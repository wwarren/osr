#!/usr/bin/env bash
# Non-root checks for the real file rollback and dry-run contracts.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/install-state.sh"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
printf 'previous\n' > "$stage/config"
chmod 0640 "$stage/config"
snapshot_save "$stage/snapshot" "$stage/config" "$stage/new-unit"
printf 'broken\n' > "$stage/config"
printf 'new\n' > "$stage/new-unit"
snapshot_restore "$stage/snapshot"
[[ $(<"$stage/config") == previous && ! -e $stage/new-unit ]] || { echo 'FAIL: previous configuration not running again'; exit 1; }
[[ $(stat -c %a "$stage/config") == 640 ]] || { echo 'FAIL: file mode was lost'; exit 1; }
cp() { return 1; }
if snapshot_restore "$stage/snapshot"; then echo 'FAIL: restore should report rollback failed too'; exit 1; fi
unset -f cp
snapshot_restore "$stage/snapshot"
sha256sum "$stage/config" > "$stage/digests"
files_match "$stage/digests" || { echo 'FAIL: unchanged installation should have nothing to do'; exit 1; }
printf 'changed\n' > "$stage/config"
if files_match "$stage/digests"; then echo 'FAIL: drift was not detected'; exit 1; fi
python3 - "$here" "$stage/bundle" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from bus_config import make_bundle
with open(sys.argv[2], 'w') as output:
    json.dump(make_bundle('mqtt://127.0.0.1:1883'), output)
PY
for target in hermes openclaw deepseek-harness observer; do
  output=$(HCOM_TARGET=$target HCOM_RELAY_BUNDLE=$stage/bundle bash "$here/install-target.sh" --dry-run)
  [[ $output == *"configure $target"* ]] || { echo 'FAIL: dry run lost the target'; exit 1; }
done
if HCOM_TARGET=unknown HCOM_RELAY_BUNDLE=$stage/bundle bash "$here/install-target.sh" --dry-run 2>/dev/null; then exit 1; fi
output=$(HCOM_TARGET=hermes HCOM_RELAY_BUNDLE=$stage/bundle bash "$here/install-target.sh" --dry-run)
[[ $output == *'relay account osr-hcom'* && $output == *'/home/hermes/AGENTS.md'* && $output != *'hooks add'* ]] ||
  { echo 'FAIL: default Hermes must keep the key in the relay account and use its working-directory AGENTS.md'; exit 1; }
output=$(HCOM_TARGET=hermes HCOM_HERMES_NATIVE=true HCOM_RELAY_BUNDLE=$stage/bundle bash "$here/install-target.sh" --dry-run)
[[ $output == *'relay account hermes'* && $output == *'hooks add hermes'* ]] || { echo 'FAIL: native Hermes plan'; exit 1; }
if HCOM_TARGET=openclaw HCOM_HERMES_NATIVE=true HCOM_RELAY_BUNDLE=$stage/bundle bash "$here/install-target.sh" --dry-run 2>/dev/null; then
  echo 'FAIL: native mode is for Hermes only'; exit 1
fi
if HCOM_TARGET=hermes HCOM_INSTRUCTIONS_FILE=/home/hermes/../../etc/x HCOM_RELAY_BUNDLE=$stage/bundle bash "$here/install-target.sh" --dry-run 2>/dev/null; then
  echo 'FAIL: instruction path with .. accepted'; exit 1
fi
CT_ID=281 MQTT_CT_ID=286 HCOM_TARGET=deepseek-harness bash "$here/provision-lxc.sh" --dry-run >/dev/null
if CT_ID=281 MQTT_CT_ID=286 HCOM_TARGET=deepseek-harness MATTERMOST_CT_ID=277 bash "$here/provision-lxc.sh" --dry-run 2>/dev/null; then exit 1; fi
if CT_ID=283 MQTT_CT_ID=286 HCOM_TARGET=openclaw HCOM_HERMES_NATIVE=true bash "$here/provision-lxc.sh" --dry-run 2>/dev/null; then exit 1; fi
output=$(CT_ID=286 MQTT_CT_ID=286 HCOM_TARGET=observer MATTERMOST_CT_ID=277 bash "$here/provision-lxc.sh" --dry-run)
[[ $output == *'reach the broker and Mattermost'* ]] || { echo 'FAIL: observer firewall plan'; exit 1; }
# The same EXIT trap must restore a swapped rule when a pct push fails before
# the guest installer starts. Exercise the real swap helper on fixture files.
python3 "$here/../../tests/lib/extract-functions.py" "$here/provision-lxc.sh" --only cleanup > "$stage/cleanup-function.sh"
mkdir -p "$stage/early-failure/pve"
printf 'original\n' > "$stage/ct.fw"
cp "$stage/ct.fw" "$stage/early-failure/firewall.before"
printf 'allowed\n' > "$stage/early-failure/firewall"
cp "$stage/early-failure/firewall" "$stage/ct.fw"
if (
  source "$stage/cleanup-function.sh"
  pct() { :; }
  # Keep the real swap helper in fixture mode even on a Proxmox test host.
  perl() { command perl "$1" "$2" "$3" "$4" "$5" "$stage/pve"; }
  # Read by the sourced cleanup function, which shellcheck cannot see.
  # shellcheck disable=SC2034
  fw_changed=true fw="$stage/ct.fw" CT_ID=283
  stage="$stage/early-failure"
  trap cleanup EXIT
  false  # stand in for a failed pct push
); then
  echo 'FAIL: early provisioning failure was reported as success'; exit 1
fi
[[ $(<"$stage/ct.fw") == original ]] || { echo 'FAIL: early provisioning failure left its firewall rule'; exit 1; }
echo 'PASS hcom: snapshots, rollback failure, drift detection, dry-run plans, early firewall rollback and validation'
