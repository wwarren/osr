# Open Terminal target

Creates an unprivileged Debian LXC for
[Open Terminal](https://github.com/open-webui/open-terminal) and registers it
as a **system Open Terminal connection** in the router's Open WebUI. Every
user gets an **isolated workspace**: each Open WebUI account, and each agent
CT (Hermes, OpenClaw, DeepSeek Harness) connected to it, works in its own
open-terminal process under its own Linux account, with its own files,
processes, `/tmp`, key and resource limits.

It installs upstream tag `v0.14.0`, verified against reviewed commit
`b58442aa8599755525878f917b621e0145b0e8f7`, into a venv built from a
hash-locked `requirements.lock`. The CT has no access to the Proxmox host or
the router's filesystem.

```
Open WebUI ──(key openwebui, X-User-Id: <account>)──┐
Hermes  ──(key hermes-<ct>, MCP)───────────────────┤
OpenClaw ──(key openclaw-<ct>, MCP)─────────────────┼─> open-terminal-gateway :8000 ──> open-terminal-ws@<id> 127.0.0.1:20000-29999
DeepSeek ──(key deepseek-harness-<ct>, MCP)─────────┘          │ (ot-gateway)            (ot-<id>, /srv/open-terminal/ws/<id>)
                                                               └─> open-terminal-spawner (root, Unix socket): accounts, keys, start/stop
```

## How the isolation works

- **One key per client.** `clients.json` (root:ot-gateway, 0640) holds a
  SHA-256 hash of each client's key, never the key. Open WebUI's key is the
  CT's `/etc/open-terminal/api-key`; each agent CT gets its own, issued by
  its provisioner. `open-terminal-clients` lists, issues, rotates and
  revokes them; the gateway rereads the file when it changes.
- **One workspace per (client, user).** Open WebUI sends every proxied
  request with `X-User-Id` (the account ID). An agent client has exactly one
  workspace, its default user's (`default`): it sends no `X-User-Id`, and
  naming any other user is refused, so its key (which the agent's own tools
  can read) cannot open or create more. The workspace ID is a hash of client
  *and* user, so the same name in two clients is two workspaces. The spawner records each workspace's owner
  (`/var/lib/open-terminal/workspaces/<id>.json`) and refuses an ID recorded
  for anyone else, so two names never share one.
- **One process per workspace.** The root `open-terminal-spawner` creates the
  workspace's account `ot-<id>` (locked password), its home
  `/srv/open-terminal/ws/<id>` (0700), a root-only key and port
  (`/etc/open-terminal/ws/<id>.env`), and starts
  `open-terminal-ws@<id>.service`. That instance runs upstream Open Terminal
  in single-user mode on loopback, with `ProtectSystem=strict`, write access
  to its own home only, a private `/tmp`, other processes hidden
  (`ProtectProc=invisible`), no capabilities, `NoNewPrivileges`, and
  `MemoryMax`/`TasksMax`/`CPUQuota` from the installer. Its key reaches only
  its own workspace; reading it from `/proc/self/environ` gains nothing.
- **Started on demand, stopped when idle.** The first request starts a
  workspace (about two seconds). One unused for `OPEN_TERMINAL_IDLE_MINUTES`
  (default 120) is stopped. At most `OPEN_TERMINAL_MAX_ACTIVE` (default 8)
  run at once; the least recently used idle one makes room, and when all are
  busy the gateway answers 503. Files stay; processes left running in a
  stopped workspace end with it.
- **Requests without a user** may read only what is the same everywhere
  (`/openapi.json`, `/api/config`, `/system`, which Open WebUI caches and
  verifies without a user). An always-running metadata workspace answers
  them. Everything else needs a user.

Upstream's own `OPEN_TERMINAL_MULTI_USER` mode is **not** used: upstream
documents it as workspace separation without a security boundary, and in
v0.14.0 its file API runs as one server account that belongs to every
user's group (a symlink in one home reaches another user's files) and keeps
the shared key in its environment.

