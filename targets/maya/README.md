# Project Maya inference target

Follows the Strata pattern: `provision-lxc.sh` creates an unprivileged LXC on
an NVIDIA GPU host, passes the GPU through, installs host-matched NVIDIA
user-space, fetches [Project Maya](https://github.com/mw00/project-maya),
downloads the selected GLM-5.3-Flash quant and starts the hardened `maya`
service with a key generated in the CT. Register it as `maya://<CT address>`
(port 8080). Only NVIDIA Linux guests are supported; Maya's AMD and Windows
paths need upstream's own setup.

Maya's [requirements](https://github.com/mw00/project-maya/blob/main/docs/SETUP.md):
compute capability 7.0+, Python 3.10+, 32 GiB RAM or more and fast NVMe. The
default Maya-S quant is about 96.5 GB; defaults are 8 cores, 64 GiB RAM and a
160 GiB disk, so pick NVMe-backed storage.

## CUDA

The target installs a driverless CUDA toolkit (default 12.8) into
`/usr/local/cuda-<version>` and builds with exactly that `nvcc` (`--nvcc`),
even if another toolkit is present. NVIDIA's repositories do not carry every
release:

| Template | Releases in NVIDIA's repository | Default 12.8 |
|---|---|---|
| Ubuntu 22.04 | 11.7+ | yes |
| Ubuntu 24.04 | 12.5+ | yes |
| Debian 12 | 12.3+ | yes |
| Debian 13 | 13.1+ | **no**: `MAYA_CUDA_VERSION=13.1`+ |
| Ubuntu 26.04 | 13.3+ | **no**: `MAYA_CUDA_VERSION=13.3`+ |

CUDA 13 does not support V100 (compute capability 7.0); use Ubuntu 22.04/24.04
or Debian 12 there. Both scripts refuse a combination the repository cannot
provide before changing anything, unless exactly `MAYA_CUDA_VERSION` is already
installed at `MAYA_NVCC` (e.g. from a runfile). The router installer picks
Debian 13 (then Ubuntu 26.04) with 13.1/13.3, but Ubuntu 24.04 and 12.8 when GPU
0 is below compute capability 7.5.

## Install

```bash
CT_ID=252 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.52/24 GATEWAY=192.0.2.1 \
bash targets/maya/provision-lxc.sh --dry-run     # then without --dry-run
```

Missing address, gateway, template and storage are prompted for on a
terminal (no address is chosen automatically); the CT ID defaults to the
cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID`
to choose another). Dry runs query nothing, so they need `CT_ID`, `TEMPLATE`
and `STORAGE`. `NVIDIA_DRIVER_VERSION=auto` (or an exact version to require). For
several GPUs, set `GPU_DEVICES` to every `/dev/nvidiaN` plus `/dev/nvidiactl`
and `/dev/nvidia-uvm`. GPU node group and memlock handling are as in the
[Strata target](../strata/README.md#requirements). An existing CT ID is
refused; a failed new CT is kept for inspection.

| Setting | Default | Notes |
|---|---|---|
| `MAYA_MODEL` | `Maya-S-v2-IQ2_XXS` | Any name the checkout's `setup.sh --help` lists (`Maya-S24`, `Maya-M`, `Maya-L`, ...) |
| `MAYA_CONTEXT` | 65536 | |
| `MAYA_DRAFT` | `mtp` | Always passed as `--draft`. `dflash2` downloads 0.7 GB more, is licensed non-commercial only, and adds a 5–20 minute calibration on first start (raise `MAYA_READY_TIMEOUT`, e.g. 2400) |
| `MAYA_NO_VISION` | false | |
| `MAYA_CUDA_VERSION`, `MAYA_NVCC` | 12.8, `/usr/local/cuda-<ver>/bin/nvcc` | See above |
| `MAYA_PORT`, `MAYA_READY_TIMEOUT` | 8080, 900 | |
| `MAYA_REF`, `MAYA_COMMIT` | `latest` (newest `vX.Y.Z` tag) | `main` follows the branch; a full commit pins it |

Setup gets `--yes --download-model --no-start`; the unit then runs the
generated `run-maya-*.sh`. Models live in `/var/lib/maya/models`. The installer
checks options, model and draft against the checkout before setup.

The unit sets `MAYA_UPDATE_CHECK=0`. Keep it: otherwise Maya's dashboard
(About > Updates) can update `/opt/maya` behind the installer's pin and
rollback. Upgrade with `install-target.sh --upgrade`.

## Connect the router

```bash
pct exec 252 -- cat /etc/maya-target/api-key
manage-model-servers set-maya-token --apply
manage-model-servers add maya://192.0.2.52 --tier xlarge --apply
manage-model-servers set-server-model xlarge maya://192.0.2.52 glm-5.3-flash --apply
```

Maya's public `/health` identifies it to the manager; use `maya://host:port`
for another port. The monitor reports it down while `/v1/models` is empty
(engine not running). `glm-5.3-flash` is sized 321B by `[model_sizes]`. The key
is also Maya's dashboard admin key, so restrict TCP 8080 to the router and
intended clients (the CT's firewall flag is on, without rules). Logs:
`pct exec 252 -- journalctl -u maya -f`.

## Upgrade

```bash
pct push 252 targets/maya/install-target.sh /root/maya-target-deploy/install-target.sh --perms 0755
pct push 252 targets/maya/maya.service /root/maya-target-deploy/maya.service --perms 0644
pct push 252 targets/maya/cuda-toolkit.sh /root/maya-target-deploy/cuda-toolkit.sh --perms 0755
pct exec 252 -- bash /root/maya-target-deploy/install-target.sh --upgrade
```

A rerun lists release tags and fetches while Maya runs; a newer release is an
upgrade. Nothing happens if commit, settings, unit and health are unchanged.
Otherwise it stops Maya, re-runs setup, and waits for `/health` `status=ok`
and the model in `/v1/models`.

**Settings record.** Every rerun reuses `/etc/maya-target/installed-env`
(older installs: the `installed-settings` fingerprint); non-empty environment
values override it, and a new `MAYA_CUDA_VERSION` without `MAYA_NVCC` takes
that release's `nvcc`. Only a fresh install uses defaults; it writes
`pending-env` first so an interrupted first install resumes. An existing
checkout or unit without a readable record needs every setting explicitly;
repair or remove a malformed `installed-env`. Healthy unchanged reruns
backfill a missing record.

**Rollback.** Before changing the checkout it snapshots the runnable checkout,
venv, launcher and unit to the root-only `/var/lib/maya-target/` (a snapshot
failure restarts the original). On failure it restores them without setup, pip
or compilation and health-checks the old service. The snapshot can contain
secrets and is deleted after success or rollback; if the rollback also fails,
it is kept beside a `rollback-failed` marker and every later run stops until
you inspect or restore it and delete the marker. Leave disk for one checkout
copy; `/var/lib/maya` is not copied (weights inside `/opt/maya` are).

## Checks

`bash targets/maya/test-install.sh` (stubbed end-to-end runs need root) and
`test-provision.sh` (dry-run plans, validation) create nothing. CI's
`maya-upstream` job runs `test-pinned-run-script.py` against Maya's code at
its `PIN`: the start-script line setup prints, setup options, the update
switch and the empty model list. Move `PIN` with each newer release you adopt.
