"""Unit tests for services/osr-router/router.py.

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
        "ROUTER_INI": str(ROOT / "services/osr-router/router.ini"),
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
        "router_under_test", ROOT / "services/osr-router/router.py")
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


FREELLMAPI = "http://10.0.0.60:3001"


def freellmapi_upstream(calls, models=None, fail_models=False):
    """FreeLLMAPI on 10.0.0.60 beside one local Ollama host."""
    def upstream(request):
        if request.url.host == "10.0.0.60":
            calls.append((request.url.path, request.url.query.decode(),
                          request.headers.get("authorization"),
                          json.loads(request.content).get("model") if request.content else None))
            if request.url.path == "/v1/models":
                if fail_models:
                    return httpx.Response(503)
                return httpx.Response(200, json={"object": "list", "data": models or []})
            if request.url.path == "/v1/chat/completions":
                return streamed(200, {"model": "llama-3.3-70b"})
            return httpx.Response(404)
        return local(request)
    local = Upstream()
    local.inventory = {HOST_A: tags(("local:7b", "7B", "llama"))}
    return upstream


FREELLMAPI_LIST = [
    {"id": "auto", "owned_by": "freellmapi", "available": True},
    {"id": "fusion", "owned_by": "freellmapi", "available": False},
    {"id": "llama-3.3-70b", "owned_by": "groq", "available": True},
    {"id": "bad id\n", "owned_by": "groq", "available": True},
]


def test_freellmapi_models_are_explicit_and_bypass_litellm(monkeypatch):
    router = load_router(monkeypatch, FREELLMAPI_BASE_URL=FREELLMAPI + "/",
                         FREELLMAPI_API_KEY="freellmapi-secret", ROUTER_API_KEY="router-key")
    calls = []
    router._HTTP["transport"] = httpx.MockTransport(freellmapi_upstream(calls, FREELLMAPI_LIST))
    auth = {"Authorization": "Bearer router-key"}
    with TestClient(router.app) as client:
        listed = [entry for entry in client.get("/v1/models", headers=auth).json()["data"]
                  if entry["id"].startswith("freellmapi/")]
        client.get("/v1/models", headers=auth)
        response = client.post("/v1/chat/completions", headers=auth, json={
            "model": "freellmapi/llama-3.3-70b", "messages": [{"role": "user", "content": "hi"}]})
        automatic = client.post("/v1/chat/completions", headers=auth, json={
            "model": "auto", "messages": [{"role": "user", "content": "hi"}]})
    # Unavailable and malformed entries are not offered; "auto" always is.
    assert [entry["id"] for entry in listed] == ["freellmapi/auto", "freellmapi/llama-3.3-70b"]
    assert {entry["owned_by"] for entry in listed} == {"freellmapi"}
    # One cached listing for two /v1/models requests, asked for usable models only.
    assert [call for call in calls if call[0] == "/v1/models"] == [
        ("/v1/models", "available=true", "Bearer freellmapi-secret", None)]
    assert response.status_code == 200
    assert response.headers["x-router-mode"] == "freellmapi"
    assert response.headers["x-router-model"] == "freellmapi/llama-3.3-70b"
    # The router's own key replaces the client's, and the prefix is removed.
    assert calls[-1] == ("/v1/chat/completions", "", "Bearer freellmapi-secret", "llama-3.3-70b")
    # "auto" stays local: nothing but the one explicit request reached FreeLLMAPI.
    assert automatic.status_code == 200
    assert automatic.headers.get("x-router-mode") != "freellmapi"
    assert len([call for call in calls if call[0] == "/v1/chat/completions"]) == 1


def test_freellmapi_auto_list_and_outage(monkeypatch):
    router = load_router(monkeypatch, FREELLMAPI_BASE_URL=FREELLMAPI,
                         FREELLMAPI_API_KEY="freellmapi-secret", FREELLMAPI_MODELS="auto")
    calls = []
    router._HTTP["transport"] = httpx.MockTransport(freellmapi_upstream(calls, FREELLMAPI_LIST))
    with TestClient(router.app) as client:
        ids = [entry["id"] for entry in client.get("/v1/models").json()["data"]]
    assert "freellmapi/auto" in ids and "freellmapi/llama-3.3-70b" not in ids

    router = load_router(monkeypatch, FREELLMAPI_BASE_URL=FREELLMAPI,
                         FREELLMAPI_API_KEY="freellmapi-secret")
    router._HTTP["transport"] = httpx.MockTransport(freellmapi_upstream([], fail_models=True))
    with TestClient(router.app) as client:
        ids = [entry["id"] for entry in client.get("/v1/models").json()["data"]]
    # A FreeLLMAPI outage neither hides its entry nor breaks the local list.
    assert "freellmapi/auto" in ids and "auto" in ids and "local:7b" in ids


def test_freellmapi_requires_url_and_key(monkeypatch):
    for settings in ({}, {"FREELLMAPI_BASE_URL": FREELLMAPI},
                     {"FREELLMAPI_API_KEY": "freellmapi-secret"},
                     {"FREELLMAPI_BASE_URL": FREELLMAPI + "/v1",
                      "FREELLMAPI_API_KEY": "freellmapi-secret"},
                     {"FREELLMAPI_BASE_URL": "ftp://10.0.0.60",
                      "FREELLMAPI_API_KEY": "freellmapi-secret"}):
        router = load_router(monkeypatch, **settings)
        calls = []
        router._HTTP["transport"] = httpx.MockTransport(freellmapi_upstream(calls))
        with TestClient(router.app) as client:
            ids = [entry["id"] for entry in client.get("/v1/models").json()["data"]]
            response = chat(client, model="freellmapi/auto")
        assert not [name for name in ids if name.startswith("freellmapi/")], settings
        assert response.status_code == 404, settings
        assert response.json()["error"]["code"] == "freellmapi_not_configured"
        assert calls == [], settings
        for name in ("FREELLMAPI_BASE_URL", "FREELLMAPI_API_KEY"):
            monkeypatch.delenv(name, raising=False)


def test_freellmapi_rejects_malformed_model_names(monkeypatch):
    router = load_router(monkeypatch, FREELLMAPI_BASE_URL=FREELLMAPI,
                         FREELLMAPI_API_KEY="freellmapi-secret")
    calls = []
    router._HTTP["transport"] = httpx.MockTransport(freellmapi_upstream(calls))
    with TestClient(router.app) as client:
        response = chat(client, model="freellmapi/")
        spaced = chat(client, model="freellmapi/a b")
    assert response.status_code == 400 and spaced.status_code == 400
    assert response.json()["error"]["code"] == "freellmapi_model_invalid"
    assert not [call for call in calls if call[0] == "/v1/chat/completions"]


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


def test_upstream_cannot_set_router_metric_labels(router):
    upstream = httpx.Response(200, headers={
        "X-Router-Model": "arbitrary-upstream-value",
        "X-Router-Server": "arbitrary-upstream-host",
        "X-Router-Request-ID": "arbitrary-upstream-id",
        "X-Request-ID": "provider-id",
        "X-Upstream": "yes",
    })
    headers = router._response_headers(upstream, {"X-Router-Mode": "discovery"})
    assert headers["X-Router-Mode"] == "discovery"
    assert not any(name.lower() in ("x-router-model", "x-router-server",
                                    "x-router-request-id") for name in headers)
    assert headers["x-request-id"] == "provider-id"
    assert headers["x-upstream"] == "yes"


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
    ini = (ROOT / "services/osr-router/router.ini").read_text()
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
    ini = (ROOT / "services/osr-router/router.ini").read_text()
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
                                  "qwen3.8-flash-next-avalon": "125B",
                                  **COLIBRI_SIZES}


# Colibri's ids that name no size, as router.py and router.ini list them.
COLIBRI_SIZES = {
    "glm-5.3-flash-colibri": "321B", "glm-5.2-colibri": "744B",
    "mistral-large-4-colibri": "1000B", "inkling-colibri": "975B",
    "kimi-k3-colibri": "2800B", "olmoe-colibri": "7B", "qwen3.6-colibri": "35B",
    "qwen3.8-flash-next-colibri": "125B", "flint-colibri": "40B",
    "muse-spark-open-colibri": "816B", "deepseek-v4-colibri": "284B",
    "deepseek-v4.1-flash-colibri": "552B", "mimo-v2.6-flash": "309B",
    "mimo-v2.6-pro": "1020B",
}


def test_colibri_sizes_are_in_router_ini(monkeypatch, tmp_path):
    """router.ini lists the same Colibri sizes as the built-in defaults, so an
    operator sees (and can blank) each one; each parses to its billions."""
    ini = (ROOT / "services/osr-router/router.ini").read_text()
    assert all(f"\n{i} = {s}\n" in ini for i, s in COLIBRI_SIZES.items())
    router = load_router(monkeypatch, ROUTER_INI=str(tmp_path / "missing.ini"))
    assert router.parse_params_billions("2800B") == 2800
    assert all(router.parse_params_billions(s) > 0 for s in COLIBRI_SIZES.values())


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
                                  "qwen3.8-flash-next-avalon": "125B", **COLIBRI_SIZES}


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


def test_colibri_discovery_and_dispatch(monkeypatch):
    """Colibri lists one model (owned_by colibri) with its context and
    capabilities; its ids are sized from [model_sizes], Inkling and OLMoE take
    no tools, and an image or decision model is not offered for chat."""
    colibri = "colibri+http://10.0.0.15:8080"
    calls = []
    listing = {"object": "list", "data": [
        {"id": "qwen3.6-colibri", "object": "model", "created": 1, "owned_by": "colibri",
         "input_modalities": ["text", "image"], "capabilities": ["chat", "systemone"],
         "context_length": 65536, "max_model_len": 65536}]}

    def handler(request):
        calls.append((request.url.path, request.headers.get("authorization")))
        if request.headers.get("authorization") != "Bearer colibri-secret":
            return httpx.Response(401, json={"error": {"message": "Invalid or missing API key.",
                                                       "type": "authentication_error",
                                                       "code": "invalid_api_key"}})
        if request.url.path == "/v1/models":
            return httpx.Response(200, json=listing)
        if request.url.path == "/v1/chat/completions":
            return streamed(200, {"model": json.loads(request.content)["model"]})
        return httpx.Response(404)

    router = load_router(monkeypatch, MODEL_SERVERS=colibri, KINDI_API_KEY="kindi-secret",
                         COLIBRI_API_KEY="colibri-secret", ROUTER_API_KEY="client-secret")
    router._HTTP["transport"] = httpx.MockTransport(handler)
    with TestClient(router.app) as client:
        models = {e["name"]: e for e in router.INVENTORY["models"]}
        response = client.post("/v1/chat/completions",
                               headers={"Authorization": "Bearer client-secret"},
                               json={"model": "qwen3.6-colibri", "messages": [user("hi")], "tools": TOOLS})
    assert router.server_kind(colibri) == "colibri"
    assert router.server_base(colibri) == "http://10.0.0.15:8080"
    assert models["qwen3.6-colibri"]["params_b"] == 35
    assert models["qwen3.6-colibri"]["context_length"] == 65536
    assert models["qwen3.6-colibri"]["tools"] is True
    assert models["qwen3.6-colibri"]["is_vision"]
    assert response.status_code == 200 and response.json()["model"] == "qwen3.6-colibri"
    assert response.headers["x-router-server"] == colibri
    assert calls == [("/v1/models", "Bearer colibri-secret"),
                     ("/v1/chat/completions", "Bearer colibri-secret")]


@pytest.mark.parametrize("entry, offered, tools", [
    ({"id": "olmoe-colibri", "capabilities": ["chat", "systemone"]}, True, None),
    ({"id": "inkling-colibri", "capabilities": ["chat", "systemone"]}, True, None),
    ({"id": "qwen3-coder-30b-a3b-colibri", "capabilities": ["chat", "systemone"]}, True, True),
    ({"id": "qwen-image-2.1-colibri", "capabilities": ["image_generation"]}, False, None),
    ({"id": "laya", "capabilities": ["systemone", "decision"]}, False, None),
])
def test_colibri_model_capabilities(monkeypatch, entry, offered, tools):
    colibri = "colibri+http://10.0.0.15:8080"
    router = load_router(monkeypatch, MODEL_SERVERS=colibri)

    def handler(request):
        return httpx.Response(200, json={"object": "list", "data": [
            {"object": "model", "created": 1, "owned_by": "colibri", **entry}]})

    async def fetch():
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            return await router.fetch_openai_models(client, colibri)

    _, entries, error = asyncio.run(fetch())
    assert error is None
    names = {e["name"]: e for e in entries if not e.get("is_image")}
    assert (entry["id"] in names) == offered
    # An image generator is kept apart as an image model; a decision model is dropped.
    images = [e["name"] for e in entries if e.get("is_image")]
    assert images == ([entry["id"]] if "image_generation" in entry["capabilities"] else [])
    if offered:
        assert names[entry["id"]]["tools"] is tools
        if entry["id"] == "qwen3-coder-30b-a3b-colibri":
            assert names[entry["id"]]["params_b"] == 30


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


def test_lmstudio_served_context_is_the_loaded_instance(router):
    """Only a loaded instance tells what LM Studio serves; max_context_length
    is the model's own limit, which a just-in-time load need not use."""
    v1 = {r["name"]: r for r in router._lmstudio_v1_models({"models": [
        {"key": "loaded", "type": "llm", "max_context_length": 262144,
         "loaded_instances": [{"id": "a", "config": {"context_length": 262144}},
                              {"id": "b", "config": {"context_length": 131072}}]},
        {"key": "cold", "type": "llm", "max_context_length": 262144, "loaded_instances": []},
    ]})}
    assert (v1["loaded"]["context_length"], v1["loaded"]["served_context_length"]) == (131072, 131072)
    assert (v1["cold"]["context_length"], v1["cold"]["served_context_length"]) == (262144, None)
    entry = router.build_entry("lmstudio+http://h:1234", v1["loaded"], v1["loaded"]["capabilities"])
    assert entry["served_context_length"] == 131072
    v0 = router._lmstudio_v0_models({"data": [{"id": "m", "type": "llm", "max_context_length": 4096}]})
    assert router.build_entry("lmstudio+http://h:1234", v0[0], [])["served_context_length"] is None


