#!/usr/bin/env python3
"""Local OpenAI chat endpoint for Hermes; inventory comes from the router.

The router chooses candidates, but model tokens go from this CT to a model
server. No inference request is sent to the router. Bind to loopback only.
"""

import hashlib
import http.client
import json
import logging
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPHandler, HTTPSHandler, Request, build_opener, urlopen


LOG = logging.getLogger("hermes-direct")
KEY_NAMES = {
    "lmstudio": "LMSTUDIO_API_TOKEN",
    "strata": "STRATA_API_KEY",
    "basalt": "BASALT_API_KEY",
    "maya": "MAYA_API_KEY",
    "xolotl": "XOLOTL_API_KEY",
}
PREFIXES = {kind: kind + "+" for kind in KEY_NAMES}
MAX_BODY = 64 * 1024 * 1024
TIER_ALIASES = frozenset(("fast", "medium", "large", "xlarge"))
TOOL_REJECTION = re.compile(rb"(does not support tools|tool calling.{0,30}not supported|tools? not supported)", re.I)
# A model server that cannot be reached is skipped for SKIP_SECONDS. A short
# connect timeout finds it quickly: a firewall that drops the connection would
# otherwise hold every request for the kernel's SYN retries (about 2 minutes).
CONNECT_TIMEOUT = 5
READ_TIMEOUT = 300
SKIP_SECONDS = 60


def read_env(path):
    try:
        with open(path, encoding="utf-8") as source:
            return dict(line.rstrip("\n").split("=", 1) for line in source
                        if "=" in line and not line.lstrip().startswith("#"))
    except FileNotFoundError:
        return {}


def server_parts(server):
    kind = "ollama"
    for candidate, prefix in PREFIXES.items():
        if server.startswith(prefix):
            kind, server = candidate, server[len(prefix):]
            break
    parsed = urlsplit(server)
    # No port: the scheme's default (80 or 443), as for any URL. .port also
    # rejects an out-of-range port with ValueError.
    if parsed.scheme not in ("http", "https") or not parsed.hostname \
            or parsed.port == 0 or parsed.username or parsed.password or parsed.query or parsed.fragment \
            or "/../" in parsed.path or parsed.path.endswith("/.."):
        raise ValueError("invalid model server URL")
    return kind, server.rstrip("/")


class _ConnectTimeout:
    """Connect (and TLS handshake) within CONNECT_TIMEOUT; then wait up to the
    request's own timeout for data, which a slow model load may need."""

    def connect(self):
        read_timeout, self.timeout = self.timeout, CONNECT_TIMEOUT
        try:
            super().connect()
        finally:
            self.timeout = read_timeout
        self.sock.settimeout(read_timeout)


class _HTTPConnection(_ConnectTimeout, http.client.HTTPConnection):
    pass


class _HTTPSConnection(_ConnectTimeout, http.client.HTTPSConnection):
    pass


class _HTTPHandler(HTTPHandler):
    def http_open(self, req):
        return self.do_open(_HTTPConnection, req)


class _HTTPSHandler(HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_HTTPSConnection, req, context=self._context)


BACKEND = build_opener(_HTTPHandler, _HTTPSHandler)


