"""Mock Open WebUI's image settings API and a ComfyUI server to check that
integrate-webui.py makes ComfyUI the image engine safely.

Run: python3 targets/comfyui/test-integration.py (stdlib only).
"""
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

SCRIPT = pathlib.Path(__file__).with_name("integrate-webui.py")
SPEC = importlib.util.spec_from_file_location("comfyui_integrate_webui", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

# The shape of GET /api/v1/images/config in Open WebUI 0.11.0-0.12.4 (ImagesConfig).
FRESH = {
    "ENABLE_IMAGE_GENERATION": False, "ENABLE_IMAGE_PROMPT_GENERATION": True,
    "IMAGE_GENERATION_ENGINE": "openai", "IMAGE_GENERATION_MODEL": "", "IMAGE_SIZE": "512x512", "IMAGE_STEPS": 50,
    "IMAGES_OPENAI_API_BASE_URL": "https://api.openai.com/v1", "IMAGES_OPENAI_API_KEY": "sk-keep",
    "IMAGES_OPENAI_API_VERSION": "", "IMAGES_OPENAI_API_PARAMS": None,
    "AUTOMATIC1111_BASE_URL": "", "AUTOMATIC1111_API_AUTH": None, "AUTOMATIC1111_PARAMS": None,
    "COMFYUI_BASE_URL": "", "COMFYUI_API_KEY": "", "COMFYUI_WORKFLOW": "\n" + json.dumps(MODULE.DEFAULT_WORKFLOW, indent=2) + "\n",
    "COMFYUI_WORKFLOW_NODES": [],
    "IMAGES_GEMINI_API_BASE_URL": "", "IMAGES_GEMINI_API_KEY": "", "IMAGES_GEMINI_ENDPOINT_METHOD": "",
    "ENABLE_IMAGE_EDIT": False, "IMAGE_EDIT_ENGINE": "openai", "IMAGE_EDIT_MODEL": "", "IMAGE_EDIT_SIZE": "",
    "IMAGES_EDIT_OPENAI_API_BASE_URL": "", "IMAGES_EDIT_OPENAI_API_KEY": "", "IMAGES_EDIT_OPENAI_API_VERSION": "",
    "IMAGES_EDIT_GEMINI_API_BASE_URL": "", "IMAGES_EDIT_GEMINI_API_KEY": "", "IMAGES_EDIT_COMFYUI_BASE_URL": "",
    "IMAGES_EDIT_COMFYUI_API_KEY": "", "IMAGES_EDIT_COMFYUI_WORKFLOW": "", "IMAGES_EDIT_COMFYUI_WORKFLOW_NODES": [],
}

# Open WebUI 0.13.4: a list of image connections replaced the single engine.
FRESH_013 = {
    "ENABLE_IMAGE_GENERATION": False, "ENABLE_IMAGE_PROMPT_GENERATION": True, "ENABLE_IMAGE_EDIT": False,
    "IMAGE_GENERATION_DEFAULT_MODEL": "", "IMAGE_EDIT_DEFAULT_MODEL": "", "IMAGE_CONNECTIONS": [],
}
REQUIRED_013 = ("ENABLE_IMAGE_GENERATION", "ENABLE_IMAGE_PROMPT_GENERATION", "ENABLE_IMAGE_EDIT")


class Handler(http.server.BaseHTTPRequestHandler):
    """ComfyUI at /comfy; Open WebUI's admin API under /api/v1/images."""
    config = {}
    diffusion_models = []
    encoders = []
    vaes = []
    combo_format = False
    missing_node = None
    is_comfyui = True
    reachable = True          # can "Open WebUI's backend" reach ComfyUI?
    legacy_verify = False     # Open WebUI before 0.11.4: GET .../config/url/verify
    models_override = None
    required = tuple(FRESH)
    updates = []
    verified = []

    def log_message(self, *_args):
        pass

    def reply(self, status, value):
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def admin(self):
        if self.headers.get("Authorization") != "Bearer admin-secret":
            self.reply(401, {"detail": "Not authenticated"})
            return False
        return True

    def comfy_url(self):
        return f"http://127.0.0.1:{self.server.server_port}/comfy"

    def do_GET(self):
        cls = type(self)
        if self.path == "/comfy/system_stats":
            if cls.is_comfyui:
                self.reply(200, {"system": {"comfyui_version": "0.42.1"}, "devices": [{"type": "cuda"}]})
            else:
                self.reply(200, {"status": "ok"})
            return
        if self.path == "/comfy/object_info":
            info = {node["class_type"]: {"input": {"required": {}}}
                    for node in MODULE.KLEIN_WORKFLOW.values()
                    if node["class_type"] != cls.missing_node}
            for node, key, options in (("UNETLoader", "unet_name", cls.diffusion_models),
                                       ("CLIPLoader", "clip_name", cls.encoders),
                                       ("VAELoader", "vae_name", cls.vaes)):
                if node in info:
                    spec = ["COMBO", {"options": options}] if cls.combo_format else [options, {}]
                    info[node]["input"]["required"][key] = spec
            self.reply(200, info)
            return
        if not self.admin():
            return
        if self.path == "/api/v1/images/config":
            self.reply(200, cls.config)
        elif self.path == "/api/v1/images/config/url/verify" and cls.legacy_verify:
            cls.verified.append("legacy")
            if cls.reachable and cls.config.get("COMFYUI_BASE_URL") == self.comfy_url():
                self.reply(200, True)
            else:
                self.reply(400, {"detail": "Invalid URL"})
        elif self.path == "/api/v1/images/models" and "IMAGE_CONNECTIONS" in cls.config:
            # Open WebUI 0.13: references "<connection>:<model>" from each enabled connection's model IDs.
            listed = []
            if cls.config.get("ENABLE_IMAGE_GENERATION"):
                for item in cls.config["IMAGE_CONNECTIONS"]:
                    if not (item.get("config") or {}).get("enable", True):
                        continue
                    models = cls.models_override if cls.models_override is not None else \
                        ((item.get("config") or {}).get("model_ids") or [""])
                    listed += [{"id": f"{item['id']}:{m}", "name": m or item["name"], "model": m,
                                "connection_id": item["id"]} for m in models]
            self.reply(200, listed)
        elif self.path == "/api/v1/images/models":
            # Open WebUI 0.11.0-0.12.4 reads UNETLoader's combo options at index 0.
            # Its model picker cannot read ComfyUI's newer COMBO format.
            if cls.models_override is not None:
                models = cls.models_override
            elif cls.combo_format:
                models = list("COMBO")
            else:
                models = cls.diffusion_models
            self.reply(200, [{"id": m, "name": m} for m in models])
        else:
            self.reply(404, {"detail": "Not Found"})

    def do_POST(self):
        cls = type(self)
        if not self.admin():
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/api/v1/images/connections/verify" and "IMAGE_CONNECTIONS" in cls.config:
            # Open WebUI 0.13: its backend reaches the connection (GET <url>/object_info).
            cls.verified.append(body)
            if body.get("type") == "comfyui" and body.get("url") == self.comfy_url() and cls.reachable:
                self.reply(200, [{"id": m, "name": m} for m in cls.diffusion_models])
            else:
                self.reply(400, {"detail": "Failed to connect to the image generation engine"})
            return
        if self.path == "/api/v1/images/config/update":
            missing = set(cls.required) - set(body)
            if missing:   # ImagesConfig: every field is required
                self.reply(422, {"detail": f"missing {sorted(missing)}"})
                return
            cls.updates.append(copy.deepcopy(body))
            cls.config = body
            self.reply(200, body)
        elif self.path == "/api/v1/images/verify" and not cls.legacy_verify:
            # Open WebUI 0.11.4+: ConnectionVerificationForm {engine, url, key}.
            if not isinstance(body.get("engine"), str) or not isinstance(body.get("url"), str):
                self.reply(422, {"detail": "engine and url are required"})
                return
            cls.verified.append(body)
            if body["engine"] == "comfyui" and body["url"] == self.comfy_url() and cls.reachable:
                self.reply(200, True)
            else:
                self.reply(400, {"detail": "Invalid URL"})
        else:
            self.reply(404, {"detail": "Not Found"})


class IntegrationTest(unittest.TestCase):
    def setUp(self):
        Handler.config = copy.deepcopy(FRESH)
        Handler.required = tuple(FRESH)
        Handler.diffusion_models = [MODULE.KLEIN_MODEL, "other.safetensors"]
        Handler.encoders = [MODULE.KLEIN_ENCODER]
        Handler.vaes = [MODULE.KLEIN_VAE]
        Handler.combo_format = False
        Handler.missing_node = None
        Handler.is_comfyui = True
        Handler.reachable = True
        Handler.legacy_verify = False
        Handler.models_override = None
        Handler.updates = []
        Handler.verified = []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.tmp = tempfile.TemporaryDirectory()
        self.token = pathlib.Path(self.tmp.name, "admin-token")
        self.token.write_text("admin-secret\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def run_script(self, *extra, token=None):
        if token is not None:
            self.token.write_text(token)
        out = io.StringIO()
        with redirect_stdout(out):
            MODULE.main(["--webui-url", self.base, "--comfyui-url", f"{self.base}/comfy/",
                         "--admin-token-file", str(self.token), *extra])
        return out.getvalue()

    def test_api_workflow_links_reach_save_image(self):
        for workflow in MODULE.WORKFLOWS.values():
            self.assertEqual(workflow["13"]["class_type"], "SaveImage")
            visited = set()

            def visit(node_id, workflow=workflow, visited=visited):
                if node_id in visited:
                    return
                self.assertIn(node_id, workflow)
                visited.add(node_id)
                for value in workflow[node_id]["inputs"].values():
                    if isinstance(value, list) and len(value) == 2 and isinstance(value[0], str):
                        visit(value[0])

            visit("13")
            self.assertEqual(visited, set(workflow))
            self.assertEqual(workflow["7"]["inputs"]["steps"], 4)
            self.assertEqual(workflow["9"]["inputs"]["cfg"], 1.0)

    def test_the_weights_manifest_matches_the_workflows(self):
        manifest = pathlib.Path(__file__).with_name("klein-weights.txt").read_text().splitlines()
        rows = [line.split() for line in manifest if line.strip() and not line.startswith("#")]
        for name, item in MODULE.VARIANTS.items():
            files = {row[1]: row[2] for row in rows if row[0] == name}
            self.assertEqual(files, {"diffusion_models": item["model"], "text_encoders": item["encoder"],
                                     "vae": item["vae"]})
            inputs = {node["class_type"]: node["inputs"] for node in item["workflow"].values()}
            self.assertEqual(inputs["UNETLoader"]["unet_name"], item["model"])
            self.assertEqual(inputs["CLIPLoader"]["clip_name"], item["encoder"])
            self.assertEqual(inputs["VAELoader"]["vae_name"], item["vae"])

    def test_fresh_install_gets_distilled_klein_workflow(self):
        out = self.run_script()
        saved = Handler.config
        self.assertEqual(saved["IMAGE_GENERATION_ENGINE"], "comfyui")
        self.assertEqual(saved["COMFYUI_BASE_URL"], f"{self.base}/comfy")
        self.assertTrue(saved["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(saved["IMAGE_GENERATION_MODEL"], MODULE.KLEIN_MODEL)
        self.assertEqual(json.loads(saved["COMFYUI_WORKFLOW"]), MODULE.KLEIN_WORKFLOW)
        types = {node["type"]: node for node in saved["COMFYUI_WORKFLOW_NODES"]}
        self.assertEqual(types["prompt"]["node_ids"], ["4"])
        self.assertEqual(types["model"], {"type": "model", "key": "unet_name", "node_ids": ["1"]})
        self.assertEqual(set(types), {"prompt", "model", "width", "height", "n", "steps", "seed"})
        # Every node mapping points at a real input of the workflow.
        for node in saved["COMFYUI_WORKFLOW_NODES"]:
            for node_id in node["node_ids"]:
                self.assertIn(node["key"], MODULE.KLEIN_WORKFLOW[node_id]["inputs"])
        self.assertEqual(saved["IMAGES_OPENAI_API_KEY"], "sk-keep")
        self.assertEqual((saved["IMAGE_SIZE"], saved["IMAGE_STEPS"]), ("1024x1024", 4))
        self.assertIn("ComfyUI 0.42.1", out)

    def test_selected_9b_uses_its_own_workflow_and_encoder(self):
        selected = MODULE.VARIANTS["klein-9b"]
        Handler.diffusion_models.append(selected["model"])
        Handler.encoders.append(selected["encoder"])
        out = self.run_script("--variant", "klein-9b")
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], selected["model"])
        self.assertEqual(json.loads(Handler.config["COMFYUI_WORKFLOW"]), selected["workflow"])
        self.assertTrue(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertIn("klein-9b", out)
        self.run_script()  # Auto keeps the selected workflow on reintegration.
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], selected["model"])

    def test_selected_9b_needs_the_matching_encoder(self):
        selected = MODULE.VARIANTS["klein-9b"]
        Handler.diffusion_models.append(selected["model"])
        out = self.run_script("--variant", "klein-9b")
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertIn(selected["encoder"], out)
        self.assertIn("COMFYUI_IMAGE_VARIANT=klein-9b", out)

    def test_auto_on_a_fresh_open_webui_uses_the_variant_comfyui_has(self):
        selected = MODULE.VARIANTS["klein-9b"]
        Handler.diffusion_models = [selected["model"]]
        Handler.encoders = [selected["encoder"]]
        self.run_script()
        self.assertEqual(json.loads(Handler.config["COMFYUI_WORKFLOW"]), selected["workflow"])
        self.assertTrue(Handler.config["ENABLE_IMAGE_GENERATION"])

    def test_auto_with_no_weights_sets_up_the_default_4b_and_leaves_it_off(self):
        Handler.diffusion_models, Handler.encoders, Handler.vaes = [], [], []
        out = self.run_script()
        self.assertEqual(MODULE.DEFAULT_VARIANT, "klein-4b")
        self.assertEqual(json.loads(Handler.config["COMFYUI_WORKFLOW"]), MODULE.VARIANTS["klein-4b"]["workflow"])
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertIn("COMFYUI_IMAGE_VARIANT=klein-4b", out)

    def test_size_steps_and_a_named_diffusion_model(self):
        self.run_script("--model", "other.safetensors", "--image-size", "768x768", "--image-steps", "6")
        saved = Handler.config
        self.assertEqual(saved["IMAGE_GENERATION_MODEL"], "other.safetensors")
        self.assertEqual((saved["IMAGE_SIZE"], saved["IMAGE_STEPS"]), ("768x768", 6))

    def test_an_unknown_diffusion_model_is_refused_before_anything_is_saved(self):
        with self.assertRaisesRegex(RuntimeError, "no diffusion model 'flux.safetensors'.*flux-2-klein"):
            self.run_script("--model", "flux.safetensors")
        self.assertEqual(Handler.updates, [])

    def test_the_distilled_model_is_selected(self):
        Handler.config["IMAGE_GENERATION_MODEL"] = MODULE.KLEIN_MODEL
        self.run_script()
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], MODULE.KLEIN_MODEL)
        Handler.config["IMAGE_GENERATION_MODEL"] = "gone.safetensors"
        self.run_script()
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], MODULE.KLEIN_MODEL)

    def test_a_custom_workflow_and_its_nodes_are_kept(self):
        custom = {"1": {"inputs": {"unet_name": "flux.safetensors"}, "class_type": "UNETLoader"}}
        nodes = [{"type": "model", "key": "unet_name", "node_ids": ["1"]}]
        Handler.config.update(COMFYUI_WORKFLOW=json.dumps(custom), COMFYUI_WORKFLOW_NODES=nodes,
                              IMAGE_GENERATION_MODEL="my-model", ENABLE_IMAGE_GENERATION=True)
        out = self.run_script()
        self.assertEqual(json.loads(Handler.config["COMFYUI_WORKFLOW"]), custom)
        self.assertEqual(Handler.config["COMFYUI_WORKFLOW_NODES"], nodes)
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], "my-model")
        self.assertTrue(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertIn("Keeping the custom ComfyUI workflow", out)

    def test_missing_klein_assets_leaves_generation_off(self):
        Handler.encoders = []
        Handler.config["ENABLE_IMAGE_GENERATION"] = True
        out = self.run_script()
        self.assertEqual(Handler.config["IMAGE_GENERATION_ENGINE"], "comfyui")
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], "")
        self.assertIn(MODULE.KLEIN_ENCODER, out)

    def test_missing_diffusion_model_leaves_generation_off(self):
        Handler.diffusion_models = ["unrelated.safetensors"]
        out = self.run_script()
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_MODEL"], "")
        self.assertIn(MODULE.KLEIN_MODEL, out)

    def test_open_webui_cannot_list_newer_combo_format_and_settings_roll_back(self):
        Handler.combo_format = True
        before = copy.deepcopy(Handler.config)
        with self.assertRaisesRegex(RuntimeError, "does not list the diffusion model"):
            self.run_script()
        self.assertEqual(Handler.config, before)

    def test_missing_workflow_node_is_refused_before_saving(self):
        Handler.missing_node = "Flux2Scheduler"
        with self.assertRaisesRegex(RuntimeError, "missing Klein workflow nodes: Flux2Scheduler"):
            self.run_script()
        self.assertEqual(Handler.updates, [])

    def test_custom_workflow_does_not_require_klein_nodes(self):
        Handler.config["COMFYUI_WORKFLOW"] = json.dumps({
            "1": {"class_type": "SaveImage", "inputs": {"filename_prefix": "custom", "images": ["2", 0]}}
        })
        Handler.missing_node = "Flux2Scheduler"
        self.run_script()
        self.assertEqual(Handler.config["IMAGE_GENERATION_ENGINE"], "comfyui")

    def test_unreachable_from_open_webui_restores_the_previous_settings(self):
        Handler.reachable = False
        before = copy.deepcopy(Handler.config)
        with self.assertRaisesRegex(RuntimeError, "firewall.*previous image settings were restored"):
            self.run_script()
        self.assertEqual(Handler.config, before)
        self.assertEqual(len(Handler.updates), 2)

    def test_open_webui_verifies_the_comfyui_url_it_is_given(self):
        self.run_script()
        self.assertEqual(Handler.verified, [{"engine": "comfyui", "url": f"{self.base}/comfy",
                                             "key": None}])

    def test_an_open_webui_before_0_11_4_uses_the_old_verify_endpoint(self):
        Handler.legacy_verify = True
        self.run_script()
        self.assertEqual(Handler.verified, ["legacy"])
        self.assertTrue(Handler.config["ENABLE_IMAGE_GENERATION"])

    def test_an_unreachable_comfyui_on_an_old_open_webui_restores_the_previous_settings(self):
        Handler.legacy_verify = True
        Handler.reachable = False
        before = copy.deepcopy(Handler.config)
        with self.assertRaisesRegex(RuntimeError, "Invalid URL.*previous image settings were restored"):
            self.run_script()
        self.assertEqual(Handler.config, before)

    def test_a_diffusion_model_open_webui_does_not_list_restores_the_previous_settings(self):
        Handler.models_override = ["other.safetensors"]
        before = copy.deepcopy(Handler.config)
        with self.assertRaisesRegex(RuntimeError, "does not list the diffusion model"):
            self.run_script()
        self.assertEqual(Handler.config, before)

    def test_not_comfyui(self):
        Handler.is_comfyui = False
        with self.assertRaisesRegex(RuntimeError, "not a ComfyUI server"):
            self.run_script()
        self.assertEqual(Handler.updates, [])

    def test_an_unsupported_open_webui_image_api(self):
        Handler.config = {"enabled": False, "engine": "", "comfyui": {"COMFYUI_BASE_URL": ""}}
        with self.assertRaisesRegex(RuntimeError, "not supported"):
            self.run_script()
        self.assertEqual(Handler.updates, [])

    def test_a_wrong_admin_token(self):
        with self.assertRaisesRegex(RuntimeError, "HTTP 401"):
            self.run_script(token="not-admin")
        self.assertEqual(Handler.updates, [])

    def test_bad_arguments(self):
        with self.assertRaisesRegex(ValueError, "image-size"):
            self.run_script("--image-size", "huge")
        self.token.write_text("\n")
        with self.assertRaisesRegex(RuntimeError, "empty"):
            self.run_script()


