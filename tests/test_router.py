"""Unit tests for services/ollama-router/router.py.

Every upstream (Ollama hosts, LiteLLM) is an httpx.MockTransport, so nothing
leaves the process. Run: python3 -m pytest -q tests/test_router.py
"""
import importlib.util
import asyncio
import json
import time
import re
import os
import sys
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
HOST_A = "http://10.0.0.1:11434"
HOST_B = "http://10.0.0.2:11434"


def load_router(monkeypatch, **env):
    base = {
        "ROUTER_INI": str(ROOT / "services/ollama-router/router.ini"),
        "MODEL_SERVERS": f"{HOST_A},{HOST_B}",
        "ROUTER_API_KEY": "",
        "LMSTUDIO_API_TOKEN": "",
        "STRATA_API_KEY": "",
        "BASALT_API_KEY": "",
        "MAYA_API_KEY": "",
        "XOLOTL_API_KEY": "",
        "LITELLM_BASE_URL": "http://litellm.test",
        "OPENAI_API_KEY": "",
        "ANTHROPIC_API_KEY": "",
        "GEMINI_API_KEY": "",
        "CLOUD_OPENAI_MODELS": "",
        "CLOUD_ANTHROPIC_MODELS": "",
        "CLOUD_GEMINI_MODELS": "",
        "SUBSCRIPTION_GATEWAY_BASE_URL": "",
    }
    base.update(env)
    for key, value in base.items():
        monkeypatch.setenv(key, value)
    spec = importlib.util.spec_from_file_location(
        "router_under_test", ROOT / "services/ollama-router/router.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["router_under_test"] = module
    spec.loader.exec_module(module)
    return module


def tags(*models):
    return {"models": [{"name": name, "details": {"parameter_size": size, "family": fam}}
                       for name, size, fam in models]}


def streamed(status, payload, headers=None):
    """A response whose body is still a stream, as a real transport returns it
    (an httpx.Response(json=...) is pre-read and cannot be aiter_raw()'d)."""
    data = json.dumps(payload).encode()
    headers = dict(headers or {}, **{"content-type": "application/json",
                                     "content-length": str(len(data))})
    return httpx.Response(status, headers=headers, stream=httpx.ByteStream(data))


class Upstream:
    """Scriptable fake for every backend the router talks to."""

    def __init__(self):
        self.inventory = {
            HOST_A: tags(("qwen3:14b", "14.8B", "qwen3")),
            HOST_B: tags(("qwen3:14b", "14.8B", "qwen3")),
        }
        self.running = {}       # host -> names returned by /api/ps; absent = unsupported
        self.chat = {}          # host -> status code or "connect" / "timeout"
        self.chat_errors = {}   # host -> custom error body
        self.calls = []
        self.capabilities = {}  # model name -> list, None (404) or "boom"
        self.tool_less = set()  # models whose chat rejects a tool request
        self.show_calls = []
        self.show_extra = {}    # model name -> more /api/show fields (model_info, parameters)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        host = f"{request.url.scheme}://{request.url.host}:{request.url.port}"
        self.calls.append((host, request.url.path, dict(request.headers),
                           request.content))
        if request.url.path == "/api/tags":
            if host in self.inventory:
                return httpx.Response(200, json=self.inventory[host])
            raise httpx.ConnectError("refused", request=request)
        if request.url.path == "/api/ps":
            if host in self.running:
                return httpx.Response(200, json={"models": [{"name": name}
                                                            for name in self.running[host]]})
            return httpx.Response(404)
        if request.url.path == "/v1/chat/completions":
            behaviour = self.chat.get(host, 200)
            if behaviour == "connect":
                raise httpx.ConnectError("refused", request=request)
            if behaviour == "timeout":
                raise httpx.ConnectTimeout("timed out", request=request)
            body = json.loads(request.content)
            if body.get("tools") and body["model"] in self.tool_less:
                # What Ollama answers for a model without tool support.
                return streamed(400, {"error": {"message": (
                    f"registry.ollama.ai/library/{body['model']} does not support tools"),
                    "type": "api_error"}})
            if behaviour == 400 and host in self.chat_errors:
                return streamed(400, self.chat_errors[host])
            return streamed(behaviour, {"served_by": host, "model": body["model"]},
                            {"x-upstream": "yes", "connection": "close"})
        if request.url.path == "/api/show":
            name = json.loads(request.content)["model"]
            self.show_calls.append((host, name))
            caps = self.capabilities.get(name)
            if caps is None:
                return httpx.Response(404, json={"error": "not found"})
            if caps == "boom":
                raise httpx.ConnectError("refused", request=request)
            return httpx.Response(200, json={"capabilities": caps, **self.show_extra.get(name, {})})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": [{"id": "fast"}]})
        return httpx.Response(404)


@pytest.fixture
def router(monkeypatch):
    return load_router(monkeypatch)


@pytest.fixture
def served(router):
    upstream = Upstream()
    router._HTTP["transport"] = httpx.MockTransport(upstream)
    with TestClient(router.app) as client:
        yield router, upstream, client


def user(text, **extra):
    return dict({"role": "user", "content": text}, **extra)


# --- keyword matching ------------------------------------------------------------
@pytest.mark.parametrize("prompt", [
    "Write a short description of my Netflix subscription",
    "Please encode this in a haiku",
    "Explain the transcript of the debate",
    "Can you improve this sentence?",
])
def test_substrings_inside_other_words_do_not_match(router, prompt):
    need = router.classify_request([user(prompt)])
    assert need["class"] == "fast" and need["code"] is False


@pytest.mark.parametrize("prompt", [
    "fix this bug", "there are two bugs here", "why does it not compile",
    "def foo():\n    return 1", "write a bash script",
])
def test_real_code_prompts_still_match(router, prompt):
    assert router.classify_request([user(prompt)])["code"] is True


def test_trailing_space_keyword_needs_whitespace(router):
    assert router.classify_request([user("the default value")])["code"] is False
    assert router.classify_request([user("def main(): pass")])["code"] is True


def test_phrase_keyword_spans_any_whitespace(router):
    need = router.classify_request([user("give me a step  by\nstep proof")])
    assert need["class"] == "xlarge"


def test_whole_word_heavy_keyword_still_promotes(router):
    assert router.classify_request([user("Prove that sqrt 2 is irrational")])["class"] == "xlarge"
    assert router.classify_request([user("analyze these numbers")])["class"] == "large"


# --- classification scope ---------------------------------------------------------
def test_system_prompt_no_longer_pins_the_tier(router):
    messages = [{"role": "system", "content": "Analyze carefully. " * 5}, user("hi")]
    assert router.classify_request(messages)["class"] == "fast"


def test_only_the_latest_user_turn_is_judged(router):
    messages = [user("analyze the architecture"), {"role": "assistant", "content": "ok"},
                user("thanks!")]
    assert router.classify_request(messages)["class"] == "fast"


def test_conversation_scope_keeps_old_behaviour(router, monkeypatch):
    monkeypatch.setattr(router, "CLASSIFY_SCOPE", "conversation")
    messages = [{"role": "system", "content": "Analyze carefully."}, user("hi")]
    assert router.classify_request(messages)["class"] == "large"


def test_an_earlier_image_still_needs_vision(router):
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}
    messages = [{"role": "user", "content": [{"type": "text", "text": "what is this"}, image]},
                {"role": "assistant", "content": "a cat"}, user("what colour is it?")]
    assert router.classify_request(messages)["vision"] is True


def test_litellm_path_uses_the_same_classifier(router):
    assert router.analyze_complexity("hello") == router.TIER_FAST
    assert router.analyze_complexity("please analyze this") == router.TIER_LARGE
    assert router.analyze_complexity("improve this") == router.TIER_FAST


def test_cloud_models_are_explicit_and_use_litellm(monkeypatch):
    router = load_router(monkeypatch, OPENAI_API_KEY="provider-secret",
                         CLOUD_OPENAI_MODELS="gpt-example")
    calls = []

    def upstream(request):
        calls.append((request.url.path, request.headers.get("authorization"),
                      json.loads(request.content).get("model") if request.content else None))
        if request.url.path == "/v1/chat/completions":
            return streamed(200, {"model": "gpt-example"})
        if request.url.path == "/api/tags":
            return httpx.Response(200, json=tags(("local:7b", "7B", "llama")))
        return httpx.Response(404)

    router._HTTP["transport"] = httpx.MockTransport(upstream)
    with TestClient(router.app) as client:
        listed = client.get("/v1/models")
        response = chat(client, model="openai/gpt-example")
    assert "openai/gpt-example" in {entry["id"] for entry in listed.json()["data"]}
    assert response.status_code == 200
    assert response.headers["x-router-mode"] == "cloud"
    assert calls[-1] == ("/v1/chat/completions", None, "openai/gpt-example")


def test_cloud_model_requires_configured_key(monkeypatch):
    router = load_router(monkeypatch, CLOUD_GEMINI_MODELS="gemini-example")
    router._HTTP["transport"] = httpx.MockTransport(Upstream())
    with TestClient(router.app) as client:
        assert "gemini/gemini-example" not in {entry["id"] for entry in
                                                client.get("/v1/models").json()["data"]}
        response = chat(client, model="gemini/gemini-example")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "cloud_model_not_configured"


def test_local_model_with_cloud_prefix_is_not_refused(monkeypatch):
    # LM Studio names gpt-oss "openai/gpt-oss-20b"; with no OpenAI key (or a
    # key without that model) it must still reach the local server by name.
    router = load_router(monkeypatch)
    upstream = Upstream()
    upstream.inventory[HOST_A] = tags(("openai/gpt-oss-20b", "20B", "gptoss"))
    router._HTTP["transport"] = httpx.MockTransport(upstream)
    with TestClient(router.app) as client:
        response = chat(client, model="openai/gpt-oss-20b")
        missing = chat(client, model="openai/not-local")
    assert response.status_code == 200
    assert response.json() == {"served_by": HOST_A, "model": "openai/gpt-oss-20b"}
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "cloud_model_not_configured"


def test_subscription_gateway_preserves_client_login(monkeypatch):
    router = load_router(monkeypatch, ROUTER_API_KEY="router-secret",
                         SUBSCRIPTION_GATEWAY_BASE_URL="http://localhost:5001")
    calls = []

    def gateway(request):
        if request.url.port != 5001:
            return httpx.Response(404)
        calls.append((request.url.path, request.headers.get("authorization"),
                      request.headers.get("x-litellm-api-key"),
                      request.headers.get("x-router-api-key"),
                      request.headers.get("x-router-subscription")))
        return streamed(200, {"ok": True})

    router._HTTP["transport"] = httpx.MockTransport(gateway)
    headers = {"x-router-subscription": "1", "x-router-api-key": "router-secret",
               "authorization": "Bearer client-oauth",
               "x-litellm-api-key": "Bearer gateway-key"}
    with TestClient(router.app) as client:
        for path in ("/v1/responses", "/v1/messages", "/v1/chat/completions"):
            response = client.post(path, headers=headers,
                                   json={"model": "subscriber-model", "messages": [user("hi")]})
            assert response.status_code == 200
            assert response.headers["x-router-mode"] == "subscription"
        assert client.get("/v1/models", headers=headers).status_code == 200
        denied = client.post("/v1/responses", headers={
            "x-router-subscription": "1", "authorization": "Bearer client-oauth"}, json={})
    assert denied.status_code == 401
    assert [c[0] for c in calls] == ["/v1/responses", "/v1/messages",
                                    "/v1/chat/completions", "/v1/models"]
    assert all(c[1:] == ("Bearer client-oauth", "Bearer gateway-key", None, None)
               for c in calls)


