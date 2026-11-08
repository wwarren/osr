# Basalt inference target

`provision-lxc.sh` creates an unprivileged LXC on a Blackwell GPU host,
installs host-matched NVIDIA user-space and a CUDA 13 toolkit, builds the
[Basalt engine](https://github.com/jesdga95/basalt), downloads one
[`.basalt` model](https://huggingface.co/jesdga/Qwen3.8-Flash-Next-Basalt) and
runs its API as the `basalt` account with a generated key. Register it as
`basalt://<CT address>` (port 8080).

Defaults: the 81 GiB GSQ-RCO IQ3_S pack, alias `qwen3.8-flash-next`, context
65536, 8 cores, 128 GiB RAM (floor 64 GiB: the expert arena is pinned host
RAM), 200 GiB disk. Basalt needs a Blackwell GPU (sm_120: RTX 50 or RTX PRO
Blackwell), CUDA 13 and CMake 3.24+ (installed into its venv if the system's
is older).

## Requirements

Run as root on the Proxmox VE 9 GPU host with a downloaded
Ubuntu 22.04/24.04/26.04 or Debian 12/13 amd64 template, `rootdir` storage,
network access and `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`.
Missing address, gateway, template and storage are prompted for on a
terminal (no address is chosen automatically); the CT ID defaults to the
cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID`
to choose another). Dry runs query nothing, so they need `CT_ID`, `TEMPLATE`
and `STORAGE`. GPU nodes get CT group `GPU_GID` (44, `video`), which `basalt`
joins; the CT gets unlimited `lxc.prlimit.memlock` and the unit
`LimitMEMLOCK=infinity`. Host-driver matching and group-root troubleshooting
work as in the [Strata target](../strata/README.md#gpu-node-shows-group-root)
(`NVIDIA_DRIVER_VERSION=auto` or an exact version).

**CUDA.** The toolkit comes from NVIDIA's apt repository for the CT's
distribution. Ubuntu 22.04/24.04 and Debian 12 carry the default 13.0;
**Debian 13 starts at 13.1** and **Ubuntu 26.04 at 13.3**, so set
`CUDA_VERSION` accordingly (the router installer does this for those
templates unless you set it). Both scripts refuse a combination the repository
cannot provide before changing anything, unless a toolkit meeting
`CUDA_VERSION` is already installed in the CT.

## Create and launch

```bash
CT_ID=250 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.50/24 GATEWAY=192.0.2.1 \
bash targets/basalt/provision-lxc.sh --dry-run     # then without --dry-run

pct exec 250 -- cat /etc/basalt-target/api-key
pct exec 250 -- journalctl -u basalt -f
```

The first build and download take time; the installer waits
`BASALT_READY_TIMEOUT` (3600 s) for a loaded model. A failed step leaves the CT
for inspection. An interrupted model download stays as `.part` and resumes on
the next run.

Settings: `BASALT_PORT`, `BASALT_MODEL`, `BASALT_HF_REPO`, `BASALT_ALIAS`,
`BASALT_GPUS` (for `0,1` also add `/dev/nvidia1` to `GPU_DEVICES`),
`BASALT_CONTEXT`, `CUDA_VERSION`, and `BASALT_ALLOW_NO_KEY=true` for an
unauthenticated API. `BASALT_URL` and `BASALT_REF` (default `main`) select the
source; pin a tested commit with `BASALT_COMMIT` for production.

## Router registration

```bash
manage-model-servers set-basalt-token --apply
manage-model-servers add basalt://192.0.2.50 --tier xlarge --apply
manage-model-servers set-server-model xlarge basalt://192.0.2.50 qwen3.8-flash-next --apply
```

The key goes to the router's `secrets.env` for discovery, dispatch, monitoring
and LiteLLM. Basalt's public `/health` also allows auto-detection of a bare
address; use `basalt://host:port` for a custom port. With a custom
`BASALT_ALIAS`, use it in `set-server-model` and add `<alias> = 125B` to
`[model_sizes]` in `router.ini` so discovery sizes it.

## Upgrade

```bash
pct push 250 targets/basalt/install-target.sh /root/basalt-target-deploy/install-target.sh --perms 0755
pct push 250 targets/basalt/cuda-toolkit.sh /root/basalt-target-deploy/cuda-toolkit.sh --perms 0755
pct push 250 targets/basalt/basalt.service /root/basalt-target-deploy/basalt.service --perms 0644
pct exec 250 -- bash /root/basalt-target-deploy/install-target.sh --upgrade   # a plain rerun is the same
```

**Settings record.** Every rerun reuses `/etc/basalt-target/installed-env`
(older installs: the `installed-settings` fingerprint); non-empty environment
values override it. Only a fresh install uses defaults; it writes
`pending-env` first so an interrupted first install resumes with the same
choices. An existing checkout or unit without a readable record needs every
setting explicitly; repair or remove a malformed `installed-env`. Healthy
unchanged reruns backfill a missing record.

**Rollback.** The source is fetched before anything stops; nothing happens if
commit, settings, model, unit and health are unchanged. Otherwise Basalt is
stopped, its runnable checkout, venv, launcher and unit are snapshotted to the
root-only `/var/lib/basalt-target/` (a snapshot failure restarts the
original), and it is rebuilt and health-checked. On failure the snapshot is
restored without rebuilding or pip and the old service is health-checked. The
snapshot can contain secrets and is deleted after success or rollback; if the
rollback also fails, it is kept beside a `rollback-failed` marker and every
later run stops until you inspect or restore it and delete the marker. Leave
disk for one checkout copy; `/var/lib/basalt` is not copied (weights inside
`/opt/basalt` are).

## Checks

`bash targets/basalt/test-provision.sh`, `test-install.sh` and
`test-upgrade.sh` (root, against stubs) cover plans, validation, failed
downloads, install, no-op rerun, upgrade and rollback. A real build, download
and health check need the target host.