class Integration013Test(IntegrationTest):
    """Open WebUI 0.13: ComfyUI as one image connection."""

    def setUp(self):
        super().setUp()
        Handler.config = copy.deepcopy(FRESH_013)
        Handler.required = REQUIRED_013

    def comfy(self):
        return [item for item in Handler.config["IMAGE_CONNECTIONS"] if item["type"] == "comfyui"]

    # The 0.12 cases do not apply; the version-independent ones ran in the 0.12 class.
    for _name in [name for name in dir(IntegrationTest) if name.startswith("test_")]:
        if _name not in ("test_not_comfyui", "test_an_unknown_diffusion_model_is_refused_before_anything_is_saved",
                         "test_a_wrong_admin_token", "test_missing_workflow_node_is_refused_before_saving"):
            locals()[_name] = None
    del _name

    def test_fresh_open_webui_gets_one_klein_connection(self):
        out = self.run_script()
        (connection,) = self.comfy()
        self.assertEqual(connection["id"], "osr-comfyui")
        self.assertEqual(connection["url"], f"{self.base}/comfy")
        config = connection["config"]
        self.assertTrue(config["enable"])
        self.assertEqual(json.loads(config["workflow"]), MODULE.KLEIN_WORKFLOW)
        self.assertEqual(config["nodes"], MODULE.KLEIN_NODES)
        self.assertEqual(config["model_ids"], [MODULE.KLEIN_MODEL])
        self.assertEqual((config["size"], config["steps"]), ("1024x1024", 4))
        self.assertEqual(config["capabilities"], {"image_generation": True, "image_edit": False})
        self.assertEqual(config["access_grants"], [{"principal_type": "user", "principal_id": "*", "permission": "read"}])
        self.assertTrue(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], f"osr-comfyui:{MODULE.KLEIN_MODEL}")
        self.assertEqual(Handler.verified[-1]["url"], f"{self.base}/comfy")
        self.assertIn("ComfyUI 0.42.1", out)
        self.run_script()
        self.assertEqual(len(self.comfy()), 1)   # a rerun updates it

    def test_an_osr_connection_to_an_old_address_is_moved(self):
        old = {"id": "c1", "name": "ComfyUI", "type": "comfyui", "url": "http://10.0.0.30:8188", "key": "",
               "config": {"enable": True, "workflow": json.dumps(MODULE.KLEIN_WORKFLOW), "model_ids": ["gone"]}}
        router = {"id": "osr-router", "name": "Open Smart Router", "type": "openai", "url": "http://127.0.0.1:8000/v1",
                  "key": "k", "config": {"enable": True, "model_ids": ["image"]}}
        Handler.config["IMAGE_CONNECTIONS"] = [old, router]
        self.run_script("--variant", "klein-4b")
        first, second = Handler.config["IMAGE_CONNECTIONS"]
        self.assertEqual((first["id"], first["url"]), ("c1", f"{self.base}/comfy"))
        self.assertEqual(first["config"]["model_ids"], [MODULE.KLEIN_MODEL])
        self.assertEqual(second, router)
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], f"c1:{MODULE.KLEIN_MODEL}")

    def test_a_custom_workflow_connection_is_kept(self):
        custom = {"1": {"inputs": {"unet_name": "flux.safetensors"}, "class_type": "UNETLoader"}}
        mine = {"id": "mine", "name": "Mine", "type": "comfyui", "url": f"{self.base}/comfy", "key": "",
                "config": {"enable": True, "workflow": json.dumps(custom), "model_ids": ["my-model"],
                           "nodes": [{"type": "model", "key": "unet_name", "node_ids": ["1"]}]}}
        Handler.config.update(IMAGE_CONNECTIONS=[copy.deepcopy(mine)], IMAGE_GENERATION_DEFAULT_MODEL="mine:my-model",
                              ENABLE_IMAGE_GENERATION=True)
        out = self.run_script()
        (connection,) = self.comfy()
        self.assertEqual(connection["config"]["workflow"], mine["config"]["workflow"])
        self.assertEqual(connection["config"]["nodes"], mine["config"]["nodes"])
        self.assertEqual(connection["config"]["model_ids"], ["my-model"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "mine:my-model")
        self.assertIn("Keeping the custom ComfyUI workflow", out)

    def test_missing_klein_assets_leave_the_connection_off(self):
        Handler.encoders = []
        out = self.run_script()
        (connection,) = self.comfy()
        self.assertFalse(connection["config"]["enable"])
        self.assertEqual(connection["config"]["model_ids"], [])
        self.assertFalse(Handler.config["ENABLE_IMAGE_GENERATION"])
        self.assertEqual(Handler.config["IMAGE_GENERATION_DEFAULT_MODEL"], "")
        self.assertIn(MODULE.KLEIN_ENCODER, out)

    def test_size_steps_and_9b(self):
        selected = MODULE.VARIANTS["klein-9b"]
        Handler.diffusion_models.append(selected["model"])
        Handler.encoders.append(selected["encoder"])
        self.run_script("--variant", "klein-9b", "--image-size", "768x768", "--image-steps", "6")
        config = self.comfy()[0]["config"]
        self.assertEqual(json.loads(config["workflow"]), selected["workflow"])
        self.assertEqual((config["size"], config["steps"]), ("768x768", 6))
        self.run_script()   # Auto keeps the selected workflow on reintegration.
        self.assertEqual(self.comfy()[0]["config"]["model_ids"], [selected["model"]])

    def test_unreachable_from_open_webui_restores_the_previous_settings_013(self):
        Handler.reachable = False
        before = copy.deepcopy(Handler.config)
        with self.assertRaisesRegex(RuntimeError, "firewall.*previous image settings were restored"):
            self.run_script()
        self.assertEqual(Handler.config, before)

    def test_a_model_open_webui_does_not_list_restores_the_previous_settings_013(self):
        Handler.models_override = ["other.safetensors"]
        before = copy.deepcopy(Handler.config)
        with self.assertRaisesRegex(RuntimeError, "does not list the diffusion model"):
            self.run_script()
        self.assertEqual(Handler.config, before)


if __name__ == "__main__":
    unittest.main()
