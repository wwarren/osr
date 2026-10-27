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
the community defaults (unprivileged, nesting).

Settings (environment; all optional):
  CT_ID=<next free>  CT_HOSTNAME=ollama  CORES=4  MEMORY_MB=16384  ROOTFS_GB=128
  STORAGE=<rootdir storage>  BRIDGE=vmbr0  IP_CIDR=<a.b.c.d/nn|dhcp>  GATEWAY=<a.b.c.d>
  NAMESERVER=<a.b.c.d>  VLAN_TAG=<1-4094>  SSH_PUBLIC_KEY=<file>
  GPU=auto|nvidia|amd|intel|none   auto: nvidia when /dev/nvidia0 exists, else amd
                      when /dev/kfd exists, else intel for an Arc card's render
                      node, else none (yes means nvidia, no means none); with
                      GPU_CARD, auto is that card's vendor
  GPU_CARD=<PCI address>   one GPU (e.g. 0000:03:00.0, as lspci -D shows it) on a
                      host with several: the community script passes every card
                      of the vendor, then only this card's device nodes are kept
                      (plus /dev/kfd, /dev/nvidiactl and /dev/nvidia-uvm)
  OLLAMA_PULL_MODELS='qwen3:8b qwen3:14b'
  OLLAMA_CT_OS=debian  OLLAMA_CT_VERSION=13   the CT's distribution: debian 12|13 or
                      ubuntu 22.04|24.04|26.04 (the community script's own
                      installer handles Debian 13; Ollama's release bundles its
                      runtimes, so the distribution only supplies Mesa for Arc)
  COMMUNITY_SCRIPT_URL=<url>      default: the ProxmoxVE main-branch ct/ollama.sh
  COMMUNITY_SCRIPT_SHA256=<hex>   refuse to run a script with any other checksum
