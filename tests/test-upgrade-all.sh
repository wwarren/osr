#!/usr/bin/env bash
# tools/upgrade-all.sh: its tables against the provisioners, and whole runs
# against a mocked pct (no Proxmox, CT or network needed).
set -uo pipefail
exec </dev/null

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$HERE/.." && pwd)
TOOL=$ROOT/tools/upgrade-all.sh
# shellcheck source=tests/lib/assert.sh
source "$HERE/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --- Tables --------------------------------------------------------------------------

# The script only defines things when sourced; read its tables in a subshell.
tables() {
    # shellcheck disable=SC1090
    ( source "$TOOL"; set +u; "$@" )
}

describe 'guest file lists match what each provisioner copies'
pushed_files() {  # the files provision-lxc.sh copies into the CT's deploy directory
    python3 - "$ROOT/targets/$1/provision-lxc.sh" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
names = set()
for n, line in enumerate(lines):
    m = re.match(r'\s*(?:deploy_)?files=\(([^)]*)\)', line)
    if m:
        names.update(m.group(1).split())
    m = re.match(r'\s*for file in ([^;"$]+); do', line)
    if m and n + 1 < len(lines) and "pct push" in lines[n + 1]:
        names.update(m.group(1).split())
    for m in re.finditer(r'pct push "\$CT_ID" "\$source_dir/([A-Za-z0-9._-]+)"', line):
        names.add(m.group(1))
print(" ".join(sorted(names)))
PY
}
for target in strata basalt maya xolotl avalon kindi airllm llamacpp ollama comfyui open-terminal; do
    listed=$(tables eval "printf '%s\n' \${GUEST_FILES[$target]} | sort | tr '\n' ' '")
    expected=$(pushed_files "$target" | tr ' ' '\n' | sort | tr '\n' ' ')
    assert_eq "$target deploys the provisioner's files" "$expected" "$listed"
    for file in $listed; do
        [[ -f $ROOT/targets/$target/$file ]] || _fail "$target/$file exists" "a file" "missing"
    done
done

describe 'every target has an upgrade method and known services'
for target in $(tables eval 'printf "%s\n" "${TARGET_ORDER[@]}"') router open-webui hcom; do
    assert_ne "$target has a method" unknown "$(tables method_of "$target")"
    assert_ne "$target has services to check" '' "$(tables eval "printf '%s' \"\${UNITS[$target]:-}\"")"
done
for unit_file in "$ROOT"/targets/*/*.service "$ROOT"/services/*/*.service; do
    target=$(basename "$(dirname "$unit_file")")
    unit=$(basename "$unit_file" .service)
    case $target in ollama-router|litellm-proxy|ollama-monitor|open-webui) target=router ;; esac
    assert_contains "$unit.service is checked for $target" " $unit " " $(tables eval "printf '%s' \"\${UNITS[$target]:-}\"") "
done

describe 'repository pins are found'
assert_ne 'DeepSeek Harness pin' '' "$(tables repo_default dsh)"
assert_ne 'Honcho pin' '' "$(tables repo_default honcho)"

# --- Mocked runs ---------------------------------------------------------------------

mkdir -p "$tmp/bin" "$tmp/nodes/pve1/lxc" "$tmp/nodes/pve2/lxc" "$tmp/nodes/pve3/lxc" "$tmp/fw" "$tmp/mock" "$tmp/remote-tmp"
# A three-node cluster: this run is on pve1; pve2 is reached over (fake) SSH;
# pve3 is offline.
cat > "$tmp/members" <<'JSON'
{"nodename": "pve1", "version": 3,
 "nodelist": {"pve1": {"id": 1, "online": 1, "ip": "10.0.0.1"},
              "pve2": {"id": 2, "online": 1, "ip": "10.0.0.2"},
              "pve3": {"id": 3, "online": 0, "ip": "10.0.0.3"}}}
JSON
# The fake ssh runs the command here, as the node named by HostKeyAlias.
cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
node='' dest='' cmd='' nostdin=false
while (( $# )); do
    case $1 in
        -o) [[ $2 != HostKeyAlias=* ]] || node=${2#*=}; shift 2 ;;
        -e) shift 2 ;;
        -O|-fN) exit 0 ;;
        -n) nostdin=true; shift ;;
        -T|-tt) shift ;;
        # Like OpenSSH: a "--" after the destination is not part of the command.
        root@*) dest=$1; shift; [[ ${1:-} != -- ]] || shift; cmd=${1:-}; break ;;
        *) dest=$1; shift ;;
    esac
done
printf '%s %s\n' "$node" "$dest" >> "$MOCK/ssh.log"
if [[ -e $MOCK/down-$node ]]; then echo "ssh: connect to host $dest: Connection refused" >&2; exit 255; fi
# Like real ssh: without -n it reads all of our stdin and forwards it.
if $nostdin; then exec </dev/null
else forwarded=$(mktemp); cat > "$forwarded"; exec < "$forwarded"; rm -f -- "$forwarded"; fi
OSR_MOCK_NODE=$node TMPDIR=$MOCK_REMOTE_TMP exec bash -c "$cmd"
MOCK
cat > "$tmp/bin/id" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then echo 0; else /usr/bin/id "$@"; fi
MOCK
# State files: <id>.state lists what works; <id>.upgrade says what an upgrade
# does (ok, nothing, break, fail, fail-break).
cat > "$tmp/bin/pct" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "${OSR_MOCK_NODE:-pve1}" "$*" >> "$MOCK/pct.log"
cmd=$1 id=${2:-}
case $cmd in
    status) if [[ -e $MOCK/$id.stopped ]]; then echo 'status: stopped'; else echo 'status: running'; fi ;;
    config) printf 'hostname: ct%s\nnet0: name=eth0,bridge=vmbr0,ip=10.0.0.%s/24,gw=10.0.0.1\n' "$id" "$((id % 250))" ;;
    snapshot) [[ ! -e $MOCK/$id.nosnap ]] || exit 1 ;;
    delsnapshot|stop|start) : ;;
    rollback) cp "$MOCK/$id.state.orig" "$MOCK/$id.state" ;;
    push) cat -- "$3" > "$MOCK/pushed-$id-${4##*/}" ;;
    pull) echo "pulled $3" > "$4" ;;
    exec)
        shift 3
        case $1 in
            sh)
                if [[ $3 == *osr-hcom-relay* ]]; then
                    [[ -e $MOCK/$id.hcom ]] || exit 3
                    cat "$MOCK/$id.hcom"; exit 0
                fi
                if [[ $3 == webui-admin ]]; then
                    # Open WebUI's admin check: the header arrives on stdin.
                    IFS= read -r header || header=''
                    if [[ -e $MOCK/webui-down ]]; then echo 000
                    elif [[ -e $MOCK/webui-token && $header == "Authorization: Bearer $(cat "$MOCK/webui-token")" ]]; then echo 200
                    else echo 401; fi
                    exit 0
                fi
                if [[ $3 == *http:hermes-gateway* ]]; then
                    [[ ! -e $MOCK/$id.http ]] || cat "$MOCK/$id.http"; exit 0
                fi
                if [[ $3 == *systemctl* ]]; then grep -v '^ct:' "$MOCK/$id.state"; fi ;;
            hostname) echo "10.0.0.$((id % 250))" ;;
            sed)
                case "$*" in
                    *service.env*) [[ ! -e $MOCK/$id.port ]] || cat "$MOCK/$id.port" ;;
                    *requirements.txt*) [[ ! -e $MOCK/$id.ctpin ]] || cat "$MOCK/$id.ctpin" ;;
                    *DSH_VERSION*) [[ ! -e $MOCK/$id.dsh ]] || cat "$MOCK/$id.dsh" ;;
                    *HERMES_COMMIT*) [[ ! -e $MOCK/$id.hermes-pin-read-fails ]] || exit 1
                                     [[ ! -e $MOCK/$id.hermes-pin ]] || cat "$MOCK/$id.hermes-pin" ;;
                esac ;;
            # Hermes's checkout, hermes update (moves it to <id>.hermes-next)
            # and the restart after it.
            git) [[ ! -e $MOCK/$id.hermes-commit ]] || cat "$MOCK/$id.hermes-commit" ;;
            runuser)
                printf 'RUNUSER %s %s\n' "$id" "$*" >> "$MOCK/installs.log"
                [[ ! -e $MOCK/$id.hermes-update-fails ]] || exit 1
                [[ ! -e $MOCK/$id.hermes-next ]] || cp "$MOCK/$id.hermes-next" "$MOCK/$id.hermes-commit" ;;
            systemctl) printf 'SYSTEMCTL %s %s\n' "$id" "$*" >> "$MOCK/installs.log" ;;
            /app/openwebui/venv/bin/python) [[ ! -e $MOCK/$id.webui ]] || cat "$MOCK/$id.webui" ;;
            python3) echo 'mqtts://broker.lan:8883' ;;
            test) [[ -e $MOCK/$id.tls ]] ;;
            grep) [[ -e $MOCK/$id.webui-api ]] || exit 1 ;;
            /usr/local/bin/manage-model-servers) printf 'MANAGE %s %s\n' "$id" "$*" >> "$MOCK/installs.log" ;;
            install) : ;;
            env)
                printf 'INSTALL %s %s\n' "$id" "$*" >> "$MOCK/installs.log"
                case $(cat "$MOCK/$id.upgrade" 2>/dev/null || echo ok) in
                    ok) echo 'upgraded' ;;
                    nothing) echo 'same commit: nothing to do' ;;
                    break) sed -i '/^unit:/d' "$MOCK/$id.state"; echo 'upgraded (but broke)' ;;
                    fail) echo 'failed; rolled back'; exit 1 ;;
                    fail-break) sed -i '/^unit:/d' "$MOCK/$id.state"; echo 'failed badly'; exit 1 ;;
                esac ;;
        esac ;;
