#!/usr/bin/env bash
# The Honcho provisioner: its questions, its plan, and its checks before any PVE call.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
provision=$here/provision-lxc.sh
common=(CT_ID=285 ROUTER_CT_ID=280 ROUTER_IP=192.0.2.80 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
  STORAGE=local-lvm IP_CIDR=192.0.2.85/24 GATEWAY=192.0.2.1)

describe honcho_dry_run
plan=$(env "${common[@]}" bash "$provision" --dry-run)
assert_contains "valid setup gets a plan" "Would create Honcho CT 285" "$plan"
assert_contains "the plan shows the entered router IP" "Router IP: 192.0.2.80" "$plan"
assert_contains "the plan shows the local embedding model" "embedding: qwen3-embedding-0.6b (1024 dimensions) in the Honcho CT" "$plan"
assert_fail "a missing Honcho CT ID cannot be guessed" env "${common[@]}" CT_ID= bash "$provision" --dry-run
assert_fail "a missing router CT ID cannot be guessed" env "${common[@]}" ROUTER_CT_ID= bash "$provision" --dry-run
assert_fail "a missing Honcho IP cannot be guessed" env "${common[@]}" IP_CIDR= bash "$provision" --dry-run
assert_fail "a missing router IP cannot be guessed" env "${common[@]}" ROUTER_IP= bash "$provision" --dry-run
assert_fail "Honcho cannot reuse the router IP" env "${common[@]}" ROUTER_IP=192.0.2.85 bash "$provision" --dry-run
assert_fail "an agent cannot reuse the Honcho IP" env "${common[@]}" HONCHO_CLIENT_IPS=192.0.2.85 bash "$provision" --dry-run
out=$(env "${common[@]}" HONCHO_EMBEDDING_MODEL=nomic-embed-text HONCHO_EMBEDDING_BASE_URL=http://192.0.2.90:11434/v1 \
  bash "$provision" --dry-run 2>&1) && rc=0 || rc=$?
assert_eq "an earlier embedding setting does not stop a run" 0 "$rc"
assert_contains "it is named as no longer used" "HONCHO_EMBEDDING_MODEL is no longer used" "$out"
assert_not_contains "and does not reach the CT" "nomic-embed-text" "$(grep -v 'no longer used' <<< "$out")"
assert_fail "Debian 12 lacks the packaged pgvector target" env "${common[@]}" TEMPLATE=local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst bash "$provision" --dry-run
assert_contains "a release is pinned by default" "with v3.5.0" "$plan"
assert_fail "a moving branch other than main is refused" env "${common[@]}" HONCHO_REF=develop bash "$provision" --dry-run
assert_fail "--rotate-keys needs an existing CT" env "${common[@]}" bash "$provision" --dry-run --rotate-keys
plan=$(env "${common[@]}" bash "$provision" --dry-run --reconfigure --rotate-keys)
assert_contains "a reconfigure can rotate the keys" "Would replace the JWT secret, the admin key and Open WebUI's gateway key" "$plan"
assert_contains "a dry-run reconfigure names the checks it cannot make" "Not checked by a dry run: CT 285 must be running, tagged honcho, and embed with qwen3-embedding-0.6b" "$plan"
assert_not_contains "a dry-run create has no such check" "Not checked by a dry run" "$(env "${common[@]}" bash "$provision" --dry-run)"
assert_contains "and admits Honcho in the router's firewall" "Would admit 192.0.2.85 to the router API in /etc/pve/firewall/280.fw" "$plan"
assert_not_contains "unless that is turned off" "Would admit" "$(env "${common[@]}" HONCHO_ROUTER_FIREWALL=false bash "$provision" --dry-run)"
assert_fail "json_object or json_schema only" env "${common[@]}" HONCHO_STRUCTURED_OUTPUT_MODE=xml bash "$provision" --dry-run
assert_fail "another Bun needs a checksum" env "${common[@]}" HONCHO_BUN_VERSION=1.5.0 bash "$provision" --dry-run
assert_ok "and runs with the baseline one alone" env "${common[@]}" HONCHO_BUN_VERSION=1.5.0 HONCHO_BUN_BASELINE_SHA256="$(printf 'a%.0s' {1..64})" bash "$provision" --dry-run
assert_fail "a checksum is 64 hex digits" env "${common[@]}" HONCHO_BUN_SHA256=abc bash "$provision" --dry-run

