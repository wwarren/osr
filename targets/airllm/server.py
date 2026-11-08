"""Ollama-compatible HTTP API backed by AirLLM layer-streamed inference.

Speaks enough of the Ollama wire protocol that the smart router, LiteLLM,
Open WebUI and anything else expecting an Ollama endpoint can point at it.
One process serves one model, and one generation runs at a time.

Configuration is entirely through environment variables; see
airllm.env.example. install-target.sh installs this as
/opt/airllm-target/server.py behind airllm-ollama-api.service.
"""

from __future__ import annotations

import asyncio
import functools
import hashlib
import json
import logging
import os
import queue
import re
import threading
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, AsyncIterator, Callable, Dict, List, Optional, Tuple

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse
from pydantic import BaseModel, Field

logging.basicConfig(
    level=os.getenv("AIRLLM_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
)
log = logging.getLogger("airllm-target")

NS_PER_SEC = 1_000_000_000
_SENTINEL = object()


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw)
    except ValueError:
        log.warning("%s=%r is not an integer; using %d", name, raw, default)
        return default


def _env_str(name: str, default: str = "") -> str:
    return (os.getenv(name) or default).strip()


@dataclass
class Config:
    model_id: str = field(default_factory=lambda: _env_str("AIRLLM_MODEL_ID", "Qwen/Qwen2.5-72B-Instruct"))
    # The name clients see. Defaults to model_id.
    model_alias: str = field(default_factory=lambda: _env_str("AIRLLM_MODEL_ALIAS"))
    # Reported metadata; empty means "work it out" (repo name / model config).
    model_family: str = field(default_factory=lambda: _env_str("AIRLLM_MODEL_FAMILY"))
    model_parameter_size: str = field(default_factory=lambda: _env_str("AIRLLM_MODEL_PARAMETER_SIZE"))

    # AirLLM defaults to cuda:0, so CPU layer streaming must say so explicitly.
    device: str = field(default_factory=lambda: _env_str("AIRLLM_DEVICE", "cpu"))
    # "4bit"/"8bit" need bitsandbytes. Empty means no compression.
    compression: str = field(default_factory=lambda: _env_str("AIRLLM_COMPRESSION"))
    # The context window: prompt plus reply never exceed this many tokens.
    max_seq_len: int = field(default_factory=lambda: _env_int("AIRLLM_MAX_SEQ_LEN", 2048))
    layer_shards_path: str = field(default_factory=lambda: _env_str("AIRLLM_LAYER_SHARDS_PATH"))
    # Delete the downloaded checkpoint once AirLLM has split it into shards.
    delete_original: bool = field(default_factory=lambda: _env_bool("AIRLLM_DELETE_ORIGINAL", False))
    prefetching: bool = field(default_factory=lambda: _env_bool("AIRLLM_PREFETCHING", True))
    hf_token: str = field(
        default_factory=lambda: _env_str("HF_TOKEN") or _env_str("HUGGING_FACE_HUB_TOKEN")
    )

    max_new_tokens: int = field(default_factory=lambda: _env_int("AIRLLM_MAX_NEW_TOKENS", 256))
    # One layer-streamed token can legitimately take minutes.
    token_timeout: int = field(default_factory=lambda: _env_int("AIRLLM_TOKEN_TIMEOUT", 1800))

    host: str = field(default_factory=lambda: _env_str("AIRLLM_HOST", "0.0.0.0"))  # noqa: S104
    port: int = field(default_factory=lambda: _env_int("AIRLLM_PORT", 11434))

    # Start loading at boot rather than on the first request. The port binds
    # immediately either way.
    eager_load: bool = field(default_factory=lambda: _env_bool("AIRLLM_EAGER_LOAD", True))
    # How long a request waits for a still-loading model before 503.
    load_wait: int = field(default_factory=lambda: _env_int("AIRLLM_LOAD_WAIT", 30))
    # Exit the process when loading fails, so systemd retries and, after its
    # start limit, marks the unit failed (which the monitor reports).
    exit_on_load_failure: bool = field(
        default_factory=lambda: _env_bool("AIRLLM_EXIT_ON_LOAD_FAILURE", True)
    )
    ollama_version: str = field(default_factory=lambda: _env_str("AIRLLM_OLLAMA_VERSION", "0.32.15"))

    @property
    def public_name(self) -> str:
        return self.model_alias or self.model_id


cfg = Config()


# --------------------------------------------------------------------------
# Ollama wire format
# --------------------------------------------------------------------------


