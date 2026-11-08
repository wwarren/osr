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

Creates an unprivileged Proxmox VE 9 LXC, passes one NVIDIA GPU through (or
none, for Kindi's CPU engine), clones https://github.com/ahtx/kindi.git inside
the CT, installs the CUDA 10.2 toolkit (NVIDIA's runfile, toolkit only; no
driver), a standalone Python 3.9 and Kindi's hash-locked venv, downloads the
pinned GGUF of the model the card holds (0.4 to 13 GB, see kindi-weights.txt),
converts and verifies it, and starts Kindi's OpenAI-compatible API as a systemd
service. A random API key is generated inside the CT. --dry-run validates
settings and prints the PVE command plan.

Required: TEMPLATE (a downloaded Debian 12/13 or Ubuntu
22.04/24.04 amd64 template), STORAGE (rootdir storage), IP_CIDR (a.b.c.d/nn or
dhcp). GATEWAY is required for a static address.

GPU: any NVIDIA card of compute capability 3.0 (Kepler) or newer that the
host's driver lists. Kindi 0.4.0 runs the Ternary-Bonsai-2 2B on a 1 GB Quadro
K420 up to the 27B on an 8 GB card or larger. Kepler cards need the host on the
NVIDIA 470 driver; Maxwell to Volta need branch 580 or older; CUDA 10.2 needs
440.33 or newer. KINDI_BACKEND=auto picks cuda when GPU_DEVICES names an NVIDIA
node or the host's NVIDIA driver lists a GPU, else cpu (Kindi's CPU engine:
the 2B, 4B or 9B; AVX2 needed).

Optional: CT_HOSTNAME=kindi-target, BRIDGE=vmbr0, CORES=4, MEMORY_MB=16384,
          SWAP_MB=0, ROOTFS_GB=64, ONBOOT=1, NAMESERVER, VLAN_TAG,
          SSH_PUBLIC_KEY=<readable file>, KINDI_BACKEND=auto|cuda|cpu,
          GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm',
          GPU_GID=44 (the CT group given the GPU nodes; 44 is "video"),
          NVIDIA_DRIVER_VERSION=auto (loaded host driver; or an exact-version check),
          NVIDIA_GUEST_INSTALLER=<host path to matching LXC helper>,
          KINDI_REF=<branch or tag>, KINDI_COMMIT=<full SHA-1 pin>
          (default: tested commit in upstream-commit.txt),
          KINDI_MODEL=auto|bonsai-2b|bonsai-4b|bonsai-9b|bonsai-27b|nanbeige-33b,
          KINDI_PROFILE=auto, KINDI_PORT=8093,
          KINDI_CONTEXT=auto (the profile's; Kindi fits it to the free card memory),
          KINDI_HEAD=exact|fast, KINDI_SPEC=auto|off, KINDI_THREADS=auto,
          KINDI_MODEL_NAME=auto, KINDI_VERIFY=true, KINDI_PYTHON_VERSION=3.9.25,
          KINDI_READY_TIMEOUT=1800.

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
CT_HOSTNAME=${CT_HOSTNAME:-kindi-target}
BRIDGE=${BRIDGE:-vmbr0}
CORES=${CORES:-4}
MEMORY_MB=${MEMORY_MB:-16384}
SWAP_MB=${SWAP_MB:-0}
ROOTFS_GB=${ROOTFS_GB:-64}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
GPU_DEVICES=${GPU_DEVICES:-}
# The Kindi service runs as an unprivileged account that joins this group, so
# the nodes must not be root's group inside the CT.
GPU_GID=${GPU_GID:-44}
NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION:-auto}
KINDI_BACKEND=${KINDI_BACKEND:-auto}
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/upstream-commit.txt ]] || die "Missing deployment file: $source_dir/upstream-commit.txt"
default_commit=$(< "$source_dir/upstream-commit.txt")
[[ $default_commit =~ ^[0-9a-f]{40}$ ]] || die 'Invalid upstream-commit.txt.'
if [[ -z ${KINDI_REF:-} && -z ${KINDI_COMMIT:-} ]]; then KINDI_COMMIT=$default_commit; fi
KINDI_REF=${KINDI_REF:-main}
KINDI_COMMIT=${KINDI_COMMIT:-}
KINDI_MODEL=${KINDI_MODEL:-auto}
KINDI_PROFILE=${KINDI_PROFILE:-auto}
KINDI_PORT=${KINDI_PORT:-8093}
KINDI_CONTEXT=${KINDI_CONTEXT:-auto}
KINDI_HEAD=${KINDI_HEAD:-exact}
KINDI_SPEC=${KINDI_SPEC:-auto}
KINDI_THREADS=${KINDI_THREADS:-auto}
KINDI_MODEL_NAME=${KINDI_MODEL_NAME:-auto}
KINDI_VERIFY=${KINDI_VERIFY:-true}
KINDI_PYTHON_VERSION=${KINDI_PYTHON_VERSION:-3.9.25}
KINDI_READY_TIMEOUT=${KINDI_READY_TIMEOUT:-1800}
gpu_tool=$(cd -- "$source_dir/../.." && pwd)/tools/setup-host-gpu.sh

