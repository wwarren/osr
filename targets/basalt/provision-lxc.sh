#!/usr/bin/env bash
# Run on the Proxmox host with the NVIDIA GPU, never inside the router CT.
#
# Basalt is a CUDA/C++ engine that must be BUILT for compute capability 12.0
# (Blackwell, sm_120) on CUDA 13.0+. Unlike Strata (pre-built binaries), this
# target also installs host-matched NVIDIA user-space, a CUDA 13.0+ toolkit
# and a build toolchain inside the CT before running install-target.sh, which
# builds the engine, downloads the .basalt model and starts the service.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run]
   or: CT_ID=250 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_<version>_amd64.tar.zst \
       STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1 \
       bash targets/basalt/provision-lxc.sh [--dry-run]

Creates an unprivileged Proxmox VE 9 LXC, passes an NVIDIA GPU through, clones
https://github.com/jesdga95/basalt.git inside the CT, installs host-matched
NVIDIA user-space plus a CUDA 13.0+ toolkit and build toolchain, builds Basalt
for compute capability 12.0, downloads the .basalt model from Hugging Face,
and starts its API as a systemd service. A random API key is generated inside
the CT. The model download is tens to hundreds of GiB and the build is slow,
so provisioning can take a long time. --dry-run validates settings and prints
the PVE command plan.

Required: TEMPLATE (downloaded Ubuntu 22.04/24.04 or Debian 12/13 amd64),
          STORAGE (rootdir storage), IP_CIDR (a.b.c.d/nn or dhcp).
          GATEWAY is required for a static address.
          The host needs NVIDIA driver 580.173.02 and the repository's
          matching LXC user-space installer by default.
An interactive run lists downloaded templates and eligible rootdir storage
when TEMPLATE or STORAGE is unset.

