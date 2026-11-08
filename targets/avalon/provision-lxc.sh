#!/usr/bin/env bash
# Run on the Proxmox host with the GPU, never inside the router CT.
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

Creates an unprivileged Proxmox VE 9 LXC, passes one GPU through, clones
https://github.com/freriadoc/Avalon.git inside the CT, builds its llama-server
with ROCm 7.2.4 (AMD) or a CUDA toolkit (NVIDIA; no driver), downloads the
pinned Qwen3.8-Flash-Next IQ3_KS GGUF and MTP draft head (about 90 GiB, see
avalon-weights.txt) and starts its OpenAI-compatible API as a systemd service.
A random API key is generated inside the CT. The download takes hours on a
slow line. --dry-run validates settings and prints the PVE command plan.

Required: TEMPLATE (a downloaded Ubuntu 24.04 or 22.04
amd64 template; with AVALON_BACKEND=cuda also Ubuntu 26.04 or Debian 12/13),
STORAGE (rootdir storage, preferably NVMe: experts that miss the RAM are read
from it), IP_CIDR (a.b.c.d/nn or dhcp). GATEWAY is required for a static
address. The host CPU needs AVX2.

GPU: an AMD Radeon RX 7000 / PRO W7000 card (RDNA 3, gfx1100/1101/1102;
upstream's reference is an RX 7900 XT) on the in-kernel amdgpu driver, or an
NVIDIA card of compute capability 7.5 or newer; 16 GB of VRAM or more (20 GB
for the full 256k context). AVALON_BACKEND=auto picks rocm when GPU_DEVICES
names /dev/kfd or a render node, or when the host has an RDNA 3 card on
amdgpu, else cuda when an NVIDIA driver is loaded. On a host without a GPU
driver, run tools/setup-host-gpu.sh first (the router installer runs it for
every selected GPU target).

Optional: CT_HOSTNAME=avalon-target, BRIDGE=vmbr0, CORES=8, MEMORY_MB=65536,
          SWAP_MB=0, ROOTFS_GB=160, ONBOOT=1, NAMESERVER, VLAN_TAG,
          SSH_PUBLIC_KEY=<readable file>, AVALON_BACKEND=auto|rocm|cuda,
          GPU_DEVICES='/dev/kfd /dev/dri/renderD128' (ROCm) or
                      '/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm' (CUDA),
          GPU_GID=44 (the CT group given the GPU nodes; 44 is "video"),
          NVIDIA_DRIVER_VERSION=auto (CUDA: loaded host driver; or an exact-version check),
          NVIDIA_GUEST_INSTALLER=<host path to matching LXC helper>,
          AVALON_REF=<branch or tag>, AVALON_COMMIT=<full SHA-1 pin>
          (default: tested commit in upstream-commit.txt),
          AVALON_ROCM_VERSION=7.2.4, AVALON_GPU_TARGET=auto,
          AVALON_CUDA_VERSION=12.9, AVALON_CUDA_ARCH=auto, AVALON_PORT=8080,
          AVALON_CONTEXT=65536 (auto: 262144 with 19 GB of VRAM or more, else 65536),
          AVALON_MTP=true, AVALON_MODEL_NAME=qwen3.8-flash-next-avalon,
          AVALON_READY_TIMEOUT=1800.

The model (~90 GiB) is memory-mapped: what does not fit in RAM is read again
from the disk. Upstream measured it with 32 GB of RAM (64 GB: within 5% of
96 GB); MEMORY_MB must be at least 32768.

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

# The host's sysfs and /dev (overridable for tests).
HOST_SYSFS=${HOST_SYSFS:-/sys}
HOST_DEV=${HOST_DEV:-/dev}
# rdna3_render_nodes: "/dev/dri/renderD<n> <gfx>" for each RDNA 3 card bound to
# amdgpu, when the host has /dev/kfd.
rdna3_render_nodes() {
    local sys name device driver gfx
    [[ -e $HOST_DEV/kfd ]] || return 0
    for sys in "$HOST_SYSFS"/class/drm/renderD*; do
        [[ -e $sys ]] || continue
        name=${sys##*/}
        [[ $(cat "$sys/device/vendor" 2>/dev/null) == 0x1002 ]] || continue
        driver=$(readlink "$sys/device/driver" 2>/dev/null || true)
        [[ ${driver##*/} == amdgpu ]] || continue
        device=$(cat "$sys/device/device" 2>/dev/null || true)
        device=${device#0x}
        case ${device:0:3} in
            744|745) gfx=gfx1100 ;;
            746|747) gfx=gfx1101 ;;
            748|749) gfx=gfx1102 ;;
            *) continue ;;
        esac
        [[ -e $HOST_DEV/dri/$name ]] || continue
        printf '/dev/dri/%s %s\n' "$name" "$gfx"
    done
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
CT_HOSTNAME=${CT_HOSTNAME:-avalon-target}
BRIDGE=${BRIDGE:-vmbr0}
CORES=${CORES:-8}
MEMORY_MB=${MEMORY_MB:-65536}
SWAP_MB=${SWAP_MB:-0}
ROOTFS_GB=${ROOTFS_GB:-160}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
GPU_DEVICES=${GPU_DEVICES:-}
# The Avalon service runs as an unprivileged account that joins this group, so
# the nodes must not be root's group inside the CT.
GPU_GID=${GPU_GID:-44}
NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION:-auto}
AVALON_BACKEND=${AVALON_BACKEND:-auto}
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/upstream-commit.txt ]] || die "Missing deployment file: $source_dir/upstream-commit.txt"
default_commit=$(< "$source_dir/upstream-commit.txt")
[[ $default_commit =~ ^[0-9a-f]{40}$ ]] || die 'Invalid upstream-commit.txt.'
if [[ -z ${AVALON_REF:-} && -z ${AVALON_COMMIT:-} ]]; then AVALON_COMMIT=$default_commit; fi
AVALON_REF=${AVALON_REF:-main}
AVALON_COMMIT=${AVALON_COMMIT:-}
AVALON_ROCM_VERSION=${AVALON_ROCM_VERSION:-7.2.4}
AVALON_GPU_TARGET=${AVALON_GPU_TARGET:-auto}
AVALON_CUDA_VERSION=${AVALON_CUDA_VERSION:-12.9}
AVALON_CUDA_ARCH=${AVALON_CUDA_ARCH:-auto}
AVALON_PORT=${AVALON_PORT:-8080}
AVALON_CONTEXT=${AVALON_CONTEXT:-65536}
AVALON_MTP=${AVALON_MTP:-true}
AVALON_MODEL_NAME=${AVALON_MODEL_NAME:-qwen3.8-flash-next-avalon}
AVALON_READY_TIMEOUT=${AVALON_READY_TIMEOUT:-1800}
gpu_tool=$(cd -- "$source_dir/../.." && pwd)/tools/setup-host-gpu.sh
noted_no_gpu=0

