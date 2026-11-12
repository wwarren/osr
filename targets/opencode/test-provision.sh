#!/usr/bin/env bash
# provision-lxc.sh: helpers, dry-run plans and validation, then whole runs
# against stubbed pct/pvesh/pvesm/curl (a fake Proxmox host, router CT and
# OpenCode CT). No Proxmox, CT, network or real router is touched.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
common=(CT_ID=284 ROUTER_CT_ID=280 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.84/24 GATEWAY=192.0.2.1)

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/opencode-provision-test.XXXXXX")
cleanup() {
  [[ $tmp_root == "${TMPDIR:-/tmp}"/opencode-provision-test.* ]] || return
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
[[ $(printf '192.0.2.84 dev eth0 src 192.0.2.80 uid 0\n' | route_src) == 192.0.2.80 ]] || fail route_src
[[ $(url_host http://router.lan:8000) == router.lan && $(url_port http://10.0.0.5:8001/) == 8001 ]] || fail 'url_host/url_port'
[[ $(cidr_network 192.0.2.84/24) == 192.0.2.0/24 && $(cidr_network 10.1.2.3/8) == 10.0.0.0/8 ]] || fail cidr_network
fw=$(firewall_config restricted 192.0.2.0/24 192.0.2.80 8000 4096)
[[ $fw == *$'policy_in: DROP\npolicy_out: DROP'* ]] || fail "restricted policies: $fw"
grep -qx 'IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 4096 -log nolog # ollama-smart-router opencode-web' <<< "$fw" || fail 'inbound web rule'
[[ $(grep -c '^IN ' <<< "$fw") == 1 ]] || fail 'one inbound rule'
# Order matters (first match wins): router, DNS, private drops, then the web.
order=$(grep -n -E 'dport 8000|udp -dport 53|-dest 192.168.0.0/16|dport 443' <<< "$fw" | cut -d: -f1 | paste -sd' ')
read -r r d p w <<< "$order"
(( r < d && d < p && p < w )) || fail "rule order: $order"
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  grep -qx "OUT DROP -dest $net -log nolog" <<< "$fw" || fail "no drop for $net"
done
fw=$(firewall_config open '' 192.0.2.80 8000 '')
[[ $fw == *'policy_out: ACCEPT'* && $fw != *'IN ACCEPT'* && $fw != *'OUT '* ]] || fail "open egress, no web UI: $fw"
printf '%s\n' "$(firewall_config restricted 10.9.0.0/16 192.0.2.80 8000 4096)" > "$tmp_root/access.fw"
[[ $(fw_access "$tmp_root/access.fw") == 10.9.0.0/16 ]] || fail fw_access
fw=$(firewall_config restricted 192.0.2.0/24 192.0.2.80 8000 4096 192.0.2.80 4097)
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 4097 -log nolog # ollama-smart-router opencode-api' <<< "$fw" ||
  fail "the chat endpoint rule (the router only): $fw"
[[ $(grep -c '^IN ' <<< "$fw") == 2 ]] || fail 'web and chat endpoint rules'
printf '%s\n' "$fw" > "$tmp_root/access.fw"
[[ $(fw_access "$tmp_root/access.fw") == 192.0.2.0/24 ]] || fail 'fw_access took the chat endpoint rule for the web range'
pass 'helpers: router kind, route source, URL parts, networks, and firewall rules in first-match order'

inv=$tmp_root/inventory.json
printf '{"enabled":true,"servers":["http://plain.lan","maya+https://secure.lan/","strata+http://10.0.0.5:8080","http://10.0.0.5:8080"]}\n' > "$inv"
[[ $(inventory_endpoints "$inv") == $'plain.lan 80\nsecure.lan 443\n10.0.0.5 8080' ]] ||
  fail "inventory endpoints: $(inventory_endpoints "$inv" 2>&1)"
for bad in http://h:0 http://h:99999 ftp://h:21 http://user@h:80 'http://h:80?x=1'; do
  printf '{"enabled":true,"servers":["%s"]}\n' "$bad" > "$inv"
  if inventory_endpoints "$inv" >/dev/null 2>&1; then fail "inventory endpoint accepted: $bad"; fi
done
printf '{"enabled":true,"servers":["strata+http://192.168.11.154:8080","http://192.168.11.153:11434/","maya+https://GPU.lan","lmstudio+http://10.0.0.5:8080","kindi+http://10.0.0.14:8093"]}\n' > "$inv"
# The names match the Hermes and OpenClaw targets', so every agent calls a server the same.
# shellcheck disable=SC1090
hermes_targets=$(source <(awk '/^inventory_targets\(\)/,/^}/' "$here/../hermes/provision-lxc.sh"); inventory_targets "$inv")
[[ $(inventory_targets "$inv") == "$hermes_targets" && -n $hermes_targets ]] || fail 'direct target names differ from the Hermes target'
[[ $(inventory_targets "$inv") == *'kindi-10-0-0-14-8093=kindi+http://10.0.0.14:8093'* ]] || fail 'a Kindi server is not its own kind of target'
printf '{"enabled":false,"servers":[]}\n' > "$inv"
if inventory_targets "$inv" >/dev/null 2>&1; then fail 'targets read from a router with discovery off'; fi
pass "inventory: endpoints default to 80/443, bad URLs are refused, target names are Hermes's"

# Reconfigure rewrites only this target's rules, found by their comment, and
# keeps every other line.
fwfile=$tmp_root/owned.fw
upd() { opencode_fw_update "$fwfile" "$@" > "$fwfile.new" && mv -- "$fwfile.new" "$fwfile"; }
web81='IN ACCEPT -source 10.0.0.0/8 -p tcp -dport 4100 -log nolog # ollama-smart-router opencode-web'
out81='OUT ACCEPT -dest 192.0.2.81/32 -p tcp -dport 8000 -log nolog # ollama-smart-router opencode-router'
cat > "$fwfile" <<'FW'
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP

[RULES]
IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog
IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 4096 -log nolog # ollama-smart-router opencode-web
OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog # ollama-smart-router opencode-router
OUT ACCEPT -dest 192.0.2.71/32 -p tcp -dport 8080 -log nolog # ollama-smart-router opencode-model
OUT ACCEPT -dest 203.0.113.10/32 -p tcp -dport 5432 -log nolog
OUT ACCEPT -p udp -dport 53 -log nolog
# an operator's note
IN DROP -source 198.51.100.0/24 -log nolog
FW
# shellcheck disable=SC2034  # read by opencode_fw_rules
model_rules=('OUT ACCEPT -dest 192.0.2.72/32 -p tcp -dport 8080 -log nolog # ollama-smart-router opencode-model')
upd replace 10.0.0.0/8 4100 192.0.2.81 8000 || fail 'firewall update'
[[ $(awk '/^\[RULES\]$/ {getline; print; exit}' "$fwfile") == "$web81" ]] || fail "web rule not first: $(cat "$fwfile")"
grep -qxF "$out81" "$fwfile" || fail 'router rule'
grep -qx 'OUT ACCEPT -dest 192.0.2.72/32 -p tcp -dport 8080 -log nolog # ollama-smart-router opencode-model' "$fwfile" || fail 'model rule'
grep -q -e '192.0.2.80' -e '192.0.2.71' -e 'dport 4096' "$fwfile" && fail "old owned rules remain: $(cat "$fwfile")"
for keep in 'IN ACCEPT -source 203.0.113.9/32 -p tcp -dport 22 -log nolog' 'OUT ACCEPT -dest 203.0.113.10/32 -p tcp -dport 5432 -log nolog' \
            'OUT ACCEPT -p udp -dport 53 -log nolog' '# an operator'"'"'s note' 'IN DROP -source 198.51.100.0/24 -log nolog' 'policy_out: DROP'; do
  grep -qxF -- "$keep" "$fwfile" || fail "lost: $keep"
done
cp "$fwfile" "$fwfile.expected"
upd keep 10.0.0.0/8 4100 192.0.2.81 8000 || fail 'idempotent firewall check'
cmp -s "$fwfile" "$fwfile.expected" || fail "an unchanged reconfigure doubled the rules: $(cat "$fwfile")"
upd keep 10.0.0.0/8 4100 192.0.2.82 8000 || fail 'keeping the old rules'
grep -qxF "$out81" "$fwfile" && grep -q '192.0.2.82/32 -p tcp -dport 8000' "$fwfile" || fail 'new rules missing next to the old ones'
upd replace 10.0.0.0/8 4100 192.0.2.82 8000 192.0.2.82 4097 || fail 'opening the chat endpoint'
grep -qx 'IN ACCEPT -source 192.0.2.82/32 -p tcp -dport 4097 -log nolog # ollama-smart-router opencode-api' "$fwfile" || fail 'chat endpoint rule'
upd replace 10.0.0.0/8 4100 192.0.2.82 8000 192.0.2.90 4200 || fail 'moving the chat endpoint'
grep -q 'dport 4097' "$fwfile" && fail 'the old chat endpoint rule remains'
grep -q -- '-source 192.0.2.90/32 -p tcp -dport 4200 .*opencode-api$' "$fwfile" || fail 'moved chat endpoint rule'
upd replace '' '' 192.0.2.82 8000 || fail 'closing the web port'
grep -q '^IN ACCEPT.*opencode' "$fwfile" && fail 'the web port was left open'
grep -q '192.0.2.81' "$fwfile" && fail 'kept rules survived the final update'
printf '[RULES]\n[RULES]\n' > "$fwfile"; cp "$fwfile" "$fwfile.expected"
if opencode_fw_update "$fwfile" replace 10.0.0.0/8 4096 192.0.2.82 8000 > /dev/null 2> "$fwfile.err"; then fail 'two [RULES] sections accepted'; fi
grep -q 'inspect' "$fwfile.err" && cmp -s "$fwfile" "$fwfile.expected" || fail 'two [RULES] sections: no reason, or the file changed'
pass 'reconfigure replaces only the commented OpenCode rules (web, chat endpoint, egress), wherever they are; keeps other lines; is idempotent; closes disabled ports'

# --- dry-run plans and validation ------------------------------------------------
has() { [[ $output == *"$1"* ]] || fail "missing: $1"$'\n'"$output"; }
lacks() { [[ $output != *"$1"* ]] || fail "unexpected: $1"$'\n'"$output"; }
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
has '+ pct create 284 local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst'
has '--unprivileged 1'
has '--tags ai\;ai-tools\;osr-target\;opencode'
has '--features nesting=1'
has '--hostname opencode'
has 'read ROUTER_API_KEY from /app/router/secrets.env on router CT 280 into a 0600 file'
has 'IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 4096 -log nolog # ollama-smart-router opencode-web'
has 'policy_out: DROP'
has '/root/opencode-deploy/router-api-key --perms 0600'
has '/hermes/direct-dispatch.py /root/opencode-deploy/direct-dispatch.py'
has 'OPENCODE_WEB=true'
has 'OPENCODE_VERSION=2.2.7'
has 'OPENCODE_FREE_MODELS=false'
has 'HONCHO_PLUGIN_VERSION=0.2.1'
has 'ROUTER_URL=http://\<router-source-ip\>:8000'
has 'IN ACCEPT -source <router-source-ip>/32 -p tcp -dport 4097 -log nolog # ollama-smart-router opencode-api'
has 'OPENCODE_API=true'; has 'OPENCODE_API_PORT=4097'; has 'OPENCODE_API_PERMISSIONS=allow'
has '/root/opencode-deploy/openai-proxy.py --perms 0644'; has '/root/opencode-deploy/opencode-api.service --perms 0644'
has '+ pct pull 284 /etc/opencode-target/api-key'
has 'integrate-webui.py --webui-url http://127.0.0.1:8080 --opencode-url http://192.0.2.84:4097/v1'
has '--model-name opencode --task-model fast'
has '+ resolve model server host names inside CT 284 and admit their addresses'
pass 'the default plan reads the router key, admits the CT network to the web UI, installs the pinned release and offers OpenCode in Open WebUI'

plan OPENCODE_WEB=false OPENWEBUI=false
has 'OPENCODE_WEB=false'; lacks 'IN ACCEPT'; has 'OPENCODE_API=false'; lacks 'integrate-webui'; lacks 'opencode-api-key'
plan OPENCODE_API_PORT=4300 OPENCODE_API_PERMISSIONS=reject TASK_MODEL= OPENWEBUI_PORT=3000
has '-dport 4300 -log nolog # ollama-smart-router opencode-api'; has 'OPENCODE_API_PERMISSIONS=reject'
has 'http://127.0.0.1:3000 --opencode-url http://192.0.2.84:4300/v1'; has "--task-model ''"
plan EGRESS=open ROUTER_URL=http://10.1.2.3:8001 OPENCODE_PORT=4100 OPENCODE_ACCESS_CIDR=10.9.8.7/16 OPENCODE_VERSION=latest
has 'policy_out: ACCEPT'; lacks 'OUT DROP'; has 'ROUTER_URL=http://10.1.2.3:8001'
has 'IN ACCEPT -source 10.9.0.0/16 -p tcp -dport 4100'; has 'OPENCODE_VERSION=latest'; has 'OPENCODE_PORT=4100'
pass 'OPENCODE_WEB=false and OPENWEBUI=false open no port; the chat endpoint port, permissions, task model, EGRESS=open, ROUTER_URL, the port, the access range and latest are honoured'

plan --reconfigure OPENCODE_ACCESS_CIDR=192.0.2.0/24
lacks '+ pct create'; lacks 'write /etc/pve/firewall'
has '+ check the OpenCode rules in /etc/pve/firewall/284.fw'
has '+ sync OpenCode rules in /etc/pve/firewall/284.fw'
has '/root/opencode-deploy/install-target.sh'
has 'OPENCODE_API=false'; lacks 'integrate-webui'
plan --integrate-only
lacks '+ pct create'; lacks 'install-target.sh'; lacks 'firewall'
has '+ pct pull 284 /etc/opencode-target/api-key'; has 'integrate-webui.py --webui-url http://127.0.0.1:8080'
pass '--reconfigure reruns the installer and syncs the owned firewall rules (Open WebUI off for a CT that records none); --integrate-only only registers'

reject 'CT_ID must be numeric' CT_ID=99
reject 'Set CT_ID for unattended provisioning' --reconfigure CT_ID=
reject 'Set TEMPLATE for unattended provisioning' TEMPLATE=
reject 'Set STORAGE for unattended provisioning' STORAGE=
reject 'Set IP_CIDR for unattended provisioning' IP_CIDR=
reject 'Set GATEWAY for unattended provisioning' GATEWAY=
reject 'OpenCode and router CT IDs must differ' CT_ID=280
reject 'at least 32768' OPENCODE_CONTEXT_LENGTH=16384
reject 'OPENCODE_MAX_TOKENS must be' OPENCODE_MAX_TOKENS=40000
reject 'OPENCODE_VERSION must be' 'OPENCODE_VERSION=2.0;x'
reject 'OPENCODE_VERSION must be' OPENCODE_VERSION=1.18.23
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'EGRESS must be' EGRESS=none
reject 'OPENCODE_WEB must be' OPENCODE_WEB=yes
reject 'OPENCODE_FREE_MODELS must be' OPENCODE_FREE_MODELS=yes
reject 'OPENCODE_ACCESS_CIDR must be' OPENCODE_ACCESS_CIDR=lan
reject 'not 8765' OPENCODE_PORT=8765
reject 'HONCHO_URL must be' HONCHO_URL=honcho:8000
reject 'no /v1' ROUTER_URL=http://r:8000/v1
reject 'Set only one of ROUTER' ROUTER=281
reject 'OPENWEBUI must be' OPENWEBUI=yes
reject 'OPENCODE_API_PORT must be' OPENCODE_API_PORT=4096
reject 'OPENCODE_API_PORT must be' OPENCODE_API_PORT=8765
reject 'OPENCODE_API_PERMISSIONS must be' OPENCODE_API_PERMISSIONS=ask
reject 'TASK_MODEL must be a router model' TASK_MODEL=opencode
reject 'Invalid TASK_MODEL' 'TASK_MODEL=a b'
reject 'OPENWEBUI_PORT must be' OPENWEBUI_PORT=70000
reject '--integrate-only needs OPENWEBUI=true' --integrate-only OPENWEBUI=false
reject 'Use only one of' --reconfigure --integrate-only
pass 'invalid CT, context, releases, network, ports, access range, Honcho and Open WebUI settings are refused before any Proxmox call'

# --- whole runs against a fake Proxmox host ----------------------------------------
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
fake=$tmp_root/fake; mkdir -p "$fake/pve/nodes" "$fake/pve/firewall" "$fake/router"
export FAKE_LOG=$log FAKE_DIR=$fake
router_key=sk-router-0123456789abcdef
export FAKE_ROUTER_KEY=$router_key
# pct: the router CT (280), the OpenCode CT (284), Honcho (285), Open Terminal (270).
cat > "$bin/pct" <<'PCT'
#!/usr/bin/env bash
printf 'pct' >> "$FAKE_LOG"; printf ' %q' "$@" >> "$FAKE_LOG"; printf '\n' >> "$FAKE_LOG"
cmd=$1 id=$2; shift 2
case $cmd in
  status) [[ -e $FAKE_DIR/ct$id || $id == 280 ]] && echo 'status: running' ;;
  create) printf 'pct-create-umask %s\n' "$(umask)" >> "$FAKE_LOG"; mkdir -p "$FAKE_DIR/ct$id"
    printf 'description: OpenCode for Ollama Smart Router\n' > "$FAKE_DIR/ct$id/description" ;;
  config) cat "$FAKE_DIR/ct$id/description" ;;
  set) : ;;
  start) : ;;
  pull) [[ $1 == /etc/opencode-target/api-key ]] && printf '%s\n' "$FAKE_API_KEY" > "$2" ;;
  push) cp "$1" "$FAKE_DIR/pushed-$id-$(basename "$2")"
    [[ $(basename "$2") != honcho-api-key ]] || cp "$1" "$FAKE_DIR/ct$id/honcho-key"
    [[ $(basename "$2") != open-terminal-key ]] || cp "$1" "$FAKE_DIR/ct$id/ot-key" ;;
  exec)
    [[ $1 == -- ]] && shift
    all="$*"
    if [[ $id == 270 ]]; then
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
        'ip -4 route get '*) echo "$5 dev eth0 src 192.0.2.80 uid 0" ;;
        'systemctl is-active --quiet open-webui.service') [[ -z ${FAKE_NO_WEBUI:-} ]] ;;
        'sh -c command -v python3 >/dev/null') exit 0 ;;
        sh\ -c\ *openwebui/.env*) echo 8080 ;;
        python3\ -c\ *) echo 0.12.4 ;;
        'mktemp -d /root/opencode-integration.XXXXXX') echo /root/opencode-integration.Ab12Cd ;;
        'python3 /root/opencode-integration.Ab12Cd/integrate-webui.py '*)
          printf '%s\n' "$all" > "$FAKE_DIR/integrate-args"
          cp "$FAKE_DIR/pushed-280-admin-token" "$FAKE_DIR/integrate-admin-token"
          [[ ${FAKE_INTEGRATE_RC:-0} == 0 ]] || exit "$FAKE_INTEGRATE_RC" ;;
        'rm -rf -- /root/opencode-integration.Ab12Cd') rm -f "$FAKE_DIR"/pushed-280-*; touch "$FAKE_DIR/router-stage-removed" ;;
        *) echo "unexpected router command: $all" >&2; exit 3 ;;
      esac
    else
      case $all in
        'test -f /etc/opencode-target/settings') [[ -e $FAKE_DIR/ct$id/installed ]] ;;
        'cat /etc/opencode-target/settings') cat "$FAKE_DIR/ct$id/settings" 2>/dev/null || exit 1 ;;
        sh\ -c\ *ip\ -4\ -o\ addr*) echo 192.0.2.84 ;;
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
        sh\ -c\ \[\ -s\ /root/opencode-deploy/open-terminal-key*)
          [[ -s $FAKE_DIR/ct$id/ot-key ]] && tr -d '\r\n\t ' < "$FAKE_DIR/ct$id/ot-key" | sha256sum | cut -d' ' -f1 ;;
        'test -s /root/opencode-deploy/honcho-api-key') [[ -s $FAKE_DIR/ct$id/honcho-key ]] ;;
        sh\ -c\ *opencode-deploy/honcho-api-key*)
          [[ -s $FAKE_DIR/ct$id/honcho-key ]] && tr -d '\r\n\t ' < "$FAKE_DIR/ct$id/honcho-key" | sha256sum | cut -d' ' -f1 ;;
        'test -x /usr/local/sbin/honcho-clients') [[ $id == 285 ]] ;;
        '/usr/local/sbin/honcho-clients has '*)
          [[ -s $FAKE_DIR/honcho-client-$3 ]] && [[ $(tr -d '\n' < "$FAKE_DIR/honcho-client-$3" | sha256sum | cut -d' ' -f1) == "$4" ]] ;;
        '/usr/local/sbin/honcho-clients issue '*)
          printf '%s\n' "$FAKE_HONCHO_KEY" | tee "$FAKE_DIR/honcho-client-$3" ;;
        '/usr/local/sbin/honcho-clients revoke '*) rm -f "$FAKE_DIR/honcho-client-$3" ;;
        'install -d -m 0700 /root/opencode-deploy') : ;;
        env\ *install-target.sh)
          printf '%s\n' "$all" > "$FAKE_DIR/guest-env"
          cp "$FAKE_DIR/pve/firewall/$id.fw" "$FAKE_DIR/fw-at-guest" 2>/dev/null || : > "$FAKE_DIR/fw-at-guest"
          [[ -z ${FAKE_FW_EDIT:-} ]] || printf '[RULES]\n' >> "$FAKE_DIR/pve/firewall/$id.fw"
          [[ -z ${FAKE_SWAP_EDIT_AT_GUEST:-} ]] || touch "$FAKE_DIR/swap-edit"
          [[ ${FAKE_GUEST_RC:-0} == 0 ]] || exit "$FAKE_GUEST_RC"
          touch "$FAKE_DIR/ct$id/installed"
          # The guest records its settings (the provisioner's defaults next time).
          : > "$FAKE_DIR/ct$id/settings"
          for word in $all; do
            case $word in ROUTER_URL=*|OPENCODE_*=*|HONCHO_URL=*|OPEN_TERMINAL_URL=*|HONCHO_PLUGIN_VERSION=*)
              printf '%s\n' "$word" >> "$FAKE_DIR/ct$id/settings" ;; esac
          done
          exit 0 ;;
        *) echo "unexpected CT command: $all" >&2; exit 3 ;;
      esac
    fi ;;
