# Ollama Smart Router — Setup & Operations

A Proxmox LXC that fronts a small Ollama cluster with complexity-based model
routing, load balancing, a chat UI, and health alerting. Provisioned by
`ollama-smart-router-install.sh` (run as root on the Proxmox host).

## What gets deployed

A **privileged** Debian 13 container running four systemd services, all as the
hardened `ollama-router` user:

| Service | Unit | Port | Notes |
|---|---|---|---|
| nginx (TLS front end) | `nginx.service` | 8080, 8000 | Terminates HTTPS for both public ports |
| Open WebUI (chat UI) | `open-webui.service` | 8088 | Loopback only; reached through nginx |
| Smart Router (OpenAI API) | `ollama-router.service` | 8010 | Loopback only; reached through nginx |
| LiteLLM proxy | `litellm-proxy.service` | 4000 | Localhost only; load balances backends |
| Health monitor | `ollama-monitor.service` | — | Probes backends, alerts to Mattermost |

Request path: **browser → nginx (TLS) → Open WebUI → nginx (TLS) → Smart Router → LiteLLM (4000) → Ollama backends (11434)**.

> **The container is privileged.** Container root is real host root — the UID
> shift that makes an unprivileged container a containment boundary is not
> there, so a root process inside it is far closer to root on the Proxmox host.
> That is the trade for device passthrough, host bind mounts and NFS shares
> working without UID gymnastics. Everything *inside* still applies least
> privilege — services run as the non-login `ollama-router` account under
> systemd hardening, and the internals bind loopback only — but treat the
> container as trusted infrastructure rather than a sandbox. `CT_UNPRIVILEGED=1`
> at install time reverts to an unprivileged container.

## How routing works

`/app/router/router.py` is a drop-in OpenAI-compatible endpoint. It routes in
two modes, preferring the first:

### 1. Live model discovery (default)

A background task polls every Ollama target's `/api/tags` on an interval
(`refresh_seconds`, default 60) and builds an inventory of what each host is
*actually* serving — model name, parameter count, quantisation and family. Each
request is then scored against that live inventory rather than a static map:

- **Size fit** — the request is classified `fast` / `medium` / `large` /
  `xlarge` (prompt length + keywords), and each model is scored on how well its
  parameter count fits that class's band (`0:9`, `9:20`, `20:70`, `70:999`
  billions by default), decaying outside the band rather than being
  disqualified. Band ceilings are **exclusive**, so the bands are disjoint and a
  70B model belongs to `xlarge` alone — otherwise `large`, which prefers the
  biggest model in its band, would take the very model that defines `xlarge`.
  The size preference is a position *within* the band, so an out-of-band giant
  never outscores a perfect in-band fit. If **no** model is in band — asking for
  `xlarge` when the largest host has a 27B — candidates are ranked by distance
  to the band rather than by score, so the closest (largest available) model
  wins. Without that they would all flatten to the same floored score and the
  load-spreading rotation would hand the request to the smallest one half the
  time.
- **Specialisation** — a code request prefers a code model (`coder`, `starcoder`,
  `deepseek-coder`…); a request containing an image prefers a vision model
  (`llava`, `-vl`, `minicpm-v`…). A specialist serving an off-task request takes
  a penalty, so a vision model isn't handed plain text when a same-size text
  model exists.
- **Embedding models are never selected** for chat completions, however the
  prompt is worded.
- **Load spreading** — candidates within `tie_epsilon` of the best are rotated,
  so the same model on several hosts shares traffic.
- **Fail-forward** — the ranked candidate list is retried in order on connection
  errors or upstream 5xx, which also covers a host that died since the last
  refresh. Retries stop once the response body starts streaming.

Parameter counts come from `details.parameter_size`, falling back to the tag
(`qwen3:14b` → 14B) when absent.

Discovery polls **every** configured host — it reads the full `MODEL_SERVERS`
list, not just the per-tier `BACKEND_*` vars, so a host you left out of every
tier is still discovered and can still be selected on merit.

Requests are dispatched straight to the chosen host's OpenAI-compatible
endpoint. The decision is reported in response headers: `X-Router-Model`,
`X-Router-Server`, `X-Router-Class`, `X-Router-Mode`, `X-Router-Candidates`.

An explicitly requested model that exists in the inventory is honoured and sent
to a host that has it — so the Open WebUI picker becomes meaningful. The tier
aliases (`fast`/`medium`/`large`/`xlarge`) and `auto` mean "decide for me",
with a tier alias pinning the size class.

Endpoints for inspection:

```
GET  /routing/inventory   # what each target is serving, per-server up/down + errors
POST /routing/refresh     # force a re-poll now
POST /routing/explain     # {"prompt": "..."} -> the decision and scored candidates
GET  /healthz
```

All of the above — bands, weights, keyword lists, refresh interval — lives in
`router.ini` in the repo, so routing behaviour changes by commit.

### 2. LiteLLM tier path (fallback)

If discovery is disabled (`enabled = false`) or the inventory is empty (every
target unreachable), the router falls back to the original static behaviour:
complexity analysis picks a tier name and forwards to LiteLLM, which keeps its
own latency routing and cross-tier fallbacks. Responses carry
`X-Router-Mode: litellm`.

LiteLLM (`/app/router/litellm_config.yaml`) maps the four tiers to backends
with `latency-based-routing` and cross-tier fallbacks:

Tiers, their servers and their model tags are all chosen at install time; the
generated `litellm_config.yaml` contains one deployment per (tier, server) pair.

## Configuration