def now_iso() -> str:
    """RFC3339 with nanosecond precision and a Z suffix, as Ollama emits."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f000Z")


def fake_digest(text: str) -> str:
    """Clients display a digest; nothing verifies it against real blobs."""
    return "sha256:" + hashlib.sha256(text.encode()).hexdigest()


def parameter_size(model_id: str) -> str:
    """Best-effort '72B'-style label parsed out of the repo name."""
    match = re.search(r"(\d+(?:\.\d+)?)\s*[bB]\b", re.sub(r"[-_]", " ", model_id))
    return f"{match.group(1)}B" if match else "unknown"


def model_family() -> str:
    """Configured family, else the loaded model's config.model_type."""
    if cfg.model_family:
        return cfg.model_family
    model_type = getattr(getattr(manager.model, "config", None), "model_type", None)
    return str(model_type) if model_type else "unknown"


def model_details() -> Dict[str, Any]:
    family = model_family()
    return {
        "parent_model": "",
        # Deliberately not "gguf": AirLLM serves safetensors shards.
        "format": "safetensors",
        "family": family,
        "families": [family],
        "parameter_size": cfg.model_parameter_size or parameter_size(cfg.model_id),
        "quantization_level": cfg.compression or "BF16",
    }


def model_entry() -> Dict[str, Any]:
    return {
        "name": cfg.public_name,
        "model": cfg.public_name,
        "modified_at": now_iso(),
        "size": 0,
        # Discovery caches /api/show by digest. Include the served window so
        # changing MAX_SEQ_LEN re-probes context even with the same weights.
        "digest": fake_digest(f"{cfg.model_id}:{cfg.max_seq_len}"),
        "details": model_details(),
    }


@dataclass
class Timing:
    """The nanosecond counters Ollama clients read to build usage stats."""

    started: float = field(default_factory=time.perf_counter)
    load_ns: int = 0
    prompt_eval_ns: int = 0
    prompt_tokens: int = 0
    eval_ns: int = 0
    eval_tokens: int = 0

    def as_packet_fields(self) -> Dict[str, Any]:
        return {
            "total_duration": int((time.perf_counter() - self.started) * NS_PER_SEC),
            "load_duration": self.load_ns,
            "prompt_eval_count": self.prompt_tokens,
            "prompt_eval_duration": self.prompt_eval_ns,
            "eval_count": self.eval_tokens,
            "eval_duration": self.eval_ns,
        }


def chat_chunk(content: str) -> Dict[str, Any]:
    return {
        "model": cfg.public_name,
        "created_at": now_iso(),
        "message": {"role": "assistant", "content": content, "images": None},
        "done": False,
    }


def chat_final(timing: Timing, done_reason: str = "stop") -> Dict[str, Any]:
    # LiteLLM requires `message` on every packet, the final one included, and
    # reads usage from prompt_eval_count / eval_count.
    return {
        "model": cfg.public_name,
        "created_at": now_iso(),
        "message": {"role": "assistant", "content": ""},
        "done": True,
        "done_reason": done_reason,
        **timing.as_packet_fields(),
    }


def generate_chunk(content: str) -> Dict[str, Any]:
    return {"model": cfg.public_name, "created_at": now_iso(), "response": content, "done": False}


def generate_final(timing: Timing, done_reason: str = "stop") -> Dict[str, Any]:
    return {
        "model": cfg.public_name,
        "created_at": now_iso(),
        "response": "",
        "done": True,
        "done_reason": done_reason,
        "context": [],
        **timing.as_packet_fields(),
    }


# --------------------------------------------------------------------------
# Generation
# --------------------------------------------------------------------------


class ModelNotReady(RuntimeError):
    pass


class Generation:
    """A single in-flight generation.

    The producer thread owns the whole lifecycle: it takes the model lock,
    runs the model, and releases the lock only once generation has actually
    stopped. The HTTP layer only reads from the queue and may set `cancel`.
    """

    def __init__(self) -> None:
        self.chunks: "queue.Queue[Any]" = queue.Queue(maxsize=256)
        self.cancel = threading.Event()
        self.timing = Timing()
        self.error: Optional[BaseException] = None
        self.done_reason = "stop"


def _exit_process() -> None:  # pragma: no cover - replaced in tests
    logging.shutdown()
    os._exit(1)


