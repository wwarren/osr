#!/usr/bin/env bash
# Run on the Proxmox host with the NVIDIA GPU, never inside the router CT.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../nvidia-lxc.sh"
usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run]
   or: CT_ID=282 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_<version>_amd64.tar.zst \
       STORAGE=local-lvm IP_CIDR=192.0.2.82/24 GATEWAY=192.0.2.1 \
       bash targets/xolotl/provision-lxc.sh [--dry-run]

Creates an unprivileged Proxmox VE 9 LXC, passes an NVIDIA GPU through, clones
https://github.com/Indras-Mirror/Xolotl.git inside the CT, builds its
DeepSeek-V4.1-Flash engine with a CUDA 13.0 toolkit (no driver), downloads the
pinned DeepSeek-V4.1-Flash-1017 V4 quant and Engram tables (about 372 GB, see
xolotl-weights.txt) and starts its API as a systemd service. A random API key
is generated inside the CT. The download and the first load take hours.
--dry-run validates settings and prints the PVE command plan.

Required: CT_ID (unused, >=100), TEMPLATE (downloaded Ubuntu 22.04/24.04 or
Debian 12/13 amd64), STORAGE (rootdir storage on a fast NVMe; not a hard
drive), IP_CIDR (a.b.c.d/nn or dhcp). GATEWAY is required for a static address.
The host needs an NVIDIA GPU of compute capability 7.5 or newer (RTX 20 series
and later) with 24 GB of VRAM (16 GB is untested upstream). The CT installs
user-space matching the loaded host NVIDIA driver.
An interactive run lists downloaded templates and eligible rootdir storage
when TEMPLATE or STORAGE is unset.

On a host without an NVIDIA driver, run tools/setup-host-gpu.sh first: it
asks for the GPU generation and installs the driver (the router installer runs
it for every selected GPU target). The engine is built for the compute
capability of GPU 0 (XOLOTL_CUDA_ARCH=auto).

Optional: CT_HOSTNAME=xolotl-target, BRIDGE=vmbr0, CORES=8, MEMORY_MB=98304,
          SWAP_MB=0, ROOTFS_GB=420, ONBOOT=1, NAMESERVER, VLAN_TAG,
          SSH_PUBLIC_KEY=<readable file>,
          GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
                      (plus /dev/nvidia-uvm-tools when the host has it),
          GPU_GID=44 (the CT group given the GPU nodes; 44 is "video"),
          NVIDIA_DRIVER_VERSION=auto (loaded host driver; or an exact-version check),
          NVIDIA_GUEST_INSTALLER=<host path to matching LXC helper>,
          XOLOTL_REF=<branch or tag>, XOLOTL_COMMIT=<full SHA-1 pin>
          (default: tested commit in upstream-commit.txt),
          XOLOTL_CUDA_VERSION=13.0, XOLOTL_CUDA_ARCH=auto, XOLOTL_PORT=8080,
          XOLOTL_CONTEXT=131072, XOLOTL_ARENA_GIB=60, XOLOTL_DSPARK=true,
          XOLOTL_MODEL_NAME=deepseek-v4.1-flash, XOLOTL_READY_TIMEOUT=1800.

XOLOTL_ARENA_GIB is the RAM the engine pins for experts; the CT needs at least
16 GiB more than that. Upstream measured 90 GB of RAM with a 64 GiB arena;
around 256 GB holds every expert.

The new CT is retained if a later step fails so the install can be inspected
and resumed (rerunning install-target.sh in the CT resumes the download). No
existing CT, router, host driver, or host network setting is changed.
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

# version_at_least A B: is version A >= B (major.minor[.patch])?
version_at_least() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1) == "$2" ]]; }
# host_driver_loaded: does an NVIDIA driver on this host list a GPU?
host_driver_loaded() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }

