#!/usr/bin/env python3
"""Open Terminal workspace gateway for Ollama Smart Router.

Listens on the terminal CT's public port, in front of one open-terminal
process per workspace:

* Every client (the router's Open WebUI, each agent CT) has its own bearer
  key. clients.json stores only SHA-256 hashes of the keys.
* A workspace belongs to one (client, user) pair. Open WebUI names the user
  in X-User-Id; an agent client has a default user and only that one
  workspace. The gateway never lets a client name a workspace of another
  client: the workspace ID is a hash of both names.
* The root spawner (spawner.py) creates the workspace's Linux account, port
  and key and starts open-terminal-ws@<id>.service, a sandboxed open-terminal
  that listens on loopback only. The gateway forwards each request to it with
  that workspace's key and stops workspaces that have been idle too long.
* Agents use POST /mcp, a small MCP (streamable HTTP, JSON responses) server
  whose tools are the workspace's own Open Terminal operations.

Runs as the unprivileged ot-gateway account from the Open Terminal venv
(starlette, httpx, websockets and uvicorn come from its hash-locked
requirements). Settings come from the environment (service.env).
"""

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import re
import time
import urllib.parse

import httpx
import uvicorn
import websockets
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.websockets import WebSocket, WebSocketDisconnect

log = logging.getLogger("open-terminal-gateway")

META_ID = "0" * 16
META_CLIENT = "_gateway"
META_USER = "metadata"
CLIENT_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")
USER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@:+-]{0,127}")
# Requests without a user may read only what is the same in every workspace.
# Open WebUI fetches these when it caches the connection (spec, features,
# system prompt) and when an admin verifies it.
METADATA_PATHS = frozenset(("/openapi.json", "/api/config", "/system"))
HOP_HEADERS = frozenset((
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "host",
))
# Open Terminal operations offered to agents as MCP tools (when the running
# release has them). The rest are UI helpers (display_file, the user terminal)
# or notebook sessions that run_command covers.
MCP_TOOLS = (
    "run_command", "get_process_status", "send_process_input", "kill_process",
    "list_processes", "list_files", "read_file", "write_file",
    "replace_file_content", "grep_search", "glob_search", "search_files", "match_files",
)
MCP_PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
MCP_MAX_BODY = 4 * 1024 * 1024
MCP_MAX_TEXT = 256 * 1024
MCP_DEFAULT_WAIT = 30.0
MCP_INSTRUCTIONS = (
    "These tools act in your own private Open Terminal workspace: a Linux "
    "account whose home directory is the workspace, separate from every other "
    "user and agent. Paths are relative to that home. There is no root access, "
    "so system packages cannot be installed; pip install --user works. "
    "run_command waits up to 30 seconds by default (argument wait); for longer "
    "commands poll get_process_status with the returned id."
)


def env_int(name, default, minimum=0):
    raw = os.environ.get(name, "")
    if not raw.strip():
        return default
    value = int(raw)
    if value < minimum:
        raise ValueError(f"{name} must be at least {minimum}")
    return value


class Settings:
    def __init__(self):
        self.host = os.environ.get("OT_GATEWAY_HOST", "0.0.0.0")
        self.port = env_int("OPEN_TERMINAL_PORT", 8000, 1)
        self.clients_file = os.environ.get("OT_CLIENTS_FILE", "/etc/open-terminal/clients.json")
        self.spawner_socket = os.environ.get(
            "OT_SPAWNER_SOCKET", "/run/open-terminal-spawner/spawner.sock")
        self.idle_seconds = env_int("OPEN_TERMINAL_IDLE_MINUTES", 120) * 60
        if os.environ.get("OT_IDLE_SECONDS", "").strip():   # tests
            self.idle_seconds = env_int("OT_IDLE_SECONDS", 0)
        self.max_active = env_int("OPEN_TERMINAL_MAX_ACTIVE", 8, 1)
        self.start_timeout = env_int("OT_START_TIMEOUT", 60, 1)
        self.reap_interval = env_int("OT_REAP_INTERVAL", 60, 1)
        self.instance_host = os.environ.get("OT_INSTANCE_HOST", "127.0.0.1")


def workspace_id(client, user):
    """The workspace of USER as seen by CLIENT: 64 bits of a hash of both."""
    digest = hashlib.sha256(f"osr-open-terminal\0{client}\0{user}".encode()).hexdigest()
    return digest[:16]


