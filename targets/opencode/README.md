# OpenCode companion

[OpenCode](https://opencode.ai/docs/) ([anomalyco/opencode](https://github.com/anomalyco/opencode))
is an open-source coding agent with a terminal UI, a web UI and an HTTP API.
Like [Hermes](../hermes/README.md) and [OpenClaw](../openclaw/README.md) it is
an **agent client** of the router, not a model-pool host. This target creates
an unprivileged Debian 12/13 LXC with nesting and runs `opencode serve` there.
Its provider `osr` points at `127.0.0.1:8765/v1`: the Hermes dispatcher
(`targets/hermes/direct-dispatch.py`) run with this target's files, which reads
the router's inventory and ranking and sends chat straight to the chosen model
server.

```
browser ---------------------> OpenCode web UI :4096 -> dispatcher :8765 -> model server
Open WebUI -> chat endpoint :4097 -/                  \-> router :8000 (inventory and ranking only)
```

The agent's tools (shell, files, web) run as `opencode`. The dispatcher runs as
a separate account, `opencode-direct`, which alone can read the router and
backend keys.

**Open WebUI.** Hermes and OpenClaw serve an OpenAI-compatible
`/v1/chat/completions` that Open WebUI lists as a model. OpenCode 2 has no such
endpoint (its server API speaks sessions, prompts and an event stream), so this
target adds one: `openai-proxy.py`, run as `opencode-api.service` under its own
account, turns each chat request into a prompt in an OpenCode session and
streams the answer back. The provisioner registers it in Open WebUI as the
model `opencode`, like OpenClaw (an Open WebUI admin token is needed;
`OPENWEBUI=false` leaves it out). See [Open WebUI](#open-webui). (DeepSeek
Harness, by contrast, has no Open WebUI connection: it is used through its own
web UI only.)

**Integrations.** With the [Honcho target](../honcho/README.md) the installer
adds Honcho's official OpenCode plugin (`@honcho-ai/opencode-honcho`, hooks
that record every turn and inject memory, whatever the model), with this CT's
own Honcho key and workspace (`opencode-<CT>`); for a separate Honcho set
`HONCHO_URL` and `HONCHO_CT_ID`. The [hcom target](../hcom/README.md) adds
`osr-bus` and managed instructions in OpenCode's global `AGENTS.md` (OpenCode
polls through its shell tool). With the
[Open Terminal target](../open-terminal/README.md), `OPEN_TERMINAL_URL` gives
OpenCode its own workspace there as MCP server `open-terminal`.

## How OpenCode is installed

OpenCode 2 is one native binary. The official installers (`curl
https://opencode.ai/v2/install | bash`, `npm install -g @opencode/cli`) end with
the same file: the npm package's only job is a postinstall script that picks
the platform package (`@opencode/cli-linux-x64`, `-baseline` for CPUs without
AVX2, `-linux-arm64`) and links its binary.

