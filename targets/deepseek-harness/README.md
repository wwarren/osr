# DeepSeek Harness target

Runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh`) as a separate CPU-only agent in its own unprivileged Debian 12/13 LXC,
with its Web UI, sessions, shell tools and workspace there. Harness uses the
router as a custom OpenAI-compatible provider (no direct dispatcher); it is
not a model in OSR's pool and not an Open WebUI tool, so it needs **no Open
WebUI admin token**. The provisioner reads the router key from the router CT
into a root-only systemd environment file; the generated Harness patch names
only the variable. With Honcho, Harness gets the shared long-term memory
([Honcho memory](#honcho-memory)). The [hcom target](../hcom/README.md) adds
`osr-bus` and its own instruction block (Harness polls through its shell
tools; the relay key stays in an account Harness cannot read).

**Trust.** Harness's shell tools inherit the service environment, so the agent
and anything it runs can read the router key and, with Honcho, the `osr`
workspace key. Limit Web UI access to people trusted to operate OSR.

## Requirements

- Proxmox VE with a downloaded Debian 12/13 amd64 template, `rootdir` storage,
  a free CT ID and a static IPv4 address with DNS and internet access.
- The router running as a CT **on the same PVE host** (address and key are read
  with `pct exec`).
- An OSR model with tool calls that serves the configured context (check
  `tools` and `context_length` in `/routing/inventory`). Harness's 29 tools
  take ~6,000 tokens per request in 0.2.1; Honcho's MCP tools add several
  thousand more.
- The router port must accept the CT. When the router has a firewall file, the
  provisioner keeps one rule there (`# osr-deepseek-harness-router`);
  `DSH_ROUTER_FIREWALL=false` leaves it to you.

The guest installs Node.js 24.9+ (NodeSource's signed Node 24 repository if
missing), then the official `@deepseek-ai/dsh` npm package as the unprivileged
`deepseek-harness` account. No DeepSeek API subscription is needed.

**Pinned release.** Harness is a developer preview with breaking changes, so
the target installs `0.2.1-rc.5` (npm `latest` on 2026-11-03) unless
`DSH_VERSION` is set. It was checked against the generated patch (`dsh
--dump-config`), a headless chat through the OSR provider (system role,
`max_tokens`, bearer key) and the Honcho MCP connection. The newer
`0.2.2-alpha` releases add MCP options not used here; move the pin only after
testing. `DSH_VERSION=latest` resolves npm `latest` on each run and records the
exact version.

## Provision

Select `deepseek-harness` in the main installer, or after OSR is running:

```bash
ROUTER_CT_ID=280 CT_ID=281 \
TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1 \
DSH_MODEL=auto DSH_ACCESS_CIDR=192.0.2.0/24 \
bash targets/deepseek-harness/provision-lxc.sh --dry-run     # then without --dry-run
```

Interactive runs prompt for missing values; `--dry-run` touches nothing; no CT
is ever deleted.

| Setting | Default | Meaning |
|---|---|---|
| `DSH_MODEL` | `auto` | OSR model ID or tier; a concrete tool-capable model gives steadier sessions |
| `DSH_CONTEXT_WINDOW` | `32768` (main installer: the smallest model window, else 65536) | Context the model serves; an exact model is checked against every reporting host. At least 32768 with Honcho |
| `DSH_MAX_TOKENS` | `8192` | Max reply tokens, below the context window |
| `DSH_VERSION` | `0.2.1-rc.5` | Exact npm release or `latest` |
| `DSH_PORT` | `3080` | Web UI port |
| `DSH_ACCESS_CIDR` | The CT's network | Source range admitted to the Web UI (a host address like `192.0.2.81/24` becomes `192.0.2.0/24`) |
| `DSH_ROUTER_FIREWALL` | `true` | Keep this CT's rule in the router's firewall file |
| `HONCHO_URL`, `HONCHO_CT_ID` | Unset | Honcho memory |
| `CORES`, `MEMORY_MB`, `ROOTFS_GB` | 2, 4096, 32 | Each release takes ~860 MB in `/opt/deepseek-harness/releases/`; an upgrade briefly holds two |