class HTTPError(Exception):
    def __init__(self, status, detail):
        super().__init__(detail)
        self.status = status
        self.detail = detail


class Clients:
    """clients.json, reread whenever it changes on disk."""

    def __init__(self, path):
        self.path = path
        self.stamp = None
        self.entries = {}

    def _load(self):
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            self.entries, self.stamp = {}, None
            return
        stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        if stamp == self.stamp:
            return
        with open(self.path, encoding="utf-8") as f:
            data = json.load(f)
        entries = {}
        for name, entry in (data.get("clients") or {}).items():
            digest = str(entry.get("key_sha256", ""))
            default_user = entry.get("default_user")
            if not CLIENT_RE.fullmatch(name) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                log.warning("ignoring invalid client entry %r", name)
                continue
            if default_user is not None and not USER_RE.fullmatch(str(default_user)):
                log.warning("ignoring invalid default_user of client %r", name)
                default_user = None
            entries[name] = (digest, default_user)
        self.entries, self.stamp = entries, stamp

    def authenticate(self, token):
        """The (name, default_user) whose key is TOKEN, or None."""
        try:
            self._load()
        except (OSError, ValueError) as exc:
            log.error("cannot read %s: %s", self.path, exc)
            raise HTTPError(503, "Gateway client list is unreadable") from exc
        if not token:
            return None
        digest = hashlib.sha256(token.encode()).hexdigest()
        found = None
        for name, (expected, default_user) in self.entries.items():
            # Compare against every entry, so timing does not depend on order.
            if hmac.compare_digest(digest, expected):
                found = (name, default_user)
        return found


class Instance:
    def __init__(self, port, key):
        self.port = port
        self.key = key


