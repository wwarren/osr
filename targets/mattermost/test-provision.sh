#!/usr/bin/env bash
# targets/mattermost/provision-lxc.sh without Proxmox: dry-run plans and validation,
# then (as root, against stubbed pct/pvesh/curl) the checksum pin, the
# readiness wait and the printed webhook steps. Nothing is fetched or created.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=$here/provision-lxc.sh
bash_bin=$(command -v bash)
common=(CT_ID=275 IP_CIDR=192.0.2.75/24 GATEWAY=192.0.2.1 STORAGE=local-lvm)
passed=0
out=''
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n%s\n' "$1" "$out" >&2; exit 1; }
has() { [[ $out == *"$1"* ]] || fail "output lacks: $1"; }
lacks() { [[ $out != *"$1"* ]] || fail "output contains: $1"; }
# plan [--flag ...] [VAR=value ...]: a dry run with those flags and settings.
plan() {
    local -a flags=() vars=()
    local arg
    for arg in "$@"; do if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi; done
    out=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" "$bash_bin" "$tool" --dry-run "${flags[@]}" 2>&1) ||
        fail "plan failed: $*"
}
refuse() {
    local expect=$1; shift
    local -a flags=() vars=()
    local arg
    for arg in "$@"; do if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi; done
    if out=$(env -i "PATH=$PATH" "${common[@]}" "${vars[@]}" "$bash_bin" "$tool" --dry-run "${flags[@]}" 2>&1); then
        fail "accepted: $*"
    fi
    has "$expect"
    lacks '+ env var_'
}

plan --create-only
has '+ curl -fsSL -o '
has 'https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/mattermost.sh'
has '+ env var_ctid=275 var_hostname=mattermost var_cpu=2 var_ram=4096 var_disk=16 var_unprivileged=1 var_nesting=1 var_gpu=no var_brg=vmbr0 var_net=192.0.2.75/24 var_gateway=192.0.2.1 var_container_storage=local-lvm bash '
has 'api/v4/system/ping'
has 'manage-model-servers set-webhook <webhook URL>'
has 'Create the channel "ollama-monitor"'
has 'whoever creates it'
lacks 'var_pw'
pass '--create-only: the community script runs with the presets, then the webhook steps are printed'

plan --create-only IP_CIDR=dhcp MATTERMOST_CHANNEL=alerts NAMESERVER=192.0.2.53 VLAN_TAG=30 BRIDGE=vmbr1
has 'var_net=dhcp'; lacks 'var_gateway'; has 'var_ns=192.0.2.53'; has 'var_vlan=30'; has 'var_brg=vmbr1'
has 'Create the channel "alerts"'
pass 'DHCP drops the gateway; optional network settings and the channel are passed through'

keyfile=$(mktemp); trap 'rm -f -- "$keyfile"' EXIT
echo 'ssh-ed25519 AAAAC3Nz test@host' > "$keyfile"
plan SSH_PUBLIC_KEY="$keyfile"
has 'var_ssh=yes'; has 'var_ssh_authorized_key=ssh-ed25519\ AAAAC3Nz\ test@host'
pass 'an SSH key is passed as its content'

refuse 'MEMORY_MB must be at least' MEMORY_MB=1024
refuse 'ROOTFS_GB must be at least' ROOTFS_GB=4
refuse 'IP_CIDR' IP_CIDR=192.0.2.300/24
refuse 'CT_ID' CT_ID=12
refuse 'MATTERMOST_CHANNEL' MATTERMOST_CHANNEL='Ollama Monitor'
refuse 'COMMUNITY_SCRIPT_URL' COMMUNITY_SCRIPT_URL=http://example/mattermost.sh
refuse 'COMMUNITY_SCRIPT_SHA256' COMMUNITY_SCRIPT_SHA256=abc
refuse 'READY_TIMEOUT' READY_TIMEOUT=0
pass 'invalid settings are refused before the community script is fetched or run'

plan
has '+ env var_ctid=275 var_hostname=mattermost'
has '+ pct push 275 '; has 'install-target.sh /root/mattermost-target-deploy/install-target.sh --perms 0755'
has 'MATTERMOST_CHANNEL=ollama-monitor'
has 'Mattermost is configured in CT 275: http://192.0.2.75:8065'
has 'cat /etc/mattermost-target/webhook-url'; lacks 'Add Incoming Webhook'
pass 'the default run configures Mattermost in the CT and says where the webhook is'

plan --reconfigure MATTERMOST_TEAM=ops
lacks '+ curl -fsSL'; lacks '+ env var_'
has '+ pct exec 275 -- env MATTERMOST_CHANNEL=ollama-monitor MATTERMOST_TEAM=ops'
pass '--reconfigure reruns the guest setup in the existing CT only'

refuse 'needs the existing CT_ID' --reconfigure CT_ID=
refuse 'Use only one of' --create-only --reconfigure
refuse 'MATTERMOST_ADMIN_USER' MATTERMOST_ADMIN_USER=X
refuse 'MATTERMOST_TEAM' MATTERMOST_TEAM='Ops Team'
pass 'the guest settings and modes are checked before anything is created'

