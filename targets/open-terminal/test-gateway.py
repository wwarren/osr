#!/usr/bin/env python3
"""End-to-end tests for the workspace gateway and spawner.

Runs the real gateway.py and spawner.py as processes, with stub useradd and
systemctl: "systemctl start open-terminal-ws@<id>" launches a small fake
open-terminal (starlette) on the port and key the spawner wrote. Nothing is
installed and no account is created.

Needs the Open Terminal venv's packages (starlette, httpx, websockets,
uvicorn: targets/open-terminal/requirements.lock). tests/run-tests.sh runs it
with OPEN_TERMINAL_PYTHON; without those packages it prints SKIP.
"""

import json
import os
import pwd
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

try:
    import httpx
    import websockets.sync.client as ws_client
except ImportError:
    print("SKIP gateway end-to-end cases (no httpx/websockets: set OPEN_TERMINAL_PYTHON "
          "to a venv built from targets/open-terminal/requirements.lock)")
    sys.exit(0)

HERE = os.path.dirname(os.path.abspath(__file__))
OWUI_KEY = "owui-key-0123456789abcdef0123456789"
FAKE_INSTANCE = textwrap.dedent('''
    import asyncio, json, os, sys
    import uvicorn
    from starlette.applications import Starlette
    from starlette.responses import JSONResponse
    from starlette.routing import Route, WebSocketRoute

    KEY = os.environ["OPEN_TERMINAL_API_KEY"]
    PORT = int(os.environ["OPEN_TERMINAL_PORT"])
    WS_DIR = sys.argv[1]
    SPEC = {
        "openapi": "3.1.0", "info": {"title": "fake", "version": "0"},
        "paths": {
            "/execute": {"post": {
                "operationId": "run_command", "summary": "Execute a command",
                "parameters": [{"name": "wait", "in": "query", "required": False,
                                "schema": {"anyOf": [{"type": "number"}, {"type": "null"}], "title": "Wait"}}],
                "requestBody": {"required": True, "content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/ExecRequest"}}}}}},
            "/files/read": {"get": {
                "operationId": "read_file", "summary": "Read a file",
                "parameters": [{"name": "path", "in": "query", "required": True,
                                "schema": {"type": "string"}, "description": "File path"}]}},
            "/files/write": {"post": {
                "operationId": "write_file", "summary": "Write a file",
                "requestBody": {"content": {"application/json": {
                    "schema": {"$ref": "#/components/schemas/WriteRequest"}}}}}},
            "/files/display": {"get": {"operationId": "display_file", "summary": "UI only"}},
            "/files/upload": {"post": {"operationId": "upload_file", "requestBody": {
                "content": {"multipart/form-data": {"schema": {"type": "object"}}}}}},
            "/execute/{process_id}/status": {"get": {
                "operationId": "get_process_status", "summary": "Status",
                "parameters": [{"name": "process_id", "in": "path", "required": True,
                                "schema": {"type": "string"}}]}},
        },
        "components": {"schemas": {
            "ExecRequest": {"type": "object", "title": "ExecRequest", "required": ["command"],
                            "properties": {"command": {"type": "string", "title": "Command"},
                                           "cwd": {"type": "string"}}},
            "WriteRequest": {"type": "object", "required": ["path", "content"],
                             "properties": {"path": {"type": "string"}, "content": {"type": "string"}}},
        }},
    }

    def authed(request):
        return request.headers.get("authorization") == f"Bearer {KEY}"

    def deny():
        return JSONResponse({"detail": "Invalid API key"}, status_code=401)

    def inside(path):
        full = os.path.normpath(os.path.join(WS_DIR, path))
        if not full.startswith(WS_DIR + os.sep):
            raise ValueError(path)
        return full

    async def health(request):
        return JSONResponse({"status": "ok"})

    async def openapi(request):
        return JSONResponse(SPEC)

    async def config(request):
        return JSONResponse({"features": {"system": True}})

    async def system(request):
        return JSONResponse({"prompt": "fake prompt"}) if authed(request) else deny()

    async def cwd(request):
        if not authed(request):
            return deny()
        return JSONResponse({"cwd": WS_DIR, "user": request.headers.get("x-user-id")})

    async def write(request):
        if not authed(request):
            return deny()
        body = await request.json()
        with open(inside(body["path"]), "w") as f:
            f.write(body["content"])
        return JSONResponse({"path": body["path"], "size": len(body["content"])})

    async def read(request):
        if not authed(request):
            return deny()
        try:
            with open(inside(request.query_params["path"])) as f:
                return JSONResponse({"content": f.read()})
        except FileNotFoundError:
            return JSONResponse({"detail": "not found"}, status_code=404)

    async def execute(request):
        if not authed(request):
            return deny()
        body = await request.json()
        return JSONResponse({"id": "p1", "status": "done", "wait": request.query_params.get("wait"),
                             "output": f"ran {body['command']} in {WS_DIR}"})

    async def upload(request):
        if not authed(request):
            return deny()
        data = await request.body()
        return JSONResponse({"received": len(data)})

    async def terminals(request):
        return JSONResponse({"id": "s1"}) if authed(request) else deny()

    async def terminal_ws(websocket):
        await websocket.accept()
        auth = json.loads(await websocket.receive_text())
        if auth.get("token") != KEY:
            await websocket.close(code=4001, reason="Invalid API key")
            return
        user = websocket.headers.get("x-user-id", "")
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                return
            if message.get("text") == "bye":
                await websocket.close(code=1000)
                return
            await websocket.send_text(f"{user}@{os.path.basename(WS_DIR)}: {message.get('text')}")

    app = Starlette(routes=[
        Route("/health", health), Route("/openapi.json", openapi), Route("/api/config", config),
        Route("/system", system), Route("/files/cwd", cwd), Route("/files/write", write, methods=["POST"]),
        Route("/files/read", read), Route("/execute", execute, methods=["POST"]),
        Route("/files/upload", upload, methods=["POST"]),
        Route("/api/terminals", terminals, methods=["POST"]),
        WebSocketRoute("/api/terminals/{sid}", terminal_ws),
    ])
    uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="warning")
''')

