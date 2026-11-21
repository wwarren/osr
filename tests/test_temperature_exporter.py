"""Sensor readings are exported as bounded, valid Prometheus series."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


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
            self.assertIn('osr_cpu_temperature_celsius{driver="k10temp",sensor="Tctl"} 62.5', text)
            self.assertIn('osr_gpu_temperature_celsius{vendor="amd",device="hwmon1",sensor="edge"} 71', text)
            self.assertIn('osr_gpu_temperature_celsius{vendor="nvidia",device="GPU-test",sensor="gpu"} 68', text)
            self.assertNotIn("999.999", text)

    def test_missing_sensors_do_not_fail_scrape(self):
        with patch.object(exporter.subprocess, "run", side_effect=FileNotFoundError):
            text = exporter.collect("/path/that/does/not/exist")
        self.assertIn("# TYPE osr_cpu_temperature_celsius gauge", text)
        self.assertNotIn("osr_gpu_temperature_celsius{", text)


if __name__ == "__main__":
    unittest.main()