esac
exit 0
MOCK
chmod +x "$tmp/bin/"*

conf() {  # conf ID TAGS [NODE]: a CT configuration on NODE (pve1, this node)
    rm -f "$tmp"/nodes/*/lxc/"$1".conf
    printf 'arch: amd64\nhostname: ct%s\ntags: %s\n' "$1" "$2" > "$tmp/nodes/${3:-pve1}/lxc/$1.conf"
}
state() {  # state ID UNIT...: what works in that CT
    local id=$1; shift
    { echo ct:running; printf 'unit:%s\n' "$@"; echo 'ss: LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*'; } > "$tmp/mock/$id.state"
    cp "$tmp/mock/$id.state" "$tmp/mock/$id.state.orig"
}
reset_mock() {
    rm -rf "$tmp"/nodes/*/lxc/* "$tmp/mock"/* "$tmp/remote-tmp"/* "$tmp/logs" "$tmp/cluster.lock"
    conf 251 'ai;ai-model;osr-target;strata'; state 251 strata
    conf 252 'ai;ai-model;osr-target;ollama'; state 252 ollama
}
CLUSTER_ENV=(MOCK="$tmp/mock" MOCK_REMOTE_TMP="$tmp/remote-tmp" PVE_NODES_DIR="$tmp/nodes" PVE_MEMBERS="$tmp/members"
             OSR_LOCAL_NODE=pve1 OSR_REMOTE_PCT="$tmp/bin/pct" OSR_UPGRADE_CLUSTER_LOCK="$tmp/cluster.lock")
run_tool() {  # run_tool ANSWERS ARGS...: output in $out, status in $rc
    local answers=$1; shift
    printf '%b' "$answers" > "$tmp/answers"
    rm -rf "$tmp/logs"
    rc=0
    out=$(env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" PVE_FW_DIR="$tmp/fw" \
              OSR_UPGRADE_LOG_DIR="$tmp/logs" OSR_UPGRADE_LOCK="$tmp/lock" HEALTH_TIMEOUT=0 POLL_INTERVAL=0 \
              OSR_UPGRADE_TTY="${OSR_UPGRADE_TTY:-$tmp/no-tty}" \
              ${answers:+OSR_UPGRADE_ANSWERS="$tmp/answers"} bash "$TOOL" "$@" 2>&1) || rc=$?
}
summary_line() { grep -E "^$1 +$2 " "$tmp"/logs/*/summary.txt 2>/dev/null | awk '{ print $4 }'; }

describe 'discovery'
reset_mock
conf 260 'ai;osr-target;something-new'; state 260 x
run_tool '' --list
assert_eq '--list exits 0' 0 "$rc"
assert_contains 'finds ollama' $'ollama\t252' "$out"
assert_contains 'finds strata' $'strata\t251' "$out"
assert_contains 'leaves unknown targets alone' 'CT 260 is tagged osr-target but names no target' "$out"
assert_contains 'says there is no router' 'No router CT' "$out"
run_tool '' --list --only strata
assert_not_contains '--only filters' $'ollama\t' "$out"
run_tool '' --list --skip 251
assert_not_contains '--skip filters by CT ID' $'strata\t' "$out"

describe 'dry run'
reset_mock
run_tool '' --dry-run
assert_eq '--dry-run exits 0' 0 "$rc"
plan=$(sed -n '/==== Plan ====/,$p' <<< "$out")
assert_contains 'plans the upgrade' 'install-target.sh --upgrade' "$plan"
[[ $(grep -n '^ollama' <<< "$plan" | cut -d: -f1) -lt $(grep -n '^strata' <<< "$plan" | cut -d: -f1) ]] &&
    _pass 'ollama before strata' || _fail 'ollama before strata' 'TARGET_ORDER' "$plan"
assert_eq 'changes nothing' '' "$(grep -E 'snapshot|push|env' "$tmp/mock/pct.log")"

describe 'successful upgrade'
reset_mock
run_tool 'y\n' --only strata
assert_eq 'exits 0' 0 "$rc"
assert_eq 'strata upgraded' upgraded "$(summary_line strata 251)"
assert_file_contains 'pushes the installer' "push 251 $ROOT/targets/strata/install-target.sh /root/strata-target-deploy/install-target.sh --perms 0755" "$tmp/mock/pct.log"
assert_file_contains 'pushes the unit' 'strata.service --perms 0644' "$tmp/mock/pct.log"
assert_file_contains 'runs --upgrade' 'install-target.sh --upgrade' "$tmp/mock/installs.log"
assert_file_contains 'takes a snapshot' 'snapshot 251 osr-upg-' "$tmp/mock/pct.log"
assert_file_contains 'drops it afterwards' 'delsnapshot 251 osr-upg-' "$tmp/mock/pct.log"

describe 'unchanged target'
reset_mock
echo nothing > "$tmp/mock/251.upgrade"
run_tool 'y\n' --only strata
assert_eq 'reported current' current "$(summary_line strata 251)"

describe 'broken by the upgrade: roll back'
reset_mock
echo break > "$tmp/mock/252.upgrade"
run_tool 'y\nb\n'
assert_eq 'exits 1' 1 "$rc"
assert_contains 'names what broke' 'service ollama is no longer active' "$out"
assert_file_contains 'rolls back' 'rollback 252 osr-upg-' "$tmp/mock/pct.log"
assert_eq 'ollama rolled back' rolled-back "$(summary_line ollama 252)"
assert_eq 'continues with strata' upgraded "$(summary_line strata 251)"