# require_host_gpu: the engine runs on the host's NVIDIA driver. Without one,
# point to tools/setup-host-gpu.sh, which asks for the GPU generation and
# installs it (the router installer runs it for every GPU target).
require_host_gpu() {
    host_driver_loaded && return 0
    if (( dry_run )); then
        printf 'Note: no NVIDIA driver is loaded on this host; a real run stops here until bash %s installs it.\n' "$gpu_tool" >&2
        return 0
    fi
    die "No NVIDIA driver is loaded on this host (nvidia-smi lists no GPU). Run: bash $gpu_tool (it asks for the GPU generation and installs the driver), then run this again. The router installer does this for every GPU target."
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
CT_HOSTNAME=${CT_HOSTNAME:-xolotl-target}
BRIDGE=${BRIDGE:-vmbr0}
CORES=${CORES:-8}
MEMORY_MB=${MEMORY_MB:-98304}
SWAP_MB=${SWAP_MB:-0}
ROOTFS_GB=${ROOTFS_GB:-420}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
# The default device list is settled after the host driver is (see below).
GPU_DEVICES=${GPU_DEVICES:-}
# The Xolotl service runs as an unprivileged account that joins this group, so
# the nodes must not be root's group inside the CT.
GPU_GID=${GPU_GID:-44}
NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION:-auto}
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/upstream-commit.txt ]] || die "Missing deployment file: $source_dir/upstream-commit.txt"
default_commit=$(< "$source_dir/upstream-commit.txt")
[[ $default_commit =~ ^[0-9a-f]{40}$ ]] || die 'Invalid upstream-commit.txt.'
if [[ -z ${XOLOTL_REF:-} && -z ${XOLOTL_COMMIT:-} ]]; then XOLOTL_COMMIT=$default_commit; fi
XOLOTL_REF=${XOLOTL_REF:-main}
XOLOTL_COMMIT=${XOLOTL_COMMIT:-}
XOLOTL_CUDA_VERSION=${XOLOTL_CUDA_VERSION:-13.0}
XOLOTL_CUDA_ARCH=${XOLOTL_CUDA_ARCH:-auto}
XOLOTL_PORT=${XOLOTL_PORT:-8080}
XOLOTL_CONTEXT=${XOLOTL_CONTEXT:-131072}
XOLOTL_ARENA_GIB=${XOLOTL_ARENA_GIB:-60}
XOLOTL_DSPARK=${XOLOTL_DSPARK:-true}
XOLOTL_MODEL_NAME=${XOLOTL_MODEL_NAME:-deepseek-v4.1-flash}
XOLOTL_READY_TIMEOUT=${XOLOTL_READY_TIMEOUT:-1800}