**What is still shared.** One kernel and one network namespace: a workspace
can connect to ports another workspace opens on the CT, and reach the
internet as before. The memory, task and CPU limits keep one workspace from
starving the others, but disk space is shared (`/srv/open-terminal`). The
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
- Memory for the workspaces you expect at once: about 100 MB per running
  workspace plus what its commands use. New CTs get 4096 MiB (`MEMORY_MB`).

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
`OPEN_TERMINAL_PORT` changes the gateway port (not 20000-29999, the
workspaces'); `--help` lists all options. The provisioner waits for a default
route and DNS before the installer runs `apt-get`.

`pct create` runs with `umask 022` (temporary credentials stay under 077),
because Proxmox's unprivileged template extraction inherits the mask; a
restrictive one gives `tar: /var/lib/lxc/<id>/rootfs: Cannot open: Permission
denied`. After such a failure, check `pct config <id>` and `pvesm list
<storage> --vmid <id>`, remove the partial CT or disk, then rerun. If it
persists, check access along `/var/lib/lxc/<id>/rootfs` and the storage's ACL
and mount options; the script does not change host storage permissions.

**Integration.** Before saving, it checks from the router that the gateway
accepts the key as client `openwebui` (`/osr/v1/whoami`; Open WebUI's own
verify reads only `/api/config`, which answers without a working key) and
reachability as Open WebUI's backend sees it. Open WebUI is not restarted and
existing terminal connections stay. If this last step fails, the CT remains:
fix the cause and rerun with `CT_ID`, `ROUTER` and `--integrate-only` (plus
`OPEN_TERMINAL_PORT` if changed). `--integrate-only` also connects an existing
terminal CT to a different or rebuilt router; it only works once Open
Terminal is installed in a running CT.

### Workspaces

| Setting | Default | Meaning |
|---|---|---|
| `OPEN_TERMINAL_IDLE_MINUTES` | `120` | Stop a workspace nobody used this long (`0`: never) |
| `OPEN_TERMINAL_MAX_ACTIVE` | `8` | Workspaces running at once |
| `OPEN_TERMINAL_WS_MEMORY` | `1G` | `MemoryMax` per workspace (`512M`, `2G`, `infinity`) |
| `OPEN_TERMINAL_WS_TASKS` | `512` | `TasksMax` per workspace |
| `OPEN_TERMINAL_WS_CPU` | `100%` | `CPUQuota` per workspace (100% = one core) |

Give them to `provision-lxc.sh` or to `install-target.sh` in the CT. Unset,
a rerun keeps the values recorded in `/etc/open-terminal/service.env`
(`tools/upgrade-all.sh` passes only the port).

In the CT:

```bash
open-terminal-clients list                 # clients and their default users
open-terminal-clients workspaces           # ID, client, user, created, running/stopped
systemctl list-units 'open-terminal-ws@*'  # running workspaces
journalctl -u open-terminal-gateway -u open-terminal-spawner -n 100 --no-pager
```

To delete a workspace: `systemctl stop open-terminal-ws@<id>`, then remove
the `ot-<id>` account (`userdel ot-<id>`), `/srv/open-terminal/ws/<id>`,
`/etc/open-terminal/ws/<id>.env` and
`/var/lib/open-terminal/workspaces/<id>.json`. Revoking a client keeps its
workspaces.

### Connect the agents

Each agent connects itself, with its own provisioner on this host:

```bash
OPEN_TERMINAL_URL=http://<terminal-ip>:8000 bash targets/hermes/provision-lxc.sh --reconfigure
OPEN_TERMINAL_URL=http://<terminal-ip>:8000 bash targets/openclaw/provision-lxc.sh --reconfigure
CT_ID=<id> ROUTER_CT_ID=<router> OPEN_TERMINAL_URL=http://<terminal-ip>:8000 \
  bash targets/deepseek-harness/provision-lxc.sh --reconfigure
```

The provisioner finds the terminal CT by its address (or `OPEN_TERMINAL_CT_ID`),
runs `open-terminal-clients issue <agent>-<ct>` there, adds one rule to the
terminal CT's firewall (`# osr-open-terminal-client <agent>-<ct>`; every other
line stays), opens the agent's restricted egress to the gateway, and pushes the
key into the agent CT. The agent gets an MCP server whose tools are its
workspace's Open Terminal operations (run a command, read, write, search and
replace files, follow a process). A key the terminal still accepts is kept by
later reconfigures; `OPEN_TERMINAL_URL=` revokes it and removes the rule. For a
terminal on another host, issue a key there and pass it as
`OPEN_TERMINAL_KEY_FILE`, and admit the agent in that terminal's firewall
yourself. The main installer does all this when Open Terminal and the agents
are selected together.

The agents keep their own shell and file tools in their own CTs; the
workspace adds a separate place to work. Everyone who uses one agent shares
that agent's workspace, as they share its memory: the agents do not tell
their tools which person is asking.

### Repair a CT from the earlier installer

The earlier installer made `/etc/open-terminal` 0700, so the service account
could not read the optional `config.toml` and exited with `PermissionError`.
It is now 0711 (`api-key` and the workspace keys stay root-only). For a CT
whose install failed, from `targets/open-terminal` on the host (do not
provision that ID again):

```bash
for f in install-target.sh open-terminal-gateway.service open-terminal-spawner.service \
         open-terminal-ws@.service gateway.py spawner.py open-terminal-clients requirements.in requirements.lock; do
  pct push <id> "$f" "/root/open-terminal-deploy/$f"
done
pct exec <id> -- bash /root/open-terminal-deploy/install-target.sh
pct exec <id> -- curl -fsS http://127.0.0.1:8000/health
CT_ID=<id> bash provision-lxc.sh --integrate-only
```

## Verify and use

```bash
pct exec <terminal-id> -- systemctl status open-terminal-gateway open-terminal-spawner --no-pager
pct exec <terminal-id> -- curl -fsS http://127.0.0.1:8000/health      # "ok" once the metadata workspace runs
pct exec <router-id> -- curl -fsS "http://<terminal-ip>:8000/health"  # or from the router's shell
pct exec <terminal-id> -- journalctl -u open-terminal-gateway -n 100 --no-pager
```