describe honcho_reconfigure_preflight
# shellcheck disable=SC1090
source <(awk '/^# Reconfigure guard helper:/{c=1} /^# End reconfigure guard helper\.$/{print; c=0} c' "$provision")
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
pct() {
  case $1 in
    status) [[ ${FAKE_CT_DOWN:-false} != true ]] && printf 'status: running\n' ;;
    config) printf 'description: Honcho AI for Ollama Smart Router%%0A\ntags: %s\n' "${FAKE_CT_TAGS:-osr-target;honcho}" ;;
    exec)
      case $4 in
        sed) printf '%s\n' "${FAKE_PREVIOUS_EMBEDDING:-qwen3-embedding-0.6b}" ;;
      esac ;;
  esac
}
preflight() ( honcho_reconfigure_preflight 285 )
assert_ok "the encoded Proxmox description and same model permit reconfigure" preflight
out=$(FAKE_PREVIOUS_EMBEDDING=nomic-embed-text preflight 2>&1) && rc=0 || rc=$?
assert_ne "an older model is refused" 0 "$rc"
assert_contains "with migration guidance" "cannot migrate stored vectors" "$out"
out=$(FAKE_CT_DOWN=true preflight 2>&1) && rc=0 || rc=$?
assert_ne "a stopped CT is refused by the helper" 0 "$rc"
assert_contains "with its CT ID" "Honcho CT 285 is not running" "$out"
out=$(FAKE_CT_TAGS='osr-target;openclaw' preflight 2>&1) && rc=0 || rc=$?
assert_ne "an untagged CT is refused" 0 "$rc"
assert_contains "before any guest operation" "CT 285 has no honcho tag" "$out"
guard_line=$(grep -n 'honcho_reconfigure_preflight "\$CT_ID"' "$provision" | tail -n1 | cut -d: -f1)
token_line=$(grep -n 'if \[\[ -z ${OPENWEBUI_ADMIN_TOKEN' "$provision" | head -n1 | cut -d: -f1)
assert_ok "the CT identity is checked before asking for the admin token" test "$guard_line" -lt "$token_line"

describe router_fw_with_honcho
# shellcheck disable=SC1090
source <(awk '/^# Router firewall helper$/{c=1;next} /^# End router firewall helper\.$/{c=0} c' "$provision")
fw=$(mktemp)
printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000 -log nolog\n' > "$fw"
updated=$(router_fw_with_honcho "$fw" 192.0.2.85 8000)
assert_eq "the rule goes first in [RULES], the rest stays" \
  "$(printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.85/32 -p tcp -dport 8000 -log nolog # osr-honcho-router\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000 -log nolog')" "$updated"
printf '%s\n' "$updated" > "$fw"
assert_eq "a rerun changes nothing" "$updated" "$(router_fw_with_honcho "$fw" 192.0.2.85 8000)"
moved=$(router_fw_with_honcho "$fw" 192.0.2.86 8001)
assert_eq "a new address or port replaces the old rule" 1 "$(grep -c 'osr-honcho-router' <<< "$moved")"
assert_contains "with the new values" "192.0.2.86/32 -p tcp -dport 8001" "$moved"
printf '[OPTIONS]\nenable: 1\n' > "$fw"
assert_contains "a file without rules gets a [RULES] section" "$(printf '[RULES]\nIN ACCEPT -source 192.0.2.85/32')" "$(router_fw_with_honcho "$fw" 192.0.2.85 8000)"
rm -f "$fw"

describe honcho_router_fw_update
# The router CT's firewall goes through targets/pve-firewall-swap.pl, here on a
# fixture /etc/pve (no Proxmox lock; its own suite covers live mode).
pve=$(mktemp -d)
mkdir -p "$pve/firewall" "$pve/stage"
router_fw=$pve/firewall/250.fw
swap_tool=$here/../pve-firewall-swap.pl
printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000\n' > "$router_fw"
cp "$router_fw" "$pve/router.orig"
status=0; out=$(honcho_router_fw_update "$router_fw" 192.0.2.85 8000 250 "$pve" "$pve/stage" "$swap_tool") || status=$?
assert_eq "the router firewall admits Honcho" 0 "$status"
assert_contains "with its rule" '192.0.2.85/32 -p tcp -dport 8000 -log nolog # osr-honcho-router' "$(cat "$router_fw")"
status=0; out=$(honcho_router_fw_update "$router_fw" 192.0.2.85 8000 250 "$pve" "$pve/stage" "$swap_tool") || status=$?
assert_eq "a rerun has nothing to do" 3 "$status"
cp "$pve/router.orig" "$router_fw"; touch "$pve/edit"
status=0; out=$(OSR_FW_SWAP_TEST_EDIT_FILE=$pve/edit TMPDIR=$pve honcho_router_fw_update "$router_fw" 192.0.2.85 8000 250 "$pve" "$pve/stage" "$swap_tool" 2>/dev/null) || status=$?
assert_eq "an edit made meanwhile stops the update" 1 "$status"
assert_contains "and is kept" '# edited meanwhile' "$(cat "$router_fw")"
assert_eq "the previous content is saved where the run says" "$(cat "$pve/router.orig")" "$(cat "$out")"
rm -f -- "$out"
cp "$pve/router.orig" "$router_fw"; touch "$pve/fail"
status=0; out=$(OSR_FW_SWAP_TEST_FAIL_FILE=$pve/fail TMPDIR=$pve honcho_router_fw_update "$router_fw" 192.0.2.85 8000 250 "$pve" "$pve/stage" "$swap_tool" 2>/dev/null) || status=$?
assert_eq "a failed write stops the update" 1 "$status"
assert_ok "and leaves the live file whole" cmp -s "$pve/router.orig" "$router_fw"
assert_eq "and saves the original" "$(cat "$pve/router.orig")" "$(cat "$out")"
rm -f -- "$out"
status=0; out=$(OSR_FW_SWAP_TEST_FAIL_FILE=$pve/fail TMPDIR=$pve/missing honcho_router_fw_update "$router_fw" 192.0.2.85 8000 250 "$pve" "$pve/stage" "$swap_tool" 2>/dev/null) || status=$?
assert_eq "a failed backup creation is reported separately" 2 "$status"
assert_eq "without claiming a backup path" '' "$out"
assert_ok "and leaves the live file whole" cmp -s "$pve/router.orig" "$router_fw"
cp() { if [[ ${3:-} == "$pve"/honcho-router-fw.* ]]; then return 1; fi; command cp "$@"; }
status=0; out=$(OSR_FW_SWAP_TEST_FAIL_FILE=$pve/fail TMPDIR=$pve honcho_router_fw_update "$router_fw" 192.0.2.85 8000 250 "$pve" "$pve/stage" "$swap_tool" 2>/dev/null) || status=$?
unset -f cp
assert_eq "a failed backup copy is reported separately" 2 "$status"
assert_eq "without claiming a partial copy" '' "$out"
assert_eq "and removes that partial copy" 0 "$(find "$pve" -maxdepth 1 -name 'honcho-router-fw.*' | wc -l | tr -d ' ')"
rm -rf -- "$pve"