def test_subscription_gateway_requires_configuration(monkeypatch):
    router = load_router(monkeypatch, ROUTER_API_KEY="router-secret")
    with TestClient(router.app) as client:
        response = client.post("/v1/responses", headers={
            "x-router-subscription": "1", "x-router-api-key": "router-secret"}, json={})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "subscription_gateway_not_configured"


def test_subscription_gateway_rejects_plain_remote_http(monkeypatch):
    router = load_router(monkeypatch, SUBSCRIPTION_GATEWAY_BASE_URL="http://remote.test:4000")
    assert router.SUBSCRIPTION_GATEWAY_BASE == ""


# --- failover -----------------------------------------------------------------------
def test_connect_timeout_is_short(served):
    router, _, _ = served
    assert router.http_client().timeout.connect == 3
    assert router.http_client().timeout.read == 300


def chat(client, **body):
    payload = {"model": "auto", "messages": [user("hi")]}
    payload.update(body)
    return client.post("/v1/chat/completions", json=payload)


def served_hosts(upstream):
    return [h for h, path, _, _ in upstream.calls if path == "/v1/chat/completions"]


def test_dead_host_fails_over_and_is_marked_down(served):
    router, upstream, client = served
    upstream.chat[HOST_A] = "connect"
    upstream.chat[HOST_B] = 200
    for _ in range(2):   # rotation would otherwise alternate A/B
        response = chat(client)
        assert response.status_code == 200
        assert response.json()["served_by"] == HOST_B
    assert router.INVENTORY["servers"][HOST_A]["up"] is False
    # After being marked down, A is not even tried again.
    assert served_hosts(upstream).count(HOST_A) == 1


def test_connect_timeout_also_marks_down(served):
    router, upstream, client = served
    upstream.chat[HOST_A] = "timeout"
    upstream.chat[HOST_B] = "timeout"
    response = chat(client)
    assert response.status_code == 502
    assert not router.INVENTORY["servers"][HOST_A]["up"]
    assert not router.INVENTORY["servers"][HOST_B]["up"]


@pytest.mark.parametrize("status", [404, 500, 503])
def test_retryable_status_falls_forward(served, status):
    _, upstream, client = served
    upstream.chat = {HOST_A: status, HOST_B: status}
    response = chat(client)
    # The last candidate's answer is returned as-is.
    assert response.status_code == status
    assert sorted(served_hosts(upstream)) == sorted([HOST_A, HOST_B])


def test_client_errors_are_not_retried(served):
    _, upstream, client = served
    upstream.chat = {HOST_A: 400, HOST_B: 400}
    assert chat(client).status_code == 400
    assert len(served_hosts(upstream)) == 1


def test_discovery_brings_a_host_back(served):
    router, upstream, client = served
    router.mark_server_down(HOST_A, "test")
    assert client.post("/routing/refresh").status_code == 200
    assert router.INVENTORY["servers"][HOST_A]["up"] is True


# --- proxy hygiene --------------------------------------------------------------------
def test_upstream_framing_headers_are_not_copied(served):
    _, _, client = served
    response = chat(client)
    assert response.headers["x-upstream"] == "yes"
    assert response.headers["x-router-mode"] == "discovery"
    assert response.headers.get("connection") != "close"
    assert json.loads(response.content)["model"] == "qwen3:14b"


def test_vision_without_vision_model_is_flagged(served):
    _, _, client = served
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}
    response = chat(client, messages=[{"role": "user", "content": [image]}])
    assert response.status_code == 200
    assert response.headers["x-router-warning"] == "no-vision-model"


def test_vision_strict_rejects(served, monkeypatch):
    router, _, client = served
    monkeypatch.setattr(router, "VISION_STRICT", True)
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}
    response = chat(client, messages=[{"role": "user", "content": [image]}])
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "no_vision_model"


def test_vision_model_is_preferred_without_warning(served):
    router, upstream, client = served
    upstream.inventory[HOST_B] = tags(("llava:13b", "13B", "llama"))
    client.post("/routing/refresh")
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}
    response = chat(client, messages=[{"role": "user", "content": [image]}])
    assert response.json()["model"] == "llava:13b"
    assert "x-router-warning" not in response.headers


def test_non_object_body_is_a_400(served):
    _, _, client = served
    assert client.post("/v1/chat/completions", json=[1, 2]).status_code == 400


# --- authentication ----------------------------------------------------------------------
def test_api_key_is_enforced(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "ROUTER_API_KEY", "s3cret")
    assert chat(client).status_code == 401
    assert client.post("/routing/refresh").status_code == 401
    assert client.get("/healthz").status_code == 200
    ok = client.post("/v1/chat/completions", headers={"Authorization": "Bearer s3cret"},
                     json={"model": "auto", "messages": [user("hi")]})
    assert ok.status_code == 200
    wrong = client.post("/v1/chat/completions", headers={"Authorization": "Bearer nope"},
                        json={"model": "auto", "messages": [user("hi")]})
    assert wrong.status_code == 401


def test_router_key_is_never_sent_to_ollama(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "ROUTER_API_KEY", "s3cret")
    client.post("/v1/chat/completions", headers={"Authorization": "Bearer s3cret"},
                json={"model": "auto", "messages": [user("hi")]})
    sent = [h for host, path, h, _ in upstream.calls if path == "/v1/chat/completions"]
    assert sent and all("authorization" not in h for h in sent)


def test_no_key_means_open_access(served):
    _, _, client = served
    assert chat(client).status_code == 200


def test_loopback_detection(router):
    assert router._is_loopback("127.0.0.1")
    assert router._is_loopback("::1")
    assert router._is_loopback("localhost")
    assert not router._is_loopback("0.0.0.0")
    assert not router._is_loopback("192.168.1.5")


def test_host_and_port_come_from_env(monkeypatch):
    module = load_router(monkeypatch, ROUTER_HOST="127.0.0.1", ROUTER_PORT="8123")
    assert (module.ROUTER_HOST, module.ROUTER_PORT) == ("127.0.0.1", 8123)


# --- LiteLLM fallback path ------------------------------------------------------------
def test_litellm_fallback_uses_the_classifier(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "INVENTORY", dict(router.INVENTORY, models=[]))
    captured = {}

    def litellm(request):
        captured["body"] = json.loads(request.content)
        captured["headers"] = dict(request.headers)
        captured["timeout"] = request.extensions["timeout"]
        return streamed(200, {"ok": True})

    router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(litellm))
    response = chat(client, messages=[user("please analyze this")])
    assert response.headers["x-router-mode"] == "litellm"
    assert captured["body"]["model"] == router.TIER_LARGE
    assert "x-litellm-num-retries" not in captured["headers"]
    assert captured["timeout"]["connect"] == 3
    # No Kindi server is configured, so the LiteLLM hop keeps read_timeout_seconds.
    assert captured["timeout"]["read"] == router.READ_TIMEOUT == 300


def test_litellm_read_timeout_follows_configured_kindi(router, monkeypatch):
    """Only an assigned Kindi deployment extends the LiteLLM hop."""
    monkeypatch.setattr(router, "SERVERS", ["http://10.0.0.51:11434"])
    monkeypatch.setenv("MODEL_SERVERS", "kindi+http://10.0.0.14:8093")
    assert router.litellm_read_timeout() == router.READ_TIMEOUT
    monkeypatch.setenv("BACKEND_FAST", "http://10.0.0.51:11434,kindi+http://10.0.0.14:8093")
    assert router.litellm_read_timeout("fast") == router.KINDI_READ_TIMEOUT == 3600
    assert router.litellm_read_timeout() == router.READ_TIMEOUT


def test_litellm_kindi_tier_caps_retries(served, monkeypatch):
    router, _, client = served
    monkeypatch.setattr(router, "INVENTORY", dict(router.INVENTORY, models=[]))
    monkeypatch.setenv("BACKEND_LARGE", "kindi+http://10.0.0.14:8093")
    captured = {}

    def litellm(request):
        captured.update(request.headers)
        captured["read_timeout"] = request.extensions["timeout"]["read"]
        return streamed(200, {"ok": True})

    router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(litellm))
    client.post("/v1/chat/completions", headers={"X-LiteLLM-Num-Retries": "9",
                                                 "X-LiteLLM-Timeout": "10"},
                json={"model": "auto", "messages": [user("please analyze this")]})
    assert captured["x-litellm-num-retries"] == "1"
    # The timeout comes from each deployment, so the tier's other servers keep
    # LiteLLM's own; the client's header is dropped.
    assert "x-litellm-timeout" not in captured
    assert captured["read_timeout"] == router.KINDI_READ_TIMEOUT


def test_litellm_embeddings_keep_normal_timeout_with_kindi_tier(served, monkeypatch):
    router, _, client = served
    monkeypatch.setenv("BACKEND_FAST", "kindi+http://10.0.0.14:8093")
    captured = {}

    def litellm(request):
        captured["read_timeout"] = request.extensions["timeout"]["read"]
        return streamed(200, {"data": []})

    router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(litellm))
    response = client.post("/v1/embeddings", json={"model": "nomic-embed", "input": "hi"})
    assert response.status_code == 200
    assert captured["read_timeout"] == router.READ_TIMEOUT


def test_kindi_read_timeout_never_shortens_read_timeout(monkeypatch, tmp_path):
    """kindi_read_timeout_seconds comes from router.ini and is never below
    read_timeout_seconds."""
    ini = tmp_path / "router.ini"
    ini.write_text("[http]\nread_timeout_seconds = 7200\nkindi_read_timeout_seconds = 1800\n")
    module = load_router(monkeypatch, ROUTER_INI=str(ini))
    assert module.READ_TIMEOUT == 7200 and module.KINDI_READ_TIMEOUT == 7200
    ini.write_text("[http]\nkindi_read_timeout_seconds = 2400\n")
    module = load_router(monkeypatch, ROUTER_INI=str(ini))
    assert (module.READ_TIMEOUT, module.KINDI_READ_TIMEOUT) == (300, 2400)


def test_inventory_publishes_the_kindi_budget(served):
    """The tool targets' dispatchers compare their own Kindi budget with this."""
    router, _, client = served
    assert client.get("/routing/inventory").json()["kindi_read_timeout_seconds"] == router.KINDI_READ_TIMEOUT


