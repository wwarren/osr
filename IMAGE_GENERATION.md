# Image generation

The router answers the OpenAI images API, `POST /v1/images/generations`, from
its own image servers, and Open WebUI draws through it (Admin Settings >
Images: engine OpenAI, `http://127.0.0.1:8000/v1`, model `image`):

| Image server | How the router finds it | Models |
|---|---|---|
| A [ComfyUI CT](targets/comfyui/README.md) | `COMFYUI_SERVERS` in `env/router.env` (its provisioner adds it; `manage-model-servers set-comfyui` / `add-comfyui`) | `flux2-klein-4b-comfyui`, `flux2-klein-9b-comfyui`, when ComfyUI has that variant's three files |
| A [Colibri CT](targets/colibri/README.md) serving an image model | Its `/v1/models` entry says `image_generation` (it is already a model server) | `qwen-image-2.1-colibri` |

Ask for `image` (the `[images] alias`) to take whichever is up: ComfyUI first
(`[images] prefer`), then the least busy, failing forward to the next on a
connect error, a failed job or a 5xx. A model's own name asks for that one.
Request fields: `prompt`, `size` (`WxH`; rounded to each server's multiple:
16 for ComfyUI, 32 for Colibri, within 256-2048), `n` (up to `[images] max_n`,
4), `steps`, `seed`, `stream` (Colibri only). Answers are `b64_json`, with a
`comfyui` or `colibri` block saying the size, seed and steps used. A picture
may take `[images] read_timeout_seconds` (900): a CPU takes minutes.
Image models are never offered for chat and are not in `/v1/models`. A cloud
image model set with `set-cloud-models` (`openai/gpt-image-1`,
`gemini/imagen-...`) goes to LiteLLM, only when named.
For an image deployment added directly to LiteLLM under a custom name, set
`model_info.mode: image_generation` in its LiteLLM config. The router uses that
mode to keep the custom name out of its chat model fallback.

```bash
curl -s http://<ct-ip>:8000/v1/images/generations -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model": "image", "prompt": "a lighthouse at dusk", "size": "1024x576"}' |
  python3 -c 'import sys, json, base64; open("out.png", "wb").write(base64.b64decode(json.load(sys.stdin)["data"][0]["b64_json"]))'
bash tools/webui-images.sh          # on the Proxmox host: make the router Open WebUI's image engine
```

The ComfyUI provisioner and the OSR installer (for a Colibri CT given an image
model) set Open WebUI up with `tools/webui-images.py`; `tools/webui-images.sh`
does it by hand (`--expect-model NAME` waits for a model, `--off` turns it
off). On Open WebUI 0.13 (the pin), image engines are a list of connections:
the helper adds the router as one OpenAI connection, `osr-router`, open to all
users, generation only, listing the `image` alias and the image models the
router serves at that moment, with the alias as the default model. Rerun it
after adding an image model so the picker lists it by name; the alias draws
with it at once anyway. Open WebUI's own upgrade from 0.12 turns the old
router engine into such a connection (with the alias only), and the helper
updates that one rather than adding another. A ComfyUI connection with OSR's
workflow is disabled, as the router draws with that ComfyUI itself. An admin's
own ComfyUI workflow stays enabled and stays the default unless
`--replace-custom`. On Open WebUI 0.12.4, set with `OPENWEBUI_VERSION`, the
helper instead patches its image picker to read `/v1/images/models` from the
local router, and the installer and version manager reapply that patch after
pip replaces Open WebUI. A ComfyUI CT set up before this release still has Open
WebUI drive it directly: `CT_ID=<id> bash targets/comfyui/provision-lxc.sh
--integrate-only` moves it behind the router.