esac
PCT
chmod +x "$bin/pct"
cat > "$bin/pvesh" <<'EOF'
#!/usr/bin/env bash
echo "pvesh $*" >> "$FAKE_LOG"; [[ ! -e $FAKE_DIR/ct284 || -n ${FAKE_FREE_ID:-} ]]
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
lxc=$fake/lxc; mkdir -p "$lxc"
printf 'net0: name=eth0,bridge=vmbr0,ip=192.0.2.70/24,gw=192.0.2.1\n' > "$lxc/270.conf"
printf 'net0: name=eth0,bridge=vmbr0,ip=192.0.2.85/24,gw=192.0.2.1\n' > "$lxc/285.conf"

admin_token=owui-admin-token-0123456789
api_key=oc-api-key-0123456789abcdef
# real [VAR=value ...] [--flag]: a whole run; the admin token comes from the
# environment, as the OSR installer gives it (NO_TOKEN=1 leaves it out).
real() {
  split "$@"
  local -a token=("OPENWEBUI_ADMIN_TOKEN=$admin_token")
  [[ " ${vars[*]} " != *' NO_TOKEN=1 '* ]] || token=()
  env -i "PATH=$bin:$PATH" PVE_ETC="$fake/pve" PVE_LXC_DIR="$lxc" SYS_NET_DIR="$fake/net" BRIDGE=lo FAKE_LOG="$log" FAKE_DIR="$fake" \
    FAKE_ROUTER_KEY="$router_key" FAKE_API_KEY="$api_key" "${token[@]}" "${common[@]}" "${vars[@]}" bash "$provision" "${flags[@]}" 2>&1
}
reset_fake() {
  rm -rf -- "${fake:?}/ct284" "$fake"/pushed-* "$fake"/fw-at-* "$fake/guest-env" "$fake/pve/firewall/284.fw" \
    "$fake/integrate-args" "$fake/integrate-admin-token" "$fake/router-stage-removed"
  : > "$log"
}
honcho_key=honcho-osr-key-0123456789
secrets_in_argv() { grep -E -- "$router_key|$honcho_key|ot-client-key-|sk-backend-secret|$admin_token|$api_key" "$log" || true; }
fwfile=$fake/pve/firewall/284.fw

