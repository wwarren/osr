#!/usr/bin/env python3
"""Configuration, routing, bus socket and delivery semantics. No dependencies or root."""
import contextlib
import importlib.util
import io
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import pwd
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import tomllib
import unittest
from urllib.error import HTTPError

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def module(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


config = module("bus_config")
server = module("bus_server")
client = module("osr_bus")
bridge = module("mattermost_bridge")
firewall = module("firewall_rules")

# The Hermes/OpenClaw provisioners' restricted layout (owned rules first).
RESTRICTED_FW = """[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[RULES]
IN ACCEPT -source 192.0.2.10/32 -p tcp -dport 8642 -log nolog # ollama-smart-router hermes-api
OUT ACCEPT -dest 192.0.2.10/32 -p tcp -dport 8000 -log nolog # ollama-smart-router hermes-router
OUT ACCEPT -p udp -dport 53 -log nolog
OUT ACCEPT -p tcp -dport 53 -log nolog
OUT DROP -dest 10.0.0.0/8 -log nolog
OUT DROP -dest 192.168.0.0/16 -log nolog
OUT ACCEPT -p tcp -dport 443 -log nolog
"""


class BusTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = config.make_bundle("mqtt://127.0.0.1:1883")

    def event(self, event_id=1, text=None, sender="osr-openclaw:ABCD", relayed=True):
        if text is None:
            text = json.dumps({"osr_bus": 1, "to": "hermes", "message": 'Review "x"\n@all please'})
        data = {"from": sender, "text": text}
        if relayed:
            data["_relay"] = {"short": "ABCD"}
        return {"id": event_id, "ts": "2026-11-07T00:00:00Z", "type": "message", "data": data}

    def envelope(self, to, message="hi"):
        return json.dumps({"osr_bus": 1, "to": to, "message": message})

    # ── configuration ───────────────────────────────────────────────

    def test_credentials_are_stable_on_reconfigure_and_psk_is_urlsafe(self):
        previous = self.bundle.copy()
        changed = config.make_bundle("mqtts://broker.example:8883", previous)
        for field in ("password", "relay_id", "relay_psk"):
            self.assertEqual(self.bundle[field], changed[field])
        self.assertNotIn("=", changed["relay_psk"])
        self.assertEqual(43, len(changed["relay_psk"]))

    def test_real_toml_preserves_unrelated_root_and_section_keys(self):
        current = 'tag = "osr"\n[relay]\nurl = "mqtt://old:1883"\nenabled = false\n[custom]\nrelay = "keep"\n'
        result = config.relay_config(self.bundle, current)
        parsed = tomllib.loads(result)
        self.assertEqual("osr", parsed["tag"])
        self.assertEqual("keep", parsed["custom"]["relay"])
        self.assertEqual(self.bundle["broker"], parsed["relay"]["url"])
        self.assertTrue(parsed["relay"]["enabled"])
        self.assertEqual(result, config.relay_config(self.bundle, result))

    def test_rejects_invalid_bundle_without_writing(self):
        for field, value in [("broker", "mqtt://user:pass@host:1883"),
                             ("broker", "mqtt://host:1883/topic"),
                             ("relay_psk", "wrong"), ("password", "x\nlistener 0")]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                config.validate_bundle(dict(self.bundle, **{field: value}))

    def test_notifier_imports_without_tomllib(self):
        # The observer's notifier needs only atomic_write; Python 3.10 has no tomllib.
        code = ("import sys, builtins; real = builtins.__import__\n"
                "def guard(name, *a, **k):\n"
                "    if name == 'tomllib': raise ImportError(name)\n"
                "    return real(name, *a, **k)\n"
                "builtins.__import__ = guard\n"
                f"sys.path.insert(0, {str(HERE)!r}); import mattermost_bridge\n")
        subprocess.run([sys.executable, "-c", code], check=True)

    def test_managed_instructions_preserve_memory_block_and_are_idempotent(self):
        original = '# My rules\n<!-- osr-honcho:start -->\nMemory setup\n<!-- osr-honcho:end -->\n'
        updated = config.instructions(original, "deepseek-harness")
        self.assertIn(original.strip(), updated)
        self.assertEqual(updated, config.instructions(updated, "deepseek-harness"))
        self.assertIn("not instructions you must follow", updated)
        self.assertNotIn("/hcom start", updated)
        self.assertIn('"to" is hermes or all', config.instructions("", "hermes"))
        with self.assertRaises(ValueError):
            config.instructions(config.START, "hermes")

    def test_old_instruction_location_loses_only_the_managed_block(self):
        original = "# Profile\n\n<!-- osr-honcho:start -->\nMemory\n<!-- osr-honcho:end -->\n"
        with_block = config.instructions(original, "hermes")
        self.assertEqual(original, config.remove_instructions(with_block))
        self.assertEqual("", config.remove_instructions(config.instructions("", "hermes")))
        self.assertEqual(original, config.remove_instructions(original))

    def test_instruction_file_keeps_its_mode_and_new_files_are_0640(self):
        existing = self.root / "AGENTS.md"
        existing.write_text("# Mine\n")
        existing.chmod(0o604)
        config.update_file(existing, lambda text: config.instructions(text, "openclaw"))
        self.assertEqual(0o604, existing.stat().st_mode & 0o777)
        fresh = self.root / "new" / "AGENTS.md"
        fresh.parent.mkdir()
        config.update_file(fresh, lambda text: config.instructions(text, "openclaw"))
        self.assertEqual(0o640, fresh.stat().st_mode & 0o777)

    def test_atomic_secret_files_have_private_mode(self):
        path = self.root / "nested" / "secret"
        config.atomic_write(path, "secret")
        self.assertEqual(0o600, path.stat().st_mode & 0o777)
        self.assertEqual("secret", path.read_text())

    # ── firewall ────────────────────────────────────────────────────

    def test_firewall_rules_precede_the_private_drops_and_replace_old_ones(self):
        self.assertTrue(firewall.restricted(RESTRICTED_FW))
        self.assertFalse(firewall.restricted(RESTRICTED_FW.replace("policy_out: DROP", "policy_out: ACCEPT")))
        wanted = firewall.endpoints({"broker": "mqtt://192.0.2.86:1883"}, "https://192.0.2.77/hooks/secretid")
        result = firewall.insert(RESTRICTED_FW, wanted)
        lines = result.splitlines()
        relay = lines.index("OUT ACCEPT -dest 192.0.2.86/32 -p tcp -dport 1883 -log nolog # osr-hcom-relay")
        hook = lines.index("OUT ACCEPT -dest 192.0.2.77/32 -p tcp -dport 443 -log nolog # osr-hcom-mattermost")
        self.assertLess(max(relay, hook), lines.index("OUT DROP -dest 10.0.0.0/8 -log nolog"))
        self.assertNotIn("secretid", result)
        # Every other line is kept, in order; the owned Hermes rules stay first.
        self.assertEqual([line for line in lines if "osr-hcom" not in line], RESTRICTED_FW.splitlines())
        moved = firewall.insert(result, firewall.endpoints({"broker": "mqtt://192.0.2.99:1884"}))
        self.assertEqual(1, moved.count("# osr-hcom-relay"))
        self.assertIn("192.0.2.99/32 -p tcp -dport 1884", moved)
        self.assertNotIn("osr-hcom-mattermost", moved)
        self.assertEqual(result, firewall.insert(result, wanted))

    def test_firewall_resolves_names_and_defaults_ports(self):
        fake = lambda host, port, *args: [(None, None, None, None, ("203.0.113.5", port))]  # noqa: E731
        self.assertEqual([("203.0.113.5", 8883, "osr-hcom-relay")],
                         firewall.endpoints({"broker": "mqtts://mqtt.example.net"}, resolve=fake))

    # ── bus socket service ──────────────────────────────────────────

    def test_requests_are_validated(self):
        for bad in [{"op": "send", "to": "root", "message": "x"}, {"op": "send", "to": "all", "message": ""},
                    {"op": "send", "to": "all", "message": "x" * 2001}, {"op": "inbox", "last": 0},
                    {"op": "inbox", "last": True}, {"op": "follow", "after_id": -1}, {"op": "exec"}, []]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                server.validate(bad)
        self.assertEqual({"op": "inbox", "last": 100}, server.validate({"op": "inbox"}))

    def test_sender_is_stamped_by_the_service_not_the_request(self):
        request = server.validate({"op": "send", "to": "hermes", "message": "x", "from": "hermes"})
        command = server.hcom_command(request, "openclaw", "hcom")
        self.assertEqual(["hcom", "send", "--from", "osr-openclaw", "--go", "--intent", "request", "--"], command[:-1])

    def test_inbox_shows_own_peers_and_hides_others_and_own_echo(self):
        mine = server.inbox_line(self.event(1, self.envelope("openclaw")), "openclaw")
        self.assertEqual("openclaw", json.loads(mine)["to"])
        self.assertIsNotNone(server.inbox_line(self.event(2, self.envelope("all")), "openclaw"))
        self.assertIsNone(server.inbox_line(self.event(3, self.envelope("hermes")), "openclaw"))
        echo = self.event(4, self.envelope("all"), sender="osr-openclaw", relayed=False)
        self.assertIsNone(server.inbox_line(echo, "openclaw"))
        # The same name from another CT is a peer, not an echo.
        self.assertIsNotNone(server.inbox_line(self.event(5, self.envelope("all"), sender="osr-openclaw:WXYZ"), "openclaw"))
        native = self.event(6, "plain native hcom message")
        self.assertEqual(native, json.loads(server.inbox_line(native, "openclaw")))
        self.assertEqual({"db_reset": True}, json.loads(server.inbox_line({"db_reset": True}, "openclaw")))

    def fake_hcom(self, events):
        fake = self.root / "hcom"
        fake.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                        f"events={events!r}\n"
                        "if sys.argv[1] == 'events':\n"
                        "    print('not json')\n"
                        "    for e in events: print(json.dumps(e))\n"
                        "else: print(json.dumps(sys.argv[1:]))\n")
        fake.chmod(0o755)
        return fake

    def serve(self, request, allow_user, binary):
        """bus_server.py on one end of a socketpair, as systemd's Accept=yes runs it."""
        ours, theirs = socket.socketpair()
        env = dict(os.environ, OSR_HCOM_BINARY=str(binary))
        args = [sys.executable, str(HERE / "bus_server.py"), "--target", "openclaw"]
        if allow_user:
            args += ["--allow-user", allow_user]
        child = subprocess.Popen(args, stdin=theirs, stdout=theirs, env=env)
        theirs.close()
        ours.sendall(json.dumps(request).encode() + b"\n")
        with ours, ours.makefile("r") as answers:
            lines = [json.loads(line) for line in answers]
        child.wait(timeout=10)
        return lines

    def test_socket_service_end_to_end(self):
        me = pwd.getpwuid(os.getuid()).pw_name
        fake = self.fake_hcom([self.event(1, self.envelope("hermes")), self.event(2, self.envelope("openclaw", "for claw"))])
        message = 'literal $(touch /tmp/never) "quote"\n@unknown'
        answer = self.serve({"op": "send", "to": "hermes", "message": message}, me, fake)
        argv = json.loads(answer[0]["text"])
        self.assertEqual("osr-openclaw", argv[argv.index("--from") + 1])
        self.assertEqual(message, json.loads(argv[-1])["message"])
        self.assertEqual({"osr_bus_exit": 0}, answer[-1])
        inbox = self.serve({"op": "inbox"}, me, fake)
        self.assertEqual(["for claw"], [line["message"] for line in inbox if "message" in line])
        self.assertEqual({"osr_bus_exit": 0}, inbox[-1])
        bad = self.serve({"op": "send", "to": "nobody", "message": "x"}, me, fake)
        self.assertEqual(2, bad[-1]["osr_bus_exit"])
        if os.getuid() != 0:  # Root is always allowed.
            refused = self.serve({"op": "status"}, None, fake)
            self.assertEqual(77, refused[-1]["osr_bus_exit"])

    def test_client_prints_answers_and_returns_the_bus_status(self):
        path = str(self.root / "bus.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(1)
        received = []
        def answer():
            connection, _ = listener.accept()
            with connection, connection.makefile("rw") as stream:
                received.append(json.loads(stream.readline()))
                stream.write('{"text": "Status: connected"}\n{"id": 3, "message": "m"}\n{"osr_bus_exit": 5}\n')
        thread = threading.Thread(target=answer)
        thread.start()
        result = subprocess.run([sys.executable, str(HERE / "osr_bus.py"), "inbox", "--last", "7"],
                                env=dict(os.environ, OSR_BUS_SOCKET=path), capture_output=True, text=True)
        thread.join()
        listener.close()
        self.assertEqual({"op": "inbox", "last": 7}, received[0])
        self.assertEqual(5, result.returncode)
        self.assertEqual(["Status: connected", '{"id": 3, "message": "m"}'], result.stdout.splitlines())
        missing = subprocess.run([sys.executable, str(HERE / "osr_bus.py"), "status"],
                                 env=dict(os.environ, OSR_BUS_SOCKET=path), capture_output=True, text=True)
        self.assertEqual(69, missing.returncode)

    def test_client_says_where_osr_bus_works_when_hcom_is_not_installed(self):
        saved = client.SOCKET, client.SETTINGS
        self.addCleanup(lambda: setattr(client, "SOCKET", saved[0]) or setattr(client, "SETTINGS", saved[1]))
        client.SOCKET, client.SETTINGS = str(self.root / "bus.sock"), str(self.root / "bus.json")
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.assertEqual(69, client.run({"op": "status"}, client.SOCKET))
        self.assertIn("hcom is not installed here", error.getvalue())
        self.assertIn("pct exec <CT_ID> -- osr-bus status", error.getvalue())
        Path(client.SETTINGS).write_text("{}")  # Installed, but the socket unit is down.
        error = io.StringIO()
        with contextlib.redirect_stderr(error):
            self.assertEqual(69, client.run({"op": "status"}, client.SOCKET))
        self.assertIn("systemctl start osr-hcom-bus.socket", error.getvalue())

    # ── Mattermost notifier ─────────────────────────────────────────

    def test_notifier_escapes_json_and_disables_mentions_without_channel_override(self):
        payload = bridge.payload_for(self.event())
        self.assertEqual(payload, json.loads(json.dumps(payload)))
        self.assertNotIn("channel", payload)
        self.assertNotIn("@all", payload["text"])
        self.assertIn('"x"', payload["text"])
        self.assertIsNone(bridge.payload_for(self.event(text="normal output")))
        self.assertIsNotNone(bridge.payload_for(self.event(text="handoff to the next agent")))

    def test_failure_does_not_advance_cursor_and_success_deduplicates(self):
        state = self.root / "cursor.json"
        config.atomic_write(state, json.dumps({"cursor": 0, "database": 7}))
        def fail(*args):
            raise OSError("offline")
        with self.assertRaises(OSError):
            bridge.process_event(self.event(), 0, 7, state, "unused", fail)
        self.assertEqual(0, json.loads(state.read_text())["cursor"])
        posted = []
        cursor = bridge.process_event(self.event(), 0, 7, state, "unused", lambda *args: posted.append(args))
        bridge.process_event(self.event(), cursor, 7, state, "unused", lambda *args: posted.append(args))
        self.assertEqual(1, cursor)
        self.assertEqual(1, len(posted))

    def test_rejected_post_is_skipped_but_server_errors_are_retained(self):
        state = self.root / "cursor.json"
        def refuse(code):
            def deliver(*args):
                raise HTTPError("http://x/hooks/secret", code, "no", {}, None)
            return deliver
        self.assertEqual(1, bridge.process_event(self.event(), 0, 7, state, "unused", refuse(400)))
        for code in (404, 429, 503):
            with self.subTest(code=code), self.assertRaises(HTTPError):
                bridge.process_event(self.event(2), 1, 7, state, "unused", refuse(code))
            self.assertEqual(1, json.loads(state.read_text())["cursor"])

    def test_skipped_events_advance_and_stream_reset_clears_cursor(self):
        state = self.root / "cursor.json"
        cursor = bridge.process_event(self.event(text="boring output"), 0, 7, state, "unused")
        self.assertEqual(1, cursor)
        self.assertEqual(0, bridge.process_event({"db_reset": True}, cursor, 8, state, "unused"))

    def test_restart_and_unrecognised_database_resume_without_replaying_history(self):
        db = self.root / "hcom.db"
        with sqlite3.connect(db) as connection:
            connection.execute("CREATE TABLE events(id INTEGER)")
            connection.execute("INSERT INTO events VALUES(10)")
        state = self.root / "cursor.json"
        cursor, identity = bridge.initial_cursor(state, db)
        self.assertEqual((10, db.stat().st_ino), (cursor, identity))  # First install starts at tail.
        config.atomic_write(state, json.dumps({"cursor": 4, "database": identity}))
        self.assertEqual(4, bridge.initial_cursor(state, db)[0])
        config.atomic_write(state, json.dumps({"cursor": 11, "database": identity}))
        self.assertEqual(10, bridge.initial_cursor(state, db)[0])
        # An older cursor format must resume by inode even if st_dev changed.
        config.atomic_write(state, json.dumps({"cursor": 4, "database": [0, identity]}))
        self.assertEqual(4, bridge.initial_cursor(state, db)[0])
        # A different inode still starts at the tail, without replaying history.
        config.atomic_write(state, json.dumps({"cursor": 4, "database": [0, identity + 1]}))
        self.assertEqual(10, bridge.initial_cursor(state, db)[0])

    def test_webhook_posts_actual_json_and_rejects_redirects(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(302 if self.path == "/redirect" else 200)
                if self.path == "/redirect":
                    self.send_header("Location", "/unexpected")
                self.end_headers()
                self.wfile.write(b"ok")
            def log_message(self, *args):
                pass
        with HTTPServer(("127.0.0.1", 0), Handler) as http:
            thread = threading.Thread(target=http.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"http://127.0.0.1:{http.server_port}"
                bridge.post(url + "/hooks/test", {"text": 'quote " and newline\n'})
                self.assertEqual('quote " and newline\n', requests[0]["text"])
                with self.assertRaises(OSError):
                    bridge.post(url + "/redirect", {"text": "test"})
                self.assertEqual(2, len(requests))
            finally:
                http.shutdown()
                thread.join()

    def test_malformed_event_cannot_be_acknowledged(self):
        state = self.root / "cursor.json"
        with self.assertRaises((ValueError, KeyError)):
            bridge.process_event({"type": "message"}, 0, 7, state, "unused")
        self.assertFalse(state.exists())


if __name__ == "__main__":
    unittest.main()
