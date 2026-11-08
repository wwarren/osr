# Gitea service

Gitea holds the router's **configuration repository**: the router clones it at
provisioning and `manage-model-servers commit` pushes changes to it. This
target creates a Debian 13 LXC with the
[Proxmox VE community script](https://community-scripts.org/scripts/gitea)
(`ct/gitea.sh`; SQLite, port 3000), then finishes Gitea's setup in the CT
without the browser and prepares the router's account. The router installer
offers it as menu entry `gitea`, creates it before the router and uses its URL,
account and token as prompt defaults. Run it alone for an existing router.

## Provision

```bash
bash targets/gitea/provision-lxc.sh
```

A new install prompts for IP/CIDR (or `dhcp`), gateway and storage (preset
`IP_CIDR`, `GATEWAY`, `TEMPLATE_STORAGE`, `STORAGE`); no address is chosen
automatically. The CT ID defaults to the cluster's next free ID (Enter, or an unattended run, takes it; preset `CT_ID` to choose another). The community script shows its own menu: choose
**Default**. A summary is shown before anything changes. When Gitea answers,
`install-target.sh` runs in the CT:

1. Writes `/etc/gitea/app.ini`: SQLite in `/var/lib/gitea/data`, `ROOT_URL
   http://<address>:3000/`, generated `SECRET_KEY`, `INTERNAL_TOKEN` and
   `JWT_SECRET`, `INSTALL_LOCK` (web installer closed), no self-registration,
   sign-in required. Then migrates and restarts.
2. Creates the administrator `GITEA_SITE_ADMIN` (`gitea-admin`) with a random
   password that must be changed at first sign-in.
3. Creates the non-admin router account `GITEA_ROUTER_USER` (`ollama-router`)
   and a `write:repository,write:user` token, so the router installer can
   create its repository under that account.

Results are root-only (0600) files in `/etc/gitea-target/`: `url`,
`admin-user`, `admin-password`, `router-user`, `router-token`
(`pct exec <id> -- cat /etc/gitea-target/<file>`).

| Setting | Default | Meaning |
|---|---|---|
| `CT_ID`, `IP_CIDR`, `GATEWAY`, `STORAGE`, `BRIDGE`, `NAMESERVER`, `VLAN_TAG`, `SSH_PUBLIC_KEY` | ID: next free; IP required; gateway for static IP | Community script `var_*` presets. Use a static address: it is the router's Gitea URL |
| `CORES`, `MEMORY_MB`, `ROOTFS_GB` | 1, 1024, 8 | CT size |
| `GITEA_SITE_ADMIN`, `GITEA_SITE_ADMIN_EMAIL` | `gitea-admin`, `<name>@<address>.local` | Administrator |
| `GITEA_ROUTER_USER`, `GITEA_ROUTER_EMAIL` | `ollama-router`, … | Router account (Gitea reserves `admin` and other route names) |
| `GITEA_DOMAIN` | Static IP, else the CT's address | Host name in `ROOT_URL` |
| `READY_TIMEOUT` | 120 | Seconds to wait for the web UI |
| `COMMUNITY_SCRIPT_URL`, `COMMUNITY_SCRIPT_SHA256` | ProxmoxVE `main` | Each run prints the checksum; a pin refuses other copies |

| Mode | Does |
|---|---|
| default | Community script, then the setup above |
| `--create-only` | Community script only; browser setup left to you (also `tools/install-gitea.sh`) |
| `--reconfigure` | Setup only, in an existing CT: repairs a failed run or recreates a revoked token. Asks for the CT (offering the one tagged `gitea`) and offers recorded settings |

Reruns keep a locked `app.ini` (including one set up in the browser) with its
`ROOT_URL`, never recreate accounts, and keep a working token. Dry runs make no
Proxmox queries.

**Connecting the router.** For the installer, set `GITEA_SERVER_URL` from
`url`, `GITEA_ADMIN_USER` from `router-user` (despite the name) and
`GITEA_DEPLOY_TOKEN` from `router-token`. On an existing router, update the URL
and account in `env/router.env`, then `manage-model-servers set-token` (it
changes only the token). A local-mode router's config checkout must also be
pointed at this repository before `commit` can push.

## Security notes

- **Setup window.** Until the locked `app.ini` is written (seconds after the
  community script), the web installer is open on port 3000: create the CT on a
  trusted segment.
- **Token scope.** Gitea tokens cannot be limited to one repository, hence the
  dedicated non-admin account. For a repository it does not own, add it as a
  collaborator with Write access.
- **Plain HTTP.** The token crosses the network on every check and push. On an
  untrusted network, use a TLS reverse proxy and give the router its `https://`
  URL (`GITEA_DOMAIN` sets Gitea's own host name).
- The administrator password is passed to the `gitea` CLI inside this CT and
  stored root-only.
- **Versions.** The checksum pins `ct/gitea.sh` only; it fetches `build.func`
  and `install/gitea-install.sh`, which install the latest Gitea release.
  Update Gitea later with the community script's update inside the CT.
