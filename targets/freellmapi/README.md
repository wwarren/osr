# FreeLLMAPI gateway

[FreeLLMAPI](https://github.com/tashfeenahmed/freellmapi) puts the free tiers
of many cloud model providers (Google, Groq, OpenRouter, Cerebras, Mistral and
others) behind one OpenAI-compatible endpoint and one key, and moves on to the
next provider when one hits its limit. This target runs it in its own CT and
offers its models through the router as `freellmapi/<id>`.

**Prompts sent to these models leave your network** for whichever provider
answers, under that provider's terms. OSR therefore treats FreeLLMAPI like its
[cloud API models](../../CLOUD_MODELS.md#cloud-api-models): a model is used only when
a request names it. `auto`, the tier aliases and LiteLLM's fallbacks never pick
one, and FreeLLMAPI is not part of the model pool.

| | |
|---|---|
| Release | `v0.16.31` (`DEFAULT_FREELLMAPI_VERSION`), commit in `upstream-commit.txt` |
| Image | `ghcr.io/tashfeenahmed/freellmapi`, pulled by digest |
| CT | Unprivileged, made from the image by Proxmox (no Docker or Podman inside), 2 cores, 1 GiB, 4 GiB root + 2 GiB data |
| Port | 3001: dashboard and API (`/v1/...`) |
| Tags | `ai`, `ai-model`, `osr-target`, `freellmapi` |
| Router | `freellmapi/<id>` models, explicit only; `freellmapi/auto` lets FreeLLMAPI choose |

## How the CT is made

FreeLLMAPI is published only as a container image. Proxmox VE 9.1 can make an
LXC from such an image itself (an "application container", a technology
preview in 9.1), so there is no container runtime in the CT and no guest
installer in this directory. `provision-lxc.sh` does the whole job:

1. `skopeo inspect` reads the release's digest and the commit it was built
   from (the image's `org.opencontainers.image.revision` label). For the tested
   release that must be the commit in `upstream-commit.txt`; with
   `FREELLMAPI_DIGEST` the digest must match too. A moved tag is refused before
   anything changes.
2. `skopeo copy` stores the image, by digest, as the CT template
   `<TEMPLATE_STORAGE>:vztmpl/freellmapi_<release>.tar`.
3. `pct create` makes the CT from it, with a second volume (`mp0`, backed up)
   at the image's data directory `/app/server/data`. Proxmox takes the image's
   entrypoint (`docker-entrypoint.sh node server/dist/index.js`) as the CT's
   init and manages its network.
4. The CT is started once with an entrypoint that only waits, and the data
   directory is prepared: `osr-target/freellmapi.env` (root:node 0640) with a
   new 64-hex-digit `ENCRYPTION_KEY`, the port and the rate limit, linked from
   `/app/.env`; and the first dashboard account (a bootstrap file FreeLLMAPI
   reads at its first start, removed once the account exists).
5. The image's entrypoint is put back and the CT restarted. The run waits for
   `/api/ping`, checks the account exists, reads the unified API key from the
   database and checks it opens `/v1/models`.
6. The endpoint and key go to the router CT: `manage-model-servers
   set-freellmapi http://<CT>:3001 --apply`, the key on stdin.

The CT's firewall admits the access range (default: the CT's network; from the
installer, its `API_ALLOW_CIDR`) and the router to port 3001, and nothing else.
Outbound traffic stays open: FreeLLMAPI calls whichever providers have keys.

## Before you start

- Proxmox VE 9.1 or later, and `skopeo` on the host (`apt install skopeo`;
  Proxmox uses it to pull images). The host must reach `ghcr.io`.
- A static address for the CT and a storage for CT templates (`local` by
  default).
- Provider API keys: sign up at the providers you want (most free tiers need
  only an account). Without at least one key, no model answers.

## Provision on the Proxmox host

From the installer, choose `freellmapi` (the last entry). It asks for the CT
ID, address, storage and the dashboard's sign-in name; the password is
generated in the CT.

On its own:

```bash
bash targets/freellmapi/provision-lxc.sh --dry-run   # the plan
bash targets/freellmapi/provision-lxc.sh
```

It asks for the CT ID (default: the cluster's next free one), storage,
address, gateway, the dashboard e-mail and password (Enter: generate one in the
CT), the access range and the router CT (default: the CT tagged `osr-router`;
`none` skips the hand-over). Unattended:

```bash
CT_ID=240 STORAGE=local-lvm IP_CIDR=192.0.2.40/24 GATEWAY=192.0.2.1 \
  ROUTER_CT_ID=210 PVE_ACCEPT_DEFAULTS=true PVE_CONFIRM=false \
  bash targets/freellmapi/provision-lxc.sh
```

| Setting | Default | Meaning |
|---|---|---|
| `FREELLMAPI_VERSION` | the tested release | Release tag to run; a CT given one stays on it until another is named. With `--reconfigure`, `keep` stays on the CT's release |
| `FREELLMAPI_DIGEST` | empty | Registry digest the tag must have (`skopeo inspect --format '{{.Digest}}' docker://ghcr.io/tashfeenahmed/freellmapi:<tag>`) |
| `FREELLMAPI_PORT` | 3001 | Dashboard and API port |
| `FREELLMAPI_ACCESS_CIDR` | the CT's network | Who may open the dashboard and API (the router is always admitted) |
| `FREELLMAPI_RATE_LIMIT_RPM` | 600 | Requests per minute per client address; the router is one client. `0` turns it off |
| `FREELLMAPI_ADMIN_EMAIL` | `admin@osr.local` | Dashboard sign-in name |
| `FREELLMAPI_ADMIN_PASSWORD` | generated | 8 to 128 characters; taken out of the environment at once, passed to the CT on stdin |
| `TEMPLATE_STORAGE` | `local` | Storage for the image template |
| `CORES`, `MEMORY_MB`, `SWAP_MB`, `ROOTFS_GB`, `DATA_GB` | 2, 1024, 0, 4, 2 | CT size |
| `CT_HOSTNAME`, `BRIDGE`, `VLAN_TAG`, `NAMESERVER`, `ONBOOT` | `freellmapi`, `vmbr0`, –, –, 1 | CT network and start |
| `ROUTER_CT_ID` | the `osr-router` CT | Router to register with, or `none` |
| `FREELLMAPI_READY_TIMEOUT` | 120 | Seconds to wait for `/api/ping` |

A generated password is kept root-only in the CT:

```bash
pct exec <CT> -- cat /app/server/data/osr-target/initial-admin-password
```

Change it in the dashboard, then delete that file.

## Add provider keys

Open `http://<CT address>:3001`, sign in, and add keys on the **Keys** page.
The dashboard also shows the fallback order, usage per provider and the
**unified API key** the router uses. If you regenerate that key, hand the new
one to the router:

```bash
CT_ID=<CT> bash targets/freellmapi/provision-lxc.sh --register
```

## Using it through the router

The router lists `freellmapi/auto` and, by default, every model FreeLLMAPI can
serve now (`freellmapi/<its model id>`), refreshed every five minutes. Open
WebUI and agents see them in `/v1/models`. A request naming one is sent to
FreeLLMAPI with the router's key in place of the client's, the prefix removed;
the response carries `X-Router-Mode: freellmapi`.

```bash
curl http://<router>:8000/v1/chat/completions -H "Authorization: Bearer $ROUTER_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model": "freellmapi/auto", "messages": [{"role": "user", "content": "hi"}]}'
```

On the router:

```bash
manage-model-servers set-freellmapi http://192.0.2.40:3001 --apply   # asks for the key twice
manage-model-servers set-freellmapi --off --apply
```

`FREELLMAPI_BASE_URL` (in `env/router.env`, committed) holds the address and
`FREELLMAPI_API_KEY` (in `secrets.env`) the key. `FREELLMAPI_MODELS=auto` in
`env/router.env` lists only FreeLLMAPI's own routing entries instead of every
model. The health monitor watches `/api/ping` and alerts when FreeLLMAPI stops
answering.

To keep Open WebUI users from reaching these models, restrict them in Open
WebUI's model settings (Admin Panel → Settings → Models).

## Upgrades

```bash
CT_ID=<CT> bash targets/freellmapi/provision-lxc.sh --reconfigure            # follow the tested release
CT_ID=<CT> FREELLMAPI_VERSION=v0.17.0 bash targets/freellmapi/provision-lxc.sh --reconfigure
```

- Nothing changed and the server answers: nothing to do.
- Settings changed (port, access range, router, rate limit): the same image restarts
  with the env file rewritten. The CT startup overrides the image's `PORT`
  value, the FreeLLMAPI firewall rules follow the selected port and access
  range, and a port change updates the router endpoint. Operator-added env
  lines and firewall rules are kept. A failed restart restores the prior env
  file, settings record, firewall and startup command.
- Another release: the new image is pulled and checked first. Then the CT is
  stopped and backed up with `vzdump` to `/var/lib/osr-freellmapi/<CT>/`, its
  data directory saved, and the CT destroyed and created again from the new
  image, with the same ID, address, MAC, firewall settings, cores, memory, swap,
  start order and DNS, and the data restored. The run succeeds only when
  `/api/ping` answers and the unified key is unchanged and works. Otherwise
  the new CT is removed and the backup restored (`pct restore`), started and
  checked. The backup is then kept in `/var/lib/osr-freellmapi/<CT>.rolled-back-<time>/`
  (delete it once the CT is fine); it does not block later runs. A rollback never
  destroys a CT unless its backup file is there. A failed restore keeps the backup
  and says how to restore it by hand.

Options set on the CT by hand beyond those listed are not carried over to the
new CT (the backup has them). `tools/upgrade-all.sh` runs `--reconfigure`,
offers the newest GitHub release beside the pin. When it keeps the CT's
release (same pin, `--keep-pins`, or a release newer than the pin) it passes
`FREELLMAPI_VERSION=keep`: the CT stays on its release, still following the
tested one if it did, and is snapshotted when snapshots are enabled. A release
replacement uses the provisioner's backup because replacing the CT removes its
snapshots.
Templates of earlier releases stay in `TEMPLATE_STORAGE` until you delete them.

**A CT on another cluster node.** `tools/upgrade-all.sh` runs this provisioner
on one node with `tools/pct-cluster.sh` as `pct`, so the CT may be on another
node. Proxmox's `vzdump` backs up only the guests of the node it runs on and
succeeds without a backup for any other one ("skip external VMs"), and a
`pct create` or `pct restore` of a CT that does not exist at that moment
acts on the node it runs on. So for a replacement the provisioner asks the
wrapper which node holds the CT (`pct --osr-node`). It then copies the
template to that node's `TEMPLATE_STORAGE` unless the node already has the
same file. `vzdump --stdout` runs there, compressed there with `zstd`, and the
archive streams into `/var/lib/osr-freellmapi/<CT>/` on the provisioner's node. The new
CT is created on the CT's node, and a rollback restores there from a copy of
that backup streamed to `/var/tmp` (removed afterwards). A successful upgrade
removes the backup; after a failed upgrade, it stays on the node running the
provisioner for inspection. Run directly with Proxmox's own `pct`, the CT is
always on this node.

## Troubleshooting

- **The CT stops right after starting.** The server is the CT's init: when it
  exits, the CT stops. `pct console <CT>` (or `pct start <CT> --debug`) shows
  its output. The usual cause is an env file without a valid
  `ENCRYPTION_KEY`.
- **"runs 'sleep infinity', not the image's entrypoint".** A run was
  interrupted while the data directory was being prepared. Put the entrypoint
  back and start it:
  `pct set <CT> --entrypoint '/usr/bin/env PORT=3001 /usr/local/bin/docker-entrypoint.sh node server/dist/index.js'; pct start <CT>`
  (replace `3001` with the port in `/app/server/data/osr-target/settings`).
- **"has no [RULES] section".** The run rewrites FreeLLMAPI's rules in the
  CT's firewall file and stops before touching the CT when it cannot. Put the
  `[RULES]` line back in `/etc/pve/firewall/<CT>.fw` (or restore the file).
- **"vzdump left no backup".** Before this was handled, a replacement run from
  another node of the cluster stopped here, with "skip external VMs" in the
  vzdump output. The CT was started again unchanged; run it again with this
  version.
- **"an earlier replacement ... did not finish".** `/var/lib/osr-freellmapi/<CT>/`
  on the node that ran the provisioner holds the backup of the CT as it was
  before. If the CT works, delete the directory. Otherwise, keep the archive
  until the old CT is running again. Restore with `umask 022`: `pct restore`
  creates the CT's root directory with the caller's umask, and an unprivileged
  CT cannot use one made under 077. For a CT on this node, stop and destroy
  any partial CT, then:

  ```sh
  (umask 022; pct restore <CT> <archive> --storage <storage>) && pct start <CT>
  ```

  For a CT on another node, run the following as root from the repository
  checkout on the provisioner's node. Set `CT`, `NODE`, `STORAGE` and `BACKUP`
  to the original CT ID and node, its root disk storage, and the archive in
  the directory above. The archive is copied to `NODE` under its own name,
  any partial CT there is stopped and destroyed, and the restore runs
  explicitly on `NODE`: after `pct destroy`, the ordinary cluster wrapper no
  longer knows which node held the CT and would restore it on this one.

  ```sh
  CT=280
  NODE=pve2
  STORAGE=local-lvm
  BACKUP=/var/lib/osr-freellmapi/280/vzdump-lxc-280-YYYY_MM_DD-HH_MM_SS.tar.zst
  COPY=/var/tmp/$(basename "$BACKUP")
  on_node() { bash tools/pct-cluster.sh --osr-on-node "$NODE" "$@"; }
  on_node sh -c 'umask 077; cat > "$1"' sh "$COPY" < "$BACKUP"
  if on_node pct status "$CT" >/dev/null 2>&1; then
      on_node pct stop "$CT" 2>/dev/null
      on_node pct destroy "$CT"
  fi
  on_node sh -c 'umask 022; exec pct restore "$@"' sh "$CT" "$COPY" --storage "$STORAGE"
  on_node pct start "$CT"
  ```

  Once the restored CT is healthy, remove the copy on `NODE`
  (`on_node rm -f -- "$COPY"`). Keep the original archive on the provisioner's
  node until recovery is confirmed.

- **Every model fails.** No provider key, or all are rate-limited: see the
  dashboard's Keys and Analytics pages.
- **The key is lost.** It is in the database, encrypted with `ENCRYPTION_KEY`.
  Losing `freellmapi.env` loses the provider keys; the CT's backups (`mp0` is
  included) have both.

## Verified, and not yet

- `test-provision.sh`: plans and validation, then whole runs against a fake
  Proxmox (`fake-pve.sh`) that keeps each CT as a directory and runs the
  provisioner's own guest scripts in it: create, register, settings change,
  replacement for a new release, every rollback path, and the password and key
  kept off command lines.
- `test-pinned-upstream.py` (CI job `freellmapi-upstream`): the pinned commit's
  Dockerfile, entrypoint, settings, endpoints and image workflow, then the
  provisioner's guest scripts against the real, built server (account from the
  bootstrap file, health, reading and using the key, restart).
- The router's `freellmapi/` path was run against that real server.
- **Not run on Proxmox.** Watch the first real run: `pct create` from the OCI
  archive (entrypoint and Debian detection), `pct exec` into an application
  container, `skopeo` reaching ghcr.io from the host, and a replacement with
  `vzdump`/`pct restore`. Proxmox marks OCI-image CTs a technology preview in
  9.1; its behaviour may change in later releases.
