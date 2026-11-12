#!/usr/bin/env python3
"""An OpenAI-compatible chat endpoint in front of DeepSeek Harness.

Harness has no /v1/chat/completions; programs drive it through its ACP server
(Agent Client Protocol: JSON-RPC over stdio, `dsh --profile acp`). This proxy
lets Open WebUI use Harness like Hermes, OpenClaw and OpenCode: it lists one
model (DSH_API_MODEL, "deepseek-harness") and turns each chat request into one
prompt in a Harness session.

The ACP server. Systemd starts `dsh --profile acp` as the deepseek-harness
user for each connection to DSH_API_ACP_SOCKET (deepseek-harness-acp.socket,
Accept=yes), with the same configuration, home, tools and workspace as the
Web UI; this proxy runs as its own account and keeps one connection. Sessions
are persisted in Harness's store, so they survive a restart of either side
(session/resume) and are kept until removed there. For tests,
DSH_API_ACP_COMMAND (a JSON list) starts the server on stdio instead.

Conversations. Open WebUI sends the whole history with every request and no
chat ID. The proxy keys each session by a hash of the conversation so far
(user and assistant turns, normalised). A request whose history is the last
state the proxy left a session in continues that session with its new user
message; any other request (a new chat, a regenerated or edited reply, a chat
started elsewhere) gets a new session, given the earlier turns as context.

A turn: session/prompt, and while it runs, the session's committed messages
(agent_message_chunk) are streamed as content; thoughts and tool activity as
reasoning_content. Harness's ACP sends whole committed messages, not token
deltas, so a reply arrives a message at a time. Permission requests are
answered by DSH_API_PERMISSIONS: allow (once) or reject. A client that goes
away, or a turn longer than DSH_API_TURN_TIMEOUT, cancels the prompt.

Configuration (environment): DSH_API_KEY (the bearer key clients must send),
DSH_API_BIND=0.0.0.0, DSH_API_PORT=3081, DSH_API_MODEL=deepseek-harness,
DSH_API_WORKSPACE=/var/lib/deepseek-harness/workspace,
DSH_API_PERMISSIONS=allow, DSH_API_TURN_TIMEOUT=3600, DSH_API_ACTIVITY=true,
DSH_API_STATE=/var/lib/deepseek-harness-api/sessions.json,
DSH_API_MAX_TURNS=4, DSH_API_IDLE=1800 (seconds before an unused session is
closed in the ACP server; it can be resumed later),
DSH_API_ACP_SOCKET=/run/deepseek-harness-acp/acp.sock. Standard library only.
"""
import hashlib
import hmac
import http.server
import json
import logging
import os
import queue
import re
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

LOG = logging.getLogger("deepseek-harness-api")

KEEPALIVE_SECONDS = 15
STATE_LIMIT = 5000
STARTUP_SECONDS = 120     # a new ACP server loads Harness before it answers
CANCEL_GRACE_SECONDS = 15  # how long a cancelled prompt may take to settle


class Config:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        self.api_key = env.get("DSH_API_KEY", "")
        self.bind = env.get("DSH_API_BIND", "0.0.0.0")
        self.port = int(env.get("DSH_API_PORT", "3081"))
        self.model = env.get("DSH_API_MODEL", "deepseek-harness")
        self.workspace = env.get("DSH_API_WORKSPACE", "/var/lib/deepseek-harness/workspace")
        self.permissions = env.get("DSH_API_PERMISSIONS", "allow")
        self.turn_timeout = float(env.get("DSH_API_TURN_TIMEOUT", "3600"))
        self.activity = env.get("DSH_API_ACTIVITY", "true") == "true"
        self.state = env.get("DSH_API_STATE", "/var/lib/deepseek-harness-api/sessions.json")
        self.max_turns = int(env.get("DSH_API_MAX_TURNS", "4"))
        self.idle = float(env.get("DSH_API_IDLE", "1800"))
        self.socket = env.get("DSH_API_ACP_SOCKET", "/run/deepseek-harness-acp/acp.sock")
        command = env.get("DSH_API_ACP_COMMAND", "")
        try:
            self.command = json.loads(command) if command else None
        except ValueError:
            self.command = None
        if command and not (isinstance(self.command, list) and self.command
                            and all(isinstance(a, str) for a in self.command)):
            raise SystemExit("DSH_API_ACP_COMMAND must be a JSON list of strings")
        if not self.api_key:
            raise SystemExit("DSH_API_KEY must be set")
        if self.permissions not in ("allow", "reject"):
            raise SystemExit("DSH_API_PERMISSIONS must be allow or reject")
        if not os.path.isabs(self.workspace):
            raise SystemExit("DSH_API_WORKSPACE must be an absolute path")