describe honcho_ct_fw_update
# shellcheck disable=SC1090
source <(awk '/^# Honcho firewall helpers$/{c=1;next} /^# End Honcho firewall helpers\.$/{c=0} c' "$provision")
pve=$(mktemp -d)
mkdir -p "$pve/firewall" "$pve/stage"
ct_fw=$pve/firewall/285.fw
swap_tool=$here/../pve-firewall-swap.pl
printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.50/32 -p tcp -dport 8000 -log nolog # osr-honcho-api\nIN ACCEPT -source 192.0.2.9/32 -p tcp -dport 22\n' > "$ct_fw"
cp "$ct_fw" "$pve/ct.orig"
new_rules='IN ACCEPT -source 192.0.2.51/32 -p tcp -dport 8000 -log nolog # osr-honcho-api'
status=0; honcho_ct_fw_update "$ct_fw" "$new_rules" "$pve/stage" 285 "$pve" "$swap_tool" 2>/dev/null || status=$?
assert_eq "the owned rules are replaced" 0 "$status"
assert_contains "with the new ones" '192.0.2.51/32' "$(cat "$ct_fw")"
assert_not_contains "the old one is gone" '192.0.2.50/32' "$(cat "$ct_fw")"
assert_contains "other rules stay" '192.0.2.9/32 -p tcp -dport 22' "$(cat "$ct_fw")"
cp "$pve/ct.orig" "$ct_fw"; touch "$pve/edit"
status=0; OSR_FW_SWAP_TEST_EDIT_FILE=$pve/edit honcho_ct_fw_update "$ct_fw" "$new_rules" "$pve/stage" 285 "$pve" "$swap_tool" 2>/dev/null || status=$?
assert_eq "an edit made meanwhile stops the update" 1 "$status"
assert_eq "and is kept, alone" "$(cat "$pve/ct.orig"; printf '# edited meanwhile')" "$(cat "$ct_fw")"
rm -f "$pve/edit"; cp "$pve/ct.orig" "$ct_fw"; touch "$pve/fail"
status=0; OSR_FW_SWAP_TEST_FAIL_FILE=$pve/fail honcho_ct_fw_update "$ct_fw" "$new_rules" "$pve/stage" 285 "$pve" "$swap_tool" 2>/dev/null || status=$?
assert_eq "a failed write stops the update" 2 "$status"
assert_ok "and leaves the file whole" cmp -s "$pve/ct.orig" "$ct_fw"
rm -rf -- "$pve"

