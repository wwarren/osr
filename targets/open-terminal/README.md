# Open Terminal LXC for Ollama Smart Router

This installer creates a separate unprivileged Debian LXC for [Open Terminal](https://github.com/open-webui/open-terminal) and adds it as a **system Open Terminal connection** in the router's Open WebUI. It installs upstream tag `v0.14.0`, verified against its reviewed commit `b58442aa8599755525878f917b621e0145b0e8f7`, into a Python virtual environment built from a hash-locked `requirements.lock`. It runs the terminal as the unprivileged `open-terminal` user and keeps its workspace at `/srv/open-terminal/workspace`. It does not give the terminal access to the Proxmox host or the router CT's filesystem.

The Open WebUI connection is **admin-only** by default. All users granted access to this connection share one shell and workspace. In Open WebUI, grant access only to trusted groups under **Admin Settings → Integrations → Open Terminal**. When the Proxmox firewall is enabled, the new CT permits TCP 8000 only from the router CT's IPv4 address. The terminal also requires a random bearer key, stored in `/etc/open-terminal/api-key` and in Open WebUI's server-side connection settings. Keep the LXC network trusted, because the internal API uses HTTP.

## Prerequisites

- A running `ollama-smart-router` Open WebUI, installed by this repository, with the Open Terminal integration (the currently pinned WebUI `0.11.0` has it). It can be a CT on the Proxmox node where you run this script, or any LXC or VM that `root` on this node can log in to over SSH. That includes a router on another node, a VM, or one installed long before this terminal.
- Root access on the Proxmox node that will host the terminal CT, and a free CT ID there.
- A downloaded Debian 12 or 13 amd64 LXC template (`pveam list <template-storage>`), active storage that supports `rootdir`, and an unused static IPv4 address reachable from the router CT.
- An **Open WebUI admin API key** from Settings → Account (enable API keys in Admin Settings → Authentication first), or an admin session JWT. The script prompts for it without echoing. For unattended use, set `OPENWEBUI_ADMIN_TOKEN`; it is removed from the environment immediately, so child processes never see it. The script uses the admin API so that other terminal connections are preserved when this one is added. The credential is deleted from temporary files after the call.
- Internet access from the new CT for Debian packages, GitHub, and PyPI.

## Choose the router

`ROUTER` says where the existing Open WebUI runs:

| `ROUTER` | Reached with | Use for |
|---|---|---|
| `280` (a CT ID) | `pct exec` / `pct push` | the router CT on this Proxmox node |
| `192.168.11.80` or `router.lan` | SSH as `root` (`ROUTER_SSH_PORT=22` by default) | a router LXC on another node, a VM, or any host root can log in to |

If `ROUTER` is not set, the script asks for it:

```text
Existing ollama-smart-router Open WebUI:
  a CT ID on this Proxmox host (e.g. 280), or
  the IP address or hostname of its LXC/VM, reached as root over SSH
Open WebUI CT ID or IP address:
```

`ROUTER_CT_ID` or `ROUTER_SSH_HOST` force one kind. The older `ROUTER_CT_ID=280` form still works. Set only one of these or `ROUTER`. SSH login must be as `root`, since integration stages files under `/root` on the selected host.

Over SSH, the script opens one connection and reuses it for the whole run, so a password is entered at most once. The host key must be known: connect once by hand, or accept it with `StrictHostKeyChecking accept-new` in `~/.ssh/config`. Unattended runs need key-based login. Before changing anything, the script checks the following on the router:

- the login works;
- `/app/openwebui/venv/bin/open-webui` exists and is executable;
- `open-webui.service` is active;
- `python3` is present;
- the Open WebUI port, read from `/app/openwebui/.env` (default 8080). Set `OPENWEBUI_PORT` if your install uses another port;
- `GET /health` returns healthy JSON and `GET /api/version` returns an Open WebUI version over loopback on that port.

If any check fails, the script exits before `pct create` and reports the selected host and port. A dry run prints this verification step but does not contact the router.

All files it copies to the router go into a private `/root/open-terminal-integration.*` directory, which is removed at the end. The router's version-controlled configuration is never touched.

The firewall rule admits the address the router uses to reach the terminal, found with `ip -4 route get <terminal IP>` on the router. That works for a CT, a VM, or a router on another node or subnet. Set `ROUTER_IP` if the router reaches the terminal through NAT or a proxy.

## Run on the Proxmox host

Copy this `targets/open-terminal` directory to the Proxmox host that will host the terminal CT, then run:

```bash
cd /path/to/ollama-smart-router/targets/open-terminal
CT_ID=281 \
TEMPLATE='local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst' \
STORAGE=local-lvm \
IP_CIDR=192.168.11.81/24 \
GATEWAY=192.168.11.1 \
bash provision-lxc.sh --dry-run

CT_ID=281 \
TEMPLATE='local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst' \
STORAGE=local-lvm \
IP_CIDR=192.168.11.81/24 \
GATEWAY=192.168.11.1 \
bash provision-lxc.sh
```

At the prompt, enter the router CT ID if it is on this Proxmox host, or the router LXC/VM's IP address if it is elsewhere. For unattended runs, set `ROUTER=280` or `ROUTER=192.168.11.80`.

`--dry-run` prints every command it would run, `pct` or `ssh`, with placeholders for the values a real run reads from the router. It never logs in. Replace the template ID, storage, CT IDs, and network values with your own. `ROUTER_IP` and `OPENWEBUI_PORT` are detected on the router; set them explicitly if detection does not fit your network. Set `OPEN_TERMINAL_PORT` to change the terminal port. `--help` lists all options.

After starting the CT, the provisioner waits for a default route and DNS before the installer runs `apt-get`. A first boot can otherwise race the network.

Before anything is saved, the integration step checks two things from the router CT. First, it checks the terminal's key directly against an endpoint that requires it (`/files/cwd`). Open WebUI's own verify reads only `/api/config`, which needs no key, so a wrong key would otherwise pass. Second, it checks reachability as Open WebUI's backend sees it. The step does not restart Open WebUI or change the router's version-controlled configuration. Existing Open WebUI terminal connections stay in place. If the last step fails, the terminal CT remains available: fix the issue and rerun with `CT_ID`, `ROUTER` and `--integrate-only` (plus the correct `OPEN_TERMINAL_PORT` if you changed it). `--integrate-only` also connects a terminal CT you already have to a different or rebuilt router.

## Verify and use

```bash
pct exec 281 -- systemctl status open-terminal.service --no-pager
pct exec 281 -- curl -fsS http://127.0.0.1:8000/health
pct exec 280 -- curl -fsS http://192.168.11.81:8000/health    # or: ssh root@<router> curl -fsS ...
```

Refresh Open WebUI, choose **Open Terminal LXC** from the terminal picker in a chat, and use a model with native function calling. The Open WebUI admin connection proxies requests, so browsers never need direct access to TCP 8000. The service therefore allows no browser origins (`OPEN_TERMINAL_CORS_ALLOWED_ORIGINS=http://127.0.0.1`; an empty value would mean `*`). For troubleshooting, use `pct exec 281 -- journalctl -u open-terminal.service -n 100 --no-pager`.

## What the shell can and cannot do

- The shell runs as `open-terminal` inside its own LXC. It can read and change files that account can access there.
- The service is sandboxed with `ProtectSystem=strict`. The shell can write only under `/srv/open-terminal` (its home and workspace) and its private `/tmp`. `apt install` and other system changes are not possible from it. `pip install --user` and tools unpacked into the workspace do work.
- The API key reaches the service through a root-only (0600) `EnvironmentFile`, `/etc/open-terminal/service.env`, so the account cannot read the key files. The server process still holds the key in its environment, and the shell runs as the same account, so a terminal user *can* read the key from that process. This grants nothing beyond the shell they already have, but treat anyone with access to this connection as holding the key.

## Upgrade and roll back

Every install checks that the tag resolves to the reviewed commit, and refuses a tag that has been moved upstream. It also checks that the tag's Python dependencies still match `requirements.in`, the inputs of `requirements.lock`, and refuses before running pip if they differ. Each commit gets its own venv, `/opt/open-terminal/venv-<commit>`. `/opt/open-terminal/venv` points at the active one. If an upgraded service does not become healthy, the installer switches back to the previous venv and restarts it. The active venv and the one before it are kept.

To upgrade after reviewing a newer upstream release:

1. Update `requirements.in` if the release's `pyproject.toml` dependencies changed, then regenerate the lock (see below).
2. Copy the target files into the CT and run the installer with the new tag and its reviewed commit:

```bash
for f in install-target.sh open-terminal.service requirements.in requirements.lock; do
  pct push 281 "$f" "/root/open-terminal-deploy/$f"
done
pct exec 281 -- env OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=<40-digit SHA-1> \
  bash /root/open-terminal-deploy/install-target.sh
```

The workspace and key survive an in-place upgrade. Running the current installer on a CT built by the earlier version of this script converts it the same way. The old venv becomes the rollback target, and the key files become root-only.

### Updating the pin

`requirements.lock` is generated from `requirements.in`: the release's runtime dependencies, plus `hatchling` so the package builds offline from the verified checkout. It resolves to the same packages on Python 3.11 (Debian 12) and 3.13 (Debian 13). Regenerate it for each, and check the two agree:

```bash
uv pip compile requirements.in --generate-hashes --no-header --no-annotate \
  --python-version 3.13 --python-platform x86_64-unknown-linux-gnu -o requirements.lock
uv pip compile requirements.in --generate-hashes --no-header --no-annotate \
  --python-version 3.11 --python-platform x86_64-unknown-linux-gnu -o /tmp/py311.lock
diff <(grep '^[a-z]' requirements.lock) <(grep '^[a-z]' /tmp/py311.lock)
```

Then change `DEFAULT_VERSION` and `DEFAULT_COMMIT` in `install-target.sh`, the version check in `provision-lxc.sh`, and the version in this README.

## Tests

```bash
bash targets/open-terminal/test-provision.sh    # router parsing, SSH quoting, dry-run plans, input checks
bash targets/open-terminal/test-install.sh      # installer, as root for the end-to-end cases
python3 targets/open-terminal/test-integration.py
python3 targets/open-terminal/test-webui-probe.py
```

`test-install.sh` runs whole installs against stubs. It covers a fresh install, a moved tag, dependency drift, a version without a pin, an upgrade, a rollback, and migration from the earlier script's layout. `test-integration.py` runs `integrate-webui.py` against a mock Open WebUI and terminal. It covers preserving other connections and grants, a failed verify, a wrong terminal key, and malformed responses. `test-webui-probe.py` checks that the pre-install probe accepts a healthy Open WebUI and rejects wrong or unavailable services. All four run from `tests/run-tests.sh` and in CI.
