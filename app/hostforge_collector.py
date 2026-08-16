#!/usr/bin/env python3
import argparse
import html
import hmac
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from http.cookies import SimpleCookie
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import RLock
from typing import Deque, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, quote, unquote, urlencode, urlsplit


INSTANCE_PATTERN = re.compile(r"[^a-z0-9._-]+")
LOG_LINE_PATTERN = re.compile(r"^\[(?P<timestamp>[^\]]+)\] \[(?P<level>[^\]]+)\] \[(?P<source>[^\]]+)\] (?P<message>.*)$")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def normalize_instance_id(value: str) -> str:
    normalized = (value or "").strip().lower()
    normalized = INSTANCE_PATTERN.sub("-", normalized)
    normalized = normalized.strip("-._")
    return normalized or "default"


def normalize_profile_name(value: str) -> str:
    normalized = (value or "").strip().lower()
    normalized = INSTANCE_PATTERN.sub("-", normalized)
    return normalized.strip("-._")


def normalize_message(value: str) -> str:
    text = (value or "").replace("\r\n", "\n").replace("\r", "\n")
    return text.replace("\n", "\\n")


def render_log_text(value: str) -> str:
    return (value or "").replace("\\n", "\n")


def parse_timestamp(value: str) -> str:
    raw_value = (value or "").strip()
    if not raw_value:
        raise ValueError("timestamp is required")

    try:
        candidate = raw_value[:-1] + "+00:00" if raw_value.endswith("Z") else raw_value
        parsed = datetime.fromisoformat(candidate)
    except ValueError as exc:
        raise ValueError("timestamp must be ISO-8601") from exc

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    else:
        parsed = parsed.astimezone(timezone.utc)

    return parsed.isoformat().replace("+00:00", "Z")


def tail_lines(path: Path, max_lines: int) -> List[str]:
    if not path.exists():
        return []

    buffer: Deque[str] = deque(maxlen=max_lines)
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            buffer.append(line.rstrip("\n"))

    return list(buffer)


def first_non_empty_line(text: str) -> str:
    for line in (text or "").splitlines():
        stripped = line.strip()
        if stripped:
            return stripped

    return ""


def human_size(byte_count: str) -> str:
    try:
        value = float(byte_count)
    except ValueError:
        return byte_count

    for unit in ["B", "KiB", "MiB", "GiB"]:
        if value < 1024 or unit == "GiB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024

    return byte_count


def find_repo_dir(start_path: Path) -> Path:
    candidate = start_path.resolve()
    if candidate.is_file():
        candidate = candidate.parent

    for current in [candidate, *candidate.parents]:
        if (current / "hostforge.sh").exists():
            return current

    return start_path.resolve()


@dataclass
class CollectorConfig:
    bind: str
    port: int
    data_dir: Path
    tail_line_count: int
    max_log_bytes: int
    site_title: str
    repo_dir: Path
    hostforge_script: Path
    web_password: str
    web_session_ttl_seconds: int


@dataclass
class ShellResult:
    ok: bool
    status: int
    output: str


@dataclass
class ActionResult:
    ok: bool
    status: int
    message: str
    output: str


@dataclass
class FlashMessage:
    message: str
    level: str
    detail: str
    expires_at: float


class HostForgeCollector:
    def __init__(self, config: CollectorConfig):
        self.config = config
        self.instances_dir = self.config.data_dir / "instances"
        self.dumps_dir = self.config.data_dir / "dumps"
        self.lock = RLock()
        self.instances_dir.mkdir(parents=True, exist_ok=True)
        self.dumps_dir.mkdir(parents=True, exist_ok=True)

    def instance_dir(self, instance_id: str) -> Path:
        return self.instances_dir / normalize_instance_id(instance_id)

    def current_log_path(self, instance_id: str) -> Path:
        return self.instance_dir(instance_id) / "current.log"

    def previous_log_path(self, instance_id: str) -> Path:
        return self.instance_dir(instance_id) / "previous.log"

    def instance_page_path(self, instance_id: str) -> Path:
        return self.instance_dir(instance_id) / "index.html"

    def instances_index_path(self) -> Path:
        return self.instances_dir / "index.html"

    def ingest_log(self, payload: Dict[str, object]) -> Tuple[str, str]:
        instance_id = normalize_instance_id(str(payload.get("instanceId", "")))
        timestamp = parse_timestamp(str(payload.get("timestamp", "")))
        level = str(payload.get("level", "")).strip().lower()
        source = str(payload.get("source", "")).strip()
        message = normalize_message(str(payload.get("message", "")))

        if not level:
            raise ValueError("level is required")
        if not source:
            raise ValueError("source is required")
        if not message:
            raise ValueError("message is required")

        line = f"[{timestamp}] [{level}] [{source}] {message}\n"

        with self.lock:
            self._append_line(instance_id, line)
            self.rebuild_instance(instance_id)
            self.rebuild_index()

        return instance_id, timestamp

    def rebuild_all(self) -> None:
        with self.lock:
            if self.instances_dir.exists():
                for instance_dir in sorted(self.instances_dir.iterdir(), key=lambda item: item.name):
                    if instance_dir.is_dir():
                        self.rebuild_instance(instance_dir.name)

            self.rebuild_index()

    def rebuild_index(self) -> None:
        rows = []
        for entry in self._collect_instance_entries():
            rows.append(
                "<tr>"
                f"<td><a href=\"/instances/{html.escape(entry['instance_id'])}/\">{html.escape(entry['instance_id'])}</a></td>"
                f"<td>{html.escape(entry['last_timestamp'] or 'n/a')}</td>"
                f"<td>{html.escape(entry['last_level'] or 'n/a')}</td>"
                f"<td>{html.escape(entry['last_source'] or 'n/a')}</td>"
                f"<td>{html.escape(entry['last_message'] or 'n/a')}</td>"
                f"<td><a href=\"/instances/{html.escape(entry['instance_id'])}/current.log\">current.log</a></td>"
                "</tr>")

        if not rows:
            rows.append("<tr><td colspan=\"6\">No logs received yet.</td></tr>")

        body = (
            f"<p>Generated at <code>{html.escape(utc_now_iso())}</code>.</p>"
            "<p><a href=\"/\">Back to HostForge</a></p>"
            "<table>"
            "<thead><tr><th>Instance</th><th>Last Timestamp</th><th>Level</th><th>Source</th><th>Message</th><th>Files</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody>"
            "</table>"
        )
        self.instances_index_path().write_text(self._render_page("HostForge Instance Logs", body), encoding="utf-8")

    def rebuild_instance(self, instance_id: str) -> None:
        instance_key = normalize_instance_id(instance_id)
        instance_dir = self.instance_dir(instance_key)
        instance_dir.mkdir(parents=True, exist_ok=True)

        current_lines = tail_lines(self.current_log_path(instance_key), self.config.tail_line_count)
        previous_lines = tail_lines(self.previous_log_path(instance_key), self.config.tail_line_count)
        latest = self._parse_log_line(current_lines[-1] if current_lines else "")

        body = (
            "<p><a href=\"/instances/\">Back to instance index</a> | <a href=\"/\">Back to HostForge</a></p>"
            f"<p><strong>Instance:</strong> <code>{html.escape(instance_key)}</code></p>"
            f"<p><strong>Updated:</strong> <code>{html.escape((latest or {}).get('timestamp', 'n/a'))}</code></p>"
            f"<p><a href=\"/instances/{html.escape(instance_key)}/current.log\">current.log</a>"
            f" | <a href=\"/instances/{html.escape(instance_key)}/previous.log\">previous.log</a></p>"
            "<h2>Recent Current Log</h2>"
            f"{self._render_log_block(current_lines, 'No current log lines yet.')}"
            "<h2>Previous Log</h2>"
            f"{self._render_log_block(previous_lines, 'No previous log file.')}"
        )
        self.instance_page_path(instance_key).write_text(
            self._render_page(f"HostForge Logs - {instance_key}", body),
            encoding="utf-8",
        )

    def serve_static_path(self, request_path: str) -> Tuple[Optional[Path], str]:
        raw_path = unquote(urlsplit(request_path).path or "/")

        if raw_path == "/instances" or raw_path == "/instances/":
            if not self.instances_index_path().exists():
                self.rebuild_all()

            return self.instances_index_path(), "text/html; charset=utf-8"

        if raw_path.startswith("/instances/"):
            suffix = raw_path[len("/instances/"):]
            parts = [part for part in suffix.split("/") if part]
            if not parts:
                return None, "text/plain; charset=utf-8"

            instance_id = normalize_instance_id(parts[0])
            if len(parts) == 1:
                page_path = self.instance_page_path(instance_id)
                if not page_path.exists():
                    self.rebuild_instance(instance_id)

                return page_path if page_path.exists() else None, "text/html; charset=utf-8"

            if len(parts) == 2 and parts[1] in {"current.log", "previous.log"}:
                file_path = self.instance_dir(instance_id) / parts[1]
                return file_path if file_path.exists() else None, "text/plain; charset=utf-8"

        if raw_path.startswith("/dumps/"):
            suffix = raw_path[len("/dumps/"):]
            parts = [part for part in suffix.split("/") if part]
            if not parts:
                return None, "text/plain; charset=utf-8"

            profile = normalize_instance_id(parts[0])
            if len(parts) == 2:
                file_name = Path(parts[1]).name
                file_path = (self.dumps_dir / profile / file_name).resolve()
                try:
                    file_path.relative_to(self.dumps_dir.resolve())
                except ValueError:
                    return None, "text/plain; charset=utf-8"

                if file_path.exists() and file_path.is_file():
                    return file_path, "application/octet-stream"

        return None, "text/plain; charset=utf-8"

    def _append_line(self, instance_id: str, line: str) -> None:
        current_path = self.current_log_path(instance_id)
        previous_path = self.previous_log_path(instance_id)
        current_path.parent.mkdir(parents=True, exist_ok=True)

        if current_path.exists() and current_path.stat().st_size >= self.config.max_log_bytes:
            if previous_path.exists():
                previous_path.unlink()

            current_path.replace(previous_path)

        with current_path.open("a", encoding="utf-8") as handle:
            handle.write(line)

    def _collect_instance_entries(self) -> List[Dict[str, str]]:
        entries: List[Dict[str, str]] = []
        if not self.instances_dir.exists():
            return entries

        for instance_dir in self.instances_dir.iterdir():
            if not instance_dir.is_dir():
                continue

            latest = self._parse_log_line(
                tail_lines(instance_dir / "current.log", 1)[-1]
                if (instance_dir / "current.log").exists()
                else "",
            )
            entries.append(
                {
                    "instance_id": instance_dir.name,
                    "last_timestamp": "" if latest is None else latest["timestamp"],
                    "last_level": "" if latest is None else latest["level"],
                    "last_source": "" if latest is None else latest["source"],
                    "last_message": "" if latest is None else latest["message"],
                }
            )

        entries.sort(key=lambda item: (item["last_timestamp"], item["instance_id"]), reverse=True)
        return entries

    def _parse_log_line(self, line: str) -> Optional[Dict[str, str]]:
        match = LOG_LINE_PATTERN.match(line or "")
        return None if match is None else match.groupdict()

    def _render_log_block(self, lines: List[str], empty_text: str) -> str:
        if not lines:
            return f"<p>{html.escape(empty_text)}</p>"

        return f"<pre>{html.escape(render_log_text(chr(10).join(lines)))}</pre>"

    def _render_page(self, title: str, body: str) -> str:
        return (
            "<!doctype html>"
            "<html lang=\"en\">"
            "<head>"
            "<meta charset=\"utf-8\">"
            f"<title>{html.escape(title)}</title>"
            "<style>"
            "body{font-family:Segoe UI,Arial,sans-serif;background:#f5f1e8;color:#1f1f1f;margin:0;padding:24px;}"
            "main{max-width:1200px;margin:0 auto;background:#fffdf9;padding:24px;border:1px solid #d8cfbf;box-shadow:0 8px 24px rgba(0,0,0,.08);}"
            "h1,h2{font-family:Georgia,serif;margin-top:0;color:#3f2f1d;}"
            "a{color:#6e3f13;text-decoration:none;}"
            "a:hover{text-decoration:underline;}"
            "table{width:100%;border-collapse:collapse;}"
            "th,td{text-align:left;padding:10px;border-bottom:1px solid #e7ddce;vertical-align:top;}"
            "th{background:#f0e6d8;}"
            "pre{white-space:pre-wrap;word-break:break-word;background:#1c1c1c;color:#f5f1e8;padding:16px;overflow:auto;}"
            "code{background:#efe5d7;padding:2px 4px;}"
            "</style>"
            "</head>"
            "<body>"
            "<main>"
            f"<h1>{html.escape(self.config.site_title)}</h1>"
            f"{body}"
            "</main>"
            "</body>"
            "</html>"
        )


