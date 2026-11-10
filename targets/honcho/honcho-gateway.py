#!/usr/bin/env python3
"""Honcho client gateway for Ollama Smart Router.

Listens on the Honcho CT's public ports, in front of the Honcho API (8000)
and Honcho's MCP server (3000), which run on loopback only:

* Every client (the router's Open WebUI, each agent CT) has its own bearer
  key. clients.json stores only SHA-256 hashes of the keys; a key can be
  revoked on its own, without touching the others or Honcho's JWT secret.
* Open WebUI names the user in X-User-Id (the connection sends the
  {{USER_ID}} template, which Open WebUI fills in for each request), and each
  user gets a Honcho workspace of their own: <client>-u-<16 hex>, a hash of
  the client and the user, so no request can name another user's workspace.
* An agent client has one fixed workspace, its own (named after the client),
  like its Open Terminal workspace, and may not name users.
* The gateway forwards each request with a Honcho JWT scoped to that one
  workspace. Honcho itself refuses any other workspace, so the separation
  does not depend on the MCP tools or the agents' plugins. The JWT is the
  same for every request to a workspace (Honcho's MCP server binds a session
  to its key), and it never leaves this CT.

Standard library only; runs as the unprivileged honcho-gateway account.
Settings come from the environment (gateway.env).
"""

import base64
import hashlib
import hmac
import http.client
import http.server
import json
import logging
import os
import re
import socket
import sys
import threading
import time

log = logging.getLogger("honcho-gateway")

CLIENT_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")
USER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@:+-]{0,127}")
WORKSPACE_RE = re.compile(r"[A-Za-z0-9_-]{1,100}")
# Per-user workspace names; a fixed workspace may not look like one.
PER_USER_RE = re.compile(r".+-u-[0-9a-f]{16}")
HOP_HEADERS = frozenset((
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "trailers", "transfer-encoding", "upgrade", "host",
    "content-length", "expect",
))
# Client headers that only the gateway may set upstream.
GATEWAY_HEADERS = frozenset(("authorization", "x-user-id", "x-honcho-workspace-id", "cookie"))
JWT_STAMP = "osr-honcho-gateway"


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
        self.host = os.environ.get("HONCHO_GATEWAY_HOST", "0.0.0.0")
        self.api_port = env_int("HONCHO_GATEWAY_API_PORT", 8000, 1)
        self.mcp_port = env_int("HONCHO_GATEWAY_MCP_PORT", 3000, 1)
        self.upstream_host = os.environ.get("HONCHO_UPSTREAM_HOST", "127.0.0.1")
        self.upstream_api_port = env_int("HONCHO_UPSTREAM_API_PORT", 8010, 1)
        self.upstream_mcp_port = env_int("HONCHO_UPSTREAM_MCP_PORT", 3010, 1)
        self.clients_file = os.environ.get("HONCHO_CLIENTS_FILE", "/etc/honcho-target/clients.json")
        self.secret_file = os.environ.get("HONCHO_JWT_SECRET_FILE", "/etc/honcho-target/jwt-secret")
        self.records = os.environ.get("HONCHO_GATEWAY_RECORDS", "/var/lib/honcho-gateway/workspaces")
        # Honcho's own model calls can wait up to twice the router's longest
        # read timeout (install-target.sh writes the value); the gateway waits
        # a little longer than that for a reply.
        self.upstream_timeout = env_int("HONCHO_GATEWAY_UPSTREAM_TIMEOUT", 7320, 1)
        self.max_body = env_int("HONCHO_GATEWAY_MAX_BODY_MB", 64, 1) * 1024 * 1024
        self.max_connections = env_int("HONCHO_GATEWAY_MAX_CONNECTIONS", 64, 1)


def workspace_name(client, user):
    """The workspace of USER as seen by CLIENT: 64 bits of a hash of both."""
    digest = hashlib.sha256(f"osr-honcho\0{client}\0{user}".encode()).hexdigest()
    return f"{client}-u-{digest[:16]}"


