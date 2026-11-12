#!/usr/bin/env python3
"""An OpenAI-compatible chat endpoint in front of OpenCode's own server API.

OpenCode 2 has no /v1/chat/completions; its server speaks sessions, prompts
and a server-wide event stream. This proxy lets Open WebUI use OpenCode like
Hermes and OpenClaw: it lists one model (OPENCODE_API_MODEL, "opencode") and
turns each chat request into one prompt in an OpenCode session.

Conversations. Open WebUI sends the whole history with every request and no
chat ID. The proxy keys each OpenCode session by a hash of the conversation
so far (user and assistant turns, normalised). A request whose history is the
last state the proxy left a session in continues that session with its new
user message; any other request (a new chat, a regenerated or edited reply,
a chat that was started elsewhere) gets a new session, given the earlier
turns as context. Sessions keep OpenCode's own history, tools and workspace,
and appear in OpenCode's web UI too.

A turn: subscribe to /api/event, POST the prompt (delivery "queue"), and from
its delivery stream session.text.delta as content (session.text.ended fills
anything missed),
reasoning and tool activity as reasoning_content, until the session's
execution succeeds, fails or is interrupted. Permission requests in the
session (and its subagents') are answered by OPENCODE_API_PERMISSIONS: allow
("once") or reject; questions are cancelled, since a chat client cannot answer
them. A client that goes away interrupts the turn.

Configuration (environment): OPENCODE_PASSWORD (the server's), OPENCODE_API_KEY
(the bearer key clients must send), OPENCODE_PORT=4096, OPENCODE_API_PORT=4097,
OPENCODE_API_BIND=0.0.0.0, OPENCODE_API_MODEL=opencode,
OPENCODE_API_DIRECTORY=/home/opencode/workspace, OPENCODE_API_PERMISSIONS=allow,
OPENCODE_API_TURN_TIMEOUT=3600, OPENCODE_API_ACTIVITY=true,
OPENCODE_API_STATE=/var/lib/opencode-api/sessions.json, OPENCODE_API_MAX_TURNS=4.
Standard library only.
"""
import base64
import hashlib
import hmac
import http.client
import http.server
import json
import logging
import os
import queue
import re
import socket
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid

LOG = logging.getLogger("opencode-api")

# The events a turn needs; the stream is filtered to these on the server.
EVENT_TYPES = (
    "session.inbox.delivered",
    "session.execution.succeeded",
    "session.execution.failed",
    "session.execution.interrupted",
    "session.text.delta",
    "session.text.ended",
    "session.reasoning.delta",
    "session.tool.input.started",
    "session.tool.failed",
    "permission.asked",
    "form.created",
)
PERMISSION_REJECTED = ("This chat runs without a person to approve actions, so the request was rejected. "
                       "Continue without this action.")
QUESTION_CANCELLED = ("This chat cannot ask the user questions, so the question was cancelled. Continue "
                      "without an answer; make reasonable assumptions and state them.")
KEEPALIVE_SECONDS = 15
STATE_LIMIT = 5000


class Config:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        self.password = env.get("OPENCODE_PASSWORD", "")
        self.api_key = env.get("OPENCODE_API_KEY", "")
        self.upstream_host = env.get("OPENCODE_HOST", "127.0.0.1")
        self.upstream_port = int(env.get("OPENCODE_PORT", "4096"))
        self.bind = env.get("OPENCODE_API_BIND", "0.0.0.0")
        self.port = int(env.get("OPENCODE_API_PORT", "4097"))
        self.model = env.get("OPENCODE_API_MODEL", "opencode")
        self.directory = env.get("OPENCODE_API_DIRECTORY", "/home/opencode/workspace")
        self.permissions = env.get("OPENCODE_API_PERMISSIONS", "allow")
        self.turn_timeout = float(env.get("OPENCODE_API_TURN_TIMEOUT", "3600"))
        self.activity = env.get("OPENCODE_API_ACTIVITY", "true") == "true"
        self.state = env.get("OPENCODE_API_STATE", "/var/lib/opencode-api/sessions.json")
        self.max_turns = int(env.get("OPENCODE_API_MAX_TURNS", "4"))
        if not self.password or not self.api_key:
            raise SystemExit("OPENCODE_PASSWORD and OPENCODE_API_KEY must be set")
        if self.permissions not in ("allow", "reject"):
            raise SystemExit("OPENCODE_API_PERMISSIONS must be allow or reject")