class HostForgeController:
    def __init__(self, config: CollectorConfig):
        self.config = config

    def list_profiles(self) -> List[Dict[str, str]]:
        names_result = self._run("__discover-profiles")
        names = [line.strip() for line in names_result.output.splitlines() if line.strip()]
        profiles = [self.inspect_profile(name) for name in names]
        profiles.sort(key=lambda item: item["profile"])
        return profiles

    def inspect_profile(self, profile: str) -> Dict[str, str]:
        result = self._run("__inspect-profile", profile)
        data = self._parse_kv_output(result.output)
        data.setdefault("profile", profile)
        data.setdefault("health", "invalid")
        data.setdefault("params_present", "no")
        data.setdefault("config_present", "no")
        data.setdefault("port", "")
        data.setdefault("server_name", "")
        data.setdefault("game_type", "")
        data.setdefault("enabled", "missing")
        data.setdefault("active", "inactive")
        data["command_ok"] = "yes" if result.ok else "no"
        data["command_status"] = str(result.status)
        data["command_output"] = result.output
        return data

    def profile_files(self, profile: str) -> Dict[str, str]:
        result = self._run("__profile-files-web", profile)
        data, params_text, config_text = self._parse_profile_files_output(result.output)
        data.setdefault("profile", profile)
        data.setdefault("params_file", "")
        data.setdefault("config_file", "")
        data.setdefault("params_present", "no")
        data.setdefault("config_present", "no")
        data["params_text"] = params_text
        data["config_text"] = config_text
        data["command_ok"] = "yes" if result.ok else "no"
        data["command_status"] = str(result.status)
        data["command_output"] = result.output
        return data

    def collector_status(self) -> Dict[str, str]:
        result = self._run("__collector-status-web")
        data = self._parse_kv_output(result.output)
        data.setdefault("unit", "hostforge-collector.service")
        data.setdefault("enabled", "missing")
        data.setdefault("active", "inactive")
        data.setdefault("url", "")
        data.setdefault("bind", "")
        data.setdefault("port", "")
        data["command_ok"] = "yes" if result.ok else "no"
        data["command_status"] = str(result.status)
        data["command_output"] = result.output
        return data

    def firewall_status(self) -> Dict[str, str]:
        result = self._run("__firewall-status-web")
        data = self._parse_kv_output(result.output)
        data.setdefault("unit", "hostforge-firewall.service")
        data.setdefault("enabled", "missing")
        data.setdefault("active", "inactive")
        data.setdefault("set", "hostforge_players")
        data.setdefault("blacklist_set", "hostforge_blacklist")
        data.setdefault("chain", "HOSTFORGE_PLAYERS")
        data.setdefault("blacklist_chain", "HOSTFORGE_BLACKLIST")
        data.setdefault("ports", "")
        data.setdefault("timeout", "")
        data.setdefault("blacklist_pps", "3000")
        data.setdefault("blacklist_burst", "9000")
        data.setdefault("hashlimit_name", "hf_pps")
        data.setdefault("blacklist_bps", "512kb/s")
        data.setdefault("blacklist_bps_burst", "2mb")
        data.setdefault("hashlimit_bps_name", "hf_bps")
        data.setdefault("iptables", "missing")
        data.setdefault("ipset", "missing")
        data["command_ok"] = "yes" if result.ok else "no"
        data["command_status"] = str(result.status)
        data["command_output"] = result.output
        return data

    def firewall_players(self) -> List[Dict[str, str]]:
        result = self._run("__firewall-players-web", "1", timeout=10)
        players: List[Dict[str, str]] = []

        for line in result.output.splitlines():
            item: Dict[str, str] = {}
            for part in line.split():
                if "=" not in part:
                    continue
                key, value = part.split("=", 1)
                item[key] = value

            if item.get("ip"):
                players.append(item)

        def rate_value(item: Dict[str, str]) -> float:
            try:
                return float(item.get("pps", "0"))
            except ValueError:
                return 0.0

        players.sort(key=rate_value, reverse=True)
        return players

    def firewall_blacklist(self) -> List[Dict[str, str]]:
        result = self._run("__firewall-blacklist-web")
        entries: List[Dict[str, str]] = []

        for line in result.output.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            entries.append({"ip": parts[0], "packets": parts[1], "bytes": parts[2]})

        return entries

    def firewall_geo_countries(self) -> List[Dict[str, str]]:
        result = self._run("__firewall-geo-countries-web")
        countries: List[Dict[str, str]] = []

        for line in result.output.splitlines():
            item: Dict[str, str] = {}
            for part in line.split():
                if "=" not in part:
                    continue
                key, value = part.split("=", 1)
                item[key] = value

            if item.get("country"):
                countries.append(item)

        countries.sort(key=lambda item: item.get("country", ""))
        return countries

    def repo_status(self) -> Dict[str, str]:
        result = self._run("__repo-status-web")
        data = self._parse_kv_output(result.output)
        data.setdefault("hostforge_dir", "")
        data.setdefault("hostforge_module_source", "")
        data.setdefault("hostforge_module_name", "MBWarlords.HostForge")
        data.setdefault("hostforge_present", "no")
        data.setdefault("hostforge_module_present", "no")
        data.setdefault("custom_mods_file", "")
        data["command_ok"] = "yes" if result.ok else "no"
        data["command_status"] = str(result.status)
        data["command_output"] = result.output
        return data

    def custom_mods(self) -> List[Dict[str, str]]:
        result = self._run("__custom-mods-web")
        mods: List[Dict[str, str]] = []

        for line in result.output.splitlines():
            parts = line.split("\t")
            if len(parts) < 8:
                continue

            mods.append(
                {
                    "key": parts[0],
                    "repo_dir": parts[1],
                    "module_dir": parts[2],
                    "module_name": parts[3],
                    "module_source": parts[4],
                    "repo_present": parts[5],
                    "module_present": parts[6],
                    "installed_present": parts[7],
                }
            )

        mods.sort(key=lambda item: item.get("module_name", item.get("key", "")))
        return mods

    def profile_logs(self, profile: str, lines: int = 80) -> str:
        return self._run("__profile-logs", profile, str(lines)).output

    def collector_logs(self, lines: int = 80) -> str:
        return self._run("__collector-logs-web", str(lines)).output

    def firewall_logs(self, lines: int = 80) -> str:
        return self._run("__firewall-logs-web", str(lines)).output

    def list_dumps(self, profile: Optional[str] = None) -> List[Dict[str, str]]:
        dumps_root = self.config.data_dir / "dumps"
        entries: List[Dict[str, str]] = []
        profiles: List[Path] = []

        if not dumps_root.exists():
            return entries

        if profile:
            profile_dir = dumps_root / normalize_instance_id(profile)
            profiles = [profile_dir] if profile_dir.exists() else []
        else:
            profiles = [path for path in dumps_root.iterdir() if path.is_dir()]

        for profile_dir in profiles:
            profile_name = normalize_instance_id(profile_dir.name)
            for path in profile_dir.iterdir():
                if not path.is_file():
                    continue

                stat = path.stat()
                entries.append(
                    {
                        "profile": profile_name,
                        "name": path.name,
                        "size": str(stat.st_size),
                        "modified": datetime.fromtimestamp(stat.st_mtime, timezone.utc)
                        .replace(microsecond=0)
                        .isoformat()
                        .replace("+00:00", "Z"),
                        "url": f"/dumps/{quote(profile_name)}/{quote(path.name)}",
                    }
                )

        entries.sort(key=lambda item: (item["modified"], item["profile"], item["name"]), reverse=True)
        return entries

    def clear_dumps(self, profile: Optional[str] = None) -> ActionResult:
        args = ["__clear-dumps-web"]
        if profile:
            args.append(profile)
        return self._run_action(*args, timeout=120)

    def activate_profile(self, profile: str) -> ActionResult:
        return self._run_action("__activate-profile", profile, timeout=600)

    def deactivate_profile(self, profile: str) -> ActionResult:
        return self._run_action("__deactivate-profile", profile, timeout=600)

    def restart_profile(self, profile: str) -> ActionResult:
        return self._run_action("__restart-profile", profile, timeout=600)

    def save_profile_files(self, profile: str, params_text: str, config_text: str) -> ActionResult:
        if not profile:
            return ActionResult(False, 1, "Save profile failed.", "Profile name is required.")

        temp_params_path = ""
        temp_config_path = ""
        try:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
                handle.write((params_text or "").replace("\r\n", "\n").replace("\r", "\n"))
                temp_params_path = handle.name

            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
                handle.write((config_text or "").replace("\r\n", "\n").replace("\r", "\n"))
                temp_config_path = handle.name

            return self._run_action("__profile-save-files-web", profile, temp_params_path, temp_config_path, timeout=120)
        finally:
            for temp_path in [temp_params_path, temp_config_path]:
                if temp_path:
                    try:
                        os.unlink(temp_path)
                    except OSError:
                        pass

    def delete_profile_files(self, profile: str) -> ActionResult:
        return self._run_action("__profile-delete-files-web", profile, timeout=120)

    def refresh_services(self) -> ActionResult:
        return self._run_action("__refresh-services", timeout=600)

    def update_bannerlord(self) -> ActionResult:
        return self._run_action("__update-bannerlord-web", timeout=3600)

    def repo_pull_hostforge(self) -> ActionResult:
        return self._run_action("__repo-pull-hostforge-web", timeout=1800)

    def collector_restart(self) -> ActionResult:
        return self._run_action("__collector-restart-web", timeout=120)

    def repo_sync_hostforge_module(self) -> ActionResult:
        return self._run_action("__repo-sync-hostforge-module-web", timeout=3600)

    def repo_update_hostforge_module(self) -> ActionResult:
        return self._run_action("__repo-update-hostforge-module-web", timeout=3600)

    def custom_mod_save(self, repo_dir: str, module_dir: str, module_name: str) -> ActionResult:
        return self._run_action("__custom-mod-save-web", repo_dir, module_dir, module_name, timeout=120)

    def custom_mod_delete(self, key: str) -> ActionResult:
        return self._run_action("__custom-mod-delete-web", key, timeout=120)

    def custom_mod_pull(self, key: str) -> ActionResult:
        return self._run_action("__custom-mod-pull-web", key, timeout=1800)

    def custom_mod_sync(self, key: str) -> ActionResult:
        return self._run_action("__custom-mod-sync-web", key, timeout=3600)

    def custom_mod_update(self, key: str) -> ActionResult:
        return self._run_action("__custom-mod-update-web", key, timeout=3600)

    def firewall_start(self) -> ActionResult:
        return self._run_action("__firewall-start-web", timeout=600)

    def firewall_stop(self) -> ActionResult:
        return self._run_action("__firewall-stop-web", timeout=600)

    def firewall_restart(self) -> ActionResult:
        return self._run_action("__firewall-restart-web", timeout=600)

    def firewall_blacklist_remove(self, ip: str) -> ActionResult:
        return self._run_action("__firewall-blacklist-remove-web", ip, timeout=120)

    def firewall_blacklist_add(self, ip: str) -> ActionResult:
        return self._run_action("__firewall-blacklist-add-web", ip, timeout=120)

    def firewall_blacklist_clear(self) -> ActionResult:
        return self._run_action("__firewall-blacklist-clear-web", timeout=120)

    def firewall_geo_save(self, country: str, cidrs: str) -> ActionResult:
        temp_path = ""
        try:
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
                handle.write(cidrs)
                temp_path = handle.name

            return self._run_action("__firewall-geo-save-file-web", country, temp_path, timeout=120)
        finally:
            if temp_path:
                try:
                    os.unlink(temp_path)
                except OSError:
                    pass

    def firewall_geo_delete(self, country: str) -> ActionResult:
        return self._run_action("__firewall-geo-delete-web", country, timeout=120)

    def firewall_geo_apply(self) -> ActionResult:
        return self._run_action("__firewall-geo-apply-web", timeout=600)

    def _run(self, *args: str, timeout: int = 120) -> ShellResult:
        env = os.environ.copy()
        env["HF_SUDO_NONINTERACTIVE"] = "1"

        try:
            completed = subprocess.run(
                ["bash", str(self.config.hostforge_script), *args],
                cwd=str(self.config.repo_dir),
                text=True,
                capture_output=True,
                timeout=timeout,
                env=env,
            )
        except subprocess.TimeoutExpired:
            return ShellResult(False, 124, "Command timed out.")
        except OSError as exc:
            return ShellResult(False, 126, str(exc))

        output_parts = []
        if completed.stdout:
            output_parts.append(completed.stdout.rstrip())
        if completed.stderr:
            output_parts.append(completed.stderr.rstrip())

        return ShellResult(completed.returncode == 0, completed.returncode, "\n".join(part for part in output_parts if part))

    def _run_action(self, *args: str, timeout: int = 120) -> ActionResult:
        result = self._run(*args, timeout=timeout)
        metadata, output = self._parse_action_output(result.output)
        ok = metadata.get("ok", "yes" if result.ok else "no") == "yes"
        status = int(metadata.get("status", str(result.status)))
        message = metadata.get("message", "Action completed." if ok else "Action failed.")
        return ActionResult(ok, status, message, output)

    def _parse_kv_output(self, text: str) -> Dict[str, str]:
        data: Dict[str, str] = {}
        for line in (text or "").splitlines():
            if "=" not in line or line.startswith("__"):
                continue

            key, value = line.split("=", 1)
            data[key.strip()] = value.strip()

        return data

    def _parse_action_output(self, text: str) -> Tuple[Dict[str, str], str]:
        metadata: Dict[str, str] = {}
        output_lines: List[str] = []
        inside_output = False

        for line in (text or "").splitlines():
            if line == "__OUTPUT_BEGIN__":
                inside_output = True
                continue

            if line == "__OUTPUT_END__":
                inside_output = False
                continue

            if inside_output:
                output_lines.append(line)
                continue

            if "=" in line:
                key, value = line.split("=", 1)
                metadata[key.strip()] = value.strip()

        return metadata, "\n".join(output_lines).strip()

    def _parse_profile_files_output(self, text: str) -> Tuple[Dict[str, str], str, str]:
        metadata: Dict[str, str] = {}
        params_lines: List[str] = []
        config_lines: List[str] = []
        section = ""

        for line in (text or "").splitlines():
            if line == "__PARAMS_BEGIN__":
                section = "params"
                continue

            if line == "__PARAMS_END__":
                section = ""
                continue

            if line == "__CONFIG_BEGIN__":
                section = "config"
                continue

            if line == "__CONFIG_END__":
                section = ""
                continue

            if section == "params":
                params_lines.append(line)
                continue

            if section == "config":
                config_lines.append(line)
                continue

            if "=" in line:
                key, value = line.split("=", 1)
                metadata[key.strip()] = value.strip()

        return metadata, "\n".join(params_lines), "\n".join(config_lines)


