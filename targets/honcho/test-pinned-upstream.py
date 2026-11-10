#!/usr/bin/env python3
"""test-pinned-upstream.py HONCHO_CHECKOUT

Check that the Honcho release this target installs (HONCHO_REF's default in
install-target.sh) honours the model-client timeout the target writes, using
Honcho's own code. Run it with the checkout's environment, as the
honcho-upstream CI job does:

    uv --directory CHECKOUT sync --frozen --no-dev
    uv --directory CHECKOUT run --frozen --no-dev python \
        "$PWD/targets/honcho/test-pinned-upstream.py" CHECKOUT

The target's install-target.sh writes the honcho.env block, here with a
2-second budget. For every model config it writes (the deriver, summary, both
dream phases and every dialectic level), Honcho's settings loader, its
resolve_model_config and execute_completion must hand the OpenAI client a
per-request timeout of twice that budget. Then the OpenAI SDK Honcho
pins, against a server that stays silent, must give up after that timeout.
A Kindi that accepts a request and never answers, behind this target's own
dispatcher, must get exactly one POST through the dispatcher, the SDK and
Honcho's outer retry loop.

Honcho's settings loader must also read the local embedding model's block as
written: its model, URL, vector size, no dimensions= field, float vectors,
the timeout and the CPU-sized input and request limits.

The client gateway's workspace keys must be read by Honcho's own JWT check as
keys for one workspace, and the MCP server must still bind each session to
its key (what keeps one Open WebUI user out of another's session).

Change the target's HONCHO_REF default only after this passes against it.
"""
import asyncio
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
INSTALLER = HERE / "install-target.sh"
BUDGET = 2  # KINDI_READ_TIMEOUT_SECONDS for this check
failures = []


def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)


def pinned_ref():
    match = re.search(r"^ref=\$\{HONCHO_REF:-([^}]+)\}$", INSTALLER.read_text(), re.M)
    if not match:
        raise SystemExit("No HONCHO_REF default in " + str(INSTALLER))
    return match.group(1)


def installer_value(name):
    """A constant install-target.sh sets at its top (embedding_model=...)."""
    match = re.search(r"^%s=(\S+)$" % re.escape(name), INSTALLER.read_text(), re.M)
    if not match:
        raise SystemExit(f"No {name}= in {INSTALLER}")
    return match.group(1)


def honcho_env():
    """The honcho.env lines install-target.sh writes, from its own block."""
    text = INSTALLER.read_text()
    start = text.index("llm_timeout=$((KINDI_READ_TIMEOUT_SECONDS * 2))")
    end = text.index('} > "$etc/honcho.env"', start)
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp, "jwt-secret").write_text("jwt\n")
        Path(tmp, "budgets.settings").write_text("")
        script = text[start:end] + "}\n"
        env = {"PATH": os.environ["PATH"], "KINDI_READ_TIMEOUT_SECONDS": str(BUDGET), "etc": tmp,
               "deploy": tmp, "db_password": "pw", "model": "fast", "proxy_url": "http://127.0.0.1:9",
               "structured_output_mode": "",
               **{name: installer_value(name) for name in
                  ("embedding_model", "embedding_dimensions", "embedding_url")}}
        out = subprocess.run(["bash", "-euc", script], env=env, check=True,
                             capture_output=True, text=True).stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


class Recorder:
    """An AsyncOpenAI stand-in that records what chat.completions.create gets."""
    def __init__(self):
        self.calls = []
        self.chat = self
        self.completions = self

    async def create(self, **params):
        self.calls.append(params)
        from types import SimpleNamespace as NS
        message = NS(content="ok", tool_calls=None, role="assistant", refusal=None)
        return NS(id="x", model=params["model"], choices=[NS(message=message, finish_reason="stop", index=0)],
                  usage=NS(prompt_tokens=1, completion_tokens=1, total_tokens=2,
                           prompt_tokens_details=None, completion_tokens_details=None))


