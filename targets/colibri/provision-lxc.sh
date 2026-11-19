#!/usr/bin/env bash
# Run on the Proxmox host, never inside the router CT. A GPU is optional.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../nvidia-lxc.sh"
usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run]

The installer asks for the CT ID (default: the cluster's next free ID, which
unattended runs take), IP/CIDR (or dhcp) and a gateway for static IPs. Preset
CT_ID to choose another ID, and IP_CIDR and GATEWAY for unattended runs.

Creates an unprivileged Proxmox VE 9 LXC, clones https://github.com/JustVugg/colibri
inside the CT, builds its engine with make, and starts its OpenAI-compatible API
as a systemd service. A random API key is generated inside the CT. No model is
downloaded: models are far too large to fetch unattended, so the service comes up
parked until an operator places one (see README.md). --dry-run validates settings
and prints the PVE command plan.

Required: TEMPLATE (downloaded Ubuntu 22.04/24.04 or
Debian 12/13 amd64; Debian 13 for Vulkan), STORAGE (rootdir storage), IP_CIDR
(a.b.c.d/nn or dhcp). GATEWAY is required for a static address. A CT given an
NVIDIA GPU installs user-space matching the loaded host NVIDIA driver.
Interactive runs list downloaded templates and eligible rootdir storage when
those values are unset. This script creates a new
CT; to resume or upgrade an existing Colibri CT, run its guest install-target.sh.

Optional: CT_HOSTNAME=colibri-target, BRIDGE=vmbr0, CORES=8, MEMORY_MB=65536
          (8192 or more), SWAP_MB=0, ROOTFS_GB=160 (40 or more), ONBOOT=1,
          NAMESERVER, VLAN_TAG, SSH_PUBLIC_KEY=<readable file>,
          GPU_DEVICES= (empty: the CPU. For CUDA '/dev/nvidia0 /dev/nvidiactl
                      /dev/nvidia-uvm', plus /dev/nvidia-uvm-tools when the host
                      has it; for Vulkan on AMD Radeon or Intel Arc the card's
                      render node, e.g. /dev/dri/renderD128),
          GPU_GID=44 (the CT group given the GPU nodes; 44 is "video"),
          NVIDIA_DRIVER_VERSION=auto (loaded host driver; or an exact-version check),
          NVIDIA_GUEST_INSTALLER=<host path to matching LXC helper>,
          COLIBRI_COMMIT=0a5504a1dc64f86fcd0fe7db298b0448c730e7e6 (tested default),
          COLIBRI_REF=<branch or tag> (explicitly follow it when no commit is set),
          COLIBRI_MODEL_DIR=/var/lib/colibri/model (created empty: a model is
                    NEVER downloaded here. Colibri models run from ~18 GB to
                    500 GB+, so the operator copies one in later and restarts
                    the service; see README.md. It must be an absolute path
                    without ".." inside the CT's data directory),
          COLIBRI_BACKEND=auto (auto|cpu|vulkan|cuda; auto follows GPU_DEVICES:
                    cuda for NVIDIA nodes, vulkan for a render node, else cpu),
          COLIBRI_HOST=0.0.0.0, COLIBRI_PORT=8080,
          COLIBRI_ALLOWED_HOST=* (comma-separated Host headers the server's
                    DNS-rebinding guard accepts besides loopback; * because
                    clients reach a 0.0.0.0 bind by addresses the CT cannot
                    know. The API key is required either way),
          COLIBRI_READY_TIMEOUT=900.

GPU passthrough is optional: with GPU_DEVICES empty (the default) the CT gets
no device line and Colibri runs on its CPU backend.
Explicit COLIBRI_REF or an empty COLIBRI_COMMIT follows a branch tip (main if no
ref is set).

The new CT is retained if a later step fails so setup can be inspected and
resumed. No existing CT, router, host driver, or host network setting is changed.
USAGE
}

