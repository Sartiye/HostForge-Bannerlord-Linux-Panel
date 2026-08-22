import http.client
import importlib.util
import json
import tempfile
import time
import unittest
import uuid
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread


MODULE_PATH = Path(__file__).resolve().parents[1] / "app" / "hostforge_collector.py"
SPEC = importlib.util.spec_from_file_location("hostforge_collector", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
hostforge_collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hostforge_collector)


class RecordingCollector(hostforge_collector.HostForgeCollector):
    def __init__(self, config):
        self.restore_inputs = []
        super().__init__(config)

    def _apply_player_ipset_restore(self, restore_input):
        self.restore_inputs.append(restore_input)


class QuietHostForgeHandler(hostforge_collector.HostForgeHandler):
    def log_message(self, format_string, *args):
        pass


class PlayerIpSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        data_dir = Path(self.temporary_directory.name)
        config = hostforge_collector.CollectorConfig(
            bind="127.0.0.1",
            port=8080,
            data_dir=data_dir,
            tail_line_count=20,
            max_log_bytes=1024,
            site_title="test",
            repo_dir=data_dir,
            hostforge_script=data_dir / "hostforge.sh",
            web_password="",
            web_session_ttl_seconds=60,
        )
        self.collector = RecordingCollector(config)
        self.generations = {}

    def tearDown(self):
        self.temporary_directory.cleanup()

    def snapshot(self, instance_id, revision, ips, generation=None):
        if generation is None:
            generation = self.generations.setdefault(instance_id, str(uuid.uuid4()))
        return {
            "instanceId": instance_id,
            "generation": generation,
            "revision": revision,
            "timestamp": "2026-08-21T12:00:00Z",
            "ips": ips,
        }

    def test_union_keeps_shared_nat_address_until_last_instance_leaves(self):
        self.collector.ingest_player_ips(self.snapshot("siege-1", 1, ["203.0.113.10", "198.51.100.7"]))
        self.collector.ingest_player_ips(self.snapshot("battle-1", 1, ["203.0.113.10"]))
        self.assertEqual({"198.51.100.7", "203.0.113.10"}, self.collector.applied_player_ips)

        self.collector.ingest_player_ips(self.snapshot("siege-1", 2, []))
        self.assertEqual({"203.0.113.10"}, self.collector.applied_player_ips)
        self.assertIn("del hostforge_verified_players 198.51.100.7", self.collector.restore_inputs[-1])

    def test_older_revision_is_ignored(self):
        self.collector.ingest_player_ips(self.snapshot("siege-1", 2, ["203.0.113.10"]))
        result = self.collector.ingest_player_ips(self.snapshot("siege-1", 1, ["198.51.100.7"]))
        self.assertEqual("ignored", result[3])
        self.assertEqual({"203.0.113.10"}, self.collector.applied_player_ips)

    def test_unchanged_heartbeat_does_not_apply_ipset_again(self):
        self.collector.ingest_player_ips(self.snapshot("siege-1", 1, ["203.0.113.10"]))
        restore_count = len(self.collector.restore_inputs)
        self.collector.ingest_player_ips(self.snapshot("siege-1", 2, ["203.0.113.10"]))
        self.assertEqual(restore_count, len(self.collector.restore_inputs))

    def test_same_revision_with_different_content_is_rejected(self):
        self.collector.ingest_player_ips(self.snapshot("siege-1", 1, ["203.0.113.10"]))
        with self.assertRaisesRegex(ValueError, "different IP snapshot"):
            self.collector.ingest_player_ips(self.snapshot("siege-1", 1, ["198.51.100.7"]))

    def test_stale_instance_is_removed_from_union(self):
        self.collector.ingest_player_ips(self.snapshot("siege-1", 1, ["203.0.113.10"]))
        self.collector.player_ip_snapshots["siege-1"].received_at = time.monotonic() - 31
        self.collector.ingest_player_ips(self.snapshot("battle-1", 1, []))
        self.assertEqual(set(), self.collector.applied_player_ips)
        self.assertIn("del hostforge_verified_players 203.0.113.10", self.collector.restore_inputs[-1])

    def test_ipv6_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "only IPv4"):
            self.collector.ingest_player_ips(self.snapshot("siege-1", 1, ["2001:db8::1"]))

    def test_loopback_http_endpoint_accepts_snapshot(self):
        QuietHostForgeHandler.collector = self.collector
        server = ThreadingHTTPServer(("127.0.0.1", 0), QuietHostForgeHandler)
        server_thread = Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
        try:
            body = json.dumps(self.snapshot("siege-1", 1, ["203.0.113.10"]))
            connection.request("PUT", "/v1/firewall/player-ips", body=body, headers={"Content-Type": "application/json"})
            response = connection.getresponse()
            response_body = json.loads(response.read().decode("utf-8"))
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)

        self.assertEqual(202, response.status)
        self.assertEqual("accepted", response_body["status"])
        self.assertEqual(1, response_body["ipCount"])


if __name__ == "__main__":
    unittest.main()