The main installer accepts `DEEPSEEK_HARNESS_*` equivalents (`_MODEL`,
`_CONTEXT_WINDOW`, `_VERSION`, `_PORT`, `_ACCESS_CIDR`), prompts for model and
context (at least 16384), and uses its `API_ALLOW_CIDR` as the Web UI range
when none is given.

## Honcho memory

Hermes and OpenClaw use native Honcho plugins that record every turn and
inject memory without the model acting. Harness has no plugin; it uses
Honcho's MCP server through `@deepseek-ai/dsh-mcp-client` (DeepSeek's route
for third-party memory), so the tools appear as `mcp__honcho__*` and the
model decides when to call them:

- **Same memory.** The shared `osr` workspace and `user` peer, so what Hermes
  or OpenClaw learned is available to Harness and vice versa; Harness writes as
  peer `deepseek-harness`.
- **Model-driven.** Honcho's MCP instructions and a managed block (between
  `osr-honcho` markers) in the user-global
  `/var/lib/deepseek-harness/home/AGENTS.md` tell the model to look up context,
  open a session and record each exchange; weak tool callers forget.
- **Cost.** Recording adds tool calls every turn and tool definitions to every
  request: give Harness 32768 tokens or more.

With the main installer, select `honcho` with `deepseek-harness`. On an
existing install:

```bash
# Admit Harness in the Honcho firewall (list every agent's IP).
CT_ID=285 ROUTER_CT_ID=280 HONCHO_CLIENT_IPS='192.0.2.82 192.0.2.83 192.0.2.81' \
  bash targets/honcho/provision-lxc.sh --reconfigure
# Turn Honcho on for Harness; the osr workspace key is fetched from CT 285.
CT_ID=281 ROUTER_CT_ID=280 HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=285 \
  bash targets/deepseek-harness/provision-lxc.sh --reconfigure
```

The MCP endpoint `http://<honcho-ip>:3000/mcp` is derived from `HONCHO_URL`
(`HONCHO_MCP_URL` and `HONCHO_API_KEY_FILE` for another Honcho). The
provisioner refuses, before changing anything, if Honcho's firewall does not
admit this CT (and prints the Honcho command); the guest checks the key with an
MCP `initialize` before writing the overlay. The key lives only in
`/etc/deepseek-harness/service.env` (root-only) and the service environment,
read by the overlay with a `!!js` expression. Reconfigures keep Honcho on;
`HONCHO_URL=` removes the MCP entry, key and `AGENTS.md` block. After a Honcho
`--rotate-keys`, reconfigure with `HONCHO_CT_ID` again.

To verify: ask Harness to remember something unique, watch for an
`mcp__honcho__add_messages_to_session` or `create_conclusions` call, then ask
for it in a new session; Hermes or OpenClaw can recall it once the deriver has
processed it (`journalctl -u honcho-deriver` in the Honcho CT).

## Use and recovery

The service binds to the CT's IPv4 address and accepts only that host name (no
`--trusted-host` is set). Each start prints a login URL with a one-time token;
read the newest after every restart or reboot:

```bash
pct exec <CT> -- journalctl -u deepseek-harness.service -b --no-pager | grep 'dsh web:' | tail -n1
```

| What you see | Cause | Fix |
|---|---|---|
| Browser times out | Your address is outside `DSH_ACCESS_CIDR` (`policy_in: DROP`; see `grep dport /etc/pve/firewall/<CT>.fw`), or the service is down (`pct exec <CT> -- systemctl is-active deepseek-harness.service`) | `DSH_ACCESS_CIDR=<your subnet> bash targets/deepseek-harness/provision-lxc.sh --reconfigure` (other settings keep their recorded values); for a stopped service read `journalctl -u deepseek-harness.service -b -n 40` |
| `dsh web authentication required; reopen the URL printed by dsh web.` | Opened without its token, or with one from before a restart | Open the newest URL above |
| Refused when using a host name | Only the CT's IP is trusted | Use `http://<CT IP>:<DSH_PORT>/…` as printed |
| Service `inactive`, empty journal, no `/etc/deepseek-harness/service.env` | The guest install never finished | `CT_ID=<CT> bash targets/deepseek-harness/provision-lxc.sh --reconfigure` and read the failing step |

