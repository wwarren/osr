#!/usr/bin/env python3
"""Make a ComfyUI target the image generation engine of Open WebUI.

Run inside the router CT (provision-lxc.sh stages it there). The admin token is
read from a file, never from argv. Open WebUI's image settings are read, the
ComfyUI fields changed, and the whole set written back, so every other image
setting (and a custom workflow an admin made) is kept. The result is then
checked through Open WebUI's own backend, which also proves that the ComfyUI
CT's firewall admits the router; on failure the previous settings are restored.
"""
import argparse
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# Open WebUI's built-in checkpoint graph, used only to recognise an untouched
# installation. Klein uses separate diffusion, text encoder and VAE files.
DEFAULT_WORKFLOW = {
    "3": {"inputs": {"seed": 0, "steps": 20, "cfg": 8, "sampler_name": "euler",
                     "scheduler": "normal", "denoise": 1, "model": ["4", 0],
                     "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["5", 0]},
          "class_type": "KSampler", "_meta": {"title": "KSampler"}},
    "4": {"inputs": {"ckpt_name": "model.safetensors"},
          "class_type": "CheckpointLoaderSimple", "_meta": {"title": "Load Checkpoint"}},
    "5": {"inputs": {"width": 512, "height": 512, "batch_size": 1},
          "class_type": "EmptyLatentImage", "_meta": {"title": "Empty Latent Image"}},
    "6": {"inputs": {"text": "Prompt", "clip": ["4", 1]},
          "class_type": "CLIPTextEncode", "_meta": {"title": "CLIP Text Encode (Prompt)"}},
    "7": {"inputs": {"text": "", "clip": ["4", 1]},
          "class_type": "CLIPTextEncode", "_meta": {"title": "CLIP Text Encode (Prompt)"}},
    "8": {"inputs": {"samples": ["3", 0], "vae": ["4", 2]},
          "class_type": "VAEDecode", "_meta": {"title": "VAE Decode"}},
    "9": {"inputs": {"filename_prefix": "ComfyUI", "images": ["8", 0]},
          "class_type": "SaveImage", "_meta": {"title": "Save Image"}},
}
WORKFLOWS = {
    size: json.loads(pathlib.Path(__file__).with_name(f"flux2-klein-{size}-api.json").read_text())
    for size in ("4b", "9b")
}
KLEIN_VAE = "flux2-vae.safetensors"
# The files are the ones klein-weights.txt downloads into the ComfyUI CT.
VARIANTS = {
    "klein-4b": {"workflow": WORKFLOWS["4b"], "model": "flux-2-klein-4b-fp8.safetensors",
                 "encoder": "qwen_3_4b.safetensors", "vae": KLEIN_VAE},
    "klein-9b": {"workflow": WORKFLOWS["9b"], "model": "flux-2-klein-9b-fp8.safetensors",
                 "encoder": "qwen_3_8b_fp8mixed.safetensors", "vae": KLEIN_VAE},
}
# The router installer's default: openly licensed, and the smaller download.
DEFAULT_VARIANT = "klein-4b"
KLEIN_WORKFLOW = VARIANTS[DEFAULT_VARIANT]["workflow"]
KLEIN_MODEL = VARIANTS[DEFAULT_VARIANT]["model"]
KLEIN_ENCODER = VARIANTS[DEFAULT_VARIANT]["encoder"]
KLEIN_NODES = [
    {"type": "prompt", "key": "text", "node_ids": ["4"]},
    {"type": "model", "key": "unet_name", "node_ids": ["1"]},
    {"type": "width", "key": "width", "node_ids": ["6", "7"]},
    {"type": "height", "key": "height", "node_ids": ["6", "7"]},
    {"type": "n", "key": "batch_size", "node_ids": ["6"]},
    {"type": "steps", "key": "steps", "node_ids": ["7"]},
    {"type": "seed", "key": "noise_seed", "node_ids": ["8"]},
]


def request(url, token=None, data=None, expect=dict):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data, separators=(",", ":")).encode()
    try:
        with OPENER.open(urllib.request.Request(url, data=data, headers=headers), timeout=30) as response:
            body = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read(500).decode("utf-8", "replace")
        exc.close()
        raise RuntimeError(f"{url}: HTTP {exc.code}: {detail}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{url}: response is not JSON") from exc
    if expect is not None and not isinstance(body, expect):
        raise RuntimeError(f"{url}: unexpected {type(body).__name__} response")
    return body


