"""Monitor dashboard for the llama.cpp target.

Serves the llama.cpp Monitor Dashboard page (monitor.html, by abhiFSD, MIT:
https://github.com/abhiFSD/llama.cpp-Monitor-Dashboard, pinned in
DASHBOARD_SOURCE below) and the three endpoints it polls, all on one origin:

  /metrics  llama-server's Prometheus counters, passed through unchanged
  /slots    llama-server's slot list, reduced to the numbers the page draws:
            its sampling settings, and the prompt and generated text it adds
            when slot debugging is on, never leave the CT
  /hw       CPU, RAM, disk and NVIDIA GPU figures in the shape of upstream's
            hw-metrics.py sidecar, read from /proc and nvidia-smi, so the
            sidecar (Flask, psutil, a second open port) is not needed

llama-server itself stays on guest loopback. The page is read-only.
"""

import asyncio
import os
import subprocess
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path

import httpx
from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response

# The upstream commit monitor.html was taken from, and the file's SHA-256
# (test-dashboard checks that the copy in this repository still matches).
DASHBOARD_SOURCE = "https://github.com/abhiFSD/llama.cpp-Monitor-Dashboard"
DASHBOARD_COMMIT = "d5254ed42c801f5aa60984b0ceb8df5a804057b1"
MONITOR_SHA256 = "a4e7076fe1092a42276e2d7d74a78865eae691ee38623aa9c5a22b65c3b8ec00"

# The page's script is inline; nothing may load from or talk to another origin
# (connect-src 'self' also stops ?server= from pointing the page elsewhere).
SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
        "img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; "
        "frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}


@dataclass(frozen=True)
class Config:
    base_url: str = "http://127.0.0.1:8081"
    page: str = str(Path(__file__).with_name("monitor.html"))
    proc: str = "/proc"
    disk: str = "/"
    timeout: float = 5

    @classmethod
    def from_env(cls):
        return cls(
            os.getenv("LLAMA_BASE_URL", "http://127.0.0.1:8081").rstrip("/"),
            os.getenv("DASHBOARD_PAGE", str(Path(__file__).with_name("monitor.html"))),
        )


def _int(value):
    """A non-negative int for the page, or 0: nothing else reaches innerHTML."""
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else 0


def reduce_slots(slots):
    """Only the fields monitor.html reads, each forced to a number or bool.

    next_token is a list in current llama-server and an object in older
    builds; the page reads next_token[0], so it is always a one-entry list.
    """
    if not isinstance(slots, list):
        return []
    reduced = []
    for slot in slots:
        if not isinstance(slot, dict):
            continue
        token = slot.get("next_token")
        if isinstance(token, list):
            token = token[0] if token else {}
        if not isinstance(token, dict):
            token = {}
        reduced.append({
            "id": _int(slot.get("id")),
            "n_ctx": _int(slot.get("n_ctx")),
            "is_processing": slot.get("is_processing") is True,
            "next_token": [{"n_decoded": _int(token.get("n_decoded")), "n_remain": _int(token.get("n_remain"))}],
        })
    return reduced


# --- hardware figures (the hw-metrics.py JSON shape) -------------------------

def _read(path):
    try:
        return Path(path).read_text()
    except OSError:
        return ""


def cpu_times(proc):
    """(busy, total) jiffies from the aggregate cpu line of /proc/stat."""
    for line in _read(f"{proc}/stat").splitlines():
        if line.startswith("cpu "):
            fields = [int(x) for x in line.split()[1:] if x.isdigit()]
            idle = sum(fields[3:5])  # idle + iowait
            return sum(fields) - idle, sum(fields)
    return 0, 0


def cpu_info(proc, previous):
    """CPU use since the previous sample, mean clock, cores and threads."""
    busy, total = cpu_times(proc)
    last_busy, last_total = previous or (0, 0)
    percent = 0.0
    if previous is not None and total > last_total:
        percent = round(100.0 * (busy - last_busy) / (total - last_total), 1)
    mhz, cores, threads = [], set(), 0
    physical = core = None
    for line in _read(f"{proc}/cpuinfo").splitlines():
        key, _, value = line.partition(":")
        key, value = key.strip(), value.strip()
        if key == "processor":
            threads += 1
            physical = core = None
        elif key == "physical id":
            physical = value
        elif key == "core id":
            core = value
            cores.add((physical, core))
        elif key == "cpu MHz":
            try:
                mhz.append(float(value))
            except ValueError:
                pass
    threads = threads or os.cpu_count() or 0
    return {
        "percent": max(0.0, min(percent, 100.0)),
        "freq": str(int(sum(mhz) / len(mhz))) if mhz else "--",
        "cores": str(len(cores) or threads or "--"),
        "threads": str(threads or "--"),
    }, (busy, total)


