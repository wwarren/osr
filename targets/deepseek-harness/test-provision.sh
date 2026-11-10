#!/usr/bin/env bash
# Local checks only: no Proxmox, network, or root privileges are needed.
set -Eeuo pipefail
exec </dev/null

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
provision=$here/provision-lxc.sh
installer=$here/install-target.sh
unit=$here/deepseek-harness.service
# shellcheck disable=SC2034  # read by the extracted fw_swap helper
source_dir=$here

describe dsh_syntax
assert_ok "shell syntax" bash -n "$provision" "$installer" "$here/pve-select.sh" "$here/test-install.sh"
assert_ok "firewall swap helper syntax" perl -c "$here/../pve-firewall-swap.pl"
assert_ok "pve-select.sh is the shared copy" cmp -s "$here/pve-select.sh" "$here/../hermes/pve-select.sh"

describe dsh_provision_helpers
# shellcheck disable=SC1090
source <(awk '/^# Provision helpers$/{c=1;next} /^# End provision helpers\.$/{c=0} c' "$provision")
assert_eq "a host address becomes its network" 192.0.2.0/24 "$(cidr_network 192.0.2.81/24)"
assert_eq "a /32 stays a host" 192.0.2.81/32 "$(cidr_network 192.0.2.81/32)"
assert_eq "an odd prefix" 10.0.0.0/15 "$(cidr_network 10.1.200.7/15)"
assert_eq "the MCP URL follows the API host" http://192.0.2.85:3000/mcp "$(honcho_mcp_url http://192.0.2.85:8000)"
assert_eq "an HTTPS API keeps its scheme" https://honcho.example:3000/mcp "$(honcho_mcp_url https://honcho.example/)"
assert_fail "an API URL with a path is refused" honcho_mcp_url http://192.0.2.85:8000/v3
record=$'DSH_MODEL=code-model\nDSH_HONCHO_MCP_URL=\nDSH_PORT=3080'
assert_eq "a record value is read" code-model "$(record_value "$record" DSH_MODEL)"
assert_eq "an empty one is empty" "" "$(record_value "$record" DSH_HONCHO_MCP_URL)"
assert_fail "a missing one fails" record_value "$record" DSH_VERSION
fw=$(mktemp)
printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000 -log nolog\n' > "$fw"
updated=$(router_fw_with_dsh "$fw" 192.0.2.81 8000)
assert_contains "the router admits DeepSeek first in [RULES]" \
  "$(printf '[RULES]\nIN ACCEPT -source 192.0.2.81/32 -p tcp -dport 8000 -log nolog # osr-deepseek-harness-router\nIN ACCEPT -source 192.0.2.0/24')" "$updated"