def test_os_env_is_restored():
    # Guard against leaking env between modules in the same pytest run.
    assert "ROUTER_API_KEY" not in os.environ or os.environ["ROUTER_API_KEY"] == ""


# --- capability-based detection ---------------------------------------------------------
def test_vision_capability_beats_the_name(served):
    router, upstream, client = served
    upstream.inventory[HOST_B] = tags(("gemma3:12b", "12.2B", "gemma3"))
    upstream.capabilities["gemma3:12b"] = ["completion", "vision"]
    client.post("/routing/refresh")
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}
    response = chat(client, messages=[{"role": "user", "content": [image]}])
    assert response.json()["model"] == "gemma3:12b"
    assert "x-router-warning" not in response.headers


def test_embedding_capability_keeps_a_model_out_of_chat(served):
    router, upstream, client = served
    upstream.inventory[HOST_B] = tags(("granite-small:2b", "2B", "granite"))
    upstream.capabilities["granite-small:2b"] = ["embedding"]
    client.post("/routing/refresh")
    entry = [e for e in router.INVENTORY["models"] if e["server"] == HOST_B][0]
    assert entry["is_embedding"] and entry["capabilities"] == ["embedding"]
    assert all(e["name"] != "granite-small:2b" for e in router.rank_candidates(
        router.classify_request([user("hi")])))


def test_explicit_embedding_model_is_rejected_with_a_clear_error(served):
    router, upstream, client = served
    upstream.inventory[HOST_B] = tags(("granite-small:2b", "2B", "granite"))
    upstream.capabilities["granite-small:2b"] = ["embedding"]
    client.post("/routing/refresh")
    before = list(served_hosts(upstream))

    for name in ("granite-small:2b", "granite-small"):   # exact and bare name
        response = chat(client, model=name)
        assert response.status_code == 400
        error = response.json()["error"]
        assert error["code"] == "embedding_model_not_chat"
        assert "granite-small:2b" in error["message"] and "/v1/embeddings" in error["message"]
    # Nothing was sent to any backend, and no other model answered instead.
    assert list(served_hosts(upstream)) == before


def test_an_unknown_explicit_model_still_falls_back_to_routing(served):
    router, upstream, client = served
    response = chat(client, model="no-such-model:1b")
    assert response.status_code == 200


def test_embedding_only_match(router):
    router.INVENTORY["models"] = [
        router.build_entry("http://a", {"name": "embed:1b"}, ["embedding"]),
        router.build_entry("http://a", {"name": "both:7b"}, ["embedding"]),
        router.build_entry("http://b", {"name": "both:7b"}, ["completion"]),
    ]
    assert router.embedding_only_match("embed:1b") == "embed:1b"
    assert router.embedding_only_match("EMBED") == "embed:1b"
    assert router.embedding_only_match("both:7b") is None
    assert router.embedding_only_match("missing") is None
    assert router.embedding_only_match("") is None


def test_unknown_size_follows_known_out_of_band_model(router):
    unknown = router.build_entry("http://unknown", {"name": "mystery"})
    known = router.build_entry(
        "http://known",
        {"name": "model:27b", "details": {"parameter_size": "27B"}},
    )
    inventory = {
        "models": [unknown, known],
        "servers": {
            "http://unknown": {"up": True},
            "http://known": {"up": True},
        },
    }

    ranked = router.rank_candidates(
        {"class": "xlarge", "code": False, "vision": False}, inventory
    )

    assert [entry["name"] for entry in ranked] == ["model:27b", "mystery"]


def test_capabilities_override_a_misleading_name(router):
    entry = router.build_entry(HOST_A, {"name": "my-vision-finetune:7b"}, ["completion"])
    assert entry["is_vision"] is False
    entry = router.build_entry(HOST_A, {"name": "llava:7b"})
    assert entry["is_vision"] is True   # no capability data -> name fallback


def test_capabilities_are_cached_per_digest(served):
    import asyncio

    router, upstream, _ = served
    upstream.capabilities["qwen3:14b"] = ["completion", "tools"]
    upstream.show_calls.clear()
    router._CAPABILITIES.clear()
    router._SHOW_TIMES.clear()

    async def probe_twice():
        async with httpx.AsyncClient(transport=httpx.MockTransport(upstream)) as http:
            raw = upstream.inventory[HOST_A]["models"][0]
            await router.model_capabilities(http, HOST_A, raw)
            await router.model_capabilities(http, HOST_A, raw)

    asyncio.run(probe_twice())
    assert upstream.show_calls == [(HOST_A, "qwen3:14b")]


def test_capability_probe_failure_falls_back_and_retries(served):
    router, upstream, client = served
    router._CAPABILITIES.clear()
    upstream.inventory[HOST_B] = tags(("llava:13b", "13B", "llama"))
    upstream.capabilities["llava:13b"] = "boom"
    client.post("/routing/refresh")
    entry = [e for e in router.INVENTORY["models"] if e["server"] == HOST_B][0]
    assert entry["is_vision"] is True          # name heuristic
    before = len(upstream.show_calls)
    client.post("/routing/refresh")
    assert len(upstream.show_calls) > before   # transient failures are not cached


def test_capability_probe_can_be_disabled(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "CAPABILITY_PROBE", False)
    upstream.show_calls.clear()
    client.post("/routing/refresh")
    assert upstream.show_calls == []


def test_ollama_residency_comes_from_running_models(served):
    router, upstream, client = served
    upstream.inventory[HOST_A] = tags(("hot:8b", "8B", "qwen"),
                                      ("cold:8b", "8B", "qwen"))
    upstream.running[HOST_A] = ["hot:8b"]
    client.post("/routing/refresh")
    entries = {m["name"]: m for m in router.INVENTORY["models"] if m["server"] == HOST_A}
    assert entries["hot:8b"]["loaded"] is True
    assert entries["cold:8b"]["loaded"] is False
    # A bridge without /api/ps stays unknown, so it remains eligible.
    assert all(m["loaded"] is None for m in router.INVENTORY["models"]
               if m["server"] == HOST_B)


# --- regex keywords -------------------------------------------------------------------
@pytest.mark.parametrize("prompt,is_code", [
    ("What is a first class ticket?", False),
    ("Can you import my contacts?", False),
    ("class Foo:\n    pass", True),
    ("from os import path", True),
    ("some text\nimport numpy as np", True),
    ("```js\nconsole.log(1)\n```", True),
])
def test_code_shapes_not_prose(router, prompt, is_code):
    assert router.classify_request([user(prompt)])["code"] is is_code


def test_regex_keywords_keep_their_case(router, monkeypatch):
    pattern = router.keyword_pattern([r"re:\bfoo\S+"])
    assert pattern.search("FOObar") and not pattern.search("foo bar")


def test_invalid_regex_keyword_is_skipped(router):
    pattern = router.keyword_pattern(["re:(unclosed", "bug"])
    assert pattern.search("a bug")


# --- LM Studio servers ---------------------------------------------------------------
LMS = "lmstudio+http://10.0.0.9:1234"

LMS_V1 = {"models": [
    {"type": "llm", "key": "google/gemma-4-26b-a4b", "architecture": "gemma4",
     "quantization": {"name": "Q4_K_M", "bits_per_weight": 4}, "size_bytes": 17990911801,
     "params_string": "26B-A4B", "loaded_instances": [{"id": "google/gemma-4-26b-a4b"}],
     "capabilities": {"vision": True, "trained_for_tool_use": True}},
    {"type": "llm", "key": "qwen/qwen3-8b", "architecture": "qwen3",
     "params_string": "8B", "loaded_instances": []},
    {"type": "embedding", "key": "text-embedding-nomic-embed-text-v1.5",
     "params_string": None, "loaded_instances": []},
]}
LMS_V0 = {"data": [
    {"id": "qwen2.5-vl-7b", "type": "vlm", "arch": "qwen2vl", "quantization": "Q4_K_M", "state": "loaded"},
    {"id": "llama-3.1-8b", "type": "llm", "arch": "llama", "state": "not-loaded"},
    {"id": "nomic-embed", "type": "embeddings", "state": "not-loaded"},
]}


class LMStudio:
    """A fake LM Studio server: native v1, native v0, or only /v1/models."""

    def __init__(self, flavour="v1", token=None):
        self.flavour, self.token, self.calls = flavour, token, []
        self.chat_status = 200

    def __call__(self, request):
        self.calls.append((request.url.path, dict(request.headers)))
        if self.token and request.headers.get("authorization") != f"Bearer {self.token}":
            return httpx.Response(401, json={"error": "unauthorized"})
        path = request.url.path
        if path == "/api/v1/models" and self.flavour == "v1":
            return httpx.Response(200, json=LMS_V1)
        if path == "/api/v0/models" and self.flavour in ("v1", "v0"):
            return httpx.Response(200, json=LMS_V0)
        if path == "/v1/models":
            return httpx.Response(200, json={"data": [{"id": "plain-model-7b"}]})
        if path == "/v1/chat/completions":
            body = json.loads(request.content)
            return streamed(self.chat_status, {"served_by": "lmstudio", "model": body["model"]})
        return httpx.Response(404)


def lmstudio_router(monkeypatch, fake, **env):
    module = load_router(monkeypatch, MODEL_SERVERS=LMS, **env)
    module._HTTP["transport"] = httpx.MockTransport(fake)
    return module


def test_server_kind_and_base(router):
    assert router.server_kind(LMS) == "lmstudio"
    assert router.server_base(LMS) == "http://10.0.0.9:1234"
    assert router.server_kind(HOST_A) == "ollama" and router.server_base(HOST_A) == HOST_A


def test_moe_params_string(router):
    assert router.parse_params_billions("26B-A4B") == 26.0
    assert router.parse_params_billions("8B") == 8.0
    assert router.parse_params_billions("B8") == 0.0


def test_lmstudio_v1_discovery(monkeypatch):
    fake = LMStudio("v1")
    router = lmstudio_router(monkeypatch, fake)
    with TestClient(router.app):
        models = {e["name"]: e for e in router.INVENTORY["models"]}
    gemma = models["google/gemma-4-26b-a4b"]
    assert gemma["params_b"] == 26.0 and gemma["is_vision"] and gemma["loaded"] is True
    assert gemma["quantization"] == "Q4_K_M" and gemma["kind"] == "lmstudio"
    assert models["qwen/qwen3-8b"]["loaded"] is False and models["qwen/qwen3-8b"]["params_b"] == 8.0
    assert models["text-embedding-nomic-embed-text-v1.5"]["is_embedding"]
    # Ollama-only endpoints are never called on an LM Studio server.
    assert not any(path.startswith(("/api/tags", "/api/show")) for path, _ in fake.calls)


def test_lmstudio_v0_fallback(monkeypatch):
    router = lmstudio_router(monkeypatch, LMStudio("v0"))
    with TestClient(router.app):
        models = {e["name"]: e for e in router.INVENTORY["models"]}
    assert models["qwen2.5-vl-7b"]["is_vision"] and models["qwen2.5-vl-7b"]["loaded"]
    assert models["llama-3.1-8b"]["loaded"] is False
    assert models["nomic-embed"]["is_embedding"]