class UpstreamError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class TurnError(Exception):
    """The session's execution failed or was interrupted."""


class ClientGone(Exception):
    """The chat client closed its connection."""


# --- conversations -----------------------------------------------------------------

_DETAILS = re.compile(r"<details\b[^>]*>.*?</details>", re.S | re.I)
_THINK = re.compile(r"<think>.*?</think>", re.S | re.I)


def content_text(content):
    """The text of an OpenAI message content: a string, or a list of parts
    (only text parts count; images are not passed on)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content
                         if isinstance(p, dict) and p.get("type") in ("text", "input_text")
                         and isinstance(p.get("text"), str))
    return ""


def normalise(text):
    """What Open WebUI sends back of a reply: without reasoning blocks it adds,
    and with white space collapsed, so a round trip keeps the same key."""
    text = _THINK.sub("", _DETAILS.sub("", text or ""))
    return " ".join(text.split())


def conversation_key(turns):
    """A stable key for a list of (role, text) user/assistant turns."""
    digest = hashlib.sha256()
    for role, text in turns:
        digest.update(role.encode() + b"\0" + normalise(text).encode() + b"\0\0")
    return digest.hexdigest()


def split_messages(messages):
    """(system text, earlier user/assistant turns, the last user message)."""
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages must be a non-empty list")
    last = None
    for index in range(len(messages) - 1, -1, -1):
        item = messages[index]
        if isinstance(item, dict) and item.get("role") == "user":
            last = index
            break
    if last is None:
        raise ValueError("the conversation has no user message")
    if any(isinstance(m, dict) and m.get("role") in ("user", "assistant") for m in messages[last + 1:]):
        raise ValueError("the last turn must be a user message")
    system, prior = [], []
    for item in messages[:last]:
        if not isinstance(item, dict):
            continue
        role, text = item.get("role"), content_text(item.get("content"))
        if role in ("system", "developer"):
            if text.strip():
                system.append(text.strip())
        elif role in ("user", "assistant") and text.strip():
            prior.append((role, text))
    for item in messages[last + 1:]:
        if isinstance(item, dict) and item.get("role") in ("system", "developer"):
            system.append(content_text(item.get("content")).strip())
    user = content_text(messages[last].get("content")).strip()
    if not user:
        raise ValueError("the last user message has no text")
    return "\n\n".join(s for s in system if s), prior, user


def first_prompt(system, prior, user):
    """The prompt that opens a new session: the client's instructions and the
    earlier turns as context, then the message itself."""
    if not system and not prior:
        return user
    parts = []
    if system:
        parts.append("Instructions from the chat client:\n" + system)
    if prior:
        lines = [f"{'User' if role == 'user' else 'Assistant'}: {text.strip()}" for role, text in prior]
        parts.append("Earlier in this conversation (continued from the chat client):\n\n" + "\n\n".join(lines))
    parts.append("Current message:\n" + user)
    return "\n\n".join(parts)


class Store:
    """Which OpenCode session a conversation state belongs to, kept on disk.
    keys: conversation key -> session; heads: session -> its latest key."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.keys, self.heads = {}, {}
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            self.keys = {k: v for k, v in (data.get("keys") or {}).items() if isinstance(v, dict)}
            self.heads = {k: v for k, v in (data.get("heads") or {}).items() if isinstance(v, str)}
        except (OSError, ValueError, AttributeError):
            pass

    def lookup(self, key):
        """The session whose latest state is KEY, or None (unknown, or the
        session has moved on since: a regenerated or edited reply)."""
        with self.lock:
            entry = self.keys.get(key)
            session = entry.get("session") if entry else None
            if session and self.heads.get(session) == key:
                return session
            return None

    def advance(self, session, key):
        with self.lock:
            self.keys[key] = {"session": session, "at": time.time()}
            self.heads[session] = key
            if len(self.keys) > STATE_LIMIT:
                for old, _ in sorted(self.keys.items(), key=lambda kv: kv[1].get("at", 0))[:len(self.keys) - STATE_LIMIT]:
                    self.keys.pop(old, None)
                live = {v["session"] for v in self.keys.values()}
                self.heads = {s: k for s, k in self.heads.items() if s in live}
            self._save()

    def forget(self, session):
        with self.lock:
            self.heads.pop(session, None)
            self.keys = {k: v for k, v in self.keys.items() if v.get("session") != session}
            self._save()

    def _save(self):
        directory = os.path.dirname(self.path) or "."
        try:
            fd, temporary = tempfile.mkstemp(prefix=".sessions-", dir=directory)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"keys": self.keys, "heads": self.heads}, f)
            os.replace(temporary, self.path)
        except OSError as exc:
            LOG.warning("could not save %s: %s", self.path, exc)


