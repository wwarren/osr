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
MATTERMOST_USER = os.getenv("MATTERMOST_MONITOR_USER", "OllamaMonitor")
MATTERMOST_CHANNEL = os.getenv("MATTERMOST_CHANNEL", "ollama-monitor")
MATTERMOST_VERIFY_TLS = os.getenv("MATTERMOST_VERIFY_TLS", "true").lower() == "true"

# Polling behaviour comes from monitor.ini (version controlled); environment
# variables still win, so an operator can override without a commit.
_DEFAULTS = {
    "polling": {"interval_seconds": "15", "timeout_seconds": "5",
                "health_path": "/api/tags"},
    "alerting": {"fail_threshold": "3", "recover_threshold": "2"},
    "startup": {"notice_interval_seconds": "3600"},
    "local_services": {
        "enabled": "true",
        "litellm-proxy": "http://127.0.0.1:4000/health/liveliness",
        "ollama-router": "http://127.0.0.1:8000/healthz",
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

CHECK_INTERVAL = int(os.getenv("MONITOR_INTERVAL_SECONDS",
                               _cfg.get("polling", "interval_seconds")))
CHECK_TIMEOUT = float(os.getenv("MONITOR_TIMEOUT_SECONDS",
                                _cfg.get("polling", "timeout_seconds")))
HEALTH_PATH = os.getenv("MONITOR_HEALTH_PATH", _cfg.get("polling", "health_path"))
FAIL_THRESHOLD = max(1, int(os.getenv("MONITOR_FAIL_THRESHOLD",
                                      _cfg.get("alerting", "fail_threshold"))))
RECOVER_THRESHOLD = max(1, int(os.getenv("MONITOR_RECOVER_THRESHOLD",
                                         _cfg.get("alerting", "recover_threshold"))))
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
KEEP_ALIVE_INTERVAL = int(os.getenv("KEEP_ALIVE_REFRESH_SECONDS",
                                    _cfg.get("keep_alive", "refresh_seconds",
                                             fallback="240")))
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


# OpenAI-compatible entries use kind prefixes in the shared server lists.
LMSTUDIO_PREFIX = "lmstudio+"
STRATA_PREFIX = "strata+"
BASALT_PREFIX = "basalt+"
LMSTUDIO_HEALTH_PATH = os.getenv("MONITOR_LMSTUDIO_HEALTH_PATH", "/v1/models")
LMSTUDIO_API_TOKEN = (os.getenv("LMSTUDIO_API_TOKEN") or "").strip()
STRATA_API_KEY = (os.getenv("STRATA_API_KEY") or "").strip()
BASALT_API_KEY = (os.getenv("BASALT_API_KEY") or "").strip()


def server_kind(server: str) -> str:
    if server.startswith(LMSTUDIO_PREFIX):
        return "lmstudio"
    if server.startswith(STRATA_PREFIX):
        return "strata"
    if server.startswith(BASALT_PREFIX):
        return "basalt"
    return "ollama"


def server_base(server: str) -> str:
    return server.split("+", 1)[1] if server_kind(server) != "ollama" else server


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

    def __init__(self, key: str, url: str, label: str, headers: dict = None):
        self.key, self.url, self.label = key, url, label
        self.headers = headers or {}
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
        if server_kind(url) == "lmstudio":
            headers = ({"Authorization": f"Bearer {LMSTUDIO_API_TOKEN}"}
                       if LMSTUDIO_API_TOKEN else {})
            checks.append(Check(url, f"{server_base(url)}{LMSTUDIO_HEALTH_PATH}",
                                f"LM Studio host `{server_base(url)}` (serving: {served})",
                                headers))
        elif server_kind(url) == "strata":
            headers = ({"Authorization": f"Bearer {STRATA_API_KEY}"}
                       if STRATA_API_KEY else {})
            # /v1/models stays available while Strata's engine is unloaded.
            checks.append(Check(url, f"{server_base(url)}/v1/models",
                                f"Strata host `{server_base(url)}` (serving: {served})",
                                headers))
        elif server_kind(url) == "basalt":
            headers = ({"Authorization": f"Bearer {BASALT_API_KEY}"}
                       if BASALT_API_KEY else {})
            checks.append(Check(url, f"{server_base(url)}/v1/models",
                                f"Basalt host `{server_base(url)}` (serving: {served})",
                                headers))
        else:
            checks.append(Check(url, f"{url}{HEALTH_PATH}",
                                f"Ollama host `{url}` (serving: {served})"))
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
        f"Ollama monitor online on `{host}` — health alerting is active. "
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


def probe(url: str, client: httpx.Client, headers: dict = None) -> tuple:
    """(ok, error) for one health URL. A 401/403 counts as down: an LM Studio
    that rejects the token cannot serve the router either."""
    try:
        resp = client.get(url, timeout=CHECK_TIMEOUT, headers=headers or {})
        resp.raise_for_status()
        return True, ""
    except Exception as exc:  # noqa: BLE001 - any failure is "unhealthy"
        return False, f"{type(exc).__name__}: {exc}"[:200]


def run_cycle(checks: list, client: httpx.Client, pool: ThreadPoolExecutor,
              notify=None) -> None:
    """Probe every check in parallel, update state, deliver pending alerts.
    An undelivered alert stays pending and is retried on the next cycle."""
    notify = notify or post_mattermost
    results = list(pool.map(lambda c: probe(c.url, client, c.headers), checks))
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


def refresh_keep_alive(is_up) -> int:
    """Pin each tier's model on every host serving that tier that is up.
    is_up(url) -> bool comes from the health checks."""
    pinned = 0
    for tier, urls in BACKENDS.items():
        model = TIER_MODELS.get(tier, "")
        if not model:
            continue
        for url in urls:
            if server_kind(url) != "ollama":
                # LM Studio has no keep_alive: it loads on demand and unloads
                # on its own idle TTL (configure that in LM Studio itself).
                continue
            if not is_up(url):
                continue          # don't wait on a host we already know is down
            if pin_model(url, model):
                pinned += 1
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
        logging.error("No Ollama hosts or local services configured; nothing to monitor.")
        return
    logging.info("Monitoring %d endpoint(s): %s (alert after %d failures, "
                 "recover after %d passes)", len(checks),
                 ", ".join(c.key for c in checks), FAIL_THRESHOLD, RECOVER_THRESHOLD)
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