class HostForgeWebApp:
    def __init__(self, config: CollectorConfig, collector: HostForgeCollector, controller: HostForgeController):
        self.config = config
        self.collector = collector
        self.controller = controller
        self._sessions: Dict[str, float] = {}
        self._session_lock = RLock()
        self._flash_messages: Dict[str, FlashMessage] = {}
        self._flash_lock = RLock()

    def auth_enabled(self) -> bool:
        return bool(self.config.web_password)

    def authenticate_password(self, candidate: str) -> bool:
        if not self.auth_enabled():
            return True

        return hmac.compare_digest(candidate or "", self.config.web_password)

    def create_session(self) -> str:
        token = secrets.token_urlsafe(32)
        expires_at = time.time() + self.config.web_session_ttl_seconds
        with self._session_lock:
            self._sessions[token] = expires_at
            self._prune_sessions_locked()
        return token

    def invalidate_session(self, token: str) -> None:
        if not token:
            return

        with self._session_lock:
            self._sessions.pop(token, None)

    def is_authenticated(self, token: str) -> bool:
        if not self.auth_enabled():
            return True

        if not token:
            return False

        now = time.time()
        with self._session_lock:
            expires_at = self._sessions.get(token)
            if expires_at is None:
                self._prune_sessions_locked(now)
                return False

            if expires_at <= now:
                self._sessions.pop(token, None)
                self._prune_sessions_locked(now)
                return False

            self._sessions[token] = now + self.config.web_session_ttl_seconds
            self._prune_sessions_locked(now)
            return True

    def _prune_sessions_locked(self, now: Optional[float] = None) -> None:
        current_time = time.time() if now is None else now
        expired = [token for token, expires_at in self._sessions.items() if expires_at <= current_time]
        for token in expired:
            self._sessions.pop(token, None)

    def create_flash_message(self, message: str, level: str, detail: str = "") -> str:
        flash_id = secrets.token_urlsafe(18)
        expires_at = time.time() + 120
        with self._flash_lock:
            self._flash_messages[flash_id] = FlashMessage(message=message, level=level, detail=detail, expires_at=expires_at)
            self._prune_flash_locked()
        return flash_id

    def consume_flash_message(self, flash_id: str) -> Optional[FlashMessage]:
        if not flash_id:
            return None

        with self._flash_lock:
            flash = self._flash_messages.pop(flash_id, None)
            self._prune_flash_locked()
            if flash is None:
                return None
            if flash.expires_at <= time.time():
                return None
            return flash

    def _prune_flash_locked(self) -> None:
        current_time = time.time()
        expired = [flash_id for flash_id, flash in self._flash_messages.items() if flash.expires_at <= current_time]
        for flash_id in expired:
            self._flash_messages.pop(flash_id, None)

    def render_login_page(self, query: Dict[str, List[str]], next_path: str = "/") -> str:
        notice = self._render_notice(query)
        body = (
            f"{notice}"
            "<section class=\"panel auth-panel\">"
            "<h2>Protected HostForge</h2>"
            "<p>Enter the shared admin password to open the HostForge website.</p>"
            "<form class=\"auth-form\" method=\"post\" action=\"/login\">"
            f"<input type=\"hidden\" name=\"next\" value=\"{html.escape(next_path)}\">"
            "<label for=\"password\">Password</label>"
            "<input id=\"password\" name=\"password\" type=\"password\" autocomplete=\"current-password\" autofocus>"
            "<button class=\"button\" type=\"submit\">Enter HostForge</button>"
            "</form>"
            "</section>"
        )
        return self._render_page("HostForge Login", "login", body)

    def render_dashboard(self, query: Dict[str, List[str]]) -> str:
        profiles = self.controller.list_profiles()
        collector = self.controller.collector_status()
        firewall = self.controller.firewall_status()
        repos = self.controller.repo_status()
        active_count = sum(1 for profile in profiles if profile.get("active") == "active")
        valid_count = sum(1 for profile in profiles if profile.get("health") == "valid")
        repos_ready = sum(1 for key in ("hostforge_present", "hostforge_module_present") if repos.get(key) == "yes")

        summary = (
            "<section class=\"cards\">"
            f"{self._render_card('Profiles', f'{len(profiles)} total', f'{valid_count} valid, {active_count} active')}"
            f"{self._render_card('Firewall', firewall.get('active', 'inactive'), firewall.get('ports', '') or 'no tracked ports')}"
            f"{self._render_card('Collector', collector.get('active', 'inactive'), collector.get('url', ''))}"
            f"{self._render_card('Repos', f'{repos_ready}/2 ready', repos.get('hostforge_module_source', ''))}"
            "</section>"
        )

        actions = (
            "<section class=\"panel\">"
            "<h2>Host Actions</h2>"
            "<div class=\"toolbar\">"
            f"{self._render_post_button('/services/refresh', 'Refresh service units', '/')}"
            f"{self._render_post_button('/bannerlord/update', 'Update Bannerlord', '/')}"
            "</div>"
            "</section>"
        )

        body = (
            f"{self._render_notice(query)}"
            f"{summary}"
            f"{actions}"
            "<section class=\"panel\">"
            "<h2>Profiles</h2>"
            f"{self._render_profiles_table(profiles, '/')}"
            "</section>"
            "<section class=\"split\">"
            "<div class=\"panel\">"
            "<h2>Collector</h2>"
            f"{self._render_status_list([('State', collector.get('active', 'inactive')), ('Enabled', collector.get('enabled', 'missing')), ('URL', collector.get('url', ''))])}"
            "<p><a href=\"/logs/collector/\">Open collector logs</a> | <a href=\"/instances/\">Open instance logs</a></p>"
            "</div>"
            "<div class=\"panel\">"
            "<h2>Firewall</h2>"
            f"{self._render_status_list([('State', firewall.get('active', 'inactive')), ('Enabled', firewall.get('enabled', 'missing')), ('Ports', firewall.get('ports', '') or 'none')])}"
            "<p><a href=\"/firewall/\">Open firewall traffic</a></p>"
            "</div>"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Repos</h2>"
            f"{self._render_status_list([('hostforge', repos.get('hostforge_present', 'no')), ('HostForge module', repos.get('hostforge_module_present', 'no'))])}"
            "<p><a href=\"/repos/\">Open repo maintenance</a></p>"
            "</section>"
        )
        return self._render_page("HostForge", "dashboard", body)

    def render_profiles_page(self, query: Dict[str, List[str]]) -> str:
        profiles = self.controller.list_profiles()
        body = (
            f"{self._render_notice(query)}"
            "<section class=\"panel\">"
            "<h2>Profiles</h2>"
            f"{self._render_profiles_table(profiles, '/profiles/')}"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Create Profile</h2>"
            "<p class=\"muted\">Create a profile pair under <code>configs/</code>. The files become <code>ds_params_&lt;profile&gt;.txt</code> and <code>ds_config_&lt;profile&gt;.txt</code>.</p>"
            f"{self._render_profile_files_form('', '', '', '/profiles/save', '/profiles/', False)}"
            "</section>"
        )
        return self._render_page("HostForge Profiles", "profiles", body)

    def render_profile_page(self, profile: str, query: Dict[str, List[str]]) -> str:
        details = self.controller.inspect_profile(profile)
        files = self.controller.profile_files(profile)
        logs = self.controller.profile_logs(profile, 80)
        dumps = self.controller.list_dumps(profile)
        current_log_lines = tail_lines(self.collector.current_log_path(profile), 60)
        previous_log_lines = tail_lines(self.collector.previous_log_path(profile), 30)

        if details.get("params_present") == "no" and details.get("config_present") == "no":
            return self._render_page(
                "Profile Not Found",
                "profiles",
                "<section class=\"panel\"><h2>Profile not found</h2><p>This profile does not exist under <code>configs/</code>.</p></section>",
                status_code=HTTPStatus.NOT_FOUND,
            )

        body = (
            f"{self._render_notice(query)}"
            "<section class=\"panel\">"
            f"<div class=\"heading-row\"><h2>{html.escape(profile)}</h2><div class=\"toolbar\">"
            f"{self._render_post_button(f'/profiles/{quote(profile)}/activate', 'Activate', f'/profiles/{quote(profile)}/', disabled=details.get('health') != 'valid')}"
            f"{self._render_post_button(f'/profiles/{quote(profile)}/deactivate', 'Deactivate', f'/profiles/{quote(profile)}/')}"
            f"{self._render_post_button(f'/profiles/{quote(profile)}/restart', 'Restart', f'/profiles/{quote(profile)}/', disabled=details.get('health') != 'valid')}"
            f"{self._render_post_button(f'/profiles/{quote(profile)}/delete', 'Delete files', '/profiles/', disabled=details.get('active') == 'active', style='danger')}"
            "</div></div>"
            f"{self._render_status_list([('Health', details.get('health', 'invalid')), ('Enabled', details.get('enabled', 'missing')), ('Active', details.get('active', 'inactive')), ('Port', details.get('port', '')), ('ServerName', details.get('server_name', '')), ('GameType', details.get('game_type', '')), ('Params', details.get('params_file', '')), ('Config', details.get('config_file', ''))])}"
            f"<p><a href=\"/profiles/{quote(profile)}/logs/\">Systemd logs</a> | <a href=\"/instances/{quote(profile)}/\">Collector logs</a> | <a href=\"/instances/{quote(profile)}/current.log\">current.log</a> | <a href=\"/dumps/{quote(profile)}/\">Crash dumps</a></p>"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Edit Config Files</h2>"
            "<p class=\"muted\">Saving updates the profile files only. Restart the profile after saving if it is already running.</p>"
            f"{self._render_profile_files_form(profile, files.get('params_text', ''), files.get('config_text', ''), f'/profiles/{quote(profile)}/save', f'/profiles/{quote(profile)}/', True)}"
            "</section>"
            "<section class=\"panel\">"
            f"<div class=\"heading-row\"><h2>Crash Dumps</h2><div class=\"toolbar\"><a class=\"button link-button\" href=\"/dumps/{quote(profile)}/\">Open dumps</a></div></div>"
            f"{self._render_dumps_table(dumps, empty_text='No crash dumps for this profile yet.')}"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Recent Service Logs</h2>"
            f"{self._render_pre(logs or 'No journal output available.')}"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Recent Collector Logs</h2>"
            f"{self._render_pre(chr(10).join(current_log_lines) if current_log_lines else 'No collector log lines yet.')}"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Previous Collector Log</h2>"
            f"{self._render_pre(chr(10).join(previous_log_lines) if previous_log_lines else 'No previous collector log file.')}"
            "</section>"
        )
        return self._render_page(f"Profile - {profile}", "profiles", body)

    def render_dumps_page(self, query: Dict[str, List[str]], profile: Optional[str] = None) -> str:
        dumps = self.controller.list_dumps(profile)
        title = f"Crash Dumps - {profile}" if profile else "Crash Dumps"
        back_link = "/profiles/" if profile is None else f"/profiles/{quote(profile)}/"

        body = (
            f"{self._render_notice(query)}"
            "<section class=\"panel\">"
            f"<div class=\"heading-row\"><h2>{html.escape(title)}</h2><div class=\"toolbar\"><a class=\"button link-button\" href=\"{back_link}\">Back</a>"
            f"{self._render_post_button(f'/dumps/{quote(profile)}/clear' if profile else '/dumps/clear', 'Clear dumps', f'/dumps/{quote(profile)}/' if profile else '/dumps/', style='danger')}"
            "</div></div>"
            f"{self._render_dumps_table(dumps)}"
            "</section>"
        )
        return self._render_page(title, "dumps", body)

    def render_profile_logs_page(self, profile: str, query: Dict[str, List[str]]) -> str:
        details = self.controller.inspect_profile(profile)
        logs = self.controller.profile_logs(profile, 160)

        if details.get("params_present") == "no" and details.get("config_present") == "no":
            return self._render_page(
                "Profile Not Found",
                "profiles",
                "<section class=\"panel\"><h2>Profile not found</h2></section>",
                status_code=HTTPStatus.NOT_FOUND,
            )

        body = (
            f"{self._render_notice(query)}"
            "<section class=\"panel\">"
            f"<div class=\"heading-row\"><h2>Logs - {html.escape(profile)}</h2><div class=\"toolbar\"><a class=\"button link-button\" href=\"/profiles/{quote(profile)}/\">Back to profile</a></div></div>"
            f"{self._render_pre(logs or 'No journal output available.')}"
            "</section>"
        )
        return self._render_page(f"Profile Logs - {profile}", "profiles", body)

    def render_firewall_page(self, query: Dict[str, List[str]]) -> str:
        firewall = self.controller.firewall_status()
        players = self.controller.firewall_players()
        blacklist = self.controller.firewall_blacklist()
        geo_countries = self.controller.firewall_geo_countries()
        logs = self.controller.firewall_logs(80)
        auto_blacklist_text = (
            f"> {firewall.get('blacklist_pps', '3000')} pps "
            f"with burst {firewall.get('blacklist_burst', '9000')}"
        )
        auto_bandwidth_text = (
            f"> {firewall.get('blacklist_bps', '512kb/s')} "
            f"with burst {firewall.get('blacklist_bps_burst', '2mb')}"
        )
        body = (
            f"{self._render_notice(query)}"
            "<section class=\"panel\">"
            "<div class=\"heading-row\"><h2>Firewall Player Tracking</h2><div class=\"toolbar\">"
            f"{self._render_post_button('/firewall/start', 'Start / Enable', '/firewall/')}"
            f"{self._render_post_button('/firewall/stop', 'Stop / Disable', '/firewall/', style='secondary')}"
            f"{self._render_post_button('/firewall/restart', 'Restart', '/firewall/')}"
            "</div></div>"
            f"{self._render_status_list([('Unit', firewall.get('unit', '')), ('Enabled', firewall.get('enabled', 'missing')), ('Active', firewall.get('active', 'inactive')), ('Player ipset', firewall.get('set', '')), ('Blacklist ipset', firewall.get('blacklist_set', '')), ('Geo block ipset', firewall.get('geo_set', '')), ('Track chain', firewall.get('chain', '')), ('Block chain', firewall.get('blacklist_chain', '')), ('Geo chain', firewall.get('geo_chain', '')), ('Geo dir', firewall.get('geo_dir', '')), ('Tracked ports', firewall.get('ports', '') or 'none'), ('Entry timeout', (firewall.get('timeout', '') + 's') if firewall.get('timeout') else ''), ('PPS auto-blacklist', auto_blacklist_text), ('Bandwidth auto-blacklist', auto_bandwidth_text), ('PPS hashlimit', firewall.get('hashlimit_name', '')), ('Bandwidth hashlimit', firewall.get('hashlimit_bps_name', '')), ('iptables binary', firewall.get('iptables', 'missing')), ('ipset binary', firewall.get('ipset', 'missing'))])}"
            "<p class=\"muted\">HostForge adds source IPs to a player ipset when packets hit configured Bannerlord ports. Iptables hashlimit adds an IP to the blacklist ipset when that source exceeds either the configured packets/sec or bandwidth rate beyond the burst allowance, and the blacklist chain drops it.</p>"
            "</section>"
            "<section class=\"panel\">"
            "<div class=\"heading-row\"><h2>Geo Country Blocks</h2><div class=\"toolbar\">"
            f"{self._render_post_button('/firewall/geo/apply', 'Apply geo blocks', '/firewall/')}"
            "</div></div>"
            "<p class=\"muted\">Paste raw IPv4 CIDR lines from the country download. Every country file listed here is dropped on Bannerlord profile ports only after applying/restarting the firewall.</p>"
            f"{self._render_firewall_geo_table(geo_countries)}"
            f"{self._render_firewall_geo_form()}"
            "</section>"
            "<section class=\"panel\">"
            "<details class=\"collapsible\">"
            "<summary><span class=\"summary-title\">Blacklist</span><span class=\"toolbar\"><span class=\"button link-button\">Collapse / expand</span></span></summary>"
            f"<div class=\"toolbar\">{self._render_post_button('/firewall/blacklist/clear', 'Clear blacklist', '/firewall/', style='danger')}</div>"
            f"{self._render_firewall_blacklist_table(blacklist)}"
            "</details>"
            "</section>"
            "<section class=\"panel\">"
            "<div class=\"heading-row\"><h2>Tracked Player Packet Rates</h2><div class=\"toolbar\"><a class=\"button link-button\" href=\"/firewall/\">Refresh</a></div></div>"
            f"{self._render_firewall_players_table(players)}"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Recent Firewall Service Logs</h2>"
            f"{self._render_pre(logs or 'No firewall journal output available.')}"
            "</section>"
        )
        return self._render_page("Firewall", "firewall", body)

    def render_repo_page(self, query: Dict[str, List[str]]) -> str:
        repos = self.controller.repo_status()
        custom_mods = self.controller.custom_mods()
        body = (
            f"{self._render_notice(query)}"
            "<section class=\"panel\">"
            "<div class=\"heading-row\"><h2>Repo Maintenance</h2><div class=\"toolbar\">"
            f"{self._render_post_button('/repos/pull-hostforge', 'Update hostforge', '/repos/')}"
            f"{self._render_post_button('/repos/sync-hostforge-module', 'Sync HostForge module', '/repos/')}"
            f"{self._render_post_button('/repos/update-hostforge-module', 'Update HostForge module', '/repos/')}"
            "</div></div>"
            f"{self._render_status_list([('hostforge repo', repos.get('hostforge_dir', '')), ('module source', repos.get('hostforge_module_source', '')), ('module name', repos.get('hostforge_module_name', 'MBWarlords.HostForge')), ('custom mods file', repos.get('custom_mods_file', '')), ('hostforge present', repos.get('hostforge_present', 'no')), ('module present', repos.get('hostforge_module_present', 'no'))])}"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Custom Mods</h2>"
            "<p class=\"muted\">Add Git-backed module repos here. Module directory can be absolute, or relative to the Git repo directory. Editing is intentionally delete and re-add for now.</p>"
            f"{self._render_custom_mods_table(custom_mods)}"
            f"{self._render_custom_mod_form()}"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Notes</h2>"
            "<p>This page mirrors the SSH repo maintenance menu. It updates this HostForge repository and syncs the bundled <code>module-hostforge</code> folder into Bannerlord.</p>"
            "</section>"
        )
        return self._render_page("Repo Maintenance", "repos", body)

    def render_collector_logs_page(self, query: Dict[str, List[str]]) -> str:
        collector = self.controller.collector_status()
        logs = self.controller.collector_logs(120)
        body = (
            f"{self._render_notice(query)}"
            "<section class=\"panel\">"
            "<div class=\"heading-row\"><h2>Collector Service</h2><div class=\"toolbar\">"
            f"{self._render_post_button('/logs/collector/restart', 'Restart website', '/logs/collector/')}"
            "</div></div>"
            f"{self._render_status_list([('Unit', collector.get('unit', '')), ('Enabled', collector.get('enabled', 'missing')), ('Active', collector.get('active', 'inactive')), ('Bind', collector.get('bind', '')), ('Port', collector.get('port', '')), ('URL', collector.get('url', ''))])}"
            "<p class=\"muted\">This restarts the collector/web service after the response is sent.</p>"
            "<p><a href=\"/instances/\">Open instance logs</a></p>"
            "</section>"
            "<section class=\"panel\">"
            "<h2>Recent Collector Journal</h2>"
            f"{self._render_pre(logs or 'No collector journal output available.')}"
            "</section>"
        )
        return self._render_page("Collector Logs", "collector", body)

    def action_redirect(self, path: str, query: Dict[str, List[str]]) -> str:
        form = self._query_value(query, "next") or "/"
        if not form.startswith("/"):
            form = path
        return form

    def redirect_with_notice(self, path: str, message: str, level: str) -> str:
        separator = "&" if "?" in path else "?"
        return f"{path}{separator}{urlencode({'notice': message, 'level': level})}"

    def _render_page(self, title: str, current_nav: str, body: str, status_code: HTTPStatus = HTTPStatus.OK) -> str:
        return (
            "<!doctype html>"
            "<html lang=\"en\">"
            "<head>"
            "<meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            f"<title>{html.escape(title)}</title>"
            "<style>"
            ":root{--bg:#efe2c7;--panel:#fff9ef;--ink:#24180f;--muted:#715947;--line:#d8c4a2;--accent:#8a4b16;--accent-strong:#5f2f0d;--danger:#8a1d1d;--ok:#315c2b;}"
            "*{box-sizing:border-box;}"
            "body{margin:0;font-family:'Segoe UI',Arial,sans-serif;color:var(--ink);background:radial-gradient(circle at top,#fff7e8 0,#efe2c7 42%,#e2d0ad 100%);}"
            "header{padding:28px 24px 18px;border-bottom:1px solid rgba(84,50,24,.12);background:linear-gradient(135deg,rgba(255,248,235,.9),rgba(235,213,177,.88));backdrop-filter:blur(6px);}"
            ".brand{max-width:1280px;margin:0 auto;display:flex;gap:16px;align-items:flex-end;justify-content:space-between;}"
            ".brand h1{margin:0;font:700 34px/1.1 Georgia,serif;letter-spacing:.02em;color:#412511;}"
            ".brand p{margin:6px 0 0;color:var(--muted);}"
            "nav{max-width:1280px;margin:14px auto 0;display:flex;gap:10px;flex-wrap:wrap;}"
            "nav a{padding:10px 14px;border:1px solid var(--line);border-radius:999px;background:rgba(255,251,244,.85);color:var(--accent-strong);text-decoration:none;font-weight:600;}"
            f"nav a.active{{background:var(--accent);color:#fff;border-color:var(--accent);}}"
            "main{max-width:1280px;margin:0 auto;padding:24px;display:grid;gap:20px;}"
            ".panel,.cards{background:var(--panel);border:1px solid var(--line);border-radius:18px;box-shadow:0 14px 32px rgba(60,35,15,.08);}"
            ".panel{padding:20px;}"
            ".cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:0;padding:0;overflow:hidden;}"
            ".card{padding:20px;border-right:1px solid var(--line);background:linear-gradient(180deg,rgba(255,252,246,.96),rgba(247,236,214,.96));}"
            ".card:last-child{border-right:none;}"
            ".card h2{margin:0 0 8px;font:700 13px/1.2 'Segoe UI',sans-serif;text-transform:uppercase;letter-spacing:.12em;color:var(--muted);}"
            ".card .value{font:700 30px/1.1 Georgia,serif;color:var(--accent-strong);}"
            ".card p{margin:8px 0 0;color:var(--muted);}"
            ".heading-row{display:flex;gap:16px;align-items:center;justify-content:space-between;flex-wrap:wrap;}"
            ".toolbar{display:flex;gap:10px;flex-wrap:wrap;}"
            ".collapsible summary{display:flex;gap:16px;align-items:center;justify-content:space-between;list-style:none;cursor:pointer;margin:-2px 0 14px;}"
            ".collapsible summary::-webkit-details-marker{display:none;}"
            ".summary-title{font:700 24px/1.2 Georgia,serif;color:#3f2f1d;}"
            "table{width:100%;border-collapse:collapse;}"
            "th,td{padding:12px 10px;border-bottom:1px solid #ebdcc4;vertical-align:top;text-align:left;}"
            "th{font-size:12px;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);}"
            "td strong{font-weight:700;}"
            ".split{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:20px;}"
            ".meta{display:grid;grid-template-columns:minmax(160px,220px) 1fr;gap:10px 16px;margin:0;}"
            ".meta dt{font-weight:700;color:var(--muted);}"
            ".meta dd{margin:0;word-break:break-word;}"
            "pre{margin:0;padding:18px;border-radius:14px;background:#191412;color:#f7ebd2;overflow:auto;white-space:pre-wrap;word-break:break-word;font:13px/1.5 Consolas,'Courier New',monospace;min-height:340px;}"
            "code{background:#f0e1c7;padding:2px 5px;border-radius:6px;}"
            "form.inline{display:inline-flex;}"
            ".auth-inline{display:inline-flex;align-items:center;gap:10px;flex-wrap:wrap;}"
            ".auth-panel{max-width:480px;margin:40px auto;}"
            ".auth-form{display:grid;gap:12px;margin-top:16px;}"
            ".auth-form label{font-weight:700;color:var(--muted);}"
            ".auth-form input{min-height:42px;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:#fffdf8;color:var(--ink);font:inherit;}"
            ".restore-form{display:grid;gap:10px;max-width:760px;}"
            ".restore-form label{font-weight:700;color:var(--muted);}"
            ".input-row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;}"
            ".input-row input{flex:1 1 320px;min-height:42px;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:#fffdf8;color:var(--ink);font:inherit;}"
            ".text-form{display:grid;gap:10px;margin-top:16px;}"
            ".text-form label{font-weight:700;color:var(--muted);}"
            ".text-form textarea{min-height:220px;padding:12px;border:1px solid var(--line);border-radius:12px;background:#fffdf8;color:var(--ink);font:13px/1.45 Consolas,'Courier New',monospace;resize:vertical;}"
            ".text-form textarea.params-textarea{min-height:86px;}"
            ".button,.button:visited{display:inline-flex;align-items:center;justify-content:center;min-height:38px;padding:0 14px;border-radius:999px;border:1px solid var(--accent);background:var(--accent);color:#fff;font-weight:700;text-decoration:none;cursor:pointer;}"
            ".button.secondary{background:#fff7ec;color:var(--accent-strong);}"
            ".button.danger{background:var(--danger);border-color:var(--danger);}"
            ".button[disabled]{opacity:.45;cursor:not-allowed;}"
            ".link-button{background:#fff7ec;color:var(--accent-strong);}"
            ".notice{padding:14px 16px;border-radius:14px;border:1px solid var(--line);font-weight:600;}"
            ".notice.success{background:#ecf6e7;border-color:#bad8ae;color:#315c2b;}"
            ".notice.error{background:#fdeaea;border-color:#efb7b7;color:#7e1e1e;}"
            ".notice-detail{margin-top:12px;padding:14px;border-radius:12px;background:rgba(18,18,18,.92);color:#f7ebd2;white-space:pre-wrap;word-break:break-word;font:12px/1.5 Consolas,'Courier New',monospace;}"
            ".badge{display:inline-flex;padding:4px 10px;border-radius:999px;font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.08em;}"
            ".badge.good{background:#e5f3de;color:#315c2b;}"
            ".badge.warn{background:#fff0d7;color:#8a5a0f;}"
            ".badge.bad{background:#fde5e5;color:#8a1d1d;}"
            ".muted{color:var(--muted);}"
            ".tiny{font-size:12px;}"
            "</style>"
            "</head>"
            "<body>"
            "<header>"
            "<div class=\"brand\">"
            "<div><h1>HostForge</h1><p>Bannerlord control plane and log intake on one private port.</p></div>"
            f"<div class=\"auth-inline\">{self._render_auth_controls()}<div class=\"muted tiny\">Generated {html.escape(utc_now_iso())}</div></div>"
            "</div>"
            "<nav>"
            f"{self._nav_link('/', 'Dashboard', current_nav == 'dashboard')}"
            f"{self._nav_link('/profiles/', 'Profiles', current_nav == 'profiles')}"
            f"{self._nav_link('/firewall/', 'Firewall', current_nav == 'firewall')}"
            f"{self._nav_link('/repos/', 'Repos', current_nav == 'repos')}"
            f"{self._nav_link('/logs/collector/', 'Collector', current_nav == 'collector')}"
            f"{self._nav_link('/instances/', 'Instance Logs', current_nav == 'instances')}"
            f"{self._nav_link('/dumps/', 'Crash Dumps', current_nav == 'dumps')}"
            "</nav>"
            "</header>"
            f"<main data-status=\"{int(status_code)}\">{body}</main>"
            "</body>"
            "</html>"
        )

    def _render_notice(self, query: Dict[str, List[str]]) -> str:
        flash_id = self._query_value(query, "flash")
        if flash_id:
            flash = self.consume_flash_message(flash_id)
            if flash is not None:
                css = "error" if flash.level == "error" else "success"
                detail_html = ""
                if flash.detail:
                    detail_html = f"<pre class=\"notice-detail\">{html.escape(render_log_text(flash.detail))}</pre>"
                return f"<div class=\"notice {css}\"><div>{html.escape(flash.message)}</div>{detail_html}</div>"

        notice = self._query_value(query, "notice")
        if not notice:
            return ""

        level = self._query_value(query, "level") or "success"
        css = "error" if level == "error" else "success"
        return f"<div class=\"notice {css}\">{html.escape(notice)}</div>"

    def _render_profiles_table(self, profiles: List[Dict[str, str]], next_path: str) -> str:
        rows = []
        for profile in profiles:
            name = profile.get("profile", "")
            valid = profile.get("health") == "valid"
            rows.append(
                "<tr>"
                f"<td><a href=\"/profiles/{quote(name)}/\"><strong>{html.escape(name)}</strong></a></td>"
                f"<td>{self._render_badge(profile.get('health', 'invalid'))}</td>"
                f"<td>{self._render_badge(profile.get('enabled', 'missing'))}</td>"
                f"<td>{self._render_badge(profile.get('active', 'inactive'))}</td>"
                f"<td>{html.escape(profile.get('port', '') or 'n/a')}</td>"
                f"<td>{html.escape(profile.get('server_name', '') or 'n/a')}</td>"
                f"<td>{html.escape(profile.get('game_type', '') or 'n/a')}</td>"
                "<td>"
                f"{self._render_post_button(f'/profiles/{quote(name)}/activate', 'Activate', next_path, disabled=not valid)}"
                f"{self._render_post_button(f'/profiles/{quote(name)}/deactivate', 'Deactivate', next_path, style='secondary')}"
                f"{self._render_post_button(f'/profiles/{quote(name)}/restart', 'Restart', next_path, disabled=not valid)}"
                f"<a class=\"button link-button\" href=\"/profiles/{quote(name)}/\">Inspect</a>"
                f"<a class=\"button link-button\" href=\"/profiles/{quote(name)}/logs/\">Logs</a>"
                "</td>"
                "</tr>"
            )

        if not rows:
            rows.append("<tr><td colspan=\"8\">No profiles found under <code>configs/</code>.</td></tr>")

        return (
            "<table>"
            "<thead><tr><th>Profile</th><th>Health</th><th>Enabled</th><th>Active</th><th>Port</th><th>Server</th><th>Game Type</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody>"
            "</table>"
        )

    def _render_profile_files_form(
        self,
        profile: str,
        params_text: str,
        config_text: str,
        action: str,
        next_path: str,
        readonly_profile: bool,
    ) -> str:
        readonly_attr = " readonly" if readonly_profile else ""
        profile_placeholder = "eu_wl_battle1"
        if not readonly_profile and not params_text:
            params_text = "/port 7210\n_MODULES_*Native*Multiplayer*MBWarlords.HostForge*_MODULES_\nno_watchdog"
        config_placeholder = "ServerName=My Bannerlord Server&#10;GameType=Battle"

        return (
            f"<form class=\"text-form\" method=\"post\" action=\"{html.escape(action)}\">"
            f"<input type=\"hidden\" name=\"next\" value=\"{html.escape(next_path)}\">"
            "<label>Profile key</label>"
            "<div class=\"input-row\">"
            f"<input name=\"profile\" required pattern=\"[A-Za-z0-9._-]+\" placeholder=\"{profile_placeholder}\" autocomplete=\"off\" value=\"{html.escape(profile)}\"{readonly_attr}>"
            "<button class=\"button\" type=\"submit\">Save profile files</button>"
            "</div>"
            "<label>Params file text</label>"
            f"<textarea class=\"params-textarea\" name=\"params\" required>{html.escape(params_text)}</textarea>"
            "<label>Config file text</label>"
            f"<textarea name=\"config\" required placeholder=\"{config_placeholder}\">{html.escape(config_text)}</textarea>"
            "<p class=\"muted tiny\">Profile keys are normalized to lowercase letters, numbers, dots, dashes, and underscores. Delete is available from the profile detail page and requires the service to be inactive.</p>"
            "</form>"
        )

    def _render_dumps_table(self, dumps: List[Dict[str, str]], empty_text: str = "No crash dumps found.") -> str:
        rows = []
        for dump in dumps:
            rows.append(
                "<tr>"
                f"<td><a href=\"/profiles/{quote(dump['profile'])}/\"><strong>{html.escape(dump['profile'])}</strong></a></td>"
                f"<td>{html.escape(dump['name'])}</td>"
                f"<td>{html.escape(human_size(dump['size']))}</td>"
                f"<td>{html.escape(dump['modified'])}</td>"
                f"<td><a class=\"button link-button\" href=\"{html.escape(dump['url'])}\" download>Download</a></td>"
                "</tr>"
            )

        if not rows:
            rows.append(f"<tr><td colspan=\"5\">{html.escape(empty_text)}</td></tr>")

        return (
            "<table>"
            "<thead><tr><th>Profile</th><th>File</th><th>Size</th><th>Modified</th><th>Download</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody>"
            "</table>"
        )

    def _render_firewall_players_table(self, players: List[Dict[str, str]]) -> str:
        rows = []
        for player in players:
            ip = player.get("ip", "")
            rows.append(
                "<tr>"
                f"<td><strong>{html.escape(ip)}</strong></td>"
                f"<td>{html.escape(player.get('pps', '0.00'))}</td>"
                f"<td>{html.escape(human_size(player.get('bps', '0')) + '/s')}</td>"
                f"<td>{html.escape(player.get('packets', '0'))}</td>"
                f"<td>{html.escape(human_size(player.get('bytes', '0')))}</td>"
                "<td>"
                f"{self._render_blacklist_ip_button('/firewall/blacklist/add', 'Blacklist', ip, style='danger')}"
                "</td>"
                "</tr>"
            )

        if not rows:
            rows.append("<tr><td colspan=\"6\">No player IPs tracked yet. Start the firewall service and wait for inbound game traffic.</td></tr>")

        return (
            "<table>"
            "<thead><tr><th>IP</th><th>Packets/sec</th><th>Bytes/sec</th><th>Total Packets</th><th>Total Bytes</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody>"
            "</table>"
        )

    def _render_firewall_blacklist_table(self, entries: List[Dict[str, str]]) -> str:
        rows = []
        for entry in entries:
            ip = entry.get("ip", "")
            rows.append(
                "<tr>"
                f"<td><strong>{html.escape(ip)}</strong></td>"
                f"<td>{html.escape(entry.get('packets', '0'))}</td>"
                f"<td>{html.escape(human_size(entry.get('bytes', '0')))}</td>"
                "<td>"
                f"{self._render_blacklist_ip_button('/firewall/blacklist/remove', 'Remove', ip, style='danger')}"
                "</td>"
                "</tr>"
            )

        if not rows:
            rows.append("<tr><td colspan=\"4\">No blacklisted IPs.</td></tr>")

        return (
            "<table>"
            "<thead><tr><th>IP</th><th>Matched Packets</th><th>Matched Bytes</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody>"
            "</table>"
        )

    def _render_firewall_geo_table(self, countries: List[Dict[str, str]]) -> str:
        rows = []
        for country in countries:
            code = country.get("country", "")
            rows.append(
                "<tr>"
                f"<td><strong>{html.escape(code)}</strong></td>"
                f"<td>{html.escape(country.get('cidrs', '0'))}</td>"
                f"<td>{html.escape(country.get('file', ''))}</td>"
                "<td>"
                f"{self._render_post_button(f'/firewall/geo/{quote(code)}/delete', 'Delete', '/firewall/', style='danger')}"
                "</td>"
                "</tr>"
            )

        if not rows:
            rows.append("<tr><td colspan=\"4\">No geo country blocks configured yet.</td></tr>")

        return (
            "<table>"
            "<thead><tr><th>Country key</th><th>CIDRs</th><th>File</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody>"
            "</table>"
        )

    def _render_firewall_geo_form(self) -> str:
        return (
            "<form class=\"text-form\" method=\"post\" action=\"/firewall/geo/save\">"
            "<input type=\"hidden\" name=\"next\" value=\"/firewall/\">"
            "<label>Country key</label>"
            "<div class=\"input-row\">"
            "<input name=\"country\" required pattern=\"[A-Za-z0-9_-]+\" placeholder=\"tr, ru, cn, br\" autocomplete=\"off\">"
            "<button class=\"button\" type=\"submit\">Save country CIDRs</button>"
            "</div>"
            "<label>IPv4 CIDR list</label>"
            "<textarea name=\"cidrs\" required placeholder=\"1.2.3.0/24&#10;5.6.0.0/16\"></textarea>"
            "<p class=\"muted tiny\">Saving creates or replaces <code>configs/firewall-geo/&lt;country&gt;.txt</code>. Use the raw <strong>Download IPv4</strong> list, not generated iptables rules.</p>"
            "</form>"
        )

    def _render_custom_mods_table(self, mods: List[Dict[str, str]]) -> str:
        rows = []
        for mod in mods:
            key = mod.get("key", "")
            rows.append(
                "<tr>"
                f"<td><strong>{html.escape(mod.get('module_name', key))}</strong><br><span class=\"muted tiny\">{html.escape(key)}</span></td>"
                f"<td>{html.escape(mod.get('repo_dir', ''))}</td>"
                f"<td>{html.escape(mod.get('module_dir', ''))}</td>"
                f"<td>{self._render_badge(mod.get('repo_present', 'no'))}</td>"
                f"<td>{self._render_badge(mod.get('module_present', 'no'))}</td>"
                f"<td>{self._render_badge(mod.get('installed_present', 'no'))}</td>"
                "<td>"
                f"{self._render_post_button(f'/repos/custom-mods/{quote(key)}/pull', 'Pull', '/repos/')}"
                f"{self._render_post_button(f'/repos/custom-mods/{quote(key)}/sync', 'Sync', '/repos/')}"
                f"{self._render_post_button(f'/repos/custom-mods/{quote(key)}/update', 'Update', '/repos/')}"
                f"{self._render_post_button(f'/repos/custom-mods/{quote(key)}/delete', 'Delete', '/repos/', style='danger')}"
                "</td>"
                "</tr>"
            )

        if not rows:
            rows.append("<tr><td colspan=\"7\">No custom mods configured yet.</td></tr>")

        return (
            "<table>"
            "<thead><tr><th>Module</th><th>Git repo directory</th><th>Module directory</th><th>Repo</th><th>Source</th><th>Installed</th><th>Actions</th></tr></thead>"
            f"<tbody>{''.join(rows)}</tbody>"
            "</table>"
        )

    def _render_custom_mod_form(self) -> str:
        return (
            "<form class=\"text-form\" method=\"post\" action=\"/repos/custom-mods/save\">"
            "<input type=\"hidden\" name=\"next\" value=\"/repos/\">"
            "<label>Git repo directory</label>"
            "<div class=\"input-row\">"
            "<input name=\"repo_dir\" required placeholder=\"~/MyBannerlordMod\" autocomplete=\"off\">"
            "</div>"
            "<label>Module directory</label>"
            "<div class=\"input-row\">"
            "<input name=\"module_dir\" required placeholder=\"module or MBWarlords.MyMod\" autocomplete=\"off\">"
            "</div>"
            "<label>Module name</label>"
            "<div class=\"input-row\">"
            "<input name=\"module_name\" required pattern=\"[A-Za-z0-9._-]+\" placeholder=\"MBWarlords.MyMod\" autocomplete=\"off\">"
            "<button class=\"button\" type=\"submit\">Save custom mod</button>"
            "</div>"
            "<p class=\"muted tiny\">Saving creates or replaces the entry for that module name only. It does not delete repo files or installed game files.</p>"
            "</form>"
        )

    def _render_status_list(self, items: List[Tuple[str, str]]) -> str:
        rows = []
        for label, value in items:
            rows.append(f"<dt>{html.escape(label)}</dt><dd>{html.escape(value or 'n/a')}</dd>")

        return f"<dl class=\"meta\">{''.join(rows)}</dl>"

    def _render_card(self, label: str, value: str, subtitle: str) -> str:
        return (
            "<div class=\"card\">"
            f"<h2>{html.escape(label)}</h2>"
            f"<div class=\"value\">{html.escape(value)}</div>"
            f"<p>{html.escape(subtitle)}</p>"
            "</div>"
        )

    def _render_pre(self, text: str) -> str:
        return f"<pre>{html.escape(render_log_text(text))}</pre>"

    def _render_auth_controls(self) -> str:
        if not self.auth_enabled():
            return ""

        return (
            "<span class=\"badge warn\">Password Protected</span>"
            "<form class=\"inline\" method=\"post\" action=\"/logout\">"
            "<button class=\"button secondary\" type=\"submit\">Log out</button>"
            "</form>"
        )

    def _render_post_button(self, action: str, label: str, next_path: str, disabled: bool = False, style: str = "") -> str:
        class_name = "button"
        if style == "secondary":
            class_name += " secondary"
        if style == "danger":
            class_name += " danger"

        disabled_attr = " disabled" if disabled else ""
        return (
            f"<form class=\"inline\" method=\"post\" action=\"{html.escape(action)}\">"
            f"<input type=\"hidden\" name=\"next\" value=\"{html.escape(next_path)}\">"
            f"<button class=\"{class_name}\" type=\"submit\"{disabled_attr}>{html.escape(label)}</button>"
            "</form>"
        )

    def _render_blacklist_ip_button(self, action: str, label: str, ip: str, style: str = "") -> str:
        class_name = "button"
        if style == "secondary":
            class_name += " secondary"
        if style == "danger":
            class_name += " danger"

        return (
            f"<form class=\"inline\" method=\"post\" action=\"{html.escape(action)}\">"
            "<input type=\"hidden\" name=\"next\" value=\"/firewall/\">"
            f"<input type=\"hidden\" name=\"ip\" value=\"{html.escape(ip)}\">"
            f"<button class=\"{class_name}\" type=\"submit\">{html.escape(label)}</button>"
            "</form>"
        )

    def _render_badge(self, value: str) -> str:
        normalized = (value or "").lower()
        css = "warn"
        if normalized in {"active", "enabled", "valid", "yes", "ok"}:
            css = "good"
        elif normalized in {"invalid", "inactive", "disabled", "missing", "no", "failed", "error"}:
            css = "bad"

        return f"<span class=\"badge {css}\">{html.escape(value or 'n/a')}</span>"

    def _nav_link(self, href: str, label: str, active: bool) -> str:
        class_name = "active" if active else ""
        return f"<a class=\"{class_name}\" href=\"{html.escape(href)}\">{html.escape(label)}</a>"

    def _query_value(self, query: Dict[str, List[str]], key: str) -> str:
        values = query.get(key) or []
        return values[0] if values else ""


