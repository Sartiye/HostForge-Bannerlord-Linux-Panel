#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$REPO_DIR/app"
CONFIG_DIR="$REPO_DIR/configs"
ENV_FILE="${HF_ENV_FILE:-$CONFIG_DIR/hostforge.env}"
SERVICE_TEMPLATE="$REPO_DIR/services/hostforge@.service"
COLLECTOR_SERVICE_TEMPLATE="$REPO_DIR/services/hostforge-collector.service"
CLOUDFLARED_QUICK_SERVICE_TEMPLATE="$REPO_DIR/services/hostforge-cloudflared-quick.service"
FIREWALL_SERVICE_TEMPLATE="$REPO_DIR/services/hostforge-firewall.service"
COLLECTOR_SCRIPT="$APP_DIR/hostforge_collector.py"
SYSTEMD_DIR="/etc/systemd/system"
SYSTEMD_TEMPLATE_PATH="$SYSTEMD_DIR/hostforge@.service"
COLLECTOR_SYSTEMD_PATH="$SYSTEMD_DIR/hostforge-collector.service"
CLOUDFLARED_QUICK_SYSTEMD_PATH="$SYSTEMD_DIR/hostforge-cloudflared-quick.service"
FIREWALL_SYSTEMD_PATH="$SYSTEMD_DIR/hostforge-firewall.service"
SUDOERS_PATH="/etc/sudoers.d/hostforge"

if [[ -f "$ENV_FILE" ]]; then
  # Load optional host-local overrides such as sibling repo paths.
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

export PATH="/opt/wine-stable/bin:$PATH"

DEFAULT_BANNERLORD_ROOT="$HOME/.steam/steam/steamapps/common/Mount & Blade II Dedicated Server"
DEFAULT_WINE_CMD="${HF_WINE_CMD:-}"
DEFAULT_WINE_PREFIX_BASE="${HF_WINEPREFIX_BASE:-$HOME/.wine-hostforge}"
DEFAULT_WINE_PREFIX_TEMPLATE="${HF_WINEPREFIX_TEMPLATE:-$HOME/.wine-hostforge}"
DEFAULT_WINE_DEBUG="${HF_WINEDEBUG:-err+all,warn-all,fixme-all}"
DEFAULT_WINE_DLL_OVERRIDES="${HF_WINEDLLOVERRIDES:-winedbg.exe=d;winemenubuilder.exe=d}"
DEFAULT_WINE_LOG_DIR="${HF_WINE_LOG_DIR:-$REPO_DIR/logs/wine}"
DEFAULT_WINE_DESKTOP_SIZE="${HF_WINE_DESKTOP_SIZE:-1280x720}"
DEFAULT_DOTNET_DUMP_ENABLED="${HF_DOTNET_DUMP_ENABLED:-1}"
DEFAULT_DOTNET_DUMP_TYPE="${HF_DOTNET_DUMP_TYPE:-4}"
DEFAULT_DOTNET_DUMP_DIR="${HF_DOTNET_DUMP_DIR:-$REPO_DIR/logs/dumps}"
DEFAULT_STEAM_APP_ID="${HF_STEAM_APP_ID:-1863440}"
DEFAULT_COLLECTOR_PORT="${HF_COLLECTOR_PORT:-8080}"
DEFAULT_COLLECTOR_BIND="${HF_COLLECTOR_BIND:-0.0.0.0}"
DEFAULT_CLOUDFLARED_ORIGIN_URL="${HF_CLOUDFLARED_ORIGIN_URL:-http://localhost:8080}"
DEFAULT_HOSTFORGE_MODULE_DIR="${HF_HOSTFORGE_MODULE_DIR:-$REPO_DIR/module-hostforge}"
DEFAULT_CUSTOM_MODS_FILE="${HF_CUSTOM_MODS_FILE:-$CONFIG_DIR/custom-mods.tsv}"
DEFAULT_FIREWALL_SET="${HF_FIREWALL_SET:-hostforge_players}"
DEFAULT_FIREWALL_BLACKLIST_SET="${HF_FIREWALL_BLACKLIST_SET:-hostforge_blacklist}"
DEFAULT_FIREWALL_PENDING_SET="${HF_FIREWALL_PENDING_SET:-hostforge_pending_players}"
DEFAULT_FIREWALL_VERIFIED_SET="${HF_PLAYER_IPSET_NAME:-hostforge_verified_players}"
DEFAULT_FIREWALL_INGRESS_CHAIN="${HF_FIREWALL_INGRESS_CHAIN:-HOSTFORGE_INGRESS}"
DEFAULT_FIREWALL_CHAIN="${HF_FIREWALL_CHAIN:-HOSTFORGE_PLAYERS}"
DEFAULT_FIREWALL_BLACKLIST_CHAIN="${HF_FIREWALL_BLACKLIST_CHAIN:-HOSTFORGE_BLACKLIST}"
DEFAULT_FIREWALL_ADMISSION_CHAIN="${HF_FIREWALL_ADMISSION_CHAIN:-HOSTFORGE_ADMISSION}"
DEFAULT_FIREWALL_GEO_SET="${HF_FIREWALL_GEO_SET:-hostforge_geo_block}"
DEFAULT_FIREWALL_GEO_CHAIN="${HF_FIREWALL_GEO_CHAIN:-HOSTFORGE_GEO_BLOCK}"
DEFAULT_FIREWALL_GEO_DIR="${HF_FIREWALL_GEO_DIR:-$CONFIG_DIR/firewall-geo}"
DEFAULT_FIREWALL_IPSET_TIMEOUT="${HF_FIREWALL_IPSET_TIMEOUT:-3600}"
DEFAULT_FIREWALL_PENDING_MAX="${HF_FIREWALL_PENDING_MAX:-50}"
DEFAULT_FIREWALL_PENDING_TIMEOUT="${HF_FIREWALL_PENDING_TIMEOUT:-30}"
DEFAULT_FIREWALL_VERIFIED_TIMEOUT="${HF_PLAYER_IPSET_TIMEOUT_SECONDS:-90}"
DEFAULT_FIREWALL_VERIFIED_MAX="${HF_PLAYER_IPSET_MAX_ENTRIES:-4096}"
DEFAULT_FIREWALL_BLACKLIST_PPS="${HF_FIREWALL_BLACKLIST_PPS:-3000}"
DEFAULT_FIREWALL_BLACKLIST_BURST="${HF_FIREWALL_BLACKLIST_BURST:-9000}"
DEFAULT_FIREWALL_HASHLIMIT_NAME="${HF_FIREWALL_HASHLIMIT_NAME:-hf_pps}"
DEFAULT_FIREWALL_BLACKLIST_BPS="${HF_FIREWALL_BLACKLIST_BPS:-512kb/s}"
DEFAULT_FIREWALL_BLACKLIST_BPS_BURST="${HF_FIREWALL_BLACKLIST_BPS_BURST:-2mb}"
DEFAULT_FIREWALL_HASHLIMIT_BPS_NAME="${HF_FIREWALL_HASHLIMIT_BPS_NAME:-hf_bps}"
DEFAULT_FIREWALL_HASHLIMIT_HTABLE_SIZE="${HF_FIREWALL_HASHLIMIT_HTABLE_SIZE:-1024}"
DEFAULT_FIREWALL_HASHLIMIT_HTABLE_MAX="${HF_FIREWALL_HASHLIMIT_HTABLE_MAX:-4096}"
DEFAULT_FIREWALL_HASHLIMIT_HTABLE_EXPIRE_MS="${HF_FIREWALL_HASHLIMIT_HTABLE_EXPIRE_MS:-2000}"
DEFAULT_FIREWALL_HASHLIMIT_HTABLE_GCINTERVAL_MS="${HF_FIREWALL_HASHLIMIT_HTABLE_GCINTERVAL_MS:-1000}"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

expand_path() {
  local path_value
  path_value="$(trim "$1")"

  case "$path_value" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${path_value#\~/}"
      ;;
    *)
      printf '%s\n' "$path_value"
      ;;
  esac
}

bannerlord_root() {
  local root_value

  if [[ -n "${BANNERLORD_ROOT:-}" ]]; then
    root_value="$BANNERLORD_ROOT"
  else
    root_value="$DEFAULT_BANNERLORD_ROOT"
  fi

  expand_path "$root_value"
}

params_file_for() {
  printf '%s/ds_params_%s.txt\n' "$CONFIG_DIR" "$1"
}

config_file_for() {
  printf '%s/ds_config_%s.txt\n' "$CONFIG_DIR" "$1"
}

validate_profile_key() {
  local profile="$1"

  if [[ -z "$profile" ]]; then
    echo "[ERROR] Profile name is required."
    return 1
  fi

  if [[ ! "$profile" =~ ^[a-z0-9._-]+$ ]]; then
    echo "[ERROR] Invalid profile name: $profile"
    echo "Use lowercase letters, numbers, dot, underscore, or dash only."
    return 1
  fi
}

profile_has_params() {
  [[ -f "$(params_file_for "$1")" ]]
}

profile_has_config() {
  [[ -f "$(config_file_for "$1")" ]]
}

profile_is_valid() {
  profile_has_params "$1" && profile_has_config "$1"
}

discover_profiles() {
  shopt -s nullglob

  {
    local file base
    for file in "$CONFIG_DIR"/ds_params_*.txt; do
      base="$(basename "$file")"
      printf '%s\n' "${base#ds_params_}"
    done

    for file in "$CONFIG_DIR"/ds_config_*.txt; do
      base="$(basename "$file")"
      printf '%s\n' "${base#ds_config_}"
    done
  } | sed -e 's/\.txt$//' -e '/^$/d' | sort -u

  shopt -u nullglob
}

systemctl_available() {
  command -v systemctl >/dev/null 2>&1
}

journalctl_available() {
  command -v journalctl >/dev/null 2>&1
}

python3_available() {
  command -v python3 >/dev/null 2>&1
}

unit_name_for() {
  printf 'hostforge@%s.service\n' "$1"
}

collector_unit_name() {
  printf 'hostforge-collector.service\n'
}

firewall_unit_name() {
  printf 'hostforge-firewall.service\n'
}

hostforge_module_source_dir() {
  expand_path "${HF_HOSTFORGE_MODULE_DIR:-$DEFAULT_HOSTFORGE_MODULE_DIR}"
}

hostforge_module_name() {
  printf '%s\n' "${HF_HOSTFORGE_MODULE_NAME:-MBWarlords.HostForge}"
}

custom_mods_file() {
  expand_path "${HF_CUSTOM_MODS_FILE:-$DEFAULT_CUSTOM_MODS_FILE}"
}

custom_mod_key() {
  local value="$1"
  value="$(trim "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9._-]+/-/g; s/^[-._]+//; s/[-._]+$//')"
  printf '%s\n' "$value"
}

valid_module_name() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
}