def test_lmstudio_openai_only_fallback(monkeypatch):
    router = lmstudio_router(monkeypatch, LMStudio("openai"))
    with TestClient(router.app):
        models = {e["name"]: e for e in router.INVENTORY["models"]}
    assert set(models) == {"plain-model-7b"}
    assert models["plain-model-7b"]["params_b"] == 7.0 and models["plain-model-7b"]["loaded"] is None


def test_lmstudio_dispatch_uses_plain_base_and_token(monkeypatch):
    fake = LMStudio("v1", token="lms-secret")
    router = lmstudio_router(monkeypatch, fake, LMSTUDIO_API_TOKEN="lms-secret")
    with TestClient(router.app) as client:
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-key"},
                               json={"model": "qwen/qwen3-8b", "messages": [user("hi")]})
    assert response.status_code == 200
    assert response.json()["model"] == "qwen/qwen3-8b"
    assert response.headers["x-router-server"] == LMS
    chat = [h for path, h in fake.calls if path == "/v1/chat/completions"]
    assert chat and chat[0]["authorization"] == "Bearer lms-secret"


def test_lmstudio_without_token_sends_none(monkeypatch):
    fake = LMStudio("v1")
    router = lmstudio_router(monkeypatch, fake)
    with TestClient(router.app) as client:
        client.post("/v1/chat/completions", json={"model": "qwen/qwen3-8b", "messages": [user("hi")]})
    assert all("authorization" not in h for _, h in fake.calls)


def test_loaded_model_wins_a_near_tie(router):
    need = {"class": "fast", "code": False, "vision": False}
    cold = router.build_entry(LMS, {"name": "a-8b", "details": {"parameter_size": "8B"}, "loaded": False})
    warm = router.build_entry(LMS, {"name": "b-8b", "details": {"parameter_size": "8B"}, "loaded": True})
    inv = {"models": [cold, warm], "servers": {LMS: {"up": True}}}
    assert router.rank_candidates(need, inv)[0]["name"] == "b-8b"


def test_loaded_only_skips_cold_models(router, monkeypatch):
    monkeypatch.setattr(router, "LMSTUDIO_LOADED_ONLY", True)
    need = {"class": "fast", "code": False, "vision": False}
    cold = router.build_entry(LMS, {"name": "a-8b", "details": {"parameter_size": "8B"}, "loaded": False})
    ollama = router.build_entry(HOST_A, {"name": "c-8b", "details": {"parameter_size": "8B"}})
    inv = {"models": [cold, ollama], "servers": {}}
    assert [e["name"] for e in router.rank_candidates(need, inv)] == ["c-8b"]


def test_mixed_ollama_and_lmstudio_inventory(monkeypatch):
    lms = LMStudio("v1")
    upstream = Upstream()

    def handler(request):
        if request.url.port == 1234:
            return lms(request)
        return upstream(request)

    router = load_router(monkeypatch, MODEL_SERVERS=f"{HOST_A},{LMS}")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app):
        kinds = {e["kind"] for e in router.INVENTORY["models"]}
        status = router.INVENTORY["servers"]
    assert kinds == {"ollama", "lmstudio"}
    assert status[HOST_A]["up"] and status[LMS]["up"]


def test_unreachable_lmstudio_is_down(monkeypatch):
    def refuse(request):
        raise httpx.ConnectError("refused", request=request)
    router = load_router(monkeypatch, MODEL_SERVERS=LMS)
    router._HTTP["transport"] = httpx.MockTransport(refuse)
    with TestClient(router.app):
        assert router.INVENTORY["servers"][LMS]["up"] is False


# --- Strata servers ----------------------------------------------------------
STRATA = "strata+http://10.0.0.8:8080"


@pytest.mark.parametrize("strata", [STRATA, "strata+http://10.0.0.8:11434"])
def test_strata_discovery_and_dispatch(monkeypatch, strata):
    calls = []

    def handler(request):
        calls.append((request.url.path, dict(request.headers)))
        if request.headers.get("authorization") != "Bearer strata-secret":
            return httpx.Response(401)
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": [
                {"id": "strata", "status": {"value": "loaded"},
                 "input_modalities": ["text", "image"]},
                {"id": "strata-alias", "status": "unloaded",
                 "input_modalities": ["text"]}]})
        if request.url.path == "/v1/chat/completions":
            return streamed(200, {"model": json.loads(request.content)["model"]})
        return httpx.Response(404)

    router = load_router(monkeypatch, MODEL_SERVERS=strata,
                         STRATA_API_KEY="strata-secret", ROUTER_API_KEY="client-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app) as client:
        models = {e["name"]: e for e in router.INVENTORY["models"]}
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-secret"},
                               json={"model": "strata", "messages": [user("hi")]})
    assert router.server_kind(strata) == "strata"
    assert router.server_base(strata) == strata.removeprefix("strata+")
    assert models["strata"]["kind"] == "strata"
    assert models["strata"]["params_b"] == 125
    assert models["strata"]["is_vision"] and models["strata"]["loaded"]
    assert models["strata-alias"]["loaded"] is False
    # Only Strata's default id gets the configured 125B; other unsized ids
    # (the Coder variant, aliases) stay unknown-size.
    assert models["strata-alias"]["params_b"] == 0
    assert response.status_code == 200 and response.json()["model"] == "strata"
    assert response.headers["x-router-server"] == strata
    assert [p for p, _ in calls] == ["/v1/models", "/v1/chat/completions"]
    assert all(h["authorization"] == "Bearer strata-secret" for _, h in calls)


def test_unreachable_strata_is_down(monkeypatch):
    def refuse(request):
        raise httpx.ConnectError("refused", request=request)
    router = load_router(monkeypatch, MODEL_SERVERS=STRATA)
    router._HTTP["transport"] = httpx.MockTransport(refuse)
    with TestClient(router.app):
        assert router.INVENTORY["servers"][STRATA]["up"] is False


def test_lmstudio_loaded_only_does_not_exclude_unloaded_strata(router, monkeypatch):
    monkeypatch.setattr(router, "LMSTUDIO_LOADED_ONLY", True)
    entry = router.build_entry(STRATA, {"name": "strata", "loaded": False})
    need = {"class": "xlarge", "code": False, "vision": False}
    inv = {"models": [entry], "servers": {STRATA: {"up": True}}}
    assert router.rank_candidates(need, inv) == [entry]


def _sizes_router(monkeypatch, tmp_path, ini_text, server, ids):
    custom = tmp_path / "router.ini"
    custom.write_text(ini_text)

    def handler(request):
        return httpx.Response(200, json={"data": [{"id": i} for i in ids]})

    router = load_router(monkeypatch, MODEL_SERVERS=server, ROUTER_INI=str(custom))
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app):
        return {e["name"]: e["params_b"] for e in router.INVENTORY["models"]}


def test_model_sizes_are_configurable(monkeypatch, tmp_path):
    ini = (ROOT / "services/ollama-router/router.ini").read_text()
    assert "\n[model_sizes]\n" in ini and "\nstrata = 125B\n" in ini
    # A blank value removes a built-in size; a sized tag still parses.
    sizes = _sizes_router(monkeypatch, tmp_path, ini.replace("\nstrata = 125B\n", "\nstrata =\n"),
                          STRATA, ["strata", "coder:62b"])
    assert sizes == {"strata": 0, "coder:62b": 62}
    # A custom alias gets a size from a line of its own, on any OpenAI kind.
    sizes = _sizes_router(monkeypatch, tmp_path, ini + "My-Basalt = 125B\n",
                          "basalt+http://10.0.0.7:8080", ["my-basalt", "qwen3.8-flash-next"])
    assert sizes == {"my-basalt": 125, "qwen3.8-flash-next": 125}



def test_strata_quant_ids_are_sized_but_coder_is_not(monkeypatch, tmp_path):
    """Strata names its qwen models qwen3.8-flash-next-<quant>; every quant is
    the 125B model, so each is size-banded. The Coder is smaller and unlisted."""
    ini = (ROOT / "services/ollama-router/router.ini").read_text()
    ids = ["qwen3.8-flash-next-q2_0", "qwen3.8-flash-next-iq2_xs",
           "qwen3.8-flash-next-iq3_xxs", "qwen3.8-flash-next-iq3_s",
           "qwen3.8-flash-next-coder-iq1_m"]
    sizes = _sizes_router(monkeypatch, tmp_path, ini, STRATA, ids)
    assert sizes == {**dict.fromkeys(ids[:4], 125), ids[4]: 0}
    # router.ini lists them too, so an operator sees (and can blank) each one.
    assert all(f"\n{i} = 125B\n" in ini for i in ids[:4])
    # The built-in defaults agree, for a router.ini without these lines.
    defaults = load_router(monkeypatch, ROUTER_INI=str(tmp_path / "missing.ini")).MODEL_SIZES
    assert all(defaults[i] == "125B" for i in ids[:4]) and ids[4] not in defaults


def test_model_sizes_default_without_a_router_ini(monkeypatch, tmp_path):
    router = load_router(monkeypatch, ROUTER_INI=str(tmp_path / "missing.ini"))
    assert router.MODEL_SIZES == {"strata": "125B", "qwen3.8-flash-next": "125B",
                                  "qwen3.8-flash-next-q2_0": "125B",
                                  "qwen3.8-flash-next-iq2_xs": "125B",
                                  "qwen3.8-flash-next-iq3_xxs": "125B",
                                  "qwen3.8-flash-next-iq3_s": "125B",
                                  "glm-5.3-flash": "321B", "deepseek-v4.1-flash": "552B",
                                  "qwen3.8-flash-next-avalon": "125B"}


def test_legacy_per_kind_size_keys_still_apply(monkeypatch, tmp_path):
    """router.ini files committed before [model_sizes] keep their meaning."""
    legacy = ("[discovery]\nstrata_default_params =\n"
              "basalt_default_id = my-basalt\nbasalt_default_params = 100B\n"
              "maya_default_id = glm-5.3-flash\nmaya_default_params = 300B\n")
    custom = tmp_path / "router.ini"
    custom.write_text(legacy)
    router = load_router(monkeypatch, ROUTER_INI=str(custom))
    quants = {f"qwen3.8-flash-next-{q}": "125B" for q in ("q2_0", "iq2_xs", "iq3_xxs", "iq3_s")}
    assert router.MODEL_SIZES == {"qwen3.8-flash-next": "125B", "my-basalt": "100B", **quants,
                                  "glm-5.3-flash": "300B", "deepseek-v4.1-flash": "552B",
                                  "qwen3.8-flash-next-avalon": "125B"}