# --- OpenCode's server ---------------------------------------------------------------

class Upstream:
    def __init__(self, config):
        self.config = config
        token = base64.b64encode(f"opencode:{config.password}".encode()).decode()
        self.auth = f"Basic {token}"

    def request(self, method, path, body=None, timeout=30):
        conn = http.client.HTTPConnection(self.config.upstream_host, self.config.upstream_port, timeout=timeout)
        try:
            data = json.dumps(body).encode() if body is not None else b""
            headers = {"Authorization": self.auth, "Accept": "application/json", "Content-Length": str(len(data))}
            if body is not None:
                headers["Content-Type"] = "application/json"
            conn.request(method, path, body=data, headers=headers)
            response = conn.getresponse()
            raw = response.read()
            value = None
            if raw:
                try:
                    value = json.loads(raw)
                except ValueError:
                    value = None
            if response.status >= 400:
                message = value.get("message") if isinstance(value, dict) else None
                raise UpstreamError(response.status, message or f"{method} {path}: HTTP {response.status}")
            return value
        except (OSError, http.client.HTTPException) as exc:
            raise UpstreamError(502, f"OpenCode is unreachable: {exc}") from exc
        finally:
            conn.close()

    def events(self):
        """An open /api/event subscription: (connection, line reader)."""
        query = urllib.parse.urlencode([("types", t) for t in EVENT_TYPES])
        conn = http.client.HTTPConnection(self.config.upstream_host, self.config.upstream_port,
                                          timeout=KEEPALIVE_SECONDS * 3)
        try:
            conn.request("GET", f"/api/event?{query}",
                         headers={"Authorization": self.auth, "Accept": "text/event-stream"})
            response = conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            conn.close()
            raise UpstreamError(502, f"OpenCode is unreachable: {exc}") from exc
        if response.status != 200:
            conn.close()
            raise UpstreamError(502, f"OpenCode's event stream answered HTTP {response.status}")
        return conn, response

    def session_parent(self, session):
        try:
            data = (self.request("GET", f"/api/session/{urllib.parse.quote(session)}") or {}).get("data") or {}
        except UpstreamError:
            return None
        return data.get("parentID")

    def interrupt(self, session):
        try:
            self.request("POST", f"/api/session/{urllib.parse.quote(session)}/interrupt", timeout=10)
        except UpstreamError as exc:
            LOG.warning("could not interrupt %s: %s", session, exc)


def read_events(response, sink, stop):
    """Parse the SSE stream into dicts on SINK until it ends or STOP is set;
    a failure is put on SINK as an exception."""
    data = []
    try:
        while not stop.is_set():
            line = response.readline()
            if not line:
                raise UpstreamError(502, "OpenCode's event stream ended")
            line = line.decode("utf-8", "replace").rstrip("\r\n")
            if not line:
                if data:
                    try:
                        sink.put(json.loads("\n".join(data)))
                    except ValueError:
                        pass
                    data = []
                continue
            if line.startswith("data:"):
                data.append(line[5:].lstrip(" "))
    except Exception as exc:  # noqa: BLE001 - every failure ends the turn
        if not stop.is_set():
            sink.put(exc if isinstance(exc, UpstreamError) else UpstreamError(502, f"event stream: {exc}"))