class Workspaces:
    """Running workspaces: started through the spawner, stopped when idle."""

    def __init__(self, settings):
        self.settings = settings
        self.instances = {}      # id -> Instance (started and healthy)
        self.locks = {}          # id -> asyncio.Lock
        self.inflight = {}       # id -> open requests and sockets
        self.last_used = {}      # id -> monotonic time
        self.meta_ready = False
        self.meta_error = "starting"
        self.http = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=5.0, read=None, write=120.0, pool=30.0),
            limits=httpx.Limits(max_connections=200, max_keepalive_connections=40),
            trust_env=False,
        )
        self.tools = None        # MCP tool table built from the spec
        self.orphans = set()     # running before a gateway restart, not yet used

    async def spawner(self, request):
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_unix_connection(self.settings.spawner_socket), timeout=5)
        except (OSError, asyncio.TimeoutError) as exc:
            raise HTTPError(503, "Workspace spawner is not available") from exc
        try:
            writer.write(json.dumps(request).encode() + b"\n")
            await writer.drain()
            line = await asyncio.wait_for(reader.readline(), timeout=self.settings.start_timeout)
        except (OSError, asyncio.TimeoutError) as exc:
            raise HTTPError(503, "Workspace spawner did not answer") from exc
        finally:
            writer.close()
        try:
            reply = json.loads(line)
        except ValueError as exc:
            raise HTTPError(502, "Workspace spawner gave an invalid reply") from exc
        if not reply.get("ok"):
            raise HTTPError(503, f"Workspace could not be started: {reply.get('error', 'unknown error')}")
        return reply

    def url(self, instance, path):
        return f"http://{self.settings.instance_host}:{instance.port}{path}"

    async def healthy(self, instance):
        try:
            response = await self.http.get(self.url(instance, "/health"), timeout=2.0)
            return response.status_code == 200 and response.json().get("status") == "ok"
        except (httpx.HTTPError, ValueError):
            return False

    def active_ids(self):
        return [ws for ws in self.instances if ws != META_ID]

    def counted_ids(self):
        return set(self.active_ids()) | self.orphans

    async def make_room(self, keep):
        if keep in self.instances or keep == META_ID:
            return
        active = self.counted_ids() - {keep}
        if len(active) < self.settings.max_active:
            return
        idle = [ws for ws in active if not self.inflight.get(ws)]
        if not idle:
            raise HTTPError(503, f"All {self.settings.max_active} workspaces are busy; try again later")
        victim = min(idle, key=lambda ws: self.last_used.get(ws, 0))
        log.info("stopping least recently used workspace %s to start %s", victim, keep)
        await self.stop(victim)

    async def stop(self, ws):
        self.instances.pop(ws, None)
        self.last_used.pop(ws, None)
        self.orphans.discard(ws)
        try:
            await self.spawner({"op": "stop", "id": ws})
        except HTTPError as exc:
            log.warning("could not stop workspace %s: %s", ws, exc.detail)

    async def ensure(self, ws, client, user, fresh=False):
        lock = self.locks.setdefault(ws, asyncio.Lock())
        async with lock:
            instance = self.instances.get(ws)
            if instance and not fresh:
                return instance
            self.instances.pop(ws, None)
            await self.make_room(ws)
            reply = await self.spawner({"op": "ensure", "id": ws, "client": client, "user": user})
            port, key = reply.get("port"), reply.get("key")
            if not isinstance(port, int) or not isinstance(key, str) or not key:
                raise HTTPError(502, "Workspace spawner gave an invalid reply")
            instance = Instance(port, key)
            deadline = time.monotonic() + self.settings.start_timeout
            while not await self.healthy(instance):
                if time.monotonic() > deadline:
                    raise HTTPError(504, "Workspace did not start in time")
                await asyncio.sleep(0.25)
            self.instances[ws] = instance
            self.orphans.discard(ws)
            self.last_used[ws] = time.monotonic()
            if ws == META_ID:
                self.tools = None
            return instance

    def touch(self, ws, delta):
        self.inflight[ws] = self.inflight.get(ws, 0) + delta
        if self.inflight[ws] <= 0:
            self.inflight.pop(ws, None)
        self.last_used[ws] = time.monotonic()

    async def reap(self):
        if not self.settings.idle_seconds:
            return
        now = time.monotonic()
        for ws in self.active_ids():
            if self.inflight.get(ws):
                continue
            if now - self.last_used.get(ws, now) >= self.settings.idle_seconds:
                lock = self.locks.setdefault(ws, asyncio.Lock())
                if lock.locked():
                    continue
                async with lock:
                    if self.inflight.get(ws) or ws not in self.instances:
                        continue
                    log.info("stopping idle workspace %s", ws)
                    await self.stop(ws)

    async def start_meta(self):
        """Keep the metadata workspace up; /health reports whether it is."""
        delay = 1.0
        while True:
            try:
                await self.ensure(META_ID, META_CLIENT, META_USER, fresh=not self.meta_ready)
                if await self.healthy(self.instances[META_ID]):
                    self.meta_ready, self.meta_error = True, ""
                    delay = 1.0
                else:
                    self.meta_ready, self.meta_error = False, "metadata workspace is not healthy"
                    self.instances.pop(META_ID, None)
            except HTTPError as exc:
                self.meta_ready, self.meta_error = False, exc.detail
                log.warning("metadata workspace: %s", exc.detail)
                delay = min(delay * 2, 30.0)
            await asyncio.sleep(delay if not self.meta_ready else 15.0)

    async def adopt_running(self):
        """After a gateway restart: count already running workspaces as fresh."""
        try:
            reply = await self.spawner({"op": "list"})
        except HTTPError:
            return
        now = time.monotonic()
        for ws in reply.get("active", []):
            if isinstance(ws, str) and re.fullmatch(r"[0-9a-f]{16}", ws) and ws != META_ID:
                # Their port and key are fetched again by the next ensure; the
                # idle reaper stops those nobody uses.
                self.last_used.setdefault(ws, now)
                self.orphans.add(ws)

    async def reap_orphans(self):
        """Stop workspaces running from before a restart that stayed unused."""
        if not self.settings.idle_seconds:
            return
        now = time.monotonic()
        for ws in list(self.orphans):
            if ws in self.instances or self.inflight.get(ws):
                continue
            if now - self.last_used.get(ws, now) >= self.settings.idle_seconds:
                await self.stop(ws)


settings = Settings()
clients = Clients(settings.clients_file)
workspaces = Workspaces(settings)


def bearer(headers):
    value = headers.get("authorization", "")
    scheme, _, token = value.partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return token.strip()


def request_user(found, headers):
    """The user a request acts for, or None (metadata only).

    A client with a default user (an agent CT) has that one workspace: its
    key is readable by the agent's own tools, so it may not open others. A
    client without one (Open WebUI) names each user in X-User-Id.
    """
    _, default_user = found
    named = headers.get("x-user-id", "").strip()
    if default_user is not None:
        if named and named != default_user:
            raise HTTPError(403, "This client has a single workspace: send no X-User-Id")
        return default_user
    if named and not USER_RE.fullmatch(named):
        raise HTTPError(400, "Invalid X-User-Id")
    return named or None


