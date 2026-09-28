"""GPU-free contract tests for the target API adapter.

Run from the repository root: python -m unittest discover -s targets/llamacpp -v
"""

import asyncio
import json
import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from bridge import Config, create_app


ALIAS = "qwen-target"


class ByteStream(httpx.AsyncByteStream):
    def __init__(self, chunks, error=None, block=False):
        self.chunks = chunks
        self.error = error
        self.block = block
        self.closed = False

    async def __aiter__(self):
        for chunk in self.chunks:
            yield chunk
        if self.error:
            raise self.error
        if self.block:
            await asyncio.Event().wait()

    async def aclose(self):
        self.closed = True


def event(value):
    return ("data: " + (value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)) + "\n\n").encode()


def completion(content="Hello", reason="stop", **message):
    return {"choices": [{"message": {"content": content, **message}, "finish_reason": reason}],
            "usage": {"prompt_tokens": 7, "completion_tokens": 3}}


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.response = httpx.Response(200, json=completion())
        self.health_response = httpx.Response(200, json={"status": "ok"})
        self.config = Config("http://llama.invalid:8081", ALIAS,
                             parameter_size="8B", family="qwen", quantization="Q4_K_M")

    def client(self, **kwargs):
        def handler(request):
            self.requests.append(request)
            selected = self.health_response if request.url.path == "/health" else self.response
            if isinstance(selected, Exception):
                raise selected
            return selected(request) if callable(selected) else selected
        return TestClient(create_app(self.config, transport=httpx.MockTransport(handler)), **kwargs)

    def payload(self):
        return json.loads(self.requests[-1].content)

    def stream_response(self, chunks, error=None, block=False):
        stream = ByteStream(chunks, error, block)
        self.response = httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=stream)
        return stream

    def post(self, path="/api/chat", **body):
        with self.client() as client:
            return client.post(path, json={"model": ALIAS, **body})

    def rows(self, response):
        self.assertEqual(response.status_code, 200, response.text)
        self.assertTrue(response.headers["content-type"].startswith("application/x-ndjson"))
        return [json.loads(line) for line in response.text.splitlines()]

    def test_ready_metadata_and_file_size(self):
        with tempfile.TemporaryDirectory() as directory:
            model_path = Path(directory) / "test.gguf"
            model_path.write_bytes(b"GGUFtest")
            self.config = Config("http://llama.invalid:8081", ALIAS, str(model_path), "8B", "qwen", "Q4_K_M")
            with self.client() as client:
                self.assertEqual(client.get("/healthz").json()["status"], "ok")
                model = client.get("/api/tags").json()["models"][0]
                self.assertEqual(model["model"], ALIAS)
                self.assertEqual(model["size"], 8)
                self.assertEqual(model["details"]["quantization_level"], "Q4_K_M")
                self.assertIn("modified_at", model)
                show = client.post("/api/show", json={"model": ALIAS}).json()
                self.assertEqual(show["capabilities"], ["completion"])
                self.assertEqual(show["details"]["parameter_size"], "8B")
                self.assertEqual(client.get("/v1/models").json()["data"][0]["id"], ALIAS)

    def test_readiness_failure_hides_model(self):
        for health, status in [(httpx.Response(503, json={"error": "loading"}), 503),
                               (httpx.Response(200, json={"status": "loading"}), 503),
                               (httpx.Response(200, text="bad json"), 502),
                               (httpx.Response(200, json=[]), 502)]:
            with self.subTest(status=status):
                self.health_response = health
                with self.client() as client:
                    response = client.get("/api/tags")
                self.assertEqual(response.status_code, status)
                self.assertIn("error", response.json())

    def test_unknown_model_does_not_reach_upstream(self):
        with self.client() as client:
            for path in ("/api/show", "/api/chat", "/api/generate", "/api/embed", "/v1/chat/completions"):
                with self.subTest(path=path):
                    response = client.post(path, json={"model": "missing"})
                    self.assertEqual(response.status_code, 404)
        self.assertEqual(self.requests, [])

    def test_nonstream_chat_sampling_reasoning_and_tool_calls(self):
        self.response = httpx.Response(200, json=completion(None, "tool_calls", reasoning_content="Consider weather",
            tool_calls=[{"function": {"name": "weather", "arguments": '{"city":"Paris"}'}}]))
        response = self.post(messages=[{"role": "user", "content": "weather?"}], stream=False,
                             options={"num_predict": 64, "temperature": 0.2, "stop": ["END"]}, format="json")
        self.assertEqual(response.status_code, 200)
        output = response.json()
        self.assertEqual(output["message"]["content"], "")
        self.assertEqual(output["message"]["thinking"], "Consider weather")
        self.assertEqual(output["message"]["tool_calls"][0]["function"]["arguments"], {"city": "Paris"})
        self.assertTrue(output["done"])
        self.assertEqual((output["prompt_eval_count"], output["eval_count"]), (7, 3))
        self.assertGreaterEqual(output["total_duration"], 0)
        upstream = self.payload()
        self.assertEqual(upstream["max_tokens"], 64)
        self.assertEqual(upstream["response_format"], {"type": "json_object"})
        self.assertEqual(upstream["stop"], ["END"])

    def test_chat_tool_round_trip_uses_matching_call_id(self):
        response = self.post(stream=False, messages=[
            {"role": "assistant", "content": "", "tool_calls": [
                {"function": {"name": "weather", "arguments": {"city": "Paris"}}}]},
            {"role": "tool", "tool_name": "weather", "content": "sunny"}])
        self.assertEqual(response.status_code, 200)
        messages = self.payload()["messages"]
        self.assertEqual(messages[0]["tool_calls"][0]["id"], messages[1]["tool_call_id"])
        self.assertEqual(json.loads(messages[0]["tool_calls"][0]["function"]["arguments"]), {"city": "Paris"})

    def test_ambiguous_tool_result_rejected(self):
        response = self.post(stream=False, messages=[
            {"role": "assistant", "tool_calls": [
                {"function": {"name": "weather", "arguments": {}}},
                {"function": {"name": "time", "arguments": {}}}]},
            {"role": "tool", "content": "result"}])
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self.requests, [])

    def test_templated_generation_has_system_and_images(self):
        response = self.post("/api/generate", prompt="Describe", system="Be concise", images=["iVBORtest"], stream=False)
        self.assertEqual(response.json()["response"], "Hello")
        self.assertEqual(self.requests[-1].url.path, "/v1/chat/completions")
        messages = self.payload()["messages"]
        self.assertEqual(messages[0], {"role": "system", "content": "Be concise"})
        self.assertEqual(messages[1]["content"][1]["image_url"]["url"], "data:image/png;base64,iVBORtest")

    def test_raw_generation_uses_completion_endpoint(self):
        self.response = httpx.Response(200, json={"choices": [{"text": "raw output", "finish_reason": "length"}]})
        response = self.post("/api/generate", prompt="verbatim", raw=True, stream=False, options={"num_predict": -1})
        self.assertEqual(response.json()["response"], "raw output")
        self.assertEqual(response.json()["done_reason"], "length")
        self.assertEqual(self.requests[-1].url.path, "/v1/completions")
        self.assertEqual(self.payload()["prompt"], "verbatim")
        self.assertNotIn("messages", self.payload())
        self.assertNotIn("max_tokens", self.payload())

    def test_templated_generation_preserves_thinking_and_json_schema(self):
        self.response = httpx.Response(200, json=completion("answer", reasoning_content="reasoning"))
        schema = {"type": "object", "properties": {"answer": {"type": "string"}}}
        response = self.post("/api/generate", prompt="answer", stream=False, format=schema)
        self.assertEqual(response.json()["thinking"], "reasoning")
        self.assertEqual(self.payload()["response_format"], {
            "type": "json_schema", "json_schema": {"name": "response", "schema": schema}})

    def test_stream_content_reasoning_fragmented_tools_and_trailing_usage(self):
        events = [
            {"choices": [{"delta": {"reasoning_content": "Think"}, "finish_reason": None}]},
            {"choices": [{"delta": {"content": "Hello 世界 "}, "finish_reason": None}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"name": "weather", "arguments": '{"ci'}}]}}]},
            {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": 'ty":"Paris"}'}}]}, "finish_reason": "tool_calls"}]},
            {"choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 9}},
            "[DONE]",
        ]
        # Deliberately split in the middle of UTF-8/JSON framing, independent of SSE event boundaries.
        wire = b": keepalive\n\n" + b"".join(event(value) for value in events)
        unicode_split = wire.index("世".encode()) + 1
        stream = self.stream_response([wire[:19], wire[19:unicode_split], wire[unicode_split:]])
        rows = self.rows(self.post(messages=[{"role": "user", "content": "Hi"}]))
        self.assertEqual(rows[0]["message"]["thinking"], "Think")
        self.assertEqual(rows[1]["message"]["content"], "Hello 世界 ")
        self.assertTrue(all(not row["done"] for row in rows[:-1]))
        self.assertTrue(rows[-1]["done"])
        self.assertEqual(rows[-1]["message"]["tool_calls"][0]["function"]["arguments"], {"city": "Paris"})
        self.assertEqual((rows[-1]["prompt_eval_count"], rows[-1]["eval_count"]), (11, 9))
        self.assertEqual(self.payload()["stream_options"], {"include_usage": True})
        self.assertTrue(stream.closed)

    def test_generate_stream_raw_and_templated(self):
        for raw in (False, True):
            with self.subTest(raw=raw):
                choice = {"text": "text"} if raw else {"delta": {"content": "text", "reasoning_content": "think"}}
                choice["finish_reason"] = "length"
                stream = self.stream_response([event({"choices": [choice]}), event("[DONE]")])
                rows = self.rows(self.post("/api/generate", prompt="hello", raw=raw))
                self.assertEqual(rows[0]["response"], "text")
                if not raw:
                    self.assertEqual(rows[0]["thinking"], "think")
                self.assertEqual(rows[-1]["done_reason"], "length")
                self.assertTrue(stream.closed)

    def test_malformed_aborted_and_error_streams_have_no_success_marker(self):
        cases = [([event("{bad")], None),
                 ([event(42)], None),
                 ([event({"choices": [42]})], None),
                 ([event({"choices": [{"delta": {"content": "partial"}}]})], None),
                 ([event("[DONE]")], None),
                 ([event({"error": {"message": "backend failed"}})], None),
                 ([event({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {
                     "name": "bad", "arguments": "{unfinished"}}]}, "finish_reason": "tool_calls"}]})], None),
                 ([event({"choices": [{"delta": {"content": "partial"}}]})], httpx.ReadError("broken"))]
        for chunks, error in cases:
            with self.subTest(chunks=chunks, error=error):
                stream = self.stream_response(chunks, error)
                rows = self.rows(self.post(messages=[{"role": "user", "content": "Hi"}]))
                self.assertIn("error", rows[-1])
                self.assertFalse(any(row.get("done") for row in rows))
                self.assertTrue(stream.closed)

    def test_malformed_nonstream_completion_is_gateway_error(self):
        for value in ({}, {"choices": []}, {"choices": [42]}, {"choices": [{"message": 42}]},
                      {"choices": [{"message": {"tool_calls": [
                      {"function": {"name": "bad", "arguments": "[]"}}]}}]}):
            with self.subTest(value=value):
                self.response = httpx.Response(200, json=value)
                self.assertEqual(self.post(stream=False, messages=[{"role": "user", "content": "Hi"}]).status_code, 502)

    def test_upstream_errors_timeouts_and_connections(self):
        for failure, status, message in [
            (httpx.Response(429, json={"error": "busy"}), 429, "busy"),
            (httpx.Response(503, text="loading"), 503, "loading"),
            (httpx.Response(503, json=["loading"]), 503, "loading"),
            (httpx.ReadTimeout("slow"), 504, "timed out"),
            (httpx.ConnectError("offline"), 502, "unreachable")]:
            with self.subTest(status=status):
                self.response = failure
                response = self.post(stream=False, messages=[{"role": "user", "content": "Hi"}])
                self.assertEqual(response.status_code, status)
                self.assertIn(message, response.json()["error"])

    def test_empty_requests_are_readiness_only_loads(self):
        with self.client() as client:
            for path, fields in [("/api/chat", {"messages": []}), ("/api/generate", {"prompt": ""})]:
                for streaming in (True, False):
                    with self.subTest(path=path, streaming=streaming):
                        response = client.post(path, json={"model": ALIAS, "stream": streaming, "keep_alive": "5m", **fields})
                        output = self.rows(response)[0] if streaming else response.json()
                        self.assertTrue(output["done"])
                        self.assertEqual(output["done_reason"], "load")
        self.assertTrue(all(request.url.path == "/health" for request in self.requests))

    def test_zero_keepalive_rejects_unload(self):
        with self.client() as client:
            for value in (0, 0.0, "0", "0s", "0.0m", "00ms"):
                with self.subTest(value=value):
                    self.assertEqual(client.post("/api/chat", json={"model": ALIAS, "keep_alive": value}).status_code, 501)
        self.assertEqual(self.requests, [])

    def test_embedding_batch_is_sorted_and_usage_translated(self):
        self.response = httpx.Response(200, json={"data": [
            {"index": 1, "embedding": [0.2, 0.3]}, {"index": 0, "embedding": [0.8, 0.9]}],
            "usage": {"prompt_tokens": 6}})
        response = self.post("/api/embed", input=["first", "second"])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["embeddings"], [[0.8, 0.9], [0.2, 0.3]])
        self.assertEqual(response.json()["prompt_eval_count"], 6)
        self.assertEqual(self.payload(), {"model": ALIAS, "input": ["first", "second"]})

    def test_legacy_embedding(self):
        self.response = httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.1, 0.2]}]})
        response = self.post("/api/embeddings", prompt="text")
        self.assertEqual(response.json(), {"embedding": [0.1, 0.2]})

    def test_embedding_invalid_input_options_and_response(self):
        for fields in ({"input": 4}, {"input": ["x", 4]}, {"input": "x", "truncate": "no"},
                       {"input": "x", "options": "bad"}):
            with self.subTest(fields=fields):
                self.assertEqual(self.post("/api/embed", **fields).status_code, 400)
        self.response = httpx.Response(200, json={"data": [{"index": 0}]})
        self.assertEqual(self.post("/api/embed", input="text").status_code, 502)

    def test_openai_preserves_wire_bytes_status_and_relevant_headers(self):
        for content_type, wire in [("application/json", b'{ "choices": [], "custom": true }'),
                                   ("text/event-stream", b'data: {"choices":[]}\n\ndata: [DONE]\n\n')]:
            with self.subTest(content_type=content_type):
                stream = ByteStream([wire[:7], wire[7:]])
                self.response = httpx.Response(201, stream=stream, headers={
                    "content-type": content_type, "x-request-id": "test-id", "cache-control": "no-cache"})
                response = self.post("/v1/chat/completions", messages=[{"role": "user", "content": "hi"}], custom=True)
                self.assertEqual(response.status_code, 201)
                self.assertEqual(response.content, wire)
                self.assertEqual(response.headers["x-request-id"], "test-id")
                self.assertEqual(response.headers["cache-control"], "no-cache")
                self.assertTrue(self.payload()["custom"])
                self.assertTrue(stream.closed)

    def test_openai_endpoint_allowlist_and_json_validation(self):
        with self.client() as client:
            self.assertEqual(client.post("/v1/responses", json={"model": ALIAS}).status_code, 501)
            for body in (b"{oops", b"[]", b"null"):
                with self.subTest(body=body):
                    response = client.post("/v1/chat/completions", content=body)
                    self.assertEqual(response.status_code, 400)
                    self.assertIn("error", response.json())
        self.assertEqual(self.requests, [])

    def test_show_accepts_litellm_legacy_name(self):
        with self.client() as client:
            response = client.post("/api/show", json={"name": ALIAS})
            self.assertEqual(response.status_code, 200)
            self.assertIn("details", response.json())
            self.assertEqual(client.post("/api/show", json={"name": "missing"}).status_code, 404)
            self.assertEqual(client.post("/api/show", json={"model": ALIAS, "name": "missing"}).status_code, 400)

    def test_unsupported_lifecycle_calls_are_explicit(self):
        with self.client() as client:
            for path in ("/api/pull", "/api/create", "/api/delete"):
                self.assertEqual(client.post(path, json={"model": ALIAS}).status_code, 501)

    def test_ollama_validation_rejects_unsupported_or_malformed_fields(self):
        invalid = [
            {"stream": "false"}, {"options": {"num_predict": 0}},
            {"options": {"num_predict": True}}, {"options": "bad"}, {"options": []}, {"format": "xml"},
            {"messages": "hello"}, {"messages": [{"role": "user", "content": []}]},
            {"messages": [{"role": []}]},
            {"messages": [{"role": "user", "images": ["bad image"]}]},
            {"messages": [{"role": "user", "images": {}}]},
            {"messages": [{"role": "user", "unexpected": True}]}, {"tools": "bad"},
            {"tools": {}},
            {"think": True},
        ]
        with self.client() as client:
            for fields in invalid:
                with self.subTest(fields=fields):
                    response = client.post("/api/chat", json={"model": ALIAS, **fields})
                    self.assertEqual(response.status_code, 400)
        self.assertEqual(self.requests, [])

    def test_load_time_options_are_ignored_not_rejected(self):
        response = self.post("/api/chat", messages=[{"role": "user", "content": "hi"}], stream=False,
                             options={"num_ctx": 8192, "num_gpu": 99, "temperature": 0.1,
                                      "typical_p": 0.9, "mirostat": 2})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["x-bridge-ignored-options"], "num_ctx,num_gpu")
        sent = self.payload()
        self.assertNotIn("num_ctx", sent)
        self.assertEqual((sent["temperature"], sent["typical_p"], sent["mirostat"]), (0.1, 0.9, 2))

    def test_stream_carries_the_ignored_options_header(self):
        self.stream_response([event({"choices": [{"delta": {"content": "x"}, "finish_reason": "stop"}]}),
                              event("[DONE]")])
        response = self.post("/api/chat", messages=[{"role": "user", "content": "hi"}],
                             options={"num_ctx": 4096})
        self.assertEqual(response.headers["x-bridge-ignored-options"], "num_ctx")

    def test_embedding_accepts_options_truncate_and_keep_alive(self):
        self.response = httpx.Response(200, json={"data": [{"index": 0, "embedding": [0.5]}]})
        response = self.post("/api/embed", input="x", truncate=True, keep_alive="5m",
                             options={"num_ctx": 512})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.headers["x-bridge-ignored-options"], "num_ctx")
        self.assertEqual(self.post("/api/embed", input="x", keep_alive=0).status_code, 501)

    def test_ps_lists_the_resident_model(self):
        with self.client() as client:
            models = client.get("/api/ps").json()["models"]
        self.assertEqual([m["model"] for m in models], [ALIAS])
        self.assertIn("expires_at", models[0])
        self.health_response = httpx.Response(503, json={"error": "loading"})
        with self.client() as client:
            self.assertEqual(client.get("/api/ps").json(), {"models": []})

    def test_unknown_parameter_size_comes_from_llama_server(self):
        self.config = Config("http://llama.invalid:8081", ALIAS, parameter_size="unknown",
                             family="qwen2", quantization="unknown")
        meta = {"data": [{"id": ALIAS, "meta": {"n_params": 7615616512, "n_ctx_train": 32768,
                                                 "size": 4683073536}}]}
        self.response = lambda request: httpx.Response(200, json=meta)
        with self.client() as client:
            details = client.get("/api/tags").json()["models"][0]["details"]
            self.assertEqual(details["parameter_size"], "7.6B")
            self.assertEqual(details["quantization_level"], "")
            show = client.post("/api/show", json={"model": ALIAS}).json()
            self.assertEqual(show["model_info"]["general.parameter_count"], 7615616512)
            self.assertEqual(show["model_info"]["qwen2.context_length"], 32768)
            client.get("/api/tags")
        # Cached after the first success: /v1/models is asked once.
        self.assertEqual(sum(r.url.path == "/v1/models" for r in self.requests), 1)

    def test_parameter_size_lookup_failure_is_harmless(self):
        self.config = Config("http://llama.invalid:8081", ALIAS, parameter_size="")
        self.response = httpx.Response(500, text="nope")
        with self.client() as client:
            self.assertEqual(client.get("/api/tags").json()["models"][0]["details"]["parameter_size"], "")

    def test_format_params(self):
        from bridge import format_params
        self.assertEqual(format_params(8030261248), "8.0B")
        self.assertEqual(format_params(494032768), "494M")
        self.assertEqual(format_params(None), "")

    def test_raw_generation_conflicting_features_rejected(self):
        for fields in ({"system": "system"}, {"images": ["iVBORtest"]}, {"format": "json"}, {"raw": "true"}):
            with self.subTest(fields=fields):
                self.assertEqual(self.post("/api/generate", prompt="x", **{"raw": True, **fields}).status_code, 400)

    def test_disconnect_closes_upstream_stream(self):
        async def exercise(path):
            stream = ByteStream([event({"choices": [{"delta": {"content": "first"}}]})], block=True)
            transport = httpx.MockTransport(lambda request: httpx.Response(200, stream=stream))
            app = create_app(self.config, transport=transport)
            disconnected = asyncio.Event()
            sent_request = False
            sent = []

            async def receive():
                nonlocal sent_request
                if not sent_request:
                    sent_request = True
                    return {"type": "http.request", "body": json.dumps({"model": ALIAS,
                        "messages": [{"role": "user", "content": "Hi"}]}).encode(), "more_body": False}
                await disconnected.wait()
                return {"type": "http.disconnect"}

            async def send(message):
                sent.append(message)
                if message["type"] == "http.response.body" and message.get("body"):
                    disconnected.set()

            scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.3"},
                     "method": "POST", "path": path, "raw_path": path.encode(), "query_string": b"",
                     "headers": [(b"content-type", b"application/json")], "scheme": "http",
                     "server": ("testserver", 80), "client": ("testclient", 123)}
            async with app.router.lifespan_context(app):
                await asyncio.wait_for(app(scope, receive, send), timeout=2)
            self.assertTrue(stream.closed)
            self.assertTrue(any(message["type"] == "http.response.body" for message in sent))

        for path in ("/api/chat", "/v1/chat/completions"):
            with self.subTest(path=path):
                asyncio.run(exercise(path))


if __name__ == "__main__":
    unittest.main()