printf '%s\n' "$updated" > "$fw"
moved=$(router_fw_with_dsh "$fw" 192.0.2.82 8001)
assert_eq "a new address or port replaces the old rule" 1 "$(grep -c 'osr-deepseek-harness-router' <<< "$moved")"
assert_contains "with the new values" "192.0.2.82/32 -p tcp -dport 8001" "$moved"
printf '[OPTIONS]\nenable: 1\n' > "$fw"
assert_contains "a file without rules gets a [RULES] section" "$(printf '[RULES]\nIN ACCEPT -source 192.0.2.81/32')" "$(router_fw_with_dsh "$fw" 192.0.2.81 8000)"
printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 3080 -log nolog # osr-deepseek-harness\nIN ACCEPT -source 192.0.2.9/32 -p tcp -dport 22 -log nolog\n' > "$fw"
new_rule='IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 3081 -log nolog # osr-deepseek-harness'
transition=$(deepseek_fw_transition "$fw" "$new_rule")
assert_contains "a port change keeps the old Web UI rule during guest install" '-dport 3080 -log nolog # osr-deepseek-harness' "$transition"
assert_contains "and admits the new port during guest install" '-dport 3081 -log nolog # osr-deepseek-harness' "$transition"
assert_contains "unrelated firewall rules remain" '-source 192.0.2.9/32 -p tcp -dport 22' "$transition"
printf '%s\n' "$transition" > "$fw"
final=$(deepseek_fw_final "$fw" "$new_rule")
assert_eq "success leaves one DeepSeek firewall rule" 1 "$(grep -c '# osr-deepseek-harness$' <<< "$final")"
assert_not_contains "the old port closes after success" '-dport 3080 -log nolog # osr-deepseek-harness' "$final"
assert_contains "the new port remains after success" '-dport 3081 -log nolog # osr-deepseek-harness' "$final"
rm -f "$fw"
seen=$(mktemp) new=$(mktemp) target=$(mktemp)
printf 'old\n' > "$seen"; printf 'new\n' > "$new"; cp "$seen" "$target"
assert_ok "fw_swap replaces a file that still holds what was read" fw_swap "$target" "$seen" "$new"
assert_eq "with the new content" new "$(cat "$target")"
printf 'edited\n' > "$target"
status=0; fw_swap "$target" "$seen" "$new" || status=$?
assert_eq "fw_swap leaves a file edited meanwhile" 1 "$status"
assert_eq "untouched" edited "$(cat "$target")"
rm -f "$seen" "$new" "$target"
before=$'DSH_MODEL=fast\nDSH_PORT=3080'
assert_eq "an unchanged record: the previous service" previous "$(guest_state "$before" "$before" 3081)"
assert_eq "a new record with the new port: switched" switched "$(guest_state "$before" $'DSH_MODEL=fast\nDSH_PORT=3081' 3081)"
assert_eq "a new record with another port: unknown" unknown "$(guest_state "$before" $'DSH_MODEL=code\nDSH_PORT=3080' 3081)"
assert_eq "a new record without a port: unknown" unknown "$(guest_state "$before" 'DSH_MODEL=code' 3081)"
assert_eq "no record before or after: the previous state" previous "$(guest_state '' '' 3081)"

describe dsh_provision_dry_run
common=(ROUTER_CT_ID=250 CT_ID=281
  TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
  STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1)
plan=$(env "${common[@]}" DSH_MODEL=fast DSH_ACCESS_CIDR=192.0.2.0/24 bash "$provision" --dry-run 2>&1)
assert_contains "a dedicated unprivileged CT" '--unprivileged 1' "$plan"
assert_contains "tagged as an OSR target" '--tags ai\;ai-tools\;osr-target\;deepseek-harness' "$plan"
assert_contains "the Web UI firewall source" 'IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 3080' "$plan"
assert_contains "the model reaches the guest" 'DSH_MODEL=fast' "$plan"
assert_contains "and the router address" 'DSH_ROUTER_URL=http://\<router-ct-ip\>:8000' "$plan"
assert_contains "the pinned release by default" 'DSH_VERSION=0.2.1-rc.5' "$plan"
assert_contains "the router key goes to the deploy directory as a private file" 'router-api-key /root/deepseek-harness-deploy/router-api-key --perms 0600' "$plan"
assert_contains "the router firewall admits the CT" 'admit 192.0.2.81 to the router API in /etc/pve/firewall/250.fw' "$plan"
assert_contains "Honcho is off unless asked for" 'DSH_HONCHO_MCP_URL= DSH_OPEN_TERMINAL_URL= bash' "$plan"
plan=$(env "${common[@]}" bash "$provision" --dry-run 2>&1)
assert_contains "the default Web UI range is the CT's network, not its host address" '-source 192.0.2.0/24 -p tcp -dport 3080' "$plan"
assert_not_contains "the router firewall can be left alone" 'admit' "$(env "${common[@]}" DSH_ROUTER_FIREWALL=false bash "$provision" --dry-run 2>&1)"
plan=$(env "${common[@]}" DEEPSEEK_HARNESS_MODEL=code-model DEEPSEEK_HARNESS_CONTEXT_WINDOW=65536 bash "$provision" --dry-run 2>&1)
assert_contains "the installer's names are read too" 'DSH_MODEL=code-model DSH_CONTEXT_WINDOW=65536' "$plan"