def valid_fixed_workspace(name):
    return bool(WORKSPACE_RE.fullmatch(name)) and not PER_USER_RE.fullmatch(name)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def mint_jwt(secret, workspace):
    """A Honcho JWT (HS256) for WORKSPACE alone, the same on every call."""
    header = b64url(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64url(json.dumps({"t": JWT_STAMP, "w": workspace},
                                separators=(",", ":"), sort_keys=True).encode())
    signing = header + b"." + payload
    signature = b64url(hmac.new(secret, signing, hashlib.sha256).digest())
    return (signing + b"." + signature).decode()


class HTTPError(Exception):
    def __init__(self, status, detail):
        super().__init__(detail)
        self.status = status
        self.detail = detail


class Watched:
    """A file reread whenever it changes on disk."""

    def __init__(self, path):
        self.path = path
        self.stamp = None
        self.lock = threading.Lock()

    def changed(self):
        """The file's new (stamp, bytes), or None when it is unchanged."""
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            if self.stamp is None:
                return None
            self.stamp = None
            return (None, None)
        stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        if stamp == self.stamp:
            return None
        with open(self.path, "rb") as f:
            data = f.read()
        self.stamp = stamp
        return (stamp, data)


class Clients(Watched):
    """clients.json: name -> (key SHA-256, fixed workspace or None)."""

    def __init__(self, path):
        super().__init__(path)
        self.entries = {}

    def _load(self):
        update = self.changed()
        if update is None:
            return
        _, raw = update
        if raw is None:
            self.entries = {}
            return
        data = json.loads(raw)
        entries = {}
        for name, entry in ((data.get("clients") or {}) if isinstance(data, dict) else {}).items():
            if not isinstance(entry, dict):
                continue
            digest = str(entry.get("key_sha256", ""))
            workspace = entry.get("workspace")
            if not CLIENT_RE.fullmatch(name) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                log.warning("ignoring invalid client entry %r", name)
                continue
            if workspace is not None and not (isinstance(workspace, str) and valid_fixed_workspace(workspace)):
                log.warning("ignoring client %r: invalid workspace", name)
                continue
            entries[name] = (digest, workspace)
        self.entries = entries

    def authenticate(self, token):
        """(name, fixed workspace or None) for the client whose key is TOKEN, or None."""
        with self.lock:
            try:
                self._load()
            except (OSError, ValueError) as exc:
                log.error("cannot read %s: %s", self.path, exc)
                raise HTTPError(503, "Gateway client list is unreadable") from exc
            entries = self.entries
        if not token:
            return None
        digest = hashlib.sha256(token.encode()).hexdigest()
        found = None
        for name, (expected, workspace) in entries.items():
            # Compare against every entry, so timing does not depend on order.
            if hmac.compare_digest(digest, expected):
                found = (name, workspace)
        return found


class Secret(Watched):
    """Honcho's JWT secret, and the workspace keys made with it."""

    def __init__(self, path):
        super().__init__(path)
        self.secret = b""
        self.tokens = {}

    def token(self, workspace):
        with self.lock:
            try:
                update = self.changed()
            except OSError as exc:
                log.error("cannot read %s: %s", self.path, exc)
                raise HTTPError(503, "Gateway cannot read Honcho's JWT secret") from exc
            if update is not None:
                self.secret = (update[1] or b"").strip()
                self.tokens = {}
            if not self.secret:
                raise HTTPError(503, "Honcho's JWT secret is missing")
            token = self.tokens.get(workspace)
            if token is None:
                token = self.tokens[workspace] = mint_jwt(self.secret, workspace)
            return token


class Workspaces:
    """Per-user workspaces: created in Honcho once, and their owners recorded.

    A recorded workspace is never handed to another client or user. A fixed
    workspace is the one clients.json names (an agent's own, or one several
    clients were given on purpose) and is not recorded.
    """

    def __init__(self, settings):
        self.settings = settings
        self.ready = set()
        self.locks = {}
        self.guard = threading.Lock()

    def _record(self, client, user, workspace):
        path = os.path.join(self.settings.records, workspace + ".json")
        try:
            with open(path, encoding="utf-8") as f:
                record = json.load(f)
        except FileNotFoundError:
            record = None
        except (OSError, ValueError) as exc:
            raise HTTPError(503, f"Workspace record {workspace} is unreadable") from exc
        if record is not None:
            if record.get("client") != client or record.get("user") != user:
                raise HTTPError(409, "This workspace belongs to another client or user")
            return
        os.makedirs(self.settings.records, mode=0o700, exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"
        record = {"workspace": workspace, "client": client, "user": user,
                  "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o640)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)

    def _create(self, workspace, token):
        conn = http.client.HTTPConnection(self.settings.upstream_host, self.settings.upstream_api_port,
                                          timeout=60)
        try:
            conn.request("POST", "/v3/workspaces", json.dumps({"id": workspace}).encode(),
                         {"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
            response = conn.getresponse()
            response.read()
        except (OSError, http.client.HTTPException) as exc:
            raise HTTPError(502, "Honcho is not reachable") from exc
        finally:
            conn.close()
        if response.status not in (200, 201):
            raise HTTPError(502, f"Honcho could not open the workspace (HTTP {response.status})")

    def ensure(self, client, user, workspace, token):
        if workspace in self.ready:
            return
        with self.guard:
            lock = self.locks.setdefault(workspace, threading.Lock())
        with lock:
            if workspace in self.ready:
                return
            if user is not None:
                try:
                    self._record(client, user, workspace)
                except OSError as exc:
                    raise HTTPError(503, f"Cannot record workspace {workspace}") from exc
            self._create(workspace, token)
            self.ready.add(workspace)


def bearer(headers):
    scheme, _, token = (headers.get("authorization") or "").partition(" ")
    return token.strip() if scheme.lower() == "bearer" else ""


def identify(clients, headers):
    """(client, user, workspace, per_user) for a request.

    user and workspace are None for a per-user client (Open WebUI) that named
    no user: such a request may only ask /osr/v1/whoami.
    """
    found = clients.authenticate(bearer(headers))
    if not found:
        raise HTTPError(401, "Invalid API key")
    name, fixed = found
    named = (headers.get("x-user-id") or "").strip()
    if fixed is not None:
        if named:
            raise HTTPError(403, "This client has a single workspace: send no X-User-Id")
        return name, None, fixed, False
    if not named:
        return name, None, None, True
    if not USER_RE.fullmatch(named):
        raise HTTPError(400, "Invalid X-User-Id")
    return name, named, workspace_name(name, named), True


def pin_workspace(body, workspace):
    """BODY (MCP JSON-RPC) with every tools/call workspace_id set to WORKSPACE.

    Honcho would refuse another workspace anyway; this turns a model's guess
    (osr, say) into the caller's own workspace instead of an error.
    """
    try:
        payload = json.loads(body)
    except ValueError:
        return body
    changed = False
    for message in payload if isinstance(payload, list) else [payload]:
        if not isinstance(message, dict) or message.get("method") != "tools/call":
            continue
        params = message.get("params")
        arguments = params.get("arguments") if isinstance(params, dict) else None
        if isinstance(arguments, dict) and "workspace_id" in arguments and arguments["workspace_id"] != workspace:
            arguments["workspace_id"] = workspace
            changed = True
    return json.dumps(payload, ensure_ascii=False).encode() if changed else body


class Gateway:
    def __init__(self, settings):
        self.settings = settings
        self.clients = Clients(settings.clients_file)
        self.secret = Secret(settings.secret_file)
        self.workspaces = Workspaces(settings)
        self.slots = threading.BoundedSemaphore(settings.max_connections)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "honcho-gateway"
    sys_version = ""
    timeout = 120

    def version_string(self):
        return self.server_version

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.address_string(), fmt % args)

    def log_request(self, code="-", size="-"):
        log.info('%s "%s" %s', self.address_string(), self.requestline, code)

    # -- helpers -----------------------------------------------------------
    def send_json(self, status, body, close=False):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def read_body(self):
        limit = self.server.gateway.settings.max_body
        if "chunked" in (self.headers.get("transfer-encoding") or "").lower():
            parts, total = [], 0
            while True:
                line = self.rfile.readline(1024)
                try:
                    size = int(line.split(b";", 1)[0].strip(), 16)
                except ValueError:
                    raise HTTPError(400, "Invalid chunked body") from None
                if size == 0:
                    while self.rfile.readline(8192) not in (b"\r\n", b"\n", b""):
                        pass
                    return b"".join(parts)
                total += size
                if total > limit:
                    raise HTTPError(413, "Request too large")
                parts.append(self.rfile.read(size))
                self.rfile.readline(8)
        raw = self.headers.get("content-length")
        if raw is None:
            return b""
        try:
            length = int(raw)
        except ValueError:
            raise HTTPError(400, "Invalid Content-Length") from None
        if length < 0:
            raise HTTPError(400, "Invalid Content-Length")
        if length > limit:
            raise HTTPError(413, "Request too large")
        return self.rfile.read(length)

    def upstream(self, method, path, headers, body):
        settings = self.server.gateway.settings
        conn = http.client.HTTPConnection(settings.upstream_host, self.server.upstream_port,
                                          timeout=settings.upstream_timeout)
        try:
            conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
            conn.putheader("Host", f"{settings.upstream_host}:{self.server.upstream_port}")
            for name, value in headers:
                conn.putheader(name, value)
            if body or method in ("POST", "PUT", "PATCH"):
                conn.putheader("Content-Length", str(len(body)))
            conn.endheaders(body or None)
            return conn, conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            conn.close()
            raise HTTPError(502, "Honcho is not reachable") from exc

    def relay(self, conn, response):
        """Copy RESPONSE to the client, streaming (Honcho's chat streams)."""
        try:
            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() not in HOP_HEADERS and name.lower() not in ("server", "date"):
                    self.send_header(name, value)
            length = response.getheader("content-length")
            if self.command == "HEAD" or response.status in (204, 304) or response.status < 200:
                if length is not None:
                    self.send_header("Content-Length", length)
                self.end_headers()
                return
            if length is not None:
                self.send_header("Content-Length", length)
                self.end_headers()
                while True:
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                return
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = response.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        except (OSError, http.client.HTTPException):
            # The client went away, or Honcho broke off mid-reply: nothing
            # useful can be sent any more.
            self.close_connection = True
        finally:
            conn.close()

    # -- requests ----------------------------------------------------------
    def handle_any(self):
        gateway = self.server.gateway
        path = self.path.split("?", 1)[0]
        body_read = False
        if not gateway.slots.acquire(timeout=30):
            self.send_json(503, {"detail": "Gateway is busy; try again later"}, close=True)
            return
        try:
            if path == "/health" and self.command in ("GET", "HEAD"):
                conn, response = self.upstream("GET", "/health", [], b"")
                self.relay(conn, response)
                return
            client, user, workspace, per_user = identify(gateway.clients, self.headers)
            if path == "/osr/v1/whoami" and self.command == "GET":
                self.send_json(200, {"client": client, "user": user, "workspace": workspace,
                                     "per_user": per_user})
                return
            if workspace is None:
                raise HTTPError(400, "X-User-Id is required: every Open WebUI user has their own memory")
            body = self.read_body()
            body_read = True
            token = gateway.secret.token(workspace)
            gateway.workspaces.ensure(client, user, workspace, token)
            if self.server.mode == "mcp" and self.command == "POST" and body:
                body = pin_workspace(body, workspace)
            headers = [(name, value) for name, value in self.headers.items()
                       if name.lower() not in HOP_HEADERS and name.lower() not in GATEWAY_HEADERS]
            headers.append(("Authorization", f"Bearer {token}"))
            if self.server.mode == "mcp":
                headers.append(("X-Honcho-Workspace-ID", workspace))
            conn, response = self.upstream(self.command, self.path, headers, body)
            self.relay(conn, response)
        except HTTPError as exc:
            # An unread request body would be taken for the next request.
            self.send_json(exc.status, {"detail": exc.detail}, close=not body_read)
        finally:
            gateway.slots.release()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_any


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, gateway, mode, upstream_port):
        self.gateway = gateway
        self.mode = mode
        self.upstream_port = upstream_port
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, Handler)


def servers(settings, gateway=None):
    gateway = gateway or Gateway(settings)
    return [Server((settings.host, settings.api_port), gateway, "api", settings.upstream_api_port),
            Server((settings.host, settings.mcp_port), gateway, "mcp", settings.upstream_mcp_port)]


def main():
    logging.basicConfig(level=os.environ.get("HONCHO_GATEWAY_LOG_LEVEL", "INFO"),
                        format="%(levelname)s %(name)s: %(message)s")
    settings = Settings()
    api, mcp = servers(settings)
    log.info("API on %s:%d -> %d, MCP on %s:%d -> %d", settings.host, settings.api_port,
             settings.upstream_api_port, settings.host, settings.mcp_port, settings.upstream_mcp_port)
    threading.Thread(target=mcp.serve_forever, daemon=True).start()
    api.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as exc:
        sys.exit(f"Honcho gateway: {exc}")
