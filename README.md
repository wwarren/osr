![Ollama Smart Router logo](assets/logo.svg)

# Ollama Smart Router — Setup & Operations

A Proxmox LXC that puts one OpenAI-compatible endpoint in front of a pool of
self-hosted model servers. It routes each request by complexity, spreads load,
serves a chat UI and alerts on host health. Design and rationale are in
[ARCHITECTURE.md](ARCHITECTURE.md); tests in [tests/README.md](tests/README.md).

## What gets deployed

An unprivileged Debian 13 CT (default 2 vCPU, 4 GB RAM, 32 GB disk) running four
hardened systemd services as the `ollama-router` user:

| Service | Unit | Port | Role |
|---|---|---|---|
| Smart Router | `ollama-router.service` | 8000 | OpenAI API; picks a model and host per request |
| Open WebUI | `open-webui.service` | 8080 | Chat UI; talks to the router |
| LiteLLM | `litellm-proxy.service` | 127.0.0.1:4000 | Static tier fallback, cloud models and non-chat `/v1` routes |
| Health monitor | `ollama-monitor.service` | — | Probes hosts and local services, alerts to Mattermost, keeps Ollama models loaded |

Normal request path: **client or Open WebUI → router :8000 → model host**.
LiteLLM serves static tiers only when discovery is off or the inventory is
empty. The pool can mix Ollama, LM Studio, llama.cpp, AirLLM, Strata, Basalt,
Maya, Xolotl, Avalon and Kindi. Optional service, model and companion CTs are
listed under [Inference targets](#inference-targets); standalone
[MQTT and hcom targets](#agent-coordination-targets) connect agents across
containers.

## Install

From a full repository checkout, as root on the Proxmox host that should hold
the new CTs:

```bash
bash ollama-smart-router-install.sh
```

The installer's menu offers, grouped by purpose: Gitea and Mattermost
services; Ollama, AirLLM, Kindi, llama.cpp, Strata, Basalt, Maya, Xolotl and
Avalon model servers; Honcho memory; Hermes, OpenClaw and DeepSeek Harness
agents; Open Terminal and ComfyUI tools. Enter names or menu numbers
(comma-separated), or Enter for none. MQTT and hcom are installed afterwards
([Agent coordination targets](#agent-coordination-targets)).

You enter the router's CT ID and static IP/CIDR, then a CT ID, static IP/CIDR
and storage for each selected target (Strata, Basalt, Maya, Xolotl, Avalon and
Kindi also a template). Each CT ID defaults to the cluster's next free ID,
skipping IDs already given out in this run (Enter takes it; type another, or
preset `CT_ID` / `<NAME>_CT_ID`, to override). Addresses are never chosen;
presets prefill prompts. It then checks the host GPU, creates
the selected service CTs (a failure stops the install before the router is
built), verifies the Gitea token, creates the router, provisions model targets,
then Honcho, the agents and tools. Choose **Default** in the Gitea, Mattermost,
Ollama and ComfyUI community-script menus. Companions that register with Open
WebUI (Honcho, Hermes, OpenClaw, Open Terminal, ComfyUI) need an Open WebUI
admin API key: create the first admin account in the browser, enable API keys
and create one when prompted. A failed model or companion target leaves the
router running and is listed with retry instructions at the end.

Ollama and AirLLM install their engines during provisioning; llama.cpp creates
only a CT unless `MODEL_ALIAS` and `MODEL_DOWNLOAD_URL` or `MODEL_PATH` are set
([its README](targets/llamacpp/README.md)). Gitea and Mattermost admin
passwords are in `/etc/<service>-target/admin-password` in their CTs.

### LXC distribution support

| LXC | Default | Other supported releases |
|---|---|---|
| Router, Gitea, ComfyUI, Honcho | Debian 13 | — |
| Open Terminal, Hermes, OpenClaw, DeepSeek Harness | Debian 13 | Debian 12 |
| MQTT broker | Debian 13 | Debian 12 |
| hcom | Existing agent/observer CT with Python 3.11+ | No new CT; x86_64/aarch64 |
| Ollama | Debian 13 | Debian 12; Ubuntu 22.04, 24.04, 26.04 (`OLLAMA_CT_OS`, `OLLAMA_CT_VERSION`) |
| Mattermost | Ubuntu 24.04 | `MATTERMOST_CT_VERSION=26.04` accepted for future testing, not yet supported by Mattermost |
| AirLLM | Chosen at prompt | Debian 12/13; Ubuntu 24.04/26.04 (Python 3.11+) |
| llama.cpp | Debian 13 | Debian 12 for CUDA or CPU; Vulkan needs 13 |
| Basalt, Maya, Xolotl | Debian 13 | Debian 12; Ubuntu 22.04, 24.04, 26.04 |
| Strata | Debian 13 | Debian 12; Ubuntu 22.04/24.04 |
| Kindi | Debian 13 | Debian 12; Ubuntu 22.04/24.04 (CUDA 10.2 runfile) |
| Avalon | Ubuntu 24.04 | Ubuntu 22.04 (ROCm); with CUDA also Debian 12/13, Ubuntu 26.04 |

The installer asks for the router's template storage (default `local`) and
Debian 13 template before the target prompts; `TEMPLATE_REF` presets it and
`TEMPLATE_STORAGE` limits discovery to one storage. Strata defaults to the
router's template; other GPU targets prefer a downloaded Debian 13 template,
then supported Ubuntu and Debian releases, downloading their preferred release
if needed. Maya on a GPU below compute capability 7.5 (e.g. V100) defaults to
Ubuntu 24.04, since CUDA 13 cannot build for it. Debian 13's NVIDIA repository
starts at CUDA 13.1 and Ubuntu 26.04's at 13.3; Basalt, Maya, Xolotl and
Avalon (CUDA) get those versions unless overridden. A CT's NVIDIA user-space
must match the loaded host driver. Ubuntu 26.04 needs an available template
(`pveam update`, `pveam available`) and a current `pve-container`.

### Host GPU

| Target | Requirement |
|---|---|
| Strata, Maya, Xolotl | NVIDIA |
| Basalt | NVIDIA Blackwell (sm_120: RTX 50 or RTX PRO Blackwell) |
| Avalon | AMD Radeon RX 7000 (RDNA 3, ROCm) or NVIDIA RTX 20+ (CUDA); 16 GB+ VRAM, AVX2 CPU |
| llama.cpp | NVIDIA (CUDA) or AMD/Intel (Vulkan); `BACKEND=cpu` needs none |
| AirLLM | NVIDIA when `GPU_DEVICES` is set |
| Ollama, ComfyUI | NVIDIA, AMD or Intel if present, else CPU |
| Kindi | Any NVIDIA from Kepler (sm_30) on the host's driver (Kepler: the 470 driver, installed by hand), else its AVX2 CPU engine |

**Which GPU each target gets.** The installer lists the host's NVIDIA cards
and AMD Radeon RX 7000/9000 and Intel Arc A/B cards (from `lspci`; iGPUs,
older Radeons and `vfio-pci`-bound cards are not offered). Ollama, llama.cpp,
ComfyUI, Avalon (RDNA 3 or NVIDIA) and Kindi (meant for a spare old or small
NVIDIA card) each ask which card to use; Ollama, Kindi and ComfyUI also offer
`none` (CPU). Several targets may share a card; a single fitting card is taken
without asking. Presets: `OLLAMA_GPU_CARD`, `LLAMACPP_GPU_CARD`,
`AVALON_GPU_CARD`, `KINDI_GPU_CARD`, `COMFYUI_GPU_CARD` (a PCI address such as
`0000:03:00.0`, or `none`). Strata, Basalt, Maya, Xolotl and AirLLM are
NVIDIA-only and use GPU 0 (or their `GPU_DEVICES`). Ollama and ComfyUI receive
`GPU` (vendor) and `GPU_CARD` and keep only that card's nodes after their
community scripts pass every card of the vendor; llama.cpp gets `BACKEND` and
`GPU_DEVICES` (render node for Vulkan, `/dev/nvidia<minor>` for CUDA), as do
Avalon (`AVALON_BACKEND`) and Kindi (`KINDI_BACKEND`). Presets are kept.

**Each model target's context window.** The installer then asks the context
window (tokens per request) of each selected Ollama, llama.cpp, Strata, Basalt,
Maya, Xolotl, Avalon and Kindi target: default 65536 (Avalon and Kindi also
accept `auto`; Kindi defaults to it). The recommendation weighs the GPU's
memory (from `nvidia-smi` or amdgpu sysfs; unknown before the driver is set
up), the engine (Xolotl's 128k needs 24 GB; Strata, Basalt and Maya keep a small
KV cache; Ollama and llama.cpp are sized for full-attention models) and the
agents: Hermes needs 64000+, OpenClaw 32768+, DeepSeek Harness 16384+, and
Honcho runs its full budgets at 131072. Too-small windows are flagged.
Honcho's and DeepSeek Harness's windows are asked last, defaulting to the
smallest chosen. A llama.cpp window is multiplied by `PARALLEL_SLOTS` for
`CONTEXT_SIZE`. Presets: `OLLAMA_CONTEXT_LENGTH`, `LLAMACPP_CONTEXT` (or
`CONTEXT_SIZE`), `STRATA_CONTEXT`, `BASALT_CONTEXT`, `MAYA_CONTEXT`,
`XOLOTL_CONTEXT`, `AVALON_CONTEXT`, `KINDI_CONTEXT`, `HONCHO_CONTEXT_TOKENS`,
`DEEPSEEK_HARNESS_CONTEXT_WINDOW`. AirLLM keeps its own small window.

**Strata KV cache.** After the windows, the installer asks how Strata stores
its context (`STRATA_KV`): `int8` (8-bit keys and values, Strata's default),
`k8v4` (8-bit keys, 4-bit values: 23% smaller) or `q4_0` (4-bit: 45% smaller,
less precise on long documents). It suggests `k8v4` for cards under 24 GB (12
and 16 GB), where the freed memory holds more of the model, and `int8` for 24
and 32 GB cards or a card it cannot read yet. A Strata window of 8192 or less
keeps a 16-bit cache, so nothing is asked.

**Host drivers.** Before creating CTs, the installer checks for a working
driver for each chosen card and once for the NVIDIA-only targets. If one is
missing, [tools/setup-host-gpu.sh](tools/setup-host-gpu.sh) identifies the card
and offers to install NVIDIA 580.173.02 (open kernel modules, DKMS) or the
Proxmox kernel driver and firmware for AMD/Intel; it reports blacklisted or
`vfio-pci` cards without changing them. Unattended: `GPU_GENERATION` (e.g.
`rtx40`, `7900`, `9070`, `A770`, `B580`) and `INSTALL_HOST_DRIVER=yes`. A
missing required GPU or a needed reboot stops the install before any CT is
created; reboot and rerun. Intel Arc B needs a Linux 6.12+ Proxmox kernel.

### Cluster SSH

On a Proxmox VE 9 cluster, the installer next makes sure root
on every node can reach every other node over SSH, as Proxmox itself does. That
is what lets [tools/upgrade-all.sh](#everything-at-once) later be started on
any node and reach CTs on all of them.
[tools/setup-cluster-ssh.sh](tools/setup-cluster-ssh.sh) checks the connection
from this node to every node, and from every node to every other, against each
node's pinned host key (`/etc/pve/nodes/<node>/ssh_known_hosts`). It flags an
unpublished pin even when SSH still connects, and uses `pvecm updatecerts`
to repair these problems; pve-cluster also runs it at every start:

- on this node, when its root key pair, its key in
  `/etc/pve/priv/authorized_keys`, its `/root/.ssh/authorized_keys` link or
  its published host key is missing or wrong;
- on any node it already reaches, when that node cannot reach another, or
  another cannot reach it.

For a node it cannot reach at all, it says why: a refused key, a stale or
unpublished host key, or no connection on port 22 (sshd or firewall). On a
terminal it then offers to sign in to that node once, with its root password
typed at ssh's own prompt, to run `pvecm updatecerts` there. A host key the
cluster cannot vouch for is shown with how to compare it on that node, and is
trusted for that one connection only if you confirm it. One sign-in serves
both the checks and the repair on that node.

Every repair, on this node or another, runs with `--yes` or when you agree on
a terminal; without either it is only reported. `pvecm updatecerts` links a
regular `/root/.ssh/authorized_keys` to the cluster file, importing its keys
or keys in an existing `authorized_keys.org` into `/etc/pve/priv/authorized_keys`.
The tool lists entries that could change root SSH access on every node and
asks for approval on a terminal; otherwise it leaves
that node alone. An unattended install makes only repairs that need no password
or unapproved cluster-wide key import. Leaving a node alone only postpones the
import: pve-cluster runs `pvecm updatecerts` itself whenever it starts (at
boot, or a restart), and merges those entries then. To keep them on that node
only, remove them from its `/root/.ssh/authorized_keys` and delete its
`/root/.ssh/authorized_keys.org`; to share them, run the tool on a terminal and
allow the import.

A problem left over is a warning, not a failure: the router does not need it.
A standalone host has nothing to do. Run the tool again at any time:
`--check` only reports, and `--node` limits it to some nodes (this node is
always checked). `CLUSTER_SSH=check` or `skip` changes what the installer
does.

### Router settings

The router prompts for its CT ID, root password, network, storage and size;
Gitea URL, account, repository and token; Mattermost webhook (blank disables
alerts); and 1–20 model servers, tiers and model tags. Selected model targets
fill the first server slots; increase the count to add existing servers.
Inputs are validated before `pct create`; a failed router build removes its
half-built CT. A service CT that failed setup is kept for `--reconfigure`.

| Area | Variables (default) |
|---|---|
| CT | `CT_ID` (next free), `CT_NAME`, `IP_CIDR`, `GATEWAY`, `BRIDGE`, `NAMESERVER`, `STORAGE`, `TEMPLATE_REF`, `TEMPLATE_STORAGE`, `TEMPLATE_MIN_GIB` (2), `CORES` (2), `MEMORY` (4096), `SWAP` (1024), `ROOTFS_GB` (32; ~16 with CPU-only torch) |
| Firewall | `FIREWALL`, `API_ALLOW_CIDR` (set it with the firewall, or 8000/8080 may be dropped) |
| Open WebUI | `OPENWEBUI_VERSION` (0.12.4), `OPENWEBUI_PORT` (8080), `OPENWEBUI_PY_VERSION` (3.12), `OPENWEBUI_PY_DIR` (`/opt/python`), `TORCH_CPU_ONLY` (true) |
| Model servers | `MODEL_SERVER_COUNT`, `MODEL_SERVER_<n>`, `OLLAMA_PORT` (11434), `MODEL_SERVER_MIN`/`_MAX` (1/20) |
| Tiers | `TIER_FAST_SERVERS` … `TIER_XLARGE_SERVERS` (e.g. `1,3`), `MODEL_FAST` … `MODEL_XLARGE`, `OLLAMA_KEEP_ALIVE` |
| Gitea | `GITEA_SERVER_URL`, `GITEA_ADMIN_USER`, `GITEA_DEPLOY_TOKEN`, `GITEA_REPO_NAME` (`ollama-smart-router`), `GITEA_REPO_OWNER` (auto), `GITEA_REPO_PRIVATE` |
| Mattermost | `MATTERMOST_WEBHOOK_URL`, `MATTERMOST_MONITOR_USER`, `MATTERMOST_CHANNEL` (`ollama-monitor`) |
| Cluster | `CLUSTER_SSH` (`fix`, the default: check and repair root SSH between nodes; `check`: report only; `skip`) |
| Targets | `INSTALL_TARGETS` (names only; menu numbers are refused because they change), `INSTALL_GITEA` / `INSTALL_MATTERMOST`, `<NAME>_CT_ID`, `<NAME>_IP_CIDR`, `<NAME>_STORAGE`, `<NAME>_TEMPLATE`, `COMFYUI_IMAGE_VARIANT` (`klein-4b`/`klein-9b`), `HF_TOKEN`, `OPENWEBUI_ADMIN_TOKEN`, `OPENWEBUI_WAIT_SECONDS` (900), `TARGETS_DIR` |

`NONINTERACTIVE=true` requires `IP_CIDR`, `GATEWAY` and every
`MODEL_SERVER_<n>`, takes the next free CT ID unless `CT_ID` is set, accepts
the other defaults and refuses selected targets
(community-script menus, GPU selection and the admin key need interaction):
install the router unattended, then run each target's `provision-lxc.sh`.
Target CT variables are separate from the router's `CT_ID`, `IP_CIDR` and
`STORAGE`; targets share its bridge and gateway. Engine options (`GPU_DEVICES`,
`BACKEND`, `OLLAMA_PULL_MODELS`, `HERMES_MODEL`, `COMFYUI_MODEL_URL`, ...) are
in the target READMEs.

Model server addresses may be IPs, `host:port`, URLs or `kind://host`; none is
prefilled without its preset. Set `MODEL_LARGE` to a model your host has (the
inherited default is `qwen3.8:27b`). Hosts are divided among four tiers (with
fewer hosts, upper tiers share the last); override with `TIER_<tier>_SERVERS`.

**Gitea.** Use the final URL scheme, address and port (`:3000` for the
community CT, HTTPS 443 for TurnKey); a redirect can lose the token. A
dedicated non-admin account needs `read:user` and `write:repository` for an
existing repo, or `write:user` and `write:repository` to create one. Set
`GITEA_REPO_OWNER` if the lookup is ambiguous (a repo under another owner must
exist). Without a usable token the install continues in local mode. For
self-signed TLS verification defaults off; install the CA and change
`GITEA_VERIFY_TLS` in `prompt_gitea_credentials`. Protect tokens on untrusted
networks with a TLS reverse proxy. The installer tests write access by
committing and then deleting `provisioning-tests/<timestamp>.md` (both commits
stay in history); if cleanup fails, `git rm -r provisioning-tests` and commit.

**After install**

```
http://<ct-ip>:8000/v1      OpenAI-compatible API (Bearer ROUTER_API_KEY from /app/router/secrets.env)
http://<ct-ip>:8080         Open WebUI: the first visitor creates the admin account
```

Open WebUI's first start downloads an embedding model (up to ten minutes).
`/etc/motd` lists ports, tiers and paths; the full layout is in
[ARCHITECTURE.md, Appendix A](ARCHITECTURE.md#appendix-a--runtime-file-layout).
Gitea and Mattermost can also be added to an existing router with their
`provision-lxc.sh` (`--reconfigure` repairs; `--create-only`, also used by
`tools/install-gitea.sh` and `tools/install-mattermost.sh`, leaves browser
setup to you).

## Inference targets

Each target has a host-side `provision-lxc.sh` (with `--dry-run`), a guest-side
`install-target.sh` (also `--upgrade`) and a README with requirements,
settings and recovery steps.

| Target | Register as | Port | Key requirement |
|---|---|---|---|
| [Ollama](targets/ollama/README.md) | Plain address | 11434 | NVIDIA, AMD, Intel or CPU |
| [llama.cpp](targets/llamacpp/README.md) | Plain address | 11434 | One GGUF; CUDA, Vulkan or CPU |
| [AirLLM](targets/airllm/README.md) | Plain address | 11434 | Large disk; slow, give it its own tier |
| [Strata](targets/strata/README.md) | `strata://` | 8080 | NVIDIA |
| [Basalt](targets/basalt/README.md) | `basalt://` | 8080 | Blackwell (sm_120), CUDA 13 |
| [Maya](targets/maya/README.md) | `maya://` | 8080 | NVIDIA; CUDA must suit CT and card |
| [Xolotl](targets/xolotl/README.md) | `xolotl://` | 8080 | NVIDIA 24 GB; ~372 GB of pinned weights |
| [Avalon](targets/avalon/README.md) | `avalon://` | 8080 | AMD RX 7000 (ROCm) or NVIDIA, experts in RAM; ~90 GiB of pinned weights |
| [Kindi](targets/kindi/README.md) | `kindi://` | 8093 | Old or small NVIDIA (from a 1 GB Kepler) or CPU; one request at a time |

Services and companions use separate CTs and stay out of the model pool:

| Target | Role and operational note |
|---|---|
| [Gitea](targets/gitea/README.md) | Configuration history; optional |
| [Mattermost](targets/mattermost/README.md) | Health alerts and, with hcom, a separate handoff channel; optional |
| [Honcho](targets/honcho/README.md) | CPU-only shared agent memory and Open WebUI MCP tools, with its own embedding model. Needs a router model with tools and structured output; its proxy dispatches directly to model hosts. Reconfigure after key rotation |
| [Hermes](targets/hermes/README.md) | Open WebUI agent `hermes-agent`; direct dispatch needs tools and 64K context. Reconfigure after key rotation or host changes |
| [OpenClaw](targets/openclaw/README.md) | Open WebUI agent `openclaw` and Control UI on :18789; same dispatcher. Reconfigure after key rotation or host changes |
| [DeepSeek Harness](targets/deepseek-harness/README.md) | Agent Web UI on :3080 using OSR as provider; no Open WebUI token needed |
| [Open Terminal](targets/open-terminal/README.md) | Open WebUI terminal connection; access grants share one workspace |
| [ComfyUI](targets/comfyui/README.md) | Open WebUI image engine on :8188; FLUX.2 Klein 9B needs an accepted Hugging Face license and token |

Honcho reaches Hermes and OpenClaw through their memory plugins and DeepSeek
Harness through MCP tools.

### Proxmox tags

Each installer tags the CT it creates. `osr-target` marks every CT installed
alongside the router; the last tag is the target's directory name under
`targets/`.

| CT | Tags |
|---|---|
| Router | `ai`, `ai-tools`, `osr-router`, `openwebui` |
| Ollama, llama.cpp, AirLLM, Strata, Basalt, Maya, Xolotl, Avalon, Kindi, ComfyUI | `ai`, `ai-model`, `osr-target`, `<target>` |
| Gitea, Mattermost, Honcho, Open Terminal, Hermes, OpenClaw, DeepSeek Harness, MQTT | `ai`, `ai-tools`, `osr-target`, `<target>` |

`tools/upgrade-all.sh` finds CTs only by these tags (`osr-router`, and
`osr-target` plus the target's name), so every provisioner makes sure they are
there:

- A CT made with `pct create` gets them at creation.
- Community-script CTs (Ollama, ComfyUI, Gitea, Mattermost) also get
  `community-script`. Because the script's menus can change or drop the tags it
  was given, the provisioner adds any that are missing once the script is done.
- `--reconfigure` (Gitea, Mattermost, Honcho, Hermes, OpenClaw, DeepSeek Harness,
  MQTT) adds any missing tags to the existing CT, so a CT made by hand or by an
  older version becomes visible to the upgrade.

Missing tags are added and the CT's other tags are kept (`pve_ensure_tags` in
`targets/pve-select.sh`). `--integrate-only` leaves the CT as it is. For any
other CT, add the tags yourself: `pct set <id> --tags 'ai;ai-model;osr-target;ollama'`.
hcom creates no CT. The lists live in each `provision-lxc.sh` and the router
installer; `tests/test-repo.sh` checks that they match `upgrade-all.sh`'s
targets. Keep this table in step with them.

### Provisioner questions

On a terminal, the provisioners used by the main installer ask in sections and
confirm a summary before changing anything:

```
== Router ==
  Router CT ID or address [280]:
== Hermes container ==
  New Hermes CT ID (unused) [282]:
  (numbered template and storage menus)
  Hermes IP/CIDR: 192.0.2.82/24
  Hermes gateway [192.0.2.1]:
== Hermes settings ==
  OSR model or tier [auto]:
  Context window the model serves (tokens) [65536]:
  Offer Hermes in Open WebUI (as hermes-agent)? [Y/n]:
  Run the Hermes dashboard? [Y/n]:
== Honcho memory ==
  Honcho API URL (none to skip) [http://192.0.2.85:8000]:
== Hermes: create ==
  Router                     CT 280, http://192.0.2.80:8000
  Hermes CT                  282 (hermes-target), ...
Create Hermes CT 282? [Y/n]:
```

- **Router first, then the target.** The router is offered from the CT tagged
  `osr-router`; the new CT's ID, template, storage, address and gateway follow
  (the gateway offered from the router's network), then the target's settings.
- **Enter takes the value in brackets.** A new CT's ID defaults to the
  cluster's next free ID (`pvesh get /cluster/nextid`): Enter takes it, typing
  another or presetting `CT_ID` overrides it, and an unattended run uses it
  and says so (dry runs query nothing, so they need `CT_ID`). An existing CT
  or gateway is only offered to a person, and addresses are always typed.
  Optional settings accept `none`.
- **`--reconfigure` starts from what is installed.** It asks for the CT
  (offering the one with the target's tag), then the router it uses, and every
  setting shows the running CT's recorded value, so Enter keeps it.
- **Environment variables win.** Preset variables are not asked. Without a
  terminal (or with `NONINTERACTIVE=true`), missing required settings stop the
  run naming the variable, and `--reconfigure` keeps recorded settings.
  `PVE_CONFIRM=false` skips the confirmation; the router installer runs
  provisioners with `PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false`.

The shared helpers are `targets/pve-select.sh`; each provisioner using them
keeps an identical copy (checked by `targets/test-pve-select.sh`). llama.cpp
and AirLLM keep their own container prompts in the same order; MQTT prompts
for missing values without the confirmation flow; hcom takes its CT IDs from
the environment. Review `--dry-run` output first.

## Agent coordination targets

[MQTT](targets/mqtt/README.md) provides an authenticated Mosquitto broker in its
own CPU-only Debian LXC (1 core, 512 MB, 4 GB). [hcom](targets/hcom/README.md)
installs the checksum-pinned 0.7.31 CLI into existing Hermes, OpenClaw and
DeepSeek Harness CTs; each keeps its own SQLite state and MQTT relays encrypted
events between them. Neither joins the model pool or needs an Open WebUI token.
Install the agents first, then the broker, then hcom in each agent; the
optional Mattermost observer also needs a configured Mattermost CT. From a full
checkout, as root on the same host, with your own IDs and addresses:

```bash
# 1. Broker
CT_ID=286 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.86/24 GATEWAY=192.0.2.1 MQTT_CLIENT_CIDR=192.0.2.0/24 \
  bash tools/install-mqtt.sh --dry-run
# 2. hcom in existing agent CTs (creates no CTs)
CT_ID=282 MQTT_CT_ID=286 HCOM_TARGET=hermes           bash tools/install-hcom.sh --dry-run
CT_ID=283 MQTT_CT_ID=286 HCOM_TARGET=openclaw         bash tools/install-hcom.sh --dry-run
CT_ID=281 MQTT_CT_ID=286 HCOM_TARGET=deepseek-harness bash tools/install-hcom.sh --dry-run
# 3. Optional: one observer on the broker CT, posting to Mattermost CT 277
CT_ID=286 MQTT_CT_ID=286 HCOM_TARGET=observer MATTERMOST_CT_ID=277 bash tools/install-hcom.sh --dry-run
```

Remove `--dry-run` to apply. The hcom provisioner adds owned outbound rules
where an agent restricts egress (Hermes and OpenClaw do by default). The
broker's `MQTT_CLIENT_CIDR` is the one IPv4 range allowed to connect (Proxmox
firewall enforcement must be on): give a range containing every agent CT, usually
their shared subnet such as `192.168.1.0/24`, or `a.b.c.d/32` for a single CT.
The prompt suggests the broker's subnet and warns about agents outside it. Port 1883 (`mqtt://`) is for a trusted network; for
TLS set `MQTT_PORT=8883`, `MQTT_HOST` to the certificate's name, and
`MQTT_TLS_CERT_FILE`/`MQTT_TLS_KEY_FILE`, with clients trusting the
certificate.

| Integration | Agent behaviour |
|---|---|
| Hermes | `osr-bus` and a managed `/home/hermes/AGENTS.md` block. The opt-in native plugin (`HCOM_HERMES_NATIVE=true`) gives Hermes the relay key and works only in messaging-platform chats, not Open WebUI |
| OpenClaw | Managed workspace instructions use `osr-bus` through its terminal tool; no native hooks or wakeups |
| DeepSeek Harness | Managed `AGENTS.md` block, same `osr-bus`; polling depends on the model |
| Mattermost | One observer posts short handoffs to a dedicated `agent-handoffs` webhook, separate from health alerts |

```bash
osr-bus status                 # through an agent's terminal tool, or as root
osr-bus inbox --last 100
osr-bus send hermes 'Please review the new installer.'
osr-bus follow
osr-bus tui                    # root only
```

Agents reach the bus only through `/run/osr-hcom/bus.sock`, which stamps the
sender; hcom state and the relay key belong to a separate `osr-hcom` account,
because any key holder can send hcom remote requests (settings, transcripts,
launches) to its peers. Messages are limited to 2,000 characters; `inbox` shows
recent events and agents use IDs to avoid repeating work. The observer keeps a
cursor, retries failed HTTP deliveries, starts at new messages and never
replays history after a database replacement; delivery is at least once. Run
one observer per relay group. `/etc/mqtt-target/relay.json` must stay out of
Git. No bus-to-Honcho archive exists, but native memory plugins can record bus
content an agent reads. Details: [hcom guide](targets/hcom/README.md),
[architecture](ARCHITECTURE.md#177-mqtt-and-hcom-agent-coordination).

## Cloud API models

Selected OpenAI, Anthropic and Google Gemini API models can be offered beside
local ones. Clients pick them explicitly as `openai/<id>`, `anthropic/<id>` or
`gemini/<id>`; `auto` and the tier aliases stay local. Cloud requests go
through LiteLLM (`X-Router-Mode: cloud`); provider keys stay in
`/app/router/secrets.env`. A configured cloud ID wins over a local model of the
same name; an unconfigured prefixed name still reaches a local server listing
it (LM Studio's `openai/gpt-oss-20b`), else 404 `cloud_model_not_configured`.

```bash
manage-model-servers set-cloud-key gemini       # prompts twice without echo
manage-model-servers set-cloud-models gemini '<Gemini-API-model-id>' --apply
manage-model-servers set-cloud-key openai
manage-model-servers set-cloud-models openai '<OpenAI-API-model-id>' --apply
manage-model-servers set-cloud-key anthropic
manage-model-servers set-cloud-models anthropic '<Claude-API-model-id>' --apply
```

IDs (comma-separated) are stored in `env/router.env` as
`CLOUD_OPENAI_MODELS`, `CLOUD_ANTHROPIC_MODELS` and `CLOUD_GEMINI_MODELS`; a
model appears in `/v1/models` only when its key is also set. `--off --apply`
clears a list or key. Cloud deployments in `litellm_config.yaml` are rebuilt on
every regeneration. Get keys and model IDs from the
[OpenAI platform](https://platform.openai.com/docs/models),
[Anthropic Console](https://docs.anthropic.com/en/docs/about-claude/models/overview)
or [Google AI Studio](https://ai.google.dev/gemini-api/docs/models); these use
API billing, so check account limits first.

### Signed-in subscription clients

LiteLLM documents per-client pass-through for
[Codex with a ChatGPT login](https://docs.litellm.ai/docs/tutorials/openai_codex_byok) and
[Claude Code with a Claude subscription](https://docs.litellm.ai/docs/tutorials/claude_code_max_subscription).
That needs a newer LiteLLM gateway with PostgreSQL, `chatgpt/*` or
`anthropic/*` deployments, a gateway virtual key and each client's login, run
separately from this project's pinned LiteLLM. Set its root URL (no `/v1`;
HTTPS or loopback HTTP) as `SUBSCRIPTION_GATEWAY_BASE_URL` in `env/router.env`
and apply. Point Codex at `http://<ct-ip>:8000/v1` and Claude Code at
`ANTHROPIC_BASE_URL=http://<ct-ip>:8000` (no `/v1`), sending on every request:

| Header | Value |
| --- | --- |
| `x-router-subscription` | `1` (selects the gateway) |
| `x-router-api-key` | OSR's `ROUTER_API_KEY`, bare (keep `Authorization` for the client login) |
| `x-litellm-api-key` | The gateway's virtual key |

The router forwards chat, Responses, Anthropic Messages and model-list
requests unchanged (`X-Router-Mode: subscription`), passing the client's
`Authorization` and removing its own two headers. Without `ROUTER_API_KEY` it
answers 503 `subscription_auth_not_configured`; without a valid gateway URL 503
`subscription_gateway_not_configured` (an invalid URL is logged at start).
Configure headers with Codex's `http_headers`/`env_http_headers` or Claude
Code's `ANTHROPIC_CUSTOM_HEADERS`. Never put a browser session or CLI OAuth
credential in `secrets.env`. Open WebUI's shared connection cannot carry
per-user logins. [Gemini CLI disallows third-party use of its OAuth
login](https://geminicli.com/docs/faq/); use a Gemini API key.

## How routing works

The router polls configured hosts every 60 s, classifies the newest user
message as `fast`, `medium`, `large` or `xlarge`, and scores each host/model
pair by size, code or vision fit, tool support and residency; close scores
rotate. A named model is used if available; `auto` and tier aliases let the
router choose; embedding models are never used for chat. Connect errors,
timeouts, 404s, 5xx and tool-support rejections try the next candidate until
streaming starts; other 400s go back to the client. With discovery off or an
empty inventory, LiteLLM serves static tiers (`X-Router-Mode: litellm`).
`X-Router-Model`, `-Server`, `-Class`, `-Mode`, `-Candidates` and `-Warning`
explain each choice.

```text
GET  /routing/inventory   host models, capabilities, context and errors
POST /routing/refresh     poll now
POST /routing/explain     {"prompt": "..."} -> scored candidates
GET  /healthz             unauthenticated liveness
```

Tune thresholds, keywords, weights, timeouts and sizes in
`services/ollama-router/router.ini`; the rules are in
[ARCHITECTURE.md](ARCHITECTURE.md#5-request-routing).

**Binding.** The router reads `ROUTER_HOST`/`ROUTER_PORT` (default
`0.0.0.0:8000`; the installer sets neither). To change them, set them in
`env/router.env`, then update `OPENAI_API_BASE_URLS` in `env/openwebui.env`
(and Open WebUI's saved connection under **Admin Settings > Connections**),
`ollama-router` in `monitor.ini [local_services]`, the CT firewall and clients.
Management health checks use `ROUTER_URL` (default `http://127.0.0.1:8000`):
set it when running `apply`, `discover` or the updater inside the CT (the
host-side wrappers do not forward it). Reconfigure Hermes and OpenClaw: their
`--reconfigure` derives `ROUTER_URL` from the router's IP and `ROUTER_PORT`
unless you pass it, and does not remember a custom URL.

**API key.** New installs generate `ROUTER_API_KEY`; without one on a
non-loopback address the router logs a warning. For an older install run
`manage-model-servers set-api-key --apply` and paste the key into Open WebUI
**Admin Settings > Connections > OpenAI**.

## Managing model servers

`manage-model-servers` exists only in the router CT, as
`/usr/local/bin/manage-model-servers` → `/app/config-repo/install/manage-model-servers.sh`
(recreated by every `apply`, so a config-repo update updates it). Run it as
root:

```bash
pct enter <CT_ID>; manage-model-servers list                     # inside the CT
pct exec <CT_ID> -- /usr/local/bin/manage-model-servers list     # from the host
bash /path/to/clone/install/manage-model-servers.sh list         # from a clone on the host: finds the CT (CT_ID=<id> skips the search)
```

`<CT_ID>` is printed at the end of the install and shown by `pct list`
(`ollama-smart-router` unless `CT_NAME` was set). Writing commands take the
config lock; `--apply` validates, applies and health-checks
([Applying changes](#applying-configuration-changes)).

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
manage-model-servers set-<kind>-token [token|--off]          # lmstudio, strata, basalt, maya, xolotl, avalon, kindi
manage-model-servers set-cloud-key <openai|anthropic|gemini> [key|--off]
manage-model-servers set-cloud-models <openai|anthropic|gemini> <id[,id...]|--off>
manage-model-servers set-token | set-webhook [url] | test-alert [message]
manage-model-servers set-webui-version [version|latest] [--apply]
manage-model-servers apply [--all] | commit [message]
manage-model-servers clear-lock [--force]
```

Servers are keyed by URL, so removing one never re-points a tier. Models are
set per (tier, server) and checked on the server first; pass full Ollama names
without `ollama/` (e.g. `smtek/Qwen3.8-27B:Q3_K_XL-16gb`). A tier's tag drives
only the LiteLLM fallback and keep-alive pinning; discovery picks from the live
inventory. `commit` pushes with the deploy token from `secrets.env` (replace
with `set-token`).

### Server kinds

Non-Ollama servers are stored with a kind prefix (`maya+http://host:8080`);
`add` accepts `kind://host` or `--type kind`. A bare address is detected
without sending a key: Ollama `/api/tags`, the public `/health` markers of
Strata, Basalt, Maya, Xolotl (Strata's server, told apart by its DeepSeek-V4
model) and Kindi (`"kindi": "<version>"`), then LM Studio, trying each kind's
default port. Avalon is identified from `/v1/models` (`"owned_by": "llamacpp"`
and an Avalon id), which needs its key once set, so add a keyed Avalon as
`avalon://host`. Set the token before adding a keyed server, so the probe can
authenticate; a keyed server that cannot identify itself is added as
`kind://host` (or with `--no-probe`).

| Kind | Default port | Token (`secrets.env`) | Notes |
|---|---|---|---|
| Ollama (also llama.cpp bridge, AirLLM) | 11434 | — | Keep-alive pinned by the monitor |
| LM Studio | 1234 | `set-lmstudio-token` | Resident models preferred; `lmstudio_loaded_only = true` never triggers a just-in-time load. Names differ (`qwen/qwen3-14b`); set LM Studio's own idle TTL |
| Strata | 8080 | `set-strata-token` | Must listen on a reachable address (below); `strata://host:11434` for that port |
| Basalt | 8080 | `set-basalt-token` | Model ID `BASALT_ALIAS` (default `qwen3.8-flash-next`) |
| Maya | 8080 | `set-maya-token` | Model ID `glm-5.3-flash` |
| Xolotl | 8080 | `set-xolotl-token` | `XOLOTL_MODEL_NAME` (default `deepseek-v4.1-flash`, sized 552B) |
| Avalon | 8080 | `set-avalon-token` | `AVALON_MODEL_NAME` (default `qwen3.8-flash-next-avalon`, sized 125B) |
| Kindi | 8093 | `set-kindi-token` | `bonsai2-<size>` or `nanbeige-33b-iq3`, sized from the id; one request at a time |

```bash
manage-model-servers set-maya-token --apply
manage-model-servers add maya://10.0.0.9 --tier xlarge --apply
manage-model-servers set-server-model xlarge maya://10.0.0.9 glm-5.3-flash --apply
```

A Strata you run yourself (not the [Strata target](targets/strata/README.md))
binds to `127.0.0.1` by default. Run its setup (`./setup.sh`, or
`START-HERE.bat` on Windows) with `--host` set to a reachable address,
`--port 11434` if wanted and `--api-key`
([options at the tested commit](https://github.com/Niko1221/Strata/blob/a0116b2782a5b82622358c04a06496485d12b2d6/docs/INSTALL.md#options-without-questions));
the newer launcher on `main` uses `strata launch --access lan` and
[creates a key by default](https://github.com/Niko1221/Strata/blob/main/docs/TERMINAL_LAUNCH.md).
The Strata-style kinds load models themselves (no keep-alive), and the monitor
counts them down while `/v1/models` is empty (engine not running).

### Model sizes for unsized IDs

Strata, Basalt, Maya, Xolotl and Avalon report no parameter count (Kindi's ids
include it). `[model_sizes]` in `router.ini` maps exact IDs
(case-insensitive) to a size; built-in entries include:

```ini
[model_sizes]
strata = 125B
qwen3.8-flash-next = 125B
# ... and its -q2_0, -iq2_xs, -iq3_xxs and -iq3_s quant IDs
qwen3.8-flash-next-avalon = 125B
glm-5.3-flash = 321B
deepseek-v4.1-flash = 552B
```

Add a line for a custom alias; a blank value removes a built-in. A size in the
ID (`coder:62b`) or a reported `parameter_size` wins. The older `[discovery]
*_default_params` / `*_default_id` keys are still read.

### Keeping models loaded

Ollama unloads idle models after ~5 minutes and its OpenAI endpoint ignores
`keep_alive`. With `OLLAMA_KEEP_ALIVE` set (at install, or `set-keepalive
30m|2h|-1|0|<seconds> --apply`), LiteLLM sends `keep_alive` on native calls and
the monitor calls each up Ollama host's `/api/chat` with an empty message every
240 s (`monitor.ini [keep_alive] refresh_seconds` or
`KEEP_ALIVE_REFRESH_SECONDS`), keeping each tier's model loaded. Blank (the
default) sends nothing and leaves each server's own setting in charge.

## Applying configuration changes

The config repo is cloned once, at provisioning, so services never need Gitea
to start. To change a running CT:

```bash
cd /app/config-repo && git pull     # local mode: edit /app/config-repo directly
manage-model-servers apply          # or --all to restart every service
```

`apply`:

1. **Validates** the LiteLLM YAML (models, `api_base`, fallbacks), the ini files
   and keyword JSON, the env files, and that `router.py`/`monitor.py` compile;
   on any error nothing changes.
2. **Snapshots** the installed files to `/var/backups/ollama-smart-router/`
   (root-only; `APPLY_BACKUP_KEEP`, default 5).
3. **Applies** the files, brings the LiteLLM and Open WebUI venvs in line with
   their pins (backing up `webui.db` first) and restarts only affected services.
4. **Health-checks** router `/healthz`, LiteLLM `/health/liveliness`, Open
   WebUI `/health` and the monitor; on failure restores the snapshot and
   restarts the old files. Rebuilt venvs are not rolled back, except that a
   failed Open WebUI upgrade reinstalls the previous version and database.

Regenerating the LiteLLM config keeps model tags and hand-edited
`router_settings` (`num_retries: 2`, `timeout: 600`), rebuilds `fallbacks`
from existing tiers (never to an identical tier, and into a Kindi tier only
from a tier on other Kindi servers), keeps operator retry policies for other
tiers and writes Kindi's own for Kindi tiers
([Kindi timeouts](targets/kindi/README.md#timeouts-and-retries)).

**Secrets** (deploy token, webhook, router key, backend tokens, cloud keys)
live only in `/app/router/secrets.env` (`0640 root:ollama-router`); `apply` and
`commit` move any found in `env/router.env` there. Commits made before 2026-09
contain the old deploy token: rotate it in Gitea.

**Config lock.** `update-router.sh` and every writing command take
`/run/lock/ollama-smart-router-config.lock`. A second change fails at once
(`CONFIG_LOCK_WAIT=<seconds>` waits). The lock dies with its process. For a
hung holder, `clear-lock --force` confirms, then sends SIGTERM and SIGKILL
after `LOCK_KILL_WAIT` (10) s (`--yes` skips the prompt; without a terminal it
cancels). A change stopped midway can leave the repo or services half-updated.

## Updating

### Everything at once

To bring the router and every target in a Proxmox cluster (or on a standalone
host) up to this clone's versions in one run, keeping their settings, as root
on any one node (inside `tmux` or `screen`, since model targets can take a long
time):

```bash
bash /path/to/clone/tools/upgrade-all.sh --dry-run   # the plan, and the router's pending diff
bash /path/to/clone/tools/upgrade-all.sh             # asks before starting
```

It finds, on every node of the cluster, the router CT (tag `osr-router`),
each target CT (tag `osr-target` plus the target's name) and each CT with
hcom, then upgrades them in dependency order: router, Open WebUI, Gitea and Mattermost, model targets,
ComfyUI and Open Terminal, Honcho, the agents, MQTT, hcom (agents before the
observer). Each goes through its own supported path, so nothing about its
settings or rollback changes:

| Component | Upgraded with | Settings kept by |
|---|---|---|
| Router | `update-router-services.sh --host --no-push`, pushed once checks pass | Updater never touches `env/*.env`, tiers, `litellm_config.yaml`, ini files or secrets |
| Open WebUI | `set-webui-version <pin> --apply` (never a downgrade) | `apply`'s snapshot and `webui.db` backup |
| llama.cpp, AirLLM, Ollama, Strata, Basalt, Maya, Xolotl, Avalon, Kindi, ComfyUI | Current files pushed to `/root/<target>-target-deploy`, then `install-target.sh --upgrade` (ComfyUI keeps a release newer than its pin) | Each target's settings record or env files |
| Open Terminal | Current files pushed, installer rerun | Its recorded port, passed back |
| Gitea, Mattermost | `provision-lxc.sh --reconfigure`, which re-applies the OSR setup; their community scripts install the newest release, which this repository does not pin, so the release stays as it is (reported `reapplied`) | Accounts, router token and webhook are kept by their installers |
| Honcho, Hermes, OpenClaw, DeepSeek Harness | `provision-lxc.sh --reconfigure`; interactive runs use `PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false`, unattended runs use `NONINTERACTIVE=true` | Recorded answers; an Open WebUI admin key is requested once when needed |
| Hermes Agent itself | Not pinned here: the reconfigure upgrades its integration (units, dispatcher, settings) and Hermes stays at its installed version. `--update-hermes` also runs `hermes update` as the hermes user and restarts `hermes-gateway` and `hermes-dashboard`, unless `HERMES_COMMIT` pins it | The plan and summary say which: Hermes stayed, was updated (old and new commit), or stays at its pin |
| MQTT | `provision-lxc.sh --reconfigure` | Address, client CIDR, host, port and TLS files read back from the broker |
| hcom | `provision-lxc.sh` per CT | Role, native mode, instructions file and observer webhook read back from the CT |

**Clusters.** Everything runs from the node you start it on, which needs
root SSH to the other nodes, as Proxmox itself uses. The installer sets that up
([Cluster SSH](#cluster-ssh)); check or repair it at any time with
`bash tools/setup-cluster-ssh.sh`. When a node holding OSR CTs does not answer,
the run names it before planning and, on a terminal, offers to run that tool
for it, then checks again. Proxmox's `pct` acts only on CTs of its own node, so the run puts `tools/pct-cluster.sh` first on `PATH` as `pct`, for
itself and every provisioner it runs. That wrapper runs the real `pct` on the
node that holds each CT: here for a local CT, otherwise over SSH with the
options Proxmox VE 9 uses (BatchMode, the node name as `HostKeyAlias`, the
node's pinned host key in `/etc/pve/nodes/<node>/ssh_known_hosts` when published, its
address from `/etc/pve/.members`), with one shared connection per node. Files for `pct push` and `pct pull` are streamed
through that connection and leave no copies behind. Provisioners also get
`PVE_LXC_DIR` pointing at a view of every node's CT configurations, so a
router, Honcho, broker or Mattermost CT on another node is found and used as
if it were local. The plan and summary show each CT's node. A node the cluster
reports offline, or one that does not answer over SSH, is reported, and its
CTs are `not-run`. So is anything that needs the router or the hcom broker on
such a node. `--node pve2,pve3` limits the run to some nodes. When several OSR
installations share a cluster, set `ROUTER_CT_ID` or use `--node` to say
which router is meant. Only one run at a time is allowed in the cluster:
`/etc/pve/priv/osr-upgrade-all.lock` names the holder. A lock left by a run on
this node that has ended is taken over; delete one from another node by hand
once that run is gone. If the lock cannot be created at all, check quorum with
`pvecm status`, then check the cluster filesystem and path permissions. A node
without quorum usually has a read-only cluster filesystem. The wrapper also
works directly, for example
`bash tools/pct-cluster.sh exec 205 -- uptime` on any node.

A release you pinned yourself (`HONCHO_REF`, `DSH_VERSION`) is offered the
repository's pin in an interactive run; `--yes` accepts it and `--keep-pins`
preserves it. A `HERMES_COMMIT` pin is always kept. `latest`, `main` and releases newer than the repository's pin
are kept. Stopped CTs are left alone unless `--include-stopped`.

**Checks and failures.** Before each upgrade it records what works in that CT:
its services, its listening TCP ports, and for the router `/healthz`,
`/v1/models`, Open WebUI's `/health` and every model server the router sees.
For Hermes (and hcom on a Hermes CT) it also records whether the API server's
`/health` answers `"status": "ok"` on its port, the direct dispatcher's
`/healthz` and the dashboard's `/api/status` answer.
For a model target it also records whether the router lists that server as up
with models (after `/routing/refresh`). It then takes a Proxmox snapshot
(`osr-upg-<time>-<n>`; when one cannot be taken, interactive runs ask whether
to continue, unattended runs continue, and `--require-snapshot` skips that CT). After the
upgrade, everything that worked before must work again within
`--health-timeout` (300 s); what was already down is not checked. If the
upgrade fails or something broke, it rings the terminal bell, posts to
Mattermost through the router's webhook (`--no-notify` turns that off), lists
what broke and asks:

| Choice | Does |
|---|---|
| `r` | Retry |
| `i` | Retry interactively, answering the installer's or provisioner's questions yourself |
| `s` | Skip it: leave it as it is and go on (it keeps its snapshot) |
| `b` | Roll the CT back to the snapshot, check it again, go on (default when broken, or when a provisioner failed) |
| `l` | Show the end of its log |
| `a` | Abort: leave the rest untouched |

A component may restore its own files after a failed upgrade; check its log.
A target installer or the router updater restores what it changed; a
provisioner (Honcho, Hermes, OpenClaw, DeepSeek Harness, Gitea, Mattermost,
MQTT, hcom) can stop after it has changed the CT, so after its failure rolling
back is the default, and `--on-failure rollback` rolls back even when every
check still passes. A failed upgrade that is skipped keeps its snapshot, and
the summary gives the `pct rollback` and `pct delsnapshot` commands for it.
The Proxmox snapshot can restore the CT when a functional check fails. Without
one, recovery may need manual work. A snapshot covers only the CT: it cannot
restore host firewall rules or Open WebUI registrations. Snapshots are deleted
after success unless `--keep-snapshots`, and after a verified rollback.

`--yes` runs unattended: provisioners get `NONINTERACTIVE=true`, and failures
are handled with `--on-failure rollback` (default), `skip` or `abort`.

**Open WebUI admin token.** Honcho, and Hermes and OpenClaw with an Open WebUI
connection, register with Open WebUI again when reconfigured. When one of them
is included and `OPENWEBUI_ADMIN_TOKEN` is not set, an unattended run asks for
the token on the terminal once, at the start, before its plan and before
anything changes. The token is checked against Open WebUI in the router CT
(`/openai/config` answers only an admin), with three tries. It is kept in
`OPENWEBUI_ADMIN_TOKEN` for the run and passed only to those provisioners,
through their environment: it is not exported to other children, put on a
command line or written to disk. Press Enter to go on without it, and those
components are reported `not-run`. They are also reported `not-run` when
there is no terminal at all (cron, systemd), so set the variable there. An
interactive run asks for the token after you accept the plan; there, Enter
leaves each provisioner to ask for itself.
`--only` and `--skip` take target names, CT IDs or `name@ID`. Logs and a
`summary.txt` are kept in `/var/log/osr-upgrade/<time>/`; the exit status is
non-zero when anything was skipped, rolled back or left broken. GPU drivers are
separate: run `tools/update-gpu-drivers.sh` first when they need updating.

### Router components

To update the router, monitor, units, requirements and management tools from a
newer clone without reinstalling, as root on the Proxmox host:

```bash
bash /path/to/clone/tools/update-router-services.sh --dry-run --diff   # review
bash /path/to/clone/tools/update-router-services.sh                     # prompts for the CT (or CT_ID; --host skips the location prompt)
```

Inside the CT, use a clone separate from `/app/config-repo` and add
`--container`. It refuses a missing or nonstandard install, stages the
installer-owned files and runs `install/update-router.sh` in the CT, which
commits them to `/app/config-repo`, rebuilds the router venv if requirements
changed, runs `manage-model-servers apply` and pushes. A failed apply undoes
the commit and restores the previous venv packages. It never touches servers,
tiers, `env/*.env`, `litellm_config.yaml` or secrets; `router.ini` and
`monitor.ini` are replaced only with `--with-tunables`. `--no-apply` and
`--no-push` stop early. It refuses a config repo with uncommitted changes. A
failed push exits non-zero but keeps the applied update. Re-running the
installer also updates installer-owned code in Gitea
(`CONFIG_UPDATE_CODE=true`); configuration is only seeded if missing.

### Open WebUI

```bash
manage-model-servers set-webui-version                 # pinned / installed / latest
manage-model-servers set-webui-version latest --apply  # or a specific version
```

The pin is in `services/open-webui/requirements.txt`; the version is checked
against PyPI and the venv's Python first, and a failed health check restores
the previous version and `webui.db`. New installs get 0.12.4; upgrade older
routers with `set-webui-version 0.12.4 --apply`. Open WebUI 0.11.1, 0.12.0 and
0.12.1 migrate the database irreversibly; `apply` keeps a copy in
`/var/backups/ollama-smart-router/<timestamp>/openwebui-data/`, but only the
last `APPLY_BACKUP_KEEP` (5) snapshots are kept, so copy it elsewhere if you
may roll back later.

### Targets

Target upgrades check readiness and restore the prior code and settings on
failure; see each target README and the
[upgrade contract](ARCHITECTURE.md#16-inference-targets-targets). Strata,
Basalt, Maya, Xolotl, Avalon and Kindi need disk for one runtime snapshot and
carry their settings forward unless overridden. Interrupting an upgrade
(Ctrl-C, closed SSH) rolls it back; after a hangup its output is in the CT's
`/var/log/osr-install-interrupted.log`. If a model target's rollback fails too,
its next run stops at `/var/lib/<target>-target/rollback-failed` until you have
inspected the kept snapshot and deleted that file. MQTT and hcom are rerun
with the same settings (or `--reconfigure`); a failed rollback keeps
`/etc/mqtt-target/rollback` or `/etc/osr-hcom/rollback` and blocks reruns.
Rerun hcom everywhere after changing the broker's advertised host or port.

### GPU drivers

To check and update the drivers of the host and every GPU container, as root
on the Proxmox host:

```bash
bash /path/to/clone/tools/update-gpu-drivers.sh --check   # report only (exit 3: updates available)
bash /path/to/clone/tools/update-gpu-drivers.sh           # shows the plan and asks before each change
```

GPU containers are found from their configs (`/dev/nvidia*`, `/dev/dri/*`,
`/dev/kfd`); running ones are checked, stopped ones with `--include-stopped`
(started, then stopped again).

**NVIDIA.** Host driver and every container's libraries must be the same
release. It offers the newest production release (recommended), the newest of
the installed branch, and the newest new-feature release; pre-Turing cards
(Maxwell, Pascal, Volta) stay on 580. Before anything stops it downloads the
release, checks its SHA-256 and that `supported-gpus.json` lists every card
(with the open modules, if used), and test-builds the modules for the running
and newer installed kernels. It then stops the NVIDIA containers, unloads the
old modules, installs with `tools/install-nvidia-driver.sh host` (DKMS for
newer kernels), installs the same libraries in each container
(`tools/install-nvidia-driver.sh lxc`) and restarts them. Debian apt NVIDIA
packages in a container (`libcuda1`, `libnvidia-ml1`, `nvidia-smi` and
`nvidia-alternative` dependents) are replaced using the provisioners' cleanup
(`targets/nvidia-lxc.sh`). Every NVIDIA container is checked before any
download, including ones `--ct` leaves out; the host update is blocked by a
container that cannot be checked or started, does not see the host driver, or
has packages cleanup won't remove (Ubuntu's `libnvidia-compute-*`,
`cuda-drivers`) or whose removal would take others along
(`nvidia-cuda-toolkit`); `--check` lists blockers. A failed host install puts
the previous release back; a host process holding the GPU prevents the
install. Containers whose NVML or CUDA library mismatches the host are offered
the host's release. An apt-installed host driver is reported, not changed.
`--nvidia <version>` can also roll back, but not below the branch a
container's CUDA needs (CUDA 13: 580).

**AMD and Intel.** `amdgpu`, `i915` and `xe` ship with the Proxmox kernel, so
updates are pending `pve-firmware` and kernel-series updates (newer opt-in
series are reported, not installed). In containers, Mesa, Intel's compute
runtime and apt ROCm are upgraded from their own repositories; ROCm, CUDA and
PyTorch bundled with Ollama or ComfyUI move with the target's `--upgrade`.

`--yes` takes recommended answers (`--nvidia production|branch|newest|keep|<version>`),
`--ct 201,202` limits containers (a new NVIDIA host release still updates all
NVIDIA containers), `--dry-run` prints commands, `--no-probe` skips the test
build. It needs ~2 GB in `DOWNLOAD_DIR` (`/root`) and ~1 GB per NVIDIA
container while installing. Exit 2 means reboot (kernel, firmware or a driver
that could not load live), then rerun to confirm.

## Troubleshooting

Inside the router CT (`pct enter <CT_ID>`):

```bash
KEY=$(sed -n 's/^ROUTER_API_KEY=//p' /app/router/secrets.env)
systemctl status open-webui ollama-router litellm-proxy ollama-monitor
manage-model-servers status           # configured hosts + live probe
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:8000/routing/inventory
journalctl -u ollama-router -f        # decisions for chats sent to /v1/chat/completions
```

Hermes (`custom:osr`, including `auto`) and OpenClaw (`osr`) use the router
only for inventory and ranking and send chat directly from their CTs: their
decisions are in `journalctl -u hermes-direct -f` or `-u openclaw-direct -f`
there. The router shows their inventory and `/routing/explain` requests but no
`route class=` line for those chats.

| Symptom | Cause / fix |
|---|---|
| Installer: no storage found | The storage lacks `rootdir`: `pvesm set <storage> --content rootdir,images`. Storage smaller than `ROOTFS_GB` is listed but not selectable |
| Installer: Gitea 401 or TLS error | Use the final URL (community CT `http://<ip>:3000`, TurnKey HTTPS 443), no redirects. The installer diagnoses DNS, connection, TLS and token errors; after 3 bad tokens it uses local mode |
| `open-webui==… (from versions: none)` | Open WebUI needs Python 3.11–3.12. The installer provisions 3.12 (system package, else `uv` into `/opt/python`, needing PyPI/GitHub); otherwise install 3.12 by hand and rerun |
| Open WebUI venv ~7.5 GB | `TORCH_CPU_ONLY=false`, or `download.pytorch.org` was unreachable; `apply` installs CPU torch and purges `nvidia-*`/`triton` wheels |
| Open WebUI shows no models / 401 | The router key changed: paste it into Admin Settings > Connections > OpenAI |
| A host or its models are missing | `/routing/inventory` shows the error: a wrong or missing `set-<kind>-token` (401), a Strata-style engine not running (empty `/v1/models`), or a server bound to `127.0.0.1`. A refused connection removes a host until its next good poll |
| Request went to an unexpected model | Check the `X-Router-*` headers or `POST /routing/explain`. `model-unavailable`: the named model's hosts were down. Unknown sizes score low: add `[model_sizes]` |
| Long prompt fails with 4xx | Context windows are not considered and 4xx does not fail forward; use a larger-context model |
| "does not support tools" | No model reports tools (`X-Router-Warning: no-tool-model`); check `tools` in `/routing/inventory`; for llama.cpp add `tools` to `MODEL_CAPABILITIES` |
| Models unload after ~5 min | Set `OLLAMA_KEEP_ALIVE`, or on the host put `Environment="OLLAMA_KEEP_ALIVE=2h"` in the unit, `daemon-reload` and restart |
| No Mattermost alerts | `journalctl -u ollama-monitor` shows rejected webhooks; `set-webhook`, `test-alert`. Alerts fire after 3 failed checks, recover after 2; the startup notice is at most hourly |
| hcom cannot connect across CTs | `osr-bus status` as the agent, broker `MQTT_CLIENT_CIDR`, agent egress rules, credentials, TLS trust; `journalctl -u osr-hcom-relay` (agent) and `-u mosquitto` (broker) |
| No Mattermost handoff posts | `journalctl -u osr-hcom-mattermost` in the observer CT; check its webhook and outbound HTTP(S); one observer per group |
| `apply` failed | The snapshot was restored and services restarted on the old files; read the reported check and `journalctl -u <unit>`. Snapshots: `/var/backups/ollama-smart-router/` |
| "config is locked" | Another change is running. For a hung one, `clear-lock` shows and `--force` stops it; then `git -C /app/config-repo status` and rerun `apply` |
| Target upgrade failed | The installer says whether the previous version is "running again"; else `journalctl -u <unit>` in the target CT. llama.cpp, AirLLM and Ollama keep replaced files as `*.prev`; the Strata-style targets keep their snapshot in `/var/lib/<target>-target/` when rollback fails. Basalt, Maya and Xolotl need a CUDA release the distro's NVIDIA repository carries (Debian 13 starts at 13.1: no V100 for Maya; `CUDA_VERSION=13.1` for Basalt) or an installed toolkit |

## Development

`services/`, `install/` and `targets/` are the sources; after editing embedded
`services/` or `install/` files, run `tools/sync-embedded.py --write`.
`bash tests/run-tests.sh` runs every suite (`--list` names them; give one name
to run one). Root-only target cases skip without root; CI runs with `--strict`.
See [tests/README.md](tests/README.md).

To run CI (`.gitea/workflows/tests.yml`) in Gitea, enable Actions and register
an `act_runner` with an ubuntu-latest style image whose job containers run as
root (`--strict` fails on skipped root-only tests). The `strata-upstream`,
`maya-upstream`, `xolotl-upstream`, `avalon-upstream`, `kindi-upstream` and
`honcho-upstream` jobs also need GitHub (and PyPI) access.
