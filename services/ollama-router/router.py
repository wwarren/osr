import asyncio
import configparser
import hmac
import ipaddress
import json
import logging
import os
import re
import time
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request
from starlette.background import BackgroundTask
from fastapi.responses import StreamingResponse, JSONResponse

logging.basicConfig(level=os.getenv("ROUTER_LOG_LEVEL", "INFO").upper(),
                    format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("router")
# httpx logs every request at INFO; the router logs its own decisions instead.
logging.getLogger("httpx").setLevel(logging.WARNING)

# The router is a drop-in OpenAI endpoint in front of the LiteLLM proxy.
# /v1/chat/completions has its model chosen by complexity analysis; every other
# /v1/* path (notably /v1/models, which Open WebUI calls to populate its model
# list) is proxied through unchanged.
LITELLM_BASE = os.getenv("LITELLM_BASE_URL", "http://127.0.0.1:4000").rstrip("/")
LITELLM_URL = os.getenv("LITELLM_URL", f"{LITELLM_BASE}/v1/chat/completions")

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
    },
    "http": {
        # Seconds to establish a TCP connection to a backend. Short on purpose:
        # this is how long a dead host delays failover to the next candidate.
        "connect_timeout_seconds": "3",
        # Seconds allowed between bytes of a response (generation can be slow).
        "read_timeout_seconds": "300",
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
        # LM Studio servers (MODEL_SERVERS entries written lmstudio+http://...)
        # load models on demand. true: only route to models already loaded
        # there (no multi-second JIT load on the request path).
        "lmstudio_loaded_only": "false",
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
        # Bonus for a model that is already resident in memory (LM Studio
        # reports this per model; Ollama entries are neutral).
        "loaded_bonus": "0.1",
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

DISCOVERY_ENABLED = _cfg.getboolean("discovery", "enabled")
DISCOVERY_REFRESH = _cfg.getint("discovery", "refresh_seconds")
DISCOVERY_TIMEOUT = _cfg.getfloat("discovery", "timeout_seconds")
CAPABILITY_PROBE = _cfg.getboolean("discovery", "capability_probe")
LMSTUDIO_LOADED_ONLY = _cfg.getboolean("discovery", "lmstudio_loaded_only")
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

# --- server kinds -----------------------------------------------------------------
# A server entry is a base URL. An LM Studio server is written with a scheme
# prefix -- lmstudio+http://host:1234 -- so the one MODEL_SERVERS / BACKEND_*
# list can mix both kinds and every consumer (router, monitor, manage tool,
# LiteLLM config) knows how to talk to each entry.
LMSTUDIO_PREFIX = "lmstudio+"
# Optional bearer token for LM Studio servers with authentication enabled
# (LM Studio 0.4+ "Require authentication"). Lives in secrets.env.
LMSTUDIO_API_TOKEN = (os.getenv("LMSTUDIO_API_TOKEN") or "").strip()


def server_kind(server: str) -> str:
    return "lmstudio" if server.startswith(LMSTUDIO_PREFIX) else "ollama"


def server_base(server: str) -> str:
    """The plain http(s) base URL of a server entry."""
    return server[len(LMSTUDIO_PREFIX):] if server.startswith(LMSTUDIO_PREFIX) else server


def backend_headers(server: str) -> dict:
    """Credentials the ROUTER adds for a backend (never the client's own)."""
    if server_kind(server) == "lmstudio" and LMSTUDIO_API_TOKEN:
        return {"Authorization": f"Bearer {LMSTUDIO_API_TOKEN}"}
    return {}

CLASSIFY_SCOPE = _cfg.get("classification", "scope").strip().lower()
VISION_STRICT = _cfg.getboolean("classification", "vision_strict")
CONNECT_TIMEOUT = _cfg.getfloat("http", "connect_timeout_seconds")
READ_TIMEOUT = _cfg.getfloat("http", "read_timeout_seconds")

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
    """Ollama base URLs to poll, in order of preference:
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

# --- live inventory -----------------------------------------------------------
# Replaced wholesale on each refresh, so readers never see a half-built dict.
INVENTORY = {"models": [], "servers": {}, "updated_at": 0.0, "errors": {}}
_rotation = {}


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
        # True/False when the server reports residency (LM Studio); None
        # when it does not (Ollama loads on demand and is not asked).
        "loaded": raw.get("loaded"),
        "kind": server_kind(server),
    }


# (server, model name, digest) -> capability list, or None when the server
# does not report one. Keyed by digest so a re-pulled model is re-probed.
_CAPABILITIES = {}


async def model_capabilities(client: httpx.AsyncClient, server: str, raw: dict,
                             limit: asyncio.Semaphore = None):
    """Ollama's capability list for one model via POST /api/show, cached."""
    name = raw.get("name") or raw.get("model") or ""
    key = (server, name, raw.get("digest") or raw.get("modified_at") or "")
    if key in _CAPABILITIES:
        return _CAPABILITIES[key]
    caps = None
    try:
        async with (limit or asyncio.Semaphore(1)):
            response = await client.post(f"{server}/api/show", json={"model": name},
                                         timeout=DISCOVERY_TIMEOUT)
        if response.status_code == 200:
            found = response.json().get("capabilities")
            if isinstance(found, list):
                caps = [str(c) for c in found]
        # Only a definite answer is cached; a transient failure is retried
        # on the next poll.
        if response.status_code in (200, 400, 404, 405, 501):
            _CAPABILITIES[key] = caps
    except (httpx.HTTPError, ValueError, AttributeError):
        pass
    return caps


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
        if features.get("trained_for_tool_use"):
            caps.append("tools")
        quant = m.get("quantization") or {}
        out.append({
            "name": m["key"],
            "size": m.get("size_bytes") or 0,
            "details": {"parameter_size": m.get("params_string") or "",
                        "family": m.get("architecture") or "",
                        "quantization_level": quant.get("name") if isinstance(quant, dict) else quant},
            "capabilities": caps,
            "loaded": bool(m.get("loaded_instances")),
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


async def fetch_server_models(client: httpx.AsyncClient, server: str) -> tuple:
    if server_kind(server) == "lmstudio":
        return await fetch_lmstudio_models(client, server)
    try:
        response = await client.get(f"{server}/api/tags", timeout=DISCOVERY_TIMEOUT)
        response.raise_for_status()
        payload = response.json()
    except Exception as exc:  # noqa: BLE001 - any failure means "server is down"
        return server, None, f"{type(exc).__name__}: {exc}"
    raws = [m for m in (payload.get("models") or []) if isinstance(m, dict)]
    if CAPABILITY_PROBE:
        limit = asyncio.Semaphore(8)   # per poll, so no cross-event-loop state
        caps = await asyncio.gather(*[model_capabilities(client, server, m, limit)
                                      for m in raws])
    else:
        caps = [None] * len(raws)
    entries = [build_entry(server, m, c) for m, c in zip(raws, caps, strict=True)]
    return server, [e for e in entries if e["name"]], None


async def refresh_inventory() -> dict:
    """Poll every Ollama target for the models it is currently serving."""
    global INVENTORY
    if not SERVERS:
        INVENTORY = {"models": [], "servers": {}, "updated_at": time.time(),
                     "errors": {"config": "no servers configured"}}
        return INVENTORY
    results = await asyncio.gather(
        *[fetch_server_models(http_client(), s) for s in SERVERS],
        return_exceptions=True,
    )
    models, servers, errors = [], {}, {}
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
        servers[server] = {"up": True, "model_count": len(entries)}
        models.extend(entries)
    INVENTORY = {"models": models, "servers": servers,
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
    if DISCOVERY_ENABLED and SERVERS:
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
        if _HTTP["client"] is not None:
            await _HTTP["client"].aclose()
            _HTTP["client"] = None


app = FastAPI(title="Intelligent Ollama Complexity Router", lifespan=lifespan)


@app.middleware("http")
async def require_api_key(request: Request, call_next):
    if ROUTER_API_KEY and request.url.path != "/healthz":
        supplied = request.headers.get("authorization", "")
        token = supplied[7:].strip() if supplied.lower().startswith("bearer ") else ""
        if not hmac.compare_digest(token.encode(), ROUTER_API_KEY.encode()):
            return JSONResponse(
                {"error": {"message": "Missing or invalid router API key.",
                           "type": "invalid_request_error",
                           "code": "invalid_api_key"}},
                status_code=401)
    return await call_next(request)


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
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    return entry["params_b"] > 0 and _in_band(entry["params_b"], low, high)


def score_entry(entry: dict, need: dict) -> float:
    """Heuristic fit of one discovered (server, model) pair to one request."""
    low, high = BANDS.get(need["class"], (0.0, 999.0))
    params = entry["params_b"]
    in_band = _in_band(params, low, high)
    if params <= 0:
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
    if params > 0 and in_band:
        span = high - low
        position = (params - low) / span if span > 0 else 1.0
        position = max(0.0, min(position, 1.0))
        if need["class"] in ("large", "xlarge"):
            score += W_LARGER * position
        elif need["class"] == "fast":
            score += W_SMALLER * (1.0 - position)
    if entry.get("loaded"):
        score += W_LOADED
    return score


def rank_candidates(need: dict, inventory: dict = None) -> list:
    """All usable (server, model) pairs, best first."""
    inv = inventory if inventory is not None else INVENTORY
    scored = []
    for entry in inv.get("models", []):
        if entry["is_embedding"]:
            continue  # embedding models cannot serve chat completions
        if not inv.get("servers", {}).get(entry["server"], {}).get("up", True):
            continue
        if LMSTUDIO_LOADED_ONLY and entry.get("loaded") is False:
            continue  # would trigger a just-in-time load on LM Studio
        scored.append((score_entry(entry, need), entry))
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
    tied, rest = [], []
    for s_val, e in scored:
        if _distance(e) == best_distance and best_score - s_val <= TIE_EPSILON:
            tied.append(e)
        else:
            rest.append(e)
    if len(tied) > 1:
        key = f"{need['class']}|{need['code']}|{need['vision']}"
        index = _rotation.get(key, 0) % len(tied)
        _rotation[key] = index + 1
        tied = tied[index:] + tied[:index]
    return tied + rest


def find_named_model(model_name: str) -> list:
    """Servers hosting an explicitly requested model, best first."""
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
    return matches


def embedding_only_match(model_name: str):
    """The inventory name when an explicitly requested model exists ONLY as an
    embedding model (exact name first, then the bare name without its tag);
    None when it is unknown or any host serves it for chat.

    Such a request cannot be answered by the chat endpoint. Rerouting it to
    some other chat model would silently answer with a model the client did
    not ask for, so the caller rejects it instead.
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


# --- proxying -----------------------------------------------------------------
def _forward_headers(request: Request, drop_auth: bool = False) -> dict:
    """Request headers to send upstream. drop_auth strips Authorization, so the
    router's own API key is never handed to an Ollama host."""
    return {k: v for k, v in request.headers.items()
            if k.lower() not in HOP_BY_HOP
            and not (drop_auth and k.lower() == "authorization")}


def _response_headers(upstream: httpx.Response, extra: dict = None) -> dict:
    headers = {k: v for k, v in upstream.headers.items()
               if k.lower() not in RESPONSE_HOP_BY_HOP}
    if extra:
        headers.update(extra)
    return headers


async def close_upstream(response: httpx.Response) -> None:
    await response.aclose()


async def _stream_upstream(method: str, url: str, headers: dict,
                           json_body=None, content=None,
                           extra_headers: dict = None) -> StreamingResponse:
    client = http_client()
    try:
        upstream_request = client.build_request(
            method, url, headers=headers, json=json_body, content=content
        )
        upstream_response = await client.send(upstream_request, stream=True)
    except httpx.RequestError as exc:
        raise HTTPException(status_code=502, detail=f"Router core disconnect: {exc}") from exc
    return StreamingResponse(
        upstream_response.aiter_raw(),
        status_code=upstream_response.status_code,
        headers=_response_headers(upstream_response, extra_headers),
        background=BackgroundTask(close_upstream, upstream_response),
    )


# Upstream statuses that mean "try the next candidate": the host is failing
# (5xx) or no longer has the model (404, e.g. removed since the last poll).
RETRYABLE_STATUS = {404} | set(range(500, 600))


async def _dispatch_direct(candidates: list, body: dict, headers: dict,
                           need: dict, extra_headers: dict = None) -> StreamingResponse:
    """Send to the best candidate, falling forward through the ranked list on
    connection errors, 404 or 5xx. Retrying is only safe before any body has
    been streamed, which is why the status is checked before returning. A host
    that refuses or times out the CONNECTION is marked down immediately so the
    next request skips it too."""
    client = http_client()
    last_error = None
    for position, entry in enumerate(candidates):
        if not INVENTORY.get("servers", {}).get(entry["server"], {}).get("up", True):
            last_error = f"{entry['server']}: marked down"
            continue
        attempt_body = dict(body)
        attempt_body["model"] = entry["name"]
        url = f"{server_base(entry['server'])}/v1/chat/completions"
        try:
            upstream_request = client.build_request(
                "POST", url, headers=dict(headers, **backend_headers(entry["server"])),
                json=attempt_body
            )
            upstream_response = await client.send(upstream_request, stream=True)
        except (httpx.ConnectError, httpx.ConnectTimeout) as exc:
            last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
            mark_server_down(entry["server"], last_error)
            continue
        except httpx.RequestError as exc:
            last_error = f"{entry['server']}: {type(exc).__name__}: {exc}"
            log.warning("dispatch: %s", last_error)
            continue
        is_last = position == len(candidates) - 1
        if upstream_response.status_code in RETRYABLE_STATUS and not is_last:
            await upstream_response.aclose()
            last_error = f"{entry['server']}: HTTP {upstream_response.status_code}"
            log.warning("dispatch: %s for %s; trying the next candidate",
                        last_error, entry["name"])
            continue
        log.info("route class=%s code=%s vision=%s tokens~%s -> %s @ %s (%d/%d)",
                 need["class"], need["code"], need["vision"],
                 need.get("approx_tokens"), entry["name"], entry["server"],
                 position + 1, len(candidates))
        router_headers = {
            "X-Router-Model": entry["name"],
            "X-Router-Server": entry["server"],
            "X-Router-Class": need["class"],
            "X-Router-Mode": "discovery",
            "X-Router-Candidates": str(len(candidates)),
        }
        router_headers.update(extra_headers or {})
        return StreamingResponse(
            upstream_response.aiter_raw(),
            status_code=upstream_response.status_code,
            headers=_response_headers(upstream_response, router_headers),
            background=BackgroundTask(close_upstream, upstream_response),
        )
    raise HTTPException(status_code=502,
                        detail=f"No usable Ollama target. Last error: {last_error}")


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
        "errors": INVENTORY.get("errors", {}),
        "models": INVENTORY.get("models", []),
    })


@app.post("/routing/refresh")
async def routing_refresh():
    await refresh_inventory()
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
    need = classify_request(messages or [])
    candidates = rank_candidates(need)
    return JSONResponse({
        "request": need,
        "legacy_tier": analyze_complexity(routing_text(messages or [])),
        "chosen": ({"model": candidates[0]["name"], "server": candidates[0]["server"]}
                   if candidates else None),
        "candidates": [
            {"model": e["name"], "server": e["server"], "params_b": e["params_b"],
             "score": round(score_entry(e, need), 4)}
            for e in candidates[:10]
        ],
    })


def _error(status: int, message: str, code: str) -> JSONResponse:
    return JSONResponse({"error": {"message": message, "type": "invalid_request_error",
                                   "code": code}}, status_code=status)


@app.post("/v1/chat/completions")
async def route_chat_completion(request: Request):
    try:
        body = await request.json()
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from exc
    if not isinstance(body, dict):
        return _error(400, "Request body must be a JSON object.", "invalid_body")
    messages = body.get("messages") or []
    requested = str(body.get("model") or "").strip()
    need = classify_request(messages)

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        # An explicitly requested real model is honoured; tier aliases and
        # "auto" mean "decide for me".
        candidates, explicit = [], False
        if requested and requested.lower() not in ("auto", "") \
                and requested not in TIER_NAMES:
            candidates = find_named_model(requested)
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
        if not candidates:
            if requested in TIER_NAMES:
                need = dict(need, **{"class": TIER_NAMES[requested]})
            candidates = rank_candidates(need)
        extra = {}
        if need["vision"] and not explicit and candidates \
                and not any(e["is_vision"] for e in candidates):
            message = ("The request contains an image, but no discovered model "
                       "looks vision-capable (see [discovery] vision_models).")
            if VISION_STRICT:
                return _error(400, message, "no_vision_model")
            log.warning("route: %s Routing to %s anyway.", message, candidates[0]["name"])
            extra["X-Router-Warning"] = "no-vision-model"
        if candidates:
            return await _dispatch_direct(
                candidates, body, _forward_headers(request, drop_auth=True),
                need, extra)

    # Fallback: the original static path through LiteLLM, which keeps its own
    # latency routing and cross-tier fallbacks.
    body["model"] = globals()[_CLASS_TO_TIER[need["class"]]]
    log.info("route class=%s -> LiteLLM %s", need["class"], body["model"])
    return await _stream_upstream(
        "POST", LITELLM_URL, _forward_headers(request, drop_auth=True), json_body=body,
        extra_headers={"X-Router-Mode": "litellm", "X-Router-Model": body["model"]},
    )


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
    seen, data = set(), []
    for alias in ("auto", TIER_FAST, TIER_MEDIUM, TIER_LARGE, TIER_XLARGE):
        if alias and alias not in seen:
            seen.add(alias)
            data.append({"id": alias, "object": "model", "owned_by": "router"})

    if DISCOVERY_ENABLED and INVENTORY.get("models"):
        for entry in INVENTORY["models"]:
            if entry["is_embedding"] or entry["name"] in seen:
                continue
            seen.add(entry["name"])
            data.append({"id": entry["name"], "object": "model", "owned_by": "ollama"})
        return JSONResponse({"object": "list", "data": data})

    # Discovery unavailable: supplement the aliases with LiteLLM's own list so
    # real model names are still offered. An alias already emitted is never
    # displaced by a stale entry of the same name.
    try:
        response = await http_client().get(
            f"{LITELLM_BASE}/v1/models",
            headers=_forward_headers(request, drop_auth=True),
            timeout=DISCOVERY_TIMEOUT)
        for entry in (response.json().get("data") or []):
            name = str(entry.get("id") or "").strip()
            if name and name not in seen:
                seen.add(name)
                data.append({"id": name, "object": "model", "owned_by": "litellm"})
    except Exception as exc:  # noqa: BLE001 - the alias list must still be served
        log.warning("model list: LiteLLM unreachable (%s); serving aliases only", exc)
    return JSONResponse({"object": "list", "data": data})


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def proxy_openai(path: str, request: Request):
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
