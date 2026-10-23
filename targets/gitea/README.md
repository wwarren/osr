# Gitea service for Ollama Smart Router

Gitea holds the router's **configuration repository**. The router clones it at
provisioning, and `manage-model-servers commit` pushes every change to it (see
the main README). This target creates a separate Debian 13 LXC with the
[Proxmox VE community script](https://community-scripts.org/scripts/gitea)
(`ct/gitea.sh`; SQLite, port 3000). It then finishes Gitea's setup inside the
CT without the browser and prepares the account the router uses.

The router installer offers this target at the start of an interactive install
(menu entry `gitea`). It creates the CT before the router, then reads the URL,
router account and token from it for its Gitea prompts. Run it on its own for
an existing router, or to create Gitea first.

## Provision on the Proxmox host

```bash
CT_ID=276 IP_CIDR=192.168.11.76/24 GATEWAY=192.168.11.1 STORAGE=local-lvm \
bash targets/gitea/provision-lxc.sh --dry-run      # print the plan

CT_ID=276 IP_CIDR=192.168.11.76/24 GATEWAY=192.168.11.1 STORAGE=local-lvm \
bash targets/gitea/provision-lxc.sh                # pick "Default" in the community menu
```

The community script shows its own menu: choose **Default** to accept the
presets (Debian 13, unprivileged, the CT ID and network given here).

When Gitea answers, `install-target.sh` runs in the CT:

1. **Writes `/etc/gitea/app.ini`** with:
   - SQLite in `/var/lib/gitea/data`;
   - `ROOT_URL http://<CT address>:3000/`;
   - generated `SECRET_KEY`, `INTERNAL_TOKEN` and `JWT_SECRET`;
   - `INSTALL_LOCK` (the web installer is closed);
   - self-registration off, and sign-in required to view anything.

   It then migrates the database and restarts Gitea.
2. **Creates the administrator** `GITEA_SITE_ADMIN` (default `gitea-admin`).
   Its random password is in `/etc/gitea-target/admin-password`, and must be
   changed at the first sign-in.
3. **Creates the router account** `GITEA_ROUTER_USER` (default
   `ollama-router`), a non-admin account that nobody signs in as.
4. **Creates the router account's token** with `write:repository,write:user`
   scopes, so the router installer can create its repository under that
   account. The token is in `/etc/gitea-target/router-token`.

All results are root-only (0600) files in `/etc/gitea-target/`: `url`,
`admin-user`, `admin-password`, `router-user` and `router-token`. Read them
with `pct exec <CT_ID> -- cat /etc/gitea-target/<file>`.

| Setting | Default | Meaning |
|---|---|---|
| `CT_ID`, `IP_CIDR`, `GATEWAY`, `STORAGE`, `BRIDGE`, `NAMESERVER`, `VLAN_TAG`, `SSH_PUBLIC_KEY` | next free ID, DHCP | CT settings, passed to the community script as its `var_*` presets. Use a static address: it is the router's Gitea URL. |
| `CORES`, `MEMORY_MB`, `ROOTFS_GB` | 1, 1024, 8 | CT size. |
| `GITEA_SITE_ADMIN`, `GITEA_SITE_ADMIN_EMAIL` | `gitea-admin`, `<name>@<address>.local` | The administrator. |
| `GITEA_ROUTER_USER`, `GITEA_ROUTER_EMAIL` | `ollama-router`, … | The router's account. Gitea reserves `admin` and other route names. |
| `GITEA_DOMAIN` | the static IP, else the CT's address | Host name in `ROOT_URL`, e.g. a DNS name. |
| `READY_TIMEOUT` | 120 | Seconds to wait for the web UI. |
| `COMMUNITY_SCRIPT_URL`, `COMMUNITY_SCRIPT_SHA256` | ProxmoxVE `main` | The script to run. Every run prints its checksum; a pin refuses any other copy. |

| Mode | Does |
|---|---|
| default | Community script, then the setup above. |
| `--create-only` | Community script only, then the browser steps to do by hand (the earlier `tools/install-gitea.sh` behaviour). |
| `--reconfigure` | Only the setup above, in the existing `CT_ID`. Repairs a failed first run, or recreates a revoked token. |

Reruns keep what exists:
- an `app.ini` that is already locked (a Gitea set up in the browser) is kept,
  with its own `ROOT_URL`;
- accounts are never recreated;
- a token that still works is kept.

To use this Gitea with an existing router, give the router installer, or
`manage-model-servers set-token`, the values from `url`, `router-user` and
`router-token`: `GITEA_SERVER_URL`, `GITEA_ADMIN_USER` (the router account,
despite the variable's name) and `GITEA_DEPLOY_TOKEN`.

## Security notes

- **The setup window.** Until `install-target.sh` has written the locked
  `app.ini`, which it does seconds after the community script finishes, the
  web installer is open to anyone who can reach port 3000. Keep the CT on a
  trusted segment while it is created.
- **Token scope.** Gitea tokens cannot be limited to one repository. That is
  why the router uses a dedicated non-admin account. For a repository it does
  not own, add the account as a collaborator with Write access.
- **Plain HTTP.** The server answers on `http://<ip>:3000`, so the token
  travels unencrypted on every check and push. On an untrusted network, put a
  TLS reverse proxy in front of it and give the router its `https://` URL
  (`GITEA_DOMAIN` sets the host name Gitea itself uses).
- **The administrator password** is passed to the `gitea` command line inside
  this dedicated CT, and stored root-only.
- **Versions.** The checksum pins `ct/gitea.sh` only. When it runs, it fetches
  the shared `build.func` and `install/gitea-install.sh`, and those install the
  latest Gitea release from GitHub. Update Gitea later with the community
  script's update, run inside the CT as its community-scripts page describes.