The Web UI is plain HTTP (the token crosses the LAN). Workspace:
`/var/lib/deepseek-harness/workspace`; profile home:
`/var/lib/deepseek-harness/home`. Tools run as `deepseek-harness` under
Harness's permission preset; releases are root-owned, so the agent cannot
change its own code. Outbound traffic is allowed (npm, agent tools), subject to
Harness's policy.

**Models chosen in the Web UI** (Settings > Models) edit the profile's own
`cordis.patch.yml`, but this target's overlay is applied after it and replaces
whole entries, so such edits do not stick: change the model with a
reconfigure.

**Reconfigure** after a router key rotation, model change or package upgrade,
with the **existing** CT ID:

```bash
ROUTER_CT_ID=280 CT_ID=281 DSH_MODEL=code-model bash targets/deepseek-harness/provision-lxc.sh --reconfigure
```

It refreshes the key and guest files, regenerates the overlay and restarts the
service, touching only a CT with this target's description and firewall rule
(other rules are kept). Settings not given (`DSH_MODEL`,
`DSH_CONTEXT_WINDOW`, `DSH_MAX_TOKENS`, `DSH_VERSION`, `DSH_PORT`, Honcho) keep
the values in `/etc/deepseek-harness/settings` from the last completed run (the
run says which); a recorded release is kept too, so set `DSH_VERSION` to move
to the pin. An unchanged rerun with a healthy service does nothing.

**Firewall during reconfigure.** A port change admits both old and new ports
until the guest is healthy, then only the new one. A failed guest run restores
the Harness and router firewall files once the previous service is back; if the
new service is running the new rule stays (the run still fails); if rollback is
incomplete or unreadable, or the run was interrupted (Ctrl-C, closed SSH), both
rules stay. Writes use Proxmox's per-CT lock and a staged replacement; a file
edited during the run is not restored (the run prints where its old content
is).

### Upgrades and rollback

Each release goes into its own `/opt/deepseek-harness/releases/<version>_<time>_<pid>`
beside the running one, with `/opt/deepseek-harness/current` pointing at the
active one, so an npm failure changes nothing. Before an installed CT changes,
the overlay, service env, settings record, keys, unit, `AGENTS.md` and
profiles (`home/profiles/`) are copied to the root-only
`/var/lib/deepseek-harness-target/rollback/`. If the router or Honcho check
fails or the new release rejects the patch (`--dump-config`), the files are
restored and the service is never restarted. If the new release does not answer
within 90 seconds of the restart, the previous release and files are restored,
restarted and health-checked, and the run says whether it runs again. After
success, the copies and previous release are deleted. Session logs are not
snapshotted: a newer Harness may upgrade sessions it opened beyond what an
older release can read.

**When the rollback does not complete**, the snapshot stays and the next run
refuses to start. In the CT, check `systemctl status deepseek-harness` and its
journal, then restore from `/var/lib/deepseek-harness-target/rollback/`:
`release` names the previous release (point `current` at it); `file.<n>` go
back, in order, to `/etc/deepseek-harness/osr.patch.yml`, `service.env`,
`settings`, `router-api-key`, `honcho-api-key`,
`/etc/systemd/system/deepseek-harness.service` and
`/var/lib/deepseek-harness/home/AGENTS.md` (an `absent.<n>` marker means it did
not exist); `profiles.tar` unpacks into `/var/lib/deepseek-harness/home`. Run
`systemctl daemon-reload`, restart, and once healthy remove the directory and
reconfigure.

A failed first install keeps its CT and release; reconfigure after fixing the
DNS, model or npm error. A CT from the first version of this target (Harness
directly in `/opt/deepseek-harness`, no settings record) moves to the release
layout on its first reconfigure; pass `DSH_MODEL` and the other settings then.

## Local checks

```bash
bash tests/run-tests.sh deepseek-harness-provision   # helpers, plans, guest dry run, unit, configure.test.mjs (Node 20+)
bash tests/run-tests.sh deepseek-harness-install     # end to end against a fake router and Honcho MCP
```

The install suite covers fresh install, unchanged rerun, reconfigure, both
rollback paths, npm and patch failures, `latest`, Honcho on and off and the
first layout. Neither needs root or Proxmox.