describe 'broken by the upgrade: skip'
reset_mock
echo break > "$tmp/mock/252.upgrade"
run_tool 'y\ns\n'
assert_eq 'ollama left broken' broken "$(summary_line ollama 252)"
assert_contains 'keeps the snapshot' 'snapshot osr-upg-' "$(grep '^ollama' "$tmp"/logs/*/summary.txt)"
assert_eq 'snapshot not deleted' '' "$(grep 'delsnapshot 252' "$tmp/mock/pct.log")"
assert_eq 'continues with strata' upgraded "$(summary_line strata 251)"
reset_mock
echo fail-break > "$tmp/mock/252.upgrade"
run_tool 'y\ns\n'
line=$(grep '^ollama' "$tmp"/logs/*/summary.txt)
assert_contains 'failed and broken: the exit status is in the summary' 'exit 1' "$line"
assert_contains 'and the snapshot recovery command' 'pct rollback 252 osr-upg-' "$line"
assert_contains 'and the snapshot removal command' 'pct delsnapshot 252 osr-upg-' "$line"

describe 'failed upgrade that rolled itself back'
reset_mock
echo fail > "$tmp/mock/252.upgrade"
run_tool 'y\n\n'
assert_contains 'says the checks still pass' 'Everything that worked before still passes the checks' "$out"
assert_eq 'default is skip' skipped "$(summary_line ollama 252)"
assert_eq 'its snapshot is kept' '' "$(grep 'delsnapshot 252' "$tmp/mock/pct.log")"
line=$(grep '^ollama' "$tmp"/logs/*/summary.txt)
assert_contains 'the summary says how to roll back' 'pct rollback 252 osr-upg-' "$line"
assert_contains 'and how to drop the snapshot' 'pct delsnapshot 252 osr-upg-' "$line"
assert_contains 'with the exit status' 'exit 1' "$line"
assert_not_contains 'without claiming the old version runs' 'previous version still works' "$line"

describe 'retry'
reset_mock
echo fail > "$tmp/mock/252.upgrade"
run_tool 'y\nr\ns\n'
assert_eq 'runs the upgrade twice' 2 "$(grep -c '^INSTALL 252' "$tmp/mock/installs.log")"