# The backend: from GPU_DEVICES when given, else from the host's GPUs.
[[ $AVALON_BACKEND =~ ^(auto|rocm|cuda)$ ]] || die 'AVALON_BACKEND must be auto, rocm or cuda.'
if [[ $AVALON_BACKEND == auto ]]; then
    if [[ " $GPU_DEVICES " == *' /dev/nvidia'* ]]; then AVALON_BACKEND=cuda
    elif [[ " $GPU_DEVICES " == *' /dev/kfd '* || " $GPU_DEVICES " == *' /dev/dri/'* ]]; then AVALON_BACKEND=rocm
    elif [[ -n $(rdna3_render_nodes) ]]; then AVALON_BACKEND=rocm
    elif host_driver_loaded; then AVALON_BACKEND=cuda
    elif (( dry_run )); then
        printf 'Note: no RDNA 3 card on amdgpu and no NVIDIA driver on this host; planning for rocm. A real run stops here until bash %s sets the GPU up.\n' "$gpu_tool" >&2
        AVALON_BACKEND=rocm noted_no_gpu=1
    else
        die "No usable GPU on this host: no AMD Radeon RX 7000 (RDNA 3) card on amdgpu with /dev/kfd, and no NVIDIA driver listing a GPU. Run: bash $gpu_tool --vendors amd,nvidia, then run this again. The router installer does this for every GPU target."
    fi
