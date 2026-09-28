"""Unit tests for services/ollama-router/router.py.

Every upstream (Ollama hosts, LiteLLM) is an httpx.MockTransport, so nothing
leaves the process. Run: python3 -m pytest -q tests/test_router.py
"""
import importlib.util
import json
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
        "LITELLM_BASE_URL": "http://litellm.test",
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
        self.chat = {}          # host -> status code or "connect" / "timeout"
        self.calls = []
        self.capabilities = {}  # model name -> list, None (404) or "boom"
        self.show_calls = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        host = f"{request.url.scheme}://{request.url.host}:{request.url.port}"
        self.calls.append((host, request.url.path, dict(request.headers),
                           request.content))
        if request.url.path == "/api/tags":
            if host in self.inventory:
                return httpx.Response(200, json=self.inventory[host])
            raise httpx.ConnectError("refused", request=request)
        if request.url.path == "/v1/chat/completions":
            behaviour = self.chat.get(host, 200)
            if behaviour == "connect":
                raise httpx.ConnectError("refused", request=request)
            if behaviour == "timeout":
                raise httpx.ConnectTimeout("timed out", request=request)
            body = json.loads(request.content)
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
            return httpx.Response(200, json={"capabilities": caps})
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
        return streamed(200, {"ok": True})

    router._HTTP["client"] = httpx.AsyncClient(transport=httpx.MockTransport(litellm))
    response = chat(client, messages=[user("please analyze this")])
    assert response.headers["x-router-mode"] == "litellm"
    assert captured["body"]["model"] == router.TIER_LARGE


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


def test_capabilities_override_a_misleading_name(router):
    entry = router.build_entry(HOST_A, {"name": "my-vision-finetune:7b"}, ["completion"])
    assert entry["is_vision"] is False
    entry = router.build_entry(HOST_A, {"name": "llava:7b"})
    assert entry["is_vision"] is True   # no capability data -> name fallback


def test_capabilities_are_cached_per_digest(served):
    router, upstream, client = served
    upstream.capabilities["qwen3:14b"] = ["completion", "tools"]
    upstream.show_calls.clear()
    router._CAPABILITIES.clear()
    client.post("/routing/refresh")
    client.post("/routing/refresh")
    assert len(upstream.show_calls) == 2       # once per host, not per poll


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