describe 'abort'
reset_mock
echo fail-break > "$tmp/mock/252.upgrade"
run_tool 'y\na\n'
assert_eq 'ollama broken' broken "$(summary_line ollama 252)"
assert_eq 'strata not run' not-run "$(summary_line strata 251)"
assert_eq 'strata untouched' '' "$(grep '^INSTALL 251' "$tmp/mock/installs.log" 2>/dev/null)"
line=$(grep '^ollama' "$tmp"/logs/*/summary.txt)
assert_contains 'the aborted one gives its exit status' 'failed (exit 1)' "$line"
assert_contains 'and how to roll back' 'pct rollback 252 osr-upg-' "$line"
assert_contains 'and how to drop the snapshot' 'pct delsnapshot 252 osr-upg-' "$line"

describe 'unattended'
reset_mock
echo break > "$tmp/mock/252.upgrade"
run_tool '' --yes
assert_eq 'rolls back by default' rolled-back "$(summary_line ollama 252)"
reset_mock
echo break > "$tmp/mock/252.upgrade"
run_tool '' --yes --on-failure abort
assert_eq '--on-failure abort stops' not-run "$(summary_line strata 251)"

describe 'snapshots'
reset_mock
touch "$tmp/mock/251.nosnap"
run_tool '' --yes --only strata
assert_eq 'upgrades without one when it cannot' upgraded "$(summary_line strata 251)"
run_tool '' --yes --only strata --require-snapshot
assert_eq '--require-snapshot skips' skipped "$(summary_line strata 251)"
reset_mock
run_tool '' --yes --only strata --no-snapshot
assert_eq '--no-snapshot takes none' '' "$(grep snapshot "$tmp/mock/pct.log")"

describe 'stopped CTs'
reset_mock
touch "$tmp/mock/252.stopped"
run_tool '' --yes
assert_eq 'stopped CT left alone' not-run "$(summary_line ollama 252)"
assert_eq 'not upgraded' '' "$(grep '^INSTALL 252' "$tmp/mock/installs.log" 2>/dev/null)"

describe 'Open Terminal keeps its port'
reset_mock
conf 270 'ai;ai-tools;osr-target;open-terminal'; state 270 open-terminal
echo 8123 > "$tmp/mock/270.port"
run_tool '' --yes --only open-terminal
assert_file_contains 'passes the recorded port' 'OPEN_TERMINAL_PORT=8123 bash /root/open-terminal-deploy/install-target.sh' "$tmp/mock/installs.log"
assert_eq 'without --upgrade' '' "$(grep -- '--upgrade' "$tmp/mock/installs.log")"

describe 'router, Open WebUI and hcom are found'
reset_mock
conf 280 'ai;ai-tools;osr-router;openwebui'; state 280 ollama-router open-webui
echo 0.11.0 > "$tmp/mock/280.webui"; echo 0.11.0 > "$tmp/mock/280.ctpin"
conf 282 'ai;ai-tools;osr-target;hermes'; state 282 hermes-gateway
printf 'target=hermes\nnative=false\n' > "$tmp/mock/282.hcom"
conf 290 'ai;ai-tools;osr-target;mqtt'; state 290 mosquitto
printf 'target=observer\nnative=false\n' > "$tmp/mock/290.hcom"
run_tool '' --list
assert_contains 'router first' $'router\t280' "$(head -n 3 <<< "$out")"
assert_contains 'hcom in the agent' $'hcom\t282\tpve1\ttarget=hermes' "$out"
[[ $(grep -n $'^hcom\t290' <<< "$out" | cut -d: -f1) -gt $(grep -n $'^hcom\t282' <<< "$out" | cut -d: -f1) ]] &&
    _pass 'observer after the agents' || _fail 'observer after the agents' 'observer last' "$out"
run_tool '' --dry-run --skip router
assert_contains 'Open WebUI moves to the pin' "set-webui-version $(sed -n 's/^open-webui==//p' "$ROOT/services/open-webui/requirements.txt")" "$out"
assert_contains 'hcom uses the one broker' 'broker CT 290' "$out"
echo 99.0.0 > "$tmp/mock/280.webui"
run_tool '' --dry-run --skip router
assert_contains 'never downgrades Open WebUI' 'keeps Open WebUI 99.0.0' "$out"
rm "$tmp/nodes/pve1/lxc/290.conf"
run_tool '' --dry-run --skip router
assert_contains 'hcom needs a broker' 'set MQTT_CT_ID' "$out"

# Functions called directly, with the mocked pct on PATH.
in_tool() {
    ( export PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" PVE_FW_DIR="$tmp/fw" \
             OSR_UPGRADE_TTY="${OSR_UPGRADE_TTY:-$tmp/no-tty}"
      # shellcheck disable=SC1090
      source "$TOOL"; set +u
      RUN_DIR=$tmp/run; mkdir -p "$RUN_DIR"
      setup_cluster
      # shellcheck disable=SC2034  # read by the sourced functions
      DRY_RUN=false INTERACTIVE=false KEEP_PINS=false ROUTER_CT=280 REPO_REV=test
      "$@" )
}

describe 'MQTT settings are read back from the broker'
reset_mock
printf 'hostname: mqtt\n' > "$tmp/nodes/pve1/lxc/290.conf"
printf '[RULES]\nIN ACCEPT -source 10.0.0.0/24 -p tcp -dport 8883 -log nolog # osr-hcom-mqtt\n' > "$tmp/fw/290.fw"
touch "$tmp/mock/290.tls"
settings=$(in_tool mqtt_env 290 "$tmp/run/mqtt-290")
assert_contains 'client CIDR from the firewall' 'MQTT_CLIENT_CIDR=10.0.0.0/24' "$settings"
assert_contains 'address from net0' 'IP_CIDR=10.0.0.40/24' "$settings"
assert_contains 'gateway from net0' 'GATEWAY=10.0.0.1' "$settings"
assert_contains 'host from the bundle' 'MQTT_HOST=broker.lan' "$settings"
assert_contains 'port from the bundle' 'MQTT_PORT=8883' "$settings"
assert_contains 'TLS files handed back' "MQTT_TLS_KEY_FILE=$tmp/run/mqtt-290/tls.key" "$settings"
rm "$tmp/fw/290.fw"
assert_fail 'refuses without its firewall rule' in_tool mqtt_env 290 "$tmp/run/mqtt-290"

describe 'pinned releases'
pin_case() {
    # shellcheck disable=SC2034  # read by decide_pin
    KEEP_PINS=${2:-false}
    add_item deepseek-harness 281
    decide_pin 0 DSH_VERSION "$1" 0.2.1-rc.5
    echo "${I_INFO[0]}|${I_NOTE[0]}"
}
pin_result() { in_tool pin_case "$@"; }
assert_contains 'moves an older pin' 'DSH_VERSION=0.2.1-rc.5' "$(pin_result 0.2.0)"
assert_contains 'keeps latest' 'keeps DSH_VERSION=latest' "$(pin_result latest)"
assert_contains '--keep-pins keeps it' 'keeps DSH_VERSION=0.2.0' "$(pin_result 0.2.0 true)"
assert_eq 'nothing when already pinned' '|' "$(pin_result 0.2.1-rc.5)"
assert_contains 'never downgrades' 'newer than the pin' "$(pin_result 0.3.0)"
assert_contains 'a final release is newer than its rc' 'newer than the pin' "$(pin_result 0.2.1)"
assert_contains 'an older rc moves' 'DSH_VERSION=0.2.1-rc.5' "$(pin_result 0.2.1-rc.4)"

describe 'router configuration is pushed only after a good router step'
reset_mock
# shellcheck disable=SC2034  # I_RESULT is read by push_router_config
push_case() {
    add_item router 280; add_item open-webui 280
    I_RESULT[0]=$1
    I_RESULT[1]=$2
    push_router_config
}
push_with() {  # push_with ROUTER_RESULT WEBUI_RESULT: how many pushes
    rm -f "$tmp/mock/installs.log"
    in_tool push_case "$@" 2>/dev/null
    cat "$tmp/mock/installs.log" 2>/dev/null | grep -c 'manage-model-servers commit'
}
assert_eq 'after an upgrade' 1 "$(push_with upgraded current)"
assert_eq 'after an Open WebUI upgrade' 1 "$(push_with current upgraded)"
assert_eq 'not when nothing changed' 0 "$(push_with current current)"
assert_eq 'not after a rollback' 0 "$(push_with rolled-back upgraded)"

describe 'the hcom probe reads what the installer recorded'
probe_root=$tmp/probe
mkdir -p "$tmp/probe-bin"
cat > "$tmp/probe-bin/systemctl" <<'MOCK'
#!/bin/sh
# list-unit-files --no-legend NAME.service: listed when $PROBE_UNITS names it.
for u in $PROBE_UNITS; do [ "$u.service" = "$3" ] && echo "$3 enabled enabled"; done
exit 0
MOCK
chmod +x "$tmp/probe-bin/systemctl"
probe() {  # probe UNITS...: the probe's output for the fake CT in $probe_root
    PROBE_UNITS="$*" OSR_PROBE_ROOT=$probe_root PATH="$tmp/probe-bin:$PATH" \
        sh -c "$(tables eval 'printf "%s" "$HCOM_PROBE"')"
}
reset_probe() { rm -rf "$probe_root"; mkdir -p "$probe_root/etc/osr-hcom" "$probe_root/home/hermes/.hermes" "$probe_root/var/lib" "$probe_root/root"; }
reset_probe
assert_status 'exits 3 without hcom' 3 probe hermes-gateway
echo openclaw > "$probe_root/etc/osr-hcom/target"
assert_contains 'target from /etc/osr-hcom/target' 'target=openclaw' "$(probe osr-hcom-relay hermes-gateway openclaw-gateway)"
reset_probe
echo hermes > "$probe_root/etc/osr-hcom/target"
mkdir -p "$probe_root/home/hermes/.osr-hcom"; touch "$probe_root/home/hermes/.osr-hcom/config.toml"
printf '<!-- osr-hcom:start -->\nold block\n<!-- osr-hcom:end -->\n' > "$probe_root/home/hermes/.hermes/AGENTS.md"
out=$(probe osr-hcom-relay hermes-gateway)
assert_contains 'legacy state in the agent account is not native mode' 'native=false' "$out"
assert_not_contains 'the legacy instructions file is left to the installer to migrate' 'instructions=' "$out"
mkdir -p "$probe_root/etc/systemd/system/hermes-gateway.service.d"
printf '[Service]\nEnvironment=HCOM_DIR=/home/hermes/.osr-hcom\n' > "$probe_root/etc/systemd/system/hermes-gateway.service.d/30-osr-hcom.conf"
assert_contains 'the HCOM_DIR drop-in means native mode' 'native=true' "$(probe osr-hcom-relay hermes-gateway)"
reset_probe
echo deepseek-harness > "$probe_root/etc/osr-hcom/target"
mkdir -p "$probe_root/root/profiles"
printf '<!-- osr-hcom:start -->\nblock\n<!-- osr-hcom:end -->\n' > "$probe_root/root/profiles/CUSTOM.md"
out=$(probe osr-hcom-relay deepseek-harness)
assert_contains 'a custom instructions file is kept, as a CT path' 'instructions=/root/profiles/CUSTOM.md' "$out"
assert_contains 'native mode is only for Hermes' 'native=false' "$out"
reset_probe
echo observer > "$probe_root/etc/osr-hcom/target"; touch "$probe_root/etc/osr-hcom/mattermost-webhook"
out=$(probe osr-hcom-relay)
assert_contains 'an observer' 'target=observer' "$out"
assert_contains 'that posts to Mattermost' 'mattermost=true' "$out"

describe 'unattended runs need the Open WebUI token for agents registered there'
reset_mock
conf 282 'ai;ai-tools;osr-target;hermes'; state 282 hermes-gateway
touch "$tmp/mock/282.webui-api"
run_tool '' --dry-run --only hermes
assert_contains 'says what to set' 'not-run: set OPENWEBUI_ADMIN_TOKEN' "$out"
OPENWEBUI_ADMIN_TOKEN=test-token run_tool '' --dry-run --only hermes
assert_contains 'runs with the token' 'provision-lxc.sh --reconfigure' "$out"
rm "$tmp/mock/282.webui-api"
run_tool '' --dry-run --only hermes
assert_contains 'runs without an Open WebUI connection' 'provision-lxc.sh --reconfigure' "$out"
conf 285 'ai;ai-tools;osr-target;honcho'; state 285 honcho-api
run_tool '' --dry-run --only honcho
assert_contains 'Honcho always registers' 'not-run: set OPENWEBUI_ADMIN_TOKEN' "$out"
run_tool 'n\n' --only honcho
assert_not_contains 'asked when there is a terminal' 'not-run: set OPENWEBUI_ADMIN_TOKEN' "$out"
printf 'unused\n' > "$tmp/tty"
OSR_UPGRADE_TTY=$tmp/tty run_tool '' --dry-run --yes --only honcho
assert_contains 'a dry run with a terminal says it will ask' 'asks for the Open WebUI admin token when the run starts' "$out"
assert_not_contains 'and does not ask' 'admin API key or session JWT' "$out"

describe 'unattended runs ask for the token at the start'
# token_case TTY_LINES...: ask_token_unattended for router 280 and Hermes 282
# with an Open WebUI connection; prints the token it kept and whether it is
# exported.
token_case() {
    # shellcheck disable=SC2034  # read by ask_token_unattended
    DRY_RUN=false
    add_item router 280; add_item hermes 282
    ask_token_unattended
    printf 'TOKEN=%s EXPORTED=%s\n' "${OPENWEBUI_ADMIN_TOKEN:-}" "$(env | grep -c '^OPENWEBUI_ADMIN_TOKEN=')"
}
ask_with() {  # ask_with LINES: the run's output with LINES typed on the terminal
    printf '%b' "$1" > "$tmp/tty"
    OSR_UPGRADE_TTY=$tmp/tty in_tool token_case 2>&1
}
reset_mock
conf 280 'ai;ai-tools;osr-router;openwebui'; state 280 ollama-router open-webui
conf 282 'ai;ai-tools;osr-target;hermes'; state 282 hermes-gateway
touch "$tmp/mock/282.webui-api"
echo good-token > "$tmp/mock/webui-token"
out=$(ask_with 'good-token\n')
assert_contains 'keeps an accepted token in OPENWEBUI_ADMIN_TOKEN' 'TOKEN=good-token ' "$out"
assert_contains 'without exporting it to every child' 'EXPORTED=0' "$out"
assert_contains 'says Open WebUI accepted it' 'accepted it as an administrator' "$out"
assert_eq 'never on a pct command line' '' "$(grep -F good-token "$tmp/mock/pct.log")"
out=$(ask_with 'wrong\ngood-token\n')
assert_contains 'asks again after a refused token' 'Open WebUI refused it' "$out"
assert_contains 'then keeps the good one' 'TOKEN=good-token ' "$out"
out=$(ask_with 'a\nb\nc\ngood-token\n')
assert_contains 'gives up after three refusals' 'TOKEN= ' "$out"
assert_contains 'and says what that means' 'not upgraded in this run' "$out"
out=$(ask_with '\n')
assert_contains 'Enter skips them' 'TOKEN= ' "$out"
touch "$tmp/mock/webui-down"
out=$(ask_with 'any-token\n')
assert_contains 'keeps a token it cannot check' 'TOKEN=any-token ' "$out"
assert_contains 'and says the provisioners check it' 'each provisioner checks it' "$out"
rm "$tmp/mock/webui-down"
out=$(OSR_UPGRADE_TTY=$tmp/no-tty in_tool token_case 2>&1)
assert_contains 'without a terminal it says what to set' 'No terminal to ask for the Open WebUI admin token' "$out"
out=$(OPENWEBUI_ADMIN_TOKEN=from-env ask_with 'typed\n')
assert_not_contains 'a token in the environment is not asked for' 'admin API key or session JWT' "$out"
printf 'a\nb\nc\n' > "$tmp/tty"
OSR_UPGRADE_TTY=$tmp/tty run_tool '' --yes --only hermes
assert_contains 'a --yes run asks before its plan' 'admin API key or session JWT' "$(sed -n '1,/==== Plan ====/p' <<< "$out")"
assert_eq 'without a token Hermes is not run' not-run "$(summary_line hermes 282)"
assert_eq 'and its upgrade never starts' '' "$(ls "$tmp"/logs/*/hermes@282.log 2>/dev/null)"
rm "$tmp/mock/282.webui-api"
out=$(ask_with 'typed\n')
assert_not_contains 'not asked when nothing needs it' 'admin API key or session JWT' "$out"