describe honcho_rules
# shellcheck disable=SC1090
source <(awk '/^# Honcho firewall helpers$/{c=1;next} /^# End Honcho firewall helpers\.$/{c=0} c' "$provision")
rules=$(honcho_rules 192.0.2.80 192.0.2.81 192.0.2.82)
assert_contains "the router reaches the API" "-source 192.0.2.80/32 -p tcp -dport 8000 -log nolog # osr-honcho-api" "$rules"
assert_contains "and MCP (Open WebUI)" "-source 192.0.2.80/32 -p tcp -dport 3000 -log nolog # osr-honcho-mcp" "$rules"
assert_contains "an agent reaches the API" "-source 192.0.2.81/32 -p tcp -dport 8000 -log nolog # osr-honcho-api" "$rules"
assert_contains "and MCP (DeepSeek Harness uses it), under its own tag" "-source 192.0.2.82/32 -p tcp -dport 3000 -log nolog # osr-honcho-client-mcp" "$rules"
assert_eq "one API and one MCP rule each" 6 "$(grep -c '^IN ACCEPT' <<< "$rules")"
fw=$(mktemp)
printf '[RULES]\n%s\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 22\n' "$rules" > "$fw"
assert_eq "a reconfigure reads back the agents, not the router" "192.0.2.81 192.0.2.82" "$(honcho_fw_clients "$fw")"
printf '[RULES]\n%s\n' "$(honcho_rules 192.0.2.80)" > "$fw"
assert_eq "no agents: an empty list" "" "$(honcho_fw_clients "$fw")"
# A Honcho CT from before agents had MCP rules reads back the same.
printf '[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8000 -log nolog # osr-honcho-api\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 3000 -log nolog # osr-honcho-mcp\nIN ACCEPT -source 192.0.2.81/32 -p tcp -dport 8000 -log nolog # osr-honcho-api\n' > "$fw"
assert_eq "older rule sets read back too" "192.0.2.81" "$(honcho_fw_clients "$fw")"
assert_contains "replacing the rules drops the agents' MCP rules too" 'osr-honcho-(api|mcp|client-mcp)$' "$(cat "$provision")"
rm -f "$fw"

describe rotation_recovery
# shellcheck disable=SC1090
source <(awk '/^# Rotation recovery helper$/{c=1;next} /^# End rotation recovery helper\.$/{c=0} c' "$provision")
stage=$(mktemp -d "${TMPDIR:-/tmp}/honcho-rotation-test.XXXXXX")
# Read by the sourced helpers.
# shellcheck disable=SC2034
CT_ID=285 ROUTER_CT_ID=280 OPENWEBUI_PORT=8080 rotation_files=(jwt-secret api-key openwebui-key clients.json)
# shellcheck disable=SC2034
rotation_stage=/root/honcho-rotation-test router_stage=/root/honcho-integration-test
# pct: logs each call; FAKE_SAME_SECRET makes cmp report an unchanged secret,
# FAIL_CT makes the Honcho CT unreachable, FAIL_WEBUI fails its restore, and
# FAIL_ROUTER_RM simulates losing router CT access during cleanup.
pct() {
  printf '%s\n' "$*" >> "$stage/calls"
  if [[ $1 == exec && $2 == 285 && $4 == true && ${FAIL_CT:-false} == true ]]; then return 1; fi
  if [[ $1 == exec && $4 == cmp ]]; then [[ ${FAKE_SAME_SECRET:-false} == true ]]; return; fi
  if [[ $1 == exec && $2 == 280 && $4 == python3 && ${FAIL_WEBUI:-false} == true ]]; then return 1; fi
  if [[ $1 == exec && $2 == 280 && $4 == rm && ${FAIL_ROUTER_RM:-false} == true ]]; then return 1; fi
  return 0
}
calls() { cat "$stage/calls"; }
: > "$stage/calls"
assert_ok "a changed secret means the keys were rotated" rotation_applied
assert_contains "compared inside the Honcho CT" "exec 285 -- cmp -s $rotation_stage/jwt-secret /etc/honcho-target/jwt-secret" "$(calls)"
FAKE_SAME_SECRET=true
assert_fail "an unchanged secret means nothing to undo" rotation_applied
unset FAKE_SAME_SECRET
FAIL_CT=true
rc=0; rotation_applied || rc=$?
assert_eq "an unreachable CT cannot prove the keys stayed unchanged" 2 "$rc"
unset FAIL_CT
: > "$stage/calls"
assert_ok "old credentials and the Open WebUI connection can be restored" restore_rotation
assert_ok "the provisioner sets aside the same files" grep -qx 'rotation_files=(jwt-secret api-key openwebui-key clients.json)' "$provision"
for file in jwt-secret api-key openwebui-key clients.json; do
  assert_contains "$file is put back" "exec 285 -- cp -a -- $rotation_stage/$file /etc/honcho-target/$file" "$(calls)"
