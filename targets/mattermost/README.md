# Mattermost service

Mattermost receives the router's **health alerts**: `ollama-monitor` posts host
and service state changes to an incoming webhook. This target creates an
Ubuntu 24.04 LXC with the
[Proxmox VE community script](https://community-scripts.org/scripts/mattermost)
(`ct/mattermost.sh`; PostgreSQL 16, Mattermost from its apt repository, port
8065), does the first-run setup in the CT without the browser and creates the
monitor's webhook. The router installer offers it as menu entry `mattermost`,
creates it before the router and uses its webhook as the prompt default. Run it
alone for an existing router. The optional [hcom observer](../hcom/README.md)
adds a separate `agent-handoffs` channel with `configure-agent-handoffs.sh`,
leaving the health channel and webhook untouched.

## Provision

```bash
bash targets/mattermost/provision-lxc.sh
```

A new install prompts for IP/CIDR (or `dhcp`), gateway and storage (preset
`IP_CIDR`, `GATEWAY`, `TEMPLATE_STORAGE`, `STORAGE`); no address is chosen
automatically. The CT ID defaults to the cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID` to choose another). In the community script's menu choose **Default**; it
also asks you to confirm Mattermost's own (unaudited) apt repository script. A
summary is shown before anything changes. When Mattermost answers,
`install-target.sh` uses `mmctl --local`:

1. Enables local mode with the drop-in `mattermost.service.d/10-local-mode.conf`
   (`MM_SERVICESETTINGS_ENABLELOCALMODE=true`); the socket
   `/var/tmp/mattermost_local.socket` is open only to root and `mattermost`.
2. Creates the administrator `MATTERMOST_ADMIN_USER` (`mmadmin`) with a random
   password.
3. Creates team `MATTERMOST_TEAM` (`ollama`) and channel `MATTERMOST_CHANNEL`
   (`ollama-monitor`).
4. Enables incoming webhooks and username/icon overrides (the monitor posts as
   `MATTERMOST_MONITOR_USER`).
5. Creates one incoming webhook for the channel (an empty `SiteURL` is first
   set to `http://<address>:8065`).

Results are root-only (0600) files in `/etc/mattermost-target/`: `url`,
`admin-user`, `admin-password`, `webhook-url`.

| Setting | Default | Meaning |
|---|---|---|
| `CT_ID`, `IP_CIDR`, `GATEWAY`, `STORAGE`, `BRIDGE`, `NAMESERVER`, `VLAN_TAG`, `SSH_PUBLIC_KEY` | ID: next free; IP required; gateway for static IP | Community script `var_*` presets |
| `CORES`, `MEMORY_MB`, `ROOTFS_GB` | 2, 4096, 16 | CT size (Mattermost plus PostgreSQL) |
| `MATTERMOST_TEAM`, `MATTERMOST_CHANNEL` | `ollama`, `ollama-monitor` | URL names (lowercase letters, digits, `-`, `_`) |
| `MATTERMOST_ADMIN_USER`, `MATTERMOST_ADMIN_EMAIL` | `mmadmin`, `<name>@<host>.local` | Administrator |
| `READY_TIMEOUT` | 120 | Seconds to wait for Mattermost |
| `MATTERMOST_CT_VERSION` | `24.04` | Ubuntu release; 26.04 is accepted for future testing but not yet supported by Mattermost |
| `COMMUNITY_SCRIPT_URL`, `COMMUNITY_SCRIPT_SHA256` | ProxmoxVE `main` | Each run prints the checksum; a pin refuses other copies |

| Mode | Does |
|---|---|
| default | Community script, then the setup above |
| `--create-only` | Community script only; browser setup left to you (also `tools/install-mattermost.sh`) |
| `--reconfigure` | Setup only, in an existing CT: repairs a failed run or recreates a deleted webhook. Asks for the CT (offering the one tagged `mattermost`) and offers recorded settings |

Reruns never recreate the administrator, team or channel, keep an existing
webhook, and restart Mattermost only when the drop-in changes. Dry runs make no
Proxmox queries.

To give an existing router the webhook, from a repository clone on the Proxmox
host (the script finds the router CT and runs there):

```bash
bash install/manage-model-servers.sh set-webhook "$(pct exec 277 -- cat /etc/mattermost-target/webhook-url)"
bash install/manage-model-servers.sh test-alert
```

## Security notes

- **First account.** Until the administrator exists (seconds after the
  community script), the first browser sign-up becomes system admin: create the
  CT on a trusted segment.
- **The webhook URL is a secret**: anyone holding it can post to the channel.
- **Local mode** stays on so reruns can manage the server; it gives
  unauthenticated admin access over the socket, but only to root and
  `mattermost` in this CT. Remove the drop-in and restart to turn it off.
- The administrator password is passed to `mmctl` inside this CT and stored
  root-only.
- **Versions.** The checksum pins `ct/mattermost.sh` only; it fetches
  `build.func`, the install script and Mattermost's repository script.