describe 'only the agents that register get the token, through their environment'
# reconf_case TARGET: what run_reconfigure hands its provisioner.
reconf_case() {
    # shellcheck disable=SC2317  # replaces env for run_reconfigure
    env() { printf 'ARGS %s\n' "$*"; printf 'GOT %s\n' "$(command env | sed -n 's/^OPENWEBUI_ADMIN_TOKEN=//p')"; }
    # shellcheck disable=SC2034  # read by run_reconfigure
    WEBUI_TOKEN=secret-token
    add_item "$1" 282
    ( run_reconfigure 0 unattended )
    printf 'AFTER %s\n' "$(command env | grep -c '^OPENWEBUI_ADMIN_TOKEN=')"
}
reset_mock
out=$(in_tool reconf_case hermes 2>&1)
assert_contains 'Hermes gets it' 'GOT secret-token' "$out"
assert_eq 'not on its command line' '' "$(grep '^ARGS' <<< "$out" | grep -F secret-token)"
assert_contains 'the export ends with the provisioner' 'AFTER 0' "$out"
out=$(in_tool reconf_case gitea 2>&1)
assert_contains 'Gitea does not get it' $'GOT \nAFTER' "$out"
out=$(in_tool reconf_case hermes 2>&1)
assert_eq 'Hermes gets no pin, channel, port or name, so it keeps what the CT records' '' \
    "$(grep '^ARGS' <<< "$out" | grep -E 'HERMES_(COMMIT|CHANNEL|API_PORT|API_MODEL_NAME)=')"

describe 'the Hermes HTTP checks'
reset_probe
mkdir -p "$tmp/curl"
cat > "$tmp/probe-bin/curl" <<'MOCK'
#!/bin/sh
# Serves $CURL_DIR/<port>_<path> for http://127.0.0.1:<port>/<path>; honours -o and -w.
out='' write='' url='' prev=''
for a do
    case $prev in -o) out=$a ;; -w) write=$a ;; esac
    case $a in http://*) url=$a ;; esac
    prev=$a
done
f=$CURL_DIR/$(printf '%s' "${url#http://127.0.0.1:}" | tr / _)
if [ -n "$write" ]; then if [ -f "$f" ]; then echo 200; else echo 404; fi; exit 0; fi
[ -f "$f" ] || exit 22
if [ -z "$out" ]; then cat "$f"; fi
MOCK
chmod +x "$tmp/probe-bin/curl"
hermes_probe() {
    local probe
    probe=$(tables eval 'printf "%s" "$HERMES_HTTP_PROBE"')
    # Simulate a CT without curl without relying on Windows-executable symlinks.
    [[ ${PROBE_NO_CURL:-} != true ]] || probe=$'command() { return 1; }\n'"$probe"
    CURL_DIR=$tmp/curl OSR_PROBE_ROOT=$probe_root PATH="$tmp/probe-bin:$PATH" sh -c "$probe"
}
assert_eq 'nothing answers: nothing reported' '' "$(hermes_probe)"
echo '{"status": "ok", "platform": "hermes-agent"}' > "$tmp/curl/8642_health"
echo ok > "$tmp/curl/8765_healthz"
echo '{}' > "$tmp/curl/9119_api_status"
out=$(hermes_probe)
assert_contains 'the gateway health' 'http:hermes-gateway' "$out"
assert_contains 'the dispatcher' 'http:hermes-direct' "$out"
assert_contains 'the dashboard' 'http:hermes-dashboard' "$out"
echo '{"status": "starting"}' > "$tmp/curl/8642_health"
assert_not_contains 'a gateway that is not ok' 'http:hermes-gateway' "$(hermes_probe)"
echo '{"status":"ok"}' > "$tmp/curl/8650_health"
printf 'API_SERVER_KEY=x\nAPI_SERVER_PORT="8650"\n' > "$probe_root/home/hermes/.hermes/.env"
assert_contains 'the port from the agent .env' 'http:hermes-gateway' "$(hermes_probe)"
rm -- "$tmp/curl/8650_health"
assert_not_contains 'and only that port' 'http:hermes-gateway' "$(hermes_probe)"
rc=0; out=$(PROBE_NO_CURL=true hermes_probe) || rc=$?
assert_eq 'no curl in the CT: no HTTP checks' '' "$out"
assert_eq 'and no failure' 0 "$rc"
reset_mock
conf 282 'ai;ai-tools;osr-target;hermes'; state 282 hermes-gateway
printf 'http:hermes-gateway\nhttp:hermes-dashboard\n' > "$tmp/mock/282.http"
collect_state_case() { add_item hermes 282; collect_state 0; }
out=$(in_tool collect_state_case 2>/dev/null)
assert_contains 'collected for Hermes' 'http:hermes-gateway' "$out"
assert_contains 'with the dashboard' 'http:hermes-dashboard' "$out"
conf 251 'ai;ai-model;osr-target;strata'
printf 'http:hermes-gateway\n' > "$tmp/mock/251.http"
collect_strata() { add_item strata 251; collect_state 0; }
assert_not_contains 'not for other targets' 'http:hermes' "$(in_tool collect_strata 2>/dev/null)"
assert_contains 'a lost check is named' 'API server /health' "$(printf 'http:hermes-gateway\n' | tables describe_missing)"