class ModelManager:
    """Owns the AirLLM model and serializes access to it.

    AirLLM streams layers through one shared set of buffers, so exactly one
    generation may be in flight at a time.
    """

    def __init__(self, config: Config) -> None:
        self.cfg = config
        self.model: Any = None
        self.load_error: Optional[BaseException] = None
        self.load_ns = 0
        self._ready = threading.Event()
        self._gen_lock = threading.Lock()
        self._load_lock = threading.Lock()
        self._loader: Optional[threading.Thread] = None
        # Called after a failed load when exit_on_load_failure is set.
        self.on_load_failure: Callable[[], None] = _exit_process

    # -- loading ----------------------------------------------------------

    @property
    def ready(self) -> bool:
        return self._ready.is_set()

    def status(self) -> str:
        if self.ready:
            return "ready"
        return "error" if self.load_error is not None else "loading"

    def load(self) -> None:
        with self._load_lock:
            if self._ready.is_set():
                return
            started = time.perf_counter()
            try:
                from airllm import AutoModel  # late import keeps startup cheap

                kwargs: Dict[str, Any] = {"device": self.cfg.device, "prefetching": self.cfg.prefetching}
                if self.cfg.max_seq_len:
                    kwargs["max_seq_len"] = self.cfg.max_seq_len
                if self.cfg.compression:
                    kwargs["compression"] = self.cfg.compression
                if self.cfg.layer_shards_path:
                    kwargs["layer_shards_saving_path"] = self.cfg.layer_shards_path
                if self.cfg.hf_token:
                    kwargs["hf_token"] = self.cfg.hf_token
                if self.cfg.delete_original:
                    kwargs["delete_original"] = True

                log.info(
                    "loading %s on %s (compression=%s, max_seq_len=%s); the first run "
                    "downloads and splits the weights, so expect this to be slow",
                    self.cfg.model_id, self.cfg.device, self.cfg.compression or "none",
                    self.cfg.max_seq_len,
                )
                self.model = AutoModel.from_pretrained(self.cfg.model_id, **kwargs)
                self.load_ns = int((time.perf_counter() - started) * NS_PER_SEC)
                self.load_error = None
                self._ready.set()
                log.info("model ready after %.1fs", self.load_ns / NS_PER_SEC)
            except BaseException as exc:  # noqa: BLE001 - surfaced via /health, then exit
                self.load_error = exc
                log.exception("model load failed")
                raise

    def load_in_background(self) -> None:
        """Start one loader thread; a second call while it runs is a no-op."""
        if self.ready or (self._loader is not None and self._loader.is_alive()):
            return

        def run() -> None:
            try:
                self.load()
            except BaseException:  # noqa: BLE001 - already logged and recorded
                if self.cfg.exit_on_load_failure:
                    log.error("exiting so systemd can retry the load (see the error above)")
                    self.on_load_failure()

        self._loader = threading.Thread(target=run, name="airllm-load", daemon=True)
        self._loader.start()

    def require(self, timeout: Optional[float] = None) -> None:
        """Block until the model is usable, or raise ModelNotReady."""
        if self.ready:
            return
        if not self.cfg.eager_load:
            self.load_in_background()
        wait = self.cfg.load_wait if timeout is None else timeout
        if not self._ready.wait(timeout=wait):
            if self.load_error is not None:
                raise ModelNotReady(f"model failed to load: {self.load_error}")
            raise ModelNotReady(
                "model is still loading; check /health or "
                "`journalctl -u airllm-ollama-api -f` for progress"
            )

    # -- prompting --------------------------------------------------------

    def fit_prompt(self, input_ids: Any, max_new_tokens: int) -> Tuple[Any, int]:
        """Fit prompt + reply into max_seq_len, keeping the newest tokens.

        The reply keeps up to half the window; older prompt tokens are dropped
        from the front (as Ollama does), never the end, which holds the latest
        turn and the assistant header.
        """
        window = self.cfg.max_seq_len
        if window <= 1:
            return input_ids, max_new_tokens
        reserve = max(1, min(max_new_tokens, window // 2))
        keep = window - reserve
        length = int(input_ids.shape[-1])
        if length > keep:
            log.warning("prompt of %d tokens exceeds the %d-token budget; dropping the oldest %d",
                        length, keep, length - keep)
            input_ids = input_ids[:, -keep:]
            length = keep
        return input_ids, max(1, min(max_new_tokens, window - length))

    def tokenize(self, text: str) -> Any:
        # Chat templates (and the manual Llama 3 one) already contain the BOS
        # and other special tokens; adding them again would double them.
        inputs = self.model.tokenizer(
            text,
            return_tensors="pt",
            return_attention_mask=False,
            add_special_tokens=False,
            padding=False,
        )
        input_ids = inputs["input_ids"]
        if self.cfg.device and hasattr(input_ids, "to"):
            input_ids = input_ids.to(self.cfg.device)
        return input_ids

    def count_tokens(self, text: str) -> int:
        if not text:
            return 0
        try:
            return len(self.model.tokenizer.encode(text, add_special_tokens=False))
        except Exception:  # noqa: BLE001 - usage numbers are advisory
            return 0

    def build_prompt(self, messages: List["ChatMessage"]) -> str:
        """Prefer the tokenizer's own chat template; fall back to Llama 3."""
        payload = [{"role": m.role, "content": m.content or ""} for m in messages]
        tokenizer = self.model.tokenizer
        if getattr(tokenizer, "chat_template", None):
            try:
                return tokenizer.apply_chat_template(payload, tokenize=False, add_generation_prompt=True)
            except Exception:  # noqa: BLE001 - fall through to the manual template
                log.warning("apply_chat_template failed; using the manual Llama 3 template")
        return llama3_prompt(payload)

    # -- generation -------------------------------------------------------

    def submit(self, prompt: str, max_new_tokens: int, gen_options: Dict[str, Any],
               seed: Optional[int] = None) -> Generation:
        """Start a generation on a background thread and return its handle."""
        gen = Generation()

        def producer() -> None:
            try:
                # Queue behind any generation already using the model.
                with self._gen_lock:
                    if gen.cancel.is_set():
                        return
                    self._run(prompt, gen, max_new_tokens, gen_options, seed)
            except BaseException as exc:  # noqa: BLE001 - re-raised to the caller
                gen.error = exc
                log.exception("generation failed")
            finally:
                gen.chunks.put(_SENTINEL)

        threading.Thread(target=producer, name="airllm-producer", daemon=True).start()
        return gen

    def _run(self, prompt: str, gen: Generation, max_new_tokens: int,
             gen_options: Dict[str, Any], seed: Optional[int]) -> None:
        from transformers import StoppingCriteria, StoppingCriteriaList, TextIteratorStreamer

        class CancelCriteria(StoppingCriteria):
            def __call__(self, input_ids, scores, **kwargs) -> bool:  # noqa: D102
                return gen.cancel.is_set()

        if seed is not None:
            # Seeded under the model lock, so it cannot disturb another request.
            import torch

            torch.manual_seed(seed)

        gen.timing.load_ns = self.load_ns
        tokenizer = self.model.tokenizer

        tokenize_started = time.perf_counter()
        input_ids, max_new_tokens = self.fit_prompt(self.tokenize(prompt), max_new_tokens)
        gen.timing.prompt_tokens = int(input_ids.shape[-1])
        gen.timing.prompt_eval_ns = int((time.perf_counter() - tokenize_started) * NS_PER_SEC)

        streamer = TextIteratorStreamer(
            tokenizer, skip_prompt=True, skip_special_tokens=True, timeout=self.cfg.token_timeout
        )
        kwargs: Dict[str, Any] = dict(
            inputs=input_ids,
            streamer=streamer,
            max_new_tokens=max_new_tokens,
            # Without a KV cache, every token replays every layer from disk.
            use_cache=True,
            stopping_criteria=StoppingCriteriaList([CancelCriteria()]),
            **gen_options,
        )

        failure: List[BaseException] = []

        def run_model() -> None:
            try:
                self.model.generate(**kwargs)
            except BaseException as exc:  # noqa: BLE001 - re-raised by the producer
                failure.append(exc)
            finally:
                # Always unblock the iterator, or the request hangs forever.
                try:
                    streamer.end()
                except Exception:  # noqa: BLE001
                    pass

        worker = threading.Thread(target=run_model, name="airllm-generate", daemon=True)
        eval_started = time.perf_counter()
        worker.start()

        produced: List[str] = []
        try:
            for text in streamer:
                if not text:
                    continue
                produced.append(text)
                if gen.cancel.is_set():
                    break
                try:
                    gen.chunks.put(text, timeout=self.cfg.token_timeout)
                except queue.Full:  # consumer vanished
                    gen.cancel.set()
                    break
        finally:
            # Safe to block here: this is the producer thread, not the loop.
            worker.join(timeout=self.cfg.token_timeout)
            gen.timing.eval_ns = int((time.perf_counter() - eval_started) * NS_PER_SEC)
            gen.timing.eval_tokens = self.count_tokens("".join(produced))
            if gen.timing.eval_tokens >= max_new_tokens:
                gen.done_reason = "length"

        if failure:
            raise failure[0]


def llama3_prompt(messages: List[Dict[str, str]]) -> str:
    """Manual Llama 3 template, used only when the tokenizer has none."""
    out = "<|begin_of_text|>"
    for msg in messages:
        role = str(msg.get("role", "user")).lower()
        out += f"<|start_header_id|>{role}<|end_header_id|>\n\n{msg.get('content', '')}<|eot_id|>"
    out += "<|start_header_id|>assistant<|end_header_id|>\n\n"
    return out


manager = ModelManager(cfg)


# --------------------------------------------------------------------------
# Request schemas
# --------------------------------------------------------------------------


class ChatMessage(BaseModel):
    role: str = "user"
    # Tool-call turns send content: null.
    content: Optional[str] = ""
    images: Optional[List[str]] = None


class GenerateRequest(BaseModel):
    model: Optional[str] = None
    prompt: str = ""
    system: Optional[str] = None
    stream: bool = True
    raw: bool = False
    options: Dict[str, Any] = Field(default_factory=dict)
    keep_alive: Optional[Any] = None
    images: Optional[List[str]] = None


class ChatRequest(BaseModel):
    model: Optional[str] = None
    messages: List[ChatMessage] = Field(default_factory=list)
    stream: bool = True
    options: Dict[str, Any] = Field(default_factory=dict)
    keep_alive: Optional[Any] = None
    tools: Optional[List[Dict[str, Any]]] = None


class OpenAIChatRequest(BaseModel):
    """The subset of OpenAI's chat completion request this target serves.
    Unknown fields (stop, presence_penalty, ...) are accepted and ignored."""

    model: Optional[str] = None
    messages: List[Dict[str, Any]] = Field(default_factory=list)
    stream: bool = False
    max_tokens: Optional[int] = None
    max_completion_tokens: Optional[int] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    seed: Optional[int] = None
    tools: Optional[List[Dict[str, Any]]] = None
    tool_choice: Optional[Any] = None
    functions: Optional[List[Dict[str, Any]]] = None
    function_call: Optional[Any] = None


class ShowRequest(BaseModel):
    model: Optional[str] = None
    name: Optional[str] = None


class ModelRequest(BaseModel):
    model: Optional[str] = None
    name: Optional[str] = None
    stream: bool = True


def model_names() -> set:
    names = {cfg.model_id, cfg.public_name}
    names.update(f"{name}:latest" for name in list(names) if ":" not in name)
    return {name for name in names if name}


def requested_model_name(*values: Optional[str]) -> Optional[str]:
    for value in values:
        if value and value.strip():
            return value.strip()
    return None


def assert_known_model(*values: Optional[str]) -> None:
    requested = requested_model_name(*values)
    if requested is None:
        return
    if requested not in model_names():
        raise HTTPException(status_code=404, detail=f"model {requested!r} is not served by this AirLLM process")


def resolve_options(options: Dict[str, Any]) -> Tuple[int, Dict[str, Any], Optional[int]]:
    """Translate Ollama `options` into generate() kwargs plus an optional seed."""
    max_new_tokens = cfg.max_new_tokens
    num_predict = options.get("num_predict")
    if isinstance(num_predict, int) and not isinstance(num_predict, bool) and num_predict > 0:
        max_new_tokens = num_predict

    gen: Dict[str, Any] = {}
    temperature = options.get("temperature")
    sampling = True
    if isinstance(temperature, (int, float)) and not isinstance(temperature, bool):
        if temperature > 0:
            gen["do_sample"] = True
            gen["temperature"] = float(temperature)
        else:
            gen["do_sample"] = False
            sampling = False
    if sampling:
        # Sampling knobs are meaningless (and warned about) under greedy decoding.
        for src, dst in (("top_p", "top_p"), ("top_k", "top_k")):
            value = options.get(src)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                gen[dst] = value
    repeat = options.get("repeat_penalty")
    if isinstance(repeat, (int, float)) and not isinstance(repeat, bool):
        gen["repetition_penalty"] = repeat
    seed = options.get("seed")
    seed = seed if isinstance(seed, int) and not isinstance(seed, bool) and seed >= 0 else None
    return max_new_tokens, gen, seed


def prompt_for_generate(req: GenerateRequest) -> str:
    if req.raw:
        return req.prompt
    messages: List[ChatMessage] = []
    if req.system:
        messages.append(ChatMessage(role="system", content=req.system))
    messages.append(ChatMessage(role="user", content=req.prompt))
    return manager.build_prompt(messages)


# --------------------------------------------------------------------------
# App
# --------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    if cfg.eager_load:
        # Background thread: the socket binds now and /api/version answers
        # immediately; /api/tags reports the model once it is usable.
        manager.load_in_background()
    yield


app = FastAPI(title="AirLLM Ollama-compatible API", lifespan=lifespan)


def not_ready_response() -> JSONResponse:
    status = manager.status()
    detail = "model is still loading" if status == "loading" else f"model failed to load: {manager.load_error}"
    return JSONResponse(status_code=503, content={"status": status, "error": detail})


async def _next_item(gen: Generation) -> Any:
    loop = asyncio.get_running_loop()
    try:
        return await loop.run_in_executor(None, functools.partial(gen.chunks.get, timeout=1.0))
    except queue.Empty:
        return None


def ndjson_stream(
    request: Request,
    gen: Generation,
    chunk_fn: Callable[[str], Dict[str, Any]],
    final_fn: Callable[..., Dict[str, Any]],
) -> StreamingResponse:
    """Drain a Generation to the client as NDJSON, honouring disconnects."""

    async def body() -> AsyncIterator[str]:
        finished = False
        try:
            while True:
                item = await _next_item(gen)
                if item is None:
                    # No token yet: a good moment to notice a vanished client.
                    if await request.is_disconnected():
                        return
                    continue
                if item is _SENTINEL:
                    break
                yield json.dumps(chunk_fn(item)) + "\n"
                if await request.is_disconnected():
                    return
            if gen.error is not None:
                yield json.dumps({"error": f"{type(gen.error).__name__}: {gen.error}"}) + "\n"
            else:
                yield json.dumps(final_fn(gen.timing, gen.done_reason)) + "\n"
            finished = True
        finally:
            # Starlette cancels this generator on disconnect, so this is the
            # branch that actually stops an abandoned generation and frees the
            # model lock.
            if not finished:
                log.info("stream ended early; cancelling generation")
                gen.cancel.set()

    return StreamingResponse(body(), media_type="application/x-ndjson")


async def collect(request: Request, gen: Generation) -> str:
    """Gather a whole reply for stream=false, cancelling if the client leaves."""
    parts: List[str] = []
    finished = False
    try:
        while True:
            item = await _next_item(gen)
            if item is None:
                if await request.is_disconnected():
                    raise HTTPException(status_code=499, detail="client disconnected")
                continue
            if item is _SENTINEL:
                break
            parts.append(item)
        finished = True
    finally:
        if not finished:
            log.info("client left before the reply finished; cancelling generation")
            gen.cancel.set()
    if gen.error is not None:
        log.error("generation failed: %s", gen.error)
        raise HTTPException(status_code=500, detail=f"{type(gen.error).__name__}: {gen.error}")
    return "".join(parts)


async def run_blocking(fn):
    """Run a blocking call off the event loop and map errors onto HTTP."""
    try:
        return await asyncio.get_running_loop().run_in_executor(None, fn)
    except ModelNotReady as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001
        log.exception("request failed")
        raise HTTPException(status_code=500, detail=f"{type(exc).__name__}: {exc}") from exc


def warn_unsupported(images: bool, tools: int = 0) -> None:
    if images:
        log.warning("image inputs are unsupported by the AirLLM target; answering from text only")
    if tools:
        log.warning("tool calling is unsupported; ignoring %d tool definitions", tools)


@app.get("/", response_class=PlainTextResponse)
@app.head("/", response_class=PlainTextResponse)
async def root() -> str:
    return "Ollama is running"


@app.get("/healthz")
async def healthz():
    """Ready means a request would be served now (same contract as the llama.cpp bridge)."""
    if not manager.ready:
        return not_ready_response()
    return {"status": "ok", "backend": "airllm", "model": cfg.public_name}


@app.get("/health")
async def health() -> Dict[str, Any]:
    """Diagnostics; always 200 so a loading target can still be inspected."""
    return {
        "status": manager.status(),
        "model": cfg.public_name,
        "model_id": cfg.model_id,
        "device": cfg.device,
        "compression": cfg.compression or None,
        "max_seq_len": cfg.max_seq_len,
        "error": None if manager.load_error is None else str(manager.load_error),
    }


@app.get("/api/version")
async def version() -> Dict[str, str]:
    return {"version": cfg.ollama_version, "backend": "airllm"}


@app.get("/api/tags")
async def tags():
    # The router and monitor treat a 503 here as "down", so a loading or
    # broken target is never sent traffic (same as the llama.cpp bridge).
    if not manager.ready:
        return not_ready_response()
    return {"models": [model_entry()]}


@app.get("/api/ps")
async def ps() -> Dict[str, Any]:
    if not manager.ready:
        return {"models": []}
    entry = model_entry()
    entry.pop("modified_at", None)
    entry["expires_at"] = "2999-12-31T23:59:59Z"  # never unloaded
    entry["size_vram"] = 0  # layers are streamed, not resident
    return {"models": [entry]}


@app.post("/api/show")
async def show(req: ShowRequest) -> Dict[str, Any]:
    assert_known_model(req.model, req.name)
    family = model_family()
    return {
        "modelfile": f"FROM {cfg.model_id}",
        "parameters": f"num_ctx {cfg.max_seq_len}\nnum_predict {cfg.max_new_tokens}",
        "template": "{{ .Prompt }}",
        "details": model_details(),
        "model_info": {
            "general.architecture": family,
            "general.parameter_count": 0,
            f"{family}.context_length": cfg.max_seq_len,
        },
        "capabilities": ["completion"],
    }


@app.post("/api/chat")
async def chat(req: ChatRequest, request: Request):
    assert_known_model(req.model)
    warn_unsupported(any(m.images for m in req.messages), len(req.tools or []))

    def start() -> Generation:
        manager.require()
        prompt = manager.build_prompt(req.messages)
        max_new_tokens, gen_options, seed = resolve_options(req.options)
        return manager.submit(prompt, max_new_tokens, gen_options, seed)

    gen = await run_blocking(start)
    if req.stream:
        return ndjson_stream(request, gen, chat_chunk, chat_final)
    text = await collect(request, gen)
    packet = chat_final(gen.timing, gen.done_reason)
    packet["message"] = {"role": "assistant", "content": text}
    return packet


# --- OpenAI-compatible chat (the router's direct dispatch path) -----------------------


def openai_messages(raw: List[Dict[str, Any]]) -> Tuple[List[ChatMessage], bool]:
    """OpenAI messages -> ChatMessages, and whether any carried an image.
    Content may be a string or a list of parts; only text parts are used."""
    messages, images = [], False
    for item in raw:
        content = item.get("content")
        if isinstance(content, list):
            texts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    texts.append(str(part.get("text") or ""))
                elif isinstance(part, dict) and part.get("type") in ("image_url", "input_image"):
                    images = True
            content = "".join(texts)
        elif content is not None and not isinstance(content, str):
            raise HTTPException(status_code=400, detail="message content must be a string or a list of parts")
        role = str(item.get("role") or "user")
        messages.append(ChatMessage(role="system" if role == "developer" else role, content=content or ""))
    return messages, images


def openai_options(req: OpenAIChatRequest) -> Dict[str, Any]:
    """OpenAI sampling fields as the Ollama options resolve_options reads."""
    options: Dict[str, Any] = {}
    limit = req.max_completion_tokens if req.max_completion_tokens is not None else req.max_tokens
    if limit is not None:
        options["num_predict"] = limit
    for key in ("temperature", "top_p", "seed"):
        value = getattr(req, key)
        if value is not None:
            options[key] = value
    return options


def openai_error(status: int, message: str, kind: str = "invalid_request_error") -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"message": message, "type": kind}})


