# OpenClaw companion

[OpenClaw](https://docs.openclaw.ai/) is an **agent client** of the router,
like [Hermes](../hermes/README.md), not a model-pool host. This target creates
an unprivileged Debian 12/13 LXC with nesting and installs OpenClaw as
[brax.me's install script](https://brax.me/openclaw/install.sh) does. Its
provider `osr` points at `127.0.0.1:8765/v1`: the Hermes dispatcher
(`targets/hermes/direct-dispatch.py`) run with this target's files, which reads
the router's inventory and ranking and sends chat straight to the chosen model
server.

OpenClaw's **Gateway** (`openclaw-gateway.service`, TCP 18789) serves the
agent, its Control UI and, with Open WebUI, `/v1/chat/completions`, registered
as a second OpenAI connection so `openclaw` appears beside the router's models:

```
browser -> Open WebUI :8080 -> OpenClaw Gateway :18789 -> dispatcher :8765 -> model server
                                                        \-> router :8000 (inventory and ranking only)
```

The agent's tools (exec, files, web) run as `openclaw`. The dispatcher runs as
a separate account, `openclaw-direct`, which alone can read the router and
backend keys (Hermes's dispatcher shares its agent's account).

**Integrations.** With the [Honcho target](../honcho/README.md) the installer
adds the official OpenClaw Honcho plugin (conversation access, shared `osr`
workspace) beside OpenClaw's own memory plugin; for a separate Honcho set
`HONCHO_URL` and `HONCHO_CT_ID`. `--reconfigure` keeps the URL, key and egress
rule; `HONCHO_URL=` turns it off. The [hcom target](../hcom/README.md) adds
`osr-bus` and managed workspace instructions (OpenClaw polls through its
terminal tool; hcom has no native OpenClaw hooks) and opens this CT's egress to
the broker.

## How OpenClaw is installed

| brax.me `install.sh` | [Official docs](https://docs.openclaw.ai/install) | This target |
|---|---|---|
| nvm v0.40.4 (`curl … \| bash`) | NodeSource, or nvm when present | nvm v0.40.4, SHA-256-checked (`NVM_INSTALLER_SHA256`), as `openclaw`, `PROFILE=/dev/null` |
| `nvm install 24` | Node 24.16+ or 26.1+; 24.22.1+/26.12.1+ strongly recommended | `nvm install 24` (`OPENCLAW_NODE_VERSION`), then checked against the stricter security floor |
| `npm install -g openclaw` | Supported; npm 11.16+ and 12 need `--allow-scripts=openclaw` | `npm install -g openclaw@latest` (`OPENCLAW_VERSION` pins), with that flag when supported |
| No onboarding | Onboarding unless `--no-onboard` | `openclaw setup --baseline`, then `openclaw config set` |
| Installs Ollama | Not part of OpenClaw | **Left out**: the router's pool serves the agent |
| No checks or pins | | Root and lock checks, settings record, rollback and health checks |

nvm checks Node against nodejs.org's `SHASUMS256.txt`. `node`, `npm` and
`openclaw` are linked into `/home/openclaw/.local/bin`, on the unit's `PATH`.

## Before you start

The router, model-host firewall and Open WebUI admin-token requirements are
[Hermes's](../hermes/README.md#before-you-start) (the token is not needed with
`OPENWEBUI=false`). Models need tools and enough context: the dispatcher never
selects one the inventory reports with less than `OPENCLAW_CONTEXT_LENGTH`
(default 65536, minimum 32768; OpenClaw's own local recipes use 64K) or
without tool support. Raise the hosts' context as for Hermes.

## Provision on the Proxmox host

```bash
bash targets/openclaw/provision-lxc.sh                 # new CT
bash targets/openclaw/provision-lxc.sh --reconfigure   # existing OpenClaw CT
```

Prompts follow Hermes's order: router (CT ID or SSH-reachable address), new CT
ID (default: the next free ID), template, storage, static IP/CIDR and gateway
(no address is chosen automatically), then settings. Before creating anything the provisioner copies
the router and backend keys into 0600 files, detects the router's source
address, checks `ROUTER_URL/v1/models`, reads `/routing/inventory` for the
firewall and direct targets, and checks Open WebUI and the token. It then
creates the CT and firewall, waits for DNS (Debian and npm), admits model
servers by the addresses the CT resolves and pushes the files. The guest
installer:

1. Checks the router's models, creates `openclaw` and `openclaw-direct`, and
   installs nvm, Node and OpenClaw.
2. Starts `openclaw-direct.service` and sends one tool-using chat through it.
3. Writes providers from the dispatcher's model lists: `osr` (`auto`, tiers,
   router models) and one per model server, each model with `contextWindow` =
   `OPENCLAW_CONTEXT_LENGTH`, `maxTokens` = `OPENCLAW_MAX_TOKENS`, tool support
   and the `max_tokens` field.
4. Runs `openclaw setup --baseline` on the first run, sets `gateway.mode=local`,
   port, token auth, bind address, chat endpoint, Control UI and
   `agents.defaults.model.primary` (`osr/<OPENCLAW_MODEL>`), then
   `openclaw config validate`.
5. Generates the Gateway token (`/etc/openclaw-target/api-key`, 0600) and puts
   it in `~/.openclaw/.env` as `OPENCLAW_GATEWAY_TOKEN`; the config holds only
   an env SecretRef.
6. Starts the Gateway and waits for `/healthz`, the agent model on
   `/v1/models` and the Control UI.

`integrate-webui.py` in the router CT then checks the token, has Open WebUI's
backend verify the connection and adds or updates it by URL, showing only
`openclaw` (OpenClaw also lists `openclaw/default` and `openclaw/<agentId>`,
the same agent).

| Setting | Default | Meaning |
|---|---|---|
| `OPENCLAW_MODEL` | `auto` | Default model `osr/<this>`: `auto`, a tier or a router model; `auto` ranks and pins tasks as for Hermes |
| `OPENCLAW_CONTEXT_LENGTH` | `65536` | Context the hosts serve (≥ 32768); every provider model's `contextWindow` |
| `OPENCLAW_MAX_TOKENS` | `8192` | `maxTokens` per model, at most half the context |
| `OPENCLAW_VERSION` | `latest` | npm dist-tag or exact release (enforced on every run; the installed one is reported) |
| `OPENCLAW_NODE_VERSION` | `24` | `24`, `26` or exact `24.x.y`/`26.x.y`; below 24.22.1 / 26.12.1 is refused; a change reinstalls OpenClaw |
| `NVM_VERSION` / `NVM_INSTALLER_SHA256` | `v0.40.4` / its known hash | Another `NVM_VERSION` has no default hash: set one or it is reported unchecked |
| `OPENWEBUI` | `true` | `false`: no chat endpoint, registration or token; the Gateway still runs for CLI, Control UI and channels |
| `OPENCLAW_DASHBOARD` | `true` | Control UI on every CT IPv4 address; with neither this nor Open WebUI the Gateway binds loopback only |
| `TASK_MODEL` | `fast` | As for Hermes (set only when unset or pointing at an OpenClaw agent) |
| `OPENCLAW_PORT` | `18789` | Gateway port (WebSocket, Control UI, HTTP API) |
| `EGRESS` | `restricted` | See [Network](#network) |
| `ROUTER_URL`, `ROUTER_IP`, `OPENWEBUI_PORT` | Detected | Overrides |
| `BRIDGE`, `CT_HOSTNAME`, `CORES`, `MEMORY_MB`, `SWAP_MB`, `ROOTFS_GB`, `ONBOOT`, `NAMESERVER`, `VLAN_TAG` | `openclaw`, 2 cores, 4096 MB, 1024 MB swap, 32 GB | CT settings |

| Run | Does |
|---|---|
| default | Creates a CT; a failed run keeps it for `--reconfigure` |
| `--reconfigure` | Pushes current router and backend keys, installer, dispatcher and units, updates the firewall from the inventory and re-registers. Use after key rotation, new servers or models, or changing model, context, port, `OPENWEBUI` or router address |
| `--integrate-only` | Re-registers the Gateway in Open WebUI |

An unchanged guest rerun (settings, keys, servers, models) says "nothing to
do". A failed configure restores `openclaw.json`, `.env`, the units and the
dispatcher's files and reports whether the old Gateway is "running again";
Node and OpenClaw themselves are not rolled back. `install-target.sh` run
inside the CT asks for `ROUTER_URL` if unset; refresh keys with the host's
`--reconfigure`.

## Open WebUI and Control UI

Choose **openclaw** in the model picker. Everyone who can chat with it runs
tools as `openclaw` and shares one agent, memory and workspace, and OpenClaw
documents the chat token as full operator access to the Gateway: keep the
connection admin-only or limited to one group. Keep `TASK_MODEL` on a router
model and don't attach Open WebUI tools, Open Terminal or web search to it.

The Control UI is at `http://<CT-IP>:18789/`; log in with the Gateway token,
then approve the browser pairing from the host:

```bash
pct exec 283 -- cat /etc/openclaw-target/api-key
oc="pct exec 283 -- runuser -u openclaw -- env HOME=/home/openclaw PATH=/home/openclaw/.local/bin:/usr/bin:/bin openclaw"
$oc devices list
$oc devices approve <requestId>
```

Origins `http://<each CT IPv4>:<port>` are allowed
(`gateway.controlUi.allowedOrigins`). OpenClaw treats plain HTTP on a LAN as a
downgraded transport: use a trusted LAN or VPN.

## Network

The CT firewall admits the Gateway port from the router (Open WebUI) and, with
the Control UI, from anywhere; no inbound SSH (use `pct enter`).
`EGRESS=restricted` allows the router API, the inventory's model servers
(resolved in the CT), DNS and internet HTTP(S) (npm, nvm, Node, `openclaw
update`, web tools), dropping everything else including private ranges;
`EGRESS=open` allows all. Unreachable-server handling is the dispatcher's
([Hermes's Network section](../hermes/README.md#network)).

Owned rules carry the comments `ollama-smart-router openclaw-api`,
`-dashboard`, `-router` and `-model`. `--reconfigure` replaces only those,
first in `[RULES]`, adding the new rules before the guest step and removing
the old ones after success; `policy_out` is never changed, a missing file is
not created, and every write goes through `targets/pve-firewall-swap.pl` under
the firewall lock, stopping if the file changed meanwhile.

## Use and maintain

```bash
$oc status                                     # with $oc as above
$oc update && pct exec 283 -- systemctl restart openclaw-gateway
journalctl -u openclaw-direct -f               # in the CT: dispatch decisions
```

Code lives in `/home/openclaw/.nvm`, config and state in
`/home/openclaw/.openclaw` (`openclaw.json`, `.env`, workspace). The hardened
Gateway can write only `/home/openclaw` and a private `/tmp`. With an exact
`OPENCLAW_VERSION`, a rerun reinstalls it, so update or clear it when
upgrading.

| Provider | Goes to | Example |
|---|---|---|
| `osr` | The router-ranked dispatcher (default): `auto`, tiers, every usable router model | `/model osr/xlarge` |
| `<target>` | One model server directly (same names as Hermes's `custom:<target>`); no ranking or failover, works while the router is down | `/model strata-192-168-11-154-8080/qwen3.8-flash-next-iq3_xxs` |

Provider model lists are written by the guest installer. New pool models are
reachable at once through `osr/auto` and the tiers; to pick one by name, rerun
`--reconfigure`. A server that cannot list its models during a rerun keeps its
previous list. Direct picks skip the tool and context checks.

| Symptom | Cause / fix |
|---|---|
| "rejected the API key … --reconfigure" | The router key was rotated: `provision-lxc.sh --reconfigure` |
| "SHA-256 … not NVM_INSTALLER_SHA256" | The nvm installer changed, or `NVM_VERSION` changed without its hash; check it, then set `NVM_INSTALLER_SHA256` |
| "below this target's security floor" | Node is below 24.22.1 / 26.12.1: set a newer `OPENCLAW_NODE_VERSION` |
| `model server … is unreachable; skipping it` in `journalctl -u openclaw-direct` | Not yet admitted (`--reconfigure`), down, or blocked by the model host's firewall |
| "does not offer OPENCLAW_MODEL" | Every server for it lacks tools or reports less than `OPENCLAW_CONTEXT_LENGTH`; check `/routing/inventory` |
| `openclaw-gateway` restarts or exits 78 | Invalid config: `journalctl -u openclaw-gateway`, then `openclaw config validate` as `openclaw` |
| Open WebUI lists no `openclaw` | `systemctl status openclaw-gateway`, then `--integrate-only`; the router needs the Gateway port |
| Chats are slow to get a title | The Task Model (External) must be a router model |
