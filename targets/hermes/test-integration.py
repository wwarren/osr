"""Mock Open WebUI's admin API and Hermes's API server to check that the
OpenAI connection is added safely.

Run: python3 targets/hermes/test-integration.py (stdlib only).
"""
import copy
import http.server
import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).with_name("integrate-webui.py")
SPEC = importlib.util.spec_from_file_location("hermes_integrate_webui", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

ROUTER = "http://127.0.0.1:8000/v1"
TASKS = {"TASK_MODEL": "", "TASK_MODEL_EXTERNAL": "", "ENABLE_TITLE_GENERATION": True,
         "TITLE_GENERATION_PROMPT_TEMPLATE": "", "AUTOCOMPLETE_GENERATION_INPUT_MAX_LENGTH": -1}


class Handler(http.server.BaseHTTPRequestHandler):
    """Open WebUI under /openai and /api; Hermes under /hermes/v1."""
    config = {}
    tasks = {}
    models = []
    hermes_key = "hermes-secret"
    hermes_models = ["hermes-agent"]
    updates = 0
    task_updates = 0
    drop_on_save = False
    task_update_status = 200

    def log_message(self, *_args):
        pass

    def reply(self, status, value):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def hermes_models_reply(self, key):
        if key != self.hermes_key:
            return 401, {"error": {"message": "Invalid API key"}}
        return 200, {"object": "list", "data": [{"id": m} for m in self.hermes_models]}

    def admin(self):
        if self.headers.get("Authorization") != "Bearer admin-secret":
            self.reply(403, {"detail": "not an admin"})
            return False
        return True

    def do_GET(self):
        if self.path == "/hermes/v1/models":
            auth = self.headers.get("Authorization", "")
            self.reply(*self.hermes_models_reply(auth.removeprefix("Bearer ")))
            return
        if not self.admin():
            return
        if self.path == "/openai/config":
            self.reply(200, self.config)
        elif self.path == "/api/v1/tasks/config":
            self.reply(200, self.tasks)
        elif self.path == "/api/models":
            self.reply(200, {"data": [{"id": m} for m in self.models]})
        else:
            self.reply(404, {})

    def do_POST(self):
        if not self.admin():
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/openai/verify":
            # Open WebUI's backend calls {url}/models with the key it was given.
            if not body["url"].endswith("/hermes/v1"):
                self.reply(500, {"detail": "Open WebUI: Server Connection Error"})
                return
            status, value = self.hermes_models_reply(body["key"])
            self.reply(200 if status == 200 else 400, value)
        elif self.path == "/openai/config/update":
            type(self).updates += 1
            if not self.drop_on_save:
                type(self).config = body
            self.reply(200, self.config)
        elif self.path == "/api/v1/tasks/config/update":
            type(self).task_updates += 1
            if self.task_update_status != 200:
                self.reply(self.task_update_status, {"detail": "validation error"})
                return
            type(self).tasks = body
            self.reply(200, body)
        else:
            self.reply(404, {})


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        Handler.config = {"ENABLE_OPENAI_API": True, "OPENAI_API_BASE_URLS": [ROUTER],
                          "OPENAI_API_KEYS": ["router-key"],
                          "OPENAI_API_CONFIGS": {"0": {"enable": True, "prefix_id": ""}}}
        Handler.tasks = copy.deepcopy(TASKS)
        Handler.models = ["auto", "fast", "large", "hermes-agent"]
        Handler.hermes_key = "hermes-secret"
        Handler.hermes_models = ["hermes-agent"]
        Handler.updates = 0
        Handler.task_updates = 0
        Handler.drop_on_save = False
        Handler.task_update_status = 200
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.temp = tempfile.TemporaryDirectory()
        self.admin = pathlib.Path(self.temp.name, "admin")
        self.key = pathlib.Path(self.temp.name, "key")
        self.admin.write_text("admin-secret\n")
        self.key.write_text("hermes-secret\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def invoke(self, *extra, hermes_url=None):
        argv = ["integrate-webui.py", "--webui-url", self.base,
                "--hermes-url", hermes_url or f"{self.base}/hermes/v1",
                "--admin-token-file", str(self.admin), "--hermes-key-file", str(self.key), *extra]
        with patch("sys.argv", argv):
            MODULE.main()

    def test_add_keeps_the_router_connection_first(self):
        self.invoke()
        cfg = Handler.config
        self.assertEqual(cfg["OPENAI_API_BASE_URLS"], [ROUTER, f"{self.base}/hermes/v1"])
        self.assertEqual(cfg["OPENAI_API_KEYS"], ["router-key", "hermes-secret"])
        self.assertEqual(cfg["OPENAI_API_CONFIGS"]["0"], {"enable": True, "prefix_id": ""})
        self.assertTrue(cfg["OPENAI_API_CONFIGS"]["1"]["enable"])
        self.assertTrue(cfg["ENABLE_OPENAI_API"])

    def test_rerun_updates_in_place_and_keeps_admin_choices(self):
        self.invoke()
        Handler.config["OPENAI_API_CONFIGS"]["1"]["model_ids"] = ["hermes-agent"]
        Handler.config["OPENAI_API_CONFIGS"]["1"]["enable"] = False
        Handler.hermes_key = "rotated-secret"
        self.key.write_text("rotated-secret\n")
        self.invoke(hermes_url=f"{self.base}/hermes/v1/")
        cfg = Handler.config
        self.assertEqual(len(cfg["OPENAI_API_BASE_URLS"]), 2)
        self.assertEqual(cfg["OPENAI_API_KEYS"][1], "rotated-secret")
        self.assertEqual(cfg["OPENAI_API_CONFIGS"]["1"]["model_ids"], ["hermes-agent"])
        self.assertTrue(cfg["OPENAI_API_CONFIGS"]["1"]["enable"])

    def test_short_key_list_is_padded_so_indices_line_up(self):
        Handler.config["OPENAI_API_BASE_URLS"] = [ROUTER, "http://other:1/v1"]
        Handler.config["OPENAI_API_KEYS"] = ["router-key"]
        self.invoke()
        self.assertEqual(Handler.config["OPENAI_API_KEYS"], ["router-key", "", "hermes-secret"])

    def test_wrong_key_is_caught_before_saving(self):
        Handler.hermes_key = "the-real-key"
        with self.assertRaises(RuntimeError) as caught:
            self.invoke()
        self.assertIn("rejected the API key", str(caught.exception))
        self.assertEqual(Handler.updates, 0)

    def test_model_not_advertised_is_refused(self):
        Handler.hermes_models = ["something-else"]
        with self.assertRaises(RuntimeError):
            self.invoke()
        self.assertEqual(Handler.updates, 0)

    def test_open_webui_cannot_reach_hermes(self):
        # Hermes answers this script (run in the router CT) but Open WebUI's
        # verify fails, as when the Hermes firewall does not admit the router.
        with patch.object(MODULE, "check_hermes"), self.assertRaises(RuntimeError):
            self.invoke(hermes_url=f"{self.base}/unreachable/v1")
        self.assertEqual(Handler.updates, 0)

    def test_duplicate_connections_are_refused(self):
        url = f"{self.base}/hermes/v1"
        Handler.config["OPENAI_API_BASE_URLS"] = [ROUTER, url, url + "/"]
        Handler.config["OPENAI_API_KEYS"] = ["a", "b", "c"]
        with self.assertRaises(RuntimeError) as caught:
            self.invoke()
        self.assertIn("connections to", str(caught.exception))
        self.assertEqual(Handler.updates, 0)

    def test_malformed_config_is_refused(self):
        Handler.config["OPENAI_API_BASE_URLS"] = "not-a-list"
        with self.assertRaises(RuntimeError):
            self.invoke()
        self.assertEqual(Handler.updates, 0)

    def test_a_save_that_is_not_retained_fails(self):
        Handler.drop_on_save = True
        with self.assertRaises(RuntimeError) as caught:
            self.invoke()
        self.assertIn("did not retain", str(caught.exception))

    def test_url_must_end_in_v1(self):
        with self.assertRaises(RuntimeError):
            self.invoke(hermes_url=f"{self.base}/hermes")

    def test_task_model_is_set_when_unset(self):
        self.invoke("--task-model", "fast")
        self.assertEqual(Handler.tasks["TASK_MODEL_EXTERNAL"], "fast")
        # Every other field is sent back unchanged (the form requires them all).
        self.assertEqual({k: v for k, v in Handler.tasks.items() if k != "TASK_MODEL_EXTERNAL"},
                         {k: v for k, v in TASKS.items() if k != "TASK_MODEL_EXTERNAL"})

    def test_task_model_choice_is_kept_unless_it_is_hermes(self):
        Handler.tasks["TASK_MODEL_EXTERNAL"] = "large"
        self.invoke("--task-model", "fast")
        self.assertEqual(Handler.tasks["TASK_MODEL_EXTERNAL"], "large")
        self.assertEqual(Handler.task_updates, 0)
        Handler.tasks["TASK_MODEL_EXTERNAL"] = "hermes-agent"
        self.invoke("--task-model", "fast")
        self.assertEqual(Handler.tasks["TASK_MODEL_EXTERNAL"], "fast")

    def test_task_model_problems_warn_but_keep_the_connection(self):
        Handler.models = ["auto", "hermes-agent"]          # "fast" is not listed
        with patch("builtins.print") as printed:
            self.invoke("--task-model", "fast")
        self.assertEqual(Handler.task_updates, 0)
        self.assertIn("WARNING", " ".join(str(c) for c in printed.call_args_list))
        Handler.models = ["fast", "hermes-agent"]
        Handler.task_update_status = 422
        with patch("builtins.print") as printed:
            self.invoke("--task-model", "fast")
        self.assertIn("could not set the task model", " ".join(str(c) for c in printed.call_args_list))
        self.assertEqual(len(Handler.config["OPENAI_API_BASE_URLS"]), 2)

    def test_no_task_model_leaves_tasks_alone(self):
        self.invoke()
        self.assertEqual(Handler.task_updates, 0)


if __name__ == "__main__":
    unittest.main()
