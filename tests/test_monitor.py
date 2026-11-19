"""Unit tests for services/osr-monitor/monitor.py (no network)."""
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
        "MONITOR_INI": str(ROOT / "services/osr-monitor/monitor.ini"),
        "MODEL_SERVERS": f"{A},{B},{C}",
        "BACKEND_FAST": A,
        "BACKEND_MEDIUM": B,
        "BACKEND_LARGE": B,
        "MATTERMOST_WEBHOOK_URL": "",
        "OLLAMA_KEEP_ALIVE": "",
    }
    base.update(env)
    for key in ("BACKEND_XLARGE", "OPENWEBUI_HEALTH_URL", "MONITOR_STATE_DIR", "LMSTUDIO_API_TOKEN", "STRATA_API_KEY", "BASALT_API_KEY", "MAYA_API_KEY", "XOLOTL_API_KEY", "MODEL_FAST", "MODEL_MEDIUM",
                "MODEL_LARGE", "MONITOR_FAIL_THRESHOLD", "MONITOR_RECOVER_THRESHOLD"):
        monkeypatch.delenv(key, raising=False)
    for key, value in base.items():
        monkeypatch.setenv(key, value)
    spec = importlib.util.spec_from_file_location(
        "monitor_under_test", ROOT / "services/osr-monitor/monitor.py")
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


def test_freellmapi_is_watched_only_when_configured(monkeypatch):
    monkeypatch.delenv("FREELLMAPI_BASE_URL", raising=False)
    module = load_monitor(monkeypatch)
    assert "freellmapi" not in {c.key for c in module.build_checks()}
    module = load_monitor(monkeypatch, FREELLMAPI_BASE_URL="http://10.0.0.60:3001/")
    check = [c for c in module.build_checks() if c.key == "freellmapi"][0]
    # Its public ping, without a key and without the model-list requirement.
    assert check.url == "http://10.0.0.60:3001/api/ping"
    assert check.headers == {} and check.require_models is False
    assert "FreeLLMAPI" in check.label
    # It is not a model server: no tier and no keep-alive plan mention it.
    assert "http://10.0.0.60:3001" not in module.ollama_hosts()
    monkeypatch.delenv("FREELLMAPI_BASE_URL")


def test_local_services_are_watched(monitor):
    keys = {c.key for c in monitor.build_checks()}
    assert {"litellm-proxy", "osr-router", "open-webui"} <= keys


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


@pytest.mark.parametrize("notice_throttled", [False, True],
                         ids=["first-start", "startup-notice-throttled"])
def test_new_host_alerts_once_during_provisioning_then_recovers(
        monkeypatch, tmp_path, notice_throttled):
    """A host configured before its target CT is ready: the down alert lands on
    exactly the FAIL_THRESHOLD-th failed check and is not repeated, and the
    recovery notice on exactly the RECOVER_THRESHOLD-th passing check. A
    startup notice suppressed by the hourly limit does not delay either."""
    module = load_monitor(monkeypatch, MODEL_SERVERS=B, BACKEND_FAST="", BACKEND_MEDIUM=B,
                          BACKEND_LARGE="", MONITOR_STATE_DIR=str(tmp_path),
                          MATTERMOST_WEBHOOK_URL="http://mm.test/hooks/x")
    if notice_throttled:
        module.record_startup_notice()          # a notice went out moments ago
    checks = [c for c in module.build_checks() if c.key == B]
    sent = []
    monkeypatch.setattr(module, "post_mattermost",
                        lambda message, emoji=None: sent.append(message) or True)

    module.send_startup_notice(checks)
    notices = 0 if notice_throttled else 1
    assert len(sent) == notices
    if not notice_throttled:
        assert "monitor online" in sent[0]
    alerts = sent[notices:]

    with ThreadPoolExecutor(2) as pool:
        with fake_client({B}) as absent:
            for _ in range(module.FAIL_THRESHOLD - 1):
                module.run_cycle(checks, absent, pool)
            assert alerts == [] and sent[notices:] == []
            module.run_cycle(checks, absent, pool)           # the threshold check
            assert len(sent[notices:]) == 1
            assert "Infrastructure Alert" in sent[-1] and B in sent[-1]
            for _ in range(4):                               # still absent: quiet
                module.run_cycle(checks, absent, pool)
            assert len(sent[notices:]) == 1
        with fake_client(set()) as ready:
            for _ in range(module.RECOVER_THRESHOLD - 1):
                module.run_cycle(checks, ready, pool)
            assert len(sent[notices:]) == 1
            module.run_cycle(checks, ready, pool)            # the threshold pass
            assert len(sent[notices:]) == 2
            assert "Recovery Notice" in sent[-1] and B in sent[-1]
            for _ in range(3):                               # stays up: quiet
                module.run_cycle(checks, ready, pool)
    assert len(sent[notices:]) == 2