def identify(headers, path, method):
    """(client, user, workspace id) for a request; user is None for metadata."""
    found = clients.authenticate(bearer(headers))
    if not found:
        raise HTTPError(401, "Invalid API key")
    client = found[0]
    user = request_user(found, headers)
    if user is None:
        if method == "GET" and path in METADATA_PATHS:
            return client, None, META_ID
        raise HTTPError(400, "X-User-Id is required: every user has their own workspace")
    return client, user, workspace_id(client, user)


def forward_headers(raw, instance, user):
    out = []
    for name, value in raw:
        lower = name.decode("latin-1").lower()
        if lower in HOP_HEADERS or lower in ("authorization", "x-user-id", "cookie"):
            continue
        out.append((name, value))
    out.append((b"authorization", f"Bearer {instance.key}".encode()))
    if user is not None:
        out.append((b"x-user-id", user.encode()))
    return out


async def proxy_http(request, client, user, ws):
    body_iter = request.stream()
    method = request.method
    target = request.url.path
    if request.url.query:
        target += "?" + request.url.query
    workspaces.touch(ws, 1)
    released = False

    def release():
        nonlocal released
        if not released:
            released = True
            workspaces.touch(ws, -1)

    try:
        instance = await workspaces.ensure(ws, client if user is not None else META_CLIENT,
                                           user if user is not None else META_USER)
        for attempt in (1, 2):
            upstream = workspaces.http.build_request(
                method, workspaces.url(instance, target),
                headers=forward_headers(request.headers.raw, instance, user),
                content=body_iter if method not in ("GET", "HEAD") else None,
            )
            try:
                response = await workspaces.http.send(upstream, stream=True)
                break
            except httpx.ConnectError:
                # Stopped or crashed since it was last used; the body was not
                # read yet, so start it again and retry once.
                if attempt == 2:
                    raise HTTPError(502, "Workspace is not reachable") from None
                instance = await workspaces.ensure(
                    ws, client if user is not None else META_CLIENT,
                    user if user is not None else META_USER, fresh=True)
    except HTTPError:
        release()
        raise
    except httpx.HTTPError as exc:
        release()
        raise HTTPError(502, f"Workspace request failed: {type(exc).__name__}") from exc

    headers = [(k, v) for k, v in response.headers.raw
               if k.decode("latin-1").lower() not in HOP_HEADERS]

    async def body():
        try:
            async for chunk in response.aiter_raw():
                yield chunk
        finally:
            await response.aclose()
            release()

    out = StreamingResponse(body(), status_code=response.status_code)
    out.raw_headers = headers
    return out


async def handle_http(scope, receive, send):
    request = Request(scope, receive)
    path = request.url.path
    try:
        if path == "/health" and request.method in ("GET", "HEAD"):
            if workspaces.meta_ready:
                response = JSONResponse({"status": "ok"})
            else:
                response = JSONResponse({"status": "starting", "detail": workspaces.meta_error},
                                        status_code=503)
        elif path == "/osr/v1/whoami" and request.method == "GET":
            found = clients.authenticate(bearer(request.headers))
            if not found:
                raise HTTPError(401, "Invalid API key")
            name = found[0]
            user = request_user(found, request.headers)
            response = JSONResponse({
                "client": name, "user": user,
                "workspace": workspace_id(name, user) if user is not None else None,
            })
        elif path == "/mcp":
            response = await handle_mcp(request)
        else:
            client, user, ws = identify(request.headers, path, request.method)
            response = await proxy_http(request, client, user, ws)
    except HTTPError as exc:
        response = JSONResponse({"detail": exc.detail}, status_code=exc.status)
    await response(scope, receive, send)