Refresh Open WebUI, pick **Open Terminal LXC** in a chat's terminal picker and
use a model with native function calling. The connection is **admin-only**
by default; grant users or groups in **Admin Settings → Integrations → Open
Terminal**, and each of them works in their own workspace. Open WebUI proxies
requests, so browsers never reach TCP 8000 and no browser origins are allowed
(`OPEN_TERMINAL_CORS_ALLOWED_ORIGINS=http://127.0.0.1`; empty would mean `*`).
With the Proxmox firewall on, the CT admits TCP 8000 only from the router and
the connected agent CTs.

**What a workspace can do.** Its shell runs as `ot-<id>` and can write only
its home (the workspace) and its private `/tmp`: no `apt install`, but
`pip install --user` and tools in the workspace work. Everyone with access to
the Open WebUI connection holds Open WebUI's client key in effect (Open WebUI
uses it on their behalf); it reaches only their own workspace through Open
WebUI, but anyone who obtains the key itself can name any Open WebUI user, so
keep it as secret as the admin token.

## Upgrade and roll back

Each install checks that the tag still resolves to the reviewed commit and
that the tag's Python dependencies match `requirements.in`, refusing before pip
otherwise. Every commit and lock hash gets its own venv,
`/opt/open-terminal/venv-<commit>-<lock-sha256>`, with
`/opt/open-terminal/venv` pointing at the active one; a failed build leaves the
active venv in place, and partial venvs are rebuilt on retry. Only once the new
venv is ready are the files changed, and every file the run replaces or
removes (the units, `service.env`, `workspace.env`, the limits drop-in,
`clients.json`, the gateway, spawner and `open-terminal-clients`, and the
earlier `open-terminal.service`) is copied to `/etc/open-terminal/rollback/`
first. If the restart or the health check fails, the previous venv, files and
services are restored and checked on the previous port; a rollback that does
not come back keeps its copies there. Running workspaces are stopped on every
applied change and start again with the new release on their next request.
An unchanged rerun on a healthy terminal prints "nothing to do".

**From the single shared workspace.** A CT installed before per-user
workspaces is converted the same way: `open-terminal.service` is stopped and
removed, `service.env` no longer holds the key, Open WebUI's key becomes
client `openwebui`, and the old venv is the rollback target. The shared files
stay in `/srv/open-terminal/workspace` (owner `open-terminal`, out of every
workspace's reach); copy what users need into their workspaces. Open WebUI's
connection keeps working without `--integrate-only`.

To upgrade to a reviewed newer release, update `requirements.in` if its
`pyproject.toml` dependencies changed and regenerate the lock (below), then:

```bash
for f in install-target.sh open-terminal-gateway.service open-terminal-spawner.service \
         open-terminal-ws@.service gateway.py spawner.py open-terminal-clients requirements.in requirements.lock; do
  pct push <id> "$f" "/root/open-terminal-deploy/$f"
done
pct exec <id> -- env OPEN_TERMINAL_VERSION=<reviewed-tag> OPEN_TERMINAL_COMMIT=<40-digit SHA-1> \
  bash /root/open-terminal-deploy/install-target.sh
```

Before moving the pin, check that the new release still runs single-user on
loopback with `run --host --port --cwd`, still reads `OPEN_TERMINAL_API_KEY`
and `OPEN_TERMINAL_SYSTEM_PROMPT`, and still names the operations the gateway
offers agents (`MCP_TOOLS` in `gateway.py`; missing ones are skipped).

### Updating the pin

`requirements.lock` comes from `requirements.in` (the release's runtime
dependencies plus `hatchling`, so the package builds offline from the verified
checkout) and must resolve identically on Python 3.11 (Debian 12) and 3.13
(Debian 13). The gateway uses only packages already in it (starlette, httpx,
websockets, uvicorn).

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
bash targets/open-terminal/test-client-lib.sh   # the agent provisioners' key and firewall helpers
python3 targets/open-terminal/test-integration.py
python3 targets/open-terminal/test-webui-probe.py
OPEN_TERMINAL_PYTHON=<venv from requirements.lock>/bin/python \
  bash tests/run-tests.sh open-terminal-gateway
```

The install suite covers a fresh install, a moved tag, dependency drift, an
unpinned version, upgrade, rollback and the move from the shared workspace.
The gateway suite runs the real gateway and spawner with stub `useradd` and
`systemctl` that start fake workspaces: separate workspaces per user and per
client, keys required and revocable, requests without a user, uploads, the
WebSocket terminal, MCP, a workspace recorded for someone else, restarts, idle
stops and the active limit. The integration suite runs `integrate-webui.py`
against a mock Open WebUI and gateway. All run in `tests/run-tests.sh` and CI.
None of them start upstream Open Terminal or systemd's sandbox: check a new
release or a new Proxmox version on a real CT (two Open WebUI users, one
agent) before relying on it.