def test_probes_run_in_parallel(monitor):
    checks = [monitor.Check(str(i), f"http://h{i}", str(i)) for i in range(4)]

    def slow(url, client, headers=None, require_models=False):
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


def test_keep_alive_pins_hosts_side_by_side(monkeypatch):
    module = load_monitor(monkeypatch, BACKEND_FAST=f"{A},{B},{C}", MODEL_FAST="qwen3:8b",
                          BACKEND_MEDIUM="", BACKEND_LARGE="", OLLAMA_KEEP_ALIVE="2h")
    together = threading.Barrier(3)

    def pin(url, model):
        together.wait(timeout=5)   # raises unless all three hosts are being pinned at once
        return True

    monkeypatch.setattr(module, "pin_model", pin)
    assert module.refresh_keep_alive(lambda url: True) == 3


def test_keep_alive_pins_a_shared_model_once_per_host(monkeypatch):
    module = load_monitor(monkeypatch, BACKEND_MEDIUM=B, BACKEND_LARGE=B,
                          MODEL_MEDIUM="qwen3:14b", MODEL_LARGE="qwen3:14b", OLLAMA_KEEP_ALIVE="2h")
    assert module.keep_alive_plan() == {B: ["qwen3:14b"]}
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append((url, model)) or True)
    monkeypatch.setattr(module, "resident_models", lambda url: pytest.fail("one model needs no /api/ps"))
    assert module.refresh_keep_alive(lambda url: True) == 1
    assert pinned == [(B, "qwen3:14b")]


def shared_host(monkeypatch, capacity):
    """B serves medium and large with different models and holds `capacity` of
    them: loading one more unloads the oldest, as Ollama does."""
    module = load_monitor(monkeypatch, BACKEND_FAST="", BACKEND_MEDIUM=B, BACKEND_LARGE=B,
                          MODEL_MEDIUM="qwen3:14b", MODEL_LARGE="qwen3:32b", OLLAMA_KEEP_ALIVE="2h")
    loaded, loads = [], []

    def pin(url, model):
        if model in loaded:
            return True
        loads.append(model)
        loaded.append(model)
        del loaded[:-capacity]
        return True

    monkeypatch.setattr(module, "pin_model", pin)
    monkeypatch.setattr(module, "resident_models", lambda url: set(loaded))
    return module, loaded, loads


def test_keep_alive_keeps_every_model_on_a_host_that_holds_them(monkeypatch):
    module, loaded, loads = shared_host(monkeypatch, capacity=2)
    for _ in range(3):
        assert module.refresh_keep_alive(lambda url: True) == 2
    assert loads == ["qwen3:14b", "qwen3:32b"]   # each loaded once, then only refreshed
    assert B not in module._CROWDED


def test_keep_alive_stops_reloading_on_a_host_that_cannot_hold_its_tiers(monkeypatch, caplog):
    module, loaded, loads = shared_host(monkeypatch, capacity=1)
    with caplog.at_level("WARNING"):
        module.refresh_keep_alive(lambda url: True)
    assert loads == ["qwen3:14b", "qwen3:32b"]   # the first pass tries both
    assert B in module._CROWDED
    assert "cannot hold them together" in caplog.text
    for _ in range(3):
        assert module.refresh_keep_alive(lambda url: True) == 1
    assert loads == ["qwen3:14b", "qwen3:32b"]   # no model is loaded again: only the resident one is refreshed
    assert loaded == ["qwen3:32b"]
    # A request loaded the other model meanwhile: that one is kept alive instead.
    loaded[:] = ["qwen3:14b"]
    module.refresh_keep_alive(lambda url: True)
    assert loads == ["qwen3:14b", "qwen3:32b"] and loaded == ["qwen3:14b"]
    # Nothing of its tiers is resident: the first tier's model is loaded.
    loaded[:] = ["other:7b"]
    module.refresh_keep_alive(lambda url: True)
    assert loads[-1] == "qwen3:14b" and len(loads) == 3


