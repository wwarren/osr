# Strata inference target for Proxmox VE 9

On an interactive Proxmox run, `provision-lxc.sh` lists downloaded compatible templates and active `rootdir` storage with enough free space for `ROOTFS_GB`. Set `TEMPLATE` and `STORAGE` to skip the menus. Dry runs make no Proxmox queries, so supply those values explicitly.

`provision-lxc.sh` creates a dedicated, unprivileged LXC on an NVIDIA GPU
node, fetches the [official Strata repository](https://github.com/Niko1221/Strata)
inside it, runs Strata's Linux setup without starting the model, and runs the
API as a hardened systemd service under its own `strata` account. It generates
an API key inside the CT. The router recognizes the target using
`strata://<CT address>` or `strata+http://<CT address>:8080`.

Strata's [Linux installation guide](https://github.com/Niko1221/Strata/blob/main/docs/INSTALL.md)
documents the GPU, RAM, disk, driver, and setup requirements. This target
defaults to the `IQ2_XS` model (`IQ1_M` for the `coder` family, `UD-IQ4_XS`
for `unsloth`), 64 GiB RAM, 160 GiB root disk, and Strata's
port **8080**. Set `STRATA_PORT=11434` if you want that port instead. The first
install downloads tens of gigabytes and can take a long time.

## Strata versions and setup options

Strata's `setup.sh` options and model families differ between releases. The
guest installer therefore reads the checked-out `setup.sh --help` and:

- passes only the options that checkout supports (`--no-browser`, `--family`,
  `--context`, `--vision`, and `--data-dir` or else `--models-dir`);
- refuses to continue, before running setup, when `--setup`, `--no-start`,
  `--yes`, `--model`, `--port` or `--host` is missing. Without `--host` the API
  listens on 127.0.0.1 only and the router cannot reach it;
- refuses a checkout without `--api-key` unless `STRATA_ALLOW_NO_KEY=true`;
- checks `STRATA_FAMILY`, `STRATA_MODEL` and `STRATA_VISION` against the
  choices that `setup.sh` lists. Any family the checkout offers is accepted
  (`qwen`, `swift`, `coder` and `unsloth` at the tested commit).

By default, fresh installs and reruns fetch the tested commit
[`a0116b2782a5b82622358c04a06496485d12b2d6`](https://github.com/Niko1221/Strata/commit/a0116b2782a5b82622358c04a06496485d12b2d6).
The target's launcher regression test runs against it. To use another tested
commit, set `STRATA_COMMIT=<40-digit SHA-1>`. To follow a branch or tag, set
`STRATA_REF=<name>` without setting `STRATA_COMMIT`; `STRATA_COMMIT=` explicitly
follows `main`. Branch tips can change between runs, so first check a new
commit with `test-pinned-run-script.py` (see [Check without Proxmox](#check-without-proxmox)).

## Before running

- Run on the Proxmox **GPU host**, as root. You need Proxmox VE 9, an unused CT
  ID, a downloaded amd64 template (Ubuntu 22.04 or 24.04, or Debian 12 or 13;
  24.04 is the tested one), rootdir storage, and an IP with internet access.
- The host must expose `/dev/nvidia0`, `/dev/nvidiactl`, and `/dev/nvidia-uvm`.
  `/dev/nvidia-uvm-tools` is passed through too when it exists. Set
  `GPU_DEVICES` to select another GPU or to list the nodes explicitly.
- The nodes are given group `GPU_GID` (default 44, `video`) inside the CT, and
  the `strata` account joins that group. It is never added to group root.
- The provisioner sets the new CT's `lxc.prlimit.memlock` to `unlimited` and
  the service's `LimitMEMLOCK` to infinity so Strata can pin model memory. This
  matches a [reported Proxmox LXC Strata configuration](https://github.com/Niko1221/Strata/issues/1217).
- The bundled guest NVIDIA installer is for host driver **580.173.02**. If
  your host has another driver, provide a matching LXC user-space installer
  using `NVIDIA_GUEST_INSTALLER` and set `NVIDIA_DRIVER_VERSION` accordingly.
  The provisioner checks the host driver before creating the CT.

## Create and launch

From this repository's root on the Proxmox host:

```bash
bash targets/strata/provision-lxc.sh  # prompts for the new Strata CT ID and install settings

CT_ID=280 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1 \
bash targets/strata/provision-lxc.sh --dry-run

CT_ID=280 \
TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1 \
bash targets/strata/provision-lxc.sh
```

Replace the template volume and network settings with values from your node.
The service is enabled for future CT starts. The installer waits up to
`STRATA_READY_TIMEOUT` seconds (default 900) for `/health` to report `loaded=true`,
because the first load of the model takes a while. A partially configured CT is
kept if setup fails, so you can inspect it. The script never deletes an
existing CT.
Running this provisioner again with that CT ID stops before creating anything.
To resume an interrupted install or upgrade Strata in the existing CT, run
`pct exec 280 -- bash /root/strata-target-deploy/install-target.sh` (replace
`280` with your Strata CT ID).

### If a GPU node appears as group root

On the Proxmox host, inspect the **existing** CT and its device assignments:

```bash
CT_ID=280  # replace with the Strata CT ID
pct config "$CT_ID" | grep -E '^(dev[0-9]+|lxc\.mount\.entry):'
pct exec "$CT_ID" -- stat -c '%n gid=%g mode=%a' \
    /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
```

For the default layout created by this provisioner, `dev0` is `nvidia0`,
`dev1` is `nvidiactl`, and `dev2` is `nvidia-uvm`. If the CT uses different
`devN` indexes, match the indexes shown by `pct config`. Only if the `devN`
configuration is missing or wrong, set each node's **container** GID to 44
(`video`) and mode to 0660, then reboot the CT:

```bash
pct set "$CT_ID" --dev0 path=/dev/nvidia0,gid=44,mode=0660
pct set "$CT_ID" --dev1 path=/dev/nvidiactl,gid=44,mode=0660
pct set "$CT_ID" --dev2 path=/dev/nvidia-uvm,gid=44,mode=0660
pct reboot "$CT_ID"
```

After the reboot, check the actual nodes and GPU access as the service user:

```bash
pct status "$CT_ID"
pct exec "$CT_ID" -- stat -c '%n gid=%g mode=%a' \
    /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
pct exec "$CT_ID" -- runuser -u strata -- sh -c \
    'for node in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm; do test -r "$node" && test -w "$node" || exit 1; done; nvidia-smi -L'
```

If the `strata` account is not present yet, rerun the current installer after
syncing these files from an updated repository checkout on the PVE host:

```bash
cd /path/to/ollama-smart-router
pct push "$CT_ID" targets/strata/install-target.sh \
    /root/strata-target-deploy/install-target.sh --perms 0755
pct push "$CT_ID" targets/strata/strata.service \
    /root/strata-target-deploy/strata.service --perms 0644
pct exec "$CT_ID" -- bash /root/strata-target-deploy/install-target.sh
```

If `pct config` already shows `gid=44,mode=0660` but the CT still reports
`gid=0,mode=666`, repeating `pct set` will not address that mismatch. A
root-group node that `strata` can read and write is accepted with a warning;
the restricted mapping remains preferable. If `nvidia-smi -L` fails as
`strata`, inspect the CT's device mounts and NVIDIA setup. [Proxmox's `devN`
options](https://github.com/proxmox/pve-docs/blob/master/generated/pct.conf.5-opts.adoc)
specify the node's GID and mode inside the CT without changing host device
ownership. The installer checks effective access inside the CT.

Strata keeps its venv, engine and model configs in `/opt/strata`, and models in
`/var/lib/strata`. Both are owned by `strata`, the only paths the service can
write. Setup prints the generated `run-<model>.sh` name; the installer checks
that it exists and is executable, and writes its path to
`/etc/strata-target/strata.env`. If a release stops printing that name, the
installer uses the single `run-*.sh` that setup just wrote, and refuses when
there is none or more than one. The unit runs that script directly, so service
restarts do not re-enter setup. Logs and the generated key are available with:

```bash
pct exec 280 -- journalctl -u strata -f
pct exec 280 -- cat /etc/strata-target/api-key
```

The key is passed to `setup.sh --setup` once; Strata stores it in its model
config. It never appears in the unit, its environment file or the installer's
output.

## Register with the router

Set the same key on the router, then add the target:

```bash
manage-model-servers set-strata-token --apply
manage-model-servers add strata://192.0.2.80 --tier xlarge --apply
```

For `STRATA_PORT=11434`, use `strata://192.0.2.80:11434` when adding it.
`set-strata-token` prompts for the key. `--apply` updates the running router,
monitor, and LiteLLM configuration after each change. Use the `strata://` form
for a keyed Strata if its public `/health` response does not identify it:
auto-detection never sends the Strata key to an unidentified host.

Without an API key (`STRATA_ALLOW_NO_KEY=true`), Strata protects itself
against DNS rebinding: it answers only requests whose `Host` is an IP address,
`localhost`, or a name in `allowed_hosts` in its model config
(`/opt/strata/strata-<model>.json`) or `STRATA_ALLOWED_HOSTS`. Register a
keyless Strata by IP (`strata://192.0.2.80`); a hostname such as
`strata://strata-target` gets HTTP 403 until you add it there. With a key the
check is off and hostnames work.

Keep the API port reachable only by the router and intended clients. The
Proxmox CT network is created with its firewall flag enabled; configure your
cluster's actual firewall rules as needed.

## Upgrade

Every rerun of the installer, with or without `--upgrade`, keeps the
installation's settings from `/etc/strata-target/installed-env`, including custom
model, context and port values. An install from before that record existed uses
its `installed-settings` fingerprint instead. Non-empty environment settings
override the corresponding saved values, and a new `STRATA_FAMILY` without `STRATA_MODEL` takes that family's default model.
Only a fresh install uses the model and port defaults. It records the settings
it runs with in `/etc/strata-target/pending-env` before its first change, so a
first install that stops part-way resumes with them on the next run;
the file is removed once the install succeeds. An existing checkout or service
unit with no readable record (missing, unreadable or dangling) requires every
setting explicitly before the installer can proceed. A malformed `installed-env`
must be repaired or removed before retrying.

Copy the current `install-target.sh` and `strata.service` into the CT, then
re-run the installer. It fetches the tested commit and upgrades the service
if the installed version differs:

```bash
pct push 280 targets/strata/install-target.sh /root/strata-target-deploy/install-target.sh --perms 0755
pct push 280 targets/strata/strata.service /root/strata-target-deploy/strata.service --perms 0644
pct exec 280 -- bash /root/strata-target-deploy/install-target.sh
```

To use another commit or follow a branch, pass `STRATA_COMMIT=<SHA>` or
`STRATA_REF=<name>` after `-- env` in the `pct exec` command. For example,
`pct exec 280 -- env STRATA_REF=main bash /root/strata-target-deploy/install-target.sh`
follows `main`. An install previously following `main` will move to the tested
pin on rerun unless you explicitly keep that ref; if its checkout is newer than
the pin, that is a move to older upstream code (a failed setup rolls back as
usual).
`--upgrade` remains available for an explicit upgrade request.

A rerun first fetches the selected commit or branch tip **while the service
keeps running**; if the fetch fails, nothing is stopped or changed. When the
fetched commit, the settings (family, model, context, vision, port, data
directory and key) and the unit are all unchanged and `/health` reports a
loaded model, the rerun does nothing. Otherwise it stops the service, checks
out the commit, re-checks the `setup.sh` options, re-runs setup for the
configured model, then restarts and health-checks Strata. Before changing the
checkout it stops the service and snapshots the runnable checkout, venv,
launcher and unit. If any step fails, it restores the previous commit and
runtime at their original paths without running setup or downloading packages,
then health-checks that version. A healthy unchanged legacy rerun backfills
missing `installed-env` records. Upstream's `update.sh` is
not used: it runs `git pull`, which cannot move a pinned checkout or provide
this rollback path.

Running the installer again also resumes an interrupted install, fetching the
selected source before continuing setup.
An install made by an earlier version of this script ran as root; re-running
hands `/opt/strata` and `/var/lib/strata` over to the `strata` account.

## Check without Proxmox

```bash
bash targets/strata/test-provision.sh
bash targets/strata/test-install.sh
git init /tmp/strata-source-check
git -C /tmp/strata-source-check fetch --depth 1 \
    https://github.com/Niko1221/Strata.git a0116b2782a5b82622358c04a06496485d12b2d6
python3 targets/strata/test-pinned-run-script.py /tmp/strata-source-check
```

`test-provision.sh` checks the dry-run plans and input validation.
`test-install.sh` checks the `setup.sh --help` and generated launcher handling, then runs whole
installs, unchanged and changed reruns, a failed fetch, a pinned upgrade and a
rolled-back upgrade (without network) against stubs. Run it as
root for the end-to-end cases. The last check fetches the pinned upstream
regression fixture, then runs its real launcher generator in a temporary
directory for both ports. It does not download a model, create a CT, or need
a GPU. CI runs it as a separate job, so an upstream change to the launcher
format is caught before you move the pin.

The root-only `/var/lib/strata-target/` holds the runtime snapshot (including any
configuration secrets) during an upgrade. It is deleted once the upgrade or the
rollback succeeds, and kept for inspection only when the rollback fails too.
Allow disk space for one copy of the checkout, in addition to the model and
build. The default `/var/lib/strata` model store is outside the snapshot; weights
placed inside `/opt/strata` are copied with that checkout.
A snapshot failure aborts the upgrade and restarts the original service.