ipv4() {
    local value=$1 octet
    local -a octets
    [[ $value =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<< "$value"
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || return 1
    done
}
valid_ip_cidr() {
    local address prefix
    [[ $1 == dhcp ]] && return 0
    [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    address=${BASH_REMATCH[1]}; prefix=${BASH_REMATCH[2]}
    ipv4 "$address" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( prefix <= 32 ))
}
positive_int() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}

dry_run=0
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

CT_ID=${CT_ID:-}
TEMPLATE=${TEMPLATE:-}
STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
CT_HOSTNAME=${CT_HOSTNAME:-colibri-target}
BRIDGE=${BRIDGE:-vmbr0}
CORES=${CORES:-8}
MEMORY_MB=${MEMORY_MB:-65536}
SWAP_MB=${SWAP_MB:-0}
ROOTFS_GB=${ROOTFS_GB:-160}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
# Colibri is CPU-first: a GPU is a speedup, never a requirement. GPU_DEVICES
# stays empty unless one was assigned (the installer exports it for a CT that got
# a card; a standalone run can set it). With it empty the CT gets no --devN line
# and the service runs on the CPU backend -- so never default to a card that the
# caller chose not to hand out.
GPU_DEVICES=${GPU_DEVICES:-}
# The Colibri service runs as an unprivileged account that joins this group, so
# the nodes must not be root's group inside the CT.
GPU_GID=${GPU_GID:-44}
NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION:-auto}
# Pin an unconfigured install to the source used by the upstream regression
# test. An explicit ref, or an explicitly empty commit, opts into branch tips.
COLIBRI_DEFAULT_COMMIT=0a5504a1dc64f86fcd0fe7db298b0448c730e7e6
if [[ ! ${COLIBRI_COMMIT+x} && ! ${COLIBRI_REF+x} ]]; then
    COLIBRI_COMMIT=$COLIBRI_DEFAULT_COMMIT
else
    COLIBRI_COMMIT=${COLIBRI_COMMIT:-}
fi
COLIBRI_REF=${COLIBRI_REF:-main}
# Colibri serves a model directory, and models run from ~18 GB to 500 GB+, so the
# installer never picks or fetches one: the guest creates COLIBRI_MODEL_DIR
# (default /var/lib/colibri/model) empty, and the service comes up parked until
# an operator copies a model into it. See README.md.
COLIBRI_MODEL_DIR=${COLIBRI_MODEL_DIR:-/var/lib/colibri/model}
COLIBRI_BACKEND=${COLIBRI_BACKEND:-auto}
COLIBRI_HOST=${COLIBRI_HOST:-0.0.0.0}
COLIBRI_PORT=${COLIBRI_PORT:-8080}
COLIBRI_ALLOWED_HOST=${COLIBRI_ALLOWED_HOST:-}
COLIBRI_READY_TIMEOUT=${COLIBRI_READY_TIMEOUT:-900}

# --- Questions: the container, one section ----------------------------------
valid_template_volume() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/[A-Za-z0-9._-]+$ ]]; }
valid_storage_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
pve_ask_new_ct Colibri
positive_int ROOTFS_GB "$ROOTFS_GB"
if pve_interactive && (( ! dry_run )); then _pve_heading; fi
pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
pve_select_storage STORAGE rootdir "$ROOTFS_GB"
pve_suggest TEMPLATE 'Ubuntu 22.04/24.04 or Debian 12/13 amd64 template' '' valid_template_volume 'Use a downloaded LXC template volume (storage:vztmpl/...).'
pve_suggest STORAGE 'Root disk storage' '' valid_storage_id
pve_ask_network Colibri dhcp

