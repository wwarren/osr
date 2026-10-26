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


class Candidates(list):
    """Entries to try, in order. pinned: only the replicas of the model a
    task is pinned to; when they all fail, the caller asks again unpinned."""
    pinned = False


LOADED_ORDER = {True: 0, None: 1, False: 2}


class _SSEDone:
    """Recognize a complete SSE [DONE] line across backend read boundaries."""
    def __init__(self):
        self.pending = b""
        self.overlong = False
        self.seen = False

    def feed(self, chunk):
        # A [DONE] line is short. Cap an unfinished line so a large data event
        # cannot make completion tracking grow with the response.
        parts = chunk.split(b"\n")
        for part in parts[:-1]:
            if not self.overlong and len(self.pending) + len(part) <= 128:
                line = (self.pending + part).rstrip(b"\r")
                if line.startswith(b"data:") and line[5:].strip() == b"[DONE]":
                    self.seen = True
            self.pending = b""
            self.overlong = False
        tail = parts[-1]
        if not self.overlong:
            if len(self.pending) + len(tail) <= 128:
                self.pending += tail
            else:
                self.pending = b""
                self.overlong = True

    def finish(self):
        """At EOF: a last "data: [DONE]" without a line end still counts."""
        if not self.overlong:
            self.feed(b"\n")
        return self.seen


