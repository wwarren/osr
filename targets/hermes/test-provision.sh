#!/usr/bin/env bash
# provision-lxc.sh: helpers, dry-run plans and validation, then whole runs
# against stubbed pct/pvesh/pvesm/curl (a fake Proxmox host, router CT and
# Hermes CT). No Proxmox, CT, network or real router is touched.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
common=(CT_ID=282 ROUTER_CT_ID=280 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.82/24 GATEWAY=192.0.2.1)

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/hermes-provision-test.XXXXXX")
cleanup() {
  [[ $tmp_root == "${TMPDIR:-/tmp}"/hermes-provision-test.* ]] || return
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

bash -n "$provision" || fail 'shell syntax'

# --- helpers in isolation ----------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Provision helpers/{c=1;next} /^# End provision helpers\./{c=0} c' "$provision")
[[ $(classify_router 280) == 'ct 280' && $(classify_router 192.0.2.80) == 'ssh 192.0.2.80' ]] || fail classify_router
if classify_router 99 >/dev/null; then fail 'classify_router accepted 99'; fi
[[ $(printf '192.0.2.82 dev eth0 src 192.0.2.80 uid 0\n' | route_src) == 192.0.2.80 ]] || fail route_src
[[ $(url_host http://router.lan:8000) == router.lan && $(url_port http://10.0.0.5:8001/) == 8001 ]] || fail 'url_host/url_port'
fw=$(firewall_config restricted 192.0.2.80 192.0.2.80 8000 8642)
[[ $fw == *$'policy_in: DROP\npolicy_out: DROP'* ]] || fail "restricted policies: $fw"
[[ $fw == *'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog'* ]] || fail 'inbound API rule'
[[ $(grep -c '^IN ' <<< "$fw") == 1 ]] || fail 'only one inbound rule'
# Order matters (first match wins): router, DNS, private drops, then the web.
order=$(grep -n -E 'dport 8000|udp -dport 53|-dest 192.168.0.0/16|dport 443' <<< "$fw" | cut -d: -f1 | paste -sd' ')
read -r r d p w <<< "$order"
(( r < d && d < p && p < w )) || fail "rule order: $order"
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  grep -qx "OUT DROP -dest $net -log nolog" <<< "$fw" || fail "no drop for $net"
done
fw=$(firewall_config open 192.0.2.80 192.0.2.80 8000 '')
[[ $fw == *'policy_out: ACCEPT'* && $fw != *'IN ACCEPT'* && $fw != *'OUT '* ]] || fail "open egress, no API: $fw"
pass 'helpers: router kind, route source, URL parts, and firewall rules in first-match order'

# Reconfigure rewrites only this target's rules (marked with a rule comment, or
# in the layout earlier versions wrote) and keeps every other line.
fwfile=$tmp_root/legacy.fw
upd() { hermes_fw_update "$fwfile" "$@" true 8642 > "$fwfile.new" && mv -- "$fwfile.new" "$fwfile"; }
api81='IN ACCEPT -source 192.0.2.81/32 -p tcp -dport 8643 -log nolog # ollama-smart-router hermes-api'
out81='OUT ACCEPT -dest 192.0.2.81/32 -p tcp -dport 8000 -log nolog # ollama-smart-router hermes-router'
second_rule() { awk '/^\[RULES\]$/ {getline; getline; print; exit}' "$fwfile"; }
legacy_fw() {
  cat > "$fwfile" <<'FW'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[RULES]
IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog
OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog
OUT ACCEPT -p udp -dport 53 -log nolog
# an operator's note
IN DROP -source 198.51.100.0/24 -log nolog
FW
}
legacy_fw
upd replace 192.0.2.81 8643 192.0.2.81 8000 || fail 'legacy firewall update'
[[ $(awk '/^\[RULES\]$/ {getline; print; exit}' "$fwfile") == "$api81" ]] || fail "API rule not first: $(cat "$fwfile")"
[[ $(second_rule) == "$out81" ]] || fail 'router rule not second'
grep -q '192.0.2.80' "$fwfile" && fail "old router rules remain: $(cat "$fwfile")"
for keep in 'OUT ACCEPT -p udp -dport 53 -log nolog' '# an operator'"'"'s note' 'IN DROP -source 198.51.100.0/24 -log nolog' 'policy_out: DROP'; do
  grep -qxF -- "$keep" "$fwfile" || fail "lost: $keep"
done
cp "$fwfile" "$fwfile.expected"
upd keep 192.0.2.81 8643 192.0.2.81 8000 || fail 'idempotent firewall check'
cmp -s "$fwfile" "$fwfile.expected" || fail "an unchanged reconfigure doubled the rules: $(cat "$fwfile")"
upd replace 192.0.2.81 8643 192.0.2.81 8000 || fail 'idempotent firewall update'
cmp -s "$fwfile" "$fwfile.expected" || fail 'an unchanged reconfigure changed the firewall'
upd replace 192.0.2.81 '' 192.0.2.81 8000 || fail 'closing the API port'
grep -q '^IN ACCEPT' "$fwfile" && fail 'CLI-only reconfigure left the API port open'
grep -qxF "$out81" "$fwfile" || fail 'CLI-only reconfigure dropped the router rule'
grep -qx 'IN DROP -source 198.51.100.0/24 -log nolog' "$fwfile" || fail 'CLI-only reconfigure lost an unrelated rule'
pass 'reconfigure replaces the legacy API and router rules, keeps other lines, is idempotent and closes a disabled port'

printf '[OPTIONS]\npolicy_out: DROP\n\n[RULES]\nOUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog\nOUT ACCEPT -p udp -dport 53 -log nolog\n' > "$fwfile"
hermes_fw_update "$fwfile" replace 192.0.2.81 8643 192.0.2.81 8000 false 8642 > "$fwfile.new" || fail 'legacy CLI-only firewall update'
mv -- "$fwfile.new" "$fwfile"
grep -qxF "$api81" "$fwfile" && grep -qxF "$out81" "$fwfile" || fail 'legacy CLI-only firewall was not upgraded'
grep -q '192.0.2.80' "$fwfile" && fail 'legacy CLI-only router rule remained'
pass 'a legacy CLI-only firewall gains its first API rule and updates its router rule'

legacy_fw
upd keep 192.0.2.81 8643 192.0.2.81 8000 || fail 'keeping the old rules'
grep -qxF "$api81" "$fwfile" && grep -qxF "$out81" "$fwfile" || fail 'new rules missing next to the old ones'
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog # ollama-smart-router hermes-api' "$fwfile" ||
  fail "old API rule not kept and marked: $(cat "$fwfile")"
grep -qx 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog # ollama-smart-router hermes-router' "$fwfile" || fail 'old router rule not kept'
upd replace 192.0.2.81 8643 192.0.2.81 8000 || fail 'dropping the kept rules'
grep -q '192.0.2.80' "$fwfile" && fail 'kept rules survived the final update'
pass 'before the guest step the new rules are added next to the old ones; afterwards only the new ones stay'

# Proxmox's GUI keeps rule comments but may move rules and drops comment lines.
cat > "$fwfile" <<FW
[OPTIONS]
policy_out: DROP

[RULES]
IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog
OUT ACCEPT -dest 203.0.113.10/32 -p tcp -dport 5432 -log nolog
$api81
$out81
FW
upd replace 192.0.2.82 8642 192.0.2.82 8000 || fail 'moved, marked rules'
grep -qx 'IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog' "$fwfile" || fail "an operator rule like ours was removed: $(cat "$fwfile")"
grep -qx 'OUT ACCEPT -dest 203.0.113.10/32 -p tcp -dport 5432 -log nolog' "$fwfile" || fail 'an operator outbound rule was removed'
grep -q '192.0.2.81' "$fwfile" && fail 'moved, marked rules not replaced'
[[ $(awk '/^\[RULES\]$/ {getline; print; exit}' "$fwfile") == *'192.0.2.82/32 -p tcp -dport 8642'* ]] || fail 'owned rules not back at the top'
# The first version of this fix wrapped the API rule in BEGIN/END lines.
cat > "$fwfile" <<'FW'
[OPTIONS]
policy_out: DROP

[RULES]
# BEGIN ollama-smart-router Hermes API
IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog
# END ollama-smart-router Hermes API
OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog
OUT ACCEPT -p udp -dport 53 -log nolog
FW
upd replace 192.0.2.81 8643 192.0.2.81 8000 || fail 'BEGIN/END layout'
grep -q 'BEGIN\|END\|192.0.2.80' "$fwfile" && fail "BEGIN/END layout not converted: $(cat "$fwfile")"
[[ $(second_rule) == "$out81" ]] || fail 'BEGIN/END layout: router rule'
grep -qx 'OUT ACCEPT -p udp -dport 53 -log nolog' "$fwfile" || fail 'BEGIN/END layout: DNS rule lost'
# Open egress: no outbound rule is added.
printf '[OPTIONS]\npolicy_out: ACCEPT\n\n[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog\n' > "$fwfile"
upd replace 192.0.2.81 8643 192.0.2.81 8000 || fail 'open egress'
grep -q '^OUT' "$fwfile" && fail 'open egress got an outbound rule'
grep -qxF "$api81" "$fwfile" || fail 'open egress: API rule'
pass 'owned rules are found by their comment wherever they are; earlier layouts are converted; open egress stays open'

refused() {
  cp "$fwfile" "$fwfile.expected"
  if hermes_fw_update "$fwfile" replace 192.0.2.82 8644 192.0.2.82 8000 "${2:-true}" 8642 > /dev/null 2> "$fwfile.err"; then fail "accepted: $1"; fi
  grep -q 'inspect\|Malformed' "$fwfile.err" || fail "no reason for: $1"
  cmp -s "$fwfile" "$fwfile.expected" || fail "modified: $1"
}
printf '[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog\nIN ACCEPT -source 192.0.2.81/32 -p tcp -dport 8643 -log nolog\n' > "$fwfile"
refused 'two unmarked API-like rules'
printf '[RULES]\nIN DROP -source 198.51.100.0/24 -log nolog\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog\n' > "$fwfile"
refused 'an unmarked API-like rule that is not first'
printf '[OPTIONS]\npolicy_out: DROP\n\n[RULES]\nOUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog\nOUT ACCEPT -dest 10.9.9.9/32 -p tcp -dport 5432 -log nolog\n' > "$fwfile"
refused 'two unmarked router-like rules'
printf '[RULES]\n# BEGIN ollama-smart-router Hermes API\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog\n' > "$fwfile"
refused 'a BEGIN line without END'
printf '[RULES]\n[RULES]\n' > "$fwfile"
refused 'two [RULES] sections'
legacy_fw
sed -i 's/-dport 8642/-dport 22/' "$fwfile"
refused 'an unmarked inbound rule whose port differs from the prior API port'
printf '[OPTIONS]\npolicy_out: DROP\n\n[RULES]\nIN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog\nOUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog\n' > "$fwfile"
refused 'a custom inbound rule in a legacy CLI-only firewall' false
legacy_fw
refused 'an unmarked rule on the API port of a CT that was CLI-only' false
pass 'a file whose Hermes rules cannot be told apart is refused and left as it is'

# --- dry-run plans and validation ------------------------------------------------
has() { [[ $output == *"$1"* ]] || fail "missing: $1"$'\n'"$output"; }
lacks() { [[ $output != *"$1"* ]] || fail "unexpected: $1"$'\n'"$output"; }
# split ARG...: VAR=value arguments into vars, --flags into flags.
split() {
  vars=(); flags=()
  local arg
  for arg in "$@"; do
    if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi
  done
}
plan() {
  split "$@"
  output=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" bash "$provision" --dry-run "${flags[@]}" 2>&1) ||
    fail "plan: $output"
}
reject() {
  local reason=$1; shift
  split "$@"
  if output=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" bash "$provision" --dry-run "${flags[@]}" 2>&1); then
    fail "accepted: $*"
  fi
  has "$reason"; lacks '+ pct create '
}

plan
has '+ pct create 282 local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst'
has '--unprivileged 1'
has 'read ROUTER_API_KEY from /app/router/secrets.env on router CT 280 into a 0600 file'
has 'IN ACCEPT -source <router-source-ip>/32 -p tcp -dport 8642'
has 'policy_out: DROP'
has '/root/hermes-deploy/router-api-key --perms 0600'
has 'HERMES_API_SERVER=true'
has 'ROUTER_URL=http://\<router-source-ip\>:8000'
has 'integrate-webui.py --webui-url http://127.0.0.1:8080 --hermes-url http://192.0.2.82:8642/v1'
has '--task-model fast'
pass 'the default plan reads the router key, firewalls the API to the router, installs and registers Hermes'

plan OPENWEBUI=false
has 'HERMES_API_SERVER=false'
lacks 'IN ACCEPT'; lacks 'integrate-webui.py --webui-url'; lacks 'pct pull'
plan EGRESS=open ROUTER_URL=http://10.1.2.3:8001 TASK_MODEL=
has 'policy_out: ACCEPT'; lacks 'OUT DROP'; has 'ROUTER_URL=http://10.1.2.3:8001'
has "--task-model ''"
pass 'OPENWEBUI=false is CLI-only; EGRESS=open, ROUTER_URL and a blank TASK_MODEL are honoured'

plan --reconfigure
lacks '+ pct create'; lacks 'write /etc/pve/firewall'
has '+ check the Hermes rules in /etc/pve/firewall/282.fw'
has '+ sync Hermes API rule in /etc/pve/firewall/282.fw'
has '/root/hermes-deploy/install-target.sh'; has 'integrate-webui.py'
plan --integrate-only
lacks '+ pct create'; lacks 'install-target.sh'; has 'pct pull 282 /etc/hermes-target/api-key'
pass '--reconfigure reruns the installer and registration; --integrate-only only registers'

reject 'CT_ID must be numeric' CT_ID=99
reject 'Hermes and router CT IDs must differ' CT_ID=280
reject 'at least 64000' HERMES_CONTEXT_LENGTH=32768
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'EGRESS must be' EGRESS=none
reject 'reserved by Hermes' HERMES_API_PORT=8644
reject 'TASK_MODEL must be a router model' TASK_MODEL=hermes-agent
reject 'no /v1' ROUTER_URL=http://r:8000/v1
reject 'needs OPENWEBUI=true' OPENWEBUI=false --integrate-only
reject 'Use only one' --reconfigure --integrate-only
reject 'Set only one of ROUTER' ROUTER=281
pass 'invalid CT, context, network, port and mode settings are refused before any Proxmox call'

# --- whole runs against a fake Proxmox host ----------------------------------------
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
fake=$tmp_root/fake; mkdir -p "$fake/pve/nodes" "$fake/pve/firewall" "$fake/ct282" "$fake/router"
export FAKE_LOG=$log FAKE_DIR=$fake
router_key=sk-router-0123456789abcdef
admin_token=owui-admin-token-secret
hermes_key=hermes-api-key-0123456789
export FAKE_ROUTER_KEY=$router_key FAKE_HERMES_KEY=$hermes_key
# pct: the router CT (280) and the Hermes CT (282).
cat > "$bin/pct" <<'PCT'
#!/usr/bin/env bash
printf 'pct' >> "$FAKE_LOG"; printf ' %q' "$@" >> "$FAKE_LOG"; printf '\n' >> "$FAKE_LOG"
cmd=$1 id=$2; shift 2
case $cmd in
  status) [[ -e $FAKE_DIR/ct$id || $id == 280 ]] && echo 'status: running' ;;
  create) mkdir -p "$FAKE_DIR/ct$id" ;;
  start) : ;;
  push) cp "$1" "$FAKE_DIR/pushed-$id-$(basename "$2")" ;;
  pull) [[ $1 == /etc/hermes-target/api-key ]] && printf '%s\n' "$FAKE_HERMES_KEY" > "$2" ;;
  exec)
    [[ $1 == -- ]] && shift
    all="$*"
    if [[ $id == 280 ]]; then
      case $all in
        'test -f /app/router/router.py') exit 0 ;;
        awk*secrets.env) [[ -n ${FAKE_NO_ROUTER_KEY:-} ]] || printf '%s\n' "$FAKE_ROUTER_KEY" ;;
        *ROUTER_PORT*) echo 8000 ;;
        *PORT=*openwebui*) echo 8080 ;;
        'systemctl is-active --quiet open-webui.service') exit 0 ;;
        *'command -v python3'*) exit 0 ;;
        'python3 -c '*) echo 0.6.5 ;;
        'ip -4 route get '*) echo "$5 dev eth0 src 192.0.2.80 uid 0" ;;
        'mktemp -d /root/hermes-integration.XXXXXX') echo /root/hermes-integration.AbC123 ;;
        python3\ /root/hermes-integration.AbC123/integrate-webui.py*)
          cp "$FAKE_DIR/pve/firewall/282.fw" "$FAKE_DIR/fw-at-integrate" 2>/dev/null || : > "$FAKE_DIR/fw-at-integrate"
          [[ $(cat "$FAKE_DIR/pushed-280-admin-token") == "$FAKE_ADMIN" ]] || exit 9
          [[ $(cat "$FAKE_DIR/pushed-280-hermes-api-key") == "$FAKE_HERMES_KEY" ]] || exit 9
          echo 'Open WebUI connection 1 added and verified.' ;;
        'rm -rf -- /root/hermes-integration.AbC123') : ;;
        *) echo "unexpected router command: $all" >&2; exit 3 ;;
      esac
    else
      case $all in
        'test -f /etc/hermes-target/settings') [[ -e $FAKE_DIR/ct$id/installed ]] ;;
        'cat /etc/hermes-target/settings')
          [[ -e $FAKE_DIR/ct$id/installed ]] || exit 1
          printf 'HERMES_API_SERVER=%s\nHERMES_API_PORT=%s\n' \
            "$(cat "$FAKE_DIR/ct$id/api-state")" "$(cat "$FAKE_DIR/ct$id/api-port")" ;;
        'test -s /etc/hermes-target/api-key') [[ -e $FAKE_DIR/ct$id/api-server ]] ;;
        sh\ -c\ *ip\ -4\ -o\ addr*) echo 192.0.2.82 ;;
        sh\ -c\ test\ -d\ /run/systemd/system*) exit 0 ;;
        'install -d -m 0700 /root/hermes-deploy') : ;;
        env\ *install-target.sh) touch "$FAKE_DIR/ct$id/installed"
          cp "$FAKE_DIR/pve/firewall/$id.fw" "$FAKE_DIR/fw-at-guest" 2>/dev/null || : > "$FAKE_DIR/fw-at-guest"
          [[ -z ${FAKE_FW_EDIT:-} ]] || printf '[RULES]\n' >> "$FAKE_DIR/pve/firewall/$id.fw"
          [[ $all =~ HERMES_API_SERVER=(true|false) ]] && server=${BASH_REMATCH[1]}
          [[ $all =~ HERMES_API_PORT=([0-9]+) ]] && port=${BASH_REMATCH[1]}
          printf '%s\n' "${server:-false}" > "$FAKE_DIR/ct$id/api-state"
          printf '%s\n' "${port:-8642}" > "$FAKE_DIR/ct$id/api-port"
          if [[ $server == true ]]; then touch "$FAKE_DIR/ct$id/api-server"; else rm -f "$FAKE_DIR/ct$id/api-server"; fi
          exit "${FAKE_GUEST_RC:-0}" ;;
        *) echo "unexpected CT command: $all" >&2; exit 3 ;;
      esac
    fi ;;
