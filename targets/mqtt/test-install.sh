#!/usr/bin/env bash
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../hcom/install-state.sh"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
printf 'old secret\n' > "$stage/relay.json"
snapshot_save "$stage/snapshot" "$stage/relay.json" "$stage/listener.conf"
printf 'bad secret\n' > "$stage/relay.json"
printf 'listener 0\n' > "$stage/listener.conf"
snapshot_restore "$stage/snapshot"
[[ $(<"$stage/relay.json") == 'old secret' && ! -e $stage/listener.conf ]] || { echo 'FAIL: previous MQTT configuration not running again'; exit 1; }
rm() { return 1; }
if snapshot_restore "$stage/snapshot"; then echo 'FAIL: must report rollback failed too'; exit 1; fi
unset -f rm
sha256sum "$stage/relay.json" > "$stage/digests"
files_match "$stage/digests" || { echo 'FAIL: unchanged installation should have nothing to do'; exit 1; }
output=$(MQTT_BIND_IP=192.0.2.86 bash "$here/install-target.sh" --dry-run)
[[ $output == *'anonymous access disabled'* ]] || exit 1
if MQTT_PORT=65536 bash "$here/install-target.sh" --dry-run 2>/dev/null; then exit 1; fi
if MQTT_BIND_IP=999.0.0.1 bash "$here/install-target.sh" --dry-run 2>/dev/null; then exit 1; fi
if MQTT_TLS_CERT_FILE=/missing bash "$here/install-target.sh" --dry-run 2>/dev/null; then exit 1; fi
CT_ID=286 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst STORAGE=local-lvm \
  IP_CIDR=192.0.2.86/24 GATEWAY=192.0.2.1 MQTT_CLIENT_CIDR=192.0.2.0/24 bash "$here/provision-lxc.sh" --dry-run >/dev/null
echo 'PASS mqtt: file rollback, failure reporting, drift detection, installer/provisioner dry runs and validation'