def test_lmstudio_parallel_slots_split_the_context(router, monkeypatch):
    """With parallel > 1 and the Unified KV Cache off, llama.cpp gives each
    slot context_length / parallel: that, not context_length, is what one
    request can use. lmstudio_unified_kv = true counts the whole pool."""
    payload = {"models": [
        {"key": "split", "type": "llm", "max_context_length": 262144,
         "loaded_instances": [{"id": "a", "config": {"context_length": 262144, "parallel": 8}}]},
        {"key": "single", "type": "llm",
         "loaded_instances": [{"id": "b", "config": {"context_length": 262144, "parallel": 1}}]},
        {"key": "unreported", "type": "llm",
         "loaded_instances": [{"id": "c", "config": {"context_length": 65536}}]},
        {"key": "bogus", "type": "llm",
         "loaded_instances": [{"id": "d", "config": {"context_length": 65536, "parallel": True}},
                              {"id": "e", "config": {"context_length": 65536, "parallel": "4"}}]},
        {"key": "mixed", "type": "llm",
         "loaded_instances": [{"id": "f", "config": {"context_length": 131072, "parallel": 4}},
                              {"id": "g", "config": {"context_length": 65536, "parallel": 1}}]},
        {"key": "tiny", "type": "llm", "max_context_length": 4096,
         "loaded_instances": [{"id": "h", "config": {"context_length": 2, "parallel": 4}}]},
    ]}

    def windows():
        return {r["name"]: (r["context_length"], r["served_context_length"])
                for r in router._lmstudio_v1_models(payload)}

    assert windows() == {"split": (32768, 32768), "single": (262144, 262144),
                         "unreported": (65536, 65536), "bogus": (65536, 65536),
                         "mixed": (32768, 32768), "tiny": (4096, None)}
    raw = router._lmstudio_v1_models(payload)[0]
    assert router.build_entry("lmstudio+http://h:1234", raw, raw["capabilities"])["served_context_length"] == 32768
    monkeypatch.setattr(router, "LMSTUDIO_UNIFIED_KV", True)
    assert windows() == {"split": (262144, 262144), "single": (262144, 262144),
                         "unreported": (65536, 65536), "bogus": (65536, 65536),
                         "mixed": (65536, 65536), "tiny": (2, 2)}


def test_show_served_context(router):
    served = router.show_served_context
    # The model's own limit alone: Ollama serves its OLLAMA_CONTEXT_LENGTH.
    assert served({"model_info": {"qwen3.context_length": 40960}}) is None
    assert served({"model_info": {"llama.context_length": 131072},
                   "parameters": "stop <eot>\nnum_ctx 65536"}) == 65536
    # A num_ctx above the model's limit is served at the limit.
    assert served({"model_info": {"llama.context_length": 32768},
                   "parameters": "num_ctx 65536"}) == 32768
    for nothing in ({}, {"parameters": "num_ctx big"}, {"parameters": None}):
        assert served(nothing) is None


def test_discovery_records_served_context(served):
    router, upstream, client = served
    router._CAPABILITIES.clear()
    router._CONTEXTS.clear()
    router._SERVED_CONTEXTS.clear()
    upstream.inventory = {HOST_A: tags(("qwen3:14b", "14.8B", "qwen3")),
                          HOST_B: tags(("bridged", "27B", "qwen3"))}
    upstream.capabilities.update({"qwen3:14b": ["completion", "tools"], "bridged": ["completion", "tools"]})
    upstream.show_extra.update({
        "qwen3:14b": {"model_info": {"qwen3.context_length": 40960}},
        "bridged": {"model_info": {"qwen3.context_length": 262144}, "parameters": "num_ctx 131072"}})
    assert client.post("/routing/refresh").status_code == 200
    inventory = {e["name"]: e for e in client.get("/routing/inventory").json()["models"]}
    assert (inventory["qwen3:14b"]["context_length"], inventory["qwen3:14b"]["served_context_length"]) == (40960, None)
    assert (inventory["bridged"]["context_length"], inventory["bridged"]["served_context_length"]) == (131072, 131072)
    # /v1/models advertises only a served context.
    listed = {m["id"]: m for m in client.get("/v1/models").json()["data"]}
    assert listed["bridged"]["context_length"] == 131072
    assert "context_length" not in listed["qwen3:14b"]
    assert "context_length" not in listed["auto"]