class Silent(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        time.sleep(BUDGET * 2 + 3)

    def log_message(self, *args):
        pass


class SilentKindi(BaseHTTPRequestHandler):
    """A Kindi that accepts a chat request and never answers it."""
    requests = 0

    def do_GET(self):  # /health: idle, so the proxy's drain check lets later requests through
        body = b'{"ok": true, "kindi": "0.4.0", "busy": null}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        type(self).requests += 1
        time.sleep(3)

    def log_message(self, *args):
        pass


def gateway_module():
    """The target's client gateway (honcho-gateway.py)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("osr_honcho_gateway", HERE / "honcho-gateway.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def dispatcher_module():
    """The target's own dispatcher (direct_dispatch.py), as the proxy runs it."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("osr_direct_dispatch", HERE / "direct_dispatch.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(checkout):
    checkout = Path(checkout).resolve()
    tag = subprocess.run(["git", "-C", str(checkout), "describe", "--tags", "--exact-match"],
                         capture_output=True, text=True).stdout.strip()
    check(tag == pinned_ref(), f"the checkout is the pinned release {pinned_ref()} ({tag or 'no tag'})")

    env = honcho_env()
    want = float(BUDGET * 2)
    names = [k for k in env if k.endswith("__OVERRIDES__PROVIDER_PARAMS__TIMEOUT")]
    check(len(names) == 9 and all(env[k] == str(BUDGET * 2) for k in names),
          f"the target writes a {BUDGET * 2} s client timeout for 9 model configs ({len(names)})")
    os.environ.update(env)
    os.environ.setdefault("DB_CONNECTION_URI", env["DB_CONNECTION_URI"])
    sys.path.insert(0, str(checkout))
    os.chdir(checkout)
    # Honcho loads tiktoken's o200k_base at import, from the network. Token
    # counts play no part in the timeout, so a stand-in keeps this offline.
    import tiktoken  # noqa: E402

    class Encoding:
        def encode(self, text, **_):
            return list(range(len(text) // 4))

        def decode(self, tokens):
            return ""

    tiktoken.get_encoding = lambda name: Encoding()
    from src.config import resolve_model_config, settings  # noqa: E402 (the pinned release's own code)
    from src.llm.backends.openai import OpenAIBackend  # noqa: E402
    from src.llm.request_builder import execute_completion  # noqa: E402

    configs = {"DERIVER": settings.DERIVER.MODEL_CONFIG, "SUMMARY": settings.SUMMARY.MODEL_CONFIG,
               "DREAM_DEDUCTION": settings.DREAM.DEDUCTION_MODEL_CONFIG,
               "DREAM_INDUCTION": settings.DREAM.INDUCTION_MODEL_CONFIG}
    configs.update({f"DIALECTIC {level}": entry.MODEL_CONFIG
                    for level, entry in settings.DIALECTIC.LEVELS.items()})
    for name, configured in configs.items():
        config = resolve_model_config(configured)
        recorder = Recorder()
        asyncio.run(execute_completion(OpenAIBackend(recorder), config,
                                       messages=[{"role": "user", "content": "hi"}], max_tokens=8))
        sent = recorder.calls[0] if recorder.calls else {}
        check(config.transport == "openai" and config.base_url == "http://127.0.0.1:9/v1"
              and sent.get("timeout") == want and "timeout" not in (sent.get("extra_body") or {}),
              f"{name}: Honcho sends the OpenAI client timeout={sent.get('timeout')} to {config.base_url}")

    # The local embedding model's block, as Honcho reads it.
    embedding = settings.EMBEDDING
    overrides = embedding.MODEL_CONFIG.overrides
    url = installer_value("embedding_url") + "/v1"
    check(embedding.MODEL_CONFIG.model == installer_value("embedding_model") and overrides.base_url == url
          and embedding.MODEL_CONFIG.transport == "openai" and bool(overrides.api_key),
          f"embeddings go to {embedding.MODEL_CONFIG.model} at {overrides.base_url}")
    check(embedding.VECTOR_DIMENSIONS == int(installer_value("embedding_dimensions"))
          and embedding.MODEL_CONFIG.dimensions_mode == "never"
          and not embedding.resolve_send_dimensions(),
          f"{embedding.VECTOR_DIMENSIONS}-value vectors, without a dimensions= field")
    check(embedding.MODEL_CONFIG.encoding_format_mode == "float" and embedding.MODEL_CONFIG.timeout == 600,
          f"float vectors, a {embedding.MODEL_CONFIG.timeout} s timeout")
    check((embedding.MAX_INPUT_TOKENS, embedding.MAX_TOKENS_PER_REQUEST, embedding.MAX_CONCURRENT_EMBEDDINGS)
          == (1536, 4096, 2),
          f"inputs of {embedding.MAX_INPUT_TOKENS} tokens, {embedding.MAX_TOKENS_PER_REQUEST} a request, "
          f"{embedding.MAX_CONCURRENT_EMBEDDINGS} at a time")

    # The OpenAI SDK Honcho pins gives up after that per-request timeout.
    import openai  # noqa: E402
    server = ThreadingHTTPServer(("127.0.0.1", 0), Silent)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    client = openai.AsyncOpenAI(base_url="http://127.0.0.1:%d/v1" % server.server_address[1],
                                api_key="x", max_retries=0)
    started = time.monotonic()
    try:
        asyncio.run(client.chat.completions.create(model="fast", messages=[{"role": "user", "content": "hi"}],
                                                   timeout=want))
        error = None
    except openai.APITimeoutError as exc:
        error = exc
    elapsed = time.monotonic() - started
    server.shutdown()
    check(error is not None and want - 0.5 <= elapsed < want + 2.5,
          f"openai {openai.__version__} stops a silent request after the timeout ({elapsed:.1f} s)")

    # A Kindi that accepts the request and never answers, behind the target's
    # own dispatcher: the dispatcher answers 424 with x-should-retry: false,
    # and neither the OpenAI SDK nor Honcho's retry loop sends it again.
    from src.config import ConfiguredModelSettings, ModelOverrideSettings  # noqa: E402
    from src.llm.api import honcho_llm_call  # noqa: E402

    SilentKindi.requests = 0
    kindi = ThreadingHTTPServer(("127.0.0.1", 0), SilentKindi)
    threading.Thread(target=kindi.serve_forever, daemon=True).start()
    direct = dispatcher_module()
    direct.KINDI_READ_TIMEOUT = 1
    direct.Handler.dispatcher = direct.Dispatcher(
        "http://127.0.0.1:9", "router-key", targets={"kindi-a": "kindi+http://127.0.0.1:%d" % kindi.server_address[1]})
    proxy = ThreadingHTTPServer(("127.0.0.1", 0), direct.Handler)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    config = ConfiguredModelSettings(
        model="bonsai2-2b", transport="openai",
        overrides=ModelOverrideSettings(
            base_url="http://127.0.0.1:%d/t/kindi-a/v1" % proxy.server_address[1],
            provider_params={"timeout": 4.0}),
    )
    try:
        asyncio.run(honcho_llm_call(model_config=config, prompt="hi", max_tokens=8,
                                    retry_attempts=3))
        error = None
    except Exception as exc:  # noqa: BLE001 - the count is what matters
        error = exc
    finally:
        proxy.shutdown()
        proxy.server_close()
        kindi.shutdown()
        kindi.server_close()
    status = getattr(getattr(error, "__cause__", None) or error, "status_code", None)
    check(error is not None and SilentKindi.requests == 1,
          f"a Kindi that never answers gets one POST through the dispatcher, the SDK and Honcho's "
          f"retries ({SilentKindi.requests} sent; {type(error).__name__ if error else 'no error'}, HTTP {status})")

    # The client gateway signs each workspace's key itself. Honcho must read it
    # as a key for that one workspace (never admin, peer or session scoped),
    # accept a per-user workspace name, and its MCP server must bind a session
    # to its key and take the workspace from X-Honcho-Workspace-ID.
    from src.schemas import WorkspaceCreate  # noqa: E402
    from src.security import verify_jwt  # noqa: E402
    gateway = gateway_module()
    workspace = gateway.workspace_name("openwebui", "a" * 128)
    params = verify_jwt(gateway.mint_jwt(settings.AUTH.JWT_SECRET.encode(), workspace))
    check(params.w == workspace and not params.ad and params.p is None and params.s is None
          and params.sc is None and params.exp is None,
          f"Honcho reads the gateway's key as a key for workspace {workspace} alone")
    check(WorkspaceCreate(name=workspace).name == workspace, "Honcho accepts a per-user workspace name")
    http_ts = (checkout / "mcp" / "src" / "http.ts").read_text()
    config_ts = (checkout / "mcp" / "src" / "config.ts").read_text()
    check("config.apiKey !== existing.apiKey" in http_ts,
          "Honcho's MCP server refuses a session's requests made with another key")
    check('request.headers.get("X-Honcho-Workspace-ID")' in config_ts and 'process.env.HOST' in http_ts,
          "Honcho's MCP server takes the workspace header and listens where HOST says")

    print(f"{'FAILED' if failures else 'OK'}: {len(failures)} failure(s) against Honcho {pinned_ref()}")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    sys.exit(main(sys.argv[1]))
