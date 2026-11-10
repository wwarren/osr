#!/usr/bin/env bash
# provision-lxc.sh: helpers, dry-run plans and validation, then whole runs
# against stubbed pct/pvesh/pvesm/curl (a fake Proxmox host, router CT and
# OpenClaw CT). No Proxmox, CT, network or real router is touched.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
common=(CT_ID=283 ROUTER_CT_ID=280 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.83/24 GATEWAY=192.0.2.1)

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/openclaw-provision-test.XXXXXX")
cleanup() {
  [[ $tmp_root == "${TMPDIR:-/tmp}"/openclaw-provision-test.* ]] || return
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

bash -n "$provision" || fail 'shell syntax'
cmp -s "$here/pve-select.sh" "$here/../pve-select.sh" || fail 'pve-select.sh is not the shared copy'

# --- helpers in isolation ----------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Provision helpers/{c=1;next} /^# End provision helpers\./{c=0} c' "$provision")
[[ $(classify_router 280) == 'ct 280' && $(classify_router 192.0.2.80) == 'ssh 192.0.2.80' ]] || fail classify_router
if classify_router 99 >/dev/null; then fail 'classify_router accepted 99'; fi
[[ $(printf '192.0.2.83 dev eth0 src 192.0.2.80 uid 0\n' | route_src) == 192.0.2.80 ]] || fail route_src
[[ $(url_host http://router.lan:8000) == router.lan && $(url_port http://10.0.0.5:8001/) == 8001 ]] || fail 'url_host/url_port'
fw=$(firewall_config restricted 192.0.2.80 192.0.2.80 8000 18789)
[[ $fw == *$'policy_in: DROP\npolicy_out: DROP'* ]] || fail "restricted policies: $fw"
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-api' <<< "$fw" || fail 'inbound API rule'
[[ $(grep -c '^IN ' <<< "$fw") == 1 ]] || fail 'only one inbound rule without the Control UI'
# Order matters (first match wins): router, DNS, private drops, then the web.
order=$(grep -n -E 'dport 8000|udp -dport 53|-dest 192.168.0.0/16|dport 443' <<< "$fw" | cut -d: -f1 | paste -sd' ')
read -r r d p w <<< "$order"
(( r < d && d < p && p < w )) || fail "rule order: $order"
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  grep -qx "OUT DROP -dest $net -log nolog" <<< "$fw" || fail "no drop for $net"
done
fw=$(firewall_config open 192.0.2.80 192.0.2.80 8000 '')
[[ $fw == *'policy_out: ACCEPT'* && $fw != *'IN ACCEPT'* && $fw != *'OUT '* ]] || fail "open egress, no API: $fw"
fw=$(firewall_config restricted 192.0.2.80 192.0.2.80 8000 18789 18789)
grep -qx 'IN ACCEPT -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-dashboard' <<< "$fw" || fail 'Control UI inbound rule'
pass 'helpers: router kind, route source, URL parts, and firewall rules in first-match order'

inv=$tmp_root/inventory.json
printf '{"enabled":true,"servers":["http://plain.lan","maya+https://secure.lan/","strata+http://10.0.0.5:8080","http://10.0.0.5:8080"]}\n' > "$inv"
[[ $(inventory_endpoints "$inv") == $'plain.lan 80\nsecure.lan 443\n10.0.0.5 8080' ]] ||
  fail "inventory endpoints: $(inventory_endpoints "$inv" 2>&1)"
for bad in http://h:0 http://h:99999 ftp://h:21 http://user@h:80 'http://h:80?x=1'; do
  printf '{"enabled":true,"servers":["%s"]}\n' "$bad" > "$inv"
  if inventory_endpoints "$inv" >/dev/null 2>&1; then fail "inventory endpoint accepted: $bad"; fi
done
printf '{"enabled":true,"servers":["strata+http://192.168.11.154:8080","http://192.168.11.153:11434/","maya+https://GPU.lan","lmstudio+http://10.0.0.5:8080"]}\n' > "$inv"
expected='strata-192-168-11-154-8080=strata+http://192.168.11.154:8080
ollama-192-168-11-153-11434=http://192.168.11.153:11434
maya-gpu-lan-443-29eaec1a9229=maya+https://GPU.lan
lmstudio-10-0-0-5-8080=lmstudio+http://10.0.0.5:8080'
[[ $(inventory_targets "$inv") == "$expected" ]] || fail "inventory targets: $(inventory_targets "$inv" 2>&1)"
# The names match the Hermes target's, so both agents call a server the same.
# shellcheck disable=SC1090
hermes_targets=$(source <(awk '/^inventory_targets\(\)/,/^}/' "$here/../hermes/provision-lxc.sh"); inventory_targets "$inv")
[[ $hermes_targets == "$expected" ]] || fail 'direct target names differ from the Hermes target'
printf '{"enabled":true,"servers":["kindi+http://10.0.0.14:8093"]}\n' > "$inv"
[[ $(inventory_targets "$inv") == 'kindi-10-0-0-14-8093=kindi+http://10.0.0.14:8093' ]] ||
  fail "a Kindi server is not its own kind of target: $(inventory_targets "$inv" 2>&1)"
printf '{"enabled":false,"servers":[]}\n' > "$inv"
if inventory_targets "$inv" >/dev/null 2>&1; then fail 'targets read from a router with discovery off'; fi
pass "inventory: endpoints default to 80/443, bad URLs are refused, target names are Hermes's"

# Reconfigure rewrites only this target's rules, found by their comment, and
# keeps every other line.
fwfile=$tmp_root/owned.fw
upd() { openclaw_fw_update "$fwfile" "$@" > "$fwfile.new" && mv -- "$fwfile.new" "$fwfile"; }
api81='IN ACCEPT -source 192.0.2.81/32 -p tcp -dport 18790 -log nolog # ollama-smart-router openclaw-api'
out81='OUT ACCEPT -dest 192.0.2.81/32 -p tcp -dport 8000 -log nolog # ollama-smart-router openclaw-router'
cat > "$fwfile" <<'FW'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[RULES]
IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog
IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-api
IN ACCEPT -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-dashboard
OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog # ollama-smart-router openclaw-router
OUT ACCEPT -dest 192.0.2.71/32 -p tcp -dport 8080 -log nolog # ollama-smart-router openclaw-model
OUT ACCEPT -dest 203.0.113.10/32 -p tcp -dport 5432 -log nolog
OUT ACCEPT -p udp -dport 53 -log nolog
# an operator's note
IN DROP -source 198.51.100.0/24 -log nolog
FW
# shellcheck disable=SC2034  # read by openclaw_fw_rules
model_rules=('OUT ACCEPT -dest 192.0.2.72/32 -p tcp -dport 8080 -log nolog # ollama-smart-router openclaw-model')
upd replace 192.0.2.81 18790 192.0.2.81 8000 18790 || fail 'firewall update'
[[ $(awk '/^\[RULES\]$/ {getline; print; exit}' "$fwfile") == "$api81" ]] || fail "API rule not first: $(cat "$fwfile")"
grep -qxF "$out81" "$fwfile" || fail 'router rule'
grep -qx 'IN ACCEPT -p tcp -dport 18790 -log nolog # ollama-smart-router openclaw-dashboard' "$fwfile" || fail 'Control UI rule'
grep -qx 'OUT ACCEPT -dest 192.0.2.72/32 -p tcp -dport 8080 -log nolog # ollama-smart-router openclaw-model' "$fwfile" || fail 'model rule'
grep -q -e '192.0.2.80' -e '192.0.2.71' -e 'dport 18789' "$fwfile" && fail "old owned rules remain: $(cat "$fwfile")"
for keep in 'IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog' 'OUT ACCEPT -dest 203.0.113.10/32 -p tcp -dport 5432 -log nolog' \
            'OUT ACCEPT -p udp -dport 53 -log nolog' '# an operator'"'"'s note' 'IN DROP -source 198.51.100.0/24 -log nolog' 'policy_out: DROP'; do
  grep -qxF -- "$keep" "$fwfile" || fail "lost: $keep"
done
cp "$fwfile" "$fwfile.expected"
upd keep 192.0.2.81 18790 192.0.2.81 8000 18790 || fail 'idempotent firewall check'
cmp -s "$fwfile" "$fwfile.expected" || fail "an unchanged reconfigure doubled the rules: $(cat "$fwfile")"
upd keep 192.0.2.82 18790 192.0.2.82 8000 18790 || fail 'keeping the old rules'
grep -qxF "$api81" "$fwfile" && grep -q '192.0.2.82/32 -p tcp -dport 18790' "$fwfile" || fail 'new rules missing next to the old ones'
upd replace 192.0.2.82 '' 192.0.2.82 8000 '' || fail 'closing the ports'
grep -q '^IN ACCEPT.*openclaw' "$fwfile" && fail 'API and Control UI ports left open'
grep -q '192.0.2.81' "$fwfile" && fail 'kept rules survived the final update'
grep -qx 'IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog' "$fwfile" || fail 'an operator rule was removed'
printf '[OPTIONS]\npolicy_out: ACCEPT\n\n[RULES]\n%s\n' "$api81" > "$fwfile"
upd replace 192.0.2.81 18790 192.0.2.81 8000 '' || fail 'open egress'
grep -q '^OUT' "$fwfile" && fail 'open egress got an outbound rule'
printf '[RULES]\n[RULES]\n' > "$fwfile"; cp "$fwfile" "$fwfile.expected"
if openclaw_fw_update "$fwfile" replace 192.0.2.82 18789 192.0.2.82 8000 '' > /dev/null 2> "$fwfile.err"; then fail 'two [RULES] sections accepted'; fi
grep -q 'inspect' "$fwfile.err" && cmp -s "$fwfile" "$fwfile.expected" || fail 'two [RULES] sections: no reason, or the file changed'
pass 'reconfigure replaces only the commented OpenClaw rules, wherever they are; keeps other lines; is idempotent; closes disabled ports'

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
has '+ pct create 283 local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst'
has '--unprivileged 1'
has '--tags ai\;ai-tools\;osr-target\;openclaw'
has '--features nesting=1'
has '--hostname openclaw'
has 'read ROUTER_API_KEY from /app/router/secrets.env on router CT 280 into a 0600 file'
has 'IN ACCEPT -source <router-source-ip>/32 -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-api'
has 'IN ACCEPT -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-dashboard'
has 'policy_out: DROP'
has '/root/openclaw-deploy/router-api-key --perms 0600'
has '/hermes/direct-dispatch.py /root/openclaw-deploy/direct-dispatch.py'
has 'OPENCLAW_API=true'
has 'OPENCLAW_DASHBOARD=true'
has 'ROUTER_URL=http://\<router-source-ip\>:8000'
has 'OPENCLAW_VERSION=latest'
has 'OPENCLAW_NODE_VERSION=24'
lacks 'NVM_INSTALLER_SHA256='
has 'integrate-webui.py --webui-url http://127.0.0.1:8080 --openclaw-url http://192.0.2.83:18789/v1'
has '--model-name openclaw'
has '--task-model fast'
has '+ resolve model server host names inside CT 283 and admit their addresses'
pass 'the default plan reads the router key, firewalls the API to the router, installs and registers OpenClaw'

plan OPENWEBUI=false
has 'OPENCLAW_API=false'
lacks 'openclaw-api'; has 'openclaw-dashboard'; lacks 'integrate-webui.py --webui-url'; lacks 'pct pull'
plan OPENWEBUI=false OPENCLAW_DASHBOARD=false
lacks 'IN ACCEPT'
plan EGRESS=open ROUTER_URL=http://10.1.2.3:8001 TASK_MODEL= OPENCLAW_PORT=18800 NVM_INSTALLER_SHA256=
has 'policy_out: ACCEPT'; lacks 'OUT DROP'; has 'ROUTER_URL=http://10.1.2.3:8001'
has "--task-model ''"; has '--openclaw-url http://192.0.2.83:18800/v1'; has 'NVM_INSTALLER_SHA256='
pass 'OPENWEBUI=false keeps the API closed; EGRESS=open, ROUTER_URL, the port, a blank TASK_MODEL and an nvm pin are honoured'

plan --reconfigure
lacks '+ pct create'; lacks 'write /etc/pve/firewall'
has '+ check the OpenClaw rules in /etc/pve/firewall/283.fw'
has '+ sync OpenClaw rules in /etc/pve/firewall/283.fw'
has '/root/openclaw-deploy/install-target.sh'; has 'integrate-webui.py'
plan --integrate-only
lacks '+ pct create'; lacks 'install-target.sh'; has 'pct pull 283 /etc/openclaw-target/api-key'
pass '--reconfigure reruns the installer and registration; --integrate-only only registers'

reject 'CT_ID must be numeric' CT_ID=99
reject 'Set CT_ID for unattended provisioning' CT_ID=
reject 'Set CT_ID for unattended provisioning' --reconfigure CT_ID=
reject 'Set TEMPLATE for unattended provisioning' TEMPLATE=
reject 'Set STORAGE for unattended provisioning' STORAGE=
reject 'Set IP_CIDR for unattended provisioning' IP_CIDR=
reject 'Set GATEWAY for unattended provisioning' GATEWAY=
reject 'OpenClaw and router CT IDs must differ' CT_ID=280
reject 'at least 32768' OPENCLAW_CONTEXT_LENGTH=16384
reject 'OPENCLAW_MAX_TOKENS must be' OPENCLAW_MAX_TOKENS=40000
reject 'OPENCLAW_VERSION must be' 'OPENCLAW_VERSION=1.0;x'
reject 'OPENCLAW_NODE_VERSION must be' OPENCLAW_NODE_VERSION=22
reject 'NVM_VERSION must be' NVM_VERSION=master
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'EGRESS must be' EGRESS=none
reject 'OPENCLAW_DASHBOARD must be' OPENCLAW_DASHBOARD=yes
reject 'is the local dispatcher' OPENCLAW_PORT=8765
reject 'TASK_MODEL must be a router model' TASK_MODEL=openclaw
reject 'TASK_MODEL must be a router model' TASK_MODEL=openclaw/default
reject 'no /v1' ROUTER_URL=http://r:8000/v1
reject 'needs OPENWEBUI=true' OPENWEBUI=false --integrate-only
reject 'Use only one' --reconfigure --integrate-only
reject 'Set only one of ROUTER' ROUTER=281
pass 'invalid CT, context, versions, network, port and mode settings are refused before any Proxmox call'

# --- whole runs against a fake Proxmox host ----------------------------------------
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
fake=$tmp_root/fake; mkdir -p "$fake/pve/nodes" "$fake/pve/firewall" "$fake/router"
export FAKE_LOG=$log FAKE_DIR=$fake
router_key=sk-router-0123456789abcdef
admin_token=owui-admin-token-secret
openclaw_key=openclaw-gateway-token-0123456789
export FAKE_ROUTER_KEY=$router_key FAKE_OPENCLAW_KEY=$openclaw_key
# pct: the router CT (280) and the OpenClaw CT (283).
cat > "$bin/pct" <<'PCT'
#!/usr/bin/env bash
printf 'pct' >> "$FAKE_LOG"; printf ' %q' "$@" >> "$FAKE_LOG"; printf '\n' >> "$FAKE_LOG"
cmd=$1 id=$2; shift 2
case $cmd in
  status) [[ -e $FAKE_DIR/ct$id || $id == 280 ]] && echo 'status: running' ;;
  create) printf 'pct-create-umask %s\n' "$(umask)" >> "$FAKE_LOG"; mkdir -p "$FAKE_DIR/ct$id"
    printf 'description: OpenClaw for Ollama Smart Router\n' > "$FAKE_DIR/ct$id/description" ;;
  config) cat "$FAKE_DIR/ct$id/description" ;;
  start) : ;;
  push) cp "$1" "$FAKE_DIR/pushed-$id-$(basename "$2")"
    [[ $(basename "$2") != honcho-api-key ]] || cp "$1" "$FAKE_DIR/ct$id/honcho-key"
    [[ $(basename "$2") != open-terminal-key ]] || cp "$1" "$FAKE_DIR/ct$id/ot-key" ;;
  pull) [[ $1 == /etc/openclaw-target/api-key ]] && printf '%s\n' "$FAKE_OPENCLAW_KEY" > "$2" ;;
  exec)
    [[ $1 == -- ]] && shift
    all="$*"
    if [[ $id == 270 ]]; then
      # The Open Terminal CT: its gateway port and client keys (hash only).
      case $all in
        'test -x /usr/local/sbin/open-terminal-clients') exit 0 ;;
        sed\ -n\ *OPEN_TERMINAL_PORT*) echo 8000 ;;
        '/usr/local/sbin/open-terminal-clients has '*)
          [[ $(cat "$FAKE_DIR/ot-${3}.sha" 2>/dev/null) == "$4" ]] ;;
        '/usr/local/sbin/open-terminal-clients issue '*' --default-user default')
          n=$(( $(cat "$FAKE_DIR/ot-issued" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/ot-issued"
          key="ot-client-key-$n-0123456789"
          printf '%s' "$key" | sha256sum | cut -d' ' -f1 > "$FAKE_DIR/ot-${3}.sha"
          printf '%s\n' "$key" ;;
        '/usr/local/sbin/open-terminal-clients revoke '*' --missing-ok') rm -f "$FAKE_DIR/ot-${3}.sha" ;;
        *) echo "unexpected terminal command: $all" >&2; exit 3 ;;
      esac
    elif [[ $id == 280 ]]; then
      case $all in
        'test -f /app/router/router.py') exit 0 ;;
        python3\ -c\ *router.ini) echo 5400 ;;
        awk*LMSTUDIO_API_TOKEN*secrets.env) printf 'STRATA_API_KEY=sk-backend-secret\n' ;;
        awk*secrets.env) [[ -n ${FAKE_NO_ROUTER_KEY:-} ]] || printf '%s\n' "$FAKE_ROUTER_KEY" ;;
        *ROUTER_PORT*) echo 8000 ;;
        *PORT=*openwebui*) echo 8080 ;;
        'systemctl is-active --quiet open-webui.service') exit 0 ;;
        *'command -v python3'*) exit 0 ;;
        'python3 -c '*) echo 0.12.4 ;;
        'ip -4 route get '*) echo "$5 dev eth0 src 192.0.2.80 uid 0" ;;
        'mktemp -d /root/openclaw-integration.XXXXXX') echo /root/openclaw-integration.AbC123 ;;
        python3\ /root/openclaw-integration.AbC123/integrate-webui.py*)
          cp "$FAKE_DIR/pve/firewall/283.fw" "$FAKE_DIR/fw-at-integrate" 2>/dev/null || : > "$FAKE_DIR/fw-at-integrate"
          [[ $(cat "$FAKE_DIR/pushed-280-admin-token") == "$FAKE_ADMIN" ]] || exit 9
          [[ $(cat "$FAKE_DIR/pushed-280-openclaw-api-key") == "$FAKE_OPENCLAW_KEY" ]] || exit 9
          echo 'Open WebUI connection 1 added and verified.' ;;
        'rm -rf -- /root/openclaw-integration.AbC123') : ;;
        *) echo "unexpected router command: $all" >&2; exit 3 ;;
      esac
    else
      case $all in
        'test -f /etc/openclaw-target/settings') [[ -e $FAKE_DIR/ct$id/installed ]] ;;
        'grep -qx OPENCLAW_API=true /etc/openclaw-target/settings') [[ -e $FAKE_DIR/ct$id/api-on ]] ;;
        sh\ -c\ *ip\ -4\ -o\ addr*) echo 192.0.2.83 ;;
        getent\ ahostsv4\ *)
          # The CT's own resolver: FAKE_CT_DNS='name=ip,ip;name=ip'.
          [[ -e $FAKE_DIR/ct$id ]] || exit 2
          name=${all#getent ahostsv4 }; found=2
          IFS=';' read -r -a pairs <<< "${FAKE_CT_DNS:-}"
          for pair in "${pairs[@]}"; do
            [[ ${pair%%=*} == "$name" ]] || continue
            IFS=',' read -r -a addrs <<< "${pair#*=}"
            for a in "${addrs[@]}"; do printf '%s STREAM %s\n%s DGRAM\n%s RAW\n' "$a" "$name" "$a" "$a"; done
            found=0
          done
          exit "$found" ;;
        sh\ -c\ test\ -d\ /run/systemd/system*) exit 0 ;;
        sh\ -c\ sed\ *HONCHO_URL*) cat "$FAKE_DIR/ct$id/honcho-url" 2>/dev/null || : ;;
        sh\ -c\ sed\ *OPEN_TERMINAL_URL*) cat "$FAKE_DIR/ct$id/ot-url" 2>/dev/null || : ;;
        sh\ -c\ \[\ -s\ /root/openclaw-deploy/open-terminal-key*)
          [[ -s $FAKE_DIR/ct$id/ot-key ]] && tr -d '\r\n\t ' < "$FAKE_DIR/ct$id/ot-key" | sha256sum | cut -d' ' -f1 ;;
        'test -s /root/openclaw-deploy/honcho-api-key') [[ -s $FAKE_DIR/ct$id/honcho-key ]] ;;
        # The Honcho CT's gateway clients: a key per client in $FAKE_DIR/honcho-client-<name>.
        sh\ -c\ *openclaw-deploy/honcho-api-key*)
          [[ -s $FAKE_DIR/ct$id/honcho-key ]] && tr -d '\r\n\t ' < "$FAKE_DIR/ct$id/honcho-key" | sha256sum | cut -d' ' -f1 ;;
        'test -x /usr/local/sbin/honcho-clients') [[ $id == 285 ]] ;;
        '/usr/local/sbin/honcho-clients has '*)
          [[ -s $FAKE_DIR/honcho-client-$3 ]] && [[ $(tr -d '\n' < "$FAKE_DIR/honcho-client-$3" | sha256sum | cut -d' ' -f1) == "$4" ]] ;;
        '/usr/local/sbin/honcho-clients issue '*)
          printf '%s\n' "$FAKE_HONCHO_KEY" | tee "$FAKE_DIR/honcho-client-$3" ;;
        '/usr/local/sbin/honcho-clients revoke '*) rm -f "$FAKE_DIR/honcho-client-$3" ;;
        'install -d -m 0700 /root/openclaw-deploy') : ;;
        env\ *install-target.sh)
          printf '%s\n' "$all" > "$FAKE_DIR/guest-env"
          cp "$FAKE_DIR/pve/firewall/$id.fw" "$FAKE_DIR/fw-at-guest" 2>/dev/null || : > "$FAKE_DIR/fw-at-guest"
          [[ -z ${FAKE_FW_EDIT:-} ]] || printf '[RULES]\n' >> "$FAKE_DIR/pve/firewall/$id.fw"
          [[ -z ${FAKE_SWAP_EDIT_AT_GUEST:-} ]] || touch "$FAKE_DIR/swap-edit"
          [[ ${FAKE_GUEST_RC:-0} == 0 ]] || exit "$FAKE_GUEST_RC"
          touch "$FAKE_DIR/ct$id/installed"
          if [[ $all =~ HONCHO_URL=([^\ ]*) ]]; then printf '%s\n' "${BASH_REMATCH[1]}" > "$FAKE_DIR/ct$id/honcho-url"; fi
          if [[ $all =~ OPEN_TERMINAL_URL=([^\ ]*) ]]; then printf '%s\n' "${BASH_REMATCH[1]}" > "$FAKE_DIR/ct$id/ot-url"; fi
          if [[ $all == *OPENCLAW_API=true* ]]; then touch "$FAKE_DIR/ct$id/api-on"; else rm -f "$FAKE_DIR/ct$id/api-on"; fi
          exit 0 ;;
        *) echo "unexpected CT command: $all" >&2; exit 3 ;;
      esac
    fi ;;