def finish_reason(done_reason: str) -> str:
    return "length" if done_reason == "length" else "stop"


def sse_stream(request: Request, gen: Generation, completion_id: str, created: int) -> StreamingResponse:
    """Drain a Generation as OpenAI chat.completion.chunk events, ending with
    data: [DONE]. A failed generation ends with an error event and no [DONE]."""

    def event(delta: Dict[str, Any], reason: Optional[str] = None) -> str:
        chunk = {"id": completion_id, "object": "chat.completion.chunk", "created": created,
                 "model": cfg.public_name,
                 "choices": [{"index": 0, "delta": delta, "finish_reason": reason}]}
        return "data: " + json.dumps(chunk) + "\n\n"

    async def body() -> AsyncIterator[str]:
        finished = False
        try:
            yield event({"role": "assistant", "content": ""})
            while True:
                item = await _next_item(gen)
                if item is None:
                    if await request.is_disconnected():
                        return
                    continue
                if item is _SENTINEL:
                    break
                yield event({"content": item})
                if await request.is_disconnected():
                    return
            if gen.error is not None:
                error = {"message": f"{type(gen.error).__name__}: {gen.error}", "type": "server_error"}
                yield "data: " + json.dumps({"error": error}) + "\n\n"
            else:
                yield event({}, finish_reason(gen.done_reason))
                yield "data: [DONE]\n\n"
            finished = True
        finally:
            if not finished:
                log.info("stream ended early; cancelling generation")
                gen.cancel.set()

    return StreamingResponse(body(), media_type="text/event-stream")


