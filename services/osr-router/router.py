import asyncio
import configparser
import contextvars
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import secrets
import time
from collections import OrderedDict
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, HTTPException, Request
from starlette.background import BackgroundTask
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.datastructures import Headers

logging.basicConfig(level=os.getenv("ROUTER_LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("router")
# httpx logs every request at INFO; the router logs its own decisions instead.
logging.getLogger("httpx").setLevel(logging.WARNING)

# --- request IDs ---------------------------------------------------------------
# Every request has an ID: the caller's X-Request-ID when it sends a plain one,
# else a new one. It is returned as X-Router-Request-ID (and as X-Request-ID
# unless the upstream answer already carries its own), sent upstream as
# X-Request-ID, and put in front of every line the router logs for the request,
# so one grep finds the routing decision, the failovers and the backend's side.
_REQUEST_ID = contextvars.ContextVar("osr_request_id", default="")
_REQUEST_ID_OK = re.compile(r"[A-Za-z0-9._:-]{1,64}")


def request_id() -> str:
    """The ID of the request being handled, or "" outside one (discovery)."""
    return _REQUEST_ID.get()


def accept_request_id(supplied) -> str:
    """A caller's X-Request-ID when it is a plain token of up to 64 characters;
    otherwise (none, too long, or with characters that could confuse a log or a
    header) a new random one."""
    if supplied and _REQUEST_ID_OK.fullmatch(supplied):
        return supplied
    return secrets.token_hex(8)


class _RequestIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        current = _REQUEST_ID.get()
        if current:
            record.msg = "[%s] %s" % (current, record.msg)
        return True


# The logger outlives a reload of this module (the tests load it many times).
log.filters[:] = [f for f in log.filters if type(f).__name__ != "_RequestIdFilter"]
log.addFilter(_RequestIdFilter())

# --- metrics ---------------------------------------------------------------------
# Counters and histograms behind GET /metrics, in Prometheus text format, kept
# in this process (they start again at zero with the router). Label values come
# from the router's own configuration and inventory (servers, models, classes,
# statuses), never from what a client sent, so the number of series is bounded.
_STARTED = time.time()
_COUNTERS = {}      # (name, ((label, value), ...)) -> count
_HISTOGRAMS = {}    # (name, ((label, value), ...)) -> [per-bucket counts..., sum, count]
DURATION_BUCKETS = (0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0, 120.0, 300.0, 600.0)
METRIC_SERIES_MAX = 5000   # a last guard; never reached with bounded labels
METRICS = {
    "osr_requests_total": ("counter", "Requests answered, by route (chat, images, v1, routing), "
                           "how they were served and the HTTP status returned."),
    "osr_upstream_failures_total": ("counter", "Attempts on a model server that failed, by reason: "
                                    "connect, transport, no_reply, http_<status>, tool_rejection."),
    "osr_response_start_seconds": ("histogram", "Chat requests answered below 400: seconds from "
                                   "arrival until the response headers were sent (model load and "
                                   "prompt processing included, where the server waits for them)."),
    "osr_request_duration_seconds": ("histogram", "Chat requests answered below 400: seconds from "
                                     "arrival until the last byte of the body was sent."),
    "osr_in_flight_requests": ("gauge", "Requests this router has in flight on a model server."),
    "osr_server_up": ("gauge", "1 when the last discovery poll (or dispatch) found the server up, else 0."),
    "osr_server_models": ("gauge", "Models the server listed at the last discovery poll."),
    "osr_inventory_age_seconds": ("gauge", "Seconds since the inventory was last refreshed."),
    "osr_remembered_conversations": ("gauge", "Conversations whose last server is remembered (affinity)."),
    "osr_start_time_seconds": ("gauge", "Unix time at which this router process started."),
}


def count(name: str, **labels) -> None:
    """Add one to a counter."""
    key = (name, tuple(sorted(labels.items())))
    if key in _COUNTERS or len(_COUNTERS) < METRIC_SERIES_MAX:
        _COUNTERS[key] = _COUNTERS.get(key, 0) + 1


def observe(name: str, seconds: float, **labels) -> None:
    """Record one duration in a histogram."""
    key = (name, tuple(sorted(labels.items())))
    series = _HISTOGRAMS.get(key)
    if series is None:
        if len(_HISTOGRAMS) >= METRIC_SERIES_MAX:
            return
        series = _HISTOGRAMS[key] = [0] * len(DURATION_BUCKETS) + [0.0, 0]
    for index, bound in enumerate(DURATION_BUCKETS):
        if seconds <= bound:
            series[index] += 1
            break
    series[-2] += seconds
    series[-1] += 1


def _label_text(labels, extra: str = "") -> str:
    """{a="b",...} for a series, values escaped as the text format requires."""
    parts = ['%s="%s"' % (name, str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n"))
             for name, value in labels]
    if extra:
        parts.append(extra)
    return "{%s}" % ",".join(parts) if parts else ""


def _number(value) -> str:
    return str(int(value)) if float(value).is_integer() else repr(float(value))

# The router is a drop-in OpenAI endpoint in front of the LiteLLM proxy.
# /v1/chat/completions has its model chosen by complexity analysis; every other
# /v1/* path (notably /v1/models, which Open WebUI calls to populate its model
# list) is proxied through unchanged unless the caller explicitly selects the
# optional subscription gateway.
LITELLM_BASE = os.getenv("LITELLM_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
LITELLM_URL = os.getenv("LITELLM_URL", f"{LITELLM_BASE}/v1/chat/completions")

# Optional newer LiteLLM gateway for per-client subscription logins. The
# built-in pinned LiteLLM remains the local/API-key path.
SUBSCRIPTION_GATEWAY_BASE = (os.getenv("SUBSCRIPTION_GATEWAY_BASE_URL") or "").rstrip("/")
if SUBSCRIPTION_GATEWAY_BASE:
    try:
        _subscription_url = urlsplit(SUBSCRIPTION_GATEWAY_BASE)
        _subscription_valid = (
            (_subscription_url.scheme == "https" or
             (_subscription_url.scheme == "http" and _subscription_url.hostname in
              ("localhost", "127.0.0.1", "::1")))
            and bool(_subscription_url.hostname)
            and (_subscription_url.port is None or _subscription_url.port > 0)
            and not (_subscription_url.path or _subscription_url.username or
                     _subscription_url.password or _subscription_url.query or
                     _subscription_url.fragment))
    except ValueError:
        _subscription_valid = False
    if not _subscription_valid:
        log.error("invalid SUBSCRIPTION_GATEWAY_BASE_URL: use HTTPS or loopback HTTP root URL")
        SUBSCRIPTION_GATEWAY_BASE = ""

# Routing behaviour lives in router.ini (version controlled) so thresholds,
# keyword lists and discovery heuristics can change without editing this file.
# Built-in defaults keep the service working if the ini is missing or partial.
# Code signals. Bare "class " / "import " / "def " matched prose ("first class
# ticket", "import my contacts"), so those are regexes for their code shapes.
CODE_KEYWORD_DEFAULTS = [
    r"re:\bdef\s+\w+\s*\(", r"re:\bfn\s+\w+\s*\(", r"re:\bclass\s+\w+\s*[:({]",
    r"re:^\s*(?:from\s+\S+\s+)?import\s+[\w.]+", r"re:```", "function", "sql",
    "script", "code", "bug", "error", "compile", "stack trace", "regex",
]
_DEFAULTS = {
    "thresholds": {"xlarge": "2000", "large": "800", "medium": "250"},
    "keywords": {
        "code_first": "true",
        "code": json.dumps(CODE_KEYWORD_DEFAULTS),
        "large": json.dumps(["analyze", "evaluate", "optimise", "optimize",
                             "architecture", "mathematics", "calculate",
                             "summarise this article"]),
        "xlarge": json.dumps(["prove", "derive", "rigorous", "comprehensive",
                              "exhaustive", "step by step proof",
                              "entire codebase", "whole repository",
                              "research report", "literature review"]),
    },
    "tiers": {"fast": "fast", "medium": "medium", "large": "large",
              "xlarge": "xlarge"},
    "classification": {
        # What the keyword and length heuristics look at:
        #   last_user    -- the newest user message only (default). A system
        #                   prompt or an old turn can no longer pin every
        #                   request of a conversation to one tier.
        #   conversation -- every message, the pre-2026-09 behaviour.
        "scope": "last_user",
        # true: a request carrying an image fails with HTTP 400 when no
        # discovered model looks vision-capable. false: route it anyway and
        # flag it with an X-Router-Warning header.
        "vision_strict": "false",
        # Requests that carry tools (agents, function calling) are raised to at
        # least this class: small models are poor at tool use. Blank: no floor.
        # A tier alias named by the client still pins the class.
        "tools_min_class": "large",
        # true: a tool request fails with HTTP 400 when every discovered model
        # is known to lack tool support. false: route it anyway, flagged with
        # an X-Router-Warning header.
        "tools_strict": "false",
        # Server kinds listed at /v1/models whose text models are reported
        # tool-capable. Their APIs say nothing per model, but each of these
        # servers parses "tools" and returns OpenAI tool_calls. A kind left
        # out is reported unknown. Blank: none.
        "tool_kinds": "strata, basalt, maya, xolotl, avalon, kindi, colibri",
    },
    "http": {
        # Seconds to establish a TCP connection to a backend. Short on purpose:
        # this is how long a dead host delays failover to the next candidate.
        "connect_timeout_seconds": "3",
        # Seconds allowed between bytes of a response (generation can be slow).
        "read_timeout_seconds": "300",
        # The same for Kindi, which serves one request at a time and reads a
        # long prompt slowly on a small card (its agent guide: 30-60 minutes).
        # Never below read_timeout_seconds.
        "kindi_read_timeout_seconds": "3600",
    },
    "images": {
        # The model name that asks for any image server that is up (Open WebUI
        # is set to it). A name of a model listed by GET /v1/images/models
        # asks for that one.
        "alias": "image",
        # Server kinds the alias tries first, in order: a ComfyUI CT has a GPU
        # for its diffusion model; Colibri draws on a Vulkan GPU or the CPU.
        "prefer": "comfyui, colibri",
        # Seconds one picture may take (a CPU takes minutes). Never below
        # read_timeout_seconds.
        "read_timeout_seconds": "900",
        # How often a ComfyUI job is polled for its result.
        "comfyui_poll_seconds": "1",
        # The most images one request may ask for (n); each is drawn in turn.
        "max_n": "4",
    },
    "discovery": {
        "enabled": "true",
        "refresh_seconds": "60",
        "timeout_seconds": "5",
        # Comma-separated Ollama base URLs. Blank -> derive from BACKEND_* env.
        "servers": "",
        # Ask each server's /api/show for a model's real capabilities (vision,
        # embedding). Name matching below is the fallback.
        "capability_probe": "true",
        # How long an /api/show answer is kept for a model the server lists
        # with a digest (see SHOW_CACHE_SECONDS below).
        "show_cache_seconds": "3600",
        # LM Studio servers (MODEL_SERVERS entries written lmstudio+http://...)
        # load models on demand. true: only route to models already loaded
        # there (no multi-second JIT load on the request path).
        "lmstudio_loaded_only": "false",
        # LM Studio reports each loaded instance's parallel (Max Concurrent
        # Predictions) but not its Unified KV Cache setting. false: one
        # request gets context_length / parallel, each slot's share with the
        # setting off. true: every LM Studio host loads with it on, so one
        # request may use the whole context_length.
        "lmstudio_unified_kv": "false",
        # Parameter-count bands (in billions) each request class prefers.
        "fast_params": "0:9",
        "medium_params": "9:20",
        "large_params": "20:70",
        "xlarge_params": "70:999",
        # How quickly score decays per billion parameters outside the band.
        "band_falloff": "12",
        # Substrings marking a model as code-specialised / vision / embedding.
        "code_models": json.dumps(["coder", "code", "starcoder", "codellama",
                                   "deepseek-coder", "codegemma", "codestral"]),
        "vision_models": json.dumps(["llava", "vision", "-vl", "minicpm-v",
                                     "moondream", "bakllava"]),
        "embedding_models": json.dumps(["embed", "embedding", "bge-", "gte-",
                                        "nomic-embed", "mxbai-embed"]),
        "vision_families": json.dumps(["clip", "mllama", "llava"]),
        "embedding_families": json.dumps(["bert", "nomic-bert"]),
    },
    "weights": {
        "band_fit": "1.0",
        "code_match": "0.6",
        "vision_match": "1.5",
        "prefer_larger": "0.15",
        "prefer_smaller": "0.15",
        "unknown_params": "0.3",
        # Fraction of the specialist weight applied as a penalty when a
        # specialised model (code/vision) is used for an off-task request.
        "offtask_penalty": "0.25",
        # Candidates within this score of the best are treated as equivalent and
        # rotated through, so identical models on several hosts share load.
        "tie_epsilon": "0.05",
        # Bonus for a model that is already resident in memory (LM Studio and
        # the Strata-style servers report it per model, Ollama through /api/ps).
        "loaded_bonus": "0.1",
        # Bonus, on a tool request, for a model the server reports as
        # tool-capable over one whose tool support is unknown.
        "tool_match": "0.3",
        # Bonus for a model assigned to the requested tier in
        # litellm_config.yaml (manage-model-servers set-model / add-model).
        "tier_member": "0.2",
    },
    # How load is spread once the scores have been compared.
    "balancing": {
        # Taken off a candidate's score for each request this router has in
        # flight on its server. 0 turns load awareness off.
        "busy_penalty": "0.03",
        # How long a conversation prefers the server and model that answered
        # it last, among equally good candidates. 0 turns it off.
        "sticky_seconds": "1800",
        # Models assigned to a tier are that tier's models whatever their size,
        # and requests of that class are spread across all of them.
        "tier_models": "true",
        # Where the tier assignments are read from. Blank: litellm_config.yaml
        # next to router.ini.
        "tier_config": "",
    },
    # Sizes for exact model ids that an OpenAI-compatible server (Strata,
    # Basalt, Maya, Xolotl, Avalon, Colibri) lists without a parameter count. Matching is by the whole
    # id, case-insensitive, so variants and aliases stay unknown-size unless
    # given a line of their own. A blank value removes a built-in entry.
    "model_sizes": {
        "strata": "125B",               # Strata's default id: Qwen3.8-Flash-Next
        "qwen3.8-flash-next": "125B",   # Basalt's default alias
        # Strata's qwen family ids, qwen3.8-flash-next-<quant>: one 125B model.
        "qwen3.8-flash-next-q2_0": "125B",
        "qwen3.8-flash-next-iq2_xs": "125B",
        "qwen3.8-flash-next-iq3_xxs": "125B",
        "qwen3.8-flash-next-iq3_s": "125B",
        "glm-5.3-flash": "321B",        # Project Maya (GLM-5.3-Flash, 321B total)
        "deepseek-v4.1-flash": "552B",  # Xolotl's default id (DeepSeek-V4.1-Flash, 552B total)
        "qwen3.8-flash-next-avalon": "125B",  # Avalon's default alias (Qwen3.8-Flash-Next)
        # Colibri's ids for the models whose id gives no size (its family
        # registry's display scale; ids such as qwen3-coder-30b-a3b-colibri
        # name theirs). Qwen3.8-Flash-Next counts 125B as for Strata and Avalon.
        "glm-5.3-flash-colibri": "321B",
        "glm-5.2-colibri": "744B",
        "mistral-large-4-colibri": "1000B",
        "inkling-colibri": "975B",
        "kimi-k3-colibri": "2800B",
        "olmoe-colibri": "7B",
        "qwen3.6-colibri": "35B",
        "qwen3.8-flash-next-colibri": "125B",
        "flint-colibri": "40B",
        "muse-spark-open-colibri": "816B",
        "deepseek-v4-colibri": "284B",
        "deepseek-v4.1-flash-colibri": "552B",
        "mimo-v2.6-flash": "309B",
        "mimo-v2.6-pro": "1020B",
    },
}
ROUTER_INI = os.getenv(
    "ROUTER_INI",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "router.ini"),
)


def _load_config(path: str) -> configparser.ConfigParser:
    cp = configparser.ConfigParser()
    cp.read_dict(_DEFAULTS)
    if os.path.exists(path):
        cp.read(path)
    return cp


def _json_list(cp: configparser.ConfigParser, section: str, option: str) -> list:
    # JSON array keeps exact spacing ("def " must not match "default").
    raw = cp.get(section, option)

    def norm(k):
        k = str(k)
        # Regex entries keep their case: lowering "\S" would turn it into "\s".
        return k if k.startswith("re:") else k.lower()
    try:
        return [norm(k) for k in json.loads(raw)]
    except (ValueError, TypeError):
        return [norm(k.strip()) for k in raw.split(",") if k.strip()]


def keyword_pattern(keywords: list):
    """Compile keywords into one case-insensitive, word-bounded regex.

    Plain substring matching misrouted ordinary prose: "script" matched
    "description"/"subscription", "code" matched "encode", "prove" matched
    "improve". Each keyword now has to start at a word boundary and end at one,
    allowing only a simple plural/past suffix ("bugs", "compiled"). A keyword
    written with a trailing space ("def ") must be followed by whitespace,
    preserving the old meaning of that convention. Spaces inside a phrase match
    any run of whitespace. An entry starting with "re:" is a regular expression
    (matched case-insensitively), for code shapes such as "class Foo:".
    """
    parts = []
    for raw in keywords:
        word = str(raw)
        if word.startswith("re:"):
            # A regular expression, for shapes a word list cannot express
            # (e.g. "class Foo:" as code but not "first class ticket").
            try:
                re.compile(word[3:])
            except re.error as exc:
                log.warning("ignoring invalid keyword regex %r: %s", raw, exc)
                continue
            parts.append("(?:%s)" % word[3:])
            continue
        word = word.lower()
        core = word.strip()
        if not core:
            continue
        body = r"\s+".join(re.escape(piece) for piece in core.split())
        tail = r"\s" if word.endswith(" ") else r"(?:s|es|d|ed)?(?![\w])"
        parts.append(r"(?<![\w])" + body + tail)
    if not parts:
        return None
    return re.compile("|".join(parts), re.IGNORECASE | re.MULTILINE)


def matches_keywords(pattern, text: str) -> bool:
    return bool(pattern and pattern.search(text))


def _band(cp: configparser.ConfigParser, option: str) -> tuple:
    raw = cp.get("discovery", option)
    try:
        low, high = raw.split(":", 1)
        return (float(low), float(high))
    except (ValueError, AttributeError):
        return (0.0, 999.0)


_cfg = _load_config(ROUTER_INI)
TOKEN_THRESHOLD_XLARGE = _cfg.getint("thresholds", "xlarge")
TOKEN_THRESHOLD_LARGE = _cfg.getint("thresholds", "large")
TOKEN_THRESHOLD_MEDIUM = _cfg.getint("thresholds", "medium")
CODE_FIRST = _cfg.getboolean("keywords", "code_first")
CODE_KEYWORDS = _json_list(_cfg, "keywords", "code")
LARGE_KEYWORDS = _json_list(_cfg, "keywords", "large")
XLARGE_KEYWORDS = _json_list(_cfg, "keywords", "xlarge")
CODE_RE = keyword_pattern(CODE_KEYWORDS)
LARGE_RE = keyword_pattern(LARGE_KEYWORDS)
XLARGE_RE = keyword_pattern(XLARGE_KEYWORDS)
TIER_FAST = _cfg.get("tiers", "fast")
TIER_MEDIUM = _cfg.get("tiers", "medium")
TIER_LARGE = _cfg.get("tiers", "large")
TIER_XLARGE = _cfg.get("tiers", "xlarge")
TIER_NAMES = {TIER_FAST: "fast", TIER_MEDIUM: "medium", TIER_LARGE: "large",
              TIER_XLARGE: "xlarge"}

# Cloud models are explicit choices. They are never mixed into local discovery
# or automatic routing, which could otherwise incur API charges unexpectedly.
CLOUD_PROVIDERS = {
    "openai": "OPENAI_API_KEY",
    "anthropic": "ANTHROPIC_API_KEY",
    "gemini": "GEMINI_API_KEY",
}
CLOUD_MODELS = {
    f"{provider}/{model.strip()}": provider
    for provider, key in CLOUD_PROVIDERS.items()
    if (os.getenv(key) or "").strip()
    for model in (os.getenv(f"CLOUD_{provider.upper()}_MODELS") or "").split(",")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", model.strip())
}

# --- image generation -------------------------------------------------------------
# POST /v1/images/generations goes to an image server the router knows:
#   * a /v1/models server whose entry declares "capabilities":
#     ["image_generation"] (Colibri serving Qwen-Image), sent the request as is;
#   * a ComfyUI CT (COMFYUI_SERVERS, set with manage-model-servers set-comfyui),
#     sent the FLUX.2 Klein workflow of targets/comfyui with the prompt, size,
#     steps and seed filled in, then polled for the picture.
# The alias ([images] alias) picks one that is up, [images] prefer first, the
# least busy next, and fails forward. Cloud image models (openai/gpt-image-1,
# gemini/imagen-...) go to LiteLLM, and only when a request names them.
IMAGE_KINDS = ("comfyui", "colibri")
CLOUD_IMAGE_NAME = re.compile(r"(?:^|/)(dall-e|gpt-image|imagen)", re.I)


def is_cloud_image_model(name: str) -> bool:
    return name in CLOUD_MODELS and bool(CLOUD_IMAGE_NAME.search(name))


def _root_urls(value: str) -> list:
    """Comma-separated http(s) root URLs, in order, without repeats."""
    seen, out = set(), []
    for url in (value or "").split(","):
        url = url.strip().rstrip("/")
        try:
            parts = urlsplit(url)
            ok = (parts.scheme in ("http", "https") and bool(parts.hostname)
                  and not (parts.path or parts.query or parts.fragment
                           or parts.username or parts.password))
        except ValueError:
            ok = False
        if url and not ok:
            log.error("ignoring image server %r: use a root URL such as http://10.0.0.30:8188", url)
            continue
        if url and url not in seen:
            seen.add(url)
            out.append(url)
    return out


COMFYUI_SERVERS = _root_urls(os.getenv("COMFYUI_SERVERS", ""))
# FLUX.2 Klein as targets/comfyui installs it (klein-weights.txt) and
# describes it (flux2-klein-{4b,9b}-api.json; tests/test_router.py checks these
# copies match). Node 4 takes the prompt, 6 and 7 the size, 6 the batch, 7 the
# steps, 8 the seed. A variant is offered when ComfyUI lists its three files.
COMFYUI_VARIANTS = {
    "flux2-klein-4b": {
        "files": {"unet_name": "flux-2-klein-4b-fp8.safetensors",
                  "clip_name": "qwen_3_4b.safetensors",
                  "vae_name": "flux2-vae.safetensors"},
        "workflow": {
            "1": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux-2-klein-4b-fp8.safetensors", "weight_dtype": "default"}},
            "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen_3_4b.safetensors", "type": "flux2", "device": "default"}},
            "3": {"class_type": "VAELoader", "inputs": {"vae_name": "flux2-vae.safetensors"}},
            "4": {"class_type": "CLIPTextEncode", "inputs": {"text": "Prompt", "clip": ["2", 0]}},
            "5": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["4", 0]}},
            "6": {"class_type": "EmptyFlux2LatentImage", "inputs": {"width": 1024, "height": 1024, "batch_size": 1}},
            "7": {"class_type": "Flux2Scheduler", "inputs": {"steps": 4, "width": 1024, "height": 1024}},
            "8": {"class_type": "RandomNoise", "inputs": {"noise_seed": 0}},
            "9": {"class_type": "CFGGuider", "inputs": {"cfg": 1.0, "model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0]}},
            "10": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
            "11": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["8", 0], "guider": ["9", 0], "sampler": ["10", 0], "sigmas": ["7", 0], "latent_image": ["6", 0]}},
            "12": {"class_type": "VAEDecode", "inputs": {"samples": ["11", 0], "vae": ["3", 0]}},
            "13": {"class_type": "SaveImage", "inputs": {"filename_prefix": "Flux2-Klein", "images": ["12", 0]}},
        },
    },
    "flux2-klein-9b": {
        "files": {"unet_name": "flux-2-klein-9b-fp8.safetensors",
                  "clip_name": "qwen_3_8b_fp8mixed.safetensors",
                  "vae_name": "flux2-vae.safetensors"},
        "workflow": {
            "1": {"class_type": "UNETLoader", "inputs": {"unet_name": "flux-2-klein-9b-fp8.safetensors", "weight_dtype": "default"}},
            "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen_3_8b_fp8mixed.safetensors", "type": "flux2", "device": "default"}},
            "3": {"class_type": "VAELoader", "inputs": {"vae_name": "flux2-vae.safetensors"}},
            "4": {"class_type": "CLIPTextEncode", "inputs": {"text": "Prompt", "clip": ["2", 0]}},
            "5": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["4", 0]}},
            "6": {"class_type": "EmptyFlux2LatentImage", "inputs": {"width": 1024, "height": 1024, "batch_size": 1}},
            "7": {"class_type": "Flux2Scheduler", "inputs": {"steps": 4, "width": 1024, "height": 1024}},
            "8": {"class_type": "RandomNoise", "inputs": {"noise_seed": 0}},
            "9": {"class_type": "CFGGuider", "inputs": {"cfg": 1.0, "model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0]}},
            "10": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
            "11": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["8", 0], "guider": ["9", 0], "sampler": ["10", 0], "sigmas": ["7", 0], "latent_image": ["6", 0]}},
            "12": {"class_type": "VAEDecode", "inputs": {"samples": ["11", 0], "vae": ["3", 0]}},
            "13": {"class_type": "SaveImage", "inputs": {"filename_prefix": "Flux2-Klein", "images": ["12", 0]}},
        },
    },
}
COMFYUI_LOADERS = (("UNETLoader", "unet_name"), ("CLIPLoader", "clip_name"), ("VAELoader", "vae_name"))

