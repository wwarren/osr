"""Mock the WebUI admin API and the terminal to check safe connection updates.

Run: python3 targets/open-terminal/test-integration.py (stdlib only).
"""
import http.server
import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).with_name("integrate-webui.py")
SPEC = importlib.util.spec_from_file_location("integrate_webui", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Handler(http.server.BaseHTTPRequestHandler):
    """One server plays both parts: Open WebUI's admin API and, at /files/cwd,
    the terminal (which, like Open Terminal, wants its own bearer key)."""
    connections = []
    posts = 0
    verify_ok = True
    terminal_key = "terminal-secret"
    list_override = None

    def log_message(self, *_args):
        pass

    def reply(self, status, value):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/files/cwd":
            if self.headers.get("Authorization") != f"Bearer {self.terminal_key}":
                self.reply(401, {"detail": "Invalid API key"})
            else:
                self.reply(200, {"cwd": "/srv/open-terminal/workspace"})
            return
        self.assert_authorized()
        if self.path == "/api/v1/configs/terminal_servers":
            value = self.list_override if self.list_override is not None else self.connections
            self.reply(200, {"TERMINAL_SERVER_CONNECTIONS": value})
        else:
            self.reply(404, {})

    def do_POST(self):
        self.assert_authorized()
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.endswith("/verify"):
            self.reply(200 if self.verify_ok else 400,
                       {"status": self.verify_ok, "type": "terminal"})
        elif self.path == "/api/v1/configs/terminal_servers":
            type(self).posts += 1
            type(self).connections = body["TERMINAL_SERVER_CONNECTIONS"]
            self.reply(200, body)
        else:
            self.reply(404, {})

    def assert_authorized(self):
        if self.headers.get("Authorization") != "Bearer admin-secret":
            self.reply(403, {})
            raise AssertionError("Missing admin authorization")


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        Handler.connections = [{"id": "other", "url": "http://other:8000", "key": "old"}]
        Handler.posts = 0
        Handler.verify_ok = True
        Handler.terminal_key = "terminal-secret"
        Handler.list_override = None
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.temp = tempfile.TemporaryDirectory()
        self.admin = pathlib.Path(self.temp.name, "admin")
        self.key = pathlib.Path(self.temp.name, "key")
        self.admin.write_text("admin-secret\n")
        self.key.write_text("terminal-secret\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def invoke(self):
        argv = ["integrate-webui.py", "--webui-url", f"http://127.0.0.1:{self.server.server_port}",
                "--terminal-url", f"http://127.0.0.1:{self.server.server_port}",
                "--id", "open-terminal-lxc-281",
                "--admin-token-file", str(self.admin), "--terminal-key-file", str(self.key)]
        with patch("sys.argv", argv):
            MODULE.main()

    def test_add_and_rerun_preserves_other_connection_and_grants(self):
        self.invoke()
        self.assertEqual(len(Handler.connections), 2)
        self.assertEqual(Handler.connections[0]["id"], "other")
        ours = Handler.connections[1]
        self.assertEqual(ours["key"], "terminal-secret")
        self.assertEqual(ours["config"], {"access_grants": []})
        ours["config"]["access_grants"] = [{"principal_type": "group", "principal_id": "trusted", "permission": "read"}]
        self.invoke()
        self.assertEqual(len(Handler.connections), 2)
        self.assertEqual(Handler.connections[1]["config"]["access_grants"][0]["principal_id"], "trusted")

    def test_failed_verify_does_not_write(self):
        Handler.verify_ok = False
        with self.assertRaises(RuntimeError):
            self.invoke()
        self.assertEqual(Handler.posts, 0)

    def test_wrong_terminal_key_is_caught_before_saving(self):
        # Open WebUI's verify would pass (it only reads the unauthenticated
        # /api/config); the direct key check must stop the save.
        Handler.terminal_key = "the-real-key"
        with self.assertRaises(RuntimeError) as caught:
            self.invoke()
        self.assertIn("rejected the API key", str(caught.exception))
        self.assertEqual(Handler.posts, 0)

    def test_malformed_connection_list_is_refused(self):
        Handler.list_override = ["not-an-object"]
        with self.assertRaises(RuntimeError) as caught:
            self.invoke()
        self.assertIn("Unexpected terminal connection entry", str(caught.exception))
        self.assertEqual(Handler.posts, 0)


if __name__ == "__main__":
    unittest.main()