class Dispatcher:
    def __init__(self, router_url, router_key, backend_keys=None, min_context=0):
        self.router_url = router_url.rstrip("/")
        # HERMES_CONTEXT_LENGTH: a model reported to serve less is never used.
        self.min_context = min_context
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

    def _live(self, entries):
        """The entries whose server has not failed in the last SKIP_SECONDS."""
        now = time.monotonic()
        with self._lock:
            return [m for m in entries
                    if now - self._failed.get(m["server"], -SKIP_SECONDS) >= SKIP_SECONDS]

    def candidates(self, body, unpinned=False):
        """Ranked entries, without the servers that failed in the last
        SKIP_SECONDS. If every candidate is on such a server, all are kept:
        trying again beats refusing outright. unpinned: ignore the task's
        pinned model and rank afresh (its replicas have just failed)."""
        ranked = self._ranked(body, unpinned)
        result = Candidates(self._live(ranked) or ranked)
        result.pinned = ranked.pinned
        return result

    def usable(self, entry):
        """Whether Hermes may use this entry at all. Hermes is a tool agent,
        so a model known to lack tools is never used, not even for a request
        without tools (context compression, summaries); and a model reported
        to serve less context than HERMES_CONTEXT_LENGTH would silently lose
        the start of the conversation. Unknown (None) passes both checks.
        This keeps AirLLM (no tools, a 2048-token window) away from Hermes."""
        context = entry.get("context_length")
        return (entry.get("tools") is not False
                and not (isinstance(context, int) and context < self.min_context))

    def _ranked(self, body, unpinned=False):
        inventory = self.inventory()
        chat = [m for m in inventory["models"] if m.get("name") and not m.get("is_embedding")]
        models = [m for m in chat if self.usable(m)]
        requested = str(body.get("model") or "auto")
        routed = requested in TIER_ALIASES or requested == "auto"
        # A real model name stays a request for that model even when it is not
        # usable (it then gets no candidates); only other names are router aliases.
        if not routed and not any(m["name"].lower() == requested.lower() for m in chat):
            routed = requested in self.router_models()
        session = self.session_key(body) if routed else None
        pinned = None
        if session and not unpinned:
            with self._lock:
                saved = self._sessions.get(session)
                if saved and time.monotonic() - saved[2] < 3600:
                    pinned = saved[:2]
        if not routed:
            matches = [m for m in models if m["name"].lower() == requested.lower()]
            return Candidates(sorted(matches, key=lambda m: LOADED_ORDER[m.get("loaded")]))
        if pinned:
            # Keep the task on its model while a replica of it is not known
            # to have failed. Otherwise the pin is dropped and the router
            # ranks afresh, as it would for a new task.
            matches = [m for m in models if m["name"].lower() == pinned[1].lower()]
            if self._live(matches):
                matches.sort(key=lambda m: (m["server"] != pinned[0], LOADED_ORDER[m.get("loaded")]))
                result = Candidates(matches)
                result.pinned = True
                return result
        decision = request_json(self.router_url + "/routing/explain", self.router_key, body)
        rank = {(c.get("server"), c.get("model")): i
                for i, c in enumerate(decision.get("candidates") or [])}
        # The router supplies the first ten ranked pairs. Inventory can be
        # larger; remaining registered servers are still eligible.
        if unpinned or pinned:
            # This is a failed task's fallback. Respect the router's order even
            # when a lower-ranked model happens to be loaded already.
            models.sort(key=lambda m: (rank.get((m["server"], m["name"]), len(rank)),
                                       LOADED_ORDER[m.get("loaded")]))
            return Candidates(models)
        # A resident model wins over a
        # cold/unknown one so an agent need not wait for a model load.
        models.sort(key=lambda m: (LOADED_ORDER[m.get("loaded")],
                                   rank.get((m["server"], m["name"]), len(rank))))
        if models:
            primary = models[0]["name"]
            models = ([m for m in models if m["name"] == primary]
                      + [m for m in models if m["name"] != primary])
        return Candidates(models)

    def model_list(self):
        """What Hermes may ask for: auto, the router's aliases and models, and
        inventory models, minus models that are never usable (usable() false
        on every server that serves them)."""
        chat = [m for m in self.inventory()["models"] if m.get("name") and not m.get("is_embedding")]
        names = {m["name"] for m in chat if self.usable(m)}
        unusable = {m["name"] for m in chat} - names
        names.update(self.router_models() - unusable)
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
    # HTTP/1.1, so a relayed model response can be sent chunked: its final
    # zero-length chunk is written only when the backend finished cleanly. A
    # backend that breaks off leaves the client with an incomplete chunked
    # body, which its HTTP library reports as an error, never as a short but
    # complete answer.
    protocol_version = "HTTP/1.1"
    dispatcher = None

    def log_message(self, fmt, *args):
        LOG.info("%s %s", self.client_address[0], fmt % args)

    def json_response(self, status, payload, close=False):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, message):
        # The request body may be unread, so the connection is not reused.
        self.json_response(status, {"error": {"message": message, "type": "server_error"}}, close=True)

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
            self.error(503, "No available chat model with tool support and at least "
                       f"{self.dispatcher.min_context} tokens of context")
            return
        self.last_error = ""
        tried = set()
        # A pinned task tries its model's replicas first. If none answers,
        # the router ranks afresh and the task moves to the best healthy model.
        if self.relay(body, candidates, tried, final=not candidates.pinned):
            return
        if candidates.pinned:
            try:
                rest = [m for m in self.dispatcher.candidates(body, unpinned=True)
                        if (m["server"], m["name"]) not in tried]
            except (ValueError, TypeError, URLError) as exc:
                rest = []
                self.last_error += f"; could not rank a fallback: {exc}"
            if rest and self.relay(body, rest, tried, final=True):
                return
        self.error(502, "No model server answered directly. " + self.last_error)

    def relay(self, body, candidates, tried, final):
        """Try candidates in order; True once a response was sent. With final
        false, a retryable HTTP error from the last candidate is not passed
        on, because the caller has more to try."""
        for index, entry in enumerate(candidates):
            last = final and index == len(candidates) - 1
            tried.add((entry["server"], entry["name"]))
            try:
                upstream = self.dispatcher.open_backend(entry, body)
            except HTTPError as exc:
                self.last_error = f"{entry['name']} at {entry['server']}: HTTP {exc.code}"
                data = exc.read()
                exc.close()
                if exc.code == 400 and body.get("tools") and TOOL_REJECTION.search(data):
                    entry["tools"] = False
                    if not last:
                        continue
                if exc.code in (404, 429, 500, 502, 503, 504) and not last:
                    continue
                self.send_response(exc.code)
                self.send_header("Content-Type", exc.headers.get("Content-Type", "application/json"))
                if exc.headers.get("Content-Encoding"):
                    self.send_header("Content-Encoding", exc.headers["Content-Encoding"])
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return True
            except ValueError as exc:
                self.last_error = f"{entry['name']} at {entry['server']}: {exc}"
                continue
            except OSError as exc:
                # Refused, timed out, reset, DNS failure: the server is
                # unreachable from this CT (URLError and TimeoutError are
                # OSErrors; HTTPError, an answer, was handled above).
                self.last_error = f"{entry['name']} at {entry['server']}: {exc}"
                LOG.warning("model server %s is unreachable (%s); skipping it for %ss",
                            entry["server"], exc, SKIP_SECONDS)
                self.dispatcher.mark_failed(entry["server"])
                continue
            LOG.info("direct dispatch %s -> %s", entry["name"], entry["server"])
            self.dispatcher.mark_ok(entry["server"])
            with upstream:
                if self.stream(upstream, entry, body):
                    self.dispatcher.record_success(body, entry)
            return True
        return False

    def stream(self, upstream, entry, body):
        """Relay a backend response as chunked HTTP/1.1. True if the backend
        finished cleanly and the client received the whole response."""
        streaming = body.get("stream") is True
        # A body with Content-Length or chunked encoding has an HTTP-level end,
        # checked below. A body that ends only when the backend closes the
        # connection (HTTP/1.0 style) has none, so its content must show that
        # it is complete: an SSE stream needs its [DONE] event, a chat
        # completion must be a whole JSON object.
        unframed = upstream.length is None and not upstream.chunked
        done = _SSEDone() if streaming and unframed else None
        json_body = bytearray() if unframed and not streaming else None
        self.send_response(upstream.status)
        self.send_header("Content-Type", upstream.headers.get("Content-Type", "application/json"))
        if upstream.headers.get("Content-Encoding"):
            self.send_header("Content-Encoding", upstream.headers["Content-Encoding"])
        self.send_header("X-Hermes-Direct-Model", entry["name"])
        self.send_header("X-Hermes-Direct-Server", entry["server"])
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        while True:
            try:
                chunk = upstream.read1(65536)
            except (http.client.HTTPException, OSError) as exc:
                LOG.warning("model server %s dropped its response (%s); skipping it for %ss",
                            entry["server"], exc, SKIP_SECONDS)
                break
            if not chunk:
                # read1() returns EOF quietly for a body shorter than its
                # Content-Length; the length left says so.
                if upstream.length:
                    LOG.warning("model server %s ended its response early; skipping it for %ss",
                                entry["server"], SKIP_SECONDS)
                    break
                if done is not None and not done.finish():
                    LOG.warning("model server %s ended its stream without [DONE]; skipping it for %ss",
                                entry["server"], SKIP_SECONDS)
                    break
                if json_body is not None:
                    try:
                        complete = json.loads(json_body)
                        if not isinstance(complete, dict):
                            raise ValueError("chat response is not a JSON object")
                    except (ValueError, UnicodeDecodeError) as exc:
                        LOG.warning("model server %s ended with incomplete JSON (%s); skipping it for %ss",
                                    entry["server"], exc, SKIP_SECONDS)
                        break
                try:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                except OSError:
                    self.close_connection = True
                    return False
                return True
            if done is not None:
                done.feed(chunk)
            if json_body is not None:
                json_body.extend(chunk)
            try:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            except OSError:
                # The client went away; the backend is not at fault.
                self.close_connection = True
                return False
        # The backend broke off: skip it, and close without the final chunk.
        self.dispatcher.mark_failed(entry["server"])
        self.close_connection = True
        return False


def main():
    home = os.environ.get("HERMES_HOME", "/home/hermes/.hermes")
    etc = os.environ.get("HERMES_ETC", "/etc/hermes-target")
    settings = read_env(etc + "/settings")
    secrets = read_env(home + "/.env")
    keys = read_env(etc + "/backend-keys")
    router_url = settings.get("ROUTER_URL", "")
    if not router_url:
        raise SystemExit("ROUTER_URL missing from Hermes settings")
    try:
        min_context = int(settings.get("HERMES_CONTEXT_LENGTH") or 0)
    except ValueError:
        raise SystemExit("HERMES_CONTEXT_LENGTH in Hermes settings is not a number") from None
    Handler.dispatcher = Dispatcher(router_url, secrets.get("ROUTER_API_KEY", ""), keys, min_context)
    port = int(os.environ.get("HERMES_DIRECT_PORT", "8765"))
    logging.basicConfig(level=logging.INFO)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