def combo_options(spec):
    """The choices of a ComfyUI combo input, in either /object_info format:
    [["a", "b"], {...}] (legacy) or ["COMBO", {"options": ["a", "b"]}]."""
    if not isinstance(spec, list) or not spec:
        return []
    if isinstance(spec[0], list):
        return [item for item in spec[0] if isinstance(item, str)]
    if spec[0] == "COMBO" and len(spec) > 1 and isinstance(spec[1], dict):
        return [item for item in spec[1].get("options", []) if isinstance(item, str)]
    return []


def comfyui_models(comfyui, workflow=KLEIN_WORKFLOW, check_klein=True):
    """Check ComfyUI and, for our workflow, inspect its nodes and model files."""
    stats = request(f"{comfyui}/system_stats")
    version = stats.get("system", {}).get("comfyui_version") if isinstance(stats.get("system"), dict) else None
    if not isinstance(version, str) or not version:
        raise RuntimeError(f"{comfyui}/system_stats: not a ComfyUI server")
    if not check_klein:
        return version, {}
    info = request(f"{comfyui}/object_info")
    missing_nodes = sorted({node["class_type"] for node in workflow.values()} - info.keys())
    if missing_nodes:
        raise RuntimeError(f"{comfyui}: missing Klein workflow nodes: {', '.join(missing_nodes)}")
    models = {}
    for node, key in (("UNETLoader", "unet_name"), ("CLIPLoader", "clip_name"),
                      ("VAELoader", "vae_name")):
        try:
            spec = info[node]["input"]["required"][key]
        except (KeyError, TypeError) as exc:
            raise RuntimeError(f"{comfyui}: {node}.{key} is missing from /object_info") from exc
        models[key] = combo_options(spec)
    return version, models


def is_default_workflow(text):
    if not isinstance(text, str) or not text.strip():
        return True
    try:
        return json.loads(text) in (DEFAULT_WORKFLOW, *WORKFLOWS.values())
    except json.JSONDecodeError:
        return False


def choose_model(wanted, current, diffusion_models, default=KLEIN_MODEL):
    """Select the variant's UNET, or a compatible explicit override."""
    if wanted:
        if wanted not in diffusion_models:
            listed = ", ".join(diffusion_models) or "none"
            raise RuntimeError(f"ComfyUI has no diffusion model {wanted!r} (it lists: {listed})")
        return wanted
    if current in diffusion_models and current == default:
        return current
    return default if default in diffusion_models else None


