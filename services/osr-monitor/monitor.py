"""Health monitor for the smart-router stack.

Watches every model host the router can route to (MODEL_SERVERS plus the
per-tier BACKEND_* lists) and the three local services (LiteLLM, the router,
Open WebUI), and posts state changes to Mattermost.

  * Probes run in parallel, so one dead host cannot stretch the cycle.
  * A state change is only reported after N consecutive failed (or passed)
    checks, so a single dropped probe does not page anyone.
  * One alert per HOST, naming every tier it serves -- not one per tier.
  * An alert that fails to deliver is retried every cycle until it lands.
  * Keep-alive pinning runs in its own thread: loading a cold model can take
    minutes and must never delay health checks.
"""
import configparser
import logging
import os
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import httpx

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

MATTERMOST_WEBHOOK_URL = os.getenv("MATTERMOST_WEBHOOK_URL")
MATTERMOST_USER = os.getenv("MATTERMOST_MONITOR_USER", "OSRMonitor")
MATTERMOST_CHANNEL = os.getenv("MATTERMOST_CHANNEL", "osr-monitor")
MATTERMOST_VERIFY_TLS = os.getenv("MATTERMOST_VERIFY_TLS", "true").lower() == "true"

# Polling behaviour comes from monitor.ini (version controlled). An environment
# variable of the names in ENV_OVERRIDES still wins when it is set to a value,
# so an operator can override one without a commit; the overrides that differ
# from monitor.ini are logged at start, so none is in force unnoticed.
_DEFAULTS = {
    "polling": {"interval_seconds": "15", "timeout_seconds": "5",
                "health_path": "/api/tags"},
    "alerting": {"fail_threshold": "3", "recover_threshold": "2"},
    "startup": {"notice_interval_seconds": "3600"},
    "local_services": {
        "enabled": "true",
        "litellm-proxy": "http://127.0.0.1:4000/health/liveliness",
        "osr-router": "http://127.0.0.1:8000/healthz",
        "open-webui": "http://127.0.0.1:8080/health",
    },
}
MONITOR_INI = os.getenv(
    "MONITOR_INI",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "monitor.ini"),
)
_cfg = configparser.ConfigParser()
_cfg.read_dict(_DEFAULTS)
if os.path.exists(MONITOR_INI):
    _cfg.read(MONITOR_INI)

# (environment variable, monitor.ini section, option, default without the file)
ENV_OVERRIDES = (
    ("MONITOR_INTERVAL_SECONDS", "polling", "interval_seconds", "15"),
    ("MONITOR_TIMEOUT_SECONDS", "polling", "timeout_seconds", "5"),
    ("MONITOR_HEALTH_PATH", "polling", "health_path", "/api/tags"),
    ("MONITOR_FAIL_THRESHOLD", "alerting", "fail_threshold", "3"),
    ("MONITOR_RECOVER_THRESHOLD", "alerting", "recover_threshold", "2"),
    ("KEEP_ALIVE_REFRESH_SECONDS", "keep_alive", "refresh_seconds", "240"),
)


def _ini(section: str, option: str, default: str) -> str:
    return _cfg.get(section, option, fallback=default).strip()


def _setting(name: str) -> str:
    """One ENV_OVERRIDES setting: the environment's value when it has one (an
    empty variable counts as not set), else monitor.ini's."""
    for env_name, section, option, default in ENV_OVERRIDES:
        if env_name == name:
            return (os.getenv(env_name) or "").strip() or _ini(section, option, default)
    raise KeyError(name)


def env_overrides() -> list:
    """The settings an environment variable changes from what monitor.ini
    says, as text for the log."""
    def same(left: str, right: str) -> bool:
        try:
            return float(left) == float(right)
        except ValueError:
            return left == right

    found = []
    for env_name, section, option, default in ENV_OVERRIDES:
        value, ini = (os.getenv(env_name) or "").strip(), _ini(section, option, default)
        if value and not same(value, ini):
            found.append(f"{env_name}={value} (monitor.ini has [{section}] {option} = {ini})")
    return found


