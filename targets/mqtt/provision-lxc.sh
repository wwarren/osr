#!/usr/bin/env bash
# Provision a dedicated broker CT; never delete or replace an existing CT.
set -Eeuo pipefail
umask 077
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$here/pve-select.sh"
dry_run=0; reconfigure=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    --reconfigure) reconfigure=1 ;;
    -h|--help) echo 'Usage: [CT_ID=<default: next free ID>] TEMPLATE= STORAGE=... IP_CIDR=... GATEWAY=... MQTT_CLIENT_CIDR=... bash provision-lxc.sh [--dry-run] [--reconfigure]'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done
CT_ID=${CT_ID:-}; TEMPLATE=${TEMPLATE:-}; STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}; GATEWAY=${GATEWAY:-}; BRIDGE=${BRIDGE:-vmbr0}
CT_HOSTNAME=${CT_HOSTNAME:-mqtt}; CORES=${CORES:-1}; MEMORY_MB=${MEMORY_MB:-512}; ROOTFS_GB=${ROOTFS_GB:-4}
MQTT_CLIENT_CIDR=${MQTT_CLIENT_CIDR:-}
MQTT_PORT=${MQTT_PORT:-1883}
if (( reconfigure )); then pve_prompt_required CT_ID 'Broker CT ID'; else pve_new_ct_id CT_ID 'Broker CT ID'; fi
pve_valid_ct_id "$CT_ID" || die 'CT_ID must be a Proxmox ID of 100 or more.'
if (( ! reconfigure )); then
  pve_select_template TEMPLATE ':vztmpl/debian-(12|13)-.*amd64.*\.tar\.(zst|gz|xz)$'
  pve_select_storage STORAGE rootdir "$ROOTFS_GB"
  pve_prompt_required TEMPLATE 'Debian 12/13 amd64 template'
  pve_prompt_required STORAGE 'Root disk storage'
  [[ $TEMPLATE =~ ^[A-Za-z0-9_-]+:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+amd64[A-Za-z0-9._-]*\.tar\.(zst|gz|xz)$ ]] || die 'Use a Debian 12/13 amd64 template.'
  [[ $STORAGE =~ ^[A-Za-z0-9_-]+$ ]] || die 'Invalid storage.'
