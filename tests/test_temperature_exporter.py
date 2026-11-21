"""Sensor readings are exported as bounded, valid Prometheus series."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler


SOURCE = Path(__file__).resolve().parents[1] / "services/temperature-exporter/exporter.py"
spec = importlib.util.spec_from_file_location("temperature_exporter", SOURCE)
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class TemperatureExporterTest(unittest.TestCase):
    def test_collect_cpu_amd_and_nvidia(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cpu = root / "hwmon0"
            amd = root / "hwmon1"
            cpu.mkdir()
            amd.mkdir()
            (cpu / "name").write_text("k10temp\n")
            (cpu / "temp1_input").write_text("62500\n")
            (cpu / "temp1_label").write_text("Tctl\n")
            (amd / "name").write_text("amdgpu\n")
            (amd / "temp1_input").write_text("71000\n")
            (amd / "temp1_label").write_text("edge\n")
            (amd / "temp2_input").write_text("999999\n")
            result = subprocess.CompletedProcess([], 0, "GPU-test, 68\n", "")
            with patch.object(exporter.subprocess, "run", return_value=result):
                text = exporter.collect(str(root))
            self.assertIn('osr_cpu_temperature_celsius{driver="k10temp",chip=', text)
            self.assertIn('sensor="Tctl"} 62.5', text)
            self.assertIn('osr_gpu_temperature_celsius{vendor="amd",device="hwmon1",sensor="edge"} 71', text)
            self.assertIn('osr_gpu_temperature_celsius{vendor="nvidia",device="GPU-test",sensor="gpu"} 68', text)
            self.assertNotIn("999.999", text)

    def test_missing_sensors_do_not_fail_scrape(self):
        with patch.object(exporter.subprocess, "run", side_effect=FileNotFoundError):
            text = exporter.collect("/path/that/does/not/exist")
        self.assertIn("# TYPE osr_cpu_temperature_celsius gauge", text)
        self.assertNotIn("osr_gpu_temperature_celsius{", text)

    def test_endpoint_requires_bearer_token(self):
        with tempfile.TemporaryDirectory() as directory:
            token_file = Path(directory) / "token"
            token_file.write_text("test-secret\n")
            ready = threading.Event()
            servers = []
            original = exporter.ThreadingHTTPServer

            def make_server(address, handler):
                server = original(address, handler)
                servers.append(server)
                ready.set()
                return server

            with patch.object(exporter, "ThreadingHTTPServer", side_effect=make_server):
                thread = threading.Thread(target=exporter.serve,
                                          args=("127.0.0.1", 0, "127.0.0.1", str(token_file)),
                                          daemon=True)
                thread.start()
                self.assertTrue(ready.wait(2))
                url = f"http://127.0.0.1:{servers[0].server_port}/metrics"
                opener = build_opener(ProxyHandler({}))
                try:
                    with self.assertRaises(HTTPError) as denied:
                        opener.open(url, timeout=2)
                    self.assertEqual(denied.exception.code, 401)
                    denied.exception.close()
                    request = Request(url, headers={"Authorization": "Bearer test-secret"})
                    with opener.open(request, timeout=2) as response:
                        self.assertIn(b"# TYPE osr_cpu_temperature_celsius gauge", response.read())
                finally:
                    servers[0].shutdown()
                    servers[0].server_close()
                    thread.join(2)


if __name__ == "__main__":
    unittest.main()