# FreeLLMAPI (targets/freellmapi) fronts the free tiers of cloud providers with
# one OpenAI-compatible endpoint and one key. Like the cloud models above it is
# an explicit choice: a request must name freellmapi/<id> (freellmapi/auto lets
# FreeLLMAPI pick), and it is never part of local discovery, "auto", the tier
# aliases or LiteLLM's fallbacks. Its prompts leave the network.
FREELLMAPI_PREFIX = "freellmapi/"
FREELLMAPI_BASE = (os.getenv("FREELLMAPI_BASE_URL") or "").strip().rstrip("/")
FREELLMAPI_KEY = (os.getenv("FREELLMAPI_API_KEY") or "").strip()
if FREELLMAPI_BASE:
    try:
        _freellmapi_url = urlsplit(FREELLMAPI_BASE)
        _freellmapi_ok = (_freellmapi_url.scheme in ("http", "https")
                          and bool(_freellmapi_url.hostname)
                          and not (_freellmapi_url.username or _freellmapi_url.password
                                   or _freellmapi_url.path or _freellmapi_url.query
                                   or _freellmapi_url.fragment))
        _freellmapi_url.port  # noqa: B018 - raises on a bad port
    except ValueError:
        _freellmapi_ok = False
    if not _freellmapi_ok:
        log.warning("ignoring FREELLMAPI_BASE_URL: use the root URL, e.g. http://10.0.0.20:3001")
        FREELLMAPI_BASE = ""
FREELLMAPI_ENABLED = bool(FREELLMAPI_BASE and FREELLMAPI_KEY)
if FREELLMAPI_BASE and not FREELLMAPI_KEY:
    log.warning("FREELLMAPI_BASE_URL is set without FREELLMAPI_API_KEY; freellmapi/ models are off")
# available: list every model FreeLLMAPI can serve now; auto: only its own
# routing entries (freellmapi/auto and the like).
FREELLMAPI_MODELS = (os.getenv("FREELLMAPI_MODELS") or "available").strip().lower()
if FREELLMAPI_MODELS not in ("available", "auto"):
    log.warning("ignoring FREELLMAPI_MODELS=%r (use available or auto)", FREELLMAPI_MODELS)
    FREELLMAPI_MODELS = "available"
FREELLMAPI_REFRESH = 300.0
_FREELLMAPI_LIST = {"at": 0.0, "ids": ["auto"]}
_FREELLMAPI_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:@/+-]{0,199}")


def freellmapi_headers() -> dict:
    return {"Authorization": f"Bearer {FREELLMAPI_KEY}"}