The installer is driven by environment variables (all have defaults). Key ones:

- `CT_ID`, `CT_NAME`, `IP_CIDR`, `GATEWAY`, `BRIDGE`, `NAMESERVER`
- `STORAGE`, `TEMPLATE_STORAGE`, `TEMPLATE_MIN_GIB` (2), `CORES` (2), `MEMORY` (4096), `SWAP` (1024), `ROOTFS_GB` (32 — safe for the CUDA fallback; ~16 suffices once CPU-only is confirmed)
  — `STORAGE` and `ROOTFS_GB` are confirmed against live free space at install time
- `OPENWEBUI_VERSION` (0.11.0), `OPENWEBUI_PY_VERSION` (3.12), `OPENWEBUI_PY_DIR` (`/opt/python`), `TORCH_CPU_ONLY` (true)
- `MODEL_SERVER_COUNT` (1–20), `MODEL_SERVER_1`…`MODEL_SERVER_<n>`, `OLLAMA_PORT`, `MODEL_SERVER_MIN`/`MODEL_SERVER_MAX`
- `TIER_FAST_SERVERS` / `TIER_MEDIUM_SERVERS` / `TIER_LARGE_SERVERS` / `TIER_XLARGE_SERVERS` (e.g. `1,3`)
- `MODEL_FAST` / `MODEL_MEDIUM` / `MODEL_LARGE` / `MODEL_XLARGE` — model tag per tier
- `NONINTERACTIVE` (false) — take every default and skip all prompts
- `GITEA_SERVER_URL` (`https://git.test.com`), `GITEA_ADMIN_USER`, `GITEA_REPO_NAME` (`ollama-smart-router`), `GITEA_REPO_OWNER` (auto), `GITEA_REPO_PRIVATE`, `GITEA_VERIFY_TLS` (false)
- `MATTERMOST_WEBHOOK_URL`, `MATTERMOST_MONITOR_USER`, `MATTERMOST_CHANNEL` (`ollama-monitor`), `MATTERMOST_VERIFY_TLS` (true)
- `FIREWALL`, `API_ALLOW_CIDR` — if the CT firewall is on, set the allow-CIDR or ports 8000/8080 may be dropped
- `OPENWEBUI_PORT` (8080)
- `TLS_ENABLED` (true), `TLS_CERT_DAYS` (3650), `TLS_KEY_BITS` (4096), `TLS_DIR` (`/app/tls`)
- `TLS_EXTRA_SAN` — extra names for the certificate, comma separated (e.g. `chat.lan,10.0.0.9`). Add the DNS name you actually browse to, or hostname verification fails
- `OPENWEBUI_INTERNAL_PORT` (8088), `ROUTER_INTERNAL_PORT` (8010) — where the apps bind once nginx owns the public ports
- `CT_UNPRIVILEGED` (0) — `0` creates a **privileged** container, `1` an unprivileged one. See the note below before changing it
- `CT_FEATURES` (`nesting=1`) — passed to `pct create -features`. Nesting permits nested user namespaces, so Docker/Podman work inside and systemd's per-unit sandboxing sets up its mount namespaces cleanly. Comma separated; empty omits the flag

### Install-time prompts

The installer prompts for:

1. **Root password** for the container (entered twice, hidden).
2. **Network** — Proxmox bridge, router IP/CIDR, gateway, optional DNS. The
   gateway is checked against the router's subnet; a mismatch warns, since the
   container would come up with no default route.
3. **Storage** — rootfs size, then a picker listing every active storage that
   accepts `rootdir` content with its free space. Candidates come from
   `pvesm status -content rootdir`, falling back to the full `pvesm status`
   table cross-referenced against `content=` in `/etc/pve/storage.cfg` when
   that filter returns nothing (it does on some setups). If no storage declares
   `rootdir` at all, the installer says so and prints the fix
   (`pvesm set <storage> --content rootdir,images`). Storages without room for the chosen rootfs
   are shown but not selectable, so the install cannot start on a disk that
   cannot finish it. The size is asked first because it decides what is
   eligible. If nothing fits, the installer stops with guidance rather than
   failing partway through `pct create`.
4. **Gitea** — server URL, username, repository name, and auth token (hidden).
   Preset `GITEA_DEPLOY_TOKEN` to skip the token prompt on unattended runs.
5. **Mattermost** — incoming webhook URL (blank disables alerting), plus
   channel, posting username, and whether to verify the server's TLS
   certificate. The channel is the **URL handle** (`ollama-monitor`), not the
   display name; leaving it blank posts wherever the webhook is already bound,
   which avoids the channel-override rejection described below.
6. **Model servers** — how many (**1–20**), each address, the tier assignment,
   and the model tag per tier. A count outside the range is rejected with a
   specific error (too few / too many / not a number) and re-prompted.

