"""Contract tests for the target's monitor dashboard service (no GPU, no llama-server).

Run from the repository root: python -m pytest -q targets/llamacpp/test_dashboard.py
"""

import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

import dashboard
from dashboard import Config, create_app, gpu_info, reduce_slots

HERE = Path(__file__).resolve().parent
METRICS = (
    "# HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.\n"
    "llamacpp:prompt_tokens_total 120\n"
    "llamacpp:predicted_tokens_seconds 42.5\n"
)
SLOTS = [
    {"id": 0, "id_task": 7, "n_ctx": 32768, "is_processing": True,
     "prompt": "my secret prompt", "params": {"temperature": 0.7, "stop": ["</s>"]},
     "next_token": [{"has_next_token": True, "n_remain": 90, "n_decoded": 10, "stopping_word": ""}]},
    {"id": 1, "n_ctx": 32768, "is_processing": False,
     "next_token": {"n_remain": -1, "n_decoded": 0}},
]


def llama(handler_calls, slots=SLOTS, status=200):
    def handler(request):
        handler_calls.append(request.url.path)
        if status != 200:
            return httpx.Response(status, text="no")
        if request.url.path == "/metrics":
            return httpx.Response(200, text=METRICS)
        if request.url.path == "/slots":
            return httpx.Response(200, json=slots)
        return httpx.Response(404)
    return httpx.MockTransport(handler)