describe dsh_provision_honcho
plan=$(env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=285 bash "$provision" --dry-run 2>&1)
assert_contains "the MCP URL is derived from the API URL" 'DSH_HONCHO_MCP_URL=http://192.0.2.85:3000/mcp' "$plan"
assert_contains "its own gateway key comes from the Honcho CT" 'take the Honcho gateway key from Honcho CT 285' "$plan"
assert_contains "and pushed as a private file" 'honcho-api-key /root/deepseek-harness-deploy/honcho-api-key --perms 0600' "$plan"
plan=$(env "${common[@]}" HONCHO_MCP_URL=https://honcho.example/mcp HONCHO_API_KEY_FILE=/dev/null bash "$provision" --dry-run 2>&1)
assert_contains "an external Honcho MCP URL is used as given" 'DSH_HONCHO_MCP_URL=https://honcho.example/mcp' "$plan"
assert_fail "Honcho needs a 32k window" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=285 DSH_CONTEXT_WINDOW=16384 bash "$provision" --dry-run
assert_fail "a Honcho URL with a path is refused" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000/v3 bash "$provision" --dry-run
assert_fail "HONCHO_CT_ID cannot be this CT" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=281 bash "$provision" --dry-run
assert_fail "an unreadable key file is refused" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_API_KEY_FILE=/nonexistent bash "$provision" --dry-run
assert_contains "the agent gets its own gateway key, pinned to osr" 'hc_connect "$HONCHO_CT_ID" "$(hc_client_name deepseek-harness "$CT_ID")"' "$(cat "$provision")"
assert_not_contains "and reads no key file in the Honcho CT" '/etc/honcho-target/' "$(cat "$provision")"
assert_contains "it is issued after the run is confirmed, beside the other pushes" 'honcho_key_from_ct == true' "$(sed -n '/install -d -m 0700 "$deploy"/,$p' "$provision")"
assert_contains "turning Honcho off revokes it" 'hc_disconnect "$honcho_prev_ct" "$(hc_client_name deepseek-harness "$CT_ID")"' "$(cat "$provision")"
assert_not_contains "never the Honcho admin key" 'cat /etc/honcho-target/api-key' "$(cat "$provision")"

describe dsh_provision_open_terminal
plan=$(env "${common[@]}" OPEN_TERMINAL_URL=http://192.0.2.70:8000/ OPEN_TERMINAL_CT_ID=270 bash "$provision" --dry-run 2>&1)
assert_contains "the guest gets the gateway URL" 'DSH_OPEN_TERMINAL_URL=http://192.0.2.70:8000 bash' "$plan"
assert_contains "the terminal CT admits this CT" "admit 192.0.2.81 in Open Terminal CT 270's firewall (# osr-open-terminal-client deepseek-harness-281)" "$plan"
assert_contains "and issues (or keeps) its key" 'open-terminal-clients issue deepseek-harness-281 --default-user default' "$plan"
plan=$(env "${common[@]}" OPEN_TERMINAL_URL=http://192.0.2.70:8000 OPEN_TERMINAL_KEY_FILE=/etc/hostname bash "$provision" --dry-run 2>&1)
assert_contains "a key issued by hand is pushed as a private file" 'open-terminal-key --perms 0600' "$plan"
assert_fail "a host name is refused (the firewall needs an address)" env "${common[@]}" OPEN_TERMINAL_URL=http://terminal:8000 bash "$provision" --dry-run
assert_fail "a URL with a path is refused" env "${common[@]}" OPEN_TERMINAL_URL=http://192.0.2.70:8000/mcp bash "$provision" --dry-run
assert_fail "OPEN_TERMINAL_CT_ID cannot be this CT" env "${common[@]}" OPEN_TERMINAL_URL=http://192.0.2.70:8000 OPEN_TERMINAL_CT_ID=281 bash "$provision" --dry-run

describe dsh_provision_refusals
assert_fail "an invalid firewall source is refused" env "${common[@]}" DSH_ACCESS_CIDR=bad bash "$provision" --dry-run
assert_fail "the router CT cannot be reused" env "${common[@]}" CT_ID=250 bash "$provision" --dry-run
assert_fail "output tokens cannot equal the context" env "${common[@]}" DSH_MAX_TOKENS=32768 bash "$provision" --dry-run
assert_fail "a moving dist-tag other than latest is refused" env "${common[@]}" DSH_VERSION=next bash "$provision" --dry-run
assert_fail "a model id with spaces is refused" env "${common[@]}" "DSH_MODEL=a b" bash "$provision" --dry-run
plan=$(env ROUTER_CT_ID=250 CT_ID=281 bash "$provision" --dry-run --reconfigure 2>&1)
assert_contains "a dry-run reconfigure plans the guest run" 'install-target.sh' "$plan"
assert_not_contains "and never creates a CT" 'pct create' "$plan"

describe dsh_guided_prompts
# An interactive run asks one section at a time: Router, then the DeepSeek
# container (ID, template, storage, address, gateway), then its settings, then
# Honcho. Offers come from the PVE configs (the router's tag, its gateway).
lxc=$(mktemp -d)
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.80/24\ntags: ai;osr-router\n' > "$lxc/250.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.85/24\ntags: ai;osr-target;honcho\n' > "$lxc/285.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.70/24\ntags: ai;osr-target;open-terminal\n' > "$lxc/270.conf"
answers=$'\n281\nlocal:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst\nlocal-lvm\n192.0.2.81/24\n\n\n\n\n\n\n\n\n\n'
out=$(PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc bash "$provision" --dry-run 2>&1 <<< "$answers")
order=$(grep -oE '== [A-Za-z: ]+ ==|Router CT ID|New DeepSeek Harness CT ID|amd64 template|Root disk storage|DeepSeek IP/CIDR|DeepSeek gateway|OSR model or tier|Context window|Max reply tokens|Web UI port|Web UI allowed from|npm release|Honcho API URL|Open Terminal URL' <<< "$out" | paste -sd'|')
assert_eq "create asks router, then container, then settings, then Honcho" \
  '== Router ==|Router CT ID|== DeepSeek Harness container ==|New DeepSeek Harness CT ID|amd64 template|Root disk storage|DeepSeek IP/CIDR|DeepSeek gateway|== DeepSeek Harness settings ==|OSR model or tier|Context window|Max reply tokens|Web UI port|Web UI allowed from|npm release|== Honcho memory ==|Honcho API URL|== Open Terminal workspace ==|Open Terminal URL|== DeepSeek Harness: create ==' \
  "$order"
assert_contains "the tagged router is offered" 'Router CT ID [250]' "$out"
assert_contains "the router's gateway is offered" 'DeepSeek gateway [192.0.2.1]' "$out"
assert_contains "the Web UI range defaults to the CT's network" 'Web UI allowed from (IPv4 CIDR) [192.0.2.0/24]' "$out"
assert_contains "the Honcho CT on this host is offered" 'Honcho API URL (none to skip) [http://192.0.2.85:8000]' "$out"
assert_contains "Enter took it: memory through Honcho's MCP" 'DSH_HONCHO_MCP_URL=http://192.0.2.85:3000/mcp' "$out"
assert_contains "and its key comes from that CT" 'take the Honcho gateway key from Honcho CT 285' "$out"
assert_contains "the Open Terminal CT on this host is offered" 'Open Terminal URL (none to skip) [http://192.0.2.70:8000]' "$out"
assert_contains "Enter took it" 'DSH_OPEN_TERMINAL_URL=http://192.0.2.70:8000' "$out"
assert_contains "and that CT issues the key" "admit 192.0.2.81 in Open Terminal CT 270's firewall" "$out"
assert_contains "the summary lists the plan" 'Network                    192.0.2.81/24 via 192.0.2.1 on vmbr0' "$out"
out=$(PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc bash "$provision" --dry-run 2>&1 <<< "${answers%$'\n\n'}"$'none\nnone\n')
assert_contains '"none" leaves Honcho off' 'Honcho memory              off' "$out"
assert_contains "and the guest gets no MCP URL" 'DSH_HONCHO_MCP_URL= DSH_OPEN_TERMINAL_URL' "$out"
out=$(env "${common[@]}" PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc bash "$provision" --dry-run 2>&1 <<< $'\n\n\n\n\n\n\n')
assert_not_contains "preset values are not asked again" 'Router CT ID' "$out"
assert_not_contains "(nor the address)" 'DeepSeek IP/CIDR' "$out"
# A reconfigure starts with the CT to change, offered by its tag, then Router.
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.81/24\ntags: ai;osr-target;deepseek-harness\n' > "$lxc/281.conf"
out=$(PVE_INTERACTIVE=true PVE_LXC_DIR=$lxc bash "$provision" --dry-run --reconfigure 2>&1 <<< $'\n\n\n\n\n\n\n\n\nnone\nnone\n')
order=$(grep -oE '== [A-Za-z: ]+ ==|DeepSeek Harness CT ID|Router CT ID' <<< "$out" | paste -sd'|')
assert_eq "reconfigure asks the CT first, then Router, then settings" \
  '== DeepSeek Harness container to reconfigure ==|DeepSeek Harness CT ID|== Router ==|Router CT ID|== DeepSeek Harness settings ==|== Honcho memory ==|== Open Terminal workspace ==|== DeepSeek Harness: reconfigure ==' "$order"
assert_contains "the tagged DeepSeek CT is offered" 'DeepSeek Harness CT ID [281]' "$out"
assert_not_contains "and never a new address" 'DeepSeek IP/CIDR' "$out"
rm -rf -- "$lxc"

describe dsh_reconfigure_firewall
# Whole reconfigure runs against a fake /etc/pve (PVE_ETC) and a stub pct: the
# Web UI port moves from 3080 to 3081 and the guest run succeeds, fails before
# or after switching, is interrupted, or races a firewall edit.
fake=$(mktemp -d)
mkdir -p "$fake/bin" "$fake/pve/nodes" "$fake/pve/firewall" "$fake/tmp"
cat > "$fake/bin/pct" <<'EOF'
#!/usr/bin/env bash
case $1 in
  status) echo 'status: running' ;;
  config) echo "description: DeepSeek Harness for Ollama Smart Router$(cat "$FAKE/description-suffix" 2>/dev/null)" ;;
  push) cp -- "$3" "$FAKE/pushed-$(basename "$4")" ;;
  exec)
    id=$2; shift 3
    case "$*" in
      'test -x /usr/local/sbin/open-terminal-clients') exit 0 ;;
      *OPEN_TERMINAL_PORT*) echo 8000 ;;
      '/usr/local/sbin/open-terminal-clients has '*) exit 1 ;;
      '/usr/local/sbin/open-terminal-clients issue '*) echo "$*" >> "$FAKE/terminal-calls"; echo ot-client-key-0123456789 ;;
      '/usr/local/sbin/open-terminal-clients revoke '*) echo "$*" >> "$FAKE/terminal-calls" ;;
      *'ip -4 -o addr'*) [[ $id == 250 ]] && echo '2: eth0 inet 192.0.2.50/24' || echo '2: eth0 inet 192.0.2.81/24' ;;
      *'/var/lib/deepseek-harness-target/rollback'*)
        [[ -e $FAKE/rollback-pending ]] && echo pending || echo clear ;;
      *'/etc/deepseek-harness/settings'*)
        [[ ! -e $FAKE/settings-unreadable ]] || exit 1
        [[ ! -e $FAKE/settings ]] || cat "$FAKE/settings" ;;
      *install-target.sh*)
        cp -- "$FAKE/pve/firewall/281.fw" "$FAKE/fw-during"
        [[ ! -e $FAKE/edit ]] || printf 'IN ACCEPT -source 192.0.2.7/32 -p tcp -dport 22\n' >> "$FAKE/pve/firewall/281.fw"
        if [[ -e $FAKE/slow ]]; then touch "$FAKE/guest-started"; sleep 2; fi
        [[ ! -e $FAKE/commit ]] || sed -i 's/^DSH_PORT=.*/DSH_PORT=3081/' "$FAKE/settings"
        [[ ! -e $FAKE/commit-model ]] || sed -i 's/^DSH_MODEL=.*/DSH_MODEL=code/' "$FAKE/settings"
        [[ ! -e $FAKE/break-settings ]] || touch "$FAKE/settings-unreadable"
        exit "$(cat "$FAKE/guest-status" 2>/dev/null || echo 0)" ;;
    esac ;;