stages_before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'opencode-setup.*' | wc -l)
reset_fake
out=$(real) || fail "full run: $out"
[[ $(cat "$fake/pushed-284-router-api-key") == "$router_key" ]] || fail 'the router key was not pushed to the CT'
[[ $(cat "$fake/pushed-284-backend-keys") == 'STRATA_API_KEY=sk-backend-secret' ]] || fail 'the backend key was not pushed to the CT'
[[ $(cat "$fake/pushed-284-targets") == 'strata-192-0-2-71-8080=strata+http://192.0.2.71:8080' ]] ||
  fail "the direct targets were not pushed: $(cat "$fake/pushed-284-targets" 2>&1)"
cmp -s "$fake/pushed-284-direct-dispatch.py" "$here/../hermes/direct-dispatch.py" || fail "the Hermes target's dispatcher was not pushed"
[[ -f $fake/pushed-284-opencode.service && -f $fake/pushed-284-opencode-direct.service ]] || fail 'units not pushed'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
guest_env=$(< "$fake/guest-env")
for want in ROUTER_URL=http://192.0.2.80:8000 OPENCODE_WEB=true OPENCODE_PORT=4096 KINDI_READ_TIMEOUT_SECONDS=5400 \
            OPENCODE_MODEL=auto OPENCODE_CONTEXT_LENGTH=65536 OPENCODE_VERSION=2.2.7 HONCHO_URL= OPEN_TERMINAL_URL=; do
  [[ " $guest_env " == *" $want "* ]] || fail "guest installer not given $want: $guest_env"