CHECK_INTERVAL = int(_setting("MONITOR_INTERVAL_SECONDS"))
CHECK_TIMEOUT = float(_setting("MONITOR_TIMEOUT_SECONDS"))
HEALTH_PATH = _setting("MONITOR_HEALTH_PATH")
FAIL_THRESHOLD = max(1, int(_setting("MONITOR_FAIL_THRESHOLD")))
RECOVER_THRESHOLD = max(1, int(_setting("MONITOR_RECOVER_THRESHOLD")))
# The startup notice is posted at most once per this many seconds, so a crash
# loop (Restart=always) does not flood the channel. The timestamp lives in the
# unit's StateDirectory; without one, every start posts as before.
NOTICE_INTERVAL = int(_cfg.get("startup", "notice_interval_seconds"))
STATE_DIR = os.getenv("MONITOR_STATE_DIR", "")

# --- keep-alive maintenance ---------------------------------------------------
# Ollama's OpenAI-compatible endpoint does not support a keep_alive field, so a
# model driven through it uses the server default and unloads after ~5 minutes
# idle. Pinning is therefore done against the NATIVE /api/chat endpoint, which
# does honour keep_alive: an empty-message request loads the model and (re)sets
# its unload timer without generating anything.
KEEP_ALIVE = (os.getenv("OLLAMA_KEEP_ALIVE", "") or "").strip()
KEEP_ALIVE_MODE = _cfg.get("keep_alive", "enabled", fallback="auto").strip().lower()
KEEP_ALIVE_INTERVAL = int(_setting("KEEP_ALIVE_REFRESH_SECONDS"))
KEEP_ALIVE_TIMEOUT = float(_cfg.get("keep_alive", "timeout_seconds", fallback="120"))
if KEEP_ALIVE_MODE == "auto":
    KEEP_ALIVE_ENABLED = bool(KEEP_ALIVE)
else:
    KEEP_ALIVE_ENABLED = KEEP_ALIVE_MODE in ("true", "yes", "1", "on")

# tier -> model tag, so we pin only the models this system actually fronts
# rather than everything a host happens to have pulled (which would thrash VRAM).
TIER_MODELS = {
    "fast": (os.getenv("MODEL_FAST", "") or "").strip(),
    "medium": (os.getenv("MODEL_MEDIUM", "") or "").strip(),
    "large": (os.getenv("MODEL_LARGE") or os.getenv("MODEL_HEAVY", "") or "").strip(),
    "xlarge": (os.getenv("MODEL_XLARGE", "") or "").strip(),
}


def _keep_alive_value():
    """Ollama accepts -1/0 or a number as an integer, durations as a string."""
    try:
        return int(KEEP_ALIVE)
    except (TypeError, ValueError):
        return KEEP_ALIVE


def _url_list(value: str) -> list:
    return [u.strip().rstrip("/") for u in (value or "").split(",") if u.strip()]


# Historical names for each tier's backend env key, newest first. The keys
# dropped their QWEN_ infix when the router stopped being Qwen-specific, and
# "heavy" was then renamed "large" when the xlarge tier was added.
# manage-model-servers.sh rewrites router.env on its next write, but a service
# can start against a file that has not been migrated yet -- without these
# fallbacks such a start looks healthy while routing to nothing at all.
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


BACKENDS = {tier: _url_list(_tier_env(tier)) for tier in ("fast", "medium", "large", "xlarge")}
BACKENDS = {tier: urls for tier, urls in BACKENDS.items() if urls}


# Entries for servers that are not Ollama carry a kind prefix in the shared
# server lists. Same table as router.py's SERVER_KINDS (tests/test_router.py
# checks that they agree):
#   prefix / key_env / label -- entry prefix, secrets.env token, alert name
#   openai -- a Strata-style server: probed on /v1/models, and up only while
#             that list names a model (its engine answers 200 with an empty
#             list when it is not running, and the router cannot use it then)
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
KIND_KEYS = {kind: (os.getenv(spec["key_env"]) or "").strip()
             for kind, spec in SERVER_KINDS.items()}
LMSTUDIO_HEALTH_PATH = os.getenv("MONITOR_LMSTUDIO_HEALTH_PATH", "/v1/models")
OPENAI_HEALTH_PATH = "/v1/models"