"$bash_bin" -n "$tool"
"$bash_bin" -n "$here/install-target.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mattermost-test.XXXXXX")
trap 'rm -rf -- "$tmp" "$keyfile"' EXIT
bin=$tmp/bin; mkdir -p "$bin" "$tmp/pve/nodes" "$tmp/net/vmbr0"
log=$tmp/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
# The "community script" the stubbed curl downloads records the presets it got.
community=$tmp/community.sh
printf '#!/usr/bin/env bash\necho "community var_ctid=$var_ctid var_ram=$var_ram" >> "%s"\n' "$log" > "$community"
good_sha=$(sha256sum "$community" | awk '{ print $1 }')
stub curl 'while (( $# )); do if [[ $1 == -o ]]; then cp "'"$community"'" "$2"; fi; shift; done'
stub pveversion 'exit 0'
# id: root unless FAKE_UID says otherwise, so these runs need no real root.
stub id '[[ $1 == -u ]] && echo "${FAKE_UID:-0}"'
stub pvesh 'exit "${FAKE_ID_UNAVAILABLE:-0}"'
# pct: the CT exists; the ping answers after FAKE_PINGS failures (default 0).
stub pct 'case "$*" in
    status*) [[ ${FAKE_STOPPED:-0} != 0 ]] && echo "status: stopped" || echo "status: running"; exit 0 ;;
    *system/ping*) n=$(cat "'"$tmp"'/pings" 2>/dev/null || echo 0); echo $((n + 1)) > "'"$tmp"'/pings"; (( n >= ${FAKE_PINGS:-0} )) ;;
    *hostname*) echo "192.0.2.75 fd00::75" ;;
    push*) : ;;
    *install-target.sh*) exit "${FAKE_GUEST_RC:-0}" ;;
    *"cat /etc/mattermost-target/url"*) echo "http://192.0.2.75:8065" ;;
    *"cat /etc/mattermost-target/admin-user"*) echo the-admin ;;
    *"cat /etc/mattermost-target/router-user"*) echo the-router ;;
esac'
stub sleep 'exit 0'
real() {
    local -a flags=() vars=()
    local arg
    for arg in "$@"; do if [[ $arg == --* ]]; then flags+=("$arg"); else vars+=("$arg"); fi; done
    env -i "PATH=$bin:$PATH" "${common[@]}" PVE_NODES_DIR="$tmp/pve/nodes" SYS_NET_DIR="$tmp/net" READY_TIMEOUT=30 \
        "${vars[@]}" "$bash_bin" "$tool" "${flags[@]}" 2>&1
}

: > "$log"; rm -f "$tmp/pings"
out=$(real --create-only COMMUNITY_SCRIPT_SHA256="$good_sha" FAKE_PINGS=2) || fail 'a pinned, answering install failed'
has "sha256 $good_sha"
grep -q '^community var_ctid=275 var_ram=4096$' "$log" || fail "the community script did not get the presets: $(cat "$log")"
[[ $(grep -c 'system/ping' "$log") == 3 ]] || fail 'the readiness check did not retry until Mattermost answered'
has 'Mattermost is answering in CT 275.'
has 'http://192.0.2.75:8065'
pass 'a pinned script runs with the presets; the wrapper waits for Mattermost and prints its address'

: > "$log"
if out=$(real COMMUNITY_SCRIPT_SHA256="$(printf '%064d' 0)"); then fail 'a changed community script was run'; fi
has 'The community script changed'
grep -q '^community ' "$log" && fail 'the community script ran despite a checksum mismatch'
pass 'a community script with another checksum is refused before it runs'

: > "$log"; rm -f "$tmp/pings"
if out=$(real FAKE_PINGS=1000 READY_TIMEOUT=1); then fail 'a server that never answered was reported ready'; fi
has 'did not answer on port 8065'
pass 'a server that does not answer is reported, with where to look'

: > "$log"
if out=$(real SYS_NET_DIR="$tmp/no-net"); then fail 'a missing bridge was accepted'; fi
has 'Bridge interface is not present'
grep -q '^community ' "$log" && fail 'the community script ran without its bridge'
pass 'host checks run before the community script'

: > "$log"; rm -f "$tmp/pings"
out=$(real) || fail 'a full run failed'
grep -q '^pct push 275 .*install-target.sh /root/mattermost-target-deploy/install-target.sh --perms 0755$' "$log" || fail "install-target.sh was not pushed: $(cat "$log")"
grep -q 'pct exec 275 -- env MATTERMOST_CHANNEL=ollama-monitor .* bash /root/mattermost-target-deploy/install-target.sh' "$log" || fail 'the guest setup did not run'
has 'Administrator: the-admin'; has 'http://192.0.2.75:8065'
pass 'a full run creates the CT, configures Mattermost in it and reports the webhook location'

: > "$log"
if out=$(real FAKE_GUEST_RC=1); then fail 'a failed guest setup was reported as success'; fi
pass 'a failed guest setup fails the run'

: > "$log"
out=$(real --reconfigure) || fail '--reconfigure failed'
grep -q '^community ' "$log" && fail '--reconfigure ran the community script'
grep -q 'bash /root/mattermost-target-deploy/install-target.sh' "$log" || fail '--reconfigure did not run the guest setup'
pass '--reconfigure runs only the guest setup in the existing CT'

: > "$log"
out=$(real --reconfigure FAKE_ID_UNAVAILABLE=1) || fail '--reconfigure refused the CT for having an ID in use'
grep -q 'bash /root/mattermost-target-deploy/install-target.sh' "$log" || fail '--reconfigure did not run the guest setup'
: > "$log"
if out=$(real --reconfigure FAKE_STOPPED=1); then fail '--reconfigure accepted a stopped CT'; fi
has 'is not a running CT'
grep -qE '^pct (push|exec)' "$log" && fail '--reconfigure touched a stopped CT'
pass '--reconfigure needs the CT running, and does not need its ID free'

: > "$log"
if out=$(real FAKE_UID=1000); then fail 'a run without root was accepted'; fi
has 'Run as root'
grep -qE '^(curl|community|pct) ' "$log" && fail 'a run without root reached Proxmox or the network'
pass 'a run without root is refused before anything is fetched or created'

printf '%s Mattermost installer cases passed. No CT was created.\n' "$passed"