done
grep -qx 'IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 4096 -log nolog # ollama-smart-router opencode-web' "$fwfile" || fail "firewall: $(cat "$fwfile")"
grep -qx 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000 -log nolog # ollama-smart-router opencode-router' "$fwfile" || fail 'router egress rule'
grep -qx 'OUT ACCEPT -dest 192.0.2.71/32 -p tcp -dport 8080 -log nolog # ollama-smart-router opencode-model' "$fwfile" || fail 'model egress rule'
grep -q 'pct create 284' "$log" || fail 'no CT created'
grep -qx 'pct-create-umask 0022' "$log" || fail 'pct create inherited a restrictive umask'
grep -q 'pct create 284.*--features nesting=1' "$log" || fail 'the OpenCode CT was created without nesting'
grep -q 'registry.npmjs.org' "$log" || fail 'the readiness check does not wait for the npm registry'
[[ $out == *'Web UI: http://192.0.2.84:4096/ (user opencode)'* && $out == *'cat /etc/opencode-target/password'* ]] || fail "summary: $out"
pass 'a full run pushes the keys as files, the shared dispatcher and units; admits the CT network to the web UI; no secret is in argv'

# The chat endpoint: pushed, admitted from the router only, registered in Open
# WebUI with the key the CT made; the admin token and the key travel as files.
[[ -f $fake/pushed-284-opencode-api.service ]] && cmp -s "$fake/pushed-284-openai-proxy.py" "$here/openai-proxy.py" ||
  fail 'the chat endpoint was not pushed'