| Official | This target |
|---|---|
| `npm install -g @opencode/cli` (Node, a postinstall script) | No Node: the platform package is chosen the same way (AVX2 or baseline, a platform package of exactly the release) and downloaded from `registry.npmjs.org` |
| npm checks the tarball against the registry's integrity | The tarball must come from the registry and match its `sha512` integrity, or nothing is installed |
| `latest` | Pinned to `2.2.7` (`OPENCODE_VERSION`); `latest` is resolved on every run and recorded as its exact release |
| Updates itself (`update` defaults to `notify`) | `update: "disable"` and `OPENCODE_DISABLE_AUTOUPDATE=1`; releases change only through `OPENCODE_VERSION` |
| One install, replaced in place | `/opt/opencode/releases/<version>-<platform>` behind `/opt/opencode/current` (root's, world-readable); a failed run switches back; the running and the previous release are kept |
| A shared background service per user (`opencode service`) | `opencode serve` as a systemd unit, password-protected |

## Before you start

The router and model-host firewall requirements are
[Hermes's](../hermes/README.md#before-you-start), including an Open WebUI admin
API key or session JWT (asked for, or `OPENWEBUI_ADMIN_TOKEN`) unless
`OPENWEBUI=false`. Models need tools and enough context: the dispatcher never selects
one the inventory reports with less than `OPENCODE_CONTEXT_LENGTH` (default
65536, minimum 32768) or without tool support. Raise the hosts' context as for
Hermes. The router port must admit this CT (`API_ALLOW_CIDR`).

## Provision on the Proxmox host

Select `opencode` in the main installer, or after OSR is running:

```bash
bash targets/opencode/provision-lxc.sh                    # new CT
bash targets/opencode/provision-lxc.sh --reconfigure      # existing OpenCode CT
bash targets/opencode/provision-lxc.sh --integrate-only   # register it in Open WebUI again
```

Prompts follow Hermes's order: router (CT ID or SSH-reachable address), new CT
ID (default: the next free ID), template, storage, static IP/CIDR and gateway,
then settings (with Open WebUI), Honcho and Open Terminal. Before creating
anything the provisioner copies the router and backend keys into 0600 files,
detects the router's source address, checks `ROUTER_URL/v1/models`, reads
`/routing/inventory` for the firewall and direct targets and, with Open WebUI,
checks that it runs on the router and takes the admin token into a 0600 file.
It then creates the CT and firewall, waits for DNS (Debian and the npm
registry), admits model servers by the addresses the CT resolves and pushes the
files. The guest installer:

1. Checks the router's models (and Honcho's and Open Terminal's keys), resolves
   the release and creates `opencode` and `opencode-direct`.
2. Downloads and checks the platform package into a new release directory.
3. Starts `opencode-direct.service` and sends one tool-using chat through it.
4. Writes providers from the dispatcher's model lists: `osr` (`auto`, tiers,
   router models) and one per model server, each model with `limit.context` =
   `OPENCODE_CONTEXT_LENGTH`, `limit.output` = `OPENCODE_MAX_TOKENS`, JSON tool
   calls, text in and out, and the `max_tokens` field.
5. Switches `current` to the release and writes the managed keys of
   `~/.config/opencode/opencode.json` (`model` = `osr/<OPENCODE_MODEL>`,
   `providers`, `update`, the `open-terminal` MCP server and the Honcho
   plugin entry), keeping everything else in the file.
6. Generates the server password (`/etc/opencode-target/password`, 0600) and
   writes it to `/etc/opencode-target/opencode.env` (root-only, read by
   systemd), with the bind address, port and Open Terminal key.
7. Starts `opencode.service` and waits for `/api/info` and the server's default
   model to be `osr/<OPENCODE_MODEL>` (proof that it loaded the config).
8. With Open WebUI: creates `opencode-api`, generates the endpoint's bearer key
   once (`/etc/opencode-target/api-key`, 0600), writes it with the server
   password to `/etc/opencode-target/api.env` (root-only, read by systemd),
   starts `opencode-api.service` and waits for `/healthz` and `/v1/models`
   with the key.

The provisioner then pulls the bearer key and runs `integrate-webui.py` on the
router (key and admin token as 0600 files in a private directory, removed
afterwards): it checks the key against the endpoint's `/v1/models`, verifies
the connection through Open WebUI, and adds or updates the connection by URL
with only the model `opencode`, setting the task model to `TASK_MODEL` when
Open WebUI's is unset or points at an agent.
| Setting | Default | Meaning |
|---|---|---|
| `OPENCODE_MODEL` | `auto` | Default model `osr/<this>`: `auto`, a tier or a router model; `auto` ranks and pins tasks as for Hermes |
| `OPENCODE_CONTEXT_LENGTH` | `65536` | Context the hosts serve (≥ 32768); every provider model's `limit.context` |
| `OPENCODE_MAX_TOKENS` | `8192` | `limit.output` per model, at most half the context |
| `OPENCODE_VERSION` | `2.2.7` | Exact `@opencode/cli` release (2.x or newer), or `latest` |
| `OPENCODE_PORT` | `4096` | Web UI and HTTP API port |
| `OPENCODE_WEB` | `true` | Listen on the CT address; `false`: loopback only (terminal UI in the CT) |
| `OPENCODE_ACCESS_CIDR` | The CT's network | Range admitted to the web UI (a host address becomes its network); `--reconfigure` keeps the one in the firewall |
| `OPENCODE_FREE_MODELS` | `false` | `true` also offers OpenCode's free cloud models (they send your code to opencode.ai) |
| `OPENWEBUI` | `true` (`--reconfigure`: the recorded choice; off for a CT made before the endpoint existed) | Run the chat endpoint and register it in Open WebUI as `opencode` |
| `OPENCODE_API_PORT` | `4097` | Chat endpoint port, admitted from the router's address only |
| `OPENCODE_API_PERMISSIONS` | `allow` | What the endpoint answers OpenCode's permission requests with: `allow` (once) or `reject` |
| `OPENWEBUI_PORT`, `TASK_MODEL` | Read from the router; `fast` | Open WebUI's port; the router model for its titles and tags (blank leaves the setting alone) |
| `HONCHO_URL`, `HONCHO_CT_ID` | Offered when a CT tagged `honcho` is on this host | Honcho memory; `HONCHO_API_KEY_FILE` for a key issued by hand; `HONCHO_PLUGIN_VERSION` (`0.2.1`) |
| `OPEN_TERMINAL_URL`, `OPEN_TERMINAL_CT_ID` | Offered when a CT tagged `open-terminal` is on this host | Open Terminal workspace; `OPEN_TERMINAL_KEY_FILE` for a key issued by hand |
| `EGRESS` | `restricted` | See [Network](#network) |
| `ROUTER_URL`, `ROUTER_IP` | Detected | Overrides |
| `BRIDGE`, `CT_HOSTNAME`, `CORES`, `MEMORY_MB`, `SWAP_MB`, `ROOTFS_GB`, `ONBOOT`, `NAMESERVER`, `VLAN_TAG` | `opencode`, 2 cores, 4096 MB, 1024 MB swap, 32 GB | CT settings; each release takes about 260 MB |

The main installer accepts `OPENCODE_MODEL`, `OPENCODE_CONTEXT_LENGTH`,
`OPENCODE_VERSION`, `OPENCODE_PORT` and `OPENCODE_ACCESS_CIDR` (default: its
`API_ALLOW_CIDR`), and gives OpenCode the Open WebUI admin key it asks for the
companions; without one OpenCode is skipped like Hermes and OpenClaw.

| Run | Does |
|---|---|
| default | Creates a CT; a failed run keeps it for `--reconfigure` |
| `--reconfigure` | Pushes current router and backend keys, installer, dispatcher, chat endpoint and units, updates the firewall from the inventory and reruns the guest, then registers the endpoint in Open WebUI again. Use after key rotation, new servers or models, or changing model, context, port, release or router address |
| `--integrate-only` | Registers an existing CT's chat endpoint in Open WebUI (after reinstalling Open WebUI, say); changes nothing in the CT |

An unchanged guest rerun (settings, keys, servers, models, release) says
"nothing to do" and, for an installed exact release, does not ask the
registry. A failed run restores `opencode.json`, the environment file, the
Honcho config, the units, the dispatcher's files and the release link, deletes
a release it downloaded, puts back the chat endpoint's unit, program and
environment (restarting it with them), and reports whether the old server is
"running again". `install-target.sh` run inside the CT asks for `ROUTER_URL` if unset;
refresh keys with the host's `--reconfigure`.

## Web UI and terminal UI

Open `http://<CT-IP>:4096/` and sign in as `opencode` with the password:

```bash
pct exec 284 -- cat /etc/opencode-target/password
```

Everyone who can sign in runs tools as `opencode` and shares its projects,
sessions, memory and workspace (`/home/opencode/workspace` by default; the web
UI can open any directory the account can read). The agent asks before shell
commands and edits unless `permissions` in `opencode.json` say otherwise. The
server speaks plain HTTP: use a trusted LAN or VPN, and keep
`OPENCODE_ACCESS_CIDR` narrow.

The terminal UI connects to the same server from inside the CT:

```bash
pct exec 284 -- sh -c 'runuser -u opencode -- env HOME=/home/opencode OPENCODE_PASSWORD="$(cat /etc/opencode-target/password)" opencode --server http://127.0.0.1:4096'
```

**Trust.** OpenCode's shell tool inherits the server's environment, so the
agent and anything it runs can read the server password and the Open Terminal
key, and, with Honcho, this CT's Honcho key (which reaches only OpenCode's own
Honcho workspace). The router and backend keys stay with `opencode-direct`;
the chat endpoint's bearer key with root and `opencode-api` (whose
environment holds the server password it already shares with the agent).