def test_keep_alive_treats_a_host_normally_again_once_it_holds_everything(monkeypatch):
    module, loaded, loads = shared_host(monkeypatch, capacity=1)
    module.refresh_keep_alive(lambda url: True)
    assert B in module._CROWDED
    loaded[:] = ["qwen3:14b", "qwen3:32b"]       # e.g. a bigger card, or smaller models
    module.refresh_keep_alive(lambda url: True)
    assert B not in module._CROWDED


def test_keep_alive_without_api_ps_pins_everything_as_before(monkeypatch):
    module, loaded, loads = shared_host(monkeypatch, capacity=1)
    monkeypatch.setattr(module, "resident_models", lambda url: None)
    for _ in range(2):
        assert module.refresh_keep_alive(lambda url: True) == 2
    assert B not in module._CROWDED
    assert loads == ["qwen3:14b", "qwen3:32b"] * 2


def test_keep_alive_zero_is_not_mistaken_for_a_crowded_host(monkeypatch):
    module, loaded, loads = shared_host(monkeypatch, capacity=1)
    monkeypatch.setattr(module, "KEEP_ALIVE", "0")
    module.refresh_keep_alive(lambda url: True)
    assert B not in module._CROWDED


def test_resident_models_reads_api_ps(monkeypatch):
    module = load_monitor(monkeypatch)

    class Client:
        def __init__(self, response):
            self.response = response

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def get(self, url, timeout):
            assert url == f"{A}/api/ps"
            if isinstance(self.response, Exception):
                raise self.response
            return self.response

    request = httpx.Request("GET", f"{A}/api/ps")
    answers = {
        "listed": httpx.Response(200, request=request, json={"models": [
            {"name": "qwen3:14b", "model": "qwen3:14b"}, {"name": "llama3:latest"}, "junk"]}),
        "missing": httpx.Response(404, request=request),
        "odd": httpx.Response(200, request=request, json={"models": None}),
        "down": httpx.ConnectError("refused"),
    }
    seen = {}
    for name, answer in answers.items():
        monkeypatch.setattr(module.httpx, "Client", lambda answer=answer: Client(answer))
        seen[name] = module.resident_models(A)
    assert seen == {"listed": {"qwen3:14b", "llama3:latest"}, "missing": None, "odd": None, "down": None}
    assert module._is_resident("llama3", seen["listed"]) and not module._is_resident("qwen3", seen["listed"])


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


def test_monitor_ini_governs_and_an_empty_variable_is_not_a_setting(monkeypatch):
    module = load_monitor(monkeypatch)
    assert (module.CHECK_INTERVAL, module.CHECK_TIMEOUT, module.HEALTH_PATH) == (15, 5.0, "/api/tags")
    assert (module.FAIL_THRESHOLD, module.RECOVER_THRESHOLD, module.KEEP_ALIVE_INTERVAL) == (3, 2, 240)
    assert module.env_overrides() == []
    # An empty variable (KEY= in router.env) used to stop the monitor at start.
    empty = load_monitor(monkeypatch, MONITOR_INTERVAL_SECONDS="", KEEP_ALIVE_REFRESH_SECONDS=" ",
                         MONITOR_FAIL_THRESHOLD="")
    assert (empty.CHECK_INTERVAL, empty.KEEP_ALIVE_INTERVAL, empty.FAIL_THRESHOLD) == (15, 240, 3)
    assert empty.env_overrides() == []