[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'CT_ID must be an unused numeric ID of 100 or more.'
pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04|26\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
positive_int ROOTFS_GB "$ROOTFS_GB"
pve_select_storage STORAGE rootdir "$ROOTFS_GB"
[[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04|26\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] || \
    die 'TEMPLATE must be a downloaded Ubuntu 22.04/24.04/26.04 or Debian 12/13 amd64 LXC template.'
[[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'STORAGE must be a Proxmox rootdir storage ID.'
valid_ip_cidr "$IP_CIDR" || die 'IP_CIDR must be dhcp or a valid IPv4 address/CIDR.'
if [[ $IP_CIDR != dhcp ]]; then ipv4 "$GATEWAY" || die 'GATEWAY must be a valid IPv4 address for a static IP.'; fi
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
for name in CORES MEMORY_MB ROOTFS_GB XOLOTL_CONTEXT XOLOTL_ARENA_GIB; do positive_int "$name" "${!name}"; done
(( MEMORY_MB >= 65536 )) || die 'MEMORY_MB must be at least 65536 for Xolotl (upstream measured 90 GB of RAM).'
(( XOLOTL_ARENA_GIB >= 8 )) || die 'XOLOTL_ARENA_GIB must be at least 8.'
(( XOLOTL_ARENA_GIB + 16 <= MEMORY_MB / 1024 )) ||
    die "XOLOTL_ARENA_GIB=$XOLOTL_ARENA_GIB needs MEMORY_MB of at least $(( (XOLOTL_ARENA_GIB + 16) * 1024 )) (16 GiB beside the pinned arena)."
# ~346 GiB of weights (about 5 GiB less without DSpark), one 10 GiB part while
# the model is joined, the CUDA toolkit, the build, its rollback snapshot and the OS.
(( ROOTFS_GB >= 380 )) || die 'ROOTFS_GB must be at least 380 for the DeepSeek-V4.1 weights (about 372 GB) and the build.'
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY ]] || die 'SSH_PUBLIC_KEY must be a readable file.'
[[ $GPU_GID =~ ^[1-9][0-9]{0,4}$ ]] && (( GPU_GID <= 65535 )) || die 'GPU_GID must be a non-root group ID (1..65535).'
[[ $NVIDIA_DRIVER_VERSION == auto || $NVIDIA_DRIVER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid NVIDIA_DRIVER_VERSION.'
[[ $XOLOTL_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $XOLOTL_REF != HEAD && $XOLOTL_REF != *..* ]] || die 'XOLOTL_REF must be a branch or a tag name.'
[[ -z $XOLOTL_COMMIT || $XOLOTL_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'XOLOTL_COMMIT must be a full 40-digit SHA-1.'
[[ $XOLOTL_CUDA_VERSION =~ ^(12\.(8|9)|1[3-9]\.[0-9]+)$ ]] || die 'XOLOTL_CUDA_VERSION must be 12.8 or newer.'
[[ $XOLOTL_CUDA_ARCH == auto || ( $XOLOTL_CUDA_ARCH =~ ^[1-9][0-9]{1,2}$ && $XOLOTL_CUDA_ARCH -ge 75 ) ]] ||
    die 'XOLOTL_CUDA_ARCH must be auto or a compute capability of 75 or newer (e.g. 86, 89, 120).'
[[ $XOLOTL_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( XOLOTL_PORT <= 65535 )) || die 'XOLOTL_PORT must be 1..65535.'
(( XOLOTL_CONTEXT >= 1000 && XOLOTL_CONTEXT <= 1048576 )) || die 'XOLOTL_CONTEXT must be 1000..1048576 tokens.'
[[ $XOLOTL_DSPARK =~ ^(true|false)$ ]] || die 'XOLOTL_DSPARK must be true or false.'
[[ $XOLOTL_MODEL_NAME =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die 'Invalid XOLOTL_MODEL_NAME (lowercase letters, digits, ., _ and -).'
[[ $XOLOTL_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'XOLOTL_READY_TIMEOUT must be a positive number of seconds.'
# The CT's CUDA runtime needs a host driver at least this new: CUDA 13.x needs
# the 580 series, 12.8/12.9 the 570 series.
if version_at_least "$XOLOTL_CUDA_VERSION" 13.0; then min_driver=580; else min_driver=570; fi
if [[ $NVIDIA_DRIVER_VERSION != auto ]]; then
    version_at_least "$NVIDIA_DRIVER_VERSION" "$min_driver" ||
        die "CUDA $XOLOTL_CUDA_VERSION needs NVIDIA driver $min_driver or newer; NVIDIA_DRIVER_VERSION is $NVIDIA_DRIVER_VERSION."
fi

for file in install-target.sh xolotl.service cuda-toolkit.sh xolotl-weights.txt engram-index.py upstream-commit.txt; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
# The template decides which NVIDIA CUDA repository the CT uses; refuse a
# combination that repository cannot install before any CT is created.
[[ $TEMPLATE =~ :vztmpl/(ubuntu|debian)-([0-9]+)(\.([0-9]+))?- ]]
template_dist=${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[4]}
CUDA_DIST=$template_dist CUDA_VERSION=$XOLOTL_CUDA_VERSION bash "$source_dir/cuda-toolkit.sh" --check-repo ||
    die "XOLOTL_CUDA_VERSION=$XOLOTL_CUDA_VERSION cannot be installed in a $template_dist CT (see above)."
NVIDIA_GUEST_INSTALLER=${NVIDIA_GUEST_INSTALLER:-$source_dir/../../tools/install-nvidia-driver.sh}
[[ -r $NVIDIA_GUEST_INSTALLER ]] || die "Missing NVIDIA LXC user-space helper: $NVIDIA_GUEST_INSTALLER"

if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root on the PVE host.'
    for command_name in pveversion pct pvesh pvesm; do
        command -v "$command_name" >/dev/null || die "Missing PVE command: $command_name"
    done
    [[ $(pveversion) == pve-manager/9.* ]] || die 'This script targets Proxmox VE 9.x.'
    [[ -d /etc/pve/nodes ]] || die '/etc/pve is unavailable.'
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "CT ID $CT_ID is already in use."
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge interface is missing: $BRIDGE"
    template_path=$(pvesm path "$TEMPLATE")
    [[ -f $template_path && -r $template_path ]] || die "Template is not readable: $TEMPLATE"
    storage_ready=0
    while read -r storage_name _ status _; do
        [[ $storage_name == "$STORAGE" && $status == active ]] && storage_ready=1
    done < <(pvesm status --content rootdir 2>/dev/null || true)
    (( storage_ready )) || die "Storage is not active or does not support rootdir: $STORAGE"
fi

gpu_tool=$(cd -- "$source_dir/../.." && pwd)/tools/setup-host-gpu.sh
require_host_gpu
# Xolotl's RTX 50 engines built with CUDA 12.8 crashed on long prompts.
if [[ $XOLOTL_CUDA_ARCH != auto ]] && (( XOLOTL_CUDA_ARCH >= 120 )); then
    version_at_least "$XOLOTL_CUDA_VERSION" 13.0 ||
        die "Compute capability $XOLOTL_CUDA_ARCH (RTX 50) needs XOLOTL_CUDA_VERSION=13.0 or newer."
fi
if [[ -z $GPU_DEVICES ]]; then
    GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
    # Optional: only some driver setups create it, and nothing here needs it.
    [[ -c /dev/nvidia-uvm-tools ]] && GPU_DEVICES+=' /dev/nvidia-uvm-tools'
fi

read -r -a devices <<< "$GPU_DEVICES"
(( ${#devices[@]} >= 3 && ${#devices[@]} <= 32 )) || die 'GPU_DEVICES must list a GPU, control, and UVM device (at most 32 paths).'
declare -A seen_devices=()
have_gpu=0; have_ctl=0; have_uvm=0
for device in "${devices[@]}"; do
    [[ $device =~ ^/dev/[A-Za-z0-9_./-]+$ && $device != *'/../'* && $device != *'/./'* ]] || die "Invalid GPU device path: $device"
    [[ -z ${seen_devices[$device]:-} ]] || die "Duplicate GPU device path: $device"
    seen_devices[$device]=1
    [[ $device =~ ^/dev/nvidia[0-9]+$ ]] && have_gpu=1
    [[ $device == /dev/nvidiactl ]] && have_ctl=1
    [[ $device == /dev/nvidia-uvm ]] && have_uvm=1
    if (( ! dry_run )); then [[ -c $device ]] || die "GPU device is missing on the PVE host: $device"; fi
done
(( have_gpu && have_ctl && have_uvm )) || die 'GPU_DEVICES must include /dev/nvidiaN, /dev/nvidiactl, and /dev/nvidia-uvm.'

ostype=debian
[[ $TEMPLATE == *:vztmpl/ubuntu-* ]] && ostype=ubuntu
net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY || $IP_CIDR == dhcp ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype "$ostype"
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT"
    --description "Xolotl inference target (DeepSeek-V4.1-Flash); OpenAI API on TCP $XOLOTL_PORT")
[[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
[[ -z $SSH_PUBLIC_KEY ]] || create+=(--ssh-public-keys "$SSH_PUBLIC_KEY")
for i in "${!devices[@]}"; do create+=("--dev$i" "path=${devices[$i]},gid=$GPU_GID,mode=0660"); done

if (( ! dry_run )); then
    command -v nvidia-smi >/dev/null || die 'Missing driver command: nvidia-smi'
    host_driver=$(nvidia_lxc_host_version) || die 'Cannot determine the loaded NVIDIA driver version on this Proxmox host.'
    [[ $NVIDIA_DRIVER_VERSION == auto || $host_driver == "$NVIDIA_DRIVER_VERSION" ]] ||
        die "Host NVIDIA driver is $host_driver; expected $NVIDIA_DRIVER_VERSION."
    NVIDIA_DRIVER_VERSION=$host_driver
    version_at_least "$NVIDIA_DRIVER_VERSION" "$min_driver" ||
        die "CUDA $XOLOTL_CUDA_VERSION needs NVIDIA driver $min_driver or newer; host driver is $NVIDIA_DRIVER_VERSION."
else
    [[ $NVIDIA_DRIVER_VERSION != auto ]] || NVIDIA_DRIVER_VERSION='<host-nvidia-driver-version>'
fi

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2' ERR
(umask 022; run "${create[@]}")
# Xolotl pins tens of GiB of expert memory (XOLOTL_ARENA_GIB). systemd's LimitMEMLOCK must be
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
    online=0
    for (( attempt=0; attempt<60; attempt++ )); do
        if pct exec "$CT_ID" -- sh -c 'ip route show default | grep -q . && getent hosts github.com >/dev/null'; then
            online=1; break
        fi
        sleep 3
    done
    (( online )) || die "CT $CT_ID has no default route or DNS after 180 seconds; check network settings."
fi
run pct exec "$CT_ID" -- install -d -m 0700 /root/xolotl-target-deploy
for file in install-target.sh cuda-toolkit.sh engram-index.py; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/xolotl-target-deploy/$file" --perms 0755
done
for file in xolotl.service xolotl-weights.txt upstream-commit.txt; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/xolotl-target-deploy/$file" --perms 0644
done
run pct push "$CT_ID" "$NVIDIA_GUEST_INSTALLER" /root/xolotl-target-deploy/nvidia-guest-install.sh --perms 0755
nvidia_lxc_install_guest "$CT_ID" "$NVIDIA_DRIVER_VERSION" /root/xolotl-target-deploy/nvidia-guest-install.sh
run pct exec "$CT_ID" -- env "XOLOTL_REF=$XOLOTL_REF" "XOLOTL_COMMIT=$XOLOTL_COMMIT" \
    "XOLOTL_CUDA_VERSION=$XOLOTL_CUDA_VERSION" "XOLOTL_CUDA_ARCH=$XOLOTL_CUDA_ARCH" "XOLOTL_PORT=$XOLOTL_PORT" \
    "XOLOTL_CONTEXT=$XOLOTL_CONTEXT" "XOLOTL_ARENA_GIB=$XOLOTL_ARENA_GIB" "XOLOTL_DSPARK=$XOLOTL_DSPARK" \
    "XOLOTL_MODEL_NAME=$XOLOTL_MODEL_NAME" "XOLOTL_READY_TIMEOUT=$XOLOTL_READY_TIMEOUT" \
    bash /root/xolotl-target-deploy/install-target.sh

printf '\nXolotl target CT %s: API port %s, model %s. Read its generated key with:\n' "$CT_ID" "$XOLOTL_PORT" "$XOLOTL_MODEL_NAME"
printf '  pct exec %s -- cat /etc/xolotl-target/api-key\n' "$CT_ID"
printf 'Then on the router, set the Xolotl key and add xolotl://<CT address>:%s.\n' "$XOLOTL_PORT"
printf 'Service logs: pct exec %s -- journalctl -u xolotl -f\n' "$CT_ID"
printf 'Upgrade later: push the current install-target.sh, cuda-toolkit.sh, engram-index.py,\n'
printf '  xolotl.service and xolotl-weights.txt to /root/xolotl-target-deploy in the CT, then run it there with --upgrade.\n'
