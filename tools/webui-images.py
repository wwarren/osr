#!/usr/bin/env python3
"""Make the router Open WebUI's image generation engine.

Run inside the router CT as root (the ComfyUI and Colibri provisioners, the OSR
installer and tools/webui-images.sh stage it there). Open WebUI has one image
engine at a time. This sets its OpenAI engine to the router's
POST /v1/images/generations and its model to the router's image alias, which
draws with whichever image server is up (a ComfyUI CT first, then Colibri) and
fails forward to the next. API clients use the same endpoint.

The admin token is read from a file, never from argv. Open WebUI's image
settings are read, the engine fields changed, and the whole set written back,
so every other setting is kept. An admin's custom ComfyUI workflow (engine
comfyui with a workflow that is not one of OSR's) is kept as it is unless
--replace-custom is given. On failure the previous settings are restored.

Open WebUI 0.13 replaced the single engine with a list of image connections
(IMAGE_CONNECTIONS). There the router is one OpenAI connection (id osr-router,
open to every user, generation only) whose models are the router's image alias
and the image models it lists now, and the alias becomes the default model.
Open WebUI's own upgrade turns a 0.12 router engine into such a connection;
this updates that one instead of adding another. An admin's custom ComfyUI
connection stays enabled, and stays the default unless --replace-custom; a
ComfyUI connection with OSR's or the built-in workflow is disabled, as the
router draws with that ComfyUI itself. Open WebUI 0.12.4's image picker is
patched to list the router's models live; 0.13 needs no patch.
"""
import argparse
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
# OSR's own ComfyUI workflows (targets/comfyui) and Open WebUI's built-in one:
# a ComfyUI engine using any of them is replaced; anything else was an admin's.
OSR_WORKFLOW_NAMES = ("flux2-klein-4b-api.json", "flux2-klein-9b-api.json")
DEFAULT_SIZE = "1024x1024"
# Open WebUI 0.13 image connections.
CONNECTION_ID = "osr-router"
CONNECTION_NAME = "Open Smart Router"
PUBLIC_GRANTS = [{"principal_type": "user", "principal_id": "*", "permission": "read"}]
SIZE_PATTERN = r"[1-9][0-9]{1,4}x[1-9][0-9]{1,4}"
PICKER_MARKER = "# OSR_IMAGE_MODELS_PATCH"
PICKER_OLD = """        if image_config.IMAGE_GENERATION_ENGINE == 'openai':
            return [
                {'id': 'dall-e-2', 'name': 'DALL·E 2'},
                {'id': 'dall-e-3', 'name': 'DALL·E 3'},
                {'id': 'gpt-image-1', 'name': 'GPT-IMAGE 1'},
                {'id': 'gpt-image-1.5', 'name': 'GPT-IMAGE 1.5'},
            ]
"""
PICKER_NEW = """        if image_config.IMAGE_GENERATION_ENGINE == 'openai':
            # OSR_IMAGE_MODELS_PATCH: ask the local router for its live image models.
            api_base = image_config.IMAGES_OPENAI_API_BASE_URL.rstrip('/')
            parsed = urlparse(api_base)
            if parsed.hostname in ('127.0.0.1', 'localhost', '::1') and parsed.path.rstrip('/') == '/v1':
                session = await get_session()
                async with session.get(
                    url=f'{api_base}/images/models',
                    headers={'Authorization': f'Bearer {image_config.IMAGES_OPENAI_API_KEY}'},
                    ssl=AIOHTTP_CLIENT_SESSION_SSL,
                ) as r:
                    r.raise_for_status()
                    listed = await r.json()
                return [
                    {'id': item['id'], 'name': 'Automatic (image)' if item['id'] == 'image' else item['id']}
                    for item in listed['data']
                    if isinstance(item, dict) and isinstance(item.get('id'), str)
                ]
            return [
                {'id': 'dall-e-2', 'name': 'DALL·E 2'},
                {'id': 'dall-e-3', 'name': 'DALL·E 3'},
                {'id': 'gpt-image-1', 'name': 'GPT-IMAGE 1'},
                {'id': 'gpt-image-1.5', 'name': 'GPT-IMAGE 1.5'},
            ]
"""


class HTTPStatusError(RuntimeError):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def openwebui_images_path(venv):
    """Find the installed module without importing Open WebUI's server."""
    python = pathlib.Path(venv) / "bin" / "python"
    result = subprocess.run(
        [str(python), "-c", "import sysconfig; print(sysconfig.get_paths()['purelib'])"],
        capture_output=True, text=True, check=True)
    return pathlib.Path(result.stdout.strip()) / "open_webui" / "routers" / "images.py"


