# Open Terminal target

Creates an unprivileged Debian LXC for
[Open Terminal](https://github.com/open-webui/open-terminal) and registers it
as a **system Open Terminal connection** in the router's Open WebUI. It
installs upstream tag `v0.14.0`, verified against reviewed commit
`b58442aa8599755525878f917b621e0145b0e8f7`, into a venv built from a
hash-locked `requirements.lock`, runs as the unprivileged `open-terminal` user
with its workspace in `/srv/open-terminal/workspace`, and has no access to the
Proxmox host or the router's filesystem.

The connection is **admin-only** by default; everyone granted access shares one
shell and workspace, so grant it only to trusted groups (**Admin Settings →
Integrations → Open Terminal**). With the Proxmox firewall on, the CT admits
TCP 8000 only from the router's address. The API also needs a random bearer
key (`/etc/open-terminal/api-key` and Open WebUI's server-side settings). The
internal API is plain HTTP, so keep the network trusted.

## Prerequisites

- A running Open WebUI from this repository with the Open Terminal
  integration (the pinned 0.12.4 has it), either a CT on this Proxmox node or
  any LXC/VM `root` on this node can reach over SSH.
- Root on the Proxmox node for the terminal CT, a free CT ID, a downloaded
  Debian 12/13 amd64 template, `rootdir` storage and a static IPv4 address
  reachable from the router.
- An **Open WebUI admin API key** (Settings → Account; enable API keys in Admin
  Settings → Authentication) or an admin session JWT. It is prompted for
  without echo, or read from `OPENWEBUI_ADMIN_TOKEN`, which is removed from the
  environment at once; temporary copies are deleted after use. The admin API
  is used so other terminal connections are preserved.
- Internet access from the new CT (Debian packages, GitHub, PyPI).

## Choose the router

| `ROUTER` | Reached with | Use for |
|---|---|---|
| A CT ID | `pct exec` / `pct push` | The router CT on this node |
| An IP or hostname | SSH as `root` (`ROUTER_SSH_PORT`, default 22) | A router on another node, a VM, any host root can log in to |

Without `ROUTER`, the *Router (Open WebUI)* section offers the CT tagged
`osr-router`. `ROUTER_CT_ID` or `ROUTER_SSH_HOST` force one kind (set only one
of the three). Over SSH one connection is reused, so a password is asked at
most once; the host key must already be known (or `StrictHostKeyChecking
accept-new`), and unattended runs need key login. Before changing anything the
script checks on the router that login works, `/app/openwebui/venv/bin/open-webui`
exists, `open-webui.service` is active, `python3` exists, and `GET /health` and
`GET /api/version` answer over loopback on the Open WebUI port (from
`/app/openwebui/.env`, default 8080; override with `OPENWEBUI_PORT`). A failure
exits before `pct create`. Files copied to the router go to a private
`/root/open-terminal-integration.*` directory that is removed afterwards; the
router's version-controlled configuration is never touched.

The firewall rule admits the address the router uses to reach the terminal
(`ip -4 route get <terminal IP>` on the router); set `ROUTER_IP` for NAT or a
proxy.

## Provision

From `targets/open-terminal` on the Proxmox host:

```bash
bash provision-lxc.sh             # interactive
bash provision-lxc.sh --dry-run   # prints every pct/ssh command; never logs in or queries Proxmox
```

After the router, it asks for the new CT ID (default: the cluster's next free
ID; an unattended run takes it),
template and storage menus (storage smaller than `ROOTFS_GB` is shown but not
selectable), static IP/CIDR, gateway and the admin key (not on dry runs, which
need `TEMPLATE` and `STORAGE` given). Unattended runs need `ROUTER`, `TEMPLATE`,
`STORAGE`, `IP_CIDR`, `GATEWAY` and `OPENWEBUI_ADMIN_TOKEN` (`CT_ID` is
optional).
`OPEN_TERMINAL_PORT` changes the port; `--help` lists all options. The
provisioner waits for a default route and DNS before the installer runs
`apt-get`.

`pct create` runs with `umask 022` (temporary credentials stay under 077),
because Proxmox's unprivileged template extraction inherits the mask; a
restrictive one gives `tar: /var/lib/lxc/<id>/rootfs: Cannot open: Permission
denied`. After such a failure, check `pct config <id>` and `pvesm list
<storage> --vmid <id>`, remove the partial CT or disk, then rerun. If it
persists, check access along `/var/lib/lxc/<id>/rootfs` and the storage's ACL
and mount options; the script does not change host storage permissions.

**Integration.** Before saving, it checks from the router the terminal key
against an endpoint that requires it (`/files/cwd`; Open WebUI's own verify
reads only the unauthenticated `/api/config`) and reachability as Open WebUI's
backend sees it. Open WebUI is not restarted and existing terminal connections
stay. If this last step fails, the CT remains: fix the cause and rerun with
`CT_ID`, `ROUTER` and `--integrate-only` (plus `OPEN_TERMINAL_PORT` if changed).
`--integrate-only` also connects an existing terminal CT to a different or
rebuilt router; it only works once Open Terminal is installed in a running CT.

### Repair a CT from the earlier installer

The earlier installer made `/etc/open-terminal` 0700, so the service account
could not read the optional `config.toml` and exited with `PermissionError`.
It is now 0711 (`api-key` and `service.env` stay 0600). For a CT whose install
failed, from `targets/open-terminal` on the host (do not provision that ID
again):

```bash
pct push <id> install-target.sh /root/open-terminal-deploy/install-target.sh --perms 0755
pct exec <id> -- bash /root/open-terminal-deploy/install-target.sh
pct exec <id> -- curl -fsS http://127.0.0.1:8000/health
CT_ID=<id> bash provision-lxc.sh --integrate-only
```

## Verify and use

```bash
pct exec <terminal-id> -- systemctl status open-terminal.service --no-pager
pct exec <terminal-id> -- curl -fsS http://127.0.0.1:8000/health
pct exec <router-id> -- curl -fsS "http://<terminal-ip>:8000/health"   # or from the router's shell
pct exec <terminal-id> -- journalctl -u open-terminal.service -n 100 --no-pager
```

Refresh Open WebUI, pick **Open Terminal LXC** in a chat's terminal picker and
use a model with native function calling. Open WebUI proxies requests, so
browsers never reach TCP 8000 and no browser origins are allowed
(`OPEN_TERMINAL_CORS_ALLOWED_ORIGINS=http://127.0.0.1`; empty would mean `*`).

**What the shell can do.** It runs as `open-terminal` under
`ProtectSystem=strict`, writing only under `/srv/open-terminal` and its private
`/tmp`: no `apt install`, but `pip install --user` and tools in the workspace
work. The key reaches the service through the root-only
`/etc/open-terminal/service.env`, yet the server process holds it in its
environment and the shell runs as the same account, so treat everyone with
access to the connection as holding the key (it grants nothing beyond the
shell).

## Upgrade and roll back

Each install checks that the tag still resolves to the reviewed commit and
that the tag's Python dependencies match `requirements.in`, refusing before pip
otherwise. Every commit and lock hash gets its own venv,
`/opt/open-terminal/venv-<commit>-<lock-sha256>`, with
`/opt/open-terminal/venv` pointing at the active one; a failed build leaves the
active venv in place, and partial venvs are rebuilt on retry. `service.env`
(the port) and the unit change only once the new venv is ready. If the switch,
restart or readiness check fails, the previous venv, `service.env` and unit
are restored and checked on the previous port. The active and previous venvs
are kept; `*.prev` configuration copies are removed after success. An
unchanged rerun on a healthy terminal prints "nothing to do"; a port change on
the same commit needs no rebuild. The workspace and key survive upgrades, and
CTs from the earlier script are converted the same way (the old venv becomes
the rollback target, key files root-only).

To upgrade to a reviewed newer release, update `requirements.in` if its
`pyproject.toml` dependencies changed and regenerate the lock (below), then:

```bash
for f in install-target.sh open-terminal.service requirements.in requirements.lock; do
  pct push <id> "$f" "/root/open-terminal-deploy/$f"
done
pct exec <id> -- env OPEN_TERMINAL_VERSION=<reviewed-tag> OPEN_TERMINAL_COMMIT=<40-digit SHA-1> \
  bash /root/open-terminal-deploy/install-target.sh
```

### Updating the pin

`requirements.lock` comes from `requirements.in` (the release's runtime
dependencies plus `hatchling`, so the package builds offline from the verified
checkout) and must resolve identically on Python 3.11 (Debian 12) and 3.13
(Debian 13):

```bash
uv pip compile requirements.in --generate-hashes --no-header --no-annotate \
  --python-version 3.13 --python-platform x86_64-unknown-linux-gnu -o requirements.lock
uv pip compile requirements.in --generate-hashes --no-header --no-annotate \
  --python-version 3.11 --python-platform x86_64-unknown-linux-gnu -o /tmp/py311.lock
diff <(grep '^[a-z]' requirements.lock) <(grep '^[a-z]' /tmp/py311.lock)
```

Then change `DEFAULT_VERSION` and `DEFAULT_COMMIT` in `install-target.sh`, the
version check in `provision-lxc.sh` and the version in this README.

## Tests

```bash
bash targets/open-terminal/test-provision.sh    # router parsing, SSH quoting, dry-run plans, input checks
bash targets/open-terminal/test-install.sh      # end-to-end cases need root
python3 targets/open-terminal/test-integration.py
python3 targets/open-terminal/test-webui-probe.py
```

The install suite covers a fresh install, a moved tag, dependency drift, an
unpinned version, upgrade, rollback and migration. The integration suite runs
`integrate-webui.py` against a mock Open WebUI and terminal (other connections
and grants preserved, failed verify, wrong key, malformed responses); the
probe suite checks the pre-install Open WebUI check. All four run in
`tests/run-tests.sh` and CI.