FAKE_SYSTEMCTL = textwrap.dedent('''
    #!{python}
    import os, re, signal, subprocess, sys, time
    state, log = os.environ["FAKE_STATE"], os.environ["FAKE_LOG"]
    env_dir, ws_root = os.environ["OT_WS_ENV_DIR"], os.environ["OT_WS_ROOT"]
    with open(log, "a") as f:
        f.write("systemctl " + " ".join(sys.argv[1:]) + "\\n")
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    def pid_of(ws):
        try:
            pid = int(open(os.path.join(state, ws + ".pid")).read())
        except (OSError, ValueError):
            return None
        return pid if alive(pid) else None
    cmd = sys.argv[1]
    if cmd in ("start", "stop"):
        ws = re.fullmatch(r"open-terminal-ws@([0-9a-f]{{16}})\\.service", sys.argv[2]).group(1)
        pid = pid_of(ws)
        if cmd == "start":
            if pid:
                sys.exit(0)
            if os.path.exists(os.path.join(state, "fail-" + ws)):
                sys.exit(1)
            env = dict(os.environ)
            for line in open(os.path.join(env_dir, ws + ".env")):
                name, sep, value = line.strip().partition("=")
                if sep and not name.startswith("#"):
                    env[name] = value
            proc = subprocess.Popen([{python!r}, {instance!r}, os.path.join(ws_root, ws)], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    start_new_session=True)
            open(os.path.join(state, ws + ".pid"), "w").write(str(proc.pid))
        elif pid:
            os.kill(pid, signal.SIGTERM)
            for _ in range(100):
                if not alive(pid):
                    break
                time.sleep(0.05)
            os.unlink(os.path.join(state, ws + ".pid"))
    elif cmd == "list-units":
        for name in os.listdir(state):
            if name.endswith(".pid") and pid_of(name[:-4]):
                print(f"open-terminal-ws@{{name[:-4]}}.service loaded active running Open Terminal workspace")
''')


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Harness:
    def __init__(self, idle_seconds="", max_active="8"):
        self.tmp = tempfile.mkdtemp(prefix="ot-gateway-test.")
        t = self.tmp
        self.etc, self.state, self.bin = f"{t}/etc", f"{t}/state", f"{t}/bin"
        for d in (self.etc, self.state, self.bin):
            os.makedirs(d)
        self.log = f"{t}/calls.log"
        open(self.log, "w").close()
        instance = f"{t}/fake_instance.py"
        with open(instance, "w") as f:
            f.write(FAKE_INSTANCE)
        with open(f"{self.bin}/systemctl", "w") as f:
            f.write(FAKE_SYSTEMCTL.format(python=sys.executable, instance=instance).lstrip())
        with open(f"{self.bin}/useradd", "w") as f:
            f.write(f"#!/bin/sh\necho \"useradd $*\" >> {self.log}\n")
        for name in ("systemctl", "useradd"):
            os.chmod(f"{self.bin}/{name}", 0o755)
        me = pwd.getpwuid(os.getuid()).pw_name
        group = subprocess.run(["id", "-gn"], capture_output=True, text=True, check=True).stdout.strip()
        self.port = free_port()
        base = free_port()
        self.env = dict(os.environ,
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        OT_ETC=self.etc, OT_CLIENTS_FILE=f"{self.etc}/clients.json",
                        OT_SPAWNER_SOCKET=f"{t}/run/spawner.sock",
                        OT_WS_ROOT=f"{t}/ws", OT_WS_ENV_DIR=f"{self.etc}/ws",
                        OT_WS_RECORD_DIR=f"{t}/records", OT_GATEWAY_USER=me, OT_GATEWAY_GROUP=group,
                        OT_WS_PORT_MIN=str(base), OT_WS_PORT_MAX=str(base + 200),
                        OT_SYSTEMCTL=f"{self.bin}/systemctl", OT_USERADD=f"{self.bin}/useradd",
                        OT_CHOWN="0", FAKE_STATE=self.state, FAKE_LOG=self.log,
                        OT_GATEWAY_HOST="127.0.0.1", OPEN_TERMINAL_PORT=str(self.port),
                        OPEN_TERMINAL_MAX_ACTIVE=max_active, OT_IDLE_SECONDS=idle_seconds,
                        OT_REAP_INTERVAL="1", OT_START_TIMEOUT="20", OT_LOG_LEVEL="WARNING")
        with open(f"{t}/owui-key", "w") as f:
            f.write(OWUI_KEY + "\n")
        self.clients("import-key", "openwebui", f"{t}/owui-key")
        self.logs = [open(f"{t}/spawner.log", "w"), open(f"{t}/gateway.log", "w")]
        self.spawner = subprocess.Popen([sys.executable, f"{HERE}/spawner.py"], env=self.env,
                                        stderr=self.logs[0])
        self.gateway = subprocess.Popen([sys.executable, f"{HERE}/gateway.py"], env=self.env,
                                        stderr=self.logs[1])
        self.url = f"http://127.0.0.1:{self.port}"
        self.http = httpx.Client(base_url=self.url, timeout=30, trust_env=False)
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                if self.http.get("/health").status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            time.sleep(0.2)
        self.close(keep=True)
        with open(f"{t}/gateway.log") as f:
            raise RuntimeError("gateway did not become healthy: " + f.read())

    def clients(self, *args):
        result = subprocess.run([sys.executable, f"{HERE}/open-terminal-clients", *args],
                                env=self.env, capture_output=True, text=True, check=False)
        if result.returncode:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def running(self):
        out = subprocess.run([f"{self.bin}/systemctl", "list-units"], env=self.env,
                             capture_output=True, text=True, check=True).stdout
        return {line.split("@")[1][:16] for line in out.splitlines()}

    def close(self, keep=False):
        self.http.close()
        for proc in (self.gateway, self.spawner):
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        for name in os.listdir(self.state):
            if name.endswith(".pid"):
                try:
                    with open(os.path.join(self.state, name)) as f:
                        os.killpg(int(f.read()), signal.SIGTERM)
                except (OSError, ValueError):
                    pass
        for handle in self.logs:
            handle.close()
        if not keep:
            shutil.rmtree(self.tmp, ignore_errors=True)