esac
PCT
chmod +x "$bin/pct"
cat > "$bin/pvesh" <<'EOF'
#!/usr/bin/env bash
echo "pvesh $*" >> "$FAKE_LOG"; [[ ! -e $FAKE_DIR/ct282 || -n ${FAKE_FREE_ID:-} ]]
EOF
cat > "$bin/pvesm" <<'EOF'
#!/usr/bin/env bash
echo "pvesm $*" >> "$FAKE_LOG"
case $1 in path) echo "$FAKE_DIR/template" ;; status) printf 'Name Type Status\nlocal-lvm lvmthin active\n' ;; esac
EOF
printf '#!/usr/bin/env bash\necho pve-manager/9\n' > "$bin/pveversion"
# id: root unless FAKE_UID says otherwise, so these runs need no real root.
printf '#!/usr/bin/env bash\n[[ $1 == -u ]] && echo "${FAKE_UID:-0}"\n' > "$bin/id"
mkdir -p "$fake/net/lo"
# curl on the host: the router probe, which must carry the key in a header file.
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
hdr=''
while (( $# )); do [[ $1 == -H && $2 == @* ]] && hdr=$(cat "${2#@}"); shift; done
[[ -n ${FAKE_ROUTER_REJECTS:-} ]] && { printf 401; exit 0; }
[[ $hdr == "Authorization: Bearer $FAKE_ROUTER_KEY" || -n ${FAKE_NO_ROUTER_KEY:-} ]] && printf 200 || printf 401
EOF
chmod +x "$bin"/*
touch "$fake/template"

real() {
  split "$@"
  env -i "PATH=$bin:$PATH" PVE_ETC="$fake/pve" SYS_NET_DIR="$fake/net" BRIDGE=lo FAKE_LOG="$log" FAKE_DIR="$fake" \
    FAKE_ROUTER_KEY="$router_key" FAKE_HERMES_KEY="$hermes_key" FAKE_ADMIN="$admin_token" \
    OPENWEBUI_ADMIN_TOKEN="$admin_token" "${common[@]}" "${vars[@]}" bash "$provision" "${flags[@]}" 2>&1
}
reset_fake() { rm -rf -- "${fake:?}/ct282" "$fake"/pushed-* "$fake"/fw-at-* "$fake/pve/firewall/282.fw"; : > "$log"; }
secrets_in_argv() { grep -E -- "$router_key|$admin_token|$hermes_key" "$log" || true; }

stages_before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'hermes-setup.*' | wc -l)
reset_fake
out=$(real) || fail "full run: $out"
[[ $(cat "$fake/pushed-282-router-api-key") == "$router_key" ]] || fail 'the router key was not pushed to the CT'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
grep -q 'install-target.sh' "$log" && grep -q 'HERMES_API_SERVER=true' "$log" || fail 'guest installer not run with the API server'
grep -q 'ROUTER_URL=http://192.0.2.80:8000' "$log" || fail 'ROUTER_URL not derived from the router address'
fwfile=$fake/pve/firewall/282.fw
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog # ollama-smart-router hermes-api' "$fwfile" || fail "firewall: $(cat "$fwfile")"
grep -qx 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog # ollama-smart-router hermes-router' "$fwfile" || fail 'router egress rule'
grep -q -- '--hermes-url http://192.0.2.82:8642/v1' "$log" || fail 'integration URL'
grep -q 'rm -rf -- /root/hermes-integration.AbC123' "$log" || fail 'the router staging directory was not removed'
[[ $out == *'Open WebUI connection 1 added'* && $out == *'hermes-agent'* ]] || fail "summary: $out"
grep -q 'pct create 282' "$log" || fail 'no CT created'
pass 'a full run pushes the router key as a file, firewalls the API to the router and registers it; no secret is in argv'

reset_fake
out=$(real OPENWEBUI=false OPENWEBUI_ADMIN_TOKEN=) || fail "CLI-only run: $out"
grep -q 'integrate-webui.py' "$log" && fail 'CLI-only run registered with Open WebUI'
grep -q '^IN ' "$fake/pve/firewall/282.fw" && fail 'CLI-only run opened an inbound port'
grep -q 'HERMES_API_SERVER=false' "$log" || fail 'CLI-only run enabled the API server'
pass 'OPENWEBUI=false needs no admin token, opens no port and runs no API server'

reset_fake
out=$(real FAKE_ROUTER_REJECTS=1) && fail 'a rejected router key was accepted'
[[ $out == *'rejected the key'* ]] || fail "rejected key message: $out"
grep -q 'pct create' "$log" && fail 'a CT was created although the router rejected the key'
reset_fake
out=$(real FAKE_NO_ROUTER_KEY=1) || fail "router without a key: $out"
[[ $out == *'has no ROUTER_API_KEY'* ]] || fail 'a router without a key is not reported'
[[ ! -e $fake/pushed-282-router-api-key ]] || fail 'an empty key file was pushed'
pass 'a router that rejects its own key stops before pct create; a router without a key is reported'

reset_fake
out=$(real FAKE_GUEST_RC=1) && fail 'a failed guest install was accepted'
[[ $out == *'re-run with --reconfigure'* ]] || fail "failure hint: $out"
pass 'a failed guest install keeps the CT and points to --reconfigure'

# --reconfigure and --integrate-only on the CT made above.
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure) || fail "reconfigure: $out"
grep -q 'pct create' "$log" && fail '--reconfigure created a CT'
[[ $(cat "$fake/pushed-282-router-api-key") == "$router_key" ]] || fail '--reconfigure did not push the current key'
grep -q 'integrate-webui.py' "$log" || fail '--reconfigure did not register again'
: > "$log"
out=$(real --integrate-only) || fail "integrate-only: $out"
grep -q 'install-target.sh' "$log" && fail '--integrate-only ran the installer'
grep -q 'pct pull 282 /etc/hermes-target/api-key' "$log" || fail '--integrate-only did not read the CT key'
rm -f "$fake/ct282/api-server"
out=$(real --integrate-only) && fail '--integrate-only accepted a CT without an API server'
[[ $out == *'runs no Hermes API server'* ]] || fail "no API server message: $out"
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
pass '--reconfigure pushes the current router key and re-registers; --integrate-only needs an API server'

# --reconfigure and the CT's firewall. The fake CT records the firewall file
# when the guest installer and Open WebUI's check run.
fwfile=$fake/pve/firewall/282.fw
api80='IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8642 -log nolog # ollama-smart-router hermes-api'
reset_fake
out=$(real OPENWEBUI=false OPENWEBUI_ADMIN_TOKEN=) || fail "CLI-only run: $out"
: > "$log"
out=$(real --reconfigure) || fail "CLI-only to Open WebUI: $out"
grep -qxF "$api80" "$fake/fw-at-integrate" || fail "the router was not admitted before Open WebUI checked Hermes: $(cat "$fake/fw-at-integrate")"
[[ $(grep -c '^IN ' "$fwfile") == 1 ]] || fail "API rule count: $(cat "$fwfile")"
pass '--reconfigure of a CLI-only CT with OPENWEBUI=true opens the API port to the router before Open WebUI checks it'

: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 HERMES_API_PORT=8643) || fail "router move: $out"
grep -q 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000' "$fake/fw-at-guest" &&
  grep -q 'OUT ACCEPT -dest 192.0.2.90/32 -p tcp -dport 8000' "$fake/fw-at-guest" ||
  fail "the guest step did not reach the old and the new router: $(cat "$fake/fw-at-guest")"
grep -q '192.0.2.80' "$fwfile" && fail "the old router address is still admitted: $(cat "$fwfile")"
grep -qx 'IN ACCEPT -source 192.0.2.90/32 -p tcp -dport 8643 -log nolog # ollama-smart-router hermes-api' "$fwfile" || fail 'new API rule'
grep -qx 'OUT ACCEPT -dest 192.0.2.90/32 -p tcp -dport 8000 -log nolog # ollama-smart-router hermes-router' "$fwfile" || fail 'new router rule'
grep -qx 'OUT ACCEPT -p tcp -dport 443 -log nolog' "$fwfile" || fail 'the other egress rules were lost'
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 HERMES_API_PORT=8650 FAKE_GUEST_RC=1) && fail 'a failed guest step was accepted'
grep -q 'dport 8643 ' "$fwfile" && grep -q 'dport 8650 ' "$fwfile" || fail "a failed reconfigure closed the working port: $(cat "$fwfile")"
printf "%s\n" "$out" >&2
cp "$fwfile" "$fwfile.clean"
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 HERMES_API_PORT=8643 FAKE_FW_EDIT=1) && fail 'a firewall edited during the run was accepted'
[[ $out == *'changed meanwhile'* ]] || fail "edited firewall message: $out"
grep -q 'integrate-webui.py' "$log" && fail 'Open WebUI registration ran after the firewall update failed'
cp "$fwfile.clean" "$fwfile"
pass '--reconfigure follows a router move and port change in both directions; a failed guest step keeps the old rules'

printf 'IN ACCEPT -source 198.51.100.7/32 -p tcp -dport 8642 -log nolog\n' >> "$fwfile"
sed -i 's/ # ollama-smart-router hermes-[a-z]*$//' "$fwfile"
cp "$fwfile" "$fwfile.before"
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 HERMES_API_PORT=8650) && fail 'an unreadable firewall was accepted'
[[ $out == *'inspect it before reconfiguring'* && $out == *'Nothing was changed'* ]] || fail "ambiguity message: $out"
grep -q 'install-target.sh\|pct push' "$log" && fail 'the CT was changed although the firewall was refused'
cmp -s "$fwfile" "$fwfile.before" || fail 'the refused firewall file was modified'
rm -f -- "$fwfile"
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 HERMES_API_PORT=8650) || fail "missing firewall file: $out"
[[ $out == *'does not exist'* ]] || fail "missing firewall warning: $out"
[[ ! -e $fwfile ]] || fail 'a firewall file was created for a CT that had none'
pass '--reconfigure stops before changing the CT when its firewall is ambiguous, and leaves a missing firewall missing'

reset_fake
out=$(real OPENWEBUI=false OPENWEBUI_ADMIN_TOKEN=) || fail "legacy CLI-only run: $out"
fwfile=$fake/pve/firewall/282.fw
sed -i 's/ # ollama-smart-router hermes-router$//' "$fwfile"
sed -i '/^\[RULES\]$/a IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog' "$fwfile"
cp "$fwfile" "$fwfile.before"
: > "$log"
out=$(real --reconfigure) && fail 'a legacy CLI-only CT lost a custom inbound rule'
[[ $out == *'Cannot tell which inbound rule'* && $out == *'Nothing was changed'* ]] || fail "legacy CLI-only warning: $out"
grep -q 'install-target.sh\|pct push' "$log" && fail 'the guest changed despite the ambiguous legacy firewall'
cmp -s "$fwfile" "$fwfile.before" || fail 'a legacy CLI-only custom rule was changed'
pass 'a legacy CLI-only CT keeps an unmarked custom inbound rule and stops before changing the guest'

# The usual upgrade: a CT made by the previous version, API server on a
# non-default port, rules without the comment. The prior state and port come
# from the CT's /etc/hermes-target/settings.
reset_fake
out=$(real HERMES_API_PORT=8643) || fail "API server on 8643: $out"
sed -i 's/ # ollama-smart-router hermes-[a-z]*$//' "$fwfile"
grep -q 'ollama-smart-router' "$fwfile" && fail 'test setup: the legacy layout still has comments'
: > "$log"
out=$(real --reconfigure HERMES_API_PORT=8643) || fail "legacy upgrade with the API server: $out"
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8643 -log nolog # ollama-smart-router hermes-api' "$fwfile" ||
  fail "legacy API rule not adopted: $(cat "$fwfile")"
grep -qx 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog # ollama-smart-router hermes-router' "$fwfile" ||
  fail 'legacy router rule not adopted'
[[ $(grep -c '^IN ' "$fwfile") == 1 && $(grep -c 'dport 8000 ' "$fwfile") == 1 ]] || fail "legacy rules duplicated: $(cat "$fwfile")"
grep -q 'integrate-webui.py' "$log" || fail 'the upgraded CT was not registered again'
pass 'a CT from the previous version with its API server on 8643 is upgraded: both rules adopted and marked'

reset_fake
out=$(real FAKE_UID=1000) && fail 'a run without root was accepted'
[[ $out == *'Run as root'* ]] || fail "no-root message: $out"
grep -q '^pct ' "$log" && fail 'a run without root reached Proxmox'
reset_fake
rmdir "$fake/net/lo"
out=$(real) && fail 'a missing bridge was accepted'
[[ $out == *'Bridge does not exist: lo'* ]] || fail "missing bridge message: $out"
grep -q 'pct create' "$log" && fail 'a CT was created without its bridge'
mkdir -p "$fake/net/lo"; reset_fake
pass 'a run without root, or without its bridge, is refused before anything is created'

[[ $(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'hermes-setup.*' | wc -l) == "$stages_before" ]] ||
  fail 'a run left its host staging directory (it can hold the router key) behind'
pass 'every run, failed or not, removes its host staging directory'

printf '%s provision cases passed. No CT was created.\n' "$passed"