def request_json(url, key, body=None, timeout=10):
    headers = {"Accept": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    if body is not None:
        headers["Content-Type"] = "application/json"
    data = None if body is None else json.dumps(body).encode()
    with urlopen(Request(url, data=data, headers=headers), timeout=timeout) as response:
        return json.load(response)


class Dispatcher:
    def __init__(self, router_url, router_key, backend_keys=None):
        self.router_url = router_url.rstrip("/")
        self.router_key = router_key
        self.backend_keys = backend_keys or {}
        self._inventory = None
        self._inventory_time = 0
        self._sessions = {}
        self._failed = {}
        self._lock = threading.Lock()

    def inventory(self):
        with self._lock:
            if self._inventory is not None and time.monotonic() - self._inventory_time < 5:
                return self._inventory
        data = request_json(self.router_url + "/routing/inventory", self.router_key)
        if not data.get("enabled") or not isinstance(data.get("models"), list):
            raise ValueError("router model discovery is disabled")
        registered = set(data.get("servers") or [])
        # Only entries for registered, live servers may become destinations.
        data["models"] = [m for m in data["models"] if isinstance(m, dict)
                          and m.get("server") in registered
                          and data.get("server_status", {}).get(m["server"], {}).get("up")]
        with self._lock:
            self._inventory, self._inventory_time = data, time.monotonic()
        return data

    @staticmethod
    def session_key(body):
        metadata = body.get("metadata") or {}
        if isinstance(metadata, dict):
            for field in ("session_id", "conversation_id"):
                if isinstance(metadata.get(field), str) and metadata[field]:
                    return field + ":" + metadata[field]
        for message in body.get("messages") or []:
            if isinstance(message, dict) and message.get("role") == "user":
                value = json.dumps(message.get("content"), sort_keys=True, ensure_ascii=False)
                return "first-user:" + hashlib.sha256(value.encode()).hexdigest()
        return None

    def mark_failed(self, server):
        with self._lock:
            self._failed[server] = time.monotonic()

    def mark_ok(self, server):
        with self._lock:
            self._failed.pop(server, None)

    def candidates(self, body):
        """Ranked entries, without the servers that failed in the last
        SKIP_SECONDS. If every candidate is on such a server, all are kept:
        trying again beats refusing outright."""
        ranked = self._ranked(body)
        now = time.monotonic()
        with self._lock:
            live = [m for m in ranked
                    if now - self._failed.get(m["server"], -SKIP_SECONDS) >= SKIP_SECONDS]
        return live or ranked

    def _ranked(self, body):
        inventory = self.inventory()
        models = [m for m in inventory["models"] if m.get("name")
                  and not m.get("is_embedding")
                  and (not body.get("tools") or m.get("tools") is not False)]
        requested = str(body.get("model") or "auto")
        routed = requested in TIER_ALIASES or requested == "auto"
        if not routed and not any(m["name"].lower() == requested.lower() for m in models):
            routed = requested in self.router_models()
        session = self.session_key(body) if routed else None
        pinned = None
        if session:
            with self._lock:
                saved = self._sessions.get(session)
                if saved and time.monotonic() - saved[2] < 3600:
                    pinned = saved[:2]
        if not routed or pinned:
            name = pinned[1] if pinned else requested
            matches = [m for m in models if m["name"].lower() == name.lower()]
            return sorted(matches, key=lambda m: (
                m["server"] != pinned[0] if pinned else False,
                {True: 0, None: 1, False: 2}[m.get("loaded")]))
        decision = request_json(self.router_url + "/routing/explain", self.router_key, body)
        rank = {(c.get("server"), c.get("model")): i
                for i, c in enumerate(decision.get("candidates") or [])}
        # The router supplies the first ten ranked pairs. Inventory can be
        # larger; remaining registered servers are still eligible.
        # A resident model wins over a
        # cold/unknown one so an agent need not wait for a model load.
        models.sort(key=lambda m: ({True: 0, None: 1, False: 2}[m.get("loaded")],
                                   rank.get((m["server"], m["name"]), len(rank))))
        if models:
            primary = models[0]["name"]
            models = ([m for m in models if m["name"] == primary]
                      + [m for m in models if m["name"] != primary])
        return models

    def model_list(self):
        names = {m["name"] for m in self.inventory()["models"]
                 if m.get("name") and not m.get("is_embedding")
                 }
        names.update(self.router_models())
        names.discard("auto")
        return {"object": "list", "data": [{"id": name, "object": "model"}
                                          for name in ["auto", *sorted(names)]]}

    def router_models(self):
        data = request_json(self.router_url + "/v1/models", self.router_key)
        return {m["id"] for m in data.get("data", [])
                if isinstance(m, dict) and isinstance(m.get("id"), str)}

    def record_success(self, body, entry):
        if str(body.get("model") or "auto").lower() == entry["name"].lower():
            return
        session = self.session_key(body)
        if session:
            with self._lock:
                self._sessions[session] = (entry["server"], entry["name"], time.monotonic())
                if len(self._sessions) > 2048:
                    oldest = min(self._sessions, key=lambda k: self._sessions[k][2])
                    del self._sessions[oldest]

    def open_backend(self, entry, body):
        kind, base = server_parts(entry["server"])
        headers = {"Content-Type": "application/json", "Accept": "text/event-stream, application/json",
                   "Accept-Encoding": "identity"}
        key = self.backend_keys.get(KEY_NAMES.get(kind, ""), "")
        if key:
            headers["Authorization"] = "Bearer " + key
        payload = dict(body, model=entry["name"])
        return BACKEND.open(Request(base + "/v1/chat/completions",
                                    data=json.dumps(payload).encode(), headers=headers),
                            timeout=READ_TIMEOUT)


class Handler(BaseHTTPRequestHandler):
    dispatcher = None

    def log_message(self, fmt, *args):
        LOG.info("%s %s", self.client_address[0], fmt % args)

    def json_response(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, message):
        self.json_response(status, {"error": {"message": message, "type": "server_error"}})

    def do_GET(self):
        if self.path == "/healthz":
            self.json_response(200, {"status": "ok"})
        elif self.path == "/v1/models":
            try:
                self.json_response(200, self.dispatcher.model_list())
            except (URLError, ValueError) as exc:
                self.error(503, "Router inventory unavailable: " + str(exc))
        else:
            self.error(404, "Unknown endpoint")

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.error(404, "Unknown endpoint")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length < 1 or length > MAX_BODY:
                self.error(413, "Invalid request size")
                return
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict) or not isinstance(body.get("messages"), list):
                self.error(400, "Expected a chat completion request")
                return
            candidates = self.dispatcher.candidates(body)
        except (ValueError, TypeError, URLError) as exc:
            self.error(503, "Could not choose a model: " + str(exc))
            return
        if not candidates:
            self.error(503, "No available loaded or loadable tool-capable chat model")
            return
        last_error = ""
        for entry in candidates:
            try:
                upstream = self.dispatcher.open_backend(entry, body)
            except HTTPError as exc:
                last_error = f"{entry['name']} at {entry['server']}: HTTP {exc.code}"
                data = exc.read()
                if exc.code == 400 and body.get("tools") and TOOL_REJECTION.search(data):
                    entry["tools"] = False
                    if entry != candidates[-1]:
                        exc.close()
                        continue
                if exc.code in (404, 429, 500, 502, 503, 504) and entry != candidates[-1]:
                    exc.close()
                    continue
                exc.close()
                self.send_response(exc.code)
                self.send_header("Content-Type", exc.headers.get("Content-Type", "application/json"))
                if exc.headers.get("Content-Encoding"):
                    self.send_header("Content-Encoding", exc.headers["Content-Encoding"])
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            except ValueError as exc:
                last_error = f"{entry['name']} at {entry['server']}: {exc}"
                continue
            except OSError as exc:
                # Refused, timed out, reset, DNS failure: the server is
                # unreachable from this CT (URLError and TimeoutError are
                # OSErrors; HTTPError, an answer, was handled above).
                last_error = f"{entry['name']} at {entry['server']}: {exc}"
                LOG.warning("model server %s is unreachable (%s); skipping it for %ss",
                            entry["server"], exc, SKIP_SECONDS)
                self.dispatcher.mark_failed(entry["server"])
                continue
            LOG.info("direct dispatch %s -> %s", entry["name"], entry["server"])
            self.dispatcher.mark_ok(entry["server"])
            self.dispatcher.record_success(body, entry)
            with upstream:
                self.send_response(upstream.status)
                self.send_header("Content-Type", upstream.headers.get("Content-Type", "application/json"))
                if upstream.headers.get("Content-Encoding"):
                    self.send_header("Content-Encoding", upstream.headers["Content-Encoding"])
                self.send_header("X-Hermes-Direct-Model", entry["name"])
                self.send_header("X-Hermes-Direct-Server", entry["server"])
                self.end_headers()
                try:
                    while chunk := upstream.read1(65536):
                        self.wfile.write(chunk)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            return
        self.error(502, "No model server answered directly. " + last_error)


def main():
    home = os.environ.get("HERMES_HOME", "/home/hermes/.hermes")
    etc = os.environ.get("HERMES_ETC", "/etc/hermes-target")
    settings = read_env(etc + "/settings")
    secrets = read_env(home + "/.env")
    keys = read_env(etc + "/backend-keys")
    router_url = settings.get("ROUTER_URL", "")
    if not router_url:
        raise SystemExit("ROUTER_URL missing from Hermes settings")
    Handler.dispatcher = Dispatcher(router_url, secrets.get("ROUTER_API_KEY", ""), keys)
    port = int(os.environ.get("HERMES_DIRECT_PORT", "8765"))
    logging.basicConfig(level=logging.INFO)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
