# Hermes Agent companion for Ollama Smart Router

Hermes is an **agent client** of the router, not a model-serving inference
target. This target creates a dedicated unprivileged Debian LXC and installs
[Hermes Agent](https://hermes-agent.nousresearch.com/) with the [official POSIX
installer](https://hermes-agent.nousresearch.com/install.sh). Hermes's custom
OpenAI-compatible provider is set to the router's `http://<router>:8000/v1`,
authenticated with the router's `ROUTER_API_KEY`.

By default Hermes's **API server** also runs in the CT (`hermes-gateway.service`,
TCP 8642). It is registered in the router's Open WebUI as a second OpenAI
connection, so `hermes-agent` appears in the model list next to the router's
models. The request path is:

```
browser -> Open WebUI :8080 -> Hermes API server :8642 (Hermes CT) -> router :8000/v1 -> model pool
```

The agent's tools (terminal, files, web) run as the unprivileged `hermes`
account inside the Hermes CT.

## Before you start

- **The router is installed** and its API port (8000) is reachable from the
  Proxmox host and from the new CT's address. With the router CT's firewall
  on, `API_ALLOW_CIDR` must include the Hermes CT.
- **An Open WebUI admin API key or JWT**, as for Open Terminal: Settings →
  Account (enable API keys in Admin Settings → Authentication first). The
  script prompts for it without echo; for unattended runs set
  `OPENWEBUI_ADMIN_TOKEN`. It is removed from the environment at once and
  deleted from temporary files after use. Not needed with `OPENWEBUI=false`.
