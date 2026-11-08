# ComfyUI image generation target

[ComfyUI](https://github.com/Comfy-Org/ComfyUI) in its own CT, used by the
router's Open WebUI as its **image generation engine** (the image button in
chats and image requests through Open WebUI's API). It is not a model server:
chat routing never sends requests to it. The CT and first install come from
the Proxmox VE community script
[`ct/comfyui.sh`](https://community-scripts.org/scripts/comfyui); this target
presets it, adopts the result with a systemd drop-in
(`/etc/systemd/system/comfyui.service.d/10-comfyui-target.conf`, so the
community unit is never edited) and connects it to Open WebUI.

```
Open WebUI (router CT) --HTTP + WebSocket :8188--> comfyui.service (this CT) --> GPU
```

| | Community script alone | After `provision-lxc.sh` |
| --- | --- | --- |
| Service account | root | `comfyui` (unprivileged), video/render groups |
| Code | `/opt/ComfyUI` (latest release, unverified) | `/opt/comfyui-target/current` → that tree, then pinned, commit-verified releases |
| Python | uv's 3.12 under `/root/.local/share/uv` | A copy in `/opt/comfyui-target/python` the service can run |
| Models, nodes, outputs, user data | Inside `/opt/ComfyUI` | `/var/lib/comfyui-target` (`--base-directory`) |
| Settings | The unit's `ExecStart` | `/etc/comfyui-target/comfyui.env` (0640) |
| Network | 8188 open to all, no authentication | CT firewall: 8188 from the router (and `UI_ALLOW_CIDR`) only |
| Hardening | None | `ProtectSystem=strict`, no capabilities, only `/var/lib/comfyui-target` writable |
| Upgrades | `update` says "use ComfyUI-Manager" | `install-target.sh --upgrade` (pinned tag and commit, built beside the running release, rollback) |
| Open WebUI | — | Admin Settings > Images: engine ComfyUI, its URL, the selected Klein API workflow |

| File | Purpose |
| --- | --- |
| `provision-lxc.sh` | PVE host: community script with presets, CT firewall, adoption, Open WebUI registration |
| `install-target.sh` | In the CT: adopts (re-runnable), downloads the Klein weights, `--upgrade` |
| `klein-weights.txt` | Each Klein variant's files: folder, name, size, SHA-256, access, URL |
| `comfyui-target.conf`, `comfyui.env.example` | The drop-in; listen address, port, extra options |
| `integrate-webui.py`, `flux2-klein-{4b,9b}-api.json` | Run in the router CT: set ComfyUI and the selected workflow in Open WebUI |
| `test-install.sh`, `test-provision.sh`, `test-integration.py` | Stubbed tests and mock servers; nothing downloaded or created |

## Provision

From the repository checkout on the PVE host (the router installer does the
same when **comfyui** is selected):

```bash
bash targets/comfyui/provision-lxc.sh                                  # klein-4b
COMFYUI_IMAGE_VARIANT=klein-9b bash targets/comfyui/provision-lxc.sh   # asks for a Hugging Face token (or HF_TOKEN)
```

It prompts for IP/CIDR (or `dhcp`), gateway and the router's Open WebUI CT ID
or IP (preset `IP_CIDR`, `GATEWAY`, `ROUTER`, `TEMPLATE_STORAGE`, `STORAGE`); no
address is chosen automatically. The CT ID defaults to the cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID` to choose another). Then:

1. **Checks first.** Settings, the router's Open WebUI (`/health`,
   `/api/version`), the admin key (prompted without echo unless
   `OPENWEBUI_ADMIN_TOKEN` is set) and the weights (every URL answers; for
   `klein-9b` the token is accepted for the gated file), before anything is
   created.
2. **Community script** with `var_*` presets, including `var_comfyui_gpu_type`
   for its GPU menu; it still shows its menu: choose **Default**. It takes a
   while (CUDA PyTorch is several GB). Defaults: 4 cores, **16 GB RAM, 64 GB
   disk** (each release's venv is 6–10 GB; the 4B weights 12.5 GB, the 9B
   18.4 GB).
3. **Firewall.** `/etc/pve/firewall/<id>.fw` drops all inbound except TCP 8188
   from the router's address (`ip route get` on the router, or `ROUTER_IP`) and
   `UI_ALLOW_CIDR`; `net0` gets `firewall=1`. An existing file is never
   replaced. Rules apply only with the datacenter firewall enabled (warned).
4. **Adoption and weights** (below). For `klein-9b` the token is pushed into
   the CT as a 0600 file for this step only and removed afterwards, also on
   failure.
5. **Open WebUI.** `integrate-webui.py` runs in the router CT from a 0700
   staging directory that is removed afterwards.

| Variant | Why | License and access |
| --- | --- | --- |
| `klein-4b` (default) | Smaller model and encoder; ~13 GB VRAM (Black Forest Labs estimate) | [Apache 2.0, open](https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8) |
| `klein-9b` | Larger; ~29 GB VRAM | [FLUX Non-Commercial License](https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8): accept the conditions on the model page, then create a read token (Settings > Access Tokens) |

The variant selects the weights and the matching workflow, so generation works
when the run ends. The token reaches only the ComfyUI provisioner. Directly,
`COMFYUI_IMAGE_VARIANT` defaults to `klein-4b`; with `--integrate-only`,
`auto` keeps Open WebUI's current Klein workflow, else uses the variant whose
files ComfyUI has (4B first). `COMFYUI_DOWNLOAD_WEIGHTS=0` skips downloads.

**GPU.** `GPU=auto` (default) uses NVIDIA when the host has `/dev/nvidia0`. If
the CT's NVML or `libcuda.so.1` then mismatches the host driver, provisioning
stops the service, confirms the CT sees the host's driver version, purges
Debian NVIDIA packages (including `nvidia-installer-cleanup`, which blocks the
`.run` installer; the CUDA keyring is kept), installs the host release's
user-space and verifies both before adoption. The community install's CUDA 13
PyTorch needs driver 580+. `GPU=amd`/`intel` pass `/dev/dri` (and `/dev/kfd`)
and install ROCm or XPU PyTorch; `GPU=none` runs `--cpu` (minutes per image).
`GPU_CARD=<PCI address>` picks one card: the CT keeps only its nodes plus the
shared ones (`/dev/kfd`, `/dev/nvidiactl`, `/dev/nvidia-uvm*`) and is
restarted before the firewall and guest install. The router installer passes
`GPU` and `GPU_CARD` after `tools/setup-host-gpu.sh`; run that tool yourself
before a direct run on an unprepared host.

**Modes.** `--dry-run` touches nothing (no Proxmox, router or token).
`--integrate-only` (with `CT_ID`) re-registers an existing CT, e.g. after
adding Klein assets or rebuilding the router (pass the original
`COMFYUI_IMAGE_VARIANT` when Open WebUI was rebuilt). `--no-webui` skips Open
WebUI; set `UI_ALLOW_CIDR` (or `FIREWALL=0`) so someone can reach it. To resume
an interrupted guest install, run `install-target.sh` in the CT.

**Community script.** It comes from `main` and can change; the wrapper prints
its SHA-256 (`COMMUNITY_SCRIPT_SHA256` pins it, `COMMUNITY_SCRIPT_URL` uses a
reviewed copy). The checksum covers `ct/comfyui.sh` only, which installs the
**latest** ComfyUI unverified: run `install-target.sh --upgrade` to move to the
pinned, commit-verified release once that is newer (a newer community install
is kept, see [Upgrade](#upgrade)). **Exposure window:** the community install
starts ComfyUI as root on all addresses before the firewall is written, so
create the CT on a trusted segment.

## Adoption (`install-target.sh`)

In the CT, from `/root/comfyui-target-deploy` (re-runnable): creates the
`comfyui` account (groups `video`, `render`) and `comfyui.env` (an existing one
is kept); copies the venv's Python out of `/root/.local/share/uv/python` into
`/opt/comfyui-target/python` and points the venv at it, offline; points
`/opt/comfyui-target/current` at `/opt/ComfyUI`; moves model files and copies
other data (model configs, example input and node, settings database) into
`/var/lib/comfyui-target` without replacing anything; installs the drop-in,
restarts the service, waits for `/system_stats` (`READY_TIMEOUT`, 300 s) and
reports the torch device.

## Open WebUI image settings (`integrate-webui.py`)

It reads `GET /api/v1/images/config`, changes only the ComfyUI fields and
writes the full set back (`POST /api/v1/images/config/update`):

* engine `comfyui`, base URL `http://<CT address>:8188`;
* the selected distilled Klein API workflow (`flux2-klein-{4b,9b}-api.json`:
  prompt → node 4, model → 1, width/height → 6/7, batch size → 6, steps → 7,
  seed → 8; four-step Flux2Scheduler, Euler, CFG 1). An admin's custom
  workflow and its settings are kept;
* the diffusion model (or `COMFYUI_IMAGE_MODEL`) with its Qwen text encoder
  and Flux.2 VAE; generation stays **off** until ComfyUI lists all three;
* `COMFYUI_IMAGE_SIZE` and `COMFYUI_IMAGE_STEPS` when given (else 1024x1024 and
  4 steps).

Open WebUI's backend then verifies the URL (`POST /api/v1/images/verify` from
0.11.4, else `/api/v1/images/config/url/verify`) and lists the models, which
proves the router reaches ComfyUI through the firewall; on failure the previous
settings are restored and the run fails. Open WebUI 0.11.0 through the pinned
0.12.4 expects ComfyUI's legacy model-list format, so the integration checks
the model picker too. Rerun it after an Open WebUI upgrade only if image
settings must change; it handles both verify endpoints.

The bundled graphs adapt ComfyUI's
[official Klein text-to-image template](https://docs.comfy.org/tutorials/flux/flux-2-klein).
For your own export: load the template, choose the **distilled** model, four
steps and CFG 1, **Export (API)**, upload it under Admin Settings > Images and
map prompt, model, width, height, steps, batch size and seed; integration runs
then keep it as a custom workflow.

## Weights

`install-target.sh` downloads the `COMFYUI_IMAGE_VARIANT` files listed in
`klein-weights.txt`:

* **Checked first:** every URL answers (HEAD, with the token for the gated
  file) with the manifest size, and the disk has room for what is missing plus
  2 GB; otherwise nothing is downloaded and the run explains
  `pct resize <id> rootfs +<N>G`.
* **Verified** against the manifest's SHA-256 (mismatches deleted). The gated
  9B model's hash is visible only to accounts that accepted its license, so it
  is checked against the hash Hugging Face sends for the authenticated request
  (`X-Linked-Etag`) and the pinned size; `COMFYUI_KLEIN_9B_SHA256` pins it once
  reviewed.
* **Resumed** within the run (five attempts) and on reruns. Verified files are
  recorded in `/etc/comfyui-target/verified-weights`; a present but mismatching
  file is refused, never replaced.
* **Token** from `HF_TOKEN_FILE` (or `HF_TOKEN`) goes into a root-only curl
  header file (`-H @file`), never argv, and is not forwarded to the CDN. curl
  runs as root while every file operation in `/var/lib/comfyui-target` runs as
  `comfyui`, so the service never sees the token and root never follows links
  in a service-writable directory.

| Variant | File | Under `/var/lib/comfyui-target/models/` |
| --- | --- | --- |
| 4B | [`flux-2-klein-4b-fp8.safetensors`](https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8/resolve/main/flux-2-klein-4b-fp8.safetensors) | `diffusion_models/` |
| 4B | [`qwen_3_4b.safetensors`](https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors) | `text_encoders/` |
| 4B | [`flux2-vae.safetensors`](https://huggingface.co/Comfy-Org/Flux-2-Klein-4B/resolve/main/split_files/vae/flux2-vae.safetensors) | `vae/` |
| 9B | [`flux-2-klein-9b-fp8.safetensors`](https://huggingface.co/black-forest-labs/FLUX.2-klein-9b-fp8/resolve/main/flux-2-klein-9b-fp8.safetensors) | `diffusion_models/` |
| 9B | [`qwen_3_8b_fp8mixed.safetensors`](https://huggingface.co/Comfy-Org/flux2-klein-9B/resolve/main/split_files/text_encoders/qwen_3_8b_fp8mixed.safetensors) | `text_encoders/` |
| 9B | [`flux2-vae.safetensors`](https://huggingface.co/Comfy-Org/flux2-klein-9B/resolve/main/split_files/vae/flux2-vae.safetensors) | `vae/` |

Both variants share the VAE. To add or switch a variant, in the CT, then rerun
`provision-lxc.sh --integrate-only` with that variant:

```bash
COMFYUI_IMAGE_VARIANT=klein-4b bash /root/comfyui-target-deploy/install-target.sh
COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN_FILE=/root/hf-token bash /root/comfyui-target-deploy/install-target.sh
```

Users get image generation per their Open WebUI permissions (Admin Settings >
Users > Groups). Image editing needs a separate workflow and is not enabled.

## Operate

```bash
systemctl status comfyui
journalctl -u comfyui -f
curl -s http://127.0.0.1:8188/system_stats    # version, device, VRAM
nvidia-smi                                      # NVIDIA: GPU visible?
```

* **Models** go in `/var/lib/comfyui-target/models/<folder>` (owned by
  `comfyui`; listed without restart); rerun `--integrate-only` after adding
  some. `COMFYUI_MODEL_URL=<https URL> COMFYUI_MODEL_SHA256=<hex> bash
  install-target.sh` downloads and checks one as the service account.
* **Outputs** stay in `/var/lib/comfyui-target/output` (Open WebUI keeps its
  own copy of each image).
* **Settings** in `comfyui.env`: `COMFYUI_EXTRA_ARGS` (e.g.
  `--preview-method auto`). Changing `COMFYUI_PORT` also needs the firewall rule
  and Open WebUI's URL updated (`--integrate-only` does the latter).
* **Web UI** (`http://<CT address>:8188`) only from `UI_ALLOW_CIDR`; add more
  sources as rules in `/etc/pve/firewall/<id>.fw`.
* **Custom nodes** go in `/var/lib/comfyui-target/custom_nodes`. The service
  cannot write its venv, so install their packages as root with
  `uv pip install --python /opt/comfyui-target/current/venv/bin/python -r <node>/requirements.txt`
  (`/opt/comfyui-target/uv/bin/uv` when `--upgrade` had to install uv);
  `--upgrade` builds a fresh venv without them. Nodes run arbitrary code:
  install only trusted ones.

**GPU memory.** `VRAM grow failed` (from `comfy_aimdo`) is a failed GPU
allocation. Klein 4B needs ~13 GB, leaving little on a 16 GB card: stop ComfyUI
and check `nvidia-smi` on the host for other users of the shared GPU. If it
still fails with the GPU to itself, set `COMFYUI_EXTRA_ARGS=--disable-dynamic-vram
--lowvram` and restart (`--lowvram` alone does nothing while DynamicVRAM is on;
together they move the text encoder to CPU and use system RAM, so watch RAM and
swap). See the
[ComfyUI startup flags](https://github.com/Comfy-Org/docs/blob/main/development/comfyui-server/startup-flags.mdx).

## Upgrade

```bash
bash /root/comfyui-target-deploy/install-target.sh --upgrade        # the pinned release (v0.42.1)
COMFYUI_VERSION=v0.42.5 COMFYUI_COMMIT=<reviewed sha1> bash install-target.sh --upgrade
```

If the running release is the requested commit, the drop-in is unchanged and
ComfyUI answers as that version (or is stopped), it prints "nothing to do".
It never downgrades by itself: when the running release is newer than the pin
(the community script installs the newest), it is kept, and only a changed
drop-in is installed (with a restart, and the old drop-in back if ComfyUI then
does not answer). Set `COMFYUI_VERSION` and `COMFYUI_COMMIT` to move to an
older release on purpose.
Otherwise:

1. **Prepare** while the current release runs: `git clone --depth 1 --branch
   <tag>`, refuse unless `HEAD` is `COMFYUI_COMMIT` and `comfyui_version.py`
   matches, build a venv with the current Python and PyTorch build
   (`torch-<ver>+cu130` → the cu130 index; `COMFYUI_TORCH` overrides) plus
   `requirements.txt`, and check it imports. A failure leaves ComfyUI as it was.
   The build uses uv from `PATH`, `/usr/local/bin`, `/root/.local/bin` or
   `/root/.cargo/bin`; without one it installs a pinned uv from PyPI
   (wheel hashes checked) into `/opt/comfyui-target/uv` with the current
   Python, and uses that one from then on.
2. **Switch:** stop, repoint `/opt/comfyui-target/current` (one rename), start.
3. **Check** `/system_stats` reports the new version within
   `UPGRADE_HEALTH_TIMEOUT` (300 s).
4. **Rollback** otherwise: `current` (and a changed drop-in) go back, the
   service restarts and the run reports "running again" or "did not answer
   either", exiting non-zero.

A stopped service stays stopped. After success the previous release is kept
for manual rollback (`ln -sfn <dir> /opt/comfyui-target/current`, then
restart); older builds are deleted, and the community tree's venv once it is no
longer the previous release. The venv is built from `requirements.txt` without
a hash lock, as upstream does, so unpinned dependency versions can differ.

## Security notes

* No authentication: anyone reaching 8188 can queue workflows, read outputs and
  upload files. The CT firewall is the access control; keep `UI_ALLOW_CIDR`
  narrow.
* Workflows and custom nodes are code. The service runs unprivileged, cannot
  write its code or venv and sees only `/var/lib/comfyui-target`, but has
  network access.
* Open WebUI sends an empty bearer token, which ComfyUI ignores.