@app.get("/v1/models")
async def openai_models():
    if not manager.ready:
        return not_ready_response()
    return {"object": "list", "data": [{"id": cfg.public_name, "object": "model",
                                        "created": 0, "owned_by": "airllm"}]}


@app.post("/v1/chat/completions")
async def openai_chat(req: OpenAIChatRequest, request: Request):
    """OpenAI chat completions, for the router's direct dispatch. Tool calling
    is refused with a 400 rather than ignored: a caller that offers tools must
    learn that this model cannot use them (the router then tries another)."""
    assert_known_model(req.model)
    if ((req.tools and req.tool_choice != "none")
            or (req.functions and req.function_call != "none")):
        return openai_error(400, f"model {cfg.public_name!r} does not support tools")
    messages, images = openai_messages(req.messages)
    warn_unsupported(images)
    max_new_tokens, gen_options, seed = resolve_options(openai_options(req))
    created = int(time.time())
    completion_id = "chatcmpl-" + uuid.uuid4().hex

    def start() -> Generation:
        manager.require()
        return manager.submit(manager.build_prompt(messages), max_new_tokens, gen_options, seed)

    gen = await run_blocking(start)
    if req.stream:
        return sse_stream(request, gen, completion_id, created)
    text = await collect(request, gen)
    timing = gen.timing
    return {
        "id": completion_id, "object": "chat.completion", "created": created,
        "model": cfg.public_name,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                     "finish_reason": finish_reason(gen.done_reason)}],
        "usage": {"prompt_tokens": timing.prompt_tokens, "completion_tokens": timing.eval_tokens,
                  "total_tokens": timing.prompt_tokens + timing.eval_tokens},
    }


