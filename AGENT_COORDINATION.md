# Agent coordination targets

[MQTT](targets/mqtt/README.md) provides an authenticated Mosquitto broker in its
own CPU-only Debian LXC (1 core, 512 MB, 4 GB). [hcom](targets/hcom/README.md)
installs the checksum-pinned 0.7.31 CLI into existing Hermes, OpenClaw,
DeepSeek Harness and OpenCode CTs; each keeps its own SQLite state and MQTT relays encrypted
events between them. Neither joins the model pool or needs an Open WebUI token.
Install the agents first, then the broker, then hcom in each agent; the
optional Mattermost observer also needs a configured Mattermost CT. From a full
checkout, as root on the same host, with your own IDs and addresses:

```bash
# 1. Broker
CT_ID=286 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.86/24 GATEWAY=192.0.2.1 MQTT_CLIENT_CIDR=192.0.2.0/24 \
  bash tools/install-mqtt.sh --dry-run
# 2. hcom in existing agent CTs (creates no CTs)
CT_ID=282 MQTT_CT_ID=286 HCOM_TARGET=hermes           bash tools/install-hcom.sh --dry-run
CT_ID=283 MQTT_CT_ID=286 HCOM_TARGET=openclaw         bash tools/install-hcom.sh --dry-run
CT_ID=281 MQTT_CT_ID=286 HCOM_TARGET=deepseek-harness bash tools/install-hcom.sh --dry-run
# 3. Optional: one observer on the broker CT, posting to Mattermost CT 277
CT_ID=286 MQTT_CT_ID=286 HCOM_TARGET=observer MATTERMOST_CT_ID=277 bash tools/install-hcom.sh --dry-run
```

Remove `--dry-run` to apply. The hcom provisioner adds owned outbound rules
where an agent restricts egress (Hermes and OpenClaw do by default). The
broker's `MQTT_CLIENT_CIDR` is the one IPv4 range allowed to connect (Proxmox
firewall enforcement must be on): give a range containing every agent CT, usually
their shared subnet such as `192.168.1.0/24`, or `a.b.c.d/32` for a single CT.
The prompt suggests the broker's subnet and warns about agents outside it. Port 1883 (`mqtt://`) is for a trusted network; for
TLS set `MQTT_PORT=8883`, `MQTT_HOST` to the certificate's name, and
`MQTT_TLS_CERT_FILE`/`MQTT_TLS_KEY_FILE`, with clients trusting the
certificate.

| Integration | Agent behaviour |
|---|---|
| Hermes | `osr-bus` and a managed `/home/hermes/AGENTS.md` block. The opt-in native plugin (`HCOM_HERMES_NATIVE=true`) gives Hermes the relay key and works only in messaging-platform chats, not Open WebUI |
| OpenClaw | Managed workspace instructions use `osr-bus` through its terminal tool; no native hooks or wakeups |
| DeepSeek Harness | Managed `AGENTS.md` block, same `osr-bus`; polling depends on the model |
| OpenCode | Managed block in its global `~/.config/opencode/AGENTS.md`, same `osr-bus` through its shell tool |
| Mattermost | One observer posts short handoffs to a dedicated `agent-handoffs` webhook, separate from health alerts |

```bash
osr-bus status                 # through an agent's terminal tool, or as root
osr-bus inbox --last 100
osr-bus send hermes 'Please review the new installer.'
osr-bus follow
osr-bus tui                    # root only
```

Agents reach the bus only through `/run/osr-hcom/bus.sock`, which stamps the
sender; hcom state and the relay key belong to a separate `osr-hcom` account,
because any key holder can send hcom remote requests (settings, transcripts,
launches) to its peers. Messages are limited to 2,000 characters; `inbox` shows
recent events and agents use IDs to avoid repeating work. The observer keeps a
cursor, retries failed HTTP deliveries, starts at new messages and never
replays history after a database replacement; delivery is at least once. Run
one observer per relay group. `/etc/mqtt-target/relay.json` must stay out of
Git. No bus-to-Honcho archive exists, but native memory plugins can record bus
content an agent reads. Details: [hcom guide](targets/hcom/README.md),
[architecture](ARCHITECTURE.md#177-mqtt-and-hcom-agent-coordination).

