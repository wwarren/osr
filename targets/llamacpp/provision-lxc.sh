#!/usr/bin/env bash
# Run on the PVE host of a NEW inference target. Never install on the router CT/VM.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' \
       bash provision-lxc.sh [--dry-run]    # select container settings and create the CT

       CT_ID=250 TEMPLATE=local:vztmpl/debian-12-standard_<version>_amd64.tar.zst \
       STORAGE=local-lvm IP_CIDR=192.0.2.50/24 GATEWAY=192.0.2.1 \
       MODEL_ALIAS=<name:tag> MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/resolve/revision/model.gguf \
       GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' \
       bash provision-lxc.sh --install-target [--dry-run]

Missing settings are prompted on a terminal: CT ID, template, name, IPv4/CIDR
or DHCP, bridge/gateway, CPU cores, RAM (MiB), root disk storage ID and size (GiB).
Choose downloaded Debian templates (12 for CUDA and CPU builds, 13 for Vulkan)
and active rootdir storage by number.
Each template includes its storage ID. Enter m for manual entry; if inventory
is unavailable, enter the full template volume / storage ID manually.
Presets supplied through environment variables skip their corresponding prompts.
NONINTERACTIVE=true disables prompts; without a terminal, required CT_ID,
TEMPLATE, STORAGE and IP_CIDR must be supplied and optional defaults are used.
For CUDA, an interactive run reads the NVIDIA kernel minor mapping and falls
back to nvidia-smi; selecting one adds its /dev/nvidia<minor>, control, and UVM
device paths. GPU_DEVICES overrides that selector and is required for
noninteractive CUDA provisioning.
BACKEND=vulkan builds llama.cpp's Vulkan backend for AMD Radeon (RDNA 3/4) and
Intel Arc (A/B) cards, on a Debian 13 template (Mesa 25, Vulkan 1.4). It passes
the card's render node: GPU_DEVICES=/dev/dri/renderD128, or chosen from the
host's render nodes on a terminal. Set the host's driver up first with
tools/setup-host-gpu.sh (the router installer does, and passes these settings).
By default only the CT is created and deployment files are copied. No model
settings are required. For CUDA guests, run the copied NVIDIA 580.173.02 helper
before choosing the model with install-target.sh in the CT.
LLAMA_CPP_REF is optional; omitted/empty uses install-target.sh's pinned release.
Optional: CT_HOSTNAME=llama-target, BRIDGE=vmbr0, GATEWAY, NAMESERVER, VLAN_TAG,
          CORES=4, MEMORY_MB=16384, SWAP_MB=0, ROOTFS_GB=64, ONBOOT=0,
          SSH_PUBLIC_KEY=<file>, GPU_DEVICES=<space-separated exact /dev paths>,
          INSTALL_TARGET=0, BACKEND=cuda|vulkan|cpu, BUILD_JOBS=4, GPU_LAYERS=auto,
          CONTEXT_SIZE=8192, PARALLEL_SLOTS=1, THREADS=4, LLAMA_EXTRA_ARGS=,
           MODEL_PARAMETER_SIZE=unknown, MODEL_FAMILY=unknown,
           MODEL_QUANTIZATION=unknown, MODEL_CAPABILITIES=completion,
           CUDA_ARCHITECTURES=native, CUDA_COMPILER=<optional-path-inside-CT>,
           MODEL_DOWNLOAD_URL=<direct-public-Hugging-Face-GGUF-URL>.