def patch_image_picker(path):
    """Patch only the reviewed Open WebUI 0.12.4 model-list branch."""
    path = pathlib.Path(path)
    original = path.read_text(encoding="utf-8")
    if PICKER_MARKER in original:
        return False
    if original.count(PICKER_OLD) != 1:
        raise RuntimeError(f"{path}: unsupported Open WebUI image picker; expected the 0.12.4 branch")
    updated = original.replace(PICKER_OLD, PICKER_NEW, 1)
    compile(updated, str(path), "exec")
    current = path.stat()
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                     dir=path.parent, prefix=".images-osr-", delete=False) as tmp:
        tmp.write(updated)
        temporary = pathlib.Path(tmp.name)
    try:
        os.chmod(temporary, stat.S_IMODE(current.st_mode))
        if hasattr(os, "chown"):
            os.chown(temporary, current.st_uid, current.st_gid)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def request(url, token=None, data=None, method=None, expect=dict, timeout=30):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data, separators=(",", ":")).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with OPENER.open(req, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read(500).decode("utf-8", "replace")
        exc.close()
        raise HTTPStatusError(f"{url}: HTTP {exc.code}: {detail}", exc.code) from exc
    try:
        body = json.loads(raw) if raw else None
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{url}: response is not JSON") from exc
    if expect is not None and not isinstance(body, expect):
        raise RuntimeError(f"{url}: unexpected {type(body).__name__} response")
    return body


def env_value(path, key):
    """KEY=value from an env file (the last one wins); '' when absent."""
    value = ""
    try:
        for line in pathlib.Path(path).read_text().splitlines():
            if line.startswith(f"{key}="):
                value = line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return value


def router_key(secrets_file):
    """The key Open WebUI already sends the router for chat."""
    key = env_value(secrets_file, "ROUTER_API_KEY")
    if not key:
        key = env_value(secrets_file, "OPENAI_API_KEYS").split(";")[0].strip()
    return key or "none"


def osr_workflows(script_dir):
    """The workflows OSR itself puts in Open WebUI: staged beside this script,
    or in the repository's targets/comfyui when run from a checkout."""
    found = []
    for name in OSR_WORKFLOW_NAMES:
        for folder in (script_dir, script_dir.parent / "targets" / "comfyui"):
            try:
                found.append(json.loads((folder / name).read_text()))
                break
            except (OSError, json.JSONDecodeError):
                continue
    return found


def custom_comfyui(config, known):
    """Is Open WebUI drawing with an admin's own ComfyUI workflow?"""
    if config.get("IMAGE_GENERATION_ENGINE") != "comfyui":
        return False
    return custom_workflow(config.get("COMFYUI_WORKFLOW"), known)


def custom_workflow(text, known):
    """Is TEXT a ComfyUI workflow an admin made (not OSR's, not the built-in one)?"""
    if not isinstance(text, str) or not text.strip():
        return False
    try:
        workflow = json.loads(text)
    except json.JSONDecodeError:
        return True
    if not isinstance(workflow, dict):
        return True
    # Open WebUI's built-in checkpoint graph has a CheckpointLoaderSimple and a KSampler.
    classes = {node.get("class_type") for node in workflow.values() if isinstance(node, dict)}
    builtin = classes == {"KSampler", "CheckpointLoaderSimple", "EmptyLatentImage",
                          "CLIPTextEncode", "VAEDecode", "SaveImage"}
    return not builtin and workflow not in known


def router_models(router, key, wait, expect):
    """The router's image models, after a refresh; waits up to `wait` seconds
    for the alias (and `expect`, when given) to appear."""
    deadline = time.monotonic() + max(0, wait)
    while True:
        try:
            request(f"{router}/routing/refresh?probe=false", key, data={}, method="POST", expect=None)
        except (RuntimeError, urllib.error.URLError, OSError):
            pass
        listed = request(f"{router}/v1/images/models", key)
        names = [item.get("id") for item in listed.get("data", []) if isinstance(item, dict)]
        wanted = expect in names if expect else bool(names)
        if wanted or time.monotonic() >= deadline:
            return names
        time.sleep(3)


def is_router_connection(item, router):
    return (isinstance(item, dict) and item.get("type") == "openai"
            and str(item.get("url") or "").rstrip("/") == f"{router}/v1")


def connection_id_of(ref):
    """The connection of a model reference ("<connection id>:<model>")."""
    return ref.split(":", 1)[0] if isinstance(ref, str) and ":" in ref else ""


def is_custom_comfyui_connection(item, known):
    config = item.get("config") if isinstance(item, dict) else None
    return (isinstance(config, dict) and item.get("type") == "comfyui"
            and custom_workflow(config.get("workflow"), known))


def save_connections(base, admin_token, original, new, check):
    """Write NEW and read it back; restore ORIGINAL when CHECK(saved) fails."""
    request(f"{base}/config/update", admin_token, new)
    try:
        check(request(f"{base}/config", admin_token))
    except (RuntimeError, urllib.error.URLError, OSError) as exc:
        try:
            request(f"{base}/config/update", admin_token, original)
            restored = "the previous image settings were restored"
        except (RuntimeError, urllib.error.URLError, OSError) as again:
            restored = f"restoring the previous image settings failed too ({again})"
        raise RuntimeError(f"{exc}; {restored}") from exc


def configure_connections(args, base, admin_token, original, router, key):
    """Open WebUI 0.13 and later: the router as one image connection."""
    connections = [dict(item) for item in original.get("IMAGE_CONNECTIONS") or [] if isinstance(item, dict)]
    ours = [item for item in connections if is_router_connection(item, router)]
    if args.off:
        if not ours:
            print("Open WebUI does not draw through the router; its image settings were left as they are.")
            return
        ids = {item.get("id") for item in ours}
        for item in ours:
            item["config"] = dict(item.get("config") or {}, enable=False)
        new = dict(original, IMAGE_CONNECTIONS=connections)
        if connection_id_of(original.get("IMAGE_GENERATION_DEFAULT_MODEL")) in ids:
            new["IMAGE_GENERATION_DEFAULT_MODEL"] = ""

        def check_off(saved):
            for item in saved.get("IMAGE_CONNECTIONS") or []:
                if isinstance(item, dict) and item.get("id") in ids and (item.get("config") or {}).get("enable", True):
                    raise RuntimeError(f"Open WebUI did not keep the connection {item.get('id')!r} off")

        save_connections(base, admin_token, original, new, check_off)
        print("Open WebUI's image generation through the router is off.")
        return

    known = osr_workflows(pathlib.Path(__file__).resolve().parent)
    names = router_models(router, key, args.wait, args.expect_model)
    ready = args.alias in names and (not args.expect_model or args.expect_model in names)
    existing = ours[0] if ours else {}
    config = dict(existing.get("config") or {})
    size = args.image_size or config.get("size") or DEFAULT_SIZE
    if not re.fullmatch(SIZE_PATTERN, str(size)):
        size = DEFAULT_SIZE   # "auto" is for gpt-image; the router's servers need a size
    params = config.get("params") if isinstance(config.get("params"), dict) else {}
    if args.image_steps:
        params = dict(params, steps=args.image_steps)
    taken = {item.get("id") for item in connections if item is not existing}
    connection_id = existing.get("id") or CONNECTION_ID
    if connection_id in taken:
        connection_id = f"{CONNECTION_ID}-{len(connections)}"
    config.update(
        enable=ready,
        capabilities={"image_generation": True, "image_edit": False},   # the router has no /images/edits
        model_ids=[args.alias] + [name for name in names if name != args.alias],
        access_grants=config.get("access_grants") or PUBLIC_GRANTS,
        auth_type="bearer",
        size=size,
        params=params,
    )
    connection = dict(existing, id=connection_id, name=CONNECTION_NAME, type="openai",
                      url=f"{router}/v1", key=key, config=config)
    updated, placed, superseded = [], False, []
    for item in connections:
        if is_router_connection(item, router):
            if not placed:
                updated.append(connection)
                placed = True
            continue   # a second router connection would list every model twice
        if item.get("type") == "comfyui" and (item.get("config") or {}).get("enable", True) \
                and not is_custom_comfyui_connection(item, known):
            # OSR's (or the built-in) ComfyUI workflow: the router draws with that ComfyUI itself.
            item = dict(item, config=dict(item.get("config") or {}, enable=False))
            superseded.append(item.get("name") or item.get("id"))
        updated.append(item)
    if not placed:
        updated.append(connection)

    default_ref = f"{connection_id}:{args.alias}"
    current = original.get("IMAGE_GENERATION_DEFAULT_MODEL") or ""
    current_connection = next((item for item in updated if item.get("id") == connection_id_of(current)), None)
    keep_custom = (current_connection is not None and not args.replace_custom
                   and is_custom_comfyui_connection(current_connection, known)
                   and (current_connection.get("config") or {}).get("enable", True))
    new = dict(original, IMAGE_CONNECTIONS=updated)
    if ready:
        new["ENABLE_IMAGE_GENERATION"] = True
        if not keep_custom:
            new["IMAGE_GENERATION_DEFAULT_MODEL"] = default_ref
    elif connection_id_of(current) == connection_id:
        new["IMAGE_GENERATION_DEFAULT_MODEL"] = ""

    def check(saved):
        match = next((item for item in saved.get("IMAGE_CONNECTIONS") or []
                      if isinstance(item, dict) and item.get("id") == connection_id), None)
        if match is None or str(match.get("url") or "").rstrip("/") != f"{router}/v1":
            raise RuntimeError(f"Open WebUI did not keep the image connection {connection_id!r} to {router}/v1")
        if (match.get("config") or {}).get("model_ids") != config["model_ids"]:
            raise RuntimeError(f"Open WebUI did not keep the router's image models on {connection_id!r}")
        if saved.get("IMAGE_GENERATION_DEFAULT_MODEL") != new.get("IMAGE_GENERATION_DEFAULT_MODEL"):
            raise RuntimeError("Open WebUI did not keep the default image model "
                               f"{new.get('IMAGE_GENERATION_DEFAULT_MODEL')!r}")

    save_connections(base, admin_token, original, new, check)
    print(f"Open WebUI generates images through the router ({router}/v1, image connection "
          f"{connection_id!r}, model {args.alias!r}, {size}).")
    if superseded:
        print(f"Disabled the ComfyUI connection(s) the router now draws with: {', '.join(map(str, superseded))}.")
    if ready:
        shown = ", ".join(n for n in names if n != args.alias)
        print(f"The router draws with: {shown}. Change the size or steps under Admin Settings > Images.")
        if keep_custom:
            print(f"The default image model stays {current!r} (an admin's custom ComfyUI workflow);")
            print("rerun with --replace-custom to make the router's alias the default.")
        print("A new image model on the router appears in Open WebUI after this step runs again.")
    else:
        wanted = args.expect_model or "an image model"
        print(f"The connection is left off: the router does not list {wanted} yet "
              f"(it lists: {', '.join(names) or 'nothing'}). Check GET {router}/routing/inventory,")
        print("then rerun this step, or enable the connection under Admin Settings > Images once a model is up.")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--webui-url", default="")
    parser.add_argument("--admin-token-file", default="")
    parser.add_argument("--webui-venv", default="/app/openwebui/venv")
    parser.add_argument("--picker-module", default="", help=argparse.SUPPRESS)
    parser.add_argument("--no-restart", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--patch-only", action="store_true",
                        help="patch the installed Open WebUI 0.12.4 image picker after a pip install "
                             "(0.13 lists the router's models without a patch)")
    parser.add_argument("--router-url", default="")
    parser.add_argument("--router-env", default="/app/router/.env")
    parser.add_argument("--router-secrets", default="/app/router/secrets.env")
    parser.add_argument("--alias", default="image")
    parser.add_argument("--expect-model", default="",
                        help="an image model the router must list before generation is enabled")
    parser.add_argument("--image-size", default="")
    parser.add_argument("--image-steps", type=int, default=0)
    parser.add_argument("--wait", type=int, default=120, help="seconds to wait for the router's image models")
    parser.add_argument("--replace-custom", action="store_true",
                        help="replace an admin's custom ComfyUI workflow too")
    parser.add_argument("--off", action="store_true", help="turn image generation off")
    args = parser.parse_args(argv)
    if args.patch_only:
        picker = pathlib.Path(args.picker_module) if args.picker_module else openwebui_images_path(args.webui_venv)
        changed = patch_image_picker(picker)
        print(f"Open WebUI image picker: {'patched' if changed else 'already patched'} ({picker}).")
        return
    if not args.webui_url or not args.admin_token_file:
        parser.error("--webui-url and --admin-token-file are required")
    if args.image_size and not re.fullmatch(r"[1-9][0-9]{1,4}x[1-9][0-9]{1,4}", args.image_size):
        raise ValueError("--image-size must be WIDTHxHEIGHT, e.g. 1024x1024")
    if args.image_steps < 0:
        raise ValueError("--image-steps must be positive")
    admin_token = pathlib.Path(args.admin_token_file).read_text().strip()
    if not admin_token:
        raise RuntimeError("The admin token file is empty")
    webui = args.webui_url.rstrip("/")
    base = f"{webui}/api/v1/images"
    port = env_value(args.router_env, "ROUTER_PORT") or "8000"
    router = (args.router_url or f"http://127.0.0.1:{port}").rstrip("/")
    key = router_key(args.router_secrets)

    original = request(f"{base}/config", admin_token)
    if isinstance(original.get("IMAGE_CONNECTIONS"), list):
        configure_connections(args, base, admin_token, original, router, key)
        return
    if "IMAGES_OPENAI_API_BASE_URL" not in original or "IMAGE_GENERATION_ENGINE" not in original:
        raise RuntimeError("This Open WebUI's image settings API is not supported "
                           "(no IMAGES_OPENAI_API_BASE_URL in /api/v1/images/config)")
    if args.off:
        if original.get("IMAGE_GENERATION_ENGINE") == "openai" and \
                str(original.get("IMAGES_OPENAI_API_BASE_URL", "")).rstrip("/") == f"{router}/v1":
            request(f"{base}/config/update", admin_token, dict(original, ENABLE_IMAGE_GENERATION=False))
            print("Open WebUI's image generation through the router is off.")
        else:
            print("Open WebUI does not draw through the router; its image settings were left as they are.")
        return
    if custom_comfyui(original, osr_workflows(pathlib.Path(__file__).resolve().parent)) and not args.replace_custom:
        print("Open WebUI draws with a custom ComfyUI workflow an admin set up; it is kept.")
        print(f"The router's image models are still on {router}/v1/images/generations for API clients;")
        print("rerun with --replace-custom to make the router Open WebUI's image engine.")
        return

    names = router_models(router, key, args.wait, args.expect_model)
    picker = pathlib.Path(args.picker_module) if args.picker_module else openwebui_images_path(args.webui_venv)
    picker_changed = patch_image_picker(picker)
    if picker_changed and not args.no_restart:
        subprocess.run(["systemctl", "restart", "open-webui.service"], check=True)
        deadline = time.monotonic() + 60
        while True:
            try:
                request(f"{base}/config", admin_token)
                break
            except (RuntimeError, urllib.error.URLError, OSError):
                if time.monotonic() >= deadline:
                    raise RuntimeError("Open WebUI did not answer after the image picker patch") from None
                time.sleep(2)
    ready = args.alias in names and (not args.expect_model or args.expect_model in names)
    size = args.image_size or original.get("IMAGE_SIZE") or DEFAULT_SIZE
    if not re.fullmatch(r"[1-9][0-9]{1,4}x[1-9][0-9]{1,4}", str(size)):
        size = DEFAULT_SIZE   # "auto" is for gpt-image; the router's servers need a size
    params = original.get("IMAGES_OPENAI_API_PARAMS")
    if args.image_steps:
        params = dict(params if isinstance(params, dict) else {}, steps=args.image_steps)
    new = dict(original,
               IMAGE_GENERATION_ENGINE="openai",
               IMAGES_OPENAI_API_BASE_URL=f"{router}/v1",
               IMAGES_OPENAI_API_KEY=key,
               IMAGES_OPENAI_API_VERSION="",
               IMAGES_OPENAI_API_PARAMS=params,
               IMAGE_GENERATION_MODEL=args.alias,
               IMAGE_SIZE=size,
               ENABLE_IMAGE_GENERATION=ready)
    request(f"{base}/config/update", admin_token, new)
    try:
        saved = request(f"{base}/config", admin_token)
        for field in ("IMAGE_GENERATION_ENGINE", "IMAGES_OPENAI_API_BASE_URL", "IMAGE_GENERATION_MODEL"):
            if saved.get(field) != new[field]:
                raise RuntimeError(f"Open WebUI did not keep {field}={new[field]!r} (it has {saved.get(field)!r})")
    except (RuntimeError, urllib.error.URLError, OSError) as exc:
        try:
            request(f"{base}/config/update", admin_token, original)
            restored = "the previous image settings were restored"
        except (RuntimeError, urllib.error.URLError, OSError) as again:
            restored = f"restoring the previous image settings failed too ({again})"
        raise RuntimeError(f"{exc}; {restored}") from exc

    print(f"Open WebUI generates images through the router ({router}/v1, model {args.alias!r}, {size}).")
    if ready:
        shown = ", ".join(n for n in names if n != args.alias)
        print(f"The router draws with: {shown}. Change the size or steps under Admin Settings > Images.")
    else:
        wanted = args.expect_model or "an image model"
        print(f"Image generation is left off: the router does not list {wanted} yet "
              f"(it lists: {', '.join(names) or 'nothing'}). Check GET {router}/routing/inventory,")
        print("then rerun this step, or turn it on under Admin Settings > Images once a model is up.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as exc:
        print(f"Image integration failed: {exc}", file=sys.stderr)
        sys.exit(1)