def server_kind(server: str) -> str:
    for kind, spec in SERVER_KINDS.items():
        if server.startswith(spec["prefix"]):
            return kind
    return "ollama"


def server_base(server: str) -> str:
    kind = server_kind(server)
    return server.removeprefix(SERVER_KINDS[kind]["prefix"]) if kind != "ollama" else server


def ollama_hosts() -> dict:
    """host URL -> tiers it serves. Includes every MODEL_SERVERS host, even one
    assigned to no tier: the router's discovery routes to it all the same."""
    hosts = {}
    for url in _url_list(os.getenv("MODEL_SERVERS", "")):
        hosts.setdefault(url, [])
    for tier, urls in BACKENDS.items():
        for url in urls:
            hosts.setdefault(url, []).append(tier)
    return hosts


def local_services() -> dict:
    """name -> health URL for the services running next to the monitor.
    OPENWEBUI_HEALTH_URL (written by the installer) overrides the ini default,
    because the Open WebUI port is chosen at install time."""
    if not _cfg.getboolean("local_services", "enabled"):
        return {}
    services = {name: url.strip() for name, url in _cfg.items("local_services")
                if name != "enabled" and url.strip()}
    override = (os.getenv("OPENWEBUI_HEALTH_URL") or "").strip()
    if override and "open-webui" in services:
        services["open-webui"] = override
    return services


class Check:
    """One monitored endpoint with debounced state.

    status   -- the confirmed state after the thresholds ('up' / 'down')
    notified -- the last state successfully delivered to Mattermost
    The two differ exactly when an alert still has to go out."""

    def __init__(self, key: str, url: str, label: str, headers: dict = None,
                 require_models: bool = False):
        self.key, self.url, self.label = key, url, label
        self.headers = headers or {}
        self.require_models = require_models
        self.status = self.notified = "up"
        self.fails = self.passes = 0
        self.last_error = ""

    def record(self, ok: bool, error: str = "") -> None:
        if ok:
            self.passes, self.fails = self.passes + 1, 0
            if self.status == "down" and self.passes >= RECOVER_THRESHOLD:
                self.status = "up"
        else:
            self.fails, self.passes = self.fails + 1, 0
            self.last_error = error
            if self.status == "up" and self.fails >= FAIL_THRESHOLD:
                self.status = "down"

    @property
    def pending(self) -> bool:
        return self.status != self.notified

    def message(self) -> tuple:
        if self.status == "down":
            detail = f" ({self.last_error})" if self.last_error else ""
            return (f"Infrastructure Alert: {self.label} is unavailable after "
                    f"{FAIL_THRESHOLD} failed checks{detail}.", ":warning:")
        return (f"Recovery Notice: {self.label} is operational again.",
                ":white_check_mark:")


def build_checks() -> list:
    checks = []
    for url, tiers in ollama_hosts().items():
        served = ", ".join(tiers) if tiers else "no tier (discovery only)"
        kind = server_kind(url)
        if kind != "ollama":
            spec, base = SERVER_KINDS[kind], server_base(url)
            token = KIND_KEYS[kind]
            headers = {"Authorization": f"Bearer {token}"} if token else {}
            path = OPENAI_HEALTH_PATH if spec["openai"] else LMSTUDIO_HEALTH_PATH
            checks.append(Check(url, f"{base}{path}",
                                f"{spec['label']} host `{base}` (serving: {served})",
                                headers, require_models=spec["openai"]))
        else:
            checks.append(Check(url, f"{url}{HEALTH_PATH}",
                                f"Ollama host `{url}` (serving: {served})"))
    freellmapi = (os.getenv("FREELLMAPI_BASE_URL") or "").strip().rstrip("/")
    if freellmapi.startswith(("http://", "https://")):
        # targets/freellmapi: not a model server (the router uses it only for
        # freellmapi/<id>), but an outage should still be reported. /api/ping
        # needs no key.
        checks.append(Check("freellmapi", f"{freellmapi}/api/ping",
                            f"FreeLLMAPI `{freellmapi}` (freellmapi/ models)"))
    for name, url in local_services().items():
        checks.append(Check(name, url, f"local service `{name}` ({url})"))
    return checks


