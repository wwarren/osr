"""Mock Open WebUI's image settings API and the router's image endpoints to
check that tools/webui-images.py makes the router Open WebUI's image engine
safely.

Run: python3 tests/test-webui-images.py (stdlib only).
"""
import asyncio
import copy
import http.server
import importlib.util
import io
import json
import pathlib
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from types import SimpleNamespace
from urllib.parse import urlparse

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools" / "webui-images.py"
SPEC = importlib.util.spec_from_file_location("webui_images", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
KLEIN = json.loads((ROOT / "targets/comfyui/flux2-klein-4b-api.json").read_text())
BUILTIN = {
    "3": {"class_type": "KSampler", "inputs": {}}, "4": {"class_type": "CheckpointLoaderSimple", "inputs": {}},
    "5": {"class_type": "EmptyLatentImage", "inputs": {}}, "6": {"class_type": "CLIPTextEncode", "inputs": {}},
    "7": {"class_type": "CLIPTextEncode", "inputs": {}}, "8": {"class_type": "VAEDecode", "inputs": {}},
    "9": {"class_type": "SaveImage", "inputs": {}},
}
# The shape of GET /api/v1/images/config in Open WebUI 0.12.4 (ImagesConfig).
FRESH = {
    "ENABLE_IMAGE_GENERATION": False, "ENABLE_IMAGE_PROMPT_GENERATION": True,
    "IMAGE_GENERATION_ENGINE": "openai", "IMAGE_GENERATION_MODEL": "", "IMAGE_SIZE": "512x512", "IMAGE_STEPS": 50,
    "IMAGES_OPENAI_API_BASE_URL": "https://api.openai.com/v1", "IMAGES_OPENAI_API_KEY": "sk-keep",
    "IMAGES_OPENAI_API_VERSION": "", "IMAGES_OPENAI_API_PARAMS": None,
    "AUTOMATIC1111_BASE_URL": "", "AUTOMATIC1111_API_AUTH": None, "AUTOMATIC1111_PARAMS": None,
    "COMFYUI_BASE_URL": "", "COMFYUI_API_KEY": "", "COMFYUI_WORKFLOW": json.dumps(BUILTIN, indent=2),
    "COMFYUI_WORKFLOW_NODES": [],
    "IMAGES_GEMINI_API_BASE_URL": "", "IMAGES_GEMINI_API_KEY": "", "IMAGES_GEMINI_ENDPOINT_METHOD": "",
    "ENABLE_IMAGE_EDIT": False, "IMAGE_EDIT_ENGINE": "openai", "IMAGE_EDIT_MODEL": "", "IMAGE_EDIT_SIZE": "",
}

# The shape of GET /api/v1/images/config in Open WebUI 0.13.4: a list of image
# connections replaced the single engine (USER_PERMISSIONS is not returned).
FRESH_013 = {
    "ENABLE_IMAGE_GENERATION": False, "ENABLE_IMAGE_PROMPT_GENERATION": True, "ENABLE_IMAGE_EDIT": False,
    "IMAGE_GENERATION_DEFAULT_MODEL": "", "IMAGE_EDIT_DEFAULT_MODEL": "", "IMAGE_CONNECTIONS": [],
}
REQUIRED_013 = ("ENABLE_IMAGE_GENERATION", "ENABLE_IMAGE_PROMPT_GENERATION", "ENABLE_IMAGE_EDIT")


class Handler(http.server.BaseHTTPRequestHandler):
    """Open WebUI's admin API under /api/v1/images; the router under /router."""
    config = {}
    images = ["image", "flux2-klein-4b-comfyui"]
    keep_engine = False        # an Open WebUI that does not save the engine (0.13: the connections)
    required = tuple(FRESH)
    updates = []
    refreshed = 0

    def log_message(self, *_args):
        pass

    def reply(self, status, value):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def authorised(self, token):
        if self.headers.get("Authorization") != f"Bearer {token}":
            self.reply(401, {"detail": "Not authenticated"})
            return False
        return True

    def do_GET(self):
        cls = type(self)
        if self.path == "/router/v1/images/models":
            if self.authorised("router-key"):
                self.reply(200, {"object": "list", "data": [{"id": name} for name in cls.images]})
            return
        if not self.authorised("admin-secret"):
            return
        if self.path == "/api/v1/images/config":
            self.reply(200, cls.config)
        else:
            self.reply(404, {"detail": "Not Found"})

    def do_POST(self):
        cls = type(self)
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"null")
        if self.path.startswith("/router/routing/refresh"):
            if self.authorised("router-key"):
                cls.refreshed += 1
                self.reply(200, {"ok": True})
            return
        if not self.authorised("admin-secret"):
            return
        if self.path == "/api/v1/images/config/update":
            missing = set(cls.required) - set(body)
            if missing:
                self.reply(422, {"detail": f"missing {sorted(missing)}"})
                return
            if "IMAGE_CONNECTIONS" in body:
                ids = [item.get("id") for item in body["IMAGE_CONNECTIONS"]]
                if len(set(ids)) != len(ids) or any(":" in str(i) for i in ids):
                    self.reply(400, {"detail": "Image connection IDs must be unique"})
                    return
            cls.updates.append(copy.deepcopy(body))
            if cls.keep_engine and "IMAGE_CONNECTIONS" in body:
                body = dict(body, IMAGE_CONNECTIONS=cls.config["IMAGE_CONNECTIONS"])
            elif cls.keep_engine:
                body = dict(body, IMAGE_GENERATION_ENGINE=cls.config["IMAGE_GENERATION_ENGINE"])
            cls.config = body
            self.reply(200, body)
        else:
            self.reply(404, {"detail": "Not Found"})


class WebuiImagesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Handler.config = copy.deepcopy(FRESH)
        Handler.required = tuple(FRESH)
        Handler.images = ["image", "flux2-klein-4b-comfyui"]
        Handler.keep_engine = False
        Handler.updates = []
        Handler.refreshed = 0
        self.tmp = tempfile.TemporaryDirectory()
        folder = pathlib.Path(self.tmp.name)
        (folder / "admin-token").write_text("admin-secret\n")
        (folder / "secrets.env").write_text("OPENAI_API_KEYS=router-key\nROUTER_API_KEY=router-key\n")
        (folder / "router.env").write_text("ROUTER_PORT=8000\n")
        (folder / "images.py").write_text(
            "async def get_models():\n    try:\n" + MODULE.PICKER_OLD +
            "    except Exception:\n        raise\n", encoding="utf-8")
        self.folder = folder

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *extra):
        out = io.StringIO()
        args = ["--webui-url", self.base, "--admin-token-file", str(self.folder / "admin-token"),
                "--router-url", f"{self.base}/router", "--router-secrets", str(self.folder / "secrets.env"),
                "--router-env", str(self.folder / "router.env"), "--wait", "0",
                "--picker-module", str(self.folder / "images.py"), "--no-restart", *extra]
        with redirect_stdout(out):
            MODULE.main(args)
        return out.getvalue()

    def test_points_the_openai_engine_at_the_router_alias(self):
        text = self.run_script()
        saved = Handler.config
        self.assertEqual(saved["IMAGE_GENERATION_ENGINE"], "openai")
        self.assertEqual(saved["IMAGES_OPENAI_API_BASE_URL"], f"{self.base}/router/v1")
        self.assertEqual(saved["IMAGES_OPENAI_API_KEY"], "router-key")
        self.assertEqual(saved["IMAGE_GENERATION_MODEL"], "image")
        self.assertTrue(saved["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(saved["IMAGE_SIZE"], "512x512")
        self.assertEqual(saved["ENABLE_IMAGE_PROMPT_GENERATION"], True)
        self.assertGreaterEqual(Handler.refreshed, 1)
        self.assertIn("The router draws with: flux2-klein-4b-comfyui", text)
        self.assertIn(MODULE.PICKER_MARKER, (self.folder / "images.py").read_text())

    def test_picker_patch_is_repeatable_and_checks_the_upstream_branch(self):
        picker = self.folder / "images.py"
        self.assertTrue(MODULE.patch_image_picker(picker))
        once = picker.read_bytes()
        self.assertFalse(MODULE.patch_image_picker(picker))
        self.assertEqual(picker.read_bytes(), once)
        picker.write_text("async def get_models():\n    return []\n")
        with self.assertRaisesRegex(RuntimeError, "unsupported Open WebUI image picker"):
            MODULE.patch_image_picker(picker)

    def test_patched_picker_lists_router_models_even_after_choosing_one(self):
        picker = self.folder / "images.py"
        MODULE.patch_image_picker(picker)

        class Answer:
            async def __aenter__(self): return self
            async def __aexit__(self, *_args): pass
            def raise_for_status(self): pass
            async def json(self):
                return {"data": [{"id": "image"}, {"id": "qwen-image-2.1-colibri"}]}

        class Session:
            def get(self, *, url, headers, ssl):
                assert url == f"http://127.0.0.1:{WebuiImagesTest.server.server_port}/v1/images/models"
                assert headers == {"Authorization": "Bearer router-key"}
                return Answer()

        config = SimpleNamespace(IMAGE_GENERATION_ENGINE="openai", IMAGE_GENERATION_MODEL="image",
                                 IMAGES_OPENAI_API_BASE_URL=f"http://127.0.0.1:{self.server.server_port}/v1",
                                 IMAGES_OPENAI_API_KEY="router-key")
        namespace = {"image_config": config, "urlparse": urlparse,
                     "get_session": lambda: asyncio.sleep(0, result=Session()),
                     "AIOHTTP_CLIENT_SESSION_SSL": None}
        exec(picker.read_text(encoding="utf-8"), namespace)
        expected = [{"id": "image", "name": "Automatic (image)"},
                    {"id": "qwen-image-2.1-colibri", "name": "qwen-image-2.1-colibri"}]
        self.assertEqual(asyncio.run(namespace["get_models"]()), expected)
        config.IMAGE_GENERATION_MODEL = "qwen-image-2.1-colibri"
        self.assertEqual(asyncio.run(namespace["get_models"]()), expected)

    def test_router_port_and_key_come_from_its_env_files(self):
        (self.folder / "secrets.env").write_text("OPENAI_API_KEYS=router-key;other\n")
        (self.folder / "router.env").write_text("ROUTER_PORT=8123\n")
        self.assertEqual(MODULE.router_key(self.folder / "secrets.env"), "router-key")
        self.assertEqual(MODULE.env_value(self.folder / "router.env", "ROUTER_PORT"), "8123")
        self.assertEqual(MODULE.router_key(self.folder / "missing.env"), "none")

    def test_no_image_server_leaves_generation_off(self):
        Handler.images = []
        text = self.run_script()
        self.assertEqual(Handler.config["IMAGE_GENERATION_ENGINE"], "openai")
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertIn("left off", text)

    def test_an_expected_model_must_be_listed(self):
        Handler.images = ["image", "qwen-image-2.1-colibri"]
        self.run_script("--expect-model", "flux2-klein-4b-comfyui")
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.run_script("--expect-model", "qwen-image-2.1-colibri")
        self.assertTrue(Handler.config["ENABLE_IMAGE_GENERATION"])

    def test_steps_and_size(self):
        Handler.config["IMAGE_SIZE"] = "auto"
        self.run_script()
        self.assertEqual(Handler.config["IMAGE_SIZE"], "1024x1024")
        self.run_script("--image-size", "768x512", "--image-steps", "12")
        self.assertEqual(Handler.config["IMAGE_SIZE"], "768x512")
        self.assertEqual(Handler.config["IMAGES_OPENAI_API_PARAMS"], {"steps": 12})

    def test_a_custom_comfyui_workflow_is_kept(self):
        custom = {"1": {"class_type": "MyLoader", "inputs": {}}}
        Handler.config.update(IMAGE_GENERATION_ENGINE="comfyui", COMFYUI_WORKFLOW=json.dumps(custom))
        text = self.run_script()
        self.assertEqual(Handler.updates, [])
        self.assertIn("custom ComfyUI workflow", text)
        self.run_script("--replace-custom")
        self.assertEqual(Handler.config["IMAGE_GENERATION_ENGINE"], "openai")

    def test_osr_klein_workflow_moves_to_the_router(self):
        # What targets/comfyui set up before the router drew pictures itself.
        Handler.config.update(IMAGE_GENERATION_ENGINE="comfyui", COMFYUI_WORKFLOW=json.dumps(KLEIN, indent=2),
                              COMFYUI_BASE_URL="http://10.0.0.30:8188", IMAGE_GENERATION_MODEL="flux-2-klein-4b-fp8.safetensors")
        self.run_script()
        self.assertEqual(Handler.config["IMAGE_GENERATION_ENGINE"], "openai")
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], "image")
        self.assertEqual(Handler.config["COMFYUI_BASE_URL"], "http://10.0.0.30:8188")   # kept, unused

    def test_a_setting_open_webui_does_not_keep_is_restored(self):
        Handler.config["IMAGE_GENERATION_ENGINE"] = "automatic1111"
        before = copy.deepcopy(Handler.config)
        Handler.keep_engine = True
        with self.assertRaisesRegex(RuntimeError, "restored"):
            self.run_script()
        self.assertEqual(Handler.updates[-1], before)

    def test_off_only_turns_off_the_router_engine(self):
        self.run_script()
        text = self.run_script("--off")
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertIn("is off", text)
        Handler.config = copy.deepcopy(FRESH)
        Handler.updates = []
        text = self.run_script("--off")
        self.assertEqual(Handler.updates, [])
        self.assertIn("left as they are", text)

    def test_an_unsupported_open_webui_is_refused(self):
        Handler.config = {"enabled": False, "engine": ""}
        with self.assertRaisesRegex(RuntimeError, "not supported"):
            self.run_script()
        self.assertEqual(Handler.updates, [])

    def test_a_router_that_does_not_answer_changes_nothing(self):
        with self.assertRaises(OSError):   # urllib's URLError
            MODULE.main(["--webui-url", self.base, "--admin-token-file", str(self.folder / "admin-token"),
                         "--router-url", "http://127.0.0.1:9", "--router-secrets", str(self.folder / "secrets.env"),
                         "--wait", "0"])
        self.assertEqual(Handler.updates, [])


