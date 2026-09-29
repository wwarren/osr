"""Unit tests for server.py against a stubbed model (no weights, no network).

Run from the repository root with:  pytest -q targets/airllm/test_server.py
airllm, transformers and torch are faked (see airllm_fakes.py).
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import sys
import threading
import time
from pathlib import Path

from fastapi.testclient import TestClient

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import airllm_fakes as fakes  # noqa: E402

MODEL = "fake/Test-7B-Instruct"


def _clear_env() -> None:
    for key in list(os.environ):
        if key.startswith("AIRLLM_") or key in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
            del os.environ[key]


def load_server(model=None, load_error=None):
    torch = fakes.install(model, load_error)
    spec = importlib.util.spec_from_file_location("airllm_server_under_test", HERE / "server.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["airllm_server_under_test"] = module
    spec.loader.exec_module(module)
    module.exits = []
    module.manager.on_load_failure = lambda: module.exits.append(True)
    module.fake_torch = torch
    return module


def build(fail_with=None, chat_template="present", load_error=None, **env):
    """Fresh fakes + a fresh server module with the given environment."""
    _clear_env()
    defaults = {
        "AIRLLM_MODEL_ID": MODEL,
        "AIRLLM_DEVICE": "cpu",
        "AIRLLM_MAX_SEQ_LEN": "128",
        "AIRLLM_MAX_NEW_TOKENS": "64",
        "AIRLLM_LOAD_WAIT": "10",
        "AIRLLM_TOKEN_TIMEOUT": "10",
        "AIRLLM_HOST": "127.0.0.1",
    }
    defaults.update({k: str(v) for k, v in env.items()})
    os.environ.update(defaults)
    model = fakes.FakeModel(fakes.FakeTokenizer(chat_template=chat_template), fail_with=fail_with)
    return load_server(model, load_error), model


def ndjson(response):
    assert response.status_code == 200, response.text
    return [json.loads(line) for line in response.text.splitlines() if line.strip()]


def user(content="hi"):
    return {"messages": [{"role": "user", "content": content}]}


# --- defaults and metadata ------------------------------------------------------------


def test_defaults():
    _clear_env()
    server = load_server(fakes.FakeModel(fakes.FakeTokenizer()))
    assert server.cfg.model_id == "Qwen/Qwen2.5-72B-Instruct"
    # Like the llama.cpp bridge, the target listens for the router by default.
    assert server.cfg.host == "0.0.0.0"
    assert server.cfg.exit_on_load_failure is True


def test_metadata_before_the_model_loads():
    server, _ = build(AIRLLM_EAGER_LOAD="false")
    with TestClient(server.app) as client:
        assert client.get("/").text == "Ollama is running"
        assert client.get("/api/version").json() == {"version": server.cfg.ollama_version, "backend": "airllm"}
        # Not ready: /api/tags and /healthz say so, so the router never routes here.
        tags = client.get("/api/tags")
        assert tags.status_code == 503 and tags.json()["status"] == "loading"
        assert client.get("/healthz").status_code == 503
        show = client.post("/api/show", json={"model": MODEL}).json()
        for key in ("modelfile", "parameters", "template", "details", "capabilities"):
            assert key in show
        assert client.get("/api/ps").json() == {"models": []}
        assert client.get("/health").json()["status"] == "loading"


def test_ready_target_reports_tags_healthz_and_ps():
    server, _ = build()
    with TestClient(server.app) as client:
        server.manager.require()
        assert client.get("/healthz").json() == {"status": "ok", "backend": "airllm", "model": MODEL}
        entry = client.get("/api/tags").json()["models"][0]
        for key in ("name", "model", "modified_at", "size", "digest", "details"):
            assert key in entry
        assert entry["details"]["format"] == "safetensors"
        assert entry["details"]["parameter_size"] == "7B"
        # The family comes from the loaded model's config, not a hard-coded "llama".
        assert entry["details"]["family"] == "qwen2"
        assert client.get("/api/ps").json()["models"][0]["size_vram"] == 0
        assert client.get("/health").json()["status"] == "ready"


def test_configured_family_and_parameter_size_win():
    server, _ = build(AIRLLM_MODEL_FAMILY="llama", AIRLLM_MODEL_PARAMETER_SIZE="70.6B")
    with TestClient(server.app) as client:
        server.manager.require()
        details = client.get("/api/tags").json()["models"][0]["details"]
    assert details["family"] == "llama" and details["parameter_size"] == "70.6B"


def test_embeddings_are_refused_clearly():
    server, _ = build()
    with TestClient(server.app) as client:
        assert client.post("/api/embed", json={"input": "x"}).status_code == 501


def test_unknown_model_requests_are_rejected():
    server, _ = build(AIRLLM_EAGER_LOAD="false")
    with TestClient(server.app) as client:
        response = client.post("/api/generate", json={"model": "local", "prompt": "hi", "stream": False})
    assert response.status_code == 404 and "local" in response.json()["detail"]


def test_model_alias_and_latest_tag_are_accepted():
    server, _ = build(AIRLLM_MODEL_ALIAS="qwen2.5:72b", AIRLLM_EAGER_LOAD="false")
    with TestClient(server.app) as client:
        for name in ("qwen2.5:72b", MODEL, f"{MODEL}:latest"):
            assert client.post("/api/show", json={"model": name}).status_code == 200


def test_pull_starts_the_load_without_blocking():
    server, _ = build(AIRLLM_EAGER_LOAD="false")
    with TestClient(server.app) as client:
        packets = ndjson(client.post("/api/pull", json={"model": MODEL}))
        once = client.post("/api/pull", json={"model": MODEL, "stream": False}).json()
        assert server.manager._ready.wait(5)
    assert packets[-1] == {"status": "success"} and once == {"status": "success"}


def test_unsupported_model_management_routes_are_explicit():
    server, _ = build(AIRLLM_EAGER_LOAD="false")
    with TestClient(server.app) as client:
        for path in ("/api/create", "/api/copy", "/api/push", "/api/delete"):
            assert client.post(path, json={"model": MODEL}).status_code == 501
        assert client.request("DELETE", "/api/delete", json={"model": MODEL}).status_code == 501


# --- chat and generate ----------------------------------------------------------------


def test_chat_stream_packet_shapes():
    server, _ = build()
    with TestClient(server.app) as client:
        packets = ndjson(client.post("/api/chat", json={"model": MODEL, **user()}))
    body, final = packets[:-1], packets[-1]
    assert "".join(p["message"]["content"] for p in body) == "".join(fakes.FakeModel.REPLY)
    for packet in packets:
        assert packet["model"] and "created_at" in packet and "message" in packet and "done" in packet
    assert final["done"] is True and final["done_reason"] == "stop"
    assert final["message"] == {"role": "assistant", "content": ""}
    assert final["prompt_eval_count"] > 0 and final["eval_count"] > 0
    for key in ("total_duration", "load_duration", "prompt_eval_duration", "eval_duration"):
        assert isinstance(final[key], int)


def test_chat_non_stream_never_echoes_the_prompt():
    server, _ = build()
    with TestClient(server.app) as client:
        body = client.post("/api/chat", json={**user("unique-marker"), "stream": False}).json()
    assert body["done"] is True
    assert body["message"]["content"] == "".join(fakes.FakeModel.REPLY)
    assert "unique-marker" not in body["message"]["content"]


def test_chat_uses_the_tokenizer_template():
    server, model = build()
    with TestClient(server.app) as client:
        client.post("/api/chat", json={"messages": [{"role": "system", "content": "be nice"},
                                                    {"role": "user", "content": "hi"}]})
    assert model.tokenizer.last_call["text"] == "<system>be nice</system><user>hi</user><assistant>"


def test_manual_template_has_exactly_one_bos():
    server, model = build(chat_template=None)
    with TestClient(server.app) as client:
        client.post("/api/chat", json={"messages": [{"role": "USER", "content": "hi"}]})
    call = model.tokenizer.last_call
    assert call["text"].startswith("<|begin_of_text|>") and "USER" not in call["text"]
    assert call["text"].endswith("<|start_header_id|>assistant<|end_header_id|>\n\n")
    # The template already carries BOS; the tokenizer must not add another.
    assert call["add_special_tokens"] is False
    assert model.calls[0]["inputs"].ids[0] != 1


def test_null_content_and_unknown_fields_do_not_400():
    server, _ = build()
    with TestClient(server.app) as client:
        response = client.post("/api/chat", json={
            "model": MODEL,
            "messages": [{"role": "assistant", "content": None, "tool_calls": []},
                         {"role": "user", "content": "hi", "images": None}],
            "keep_alive": "5m", "format": "json", "think": False,
        })
    assert response.status_code == 200


def test_generate_stream_and_non_stream():
    server, _ = build()
    with TestClient(server.app) as client:
        packets = ndjson(client.post("/api/generate", json={"model": MODEL, "prompt": "hi"}))
        once = client.post("/api/generate", json={"model": MODEL, "prompt": "hi", "stream": False}).json()
    assert "".join(p["response"] for p in packets[:-1]) == "".join(fakes.FakeModel.REPLY)
    assert packets[-1]["done"] is True and packets[-1]["context"] == []
    assert once["response"] == "".join(fakes.FakeModel.REPLY)


def test_generate_raw_skips_templating():
    server, model = build()
    with TestClient(server.app) as client:
        client.post("/api/generate", json={"prompt": "bare prompt", "raw": True})
    assert model.tokenizer.last_call["text"] == "bare prompt"


# --- context window -------------------------------------------------------------------


def test_long_prompts_keep_the_newest_tokens_and_leave_room_for_the_reply():
    server, model = build(AIRLLM_MAX_SEQ_LEN=16, AIRLLM_MAX_NEW_TOKENS=4)
    words = " ".join("w" * (i % 9 + 1) for i in range(40))  # 40 tokens
    with TestClient(server.app) as client:
        client.post("/api/generate", json={"prompt": words + " LATEST", "raw": True, "stream": False})
    call = model.calls[0]
    ids = call["inputs"].ids
    assert len(ids) == 12                      # 16-token window minus 4 reserved
    assert ids[-1] == len("LATEST")            # the newest token survived
    assert call["max_new_tokens"] == 4


def test_short_prompts_are_untouched_and_the_reply_is_capped_to_the_window():
    server, model = build(AIRLLM_MAX_SEQ_LEN=16, AIRLLM_MAX_NEW_TOKENS=64)
    with TestClient(server.app) as client:
        client.post("/api/generate", json={"prompt": "a b c", "raw": True, "stream": False})
    call = model.calls[0]
    assert len(call["inputs"].ids) == 3
    assert call["max_new_tokens"] == 13       # 16 - 3: prompt + reply fit the window


def test_the_reply_never_takes_more_than_half_a_full_window():
    server, model = build(AIRLLM_MAX_SEQ_LEN=16, AIRLLM_MAX_NEW_TOKENS=64)
    with TestClient(server.app) as client:
        client.post("/api/generate", json={"prompt": " ".join(["x"] * 30), "raw": True, "stream": False})
    call = model.calls[0]
    assert len(call["inputs"].ids) == 8 and call["max_new_tokens"] == 8


# --- options, seeds and concurrency ---------------------------------------------------


def test_generation_always_uses_the_kv_cache():
    server, model = build()
    with TestClient(server.app) as client:
        client.post("/api/chat", json=user())
    assert model.calls[0]["use_cache"] is True


def test_options_map_onto_generate_kwargs():
    server, model = build()
    with TestClient(server.app) as client:
        client.post("/api/chat", json={**user(), "options": {"num_predict": 2, "temperature": 0.7,
                                                             "top_p": 0.9, "top_k": 40,
                                                             "repeat_penalty": 1.1}})
    call = model.calls[0]
    assert call["max_new_tokens"] == 2
    assert call["do_sample"] is True and call["temperature"] == 0.7
    assert call["top_p"] == 0.9 and call["top_k"] == 40 and call["repetition_penalty"] == 1.1


def test_greedy_decoding_drops_sampling_knobs():
    server, model = build()
    with TestClient(server.app) as client:
        client.post("/api/chat", json={**user(), "options": {"temperature": 0, "top_p": 0.9}})
    call = model.calls[0]
    assert call["do_sample"] is False and "top_p" not in call


def test_num_predict_truncates_the_reply_and_reports_length():
    server, _ = build()
    with TestClient(server.app) as client:
        packets = ndjson(client.post("/api/chat", json={**user(), "options": {"num_predict": 2}}))
    assert "".join(p["message"]["content"] for p in packets[:-1]) == "Hello there"
    assert packets[-1]["done_reason"] == "length"


def test_seed_is_applied_inside_the_model_lock():
    server, model = build()
    model.delay = 0.2
    with TestClient(server.app) as client:
        server.manager.require()
        first = threading.Thread(target=lambda: client.post("/api/chat", json={**user(), "stream": False}))
        first.start()
        assert model.started.wait(5)
        # A seeded request arriving mid-generation must not reseed the running one.
        second = threading.Thread(target=lambda: client.post(
            "/api/chat", json={**user(), "stream": False, "options": {"seed": 42}}))
        second.start()
        time.sleep(0.3)
        assert server.fake_torch.seeds == []
        first.join(10)
        second.join(10)
    assert server.fake_torch.seeds == [42]


def test_model_is_used_by_one_request_at_a_time():
    server, model = build()
    model.delay = 0.02
    results = []
    with TestClient(server.app) as client:
        server.manager.require()

        def fire():
            results.append(ndjson(client.post("/api/chat", json=user())))

        threads = [threading.Thread(target=fire) for _ in range(3)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)
    assert len(results) == 3 and model.max_concurrent == 1


# --- failure paths --------------------------------------------------------------------


def test_generation_failure_is_reported_instead_of_hanging():
    server, _ = build(fail_with=RuntimeError("out of memory"))
    with TestClient(server.app) as client:
        packets = ndjson(client.post("/api/chat", json={"messages": []}))
    assert "out of memory" in packets[-1]["error"]


def test_non_stream_generation_failure_returns_500():
    server, _ = build(fail_with=RuntimeError("boom"))
    with TestClient(server.app) as client:
        response = client.post("/api/chat", json={"messages": [], "stream": False})
    assert response.status_code == 500 and "boom" in response.json()["detail"]


class Hangup:
    """A request whose client has already gone away."""

    async def is_disconnected(self):
        return True


def test_abandoning_a_stream_cancels_the_generation():
    server, _ = build()

    class NeverDisconnected:
        async def is_disconnected(self):
            return False

    gen = server.Generation()
    for token in ("a", "b", "c"):
        gen.chunks.put(token)
    response = server.ndjson_stream(NeverDisconnected(), gen, server.chat_chunk, server.chat_final)

    async def consume_one_then_hang_up():
        body = response.body_iterator
        await body.__anext__()
        await body.aclose()

    asyncio.run(consume_one_then_hang_up())
    assert gen.cancel.is_set()


def test_a_non_stream_client_that_leaves_cancels_the_generation():
    server, _ = build()
    gen = server.Generation()  # nothing is ever produced

    async def run():
        try:
            await server.collect(Hangup(), gen)
        except server.HTTPException as exc:
            return exc.status_code
        return None

    assert asyncio.run(run()) == 499
    assert gen.cancel.is_set()


def test_requests_503_while_the_model_is_still_loading():
    server, _ = build(AIRLLM_EAGER_LOAD="false", AIRLLM_LOAD_WAIT=0)
    server.manager.load = lambda: threading.Event().wait(30)
    with TestClient(server.app) as client:
        response = client.post("/api/chat", json={"messages": [], "stream": False})
    assert response.status_code == 503 and "loading" in response.json()["detail"]


def test_a_failed_load_exits_so_systemd_can_retry():
    server, _ = build(load_error=RuntimeError("gated repo: set HF_TOKEN"))
    with TestClient(server.app) as client:
        deadline = time.time() + 5
        while not server.exits and time.time() < deadline:
            time.sleep(0.02)
        assert server.exits == [True]
        health = client.get("/health").json()
        assert health["status"] == "error" and "HF_TOKEN" in health["error"]
        assert client.get("/api/tags").status_code == 503


def test_exit_on_load_failure_can_be_disabled():
    server, _ = build(load_error=RuntimeError("nope"), AIRLLM_EXIT_ON_LOAD_FAILURE="false")
    with TestClient(server.app):
        deadline = time.time() + 2
        while server.manager.load_error is None and time.time() < deadline:
            time.sleep(0.02)
    assert server.manager.status() == "error" and server.exits == []


# --- loading --------------------------------------------------------------------------


def test_airllm_is_constructed_with_an_explicit_device():
    server, _ = build(AIRLLM_MAX_SEQ_LEN=256)
    with TestClient(server.app):
        server.manager.require()
    kwargs = sys.modules["airllm"].AutoModel.last_kwargs
    assert kwargs["device"] == "cpu" and kwargs["max_seq_len"] == 256
    assert "compression" not in kwargs and "delete_original" not in kwargs


def test_prompt_tensor_is_moved_to_the_configured_device():
    server, model = build(AIRLLM_DEVICE="cuda:0")
    with TestClient(server.app) as client:
        client.post("/api/chat", json=user())
    assert model.calls[0]["inputs"].device == "cuda:0"


def test_token_compression_shards_and_delete_original_are_forwarded():
    server, _ = build(HF_TOKEN="hf_test", AIRLLM_COMPRESSION="4bit",
                      AIRLLM_LAYER_SHARDS_PATH="/var/lib/airllm-target/shards", AIRLLM_DELETE_ORIGINAL="true")
    with TestClient(server.app):
        server.manager.require()
    kwargs = sys.modules["airllm"].AutoModel.last_kwargs
    assert kwargs["compression"] == "4bit" and kwargs["hf_token"] == "hf_test"
    assert kwargs["layer_shards_saving_path"] == "/var/lib/airllm-target/shards"
    assert kwargs["delete_original"] is True