fi

if [[ $AVALON_BACKEND == rocm ]]; then
    template_re='^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/ubuntu-(22\.04|24\.04)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
    template_names='Ubuntu 24.04 or 22.04 (AMD supports ROCm on Radeon cards on these only)'
else
    template_re='^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04|26\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
    template_names='Ubuntu 22.04/24.04/26.04 or Debian 12/13'
fi

# --- Questions: the container, one section ----------------------------------
valid_template_volume() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/[A-Za-z0-9._-]+$ ]]; }
valid_storage_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
pve_ask_new_ct Avalon
[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'CT_ID must be an unused numeric ID of 100 or more.'
if pve_interactive && (( ! dry_run )); then _pve_heading; fi
pve_select_template TEMPLATE "$template_re"
positive_int ROOTFS_GB "$ROOTFS_GB"
pve_select_storage STORAGE rootdir "$ROOTFS_GB"
pve_suggest TEMPLATE 'Template (storage:vztmpl/...)' '' valid_template_volume 'Use a downloaded LXC template volume (storage:vztmpl/...).'
pve_suggest STORAGE 'Root disk storage' '' valid_storage_id
pve_ask_network Avalon dhcp
[[ $TEMPLATE =~ $template_re ]] ||
    die "TEMPLATE must be a downloaded $template_names amd64 LXC template for AVALON_BACKEND=$AVALON_BACKEND."
[[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'STORAGE must be a Proxmox rootdir storage ID.'
valid_ip_cidr "$IP_CIDR" || die 'IP_CIDR must be dhcp or a valid IPv4 address/CIDR.'
if [[ $IP_CIDR != dhcp ]]; then ipv4 "$GATEWAY" || die 'GATEWAY must be a valid IPv4 address for a static IP.'; fi
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
for name in CORES MEMORY_MB ROOTFS_GB; do positive_int "$name" "${!name}"; done
(( MEMORY_MB >= 32768 )) || die 'MEMORY_MB must be at least 32768 for Avalon (upstream measured it with 32 GB of RAM).'
# ~90 GiB of weights, ROCm (~8 GB) or the CUDA toolkit, the build, its
# rollback snapshot and the OS.
(( ROOTFS_GB >= 130 )) || die 'ROOTFS_GB must be at least 130 for the Avalon weights (about 90 GiB), the GPU toolkit and the build.'
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY ]] || die 'SSH_PUBLIC_KEY must be a readable file.'
[[ $GPU_GID =~ ^[1-9][0-9]{0,4}$ ]] && (( GPU_GID <= 65535 )) || die 'GPU_GID must be a non-root group ID (1..65535).'
[[ $NVIDIA_DRIVER_VERSION == auto || $NVIDIA_DRIVER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid NVIDIA_DRIVER_VERSION.'
[[ $AVALON_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $AVALON_REF != HEAD && $AVALON_REF != *..* ]] || die 'AVALON_REF must be a branch or a tag name.'
[[ -z $AVALON_COMMIT || $AVALON_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'AVALON_COMMIT must be a full 40-digit SHA-1.'
[[ $AVALON_ROCM_VERSION =~ ^7\.[0-9]+(\.[0-9]+)?$ ]] || die 'AVALON_ROCM_VERSION must be a ROCm 7.x release such as 7.2.4.'
[[ $AVALON_GPU_TARGET =~ ^(auto|gfx110[012])$ ]] || die 'AVALON_GPU_TARGET must be auto, gfx1100, gfx1101 or gfx1102.'
[[ $AVALON_CUDA_VERSION =~ ^(12\.([4-9])|1[3-9]\.[0-9]+)$ ]] || die 'AVALON_CUDA_VERSION must be 12.4 or newer.'
[[ $AVALON_CUDA_ARCH == auto || ( $AVALON_CUDA_ARCH =~ ^[1-9][0-9]{1,2}$ && $AVALON_CUDA_ARCH -ge 75 ) ]] ||
    die 'AVALON_CUDA_ARCH must be auto or a compute capability of 75 or newer (e.g. 86, 89, 120).'
[[ $AVALON_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( AVALON_PORT <= 65535 )) || die 'AVALON_PORT must be 1..65535.'
[[ $AVALON_CONTEXT == auto || ( $AVALON_CONTEXT =~ ^[1-9][0-9]{3,5}$ && $AVALON_CONTEXT -ge 4096 && $AVALON_CONTEXT -le 262144 ) ]] ||
    die 'AVALON_CONTEXT must be auto or 4096..262144 tokens.'
[[ $AVALON_MTP =~ ^(true|false)$ ]] || die 'AVALON_MTP must be true or false.'
[[ $AVALON_MODEL_NAME =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die 'Invalid AVALON_MODEL_NAME (lowercase letters, digits, ., _ and -).'
[[ $AVALON_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'AVALON_READY_TIMEOUT must be a positive number of seconds.'
if [[ $AVALON_CUDA_ARCH != auto ]] && (( AVALON_CUDA_ARCH >= 120 )); then
    version_at_least "$AVALON_CUDA_VERSION" 12.8 ||
        die "Compute capability $AVALON_CUDA_ARCH (RTX 50) needs AVALON_CUDA_VERSION=12.8 or newer."
fi
# The CT's CUDA runtime needs a host driver at least this new.
if version_at_least "$AVALON_CUDA_VERSION" 13.0; then min_driver=580
elif version_at_least "$AVALON_CUDA_VERSION" 12.8; then min_driver=570
else min_driver=550; fi
if [[ $AVALON_BACKEND == cuda && $NVIDIA_DRIVER_VERSION != auto ]]; then
    version_at_least "$NVIDIA_DRIVER_VERSION" "$min_driver" ||
        die "CUDA $AVALON_CUDA_VERSION needs NVIDIA driver $min_driver or newer; NVIDIA_DRIVER_VERSION is $NVIDIA_DRIVER_VERSION."
fi

for file in install-target.sh avalon.service rocm-toolkit.sh cuda-toolkit.sh avalon-weights.txt upstream-commit.txt; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
# The template decides which repository the CT installs its toolkit from;
# refuse a combination that repository cannot install before any CT is created.
[[ $TEMPLATE =~ :vztmpl/(ubuntu|debian)-([0-9]+)(\.([0-9]+))?- ]]
template_dist=${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[4]}
if [[ $AVALON_BACKEND == rocm ]]; then
    ROCM_DIST=$template_dist ROCM_VERSION=$AVALON_ROCM_VERSION bash "$source_dir/rocm-toolkit.sh" --check-repo ||
        die "ROCm $AVALON_ROCM_VERSION cannot be installed in a $template_dist CT (see above)."
else
    CUDA_DIST=$template_dist CUDA_VERSION=$AVALON_CUDA_VERSION bash "$source_dir/cuda-toolkit.sh" --check-repo ||
        die "AVALON_CUDA_VERSION=$AVALON_CUDA_VERSION cannot be installed in a $template_dist CT (see above)."
    NVIDIA_GUEST_INSTALLER=${NVIDIA_GUEST_INSTALLER:-$source_dir/../../tools/install-nvidia-driver.sh}
    [[ -r $NVIDIA_GUEST_INSTALLER ]] || die "Missing NVIDIA LXC user-space helper: $NVIDIA_GUEST_INSTALLER"
fi

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
    # The experts that are not on the GPU are computed with AVX2 kernels.
    grep -qw avx2 /proc/cpuinfo || die 'This host CPU has no AVX2; Avalon computes the experts that are not on the GPU with AVX2 kernels.'
fi

if [[ $AVALON_BACKEND == rocm ]]; then
    if [[ -z $GPU_DEVICES ]]; then
        mapfile -t cards < <(rdna3_render_nodes)
        if (( ${#cards[@]} == 1 )); then
            GPU_DEVICES="/dev/kfd ${cards[0]%% *}"
        elif (( ${#cards[@]} > 1 )); then
            die "Several RDNA 3 cards are on this host (${cards[*]}); set GPU_DEVICES='/dev/kfd /dev/dri/renderD<n>' for the one Avalon uses."
        elif (( dry_run )); then
            (( noted_no_gpu )) ||
                printf 'Note: no RDNA 3 card on amdgpu on this host; a real run stops here until bash %s --vendors amd sets it up.\n' "$gpu_tool" >&2
            GPU_DEVICES='/dev/kfd /dev/dri/renderD128'
        else
            die "No AMD Radeon RX 7000 (RDNA 3) card on amdgpu with /dev/kfd on this host. Run: bash $gpu_tool --vendors amd (it sets the driver up), then run this again."
        fi
    fi
else
    if ! host_driver_loaded; then
        (( dry_run )) ||
            die "No NVIDIA driver is loaded on this host (nvidia-smi lists no GPU). Run: bash $gpu_tool (it asks for the GPU generation and installs the driver), then run this again. The router installer does this for every GPU target."
        printf 'Note: no NVIDIA driver is loaded on this host; a real run stops here until bash %s installs it.\n' "$gpu_tool" >&2
    fi
    if [[ -z $GPU_DEVICES ]]; then
        GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
        # Optional: only some driver setups create it, and nothing here needs it.
        [[ -c /dev/nvidia-uvm-tools ]] && GPU_DEVICES+=' /dev/nvidia-uvm-tools'
    fi
fi

read -r -a devices <<< "$GPU_DEVICES"
(( ${#devices[@]} >= 2 && ${#devices[@]} <= 32 )) || die 'GPU_DEVICES must list the GPU and its control devices (at most 32 paths).'
declare -A seen_devices=()
have_gpu=0; have_ctl=0; have_uvm=0; have_kfd=0; have_render=0
for device in "${devices[@]}"; do
    [[ $device =~ ^/dev/[A-Za-z0-9_./-]+$ && $device != *'/../'* && $device != *'/./'* ]] || die "Invalid GPU device path: $device"
    [[ -z ${seen_devices[$device]:-} ]] || die "Duplicate GPU device path: $device"
    seen_devices[$device]=1
    [[ $device =~ ^/dev/nvidia[0-9]+$ ]] && have_gpu=1
    [[ $device == /dev/nvidiactl ]] && have_ctl=1
    [[ $device == /dev/nvidia-uvm ]] && have_uvm=1
    [[ $device == /dev/kfd ]] && have_kfd=1
    [[ $device =~ ^/dev/dri/renderD[0-9]+$ ]] && have_render=$(( have_render + 1 ))
    if (( ! dry_run )); then [[ -c $device ]] || die "GPU device is missing on the PVE host: $device"; fi
done
if [[ $AVALON_BACKEND == rocm ]]; then
    (( have_kfd && have_render >= 1 && ! have_gpu )) ||
        die 'GPU_DEVICES must include /dev/kfd and the card'\''s /dev/dri/renderD<n> for AVALON_BACKEND=rocm (and no NVIDIA nodes).'
else
    (( have_gpu && have_ctl && have_uvm && ! have_kfd )) ||
        die 'GPU_DEVICES must include /dev/nvidiaN, /dev/nvidiactl, and /dev/nvidia-uvm for AVALON_BACKEND=cuda.'
fi

ostype=debian
[[ $TEMPLATE == *:vztmpl/ubuntu-* ]] && ostype=ubuntu
net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY || $IP_CIDR == dhcp ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype "$ostype"
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT" --tags 'ai;ai-model;osr-target;avalon'
    --description "Avalon inference target (Qwen3.8-Flash-Next, $AVALON_BACKEND); OpenAI API on TCP $AVALON_PORT")
[[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
[[ -z $SSH_PUBLIC_KEY ]] || create+=(--ssh-public-keys "$SSH_PUBLIC_KEY")
for i in "${!devices[@]}"; do create+=("--dev$i" "path=${devices[$i]},gid=$GPU_GID,mode=0660"); done

if [[ $AVALON_BACKEND == cuda ]]; then
    if (( ! dry_run )); then
        command -v nvidia-smi >/dev/null || die 'Missing driver command: nvidia-smi'
        host_driver=$(nvidia_lxc_host_version) || die 'Cannot determine the loaded NVIDIA driver version on this Proxmox host.'
        [[ $NVIDIA_DRIVER_VERSION == auto || $host_driver == "$NVIDIA_DRIVER_VERSION" ]] ||
            die "Host NVIDIA driver is $host_driver; expected $NVIDIA_DRIVER_VERSION."
        NVIDIA_DRIVER_VERSION=$host_driver
        version_at_least "$NVIDIA_DRIVER_VERSION" "$min_driver" ||
            die "CUDA $AVALON_CUDA_VERSION needs NVIDIA driver $min_driver or newer; host driver is $NVIDIA_DRIVER_VERSION."
    else
        [[ $NVIDIA_DRIVER_VERSION != auto ]] || NVIDIA_DRIVER_VERSION='<host-nvidia-driver-version>'
    fi
fi

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2' ERR
pve_summary "Avalon: create"
pve_row 'Avalon CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB} GiB on $STORAGE"
pve_row 'Template' "$TEMPLATE"
pve_row 'Network' "$IP_CIDR${GATEWAY:+ via $GATEWAY} on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
pve_row 'Model' "${AVALON_MODEL_NAME} (context ${AVALON_CONTEXT}, port ${AVALON_PORT})"
pve_confirm "Create Avalon CT $CT_ID?"
(umask 022; run "${create[@]}")
# The expert cache pins host memory for its PCIe copies; systemd's
# LimitMEMLOCK must be allowed by the outer LXC hard limit too.
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
run pct exec "$CT_ID" -- install -d -m 0700 /root/avalon-target-deploy
for file in install-target.sh rocm-toolkit.sh cuda-toolkit.sh; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/avalon-target-deploy/$file" --perms 0755
done
for file in avalon.service avalon-weights.txt upstream-commit.txt; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/avalon-target-deploy/$file" --perms 0644
done
if [[ $AVALON_BACKEND == cuda ]]; then
    run pct push "$CT_ID" "$NVIDIA_GUEST_INSTALLER" /root/avalon-target-deploy/nvidia-guest-install.sh --perms 0755
    nvidia_lxc_install_guest "$CT_ID" "$NVIDIA_DRIVER_VERSION" /root/avalon-target-deploy/nvidia-guest-install.sh
fi
run pct exec "$CT_ID" -- env "AVALON_REF=$AVALON_REF" "AVALON_COMMIT=$AVALON_COMMIT" "AVALON_BACKEND=$AVALON_BACKEND" \
    "AVALON_ROCM_VERSION=$AVALON_ROCM_VERSION" "AVALON_GPU_TARGET=$AVALON_GPU_TARGET" \
    "AVALON_CUDA_VERSION=$AVALON_CUDA_VERSION" "AVALON_CUDA_ARCH=$AVALON_CUDA_ARCH" "AVALON_PORT=$AVALON_PORT" \
    "AVALON_CONTEXT=$AVALON_CONTEXT" "AVALON_MTP=$AVALON_MTP" "AVALON_MODEL_NAME=$AVALON_MODEL_NAME" \
    "AVALON_READY_TIMEOUT=$AVALON_READY_TIMEOUT" \
    bash /root/avalon-target-deploy/install-target.sh

printf '\nAvalon target CT %s: API port %s, model %s (%s). Read its generated key with:\n' "$CT_ID" "$AVALON_PORT" "$AVALON_MODEL_NAME" "$AVALON_BACKEND"
printf '  pct exec %s -- cat /etc/avalon-target/api-key\n' "$CT_ID"
printf 'Then on the router, set the Avalon key and add avalon://<CT address>:%s.\n' "$AVALON_PORT"
printf 'Service logs: pct exec %s -- journalctl -u avalon -f\n' "$CT_ID"
printf 'Upgrade later: push the current install-target.sh, rocm-toolkit.sh, cuda-toolkit.sh,\n'
printf '  avalon.service, avalon-weights.txt and upstream-commit.txt to /root/avalon-target-deploy in the CT, then run it there with --upgrade.\n'