def test_served_contexts_take_every_replica(router):
    contexts = router.served_contexts([
        {"name": "a", "served_context_length": 262144},
        {"name": "a", "served_context_length": 131072},
        {"name": "b", "served_context_length": 65536},
        {"name": "b", "served_context_length": None},   # a replica that may serve less
        {"name": "c", "served_context_length": None},
        {"name": "d", "served_context_length": None},
        {"name": "d", "served_context_length": 65536},
    ])
    assert contexts == {"a": 131072}


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
    # These servers report the window they run with: it is the served one.
    assert {e["name"]: e["served_context_length"] for e in entries} == {"a": 65536, "b": 32768, "c": None}


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
    ini = (ROOT / "services/osr-router/router.ini").read_text()
    assert "\ntool_kinds = strata, basalt, maya, xolotl, avalon, kindi, colibri\n" in ini
    custom = tmp_path / "router.ini"
    custom.write_text(ini.replace("tool_kinds = strata, basalt, maya, xolotl, avalon, kindi, colibri",
                                  "tool_kinds = Avalon, ollama, nonsense"))
    with caplog.at_level("WARNING", logger="router"):
        router = load_router(monkeypatch, ROUTER_INI=str(custom))
    assert router.TOOL_KINDS == {"avalon"}
    assert sorted(r.getMessage() for r in caplog.records if "tool_kinds" in r.getMessage()) == [
        "ignoring [classification] tool_kinds entry 'nonsense' (use avalon, basalt, colibri, kindi, maya, strata, xolotl)",
        "ignoring [classification] tool_kinds entry 'ollama' (use avalon, basalt, colibri, kindi, maya, strata, xolotl)"]
    assert _openai_listing(router, "avalon+http://h:8080", [{"id": "m"}])["m"]["tools"] is True
    assert _openai_listing(router, "strata+http://h:8080", [{"id": "m"}])["m"]["tools"] is None
    custom.write_text(ini.replace("tool_kinds = strata, basalt, maya, xolotl, avalon, kindi, colibri", "tool_kinds ="))
    assert load_router(monkeypatch, ROUTER_INI=str(custom)).TOOL_KINDS == frozenset()
    # The built-in default matches router.ini, for a router.ini without the line.
    assert load_router(monkeypatch, ROUTER_INI=str(tmp_path / "missing.ini")).TOOL_KINDS == {
        "strata", "basalt", "maya", "xolotl", "avalon", "kindi", "colibri"}


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
    ini.write_text((ROOT / "services/osr-router/router.ini").read_text()
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
    # Conversations that begin differently: ties rotate, as before.
    plain = {chat(client, messages=[user(f"hi {n}")]).json()["model"] for n in range(4)}
    assert plain == {"qwen3:14b", "llama9:14b"}
    # Agent loops, whichever task: one model, never the other.
    tooled = {chat(client, tools=TOOLS, messages=[user(f"task {n}")]).json()["model"] for n in range(4)}
    assert len(tooled) == 1
    # The same model on two hosts still shares the load between tasks...
    tool_pool(router, upstream, client, ("qwen3:14b", "14B", "qwen3"),
              ("qwen3:14b", "14B", "qwen3"), caps)
    upstream.calls.clear()
    for n in range(4):
        chat(client, tools=TOOLS, messages=[user(f"another task {n}")])
    assert set(served_hosts(upstream)) == {HOST_A, HOST_B}
    # ...while one task's requests stay on the host that holds its prompt cache.
    upstream.calls.clear()
    for _ in range(4):
        chat(client, tools=TOOLS, messages=[user("one long task")])
    assert len(set(served_hosts(upstream))) == 1


def test_explain_lists_tool_support(served):
    router, upstream, client = served
    tool_pool(router, upstream, client, ("gemma3:12b", "12.2B", "gemma3"),
              ("qwen3:14b", "14.8B", "qwen3"),
              {"gemma3:12b": ["completion"], "qwen3:14b": ["completion", "tools"]})
    body = client.post("/routing/explain", json={"messages": [user("hi")], "tools": TOOLS}).json()
    assert [c["model"] for c in body["candidates"]] == ["qwen3:14b"]
    assert body["candidates"][0]["tools"] is True


# --- /api/show cache lifetime ----------------------------------------------------
def _age_show_cache(router, seconds):
    """Let `seconds` pass for every cached /api/show answer."""
    for key in router._SHOW_TIMES:
        router._SHOW_TIMES[key] -= seconds


def _digest_inventory(upstream, digest="sha256:aaa"):
    """HOST_A as Ollama lists a model (with its digest); HOST_B as the
    llama.cpp bridge does (no digest)."""
    upstream.inventory[HOST_A] = {"models": [{
        "name": "qwen3:14b", "digest": digest,
        "details": {"parameter_size": "14.8B", "family": "qwen3"}}]}
    upstream.inventory[HOST_B] = tags(("bridge-model:7b", "7B", "llama"))
    upstream.capabilities.update({"qwen3:14b": ["completion"], "bridge-model:7b": ["completion"]})


def test_show_answers_outlive_a_poll_for_models_with_a_digest(served):
    router, upstream, client = served
    assert router.SHOW_CACHE_SECONDS == 3600
    _digest_inventory(upstream)
    client.post("/routing/refresh")
    # Two minutes on, a poll asks only the server that lists no digest.
    _age_show_cache(router, 120)
    upstream.show_calls.clear()
    client.post("/routing/refresh?probe=false")
    assert upstream.show_calls == [(HOST_B, "bridge-model:7b")]
    # After show_cache_seconds the digest's answer has expired too.
    _age_show_cache(router, 3600)
    upstream.show_calls.clear()
    client.post("/routing/refresh?probe=false")
    assert sorted(upstream.show_calls) == [(HOST_A, "qwen3:14b"), (HOST_B, "bridge-model:7b")]


def test_a_new_digest_is_probed_at_once_and_the_old_answer_forgotten(served):
    router, upstream, client = served
    _digest_inventory(upstream)
    upstream.show_extra["qwen3:14b"] = {"parameters": "num_ctx 8192"}
    client.post("/routing/refresh")
    assert (HOST_A, "qwen3:14b", "sha256:aaa") in router._CAPABILITIES
    # The model is re-created with another window: a new digest.
    _digest_inventory(upstream, "sha256:bbb")
    upstream.show_extra["qwen3:14b"] = {"parameters": "num_ctx 32768"}
    upstream.show_calls.clear()
    client.post("/routing/refresh?probe=false")
    assert (HOST_A, "qwen3:14b") in upstream.show_calls
    entry = [e for e in router.INVENTORY["models"] if e["server"] == HOST_A][0]
    assert entry["context_length"] == 32768
    for cache in (router._CAPABILITIES, router._CONTEXTS, router._SHOW_TIMES):
        assert [k for k in cache if k[0] == HOST_A] == [(HOST_A, "qwen3:14b", "sha256:bbb")]
    # A model the server no longer lists is forgotten as well.
    upstream.inventory[HOST_A] = {"models": []}
    client.post("/routing/refresh?probe=false")
    assert not [k for k in router._CAPABILITIES if k[0] == HOST_A]


def test_refresh_probes_every_model_unless_told_not_to(served):
    router, upstream, client = served
    _digest_inventory(upstream)
    client.post("/routing/refresh")
    upstream.show_calls.clear()
    assert client.post("/routing/refresh?probe=false").status_code == 200
    assert upstream.show_calls == []          # both answers are fresh
    client.post("/routing/refresh")
    assert sorted(upstream.show_calls) == [(HOST_A, "qwen3:14b"), (HOST_B, "bridge-model:7b")]


def test_show_cache_seconds_is_a_setting(monkeypatch, tmp_path):
    ini = tmp_path / "router.ini"
    ini.write_text("[discovery]\nshow_cache_seconds = 30\n")
    router = load_router(monkeypatch, ROUTER_INI=str(ini))
    assert router.SHOW_CACHE_SECONDS == 30
    assert router._show_ttl({"digest": "sha256:aaa"}) == 30
    assert router._show_ttl({"name": "no-digest"}) == 30     # never longer than the setting
    assert load_router(monkeypatch)._show_ttl({"name": "no-digest"}) == 60


# --- the request body is not re-encoded needlessly ---------------------------------
def _chat_bodies(upstream):
    return [call[3] for call in upstream.calls if call[1] == "/v1/chat/completions"]


def test_a_named_models_body_is_forwarded_as_sent(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "_json_bytes", lambda payload: pytest.fail("the body was re-encoded"))
    raw = b'{"model": "qwen3:14b",  "messages": [{"role": "user", "content": "h\xc3\xa9llo"}]}'
    response = client.post("/v1/chat/completions", content=raw,
                           headers={"content-type": "application/json"})
    assert response.status_code == 200
    assert _chat_bodies(upstream) == [raw]


def test_a_routed_body_is_encoded_once_for_the_same_model_on_two_hosts(served, monkeypatch):
    router, upstream, client = served
    upstream.chat = {HOST_A: 500, HOST_B: 500}
    encodings, real = [], router._json_bytes
    monkeypatch.setattr(router, "_json_bytes", lambda payload: encodings.append(payload["model"]) or real(payload))
    response = client.post("/v1/chat/completions",
                           json={"model": "auto", "messages": [user("héllo")]})
    assert response.status_code == 500        # the last candidate's answer is passed through
    bodies = _chat_bodies(upstream)
    assert len(bodies) == 2 and bodies[0] == bodies[1]
    assert encodings == ["qwen3:14b"]
    assert json.loads(bodies[0]) == {"model": "qwen3:14b", "messages": [user("héllo")]}
    assert "héllo".encode() in bodies[0]  # compact UTF-8, as httpx's json= produced


def test_a_body_in_another_encoding_is_sent_on_as_utf8(served):
    router, upstream, client = served
    payload = {"model": "qwen3:14b", "messages": [user("héllo")]}
    # UTF-16, and UTF-8 behind a byte order mark: json.loads reads both, but a
    # backend may not, so neither is passed through as it came.
    for raw in (json.dumps(payload).encode("utf-16"), b"\xef\xbb\xbf" + json.dumps(payload).encode()):
        upstream.calls.clear()
        assert client.post("/v1/chat/completions", content=raw).status_code == 200
        (sent,) = _chat_bodies(upstream)
        assert sent != raw and json.detect_encoding(sent) == "utf-8" and json.loads(sent) == payload


def test_a_body_without_a_content_type_is_still_sent_as_json(served):
    router, upstream, client = served
    raw = json.dumps({"model": "qwen3:14b", "messages": [user("hi")]}).encode()
    assert client.post("/v1/chat/completions", content=raw).status_code == 200
    headers = [call[2] for call in upstream.calls if call[1] == "/v1/chat/completions"][0]
    assert headers["content-type"] == "application/json"
    assert headers["content-length"] == str(len(raw))


def test_body_for_model_caches_per_name(router):
    body, cache = {"model": "auto", "messages": [user("hi")]}, {}
    first = router.body_for_model(body, "qwen3:14b", b"ignored", cache)
    assert json.loads(first)["model"] == "qwen3:14b" and body["model"] == "auto"
    assert router.body_for_model(body, "qwen3:14b", b"ignored", cache) is first
    assert json.loads(router.body_for_model(body, "llama3:8b", None, cache))["model"] == "llama3:8b"
    assert sorted(cache) == ["llama3:8b", "qwen3:14b"]


# --- the key check is plain ASGI middleware ---------------------------------------
def test_the_key_check_does_not_wrap_responses(router):
    from starlette.middleware.base import BaseHTTPMiddleware
    classes = [middleware.cls for middleware in router.app.user_middleware]
    assert classes == [router.RequestMiddleware, router.RouterKeyMiddleware]   # outermost first
    assert not any(issubclass(cls, BaseHTTPMiddleware) for cls in classes)


def test_api_key_failure_decides_from_path_and_headers(router, monkeypatch):
    assert router.api_key_failure("/v1/models", {}) is None          # no key configured
    assert router.api_key_failure("/v1/models", {"x-router-subscription": "1"}).status_code == 503
    monkeypatch.setattr(router, "ROUTER_API_KEY", "s3cret")
    assert router.api_key_failure("/healthz", {}) is None
    assert router.api_key_failure("/v1/models", {}).status_code == 401
    assert router.api_key_failure("/v1/models", {"authorization": "Bearer wrong"}).status_code == 401
    assert router.api_key_failure("/v1/models", {"authorization": "bearer s3cret"}) is None
    subscriber = {"x-router-subscription": "1", "authorization": "Bearer client-login"}
    assert router.api_key_failure("/v1/models", subscriber).status_code == 401
    assert router.api_key_failure("/v1/models", dict(subscriber, **{"x-router-api-key": "s3cret"})) is None


def test_a_streamed_reply_passes_the_key_check_chunk_by_chunk(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "ROUTER_API_KEY", "s3cret")
    payload = {"model": "qwen3:14b", "messages": [user("hi")], "stream": True}
    assert client.post("/v1/chat/completions", json=payload).status_code == 401
    with client.stream("POST", "/v1/chat/completions", json=payload,
                       headers={"authorization": "Bearer s3cret"}) as response:
        assert response.status_code == 200
        assert json.loads(b"".join(response.iter_raw()))["model"] == "qwen3:14b"


# --- load awareness: requests in flight -------------------------------------------
def _need(router, text="hi", **body):
    return router.apply_tool_needs(router.classify_request([user(text)]), body)


def _first_servers(router, need, times=4, **kwargs):
    return [router.rank_candidates(need, **kwargs)[0]["server"] for _ in range(times)]


def test_in_flight_counts_a_request_until_it_is_released(router):
    first, second = router.InFlight(HOST_A), router.InFlight(HOST_A)
    other = router.InFlight(HOST_B)
    assert router._IN_FLIGHT == {HOST_A: 2, HOST_B: 1}
    first.release()
    first.release()                       # a second release counts nothing
    assert router._IN_FLIGHT == {HOST_A: 1, HOST_B: 1}
    del second                            # a forgotten one is released when collected
    other.release()
    assert router._IN_FLIGHT == {}


def test_a_busy_server_gives_way_to_an_idle_twin(served):
    router, upstream, client = served     # the same model on HOST_A and HOST_B
    need = _need(router)
    assert set(_first_servers(router, need)) == {HOST_A, HOST_B}      # idle: they rotate
    held = router.InFlight(HOST_A)
    assert set(_first_servers(router, need)) == {HOST_B}
    also = router.InFlight(HOST_B)
    assert set(_first_servers(router, need)) == {HOST_A, HOST_B}      # equally busy: rotate again
    more = [router.InFlight(HOST_B), router.InFlight(HOST_B)]
    ranked = router.rank_candidates(need)
    assert [e["server"] for e in ranked] == [HOST_A, HOST_B]
    assert router.score_entry(ranked[0], need) - router.score_entry(ranked[1], need) == pytest.approx(0.06)
    for slot in (held, also, *more):
        slot.release()


def test_a_loaded_server_keeps_its_lead_for_one_request_in_flight(served):
    router, upstream, client = served
    upstream.running = {HOST_A: ["qwen3:14b"], HOST_B: []}            # in memory on A only
    client.post("/routing/refresh")
    need = _need(router)
    assert set(_first_servers(router, need)) == {HOST_A}
    slots = [router.InFlight(HOST_A)]
    assert set(_first_servers(router, need)) == {HOST_A}              # one request is no reason to load it elsewhere
    slots.append(router.InFlight(HOST_A))
    assert set(_first_servers(router, need)) == {HOST_B}              # two are
    for slot in slots:
        slot.release()


def test_busy_penalty_zero_turns_load_awareness_off(served, monkeypatch):
    router, upstream, client = served
    need = _need(router)
    idle_score = router.score_entry(router.rank_candidates(need)[0], need)
    monkeypatch.setattr(router, "BUSY_PENALTY", 0.0)
    slots = [router.InFlight(HOST_A) for _ in range(5)]
    assert set(_first_servers(router, need)) == {HOST_A, HOST_B}
    assert all(router.score_entry(e, need) == idle_score for e in router.rank_candidates(need))
    for slot in slots:
        slot.release()


def test_busy_penalty_is_a_setting(monkeypatch, tmp_path):
    ini = tmp_path / "router.ini"
    ini.write_text("[balancing]\nbusy_penalty = 0.2\nsticky_seconds = 60\n")
    router = load_router(monkeypatch, ROUTER_INI=str(ini))
    assert (router.BUSY_PENALTY, router.STICKY_SECONDS) == (0.2, 60)
    defaults = load_router(monkeypatch)
    assert (defaults.BUSY_PENALTY, defaults.STICKY_SECONDS) == (0.03, 1800)


class _InFlightSpy(list):
    """upstream.calls that also notes what was in flight when each call arrived."""

    def __init__(self, router):
        super().__init__()
        self.router, self.seen = router, []

    def append(self, call):
        if call[1] == "/v1/chat/completions":
            self.seen.append((call[0], dict(self.router._IN_FLIGHT)))
        super().append(call)


def test_requests_are_counted_while_they_run_and_released_after(served):
    router, upstream, client = served
    upstream.calls = spy = _InFlightSpy(router)
    assert chat(client).status_code == 200
    (host, counted), = spy.seen
    assert counted == {host: 1}
    assert router._IN_FLIGHT == {}
    # Streamed: counted until the body has been relayed.
    with client.stream("POST", "/v1/chat/completions",
                       json={"model": "auto", "stream": True, "messages": [user("streamed")]}) as response:
        response.read()
    assert router._IN_FLIGHT == {}


@pytest.mark.parametrize("failures", [
    {HOST_A: 500, HOST_B: 500}, {HOST_A: "connect", HOST_B: "timeout"}, {HOST_A: 404, HOST_B: "connect"}])
def test_a_failed_attempt_stops_counting_before_the_next_one(served, failures):
    router, upstream, client = served
    upstream.chat = dict(failures)
    upstream.calls = spy = _InFlightSpy(router)
    chat(client)
    assert len(spy.seen) == 2
    for host, counted in spy.seen:
        assert counted == {host: 1}       # the attempt before it is no longer counted
    assert router._IN_FLIGHT == {}


def test_a_stream_stops_counting_when_it_ends_breaks_or_is_dropped(router):
    import asyncio

    async def chunks():
        yield b"a"
        yield b"b"

    async def broken():
        yield b"a"
        raise httpx.ReadError("gone")

    async def run():
        slot = router.InFlight(HOST_A)
        assert [c async for c in router._relay_counted(slot, chunks())] == [b"a", b"b"]
        assert router._IN_FLIGHT == {}
        slot = router.InFlight(HOST_A)
        with pytest.raises(httpx.ReadError):
            [c async for c in router._relay_counted(slot, broken())]
        assert router._IN_FLIGHT == {}
        slot = router.InFlight(HOST_A)
        stream = router._relay_counted(slot, chunks())
        assert await anext(stream) == b"a" and router._IN_FLIGHT == {HOST_A: 1}
        await stream.aclose()             # the client stopped reading
        assert router._IN_FLIGHT == {}

    asyncio.run(run())


def test_inventory_and_explain_show_requests_in_flight(served):
    router, upstream, client = served
    slot = router.InFlight(HOST_A)
    assert client.get("/routing/inventory").json()["in_flight"] == {HOST_A: 1}
    candidates = client.post("/routing/explain", json={"prompt": "hi"}).json()["candidates"]
    assert {c["server"]: c["in_flight"] for c in candidates} == {HOST_A: 1, HOST_B: 0}
    assert candidates[0]["server"] == HOST_B and candidates[0]["score"] > candidates[1]["score"]
    slot.release()
    assert client.get("/routing/inventory").json()["in_flight"] == {}


# --- conversation affinity ---------------------------------------------------------
def _turns(opening, replies=0):
    """A conversation's messages at its first request, or after `replies` answers."""
    messages = [{"role": "system", "content": "Be brief."}, user(opening)]
    for n in range(replies):
        messages += [{"role": "assistant", "content": f"answer {n} to {opening}"}, user(f"follow-up {n}")]
    return messages


def _served_by(client, messages, **body):
    response = chat(client, messages=messages, **body)
    assert response.status_code == 200
    return response.json()["served_by"]


def test_conversation_keys_name_how_a_conversation_began(router):
    first = router.conversation_keys(_turns("how do magnets work"))
    assert len(first) == 1                                    # nothing but the opening yet
    second = router.conversation_keys(_turns("how do magnets work", replies=1))
    third = router.conversation_keys(_turns("how do magnets work", replies=3))
    assert second == third and len(second) == 2 and second[1] == first[0]
    assert router.conversation_keys(_turns("something else"))[0] != first[0]
    # The same opening, answered differently: told apart from the second turn on.
    other = _turns("how do magnets work", replies=1)
    other[2] = {"role": "assistant", "content": "a different answer"}
    assert router.conversation_keys(other)[1] == first[0]
    assert router.conversation_keys(other)[0] != second[0]
    # A first reply that only calls tools is told apart by its calls.
    def tooled(call_id):
        return [user("do the task"), {"role": "assistant", "content": None, "tool_calls": [
            {"id": call_id, "type": "function", "function": {"name": "run", "arguments": "{}"}}]}]
    assert router.conversation_keys(tooled("call_1"))[0] != router.conversation_keys(tooled("call_2"))[0]
    assert router.conversation_keys(tooled("call_1")) == router.conversation_keys(tooled("call_1"))
    # Text parts are hashed, images are not; and nothing readable is kept.
    image = {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA"}}
    parts = [{"role": "user", "content": [{"type": "text", "text": "what is this"}, image]}]
    assert router.conversation_keys(parts) == router.conversation_keys([user("what is this")])
    assert all(len(key) == 32 and "magnets" not in key for key in second)
    assert router.conversation_keys([]) == router.conversation_keys(None) == []
    assert router.conversation_keys([{"role": "system", "content": "only a system prompt"}, "junk"]) == []


def test_a_conversation_stays_on_the_server_that_answered_it(served):
    router, upstream, client = served     # the same model on HOST_A and HOST_B
    home = _served_by(client, _turns("how do magnets work"))
    for replies in (1, 2, 3):
        assert _served_by(client, _turns("how do magnets work", replies)) == home
    # Other conversations are still spread over both servers.
    assert {_served_by(client, _turns(f"question {n}")) for n in range(4)} == {HOST_A, HOST_B}
    # And a named model keeps its conversation's server the same way.
    named = _served_by(client, _turns("a named one"), model="qwen3:14b")
    for replies in (1, 2):
        assert _served_by(client, _turns("a named one", replies), model="qwen3:14b") == named
    assert {_served_by(client, _turns(f"named {n}"), model="qwen3:14b") for n in range(4)} == {HOST_A, HOST_B}


def test_a_conversation_moves_to_an_idle_server_and_then_stays_there(served):
    router, upstream, client = served
    home = _served_by(client, _turns("a long chat"))
    away = HOST_B if home == HOST_A else HOST_A
    busy = router.InFlight(home)          # another conversation is using its server
    assert _served_by(client, _turns("a long chat", 1)) == away
    busy.release()
    assert _served_by(client, _turns("a long chat", 2)) == away      # its prompt cache is there now
    # Both equally busy: it stays where it is.
    slots = [router.InFlight(HOST_A), router.InFlight(HOST_B)]
    assert _served_by(client, _turns("a long chat", 3)) == away
    for slot in slots:
        slot.release()


def test_affinity_ends_after_sticky_seconds_or_when_turned_off(served, monkeypatch):
    router, upstream, client = served
    home = _served_by(client, _turns("soon forgotten"))
    assert router.sticky_choice(router.conversation_keys(_turns("soon forgotten"))) == (home, "qwen3:14b")
    for key, (server, model, when) in list(router._STICKY.items()):
        router._STICKY[key] = (server, model, when - router.STICKY_SECONDS - 1)
    assert router.sticky_choice(router.conversation_keys(_turns("soon forgotten"))) is None
    assert not router._STICKY             # an expired entry is dropped when it is looked up
    monkeypatch.setattr(router, "STICKY_SECONDS", 0.0)
    assert router.conversation_keys(_turns("never kept")) == []
    assert {_served_by(client, _turns("never kept")) for _ in range(4)} == {HOST_A, HOST_B}
    assert not router._STICKY


def test_the_affinity_store_is_bounded(router, monkeypatch):
    monkeypatch.setattr(router, "STICKY_MAX", 3)
    entry = {"server": HOST_A, "name": "qwen3:14b"}
    for n in range(5):
        router.remember_choice([f"key{n}"], entry)
    assert list(router._STICKY) == ["key2", "key3", "key4"]
    router.sticky_choice(["key2"])                             # looking one up does not renew it
    router.remember_choice(["key2"], entry)                    # an answer does
    router.remember_choice(["key5"], entry)
    assert list(router._STICKY) == ["key4", "key2", "key5"]
    router.remember_choice([], entry)
    router.remember_choice(None, entry)
    assert len(router._STICKY) == 3


def test_an_error_answer_is_not_remembered(served):
    router, upstream, client = served
    upstream.chat = {HOST_A: 500, HOST_B: 500}
    assert chat(client, messages=_turns("fails everywhere")).status_code == 500
    assert not router._STICKY


def test_affinity_never_overrides_the_scores(served):
    router, upstream, client = served
    keys = router.conversation_keys(_turns("was on A"))
    router.remember_choice(keys, {"server": HOST_A, "name": "qwen3:14b"})
    need = _need(router)
    assert set(_first_servers(router, need, affinity=keys)) == {HOST_A}       # tied: its server
    upstream.running = {HOST_A: [], HOST_B: ["qwen3:14b"]}                    # now loaded on B only
    client.post("/routing/refresh")
    assert set(_first_servers(router, need, affinity=keys)) == {HOST_B}       # B scores higher: B
    # A server that is down is not a candidate, remembered or not.
    upstream.running = {}
    client.post("/routing/refresh")
    router.mark_server_down(HOST_A, "test")
    assert set(_first_servers(router, need, affinity=keys)) == {HOST_B}


def test_a_task_keeps_its_model_among_tied_models(served):
    router, upstream, client = served
    caps = {"qwen3:14b": ["completion", "tools"], "llama9:14b": ["completion", "tools"]}
    tool_pool(router, upstream, client, ("qwen3:14b", "14B", "qwen3"),
              ("llama9:14b", "14B", "llama"), caps)
    usual = chat(client, tools=TOOLS, messages=_turns("some task")).json()["model"]
    other = "llama9:14b" if usual == "qwen3:14b" else "qwen3:14b"
    # A task that has been running on the other model keeps it.
    keys = router.conversation_keys(_turns("an older task"))
    host = [e for e in router.INVENTORY["models"] if e["name"] == other][0]
    router.remember_choice(keys, host)
    for replies in (0, 1, 2):
        answer = chat(client, tools=TOOLS, messages=_turns("an older task", replies)).json()
        assert answer["model"] == other
    assert chat(client, tools=TOOLS, messages=_turns("a new task")).json()["model"] == usual


def test_the_route_log_says_when_a_conversation_kept_its_server(served, caplog):
    router, upstream, client = served
    with caplog.at_level("INFO", logger="router"):
        _served_by(client, _turns("logged"))
        assert "same server as last turn" not in caplog.text
        _served_by(client, _turns("logged", 1))
        assert "same server as last turn" in caplog.text


# --- request IDs -------------------------------------------------------------------
def _upstream_headers(upstream, path="/v1/chat/completions"):
    return [call[2] for call in upstream.calls if call[1] == path]


def test_every_answer_carries_a_request_id(served):
    router, upstream, client = served
    response = chat(client)
    made = response.headers["x-router-request-id"]
    assert re.fullmatch(r"[0-9a-f]{16}", made)
    assert response.headers["x-request-id"] == made                 # where OpenAI clients look
    assert _upstream_headers(upstream)[-1]["x-request-id"] == made   # and the backend's log has it
    other = chat(client).headers["x-router-request-id"]
    assert other != made
    # Paths that route nothing have one as well, and so does a refusal.
    assert client.get("/healthz").headers["x-router-request-id"]
    assert client.post("/v1/chat/completions", content=b"{not json").headers["x-router-request-id"]


def test_a_callers_request_id_is_kept_when_it_is_plain(served):
    router, upstream, client = served
    response = chat_with(client, {"X-Request-ID": "ticket-4711.a:b_c"})
    assert response.headers["x-router-request-id"] == "ticket-4711.a:b_c"
    assert _upstream_headers(upstream)[-1]["x-request-id"] == "ticket-4711.a:b_c"
    for odd in ("has space", "x" * 65, "semi;colon", "quote\"d", "a/b"):
        response = chat_with(client, {"X-Request-ID": odd})
        made = response.headers["x-router-request-id"]
        assert made != odd and re.fullmatch(r"[0-9a-f]{16}", made)
        assert _upstream_headers(upstream)[-1]["x-request-id"] == made   # the odd one goes no further
    assert router.accept_request_id(None) != router.accept_request_id("")


def chat_with(client, headers, **body):
    payload = {"model": "auto", "messages": [user("hi")]}
    payload.update(body)
    return client.post("/v1/chat/completions", json=payload, headers=headers)


def test_a_refused_request_has_an_id_and_is_counted(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "ROUTER_API_KEY", "s3cret")
    response = chat(client)
    assert response.status_code == 401 and response.headers["x-router-request-id"]
    assert 'osr_requests_total{class="",mode="",model="",route="chat",server="",status="401"} 1' in \
        router.render_metrics()


def test_an_upstream_request_id_on_the_answer_is_left_alone(router):
    async def app(scope, receive, send):
        await send({"type": "http.response.start", "status": 200,
                    "headers": [(b"x-request-id", b"req_from_the_provider")]})
        await send({"type": "http.response.body", "body": b"ok"})

    response = TestClient(router.RequestMiddleware(app)).get("/v1/models", headers={"X-Request-ID": "mine-1"})
    assert response.headers["x-request-id"] == "req_from_the_provider"
    assert response.headers["x-router-request-id"] == "mine-1"


def test_log_lines_of_a_request_start_with_its_id(served, caplog):
    router, upstream, client = served
    upstream.chat = {HOST_A: 500, HOST_B: 500}
    with caplog.at_level("INFO", logger="router"):
        made = chat_with(client, {"X-Request-ID": "trace-me"}).headers["x-router-request-id"]
        client.post("/routing/refresh")
    assert made == "trace-me"
    mine = [r.getMessage() for r in caplog.records if r.name == "router" and "trace-me" in r.getMessage()]
    assert any(m.startswith("[trace-me] dispatch: ") and "trying the next candidate" in m for m in mine)
    assert any(m.startswith("[trace-me] route class=") for m in mine)
    assert all(m.startswith("[trace-me] ") for m in mine)
    assert router.request_id() == ""                                # nothing lingers after the request
    # The logger is shared across reloads of the module: still one prefix only.
    assert not any(m.startswith("[trace-me] [trace-me]") for m in mine)


# --- /metrics ------------------------------------------------------------------------
def _metric(text, name, **labels):
    """The value of one series in a /metrics page, or None."""
    upper = labels.pop("le", None)                  # a histogram's bound comes last
    pairs = sorted(labels.items()) + ([("le", upper)] if upper else [])
    want = "{%s}" % ",".join('%s="%s"' % item for item in pairs) if pairs else ""
    for line in text.splitlines():
        if line.startswith(name + want + " "):
            return float(line.rsplit(" ", 1)[1])
    return None


def test_metrics_count_requests_by_how_they_were_served(served):
    router, upstream, client = served
    for n in range(3):
        assert chat(client, messages=[user(f"question {n}")]).status_code == 200
    upstream.chat = {HOST_A: 500, HOST_B: 500}
    assert chat(client, messages=[user("fails")]).status_code == 500
    client.post("/v1/chat/completions", content=b"{not json")
    client.get("/routing/inventory")
    client.get("/healthz")
    page = client.get("/metrics")
    assert page.status_code == 200 and page.headers["content-type"].startswith("text/plain; version=0.0.4")
    text = page.text
    served_ok = [_metric(text, "osr_requests_total", **{"class": "fast"}, mode="discovery", model="qwen3:14b",
                         route="chat", server=host, status="200") or 0 for host in (HOST_A, HOST_B)]
    assert sum(served_ok) == 3
    assert sum(_metric(text, "osr_requests_total", **{"class": "fast"}, mode="discovery", model="qwen3:14b",
                       route="chat", server=host, status="500") or 0 for host in (HOST_A, HOST_B)) == 1
    assert _metric(text, "osr_requests_total", **{"class": ""}, mode="", model="", route="chat",
                   server="", status="400") == 1
    assert _metric(text, "osr_requests_total", **{"class": ""}, mode="", model="", route="routing",
                   server="", status="200") == 1
    assert "healthz" not in text and 'route="other"' not in text and "/metrics" not in text
    # Both failing servers were tried, and counted, once each.
    for host in (HOST_A, HOST_B):
        assert _metric(text, "osr_upstream_failures_total", reason="http_500", server=host) == 1
    # Timings: one observation per request answered below 400, in every bucket above it.
    counts = [_metric(text, "osr_request_duration_seconds_count", mode="discovery", model="qwen3:14b",
                      server=host) or 0 for host in (HOST_A, HOST_B)]
    assert sum(counts) == 3
    starts = [_metric(text, "osr_response_start_seconds_bucket", mode="discovery", model="qwen3:14b",
                      server=host, le="+Inf") or 0 for host in (HOST_A, HOST_B)]
    assert sum(starts) == 3
    assert "# TYPE osr_request_duration_seconds histogram" in text
    assert "# TYPE osr_requests_total counter" in text and "# HELP osr_requests_total " in text


def test_metric_timing_includes_sending_headers_and_final_body(router):
    async def app(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        await asyncio.sleep(0.02)

    scope = {"type": "http", "path": "/v1/chat/completions", "headers": []}
    asyncio.run(router.RequestMiddleware(app)(scope, receive, send))
    text = router.render_metrics()
    assert _metric(text, "osr_response_start_seconds_sum", mode="", model="", server="") >= 0.02
    assert _metric(text, "osr_request_duration_seconds_sum", mode="", model="", server="") >= 0.04


def test_metrics_report_servers_and_load(served):
    router, upstream, client = served
    upstream.chat = {HOST_A: "connect"}
    for n in range(2):
        chat(client, messages=[user(f"to the other one {n}")])
    slot = router.InFlight(HOST_B)
    text = client.get("/metrics").text
    assert _metric(text, "osr_server_up", kind="ollama", server=HOST_A) == 0       # marked down by the failed attempt
    assert _metric(text, "osr_server_up", kind="ollama", server=HOST_B) == 1
    assert _metric(text, "osr_server_models", server=HOST_B) == 1
    assert _metric(text, "osr_in_flight_requests", server=HOST_B) == 1
    assert _metric(text, "osr_in_flight_requests", server=HOST_A) == 0
    assert _metric(text, "osr_upstream_failures_total", reason="connect", server=HOST_A) == 1
    assert _metric(text, "osr_remembered_conversations") == 2
    assert _metric(text, "osr_inventory_age_seconds") >= 0
    assert _metric(text, "osr_start_time_seconds") == pytest.approx(time.time(), abs=120)
    slot.release()


def test_metrics_count_a_tool_rejection(served):
    router, upstream, client = served
    upstream.capabilities["qwen3:14b"] = ["completion", "tools"]
    client.post("/routing/refresh")
    upstream.tool_less.add("qwen3:14b")
    chat(client, tools=TOOLS)
    text = client.get("/metrics").text
    rejected = [_metric(text, "osr_upstream_failures_total", reason="tool_rejection", server=host) or 0
                for host in (HOST_A, HOST_B)]
    assert sum(rejected) == 2


def test_metrics_need_the_router_key(served, monkeypatch):
    router, upstream, client = served
    monkeypatch.setattr(router, "ROUTER_API_KEY", "s3cret")
    assert client.get("/metrics").status_code == 401
    assert client.get("/metrics", headers={"authorization": "Bearer s3cret"}).status_code == 200


def test_metric_labels_never_come_from_the_client(served):
    router, upstream, client = served
    chat_with(client, {"X-Request-ID": "client-chosen-id", "X-Router-Model": "spoofed",
                       "X-Router-Server": "http://evil.example"},
              model="no-such-model-the-client-made-up", messages=[user("hi there")])
    text = client.get("/metrics").text
    for word in ("client-chosen-id", "spoofed", "evil.example", "no-such-model"):
        assert word not in text


def test_metric_text_format(router):
    assert router._label_text((("server", 'a"b\\c\nd'),)) == '{server="a\\"b\\\\c\\nd"}'
    assert router._label_text((), 'le="1"') == '{le="1"}' and router._label_text(()) == ""
    assert (router._number(3), router._number(2.0), router._number(0.25)) == ("3", "2", "0.25")
    router.observe("osr_request_duration_seconds", 0.2, server="s")
    router.observe("osr_request_duration_seconds", 7.0, server="s")
    router.observe("osr_request_duration_seconds", 9999.0, server="s")     # beyond the last bucket
    text = router.render_metrics()
    series = {line.rsplit(" ", 1)[0]: float(line.rsplit(" ", 1)[1]) for line in text.splitlines()
              if line.startswith("osr_request_duration_seconds") and 'server="s"' in line}
    assert series['osr_request_duration_seconds_bucket{server="s",le="0.1"}'] == 0
    assert series['osr_request_duration_seconds_bucket{server="s",le="0.25"}'] == 1
    assert series['osr_request_duration_seconds_bucket{server="s",le="5"}'] == 1
    assert series['osr_request_duration_seconds_bucket{server="s",le="10"}'] == 2      # cumulative
    assert series['osr_request_duration_seconds_bucket{server="s",le="600"}'] == 2
    assert series['osr_request_duration_seconds_bucket{server="s",le="+Inf"}'] == 3
    assert series['osr_request_duration_seconds_count{server="s"}'] == 3
    assert series['osr_request_duration_seconds_sum{server="s"}'] == pytest.approx(10006.2)
    # Every sample line is "name{labels} number", and every metric is described.
    for line in text.splitlines():
        assert line.startswith("# ") or re.fullmatch(r'[a-z_]+(\{.*\})? [-+0-9.e]+', line), line
    for name in router.METRICS:
        assert f"# TYPE {name} " in text


def test_the_number_of_series_is_capped(router, monkeypatch):
    monkeypatch.setattr(router, "METRIC_SERIES_MAX", 3)
    for n in range(10):
        router.count("osr_requests_total", route=f"r{n}")
        router.observe("osr_request_duration_seconds", 1.0, server=f"s{n}")
    router.count("osr_requests_total", route="r0")           # an existing series still counts
    assert len(router._COUNTERS) == 3 and len(router._HISTOGRAMS) == 3
    assert router._COUNTERS[("osr_requests_total", (("route", "r0"),))] == 2



# --- image generation ---------------------------------------------------------------
COLIBRI_IMG = "colibri+http://10.0.0.16:8080"
COMFY = "http://10.0.0.30:8188"
KLEIN4 = {"unet_name": "flux-2-klein-4b-fp8.safetensors", "clip_name": "qwen_3_4b.safetensors",
          "vae_name": "flux2-vae.safetensors"}


class ImageUpstream:
    """A Colibri CT serving Qwen-Image, a ComfyUI CT with Klein 4B, LiteLLM."""

    def __init__(self):
        self.calls = []
        self.colibri = 200          # status, or "connect"
        self.comfy = "ok"           # ok, connect, refuse, error, poll_error
        self.cancel_status = 200    # POST /api/jobs/p1/cancel (404: a ComfyUI without the jobs API)
        self.comfy_files = dict(KLEIN4)
        self.history_polls = 0

    def __call__(self, request):
        host = f"{request.url.scheme}://{request.url.host}:{request.url.port}"
        path = request.url.path
        body = json.loads(request.content) if request.content else None
        self.calls.append((host, path, body, request.headers.get("authorization")))
        if host == "http://10.0.0.16:8080":
            if path == "/v1/models":
                return httpx.Response(200, json={"data": [
                    {"id": "qwen-image-2.1-colibri", "owned_by": "colibri",
                     "capabilities": ["image_generation"]}]})
            if path == "/v1/images/generations":
                if self.colibri == "connect":
                    raise httpx.ConnectError("refused", request=request)
                if self.colibri != 200:
                    return httpx.Response(self.colibri, json={"error": {"message": "nope"}})
                return httpx.Response(200, json={"created": 1, "data": [{"b64_json": "Q09MSUJSSQ==",
                                                                        "revised_prompt": None}],
                                                 "colibri": {"seed": 7, "steps": 8}})
        if host == COMFY:
            if self.comfy == "connect":
                raise httpx.ConnectError("refused", request=request)
            if path == "/system_stats":
                return httpx.Response(200, json={"system": {"comfyui_version": "0.9.0"}})
            if path.startswith("/object_info/"):
                node = path.rsplit("/", 1)[1]
                key = dict(router_loaders())[node]
                return httpx.Response(200, json={node: {"input": {"required": {
                    key: ["COMBO", {"options": [self.comfy_files.get(key, "other.safetensors")]}]}}}})
            if path == "/prompt":
                if self.comfy == "refuse":
                    return httpx.Response(400, json={"error": "bad workflow"})
                return httpx.Response(200, json={"prompt_id": "p1"})
            if path == "/history/p1":
                if self.comfy == "poll_error":
                    raise httpx.ReadTimeout("slow", request=request)
                self.history_polls += 1
                if self.history_polls < 2:
                    return httpx.Response(200, json={})
                status = ({"status_str": "error", "completed": False, "messages": ["oom"]}
                          if self.comfy == "error" else {"status_str": "success", "completed": True})
                return httpx.Response(200, json={"p1": {"status": status, "outputs": {
                    "13": {"images": [{"filename": "Flux2-Klein_0001_.png", "subfolder": "",
                                       "type": "output"}]}}}})
            if path == "/view":
                return httpx.Response(200, content=b"PNGDATA")
            if path == "/api/jobs/p1/cancel":
                return httpx.Response(self.cancel_status, json={"cancelled": True})
        if request.url.host == "litellm.test":
            if path == "/v1/models":
                return httpx.Response(200, json={"data": [
                    {"id": "openai/gpt-image-1"}, {"id": "openai/gpt-4.1"},
                    {"id": "qwen-image-2.1-colibri"}, {"id": "custom/flux-image"}]})
            if path == "/model/info":
                return httpx.Response(200, json={"data": [
                    {"model_name": "custom/flux-image", "model_info": {"mode": "image_generation"}}]})
            return streamed(200, {"created": 2, "data": [{"url": "https://cloud/x.png"}], "via": "litellm"})
        return httpx.Response(404)


def router_loaders():
    return (("UNETLoader", "unet_name"), ("CLIPLoader", "clip_name"), ("VAELoader", "vae_name"))


@pytest.fixture
def imaging(monkeypatch):
    def start(**env):
        router = load_router(monkeypatch, **{"MODEL_SERVERS": COLIBRI_IMG, "COLIBRI_API_KEY": "colibri-secret",
                                             "COMFYUI_SERVERS": COMFY, **env})
        router.COMFYUI_POLL_SECONDS = 0
        upstream = ImageUpstream()
        router._HTTP["transport"] = httpx.MockTransport(upstream)
        return router, upstream
    return start


def test_router_klein_workflows_match_the_comfyui_target(router):
    for variant, size in (("flux2-klein-4b", "4b"), ("flux2-klein-9b", "9b")):
        shipped = json.loads((ROOT / f"targets/comfyui/flux2-klein-{size}-api.json").read_text())
        assert router.COMFYUI_VARIANTS[variant]["workflow"] == shipped
        loaders = {node["class_type"]: node["inputs"] for node in shipped.values()}
        assert router.COMFYUI_VARIANTS[variant]["files"] == {
            "unet_name": loaders["UNETLoader"]["unet_name"], "clip_name": loaders["CLIPLoader"]["clip_name"],
            "vae_name": loaders["VAELoader"]["vae_name"]}


def test_image_models_are_listed_apart_from_chat(imaging):
    router, upstream = imaging()
    with TestClient(router.app) as client:
        chat = [m["id"] for m in client.get("/v1/models").json()["data"]]
        images = [m["id"] for m in client.get("/v1/images/models").json()["data"]]
        inventory = client.get("/routing/inventory").json()
    assert "qwen-image-2.1-colibri" not in chat and "flux2-klein-4b-comfyui" not in chat
    assert images == ["image", "flux2-klein-4b-comfyui", "qwen-image-2.1-colibri"]
    assert {(e["name"], e["kind"]) for e in inventory["images"]} == {
        ("flux2-klein-4b-comfyui", "comfyui"), ("qwen-image-2.1-colibri", "colibri")}
    assert inventory["image_alias"] == "image"
    assert inventory["server_status"][COMFY] == {"up": True, "model_count": 0, "image_models": 1}
    assert inventory["server_status"][COLIBRI_IMG]["image_models"] == 1
    assert router.INVENTORY["models"] == []


def test_down_image_server_is_not_listed(imaging):
    router, _ = imaging(COMFYUI_SERVERS="")
    with TestClient(router.app) as client:
        router.mark_server_down(COLIBRI_IMG, "connection lost")
        assert client.get("/v1/images/models").json()["data"] == []
        response = client.post("/v1/images/generations", json={
            "model": "qwen-image-2.1-colibri", "prompt": "a fox"})
    assert response.status_code == 503


# The second case: an image deployment added to LiteLLM by hand, which the
# router's CLOUD_*_MODELS does not name.
@pytest.mark.parametrize("cloud", ["gpt-image-1", ""])
def test_litellm_fallback_does_not_offer_image_models_for_chat(imaging, cloud):
    router, _ = imaging(OPENAI_API_KEY="sk-test", CLOUD_OPENAI_MODELS=cloud)
    with TestClient(router.app) as client:
        router.INVENTORY = dict(router.INVENTORY, models=[])
        models = [item["id"] for item in client.get("/v1/models").json()["data"]]
    assert "openai/gpt-4.1" in models
    assert "openai/gpt-image-1" not in models
    assert "qwen-image-2.1-colibri" not in models
    assert "custom/flux-image" not in models


def test_comfyui_without_the_klein_files_offers_nothing(imaging):
    router, upstream = imaging(MODEL_SERVERS="")
    upstream.comfy_files = {"unet_name": "flux-2-klein-4b-fp8.safetensors"}
    with TestClient(router.app) as client:
        assert client.get("/v1/images/models").json()["data"] == []
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
    assert response.status_code == 503 and response.json()["error"]["code"] == "no_image_server"


def test_alias_prefers_comfyui_and_fills_the_klein_workflow(imaging):
    router, upstream = imaging()
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={
            "model": "image", "prompt": "a lighthouse", "size": "1000x700", "seed": 42, "steps": 6, "n": 1})
    assert response.status_code == 200, response.text
    assert response.headers["x-router-server"] == COMFY
    assert response.headers["x-router-model"] == "flux2-klein-4b-comfyui"
    payload = response.json()
    assert payload["data"][0]["b64_json"] == "UE5HREFUQQ=="
    assert payload["comfyui"] == {"width": 1008, "height": 704, "seed": 42, "steps": 6}
    workflow = next(body for host, path, body, _ in upstream.calls if path == "/prompt")["prompt"]
    assert workflow["4"]["inputs"]["text"] == "a lighthouse"
    assert workflow["6"]["inputs"] == {"width": 1008, "height": 704, "batch_size": 1}
    assert workflow["7"]["inputs"] == {"steps": 6, "width": 1008, "height": 704}
    assert workflow["8"]["inputs"]["noise_seed"] == 42
    assert workflow["1"]["inputs"]["unet_name"] == KLEIN4["unet_name"]
    assert not any(path == "/v1/images/generations" for _, path, _, _ in upstream.calls)


def test_named_colibri_model_gets_its_own_api_and_key(imaging):
    router, upstream = imaging()
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={
            "model": "qwen-image-2.1-colibri", "prompt": "a fox", "size": "500x300", "user": "u1"})
    assert response.status_code == 200, response.text
    assert response.json()["colibri"] == {"seed": 7, "steps": 8}
    assert response.headers["x-router-mode"] == "image"
    sent = [(body, auth) for host, path, body, auth in upstream.calls if path == "/v1/images/generations"]
    assert sent == [({"model": "qwen-image-2.1-colibri", "prompt": "a fox", "n": 1,
                      "response_format": "b64_json", "size": "512x288"}, "Bearer colibri-secret")]


def test_colibri_draws_n_images_one_at_a_time(imaging):
    router, upstream = imaging(COMFYUI_SERVERS="")
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox", "n": 3})
        too_many = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox", "n": 9})
    assert response.status_code == 200
    assert len(response.json()["data"]) == 3 and "colibri" not in response.json()
    assert sum(path == "/v1/images/generations" for _, path, _, _ in upstream.calls) == 3
    assert too_many.status_code == 400 and "max_n" in too_many.json()["error"]["message"]


@pytest.mark.parametrize("failure", ["connect", "refuse", "error"])
def test_a_failing_comfyui_falls_forward_to_colibri(imaging, failure):
    router, upstream = imaging()
    with TestClient(router.app) as client:
        upstream.comfy = failure
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
        down = client.get("/routing/inventory").json()["server_status"][COMFY]["up"] is False
    assert response.status_code == 200
    assert response.headers["x-router-server"] == COLIBRI_IMG
    assert down == (failure == "connect")


def test_comfyui_timeout_cancels_only_its_own_job(imaging):
    router, upstream = imaging(MODEL_SERVERS="")
    router.IMAGE_READ_TIMEOUT = -1  # force expiry even on coarse monotonic clocks
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
    assert response.status_code == 504
    paths = [path for _, path, _, _ in upstream.calls]
    assert "/api/jobs/p1/cancel" in paths
    assert "/interrupt" not in paths and "/queue" not in paths


def test_a_refused_comfyui_cancel_is_logged(imaging, caplog):
    router, upstream = imaging(MODEL_SERVERS="")
    router.IMAGE_READ_TIMEOUT = -1
    upstream.cancel_status = 404
    with caplog.at_level("WARNING"), TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
    assert response.status_code == 504
    assert any("did not cancel job p1: HTTP 404" in record.getMessage() for record in caplog.records)


def _wait_for(predicate, seconds=2.0):
    deadline = time.monotonic() + seconds
    while not predicate() and time.monotonic() < deadline:
        time.sleep(0.02)
    return predicate()


def test_a_failed_comfyui_poll_cancels_its_job(imaging):
    router, upstream = imaging(MODEL_SERVERS="")
    upstream.comfy = "poll_error"
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
        cancelled = _wait_for(lambda: any(path == "/api/jobs/p1/cancel" for _, path, _, _ in upstream.calls))
    assert response.status_code == 502
    assert cancelled


def test_disconnected_image_client_cancels_comfyui_job(imaging):
    router, upstream = imaging(MODEL_SERVERS="")

    async def run():
        await router.refresh_inventory()
        body = json.dumps({"model": "image", "prompt": "a fox"}).encode()
        messages = iter(({"type": "http.request", "body": body, "more_body": False},
                         {"type": "http.disconnect"}))

        async def receive():
            return next(messages)

        scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
                 "method": "POST", "path": "/v1/images/generations",
                 "raw_path": b"/v1/images/generations", "query_string": b"", "headers": [],
                 "scheme": "http", "client": ("127.0.0.1", 1234), "server": ("127.0.0.1", 8000)}
        sent = []

        async def send(message):
            sent.append(message)

        await router.app(scope, receive, send)
        await asyncio.gather(*router._COMFYUI_CANCELS)
        await router.http_client().aclose()
        return next(message["status"] for message in sent if message["type"] == "http.response.start")

    status = asyncio.run(run())
    assert status == 499
    paths = [path for _, path, _, _ in upstream.calls]
    assert "/api/jobs/p1/cancel" in paths
    assert "/history/p1" not in paths