for want in OPENCODE_API=true OPENCODE_API_PORT=4097 OPENCODE_API_PERMISSIONS=allow; do
  [[ " $guest_env " == *" $want "* ]] || fail "guest installer not given $want: $guest_env"
done
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 4097 -log nolog # ollama-smart-router opencode-api' "$fwfile" ||
  fail "chat endpoint rule: $(cat "$fwfile")"
grep -qx 'IN ACCEPT -source 192.0.2.80/32 -p tcp -dport 4097 -log nolog # ollama-smart-router opencode-api' "$fake/fw-at-guest" ||
  fail 'the router was not admitted to the chat endpoint before the guest step'
args=$(< "$fake/integrate-args")
[[ $args == *'--webui-url http://127.0.0.1:8080 --opencode-url http://192.0.2.84:4097/v1 --model-name opencode --task-model fast'* &&
   $args == *'--admin-token-file /root/opencode-integration.Ab12Cd/admin-token --opencode-key-file /root/opencode-integration.Ab12Cd/opencode-api-key'* ]] ||
  fail "integrate-webui arguments: $args"
[[ $(< "$fake/integrate-admin-token") == "$admin_token" ]] || fail 'the admin token did not reach the router as a file'
grep -q "pct push 280 .*/opencode-api-key /root/opencode-integration.Ab12Cd/opencode-api-key --perms 0600" "$log" &&
  grep -q 'pct push 280 .*integrate-webui.py /root/opencode-integration.Ab12Cd/integrate-webui.py --perms 0600' "$log" ||
  fail 'the key or the integration script was not pushed to the router'
grep -q 'pct exec 280 -- python3 -c ' "$log" || fail 'Open WebUI was not verified'
[[ -e $fake/router-stage-removed ]] || fail 'the router staging directory (admin token, key) was not removed'
(( $(grep -n 'pct exec 280 -- python3 -c ' "$log" | head -n1 | cut -d: -f1) < $(grep -n 'pct create 284' "$log" | cut -d: -f1) )) ||
  fail 'Open WebUI was not checked before the CT was created'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
[[ $out == *'choose "opencode" in the model list'* && $out == *'permission requests: allow'* ]] || fail "Open WebUI summary: $out"
pass 'the chat endpoint: pushed, admitted from the router only, registered in Open WebUI; the admin token and key travel as files and are removed'

out=$(real --reconfigure OPENCODE_WEB=false) || fail "web off: $out"
grep -q 'opencode-web' "$fwfile" && fail 'the web rule remained after disabling the web UI'
[[ $(< "$fake/guest-env") == *OPENCODE_WEB=false* ]] || fail 'guest did not receive the web setting'
out=$(real --reconfigure OPENCODE_WEB=true OPENCODE_ACCESS_CIDR=10.20.30.40/16) || fail "web on again: $out"
grep -qx 'IN ACCEPT -source 10.20.0.0/16 -p tcp -dport 4096 -log nolog # ollama-smart-router opencode-web' "$fwfile" || fail 'the new access range'
out=$(real --reconfigure OPENCODE_MAX_TOKENS=4096) || fail "plain reconfigure: $out"
[[ $(grep -c 'opencode-web$' "$fwfile") == 1 ]] && grep -q -- '-source 10.20.0.0/16 ' "$fwfile" || fail 'a reconfigure did not keep the access range from the firewall'
[[ $(< "$fake/guest-env") == *OPENCODE_MAX_TOKENS=4096* && $(< "$fake/guest-env") == *OPENCODE_WEB=true* ]] ||
  fail 'the recorded settings were not the defaults of the reconfigure'
pass 'reconfigure closes and reopens the web port, takes a new access range and keeps it from the firewall afterwards'

