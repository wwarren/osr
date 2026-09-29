#!/usr/bin/env bash
# Run on the PVE host to create a NEW Ollama inference target. Never on the router CT/VM.
# The CT and the initial Ollama install come from the Proxmox VE community
# script (ct/ollama.sh); this wrapper presets its settings, then copies this
# target's files in and, with --install-target, adopts the install.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
readonly COMMUNITY_SCRIPT_DEFAULT_URL=https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/ollama.sh
usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--install-target] [--dry-run]

Runs the community script
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/ollama.sh)"
with this target's settings preset as its var_* variables, then copies the
deployment files to /root/ollama-target-deploy in the new CT. With
--install-target (or INSTALL_TARGET=1) it also runs install-target.sh there,
which moves the service to an unprivileged user, a hardening drop-in,
/etc/ollama-target/ollama.env and /var/lib/ollama-target/models, and pulls
OLLAMA_PULL_MODELS.

The community script still shows its own menu; pick "Default" (or "My
Defaults") to accept the presets below. Its settings you do not preset keep
the community defaults (Ubuntu 24.04, unprivileged, nesting).

Settings (environment; all optional):
  CT_ID=<next free>  CT_HOSTNAME=ollama  CORES=4  MEMORY_MB=16384  ROOTFS_GB=128
  STORAGE=<rootdir storage>  BRIDGE=vmbr0  IP_CIDR=<a.b.c.d/nn|dhcp>  GATEWAY=<a.b.c.d>
  NAMESERVER=<a.b.c.d>  VLAN_TAG=<1-4094>  SSH_PUBLIC_KEY=<file>
  GPU=auto|yes|no     auto passes the GPU through when /dev/nvidia0 exists
  OLLAMA_PULL_MODELS='qwen3:8b qwen3:14b'
  COMMUNITY_SCRIPT_URL=<url>      default: the ProxmoxVE main-branch ct/ollama.sh
  COMMUNITY_SCRIPT_SHA256=<hex>   refuse to run a script with any other checksum
When the CT sees the GPU but nvidia-smi is missing inside it, the repository's
NVIDIA 580.173.02 user-space helper is run before install-target.sh.
--dry-run validates inputs and prints the commands without running anything.
USAGE
}