describe 'Hermes itself'
# hermes_case UPDATE OUTPUT: process Hermes 282 whose reconfigure prints OUTPUT;
# prints RESULT|NOTE.
hermes_case() {
    # shellcheck disable=SC2034  # read by prepare and process_item
    SNAPSHOTS=false KEEP_SNAPSHOTS=false NOTIFY=false ON_FAILURE=skip HEALTH_TIMEOUT=0 POLL_INTERVAL=0 \
        INCLUDE_STOPPED=false UPDATE_HERMES=$1
    # shellcheck disable=SC2317  # called by run_item
    run_reconfigure() {
        printf '%s\n' "$item_output"
        [[ ! -e $MOCK/282.hermes-pin-after ]] || cp "$MOCK/282.hermes-pin-after" "$MOCK/282.hermes-pin"
    }
    item_output=$2
    add_item hermes 282
    prepare 2>/dev/null
    process_item 0 2>/dev/null
    echo "${I_RESULT[0]}|${I_NOTE[0]}"
}
hermes_reset() {
    reset_mock
    rm -rf -- "${tmp:?}/run"
    conf 282 'ai;ai-tools;osr-target;hermes'; state 282 hermes-gateway
    printf '%040d\n' 0 | tr 0 a > "$tmp/mock/282.hermes-commit"
}
hermes_reset
out=$(in_tool hermes_case false 'Hermes reconfigured')
assert_eq 'without --update-hermes: the integration is upgraded' \
    'upgraded|integration upgraded; Hermes itself stays at its installed version (--update-hermes updates it)' "$out"
assert_eq 'and hermes update is not run' '' "$(grep RUNUSER "$tmp/mock/installs.log" 2>/dev/null)"
hermes_reset
assert_eq 'a no-op is current, and says Hermes stayed' 'current|Hermes itself stays at its installed version (--update-hermes updates it)' \
    "$(in_tool hermes_case false 'settings unchanged; nothing to do')"
hermes_reset
printf '%040d\n' 0 | tr 0 b > "$tmp/mock/282.hermes-next"
out=$(in_tool hermes_case true 'settings unchanged; nothing to do')
assert_eq '--update-hermes: a moved checkout is an upgrade' \
    "upgraded|Hermes updated: aaaaaaaaaaaa to bbbbbbbbbbbb" "$out"
assert_file_contains 'runs hermes update as the hermes user' \
    'RUNUSER 282 runuser -u hermes -- env HOME=/home/hermes /home/hermes/.local/bin/hermes update' "$tmp/mock/installs.log"
assert_file_contains 'restarts the gateway and dashboard' \
    'SYSTEMCTL 282 systemctl try-restart hermes-gateway.service hermes-dashboard.service' "$tmp/mock/installs.log"
hermes_reset
assert_eq 'nothing newer: still current' 'current|hermes update found nothing newer (aaaaaaaaaaaa)' \
    "$(in_tool hermes_case true 'settings unchanged; nothing to do')"
hermes_reset
assert_eq 'nothing newer after a reconfigure' 'upgraded|integration upgraded; hermes update found nothing newer (aaaaaaaaaaaa)' \
    "$(in_tool hermes_case true 'Hermes reconfigured')"
hermes_reset
printf '%040d\n' 3 > "$tmp/mock/282.hermes-pin"  # what sed prints from the settings
out=$(in_tool hermes_case true 'settings unchanged; nothing to do')
assert_eq 'a HERMES_COMMIT pin is kept' 'current|Hermes stays at its HERMES_COMMIT pin 000000000000' "$out"
assert_eq 'and hermes update is not run under a pin' '' "$(grep RUNUSER "$tmp/mock/installs.log" 2>/dev/null)"
hermes_reset
printf '%040d\n' 3 > "$tmp/mock/282.hermes-pin-after"
out=$(in_tool hermes_case true 'Hermes reconfigured')
assert_eq 'a pin recorded during reconfigure also prevents the update' \
    'upgraded|integration upgraded; Hermes stays at its HERMES_COMMIT pin 000000000000' "$out"
assert_eq 'and does not run hermes update' '' "$(grep RUNUSER "$tmp/mock/installs.log" 2>/dev/null)"
hermes_reset
touch "$tmp/mock/282.hermes-pin-read-fails"
out=$(in_tool hermes_case true 'Hermes reconfigured')
assert_contains 'an unreadable pin stops the update' 'skipped|upgrade failed (exit 1)' "$out"
assert_eq 'before running hermes update' '' "$(grep RUNUSER "$tmp/mock/installs.log" 2>/dev/null)"
hermes_reset
rm "$tmp/mock/282.hermes-commit"
out=$(in_tool hermes_case true 'Hermes reconfigured')
assert_contains 'an unreadable installed commit stops the update' 'skipped|upgrade failed (exit 1)' "$out"
assert_eq 'before running it' '' "$(grep RUNUSER "$tmp/mock/installs.log" 2>/dev/null)"
hermes_reset
touch "$tmp/mock/282.hermes-update-fails"
out=$(in_tool hermes_case true 'Hermes reconfigured')
assert_contains 'a failed hermes update fails the item' 'skipped|upgrade failed (exit 1) and may have changed the CT' "$out"
assert_contains 'and says no snapshot was taken' 'no snapshot was taken' "$out"
assert_eq 'no restart after a failed update' '' "$(grep SYSTEMCTL "$tmp/mock/installs.log" 2>/dev/null)"
hermes_reset
run_tool '' --dry-run --only hermes
assert_contains 'the plan says Hermes stays' 'Hermes itself stays at its installed version' "$out"
run_tool '' --dry-run --only hermes --update-hermes
assert_contains 'the plan with --update-hermes' 'then hermes update and a restart' "$out"
printf '%040d\n' 3 > "$tmp/mock/282.hermes-pin"  # what sed prints from the settings
run_tool '' --dry-run --only hermes --update-hermes
assert_contains 'the plan under a pin' '--update-hermes does not move a pin' "$out"
assert_eq 'a dry run updates nothing' '' "$(grep RUNUSER "$tmp/mock/installs.log" 2>/dev/null)"

