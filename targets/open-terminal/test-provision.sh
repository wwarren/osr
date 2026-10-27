#!/usr/bin/env bash
# Plans only: no Proxmox, router CT, network or root privileges are required.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
common=(CT_ID=281 ROUTER_CT_ID=280 TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1)
passed=0

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Provision helpers/ { capture=1; next }
    /^# End provision helpers\./ { capture=0 }
    capture { print }
' "$provision")
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
check() { "$@" || { printf 'FAIL %s\n' "$*" >&2; exit 1; }; }
check [ "$(classify_router 280)" = 'ct 280' ]
check [ "$(classify_router 192.0.2.80)" = 'ssh 192.0.2.80' ]
check [ "$(classify_router router.lan)" = 'ssh router.lan' ]
check [ "$(classify_router ollama-smart-router)" = 'ssh ollama-smart-router' ]
for bad in 99 0280 192.0.2.999 1.2.3 'host name' 'a;b' '' -router; do
    if classify_router "$bad" >/dev/null; then printf 'FAIL classify_router accepted %q\n' "$bad" >&2; exit 1; fi
done
check [ "$(printf '192.0.2.81 dev eth0 src 192.0.2.80 uid 0\n    cache\n' | route_src)" = 192.0.2.80 ]
check [ "$(printf '192.0.2.81 via 10.0.0.1 dev ens18 src 10.0.0.5 uid 0\n' | route_src)" = 10.0.0.5 ]
check [ -z "$(printf 'RTNETLINK answers: Network is unreachable\n' | route_src)" ]
# remote_command must survive a POSIX shell unchanged, quotes included.
args=(python3 "/root/a b/x.py" --name "Open Terminal LXC" "it's" '$HOME' 'a"b' '')
mapfile -d '' -t round < <(sh -c "printf '%s\\0' $(remote_command "${args[@]}")")
check [ "${#round[@]}" = "${#args[@]}" ]
for i in "${!args[@]}"; do check [ "${round[$i]}" = "${args[$i]}" ]; done
probe_code=$(cat "$here/verify-webui.py")
mapfile -d '' -t round < <(sh -c "printf '%s\\0' $(remote_command python3 -c "$probe_code" 8080)")
check [ "${round[2]}" = "$probe_code" ]
check [ "${round[3]}" = 8080 ]
# pct create needs a normal umask for Proxmox's unprivileged template
# extraction, while the parent still creates credentials with 077.
saved_umask=$(umask)
umask 077
run() { printf '%s %s\n' "$(umask)" "$*"; }
check [ "$(run_pct_create pct create 158)" = '0022 pct create 158' ]
check [ "$(umask)" = 0077 ]
unset -f run
umask "$saved_umask"
passed=$((passed + 1))

# Both selectors use Proxmox discovery, including a storage.cfg fallback when
# pvesm's content filter returns an empty table.
pvesm() {
    case "$*" in
        'status -content vztmpl') cat <<'TABLE'
Name Type Status Total (KiB) Used (KiB) Available (KiB) %
local dir active 100000000 1000000 99000000 1%
zstore dir active 100000000 1000000 99000000 1%
offline dir inactive 100000000 0 100000000 0%
TABLE
            ;;
        'status -content rootdir') cat <<'TABLE'
Name Type Status Total (KiB) Used (KiB) Available (KiB) %
local-lvm lvmthin active 80000000 45000000 35000000 56%
tiny dir active 20000000 11000000 9000000 55%
big zfspool active 100000000 30000000 70000000 30%
offline dir inactive 100000000 0 100000000 0%
TABLE
            ;;
        status) cat <<'TABLE'
Name Type Status Total (KiB) Used (KiB) Available (KiB) %
local dir active 100000000 1000000 99000000 1%
local-lvm lvmthin active 80000000 45000000 35000000 56%
tiny dir active 20000000 11000000 9000000 55%
big zfspool active 100000000 30000000 70000000 30%
TABLE
            ;;
        *) return 1 ;;
    esac
}
pveam() {
    [[ $1 == list ]] || return 1
    case $2 in
      local) cat <<'TABLE'
Volid Format Type Size
local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst tar.zst vztmpl 1000
local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst tar.zst vztmpl 1000
local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst tar.zst vztmpl 1000
TABLE
        ;;
      zstore) cat <<'TABLE'
