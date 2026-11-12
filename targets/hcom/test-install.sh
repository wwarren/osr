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
for target in hermes openclaw deepseek-harness opencode observer; do
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
# Parameters: an unattended run names every missing setting; a person is asked,
# with CTs offered by their tags and, on --reconfigure, the CT's recorded values.
output=$(bash "$here/provision-lxc.sh" --dry-run </dev/null 2>&1) && { echo 'FAIL: missing settings accepted'; exit 1; }
[[ $output == *'CT_ID (the existing CT)'* && $output == *'MQTT_CT_ID (the broker CT)'* && $output == *'HCOM_TARGET ('* ]] ||
  { echo 'FAIL: unattended run must name each missing setting'; exit 1; }
output=$(bash "$here/provision-lxc.sh" --reconfigure --dry-run </dev/null 2>&1) && { echo 'FAIL: missing CT accepted'; exit 1; }
[[ $output == *'CT_ID (the existing CT)'* && $output != *'HCOM_TARGET ('* ]] ||
  { echo 'FAIL: a reconfigure can take the recorded target'; exit 1; }
output=$(CT_ID=12 bash "$here/provision-lxc.sh" --dry-run </dev/null 2>&1) && exit 1
[[ $output == *"CT_ID must be a CT ID (100 or more), not '12'"* ]] || { echo 'FAIL: bad CT_ID message'; exit 1; }
bash "$here/provision-lxc.sh" --help | grep -q 'MATTERMOST_CT_ID    observer' || { echo 'FAIL: --help lists the settings'; exit 1; }
lxc=$stage/lxc
mkdir -p "$lxc"
for ct in '282 hermes' '283 openclaw' '286 mqtt' '277 mattermost'; do
  set -- $ct
  printf 'net0: name=eth0,bridge=vmbr0,ip=192.0.2.%s/24\ntags: ai;ai-tools;osr-target;%s\n' "${1:1}" "$2" > "$lxc/$1.conf"
done
asked() { PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc bash "$here/provision-lxc.sh" "$@" 2>&1; }
output=$(printf 'hermes\n\n\n\n' | asked --dry-run)
[[ $output == *'Existing Hermes CT ID [282]'* && $output == *'MQTT broker CT ID [286]'* && $output == *'existing hermes CT 282'* ]] ||
  { echo 'FAIL: tagged Hermes and broker CTs offered'; exit 1; }
output=$(printf 'nope\nobserver\n\n\n\n' | asked --dry-run)
[[ $output == *'Use hermes, openclaw'* && $output == *'Mattermost CT ID (none to skip) [277]'* && $output == *'Mattermost CT 277'* ]] ||
  { echo 'FAIL: observer prompts'; exit 1; }
output=$(printf 'openclaw\n\n\n' | MQTT_CT_ID=286 asked --dry-run)
[[ $output != *'MQTT broker CT ID'* && $output != *'native'* ]] || { echo 'FAIL: preset or irrelevant settings asked'; exit 1; }
# --reconfigure reads what the CT recorded (fake pct): target, native mode and
# the broker address, found again by IP even though the broker lost its tag.
sed -i 's/;mqtt$//' "$lxc/286.conf"
mkdir -p "$stage/bin"
cat > "$stage/bin/pct" <<'PCT'
#!/bin/sh
case $1 in
  status) echo 'status: running' ;;
  exec) printf 'target=hermes\nnative=true\nbroker=192.0.2.86\n' ;;
esac
PCT
chmod +x "$stage/bin/pct"
# Not a dry run (that reads nothing from the CT), so answer "n" at the
# confirmation: it stops before any change, even on a real Proxmox host.
output=$(printf '282\n\n\n\nn\n' | PATH="$stage/bin:$PATH" asked --reconfigure) && { echo 'FAIL: declined plan ran'; exit 1; }
[[ $output == *'(hermes, openclaw, deepseek-harness, opencode, observer) [hermes]'* && $output == *'MQTT broker CT ID [286]'* &&
   $output == *'native hcom plugin? [Y/n]'* && $output == *'Native Hermes plugin       true'* &&
   $output == *'nothing was changed'* ]] ||
  { echo 'FAIL: reconfigure defaults to the recorded settings'; printf '%s\n' "$output"; exit 1; }
echo 'PASS hcom: snapshots, rollback failure, drift detection, dry-run plans, early firewall rollback, parameter prompts and validation'
