# Xolotl (DeepSeek-V4.1-Flash) inference target for Proxmox VE 9

[Xolotl](https://github.com/Indras-Mirror/Xolotl) is Indras Mirror's fork of
[Strata](https://github.com/Niko1221/Strata): Strata's engine, server and
kernels (merged at 0.1.44.1) plus its own engines for DeepSeek-V4.1-Flash
(552B MoE), GLM-5.3-Flash and the Qwen3.8 models. Like Strata, it keeps every
expert somewhere (the hottest in VRAM, tens of GiB in a pinned RAM arena, the
rest on NVMe) and serves one OpenAI- and Anthropic-compatible API.

This target runs Xolotl's **DeepSeek-V4.1-Flash** engine, the model the other
targets do not cover (GLM-5.3-Flash is the [Maya target](../maya/README.md);
Qwen3.8-Flash-Next is the [Strata target](../strata/README.md)).
`provision-lxc.sh` creates an unprivileged LXC on an NVIDIA GPU node and runs
`install-target.sh` in it, which:

- installs a CUDA toolkit without a driver (13.0 by default, `cuda-toolkit.sh`);
- fetches Xolotl and builds `ds41_generate` exactly as Xolotl's README does:
  its pinned Python packages (CMake and Ninja among them) in a venv,
  `tools/xolotl/fetch-llama.sh` (llama.cpp at Xolotl's pin plus its ggml patch),
  and CMake with `-DSTRATA_DSV41_FQ_OP=ON -DSTRATA_DSV41_HC_MIX=ON` for the
  GPU's own architecture;
- downloads the pinned
  [DeepSeek-V4.1-Flash-1017 V4](https://huggingface.co/IndrasMirror/DeepSeek-V4.1-Flash-1017-XQ-Uncensored)
  quant (163 GB) with its V4 expert ranking, tokenizer and the 5.7 GB DSpark
  draft sidecar, plus the two
  [DeepSeek-V4.1-Flash-1017](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash-1017)
  safetensors shards that hold the Engram hash tables (203 GB);
- serves it with Strata's server (`tools/v41/serve/serve_ds41.py`) as a
  hardened systemd service under its own `xolotl` account, with a generated
  API key.

The router recognizes the target as `xolotl://<CT address>` (port 8080).

## Requirements

These are upstream's, measured on one RTX 4090 (24 GB), 90 GB of DDR4 and one
NVMe drive: about 26 tok/s decode and 290-400 tok/s prefill.

- **GPU:** NVIDIA, compute capability 7.5 or newer (RTX 20/30/40/50), 24 GB of
  VRAM. 16 GB should load but is untested upstream; below 16 GB will not work.
  The installer reads GPU 0's VRAM and compute capability before installing or
  downloading weights, then builds for it (`XOLOTL_CUDA_ARCH=auto`).
- **RAM:** the CT gets 96 GiB by default and the engine pins a 60 GiB expert
  arena (`XOLOTL_ARENA_GIB`). The installer refuses an arena within 16 GiB of
  the CT's memory. Less RAM means more experts come off the disk each token;
  around 256 GB holds every expert.
- **Disk:** about 372 GB of weights. The CT's root disk defaults to 420 GiB
  (at least 380). Put it on **fast NVMe storage**: the engine reads ~48 random
  Engram rows and the missing experts from disk for every token. Not a hard
  drive, and not exFAT.
- **Host:** Proxmox VE 9 with NVIDIA driver 580.173.02 for the bundled guest
  user-space installer (or supply `NVIDIA_GUEST_INSTALLER` and
  `NVIDIA_DRIVER_VERSION` for another driver), and the GPU nodes
  `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`. A host without an
  NVIDIA driver gets one from `tools/setup-host-gpu.sh` (see
  [Hosts without an NVIDIA driver](#hosts-without-an-nvidia-driver)).
- **Templates:** Ubuntu 22.04/24.04 or Debian 12/13 amd64 (Ubuntu 24.04 is the
  default the router installer picks). Debian 13's NVIDIA repository starts at
  CUDA 13.1: set `XOLOTL_CUDA_VERSION=13.1` there.

The first install downloads the weights (hours, depending on the connection)
and then loads the model; plan for both.

## Hosts without an NVIDIA driver

The engine is compiled for one GPU generation, read from the card (compute
capability of GPU 0), so the host's NVIDIA driver must be loaded before the
provisioner runs. When `nvidia-smi` lists no GPU, `provision-lxc.sh` stops
before it creates anything (`--dry-run` only notes it) and points to
`tools/setup-host-gpu.sh`. The router installer runs that tool itself, for
every selected GPU target, before it creates any CT.

```bash
bash tools/setup-host-gpu.sh --for xolotl          # NVIDIA only, the default
```

It lists the NVIDIA GPUs on the PCI bus, stops if there is none or the card is
bound to `vfio-pci` (reserved for a VM), asks which generation the card is,
suggesting the one its codename (TU1xx, GA10x, AD10x, GB20x) points to:

| Answer | Cards | Built for | CUDA |
|---|---|---|---|
| `rtx20` (1) | GeForce RTX 20, Quadro RTX, TITAN RTX (Turing) | 7.5 (`75`) | 12.8+ |
| `rtx30` (2) | GeForce RTX 30, RTX A2000-A6000 (Ampere) | 8.6 (`86`) | 12.8+ |
| `rtx40` (3) | GeForce RTX 40, RTX Ada workstation cards (Ada Lovelace) | 8.9 (`89`) | 12.8+ |
| `rtx50` (4) | GeForce RTX 50, RTX PRO Blackwell (Blackwell) | 12.0 (`120`) | 13.0+ |

and, after a yes, installs the repository's NVIDIA **580.173.02** driver on the
host (`install_nvidia_580_173_02.sh host`): one release supports every RTX
generation, and it must be the release the CT's user-space libraries come
from. It uses NVIDIA's **open kernel modules** (required by RTX 50, supported
from RTX 20 on), built with DKMS against the running Proxmox kernel's headers.
It blacklists nouveau, loads `nvidia` and `nvidia_uvm` at once and at every
boot, and creates the `/dev/nvidia*` nodes before Proxmox starts its guests
(`nvidia-lxc-devices.service`), so the CT still finds them after a reboot. If
nouveau still holds the card, reboot the host and run it again. Unattended:
`GPU_GENERATION=rtx40 INSTALL_HOST_DRIVER=yes`; `--dry-run` installs nothing.
An NVIDIA driver the host already runs is never replaced.

Xolotl then builds for the card's real compute capability. On an RTX 50 card
`XOLOTL_CUDA_VERSION` must be 13.0 or newer (the default), and CUDA 13 needs
driver 580 or newer.

## Create and launch

From this repository's root on the Proxmox GPU host:

```bash
CT_ID=282 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.82/24 GATEWAY=192.0.2.1 \
bash targets/xolotl/provision-lxc.sh --dry-run

CT_ID=282 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.82/24 GATEWAY=192.0.2.1 \
bash targets/xolotl/provision-lxc.sh
```

Replace the template, storage and address with values from your node. The
script refuses an existing CT ID and keeps a newly created CT for inspection if
a later step fails. An interrupted download resumes where it stopped when the
installer runs again (see [Upgrade](#upgrade) for the command).

Settings (environment variables of either script):

| Setting | Default | |
|---|---|---|
| `XOLOTL_REF` / `XOLOTL_COMMIT` | tested commit in `upstream-commit.txt` | set a branch or another full commit to override it (see below) |
| `XOLOTL_CUDA_VERSION` | `13.0` | the toolkit the engine is built with (12.8 or newer; RTX 50 needs 13.x) |
| `XOLOTL_CUDA_ARCH` | `auto` | the GPU's compute capability as a number (`86`, `89`, `120`); `auto` reads GPU 0 |
| `XOLOTL_PORT` | `8080` | the API port |
| `XOLOTL_CONTEXT` | `131072` | the context (`--ctx`); the engine supports up to 512K with its 4-bit KV cache |
| `XOLOTL_ARENA_GIB` | `60` | the pinned RAM expert arena (`--arena-gib`) |
| `XOLOTL_DSPARK` | `true` | speculative decoding with the DSpark sidecar; `false` skips its 5.7 GB download and keeps ~2.9 GB of VRAM free for experts |
| `XOLOTL_MODEL_NAME` | `deepseek-v4.1-flash` | the model id the API lists |
| `XOLOTL_READY_TIMEOUT` | `1800` | seconds to wait for the model to load |

Host-side settings (`CORES=8`, `MEMORY_MB=98304`, `ROOTFS_GB=420`,
`GPU_DEVICES`, `GPU_GID=44`, `BRIDGE`, `VLAN_TAG`, `NAMESERVER`,
`SSH_PUBLIC_KEY`, ...) work as for the other GPU targets; `--help` lists them.

The engine runs with the settings of Xolotl's DeepSeek-V4.1 serve scripts:
`--rank rank-1017-v4.bin --tier-batch-pcie 0.25` (upstream's recommendation
for V4), `--arena-adapt --kv-fp4`, route bias 0.5 / file 0.3, a 12288-token
prompt batch, the dense half re-quantized to Q6_K at load (cached in
`/var/lib/xolotl/cache`), and DSpark with depth 4. The model is text-only here
(Xolotl's vision path needs its separate encoder setup).

## Connect the router

```bash
pct exec 282 -- cat /etc/xolotl-target/api-key
manage-model-servers set-xolotl-token --apply
manage-model-servers add xolotl://192.0.2.82 --tier xlarge --apply
```

`set-xolotl-token` prompts for the key. Xolotl's server is Strata's, so its
public `/health` says `"service": "strata"`; the manager tells it apart from
Strata by the DeepSeek-V4 model it reports, and an explicit `xolotl://` address
always works. The router, monitor and LiteLLM use the key from `secrets.env`,
never sending the Strata key to a Xolotl server or the other way round. The
router sizes the default model id `deepseek-v4.1-flash` as 552B for xlarge
discovery (`[model_sizes]` in `router.ini`; add a line there if you set
another `XOLOTL_MODEL_NAME`).

Logs: `pct exec 282 -- journalctl -u xolotl -f`. The CT's Proxmox firewall flag
is enabled; configure the host's actual firewall rules so only the router and
intended clients reach the API port.

## Where things are

| Path | |
|---|---|
| `/opt/xolotl` | the checkout, its venv, `third_party/llama.cpp` and `build-xolotl/ds41_generate` (read-only for the service) |
| `/var/lib/xolotl/models/v41-xq-1017-v4` | the quant, rank file, tokenizer and DSpark sidecar |
| `/var/lib/xolotl/models/engram-1017` | the Engram shards and the index the installer writes for them |
| `/etc/xolotl/xolotl-ds41.json` | the server config: engine, arguments, settings and the API key (root-owned, readable by the `xolotl` group only) |
| `/etc/xolotl-target/` | root-only records: the key, settings, verified weights; `xolotl.env` (the port) |

The key is passed to the server through its config only; it is never on a
command line, in the unit or in its environment file.

## Weights

`xolotl-weights.txt` lists every file with its size and hash, at a pinned commit
of each Hugging Face repository, so a URL always names the same object:

- Before downloading, the installer asks Hugging Face for each missing file's
  size and SHA-256 and refuses one that differs from the list, then checks the
  free disk space against what is missing.
- The 16 byte-range parts of the quant are each downloaded, verified, appended
  to the model file and deleted, so the disk never holds the parts and the
  joined model at once. The joined file is checked against its own SHA-256.
- Interrupted downloads and joins resume on the next run; a corrupt part is
  deleted and fetched again.
- Verified files are recorded (`/etc/xolotl-target/verified-weights`), so a
  rerun neither hashes ~370 GB again nor needs the network for them.
- DeepSeek's index of the Engram shards lists all 48 shards of the full model
  and has no published hash, so `engram-index.py` writes the index from the two
  verified shards' own headers instead; the engine reads the tables from them
  in place (upstream's `extract_engram.py` copy step is not needed, which saves
  203 GB of scratch space).

To move to a newer build, review its files and replace the rows (and the
revision in each URL) in `xolotl-weights.txt`. Files of the old build stay on
disk until you delete them.

## Xolotl versions

Xolotl is research code that changes many times a day. By default every run
fetches the tested commit in `upstream-commit.txt` (currently
`c17cddadd06a47b34abfb1e93ab1f710d9705c07`). This is the commit
`test-pinned-upstream.py` and CI's `xolotl-upstream` job check. Set
`XOLOTL_REF=main` on each run to follow the branch tip or `XOLOTL_COMMIT` to
use another full commit. The installer checks the checkout for the files, CMake options,
engine flags and config keys it uses before building, and a failed upgrade
rolls back.

```bash
XOLOTL_REF=main
```

Move `upstream-commit.txt` deliberately, after that check passes against the
new commit (see [Local checks](#local-checks)). The commit is not part of the
saved settings, so the next rerun of an existing install moves to the new pin.

## Upgrade

Installs made before this pin existed followed `main`. Their next rerun
without `XOLOTL_REF` moves to the pinned commit, which may be older than the
`main` they run: the installer rebuilds and prints "Upgrading Xolotl from
<their commit> to <the pin>". Set `XOLOTL_REF=main` on that rerun to stay on
the branch instead.

Every rerun of the installer, with or without `--upgrade`, keeps the
installation's settings from `/etc/xolotl-target/installed-env`. Non-empty
environment settings override the corresponding saved values, and a new
`XOLOTL_CUDA_VERSION` without `XOLOTL_NVCC` takes that release's default nvcc;
`XOLOTL_CUDA_ARCH=auto` reads the GPU again. Only a fresh install uses the
defaults. A fresh install records the settings it runs with in
`/etc/xolotl-target/pending-env` before its first change, so an install that
stops part-way (a long download, say) resumes with them. An existing checkout or
unit with no readable record requires every setting explicitly.

Copy the current files into the CT, then rerun:

```bash
for f in install-target.sh cuda-toolkit.sh engram-index.py xolotl.service xolotl-weights.txt upstream-commit.txt; do
    pct push 282 targets/xolotl/$f /root/xolotl-target-deploy/$f
done
pct exec 282 -- bash /root/xolotl-target-deploy/install-target.sh --upgrade
```

A rerun fetches the selected commit and verifies (or finishes downloading) the
weights **while the service keeps running**; if either fails, nothing is
stopped or changed. When the commit, settings, config, unit and weights are
unchanged and `/health` reports the model loaded, it does nothing. Otherwise it
stops the service and snapshots the runnable checkout (venv, llama.cpp, engine
build), unit, its environment and the server config into the root-only
`/var/lib/xolotl-target/`; then it checks out the commit, rebuilds
`ds41_generate`, rewrites the config and restarts. If any step fails, it
restores the previous commit and that snapshot at their original paths, without
building or downloading anything, and health-checks the previous service. The
snapshot is deleted after a successful upgrade or rollback and kept only when
the rollback fails too. Allow disk space for one copy of the checkout and its
build; the models are outside it.

`fetch-llama.sh` keeps any llama.cpp tree that already carries its patch, even
when a new Xolotl commit pins another llama.cpp commit, so the installer fetches
the tree again whenever its commit differs from the pin.

## Local checks

```bash
bash targets/xolotl/test-install.sh         # helpers, plus stubbed end-to-end runs as root
bash targets/xolotl/test-provision.sh       # dry-run plans and validation
bash targets/xolotl/test-cuda-toolkit.sh    # the CUDA repository table
git init /tmp/xolotl-source-check
git -C /tmp/xolotl-source-check fetch --depth 1 \
    https://github.com/Indras-Mirror/Xolotl.git "$(cat targets/xolotl/upstream-commit.txt)"
git -C /tmp/xolotl-source-check checkout -q FETCH_HEAD
python3 -m venv /tmp/xolotl-venv && /tmp/xolotl-venv/bin/pip install -r /tmp/xolotl-source-check/requirements.txt
/tmp/xolotl-venv/bin/python targets/xolotl/test-pinned-upstream.py /tmp/xolotl-source-check
```

`tests/run-tests.sh` runs the first three. `test-pinned-upstream.py` needs the
network and runs as CI's separate `xolotl-upstream` job: it sends the config
the installer writes through the pinned server's own config, engine-argument
and environment code, checks that the engine reads every flag and `STRATA_*`
setting it sets, that `/health` still reports what the readiness probe and the
manager's detection read, and that the Engram index matches what the engine
looks up. None of these build the engine, download a model or need a GPU.
