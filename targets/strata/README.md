# Strata inference target

`provision-lxc.sh` creates an unprivileged LXC on an NVIDIA GPU host, fetches
the [official Strata repository](https://github.com/Niko1221/Strata), runs
Strata's Linux setup without starting the model, and runs the API as the
hardened `strata` service with an API key generated in the CT. Register it as
`strata://<CT address>` (`strata+http://<address>:8080`).

Defaults: model `IQ2_XS` (`IQ1_M` for the `coder` family, `UD-IQ4_XS` for
`unsloth`), context 65536, 8 cores, 64 GiB RAM, 160 GiB disk, port **8080**
(`STRATA_PORT=11434` if you prefer). The first install downloads tens of
gigabytes. Upstream requirements are in Strata's
[installation guide](https://github.com/Niko1221/Strata/blob/main/docs/INSTALL.md).

## Source and setup options

Runs fetch the tested commit
[`a0116b2782a5b82622358c04a06496485d12b2d6`](https://github.com/Niko1221/Strata/commit/a0116b2782a5b82622358c04a06496485d12b2d6),
which the launcher regression test checks. `STRATA_COMMIT=<sha>` selects
another commit; `STRATA_REF=<name>` (with `STRATA_COMMIT` unset) follows a
branch or tag, and `STRATA_COMMIT=` follows `main`. Check a moving ref with
`test-pinned-run-script.py` first ([Checks](#checks)).

Because `setup.sh` options differ between releases, the installer reads the
checkout's `setup.sh --help` and:

- passes only supported options (`--no-browser`, `--family`, `--context`,
  `--vision`, `--data-dir` or else `--models-dir`);
- stops before setup if `--setup`, `--no-start`, `--yes`, `--model`, `--port`
  or `--host` is missing (without `--host` the API binds to 127.0.0.1);
- refuses a checkout without `--api-key` unless `STRATA_ALLOW_NO_KEY=true`;
- checks `STRATA_FAMILY`, `STRATA_MODEL` and `STRATA_VISION` against the
  choices `setup.sh` lists (`qwen`, `swift`, `coder`, `unsloth` at the pin).

## Requirements

Run as root on the Proxmox VE 9 **GPU host** with a downloaded
amd64 template (Ubuntu 22.04/24.04 or Debian 12/13; 24.04 is the tested one),
`rootdir` storage and an IP with internet access. On a terminal the
provisioner prompts for missing address, gateway, template and storage (no
address is chosen automatically). The CT ID defaults to the cluster's next free
ID (Enter, or an unattended run, takes it; preset `CT_ID` to choose another).
Dry runs make no Proxmox queries, so give `CT_ID`, `TEMPLATE` and `STORAGE`.

- **GPU nodes.** `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm` (and
  `/dev/nvidia-uvm-tools` if present) are passed through with CT group
  `GPU_GID` (44, `video`); `strata` joins that group, never root. Set
  `GPU_DEVICES` for another GPU or explicit nodes.
- **Driver.** The provisioner installs NVIDIA user-space matching the loaded
  host driver and verifies NVML and CUDA first (`NVIDIA_DRIVER_VERSION=auto`,
  or an exact version to require).
- **Memory locking.** The CT gets `lxc.prlimit.memlock: unlimited` and the unit
  `LimitMEMLOCK=infinity`, so Strata can pin model memory.

## Create and launch

From the repository root on the Proxmox host:

```bash
bash targets/strata/provision-lxc.sh      # interactive
CT_ID=251 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.51/24 GATEWAY=192.0.2.1 \
bash targets/strata/provision-lxc.sh --dry-run     # then without --dry-run
```

The installer waits `STRATA_READY_TIMEOUT` (900 s) for `/health` to report
`loaded=true`. A failed setup keeps the CT for inspection; the provisioner
never deletes a CT and stops if the ID exists. To resume or upgrade an existing
CT, run `pct exec <id> -- bash /root/strata-target-deploy/install-target.sh`
(see [Upgrade](#upgrade)).

Strata keeps its venv, engine and configs in `/opt/strata` and models in
`/var/lib/strata`, the only paths the `strata` account can write. Setup prints
the generated `run-<model>.sh`; the installer checks it (or, if not printed,
the single new `run-*.sh`), writes its path to `/etc/strata-target/strata.env`,
and the unit runs it directly. The key is passed to `setup.sh --setup` once
and stored by Strata in its model config, never in the unit, env file or
output.

```bash
pct exec <id> -- journalctl -u strata -f
pct exec <id> -- cat /etc/strata-target/api-key
```

**CUDA build fallback.** If Strata has no ready engine for the GPU, setup
compiles one and tries `sudo` (Ubuntu) or stops (Debian) to get CUDA. The
installer intercepts that, installs NVIDIA's toolkit-only package as root
(`cuda-toolkit-13-0` on Ubuntu 22.04/24.04 and Debian 12, `13-1` on Debian 13)
and retries setup once. The CT's NVIDIA user-space must still match the host.
To resume a CT that failed here, push the current installer and rerun it;
`/etc/strata-target/pending-env` keeps the first attempt's choices.

### GPU node shows group root

```bash
pct config <id> | grep -E '^(dev[0-9]+|lxc\.mount\.entry):'
pct exec <id> -- stat -c '%n gid=%g mode=%a' /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
```

The provisioner's layout is `dev0` nvidia0, `dev1` nvidiactl, `dev2`
nvidia-uvm (match the indexes `pct config` shows). Only if a `devN` entry is
missing or wrong, set the CT-side group and mode and reboot:

```bash
pct set <id> --dev0 path=/dev/nvidia0,gid=44,mode=0660
pct set <id> --dev1 path=/dev/nvidiactl,gid=44,mode=0660
pct set <id> --dev2 path=/dev/nvidia-uvm,gid=44,mode=0660
pct reboot <id>
pct exec <id> -- runuser -u strata -- nvidia-smi -L
```

A root-group node that `strata` can already read and write (0666, older
mapping) is accepted with a warning, and `strata` still joins `video` so it
keeps the GPU once the mapping is tightened. If `pct config` already shows
`gid=44,mode=0660` but the CT reports `gid=0,mode=666`, repeating `pct set`
will not help; inspect the CT's device mounts. Installs that predate the check
need `usermod -aG video strata` or an installer rerun. Installs from an older
script that ran as root are handed to the `strata` account on rerun.

## Register with the router

```bash
manage-model-servers set-strata-token --apply        # prompts for the key
manage-model-servers add strata://192.0.2.51 --tier xlarge --apply
```

Use `strata://host:11434` for that port. Use the `strata://` form whenever a
keyed Strata's public `/health` does not identify it: auto-detection never
sends the key to an unidentified host.

Without a key (`STRATA_ALLOW_NO_KEY=true`), Strata answers only requests whose
`Host` is an IP, `localhost` or listed in `allowed_hosts` in
`/opt/strata/strata-<model>.json` (or `STRATA_ALLOWED_HOSTS`), so register it
by IP; a hostname gets 403. With a key that check is off.

The CT is created with its firewall flag on but no rules: restrict the API port
to the router and intended clients.

## Upgrade

Push the current files and rerun the installer (`--upgrade` is optional and
behaves the same):

```bash
pct push <id> targets/strata/install-target.sh /root/strata-target-deploy/install-target.sh --perms 0755
pct push <id> targets/strata/strata.service /root/strata-target-deploy/strata.service --perms 0644
pct exec <id> -- bash /root/strata-target-deploy/install-target.sh
pct exec <id> -- env STRATA_REF=main bash /root/strata-target-deploy/install-target.sh   # follow main
```

An install that followed `main` moves to the tested pin on rerun unless you
pass its ref again (possibly to older code; a failed setup rolls back).
Upstream's `update.sh` is not used: its `git pull` cannot move a pinned
checkout or roll back.

**Settings record.** Every rerun reuses `/etc/strata-target/installed-env`
(older installs: the `installed-settings` fingerprint); non-empty environment
values override it, and a new `STRATA_FAMILY` without `STRATA_MODEL` takes that
family's default. Only a fresh install uses defaults; it writes `pending-env`
before its first change so an interrupted first install resumes with the same
choices. An existing checkout or unit without a readable record needs every
setting given explicitly; repair or remove a malformed `installed-env`.
Healthy unchanged reruns backfill a missing record.

**Rollback.** A rerun fetches the source while the service runs (a failed
fetch changes nothing) and does nothing if commit, settings (family, model,
context, vision, port, data dir, key), unit and health are unchanged.
Otherwise it stops the service, snapshots the runnable checkout, venv,
launcher and unit to the root-only `/var/lib/strata-target/` (a snapshot
failure restarts the original), re-runs setup and health-checks. On failure it
restores the snapshot without setup or downloads and health-checks the old
version. The snapshot can contain secrets and is deleted after success or
rollback. If the rollback also fails, it is kept beside a `rollback-failed`
marker and every later run stops there: inspect or restore it, then delete the
marker. Leave disk for one copy of the checkout; `/var/lib/strata` is not
copied (weights inside `/opt/strata` are).

## Checks

```bash
bash targets/strata/test-provision.sh       # dry-run plans, validation
bash targets/strata/test-install.sh         # end-to-end cases need root
git init /tmp/strata-src && git -C /tmp/strata-src fetch --depth 1 \
    https://github.com/Niko1221/Strata.git a0116b2782a5b82622358c04a06496485d12b2d6
python3 targets/strata/test-pinned-run-script.py /tmp/strata-src
```

`test-install.sh` covers `setup.sh --help` and launcher handling, installs,
unchanged and changed reruns, a failed fetch, a pinned upgrade and a rollback
against stubs. The pinned check runs upstream's real launcher generator for
both ports; CI runs it as the `strata-upstream` job, so a launcher change is
caught before the pin moves. None of these downloads a model or needs a GPU.
