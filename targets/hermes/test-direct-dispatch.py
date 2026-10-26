"""Integration checks for Hermes's loopback dispatcher; no real router/GPU."""

import importlib.util
import json
import pathlib
import socket
import threading
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

    def do_GET(self):
        self.requests.append(("GET", self.path, self.headers.get("Authorization")))
        if self.path == "/v1/models":
            self.send_json({"data": [{"id": name} for name in
                                     ("auto", "fast", "medium", "large", "xlarge",
                                      "tool-model", "other-model")]})
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


if __name__ == "__main__":
    unittest.main()