--create-only explicitly skips the guest installer (the default), overriding
INSTALL_TARGET=1 or --install-target. Prepare host-matched NVIDIA userspace
libraries in the CT, then run install-target.sh there; it installs the CUDA
13.0 toolkit when nvcc is missing.
--install-target (or INSTALL_TARGET=1) runs the NVIDIA 580.173.02 LXC user-space
installer first for CUDA guests, then runs the guest installer. It requires
explicit MODEL_ALIAS=<name[:tag]> (a bare name gets :latest) plus either
MODEL_PATH or a direct public huggingface.co MODEL_DOWNLOAD_URL. A URL-only
install uses the guest's default model store; set MODEL_PATH to choose its
destination.
Deployment files are copied to /root/llama-target-deploy either way.
--dry-run validates inputs and prints commands without creating a CT.
Only a new unprivileged CT is created. No host drivers or host configuration change.
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
# The Debian release of the template: 12 for CUDA (NVIDIA's repository) and CPU
# builds, 13 for Vulkan (Mesa 25 and Vulkan 1.4 from Debian itself).
template_release() { if [[ ${BACKEND:-cuda} == vulkan ]]; then echo 13; else echo 12; fi; }
valid_container_template() {
    local release
    release=$(template_release)
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-${release}-[A-Za-z0-9._-]+\.tar\.(zst|xz|gz)$ ]]
}
valid_container_name() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
valid_container_storage() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_container_bridge() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
valid_container_cores() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && (( $1 <= 8192 )); }
valid_container_memory() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && (( $1 >= 1024 )); }
valid_container_disk() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]; }
valid_container_gateway() { [[ -z $1 ]] || ipv4 "$1"; }
valid_huggingface_gguf_url() {
    local url=$1 path
    [[ $url != *[[:space:]]* && $url != *'#'* ]] || return 1
    path=${url%%\?*}
    [[ $path != *'/../'* && $path != */.. && $path != *'/./'* && $path != */. ]] || return 1
    [[ $url =~ ^https://huggingface\.co/[^/?#]+/[^/?#]+/resolve/[^?#]+\.gguf(\?[^#[:space:]]*)?$ ]]
}
valid_container_ip() {
    local address prefix
    [[ $1 != dhcp ]] || return 0
    [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    address=${BASH_REMATCH[1]}
    prefix=${BASH_REMATCH[2]}
    ipv4 "$address" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( prefix <= 32 ))
}
container_prompt_available() { [[ $NONINTERACTIVE == false && -t 0 ]]; }
prompt_container_setting() {
    local name=$1 label=$2 default=$3 validator=$4 guidance=$5 allow_empty=${6:-false} value
    if [[ -n ${!name:-} || ( $allow_empty == true && -v $name ) ]]; then
        "$validator" "${!name}" || die "$name: $guidance"
        return
    fi
    if ! container_prompt_available; then
        [[ -n $default || $allow_empty == true ]] || die "Set $name for unattended provisioning, or run interactively on the PVE host."
        "$validator" "$default" || die "$name: $guidance"
        printf -v "$name" '%s' "$default"
        return
    fi
    while true; do
        printf '%s' "$label" >&2
        [[ -z $default ]] || printf ' [%s]' "$default" >&2
        printf ': ' >&2
        IFS= read -r value || die "Input ended while reading $name."
        value=${value:-$default}
        if [[ -n $value || $allow_empty == true ]] && "$validator" "$value"; then
            printf -v "$name" '%s' "$value"
            return
        fi
        printf '%s\n' "$guidance" >&2
    done
}
list_container_templates() {
    local storage type status rest volume
    command -v pvesm >/dev/null && command -v pveam >/dev/null || return 0
    while read -r storage type status rest; do
        [[ $status == active ]] || continue
        while read -r volume rest; do
            if valid_container_template "$volume"; then printf '%s\n' "$volume"; fi
        done < <(pveam list "$storage" 2>/dev/null || true)
    done < <(pvesm status --content vztmpl 2>/dev/null || true)
    return 0
}
list_container_storage() {
    local storage type status rest
    command -v pvesm >/dev/null || return 0
    while read -r storage type status rest; do
        if [[ $status == active ]] && valid_container_storage "$storage"; then
            printf '%s\t%s (%s)\n' "$storage" "$storage" "$type"
        fi
    done < <(pvesm status --content rootdir 2>/dev/null || true)
    return 0
}
select_container_setting() {
    local name=$1 label=$2 validator=$3 guidance=$4 list_function=$5
    local choice description value i
    local -a choices=() labels=()
    if [[ -n ${!name:-} ]] || ! container_prompt_available; then
        prompt_container_setting "$name" "$label" '' "$validator" "$guidance"
        return
    fi
    while IFS=$'\t' read -r choice description; do
        if "$validator" "$choice"; then
            choices+=("$choice")
            labels+=("${description:-$choice}")
        fi
    done < <("$list_function")
    if (( ${#choices[@]} == 0 )); then
        printf 'No available %s choices were found; enter the full ID manually.\n' "$label" >&2
        prompt_container_setting "$name" "$label" '' "$validator" "$guidance"
        return
    fi
    printf '\n%s:\n' "$label" >&2
    for i in "${!choices[@]}"; do printf '  %s) %s\n' "$((i + 1))" "${labels[$i]}" >&2; done
    printf '  m) Enter a full ID manually\n' >&2
    while true; do
        printf 'Select %s [1-%s or m]: ' "$label" "${#choices[@]}" >&2
        IFS= read -r value || die "Input ended while reading $name."
        if [[ $value == m || $value == M ]]; then
            prompt_container_setting "$name" "$label" '' "$validator" "$guidance"
            return
        fi
        if [[ $value =~ ^[1-9][0-9]{0,8}$ ]] && (( value <= ${#choices[@]} )); then
            printf -v "$name" '%s' "${choices[$((value - 1))]}"
            return
        fi
        for choice in "${choices[@]}"; do
            if [[ $value == "$choice" ]]; then
                printf -v "$name" '%s' "$choice"
                return
            fi
        done
        printf 'Choose a listed number or ID, or m for manual entry.\n' >&2
    done
}
# GPU configuration helpers (read-only).
trim_space() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}
valid_gpu_device_list() {
    local device
    local -a device_list=()
    read -r -a device_list <<< "$1"
    (( ${#device_list[@]} >= 1 && ${#device_list[@]} <= 32 )) || return 1
    for device in "${device_list[@]}"; do
        [[ $device =~ ^/dev/[A-Za-z0-9_./-]+$ && $device != *'/../'* && $device != *'/./'* ]] || return 1
    done
}
nvidia_device_node_exists() { [[ -c $1 ]]; }
nvidia_gpu_minor_from_proc() {
    local info_file=$1 key value minor=''
    while IFS=: read -r key value; do
        key=$(trim_space "$key")
        [[ $key == 'Device Minor' ]] || continue
        value=$(trim_space "$value")
        if [[ $value =~ ^[0-9]+$ ]]; then
            minor=$value
            break
        fi
    done < "$info_file"
    [[ -n $minor ]] || return 1
    printf '%s\n' "$minor"
}
list_nvidia_gpus_from_proc() {
    local info_file key value model bus minor found=0
    for info_file in /proc/driver/nvidia/gpus/*/information; do
        [[ -r $info_file ]] || continue
        model=''
        bus=''
        while IFS=: read -r key value; do
            key=$(trim_space "$key")
            value=$(trim_space "$value")
            case $key in
                Model) model=$value ;;
                'Bus Location') bus=$value ;;
            esac
        done < "$info_file"
        if ! minor=$(nvidia_gpu_minor_from_proc "$info_file"); then continue; fi
        [[ -n $model ]] || model='NVIDIA GPU'
        if [[ -n $bus ]]; then
            printf '%s\t%s at %s (/dev/nvidia%s)\n' "$minor" "$model" "$bus" "$minor"
        else
            printf '%s\t%s (/dev/nvidia%s)\n' "$minor" "$model" "$minor"
        fi
        found=1
    done
    (( found ))
}
nvidia_gpu_minor() {
    local index=$1 output key value
    if ! output=$(LC_ALL=C nvidia-smi -q -i "$index" 2>&1); then
        printf 'nvidia-smi detailed query failed for GPU %s: %s\n' "$index" "$output" >&2
        return 1
    fi
    while IFS=: read -r key value; do
        key=$(trim_space "$key")
        [[ $key == 'Minor Number' ]] || continue
        value=$(trim_space "$value")
        if [[ $value =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        break
    done <<< "$output"
    printf 'nvidia-smi detailed query did not report a usable minor number for GPU %s.\n' "$index" >&2
    return 1
}
list_nvidia_gpus() {
    local output index name minor line found=0
    local -a fallback_indices=() fallback_names=()
    if output=$(list_nvidia_gpus_from_proc); then
        printf '%s\n' "$output"
        return 0
    fi
    printf 'NVIDIA device mapping was not found in /proc/driver/nvidia; trying nvidia-smi fallback.\n' >&2
    if ! command -v nvidia-smi >/dev/null; then
        printf 'nvidia-smi is not on PATH; enter exact GPU device paths manually.\n' >&2
        return 0
    fi
    if ! output=$(LC_ALL=C nvidia-smi -L 2>&1); then
        printf 'nvidia-smi fallback GPU listing failed: %s\n' "$output" >&2
        return 0
    fi
    while IFS= read -r line; do
        if [[ $line =~ ^GPU[[:space:]]+([0-9]+):[[:space:]]+(.+)[[:space:]]+\(UUID: ]]; then
            fallback_indices+=("${BASH_REMATCH[1]}")
            fallback_names+=("$(trim_space "${BASH_REMATCH[2]}")")
        fi
    done <<< "$output"
    if (( ${#fallback_indices[@]} == 0 )); then
        printf 'nvidia-smi GPU inventory query failed: fallback listing returned no physical GPUs.\n' >&2
        return 0
    fi
    for index in "${!fallback_indices[@]}"; do
        if minor=$(nvidia_gpu_minor "${fallback_indices[$index]}"); then
            printf '%s\tGPU %s: %s (/dev/nvidia%s)\n' "$minor" "${fallback_indices[$index]}" "${fallback_names[$index]}" "$minor"
            found=1
        fi
    done
    (( found )) && return 0
    if (( ${#fallback_indices[@]} == 1 )) && nvidia_device_node_exists "/dev/nvidia${fallback_indices[0]}"; then
        minor=${fallback_indices[0]}
        printf '%s\tGPU %s: %s (/dev/nvidia%s; single-GPU fallback)\n' "$minor" "${fallback_indices[0]}" "${fallback_names[0]}" "$minor"
    fi
    return 0
}
prompt_gpu_devices_manual() {
    local value
    while true; do
        printf 'GPU device paths (space-separated, e.g. /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools, or /dev/dri/renderD128): ' >&2
        IFS= read -r value || die 'Input ended while reading GPU_DEVICES.'
        if valid_gpu_device_list "$value"; then
            GPU_DEVICES=$value
            return
        fi
        printf 'Enter one to 32 absolute /dev device paths without traversal components.\n' >&2
    done
}
# list_render_nodes: the host's DRM render nodes as "path<TAB>label", AMD and
# Intel cards only (vendor and PCI device ID from sysfs).
list_render_nodes() {
    local node vendor device name
    for node in "${DRM_SYSFS:-/sys/class/drm}"/renderD*; do
        [[ -r $node/device/vendor ]] || continue
        vendor=$(< "$node/device/vendor"); device=$(cat "$node/device/device" 2>/dev/null || echo unknown)
        case $vendor in
            0x1002) name='AMD Radeon' ;;
            0x8086) name='Intel' ;;
            *) continue ;;
        esac
        printf '/dev/dri/%s\t%s GPU %s (/dev/dri/%s)\n' "${node##*/}" "$name" "$device" "${node##*/}"
    done
    return 0
}
configure_render_node() {
    local value i
    local -a nodes=() labels=()
    if ! container_prompt_available; then
        die 'Vulkan requires explicit GPU_DEVICES: the card'"'"'s render node on this host, e.g. /dev/dri/renderD128.'
    fi
    while IFS=$'\t' read -r value label; do
        [[ -n $value ]] || continue
        nodes+=("$value"); labels+=("$label")
    done < <(list_render_nodes)
    if (( ${#nodes[@]} == 0 )); then
        printf 'No AMD or Intel render node was found; enter the device path manually.\n' >&2
        prompt_gpu_devices_manual
        return
    fi
    printf '\nGPU render nodes:\n' >&2
    for i in "${!nodes[@]}"; do printf '  %s) %s\n' "$((i + 1))" "${labels[$i]}" >&2; done
    printf '  m) Enter device paths manually\n' >&2
    while true; do
        printf 'Select the GPU [1-%s or m]: ' "${#nodes[@]}" >&2
        IFS= read -r value || die 'Input ended while reading GPU_DEVICES.'
        if [[ $value == m || $value == M ]]; then
            prompt_gpu_devices_manual
            return
        fi
        if [[ $value =~ ^[1-9][0-9]{0,8}$ ]] && (( value <= ${#nodes[@]} )); then
            GPU_DEVICES=${nodes[$((value - 1))]}
            return
        fi
        printf 'Choose a listed number or m for manual entry.\n' >&2
    done
}
configure_gpu_devices() {
    [[ $BACKEND != cpu ]] || return 0
    [[ -z ${GPU_DEVICES:-} ]] || return 0
    if [[ $BACKEND == vulkan ]]; then
        configure_render_node
        return
    fi
    if ! container_prompt_available; then
        die 'CUDA requires explicit GPU_DEVICES; select the GPU and control/UVM device paths on this host.'
    fi
    local minor label value i
    local -a minors=() labels=()
    while IFS=$'\t' read -r minor label; do
        [[ $minor =~ ^[0-9]+$ && -n $label ]] || continue
        minors+=("$minor")
        labels+=("$label")
    done < <(list_nvidia_gpus)
    if (( ${#minors[@]} == 0 )); then
        printf 'No NVIDIA GPU inventory was found; enter the exact device paths manually.\n' >&2
        prompt_gpu_devices_manual
        return
    fi
    printf '\nNVIDIA GPUs:\n' >&2
    for i in "${!minors[@]}"; do printf '  %s) %s\n' "$((i + 1))" "${labels[$i]}" >&2; done
    printf '  m) Enter device paths manually\n' >&2
    while true; do
        printf 'Select NVIDIA GPU [1-%s or m]: ' "${#minors[@]}" >&2
        IFS= read -r value || die 'Input ended while reading GPU_DEVICES.'
        if [[ $value == m || $value == M ]]; then
            prompt_gpu_devices_manual
            return
        fi
        if [[ $value =~ ^[1-9][0-9]{0,8}$ ]] && (( value <= ${#minors[@]} )); then
            GPU_DEVICES="/dev/nvidia${minors[$((value - 1))]} /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools"
            return
        fi
        printf 'Choose a listed number or m for manual entry.\n' >&2
    done
}
# End GPU configuration helpers.
configure_container() {
    NONINTERACTIVE=${NONINTERACTIVE:-false}
    [[ $NONINTERACTIVE == true || $NONINTERACTIVE == false ]] || die 'NONINTERACTIVE must be true or false.'
    local next_id=''
    if [[ -z ${CT_ID:-} ]] && container_prompt_available && command -v pvesh >/dev/null; then
        next_id=$(pvesh get /cluster/nextid 2>/dev/null) || next_id=''
        valid_container_id "$next_id" || next_id=''
    fi
    prompt_container_setting CT_ID 'Container ID' "$next_id" valid_container_id 'Enter an unused CT ID from 100 to 999999999.'
    if [[ $(template_release) == 13 ]]; then
        select_container_setting TEMPLATE 'CT template volume' valid_container_template \
            'Enter an existing Debian 13 template volume (Vulkan needs Debian 13), e.g. local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst.' list_container_templates
    else
        select_container_setting TEMPLATE 'CT template volume' valid_container_template \
            'Enter an existing Debian 12 template volume, e.g. local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst.' list_container_templates
    fi
    prompt_container_setting CT_HOSTNAME 'Container name' llama-target valid_container_name 'Enter a DNS hostname label, up to 63 characters.'
    prompt_container_setting IP_CIDR 'IPv4 address/CIDR or dhcp' '' valid_container_ip 'Enter a valid IPv4/CIDR (e.g. 192.168.11.30/24), or dhcp.'
    prompt_container_setting BRIDGE 'Network bridge' vmbr0 valid_container_bridge 'Enter a Proxmox bridge name, e.g. vmbr0.'
    if [[ $IP_CIDR == dhcp ]]; then
        [[ -z ${GATEWAY:-} ]] || die 'Do not set GATEWAY with IP_CIDR=dhcp.'
        GATEWAY=''
    else
        prompt_container_setting GATEWAY 'IPv4 gateway (blank for none)' '' valid_container_gateway 'Enter an IPv4 gateway or leave it blank.' true
    fi
    prompt_container_setting CORES 'CPU cores' 4 valid_container_cores 'Enter a whole number from 1 to 8192.'
    prompt_container_setting MEMORY_MB 'RAM in MiB (16384 = 16 GiB)' 16384 valid_container_memory 'Enter a whole number of MiB, at least 1024.'
    select_container_setting STORAGE 'Root disk storage ID' valid_container_storage \
        'Enter a Proxmox rootdir storage ID, e.g. local-lvm (not a filesystem path).' list_container_storage
    prompt_container_setting ROOTFS_GB 'Root disk size in GiB' 64 valid_container_disk 'Enter a positive whole number of GiB.'
    printf '\nContainer: %s (%s)\nTemplate: %s\nNetwork: %s on %s\nCPU: %s cores | RAM: %s MiB | Disk: %s:%s GiB\n' \
        "$CT_HOSTNAME" "$CT_ID" "$TEMPLATE" "$IP_CIDR" "$BRIDGE" "$CORES" "$MEMORY_MB" "$STORAGE" "$ROOTFS_GB"
}
# End container configuration helpers.

dry_run=0
create_only=0
INSTALL_TARGET=${INSTALL_TARGET:-0}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --create-only) create_only=1 ;;
        --install-target) INSTALL_TARGET=1 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done
if (( create_only )); then INSTALL_TARGET=0; fi
[[ $INSTALL_TARGET =~ ^[01]$ ]] || die 'INSTALL_TARGET must be 0 or 1.'
LLAMA_CPP_REF=${LLAMA_CPP_REF:-}
MODEL_ALIAS=${MODEL_ALIAS:-}
MODEL_PATH=${MODEL_PATH:-}
MODEL_DOWNLOAD_URL=${MODEL_DOWNLOAD_URL:-}
if [[ $INSTALL_TARGET == 1 ]]; then
    [[ -n $MODEL_ALIAS ]] || die 'Explicit guest installation requires MODEL_ALIAS. Set it for a prepared template, or use --create-only and choose the model inside the CT later.'
    [[ -n $MODEL_PATH || -n $MODEL_DOWNLOAD_URL ]] || die 'Explicit guest installation requires MODEL_PATH or MODEL_DOWNLOAD_URL. Set a source for a prepared template, or use --create-only and choose the model inside the CT later.'
fi
BACKEND=${BACKEND:-cuda}
[[ $BACKEND == cpu || $BACKEND == cuda || $BACKEND == vulkan ]] || die 'BACKEND must be cpu, cuda or vulkan.'
configure_container
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SWAP_MB=${SWAP_MB:-0}
ONBOOT=${ONBOOT:-0}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
GPU_DEVICES=${GPU_DEVICES:-}
BUILD_JOBS=${BUILD_JOBS:-4}
CONTEXT_SIZE=${CONTEXT_SIZE:-8192}
PARALLEL_SLOTS=${PARALLEL_SLOTS:-1}
THREADS=${THREADS:-4}
if [[ $BACKEND != cpu ]]; then GPU_LAYERS=${GPU_LAYERS:-auto}; else GPU_LAYERS=${GPU_LAYERS:-0}; fi
MODEL_PARAMETER_SIZE=${MODEL_PARAMETER_SIZE:-unknown}
MODEL_FAMILY=${MODEL_FAMILY:-unknown}
MODEL_QUANTIZATION=${MODEL_QUANTIZATION:-unknown}
MODEL_CAPABILITIES=${MODEL_CAPABILITIES:-completion}
CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES:-native}
CUDA_COMPILER=${CUDA_COMPILER:-}
LLAMA_EXTRA_ARGS=${LLAMA_EXTRA_ARGS:-}

configure_gpu_devices
for name in BUILD_JOBS CONTEXT_SIZE PARALLEL_SLOTS THREADS; do positive_int "$name" "${!name}"; done
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
[[ $GPU_LAYERS == auto || $GPU_LAYERS == all || $GPU_LAYERS =~ ^(0|[1-9][0-9]{0,5})$ ]] || die 'GPU_LAYERS must be auto, all, or a nonnegative integer.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || ( -f $SSH_PUBLIC_KEY && -s $SSH_PUBLIC_KEY && -r $SSH_PUBLIC_KEY ) ]] || die 'SSH_PUBLIC_KEY must refer to a readable, nonempty public-key file.'
[[ $BACKEND != cpu || $GPU_LAYERS == 0 ]] || die 'A CPU build requires GPU_LAYERS=0.'
if (( INSTALL_TARGET )); then
    if [[ -n $LLAMA_CPP_REF ]]; then
        [[ $LLAMA_CPP_REF =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'LLAMA_CPP_REF must be a release tag or full commit without refs/.'
        [[ $LLAMA_CPP_REF != HEAD && $LLAMA_CPP_REF != master && $LLAMA_CPP_REF != main ]] || die 'LLAMA_CPP_REF must be a pinned tag or commit.'
    fi
    # Same rule as install-target.sh: a bare name gets the :latest tag.
    [[ $MODEL_ALIAS =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]] || die 'MODEL_ALIAS must be a model name or name:tag.'
    [[ $MODEL_ALIAS == *:* ]] || MODEL_ALIAS+=:latest
    [[ $LLAMA_EXTRA_ARGS =~ ^[A-Za-z0-9\ ._,:=/+-]*$ ]] || die 'LLAMA_EXTRA_ARGS may contain only letters, digits, spaces and . _ , : = / + -'
    if [[ -n $MODEL_PATH ]]; then
        [[ $MODEL_PATH =~ ^/[A-Za-z0-9_./-]+\.gguf$ && $MODEL_PATH != *'/../'* && $MODEL_PATH != *'/./'* ]] || die 'MODEL_PATH must be an absolute .gguf path without spaces or traversal components.'
        [[ $MODEL_PATH != /root/* && $MODEL_PATH != /home/* ]] || die 'Place models outside /root and /home.'
    fi
    [[ -z $MODEL_DOWNLOAD_URL ]] || valid_huggingface_gguf_url "$MODEL_DOWNLOAD_URL" || die 'MODEL_DOWNLOAD_URL must be a direct HTTPS huggingface.co/<org>/<repo>/resolve/<revision>/<file>.gguf URL.'
    for name in MODEL_PARAMETER_SIZE MODEL_FAMILY MODEL_QUANTIZATION; do [[ ${!name} =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid $name."; done
    [[ $MODEL_CAPABILITIES =~ ^(completion|tools|vision|embedding)(,(completion|tools|vision|embedding))*$ ]] || die 'MODEL_CAPABILITIES may contain completion,tools,vision,embedding.'
    [[ $CUDA_ARCHITECTURES == native || $CUDA_ARCHITECTURES =~ ^[0-9]+(-real|-virtual)?(\;[0-9]+(-real|-virtual)?)*$ ]] || die 'Invalid CUDA_ARCHITECTURES (use native or e.g. 86;89;120).'
    [[ -z $CUDA_COMPILER || $CUDA_COMPILER =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'CUDA_COMPILER must be an absolute path without spaces.'
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
nvidia_installer=''
for candidate in \
    "$source_dir/../../tools/install_nvidia_580_173_02.sh" \
    "$source_dir/../../install_nvidia_580_173_02.sh"; do
    if [[ -r $candidate ]]; then
        nvidia_installer=$(cd -- "$(dirname -- "$candidate")" && pwd)/$(basename -- "$candidate")
        break
    fi
done
files=(install-target.sh bridge.py requirements.txt llama-server.service llama-ollama-bridge.service llama-server.env.example bridge.env.example)
for file in "${files[@]}"; do [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"; done
[[ -n $nvidia_installer ]] || die 'Missing install_nvidia_580_173_02.sh in the repository root or tools directory.'
net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT" --description 'Standalone llama.cpp inference target; OpenAI/Ollama compatibility on TCP 11434')
[[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
[[ -z $SSH_PUBLIC_KEY ]] || create+=(--ssh-public-keys "$SSH_PUBLIC_KEY")
devices=()
if [[ -n $GPU_DEVICES ]]; then read -r -a devices <<< "$GPU_DEVICES"; fi
if [[ $BACKEND == cuda ]] && (( ${#devices[@]} == 0 )); then
    die 'CUDA requires explicit GPU_DEVICES; select the GPU and control/UVM device paths on this host.'
fi
if [[ $BACKEND == vulkan ]]; then
    (( ${#devices[@]} > 0 )) || die 'Vulkan requires GPU_DEVICES: the card'"'"'s render node, e.g. /dev/dri/renderD128.'
    for device in "${devices[@]}"; do
        [[ $device == /dev/dri/renderD* ]] || die "Vulkan passes the card's render node only (/dev/dri/renderD<n>), not $device."
    done
fi
(( ${#devices[@]} <= 32 )) || die 'At most 32 explicit GPU device paths are supported.'
declare -A seen_devices=()
for i in "${!devices[@]}"; do
    device=${devices[$i]}
    [[ $device =~ ^/dev/[A-Za-z0-9_./-]+$ && $device != *'/../'* && $device != *'/./'* ]] || die "Invalid device path: $device"
    [[ -z ${seen_devices[$device]:-} ]] || die "Duplicate device path: $device"
    seen_devices[$device]=1
    if (( ! dry_run )); then [[ -c $device ]] || die "Not an existing character device on this host: $device"; fi
    create+=("--dev$i" "path=$device,gid=993,mode=0660")
done
guest_env=(env "NONINTERACTIVE=true" "LLAMA_CPP_REF=$LLAMA_CPP_REF" "MODEL_ALIAS=$MODEL_ALIAS" "MODEL_PATH=$MODEL_PATH" "MODEL_DOWNLOAD_URL=$MODEL_DOWNLOAD_URL" "BACKEND=$BACKEND" "BUILD_JOBS=$BUILD_JOBS" "CONTEXT_SIZE=$CONTEXT_SIZE" "PARALLEL_SLOTS=$PARALLEL_SLOTS" "THREADS=$THREADS" "GPU_LAYERS=$GPU_LAYERS" "MODEL_PARAMETER_SIZE=$MODEL_PARAMETER_SIZE" "MODEL_FAMILY=$MODEL_FAMILY" "MODEL_QUANTIZATION=$MODEL_QUANTIZATION" "MODEL_CAPABILITIES=$MODEL_CAPABILITIES" "CUDA_ARCHITECTURES=$CUDA_ARCHITECTURES" "CUDA_COMPILER=$CUDA_COMPILER" "LLAMA_EXTRA_ARGS=$LLAMA_EXTRA_ARGS")
run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if (( ! dry_run )); then "$@"; fi
}

if (( ! dry_run )); then
    [[ ${EUID} -eq 0 ]] || die 'Run as root on the intended PVE host.'
    for command_name in pveversion pct pvesh pvesm; do command -v "$command_name" >/dev/null || die "Missing PVE command: $command_name"; done
    [[ $(pveversion) == pve-manager/9.* ]] || die 'This script targets Proxmox VE 9.x (requested PVE 9.2).'
    [[ -d /etc/pve/nodes ]] || die '/etc/pve is unavailable; do not create a CT until the cluster filesystem is ready.'
    # The cluster API rejects an ID already assigned to any CT or VM, on any node.
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "ID $CT_ID is unavailable in this cluster."
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge interface is not present: $BRIDGE"
    template_path=$(pvesm path "$TEMPLATE")
    [[ -f $template_path && -r $template_path ]] || die "Template is not readable on this node: $TEMPLATE"
    storage_ready=0
    while read -r storage_name _ storage_status _; do
        if [[ $storage_name == "$STORAGE" && $storage_status == active ]]; then
            storage_ready=1
            break
        fi
    done < <(pvesm status --content rootdir 2>/dev/null || true)
    (( storage_ready )) || die "Storage is not active or does not support LXC root disks: $STORAGE"
fi

trap 'printf "Provisioning stopped at line %s. Any newly created CT is retained for inspection; no CT is deleted automatically.\n" "$LINENO" >&2' ERR
run "${create[@]}"
run pct start "$CT_ID"
if (( ! dry_run )); then
    ready=0
    for (( attempt=0; attempt<45; attempt++ )); do
        if pct exec "$CT_ID" -- test -d /run/systemd/system; then ready=1; break; fi
        sleep 1
    done
    (( ready )) || die "CT $CT_ID did not start systemd within 45 seconds."
fi
run pct exec "$CT_ID" -- install -d -m 0700 /root/llama-target-deploy
for file in "${files[@]}"; do
    run pct push "$CT_ID" "$source_dir/$file" "/root/llama-target-deploy/$file" --perms 0644
done
run pct push "$CT_ID" "$nvidia_installer" /root/llama-target-deploy/install_nvidia_580_173_02.sh --perms 0755
if (( INSTALL_TARGET )); then
    if [[ $BACKEND == cuda ]]; then
        run pct exec "$CT_ID" -- bash /root/llama-target-deploy/install_nvidia_580_173_02.sh lxc
    fi
    run pct exec "$CT_ID" -- "${guest_env[@]}" bash /root/llama-target-deploy/install-target.sh
else
    printf '\nGuest installation skipped. Enter the target CT: pct enter %s\n' "$CT_ID"
    if [[ $BACKEND == cuda ]]; then
        printf 'Install the host-matched NVIDIA 580.173.02 user-space libraries inside the CT first:\n'
        printf '  bash /root/llama-target-deploy/install_nvidia_580_173_02.sh lxc\n'
    fi
    if [[ $BACKEND == vulkan ]]; then
        printf 'Then run this inside the CT to select the model/tag and directory; Mesa'"'"'s Vulkan driver and the build tools install automatically:\n'
    else
        printf 'Then run this inside the CT to select the model/tag and directory; the CUDA toolkit installs automatically if missing:\n'
    fi
    printf '  BACKEND=%q ' "$BACKEND"
    if [[ $BACKEND == cuda && -n $CUDA_COMPILER ]]; then printf 'CUDA_COMPILER=%q ' "$CUDA_COMPILER"; fi
    printf 'bash /root/llama-target-deploy/install-target.sh\n'
fi
if (( INSTALL_TARGET )) && [[ -n $MODEL_DOWNLOAD_URL ]]; then
    printf '\nReview CT %s network/firewall and verify the downloaded GGUF before starting services.\n' "$CT_ID"
else
    printf '\nReview CT %s network/firewall and stage the GGUF before starting services.\n' "$CT_ID"
fi
printf 'Enable CT autostart when ready: pct set %s --onboot 1\n' "$CT_ID"