async def handle_ws(scope, receive, send):
    socket = WebSocket(scope, receive, send)
    path = scope.get("path", "")
    if not re.fullmatch(r"/api/terminals/[^/]+", path):
        await socket.close(code=4004)
        return
    await socket.accept()
    try:
        first = await asyncio.wait_for(socket.receive_text(), timeout=10.0)
        payload = json.loads(first)
        if not isinstance(payload, dict) or payload.get("type") != "auth":
            raise ValueError
    except (asyncio.TimeoutError, ValueError, KeyError, WebSocketDisconnect, RuntimeError):
        await socket.close(code=4001, reason="Auth timeout or invalid payload")
        return
    try:
        headers = {"authorization": f"Bearer {payload.get('token', '')}"}
        user_id = socket.headers.get("x-user-id", "")
        if user_id:
            headers["x-user-id"] = user_id
        client, user, ws = identify(headers, path, "WEBSOCKET")
        if user is None:
            raise HTTPError(400, "X-User-Id is required")
    except HTTPError as exc:
        await socket.close(code=4001 if exc.status == 401 else 4000, reason=exc.detail[:120])
        return
    workspaces.touch(ws, 1)
    try:
        try:
            instance = await workspaces.ensure(ws, client, user)
        except HTTPError as exc:
            await socket.close(code=1011, reason=exc.detail[:120])
            return
        query = scope.get("query_string", b"").decode("latin-1")
        url = f"ws://{settings.instance_host}:{instance.port}{urllib.parse.quote(path)}"
        if query:
            url += "?" + query
        upstream_headers = {"X-User-Id": user}
        session_id = socket.headers.get("x-session-id")
        if session_id:
            upstream_headers["X-Session-Id"] = session_id
        try:
            upstream = await websockets.connect(
                url, additional_headers=upstream_headers, open_timeout=10,
                max_size=None, proxy=None)
        except (OSError, websockets.exceptions.WebSocketException, asyncio.TimeoutError):
            await socket.close(code=1011, reason="Workspace terminal is not reachable")
            return
        async with upstream:
            payload["token"] = instance.key
            await upstream.send(json.dumps(payload))

            async def client_to_upstream():
                while True:
                    message = await socket.receive()
                    if message["type"] == "websocket.disconnect":
                        return
                    if message.get("bytes") is not None:
                        await upstream.send(message["bytes"])
                    elif message.get("text") is not None:
                        await upstream.send(message["text"])
                    workspaces.touch(ws, 0)

            async def upstream_to_client():
                async for message in upstream:
                    if isinstance(message, bytes):
                        await socket.send_bytes(message)
                    else:
                        await socket.send_text(message)
                    workspaces.touch(ws, 0)

            tasks = [asyncio.create_task(client_to_upstream()),
                     asyncio.create_task(upstream_to_client())]
            try:
                await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
            code, reason = 1000, ""
            if upstream.close_code is not None:
                code, reason = upstream.close_code, upstream.close_reason or ""
            try:
                await socket.close(code=code if code != 1006 else 1011, reason=reason[:120])
            except RuntimeError:
                pass
    finally:
        workspaces.touch(ws, -1)


# --- MCP ----------------------------------------------------------------------

def strip_titles(schema):
    if isinstance(schema, dict):
        return {k: strip_titles(v) for k, v in schema.items() if k != "title"}
    if isinstance(schema, list):
        return [strip_titles(v) for v in schema]
    return schema


def deref(schema, spec, depth=0):
    """SCHEMA with local $refs into SPEC inlined (bounded, for small specs)."""
    if depth > 20:
        return {}
    if isinstance(schema, dict):
        ref = schema.get("$ref")
        if isinstance(ref, str) and ref.startswith("#/"):
            node = spec
            for part in ref[2:].split("/"):
                node = node.get(part.replace("~1", "/").replace("~0", "~"), {}) if isinstance(node, dict) else {}
            merged = {k: v for k, v in schema.items() if k != "$ref"}
            return {**deref(node, spec, depth + 1), **deref(merged, spec, depth + 1)}
        return {k: deref(v, spec, depth + 1) for k, v in schema.items()}
    if isinstance(schema, list):
        return [deref(v, spec, depth + 1) for v in schema]
    return schema


