# Ollama Smart Router — Setup & Operations

A Proxmox LXC that fronts a small Ollama cluster with complexity-based model
routing, load balancing, a chat UI, and health alerting. Provisioned by
`ollama-smart-router-install.sh` (run as root on the Proxmox host).

## What gets deployed

An unprivileged Debian 13 container running four systemd services, all as the
hardened `ollama-router` user:

| Service | Unit | Port | Notes |
|---|---|---|---|
| Open WebUI (chat UI) | `open-webui.service` | 8080 | Points at the smart router |
| Smart Router (OpenAI API) | `ollama-router.service` | 8000 | Complexity routing + proxy |
| LiteLLM proxy | `litellm-proxy.service` | 4000 | Localhost only; load balances backends |
| Health monitor | `ollama-monitor.service` | — | Probes backends, alerts to Mattermost |

Request path: **Open WebUI → Smart Router (8000) → LiteLLM (4000) → Ollama backends (11434)**.

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
  prompt is worded. Explicitly naming an embedding-only model on
  `/v1/chat/completions` returns **400** with code `embedding_model_not_chat`
  instead of silently answering with a different model.
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
with a tier alias pinning the size class. A name the inventory knows only as
an embedding model is rejected with a 400 that points at `/v1/embeddings`; a
name it does not know at all is still routed as `auto`.

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
- `GITEA_SERVER_URL` (`https://git.bancs.net`), `GITEA_ADMIN_USER`, `GITEA_REPO_NAME` (`ollama-smart-router`), `GITEA_REPO_OWNER` (auto), `GITEA_REPO_PRIVATE`, `GITEA_VERIFY_TLS` (false)
- `MATTERMOST_WEBHOOK_URL`, `MATTERMOST_MONITOR_USER`, `MATTERMOST_CHANNEL` (`ollama-monitor`)
- `FIREWALL`, `API_ALLOW_CIDR` — if the CT firewall is on, set the allow-CIDR or ports 8000/8080 may be dropped
- `OPENWEBUI_PORT` (8080)

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
5. **Mattermost** — incoming webhook URL (blank disables alerting), plus channel
   and posting username when a webhook is given.
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
mid-install. `apply` then notices the pin no longer matches what is installed,
upgrades the venv, and restarts the service. Expect the install step to take a
while — it is a large dependency tree.

## Provisioning-time checks

- **Gitea:** `test_gitea_access` authenticates with the deploy token, creates
  the service repo if missing, and pushes a timestamped test commit under
  `provisioning-tests/`. Non-fatal — warns and continues on failure.

  **Which repository:** the installer always uses `GITEA_REPO_NAME`, default
  **`ollama-smart-router`** — every API call and the clone URL are built from
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
  `https://git.bancs.net` with no port.

  TurnKey ships a **self-signed certificate**, so `prompt_gitea_credentials`
  sets `GITEA_VERIFY_TLS=false` unconditionally — certificate verification is
  off for the credential check, repo resolution, seeding API calls and the
  container's `git clone` alike. The trade-off is that the deploy token travels
  over a connection whose certificate isn't authenticated; if that network path
  isn't trusted, install the appliance's CA (or a real certificate) and change
  that line in `prompt_gitea_credentials` to `true`. Use an `https://` URL:
  curl drops the auth token when a redirect changes scheme, so an `http://`
  URL follows the appliance's 80→443 redirect and then 401s. The test emits a
  specific diagnostic for each of these cases (DNS, connect-refused, TLS, 401).
- **Mattermost:** on startup the monitor posts a green-check confirmation to
  `#ollama-monitor` naming everything it watches, and logs a clear error
  (visible in `journalctl -u ollama-monitor`) if the webhook is rejected. It
  watches every Ollama host in `MODEL_SERVERS` (one alert per host, naming its
  tiers) plus LiteLLM, the router and Open WebUI. It probes in parallel, and a
  state change is reported only after `fail_threshold` / `recover_threshold`
  consecutive checks (`monitor.ini [alerting]`, default 3 / 2). An alert that
  fails to deliver is retried every cycle. Keep-alive pinning runs in its own
  thread, so a slow model load never delays health checks.
- **Container:** readiness is polled (systemd + DNS) before apt runs, apt is
  retried, and an `ERR` trap destroys a half-provisioned container on failure.

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

All service configuration lives in the Gitea repo and is injected during
provisioning. Layout — one directory per service, so each is version controlled
independently:

```
services/ollama-router/    router.py  router.ini  requirements.txt  *.service
services/litellm-proxy/    litellm_config.yaml    requirements.txt  *.service
services/ollama-monitor/   monitor.py monitor.ini requirements.txt  *.service
services/open-webui/       requirements.txt       *.service
env/router.env             shared env for router/litellm/monitor
env/openwebui.env          Open WebUI env
install/apply-config.sh    copies everything into its runtime location
```