| Provider | Goes to | Example |
|---|---|---|
| `osr` | The router-ranked dispatcher (default): `auto`, tiers, every usable router model | `osr/xlarge` |
| `<target>` | One model server directly (Hermes's names); no ranking or failover, works while the router is down | `strata-192-168-11-154-8080/qwen3.8-flash-next-iq3_xxs` |

Provider model lists are written by the guest installer. New pool models are
reachable at once through `osr/auto` and the tiers; to pick one by name, rerun
`--reconfigure`. A server that cannot list its models during a rerun keeps its
previous list. Direct picks skip the tool and context checks. With a Kindi
server in the pool, its provider and `osr` wait twice the router's Kindi read
budget for response headers (`settings.headerTimeout`).

## Open WebUI

Choose `opencode` in Open WebUI's model list. Check its visibility under
Admin Settings > Models before sharing it: whoever can chat with it runs tools
as `opencode` in this CT, in the same workspace and memory as the web UI.

Each chat request becomes a prompt in an OpenCode session (titled
`Open WebUI: <first message>`, in `/home/opencode/workspace`), so OpenCode keeps
its own history, tools and context, and the sessions appear in its web UI too.
Open WebUI sends the whole conversation every time and no chat ID, so the
endpoint keys sessions by a hash of the conversation so far (user and
assistant turns, with Open WebUI's `<details>` and `<think>` blocks and
whitespace normalised). A request that continues the exact state a session was
left in sends only the new message to that session. Anything else (a new chat,
a regenerated or edited reply, a session deleted in OpenCode) starts a new
session, given Open WebUI's system prompt and the earlier turns as context.
The map lives in `/var/lib/opencode-api/sessions.json` and survives restarts.

The answer streams as it is written. Reasoning and tool activity (`tool:
bash`, permission decisions) stream as `reasoning_content`, which Open WebUI
shows as a collapsible block; `OPENCODE_API_ACTIVITY=false` in `api.env`
leaves the tool lines out. Nobody can answer OpenCode's questions from a chat,
so permission requests in the session and its subagents are answered with
`OPENCODE_API_PERMISSIONS` (`allow` once, like Hermes's and OpenClaw's
unattended tools; `reject` with a note the model sees), and questions are
cancelled with a note telling the model to go on with reasonable assumptions
and state them.
Closing or stopping the chat interrupts the OpenCode turn. A conversation runs
one turn at a time (a second request gets 409), the endpoint runs at most four
turns at once (429), and a turn is stopped after an hour.

The endpoint listens on `OPENCODE_API_PORT`, admitted from the router's address
only, and requires the bearer key in `/etc/opencode-target/api-key`; Open WebUI
holds a copy in its connection. It talks to OpenCode on loopback with the
server password, so it works with `OPENCODE_WEB=false` too. `OPENWEBUI=false`
on a `--reconfigure` stops and removes the endpoint (the key is kept, so
turning it on again needs no change in Open WebUI); remove the connection
under Admin Settings > Connections by hand.

## Honcho memory

With `HONCHO_URL`, the provisioner has the Honcho CT (found by its address, or
`HONCHO_CT_ID`) issue a client key for `opencode-<CT>`, pinned to a workspace of
that name, and pushes it here; the guest checks it at `/osr/v1/whoami` before
changing anything. The installer writes `~/.honcho/config.json` (0600; key, URL,
peer `user`, `hosts.opencode` with the workspace, AI peer `opencode`, unified
observation) and adds `@honcho-ai/opencode-honcho@<HONCHO_PLUGIN_VERSION>` to
`plugins`. OpenCode installs the plugin from the npm registry in the background
on its first start; check it with `/honcho:status` in a session. `HONCHO_URL=`
removes the plugin and its config and revokes the key; the memories stay in
Honcho.

## Open Terminal workspace

With `OPEN_TERMINAL_URL`, the provisioner has the terminal CT (found by its
address, or `OPEN_TERMINAL_CT_ID`) issue a client key for `opencode-<CT>`, admit
this CT in the terminal's firewall, and push the key here; the guest checks it
against the gateway (`/osr/v1/whoami`). OpenCode gets `mcp.servers.open-terminal`
(remote, `<URL>/mcp`, OAuth off, header `Authorization: Bearer
{env:OSR_OPEN_TERMINAL_KEY}`, substituted from the server environment, so
`opencode.json` holds no key). Its tools act in OpenCode's own workspace in the
terminal CT; OpenCode's own shell and file tools still run in this CT.
`OPEN_TERMINAL_URL=` removes the MCP server, revokes the key and drops the
terminal firewall rule.

## Network

The CT firewall admits the web UI port from `OPENCODE_ACCESS_CIDR` and the chat
endpoint port from the router's address; no inbound SSH (use `pct enter`). `EGRESS=restricted` allows the router API, the
inventory's model servers (resolved in the CT), Honcho and the Open Terminal
gateway when set, DNS and internet HTTP(S) (the npm registry for releases and
plugins, models.dev, OpenCode's web tools), dropping everything else including
private ranges; `EGRESS=open` allows all.

Owned rules carry the comments `ollama-smart-router opencode-web`, `-api`,
`-router` and `-model`. `--reconfigure` replaces only those, first in `[RULES]`, adding
the new rules before the guest step and removing the old ones after success;
`policy_out` is never changed, a missing file is not created, and every write
goes through `targets/pve-firewall-swap.pl` under the firewall lock, stopping
if the file changed meanwhile.

## Use and maintain

```bash
journalctl -u opencode -f                      # in the CT: the server
journalctl -u opencode-direct -f               # in the CT: dispatch decisions
journalctl -u opencode-api -f                  # in the CT: Open WebUI chat turns
OPENCODE_VERSION=2.2.8 bash targets/opencode/provision-lxc.sh --reconfigure   # another release
```

Releases live in `/opt/opencode/releases`, config in
`/home/opencode/.config/opencode/opencode.json` (plain JSON; the installer
refuses a JSONC file with comments rather than rewrite it), sessions in
`/home/opencode/.local/share/opencode`. The hardened server can write only
`/home/opencode` and a private `/tmp`. `tools/upgrade-all.sh` offers to move a
CT pinned to an older release to this target's pin.

| Symptom | Cause / fix |
|---|---|
| "rejected the API key … --reconfigure" | The router key was rotated: `provision-lxc.sh --reconfigure` |
| "does not match the registry's sha512 integrity" | The download was altered or cut off; nothing was installed. Retry; if it persists, check the CT's proxy or DNS |
| "is not plain JSON" | `opencode.json` was edited with comments: remove them or move the file aside, then rerun |
| `model server … is unreachable; skipping it` in `journalctl -u opencode-direct` | Not yet admitted (`--reconfigure`), down, or blocked by the model host's firewall |
| "does not offer OPENCODE_MODEL" | Every server for it lacks tools or reports less than `OPENCODE_CONTEXT_LENGTH`; check `/routing/inventory` |
| "did not answer … with default model osr/…" | The server did not start or did not load the config: `journalctl -u opencode` |
| Open WebUI: "OpenCode's chat endpoint rejected the key" | The CT's `api-key` and the one given differ: rerun `--integrate-only` |
| Open WebUI: "has no /v1/models: is opencode-api running?" | `OPENWEBUI=false` was set, or the endpoint is down: `journalctl -u opencode-api`, or `--reconfigure` with `OPENWEBUI=true` |
| An Open WebUI reply starts over (no memory of the chat) | The reply was regenerated or edited, or the earlier reply differs from what the endpoint stored: a new session was started with the transcript (by design) |
| "**OpenCode error:** … busy" in a chat | That conversation's session is still running a turn (another tab, or a regenerate before the first finished) |
| `/honcho:status` shows no plugin | First start installs it in the background; check `journalctl -u opencode` for npm errors (egress to registry.npmjs.org) |

## Verified, and not yet

Checked against the OpenCode sources at release 2.2.7 (`anomalyco/opencode`
2026-11-11) and the published packages: the config schema (`providers`,
`settings.baseURL`/`apiKey`/`headerTimeout`, `compatibility.maxTokensField`,
`capabilities`, `limit`, `mcp.servers` with `type: remote`, `plugins`,
`update`), `opencode serve --hostname --port`, Basic auth with
`OPENCODE_PASSWORD` (user `opencode`), `/api/info`, `/api/model/default`, the
npm package's platform selection, and `@honcho-ai/opencode-honcho` 0.2.1's
OpenCode 2 support and config. The chat endpoint was checked against the
server API of the same sources (`POST /api/session`, `/api/session/:id/prompt`
with `delivery`, the `/api/event` stream and its `session.*`, `permission.asked`
and `form.created` events, permission replies, form cancel, interrupt) and
tested against a fake OpenCode server. The binary itself was not run here: a
first real install should be watched (the server starting under the unit's
hardening in an unprivileged LXC, the plugin install, a tool-calling session
from the web UI and from Open WebUI).
