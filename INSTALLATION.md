# Install

From a full repository checkout, as root on the Proxmox host that should hold
the new CTs:

```bash
bash open-smart-router-install.sh
```

The installer's menu offers, grouped by purpose: Gitea and Mattermost
services; Ollama, AirLLM, Kindi, Colibri, llama.cpp, Strata, Basalt, Maya, Xolotl and
Avalon model servers; Honcho memory; Hermes, OpenClaw, DeepSeek Harness and
OpenCode agents; Open Terminal and ComfyUI tools; and the FreeLLMAPI cloud
gateway (Proxmox VE 9.1 and `skopeo` needed). Enter names or menu numbers
(comma-separated), or Enter for none. MQTT and hcom are installed afterwards
([Agent coordination targets](AGENT_COORDINATION.md#agent-coordination-targets)).

You enter the router's CT ID and static IP/CIDR, then a CT ID, static IP/CIDR
and storage for each selected target (Strata, Basalt, Maya, Xolotl, Avalon,
Kindi and Colibri also a template; Strata also its RAM, `STRATA_MEMORY_MB`, default 65536
MiB, at least 32768, shown beside the host's RAM: it holds its model in RAM,
about 48 GB for IQ2_XS, 60 for IQ3_XXS and 62 for IQ3_S; Colibri also its RAM,
`COLIBRI_MEMORY_MB` (65536, at least 8192), and disk, `COLIBRI_ROOTFS_GB` (160,
at least 40), sized for the model you will place in it, since none is
downloaded). Each CT ID defaults to the cluster's next free ID,
skipping IDs already given out in this run (Enter takes it; type another, or
preset `CT_ID` / `<NAME>_CT_ID`, to override). Addresses are never chosen;
presets prefill prompts. It then checks the host GPU, creates
the selected service CTs (a failure stops the install before the router is
built), verifies the Gitea token, creates the router, provisions model targets,
then Honcho, the agents and tools. Choose **Default** in the Gitea, Mattermost,
Ollama and ComfyUI community-script menus. Companions that register with Open
WebUI (Honcho, Hermes, OpenClaw, DeepSeek Harness, OpenCode, Open Terminal,
ComfyUI) need an Open WebUI admin API key: create the first admin account in
the browser, enable API keys and create one when prompted (without a key,
DeepSeek Harness is installed without its Open WebUI endpoint and the others
are skipped). A failed model or companion target leaves the router running
and is listed with retry instructions at the end.

Ollama and AirLLM install their engines during provisioning; llama.cpp creates
only a CT unless `MODEL_ALIAS` and `MODEL_DOWNLOAD_URL` or `MODEL_PATH` are set
([its README](targets/llamacpp/README.md)). Gitea and Mattermost admin
passwords are in `/etc/<service>-target/admin-password` in their CTs.

## LXC distribution support

| LXC | Default | Other supported releases |
|---|---|---|
| Router, Gitea, ComfyUI, Honcho | Debian 13 | — |
| Open Terminal, Hermes, OpenClaw, DeepSeek Harness, OpenCode | Debian 13 | Debian 12 |
| MQTT broker | Debian 13 | Debian 12 |
| hcom | Existing agent/observer CT with Python 3.11+ | No new CT; x86_64/aarch64 |
| Ollama | Debian 13 | Debian 12; Ubuntu 22.04, 24.04, 26.04 (`OLLAMA_CT_OS`, `OLLAMA_CT_VERSION`) |
| Mattermost | Ubuntu 24.04 | `MATTERMOST_CT_VERSION=26.04` accepted for future testing, not yet supported by Mattermost |
| AirLLM | Chosen at prompt | Debian 12/13; Ubuntu 24.04/26.04 (Python 3.11+) |
| llama.cpp | Debian 13 | Debian 12 for CUDA or CPU; Vulkan needs 13 |
| Basalt, Maya, Xolotl | Debian 13 | Debian 12; Ubuntu 22.04, 24.04, 26.04 |
| Strata | Debian 13 | Debian 12; Ubuntu 22.04/24.04 |
| Kindi | Debian 13 | Debian 12; Ubuntu 22.04/24.04 (CUDA 10.2 runfile) |
| Colibri | Debian 13 | Debian 12; Ubuntu 22.04/24.04 (Vulkan wants Debian 13's Mesa) |
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

## Host GPU

| Target | Requirement |
|---|---|
| Strata, Maya, Xolotl | NVIDIA |
| Basalt | NVIDIA Blackwell (sm_120: RTX 50 or RTX PRO Blackwell) |
| Avalon | AMD Radeon RX 7000 (RDNA 3, ROCm) or NVIDIA RTX 20+ (CUDA); 16 GB+ VRAM, AVX2 CPU |
| llama.cpp | NVIDIA (CUDA) or AMD/Intel (Vulkan); `BACKEND=cpu` needs none |
| AirLLM | NVIDIA when `GPU_DEVICES` is set |
| Ollama, ComfyUI | NVIDIA, AMD or Intel if present, else CPU |
| Kindi | Any NVIDIA from Kepler (sm_30) on the host's driver (Kepler: the 470 driver, installed by hand), else its AVX2 CPU engine |
| Colibri | NVIDIA (CUDA), AMD Radeon RX 7000/9000 or Intel Arc (Vulkan), or none (CPU) |

**Which GPU each target gets.** The installer lists the host's NVIDIA cards
and AMD Radeon RX 7000/9000 and Intel Arc A/B cards (from `lspci`; iGPUs,
older Radeons and `vfio-pci`-bound cards are not offered). Ollama, llama.cpp,
ComfyUI, Avalon (RDNA 3 or NVIDIA), Kindi (meant for a spare old or small
NVIDIA card) and Colibri each ask which card to use; Ollama, Kindi, Colibri and
ComfyUI also offer `none` (CPU). Several targets may share a card; a single fitting card is taken
without asking. Presets: `OLLAMA_GPU_CARD`, `LLAMACPP_GPU_CARD`,
`AVALON_GPU_CARD`, `KINDI_GPU_CARD`, `COLIBRI_GPU_CARD`, `COMFYUI_GPU_CARD` (a PCI address such as
`0000:03:00.0`, or `none`). Strata, Basalt, Maya, Xolotl and AirLLM are
NVIDIA-only and use GPU 0 (or their `GPU_DEVICES`). Ollama and ComfyUI receive
`GPU` (vendor) and `GPU_CARD` and keep only that card's nodes after their
community scripts pass every card of the vendor; llama.cpp gets `BACKEND` and
`GPU_DEVICES` (render node for Vulkan, `/dev/nvidia<minor>` for CUDA), as do
Avalon (`AVALON_BACKEND`), Kindi (`KINDI_BACKEND`) and Colibri
(`COLIBRI_BACKEND`: cuda on NVIDIA, vulkan with the render node on AMD or
Intel Arc, cpu without a card). Presets are kept.

**Each model target's context window.** The installer then asks the context
window (tokens per request) of each selected Ollama, llama.cpp, Strata, Basalt,
Maya, Xolotl, Avalon and Kindi target: default 65536 (Avalon and Kindi also
accept `auto`; Kindi defaults to it). The recommendation weighs the GPU's
memory (from `nvidia-smi` or amdgpu sysfs; unknown before the driver is set
up), the engine (Xolotl's 128k needs 24 GB; Strata, Basalt and Maya keep a small
KV cache; Ollama and llama.cpp are sized for full-attention models) and the
agents: Hermes needs 64000+, OpenClaw and OpenCode 32768+, DeepSeek Harness 16384+, and
Honcho runs its full budgets at 131072. Too-small windows are flagged.
Honcho's and DeepSeek Harness's windows are asked last, defaulting to `auto`.

**The agents follow what the servers serve.** With `auto` (the default for a
new agent CT) Hermes, OpenClaw, OpenCode, Honcho and DeepSeek Harness size each
model's window from what its server reports serving in the router's inventory
(`served_context_length`): an LM Studio model loaded with 262144 tokens gets
262144, Strata started with 131072 gets 131072, and a server that reports
nothing counts as 65536 (or the model's own limit if smaller). Hermes follows
it live; the others read it each time they are configured (`--reconfigure`,
`tools/upgrade-all.sh`). A number pins the window instead; an existing agent CT
keeps its recorded number until reconfigured with `auto`. A llama.cpp window is multiplied by `PARALLEL_SLOTS` for
`CONTEXT_SIZE`. Presets: `OLLAMA_CONTEXT_LENGTH`, `LLAMACPP_CONTEXT` (or
`CONTEXT_SIZE`), `STRATA_CONTEXT`, `BASALT_CONTEXT`, `MAYA_CONTEXT`,
`XOLOTL_CONTEXT`, `AVALON_CONTEXT`, `KINDI_CONTEXT`, `HONCHO_CONTEXT_TOKENS`,
`DEEPSEEK_HARNESS_CONTEXT_WINDOW`. AirLLM keeps its own small window.

**Strata KV cache.** After the windows, the installer asks how Strata stores
its context (`STRATA_KV`): `int8` (8-bit keys and values, Strata's default),
`k8v4` (8-bit keys, 4-bit values: 23% smaller) or `q4_0` (4-bit: 45% smaller,
less precise on long documents). From a 64K window, when Strata's CT (the RAM
chosen for it, `STRATA_MEMORY_MB`) holds the model and the cache, Strata keeps the
cache in RAM with only a 32K window on the GPU, and `int8` is suggested on any
card. Otherwise it suggests `k8v4` for cards under 24 GB (12 and 16 GB), where
the freed memory holds more of the model, and `int8` for 24 and 32 GB cards or
a card it cannot read yet. It then asks about Strata's message cache
(`STRATA_MESSAGE_CACHE`, default `false`): one more checkpoint before the last
message of a long conversation, for agents that rewrite it. A Strata window of
8192 or less keeps a 16-bit cache, so neither is asked.

**Host drivers.** Before creating CTs, the installer checks for a working
driver for each chosen card and once for the NVIDIA-only targets. If one is
missing, [tools/setup-host-gpu.sh](tools/setup-host-gpu.sh) identifies the card
and offers to install NVIDIA 580.173.02 (open kernel modules, DKMS) or the
Proxmox kernel driver and firmware for AMD/Intel; it reports blacklisted or
`vfio-pci` cards without changing them. Unattended: `GPU_GENERATION` (e.g.
`rtx40`, `7900`, `9070`, `A770`, `B580`) and `INSTALL_HOST_DRIVER=yes`. A
missing required GPU or a needed reboot stops the install before any CT is
created; reboot and rerun. Intel Arc B needs a Linux 6.12+ Proxmox kernel.

## Cluster SSH

On a Proxmox VE 9 cluster, the installer next makes sure root
on every node can reach every other node over SSH, as Proxmox itself does. That
is what lets [tools/upgrade-all.sh](UPDATING.md#everything-at-once) later be started on
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

## Router settings

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
| Open WebUI | `OPENWEBUI_VERSION` (0.13.4; `latest` for the newest release), `OPENWEBUI_PORT` (8080), `OPENWEBUI_PY_VERSION` (3.12), `OPENWEBUI_PY_DIR` (`/opt/python`), `TORCH_CPU_ONLY` (true) |
| Model servers | `MODEL_SERVER_COUNT`, `MODEL_SERVER_<n>`, `OLLAMA_PORT` (11434), `MODEL_SERVER_MIN`/`_MAX` (1/20) |
| Tiers | `TIER_FAST_SERVERS` … `TIER_XLARGE_SERVERS` (e.g. `1,3`), `MODEL_FAST` … `MODEL_XLARGE`, `OLLAMA_KEEP_ALIVE` |
| Gitea | `GITEA_SERVER_URL`, `GITEA_ADMIN_USER`, `GITEA_DEPLOY_TOKEN`, `GITEA_REPO_NAME` (`open-smart-router`), `GITEA_REPO_LEGACY_NAME` (`ollama-smart-router`, used when the default name finds no repository), `GITEA_REPO_OWNER` (auto), `GITEA_REPO_PRIVATE`, `GITEA_VERIFY_TLS` (false) |
| Mattermost | `MATTERMOST_WEBHOOK_URL`, `MATTERMOST_MONITOR_USER` (`OSRMonitor`), `MATTERMOST_CHANNEL` (`osr-monitor`) |
| Cluster | `CLUSTER_SSH` (`fix`, the default: check and repair root SSH between nodes; `check`: report only; `skip`) |
| Targets | `INSTALL_TARGETS` (names only; menu numbers are refused because they change), `INSTALL_GITEA` / `INSTALL_MATTERMOST`, `<NAME>_CT_ID`, `<NAME>_IP_CIDR`, `<NAME>_STORAGE`, `<NAME>_TEMPLATE`, `STRATA_MEMORY_MB` (65536), `COLIBRI_MEMORY_MB` (65536), `COLIBRI_ROOTFS_GB` (160), `COMFYUI_IMAGE_VARIANT` (`klein-4b`/`klein-9b`), `HF_TOKEN`, `OPENWEBUI_ADMIN_TOKEN`, `OPENWEBUI_WAIT_SECONDS` (900), `TARGETS_DIR` |

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
self-signed TLS verification defaults off; install the CA on the Proxmox
host and run the installer with `GITEA_VERIFY_TLS=true`. Protect tokens on
untrusted networks with a TLS reverse proxy. The installer tests write access by
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

