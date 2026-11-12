"""The OpenAI-compatible proxy against a fake DeepSeek Harness ACP server
(initialize, session/new, resume, close, prompt, cancel, session/update and
session/request_permission), run as a child process on stdio like the real
`dsh --profile acp`.

Run: python3 targets/deepseek-harness/test-openai-proxy.py (stdlib only).
The fake server is this file with --fake-acp; it keeps its sessions, its
call log and the per-prompt scripts the tests give it in FAKE_ACP_DIR.
"""
import http.client
import http.server
import importlib.util
import json
import os
import pathlib
import queue
import socket
import sys
import tempfile
import threading
import time
import unittest

SCRIPT = pathlib.Path(__file__).with_name("openai-proxy.py")
API_KEY = "proxy-key-0123456789"
WORKSPACE = "/var/lib/deepseek-harness/workspace"


# --- the fake ACP server (a child process) -------------------------------------------

def fake_acp(directory):
    """Serve ACP on stdio. Prompts follow the steps in DIR/script.json:
    {"queue": [[step, ...], ...]} (one list per prompt, consumed in order),
    else the default reply. Steps: {"message": text, "id": message id},
    {"thought": text}, {"update": raw update}, {"other_session": update},
    {"tool": title}, {"tool_failed": text}, {"sleep": seconds},
    {"permission": options}, {"error": [code, message]}, {"stop": reason},
    {"exit": true} (the process dies)."""
    directory = pathlib.Path(directory)
    store = directory / "sessions.json"
    log_lock, write_lock = threading.Lock(), threading.Lock()
    waiters, cancels = {}, {}

    def log(**entry):
        with log_lock, open(directory / "calls.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")

    def send(message):
        with write_lock:
            sys.stdout.write(json.dumps(message) + "\n")
            sys.stdout.flush()

    def sessions():
        try:
            return json.loads(store.read_text())
        except (OSError, ValueError):
            return {}

    def next_steps():
        path = directory / "script.json"
        try:
            script = json.loads(path.read_text())
        except (OSError, ValueError):
            script = {}
        if script.get("queue"):
            steps = script["queue"].pop(0)
            path.write_text(json.dumps(script))
            return steps
        return script.get("default") or [{"message": "Hello there"}]

    def update(session, value):
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session, "update": value}})

    def prompt(ident, params):
        session = params.get("sessionId")
        if session not in sessions():
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32602, "message": f"unknown session: {session}"}})
            return
        cancelled = cancels[session] = threading.Event()
        log(method="session/prompt", session=session, text=params["prompt"][0]["text"])
        message = 0
        for step in next_steps():
            if cancelled.is_set():
                break
            if "message" in step:
                message += 1
                update(session, {"sessionUpdate": "agent_message_chunk", "messageId": step.get("id", f"m{message}"),
                                 "content": {"type": "text", "text": step["message"]}})
            elif "thought" in step:
                update(session, {"sessionUpdate": "agent_thought_chunk", "messageId": "t",
                                 "content": {"type": "text", "text": step["thought"]}})
            elif "update" in step:
                update(session, step["update"])
            elif "other_session" in step:
                update("ses-stranger", step["other_session"])
            elif "tool" in step:
                update(session, {"sessionUpdate": "tool_call", "toolCallId": "call_1", "title": step["tool"],
                                 "kind": "other", "status": "in_progress", "rawInput": {}})
            elif "tool_failed" in step:
                update(session, {"sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "failed",
                                 "content": [{"type": "content", "content": {"type": "text",
                                                                             "text": step["tool_failed"]}}]})
            elif "sleep" in step:
                cancelled.wait(step["sleep"])
            elif "permission" in step:
                request = f"perm-{time.monotonic_ns()}"
                waiter = waiters[request] = queue.Queue()
                send({"jsonrpc": "2.0", "id": request, "method": "session/request_permission",
                      "params": {"sessionId": step.get("session", session), "toolCall": {"toolCallId": "call_1",
                                                                                        "title": "bash"},
                                 "options": step["permission"]}})
                log(method="permission", answer=waiter.get(timeout=10))
            elif "error" in step:
                code, text = step["error"]
                send({"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": text}})
                return
            elif "exit" in step:
                os._exit(1)
            elif "stop" in step:
                send({"jsonrpc": "2.0", "id": ident, "result": {"stopReason": step["stop"]}})
                return
        send({"jsonrpc": "2.0", "id": ident, "result": {"stopReason": "cancelled" if cancelled.is_set() else
                                                        "end_turn"}})

    for line in sys.stdin:
        message = json.loads(line)
        method, ident, params = message.get("method"), message.get("id"), message.get("params") or {}
        if method is None:
            waiter = waiters.pop(ident, None)
            if waiter:
                waiter.put(message.get("result") or message.get("error"))
            continue
        if method != "session/prompt":
            log(method=method, params=params)
        if method == "initialize":
            version = int(os.environ.get("FAKE_ACP_VERSION", "1"))
            send({"jsonrpc": "2.0", "id": ident, "result": {"protocolVersion": version,
                                                            "agentInfo": {"name": "fake-acp"}}})
        elif method == "session/new":
            known = sessions()
            session = f"ses-{len(known) + 1:04d}"
            known[session] = {"cwd": params.get("cwd")}
            store.write_text(json.dumps(known))
            send({"jsonrpc": "2.0", "id": ident, "result": {"sessionId": session}})
        elif method == "session/resume":
            if params.get("sessionId") in sessions():
                send({"jsonrpc": "2.0", "id": ident, "result": {}})
            else:
                send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32602,
                                                               "message": "session is not resumable"}})
        elif method == "session/close":
            send({"jsonrpc": "2.0", "id": ident, "result": {}})
        elif method == "session/cancel":
            event = cancels.get(params.get("sessionId"))
            if event:
                event.set()
        elif method == "session/prompt":
            threading.Thread(target=prompt, args=(ident, params), daemon=True).start()
        else:
            send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "not found"}})


