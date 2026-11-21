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
for target in strata basalt maya xolotl avalon kindi colibri airllm llamacpp ollama comfyui open-terminal; do
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
    if [[ $target == freellmapi ]]; then
        # Its CT is its container image, without systemd: checked over HTTP.
        assert_eq "$target has no units (its image has no systemd)" '' "$(tables eval "printf '%s' \"\${UNITS[$target]:-}\"")"
        continue
    fi
    assert_ne "$target has services to check" '' "$(tables eval "printf '%s' \"\${UNITS[$target]:-}\"")"
done
for unit_file in "$ROOT"/targets/*/*.service "$ROOT"/services/*/*.service; do
    target=$(basename "$(dirname "$unit_file")")
    unit=$(basename "$unit_file" .service)
    case $target in osr-router|litellm-proxy|osr-monitor|open-webui) target=router ;; esac
    [[ $unit != *@ ]] || continue   # a template is never active itself
    # NAME=OLD entries (a unit renamed since) are checked as NAME.
    assert_contains "$unit.service is checked for $target" " $unit " \
      " $(tables eval "printf '%s' \"\${UNITS[$target]:-}\"" | sed -E 's/=[^ ]*//g') "
done

describe 'repository pins are found'
assert_ne 'DeepSeek Harness pin' '' "$(tables repo_default dsh)"
assert_ne 'Honcho pin' '' "$(tables repo_default honcho)"
assert_eq 'OpenCode pin' "$(sed -n 's/^DEFAULT_OPENCODE_VERSION=//p' "$ROOT/targets/opencode/install-target.sh")" "$(tables repo_default opencode)"
assert_ne 'LiteLLM pin (the router row)' '' "$(tables pinned_release router)"
assert_ne 'AirLLM pin' '' "$(tables pinned_release airllm)"
assert_ne 'hcom pin' '' "$(tables pinned_release hcom)"
for target in $(tables eval 'printf "%s\n" "${TARGET_ORDER[@]}"') router open-webui hcom; do
    [[ -n $(tables upstream_spec "$target") || -n $(tables eval "printf '%s' \"\${UPSTREAM_UNPINNED[$target]:-}\"") ||
       $target == hermes ]] && _pass "$target is in the versions table" || _fail "$target is in the versions table" 'an UPSTREAM, UPSTREAM_SHOWN or UPSTREAM_UNPINNED entry' 'none'
