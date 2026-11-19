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

**No model is downloaded.** The service starts *parked* until you copy one in;
see [Placing a model](#placing-a-model).

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
  will place: Qwen3.6-35B-A3B is a 23 GB download and runs in 16 GB of RAM;
  GLM-5.2 needs 429 GB of disk. More RAM keeps more experts resident.

It adds the CT to the router's server list up front, then, once the CT is
built, reads `/etc/colibri-target/api-key` and gives it to the router with
`set-colibri-token`. Until a model is placed, the router and the monitor see
the server as down.

## Standalone

From the repository root on the Proxmox VE 9 host:

```bash
bash targets/colibri/provision-lxc.sh      # interactive
CT_ID=251 TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.51/24 GATEWAY=192.0.2.1 \
bash targets/colibri/provision-lxc.sh --dry-run     # then without --dry-run
```

`GPU_DEVICES` is empty by default (the CPU). For CUDA pass
`'/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'` (plus `/dev/nvidia-uvm-tools`
when the host has it); the CT then gets NVIDIA user space matching the host's
driver (580 series or newer). For Vulkan pass the card's render node, e.g.
`/dev/dri/renderD128`. Both are mapped with `gid=44` (video), which the
`colibri` account joins. `COLIBRI_BACKEND=cuda` or `vulkan` without its device
is refused. A host without the GPU's driver: `bash tools/setup-host-gpu.sh`.

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
model, replace the directory's contents and restart. `COLIBRI_MODEL_DIR` moves
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
| `/root/colibri-target-deploy/` | the pushed installer and unit |

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