esac
exit 0
EOF
printf '#!/bin/sh\n[ "$1" = -u ] && echo 0 || command -p id "$@"\n' > "$fake/bin/id"
printf '#!/bin/sh\nexit 0\n' > "$fake/bin/pvesh"; cp "$fake/bin/pvesh" "$fake/bin/pvesm"
chmod +x "$fake/bin/"*
reset_fake() {
  rm -f -- "$fake"/{edit,slow,commit,commit-model,break-settings,settings-unreadable,rollback-pending,swap-fail,guest-status,guest-started,fw-during,terminal-calls,pushed-open-terminal-key}
  printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 3080 -log nolog # osr-deepseek-harness\nIN ACCEPT -source 192.0.2.9/32 -p tcp -dport 22\n' > "$fake/pve/firewall/281.fw"
  printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000\n' > "$fake/pve/firewall/250.fw"
  printf 'DSH_VERSION=0.2.1-rc.5\nDSH_MODEL=fast\nDSH_PORT=3080\n' > "$fake/settings"
  cp "$fake/pve/firewall/281.fw" "$fake/ct.orig"; cp "$fake/pve/firewall/250.fw" "$fake/router.orig"
}
reconf=(env -i "PATH=$fake/bin:$PATH" "FAKE=$fake" "PVE_ETC=$fake/pve" "TMPDIR=$fake/tmp"
  "OSR_FW_SWAP_TEST_FAIL_FILE=$fake/swap-fail" NONINTERACTIVE=true
  CT_ID=281 ROUTER_CT_ID=250 DSH_PORT=3081 bash "$provision" --reconfigure)
