"""The OpenAI-compatible proxy against a fake OpenCode server (sessions,
prompts, the SSE event stream, permissions, forms, interrupts).

Run: python3 targets/opencode/test-openai-proxy.py (stdlib only).
"""
import base64
import http.client
import http.server
import importlib.util
import json
import pathlib
import queue
import socket
import tempfile
import threading
import time
import unittest
import urllib.parse

SCRIPT = pathlib.Path(__file__).with_name("openai-proxy.py")
SPEC = importlib.util.spec_from_file_location("opencode_openai_proxy", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

PASSWORD = "server-password"
API_KEY = "proxy-key-0123456789"


class FakeOpenCode:
    """The parts of OpenCode's server API the proxy uses."""

    def __init__(self):
        self.sessions = {}
        self.prompts = []
        self.replies = []
        self.cancelled = []
        self.interrupts = []
        self.subscribers = []
        self.subscriptions = []
        self.pending_permissions = {}
        self.lock = threading.Lock()
        self.counter = 0
        # script(session, inbox, text) -> events to send after the prompt.
        self.script = lambda session, inbox, text: reply_events(session, ["Hello", " there"])
        self.hold = None      # an Event the script waits for before its events

    def new_id(self, prefix):
        with self.lock:
            self.counter += 1
            return f"{prefix}_{self.counter:04d}"

    def publish(self, event):
        for sink in list(self.subscribers):
            sink.put(event)



def event(kind, session, **data):
    return {"type": kind, "data": {"sessionID": session, **data}}


def reply_events(session, deltas, ended=None, message="msg_reply", inbox=None, extra=()):
    events = [{"type": "session.inbox.delivered", "data": {"sessionID": session, "inboxID": inbox or "@inbox"}}]
    events += list(extra)
    events += [event("session.text.delta", session, assistantMessageID=message, ordinal=0, delta=d) for d in deltas]
    events.append(event("session.text.ended", session, assistantMessageID=message, ordinal=0,
                        text=ended if ended is not None else "".join(deltas)))
    events.append(event("session.execution.succeeded", session))
    return events


def make_handler(fake):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def reply(self, status, value=None):
            payload = json.dumps(value).encode() if value is not None else b""
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def authorised(self):
            expected = "Basic " + base64.b64encode(f"opencode:{PASSWORD}".encode()).decode()
            if self.headers.get("Authorization") != expected:
                self.reply(401, {"_tag": "UnauthorizedError", "message": "Authentication required"})
                return False
            return True

        def body(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            return json.loads(raw) if raw else None

        def do_GET(self):
            if not self.authorised():
                return
            url = urllib.parse.urlsplit(self.path)
            parts = url.path.strip("/").split("/")
            if url.path == "/api/info":
                self.reply(200, {"version": "2.2.7"})
            elif url.path == "/api/event":
                fake.subscriptions.append(urllib.parse.parse_qs(url.query).get("types", []))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                sink = queue.Queue()
                fake.subscribers.append(sink)
                try:
                    self.wfile.write(b'data: {"id":"evt_c","type":"server.connected","data":{}}\n\n')
                    self.wfile.flush()
                    while True:
                        try:
                            item = sink.get(timeout=0.2)
                        except queue.Empty:
                            self.wfile.write(b": heartbeat\n\n")
                            self.wfile.flush()
                            continue
                        self.wfile.write(f"data: {json.dumps(item)}\n\n".encode())
                        self.wfile.flush()
                except OSError:
                    pass
                finally:
                    fake.subscribers.remove(sink)
            elif len(parts) == 3 and parts[:2] == ["api", "session"]:
                session = fake.sessions.get(parts[2])
                self.reply(200, {"data": session}) if session else self.reply(404, {"message": "Session not found"})
            elif len(parts) == 4 and parts[3] == "permission":
                self.reply(200, {"data": fake.pending_permissions.pop(parts[2], [])})
            elif len(parts) == 4 and parts[3] == "form":
                self.reply(200, {"data": []})
            else:
                self.reply(404, {"message": "Not found"})

        def do_POST(self):
            if not self.authorised():
                return
            parts = urllib.parse.urlsplit(self.path).path.strip("/").split("/")
            body = self.body()
            if parts == ["api", "session"]:
                session = fake.new_id("ses")
                fake.sessions[session] = {"id": session, "title": body.get("title"),
                                          "location": body.get("location"), "parentID": body.get("parentID")}
                self.reply(200, {"data": fake.sessions[session]})
            elif len(parts) == 4 and parts[3] == "prompt":
                session = parts[2]
                if session not in fake.sessions:
                    self.reply(404, {"message": "Session not found"})
                    return
                inbox = fake.new_id("msg")
                fake.prompts.append({"session": session, "inbox": inbox, **body})
                self.reply(200, {"data": {"id": inbox, "sessionID": session}})

                def script():
                    events = fake.script(session, inbox, body["text"])
                    for item in events:
                        if isinstance(item, dict) and item.get("data", {}).get("inboxID") == "@inbox":
                            item["data"]["inboxID"] = inbox

                    def run():
                        if fake.hold is not None:
                            fake.hold.wait(5)
                        for item in events:
                            if isinstance(item, (int, float)):
                                time.sleep(item)
                                continue
                            fake.publish(item)
                    run()
                threading.Thread(target=script, daemon=True).start()
            elif len(parts) == 6 and parts[3] == "permission" and parts[5] == "reply":
                fake.replies.append({"session": parts[2], "request": parts[4], **body})
                self.reply(204)
            elif len(parts) == 4 and parts[3] == "interrupt":
                fake.interrupts.append(parts[2])
                fake.publish(event("session.execution.interrupted", parts[2], reason="user"))
                self.reply(200, {"interrupted": True})
            else:
                self.reply(404, {"message": "Not found"})

        def do_DELETE(self):
            if not self.authorised():
                return
            url = urllib.parse.urlsplit(self.path)
            parts = url.path.strip("/").split("/")
            if len(parts) == 5 and parts[3] == "form":
                fake.cancelled.append({"session": parts[2], "form": parts[4],
                                       "message": urllib.parse.parse_qs(url.query).get("message", [""])[0]})
                self.reply(204)
            else:
                self.reply(404, {"message": "Not found"})

    return Handler


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeOpenCode()
        self.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.fake))
        self.upstream.daemon_threads = True
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()
        self.temp = tempfile.TemporaryDirectory()
        self.start_proxy()

    def start_proxy(self, **env):
        settings = {"OPENCODE_PASSWORD": PASSWORD, "OPENCODE_API_KEY": API_KEY,
                    "OPENCODE_PORT": str(self.upstream.server_port), "OPENCODE_API_PORT": "0",
                    "OPENCODE_API_BIND": "127.0.0.1", "OPENCODE_API_DIRECTORY": "/home/opencode/workspace",
                    "OPENCODE_API_STATE": str(pathlib.Path(self.temp.name, "sessions.json")),
                    "OPENCODE_API_TURN_TIMEOUT": "10", **env}
        self.config = MODULE.Config(settings)
        self.proxy = MODULE.Proxy(self.config)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MODULE.make_handler(self.proxy))
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop_proxy(self):
        self.server.shutdown()
        self.server.server_close()

    def tearDown(self):
        self.stop_proxy()
        self.upstream.shutdown()
        self.upstream.server_close()
        self.temp.cleanup()

    def call(self, method, path, body=None, key=API_KEY, raw=False):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=20)
        headers = {"Content-Type": "application/json"}
        if key:
            headers["Authorization"] = f"Bearer {key}"
        conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
        response = conn.getresponse()
        data = response.read()
        conn.close()
        if raw:
            return response.status, data.decode()
        return response.status, json.loads(data) if data else None

    def chat(self, messages, **extra):
        return self.call("POST", "/v1/chat/completions", {"model": "opencode", "messages": messages, **extra})

    def stream(self, messages):
        status, text = self.call("POST", "/v1/chat/completions",
                                 {"model": "opencode", "messages": messages, "stream": True}, raw=True)
        self.assertEqual(status, 200)
        chunks = [json.loads(line[6:]) for line in text.splitlines()
                  if line.startswith("data: ") and line != "data: [DONE]"]
        self.assertTrue(text.rstrip().endswith("data: [DONE]"), text)
        content = "".join(c["choices"][0]["delta"].get("content", "") for c in chunks)
        reasoning = "".join(c["choices"][0]["delta"].get("reasoning_content", "") for c in chunks)
        return chunks, content, reasoning

    # --- models and requests -------------------------------------------------

    def test_models_need_the_key(self):
        self.assertEqual(self.call("GET", "/v1/models", key=None)[0], 401)
        self.assertEqual(self.call("GET", "/v1/models", key="wrong")[0], 401)
        status, body = self.call("GET", "/v1/models")
        self.assertEqual(status, 200)
        self.assertEqual([m["id"] for m in body["data"]], ["opencode"])
        self.assertEqual(self.call("POST", "/v1/chat/completions", {"messages": []}, key=None)[0], 401)

    def test_health_follows_opencode(self):
        self.assertEqual(self.call("GET", "/healthz", key=None), (200, {"ok": True}))
        self.upstream.shutdown()
        self.upstream.server_close()
        status, body = self.call("GET", "/healthz", key=None)
        self.assertEqual(status, 503)
        self.assertFalse(body["ok"])
        self.upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.fake))
        threading.Thread(target=self.upstream.serve_forever, daemon=True).start()

    def test_bad_requests(self):
        self.assertEqual(self.chat([{"role": "user", "content": "hi"}], model="other")[0], 404)
        self.assertEqual(self.chat([])[0], 400)
        self.assertEqual(self.chat([{"role": "assistant", "content": "only me"}])[0], 400)
        self.assertEqual(self.chat([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "x"}])[0], 400)
        self.assertEqual(self.fake.prompts, [])

    # --- conversations ---------------------------------------------------------

    def test_a_new_chat_opens_a_session_in_the_workspace(self):
        status, body = self.chat([{"role": "user", "content": "hi"}])
        self.assertEqual(status, 200, body)
        self.assertEqual(body["choices"][0]["message"], {"role": "assistant", "content": "Hello there"})
        self.assertEqual(len(self.fake.sessions), 1)
        session = next(iter(self.fake.sessions.values()))
        self.assertEqual(session["location"], {"directory": "/home/opencode/workspace"})
        self.assertTrue(session["title"].startswith("Open WebUI: hi"))
        self.assertEqual(self.fake.prompts[0]["text"], "hi")
        self.assertEqual(self.fake.prompts[0]["delivery"], "queue")
        self.assertIn("session.text.delta", self.fake.subscriptions[0])

    def test_the_next_turn_continues_the_session_as_open_webui_sends_it_back(self):
        self.chat([{"role": "user", "content": "hi"}])
        # Open WebUI keeps reasoning in a details block and may reflow white space.
        history = [{"role": "system", "content": "Be brief."},
                   {"role": "user", "content": [{"type": "text", "text": "hi"}]},
                   {"role": "assistant", "content": '<details type="reasoning" done="true">\nthought\n</details>\nHello  there\n'},
                   {"role": "user", "content": "and now?"}]
        status, body = self.chat(history)
        self.assertEqual(status, 200, body)
        self.assertEqual(len(self.fake.sessions), 1)
        self.assertEqual([p["session"] for p in self.fake.prompts], ["ses_0001", "ses_0001"])
        self.assertEqual(self.fake.prompts[1]["text"], "and now?")

    def test_a_regenerated_reply_gets_a_new_session_with_the_earlier_turns(self):
        self.chat([{"role": "user", "content": "first"}])
        self.chat([{"role": "user", "content": "first"}, {"role": "assistant", "content": "Hello there"},
                   {"role": "user", "content": "second"}])
        # Regenerate the second reply: the same history again, but its session has moved on.
        status, _ = self.chat([{"role": "system", "content": "Be brief."},
                               {"role": "user", "content": "first"}, {"role": "assistant", "content": "Hello there"},
                               {"role": "user", "content": "second"}])
        self.assertEqual(status, 200)
        self.assertEqual(len(self.fake.sessions), 2)
        text = self.fake.prompts[2]["text"]
        self.assertIn("Instructions from the chat client:\nBe brief.", text)
        self.assertIn("User: first", text)
        self.assertIn("Assistant: Hello there", text)
        self.assertTrue(text.endswith("Current message:\nsecond"))

    def test_a_chat_started_elsewhere_or_a_deleted_session_starts_again(self):
        self.chat([{"role": "user", "content": "q"}])
        self.fake.sessions.clear()
        status, _ = self.chat([{"role": "user", "content": "q"}, {"role": "assistant", "content": "Hello there"},
                               {"role": "user", "content": "more"}])
        self.assertEqual(status, 200)
        self.assertEqual(len(self.fake.sessions), 1)
        self.assertIn("User: q", self.fake.prompts[1]["text"])

    def test_the_mapping_survives_a_restart(self):
        self.chat([{"role": "user", "content": "hi"}])
        self.stop_proxy()
        self.start_proxy()
        self.chat([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "Hello there"},
                   {"role": "user", "content": "again"}])
        self.assertEqual(len(self.fake.sessions), 1)

    # --- streaming --------------------------------------------------------------

    def test_streaming_deltas_parts_tools_and_missed_text(self):
        def script(session, inbox, _text):
            tool = event("session.tool.input.started", session, assistantMessageID="m1", id="t1", name="bash")
            return [
                event("session.text.delta", session, assistantMessageID="old", ordinal=0, delta="before"),
                {"type": "session.inbox.delivered", "data": {"sessionID": session, "inboxID": inbox}},
                event("session.reasoning.delta", session, assistantMessageID="m1", ordinal=0, delta="thinking"),
                event("session.text.delta", session, assistantMessageID="m1", ordinal=0, delta="Let me "),
                tool,
                # "look." was missed live; text.ended carries the whole part.
                event("session.text.ended", session, assistantMessageID="m1", ordinal=0, text="Let me look."),
                event("session.text.delta", session, assistantMessageID="m2", ordinal=0, delta="Done."),
                event("session.text.delta", session, assistantMessageID="other", ordinal=0, delta="x") | {
                    "data": {"sessionID": "ses_other", "assistantMessageID": "z", "ordinal": 0, "delta": "noise"}},
                event("session.execution.succeeded", session),
            ]
        self.fake.script = script
        chunks, content, reasoning = self.stream([{"role": "user", "content": "go"}])
        self.assertEqual(chunks[0]["choices"][0]["delta"]["role"], "assistant")
        self.assertEqual(chunks[-1]["choices"][0]["finish_reason"], "stop")
        self.assertEqual(content, "Let me look.\n\nDone.")
        self.assertIn("thinking", reasoning)
        self.assertIn("[tool: bash]", reasoning)
        # The stored state is the content that was sent, so the next turn continues.
        self.fake.script = lambda s, i, t: reply_events(s, ["ok"])
        self.chat([{"role": "user", "content": "go"}, {"role": "assistant", "content": content},
                   {"role": "user", "content": "next"}])
        self.assertEqual(len(self.fake.sessions), 1)

    def test_text_seen_only_in_part_is_restored_from_its_end(self):
        # A delta that raced the delivery notice is dropped live; text.ended has it.
        self.fake.script = lambda s, i, t: [
            event("session.text.delta", s, assistantMessageID="m", ordinal=0, delta="early "),
            {"type": "session.inbox.delivered", "data": {"sessionID": s, "inboxID": i}},
            event("session.text.delta", s, assistantMessageID="m", ordinal=0, delta="late"),
            event("session.text.ended", s, assistantMessageID="m", ordinal=0, text="early late"),
            event("session.execution.succeeded", s)]
        self.assertEqual(self.chat([{"role": "user", "content": "x"}])[1]["choices"][0]["message"]["content"],
                         "early late")

    def test_an_earlier_execution_ending_is_not_this_turn(self):
        self.fake.script = lambda s, i, t: [
            event("session.execution.succeeded", s),
            {"type": "session.inbox.delivered", "data": {"sessionID": s, "inboxID": i}},
            event("session.text.delta", s, assistantMessageID="m", ordinal=0, delta="mine"),
            event("session.execution.succeeded", s)]
        self.assertEqual(self.chat([{"role": "user", "content": "x"}])[1]["choices"][0]["message"]["content"], "mine")

    # --- asks, failures, disconnects ------------------------------------------------

    def test_permissions_in_the_session_and_its_subagents_are_allowed_once(self):
        def script(session, inbox, _text):
            self.fake.sessions["ses_child"] = {"id": "ses_child", "parentID": session}
            self.fake.sessions["ses_stranger"] = {"id": "ses_stranger"}
            asks = [{"type": "permission.asked", "data": {"id": "per_1", "sessionID": session, "action": "shell",
                                                          "resources": ["ls"]}},
                    {"type": "permission.asked", "data": {"id": "per_2", "sessionID": "ses_child", "action": "edit",
                                                          "resources": ["a.py"]}},
                    {"type": "permission.asked", "data": {"id": "per_3", "sessionID": "ses_stranger", "action": "shell",
                                                          "resources": ["rm"]}}]
            return reply_events(session, ["ok"], extra=asks + [0.2])
        self.fake.script = script
        self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(sorted((r["request"], r["decision"]) for r in self.fake.replies),
                         [("per_1", "once"), ("per_2", "once")])

    def test_permissions_can_be_rejected_and_pending_ones_are_answered(self):
        self.stop_proxy()
        self.start_proxy(OPENCODE_API_PERMISSIONS="reject")
        self.fake.pending_permissions["ses_0001"] = [{"id": "per_9", "sessionID": "ses_0001", "action": "shell",
                                                      "resources": ["make"]}]
        self.fake.hold = threading.Event()
        threading.Timer(0.5, self.fake.hold.set).start()
        self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(len(self.fake.replies), 1)
        self.assertEqual(self.fake.replies[0]["decision"], "reject")
        self.assertIn("rejected", self.fake.replies[0]["message"])

    def test_questions_are_cancelled(self):
        self.fake.script = lambda s, i, t: reply_events(s, ["ok"], extra=[
            {"type": "form.created", "data": {"form": {"id": "frm_1", "sessionID": s, "title": "Which?"}}},
            {"type": "form.created", "data": {"form": {"id": "frm_2", "sessionID": "global", "title": "MCP"}}}, 0.2])
        self.chat([{"role": "user", "content": "x"}])
        self.assertEqual([c["form"] for c in self.fake.cancelled], ["frm_1"])
        self.assertIn("cannot ask the user questions", self.fake.cancelled[0]["message"])

    def test_a_failed_execution_is_reported(self):
        failure = lambda s, i, t: [  # noqa: E731
            {"type": "session.inbox.delivered", "data": {"sessionID": s, "inboxID": i}},
            event("session.text.delta", s, assistantMessageID="m", ordinal=0, delta="partial"),
            event("session.execution.failed", s, error={"type": "provider", "message": "model unavailable"})]
        self.fake.script = failure
        status, body = self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(status, 502)
        self.assertIn("model unavailable", body["error"]["message"])
        _, content, _ = self.stream([{"role": "user", "content": "x"}])
        self.assertIn("partial", content)
        self.assertIn("**OpenCode error:** model unavailable", content)
        # A failed turn is not a state to continue from.
        self.fake.script = lambda s, i, t: reply_events(s, ["fine"])
        self.chat([{"role": "user", "content": "x"}, {"role": "assistant", "content": "partial"},
                   {"role": "user", "content": "retry"}])
        self.assertEqual(len(self.fake.sessions), 3)

    def test_a_client_that_goes_away_interrupts_the_turn(self):
        self.fake.script = lambda s, i, t: [
            {"type": "session.inbox.delivered", "data": {"sessionID": s, "inboxID": i}},
            event("session.text.delta", s, assistantMessageID="m", ordinal=0, delta="working"), 30]
        payload = json.dumps({"model": "opencode", "stream": True,
                              "messages": [{"role": "user", "content": "long job"}]}).encode()
        client = socket.create_connection(("127.0.0.1", self.server.server_port), timeout=10)
        client.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                       + f"Authorization: Bearer {API_KEY}\r\nContent-Length: {len(payload)}\r\n\r\n".encode()
                       + payload)
        seen = b""
        while b"working" not in seen:
            seen += client.recv(4096)
        client.close()
        for _ in range(100):
            if self.fake.interrupts:
                break
            time.sleep(0.1)
        self.assertEqual(self.fake.interrupts, ["ses_0001"])

    def test_a_turn_that_takes_too_long_is_interrupted(self):
        self.stop_proxy()
        self.start_proxy(OPENCODE_API_TURN_TIMEOUT="1")
        self.fake.script = lambda s, i, t: [
            {"type": "session.inbox.delivered", "data": {"sessionID": s, "inboxID": i}}, 30]
        status, body = self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(status, 502)
        self.assertIn("longer than 1 seconds", body["error"]["message"])
        self.assertEqual(self.fake.interrupts, ["ses_0001"])

    def test_turns_are_limited(self):
        self.stop_proxy()
        self.start_proxy(OPENCODE_API_MAX_TURNS="1")
        self.fake.hold = threading.Event()
        results = []
        first = threading.Thread(target=lambda: results.append(self.chat([{"role": "user", "content": "a"}])[0]))
        first.start()
        time.sleep(0.5)
        status, body = self.chat([{"role": "user", "content": "b"}])
        self.fake.hold.set()
        first.join()
        self.assertEqual(status, 429)
        self.assertEqual(results, [200])

    def test_wrong_server_password_is_an_upstream_error(self):
        self.stop_proxy()
        self.start_proxy(OPENCODE_PASSWORD="wrong")
        status, body = self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(status, 502)
        self.assertEqual(self.fake.prompts, [])

    # --- helpers ------------------------------------------------------------------

    def test_helpers(self):
        self.assertEqual(MODULE.normalise('<details type="reasoning">a\nb</details> x  \n y <think>z</think>'), "x y")
        self.assertEqual(MODULE.conversation_key([("user", "a b")]), MODULE.conversation_key([("user", " a\n b ")]))
        self.assertNotEqual(MODULE.conversation_key([("user", "a")]), MODULE.conversation_key([("assistant", "a")]))
        system, prior, user = MODULE.split_messages([
            {"role": "system", "content": "S"}, {"role": "user", "content": "u1"},
            {"role": "assistant", "content": ""}, {"role": "tool", "content": "t"},
            {"role": "user", "content": [{"type": "text", "text": "u2"}, {"type": "image_url", "image_url": {}}]}])
        self.assertEqual((system, prior, user), ("S", [("user", "u1")], "u2"))
        self.assertEqual(MODULE.first_prompt("", [], "hi"), "hi")
        with self.assertRaises(SystemExit):
            MODULE.Config({"OPENCODE_PASSWORD": "p", "OPENCODE_API_KEY": "k", "OPENCODE_API_PERMISSIONS": "maybe"})
        with self.assertRaises(SystemExit):
            MODULE.Config({"OPENCODE_PASSWORD": "p"})


if __name__ == "__main__":
    unittest.main()