def test_environment_overrides_win_and_are_reported(monkeypatch, tmp_path, caplog):
    ini = tmp_path / "monitor.ini"
    ini.write_text("[polling]\ninterval_seconds = 30\n[keep_alive]\nrefresh_seconds = 120\n")
    module = load_monitor(monkeypatch, MONITOR_INI=str(ini), MONITOR_INTERVAL_SECONDS="15",
                          KEEP_ALIVE_REFRESH_SECONDS="120", MONITOR_TIMEOUT_SECONDS="5.0",
                          MONITOR_HEALTH_PATH="/api/version")
    assert (module.CHECK_INTERVAL, module.KEEP_ALIVE_INTERVAL, module.HEALTH_PATH) == (15, 120, "/api/version")
    # Only the ones that change something: 120 and 5.0 repeat what the file says.
    assert module.env_overrides() == [
        "MONITOR_INTERVAL_SECONDS=15 (monitor.ini has [polling] interval_seconds = 30)",
        "MONITOR_HEALTH_PATH=/api/version (monitor.ini has [polling] health_path = /api/tags)"]
    monkeypatch.setattr(module, "build_checks", lambda: [module.Check("x", "http://x", "x")])
    monkeypatch.setattr(module, "send_startup_notice", lambda checks: None)
    monkeypatch.setattr(module, "run_cycle", lambda *a, **k: (_ for _ in ()).throw(KeyboardInterrupt))
    with caplog.at_level("INFO"), pytest.raises(KeyboardInterrupt):
        module.run_health_checks()
    assert "overrides monitor.ini: MONITOR_INTERVAL_SECONDS=15" in caplog.text
    assert "KEEP_ALIVE_REFRESH_SECONDS" not in caplog.text
    for key in ("MONITOR_INTERVAL_SECONDS", "KEEP_ALIVE_REFRESH_SECONDS", "MONITOR_TIMEOUT_SECONDS",
                "MONITOR_HEALTH_PATH", "MONITOR_INI"):
        monkeypatch.delenv(key, raising=False)


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


def test_maya_health_key_and_keep_alive(monkeypatch):
    maya = "maya+http://10.0.0.9:8080"
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{maya}",
                          BACKEND_FAST=f"{A},{maya}", MODEL_FAST="glm-5.3-flash",
                          MAYA_API_KEY="maya-secret", OLLAMA_KEEP_ALIVE="2h")
    check = [c for c in module.build_checks() if c.key == maya][0]
    assert check.url == "http://10.0.0.9:8080/v1/models"
    assert check.headers == {"Authorization": "Bearer maya-secret"}
    assert "Maya host" in check.label
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append(url) or True)
    module.refresh_keep_alive(lambda url: True)
    assert pinned == [A]


@pytest.mark.parametrize("kind", ["strata", "basalt", "maya", "xolotl", "avalon", "kindi", "colibri"])
def test_openai_host_with_an_empty_model_list_is_down(monkeypatch, kind):
    """Strata-style servers answer /v1/models with 200 and no models while
    their engine is down; the router cannot use them, so neither is the host up."""
    server = f"{kind}+http://10.0.0.9:8080"
    module = load_monitor(monkeypatch, MODEL_SERVERS=server)
    check = [c for c in module.build_checks() if c.key == server][0]
    assert check.require_models
    empty = httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(200, json={"object": "list", "data": []})))
    ok, error = module.probe(check.url, empty, check.headers, check.require_models)
    assert not ok and "empty" in error
    loaded = httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(200, json={"data": [{"id": "glm-5.3-flash"}]})))
    assert module.probe(check.url, loaded, check.headers, check.require_models) == (True, "")
    not_json = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, text="ok")))
    assert not module.probe(check.url, not_json, check.headers, check.require_models)[0]


def test_xolotl_health_key_and_keep_alive(monkeypatch):
    xolotl = "xolotl+http://10.0.0.12:8080"
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{xolotl}",
                          BACKEND_XLARGE=xolotl, MODEL_FAST="deepseek-v4.1-flash",
                          STRATA_API_KEY="strata-secret", XOLOTL_API_KEY="xolotl-secret",
                          OLLAMA_KEEP_ALIVE="2h")
    check = [c for c in module.build_checks() if c.key == xolotl][0]
    assert check.url == "http://10.0.0.12:8080/v1/models"
    assert check.headers == {"Authorization": "Bearer xolotl-secret"}
    assert "Xolotl host" in check.label
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append(url) or True)
    module.refresh_keep_alive(lambda url: True)
    assert pinned == [A]


def test_avalon_health_key_and_keep_alive(monkeypatch):
    avalon = "avalon+http://10.0.0.13:8080"
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{avalon}",
                          BACKEND_XLARGE=avalon, MODEL_FAST="qwen3.8-flash-next-avalon",
                          XOLOTL_API_KEY="xolotl-secret", AVALON_API_KEY="avalon-secret",
                          OLLAMA_KEEP_ALIVE="2h")
    check = [c for c in module.build_checks() if c.key == avalon][0]
    assert check.url == "http://10.0.0.13:8080/v1/models"
    assert check.headers == {"Authorization": "Bearer avalon-secret"}
    assert "Avalon host" in check.label
    # llama-server answers 503 while the model loads: the host is down then.
    loading = httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(503, json={"error": {"code": 503, "message": "Loading model"}})))
    assert not module.probe(check.url, loading, check.headers, check.require_models)[0]
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append(url) or True)
    module.refresh_keep_alive(lambda url: True)
    assert pinned == [A]