def _post_once(payload: dict) -> tuple:
    """POST one payload. Returns (ok, status, body) -- status None on transport
    failure, with the exception text as the body."""
    try:
        with httpx.Client(verify=MATTERMOST_VERIFY_TLS) as client:
            resp = client.post(MATTERMOST_WEBHOOK_URL, json=payload, timeout=5.0)
        return (resp.status_code < 400, resp.status_code, resp.text.strip())
    except Exception as exc:  # noqa: BLE001 - transport errors are reported, not raised
        return (False, None, str(exc))


def post_mattermost(message: str, emoji: str = ":warning:") -> bool:
    """Post to the configured channel. Returns True on a 2xx delivery."""
    if not MATTERMOST_WEBHOOK_URL:
        logging.info("(message suppressed, no webhook configured) %s", message)
        return False
    payload = {
        "username": MATTERMOST_USER,
        "icon_emoji": emoji,
        "text": message,
    }
    # An incoming webhook is already bound to a channel. Naming the channel
    # explicitly makes the target unambiguous, but Mattermost REJECTS the
    # override unless the webhook is allowed to post elsewhere -- and a server
    # with channel overrides disabled fails every message with a 4xx that reads
    # like a permissions problem. So: try with the override, and on any 4xx
    # fall back to the webhook's own default channel rather than losing the
    # alert entirely.
    if MATTERMOST_CHANNEL:
        payload["channel"] = MATTERMOST_CHANNEL

    ok, status, body = _post_once(payload)
    if ok:
        return True

    if status is not None and 400 <= status < 500 and "channel" in payload:
        retry = {k: v for k, v in payload.items() if k != "channel"}
        ok_retry, status_retry, body_retry = _post_once(retry)
        if ok_retry:
            logging.warning(
                "Mattermost refused the channel override to '%s' (HTTP %s: %s); "
                "delivered to the webhook's own default channel instead. Either "
                "clear MATTERMOST_CHANNEL, or allow channel overrides for this "
                "webhook in the System Console.",
                MATTERMOST_CHANNEL, status, body)
            return True
        logging.error("Mattermost rejected message (HTTP %s): %s -- and again "
                      "without the channel override (HTTP %s): %s",
                      status, body, status_retry, body_retry)
        return False

    if status is None:
        logging.error("Failed message delivery: %s%s", body,
                      "" if MATTERMOST_VERIFY_TLS is False
                      else "  (if this is a certificate error, set "
                           "MATTERMOST_VERIFY_TLS=false in router.env)")
    else:
        logging.error("Mattermost rejected message (HTTP %s): %s", status, body)
    return False


def _notice_stamp() -> str:
    return os.path.join(STATE_DIR, "last-startup-notice") if STATE_DIR else ""


def startup_notice_due(now: float = None) -> bool:
    """False when a startup notice was delivered less than NOTICE_INTERVAL ago."""
    stamp = _notice_stamp()
    if not stamp or NOTICE_INTERVAL <= 0:
        return True
    try:
        with open(stamp) as fh:
            last = float(fh.read().strip() or 0)
    except (OSError, ValueError):
        return True
    return ((now or time.time()) - last) >= NOTICE_INTERVAL


def record_startup_notice(now: float = None) -> None:
    stamp = _notice_stamp()
    if not stamp:
        return
    try:
        with open(stamp, "w") as fh:
            fh.write("%f\n" % (now or time.time()))
    except OSError as exc:
        logging.warning("could not record the startup notice time: %s", exc)


def send_startup_notice(checks: list) -> None:
    host = socket.gethostname()
    watched = ", ".join(c.key for c in checks) or "nothing configured"
    message = (
        f"Health monitor online on `{host}` — health alerting is active. "
        f"Watching: {watched}. "
        f"(This is a startup test message confirming webhook access to "
        f"#{MATTERMOST_CHANNEL}.)"
    )
    if not MATTERMOST_WEBHOOK_URL:
        logging.warning("No MATTERMOST_WEBHOOK_URL set; skipping startup notice.")
        return
    if not startup_notice_due():
        logging.info("Startup notice skipped: one was sent within the last %ds "
                     "([startup] notice_interval_seconds).", NOTICE_INTERVAL)
        return
    if post_mattermost(message, emoji=":white_check_mark:"):
        record_startup_notice()
        logging.info("Startup notice delivered to #%s.", MATTERMOST_CHANNEL)
    else:
        logging.error(
            "Startup notice to #%s FAILED — check MATTERMOST_WEBHOOK_URL, the "
            "webhook's channel permissions, and MATTERMOST_VERIFY_TLS.",
            MATTERMOST_CHANNEL,
        )


