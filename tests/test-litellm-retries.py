#!/usr/bin/env python3
"""How the pinned LiteLLM retries a request for a tier with a Kindi deployment.

Kindi serves one request at a time, and its guide asks for one retry at most:
a retry after a timeout queues behind the request Kindi is still reading. OSR
limits LiteLLM's retries in two places, and this test runs both against the
LiteLLM release the router CT installs (services/litellm-proxy/requirements.lock):

  * router_settings.model_group_retry_policy, exactly as the installer writes
    it (litellm_router_settings): no retry after a timeout, one after a 429;
  * the x-litellm-num-retries: 1 header the router sends for such a tier,
    which LiteLLM's proxy turns into the request's num_retries. LiteLLM 1.75
    does not read a policy's InternalServerErrorRetries, so this is what caps a
    5xx at one retry.

A local HTTP server plays the Kindi deployment and counts the attempts.

Run it with the LiteLLM venv's interpreter (LITELLM_PYTHON in run-tests.sh):
    /app/litellm/venv/bin/python tests/test-litellm-retries.py
"""
import asyncio
import inspect
import json
import subprocess
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "ollama-smart-router-install.sh"
LOCK = ROOT / "services/litellm-proxy/requirements.lock"

try:
    import litellm
    import yaml
    from litellm.proxy._types import UserAPIKeyAuth
    from litellm.proxy.litellm_pre_call_utils import LiteLLMProxyRequestSetup
except ImportError as exc:  # the runner's skip parser reports this line
    print(f"SKIP test-litellm-retries: needs the pinned LiteLLM ({exc}); "
          "set LITELLM_PYTHON to the LiteLLM venv's python")
    sys.exit(0)


def pinned_version():
    for line in LOCK.read_text().splitlines():
        if line.startswith("litellm=="):
            return line.split("==", 1)[1].split()[0]
    raise AssertionError("no litellm pin in " + str(LOCK))


class Kindi(BaseHTTPRequestHandler):
    """A one-model OpenAI server: answers every chat request with STATUS, or
    stays silent past the client's timeout when STATUS is 0."""
    status = 500
    attempts = 0
    lock = threading.Lock()

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        with Kindi.lock:
            Kindi.attempts += 1
        if Kindi.status == 0:
            time.sleep(2.5)  # reading the prompt, past the 1 s timeout below
            return
        if Kindi.status == 200:
            body = {"id": "x", "object": "chat.completion", "created": 1, "model": "bonsai2-2b",
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant", "content": "ok"}}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}
        else:
            body = {"error": {"message": "kindi says no", "type": "server_error"}}
        data = json.dumps(body).encode()
        self.send_response(Kindi.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Retry-After", "0")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def router_settings(base):
    """router_settings for one fast tier on a Kindi server, from the installer."""
    script = ("source <(sed -n '/^litellm_router_settings() {/,/^}/p' \"$1\"); "
              "printf 'fast bonsai2-2b@kindi+%s\\n' \"$2\" | litellm_router_settings")
    out = subprocess.run(["bash", "-c", script, "-", str(INSTALLER), base],
                         check=True, capture_output=True, text=True).stdout
    return yaml.safe_load(out)["router_settings"]


class KindiRetries(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Kindi)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_address[1]
        cls.settings = router_settings(cls.base)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def router(self):
        # As the proxy builds it: every router_settings key Router accepts.
        accepted = set(inspect.signature(litellm.Router).parameters)
        settings = {k: v for k, v in self.settings.items() if k in accepted}
        model_list = [{"model_name": "fast", "litellm_params": {
            "model": "openai/bonsai2-2b", "api_base": self.base + "/v1",
            "api_key": "none", "timeout": 1}}]
        return litellm.Router(model_list=model_list, retry_after=0, disable_cooldowns=True,
                              **settings)

    def attempts(self, status, **request):
        """Kindi's attempt count for one chat request that answers STATUS."""
        Kindi.status, Kindi.attempts = status, 0
        router = self.router()

        async def call():
            try:
                await router.acompletion(model="fast", messages=[{"role": "user", "content": "hi"}],
                                         **request)
            except Exception as exc:  # noqa: BLE001 - the attempt count is what matters
                return exc
            return None

        error = asyncio.run(call())
        if status != 200:
            self.assertIsNotNone(error, "a failing deployment reported success")
        return Kindi.attempts

    def header_retries(self):
        """num_retries from the header the router sends, through the proxy's own setup."""
        data = LiteLLMProxyRequestSetup.add_litellm_data_for_backend_llm_call(
            headers={"x-litellm-num-retries": "1"}, user_api_key_dict=UserAPIKeyAuth(),
            general_settings={})
        return data["num_retries"]

    def test_pinned_release(self):
        import importlib.metadata
        self.assertEqual(importlib.metadata.version("litellm"), pinned_version())

    def test_policy_is_what_the_installer_writes(self):
        policy = self.settings["model_group_retry_policy"]["fast"]
        self.assertEqual(policy, {"TimeoutErrorRetries": 0, "RateLimitErrorRetries": 1})
        self.assertEqual(self.settings["num_retries"], 2)

    def test_header_becomes_num_retries(self):
        self.assertEqual(self.header_retries(), 1)

    def test_server_error_without_the_header_is_retried_twice(self):
        # Why the header exists: the policy cannot cap a 5xx in this release.
        self.assertEqual(self.attempts(500), 3)

    def test_server_error_with_the_header_is_retried_once(self):
        self.assertEqual(self.attempts(500, num_retries=self.header_retries()), 2)

    def test_timeout_is_never_retried(self):
        self.assertEqual(self.attempts(0, num_retries=self.header_retries()), 1)
        self.assertEqual(self.attempts(0), 1)

    def test_rate_limit_is_retried_once(self):
        self.assertEqual(self.attempts(429, num_retries=self.header_retries()), 2)
        self.assertEqual(self.attempts(429), 2)

    def test_success_is_one_attempt(self):
        self.assertEqual(self.attempts(200, num_retries=self.header_retries()), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