- **A tool-capable model with at least 64K context.** Hermes needs 64,000
  tokens of context for agent work with tools.
  - The pool's defaults are smaller: the Ollama target ships
    `OLLAMA_CONTEXT_LENGTH=8192`, and llama.cpp `CONTEXT_SIZE=8192` is split
    across `PARALLEL_SLOTS`.
  - Raise the host that will serve Hermes: `OLLAMA_CONTEXT_LENGTH=65536` in
    `/etc/ollama-target/ollama.env`, or `CONTEXT_SIZE` of at least
    65536 × `PARALLEL_SLOTS` for llama.cpp. Otherwise Ollama silently drops the
    start of the prompt (Hermes's tool definitions), and llama.cpp rejects it.
  - The router does not know context sizes (ARCHITECTURE §14), so
    `HERMES_CONTEXT_LENGTH` must match what the host really serves.
  - llama.cpp models need `tools` in the bridge's `MODEL_CAPABILITIES` before
    the router sends them tool requests.

## Provision on the Proxmox host

```bash
CT_ID=282 ROUTER=280 \
TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.168.11.82/24 GATEWAY=192.168.11.1 \
bash targets/hermes/provision-lxc.sh --dry-run          # print the plan

CT_ID=282 ROUTER=280 \
TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.168.11.82/24 GATEWAY=192.168.11.1 \
bash targets/hermes/provision-lxc.sh
```

`ROUTER` is the router CT's ID on this host, or the IP address or hostname of
a router LXC/VM that root can log in to over SSH (as for Open Terminal).

Before creating anything, the provisioner:

1. Reads `ROUTER_API_KEY` from the router's `/app/router/secrets.env` into a
   0600 file. The key never appears in a command line.
2. Detects the address the router uses to reach the new CT. The default
   `ROUTER_URL` is `http://<that address>:<router port>`.
3. Checks that `ROUTER_URL/v1/models` accepts the key.
4. Checks Open WebUI's health and asks for the admin token.

It then creates the CT and its firewall, and pushes `install-target.sh`,
`hermes-gateway.service` and the router key. The guest installer then:

1. Sends one test chat request that offers a tool. This proves the key, tool
   support and inference before anything is installed.
2. Installs Hermes as the `hermes` account.
3. Configures the provider: `model.provider custom`, `model.base_url`,
   `model.default`, `model.context_length` and `model.api_key`.
4. Generates the API server key in `/etc/hermes-target/api-key` (0600) and
   writes the `API_SERVER_*` settings to `~/.hermes/.env`.
5. Starts `hermes-gateway.service` and waits for `/health` and `/v1/models`.

Finally, `integrate-webui.py` runs in the router CT:

1. Checks the Hermes key against Hermes.
2. Has Open WebUI's own backend verify the connection, which also proves the
   firewall admits the router.
3. Adds or updates the OpenAI connection by URL. The router's connection and
   any others are kept as they are.

| Setting | Default | Meaning |
|---|---|---|
| `HERMES_MODEL` | `auto` | A model ID from the router's `/v1/models`. With `auto`, the router keeps a tool request on a tool-capable model of at least `tools_min_class` (default `large`), and keeps one agent loop on one model. Name a model for a fixed choice. |
| `HERMES_CONTEXT_LENGTH` | `65536` | Context the model's host serves; at least 64000. |
| `HERMES_CHANNEL` | `stable` | Upstream update channel (`stable` or `main`). |
| `HERMES_COMMIT` | — | Pin the Hermes checkout to a commit. A changed pin is applied on the next run. The installer reports the installed commit so you can pin it. |
| `HERMES_INSTALLER_SHA256` | — | Refuse an `install.sh` with another SHA-256. Every run prints the downloaded installer's checksum. |
| `OPENWEBUI` | `true` | `false`: CLI only. No API server, no inbound port, no admin token needed. |
| `TASK_MODEL` | `fast` | Router model for Open WebUI's titles, tags and follow-ups (Admin Settings → Interface → Task Model (External)). It is set only when unset, or when it points at Hermes. Blank leaves it alone. |
| `HERMES_API_PORT` / `HERMES_API_MODEL_NAME` | `8642` / `hermes-agent` | API server port, and the model name Open WebUI shows. Ports 8644–8646 are reserved by Hermes. |
| `EGRESS` | `restricted` | See [Network](#network). |
| `ROUTER_URL`, `ROUTER_IP`, `OPENWEBUI_PORT` | detected | Override the router URL, the router's source address, or Open WebUI's port. |
| `BRIDGE`, `CT_HOSTNAME`, `CORES`, `MEMORY_MB`, `SWAP_MB`, `ROOTFS_GB`, `ONBOOT`, `NAMESERVER`, `VLAN_TAG` | 2 cores, 4096 MB, 1024 MB swap, 32 GB | CT settings. |

### Modes

| Run | Does |
|---|---|
| default | Creates a new CT. A failed run leaves the CT for inspection; fix the error and use `--reconfigure`. |
| `--reconfigure` | An existing Hermes CT. Pushes the router's **current** key, the installer and the unit, reruns the guest installer with the given settings, updates the CT's Hermes firewall rules (see [Network](#network)), then registers it again. Use it after `manage-model-servers set-api-key`, or to change model, context, port, `OPENWEBUI` or the router's address. |
| `--integrate-only` | Registers an existing CT's API server in Open WebUI again, for example after resetting `webui.db`. |

Rerunning the guest installer with unchanged settings says "nothing to do".
It compares a settings record that includes a hash of the router key, so a
rotated key counts as a change. A failure while configuring restores the
previous `config.yaml`, `.env` and unit, and health-checks the previous API
server: it reports "running again" or "did not become healthy either".

## Open WebUI

After provisioning, choose **hermes-agent** in the model picker. The
connection uses the Chat Completions API (the default). Hermes streams tool
progress and keepalives, so long tool runs do not time out.

- **Who can use it.** Check the model's visibility under Admin Settings →
  Models before sharing it. Anyone who can chat with `hermes-agent` runs tools
  as `hermes` in this CT. They also share one Hermes profile: its memory,
  skills and the router key in its configuration. For separate users, run one
  Hermes profile per user or group, each with its own `API_SERVER_PORT`, key
  and Open WebUI connection.
- **Task model.** Titles, tags and follow-ups go to `TASK_MODEL`. If that
  setting pointed at Hermes, every chat title would start an agent run and end
  up in Hermes's memory.
- **One agent at a time.** Don't attach Open WebUI tools, Open Terminal or web
  search to the Hermes model; Hermes has its own.
- **Files.** Open WebUI's document retrieval puts file text into the prompt,
  which works. Hermes refuses raw file attachments (`input_file`); inline
  images work.

## Network

With the Proxmox firewall enabled at datacenter level, the CT's
`/etc/pve/firewall/<CT_ID>.fw` admits inbound only the router's address, and
only to the API server port. Inbound SSH is not admitted; use
`pct enter <CT_ID>`.

With `EGRESS=restricted` (default), outbound traffic is allowed, in this order:

1. The router's API, from `ROUTER_URL`.
2. DNS.
3. HTTP(S) to the internet, for packages, `hermes update`, and Hermes's web
   tools.

All other outbound traffic is dropped, including private (RFC 1918), CGNAT
and link-local addresses. An agent with a shell therefore cannot reach the
model hosts directly, Open Terminal, or other LAN services. `EGRESS=open`
allows all outbound traffic, for example when packages must come through a LAN
proxy.

**What `--reconfigure` changes.** Two rules belong to this target: the inbound
API rule and the outbound router rule. They carry the rule comment
`ollama-smart-router hermes-api` / `hermes-router`, which Proxmox keeps when
you edit the firewall in its GUI. `--reconfigure` replaces only those two,
puts them first in `[RULES]` so they match first, and leaves every other line
as it is.
- **Order.** Before anything in the CT changes, the new rules are added next
  to the old ones, so the guest installer can reach a moved router. Once it
  has succeeded, the old ones are removed. A failed run therefore leaves the
  CT reachable as before; rerun `--reconfigure` to finish.
- **Changing the egress mode.** The egress mode is read from the file's
  `policy_out` and never changed; edit `policy_out` and the rules yourself, or
  recreate the CT, to switch.
- **CTs from earlier versions.** Their rules have no comment. The layout those
  versions wrote is recognised: the API rule first in `[RULES]`, then the
  router rule. An unmarked inbound rule is adopted only if the CT's prior
  settings say its API server was enabled on that port. If the file was edited
  so that it is unclear which rules are Hermes's, the run stops before
  changing anything, and says so.
- **No firewall file.** If `/etc/pve/firewall/<CT_ID>.fw` is missing,
  `--reconfigure` warns and does not create one.

## Use and maintain Hermes

Open the CLI from the Proxmox host:

```bash
pct exec 282 -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes
```

The installer uses Hermes's non-interactive mode and skips the browser and
computer-use downloads for this headless CT. Code and profile live under
`/home/hermes/.hermes`. `hermes-gateway.service` runs `hermes gateway run`,
hardened: the agent can write only to `/home/hermes` and a private `/tmp`.

Upgrade the agent with Hermes's own updater, then restart the gateway:

```bash
pct exec 282 -- runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes update
pct exec 282 -- systemctl restart hermes-gateway
```

With `HERMES_COMMIT` set, a rerun moves the checkout back to the pin. Unpin it,
or set the new commit, when you upgrade.

| Symptom | Cause / fix |
|---|---|
| "rejected the API key … --reconfigure" | The router key was rotated. Run `provision-lxc.sh --reconfigure`. |
| "test chat request with a tool failed … does not support tools" | No tool-capable model was chosen. Name one in `HERMES_MODEL`, or check `/routing/inventory`: Ollama reports `tools` per model; llama.cpp needs `MODEL_CAPABILITIES=…,tools`. |
| The agent forgets its instructions or tools mid-task | The host's context is smaller than `HERMES_CONTEXT_LENGTH`. Raise it on the host (see above). |
| Open WebUI lists no `hermes-agent` | `systemctl status hermes-gateway` in the CT, then `--integrate-only`. With the firewall on, the router's address needs TCP 8642. |
| Chats are slow to get a title | Check that the Task Model (External) is a router model, not `hermes-agent`. |