done

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
    config) printf 'hostname: ct%s\nnet0: name=eth0,bridge=vmbr0,ip=10.0.0.%s/24,gw=10.0.0.1\n' "$id" "$((id % 250))"
            for conf in "$PVE_NODES_DIR"/*/lxc/"$id".conf; do
                [[ ! -f $conf ]] || sed -n '/^tags:/p' "$conf"
            done
            # <id>.memory: the CT's memory line (Colibri's model menu reads it).
            [[ ! -e $MOCK/$id.memory ]] || printf 'memory: %s\n' "$(cat "$MOCK/$id.memory")" ;;
    set) [[ ${3:-} == --tags ]] || exit 1
         for conf in "$PVE_NODES_DIR"/*/lxc/"$id".conf; do
             [[ -f $conf ]] || continue
             if grep -q '^tags:' "$conf"; then sed -i "s/^tags:.*/tags: $4/" "$conf"
             else printf 'tags: %s\n' "$4" >> "$conf"; fi
             exit 0
         done
         exit 1 ;;
    snapshot) [[ ! -e $MOCK/$id.nosnap ]] || exit 1 ;;
    delsnapshot|stop|start) : ;;
    rollback) cp "$MOCK/$id.state.orig" "$MOCK/$id.state" ;;
    # Like a pct that reads its stdin: a caller that pipes a secret to a later
    # pct exec must keep it away from this one.
    push) cat -- "$3" > "$MOCK/pushed-$id-${4##*/}"; [[ -t 0 ]] || cat > /dev/null ;;
    pull) echo "pulled $3" > "$4" ;;
    exec)
        shift 3
        case $1 in
            sh)
                # The versions table's probe: <id>.installed is what the CT runs.
                if [[ $3 == *osr-installed-version* ]]; then
                    [[ ! -e $MOCK/$id.installed ]] || cat "$MOCK/$id.installed"; exit 0
                fi
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
                # The llama.cpp dashboard probe: <id>.dashboard, else installed and answering.
                if [[ $3 == *llama-dashboard.service* ]]; then
                    if [[ -e $MOCK/$id.dashboard ]]; then cat "$MOCK/$id.dashboard"
                    else printf 'dashboard=present\ndashboard_port=8082\ndashboard_state=active\ndashboard_http=ok\n'; fi
                    exit 0
                fi
                # collect_state's probe: each NAME[=OLD] argument is active when
                # either name is listed in <id>.state, and is reported as NAME.
                if [[ $3 == *systemctl* ]]; then
                    grep -v -e '^ct:' -e '^unit:' "$MOCK/$id.state"
                    for u in "${@:5}"; do
                        for c in ${u//=/ }; do grep -qx "unit:$c" "$MOCK/$id.state" && { echo "unit:${u%%=*}"; break; }; done
                    done
                fi ;;
            hostname) echo "10.0.0.$((id % 250))" ;;
            # setup-metrics.sh login: <id>.grafana is what it prints.
            bash) [[ $* == *'setup-metrics.sh login' && -e $MOCK/$id.grafana ]] || exit 1
                  cat "$MOCK/$id.grafana" ;;
            sed)
                case "$*" in
                    *service.env*) [[ ! -e $MOCK/$id.port ]] || cat "$MOCK/$id.port" ;;
                    # Open Terminal's recorded Open WebUI access (all or keep).
                    *webui-access*) [[ ! -e $MOCK/$id.access ]] || cat "$MOCK/$id.access" ;;
                    *requirements.txt*) [[ ! -e $MOCK/$id.ctpin ]] || cat "$MOCK/$id.ctpin" ;;
                    *DSH_VERSION*) [[ ! -e $MOCK/$id.dsh ]] || cat "$MOCK/$id.dsh" ;;
                    *FREELLMAPI_VERSION*) [[ ! -e $MOCK/$id.freellmapi ]] || cat "$MOCK/$id.freellmapi" ;;
                    *HERMES_COMMIT*) [[ ! -e $MOCK/$id.hermes-pin-read-fails ]] || exit 1
                                     [[ ! -e $MOCK/$id.hermes-pin ]] || cat "$MOCK/$id.hermes-pin" ;;
                esac ;;
            # Hermes's checkout, hermes update (moves it to <id>.hermes-next)
            # and the restart after it.
            git) [[ ! -e $MOCK/$id.hermes-commit ]] || cat "$MOCK/$id.hermes-commit" ;;
            runuser)
                if [[ $* == *' update --help' ]]; then
                    # Only a newer Hermes knows --no-gateway-restart.
                    echo 'usage: hermes update [--check] [--force]'
                    [[ ! -e $MOCK/$id.hermes-no-restart-flag ]] || echo '  --no-gateway-restart  defer the restart'
                    exit 0
                fi
                printf 'RUNUSER %s %s\n' "$id" "$*" >> "$MOCK/installs.log"
                [[ ! -e $MOCK/$id.hermes-update-fails ]] || exit 1
                [[ ! -e $MOCK/$id.hermes-next ]] || cp "$MOCK/$id.hermes-next" "$MOCK/$id.hermes-commit" ;;
            systemctl) printf 'SYSTEMCTL %s %s\n' "$id" "$*" >> "$MOCK/installs.log" ;;
            /app/openwebui/venv/bin/python) [[ ! -e $MOCK/$id.webui ]] || cat "$MOCK/$id.webui" ;;
            # Open Terminal's access in Open WebUI: the admin token arrives on stdin.
            python3)
                if [[ $* == *--access-only* ]]; then
                    IFS= read -r token || token=''
                    printf 'WEBUI_ACCESS %s %s token=%s\n' "$id" "$*" "$token" >> "$MOCK/installs.log"
                    [[ ! -e $MOCK/access-fails ]] || exit 1
                    exit 0
                fi
                echo 'mqtts://broker.lan:8883' ;;
            test) [[ -e $MOCK/$id.tls ]] ;;
            # A Colibri CT's download manifest (<id>.manifest) and free disk.
            cat) [[ -e $MOCK/$id.manifest ]] || exit 1; cat "$MOCK/$id.manifest" ;;
            df) printf 'Filesystem 1B-blocks Used Available Use%% Mounted\nfake 0 0 900000000000 0%% /\n' ;;
            # FreeLLMAPI's /api/ping probe (node in its image): <id>.ping answers.
            node) [[ $3 == *'/api/ping'* && -e $MOCK/$id.ping ]]; exit ;;
            grep) [[ -e $MOCK/$id.webui-api ]] || exit 1 ;;
            /usr/local/bin/manage-model-servers) printf 'MANAGE %s %s\n' "$id" "$*" >> "$MOCK/installs.log" ;;
            install) : ;;
            env)
                printf 'INSTALL %s %s\n' "$id" "$*" >> "$MOCK/installs.log"
                case $(cat "$MOCK/$id.upgrade" 2>/dev/null || echo ok) in
                    # <id>.dashboard-after: what the dashboard probe finds after it.
                    ok) [[ ! -e $MOCK/$id.dashboard-after ]] || cp "$MOCK/$id.dashboard-after" "$MOCK/$id.dashboard"
                        echo 'upgraded' ;;
                    nothing) echo 'same commit: nothing to do' ;;
                    break) sed -i '/^unit:/d' "$MOCK/$id.state"; echo 'upgraded (but broke)' ;;
                    fail) echo 'failed; rolled back'; exit 1 ;;
                    fail-break) sed -i '/^unit:/d' "$MOCK/$id.state"; echo 'failed badly'; exit 1 ;;
                esac ;;
        esac ;;
