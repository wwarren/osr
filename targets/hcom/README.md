# hcom tool target

Adds [hcom](https://github.com/aannoo/hcom) to existing OSR Hermes, OpenClaw and
DeepSeek Harness CTs, plus one optional Mattermost observer. These standalone
tool targets are installed after the agents, create no CT and do not change
model routing. The installer pins **hcom 0.7.31** (upstream commit
`de33e31a0cdbba4c5863f7cc050d8b79aa50bcdf`) and verifies the Linux x86_64 or
aarch64 musl archive against its recorded SHA-256; no Rust toolchain is needed.
Update the version and both hashes together, after a live test.

## Deploy

Provision [the MQTT target](../mqtt/README.md) first. Then, from a full
checkout on the Proxmox host, as root, run the provisioner in a terminal. It
asks for each setting not already set, offering CTs by their tags, shows the
plan and asks to confirm:

```bash
bash tools/install-hcom.sh                  # add hcom to an agent CT, or an observer
bash tools/install-hcom.sh --reconfigure    # a CT that has hcom: its recorded settings are the defaults
bash tools/install-hcom.sh --help           # every setting and option
```

| Setting | When | Meaning (offered default) |
|---|---|---|
| `HCOM_TARGET` | always | `hermes`, `openclaw` or `deepseek-harness` (the agent the CT runs), or `observer` (no agent; posts handoffs to Mattermost). A reconfigure offers the recorded one. |
| `CT_ID` | always | The existing CT to add hcom to (the CT tagged with the target; observer: the broker CT). A reconfigure asks for it first. |
| `MQTT_CT_ID` | always | The broker CT from `targets/mqtt` (the CT at the recorded broker address, else the one tagged `mqtt`). |
| `MATTERMOST_CT_ID` | observer | Where the agent-handoffs webhook is created (tag `mattermost`); `none` keeps an observer's current webhook, or posts nothing. |
| `HCOM_HERMES_NATIVE` | hermes | `true` adds Hermes's native plugin, which gives Hermes the relay key (default `false`, or the recorded mode). |
| `HCOM_INSTRUCTIONS_FILE` | optional | A custom AGENTS.md for the managed block; never asked. |

Preset any of them as environment variables to skip its question. Without a
terminal nothing is asked, and the run stops listing each missing required
setting (a reconfigure can take the recorded target). For example, with your
agent and broker CT IDs:

```bash
CT_ID=282 MQTT_CT_ID=286 HCOM_TARGET=hermes           bash tools/install-hcom.sh --dry-run
CT_ID=283 MQTT_CT_ID=286 HCOM_TARGET=openclaw         bash tools/install-hcom.sh --dry-run
CT_ID=281 MQTT_CT_ID=286 HCOM_TARGET=deepseek-harness bash tools/install-hcom.sh --dry-run

# Exactly one observer per group; here on the broker CT. The Mattermost CT must
# already be configured by its OSR target.
CT_ID=286 MQTT_CT_ID=286 HCOM_TARGET=observer MATTERMOST_CT_ID=277 \
  bash tools/install-hcom.sh --dry-run
```

Remove `--dry-run` to install; rerun the same command (or add
`--reconfigure`) to reconfigure. Credentials move through private `pct
pull`/`pct push` files, never printed or passed as arguments, and temporary
copies are removed. The CT needs Python 3.11+ (Debian 12/13, Ubuntu 24.04+),
including an existing CT used as observer.

**Firewall.** Hermes and OpenClaw default to `EGRESS=restricted` (private
addresses dropped). When a CT's firewall has `policy_out: DROP`, the
provisioner adds owned rules before the first outbound DROP, with the port
taken from the broker URL (and, for an observer, the webhook URL):

```
OUT ACCEPT -dest <broker-ip>/32 -p tcp -dport 1883 -log nolog # osr-hcom-relay
OUT ACCEPT -dest <mattermost-ip>/32 -p tcp -dport 443 -log nolog # osr-hcom-mattermost
```

The agents' provisioners keep these lines on reconfigure. A broker given by
name is resolved on the Proxmox host, so rerun hcom if its address changes. A
failed install removes the rule it added. The broker must admit the CT
(`MQTT_CLIENT_CIDR`).

**Without Proxmox**, copy the broker's relay bundle privately and run in the
agent guest as root (allow outbound TCP to the broker yourself):

```bash
HCOM_TARGET=openclaw HCOM_RELAY_BUNDLE=/root/relay.json bash targets/hcom/install-target.sh --dry-run
```

An observer also needs `HCOM_MATTERMOST_WEBHOOK_FILE`, a private file with the
dedicated handoff webhook from the [Mattermost helper](#mattermost); supplying
the correct, separate webhook is then up to you.

## Security model

Every CT in a relay group holds the group's broker password and encryption
key, and any key holder can send remote requests that peers' relay workers
execute: changing hcom settings (e.g. `hints`, text added to every message),
reading transcripts and events, ending sessions, launching tools. So the key is
kept from the agents:

| | Default | `HCOM_HERMES_NATIVE=true` (Hermes only) |
|---|---|---|
| Relay account (owns state and key, runs the worker) | `osr-hcom` | `hermes` |
| hcom state (`HCOM_DIR`, 0700) | `/var/lib/osr-hcom/.osr-hcom` | `/home/hermes/.osr-hcom` |
| Agent reaches the bus through | `/run/osr-hcom/bus.sock` only | The socket, and hcom directly |
| Agent can read the key / send remote requests | No | Yes |

`osr-hcom-bus.socket` admits root and the CT's agent (socket group plus a
peer-credential check); each connection runs `osr-hcom-bus@.service` as the
relay account. It accepts four requests: send a handoff (up to 2,000
characters, to `hermes`, `openclaw`, `deepseek-harness` or `all`), read the
inbox, follow, or show status. It stamps the sender as `osr-<target>` and runs
no shell. Agents never start hcom, so they never start a stray relay worker;
the relay unit also stops one before starting (relevant in native mode). Root
on any group member can still act on the whole group: use one group per
trusted set of CTs.

| Target | Agent account | Managed instruction file |
|---|---|---|
| Hermes | `hermes` | `/home/hermes/AGENTS.md` (Hermes's working directory) |
| OpenClaw | `openclaw` | `/home/openclaw/.openclaw/workspace/AGENTS.md` |
| DeepSeek Harness | `deepseek-harness` | `/var/lib/deepseek-harness/home/AGENTS.md` |
| Observer | — | — |

`HCOM_INSTRUCTIONS_FILE` selects a custom workspace or profile. Only the
managed `osr-hcom` block is replaced; other content (including Honcho's block)
and the file's owner and mode are kept, as are provider and Honcho settings.

**Upgrading from the first hcom release**, which kept state and key in the
agent account with an `HCOM_DIR` drop-in: a rerun moves the state (history and
device ID) to the relay account, removes the drop-in and the block in
`~/.hermes/AGENTS.md`, removes Hermes's native plugin unless
`HCOM_HERMES_NATIVE=true`, and restarts the agent once. Then rotate the group
key, since agents could read it: delete `/etc/mqtt-target/relay.json` in the
broker CT, rerun the MQTT provisioner with `--reconfigure`, then every hcom
provisioner.

## Agent integrations

Through an agent's terminal tool, or as root:

```bash
osr-bus status
osr-bus inbox --last 100
osr-bus send hermes 'Please review the installer; tests pass.'
osr-bus send all 'Handoff complete; the change is ready to review.'
osr-bus follow                  # stream new events until interrupted
osr-bus follow --after-id 42    # resume after a LOCAL event ID
osr-bus tui                     # hcom dashboard (root only)
```

The bus sends a small JSON envelope with hcom's
`send --from osr-<target> --go --intent request -- ...`, addressing stable OSR
target names without native hcom identities. The inbox shows messages for this
agent or `all` plus native messages, hiding other agents' and this CT's own
handoffs; it covers the latest 100 message events by default (`--last`
1–10000), not a durable task queue. Agents use event IDs to avoid repeating
work.

**OpenClaw and DeepSeek Harness.** hcom 0.7.31 has no native hooks for them.
Managed instructions tell their terminal tools to run `osr-bus inbox` before
substantial tasks and between major steps and to send short handoffs; messages
do not start turns, and compliance depends on the model. If OpenClaw's tool
policy denies `exec`, allow `osr-bus` there (setup changes no tool policy).

**Hermes** uses `osr-bus` by default. The native plugin
(`HCOM_HERMES_NATIVE=true`) runs hcom as `hermes`, so Hermes holds the group
key; setup runs `hcom hooks add hermes`, adds an `HCOM_DIR` drop-in to
`hermes-gateway.service` (which must exist: the Hermes provisioner's Open WebUI
option) and restarts it. A chat joins only after `/hcom start hermes`, and only
on a messaging platform (Telegram, Discord, Slack, ...): the plugin treats Open
WebUI's API-server sessions as not a chat. Joined chats receive every envelope;
the instructions tell Hermes to act only on `hermes` or `all`. Rerunning
without the flag removes the plugin and moves state back to `osr-hcom`.

## Mattermost

The observer provisioner runs
[`configure-agent-handoffs.sh`](../mattermost/configure-agent-handoffs.sh) in
the Mattermost CT: local `mmctl` keeps or creates a dedicated channel
(`HCOM_MATTERMOST_CHANNEL`, default `agent-handoffs`, in `MATTERMOST_TEAM`,
default `ollama`) and its own incoming webhook in
`/etc/mattermost-target/agent-handoffs-webhook-url`. The webhook is locked to
that channel, so a payload, even one sent with a leaked URL, cannot post
anywhere else; a rerun locks one made by an earlier release in place. It
refuses the health webhook's channel, whatever its name (a health webhook
since deleted in Mattermost is noted and skipped), and leaves the health
webhook and `ollama-monitor` untouched. Incoming webhooks must already be enabled (the
Mattermost target does this). For a non-Proxmox observer, run it in the
Mattermost CT (`--dry-run` first) and transfer the webhook file privately.

`osr-hcom-mattermost.service` runs as `osr-hcom` with the webhook delivered via
systemd `LoadCredential`. It follows
`hcom events --follow --full --type message --after-id ...` and posts bus
envelopes and native requests or messages with handoff/review/done/completed/
mention signals, with capped text, active `@` mentions disabled and no channel
override. Posts include the event ID.

**Cursor.** The first start records the current tail and watches new events.
Later starts resume `/var/lib/osr-hcom/bridge/cursor.json`, keyed by the
database inode (older cursors that also stored the device number are read by
inode). A database replaced, restored or reset while stopped resumes at the
newest event without replay; a reset seen while running is followed from its
first event. Delivery is **at least once**: a crash after Mattermost accepts a
post but before the cursor is saved can duplicate it.

**Errors.** Network errors and HTTP 5xx/429 retry with backoff, then systemd
restarts the service. Rejected posts (400, 413, 422) are logged with their
event ID and skipped. A missing, disabled or forbidden webhook (401, 403, 404,
410) is logged and retried until fixed (rerun the observer provisioner). Logs
show status codes, never the URL. MQTT retains only a bounded recent tail.

## State, memory and maintenance

Honcho remains the semantic memory; nothing archives bus events to it or shares
its database. Each CT keeps hcom's SQLite, config and logs in the relay
account's `HCOM_DIR`; MQTT synchronizes encrypted events. This is separate
storage, not a hard barrier: native memory plugins may record bus content an
agent reads (absolute exclusion needs changes to their capture policies).
Instructions tell agents to keep handoffs short and never post memory dumps,
credentials or transcripts. Stop the relay before backing up or removing
state.

```bash
systemctl status osr-hcom-relay osr-hcom-bus.socket
journalctl -u osr-hcom-relay -n 50
journalctl -u 'osr-hcom-bus@*' -n 50
systemctl status osr-hcom-mattermost   # observer only
```

Unchanged healthy installs print `nothing to do`; file drift is repaired. Each
install checks that the relay reaches the broker, the socket answers for root
and the agent, and the agent cannot read the key. A failed install restores
the managed binary, config, plugin and unit files (and both state directories
during a move) and restarts the previous services. A failed rollback leaves
`/etc/osr-hcom/rollback` and blocks further runs; recover it before removing
the snapshot. Apt packages and runtime databases are not rolled back.

## Validation

```bash
bash tests/run-tests.sh hcom-install
bash tests/run-tests.sh mqtt-install
bash tests/run-tests.sh hcom-integration
python3 targets/hcom/test-live.py --hcom /path/to/hcom \
  --mosquitto /usr/sbin/mosquitto --mosquitto-passwd /usr/bin/mosquitto_passwd   # optional
```

The live test runs two simulated CTs, each with its own per-connection bus
socket, against real hcom and Mosquitto and a local webhook, in temporary state
with no external notifications. It checks anonymous rejection, authenticated
cross-device traffic, sender stamping, inbox filtering, follow, exact quoting,
HTTP retry, restart deduplication and survival of the unit's worker beside a
stray one. Run it as an ordinary user (Mosquitto started as root cannot read
the private temporary files). It does not exercise Proxmox, systemd or the real
agents and Mattermost.