class UpstreamError(Exception):
    """Harness's ACP server could not be reached, or refused a request."""

    def __init__(self, status, message, code=None):
        super().__init__(message)
        self.status = status
        self.code = code


class TurnError(Exception):
    """The prompt failed, was cancelled or took too long."""


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
    """Which Harness session a conversation state belongs to, kept on disk.
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
                oldest = sorted(self.keys.items(), key=lambda kv: kv[1].get("at", 0))
                for old, _ in oldest[:len(self.keys) - STATE_LIMIT]:
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


# --- Harness's ACP server ------------------------------------------------------------

class Connection:
    """One ACP connection: newline-delimited JSON-RPC 2.0 over a unix socket,
    or over a child process's stdio (DSH_API_ACP_COMMAND, for tests)."""

    def __init__(self, config, on_request, on_notification):
        self.config = config
        self.on_request, self.on_notification = on_request, on_notification
        self.write_lock = threading.Lock()
        self.pending = {}
        self.pending_lock = threading.Lock()
        self.next_id = 0
        self.closed = threading.Event()
        self.process = self.sock = None
        try:
            if config.command:
                self.process = subprocess.Popen(config.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
                self.reader, self.writer = self.process.stdout, self.process.stdin
            else:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(config.socket)
                self.reader, self.writer = self.sock.makefile("rb"), self.sock.makefile("wb")
        except (OSError, AttributeError) as exc:
            if self.sock:
                self.sock.close()
            raise UpstreamError(502, f"DeepSeek Harness's ACP server is unreachable: {exc}") from exc
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for line in self.reader:
                try:
                    message = json.loads(line)
                except ValueError:
                    LOG.warning("ignoring a line from Harness that is not JSON")
                    continue
                if not isinstance(message, dict):
                    continue
                if "method" in message:
                    handler = self.on_request if "id" in message else self.on_notification
                    try:
                        handler(self, message)
                    except Exception:  # noqa: BLE001 - one bad message must not end the connection
                        LOG.exception("handling %s failed", message.get("method"))
                    continue
                with self.pending_lock:
                    waiter = self.pending.pop(message.get("id"), None)
                if waiter is not None:
                    waiter.put(message)
        except (OSError, ValueError):
            pass
        finally:
            self.close()

    def send(self, message):
        data = (json.dumps(message, separators=(",", ":")) + "\n").encode()
        try:
            with self.write_lock:
                self.writer.write(data)
                self.writer.flush()
        except (OSError, ValueError) as exc:
            self.close()
            raise UpstreamError(502, f"the connection to DeepSeek Harness failed: {exc}") from exc

    def request(self, method, params, timeout=60):
        if self.closed.is_set():
            raise UpstreamError(502, "the connection to DeepSeek Harness is closed")
        with self.pending_lock:
            self.next_id += 1
            ident = self.next_id
            waiter = self.pending[ident] = queue.Queue(maxsize=1)
        self.send({"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
        try:
            message = waiter.get(timeout=timeout)
        except queue.Empty:
            with self.pending_lock:
                self.pending.pop(ident, None)
            raise UpstreamError(504, f"DeepSeek Harness did not answer {method} within {int(timeout)} seconds") \
                from None
        if "error" in message:
            error = message.get("error") or {}
            if error.get("code") == -32099:
                raise UpstreamError(502, error.get("message") or "the connection to DeepSeek Harness closed")
            raise UpstreamError(502, error.get("message") or f"{method} failed", error.get("code"))
        return message.get("result")

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def respond(self, ident, result=None, error=None):
        message = {"jsonrpc": "2.0", "id": ident}
        message.update({"error": error} if error else {"result": result})
        try:
            self.send(message)
        except UpstreamError as exc:
            LOG.warning("could not answer Harness: %s", exc)

    def close(self):
        if self.closed.is_set():
            return
        self.closed.set()
        with self.pending_lock:
            waiters, self.pending = list(self.pending.values()), {}
        for waiter in waiters:
            waiter.put({"error": {"code": -32099, "message": "the connection to DeepSeek Harness closed"}})
        for stream in (self.writer, self.reader):
            try:
                stream.close()
            except (OSError, ValueError):
                pass
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        if self.process:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()


class Harness:
    """The ACP client: one connection, opened on demand and reopened when it
    drops; the sessions open in it; the turn each session's updates go to."""

    def __init__(self, config):
        self.config = config
        self.lock = threading.Lock()
        self.connection = None
        self.live = {}        # session -> last use (monotonic), for this connection
        self.turns = {}       # session -> the Turn receiving its updates

    def connect(self):
        with self.lock:
            if self.connection is not None and not self.connection.closed.is_set():
                return self.connection
            connection = Connection(self.config, self._request, self._notification)
            try:
                result = connection.request("initialize", {"protocolVersion": 1, "clientCapabilities": {}},
                                            timeout=STARTUP_SECONDS) or {}
            except UpstreamError:
                connection.close()
                raise
            if result.get("protocolVersion") != 1:
                connection.close()
                raise UpstreamError(502, f"DeepSeek Harness speaks ACP version {result.get('protocolVersion')!r}, "
                                         "not 1")
            self.connection, self.live = connection, {}
            LOG.info("connected to %s", (result.get("agentInfo") or {}).get("name", "the ACP server"))
            return connection

    def _notification(self, connection, message):
        if message.get("method") != "session/update":
            return
        params = message.get("params") or {}
        turn = self.turns.get(params.get("sessionId"))
        if turn is not None and connection is self.connection:
            turn.events.put(("update", params.get("update") or {}))

    def _request(self, connection, message):
        params = message.get("params") or {}
        if message.get("method") == "session/request_permission":
            turn = self.turns.get(params.get("sessionId"))
            if turn is not None and connection is self.connection:
                turn.events.put(("permission", (connection, message)))
            else:
                connection.respond(message["id"], {"outcome": {"outcome": "cancelled"}})
            return
        connection.respond(message["id"], error={"code": -32601, "message": f"{message.get('method')} is not "
                                                                            "supported by this client"})

    def new_session(self):
        connection = self.connect()
        result = connection.request("session/new", {"cwd": self.config.workspace, "mcpServers": []}) or {}
        session = result.get("sessionId")
        if not session:
            raise UpstreamError(502, "DeepSeek Harness did not create a session")
        with self.lock:
            self.live[session] = time.monotonic()
        return session

    def open_session(self, session):
        """Make SESSION usable on the current connection (session/resume when
        it is not open there); False when Harness no longer has it."""
        connection = self.connect()
        with self.lock:
            if session in self.live:
                self.live[session] = time.monotonic()
                return True
        try:
            connection.request("session/resume", {"sessionId": session, "cwd": self.config.workspace,
                                                  "mcpServers": []})
        except UpstreamError as exc:
            if exc.code == -32602:      # unknown, not resumable, or another workspace
                return False
            raise
        with self.lock:
            self.live[session] = time.monotonic()
        return True

    def cancel(self, session):
        connection = self.connection
        if connection is None:
            return
        try:
            connection.notify("session/cancel", {"sessionId": session})
        except UpstreamError as exc:
            LOG.warning("could not cancel %s: %s", session, exc)

    def close_idle(self, busy):
        """Close sessions unused for DSH_API_IDLE seconds in the ACP server (they
        stay in Harness's store and are resumed when their chat continues)."""
        now = time.monotonic()
        with self.lock:
            connection = self.connection
            idle = [s for s, at in self.live.items() if now - at > self.config.idle and s not in busy]
            for session in idle:
                self.live.pop(session, None)
        for session in idle:
            try:
                connection.request("session/close", {"sessionId": session}, timeout=60)
            except UpstreamError as exc:
                LOG.info("closing idle session %s: %s", session, exc)


class Turn:
    """One prompt in one session, from session/prompt to its stop reason."""

    def __init__(self, config, harness, session, emit, tick, streaming=True, gone=lambda: False):
        self.config, self.harness, self.session = config, harness, session
        self.emit, self.tick, self.streaming, self.gone = emit, tick, streaming, gone
        self.events = queue.Queue()
        self.messages = {}     # message id -> text, in order
        self.last_message = None
        self.content = []

    def note(self, text):
        self.emit("reasoning", "\n" + text + "\n")

    def text(self, message, value):
        if not value:
            return
        if message != self.last_message and self.content:
            self.emit("content", "\n\n")
            self.content.append("\n\n")
        self.last_message = message
        self.messages[message] = self.messages.get(message, "") + value
        self.content.append(value)
        self.emit("content", value)

    def reply(self):
        """The reply: what was streamed (the client keeps exactly that), or
        each committed message for a whole response."""
        if self.streaming:
            return "".join(self.content)
        return "\n\n".join(t for t in self.messages.values() if t)

    def answer(self, connection, message):
        params = message.get("params") or {}
        options = [o for o in params.get("options") or [] if isinstance(o, dict)]
        allow = self.config.permissions == "allow"
        wanted = ("allow_once", "allow_always") if allow else ("reject_once", "reject_always")
        choice = next((o for kind in wanted for o in options if o.get("kind") == kind), None)
        tool = params.get("toolCall") or {}
        title = tool.get("title") or tool.get("toolCallId") or "an action"
        if choice is None:
            outcome = {"outcome": "cancelled"}
            verb = "cancelled"
        else:
            outcome = {"outcome": "selected", "optionId": choice.get("optionId")}
            verb = "allowed" if allow else "rejected"
        LOG.info("%s permission for %s in %s", verb, title, self.session)
        if self.config.activity:
            self.note(f"[permission {verb}: {title}]")
        connection.respond(message["id"], {"outcome": outcome})

    def update(self, update):
        kind = update.get("sessionUpdate")
        content = update.get("content")
        if kind == "agent_message_chunk":
            if isinstance(content, dict) and content.get("type") == "text":
                self.text(update.get("messageId"), content.get("text") or "")
        elif kind == "agent_thought_chunk":
            if isinstance(content, dict) and content.get("type") == "text" and content.get("text"):
                self.emit("reasoning", content["text"])
        elif kind == "tool_call" and self.config.activity:
            self.note(f"[tool: {update.get('title') or 'tool'}]")
        elif kind == "tool_call_update" and update.get("status") == "failed" and self.config.activity:
            detail = ""
            for item in update.get("content") or []:
                inner = item.get("content") if isinstance(item, dict) else None
                if isinstance(inner, dict) and inner.get("type") == "text":
                    detail = inner.get("text") or ""
                    break
            self.note(f"[tool failed: {' '.join(detail.split())[:200] or update.get('toolCallId')}]")

    def run(self, text):
        """Send TEXT and stream the reply; returns the reply."""
        connection = self.harness.connect()
        self.harness.turns[self.session] = self

        def prompt():
            try:
                result = connection.request("session/prompt", {"sessionId": self.session,
                                                               "prompt": [{"type": "text", "text": text}]},
                                            timeout=self.config.turn_timeout + CANCEL_GRACE_SECONDS * 2)
                self.events.put(("result", result or {}))
            except UpstreamError as exc:
                self.events.put(("error", exc))

        sender = threading.Thread(target=prompt, daemon=True)
        sender.start()
        done = False
        try:
            deadline = time.monotonic() + self.config.turn_timeout
            last_out = time.monotonic()
            while True:
                if time.monotonic() > deadline:
                    raise TurnError(f"the turn took longer than {int(self.config.turn_timeout)} seconds")
                try:
                    kind, value = self.events.get(timeout=1)
                except queue.Empty:
                    if self.gone():
                        raise ClientGone() from None
                    if time.monotonic() - last_out >= KEEPALIVE_SECONDS:
                        self.tick()
                        last_out = time.monotonic()
                    continue
                last_out = time.monotonic()
                if kind == "update":
                    self.update(value)
                elif kind == "permission":
                    self.answer(*value)
                elif kind == "error":
                    done = True
                    raise TurnError(str(value))
                elif kind == "result":
                    done = True
                    # Updates sent before the prompt's answer are already queued.
                    while True:
                        try:
                            later_kind, later = self.events.get_nowait()
                        except queue.Empty:
                            break
                        if later_kind == "update":
                            self.update(later)
                    reason = value.get("stopReason")
                    if reason == "cancelled":
                        raise TurnError("the turn was cancelled")
                    if reason == "refusal":
                        raise TurnError("the model refused to continue")
                    if reason in ("max_tokens", "max_turn_requests") and self.config.activity:
                        self.note(f"[stopped: {reason.replace('_', ' ')}]")
                    if not self.content:
                        message = "(DeepSeek Harness finished the turn without a reply.)"
                        self.text("@empty", message)
                    return self.reply()
        finally:
            if not done:
                self.harness.cancel(self.session)
                # The next prompt in this session may start only once this one settles.
                sender.join(CANCEL_GRACE_SECONDS)
            self.harness.turns.pop(self.session, None)


# --- the OpenAI side ----------------------------------------------------------------

class Proxy:
    def __init__(self, config):
        self.config = config
        self.harness = Harness(config)
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
            if self.harness.open_session(session):
                return session, user, False
            LOG.info("session %s is gone from Harness; starting again", session)
            self.store.forget(session)
        return self.harness.new_session(), first_prompt(system, prior, user), True

    def complete(self, body, emit, tick, streaming=True, gone=lambda: False):
        """Run one chat request; returns the reply content."""
        system, prior, user = split_messages(body.get("messages"))
        if not self.turns.acquire(blocking=False):
            raise UpstreamError(429, f"DeepSeek Harness is already running {self.config.max_turns} chat turns; "
                                     "try again shortly")
        try:
            busy = set(self.harness.turns)
            self.harness.close_idle(busy)
            session, text, new = self.session_for(system, prior, user)
            lock = self.session_lock(session)
            if not lock.acquire(timeout=5):
                raise UpstreamError(409, "this conversation's Harness session is busy with another request")
            try:
                LOG.info("%s session %s", "new" if new else "continuing", session)
                content = Turn(self.config, self.harness, session, emit, tick, streaming, gone).run(text)
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
        server_version = "deepseek-harness-api"

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

        def client_gone(self):
            """Has the chat client closed its connection? (It sends nothing
            more after its request, so a readable socket means it hung up.)"""
            try:
                readable, _, _ = select.select([self.connection], [], [], 0)
                return bool(readable) and not self.connection.recv(1, socket.MSG_PEEK)
            except (OSError, ValueError):
                return True

        def authorised(self):
            header = self.headers.get("Authorization", "")
            given = header[7:] if header.lower().startswith("bearer ") else ""
            if given and hmac.compare_digest(given.encode(), config.api_key.encode()):
                return True
            # The request body was not read: do not parse it as the next request.
            self.close_connection = True
            self.error(401, "Invalid or missing API key", "authentication_error")
            return False

        def do_GET(self):
            path = self.path.split("?", 1)[0].rstrip("/")
            if path == "/healthz":
                try:
                    proxy.harness.connect()
                    self.send_json(200, {"ok": True})
                except UpstreamError as exc:
                    self.send_json(503, {"ok": False, "error": str(exc)})
                return
            if not self.authorised():
                return
            model = {"id": config.model, "object": "model", "created": 0, "owned_by": "deepseek-harness"}
            if path in ("/v1/models", "/models"):
                self.send_json(200, {"object": "list", "data": [model]})
            elif path in (f"/v1/models/{config.model}", f"/models/{config.model}"):
                self.send_json(200, model)
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
                content = proxy.complete(body, lambda kind, text: None, lambda: None, streaming=False,
                                         gone=self.client_gone)
            except ClientGone:
                LOG.info("the client closed the connection; the turn was cancelled")
                self.close_connection = True
                return
            except UpstreamError as exc:
                self.error(exc.status if exc.status in (409, 429) else 502, str(exc), "upstream_error")
                return
            except TurnError as exc:
                self.error(502, f"DeepSeek Harness: {exc}", "upstream_error")
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
                    proxy.complete(body, emit, lambda: write(b": keepalive\n\n"), gone=self.client_gone)
                except (UpstreamError, TurnError) as exc:
                    chunk({"content": f"\n\n**DeepSeek Harness error:** {exc}"})
                chunk({}, "stop")
                write(b"data: [DONE]\n\n")
            except ClientGone:
                LOG.info("the client closed the connection; the turn was cancelled")

    return Handler


def main():
    logging.basicConfig(level=os.environ.get("DSH_API_LOG_LEVEL", "INFO"),
                        format="%(levelname)s %(message)s", stream=sys.stderr)
    config = Config()
    proxy = Proxy(config)
    server = http.server.ThreadingHTTPServer((config.bind, config.port), make_handler(proxy))
    server.daemon_threads = True
    LOG.info("serving model %s on %s:%s for DeepSeek Harness at %s (permissions: %s)", config.model,
             config.bind, config.port, config.socket if not config.command else config.command[0],
             config.permissions)
    server.serve_forever()


if __name__ == "__main__":
    main()
