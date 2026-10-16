"""Unit tests for services/ollama-monitor/monitor.py (no network)."""
import importlib.util
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import httpx
import pytest

ROOT = Path(__file__).resolve().parent.parent
A, B, C = "http://10.0.0.1:11434", "http://10.0.0.2:11434", "http://10.0.0.3:11434"


def load_monitor(monkeypatch, **env):
    base = {
        "MONITOR_INI": str(ROOT / "services/ollama-monitor/monitor.ini"),
        "MODEL_SERVERS": f"{A},{B},{C}",
        "BACKEND_FAST": A,
        "BACKEND_MEDIUM": B,
        "BACKEND_LARGE": B,
        "MATTERMOST_WEBHOOK_URL": "",
        "OLLAMA_KEEP_ALIVE": "",
    }
    base.update(env)
    for key in ("BACKEND_XLARGE", "OPENWEBUI_HEALTH_URL", "MONITOR_STATE_DIR", "LMSTUDIO_API_TOKEN", "STRATA_API_KEY", "BASALT_API_KEY", "MODEL_FAST", "MODEL_MEDIUM",
                "MODEL_LARGE", "MONITOR_FAIL_THRESHOLD", "MONITOR_RECOVER_THRESHOLD"):
        monkeypatch.delenv(key, raising=False)
    for key, value in base.items():
        monkeypatch.setenv(key, value)
    spec = importlib.util.spec_from_file_location(
        "monitor_under_test", ROOT / "services/ollama-monitor/monitor.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["monitor_under_test"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def monitor(monkeypatch):
    return load_monitor(monkeypatch)


def test_every_model_server_is_watched_even_without_a_tier(monitor):
    hosts = monitor.ollama_hosts()
    assert set(hosts) == {A, B, C}
    assert hosts[C] == []


def test_a_shared_host_is_one_check_naming_all_its_tiers(monitor):
    checks = [c for c in monitor.build_checks() if c.key == B]
    assert len(checks) == 1
    assert "medium, large" in checks[0].label


def test_local_services_are_watched(monitor):
    keys = {c.key for c in monitor.build_checks()}
    assert {"litellm-proxy", "ollama-router", "open-webui"} <= keys


def test_openwebui_url_override(monkeypatch):
    module = load_monitor(monkeypatch, OPENWEBUI_HEALTH_URL="http://127.0.0.1:3000/health")
    assert module.local_services()["open-webui"] == "http://127.0.0.1:3000/health"


def test_debounce_needs_consecutive_failures(monitor):
    check = monitor.Check("x", "http://x", "x")
    check.record(False)
    check.record(False)
    assert check.status == "up"
    check.record(True)            # a pass resets the failure run
    check.record(False)
    check.record(False)
    assert check.status == "up"
    check.record(False)
    assert check.status == "down" and check.pending


def test_recovery_needs_consecutive_passes(monitor):
    check = monitor.Check("x", "http://x", "x")
    for _ in range(3):
        check.record(False)
    check.notified = "down"
    check.record(True)
    assert check.status == "down"
    check.record(True)
    assert check.status == "up" and check.pending


def fake_client(down: set):
    def handler(request):
        url = f"{request.url.scheme}://{request.url.host}:{request.url.port}"
        if url in down:
            raise httpx.ConnectError("refused", request=request)
        return httpx.Response(200, json={"models": []})
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_alert_is_sent_once_per_host_and_retried_until_delivered(monitor):
    checks = [c for c in monitor.build_checks() if c.key in (A, B)]
    sent, deliver = [], {"ok": False}

    def notify(text, emoji):
        sent.append(text)
        return deliver["ok"]

    client = fake_client({B})
    with ThreadPoolExecutor(4) as pool:
        for _ in range(3):
            monitor.run_cycle(checks, client, pool, notify)
        assert len(sent) == 1 and B in sent[0] and "medium, large" in sent[0]
        monitor.run_cycle(checks, client, pool, notify)    # delivery failed -> retry
        assert len(sent) == 2
        deliver["ok"] = True
        monitor.run_cycle(checks, client, pool, notify)
        monitor.run_cycle(checks, client, pool, notify)    # delivered -> quiet
        assert len(sent) == 3


def test_probes_run_in_parallel(monitor):
    checks = [monitor.Check(str(i), f"http://h{i}", str(i)) for i in range(4)]

    def slow(url, client, headers=None):
        time.sleep(0.3)
        return True, ""

    original = monitor.probe
    monitor.probe = slow
    try:
        with ThreadPoolExecutor(4) as pool:
            started = time.monotonic()
            monitor.run_cycle(checks, None, pool, lambda *a: True)
            assert time.monotonic() - started < 0.9
    finally:
        monitor.probe = original


def test_keep_alive_skips_down_hosts(monkeypatch):
    module = load_monitor(monkeypatch, MODEL_FAST="qwen3:8b", MODEL_MEDIUM="qwen3:14b",
                          OLLAMA_KEEP_ALIVE="2h")
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append((url, model)) or True)
    module.refresh_keep_alive(lambda url: url != B)
    assert pinned == [(A, "qwen3:8b")]