@pytest.mark.parametrize("port", [8080, 11434])
def test_basalt_discovery_and_dispatch(monkeypatch, port):
    basalt = f"basalt+http://10.0.0.7:{port}"
    calls = []

    def handler(request):
        calls.append((request.url.path, dict(request.headers)))
        if request.headers.get("authorization") != "Bearer basalt-secret":
            return httpx.Response(401)
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": [
                {"id": "qwen3.8-flash-next", "status": {"value": "loaded"},
                 "architecture": {"input_modalities": ["text", "image"]}},
                {"id": "other-alias", "status": {"value": "unloaded"},
                 "architecture": {"input_modalities": ["text"]}}]})
        if request.url.path == "/v1/chat/completions":
            return streamed(200, {"model": json.loads(request.content)["model"]})
        return httpx.Response(404)

    router = load_router(monkeypatch, MODEL_SERVERS=basalt,
                         BASALT_API_KEY="basalt-secret", ROUTER_API_KEY="client-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app) as client:
        models = {e["name"]: e for e in router.INVENTORY["models"]}
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-secret"},
                               json={"model": "qwen3.8-flash-next", "messages": [user("hi")]})
        listed = client.get("/v1/models", headers={"Authorization": "Bearer client-secret"})
    assert router.server_kind(basalt) == "basalt"
    assert router.server_base(basalt) == f"http://10.0.0.7:{port}"
    assert models["qwen3.8-flash-next"]["kind"] == "basalt"
    assert models["qwen3.8-flash-next"]["params_b"] == 125
    assert models["qwen3.8-flash-next"]["is_vision"] and models["qwen3.8-flash-next"]["loaded"]
    assert models["other-alias"]["params_b"] == 0
    assert models["other-alias"]["loaded"] is False
    assert response.status_code == 200 and response.json()["model"] == "qwen3.8-flash-next"
    assert response.headers["x-router-server"] == basalt
    assert {e["id"]: e["owned_by"] for e in listed.json()["data"]}["qwen3.8-flash-next"] == "basalt"
    assert [p for p, _ in calls] == ["/v1/models", "/v1/chat/completions"]
    assert all(h["authorization"] == "Bearer basalt-secret" for _, h in calls)


def test_maya_discovery_and_dispatch(monkeypatch):
    maya = "maya+http://10.0.0.9:8080"
    calls = []

    def handler(request):
        calls.append((request.url.path, request.headers.get("authorization")))
        if request.headers.get("authorization") != "Bearer maya-secret":
            return httpx.Response(401)
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": [
                {"id": "glm-5.3-flash", "status": {"value": "loaded"},
                 "architecture": {"input_modalities": ["text", "image"]}},
                {"id": "custom-alias", "status": {"value": "unloaded"}}]})
        if request.url.path == "/v1/chat/completions":
            return streamed(200, {"model": json.loads(request.content)["model"]})
        return httpx.Response(404)

    router = load_router(monkeypatch, MODEL_SERVERS=maya,
                         MAYA_API_KEY="maya-secret", ROUTER_API_KEY="client-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app) as client:
        models = {e["name"]: e for e in router.INVENTORY["models"]}
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-secret"},
                               json={"model": "glm-5.3-flash", "messages": [user("hi")]})
    assert router.server_kind(maya) == "maya"
    assert router.server_base(maya) == "http://10.0.0.9:8080"
    assert models["glm-5.3-flash"]["params_b"] == 321
    assert models["glm-5.3-flash"]["is_vision"] and models["glm-5.3-flash"]["loaded"]
    assert models["custom-alias"]["params_b"] == 0
    assert response.status_code == 200 and response.json()["model"] == "glm-5.3-flash"
    assert response.headers["x-router-server"] == maya
    assert calls == [("/v1/models", "Bearer maya-secret"),
                     ("/v1/chat/completions", "Bearer maya-secret")]


def test_xolotl_discovery_and_dispatch(monkeypatch):
    """Xolotl serves through Strata's server with its own key; a Strata key
    configured on the router is never sent to it."""
    xolotl = "xolotl+http://10.0.0.12:8080"
    calls = []

    def handler(request):
        calls.append((request.url.path, request.headers.get("authorization")))
        if request.headers.get("authorization") != "Bearer xolotl-secret":
            return httpx.Response(401)
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"object": "list", "data": [
                {"id": "deepseek-v4.1-flash", "object": "model", "status": {"value": "loaded"},
                 "meta": {"n_ctx": 131072}, "architecture": {"input_modalities": ["text"]}}]})
        if request.url.path == "/v1/chat/completions":
            return streamed(200, {"model": json.loads(request.content)["model"]})
        return httpx.Response(404)

    router = load_router(monkeypatch, MODEL_SERVERS=xolotl, STRATA_API_KEY="strata-secret",
                         XOLOTL_API_KEY="xolotl-secret", ROUTER_API_KEY="client-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app) as client:
        models = {e["name"]: e for e in router.INVENTORY["models"]}
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-secret"},
                               json={"model": "deepseek-v4.1-flash", "messages": [user("hi")]})
    assert router.server_kind(xolotl) == "xolotl"
    assert router.server_base(xolotl) == "http://10.0.0.12:8080"
    assert models["deepseek-v4.1-flash"]["params_b"] == 552
    assert models["deepseek-v4.1-flash"]["loaded"] and not models["deepseek-v4.1-flash"]["is_vision"]
    assert response.status_code == 200 and response.json()["model"] == "deepseek-v4.1-flash"
    assert response.headers["x-router-server"] == xolotl
    assert calls == [("/v1/models", "Bearer xolotl-secret"),
                     ("/v1/chat/completions", "Bearer xolotl-secret")]


def test_avalon_discovery_and_dispatch(monkeypatch):
    """Avalon is a llama-server (llama.cpp's /v1/models shape, with an Ollama-
    style "models" list beside "data") with its own key; its alias is sized
    from [model_sizes], and no other kind's key is sent to it."""
    avalon = "avalon+http://10.0.0.13:8080"
    calls = []

    def handler(request):
        calls.append((request.url.path, request.headers.get("authorization")))
        if request.headers.get("authorization") != "Bearer avalon-secret":
            return httpx.Response(401, json={"error": {"code": 401, "message": "Invalid API Key"}})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={
                "models": [{"name": "qwen3.8-flash-next-avalon", "model": "qwen3.8-flash-next-avalon",
                            "details": {"parameter_size": ""}}],
                "object": "list",
                "data": [{"id": "qwen3.8-flash-next-avalon", "aliases": ["qwen3.8-flash-next-avalon"],
                          "object": "model", "owned_by": "llamacpp",
                          "architecture": {"input_modalities": ["text"]},
                          "meta": {"n_ctx": 262144, "n_ctx_train": 262144, "n_params": 125000000000}}]})
        if request.url.path == "/v1/chat/completions":
            return streamed(200, {"model": json.loads(request.content)["model"]})
        return httpx.Response(404)

    router = load_router(monkeypatch, MODEL_SERVERS=avalon, STRATA_API_KEY="strata-secret",
                         AVALON_API_KEY="avalon-secret", ROUTER_API_KEY="client-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app) as client:
        models = {e["name"]: e for e in router.INVENTORY["models"]}
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-secret"},
                               json={"model": "qwen3.8-flash-next-avalon", "messages": [user("hi")]})
    assert router.server_kind(avalon) == "avalon"
    assert router.server_base(avalon) == "http://10.0.0.13:8080"
    assert models["qwen3.8-flash-next-avalon"]["params_b"] == 125
    assert not models["qwen3.8-flash-next-avalon"]["is_vision"]
    assert response.status_code == 200 and response.json()["model"] == "qwen3.8-flash-next-avalon"
    assert response.headers["x-router-server"] == avalon
    assert calls == [("/v1/models", "Bearer avalon-secret"),
                     ("/v1/chat/completions", "Bearer avalon-secret")]


def test_kindi_discovery_and_dispatch(monkeypatch):
    """Kindi lists one model with its fitted context_length and its own key;
    its ids carry their size (bonsai2-27b), and no other kind's key is sent."""
    kindi = "kindi+http://10.0.0.14:8093"
    calls = []
    chat_timeout = []

    def handler(request):
        calls.append((request.url.path, request.headers.get("authorization")))
        if request.headers.get("authorization") != "Bearer kindi-secret":
            return httpx.Response(401, json={"error": {"message": "invalid API key", "type": "authentication_error",
                                                       "code": "authentication_error"}})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"object": "list", "data": [
                {"id": "bonsai2-27b", "object": "model", "created": 1, "owned_by": "kindi",
                 "context_length": 110592}]})
        if request.url.path == "/v1/chat/completions":
            chat_timeout.append(request.extensions["timeout"])
            return streamed(200, {"model": json.loads(request.content)["model"]})
        return httpx.Response(404)

    router = load_router(monkeypatch, MODEL_SERVERS=kindi, AVALON_API_KEY="avalon-secret",
                         KINDI_API_KEY="kindi-secret", ROUTER_API_KEY="client-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app) as client:
        models = {e["name"]: e for e in router.INVENTORY["models"]}
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-secret"},
                               json={"model": "bonsai2-27b", "messages": [user("hi")], "tools": TOOLS})
    assert router.server_kind(kindi) == "kindi"
    assert router.server_base(kindi) == "http://10.0.0.14:8093"
    assert models["bonsai2-27b"]["params_b"] == 27
    assert models["bonsai2-27b"]["context_length"] == 110592
    assert models["bonsai2-27b"]["tools"] is True
    assert not models["bonsai2-27b"]["is_vision"]
    assert response.status_code == 200 and response.json()["model"] == "bonsai2-27b"
    assert response.headers["x-router-server"] == kindi
    assert calls == [("/v1/models", "Bearer kindi-secret"),
                     ("/v1/chat/completions", "Bearer kindi-secret")]
    assert chat_timeout[0]["connect"] == 3
    assert chat_timeout[0]["read"] == 3600