Optional: CT_HOSTNAME=basalt-target, BRIDGE=vmbr0, CORES=8,
          MEMORY_MB=131072 (the model's expert arena is tens of GiB of pinned
          host RAM; floor 65536), SWAP_MB=0, ROOTFS_GB=200 (the model file plus
          the CUDA toolkit and build tree; the Q8_0 pack needs more),
          ONBOOT=1, NAMESERVER, VLAN_TAG, SSH_PUBLIC_KEY=<readable file>,
          GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
                      (plus /dev/nvidia-uvm-tools when the host has it),
          GPU_GID=44 (the CT group given the GPU nodes; 44 is "video"),
          NVIDIA_DRIVER_VERSION=580.173.02,
          NVIDIA_GUEST_INSTALLER=<host path to matching LXC helper>,
          CUDA_VERSION=13.0 (the toolkit floor; basalt's CMake hard-errors below),
          BASALT_URL=https://github.com/jesdga95/basalt.git,
          BASALT_REF=main, BASALT_COMMIT=<optional full SHA-1 pin>,
          BASALT_HF_REPO=https://huggingface.co/jesdga/Qwen3.8-Flash-Next-Basalt,
          BASALT_MODEL=Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt,
          BASALT_ALIAS=qwen3.8-flash-next, BASALT_GPUS=0 (or "0,1"),
          BASALT_CONTEXT=32768, BASALT_PORT=8080, BASALT_READY_TIMEOUT=3600,
          BASALT_ALLOW_NO_KEY=false.

With no BASALT_COMMIT, installation fetches the latest commit on BASALT_REF
(main by default).

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
CT_HOSTNAME=${CT_HOSTNAME:-basalt-target}
BRIDGE=${BRIDGE:-vmbr0}
CORES=${CORES:-8}
MEMORY_MB=${MEMORY_MB:-131072}
SWAP_MB=${SWAP_MB:-0}
ROOTFS_GB=${ROOTFS_GB:-200}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
if [[ -z ${GPU_DEVICES:-} ]]; then
    GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
    # Optional: only some driver setups create it, and nothing here needs it.
    [[ -c /dev/nvidia-uvm-tools ]] && GPU_DEVICES+=' /dev/nvidia-uvm-tools'
fi
# The Basalt service runs as an unprivileged account that joins this group, so
# the nodes must not be root's group inside the CT.
GPU_GID=${GPU_GID:-44}
NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION:-580.173.02}
CUDA_VERSION=${CUDA_VERSION:-13.0}
BASALT_URL=${BASALT_URL:-https://github.com/jesdga95/basalt.git}
BASALT_REF=${BASALT_REF:-main}
BASALT_COMMIT=${BASALT_COMMIT:-}
BASALT_HF_REPO=${BASALT_HF_REPO:-https://huggingface.co/jesdga/Qwen3.8-Flash-Next-Basalt}
BASALT_MODEL=${BASALT_MODEL:-Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt}
BASALT_ALIAS=${BASALT_ALIAS:-qwen3.8-flash-next}
BASALT_GPUS=${BASALT_GPUS:-0}
BASALT_CONTEXT=${BASALT_CONTEXT:-32768}
BASALT_PORT=${BASALT_PORT:-8080}
BASALT_READY_TIMEOUT=${BASALT_READY_TIMEOUT:-3600}
BASALT_ALLOW_NO_KEY=${BASALT_ALLOW_NO_KEY:-false}

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
for name in CORES MEMORY_MB ROOTFS_GB BASALT_READY_TIMEOUT; do positive_int "$name" "${!name}"; done
(( MEMORY_MB >= 65536 )) || die 'MEMORY_MB must be at least 65536; the Basalt model arena is tens of GiB of pinned RAM.'
(( ROOTFS_GB >= 120 )) || die 'ROOTFS_GB must be at least 120 for the Basalt model plus the CUDA toolkit and build tree.'
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY ]] || die 'SSH_PUBLIC_KEY must be a readable file.'
[[ $GPU_GID =~ ^[1-9][0-9]{0,4}$ ]] && (( GPU_GID <= 65535 )) || die 'GPU_GID must be a non-root group ID (1..65535).'
[[ $NVIDIA_DRIVER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid NVIDIA_DRIVER_VERSION.'
[[ $CUDA_VERSION =~ ^[0-9]+\.[0-9]+$ ]] && (( ${CUDA_VERSION%%.*} >= 13 )) || die 'CUDA_VERSION must be 13.0 or newer (Basalt hard-errors below 13.0).'
[[ $BASALT_URL =~ ^https://[A-Za-z0-9._/-]+$ ]] || die 'Invalid BASALT_URL (must be an https URL).'
[[ $BASALT_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $BASALT_REF != HEAD && $BASALT_REF != *..* ]] || die 'BASALT_REF must be a branch or tag name.'
[[ -z $BASALT_COMMIT || $BASALT_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'BASALT_COMMIT must be a full 40-digit SHA-1.'
[[ $BASALT_HF_REPO =~ ^https://[A-Za-z0-9._/-]+$ ]] || die 'Invalid BASALT_HF_REPO (must be an https URL).'
[[ $BASALT_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $BASALT_MODEL == *.basalt ]] || die 'BASALT_MODEL must be a .basalt file name.'
[[ $BASALT_ALIAS =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || die 'Invalid BASALT_ALIAS.'
[[ $BASALT_GPUS =~ ^[0-9]+(,[0-9]+)*$ ]] || die 'BASALT_GPUS must be a GPU list like 0 or 0,1.'
positive_int BASALT_CONTEXT "$BASALT_CONTEXT"
[[ $BASALT_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( BASALT_PORT <= 65535 )) || die 'BASALT_PORT must be 1..65535.'
[[ $BASALT_READY_TIMEOUT =~ ^[1-9][0-9]{0,6}$ ]] || die 'BASALT_READY_TIMEOUT must be a positive number of seconds.'
[[ $BASALT_ALLOW_NO_KEY =~ ^(true|false)$ ]] || die 'BASALT_ALLOW_NO_KEY must be true or false.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Where to send a host without an NVIDIA driver (the router installer runs it too).
gpu_hint=" Without an NVIDIA driver on this host, run: bash ${source_dir%/*/*}/tools/setup-host-gpu.sh"
for file in install-target.sh basalt.service cuda-toolkit.sh; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
# The template decides which NVIDIA CUDA repository the CT uses; refuse a
# combination that repository cannot install before any CT is created.
[[ $TEMPLATE =~ :vztmpl/(ubuntu|debian)-([0-9]+)(\.([0-9]+))?- ]]
template_dist=${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[4]}
CUDA_DIST=$template_dist CUDA_VERSION=$CUDA_VERSION bash "$source_dir/cuda-toolkit.sh" --check-repo ||
    die "CUDA_VERSION=$CUDA_VERSION cannot be installed in a $template_dist CT (see above)."
# The NVIDIA LXC user-space helper lives at the repository root, two levels up.
NVIDIA_GUEST_INSTALLER=${NVIDIA_GUEST_INSTALLER:-$source_dir/../../install_nvidia_580_173_02.sh}
[[ -r $NVIDIA_GUEST_INSTALLER ]] || die "Missing NVIDIA LXC user-space helper: $NVIDIA_GUEST_INSTALLER"

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
    if (( ! dry_run )); then [[ -c $device ]] || die "GPU device is missing on the PVE host: $device.$gpu_hint"; fi
done
(( have_gpu && have_ctl && have_uvm )) || die 'GPU_DEVICES must include /dev/nvidiaN, /dev/nvidiactl, and /dev/nvidia-uvm.'
IFS=, read -r -a gpu_indices <<< "$BASALT_GPUS"
for gpu_index in "${gpu_indices[@]}"; do
    [[ -n ${seen_devices[/dev/nvidia$gpu_index]:-} ]] ||
        die "BASALT_GPUS selects GPU $gpu_index, but GPU_DEVICES does not pass through /dev/nvidia$gpu_index."
done

ostype=debian
[[ $TEMPLATE == *:vztmpl/ubuntu-* ]] && ostype=ubuntu
net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY || $IP_CIDR == dhcp ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype "$ostype"
    --unprivileged 1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT"
    --description "Basalt inference target; OpenAI API on TCP $BASALT_PORT")
[[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
[[ -z $SSH_PUBLIC_KEY ]] || create+=(--ssh-public-keys "$SSH_PUBLIC_KEY")
for i in "${!devices[@]}"; do create+=("--dev$i" "path=${devices[$i]},gid=$GPU_GID,mode=0660"); done

if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root on the PVE host.'
    for command_name in pveversion pct pvesh pvesm nvidia-smi; do
        if ! command -v "$command_name" >/dev/null; then
            [[ $command_name == nvidia-smi ]] || die "Missing PVE/driver command: $command_name"
            die "Missing PVE/driver command: nvidia-smi.$gpu_hint"
        fi
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
    host_versions=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
    host_driver=${host_versions%%$'\n'*}
    host_driver=${host_driver//[[:space:]]/}
    [[ $host_driver == "$NVIDIA_DRIVER_VERSION" ]] || \
        die "Host NVIDIA driver is $host_driver; expected $NVIDIA_DRIVER_VERSION. Supply a matching NVIDIA_GUEST_INSTALLER and NVIDIA_DRIVER_VERSION."
fi

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2' ERR
run "${create[@]}"
# Basalt pins tens of GiB of expert memory. systemd's LimitMEMLOCK must be
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
            online=1; break; fi
        sleep 3
    done
    (( online )) || die "CT $CT_ID has no default route or DNS after 180 seconds; check network settings."
fi
# QEMU guest agent: Proxmox does not use it for an LXC (no virtio-serial port, so
# the service stays inactive), but every guest carries it. A failure is not fatal.
run pct exec "$CT_ID" -- sh -c 'export DEBIAN_FRONTEND=noninteractive; for i in 1 2 3 4 5; do apt-get update -q && apt-get install -y -q qemu-guest-agent && exit 0; sleep 5; done; exit 1' ||
    printf 'Warning: qemu-guest-agent did not install in CT %s; continuing.\n' "$CT_ID" >&2
run pct exec "$CT_ID" -- install -d -m 0700 /root/basalt-target-deploy
run pct push "$CT_ID" "$source_dir/install-target.sh" /root/basalt-target-deploy/install-target.sh --perms 0755
run pct push "$CT_ID" "$source_dir/cuda-toolkit.sh" /root/basalt-target-deploy/cuda-toolkit.sh --perms 0755
run pct push "$CT_ID" "$source_dir/basalt.service" /root/basalt-target-deploy/basalt.service --perms 0644
run pct push "$CT_ID" "$NVIDIA_GUEST_INSTALLER" /root/basalt-target-deploy/nvidia-guest-install.sh --perms 0755
# Host-matched NVIDIA user-space first; the installer is invoked in LXC mode
# (no driver, no kernel module -- just the user-space matched to the host driver).
run pct exec "$CT_ID" -- bash /root/basalt-target-deploy/nvidia-guest-install.sh lxc
# Then the CUDA toolkit, build toolchain and engine build, the model download,
# and the service start all happen inside install-target.sh (so a failed build
# does not leave a half-configured service).
run pct exec "$CT_ID" -- env \
    "BASALT_URL=$BASALT_URL" "BASALT_REF=$BASALT_REF" "BASALT_COMMIT=$BASALT_COMMIT" \
    "BASALT_HF_REPO=$BASALT_HF_REPO" "BASALT_MODEL=$BASALT_MODEL" "BASALT_ALIAS=$BASALT_ALIAS" \
    "BASALT_GPUS=$BASALT_GPUS" "BASALT_CONTEXT=$BASALT_CONTEXT" "BASALT_PORT=$BASALT_PORT" \
    "BASALT_READY_TIMEOUT=$BASALT_READY_TIMEOUT" "BASALT_ALLOW_NO_KEY=$BASALT_ALLOW_NO_KEY" \
    "CUDA_VERSION=$CUDA_VERSION" \
    bash /root/basalt-target-deploy/install-target.sh

printf '\nBasalt target CT %s: API port %s. Read its generated key with:\n' "$CT_ID" "$BASALT_PORT"
printf '  pct exec %s -- cat /etc/basalt-target/api-key\n' "$CT_ID"
printf 'Router registration needs Basalt support; the current router does not accept basalt:// addresses.\n'
printf 'Service logs: pct exec %s -- journalctl -u basalt -f\n' "$CT_ID"
printf 'Upgrade later: push the current install-target.sh, cuda-toolkit.sh and basalt.service to\n'
printf '  /root/basalt-target-deploy in the CT, then run install-target.sh there with --upgrade.\n'