describe 'a provisioner that fails keeps its snapshot and defaults to rolling back'
# fail_case TARGET ID POLICY: an upgrade that exits 1 with every check passing.
fail_case() {
    # shellcheck disable=SC2034  # read by process_item
    SNAPSHOTS=true REQUIRE_SNAPSHOT=false KEEP_SNAPSHOTS=false NOTIFY=false ON_FAILURE=$3 HEALTH_TIMEOUT=0 POLL_INTERVAL=0
    # shellcheck disable=SC2317  # called by process_item
    run_item() { echo 'Hermes is reconfigured, but its firewall sync failed'; return 1; }
    add_item "$1" "$2"
    process_item 0 2>/dev/null
    echo "${I_RESULT[0]}|${I_NOTE[0]}"
}
hermes_reset
out=$(in_tool fail_case hermes 282 rollback)
assert_contains 'Hermes: rolled back' 'rolled-back|' "$out"
assert_file_contains 'to its snapshot' 'rollback 282 osr-upg-' "$tmp/mock/pct.log"
hermes_reset
out=$(in_tool fail_case strata 251 rollback)
assert_contains 'an installer that restores itself is skipped' 'skipped|upgrade failed (exit 1); its own rollback' "$out"
assert_contains 'with its snapshot kept' 'pct rollback 251 osr-upg-' "$out"
assert_eq 'not rolled back' '' "$(grep 'rollback 251' "$tmp/mock/pct.log" | grep -v delsnapshot)"
assert_eq 'nor deleted' '' "$(grep 'delsnapshot 251' "$tmp/mock/pct.log")"
hermes_reset
out=$(in_tool fail_case hermes 282 skip)
assert_contains '--on-failure skip keeps the snapshot' 'snapshot osr-upg-' "$out"
assert_contains 'and says it may have changed the CT' 'may have changed the CT' "$out"

describe 'Gitea and Mattermost keep their release'
reset_mock
conf 275 'ai;ai-tools;osr-target;gitea'; state 275 gitea
run_tool '' --dry-run --only gitea
assert_contains 'the plan says so' 'does not pin the gitea release' "$out"
item_case() {  # item_case TARGET ID OUTPUT: run one item whose upgrade prints OUTPUT
    # shellcheck disable=SC2034  # read by process_item
    SNAPSHOTS=false KEEP_SNAPSHOTS=false NOTIFY=false ON_FAILURE=skip HEALTH_TIMEOUT=0 POLL_INTERVAL=0
    # shellcheck disable=SC2317  # called by process_item
    run_item() { printf '%s\n' "$item_output"; }
    item_output=$3
    add_item "$1" "$2"
    [[ ! -f $RUN_DIR/seed.log ]] || cp "$RUN_DIR/seed.log" "$RUN_DIR/$1@$2.log"
    process_item 0 2>/dev/null
    echo "${I_RESULT[0]}"
}
rm -rf "$tmp/run"
assert_eq 'reported as re-applied' reapplied "$(in_tool item_case gitea 275 'Gitea setup done')"

describe 'only the last attempt says whether anything changed'
reset_mock
rm -rf "$tmp/run"; mkdir -p "$tmp/run"
echo 'earlier attempt: same commit: nothing to do' > "$tmp/run/seed.log"
assert_eq 'an upgrade after an earlier no-op' upgraded "$(in_tool item_case strata 251 'upgraded to the new commit')"
assert_eq 'a no-op' current "$(in_tool item_case strata 251 'Strata is up to date and healthy; nothing to do.')"
rm -rf "$tmp/run"

describe 'CTs on other cluster nodes'
reset_mock
conf 280 'ai;ai-tools;osr-router;openwebui'; state 280 ollama-router
conf 351 'ai;ai-model;osr-target;strata' pve2; state 351 strata
conf 361 'ai;ai-model;osr-target;maya' pve3; state 361 maya
run_tool '' --list
assert_contains 'lists a CT on another node with its node' $'strata\t351\tpve2' "$out"
assert_contains 'and one on this node' $'ollama\t252\tpve1' "$out"
run_tool '' --dry-run --skip router,open-webui
plan=$(sed -n '/==== Plan ====/,$p' <<< "$out")
assert_contains 'the plan shows the node' 'pve2' "$(grep '^strata  *351' <<< "$plan")"
assert_contains 'an offline node is reported' 'not-run: node pve3 is offline in the cluster' "$(grep '^maya' <<< "$plan")"
assert_eq 'without trying to reach it' '' "$(grep '^pve3 ' "$tmp/mock/ssh.log" 2>/dev/null)"
run_tool '' --yes --only strata
assert_eq 'a CT on another node is upgraded' upgraded "$(summary_line strata 351)"
assert_file_contains 'through SSH to its node, at its cluster address' 'pve2 root@10.0.0.2' "$tmp/mock/ssh.log"
assert_file_contains 'snapshotted there' 'pve2 snapshot 351 osr-upg-' "$tmp/mock/pct.log"
assert_file_contains 'upgraded there' 'pve2 exec 351 -- env bash /root/strata-target-deploy/install-target.sh --upgrade' "$tmp/mock/pct.log"
assert_eq 'with the files from this clone' "$(cat "$ROOT/targets/strata/install-target.sh")" "$(cat "$tmp/mock/pushed-351-install-target.sh" 2>/dev/null)"
assert_eq 'leaving no copies on that node' '' "$(ls -A "$tmp/remote-tmp")"
assert_contains 'the summary names the node' 'pve2' "$(grep '^strata' "$tmp"/logs/*/summary.txt)"
echo break > "$tmp/mock/351.upgrade"
run_tool '' --yes --only strata
assert_eq 'a broken upgrade there is rolled back there' rolled-back "$(summary_line strata 351)"
assert_file_contains 'by that node' 'pve2 rollback 351 osr-upg-' "$tmp/mock/pct.log"
rm "$tmp/mock/351.upgrade"
touch "$tmp/mock/down-pve2"
rm -f "$tmp/mock/pct.log"
run_tool '' --yes --only strata
assert_eq 'an unreachable node is not run' not-run "$(summary_line strata 351)"
assert_contains 'saying how to check it' 'node pve2 does not answer as root over SSH' "$(grep '^strata' "$tmp"/logs/*/summary.txt)"
assert_eq 'and the run does not count it as upgraded' 0 "$(grep -c 'pve2 exec 351 -- env' "$tmp/mock/pct.log")"
rm "$tmp/mock/down-pve2"

describe '--node limits the run to some nodes'
run_tool '' --list --node pve2
assert_contains 'keeps that node' $'strata\t351\tpve2' "$out"
assert_not_contains 'drops the others' $'ollama\t252' "$out"
assert_not_contains 'including the router' $'router\t280' "$out"
run_tool '' --dry-run --node pve2
assert_not_contains 'still uses the one router for checks' 'No router CT' "$out"

describe 'several OSR installations in one cluster'
conf 380 'ai;ai-tools;osr-router;openwebui' pve2; state 380 ollama-router
run_tool '' --list
assert_eq 'two routers need a choice' 1 "$rc"
assert_contains 'naming both with their nodes' '280 on pve1, 380 on pve2' "$out"
run_tool '' --list --node pve2
assert_contains '--node picks the one on that node' $'router\t380\tpve2' "$out"
ROUTER_CT_ID=280 run_tool '' --list
assert_contains 'ROUTER_CT_ID picks one' $'router\t280\tpve1' "$out"
rm "$tmp/nodes/pve2/lxc/380.conf"