deepseek_ports() { sed -nE 's/.*-dport ([0-9]+) .*# osr-deepseek-harness$/\1/p' "$fake/pve/firewall/281.fw" | paste -sd' '; }
stages() { find "$fake/tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

reset_fake
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a healthy reconfigure succeeds" 0 "$status"
assert_eq "both ports are open while the guest installs" '3080 3081' "$(sed -nE 's/.*-dport ([0-9]+) .*# osr-deepseek-harness$/\1/p' "$fake/fw-during" | paste -sd' ')"
assert_eq "then only the new port" 3081 "$(deepseek_ports)"
assert_contains "other CT rules stay" '-source 192.0.2.9/32 -p tcp -dport 22' "$(cat "$fake/pve/firewall/281.fw")"
assert_contains "the router admits DeepSeek" '# osr-deepseek-harness-router' "$(cat "$fake/pve/firewall/250.fw")"
assert_eq "and no staging directory is left" 0 "$(stages)"

reset_fake
# Saved from the Proxmox GUI's Notes field, the description ends in a newline.
printf '%%0Akept by the team\n' > "$fake/description-suffix"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
rm -f -- "$fake/description-suffix"
assert_eq "a description edited in the GUI is still this target's" 0 "$status"
printf ' 2\n' > "$fake/description-suffix"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
rm -f -- "$fake/description-suffix"
assert_eq "another description is refused" 1 "$status"
assert_contains "naming why" 'not this target' "$out"

reset_fake
echo 1 > "$fake/guest-status"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a failed guest run fails" 1 "$status"
assert_ok "the CT firewall is back as it was" cmp -s "$fake/ct.orig" "$fake/pve/firewall/281.fw"
assert_ok "and so is the router's" cmp -s "$fake/router.orig" "$fake/pve/firewall/250.fw"
assert_eq "no staging directory (it held the router key) is left" 0 "$(stages)"

reset_fake
echo 1 > "$fake/guest-status"; touch "$fake/commit"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a guest that fails after switching still fails the run" 1 "$status"
assert_eq "but its new port stays open, alone" 3081 "$(deepseek_ports)"
assert_contains "and the run says why" 'failed after DeepSeek switched to the new settings' "$out"

reset_fake
echo 1 > "$fake/guest-status"; touch "$fake/break-settings"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a failed guest whose settings cannot be read fails" 1 "$status"
assert_eq "and keeps both ports, as either may be serving" '3080 3081' "$(deepseek_ports)"
assert_contains "saying so" 'keeps both Web UI rules' "$out"
assert_eq "without leaving the staging directory" 0 "$(stages)"

reset_fake
echo 1 > "$fake/guest-status"; touch "$fake/commit-model"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a changed record without the new port fails" 1 "$status"
assert_eq "and keeps both ports too" '3080 3081' "$(deepseek_ports)"

reset_fake
echo 1 > "$fake/guest-status"; touch "$fake/rollback-pending"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a failed rollback before the new settings record fails" 1 "$status"
assert_eq "and keeps both ports even though the record is unchanged" '3080 3081' "$(deepseek_ports)"
assert_contains "with an unknown-state explanation" 'keeps both Web UI rules' "$out"

reset_fake
touch "$fake/swap-fail"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a firewall staging failure stops reconfigure" 1 "$status"
assert_ok "without changing the live firewall" cmp -s "$fake/ct.orig" "$fake/pve/firewall/281.fw"
kept=$(find "$fake/tmp" -mindepth 1 -maxdepth 1)
assert_ok "and keeps the original firewall backup" test -s "$kept/deepseek.fw.before"
assert_ok "without keeping the router key" test ! -e "$kept/router-api-key"
rm -rf -- "${fake:?}/tmp/"*

reset_fake
rm -f "$fake/settings"; echo 1 > "$fake/guest-status"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "with no record before or after, a failed guest" 1 "$status"
assert_ok "gets the previous CT firewall back" cmp -s "$fake/ct.orig" "$fake/pve/firewall/281.fw"

reset_fake
echo 1 > "$fake/guest-status"; touch "$fake/edit"
status=0; out=$("${reconf[@]}" 2>&1) || status=$?
assert_eq "a failed run whose firewall was edited meanwhile fails" 1 "$status"
assert_contains "the edit is kept" '-source 192.0.2.7/32 -p tcp -dport 22' "$(cat "$fake/pve/firewall/281.fw")"
assert_contains "and the run says it did not restore" 'changed during this run; it was not restored' "$out"
assert_eq "the router firewall is still restored" "$(cat "$fake/router.orig")" "$(cat "$fake/pve/firewall/250.fw")"
kept=$(find "$fake/tmp" -mindepth 1 -maxdepth 1)
assert_ok "the previous content is kept for recovery" test -s "$kept/deepseek.fw.before"
assert_ok "without the router key" test ! -e "$kept/router-api-key"
rm -rf -- "${fake:?}/tmp/"*

reset_fake
touch "$fake/slow"
"${reconf[@]}" > "$fake/out" 2>&1 &
pid=$!
for _ in $(seq 50); do [[ -e $fake/guest-started ]] && break; sleep 0.1; done
kill -TERM "$pid"
status=0; wait "$pid" || status=$?
assert_eq "an interrupted run fails" 143 "$status"
assert_eq "and keeps both ports open, as the guest may still be installing" '3080 3081' "$(deepseek_ports)"
assert_contains "telling how to finish" 'Rerun with --reconfigure to finish' "$(cat "$fake/out")"
assert_eq "without leaving the staging directory" 0 "$(stages)"
# Open Terminal on a reconfigure: the terminal CT (found by its address)
# issues the key and admits this CT; turning it off revokes both.
reset_fake
mkdir -p "$fake/lxc"
printf 'net0: name=eth0,bridge=vmbr0,ip=192.0.2.70/24,gw=192.0.2.1\n' > "$fake/lxc/270.conf"
printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\nIN ACCEPT -source 192.0.2.50/32 -p tcp -dport 8000 -log nolog\n' > "$fake/pve/firewall/270.fw"
ot_reconf() {
  env -i "PATH=$fake/bin:$PATH" "FAKE=$fake" "PVE_ETC=$fake/pve" "PVE_LXC_DIR=$fake/lxc" "TMPDIR=$fake/tmp" \
    NONINTERACTIVE=true CT_ID=281 ROUTER_CT_ID=250 "$@" bash "$provision" --reconfigure
}
status=0; out=$(ot_reconf OPEN_TERMINAL_URL=http://192.0.2.70:8000 2>&1) || status=$?
assert_eq "connecting the Open Terminal workspace succeeds" 0 "$status"
assert_file_contains "the terminal CT issues the key" 'issue deepseek-harness-281 --default-user default' "$fake/terminal-calls"
assert_eq "which is pushed as a file" ot-client-key-0123456789 "$(cat "$fake/pushed-open-terminal-key" 2>/dev/null)"
assert_file_contains "the terminal firewall admits this CT" 'IN ACCEPT -source 192.0.2.81/32 -p tcp -dport 8000 -log nolog # osr-open-terminal-client deepseek-harness-281' "$fake/pve/firewall/270.fw"
assert_file_contains "and keeps the router" '-source 192.0.2.50/32' "$fake/pve/firewall/270.fw"
reset_fake
printf 'DSH_VERSION=0.2.1-rc.5\nDSH_MODEL=fast\nDSH_PORT=3080\nDSH_OPEN_TERMINAL_URL=http://192.0.2.70:8000\n' > "$fake/settings"
status=0; out=$(ot_reconf OPEN_TERMINAL_URL= 2>&1) || status=$?
assert_eq "disconnecting succeeds" 0 "$status"
assert_file_contains "the key is revoked" 'revoke deepseek-harness-281 --missing-ok' "$fake/terminal-calls"
assert_eq "and the terminal firewall forgets this CT" 0 "$(grep -c deepseek-harness-281 "$fake/pve/firewall/270.fw")"
assert_eq "no staging directory is left" 0 "$(stages)"

rm -rf -- "$fake"

describe dsh_guest_dry_run
guest=$(env DSH_ROUTER_URL=http://192.0.2.50:8000 DSH_BIND_IP=192.0.2.81 bash "$installer" --dry-run 2>&1)
assert_contains "Node.js 24 and the pinned npm release" '@deepseek-ai/dsh@0.2.1-rc.5' "$guest"
assert_contains "a rollback-guarded service" 'deepseek-harness.service on 192.0.2.81:3080; roll back on failure' "$guest"
assert_fail "a router URL with a path is refused" env DSH_ROUTER_URL=http://192.0.2.50:8000/path DSH_BIND_IP=192.0.2.81 bash "$installer" --dry-run

describe dsh_unit
assert_file_contains "the service is unprivileged" 'User=deepseek-harness' "$unit"
assert_file_contains "its filesystem is protected" 'ProtectSystem=strict' "$unit"
assert_file_contains "keys come from the root-only env file" 'EnvironmentFile=/etc/deepseek-harness/service.env' "$unit"
assert_ok "the Web UI listens on the CT address and port" grep -q '^ExecStart=.*/current/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web.*--host .*--port ' "$unit"

describe dsh_configure
if command -v node >/dev/null && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'; then
  result=0
  output=$(node --test "$here/configure.test.mjs" 2>&1) || result=$?
  assert_eq "configure.mjs passes its mock-router tests" 0 "$result"
  (( result == 0 )) || printf '%s\n' "$output" | tail -n 30
else
  skip "configure.mjs tests" "needs Node.js 20 or newer"
fi

summary