class Turn:
    """One prompt in one session, from admission to its execution's end."""

    def __init__(self, config, upstream, session, emit, tick, streaming=True):
        self.config, self.upstream, self.session = config, upstream, session
        self.emit, self.tick, self.streaming = emit, tick, streaming
        self.owned = {session: True}
        self.parts = {}
        self.final = {}   # each text part's whole text, in order (text.ended wins)
        self.last_part = None
        self.content = []
        self.answered = set()

    def owns(self, session):
        """Is SESSION this turn's, or a subagent session below it?"""
        seen = []
        while session and session not in self.owned and len(seen) < 8:
            seen.append(session)
            session = self.upstream.session_parent(session)
        verdict = bool(session) and self.owned.get(session, False)
        for item in seen:
            self.owned[item] = verdict
        return verdict

    def answer_permission(self, request):
        session, request_id = request.get("sessionID"), request.get("id")
        if not session or not request_id or request_id in self.answered or not self.owns(session):
            return
        self.answered.add(request_id)
        allow = self.config.permissions == "allow"
        body = {"decision": "once"} if allow else {"decision": "reject", "message": PERMISSION_REJECTED}
        LOG.info("%s permission %s on %s: %s", "allowing" if allow else "rejecting",
                 request.get("action"), ", ".join(request.get("resources") or []), session)
        if self.config.activity:
            verb = "allowed" if allow else "rejected"
            self.note(f"[permission {verb}: {request.get('action')} {' '.join(request.get('resources') or [])}]")
        try:
            self.upstream.request("POST", f"/api/session/{urllib.parse.quote(session)}/permission/"
                                  f"{urllib.parse.quote(request_id)}/reply", body)
        except UpstreamError as exc:
            LOG.warning("permission reply failed: %s", exc)

    def cancel_form(self, form):
        session, form_id = form.get("sessionID"), form.get("id")
        if not session or session == "global" or not form_id or form_id in self.answered or not self.owns(session):
            return
        self.answered.add(form_id)
        query = urllib.parse.urlencode({"message": QUESTION_CANCELLED})
        try:
            self.upstream.request("DELETE", f"/api/session/{urllib.parse.quote(session)}/form/"
                                  f"{urllib.parse.quote(form_id)}?{query}")
        except UpstreamError as exc:
            LOG.warning("form cancel failed: %s", exc)

    def note(self, text):
        self.emit("reasoning", "\n" + text + "\n")

    def text(self, key, value, full=False):
        previous = self.parts.get(key, "")
        self.final[key] = value if full else self.final.get(key, "") + value
        if full:
            if not value.startswith(previous) or value == previous:
                return
            delta = value[len(previous):]
        else:
            delta = value
        if not delta:
            return
        if key != self.last_part and self.content:
            self.emit("content", "\n\n")
            self.content.append("\n\n")
        self.last_part = key
        self.parts[key] = previous + delta
        self.content.append(delta)
        self.emit("content", delta)

    def reply(self):
        """The reply: what was streamed (the client keeps exactly that), or
        for a whole response each text part as OpenCode stored it."""
        if self.streaming:
            return "".join(self.content)
        return "\n\n".join(t for t in self.final.values() if t)

    def run(self, text):
        """Send TEXT and stream the reply; returns the reply."""
        conn, response = self.upstream.events()
        sink, stop = queue.Queue(), threading.Event()
        reader = threading.Thread(target=read_events, args=(response, sink, stop), daemon=True)
        reader.start()
        inbox, delivered, done = None, False, False
        try:
            admitted = self.upstream.request("POST", f"/api/session/{urllib.parse.quote(self.session)}/prompt",
                                             {"text": text, "delivery": "queue"})
            inbox = ((admitted or {}).get("data") or {}).get("id")
            if not inbox:
                raise UpstreamError(502, "OpenCode did not admit the prompt")
            # Asks raised before the subscription saw them.
            for path, handler in (("permission", self.answer_permission), ("form", self.cancel_form)):
                try:
                    pending = self.upstream.request("GET", f"/api/session/{urllib.parse.quote(self.session)}/{path}")
                except UpstreamError:
                    pending = None
                for item in (pending or {}).get("data") or []:
                    handler(item)
            deadline = time.monotonic() + self.config.turn_timeout
            last_out = time.monotonic()
            while True:
                if time.monotonic() > deadline:
                    raise TurnError(f"the turn took longer than {int(self.config.turn_timeout)} seconds")
                try:
                    event = sink.get(timeout=1)
                except queue.Empty:
                    if time.monotonic() - last_out >= KEEPALIVE_SECONDS:
                        self.tick()
                        last_out = time.monotonic()
                    continue
                if isinstance(event, Exception):
                    raise event
                kind = event.get("type")
                data = event.get("data") or {}
                if kind == "permission.asked":
                    self.answer_permission(data)
                    continue
                if kind == "form.created":
                    self.cancel_form(data.get("form") or {})
                    continue
                if data.get("sessionID") != self.session:
                    continue
                if not delivered:
                    # Until the prompt is delivered, the session's events are an
                    # earlier turn's (OpenCode's own run client does the same);
                    # session.text.ended restores any text of ours seen only in part.
                    delivered = kind == "session.inbox.delivered" and data.get("inboxID") == inbox
                    continue
                last_out = time.monotonic()
                if self.handle(event):
                    done = True
                    return self.reply()
        finally:
            stop.set()
            try:
                if conn.sock:
                    conn.sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()
            if inbox and not done:
                self.upstream.interrupt(self.session)

    def handle(self, event):
        """Apply one event of this turn; True when the turn is over."""
        kind = event.get("type")
        data = event.get("data") or {}
        key = (data.get("assistantMessageID"), data.get("ordinal"))
        if kind == "session.text.delta":
            self.text(key, data.get("delta") or "")
        elif kind == "session.text.ended":
            self.text(key, data.get("text") or "", full=True)
        elif kind == "session.reasoning.delta":
            if data.get("delta"):
                self.emit("reasoning", data["delta"])
        elif kind == "session.tool.input.started" and self.config.activity:
            self.note(f"[tool: {data.get('name') or 'tool'}]")
        elif kind == "session.tool.failed" and self.config.activity:
            error = data.get("error") or {}
            self.note(f"[tool failed: {error.get('message') if isinstance(error, dict) else error}]")
        elif kind == "session.execution.succeeded":
            return True
        elif kind == "session.execution.failed":
            error = data.get("error") or {}
            raise TurnError((error.get("message") if isinstance(error, dict) else str(error)) or "the session failed")
        elif kind == "session.execution.interrupted":
            raise TurnError(f"the session was interrupted ({data.get('reason') or 'unknown'})")
        return False


