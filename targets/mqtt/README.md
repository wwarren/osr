# MQTT tool target

An unprivileged Debian 12/13 LXC with authenticated Mosquitto for the
[hcom agent bus](../hcom/README.md). Defaults: 1 core, 512 MB RAM, 4 GB disk.
It is a standalone follow-up target, not in the main installer's menu.

From a full checkout on the Proxmox host, as root:

```bash
CT_ID=286 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
STORAGE=local-lvm IP_CIDR=192.0.2.86/24 GATEWAY=192.0.2.1 \
MQTT_CLIENT_CIDR=192.0.2.0/24 \
bash tools/install-mqtt.sh --dry-run        # then without --dry-run
```

Missing required values are prompted for, without the full confirmation flow
of the other provisioners. No existing CT is deleted. To reconfigure, rerun
with the same network settings and `--reconfigure`; the CT must be running and
carry the OSR MQTT description. Outside Proxmox, run
`targets/mqtt/install-target.sh` as root in a dedicated Debian guest with
`MQTT_BIND_IP` set to its IPv4 address.

| Setting | Default | Meaning |
|---|---|---|
| `CT_ID` | Cluster's next free ID | New CT's ID (required for `--reconfigure` and dry runs) |
| `TEMPLATE`, `STORAGE`, `IP_CIDR`, `GATEWAY` | Required to create | Placement and network |
| `MQTT_CLIENT_CIDR` | Required; asked with the broker's subnet as suggestion | The one IPv4 range allowed to connect: it must cover every agent CT that runs hcom (see Firewall) |
| `MQTT_PORT` | `1883` | Listener port (8883 for TLS) |
| `MQTT_HOST` | CT IP | Address advertised to hcom clients |
| `MQTT_BIND_IP` | CT IP; `127.0.0.1` for direct guest installs | Listener address |
| `MQTT_TLS_CERT_FILE`, `MQTT_TLS_KEY_FILE` | Unset | Host files enabling TLS |
| `BRIDGE`, `CT_HOSTNAME` | `vmbr0`, `mqtt` | Network and hostname |
| `CORES`, `MEMORY_MB`, `ROOTFS_GB` | 1, 512, 4 | Resources |

**Firewall.** The CT's firewall drops inbound traffic except `MQTT_CLIENT_CIDR`
on the MQTT port; the Proxmox host/datacenter firewall must be enabled for it
to apply. Choose one range, in `a.b.c.d/nn` form, that contains every CT
whose hcom relay connects: Hermes, OpenClaw, DeepSeek Harness, and an observer
on any other CT (an observer on the broker CT itself needs no entry):

| Agents are… | Enter |
|---|---|
| All on the broker's subnet, e.g. `192.168.1.x` (usual) | `192.168.1.0/24` |
| One CT only, e.g. `192.168.1.82` | `192.168.1.82/32` |
| On two subnets | One range spanning both (e.g. `10.0.0.0/16`), or add a second rule yourself |

The prompt lists the agent CTs it finds by tag and warns about any outside the
range you enter. Clients also need the generated password, so the range is an
extra layer, not the only check. To change it later, rerun with the new
`MQTT_CLIENT_CIDR` and `--reconfigure`. Reconfigure preserves unrelated rules and replaces the file under the
shared Proxmox lock after a content check. Debian apt access is required.

**Credentials.** Anonymous access is off; clients use username `hcom` with a
generated password, and an ACL admits only the relay group's topic subtree.
`/etc/mqtt-target/relay.json` (0600) holds broker URL, group, password and
encryption key, kept across reruns. The hcom provisioner moves it privately;
never commit it or paste it anywhere. To rotate, remove it and rerun with
`--reconfigure`, then rerun every hcom provisioner.

**TLS.** The default `mqtt://` listener is for a trusted private network:
broker authentication is unencrypted, although hcom encrypts payloads. For
untrusted or routed networks add:

```bash
MQTT_HOST=mqtt.example.net MQTT_PORT=8883 \
MQTT_TLS_CERT_FILE=/root/mqtt-fullchain.pem MQTT_TLS_KEY_FILE=/root/mqtt-key.pem
```

The certificate must match `MQTT_HOST` and be trusted by the clients' system CA
stores (install a private CA there if needed); no checks are disabled and
client certificates are not required. The files become root:mosquitto 0640.
Pass both files on every TLS reconfigure: omitting them selects non-TLS mode.
Rerun all hcom provisioners after changing the advertised host or port.

**Reruns and recovery.** Unchanged healthy installs print `nothing to do`.
Changed settings regenerate the managed listener, password file and ACL,
keeping credentials. A failed start restores the managed files and checks the
previous service; a failed rollback keeps `/etc/mqtt-target/rollback` and
blocks further runs until recovered. Apt packages and broker runtime state are
not rolled back. Use a dedicated broker: other listeners are left unmanaged.

```bash
systemctl status mosquitto
journalctl -u mosquitto -n 50
```

Next: [hcom deployment and Mattermost handoffs](../hcom/README.md).