def owui(user=None):
    headers = {"Authorization": f"Bearer {OWUI_KEY}"}
    if user:
        headers["X-User-Id"] = user
    return headers


class GatewayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h = Harness()

    @classmethod
    def tearDownClass(cls):
        cls.h.close()

    def test_keys_are_required(self):
        h = self.h.http
        self.assertEqual(h.get("/files/cwd").status_code, 401)
        self.assertEqual(h.get("/files/cwd", headers={"Authorization": "Bearer wrong",
                                                      "X-User-Id": "alice"}).status_code, 401)
        self.assertEqual(h.post("/mcp", json={}).status_code, 401)
        # The gateway's own health check needs no key and says nothing more.
        self.assertEqual(h.get("/health").json(), {"status": "ok"})

    def test_each_user_has_a_separate_workspace(self):
        h = self.h.http
        a = h.get("/files/cwd", headers=owui("user-a")).json()
        b = h.get("/files/cwd", headers=owui("user-b")).json()
        self.assertNotEqual(a["cwd"], b["cwd"])
        self.assertEqual(a["user"], "user-a")
        r = h.post("/files/write", headers=owui("user-a"), json={"path": "secret.txt", "content": "A only"})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(h.get("/files/read", params={"path": "secret.txt"},
                               headers=owui("user-a")).json()["content"], "A only")
        self.assertEqual(h.get("/files/read", params={"path": "secret.txt"},
                               headers=owui("user-b")).status_code, 404)
        # Each workspace has its own key and port, written by the spawner.
        envs = {}
        for name in os.listdir(self.h.env["OT_WS_ENV_DIR"]):
            with open(os.path.join(self.h.env["OT_WS_ENV_DIR"], name)) as f:
                text = f.read()
            envs[name] = text
            self.assertEqual(os.stat(os.path.join(self.h.env["OT_WS_ENV_DIR"], name)).st_mode & 0o777, 0o600)
        keys = [line for text in envs.values() for line in text.splitlines() if line.startswith("OPEN_TERMINAL_API_KEY=")]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertNotIn(OWUI_KEY, "".join(envs.values()))
        with open(self.h.log) as f:
            log = f.read()
        self.assertIn("useradd --home-dir", log)
        self.assertIn("--user-group", log)

    def test_users_are_namespaced_by_client(self):
        key = self.h.clients("issue", "hermes-282", "--default-user", "default")
        h = self.h.http
        agent = {"Authorization": f"Bearer {key}"}
        h.post("/files/write", headers=owui("default"), json={"path": "mine.txt", "content": "owui"})
        # The agent's default user is not Open WebUI's user of the same name.
        self.assertNotEqual(h.get("/files/cwd", headers=agent).json()["cwd"],
                            h.get("/files/cwd", headers=owui("default")).json()["cwd"])
        self.assertEqual(h.get("/files/read", params={"path": "mine.txt"}, headers=agent).status_code, 404)
        # An agent has one workspace: naming another user is refused, so a
        # key its own tools can read cannot open (or create) more.
        r = h.get("/files/cwd", headers={**agent, "X-User-Id": "user-a"})
        self.assertEqual(r.status_code, 403)
        self.assertEqual(h.get("/files/cwd", headers={**agent, "X-User-Id": "default"}).status_code, 200)
        self.assertEqual(h.post("/mcp", headers={**agent, "X-User-Id": "user-a"},
                                json={"jsonrpc": "2.0", "id": 1, "method": "ping"}).status_code, 403)
        who = h.get("/osr/v1/whoami", headers=agent).json()
        self.assertEqual((who["client"], who["user"]), ("hermes-282", "default"))
        records = os.listdir(self.h.env["OT_WS_RECORD_DIR"])
        owners = []
        for r in records:
            with open(os.path.join(self.h.env["OT_WS_RECORD_DIR"], r)) as f:
                owners.append(json.load(f))
        pairs = {(o["client"], o["user"]) for o in owners}
        self.assertIn(("hermes-282", "default"), pairs)
        self.assertNotIn(("hermes-282", "user-a"), pairs)

    def test_requests_without_a_user(self):
        h = self.h.http
        # Open WebUI caches the spec, features and system prompt without a user.
        self.assertIn("paths", h.get("/openapi.json", headers=owui()).json())
        self.assertEqual(h.get("/system", headers=owui()).json()["prompt"], "fake prompt")
        self.assertEqual(h.get("/api/config", headers=owui()).status_code, 200)
        # Anything that touches files or runs commands needs one.
        r = h.get("/files/cwd", headers=owui())
        self.assertEqual(r.status_code, 400)
        self.assertIn("X-User-Id", r.json()["detail"])
        self.assertEqual(h.post("/execute", headers=owui(), json={"command": "id"}).status_code, 400)
        self.assertEqual(h.get("/files/cwd", headers=owui("bad user!")).status_code, 400)
        self.assertEqual(h.get("/osr/v1/whoami", headers=owui()).json(),
                         {"client": "openwebui", "user": None, "workspace": None})

    def test_streamed_upload_is_forwarded(self):
        data = os.urandom(300_000)
        r = self.h.http.post("/files/upload", headers=owui("user-up"), files={"file": ("x.bin", data)})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertGreater(r.json()["received"], len(data))

    def test_websocket_terminal(self):
        self.h.http.post("/api/terminals", headers=owui("user-ws"))
        url = f"ws://127.0.0.1:{self.h.port}/api/terminals/s1"
        with ws_client.connect(url, additional_headers={"X-User-Id": "user-ws"}, proxy=None) as conn:
            conn.send(json.dumps({"type": "auth", "token": OWUI_KEY}))
            conn.send("hello")
            self.assertTrue(conn.recv(timeout=10).startswith("user-ws@"))
        with ws_client.connect(url, additional_headers={"X-User-Id": "user-ws"}, proxy=None) as conn:
            conn.send(json.dumps({"type": "auth", "token": "wrong"}))
            with self.assertRaises(Exception) as caught:
                conn.recv(timeout=10)
            self.assertEqual(getattr(caught.exception, "rcvd", None).code, 4001)

    def test_mcp(self):
        key = self.h.clients("issue", "deepseek-harness-281", "--default-user", "default")
        h = self.h.http
        headers = {"Authorization": f"Bearer {key}", "Accept": "application/json, text/event-stream"}

        def rpc(method, params=None, rid=1):
            body = {"jsonrpc": "2.0", "id": rid, "method": method}
            if params is not None:
                body["params"] = params
            r = h.post("/mcp", headers=headers, json=body)
            self.assertEqual(r.status_code, 200, r.text)
            return r.json()

        init = rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                  "clientInfo": {"name": "t", "version": "1"}})
        self.assertEqual(init["result"]["protocolVersion"], "2025-03-26")
        self.assertEqual(h.post("/mcp", headers=headers,
                                json={"jsonrpc": "2.0", "method": "notifications/initialized"}).status_code, 202)
        tools = {t["name"]: t for t in rpc("tools/list")["result"]["tools"]}
        self.assertEqual(set(tools), {"run_command", "read_file", "write_file", "get_process_status"})
        schema = tools["run_command"]["inputSchema"]
        self.assertEqual(schema["required"], ["command"])
        self.assertIn("wait", schema["properties"])
        self.assertNotIn("title", json.dumps(schema))
        wrote = rpc("tools/call", {"name": "write_file", "arguments": {"path": "a.txt", "content": "agent"}})
        self.assertFalse(wrote["result"]["isError"], wrote)
        read = rpc("tools/call", {"name": "read_file", "arguments": {"path": "a.txt"}})
        self.assertEqual(json.loads(read["result"]["content"][0]["text"])["content"], "agent")
        ran = json.loads(rpc("tools/call", {"name": "run_command",
                                            "arguments": {"command": "ls"}})["result"]["content"][0]["text"])
        self.assertEqual(ran["wait"], "30.0")
        missing = rpc("tools/call", {"name": "read_file", "arguments": {"path": "nope"}})
        self.assertTrue(missing["result"]["isError"])
        self.assertIn("HTTP 404", missing["result"]["content"][0]["text"])
        self.assertEqual(rpc("tools/call", {"name": "display_file", "arguments": {}})["error"]["code"], -32602)
        self.assertEqual(rpc("nope")["error"]["code"], -32601)
        status = rpc("tools/call", {"name": "get_process_status", "arguments": {}})
        self.assertEqual(status["error"]["code"], -32602)
        # The agent's default user is a workspace of its own client only.
        who = h.get("/osr/v1/whoami", headers={"Authorization": f"Bearer {key}"}).json()
        self.assertEqual(h.get("/files/read", params={"path": "a.txt"}, headers=owui("default")).status_code, 404)
        self.assertEqual(who["user"], "default")
        batch = h.post("/mcp", headers=headers, json=[{"jsonrpc": "2.0", "id": 7, "method": "ping"},
                                                      {"jsonrpc": "2.0", "method": "notifications/x"}]).json()
        self.assertEqual(batch, [{"jsonrpc": "2.0", "id": 7, "result": {}}])
        self.assertEqual(h.get("/mcp", headers=headers).status_code, 405)
        self.assertEqual(h.post("/mcp", headers=headers, content=b"{").status_code, 400)

    def test_revoked_key_stops_working(self):
        key = self.h.clients("issue", "openclaw-283", "--default-user", "default")
        h = self.h.http
        auth = {"Authorization": f"Bearer {key}"}
        self.assertEqual(h.get("/files/cwd", headers=auth).status_code, 200)
        new_key = self.h.clients("issue", "openclaw-283", "--default-user", "default")
        self.assertEqual(h.get("/files/cwd", headers=auth).status_code, 401)
        self.assertEqual(h.get("/files/cwd", headers={"Authorization": f"Bearer {new_key}"}).status_code, 200)
        digest = __import__("hashlib").sha256(new_key.encode()).hexdigest()
        self.h.clients("has", "openclaw-283", digest)
        with self.assertRaises(AssertionError):
            self.h.clients("has", "openclaw-283", "0" * 64)
        self.h.clients("revoke", "openclaw-283")
        self.h.clients("revoke", "openclaw-283", "--missing-ok")
        self.assertEqual(h.get("/files/cwd", headers={"Authorization": f"Bearer {new_key}"}).status_code, 401)
        self.assertIn("openwebui", self.h.clients("list"))

    def test_a_recorded_workspace_is_never_shared(self):
        h = self.h.http
        h.get("/files/cwd", headers=owui("user-rec"))
        records = self.h.env["OT_WS_RECORD_DIR"]
        for name in os.listdir(records):
            path = os.path.join(records, name)
            with open(path) as f:
                record = json.load(f)
            if record["user"] == "user-rec":
                record["user"] = "someone-else"
                with open(path, "w") as f:
                    json.dump(record, f)
                ws = record["id"]
        subprocess.run([f"{self.h.bin}/systemctl", "stop", f"open-terminal-ws@{ws}.service"],
                       env=self.h.env, check=True)
        r = h.get("/files/cwd", headers=owui("user-rec"))
        self.assertEqual(r.status_code, 503)
        self.assertIn("belongs to another", r.json()["detail"])

    def test_a_stopped_workspace_is_started_again(self):
        h = self.h.http
        cwd = h.get("/files/cwd", headers=owui("user-restart")).json()["cwd"]
        ws = os.path.basename(cwd)
        subprocess.run([f"{self.h.bin}/systemctl", "stop", f"open-terminal-ws@{ws}.service"],
                       env=self.h.env, check=True)
        self.assertEqual(h.get("/files/cwd", headers=owui("user-restart")).json()["cwd"], cwd)