reset_fake
out=$(real NO_TOKEN=1) && fail 'an unattended run without an admin token was accepted'
[[ $out == *'Set OPENWEBUI_ADMIN_TOKEN'* ]] || fail "missing token message: $out"
grep -q 'pct create' "$log" && fail 'a CT was created without the admin token'
reset_fake
out=$(real FAKE_NO_WEBUI=1) && fail 'a router without Open WebUI was accepted'
[[ $out == *'Open WebUI (open-webui.service) is not active'*'OPENWEBUI=false'* ]] || fail "no Open WebUI message: $out"
grep -q 'pct create' "$log" && fail 'a CT was created although Open WebUI is not running'
reset_fake
out=$(real NO_TOKEN=1 OPENWEBUI=false) || fail "without Open WebUI: $out"
[[ ! -e $fake/integrate-args && $(< "$fake/guest-env") == *OPENCODE_API=false* ]] || fail 'OPENWEBUI=false still registered or ran the chat endpoint'
grep -q 'opencode-api$' "$fwfile" && fail 'OPENWEBUI=false opened the chat endpoint port'
out=$(real --reconfigure NO_TOKEN=1) || fail "reconfigure keeps Open WebUI off: $out"
[[ ! -e $fake/integrate-args && $(< "$fake/guest-env") == *OPENCODE_API=false* ]] || fail 'a reconfigure turned the recorded choice around'
# A CT made before the chat endpoint existed records no OPENCODE_API: an
# unattended reconfigure (tools/upgrade-all.sh) leaves it off, needing no token.
sed -i '/^OPENCODE_API/d' "$fake/ct284/settings"
out=$(real --reconfigure NO_TOKEN=1) || fail "reconfigure of an older CT: $out"
[[ $(< "$fake/guest-env") == *OPENCODE_API=false* && ! -e $fake/integrate-args ]] || fail 'an older CT got the chat endpoint unasked'
out=$(real --integrate-only) && fail '--integrate-only on a CT with the chat endpoint off was accepted'
[[ $out == *"chat endpoint off; use --reconfigure"* ]] || fail "integrate refusal: $out"
out=$(real --reconfigure OPENWEBUI=true OPENCODE_API_PORT=4300 TASK_MODEL=) || fail "turning Open WebUI on: $out"
[[ $(< "$fake/integrate-args") == *'--opencode-url http://192.0.2.84:4300/v1 --model-name opencode --task-model  --admin-token-file'* ]] ||
  fail "registration after turning it on: $(< "$fake/integrate-args")"
grep -q -- '-dport 4300 -log nolog # ollama-smart-router opencode-api' "$fwfile" || fail 'the chat endpoint port was not opened'
grep -q -- '-dport 4300 -log nolog # ollama-smart-router opencode-api' "$fake/fw-at-guest" ||
  fail 'a reconfigure did not admit the router to the new chat endpoint port before the guest step'
rm -f "$fake/integrate-args"; : > "$log"
out=$(real --reconfigure NO_TOKEN=1) && fail 'a reconfigure that registers again ran without a token'
[[ $out == *'Set OPENWEBUI_ADMIN_TOKEN'* ]] || fail "reconfigure token message: $out"
grep -q 'install-target.sh' "$log" && fail 'the guest ran although the token was missing'
out=$(real --reconfigure) || fail "reconfigure with Open WebUI recorded: $out"
[[ $(< "$fake/guest-env") == *OPENCODE_API=true*OPENCODE_API_PORT=4300* && $(< "$fake/integrate-args") == *':4300/v1'* ]] ||
  fail 'a reconfigure did not keep the chat endpoint (recorded port) and register it again'
rm -f "$fake/integrate-args" "$fake/guest-env"; : > "$log"
out=$(real --integrate-only) || fail "integrate only: $out"
[[ $(< "$fake/integrate-args") == *'--opencode-url http://192.0.2.84:4300/v1'* ]] || fail 'integrate-only did not register the recorded port'
[[ ! -e $fake/guest-env ]] && ! grep -q -e 'install-target.sh' -e 'pct create' -e 'pct push 284' "$log" || fail '--integrate-only changed the CT'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
out=$(real --integrate-only FAKE_INTEGRATE_RC=1) && fail 'a failed registration was reported as done'
[[ -e $fake/router-stage-removed ]] || fail 'a failed registration left the router staging directory'
pass 'Open WebUI: token and service checked before anything is made; OPENWEBUI=false and older CTs need neither; reconfigure keeps the choice and registers again; --integrate-only only registers'

reset_fake
out=$(real FAKE_ROUTER_REJECTS=1) && fail 'a rejected router key was accepted'
[[ $out == *'rejected the key'* ]] || fail "rejected key message: $out"
grep -q 'pct create' "$log" && fail 'a CT was created although the router rejected the key'
reset_fake
out=$(real FAKE_NO_ROUTER_KEY=1) || fail "router without a key: $out"
[[ $out == *'has no ROUTER_API_KEY'* ]] || fail 'a router without a key is not reported'
[[ ! -e $fake/pushed-284-router-api-key ]] || fail 'an empty key file was pushed'
pass 'a router that rejects its own key stops before pct create; a router without a key is reported'

reset_fake
out=$(real FAKE_GUEST_RC=1) && fail 'a failed guest install was accepted'
[[ $out == *'re-run with --reconfigure'* ]] || fail "failure hint: $out"
[[ ! -e $fake/ct284/installed ]] || fail 'the failed guest install wrote completed settings'
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure OPENCODE_ACCESS_CIDR=192.0.2.0/24) || fail "resume: $out"
grep -q 'pct create' "$log" && fail '--reconfigure created a CT'
[[ -e $fake/ct284/installed && $out == *'resuming its partial installation'* ]] || fail "partial install not resumed: $out"
grep -qF 'pct set 284 --tags ai\;ai-tools\;osr-target\;opencode' "$log" || fail 'a reconfigure did not make sure of the tags'
pass 'a failed guest install leaves an incomplete CT; --reconfigure resumes it'

: > "$log"
out=$(real --reconfigure FAKE_MODEL_SERVER=192.0.2.72) || fail "changed model server: $out"
grep -qx 'OUT ACCEPT -dest 192.0.2.72/32 -p tcp -dport 8080 -log nolog # ollama-smart-router opencode-model' "$fwfile" || fail 'new model server not admitted'
grep -q '192.0.2.71/32.*opencode-model' "$fwfile" && fail 'old model server still admitted'
pass '--reconfigure follows the inventory'

# Honcho: given once, kept by a plain --reconfigure, turned off with HONCHO_URL=.
honcho_rule='OUT ACCEPT -dest 192.0.2.85/32 -p tcp -dport 8000 -log nolog # ollama-smart-router opencode-model'
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure HONCHO_URL=http://192.0.2.85:8000 FAKE_HONCHO_KEY=$honcho_key) || fail "Honcho on: $out"
grep -q 'pct exec 285 -- /usr/local/sbin/honcho-clients issue opencode-284 --workspace opencode-284' "$log" ||
  fail 'the key must be this CT'"'"'s own gateway key (Honcho CT found by its address), pinned to its own workspace'
