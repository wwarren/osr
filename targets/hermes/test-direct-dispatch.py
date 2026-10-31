"""Integration checks for Hermes's loopback dispatcher; no real router/GPU."""

import contextlib
import http.client
import importlib.util
import io
import json
import pathlib
import socket
import struct
import tempfile
import threading
import time
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen


spec = importlib.util.spec_from_file_location("direct_dispatch", pathlib.Path(__file__).with_name("direct-dispatch.py"))
direct = importlib.util.module_from_spec(spec)
spec.loader.exec_module(direct)


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class Quiet(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send_json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Backend(Quiet):
    requests = []
    errors = {}
    stream_gate = threading.Event()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.server.server_port, self.path,
                              self.headers.get("Authorization"), body))
        if self.server.server_port in self.errors:
            code, data = self.errors[self.server.server_port]
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b'data: {"chunk":1}\n\n')
            self.wfile.flush()
            self.stream_gate.wait(5)
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
            return
        self.send_json({"model": body["model"], "choices": [{"message": {"content": "ready"}}]})


class Router(Quiet):
    inventory = {}
    rankings = []
    requests = []
    extra_models = ()

    def do_GET(self):
        self.requests.append(("GET", self.path, self.headers.get("Authorization")))
        if self.path == "/v1/models":
            self.send_json({"data": [{"id": name} for name in
                                     ("auto", "fast", "medium", "large", "xlarge",
                                      "tool-model", "other-model", *self.extra_models)]})
        else:
            self.send_json(self.inventory)

    def do_POST(self):
        self.requests.append(("POST", self.path, self.headers.get("Authorization")))
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_json({"candidates": self.rankings})