def test_keep_alive_runs_off_the_health_loop(monkeypatch):
    module = load_monitor(monkeypatch, MODEL_FAST="qwen3:8b", OLLAMA_KEEP_ALIVE="2h")
    started = threading.Event()

    def slow_pin(url, model):
        started.set()
        time.sleep(5)
        return True

    monkeypatch.setattr(module, "pin_model", slow_pin)
    stop = threading.Event()
    checks = module.build_checks()
    thread = threading.Thread(target=module.keep_alive_loop, args=(checks, stop), daemon=True)
    thread.start()
    assert started.wait(2)
    # The health cycle is not blocked while a model is loading.
    with ThreadPoolExecutor(4) as pool:
        t0 = time.monotonic()
        module.run_cycle(checks, fake_client(set()), pool, lambda *a: True)
        assert time.monotonic() - t0 < 2
    stop.set()


def test_keep_alive_value(monkeypatch):
    assert load_monitor(monkeypatch, OLLAMA_KEEP_ALIVE="-1")._keep_alive_value() == -1
    assert load_monitor(monkeypatch, OLLAMA_KEEP_ALIVE="2h")._keep_alive_value() == "2h"


def test_startup_notice_is_rate_limited(monkeypatch, tmp_path):
    module = load_monitor(monkeypatch, MONITOR_STATE_DIR=str(tmp_path),
                          MATTERMOST_WEBHOOK_URL="http://mm.test/hooks/x")
    sent = []
    monkeypatch.setattr(module, "post_mattermost", lambda text, emoji=None: sent.append(text) or True)
    module.send_startup_notice([])
    module.send_startup_notice([])
    assert len(sent) == 1
    assert module.startup_notice_due(now=time.time() + module.NOTICE_INTERVAL + 1)


def test_failed_notice_is_not_recorded(monkeypatch, tmp_path):
    module = load_monitor(monkeypatch, MONITOR_STATE_DIR=str(tmp_path),
                          MATTERMOST_WEBHOOK_URL="http://mm.test/hooks/x")
    monkeypatch.setattr(module, "post_mattermost", lambda text, emoji=None: False)
    module.send_startup_notice([])
    assert module.startup_notice_due()


def test_no_state_dir_means_always_due(monitor):
    assert monitor.startup_notice_due()


# --- LM Studio hosts --------------------------------------------------------------------
LMS = "lmstudio+http://10.0.0.9:1234"


def test_lmstudio_host_is_probed_on_v1_models(monkeypatch):
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{LMS}", BACKEND_LARGE=LMS)
    check = [c for c in module.build_checks() if c.key == LMS][0]
    assert check.url == "http://10.0.0.9:1234/v1/models"
    assert "LM Studio host `http://10.0.0.9:1234`" in check.label and "large" in check.label
    assert check.headers == {}


def test_lmstudio_token_is_sent(monkeypatch):
    module = load_monitor(monkeypatch, MODEL_SERVERS=LMS, LMSTUDIO_API_TOKEN="tok")
    check = [c for c in module.build_checks() if c.key == LMS][0]
    assert check.headers == {"Authorization": "Bearer tok"}
    seen = {}

    def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json={"data": []})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    assert module.probe(check.url, client, check.headers) == (True, "")
    assert seen["auth"] == "Bearer tok"


def test_rejected_token_counts_as_down(monkeypatch):
    module = load_monitor(monkeypatch, MODEL_SERVERS=LMS)
    client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(401)))
    ok, error = module.probe("http://10.0.0.9:1234/v1/models", client)
    assert not ok and "401" in error


def test_keep_alive_skips_lmstudio(monkeypatch):
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{LMS}", BACKEND_FAST=f"{A},{LMS}",
                          MODEL_FAST="qwen3:8b", OLLAMA_KEEP_ALIVE="2h")
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append(url) or True)
    module.refresh_keep_alive(lambda url: True)
    assert pinned == [A]


@pytest.mark.parametrize("port", [8080, 11434])
def test_strata_health_key_and_keep_alive(monkeypatch, port):
    strata = f"strata+http://10.0.0.8:{port}"
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{strata}",
                          BACKEND_FAST=f"{A},{strata}", MODEL_FAST="strata",
                          STRATA_API_KEY="strata-secret", OLLAMA_KEEP_ALIVE="2h")
    check = [c for c in module.build_checks() if c.key == strata][0]
    assert check.url == f"http://10.0.0.8:{port}/v1/models"
    assert check.headers == {"Authorization": "Bearer strata-secret"}
    assert "Strata host" in check.label
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append(url) or True)
    module.refresh_keep_alive(lambda url: True)
    assert pinned == [A]


@pytest.mark.parametrize("port", [8080, 11434])
def test_basalt_health_key_and_keep_alive(monkeypatch, port):
    basalt = f"basalt+http://10.0.0.7:{port}"
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{basalt}",
                          BACKEND_FAST=f"{A},{basalt}", MODEL_FAST="qwen3.8-flash-next",
                          BASALT_API_KEY="basalt-secret", OLLAMA_KEEP_ALIVE="2h")
    check = [c for c in module.build_checks() if c.key == basalt][0]
    assert check.url == f"http://10.0.0.7:{port}/v1/models"
    assert check.headers == {"Authorization": "Bearer basalt-secret"}
    assert "Basalt host" in check.label
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append(url) or True)
    module.refresh_keep_alive(lambda url: True)
    assert pinned == [A]