def _asgi_image_post(router, payload):
    """POST /v1/images/generations through the full app, the client gone after
    sending the body. Returns the response status."""
    async def run():
        await router.refresh_inventory()
        body = json.dumps(payload).encode()
        messages = iter(({"type": "http.request", "body": body, "more_body": False},))

        async def receive():
            return next(messages, {"type": "http.disconnect"})

        scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
                 "method": "POST", "path": "/v1/images/generations",
                 "raw_path": b"/v1/images/generations", "query_string": b"", "headers": [],
                 "scheme": "http", "client": ("127.0.0.1", 1234), "server": ("127.0.0.1", 8000)}
        sent = []

        async def send(message):
            sent.append(message)

        await router.app(scope, receive, send)
        await asyncio.gather(*router._COMFYUI_CANCELS)
        await router.http_client().aclose()
        return next(message["status"] for message in sent if message["type"] == "http.response.start")

    return asyncio.run(run())


def test_a_gone_client_gets_no_more_colibri_images(imaging):
    router, upstream = imaging(COMFYUI_SERVERS="")
    status = _asgi_image_post(router, {"model": "image", "prompt": "a fox", "n": 3})
    assert status == 499
    assert sum(path == "/v1/images/generations" for _, path, _, _ in upstream.calls) == 1