def build_config(config, comfyui, model, size, steps, workflow=KLEIN_WORKFLOW):
    """Open WebUI's image settings with ComfyUI as the engine."""
    new = dict(config)
    new["IMAGE_GENERATION_ENGINE"] = "comfyui"
    new["COMFYUI_BASE_URL"] = comfyui
    if is_default_workflow(config.get("COMFYUI_WORKFLOW")):
        new["COMFYUI_WORKFLOW"] = json.dumps(workflow, indent=2)
        new["COMFYUI_WORKFLOW_NODES"] = KLEIN_NODES
    if model:
        new["IMAGE_GENERATION_MODEL"] = model
        new["ENABLE_IMAGE_GENERATION"] = True
    else:
        # Nothing to draw with yet: keep the engine set up, but off.
        new["IMAGE_GENERATION_MODEL"] = ""
        new["ENABLE_IMAGE_GENERATION"] = False
    if size:
        new["IMAGE_SIZE"] = size
    if steps:
        new["IMAGE_STEPS"] = steps
    return new


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--webui-url", required=True)
    parser.add_argument("--comfyui-url", required=True)
    parser.add_argument("--admin-token-file", required=True)
    parser.add_argument("--model", default="")
    parser.add_argument("--variant", choices=("auto", *VARIANTS), default="auto")
    parser.add_argument("--image-size", default="")
    parser.add_argument("--image-steps", type=int, default=0)
    args = parser.parse_args(argv)
    if args.image_size and not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", args.image_size):
        raise ValueError("--image-size must be WIDTHxHEIGHT, e.g. 1024x1024")
    if args.image_steps < 0:
        raise ValueError("--image-steps must be positive")

    admin_token = pathlib.Path(args.admin_token_file).read_text().strip()
    if not admin_token:
        raise RuntimeError("The admin token file is empty")
    webui = args.webui_url.rstrip("/")
    comfyui = args.comfyui_url.rstrip("/")
    base = f"{webui}/api/v1/images"

    original = request(f"{base}/config", admin_token)
    if "COMFYUI_BASE_URL" not in original or "IMAGE_GENERATION_ENGINE" not in original:
        raise RuntimeError("This Open WebUI's image settings API is not supported "
                           "(no COMFYUI_BASE_URL in /api/v1/images/config; the router pins Open WebUI 0.11.0)")
    custom = not is_default_workflow(original.get("COMFYUI_WORKFLOW"))
    variant = args.variant
    if variant == "auto":
        try:
            current_workflow = json.loads(original.get("COMFYUI_WORKFLOW") or "null")
        except json.JSONDecodeError:
            current_workflow = None
        variant = next((name for name, item in VARIANTS.items()
                        if current_workflow == item["workflow"]), None)
        if variant is None and not custom:
            # A fresh Open WebUI: the variant whose three files ComfyUI has.
            _version, available = comfyui_models(comfyui, KLEIN_WORKFLOW)
            variant = next((name for name, item in VARIANTS.items()
                            if item["model"] in available["unet_name"]
                            and item["encoder"] in available["clip_name"]
                            and item["vae"] in available["vae_name"]), DEFAULT_VARIANT)
        variant = variant or DEFAULT_VARIANT
    selected = VARIANTS[variant]
    if custom:
        print("Keeping the custom ComfyUI workflow and its node mapping configured in Open WebUI.")
    # Check from the router CT; custom workflows do not depend on Klein's nodes.
    version, models = comfyui_models(comfyui, selected["workflow"], check_klein=not custom)
    model = (original.get("IMAGE_GENERATION_MODEL", "") if custom else
             choose_model(args.model, original.get("IMAGE_GENERATION_MODEL", ""),
                          models["unet_name"], selected["model"]))
    missing = ([] if custom else [name for name, available in
               ((selected["encoder"], models["clip_name"]), (selected["vae"], models["vae_name"]))
               if name not in available])
    ready = bool(model) and not missing
    if custom:
        new = dict(original, IMAGE_GENERATION_ENGINE="comfyui", COMFYUI_BASE_URL=comfyui)
    else:
        new = build_config(original, comfyui, model if ready else None,
                           args.image_size or "1024x1024", args.image_steps or 4,
                           selected["workflow"])

    request(f"{base}/config/update", admin_token, new)
    try:
        # Open WebUI's backend checks the saved URL itself (GET <url>/object_info).
        if request(f"{base}/config/url/verify", admin_token, expect=None) is not True:
            raise RuntimeError("Open WebUI did not verify the ComfyUI URL")
        if ready and not custom:
            listed = request(f"{base}/models", admin_token, expect=list)
            if not any(isinstance(item, dict) and item.get("id") == model for item in listed):
                raise RuntimeError(f"Open WebUI does not list the diffusion model {model!r}")
    except (RuntimeError, urllib.error.URLError, OSError) as exc:
        try:
            request(f"{base}/config/update", admin_token, original)
            restored = "the previous image settings were restored"
        except (RuntimeError, urllib.error.URLError, OSError) as again:
            restored = f"restoring the previous image settings failed too ({again})"
        raise RuntimeError(f"{exc}. Open WebUI on the router could not use ComfyUI at {comfyui} "
                           f"(is the router admitted by the ComfyUI CT's firewall?); {restored}") from exc

    print(f"Open WebUI generates images with ComfyUI {version} at {comfyui}.")
    if custom:
        print("The existing custom workflow and image settings were preserved.")
    elif ready:
        print(f"Image model: {variant}; diffusion file: {model}. Change it under Admin Settings > Images.")
    else:
        print(f"Image generation is left off until the {variant} assets are installed:")
        for name in ([selected["model"]] if not model else []) + missing:
            print(f"  {name}")
        print("Download them in the ComfyUI CT with: env COMFYUI_IMAGE_VARIANT="
              f"{variant} bash /root/comfyui-target-deploy/install-target.sh")
        print("(klein-9b also needs HF_TOKEN_FILE), then rerun provision-lxc.sh --integrate-only.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as exc:
        print(f"Integration failed: {exc}", file=sys.stderr)
        sys.exit(1)