describe 'what a CT needs on another node'
reset_mock
conf 280 'ai;ai-tools;osr-router;openwebui' pve2; state 280 ollama-router
conf 282 'ai;ai-tools;osr-target;hermes'; state 282 hermes-gateway
conf 290 'ai;ai-tools;osr-target;mqtt' pve2; state 290 mosquitto
printf 'target=hermes\nnative=false\n' > "$tmp/mock/282.hcom"
touch "$tmp/mock/down-pve2"
run_tool '' --dry-run --skip router,open-webui,mqtt
assert_contains 'an agent whose router is unreachable is not run' \
    'not-run: needs the router CT 280: node pve2 does not answer' "$(grep '^hermes' <<< "$out")"
assert_contains 'hcom whose broker is unreachable is not run' \
    'not-run: needs the broker CT 290: node pve2 does not answer' "$(grep '^hcom' <<< "$out")"
assert_contains 'and router checks are off' 'The router CT 280: node pve2 does not answer' "$out"
rm "$tmp/mock/down-pve2"

describe 'a node without SSH can be repaired from the run'
reset_mock
conf 351 'ai;ai-model;osr-target;strata' pve2; state 351 strata
# The SSH tool's stand-in: records its arguments and repairs pve2.
cat > "$tmp/cluster-ssh-tool" <<'EOF'
printf '%s\n' "$*" >> "$MOCK/ssh-tool.log"
rm -f "$MOCK/down-pve2"
EOF
touch "$tmp/mock/down-pve2"
OSR_CLUSTER_SSH_TOOL=$tmp/cluster-ssh-tool run_tool 'y\nn\n' --only strata
assert_contains 'names the node before the plan' 'do not answer as root over SSH: pve2' "$(sed -n '1,/==== Plan ====/p' <<< "$out")"
assert_eq 'runs the SSH tool for that node only' '--node pve2' "$(cat "$tmp/mock/ssh-tool.log" 2>/dev/null)"
assert_contains 'then plans its CTs' 'install-target.sh --upgrade' "$(grep '^strata  *351' <<< "$out")"
touch "$tmp/mock/down-pve2"; rm -f "$tmp/mock/ssh-tool.log"
OSR_CLUSTER_SSH_TOOL=$tmp/cluster-ssh-tool run_tool 'n\nn\n' --only strata
assert_eq 'declined: the tool is not run' '' "$(cat "$tmp/mock/ssh-tool.log" 2>/dev/null)"
assert_contains 'and its CTs are not run' 'not-run: node pve2 does not answer' "$(grep '^strata  *351' <<< "$out")"
OSR_CLUSTER_SSH_TOOL=$tmp/cluster-ssh-tool run_tool '' --yes --only strata
assert_contains 'unattended: says what to run' 'Check and repair with: bash '"$tmp"'/cluster-ssh-tool --node pve2' "$out"
assert_eq 'without running it' '' "$(cat "$tmp/mock/ssh-tool.log" 2>/dev/null)"
rm -f "$tmp/mock/down-pve2"
rm -f "$tmp/mock/ssh-tool.log"
OSR_CLUSTER_SSH_TOOL=$tmp/cluster-ssh-tool run_tool 'n\n' --only strata
assert_not_contains 'nothing to offer when every node answers' 'do not answer as root over SSH' "$out"

describe 'one run at a time in the cluster'
reset_mock
printf 'node=pve2 pid=4242 started=2026-11-07T12:00:00-08:00\n' > "$tmp/cluster.lock"
run_tool '' --yes --only strata
assert_eq 'refuses while another node holds the lock' 1 "$rc"
assert_contains 'naming the holder' 'node=pve2 pid=4242' "$out"
assert_eq 'and leaves its lock alone' 'node=pve2 pid=4242 started=2026-11-07T12:00:00-08:00' "$(cat "$tmp/cluster.lock")"
run_tool '' --dry-run
assert_eq 'a dry run does not need it' 0 "$rc"
( exit 0 ) & dead_pid=$!; wait "$dead_pid"
printf 'node=pve1 pid=%s started=then\n' "$dead_pid" > "$tmp/cluster.lock"
run_tool '' --yes --only strata
assert_contains 'takes over a lock left by a finished run on this node' 'Taking over the cluster lock' "$out"
assert_eq 'and upgrades' upgraded "$(summary_line strata 251)"
assert_eq 'releasing the lock afterwards' '' "$(cat "$tmp/cluster.lock" 2>/dev/null)"

describe 'provisioners see the whole cluster'
reset_mock
conf 280 'ai;ai-tools;osr-router;openwebui' pve2; state 280 ollama-router
printf 'net0: name=eth0,bridge=vmbr0,ip=10.0.2.80/24,gw=10.0.2.1\n' >> "$tmp/nodes/pve2/lxc/280.conf"
cluster_case() {
    printf 'LXC %s\n' "$(cd "$PVE_LXC_DIR" && ls | tr '\n' ' ')"
    printf 'PCT %s\n' "$(bash -c 'command -v pct')"
    pct status 280 >/dev/null && printf 'STATUS ok\n'
    # The shared helpers every provisioner sources look tags and addresses up
    # there; a provisioner is a separate process, so they run in one here.
    # shellcheck disable=SC2016  # expanded by the child
    bash -c 'source "$1"; printf "ROUTER %s\nNET %s\n" "$(pve_tagged_ct osr-router)" "$(pve_ct_net 280 ip)"' \
        _ "$ROOT/targets/pve-select.sh"
}
rm -rf "$tmp/run"
out=$(in_tool cluster_case 2>&1)
assert_contains 'PVE_LXC_DIR holds every node'"'"'s CTs' 'LXC 251.conf 252.conf 280.conf' "$out"
assert_contains 'children run the wrapper as pct' "PCT $tmp/run/bin/pct" "$out"
assert_contains 'which reaches the other node' 'STATUS ok' "$out"
assert_file_contains 'over SSH' 'pve2 status 280' "$tmp/mock/pct.log"
assert_contains 'pve-select finds a router on another node' 'ROUTER 280' "$out"
assert_contains 'and reads its address' 'NET 10.0.2.80' "$out"
rm -rf "$tmp/run"

describe 'options'
assert_status 'unknown option' 2 env PATH="$tmp/bin:$PATH" bash "$TOOL" --bogus
assert_status 'bad --on-failure' 1 env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" bash "$TOOL" --on-failure maybe
assert_status 'snapshot options conflict' 1 env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" bash "$TOOL" --no-snapshot --require-snapshot
assert_status 'empty --only is refused' 1 env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" bash "$TOOL" --only=
assert_status 'empty --node is refused' 1 env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" bash "$TOOL" --node=
assert_status 'unknown --node is refused' 1 env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" bash "$TOOL" --node=pve9 --list
assert_status 'unknown --only is refused' 1 env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" bash "$TOOL" --only=unknown --list
assert_status 'missing cluster lock directory is refused' 1 env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" OSR_UPGRADE_CLUSTER_LOCK="$tmp/no-lock-dir/lock" bash "$TOOL" --yes --only=ollama
# A lock the cluster filesystem will not take (read-only without quorum):
# nothing can create a file where a directory is, not even root.
reset_mock
mkdir -p "$tmp/lock-unwritable/lock"
rc=0
out=$(env PATH="$tmp/bin:$PATH" "${CLUSTER_ENV[@]}" OSR_UPGRADE_CLUSTER_LOCK="$tmp/lock-unwritable/lock" \
          OSR_UPGRADE_LOG_DIR="$tmp/logs" OSR_UPGRADE_LOCK="$tmp/lock" bash "$TOOL" --yes --only=ollama 2>&1) || rc=$?
assert_eq 'a lock that cannot be created stops the run' 1 "$rc"
assert_contains 'saying the cluster filesystem would not take it' 'Cannot create the cluster lock' "$out"
assert_contains 'and how to check quorum' 'pvecm status' "$out"
assert_not_contains 'not blaming another run' 'Another upgrade-all.sh holds' "$out"

summary
