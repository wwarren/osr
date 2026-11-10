#!/usr/bin/env python3
"""Tests for the Honcho client gateway (honcho-gateway.py) and honcho-clients.

Runs the real gateway as a process in front of two fake upstreams (the
Honcho API and its MCP server) that record what reaches them and check the
workspace JWT the way Honcho does (HS256 over the shared secret). Standard
library only.
"""

import base64
import hashlib
import hmac
import http.client
import importlib.util
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).parent
GATEWAY = HERE / "honcho-gateway.py"
CLIENTS_CLI = HERE / "honcho-clients"
spec = importlib.util.spec_from_file_location("honcho_gateway", GATEWAY)
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)

SECRET = "0123456789abcdef" * 6
OWUI_KEY = "owui-key-0123456789abcdef0123456789"
AGENT_KEY = "agent-key-0123456789abcdef012345678"
OTHER_AGENT_KEY = "other-agent-key-0123456789abcdef012"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def b64decode(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def jwt_claims(token, secret):
    """The claims of TOKEN if its HS256 signature is valid for SECRET, else None."""
    try:
        header, payload, signature = token.split(".")
    except ValueError:
        return None
    expected = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(expected, b64decode(signature)):
        return None
    if json.loads(b64decode(header)) != {"alg": "HS256", "typ": "JWT"}:
        return None
    return json.loads(b64decode(payload))


class Upstream(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def reply(self, status, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        state = self.server.state
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        token = (self.headers.get("authorization") or "").removeprefix("Bearer ")
        claims = jwt_claims(token, state["secret"]) if token else None
        state["requests"].append({"method": self.command, "path": self.path,
                                  "headers": {k.lower(): v for k, v in self.headers.items()},
                                  "body": body, "claims": claims})
        if self.path == "/health":
            return self.reply(200, {"status": "ok"})
        if claims is None:
            return self.reply(401, {"detail": "Invalid JWT"})
        if self.path == "/v3/workspaces" and self.command == "POST":
            if state.get("fail_create"):
                return self.reply(500, {"detail": "boom"})
            name = json.loads(body)["id"]
            if claims.get("w") != name:
                return self.reply(401, {"detail": "Unauthorized access to resource"})
            created = name not in state["workspaces"]
            state["workspaces"].add(name)
            return self.reply(201 if created else 200, {"id": name})
        if self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (b"data: one\n\n", b"data: two\n\n"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
                self.wfile.flush()
                state["streamed"].wait(5)
            self.wfile.write(b"0\r\n\r\n")
            return None
        return self.reply(200, {"path": self.path, "workspace": claims.get("w")},
                          headers=[("Mcp-Session-Id", "s-1"), ("Server", "upstream")])

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = handle_any


class GatewayTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.clients_file = root / "clients.json"
        self.secret_file = root / "jwt-secret"
        self.records = root / "records"
        self.secret_file.write_text(SECRET + "\n")
        self.write_clients({"openwebui": {"key_sha256": sha(OWUI_KEY)},
                            "hermes-201": {"key_sha256": sha(AGENT_KEY), "workspace": "hermes-201"},
                            "openclaw-202": {"key_sha256": sha(OTHER_AGENT_KEY), "workspace": "openclaw-202"}})
        self.state = {"secret": SECRET, "requests": [], "workspaces": set(),
                      "streamed": threading.Event()}
        self.upstreams = []
        ports = {}
        for kind in ("api", "mcp"):
            server = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
            server.daemon_threads = True
            server.state = self.state
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.upstreams.append(server)
            ports[kind] = server.server_address[1]
        self.api_port, self.mcp_port = free_port(), free_port()
        env = dict(os.environ, HONCHO_GATEWAY_HOST="127.0.0.1",
                   HONCHO_GATEWAY_API_PORT=str(self.api_port), HONCHO_GATEWAY_MCP_PORT=str(self.mcp_port),
                   HONCHO_UPSTREAM_API_PORT=str(ports["api"]), HONCHO_UPSTREAM_MCP_PORT=str(ports["mcp"]),
                   HONCHO_CLIENTS_FILE=str(self.clients_file), HONCHO_JWT_SECRET_FILE=str(self.secret_file),
                   HONCHO_GATEWAY_RECORDS=str(self.records), HONCHO_GATEWAY_MAX_BODY_MB="1",
                   HONCHO_GATEWAY_LOG_LEVEL="WARNING")
        self.proc = subprocess.Popen([sys.executable, "-I", str(GATEWAY)], env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10
        while True:
            try:
                for port in (self.api_port, self.mcp_port):
                    socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                if self.proc.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("gateway did not start: " + self.proc.stderr.read().decode()) from None
                time.sleep(0.05)

    def tearDown(self):
        self.proc.terminate()
        self.proc.wait(5)
        self.proc.stderr.close()
        for server in self.upstreams:
            server.shutdown()
            server.server_close()
        self.tmp.cleanup()

    def write_clients(self, clients):
        tmp = self.clients_file.with_suffix(".tmp")
        tmp.write_text(json.dumps({"version": 1, "clients": clients}))
        os.replace(tmp, self.clients_file)

    def call(self, method, path, key=None, user=None, body=None, port=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", port or self.api_port, timeout=10)
        sent = dict(headers or {})
        if key:
            sent["Authorization"] = f"Bearer {key}"
        if user is not None:
            sent["X-User-Id"] = user
        data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
        if data is not None:
            sent.setdefault("Content-Type", "application/json")
        conn.request(method, path, data, sent)
        response = conn.getresponse()
        raw = response.read()
        conn.close()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = raw
        return response.status, parsed, response

    def upstream_calls(self, path):
        return [r for r in self.state["requests"] if r["path"] == path]

    # --- tests -------------------------------------------------------------
    def test_each_open_webui_user_has_their_own_workspace(self):
        status, body, _ = self.call("GET", "/v3/workspaces/x/peers", OWUI_KEY, user="alice")
        self.assertEqual(status, 200)
        alice = gateway.workspace_name("openwebui", "alice")
        self.assertEqual(body["workspace"], alice)
        self.assertRegex(alice, r"^openwebui-u-[0-9a-f]{16}$")
        status, body, _ = self.call("GET", "/v3/workspaces/x/peers", OWUI_KEY, user="bob")
        bob = gateway.workspace_name("openwebui", "bob")
        self.assertEqual(body["workspace"], bob)
        self.assertNotEqual(alice, bob)
        # Each workspace is created once, with its own key, and its owner recorded.
        self.call("GET", "/again", OWUI_KEY, user="alice")
        self.assertEqual(self.state["workspaces"], {alice, bob})
        self.assertEqual(len(self.upstream_calls("/v3/workspaces")), 2)
        record = json.loads((self.records / f"{alice}.json").read_text())
        self.assertEqual((record["client"], record["user"]), ("openwebui", "alice"))
        claims = [r["claims"] for r in self.upstream_calls("/v3/workspaces/x/peers")]
        self.assertEqual(claims, [{"t": "osr-honcho-gateway", "w": alice},
                                  {"t": "osr-honcho-gateway", "w": bob}])

    def test_the_same_key_reaches_a_workspace_every_time(self):
        # Honcho's MCP server binds a session to its key: it must not change.
        self.call("POST", "/mcp", OWUI_KEY, user="alice", body={}, port=self.mcp_port)
        self.call("POST", "/mcp", OWUI_KEY, user="alice", body={}, port=self.mcp_port)
        keys = {r["headers"]["authorization"] for r in self.upstream_calls("/mcp")}
        self.assertEqual(len(keys), 1)

    def test_mcp_gets_the_workspace_header_and_client_headers_are_dropped(self):
        status, body, response = self.call(
            "POST", "/mcp", OWUI_KEY, user="alice", port=self.mcp_port,
            body={"jsonrpc": "2.0", "id": 1, "method": "initialize"},
            headers={"X-Honcho-Workspace-ID": "osr", "Cookie": "a=b", "Mcp-Session-Id": "s-1"})
        self.assertEqual(status, 200)
        alice = gateway.workspace_name("openwebui", "alice")
        seen = self.upstream_calls("/mcp")[-1]["headers"]
        self.assertEqual(seen["x-honcho-workspace-id"], alice)
        self.assertNotIn("cookie", seen)
        self.assertNotIn("x-user-id", seen)
        self.assertEqual(seen["mcp-session-id"], "s-1")
        self.assertEqual(response.getheader("Mcp-Session-Id"), "s-1")
        self.assertEqual(response.getheader("Server"), "honcho-gateway")
        # The API port gets no workspace header.
        self.call("GET", "/v3/x", OWUI_KEY, user="alice")
        self.assertNotIn("x-honcho-workspace-id", self.upstream_calls("/v3/x")[-1]["headers"])

    def test_tool_calls_are_pinned_to_the_callers_workspace(self):
        batch = [{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                  "params": {"name": "chat", "arguments": {"workspace_id": "osr", "query": "q"}}},
                 {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                  "params": {"name": "list_peers", "arguments": {}}},
                 {"jsonrpc": "2.0", "id": 3, "method": "tools/list"}]
        self.call("POST", "/mcp", OWUI_KEY, user="alice", body=batch, port=self.mcp_port)
        sent = json.loads(self.upstream_calls("/mcp")[-1]["body"])
        alice = gateway.workspace_name("openwebui", "alice")
        self.assertEqual(sent[0]["params"]["arguments"], {"workspace_id": alice, "query": "q"})
        self.assertEqual(sent[1]["params"]["arguments"], {})
        self.assertEqual(sent[2], batch[2])

    def test_open_webui_without_a_user_only_learns_who_it_is(self):
        status, body, _ = self.call("GET", "/osr/v1/whoami", OWUI_KEY, port=self.mcp_port)
        self.assertEqual((status, body), (200, {"client": "openwebui", "user": None,
                                                "workspace": None, "per_user": True}))
        for port in (self.api_port, self.mcp_port):
            status, body, _ = self.call("POST", "/mcp", OWUI_KEY, body={}, port=port)
            self.assertEqual(status, 400)
            self.assertIn("X-User-Id is required", body["detail"])
        self.assertFalse([r for r in self.state["requests"] if r["path"] != "/health"])
        status, _, _ = self.call("GET", "/v3/x", OWUI_KEY, user="bad user")
        self.assertEqual(status, 400)
        status, _, _ = self.call("GET", "/v3/x", OWUI_KEY, user="{{USER_ID}}")
        self.assertEqual(status, 400)

    def test_each_agent_has_its_own_workspace(self):
        status, body, _ = self.call("GET", "/v3/workspaces/hermes-201/peers", AGENT_KEY)
        self.assertEqual((status, body["workspace"]), (200, "hermes-201"))
        status, body, _ = self.call("GET", "/osr/v1/whoami", AGENT_KEY)
        self.assertEqual(body, {"client": "hermes-201", "user": None, "workspace": "hermes-201", "per_user": False})
        # Another agent's requests carry a key for its own workspace only, even
        # when they name the first agent's.
        status, body, _ = self.call("GET", "/v3/workspaces/hermes-201/peers", OTHER_AGENT_KEY)
        self.assertEqual(body["workspace"], "openclaw-202")
        self.call("POST", "/mcp", OTHER_AGENT_KEY, port=self.mcp_port, body={
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "list_peers", "arguments": {"workspace_id": "hermes-201"}}})
        sent = self.upstream_calls("/mcp")[-1]
        self.assertEqual(sent["claims"]["w"], "openclaw-202")
        self.assertEqual(sent["headers"]["x-honcho-workspace-id"], "openclaw-202")
        self.assertEqual(json.loads(sent["body"])["params"]["arguments"]["workspace_id"], "openclaw-202")
        status, body, _ = self.call("GET", "/v3/x", AGENT_KEY, user="alice")
        self.assertEqual(status, 403)
        self.assertFalse(list(self.records.glob("*.json")) if self.records.exists() else [])

    def test_keys_are_required_and_follow_clients_json(self):
        for key in (None, "wrong-key-0123456789abcdef"):
            status, _, _ = self.call("GET", "/v3/x", key, user="alice")
            self.assertEqual(status, 401)
        self.write_clients({"openwebui": {"key_sha256": sha("new-owui-key-0123456789abcdef")}})
        status, _, _ = self.call("GET", "/v3/x", OWUI_KEY, user="alice")
        self.assertEqual(status, 401)
        status, _, _ = self.call("GET", "/v3/x", AGENT_KEY)
        self.assertEqual(status, 401)
        status, _, _ = self.call("GET", "/v3/x", "new-owui-key-0123456789abcdef", user="alice")
        self.assertEqual(status, 200)
        # Invalid entries are ignored, not trusted.
        self.write_clients({"openwebui": {"key_sha256": sha(OWUI_KEY), "workspace": "x-u-0123456789abcdef"},
                            "Bad": {"key_sha256": sha(AGENT_KEY)}})
        self.assertEqual(self.call("GET", "/v3/x", OWUI_KEY, user="alice")[0], 401)
        self.assertEqual(self.call("GET", "/v3/x", AGENT_KEY)[0], 401)

    def test_a_new_jwt_secret_gives_new_workspace_keys(self):
        self.call("GET", "/v3/x", AGENT_KEY)
        new = "fedcba9876543210" * 6
        self.secret_file.write_text(new + "\n")
        self.state["secret"] = new
        status, _, _ = self.call("GET", "/v3/y", AGENT_KEY)
        self.assertEqual(status, 200)
        self.assertEqual(self.upstream_calls("/v3/y")[-1]["claims"]["w"], "hermes-201")
        self.secret_file.write_text("")
        self.assertEqual(self.call("GET", "/v3/z", AGENT_KEY)[0], 503)

    def test_a_recorded_workspace_is_not_handed_to_another_user(self):
        alice = gateway.workspace_name("openwebui", "alice")
        self.records.mkdir()
        (self.records / f"{alice}.json").write_text(json.dumps({"client": "openwebui", "user": "mallory"}))
        status, _, _ = self.call("GET", "/v3/x", OWUI_KEY, user="alice")
        self.assertEqual(status, 409)
        self.assertFalse(self.upstream_calls("/v3/x"))

    def test_failures_upstream_are_reported(self):
        self.state["fail_create"] = True
        status, body, _ = self.call("GET", "/v3/x", OWUI_KEY, user="alice")
        self.assertEqual(status, 502)
        self.assertIn("could not open the workspace", body["detail"])
        self.state["fail_create"] = False
        self.assertEqual(self.call("GET", "/v3/x", OWUI_KEY, user="alice")[0], 200)
        for server in self.upstreams:
            server.shutdown()
            server.server_close()
        self.assertEqual(self.call("GET", "/v3/x", OWUI_KEY, user="alice")[0], 502)
        self.assertEqual(self.call("GET", "/health")[0], 502)

    def test_health_needs_no_key(self):
        status, body, _ = self.call("GET", "/health", port=self.mcp_port)
        self.assertEqual((status, body), (200, {"status": "ok"}))

    def test_streamed_replies_arrive_as_they_are_sent(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.api_port, timeout=10)
        conn.request("GET", "/stream", headers={"Authorization": f"Bearer {AGENT_KEY}"})
        response = conn.getresponse()
        self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
        # The first event comes before the upstream has sent the second.
        self.assertEqual(response.read1(100), b"data: one\n\n")
        self.state["streamed"].set()
        self.assertEqual(response.read(), b"data: two\n\n")
        conn.close()

    def test_bodies_are_forwarded_and_bounded(self):
        conn = http.client.HTTPConnection("127.0.0.1", self.api_port, timeout=10)
        conn.request("POST", "/v3/upload", body=iter([b"ab", b"cd"]),
                     headers={"Authorization": f"Bearer {AGENT_KEY}"})  # sent chunked
        response = conn.getresponse()
        response.read()
        self.assertEqual(response.status, 200)
        # The same connection serves a second request.
        conn.request("POST", "/v3/second", body=b"xyz", headers={"Authorization": f"Bearer {AGENT_KEY}"})
        self.assertEqual(conn.getresponse().status, 200)
        conn.close()
        self.assertEqual(self.upstream_calls("/v3/upload")[-1]["body"], b"abcd")
        self.assertEqual(self.upstream_calls("/v3/second")[-1]["body"], b"xyz")
        status, _, _ = self.call("POST", "/v3/big", AGENT_KEY, body=b"x" * (1024 * 1024 + 1))
        self.assertEqual(status, 413)


class PureTest(unittest.TestCase):
    def test_jwt_matches_honchos_format(self):
        token = gateway.mint_jwt(SECRET.encode(), "osr")
        self.assertEqual(jwt_claims(token, SECRET), {"t": "osr-honcho-gateway", "w": "osr"})
        self.assertEqual(token, gateway.mint_jwt(SECRET.encode(), "osr"))
        self.assertIsNone(jwt_claims(token, "another secret"))

    def test_fixed_workspace_names(self):
        self.assertTrue(gateway.valid_fixed_workspace("osr"))
        self.assertFalse(gateway.valid_fixed_workspace("openwebui-u-0123456789abcdef"))
        self.assertFalse(gateway.valid_fixed_workspace("bad name"))

    def test_pin_workspace_leaves_other_bodies_alone(self):
        self.assertEqual(gateway.pin_workspace(b"not json", "w"), b"not json")
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": "x", "arguments": {"workspace_id": "w"}}}).encode()
        self.assertIs(gateway.pin_workspace(body, "w"), body)


class ClientsCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.etc = pathlib.Path(self.tmp.name) / "etc"
        self.records = pathlib.Path(self.tmp.name) / "records"
        import grp
        self.env = dict(os.environ, HONCHO_ETC=str(self.etc), HONCHO_GATEWAY_RECORDS=str(self.records),
                        HONCHO_GATEWAY_GROUP=grp.getgrgid(os.getgid()).gr_name)

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args, check=True):
        result = subprocess.run([sys.executable, "-I", str(CLIENTS_CLI), *args], env=self.env,
                                capture_output=True, text=True, check=False)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def clients(self):
        return json.loads((self.etc / "clients.json").read_text())["clients"]

    def test_issue_has_list_revoke(self):
        key = self.cli("issue", "hermes-201").stdout.strip()
        self.assertRegex(key, r"^[A-Za-z0-9_-]{40,}$")
        # An agent gets a workspace of its own by default.
        self.assertEqual(self.clients()["hermes-201"], {"key_sha256": sha(key), "workspace": "hermes-201"})
        self.assertEqual(oct((self.etc / "clients.json").stat().st_mode & 0o777), "0o640")
        self.assertEqual(self.cli("has", "hermes-201", sha(key)).returncode, 0)
        self.assertEqual(self.cli("has", "hermes-201", sha("other"), check=False).returncode, 1)
        self.assertEqual(self.cli("has", "hermes-201", sha(key), "--workspace", "hermes-201").returncode, 0)
        self.assertEqual(self.cli("has", "hermes-201", sha(key), "--workspace", "osr", check=False).returncode, 1)
        again = self.cli("issue", "hermes-201", "--workspace", "lab").stdout.strip()
        self.assertNotEqual(again, key)
        self.assertEqual(self.cli("has", "hermes-201", sha(key), check=False).returncode, 1)
        self.assertEqual(self.clients()["hermes-201"]["workspace"], "lab")
        self.assertIn("hermes-201\tworkspace lab", self.cli("list").stdout)
        self.cli("revoke", "hermes-201")
        self.assertNotIn("hermes-201", self.clients())
        self.assertEqual(self.cli("revoke", "hermes-201", check=False).returncode, 1)
        self.cli("revoke", "hermes-201", "--missing-ok")

    def test_import_key_for_open_webui(self):
        key_file = pathlib.Path(self.tmp.name) / "key"
        key_file.write_text(OWUI_KEY + "\n")
        result = self.cli("import-key", "openwebui", str(key_file), "--per-user")
        self.assertIn("updated", result.stderr)
        self.assertEqual(self.clients()["openwebui"], {"key_sha256": sha(OWUI_KEY)})
        self.assertIn("unchanged", self.cli("import-key", "openwebui", str(key_file), "--per-user").stderr)
        self.assertIn("a workspace per user", self.cli("list").stdout)
        key_file.write_text("short")
        self.assertEqual(self.cli("import-key", "openwebui", str(key_file), check=False).returncode, 1)

    def test_invalid_names_and_workspaces(self):
        for args in (("issue", "Bad"), ("issue", "ok", "--workspace", "a b"),
                     ("issue", "ok", "--workspace", "openwebui-u-0123456789abcdef"),
                     ("issue", "ok", "--workspace", "x", "--per-user")):
            self.assertNotEqual(self.cli(*args, check=False).returncode, 0, args)
        self.assertFalse((self.etc / "clients.json").exists())

    def test_workspaces_lists_records(self):
        self.records.mkdir()
        (self.records / "openwebui-u-0123456789abcdef.json").write_text(json.dumps(
            {"workspace": "openwebui-u-0123456789abcdef", "client": "openwebui", "user": "alice",
             "created": "2026-11-09T00:00:00Z"}))
        (self.records / "junk.json").write_text("{")
        self.assertEqual(self.cli("workspaces").stdout,
                         "openwebui-u-0123456789abcdef\topenwebui\talice\t2026-11-09T00:00:00Z\n")


if __name__ == "__main__":
    unittest.main()