def ram_info(proc):
    values = {}
    for line in _read(f"{proc}/meminfo").splitlines():
        key, _, rest = line.partition(":")
        parts = rest.split()
        if parts and parts[0].isdigit():
            values[key] = int(parts[0]) * 1024
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", values.get("MemFree", 0))
    used = max(total - available, 0)
    return {
        "used": f"{used / 1024 ** 3:.1f}",
        "total": f"{total / 1024 ** 3:.1f}",
        "percent": round(100.0 * used / total, 1) if total else 0,
    }


def disk_info(path):
    try:
        st = os.statvfs(path)
    except OSError:
        return {"percent": 0}
    used = (st.f_blocks - st.f_bfree) * st.f_frsize
    usable = used + st.f_bavail * st.f_frsize
    return {"percent": round(100.0 * used / usable, 1) if usable else 0}


GPU_FIELDS = ("util", "temp", "power", "power_limit", "fan", "clock_gpu", "clock_mem",
              "vram_used", "vram_total", "vram_free")


def gpu_info(run=subprocess.run):
    """GPU 0 as nvidia-smi reports it, or None (no NVIDIA GPU: Vulkan, CPU)."""
    try:
        result = run(
            ["nvidia-smi", "--id=0",
             "--query-gpu=utilization.gpu,temperature.gpu,power.draw,power.limit,fan.speed,"
             "clocks.current.graphics,clocks.current.memory,memory.used,memory.total,memory.free",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    values = [v.strip() for v in result.stdout.strip().splitlines()[0].split(",")] if result.stdout.strip() else []
    if len(values) != len(GPU_FIELDS):
        return None
    # "[N/A]" (no fan, no power reading) would draw NaN; the page shows 0.
    return {k: (v if v.replace(".", "", 1).isdigit() else "0") for k, v in zip(GPU_FIELDS, values)}


def create_app(config=None, transport=None, gpu=gpu_info):
    @asynccontextmanager
    async def lifespan(app):
        app.state.config = config or Config.from_env()
        app.state.cpu = None
        app.state.hw = (0.0, None)
        app.state.hw_lock = asyncio.Lock()
        async with httpx.AsyncClient(timeout=app.state.config.timeout, transport=transport, trust_env=False) as client:
            app.state.client = client
            yield

    app = FastAPI(title="llama.cpp target dashboard", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)

    @app.middleware("http")
    async def headers(request, call_next):
        response = await call_next(request)
        response.headers.update(SECURITY_HEADERS)
        return response

    async def upstream(path):
        cfg = app.state.config
        try:
            response = await app.state.client.get(cfg.base_url + path)
        except httpx.HTTPError:
            return None
        return response if response.status_code == 200 else None

    @app.get("/")
    async def index():
        # hw=. makes the page fetch ./hw from this origin.
        return RedirectResponse("/monitor.html?hw=.", status_code=302)

    @app.get("/monitor.html")
    async def page():
        return FileResponse(app.state.config.page, media_type="text/html; charset=utf-8")

    @app.get("/healthz")
    async def health():
        return {"status": "ok"}

    @app.get("/metrics")
    async def metrics():
        response = await upstream("/metrics")
        if response is None:
            return PlainTextResponse("llama-server metrics unavailable (is it running with --metrics?)\n", status_code=502)
        return Response(response.content, media_type="text/plain; version=0.0.4; charset=utf-8")

    @app.get("/slots")
    async def slots():
        response = await upstream("/slots")
        if response is None:
            return JSONResponse({"error": "llama-server slots unavailable"}, status_code=502)
        try:
            data = response.json()
        except ValueError:
            return JSONResponse({"error": "llama-server returned no slot list"}, status_code=502)
        return reduce_slots(data)

    @app.get("/hw")
    async def hw():
        # Every viewer polls every 2 s; nvidia-smi runs at most once a second.
        async with app.state.hw_lock:
            stamp, cached = app.state.hw
            if cached is None or time.monotonic() - stamp >= 1:
                cfg = app.state.config
                cpu, app.state.cpu = cpu_info(cfg.proc, app.state.cpu)
                data = {"cpu": cpu, "ram": ram_info(cfg.proc), "disk": disk_info(cfg.disk)}
                gpu_now = await asyncio.to_thread(gpu)
                if gpu_now:
                    data["gpu"] = gpu_now
                app.state.hw = (time.monotonic(), data)
                cached = data
        return cached

    return app


app = create_app()
