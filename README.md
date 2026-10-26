# Ollama Smart Router — Setup & Operations

A Proxmox LXC that puts one OpenAI-compatible endpoint in front of a pool of
self-hosted model servers. It routes each request by complexity, spreads load,
serves a chat UI and alerts on host health. Design and rationale are in
[ARCHITECTURE.md](ARCHITECTURE.md); test details are in [tests/README.md](tests/README.md).

## What gets deployed

An unprivileged Debian 13 CT (default 2 vCPU, 4 GB RAM, 32 GB disk) running
four hardened systemd services as the `ollama-router` user:

| Service | Unit | Port | Role |
|---|---|---|---|
| Smart Router | `ollama-router.service` | 8000 | OpenAI API; picks a model and host per request |
| Open WebUI | `open-webui.service` | 8080 | Chat UI; talks to the router |
| LiteLLM | `litellm-proxy.service` | 127.0.0.1:4000 | Static tier fallback and non-chat `/v1` routes |
| Health monitor | `ollama-monitor.service` | — | Probes hosts and local services, alerts to Mattermost, keeps models loaded |

Normal request path: **client or Open WebUI → router :8000 → model host**.
LiteLLM is used only when discovery is off or no host answers.

The model pool can mix Ollama, LM Studio, Strata, Basalt, Project Maya and
Xolotl servers. `targets/` provisions such servers in their own CTs (see
[Inference targets](#inference-targets)), plus optional
[Gitea](targets/gitea/README.md) and [Mattermost](targets/mattermost/README.md)
service LXCs and [Open Terminal](targets/open-terminal/README.md),
[Hermes Agent](targets/hermes/README.md) and [ComfyUI](targets/comfyui/README.md)
(image generation) companion LXCs.

## Install

Gitea keeps the router's configuration history, and Mattermost receives its
health alerts. Both are optional. If you do not run them yet, the installer can
create each one in its own LXC at the start of the install, already set up for
the router. You can also create them first with
[`targets/gitea`](targets/gitea/README.md) and
[`targets/mattermost`](targets/mattermost/README.md).

Run as root on the Proxmox host:

```bash
bash ollama-smart-router-install.sh
```

It first asks which [targets](#inference-targets) to create alongside the
router, from a numbered menu:
- the services `gitea` and `mattermost`;
- the model servers `ollama`, `llamacpp`, `airllm`, `strata`, `basalt`,
  `maya` and `xolotl`;
- the companions `open-terminal`, `hermes` and `comfyui`.

Answer with numbers or names, comma-separated, or Enter for none.

For each selected target, it asks up front, with the other settings:
- a CT ID (the next free one after the router's);
- a static IP/CIDR (the router needs a fixed address);
- a storage (default: the router's);
- for Strata, Basalt, Maya and Xolotl, a template. The default is the newest
  downloaded Debian 13 template, then Ubuntu 26.04 (not for Strata), Ubuntu
  24.04, Ubuntu 22.04 and Debian 12; with none downloaded, a Debian 13 template
  is downloaded. Maya on a card CUDA 13 cannot build for (compute capability
  below 7.5, e.g. a V100) defaults to Ubuntu 24.04 instead. Basalt, Maya and
  Xolotl get CUDA 13.1 on Debian 13 and 13.3 on Ubuntu 26.04 (the first
  releases those NVIDIA repositories carry) unless you set their CUDA version.

### LXC distribution support

Debian 13 and Ubuntu 26.04 are preferred wherever the target's upstream
supports them; the older releases stay available where it does not.

| LXC | Default | Also supported |
|---|---|---|
| Router, Gitea, ComfyUI | Debian 13 | |
| Open Terminal, Hermes Agent | Debian 13 (the router's template) | Debian 12 |
| Ollama (community script) | Debian 13 | Debian 12; Ubuntu 22.04, 24.04, 26.04 (`OLLAMA_CT_OS`, `OLLAMA_CT_VERSION`) |
| Mattermost (community script) | Ubuntu 26.04 | Ubuntu 22.04, 24.04 (`MATTERMOST_CT_VERSION`); Mattermost publishes for Ubuntu only |
| AirLLM | chosen at its prompt | Debian 12 or 13; Ubuntu 24.04 or 26.04 (Python 3.11+) |
| llama.cpp | Debian 13 listed first | CUDA or CPU: Debian 12 or 13; Vulkan: Debian 13 |
| Basalt, Maya, Xolotl | Debian 13 | Ubuntu 26.04, 24.04, 22.04; Debian 12 |
| Strata | Debian 13 | Ubuntu 24.04, 22.04; Debian 12 (not 26.04: its setup installs CUDA only on these) |

What each release brings in:

| | Debian 12 | Debian 13 | Ubuntu 22.04 | Ubuntu 24.04 | Ubuntu 26.04 |
|---|---|---|---|---|---|
| Python (venvs) | 3.11 | 3.13 | 3.10 | 3.12 | 3.14 |
| GCC (nvcc's host compiler) | 12 | 14 | 11 | 13 | 15 |
| First CUDA in NVIDIA's repository | 12.3 | **13.1** | 11.7 | 12.5 | **13.3** |
| Default CUDA: Basalt and Xolotl / Maya | 13.0 / 12.8 | 13.1 / 13.1 | 13.0 / 12.8 | 13.0 / 12.8 | 13.3 / 13.3 |
| CUDA used by llama.cpp | 13.0 | 13.1 | | | |

Every pinned Python requirement has wheels for these Pythons: Basalt's,
Xolotl's and Strata's for 3.10 through 3.14, AirLLM's hash lock for 3.11
through 3.14 (it requires 3.11, so no Ubuntu 22.04); Maya installs current
releases.
Strata's ready-made engine loads CUDA 13.0 from NVIDIA's pip packages, so it
needs no toolkit. The host keeps the bundled NVIDIA 580.173.02 driver, and the
CT's user-space libraries must match it on every release. CUDA 13.1 and 13.3
run on it under NVIDIA's
[minor version compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html):
the engines are built for the card's own architecture, as that requires, but
a feature that needs a newer driver can still fail
(`cudaErrorCallRequiresNewerDriver`). CUDA 13.3 is the release NVIDIA pairs
with the 610 driver, which is why Debian 13 (13.1) is the default. CUDA 13
cannot build for a V100; use Ubuntu 22.04/24.04 or Debian 12 for Maya on that
card. Ubuntu 26.04 needs Proxmox's ubuntu-26.04 template (`pveam update`, then
`pveam available`) and a current `pve-container`.

**The host's GPU driver comes next,** when GPU targets are selected. All the
selected targets share one GPU vendor:

| Target | GPU |
|---|---|
| Strata, Maya, Xolotl | NVIDIA, required |
| Basalt | NVIDIA RTX 50, required |
| llama.cpp | required unless `BACKEND=cpu`: NVIDIA (CUDA) or AMD Radeon / Intel Arc (Vulkan, on a Debian 13 CT) |
| AirLLM | NVIDIA, only when `GPU_DEVICES` is set |
| Ollama, ComfyUI | NVIDIA, AMD Radeon or Intel Arc, used when present |

If a suitable GPU already works (`nvidia-smi` lists one, or an AMD/Intel card is
bound to its driver with its render node), the installer just reports it.
Otherwise [`tools/setup-host-gpu.sh`](tools/setup-host-gpu.sh) lists the cards on
the PCI bus and asks which generation the card is, suggesting it from the
card's ID: `rtx20`-`rtx50` (GeForce RTX 20-50), `rdna3` (Radeon RX 7000, PRO
W7000), `rdna4` (Radeon RX 9000, AI PRO R9700), `arc-a` or `arc-b` (Intel Arc
A/B). Once you agree, it sets the driver up: for NVIDIA it installs the
repository's NVIDIA 580.173.02 driver (open kernel modules, DKMS, loaded at
every boot with the `/dev/nvidia*` nodes the CTs pass through); for AMD and
Intel, whose drivers are part of the Proxmox kernel, it installs `pve-firmware`
when the card's firmware is missing and loads `amdgpu`, `i915` or `xe` now and
at every boot (Arc B needs Linux 6.12+). A driver blacklisted in
`/etc/modprobe.d` (often for VM passthrough) or a card bound to `vfio-pci` is
reported, not changed. Unattended: `GPU_GENERATION=rtx40` (or `7900`, `9070`,
`A770`, `B580`) `INSTALL_HOST_DRIVER=yes`. Without a GPU, targets that need one
stop the install before anything is created, and Ollama and ComfyUI go on
CPU-only. If the card needs a reboot (nouveau still holds it, or new firmware),
reboot and run the installer again; nothing else was created. The installer
then hands the result on: `GPU=<vendor>` to Ollama and ComfyUI, and
`BACKEND=cuda` or `BACKEND=vulkan` with the render node as `GPU_DEVICES` to
llama.cpp, unless you set them. A GPU target's `provision-lxc.sh` run by hand
on a host without a driver points to the same tool.

**Services are created right away,** after the network and storage prompts and
before anything for the router is built. Each runs its target's community
script (choose **Default** in its menu), then is set up inside its CT without
the browser:
- **Gitea:** a locked `app.ini` with registration off, an administrator, and a
  non-admin router account with a scoped token.
- **Mattermost:** an administrator, the `ollama` team, the `ollama-monitor`
  channel and an incoming webhook.

The installer then reads Gitea's URL, router account and token, and
Mattermost's webhook URL, from the CTs. They become the defaults of the Gitea
and Mattermost prompts, which still verify them. The administrator passwords
stay in each CT, in `/etc/<service>-target/admin-password`. A service that
fails stops the install before the router is built; its CT is kept for
`--reconfigure`.

The selected model targets become servers 1…n of the model-server prompt, so
they get tiers like any other server. Raise the count to keep existing servers
too.

After the router is running:
1. Each model target's `provision-lxc.sh` runs in turn, with its own CT
   settings:
   - Ollama and AirLLM include their guest install.
   - llama.cpp includes it only when `MODEL_ALIAS` plus `MODEL_DOWNLOAD_URL` or
     `MODEL_PATH` are set; otherwise only the CT is made.
   - Strata, Basalt, Maya and Xolotl generate keys, which are handed to the router with
     `set-<kind>-token` on stdin, followed by one `apply`.
2. The installer waits for Open WebUI and asks once for an admin API key: create
   the admin account in the browser, enable API keys, and create one. It then
   runs Open Terminal, Hermes and ComfyUI against the router CT. ComfyUI's
   community script shows its own menu (choose **Default**) and takes a while.

Target-specific settings (`GPU_DEVICES`, `STRATA_MODEL`, `OLLAMA_PULL_MODELS`,
`HERMES_MODEL`, `COMFYUI_MODEL_URL`, …) come from the environment, as each target's README describes;
so do `GPU_GENERATION` and `INSTALL_HOST_DRIVER` for the host driver step, and
`BACKEND` (llama.cpp: `cuda`, `vulkan` or `cpu`) and `GPU` (Ollama and ComfyUI:
`nvidia`, `amd`, `intel` or `none`).
The router's own `CT_ID`, `IP_CIDR`, `CORES`, `ROOTFS_GB` and similar settings
never reach a target. A failed target leaves the router as it is. The run ends
with a summary of every target and how to retry it, and exits non-zero if any
target failed. The router monitor reports each configured but absent model host
as down after three failed checks and posts one down alert for it, retried
every cycle until Mattermost accepts it. Once the host is ready, two passing
checks send a recovery notice. (Both counts are defaults, set in
`monitor.ini` `[alerting]`.)

The monitor's startup notice is limited to one per hour; that limit does not
delay host alerts.

It then prompts for the CT root password, network (bridge, IP/CIDR, gateway, DNS),
rootfs size and storage, Gitea URL/user/repo/token, Mattermost webhook
(blank disables alerts), and the model servers (1–20), their tiers and the
model tag per tier. Every prompt has a default and re-prompts on bad input.
Everything is validated before `pct create`, and a failed run destroys the
half-built CT.

Settings can be preset as environment variables (`NONINTERACTIVE=true` takes
all defaults and skips the prompts):

| Area | Variables (default) |
|---|---|
| CT | `CT_ID`, `CT_NAME`, `IP_CIDR`, `GATEWAY`, `BRIDGE`, `NAMESERVER`, `STORAGE`, `TEMPLATE_STORAGE`, `TEMPLATE_MIN_GIB` (2), `CORES` (2), `MEMORY` (4096), `SWAP` (1024), `ROOTFS_GB` (32; ~16 is enough with CPU-only torch) |
| Firewall | `FIREWALL`, `API_ALLOW_CIDR` (set it, or 8000/8080 may be dropped) |
| Open WebUI | `OPENWEBUI_VERSION` (0.12.4), `OPENWEBUI_PORT` (8080), `OPENWEBUI_PY_VERSION` (3.12), `OPENWEBUI_PY_DIR` (`/opt/python`), `TORCH_CPU_ONLY` (true) |
| Model servers | `MODEL_SERVER_COUNT`, `MODEL_SERVER_<n>`, `OLLAMA_PORT` (11434), `MODEL_SERVER_MIN`/`_MAX` |
| Tiers | `TIER_FAST_SERVERS` … `TIER_XLARGE_SERVERS` (e.g. `1,3`), `MODEL_FAST` … `MODEL_XLARGE`, `OLLAMA_KEEP_ALIVE` |
| Gitea | `GITEA_SERVER_URL`, `GITEA_ADMIN_USER`, `GITEA_DEPLOY_TOKEN`, `GITEA_REPO_NAME` (`ollama-smart-router`), `GITEA_REPO_OWNER` (auto), `GITEA_REPO_PRIVATE` |
| Mattermost | `MATTERMOST_WEBHOOK_URL`, `MATTERMOST_MONITOR_USER`, `MATTERMOST_CHANNEL` (`ollama-monitor`) |
| Targets | `INSTALL_TARGETS` (e.g. `gitea,ollama,hermes`; pre-fills the menu answer), `INSTALL_GITEA` / `INSTALL_MATTERMOST` (`true` pre-selects that service), `<NAME>_CT_ID`, `<NAME>_IP_CIDR`, `<NAME>_STORAGE`, `<NAME>_TEMPLATE` (`<NAME>` is `GITEA`, `MATTERMOST`, `OLLAMA`, `LLAMACPP`, …, `OPEN_TERMINAL`, `HERMES`, `COMFYUI`), `COMFYUI_IMAGE_VARIANT` (`klein-4b` or `klein-9b`) and `HF_TOKEN` (skips the Hugging Face token prompt for `klein-9b`), `GITEA_COMMUNITY_SCRIPT_URL` / `_SHA256` and the `MATTERMOST_*` and `COMFYUI_*` equivalents (pin a target's community script), the services' own settings such as `GITEA_SITE_ADMIN` and `MATTERMOST_TEAM` (see their READMEs), `<NAME>_PORT` for Strata/Basalt/Maya (8080), `OPENWEBUI_ADMIN_TOKEN` (skips the admin key prompt), `OPENWEBUI_WAIT_SECONDS` (900), `TARGETS_DIR` |

`NONINTERACTIVE=true` refuses a non-empty `INSTALL_TARGETS` (or `INSTALL_GITEA`
/ `INSTALL_MATTERMOST=true`). The community scripts' menus, GPU selection and
the Open WebUI admin key need a person. Install the router unattended instead,
then run each target's `provision-lxc.sh` afterwards. A target's CT settings
(`<NAME>_CT_ID`, …) are separate from the router's `CT_ID`, `IP_CIDR` and
`STORAGE`; every target shares the router's bridge and gateway. Targets need
the full repository checkout.

**Model servers.** An address can be `10.0.0.5`, `host:port`, a URL, or
`kind://host` for a non-Ollama server (e.g. `strata://10.0.0.8`). Only
servers 1–3 have default addresses. `MODEL_LARGE` defaults to the inherited
`qwen3.8:27b`, so change it to a model you have pulled. By default the servers
are split into four contiguous groups, with the remainder going to `xlarge`.
Below four servers, the upper tiers share the last host:

| Servers | fast | medium | large | xlarge |
|---|---|---|---|---|
| 1 | 1 | 1 | 1 | 1 |
| 2 | 1 | 2 | 2 | 2 |
| 3 | 1 | 2 | 3 | 3 |
| 5 | 1 | 2 | 3 | 4,5 |
| 8 | 1,2 | 3,4 | 5,6 | 7,8 |

**Gitea.** Use the server's actual scheme, address and port. The community
installer below serves on `http://<ct-ip>:3000`; the TurnKey appliance serves
on HTTPS port 443. If your server redirects HTTP to HTTPS, use its final HTTPS
URL directly so the token is not dropped on the redirect. TLS verification
is off by default for self-signed certificates. To turn it on, install the CA
and change
`GITEA_VERIFY_TLS=false` in `prompt_gitea_credentials`. The token is checked
before anything is built, with up to 3 tries. If the token belongs to another
account, its owner becomes the repo owner. The repo is `GITEA_REPO_NAME`, and
its owner is resolved in this order: `GITEA_REPO_OWNER`, then the token owner,
then an exact-name search across repos the token can see. The repo is created
under the token owner only when none matches; a missing repo under any other
`GITEA_REPO_OWNER` stops the check, so create that one in Gitea first. If several matches are ambiguous, the installer stops
and you set `GITEA_REPO_OWNER`. With no usable token, the install continues in
**local mode**: the same config is applied, but without version control. The
installer's access-test commit is deleted again once it succeeds; remove
markers left by older runs with `git rm -r provisioning-tests`.

**After install**

```
http://<ct-ip>:8000/v1      OpenAI-compatible API (Bearer ROUTER_API_KEY)
http://<ct-ip>:8080         Open WebUI: the first visitor creates the admin account
```

**Gitea and Mattermost on their own.** `targets/gitea/provision-lxc.sh` and
`targets/mattermost/provision-lxc.sh` create the same service CTs for an
existing router, and print where their URL, token or webhook are. See
[targets/gitea](targets/gitea/README.md) and
[targets/mattermost](targets/mattermost/README.md).
- `--create-only` keeps the earlier behaviour: the community script, then the
  browser setup steps. `tools/install-gitea.sh` and
  `tools/install-mattermost.sh` still do exactly that.
- `--reconfigure` repairs the setup of an existing CT.
- **A Gitea you already run.** Give the router a dedicated non-admin account
  and its token. Reusing an existing repository needs the `read:user` and
  `write:repository` scopes; creating it under that account needs `write:user`
  and `write:repository`. Tokens cannot be limited to one repository, so limit
  the account's access instead (a collaborator with Write access).
- **Plain HTTP.** Gitea answers on `http://<ip>:3000`, so its token travels
  unencrypted. Put a TLS reverse proxy in front of it on an untrusted network.

The first Open WebUI start downloads an embedding model and is slow
(`TimeoutStartSec=600`). `/etc/motd` summarises ports, tiers and paths. The
runtime file layout is in [ARCHITECTURE.md, Appendix A](ARCHITECTURE.md#appendix-a--runtime-file-layout).

## How routing works

The router polls every host in `MODEL_SERVERS` every `refresh_seconds` (60)
through that host's own API and keeps a live inventory. Each request is
classified `fast` / `medium` / `large` / `xlarge` (from the newest user
message's length and keywords, plus whether it contains code or an image).
Every `(host, model)` pair is then scored:

- **Size band** — `0:9`, `9:20`, `20:70`, `70:999` billion parameters
  (ceilings exclusive). Out-of-band models score lower but are not excluded.
  When nothing is in band, the closest model wins.
- **Specialisation** — code requests prefer code models, and image requests
  prefer vision models (Ollama's `/api/show` capabilities first, names as a
  fallback).
- **Tools** — a request that offers tools (agents such as Hermes, Open WebUI
  function calling) skips models whose server reports no tool support
  (Ollama's `tools` capability; the llama.cpp bridge needs `tools` in
  `MODEL_CAPABILITIES`). It is raised to at least the `large` class
  (`[classification] tools_min_class`), and stays on one model across an agent
  loop. A model that answers 400 "does not support tools" (or similar
  wording) is skipped and the next candidate tried. Any other 400, such as a
  malformed `tools` schema, goes back to the client unchanged.
- **Never embeddings** — naming an embedding-only model on
  `/v1/chat/completions` returns 400 `embedding_model_not_chat`.
- **Load spreading** — near-ties rotate across hosts.
- **Fail-forward** — a connect error, timeout, 404 or 5xx moves on to the
  next candidate, until the response starts streaming. A host that refuses a
  connection is marked down until its next good poll.

A model named in the request is honoured if a host that has it is up.
Otherwise the request is routed by content with
`X-Router-Warning: model-unavailable`. `auto` and the tier aliases mean
"decide for me"; a tier alias pins the size class. An image request with no
vision model is routed with `X-Router-Warning: no-vision-model`, or rejected
if `vision_strict = true`. A tool request with no tool-capable model gets
`X-Router-Warning: no-tool-model`, or a 400 with `tools_strict = true`.

Every response carries `X-Router-Model`, `-Server`, `-Class`, `-Mode` and
`-Candidates`. For inspection:

```
GET  /routing/inventory   what each host serves (tools, context_length, ...), up/down, last error
POST /routing/refresh     re-poll now
POST /routing/explain     {"prompt": "..."} -> decision and scored candidates
GET  /healthz             liveness (no key needed)
```

Thresholds, keywords (JSON arrays; `"re:..."` for regexes), weights, bands,
timeouts and model sizes all live in `services/ollama-router/router.ini`, so
routing changes by commit. If discovery is disabled or the inventory is empty,
the router hands the request to LiteLLM by tier (`X-Router-Mode: litellm`).

**API key.** New installs generate `ROUTER_API_KEY`. For an older install, run
`manage-model-servers set-api-key --apply`, then paste the printed key into
Open WebUI under **Admin Settings > Connections > OpenAI**, because Open WebUI
reads `OPENAI_API_KEYS` only on its first start. The client's key is never
forwarded to model hosts.

## Managing model servers

`manage-model-servers` runs inside the CT or on the Proxmox host. On the host
it finds the CT that holds the config and re-runs itself there; set `CT_ID` to
skip the search. Commands that write take the config lock, and `--apply`
validates, applies and health-checks (see [Applying changes](#applying-configuration-changes)).

```bash
manage-model-servers list | status | discover | models     # config, live probe, router inventory, tags per host
manage-model-servers add 10.0.0.55 --tier large --apply      # probed before it is accepted (--no-probe skips)
manage-model-servers add lmstudio://10.0.0.9:1234 --tier fast   # or --type <kind>
manage-model-servers remove 10.0.0.55 --apply                # by address or list number
manage-model-servers set-tier large 10.0.0.54 10.0.0.55 --apply
manage-model-servers set-model large qwen3:32b --apply       # every server in the tier
manage-model-servers set-server-model large 10.0.0.54 llama3.3:70b --apply   # one server
manage-model-servers set-keepalive 2h --apply
manage-model-servers set-api-key [key|--generate|--off]
manage-model-servers set-<kind>-token [token|--off]          # lmstudio, strata, basalt, maya, xolotl
manage-model-servers set-token | set-webhook [url] | test-alert [message]
manage-model-servers set-webui-version [version|latest] [--apply]
manage-model-servers apply [--all] | commit [message]
manage-model-servers clear-lock [--force]
```

- Servers are keyed by URL, never by position, so removing one never re-points
  a tier at the wrong host.
- Models are set per (tier, server), and both model commands check that the
  tag exists on the server first. Pass full Ollama names without the `ollama/`
  prefix, e.g. `smtek/Qwen3.8-27B:Q3_K_XL-16gb`.
- A tier's model tag drives the LiteLLM fallback and the keep-alive pinning.
  Discovery-mode routing picks from the live inventory regardless.
- `commit` pushes with the deploy token from `secrets.env` (Gitea refuses
  passwords over HTTP). Replace the token with `set-token`.

### Server kinds

Non-Ollama servers are stored with a kind prefix (`maya+http://host:8080`);
`add` accepts `kind://host` or `--type kind`. A bare address is auto-detected
without sending a key: Ollama `/api/tags`, then the public `/health` markers of
Strata, Basalt, Maya and Xolotl, then LM Studio's model API, trying each kind's
default port. Xolotl runs Strata's server, so its `/health` says `strata`; a
DeepSeek-V4 model there identifies Xolotl.

| Kind | Default port | Token (in `secrets.env`) | Notes |
|---|---|---|---|
| Ollama (also llama.cpp bridge, AirLLM) | 11434 | — | Keep-alive pinned by the monitor |
| LM Studio | 1234 | `set-lmstudio-token` | Resident models are preferred; `lmstudio_loaded_only = true` never triggers a just-in-time load. Model names differ (`qwen/qwen3-14b`). Set LM Studio's own idle TTL. |
| Strata | 8080 | `set-strata-token` | Must listen on an address the router can reach (its default is `127.0.0.1`). Can run on 11434: `strata://host:11434`. |
| Basalt | 8080 | `set-basalt-token` | Model ID is `BASALT_ALIAS` (default `qwen3.8-flash-next`) |
| Maya | 8080 | `set-maya-token` | Model ID `glm-5.3-flash` |
| Xolotl | 8080 | `set-xolotl-token` | Model ID `XOLOTL_MODEL_NAME` (default `deepseek-v4.1-flash`, sized 552B) |

Example for a keyed Strata-style server. Set the token first, so the probe can
authenticate:

```bash
manage-model-servers set-maya-token --apply
manage-model-servers add maya://10.0.0.9 --tier xlarge --apply
manage-model-servers set-server-model xlarge maya://10.0.0.9 glm-5.3-flash --apply
```

If an older keyed Strata cannot be identified without a key, add it as
`strata://host` (that probe uses the key) or with `--no-probe`. Strata, Basalt,
Maya and Xolotl load models themselves, so no keep-alive is sent. The monitor counts
them as down while `/v1/models` is empty, which is how they answer when the
engine is not running.

### Model sizes for unsized IDs

Strata, Basalt, Maya and Xolotl report no parameter count. `[model_sizes]` in
`router.ini` maps exact model IDs (case-insensitive) to a size:

```ini
[model_sizes]
strata = 125B
qwen3.8-flash-next = 125B
glm-5.3-flash = 321B
```

Add a line for a custom alias; a blank value removes a built-in entry. A size
in the ID (`coder:62b`) or a reported `parameter_size` wins. The older
`[discovery] *_default_params` / `*_default_id` keys are still read.

### Keeping models loaded

Ollama unloads idle models after ~5 minutes, and its OpenAI-compatible
endpoint ignores `keep_alive`. Set `OLLAMA_KEEP_ALIVE` (at install, or
`set-keepalive 30m|2h|-1|0|<seconds> --apply`) and two things happen:

- LiteLLM sends `keep_alive` on its native-API calls.
- The monitor calls each up Ollama host's native `/api/chat` with an empty
  message every 240 s (`monitor.ini [keep_alive] refresh_seconds`), keeping
  each tier's model loaded.

Blank (the default) sends nothing and leaves each server's own setting in
charge.

## Applying configuration changes

The config repo is cloned once, at provisioning, so services never need Gitea
to start. To change config on a running CT:

```bash
cd /app/config-repo && git pull
manage-model-servers apply          # or --all to restart every service
```

`apply`:

1. **Validates** the LiteLLM YAML (models, `api_base`, fallbacks), the ini
   files and keyword JSON, the env files, and that `router.py`/`monitor.py`
   compile. On any error nothing is changed.
2. **Snapshots** the installed files to `/var/backups/ollama-smart-router/`
   (root-only; `APPLY_BACKUP_KEEP`, default 5).
3. **Applies** the files, brings the LiteLLM and Open WebUI venvs in line with
   their pins (Open WebUI's `webui.db` is backed up first), and restarts only
   the affected services.
4. **Health-checks** the router `/healthz`, LiteLLM `/health/liveliness`,
   Open WebUI `/health` and the monitor. On failure it restores the snapshot
   and restarts the old files. Rebuilt venvs are not rolled back, except that
   a failed Open WebUI upgrade reinstalls the previous version and database.

Regenerating the LiteLLM config keeps model tags and hand-edited
`router_settings` (`num_retries: 2`, `timeout: 600`). It rebuilds `fallbacks`
from the existing tiers and never falls back to an identical tier.

**Secrets** (deploy token, webhook, router key, backend tokens) live only in
`/app/router/secrets.env` (`0640 root:ollama-router`). `apply` and `commit`
move any secret they find in `env/router.env` into that file. Commits made
before 2026-09 still contain the old deploy token, so rotate it in Gitea.

**Config lock.** `update-router.sh` and every writing command take
`/run/lock/ollama-smart-router-config.lock`. A second change fails at once;
`CONFIG_LOCK_WAIT=<seconds>` makes it wait instead. The lock dies with its
process, so a crash never leaves it held.

## Updating

### Router components

To update the router, monitor, units, requirements and management tools from
a newer clone, without reinstalling, run this as root from a clone on the
Proxmox host:

```bash
bash /path/to/clone/tools/update-router-services.sh --dry-run --diff   # review
bash /path/to/clone/tools/update-router-services.sh                     # prompts for the CT (or set CT_ID; --host skips the location prompt)
```

To run it inside the CT, use a clone separate from `/app/config-repo` and add
`--container`. It refuses a missing or nonstandard installation, then stages
the installer-owned files and runs
`install/update-router.sh` in the CT. That script commits them to
`/app/config-repo`, rebuilds the router venv if its requirements changed, runs
`manage-model-servers apply`, and pushes. On a failed apply it undoes the
commit and restores the previous venv packages. It never touches your servers,
tiers, `env/*.env`, `litellm_config.yaml` or secrets. `router.ini` and
`monitor.ini` are replaced only with `--with-tunables`. `--no-apply` and
`--no-push` stop early. It refuses a config repo with uncommitted changes, so
commit pending edits first. A failed push exits non-zero but keeps the
applied update.

Re-running the installer also updates installer-owned code in the Gitea repo
(`CONFIG_UPDATE_CODE=true`). Configuration files are only seeded if missing.

### Open WebUI

```bash
manage-model-servers set-webui-version                 # pinned / installed / latest
manage-model-servers set-webui-version latest --apply  # or a specific version
```

The pin lives in `services/open-webui/requirements.txt`. The version is
checked against PyPI and against the venv's Python before the pin is written.
If the upgraded UI fails its health check, the previous version and
`webui.db` are restored.

New installs get Open WebUI 0.12.4. To bring an existing router up to it, run
`manage-model-servers set-webui-version 0.12.4 --apply`. Open WebUI 0.11.1,
0.12.0 and 0.12.1 migrate the database, so an older version cannot open it
afterwards. `apply` copies `webui.db` into its snapshot under
`/var/backups/ollama-smart-router/<timestamp>/openwebui-data/` before
upgrading; only the last `APPLY_BACKUP_KEEP` (5) snapshots are kept, so copy
that directory elsewhere if you may want to roll back later. Re-run a ComfyUI
router's `targets/comfyui/integrate-webui.py` only if its image settings need
to change: it handles both the 0.11.4+ connection check and the older one.

### Inference targets

Each target has `provision-lxc.sh` (run on the PVE host; it creates the CT,
passes the GPU through and pushes files), `install-target.sh` (run in the CT;
also does `--upgrade`), tests and a README with the full procedure. Every
provisioner offers `--dry-run`; the Strata, Basalt, Maya and Xolotl guest
installers also offer it.

| Target | Register as | Port | Engine |
|---|---|---|---|
| [ollama](targets/ollama/README.md) | plain address | 11434 | Ollama from the PVE community script, run unprivileged with pinned, checksummed upgrades; NVIDIA (CUDA), AMD Radeon (ROCm) or Intel Arc (Vulkan) |
| [llamacpp](targets/llamacpp/README.md) | plain address | 11434 | llama.cpp `llama-server` (one GGUF) behind an Ollama bridge; CUDA on NVIDIA, Vulkan on AMD Radeon and Intel Arc (Debian 13), or CPU |
| [airllm](targets/airllm/README.md) | plain address | 11434 | AirLLM, streaming a model larger than RAM/VRAM from disk; seconds–minutes per token, so give it its own tier |
| [strata](targets/strata/README.md) | `strata://` | 8080 | Strata (Qwen3.8-Flash-Next) |
| [basalt](targets/basalt/README.md) | `basalt://` | 8080 | Basalt on a Blackwell GPU, CUDA 13 (13.1+ on Debian 13) |
| [maya](targets/maya/README.md) | `maya://` | 8080 | Project Maya (GLM-5.3-Flash), CUDA 12.8 default |
| [xolotl](targets/xolotl/README.md) | `xolotl://` | 8080 | Xolotl, Indras Mirror's Strata fork, running DeepSeek-V4.1-Flash (552B MoE) on one 24 GB GPU; downloads ~372 GB of pinned, hash-checked weights, CUDA 13.0 default |

[Gitea](targets/gitea/README.md) and [Mattermost](targets/mattermost/README.md)
are services for the router (configuration repository and alerts). They come
from the Proxmox VE community scripts and are set up for the router by their
`install-target.sh`.

[Hermes Agent](targets/hermes/README.md) is an agent client, not a pool
member. Its CT discovers model servers and task ranking from the router, then
sends inference directly to the selected server. By default its API server is added to Open WebUI as the
model `hermes-agent`. Needs a tool-capable model with 64K context. After
`set-api-key`, a backend key rotation or a new model server, run its
`provision-lxc.sh --reconfigure`.

[ComfyUI](targets/comfyui/README.md) is Open WebUI's image generation engine,
not a pool member: chats get an image button, backed by ComfyUI on a GPU in
its own CT (port 8188). The CT comes from the Proxmox VE community script; the
target adopts it (unprivileged account, data in `/var/lib/comfyui-target`),
admits only the router to its unauthenticated port through the CT firewall,
and sets Open WebUI's image settings (engine, URL, and the selected distilled
FLUX.2 Klein 4B or 9B workflow). The installer prompts for the variant, and the
CT install downloads its diffusion model, text encoder and VAE (12.5 or 18.4 GB,
checksum-verified, resumable), so images work when the install finishes.
`klein-9b` is gated: the installer also asks for a Hugging Face token whose
account accepted its license (or takes `HF_TOKEN`). Its `--upgrade` builds a
pinned, commit-verified release beside the running one.

Upgrades share one contract ([ARCHITECTURE.md §16](ARCHITECTURE.md#16-inference-targets-targets)):

- Sources are fetched and verified before stopping. Strata, Basalt, Maya and
  Xolotl stop and snapshot the running checkout before building (Xolotl also
  verifies or finishes its weights download first); llama.cpp, AirLLM,
  Ollama, Open Terminal and ComfyUI prepare the new build, venv or release
  while the old one keeps running, then restart.
- An unchanged, healthy target is left alone ("nothing to do").
- Success requires the target's own health check.
- Any failure restores the previous code and configuration, health-checks
  it, and exits non-zero.
- llama.cpp, AirLLM, Ollama and ComfyUI keep a deliberately stopped service
  stopped.
- Strata, Basalt, Maya and Xolotl keep an installation's settings on every rerun, with
  or without `--upgrade` (`installed-env`, or `installed-settings` for older
  installs). Non-empty environment values override them; changing Strata's
  family or Maya's or Xolotl's CUDA version also resets the model or nvcc derived from it
  unless that is given too. A first install that stops part-way resumes with
  the settings it was started with (`pending-env`). An existing checkout or
  unit with no readable record at all requires every setting explicitly; it
  never receives fresh-install defaults.

Strata, Basalt, Maya and Xolotl snapshot their runnable checkout to
`/var/lib/<target>-target/rollback-runtime.tar` (root-only, may contain
secrets) before changing it, and delete it once the upgrade or the rollback
succeeds. Leave disk room for one snapshot during an upgrade; model stores
outside `/opt/<target>` are not copied.

### Old tier names

Configs from before the `xlarge` tier may use old names. Nothing migrates them
automatically. The services still read the old env keys, but API callers must
switch to `large`. Edit `env/router.env`, `litellm_config.yaml` and
`router.ini`:

| Old | New |
|---|---|
| `BACKEND_QWEN_HEAVY` / `BACKEND_HEAVY`, `MODEL_HEAVY` | `BACKEND_LARGE`, `MODEL_LARGE` |
| `BACKEND_QWEN_FAST` / `_MEDIUM` | `BACKEND_FAST` / `BACKEND_MEDIUM` |
| `model_name: qwen-heavy` / `heavy`; `heavy =` in `[thresholds]`, `[keywords]`, `[tiers]` | `large` |
| `heavy_params = 20:999` | `large_params = 20:70` and `xlarge_params = 70:999` |
| `prefer_larger_heavy` / `prefer_smaller_fast` | `prefer_larger` / `prefer_smaller` |

Then populate the new tier: `manage-model-servers set-tier xlarge <host>` and
`set-model xlarge <tag> --apply --commit`. Settings `router.ini` omits use the
built-in defaults.

## Troubleshooting

Start with the services' logs and the router's view of the pool:

```bash
systemctl status open-webui ollama-router litellm-proxy ollama-monitor
journalctl -u ollama-router -f        # every routing decision is logged
manage-model-servers status           # configured hosts + live probe
curl -s -H "Authorization: Bearer $KEY" http://<ct-ip>:8000/routing/inventory
```

| Symptom | Cause / fix |
|---|---|
| Installer: no storage found | The storage does not declare `rootdir`. Run `pvesm set <storage> --content rootdir,images`. Storages too small for `ROOTFS_GB` are listed but cannot be selected. |
| Installer: Gitea 401 or TLS error | Use `https://` without a port. The installer prints a specific diagnosis (DNS, refused, TLS, 401). A wrong token re-prompts; after 3 tries it falls back to local mode. |
| `open-webui==… (from versions: none)` | Open WebUI needs Python 3.11–3.12. The installer provisions 3.12 (system package, otherwise `uv` into `/opt/python`, which needs PyPI/GitHub). If neither is reachable, install 3.12 manually and re-run. |
| Open WebUI venv ~7.5 GB | `TORCH_CPU_ONLY=false`, or `download.pytorch.org` was unreachable. `apply` installs CPU torch and purges `nvidia-*`/`triton` wheels. |
| Open WebUI shows no models / 401 | The router key changed. Paste it into Admin Settings > Connections > OpenAI. |
| A host or its models are missing | Check `/routing/inventory` for the error. Common causes: a wrong or missing `set-<kind>-token` (401), a Strata-style engine not running (empty `/v1/models`), or a server bound to `127.0.0.1`. A refused connection takes a host out of rotation until its next good poll. |
| Request went to an unexpected model | Look at the `X-Router-*` headers, or `POST /routing/explain`. `model-unavailable` means the named model's hosts were down. Unknown-size models score low; give them a `[model_sizes]` entry. |
| Long prompt fails with 4xx | Context windows are not considered, and a 4xx does not fail forward. Use a model with a larger context. |
| Agent or function-calling request fails with "does not support tools" | No discovered model reports tool support (`X-Router-Warning: no-tool-model`). Check `tools` per model in `/routing/inventory`; for llama.cpp add `tools` to `MODEL_CAPABILITIES`. |
| Models unload after ~5 min | Set `OLLAMA_KEEP_ALIVE` (see above). If you rely on the host's own setting, check that it is in the unit (`Environment="OLLAMA_KEEP_ALIVE=2h"`, then `daemon-reload` and restart). |
| No Mattermost alerts | `journalctl -u ollama-monitor` shows rejected webhooks. Use `set-webhook` and `test-alert`. Alerts fire after 3 failed checks and recover after 2; the startup notice is sent at most hourly. |
| `apply` failed | The snapshot was restored and the services were restarted on the old files. Read the reported check, then `journalctl -u <unit>`. Snapshots are in `/var/backups/ollama-smart-router/`. |
| "config is locked" | Another change is running. A hung one: `manage-model-servers clear-lock` shows the holder, and `--force` stops it. Afterwards check `git -C /app/config-repo status` and re-run `apply`. |
| Target upgrade failed | The installer says whether the previous version is "running again". If not, use `journalctl -u <unit>` in the target CT. Replaced files are kept as `*.prev` (llama.cpp, AirLLM, Ollama); Strata, Basalt, Maya and Xolotl keep their snapshot in `/var/lib/<target>-target/` when the rollback fails. Maya, Basalt and Xolotl: the CT's distro must carry the CUDA release, or the toolkit must already be installed. Debian 13 starts at 13.1 (no V100 support for Maya; set `CUDA_VERSION=13.1` for Basalt). |

## Development

The files under `services/`, `install/` and `targets/` are the source of
truth. The installer embeds copies of `services/` and `install/`: after editing, run
`tools/sync-embedded.py --write`, or `tests/test-repo.sh` fails.
`install/manage-model-servers.sh` is the only real management tool; the
repo-root `manage-model-servers.sh` just runs it.

`bash tests/run-tests.sh` runs every suite: shell, pytest, the targets' stubbed
installs, and a coverage gate requiring a test for every installer and manager
function. Use `bash tests/run-tests.sh <suite>` or `--list` to pick one. Nothing
touches the network, a CT or a GPU. Target end-to-end cases need root and are
skipped otherwise; `unshare -r bash targets/<t>/test-*.sh` runs them as an
ordinary user. CI (`.gitea/workflows/tests.yml`, needs an `act_runner`) runs
the suites, shellcheck and ruff on every push. It uses separate router and
bridge venvs because they pin different fastapi versions. Three more jobs check
Strata, Maya and Xolotl at their pinned upstream commits.
