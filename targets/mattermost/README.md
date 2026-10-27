# Mattermost service for Ollama Smart Router

Mattermost receives the router's **health alerts**. The `ollama-monitor`
service posts host and service state changes to an incoming webhook (see the
main README). This target creates a separate Ubuntu 24.04 LXC (`MATTERMOST_CT_VERSION=22.04`
for an older one; Mattermost publishes for Ubuntu only) with the
[Proxmox VE community script](https://community-scripts.org/scripts/mattermost)
(`ct/mattermost.sh`; PostgreSQL 16, Mattermost from its apt repository, port
8065). It then does the first-run setup inside the CT without the browser,
and creates the webhook the monitor posts to.

Ubuntu 26.04 can be selected explicitly for future testing, but Mattermost does
not currently support it.

The router installer offers this target at the start of an interactive install
(menu entry `mattermost`). It creates the CT before the router, then reads the
webhook URL from it for its Mattermost prompt. Run it on its own for an
existing router.

## Provision on the Proxmox host

```bash
CT_ID=277 IP_CIDR=192.168.11.77/24 GATEWAY=192.168.11.1 STORAGE=local-lvm \
bash targets/mattermost/provision-lxc.sh --dry-run      # print the plan

CT_ID=277 IP_CIDR=192.168.11.77/24 GATEWAY=192.168.11.1 STORAGE=local-lvm \
bash targets/mattermost/provision-lxc.sh                # pick "Default" in the community menu
```

The community script shows its own menu: choose **Default** to accept the
presets. It also asks you to confirm Mattermost's own apt repository set-up
script, which it does not audit.

When Mattermost answers, `install-target.sh` runs in the CT and uses `mmctl`
in local mode:

1. **Turns local mode on** with a systemd drop-in,
   `mattermost.service.d/10-local-mode.conf`, which sets
   `MM_SERVICESETTINGS_ENABLELOCALMODE=true`. `mmctl --local` then manages the
   server over `/var/tmp/mattermost_local.socket`, which only root and the
   `mattermost` account can open.
2. **Creates the administrator** `MATTERMOST_ADMIN_USER` (default `mmadmin`).
   Its random password is in `/etc/mattermost-target/admin-password`.
3. **Creates the team** `MATTERMOST_TEAM` (default `ollama`) and the alert
   channel `MATTERMOST_CHANNEL` (default `ollama-monitor`).
4. **Enables incoming webhooks and username/icon overrides.** The monitor
   posts as `MATTERMOST_MONITOR_USER`.
5. **Creates one incoming webhook** for that channel. Its URL
   (`<SiteURL>/hooks/<id>`) is in `/etc/mattermost-target/webhook-url`. An empty
   `SiteURL` is first set to `http://<CT address>:8065`.

All results are root-only (0600) files in `/etc/mattermost-target/`: `url`,
`admin-user`, `admin-password` and `webhook-url`.

| Setting | Default | Meaning |
|---|---|---|
| `CT_ID`, `IP_CIDR`, `GATEWAY`, `STORAGE`, `BRIDGE`, `NAMESERVER`, `VLAN_TAG`, `SSH_PUBLIC_KEY` | next free ID, DHCP | CT settings, passed to the community script as its `var_*` presets. |
| `CORES`, `MEMORY_MB`, `ROOTFS_GB` | 2, 4096, 16 | CT size (Mattermost plus PostgreSQL). |
| `MATTERMOST_TEAM`, `MATTERMOST_CHANNEL` | `ollama`, `ollama-monitor` | URL names (lowercase letters, digits, `-`, `_`). |
| `MATTERMOST_ADMIN_USER`, `MATTERMOST_ADMIN_EMAIL` | `mmadmin`, `<name>@<host>.local` | The administrator. |
| `READY_TIMEOUT` | 120 | Seconds to wait for Mattermost to answer. |
| `MATTERMOST_CT_VERSION` | `24.04` | Ubuntu release for the CT. |
| `COMMUNITY_SCRIPT_URL`, `COMMUNITY_SCRIPT_SHA256` | ProxmoxVE `main` | The script to run. Every run prints its checksum; a pin refuses any other copy. |

| Mode | Does |
|---|---|
| default | Community script, then the setup above. |
| `--create-only` | Community script only, then the browser steps to do by hand (the earlier `tools/install-mattermost.sh` behaviour). |
| `--reconfigure` | Only the setup above, in the existing `CT_ID`. Repairs a failed first run, or recreates a deleted webhook. |

Reruns keep what exists: the administrator, team and channel are never
recreated, a webhook that still exists is kept, and Mattermost is restarted
only when the drop-in changes.

On an existing router, give it the webhook and send a test alert:

```bash
manage-model-servers set-webhook "$(pct exec 277 -- cat /etc/mattermost-target/webhook-url)"
manage-model-servers test-alert
```

## Security notes

- **The first account.** Until `install-target.sh` has created the
  administrator, which it does seconds after the community script finishes,
  the first account anyone makes in the browser becomes the system admin. Keep
  the CT on a trusted segment while it is created.
- **The webhook URL is a secret.** Anyone who has it can post to the channel.
- **Local mode** stays on, so reruns can manage the server. It gives
  unauthenticated admin access over the socket, but only to root and the
  `mattermost` account in this CT, which already control the server. Remove
  the drop-in and restart Mattermost to turn it off.
- **The administrator password** is passed to `mmctl` inside this dedicated CT,
  and stored root-only.
- **Versions.** The checksum pins `ct/mattermost.sh` only. When it runs, it
  fetches `build.func`, the install script and Mattermost's repository set-up
  script.