def test_a_disconnected_client_is_not_counted_against_the_image_server(imaging):
    router, _ = imaging(COMFYUI_SERVERS="")
    assert _asgi_image_post(router, {"model": "image", "prompt": "a fox", "n": 2}) == 499
    failures = [key for key in router._COUNTERS if key[0] == "osr_upstream_failures_total"]
    assert failures == []
    assert router.INVENTORY.get("servers", {}).get(COLIBRI_IMG, {}).get("up", True) is not False


def test_comfyui_disconnect_is_not_counted_either(imaging):
    router, upstream = imaging(MODEL_SERVERS="")
    assert _asgi_image_post(router, {"model": "image", "prompt": "a fox"}) == 499
    assert not [key for key in router._COUNTERS if key[0] == "osr_upstream_failures_total"]
    assert "/api/jobs/p1/cancel" in [path for _, path, _, _ in upstream.calls]


def test_litellm_fallback_asks_for_the_list_and_the_modes_at_once(imaging, monkeypatch):
    router, _ = imaging()
    state = {"now": 0, "peak": 0}

    class Client:
        async def get(self, url, headers=None, timeout=None):
            state["now"] += 1
            state["peak"] = max(state["peak"], state["now"])
            await asyncio.sleep(0.05)
            state["now"] -= 1
            request = httpx.Request("GET", url)
            if url.endswith("/model/info"):
                return httpx.Response(200, request=request, json={"data": [
                    {"model_name": "custom/flux-image", "model_info": {"mode": "image_generation"}}]})
            return httpx.Response(200, request=request,
                                  json={"data": [{"id": "openai/gpt-4.1"}, {"id": "custom/flux-image"}]})

    with TestClient(router.app) as client:
        router.INVENTORY = dict(router.INVENTORY, models=[])
        real = router.http_client
        monkeypatch.setattr(router, "http_client", lambda: Client())
        try:
            models = [item["id"] for item in client.get("/v1/models").json()["data"]]
        finally:
            monkeypatch.setattr(router, "http_client", real)
    assert state["peak"] == 2
    assert "openai/gpt-4.1" in models and "custom/flux-image" not in models