class Fixture:
    def __init__(self, tmp):
        self.root = Path(tmp)
        (self.root / "proc").mkdir()
        (self.root / "proc" / "stat").write_text("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 1 1 1\n")
        (self.root / "proc" / "cpuinfo").write_text(
            "processor\t: 0\nphysical id\t: 0\ncore id\t: 0\ncpu MHz\t\t: 3000.000\n\n"
            "processor\t: 1\nphysical id\t: 0\ncore id\t: 0\ncpu MHz\t\t: 3400.000\n\n"
            "processor\t: 2\nphysical id\t: 0\ncore id\t: 1\ncpu MHz\t\t: 3200.000\n")
        (self.root / "proc" / "meminfo").write_text(
            "MemTotal:       8388608 kB\nMemFree:         1048576 kB\nMemAvailable:    2097152 kB\n")
        self.page = self.root / "monitor.html"
        self.page.write_text("<html>monitor</html>")

    def config(self):
        return Config(base_url="http://llama", page=str(self.page), proc=str(self.root / "proc"), disk=str(self.root))


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(self.tmp.name)
        self.calls = []

    def tearDown(self):
        self.tmp.cleanup()

    def client(self, transport=None, gpu=lambda: None):
        return TestClient(create_app(self.fx.config(), transport or llama(self.calls), gpu=gpu))

    def test_root_opens_the_page_with_the_hardware_panel(self):
        with self.client() as c:
            r = c.get("/", follow_redirects=False)
            self.assertEqual(r.status_code, 302)
            self.assertEqual(r.headers["location"], "/monitor.html?hw=.")
            page = c.get("/monitor.html")
            self.assertEqual(page.status_code, 200)
            self.assertIn("monitor", page.text)
            self.assertTrue(page.headers["content-type"].startswith("text/html"))

    def test_every_response_is_locked_to_this_origin(self):
        with self.client() as c:
            for path in ("/monitor.html", "/metrics", "/slots", "/hw", "/healthz"):
                csp = c.get(path).headers["content-security-policy"]
                self.assertIn("connect-src 'self'", csp, path)
                self.assertIn("frame-ancestors 'none'", csp, path)
            self.assertEqual(c.get("/healthz").headers["x-content-type-options"], "nosniff")

    def test_metrics_pass_through(self):
        with self.client() as c:
            r = c.get("/metrics")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.text, METRICS)
        self.assertTrue(r.headers["content-type"].startswith("text/plain"))
        self.assertEqual(self.calls, ["/metrics"])

    def test_slots_keep_only_what_the_page_draws(self):
        with self.client() as c:
            body = c.get("/slots").json()
        self.assertEqual(body, [
            {"id": 0, "n_ctx": 32768, "is_processing": True, "next_token": [{"n_decoded": 10, "n_remain": 90}]},
            {"id": 1, "n_ctx": 32768, "is_processing": False, "next_token": [{"n_decoded": 0, "n_remain": 0}]},
        ])
        self.assertNotIn("secret", str(body))

    def test_slot_values_are_numbers_only(self):
        hostile = [{"id": "<img src=x onerror=alert(1)>", "n_ctx": "1", "is_processing": "yes",
                    "next_token": [{"n_decoded": True, "n_remain": -5}]}, "junk", None]
        self.assertEqual(reduce_slots(hostile), [
            {"id": 0, "n_ctx": 0, "is_processing": False, "next_token": [{"n_decoded": 0, "n_remain": 0}]}])
        self.assertEqual(reduce_slots({"error": "x"}), [])
        self.assertEqual(reduce_slots([{"id": 2, "next_token": []}])[0]["next_token"], [{"n_decoded": 0, "n_remain": 0}])

    def test_llama_server_down_reads_as_offline(self):
        def down(request):
            raise httpx.ConnectError("refused", request=request)
        with self.client(httpx.MockTransport(down)) as c:
            self.assertEqual(c.get("/metrics").status_code, 502)
            self.assertEqual(c.get("/slots").status_code, 502)
            self.assertEqual(c.get("/healthz").status_code, 200)
        with self.client(llama(self.calls, status=501)) as c:
            self.assertIn("--metrics", c.get("/metrics").text)
            self.assertEqual(c.get("/slots").status_code, 502)

    def test_hardware_in_the_sidecar_shape(self):
        gpu = {"util": "37", "temp": "61", "power": "88.5", "power_limit": "130.0", "fan": "40",
               "clock_gpu": "2400", "clock_mem": "8001", "vram_used": "6000", "vram_total": "16376", "vram_free": "10376"}
        with self.client(gpu=lambda: gpu) as c:
            hw = c.get("/hw").json()
        self.assertEqual(hw["cpu"]["threads"], "3")
        self.assertEqual(hw["cpu"]["cores"], "2")
        self.assertEqual(hw["cpu"]["freq"], "3200")
        self.assertEqual(hw["ram"], {"used": "6.0", "total": "8.0", "percent": 75.0})
        self.assertIn("percent", hw["disk"])
        self.assertEqual(hw["gpu"], gpu)

    def test_cpu_use_is_measured_between_samples(self):
        app = create_app(self.fx.config(), llama(self.calls), gpu=lambda: None)
        with TestClient(app) as c:
            self.assertEqual(c.get("/hw").json()["cpu"]["percent"], 0.0)  # no earlier sample
            # busy 200 -> 300 of total 1000 -> 1200: half the new time was busy.
            (self.fx.root / "proc" / "stat").write_text("cpu  150 0 150 800 100 0 0 0 0 0\n")
            app.state.hw = (0.0, None)
            self.assertEqual(c.get("/hw").json()["cpu"]["percent"], 50.0)

    def test_hardware_is_cached_between_viewers(self):
        runs = []
        with self.client(gpu=lambda: runs.append(1)) as c:
            c.get("/hw"); c.get("/hw"); c.get("/hw")
        self.assertEqual(len(runs), 1)

    def test_no_nvidia_gpu_leaves_the_gpu_out(self):
        with self.client() as c:
            self.assertNotIn("gpu", c.get("/hw").json())

    def test_gpu_info_reads_gpu_zero(self):
        def run(cmd, **kw):
            self.assertIn("--id=0", cmd)
            return subprocess.CompletedProcess(cmd, 0, "37, 61, 88.50, 130.00, [N/A], 2400, 8001, 6000, 16376, 10376\n", "")
        info = gpu_info(run)
        self.assertEqual(info["util"], "37")
        self.assertEqual(info["fan"], "0")  # [N/A] would draw NaN
        self.assertEqual(info["power"], "88.50")

        def missing(cmd, **kw):
            raise FileNotFoundError("nvidia-smi")
        self.assertIsNone(gpu_info(missing))
        self.assertIsNone(gpu_info(lambda cmd, **kw: subprocess.CompletedProcess(cmd, 9, "", "NVML mismatch")))
        self.assertIsNone(gpu_info(lambda cmd, **kw: subprocess.CompletedProcess(cmd, 0, "1, 2\n", "")))

    def test_monitor_html_is_the_pinned_upstream_file(self):
        digest = hashlib.sha256((HERE / "monitor.html").read_bytes()).hexdigest()
        self.assertEqual(digest, dashboard.MONITOR_SHA256)
        self.assertRegex(dashboard.DASHBOARD_COMMIT, r"^[0-9a-f]{40}$")

    def test_the_page_polls_only_what_this_service_serves(self):
        page = (HERE / "monitor.html").read_text()
        for path in ("'/metrics'", "'/slots'", "'/hw'"):
            self.assertIn(path, page)
        for field in ("is_processing", "n_ctx", "n_decoded", "n_remain"):
            self.assertIn(field, page)


if __name__ == "__main__":
    unittest.main()