class LimitsTest(unittest.TestCase):
    def test_idle_and_max_active(self):
        h = Harness(idle_seconds="2", max_active="2")
        try:
            c = h.http
            meta = "0" * 16
            ids = [os.path.basename(c.get("/files/cwd", headers=owui(u)).json()["cwd"]) for u in ("u1", "u2")]
            self.assertEqual(h.running(), {meta, *ids})
            third = os.path.basename(c.get("/files/cwd", headers=owui("u3")).json()["cwd"])
            # The least recently used workspace made room; the metadata one stays.
            self.assertEqual(h.running(), {meta, ids[1], third})
            deadline = time.time() + 15
            while time.time() < deadline and h.running() != {meta}:
                time.sleep(0.5)
            self.assertEqual(h.running(), {meta})
            # Files stay; the workspace comes back on the next request.
            self.assertEqual(os.path.basename(c.get("/files/cwd", headers=owui("u1")).json()["cwd"]), ids[0])
        finally:
            h.close()

    def test_failed_start_is_reported(self):
        h = Harness()
        try:
            from_id = h.http.get("/osr/v1/whoami", headers=owui("broken")).json()["workspace"]
            open(os.path.join(h.state, "fail-" + from_id), "w").close()
            r = h.http.get("/files/cwd", headers=owui("broken"))
            self.assertEqual(r.status_code, 503)
            self.assertIn("could not be started", r.json()["detail"])
        finally:
            h.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
