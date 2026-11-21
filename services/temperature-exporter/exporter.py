#!/usr/bin/env python3
"""Read Proxmox host CPU/GPU sensors for the OSR Prometheus dashboard."""

import argparse
import glob
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import subprocess


CPU_DRIVERS = {"coretemp", "k10temp", "zenpower", "cpu_thermal"}
GPU_DRIVERS = {"amdgpu": "amd", "i915": "intel", "xe": "intel"}


def _label(value):
    return '"' + str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"') + '"'


def _temperature(path):
    try:
        value = int(Path(path).read_text().strip()) / 1000
    except (OSError, ValueError):
        return None
    return value if -30 <= value <= 150 else None


def collect(hwmon_root="/sys/class/hwmon", nvidia_smi="nvidia-smi"):
    """Return Prometheus text; absent or unreadable sensors emit no sample."""
    lines = [
        "# HELP osr_cpu_temperature_celsius Proxmox host CPU sensor temperature in Celsius.",
        "# TYPE osr_cpu_temperature_celsius gauge",
        "# HELP osr_gpu_temperature_celsius Proxmox host GPU temperature in Celsius.",
        "# TYPE osr_gpu_temperature_celsius gauge",
    ]
    for directory in sorted(glob.glob(f"{hwmon_root}/hwmon*")):
        base = Path(directory)
        try:
            driver = (base / "name").read_text().strip()
        except OSError:
            continue
        if driver not in CPU_DRIVERS and driver not in GPU_DRIVERS:
            continue
        pci = re.search(r"(?<![0-9a-f])([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])", str(base.resolve()), re.I)
        for sensor in sorted(base.glob("temp*_input")):
            value = _temperature(sensor)
            if value is None:
                continue
            prefix = sensor.name.removesuffix("_input")
            try:
                label = (base / f"{prefix}_label").read_text().strip()
            except OSError:
                label = prefix
            if driver in CPU_DRIVERS:
                labels = f'driver={_label(driver)},sensor={_label(label)}'
                lines.append(f"osr_cpu_temperature_celsius{{{labels}}} {value:g}")
            else:
                # PCI address remains stable if hwmon enumeration changes.
                device = pci.group(1).lower() if pci else base.name
                labels = f'vendor={_label(GPU_DRIVERS[driver])},device={_label(device)},sensor={_label(label)}'
                lines.append(f"osr_gpu_temperature_celsius{{{labels}}} {value:g}")
    try:
        result = subprocess.run(
            [nvidia_smi, "--query-gpu=uuid,temperature.gpu", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=4, check=True,
        )
    except (OSError, subprocess.SubprocessError):
        result = None
    if result:
        for row in result.stdout.splitlines():
            parts = [part.strip() for part in row.split(",")]
            if len(parts) != 2 or not parts[0].startswith("GPU-"):
                continue
            try:
                value = float(parts[1])
            except ValueError:
                continue
            if -30 <= value <= 150:
                labels = f'vendor="nvidia",device={_label(parts[0])},sensor="gpu"'
                lines.append(f"osr_gpu_temperature_celsius{{{labels}}} {value:g}")
    return "\n".join(lines) + "\n"


def serve(bind, port, allowed_ip, token_file):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/metrics":
                self.send_error(404)
                return
            if self.client_address[0] != allowed_ip:
                self.send_error(403)
                return
            try:
                token = Path(token_file).read_text().strip()
            except OSError:
                self.send_error(503)
                return
            supplied = self.headers.get("Authorization", "")
            if not token or not hmac.compare_digest(supplied, f"Bearer {token}"):
                self.send_response(401)
                self.send_header("WWW-Authenticate", "Bearer")
                self.end_headers()
                return
            body = collect().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    ThreadingHTTPServer((bind, port), Handler).serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--allow", required=True)
    parser.add_argument("--port", type=int, default=9408)
    parser.add_argument("--token-file", default="/etc/osr-temperature-exporter/token")
    args = parser.parse_args()
    serve(args.bind, args.port, args.allow, args.token_file)