def build_tools(spec):
    """MCP tools from the workspace OpenAPI spec: name -> (tool, call plan)."""
    tools = {}
    for path, item in (spec.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        for method, op in item.items():
            if method not in ("get", "post", "put", "delete", "patch") or not isinstance(op, dict):
                continue
            name = op.get("operationId")
            if name not in MCP_TOOLS:
                continue
            props, required, plan = {}, [], {"method": method.upper(), "path": path,
                                              "query": [], "path_params": [], "body": []}
            for param in op.get("parameters") or []:
                param = deref(param, spec)
                where, pname = param.get("in"), param.get("name")
                if where not in ("query", "path") or not isinstance(pname, str):
                    continue
                schema = strip_titles(deref(param.get("schema") or {}, spec))
                if param.get("description") and "description" not in schema:
                    schema["description"] = param["description"]
                props[pname] = schema
                plan["path_params" if where == "path" else "query"].append(pname)
                if param.get("required") or where == "path":
                    required.append(pname)
            content = ((op.get("requestBody") or {}).get("content") or {})
            body = content.get("application/json")
            if body is None and content:
                continue  # uploads and forms are not offered as tools
            if body:
                schema = strip_titles(deref(body.get("schema") or {}, spec))
                for pname, pschema in (schema.get("properties") or {}).items():
                    if pname in props:
                        continue
                    props[pname] = pschema
                    plan["body"].append(pname)
                required.extend(r for r in schema.get("required") or [] if r in plan["body"])
            if name == "run_command" and "wait" in props:
                props["wait"] = dict(props["wait"])
                props["wait"]["description"] = (
                    f"Seconds to wait for the command to finish (default {MCP_DEFAULT_WAIT:g}). "
                    "If it finishes in time the output is included; otherwise poll "
                    "get_process_status with the returned id.")
            description = "\n\n".join(
                part for part in (op.get("summary"), op.get("description")) if part)
            tool = {"name": name, "description": description[:2000],
                    "inputSchema": {"type": "object", "properties": props,
                                    **({"required": sorted(set(required))} if required else {})}}
            tools[name] = (tool, plan)
    return tools


async def mcp_tools():
    if workspaces.tools is None:
        instance = await workspaces.ensure(META_ID, META_CLIENT, META_USER)
        try:
            response = await workspaces.http.get(workspaces.url(instance, "/openapi.json"),
                                                 headers={"authorization": f"Bearer {instance.key}"},
                                                 timeout=15.0)
            response.raise_for_status()
            spec = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise HTTPError(502, "Could not read the Open Terminal tool list") from exc
        workspaces.tools = build_tools(spec)
    return workspaces.tools


def tool_result(response):
    ctype = response.headers.get("content-type", "").split(";")[0].strip().lower()
    error = response.status_code >= 400
    if ctype.startswith("image/") and not error:
        data = base64.b64encode(response.content).decode()
        return {"content": [{"type": "image", "data": data, "mimeType": ctype}], "isError": False}
    if ctype == "application/json":
        try:
            text = json.dumps(response.json(), ensure_ascii=False)
        except ValueError:
            text = response.text
    else:
        text = response.text
    if error:
        text = f"HTTP {response.status_code}: {text}"
    if len(text) > MCP_MAX_TEXT:
        text = text[:MCP_MAX_TEXT] + f"\n[output truncated at {MCP_MAX_TEXT} characters]"
    return {"content": [{"type": "text", "text": text}], "isError": error}


async def mcp_call(client, user, ws, name, arguments):
    tools = await mcp_tools()
    if name not in tools:
        raise ValueError(f"Unknown tool: {name}")
    if not isinstance(arguments, dict):
        raise ValueError("arguments must be an object")
    _, plan = tools[name]
    arguments = dict(arguments)
    if name == "run_command" and arguments.get("wait") is None and "wait" in plan["query"]:
        arguments["wait"] = MCP_DEFAULT_WAIT
    path = plan["path"]
    for pname in plan["path_params"]:
        if pname not in arguments:
            raise ValueError(f"Missing argument: {pname}")
        path = path.replace("{" + pname + "}", urllib.parse.quote(str(arguments[pname]), safe=""))
    query = {}
    for pname in plan["query"]:
        value = arguments.get(pname)
        if value is None:
            continue
        query[pname] = json.dumps(value) if isinstance(value, (dict, list)) else (
            str(value).lower() if isinstance(value, bool) else str(value))
    body = {p: arguments[p] for p in plan["body"] if p in arguments}
    workspaces.touch(ws, 1)
    try:
        instance = await workspaces.ensure(ws, client, user)
        kwargs = {"params": query,
                  "headers": {"authorization": f"Bearer {instance.key}", "x-user-id": user},
                  "timeout": httpx.Timeout(connect=5.0, read=600.0, write=60.0, pool=30.0)}
        if plan["method"] not in ("GET", "DELETE") or body:
            kwargs["json"] = body
        try:
            response = await workspaces.http.request(plan["method"], workspaces.url(instance, path), **kwargs)
        except httpx.ConnectError:
            instance = await workspaces.ensure(ws, client, user, fresh=True)
            kwargs["headers"]["authorization"] = f"Bearer {instance.key}"
            response = await workspaces.http.request(plan["method"], workspaces.url(instance, path), **kwargs)
        return tool_result(response)
    except httpx.HTTPError as exc:
        return {"content": [{"type": "text", "text": f"Workspace request failed: {type(exc).__name__}"}],
                "isError": True}
    finally:
        workspaces.touch(ws, -1)


def rpc_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


async def mcp_message(message, client, user, ws):
    """One JSON-RPC message: its response, or None for a notification."""
    if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
        return rpc_error(None, -32600, "Invalid Request")
    method = message.get("method")
    if "id" not in message:
        return None  # notifications (initialized, cancelled) and stray responses
    rid = message["id"]
    params = message.get("params") or {}
    if not isinstance(params, dict):
        return rpc_error(rid, -32602, "params must be an object")
    try:
        if method == "initialize":
            wanted = params.get("protocolVersion")
            version = wanted if wanted in MCP_PROTOCOLS else MCP_PROTOCOLS[0]
            result = {"protocolVersion": version,
                      "capabilities": {"tools": {"listChanged": False}},
                      "serverInfo": {"name": "osr-open-terminal", "version": "1"},
                      "instructions": MCP_INSTRUCTIONS}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": [tool for tool, _ in (await mcp_tools()).values()]}
        elif method == "tools/call":
            if user is None:
                return rpc_error(rid, -32602, "X-User-Id is required for tools")
            result = await mcp_call(client, user, ws, params.get("name"), params.get("arguments") or {})
        elif method in ("resources/list", "prompts/list"):
            result = {method.split("/")[0]: []}
        else:
            return rpc_error(rid, -32601, f"Method not found: {method}")
    except ValueError as exc:
        return rpc_error(rid, -32602, str(exc))
    except HTTPError as exc:
        return rpc_error(rid, -32603, exc.detail)
    return {"jsonrpc": "2.0", "id": rid, "result": result}


async def handle_mcp(request):
    found = clients.authenticate(bearer(request.headers))
    if not found:
        raise HTTPError(401, "Invalid API key")
    if request.method != "POST":
        # No server-initiated stream: responses come back on each POST.
        return Response(status_code=405, headers={"allow": "POST"})
    client = found[0]
    user = request_user(found, request.headers)
    ws = workspace_id(client, user) if user is not None else None
    raw = b""
    async for chunk in request.stream():
        raw += chunk
        if len(raw) > MCP_MAX_BODY:
            raise HTTPError(413, "Request too large")
    try:
        payload = json.loads(raw)
    except ValueError:
        return JSONResponse(rpc_error(None, -32700, "Parse error"), status_code=400)
    if isinstance(payload, list):
        if not payload:
            return JSONResponse(rpc_error(None, -32600, "Invalid Request"), status_code=400)
        replies = [r for r in [await mcp_message(m, client, user, ws) for m in payload] if r is not None]
        return JSONResponse(replies) if replies else Response(status_code=202)
    reply = await mcp_message(payload, client, user, ws)
    return JSONResponse(reply) if reply is not None else Response(status_code=202)


# --- ASGI ---------------------------------------------------------------------

async def app(scope, receive, send):
    if scope["type"] == "http":
        await handle_http(scope, receive, send)
    elif scope["type"] == "websocket":
        await handle_ws(scope, receive, send)
    elif scope["type"] == "lifespan":
        tasks = []
        while True:
            message = await receive()
            if message["type"] == "lifespan.startup":
                await workspaces.adopt_running()

                async def reaper():
                    while True:
                        await asyncio.sleep(settings.reap_interval)
                        try:
                            await workspaces.reap()
                            await workspaces.reap_orphans()
                        except Exception:  # keep reaping after one failure
                            log.exception("idle reaper failed")

                tasks = [asyncio.create_task(workspaces.start_meta()),
                         asyncio.create_task(reaper())]
                await send({"type": "lifespan.startup.complete"})
            elif message["type"] == "lifespan.shutdown":
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                await workspaces.http.aclose()
                await send({"type": "lifespan.shutdown.complete"})
                return


def main():
    logging.basicConfig(level=os.environ.get("OT_LOG_LEVEL", "INFO"),
                        format="%(levelname)s %(name)s: %(message)s")
    uvicorn.run(app, host=settings.host, port=settings.port, proxy_headers=False,
                server_header=False, log_level=os.environ.get("OT_LOG_LEVEL", "info").lower(),
                ws_max_size=16 * 1024 * 1024)


if __name__ == "__main__":
    main()