esac
PCT
chmod +x "$bin/pct"
cat > "$bin/pvesh" <<'EOF'
#!/usr/bin/env bash
echo "pvesh $*" >> "$FAKE_LOG"; [[ ! -e $FAKE_DIR/ct283 || -n ${FAKE_FREE_ID:-} ]]
EOF
cat > "$bin/pvesm" <<'EOF'
#!/usr/bin/env bash
echo "pvesm $*" >> "$FAKE_LOG"
case $1 in path) echo "$FAKE_DIR/template" ;; status) printf 'Name Type Status\nlocal-lvm lvmthin active\n' ;; esac
EOF
printf '#!/usr/bin/env bash\necho pve-manager/9\n' > "$bin/pveversion"
# The HOST's resolver gives other answers: model server names must not use it.
printf '#!/usr/bin/env bash\necho "getent $*" >> "$FAKE_LOG"\necho "198.51.100.99 STREAM $3"\n' > "$bin/getent"
# id: root unless FAKE_UID says otherwise, so these runs need no real root.
printf '#!/usr/bin/env bash\n[[ $1 == -u ]] && echo "${FAKE_UID:-0}"\n' > "$bin/id"
mkdir -p "$fake/net/lo"
# curl on the host: the router probe, which must carry the key in a header file.
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
hdr='' out='' url=''
while (( $# )); do
  if [[ $1 == -H && $2 == @* ]]; then hdr=$(cat "${2#@}"); shift 2
  elif [[ $1 == -o ]]; then out=$2; shift 2
  elif [[ $1 == http* ]]; then url=$1; shift
  else shift; fi
done
[[ -n ${FAKE_ROUTER_REJECTS:-} ]] && { printf 401; exit 0; }
if [[ $hdr == "Authorization: Bearer $FAKE_ROUTER_KEY" || -n ${FAKE_NO_ROUTER_KEY:-} ]]; then
  if [[ $url == */routing/inventory ]]; then
    servers=${FAKE_INVENTORY_SERVERS:-strata+http://${FAKE_MODEL_SERVER:-192.0.2.71}:8080}
    json=$(printf '"%s",' ${servers//,/ })
    printf '{"enabled":true,"servers":[%s],"models":[]}\n' "${json%,}" > "$out"
  fi
  printf 200
else printf 401; fi
EOF
chmod +x "$bin"/*
python_cmd=${PYTHON_FOR_TEST:-$(command -v python3)}
printf '#!/usr/bin/env bash\nset -o pipefail\n"%s" "$@" | tr -d "\\r"\n' "$python_cmd" > "$bin/python3"
chmod +x "$bin/python3"
touch "$fake/template"

real() {
  split "$@"
  env -i "PATH=$bin:$PATH" PVE_ETC="$fake/pve" SYS_NET_DIR="$fake/net" BRIDGE=lo FAKE_LOG="$log" FAKE_DIR="$fake" \
    FAKE_ROUTER_KEY="$router_key" FAKE_OPENCLAW_KEY="$openclaw_key" FAKE_ADMIN="$admin_token" \
    OPENWEBUI_ADMIN_TOKEN="$admin_token" "${common[@]}" "${vars[@]}" bash "$provision" "${flags[@]}" 2>&1
}
reset_fake() { rm -rf -- "${fake:?}/ct283" "$fake"/pushed-* "$fake"/fw-at-* "$fake/guest-env" "$fake/pve/firewall/283.fw"; : > "$log"; }
honcho_key=honcho-osr-key-0123456789
secrets_in_argv() { grep -E -- "$router_key|$admin_token|$openclaw_key|$honcho_key|ot-client-key-" "$log" || true; }
fwfile=$fake/pve/firewall/283.fw

stages_before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'openclaw-setup.*' | wc -l)
reset_fake
out=$(real) || fail "full run: $out"
[[ $(cat "$fake/pushed-283-router-api-key") == "$router_key" ]] || fail 'the router key was not pushed to the CT'
[[ $(cat "$fake/pushed-283-backend-keys") == 'STRATA_API_KEY=sk-backend-secret' ]] || fail 'the backend key was not pushed to the CT'
[[ $(cat "$fake/pushed-283-targets") == 'strata-192-0-2-71-8080=strata+http://192.0.2.71:8080' ]] ||
  fail "the direct targets were not pushed: $(cat "$fake/pushed-283-targets" 2>&1)"
cmp -s "$fake/pushed-283-direct-dispatch.py" "$here/../hermes/direct-dispatch.py" || fail "the Hermes target's dispatcher was not pushed"
[[ -f $fake/pushed-283-openclaw-gateway.service && -f $fake/pushed-283-openclaw-direct.service ]] || fail 'units not pushed'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
guest_env=$(< "$fake/guest-env")
for want in ROUTER_URL=http://192.0.2.80:8000 OPENCLAW_API=true OPENCLAW_DASHBOARD=true OPENCLAW_PORT=18789 KINDI_READ_TIMEOUT_SECONDS=5400 \
            OPENCLAW_MODEL=auto OPENCLAW_CONTEXT_LENGTH=65536 OPENCLAW_NODE_VERSION=24 NVM_VERSION=v0.40.4; do
  [[ " $guest_env " == *" $want "* ]] || fail "guest installer not given $want: $guest_env"
done
[[ $guest_env != *NVM_INSTALLER_SHA256* ]] || fail 'an unset nvm pin must leave the guest default in force'
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-api' "$fwfile" || fail "firewall: $(cat "$fwfile")"
grep -qx 'IN ACCEPT -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-dashboard' "$fwfile" || fail 'Control UI firewall rule'
grep -qx 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog # ollama-smart-router openclaw-router' "$fwfile" || fail 'router egress rule'
grep -qx 'OUT ACCEPT -dest 192.0.2.71/32 -p tcp -dport 8080 -log nolog # ollama-smart-router openclaw-model' "$fwfile" || fail 'model egress rule'
grep -q -- '--openclaw-url http://192.0.2.83:18789/v1' "$log" || fail 'integration URL'
grep -qxF "IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-api" "$fake/fw-at-integrate" ||
  fail 'the router was not admitted before Open WebUI checked OpenClaw'
grep -q 'rm -rf -- /root/openclaw-integration.AbC123' "$log" || fail 'the router staging directory was not removed'
[[ $out == *'Open WebUI connection 1 added'* && $out == *'choose "openclaw"'* ]] || fail "summary: $out"
[[ $out == *'Control UI: http://192.0.2.83:18789/'* && $out == *'devices approve'* ]] || fail "Control UI summary: $out"
grep -q 'pct create 283' "$log" || fail 'no CT created'
grep -qx 'pct-create-umask 0022' "$log" || fail 'pct create inherited a restrictive umask'
grep -q 'pct create 283.*--features nesting=1' "$log" || fail 'the OpenClaw CT was created without nesting'
pass 'a full run pushes the keys as files, the shared dispatcher and units; firewalls the API to the router and registers it; no secret is in argv'

out=$(real --reconfigure OPENCLAW_DASHBOARD=false) || fail "Control UI off: $out"
grep -q 'openclaw-dashboard' "$fwfile" && fail 'Control UI rule remained after disabling it'
[[ $(< "$fake/guest-env") == *OPENCLAW_DASHBOARD=false* ]] || fail 'guest did not receive the Control UI setting'
out=$(real --reconfigure) || fail "Control UI on again: $out"
[[ $(grep -c 'openclaw-dashboard$' "$fwfile") == 1 && $(grep -c 'openclaw-api$' "$fwfile") == 1 ]] || fail 'rules were not restored exactly once'
pass 'reconfigure closes and restores the Control UI firewall port with OPENCLAW_DASHBOARD'

reset_fake
out=$(real OPENWEBUI=false OPENCLAW_DASHBOARD=false OPENWEBUI_ADMIN_TOKEN=) || fail "no Open WebUI run: $out"
grep -q 'integrate-webui.py' "$log" && fail 'a run without Open WebUI registered with it'
grep -q '^IN ' "$fwfile" && fail 'a run without Open WebUI or the Control UI opened an inbound port'
[[ $(< "$fake/guest-env") == *OPENCLAW_API=false* ]] || fail 'the chat endpoint was enabled'
pass 'OPENWEBUI=false and OPENCLAW_DASHBOARD=false need no admin token or inbound port'

reset_fake
out=$(real NVM_INSTALLER_SHA256=0000000000000000000000000000000000000000000000000000000000000000 OPENCLAW_VERSION=2026.10.9) ||
  fail "pinned run: $out"
[[ $(< "$fake/guest-env") == *NVM_INSTALLER_SHA256=0000*' '*OPENCLAW_VERSION=2026.10.9* ||
   $(< "$fake/guest-env") == *OPENCLAW_VERSION=2026.10.9*NVM_INSTALLER_SHA256=0000* ]] || fail "pins not passed: $(< "$fake/guest-env")"
pass 'nvm and OpenClaw pins reach the guest installer'

reset_fake
out=$(real FAKE_ROUTER_REJECTS=1) && fail 'a rejected router key was accepted'
[[ $out == *'rejected the key'* ]] || fail "rejected key message: $out"
grep -q 'pct create' "$log" && fail 'a CT was created although the router rejected the key'
reset_fake
out=$(real FAKE_NO_ROUTER_KEY=1) || fail "router without a key: $out"
[[ $out == *'has no ROUTER_API_KEY'* ]] || fail 'a router without a key is not reported'
[[ ! -e $fake/pushed-283-router-api-key ]] || fail 'an empty key file was pushed'
pass 'a router that rejects its own key stops before pct create; a router without a key is reported'

reset_fake
out=$(real FAKE_GUEST_RC=1) && fail 'a failed guest install was accepted'
[[ $out == *'re-run with --reconfigure'* ]] || fail "failure hint: $out"
[[ ! -e $fake/ct283/installed ]] || fail 'the failed guest install wrote completed settings'
pass 'a failed guest install leaves an incomplete CT and points to --reconfigure'

# --reconfigure and --integrate-only on the CT made above.
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure) || fail "reconfigure: $out"
grep -q 'pct create' "$log" && fail '--reconfigure created a CT'
[[ -e $fake/ct283/installed ]] || fail '--reconfigure did not complete the partial guest install'
[[ $out == *'resuming its partial installation'* ]] || fail "no partial-install recovery notice: $out"
[[ $(cat "$fake/pushed-283-router-api-key") == "$router_key" ]] || fail '--reconfigure did not push the current key'
grep -q 'integrate-webui.py' "$log" || fail '--reconfigure did not register again'
: > "$log"
out=$(real --reconfigure FAKE_MODEL_SERVER=192.0.2.72) || fail "changed model server: $out"
grep -qx 'OUT ACCEPT -dest 192.0.2.72/32 -p tcp -dport 8080 -log nolog # ollama-smart-router openclaw-model' "$fwfile" || fail 'new model server not admitted'
grep -q '192.0.2.71/32.*openclaw-model' "$fwfile" && fail 'old model server still admitted'
# Honcho: given once, kept by a plain --reconfigure, turned off with HONCHO_URL=.
honcho_rule='OUT ACCEPT -dest 192.0.2.85/32 -p tcp -dport 8000 -log nolog # ollama-smart-router openclaw-model'
: > "$log"; rm -f "$fake"/pushed-*
honcho_lxc=$fake/honcho-lxc; mkdir -p "$honcho_lxc"
printf 'net0: name=eth0,bridge=vmbr0,ip=192.0.2.85/24,gw=192.0.2.1\n' > "$honcho_lxc/285.conf"
out=$(real --reconfigure HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=285 FAKE_HONCHO_KEY=$honcho_key) || fail "Honcho on: $out"
grep -q 'pct exec 285 -- /usr/local/sbin/honcho-clients issue openclaw-283 --workspace openclaw-283' "$log" ||
  fail 'the key must be this CT'"'"'s own gateway key, pinned to its own workspace'
grep -q 'cat /etc/honcho-target' "$log" && fail 'no key file is read from the Honcho CT'
[[ $(cat "$fake/pushed-283-honcho-api-key") == "$honcho_key" ]] || fail 'the Honcho key was not pushed as a file'
grep -qxF "$honcho_rule" "$fwfile" || fail "Honcho egress rule: $(cat "$fwfile")"
grep -q 'HONCHO_URL=http://192.0.2.85:8000' "$log" || fail 'the guest did not get HONCHO_URL'
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure PVE_LXC_DIR="$honcho_lxc" FAKE_HONCHO_KEY=honcho-rotated-key-0123456789) || fail "plain reconfigure: $out"
[[ $out == *'Keeping Honcho memory at http://192.0.2.85:8000'* ]] || fail "no keep notice: $out"
grep -q 'pct exec 285 -- /usr/local/sbin/honcho-clients has openclaw-283 [0-9a-f]* --workspace openclaw-283' "$log" || fail 'the kept key was not checked with the Honcho CT'
grep -q 'honcho-clients issue' "$log" && fail 'a key Honcho accepts was replaced'
grep -qxF "$honcho_rule" "$fwfile" || fail 'a plain reconfigure dropped the Honcho egress rule'
grep -q 'HONCHO_URL=http://192.0.2.85:8000' "$log" || fail 'a plain reconfigure did not pass HONCHO_URL on'
[[ ! -e $fake/pushed-283-honcho-api-key ]] || fail 'the Honcho key already in the CT should be reused'
: > "$log"
out=$(real --reconfigure HONCHO_URL= PVE_LXC_DIR="$honcho_lxc") || fail "Honcho off: $out"
grep -q 'pct exec 285 -- /usr/local/sbin/honcho-clients revoke openclaw-283 --missing-ok' "$log" || fail 'HONCHO_URL= did not revoke the key'
[[ ! -e $fake/honcho-client-openclaw-283 ]] || fail 'the revoked key still works'
grep -q '192.0.2.85/32' "$fwfile" && fail 'HONCHO_URL= kept the Honcho egress rule'
grep -q 'HONCHO_URL= ' "$log" || fail 'the guest was not told to turn Honcho off'
: > "$log"
out=$(real --reconfigure) || fail "reconfigure after Honcho off: $out"
[[ $out != *'Keeping Honcho memory'* ]] || fail 'Honcho came back after it was turned off'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
pass 'Honcho: its own gateway key and workspace, as a file, and an egress rule; kept by a plain --reconfigure; HONCHO_URL= revokes it'

# Open Terminal: a client key issued by the terminal CT, admitted in its
# firewall, an egress rule here; kept (not rotated) by a plain --reconfigure;
# OPEN_TERMINAL_URL= revokes it.
ot_lxc=$fake/lxc; mkdir -p "$ot_lxc"
printf 'net0: name=eth0,bridge=vmbr0,ip=192.0.2.70/24,gw=192.0.2.1\n' > "$ot_lxc/270.conf"
printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8000 -log nolog\n' > "$fake/pve/firewall/270.fw"
ot_rule='IN ACCEPT -source 192.0.2.83/32 -p tcp -dport 8000 -log nolog # osr-open-terminal-client openclaw-283'
ot_egress='OUT ACCEPT -dest 192.0.2.70/32 -p tcp -dport 8000 -log nolog # ollama-smart-router openclaw-model'
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure OPEN_TERMINAL_URL=http://192.0.2.70:8000 PVE_LXC_DIR="$ot_lxc") || fail "Open Terminal on: $out"
grep -q 'pct exec 270 -- /usr/local/sbin/open-terminal-clients issue openclaw-283 --default-user default' "$log" ||
  fail 'the terminal CT (found by its address) did not issue a key'
[[ $(cat "$fake/pushed-283-open-terminal-key") == ot-client-key-1-0123456789 ]] || fail 'the key was not pushed as a file'
grep -qxF "$ot_rule" "$fake/pve/firewall/270.fw" || fail "terminal firewall: $(cat "$fake/pve/firewall/270.fw")"
grep -qxF "$ot_egress" "$fwfile" || fail "Open Terminal egress rule: $(cat "$fwfile")"
grep -q 'OPEN_TERMINAL_URL=http://192.0.2.70:8000' "$fake/guest-env" || fail 'the guest did not get OPEN_TERMINAL_URL'
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure PVE_LXC_DIR="$ot_lxc") || fail "plain reconfigure with Open Terminal: $out"
[[ $out == *'Keeping the Open Terminal workspace at http://192.0.2.70:8000'* && $out == *"Keeping client openclaw-283's Open Terminal key"* ]] ||
  fail "no keep notices: $out"
grep -q ' issue ' "$log" && fail 'a plain reconfigure rotated a working key'
grep -qxF "$ot_egress" "$fwfile" || fail 'a plain reconfigure dropped the Open Terminal egress rule'
: > "$log"
out=$(real --reconfigure OPEN_TERMINAL_URL= PVE_LXC_DIR="$ot_lxc") || fail "Open Terminal off: $out"
grep -q 'pct exec 270 -- /usr/local/sbin/open-terminal-clients revoke openclaw-283 --missing-ok' "$log" || fail 'the key was not revoked'
grep -q 'openclaw-283' "$fake/pve/firewall/270.fw" && fail 'the terminal firewall still admits the CT'
grep -q '192.0.2.70/32' "$fwfile" && fail 'OPEN_TERMINAL_URL= kept the egress rule'
grep -q 'OPEN_TERMINAL_URL= ' "$fake/guest-env" || fail 'the guest was not told to disconnect'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
pass 'Open Terminal: key issued by the terminal CT and kept while valid, both firewalls; OPEN_TERMINAL_URL= revokes it'
: > "$log"
out=$(real --integrate-only) || fail "integrate-only: $out"
grep -q 'install-target.sh' "$log" && fail '--integrate-only ran the installer'
grep -q 'pct pull 283 /etc/openclaw-target/api-key' "$log" || fail '--integrate-only did not read the CT key'
rm -f "$fake/ct283/api-on"
out=$(real --integrate-only) && fail '--integrate-only accepted a CT with the chat endpoint off'
[[ $out == *'chat completions endpoint off'* ]] || fail "endpoint off message: $out"
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
pass '--reconfigure pushes the current router key, follows the inventory and re-registers; --integrate-only needs the chat endpoint'

: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCLAW_PORT=18790) || fail "router move: $out"
grep -q 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000' "$fake/fw-at-guest" &&
  grep -q 'OUT ACCEPT -dest 192.0.2.90/32 -p tcp -dport 8000' "$fake/fw-at-guest" ||
  fail "the guest step did not reach the old and the new router: $(cat "$fake/fw-at-guest")"
grep -q '192.0.2.80' "$fwfile" && fail "the old router address is still admitted: $(cat "$fwfile")"
grep -qx 'IN ACCEPT -source 192.0.2.90/32 -p tcp -dport 18790 -log nolog # ollama-smart-router openclaw-api' "$fwfile" || fail 'new API rule'
grep -qx 'IN ACCEPT -p tcp -dport 18790 -log nolog # ollama-smart-router openclaw-dashboard' "$fwfile" || fail 'new Control UI rule'
grep -q 'dport 18789' "$fwfile" && fail 'the old port is still open'
grep -qx 'OUT ACCEPT -p tcp -dport 443 -log nolog' "$fwfile" || fail 'the other egress rules were lost'
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCLAW_PORT=18800 FAKE_GUEST_RC=1) && fail 'a failed guest step was accepted'
grep -q 'dport 18790 ' "$fwfile" && grep -q 'dport 18800 ' "$fwfile" || fail "a failed reconfigure closed the working port: $(cat "$fwfile")"
cp "$fwfile" "$fwfile.clean"
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCLAW_PORT=18790 FAKE_FW_EDIT=1) && fail 'a firewall edited during the run was accepted'
[[ $out == *'changed meanwhile'* ]] || fail "edited firewall message: $out"
grep -q 'integrate-webui.py' "$log" && fail 'Open WebUI registration ran after the firewall update failed'
cp "$fwfile.clean" "$fwfile"
# Every firewall write goes through targets/pve-firewall-swap.pl: an edit made
# between reading the file and replacing it is kept, never overwritten.
: > "$log"; touch "$fake/swap-edit"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCLAW_PORT=18790 OSR_FW_SWAP_TEST_EDIT_FILE="$fake/swap-edit") &&
  fail 'an edit racing the first firewall update was overwritten'
[[ $out == *'Nothing was changed'* ]] || fail "racing first update message: $out"
grep -q 'install-target.sh' "$log" && fail 'the guest ran after the first firewall update was refused'
grep -q '# edited meanwhile' "$fwfile" || fail 'the racing edit was lost'
cmp -s "$fwfile" <(cat "$fwfile.clean"; printf '# edited meanwhile\n') || fail "the file should be the racing edit alone: $(cat "$fwfile")"
cp "$fwfile.clean" "$fwfile"; rm -f -- "$fake/swap-edit"; : > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCLAW_PORT=18790 FAKE_SWAP_EDIT_AT_GUEST=1 OSR_FW_SWAP_TEST_EDIT_FILE="$fake/swap-edit") &&
  fail 'an edit racing the final firewall update was overwritten'
[[ $out == *'still admits the old and new rules'* ]] || fail "racing final update message: $out"
grep -q '# edited meanwhile' "$fwfile" || fail 'the edit racing the final update was lost'
[[ -z $(grep -vxFf "$fwfile" "$fwfile.clean") ]] || fail "the old rules should remain: $(cat "$fwfile")"
grep -q 'dport 18790 ' "$fwfile" || fail "the new rule should remain next to them: $(cat "$fwfile")"
cp "$fwfile.clean" "$fwfile"; rm -f -- "$fake/swap-edit"
pass 'firewall updates go through the locked swap: a racing edit stops the run and is kept'
rm -f -- "$fwfile"
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCLAW_PORT=18790) || fail "missing firewall file: $out"
[[ $out == *'does not exist'* ]] || fail "missing firewall warning: $out"
[[ ! -e $fwfile ]] || fail 'a firewall file was created for a CT that had none'
pass '--reconfigure follows a router move and port change; a failed guest step keeps the old rules; a missing firewall stays missing'

# Model servers by host name, and URLs without a port.
reset_fake
servers=strata+http://models.lan:8080,http://plain.lan,maya+https://secure.lan,http://192.0.2.75,http://nowhere.lan:11434
dns='FAKE_CT_DNS=models.lan=192.0.2.73,192.0.2.74;plain.lan=192.0.2.76;secure.lan=192.0.2.77'
out=$(real FAKE_INVENTORY_SERVERS=$servers "$dns") || fail "model servers by name: $out"
for want in 192.0.2.73/32:8080 192.0.2.74/32:8080 192.0.2.76/32:80 192.0.2.77/32:443 192.0.2.75/32:80; do
  rule="OUT ACCEPT -dest ${want%:*} -p tcp -dport ${want##*:} -log nolog # ollama-smart-router openclaw-model"
  grep -qxF "$rule" "$fwfile" || fail "missing $rule: $(cat "$fwfile")"
  grep -qxF "$rule" "$fake/fw-at-guest" || fail "not admitted before the guest step: $rule"
done
[[ $(grep -c 'openclaw-model' "$fwfile") == 5 ]] || fail "model rule count: $(cat "$fwfile")"
grep -q '198.51.100.99' "$fwfile" && fail 'a model server was resolved on the Proxmox host'
grep -q '^getent ' "$log" && fail "the host resolver was used: $(grep '^getent ' "$log")"
[[ $out == *'cannot resolve model server nowhere.lan'* ]] || fail "unresolvable name not reported: $out"
grep -q 'registry.npmjs.org' "$log" || fail 'the readiness check does not wait for the npm registry'
pass 'model server names are resolved inside the CT (every address) and ports default to 80/443'

reset_fake
mkdir -p "$fake/ct283"
printf 'description: unrelated CT\n' > "$fake/ct283/description"
printf '[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 18789 -log nolog # ollama-smart-router openclaw-api\n' > "$fwfile"
out=$(real --reconfigure) && fail 'an unrelated CT without OpenClaw settings was accepted'
[[ $out == *'no completed OpenClaw installation'* ]] || fail "unrelated CT message: $out"
grep -q 'pct push' "$log" && fail 'an unrelated CT was modified'
pass "partial recovery requires this target's CT description and firewall file"

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

[[ $(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'openclaw-setup.*' | wc -l) == "$stages_before" ]] ||
  fail 'a run left its host staging directory (it can hold the router key) behind'
pass 'every run, failed or not, removes its host staging directory'

# Guided prompts: Router first, then the OpenClaw container, then its settings
# and Honcho; a reconfigure starts with the CT to change. Offers come from the
# PVE configs (the router's tag and gateway, the Honcho CT's tag).
lxc=$(mktemp -d)
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.80/24\ntags: osr-router\n' > "$lxc/280.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.85/24\ntags: osr-target;honcho\n' > "$lxc/285.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.70/24\ntags: osr-target;open-terminal\n' > "$lxc/270.conf"
answers=$'\n282\nlocal:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst\nlocal-lvm\n192.0.2.82/24\n\n\n\n\n\n\n\n\n'
out=$(env -i "PATH=$PATH" PVE_INTERACTIVE=true PVE_LXC_DIR="$lxc" OPENWEBUI_ADMIN_TOKEN=x bash "$provision" --dry-run 2>&1 <<< "$answers") ||
  fail "guided create: $out"
order=$(sed '/== OpenClaw: /q' <<< "$out" | grep -oE '== [A-Za-z: ]+ ==|Router CT ID or address|New OpenClaw CT ID|amd64 template|Root disk storage|OpenClaw IP/CIDR|OpenClaw gateway|OSR model or tier|Context window|Max reply tokens|Offer OpenClaw in Open WebUI|Run the OpenClaw Control UI|Honcho API URL|Open Terminal URL' | paste -sd'|')
[[ $order == '== Router ==|Router CT ID or address|== OpenClaw container ==|New OpenClaw CT ID|amd64 template|Root disk storage|OpenClaw IP/CIDR|OpenClaw gateway|== OpenClaw settings ==|OSR model or tier|Context window|Max reply tokens|Offer OpenClaw in Open WebUI|Run the OpenClaw Control UI|== Honcho memory ==|Honcho API URL|== Open Terminal workspace ==|Open Terminal URL|== OpenClaw: create ==' ]] ||
  fail "create prompts out of order: $order"
[[ $out == *'Router CT ID or address [280]'* && $out == *'OpenClaw gateway [192.0.2.1]'* ]] || fail "router offers: $out"
[[ $out == *'Honcho API URL (none to skip) [http://192.0.2.85:8000]'* && $out == *'HONCHO_URL=http://192.0.2.85:8000'* ]] ||
  fail "the Honcho CT on this host was not offered or taken: $out"
[[ $out == *'Open Terminal URL (none to skip) [http://192.0.2.70:8000]'* && $out == *'OPEN_TERMINAL_URL=http://192.0.2.70:8000'* &&
   $out == *"admit 192.0.2.82 in Open Terminal CT 270's firewall"* ]] ||
  fail "the Open Terminal CT on this host was not offered, taken or connected: $out"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.82/24\ntags: osr-target;openclaw\n' > "$lxc/282.conf"
out=$(env -i "PATH=$PATH" PVE_INTERACTIVE=true PVE_LXC_DIR="$lxc" OPENWEBUI_ADMIN_TOKEN=x HONCHO_URL= bash "$provision" --dry-run --reconfigure 2>&1 <<< $'\n\n\n\n\n\n\n') ||
  fail "guided reconfigure: $out"
order=$(sed '/== OpenClaw: /q' <<< "$out" | grep -oE '== [A-Za-z: ]+ ==|OpenClaw CT ID|Router CT ID or address' | paste -sd'|')
[[ $order == '== OpenClaw container to reconfigure ==|OpenClaw CT ID|== Router ==|Router CT ID or address|== OpenClaw settings ==|== OpenClaw: reconfigure ==' ]] ||
  fail "reconfigure prompts out of order: $order"
[[ $out == *'OpenClaw CT ID [282]'* && $out != *'OpenClaw IP/CIDR'* ]] || fail "reconfigure CT offer: $out"
rm -rf -- "$lxc"
pass 'guided prompts: router, container, settings, Honcho; a reconfigure starts with the CT, offered by its tag'

printf '%s provision cases passed. No CT was created.\n' "$passed"
