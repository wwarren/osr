#!/usr/bin/env bash
# On the Proxmox host: install an OSR temperature exporter for one router CT.
# CT_ID=<router CT> BRIDGE=<host bridge> ROUTER_IP=<CT IPv4> bash this-file
set -euo pipefail

: "${CT_ID:?set CT_ID to the router CT ID}"
: "${BRIDGE:?set BRIDGE to the Proxmox bridge with an IPv4 address}"
: "${ROUTER_IP:?set ROUTER_IP to the router CT IPv4 address}"
[[ $EUID -eq 0 ]] || { echo 'Run as root on the Proxmox host.' >&2; exit 1; }
[[ $CT_ID =~ ^[0-9]+$ && $ROUTER_IP =~ ^[0-9.]+$ && $BRIDGE =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="${SCRIPT_DIR}/../services/temperature-exporter/exporter.py"
[[ -f $SOURCE ]] || { echo "Missing $SOURCE" >&2; exit 1; }
HOST_IP="$(ip -4 -o addr show dev "$BRIDGE" | awk 'NR == 1 {split($4, a, "/"); print a[1]}')"
[[ $HOST_IP =~ ^[0-9.]+$ ]] || { echo "No IPv4 address on $BRIDGE; temperature exporter was not installed." >&2; exit 1; }
python3 - "$HOST_IP" "$ROUTER_IP" <<'PY'
import ipaddress, sys
for address in sys.argv[1:]:
    ipaddress.IPv4Address(address)
PY

id -u osr-temperature >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin osr-temperature
install -d -m 0755 /usr/local/libexec /etc/osr-temperature-exporter
install -m 0755 "$SOURCE" /usr/local/libexec/osr-temperature-exporter.py
if [[ ! -s /etc/osr-temperature-exporter/token ]]; then
  umask 077
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > /etc/osr-temperature-exporter/token
fi
chown osr-temperature:osr-temperature /etc/osr-temperature-exporter/token
chmod 0600 /etc/osr-temperature-exporter/token
cat > /etc/systemd/system/osr-temperature-exporter.service <<EOF
[Unit]
Description=OSR Proxmox host temperature exporter
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=osr-temperature
Group=osr-temperature
ExecStart=/usr/bin/python3 /usr/local/libexec/osr-temperature-exporter.py --bind ${HOST_IP} --allow ${ROUTER_IP}
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
CapabilityBoundingSet=
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET
SystemCallArchitectures=native
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable osr-temperature-exporter.service
systemctl restart osr-temperature-exporter.service

# Keep the bearer secret off command lines and out of the Git config repo.
pct push "$CT_ID" /etc/osr-temperature-exporter/token /etc/prometheus/osr-sensors-key --perms 0600
pct exec "$CT_ID" -- chown prometheus:prometheus /etc/prometheus/osr-sensors-key
pct exec "$CT_ID" -- env OSR_SENSOR_TARGET="${HOST_IP}:9408" bash /app/config-repo/install/setup-metrics.sh sync-sensors
echo "Temperature metrics: ${HOST_IP}:9408 (only ${ROUTER_IP} is accepted; allow TCP 9408 from it in the host firewall if enabled)."