def _kindi_router(monkeypatch, handler):
    kindi = "kindi+http://10.0.0.14:8093"
    router = load_router(monkeypatch, MODEL_SERVERS=kindi, KINDI_API_KEY="kindi-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    router._KINDI_DRAINING.clear()
    return router, kindi


def _kindi_listing(request):
    return httpx.Response(200, json={"object": "list", "data": [
        {"id": "bonsai2-2b", "object": "model", "created": 1, "owned_by": "kindi", "context_length": 24576}]})


def test_kindi_no_reply_is_not_retryable_and_drains(monkeypatch):
    """A Kindi request that was sent but got no reply is answered 424 with
    x-should-retry: false, once. While Kindi's /health shows it busy, nothing
    more is sent and callers get a retryable 503; once idle, requests go."""
    posts, state = [], {"silent": True, "busy": {"phase": "prompt"}}

    def handler(request):
        if request.url.path == "/v1/models":
            return _kindi_listing(request)
        if request.url.path == "/health":
            return httpx.Response(200, json={"ok": True, "kindi": "0.4.0", "busy": state["busy"]})
        if request.url.path == "/v1/chat/completions":
            posts.append(request.url.path)
            if state["silent"]:
                raise httpx.ReadTimeout("timed out", request=request)
            return streamed(200, {"model": "bonsai2-2b"})
        return httpx.Response(404)

    router, kindi = _kindi_router(monkeypatch, handler)
    with TestClient(router.app) as client:
        body = {"model": "bonsai2-2b", "messages": [user("hi")]}
        response = client.post("/v1/chat/completions", json=body)
        assert response.status_code == 424
        assert response.headers["x-should-retry"] == "false"
        error = response.json()["error"]
        assert error["type"] == "upstream_no_reply"
        assert not re.search(r"(?i)timed out|timeout", error["message"])
        assert posts == ["/v1/chat/completions"]
        state["silent"] = False
        response = client.post("/v1/chat/completions", json=body)
        assert response.status_code == 503 and response.headers["retry-after"] == "15"
        assert posts == ["/v1/chat/completions"]
        state["busy"] = None
        router._KINDI_DRAINING[kindi][0] = float("-inf")  # the 5 s /health cache has passed
        router.INVENTORY["servers"][kindi]["up"] = True
        response = client.post("/v1/chat/completions", json=body)
    assert response.status_code == 200
    assert posts == ["/v1/chat/completions"] * 2
    assert kindi not in router._KINDI_DRAINING


def test_kindi_connect_failure_stays_retryable(monkeypatch):
    def handler(request):
        if request.url.path == "/v1/models":
            return _kindi_listing(request)
        if request.url.path == "/v1/chat/completions":
            raise httpx.ConnectError("refused", request=request)
        return httpx.Response(404)

    router, _ = _kindi_router(monkeypatch, handler)
    with TestClient(router.app) as client:
        response = client.post("/v1/chat/completions", json={"model": "bonsai2-2b", "messages": [user("hi")]})
    assert response.status_code == 502
    assert "x-should-retry" not in response.headers


def test_kindi_drain_requires_a_confirmed_idle_health(router):
    kindi = "kindi+http://k:8093"
    responses = [httpx.Response(200, json={"busy": {"phase": "prompt"}}),
                 httpx.Response(503, json={"error": "unavailable"}),
                 httpx.Response(200, json={}),
                 httpx.Response(200, json={"busy": None})]
    calls = []

    def handler(request):
        calls.append(request.url.path)
        return responses.pop(0)

    async def check():
        router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        try:
            # A full hour passing does not release a server that reports busy.
            router._KINDI_DRAINING[kindi] = [time.monotonic() - 3600, True]
            for _ in range(3):
                assert await router.kindi_busy(kindi) is True
                router._KINDI_DRAINING[kindi][0] = float("-inf")
            assert await router.kindi_busy(kindi) is False
        finally:
            await router._HTTP["client"].aclose()

    asyncio.run(check())
    assert calls == ["/health"] * 4
    assert kindi not in router._KINDI_DRAINING


def test_kindi_newer_busy_request_keeps_gate_closed(router, monkeypatch):
    """A newer request may run while the unanswered one is still queued."""
    kindi = "kindi+http://10.0.0.14:8093"
    clock = [1000.0]
    monkeypatch.setattr(router.time, "monotonic", lambda: clock[0])

    async def check():
        busy = iter([{"phase": "prompt", "elapsed_s": 3},
                     {"phase": "prompt", "elapsed_s": 1}, None])
        router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, json={"ok": True, "busy": next(busy)})))
        try:
            router.mark_kindi_draining(kindi)
            clock[0] += 600
            assert await router.kindi_busy(kindi) is True
            clock[0] += router.KINDI_HEALTH_CACHE_SECONDS
            assert await router.kindi_busy(kindi) is True
            clock[0] += router.KINDI_HEALTH_CACHE_SECONDS
            assert await router.kindi_busy(kindi) is False
        finally:
            await router._HTTP["client"].aclose()

    asyncio.run(check())
    assert kindi not in router._KINDI_DRAINING


def test_kindi_partial_nonstreaming_body_timeout_returns_424(monkeypatch):
    posts = []

    class PartialBody(httpx.AsyncByteStream):
        def __init__(self, request):
            self.request = request

        async def __aiter__(self):
            yield b'{"choices":'
            raise httpx.ReadTimeout("read timed out", request=self.request)

        async def aclose(self):
            pass

    def handler(request):
        if request.url.path == "/v1/models":
            return _kindi_listing(request)
        if request.url.path == "/v1/chat/completions":
            posts.append(request.url.path)
            return httpx.Response(200, headers={"content-type": "application/json"},
                                  stream=PartialBody(request))
        return httpx.Response(404)

    router, kindi = _kindi_router(monkeypatch, handler)
    with TestClient(router.app) as client:
        response = client.post("/v1/chat/completions",
                               json={"model": "bonsai2-2b", "messages": [user("hi")]})
    assert response.status_code == 424
    assert response.headers["x-should-retry"] == "false"
    assert posts == ["/v1/chat/completions"]
    assert kindi in router._KINDI_DRAINING


def test_kindi_stream_timeout_after_first_chunk_marks_it_draining(router):
    kindi = "kindi+http://k:8093"
    router.INVENTORY["servers"] = {kindi: {"up": True}}

    class PartialStream(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b'data: {"choices": []}\n\n'
            raise httpx.ReadTimeout("read timed out")

        async def aclose(self):
            pass

    async def check():
        router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(
            lambda request: httpx.Response(200, headers={"content-type": "text/event-stream"},
                                           stream=PartialStream())))
        try:
            response = await router._dispatch_direct(
                [{"server": kindi, "name": "bonsai2-2b", "kind": "kindi"}],
                {"stream": True, "messages": [user("hi")]}, {},
                {"class": "fast", "code": False, "vision": False, "tools": False,
                 "approx_tokens": 1})
            assert response.status_code == 200
            chunks = []
            with pytest.raises(httpx.ReadTimeout):
                async for chunk in response.body_iterator:
                    chunks.append(chunk)
            assert chunks == [b'data: {"choices": []}\n\n']
        finally:
            await router._HTTP["client"].aclose()

    asyncio.run(check())
    assert kindi in router._KINDI_DRAINING


def test_last_fallback_503_does_not_hide_kindi_no_reply(router):
    kindi = "kindi+http://k:8093"
    other = "strata+http://s:8080"
    router.INVENTORY["servers"] = {kindi: {"up": True}, other: {"up": True}}
    posts = []

    def handler(request):
        posts.append(request.url.host)
        if request.url.host == "k":
            raise httpx.ReadTimeout("read timed out", request=request)
        return streamed(503, {"error": "unavailable"})

    async def check():
        router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        try:
            return await router._dispatch_direct(
                [{"server": kindi, "name": "bonsai2-2b", "kind": "kindi"},
                 {"server": other, "name": "other", "kind": "strata"}],
                {"messages": [user("hi")]}, {},
                {"class": "fast", "code": False, "vision": False, "tools": False,
                 "approx_tokens": 1})
        finally:
            await router._HTTP["client"].aclose()

    response = asyncio.run(check())
    assert response.status_code == 424
    assert response.headers["x-should-retry"] == "false"
    assert posts == ["k", "s"]


@pytest.mark.parametrize("kindi_tier,status", [(True, 424), (False, 408)])
def test_litellm_timeout_for_a_kindi_tier_is_not_retryable(served, monkeypatch, kindi_tier, status):
    """LiteLLM answers its own timeout with 408, which an SDK retries; for a
    tier with Kindi the router answers 424 with x-should-retry: false."""
    router, _, client = served
    monkeypatch.setattr(router, "INVENTORY", dict(router.INVENTORY, models=[]))
    if kindi_tier:
        monkeypatch.setenv("BACKEND_LARGE", "kindi+http://10.0.0.14:8093")
    router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(
        lambda request: streamed(408, {"error": {"message": "litellm.Timeout"}})))
    response = chat(client, messages=[user("please analyze this")])
    assert response.status_code == status
    assert (response.headers.get("x-should-retry") == "false") is kindi_tier


def test_litellm_kindi_tier_partial_body_timeout_is_424(served, monkeypatch):
    router, _, client = served
    monkeypatch.setattr(router, "INVENTORY", dict(router.INVENTORY, models=[]))
    monkeypatch.setenv("BACKEND_LARGE", "kindi+http://10.0.0.14:8093")
    posts = []

    class PartialBody(httpx.AsyncByteStream):
        def __init__(self, request):
            self.request = request

        async def __aiter__(self):
            yield b'{"choices":'
            raise httpx.ReadTimeout("read timed out", request=self.request)

        async def aclose(self):
            pass

    def handler(request):
        posts.append(request.url.path)
        return httpx.Response(200, headers={"content-type": "application/json"},
                              stream=PartialBody(request))

    router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    response = chat(client, messages=[user("please analyze this")])
    assert response.status_code == 424
    assert response.headers["x-should-retry"] == "false"
    assert posts == ["/v1/chat/completions"]


@pytest.mark.parametrize("model_id,size", [("bonsai2-2b", 2), ("bonsai2-9b", 9), ("nanbeige-33b-iq3", 33)])
def test_kindi_ids_are_sized_from_the_id(router, model_id, size):
    """Kindi's model ids name their size, so they need no [model_sizes] line."""
    entries = _openai_listing(router, "kindi+http://h:8093", [{"id": model_id, "context_length": 24576}])
    assert entries[model_id]["params_b"] == size


# --- named models on unreachable hosts ----------------------------------------
def test_named_model_on_a_down_host_is_routed_with_a_warning(served):
    router, upstream, client = served
    upstream.inventory[HOST_B] = tags(("qwen3:14b", "14.8B", "qwen3"),
                                      ("special:7b", "7B", "llama"))
    client.post("/routing/refresh")
    router.mark_server_down(HOST_B, "test")

    response = chat(client, model="special:7b")
    assert response.status_code == 200
    assert response.headers["x-router-warning"] == "model-unavailable"
    assert served_hosts(upstream)[-1] == HOST_A

    # A name the router has never seen is routed without that warning.
    response = chat(client, model="never-seen:1b")
    assert response.status_code == 200
    assert "x-router-warning" not in response.headers


def test_chat_copy_on_a_down_host_is_not_called_embedding_only(served):
    router, upstream, client = served
    router.INVENTORY = dict(router.INVENTORY, models=router.INVENTORY["models"] + [
        router.build_entry(HOST_A, {"name": "dual:1b"}, ["embedding"]),
        router.build_entry(HOST_B, {"name": "dual:1b"}, ["completion"]),
    ])
    router.mark_server_down(HOST_B, "test")

    response = chat(client, model="dual:1b")
    assert response.status_code == 200          # not the embedding-only 400
    assert response.headers["x-router-warning"] == "model-unavailable"