done
assert_not_contains "the rest of honcho.env is not rolled back" "/etc/honcho-target/honcho.env" "$(calls | grep -v '^exec 285 -- python3 -c')"
assert_contains "only its JWT secret line is set, inside the CT" 'lines = ["AUTH_JWT_SECRET=" + secret' "$(calls)"
assert_contains "the gateway restarts with Honcho (it rereads the secret)" "honcho-gateway.service" "$(calls | grep 'systemctl restart')"
restart=$(calls | grep -n 'systemctl restart' | cut -d: -f1)
restore=$(calls | grep -n 'integrate-webui.py --restore' | cut -d: -f1)
assert_ok "Honcho restarts before Open WebUI gets its old connection back" test "${restart:-999}" -lt "${restore:-0}"
assert_contains "from the saved snapshot" "--restore http://127.0.0.1:8080 $router_stage/admin-token $router_stage/webui-honcho-snapshot.json" "$(calls)"
assert_contains "recovery cleans its CT copy after success" "rm -rf -- $rotation_stage" "$(calls)"
: > "$stage/calls"
FAIL_WEBUI=true
assert_fail "a failed Open WebUI restore is reported" restore_rotation
assert_not_contains "and leaves the CT copy available" "rm -rf -- $rotation_stage" "$(calls)"
unset FAIL_WEBUI
# Read by clean_router_stage.
# shellcheck disable=SC2034
router_stage_created=false rotation_pending=false
: > "$stage/calls"
warning=$(FAIL_ROUTER_RM=true clean_router_stage 2>&1)
assert_eq "a run that stopped before the router stage existed stays silent" "" "$warning"
assert_eq "and touches nothing in the router CT" "" "$(calls)"
# shellcheck disable=SC2034
router_stage_created=true
: > "$stage/calls"
# shellcheck disable=SC2034
rotation_pending=true
clean_router_stage
assert_contains "an unresolved rotation drops the admin token and new key from the router CT" \
  "exec 280 -- rm -f -- $router_stage/admin-token $router_stage/honcho-api-key $router_stage/integrate-webui.py" "$(calls)"
assert_not_contains "but keeps the saved connection" "rm -rf -- $router_stage" "$(calls)"
warning=$(FAIL_ROUTER_RM=true clean_router_stage 2>&1)
assert_contains "a failed credential cleanup warns with the router CT path" "$router_stage" "$warning"
: > "$stage/calls"
# shellcheck disable=SC2034
rotation_pending=false
clean_router_stage
assert_contains "otherwise the whole staging directory goes" "exec 280 -- rm -rf -- $router_stage" "$(calls)"
warning=$(FAIL_ROUTER_RM=true clean_router_stage 2>&1)
assert_contains "a failed whole-directory cleanup warns about the admin token" 'it may still hold an Open WebUI admin token' "$warning"
[[ $stage == "${TMPDIR:-/tmp}"/honcho-rotation-test.* ]] && rm -rf -- "$stage"

describe model_choice_helpers
unset -f pct   # the rotation cases' stand-in; these use the stubs below
# shellcheck disable=SC1090
source <(awk '/^# Model choice helpers$/{c=1;next} /^# End model choice helpers\.$/{c=0} c' "$provision")
stubs=$(mktemp -d)
cat > "$stubs/inventory.json" <<'JSON'
{"models": [
 {"server": "http://192.0.2.90:11434", "name": "qwen3:14b", "tools": true, "context_length": 65536, "params_b": 14.8, "loaded": true, "is_embedding": false},
 {"server": "http://192.0.2.90:11434", "name": "gemma3:12b", "tools": null, "context_length": 131072, "params_b": 12, "is_embedding": false},
 {"server": "http://192.0.2.90:11434", "name": "nomic-embed-text:latest", "tools": null, "context_length": 2048, "is_embedding": true}
]}
JSON
cat > "$stubs/pct" <<'STUB'
#!/usr/bin/env bash
printf 'pct %s\n' "$*" >> "$STUBS/calls"
case "$*" in
  *ROUTER_PORT*) echo 8123 ;;
  *ROUTER_API_KEY*) printf 'sk-router"key\n' ;;
  *'curl -K -'*) cat > "$STUBS/pct-curl-config"; cat "$STUBS/inventory.json" ;;