# --- the OpenAI side ----------------------------------------------------------------

class Proxy:
    def __init__(self, config):
        self.config = config
        self.upstream = Upstream(config)
        self.store = Store(config.state)
        self.turns = threading.BoundedSemaphore(config.max_turns)
        self.session_locks = {}
        self.locks_guard = threading.Lock()

    def session_lock(self, session):
        with self.locks_guard:
            return self.session_locks.setdefault(session, threading.Lock())

    def session_for(self, system, prior, user):
        """(session, prompt text, new?) for this request."""
        session = self.store.lookup(conversation_key(prior)) if prior else None
        if session:
            try:
                self.upstream.request("GET", f"/api/session/{urllib.parse.quote(session)}")
                return session, user, False
            except UpstreamError as exc:
                if exc.status != 404:
                    raise
                self.store.forget(session)
        title = "Open WebUI: " + " ".join(user.split())[:60]
        created = self.upstream.request("POST", "/api/session",
                                        {"title": title, "location": {"directory": self.config.directory}})
        session = ((created or {}).get("data") or {}).get("id")
        if not session:
            raise UpstreamError(502, "OpenCode did not create a session")
        return session, first_prompt(system, prior, user), True

    def complete(self, body, emit, tick, streaming=True):
        """Run one chat request; returns the reply content."""
        system, prior, user = split_messages(body.get("messages"))
        if not self.turns.acquire(blocking=False):
            raise UpstreamError(429, f"OpenCode is already running {self.config.max_turns} chat turns; try again shortly")
        try:
            session, text, new = self.session_for(system, prior, user)
            lock = self.session_lock(session)
            if not lock.acquire(timeout=5):
                raise UpstreamError(409, "this conversation's OpenCode session is busy with another request")
            try:
                LOG.info("%s session %s", "new" if new else "continuing", session)
                content = Turn(self.config, self.upstream, session, emit, tick, streaming).run(text)
            finally:
                lock.release()
            self.store.advance(session, conversation_key(prior + [("user", user), ("assistant", content)]))
            return content
        finally:
            self.turns.release()