# Container configuration helpers (read-only).
positive_int() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
ipv4() {
    local value=$1 octet
    local -a octets
    [[ $value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    done
}
valid_container_id() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && (( $1 >= 100 )); }
valid_container_ip() {
    local address prefix
    [[ $1 != dhcp ]] || return 0
    [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    address=${BASH_REMATCH[1]}
    prefix=${BASH_REMATCH[2]}
    ipv4 "$address" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( prefix <= 32 ))
}
valid_models() { [[ -z $1 || $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*([[:space:]]+[A-Za-z0-9][A-Za-z0-9._:/-]*)*$ ]]; }
# The community script's var_* presets for these settings, one NAME=value per line.
community_vars() {
    printf '%s\n' "var_ctid=$CT_ID" "var_hostname=$CT_HOSTNAME" "var_cpu=$CORES" "var_ram=$MEMORY_MB" \
        "var_disk=$ROOTFS_GB" "var_unprivileged=1" "var_nesting=1" "var_gpu=$gpu" "var_brg=$BRIDGE"
    [[ -z $IP_CIDR ]] || printf '%s\n' "var_net=$IP_CIDR"
    [[ -z $GATEWAY || $IP_CIDR == dhcp ]] || printf '%s\n' "var_gateway=$GATEWAY"
    [[ -z $NAMESERVER ]] || printf '%s\n' "var_ns=$NAMESERVER"
    [[ -z $VLAN_TAG ]] || printf '%s\n' "var_vlan=$VLAN_TAG"
    [[ -z $STORAGE ]] || printf '%s\n' "var_container_storage=$STORAGE"
    if [[ -n $SSH_PUBLIC_KEY ]]; then
        # The community script takes the key itself, not a path.
        printf '%s\n' "var_ssh=yes" "var_ssh_authorized_key=$(head -n1 -- "$SSH_PUBLIC_KEY" 2>/dev/null || printf '%s' "$SSH_PUBLIC_KEY")"
    fi
    return 0
}
# End container configuration helpers.

dry_run=0
INSTALL_TARGET=${INSTALL_TARGET:-0}
while (( $# )); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --install-target) INSTALL_TARGET=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
[[ $INSTALL_TARGET == 0 || $INSTALL_TARGET == 1 ]] || die 'INSTALL_TARGET must be 0 or 1.'

CT_ID=${CT_ID:-}
CT_HOSTNAME=${CT_HOSTNAME:-ollama}
CORES=${CORES:-4}
MEMORY_MB=${MEMORY_MB:-16384}
ROOTFS_GB=${ROOTFS_GB:-128}
STORAGE=${STORAGE:-}
BRIDGE=${BRIDGE:-vmbr0}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
GPU=${GPU:-auto}
OLLAMA_PULL_MODELS=${OLLAMA_PULL_MODELS:-}
COMMUNITY_SCRIPT_URL=${COMMUNITY_SCRIPT_URL:-$COMMUNITY_SCRIPT_DEFAULT_URL}
COMMUNITY_SCRIPT_SHA256=${COMMUNITY_SCRIPT_SHA256:-}

if [[ -z $CT_ID ]]; then
    (( dry_run )) || CT_ID=$(pvesh get /cluster/nextid 2>/dev/null || true)
    [[ -n $CT_ID ]] || die 'Set CT_ID (the next free ID could not be read from the cluster).'
fi
valid_container_id "$CT_ID" || die 'CT_ID must be a numeric ID of 100 or more.'
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
for name in CORES MEMORY_MB ROOTFS_GB; do positive_int "$name" "${!name}"; done
(( MEMORY_MB >= 4096 )) || die 'MEMORY_MB must be at least 4096; even small models need several GB.'
(( ROOTFS_GB >= 32 )) || die 'ROOTFS_GB must be at least 32; models are several GB each.'
[[ -z $STORAGE || $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ -z $IP_CIDR ]] || valid_container_ip "$IP_CIDR" || die 'IP_CIDR must be a.b.c.d/nn or dhcp.'
[[ -z $GATEWAY ]] || ipv4 "$GATEWAY" || die 'GATEWAY must be an IPv4 address.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY || $dry_run == 1 ]] || die "SSH_PUBLIC_KEY is not readable: $SSH_PUBLIC_KEY"
valid_models "$OLLAMA_PULL_MODELS" || die 'OLLAMA_PULL_MODELS is a space-separated list of name[:tag] entries.'
[[ $COMMUNITY_SCRIPT_URL =~ ^https://[A-Za-z0-9./_-]+\.sh$ ]] || die 'COMMUNITY_SCRIPT_URL must be an https URL of a .sh file.'
[[ -z $COMMUNITY_SCRIPT_SHA256 || $COMMUNITY_SCRIPT_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || die 'COMMUNITY_SCRIPT_SHA256 must be 64 hex digits.'
case "$GPU" in
    auto) if [[ -e ${NVIDIA_DEVICE:-/dev/nvidia0} ]]; then gpu=yes; else gpu=no; fi ;;
    yes|no) gpu=$GPU ;;
    *) die 'GPU must be auto, yes or no.' ;;
esac

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
files=(install-target.sh ollama.env.example ollama-target.conf README.md)
for file in "${files[@]}"; do [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"; done
nvidia_installer=''
for candidate in "$source_dir/../../tools/install_nvidia_580_173_02.sh" "$source_dir/../../install_nvidia_580_173_02.sh"; do
    if [[ -r $candidate ]]; then nvidia_installer=$candidate; break; fi
done
[[ $gpu == no || -n $nvidia_installer ]] || die 'GPU passthrough needs install_nvidia_580_173_02.sh in the repository root or tools directory.'

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
mapfile -t presets < <(community_vars)

if (( ! dry_run )); then
    [[ ${EUID} -eq 0 ]] || die 'Run as root on the intended PVE host.'
    for command_name in pveversion pct pvesh curl sha256sum; do command -v "$command_name" >/dev/null || die "Missing command: $command_name"; done
    [[ -d /etc/pve/nodes ]] || die '/etc/pve is unavailable; do not create a CT until the cluster filesystem is ready.'
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "ID $CT_ID is unavailable in this cluster."
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge interface is not present: $BRIDGE"
fi

script=${TMPDIR:-/tmp}/community-ollama.$$.sh
trap 'rm -f -- "$script"' EXIT
run curl -fsSL -o "$script" "$COMMUNITY_SCRIPT_URL"
if (( ! dry_run )); then
    actual=$(sha256sum "$script" | awk '{ print $1 }')
    printf 'Community script %s\n  sha256 %s\n' "$COMMUNITY_SCRIPT_URL" "$actual"
    if [[ -n $COMMUNITY_SCRIPT_SHA256 && $actual != "${COMMUNITY_SCRIPT_SHA256,,}" ]]; then
        die "The community script changed (expected $COMMUNITY_SCRIPT_SHA256). Review it, then update COMMUNITY_SCRIPT_SHA256."
    fi
fi
# The community script is interactive: it needs this terminal, not a pipe.
run env "${presets[@]}" bash "$script"
if (( ! dry_run )); then
    pct status "$CT_ID" >/dev/null 2>&1 || die "The community script did not create CT $CT_ID (did you change the ID in its menu?)."
fi

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2; rm -f -- "$script"' ERR
run pct exec "$CT_ID" -- install -d -m 0700 /root/ollama-target-deploy
for file in "${files[@]}"; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/ollama-target-deploy/$file" --perms 0644
done
if [[ $gpu == yes ]]; then
    run pct push "$CT_ID" "$nvidia_installer" /root/ollama-target-deploy/install_nvidia_580_173_02.sh --perms 0755
fi
if (( INSTALL_TARGET )); then
    if [[ $gpu == yes ]]; then
        if (( dry_run )) || ! pct exec "$CT_ID" -- nvidia-smi -L >/dev/null 2>&1; then
            run pct exec "$CT_ID" -- bash /root/ollama-target-deploy/install_nvidia_580_173_02.sh lxc
        fi
    fi
    run pct exec "$CT_ID" -- env "OLLAMA_PULL_MODELS=$OLLAMA_PULL_MODELS" bash /root/ollama-target-deploy/install-target.sh
else
    printf '\nOllama is installed as the community script left it (running as root).\n'
    printf 'To adopt it into the target layout, inside the CT (pct enter %s) run:\n' "$CT_ID"
    if [[ $gpu == yes ]]; then printf '  bash /root/ollama-target-deploy/install_nvidia_580_173_02.sh lxc   # if nvidia-smi is missing\n'; fi
    printf '  bash /root/ollama-target-deploy/install-target.sh\n'
fi
printf 'Register it with the router: manage-model-servers add http://<CT %s address>:11434\n' "$CT_ID"