@app.post("/api/generate")
async def generate(req: GenerateRequest, request: Request):
    assert_known_model(req.model)
    warn_unsupported(bool(req.images))

    def start() -> Generation:
        manager.require()
        prompt = prompt_for_generate(req)
        max_new_tokens, gen_options, seed = resolve_options(req.options)
        return manager.submit(prompt, max_new_tokens, gen_options, seed)

    gen = await run_blocking(start)
    if req.stream:
        return ndjson_stream(request, gen, generate_chunk, generate_final)
    text = await collect(request, gen)
    packet = generate_final(gen.timing, gen.done_reason)
    packet["response"] = text
    return packet


@app.post("/api/embeddings")
@app.post("/api/embed")
async def embeddings() -> JSONResponse:
    return JSONResponse(status_code=501, content={"error": "embeddings are not supported by the AirLLM target"})


@app.post("/api/pull")
async def pull(req: ModelRequest) -> Any:
    assert_known_model(req.model, req.name)
    manager.load_in_background()
    if not req.stream:
        return {"status": "success"}

    async def body() -> AsyncIterator[str]:
        for status in ("pulling manifest", "verifying sha256 digest", "success"):
            yield json.dumps({"status": status}) + "\n"

    return StreamingResponse(body(), media_type="application/x-ndjson")


@app.post("/api/create")
@app.post("/api/copy")
@app.post("/api/push")
async def unsupported_model_write() -> JSONResponse:
    return JSONResponse(
        status_code=501,
        content={"error": "this AirLLM target serves one configured Hugging Face model; "
                          "Ollama model creation, copying and pushing are not supported"},
    )


@app.delete("/api/delete")
@app.post("/api/delete")
async def delete(req: ModelRequest) -> JSONResponse:
    assert_known_model(req.model, req.name)
    return JSONResponse(status_code=501, content={"error": "the configured AirLLM model cannot be deleted through this API"})


def main() -> None:
    import uvicorn

    if cfg.host in ("0.0.0.0", "::"):  # noqa: S104 - informational
        log.warning("listening on all interfaces without authentication; keep this target "
                    "on an isolated network or firewall port %d to the router", cfg.port)
    uvicorn.run(app, host=cfg.host, port=cfg.port, log_level="info", workers=1)


if __name__ == "__main__":
    main()