def make_handler(proxy):
    config = proxy.config

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "opencode-api"

        def log_message(self, fmt, *args):
            LOG.debug("%s " + fmt, self.address_string(), *args)

        def send_json(self, status, value):
            payload = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def error(self, status, message, kind="invalid_request_error"):
            self.send_json(status, {"error": {"message": message, "type": kind}})

        def authorised(self):
            header = self.headers.get("Authorization", "")
            given = header[7:] if header.lower().startswith("bearer ") else ""
            if given and hmac.compare_digest(given.encode(), config.api_key.encode()):
                return True
            self.error(401, "Invalid or missing API key", "authentication_error")
            return False

        def do_GET(self):
            path = self.path.split("?", 1)[0].rstrip("/")
            if path == "/healthz":
                try:
                    proxy.upstream.request("GET", "/api/info", timeout=5)
                    self.send_json(200, {"ok": True})
                except UpstreamError as exc:
                    self.send_json(503, {"ok": False, "error": str(exc)})
                return
            if not self.authorised():
                return
            if path in ("/v1/models", "/models"):
                self.send_json(200, {"object": "list", "data": [
                    {"id": config.model, "object": "model", "created": 0, "owned_by": "opencode"}]})
            elif path in (f"/v1/models/{config.model}", f"/models/{config.model}"):
                self.send_json(200, {"id": config.model, "object": "model", "created": 0, "owned_by": "opencode"})
            else:
                self.error(404, "Not found")

        def do_POST(self):
            path = self.path.split("?", 1)[0].rstrip("/")
            if path not in ("/v1/chat/completions", "/chat/completions"):
                self.error(404, "Not found")
                return
            if not self.authorised():
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(body, dict):
                    raise ValueError("the body must be a JSON object")
                if body.get("model") not in (None, config.model):
                    raise LookupError(f"Unknown model {body.get('model')!r}; this endpoint serves {config.model!r}")
                split_messages(body.get("messages"))
            except LookupError as exc:
                self.error(404, str(exc))
                return
            except ValueError as exc:
                self.error(400, f"Invalid request: {exc}")
                return
            if body.get("stream"):
                self.stream(body)
            else:
                self.whole(body)

        def whole(self, body):
            started = int(time.time())
            try:
                content = proxy.complete(body, lambda kind, text: None, lambda: None, streaming=False)
            except UpstreamError as exc:
                self.error(exc.status if exc.status in (409, 429) else 502, str(exc), "upstream_error")
                return
            except TurnError as exc:
                self.error(502, f"OpenCode: {exc}", "upstream_error")
                return
            self.send_json(200, {
                "id": f"chatcmpl-{uuid.uuid4().hex}", "object": "chat.completion", "created": started,
                "model": config.model,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": content},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            })

        def stream(self, body):
            ident, started = f"chatcmpl-{uuid.uuid4().hex}", int(time.time())
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def write(raw):
                try:
                    self.wfile.write(raw)
                    self.wfile.flush()
                except OSError as exc:
                    raise ClientGone() from exc

            def chunk(delta, finish=None):
                value = {"id": ident, "object": "chat.completion.chunk", "created": started, "model": config.model,
                         "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                write(f"data: {json.dumps(value)}\n\n".encode())

            def emit(kind, text):
                chunk({"content": text} if kind == "content" else {"reasoning_content": text})

            try:
                chunk({"role": "assistant", "content": ""})
                try:
                    proxy.complete(body, emit, lambda: write(b": keepalive\n\n"))
                except (UpstreamError, TurnError) as exc:
                    chunk({"content": f"\n\n**OpenCode error:** {exc}"})
                chunk({}, "stop")
                write(b"data: [DONE]\n\n")
            except ClientGone:
                LOG.info("the client closed the connection; the turn was interrupted")

    return Handler


def main():
    logging.basicConfig(level=os.environ.get("OPENCODE_API_LOG_LEVEL", "INFO"),
                        format="%(levelname)s %(message)s", stream=sys.stderr)
    config = Config()
    proxy = Proxy(config)
    server = http.server.ThreadingHTTPServer((config.bind, config.port), make_handler(proxy))
    server.daemon_threads = True
    LOG.info("serving model %s on %s:%s for OpenCode at %s:%s (permissions: %s)", config.model, config.bind,
             config.port, config.upstream_host, config.upstream_port, config.permissions)
    server.serve_forever()


if __name__ == "__main__":
    main()