[[ $(cat "$fake/pushed-284-honcho-api-key") == "$honcho_key" ]] || fail 'the Honcho key was not pushed as a file'
grep -qxF "$honcho_rule" "$fwfile" || fail "Honcho egress rule: $(cat "$fwfile")"
[[ $(< "$fake/guest-env") == *HONCHO_URL=http://192.0.2.85:8000* ]] || fail 'the guest did not get HONCHO_URL'
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure FAKE_HONCHO_KEY=honcho-rotated-key-0123456789) || fail "plain reconfigure: $out"
[[ $out == *'Keeping Honcho memory at http://192.0.2.85:8000'* ]] || fail "no keep notice: $out"
grep -q 'honcho-clients has opencode-284 [0-9a-f]* --workspace opencode-284' "$log" || fail 'the kept key was not checked with the Honcho CT'
grep -q 'honcho-clients issue' "$log" && fail 'a key Honcho accepts was replaced'
grep -qxF "$honcho_rule" "$fwfile" || fail 'a plain reconfigure dropped the Honcho egress rule'
[[ ! -e $fake/pushed-284-honcho-api-key ]] || fail 'the Honcho key already in the CT should be reused'
: > "$log"
out=$(real --reconfigure HONCHO_URL=) || fail "Honcho off: $out"
grep -q 'pct exec 285 -- /usr/local/sbin/honcho-clients revoke opencode-284 --missing-ok' "$log" || fail 'HONCHO_URL= did not revoke the key'
grep -q '192.0.2.85/32' "$fwfile" && fail 'HONCHO_URL= kept the Honcho egress rule'
[[ " $(< "$fake/guest-env") " == *' HONCHO_URL= '* ]] || fail 'the guest was not told to turn Honcho off'
: > "$log"
out=$(real --reconfigure) || fail "reconfigure after Honcho off: $out"
[[ $out != *'Keeping Honcho memory'* ]] || fail 'Honcho came back after it was turned off'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
pass 'Honcho: its own gateway key and workspace, as a file, and an egress rule; kept by a plain --reconfigure; HONCHO_URL= revokes it'

# Open Terminal: a client key issued by the terminal CT, admitted in its
# firewall, an egress rule here; kept by a plain --reconfigure; OPEN_TERMINAL_URL= revokes it.
printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8000 -log nolog\n' > "$fake/pve/firewall/270.fw"
ot_rule='IN ACCEPT -source 192.0.2.84/32 -p tcp -dport 8000 -log nolog # osr-open-terminal-client opencode-284'
ot_egress='OUT ACCEPT -dest 192.0.2.70/32 -p tcp -dport 8000 -log nolog # ollama-smart-router opencode-model'
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure OPEN_TERMINAL_URL=http://192.0.2.70:8000) || fail "Open Terminal on: $out"
grep -q 'pct exec 270 -- /usr/local/sbin/open-terminal-clients issue opencode-284 --default-user default' "$log" ||
  fail 'the terminal CT (found by its address) did not issue a key'
[[ $(cat "$fake/pushed-284-open-terminal-key") == ot-client-key-1-0123456789 ]] || fail 'the key was not pushed as a file'
grep -qxF "$ot_rule" "$fake/pve/firewall/270.fw" || fail "terminal firewall: $(cat "$fake/pve/firewall/270.fw")"
grep -qxF "$ot_egress" "$fwfile" || fail "Open Terminal egress rule: $(cat "$fwfile")"
: > "$log"; rm -f "$fake"/pushed-*
out=$(real --reconfigure) || fail "plain reconfigure with Open Terminal: $out"
[[ $out == *'Keeping the Open Terminal workspace at http://192.0.2.70:8000'* ]] || fail "no keep notice: $out"
grep -q ' issue ' "$log" && fail 'a plain reconfigure rotated a working key'
: > "$log"
out=$(real --reconfigure OPEN_TERMINAL_URL=) || fail "Open Terminal off: $out"
grep -q 'pct exec 270 -- /usr/local/sbin/open-terminal-clients revoke opencode-284 --missing-ok' "$log" || fail 'the key was not revoked'
grep -q 'opencode-284' "$fake/pve/firewall/270.fw" && fail 'the terminal firewall still admits the CT'
grep -q '192.0.2.70/32' "$fwfile" && fail 'OPEN_TERMINAL_URL= kept the egress rule'
[[ -z $(secrets_in_argv) ]] || fail "a secret appeared in a command line: $(secrets_in_argv)"
pass 'Open Terminal: key issued by the terminal CT and kept while valid, both firewalls; OPEN_TERMINAL_URL= revokes it'

: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCODE_PORT=4100) || fail "router move: $out"
grep -q 'OUT ACCEPT -dest 192.0.2.80/32 -p tcp -dport 8000' "$fake/fw-at-guest" &&
  grep -q 'OUT ACCEPT -dest 192.0.2.90/32 -p tcp -dport 8000' "$fake/fw-at-guest" ||
  fail "the guest step did not reach the old and the new router: $(cat "$fake/fw-at-guest")"
grep -q '192.0.2.80' "$fwfile" && fail "the old router address is still admitted: $(cat "$fwfile")"
grep -q -- '-dport 4100 -log nolog # ollama-smart-router opencode-web' "$fwfile" || fail 'new web rule'
grep -q 'dport 4096' "$fwfile" && fail 'the old port is still open'
grep -qx 'OUT ACCEPT -p tcp -dport 443 -log nolog' "$fwfile" || fail 'the other egress rules were lost'
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCODE_PORT=4200 FAKE_GUEST_RC=1) && fail 'a failed guest step was accepted'
grep -q 'dport 4100 ' "$fwfile" && grep -q 'dport 4200 ' "$fwfile" || fail "a failed reconfigure closed the working port: $(cat "$fwfile")"
cp "$fwfile" "$fwfile.clean"
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCODE_PORT=4100 FAKE_FW_EDIT=1) && fail 'a firewall edited during the run was accepted'
[[ $out == *'changed meanwhile'* ]] || fail "edited firewall message: $out"
cp "$fwfile.clean" "$fwfile"
: > "$log"; touch "$fake/swap-edit"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCODE_PORT=4100 OSR_FW_SWAP_TEST_EDIT_FILE="$fake/swap-edit") &&
  fail 'an edit racing the first firewall update was overwritten'
[[ $out == *'Nothing was changed'* ]] || fail "racing first update message: $out"
grep -q 'install-target.sh' "$log" && fail 'the guest ran after the first firewall update was refused'
grep -q '# edited meanwhile' "$fwfile" || fail 'the racing edit was lost'
cp "$fwfile.clean" "$fwfile"; rm -f -- "$fake/swap-edit"
pass 'firewall updates follow a router move and port change, keep the old rules after a failed guest step, and never overwrite a racing edit'
rm -f -- "$fwfile"
: > "$log"
out=$(real --reconfigure ROUTER_IP=192.0.2.90 OPENCODE_PORT=4100 OPENCODE_ACCESS_CIDR=192.0.2.0/24) || fail "missing firewall file: $out"
[[ $out == *'does not exist'* ]] || fail "missing firewall warning: $out"
[[ ! -e $fwfile ]] || fail 'a firewall file was created for a CT that had none'
pass 'a missing firewall file stays missing, with a warning'