fi
pve_prompt_required IP_CIDR 'Broker static IPv4/prefix'
pve_prompt_required GATEWAY 'Gateway IPv4'
pve_prompt_required MQTT_CLIENT_CIDR 'Client IPv4 CIDR admitted to MQTT'
python3 - "$IP_CIDR" "$GATEWAY" "$MQTT_CLIENT_CIDR" <<'PY'
import ipaddress, sys
ipaddress.IPv4Interface(sys.argv[1])
ipaddress.IPv4Address(sys.argv[2])
ipaddress.IPv4Network(sys.argv[3], strict=False)
PY
[[ $BRIDGE =~ ^[A-Za-z0-9_.-]+$ && $CT_HOSTNAME =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die 'Invalid bridge or hostname.'
for value in "$CORES" "$MEMORY_MB" "$ROOTFS_GB" "$MQTT_PORT"; do
  [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || die 'Sizing and port must be positive integers.'
done
(( MQTT_PORT <= 65535 )) || die 'Invalid MQTT_PORT.'
MQTT_HOST=${MQTT_HOST:-${IP_CIDR%/*}}
MQTT_BIND_IP=${IP_CIDR%/*}
export MQTT_HOST MQTT_PORT MQTT_BIND_IP
bash "$here/install-target.sh" --dry-run >/dev/null
if (( dry_run )); then
  printf '+ %s broker CT %s at %s (unprivileged Debian); admit %s to TCP %s\n' \
    "$([[ $reconfigure == 1 ]] && echo reconfigure || echo create)" "$CT_ID" "$IP_CIDR" "$MQTT_CLIENT_CIDR" "$MQTT_PORT"
  bash "$here/install-target.sh" --dry-run
  exit 0
fi
[[ $EUID == 0 ]] || die 'Run on the Proxmox host as root.'
command -v pct >/dev/null || die 'pct is required.'
if (( reconfigure )); then
  pct config "$CT_ID" | grep -q '^description: MQTT relay for Ollama Smart Router' || die 'Selected CT is not the OSR MQTT target.'
  pct status "$CT_ID" | grep -q running || die 'Broker CT must be running.'
else
  if pct config "$CT_ID" >/dev/null 2>&1 || qm config "$CT_ID" >/dev/null 2>&1; then die 'CT_ID is already in use.'; fi
  ( umask 022; pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --unprivileged 1 \
    --cores "$CORES" --memory "$MEMORY_MB" --swap 256 --rootfs "$STORAGE:$ROOTFS_GB" \
    --net0 "name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1" \
    --onboot 1 --description 'MQTT relay for Ollama Smart Router' --tags 'ai;ai-tools;osr-target;mqtt' )
  pct start "$CT_ID"
fi
# Preserve user firewall rules on reconfigure. Replace only our managed rule.
fw=/etc/pve/firewall/$CT_ID.fw
stage=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  pct exec "$CT_ID" -- rm -rf /root/osr-mqtt-setup 2>/dev/null || true
  rm -rf -- "$stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
ready=false
for (( attempt=0; attempt<30; attempt++ )); do
  if pct exec "$CT_ID" -- true 2>/dev/null; then ready=true; break; fi
  sleep 1
done
$ready || die 'Broker CT did not become ready.'
new_firewall=false
if [[ ! -f $fw ]]; then
  new_firewall=true
  touch "$fw"
  printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out: ACCEPT\n\n[RULES]\n' > "$stage/firewall"
else
  cp "$fw" "$stage/firewall"
fi
cp "$fw" "$stage/firewall.before"
python3 - "$stage/firewall" "$MQTT_CLIENT_CIDR" "$MQTT_PORT" <<'PY'
from pathlib import Path
import ipaddress, sys
p = Path(sys.argv[1])
text = '\n'.join(line for line in p.read_text().splitlines() if not line.endswith('# osr-hcom-mqtt'))
rule = f'IN ACCEPT -source {ipaddress.IPv4Network(sys.argv[2], strict=False)} -p tcp -dport {sys.argv[3]} -log nolog # osr-hcom-mqtt'
if '[RULES]' not in text:
    text += '\n[RULES]\n'
p.write_text(text.replace('[RULES]', '[RULES]\n' + rule, 1) + '\n')
PY
if $new_firewall; then
  # A new broker must have its allowlist before any network listener starts.
  perl "$here/../pve-firewall-swap.pl" "$fw" "$stage/firewall.before" "$stage/firewall" "$CT_ID" /etc/pve ||
    die 'Could not install the initial broker firewall.'
  cp "$stage/firewall" "$stage/firewall.before"
fi
pct exec "$CT_ID" -- install -d -m 0700 /root/osr-mqtt-setup
for file in "$here/install-target.sh" "$here/../hcom/bus_config.py" "$here/../hcom/install-state.sh"; do
  pct push "$CT_ID" "$file" "/root/osr-mqtt-setup/${file##*/}" --perms 0600
done
env_args=("MQTT_BIND_IP=$MQTT_BIND_IP" "MQTT_HOST=$MQTT_HOST" "MQTT_PORT=$MQTT_PORT")
if [[ -n ${MQTT_TLS_CERT_FILE:-} ]]; then
  pct push "$CT_ID" "$MQTT_TLS_CERT_FILE" /root/osr-mqtt-setup/tls.crt --perms 0600
  pct push "$CT_ID" "$MQTT_TLS_KEY_FILE" /root/osr-mqtt-setup/tls.key --perms 0600
  env_args+=(MQTT_TLS_CERT_FILE=/root/osr-mqtt-setup/tls.crt MQTT_TLS_KEY_FILE=/root/osr-mqtt-setup/tls.key)
fi
status=0
pct exec "$CT_ID" -- env "${env_args[@]}" bash /root/osr-mqtt-setup/install-target.sh || status=$?
pct exec "$CT_ID" -- rm -rf /root/osr-mqtt-setup
if (( status == 0 )); then
  # Keep the previous allow rule until the new guest is healthy. Refuse
  # concurrent edits using Proxmox's per-CT lock and the shared content check.
  perl "$here/../pve-firewall-swap.pl" "$fw" "$stage/firewall.before" "$stage/firewall" "$CT_ID" /etc/pve ||
    die 'MQTT is installed, but the firewall changed or could not be published; rerun --reconfigure.'
fi
exit "$status"