class HostForgeHandler(BaseHTTPRequestHandler):
    collector: Optional[HostForgeCollector] = None
    web_app: Optional[HostForgeWebApp] = None

    def do_GET(self) -> None:
        path = urlsplit(self.path).path or "/"
        query = parse_qs(urlsplit(self.path).query)

        if path == "/healthz":
            self._send_bytes(HTTPStatus.OK, b"ok\n", "text/plain; charset=utf-8")
            return

        assert self.collector is not None
        assert self.web_app is not None

        if path == "/login":
            if self._is_authenticated():
                self._redirect("/")
                return

            next_path = self._sanitize_next(self._query_value(query, "next") or "/")
            self._send_html(HTTPStatus.OK, self.web_app.render_login_page(query, next_path))
            return

        if self.web_app.auth_enabled() and not self._is_authenticated():
            self._redirect(f"/login?{urlencode({'next': self.path})}")
            return

        static_path, content_type = self.collector.serve_static_path(self.path)
        if static_path is not None and static_path.exists():
            self._send_bytes(HTTPStatus.OK, static_path.read_bytes(), content_type)
            return

        if path == "/":
            self._send_html(HTTPStatus.OK, self.web_app.render_dashboard(query))
            return

        if path == "/profiles" or path == "/profiles/":
            self._send_html(HTTPStatus.OK, self.web_app.render_profiles_page(query))
            return

        if path == "/firewall" or path == "/firewall/":
            self._send_html(HTTPStatus.OK, self.web_app.render_firewall_page(query))
            return

        if path == "/repos" or path == "/repos/":
            self._send_html(HTTPStatus.OK, self.web_app.render_repo_page(query))
            return

        if path == "/logs/collector" or path == "/logs/collector/":
            self._send_html(HTTPStatus.OK, self.web_app.render_collector_logs_page(query))
            return

        if path == "/dumps" or path == "/dumps/":
            self._send_html(HTTPStatus.OK, self.web_app.render_dumps_page(query))
            return

        dump_profile_redirect_match = re.fullmatch(r"/dumps/([^/]+)", path)
        if dump_profile_redirect_match is not None:
            profile = normalize_instance_id(unquote(dump_profile_redirect_match.group(1)))
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("Location", f"/dumps/{quote(profile)}/")
            self.end_headers()
            return

        dump_profile_match = re.fullmatch(r"/dumps/([^/]+)/", path)
        if dump_profile_match is not None:
            profile = normalize_instance_id(unquote(dump_profile_match.group(1)))
            self._send_html(HTTPStatus.OK, self.web_app.render_dumps_page(query, profile))
            return

        profile_redirect_match = re.fullmatch(r"/profiles/([^/]+)", path)
        if profile_redirect_match is not None:
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("Location", f"/profiles/{quote(normalize_instance_id(unquote(profile_redirect_match.group(1))))}/")
            self.end_headers()
            return

        profile_logs_redirect_match = re.fullmatch(r"/profiles/([^/]+)/logs", path)
        if profile_logs_redirect_match is not None:
            profile = normalize_instance_id(unquote(profile_logs_redirect_match.group(1)))
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("Location", f"/profiles/{quote(profile)}/logs/")
            self.end_headers()
            return

        profile_match = re.fullmatch(r"/profiles/([^/]+)/", path)
        if profile_match is not None:
            profile = normalize_instance_id(unquote(profile_match.group(1)))
            page = self.web_app.render_profile_page(profile, query)
            status = HTTPStatus.NOT_FOUND if "Profile not found" in page else HTTPStatus.OK
            self._send_html(status, page)
            return

        profile_logs_match = re.fullmatch(r"/profiles/([^/]+)/logs/", path)
        if profile_logs_match is not None:
            profile = normalize_instance_id(unquote(profile_logs_match.group(1)))
            page = self.web_app.render_profile_logs_page(profile, query)
            status = HTTPStatus.NOT_FOUND if "Profile not found" in page else HTTPStatus.OK
            self._send_html(status, page)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self) -> None:
        path = urlsplit(self.path).path or "/"

        if path == "/v1/logs":
            self._handle_ingest()
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(content_length) if content_length > 0 else b""
        form = parse_qs(raw_body.decode("utf-8", errors="replace"))

        assert self.web_app is not None

        if path == "/login":
            self._handle_login(form)
            return

        if path == "/logout":
            self._handle_logout()
            return

        if self.web_app.auth_enabled() and not self._is_authenticated():
            self._redirect(f"/login?{urlencode({'next': self.path})}")
            return

        if path == "/dumps/clear":
            result = self.web_app.controller.clear_dumps()
            self._redirect_with_action_result(self.web_app.action_redirect("/dumps/", form), result)
            return

        clear_profile_dumps_match = re.fullmatch(r"/dumps/([^/]+)/clear", path)
        if clear_profile_dumps_match is not None:
            profile = normalize_instance_id(unquote(clear_profile_dumps_match.group(1)))
            result = self.web_app.controller.clear_dumps(profile)
            self._redirect_with_action_result(self.web_app.action_redirect(f"/dumps/{quote(profile)}/", form), result)
            return

        if path == "/services/refresh":
            result = self.web_app.controller.refresh_services()
            self._redirect_with_action_result(self.web_app.action_redirect("/", form), result)
            return

        if path == "/bannerlord/update":
            result = self.web_app.controller.update_bannerlord()
            self._redirect_with_action_result(self.web_app.action_redirect("/", form), result)
            return

        if path == "/logs/collector/restart":
            result = self.web_app.controller.collector_restart()
            self._redirect_with_action_result(self.web_app.action_redirect("/logs/collector/", form), result)
            return

        if path == "/firewall/start":
            result = self.web_app.controller.firewall_start()
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/firewall/stop":
            result = self.web_app.controller.firewall_stop()
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/firewall/restart":
            result = self.web_app.controller.firewall_restart()
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/firewall/geo/save":
            country = self._query_value(form, "country")
            cidrs = self._query_value(form, "cidrs")
            result = self.web_app.controller.firewall_geo_save(country, cidrs)
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/firewall/geo/apply":
            result = self.web_app.controller.firewall_geo_apply()
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/firewall/blacklist/clear":
            result = self.web_app.controller.firewall_blacklist_clear()
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/firewall/blacklist/add":
            ip = self._query_value(form, "ip")
            result = self.web_app.controller.firewall_blacklist_add(ip)
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/firewall/blacklist/remove":
            ip = self._query_value(form, "ip")
            result = self.web_app.controller.firewall_blacklist_remove(ip)
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        firewall_geo_delete_match = re.fullmatch(r"/firewall/geo/([^/]+)/delete", path)
        if firewall_geo_delete_match is not None:
            country = unquote(firewall_geo_delete_match.group(1))
            result = self.web_app.controller.firewall_geo_delete(country)
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        firewall_blacklist_add_match = re.fullmatch(r"/firewall/blacklist/([^/]+)/add", path)
        if firewall_blacklist_add_match is not None:
            ip = unquote(firewall_blacklist_add_match.group(1))
            result = self.web_app.controller.firewall_blacklist_add(ip)
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        firewall_blacklist_remove_match = re.fullmatch(r"/firewall/blacklist/([^/]+)/remove", path)
        if firewall_blacklist_remove_match is not None:
            ip = unquote(firewall_blacklist_remove_match.group(1))
            result = self.web_app.controller.firewall_blacklist_remove(ip)
            self._redirect_with_action_result(self.web_app.action_redirect("/firewall/", form), result)
            return

        if path == "/repos/pull-hostforge":
            result = self.web_app.controller.repo_pull_hostforge()
            self._redirect_with_action_result(self.web_app.action_redirect("/repos/", form), result)
            return

        if path == "/repos/sync-hostforge-module":
            result = self.web_app.controller.repo_sync_hostforge_module()
            self._redirect_with_action_result(self.web_app.action_redirect("/repos/", form), result)
            return

        if path == "/repos/update-hostforge-module":
            result = self.web_app.controller.repo_update_hostforge_module()
            self._redirect_with_action_result(self.web_app.action_redirect("/repos/", form), result)
            return

        if path == "/repos/custom-mods/save":
            repo_dir = self._query_value(form, "repo_dir")
            module_dir = self._query_value(form, "module_dir")
            module_name = self._query_value(form, "module_name")
            result = self.web_app.controller.custom_mod_save(repo_dir, module_dir, module_name)
            self._redirect_with_action_result(self.web_app.action_redirect("/repos/", form), result)
            return

        custom_mod_action_match = re.fullmatch(r"/repos/custom-mods/([^/]+)/(pull|sync|update|delete)", path)
        if custom_mod_action_match is not None:
            key = unquote(custom_mod_action_match.group(1))
            action = custom_mod_action_match.group(2)
            if action == "pull":
                result = self.web_app.controller.custom_mod_pull(key)
            elif action == "sync":
                result = self.web_app.controller.custom_mod_sync(key)
            elif action == "update":
                result = self.web_app.controller.custom_mod_update(key)
            else:
                result = self.web_app.controller.custom_mod_delete(key)
            self._redirect_with_action_result(self.web_app.action_redirect("/repos/", form), result)
            return

        if path == "/profiles/save":
            profile = normalize_profile_name(self._query_value(form, "profile"))
            params_text = self._query_value(form, "params")
            config_text = self._query_value(form, "config")
            result = self.web_app.controller.save_profile_files(profile, params_text, config_text)
            redirect_target = f"/profiles/{quote(profile)}/" if result.ok and profile else "/profiles/"
            self._redirect_with_action_result(self.web_app.action_redirect(redirect_target, form), result)
            return

        save_profile_match = re.fullmatch(r"/profiles/([^/]+)/save", path)
        if save_profile_match is not None:
            profile = normalize_profile_name(unquote(save_profile_match.group(1)))
            params_text = self._query_value(form, "params")
            config_text = self._query_value(form, "config")
            result = self.web_app.controller.save_profile_files(profile, params_text, config_text)
            self._redirect_with_action_result(self.web_app.action_redirect(f"/profiles/{quote(profile)}/", form), result)
            return

        delete_profile_match = re.fullmatch(r"/profiles/([^/]+)/delete", path)
        if delete_profile_match is not None:
            profile = normalize_profile_name(unquote(delete_profile_match.group(1)))
            result = self.web_app.controller.delete_profile_files(profile)
            redirect_target = "/profiles/" if result.ok else f"/profiles/{quote(profile)}/"
            self._redirect_with_action_result(self.web_app.action_redirect(redirect_target, form), result)
            return

        activate_match = re.fullmatch(r"/profiles/([^/]+)/activate", path)
        if activate_match is not None:
            profile = normalize_instance_id(unquote(activate_match.group(1)))
            result = self.web_app.controller.activate_profile(profile)
            self._redirect_with_action_result(self.web_app.action_redirect(f"/profiles/{quote(profile)}/", form), result)
            return

        deactivate_match = re.fullmatch(r"/profiles/([^/]+)/deactivate", path)
        if deactivate_match is not None:
            profile = normalize_instance_id(unquote(deactivate_match.group(1)))
            result = self.web_app.controller.deactivate_profile(profile)
            self._redirect_with_action_result(self.web_app.action_redirect(f"/profiles/{quote(profile)}/", form), result)
            return

        restart_match = re.fullmatch(r"/profiles/([^/]+)/restart", path)
        if restart_match is not None:
            profile = normalize_instance_id(unquote(restart_match.group(1)))
            result = self.web_app.controller.restart_profile(profile)
            self._redirect_with_action_result(self.web_app.action_redirect(f"/profiles/{quote(profile)}/", form), result)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "not found")

    def _handle_ingest(self) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length <= 0:
            self.send_error(HTTPStatus.BAD_REQUEST, "body is required")
            return

        raw_body = self.rfile.read(content_length)
        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_error(HTTPStatus.BAD_REQUEST, "invalid json")
            return

        assert self.collector is not None
        try:
            instance_id, timestamp = self.collector.ingest_log(payload)
        except ValueError as exc:
            self.send_error(HTTPStatus.BAD_REQUEST, str(exc))
            return

        response = json.dumps({"instanceId": instance_id, "timestamp": timestamp, "status": "accepted"}).encode("utf-8")
        self._send_bytes(HTTPStatus.ACCEPTED, response, "application/json; charset=utf-8")

    def _redirect_with_action_result(self, path: str, result: ActionResult) -> None:
        assert self.web_app is not None
        flash_id = self.web_app.create_flash_message(
            result.message,
            "success" if result.ok else "error",
            result.output,
        )
        separator = "&" if "?" in path else "?"
        target = f"{path}{separator}{urlencode({'flash': flash_id})}"
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", target)
        self.end_headers()

    def _handle_login(self, form: Dict[str, List[str]]) -> None:
        assert self.web_app is not None

        password = self._query_value(form, "password")
        next_path = self._sanitize_next(self._query_value(form, "next") or "/")
        if self.web_app.authenticate_password(password):
            session_token = self.web_app.create_session()
            self.send_response(HTTPStatus.SEE_OTHER)
            self.send_header("Location", next_path)
            self.send_header(
                "Set-Cookie",
                f"hostforge_session={session_token}; Path=/; HttpOnly; SameSite=Lax; Max-Age={self.web_app.config.web_session_ttl_seconds}",
            )
            self.end_headers()
            return

        target = self.web_app.redirect_with_notice(
            f"/login?{urlencode({'next': next_path})}",
            "Incorrect password.",
            "error",
        )
        self._redirect(target)

    def _handle_logout(self) -> None:
        assert self.web_app is not None

        session_token = self._session_token()
        self.web_app.invalidate_session(session_token)
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", "/login")
        self.send_header("Set-Cookie", "hostforge_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0")
        self.end_headers()

    def _send_html(self, status: HTTPStatus, document: str) -> None:
        self._send_bytes(status, document.encode("utf-8"), "text/html; charset=utf-8")

    def _send_bytes(self, status: HTTPStatus, payload: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        if content_type == "application/octet-stream":
            file_name = Path(unquote(urlsplit(self.path).path)).name
            self.send_header("Content-Disposition", f"attachment; filename=\"{file_name}\"")
        self.end_headers()
        self.wfile.write(payload)

    def _redirect(self, target: str) -> None:
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", target)
        self.end_headers()

    def _is_authenticated(self) -> bool:
        assert self.web_app is not None
        return self.web_app.is_authenticated(self._session_token())

    def _session_token(self) -> str:
        raw_cookie = self.headers.get("Cookie", "")
        if not raw_cookie:
            return ""

        cookie = SimpleCookie()
        try:
            cookie.load(raw_cookie)
        except Exception:
            return ""

        morsel = cookie.get("hostforge_session")
        return "" if morsel is None else morsel.value

    def _query_value(self, query: Dict[str, List[str]], key: str) -> str:
        values = query.get(key) or []
        return values[0] if values else ""

    def _sanitize_next(self, path: str) -> str:
        candidate = path or "/"
        if not candidate.startswith("/"):
            return "/"

        if candidate.startswith("//"):
            return "/"

        return candidate

    def log_message(self, format_string: str, *args) -> None:
        sys.stdout.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format_string % args))


