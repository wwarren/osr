# Hermes Agent companion

Hermes is an **agent client** of the router, not a model-pool host. This
target creates an unprivileged Debian 12/13 LXC with nesting and installs
[Hermes Agent](https://hermes-agent.nousresearch.com/) with the
[official POSIX installer](https://hermes-agent.nousresearch.com/install.sh).
Hermes's custom provider points at a local dispatcher on `127.0.0.1:8765/v1`,
which reads the router's inventory and ranking with `ROUTER_API_KEY` and sends
chat straight to the chosen model server.

By default Hermes's **API server** (`hermes-gateway.service`, TCP 8642) is
registered in the router's Open WebUI as a second OpenAI connection, so
`hermes-agent` appears beside the router's models:

```
browser -> Open WebUI :8080 -> Hermes API server :8642 -> dispatcher :8765 -> model server
                                                       \-> router :8000 (inventory and ranking only)
```

The agent's tools (terminal, files, web) run as the unprivileged `hermes`
account in this CT. The web dashboard (`hermes-dashboard.service`) listens on
`0.0.0.0:9119` with a generated login (user `admin`, random password in
`~/.hermes/.env`); it can manage settings and secrets, so reach it only over a
trusted LAN or VPN.

**Integrations.** With the [Honcho target](../honcho/README.md) the installer
adds Hermes's Honcho memory plugin on the shared `osr` workspace; for a
separately installed Honcho set `HONCHO_URL` and `HONCHO_CT_ID`.
`--reconfigure` keeps the URL, key and egress rule; `HONCHO_URL=` turns it off.
The [hcom target](../hcom/README.md) adds `osr-bus` and a managed block in
`/home/hermes/AGENTS.md` and opens this CT's egress to the broker; its native
plugin (`HCOM_HERMES_NATIVE=true`) gives Hermes the group key and works only in
messaging-platform chats, not Open WebUI.

## Before you start

- **Router reachable.** Port 8000 must accept the Proxmox host and the new CT
  (with the router firewall on, `API_ALLOW_CIDR` must include the Hermes CT).
- **Model hosts admit the Hermes CT.** Its own firewall allows the discovered
  servers, but a model host's firewall may allow only the router.
- **Open WebUI admin API key or JWT** (Settings → Account; enable API keys in
  Admin Settings → Authentication), prompted without echo or from
  `OPENWEBUI_ADMIN_TOKEN` (removed from the environment at once; temporary
  copies deleted). Not needed with `OPENWEBUI=false`.
- **Tool-capable models with at least 64000 tokens of context.** Every model
  the dispatcher may pick needs it. Model targets default to 65536 (the OSR
  installer flags smaller windows); llama.cpp needs 65536 × `PARALLEL_SLOTS` in
  `CONTEXT_SIZE` and `tools` in `MODEL_CAPABILITIES`. On older hosts raise
  `OLLAMA_CONTEXT_LENGTH` in `/etc/ollama-target/ollama.env` or llama.cpp's
  `CONTEXT_SIZE`, otherwise Ollama silently drops the start of the prompt (the
  tool definitions) and llama.cpp rejects it. The router's inventory reports
  `context_length` but can overstate what a host serves, so
  `HERMES_CONTEXT_LENGTH` must match the real window.

## Provision on the Proxmox host

```bash
bash targets/hermes/provision-lxc.sh                 # new CT
bash targets/hermes/provision-lxc.sh --reconfigure   # existing Hermes CT
```

A new install asks for the router (a CT ID here, or the IP/hostname of a router
LXC/VM reachable as root over SSH, as for Open Terminal), then the new Hermes
CT's ID (default: the cluster's next free ID, which an unattended run takes;
preset `CT_ID` to choose another), template and storage menus, static IP/CIDR
and gateway (no address is chosen automatically), then Hermes settings; see the root README's
[Provisioner questions](../../README.md#provisioner-questions). Before creating
anything, the provisioner:

1. Copies `ROUTER_API_KEY` and the backend keys from the router's
   `/app/router/secrets.env` into 0600 files (never into argv).
2. Detects the address the router uses to reach the CT; `ROUTER_URL` defaults
   to `http://<that address>:<router port>`.
3. Checks `ROUTER_URL/v1/models` with the key and reads `/routing/inventory` to
   admit each model server's IP and port (no port: 80 for http, 443 for https).
4. Checks Open WebUI's health and asks for the admin token.

It then creates the CT and firewall, resolves model-server host names inside
the CT (with the dispatcher's resolver) and admits every IPv4 address, and
pushes the installer, dispatcher, units and keys. The guest installer installs
Hermes as `hermes`; configures provider `custom` (`model.base_url` at the
dispatcher, `model.default`, `model.context_length`, a placeholder key);
starts `hermes-direct.service` and sends one tool-using chat through it;
generates the API server key (`/etc/hermes-target/api-key`, 0600) and
`API_SERVER_*` settings; starts `hermes-gateway.service` and waits for
`/health` and `/v1/models`; and enables the dashboard, checking that
`/api/status` requires login. Finally `integrate-webui.py` in the router CT
checks the Hermes key, has Open WebUI's backend verify the connection (which
also proves the firewall admits the router), and adds or updates the
connection by URL, keeping all others.

| Setting | Default | Meaning |
|---|---|---|
| `HERMES_MODEL` | `auto` | Default model of provider `custom:osr`. `auto` uses `/routing/explain`, prefers loaded models and pins an agent task to one model while a server for it works; if all its servers fail, the router ranks afresh. Name a model for a fixed choice |
| `HERMES_CONTEXT_LENGTH` | `65536` | Context the host really serves (≥ 64000). The dispatcher never uses a model the inventory reports with less, or without tool support; AirLLM is excluded |
| `HERMES_CHANNEL` | `stable` | Upstream channel (`stable` or `main`) |
| `HERMES_COMMIT` | — | Pin the checkout; a changed pin applies on the next run (the installer reports the installed commit). Kept by `--reconfigure`; `HERMES_COMMIT=` clears it |
| `HERMES_INSTALLER_SHA256` | — | Refuse another `install.sh`; every run prints its checksum |
| `OPENWEBUI` | `true` | `false`: no Open WebUI connection or API server, no admin token |
| `HERMES_DASHBOARD` | `true` | `false` stops the dashboard and closes TCP 9119 |
| `TASK_MODEL` | `fast` | Open WebUI's Task Model (External) for titles, tags, follow-ups; set only when unset or pointing at Hermes; blank leaves it alone |
| `HERMES_API_PORT` / `HERMES_API_MODEL_NAME` | `8642` / `hermes-agent` | API port (8644–8646 are reserved by Hermes) and model name in Open WebUI. Kept by `--reconfigure` and `--integrate-only`, like `HERMES_CHANNEL` |
| `EGRESS` | `restricted` | See [Network](#network) |
| `ROUTER_URL`, `ROUTER_IP`, `OPENWEBUI_PORT` | Detected | Overrides |
| `BRIDGE`, `CT_HOSTNAME`, `CORES`, `MEMORY_MB`, `SWAP_MB`, `ROOTFS_GB`, `ONBOOT`, `NAMESERVER`, `VLAN_TAG` | 2 cores, 4096 MB, 1024 MB swap, 32 GB | CT settings |

| Run | Does |
|---|---|
| default | Creates a CT. A failed run keeps it; fix the cause and use `--reconfigure` |
| `--reconfigure` | Pushes the router's current and backend keys, installer, dispatcher and units, updates the Hermes firewall rules from the current inventory and re-registers. Use after key rotation, a new model server, or changing model, context, port, `OPENWEBUI` or router address. Works even if the guest never wrote its settings, as long as the CT description and firewall file remain |
| `--integrate-only` | Re-registers the API server in Open WebUI (e.g. after resetting `webui.db`) |

`--reconfigure` does not change CT features: for a CT made before nesting was
enabled, turn on **Options → Features → Nesting** and restart it. Running
`install-target.sh` inside the CT asks for `ROUTER_URL` if unset (set it for
unattended runs); after key changes use the host's `--reconfigure` so current
keys are supplied. An unchanged guest rerun says "nothing to do" (the settings
record includes key hashes, so a rotated key is a change). A failed configure
restores the previous `config.yaml`, `.env` and units and reports whether the
old API server is "running again" or "did not become healthy either".

## Open WebUI

Choose **hermes-agent** in the model picker (Chat Completions API; Hermes
streams tool progress and keep-alives, so long runs do not time out).

- **Access.** Check its visibility under Admin Settings → Models. Everyone who
  can chat with it runs tools as `hermes` and shares one profile: memory,
  skills and the router and backend keys. For separation, run one Hermes
  profile per user or group with its own `API_SERVER_PORT`, key and connection.
- **Task model.** Titles, tags and follow-ups go to `TASK_MODEL`; pointing it
  at Hermes would start an agent run (and a memory entry) for every title.
- **One agent at a time.** Don't attach Open WebUI tools, Open Terminal or web
  search to `hermes-agent`; Hermes has its own.
- **Files.** Document retrieval works; raw attachments (`input_file`) are
  refused; inline images work.

## Network

With the datacenter firewall enabled, `/etc/pve/firewall/<id>.fw` admits the
API port only from the router and TCP 9119 when the dashboard is on. Inbound
SSH is not admitted; use `pct enter`.

`EGRESS=restricted` (default) allows outbound, in order: the router's API (from
`ROUTER_URL`); the model server IPs and ports from the inventory at the last
provision or reconfigure (names resolved in the CT; unresolvable ones are
reported and skipped); DNS; internet HTTP(S) for packages, `hermes update` and
web tools. Everything else, including RFC 1918, CGNAT and link-local, is
dropped. `EGRESS=open` allows all (e.g. for a LAN proxy). A new model server or
a changed address needs `--reconfigure`; new models on an admitted host are
discovered automatically. Meanwhile the dispatcher skips a server it cannot
connect to within 5 s, or that drops a stream, for 60 s (unless all are
skipped). A backend that breaks off a response reaches Hermes as an incomplete
chunked response; for close-delimited backends the dispatcher requires
complete JSON or an SSE `[DONE]` first.

**What `--reconfigure` changes.** The rules carrying the comments
`ollama-smart-router hermes-api`, `hermes-dashboard`, `hermes-router` and
`hermes-model` (Proxmox's GUI keeps comments) belong to this target. Only those
are replaced, placed first in `[RULES]`; every other line stays. Each write
goes through `targets/pve-firewall-swap.pl` under the CT's firewall lock and
only if the file is unchanged since read, so a concurrent edit stops the run
and is kept.

- New rules are added beside the old ones before the guest changes (so a moved
  router stays reachable) and the old ones removed after success; a failed run
  leaves the CT reachable, and rerunning finishes it.
- The egress mode is read from `policy_out` and never changed; edit it and the
  rules yourself, or recreate the CT.
- Uncommented rules from older versions are recognized by their layout (API
  rule first, then the router rule); an unmarked inbound rule is adopted only
  if prior settings show the API server on that port. If ownership is unclear
  the run stops before changing anything.
- A missing firewall file produces a warning and is not created.

## Use and maintain

```bash
pct exec 282 -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes          # CLI
pct exec 282 -- grep -E '^HERMES_DASHBOARD_BASIC_AUTH_(USERNAME|PASSWORD)=' /home/hermes/.hermes/.env
pct exec 282 -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes update
pct exec 282 -- systemctl try-restart hermes-gateway.service hermes-dashboard.service
journalctl -u hermes-direct -f     # in the CT: "direct dispatch MODEL -> SERVER"
```

The install is non-interactive and skips browser and computer-use downloads.
Code and profile live under `/home/hermes/.hermes`; the hardened gateway can
write only `/home/hermes` and a private `/tmp`. The dashboard password, session
secret and any OAuth dashboard credentials are kept on reconfigure. A
recorded `HERMES_COMMIT` pin is kept too, and a rerun moves the checkout back
to it: change the pin, or clear it with `HERMES_COMMIT=`, to upgrade. `tools/upgrade-all.sh` upgrades the integration and
leaves Hermes at its version; with `--update-hermes` it also runs `hermes
update` and restarts the gateway and dashboard, unless `HERMES_COMMIT` is set.

**Choosing a model.** Hermes's `/model` switcher offers:

| Provider | Goes to | Example |
|---|---|---|
| `custom:osr` | The router-ranked dispatcher (default); `auto`, tier names or any router model | `/model custom:osr:xlarge` |
| `custom:<target>` | One model server directly, with its backend key; models from its own `/api/tags` or `/v1/models`. No ranking or failover, so it works while the router is down | `/model custom:strata-192-168-11-154-8080:qwen3.8-flash-next-iq3_xxs` |

Plain-HTTP IPv4 targets are named `<kind>-<ip>-<port>`; other endpoints get a
stable URL-derived suffix. Names come from the inventory at the last provision
or reconfigure and are kept in `/etc/hermes-target/targets`; after adding or
removing a model server, `--reconfigure` adds or removes providers (and
firewall rules). A direct pick skips the tool and context checks, so choose a
tool-capable model with enough context.

| Symptom | Cause / fix |
|---|---|
| "rejected the API key … --reconfigure" | The router key was rotated: `provision-lxc.sh --reconfigure` |
| `model server … is unreachable; skipping it` in `journalctl -u hermes-direct` | Not yet admitted (`--reconfigure` after adding a server or changing its DNS), down, or blocked by the model host's firewall |
| 503 "No available chat model with tool support and at least … tokens of context" | Check `tools` and `context_length` per model in `/routing/inventory`; raise the host's context or add `tools` to llama.cpp's `MODEL_CAPABILITIES` |
| "Direct model-server chat probe failed" | Check `/routing/inventory`, backend keys and direct access from this CT to the model host |
| Agent forgets instructions or tools mid-task | The host serves less than `HERMES_CONTEXT_LENGTH`; raise it on the host |
| Open WebUI lists no `hermes-agent` | `systemctl status hermes-gateway` in the CT, then `--integrate-only`; the router needs TCP 8642 through the firewall |
| Chats are slow to get a title | The Task Model (External) must be a router model, not `hermes-agent` |