def test_litellm_fallback_lists_models_when_model_info_fails(imaging, monkeypatch):
    router, _ = imaging()

    class Client:
        async def get(self, url, headers=None, timeout=None):
            request = httpx.Request("GET", url)
            if url.endswith("/model/info"):
                raise httpx.ConnectError("refused", request=request)
            return httpx.Response(200, request=request, json={"data": [{"id": "openai/gpt-4.1"}]})

    with TestClient(router.app) as client:
        router.INVENTORY = dict(router.INVENTORY, models=[])
        real = router.http_client
        monkeypatch.setattr(router, "http_client", lambda: Client())
        try:
            models = [item["id"] for item in client.get("/v1/models").json()["data"]]
        finally:
            monkeypatch.setattr(router, "http_client", real)
    assert "openai/gpt-4.1" in models


def test_cancelled_timeout_keeps_comfyui_cleanup(imaging, monkeypatch):
    router, _ = imaging(MODEL_SERVERS="")
    router.IMAGE_READ_TIMEOUT = -1  # force expiry even on coarse monotonic clocks
    calls = []

    async def run():
        await router.refresh_inventory()
        started, release = asyncio.Event(), asyncio.Event()

        async def slow_cancel(client, server, prompt_id):
            calls.append(prompt_id)
            started.set()
            await release.wait()

        class ConnectedRequest:
            async def is_disconnected(self):
                return False

        monkeypatch.setattr(router, "comfyui_cancel", slow_cancel)
        entry = router.image_candidates("image")[0]
        task = asyncio.create_task(router.comfyui_image(entry, {"prompt": "a fox"}, 1,
                                                        ConnectedRequest()))
        await asyncio.wait_for(started.wait(), 2)
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        await asyncio.sleep(0)
        release.set()
        await asyncio.gather(*router._COMFYUI_CANCELS)
        await router.http_client().aclose()

    asyncio.run(run())
    assert calls == ["p1", "p1"]


