# Basalt inference target for Proxmox VE 9

On an interactive Proxmox run, `provision-lxc.sh` lists downloaded compatible templates and active `rootdir` storage with enough free space for `ROOTFS_GB`. Set `TEMPLATE` and `STORAGE` to skip the menus. Dry runs make no Proxmox queries, so supply those values explicitly.

`provision-lxc.sh` creates a dedicated, unprivileged LXC on a Blackwell GPU
node. It installs matching NVIDIA userspace, a CUDA 13 toolkit, builds the
[Basalt engine](https://github.com/jesdga95/basalt), downloads one
[`.basalt` model](https://huggingface.co/jesdga/Qwen3.8-Flash-Next-Basalt),
and runs its API under a dedicated `basalt` account with a generated API key.
The default model is the 81 GiB GSQ-RCO IQ3_S pack. The default CT size is
128 GiB RAM and 200 GiB root disk. Basalt requires a Blackwell GPU (sm_120),
CUDA 13, CMake 3.24 or newer, and enough RAM for its expert arena. The guest
installer supplies a newer CMake in its virtual environment when the system
version is too old.

The toolkit comes from NVIDIA's apt repository for the CT's distribution.
Ubuntu 22.04/24.04 and Debian 12 carry the default CUDA 13.0. **Debian 13
starts at 13.1** (`CUDA_VERSION=13.1` or later); **Ubuntu 26.04 starts at
13.3** (`CUDA_VERSION=13.3` or later). The router installer picks a Debian 13
template first, then Ubuntu 26.04, and selects these versions automatically
for them unless `CUDA_VERSION` is explicitly set. `provision-lxc.sh` and `install-target.sh` refuse a combination the
repository cannot provide before anything is created or changed, unless a
toolkit that meets `CUDA_VERSION` is already installed in the CT.

## Before running

Run on the Proxmox GPU host as root. The host needs Proxmox VE 9, an unused CT
ID, a downloaded Ubuntu 22.04/24.04/26.04 or Debian 12/13 amd64 LXC template,
rootdir storage, network access, and `/dev/nvidia0`, `/dev/nvidiactl` and
`/dev/nvidia-uvm`. The bundled NVIDIA guest helper matches host driver
580.173.02. For a different host driver, supply a matching
`NVIDIA_GUEST_INSTALLER` and `NVIDIA_DRIVER_VERSION`. The provisioner checks
the host driver before creating the CT.

The GPU nodes are assigned `GPU_GID` (44, `video`, by default), and the service
account joins their group. The provisioner also gives the CT unlimited
`lxc.prlimit.memlock`; the service sets `LimitMEMLOCK=infinity` because Basalt
pins expert memory.

## Create and launch

From this repository's root on the Proxmox host, inspect the plan first:

```bash
CT_ID=250 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1 \
bash targets/basalt/provision-lxc.sh --dry-run
```

Run the same command without `--dry-run` after substituting your template,
storage and network values. The first build and model download take time.
The script leaves a partially configured CT for inspection if a step fails.
Read the key and logs with:

```bash
pct exec 250 -- cat /etc/basalt-target/api-key
pct exec 250 -- journalctl -u basalt -f
```

Basalt serves port 8080 by default. `BASALT_PORT`, `BASALT_MODEL`,
`BASALT_HF_REPO`, `BASALT_ALIAS`, `BASALT_GPUS`, `BASALT_CONTEXT` (32768 tokens
by default) and `CUDA_VERSION` can be set on
the provision command. `BASALT_URL` and `BASALT_REF` select the source checkout;
`BASALT_COMMIT` pins a full 40 digit commit. For production, pin a commit you
have tested. A rerun fetches the selected source before stopping the service,
and restores the previous local commit if the rebuild or health check fails.
An interrupted model download stays as `.part` and is resumed on the next run.
For `BASALT_GPUS=0,1`, also include `/dev/nvidia1` in `GPU_DEVICES`.

## Router registration

Register the CT as a Basalt server. Its API key is saved in the router's
`secrets.env` and used for discovery, chat dispatch, monitoring and LiteLLM.

```bash
manage-model-servers set-basalt-token --apply
manage-model-servers add basalt://192.0.2.80 --tier xlarge --apply
manage-model-servers set-server-model xlarge basalt://192.0.2.80 qwen3.8-flash-next --apply
```

Replace the address with the CT's IP. If you changed `BASALT_ALIAS` during
provisioning, use that alias in `set-server-model`. Basalt's public `/health`
endpoint also allows auto-detection from a bare address. Use `basalt://` to
select the API explicitly, including when it listens on a custom port. For a
custom alias, add `<alias> = 125B` to `[model_sizes]` in the router's
`router.ini` if you want discovery to size it like the default alias.

## Upgrade and check

Every rerun of the installer, with or without `--upgrade`, keeps the
installation's settings from `/etc/basalt-target/installed-env`, including custom
model, context and port values. An install from before that record existed uses
its `installed-settings` fingerprint instead. Non-empty environment settings
override the corresponding saved values.
Only a fresh install uses the defaults. A fresh install records the settings
it runs with in `/etc/basalt-target/pending-env` before its first change, so a
first install that stops part-way resumes with them on the next run;
the file is removed once the install succeeds. An existing checkout or service
unit with no readable record (missing, unreadable or dangling) requires every
setting explicitly before the installer can proceed. A malformed `installed-env`
must be repaired or removed before retrying.

Push the three deployment files into the existing CT, then rerun the guest
installer with `--upgrade` (a plain rerun does the same and keeps the same
settings):

```bash
pct push 250 targets/basalt/install-target.sh /root/basalt-target-deploy/install-target.sh --perms 0755
pct push 250 targets/basalt/cuda-toolkit.sh /root/basalt-target-deploy/cuda-toolkit.sh --perms 0755
pct push 250 targets/basalt/basalt.service /root/basalt-target-deploy/basalt.service --perms 0644
pct exec 250 -- bash /root/basalt-target-deploy/install-target.sh --upgrade
```

The installer fetches before stopping anything and does nothing when the
commit, settings, model, unit and health are unchanged. Otherwise it stops
Basalt, rebuilds, relaunches and waits for `/health` to report a loaded model.
Before changing the checkout it stops the service and snapshots the runnable
checkout, venv, launcher and unit. If the upgrade fails, it restores the
previous commit and runtime at the original paths without rebuilding or
running pip, then health-checks the old service. Model files in the separate
data directory are kept. Healthy unchanged legacy reruns backfill missing
`installed-env` records.

Without Proxmox or a GPU, run `bash targets/basalt/test-provision.sh`,
`bash targets/basalt/test-install.sh` and `bash targets/basalt/test-upgrade.sh`
(as root, against stubs: install, no-op rerun, upgrade and rollback) to check
plans, validation, shell syntax, failed-download handling and the upgrade
path. A real build, model download and service
health check require the target host.

The root-only `/var/lib/basalt-target/` holds the runtime snapshot (including any
configuration secrets) during an upgrade. It is deleted once the upgrade or the
rollback succeeds, and kept for inspection only when the rollback fails too.
Allow disk space for one copy of the checkout, in addition to the model and
build. The default `/var/lib/basalt` model store is outside the snapshot; weights
placed inside `/opt/basalt` are copied with that checkout.
A snapshot failure aborts the upgrade and restarts the original service.