class TestDirect(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hot = serve(Backend)
        cls.cold = serve(Backend)
        cls.router = serve(Router)
        cls.proxy = serve(direct.Handler)

    @classmethod
    def tearDownClass(cls):
        for server in (cls.proxy, cls.router, cls.hot, cls.cold):
            server.shutdown()
            server.server_close()

    def setUp(self):
        Backend.requests = []
        Backend.errors = {}
        Backend.stream_gate.clear()
        Router.requests = []
        Router.extra_models = ()
        hot = f"strata+http://127.0.0.1:{self.hot.server_port}"
        cold = f"strata+http://127.0.0.1:{self.cold.server_port}"
        Router.inventory = {
            "enabled": True, "servers": [hot, cold],
            "server_status": {hot: {"up": True}, cold: {"up": True}},
            "models": [
                {"server": hot, "name": "tool-model", "loaded": True,
                 "tools": True, "is_embedding": False},
                {"server": cold, "name": "other-model", "loaded": None,
                 "tools": True, "is_embedding": False},
                {"server": cold, "name": "embed-model", "loaded": True,
                 "tools": False, "is_embedding": True},
            ],
        }
        Router.rankings = [{"server": cold, "model": "other-model"},
                           {"server": hot, "model": "tool-model"}]
        direct.Handler.dispatcher = direct.Dispatcher(
            f"http://127.0.0.1:{self.router.server_port}", "router-secret",
            {"STRATA_API_KEY": "backend-secret"})
        self.base = f"http://127.0.0.1:{self.proxy.server_port}"

    def post(self, body):
        request = Request(self.base + "/v1/chat/completions",
                          data=json.dumps(body).encode(),
                          headers={"Content-Type": "application/json",
                                   "Authorization": "Bearer local-placeholder"})
        with urlopen(request, timeout=5) as response:
            return response, json.load(response)

    def test_inventory_and_direct_auth(self):
        with urlopen(self.base + "/v1/models", timeout=5) as response:
            names = {m["id"] for m in json.load(response)["data"]}
        self.assertEqual(names, {"auto", "fast", "medium", "large", "xlarge",
                                 "tool-model", "other-model"})
        response, answer = self.post({"model": "auto", "messages": [{"role": "user", "content": "Do work"}],
                                      "tools": [{"type": "function"}]})
        self.assertEqual(answer["model"], "tool-model")
        self.assertEqual(response.headers["X-Hermes-Direct-Server"], Router.inventory["servers"][0])
        self.assertEqual(len(Backend.requests), 1)
        port, path, auth, body = Backend.requests[0]
        self.assertEqual((port, path, auth, body["model"]),
                         (self.hot.server_port, "/v1/chat/completions",
                          "Bearer backend-secret", "tool-model"))
        self.assertTrue(Router.requests)
        self.assertTrue(all(req[2] == "Bearer router-secret" for req in Router.requests))
        self.assertFalse(any(req[1] == "/v1/chat/completions" for req in Router.requests))

    def test_task_stays_on_one_model(self):
        first = {"model": "auto", "messages": [{"role": "user", "content": "Build a script"}]}
        self.post(first)
        Router.rankings.reverse()
        self.post({"model": "auto", "messages": first["messages"] +
                   [{"role": "assistant", "content": "step 1"},
                    {"role": "user", "content": "continue"}]})
        self.assertEqual([req[0] for req in Backend.requests],
                         [self.hot.server_port, self.hot.server_port])
        self.assertEqual(sum(req[0] == "POST" for req in Router.requests), 1)

    def test_explicit_model_and_unavailable(self):
        _, answer = self.post({"model": "other-model", "messages": []})
        self.assertEqual(answer["model"], "other-model")
        with self.assertRaises(HTTPError) as context:
            self.post({"model": "embed-model", "messages": []})
        self.assertEqual(context.exception.code, 503)
        context.exception.close()

    def test_router_tier_alias_is_selected_directly(self):
        _, answer = self.post({"model": "large", "messages": [{"role": "user", "content": "Plan it"}]})
        self.assertEqual(answer["model"], "tool-model")
        self.assertEqual(Backend.requests[0][0], self.hot.server_port)

    def test_unregistered_destination_is_rejected(self):
        Router.inventory["models"].append({"server": "strata+http://127.0.0.1:1",
                                           "name": "bad", "loaded": True})
        with self.assertRaises(HTTPError) as context:
            self.post({"model": "bad", "messages": []})
        self.assertEqual(context.exception.code, 503)
        context.exception.close()

    def test_same_model_host_failover(self):
        hot, cold = Router.inventory["servers"]
        Router.inventory["models"].append({"server": cold, "name": "tool-model",
                                            "loaded": None, "tools": True,
                                            "is_embedding": False})
        Router.rankings.append({"server": cold, "model": "tool-model"})
        Backend.errors[self.hot.server_port] = (503, b'{}')
        _, answer = self.post({"model": "auto", "messages": [{"role": "user", "content": "Fail over"}]})
        self.assertEqual(answer["model"], "tool-model")
        self.assertEqual([req[0] for req in Backend.requests],
                         [self.hot.server_port, self.cold.server_port])
        Backend.requests.clear()
        self.post({"model": "auto", "messages": [{"role": "user", "content": "Fail over"}]})
        self.assertEqual([req[0] for req in Backend.requests], [self.cold.server_port])

    def test_tool_rejection_tries_another_model(self):
        Backend.errors[self.hot.server_port] = (400, b'{"error":{"message":"does not support tools"}}')
        _, answer = self.post({"model": "auto", "messages": [{"role": "user", "content": "Use tools"}],
                               "tools": [{"type": "function"}]})
        self.assertEqual(answer["model"], "other-model")
        self.assertEqual([req[0] for req in Backend.requests],
                         [self.hot.server_port, self.cold.server_port])

    def spy_backends(self):
        """Record the server of every direct attempt, in order."""
        attempts = []
        dispatcher = direct.Handler.dispatcher
        real_open = dispatcher.open_backend

        def spy(entry, body):
            attempts.append(entry["server"])
            return real_open(entry, body)
        dispatcher.open_backend = spy
        return attempts

    def test_portless_urls_use_the_scheme_default(self):
        self.assertEqual(direct.server_parts("http://models.lan"), ("ollama", "http://models.lan"))
        self.assertEqual(direct.server_parts("strata+https://models.lan/"), ("strata", "https://models.lan"))
        for bad in ("http://models.lan:0", "http://models.lan:70000", "ftp://models.lan"):
            with self.assertRaises(ValueError):
                direct.server_parts(bad)

    def test_unreachable_server_is_skipped(self):
        # A port with nothing listening: the connection is refused.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            dead = f"strata+http://127.0.0.1:{probe.getsockname()[1]}"
        hot = Router.inventory["servers"][0]
        Router.inventory["servers"].append(dead)
        Router.inventory["server_status"][dead] = {"up": True}
        Router.inventory["models"].append({"server": dead, "name": "tool-model", "loaded": True,
                                           "tools": True, "is_embedding": False})
        Router.rankings.insert(0, {"server": dead, "model": "tool-model"})
        attempts = self.spy_backends()
        _, answer = self.post({"model": "auto", "messages": [{"role": "user", "content": "First task"}]})
        self.assertEqual(answer["model"], "tool-model")
        self.assertEqual(attempts, [dead, hot])
        attempts.clear()
        self.post({"model": "auto", "messages": [{"role": "user", "content": "Second task"}]})
        self.assertEqual(attempts, [hot], "a server that just failed was tried again")
        # Once SKIP_SECONDS have passed, it is tried again.
        attempts.clear()
        with mock.patch.object(direct, "SKIP_SECONDS", 0):
            self.post({"model": "auto", "messages": [{"role": "user", "content": "Third task"}]})
        self.assertEqual(attempts, [dead, hot])

    def test_a_failed_server_is_still_tried_when_nothing_else_is_left(self):
        hot = Router.inventory["servers"][0]
        direct.Handler.dispatcher.mark_failed(hot)
        attempts = self.spy_backends()
        _, answer = self.post({"model": "tool-model", "messages": []})
        self.assertEqual((answer["model"], attempts), ("tool-model", [hot]))
        attempts.clear()
        self.post({"model": "auto", "messages": [{"role": "user", "content": "Back again"}]})
        self.assertEqual(attempts, [hot], "a server that answered stayed on the skip list")

    def test_pinned_task_falls_back_when_its_server_fails(self):
        hot, cold = Router.inventory["servers"]
        first_user = {"role": "user", "content": "Keep working on this task"}
        self.post({"model": "auto", "messages": [first_user]})
        dispatcher = direct.Handler.dispatcher
        real_open = dispatcher.open_backend
        attempts = []

        def fail_hot(entry, body):
            attempts.append(entry["server"])
            if entry["server"] == hot:
                raise OSError("server is unreachable")
            return real_open(entry, body)

        later = {"model": "auto", "messages": [first_user,
                 {"role": "assistant", "content": "step one"},
                 {"role": "user", "content": "continue"}]}
        with mock.patch.object(dispatcher, "open_backend", side_effect=fail_hot):
            _, answer = self.post(later)
            self.assertEqual(answer["model"], "other-model")
            self.assertEqual(attempts, [hot, cold])
            attempts.clear()
            self.post(later)
            self.assertEqual(attempts, [cold], "the task was not pinned to the healthy fallback")

    def test_incomplete_backend_stream_is_quarantined(self):
        hot, cold = Router.inventory["servers"]
        original = Backend.do_POST

        def drop_stream(handler):
            if handler.server.server_port != self.hot.server_port:
                return original(handler)
            handler.rfile.read(int(handler.headers["Content-Length"]))
            handler.send_response(200)
            handler.send_header("Content-Type", "text/event-stream")
            handler.send_header("Transfer-Encoding", "chunked")
            handler.end_headers()
            handler.wfile.write(b"7\r\npartial\r\n")
            handler.wfile.flush()
            handler.close_connection = True  # no terminating chunk

        body = {"model": "auto", "messages": [{"role": "user", "content": "Stream this"}],
                "stream": True}
        request = Request(self.base + "/v1/chat/completions",
                          data=json.dumps(body).encode(),
                          headers={"Content-Type": "application/json"})
        handler_errors = []
        with mock.patch.object(Backend, "do_POST", drop_stream), \
                mock.patch.object(self.proxy, "handle_error",
                                  side_effect=lambda *args: handler_errors.append(args)):
            with urlopen(request, timeout=5) as response:
                # The client must see a broken response, not a short answer.
                with self.assertRaises(http.client.IncompleteRead) as broken:
                    response.read()
                self.assertEqual(broken.exception.partial, b"partial")
            self.assertFalse(handler_errors, "the incomplete stream escaped the handler")
            self.assertIn(hot, direct.Handler.dispatcher._failed)
            attempts = self.spy_backends()
            _, answer = self.post({"model": "auto", "messages": body["messages"]})
            self.assertEqual(answer["model"], "other-model")
            self.assertEqual(attempts, [cold])

    def test_short_backend_body_reaches_the_client_as_incomplete(self):
        hot, cold = Router.inventory["servers"]
        original = Backend.do_POST

        def short_body(handler):
            if handler.server.server_port != self.hot.server_port:
                return original(handler)
            handler.rfile.read(int(handler.headers["Content-Length"]))
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", "500")
            handler.end_headers()
            handler.wfile.write(b'{"choices": [{"message": {"content": "par')
            handler.wfile.flush()
            handler.close_connection = True

        with mock.patch.object(Backend, "do_POST", short_body):
            with self.assertRaises(http.client.IncompleteRead) as broken:
                self.post({"model": "tool-model", "messages": []})
        self.assertTrue(broken.exception.partial.startswith(b'{"choices"'))
        self.assertIn(hot, direct.Handler.dispatcher._failed)

    def test_eof_delimited_json_must_be_complete(self):
        hot = Router.inventory["servers"][0]
        original = Backend.do_POST

        def unframed(handler):
            if handler.server.server_port != self.hot.server_port:
                return original(handler)
            body = json.loads(handler.rfile.read(int(handler.headers["Content-Length"])))
            data = (b'{"model":"tool-model","choices":[]}' if body["messages"][0]["content"] == "valid"
                    else b'{"choices": [{"message": {"content": "par')
            handler.send_response(200)
            handler.send_header("Content-Type", "application/json")
            handler.end_headers()  # no Content-Length or Transfer-Encoding
            handler.wfile.write(data)
            handler.wfile.flush()
            handler.close_connection = True

        with mock.patch.object(Backend, "do_POST", unframed):
            _, answer = self.post({"model": "tool-model", "messages": [
                {"role": "user", "content": "valid"}]})
            self.assertEqual(answer["model"], "tool-model")
            with self.assertRaises(http.client.IncompleteRead):
                self.post({"model": "tool-model", "messages": [
                    {"role": "user", "content": "cut off"}]})
        self.assertIn(hot, direct.Handler.dispatcher._failed)

    def test_eof_delimited_sse_needs_done(self):
        hot = Router.inventory["servers"][0]
        original = Backend.do_POST

        def unframed(handler):
            if handler.server.server_port != self.hot.server_port:
                return original(handler)
            handler.rfile.read(int(handler.headers["Content-Length"]))
            handler.send_response(200)
            handler.send_header("Content-Type", "text/event-stream")
            handler.end_headers()  # no Content-Length or Transfer-Encoding
            handler.wfile.write(b'data: {"chunk":1}\n\n')
            handler.wfile.flush()
            handler.close_connection = True

        request = Request(self.base + "/v1/chat/completions",
                          data=json.dumps({"model": "tool-model", "messages": [], "stream": True}).encode(),
                          headers={"Content-Type": "application/json"})
        with mock.patch.object(Backend, "do_POST", unframed):
            with urlopen(request, timeout=5) as response:
                with self.assertRaises(http.client.IncompleteRead):
                    response.read()
        self.assertIn(hot, direct.Handler.dispatcher._failed)

    def test_done_marker_split_across_backend_reads(self):
        done = direct._SSEDone()
        done.feed(b'data: {"chunk":1}\n\ndata: [DO')
        self.assertFalse(done.seen)
        done.feed(b'NE]\r\n\r\n')
        self.assertTrue(done.seen)

    def test_done_marker_without_a_line_end_counts_at_eof(self):
        done = direct._SSEDone()
        done.feed(b'data: {"chunk":1}\n\ndata: [DONE]')
        self.assertFalse(done.seen)
        self.assertTrue(done.finish())
        cut = direct._SSEDone()
        cut.feed(b'data: {"chunk":1}\n\ndata: [DO')
        self.assertFalse(cut.finish(), "a cut-off [DONE] was accepted")
        long_line = direct._SSEDone()
        long_line.feed(b"data: " + b"x" * 200)
        self.assertFalse(long_line.finish())

    def unframed_sse(self, data):
        """A backend that streams SSE without framing and then closes."""
        original = Backend.do_POST

        def handler_fn(handler):
            if handler.server.server_port != self.hot.server_port:
                return original(handler)
            handler.rfile.read(int(handler.headers["Content-Length"]))
            handler.send_response(200)
            handler.send_header("Content-Type", "text/event-stream")
            handler.end_headers()
            handler.wfile.write(data)
            handler.wfile.flush()
            handler.close_connection = True
        return mock.patch.object(Backend, "do_POST", handler_fn)

    def stream_request(self):
        return Request(self.base + "/v1/chat/completions",
                       data=json.dumps({"model": "tool-model", "messages": [], "stream": True}).encode(),
                       headers={"Content-Type": "application/json"})

    def test_eof_delimited_sse_with_a_final_done_and_no_line_end(self):
        hot = Router.inventory["servers"][0]
        with self.unframed_sse(b'data: {"chunk":1}\n\ndata: [DONE]'):
            with urlopen(self.stream_request(), timeout=5) as response:
                self.assertTrue(response.read().endswith(b"data: [DONE]"))
        self.assertNotIn(hot, direct.Handler.dispatcher._failed)

    def test_framed_sse_without_done_is_complete(self):
        # Chunked encoding marks the end, so [DONE] is not required.
        hot = Router.inventory["servers"][0]
        original = Backend.do_POST
        event = b'data: {"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}\n\n'

        def chunked(handler):
            if handler.server.server_port != self.hot.server_port:
                return original(handler)
            handler.rfile.read(int(handler.headers["Content-Length"]))
            handler.send_response(200)
            handler.send_header("Content-Type", "text/event-stream")
            handler.send_header("Transfer-Encoding", "chunked")
            handler.end_headers()
            handler.wfile.write(b"%x\r\n%s\r\n0\r\n\r\n" % (len(event), event))
            handler.wfile.flush()
            handler.close_connection = True

        with mock.patch.object(Backend, "do_POST", chunked):
            with urlopen(self.stream_request(), timeout=5) as response:
                self.assertEqual(response.read(), event)
        self.assertNotIn(hot, direct.Handler.dispatcher._failed)

    def test_complete_responses_are_chunked_and_the_connection_kept(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.proxy.server_port, timeout=5)
        try:
            for content in ("one", "two"):
                connection.request("POST", "/v1/chat/completions",
                                   json.dumps({"model": "tool-model", "messages": [
                                       {"role": "user", "content": content}]}),
                                   {"Content-Type": "application/json"})
                response = connection.getresponse()
                self.assertEqual(response.getheader("Transfer-Encoding"), "chunked")
                self.assertEqual(json.loads(response.read())["model"], "tool-model")
            # An error is answered with Connection: close (the body may be unread).
            connection.request("POST", "/nowhere", b"{}", {"Content-Type": "application/json"})
            response = connection.getresponse()
            response.read()
            self.assertEqual((response.status, response.getheader("Connection")), (404, "close"))
        finally:
            connection.close()

    def pin(self, server, name, first_user):
        dispatcher = direct.Handler.dispatcher
        session = dispatcher.session_key({"messages": [first_user]})
        dispatcher._sessions[session] = (server, name, direct.time.monotonic())

    def test_pinned_fallback_follows_the_router_ranking(self):
        hot = Router.inventory["servers"][0]
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            dead = f"strata+http://127.0.0.1:{probe.getsockname()[1]}"
        Router.inventory["servers"].append(dead)
        Router.inventory["server_status"][dead] = {"up": True}
        # Inventory order puts the small model first; the router ranks big-b first.
        Router.inventory["models"] = [
            {"server": dead, "name": "big-a", "loaded": True, "tools": True},
            {"server": hot, "name": "tiny-1b", "loaded": True, "tools": True},
            {"server": hot, "name": "big-b", "loaded": False, "tools": True}]
        Router.rankings = [{"server": dead, "model": "big-a"},
                           {"server": hot, "model": "big-b"},
                           {"server": hot, "model": "tiny-1b"}]
        first_user = {"role": "user", "content": "A long agent task"}
        self.pin(dead, "big-a", first_user)
        attempts = self.spy_backends()
        later = {"model": "auto", "tools": [{"type": "function"}],
                 "messages": [first_user, {"role": "assistant", "content": "step"},
                              {"role": "user", "content": "continue"}]}
        _, answer = self.post(later)
        self.assertEqual((answer["model"], attempts), ("big-b", [dead, hot]))
        # The task is now pinned to the fallback, without asking the router.
        attempts.clear()
        Router.requests.clear()
        _, answer = self.post(later)
        self.assertEqual((answer["model"], attempts), ("big-b", [hot]))
        self.assertFalse([r for r in Router.requests if r[1] == "/routing/explain"])

    def test_pinned_replica_error_falls_back_instead_of_failing(self):
        hot, cold = Router.inventory["servers"]
        first_user = {"role": "user", "content": "Another task"}
        self.pin(hot, "tool-model", first_user)
        Backend.errors[self.hot.server_port] = (503, b'{"error": "busy"}')
        _, answer = self.post({"model": "auto", "messages": [first_user]})
        self.assertEqual(answer["model"], "other-model")
        self.assertEqual([req[0] for req in Backend.requests],
                         [self.hot.server_port, self.cold.server_port])

    def add_unusable(self, name, **fields):
        """A loaded model on the hot server that the router ranks first."""
        hot = Router.inventory["servers"][0]
        Router.inventory["models"].insert(0, {"server": hot, "name": name, "loaded": True,
                                              "is_embedding": False, **fields})
        Router.rankings.insert(0, {"server": hot, "model": name})
        Router.extra_models = (name,)

    def test_a_model_without_tools_is_never_used(self):
        # AirLLM's shape: no tools. Not even for a request that offers none.
        self.add_unusable("airllm-72b", tools=False, context_length=2048)
        attempts = self.spy_backends()
        _, answer = self.post({"model": "auto", "messages": [{"role": "user", "content": "Summarize"}]})
        self.assertNotEqual(answer["model"], "airllm-72b")
        self.assertTrue(attempts)
        self.assertNotIn("airllm-72b", [m["name"] for m in direct.Handler.dispatcher.candidates(
            {"model": "auto", "messages": [{"role": "user", "content": "x"}]})])

    def test_a_model_with_too_little_context_is_never_used(self):
        direct.Handler.dispatcher.min_context = 64000
        self.add_unusable("small-ctx", tools=True, context_length=8192)
        names = [m["name"] for m in direct.Handler.dispatcher.candidates(
            {"model": "auto", "messages": [{"role": "user", "content": "x"}]})]
        self.assertNotIn("small-ctx", names)
        # Unknown context (None) and enough context are both usable.
        self.assertIn("tool-model", names)
        Router.inventory["models"][0]["context_length"] = 65536
        direct.Handler.dispatcher._inventory = None
        self.assertIn("small-ctx", [m["name"] for m in direct.Handler.dispatcher.candidates(
            {"model": "auto", "messages": [{"role": "user", "content": "y"}]})])

    def test_naming_an_unusable_model_is_refused_not_rerouted(self):
        self.add_unusable("airllm-72b", tools=False)
        attempts = self.spy_backends()
        with self.assertRaises(HTTPError) as refused:
            self.post({"model": "airllm-72b", "messages": [{"role": "user", "content": "hi"}]})
        self.assertEqual(refused.exception.code, 503)
        self.assertIn("tool support", json.loads(refused.exception.read())["error"]["message"])
        refused.exception.close()
        self.assertEqual(attempts, [])

    def test_model_list_leaves_out_unusable_models(self):
        self.add_unusable("airllm-72b", tools=False)
        with urlopen(self.base + "/v1/models", timeout=5) as response:
            names = {m["id"] for m in json.load(response)["data"]}
        self.assertNotIn("airllm-72b", names)
        self.assertIn("tool-model", names)

    def test_main_reads_the_context_floor_from_the_settings(self):
        with tempfile.TemporaryDirectory() as root:
            etc, home = pathlib.Path(root, "etc"), pathlib.Path(root, "home")
            etc.mkdir()
            home.mkdir()
            (etc / "settings").write_text("ROUTER_URL=http://r:8000\nHERMES_CONTEXT_LENGTH=65536\n")
            (home / ".env").write_text("ROUTER_API_KEY=k\n")
            env = {"HERMES_ETC": str(etc), "HERMES_HOME": str(home)}
            with mock.patch.dict("os.environ", env), \
                    mock.patch.object(direct, "DispatchServer"), \
                    mock.patch.object(direct.logging, "basicConfig"):
                direct.main()
            self.assertEqual(direct.Handler.dispatcher.min_context, 65536)
            (etc / "settings").write_text("ROUTER_URL=http://r:8000\nHERMES_CONTEXT_LENGTH=lots\n")
            with mock.patch.dict("os.environ", env), \
                    mock.patch.object(direct, "DispatchServer"), \
                    mock.patch.object(direct.logging, "basicConfig"), \
                    self.assertRaises(SystemExit):
                direct.main()

    def test_connect_timeout_is_short_and_read_timeout_long(self):
        made = []
        real = socket.create_connection

        def spy(address, timeout, *args, **kwargs):
            sock = real(address, timeout, *args, **kwargs)
            made.append((timeout, sock))
            return sock
        request = Request(f"http://127.0.0.1:{self.hot.server_port}/v1/chat/completions",
                          data=b'{"model": "tool-model", "messages": []}',
                          headers={"Content-Type": "application/json"})
        with mock.patch("socket.create_connection", spy):
            with direct.BACKEND.open(request, timeout=direct.READ_TIMEOUT) as response:
                self.assertEqual(made[0][1].gettimeout(), direct.READ_TIMEOUT)
                response.read()
        self.assertEqual(made[0][0], direct.CONNECT_TIMEOUT)
        self.assertLess(direct.CONNECT_TIMEOUT, direct.READ_TIMEOUT)

    def test_sse_is_forwarded_before_completion(self):
        body = {"model": "tool-model", "messages": [], "stream": True}
        request = Request(self.base + "/v1/chat/completions", data=json.dumps(body).encode(),
                          headers={"Content-Type": "application/json"})
        with urlopen(request, timeout=2) as response:
            self.assertEqual(response.readline(), b'data: {"chunk":1}\n')
            Backend.stream_gate.set()
            self.assertIn(b"[DONE]", response.read())


class TestServerErrors(unittest.TestCase):
    def setUp(self):
        self.server = direct.DispatchServer(("127.0.0.1", 0), Quiet)
        self.addCleanup(self.server.server_close)

    def report(self, exc):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertLogs(direct.LOG, "DEBUG") as logs:
            direct.LOG.debug("start")
            try:
                raise exc
            except Exception:
                self.server.handle_error(None, ("127.0.0.1", 1))
        return stderr.getvalue(), logs.output

    def test_a_dropped_client_connection_is_one_debug_line(self):
        for exc in (ConnectionResetError(104, "Connection reset by peer"), BrokenPipeError()):
            stderr, logs = self.report(exc)
            self.assertEqual(stderr, "")
            self.assertIn("closed the connection", logs[-1])

    def test_other_errors_keep_the_traceback(self):
        stderr, _ = self.report(ValueError("boom"))
        self.assertIn("Traceback", stderr)
        self.assertIn("ValueError: boom", stderr)

    def test_a_real_reset_between_requests_prints_no_traceback(self):
        server = direct.DispatchServer(("127.0.0.1", 0), Quiet)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            client = socket.create_connection(("127.0.0.1", server.server_port))
            # SO_LINGER 0: close() sends a reset, as Hermes's pool does.
            client.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            time.sleep(0.2)
            client.close()
            time.sleep(0.3)
        self.assertNotIn("Traceback", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
