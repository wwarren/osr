"""Target-side Ollama inference adapter for one resident llama.cpp server.

OpenAI requests retain their wire format. Ollama inference requests are
translated; model installation and lifecycle belong to systemd, not this API.
"""

import json
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

log = logging.getLogger("bridge")

# Ollama sampling options llama-server's OpenAI endpoints accept, by the name
# llama-server uses for them.
SAMPLING_OPTIONS = {
    "temperature": "temperature", "top_p": "top_p", "top_k": "top_k", "min_p": "min_p",
    "typical_p": "typical_p", "seed": "seed", "stop": "stop", "num_predict": "max_tokens",
    "repeat_penalty": "repeat_penalty", "repeat_last_n": "repeat_last_n",
    "presence_penalty": "presence_penalty", "frequency_penalty": "frequency_penalty",
    "mirostat": "mirostat", "mirostat_tau": "mirostat_tau", "mirostat_eta": "mirostat_eta",
}
# Everything else in "options" is accepted and IGNORED, with a log line and an
# X-Bridge-Ignored-Options header. Most of it is load-time configuration
# (num_ctx, num_gpu, num_thread, num_batch, use_mmap, ...) that is fixed when
# llama-server starts; Open WebUI and LiteLLM send some of these on ordinary
# chat requests, and failing the request over them broke those clients.
_WARNED_OPTIONS = set()


@dataclass(frozen=True)
class Config:
    base_url: str
    alias: str
    model_path: str = ""
    parameter_size: str = ""
    family: str = ""
    quantization: str = ""
    capabilities: tuple = ("completion",)
    timeout: float = 600

    @classmethod
    def from_env(cls):
        alias = os.environ.get("MODEL_ALIAS", "").strip()
        if not alias:
            raise RuntimeError("MODEL_ALIAS is required and must match llama-server --alias")
        return cls(
            os.getenv("LLAMA_BASE_URL", "http://127.0.0.1:8081").rstrip("/"), alias,
            os.getenv("MODEL_PATH", ""), os.getenv("MODEL_PARAMETER_SIZE", ""),
            os.getenv("MODEL_FAMILY", ""), os.getenv("MODEL_QUANTIZATION", ""),
            tuple(x.strip() for x in os.getenv("MODEL_CAPABILITIES", "completion").split(",") if x.strip()),
            float(os.getenv("REQUEST_TIMEOUT_SECONDS", "600")),
        )


def fail(status, message):
    raise HTTPException(status, message)