# --- tool requests (agents, function calling) -------------------------------------
TOOLS = [{"type": "function", "function": {
    "name": "terminal", "description": "Run a shell command",
    "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}}}}]


def tool_pool(router, upstream, client, a, b, caps):
    """HOST_A serves model a, HOST_B model b; caps maps names to /api/show lists."""
    upstream.inventory = {HOST_A: tags(a), HOST_B: tags(b)}
    upstream.capabilities.update(caps)
    router._CAPABILITIES.clear()
    assert client.post("/routing/refresh").status_code == 200


def tools_flag(router, name):
    return [e["tools"] for e in router.INVENTORY["models"] if e["name"] == name]


def test_discovery_records_tool_support(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("gemma3:12b", "12.2B", "gemma3"),
              ("qwen3:14b", "14.8B", "qwen3"),
              {"gemma3:12b": ["completion", "vision"], "qwen3:14b": ["completion", "tools"]})
    assert tools_flag(router, "gemma3:12b") == [False]
    assert tools_flag(router, "qwen3:14b") == [True]


def test_tool_support_is_unknown_without_a_capability_list(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "CAPABILITY_PROBE", False)
    client.post("/routing/refresh")
    assert set(tools_flag(router, "qwen3:14b")) == {None}


def test_lmstudio_trained_flag_means_tools_otherwise_unknown(router):
    raws = router._lmstudio_v1_models({"models": [
        {"key": "trained", "type": "llm", "capabilities": {"trained_for_tool_use": True}},
        {"key": "plain", "type": "llm", "capabilities": {}},
    ]})
    entries = {r["name"]: router.build_entry("lmstudio+http://h:1234", r, r["capabilities"])
               for r in raws}
    assert entries["trained"]["tools"] is True
    assert entries["plain"]["tools"] is None


def test_show_context_length(router):
    show = router.show_context_length
    assert show({"model_info": {"qwen3.context_length": 40960}}) == 40960
    # A served num_ctx below the model's own limit is what counts.
    assert show({"model_info": {"llama.context_length": 131072},
                 "parameters": "stop <eot>\nnum_ctx 8192"}) == 8192
    assert show({"parameters": "num_ctx 2048\nnum_predict 512"}) == 2048
    for nothing in ({}, {"model_info": {"llama.context_length": True}},
                    {"model_info": {"x.context_length": "4096"}, "parameters": "num_ctx big"},
                    {"model_info": None, "parameters": None}):
        assert show(nothing) is None


def test_discovery_records_context_length(served):
    router, upstream, client = served
    router._CAPABILITIES.clear()
    router._CONTEXTS.clear()
    upstream.inventory = {HOST_A: tags(("qwen3:14b", "14.8B", "qwen3")),
                          HOST_B: tags(("airllm-72b", "72B", "qwen2"))}
    upstream.capabilities.update({"qwen3:14b": ["completion", "tools"], "airllm-72b": ["completion"]})
    upstream.show_extra.update({
        "qwen3:14b": {"model_info": {"qwen3.context_length": 40960}},
        # What AirLLM's /api/show reports for its default window.
        "airllm-72b": {"model_info": {"qwen2.context_length": 2048},
                       "parameters": "num_ctx 2048\nnum_predict 512"}})
    assert client.post("/routing/refresh").status_code == 200
    inventory = {e["name"]: e for e in client.get("/routing/inventory").json()["models"]}
    assert inventory["qwen3:14b"]["context_length"] == 40960
    assert (inventory["airllm-72b"]["context_length"], inventory["airllm-72b"]["tools"]) == (2048, False)
    # Cached with the capabilities: a second poll still reports it.
    client.post("/routing/refresh")
    assert {e["name"]: e["context_length"] for e in router.INVENTORY["models"]}["qwen3:14b"] == 40960


def test_context_is_reprobed_after_cache_expiry(served):
    import asyncio

    router, upstream, client = served
    router._CAPABILITIES.clear()
    router._CONTEXTS.clear()
    router._SHOW_TIMES.clear()
    upstream.capabilities["qwen3:14b"] = ["completion", "tools"]
    upstream.show_extra["qwen3:14b"] = {"parameters": "num_ctx 65536"}
    client.post("/routing/refresh")
    assert {e["context_length"] for e in router.INVENTORY["models"]} == {65536}

    upstream.show_extra["qwen3:14b"] = {"parameters": "num_ctx 8192"}
    async def fetch():
        async with httpx.AsyncClient(transport=httpx.MockTransport(upstream)) as http:
            return await router.fetch_server_models(http, HOST_A)

    _, cached, _ = asyncio.run(fetch())
    assert cached[0]["context_length"] == 65536
    for key in router._SHOW_TIMES:
        router._SHOW_TIMES[key] = 0
    _, refreshed, _ = asyncio.run(fetch())
    assert refreshed[0]["context_length"] == 8192
    # A manual refresh should also re-probe before the cache expires.
    upstream.show_extra["qwen3:14b"] = {"parameters": "num_ctx 4096"}
    client.post("/routing/refresh")
    assert {e["context_length"] for e in router.INVENTORY["models"]} == {4096}


def test_a_failed_reprobe_keeps_the_last_good_show_answer(served):
    """A transient /api/show failure after the cache expired must not turn a
    model's known capabilities and context into "unknown": tools False would
    become None, which Hermes's dispatcher accepts."""
    import asyncio

    router, upstream, client = served
    router._CAPABILITIES.clear()
    router._CONTEXTS.clear()
    router._SHOW_TIMES.clear()
    # No tools, a vision capability the name alone would not suggest, a small window.
    upstream.capabilities["qwen3:14b"] = ["completion", "vision"]
    upstream.show_extra["qwen3:14b"] = {"parameters": "num_ctx 2048"}
    client.post("/routing/refresh")

    def entry():
        found = [e for e in router.INVENTORY["models"] if e["name"] == "qwen3:14b"]
        assert found
        return {(e["tools"], e["is_vision"], e["context_length"]) for e in found}

    assert entry() == {(False, True, 2048)}

    upstream.capabilities["qwen3:14b"] = "boom"      # /api/show now fails to connect
    calls = len(upstream.show_calls)
    # A forced refresh re-probes, fails, and keeps the last good answer.
    client.post("/routing/refresh")
    assert len(upstream.show_calls) > calls
    assert entry() == {(False, True, 2048)}

    # So does a scheduled poll after the cache expired.
    for key in router._SHOW_TIMES:
        router._SHOW_TIMES[key] = 0

    async def fetch():
        async with httpx.AsyncClient(transport=httpx.MockTransport(upstream)) as http:
            return await router.fetch_server_models(http, HOST_A)

    calls = len(upstream.show_calls)
    _, entries, _ = asyncio.run(fetch())
    assert len(upstream.show_calls) > calls
    assert [(e["tools"], e["is_vision"], e["context_length"]) for e in entries
            if e["name"] == "qwen3:14b"] == [(False, True, 2048)]

    # The failure is not cached: once /api/show answers again, its answer wins.
    upstream.capabilities["qwen3:14b"] = ["completion", "tools"]
    upstream.show_extra["qwen3:14b"] = {"parameters": "num_ctx 65536"}
    client.post("/routing/refresh")
    assert entry() == {(True, False, 65536)}


def test_context_length_is_unknown_without_the_probe(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "CAPABILITY_PROBE", False)
    client.post("/routing/refresh")
    assert {e["context_length"] for e in router.INVENTORY["models"]} == {None}


def test_lmstudio_context_length(router):
    v1 = {r["name"]: r["context_length"] for r in router._lmstudio_v1_models({"models": [
        {"key": "loaded", "type": "llm", "max_context_length": 131072,
         "loaded_instances": [{"id": "a", "config": {"context_length": 8192}}]},
        {"key": "cold", "type": "llm", "max_context_length": 32768, "loaded_instances": []},
        {"key": "unknown", "type": "llm"},
    ]})}
    assert v1 == {"loaded": 8192, "cold": 32768, "unknown": None}
    v0 = router._lmstudio_v0_models({"data": [{"id": "m", "type": "llm", "max_context_length": 4096}]})
    assert v0[0]["context_length"] == 4096
    entry = router.build_entry("lmstudio+http://h:1234", v0[0], v0[0]["capabilities"])
    assert entry["context_length"] == 4096


def test_openai_kind_context_length(router):
    import asyncio

    def handler(request):
        return httpx.Response(200, json={"data": [
            {"id": "a", "context_length": 65536},
            {"id": "b", "max_model_len": 32768},
            {"id": "c", "context_window": False},
        ]})

    async def fetch():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await router.fetch_openai_models(client, "strata+http://h:8080")

    _, entries, error = asyncio.run(fetch())
    assert error is None
    assert {e["name"]: e["context_length"] for e in entries} == {"a": 65536, "b": 32768, "c": None}


def test_openai_kind_tool_support_is_unknown_without_a_listing(router):
    """build_entry alone knows nothing: tool_kinds is applied to a /v1/models listing."""
    entry = router.build_entry("maya+http://h:8080", {"name": "glm-5.3-flash"}, ["completion"])
    assert entry["tools"] is None


def _openai_listing(router, server, data):
    import asyncio

    def handler(request):
        return httpx.Response(200, json={"object": "list", "data": data})

    async def fetch():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await router.fetch_openai_models(client, server)

    _, entries, error = asyncio.run(fetch())
    assert error is None
    return {e["name"]: e for e in entries}


def test_openai_kind_context_from_meta_n_ctx(router):
    """Strata, Basalt, Xolotl and llama-server (Avalon) give the served context as
    meta.n_ctx; n_ctx_train is the model's own limit and is never used. A named
    field still comes first (Maya sends both)."""
    entries = _openai_listing(router, "avalon+http://h:8080", [
        {"id": "served", "meta": {"n_ctx": 131072, "n_ctx_train": 262144}},
        {"id": "train-only", "meta": {"n_ctx_train": 262144}},
        {"id": "named", "context_length": 32768, "meta": {"n_ctx": 65536}},
        {"id": "odd", "meta": {"n_ctx": True}},
        {"id": "no-meta", "meta": "n_ctx"},
    ])
    assert {n: e["context_length"] for n, e in entries.items()} == {
        "served": 131072, "train-only": None, "named": 32768, "odd": None, "no-meta": None}


@pytest.mark.parametrize("kind", ["strata", "basalt", "maya", "xolotl", "avalon", "kindi"])
def test_openai_kind_text_models_report_tools(router, kind):
    """Each of these servers takes "tools" and returns tool_calls, so its text
    models are tool-capable; an image generator listed beside them is not."""
    entries = _openai_listing(router, f"{kind}+http://h:8080", [
        {"id": "chat", "meta": {"n_ctx": 32768}},
        {"id": "chat-alias", "architecture": {"output_modalities": ["text"]}},
        {"id": "images", "architecture": {"input_modalities": ["text"], "output_modalities": ["image"]}},
    ])
    assert {n: e["tools"] for n, e in entries.items()} == {
        "chat": True, "chat-alias": True, "images": None}


def test_tool_kinds_setting(monkeypatch, tmp_path, caplog):
    """A kind left out of tool_kinds is unknown again; a name that is not a
    /v1/models kind is ignored with a warning."""
    ini = (ROOT / "services/ollama-router/router.ini").read_text()
    assert "\ntool_kinds = strata, basalt, maya, xolotl, avalon, kindi\n" in ini
    custom = tmp_path / "router.ini"
    custom.write_text(ini.replace("tool_kinds = strata, basalt, maya, xolotl, avalon, kindi",
                                  "tool_kinds = Avalon, ollama, nonsense"))
    with caplog.at_level("WARNING", logger="router"):
        router = load_router(monkeypatch, ROUTER_INI=str(custom))
    assert router.TOOL_KINDS == {"avalon"}
    assert sorted(r.getMessage() for r in caplog.records if "tool_kinds" in r.getMessage()) == [
        "ignoring [classification] tool_kinds entry 'nonsense' (use avalon, basalt, kindi, maya, strata, xolotl)",
        "ignoring [classification] tool_kinds entry 'ollama' (use avalon, basalt, kindi, maya, strata, xolotl)"]
    assert _openai_listing(router, "avalon+http://h:8080", [{"id": "m"}])["m"]["tools"] is True
    assert _openai_listing(router, "strata+http://h:8080", [{"id": "m"}])["m"]["tools"] is None
    custom.write_text(ini.replace("tool_kinds = strata, basalt, maya, xolotl, avalon, kindi", "tool_kinds ="))
    assert load_router(monkeypatch, ROUTER_INI=str(custom)).TOOL_KINDS == frozenset()
    # The built-in default matches router.ini, for a router.ini without the line.
    assert load_router(monkeypatch, ROUTER_INI=str(tmp_path / "missing.ini")).TOOL_KINDS == {
        "strata", "basalt", "maya", "xolotl", "avalon", "kindi"}


@pytest.mark.parametrize("body,expected", [
    ({"tools": TOOLS}, True),
    ({"functions": [{"name": "f", "parameters": {}}]}, True),
    ({"tools": TOOLS, "tool_choice": "none"}, False),
    ({"tools": []}, False),
    ({"tools": "terminal"}, False),
    ({}, False),
])
def test_wants_tools(router, body, expected):
    assert router.wants_tools(body) is expected


def test_tool_request_skips_a_model_known_to_lack_tools(served):
    """The reproduced failure: a short agent prompt went to the closest small
    model, which has no tool support, and every turn got a 400."""
    router, upstream, client = served
    tool_pool(router, upstream, client, ("gemma3:12b", "12.2B", "gemma3"),
              ("qwen3:14b", "14.8B", "qwen3"),
              {"gemma3:12b": ["completion", "vision"], "qwen3:14b": ["completion", "tools"]})
    upstream.tool_less = {"gemma3:12b"}
    for _ in range(4):
        response = chat(client, tools=TOOLS, messages=[user("List the files in /etc")])
        assert response.status_code == 200
        assert response.json()["model"] == "qwen3:14b"
        assert "x-router-warning" not in response.headers
    assert set(served_hosts(upstream)) == {HOST_B}
    # The same prompt without tools still goes by size.
    assert chat(client, messages=[user("List the files in /etc")]).json()["model"] == "gemma3:12b"


def test_tool_request_is_raised_to_tools_min_class(served):
    router, _, client = served
    plain = client.post("/routing/explain", json={"messages": [user("hi")]}).json()
    tooled = client.post("/routing/explain",
                         json={"messages": [user("hi")], "tools": TOOLS}).json()
    assert plain["request"]["class"] == "fast"
    assert tooled["request"]["class"] == router.TOOLS_MIN_CLASS == "large"
    assert tooled["request"]["tools"] is True
    assert chat(client, tools=TOOLS).headers["x-router-class"] == "large"


def test_explain_honours_requested_tier_alias(served):
    router, _, client = served
    result = client.post("/routing/explain", json={
        "model": router.TIER_XLARGE, "messages": [user("hi")]}).json()
    assert result["request"]["class"] == "xlarge"


def test_tool_floor_never_lowers_a_class(router):
    need = router.apply_tool_needs({"class": "xlarge", "code": False, "vision": False},
                                   {"tools": TOOLS})
    assert need["class"] == "xlarge"


def test_blank_tools_min_class_disables_the_floor(served, monkeypatch):
    router, _, client = served
    monkeypatch.setattr(router, "TOOLS_MIN_CLASS", "")
    assert chat(client, tools=TOOLS).headers["x-router-class"] == "fast"


def test_tier_alias_still_pins_the_class_of_a_tool_request(served):
    router, _, client = served
    response = chat(client, model=router.TIER_FAST, tools=TOOLS)
    assert response.headers["x-router-class"] == "fast"


def test_invalid_tools_min_class_is_ignored(monkeypatch, tmp_path):
    ini = tmp_path / "router.ini"
    ini.write_text((ROOT / "services/ollama-router/router.ini").read_text()
                   .replace("tools_min_class = large", "tools_min_class = huge"))
    module = load_router(monkeypatch, ROUTER_INI=str(ini))
    assert module.TOOLS_MIN_CLASS == ""


def test_known_tool_model_beats_an_unknown_one_of_equal_fit(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("mystery:14b", "14.8B", "x"),
              ("qwen3:14b", "14.8B", "qwen3"), {"qwen3:14b": ["completion", "tools"]})
    assert tools_flag(router, "mystery:14b") == [None]
    for _ in range(3):
        assert chat(client, tools=TOOLS).json()["model"] == "qwen3:14b"


def test_tool_rejection_fails_forward_and_is_remembered(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("mystery:14b", "14.8B", "x"),
              ("other:14b", "14.8B", "y"), {})
    upstream.tool_less = {"mystery:14b"}
    router._rotation.clear()
    served_models = set()
    for _ in range(4):
        response = chat(client, tools=TOOLS)
        assert response.status_code == 200
        served_models.add(response.json()["model"])
    assert served_models == {"other:14b"}
    assert tools_flag(router, "mystery:14b") == [False]
    # Once known, it is not even tried: at most the one rejected attempt.
    assert served_hosts(upstream).count(HOST_A) == 1


def test_a_400_that_is_not_about_tools_is_passed_through(served):
    _, upstream, client = served
    upstream.chat = {HOST_A: 400, HOST_B: 400}
    response = chat(client, tools=TOOLS)
    assert response.status_code == 400
    assert "served_by" in response.json()          # the backend's own body
    assert response.headers["x-router-mode"] == "discovery"
    assert len(served_hosts(upstream)) == 1


def test_a_tools_schema_400_is_passed_through_without_demotion(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("mystery:14b", "14.8B", "x"),
              ("other:14b", "14.8B", "y"), {})
    upstream.chat[HOST_A] = 400
    upstream.chat_errors[HOST_A] = {"error": {
        "message": "Invalid parameter 'tools': function parameters must be an object"}}
    router._rotation.clear()

    response = chat(client, tools=TOOLS)
    assert response.status_code == 400
    assert response.json() == upstream.chat_errors[HOST_A]
    assert served_hosts(upstream) == [HOST_A]
    assert tools_flag(router, "mystery:14b") == [None]


def test_last_candidate_tool_rejection_is_returned(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("mystery:14b", "14.8B", "x"),
              ("mystery:14b", "14.8B", "x"), {})
    upstream.tool_less = {"mystery:14b"}
    response = chat(client, tools=TOOLS)
    assert response.status_code == 400
    assert "does not support tools" in response.json()["error"]["message"]
    # Both hosts' entries are remembered, the last one included.
    assert tools_flag(router, "mystery:14b") == [False, False]


def test_a_lone_tool_less_model_is_remembered_and_still_answers(served):
    router, upstream, client = served
    upstream.inventory = {HOST_A: tags(("mystery:14b", "14.8B", "x"))}
    router._CAPABILITIES.clear()
    assert client.post("/routing/refresh").status_code == 200
    upstream.tool_less = {"mystery:14b"}
    for _ in range(2):
        # Known not to support tools, it is still the only candidate, so the
        # client keeps getting the backend's own 400 rather than a 502.
        response = chat(client, tools=TOOLS)
        assert response.status_code == 400
        assert "does not support tools" in response.json()["error"]["message"]
        assert tools_flag(router, "mystery:14b") == [False]
    assert served_hosts(upstream) == [HOST_A, HOST_A]


def test_no_tool_model_is_flagged(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("gemma3:12b", "12.2B", "gemma3"),
              ("phi4:14b", "14.7B", "phi3"),
              {"gemma3:12b": ["completion"], "phi4:14b": ["completion"]})
    response = chat(client, tools=TOOLS)
    assert response.headers["x-router-warning"] == "no-tool-model"


def test_tools_strict_rejects_when_no_model_has_tools(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "TOOLS_STRICT", True)
    tool_pool(router, upstream, client, ("gemma3:12b", "12.2B", "gemma3"),
              ("phi4:14b", "14.7B", "phi3"),
              {"gemma3:12b": ["completion"], "phi4:14b": ["completion"]})
    response = chat(client, tools=TOOLS)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "no_tool_model"
    assert served_hosts(upstream) == []


def test_named_model_is_honoured_for_a_tool_request(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("gemma3:12b", "12.2B", "gemma3"),
              ("qwen3:14b", "14.8B", "qwen3"),
              {"gemma3:12b": ["completion"], "qwen3:14b": ["completion", "tools"]})
    response = chat(client, model="gemma3:12b", tools=TOOLS)
    assert response.json()["model"] == "gemma3:12b"
    assert "x-router-warning" not in response.headers


def test_tool_requests_stay_on_one_model_but_share_its_hosts(served):
    router, upstream, client = served
    caps = {"qwen3:14b": ["completion", "tools"], "llama9:14b": ["completion", "tools"]}
    tool_pool(router, upstream, client, ("qwen3:14b", "14B", "qwen3"),
              ("llama9:14b", "14B", "llama"), caps)
    router._rotation.clear()
    plain = {chat(client).json()["model"] for _ in range(4)}
    assert plain == {"qwen3:14b", "llama9:14b"}      # unchanged: ties rotate
    tooled = {chat(client, tools=TOOLS).json()["model"] for _ in range(4)}
    assert len(tooled) == 1                         # one model for an agent loop
    # The same model on two hosts still shares the load.
    tool_pool(router, upstream, client, ("qwen3:14b", "14B", "qwen3"),
              ("qwen3:14b", "14B", "qwen3"), caps)
    upstream.calls.clear()
    for _ in range(4):
        chat(client, tools=TOOLS)
    assert set(served_hosts(upstream)) == {HOST_A, HOST_B}


def test_explain_lists_tool_support(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("gemma3:12b", "12.2B", "gemma3"),
              ("qwen3:14b", "14.8B", "qwen3"),
              {"gemma3:12b": ["completion"], "qwen3:14b": ["completion", "tools"]})
    body = client.post("/routing/explain", json={"messages": [user("hi")], "tools": TOOLS}).json()
    assert [c["model"] for c in body["candidates"]] == ["qwen3:14b"]
    assert body["candidates"][0]["tools"] is True