**Flow:** the installer builds this tree, seeds it into the repo (only files the
repo doesn't already have, so your commits always win), installs git in the
container, clones, and runs `apply-config.sh`. The pull happens **once, at
provisioning time** — services never contact Gitea to start, so a Gitea outage
can't block a boot.

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
manage-model-servers set-api-key --apply                     # generate + require a router API key
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
`qwen3.8:27b` value. `commit` pushes using the **deploy token** from `/app/router/secrets.env` — Gitea does not
accept an account password for git-over-HTTP, and provisioning deletes the
stored git credentials once the clone is done. If the token is missing, wrong,
or lacks write access, the push fails fast with the real git error (token
redacted) instead of hanging on a password prompt. Store or replace it with
`manage-model-servers set-token`, which verifies it against the server.

Both model commands accept third-party names with a namespace, such as
`smtek/Qwen3.8-27B:Q3_K_XL-16gb`. Pass the full Ollama model name, without the
LiteLLM `ollama/` provider prefix; the tool adds that prefix to the generated config:

```bash
manage-model-servers set-server-model medium 192.168.11.14 smtek/Qwen3.8-27B:Q3_K_XL-16gb --apply
manage-model-servers set-model medium smtek/Qwen3.8-27B:Q3_K_XL-16gb --apply
```

**Changing config on a running container:**

```
cd /app/config-repo && git pull
manage-model-servers apply    # validate, copy, repair venvs, restart what changed
manage-model-servers apply --all   # same, but restart every service
```

`router.ini` holds the complexity thresholds, keyword lists and tier names, so
routing behaviour changes by commit rather than by editing `router.py`. Keyword
lists are JSON arrays because exact spacing matters — `"def "` with a trailing
space must not match `default`. `monitor.ini` holds polling interval, timeout
and health path; environment variables still override both.

The router and monitor share `/app/router/venv`. LiteLLM has its own
`/app/litellm/venv`: `litellm --config` needs the `litellm[proxy]` extra, which
pins fastapi/uvicorn versions that conflict with the router's. It is installed
from `services/litellm-proxy/requirements.lock` with `pip --require-hashes`
when that file is present. `manage-model-servers apply` builds or repairs this
venv automatically on older containers.

> **Secrets:** the Gitea deploy token and the Mattermost webhook URL are **not**
> kept in the repo. They live in `/app/router/secrets.env` inside the container
> (`0640 root:ollama-router`), which the monitor loads as a second
> `EnvironmentFile=`. Set them with `manage-model-servers set-token` and
> `set-webhook`. The router API key (`ROUTER_API_KEY`, and the same value as
> Open WebUI's `OPENAI_API_KEYS`) lives there too; see `set-api-key`.
> `commit` and `apply` move any secret still found in
> `env/router.env` into that file before doing anything else. Older commits
> still contain the token: rotate it in Gitea.

## Files in the container

```
/app/router/.env                 # shared runtime config (no secrets)
/app/router/secrets.env          # deploy token + webhook URL (0640, not in git)
/app/router/router.py            # complexity router + OpenAI proxy
/app/router/monitor.py           # backend health monitor + Mattermost alerts
/app/router/litellm_config.yaml  # tier → backend mapping, fallbacks
/app/router/router.ini           # routing thresholds + keywords
/app/router/monitor.ini          # monitor polling tunables
/app/config-repo/                # cloned config repo (root-only)
/app/router/venv/                # router + monitor deps
/app/litellm/venv/               # litellm[proxy] (isolated, hash-locked)
/app/openwebui/.env              # Open WebUI config
/app/openwebui/venv/             # Open WebUI deps (isolated)
/app/openwebui/data/             # Open WebUI data (DATA_DIR)
/opt/python/                     # standalone CPython 3.12 (if uv-provisioned)
/etc/systemd/system/*.service    # the four units
/etc/motd                        # login summary
```

## Editing service code

The files under `services/` and `install/` are the source of truth. The
installer embeds copies of them so it can run as a single file; after editing,
run `tools/sync-embedded.py --write` to refresh those copies (`tests/test-repo.sh`
fails on any drift). On re-install, installer-owned code in the Gitea repo is
updated when it differs (`CONFIG_UPDATE_CODE=true`, the default); `router.ini`,
`monitor.ini`, `env/*.env` and `litellm_config.yaml` remain seed-if-missing.

## Router API

- **Authentication.** When `ROUTER_API_KEY` is set, every endpoint except
  `/healthz` requires `Authorization: Bearer <key>`. New installs generate a
  key. On an existing install, run `manage-model-servers set-api-key --apply`,
  then paste the printed key into Open WebUI under **Admin Settings >
  Connections > OpenAI**, because Open WebUI only reads `OPENAI_API_KEYS` on
  its first start. The router never forwards the key to an Ollama host.
  `ROUTER_HOST` and `ROUTER_PORT` set the listen address (default
  `0.0.0.0:8000`); the router logs a warning at startup if it listens beyond
  loopback without a key.
- **Classification.** Keywords match whole words, so "description" no longer
  counts as `script` and "improve" no longer counts as `prove`. Only the newest
  user message is judged (`router.ini [classification] scope`).
- **Failover.** Backends get 3 s to accept a connection
  (`[http] connect_timeout_seconds`). A host that refuses or times out is taken
  out of rotation at once and returns on the next successful discovery poll. A
  404 or 5xx falls forward to the next candidate.
- **Capabilities.** Discovery asks each Ollama host's `/api/show` which
  capabilities a model has, and caches the answer per model digest. A model
  reporting `vision` counts as vision-capable whatever its name (gemma3,
  mistral-small3.1, qwen2.5vl), and an embedding-only model is never offered
  for chat. Name matching is only the fallback. Turn the probe off with
  `[discovery] capability_probe = false`.
- **Images.** A request with an image but no vision-looking model is routed
  anyway, flagged with `X-Router-Warning: no-vision-model`. Set
  `vision_strict = true` to reject it with a 400 instead.

## Applying changes safely

`manage-model-servers apply` (and every `--apply`) now works in this order:

1. **Validate** the repo before touching anything:
   - `litellm_config.yaml` parses, every deployment has a model and an
     `api_base`, and fallbacks only name tiers that exist;
   - the router and monitor ini files parse, and the keyword lists are JSON;
   - the env files are `KEY=value` lines;
   - `router.py` and `monitor.py` compile.

   On any problem, nothing is applied.
2. **Snapshot** the installed files to `/var/backups/ollama-smart-router/`
   (root-only; the last 5 are kept).
3. **Apply**, then restart **only the services affected**: files that
   changed, a changed `secrets.env`, a rebuilt venv, or a unit that is not
   running.
4. **Health-check** each restarted service. The router is checked on
   `/healthz`, LiteLLM on `/health/liveliness` and Open WebUI on `/health`;
   the monitor must stay active. On failure the snapshot is restored and the
   services are restarted on the old files. Rebuilt venvs are not rolled
   back.

Whenever the LiteLLM config is regenerated, its `fallbacks` are rebuilt from
the tiers that exist. A tier never falls back to a tier with identical
deployments (same model on the same host). Other `router_settings` keys and
later sections are kept.

## Inference targets

Besides existing Ollama and LM Studio hosts, the router can use three kinds of
inference targets built from this repository, each in its own CT and each
speaking the Ollama API on TCP 11434:

- `targets/ollama/`: a plain Ollama server. The CT and Ollama come from the
  Proxmox community script (`ct/ollama.sh`); `install-target.sh` then runs it
  unprivileged and hardened, with pinned upgrades.
- `targets/llamacpp/`: a llama.cpp server behind an Ollama bridge (GGUF models).
- `targets/airllm/`: AirLLM, which streams a model far larger than RAM or VRAM
  from disk one layer at a time. Slow (seconds to minutes per token); give it
  its own tier.

Each has `provision-lxc.sh` for the PVE host, `install-target.sh` (with
`--upgrade`) for inside the CT, and a README with the details.

## Continuous integration

`.gitea/workflows/tests.yml` runs `tests/run-tests.sh` (every shell and
pytest suite), shellcheck and ruff on each push. It builds separate venvs for
the router/monitor and the llama.cpp bridge, because they pin different
fastapi versions (`ROUTER_PYTHON` / `BRIDGE_PYTHON`); the AirLLM target's tests
reuse the bridge venv. Enable Actions on the
repository and register an `act_runner` to use it.

## Updating the router components

To update a running router container to newer code (router, monitor, units,
requirements, management tools) without re-running the installer, copy the
updated repository into the container and run `install/update-router.sh`
there. From the PVE host:

```bash
tar -C ~/gitea-ollama-smart-router --exclude=.git -czf - . |
  pct exec <CT> -- sh -c 'rm -rf /root/osr-src && mkdir /root/osr-src && tar -C /root/osr-src -xzf -'
pct exec <CT> -- bash /root/osr-src/install/update-router.sh --dry-run --diff   # review
pct exec <CT> -- bash /root/osr-src/install/update-router.sh
```

It commits the changed component files into `/app/config-repo`, reinstalls the
router venv if its requirements changed, applies with
`manage-model-servers apply` (health checks and rollback), then pushes to
Gitea. Your servers, tiers, `env/*.env`, `litellm_config.yaml` and secrets are
never touched; `router.ini` / `monitor.ini` are replaced only with
`--with-tunables`. If the apply fails, the commit is undone and the previous
venv packages are restored. `--no-apply` and `--no-push` stop after the commit
or the apply. Commit any pending `manage-model-servers` edits first; the
script refuses a config repo with uncommitted changes. A failed push exits
non-zero but keeps the applied update and its local commit.

### The config lock

`update-router.sh` and every `manage-model-servers` command that writes
(`add`, `remove`, `set-*`, `apply`, `commit`) take one lock,
`/run/lock/ollama-smart-router-config.lock`, so two changes never overlap.
Read-only commands (`list`, `status`, `models`, `discover`, `test-alert`)
never wait on it. A second change fails at once; set `CONFIG_LOCK_WAIT=<seconds>`
to wait instead.

The lock is held by a running process and disappears with it, so a crash or
reboot never leaves it in force (the file that stays behind is only a
placeholder). If a change is **hung**, see who holds it and stop it:

```bash
manage-model-servers clear-lock            # shows the holder; changes nothing
manage-model-servers clear-lock --force    # SIGTERM, then SIGKILL after LOCK_KILL_WAIT (10) s
```

Stopping a change midway can leave the config repo or services half-updated:
check `git -C /app/config-repo status` and run `manage-model-servers apply`
afterwards.

## Maintenance notes

- **Open WebUI upgrades** (`set-webui-version <v> --apply`) copy `webui.db` into
  the apply snapshot first. If the upgraded UI does not come up healthy, the
  previous version is reinstalled and the pre-migration database is put back.
  The repo's pin, not the installer default, decides the version; a fresh
  install seeds the installer default.
- **Service sandboxing:** every unit runs with `ProtectSystem=strict` and
  related settings; see ARCHITECTURE.md §3.
- **Startup notice:** the monitor posts its "online" message at most once per
  hour (`monitor.ini [startup] notice_interval_seconds`), so a restart loop
  cannot flood the channel.
- **LiteLLM retries:** `router_settings` carries `num_retries: 2` and
  `timeout: 600`. `apply` prints a note when two tiers are identical (same
  model on the same host), because one of them then adds nothing.
- **Code keywords** can be regular expressions (`"re:..."` in `router.ini`). The
  defaults match code *shapes* (`class Foo:`, `import x`, `def f(`), so prose
  such as "first class ticket" is not treated as code.
- **Management tool:** `install/manage-model-servers.sh` is the only copy.
  The repo-root `manage-model-servers.sh` is a thin wrapper that runs it.
- **Gitea access test:** the installer's test commit
  (`provisioning-tests/<timestamp>.md`) is now deleted again right after it
  succeeds. Remove markers left by older runs with
  `git rm -r provisioning-tests`.

## LM Studio servers

An [LM Studio](https://lmstudio.ai/docs/developer) server can sit next to Ollama
hosts in the same pool. It is stored with a scheme prefix,
`lmstudio+http://host:1234`, in `MODEL_SERVERS` and `BACKEND_*`, so every
component knows which API to speak.

```bash
manage-model-servers add 10.0.0.9 --tier fast        # auto-detected (tries :11434, then :1234)
manage-model-servers add lmstudio://10.0.0.9:1234    # explicit
manage-model-servers add 10.0.0.9 --type lmstudio --no-probe
manage-model-servers set-server-model fast 10.0.0.9:1234 qwen/qwen3-8b --apply
manage-model-servers set-lmstudio-token               # only if LM Studio requires authentication
```

| Component | Ollama host | LM Studio server |
|---|---|---|
| Router discovery | `/api/tags` + `/api/show` capabilities | `/api/v1/models` (LM Studio 0.4+), else `/api/v0/models`, else `/v1/models`. Vision/embedding, parameter size and **loaded state** come from LM Studio. |
| Router dispatch | `/v1/chat/completions` | `/v1/chat/completions` (+ `LMSTUDIO_API_TOKEN`) |
| Router scoring | — | `loaded_bonus` prefers resident models; `lmstudio_loaded_only = true` never triggers a just-in-time load |
| LiteLLM | `ollama/<model>`, `api_base` = host | `lm_studio/<model>`, `api_base` = host`/v1`, `api_key: os.environ/LMSTUDIO_API_TOKEN` when a token is set |
| Monitor | `/api/tags` | `/v1/models` (a rejected token counts as down) |
| Keep-alive | pinned by the monitor | not applicable: set LM Studio's own idle TTL |

Model names differ between the two (`qwen3:14b` vs `qwen/qwen3-14b`). When
an LM Studio server joins a tier whose model it lacks, `add` says so; pick
one of its models with `set-server-model`.