Volid Format Type Size
zstore:vztmpl/debian-12-standard_12.9-1_amd64.tar.zst tar.zst vztmpl 1000
TABLE
        ;;
      *) return 1 ;;
    esac
}
check [ "$(storage_rows rootdir | wc -l | tr -d ' ')" = 3 ]
check [ "$(downloaded_debian_templates | wc -l | tr -d ' ')" = 3 ]
ROOTFS_GB=16
TEMPLATE=''
select_template <<< '' 2>/dev/null
check [ "$TEMPLATE" = local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst ]
TEMPLATE=''
select_template <<< $'4\n2\n' 2>/dev/null
check [ "$TEMPLATE" = zstore:vztmpl/debian-12-standard_12.9-1_amd64.tar.zst ]
STORAGE=''
select_storage <<< $'2\n\n' 2>/dev/null
check [ "$STORAGE" = big ]
fallback_cfg=$(mktemp)
printf 'dir: local\n  content vztmpl,iso\nlvmthin: local-lvm\n  content rootdir,images\n' > "$fallback_cfg"
STORAGE_CFG=$fallback_cfg
pvesm() {
    if [[ $* == 'status -content '* ]]; then printf 'Name Type Status Available (KiB)\n'; return 0; fi
    [[ $* == status ]] || return 1
    printf 'Name Type Status Available (KiB)\nlocal dir active 50000000\nlocal-lvm lvmthin active 30000000\n'
}
check [ "$(storage_rows rootdir)" = $'local-lvm\tlvmthin\t30000000' ]
check [ "$(storage_rows vztmpl)" = $'local\tdir\t50000000' ]
rm -f -- "$fallback_cfg"
unset STORAGE_CFG
unset -f pvesm pveam
passed=$((passed + 1))

