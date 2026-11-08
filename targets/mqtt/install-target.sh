#!/usr/bin/env bash
# Authenticated Mosquitto for the hcom relay. Run inside a Debian 12/13 CT.
set -Eeuo pipefail
umask 077
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
dry_run=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'Usage: MQTT_BIND_IP=<CT IPv4> MQTT_HOST=<DNS-or-IP> bash install-target.sh [--dry-run]'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done
MQTT_BIND_IP=${MQTT_BIND_IP:-127.0.0.1}
MQTT_HOST=${MQTT_HOST:-$MQTT_BIND_IP}
MQTT_PORT=${MQTT_PORT:-1883}
MQTT_TLS_CERT_FILE=${MQTT_TLS_CERT_FILE:-}
MQTT_TLS_KEY_FILE=${MQTT_TLS_KEY_FILE:-}
etc=${MQTT_ETC_DIR:-/etc/mqtt-target}
conf=${MQTT_CONF_DIR:-/etc/mosquitto/conf.d}
[[ $MQTT_BIND_IP =~ ^[0-9.]+$ && $MQTT_HOST =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die 'Invalid MQTT_BIND_IP or MQTT_HOST.'
[[ $MQTT_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( MQTT_PORT <= 65535 )) || die 'Invalid MQTT_PORT.'
python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$MQTT_BIND_IP" || die 'Invalid IPv4 bind address.'
scheme=mqtt
if [[ -n $MQTT_TLS_CERT_FILE || -n $MQTT_TLS_KEY_FILE ]]; then
  [[ -r $MQTT_TLS_CERT_FILE && -r $MQTT_TLS_KEY_FILE ]] || die 'TLS requires readable certificate and key files.'
  scheme=mqtts
fi
helper=$here/../hcom/bus_config.py
[[ -r $helper ]] || helper=$here/bus_config.py
[[ -r $helper ]] || die 'Missing hcom/bus_config.py; use the full checkout.'
state_helper=$here/../hcom/install-state.sh
[[ -r $state_helper ]] || state_helper=$here/install-state.sh
# shellcheck source=../hcom/install-state.sh
source "$state_helper"
if (( dry_run )); then
  printf '+ install Mosquitto; listen on %s:%s (%s), anonymous access disabled\n' "$MQTT_BIND_IP" "$MQTT_PORT" "$scheme"
  printf '+ keep or create relay credentials in %s/relay.json; ACL allows only that group\n' "$etc"
  printf '+ restart mosquitto; verify active; restore previous files if startup fails\n'
  exit 0
fi
[[ $EUID == 0 ]] || die 'Run as root inside the broker CT.'
install -d -m 0700 "$etc"
exec {lock_fd}>"$etc/install.lock"
flock -n "$lock_fd" || die 'Another MQTT installer is running.'
[[ ! -d $etc/rollback ]] || die "Failed rollback retained in $etc/rollback; repair it before rerunning."
input_sha=$( { cat "$helper" "$state_helper" "$here/install-target.sh"; printf '%s\n' "$MQTT_BIND_IP" "$MQTT_HOST" "$MQTT_PORT"; [[ -z $MQTT_TLS_CERT_FILE ]] || cat "$MQTT_TLS_CERT_FILE" "$MQTT_TLS_KEY_FILE"; } | sha256sum | cut -d' ' -f1)
if [[ -r $etc/settings && $(<"$etc/settings") == "$input_sha" ]] &&
   files_match "$etc/managed.sha256" && systemctl is-active --quiet mosquitto.service; then
  echo 'MQTT is configured and running: nothing to do.'
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y mosquitto mosquitto-clients ca-certificates python3
install -d -m 0755 "$conf"
stage=$(mktemp -d)
files=("$etc/relay.json" "$etc/settings" "$etc/managed.sha256" "$conf/osr-hcom.conf" /etc/mosquitto/osr-hcom.passwd /etc/mosquitto/osr-hcom.acl /etc/mosquitto/osr-hcom.crt /etc/mosquitto/osr-hcom.key)
snapshot_save "$etc/rollback" "${files[@]}"
rollback() {
  local status=$? recovered=true
  trap - EXIT
  if (( status != 0 )); then
    snapshot_restore "$etc/rollback" || recovered=false
    systemctl restart mosquitto.service && systemctl is-active --quiet mosquitto.service || recovered=false
    if $recovered; then echo 'Previous MQTT configuration running again.' >&2
    else echo "MQTT rollback failed too; snapshot retained in $etc/rollback." >&2; fi
  fi
  if (( status == 0 )) || $recovered; then rm -rf -- "$etc/rollback"; fi
  rm -rf -- "$stage"
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
python3 "$helper" broker --bundle "$etc/relay.json" --url "$scheme://$MQTT_HOST:$MQTT_PORT" \
  --password-file "$stage/password" --acl-file "$stage/acl"
mosquitto_passwd -U "$stage/password"
install -o root -g mosquitto -m 0640 "$stage/password" /etc/mosquitto/osr-hcom.passwd
install -o root -g mosquitto -m 0640 "$stage/acl" /etc/mosquitto/osr-hcom.acl
{
  printf 'listener %s %s\nallow_anonymous false\n' "$MQTT_PORT" "$MQTT_BIND_IP"
  printf 'password_file /etc/mosquitto/osr-hcom.passwd\nacl_file /etc/mosquitto/osr-hcom.acl\n'
  if [[ $scheme == mqtts ]]; then
    install -o root -g mosquitto -m 0640 "$MQTT_TLS_CERT_FILE" /etc/mosquitto/osr-hcom.crt
    install -o root -g mosquitto -m 0640 "$MQTT_TLS_KEY_FILE" /etc/mosquitto/osr-hcom.key
    printf 'certfile /etc/mosquitto/osr-hcom.crt\nkeyfile /etc/mosquitto/osr-hcom.key\ntls_version tlsv1.2\n'
  fi
} > "$conf/osr-hcom.conf"
chmod 0644 "$conf/osr-hcom.conf"
systemctl enable mosquitto.service
systemctl restart mosquitto.service
sleep 1
systemctl is-active --quiet mosquitto.service || die 'Mosquitto failed to start.'
printf '%s\n' "$input_sha" > "$etc/settings"
managed=()
for file in "${files[@]}"; do
  [[ $file == "$etc/managed.sha256" || $file == "$etc/settings" || ! -f $file ]] || managed+=("$file")
done
sha256sum "${managed[@]}" > "$etc/managed.sha256"
printf 'MQTT ready. Relay bundle: %s/relay.json (secret; distribute through pct push).\n' "$etc"