async def freellmapi_models() -> list:
    """Model ids FreeLLMAPI serves now, without the prefix, refreshed at most
    every FREELLMAPI_REFRESH seconds. "auto" is always first, so the entry
    stays selectable while FreeLLMAPI is down or has no provider key yet; a
    failed refresh keeps the previous list."""
    now = time.monotonic()
    if _FREELLMAPI_LIST["at"] and now - _FREELLMAPI_LIST["at"] < FREELLMAPI_REFRESH:
        return _FREELLMAPI_LIST["ids"]
    _FREELLMAPI_LIST["at"] = now
    try:
        response = await http_client().get(
            f"{FREELLMAPI_BASE}/v1/models", params={"available": "true"},
            headers=freellmapi_headers(), timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        ids = ["auto"]
        for entry in (response.json().get("data") or []):
            name = str(entry.get("id") or "")
            if not _FREELLMAPI_ID.fullmatch(name) or name in ids:
                continue
            if entry.get("available") is False:
                continue
            # FreeLLMAPI's own routing entries carry owned_by "freellmapi".
            if FREELLMAPI_MODELS == "auto" and entry.get("owned_by") != "freellmapi":
                continue
            ids.append(name)
        _FREELLMAPI_LIST["ids"] = ids
    except Exception as exc:  # noqa: BLE001 - the model list must still be served
        log.warning("freellmapi: model list unavailable (%s)", exc)
    return _FREELLMAPI_LIST["ids"]

DISCOVERY_ENABLED = _cfg.getboolean("discovery", "enabled")
DISCOVERY_REFRESH = _cfg.getint("discovery", "refresh_seconds")
DISCOVERY_TIMEOUT = _cfg.getfloat("discovery", "timeout_seconds")
CAPABILITY_PROBE = _cfg.getboolean("discovery", "capability_probe")
LMSTUDIO_LOADED_ONLY = _cfg.getboolean("discovery", "lmstudio_loaded_only")
LMSTUDIO_UNIFIED_KV = _cfg.getboolean("discovery", "lmstudio_unified_kv")


def _model_sizes(cp: configparser.ConfigParser) -> dict:
    """[model_sizes] as {lowercase id: size}, blank entries dropped. The
    per-kind keys of earlier router.ini files ([discovery]
    strata_default_params, basalt_/maya_default_id + _params) still apply when
    a committed router.ini sets them."""
    sizes = {k.strip().lower(): v.strip() for k, v in cp.items("model_sizes")}
    if cp.has_option("discovery", "strata_default_params"):
        sizes["strata"] = cp.get("discovery", "strata_default_params").strip()
    for kind in ("basalt", "maya"):
        id_key, size_key = f"{kind}_default_id", f"{kind}_default_params"
        if cp.has_option("discovery", id_key) and cp.has_option("discovery", size_key):
            sizes[cp.get("discovery", id_key).strip().lower()] = \
                cp.get("discovery", size_key).strip()
    return {k: v for k, v in sizes.items() if k and v}


MODEL_SIZES = _model_sizes(_cfg)
BANDS = {
    "fast": _band(_cfg, "fast_params"),
    "medium": _band(_cfg, "medium_params"),
    "large": _band(_cfg, "large_params"),
    "xlarge": _band(_cfg, "xlarge_params"),
}
# Highest ceiling across all bands — the one band whose upper bound stays
# inclusive, so a model above every other band still scores a perfect fit.
TOP_BAND_HIGH = max(high for _, high in BANDS.values())
BAND_FALLOFF = _cfg.getfloat("discovery", "band_falloff")
CODE_MODELS = _json_list(_cfg, "discovery", "code_models")
VISION_MODELS = _json_list(_cfg, "discovery", "vision_models")
EMBEDDING_MODELS = _json_list(_cfg, "discovery", "embedding_models")
VISION_FAMILIES = _json_list(_cfg, "discovery", "vision_families")
EMBEDDING_FAMILIES = _json_list(_cfg, "discovery", "embedding_families")

W_BAND = _cfg.getfloat("weights", "band_fit")
W_CODE = _cfg.getfloat("weights", "code_match")
W_VISION = _cfg.getfloat("weights", "vision_match")
W_LARGER = _cfg.getfloat("weights", "prefer_larger")
W_SMALLER = _cfg.getfloat("weights", "prefer_smaller")
W_UNKNOWN = _cfg.getfloat("weights", "unknown_params")
W_OFFTASK = _cfg.getfloat("weights", "offtask_penalty")
TIE_EPSILON = _cfg.getfloat("weights", "tie_epsilon")
W_LOADED = _cfg.getfloat("weights", "loaded_bonus")
W_TOOLS = _cfg.getfloat("weights", "tool_match")
W_TIER_MEMBER = max(0.0, _cfg.getfloat("weights", "tier_member"))
BUSY_PENALTY = max(0.0, _cfg.getfloat("balancing", "busy_penalty"))
STICKY_SECONDS = max(0.0, _cfg.getfloat("balancing", "sticky_seconds"))
TIER_MODELS_ENABLED = _cfg.getboolean("balancing", "tier_models")
TIER_CONFIG = (_cfg.get("balancing", "tier_config").strip()
               or os.path.join(os.path.dirname(os.path.abspath(ROUTER_INI)), "litellm_config.yaml"))

# --- server kinds -----------------------------------------------------------------
# A server entry is a base URL. Entries for servers that are not Ollama carry a
# kind prefix (lmstudio+http://host:1234, maya+http://host:8080, ...), so
# MODEL_SERVERS / BACKEND_* can mix APIs. This table is the one place a kind is
# described; monitor.py and manage-model-servers.sh keep matching tables, and
# tests/test_router.py checks that all three agree.
#   prefix   -- the entry prefix
#   key_env  -- the secrets.env variable holding the router's bearer token
#   label    -- the name used in logs and alerts
#   openai   -- models are listed at <base>/v1/models (Strata-style servers)
SERVER_KINDS = {
    "lmstudio": {"prefix": "lmstudio+", "key_env": "LMSTUDIO_API_TOKEN",
                 "label": "LM Studio", "openai": False},
    "strata": {"prefix": "strata+", "key_env": "STRATA_API_KEY",
               "label": "Strata", "openai": True},
    "basalt": {"prefix": "basalt+", "key_env": "BASALT_API_KEY",
               "label": "Basalt", "openai": True},
    "maya": {"prefix": "maya+", "key_env": "MAYA_API_KEY",
             "label": "Maya", "openai": True},
    "xolotl": {"prefix": "xolotl+", "key_env": "XOLOTL_API_KEY",
               "label": "Xolotl", "openai": True},
    "avalon": {"prefix": "avalon+", "key_env": "AVALON_API_KEY",
               "label": "Avalon", "openai": True},
    "kindi": {"prefix": "kindi+", "key_env": "KINDI_API_KEY",
              "label": "Kindi", "openai": True},
    "colibri": {"prefix": "colibri+", "key_env": "COLIBRI_API_KEY",
                "label": "Colibri", "openai": True},
}
OPENAI_KINDS = frozenset(k for k, v in SERVER_KINDS.items() if v["openai"])
# Capabilities a /v1/models entry can declare (Colibri's "capabilities") that
# mean it answers no chat: an image generator or a decision model. Such an
# entry is not offered for chat at all.
NON_CHAT_CAPABILITIES = frozenset({"image_generation", "decision"})
# Models of a tool kind whose engine takes no tools: Colibri parses tools on
# every chat engine except Inkling and OLMoE. Their tool support is unknown.
NO_TOOL_MODELS = {"colibri": frozenset({"inkling-colibri", "olmoe-colibri"})}
# Bearer tokens the router adds per kind (secrets.env). LM Studio's is for
# servers with "Require authentication" (0.4+).
KIND_KEYS = {kind: (os.getenv(spec["key_env"]) or "").strip()
             for kind, spec in SERVER_KINDS.items()}


def server_kind(server: str) -> str:
    for kind, spec in SERVER_KINDS.items():
        if server.startswith(spec["prefix"]):
            return kind
    return "ollama"


def server_base(server: str) -> str:
    """The plain http(s) base URL of a server entry."""
    kind = server_kind(server)
    return server.removeprefix(SERVER_KINDS[kind]["prefix"]) if kind != "ollama" else server


def backend_headers(server: str) -> dict:
    """Credentials the ROUTER adds for a backend (never the client's own)."""
    token = KIND_KEYS.get(server_kind(server), "")
    if token:
        return {"Authorization": f"Bearer {token}"}
    return {}


CLASSIFY_SCOPE = _cfg.get("classification", "scope").strip().lower()
VISION_STRICT = _cfg.getboolean("classification", "vision_strict")
CLASS_ORDER = ("fast", "medium", "large", "xlarge")
TOOLS_MIN_CLASS = _cfg.get("classification", "tools_min_class").strip().lower()
if TOOLS_MIN_CLASS and TOOLS_MIN_CLASS not in CLASS_ORDER:
    log.warning("ignoring [classification] tools_min_class = %r (use one of %s, "
                "or blank)", TOOLS_MIN_CLASS, ", ".join(CLASS_ORDER))
    TOOLS_MIN_CLASS = ""
TOOLS_STRICT = _cfg.getboolean("classification", "tools_strict")
TOOL_KINDS = frozenset(k for k in _json_list(_cfg, "classification", "tool_kinds")
                       if k in OPENAI_KINDS)
for _kind in sorted(set(_json_list(_cfg, "classification", "tool_kinds")) - TOOL_KINDS):
    log.warning("ignoring [classification] tool_kinds entry %r (use %s)",
                _kind, ", ".join(sorted(OPENAI_KINDS)))
CONNECT_TIMEOUT = _cfg.getfloat("http", "connect_timeout_seconds")
READ_TIMEOUT = _cfg.getfloat("http", "read_timeout_seconds")
KINDI_READ_TIMEOUT = max(READ_TIMEOUT, _cfg.getfloat("http", "kindi_read_timeout_seconds"))
IMAGE_ALIAS = _cfg.get("images", "alias").strip() or "image"
IMAGE_READ_TIMEOUT = max(READ_TIMEOUT, _cfg.getfloat("images", "read_timeout_seconds"))
IMAGE_PREFER = [k for k in _json_list(_cfg, "images", "prefer") if k in IMAGE_KINDS]
COMFYUI_POLL_SECONDS = max(0.2, _cfg.getfloat("images", "comfyui_poll_seconds"))
IMAGE_MAX_N = max(1, _cfg.getint("images", "max_n"))

# Request headers never forwarded upstream.
HOP_BY_HOP = {"host", "content-length", "connection", "keep-alive",
              "transfer-encoding", "upgrade", "proxy-connection", "te",
              "trailer", "proxy-authorization", "proxy-authenticate"}
# Response headers never copied onto our own (re-framed) streaming response.
# The body is re-chunked by the ASGI server, so the upstream framing headers
# would contradict what is actually sent. content-encoding is kept because the
# raw (still-encoded) bytes are passed through unchanged.
RESPONSE_HOP_BY_HOP = HOP_BY_HOP | {"date", "server"}

# Optional bearer token. When set, every endpoint except /healthz requires
# "Authorization: Bearer <key>". Lives in /app/router/secrets.env.
ROUTER_API_KEY = (os.getenv("ROUTER_API_KEY") or "").strip()
ROUTER_HOST = os.getenv("ROUTER_HOST", "0.0.0.0")
ROUTER_PORT = int(os.getenv("ROUTER_PORT", "8000"))


# Historical names for each tier's backend env key, newest first. The keys
# dropped their QWEN_ infix when the router stopped being Qwen-specific, and
# "heavy" was then renamed "large" when the xlarge tier was added. A service
# can start against a router.env that manage-model-servers.sh has not migrated
# yet -- without these fallbacks such a start looks healthy while resolving no
# backends at all.
_TIER_ENV_ALIASES = {
    "fast": ("BACKEND_FAST", "BACKEND_QWEN_FAST"),
    "medium": ("BACKEND_MEDIUM", "BACKEND_QWEN_MEDIUM"),
    "large": ("BACKEND_LARGE", "BACKEND_HEAVY", "BACKEND_QWEN_HEAVY"),
    "xlarge": ("BACKEND_XLARGE",),
}


def _tier_env(tier: str) -> str:
    for name in _TIER_ENV_ALIASES.get(tier, ("BACKEND_%s" % tier.upper(),)):
        value = os.getenv(name)
        if value:
            return value
    return ""


def _discovery_servers() -> list:
    """Model server entries to poll, in order of preference:
      1. an explicit list in router.ini
      2. MODEL_SERVERS - every configured host, including any not assigned to a
         tier (those are absent from BACKEND_*, so relying on those alone would
         leave such a host permanently undiscovered)
      3. the per-tier BACKEND_* vars, as a fallback for older env files."""
    def _split(value: str) -> list:
        seen, out = set(), []
        for url in (value or "").split(","):
            url = url.strip().rstrip("/")
            if url and url not in seen:
                seen.add(url)
                out.append(url)
        return out

    configured = _cfg.get("discovery", "servers").strip()
    if configured:
        return _split(configured)
    every_host = _split(os.getenv("MODEL_SERVERS", ""))
    if every_host:
        return every_host
    return _split(",".join(
        _tier_env(t) for t in ("fast", "medium", "large", "xlarge")))


SERVERS = _discovery_servers()


def litellm_read_timeout(tier: str | None = None) -> float:
    """Read gap for this LiteLLM request; passthrough keeps the normal limit."""
    return KINDI_READ_TIMEOUT if tier and tier_has_kindi(tier) else READ_TIMEOUT


def tier_has_kindi(tier: str) -> bool:
    """Whether LiteLLM can select a Kindi deployment for this tier."""
    return any(server_kind(entry.strip()) == "kindi"
               for entry in _tier_env(tier).split(",") if entry.strip())


# --- live inventory -----------------------------------------------------------
# Replaced wholesale on each refresh, so readers never see a half-built dict.
INVENTORY = {"models": [], "images": [], "servers": {}, "updated_at": 0.0, "errors": {}}
_rotation = {}

# --- tier assignments -----------------------------------------------------------
# class -> model names assigned to that tier, from the model_list that
# manage-model-servers writes to litellm_config.yaml (one deployment per tier,
# server and model). Names are lower-cased, without a ":latest" suffix. Read
# again whenever the file changes (checked on each discovery refresh), so a
# set-model / add-model needs no router restart.
TIER_MEMBERS = {}
_TIER_CONFIG_STATE = {"mtime": None, "read": False}
_YAML_ITEM = re.compile(r"^(\s*)-\s+(.*)$")
_YAML_FIELD = re.compile(r"^\s*(model_name|model)\s*:\s*(.*?)\s*$")


def _model_key(name: str) -> str:
    """How tier names and inventory names are compared: case-insensitive, and
    Ollama's implicit ":latest" tag is the same model as no tag."""
    name = (name or "").strip().lower()
    return name[:-len(":latest")] if name.endswith(":latest") else name


def _yaml_scalar(value: str) -> str:
    value = re.sub(r"\s+#.*$", "", value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    return value.strip()


def parse_tier_models(text: str) -> dict:
    """class -> {model key} from litellm_config.yaml's model_list.

    Only deployments whose model_name is a tier alias count (cloud models are
    named after themselves). The model is litellm_params.model without its
    provider prefix: ollama/qwen3:14b -> qwen3:14b, openai/glm-5.3-flash ->
    glm-5.3-flash, lm_studio/qwen/qwen3-14b -> qwen/qwen3-14b. The file is
    generated, so a small line reader does; a line it does not understand is
    skipped rather than failing the router."""
    members, item, in_list, item_indent = {}, None, False, None

    def flush():
        if item and item.get("model_name") in TIER_NAMES and "/" in item.get("model", ""):
            tag = _model_key(item["model"].split("/", 1)[1])
            if tag:
                members.setdefault(TIER_NAMES[item["model_name"]], set()).add(tag)

    for line in (text or "").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace() and not (in_list and line.startswith("-")):
            flush()
            item, item_indent = None, None
            in_list = line.split("#", 1)[0].strip() == "model_list:"
            continue
        if not in_list:
            continue
        start = _YAML_ITEM.match(line)
        if start and (item_indent is None or len(start.group(1)) <= item_indent):
            flush()
            item, item_indent = {}, len(start.group(1))
            line = start.group(1) + "  " + start.group(2)
        field = _YAML_FIELD.match(line)
        if field and item is not None and field.group(1) not in item:
            item[field.group(1)] = _yaml_scalar(field.group(2))
    flush()
    return members


def load_tier_models(force: bool = False) -> dict:
    """Read the tier assignments again if litellm_config.yaml changed."""
    global TIER_MEMBERS
    if not TIER_MODELS_ENABLED:
        TIER_MEMBERS = {}
        return TIER_MEMBERS
    try:
        mtime = os.stat(TIER_CONFIG).st_mtime_ns
    except OSError:
        mtime = None
    if not force and _TIER_CONFIG_STATE["read"] and mtime == _TIER_CONFIG_STATE["mtime"]:
        return TIER_MEMBERS
    members = {}
    if mtime is not None:
        try:
            with open(TIER_CONFIG, encoding="utf-8") as handle:
                members = parse_tier_models(handle.read())
        except (OSError, UnicodeDecodeError) as exc:
            log.warning("tier models: cannot read %s (%s); sizes alone decide", TIER_CONFIG, exc)
    _TIER_CONFIG_STATE.update(mtime=mtime, read=True)
    if members != TIER_MEMBERS:
        log.info("tier models: %s", "; ".join(
            "%s=%s" % (cls, ",".join(sorted(members[cls])))
            for cls in CLASS_ORDER if cls in members) or "none assigned")
    TIER_MEMBERS = members
    return TIER_MEMBERS


def tier_classes(entry: dict) -> list:
    """The classes whose tier this model is assigned to, in class order."""
    key = _model_key(entry.get("name", ""))
    return [cls for cls in CLASS_ORDER if key in TIER_MEMBERS.get(cls, ())]


def is_tier_member(entry: dict, need: dict) -> bool:
    """Is this model assigned to the tier of the requested class?"""
    return _model_key(entry.get("name", "")) in TIER_MEMBERS.get(need.get("class"), ())


load_tier_models()

# --- load and conversation affinity -------------------------------------------
# server -> requests this router has sent there and not yet seen finish. Only
# its own traffic: what the agents' dispatchers or other clients send a server
# directly is not seen.
_IN_FLIGHT = {}


class InFlight:
    """One request counted against a server from the moment it is sent until
    release(): when its body has been relayed, it failed, or the client left.
    release() may be called more than once, and a forgotten one is released
    when it is collected, so a lost count cannot weigh on a server for good."""

    __slots__ = ("server", "open", "streaming")

    def __init__(self, server: str):
        self.server, self.open, self.streaming = server, True, False
        _IN_FLIGHT[server] = _IN_FLIGHT.get(server, 0) + 1

    def release(self) -> None:
        if not self.open:
            return
        self.open = False
        left = _IN_FLIGHT.get(self.server, 0) - 1
        if left > 0:
            _IN_FLIGHT[self.server] = left
        else:
            _IN_FLIGHT.pop(self.server, None)

    def __del__(self):
        self.release()


def in_flight(server: str) -> int:
    """Requests in flight on a server, as far as load awareness is on."""
    return _IN_FLIGHT.get(server, 0) if BUSY_PENALTY > 0 else 0


# conversation key -> (server, model, time of its last answer), oldest first.
_STICKY = OrderedDict()
STICKY_MAX = 4096


def conversation_keys(messages) -> list:
    """Fingerprints of how a conversation began, most specific first.

    Clients resend the whole history with every turn, so its beginning names a
    conversation. Two keys: one through the first assistant reply after the
    first user turn (there from the second turn on, and as good as unique), and
    one through the first user turn alone (all a first request has; two
    conversations that open with the same words share it). Only hashes of the
    roles and text are kept. Empty when affinity is off or no user has spoken."""
    if STICKY_SECONDS <= 0:
        return []
    digest, opening = hashlib.blake2b(digest_size=16), None
    for message in messages or []:
        if not isinstance(message, dict):
            continue
        role = str(message.get("role") or "")
        digest.update(role.encode("utf-8", "replace") + b"\0")
        digest.update(_message_parts(message)[0].encode("utf-8", "replace") + b"\0")
        if opening is None:
            if role == "user":
                opening = digest.hexdigest()
        elif role == "assistant":
            # A reply that only calls tools has no text; its calls tell it apart.
            calls = message.get("tool_calls")
            if calls:
                digest.update(json.dumps(calls, sort_keys=True, default=str).encode("utf-8", "replace"))
            return [digest.hexdigest(), opening]
    return [opening] if opening else []


def sticky_choice(keys: list):
    """(server, model) that last answered this conversation, or None."""
    now = time.monotonic()
    for key in keys or ():
        found = _STICKY.get(key)
        if found is None:
            continue
        if now - found[2] > STICKY_SECONDS:
            del _STICKY[key]
            continue
        return found[0], found[1]
    return None


def remember_choice(keys: list, entry: dict) -> None:
    """Note which server and model answered this conversation."""
    now = time.monotonic()
    for key in keys or ():
        _STICKY[key] = (entry["server"], entry["name"], now)
        _STICKY.move_to_end(key)
    while len(_STICKY) > STICKY_MAX:
        _STICKY.popitem(last=False)


def order_tied(tied: list, sticky=None) -> list:
    """Order candidates that are equally good: the server with the fewest
    requests in flight first, then the one this conversation used last. What is
    still equal keeps the order it came in (the rotation's)."""
    if len(tied) < 2:
        return tied
    return sorted(tied, key=lambda entry: (
        in_flight(entry["server"]),
        0 if sticky and (entry["server"], entry["name"]) == sticky else 1))


def parse_params_billions(text) -> float:
    """'7.6B' -> 7.6, '134M' -> 0.134. A mixture-of-experts label such as
    LM Studio's '26B-A4B' counts its total size (26). 0.0 when unparseable."""
    if not text:
        return 0.0
    match = re.match(r"^\s*([0-9.]+)\s*([bBmM])(?:\s*$|[-_ ])", str(text))
    if not match:
        return 0.0
    try:
        value = float(match.group(1))
    except ValueError:
        return 0.0
    return value if match.group(2).lower() == "b" else value / 1000.0


def params_from_name(name: str) -> float:
    """Fall back to the tag: 'qwen3:14b' -> 14.0, 'phi3:3.8b' -> 3.8."""
    match = re.search(r"[:\-]([0-9.]+)\s*b\b", (name or "").lower())
    if match:
        try:
            return float(match.group(1))
        except ValueError:
            return 0.0
    return 0.0


def _matches_any(haystack: str, needles: list) -> bool:
    return any(n in haystack for n in needles)


def build_entry(server: str, raw: dict, capabilities=None) -> dict:
    """One discovered (server, model). `capabilities` is Ollama's own list from
    /api/show ("completion", "vision", "embedding", "tools", ...). When known it
    decides vision/embedding outright; the name heuristics are the fallback
    for servers that do not report it, and still drive is_code (Ollama has no
    "code" capability)."""
    name = raw.get("name") or raw.get("model") or ""
    details = raw.get("details") or {}
    families = [str(f).lower() for f in (details.get("families") or [])]
    family = str(details.get("family") or "").lower()
    if family and family not in families:
        families.append(family)
    params = parse_params_billions(details.get("parameter_size"))
    if params <= 0:
        params = params_from_name(name)
    lowered = name.lower()
    is_vision = (_matches_any(lowered, VISION_MODELS)
                 or any(f in VISION_FAMILIES for f in families))
    is_embedding = (_matches_any(lowered, EMBEDDING_MODELS)
                    or any(f in EMBEDDING_FAMILIES for f in families))
    caps = [str(c).lower() for c in capabilities] if capabilities else []
    if caps:
        is_vision = "vision" in caps
        is_embedding = "embedding" in caps and "completion" not in caps
    # Tool support: True, False, or None (unknown). Ollama's /api/show list is
    # authoritative (the llama.cpp bridge and AirLLM answer it too). Other
    # kinds say so explicitly in raw["tools"] or not at all.
    if "tools" in raw:
        tools = raw["tools"]
    elif caps and server_kind(server) == "ollama":
        tools = "tools" in caps
    else:
        tools = None
    return {
        "server": server,
        "name": name,
        "params_b": params,
        "quantization": details.get("quantization_level") or "",
        "families": families,
        "size_bytes": raw.get("size") or 0,
        "capabilities": caps,
        "is_code": _matches_any(lowered, CODE_MODELS),
        "is_vision": is_vision,
        "is_embedding": is_embedding,
        "tools": tools,
        # The largest context the server reports for this model (tokens), or
        # None when it reports none. A ceiling, not a guarantee: Ollama, for
        # one, may serve less than the model's own limit unless num_ctx says.
        "context_length": positive_int(raw.get("context_length")),
        # The context the server is set to serve this model with right now
        # (tokens): LM Studio's loaded instance, a num_ctx (Ollama Modelfile,
        # the llama.cpp bridge's slot, AirLLM's window) or a /v1/models
        # server's own setting. None when only the model's own limit is known.
        # Clients that size their window from discovery (Hermes) use this.
        "served_context_length": positive_int(raw.get("served_context_length")),
        # True/False when the server reports residency; None otherwise.
        "loaded": raw.get("loaded"),
        "kind": server_kind(server),
    }


# (server, model name, digest) -> capability list, or None when the server
# does not report one. Keyed by digest so a re-pulled model is re-probed.
_CAPABILITIES = {}
# The same key -> context length from the same /api/show answer, or None.
_CONTEXTS = {}
# The same key -> that context when it came from a num_ctx (what the server
# serves), or None when it is only the model's own limit.
_SERVED_CONTEXTS = {}
# A digest identifies what was probed: Ollama gives a re-pulled or re-created
# model a new one, and AirLLM puts its served window into its digest. Such an
# answer is kept for show_cache_seconds (an hour), so a poll does not ask every
# host about every model again. A server that lists no digest (the llama.cpp
# bridge) can change a runtime setting, such as its context size, with nothing
# to show for it, so its answers expire after a minute, as all did before.
# POST /routing/refresh re-probes everything at once.
SHOW_CACHE_SECONDS = max(0.0, _cfg.getfloat("discovery", "show_cache_seconds"))
SHOW_CACHE_SECONDS_NO_DIGEST = 60.0
_SHOW_TIMES = {}


def _show_ttl(raw: dict) -> float:
    """Seconds a cached /api/show answer for this /api/tags entry stays valid."""
    if raw.get("digest"):
        return SHOW_CACHE_SECONDS
    return min(SHOW_CACHE_SECONDS, SHOW_CACHE_SECONDS_NO_DIGEST)


def _forget_show_answers(server: str, current: set) -> None:
    """Drop the cached answers of models a server no longer lists (a removed
    model, or the previous digest of a re-pulled one)."""
    for key in [k for k in _CAPABILITIES if k[0] == server and k not in current]:
        for cache in (_CAPABILITIES, _CONTEXTS, _SERVED_CONTEXTS, _SHOW_TIMES):
            cache.pop(key, None)


def positive_int(value):
    """value if it is a positive int (not a bool), else None."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def show_context_length(show: dict):
    """The context Ollama's /api/show says a model is served with, or None.
    model_info's "<arch>.context_length" is the model's own limit; a num_ctx
    parameter (a Modelfile's, or AirLLM's window) is what the server uses.
    The smaller known value wins."""
    values = []
    info = show.get("model_info")
    if isinstance(info, dict):
        values += [positive_int(v) for k, v in info.items()
                   if isinstance(k, str) and k.endswith(".context_length")]
    parameters = show.get("parameters")
    if isinstance(parameters, str):
        for line in parameters.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "num_ctx" and parts[1].isdigit():
                values.append(positive_int(int(parts[1])))
    values = [v for v in values if v]
    return min(values) if values else None


def show_served_context(show: dict):
    """show_context_length when /api/show gives a num_ctx, the window the
    server really uses (a Modelfile's, the llama.cpp bridge's slot, AirLLM's);
    None when only the model's own limit is known: Ollama then serves its
    OLLAMA_CONTEXT_LENGTH default, which /api/show does not report."""
    parameters = show.get("parameters")
    if not isinstance(parameters, str) or not any(
            len(parts) == 2 and parts[0] == "num_ctx" and parts[1].isdigit()
            for parts in (line.split() for line in parameters.splitlines())):
        return None
    return show_context_length(show)


def _show_key(server: str, raw: dict) -> tuple:
    name = raw.get("name") or raw.get("model") or ""
    return (server, name, raw.get("digest") or raw.get("modified_at") or "")


async def model_capabilities(client: httpx.AsyncClient, server: str, raw: dict,
                             limit: asyncio.Semaphore = None, force: bool = False):
    """Ollama's capability list for one model via POST /api/show, cached.
    The context length from the same answer is cached in _CONTEXTS."""
    name = raw.get("name") or raw.get("model") or ""
    key = _show_key(server, raw)
    if (not force and key in _CAPABILITIES and key in _SHOW_TIMES
            and time.monotonic() - _SHOW_TIMES[key] < _show_ttl(raw)):
        return _CAPABILITIES[key]
    caps = context = served = None
    try:
        async with (limit or asyncio.Semaphore(1)):
            response = await client.post(f"{server}/api/show", json={"model": name},
                                         timeout=DISCOVERY_TIMEOUT)
        if response.status_code == 200:
            payload = response.json()
            if isinstance(payload, dict):
                found = payload.get("capabilities")
                if isinstance(found, list):
                    caps = [str(c) for c in found]
                context = show_context_length(payload)
                served = show_served_context(payload)
        # Only a definite answer is cached; a transient failure is retried
        # on the next poll.
        if response.status_code in (200, 400, 404, 405, 501):
            _CONTEXTS[key] = context
            _SERVED_CONTEXTS[key] = served
            _CAPABILITIES[key] = caps
            _SHOW_TIMES[key] = time.monotonic()
    except (httpx.HTTPError, ValueError, AttributeError):
        pass
    return _CAPABILITIES.get(key, caps)


def lmstudio_instance_context(config: dict):
    """The tokens one request may use on a loaded LM Studio instance, or None.
    With parallel > 1 (Max Concurrent Predictions) and the Unified KV Cache
    off, llama.cpp gives each slot context_length / parallel, and a longer
    request fails with "request (N tokens) exceeds the available context
    size". LM Studio does not report that setting: lmstudio_unified_kv says
    whether the slots share one pool instead."""
    context = positive_int(config.get("context_length"))
    parallel = positive_int(config.get("parallel"))
    if context and parallel and parallel > 1 and not LMSTUDIO_UNIFIED_KV:
        return context // parallel or None
    return context


def lmstudio_loaded_context(model: dict):
    """The context LM Studio serves one request with: the smallest loaded
    instance's per-request window, or None when it is not loaded (a
    just-in-time load uses LM Studio's load settings, which it does not list)."""
    loaded = []
    for instance in model.get("loaded_instances") or []:
        config = instance.get("config") if isinstance(instance, dict) else None
        context = lmstudio_instance_context(config) if isinstance(config, dict) else None
        if context:
            loaded.append(context)
    return min(loaded) if loaded else None


def lmstudio_context(model: dict):
    """LM Studio's context for a model: the smallest loaded instance's
    per-request window, else max_context_length; None if neither."""
    return lmstudio_loaded_context(model) or positive_int(model.get("max_context_length"))


def _lmstudio_v1_models(payload: dict) -> list:
    """LM Studio 0.4+ GET /api/v1/models -> raw entries build_entry accepts."""
    out = []
    for m in payload.get("models") or []:
        if not isinstance(m, dict) or not m.get("key"):
            continue
        caps = ["embedding"] if m.get("type") == "embedding" else ["completion"]
        features = m.get("capabilities") or {}
        if features.get("vision"):
            caps.append("vision")
        # LM Studio gives untrained models its default tool format, so
        # "not trained for tool use" is not "no tools": leave that unknown.
        trained = bool(features.get("trained_for_tool_use"))
        if trained:
            caps.append("tools")
        quant = m.get("quantization") or {}
        out.append({
            "name": m["key"],
            "size": m.get("size_bytes") or 0,
            "details": {"parameter_size": m.get("params_string") or "",
                        "family": m.get("architecture") or "",
                        "quantization_level": quant.get("name") if isinstance(quant, dict) else quant},
            "capabilities": caps,
            "tools": True if trained else None,
            "loaded": bool(m.get("loaded_instances")),
            "context_length": lmstudio_context(m),
            "served_context_length": lmstudio_loaded_context(m),
        })
    return out


def _lmstudio_v0_models(payload: dict) -> list:
    """LM Studio 0.3.x GET /api/v0/models -> raw entries (type llm|vlm|embeddings)."""
    out = []
    for m in payload.get("data") or []:
        if not isinstance(m, dict) or not m.get("id"):
            continue
        kind = m.get("type")
        caps = (["embedding"] if kind in ("embeddings", "embedding")
                else ["completion", "vision"] if kind == "vlm" else ["completion"])
        out.append({
            "name": m["id"],
            "details": {"family": m.get("arch") or "",
                        "quantization_level": m.get("quantization") or ""},
            "capabilities": caps,
            "loaded": m.get("state") == "loaded",
            "context_length": positive_int(m.get("max_context_length")),
        })
    return out


async def fetch_lmstudio_models(client: httpx.AsyncClient, server: str) -> tuple:
    """Newest native API first; the OpenAI-compatible /v1/models (names only)
    is the last resort, e.g. for an older LM Studio."""
    base, headers = server_base(server), backend_headers(server)
    last_error = None
    for path, convert in (("/api/v1/models", _lmstudio_v1_models),
                          ("/api/v0/models", _lmstudio_v0_models),
                          ("/v1/models", None)):
        try:
            response = await client.get(f"{base}{path}", headers=headers,
                                        timeout=DISCOVERY_TIMEOUT)
            if response.status_code in (404, 405):
                continue
            response.raise_for_status()
            payload = response.json()
        except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
            return server, None, f"{type(exc).__name__}: {exc}"
        except Exception as exc:  # noqa: BLE001 - try the next API flavour
            last_error = f"{path}: {type(exc).__name__}: {exc}"
            continue
        if convert is None:
            raws = [{"name": m.get("id")} for m in (payload.get("data") or [])
                    if isinstance(m, dict) and m.get("id")]
        else:
            raws = convert(payload)
        entries = [build_entry(server, raw, raw.get("capabilities")) for raw in raws]
        return server, [e for e in entries if e["name"]], None
    return server, None, last_error or "no LM Studio model API answered"


async def fetch_openai_models(client: httpx.AsyncClient, server: str) -> tuple:
    """Read Strata, Basalt, Maya, Xolotl, Avalon, Kindi or Colibri model IDs and capabilities at /v1/models."""
    try:
        response = await client.get(f"{server_base(server)}/v1/models",
                                    headers=backend_headers(server),
                                    timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        payload = response.json()
        models = payload["data"]
        if not isinstance(models, list):
            raise ValueError("data is not a list")
        entries = []
        for model in models:
            if not isinstance(model, dict) or not model.get("id"):
                continue
            declared = model.get("capabilities")
            if (isinstance(declared, list) and NON_CHAT_CAPABILITIES & set(declared)
                    and not {"chat", "completion"} & set(declared)):
                # Not for chat. An image generator is an image server's model
                # (POST /v1/images/generations); a decision model is skipped.
                if "image_generation" in declared:
                    entries.append(image_entry(server, str(model["id"]), server_kind(server)))
                continue
            architecture = model.get("architecture") or {}
            modalities = model.get("input_modalities") or []
            if not modalities and isinstance(architecture, dict):
                modalities = architecture.get("input_modalities") or []
            caps = ["completion"] + (["vision"] if "image" in modalities else [])
            outputs = architecture.get("output_modalities") if isinstance(architecture, dict) else None
            meta = model.get("meta") if isinstance(model.get("meta"), dict) else {}
            state = model.get("status", model.get("state"))
            if isinstance(state, dict):
                state = state.get("value")
            size = model.get("parameter_size") or model.get("params_string")
            # Only ids listed in [model_sizes] inherit a size. Other aliases
            # and variants stay unknown unless the API or the id gives one.
            if not size:
                size = MODEL_SIZES.get(str(model["id"]).lower())
            # Field names used by OpenAI-style servers (vLLM-style
            # max_model_len included), then the served context that
            # llama-server and Strata-style servers give as meta.n_ctx
            # (not n_ctx_train, the model's own limit). None required.
            context = next(filter(None, (
                *(positive_int(model.get(k)) for k in
                  ("context_length", "max_model_len", "context_window")),
                positive_int(meta.get("n_ctx")))), None)
            raw = {"name": model["id"], "capabilities": caps,
                   "details": {"parameter_size": size},
                   "loaded": state == "loaded" if state is not None else None,
                   # These servers report the window they were started
                   # with (STRATA_CONTEXT, -c, Kindi's fitted context), so
                   # it is also the served one.
                   "context_length": context,
                   "served_context_length": context}
            # An image generator listed beside the chat model (Strata's
            # /v1/images model) outputs no text, so it takes no tools.
            if server_kind(server) in TOOL_KINDS:
                raw["tools"] = True if not isinstance(outputs, list) or "text" in outputs else None
                if str(model["id"]).lower() in NO_TOOL_MODELS.get(server_kind(server), ()):
                    raw["tools"] = None
            entries.append(build_entry(server, raw, caps))
        return server, entries, None
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        return server, None, f"{type(exc).__name__}: {exc}"


fetch_strata_models = fetch_openai_models  # preserve the existing callable


def image_entry(server: str, name: str, kind: str, variant: str = "") -> dict:
    """One image model on one server. Kept apart from the chat inventory
    (INVENTORY["images"]), so no chat path can ever pick it."""
    return {"server": server, "name": name, "kind": kind, "is_image": True,
            **({"variant": variant} if variant else {})}


def combo_options(spec) -> list:
    """The choices of a ComfyUI combo input, in either /object_info format:
    [["a", "b"], {...}] (older) or ["COMBO", {"options": ["a", "b"]}]."""
    if not isinstance(spec, list) or not spec:
        return []
    if isinstance(spec[0], list):
        return [item for item in spec[0] if isinstance(item, str)]
    if spec[0] == "COMBO" and len(spec) > 1 and isinstance(spec[1], dict):
        return [item for item in spec[1].get("options", []) if isinstance(item, str)]
    return []


async def fetch_comfyui_images(client: httpx.AsyncClient, server: str) -> tuple:
    """A ComfyUI CT's image models: each Klein variant whose diffusion model,
    text encoder and VAE its loaders list. ComfyUI has no authentication; its
    CT's firewall admits the router."""
    try:
        response = await client.get(f"{server}/system_stats", timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        stats = response.json()
        system = stats.get("system") if isinstance(stats, dict) else None
        if not isinstance(system, dict) or not system.get("comfyui_version"):
            raise ValueError("not a ComfyUI server (no system.comfyui_version)")
        files = {}
        for node, key in COMFYUI_LOADERS:
            response = await client.get(f"{server}/object_info/{node}", timeout=DISCOVERY_TIMEOUT)
            response.raise_for_status()
            info = response.json().get(node) or {}
            files[key] = set(combo_options(((info.get("input") or {}).get("required") or {}).get(key)))
        entries = [image_entry(server, f"{variant}-comfyui", "comfyui", variant)
                   for variant, spec in COMFYUI_VARIANTS.items()
                   if all(name in files[key] for key, name in spec["files"].items())]
        return server, entries, None
    except (httpx.HTTPError, ValueError, KeyError, TypeError, AttributeError) as exc:
        return server, None, f"{type(exc).__name__}: {exc}"


async def fetch_server_models(client: httpx.AsyncClient, server: str,
                              force_probe: bool = False) -> tuple:
    if server_kind(server) == "lmstudio":
        return await fetch_lmstudio_models(client, server)
    if server_kind(server) in OPENAI_KINDS:
        return await fetch_openai_models(client, server)
    try:
        response = await client.get(f"{server}/api/tags", timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        payload = response.json()
    except Exception as exc:  # noqa: BLE001 - any failure means "server is down"
        return server, None, f"{type(exc).__name__}: {exc}"
    raws = [m for m in (payload.get("models") or []) if isinstance(m, dict)]
    # Ollama's /api/tags lists installed models; /api/ps reports the ones
    # resident in memory right now. Older bridges may lack /api/ps, in which
    # case residency remains unknown rather than marking everything cold.
    try:
        running = await client.get(f"{server}/api/ps", timeout=DISCOVERY_TIMEOUT)
        running.raise_for_status()
        running_models = [m for m in running.json().get("models", []) if isinstance(m, dict)]
        loaded = {name for m in running_models for name in (m.get("name"), m.get("model"))
                  if isinstance(name, str)}
        loaded.update(f"{name}:latest" for name in tuple(loaded) if ":" not in name)
        loaded_digests = {m["digest"] for m in running_models if m.get("digest")}
        for raw in raws:
            raw["loaded"] = ((raw.get("name") or raw.get("model")) in loaded
                             or bool(raw.get("digest") and raw["digest"] in loaded_digests))
    except (httpx.HTTPError, ValueError, TypeError, AttributeError):
        pass
    if CAPABILITY_PROBE:
        limit = asyncio.Semaphore(8)   # per poll, so no cross-event-loop state
        caps = await asyncio.gather(*[model_capabilities(client, server, m, limit, force_probe)
                                      for m in raws])
        for raw in raws:
            raw["context_length"] = _CONTEXTS.get(_show_key(server, raw))
            raw["served_context_length"] = _SERVED_CONTEXTS.get(_show_key(server, raw))
        _forget_show_answers(server, {_show_key(server, raw) for raw in raws})
    else:
        caps = [None] * len(raws)
    entries = [build_entry(server, m, c) for m, c in zip(raws, caps, strict=True)]
    return server, [e for e in entries if e["name"]], None


async def refresh_inventory(force_probe: bool = False) -> dict:
    """Poll every target for the models it is currently serving."""
    global INVENTORY
    load_tier_models()
    if not SERVERS and not COMFYUI_SERVERS:
        INVENTORY = {"models": [], "images": [], "servers": {}, "updated_at": time.time(),
                     "errors": {"config": "no servers configured"}}
        return INVENTORY
    results = await asyncio.gather(
        *[fetch_server_models(http_client(), s, force_probe) for s in SERVERS],
        *[fetch_comfyui_images(http_client(), s) for s in COMFYUI_SERVERS],
        return_exceptions=True,
    )
    models, images, servers, errors = [], [], {}, {}
    for result in results:
        if isinstance(result, Exception):
            continue
        server, entries, error = result
        if error is not None:
            servers[server] = {"up": False, "model_count": 0}
            errors[server] = error
            if INVENTORY.get("servers", {}).get(server, {}).get("up", True):
                log.warning("discovery: %s is down (%s)", server, error)
            continue
        if not INVENTORY.get("servers", {}).get(server, {}).get("up", True):
            log.info("discovery: %s is back (%d models)", server, len(entries))
        drawn = [e for e in entries if e.get("is_image")]
        chat = [e for e in entries if not e.get("is_image")]
        servers[server] = {"up": True, "model_count": len(chat)}
        if drawn or server in COMFYUI_SERVERS:
            servers[server]["image_models"] = len(drawn)
        models.extend(chat)
        images.extend(drawn)
    INVENTORY = {"models": models, "images": images, "servers": servers,
                 "updated_at": time.time(), "errors": errors}
    return INVENTORY


def mark_server_down(server: str, reason: str) -> None:
    """Take a host out of rotation right now, instead of waiting up to
    refresh_seconds for the next poll. The next successful poll restores it."""
    global INVENTORY
    servers = dict(INVENTORY.get("servers", {}))
    previous = servers.get(server, {})
    if not previous.get("up", True):
        return
    servers[server] = dict(previous, up=False)
    errors = dict(INVENTORY.get("errors", {}), **{server: reason})
    INVENTORY = dict(INVENTORY, servers=servers, errors=errors)
    log.warning("dispatch: %s marked down until the next discovery poll (%s)",
                server, reason)


async def _discovery_loop() -> None:
    while True:
        await asyncio.sleep(max(5, DISCOVERY_REFRESH))
        try:
            await refresh_inventory()
        except Exception:  # noqa: BLE001 - never let the loop die
            log.exception("discovery: refresh failed")


# --- shared HTTP client + lifespan ---------------------------------------------
# One pooled client for every upstream call. Tests swap the transport.
_HTTP = {"client": None, "transport": None, "task": None}


def http_client() -> httpx.AsyncClient:
    if _HTTP["client"] is None:
        _HTTP["client"] = httpx.AsyncClient(
            timeout=httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT),
            limits=httpx.Limits(max_connections=200, max_keepalive_connections=40),
            transport=_HTTP["transport"],
        )
    return _HTTP["client"]


def _is_loopback(host: str) -> bool:
    if host in ("localhost", ""):
        return host == "localhost"
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


@asynccontextmanager
async def lifespan(_app):
    http_client()
    if not ROUTER_API_KEY and not _is_loopback(ROUTER_HOST):
        log.warning("ROUTER_API_KEY is not set and the router listens on %s: "
                    "anyone who can reach port %d can use every backend. Set "
                    "it with `manage-model-servers set-api-key`.",
                    ROUTER_HOST, ROUTER_PORT)
    if DISCOVERY_ENABLED and (SERVERS or COMFYUI_SERVERS):
        await refresh_inventory()
        # Keep the reference: a bare create_task() can be garbage-collected.
        _HTTP["task"] = asyncio.create_task(_discovery_loop())
    log.info("router ready: discovery=%s servers=%d scope=%s auth=%s",
             DISCOVERY_ENABLED, len(SERVERS), CLASSIFY_SCOPE,
             "on" if ROUTER_API_KEY else "off")
    try:
        yield
    finally:
        task = _HTTP.get("task")
        if task:
            task.cancel()
        if _COMFYUI_CANCELS:
            await asyncio.gather(*tuple(_COMFYUI_CANCELS), return_exceptions=True)
        if _HTTP["client"] is not None:
            await _HTTP["client"].aclose()
            _HTTP["client"] = None


app = FastAPI(title="Open Smart Router", lifespan=lifespan)


def api_key_failure(path: str, headers) -> Response | None:
    """The response that refuses a request, or None when it may proceed."""
    if path != "/healthz" and headers.get("x-router-subscription") == "1" \
            and not ROUTER_API_KEY:
        return _error(503, "Subscription pass through requires ROUTER_API_KEY.",
                      "subscription_auth_not_configured")
    if ROUTER_API_KEY and path != "/healthz":
        if headers.get("x-router-subscription") == "1":
            # Keep Authorization free for the signed-in Codex/Claude client.
            token = headers.get("x-router-api-key", "")
        else:
            supplied = headers.get("authorization", "")
            token = supplied[7:].strip() if supplied.lower().startswith("bearer ") else ""
        if not hmac.compare_digest(token.encode(), ROUTER_API_KEY.encode()):
            return JSONResponse(
                {"error": {"message": "Missing or invalid router API key.",
                           "type": "invalid_request_error",
                           "code": "invalid_api_key"}},
                status_code=401)
    return None


class RouterKeyMiddleware:
    """The API-key check as plain ASGI middleware.

    @app.middleware("http") would build Starlette's BaseHTTPMiddleware, which
    runs the application in a second task and relays every response chunk
    through an in-memory stream: a cost paid for each token of a streamed
    completion. Here an admitted request reaches the application with its own
    receive and send, untouched."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            denied = api_key_failure(scope["path"], Headers(scope=scope))
            if denied is not None:
                await denied(scope, receive, send)
                return
        await self.app(scope, receive, send)


def _metrics_route(path: str) -> str:
    """Which family of requests a path belongs to in osr_requests_total; ""
    for the ones not counted (/healthz and /metrics are polled by machines)."""
    if path == "/v1/chat/completions":
        return "chat"
    if path == "/v1/images/generations":
        return "images"
    if path.startswith("/v1/"):
        return "v1"
    if path.startswith("/routing/"):
        return "routing"
    return ""


class RequestMiddleware:
    """Gives each request its ID and counts and times it for /metrics.

    Plain ASGI, like the key check: the only thing put between the application
    and the server is one function call per message sent. The labels are read
    from the X-Router-* headers the router itself puts on an answer."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        current = accept_request_id(Headers(scope=scope).get("x-request-id"))
        token = _REQUEST_ID.set(current)
        route = _metrics_route(scope["path"])
        started = time.monotonic()
        timed = {}

        async def send_with_id(message):
            kind = message["type"]
            record_start = record_duration = False
            if kind == "http.response.start":
                headers = list(message.get("headers") or [])
                given = {name.lower(): value for name, value in headers}
                headers.append((b"x-router-request-id", current.encode("ascii")))
                if b"x-request-id" not in given:
                    headers.append((b"x-request-id", current.encode("ascii")))
                message = dict(message, headers=headers)
                if route:
                    labels = {label: given.get(b"x-router-" + label.encode(), b"").decode("latin-1")
                              for label in ("mode", "model", "server")}
                    count("osr_requests_total", route=route, status=str(message["status"]),
                          **{"class": given.get(b"x-router-class", b"").decode("latin-1")}, **labels)
                    if route == "chat" and message["status"] < 400:
                        timed.update(labels)
                        record_start = True
            elif kind == "http.response.body" and timed and not message.get("more_body"):
                record_duration = True
            await send(message)
            # ASGI send completion is the closest available point to headers
            # and the final body reaching the server's output transport.
            if record_start:
                observe("osr_response_start_seconds", time.monotonic() - started, **timed)
            if record_duration:
                observe("osr_request_duration_seconds", time.monotonic() - started, **timed)
                timed.clear()

        try:
            await self.app(scope, receive, send_with_id)
        finally:
            _REQUEST_ID.reset(token)


app.add_middleware(RouterKeyMiddleware)
# Added last, so it is outermost: a refused request has an ID and is counted too.
app.add_middleware(RequestMiddleware)


# --- request analysis ---------------------------------------------------------
_CLASS_TO_TIER = {"fast": "TIER_FAST", "medium": "TIER_MEDIUM",
                  "large": "TIER_LARGE", "xlarge": "TIER_XLARGE"}


def classify_text(text: str) -> dict:
    """Request class for one block of text. The single source of the keyword
    and length heuristics, shared by discovery routing and the LiteLLM path."""
    approx_tokens = len(text.split()) * 1.3
    is_code = matches_keywords(CODE_RE, text)
    if CODE_FIRST and is_code:
        request_class = "fast"
    elif approx_tokens > TOKEN_THRESHOLD_XLARGE or matches_keywords(XLARGE_RE, text):
        request_class = "xlarge"
    elif approx_tokens > TOKEN_THRESHOLD_LARGE or matches_keywords(LARGE_RE, text):
        request_class = "large"
    elif approx_tokens > TOKEN_THRESHOLD_MEDIUM:
        request_class = "medium"
    else:
        request_class = "fast"
    return {"class": request_class, "code": is_code,
            "approx_tokens": round(approx_tokens)}


def analyze_complexity(prompt: str) -> str:
    """Tier alias (a LiteLLM model_name) for a prompt -- the LiteLLM path."""
    return globals()[_CLASS_TO_TIER[classify_text(prompt)["class"]]]


def _message_parts(message) -> tuple:
    """(text, has_image) for one OpenAI chat message."""
    if not isinstance(message, dict):
        return "", False
    content = message.get("content")
    if isinstance(content, str):
        return content, False
    texts, has_image = [], False
    if isinstance(content, list):
        # OpenAI multimodal form: [{"type":"text"...},{"type":"image_url"...}]
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                texts.append(part["text"])
            elif part.get("type") in ("image_url", "input_image", "image"):
                has_image = True
    return " ".join(texts), has_image


def routing_text(messages: list) -> str:
    """The text the heuristics judge, per [classification] scope."""
    messages = [m for m in (messages or []) if isinstance(m, dict)]
    if CLASSIFY_SCOPE != "conversation":
        for message in reversed(messages):
            if message.get("role") == "user":
                return _message_parts(message)[0]
    # Scope "conversation", or no user turn at all (then judge everything).
    return " ".join(_message_parts(m)[0] for m in messages)


def classify_request(messages: list) -> dict:
    """Turn the conversation into routing requirements.

    Images are looked for in EVERY message: a follow-up question about an
    image sent earlier still needs a vision model to see it."""
    need = classify_text(routing_text(messages))
    need["vision"] = any(_message_parts(m)[1] for m in (messages or []))
    need["tools"] = False
    return need


def wants_tools(body: dict) -> bool:
    """Does the request offer the model tools it may call? An empty list, or
    tool_choice "none", asks for none."""
    if not isinstance(body, dict):
        return False
    tools = body.get("tools") or body.get("functions")
    if not isinstance(tools, list) or not tools:
        return False
    return body.get("tool_choice") != "none" and body.get("function_call") != "none"


def apply_tool_needs(need: dict, body: dict) -> dict:
    """Mark a tool request, and raise its class to tools_min_class."""
    need = dict(need, tools=wants_tools(body))
    if need["tools"] and TOOLS_MIN_CLASS and \
            CLASS_ORDER.index(need["class"]) < CLASS_ORDER.index(TOOLS_MIN_CLASS):
        need["class"] = TOOLS_MIN_CLASS
    return need


def _in_band(params: float, low: float, high: float) -> bool:
    """Is a parameter count inside a band?

    The upper bound is EXCLUSIVE so adjacent bands are disjoint. With the
    defaults (large 20:70, xlarge 70:999) an inclusive bound would place a 70B
    model in both, and the size bias in score_entry would then let large take
    the very model that defines xlarge. The topmost band keeps an inclusive
    ceiling so the biggest model in the pool still lands somewhere.
    """
    return low <= params < high or params == high == TOP_BAND_HIGH


def band_distance(entry: dict, need: dict) -> float:
    """How far outside the requested band a model sits, in billions (0 = in).

    Used to order candidates when nothing is in band at all -- see
    rank_candidates. A model of unknown size sorts after known out-of-band
    models, but remains eligible when no known-size model exists.
    """
    if is_tier_member(entry, need):
        return 0.0
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    params = entry["params_b"]
    if params <= 0:
        return float("inf")
    if _in_band(params, low, high):
        return 0.0
    return (low - params) if params < low else (params - high)


def in_requested_band(entry: dict, need: dict) -> bool:
    """Does this model's size genuinely fall inside the requested band?

    Distinct from `band_distance(...) == 0.0`, which means a known model is
    inside the requested band. Keeping them separate matters: one unknown-size
    model in the pool must not switch off distance ranking for every other
    candidate.
    """
    if is_tier_member(entry, need):
        return True
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    return entry["params_b"] > 0 and _in_band(entry["params_b"], low, high)


def score_entry(entry: dict, need: dict) -> float:
    """Heuristic fit of one discovered (server, model) pair to one request."""
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    params = entry["params_b"]
    in_band = _in_band(params, low, high)
    # A model assigned to the requested tier (manage-model-servers set-model /
    # add-model) fits it whatever its size, and every such model scores alike,
    # so they tie and the requests rotate across all of them and their hosts.
    member = is_tier_member(entry, need)
    if member:
        fit = 1.0
    elif params <= 0:
        fit = W_UNKNOWN
    elif in_band:
        fit = 1.0
    else:
        distance = (low - params) if params < low else (params - high)
        fit = max(0.0, 1.0 - (distance / BAND_FALLOFF))
    score = W_BAND * fit

    if need["code"]:
        score += W_CODE if entry["is_code"] else 0.0
    elif entry["is_code"]:
        # A code model on a general request is usable but not preferred.
        score -= W_CODE * W_OFFTASK

    if need["vision"]:
        score += W_VISION if entry["is_vision"] else -W_VISION
    elif entry["is_vision"]:
        # A vision model answers text fine, but it is tuned for something else
        # and is usually the wrong pick when an equal-sized text model exists.
        score -= W_VISION * W_OFFTASK

    # Within a band, bias toward the extreme the class actually wants. The bias
    # is a position WITHIN the band (0 at the floor, 1 at the ceiling) and is
    # applied only to in-band models. Rewarding absolute size instead would let
    # an out-of-band giant outscore a perfect in-band fit: a 70B model sits at
    # large's exclusive ceiling, so the gentle falloff still scores it ~1.0, and
    # an unbounded size bonus would push it past the 32B that actually belongs
    # to the tier.
    if params > 0 and in_band and not member:
        span = high - low
        position = (params - low) / span if span > 0 else 1.0
        position = max(0.0, min(position, 1.0))
        if need["class"] in ("large", "xlarge"):
            score += W_LARGER * position
        elif need["class"] == "fast":
            score += W_SMALLER * (1.0 - position)
    if member:
        # Ahead of any model that is only the right size: the tier's own
        # models are the ones asked for.
        score += W_TIER_MEMBER
    if entry.get("loaded"):
        score += W_LOADED
    if need.get("tools") and entry.get("tools"):
        score += W_TOOLS
    # Each request already in flight on the server counts against it, so a busy
    # server gives way to an equally good idle one at once, and to a slightly
    # worse one (the same model not yet loaded elsewhere, say) as it gets busier.
    score -= BUSY_PENALTY * in_flight(entry["server"])
    return score


def rank_candidates(need: dict, inventory: dict = None, affinity: list = None) -> list:
    """All usable (server, model) pairs, best first. affinity: the request's
    conversation_keys, so that equally good candidates start with the one the
    conversation used last."""
    inv = inventory if inventory is not None else INVENTORY
    scored = []
    for entry in inv.get("models", []):
        if entry["is_embedding"]:
            continue  # embedding models cannot serve chat completions
        if not inv.get("servers", {}).get(entry["server"], {}).get("up", True):
            continue
        if LMSTUDIO_LOADED_ONLY and entry["kind"] == "lmstudio" and entry.get("loaded") is False:
            continue  # would trigger a just-in-time load on LM Studio
        scored.append((score_entry(entry, need), entry))
    if need.get("tools"):
        # A model known to lack tools answers a tool request with an error.
        # Keep the full list only when nothing else is left (the caller warns).
        capable = [pair for pair in scored if pair[1].get("tools") is not False]
        scored = capable or scored
    if not scored:
        return []

    # Ordinarily score alone orders the list. But when NOTHING is in band it
    # cannot: the falloff floors at zero once a model is band_falloff billions
    # outside, so for an xlarge request (70:999) against a 14B/27B pool every
    # candidate flattens to exactly 0.0. They then look tied, and the rotation
    # below hands the prompt to the smallest model half the time while the
    # largest sits idle. In that case rank by how far each model is from the
    # band, so the closest wins, and let score break ties only among models
    # that are equally far out.
    use_distance = not any(in_requested_band(e, need) for _, e in scored)

    def _distance(entry):
        return band_distance(entry, need) if use_distance else 0.0

    # Sorting on (distance asc, score desc) is identical to the previous
    # score-only sort whenever use_distance is False.
    scored.sort(key=lambda pair: (_distance(pair[1]), -pair[0]))

    # Rotate through candidates that score within tie_epsilon of the best, so
    # the same model on several hosts shares load instead of always hitting the
    # first one. (LiteLLM does this for the static path; direct dispatch needs
    # its own.) Equal distance is part of "tied": without it the rotation would
    # spread load across models of visibly different size.
    best_score = scored[0][0]
    best_distance = _distance(scored[0][1])
    sticky = sticky_choice(affinity)
    tied, rest = [], []
    for s_val, e in scored:
        if _distance(e) == best_distance and best_score - s_val <= TIE_EPSILON:
            tied.append(e)
        else:
            rest.append(e)
    if need.get("tools") and len(tied) > 1:
        # An agent loop sends many requests for one task. Rotating between
        # DIFFERENT models would change the model mid-task and discard the
        # backend's prompt cache, so only the same model on several hosts
        # shares the load.
        # The model the task has been using stays the one, while it is tied.
        best_name = tied[0]["name"]
        names = list(dict.fromkeys(e["name"] for e in tied))
        if sticky and any(e["name"] == sticky[1] for e in tied):
            best_name = sticky[1]
        elif STICKY_SECONDS > 0 and len(names) > 1 \
                and all(is_tier_member(e, need) for e in tied):
            # A tier with several assigned models: each new task takes the
            # next of them, and keeps it through the conversation affinity.
            key = f"tools-model|{need['class']}|{need['code']}|{need['vision']}"
            index = _rotation.get(key, 0) % len(names)
            _rotation[key] = index + 1
            best_name = names[index]
        rest = [e for e in tied if e["name"] != best_name] + rest
        tied = [e for e in tied if e["name"] == best_name]
    if len(tied) > 1:
        key = f"{need['class']}|{need['code']}|{need['vision']}|{need.get('tools', False)}"
        index = _rotation.get(key, 0) % len(tied)
        _rotation[key] = index + 1
        tied = tied[index:] + tied[:index]
    return order_tied(tied, sticky) + rest


def find_named_model(model_name: str, affinity: list = None) -> list:
    """Servers hosting an explicitly requested model, best first: the least
    busy, then the one the conversation used last, in rotation otherwise."""
    wanted = (model_name or "").strip().lower()
    if not wanted:
        return []
    matches = [e for e in INVENTORY.get("models", [])
               if e["name"].lower() == wanted
               and not e["is_embedding"]
               and INVENTORY.get("servers", {}).get(e["server"], {}).get("up", True)]
    if not matches:
        # Allow the bare name without its tag, e.g. "qwen3" -> "qwen3:14b".
        matches = [e for e in INVENTORY.get("models", [])
                   if e["name"].lower().split(":", 1)[0] == wanted
                   and not e["is_embedding"]
                   and INVENTORY.get("servers", {}).get(e["server"], {}).get("up", True)]
    if len(matches) > 1:
        index = _rotation.get(wanted, 0) % len(matches)
        _rotation[wanted] = index + 1
        matches = matches[index:] + matches[:index]
    return order_tied(matches, sticky_choice(affinity))


def embedding_only_match(model_name: str):
    """The inventory name when an explicitly requested model exists ONLY as an
    embedding model (exact name first, then the bare name without its tag);
    None when it is unknown or any host serves it for chat.

    Such a request cannot be answered by the chat endpoint. Rerouting it to
    some other chat model would silently answer with a model the client did
    not ask for, so the caller rejects it instead.

    Host state is deliberately ignored: when the chat copy of a name is only on
    a host that is down, the model is not embedding-only, and the request takes
    the same path as any explicitly named model that is currently unavailable
    (routed by its content, flagged with X-Router-Warning: model-unavailable).
    """
    wanted = (model_name or "").strip().lower()
    if not wanted:
        return None
    models = INVENTORY.get("models", [])
    matches = [e for e in models if e["name"].lower() == wanted]
    if not matches:
        matches = [e for e in models if e["name"].lower().split(":", 1)[0] == wanted]
    if matches and all(e["is_embedding"] for e in matches):
        return matches[0]["name"]
    return None


def known_chat_model(model_name: str) -> bool:
    """Is this name (exact, or without its tag) a chat model on ANY host, up or
    down? Distinguishes "named model temporarily unavailable" from a name the
    router has never seen."""
    wanted = (model_name or "").strip().lower()
    if not wanted:
        return False
    return any(not e["is_embedding"]
               and wanted in (e["name"].lower(), e["name"].lower().split(":", 1)[0])
               for e in INVENTORY.get("models", []))


# --- proxying -----------------------------------------------------------------
def _forward_headers(request: Request, drop_auth: bool = False) -> dict:
    """Request headers to send upstream. drop_auth strips Authorization, so the
    router's own API key is never handed to an Ollama host. The request's ID
    goes along as X-Request-ID (the caller's own, when the router adopted it)."""
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in HOP_BY_HOP
               and k.lower() not in ("x-router-api-key", "x-router-subscription", "x-request-id")
               and not (drop_auth and k.lower() == "authorization")}
    if request_id():
        headers["X-Request-ID"] = request_id()
    return headers


async def _proxy_subscription(request: Request) -> Response:
    if not SUBSCRIPTION_GATEWAY_BASE:
        return _error(503, "Subscription gateway is not configured.",
                      "subscription_gateway_not_configured")
    url = f"{SUBSCRIPTION_GATEWAY_BASE}{request.url.path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"
    raw = await request.body()
    return await _stream_upstream(
        request.method, url, _forward_headers(request), content=raw or None,
        extra_headers={"X-Router-Mode": "subscription"})


def _response_headers(upstream: httpx.Response, extra: dict = None) -> dict:
    headers = {k: v for k, v in upstream.headers.items()
               if k.lower() not in RESPONSE_HOP_BY_HOP
               and not k.lower().startswith("x-router-")}
    # Only this router may set X-Router-* response headers. Metrics use them
    # as labels, so forwarding an upstream value could create unbounded series.
    if extra:
        headers.update(extra)
    return headers


async def close_upstream(response: httpx.Response, slot: InFlight = None) -> None:
    await response.aclose()
    if slot is not None:
        slot.release()


async def _relay_counted(slot: InFlight, chunks: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
    """Relay a streamed body. The request stops counting against its server
    when the stream ends, breaks, or the client stops reading."""
    try:
        async for chunk in chunks:
            yield chunk
    finally:
        slot.release()


async def _stream_upstream(method: str, url: str, headers: dict,
                           json_body=None, content=None,
                           extra_headers: dict = None,
                           read_timeout: float = READ_TIMEOUT,
                           kindi_tier: bool = False) -> Response:
    client = http_client()
    try:
        upstream_request = client.build_request(
            method, url, headers=headers, json=json_body, content=content,
            timeout=httpx.Timeout(read_timeout, connect=CONNECT_TIMEOUT),
        )
        upstream_response = await client.send(upstream_request, stream=True)
    except httpx.ReadTimeout as exc:
        if kindi_tier:
            return kindi_no_reply("LiteLLM did not answer for a tier with Kindi.")
        raise HTTPException(status_code=502, detail=f"OSR core disconnect: {exc}") from exc
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f"OSR core disconnect: {exc}") from exc
    if kindi_tier and upstream_response.status_code == 408:
        # LiteLLM answers its own timeout with 408, which an SDK retries.
        await upstream_response.aclose()
        return kindi_no_reply("LiteLLM gave up on a tier with Kindi.")
    if (kindi_tier and isinstance(json_body, dict) and json_body.get("stream") is not True
            and 200 <= upstream_response.status_code < 300):
        # LiteLLM can send 200 headers before a Kindi-backed completion body.
        # Finish the non-streaming response before committing our own 200.
        try:
            buffered = b"".join([chunk async for chunk in upstream_response.aiter_raw()])
        except httpx.ReadTimeout:
            await upstream_response.aclose()
            return kindi_no_reply("LiteLLM did not finish a tier with Kindi.")
        except httpx.RequestError as exc:
            await upstream_response.aclose()
            raise HTTPException(status_code=502, detail=f"OSR core disconnect: {exc}") from exc
        await upstream_response.aclose()
        return Response(content=buffered, status_code=upstream_response.status_code,
                        headers=_response_headers(upstream_response, extra_headers))
    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=_response_headers(upstream_response, extra_headers),
        background=BackgroundTask(close_upstream, upstream_response),
    )


# Upstream statuses that mean "try the next candidate": the host is failing
# (5xx) or no longer has the model (404, e.g. removed since the last poll).
RETRYABLE_STATUS = {404} | set(range(500, 600))
CLIENT_RETRYABLE_STATUS = {408, 409, 429} | set(range(500, 600))

# A Kindi request that got no reply after it was sent may still be running:
# Kindi serves one request at a time, and an OpenAI SDK retries a 5xx (a 408
# too), so the retry would queue behind it. Such a failure is answered 424 with
# x-should-retry: false; the message avoids the words clients match as a
# timeout. The router hung up, so Kindi stops the request at its next prompt
# batch or token; until its /health confirms it is idle, nothing more is sent
# to it and callers get a retryable 503. A newer busy request does not prove
# the unanswered one has finished: it could still be waiting in Kindi's queue.
KINDI_HEALTH_CACHE_SECONDS = 5
_KINDI_DRAINING: dict = {}  # server -> [last /health check, busy]


def kindi_no_reply(prefix: str) -> JSONResponse:
    return JSONResponse(
        {"error": {"message": prefix + " No complete reply arrived within the read budget; the request "
                   "was not sent again, because Kindi may still be working on it.",
                   "type": "upstream_no_reply", "code": "kindi_no_reply"}},
        status_code=424, headers={"x-should-retry": "false"})


def mark_kindi_draining(server: str) -> None:
    _KINDI_DRAINING[server] = [float("-inf"), True]


async def kindi_busy(server: str) -> bool:
    """True while a Kindi server that left a request unanswered still reports
    work in progress on /health (checked at most every 5 s)."""
    state = _KINDI_DRAINING.get(server)
    if state is None:
        return False
    now = time.monotonic()
    if now - state[0] < KINDI_HEALTH_CACHE_SECONDS:
        return state[1]
    try:
        response = await http_client().get(f"{server_base(server)}/health", timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        health = response.json()
        if not isinstance(health, dict) or "busy" not in health:
            raise ValueError("Kindi health response has no busy field")
        busy = health["busy"] is not None and health["busy"] is not False
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("dispatch: cannot confirm Kindi %s is idle (%s)", server, exc)
        busy = True
    # A concurrent request may have recorded a newer unanswered POST while
    # this probe was in flight. Its drain state takes precedence.
    current = _KINDI_DRAINING.get(server)
    if current is not state:
        return current[1] if current is not None else False
    if busy:
        _KINDI_DRAINING[server] = [now, True]
    else:
        _KINDI_DRAINING.pop(server, None)
    return busy


# Only a capability rejection warrants trying another model and temporarily
# excluding this one from tool requests. A malformed tools payload can also
# mention "tools" in a 400, but every candidate would receive that same error.
TOOL_REJECTION_RE = re.compile(
    rb"\b(?:does not|doesn't|do not|don't)\s+support\s+"
    rb"(?:tools?|tool\s+(?:calls?|calling|use)|function\s+(?:calls?|calling))\b"
    rb"|\b(?:tools?|tool\s+(?:calls?|calling|use)|function\s+(?:calls?|calling))"
    rb"\s+(?:is|are)\s+not\s+supported\b",
    re.IGNORECASE,
)
# Error bodies are small; never buffer more than this to inspect one.
ERROR_PEEK_BYTES = 65536


async def _read_raw(response: httpx.Response, limit: int = ERROR_PEEK_BYTES) -> bytes:
    """The raw (still encoded) body of an error response, up to limit bytes."""
    chunks, size = [], 0
    async for chunk in response.aiter_raw():
        chunks.append(chunk)
        size += len(chunk)
        if size >= limit:
            break
    return b"".join(chunks)


async def _relay_kindi_stream(server: str, response: httpx.Response, first_chunk: bytes,
                              remaining: AsyncIterator[bytes]) -> AsyncIterator[bytes]:
    """Relay SSE after its first chunk; keep Kindi gated if it later stalls."""
    try:
        if first_chunk:
            yield first_chunk
        async for chunk in remaining:
            yield chunk
    except httpx.ReadTimeout:
        mark_kindi_draining(server)
        raise
    finally:
        await response.aclose()


def _json_bytes(payload) -> bytes:
    """A JSON body as httpx encodes json=: compact UTF-8, non-ASCII kept."""
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"),
                      allow_nan=False).encode("utf-8")


def body_for_model(body: dict, name: str, raw: bytes | None, encoded: dict) -> bytes:
    """The request body with "model" set to name, as bytes.

    A long conversation or an inline image makes the body megabytes of JSON,
    and encoding it holds the event loop, and with it every other stream. So
    it is encoded once per model name (encoded caches it across the fail-forward
    attempts, where the same model on another host is the usual next candidate),
    and not at all when the client already named this model: its own bytes
    (raw, when they are UTF-8 JSON) are sent as they came."""
    if name not in encoded:
        if raw is not None and body.get("model") == name and json.detect_encoding(raw) == "utf-8":
            encoded[name] = raw
        else:
            encoded[name] = _json_bytes(dict(body, model=name))
    return encoded[name]


async def _dispatch_direct(candidates: list, body: dict, headers: dict,
                           need: dict, extra_headers: dict = None,
                           raw: bytes | None = None, affinity: list = None) -> Response:
    """Send to the best candidate, falling forward through the ranked list on
    connection errors, 404 or 5xx. Retrying is only safe before any body has
    been streamed, which is why the status is checked before returning. A host
    that refuses or times out the CONNECTION is marked down immediately so the
    next request skips it too."""
    client = http_client()
    last_error = None
    no_reply = kindi_was_busy = False
    encoded: dict = {}

    def failed(entry: dict, reason: str) -> None:
        count("osr_upstream_failures_total", server=entry["server"], reason=reason)

    if not any(key.lower() == "content-type" for key in headers):
        headers = dict(headers, **{"Content-Type": "application/json"})
    for position, entry in enumerate(candidates):
        if not INVENTORY.get("servers", {}).get(entry["server"], {}).get("up", True):
            last_error = f"{entry['server']}: marked down"
            continue
        if entry["kind"] == "kindi" and await kindi_busy(entry["server"]):
            last_error = (f"{entry['server']} is still busy after an earlier request got no reply; "
                          "nothing was sent to it")
            kindi_was_busy = True
            continue
        slot = InFlight(entry["server"])
        try:
            url = f"{server_base(entry['server'])}/v1/chat/completions"
            try:
                upstream_request = client.build_request(
                    "POST", url, headers=dict(headers, **backend_headers(entry["server"])),
                    content=body_for_model(body, entry["name"], raw, encoded),
                    timeout=httpx.Timeout(
                        KINDI_READ_TIMEOUT if entry["kind"] == "kindi" else READ_TIMEOUT,
                        connect=CONNECT_TIMEOUT,
                    ),
                )
                upstream_response = await client.send(upstream_request, stream=True)
            except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
                last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                failed(entry, "connect")
                mark_server_down(entry["server"], last_error)
                continue
            except httpx.RequestError as exc:
                last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                if entry["kind"] == "kindi" and isinstance(exc, httpx.ReadTimeout):
                    # Sent, but no reply: Kindi may still be working on it.
                    no_reply = True
                    failed(entry, "no_reply")
                    mark_kindi_draining(entry["server"])
                    log.warning("dispatch: Kindi %s sent no reply; not sending it again", entry["server"])
                    continue
                failed(entry, "transport")
                log.warning("dispatch: %s", last_error)
                continue
            is_last = position == len(candidates) - 1
            if upstream_response.status_code in RETRYABLE_STATUS:
                # Counted whether another candidate follows or this answer is
                # passed on as it is.
                failed(entry, f"http_{upstream_response.status_code}")
            if upstream_response.status_code in RETRYABLE_STATUS and not is_last:
                await upstream_response.aclose()
                last_error = f"{entry['server']}: HTTP {upstream_response.status_code}"
                log.warning("dispatch: %s for %s; trying the next candidate",
                            last_error, entry["name"])
                continue
            if no_reply and upstream_response.status_code in CLIENT_RETRYABLE_STATUS:
                # A later error must not turn an unanswered Kindi POST into a
                # response that makes clients replay the whole call.
                last_error = f"{entry['server']}: HTTP {upstream_response.status_code}"
                if upstream_response.status_code not in RETRYABLE_STATUS:
                    failed(entry, f"http_{upstream_response.status_code}")
                await upstream_response.aclose()
                continue
            buffered = None
            if upstream_response.status_code == 400 and need.get("tools"):
                # The raw body is inspected as sent. A compressed error body will
                # not match, so it is passed through and nothing is demoted.
                buffered = await _read_raw(upstream_response)
                await upstream_response.aclose()
                if TOOL_REJECTION_RE.search(buffered):
                    # Skip this model for tool requests until the next poll
                    # (which rebuilds the entry) instead of failing every turn.
                    # The last candidate is remembered too; its 400 is returned.
                    entry["tools"] = False
                    failed(entry, "tool_rejection")
                    last_error = f"{entry['server']}: {entry['name']} rejected the tools (HTTP 400)"
                    if not is_last:
                        log.warning("dispatch: %s; trying the next candidate", last_error)
                        continue
                    log.warning("dispatch: %s; no candidates left", last_error)
            kindi_stream = None
            if entry["kind"] == "kindi" and upstream_response.status_code < 400:
                try:
                    raw_stream = upstream_response.aiter_raw()
                    if body.get("stream") is True:
                        first_chunk = await anext(raw_stream, b"")
                        kindi_stream = _relay_kindi_stream(entry["server"], upstream_response,
                                                            first_chunk, raw_stream)
                    else:
                        # The client expects one complete JSON reply. Read every
                        # raw byte before sending 200, so a late read timeout can
                        # still become 424 and the original encoding is preserved.
                        buffered = b"".join([chunk async for chunk in raw_stream])
                        await upstream_response.aclose()
                except httpx.ReadTimeout as exc:
                    last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                    no_reply = True
                    failed(entry, "no_reply")
                    mark_kindi_draining(entry["server"])
                    await upstream_response.aclose()
                    continue
                except httpx.RequestError as exc:
                    last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
                    failed(entry, "transport")
                    mark_server_down(entry["server"], last_error)
                    await upstream_response.aclose()
                    continue
            kept = sticky_choice(affinity) == (entry["server"], entry["name"])
            if upstream_response.status_code < 400:
                remember_choice(affinity, entry)
            log.info("route class=%s code=%s vision=%s tools=%s tokens~%s -> %s @ %s (%d/%d)%s",
                     need["class"], need["code"], need["vision"], need.get("tools", False),
                     need.get("approx_tokens"), entry["name"], entry["server"],
                     position + 1, len(candidates), " same server as last turn" if kept else "")
            router_headers = {
                "X-Router-Model": entry["name"],
                "X-Router-Server": entry["server"],
                "X-Router-Class": need["class"],
                "X-Router-Mode": "discovery",
                "X-Router-Candidates": str(len(candidates)),
            }
            router_headers.update(extra_headers or {})
            if buffered is not None:
                return Response(content=buffered, status_code=upstream_response.status_code,
                                headers=_response_headers(upstream_response, router_headers))
            # The body is still to come: the request counts against the server
            # until it has been relayed.
            slot.streaming = True
            return StreamingResponse(
                _relay_counted(slot, kindi_stream if kindi_stream is not None
                               else upstream_response.aiter_raw()),
                status_code=upstream_response.status_code,
                headers=_response_headers(upstream_response, router_headers),
                background=BackgroundTask(close_upstream, upstream_response, slot),
            )
        finally:
            if not slot.streaming:
                slot.release()
    if no_reply:
        return kindi_no_reply("No usable model target.")
    if kindi_was_busy:
        return JSONResponse({"error": {"message": f"No usable model target. Last error: {last_error}",
                                       "type": "kindi_busy", "code": "kindi_busy"}},
                            status_code=503, headers={"Retry-After": "15"})
    raise HTTPException(status_code=502,
                        detail=f"No usable model target. Last error: {last_error}")


@app.get("/healthz")
async def healthz():
    return JSONResponse({"status": "ok"})


@app.get("/routing/inventory")
async def routing_inventory():
    """What each Ollama target is currently serving, as the router sees it."""
    return JSONResponse({
        "enabled": DISCOVERY_ENABLED,
        "servers": SERVERS,
        "updated_at": INVENTORY.get("updated_at"),
        "age_seconds": round(time.time() - (INVENTORY.get("updated_at") or 0), 1),
        "server_status": INVENTORY.get("servers", {}),
        # Requests this router has in flight per server (others are not seen).
        "in_flight": dict(_IN_FLIGHT),
        "errors": INVENTORY.get("errors", {}),
        "models": INVENTORY.get("models", []),
        # Image models (POST /v1/images/generations), never offered for chat.
        "images": INVENTORY.get("images", []),
        "image_alias": IMAGE_ALIAS,
        # class -> the models assigned to its tier (litellm_config.yaml), which
        # auto and the tier alias spread that class's requests across.
        "tier_models": {cls: sorted(TIER_MEMBERS[cls]) for cls in CLASS_ORDER
                        if cls in TIER_MEMBERS},
        # The direct dispatchers of Hermes, OpenClaw and Honcho compare this
        # with the budget their CT was configured for.
        "kindi_read_timeout_seconds": KINDI_READ_TIMEOUT,
    })


def render_metrics() -> str:
    """Everything /metrics reports, in Prometheus text format (version 0.0.4)."""
    servers = INVENTORY.get("servers", {})
    known = list(dict.fromkeys([*SERVERS, *servers, *_IN_FLIGHT]))
    gauges = {
        "osr_in_flight_requests": [((("server", s),), _IN_FLIGHT.get(s, 0)) for s in known],
        "osr_server_up": [((("kind", "comfyui" if s in COMFYUI_SERVERS else server_kind(s)), ("server", s)),
                           1 if state.get("up") else 0)
                          for s, state in servers.items()],
        "osr_server_models": [((("server", s),), state.get("model_count", 0))
                              for s, state in servers.items()],
        "osr_inventory_age_seconds": ([((), round(time.time() - INVENTORY["updated_at"], 3))]
                                      if INVENTORY.get("updated_at") else []),
        "osr_remembered_conversations": [((), len(_STICKY))],
        "osr_start_time_seconds": [((), round(_STARTED, 3))],
    }
    lines = []
    for name, (kind, text) in METRICS.items():
        lines.append(f"# HELP {name} {text}")
        lines.append(f"# TYPE {name} {kind}")
        if kind == "counter":
            lines += [f"{name}{_label_text(labels)} {_number(value)}"
                      for (metric, labels), value in sorted(_COUNTERS.items()) if metric == name]
        elif kind == "gauge":
            lines += [f"{name}{_label_text(labels)} {_number(value)}" for labels, value in gauges[name]]
        else:
            for (metric, labels), series in sorted(_HISTOGRAMS.items()):
                if metric != name:
                    continue
                running = 0
                for bound, hits in zip(DURATION_BUCKETS, series, strict=False):
                    running += hits
                    upper = 'le="%s"' % _number(bound)
                    lines.append(f"{name}_bucket{_label_text(labels, upper)} {running}")
                upper = 'le="+Inf"'
                lines.append(f"{name}_bucket{_label_text(labels, upper)} {series[-1]}")
                lines.append(f"{name}_sum{_label_text(labels)} {repr(float(series[-2]))}")
                lines.append(f"{name}_count{_label_text(labels)} {series[-1]}")
    return "\n".join(lines) + "\n"


@app.get("/metrics")
async def metrics():
    """Prometheus metrics. Like every path but /healthz it needs the router key:
    the labels name the model servers and models."""
    return Response(render_metrics(), media_type="text/plain; version=0.0.4; charset=utf-8")


@app.post("/routing/refresh")
async def routing_refresh(probe: bool = True):
    """Poll every server now. By default every Ollama model is also asked for
    its capabilities again; ?probe=false keeps the cached /api/show answers,
    for callers that only need to know which servers are up with which models
    (tools/upgrade-all.sh polls this while it waits for a target)."""
    await refresh_inventory(force_probe=probe)
    return await routing_inventory()


@app.post("/routing/explain")
async def routing_explain(request: Request):
    """Show the routing decision for a prompt without executing it."""
    try:
        body = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    messages = body.get("messages")
    if not messages and isinstance(body.get("prompt"), str):
        messages = [{"role": "user", "content": body["prompt"]}]
    need = apply_tool_needs(classify_request(messages or []), body)
    requested = str(body.get("model") or "").strip()
    if requested in TIER_NAMES:
        need = dict(need, **{"class": TIER_NAMES[requested]})
    candidates = rank_candidates(need)
    return JSONResponse({
        "request": need,
        "legacy_tier": analyze_complexity(routing_text(messages or [])),
        "chosen": ({"model": candidates[0]["name"], "server": candidates[0]["server"]}
                   if candidates else None),
        "candidates": [
            {"model": e["name"], "server": e["server"], "params_b": e["params_b"],
             "tools": e.get("tools"), "tiers": tier_classes(e),
             "score": round(score_entry(e, need), 4),
             "in_flight": _IN_FLIGHT.get(e["server"], 0)}
            for e in candidates[:10]
        ],
    })


def _error(status: int, message: str, code: str) -> JSONResponse:
    return JSONResponse({"error": {"message": message, "type": "invalid_request_error",
                                   "code": code}}, status_code=status)


@app.post("/v1/chat/completions")
async def route_chat_completion(request: Request):
    if request.headers.get("x-router-subscription") == "1":
        return await _proxy_subscription(request)
    raw = await request.body()
    try:
        body = json.loads(raw)
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    if not isinstance(body, dict):
        return _error(400, "Request body must be a JSON object.", "invalid_body")
    messages = body.get("messages") or []
    requested = str(body.get("model") or "").strip()
    need = apply_tool_needs(classify_request(messages), body)
    affinity = conversation_keys(messages)

    if requested in CLOUD_MODELS:
        log.info("route explicit cloud model=%s", requested)
        return await _stream_upstream(
            "POST", LITELLM_URL, _forward_headers(request, drop_auth=True),
            json_body=body,
            extra_headers={"X-Router-Mode": "cloud", "X-Router-Model": requested},
        )
    if requested.startswith(FREELLMAPI_PREFIX):
        if not FREELLMAPI_ENABLED:
            return _error(404, f"Model '{requested}' needs FreeLLMAPI, which is not configured "
                          "(manage-model-servers set-freellmapi).", "freellmapi_not_configured")
        upstream_model = requested[len(FREELLMAPI_PREFIX):]
        if not _FREELLMAPI_ID.fullmatch(upstream_model):
            return _error(400, f"'{requested}' is not a FreeLLMAPI model name.",
                          "freellmapi_model_invalid")
        log.info("route explicit freellmapi model=%s", requested)
        headers = _forward_headers(request, drop_auth=True)
        headers.update(freellmapi_headers())
        return await _stream_upstream(
            "POST", f"{FREELLMAPI_BASE}/v1/chat/completions", headers,
            json_body=dict(body, model=upstream_model),
            extra_headers={"X-Router-Mode": "freellmapi", "X-Router-Model": requested},
        )
    if requested.split("/", 1)[0] in CLOUD_PROVIDERS and "/" in requested \
            and not known_chat_model(requested) and not embedding_only_match(requested):
        # Local servers may use the same prefixes (LM Studio lists
        # "openai/gpt-oss-20b"), so only a name no local host knows is refused.
        return _error(404, f"Cloud model '{requested}' is not configured with an API key.",
                      "cloud_model_not_configured")

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        # An explicitly requested real model is honoured; tier aliases and
        # "auto" mean "decide for me".
        candidates, explicit = [], False
        if requested and requested.lower() not in ("auto", "") \
                and requested not in TIER_NAMES:
            candidates = find_named_model(requested, affinity)
            explicit = bool(candidates)
            embedding = None if candidates else embedding_only_match(requested)
            if embedding:
                log.warning("route: %s is embedding-only; rejecting the chat request", embedding)
                return _error(
                    400,
                    f"Model '{embedding}' is an embedding-only model and cannot answer chat "
                    "completions. Send embedding requests to /v1/embeddings, or choose a chat "
                    "model (see /v1/models) or 'auto'.",
                    "embedding_model_not_chat")
        warnings = []
        if requested and not candidates and requested.lower() != "auto" \
                and requested not in TIER_NAMES and known_chat_model(requested):
            # Named, known, but every host serving it is down: answer by
            # content, and say so rather than silently using another model.
            log.warning("route: %s is on no reachable host; routing by content", requested)
            warnings.append("model-unavailable")
        if not candidates:
            if requested in TIER_NAMES:
                need = dict(need, **{"class": TIER_NAMES[requested]})
            candidates = rank_candidates(need, affinity=affinity)
        extra = {}
        if need["vision"] and not explicit and candidates \
                and not any(e["is_vision"] for e in candidates):
            message = ("The request contains an image, but no discovered model "
                       "looks vision-capable (see [discovery] vision_models).")
            if VISION_STRICT:
                return _error(400, message, "no_vision_model")
            log.warning("route: %s Routing to %s anyway.", message, candidates[0]["name"])
            warnings.append("no-vision-model")
        if need["tools"] and not explicit and candidates \
                and all(e.get("tools") is False for e in candidates):
            message = ("The request offers tools, but every discovered model is "
                       "known to lack tool support.")
            if TOOLS_STRICT:
                return _error(400, message, "no_tool_model")
            log.warning("route: %s Routing to %s anyway.", message, candidates[0]["name"])
            warnings.append("no-tool-model")
        if warnings:
            extra["X-Router-Warning"] = ", ".join(warnings)
        if candidates:
            return await _dispatch_direct(
                candidates, body, _forward_headers(request, drop_auth=True),
                need, extra, raw=raw, affinity=affinity)

    # Fallback: the original static path through LiteLLM, which keeps its own
    # latency routing and cross-tier fallbacks.
    tier = _CLASS_TO_TIER[need["class"]]
    body["model"] = globals()[tier]
    log.info("route class=%s -> LiteLLM %s", need["class"], body["model"])
    headers = _forward_headers(request, drop_auth=True)
    if tier_has_kindi(need["class"]):
        # Kindi asks for one retry at most. LiteLLM 1.75 does not read the
        # policy's InternalServerErrorRetries, so this request header caps the
        # retries of every error but a timeout (the policy's 0) at one. A
        # client's own retry or timeout header is dropped; the timeout comes
        # from each deployment (Kindi's follows router.ini), and a request-wide
        # one would also lift LiteLLM's 600 s from the tier's other servers.
        headers = {key: value for key, value in headers.items()
                   if key.lower() not in ("x-litellm-num-retries", "x-litellm-timeout")}
        headers["x-litellm-num-retries"] = "1"
    return await _stream_upstream(
        "POST", LITELLM_URL, headers, json_body=body,
        extra_headers={"X-Router-Mode": "litellm", "X-Router-Model": body["model"]},
        read_timeout=litellm_read_timeout(need["class"]),
        kindi_tier=tier_has_kindi(need["class"]),
    )


def served_contexts(models: list) -> dict:
    """Model name -> the context every server listing it serves (the smallest),
    for /v1/models. A name is left out when any of its servers reports only
    the model's own limit, or nothing: a request may land on that server."""
    found = {}
    for entry in models:
        name, served = entry.get("name"), entry.get("served_context_length")
        if name in found and found[name] is None:
            continue
        found[name] = (None if not served else
                       min(served, found[name]) if found.get(name) else served)
    return {name: value for name, value in found.items() if value}


@app.get("/v1/models")
async def list_models(request: Request):
    """Advertise auto + the tier aliases, then whatever is actually available.

    The aliases are emitted FIRST and UNCONDITIONALLY. They are resolved by the
    router itself, so they must stay selectable in states where nothing
    downstream knows about them:

      * discovery empty -- every Ollama host down, discovery disabled, or the
        first poll still in flight;
      * a tier with no LiteLLM deployment -- which is exactly xlarge until
        servers are assigned to it.

    This path used to return LiteLLM's list verbatim whenever discovery was
    empty. That made the picker mirror litellm_config.yaml, so a tier with no
    deployment never appeared, and a stale alias still in that file was
    advertised as though it were live.
    """
    if request.headers.get("x-router-subscription") == "1":
        return await _proxy_subscription(request)
    seen, data = set(), []
    for alias in ("auto", TIER_FAST, TIER_MEDIUM, TIER_LARGE, TIER_XLARGE):
        if alias and alias not in seen:
            seen.add(alias)
            data.append({"id": alias, "object": "model", "owned_by": "router"})

    for name, provider in CLOUD_MODELS.items():
        # An image model is not a chat model: GET /v1/images/models lists it.
        if name not in seen and not is_cloud_image_model(name):
            seen.add(name)
            data.append({"id": name, "object": "model", "owned_by": provider})

    if FREELLMAPI_ENABLED:
        for name in await freellmapi_models():
            name = FREELLMAPI_PREFIX + name
            if name not in seen:
                seen.add(name)
                data.append({"id": name, "object": "model", "owned_by": "freellmapi"})

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        served = served_contexts(INVENTORY["models"])
        for entry in INVENTORY["models"]:
            if entry["is_embedding"] or entry["name"] in seen:
                continue
            seen.add(entry["name"])
            item = {"id": entry["name"], "object": "model", "owned_by": entry["kind"]}
            if served.get(entry["name"]):
                item["context_length"] = served[entry["name"]]
            data.append(item)
        return JSONResponse({"object": "list", "data": data})

    # Discovery unavailable: supplement the aliases with LiteLLM's own list so
    # real model names are still offered. An alias already emitted is never
    # displaced by a stale entry of the same name.
    try:
        # /v1/models is often just OpenAI's id-only shape. LiteLLM's richer
        # /model/info gives the mode for image deployments with arbitrary
        # public names (for example an admin's "art" alias). Both are asked at
        # once, so a slow LiteLLM costs one DISCOVERY_TIMEOUT, not two.
        forward = _forward_headers(request, drop_auth=True)
        response, details = await asyncio.gather(
            http_client().get(f"{LITELLM_BASE}/v1/models", headers=forward, timeout=DISCOVERY_TIMEOUT),
            http_client().get(f"{LITELLM_BASE}/model/info", headers=forward, timeout=DISCOVERY_TIMEOUT),
            return_exceptions=True)
        if isinstance(response, BaseException):
            raise response
        entries = response.json().get("data") or []
        image_names = set()
        try:
            if isinstance(details, BaseException):
                raise details
            details.raise_for_status()
            for detail in details.json().get("data") or []:
                info = detail.get("model_info") if isinstance(detail, dict) else None
                if isinstance(info, dict) and info.get("mode") == "image_generation":
                    image_names.add(str(detail.get("model_name") or "").lower())
        except (httpx.HTTPError, ValueError, TypeError, AttributeError):
            log.debug("model list: LiteLLM model modes unavailable; using listed metadata and names")
        for entry in entries:
            name = str(entry.get("id") or "").strip()
            info = entry.get("model_info") or {}
            mode = entry.get("mode") or (info.get("mode") if isinstance(info, dict) else None)
            if name and name not in seen and mode != "image_generation" and name.lower() not in image_names \
                    and not CLOUD_IMAGE_NAME.search(name) and not any(
                    image["name"].lower() == name.lower() for image in INVENTORY.get("images", [])):
                seen.add(name)
                data.append({"id": name, "object": "model", "owned_by": "litellm"})
    except Exception as exc:  # noqa: BLE001 - the alias list must still be served
        log.warning("model list: LiteLLM unreachable (%s); serving aliases only", exc)
    return JSONResponse({"object": "list", "data": data})


# --- image generation ---------------------------------------------------------------
class ImageFailure(Exception):
    """An image server could not answer. retry: try the next one; down: also
    take this server out of rotation until the next poll."""

    def __init__(self, status: int, message: str, code: str, retry: bool = True, down: bool = False,
                 response: Response = None):
        super().__init__(message)
        self.status, self.message, self.code = status, message, code
        self.retry, self.down, self.response = retry, down, response


def image_candidates(requested: str) -> list:
    """The image models that can answer, best first: the alias takes every one
    that is up, [images] prefer's kinds first, then the least busy; a name takes
    its own copies the same way."""
    servers = INVENTORY.get("servers", {})
    up = [e for e in INVENTORY.get("images", []) if servers.get(e["server"], {}).get("up", True)]
    wanted = requested.lower()
    if wanted != IMAGE_ALIAS.lower():
        up = [e for e in up if e["name"].lower() == wanted]
    rank = {kind: index for index, kind in enumerate(IMAGE_PREFER)}
    return sorted(up, key=lambda e: (rank.get(e["kind"], len(rank)), _IN_FLIGHT.get(e["server"], 0)))


def known_image_model(requested: str) -> bool:
    wanted = requested.lower()
    return wanted == IMAGE_ALIAS.lower() or any(e["name"].lower() == wanted
                                                for e in INVENTORY.get("images", []))


def image_size(body: dict, multiple: int) -> tuple:
    """(width, height) the request asks for, each rounded to the server's
    multiple within 256-2048; (0, 0) when it gives none (the server's default)."""
    size = body.get("size")
    if size in (None, "", "auto"):
        width, height = body.get("width"), body.get("height")
        if width is None and height is None:
            return 0, 0
    elif isinstance(size, str) and re.fullmatch(r"[1-9][0-9]{1,4}x[1-9][0-9]{1,4}", size):
        width, height = (int(part) for part in size.split("x"))
    else:
        raise ValueError("`size` must be WIDTHxHEIGHT, e.g. 1024x1024.")
    if not all(isinstance(v, int) and not isinstance(v, bool) and v > 0 for v in (width, height)):
        raise ValueError("`width` and `height` must be positive integers.")
    return tuple(min(2048, max(256, int(v / multiple + 0.5) * multiple)) for v in (width, height))


def image_payload(images: list, extra: dict = None) -> dict:
    return {"created": int(time.time()),
            "data": [{"b64_json": b64, "revised_prompt": None} for b64 in images], **(extra or {})}


async def openai_image(entry: dict, body: dict, n: int, request_headers: dict,
                       request: Request | None = None) -> Response:
    """Colibri (any /v1/models server that declares image_generation): its own
    OpenAI images API, one image per request, b64_json. A client that has gone
    gets no further images drawn for it."""
    server = entry["server"]
    url = f"{server_base(server)}/v1/images/generations"
    headers = dict(request_headers, **backend_headers(server))
    width, height = image_size(body, 32)
    upstream = {k: v for k, v in body.items() if k not in ("size", "width", "height", "user")}
    upstream.update(model=entry["name"], n=1, response_format="b64_json")
    if width:
        upstream["size"] = f"{width}x{height}"
    extra = {"X-Router-Mode": "image", "X-Router-Model": entry["name"], "X-Router-Server": server}
    if body.get("stream") is True:
        if n != 1:
            raise ImageFailure(400, "A streamed image request takes n=1.", "invalid_value", retry=False)
        return await _stream_upstream("POST", url, headers, json_body=upstream,
                                      extra_headers=extra, read_timeout=IMAGE_READ_TIMEOUT)
    drawn, last = [], None
    for index in range(n):
        if index and request is not None and await request.is_disconnected():
            raise ImageFailure(499, "Client disconnected before the images were ready",
                               "client_disconnected", retry=False)
        slot = InFlight(server)
        try:
            response = await http_client().post(
                url, json=upstream, headers=headers,
                timeout=httpx.Timeout(IMAGE_READ_TIMEOUT, connect=CONNECT_TIMEOUT))
        except httpx.ConnectError as exc:
            raise ImageFailure(502, f"{server}: {exc}", "connect", down=True) from exc
        except httpx.RequestError as exc:
            raise ImageFailure(502, f"{server}: {type(exc).__name__}: {exc}", "transport") from exc
        finally:
            slot.release()
        if response.status_code >= 400:
            failure = Response(response.content, status_code=response.status_code,
                               headers=_response_headers(response, extra))
            # 503 is Colibri's full queue (one image at a time): another server may be free.
            raise ImageFailure(response.status_code, f"{server}: HTTP {response.status_code}",
                               f"http_{response.status_code}",
                               retry=response.status_code in RETRYABLE_STATUS, response=failure)
        try:
            last = response.json()
            drawn.extend(item["b64_json"] for item in last["data"])
        except (ValueError, KeyError, TypeError) as exc:
            raise ImageFailure(502, f"{server}: not an images answer ({exc})", "no_reply") from exc
    extra_fields = {"colibri": last["colibri"]} if n == 1 and isinstance(last.get("colibri"), dict) else {}
    return JSONResponse(image_payload(drawn, extra_fields), headers=extra)


_COMFYUI_CANCELS: set = set()   # background cancels; a bare create_task() can be garbage-collected


async def comfyui_cancel(client: httpx.AsyncClient, server: str, prompt_id: str) -> None:
    """Cancel one ComfyUI job by id: POST /api/jobs/{id}/cancel dequeues it if
    pending and interrupts it only if it is the one running. /interrupt would
    stop whichever user's job happens to be running now."""
    try:
        response = await client.post(f"{server}/api/jobs/{prompt_id}/cancel", timeout=DISCOVERY_TIMEOUT)
    except (httpx.HTTPError, RuntimeError) as exc:   # RuntimeError: the client closed at shutdown
        log.warning("image: could not cancel ComfyUI job %s on %s (%s); it may still draw",
                    prompt_id, server, exc)
        return
    if response.status_code >= 400:
        log.warning("image: %s did not cancel job %s: HTTP %s (a ComfyUI without /api/jobs?); "
                    "it may still draw", server, prompt_id, response.status_code)


async def comfyui_image(entry: dict, body: dict, n: int, request: Request) -> Response:
    """ComfyUI: the variant's Klein workflow with the prompt, size, steps and
    seed filled in, queued, polled until done, and its pictures fetched."""
    import base64
    import copy
    server = entry["server"]
    extra = {"X-Router-Mode": "image", "X-Router-Model": entry["name"], "X-Router-Server": server}
    if body.get("stream") is True:
        raise ImageFailure(400, "ComfyUI images are not streamed.", "invalid_value")
    width, height = image_size(body, 16)
    workflow = copy.deepcopy(COMFYUI_VARIANTS[entry["variant"]]["workflow"])
    width, height = width or workflow["6"]["inputs"]["width"], height or workflow["6"]["inputs"]["height"]
    steps = body.get("steps", workflow["7"]["inputs"]["steps"])
    seed = body.get("seed")
    if not isinstance(steps, int) or isinstance(steps, bool) or not 1 <= steps <= 200:
        raise ImageFailure(400, "`steps` must be an integer from 1 to 200.", "invalid_value", retry=False)
    if seed is None:
        seed = secrets.randbelow(2 ** 32)
    elif not isinstance(seed, int) or isinstance(seed, bool) or not 0 <= seed < 2 ** 64:
        raise ImageFailure(400, "`seed` must be a non-negative integer.", "invalid_value", retry=False)
    workflow["4"]["inputs"]["text"] = str(body.get("prompt") or "")
    workflow["6"]["inputs"].update(width=width, height=height, batch_size=n)
    workflow["7"]["inputs"].update(steps=steps, width=width, height=height)
    workflow["8"]["inputs"]["noise_seed"] = seed
    client = http_client()
    slot = InFlight(server)
    prompt_id = ""
    settled = False   # the job finished, failed or was cancelled: nothing left to cancel
    try:
        try:
            queued = await client.post(f"{server}/prompt", timeout=DISCOVERY_TIMEOUT,
                                       json={"prompt": workflow, "client_id": f"osr-router-{request_id()}"})
            if queued.status_code >= 400:
                raise ImageFailure(502, f"{server}: ComfyUI refused the workflow: HTTP {queued.status_code} "
                                   f"{queued.text[:300]}", f"http_{queued.status_code}")
            prompt_id = str(queued.json()["prompt_id"])
            deadline = time.monotonic() + IMAGE_READ_TIMEOUT
            while True:
                await asyncio.sleep(COMFYUI_POLL_SECONDS)
                if await request.is_disconnected():
                    raise ImageFailure(499, "Client disconnected before the image was ready",
                                       "client_disconnected", retry=False)
                history = (await client.get(f"{server}/history/{prompt_id}",
                                            timeout=DISCOVERY_TIMEOUT)).json().get(prompt_id)
                if isinstance(history, dict):
                    status = history.get("status") or {}
                    if status.get("status_str") == "error":
                        settled = True
                        raise ImageFailure(502, f"{server}: ComfyUI failed the job: "
                                           f"{json.dumps(status.get('messages'))[:300]}", "engine_error")
                    if status.get("completed", bool(history.get("outputs"))):
                        settled = True
                        break
                if time.monotonic() > deadline:
                    await comfyui_cancel(client, server, prompt_id)
                    settled = True
                    raise ImageFailure(504, f"{server}: no picture within {IMAGE_READ_TIMEOUT:g} s "
                                       "([images] read_timeout_seconds)", "timeout", retry=False)
            drawn = []
            for output in (history.get("outputs") or {}).values():
                for image in (output or {}).get("images") or []:
                    if image.get("type", "output") != "output":
                        continue
                    picture = await client.get(f"{server}/view", timeout=DISCOVERY_TIMEOUT, params={
                        "filename": image["filename"], "subfolder": image.get("subfolder", ""),
                        "type": "output"})
                    picture.raise_for_status()
                    drawn.append(base64.b64encode(picture.content).decode("ascii"))
        except httpx.ConnectError as exc:
            raise ImageFailure(502, f"{server}: {exc}", "connect", down=not prompt_id) from exc
        except (httpx.HTTPError, ValueError, KeyError, TypeError, AttributeError) as exc:
            raise ImageFailure(502, f"{server}: {type(exc).__name__}: {exc}", "transport") from exc
    finally:
        slot.release()
        if prompt_id and not settled:
            # A poll that failed, or a caller that went away (CancelledError),
            # would leave the job drawing for nobody. Cancel it in a task of
            # its own, which still runs when this one is being cancelled.
            task = asyncio.create_task(comfyui_cancel(client, server, prompt_id))
            _COMFYUI_CANCELS.add(task)
            task.add_done_callback(_COMFYUI_CANCELS.discard)
    if not drawn:
        raise ImageFailure(502, f"{server}: ComfyUI finished without a picture", "no_reply")
    return JSONResponse(image_payload(drawn, {"comfyui": {"width": width, "height": height,
                                                          "seed": seed, "steps": steps}}),
                        headers=extra)


@app.post("/v1/images/generations")
async def route_image_generation(request: Request):
    """Pictures from the image servers the router knows (the alias picks one;
    a name asks for that model), or from LiteLLM for a cloud image model or a
    name the router does not know."""
    if request.headers.get("x-router-subscription") == "1":
        return await _proxy_subscription(request)
    raw = await request.body()
    try:
        body = json.loads(raw)
    except ValueError:
        return _error(400, "Invalid JSON body.", "invalid_body")
    if not isinstance(body, dict):
        return _error(400, "Request body must be a JSON object.", "invalid_body")
    requested = str(body.get("model") or "").strip() or IMAGE_ALIAS
    if requested in CLOUD_MODELS or not known_image_model(requested):
        # Cloud models only when named; any other name is LiteLLM's to answer.
        mode = "cloud" if requested in CLOUD_MODELS else "litellm"
        return await _stream_upstream(
            "POST", f"{LITELLM_BASE}/v1/images/generations", _forward_headers(request, drop_auth=True),
            content=raw, read_timeout=IMAGE_READ_TIMEOUT,
            extra_headers={"X-Router-Mode": mode, **({"X-Router-Model": requested} if mode == "cloud" else {})})
    prompt = body.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return _error(400, "`prompt` must be a non-empty string.", "invalid_value")
    n = body.get("n", 1)
    if not isinstance(n, int) or isinstance(n, bool) or not 1 <= n <= IMAGE_MAX_N:
        return _error(400, f"`n` must be an integer from 1 to {IMAGE_MAX_N} ([images] max_n).",
                      "invalid_value")
    try:
        image_size(body, 16)
    except ValueError as exc:
        return _error(400, str(exc), "invalid_value")
    candidates = image_candidates(requested)
    if body.get("stream") is True:
        candidates = [e for e in candidates if e["kind"] != "comfyui"]
    if not candidates:
        return _error(503, f"No image server for '{requested}' is up"
                      + (" that streams (Colibri)" if body.get("stream") is True else "")
                      + "; see GET /routing/inventory.", "no_image_server")
    headers = {"X-Request-ID": request_id()} if request_id() else {}
    last = None
    for entry in candidates:
        try:
            if entry["kind"] == "comfyui":
                return await comfyui_image(entry, body, n, request)
            return await openai_image(entry, body, n, headers, request)
        except ImageFailure as failure:
            if failure.code == "client_disconnected":
                # The client left; the server did nothing wrong, so it is not counted against it.
                log.info("image: %s on %s: %s", entry["name"], entry["server"], failure.message)
                return failure.response or _error(failure.status, failure.message, failure.code)
            count("osr_upstream_failures_total", server=entry["server"], reason=failure.code)
            log.warning("image: %s on %s failed (%s)", entry["name"], entry["server"], failure.message)
            if failure.down:
                mark_server_down(entry["server"], failure.message)
            if not failure.retry:
                return failure.response or _error(failure.status, failure.message, failure.code)
            last = failure
    if last is not None and last.response is not None:
        return last.response
    return _error(502, f"Every image server failed; the last: {last.message}", "image_servers_failed")


@app.get("/v1/images/models")
async def list_image_models():
    """What /v1/images/generations can draw with: the alias when an image
    server is up, every image model, and the configured cloud image models."""
    data, seen = [], set()
    if image_candidates(IMAGE_ALIAS):
        data.append({"id": IMAGE_ALIAS, "object": "model", "owned_by": "router"})
        seen.add(IMAGE_ALIAS)
    rank = {kind: index for index, kind in enumerate(IMAGE_PREFER)}
    available = [entry for entry in INVENTORY.get("images", [])
                 if INVENTORY.get("servers", {}).get(entry["server"], {}).get("up", True)]
    for entry in sorted(available, key=lambda e: rank.get(e["kind"], len(rank))):
        if entry["name"] not in seen:
            seen.add(entry["name"])
            data.append({"id": entry["name"], "object": "model", "owned_by": entry["kind"]})
    for name, provider in CLOUD_MODELS.items():
        if is_cloud_image_model(name) and name not in seen:
            seen.add(name)
            data.append({"id": name, "object": "model", "owned_by": provider})
    return JSONResponse({"object": "list", "data": data})


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def proxy_openai(path: str, request: Request):
    if request.headers.get("x-router-subscription") == "1":
        return await _proxy_subscription(request)
    # Transparent passthrough for all other OpenAI routes (embeddings, etc.).
    url = f"{LITELLM_BASE}/v1/{path}"
    if request.url.query:
        url = f"{url}?{request.url.query}"
    raw = await request.body()
    return await _stream_upstream(
        request.method, url, _forward_headers(request, drop_auth=True),
        content=raw or None
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host=ROUTER_HOST, port=ROUTER_PORT)