def test_shutdown_waits_for_comfyui_cancellation(monkeypatch):
    router = load_router(monkeypatch, MODEL_SERVERS="", COMFYUI_SERVERS="")
    cancelled_before_close = []

    async def run():
        async with router.lifespan(router.app):
            client = router.http_client()

            async def finish_cancel():
                await asyncio.sleep(0)
                cancelled_before_close.append(not client.is_closed)

            task = asyncio.create_task(finish_cancel())
            router._COMFYUI_CANCELS.add(task)
            task.add_done_callback(router._COMFYUI_CANCELS.discard)

    asyncio.run(run())
    assert cancelled_before_close == [True]


def test_a_finished_comfyui_job_is_not_cancelled(imaging):
    router, upstream = imaging(MODEL_SERVERS="")
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
        time.sleep(0.2)
    assert response.status_code == 200
    assert all(path != "/api/jobs/p1/cancel" for _, path, _, _ in upstream.calls)


def test_a_full_colibri_queue_falls_forward_and_a_bad_request_does_not(imaging):
    router, upstream = imaging(COMFYUI_SERVERS="")
    upstream.colibri = 400
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
        assert response.status_code == 400 and response.json()["error"]["message"] == "nope"
        upstream.colibri = 503
        response = client.post("/v1/images/generations", json={"model": "image", "prompt": "a fox"})
    assert response.status_code == 503


def test_streaming_needs_colibri(imaging):
    router, upstream = imaging(MODEL_SERVERS="")
    with TestClient(router.app) as client:
        response = client.post("/v1/images/generations",
                               json={"model": "image", "prompt": "a fox", "stream": True})
    assert response.status_code == 503 and "streams" in response.json()["error"]["message"]