esac
exit 0
MOCK
# Upstream release lookups: curl serves $MOCK/upstream/<the URL, every
# character but letters and digits as _>; anything else is an HTTP error.
# UPSTREAM_DOWN=1 is a network that cannot be reached. The arguments and the
# headers read from files (@FILE) are logged apart.
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url='' headers=''
for a; do
    case $a in
        https://*) url=$a ;;
        @*) [[ ! -r ${a#@} ]] || headers+=$(cat -- "${a#@}") ;;
    esac
done
printf '%s\n' "$*" >> "$MOCK/curl.log"
printf '%s\n' "$headers" >> "$MOCK/curl-headers.log"
[[ -z ${UPSTREAM_DOWN:-} ]] || exit 7
f=$MOCK/upstream/$(printf '%s' "$url" | tr -c 'A-Za-z0-9' _)
[[ -f $f ]] || exit 22
cat -- "$f"
MOCK
chmod +x "$tmp/bin/"*
upstream() {  # upstream URL BODY: what the (fake) upstream serves at URL
    mkdir -p "$tmp/mock/upstream"
    printf '%s\n' "$2" > "$tmp/mock/upstream/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"
}

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

llama_dashboard() {  # llama_dashboard STATE [http]: what the probe finds after the upgrade
    printf 'dashboard=present\ndashboard_port=8082\ndashboard_state=%s\n%s' "$1" "${2:+dashboard_http=ok$'\n'}" > "$tmp/mock/253.dashboard-after"
}
llama_note() { grep '^llamacpp' "$tmp"/logs/*/summary.txt; }
describe 'retry'
reset_mock
echo fail > "$tmp/mock/252.upgrade"
run_tool 'y\nr\ns\n' --pinned
assert_eq 'runs the upgrade twice' 2 "$(grep -c '^INSTALL 252' "$tmp/mock/installs.log")"

describe 'abort'
reset_mock
echo fail-break > "$tmp/mock/252.upgrade"
run_tool 'y\na\n' --pinned
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

summary