has() { [[ $output == *"$1"* ]] || { printf 'FAIL missing %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
lacks() { [[ $output != *"$1"* ]] || { printf 'FAIL unexpected %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
plan() {
    output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1) || {
        printf 'FAIL plan\n%s\n' "$output" >&2; exit 1;
    }
    passed=$((passed + 1))
}
reject() {
    local reason=$1; shift
    if output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1); then
        printf 'FAIL accepted invalid setting\n%s\n' "$output" >&2; exit 1
    fi
    has "$reason"
    lacks '+ pct create '
    passed=$((passed + 1))
}

plan
has '+ pct create 281 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst'
has '--unprivileged 1'
has 'ip=192.0.2.81/24\,gw=192.0.2.1\,firewall=1'
has 'policy_in: DROP'
has 'IN ACCEPT -source <router-source-ip>/32 -p tcp -dport 8000'
has 'wait for systemd, a default route and DNS'
has '+ pct exec 281 -- install -d -m 0711 /etc/open-terminal'
has '+ pct exec 281 -- install -d -m 0700 /root/open-terminal-deploy'
for file in install-target.sh open-terminal.service requirements.in requirements.lock; do
    has "/root/open-terminal-deploy/$file"
done
has '/etc/open-terminal/api-key --perms 0600'
has 'OPEN_TERMINAL_VERSION=v0.14.0 OPEN_TERMINAL_COMMIT= bash /root/open-terminal-deploy/install-target.sh'
has 'integrate-webui.py --webui-url http://127.0.0.1:\<router-webui-port\> --terminal-url http://192.0.2.81:8000'
has '--id open-terminal-lxc-281'
has '+ verify Open WebUI install, open-webui.service, /health and /api/version on router CT 280:<router-webui-port> before pct create'
[[ $output == *'before pct create'*'+ pct create 281'* ]] || { printf 'FAIL WebUI verification does not precede CT creation\n' >&2; exit 1; }
lacks 'Setup stopped'
# The plan neither prompts for nor stores an admin token.
lacks 'admin API key or JWT:'

plan OPEN_TERMINAL_PORT=8100 ROUTER_IP=192.0.2.80 OPENWEBUI_PORT=3000 VLAN_TAG=20 NAMESERVER=192.0.2.53
has '-source 192.0.2.80/32 -p tcp -dport 8100'
has 'OPEN_TERMINAL_PORT=8100'
has 'http://127.0.0.1:3000 --terminal-url http://192.0.2.81:8100'
has '\,tag=20'
has '--nameserver 192.0.2.53'

plan ROUTER_CT_ID= ROUTER=150
has '+ verify Open WebUI install, open-webui.service, /health and /api/version on router CT 150:'
has '+ pct create 281'

commit=0123456789abcdef0123456789abcdef01234567
plan OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=$commit
has "OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=$commit"

# A router reached over SSH (an LXC/VM on another node, or added later).
output=$(env -i "PATH=$PATH" CT_ID=281 ROUTER=192.0.2.80 TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
    STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1 bash "$provision" --dry-run 2>&1) ||
    { printf 'FAIL ssh router plan\n%s\n' "$output" >&2; exit 1; }
has '+ pct create 281'
has "+ ssh root@192.0.2.80 -- 'mktemp' '-d' '/root/open-terminal-integration.XXXXXX'"
has '+ ssh root@192.0.2.80 -- write <router-stage>/api-key (0600)'
has "+ ssh root@192.0.2.80 -- 'python3' '<router-stage>/integrate-webui.py'"
has 'reachable from router root@192.0.2.80'
lacks 'pct exec 280'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" CT_ID=281 ROUTER=router.lan ROUTER_SSH_PORT=2222 \
    bash "$provision" --dry-run --integrate-only 2>&1) || { printf 'FAIL hostname router\n%s\n' "$output" >&2; exit 1; }
has '+ ssh root@router.lan --'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" CT_ID=281 ROUTER=280 bash "$provision" --dry-run --integrate-only 2>&1) ||
    { printf 'FAIL ROUTER=CT plan\n%s\n' "$output" >&2; exit 1; }
has '+ pct exec 280 -- mktemp'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" CT_ID=281 ROUTER_CT_ID=280 bash "$provision" --dry-run --integrate-only 2>&1) ||
    { printf 'FAIL integrate-only plan\n%s\n' "$output" >&2; exit 1; }
has '+ pct pull 281 /etc/open-terminal/api-key'
lacks '+ pct create'
has '--terminal-url http://\<terminal-eth0-ip\>:8000'
passed=$((passed + 1))

reject 'CT_ID' CT_ID=99
reject 'Set CT_ID for an unattended run' CT_ID=
reject 'Set CT_ID for an unattended run' ROUTER_CT_ID= ROUTER=192.0.2.80 CT_ID=
reject 'must differ' ROUTER_CT_ID=281
reject 'must differ' ROUTER_CT_ID= ROUTER=281
reject 'neither a CT ID' ROUTER_CT_ID= ROUTER=99
reject 'neither a CT ID' ROUTER_CT_ID= ROUTER='a;b'
reject 'Set only one' ROUTER_SSH_HOST=192.0.2.80
reject 'Set only one' ROUTER=280
reject 'Set ROUTER to the router CT ID' ROUTER_CT_ID=
reject 'ROUTER_SSH_PORT' ROUTER_CT_ID= ROUTER=192.0.2.80 ROUTER_SSH_PORT=0
reject 'ROUTER_SSH_USER' ROUTER_CT_ID= ROUTER=192.0.2.80 ROUTER_SSH_USER='Bad User'
reject 'ROUTER_SSH_USER must be root' ROUTER_CT_ID= ROUTER=192.0.2.80 ROUTER_SSH_USER=admin
reject 'TEMPLATE' TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
reject 'Set TEMPLATE for an unattended run' TEMPLATE=
reject 'Set STORAGE for an unattended run' STORAGE=
reject 'Set IP_CIDR for an unattended run' IP_CIDR=
reject 'Set GATEWAY for an unattended run' GATEWAY=
reject 'IP_CIDR' IP_CIDR=dhcp
reject 'GATEWAY' GATEWAY=
reject 'OPEN_TERMINAL_PORT' OPEN_TERMINAL_PORT=70000
reject 'Set OPEN_TERMINAL_COMMIT' OPEN_TERMINAL_VERSION=v0.15.0
reject 'OPEN_TERMINAL_COMMIT must be' OPEN_TERMINAL_COMMIT=abc
reject 'CONNECTION_NAME' CONNECTION_NAME="$(printf 'x%.0s' {1..65})"
reject 'ROUTER_IP' ROUTER_IP=10.0.0.999

bash -n "$provision"
bash -n "$here/install-target.sh"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$here/integrate-webui.py"
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$here/verify-webui.py"
printf '%s Open Terminal dry-run cases and syntax checks passed. No CT was created.\n' "$passed"