# Model servers by host name, and URLs without a port.
reset_fake
servers=strata+http://models.lan:8080,http://plain.lan,maya+https://secure.lan,http://192.0.2.75,http://nowhere.lan:11434
dns='FAKE_CT_DNS=models.lan=192.0.2.73,192.0.2.74;plain.lan=192.0.2.76;secure.lan=192.0.2.77'
out=$(real FAKE_INVENTORY_SERVERS=$servers "$dns") || fail "model servers by name: $out"
for want in 192.0.2.73/32:8080 192.0.2.74/32:8080 192.0.2.76/32:80 192.0.2.77/32:443 192.0.2.75/32:80; do
  rule="OUT ACCEPT -dest ${want%:*} -p tcp -dport ${want##*:} -log nolog # ollama-smart-router opencode-model"
  grep -qxF "$rule" "$fwfile" || fail "missing $rule: $(cat "$fwfile")"
  grep -qxF "$rule" "$fake/fw-at-guest" || fail "not admitted before the guest step: $rule"
done
grep -q '198.51.100.99' "$fwfile" && fail 'a model server was resolved on the Proxmox host'
[[ $out == *'cannot resolve model server nowhere.lan'* ]] || fail "unresolvable name not reported: $out"
pass 'model server names are resolved inside the CT (every address) and ports default to 80/443'

reset_fake
mkdir -p "$fake/ct284"
printf 'description: unrelated CT\n' > "$fake/ct284/description"
printf '[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 4096 -log nolog # ollama-smart-router opencode-web\n' > "$fwfile"
out=$(real --reconfigure) && fail 'an unrelated CT without OpenCode settings was accepted'
[[ $out == *'no completed OpenCode installation'* ]] || fail "unrelated CT message: $out"
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
mkdir -p "$fake/net/lo"; reset_fake
pass 'a run without root, or without its bridge, is refused before anything is created'

[[ $(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'opencode-setup.*' | wc -l) == "$stages_before" ]] ||
  fail 'a run left its host staging directory (it can hold the router key) behind'
pass 'every run, failed or not, removes its host staging directory'

# Guided prompts: Router first, then the OpenCode container, its settings,
# Honcho and Open Terminal; offers come from the PVE configs.
glxc=$(mktemp -d)
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.80/24\ntags: osr-router\n' > "$glxc/280.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.85/24\ntags: osr-target;honcho\n' > "$glxc/285.conf"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.70/24\ntags: osr-target;open-terminal\n' > "$glxc/270.conf"
answers=$'\n282\nlocal:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst\nlocal-lvm\n192.0.2.82/24\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n'
out=$(env -i "PATH=$PATH" PVE_INTERACTIVE=true PVE_LXC_DIR="$glxc" bash "$provision" --dry-run 2>&1 <<< "$answers") ||
  fail "guided create: $out"
order=$(sed '/== OpenCode: /q' <<< "$out" | grep -oE '== [A-Za-z: ]+ ==|Router CT ID or address|New OpenCode CT ID|amd64 template|Root disk storage|OpenCode IP/CIDR|OpenCode gateway|OSR model or tier|Context window|Max reply tokens|OpenCode release|Web UI and API port|Serve the OpenCode web UI|Web UI allowed from|Offer OpenCode in Open WebUI|Chat endpoint port|Tool permission requests|Honcho API URL|Open Terminal URL' | paste -sd'|')
[[ $order == '== Router ==|Router CT ID or address|== OpenCode container ==|New OpenCode CT ID|amd64 template|Root disk storage|OpenCode IP/CIDR|OpenCode gateway|== OpenCode settings ==|OSR model or tier|Context window|Max reply tokens|OpenCode release|Web UI and API port|Serve the OpenCode web UI|Web UI allowed from|Offer OpenCode in Open WebUI|Chat endpoint port|Tool permission requests|== Honcho memory ==|Honcho API URL|== Open Terminal workspace ==|Open Terminal URL|== OpenCode: create ==' ]] ||
  fail "create prompts out of order: $order"
[[ $out == *'Router CT ID or address [280]'* && $out == *'OpenCode gateway [192.0.2.1]'* && $out == *'Web UI allowed from (IPv4 CIDR) [192.0.2.0/24]'* &&
   $out == *'Offer OpenCode in Open WebUI (as opencode)? [Y/n]'* && $out == *'Chat endpoint port (for Open WebUI) [4097]'* ]] ||
  fail "offers: $out"
[[ $out == *'Honcho API URL (none to skip) [http://192.0.2.85:8000]'* && $out == *'HONCHO_URL=http://192.0.2.85:8000'* &&
   $out == *'honcho-clients issue opencode-282'* ]] || fail "the Honcho CT on this host was not offered or taken: $out"
[[ $out == *'Open Terminal URL (none to skip) [http://192.0.2.70:8000]'* && $out == *'OPEN_TERMINAL_URL=http://192.0.2.70:8000'* ]] ||
  fail "the Open Terminal CT on this host was not offered or taken: $out"
printf 'net0: name=eth0,bridge=vmbr0,gw=192.0.2.1,ip=192.0.2.82/24\ntags: osr-target;opencode\n' > "$glxc/282.conf"
out=$(env -i "PATH=$PATH" PVE_INTERACTIVE=true PVE_LXC_DIR="$glxc" HONCHO_URL= OPEN_TERMINAL_URL= bash "$provision" --dry-run --reconfigure 2>&1 <<< $'\n\n\n\n\n\n\n\n\n\n\n\n\n') ||
  fail "guided reconfigure: $out"
order=$(sed '/== OpenCode: /q' <<< "$out" | grep -oE '== [A-Za-z: ]+ ==|OpenCode CT ID|Router CT ID or address' | paste -sd'|')
[[ $order == '== OpenCode container to reconfigure ==|OpenCode CT ID|== Router ==|Router CT ID or address|== OpenCode settings ==|== OpenCode: reconfigure ==' ]] ||
  fail "reconfigure prompts out of order: $order"
[[ $out == *'OpenCode CT ID [282]'* && $out != *'OpenCode IP/CIDR'* ]] || fail "reconfigure CT offer: $out"
[[ $out == *'Offer OpenCode in Open WebUI (as opencode)? [y/N]'* ]] || fail "a reconfigure of a CT that records no chat endpoint offers it on: $out"
rm -rf -- "$glxc"
pass 'guided prompts: router, container, settings, Open WebUI, Honcho, Open Terminal; a reconfigure starts with the CT, offered by its tag'

printf '%s provision cases passed. No CT was created.\n' "$passed"
