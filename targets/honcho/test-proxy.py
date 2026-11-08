#!/usr/bin/env python3
"""Loopback proxy tests with separate fake router and model hosts."""

import importlib.util
import json
import pathlib
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen


HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location("honcho_proxy", HERE / "honcho-proxy.py")
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class FixtureHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        state = self.server.state
        state["paths"].append(self.path)
        if state["kind"] == "router":
            if self.headers.get("Authorization") != "Bearer router-key":
                return self.reply(401, {"error": "router key required"})
            if self.path == "/routing/inventory":
                model_host = state["model_host"]
                server = "strata+" + model_host
                models = [{"name": "tool-model", "server": server,
                           "tools": state["tools"], "context_length": state["context"],
                           "loaded": True, "is_embedding": False},
                          {"name": "embed-model", "server": server,
                           "is_embedding": True, "loaded": True}]
                if state.get("other"):
                    models.insert(0, {"name": "other-model", "server": server,
                                      "tools": True, "context_length": 65536,
                                      "loaded": True, "is_embedding": False})
                return self.reply(200, {"enabled": True, "servers": [server],
                                        "server_status": {server: {"up": True}},
                                        "models": models})
            if self.path == "/v1/models":
                return self.reply(200, {"data": [{"id": "fast"}, {"id": "tool-model"}]})
        self.reply(404, {"error": "unexpected GET"})

    def do_POST(self):
        state = self.server.state
        state["paths"].append(self.path)
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if state["kind"] == "router":
            if self.headers.get("Authorization") != "Bearer router-key":
                return self.reply(401, {"error": "router key required"})
            if self.path == "/routing/explain":
                server = "strata+" + state["model_host"]
                return self.reply(200, {"candidates": [{"model": "tool-model", "server": server}]})
            return self.reply(500, {"error": "inference reached router"})
        state["auth"].append(self.headers.get("Authorization"))
        if self.path == "/v1/chat/completions":
            state["chat"].append(body)
            if body.get("tools") and state.get("text_replies", 0) > 0:
                state["text_replies"] -= 1
                return self.reply(200, {"choices": [{"message": {"role": "assistant",
                                       "content": "I would rather not."}}]})
            if body.get("tools"):
                return self.reply(200, {"choices": [{"message": {"role": "assistant", "content": None,
                                       "tool_calls": [{"id": "call-1", "type": "function",
                                                       "function": {"name": "noop", "arguments": "{}"}}]}}]})
            return self.reply(200, {"choices": [{"message": {"role": "assistant",
                                   "content": state.get("json_reply", '{"ready": true}')}}]})
        if self.path == "/v1/embeddings":
            state["embed"].append(body)
            return self.reply(200, {"data": [{"embedding": [0.0, 0.1, 0.2]}]})
        self.reply(404, {"error": "unexpected POST"})


def start_server(state):
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    server.state = state
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


def post(url, body):
    request = Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
    with urlopen(request, timeout=10) as response:
        return json.load(response)


class ProxyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.model_state = {"kind": "model", "paths": [], "auth": [], "chat": [], "embed": []}
        self.model_server, _ = start_server(self.model_state)
        self.addCleanup(self.model_server.server_close)
        self.addCleanup(self.model_server.shutdown)
        model_url = "http://127.0.0.1:%s" % self.model_server.server_port
        self.router_state = {"kind": "router", "paths": [], "model_host": model_url,
                             "tools": True, "context": 65536}
        self.router_server, _ = start_server(self.router_state)
        self.addCleanup(self.router_server.server_close)
        self.addCleanup(self.router_server.shutdown)
        self.router_url = "http://127.0.0.1:%s" % self.router_server.server_port
        self.directory = pathlib.Path(self.temp.name)
        (self.directory / "router-api-key").write_text("router-key\n")
        (self.directory / "backend-keys").write_text("STRATA_API_KEY=backend-key\n")
        self.write_settings()

    def write_settings(self, **changes):
        values = {"ROUTER_URL": self.router_url, "HONCHO_MODEL": "fast",
                  "HONCHO_CONTEXT_TOKENS": "32768", "HONCHO_SKIP_CHAT_PROBE": "false"}
        values.update(changes)
        (self.directory / "proxy.settings").write_text(
            "".join("%s=%s\n" % pair for pair in values.items()))

    def test_probe_and_loopback_requests_go_directly_to_model(self):
        proxy.probe(str(self.directory))
        self.assertEqual(len(self.model_state["chat"]), 2)
        self.assertEqual([], self.model_state["embed"], "the probe checks chat only")
        self.router_state["other"] = True
        self.write_settings(RESOLVED_MODEL="tool-model")
        config = proxy.settings(str(self.directory))
        proxy.direct.Handler.dispatcher = proxy.HonchoDispatcher(
            config, proxy.router_key(str(self.directory)),
            proxy.direct.read_env(str(self.directory / "backend-keys")))
        local = proxy.direct.DispatchServer(("127.0.0.1", 0), proxy.direct.Handler)
        thread = threading.Thread(target=local.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(local.server_close)
        self.addCleanup(local.shutdown)
        base = "http://127.0.0.1:%s/v1" % local.server_port
        with urlopen(base + "/models", timeout=10) as response:
            self.assertEqual([item["id"] for item in json.load(response)["data"]], ["fast"],
                             "Honcho's embeddings come from its own model, not through here")
        result = post(base + "/chat/completions", {"model": "fast",
                      "messages": [{"role": "user", "content": "remember this"}]})
        self.assertEqual(result["choices"][0]["message"]["content"], '{"ready": true}')
        self.assertEqual(self.model_state["chat"][-1]["model"], "tool-model")
        self.assertTrue(all(value == "Bearer backend-key" for value in self.model_state["auth"]))
        self.assertFalse(any(path.startswith("/v1/chat/") or path == "/v1/embeddings"
                             for path in self.router_state["paths"]))

    def test_context_and_tool_metadata_are_required(self):
        self.router_state["context"] = 8192
        with self.assertRaisesRegex(ValueError, "no reachable model that reports tool support"):
            proxy.probe(str(self.directory))
        try:
            proxy.probe(str(self.directory))
        except ValueError as exc:
            self.assertIn("Set HONCHO_CONTEXT_TOKENS", str(exc), "the error names the fix")
        self.router_state["context"] = 65536
        self.router_state["tools"] = False
        with self.assertRaisesRegex(ValueError, "no reachable model that reports tool support"):
            proxy.probe(str(self.directory))

    def test_a_model_that_answers_in_text_gets_a_second_try(self):
        self.model_state["text_replies"] = 1
        proxy.probe(str(self.directory))
        tool_calls = [body for body in self.model_state["chat"] if body.get("tools")]
        self.assertEqual(2, len(tool_calls), "one text answer, then the firmer prompt")
        self.assertIn("must respond only by calling", tool_calls[1]["messages"][-1]["content"])

    def test_a_model_that_never_calls_tools_is_refused_with_the_way_out(self):
        self.model_state["text_replies"] = 99
        with self.assertRaisesRegex(ValueError, "answered in text instead of calling a tool in 2 tries"):
            proxy.probe(str(self.directory))
        try:
            proxy.probe(str(self.directory))
        except ValueError as exc:
            self.assertIn("HONCHO_SKIP_CHAT_PROBE=true", str(exc))

    def test_fenced_json_passes_but_prose_does_not(self):
        self.model_state["json_reply"] = '```json\n{"ready": true}\n```'
        proxy.probe(str(self.directory))
        self.model_state["json_reply"] = "Sure! Here it is: ready"
        with self.assertRaisesRegex(ValueError, "HONCHO_STRUCTURED_OUTPUT_MODE=json_object"):
            proxy.probe(str(self.directory))

    def test_settings_need_no_embedding_values(self):
        config = proxy.settings(str(self.directory))
        self.assertFalse([key for key in config if key.startswith("EMBEDDING")])
        self.write_settings(HONCHO_CONTEXT_TOKENS="4096")
        with self.assertRaisesRegex(ValueError, "invalid model context"):
            proxy.settings(str(self.directory))


if __name__ == "__main__":
    unittest.main()