def build_config(args: argparse.Namespace) -> CollectorConfig:
    default_title = f"HostForge - {socket.gethostname()}"
    bind = args.bind or os.environ.get("HF_COLLECTOR_BIND", "0.0.0.0")
    port = args.port or int(os.environ.get("HF_COLLECTOR_PORT", "8080"))
    data_dir = Path(args.data_dir or os.environ.get("HF_COLLECTOR_DATA_DIR", str(Path.cwd() / "logs"))).resolve()
    tail_line_count = args.tail_lines or int(os.environ.get("HF_COLLECTOR_TAIL_LINES", "200"))
    max_log_bytes = args.max_log_bytes or int(os.environ.get("HF_COLLECTOR_MAX_LOG_BYTES", "5242880"))
    site_title = args.site_title or os.environ.get("HF_COLLECTOR_SITE_TITLE", default_title)
    repo_dir = Path(os.environ.get("HF_REPO_DIR", str(find_repo_dir(data_dir)))).resolve()
    hostforge_script = Path(os.environ.get("HF_HOSTFORGE_SCRIPT", str(repo_dir / "hostforge.sh"))).resolve()
    web_password = os.environ.get("HF_WEB_PASSWORD", "")
    web_session_ttl_seconds = int(os.environ.get("HF_WEB_SESSION_TTL_SECONDS", "43200"))
    return CollectorConfig(
        bind,
        port,
        data_dir,
        tail_line_count,
        max_log_bytes,
        site_title,
        repo_dir,
        hostforge_script,
        web_password,
        web_session_ttl_seconds,
    )


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="HostForge web control plane and log collector")
    parser.add_argument("--bind", help="HTTP bind address")
    parser.add_argument("--port", type=int, help="HTTP port")
    parser.add_argument("--data-dir", help="Collector data directory")
    parser.add_argument("--tail-lines", type=int, help="Lines to show in generated pages")
    parser.add_argument("--max-log-bytes", type=int, help="Rotate current.log when it reaches this size")
    parser.add_argument("--site-title", help="HTML page title")
    parser.add_argument("--rebuild", action="store_true", help="Rebuild instance HTML indexes and exit")
    return parser.parse_args(argv)


def run_server(config: CollectorConfig) -> int:
    collector = HostForgeCollector(config)
    controller = HostForgeController(config)
    collector.rebuild_all()
    HostForgeHandler.collector = collector
    HostForgeHandler.web_app = HostForgeWebApp(config, collector, controller)
    server = ThreadingHTTPServer((config.bind, config.port), HostForgeHandler)

    print(f"HostForge listening on http://{config.bind}:{config.port}/")
    print(f"Using repo {config.repo_dir}")
    print(f"Writing logs under {config.data_dir}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("HostForge stopped.")
    finally:
        server.server_close()

    return 0


def rebuild_only(config: CollectorConfig) -> int:
    collector = HostForgeCollector(config)
    collector.rebuild_all()
    print(f"Rebuilt instance log pages under {config.data_dir}")
    return 0


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    config = build_config(args)
    if args.rebuild:
        return rebuild_only(config)

    return run_server(config)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