class WebuiImages013Test(WebuiImagesTest):
    """Open WebUI 0.13: the router as one image connection; no picker patch."""

    def setUp(self):
        super().setUp()
        Handler.config = copy.deepcopy(FRESH_013)
        Handler.required = REQUIRED_013

    def router_connections(self):
        return [item for item in Handler.config["IMAGE_CONNECTIONS"]
                if item["type"] == "openai" and item["url"] == f"{self.base}/router/v1"]

    # The 0.12 cases do not apply to the connections API.
    test_points_the_openai_engine_at_the_router_alias = None
    test_no_image_server_leaves_generation_off = None
    test_an_expected_model_must_be_listed = None
    test_steps_and_size = None
    test_a_custom_comfyui_workflow_is_kept = None
    test_osr_klein_workflow_moves_to_the_router = None
    test_a_setting_open_webui_does_not_keep_is_restored = None
    test_off_only_turns_off_the_router_engine = None
    # Version-independent, run once in the 0.12 class.
    test_picker_patch_is_repeatable_and_checks_the_upstream_branch = None
    test_patched_picker_lists_router_models_even_after_choosing_one = None
    test_router_port_and_key_come_from_its_env_files = None

    def test_adds_the_router_as_one_connection_with_its_models(self):
        picker_before = (self.folder / "images.py").read_text()
        text = self.run_script()
        (connection,) = self.router_connections()
        self.assertEqual(connection["id"], "osr-router")
        self.assertEqual(connection["name"], "Open Smart Router")
        self.assertEqual(connection["key"], "router-key")
        config = connection["config"]
        self.assertTrue(config["enable"])
        self.assertEqual(config["model_ids"], ["image", "flux2-klein-4b-comfyui"])
        self.assertEqual(config["capabilities"], {"image_generation": True, "image_edit": False})
        self.assertEqual(config["access_grants"], [{"principal_type": "user", "principal_id": "*", "permission": "read"}])
        self.assertEqual(config["size"], "1024x1024")
        self.assertTrue(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "osr-router:image")
        self.assertTrue(Handler.config["ENABLE_IMAGE_PROMPT_GENERATION"])
        self.assertEqual((self.folder / "images.py").read_text(), picker_before)   # 0.13 needs no patch
        self.assertIn("The router draws with: flux2-klein-4b-comfyui", text)
        self.run_script()
        self.assertEqual(len(Handler.config["IMAGE_CONNECTIONS"]), 1)   # a rerun updates it

    def test_the_connection_open_webui_migrated_from_0_12_is_updated_in_place(self):
        migrated = {"id": "4f1c", "name": "OpenAI", "type": "openai", "url": f"{self.base}/router/v1/",
                    "key": "old-key", "config": {"enable": True, "model_ids": ["image"], "size": "768x768",
                                                 "params": {"steps": 9}, "access_grants": [{"principal_type": "group",
                                                 "principal_id": "artists", "permission": "read"}]}}
        Handler.config.update(IMAGE_CONNECTIONS=[migrated], IMAGE_GENERATION_DEFAULT_MODEL="4f1c:image",
                              ENABLE_IMAGE_GENERATION=True)
        self.run_script()
        (connection,) = Handler.config["IMAGE_CONNECTIONS"]
        self.assertEqual(connection["id"], "4f1c")
        self.assertEqual(connection["key"], "router-key")
        self.assertEqual(connection["config"]["model_ids"], ["image", "flux2-klein-4b-comfyui"])
        self.assertEqual(connection["config"]["size"], "768x768")
        self.assertEqual(connection["config"]["params"], {"steps": 9})
        self.assertEqual(connection["config"]["access_grants"][0]["principal_id"], "artists")   # kept
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "4f1c:image")

    def test_a_second_router_connection_is_dropped(self):
        twin = {"id": "a", "name": "x", "type": "openai", "url": f"{self.base}/router/v1", "key": "", "config": {}}
        Handler.config["IMAGE_CONNECTIONS"] = [twin, dict(twin, id="b")]
        self.run_script()
        self.assertEqual([item["id"] for item in Handler.config["IMAGE_CONNECTIONS"]], ["a"])

    def test_an_unrelated_connection_and_its_id_are_respected(self):
        cloud = {"id": "osr-router", "name": "Cloud", "type": "openai", "url": "https://api.openai.com/v1",
                 "key": "sk-keep", "config": {"enable": True, "model_ids": ["gpt-image-1"]}}
        Handler.config["IMAGE_CONNECTIONS"] = [cloud]
        self.run_script()
        kept, ours = Handler.config["IMAGE_CONNECTIONS"]
        self.assertEqual(kept, cloud)
        self.assertNotEqual(ours["id"], "osr-router")
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], f"{ours['id']}:image")

    def test_no_image_server_leaves_the_connection_off(self):
        Handler.images = []
        text = self.run_script()
        (connection,) = self.router_connections()
        self.assertFalse(connection["config"]["enable"])
        self.assertEqual(connection["config"]["model_ids"], ["image"])
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "")
        self.assertIn("left off", text)

    def test_an_expected_model_must_be_listed_013(self):
        Handler.images = ["image", "qwen-image-2.1-colibri"]
        self.run_script("--expect-model", "flux2-klein-4b-comfyui")
        self.assertFalse(self.router_connections()[0]["config"]["enable"])
        self.run_script("--expect-model", "qwen-image-2.1-colibri")
        self.assertTrue(self.router_connections()[0]["config"]["enable"])
        self.assertEqual(self.router_connections()[0]["config"]["model_ids"], ["image", "qwen-image-2.1-colibri"])

    def test_steps_and_size_013(self):
        self.run_script("--image-size", "768x512", "--image-steps", "12")
        config = self.router_connections()[0]["config"]
        self.assertEqual(config["size"], "768x512")
        self.assertEqual(config["params"], {"steps": 12})
        Handler.config["IMAGE_CONNECTIONS"][0]["config"]["size"] = "auto"
        self.run_script()
        self.assertEqual(self.router_connections()[0]["config"]["size"], "1024x1024")

    def test_a_custom_comfyui_connection_stays_the_default(self):
        custom = {"id": "mine", "name": "My ComfyUI", "type": "comfyui", "url": "http://10.0.0.9:8188", "key": "",
                  "config": {"enable": True, "workflow": json.dumps({"1": {"class_type": "MyLoader", "inputs": {}}}),
                             "model_ids": ["x.safetensors"]}}
        Handler.config.update(IMAGE_CONNECTIONS=[custom], IMAGE_GENERATION_DEFAULT_MODEL="mine:x.safetensors")
        text = self.run_script()
        self.assertEqual(Handler.config["IMAGE_CONNECTIONS"][0], custom)
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "mine:x.safetensors")
        self.assertEqual(len(self.router_connections()), 1)
        self.assertIn("--replace-custom", text)
        self.run_script("--replace-custom")
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "osr-router:image")
        self.assertTrue(Handler.config["IMAGE_CONNECTIONS"][0]["config"]["enable"])   # still usable

    def test_an_osr_klein_comfyui_connection_is_disabled(self):
        klein = {"id": "c1", "name": "ComfyUI", "type": "comfyui", "url": "http://10.0.0.30:8188", "key": "",
                 "config": {"enable": True, "workflow": json.dumps(KLEIN, indent=2),
                            "model_ids": ["flux-2-klein-4b-fp8.safetensors"]}}
        Handler.config.update(IMAGE_CONNECTIONS=[klein], IMAGE_GENERATION_DEFAULT_MODEL="c1:flux-2-klein-4b-fp8.safetensors")
        text = self.run_script()
        first = Handler.config["IMAGE_CONNECTIONS"][0]
        self.assertFalse(first["config"]["enable"])
        self.assertEqual(first["url"], "http://10.0.0.30:8188")   # kept, unused
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "osr-router:image")
        self.assertIn("Disabled the ComfyUI connection(s)", text)

    def test_a_connection_open_webui_does_not_keep_is_restored(self):
        before = copy.deepcopy(Handler.config)
        Handler.keep_engine = True
        with self.assertRaisesRegex(RuntimeError, "restored"):
            self.run_script()
        self.assertEqual(Handler.updates[-1], before)

    def test_off_only_turns_off_the_router_connection(self):
        self.run_script()
        text = self.run_script("--off")
        (connection,) = self.router_connections()
        self.assertFalse(connection["config"]["enable"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "")
        self.assertIn("is off", text)
        Handler.config = copy.deepcopy(FRESH_013)
        Handler.updates = []
        text = self.run_script("--off")
        self.assertEqual(Handler.updates, [])
        self.assertIn("left as they are", text)


if __name__ == "__main__":
    unittest.main()
