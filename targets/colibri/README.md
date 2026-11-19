# Colibri inference target

[colibri](https://github.com/JustVugg/colibri) is an inference engine for large
mixture-of-experts models: it keeps a model's always-used weights in RAM and
spreads the routed experts over the GPU (hot), RAM (warm) and NVMe (cold,
streamed). Its engines are C; `coli`, its Python launcher, serves an
OpenAI-compatible API (`/v1/chat/completions`, `/v1/models`, tool calls on every
chat engine except Inkling and OLMoE). It is **CPU-first**: every engine runs on
the CPU, with CUDA (NVIDIA) and Vulkan (AMD Radeon, Intel Arc) as options.

`provision-lxc.sh` creates an unprivileged LXC, builds colibri from a pinned
commit into `/opt/colibri`, and runs `coli serve` as the hardened `colibri`
service with an API key generated in the CT. OSR knows it as the `colibri`
server kind: `colibri+http://<CT address>:8080`, key `COLIBRI_API_KEY`
(`manage-model-servers set-colibri-token`).

Defaults: port **8080**, 8 cores (`CORES`), 64 GiB RAM (`MEMORY_MB`, at least
8192), 160 GiB disk (`ROOTFS_GB`, at least 40), backend `auto`, model directory
`/var/lib/colibri/model`.

Setup suggests a model after GPU and RAM selection and asks before downloading
it. Press Enter to skip; the service starts *parked* until you copy one in.
See [Placing a model](#placing-a-model).

## With the OSR installer

`colibri` is in the installer's menu with the CPU-or-optional-GPU model
servers. For it the installer asks:

- **Which GPU**, from the host's NVIDIA, AMD Radeon RX 7000/9000 and Intel Arc
  cards, or `none` (CPU). An NVIDIA card gives `COLIBRI_BACKEND=cuda` and its
  `/dev/nvidia<minor>`, control and UVM nodes; an AMD or Intel card gives
  `COLIBRI_BACKEND=vulkan` and its render node; `none` gives `cpu`. Presets:
  `COLIBRI_GPU_CARD` (a PCI address or `none`), `COLIBRI_BACKEND`, `GPU_DEVICES`.
- **Template**: Debian 13 (first; its Mesa 25 is what the Vulkan lane wants),
  Debian 12, Ubuntu 24.04 or 22.04.
- **RAM** (`COLIBRI_MEMORY_MB`, default 65536, at least 8192) and **disk**
  (`COLIBRI_ROOTFS_GB`, default 160, at least 40). Size both for the model you
  will place: Qwen3.6-35B-A3B is a 23 GB download, needs at least 10 GB RAM
  (20 GB preferred). GLM-5.2 needs 429 GB of disk. More RAM keeps more experts
  resident.
- **Model**: a menu of every text model in the
  [tested Colibri catalog](https://github.com/JustVugg/colibri/blob/0a5504a1dc64f86fcd0fe7db298b0448c730e7e6/c/setup_catalog.py),
  from Qwen3-Coder-30B-A3B (19.4 GB) to Kimi K3 (1561 GB), each marked
  `fits` or with what it lacks (RAM, or room on the root disk less about
  10 GiB). The one that runs from RAM best on this CT is marked `(suggested)`:
  Qwen3.6-35B-A3B with at least 20 GiB on the CPU or 10 GiB with a GPU,
  otherwise Qwen3-Coder-30B-A3B. Enter downloads nothing. Unattended, set
  `COLIBRI_MODEL_ID=<id>` to download one; unset or `none` skips it. See
  [Downloading a catalog model](#downloading-a-catalog-model).

It adds the CT to the router's server list up front, then, once the CT is
built, reads `/etc/colibri-target/api-key` and gives it to the router with
`set-colibri-token`. If the download was skipped, the router and monitor see
the parked server as down until a model is placed.

## Standalone

From the repository root on the Proxmox VE 9 host:

```bash
bash targets/colibri/provision-lxc.sh      # interactive
CT_ID=251 TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.51/24 GATEWAY=192.0.2.1 \
bash targets/colibri/provision-lxc.sh --dry-run     # then without --dry-run
```

The standalone provisioner shows the same model menu after detecting the GPU.
To choose without a prompt, set `COLIBRI_MODEL_ID=<id>`; unattended without
it, nothing is downloaded and the provisioner says which ID it would suggest.

With `GPU_DEVICES` empty (the default) the provisioner finds the host's GPU the
way the OSR installer does: `tools/setup-host-gpu.sh` checks the driver for an
NVIDIA, AMD Radeon RX 7000/9000 or Intel Arc card and, if it is missing, offers
to install it (on a terminal; unattended, `INSTALL_HOST_DRIVER=yes` and
`GPU_GENERATION=<gen>`). It may ask for a reboot, after which you run the
provisioner again. An NVIDIA card gives `COLIBRI_BACKEND=cuda`, its
`/dev/nvidia<minor>`, control and UVM nodes, and NVIDIA user space in the CT
matching the host's driver (580 series or newer); an AMD or Intel card gives
`COLIBRI_BACKEND=vulkan` and its render node. With no usable card the CT runs
on the CPU, and the provisioner says so. `GPU_CARD=<PCI address>` picks the
card on a host with several; `COLIBRI_BACKEND=cpu` skips the search;
`COLIBRI_BACKEND=cuda` or `vulkan` stops unless that vendor's GPU is ready.

Or name the devices: `GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'`
(plus `/dev/nvidia-uvm-tools` when the host has it) for CUDA, or the card's
render node, e.g. `/dev/dri/renderD128`, for Vulkan. Both are mapped with
`gid=44` (video), which the `colibri` account joins.

Then on OSR:

```bash
pct exec <id> -- cat /etc/colibri-target/api-key
manage-model-servers set-colibri-token            # paste the key
manage-model-servers add colibri://192.0.2.51 --tier large --apply
```

A keyed Colibri cannot be identified without its key, so add it as
`colibri://host` (or `--type colibri`).

The provisioner never deletes a CT and stops if the ID exists. A failed step
keeps the CT; resume or upgrade with
`pct exec <id> -- bash /root/colibri-target-deploy/install-target.sh`.

## Changing the model

One model is served at a time; picking another replaces it. Three ways in:

```bash
bash targets/colibri/provision-lxc.sh --reconfigure            # on the host: the menu
CT_ID=251 COLIBRI_MODEL_ID=glm-5.3 bash targets/colibri/provision-lxc.sh --reconfigure --dry-run
pct exec <id> -- bash /root/colibri-target-deploy/install-target.sh --model   # in the CT
```

`--reconfigure` takes `CT_ID` (or the one CT tagged `colibri` on the node),
reads its memory, GPU line, model directory, free disk and current model, shows
the menu (Enter keeps the current model, `r` removes it), pushes the current
deployment files and runs `install-target.sh --model` in the CT. Unattended,
`COLIBRI_MODEL_ID` is an ID, `keep` or `remove`. `tools/upgrade-all.sh` asks for
each Colibri CT whether to serve another model after its upgrade (default no;
unattended and dry runs keep it).

`install-target.sh --model`:

- downloads the new model into its stage while the current one keeps serving
  (the free-space check counts both; unfinished downloads of other models are
  removed first);
- stops the service, moves the served files aside and the new ones in (each
  phase recorded in the publication marker, so any interrupted run finishes
  it), restarts and waits for `/v1/models`; the old files stay aside until the
  new model answers, including across a plain `--upgrade` rerun;
- if the new model does not answer, swaps the previous one back, restarts it,
  keeps the download to try again, and fails;
- on success deletes the replaced model when it was a catalog download (it can
  be fetched again); a model placed by hand is kept in
  `/var/lib/colibri/model-replaced-<time>` for you to delete;
- `remove` takes the served model away the same way and leaves the service
  parked.

## Source and build

The installer **pins by default**: with neither `COLIBRI_COMMIT` nor
`COLIBRI_REF` set it installs `COLIBRI_DEFAULT_COMMIT`
(`0a5504a1dc64f86fcd0fe7db298b0448c730e7e6`, upstream `main` when this target
was written and checked; `test-pinned-upstream.py` and the `colibri-upstream`
CI job check the target against that commit). Set `COLIBRI_REF` to follow a
branch, or `COLIBRI_COMMIT` to pin another SHA.

One `make -C c install PREFIX=/opt/colibri`, as the `colibri` account, builds
every engine and installs `coli` to `/opt/colibri/bin` and the engines to
`/opt/colibri/libexec/colibri` (where `coli` looks for them). Nothing goes to
`/usr/local`, and a rollback of the checkout takes the build with it. The
backend decides the make flags:

| Backend | Chosen by `auto` when | Build | Installs |
|---|---|---|---|
| `cuda` | NVIDIA nodes are in the CT | `CUDA=1 CUDA_HOME=<toolkit>` | NVIDIA's `cuda-toolkit-13-x` when no `nvcc` is found |
| `vulkan` | a render node is in the CT | `VK=1` | `mesa-vulkan-drivers libvulkan1 libvulkan-dev glslc spirv-headers vulkan-tools`; `vulkaninfo` must show the `colibri` account a GPU |
| `cpu` | neither | — | nothing |

An explicit backend the CT cannot honour is warned about and built for the CPU.
The backend actually built is part of the settings fingerprint, so passing a
GPU in later (or taking it away) makes the next run rebuild for it.

## The service

The generated launcher, `/opt/colibri/run-colibri.sh`, runs what upstream's own
`coli start` runs:

```bash
coli serve --host 0.0.0.0 --port 8080 --allowed-host '*' \
  --model /var/lib/colibri/model --auto-tier [--gpu auto]
```

- `--auto-tier` applies colibri's RAM/VRAM plan (without it most families run
  a fixed default expert cache); `--gpu auto` puts the plan's VRAM tier on a
  CUDA card. A Vulkan build also gets `COLI_VULKAN=1` (without it a Vulkan
  engine stays on the CPU) and `COLI_VK_SHADERS=/opt/colibri/c/shaders`.
- **`--allowed-host '*'`.** colibri's DNS-rebinding guard accepts only loopback,
  the bind address and `--allowed-host` names. Bound to `0.0.0.0`, the router
  reaches it by the CT's address, which the CT cannot know in advance (DHCP, a
  hostname, a proxy), so `*`, upstream's own advice for a public bind. The API
  key still guards every request. `COLIBRI_ALLOWED_HOST` takes a
  comma-separated list instead.
- **The key** is in `/etc/colibri-target/api-key` (0600) and reaches
  `coli serve` as `COLI_API_KEY` from `/etc/colibri-target/secrets.env` (0600),
  which systemd reads before it drops to the `colibri` account. It is never on
  a command line, in the unit, the launcher or the logs.
- The unit runs `/bin/sh ${COLIBRI_RUN_SCRIPT}`; the path is in
  `/etc/colibri-target/colibri.env`. `ProtectSystem=strict`, no capabilities,
  writable paths `/opt/colibri` and `/var/lib/colibri` only,
  `LimitMEMLOCK=infinity` (the CT gets `lxc.prlimit.memlock: unlimited`).

Health is `GET /v1/models` with the key; it lists the served model as
`owned_by: colibri` with its `context_length`, input modalities and
capabilities. The router sizes the ids colibri announces without a size
(`qwen3.6-colibri`, `glm-5.2-colibri`, ...) from `[model_sizes]` and does not
offer an image or decision model (Qwen-Image, Laya, GLiNER) for chat.

## Downloading a catalog model

`COLIBRI_MODEL_ID` names one of colibri's text models in `model-select.sh`,
each pinned to a Hugging Face commit (`test-pinned-upstream.py` keeps the table
equal to colibri's catalog at the tested pin):

| ID | Model | Download | RAM at least (good) | Repository @ commit |
|---|---|---|---|---|
| `qwen3-coder-30b` | Qwen3-Coder-30B-A3B | 19.4 GB | 8 GiB (18) | `Justvugg/Qwen3-Coder-30B-A3B-colibri-int4` @ `d839110a` |
| `qwen36-35b` | Qwen3.6-35B-A3B | 23.1 GB | 10 GiB (20) | `Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64` @ `c619aa59` |
| `deepseek-v4-flash-reap` | DeepSeek V4 Flash REAP 150B | 84.7 GB | 16 GiB (32) | `puwaer/DeepSeek-V4-Flash-0731-reap-150b` @ `7c76db22` |
| `deepseek-v4-flash` | DeepSeek V4 Flash | 166.9 GB | 16 GiB (32) | `deepseek-ai/DeepSeek-V4-Flash-0731` @ `7872f01b` |
| `mimo-v2.6-flash` | MiMo-V2.6 Flash | 171.8 GB | 32 GiB (52) | `XiaomiMiMo/MiMo-V2.6-Flash-MOPD` @ `5220c3f5` |
| `qwen38-flash-next` | Qwen3.8-Flash-Next | 185.6 GB | 24 GiB (32) | `Qwen/Qwen3.8-Flash-Next-FP8` @ `bcd9f01d` (upstream's pin) |
| `glm-5.3` | GLM-5.3 | 419.3 GB | 16 GiB (24) | `Justvugg/GLM-5.3-colibri-int4-g64` @ `3930f4bb` |
| `glm-5.2` | GLM-5.2 | 429.3 GB | 16 GiB (24) | `mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp` @ `6bbb01ed` |
| `inkling` | Inkling | 514.1 GB | 120 GiB (128) | `nbeerbower/Inkling-colibri-int4` @ `3981e658` |
| `mimo-v2.6-pro` | MiMo-V2.6 Pro | 563.6 GB | 54 GiB (64) | `XiaomiMiMo/MiMo-V2.6-Pro-MOPD` @ `da71ee15` |
| `kimi-k3` | Kimi K3 | 1561.0 GB | 32 GiB (64) | `moonshotai/Kimi-K3` @ `f831ab66` |

The two MiMo models skip what the engine never reads (`dflash/`,
`audio_tokenizer/`, `model_mtp.safetensors`), as colibri's catalog does; Kimi
K3 gets its `tokenizer.json` from colibri's `tools/k3_tokenizer.py` before it
is published. The large models stream their experts from disk. Qwen-Image is
left out: it is an image model, not a chat server.

An install or rerun downloads it only when the model directory holds no model
(to replace a served model, see [Changing the model](#changing-the-model)):

```bash
pct exec <CT_ID> -- env COLIBRI_MODEL_ID=qwen36-35b bash /root/colibri-target-deploy/install-target.sh
```

- colibri's own downloader (`setup_download.py`, installed with colibri) does
  the transfer as the `colibri` account. It uses Python's standard library
  only, so nothing is installed from PyPI. It checks every file against the
  commit's SHA-256 listing.
- It stops before fetching anything when the model's filesystem lacks the
  remaining download plus 1 GiB.
- Files land in an ID- and revision-specific folder under
  `/var/lib/colibri/model/.colibri-staging`, on the model's own filesystem even
  when that is a separate mount. A publication marker keeps the launcher parked
  while files move, then records validation while the service starts. Staging
  from another model is never published with the selected one.
- An interrupted download is resumed by the same command. An interrupted
  publication is finished by any later run, with or without
  `COLIBRI_MODEL_ID` (upgrade-all's plain `--upgrade` included); while files
  are still moving, the launcher parks and logs the interruption.
- After a publication every stage is removed. A plain rerun keeps an
  unfinished download and names the ID that resumes it.
- On an installed CT, the run then restarts the service; nothing is rebuilt.
- `COLIBRI_MODEL_ID` is not recorded as a setting, so later runs and upgrades
  never download anything unless asked.

## Placing a model

A parked service logs one line (`journalctl -u colibri`) and stays inactive:
its launcher exits 0 while the model directory is empty, and checks again at
every start. As root in the CT:

```bash
# 1. put a model directory colibri reads in /var/lib/colibri/model: a
#    Hugging Face safetensors checkout copied there, or a GGUF imported into
#    it (link mode: the weights stay in the GGUF, which must stay in place):
#    runuser -u colibri -- /opt/colibri/bin/coli import \
#      /var/lib/colibri/<file>.gguf --model /var/lib/colibri/model
#    (colibri's README lists the models and formats it supports)
chown -R colibri:colibri /var/lib/colibri
# 2. start it
systemctl restart colibri
journalctl -u colibri -f
```

Rerunning `install-target.sh` does the same (it restarts a parked or stopped
service and rebuilds only if that does not bring it back). To serve another
model, use [Changing the model](#changing-the-model) (or replace the
directory's contents and restart). `COLIBRI_MODEL_DIR` moves
the directory (it must be under `/var/lib/colibri`); changing it is a settings
change, so the next run re-applies the build.

Keep disk and RAM in mind: the weights must fit on the CT's disk (or a mount
under `/var/lib/colibri`), and RAM decides how many experts stay resident.
On the CPU a large model answers slowly; raise the router's
`read_timeout_seconds` if the first token takes longer than its 300 s.

## Upgrade

`tools/upgrade-all.sh` upgrades the CT (it finds it by its `osr-target` and
`colibri` tags), or by hand:

```bash
pct push <id> targets/colibri/install-target.sh /root/colibri-target-deploy/install-target.sh --perms 0755
pct push <id> targets/colibri/colibri.service /root/colibri-target-deploy/colibri.service --perms 0644
pct push <id> targets/colibri/model-select.sh /root/colibri-target-deploy/model-select.sh --perms 0644
pct exec <id> -- bash /root/colibri-target-deploy/install-target.sh --upgrade
```

Reruns keep the recorded settings (`/etc/colibri-target/installed-env`);
non-empty environment values override them. The model directory is never
fetched, moved or rewritten.

- The same commit, settings, built backend and unit, serving (or parked
  without a model): **nothing to do**.
- The same but not serving: restart; rebuild only if that fails.
- A fetch failure stops nothing and changes nothing.
- Otherwise the previous commit stays reachable (`refs/colibri/previous`), the
  runnable checkout, unit and env file are snapshotted to
  `/var/lib/colibri-target`, and a failed upgrade restores all of it offline,
  restarts the service and checks it again. A rollback that does not come back
  keeps its snapshot and a `rollback-failed` marker, and every later run stops
  until someone removes it (`Rollback to <commit> failed too`).

## Paths

| Path | What it holds |
| --- | --- |
| `/opt/colibri` | checkout, `bin/coli`, `libexec/colibri/` engines, `run-colibri.sh` |
| `/var/lib/colibri` | the model directory and the account's HOME |
| `/etc/colibri-target/colibri.env` | `COLIBRI_RUN_SCRIPT` |
| `/etc/colibri-target/secrets.env` | `COLI_API_KEY` (0600) |
| `/etc/colibri-target/api-key` | the key (0600), read by the OSR installer |
| `/etc/colibri-target/installed-env`, `installed-settings` | the last good settings and their fingerprint |
| `/root/colibri-target-deploy/` | the pushed installer, model catalog and unit |

The CT's firewall flag is on with no rules: restrict port 8080 to the router
and intended clients.

## Checks

```bash
bash targets/colibri/test-install.sh         # settings, backends, records, launcher
bash targets/colibri/test-provision.sh       # dry-run plans, GPU devices, validation
bash targets/colibri/test-upgrade.sh         # install, park, restart, upgrade, rollback
                                             # (needs root; re-execs in a user namespace)
python3 targets/colibri/test-pinned-upstream.py /path/to/fetched/colibri
```

None downloads a model or needs a GPU. `tests/test-repo.sh` keeps the unit's
hardening and the upgrade contract.
