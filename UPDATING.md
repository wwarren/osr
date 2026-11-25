# Updating

## Everything at once

To bring the router and every target in a Proxmox cluster (or on a standalone
host) up to this clone's versions in one run, keeping their settings, as root
on any one node (inside `tmux` or `screen`, since model targets can take a long
time):

```bash
bash /path/to/clone/tools/upgrade-all.sh --dry-run   # the plan, and the router's pending diff
bash /path/to/clone/tools/upgrade-all.sh             # asks before starting
```

It finds, on every node of the cluster, the router CT (tag `osr-router`),
each target CT (tag `osr-target` plus the target's name) and each CT with
hcom, then upgrades them in dependency order: router, Open WebUI, Gitea and Mattermost, model targets,
ComfyUI and Open Terminal, Honcho, the agents, MQTT, hcom (agents before the
observer). Once an upgrade run starts, it adds the `hcom` tag to each detected
hcom CT that lacks it, keeping its other tags. `--list` and `--dry-run` leave
tags alone. Each component goes through its own supported path, so nothing about its
settings or rollback changes:

| Component | Upgraded with | Settings kept by |
|---|---|---|
| Router | `update-router-services.sh --host --no-push`, pushed once checks pass | Updater never touches `env/*.env`, tiers, `litellm_config.yaml`, ini files or secrets |
| Open WebUI | `set-webui-version <pin> --apply` (never a downgrade) | `apply`'s snapshot and `webui.db` backup |
| llama.cpp, AirLLM, Ollama, Strata, PolyStrata, Basalt, Maya, Xolotl, Avalon, Kindi, Colibri, ComfyUI | Current files pushed to `/root/<target>-target-deploy`, then `install-target.sh --upgrade` (ComfyUI keeps a release newer than its pin; a llama.cpp target without the monitor dashboard gets it, as the plan and summary say). No model question, as for every other model target; with `--colibri-model`, an interactive run asks for each Colibri CT whether to serve another model afterwards (default no), and a yes shows the model menu and runs `install-target.sh --model` after its upgrade | Each target's settings record or env files; the served Colibri model unless `--colibri-model` chooses another |
| Open Terminal | Current files pushed, installer rerun (running workspaces restart on their next request); then its Open WebUI connection is enabled for all users (needs the admin token; skipped without it) | Its recorded port, passed back; workspace limits kept by the installer; `OPEN_TERMINAL_WEBUI_ACCESS=keep`, once recorded, leaves its access alone |
| Gitea, Mattermost | `provision-lxc.sh --reconfigure`, which re-applies the OSR setup; their community scripts install the newest release, which this repository does not pin, so the release stays as it is (reported `reapplied`) | Accounts, router token and webhook are kept by their installers |
| Honcho, Hermes, OpenClaw, DeepSeek Harness, OpenCode | `provision-lxc.sh --reconfigure`; interactive runs use `PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false`, unattended runs use `NONINTERACTIVE=true`. Honcho's Open WebUI connection is enabled for all users | Recorded answers; an Open WebUI admin key is requested once when needed; `HONCHO_WEBUI_ACCESS=keep`, once recorded, leaves its access alone |
| Hermes Agent itself | Not pinned here: the reconfigure upgrades its integration (units, dispatcher, settings) and Hermes stays at its installed version. `--update-hermes` also runs `hermes update` as the hermes user and restarts `hermes-gateway` and `hermes-dashboard`, unless `HERMES_COMMIT` pins it | The plan and summary say which: Hermes stayed, was updated (old and new commit), or stays at its pin |
| MQTT | `provision-lxc.sh --reconfigure` | Address, client CIDR, host, port and TLS files read back from the broker |
| hcom | `provision-lxc.sh` per CT | Role, native mode, instructions file and observer webhook read back from the CT |

**Clusters.** Everything runs from the node you start it on, which needs
root SSH to the other nodes, as Proxmox itself uses. The installer sets that up
([Cluster SSH](INSTALLATION.md#cluster-ssh)); check or repair it at any time with
`bash tools/setup-cluster-ssh.sh`. When a node holding OSR CTs does not answer,
the run names it before planning and, on a terminal, offers to run that tool
for it, then checks again. Proxmox's `pct` acts only on CTs of its own node, so the run puts `tools/pct-cluster.sh` first on `PATH` as `pct`, for
itself and every provisioner it runs. That wrapper runs the real `pct` on the
node that holds each CT: here for a local CT, otherwise over SSH with the
options Proxmox VE 9 uses (BatchMode, the node name as `HostKeyAlias`, the
node's pinned host key in `/etc/pve/nodes/<node>/ssh_known_hosts` when published, its
address from `/etc/pve/.members`), with one shared connection per node. Files for `pct push` and `pct pull` are streamed
through that connection and leave no copies behind. Provisioners also get
`PVE_LXC_DIR` pointing at a view of every node's CT configurations, so a
router, Honcho, broker or Mattermost CT on another node is found and used as
if it were local. The plan and summary show each CT's node. A node the cluster
reports offline, or one that does not answer over SSH, is reported, and its
CTs are `not-run`. So is anything that needs the router or the hcom broker on
such a node. `--node pve2,pve3` limits the run to some nodes. When several OSR
installations share a cluster, set `ROUTER_CT_ID` or use `--node` to say
which router is meant. Only one run at a time is allowed in the cluster:
`/etc/pve/priv/osr-upgrade-all.lock` names the holder. A lock left by a run on
this node that has ended is taken over; delete one from another node by hand
once that run is gone. If the lock cannot be created at all, check quorum with
`pvecm status`, then check the cluster filesystem and path permissions. A node
without quorum usually has a read-only cluster filesystem. The wrapper also
works directly, for example
`bash tools/pct-cluster.sh exec 205 -- uptime` on any node.

**Installed, pinned or latest upstream.** Before the plan the run lists a
versions table with one row per CT it will upgrade: the version installed in
that CT now (read from what its installer records or reports: a release, or a
12-digit commit; `?` when the CT does not say), the release pinned here
(tested with this repository) and the newest upstream release, looked up on
GitHub, PyPI or npm (`GITHUB_TOKEN` raises GitHub's rate limit; it goes in a
header file, never on a command line):

```
COMPONENT          CT     INSTALLED              PINNED                 LATEST UPSTREAM
router (LiteLLM)   200    1.75.5.post1           1.75.5.post1           1.79.0 (not offered: this run installs the pin)
open-webui         200    0.11.0                 0.13.4                 0.13.4 (the pin is current)
ollama             210    0.33.1                 v0.34.4                v0.35.0
strata             211    0123456789ab           0123456789ab           main @ 89abcdef0123
hcom               220    0.7.31                 0.7.31                 v0.7.31 (the pin is current)
```

The router's row is its LiteLLM; it, AirLLM and hcom show their latest
upstream release but are not offered it (their installers take only the pin).
MQTT's row is the CT's Mosquitto package, which follows Debian.

| Component | Pin | Latest upstream | Given to its installer |
|---|---|---|---|
| Open WebUI | `services/open-webui/requirements.txt` | PyPI `open-webui` | `set-webui-version` |
| Ollama, llama.cpp, Honcho | the installer's (provisioner's) default | highest `vX.Y.Z` GitHub release, no pre-releases | `OLLAMA_VERSION`, `LLAMA_CPP_REF`, `HONCHO_REF` |
| ComfyUI, Open Terminal | default tag and its reviewed commit | the same, with the commit the tag names now | `*_VERSION` and `*_COMMIT`; Open Terminal resolves a newer release's Python dependencies with pip when they differ from its lock |
| Strata, PolyStrata, Xolotl, Avalon, Kindi, Colibri | the tested commit | the tip of `main` | `*_COMMIT` |
| DeepSeek Harness, OpenCode | the provisioner's default | npm `latest` tag | `DSH_VERSION`, `OPENCODE_VERSION` |
| FreeLLMAPI | the provisioner's tested release | highest `vX.Y.Z` GitHub release | `FREELLMAPI_VERSION` (its image tag) |
| Hermes | none (stays at its commit) | `hermes update` | as `--update-hermes` |

On a terminal, the run asks about every selected component before the plan.
Pinned components ask `[P/k]`: apply the repository pin (`p`, the answer for
`--yes`) or keep what is installed (`k`), even when the pin is current. When a
newer upstream release or commit is available, they ask `[p/L/k]` and default
to the latest (`l`); when every CT already runs that release, the default is
`k` and the prompt shows `[p/l/K]`. Components without a pin (Basalt, Maya,
OpenClaw, Gitea, Mattermost and MQTT) ask `[U/k]`: run their existing upgrade
or reconfigure step (`u`) or keep them (`k`). `k` skips every CT of that
component for this run;
the plan and summary show them as `kept` (not a failure). Hermes is asked the
same way: `p` upgrades its integration, `l` also runs `hermes update`, `k`
skips it. To keep one CT of several, or to keep a component unattended, use
`--skip`. `--latest ollama,comfyui` (or `all`) takes the latest without asking,
and `--pinned` takes every pin. The latest is untested here, and a commit the
installer checks is the one upstream names at that moment, not a reviewed one;
the snapshot and checks still cover it. ComfyUI and Open Terminal keep a
newer release on later runs that take the pin; Ollama, llama.cpp, Strata,
PolyStrata, Xolotl, Avalon, Kindi and Colibri go back to the pin then. An unreachable upstream is reported
and the pins are used.

A release you pinned yourself (`HONCHO_REF`, `DSH_VERSION`, `OPENCODE_VERSION`) is offered the
repository's pin in an interactive run; `--yes` accepts it and `--keep-pins`
preserves it. A `HERMES_COMMIT` pin is always kept. `latest`, `main` and releases newer than the repository's pin
are kept. Stopped CTs are left alone unless `--include-stopped`.

**Checks and failures.** Before each upgrade it records what works in that CT:
its services, its listening TCP ports, and for the router `/healthz`,
`/v1/models`, Open WebUI's `/health` and every model server the router sees.
For Hermes (and hcom on a Hermes CT) it also records whether the API server's
`/health` answers `"status": "ok"` on its port, the direct dispatcher's
`/healthz` and the dashboard's `/api/status` answer.
For a model target it also records whether the router lists that server as up
with models (after `/routing/refresh?probe=false`). It then takes a Proxmox snapshot
(`osr-upg-<time>-<n>`; when one cannot be taken, interactive runs ask whether
to continue, unattended runs continue, and `--require-snapshot` skips that CT). After the
upgrade, everything that worked before must work again within
`--health-timeout` (300 s); what was already down is not checked. If the
upgrade fails or something broke, it rings the terminal bell, posts to
Mattermost through the router's webhook (`--no-notify` turns that off), lists
what broke and asks:

| Choice | Does |
|---|---|
| `r` | Retry |
| `i` | Retry interactively, answering the installer's or provisioner's questions yourself |
| `s` | Skip it: leave it as it is and go on (it keeps its snapshot) |
| `b` | Roll the CT back to the snapshot, check it again, go on (default when broken, or when a provisioner failed) |
| `l` | Show the end of its log |
| `a` | Abort: leave the rest untouched |

A component may restore its own files after a failed upgrade; check its log.
A target installer or the router updater restores what it changed; a
provisioner (Honcho, Hermes, OpenClaw, DeepSeek Harness, OpenCode, Gitea,
Mattermost, MQTT, hcom) can stop after it has changed the CT, so after its failure rolling
back is the default, and `--on-failure rollback` rolls back even when every
check still passes. A failed upgrade that is skipped keeps its snapshot, and
the summary gives the `pct rollback` and `pct delsnapshot` commands for it.
The Proxmox snapshot can restore the CT when a functional check fails. Without
one, recovery may need manual work. A snapshot covers only the CT: it cannot
restore host firewall rules or Open WebUI registrations. Snapshots are deleted
after success unless `--keep-snapshots`, and after a verified rollback.

`--yes` runs unattended: provisioners get `NONINTERACTIVE=true`, and failures
are handled with `--on-failure rollback` (default), `skip` or `abort`.

**Open WebUI admin token.** Honcho, and Hermes, OpenClaw and OpenCode with an
Open WebUI connection, register with Open WebUI again when reconfigured, and
Open Terminal's connection is enabled for all users after its upgrade (without
a token Open Terminal is still upgraded and its access is left alone). When
one of them is included and `OPENWEBUI_ADMIN_TOKEN` is not set, an unattended run asks for
the token on the terminal once, at the start, before its plan and before
anything changes. The token is checked against Open WebUI in the router CT
(`/openai/config` answers only an admin), with three tries. It is kept in
`OPENWEBUI_ADMIN_TOKEN` for the run and passed only to those provisioners,
through their environment: it is not exported to other children, put on a
command line or written to disk. Press Enter to go on without it, and those
components are reported `not-run`. They are also reported `not-run` when
there is no terminal at all (cron, systemd), so set the variable there. An
interactive run asks for the token after you accept the plan; there, Enter
leaves each provisioner to ask for itself.
`--only` and `--skip` take target names, CT IDs or `name@ID`. Logs and a
`summary.txt` are kept in `/var/log/osr-upgrade/<time>/`; the exit status is
non-zero when anything was skipped, rolled back or left broken. GPU drivers are
separate: run `tools/update-gpu-drivers.sh` first when they need updating.

## Router components

To update the router, monitor, units, requirements and management tools from a
newer clone without reinstalling, as root on the Proxmox host:

```bash
bash /path/to/clone/tools/update-router-services.sh --dry-run --diff   # review
bash /path/to/clone/tools/update-router-services.sh                     # prompts for the CT (or CT_ID; --host skips the location prompt)
```

Inside the CT, use a clone separate from `/app/config-repo` and add
`--container`. It refuses a missing or nonstandard install, stages the
installer-owned files and runs `install/update-router.sh` in the CT, which
commits them to `/app/config-repo`, rebuilds the router venv if requirements
changed, runs `manage-model-servers apply` and pushes. A failed apply undoes
the commit and restores the previous venv packages. It never touches servers,
tiers, `env/*.env`, `litellm_config.yaml` or secrets; `router.ini` and
`monitor.ini` are replaced only with `--with-tunables`. `--no-apply` and
`--no-push` stop early. It refuses a config repo with uncommitted changes. A
failed push exits non-zero but keeps the applied update. Re-running the
installer also updates installer-owned code in Gitea
(`CONFIG_UPDATE_CODE=true`); configuration is only seeded if missing.

## Open WebUI

```bash
manage-model-servers set-webui-version                 # pinned / installed / latest
manage-model-servers set-webui-version latest --apply  # or a specific version
```

New installs get Open WebUI 0.13.4, the pinned release; the pin is in
`services/open-webui/requirements.txt`. Set `OPENWEBUI_VERSION` to another
release, or to `latest`. The version manager checks releases against PyPI and
the venv's Python first, and a failed health check restores the previous
version and `webui.db`. Upgrade an existing router with
`set-webui-version 0.13.4 --apply` (or let `tools/upgrade-all.sh` do it).
0.13 keeps image engines as a list of connections and converts the 0.12
settings at its first start (see [Image generation](IMAGE_GENERATION.md#image-generation)). Its terminal
features (process list and output, events, notebooks, coding agents) need
Open Terminal v0.17.21, the pinned release: upgrade the terminal CT too
(`tools/upgrade-all.sh` does both).
Open WebUI 0.11.1, 0.12.0 and 0.12.1 migrate the database irreversibly; `apply` keeps a copy in
`/var/backups/open-smart-router/<timestamp>/openwebui-data/`, but only the
last `APPLY_BACKUP_KEEP` (5) snapshots are kept, so copy it elsewhere if you
may roll back later.

## Targets

Target upgrades check readiness and restore the prior code and settings on
failure; see each target README and the
[upgrade contract](ARCHITECTURE.md#16-inference-targets-targets). Strata,
PolyStrata, Basalt, Maya, Xolotl, Avalon, Kindi and Colibri need disk for one runtime snapshot and
carry their settings forward unless overridden. Interrupting an upgrade
(Ctrl-C, closed SSH) rolls it back; after a hangup its output is in the CT's
`/var/log/osr-install-interrupted.log`. If a model target's rollback fails too,
its next run stops at `/var/lib/<target>-target/rollback-failed` until you have
inspected the kept snapshot and deleted that file. FreeLLMAPI is replaced by a
CT made from the new image; it is backed up with `vzdump` first and restored on
failure, so `tools/upgrade-all.sh` snapshots it only for a run that keeps its
release (passed as `FREELLMAPI_VERSION=keep`). MQTT and hcom are rerun
with the same settings (or `--reconfigure`); a failed rollback keeps
`/etc/mqtt-target/rollback` or `/etc/osr-hcom/rollback` and blocks reruns.
Rerun hcom everywhere after changing the broker's advertised host or port.

## GPU drivers

To check and update the drivers of the host and every GPU container, as root
on the Proxmox host:

```bash
bash /path/to/clone/tools/update-gpu-drivers.sh --check   # report only (exit 3: updates available)
bash /path/to/clone/tools/update-gpu-drivers.sh           # shows the plan and asks before each change
```

GPU containers are found from their configs (`/dev/nvidia*`, `/dev/dri/*`,
`/dev/kfd`); running ones are checked, stopped ones with `--include-stopped`
(started, then stopped again).

**NVIDIA.** Host driver and every container's libraries must be the same
release. It offers the newest production release (recommended), the newest of
the installed branch, and the newest new-feature release; pre-Turing cards
(Maxwell, Pascal, Volta) stay on 580. Before anything stops it downloads the
release, checks its SHA-256 and that `supported-gpus.json` lists every card
(with the open modules, if used), and test-builds the modules for the running
and newer installed kernels. It then stops the NVIDIA containers, unloads the
old modules, installs with `tools/install-nvidia-driver.sh host` (DKMS for
newer kernels), installs the same libraries in each container
(`tools/install-nvidia-driver.sh lxc`) and restarts them. Debian apt NVIDIA
packages in a container (`libcuda1`, `libnvidia-ml1`, `nvidia-smi` and
`nvidia-alternative` dependents) are replaced using the provisioners' cleanup
(`targets/nvidia-lxc.sh`). Every NVIDIA container is checked before any
download, including ones `--ct` leaves out; the host update is blocked by a
container that cannot be checked or started, does not see the host driver, or
has packages cleanup won't remove (Ubuntu's `libnvidia-compute-*`,
`cuda-drivers`) or whose removal would take others along
(`nvidia-cuda-toolkit`); `--check` lists blockers. A failed host install puts
the previous release back; a host process holding the GPU prevents the
install. Containers whose NVML or CUDA library mismatches the host are offered
the host's release. An apt-installed host driver is reported, not changed.
`--nvidia <version>` can also roll back, but not below the branch a
container's CUDA needs (CUDA 13: 580).

**AMD and Intel.** `amdgpu`, `i915` and `xe` ship with the Proxmox kernel, so
updates are pending `pve-firmware` and kernel-series updates (newer opt-in
series are reported, not installed). In containers, Mesa, Intel's compute
runtime and apt ROCm are upgraded from their own repositories; ROCm, CUDA and
PyTorch bundled with Ollama or ComfyUI move with the target's `--upgrade`.

`--yes` takes recommended answers (`--nvidia production|branch|newest|keep|<version>`),
`--ct 201,202` limits containers (a new NVIDIA host release still updates all
NVIDIA containers), `--dry-run` prints commands, `--no-probe` skips the test
build. It needs ~2 GB in `DOWNLOAD_DIR` (`/root`) and ~1 GB per NVIDIA
container while installing. Exit 2 means reboot (kernel, firmware or a driver
that could not load live), then rerun to confirm.

## Upgrading from Ollama Smart Router

The project was renamed to Open Smart Router in November 2026. An existing
install needs no manual step: update it from a new clone as above
(`tools/upgrade-all.sh`, or `tools/update-router-services.sh` for the router
alone).

| Renamed | On an existing install |
|---|---|
| Installer `ollama-smart-router-install.sh` → `open-smart-router-install.sh` | Use the new file from a new clone |
| Default CT hostname and Gitea repository `ollama-smart-router` → `open-smart-router` | Both keep their old names. The tools find the router by its `osr-router` tag, and the installer uses an existing `ollama-smart-router` repository when `open-smart-router` does not exist (`GITEA_REPO_LEGACY_NAME=` turns that off; a `GITEA_REPO_NAME` of your own is never replaced). To move to the new name, rename the repository in Gitea and run `git -C /app/config-repo remote set-url origin <new URL>` in the router CT |
| Snapshots `/var/backups/ollama-smart-router/` → `/var/backups/open-smart-router/` | The next `apply` moves the old snapshots and prunes them with the rest |
| Config lock `/run/lock/ollama-smart-router-config.lock` → `…/open-smart-router-config.lock` | `update-router.sh` also takes the old lock, so a management tool from before the update cannot overlap it |
| Firewall rule tags and CT descriptions (`… for Ollama Smart Router`) | Old ones are recognised; Hermes, OpenClaw and OpenCode rewrite theirs on the next `--reconfigure` |
| DeepSeek Harness's managed `AGENTS.md` block | Replaced in place on the next run |
| Units `ollama-router.service`, `ollama-monitor.service` → `osr-router.service`, `osr-monitor.service`, and `services/ollama-router/`, `services/ollama-monitor/` → `services/osr-router/`, `services/osr-monitor/` in the configuration repository | The update moves the directories in the config repo with `git mv` (your `router.ini` and `monitor.ini` go along), and its `apply` stops, disables and removes the old units, enables the new ones if the old ones were enabled, and moves `/var/lib/ollama-monitor` to `/var/lib/osr-monitor`. The router is down for its restart. The installer moves the directories in an existing Gitea repository the same way when it seeds it. Logs from before stay under `journalctl -u ollama-router`. An existing `monitor.ini` keeps its `ollama-router` health-check name; rename that key to `osr-router` if you want alerts to use the new name |
| Service account `ollama-router` → `osr-router` | The update's `apply` stops the services that run as it, renames the account and its group in place (`usermod`/`groupmod`: the UID and GID stay, so file ownership is unchanged) and starts them again. If a process still runs as the old account the rename is refused, the services start again and nothing is applied. A failed apply later on keeps the new name. `env/router.env` gets `MATTERMOST_CHANNEL=ollama-monitor` and `MATTERMOST_MONITOR_USER=OllamaMonitor` written in if it did not set them, so alerts keep going where they went |
| Defaults for new installs: Gitea router account `ollama-router` → `osr-router`; Mattermost team `ollama` → `osr`, channel `ollama-monitor` → `osr-monitor`, posting name `OllamaMonitor` → `OSRMonitor` | Existing targets keep theirs: Gitea's `--reconfigure` uses its recorded router account, and Mattermost now records its team and channel (one set up before that keeps `ollama` and `ollama-monitor`). The router's `env/router.env` already names its channel and posting name |

New installs use only the new names. Kept as they are: `/app/router`,
`manage-model-servers`, the `OLLAMA_*` settings (they configure Ollama
servers) and the `osr-router`/`osr-target` tags.