# The backend: from GPU_DEVICES when given, else from the host's driver.
[[ $KINDI_BACKEND =~ ^(auto|cuda|cpu)$ ]] || die 'KINDI_BACKEND must be auto, cuda or cpu.'
if [[ $KINDI_BACKEND == auto ]]; then
    if [[ " $GPU_DEVICES " == *' /dev/nvidia'* ]]; then KINDI_BACKEND=cuda
    elif [[ -z $GPU_DEVICES ]] && host_driver_loaded; then KINDI_BACKEND=cuda
    else
        printf 'Note: no NVIDIA driver lists a GPU on this host; Kindi runs its CPU engine (KINDI_BACKEND=cpu). To use a GPU, run bash %s first.\n' "$gpu_tool" >&2
        KINDI_BACKEND=cpu
    fi
fi
[[ $KINDI_BACKEND == cuda || -z $GPU_DEVICES ]] || die 'GPU_DEVICES is for KINDI_BACKEND=cuda; the CPU engine gets no GPU.'

template_re='^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
template_names='Debian 12/13 or Ubuntu 22.04/24.04'

# --- Questions: the container, one section ----------------------------------
valid_template_volume() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/[A-Za-z0-9._-]+$ ]]; }
valid_storage_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
pve_ask_new_ct Kindi
[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'CT_ID must be an unused numeric ID of 100 or more.'
if pve_interactive && (( ! dry_run )); then _pve_heading; fi
pve_select_template TEMPLATE "$template_re"
positive_int ROOTFS_GB "$ROOTFS_GB"
pve_select_storage STORAGE rootdir "$ROOTFS_GB"
pve_suggest TEMPLATE 'Template (storage:vztmpl/...)' '' valid_template_volume 'Use a downloaded LXC template volume (storage:vztmpl/...).'
pve_suggest STORAGE 'Root disk storage' '' valid_storage_id
pve_ask_network Kindi dhcp
[[ $TEMPLATE =~ $template_re ]] || die "TEMPLATE must be a downloaded $template_names amd64 LXC template."
[[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'STORAGE must be a Proxmox rootdir storage ID.'
valid_ip_cidr "$IP_CIDR" || die 'IP_CIDR must be dhcp or a valid IPv4 address/CIDR.'
if [[ $IP_CIDR != dhcp ]]; then ipv4 "$GATEWAY" || die 'GATEWAY must be a valid IPv4 address for a static IP.'; fi
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
for name in CORES MEMORY_MB ROOTFS_GB; do positive_int "$name" "${!name}"; done
# Kindi's smallest setup, the 2B, needs 4 GB of RAM; the 27B's first start
# about 14 GB (install-target.sh checks the model's own need).
(( MEMORY_MB >= 4096 )) || die 'MEMORY_MB must be at least 4096 for Kindi (its 2B needs 4 GB of RAM).'
# The CUDA 10.2 toolkit (~3 GB, and its 2.6 GB runfile while it installs),
# the venv, the model with its pack, the rollback snapshot and the OS.
if [[ $KINDI_BACKEND == cuda ]]; then
    (( ROOTFS_GB >= 32 )) || die 'ROOTFS_GB must be at least 32 for the CUDA 10.2 toolkit, the venv and a model with its pack.'
else
    (( ROOTFS_GB >= 16 )) || die 'ROOTFS_GB must be at least 16 for the venv and a model with its pack.'
fi
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY ]] || die 'SSH_PUBLIC_KEY must be a readable file.'
[[ $GPU_GID =~ ^[1-9][0-9]{0,4}$ ]] && (( GPU_GID <= 65535 )) || die 'GPU_GID must be a non-root group ID (1..65535).'
[[ $NVIDIA_DRIVER_VERSION == auto || $NVIDIA_DRIVER_VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die 'Invalid NVIDIA_DRIVER_VERSION.'
[[ $KINDI_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $KINDI_REF != HEAD && $KINDI_REF != *..* ]] || die 'KINDI_REF must be a branch or a tag name.'
[[ -z $KINDI_COMMIT || $KINDI_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'KINDI_COMMIT must be a full 40-digit SHA-1.'
[[ $KINDI_MODEL =~ ^(auto|bonsai-(2b|4b|9b|27b)|nanbeige-33b)$ ]] ||
    die 'KINDI_MODEL must be auto, bonsai-2b, bonsai-4b, bonsai-9b, bonsai-27b or nanbeige-33b.'
[[ $KINDI_PROFILE =~ ^(auto|tc|pascal8|p100|kepler|maxwell|nanbeige|cpu)$ ]] ||
    die 'KINDI_PROFILE must be auto, tc, pascal8, p100, kepler, maxwell, nanbeige or cpu.'
if [[ $KINDI_BACKEND == cpu ]]; then
    [[ $KINDI_MODEL =~ ^(auto|bonsai-(2b|4b|9b))$ ]] ||
        die "Kindi's CPU engine runs bonsai-2b, bonsai-4b and bonsai-9b, not $KINDI_MODEL."
    [[ $KINDI_PROFILE == auto || $KINDI_PROFILE == cpu ]] || die 'KINDI_BACKEND=cpu runs the cpu profile only.'
else
    [[ $KINDI_PROFILE != cpu ]] || die 'The cpu profile needs KINDI_BACKEND=cpu.'
    [[ $KINDI_THREADS == auto ]] || die 'KINDI_THREADS is for the CPU engine (KINDI_BACKEND=cpu).'
fi
[[ $KINDI_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( KINDI_PORT <= 65535 )) || die 'KINDI_PORT must be 1..65535.'
[[ $KINDI_CONTEXT == auto || ( $KINDI_CONTEXT =~ ^[1-9][0-9]{3,5}$ && $KINDI_CONTEXT -ge 1024 && $KINDI_CONTEXT -le 262144 ) ]] ||
    die 'KINDI_CONTEXT must be auto or 1024..262144 tokens.'
[[ $KINDI_HEAD =~ ^(exact|fast)$ ]] || die 'KINDI_HEAD must be exact or fast.'
[[ $KINDI_SPEC =~ ^(auto|off)$ ]] || die 'KINDI_SPEC must be auto or off.'
[[ $KINDI_THREADS == auto || ( $KINDI_THREADS =~ ^[1-9][0-9]{0,2}$ && $KINDI_THREADS -le 512 ) ]] ||
    die 'KINDI_THREADS must be auto or 1..512.'
[[ $KINDI_MODEL_NAME == auto || $KINDI_MODEL_NAME =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] ||
    die 'Invalid KINDI_MODEL_NAME (lowercase letters, digits, ., _ and -).'
[[ $KINDI_VERIFY =~ ^(true|false)$ ]] || die 'KINDI_VERIFY must be true or false.'
[[ $KINDI_PYTHON_VERSION =~ ^3\.9\.[0-9]{1,2}$ ]] || die 'KINDI_PYTHON_VERSION must be a Python 3.9 release, e.g. 3.9.25.'
[[ $KINDI_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'KINDI_READY_TIMEOUT must be a positive number of seconds.'
# CUDA 10.2's runtime needs at least this driver; branch 470 is the last with Kepler.
min_driver=440.33
if [[ $KINDI_BACKEND == cuda && $NVIDIA_DRIVER_VERSION != auto ]]; then
    version_at_least "$NVIDIA_DRIVER_VERSION" "$min_driver" ||
        die "CUDA 10.2 needs NVIDIA driver $min_driver or newer; NVIDIA_DRIVER_VERSION is $NVIDIA_DRIVER_VERSION."
fi

deploy_files=(install-target.sh cuda-toolkit.sh kindi.service kindi-weights.txt upstream-commit.txt
    requirements-cpu.lock requirements-cuda.lock uv.lock)
for file in "${deploy_files[@]}"; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
# The template decides whether the CT can run the CUDA 10.2 runfile; refuse
# a combination it cannot before any CT is created.
[[ $TEMPLATE =~ :vztmpl/(ubuntu|debian)-([0-9]+)(\.([0-9]+))?- ]]
template_dist=${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[4]}
if [[ $KINDI_BACKEND == cuda ]]; then
    CUDA_DIST=$template_dist bash "$source_dir/cuda-toolkit.sh" --check-repo ||
        die "The CUDA 10.2 toolkit cannot be installed in a $template_dist CT (see above)."
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
    # The CPU engine's kernels are AVX2.
    [[ $KINDI_BACKEND != cpu ]] || grep -qw avx2 /proc/cpuinfo ||
        die "This host CPU has no AVX2; Kindi's CPU engine needs it."
fi

devices=()
if [[ $KINDI_BACKEND == cuda ]]; then
    if ! host_driver_loaded; then
        (( dry_run )) ||
            die "No NVIDIA driver is loaded on this host (nvidia-smi lists no GPU). Run: bash $gpu_tool (it asks for the GPU generation and installs the driver), then run this again; or use KINDI_BACKEND=cpu. Kepler cards need the NVIDIA 470 driver, installed by hand."
        printf 'Note: no NVIDIA driver is loaded on this host; a real run stops here until bash %s installs it.\n' "$gpu_tool" >&2
    fi
    if [[ -z $GPU_DEVICES ]]; then
        GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
        # Optional: only some driver setups create it, and nothing here needs it.
        [[ -c /dev/nvidia-uvm-tools ]] && GPU_DEVICES+=' /dev/nvidia-uvm-tools'
    fi
    read -r -a devices <<< "$GPU_DEVICES"
    (( ${#devices[@]} >= 3 && ${#devices[@]} <= 32 )) || die 'GPU_DEVICES must list the GPU and its control devices (at most 32 paths).'
    declare -A seen_devices=()
    have_gpu=0; have_ctl=0; have_uvm=0
    for device in "${devices[@]}"; do
        [[ $device =~ ^/dev/[A-Za-z0-9_./-]+$ && $device != *'/../'* && $device != *'/./'* ]] || die "Invalid GPU device path: $device"
        [[ -z ${seen_devices[$device]:-} ]] || die "Duplicate GPU device path: $device"
        seen_devices[$device]=1
        [[ $device =~ ^/dev/nvidia[0-9]+$ ]] && have_gpu=$(( have_gpu + 1 ))
        [[ $device == /dev/nvidiactl ]] && have_ctl=1
        [[ $device == /dev/nvidia-uvm ]] && have_uvm=1
        if (( ! dry_run )); then [[ -c $device ]] || die "GPU device is missing on the PVE host: $device"; fi
    done
    (( have_gpu == 1 && have_ctl && have_uvm )) ||
        die 'GPU_DEVICES must include one /dev/nvidiaN, /dev/nvidiactl and /dev/nvidia-uvm (Kindi serves one model on one card here).'
fi

ostype=debian
[[ $TEMPLATE == *:vztmpl/ubuntu-* ]] && ostype=ubuntu
net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY || $IP_CIDR == dhcp ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype "$ostype"
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT" --tags 'ai;ai-model;osr-target;kindi'
    --description "Kindi inference target (Ternary-Bonsai-2, $KINDI_BACKEND); OpenAI API on TCP $KINDI_PORT")
[[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
[[ -z $SSH_PUBLIC_KEY ]] || create+=(--ssh-public-keys "$SSH_PUBLIC_KEY")
for i in "${!devices[@]}"; do create+=("--dev$i" "path=${devices[$i]},gid=$GPU_GID,mode=0660"); done

if [[ $KINDI_BACKEND == cuda ]]; then
    if (( ! dry_run )); then
        host_driver=$(nvidia_lxc_host_version) || die 'Cannot determine the loaded NVIDIA driver version on this Proxmox host.'
        [[ $NVIDIA_DRIVER_VERSION == auto || $host_driver == "$NVIDIA_DRIVER_VERSION" ]] ||
            die "Host NVIDIA driver is $host_driver; expected $NVIDIA_DRIVER_VERSION."
        NVIDIA_DRIVER_VERSION=$host_driver
        version_at_least "$NVIDIA_DRIVER_VERSION" "$min_driver" ||
            die "CUDA 10.2 needs NVIDIA driver $min_driver or newer; host driver is $NVIDIA_DRIVER_VERSION."
    else
        [[ $NVIDIA_DRIVER_VERSION != auto ]] || NVIDIA_DRIVER_VERSION='<host-nvidia-driver-version>'
    fi
fi

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2' ERR
pve_summary "Kindi: create"
pve_row 'Kindi CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB} GiB on $STORAGE"
pve_row 'Template' "$TEMPLATE"
pve_row 'Network' "$IP_CIDR${GATEWAY:+ via $GATEWAY} on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
pve_row 'Engine' "$KINDI_BACKEND${GPU_DEVICES:+ ($GPU_DEVICES)}"
pve_row 'Model' "$KINDI_MODEL (context $KINDI_CONTEXT, port $KINDI_PORT)"
pve_confirm "Create Kindi CT $CT_ID?"
(umask 022; run "${create[@]}")
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
run pct exec "$CT_ID" -- install -d -m 0700 /root/kindi-target-deploy
for file in install-target.sh cuda-toolkit.sh; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/kindi-target-deploy/$file" --perms 0755
done
for file in kindi.service kindi-weights.txt upstream-commit.txt requirements-cpu.lock requirements-cuda.lock uv.lock; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/kindi-target-deploy/$file" --perms 0644
done
if [[ $KINDI_BACKEND == cuda ]]; then
    run pct push "$CT_ID" "$NVIDIA_GUEST_INSTALLER" /root/kindi-target-deploy/install-nvidia-driver.sh --perms 0755
    nvidia_lxc_install_guest "$CT_ID" "$NVIDIA_DRIVER_VERSION" /root/kindi-target-deploy/install-nvidia-driver.sh
fi
run pct exec "$CT_ID" -- env "KINDI_REF=$KINDI_REF" "KINDI_COMMIT=$KINDI_COMMIT" "KINDI_BACKEND=$KINDI_BACKEND" \
    "KINDI_MODEL=$KINDI_MODEL" "KINDI_PROFILE=$KINDI_PROFILE" "KINDI_PORT=$KINDI_PORT" \
    "KINDI_CONTEXT=$KINDI_CONTEXT" "KINDI_HEAD=$KINDI_HEAD" "KINDI_SPEC=$KINDI_SPEC" \
    "KINDI_THREADS=$KINDI_THREADS" "KINDI_MODEL_NAME=$KINDI_MODEL_NAME" "KINDI_VERIFY=$KINDI_VERIFY" \
    "KINDI_PYTHON_VERSION=$KINDI_PYTHON_VERSION" "KINDI_READY_TIMEOUT=$KINDI_READY_TIMEOUT" \
    bash /root/kindi-target-deploy/install-target.sh

printf '\nKindi target CT %s: API port %s (%s). Read its generated key with:\n' "$CT_ID" "$KINDI_PORT" "$KINDI_BACKEND"
printf '  pct exec %s -- cat /etc/kindi-target/api-key\n' "$CT_ID"
printf 'Then on the router, set the Kindi key and add kindi://<CT address>:%s.\n' "$KINDI_PORT"
printf 'Service logs: pct exec %s -- journalctl -u kindi -f\n' "$CT_ID"
printf 'Upgrade later: push the current install-target.sh, cuda-toolkit.sh, kindi.service,\n'
printf '  kindi-weights.txt, upstream-commit.txt and the three *.lock files to /root/kindi-target-deploy in the CT, then run it there with --upgrade.\n'