def test_cloud_image_models_only_when_named(imaging):
    router, upstream = imaging(OPENAI_API_KEY="sk-test", CLOUD_OPENAI_MODELS="gpt-4.1,gpt-image-1")
    with TestClient(router.app) as client:
        chat = [m["id"] for m in client.get("/v1/models").json()["data"]]
        images = [m["id"] for m in client.get("/v1/images/models").json()["data"]]
        named = client.post("/v1/images/generations", json={"model": "openai/gpt-image-1", "prompt": "a fox"})
        unknown = client.post("/v1/images/generations", json={"model": "dall-e-3", "prompt": "a fox"})
        alias = client.post("/v1/images/generations", json={"prompt": "a fox"})
    assert "openai/gpt-4.1" in chat and "openai/gpt-image-1" not in chat
    assert images[-1] == "openai/gpt-image-1"
    assert named.status_code == 200 and named.json()["via"] == "litellm"
    assert named.headers["x-router-mode"] == "cloud"
    assert unknown.json()["via"] == "litellm" and unknown.headers["x-router-mode"] == "litellm"
    assert alias.headers["x-router-server"] == COMFY
    litellm = [body["model"] for host, path, body, auth in upstream.calls if "litellm.test" in host and path == "/v1/images/generations"]
    assert litellm == ["openai/gpt-image-1", "dall-e-3"]


def test_image_requests_are_validated(imaging):
    router, upstream = imaging()
    with TestClient(router.app) as client:
        for body, word in (({"model": "image"}, "prompt"),
                           ({"model": "image", "prompt": "x", "size": "big"}, "size"),
                           ({"model": "image", "prompt": "x", "n": 0}, "`n`")):
            response = client.post("/v1/images/generations", json=body)
            assert response.status_code == 400 and word in response.json()["error"]["message"]
        metrics = client.get("/metrics").text
    assert 'osr_requests_total{class="",mode="",model="",route="images",server="",status="400"} 3' in metrics
    assert 'osr_server_up{kind="comfyui",server="http://10.0.0.30:8188"} 1' in metrics


# --- several models in one tier ---------------------------------------------------------
XL_YAML = """model_list:
  - model_name: xlarge
    litellm_params:
      model: ollama/llama3.3:70b
      api_base: http://10.0.0.1:11434
  - model_name: xlarge
    litellm_params:
      model: ollama/qwen3:235b
      api_base: http://10.0.0.1:11434
  - model_name: xlarge
    litellm_params:
      model: ollama/deepseek-r1:671b  # the biggest
      api_base: http://10.0.0.2:11434
  - model_name: fast
    litellm_params:
      model: ollama/qwen3:4b
      api_base: http://10.0.0.2:11434
  - model_name: openai/gpt-4.1
    litellm_params:
      model: openai/gpt-4.1
      api_key: os.environ/OPENAI_API_KEY
router_settings:
  routing_strategy: latency-based-routing
"""
XL_MODELS = {"llama3.3:70b", "qwen3:235b", "deepseek-r1:671b"}
PROOF = "Prove that sqrt 2 is irrational"


def xl_tier(router, tmp_path, text=XL_YAML):
    path = tmp_path / "litellm_config.yaml"
    path.write_text(text)
    router.TIER_CONFIG = str(path)
    router.load_tier_models(force=True)
    return path


@pytest.fixture
def xl(served, tmp_path):
    router, upstream, client = served
    upstream.inventory = {
        HOST_A: tags(("llama3.3:70b", "70.6B", "llama"), ("qwen3:235b", "235B", "qwen3"),
                     ("mistral-large:123b", "123B", "llama")),
        HOST_B: tags(("deepseek-r1:671b", "671B", "deepseek2"), ("qwen3:4b", "4B", "qwen3")),
    }
    xl_tier(router, tmp_path)
    assert client.post("/routing/refresh").status_code == 200
    router._rotation.clear()
    return router, upstream, client


def test_parse_tier_models_reads_every_deployment_of_a_tier(router):
    assert router.parse_tier_models(XL_YAML) == {
        "xlarge": XL_MODELS, "fast": {"qwen3:4b"}}
    # Key order inside an item, quotes, comments and ":latest" do not matter;
    # cloud models, router_settings and other sections are not tiers.
    assert router.parse_tier_models(
        "model_list:\n"
        "  - litellm_params:\n"
        "      model: 'openai/GLM-5.3-Flash'\n"
        "      tags:\n"
        "        - model: ollama/nope\n"
        "    model_name: large\n"
        "  - model_name: \"large\"\n"
        "    litellm_params: {model: ignored}\n"
        "  - model_name: large\n"
        "    litellm_params:\n"
        "      model: lm_studio/qwen/qwen3-32b:latest\n"
        "router_settings:\n"
        "  model: ollama/also-nope\n") == {"large": {"glm-5.3-flash", "qwen/qwen3-32b"}}
    assert router.parse_tier_models("") == {}
    assert router.parse_tier_models("not: yaml: at all\n  - ]") == {}


def test_auto_spreads_a_tier_across_all_of_its_models(xl):
    router, upstream, client = xl
    picked = [chat(client, messages=[user(f"{PROOF} ({n})")]).json()["model"] for n in range(6)]
    assert set(picked) == XL_MODELS                         # every assigned model takes a turn...
    assert "mistral-large:123b" not in picked               # ...and none that is only the right size
    assert set(served_hosts(upstream)) == {HOST_A, HOST_B}


def test_without_tier_models_the_largest_model_always_wins(xl, monkeypatch):
    router, upstream, client = xl
    monkeypatch.setattr(router, "TIER_MODELS_ENABLED", False)
    router.load_tier_models(force=True)
    assert router.TIER_MEMBERS == {}
    picked = {chat(client, messages=[user(f"{PROOF} ({n})")]).json()["model"] for n in range(4)}
    assert picked == {"deepseek-r1:671b"}


def test_tier_alias_spreads_across_its_models(xl):
    router, upstream, client = xl
    picked = {chat(client, model="xlarge", messages=[user(f"hello {n}")]).json()["model"]
              for n in range(6)}
    assert picked == XL_MODELS


def test_each_tier_model_is_listed_and_can_be_named(xl):
    router, upstream, client = xl
    listed = [m["id"] for m in client.get("/v1/models").json()["data"]]
    assert XL_MODELS <= set(listed)
    for name in XL_MODELS:
        for _ in range(3):
            response = chat(client, model=name, messages=[user(PROOF)])
            assert response.json()["model"] == name


def test_an_assigned_model_fits_its_tier_whatever_its_size(router, tmp_path):
    xl_tier(router, tmp_path, XL_YAML.replace("deepseek-r1:671b", "qwen3:32b"))
    small = router.build_entry(HOST_B, {"name": "qwen3:32b", "details": {"parameter_size": "32B"}})
    unsized = router.build_entry(HOST_A, {"name": "qwen3:235b", "details": {}})
    giant = router.build_entry(HOST_A, {"name": "kimi:1000b", "details": {"parameter_size": "1000B"}})
    inv = {"models": [small, unsized, giant], "servers": {}}
    need = {"class": "xlarge", "code": False, "vision": False}
    first = {router.rank_candidates(need, inv)[0]["name"] for _ in range(4)}
    assert first == {"qwen3:32b", "qwen3:235b"}
    assert router.in_requested_band(small, need) and router.band_distance(unsized, need) == 0.0
    # Not assigned to large: there it is judged by its size alone, as before.
    assert router.tier_classes(small) == ["xlarge"]
    assert not router.is_tier_member(small, {"class": "large"})


def test_tier_models_still_respect_the_request_needs(xl):
    router, upstream, client = xl
    upstream.capabilities.update({"llama3.3:70b": ["completion", "vision"],
                                  "qwen3:235b": ["completion"], "deepseek-r1:671b": ["completion"]})
    router._CAPABILITIES.clear()
    client.post("/routing/refresh")
    image = [{"role": "user", "content": [{"type": "text", "text": PROOF},
                                          {"type": "image_url", "image_url": {"url": "data:,"}}]}]
    picked = {chat(client, messages=image).json()["model"] for _ in range(4)}
    assert picked == {"llama3.3:70b"}


def test_busy_server_gives_way_inside_a_tier(xl):
    router, upstream, client = xl
    router._IN_FLIGHT[HOST_A] = 3
    try:
        need = {"class": "xlarge", "code": False, "vision": False}
        assert router.rank_candidates(need)[0]["server"] == HOST_B
    finally:
        router._IN_FLIGHT.clear()


def test_a_conversation_keeps_its_tier_model(xl):
    router, upstream, client = xl
    history = [user(PROOF)]
    first = chat(client, messages=history).json()["model"]
    history += [{"role": "assistant", "content": "ok"}, user("Now prove it for cube roots")]
    assert {chat(client, messages=history).json()["model"] for _ in range(4)} == {first}


def test_tool_tasks_take_the_tier_models_in_turn_and_keep_theirs(xl):
    router, upstream, client = xl
    upstream.capabilities.update({name: ["completion", "tools"] for name in XL_MODELS})
    router._CAPABILITIES.clear()
    client.post("/routing/refresh")
    tasks = {}
    for n in range(6):
        tasks[n] = chat(client, model="xlarge", tools=TOOLS,
                        messages=[user(f"task {n}")]).json()["model"]
    assert set(tasks.values()) == XL_MODELS
    # Later steps of one task stay on its model.
    steps = [user("task 2"), {"role": "assistant", "content": "", "tool_calls": [
        {"id": "1", "type": "function", "function": {"name": "f", "arguments": "{}"}}]},
             {"role": "tool", "tool_call_id": "1", "content": "done"}]
    assert {chat(client, model="xlarge", tools=TOOLS, messages=steps).json()["model"]
            for _ in range(4)} == {tasks[2]}


def test_tool_tasks_stay_on_one_model_when_affinity_is_off(xl, monkeypatch):
    router, upstream, client = xl
    monkeypatch.setattr(router, "STICKY_SECONDS", 0.0)
    upstream.capabilities.update({name: ["completion", "tools"] for name in XL_MODELS})
    router._CAPABILITIES.clear()
    client.post("/routing/refresh")
    picked = {chat(client, model="xlarge", tools=TOOLS, messages=[user(f"task {n}")]).json()["model"]
              for n in range(4)}
    assert len(picked) == 1


def test_tier_assignments_are_read_again_when_the_file_changes(xl, tmp_path):
    router, upstream, client = xl
    path = tmp_path / "litellm_config.yaml"
    path.write_text(XL_YAML.replace("ollama/qwen3:235b", "ollama/mistral-large:123b"))
    os.utime(path, ns=(time.time_ns(), time.time_ns() + 10_000_000_000))
    client.post("/routing/refresh")
    assert router.TIER_MEMBERS["xlarge"] == {"llama3.3:70b", "mistral-large:123b", "deepseek-r1:671b"}
    inventory = client.get("/routing/inventory").json()
    assert inventory["tier_models"]["xlarge"] == ["deepseek-r1:671b", "llama3.3:70b", "mistral-large:123b"]
    explain = client.post("/routing/explain", json={"prompt": PROOF}).json()
    assert all(c["tiers"] == ["xlarge"] for c in explain["candidates"][:3])
    path.unlink()
    client.post("/routing/refresh")
    assert router.TIER_MEMBERS == {}


def test_tier_config_defaults_beside_router_ini(monkeypatch, tmp_path):
    ini = tmp_path / "router.ini"
    ini.write_text((ROOT / "services/osr-router/router.ini").read_text())
    (tmp_path / "litellm_config.yaml").write_text(XL_YAML)
    router = load_router(monkeypatch, ROUTER_INI=str(ini))
    assert router.TIER_CONFIG == str(tmp_path / "litellm_config.yaml")
    assert router.TIER_MEMBERS["xlarge"] == XL_MODELS