[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'CT_ID must be an unused numeric ID of 100 or more.'
[[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] || \
    die 'TEMPLATE must be a downloaded Ubuntu 22.04/24.04 or Debian 12/13 amd64 LXC template.'
[[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'STORAGE must be a Proxmox rootdir storage ID.'
valid_ip_cidr "$IP_CIDR" || die 'IP_CIDR must be dhcp or a valid IPv4 address/CIDR.'
if [[ $IP_CIDR != dhcp ]]; then ipv4 "$GATEWAY" || die 'GATEWAY must be a valid IPv4 address for a static IP.'; fi
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
for name in CORES MEMORY_MB ROOTFS_GB COLIBRI_READY_TIMEOUT; do positive_int "$name" "${!name}"; done
# Floors for the engine alone, not for a model: Colibri runs on the CPU with
# nothing else installed, and the model an operator places later is the real
# requirement. Kept modest so a CPU-only CT is provisionable.
(( MEMORY_MB >= 8192 )) || die 'MEMORY_MB must be at least 8192 for Colibri (a model needs more).'
(( ROOTFS_GB >= 40 )) || die 'ROOTFS_GB must be at least 40 for the Colibri checkout and its engines (a model needs far more).'
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY ]] || die 'SSH_PUBLIC_KEY must be a readable file.'
[[ $GPU_GID =~ ^[1-9][0-9]{0,4}$ ]] && (( GPU_GID <= 65535 )) || die 'GPU_GID must be a non-root group ID (1..65535).'
[[ $NVIDIA_DRIVER_VERSION == auto || $NVIDIA_DRIVER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid NVIDIA_DRIVER_VERSION.'
[[ $COLIBRI_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $COLIBRI_REF != HEAD && $COLIBRI_REF != *..* ]] || die 'COLIBRI_REF must be a branch or tag name.'
[[ -z $COLIBRI_COMMIT || $COLIBRI_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'COLIBRI_COMMIT must be a full 40-digit SHA-1.'
[[ -z $COLIBRI_MODEL_DIR || ( $COLIBRI_MODEL_DIR == /* && $COLIBRI_MODEL_DIR != *..* ) ]] || die 'COLIBRI_MODEL_DIR must be empty or an absolute path without "..".'
[[ $COLIBRI_BACKEND =~ ^(auto|cpu|vulkan|cuda)$ ]] || die 'COLIBRI_BACKEND must be auto, cpu, vulkan or cuda.'
[[ $COLIBRI_HOST =~ ^[A-Za-z0-9._:-]{1,63}$ ]] || die 'Invalid COLIBRI_HOST.'
# Comma-separated host names, addresses or *; ']' must come first in a bracket
# expression (a backslash there is literal). The guest checks each entry.
[[ -z $COLIBRI_ALLOWED_HOST || ( ${#COLIBRI_ALLOWED_HOST} -le 255 && $COLIBRI_ALLOWED_HOST =~ ^[][A-Za-z0-9._:*,-]+$ ) ]] || die 'Invalid COLIBRI_ALLOWED_HOST.'
[[ $COLIBRI_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( COLIBRI_PORT <= 65535 )) || die 'COLIBRI_PORT must be 1..65535.'
[[ $COLIBRI_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'COLIBRI_READY_TIMEOUT must be a positive number of seconds.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Where to send a host without a GPU driver (the router installer runs it too).
gpu_hint=" Without a driver for that GPU on this host, run: bash ${source_dir%/*/*}/tools/setup-host-gpu.sh"
for file in install-target.sh colibri.service; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
NVIDIA_GUEST_INSTALLER=${NVIDIA_GUEST_INSTALLER:-$source_dir/../../tools/install-nvidia-driver.sh}
[[ -r $NVIDIA_GUEST_INSTALLER ]] || die "Missing NVIDIA LXC user-space helper: $NVIDIA_GUEST_INSTALLER"

read -r -a devices <<< "$GPU_DEVICES"
declare -A seen_devices=()
have_gpu=0; have_ctl=0; have_uvm=0; have_nvidia=0; have_dri=0
for device in "${devices[@]}"; do
    [[ $device =~ ^/dev/[A-Za-z0-9_./-]+$ && $device != *'/../'* && $device != *'/./'* ]] || die "Invalid GPU device path: $device"
    [[ -z ${seen_devices[$device]:-} ]] || die "Duplicate GPU device path: $device"
    seen_devices[$device]=1
    case $device in
        /dev/nvidia[0-9]*) [[ $device =~ ^/dev/nvidia[0-9]+$ ]] || die "Invalid GPU device path: $device"; have_gpu=1; have_nvidia=1 ;;
        /dev/nvidiactl) have_ctl=1; have_nvidia=1 ;;
        /dev/nvidia-uvm) have_uvm=1; have_nvidia=1 ;;
        /dev/nvidia-uvm-tools) have_nvidia=1 ;;
        /dev/dri/renderD[0-9]*) have_dri=1 ;;
        *) die "GPU_DEVICES takes NVIDIA nodes (/dev/nvidia*) or a render node (/dev/dri/renderD<n>), not $device." ;;
    esac
    if (( ! dry_run )); then [[ -c $device ]] || die "GPU device is missing on the PVE host: $device.$gpu_hint"; fi
done
(( ${#devices[@]} <= 32 )) || die 'GPU_DEVICES lists too many device paths (32 at most).'
(( ! (have_nvidia && have_dri) )) || die 'GPU_DEVICES mixes NVIDIA nodes and a render node; pass one GPU: CUDA or Vulkan.'
if (( have_nvidia )); then
    # A CUDA CT: it must get the full NVIDIA node set, or the guest driver cannot
    # work. An empty GPU_DEVICES is the supported CPU-only case and skips this.
    (( have_gpu && have_ctl && have_uvm )) ||
        die 'GPU_DEVICES must include /dev/nvidiaN, /dev/nvidiactl and /dev/nvidia-uvm, or be empty for a CPU-only CT.'
    [[ $NVIDIA_DRIVER_VERSION == auto ]] || nvidia_lxc_require_series "$NVIDIA_DRIVER_VERSION" 580 'CUDA 13'
fi
# An explicit GPU backend needs its device here: the guest would otherwise
# build for the CPU (and warn) on a CT made for a GPU it never got.
[[ $COLIBRI_BACKEND != cuda ]] || (( have_nvidia )) ||
    die 'COLIBRI_BACKEND=cuda needs the NVIDIA nodes in GPU_DEVICES (/dev/nvidiaN /dev/nvidiactl /dev/nvidia-uvm).'
[[ $COLIBRI_BACKEND != vulkan ]] || (( have_dri )) ||
    die 'COLIBRI_BACKEND=vulkan needs the card'"'"'s render node in GPU_DEVICES (/dev/dri/renderD<n>).'
gpu_label='none (CPU)'
(( ! have_nvidia )) || gpu_label="NVIDIA (CUDA): ${devices[*]}"
(( ! have_dri )) || gpu_label="render node (Vulkan): ${devices[*]}"

# --- Colibri settings --------------------------------------------------------
# Nothing to ask: the model is never chosen or fetched here (models run from
# ~18 GB to 500 GB+, so the service comes up parked until an operator places
# one), the backend resolves itself in the guest, and the server binds 0.0.0.0
# on COLIBRI_PORT. See the CT summary below and README.md.

ostype=debian
[[ $TEMPLATE == *:vztmpl/ubuntu-* ]] && ostype=ubuntu
net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY || $IP_CIDR == dhcp ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype "$ostype"
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT" --tags 'ai;ai-model;osr-target;colibri'
    --description "Colibri inference target; OpenAI API on TCP $COLIBRI_PORT")
[[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
[[ -z $SSH_PUBLIC_KEY ]] || create+=(--ssh-public-keys "$SSH_PUBLIC_KEY")
for i in "${!devices[@]}"; do create+=("--dev$i" "path=${devices[$i]},gid=$GPU_GID,mode=0660"); done

if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root on the PVE host.'
    for command_name in pveversion pct pvesh pvesm; do
        command -v "$command_name" >/dev/null || die "Missing PVE command: $command_name"
    done
    # nvidia-smi is only needed when the CT is handed NVIDIA devices.
    if (( have_nvidia )); then
        command -v nvidia-smi >/dev/null || die "Missing PVE/driver command: nvidia-smi.$gpu_hint"
    fi
    [[ $(pveversion) == pve-manager/9.* ]] || die 'This script targets Proxmox VE 9.x.'
    [[ -d /etc/pve/nodes ]] || die '/etc/pve is unavailable.'
    if ! pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null; then
        if pct status "$CT_ID" >/dev/null 2>&1; then
            die "CT $CT_ID already exists. This script only creates new Colibri CTs; resume or upgrade it with: pct exec $CT_ID -- bash /root/colibri-target-deploy/install-target.sh"
        fi
        die "CT ID $CT_ID is unavailable in this cluster."
    fi
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge interface is missing: $BRIDGE"
    template_path=$(pvesm path "$TEMPLATE")
    [[ -f $template_path && -r $template_path ]] || die "Template is not readable: $TEMPLATE"
    storage_ready=0
    while read -r storage_name _ status _; do
        [[ $storage_name == "$STORAGE" && $status == active ]] && storage_ready=1
    done < <(pvesm status --content rootdir 2>/dev/null || true)
    (( storage_ready )) || die "Storage is not active or does not support rootdir: $STORAGE"
    if (( have_nvidia )); then
        host_driver=$(nvidia_lxc_host_version) || die 'Cannot determine the loaded NVIDIA driver version on this Proxmox host.'
        [[ $NVIDIA_DRIVER_VERSION == auto || $host_driver == "$NVIDIA_DRIVER_VERSION" ]] ||
            die "Host NVIDIA driver is $host_driver; expected $NVIDIA_DRIVER_VERSION."
        NVIDIA_DRIVER_VERSION=$host_driver
        nvidia_lxc_require_series "$NVIDIA_DRIVER_VERSION" 580 'CUDA 13'
    fi
else
    [[ $NVIDIA_DRIVER_VERSION != auto ]] || NVIDIA_DRIVER_VERSION='<host-nvidia-driver-version>'
fi

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2' ERR
pve_summary "Colibri: create"
pve_row 'Colibri CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB} GiB on $STORAGE"
pve_row 'Template' "$TEMPLATE"
pve_row 'Network' "$IP_CIDR${GATEWAY:+ via $GATEWAY} on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
pve_row 'GPU' "$gpu_label"
pve_row 'Server' "backend $COLIBRI_BACKEND, host $COLIBRI_HOST, port $COLIBRI_PORT"
pve_row 'Model' "$COLIBRI_MODEL_DIR, created empty (parked until a model is copied in; none is downloaded)"
pve_confirm "Create Colibri CT $CT_ID?"
(umask 022; run "${create[@]}")
# Colibri pins tens of GiB of model memory. systemd's LimitMEMLOCK must be
# allowed by the outer LXC hard limit too.
ct_config="/etc/pve/lxc/${CT_ID}.conf"
if (( dry_run )); then
    printf '+ set lxc.prlimit.memlock: unlimited in %s\n' "$ct_config"
else
    [[ -f $ct_config ]] || die "New CT configuration was not created: $ct_config"
    if grep -q '^lxc\.prlimit\.memlock:' "$ct_config"; then
        die "New CT already has a memlock limit; inspect $ct_config before starting."
    fi
    printf 'lxc.prlimit.memlock: unlimited\n' >> "$ct_config"
fi
run pct start "$CT_ID"
if (( ! dry_run )); then
    ready=0
    for (( attempt=0; attempt<60; attempt++ )); do
        if pct exec "$CT_ID" -- test -d /run/systemd/system; then ready=1; break; fi
        sleep 1
    done
    (( ready )) || die "CT $CT_ID did not start systemd within 60 seconds."
    for i in "${!devices[@]}"; do
        pct exec "$CT_ID" -- test -c "${devices[$i]}" ||
            die "CT $CT_ID has no character device at ${devices[$i]}; inspect its --dev$i mapping with 'pct config $CT_ID'."
        guest_perms=$(pct exec "$CT_ID" -- stat -c '%g %a' "${devices[$i]}") ||
            die "CT $CT_ID cannot stat ${devices[$i]}; inspect its --dev$i mapping with 'pct config $CT_ID'."
        read -r guest_gid guest_mode <<< "$guest_perms"
        if [[ $guest_gid != "$GPU_GID" ]]; then
            printf 'Warning: CT %s sees %s with gid %s and mode %s although --dev%s requests gid %s and mode 0660. The guest installer will check access as the colibri account.\n' \
                "$CT_ID" "${devices[$i]}" "$guest_gid" "$guest_mode" "$i" "$GPU_GID" >&2
        fi
    done
    online=0
    for (( attempt=0; attempt<60; attempt++ )); do
        if pct exec "$CT_ID" -- sh -c 'ip route show default | grep -q . && getent hosts github.com >/dev/null'; then
            online=1; break
        fi
        sleep 3
    done
    (( online )) || die "CT $CT_ID has no default route or DNS after 180 seconds; check network settings."
fi
run pct exec "$CT_ID" -- install -d -m 0700 /root/colibri-target-deploy
run pct push "$CT_ID" "$source_dir/install-target.sh" /root/colibri-target-deploy/install-target.sh --perms 0755
run pct push "$CT_ID" "$source_dir/colibri.service" /root/colibri-target-deploy/colibri.service --perms 0644
run pct push "$CT_ID" "$NVIDIA_GUEST_INSTALLER" /root/colibri-target-deploy/nvidia-guest-install.sh --perms 0755
# Only an NVIDIA CT needs the NVIDIA user-space in the guest; a CPU-only or
# Vulkan CT must not be told to install that driver (Mesa's Vulkan driver is
# installed by install-target.sh).
if (( have_nvidia )); then
    nvidia_lxc_install_guest "$CT_ID" "$NVIDIA_DRIVER_VERSION" /root/colibri-target-deploy/nvidia-guest-install.sh
fi
run pct exec "$CT_ID" -- env "COLIBRI_REF=$COLIBRI_REF" "COLIBRI_COMMIT=$COLIBRI_COMMIT" \
    "COLIBRI_MODEL_DIR=$COLIBRI_MODEL_DIR" "COLIBRI_BACKEND=$COLIBRI_BACKEND" \
    "COLIBRI_HOST=$COLIBRI_HOST" "COLIBRI_PORT=$COLIBRI_PORT" \
    "COLIBRI_ALLOWED_HOST=$COLIBRI_ALLOWED_HOST" \
    "COLIBRI_READY_TIMEOUT=$COLIBRI_READY_TIMEOUT" \
    bash /root/colibri-target-deploy/install-target.sh

printf '\nColibri target CT %s: API port %s. Read its generated key with:\n' "$CT_ID" "$COLIBRI_PORT"
printf '  pct exec %s -- cat /etc/colibri-target/api-key\n' "$CT_ID"
printf 'Then on OSR: manage-model-servers set-colibri-token (paste it), and\n'
printf '  manage-model-servers add colibri://<CT address>:%s --tier <tier> --apply\n' "$COLIBRI_PORT"
printf '(the OSR installer does both for a CT it creates).\n'
printf 'No model is downloaded: the service is parked until one is placed (README.md).\n'
printf 'Service logs: pct exec %s -- journalctl -u colibri -f\n' "$CT_ID"
printf 'Upgrade later: push the current install-target.sh and colibri.service to\n'
printf '  /root/colibri-target-deploy in the CT, then run it there with --upgrade.\n'