def probe(url: str, client: httpx.Client, headers: dict = None,
          require_models: bool = False) -> tuple:
    """(ok, error) for one health URL. A 401/403 counts as down: a server
    that rejects the token cannot serve the router either. With
    require_models, the OpenAI model list must also name at least one model."""
    try:
        resp = client.get(url, timeout=CHECK_TIMEOUT, headers=headers or {})
        resp.raise_for_status()
        if require_models:
            models = resp.json().get("data")
            if not isinstance(models, list) or not models:
                return False, "no model loaded (the model list is empty)"
        return True, ""
    except Exception as exc:  # noqa: BLE001 - any failure is "unhealthy"
        return False, f"{type(exc).__name__}: {exc}"[:200]


def run_cycle(checks: list, client: httpx.Client, pool: ThreadPoolExecutor,
              notify=None) -> None:
    """Probe every check in parallel, update state, deliver pending alerts.
    An undelivered alert stays pending and is retried on the next cycle."""
    notify = notify or post_mattermost
    results = list(pool.map(lambda c: probe(c.url, client, c.headers, c.require_models),
                            checks))
    for check, (ok, error) in zip(checks, results, strict=True):
        before = check.status
        check.record(ok, error)
        if check.status != before:
            logging.warning("%s is now %s", check.label, check.status.upper())
        if check.pending:
            text, emoji = check.message()
            if notify(text, emoji):
                check.notified = check.status
            else:
                logging.warning("alert for %s not delivered; will retry", check.key)


# --- keep-alive thread --------------------------------------------------------
def pin_model(url: str, model: str) -> bool:
    """Load `model` on `url` and set its unload timer, generating nothing."""
    payload = {"model": model, "messages": [], "keep_alive": _keep_alive_value()}
    try:
        with httpx.Client() as client:
            resp = client.post(f"{url.rstrip('/')}/api/chat", json=payload,
                               timeout=KEEP_ALIVE_TIMEOUT)
            resp.raise_for_status()
        return True
    except Exception as exc:  # noqa: BLE001 - reported, the loop carries on
        logging.warning("keep-alive: %s on %s failed: %s", model, url, exc)
        return False


def keep_alive_plan() -> dict:
    """Ollama host URL -> the tier models to keep loaded there, in tier order.
    A model that two of a host's tiers share is listed once."""
    plan = {}
    for tier, urls in BACKENDS.items():
        model = TIER_MODELS.get(tier, "")
        if not model:
            continue
        for url in urls:
            if server_kind(url) != "ollama":
                # LM Studio has no keep_alive: it loads on demand and unloads
                # on its own idle TTL (configure that in LM Studio itself).
                continue
            models = plan.setdefault(url, [])
            if model not in models:
                models.append(model)
    return plan


def resident_models(url: str):
    """The model names Ollama's /api/ps reports loaded on url, or None when it
    cannot say (a failed call, or a bridge without /api/ps)."""
    try:
        with httpx.Client() as client:
            resp = client.get(f"{url.rstrip('/')}/api/ps", timeout=CHECK_TIMEOUT)
            resp.raise_for_status()
            models = resp.json().get("models")
        if not isinstance(models, list):
            return None
        return {name for model in models if isinstance(model, dict)
                for name in (model.get("name"), model.get("model")) if isinstance(name, str)}
    except Exception:  # noqa: BLE001 - residency is then simply unknown
        return None


def _is_resident(model: str, resident: set) -> bool:
    return model in resident or (":" not in model and f"{model}:latest" in resident)


# Hosts seen unloading one of their tier models to load another: they cannot
# hold all of them at once.
_CROWDED = set()