def now():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def ndjson(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"


def check_fields(body, allowed, label="request"):
    extra = set(body) - set(allowed)
    if extra:
        fail(400, f"Unsupported {label} fields: {', '.join(sorted(extra))}")


def sampling(body):
    """(llama-server sampling fields, sorted list of ignored option names)."""
    options = body.get("options")
    if options is None:
        options = {}
    if not isinstance(options, dict):
        fail(400, "options must be an object")
    ignored = sorted(key for key in options if key not in SAMPLING_OPTIONS)
    for key in ignored:
        if key not in _WARNED_OPTIONS:
            _WARNED_OPTIONS.add(key)
            log.warning("ignoring Ollama option %r: not a per-request setting on "
                        "llama-server (configure it in llama-server.env)", key)
    result = {SAMPLING_OPTIONS[key]: value for key, value in options.items()
              if key in SAMPLING_OPTIONS}
    if result.get("max_tokens") == -1:
        result.pop("max_tokens")
    elif "max_tokens" in result and (type(result["max_tokens"]) is not int or result["max_tokens"] < 1):
        fail(400, "num_predict must be a positive integer or -1")
    fmt = body.get("format")
    if fmt == "json":
        result["response_format"] = {"type": "json_object"}
    elif isinstance(fmt, dict):
        result["response_format"] = {"type": "json_schema", "json_schema": {"name": "response", "schema": fmt}}
    elif fmt not in (None, ""):
        fail(400, "format must be 'json' or a JSON schema object")
    return result, ignored


def ignored_header(ignored):
    return {"X-Bridge-Ignored-Options": ",".join(ignored)} if ignored else {}


def format_params(count):
    """7_615_616_512 -> '7.6B', 494_032_768 -> '494M' (Ollama's style)."""
    if not isinstance(count, (int, float)) or count <= 0:
        return ""
    if count >= 1e9:
        return f"{count / 1e9:.1f}B"
    return f"{count / 1e6:.0f}M"


def is_unkeep(keep):
    """keep_alive values that ask Ollama to unload the model."""
    return keep == 0 or (isinstance(keep, str) and re.fullmatch(r"0+(?:\.0+)?(?:ns|us|ms|s|m|h)?", keep))


def messages_to_openai(messages):
    if not isinstance(messages, list):
        fail(400, "messages must be an array")
    output, pending = [], []
    for index, message in enumerate(messages):
        if not isinstance(message, dict):
            fail(400, "Each message must be an object")
        check_fields(message, {"role", "content", "images", "tool_calls", "tool_name", "thinking"}, "message")
        role = message.get("role")
        if not isinstance(role, str) or role not in {"system", "user", "assistant", "tool"}:
            fail(400, "Unsupported message role")
        content = message.get("content", "")
        if not isinstance(content, str):
            fail(400, "Ollama message content must be a string")
        converted = {"role": role, "content": content}
        if message.get("thinking"):
            converted["reasoning_content"] = message["thinking"]
        images = message.get("images", [])
        if not isinstance(images, list) or any(not isinstance(x, str) for x in images):
            fail(400, "images must be an array of base64 strings on user messages")
        if images:
            if role != "user":
                fail(400, "images must be an array of base64 strings on user messages")
            converted["content"] = [{"type": "text", "text": content}]
            for data in images:
                # Ollama images contain bare base64; only common image encodings are accepted.
                mime = "image/png" if data.startswith("iVBOR") else "image/jpeg" if data.startswith("/9j/") else "image/webp" if data.startswith("UklGR") else None
                if not mime:
                    fail(400, "Only base64 PNG, JPEG, and WebP images are supported")
                converted["content"].append({"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}})
        calls = message.get("tool_calls")
        if calls:
            if role != "assistant" or not isinstance(calls, list):
                fail(400, "tool_calls must be an array on assistant messages")
            converted["tool_calls"] = []
            for number, call in enumerate(calls):
                fn = call.get("function") if isinstance(call, dict) else None
                if not isinstance(fn, dict) or not isinstance(fn.get("name"), str) or not isinstance(fn.get("arguments", {}), dict):
                    fail(400, "Tool calls require a function name and object arguments")
                call_id = f"call_{index}_{number}"
                pending.append((fn["name"], call_id))
                converted["tool_calls"].append({"id": call_id, "type": "function", "function": {"name": fn["name"], "arguments": json.dumps(fn.get("arguments", {}))}})
        if role == "tool":
            matches = [item for item in pending if not message.get("tool_name") or item[0] == message["tool_name"]]
            if len(matches) != 1:
                fail(400, "Tool result must identify exactly one pending call using tool_name")
            converted["tool_call_id"] = matches[0][1]
            pending.remove(matches[0])
        output.append(converted)
    return output


def ollama_tools(calls):
    result = []
    for index, call in enumerate(calls):
        fn = call.get("function", {})
        args = fn.get("arguments") or "{}"
        if isinstance(args, str):
            args = json.loads(args)
        if not isinstance(args, dict):
            raise ValueError("Upstream tool arguments are not an object")
        result.append({"function": {"index": index, "name": fn.get("name", ""), "arguments": args}})
    return result


async def sse_events(response):
    lines = []
    async for line in response.aiter_lines():
        if not line:
            if lines:
                yield "\n".join(lines)
                lines = []
        elif line.startswith("data:"):
            lines.append(line[5:].lstrip(" "))
    if lines:
        yield "\n".join(lines)


def create_app(config=None, transport=None):
    @asynccontextmanager
    async def lifespan(app):
        app.state.config = config or Config.from_env()
        app.state.model_meta = None
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(app.state.config.timeout, connect=5),
            transport=transport, trust_env=False,
        ) as client:
            app.state.client = client
            yield

    app = FastAPI(title="llama.cpp target API", lifespan=lifespan)

    @app.exception_handler(HTTPException)
    async def error_handler(request, exc):
        return JSONResponse({"error": exc.detail}, status_code=exc.status_code)

    def cfg():
        return app.state.config

    async def body_json(request):
        try:
            body = await request.json()
        except (ValueError, UnicodeError):
            fail(400, "Request body must be valid JSON")
        if not isinstance(body, dict):
            fail(400, "Request body must be a JSON object")
        return body

    def model(body):
        if body.get("model") != cfg().alias:
            fail(404, f"Model not found; this target serves {cfg().alias!r}")

    async def upstream(path, payload=None, stream=False):
        client = app.state.client
        req = client.build_request("GET" if payload is None else "POST", cfg().base_url + path, json=payload)
        try:
            response = await client.send(req, stream=stream)
        except httpx.TimeoutException:
            fail(504, "llama-server timed out")
        except httpx.RequestError:
            fail(502, "llama-server is unreachable")
        if response.is_error:
            try:
                await response.aread()
                try:
                    error = response.json()
                    detail = error.get("error", response.text) if isinstance(error, dict) else response.text
                except ValueError:
                    detail = response.text
            except httpx.TimeoutException:
                fail(504, "llama-server error response timed out")
            except httpx.RequestError:
                fail(502, "llama-server error response was interrupted")
            finally:
                await response.aclose()
            fail(response.status_code, detail or "llama-server rejected the request")
        return response

    async def ready():
        response = await upstream("/health")
        try:
            health = response.json()
            if not isinstance(health, dict):
                fail(502, "Invalid llama-server health response")
            if health.get("status") != "ok":
                fail(503, "llama-server is not ready")
        except ValueError:
            fail(502, "Invalid llama-server health response")

    async def model_meta():
        """llama-server's own description of the loaded model (n_params,
        n_ctx_train, size), from its /v1/models "meta" block. Cached after the
        first success; {} while unavailable."""
        if app.state.model_meta is not None:
            return app.state.model_meta
        try:
            response = await app.state.client.get(cfg().base_url + "/v1/models")
            data = response.json().get("data") or []
            meta = (data[0].get("meta") if data else None) or {}
            if not isinstance(meta, dict):
                return {}
        except (httpx.HTTPError, ValueError, AttributeError, IndexError, TypeError):
            return {}
        app.state.model_meta = meta
        return meta

    def configured(value):
        return value if value and value.lower() != "unknown" else ""

    async def metadata():
        parameter_size = configured(cfg().parameter_size)
        if not parameter_size:
            # The installer defaults MODEL_PARAMETER_SIZE to "unknown", which
            # leaves the router unable to size-band this target. Ask llama-server.
            parameter_size = format_params((await model_meta()).get("n_params"))
        family = configured(cfg().family)
        details = {"format": "gguf", "family": family,
                   "families": [family] if family else [],
                   "parameter_size": parameter_size,
                   "quantization_level": configured(cfg().quantization)}
        data = {"name": cfg().alias, "model": cfg().alias, "details": details}
        if cfg().model_path:
            try:
                stat = Path(cfg().model_path).stat()
                data.update(size=stat.st_size, modified_at=datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat())
            except OSError:
                pass
        return data

    @app.get("/")
    @app.get("/healthz")
    async def health():
        await ready()
        return {"status": "ok", "backend": "llama.cpp", "model": cfg().alias}

    @app.get("/api/version")
    async def version():
        return {"version": "0.0.0-llamacpp-bridge", "backend": "llama.cpp"}

    @app.get("/api/tags")
    async def tags():
        await ready()
        return {"models": [await metadata()]}

    @app.get("/api/ps")
    async def running():
        """The resident model, in Ollama's /api/ps shape. llama-server keeps it
        loaded until the service stops, so it never expires."""
        try:
            await ready()
        except HTTPException:
            return {"models": []}
        data = await metadata()
        size = data.get("size") or (await model_meta()).get("size") or 0
        return {"models": [dict(data, digest="", size=size, size_vram=size,
                                expires_at="2999-12-31T23:59:59Z")]}

    @app.post("/api/show")
    async def show(request: Request):
        body = await body_json(request)
        # LiteLLM still sends Ollama's legacy `name` spelling for model info.
        if "model" in body and "name" in body and body["model"] != body["name"]:
            fail(400, "model and name must identify the same model")
        model({"model": body.get("model", body.get("name"))})
        await ready()
        data = await metadata()
        meta = await model_meta()
        arch = data["details"]["family"] or "llama"
        info = {"general.architecture": arch}
        if meta.get("n_params"):
            info["general.parameter_count"] = meta["n_params"]
        if meta.get("n_ctx_train"):
            info[f"{arch}.context_length"] = meta["n_ctx_train"]
        return {"details": data["details"], "capabilities": list(cfg().capabilities), "model_info": info}

    @app.get("/v1/models")
    async def models():
        await ready()
        return {"object": "list", "data": [{"id": cfg().alias, "object": "model", "created": 0, "owned_by": "llama.cpp"}]}

    @app.post("/v1/{path:path}")
    async def openai(path: str, request: Request):
        if path not in {"chat/completions", "completions", "embeddings"}:
            fail(501, "This bridge exposes OpenAI chat/completions, completions, and embeddings")
        body = await body_json(request)
        model(body)
        response = await upstream("/v1/" + path, body, stream=True)

        async def chunks():
            try:
                async for chunk in response.aiter_raw():
                    yield chunk
            finally:
                await response.aclose()

        headers = {key: value for key, value in response.headers.items()
                   if key.lower() in {"content-type", "content-encoding", "cache-control", "x-request-id"}}
        return StreamingResponse(chunks(), status_code=response.status_code, headers=headers)

    def envelope(chat, done=False):
        data = {"model": cfg().alias, "created_at": now(), "done": done}
        data["message" if chat else "response"] = {"role": "assistant", "content": ""} if chat else ""
        return data

    def finish(data, reason, usage, start):
        data.update(done=True, done_reason="length" if reason == "length" else "stop",
                    total_duration=time.monotonic_ns() - start)
        if "prompt_tokens" in usage:
            data["prompt_eval_count"] = usage["prompt_tokens"]
        if "completion_tokens" in usage:
            data["eval_count"] = usage["completion_tokens"]
        return data

    async def native(request, chat):
        start = time.monotonic_ns()
        body = await body_json(request)
        fields = {"model", "stream", "options", "format", "keep_alive"}
        fields |= {"messages", "tools"} if chat else {"prompt", "system", "raw", "images"}
        check_fields(body, fields)
        model(body)
        stream = body.get("stream", True)
        if type(stream) is not bool:
            fail(400, "stream must be boolean")
        if is_unkeep(body.get("keep_alive")):
            fail(501, "Unloading is not supported; manage the resident model with systemd")
        options, ignored = sampling(body)
        extra_headers = ignored_header(ignored)
        payload = {"model": cfg().alias, "stream": stream, **options}
        if chat:
            payload["messages"] = messages_to_openai(body.get("messages", []))
            if "tools" in body and not isinstance(body["tools"], list):
                fail(400, "tools must be an array")
            if body.get("tools"):
                payload["tools"] = body["tools"]
            empty = not payload["messages"]
        else:
            prompt = body.get("prompt", "")
            if not isinstance(prompt, str) or not isinstance(body.get("system", ""), str):
                fail(400, "prompt and system must be strings")
            if type(body.get("raw", False)) is not bool:
                fail(400, "raw must be boolean")
            empty = not prompt and not body.get("system") and not body.get("images")
            if body.get("raw"):
                if body.get("system") or body.get("images") or body.get("format"):
                    fail(400, "raw generation does not support system, images, or format")
                payload["prompt"] = prompt
            else:
                payload["messages"] = messages_to_openai(
                    ([{"role": "system", "content": body["system"]}] if body.get("system") else [])
                    + [{"role": "user", "content": prompt, "images": body.get("images", [])}])
        if empty:
            await ready()
            result = finish(envelope(chat), "stop", {}, start)
            result["done_reason"] = "load"
            return (Response(ndjson(result), media_type="application/x-ndjson", headers=extra_headers)
                    if stream else JSONResponse(result, headers=extra_headers))
        completion = "prompt" in payload
        path = "/v1/completions" if completion else "/v1/chat/completions"
        if stream:
            payload["stream_options"] = {"include_usage": True}
        response = await upstream(path, payload, stream=stream)
        if not stream:
            try:
                raw = response.json()
                choice = raw["choices"][0]
                message = choice.get("message", {})
                result = envelope(chat)
                if chat:
                    result["message"]["content"] = message.get("content") or ""
                    if message.get("reasoning_content"):
                        result["message"]["thinking"] = message["reasoning_content"]
                    if message.get("tool_calls"):
                        result["message"]["tool_calls"] = ollama_tools(message["tool_calls"])
                else:
                    result["response"] = choice.get("text", "") if completion else message.get("content") or ""
                    if message.get("reasoning_content"):
                        result["thinking"] = message["reasoning_content"]
                return JSONResponse(finish(result, choice.get("finish_reason"), raw.get("usage") or {}, start),
                                    headers=extra_headers)
            except (ValueError, KeyError, IndexError, TypeError, AttributeError):
                fail(502, "Invalid llama-server completion response")

        async def translated():
            usage, calls, reason = {}, {}, None
            try:
                async for event in sse_events(response):
                    if event == "[DONE]":
                        break
                    event = json.loads(event)
                    if event.get("error"):
                        yield ndjson({"error": event["error"]})
                        return
                    usage.update(event.get("usage") or {})
                    for choice in event.get("choices", []):
                        delta = choice.get("delta") or {}
                        text = choice.get("text", "") if completion else delta.get("content") or ""
                        thought = delta.get("reasoning_content") or ""
                        for call in delta.get("tool_calls") or []:
                            index = call.get("index", 0)
                            current = calls.setdefault(index, {"function": {"name": "", "arguments": ""}})["function"]
                            for key in ("name", "arguments"):
                                current[key] += call.get("function", {}).get(key) or ""
                        if text or thought:
                            chunk = envelope(chat)
                            if chat:
                                chunk["message"]["content"] = text
                                if thought:
                                    chunk["message"]["thinking"] = thought
                            else:
                                chunk["response"] = text
                                if thought:
                                    chunk["thinking"] = thought
                            yield ndjson(chunk)
                        reason = choice.get("finish_reason") or reason
                if reason is None:
                    yield ndjson({"error": "llama-server stream ended before a finish reason"})
                    return
                result = finish(envelope(chat), reason, usage, start)
                if calls and chat:
                    result["message"]["tool_calls"] = ollama_tools([calls[key] for key in sorted(calls)])
                yield ndjson(result)
            except (httpx.RequestError, ValueError, KeyError, TypeError, AttributeError):
                yield ndjson({"error": "Invalid or interrupted llama-server stream"})
            finally:
                await response.aclose()

        return StreamingResponse(translated(), media_type="application/x-ndjson",
                                 headers={"Cache-Control": "no-cache", **extra_headers})

    @app.post("/api/chat")
    async def chat(request: Request):
        return await native(request, True)

    @app.post("/api/generate")
    async def generate(request: Request):
        return await native(request, False)

    @app.post("/api/embed")
    @app.post("/api/embeddings")
    async def embeddings(request: Request):
        body = await body_json(request)
        check_fields(body, {"model", "input", "prompt", "truncate", "options", "keep_alive"})
        model(body)
        if body.get("options") is not None and not isinstance(body["options"], dict):
            fail(400, "options must be an object")
        if "truncate" in body and type(body["truncate"]) is not bool:
            fail(400, "truncate must be boolean")
        if is_unkeep(body.get("keep_alive")):
            fail(501, "Unloading is not supported; manage the resident model with systemd")
        # Options and keep_alive have no per-request meaning for a resident
        # llama-server; they are accepted and ignored like on /api/chat.
        ignored = sorted(body.get("options") or {})
        headers = ignored_header(ignored)
        legacy = request.url.path == "/api/embeddings"
        value = body.get("prompt" if legacy else "input")
        if not isinstance(value, str) and not (not legacy and isinstance(value, list) and all(isinstance(x, str) for x in value)):
            fail(400, "Embedding input must be a string or array of strings")
        start = time.monotonic_ns()
        response = await upstream("/v1/embeddings", {"model": cfg().alias, "input": value})
        try:
            raw = response.json()
            vectors = [item["embedding"] for item in sorted(raw["data"], key=lambda item: item["index"])]
            if legacy:
                return JSONResponse({"embedding": vectors[0]}, headers=headers)
            result = {"model": cfg().alias, "embeddings": vectors, "total_duration": time.monotonic_ns() - start}
            if "prompt_tokens" in (raw.get("usage") or {}):
                result["prompt_eval_count"] = raw["usage"]["prompt_tokens"]
            return JSONResponse(result, headers=headers)
        except (ValueError, KeyError, IndexError, TypeError):
            fail(502, "Invalid llama-server embedding response")

    @app.api_route("/api/{path:path}", methods=["GET", "POST", "DELETE", "PUT", "HEAD"])
    async def unsupported(path: str):
        fail(501, f"Ollama /api/{path} is not implemented; manage GGUF files and model lifecycle on the target")

    return app


app = create_app()