Every prompt offers a default that Enter accepts, and each value is validated
with a re-prompt on bad input (malformed CIDR, out-of-range port, a tier
referencing a server that doesn't exist). `NONINTERACTIVE=true` takes all
defaults, so the whole thing can run unattended from environment variables.

### Model servers and tiers

The four tiers are named `fast`, `medium`, `large` and `xlarge`. Those names are the
LiteLLM `model_name` aliases you call over the API, the keys in `router.ini`,
and the `BACKEND_FAST` / `BACKEND_MEDIUM` / `BACKEND_LARGE` / `BACKEND_XLARGE` entries in
`router.env` that list which servers back each tier. Nothing about them is
model-specific — a tier is a size class, and you point it at whatever model you
like with `set-model` or `set-server-model`.

> **Upgrading an existing install — manual.** The tiers have been renamed twice,
> so a config deployed before this version may be one or two generations behind:
>
> ```
> BACKEND_QWEN_HEAVY  ->  BACKEND_HEAVY  ->  BACKEND_LARGE
> model_name qwen-heavy  ->  heavy  ->  large
> ```
>
> (the `QWEN_` infix went when the router stopped being Qwen-specific; `heavy`
> became `large` when `xlarge` was added). **There is no automatic migration** —
> the scripts do not rewrite an old config. Either reprovision, or edit
> `env/router.env`, `services/litellm-proxy/litellm_config.yaml` and
> `services/ollama-router/router.ini` by hand:
>
> | Old | New |
> |---|---|
> | `BACKEND_QWEN_HEAVY=` / `BACKEND_HEAVY=` | `BACKEND_LARGE=` |
> | `BACKEND_QWEN_FAST=` / `BACKEND_QWEN_MEDIUM=` | `BACKEND_FAST=` / `BACKEND_MEDIUM=` |
> | `MODEL_HEAVY=` | `MODEL_LARGE=` |
> | `model_name: qwen-heavy` / `heavy` | `model_name: large` |
> | `[thresholds] heavy =` / `[keywords] heavy =` / `[tiers] heavy =` | `large =` |
> | `heavy_params = 20:999` | `large_params = 20:70` **plus** `xlarge_params = 70:999` |
> | `prefer_larger_heavy` / `prefer_smaller_fast` | `prefer_larger` / `prefer_smaller` |
>
> Then add the new tier's keys (`BACKEND_XLARGE=`, `MODEL_XLARGE=`), an
> `xlarge = xlarge` entry under `[tiers]`, and an `xlarge` threshold and keyword
> list — or leave those out and the router falls back to its built-in defaults
> for anything `router.ini` does not set. Populate the tier with:
>
> ```bash
> manage-model-servers set-tier  xlarge 10.0.0.54
> manage-model-servers set-model xlarge llama3.3:70b --apply --commit
> ```
>
> Model *tags* like `qwen3:32b` are unaffected — only routing names changed. The
> running services do still read the old env key names as a fallback, so a
> service that starts against an un-migrated `router.env` resolves its backends
> rather than coming up healthy with nothing behind it. **If you call the API
> with `qwen-heavy` or `heavy`, change it to `large`** — the old aliases stop
> resolving once the config is regenerated.

Only `MODEL_SERVER_1`–`MODEL_SERVER_3` carry built-in defaults; higher indices
have none and must be typed (or preset via `MODEL_SERVER_<n>`).

Addresses accept `10.0.0.5`, `10.0.0.5:11434`, `ollama1.lan`, or a full URL,
and are normalised to a base URL with an explicit port (`OLLAMA_PORT`,
default 11434).

A tier may be assigned **several** servers (`1,3`), in which case LiteLLM emits
one deployment per server under the same `model_name` and load-balances across
them with its latency routing. The same server may also back several tiers —
necessary when you only have two. Defaults scale with the count so nothing sits
idle:

Servers are split into four contiguous groups, with the remainder going to the
xlarge tier (which gains most from extra parallel capacity). Counts below 4
can't give every tier its own host, so the upper tiers share the last one — an
xlarge model is the least likely to fit on an early, smaller host:

| Servers | fast | medium | large | xlarge |
|---|---|---|---|---|
| 1 | 1 | 1 | 1 | 1 |
| 2 | 1 | 2 | 2 | 2 |
| 3 | 1 | 2 | 3 | 3 |
| 4 | 1 | 2 | 3 | 4 |
| 5 | 1 | 2 | 3 | 4,5 |
| 8 | 1,2 | 3,4 | 5,6 | 7,8 |
| 20 | 1–5 | 6–10 | 11–15 | 16–20 |

From 4 servers up, every host lands in exactly one tier — no gaps, no overlap.

The installer prints the resulting routing plan, warns about servers assigned to
no tier, and warns if the same address was entered twice (it would be weighted
twice in latency routing). The health monitor tracks every `(tier, server)` pair
independently but probes each distinct host only once per cycle.

Model tags are prompted per tier — this is where to correct the inherited
`qwen3.8:27b` value to whatever you actually pulled.

The username/token pair is **verified against the Gitea server before anything
is built**, so a bad token costs seconds instead of a full provisioning run. A
rejected token is re-prompted up to 3 times. If the token belongs to a different
account than the username entered, the installer says so and uses the token's
real owner as the repository owner.

If no usable token is supplied (blank, or 3 failed attempts), provisioning
continues in **local mode**: the generated config tree is shipped into the
container directly and applied through the same `apply-config.sh` path, so the
end state is identical minus version control. The run never aborts for this.

The root password is set via `chpasswd` over stdin (never on the command line),
and all config/app files are staged on the host and pushed in, so secret values
can't break shell quoting or be mangled by a heredoc.

Runtime config lives at `/app/router/.env` (0640, root:ollama-router) and
`/app/openwebui/.env`.

### Python versions (important)

Every `open-webui` release requires Python `>=3.11,<3.13` — still true as of
0.11.0 — but Debian 13 ships Python **3.13**. Installing it with the system interpreter fails with:

```
ERROR: Could not find a version that satisfies the requirement open-webui==...
       (from versions: none)
```

— pip filters out every candidate on the `Requires-Python` gate, which is why
the version list looks empty. The installer therefore provisions a dedicated
**Python 3.12** for Open WebUI only (`ensure_openwebui_python`), trying in
order: an existing `python3.12`, the distro package, then a `uv`-managed
standalone CPython installed to `/opt/python`. The router/LiteLLM venv keeps
using the system interpreter.

Candidates are validated by actually running them **as the `ollama-router`
service user** — an interpreter under `/root` (mode 700) would otherwise build
a venv that fails at service start.

The uv fallback needs outbound HTTPS to PyPI and GitHub. If neither is
reachable, install a 3.11/3.12 interpreter manually and re-run.

### Upgrading Open WebUI

The pinned version lives in `services/open-webui/requirements.txt` in the config
repo, so it is version controlled like everything else.

```
manage-model-servers set-webui-version                 # pinned / installed / latest
manage-model-servers set-webui-version latest --apply  # upgrade
manage-model-servers set-webui-version 0.9.6 --apply   # or a specific release
```

`set-webui-version` checks the release exists on PyPI **and** that the venv's
interpreter satisfies its `Requires-Python` before writing the pin, so an
upgrade needing a different Python is refused up front instead of failing
mid-install. If PyPI cannot be reached, a version change is **refused** rather
than pinned unverified — but the no-argument query still works and reports the
latest release as `<unknown>`. `apply` then notices the pin no longer matches what is installed,
upgrades the venv, and restarts the service. Expect the install step to take a
while — it is a large dependency tree.

## Provisioning-time checks

- **Gitea:** `test_gitea_access` authenticates with the deploy token and
  creates the service repo if missing. The actual write check happens later,
  when the generated local config tree is committed and pushed as deployment
  history. Non-fatal — warns and continues on failure.

  **Which repository:** the installer always uses `GITEA_REPO_NAME`, default
  **`ollama-smart-router`** — every API call and the push remote are built from
  that one variable. The owner is resolved in this order: an explicit
  `GITEA_REPO_OWNER`; then the token owner; then a search across every repo the
  token can see, matching the name exactly. That search matters — if the repo
  lives under an organisation, resolving only against the token owner would 404
  and silently create a *duplicate*. If several repos share the name and none
  belongs to the token owner, the installer lists them and stops rather than
  guessing (set `GITEA_REPO_OWNER` to pick). It creates the repo only when no
  match exists anywhere, and treats HTTP 409 on create as "already exists".
  The resolved repository is printed as `Configuration repository: owner/name`.

  Gitea runs as a **TurnKey Gitea 18.0-1 appliance**, which serves through
  nginx on **80/443** — Gitea's own port 3000 is bound to localhost *inside*
  that container and is not reachable from outside, so the URL is
  `https://git.test.com` with no port.

  TurnKey ships a **self-signed certificate**, so `prompt_gitea_credentials`
  sets `GITEA_VERIFY_TLS=false` unconditionally — certificate verification is
  off for the credential check, repo resolution and history push. The trade-off is that the deploy token travels
  over a connection whose certificate isn't authenticated; if that network path
  isn't trusted, install the appliance's CA (or a real certificate) and change
  that line in `prompt_gitea_credentials` to `true`. Use an `https://` URL:
  curl drops the auth token when a redirect changes scheme, so an `http://`
  URL follows the appliance's 80→443 redirect and then 401s. The test emits a
  specific diagnostic for each of these cases (DNS, connect-refused, TLS, 401).
- **Mattermost:** on its first start — and after any change to the watched
  backend set — the monitor posts a green-check confirmation to
  `#ollama-monitor` naming the host and watched tiers, and logs a clear error
  (visible in `journalctl -u ollama-monitor`) if the webhook is rejected. Plain
  restarts are silent, so a flapping unit cannot flood the channel.
- **Container:** readiness is polled (systemd + DNS) before apt runs, apt is
  retried, and an `ERR` trap destroys a half-provisioned container on failure.

## Running the repo's scripts

`apply-config.sh` makes every `*.sh` in the config repo executable (skipping
`.git/`) and drops a `/etc/profile.d/ollama-router-path.sh` snippet that appends
`/app/config-repo` and `/app/config-repo/install` to `PATH`. So inside the
container the tools run by name:

```bash
manage-model-servers list
apply-config.sh /app/config-repo
```

Three things worth knowing:

- **Appended, never prepended.** A file committed to the repo cannot shadow a
  system command.
- **Login shells only.** `profile.d` is read by `pct enter` and `ssh`, but not
  by `pct exec <id> -- <cmd>`. That is why `apply-config.sh` also symlinks
  `/usr/local/bin/manage-model-servers` — and it does that as its *first* step,
  so a later failure can never leave you with a half-applied system and no
  management command to diagnose it with.
- **Root only, by design.** The repo is `0700 root:root` because
  `env/router.env` holds the Gitea token and the Mattermost webhook. Putting it
  on `PATH` is an operator convenience; the `ollama-router` service account
  still cannot traverse it.

Re-running `apply-config.sh` restores both the executable bits and the `PATH`
snippet, so this self-heals even if a later edit or history operation loses an
executable bit.

## Mattermost alerting

The monitor posts **state transitions only** — a backend going down, and its
recovery. A healthy, unchanged cluster is silent by design, so "no messages" is
the normal state and not on its own evidence of a problem.

Every cycle's raw result is written to the state file, along with a fingerprint
of the last message actually posted. Before anything is sent, the current
cluster state is compared against that fingerprint: **if it is the same, nothing
is posted**, no matter what the threshold logic upstream decided. That check is
the backstop — the thresholds and the persisted health should already prevent a
duplicate, and this makes it impossible rather than merely unlikely.

Quieting is deliberate, and tunable in `services/ollama-monitor/monitor.ini`:

| Setting | Default | Effect |
|---|---|---|
| `failure_threshold` | `3` | Consecutive failed probes before a backend is called down. At `1`, a host that times out on alternate cycles posts a down/up pair **every interval, forever**. |
| `recovery_threshold` | `2` | Consecutive successes before it is called recovered. |
| `repeat_seconds` | `0` | Reminders while an outage continues. `0` reports each outage exactly once. |
| `startup_notice` | `auto` | `auto` posts the "monitor online" self-test only on a first start or after the watched backend set changes. `always` / `never` override. |
| `state_file` | `/var/lib/ollama-monitor/state.json` | Where health, the last raw check and the last-posted fingerprint are remembered across restarts, so a restart mid-outage does not re-announce it. Created and owned by systemd's `StateDirectory=`. |

`repeat_seconds` is the one setting that can re-state something already said,
which is why it defaults to off.

Alerts are keyed by **host**, not by tier, and name every tier the host serves —
so one unreachable box is one message even when it backs all four tiers.
Transitions in the same cycle are batched into one post.

If the channel is noisy, these are the two things to check first:

```bash
journalctl -u ollama-monitor | grep -c "monitor online"   # restart loop?
systemctl show ollama-monitor -p NRestarts                # how many restarts
cat /var/lib/ollama-monitor/state.json                    # belief, last check, last post
```

A high `NRestarts` means the flood is the daemon restarting, not the alert
logic; `journalctl -u ollama-monitor -n 100` will show why it exited. Deleting
the state file re-arms every alert, which is occasionally what you want after
maintenance.

Check and change it without hand-editing `router.env`:

```bash
manage-model-servers test-alert                 # post a test message, diagnose failures
manage-model-servers set-webhook <url>          # set (empty url disables alerting)
manage-model-servers set-webhook --channel ''   # post wherever the webhook is bound
manage-model-servers set-webhook --verify-tls false   # self-signed Mattermost
manage-model-servers apply                      # restart the monitor to pick it up
```

`test-alert` uses the identical payload and TLS setting as the monitor, and
separates the three failures that otherwise look the same:

| Symptom | Cause |
|---|---|
| `MATTERMOST_WEBHOOK_URL is not set` | never configured — the monitor logs alerts instead of posting |
| `curl exit 60` / TLS failure | self-signed or internal CA → `set-webhook --verify-tls false` |
| 4xx that succeeds on retry without the channel | Mattermost refuses the **channel override** |
| 404 both ways | the webhook URL is wrong or deleted |

That third row is the common one. An incoming webhook is bound to a channel,
and many servers refuse to let a payload redirect it elsewhere — so naming the
channel explicitly fails with what reads like a permissions error. The monitor
handles this itself: on any 4xx it retries once **without** the channel field
and logs a warning, so the alert reaches the webhook's own channel rather than
being lost. Clearing `--channel ''` removes the warning.

The service log is the other source of truth:

```bash
journalctl -u ollama-monitor -n 50 --no-pager | grep -i mattermost
```

## HTTPS

Both public endpoints are served over TLS by nginx, using a self-signed
certificate the installer generates inside the container:

```
https://<ip>:8080        Open WebUI
https://<ip>:8000/v1     OpenAI-compatible API
```

The **ports are unchanged** — only the scheme is. Existing firewall rules and
bookmarks keep working; add the `s`.

### Why a proxy

Open WebUI cannot do TLS itself. Its `serve` command passes only host and port
to uvicorn and exposes no `--ssl-*` options, which is why its own documentation
recommends a reverse proxy. So nginx owns 8080 and 8000, and the two
applications move to `127.0.0.1:8088` and `127.0.0.1:8010` — loopback, so
there is no second unencrypted listener quietly serving the same thing.

The proxy config is not just `proxy_pass`. Three settings are load-bearing:

| Setting | Without it |
|---|---|
| `Upgrade` / `Connection` headers | Open WebUI's socket.io falls back to long-polling; the UI feels broken rather than failing outright |
| `proxy_buffering off` | nginx holds the token stream until a buffer fills, so replies arrive in bursts instead of word by word |
| `proxy_read_timeout 1h` | a long generation is cut off mid-sentence at nginx's 60-second default |

`client_max_body_size 200m` also lets Open WebUI's own limit decide what to
reject, rather than an nginx 413.

### 502 Bad Gateway

nginx is working and TLS is fine — the application behind it is not listening.
Almost always Open WebUI failing to bind:

```bash
pct exec <CTID> -- ss -lntp | grep -E '8088|8080'
pct exec <CTID> -- journalctl -u open-webui -n 50 --no-pager
```

`address already in use` means the unit is trying the wrong port. Open WebUI's
`serve()` is declared with **literal** defaults:

```python
def serve(host: str = "0.0.0.0", port: int = 8080):
```

It never reads `HOST` or `PORT` from the environment, so setting them in
`.env` alone leaves it binding `0.0.0.0:8080` — the port nginx owns. The unit
therefore passes them on the command line:

```
ExecStart=/app/openwebui/venv/bin/open-webui serve --host ${HOST} --port ${PORT}
```

systemd expands those from the `EnvironmentFile`, so the env file remains the
single source of truth. If an older container is missing the flags, add them
and `systemctl daemon-reload && systemctl restart open-webui`.

### The certificate

Self-signed, generated in the container so the private key never touches the
Proxmox host. `subjectAltName` covers the container IP, its hostname and
localhost — a certificate with only a CN has not been accepted as an identity
by any current browser since Chrome 58, so the SAN list is what makes it work
at all. Key `0600`, certificate `0644`, both under `/app/tls`.

```bash
manage-model-servers cert                      # subject, SANs, dates, fingerprint
manage-model-servers cert renew                # keeps the existing SANs
manage-model-servers cert renew --san chat.lan,10.0.0.9 --days 825
```

`renew` carries the existing SANs forward unless `--san` is given, so renewing
never silently narrows the certificate and breaks a client that reaches the box
by a name someone added months ago. It writes to a temporary pair and swaps only
once openssl has succeeded, so a failed renewal cannot leave nginx with a key
that no longer matches the certificate.

**Browsers will warn** until the certificate is trusted. To trust it:

```bash
# Fetch a copy from the Proxmox host
pct pull <CTID> /app/tls/server.crt ollama-router.crt

# Command-line clients
export SSL_CERT_FILE=/path/to/ollama-router.crt      # curl, requests, openai
curl --cacert ollama-router.crt https://<ip>:8000/v1/models
```

Import it into the OS or browser trust store to stop the warning. If you reach
the container by a DNS name, put it in the certificate first — either
`TLS_EXTRA_SAN=chat.lan` at install time or `cert renew --san chat.lan` after —
or hostname verification fails no matter how well trusted the certificate is.

### Turning it off

`TLS_ENABLED=false` at install time reverts to the previous behaviour exactly:
no nginx, the applications bind `0.0.0.0` on 8080 and 8000, plain HTTP.

## Evaluating routing quality

Every routed request writes one JSON object to
`/var/log/ollama-router/decisions.jsonl`, carrying the classification, **every
candidate's score with its component terms**, the winner, and what happened
next. The point is that a routing decision can only be judged against what it
rejected — "qwen3:14b answered" is not evaluable, but "it beat the in-band
qwen3:8b by 0.17 because the prompt matched a code keyword" is.

```bash
manage-model-servers routing-stats                 # summary
manage-model-servers routing-stats --class xlarge  # one class
manage-model-servers routing-stats --last 500      # recent traffic only
manage-model-servers routing-stats --json          # for a script
```

The summary is built around four numbers that each point at a specific
misconfiguration:

| Number | What a bad value means |
|---|---|
| **top candidate in band** | Low means the `*_params` bands and the models actually installed have drifted apart — either pull different models or move the bands. |
| **distance-ranked requests** | The share where *nothing* was in band, so ranking fell back to "closest to the band". Persistently high for one class means that class has no hardware behind it. |
| **mean tie-group size** | How many candidates the load-spreading rotation treats as equivalent. Consistently above 2 means `tie_epsilon` is wide enough to be spreading traffic across models that are not really interchangeable. |
| **median winning margin** | The score gap between first and second place. Near zero means the scoring is not discriminating, and the choice is effectively arbitrary. |

For anything the summary does not cover, query the file directly:

```bash
# Requests where an out-of-band model won, and by how much
jq -r 'select(.candidates[0].in_band == false)
       | [.request.class, .chosen.model, .candidates[0].band_distance] | @tsv' \
   /var/log/ollama-router/decisions.jsonl

# Which keyword is sending things to xlarge
jq -r 'select(.request.class=="xlarge") | .request.matched.xlarge[]' \
   /var/log/ollama-router/decisions.jsonl | sort | uniq -c | sort -rn

# Slowest requests, with the model that served them
jq -r 'select(.total_ms) | [.total_ms, .chosen.model, .request.prompt] | @tsv' \
   /var/log/ollama-router/decisions.jsonl | sort -rn | head

# Everything about one request, by the id in the X-Router-Request-Id header
jq 'select(.id=="9f2c1a4b7e30")' /var/log/ollama-router/decisions.jsonl
```

A worked example. This record says the request was classed `fast` because it
matched the code keyword `function`, and that the winner was **out of band**:

```
class=fast  reason="code keyword (code_first)"  matched.code=["function"]
  rank 0  qwen2.5-coder:14b  score 1.183  in_band=false  terms{band 0.583, code 0.6}
  rank 1  qwen3:8b           score 1.017  in_band=true   terms{band 1.0, size 0.017}
```

The 14B coder won on the `code` term despite scoring worse on band fit. Whether
that is right is a judgement about your pool — but it is now a visible,
quantified judgement rather than a guess, and `code_match` in `[weights]` is the
dial that changes it.

`POST /routing/explain` returns this same shape for a prompt without executing
it, so a hypothesis formed from the log can be tested directly:

```bash
curl -s localhost:8000/routing/explain \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "prove that the algorithm terminates"}' | jq
```

### Settings

`[logging]` in `router.ini`:

| Setting | Default | Notes |
|---|---|---|
| `level` | `INFO` | One journal line per routed request. `DEBUG` adds discovery polls. |
| `decisions` | `true` | The JSONL records. |
| `decision_file` | (blank) | Blank uses systemd's `LogsDirectory=`, i.e. `/var/log/ollama-router/decisions.jsonl`. |
| `max_bytes` / `backup_count` | 20 MB / 5 | Rotation. |
| `prompt_chars` | `200` | Prompt text kept per record. `0` stores only derived features. |
| `log_candidates` | `10` | Ranked candidates recorded per request. `0` = all. |

> **The prompt text in this file has the same sensitivity as the chat itself.**
> The router chmods it to `0640` explicitly — the process umask would otherwise
> leave it `0644` — inside a `0750` directory owned by the service account.
> `apply-config.sh` also installs `/etc/logrotate.d/ollama-smart-router` as an
> OS-level cap on anything else written to that directory. Set
> `prompt_chars = 0` to keep the analysis without keeping any content.

### The other services

| Service | Setting | Where |
|---|---|---|
| Router | `[logging] level` | `router.ini` (version controlled) |
| Monitor | `[logging] level` | `monitor.ini`. `DEBUG` logs every probe with its latency and failure/success streaks — how you catch a host flapping *before* it crosses a threshold. |
| LiteLLM | `LITELLM_LOG` | `router.env`. `DEBUG` prints full request/response bodies. |
| Open WebUI | `GLOBAL_LOG_LEVEL` | `openwebui.env` |

```bash
journalctl -u ollama-router -f            # live routing decisions
journalctl -u ollama-monitor -f           # probes and transitions
```

## When Open WebUI will not start

**The installer now handles this case itself** — it starts Open WebUI on its
own, waits for the port, and resets the database once if the first-run
migration fails. What follows is for containers built with an older installer,
or for a failure the installer could not resolve.

The unit reports `active` but nothing listens on 8080, and the journal shows:

```
sqlalchemy.exc.OperationalError: (sqlite3.OperationalError) duplicate column name: info_json
[SQL: ALTER TABLE user ADD COLUMN info_json JSON]
```

Open WebUI's first start creates its schema and then runs alembic over it; on a
brand-new database the two disagree, the column is added twice, and the process
dies. The revision is never stamped, so every later start retries the same
`ALTER`. It cannot recover on its own. This is upstream behaviour rather than
anything in this configuration.

On a fresh install there is nothing to preserve, so move the database aside:

```bash
systemctl stop open-webui
mv /app/openwebui/data/webui.db{,.broken}
systemctl start open-webui
journalctl -u open-webui -f        # first start takes minutes
```

On an install with real accounts, repair rather than replace — back up
`webui.db`, then stamp the current revision with the alembic config inside the
venv rather than deleting anything.

Separately, check the units are the current ones:

```bash
grep -l '^Requires=' /etc/systemd/system/{ollama-router,ollama-monitor,open-webui}.service
```

Any output means an old unit is still installed. `Requires=` propagates a stop,
so a crash-looping `litellm-proxy` takes the router and the UI down with it —
a failure that shows up on the units that did nothing wrong. Re-apply from the
config repo and `systemctl daemon-reload`.

## Operating

```
# Status / logs (inside the container: pct enter <CT_ID>)
systemctl status open-webui ollama-router litellm-proxy ollama-monitor
journalctl -u ollama-router -f

# API base URL (external)
http://<container-ip>:8000/v1

# Chat UI — create the admin account on first visit
http://<container-ip>:8080
```

A login MOTD (`/etc/motd`) summarizes all services, IPs, ports, and config paths.

## Open items / things to verify

- **LiteLLM `fallbacks` location** — confirm against LiteLLM 1.75.5 docs; some
  versions expect `fallbacks` under `litellm_settings` rather than `router_settings`.
- **Open WebUI first boot** downloads a local embedding model for RAG (hence the
  RAM/disk bump and the 600s `TimeoutStartSec`); first start is slow.
- **Disk / CPU-only torch**: this container never has a GPU — inference runs on
  the remote Ollama hosts — so the CUDA build of torch is ~4.5 GB of wheels that
  can never be used. `TORCH_CPU_ONLY` therefore defaults to **true**: CPU-only
  torch is installed from the PyTorch CPU index *before* Open WebUI, so pip finds
  the requirement already satisfied and never pulls the CUDA stack. `apply` does
  the same on upgrades, and additionally removes any orphaned `nvidia-*`/`triton`
  wheels left by an earlier CUDA install — which is what actually reclaims the
  disk. If `download.pytorch.org` is unreachable the install warns and falls back
  to the default build rather than failing, and nothing is uninstalled.
- **Router/LiteLLM auth** — LiteLLM has no master key set (localhost-bound), so
  the API keys in the env files are placeholders. Add a master key if you expose
  ports beyond the trusted subnet.

## Version-controlled configuration

All service configuration is generated locally during provisioning and copied
into the container. If Gitea is configured, the same tree is then initialized as
a git repository and pushed as deployment history. Layout:

```
services/ollama-router/    router.py  router.ini  requirements.txt  *.service
services/litellm-proxy/    litellm_config.yaml    requirements.txt  *.service
services/ollama-monitor/   monitor.py monitor.ini requirements.txt  *.service
services/open-webui/       requirements.txt       *.service
env/router.env             shared env for router/litellm/monitor
env/openwebui.env          Open WebUI env
install/apply-config.sh    copies everything into its runtime location
```

**Flow:** the installer builds this tree locally, pushes it into the container,
and runs `apply-config.sh`. If Gitea is configured, the same generated tree is
initialized as a git repo and pushed as deployment history. Gitea is never cloned
or pulled during provisioning, so stale remote commits cannot affect a clean
install.

### Keeping models loaded (the 5-minute unload)

Ollama unloads an idle model after ~5 minutes by default (`OLLAMA_KEEP_ALIVE`).
The catch: **Ollama's OpenAI-compatible endpoint does not support a `keep_alive`
field at all** — it is absent from the documented parameter list, and passing it
is silently ignored ([ollama#11458](https://github.com/ollama/ollama/issues/11458),
[ollama#5013](https://github.com/ollama/ollama/issues/5013)). Since the router
dispatches through `/v1/chat/completions`, neither it nor Open WebUI can request
a longer keep-alive on that path. Open WebUI is not the cause and cannot fix it.

The installer therefore handles this on two fronts, driven by one setting
(`OLLAMA_KEEP_ALIVE`, prompted at install, blank by default):

1. **LiteLLM path** — `keep_alive` is emitted into each deployment's
   `litellm_params`. LiteLLM talks to Ollama's *native* API, which honours it
   (support merged in [litellm#7079](https://github.com/BerriAI/litellm/pull/7079)).
2. **Router path** — the monitor runs a **keep-alive maintainer**: every
   `KEEP_ALIVE_REFRESH_SECONDS` (default 240, just inside the 5-minute default)
   it POSTs to each healthy host's native `/api/chat` with an empty message list
   and the configured `keep_alive`, which loads the model and resets its unload
   timer without generating anything. Hosts already known to be down are
   skipped, so a dead host costs nothing.

Values: `30m`, `2h`, `-1` (never unload), `0` (unload immediately), or a bare
number of seconds. **Blank means nothing is sent**, so each server's own
`OLLAMA_KEEP_ALIVE` governs and the maintainer stays off — that is the "respect
the server setting" mode. Change it later with:

```
manage-model-servers set-keepalive 2h --apply
```

> If you have already set `OLLAMA_KEEP_ALIVE` on the Ollama hosts and still see
> 5-minute unloads, check it is actually in effect there — for a systemd install
> it needs `Environment="OLLAMA_KEEP_ALIVE=2h"` in the unit (or a drop-in),
> followed by `systemctl daemon-reload && systemctl restart ollama`.

**Changing the model server list** (no installer re-run needed):

```
manage-model-servers list                                  # servers + tier map
manage-model-servers status                                # + live reachability
manage-model-servers add 10.0.0.55 --tier large --apply
manage-model-servers remove 3 --apply
manage-model-servers set-tier large 10.0.0.54 10.0.0.55 --apply
manage-model-servers models                                # what's available where
manage-model-servers set-model large qwen3:32b --apply      # every server in the tier
manage-model-servers set-server-model large 10.0.0.54 llama3.3:70b   # just one server
manage-model-servers set-keepalive 2h --apply                # keep models resident
manage-model-servers set-webui-version                       # pinned / installed / latest
manage-model-servers set-webui-version latest --apply        # upgrade Open WebUI
```

Seeded into the repo at `install/manage-model-servers.sh` and symlinked to
`/usr/local/bin/manage-model-servers`. It runs from **either** the container or
the Proxmox host: on the host it finds the container that actually holds the
config (by testing for the file rather than guessing a name) and re-execs itself
there with the same arguments. Set `CT_ID` to skip the search. It updates `MODEL_SERVERS` and the
per-tier `BACKEND_*` values, regenerates `litellm_config.yaml` (preserving model
tags and `router_settings`), and can restart the services. New hosts are probed
before being accepted. Models are per **(tier, server)** deployment, so a tier
whose hosts have different hardware can serve a different model on each:
`set-model` sets every server in a tier (and says so when that is more than
one), while `set-server-model` changes a single one. Both verify the tag exists
on the affected server(s) before writing it — which is the easiest way to correct the inherited
`qwen3.8:27b` value. `commit` pushes using the **deploy token** from `router.env` — Gitea does not
accept an account password for git-over-HTTP, and provisioning deletes the
stored git credentials. If the token is missing, wrong, or lacks write access,
the push fails fast with the real git error (token redacted) instead of hanging
on a password prompt. Store or replace it with `manage-model-servers set-token`,
which verifies it against the server.

**Changing config on a running container:**

```
cd /app/config-repo
./install/apply-config.sh
systemctl daemon-reload
systemctl restart litellm-proxy ollama-router ollama-monitor open-webui
manage-model-servers commit "Describe the change"
```

`router.ini` holds the complexity thresholds, keyword lists and tier names, so
routing behaviour changes by commit rather than by editing `router.py`. Keyword
lists are JSON arrays because exact spacing matters — `"def "` with a trailing
space must not match `default`. `monitor.ini` holds the polling interval,
timeout and health path plus the `[alerting]` thresholds that decide when a
transition is believed; environment variables still override both.

Both venvs are built from the repo's `requirements.txt` files (the router,
litellm-proxy and monitor share `/app/router/venv`, built from all three).

> **Secrets:** `env/*.env` contain the real Gitea token and Mattermost webhook,
> committed by choice. The repo is created **private**, the local config tree in
> the container is locked to root-only (`chmod -R go-rwx`), and the runtime copies
> are `0640 root:ollama-router`. Anyone who can read the repo gets those
> credentials — rotate the deploy token if the repo is ever shared.

## Files in the container

```
/app/router/.env                 # shared runtime config (secrets)
/app/router/router.py            # complexity router + OpenAI proxy
/app/router/monitor.py           # backend health monitor + Mattermost alerts
/app/router/litellm_config.yaml  # tier → backend mapping, fallbacks
/app/router/router.ini           # routing thresholds + keywords
/app/router/monitor.ini          # monitor polling + alerting tunables
/var/lib/ollama-monitor/state.json  # remembered host health (survives restarts)
/app/config-repo/                # local config tree, optional git history
/app/router/venv/                # router + litellm deps
/app/openwebui/.env              # Open WebUI config
/app/openwebui/venv/             # Open WebUI deps (isolated)
/app/openwebui/data/             # Open WebUI data (DATA_DIR)
/opt/python/                     # standalone CPython 3.12 (if uv-provisioned)
/etc/systemd/system/*.service    # the four units
/etc/motd                        # login summary
```