resolve_custom_mod_source_dir() {
  local repo_dir="$1"
  local module_dir="$2"

  case "$module_dir" in
    "~"|"~/"*|/*)
      expand_path "$module_dir"
      ;;
    *)
      printf '%s/%s\n' "$(expand_path "$repo_dir")" "$module_dir"
      ;;
  esac
}

service_enabled_state() {
  local profile="$1"

  if ! systemctl_available; then
    printf 'n/a\n'
    return
  fi

  if systemctl is-enabled "$(unit_name_for "$profile")" >/dev/null 2>&1; then
    printf 'enabled\n'
    return
  fi

  if systemctl is-enabled "$(unit_name_for "$profile")" 2>/dev/null | grep -q "disabled"; then
    printf 'disabled\n'
    return
  fi

  printf 'missing\n'
}

unit_enabled_state() {
  local unit_name="$1"

  if ! systemctl_available; then
    printf 'n/a\n'
    return
  fi

  if systemctl is-enabled "$unit_name" >/dev/null 2>&1; then
    printf 'enabled\n'
    return
  fi

  if systemctl is-enabled "$unit_name" 2>/dev/null | grep -q "disabled"; then
    printf 'disabled\n'
    return
  fi

  printf 'missing\n'
}

service_active_state() {
  local profile="$1"

  if ! systemctl_available; then
    printf 'n/a\n'
    return
  fi

  if systemctl is-active "$(unit_name_for "$profile")" >/dev/null 2>&1; then
    printf 'active\n'
  else
    printf 'inactive\n'
  fi
}

unit_active_state() {
  local unit_name="$1"

  if ! systemctl_available; then
    printf 'n/a\n'
    return
  fi

  if systemctl is-active "$unit_name" >/dev/null 2>&1; then
    printf 'active\n'
  else
    printf 'inactive\n'
  fi
}

profile_port() {
  local file
  file="$(params_file_for "$1")"

  if [[ ! -f "$file" ]]; then
    return
  fi

  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*[#;]/ { next }
    tolower($1) == "/port" { print $2; exit }
  ' "$file"
}

config_value() {
  local profile="$1"
  local key="$2"
  local file
  file="$(config_file_for "$profile")"

  if [[ ! -f "$file" ]]; then
    return
  fi

  awk -v key="$key" '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*[#;]/ { next }
    $1 == key {
      $1=""
      sub(/^[[:space:]]+/, "", $0)
      print $0
      exit
    }
  ' "$file"
}

profile_server_name() {
  config_value "$1" "ServerName"
}

profile_game_type() {
  config_value "$1" "GameType"
}

profile_health() {
  if profile_is_valid "$1"; then
    printf 'valid\n'
  else
    printf 'invalid\n'
  fi
}

sudo_run() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  elif [[ "${HF_SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
    sudo -n "$@"
  else
    sudo "$@"
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

service_user() {
  printf '%s\n' "${HF_SERVICE_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
}

service_user_home() {
  local target_user passwd_home
  target_user="$(service_user)"

  if command -v getent >/dev/null 2>&1; then
    passwd_home="$(getent passwd "$target_user" | awk -F: 'NR == 1 { print $6 }' || true)"
    if [[ -n "$passwd_home" ]]; then
      printf '%s\n' "$passwd_home"
      return
    fi
  fi

  printf '%s\n' "$HOME"
}

collector_port() {
  printf '%s\n' "${HF_COLLECTOR_PORT:-$DEFAULT_COLLECTOR_PORT}"
}

collector_bind() {
  printf '%s\n' "${HF_COLLECTOR_BIND:-$DEFAULT_COLLECTOR_BIND}"
}

collector_public_host() {
  local bind_value hostname_value

  bind_value="$(collector_bind)"
  if [[ "$bind_value" == "127.0.0.1" || "$bind_value" == "localhost" ]]; then
    printf '127.0.0.1\n'
    return
  fi

  hostname_value="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
  if [[ -n "$hostname_value" ]]; then
    printf '%s\n' "$hostname_value"
    return
  fi

  printf '%s\n' "$bind_value"
}

collector_public_url() {
  printf 'http://%s:%s/\n' "$(collector_public_host)" "$(collector_port)"
}

firewall_set_name() {
  printf '%s\n' "${HF_FIREWALL_SET:-$DEFAULT_FIREWALL_SET}"
}

firewall_blacklist_set_name() {
  printf '%s\n' "${HF_FIREWALL_BLACKLIST_SET:-$DEFAULT_FIREWALL_BLACKLIST_SET}"
}

firewall_pending_set_name() {
  printf '%s\n' "${HF_FIREWALL_PENDING_SET:-$DEFAULT_FIREWALL_PENDING_SET}"
}

firewall_verified_set_name() {
  printf '%s\n' "${HF_PLAYER_IPSET_NAME:-$DEFAULT_FIREWALL_VERIFIED_SET}"
}

firewall_ingress_chain_name() {
  printf '%s\n' "${HF_FIREWALL_INGRESS_CHAIN:-$DEFAULT_FIREWALL_INGRESS_CHAIN}"
}

firewall_chain_name() {
  printf '%s\n' "${HF_FIREWALL_CHAIN:-$DEFAULT_FIREWALL_CHAIN}"
}

firewall_blacklist_chain_name() {
  printf '%s\n' "${HF_FIREWALL_BLACKLIST_CHAIN:-$DEFAULT_FIREWALL_BLACKLIST_CHAIN}"
}

firewall_admission_chain_name() {
  printf '%s\n' "${HF_FIREWALL_ADMISSION_CHAIN:-$DEFAULT_FIREWALL_ADMISSION_CHAIN}"
}

firewall_geo_set_name() {
  printf '%s\n' "${HF_FIREWALL_GEO_SET:-$DEFAULT_FIREWALL_GEO_SET}"
}

firewall_geo_chain_name() {
  printf '%s\n' "${HF_FIREWALL_GEO_CHAIN:-$DEFAULT_FIREWALL_GEO_CHAIN}"
}

firewall_geo_dir() {
  expand_path "${HF_FIREWALL_GEO_DIR:-$DEFAULT_FIREWALL_GEO_DIR}"
}

firewall_ipset_timeout() {
  printf '%s\n' "${HF_FIREWALL_IPSET_TIMEOUT:-$DEFAULT_FIREWALL_IPSET_TIMEOUT}"
}

firewall_pending_max() {
  printf '%s\n' "${HF_FIREWALL_PENDING_MAX:-$DEFAULT_FIREWALL_PENDING_MAX}"
}

firewall_pending_timeout() {
  printf '%s\n' "${HF_FIREWALL_PENDING_TIMEOUT:-$DEFAULT_FIREWALL_PENDING_TIMEOUT}"
}

firewall_verified_timeout() {
  printf '%s\n' "${HF_PLAYER_IPSET_TIMEOUT_SECONDS:-$DEFAULT_FIREWALL_VERIFIED_TIMEOUT}"
}

firewall_verified_max() {
  printf '%s\n' "${HF_PLAYER_IPSET_MAX_ENTRIES:-$DEFAULT_FIREWALL_VERIFIED_MAX}"
}

firewall_blacklist_pps() {
  printf '%s\n' "${HF_FIREWALL_BLACKLIST_PPS:-$DEFAULT_FIREWALL_BLACKLIST_PPS}"
}

firewall_blacklist_burst() {
  printf '%s\n' "${HF_FIREWALL_BLACKLIST_BURST:-$DEFAULT_FIREWALL_BLACKLIST_BURST}"
}

firewall_hashlimit_name() {
  printf '%s\n' "${HF_FIREWALL_HASHLIMIT_NAME:-$DEFAULT_FIREWALL_HASHLIMIT_NAME}"
}

firewall_blacklist_bps() {
  printf '%s\n' "${HF_FIREWALL_BLACKLIST_BPS:-$DEFAULT_FIREWALL_BLACKLIST_BPS}"
}

firewall_blacklist_bps_burst() {
  printf '%s\n' "${HF_FIREWALL_BLACKLIST_BPS_BURST:-$DEFAULT_FIREWALL_BLACKLIST_BPS_BURST}"
}

firewall_hashlimit_bps_name() {
  printf '%s\n' "${HF_FIREWALL_HASHLIMIT_BPS_NAME:-$DEFAULT_FIREWALL_HASHLIMIT_BPS_NAME}"
}

firewall_hashlimit_htable_size() {
  printf '%s\n' "${HF_FIREWALL_HASHLIMIT_HTABLE_SIZE:-$DEFAULT_FIREWALL_HASHLIMIT_HTABLE_SIZE}"
}

firewall_hashlimit_htable_max() {
  printf '%s\n' "${HF_FIREWALL_HASHLIMIT_HTABLE_MAX:-$DEFAULT_FIREWALL_HASHLIMIT_HTABLE_MAX}"
}

firewall_hashlimit_htable_expire_ms() {
  printf '%s\n' "${HF_FIREWALL_HASHLIMIT_HTABLE_EXPIRE_MS:-$DEFAULT_FIREWALL_HASHLIMIT_HTABLE_EXPIRE_MS}"
}

firewall_hashlimit_htable_gcinterval_ms() {
  printf '%s\n' "${HF_FIREWALL_HASHLIMIT_HTABLE_GCINTERVAL_MS:-$DEFAULT_FIREWALL_HASHLIMIT_HTABLE_GCINTERVAL_MS}"
}

cloudflared_origin_url() {
  printf '%s\n' "${HF_CLOUDFLARED_ORIGIN_URL:-$DEFAULT_CLOUDFLARED_ORIGIN_URL}"
}

cloudflared_service_unit() {
  printf 'hostforge-cloudflared-quick.service\n'
}

cloudflared_available() {
  command -v cloudflared >/dev/null 2>&1
}

require_cloudflared() {
  if ! cloudflared_available; then
    echo "[ERROR] cloudflared is not installed. Run bash setup.sh first."
    return 1
  fi
}

cloudflared_status() {
  local quick_url
  quick_url="$(cloudflared_quick_url || true)"

  echo
  echo "=== Cloudflare Quick Tunnel ==="
  echo "Binary:        $(command -v cloudflared 2>/dev/null || echo 'not installed')"
  echo "Origin URL:    $(cloudflared_origin_url)"
  echo "Protocol:      ${HF_CLOUDFLARED_PROTOCOL:-http2}"
  echo "Public URL:    ${quick_url:-n/a}"

  if systemctl_available; then
    echo "Service enable: $(unit_enabled_state "$(cloudflared_service_unit)")"
    echo "Service state:  $(unit_active_state "$(cloudflared_service_unit)")"
  fi
}

cloudflared_start_service() {
  require_cloudflared || return 1
  require_systemctl || return 1
  require_python3 || return 1
  install_service_template || return 1
  ensure_collector_running || return 1
  sudo_run systemctl enable --now "$(cloudflared_service_unit)"
  systemctl status "$(cloudflared_service_unit)" --no-pager -n 8 || true
  echo
  echo "Public URL: $(cloudflared_quick_url || printf 'pending; check logs in a few seconds')"
}

cloudflared_stop_service() {
  require_systemctl || return 1
  sudo_run systemctl disable --now "$(cloudflared_service_unit)" || true
  systemctl status "$(cloudflared_service_unit)" --no-pager -n 5 || true
}

cloudflared_restart_service() {
  require_systemctl || return 1
  sudo_run systemctl restart "$(cloudflared_service_unit)"
  systemctl status "$(cloudflared_service_unit)" --no-pager -n 8 || true
}

cloudflared_service_logs() {
  local lines="${1:-80}"

  if ! journalctl_available; then
    echo "[ERROR] journalctl is required for this action."
    return 1
  fi

  journalctl -u "$(cloudflared_service_unit)" -n "$lines" --no-pager || true
}

cloudflared_quick_url() {
  if ! journalctl_available || ! systemctl_available; then
    return
  fi

  journalctl -u "$(cloudflared_service_unit)" -n 200 --no-pager 2>/dev/null \
    | grep -Eo 'https://[[:alnum:]-]+\.trycloudflare\.com' \
    | tail -n 1
}

firewall_ports() {
  local profile port

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue
    port="$(profile_port "$profile" || true)"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$port"
    fi
  done < <(discover_profiles) | sort -n -u
}

firewall_port_groups() {
  local port group="" count=0

  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    group="${group:+$group,}$port"
    count=$((count + 1))

    if [[ "$count" -eq 15 ]]; then
      printf '%s\n' "$group"
      group=""
      count=0
    fi
  done < <(firewall_ports)

  if [[ -n "$group" ]]; then
    printf '%s\n' "$group"
  fi
}

require_firewall_tools() {
  local missing=0 command_name

  for command_name in iptables ipset; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "[ERROR] Required firewall command not found: $command_name"
      missing=1
    fi
  done

  [[ "$missing" -eq 0 ]]
}

firewall_country_code() {
  local value="$1"
  value="$(trim "$value" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "$value" | sed -E 's/[^a-z0-9_-]+/_/g; s/^_+//; s/_+$//')"
  printf '%s\n' "$value"
}

firewall_geo_country_path() {
  local country
  country="$(firewall_country_code "$1")"
  [[ -n "$country" ]] || return 1
  printf '%s/%s.txt\n' "$(firewall_geo_dir)" "$country"
}

firewall_geo_count_cidrs() {
  local file="$1"
  [[ -f "$file" ]] || {
    printf '0\n'
    return
  }

  awk '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*[#;]/ { next }
    { count++ }
    END { print count + 0 }
  ' "$file"
}

normalize_firewall_geo_cidrs() {
  local python_cmd
  python_cmd="$(find_command python3 python || true)"
  if [[ -z "$python_cmd" ]]; then
    echo "[ERROR] Python is required to validate geo CIDR lists." >&2
    return 1
  fi

  "$python_cmd" -c '
import ipaddress
import sys

bad = set()
for raw in sys.stdin:
    line = raw.strip()
    if not line or line.startswith("#") or line.startswith(";"):
        continue

    value = line.split()[0]
    try:
        network = ipaddress.ip_network(value, strict=False)
        if network.version != 4:
            raise ValueError("not IPv4")
    except ValueError:
        bad.add(value)
        continue

    if "/" in value:
        print(str(network))
    else:
        print(value)

for value in sorted(bad):
    print(f"[WARN] Ignored invalid CIDR: {value}", file=sys.stderr)
'
}

firewall_geo_list_countries() {
  local dir file country
  dir="$(firewall_geo_dir)"

  shopt -s nullglob
  for file in "$dir"/*.txt; do
    country="$(basename "$file" .txt)"
    printf 'country=%s cidrs=%s file=%s\n' "$country" "$(firewall_geo_count_cidrs "$file")" "$file"
  done | sort
  shopt -u nullglob
}

firewall_geo_save_country() {
  local country="$1"
  local cidr_text="${2:-}"
  local path tmp count

  country="$(firewall_country_code "$country")"
  if [[ -z "$country" ]]; then
    echo "[ERROR] Country key is required."
    return 1
  fi

  mkdir -p "$(firewall_geo_dir)"
  path="$(firewall_geo_country_path "$country")"
  tmp="$(mktemp)"

  printf '%s\n' "$cidr_text" \
    | tr -d '\r' \
    | normalize_firewall_geo_cidrs \
    | sort -u > "$tmp"

  count="$(firewall_geo_count_cidrs "$tmp")"
  if [[ "$count" -eq 0 ]]; then
    rm -f "$tmp"
    echo "[ERROR] No valid IPv4 CIDRs were provided for $country."
    return 1
  fi

  mv "$tmp" "$path"
  echo "[OK] Saved $count CIDRs for $country at $path"
  echo "Restart or apply the firewall for this country block to take effect."
}

firewall_geo_save_country_file() {
  local country="$1"
  local cidr_file="$2"
  local path tmp count

  country="$(firewall_country_code "$country")"
  if [[ -z "$country" ]]; then
    echo "[ERROR] Country key is required."
    return 1
  fi

  if [[ ! -f "$cidr_file" ]]; then
    echo "[ERROR] CIDR file not found: $cidr_file"
    return 1
  fi

  mkdir -p "$(firewall_geo_dir)"
  path="$(firewall_geo_country_path "$country")"
  tmp="$(mktemp)"

  tr -d '\r' < "$cidr_file" \
    | normalize_firewall_geo_cidrs \
    | sort -u > "$tmp"

  count="$(firewall_geo_count_cidrs "$tmp")"
  if [[ "$count" -eq 0 ]]; then
    rm -f "$tmp"
    echo "[ERROR] No valid IPv4 CIDRs were provided for $country."
    return 1
  fi

  mv "$tmp" "$path"
  echo "[OK] Saved $count CIDRs for $country at $path"
  echo "Restart or apply the firewall for this country block to take effect."
}

firewall_geo_delete_country() {
  local country="$1"
  local path

  country="$(firewall_country_code "$country")"
  if [[ -z "$country" ]]; then
    echo "[ERROR] Country key is required."
    return 1
  fi

  path="$(firewall_geo_country_path "$country")"
  rm -f "$path"
  echo "[OK] Removed geo country file for $country"
  echo "Restart or apply the firewall for this removal to take effect."
}

firewall_geo_restore_ipset() {
  local restore_file="$1"

  if [[ "${EUID}" -eq 0 ]]; then
    ipset restore -exist < "$restore_file"
  elif [[ "${HF_SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
    sudo -n ipset restore -exist < "$restore_file"
  else
    sudo ipset restore -exist < "$restore_file"
  fi
}

firewall_geo_load_set() {
  local set_name dir file restore_file cidr total
  set_name="$(firewall_geo_set_name)"
  dir="$(firewall_geo_dir)"
  total=0
  restore_file="$(mktemp)"

  {
    printf 'create %s hash:net family inet hashsize 262144 maxelem 1000000 counters -exist\n' "$set_name"
    printf 'flush %s\n' "$set_name"

    shopt -s nullglob
    for file in "$dir"/*.txt; do
      while IFS= read -r cidr; do
        cidr="$(trim "$cidr")"
        [[ -n "$cidr" ]] || continue
        [[ "$cidr" =~ ^[#\;] ]] && continue
        printf 'add %s %s -exist\n' "$set_name" "$cidr"
        total=$((total + 1))
      done < "$file"
    done
    shopt -u nullglob
  } > "$restore_file"

  firewall_geo_restore_ipset "$restore_file"
  rm -f "$restore_file"
  echo "[OK] Loaded $total geo CIDRs into $set_name"
}

firewall_chain_exists() {
  local table="$1"
  local chain="$2"
  sudo_run iptables -t "$table" -n -L "$chain" >/dev/null 2>&1
}

firewall_ensure_chain() {
  local table="$1"
  local chain="$2"

  if ! firewall_chain_exists "$table" "$chain"; then
    sudo_run iptables -t "$table" -N "$chain"
  fi
}

firewall_delete_jumps() {
  local table="$1"
  local parent_chain="$2"
  local target_chain="$3"
  local line
  local args=()

  while sudo_run iptables -t "$table" -S "$parent_chain" 2>/dev/null | grep -Fq -- "-j $target_chain"; do
    line="$(sudo_run iptables -t "$table" -S "$parent_chain" 2>/dev/null | grep -F -- "-j $target_chain" | head -n 1 || true)"
    [[ -n "$line" ]] || break
    read -r -a args <<< "$line"
    args[0]="-D"
    sudo_run iptables -t "$table" "${args[@]}"
  done
}

firewall_destroy_chain() {
  local table="$1"
  local chain="$2"

  if firewall_chain_exists "$table" "$chain"; then
    sudo_run iptables -t "$table" -F "$chain"
    sudo_run iptables -t "$table" -X "$chain"
  fi
}

firewall_apply_rules() {
  local set_name blacklist_set pending_set verified_set geo_set ingress_chain chain_name blacklist_chain admission_chain geo_chain
  local timeout_value pending_max pending_timeout verified_max verified_timeout blacklist_pps blacklist_burst hashlimit_name
  local blacklist_bps blacklist_bps_burst hashlimit_bps_name htable_size htable_max htable_expire_ms htable_gcinterval_ms
  local port_group target_chain

  require_firewall_tools || return 1
  set_name="$(firewall_set_name)"
  blacklist_set="$(firewall_blacklist_set_name)"
  pending_set="$(firewall_pending_set_name)"
  verified_set="$(firewall_verified_set_name)"
  geo_set="$(firewall_geo_set_name)"
  ingress_chain="$(firewall_ingress_chain_name)"
  chain_name="$(firewall_chain_name)"
  blacklist_chain="$(firewall_blacklist_chain_name)"
  admission_chain="$(firewall_admission_chain_name)"
  geo_chain="$(firewall_geo_chain_name)"
  timeout_value="$(firewall_ipset_timeout)"
  pending_max="$(firewall_pending_max)"
  pending_timeout="$(firewall_pending_timeout)"
  verified_max="$(firewall_verified_max)"
  verified_timeout="$(firewall_verified_timeout)"
  blacklist_pps="$(firewall_blacklist_pps)"
  blacklist_burst="$(firewall_blacklist_burst)"
  hashlimit_name="$(firewall_hashlimit_name)"
  blacklist_bps="$(firewall_blacklist_bps)"
  blacklist_bps_burst="$(firewall_blacklist_bps_burst)"
  hashlimit_bps_name="$(firewall_hashlimit_bps_name)"
  htable_size="$(firewall_hashlimit_htable_size)"
  htable_max="$(firewall_hashlimit_htable_max)"
  htable_expire_ms="$(firewall_hashlimit_htable_expire_ms)"
  htable_gcinterval_ms="$(firewall_hashlimit_htable_gcinterval_ms)"

  sudo_run ipset create "$set_name" hash:ip family inet timeout "$timeout_value" counters -exist
  sudo_run ipset create "$blacklist_set" hash:ip family inet counters -exist
  sudo_run ipset create "$pending_set" hash:ip family inet hashsize 64 maxelem "$pending_max" timeout "$pending_timeout" counters -exist
  sudo_run ipset create "$verified_set" hash:ip family inet hashsize 1024 maxelem "$verified_max" timeout "$verified_timeout" -exist
  firewall_geo_load_set

  for target_chain in "$ingress_chain" "$chain_name" "$blacklist_chain" "$admission_chain" "$geo_chain"; do
    firewall_ensure_chain raw "$target_chain"
    sudo_run iptables -t raw -F "$target_chain"
  done

  sudo_run iptables -t raw -A "$chain_name" -m set ! --match-set "$verified_set" src -j SET --add-set "$pending_set" src --exist
  sudo_run iptables -t raw -A "$chain_name" -m set --match-set "$set_name" src -j RETURN
  sudo_run iptables -t raw -A "$chain_name" -j SET --add-set "$set_name" src --exist
  sudo_run iptables -t raw -A "$chain_name" -j RETURN

  sudo_run iptables -t raw -A "$admission_chain" -m set --match-set "$verified_set" src -j RETURN
  sudo_run iptables -t raw -A "$admission_chain" -m set --match-set "$pending_set" src -j RETURN
  sudo_run iptables -t raw -A "$admission_chain" -j SET --add-set "$pending_set" src --exist
  sudo_run iptables -t raw -A "$admission_chain" -m set --match-set "$pending_set" src -j RETURN
  sudo_run iptables -t raw -A "$admission_chain" -j DROP

  sudo_run iptables -t raw -A "$blacklist_chain" \
    -m hashlimit \
    --hashlimit-above "${blacklist_pps}/second" \
    --hashlimit-burst "$blacklist_burst" \
    --hashlimit-mode srcip \
    --hashlimit-name "$hashlimit_name" \
    --hashlimit-htable-size "$htable_size" \
    --hashlimit-htable-max "$htable_max" \
    --hashlimit-htable-expire "$htable_expire_ms" \
    --hashlimit-htable-gcinterval "$htable_gcinterval_ms" \
    -j SET --add-set "$blacklist_set" src --exist
  sudo_run iptables -t raw -A "$blacklist_chain" \
    -m hashlimit \
    --hashlimit-above "$blacklist_bps" \
    --hashlimit-burst "$blacklist_bps_burst" \
    --hashlimit-mode srcip \
    --hashlimit-name "$hashlimit_bps_name" \
    --hashlimit-htable-size "$htable_size" \
    --hashlimit-htable-max "$htable_max" \
    --hashlimit-htable-expire "$htable_expire_ms" \
    --hashlimit-htable-gcinterval "$htable_gcinterval_ms" \
    -j SET --add-set "$blacklist_set" src --exist
  sudo_run iptables -t raw -A "$blacklist_chain" -m set --match-set "$blacklist_set" src -j DROP
  sudo_run iptables -t raw -A "$blacklist_chain" -j RETURN

  sudo_run iptables -t raw -A "$geo_chain" -m set --match-set "$geo_set" src -j DROP
  sudo_run iptables -t raw -A "$geo_chain" -j RETURN

  sudo_run iptables -t raw -A "$ingress_chain" -j "$admission_chain"
  sudo_run iptables -t raw -A "$ingress_chain" -m set --match-set "$blacklist_set" src -j DROP
  sudo_run iptables -t raw -A "$ingress_chain" -j "$geo_chain"
  sudo_run iptables -t raw -A "$ingress_chain" -j "$blacklist_chain"
  sudo_run iptables -t raw -A "$ingress_chain" -j "$chain_name"
  sudo_run iptables -t raw -A "$ingress_chain" -j RETURN

  firewall_delete_jumps raw PREROUTING "$ingress_chain"
  while IFS= read -r port_group; do
    [[ -n "$port_group" ]] || continue
    sudo_run iptables -t raw -I PREROUTING 1 -p udp -m multiport --dports "$port_group" -j "$ingress_chain"
  done < <(firewall_port_groups)

  for target_chain in "$chain_name" "$blacklist_chain" "$admission_chain" "$geo_chain"; do
    firewall_delete_jumps filter INPUT "$target_chain"
  done
  firewall_destroy_chain filter "$chain_name"
  firewall_destroy_chain filter "$blacklist_chain"
  firewall_destroy_chain filter "$admission_chain"
  firewall_destroy_chain filter "$geo_chain"

  echo "[OK] HostForge firewall player tracking is active."
  echo "Table/hook:    raw/PREROUTING"
  echo "Player set:    $set_name"
  echo "Blacklist set: $blacklist_set"
  echo "Pending set:   $pending_set"
  echo "Verified set:  $verified_set"
  echo "Geo block set: $geo_set"
  echo "Ingress chain: $ingress_chain"
  echo "Player chain:  $chain_name"
  echo "Block chain:   $blacklist_chain"
  echo "Admission:     $admission_chain"
  echo "Geo chain:     $geo_chain"
  echo "Ports:         $(firewall_ports | paste -sd ' ' -)"
  echo "Timeout:       ${timeout_value}s"
  echo "Admission:     verified plus ${pending_max} pending IPs"
  echo "Pending lease: ${pending_timeout}s, renewed after enforcement"
  echo "Verified:      collector-managed, ${verified_timeout}s timeout"
  echo "Blacklist:     above ${blacklist_pps}pps with burst ${blacklist_burst}"
  echo "Bandwidth:     above ${blacklist_bps} with burst ${blacklist_bps_burst}"
  echo "Hash tables:   size ${htable_size}, max ${htable_max}, expire ${htable_expire_ms}ms, GC ${htable_gcinterval_ms}ms"
}

firewall_remove_rules() {
  local set_name pending_set geo_set ingress_chain chain_name blacklist_chain admission_chain geo_chain target_chain

  require_firewall_tools || return 1
  set_name="$(firewall_set_name)"
  pending_set="$(firewall_pending_set_name)"
  geo_set="$(firewall_geo_set_name)"
  ingress_chain="$(firewall_ingress_chain_name)"
  chain_name="$(firewall_chain_name)"
  blacklist_chain="$(firewall_blacklist_chain_name)"
  admission_chain="$(firewall_admission_chain_name)"
  geo_chain="$(firewall_geo_chain_name)"

  firewall_delete_jumps raw PREROUTING "$ingress_chain"
  firewall_destroy_chain raw "$ingress_chain"
  firewall_destroy_chain raw "$chain_name"
  firewall_destroy_chain raw "$blacklist_chain"
  firewall_destroy_chain raw "$admission_chain"
  firewall_destroy_chain raw "$geo_chain"

  for target_chain in "$chain_name" "$blacklist_chain" "$admission_chain" "$geo_chain"; do
    firewall_delete_jumps filter INPUT "$target_chain"
    firewall_destroy_chain filter "$target_chain"
  done

  sudo_run ipset destroy "$set_name" >/dev/null 2>&1 || true
  sudo_run ipset destroy "$pending_set" >/dev/null 2>&1 || true
  sudo_run ipset destroy "$geo_set" >/dev/null 2>&1 || true

  echo "[OK] HostForge firewall player tracking is stopped."
}

firewall_ipset_snapshot() {
  local set_name="$1"

  require_firewall_tools || return 1
  sudo_run ipset list "$set_name" 2>/dev/null \
    | awk '
      /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {
        ip=$1
        packets=0
        bytes=0
        for (i=1; i<=NF; i++) {
          if ($i == "packets") packets=$(i+1)
          if ($i == "bytes") bytes=$(i+1)
        }
        print ip, packets, bytes
      }
    ' || true
}

firewall_snapshot() {
  firewall_ipset_snapshot "$(firewall_set_name)"
}

firewall_blacklist_snapshot() {
  firewall_ipset_snapshot "$(firewall_blacklist_set_name)"
}

firewall_ipset_count() {
  local set_name="$1"

  sudo_run ipset list "$set_name" 2>/dev/null \
    | awk -F ': ' '/^Number of entries:/ { print $2; found=1 } END { if (!found) print 0 }' \
    || true
}

firewall_player_rates() {
  local interval="${1:-1}"
  local first_snapshot second_snapshot

  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
    interval=1
  fi

  first_snapshot="$(mktemp)"
  second_snapshot="$(mktemp)"
  firewall_snapshot > "$first_snapshot" || {
    rm -f "$first_snapshot" "$second_snapshot"
    return 1
  }
  sleep "$interval"
  firewall_snapshot > "$second_snapshot" || {
    rm -f "$first_snapshot" "$second_snapshot"
    return 1
  }

  awk -v interval="$interval" '
    FNR == NR {
      packets[$1]=$2
      bytes[$1]=$3
      next
    }
    {
      old_packets=($1 in packets ? packets[$1] : $2)
      old_bytes=($1 in bytes ? bytes[$1] : $3)
      pps=($2-old_packets)/interval
      bps=($3-old_bytes)/interval
      if (pps < 0) pps=0
      if (bps < 0) bps=0
      printf "ip=%s packets=%s bytes=%s pps=%.2f bps=%.2f\n", $1, $2, $3, pps, bps
    }
  ' "$first_snapshot" "$second_snapshot"

  rm -f "$first_snapshot" "$second_snapshot"
}

valid_ipv4() {
  local value="$1"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

firewall_blacklist_add() {
  local ip="$1"

  require_firewall_tools || return 1
  if ! valid_ipv4 "$ip"; then
    echo "[ERROR] Invalid IPv4 address: $ip"
    return 1
  fi

  sudo_run ipset create "$(firewall_blacklist_set_name)" hash:ip family inet counters -exist
  if sudo_run ipset test "$(firewall_blacklist_set_name)" "$ip" >/dev/null 2>&1; then
    echo "[OK] $ip is already in $(firewall_blacklist_set_name)"
    return 0
  fi

  sudo_run ipset add "$(firewall_blacklist_set_name)" "$ip" -exist
  echo "[OK] Added $ip to $(firewall_blacklist_set_name)"
}

firewall_blacklist_remove() {
  local ip="$1"
  local set_name

  require_firewall_tools || return 1
  if ! valid_ipv4 "$ip"; then
    echo "[ERROR] Invalid IPv4 address: $ip"
    return 1
  fi

  set_name="$(firewall_blacklist_set_name)"
  sudo_run ipset create "$set_name" hash:ip family inet counters -exist

  if ! sudo_run ipset test "$set_name" "$ip" >/dev/null 2>&1; then
    echo "[OK] $ip was not in $set_name"
    return 0
  fi

  if ! sudo_run ipset del "$set_name" "$ip"; then
    echo "[ERROR] Failed to remove $ip from $set_name"
    return 1
  fi

  if sudo_run ipset test "$set_name" "$ip" >/dev/null 2>&1; then
    echo "[ERROR] $ip is still present in $set_name after removal"
    return 1
  fi

  echo "[OK] Removed $ip from $set_name"
}

firewall_blacklist_clear() {
  require_firewall_tools || return 1
  sudo_run ipset create "$(firewall_blacklist_set_name)" hash:ip family inet counters -exist
  sudo_run ipset flush "$(firewall_blacklist_set_name)"
  echo "[OK] Cleared $(firewall_blacklist_set_name)"
}

firewall_blacklist_list() {
  local found="0"

  echo
  echo "=== Firewall Blacklist ==="
  echo "Set: $(firewall_blacklist_set_name)"
  while read -r ip packets bytes; do
    [[ -n "$ip" ]] || continue
    found="1"
    printf '%-16s packets=%-10s bytes=%s\n' "$ip" "$packets" "$bytes"
  done < <(firewall_blacklist_snapshot)

  if [[ "$found" == "0" ]]; then
    echo "No blacklisted IPs."
  fi
}

firewall_select_blacklist_ip() {
  local ips=() ip choice index packets bytes

  while read -r ip packets bytes; do
    [[ -n "$ip" ]] && ips+=("$ip")
  done < <(firewall_blacklist_snapshot)

  if [[ "${#ips[@]}" -eq 0 ]]; then
    echo "No blacklisted IPs." >&2
    return 1
  fi

  echo >&2
  echo "Blacklisted IPs:" >&2
  for index in "${!ips[@]}"; do
    printf '  %2d) %s\n' "$((index + 1))" "${ips[$index]}" >&2
  done

  echo >&2
  read -r -p "Choose an IP number or type an IP: " choice >&2
  choice="$(trim "$choice")"

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    index=$((choice - 1))
    if (( index < 0 || index >= ${#ips[@]} )); then
      echo "Invalid IP number: $choice" >&2
      return 1
    fi
    printf '%s\n' "${ips[$index]}"
    return
  fi

  if valid_ipv4 "$choice"; then
    printf '%s\n' "$choice"
    return
  fi

  echo "Invalid IP: $choice" >&2
  return 1
}

firewall_status() {
  local set_name blacklist_set pending_set verified_set geo_set ingress_chain chain_name blacklist_chain admission_chain geo_chain ports
  set_name="$(firewall_set_name)"
  blacklist_set="$(firewall_blacklist_set_name)"
  pending_set="$(firewall_pending_set_name)"
  verified_set="$(firewall_verified_set_name)"
  geo_set="$(firewall_geo_set_name)"
  ingress_chain="$(firewall_ingress_chain_name)"
  chain_name="$(firewall_chain_name)"
  blacklist_chain="$(firewall_blacklist_chain_name)"
  admission_chain="$(firewall_admission_chain_name)"
  geo_chain="$(firewall_geo_chain_name)"
  ports="$(firewall_ports | paste -sd ' ' -)"

  echo
  echo "=== HostForge Firewall Tracking ==="
  echo "Unit:       $(firewall_unit_name)"
  echo "Enabled:    $(unit_enabled_state "$(firewall_unit_name)")"
  echo "Active:     $(unit_active_state "$(firewall_unit_name)")"
  echo "Player set: $set_name"
  echo "Block set:  $blacklist_set"
  echo "Pending set:$pending_set"
  echo "Verified set: $verified_set"
  echo "Geo set:    $geo_set"
  echo "Hook:       raw/PREROUTING"
  echo "Ingress:    $ingress_chain"
  echo "Track chain:$chain_name"
  echo "Block chain:$blacklist_chain"
  echo "Admit chain:$admission_chain"
  echo "Geo chain:  $geo_chain"
  echo "Geo dir:    $(firewall_geo_dir)"
  echo "Ports:      ${ports:-none}"
  echo "Timeout:    $(firewall_ipset_timeout)s"
  echo "Pending IPs: $(firewall_ipset_count "$pending_set")/$(firewall_pending_max) IPs, $(firewall_pending_timeout)s renewable timeout"
  echo "Verified IPs: $(firewall_ipset_count "$verified_set") IPs, $(firewall_verified_timeout)s collector-renewed timeout"
  echo "Blacklist:  >$(firewall_blacklist_pps)pps burst $(firewall_blacklist_burst)"
  echo "Bandwidth:  >$(firewall_blacklist_bps) burst $(firewall_blacklist_bps_burst)"
  echo "Hash table: size $(firewall_hashlimit_htable_size), max $(firewall_hashlimit_htable_max), expire $(firewall_hashlimit_htable_expire_ms)ms, GC $(firewall_hashlimit_htable_gcinterval_ms)ms"
  echo "iptables:   $(command -v iptables 2>/dev/null || echo 'missing')"
  echo "ipset:      $(command -v ipset 2>/dev/null || echo 'missing')"
  echo
  echo "Tracked players:"
  firewall_player_rates 1 || echo "No ipset counters available yet. Start the firewall service first."
}

firewall_start_service() {
  require_systemctl || return 1
  install_service_template || return 1
  sudo_run systemctl enable --now "$(firewall_unit_name)"
  systemctl status "$(firewall_unit_name)" --no-pager -n 10 || true
}

firewall_stop_service() {
  require_systemctl || return 1
  sudo_run systemctl disable --now "$(firewall_unit_name)" || true
  systemctl status "$(firewall_unit_name)" --no-pager -n 8 || true
}

firewall_restart_service() {
  require_systemctl || return 1
  install_service_template || return 1
  if systemctl is-active --quiet "$(firewall_unit_name)"; then
    firewall_apply_rules
  else
    sudo_run systemctl enable --now "$(firewall_unit_name)"
  fi
  systemctl status "$(firewall_unit_name)" --no-pager -n 10 || true
}

firewall_logs() {
  local lines="${1:-80}"

  if ! journalctl_available; then
    echo "[ERROR] journalctl is required for this action."
    return 1
  fi

  journalctl -u "$(firewall_unit_name)" -n "$lines" --no-pager || true
}

web_firewall_status() {
  print_web_kv "unit" "$(firewall_unit_name)"
  print_web_kv "enabled" "$(unit_enabled_state "$(firewall_unit_name)")"
  print_web_kv "active" "$(unit_active_state "$(firewall_unit_name)")"
  print_web_kv "set" "$(firewall_set_name)"
  print_web_kv "blacklist_set" "$(firewall_blacklist_set_name)"
  print_web_kv "pending_set" "$(firewall_pending_set_name)"
  print_web_kv "pending_count" "$(firewall_ipset_count "$(firewall_pending_set_name)")"
  print_web_kv "pending_max" "$(firewall_pending_max)"
  print_web_kv "pending_timeout" "$(firewall_pending_timeout)"
  print_web_kv "verified_set" "$(firewall_verified_set_name)"
  print_web_kv "verified_count" "$(firewall_ipset_count "$(firewall_verified_set_name)")"
  print_web_kv "verified_timeout" "$(firewall_verified_timeout)"
  print_web_kv "geo_set" "$(firewall_geo_set_name)"
  print_web_kv "hook" "raw/PREROUTING"
  print_web_kv "ingress_chain" "$(firewall_ingress_chain_name)"
  print_web_kv "chain" "$(firewall_chain_name)"
  print_web_kv "blacklist_chain" "$(firewall_blacklist_chain_name)"
  print_web_kv "admission_chain" "$(firewall_admission_chain_name)"
  print_web_kv "geo_chain" "$(firewall_geo_chain_name)"
  print_web_kv "geo_dir" "$(firewall_geo_dir)"
  print_web_kv "ports" "$(firewall_ports | paste -sd ' ' -)"
  print_web_kv "timeout" "$(firewall_ipset_timeout)"
  print_web_kv "blacklist_pps" "$(firewall_blacklist_pps)"
  print_web_kv "blacklist_burst" "$(firewall_blacklist_burst)"
  print_web_kv "hashlimit_name" "$(firewall_hashlimit_name)"
  print_web_kv "blacklist_bps" "$(firewall_blacklist_bps)"
  print_web_kv "blacklist_bps_burst" "$(firewall_blacklist_bps_burst)"
  print_web_kv "hashlimit_bps_name" "$(firewall_hashlimit_bps_name)"
  print_web_kv "hashlimit_htable_size" "$(firewall_hashlimit_htable_size)"
  print_web_kv "hashlimit_htable_max" "$(firewall_hashlimit_htable_max)"
  print_web_kv "hashlimit_htable_expire_ms" "$(firewall_hashlimit_htable_expire_ms)"
  print_web_kv "hashlimit_htable_gcinterval_ms" "$(firewall_hashlimit_htable_gcinterval_ms)"
  print_web_kv "iptables" "$(command -v iptables 2>/dev/null || echo 'missing')"
  print_web_kv "ipset" "$(command -v ipset 2>/dev/null || echo 'missing')"
}

wine_prefix_for_profile() {
  local profile="$1"

  if [[ -n "${HF_WINEPREFIX:-}" ]]; then
    expand_path "$HF_WINEPREFIX"
    return
  fi

  expand_path "${HF_WINEPREFIX_BASE:-$DEFAULT_WINE_PREFIX_BASE-$profile}"
}

wine_prefix_template() {
  expand_path "${HF_WINEPREFIX_TEMPLATE:-$DEFAULT_WINE_PREFIX_TEMPLATE}"
}

find_command() {
  local command_name

  for command_name in "$@"; do
    if command -v "$command_name" >/dev/null 2>&1; then
      command -v "$command_name"
      return
    fi
  done

  return 1
}

resolve_wine_cmd() {
  local requested="${1:-}"

  if [[ -n "$requested" ]]; then
    if command -v "$requested" >/dev/null 2>&1; then
      command -v "$requested"
      return
    fi

    if [[ -x "$requested" ]]; then
      printf '%s\n' "$requested"
      return
    fi

    if [[ "$requested" != "wine" ]]; then
      return 1
    fi
  fi

  find_command wine wine-stable /opt/wine-stable/bin/wine
}

wine_documents_dir() {
  local prefix="$1"
  local username="${2:-$(service_user)}"
  local candidate

  if [[ -n "$username" && -d "$prefix/drive_c/users/$username" ]]; then
    printf '%s\n' "$prefix/drive_c/users/$username/Documents"
    return
  fi

  candidate="$(find "$prefix/drive_c/users" -mindepth 1 -maxdepth 1 -type d ! -name Public -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate/Documents"
    return
  fi

  printf '%s\n' "$prefix/drive_c/users/${username:-steamuser}/Documents"
}

bannerlord_auth_token_path() {
  local prefix documents_dir
  prefix="$(wine_prefix_template)"
  documents_dir="$(wine_documents_dir "$prefix")"
  printf '%s\n' "$documents_dir/Mount and Blade II Bannerlord/Tokens/DedicatedCustomServerAuthToken.txt"
}

write_bannerlord_auth_token() {
  local token="$1"
  local token_file token_dir

  token="$(trim "$token")"
  if [[ -z "$token" ]]; then
    echo "[ERROR] Token cannot be blank."
    return 1
  fi

  token_file="$(bannerlord_auth_token_path)"
  token_dir="$(dirname "$token_file")"

  mkdir -p "$token_dir"
  umask 077
  printf '%s\n' "$token" > "$token_file"
  chmod 600 "$token_file"

  echo "[OK] Wrote Bannerlord dedicated auth token:"
  echo "$token_file"
}

prompt_bannerlord_auth_token() {
  local token token_file

  token_file="$(bannerlord_auth_token_path)"
  echo "Token target:"
  echo "$token_file"
  echo
  read -r -s -p "Bannerlord DedicatedCustomServer auth token: " token
  echo
  write_bannerlord_auth_token "$token"
}

path_has_entries() {
  local path_value="$1"
  [[ -n "$(find "$path_value" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

seed_wine_prefix_from_template() {
  local profile="$1"
  local wine_prefix="$2"
  local template_prefix parent_dir temp_prefix backup_prefix

  template_prefix="$(wine_prefix_template)"

  if [[ "$template_prefix" == "$wine_prefix" ]]; then
    echo "  Prefix seed: skipped; template and target are the same path"
    return 1
  fi

  if [[ ! -f "$template_prefix/system.reg" ]]; then
    echo "  Prefix seed: skipped; template missing system.reg at $template_prefix"
    return 1
  fi

  if [[ -e "$wine_prefix" ]]; then
    if path_has_entries "$wine_prefix"; then
      backup_prefix="${wine_prefix}.broken-$(date -u +%Y%m%d-%H%M%S)"
      echo "  Prefix seed: moving incomplete prefix to $backup_prefix"
      mv "$wine_prefix" "$backup_prefix"
    else
      rmdir "$wine_prefix"
    fi
  fi

  parent_dir="$(dirname "$wine_prefix")"
  mkdir -p "$parent_dir"
  temp_prefix="$(mktemp -d "$parent_dir/.hostforge-prefix-${profile}.XXXXXX")"

  echo "  Prefix seed: copying template $template_prefix"
  if cp -a "$template_prefix/." "$temp_prefix/"; then
    mv "$temp_prefix" "$wine_prefix"
    return 0
  fi

  rm -rf "$temp_prefix"
  return 1
}

ensure_wine_prefix() {
  local profile="$1"
  local wine_prefix="$2"

  if [[ -f "$wine_prefix/system.reg" ]]; then
    return
  fi

  if seed_wine_prefix_from_template "$profile" "$wine_prefix"; then
    return
  fi

  mkdir -p "$wine_prefix"
  if command -v wineboot >/dev/null 2>&1; then
    echo "  Prefix init: first run for $profile"
    WINEPREFIX="$wine_prefix" WINEDEBUG=-all wineboot -u >/dev/null 2>&1 || true
  fi
}

install_unit_from_template() {
  local template_path="$1"
  local destination_path="$2"
  local service_user_value service_home_value tmp_file

  service_user_value="$(service_user)"
  service_home_value="$(service_user_home)"

  if [[ ! -f "$template_path" ]]; then
    echo "[ERROR] Missing service template: $template_path"
    return 1
  fi

  tmp_file="$(mktemp)"
  sed \
    -e "s|__REPO_DIR__|$(escape_sed_replacement "$REPO_DIR")|g" \
    -e "s|__USER__|$(escape_sed_replacement "$service_user_value")|g" \
    -e "s|__USER_HOME__|$(escape_sed_replacement "$service_home_value")|g" \
    -e "s|__COLLECTOR_PORT__|$(escape_sed_replacement "$(collector_port)")|g" \
    -e "s|__COLLECTOR_BIND__|$(escape_sed_replacement "$(collector_bind)")|g" \
    "$template_path" > "$tmp_file"

  sudo_run cp "$tmp_file" "$destination_path"
  sudo_run chmod 644 "$destination_path"
  rm -f "$tmp_file"
}

systemctl_path() {
  command -v systemctl 2>/dev/null || printf '/usr/bin/systemctl\n'
}

install_sudoers_rule() {
  local service_user_value tmp_file systemctl_bin systemctl_alt_bin

  if [[ "${HF_INSTALL_SUDOERS:-1}" != "1" ]]; then
    echo "Skipping sudoers install because HF_INSTALL_SUDOERS is not 1."
    return
  fi

  if [[ "${EUID}" -ne 0 && "${HF_SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
    echo "Skipping sudoers install from non-interactive sudo context."
    return
  fi

  service_user_value="$(service_user)"
  systemctl_bin="$(systemctl_path)"
  systemctl_alt_bin="/bin/systemctl"
  if [[ "$systemctl_bin" == "/bin/systemctl" ]]; then
    systemctl_alt_bin="/usr/bin/systemctl"
  fi
  tmp_file="$(mktemp)"

  cat > "$tmp_file" <<EOF
# Installed by HostForge. Allows the HostForge web collector to run systemctl
# without interactive sudo. HostForge's web app exposes only curated service
# actions, but sudoers argument wildcards are not portable across sudo versions.
Cmnd_Alias HOSTFORGE_SYSTEMCTL = $systemctl_bin, $systemctl_alt_bin
Cmnd_Alias HOSTFORGE_FIREWALL = /usr/sbin/ipset, /sbin/ipset, /usr/sbin/iptables, /sbin/iptables

$service_user_value ALL=(root) NOPASSWD: HOSTFORGE_SYSTEMCTL, HOSTFORGE_FIREWALL
EOF

  if command -v visudo >/dev/null 2>&1; then
    if ! visudo -cf "$tmp_file"; then
      rm -f "$tmp_file"
      echo "[ERROR] Generated sudoers rule failed validation."
      return 1
    fi
  fi

  sudo_run cp "$tmp_file" "$SUDOERS_PATH"
  sudo_run chmod 440 "$SUDOERS_PATH"
  rm -f "$tmp_file"
}

install_service_template() {
  if [[ "${EUID}" -ne 0 && "${HF_SUDO_NONINTERACTIVE:-0}" == "1" ]]; then
    if [[ -f "$SYSTEMD_TEMPLATE_PATH" && -f "$COLLECTOR_SYSTEMD_PATH" && -f "$FIREWALL_SYSTEMD_PATH" ]]; then
      echo "Using already-installed HostForge systemd units."
      return 0
    fi

    echo "[ERROR] HostForge systemd units are not installed yet."
    echo "Run from SSH first: bash $REPO_DIR/hostforge.sh __install-service-template"
    return 1
  fi

  mkdir -p "$REPO_DIR/logs/wine" "$REPO_DIR/logs/instances"
  sudo_run mkdir -p "$SYSTEMD_DIR"
  install_unit_from_template "$SERVICE_TEMPLATE" "$SYSTEMD_TEMPLATE_PATH"
  install_unit_from_template "$COLLECTOR_SERVICE_TEMPLATE" "$COLLECTOR_SYSTEMD_PATH"
  install_unit_from_template "$CLOUDFLARED_QUICK_SERVICE_TEMPLATE" "$CLOUDFLARED_QUICK_SYSTEMD_PATH"
  install_unit_from_template "$FIREWALL_SERVICE_TEMPLATE" "$FIREWALL_SYSTEMD_PATH"
  install_sudoers_rule

  if systemctl_available; then
    if systemctl list-unit-files | grep -q '^hostforge\.service'; then
      sudo_run systemctl disable --now hostforge.service || true
    fi

    if [[ -f "$SYSTEMD_DIR/hostforge.service" ]]; then
      sudo_run rm -f "$SYSTEMD_DIR/hostforge.service"
    fi

    sudo_run systemctl daemon-reload
  fi

  echo "[OK] Installed HostForge systemd units in $SYSTEMD_DIR"
}

require_systemctl() {
  if ! systemctl_available; then
    echo "[ERROR] systemctl is required for this action."
    return 1
  fi
}

require_python3() {
  if ! python3_available; then
    echo "[ERROR] python3 is required for the HostForge collector."
    return 1
  fi
}

ensure_collector_running() {
  require_systemctl || return 1
  require_python3 || return 1
  install_service_template || return 1
  sudo_run systemctl enable --now "$(collector_unit_name)"
}

active_hostforge_profiles() {
  if ! systemctl_available; then
    return
  fi

  systemctl list-units 'hostforge@*.service' --type=service --all --no-legend --plain 2>/dev/null \
    | awk '{print $1}' \
    | sed -e 's/^hostforge@//' -e 's/\.service$//' \
    | sort -u
}

warn_port_conflicts() {
  local target_profile="$1"
  local target_port active_profile active_port conflict_found="0"

  target_port="$(profile_port "$target_profile" || true)"
  if [[ -z "$target_port" ]]; then
    return
  fi

  while IFS= read -r active_profile; do
    [[ -n "$active_profile" ]] || continue
    [[ "$active_profile" == "$target_profile" ]] && continue

    active_port="$(profile_port "$active_profile" || true)"
    if [[ -n "$active_port" && "$active_port" == "$target_port" && "$(service_active_state "$active_profile")" == "active" ]]; then
      if [[ "$conflict_found" == "0" ]]; then
        echo "[WARN] Port $target_port is already used by an active profile:"
        conflict_found="1"
      fi

      echo "  - $active_profile"
    fi
  done < <(active_hostforge_profiles)

  if [[ "$conflict_found" == "1" ]]; then
    local answer
    read -r -p "Continue activating $target_profile anyway? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "Activation cancelled."
      return 1
    fi
  fi
}

show_profiles_table() {
  local profile params_state config_state health server_name game_type port enabled_state active_state

  printf '%-18s %-8s %-8s %-8s %-8s %-8s %-10s %s\n' "PROFILE" "PARAMS" "CONFIG" "STATUS" "PORT" "ENABLE" "ACTIVE" "SERVER"

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue

    if profile_has_params "$profile"; then
      params_state="yes"
    else
      params_state="no"
    fi

    if profile_has_config "$profile"; then
      config_state="yes"
    else
      config_state="no"
    fi

    health="$(profile_health "$profile")"
    port="$(profile_port "$profile" || true)"
    server_name="$(profile_server_name "$profile" || true)"
    game_type="$(profile_game_type "$profile" || true)"
    enabled_state="$(service_enabled_state "$profile")"
    active_state="$(service_active_state "$profile")"

    if [[ -n "$game_type" ]]; then
      server_name="$server_name [$game_type]"
    fi

    printf '%-18s %-8s %-8s %-8s %-8s %-8s %-10s %s\n' \
      "$profile" "$params_state" "$config_state" "$health" "${port:-n/a}" "$enabled_state" "$active_state" "${server_name:-n/a}"
  done < <(discover_profiles)
}

select_profile() {
  local profiles=() profile choice index

  while IFS= read -r profile; do
    [[ -n "$profile" ]] && profiles+=("$profile")
  done < <(discover_profiles)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    echo "No profiles found under $CONFIG_DIR." >&2
    return 1
  fi

  echo >&2
  echo "Available profiles:" >&2
  for index in "${!profiles[@]}"; do
    profile="${profiles[$index]}"
    printf '  %2d) %s [%s]\n' "$((index + 1))" "$profile" "$(profile_health "$profile")" >&2
  done

  echo >&2
  read -r -p "Select profile number or name: " choice >&2
  choice="$(trim "$choice")"

  if [[ -z "$choice" ]]; then
    echo "No profile selected." >&2
    return 1
  fi

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    index=$((choice - 1))
    if (( index < 0 || index >= ${#profiles[@]} )); then
      echo "Invalid selection." >&2
      return 1
    fi

    printf '%s\n' "${profiles[$index]}"
    return
  fi

  printf '%s\n' "$choice"
}

selection_tokens() {
  local raw_input="$1"

  printf '%s\n' "$raw_input" \
    | tr ',;' '  ' \
    | xargs -n1 2>/dev/null \
    | sed '/^$/d'
}

profile_was_selected() {
  local wanted="$1"
  shift
  local selected_profile

  for selected_profile in "$@"; do
    if [[ "$selected_profile" == "$wanted" ]]; then
      return 0
    fi
  done

  return 1
}

select_profiles() {
  local profiles=() selected=()
  local profile choice token index matched port_value active_state health_state

  while IFS= read -r profile; do
    [[ -n "$profile" ]] && profiles+=("$profile")
  done < <(discover_profiles)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    echo "No profiles found under $CONFIG_DIR." >&2
    return 1
  fi

  echo >&2
  echo "Available profiles:" >&2
  for index in "${!profiles[@]}"; do
    profile="${profiles[$index]}"
    port_value="$(profile_port "$profile" || true)"
    active_state="$(service_active_state "$profile")"
    health_state="$(profile_health "$profile")"
    printf '  %2d) %-18s status=%-7s active=%-8s port=%s\n' \
      "$((index + 1))" \
      "$profile" \
      "$health_state" \
      "$active_state" \
      "${port_value:-n/a}" >&2
  done

  echo >&2
  read -r -p "Select profile numbers/names (example: 1 2 4, or all): " choice >&2
  choice="$(trim "$choice")"

  if [[ -z "$choice" ]]; then
    echo "No profiles selected." >&2
    return 1
  fi

  if [[ "${choice,,}" == "all" ]]; then
    printf '%s\n' "${profiles[@]}"
    return
  fi

  while IFS= read -r token; do
    [[ -n "$token" ]] || continue

    if [[ "$token" =~ ^[0-9]+$ ]]; then
      index=$((token - 1))
      if (( index < 0 || index >= ${#profiles[@]} )); then
        echo "Invalid profile number: $token" >&2
        return 1
      fi

      profile="${profiles[$index]}"
    else
      matched="0"
      for profile in "${profiles[@]}"; do
        if [[ "$profile" == "$token" ]]; then
          matched="1"
          break
        fi
      done

      if [[ "$matched" != "1" ]]; then
        echo "Unknown profile: $token" >&2
        return 1
      fi
    fi

    if ! profile_was_selected "$profile" "${selected[@]}"; then
      selected+=("$profile")
    fi
  done < <(selection_tokens "$choice")

  if [[ "${#selected[@]}" -eq 0 ]]; then
    echo "No valid profiles selected." >&2
    return 1
  fi

  printf '%s\n' "${selected[@]}"
}

inspect_profile() {
  local profile="$1"
  local params_file config_file logs_answer port_value server_name_value game_type_value

  params_file="$(params_file_for "$profile")"
  config_file="$(config_file_for "$profile")"
  port_value="$(profile_port "$profile" || true)"
  server_name_value="$(profile_server_name "$profile" || true)"
  game_type_value="$(profile_game_type "$profile" || true)"

  echo
  echo "Profile:        $profile"
  echo "Health:         $(profile_health "$profile")"
  echo "Params file:    $params_file"
  echo "Config file:    $config_file"
  echo "Port:           ${port_value:-n/a}"
  echo "ServerName:     ${server_name_value:-n/a}"
  echo "GameType:       ${game_type_value:-n/a}"
  echo "Enabled:        $(service_enabled_state "$profile")"
  echo "Active:         $(service_active_state "$profile")"
  echo "Log page:       $(collector_public_url)instances/$profile/"

  if [[ -f "$params_file" ]]; then
    echo
    echo "Params preview:"
    sed -n '1,10p' "$params_file"
  fi

  if [[ -f "$config_file" ]]; then
    echo
    echo "Config preview:"
    awk '
      BEGIN { count = 0 }
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*[#;]/ { next }
      {
        if ($1 == "AdminPassword" || $1 == "GamePassword") {
          print $1 " [redacted]"
        } else {
          print
        }

        count++
        if (count >= 12) {
          exit
        }
      }
    ' "$config_file"
  fi

  if journalctl_available && systemctl_available; then
    echo
    read -r -p "Show recent logs for $profile? [y/N] " logs_answer
    if [[ "$logs_answer" =~ ^[Yy]$ ]]; then
      journalctl -u "$(unit_name_for "$profile")" -n 30 --no-pager || true
    fi
  fi
}

activate_profile() {
  local profile="$1"

  if ! profile_is_valid "$profile"; then
    echo "[ERROR] Profile $profile is incomplete."
    return 1
  fi

  require_systemctl || return 1
  require_python3 || return 1
  install_service_template || return 1
  ensure_collector_running || return 1
  warn_port_conflicts "$profile" || return 1
  sudo_run systemctl enable --now "$(unit_name_for "$profile")"
  systemctl status "$(unit_name_for "$profile")" --no-pager -n 8 || true
}

deactivate_profile() {
  local profile="$1"

  require_systemctl || return 1
  sudo_run systemctl disable --now "$(unit_name_for "$profile")" || true
  systemctl status "$(unit_name_for "$profile")" --no-pager -n 5 || true
}

restart_profile() {
  local profile="$1"

  if ! profile_is_valid "$profile"; then
    echo "[ERROR] Profile $profile is incomplete."
    return 1
  fi

  require_systemctl || return 1
  require_python3 || return 1
  install_service_template || return 1
  ensure_collector_running || return 1
  sudo_run systemctl restart "$(unit_name_for "$profile")"
  systemctl status "$(unit_name_for "$profile")" --no-pager -n 8 || true
}

show_active_services() {
  require_systemctl || return 1
  systemctl list-units 'hostforge@*.service' --type=service --all --no-pager --plain || true
}

view_logs() {
  local profile="$1"
  local lines="${2:-50}"

  if ! journalctl_available; then
    echo "[ERROR] journalctl is required for this action."
    return 1
  fi

  journalctl -u "$(unit_name_for "$profile")" -n "$lines" --no-pager || true
}

collector_status() {
  require_systemctl || return 1
  systemctl status "$(collector_unit_name)" --no-pager -n 12 || true
  echo
  echo "Collector URL: $(collector_public_url)"
}

collector_logs() {
  local lines="${1:-80}"

  if ! journalctl_available; then
    echo "[ERROR] journalctl is required for this action."
    return 1
  fi

  journalctl -u "$(collector_unit_name)" -n "$lines" --no-pager || true
}

dotnet_dump_root() {
  expand_path "${HF_DOTNET_DUMP_DIR:-$DEFAULT_DOTNET_DUMP_DIR}"
}

clear_crash_dumps() {
  local profile="${1:-}"
  local root target count

  root="$(dotnet_dump_root)"
  if [[ -z "$root" || "$root" == "/" ]]; then
    echo "[ERROR] Refusing to clear unsafe dump root: ${root:-empty}"
    return 1
  fi

  mkdir -p "$root"

  if [[ -n "$profile" ]]; then
    if [[ ! "$profile" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "[ERROR] Invalid profile name for dump clear: $profile"
      return 1
    fi
    target="$root/$profile"
  else
    target="$root"
  fi

  if [[ ! -d "$target" ]]; then
    echo "[OK] No crash dumps found at $target"
    return 0
  fi

  count="$(find "$target" -mindepth 1 2>/dev/null | wc -l | tr -d '[:space:]')"
  find "$target" -mindepth 1 -exec rm -rf -- {} +

  if [[ -n "$profile" ]]; then
    echo "[OK] Cleared $count crash dump item(s) for $profile from $target"
  else
    echo "[OK] Cleared $count crash dump item(s) from $target"
  fi
}

rebuild_log_site() {
  require_python3 || return 1
  python3 "$COLLECTOR_SCRIPT" --data-dir "$REPO_DIR/logs" --site-title "HostForge" --rebuild
  echo "Log site: $(collector_public_url)"
}

restart_collector_service() {
  require_systemctl || return 1
  require_python3 || return 1
  install_service_template || return 1
  sudo_run systemctl restart "$(collector_unit_name)"
  systemctl status "$(collector_unit_name)" --no-pager -n 12 || true
  echo
  echo "Collector URL: $(collector_public_url)"
}

print_web_kv() {
  local key="$1"
  local value="${2-}"
  printf '%s=%s\n' "$key" "$value"
}

web_wrap_action() {
  local action_label="$1"
  shift
  local output status message

  if output="$("$@" 2>&1)"; then
    status=0
    message="$action_label completed."
  else
    status=$?
    message="$action_label failed."
  fi

  print_web_kv "ok" "$([[ "$status" -eq 0 ]] && printf 'yes' || printf 'no')"
  print_web_kv "status" "$status"
  print_web_kv "message" "$message"
  echo "__OUTPUT_BEGIN__"
  printf '%s\n' "$output"
  echo "__OUTPUT_END__"
  return "$status"
}

web_discover_profiles() {
  discover_profiles
}

web_inspect_profile() {
  local profile="$1"
  local params_file config_file port_value server_name_value game_type_value

  validate_profile_key "$profile" || return 1

  params_file="$(params_file_for "$profile")"
  config_file="$(config_file_for "$profile")"
  port_value="$(profile_port "$profile" || true)"
  server_name_value="$(profile_server_name "$profile" || true)"
  game_type_value="$(profile_game_type "$profile" || true)"

  print_web_kv "profile" "$profile"
  print_web_kv "health" "$(profile_health "$profile")"
  print_web_kv "params_present" "$([[ -f "$params_file" ]] && printf 'yes' || printf 'no')"
  print_web_kv "config_present" "$([[ -f "$config_file" ]] && printf 'yes' || printf 'no')"
  print_web_kv "params_file" "$params_file"
  print_web_kv "config_file" "$config_file"
  print_web_kv "port" "${port_value:-}"
  print_web_kv "server_name" "${server_name_value:-}"
  print_web_kv "game_type" "${game_type_value:-}"
  print_web_kv "enabled" "$(service_enabled_state "$profile")"
  print_web_kv "active" "$(service_active_state "$profile")"
  print_web_kv "log_page" "$(collector_public_url)instances/$profile/"
  print_web_kv "log_current" "$REPO_DIR/logs/instances/$profile/current.log"
  print_web_kv "log_previous" "$REPO_DIR/logs/instances/$profile/previous.log"
}

web_profile_files() {
  local profile="$1"
  local params_file config_file

  validate_profile_key "$profile" || return 1

  params_file="$(params_file_for "$profile")"
  config_file="$(config_file_for "$profile")"

  print_web_kv "profile" "$profile"
  print_web_kv "params_file" "$params_file"
  print_web_kv "config_file" "$config_file"
  print_web_kv "params_present" "$([[ -f "$params_file" ]] && printf 'yes' || printf 'no')"
  print_web_kv "config_present" "$([[ -f "$config_file" ]] && printf 'yes' || printf 'no')"
  echo "__PARAMS_BEGIN__"
  emit_profile_file_body "$params_file"
  echo "__PARAMS_END__"
  echo "__CONFIG_BEGIN__"
  emit_profile_file_body "$config_file"
  echo "__CONFIG_END__"
}

emit_profile_file_body() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  cat "$file"
  if [[ -s "$file" && "$(tail -c 1 "$file")" != "" ]]; then
    printf '\n'
  fi
}

sanitize_profile_editor_text() {
  tr -d '\r' \
    | sed \
      -e 's/__PARAMS_BEGIN__//g' \
      -e 's/__PARAMS_END__//g' \
      -e 's/__CONFIG_BEGIN__//g' \
      -e 's/__CONFIG_END__//g'
}

save_profile_files() {
  local profile="$1"
  local params_source="$2"
  local config_source="$3"
  local params_target config_target params_tmp config_tmp

  validate_profile_key "$profile" || return 1

  if [[ ! -f "$params_source" ]]; then
    echo "[ERROR] Params source file not found: $params_source"
    return 1
  fi

  if [[ ! -f "$config_source" ]]; then
    echo "[ERROR] Config source file not found: $config_source"
    return 1
  fi

  if [[ ! -s "$params_source" ]]; then
    echo "[ERROR] Params text is required."
    return 1
  fi

  if [[ ! -s "$config_source" ]]; then
    echo "[ERROR] Config text is required."
    return 1
  fi

  mkdir -p "$CONFIG_DIR"
  params_target="$(params_file_for "$profile")"
  config_target="$(config_file_for "$profile")"
  params_tmp="$(mktemp "$CONFIG_DIR/.ds_params_${profile}.XXXXXX")"
  config_tmp="$(mktemp "$CONFIG_DIR/.ds_config_${profile}.XXXXXX")"

  sanitize_profile_editor_text < "$params_source" > "$params_tmp"
  sanitize_profile_editor_text < "$config_source" > "$config_tmp"
  mv "$params_tmp" "$params_target"
  mv "$config_tmp" "$config_target"

  echo "[OK] Saved profile $profile"
  echo "Params: $params_target"
  echo "Config: $config_target"
  echo "Restart $profile for these files to affect a running server."
}

delete_profile_files() {
  local profile="$1"
  local params_target config_target

  validate_profile_key "$profile" || return 1

  if [[ "$(service_active_state "$profile")" == "active" ]]; then
    echo "[ERROR] Profile $profile is active. Deactivate it before deleting config files."
    return 1
  fi

  params_target="$(params_file_for "$profile")"
  config_target="$(config_file_for "$profile")"

  if [[ ! -f "$params_target" && ! -f "$config_target" ]]; then
    echo "[ERROR] Profile $profile has no config files to delete."
    return 1
  fi

  if systemctl_available; then
    sudo_run systemctl disable "$(unit_name_for "$profile")" >/dev/null 2>&1 || true
  fi

  rm -f "$params_target" "$config_target"
  echo "[OK] Deleted profile files for $profile"
  echo "Removed: $params_target"
  echo "Removed: $config_target"
}

web_collector_status() {
  print_web_kv "unit" "$(collector_unit_name)"
  print_web_kv "enabled" "$(unit_enabled_state "$(collector_unit_name)")"
  print_web_kv "active" "$(unit_active_state "$(collector_unit_name)")"
  print_web_kv "url" "$(collector_public_url)"
  print_web_kv "bind" "$(collector_bind)"
  print_web_kv "port" "$(collector_port)"
}

web_repo_status() {
  local self_repo_dir hostforge_module_source

  self_repo_dir="$REPO_DIR"
  hostforge_module_source="$(hostforge_module_source_dir)"

  print_web_kv "hostforge_dir" "$self_repo_dir"
  print_web_kv "hostforge_module_source" "$hostforge_module_source"
  print_web_kv "hostforge_module_name" "$(hostforge_module_name)"
  print_web_kv "hostforge_present" "$([[ -d "$self_repo_dir/.git" ]] && printf 'yes' || printf 'no')"
  print_web_kv "hostforge_module_present" "$([[ -d "$hostforge_module_source" ]] && printf 'yes' || printf 'no')"
  print_web_kv "custom_mods_file" "$(custom_mods_file)"
}

require_git() {
  if ! command -v git >/dev/null 2>&1; then
    echo "[ERROR] git is required for this action."
    return 1
  fi
}

repo_exists() {
  [[ -d "$1/.git" ]]
}

sync_directory() {
  local source_dir="$1"
  local target_dir="$2"
  shift 2

  mkdir -p "$target_dir"
  rsync -a --delete "$@" "${source_dir}/" "${target_dir}/"
}

git_pull_repo() {
  local repo_dir="$1"
  local label="$2"

  require_git || return 1

  if ! repo_exists "$repo_dir"; then
    echo "[ERROR] $label repo not found at $repo_dir"
    return 1
  fi

  echo "== $label =="
  echo "Repo: $repo_dir"
  git -C "$repo_dir" pull --ff-only
}

hostforge_module_status() {
  local hostforge_module_source module_name module_target server_path

  hostforge_module_source="$(hostforge_module_source_dir)"
  module_name="$(hostforge_module_name)"
  server_path="$(bannerlord_root)"
  module_target="$server_path/Modules/$module_name"

  echo
  echo "=== Repo Maintenance ==="
  echo "hostforge repo:       $REPO_DIR"
  echo "module source:        $hostforge_module_source"
  echo "module target:        $module_target"
  echo
  echo "hostforge present:    $([[ -d "$REPO_DIR/.git" ]] && printf 'yes' || printf 'no')"
  echo "module present:       $([[ -d "$hostforge_module_source" ]] && printf 'yes' || printf 'no')"
  echo "server path present:  $([[ -d "$server_path" ]] && printf 'yes' || printf 'no')"
  echo "installed present:    $([[ -d "$module_target" ]] && printf 'yes' || printf 'no')"
}

pull_hostforge_repo() {
  git_pull_repo "$REPO_DIR" "hostforge"
}

schedule_collector_restart() {
  local unit
  unit="$(collector_unit_name)"

  require_systemctl || return 1

  if [[ "${EUID}" -eq 0 ]]; then
    nohup bash -c 'sleep 2; systemctl restart "$1"' _ "$unit" >/dev/null 2>&1 &
  else
    nohup bash -c 'sleep 2; sudo -n systemctl restart "$1"' _ "$unit" >/dev/null 2>&1 &
  fi

  echo "Scheduled $unit restart in 2 seconds."
  echo "The website may briefly disconnect while the updated collector restarts."
}

restart_hostforge_site_from_web() {
  schedule_collector_restart
}

sync_hostforge_module() {
  local server_path module_src module_name module_dst

  if ! command -v rsync >/dev/null 2>&1; then
    echo "[ERROR] Required command not found: rsync"
    return 1
  fi

  server_path="$(bannerlord_root)"
  module_src="$(hostforge_module_source_dir)"
  module_name="$(hostforge_module_name)"
  module_dst="$server_path/Modules/$module_name"

  if [[ ! -d "$module_src" ]]; then
    echo "[ERROR] Missing HostForge module source: $module_src"
    return 1
  fi

  if [[ ! -d "$server_path" ]]; then
    echo "[ERROR] Bannerlord server path does not exist: $server_path"
    return 1
  fi

  echo "== HostForge module sync =="
  echo "Repo:           $REPO_DIR"
  echo "Bannerlord:     $server_path"
  echo "Module source:  $module_src"
  echo "Module target:  $module_dst"

  sync_directory "$module_src" "$module_dst"

  echo "[SUCCESS] HostForge module synced."
}

update_hostforge_module() {
  pull_hostforge_repo || return 1
  sync_hostforge_module
}

list_custom_mods_web() {
  local mods_file key repo_dir module_dir module_name module_source module_target server_path
  mods_file="$(custom_mods_file)"
  server_path="$(bannerlord_root)"

  [[ -f "$mods_file" ]] || return 0

  while IFS=$'\t' read -r key repo_dir module_dir module_name; do
    [[ -n "${key:-}" ]] || continue
    [[ "${key:0:1}" == "#" ]] && continue
    module_source="$(resolve_custom_mod_source_dir "$repo_dir" "$module_dir")"
    module_target="$server_path/Modules/$module_name"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$key" \
      "$repo_dir" \
      "$module_dir" \
      "$module_name" \
      "$module_source" \
      "$([[ -d "$(expand_path "$repo_dir")/.git" ]] && printf 'yes' || printf 'no')" \
      "$([[ -d "$module_source" ]] && printf 'yes' || printf 'no')" \
      "$([[ -d "$module_target" ]] && printf 'yes' || printf 'no')"
  done < "$mods_file"
}

custom_mod_record() {
  local wanted_key="$1"
  local mods_file key repo_dir module_dir module_name
  mods_file="$(custom_mods_file)"
  [[ -f "$mods_file" ]] || return 1

  while IFS=$'\t' read -r key repo_dir module_dir module_name; do
    [[ -n "${key:-}" ]] || continue
    [[ "${key:0:1}" == "#" ]] && continue
    if [[ "$key" == "$wanted_key" ]]; then
      printf '%s\t%s\t%s\t%s\n' "$key" "$repo_dir" "$module_dir" "$module_name"
      return 0
    fi
  done < "$mods_file"

  return 1
}

save_custom_mod() {
  local repo_dir="$1"
  local module_dir="$2"
  local module_name="$3"
  local key mods_file tmp existing_key existing_repo existing_module_dir existing_module_name

  repo_dir="$(trim "$repo_dir")"
  module_dir="$(trim "$module_dir")"
  module_name="$(trim "$module_name")"

  if [[ -z "$repo_dir" || -z "$module_dir" || -z "$module_name" ]]; then
    echo "[ERROR] Git repo directory, module directory, and module name are required."
    return 1
  fi

  if ! valid_module_name "$module_name"; then
    echo "[ERROR] Invalid module name: $module_name"
    echo "Use letters, numbers, dot, underscore, or dash only."
    return 1
  fi

  if [[ "$repo_dir" == *$'\t'* || "$module_dir" == *$'\t'* || "$module_name" == *$'\t'* ]]; then
    echo "[ERROR] Custom mod fields cannot contain tab characters."
    return 1
  fi

  key="$(custom_mod_key "$module_name")"
  if [[ -z "$key" ]]; then
    echo "[ERROR] Could not derive a custom mod key from module name: $module_name"
    return 1
  fi

  mkdir -p "$CONFIG_DIR"
  mods_file="$(custom_mods_file)"
  tmp="$(mktemp)"

  if [[ -f "$mods_file" ]]; then
    while IFS=$'\t' read -r existing_key existing_repo existing_module_dir existing_module_name; do
      [[ -n "${existing_key:-}" ]] || continue
      [[ "$existing_key" == "$key" ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$existing_key" "$existing_repo" "$existing_module_dir" "$existing_module_name"
    done < "$mods_file" > "$tmp"
  else
    : > "$tmp"
  fi

  printf '%s\t%s\t%s\t%s\n' "$key" "$repo_dir" "$module_dir" "$module_name" >> "$tmp"
  sort -u "$tmp" > "$mods_file"
  rm -f "$tmp"

  echo "[OK] Saved custom mod $module_name"
  echo "Repo:   $repo_dir"
  echo "Source: $module_dir"
  echo "Target: $(bannerlord_root)/Modules/$module_name"
}

delete_custom_mod() {
  local key="$1"
  local mods_file tmp existing_key existing_repo existing_module_dir existing_module_name removed=0

  key="$(custom_mod_key "$key")"
  if [[ -z "$key" ]]; then
    echo "[ERROR] Custom mod key is required."
    return 1
  fi

  mods_file="$(custom_mods_file)"
  if [[ ! -f "$mods_file" ]]; then
    echo "[ERROR] No custom mods file exists: $mods_file"
    return 1
  fi

  tmp="$(mktemp)"
  while IFS=$'\t' read -r existing_key existing_repo existing_module_dir existing_module_name; do
    [[ -n "${existing_key:-}" ]] || continue
    if [[ "$existing_key" == "$key" ]]; then
      removed=1
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$existing_key" "$existing_repo" "$existing_module_dir" "$existing_module_name"
  done < "$mods_file" > "$tmp"

  mv "$tmp" "$mods_file"

  if [[ "$removed" != "1" ]]; then
    echo "[ERROR] Custom mod not found: $key"
    return 1
  fi

  echo "[OK] Deleted custom mod entry: $key"
  echo "Installed game files were not removed."
}

pull_custom_mod() {
  local key="$1"
  local record repo_dir module_dir module_name

  key="$(custom_mod_key "$key")"
  record="$(custom_mod_record "$key" || true)"
  if [[ -z "$record" ]]; then
    echo "[ERROR] Custom mod not found: $key"
    return 1
  fi

  IFS=$'\t' read -r _ repo_dir module_dir module_name <<< "$record"
  git_pull_repo "$(expand_path "$repo_dir")" "$module_name"
}

sync_custom_mod() {
  local key="$1"
  local record repo_dir module_dir module_name module_src module_dst server_path

  if ! command -v rsync >/dev/null 2>&1; then
    echo "[ERROR] Required command not found: rsync"
    return 1
  fi

  key="$(custom_mod_key "$key")"
  record="$(custom_mod_record "$key" || true)"
  if [[ -z "$record" ]]; then
    echo "[ERROR] Custom mod not found: $key"
    return 1
  fi

  IFS=$'\t' read -r _ repo_dir module_dir module_name <<< "$record"
  server_path="$(bannerlord_root)"
  module_src="$(resolve_custom_mod_source_dir "$repo_dir" "$module_dir")"
  module_dst="$server_path/Modules/$module_name"

  if [[ ! -d "$module_src" ]]; then
    echo "[ERROR] Missing custom module source: $module_src"
    return 1
  fi

  if [[ ! -d "$server_path" ]]; then
    echo "[ERROR] Bannerlord server path does not exist: $server_path"
    return 1
  fi

  echo "== Custom module sync =="
  echo "Module:        $module_name"
  echo "Repo:          $repo_dir"
  echo "Source:        $module_src"
  echo "Target:        $module_dst"

  sync_directory "$module_src" "$module_dst"

  echo "[SUCCESS] Custom module synced: $module_name"
}

update_custom_mod() {
  local key="$1"
  pull_custom_mod "$key" || return 1
  sync_custom_mod "$key"
}

update_bannerlord_server() {
  local steamcmd_bin install_dir validate args

  steamcmd_bin="${HF_STEAMCMD:-steamcmd}"
  install_dir="$(bannerlord_root)"
  validate="${HF_VALIDATE:-0}"

  if ! command -v "$steamcmd_bin" >/dev/null 2>&1; then
    echo "[ERROR] steamcmd not found: $steamcmd_bin"
    return 1
  fi

  args=("+force_install_dir" "$install_dir" "+login" "anonymous")
  if [[ "$validate" == "1" ]]; then
    args+=("+app_update" "$DEFAULT_STEAM_APP_ID validate")
  else
    args+=("+app_update" "$DEFAULT_STEAM_APP_ID")
  fi
  args+=("+quit")

  mkdir -p "$install_dir"
  "$steamcmd_bin" "${args[@]}"
}

run_profile() {
  local profile="$1"
  local wine_cmd use_xvfb wine_prefix wine_debug wine_dll_overrides debug_mode wine_log_dir
  local wine_virtual_desktop wine_desktop_size params_file config_source config_name
  local path_value root_path bin_dir exe_path native_dir trimmed first_char first_token port_value
  local server_name_value game_type_value dotnet_dump_enabled dotnet_dump_type
  local dotnet_dump_root dotnet_dump_dir dotnet_dump_windows_dir dotnet_dump_name dotnet_dump_log
  local args=()
  local run_cmd=()

  if ! wine_cmd="$(resolve_wine_cmd "${HF_WINE_CMD:-$DEFAULT_WINE_CMD}")"; then
    echo "[ERROR] Wine command not found."
    echo "Tried: ${HF_WINE_CMD:-auto-detect wine, wine-stable, /opt/wine-stable/bin/wine}"
    echo "Run setup again or inspect:"
    echo "  command -v wine wine-stable"
    echo "  ls -la /opt/wine-stable/bin"
    exit 1
  fi
  use_xvfb="${HF_USE_XVFB:-1}"
  wine_prefix="$(wine_prefix_for_profile "$profile")"
  wine_debug="${HF_WINEDEBUG:-$DEFAULT_WINE_DEBUG}"
  wine_dll_overrides="${HF_WINEDLLOVERRIDES:-$DEFAULT_WINE_DLL_OVERRIDES}"
  debug_mode="${HF_DEBUG_MODE:-0}"
  wine_log_dir="${HF_WINE_LOG_DIR:-$DEFAULT_WINE_LOG_DIR}"
  wine_virtual_desktop="${HF_WINE_VIRTUAL_DESKTOP:-1}"
  wine_desktop_size="${HF_WINE_DESKTOP_SIZE:-$DEFAULT_WINE_DESKTOP_SIZE}"
  dotnet_dump_enabled="${HF_DOTNET_DUMP_ENABLED:-$DEFAULT_DOTNET_DUMP_ENABLED}"
  dotnet_dump_type="${HF_DOTNET_DUMP_TYPE:-$DEFAULT_DOTNET_DUMP_TYPE}"
  dotnet_dump_root="${HF_DOTNET_DUMP_DIR:-$DEFAULT_DOTNET_DUMP_DIR}"
  dotnet_dump_dir="$dotnet_dump_root/$profile"

  export WINEPREFIX="$wine_prefix"
  export WINEDEBUG="$wine_debug"
  export WINEDLLOVERRIDES="$wine_dll_overrides"
  export COMPlus_gcServer="${COMPlus_gcServer:-0}"
  export DOTNET_gcServer="${DOTNET_gcServer:-0}"
  export HF_INSTANCE_ID="${HF_INSTANCE_ID:-$profile}"
  export HF_LOG_API_ENABLED="${HF_LOG_API_ENABLED:-1}"
  export HF_LOG_API_URL="${HF_LOG_API_URL:-http://127.0.0.1:$(collector_port)/v1/logs}"

  root_path="$(bannerlord_root)"
  bin_dir="$root_path/bin/Win64_Shipping_Server"
  exe_path="$bin_dir/DedicatedCustomServer.Starter.exe"
  native_dir="$root_path/Modules/Native"
  params_file="$(params_file_for "$profile")"
  config_name="ds_config_${profile}.txt"
  config_source="$(config_file_for "$profile")"

  if [[ ! -f "$params_file" ]]; then
    echo "[ERROR] Missing params file: $params_file"
    exit 1
  fi

  if [[ ! -f "$config_source" ]]; then
    echo "[ERROR] Missing config file: $config_source"
    exit 1
  fi

  if [[ ! -f "$exe_path" ]]; then
    echo "[ERROR] Can't find DedicatedCustomServer.Starter.exe under $bin_dir"
    exit 1
  fi

  mkdir -p "$bin_dir" "$native_dir"
  cp -f "$config_source" "$bin_dir/$config_name"
  cp -f "$config_source" "$native_dir/$config_name"
  server_name_value="$(profile_server_name "$profile" || true)"
  game_type_value="$(profile_game_type "$profile" || true)"
  port_value="$(profile_port "$profile" || true)"

  if [[ "$dotnet_dump_enabled" == "1" ]]; then
    mkdir -p "$dotnet_dump_dir"
    if command -v winepath >/dev/null 2>&1; then
      dotnet_dump_windows_dir="$(winepath -w "$dotnet_dump_dir" 2>/dev/null || true)"
    fi

    if [[ -n "${dotnet_dump_windows_dir:-}" ]]; then
      dotnet_dump_name="${dotnet_dump_windows_dir}\\coreclr-${profile}-%e-%p-%t.dmp"
      dotnet_dump_log="${dotnet_dump_windows_dir}\\createdump-${profile}-%p-%t.log"
    else
      dotnet_dump_name="$dotnet_dump_dir/coreclr-${profile}-%e-%p-%t.dmp"
      dotnet_dump_log="$dotnet_dump_dir/createdump-${profile}-%p-%t.log"
    fi

    export DOTNET_DbgEnableMiniDump=1
    export DOTNET_DbgMiniDumpType="$dotnet_dump_type"
    export DOTNET_DbgMiniDumpName="$dotnet_dump_name"
    export DOTNET_CreateDumpDiagnostics=1
    export DOTNET_CreateDumpLogToFile="$dotnet_dump_log"
    export COMPlus_DbgEnableMiniDump=1
    export COMPlus_DbgMiniDumpType="$dotnet_dump_type"
    export COMPlus_DbgMiniDumpName="$dotnet_dump_name"
    export COMPlus_CreateDumpDiagnostics=1
    export COMPlus_CreateDumpLogToFile="$dotnet_dump_log"
  fi

  while IFS= read -r path_value || [[ -n "$path_value" ]]; do
    trimmed="$(trim "$path_value")"
    if [[ -z "$trimmed" ]]; then
      continue
    fi

    first_char="${trimmed:0:1}"
    if [[ "$first_char" == "#" || "$first_char" == ";" ]]; then
      continue
    fi

    first_token="$(echo "$trimmed" | awk '{print tolower($1)}')"
    if [[ "$first_token" == "/dedicatedcustomserverconfigfile" ]]; then
      continue
    fi

    if [[ "$first_token" == "/port" ]]; then
      port_value="$(echo "$trimmed" | awk '{print $2; exit}')"
      if [[ -z "$port_value" ]]; then
        echo "[ERROR] Invalid /port line in $params_file: $trimmed"
        exit 1
      fi

      args+=("/port" "$port_value")
      continue
    fi

    args+=("$trimmed")
  done < "$params_file"

  echo "Launching Bannerlord profile $profile"
  echo "  Root:           $root_path"
  echo "  Bin dir:        $bin_dir"
  echo "  Executable:     $exe_path"
  echo "  Config:         $config_name"
  echo "  Params:         $params_file"
  echo "  ServerName:     ${server_name_value:-n/a}"
  echo "  GameType:       ${game_type_value:-n/a}"
  echo "  Port:           ${port_value:-n/a}"
  echo "  Wine:           $wine_cmd"
  echo "  Prefix:         $wine_prefix"
  echo "  WINEDEBUG:      $WINEDEBUG"
  echo "  DLL overrides:  $WINEDLLOVERRIDES"
  echo "  GC server:      $COMPlus_gcServer"
  echo "  Logs:           $HF_LOG_API_URL"
  echo "  Dump enabled:   $dotnet_dump_enabled"
  if [[ "$dotnet_dump_enabled" == "1" ]]; then
    echo "  Dump type:      $dotnet_dump_type"
    echo "  Dump dir:       $dotnet_dump_dir"
    echo "  Dump name:      $DOTNET_DbgMiniDumpName"
    echo "  Dump log:       $DOTNET_CreateDumpLogToFile"
  fi

  ensure_wine_prefix "$profile" "$wine_prefix"

  if [[ "$debug_mode" == "1" ]]; then
    mkdir -p "$wine_log_dir"
  fi

  cd "$bin_dir"
  if [[ "$wine_virtual_desktop" == "1" ]]; then
    run_cmd=("$wine_cmd" explorer "/desktop=HostForge-$profile,$wine_desktop_size" DedicatedCustomServer.Starter.exe /dedicatedcustomserverconfigfile "$config_name" "${args[@]}")
  else
    run_cmd=("$wine_cmd" DedicatedCustomServer.Starter.exe /dedicatedcustomserverconfigfile "$config_name" "${args[@]}")
  fi

  printf '  Command:'
  printf ' %q' "${run_cmd[@]}"
  printf '\n'

  if [[ "$debug_mode" == "1" ]]; then
    local log_file
    log_file="$wine_log_dir/wine-${profile}-$(date -u +%Y%m%d-%H%M%S)-p$$.log"
    echo "  Debug:  $log_file"

    if [[ "$use_xvfb" == "1" ]] && command -v xvfb-run >/dev/null 2>&1; then
      xvfb-run -a -s "-screen 0 1024x768x24" "${run_cmd[@]}" 2>&1 | tee -a "$log_file"
      exit "${PIPESTATUS[0]}"
    fi

    "${run_cmd[@]}" 2>&1 | tee -a "$log_file"
    exit "${PIPESTATUS[0]}"
  fi

  if [[ "$use_xvfb" == "1" ]] && command -v xvfb-run >/dev/null 2>&1; then
    exec xvfb-run -a -s "-screen 0 1024x768x24" "${run_cmd[@]}"
  fi

  exec "${run_cmd[@]}"
}

pause_prompt() {
  echo
  read -r -p "Press Enter to continue..." _
}

run_menu_action() {
  if "$@"; then
    return 0
  fi

  local status=$?
  echo
  echo "[WARN] Action returned status $status."
  return 0
}

profile_action_menu() {
  local profile="$1"
  local choice line_count

  while true; do
    echo
    echo "=== Profile: $profile ==="
    echo "Health:  $(profile_health "$profile")"
    echo "Enabled: $(service_enabled_state "$profile")"
    echo "Active:  $(service_active_state "$profile")"
    echo "Port:    $(profile_port "$profile" || true)"
    echo
    echo "1) Inspect"
    echo "2) Activate"
    echo "3) Deactivate"
    echo "4) Restart"
    echo "5) View logs"
    echo "0) Back"
    echo
    read -r -p "Choose a profile action: " choice

    case "$choice" in
      1)
        run_menu_action inspect_profile "$profile"
        pause_prompt
        ;;
      2)
        run_menu_action activate_profile "$profile"
        pause_prompt
        ;;
      3)
        run_menu_action deactivate_profile "$profile"
        pause_prompt
        ;;
      4)
        run_menu_action restart_profile "$profile"
        pause_prompt
        ;;
      5)
        read -r -p "How many log lines? [50] " line_count
        run_menu_action view_logs "$profile" "${line_count:-50}"
        pause_prompt
        ;;
      0)
        return
        ;;
      *)
        echo "Invalid choice."
        pause_prompt
        ;;
    esac
  done
}

profiles_menu() {
  local choice profile selected_profiles

  while true; do
    echo
    echo "=== Profiles ==="
    echo
    echo "1) List profiles"
    echo "2) Open one profile"
    echo "3) Activate multiple profiles"
    echo "4) Deactivate multiple profiles"
    echo "5) Restart multiple profiles"
    echo "0) Back"
    echo
    read -r -p "Choose a profiles action: " choice

    case "$choice" in
      1)
        show_profiles_table
        pause_prompt
        ;;
      2)
        if profile="$(select_profile)"; then
          profile_action_menu "$profile"
        else
          pause_prompt
        fi
        ;;
      3)
        if selected_profiles="$(select_profiles)"; then
          while IFS= read -r profile; do
            [[ -n "$profile" ]] || continue
            echo
            echo "== Activating $profile =="
            run_menu_action activate_profile "$profile"
          done <<< "$selected_profiles"
        fi
        pause_prompt
        ;;
      4)
        if selected_profiles="$(select_profiles)"; then
          while IFS= read -r profile; do
            [[ -n "$profile" ]] || continue
            echo
            echo "== Deactivating $profile =="
            run_menu_action deactivate_profile "$profile"
          done <<< "$selected_profiles"
        fi
        pause_prompt
        ;;
      5)
        if selected_profiles="$(select_profiles)"; then
          while IFS= read -r profile; do
            [[ -n "$profile" ]] || continue
            echo
            echo "== Restarting $profile =="
            run_menu_action restart_profile "$profile"
          done <<< "$selected_profiles"
        fi
        pause_prompt
        ;;
      0)
        return
        ;;
      *)
        echo "Invalid choice."
        pause_prompt
        ;;
    esac
  done
}

system_menu() {
  local choice selected_profiles profile line_count

  while true; do
    echo
    echo "=== System ==="
    echo
    echo "1) Show active services"
    echo "2) Collector status"
    echo "3) View profile logs"
    echo "4) Restart HostForge web service"
    echo "5) Refresh service units"
    echo "6) Patch/update Bannerlord server"
    echo "7) Set Bannerlord dedicated auth token"
    echo "0) Back"
    echo
    read -r -p "Choose a system action: " choice

    case "$choice" in
      1)
        run_menu_action show_active_services
        pause_prompt
        ;;
      2)
        run_menu_action collector_status
        pause_prompt
        ;;
      3)
        if selected_profiles="$(select_profiles)"; then
          read -r -p "How many log lines? [50] " line_count
          line_count="${line_count:-50}"
          while IFS= read -r profile; do
            [[ -n "$profile" ]] || continue
            echo
            echo "== Logs for $profile =="
            run_menu_action view_logs "$profile" "$line_count"
          done <<< "$selected_profiles"
        fi
        pause_prompt
        ;;
      4)
        run_menu_action restart_collector_service
        pause_prompt
        ;;
      5)
        run_menu_action install_service_template
        run_menu_action ensure_collector_running
        pause_prompt
        ;;
      6)
        run_menu_action update_bannerlord_server
        pause_prompt
        ;;
      7)
        run_menu_action prompt_bannerlord_auth_token
        pause_prompt
        ;;
      0)
        return
        ;;
      *)
        echo "Invalid choice."
        pause_prompt
        ;;
    esac
  done
}

firewall_menu() {
  local choice line_count

  while true; do
    echo
    echo "=== Firewall Traffic Tracking ==="
    echo "Unit:  $(firewall_unit_name)"
    echo "Set:   $(firewall_set_name)"
    echo "Ports: $(firewall_ports | paste -sd ' ' -)"
    echo
    echo "1) Status and player packet rates"
    echo "2) Start/enable tracking"
    echo "3) Stop/disable tracking"
    echo "4) Restart tracking"
    echo "5) View logs"
    echo "6) List blacklist"
    echo "7) Remove from blacklist"
    echo "0) Back"
    echo
    read -r -p "Choose a firewall action: " choice

    case "$choice" in
      1)
        run_menu_action firewall_status
        pause_prompt
        ;;
      2)
        run_menu_action firewall_start_service
        pause_prompt
        ;;
      3)
        run_menu_action firewall_stop_service
        pause_prompt
        ;;
      4)
        run_menu_action firewall_restart_service
        pause_prompt
        ;;
      5)
        read -r -p "How many log lines? [80] " line_count
        run_menu_action firewall_logs "${line_count:-80}"
        pause_prompt
        ;;
      6)
        run_menu_action firewall_blacklist_list
        pause_prompt
        ;;
      7)
        if line_count="$(firewall_select_blacklist_ip)"; then
          run_menu_action firewall_blacklist_remove "$line_count"
        fi
        pause_prompt
        ;;
      0)
        return
        ;;
      *)
        echo "Invalid choice."
        pause_prompt
        ;;
    esac
  done
}

cloudflared_menu() {
  local choice line_count

  while true; do
    echo
    echo "=== Cloudflare Quick Tunnel ==="
    echo "Origin URL:  $(cloudflared_origin_url)"
    echo "Public URL:  $(cloudflared_quick_url || printf 'n/a')"
    echo
    echo "1) Status"
    echo "2) Start/enable temporary public URL service"
    echo "3) Stop/disable temporary public URL service"
    echo "4) Restart temporary public URL service"
    echo "5) Temporary public URL service logs"
    echo "0) Back"
    echo
    read -r -p "Choose a Cloudflare action: " choice

    case "$choice" in
      1)
        run_menu_action cloudflared_status
        pause_prompt
        ;;
      2)
        run_menu_action cloudflared_start_service
        pause_prompt
        ;;
      3)
        run_menu_action cloudflared_stop_service
        pause_prompt
        ;;
      4)
        run_menu_action cloudflared_restart_service
        pause_prompt
        ;;
      5)
        read -r -p "How many log lines? [80] " line_count
        run_menu_action cloudflared_service_logs "${line_count:-80}"
        pause_prompt
        ;;
      0)
        return
        ;;
      *)
        echo "Invalid choice."
        pause_prompt
        ;;
    esac
  done
}

repo_maintenance_menu() {
  local choice

  while true; do
    echo
    echo "=== Repo Maintenance ==="
    echo "hostforge:        $REPO_DIR"
    echo "hostforge module: $(hostforge_module_source_dir)"
    echo
    echo "1) Status"
    echo "2) Sync HostForge module"
    echo "3) Update HostForge module"
    echo "0) Back"
    echo
    read -r -p "Choose a repo action: " choice

    case "$choice" in
      1)
        run_menu_action hostforge_module_status
        pause_prompt
        ;;
      2)
        run_menu_action sync_hostforge_module
        pause_prompt
        ;;
      3)
        run_menu_action update_hostforge_module
        pause_prompt
        ;;
      0)
        return
        ;;
      *)
        echo "Invalid choice."
        pause_prompt
        ;;
    esac
  done
}

interactive_menu() {
  local choice

  while true; do
    echo
    echo "=== HostForge Terminal ==="
    echo "Repo:          $REPO_DIR"
    echo "Config dir:    $CONFIG_DIR"
    echo "Game path:     $(bannerlord_root)"
    echo "Collector URL: $(collector_public_url)"
    echo
    echo "1) Profiles"
    echo "2) System"
    echo "3) Firewall traffic"
    echo "4) Cloudflare tunnel"
    echo "5) Repo maintenance"
    echo "0) Exit"
    echo
    read -r -p "Choose an action: " choice

    case "$choice" in
      1)
        profiles_menu
        ;;
      2)
        system_menu
        ;;
      3)
        firewall_menu
        ;;
      4)
        cloudflared_menu
        ;;
      5)
        repo_maintenance_menu
        ;;
      0)
        exit 0
        ;;
      *)
        echo "Invalid choice."
        pause_prompt
        ;;
    esac
  done
}

command_mode() {
  case "${1:-}" in
    __run-profile)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      run_profile "$2"
      ;;
    __install-service-template)
      install_service_template
      ;;
    __start-collector)
      ensure_collector_running
      ;;
    __collector-status)
      collector_status
      ;;
    __collector-logs)
      collector_logs "${2:-80}"
      ;;
    __rebuild-log-site)
      rebuild_log_site
      ;;
    __restart-collector)
      restart_collector_service
      ;;
    __update-bannerlord)
      update_bannerlord_server
      ;;
    __set-bannerlord-token)
      if [[ -n "${2:-}" ]]; then
        write_bannerlord_auth_token "$2"
      else
        prompt_bannerlord_auth_token
      fi
      ;;
    __list-profiles)
      show_profiles_table
      ;;
    __discover-profiles)
      web_discover_profiles
      ;;
    __inspect-profile)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      web_inspect_profile "$2"
      ;;
    __profile-files-web)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      web_profile_files "$2"
      ;;
    __profile-save-files-web)
      if [[ -z "${2:-}" || -z "${3:-}" || -z "${4:-}" ]]; then
        echo "[ERROR] Missing profile name, params file, or config file."
        exit 1
      fi
      web_wrap_action "Save profile $2" save_profile_files "$2" "$3" "$4"
      ;;
    __profile-delete-files-web)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      web_wrap_action "Delete profile $2" delete_profile_files "$2"
      ;;
    __activate-profile)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      web_wrap_action "Activate profile $2" activate_profile "$2"
      ;;
    __deactivate-profile)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      web_wrap_action "Deactivate profile $2" deactivate_profile "$2"
      ;;
    __restart-profile)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      web_wrap_action "Restart profile $2" restart_profile "$2"
      ;;
    __profile-logs)
      if [[ -z "${2:-}" ]]; then
        echo "[ERROR] Missing profile name."
        exit 1
      fi
      view_logs "$2" "${3:-50}"
      ;;
    __refresh-services)
      web_wrap_action "Refresh service templates" ensure_collector_running
      ;;
    __active-services)
      show_active_services
      ;;
    __collector-status-web)
      web_collector_status
      ;;
    __repo-status-web)
      web_repo_status
      ;;
    __custom-mods-web)
      list_custom_mods_web
      ;;
    __custom-mod-save-web)
      web_wrap_action "Save custom mod ${4:-}" save_custom_mod "${2:-}" "${3:-}" "${4:-}"
      ;;
    __custom-mod-delete-web)
      web_wrap_action "Delete custom mod ${2:-}" delete_custom_mod "${2:-}"
      ;;
    __custom-mod-pull-web)
      web_wrap_action "Pull custom mod ${2:-}" pull_custom_mod "${2:-}"
      ;;
    __custom-mod-sync-web)
      web_wrap_action "Sync custom mod ${2:-}" sync_custom_mod "${2:-}"
      ;;
    __custom-mod-update-web)
      web_wrap_action "Update custom mod ${2:-}" update_custom_mod "${2:-}"
      ;;
    __collector-logs-web)
      collector_logs "${2:-80}"
      ;;
    __clear-dumps-web)
      web_wrap_action "Clear crash dumps" clear_crash_dumps "${2:-}"
      ;;
    __update-bannerlord-web)
      web_wrap_action "Update Bannerlord dedicated server" update_bannerlord_server
      ;;
    __cloudflared-status)
      cloudflared_status
      ;;
    __cloudflared-start-service)
      cloudflared_start_service
      ;;
    __cloudflared-stop-service)
      cloudflared_stop_service
      ;;
    __cloudflared-restart-service)
      cloudflared_restart_service
      ;;
    __cloudflared-logs)
      cloudflared_service_logs "${2:-80}"
      ;;
    __firewall-apply-root)
      firewall_apply_rules
      ;;
    __firewall-remove-root)
      firewall_remove_rules
      ;;
    __firewall-status)
      firewall_status
      ;;
    __firewall-start)
      firewall_start_service
      ;;
    __firewall-stop)
      firewall_stop_service
      ;;
    __firewall-restart)
      firewall_restart_service
      ;;
    __firewall-logs)
      firewall_logs "${2:-80}"
      ;;
    __firewall-blacklist)
      firewall_blacklist_list
      ;;
    __firewall-unblacklist)
      firewall_blacklist_remove "${2:-}"
      ;;
    __firewall-status-web)
      web_firewall_status
      ;;
    __firewall-players-web)
      firewall_player_rates "${2:-1}"
      ;;
    __firewall-blacklist-web)
      firewall_blacklist_snapshot
      ;;
    __firewall-geo-countries-web)
      firewall_geo_list_countries
      ;;
    __firewall-geo-save-web)
      web_wrap_action "Save geo country ${2:-}" firewall_geo_save_country "${2:-}" "${3:-}"
      ;;
    __firewall-geo-save-file-web)
      web_wrap_action "Save geo country ${2:-}" firewall_geo_save_country_file "${2:-}" "${3:-}"
      ;;
    __firewall-geo-delete-web)
      web_wrap_action "Delete geo country ${2:-}" firewall_geo_delete_country "${2:-}"
      ;;
    __firewall-geo-apply-web)
      web_wrap_action "Apply geo country blocks" firewall_restart_service
      ;;
    __firewall-blacklist-add-web)
      web_wrap_action "Add ${2:-} to firewall blacklist" firewall_blacklist_add "${2:-}"
      ;;
    __firewall-blacklist-remove-web)
      web_wrap_action "Remove ${2:-} from firewall blacklist" firewall_blacklist_remove "${2:-}"
      ;;
    __firewall-blacklist-clear-web)
      web_wrap_action "Clear firewall blacklist" firewall_blacklist_clear
      ;;
    __firewall-start-web)
      web_wrap_action "Start firewall player tracking" firewall_start_service
      ;;
    __firewall-stop-web)
      web_wrap_action "Stop firewall player tracking" firewall_stop_service
      ;;
    __firewall-restart-web)
      web_wrap_action "Restart firewall player tracking" firewall_restart_service
      ;;
    __firewall-logs-web)
      firewall_logs "${2:-80}"
      ;;
    __repo-status)
      hostforge_module_status
      ;;
    __repo-pull-hostforge-web)
      web_wrap_action "Update hostforge" pull_hostforge_repo
      ;;
    __collector-restart-web)
      web_wrap_action "Restart HostForge website" restart_hostforge_site_from_web
      ;;
    __repo-sync-hostforge-module-web)
      web_wrap_action "Sync HostForge module" sync_hostforge_module
      ;;
    __repo-update-hostforge-module-web)
      web_wrap_action "Update HostForge module" update_hostforge_module
      ;;
    __repo-pull-hostforge)
      pull_hostforge_repo
      ;;
    __repo-sync-hostforge-module)
      sync_hostforge_module
      ;;
    __repo-update-hostforge-module)
      update_hostforge_module
      ;;
    "")
      interactive_menu
      ;;
    *)
      echo "[ERROR] Unknown command: $1"
      exit 1
      ;;
  esac
}

mkdir -p "$CONFIG_DIR" "$REPO_DIR/logs/wine" "$REPO_DIR/logs/instances"
if [[ "$#" -eq 0 ]]; then
  command_mode ""
else
  command_mode "$@"
fi