if len(sys.argv) > 2 and sys.argv[1] == "--fake-acp":
    fake_acp(sys.argv[2])
    sys.exit(0)


SPEC = importlib.util.spec_from_file_location("dsh_openai_proxy", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.acp = pathlib.Path(self.temp.name, "acp")
        self.acp.mkdir()
        self.start_proxy()

    def start_proxy(self, **env):
        command = [sys.executable, str(pathlib.Path(__file__).resolve()), "--fake-acp", str(self.acp)]
        settings = {"DSH_API_KEY": API_KEY, "DSH_API_PORT": "0", "DSH_API_BIND": "127.0.0.1",
                    "DSH_API_WORKSPACE": WORKSPACE, "DSH_API_ACP_COMMAND": json.dumps(command),
                    "DSH_API_STATE": str(pathlib.Path(self.temp.name, "sessions.json")),
                    "DSH_API_TURN_TIMEOUT": "10", **env}
        self.config = MODULE.Config(settings)
        self.proxy = MODULE.Proxy(self.config)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MODULE.make_handler(self.proxy))
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop_proxy(self):
        self.server.shutdown()
        self.server.server_close()
        connection = self.proxy.harness.connection
        if connection is not None:
            connection.close()

    def tearDown(self):
        self.stop_proxy()
        self.temp.cleanup()

    # --- the fake server's state -----------------------------------------------------

    def script(self, *prompts, default=None):
        value = {"queue": [list(p) for p in prompts]}
        if default is not None:
            value["default"] = default
        (self.acp / "script.json").write_text(json.dumps(value))

    def calls(self, method=None):
        try:
            lines = (self.acp / "calls.jsonl").read_text().splitlines()
        except OSError:
            return []
        entries = [json.loads(line) for line in lines]
        return [e for e in entries if method is None or e["method"] == method]

    def wait_for(self, method, count=1):
        for _ in range(100):
            if len(self.calls(method)) >= count:
                return self.calls(method)
            time.sleep(0.1)
        self.fail(f"no {method} call: {self.calls()}")

    def sessions(self):
        try:
            return json.loads((self.acp / "sessions.json").read_text())
        except OSError:
            return {}

    # --- HTTP -------------------------------------------------------------------------

    def call(self, method, path, body=None, key=API_KEY, raw=False):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=30)
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
        return self.call("POST", "/v1/chat/completions", {"model": "deepseek-harness", "messages": messages, **extra})

    def reply(self, messages):
        status, body = self.chat(messages)
        self.assertEqual(status, 200, body)
        return body["choices"][0]["message"]["content"]

    def stream(self, messages):
        status, text = self.call("POST", "/v1/chat/completions",
                                 {"model": "deepseek-harness", "messages": messages, "stream": True}, raw=True)
        self.assertEqual(status, 200)
        chunks = [json.loads(line[6:]) for line in text.splitlines()
                  if line.startswith("data: ") and line != "data: [DONE]"]
        self.assertTrue(text.rstrip().endswith("data: [DONE]"), text)
        content = "".join(c["choices"][0]["delta"].get("content", "") for c in chunks)
        reasoning = "".join(c["choices"][0]["delta"].get("reasoning_content", "") for c in chunks)
        return chunks, content, reasoning

    # --- models and requests ------------------------------------------------------------

    def test_models_need_the_key(self):
        self.assertEqual(self.call("GET", "/v1/models", key=None)[0], 401)
        self.assertEqual(self.call("GET", "/v1/models", key="wrong")[0], 401)
        status, body = self.call("GET", "/v1/models")
        self.assertEqual(status, 200)
        self.assertEqual([m["id"] for m in body["data"]], ["deepseek-harness"])
        self.assertEqual(self.call("GET", "/v1/models/deepseek-harness")[1]["id"], "deepseek-harness")
        self.assertEqual(self.call("POST", "/v1/chat/completions", {"messages": []}, key=None)[0], 401)

    def test_health_follows_the_acp_server(self):
        self.assertEqual(self.call("GET", "/healthz", key=None), (200, {"ok": True}))
        self.assertEqual(len(self.calls("initialize")), 1)
        self.stop_proxy()
        self.start_proxy(DSH_API_ACP_COMMAND=json.dumps([sys.executable, "-c", "pass"]))
        status, body = self.call("GET", "/healthz", key=None)
        self.assertEqual(status, 503)
        self.assertFalse(body["ok"])

    def test_an_unreachable_socket_is_an_upstream_error(self):
        if not hasattr(socket, "AF_UNIX"):
            self.skipTest("no unix sockets here")
        self.stop_proxy()
        env = {"DSH_API_ACP_COMMAND": "", "DSH_API_ACP_SOCKET": str(pathlib.Path(self.temp.name, "none.sock"))}
        self.start_proxy(**env)
        status, body = self.chat([{"role": "user", "content": "hi"}])
        self.assertEqual(status, 502)
        self.assertIn("unreachable", body["error"]["message"])

    def test_another_protocol_version_is_refused(self):
        self.stop_proxy()
        os.environ["FAKE_ACP_VERSION"] = "2"
        try:
            self.start_proxy()
            status, body = self.chat([{"role": "user", "content": "hi"}])
        finally:
            del os.environ["FAKE_ACP_VERSION"]
        self.assertEqual(status, 502)
        self.assertIn("ACP version 2", body["error"]["message"])
        self.assertEqual(self.calls("session/new"), [])

    def test_bad_requests(self):
        self.assertEqual(self.chat([{"role": "user", "content": "hi"}], model="other")[0], 404)
        self.assertEqual(self.chat([])[0], 400)
        self.assertEqual(self.chat([{"role": "assistant", "content": "only me"}])[0], 400)
        self.assertEqual(self.chat([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "x"}])[0], 400)
        self.assertEqual(self.calls("session/prompt"), [])

    # --- conversations --------------------------------------------------------------------

    def test_a_new_chat_opens_a_session_in_the_workspace(self):
        self.assertEqual(self.reply([{"role": "user", "content": "hi"}]), "Hello there")
        self.assertEqual(self.calls("session/new")[0]["params"], {"cwd": WORKSPACE, "mcpServers": []})
        self.assertEqual(self.calls("session/prompt"), [{"method": "session/prompt", "session": "ses-0001",
                                                         "text": "hi"}])

    def test_the_next_turn_continues_the_session_as_open_webui_sends_it_back(self):
        self.reply([{"role": "user", "content": "hi"}])
        # Open WebUI keeps reasoning in a details block and may reflow white space.
        self.reply([{"role": "system", "content": "Be brief."},
                    {"role": "user", "content": [{"type": "text", "text": "hi"}]},
                    {"role": "assistant",
                     "content": '<details type="reasoning" done="true">\nt\n</details>\nHello  there\n'},
                    {"role": "user", "content": "and now?"}])
        self.assertEqual(len(self.calls("session/new")), 1)
        self.assertEqual([(p["session"], p["text"]) for p in self.calls("session/prompt")],
                         [("ses-0001", "hi"), ("ses-0001", "and now?")])
        self.assertEqual(self.calls("session/resume"), [], "an open session needs no resume")

    def test_a_regenerated_reply_gets_a_new_session_with_the_earlier_turns(self):
        self.reply([{"role": "user", "content": "first"}])
        self.reply([{"role": "user", "content": "first"}, {"role": "assistant", "content": "Hello there"},
                    {"role": "user", "content": "second"}])
        # Regenerate the second reply: the same history again, but its session has moved on.
        self.reply([{"role": "system", "content": "Be brief."},
                    {"role": "user", "content": "first"}, {"role": "assistant", "content": "Hello there"},
                    {"role": "user", "content": "second"}])
        self.assertEqual(len(self.sessions()), 2)
        text = self.calls("session/prompt")[2]["text"]
        self.assertIn("Instructions from the chat client:\nBe brief.", text)
        self.assertIn("User: first", text)
        self.assertIn("Assistant: Hello there", text)
        self.assertTrue(text.endswith("Current message:\nsecond"))

    def test_a_session_gone_from_harness_starts_again(self):
        self.reply([{"role": "user", "content": "q"}])
        self.stop_proxy()
        (self.acp / "sessions.json").write_text("{}")
        self.start_proxy()
        self.reply([{"role": "user", "content": "q"}, {"role": "assistant", "content": "Hello there"},
                    {"role": "user", "content": "more"}])
        self.assertEqual(len(self.calls("session/resume")), 1)
        self.assertEqual(len(self.calls("session/new")), 2)
        self.assertIn("User: q", self.calls("session/prompt")[1]["text"])

    def test_the_mapping_survives_a_restart_by_resuming(self):
        self.reply([{"role": "user", "content": "hi"}])
        self.stop_proxy()
        self.start_proxy()
        self.reply([{"role": "user", "content": "hi"}, {"role": "assistant", "content": "Hello there"},
                    {"role": "user", "content": "again"}])
        self.assertEqual(len(self.calls("session/new")), 1)
        self.assertEqual(self.calls("session/resume")[0]["params"],
                         {"sessionId": "ses-0001", "cwd": WORKSPACE, "mcpServers": []})
        self.assertEqual(self.calls("session/prompt")[1]["text"], "again")

    def test_idle_sessions_are_closed_and_resumed_when_their_chat_continues(self):
        self.stop_proxy()
        self.start_proxy(DSH_API_IDLE="0")
        self.reply([{"role": "user", "content": "a"}])
        time.sleep(0.05)
        self.reply([{"role": "user", "content": "b"}])
        self.assertEqual([c["params"]["sessionId"] for c in self.calls("session/close")], ["ses-0001"])
        self.reply([{"role": "user", "content": "a"}, {"role": "assistant", "content": "Hello there"},
                    {"role": "user", "content": "a2"}])
        self.assertEqual([c["params"]["sessionId"] for c in self.calls("session/resume")], ["ses-0001"])

    # --- streaming --------------------------------------------------------------------------

    def test_streaming_messages_thoughts_and_tools(self):
        self.script([{"thought": "thinking"}, {"message": "Let me look.", "id": "m1"}, {"tool": "bash"},
                     {"tool_failed": "Error: no such file\nmore"},
                     {"other_session": {"sessionUpdate": "agent_message_chunk", "messageId": "x",
                                        "content": {"type": "text", "text": "noise"}}},
                     {"update": {"sessionUpdate": "usage_update", "used": 10, "size": 100}},
                     {"update": {"sessionUpdate": "agent_message_chunk", "messageId": "img",
                                 "content": {"type": "image", "data": ""}}},
                     {"message": "Done.", "id": "m2"}])
        chunks, content, reasoning = self.stream([{"role": "user", "content": "go"}])
        self.assertEqual(chunks[0]["choices"][0]["delta"]["role"], "assistant")
        self.assertEqual(chunks[-1]["choices"][0]["finish_reason"], "stop")
        self.assertEqual(content, "Let me look.\n\nDone.")
        self.assertIn("thinking", reasoning)
        self.assertIn("[tool: bash]", reasoning)
        self.assertIn("[tool failed: Error: no such file more]", reasoning)
        # The stored state is the content that was sent, so the next turn continues.
        self.reply([{"role": "user", "content": "go"}, {"role": "assistant", "content": content},
                    {"role": "user", "content": "next"}])
        self.assertEqual(len(self.sessions()), 1)

    def test_activity_can_be_left_out(self):
        self.stop_proxy()
        self.start_proxy(DSH_API_ACTIVITY="false")
        self.script([{"tool": "bash"}, {"message": "ok"}])
        _, content, reasoning = self.stream([{"role": "user", "content": "go"}])
        self.assertEqual((content, reasoning), ("ok", ""))

    def test_a_turn_without_a_reply_says_so(self):
        self.script([{"tool": "bash"}])
        self.assertIn("without a reply", self.reply([{"role": "user", "content": "x"}]))

    def test_an_output_limit_is_noted(self):
        self.script([{"message": "partial"}, {"stop": "max_tokens"}])
        _, content, reasoning = self.stream([{"role": "user", "content": "x"}])
        self.assertEqual(content, "partial")
        self.assertIn("[stopped: max tokens]", reasoning)

    # --- permissions, failures, disconnects ----------------------------------------------------

    OPTIONS = [{"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
               {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}]

    def test_permissions_are_allowed_once(self):
        self.script([{"permission": self.OPTIONS}, {"message": "ok"}])
        _, _, reasoning = self.stream([{"role": "user", "content": "x"}])
        self.assertEqual(self.calls("permission")[0]["answer"],
                         {"outcome": {"outcome": "selected", "optionId": "allow-once"}})
        self.assertIn("[permission allowed: bash]", reasoning)

    def test_permissions_can_be_rejected(self):
        self.stop_proxy()
        self.start_proxy(DSH_API_PERMISSIONS="reject")
        self.script([{"permission": self.OPTIONS}, {"message": "ok"}])
        self.reply([{"role": "user", "content": "x"}])
        self.assertEqual(self.calls("permission")[0]["answer"],
                         {"outcome": {"outcome": "selected", "optionId": "reject-once"}})

    def test_a_permission_without_a_fitting_option_or_turn_is_cancelled(self):
        self.script([{"permission": [{"optionId": "a", "name": "Always", "kind": "allow_always"}]},
                     {"permission": [{"optionId": "x", "name": "Something", "kind": "other"}]},
                     {"permission": self.OPTIONS, "session": "ses-stranger"}, {"message": "ok"}])
        self.reply([{"role": "user", "content": "x"}])
        answers = [c["answer"] for c in self.calls("permission")]
        self.assertEqual(answers, [{"outcome": {"outcome": "selected", "optionId": "a"}},
                                   {"outcome": {"outcome": "cancelled"}},
                                   {"outcome": {"outcome": "cancelled"}}])

    def test_a_failed_prompt_is_reported_and_not_continued(self):
        self.script([{"message": "partial"}, {"error": [-32603, "Internal error: turn failed: Connection error."]}],
                    [{"message": "partial"}, {"error": [-32603, "Internal error: turn failed: model unavailable"]}])
        status, body = self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(status, 502)
        self.assertIn("Connection error", body["error"]["message"])
        _, content, _ = self.stream([{"role": "user", "content": "x"}])
        self.assertIn("partial", content)
        self.assertIn("**DeepSeek Harness error:** Internal error: turn failed: model unavailable", content)
        # A failed turn is not a state to continue from.
        self.reply([{"role": "user", "content": "x"}, {"role": "assistant", "content": "partial"},
                    {"role": "user", "content": "retry"}])
        self.assertEqual(len(self.sessions()), 3)

    def test_a_client_that_goes_away_cancels_the_turn(self):
        self.script([{"message": "working"}, {"sleep": 30}])
        payload = json.dumps({"model": "deepseek-harness", "stream": True,
                              "messages": [{"role": "user", "content": "long job"}]}).encode()
        client = socket.create_connection(("127.0.0.1", self.server.server_port), timeout=10)
        client.sendall(b"POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                       + f"Authorization: Bearer {API_KEY}\r\nContent-Length: {len(payload)}\r\n\r\n".encode()
                       + payload)
        seen = b""
        while b"working" not in seen:
            seen += client.recv(4096)
        client.close()
        self.assertEqual(self.wait_for("session/cancel")[0]["params"], {"sessionId": "ses-0001"})
        # The session can take the next prompt.
        self.reply([{"role": "user", "content": "again"}])

    def test_a_turn_that_takes_too_long_is_cancelled(self):
        self.stop_proxy()
        self.start_proxy(DSH_API_TURN_TIMEOUT="1")
        self.script([{"sleep": 30}])
        status, body = self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(status, 502)
        self.assertIn("longer than 1 seconds", body["error"]["message"])
        self.assertEqual(len(self.calls("session/cancel")), 1)

    def test_a_cancelled_stop_is_an_error(self):
        self.script([{"message": "half"}, {"stop": "cancelled"}])
        status, body = self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(status, 502)
        self.assertIn("cancelled", body["error"]["message"])

    def test_the_server_dying_mid_turn_is_reported_and_the_next_turn_reconnects(self):
        self.script([{"message": "half"}, {"exit": True}])
        status, body = self.chat([{"role": "user", "content": "x"}])
        self.assertEqual(status, 502)
        self.assertIn("closed", body["error"]["message"])
        self.assertEqual(self.reply([{"role": "user", "content": "y"}]), "Hello there")
        self.assertEqual(len(self.calls("initialize")), 2)

    def test_turns_are_limited(self):
        self.stop_proxy()
        self.start_proxy(DSH_API_MAX_TURNS="1")
        self.script([{"sleep": 1.5}, {"message": "done"}])
        results = []
        first = threading.Thread(target=lambda: results.append(self.chat([{"role": "user", "content": "a"}])[0]))
        first.start()
        self.wait_for("session/prompt")
        status, _ = self.chat([{"role": "user", "content": "b"}])
        first.join()
        self.assertEqual(status, 429)
        self.assertEqual(results, [200])

    # --- helpers --------------------------------------------------------------------------------

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
        for bad in ({"DSH_API_PERMISSIONS": "maybe"}, {"DSH_API_ACP_COMMAND": '"dsh"'},
                    {"DSH_API_ACP_COMMAND": "not json"}, {"DSH_API_WORKSPACE": "relative"}):
            with self.assertRaises(SystemExit, msg=bad):
                MODULE.Config({"DSH_API_KEY": "k", **bad})
        with self.assertRaises(SystemExit):
            MODULE.Config({})
        defaults = MODULE.Config({"DSH_API_KEY": "k"})
        self.assertEqual((defaults.port, defaults.model, defaults.socket, defaults.permissions, defaults.command),
                         (3081, "deepseek-harness", "/run/deepseek-harness-acp/acp.sock", "allow", None))


if __name__ == "__main__":
    unittest.main()