def test_kindi_health_key_and_keep_alive(monkeypatch):
    kindi = "kindi+http://10.0.0.14:8093"
    module = load_monitor(monkeypatch, MODEL_SERVERS=f"{A},{kindi}",
                          BACKEND_FAST=f"{A},{kindi}", MODEL_FAST="bonsai2-2b",
                          AVALON_API_KEY="avalon-secret", KINDI_API_KEY="kindi-secret",
                          OLLAMA_KEEP_ALIVE="2h")
    check = [c for c in module.build_checks() if c.key == kindi][0]
    assert check.url == "http://10.0.0.14:8093/v1/models"
    assert check.headers == {"Authorization": "Bearer kindi-secret"}
    assert "Kindi host" in check.label
    # A rejected key counts as down.
    rejected = httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(401, json={"error": {"message": "invalid API key"}})))
    assert not module.probe(check.url, rejected, check.headers, check.require_models)[0]
    pinned = []
    monkeypatch.setattr(module, "pin_model", lambda url, model: pinned.append(url) or True)
    module.refresh_keep_alive(lambda url: True)
    assert pinned == [A]


def test_empty_model_list_alerts_through_run_cycle(monkeypatch):
    maya = "maya+http://10.0.0.9:8080"
    module = load_monitor(monkeypatch, MODEL_SERVERS=maya)
    checks = [c for c in module.build_checks() if c.key == maya]
    client = httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(200, json={"data": []})))
    sent = []
    with module.ThreadPoolExecutor(max_workers=2) as pool:
        for _ in range(module.FAIL_THRESHOLD):
            module.run_cycle(checks, client, pool, notify=lambda *a: sent.append(a) or True)
    assert checks[0].status == "down"
    assert sent and "Maya host" in str(sent[0])


def test_lmstudio_with_no_models_listed_stays_up(monkeypatch):
    module = load_monitor(monkeypatch, MODEL_SERVERS=LMS)
    check = [c for c in module.build_checks() if c.key == LMS][0]
    assert not check.require_models


def _manager_kinds() -> dict:
    """manage-model-servers.sh's kind table, read through its own functions."""
    import subprocess
    script = ROOT / "install/manage-model-servers.sh"
    funcs = subprocess.run(
        [sys.executable, str(ROOT / "tests/lib/extract-functions.py"), str(script),
         "--only", "server_kinds,kind_field"],
        check=True, capture_output=True, text=True).stdout
    out = subprocess.run(
        ["bash", "-c", funcs + '\nfor k in $(server_kinds); do '
         'printf "%s|%s|%s|%s\\n" "$k" "$(kind_field "$k" key)" '
         '"$(kind_field "$k" label)" "$(kind_field "$k" openai)"; done'],
        check=True, capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"}).stdout
    kinds = {}
    for line in out.splitlines():
        kind, key, label, openai = line.split("|")
        kinds[kind] = {"prefix": f"{kind}+", "key_env": key, "label": label,
                       "openai": openai == "1"}
    return kinds


def test_router_monitor_and_manager_agree_on_server_kinds(monkeypatch):
    """One kind table, three copies: a kind added to one must be added to all."""
    monitor = load_monitor(monkeypatch)
    for key in ("ROUTER_API_KEY", "MODEL_SERVERS"):
        monkeypatch.setenv(key, "")
    monkeypatch.setenv("ROUTER_INI", str(ROOT / "services/osr-router/router.ini"))
    spec = importlib.util.spec_from_file_location(
        "router_kinds_under_test", ROOT / "services/osr-router/router.py")
    router = importlib.util.module_from_spec(spec)
    sys.modules["router_kinds_under_test"] = router
    spec.loader.exec_module(router)
    assert router.SERVER_KINDS == monitor.SERVER_KINDS
    assert _manager_kinds() == router.SERVER_KINDS
    assert list(_manager_kinds()) == list(router.SERVER_KINDS)   # detection order too