def pin_host(url: str, models: list) -> int:
    """Pin one host's tier models, one after another (a host loads one model at
    a time). Returns how many were pinned.

    A host that serves several tiers gets all of its models on the first pass.
    If loading one of them unloaded another, the host cannot hold them all, and
    loading each in turn on every refresh would evict the model in use again
    and again. Such a host then only has the timers of its resident tier models
    refreshed (the first is loaded when none is resident); the others load when
    a request needs them. It is treated normally again once /api/ps shows all
    of its models loaded together."""
    wanted = models
    if len(models) > 1 and url in _CROWDED:
        resident = resident_models(url)
        if resident is not None:
            if all(_is_resident(model, resident) for model in models):
                _CROWDED.discard(url)
            else:
                wanted = [m for m in models if _is_resident(m, resident)] or models[:1]
    done = [model for model in wanted if pin_model(url, model)]
    # keep_alive 0 unloads at once, so nothing stays resident to compare.
    if len(done) > 1 and url not in _CROWDED and _keep_alive_value() != 0:
        resident = resident_models(url)
        if resident is not None and not all(_is_resident(model, resident) for model in done):
            _CROWDED.add(url)
            logging.warning(
                "keep-alive: %s unloaded one tier model to load another (%s): it cannot "
                "hold them together. Only its loaded tier models are kept alive from now "
                "on; give each tier its own host, or one model, to keep them all loaded.",
                url, ", ".join(done))
    return len(done)


def refresh_keep_alive(is_up) -> int:
    """Pin each tier's model on every host serving that tier that is up.
    is_up(url) -> bool comes from the health checks. Hosts are pinned side by
    side, so one host's cold load (up to timeout_seconds) does not hold back
    the others until their models have already been unloaded."""
    # Down hosts are left out: don't wait on a host we already know is down.
    plan = [(url, models) for url, models in keep_alive_plan().items() if is_up(url)]
    if len(plan) > 1:
        with ThreadPoolExecutor(max_workers=min(16, len(plan)),
                                thread_name_prefix="keep-alive") as pool:
            pinned = sum(pool.map(lambda item: pin_host(*item), plan))
    else:
        pinned = sum(pin_host(url, models) for url, models in plan)
    if pinned:
        logging.info("keep-alive: refreshed %d model(s) with keep_alive=%s",
                     pinned, KEEP_ALIVE)
    return pinned


def keep_alive_loop(checks: list, stop: threading.Event) -> None:
    by_url = {c.key: c for c in checks}

    def is_up(url):
        check = by_url.get(url)
        return check is None or check.status == "up"

    while not stop.is_set():
        try:
            refresh_keep_alive(is_up)
        except Exception:  # noqa: BLE001 - never let the thread die
            logging.exception("keep-alive: refresh failed")
        stop.wait(KEEP_ALIVE_INTERVAL)


def run_health_checks() -> None:
    checks = build_checks()
    if not checks:
        logging.error("No model hosts or local services configured; nothing to monitor.")
        return
    logging.info("Monitoring %d endpoint(s): %s (alert after %d failures, "
                 "recover after %d passes)", len(checks),
                 ", ".join(c.key for c in checks), FAIL_THRESHOLD, RECOVER_THRESHOLD)
    for override in env_overrides():
        logging.info("The environment (router.env) overrides monitor.ini: %s", override)
    stop = threading.Event()
    if KEEP_ALIVE_ENABLED:
        logging.info("keep-alive maintainer active: keep_alive=%s every %ds",
                     KEEP_ALIVE, KEEP_ALIVE_INTERVAL)
        threading.Thread(target=keep_alive_loop, args=(checks, stop),
                         name="keep-alive", daemon=True).start()
    elif KEEP_ALIVE:
        logging.info("keep-alive configured (%s) but the maintainer is disabled.",
                     KEEP_ALIVE)
    else:
        logging.info("No OLLAMA_KEEP_ALIVE set; each server's own setting applies.")
    # Confirm on startup that the webhook works and has channel permission.
    send_startup_notice(checks)
    with httpx.Client() as client, ThreadPoolExecutor(max_workers=min(16, len(checks))) as pool:
        while True:
            started = time.monotonic()
            run_cycle(checks, client, pool)
            time.sleep(max(1.0, CHECK_INTERVAL - (time.monotonic() - started)))


if __name__ == "__main__":
    run_health_checks()
