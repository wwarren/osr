# ComfyUI image generation target

[ComfyUI](https://github.com/Comfy-Org/ComfyUI) in its own CT, used by the
router's Open WebUI as its **image generation engine** (the image button in
chats, and image requests through Open WebUI's API). It is not a model server:
the router's chat routing never sends requests to it.

The CT and the first ComfyUI install come from the Proxmox VE community
script [`ct/comfyui.sh`](https://community-scripts.org/scripts/comfyui); the
files here preset that script, then bring the result into the same conventions
as the other targets and connect it to Open WebUI.

```
Open WebUI (router CT) --HTTP + WebSocket :8188--> comfyui.service (this CT) --> GPU
```

| | Community script alone | After `provision-lxc.sh` |
| --- | --- | --- |
| Service account | root | `comfyui` (unprivileged), video/render groups |
| Code | `/opt/ComfyUI` (latest release, unverified) | `/opt/comfyui-target/current` → that tree, then pinned, commit-verified releases |
| Python | uv's 3.12 under `/root/.local/share/uv` | a copy in `/opt/comfyui-target/python` the service account can run |
| Models, nodes, outputs, user data | inside `/opt/ComfyUI` | `/var/lib/comfyui-target` (`--base-directory`) |
| Settings | the unit's `ExecStart` | `/etc/comfyui-target/comfyui.env` |
| Network | port 8188 open to everyone, no authentication | CT firewall: TCP 8188 from the router (and `UI_ALLOW_CIDR`) only |
| Hardening | none | `ProtectSystem=strict`, no capabilities, only `/var/lib/comfyui-target` writable |
| Upgrades | `update` only says "use ComfyUI-Manager" | `install-target.sh --upgrade` (pinned tag + commit, built beside the running release, rollback) |
| Open WebUI | — | Admin Settings > Images: engine ComfyUI, its URL, and the selected distilled Klein API workflow |

The adoption is a systemd drop-in
(`/etc/systemd/system/comfyui.service.d/10-comfyui-target.conf`), so the
community unit is never edited.

## Files

| File | Purpose |
| --- | --- |
| `provision-lxc.sh` | PVE host: runs the community script with presets, writes the CT firewall, adopts, registers with Open WebUI. |
| `install-target.sh` | Inside the CT: adopts the install (safe to re-run), downloads the Klein weights, `--upgrade`. |
| `klein-weights.txt` | The weights of each Klein variant: folder, file, size, SHA-256, access and URL. |
| `comfyui-target.conf` | The drop-in: user, paths, env file, hardening. |
| `comfyui.env.example` | Listen address, port and extra ComfyUI options. Installed as `/etc/comfyui-target/comfyui.env` (0640). |
| `integrate-webui.py`, `flux2-klein-{4b,9b}-api.json` | Run in the router CT: set ComfyUI as Open WebUI's image engine with the selected API workflow. |
| `test-install.sh`, `test-provision.sh`, `test-integration.py` | Tests with stubbed system commands and mock servers; nothing is downloaded or created. |

## Provision

On the PVE host, from the repository checkout (the router installer does the
same when **comfyui** is picked from its targets menu):

`bash targets/comfyui/provision-lxc.sh` prompts for the **new ComfyUI CT ID**
and the existing Open WebUI CT ID or IP address. It never chooses a fresh CT ID
on a rerun. For a ComfyUI CT already installed, run
`bash targets/comfyui/provision-lxc.sh --integrate-only` and enter its existing
CT ID to register it with Open WebUI again. To resume an interrupted guest
install or upgrade ComfyUI, use the guest `install-target.sh` described below.

```bash
CT_ID=286 IP_CIDR=192.0.2.86/24 GATEWAY=192.0.2.1 STORAGE=local-lvm ROUTER=280 \
bash targets/comfyui/provision-lxc.sh                      # klein-4b

COMFYUI_IMAGE_VARIANT=klein-9b CT_ID=287 ... bash targets/comfyui/provision-lxc.sh
# asks for a Hugging Face token (or set HF_TOKEN in the environment)
```

1. **Checks first.** Settings, the router's Open WebUI (`/health`,
   `/api/version`) and the admin key (asked for without echo unless
   `OPENWEBUI_ADMIN_TOKEN` is set: an Open WebUI admin API key or JWT) are
   checked before anything is created. So are the image model's weights: each
   URL must answer on Hugging Face, and for `klein-9b` the token must be
   accepted for the gated file.
2. **Community script.** It runs
   `bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/comfyui.sh)"`
   with the settings preset as `var_*` variables, including
   `var_comfyui_gpu_type`, which answers the install's GPU menu. It still shows
   its own menu: choose **Default**. The install takes a long time (PyTorch for
   CUDA is several GB). Defaults here are larger than the community ones:
   4 cores, **16 GB RAM, 64 GB disk** (each release's venv is about 6–10 GB;
   the 4B weights are 12.5 GB, the 9B weights 18.4 GB).
3. **Firewall.** `/etc/pve/firewall/<CT_ID>.fw` drops all inbound traffic except
   TCP 8188 from the address the router uses to reach the CT (detected with
   `ip route get` on the router, or `ROUTER_IP`) and from `UI_ALLOW_CIDR`, and
   the CT's `net0` gets `firewall=1`. An existing firewall file is never
   replaced. The rules only take effect when the Proxmox firewall is enabled
   for the datacenter; the script warns when it is not.
4. **Adoption and weights.** `install-target.sh` runs in the CT (below), then
   downloads the selected variant's diffusion model, text encoder and VAE
   ([Weights](#weights)). For `klein-9b` the token is pushed into the CT as a
   0600 file for this step only and removed afterwards, also when it fails.
5. **Open WebUI.** `integrate-webui.py` runs in the router CT (staged there in a
   0700 directory and removed afterwards) and sets the image settings (below).

The router installer asks for an image model when ComfyUI is selected. It offers
the two distilled Klein variants that have matching workflows here:

| Choice | Why choose it | License and access |
| --- | --- | --- |
| `klein-4b` (installer default) | Smaller model and encoder; Black Forest Labs estimates about 13 GB VRAM | [Apache 2.0, open download](https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8) |
| `klein-9b` | Larger model and encoder; Black Forest Labs estimates about 29 GB VRAM | [FLUX Non-Commercial License; accept the Hugging Face conditions first](https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8) |

The choice selects the weights the CT downloads and the Open WebUI workflow
that uses them, so image generation works as soon as the run finishes. For
`klein-9b` the installer also asks for a Hugging Face token (or takes
`HF_TOKEN` from the environment): first accept the FLUX Non-Commercial License
on the [model page](https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8)
with your account, then create a read token under Settings > Access Tokens.
The token reaches only the ComfyUI provisioner, as an environment variable.

For a direct `provision-lxc.sh` run, `COMFYUI_IMAGE_VARIANT` defaults to
`klein-4b` for a new CT. With `--integrate-only`, `auto` keeps the Klein
workflow Open WebUI already has, and otherwise uses the variant whose files
ComfyUI has (4B first). `COMFYUI_DOWNLOAD_WEIGHTS=0` skips the download.

The GPU: `GPU=auto` (default) sets ComfyUI up for NVIDIA when the host has
`/dev/nvidia0` and passes it through; when `nvidia-smi` is still missing in the
CT afterwards, the repository's NVIDIA 580.173.02 user-space helper is run.
PyTorch's CUDA 13 build, which the community install picks, needs host driver
580 or newer. `GPU=amd` and `GPU=intel` pass `/dev/dri` (and `/dev/kfd`) through
and install ROCm or XPU PyTorch. `GPU=none` installs CPU-only operation
(`--cpu`), which works but takes minutes per image. `GPU_CARD=<PCI address>`
(for example `0000:03:00.0`) picks one card on a host with several (`GPU=auto`
then means that card's vendor): after the community script, which passes
every card of the vendor, the CT keeps only that card's device nodes plus the
shared ones (`/dev/kfd`, `/dev/nvidiactl`, `/dev/nvidia-uvm*`), and is
restarted before the firewall and the guest install. The router installer
asks which card ComfyUI should use and sets `GPU` and `GPU_CARD` after
`tools/setup-host-gpu.sh`, which first makes the host's NVIDIA, AMD (`amdgpu`)
or Intel Arc (`i915`/`xe`) driver work; run that tool yourself before a direct
`provision-lxc.sh` run on a host whose GPU is not set up yet.

`--dry-run` prints the plan without touching Proxmox, the router or a token.
`--integrate-only` (with `CT_ID`) registers an existing ComfyUI CT with Open
WebUI again, e.g. after adding Klein assets or rebuilding the router. When
rebuilding Open WebUI, pass the original `COMFYUI_IMAGE_VARIANT` explicitly.
`--no-webui` creates and adopts the CT without Open WebUI; set `UI_ALLOW_CIDR`
(or `FIREWALL=0`) so that someone can reach it.

The community script comes from the `main` branch, so it can change between
runs. The wrapper prints its SHA-256; set `COMMUNITY_SCRIPT_SHA256` to refuse
any other version, or `COMMUNITY_SCRIPT_URL` for a reviewed copy. The checksum
covers `ct/comfyui.sh` only: that script loads the shared `build.func` and
`install/comfyui-install.sh`, which install the **latest** ComfyUI release
without verifying it. Run `install-target.sh --upgrade` afterwards to move to
the release pinned here, verified by commit.

**Exposure window.** The community install starts ComfyUI as root on all
addresses before this script writes the firewall (seconds to minutes). Create
the CT on a trusted segment.

## Adoption (`install-target.sh`)

Inside the CT (`pct enter <CT_ID>`), from `/root/comfyui-target-deploy`; safe to
re-run:

* creates the `comfyui` system account (in the `video` and `render` groups) and
  `/etc/comfyui-target/comfyui.env` (an existing one is kept);
* copies the venv's Python out of `/root/.local/share/uv/python` into
  `/opt/comfyui-target/python` and points the venv at the copy, since the
  service account cannot enter `/root` (offline: nothing is reinstalled);
* points `/opt/comfyui-target/current` at `/opt/ComfyUI`;
* brings the community tree's data into `/var/lib/comfyui-target`: model files
  are moved, everything else (model configs, the example input and custom
  node, the settings database) is copied; nothing there is replaced;
* installs the drop-in, restarts `comfyui.service` and waits for
  `/system_stats` (`READY_TIMEOUT`, 300 s), then reports the torch device.

## Open WebUI image settings (`integrate-webui.py`)

It reads `GET /api/v1/images/config`, changes the ComfyUI fields and writes
the whole set back with `POST /api/v1/images/config/update`, so every other
image setting is kept:

* engine `comfyui`, base URL `http://<CT address>:8188`;
* the selected API-format distilled Klein workflow in
  `flux2-klein-{4b,9b}-api.json`, with prompt → node 4, diffusion model → 1,
  width and height → 6 and 7,
  batch size → 6, steps → 7, seed → 8. The graph uses a four-step
  Flux2Scheduler, Euler sampler and CFG 1. An admin's custom workflow and its
  settings are kept;
* the selected diffusion model (or `COMFYUI_IMAGE_MODEL`), plus its matching
  Qwen text encoder and Flux.2 VAE below. Generation stays **off** until
  ComfyUI lists all three assets;
* `COMFYUI_IMAGE_SIZE` and `COMFYUI_IMAGE_STEPS`, when given (otherwise
  1024x1024 and 4 steps for the distilled model).

Then it asks Open WebUI's backend to verify the URL
(`POST /api/v1/images/verify` from Open WebUI 0.11.4, falling back to
`/api/v1/images/config/url/verify` on older releases) and to list the
diffusion models. That proves
the router CT can reach ComfyUI through the firewall. On failure the previous
image settings are restored and the run fails.

The bundled graphs are API-format adaptations of ComfyUI's [official Klein
text-to-image template](https://docs.comfy.org/tutorials/flux/flux-2-klein).
For a workflow exported from your own ComfyUI build, load that template in
ComfyUI, choose the selected **distilled** diffusion model, set four steps and
CFG 1, then use **Export (API)**. In Open WebUI's Admin Settings
> Images, upload the exported JSON and map prompt, model, width, height,
steps, batch size, and seed to the corresponding node inputs. This becomes a
custom workflow, so future integration runs preserve it. Open WebUI (0.11.0
through the pinned 0.12.4) expects ComfyUI's legacy model-list format; the integration checks its model
picker and restores the previous settings if the selected model does not
appear.

## Weights

`install-target.sh` downloads the files of `COMFYUI_IMAGE_VARIANT` listed in
`klein-weights.txt`:

* **Checked first:** every URL answers (HEAD, with the token for the gated
  file) with the size in the manifest, and the CT has room for what is missing
  plus 2 GB; otherwise nothing is downloaded and the run says how to grow the
  disk (`pct resize <CT_ID> rootfs +<N>G`).
* **Verified:** each file must match its SHA-256 in the manifest; a mismatching
  download is deleted. The gated 9B diffusion model's hash is only shown to
  accounts that accepted its license, so it is checked against the SHA-256
  Hugging Face sends for the authenticated request (`X-Linked-Etag`) and the
  pinned size; set `COMFYUI_KLEIN_9B_SHA256` to pin it once you have reviewed it.
* **Resumed:** an interrupted download continues where it stopped, within the
  run (five attempts) and on a rerun. Verified files are recorded in
  `/etc/comfyui-target/verified-weights`, so a rerun does not hash many GB
  again; a file that is there but does not match is refused, never replaced.
* **The token** is read from `HF_TOKEN_FILE` (or `HF_TOKEN`) into a root-only
  header file that curl reads (`-H @file`), so it is never on a command line;
  curl does not send it on to the CDN Hugging Face redirects to. curl runs as
  root, and every file operation in `/var/lib/comfyui-target` runs as
  `comfyui`, so the service account never sees the token and root never
  follows a link in a directory the service can write.

To add or change a variant later, in the CT:

```bash
COMFYUI_IMAGE_VARIANT=klein-4b bash /root/comfyui-target-deploy/install-target.sh
COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN_FILE=/root/hf-token bash /root/comfyui-target-deploy/install-target.sh
```

then rerun `provision-lxc.sh --integrate-only` with that `COMFYUI_IMAGE_VARIANT`.
The files, in `/var/lib/comfyui-target/models/`:

| Variant | File | Directory under `/var/lib/comfyui-target/models/` |
| --- | --- | --- |
| 4B | [`flux-2-klein-4b-fp8.safetensors`](https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8/resolve/main/flux-2-klein-4b-fp8.safetensors) | `diffusion_models/` |
| 4B | [`qwen_3_4b.safetensors`](https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors) | `text_encoders/` |
| 4B | [`flux2-vae.safetensors`](https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/main/split_files/vae/flux2-vae.safetensors) | `vae/` |
| 9B | [`flux-2-klein-9b-fp8.safetensors`](https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8/resolve/main/flux-2-klein-9b-fp8.safetensors) | `diffusion_models/` |
| 9B | [`qwen_3_8b_fp8mixed.safetensors`](https://huggingface.co/Comfy-Org/flux2-klein-9B/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors) | `text_encoders/` |
| 9B | [`flux2-vae.safetensors`](https://huggingface.co/Comfy-Org/flux2-klein-9B/resolve/main/split_files/vae/flux2-vae.safetensors) | `vae/` |

Both variants use the same VAE file; installing the second variant downloads
only its diffusion model and text encoder. Users get image generation according to their Open WebUI permissions (Admin
Settings > Users > Groups). Image editing needs a separate workflow and is not
enabled here.

## Operate

```bash
systemctl status comfyui
journalctl -u comfyui -f
curl -s http://127.0.0.1:8188/system_stats          # version, device, VRAM
nvidia-smi                                            # NVIDIA: is the GPU visible?
```

* **Models** go in `/var/lib/comfyui-target/models/<folder>` (`vae`,
  `diffusion_models`, `text_encoders`, ...), owned by `comfyui`; ComfyUI lists
  new files without a restart. The Klein weights are installed as described in
  [Weights](#weights); after adding others, rerun `provision-lxc.sh --integrate-only`.
  `COMFYUI_MODEL_URL=<https URL> COMFYUI_MODEL_SHA256=<hex> bash install-target.sh`
  downloads one as the service account and checks it.
* **Outputs** stay in `/var/lib/comfyui-target/output`; Open WebUI keeps its
  own copy of each image it shows.
* **Settings** are in `/etc/comfyui-target/comfyui.env`: `COMFYUI_EXTRA_ARGS`
  takes further ComfyUI options (`--lowvram`, `--reserve-vram 1.0`,
  `--preview-method auto`). Changing `COMFYUI_PORT` also needs the firewall
  rule and Open WebUI's URL changed (`--integrate-only` does the latter).
* **The web UI** (`http://<CT address>:8188`) is reachable from the addresses
  in `UI_ALLOW_CIDR` only. Add one later as another rule in
  `/etc/pve/firewall/<CT_ID>.fw`.
* **Custom nodes** go in `/var/lib/comfyui-target/custom_nodes`. The service
  cannot write its venv, so a node (or ComfyUI-Manager) cannot install its own
  Python packages: install them as root with
  `uv pip install --python /opt/comfyui-target/current/venv/bin/python -r <node>/requirements.txt`.
  A later `--upgrade` builds a fresh venv without them. Only install nodes you
  trust: they run arbitrary code.

## Upgrade

```bash
bash /root/comfyui-target-deploy/install-target.sh --upgrade        # the release pinned here (v0.42.1)
COMFYUI_VERSION=v0.42.5 COMFYUI_COMMIT=<reviewed sha1> bash install-target.sh --upgrade
```

When the running release is the requested commit, the drop-in is unchanged and
ComfyUI answers as that version (or the service is stopped), `--upgrade` prints
"nothing to do". Otherwise:

1. **Prepare** while the current release keeps running: install `git` if
   needed, `git clone --depth 1 --branch <tag>`, refuse it unless `HEAD` is
   `COMFYUI_COMMIT` and `comfyui_version.py` matches the tag, then build a new
   venv with the same Python and PyTorch build as the current release
   (`torch-<ver>+cu130` → the cu130 index; `COMFYUI_TORCH` overrides) plus
   `requirements.txt`, and check that it imports. Any failure here leaves
   ComfyUI as it was.
2. **Switch:** stop the service, point `/opt/comfyui-target/current` at the
   new release (one rename) and start it.
3. **Check:** it must answer `/system_stats` as the new version within
   `UPGRADE_HEALTH_TIMEOUT` (300 s).
4. **Rollback** otherwise: `current` goes back to the previous release (and the
   drop-in, if this repository's copy had changed), the service is restarted
   and checked to answer again; the run reports "running again" or that the
   previous release "did not answer either", and exits non-zero.

A service that was stopped stays stopped. After a success the previous release
is kept for a manual rollback (`ln -sfn <dir> /opt/comfyui-target/current`,
then restart); older builds are deleted, and once the community tree is no
longer the previous release, its venv is removed. The venv is rebuilt from
`requirements.txt` without a hash lock, as upstream installs it, so versions
of unpinned dependencies can differ between builds.

## Security notes

* ComfyUI has no authentication: anyone who reaches port 8188 can queue
  workflows, read every output and upload files. The CT firewall is the access
  control; keep `UI_ALLOW_CIDR` narrow.
* Workflows and custom nodes are code. The service runs unprivileged, cannot
  write its code or venv, and sees only `/var/lib/comfyui-target`, but it does
  have network access.
* Open WebUI sends an empty `Authorization` bearer token; ComfyUI ignores it.