esac
STUB
cat > "$stubs/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUBS/calls"
case "$*" in
  *routing/inventory*)
    cat > "$STUBS/curl-config"
    [[ ${FAIL_HOST_CURL:-} != true ]] || exit 7
    cat "$STUBS/inventory.json" ;;
  *embeddings*)
    [[ ${FAIL_EMBED:-} != true ]] || exit 22
    while (( $# )); do [[ $1 == -o ]] && out=$2; shift; done
    python3 -c 'import json,sys; json.dump({"data": [{"embedding": [0.0] * int(sys.argv[2])}]}, open(sys.argv[1], "w"))' \
      "$out" "${STUB_DIMS:-640}" ;;
esac
STUB
chmod +x "$stubs/pct" "$stubs/curl"
export STUBS=$stubs
saved_path=$PATH; PATH="$stubs:$PATH"
inventory=$(router_inventory 280 192.0.2.80)
assert_contains "the inventory comes from the router's address" "curl -K - http://192.0.2.80:8123/routing/inventory" "$(cat "$stubs/calls")"
assert_contains "and is returned" '"qwen3:14b"' "$inventory"
assert_contains "the router key goes to curl on stdin, quoted" 'header = "Authorization: Bearer sk-router\"key"' "$(cat "$stubs/curl-config")"
assert_not_contains "never on a command line" "sk-router" "$(grep '^curl' "$stubs/calls")"
: > "$stubs/calls"
inventory=$(FAIL_HOST_CURL=true router_inventory 280 192.0.2.80)
assert_contains "a firewalled router is asked from inside its CT" "pct exec 280 -- curl -K - http://127.0.0.1:8123/routing/inventory" "$(cat "$stubs/calls")"
assert_contains "with the same key on stdin" "sk-router" "$(cat "$stubs/pct-curl-config")"
assert_contains "and its answer is used" '"qwen3:14b"' "$inventory"
lines=($'qwen3:14b\t65536-token context, loaded\thttp://192.0.2.90:11434/v1' $'qwen3:32b\t65536-token context\thttp://192.0.2.91:11434/v1')
assert_eq "Enter takes the suggestion" "qwen3:14b" "$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" <<< '' 2>/dev/null)"
assert_eq "a number takes its line" "qwen3:32b" "$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" <<< '2' 2>/dev/null)"
assert_eq "a name or tier is taken as typed" "large" "$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" <<< 'large' 2>/dev/null)"
out=$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" 2>&1 <<< $'9\nbad name\n1')
assert_contains "the list is shown with descriptions" "2) qwen3:32b  (65536-token context)" "$out"
assert_contains "a number off the list is asked again" "Choose 1-2, or type a name." "$out"
assert_contains "so is an invalid name" "Not a valid choice: bad name" "$out"
assert_eq "until an answer fits" "qwen3:14b" "$(tail -n1 <<< "$out" | sed 's/.*: //')"
assert_fail "the end of input is no choice" choose_from Model '' valid_model_name <<< ''
valid_count() { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
assert_eq "without a list a number is the value" 1024 "$(choose_from Size '' valid_count <<< '1024' 2>/dev/null)"
describe honcho_interactive_choices
if command -v script >/dev/null; then
  interactive_env=(CT_ID=285 ROUTER_CT_ID=280 ROUTER_IP=192.0.2.80 GATEWAY=192.0.2.1 IP_CIDR=192.0.2.85/24
    TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst STORAGE=local-lvm HONCHO_CLIENT_IPS=)
  # Answers: the context window (Enter: 65536), the chat model (Enter: the
  # suggestion). Nothing about embeddings is asked.
  out=$(printf '\n\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_contains "the context window is asked first, with the first-install size" "Context window the chat model serves (tokens; none = Honcho's 128k budgets) [65536]" "$out"
  assert_contains "and reaches the CT" "HONCHO_CONTEXT_TOKENS=65536" "$out"
  assert_contains "the router's inventory is read once its address is known" "Reading the models router CT 280 serves" "$out"
  assert_contains "the usable chat model is listed" "1) qwen3:14b  (65536-token context, 14.8B, loaded, on http://192.0.2.90:11434)" "$out"
  assert_contains "the ones the proxy cannot use are named, with the reason" "gemma3:12b (tool support not reported)" "$out"
  assert_not_contains "embedding models are not offered" "nomic-embed-text" "$out"
  assert_not_contains "nor asked for" "Embedding model (" "$out"
  assert_contains "and the answer reaches the plan" "chat model: qwen3:14b; embedding: qwen3-embedding-0.6b (1024 dimensions) in the Honcho CT" "$out"
  # A preset chat model: only the context window is asked.
  out=$(printf '\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" HONCHO_MODEL=large \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_not_contains "a preset chat model is not asked for" "Chat model (number" "$out"
  assert_not_contains "nor is the inventory read for it" "Reading the models" "$out"
  assert_contains "the preset is kept" "chat model: large;" "$out"
  cp "$stubs/inventory.json" "$stubs/full.json"
  printf '{"models": [{"server": "http://192.0.2.90:11434", "name": "gemma3:12b", "tools": null, "context_length": 131072}]}\n' > "$stubs/inventory.json"
  out=$(printf '\n\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_contains "with no usable model, the install is said to need one" "No model in the inventory reports tool support" "$out"
  assert_contains "and the fast tier is suggested" "Chat model (number, name or tier) [fast]" "$out"
  assert_contains "the Enter key takes it" "chat model: fast;" "$out"
  printf 'not json\n' > "$stubs/inventory.json"
  out=$(printf '\n\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_contains "an unreadable inventory is said so" "Could not read the router inventory; enter the model name yourself." "$out"
  assert_contains "and the name is still asked for" "chat model: fast;" "$out"
  mv "$stubs/full.json" "$stubs/inventory.json"
else
  printf 'SKIP honcho_interactive_choices (no script command for a terminal)\n'
fi
PATH=$saved_path
rm -rf -- "$stubs"
unset STUBS

describe honcho_guided_prompts
# Router first, then the Honcho container, then models, then agents; offers
# come from the PVE configs (router tag and gateway, agent tags).
lxc=$(mktemp -d) nostub=$(mktemp -d)
printf '#!/bin/sh\nexit 1\n' > "$nostub/curl"; cp "$nostub/curl" "$nostub/pct"; chmod +x "$nostub/curl" "$nostub/pct"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.80/24\ntags: osr-router\n' > "$lxc/280.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.94/24\ntags: osr-target;hermes\n' > "$lxc/294.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.81/24\ntags: osr-target;deepseek-harness\n' > "$lxc/281.conf"
answers=$'\n\n285\nlocal:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst\nlocal-lvm\n192.0.2.85/24\n\n\n\n\n'
out=$(PATH="$nostub:$PATH" PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc bash "$provision" --dry-run 2>&1 <<< "$answers")
order=$(sed '/== Honcho: /q' <<< "$out" | grep -oE '== [A-Za-z: ]+ ==|Router CT ID|Router IP|New Honcho CT ID|amd64 template|Root disk storage|Honcho IP/CIDR|Honcho gateway|Context window|Chat model \(|Embedding|Agent CT IPs' | paste -sd'|')
assert_eq "create asks router, container, models, agents, then the summary" \
  '== Router ==|Router CT ID|Router IP|== Honcho container ==|New Honcho CT ID|amd64 template|Root disk storage|Honcho IP/CIDR|Honcho gateway|== Honcho models ==|Context window|Chat model (|== Agents allowed to Honcho ==|Agent CT IPs|== Honcho: create ==' \
  "$order"
assert_contains "the router and its address are offered" 'Router IP [192.0.2.80]' "$out"
assert_contains "the router's gateway is offered" 'Honcho gateway [192.0.2.1]' "$out"
assert_contains "the agent CTs on this host are offered" 'Agent CT IPs (space-separated) (none to skip) [192.0.2.94 192.0.2.81]' "$out"
assert_contains "Enter admits them" 'Agent IPs allowed to Honcho: 192.0.2.94 192.0.2.81.' "$out"
assert_contains "the summary names the plan" 'Agents allowed             192.0.2.94 192.0.2.81' "$out"
assert_contains "a chosen chat model reaches the CT" 'HONCHO_MODEL=fast' "$out"
assert_contains "the summary names the local embedding model" 'Qwen3-Embedding-0.6B (1024 dimensions), llama.cpp on the CT' "$out"
out=$(PATH="$nostub:$PATH" env "${common[@]}" PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc HONCHO_CLIENT_IPS= HONCHO_MODEL=fast \
  bash "$provision" --dry-run 2>&1 <<< $'\n')
assert_not_contains "presets are not asked again" 'Router CT ID' "$out"
assert_not_contains "nor agents given as empty" 'Agent CT IPs' "$out"
out=$(PATH="$nostub:$PATH" env "${common[@]}" PVE_INTERACTIVE=true PVE_ACCEPT_DEFAULTS=true PVE_LXC_DIR=$lxc HONCHO_CLIENT_IPS= \
  bash "$provision" --dry-run 2>&1 < /dev/null)
assert_not_contains "under the OSR installer no default is asked" 'Context window the chat' "$out"
assert_contains "and the first-install window is used" 'HONCHO_CONTEXT_TOKENS=65536' "$out"
# Reconfigure: the CT to change (offered by its tag), then Router.
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.85/24\ntags: osr-target;honcho\n' > "$lxc/285.conf"
out=$(PATH="$nostub:$PATH" PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc IP_CIDR=192.0.2.85/24 \
  bash "$provision" --dry-run --reconfigure 2>&1 <<< $'\n\n\n')
order=$(sed '/== Honcho: /q' <<< "$out" | grep -oE '== [A-Za-z: ]+ ==|Honcho CT ID|Router CT ID|Router IP' | paste -sd'|')
assert_eq "reconfigure asks the CT first, then Router (its address comes from the route)" \
  '== Honcho container to reconfigure ==|Honcho CT ID|== Router ==|Router CT ID|== Honcho models ==|== Honcho: reconfigure ==' "$order"
assert_contains "the tagged Honcho CT is offered" 'Honcho CT ID [285]' "$out"
rm -rf -- "$lxc" "$nostub"

describe honcho_budget_passthrough
plan=$(env "${common[@]}" HONCHO_CONTEXT_TOKENS=32768 HONCHO_DREAM_ENABLED= bash "$provision" --dry-run)
assert_contains "set budget variables are passed on" "HONCHO_CONTEXT_TOKENS=32768" "$plan"
assert_contains "an empty one too: it returns the setting to the default" "HONCHO_DREAM_ENABLED=" "$plan"
assert_not_contains "unset ones are not, so the CT keeps its values" "HONCHO_DIALECTIC_MAX_INPUT_TOKENS" "$plan"
assert_fail "a budget with a unit is refused before any Proxmox call" env "${common[@]}" HONCHO_CONTEXT_TOKENS=32k bash "$provision" --dry-run
assert_fail "DREAM_ENABLED is true or false" env "${common[@]}" HONCHO_DREAM_ENABLED=no bash "$provision" --dry-run
provision_names=$(sed -n '/^honcho_budget_names=(/,/)/p' "$provision" | tr -d '()' | sed 's/honcho_budget_names=//' | tr -s ' \n' '\n' | grep . | sort)
helper_names=$(python3 -c 'import importlib.util,sys
spec = importlib.util.spec_from_file_location("b", sys.argv[1]); b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
print("\n".join(sorted(b.NAMES)))' "$here/budgets.py" | tr -d '\r')
assert_eq "the provisioner forwards exactly the settings budgets.py knows" "$helper_names" "$provision_names"
plan=$(env "${common[@]}" HONCHO_MODEL=auto HONCHO_STRUCTURED_OUTPUT_MODE= bash "$provision" --dry-run --reconfigure)
assert_contains "a reconfigure without HONCHO_REF keeps the CT's release" "with its recorded release (v3.5.0 if none)" "$plan"
assert_contains "set kept settings are passed on" "HONCHO_MODEL=auto" "$plan"
assert_contains "an empty one too, to clear it" "HONCHO_STRUCTURED_OUTPUT_MODE=" "$plan"
assert_not_contains "unset ones are not" "HONCHO_REF=" "$plan"
plan=$(env "${common[@]}" HONCHO_REF=v3.6.0 bash "$provision" --dry-run --reconfigure)
assert_contains "a given release is used" "with v3.6.0" "$plan"
assert_not_contains "and the guest is never handed a default it did not ask for" "HONCHO_MODEL=fast" "$(env "${common[@]}" bash "$provision" --dry-run --reconfigure)"
assert_contains "budgets.py is pushed with the guest installer" "install-target.sh budgets.py honcho-proxy.py" "$(cat "$provision")"
assert_contains "the local proxy is staged" "honcho-proxy.py direct_dispatch.py honcho-proxy.service" "$(cat "$provision")"
assert_contains "backend keys are staged for the proxy" '"$stage/backend-keys" /root/honcho-deploy/backend-keys' "$(cat "$provision")"
assert_ok "the vendored direct dispatcher matches Hermes" cmp -s "$here/direct_dispatch.py" "$here/../hermes/direct-dispatch.py"

describe honcho_guest_files
install=$here/install-target.sh
assert_contains "the guest pins a release too" 'ref=${HONCHO_REF:-v3.5.0}' "$(cat "$install")"
assert_contains "Bun comes from a checksum-pinned release zip" 'sha256sum -c --quiet' "$(cat "$install")"
assert_not_contains "and never from a piped install script" 'bun.sh/install' "$(cat "$install")"
assert_not_contains "clients get no Honcho key" 'generate_key --workspace' "$(cat "$install")"
assert_contains "Open WebUI gets its own gateway key" '/etc/honcho-target/openwebui-key' "$(cat "$provision")"
assert_contains "the gateway is pushed with the guest installer" "honcho-gateway.py honcho-clients" "$(cat "$provision")"
assert_contains "with its unit" "honcho-gateway.service; do" "$(cat "$provision")"
assert_contains "the API listens on loopback behind the gateway" '--host 127.0.0.1 --port 8010' "$(cat "$here/honcho-api.service")"
assert_contains "and MCP" 'Environment=PORT=3010' "$(cat "$here/honcho-mcp.service")"
assert_contains "the gateway runs as its own user" 'User=honcho-gateway' "$(cat "$here/honcho-gateway.service")"
assert_not_contains "and is not given the database" 'honcho.env' "$(cat "$here/honcho-gateway.service")"
assert_contains "Honcho uses a stable local chat endpoint" '%s_MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1' "$(cat "$install")"
assert_contains "Honcho asks its own embedding model" 'EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1' "$(cat "$install")"
assert_contains "which listens on loopback only" '--host 127.0.0.1 --port 8766' "$(cat "$here/honcho-embedding.service")"
assert_contains "the embedding unit is pushed with the guest installer" "honcho-mcp.service honcho-embedding.service" "$(cat "$provision")"
assert_not_contains "and no re-embedding unit" "honcho-reembed" "$(cat "$provision" "$install")"
assert_contains "the proxy runs as a dedicated user" 'User=honcho-proxy' "$(cat "$here/honcho-proxy.service")"
assert_not_contains "and never the admin key" 'cat /etc/honcho-target/api-key' "$(cat "$provision")"
for unit in honcho-api honcho-deriver; do
  assert_contains "$unit runs the locked environment" 'uv run --frozen --no-dev' "$(cat "$here/$unit.service")"
done
assert_contains "the MCP unit runs the pinned Bun" 'ExecStart=/opt/honcho-bun/bun run http' "$(cat "$here/honcho-mcp.service")"
for agent in hermes openclaw deepseek-harness; do
  assert_not_contains "$agent never takes the Honcho admin key" '/etc/honcho-target/api-key' "$(cat "$here/../$agent/provision-lxc.sh")"
done
summary
