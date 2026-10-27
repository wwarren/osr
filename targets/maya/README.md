# Project Maya inference target for Proxmox VE 9

On an interactive Proxmox run, `provision-lxc.sh` lists downloaded compatible templates and active `rootdir` storage with enough free space for `ROOTFS_GB`. Set `TEMPLATE` and `STORAGE` to skip the menus. Dry runs make no Proxmox queries, so supply those values explicitly.

This target follows the Strata LXC install pattern. Run
`provision-lxc.sh` on an NVIDIA GPU Proxmox host to create an unprivileged CT,
pass its GPU devices through, install the matching NVIDIA user-space driver,
fetch [Project Maya](https://github.com/mw00/project-maya), download the
selected GLM-5.3-Flash quant, and start a hardened systemd service. A random
API key is generated inside the CT.

Maya's [requirements and setup options](https://github.com/mw00/project-maya/blob/main/docs/SETUP.md)
apply: compute capability 7.0 or newer, CUDA 12.x, Python 3.10+, at least
32 GiB RAM, and a fast NVMe volume with room for the model and build files.
The default Maya-S quant is about 96.5 GB. The provisioner defaults to
64 GiB RAM and a 160 GiB root disk; select Proxmox storage backed by NVMe.
This script supports NVIDIA Linux guests. Maya's AMD and Windows paths require
their separate upstream setup.
The target installs a CUDA 12.8 toolkit without a kernel driver inside the CT,
into `/usr/local/cuda-12.8`, and builds Maya with exactly that `nvcc`
(`--nvcc`), even when another toolkit is present. Set `MAYA_CUDA_VERSION` for
another supported toolkit; CUDA 13 does not support V100 GPUs.

The toolkit comes from NVIDIA's apt repository for the CT's distribution, and
not every repository carries every release:

| Template | CUDA releases in NVIDIA's repository | Maya default (12.8) |
|---|---|---|
| Ubuntu 24.04 | 12.5 and later | yes |
| Ubuntu 26.04 | 13.3 and later | **no**: set `MAYA_CUDA_VERSION=13.3` or later (no V100) |
| Ubuntu 22.04 | 11.7 and later | yes |
| Debian 12 | 12.3 and later | yes |
| Debian 13 | 13.1 and later | **no**: set `MAYA_CUDA_VERSION=13.1` or later (no V100) |

`provision-lxc.sh` and `install-target.sh` refuse a combination the repository
cannot provide before anything is created or changed. A toolkit of exactly
`MAYA_CUDA_VERSION` already installed at `MAYA_NVCC` (from a runfile, say) is
accepted whatever the repository carries. For a V100, use an Ubuntu 22.04/24.04
or Debian 12 template. The router installer picks Debian 13 (then Ubuntu
26.04) and selects CUDA 13.1 or 13.3 for them unless `MAYA_CUDA_VERSION` is
explicitly set; when the host's GPU 0 is older than compute capability 7.5 it
picks Ubuntu 24.04 instead, so Maya keeps its CUDA 12.8 default.

## Install

From this repository's root on the Proxmox GPU host:

```bash
CT_ID=281 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1 \
bash targets/maya/provision-lxc.sh --dry-run

CT_ID=281 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1 \
bash targets/maya/provision-lxc.sh
```

Replace the template, storage and address with values from your node. The
bundled guest NVIDIA installer requires host driver **580.173.02**. For another
host driver, supply a matching `NVIDIA_GUEST_INSTALLER` and
`NVIDIA_DRIVER_VERSION`. For more than one GPU, set `GPU_DEVICES` to every
`/dev/nvidiaN` you want, plus `/dev/nvidiactl` and `/dev/nvidia-uvm`.
The script refuses an existing CT ID and keeps a newly created CT for
inspection if setup fails.

The guest installer uses `MAYA_MODEL=Maya-S-v2-IQ2_XXS` by default. Set
`MAYA_MODEL` to another name listed by the checked-out `setup.sh --help`,
such as `Maya-S24`, `Maya-M`, or `Maya-L`. Other settings include
`MAYA_CONTEXT=32768`, `MAYA_DRAFT=mtp`, `MAYA_NO_VISION=false`,
`MAYA_CUDA_VERSION=12.8`, `MAYA_PORT=8080`, and
`MAYA_READY_TIMEOUT=900`. Setup receives `--yes --download-model --no-start`,
so it downloads and builds without an interactive prompt; the service then
starts the generated `run-maya-*.sh` script. Models are stored under
`/var/lib/maya/models`.

`MAYA_DRAFT` is always passed as `--draft` (when the checkout has it), so a
rerun never keeps an earlier DFlash2 choice by accident. `MAYA_DRAFT=dflash2`
selects the DFlash2 drafter: it downloads another 0.7 GB, its license allows
non-commercial use only, and Maya's first start then runs a 5-20 minute speed
calibration, so raise `MAYA_READY_TIMEOUT` (for example to 2400) with it.

By default each run installs the newest `vX.Y.Z` release tag
(`MAYA_REF=latest`), the same releases Maya's own updater offers. Set
`MAYA_REF=main` to follow the branch, or `MAYA_COMMIT` to a tested full
40-character commit ID for repeatable deployments. The installer checks the
upstream options, selected model and draft before setup, and an upgrade keeps
the previous commit available locally for rollback.

The unit sets `MAYA_UPDATE_CHECK=0`. Keep it: without it, Maya's dashboard
(About > Updates) can update `/opt/maya` itself, behind the installer's
pinned commit and rollback ref. Upgrade with `install-target.sh --upgrade`.

## Connect the router

```bash
pct exec 281 -- cat /etc/maya-target/api-key
manage-model-servers set-maya-token --apply
manage-model-servers add maya://192.0.2.81 --tier xlarge --apply
manage-model-servers set-server-model xlarge maya://192.0.2.81 glm-5.3-flash --apply
```

`set-maya-token` prompts for the generated key. Maya's public `/health`
identifies the service to the manager; an explicit `maya://` address also
works when auto-detection is unavailable. Use `maya://host:port` for a
nondefault port. The router, monitor and LiteLLM use the key from
`secrets.env`; the monitor checks `/v1/models` and reports the host down while
it lists no model (Maya's answer while its engine is not running). The router
assigns the known model ID `glm-5.3-flash` a 321B parameter size for xlarge
discovery (`[model_sizes]` in `router.ini`).

Logs: `pct exec 281 -- journalctl -u maya -f`. The API is on TCP 8080 by
default. The CT's Proxmox firewall flag is enabled; configure the host's
actual firewall rules so only the router and intended clients can reach it.

## Upgrade

Every rerun of the installer, with or without `--upgrade`, keeps the
installation's settings from `/etc/maya-target/installed-env`, including custom
model, context and port values. An install from before that record existed uses
its `installed-settings` fingerprint instead. Non-empty environment settings
override the corresponding saved values, and a new `MAYA_CUDA_VERSION` without `MAYA_NVCC` takes that release's default nvcc.
Only a fresh install uses the defaults. A fresh install records the settings
it runs with in `/etc/maya-target/pending-env` before its first change, so a
first install that stops part-way resumes with them on the next run;
the file is removed once the install succeeds. An existing checkout or service
unit with no readable record (missing, unreadable or dangling) requires every
setting explicitly before the installer can proceed. A malformed `installed-env`
must be repaired or removed before retrying.

Copy the current installer and unit into the CT, then rerun:

```bash
pct push 281 targets/maya/install-target.sh /root/maya-target-deploy/install-target.sh --perms 0755
pct push 281 targets/maya/maya.service /root/maya-target-deploy/maya.service --perms 0644
pct push 281 targets/maya/cuda-toolkit.sh /root/maya-target-deploy/cuda-toolkit.sh --perms 0755
pct exec 281 -- bash /root/maya-target-deploy/install-target.sh --upgrade
```

A rerun lists the release tags and fetches while the service remains up; a
newer release than the installed one is an upgrade. When commit, settings, unit,
and health are unchanged, it does nothing. Otherwise it stops Maya, runs
upstream setup again, restarts, and waits for `/health` to report `status=ok`
and `/v1/models` to list the loaded model.
Before changing the checkout it stops the service and saves its runnable
checkout, venv, launcher and unit. If the upgrade fails, it restores that
snapshot at the original paths and health-checks the previous service; setup,
pip and compilation are not needed during rollback. Healthy unchanged reruns
also backfill missing `installed-env` records from
older installations.

## Local checks

```bash
bash targets/maya/test-install.sh      # helpers, plus stubbed end-to-end runs as root
bash targets/maya/test-provision.sh    # dry-run plans and validation
```

These checks do not create a CT or download a model. `tests/run-tests.sh`
runs both. CI's `maya-upstream` job also runs `test-pinned-run-script.py`
against Maya's real code at the pinned release: the start-script line setup
prints, the setup options, the update switch and the empty model list. Move
its `PIN` when moving to a newer release. A complete install requires the
Proxmox host, GPU and upstream model download.

The root-only `/var/lib/maya-target/` holds the runtime snapshot (including any
configuration secrets) during an upgrade. It is deleted once the upgrade or the
rollback succeeds, and kept for inspection only when the rollback fails too.
Allow disk space for one copy of the checkout, in addition to the model and
build. The default `/var/lib/maya` model store is outside the snapshot; weights
placed inside `/opt/maya` are copied with that checkout.
A snapshot failure aborts the upgrade and restarts the original service.