When the CT sees an NVIDIA GPU but nvidia-smi is missing inside it, the
repository's NVIDIA 580.173.02 user-space helper is run before install-target.sh.
AMD Radeon (RDNA 3/4): /dev/kfd and the render node are passed through and
install-target.sh adds Ollama's ROCm libraries. Intel Arc (A/B): the render
node is passed through and install-target.sh installs Mesa's Vulkan driver for
Ollama's Vulkan backend. Run tools/setup-host-gpu.sh first on a host whose GPU
driver is not set up (the router installer does).
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
    local passthrough=yes
    [[ $gpu != none ]] || passthrough=no
    printf '%s\n' "var_ctid=$CT_ID" "var_hostname=$CT_HOSTNAME" "var_cpu=$CORES" "var_ram=$MEMORY_MB" \
        "var_disk=$ROOTFS_GB" "var_unprivileged=1" "var_nesting=1" "var_gpu=$passthrough" "var_brg=$BRIDGE" \
        "var_os=$OLLAMA_CT_OS" "var_version=$OLLAMA_CT_VERSION"
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
# Intel Arc cards, by PCI device ID: 56xx (Alchemist), e2xx (Battlemage).
intel_arc_render_node() {
    local node vendor device
    for node in "${DRM_SYSFS:-/sys/class/drm}"/renderD*; do
        [[ -r $node/device/vendor && -r $node/device/device ]] || continue
        vendor=$(< "$node/device/vendor"); device=$(< "$node/device/device")
        if [[ $vendor == 0x8086 && $device =~ ^0x(56|e2)[0-9a-f]{2}$ ]]; then
            printf '/dev/dri/%s\n' "${node##*/}"
            return 0
        fi
    done
    return 1
}
# gpu_vendor MODE: nvidia, amd, intel or none for a GPU setting.
gpu_vendor() {
    case $1 in
        auto)
            if [[ -e ${NVIDIA_DEVICE:-/dev/nvidia0} ]]; then echo nvidia
            elif [[ -e ${KFD_DEVICE:-/dev/kfd} ]]; then echo amd
            elif intel_arc_render_node >/dev/null; then echo intel
            else echo none; fi ;;
        yes|nvidia) echo nvidia ;;
        amd|intel) echo "$1" ;;
        no|none) echo none ;;
        *) return 1 ;;
    esac
}
# normalize_pci_address ADDRESS: 0000:03:00.0 for 03:00.0 or 0000:03:00.0 (any case).
normalize_pci_address() {
    local address=${1,,}
    [[ $address =~ ^([0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || return 1
    [[ $address == *:*:* ]] || address=0000:$address
    printf '%s\n' "$address"
}
# card_vendor_kind ADDRESS: nvidia, amd or intel for a PCI card's vendor ID.
card_vendor_kind() {
    local vendor
    vendor=$(cat "${PCI_SYSFS:-/sys/bus/pci/devices}/$1/vendor" 2>/dev/null) || return 1
    case $vendor in
        0x10de) echo nvidia ;;
        0x1002) echo amd ;;
        0x8086) echo intel ;;
        *) return 1 ;;
    esac
}
# card_device_nodes ADDRESS: one card's host device nodes: its DRM render and
# card nodes, and an NVIDIA card's /dev/nvidia<minor> (from the driver's
# /proc/driver/nvidia/gpus/<address>/information).
card_device_nodes() {
    local node minor
    for node in "${PCI_SYSFS:-/sys/bus/pci/devices}/$1/drm/"renderD* "${PCI_SYSFS:-/sys/bus/pci/devices}/$1/drm/"card*; do
        [[ -e $node ]] && printf '/dev/dri/%s\n' "${node##*/}"
    done
    minor=$(sed -n 's/^Device Minor:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
        "${NVIDIA_PROC:-/proc/driver/nvidia}/gpus/$1/information" 2>/dev/null | head -n1)
    [[ -z $minor ]] || printf '/dev/nvidia%s\n' "$minor"
    return 0
}
# config_devices: "devN path" for each device entry of `pct config` on stdin.
config_devices() {
    local line key path
    while IFS= read -r line; do
        key=${line%%:*}
        [[ $key =~ ^dev[0-9]+$ ]] || continue
        path=${line#*: }; path=${path%%,*}; path=${path#path=}
        printf '%s %s\n' "$key" "$path"
    done
}
# other_card_devices NODE...: the devN entries of `pct config` (stdin) that pass
# another card's GPU node: a DRM render or card node, or /dev/nvidia<N>, not in
# NODE.... The nodes all cards share (/dev/kfd, /dev/nvidiactl,
# /dev/nvidia-uvm*, /dev/nvidia-caps/*) stay.
other_card_devices() {
    local nodes=" $* " key path
    while read -r key path; do
        [[ $path =~ ^/dev/dri/(renderD|card)[0-9]+$ || $path =~ ^/dev/nvidia[0-9]+$ ]] || continue
        [[ $nodes == *" $path "* ]] || printf '%s\n' "$key"
    done < <(config_devices)
}
# valid_ct_os OS VERSION: a distribution the community script and this target support.
valid_ct_os() { [[ $1 == debian && $2 =~ ^(12|13)$ || $1 == ubuntu && $2 =~ ^(22\.04|24\.04|26\.04)$ ]]; }
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
GPU_CARD=${GPU_CARD:-}
OLLAMA_PULL_MODELS=${OLLAMA_PULL_MODELS:-}
COMMUNITY_SCRIPT_URL=${COMMUNITY_SCRIPT_URL:-$COMMUNITY_SCRIPT_DEFAULT_URL}
COMMUNITY_SCRIPT_SHA256=${COMMUNITY_SCRIPT_SHA256:-}
OLLAMA_CT_OS=${OLLAMA_CT_OS:-debian}
OLLAMA_CT_VERSION=${OLLAMA_CT_VERSION:-13}

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
valid_ct_os "$OLLAMA_CT_OS" "$OLLAMA_CT_VERSION" ||
    die 'OLLAMA_CT_OS/OLLAMA_CT_VERSION must be debian 12|13 or ubuntu 22.04|24.04|26.04.'
gpu=$(gpu_vendor "$GPU") || die 'GPU must be auto, nvidia, amd, intel or none (yes means nvidia, no means none).'
card=''
if [[ -n $GPU_CARD ]]; then
    card=$(normalize_pci_address "$GPU_CARD") || die 'GPU_CARD must be a PCI address such as 0000:03:00.0.'
    [[ $GPU != no && $GPU != none ]] || die 'GPU_CARD names a GPU, but GPU is none.'
    if card_kind=$(card_vendor_kind "$card"); then
        if [[ $GPU == auto ]]; then
            gpu=$card_kind
        elif [[ $card_kind != "$gpu" ]]; then
            die "GPU_CARD $card is an ${card_kind^^} card, not ${gpu^^} (GPU=$GPU)."
        fi
    elif (( ! dry_run )); then
        die "GPU_CARD: no NVIDIA, AMD or Intel GPU at $card on this host."
    fi
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
files=(install-target.sh ollama.env.example ollama-target.conf README.md)
for file in "${files[@]}"; do [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"; done
nvidia_installer=''
for candidate in "$source_dir/../../tools/install_nvidia_580_173_02.sh" "$source_dir/../../install_nvidia_580_173_02.sh"; do
    if [[ -r $candidate ]]; then nvidia_installer=$candidate; break; fi
done
[[ $gpu != nvidia || -n $nvidia_installer ]] || die 'NVIDIA passthrough needs install_nvidia_580_173_02.sh in the repository root or tools directory.'

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
mapfile -t presets < <(community_vars)
# narrow_gpu_devices: the community script passes every card of the chosen
# vendor; with GPU_CARD only that card's nodes (and the shared ones) stay. The
# CT is restarted for the change.
narrow_gpu_devices() {
    local -a nodes=() drop=()
    local attempt primary='' node
    [[ -n $card ]] || return 0
    if (( dry_run )); then
        printf '+ keep only the GPU at %s in CT %s: delete the device entries of other cards (pct stop, pct set --delete, pct start)\n' "$card" "$CT_ID"
        return 0
    fi
    mapfile -t nodes < <(card_device_nodes "$card")
    for node in "${nodes[@]}"; do
        if [[ $node == /dev/dri/renderD* || $node == /dev/nvidia[0-9]* ]]; then primary=$node; break; fi
    done
    if [[ -z $primary ]]; then
        printf 'Warning: the GPU at %s has no render node or /dev/nvidia<N> on this host; CT %s keeps the devices the community script passed.\n' \
            "$card" "$CT_ID" >&2
        return 0
    fi
    if ! pct config "$CT_ID" | config_devices | grep -q -- " $primary\$"; then
        printf 'Warning: CT %s does not pass %s, the GPU at %s. Add it in the CT'"'"'s Resources (Device Passthrough), then run install-target.sh again.\n' \
            "$CT_ID" "$primary" "$card" >&2
    fi
    mapfile -t drop < <(pct config "$CT_ID" | other_card_devices "${nodes[@]}")
    (( ${#drop[@]} )) || return 0
    printf 'CT %s: passing only the GPU at %s (%s).\n' "$CT_ID" "$card" "${nodes[*]}"
    run pct stop "$CT_ID"
    run pct set "$CT_ID" --delete "$(IFS=,; printf '%s' "${drop[*]}")"
    run pct start "$CT_ID"
    for (( attempt = 0; attempt < 45; attempt++ )); do
        pct exec "$CT_ID" -- test -d /run/systemd/system 2>/dev/null && return 0
        sleep 1
    done
    die "CT $CT_ID did not start systemd within 45 seconds."
}

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
if [[ $gpu != none ]]; then
    printf 'GPU: %s%s. If the community script asks which GPU type to pass through, answer %s.\n' "$gpu" "${card:+ (the card at $card)}" "${gpu^^}"
fi
run env "${presets[@]}" bash "$script"
if (( ! dry_run )); then
    pct status "$CT_ID" >/dev/null 2>&1 || die "The community script did not create CT $CT_ID (did you change the ID in its menu?)."
    # The community script chooses the devices itself: check it passed this GPU.
    case $gpu in
        nvidia) want='/dev/nvidia' ;;
        amd) want='/dev/kfd' ;;
        intel) want='/dev/dri/renderD' ;;
        *) want='' ;;
    esac
    if [[ -n $want ]] && ! pct config "$CT_ID" 2>/dev/null | grep -q -- "$want"; then
        printf 'Warning: CT %s has no %s device; Ollama will run on the CPU. Add the %s GPU in the CT'"'"'s Resources (Device Passthrough), then run install-target.sh again.\n' \
            "$CT_ID" "$want" "$gpu" >&2
    fi
fi
narrow_gpu_devices

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2; rm -f -- "$script"' ERR
# QEMU guest agent: Proxmox does not use it for an LXC (no virtio-serial port, so
# the service stays inactive), but every guest carries it. A failure is not fatal.
run pct exec "$CT_ID" -- sh -c 'export DEBIAN_FRONTEND=noninteractive; for i in 1 2 3 4 5; do apt-get update -q && apt-get install -y -q qemu-guest-agent && exit 0; sleep 5; done; exit 1' ||
    printf 'Warning: qemu-guest-agent did not install in CT %s; continuing.\n' "$CT_ID" >&2
run pct exec "$CT_ID" -- install -d -m 0700 /root/ollama-target-deploy
for file in "${files[@]}"; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/ollama-target-deploy/$file" --perms 0644
done
if [[ $gpu == nvidia ]]; then
    run pct push "$CT_ID" "$nvidia_installer" /root/ollama-target-deploy/install_nvidia_580_173_02.sh --perms 0755
fi
if (( INSTALL_TARGET )); then
    if [[ $gpu == nvidia ]]; then
        if (( dry_run )) || ! pct exec "$CT_ID" -- nvidia-smi -L >/dev/null 2>&1; then
            run pct exec "$CT_ID" -- bash /root/ollama-target-deploy/install_nvidia_580_173_02.sh lxc
        fi
    fi
    run pct exec "$CT_ID" -- env "OLLAMA_GPU=$gpu" "OLLAMA_PULL_MODELS=$OLLAMA_PULL_MODELS" bash /root/ollama-target-deploy/install-target.sh
else
    printf '\nOllama is installed as the community script left it (running as root).\n'
    printf 'To adopt it into the target layout, inside the CT (pct enter %s) run:\n' "$CT_ID"
    if [[ $gpu == nvidia ]]; then printf '  bash /root/ollama-target-deploy/install_nvidia_580_173_02.sh lxc   # if nvidia-smi is missing\n'; fi
    printf '  OLLAMA_GPU=%s bash /root/ollama-target-deploy/install-target.sh\n' "$gpu"
fi
printf 'Register it with the router: manage-model-servers add http://<CT %s address>:11434\n' "$CT_ID"
