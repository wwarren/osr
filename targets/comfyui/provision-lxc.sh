#!/usr/bin/env bash
# Run on the PVE host to create a ComfyUI image-generation target. Never on the
# router CT/VM. The CT and the first ComfyUI install come from the Proxmox VE
# community script (ct/comfyui.sh), run with this target's settings preset.
# install-target.sh then adopts that install (unprivileged account, hardening
# drop-in, data under /var/lib/comfyui-target), the CT firewall admits only the
# router (ComfyUI has no authentication), and integrate-webui.py makes it the
# image generation engine of the router's Open WebUI.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
note() { printf '%s\n' "$*" >&2; }
readonly COMMUNITY_SCRIPT_DEFAULT_URL=https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/comfyui.sh
usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run] [--integrate-only | --no-webui]
   or: CT_ID=286 IP_CIDR=192.168.11.86/24 GATEWAY=192.168.11.1 ROUTER=280 \
       bash provision-lxc.sh [--dry-run] [--integrate-only | --no-webui]

Runs the community script
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/comfyui.sh)"
with the settings below preset as its var_* variables. It creates an
unprivileged Debian 13 CT with ComfyUI (Python 3.12 venv, PyTorch for the
chosen GPU) on port 8188. This script then:
  1. writes the CT's firewall: inbound only TCP 8188 from the router (and
     UI_ALLOW_CIDR), since ComfyUI has no authentication of its own;
  2. runs install-target.sh in the CT: ComfyUI runs as the unprivileged
     `comfyui` account under a hardening drop-in, with models, outputs and
     settings under /var/lib/comfyui-target (and downloads COMFYUI_MODEL_URL);
  3. sets ComfyUI as the image generation engine of the router's Open WebUI
     (Admin Settings > Images), with the selected distilled FLUX.2 Klein API workflow.
It asks for an Open WebUI admin API key unless OPENWEBUI_ADMIN_TOKEN is set.

The community script still shows its own menu; pick "Default" (or "My
Defaults") to accept the presets below. Its install takes a long time
(PyTorch alone is several GB).
An interactive run asks for CT_ID: the new ComfyUI CT ID, or the existing CT ID
with --integrate-only. It does not silently choose another CT when rerun.

The router (the LXC or VM running Open WebUI) is given as ROUTER:
  ROUTER=280                a CT on this Proxmox host, reached with pct
  ROUTER=192.168.11.80      any LXC or VM, reached as root over SSH
ROUTER_CT_ID or ROUTER_SSH_HOST force one kind. Without ROUTER the script asks.

Settings (environment; all optional unless noted):
  CT_ID=<next free>  CT_HOSTNAME=comfyui  CORES=4  MEMORY_MB=16384  ROOTFS_GB=64
  TEMPLATE_STORAGE=<vztmpl storage>  STORAGE=<rootdir storage>
  BRIDGE=vmbr0  IP_CIDR=<a.b.c.d/nn|dhcp>  GATEWAY=<a.b.c.d>
  NAMESERVER=<a.b.c.d>  VLAN_TAG=<1-4094>  SSH_PUBLIC_KEY=<file>
  GPU=auto|nvidia|amd|intel|none   auto: nvidia when /dev/nvidia0 exists, else none
                                   (none runs ComfyUI with --cpu: very slow); with
                                   GPU_CARD, auto is that card's vendor
  GPU_CARD=<PCI address>           one GPU (e.g. 0000:03:00.0, as lspci -D shows it)
                                   on a host with several: the community script passes
                                   every card of the vendor, then only this card's
                                   device nodes are kept (plus /dev/kfd and the shared
                                   NVIDIA nodes)
  COMFYUI_PORT=8188
  UI_ALLOW_CIDR='192.168.11.0/24'  also admit these addresses/CIDRs to the web UI
  FIREWALL=1                       0 leaves the CT unfiltered (ComfyUI is then open
                                   to anyone who can reach it)
  READY_TIMEOUT=600                seconds to wait for ComfyUI after adoption
  COMFYUI_MODEL_URL=<https URL>    a model to download into models/<folder>
  COMFYUI_MODEL_SHA256=<hex>       its checksum (recommended)
  COMFYUI_MODEL_FOLDER=checkpoints COMFYUI_MODEL_NAME=<file name; from the URL>
  COMFYUI_IMAGE_VARIANT=auto|klein-4b|klein-9b  the FLUX.2 Klein (distilled) model: its
                                   weights are downloaded into the CT (klein-weights.txt)
                                   and its workflow set in Open WebUI. auto: klein-4b for a
                                   new CT; with --integrate-only, the Klein workflow Open
                                   WebUI has, else the variant ComfyUI has the files of
  COMFYUI_DOWNLOAD_WEIGHTS=1       0 skips the download (put the files in by hand)
  HF_TOKEN=<hf_...>                for klein-9b, which is gated: a Hugging Face token of an
                                   account that accepted the FLUX Non-Commercial License
                                   (asked for when unset; passed to the CT as a file)
  COMFYUI_IMAGE_MODEL=<compatible Klein diffusion model> overrides the variant's file
  COMFYUI_IMAGE_SIZE=<WxH>  COMFYUI_IMAGE_STEPS=<n>   Open WebUI's image size/steps
  ROUTER_IP                        the address the router uses to reach this CT
                                   (detected with "ip route get" on the router)
  OPENWEBUI_PORT                   read from the router's /app/openwebui/.env
  ROUTER_SSH_PORT=22
  COMMUNITY_SCRIPT_URL=<url>       default: the ProxmoxVE main-branch ct/comfyui.sh
  COMMUNITY_SCRIPT_SHA256=<hex>    refuse to run a script with any other checksum
The checksum pins ct/comfyui.sh only: it downloads the shared build.func and
install/comfyui-install.sh, which install the latest ComfyUI release. Pin and
verify the release afterwards with install-target.sh --upgrade (see README.md).

--dry-run prints the plan without touching Proxmox, the router or a token.
--integrate-only registers an existing ComfyUI CT (CT_ID) with Open WebUI again.
--no-webui creates and adopts the CT without Open WebUI (set UI_ALLOW_CIDR, or
FIREWALL=0, so that someone can reach it).
For a dry run, set CT_ID explicitly (no cluster query is made).
USAGE
}

# Provision helpers (sourced by test-provision.sh) -----------------------------
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
valid_cidr() {
    local address prefix
    [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    address=${BASH_REMATCH[1]}
    prefix=${BASH_REMATCH[2]}
    ipv4 "$address" && [[ $prefix =~ ^(0|[1-9][0-9]?)$ ]] && (( prefix <= 32 ))
}
valid_container_id() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && (( $1 >= 100 )); }
valid_container_ip() { [[ $1 == dhcp ]] || valid_cidr "$1"; }
valid_hostname() {
    [[ ${#1} -le 253 && $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}
# allow_list VALUE: the addresses/CIDRs of a comma- or space-separated list, one
# per line; returns 1 if any entry is neither.
allow_list() {
    local entry
    for entry in ${1//,/ }; do
        ipv4 "$entry" || valid_cidr "$entry" || return 1
        printf '%s\n' "$entry"
    done
}
# gpu_kind GPU: the GPU family to set ComfyUI up for (auto: NVIDIA when the host
# has /dev/nvidia0, else none). AMD and Intel are only used when asked for.
gpu_kind() {
    case $1 in
        auto) if [[ -e ${NVIDIA_DEVICE:-/dev/nvidia0} ]]; then echo nvidia; else echo none; fi ;;
        nvidia|amd|intel|none) echo "$1" ;;
        *) return 1 ;;
    esac
}
# community_gpu_choice KIND: the answer to install/comfyui-install.sh's GPU menu
# ("[1]-None [2]-NVIDIA [3]-AMD [4]-Intel"), read from var_comfyui_gpu_type.
community_gpu_choice() {
    case $1 in none) echo 1 ;; nvidia) echo 2 ;; amd) echo 3 ;; intel) echo 4 ;; *) return 1 ;; esac
}
# The community script's var_* presets for these settings, one NAME=value per line.
community_vars() {
    local passthrough=yes
    [[ $gpu != none ]] || passthrough=no
    printf '%s\n' "var_ctid=$CT_ID" "var_hostname=$CT_HOSTNAME" "var_cpu=$CORES" "var_ram=$MEMORY_MB" \
        "var_disk=$ROOTFS_GB" "var_unprivileged=1" "var_nesting=1" "var_os=debian" "var_version=13" \
        "var_gpu=$passthrough" "var_comfyui_gpu_type=$(community_gpu_choice "$gpu")" "var_brg=$BRIDGE"
    [[ -z $IP_CIDR ]] || printf '%s\n' "var_net=$IP_CIDR"
    [[ -z $GATEWAY || $IP_CIDR == dhcp ]] || printf '%s\n' "var_gateway=$GATEWAY"
    [[ -z $NAMESERVER ]] || printf '%s\n' "var_ns=$NAMESERVER"
    [[ -z $VLAN_TAG ]] || printf '%s\n' "var_vlan=$VLAN_TAG"
    [[ -z $TEMPLATE_STORAGE ]] || printf '%s\n' "var_template_storage=$TEMPLATE_STORAGE"
    [[ -z $STORAGE ]] || printf '%s\n' "var_container_storage=$STORAGE"
    if [[ -n $SSH_PUBLIC_KEY ]]; then
        # The community script takes the key itself, not a path.
        printf '%s\n' "var_ssh=yes" "var_ssh_authorized_key=$(head -n1 -- "$SSH_PUBLIC_KEY" 2>/dev/null || printf '%s' "$SSH_PUBLIC_KEY")"
    fi
    return 0
}
# The community installer can leave Debian's 550.x nvidia-smi/NVML packages in
# the CT when it cannot find userspace matching the host. Debian's
# nvidia-installer-cleanup then refuses the matching NVIDIA .run installer.
# Select only installed driver packages; cuda-keyring is deliberately kept.
nvidia_guest_cleanup_script() {
    printf '%s' 'set --; for package in nvidia-smi libnvidia-ml1 libcuda1 '
    printf '%s' 'nvidia-alternative glx-alternative-nvidia nvidia-legacy-check nvidia-installer-cleanup; do '
    printf '%s' 'if dpkg -s "$package" 2>/dev/null | grep -q "^Status: install ok installed$"; '
    printf '%s' 'then set -- "$@" "$package"; fi; done; '
    printf '%s\n' 'if [ "$#" -gt 0 ]; then DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"; fi'
}
# Read the loaded kernel module version, which NVIDIA's LXC user-space
# libraries must match exactly. Accept either the proprietary or open module.
nvidia_kernel_version() {
    sed -nE 's/.*Kernel Module( for x86_64)?[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\2/p' | head -n1
}
# Require both NVML and CUDA userspace to be the exact host release.
nvidia_guest_ready_script() {
    printf '%s' 'expected=$1; nvml=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d "[:space:]"); '
    printf '%s' '[ "$nvml" = "$expected" ] || exit 1; '
    printf '%s' 'cuda=$(ldconfig -p | awk '\''$1 == "libcuda.so.1" && $2 ~ /x86-64/ { print $NF; exit }'\''); '
    printf '%s\n' '[ -n "$cuda" ] && [ -r "$cuda" ] && [ "$(basename "$(readlink -f "$cuda")")" = "libcuda.so.$expected" ]'
}
# firewall_config PORT SOURCE...: the CT's /etc/pve/firewall/<id>.fw. Inbound
# traffic is dropped except the ComfyUI port from each source (address or CIDR).
firewall_config() {
    local port=$1 source
    shift
    printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\n'
    for source in "$@"; do
        [[ $source == */* ]] || source+=/32
        printf 'IN ACCEPT -source %s -p tcp -dport %s -log nolog # comfyui-target\n' "$source" "$port"
    done
}
# net_with_firewall NET0: that net0 value with the firewall switched on.
net_with_firewall() {
    local net=$1
    if [[ ,$net, == *,firewall=1,* ]]; then printf '%s\n' "$net"; return 0; fi
    net=$(printf '%s' "$net" | sed -E 's/(^|,)firewall=[^,]*//g; s/^,//')
    printf '%s,firewall=1\n' "$net"
}
# classify_router VALUE: "ct <id>" for a Proxmox CT ID, "ssh <host>" for an
# IPv4 address or hostname; returns 1 for anything else.
classify_router() {
    local value=$1
    if [[ $value =~ ^[0-9]+$ ]]; then
        [[ $value =~ ^[1-9][0-9]{2,8}$ ]] || return 1
        printf 'ct %s\n' "$value"
    elif [[ $value =~ ^[0-9.]+$ ]]; then
        ipv4 "$value" || return 1
        printf 'ssh %s\n' "$value"
    elif valid_hostname "$value"; then
        printf 'ssh %s\n' "$value"
    else
        return 1
    fi
}
# route_src: the "src" address from `ip -4 route get` output on stdin.
route_src() { sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1; }
# remote_command ARG...: one string a POSIX remote shell splits back into ARGs.
remote_command() {
    local arg out=''
    for arg in "$@"; do
        out+="'${arg//\'/\'\\\'\'}' "
    done
    printf '%s' "${out% }"
}
# weight_urls FILE VARIANT: "<access> <url>" for each of VARIANT's weights in
# the manifest FILE (klein-weights.txt).
weight_urls() {
    awk -v v="$2" '$1 == v && NF == 7 { print $6, $7 }' "$1"
}
# weight_status URL [HEADER_FILE]: the HTTP status of a Hugging Face resolve URL
# (its redirect is not followed). A token is read by curl from HEADER_FILE.
weight_status() {
    local -a auth=()
    if [[ -n ${2:-} ]]; then auth=(-H "@$2"); fi
    curl -sS --max-time 30 --proto '=https' -o /dev/null -w '%{http_code}' -I "${auth[@]}" -- "$1" 2>/dev/null || true
}
valid_hf_token() { [[ $1 =~ ^hf_[A-Za-z0-9]{30,}$ ]]; }
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
# End provision helpers. --------------------------------------------------------

dry_run=0
mode=full
while (( $# )); do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --integrate-only) [[ $mode == full ]] || die 'Use only one of --integrate-only and --no-webui.'; mode=integrate ;;
        --no-webui) [[ $mode == full ]] || die 'Use only one of --integrate-only and --no-webui.'; mode=nowebui ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

CT_ID=${CT_ID:-}
CT_HOSTNAME=${CT_HOSTNAME:-comfyui}
CORES=${CORES:-4}
MEMORY_MB=${MEMORY_MB:-16384}
ROOTFS_GB=${ROOTFS_GB:-64}
STORAGE=${STORAGE:-}
TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-}
BRIDGE=${BRIDGE:-vmbr0}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
GPU=${GPU:-auto}
GPU_CARD=${GPU_CARD:-}
COMFYUI_PORT=${COMFYUI_PORT:-}
UI_ALLOW_CIDR=${UI_ALLOW_CIDR:-}
FIREWALL=${FIREWALL:-1}
READY_TIMEOUT=${READY_TIMEOUT:-600}
COMFYUI_MODEL_URL=${COMFYUI_MODEL_URL:-}
COMFYUI_MODEL_SHA256=${COMFYUI_MODEL_SHA256:-}
COMFYUI_MODEL_FOLDER=${COMFYUI_MODEL_FOLDER:-checkpoints}
COMFYUI_MODEL_NAME=${COMFYUI_MODEL_NAME:-}
COMFYUI_IMAGE_VARIANT=${COMFYUI_IMAGE_VARIANT:-auto}
COMFYUI_IMAGE_MODEL=${COMFYUI_IMAGE_MODEL:-}
COMFYUI_IMAGE_SIZE=${COMFYUI_IMAGE_SIZE:-}
COMFYUI_IMAGE_STEPS=${COMFYUI_IMAGE_STEPS:-}
ROUTER=${ROUTER:-}
ROUTER_CT_ID=${ROUTER_CT_ID:-}
ROUTER_SSH_HOST=${ROUTER_SSH_HOST:-}
ROUTER_SSH_PORT=${ROUTER_SSH_PORT:-22}
ROUTER_SSH_USER=${ROUTER_SSH_USER:-root}
ROUTER_IP=${ROUTER_IP:-}
OPENWEBUI_PORT=${OPENWEBUI_PORT:-}
COMMUNITY_SCRIPT_URL=${COMMUNITY_SCRIPT_URL:-$COMMUNITY_SCRIPT_DEFAULT_URL}
COMMUNITY_SCRIPT_SHA256=${COMMUNITY_SCRIPT_SHA256:-}
# Host paths, overridable for the tests only.
PVE_ETC=${PVE_ETC:-/etc/pve}
SYS_NET_DIR=${SYS_NET_DIR:-/sys/class/net}
# Taken out of the environment at once so no child process (pct, ssh) inherits it.
saved_admin_token=${OPENWEBUI_ADMIN_TOKEN:-}
saved_hf_token=${HF_TOKEN:-}
unset OPENWEBUI_ADMIN_TOKEN HF_TOKEN

# --- settings --------------------------------------------------------------------
if [[ -z $CT_ID ]]; then
    [[ -t 0 ]] || die 'Set CT_ID for an unattended run (or run interactively to be prompted).'
    if [[ $mode == integrate ]]; then
        read -r -p 'Existing ComfyUI CT ID on this Proxmox host: ' CT_ID || die 'No CT_ID was entered.'
    else
        read -r -p 'New ComfyUI CT ID on this Proxmox host (unused, at least 100): ' CT_ID || die 'No CT_ID was entered.'
    fi
    [[ -n $CT_ID ]] || die 'CT_ID is required.'
fi
valid_container_id "$CT_ID" || die 'ComfyUI CT_ID must be a numeric ID of 100 or more.'
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
for name in CORES MEMORY_MB ROOTFS_GB READY_TIMEOUT; do positive_int "$name" "${!name}"; done
(( MEMORY_MB >= 8192 )) || die 'MEMORY_MB must be at least 8192; image models need several GB of RAM.'
(( ROOTFS_GB >= 32 )) || die 'ROOTFS_GB must be at least 32; PyTorch alone takes about 10 GB, and models are several GB each.'
[[ -z $STORAGE || $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
[[ -z $TEMPLATE_STORAGE || $TEMPLATE_STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid TEMPLATE_STORAGE.'
if [[ $mode != integrate ]]; then
    pve_select_storage TEMPLATE_STORAGE vztmpl 0
    pve_select_storage STORAGE rootdir "$ROOTFS_GB"
fi
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ -z $IP_CIDR ]] || valid_container_ip "$IP_CIDR" || die 'IP_CIDR must be a.b.c.d/nn or dhcp.'
[[ -z $GATEWAY ]] || ipv4 "$GATEWAY" || die 'GATEWAY must be an IPv4 address.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY || $dry_run == 1 ]] || die "SSH_PUBLIC_KEY is not readable: $SSH_PUBLIC_KEY"
gpu=$(gpu_kind "$GPU") || die 'GPU must be auto, nvidia, amd, intel or none.'
card=''
if [[ -n $GPU_CARD && $mode != integrate ]]; then
    card=$(normalize_pci_address "$GPU_CARD") || die 'GPU_CARD must be a PCI address such as 0000:03:00.0.'
    [[ $GPU != none ]] || die 'GPU_CARD names a GPU, but GPU is none.'
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
if [[ -n $COMFYUI_PORT ]]; then
    positive_int COMFYUI_PORT "$COMFYUI_PORT"
    (( COMFYUI_PORT <= 65535 )) || die 'COMFYUI_PORT must be <=65535.'
fi
mapfile -t ui_sources < <(allow_list "$UI_ALLOW_CIDR") && allow_list "$UI_ALLOW_CIDR" >/dev/null ||
    die 'UI_ALLOW_CIDR must be IPv4 addresses or CIDRs, separated by commas or spaces.'
[[ $FIREWALL =~ ^[01]$ ]] || die 'FIREWALL must be 0 or 1.'
if [[ $mode == nowebui && $FIREWALL == 1 && ${#ui_sources[@]} -eq 0 ]]; then
    die 'With --no-webui nothing would be admitted to ComfyUI: set UI_ALLOW_CIDR (who may use it), or FIREWALL=0.'
fi
[[ -z $COMFYUI_MODEL_URL || $COMFYUI_MODEL_URL =~ ^https://[^[:space:]\'\"\`\$\\]+$ ]] || die 'COMFYUI_MODEL_URL must be an https URL.'
[[ -z $COMFYUI_MODEL_SHA256 || $COMFYUI_MODEL_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || die 'COMFYUI_MODEL_SHA256 must be 64 hex digits.'
[[ $COMFYUI_MODEL_FOLDER =~ ^[a-z][a-z0-9_]{0,63}$ ]] || die 'COMFYUI_MODEL_FOLDER must be a ComfyUI models folder name such as checkpoints.'
[[ -z $COMFYUI_MODEL_NAME || ( $COMFYUI_MODEL_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,200}$ && $COMFYUI_MODEL_NAME != *..* ) ]] ||
    die 'COMFYUI_MODEL_NAME must be a plain file name.'
[[ $COMFYUI_IMAGE_VARIANT == auto || $COMFYUI_IMAGE_VARIANT == klein-4b || $COMFYUI_IMAGE_VARIANT == klein-9b ]] ||
    die 'COMFYUI_IMAGE_VARIANT must be auto, klein-4b or klein-9b.'
COMFYUI_DOWNLOAD_WEIGHTS=${COMFYUI_DOWNLOAD_WEIGHTS:-1}
[[ $COMFYUI_DOWNLOAD_WEIGHTS =~ ^[01]$ ]] || die 'COMFYUI_DOWNLOAD_WEIGHTS must be 0 or 1.'
# A new CT gets the default model; --integrate-only can still find out which it has.
if [[ $mode != integrate && $COMFYUI_IMAGE_VARIANT == auto ]]; then COMFYUI_IMAGE_VARIANT=klein-4b; fi
download_variant=none
if [[ $mode != integrate && $COMFYUI_DOWNLOAD_WEIGHTS == 1 ]]; then download_variant=$COMFYUI_IMAGE_VARIANT; fi
[[ -z $COMFYUI_IMAGE_MODEL || ( ${#COMFYUI_IMAGE_MODEL} -le 255 && $COMFYUI_IMAGE_MODEL =~ ^[[:print:]]+$ ) ]] ||
    die 'COMFYUI_IMAGE_MODEL must be a diffusion model name as ComfyUI lists it.'
[[ -z $COMFYUI_IMAGE_SIZE || $COMFYUI_IMAGE_SIZE =~ ^[1-9][0-9]{1,4}x[1-9][0-9]{1,4}$ ]] || die 'COMFYUI_IMAGE_SIZE must be WIDTHxHEIGHT, e.g. 1024x1024.'
[[ -z $COMFYUI_IMAGE_STEPS ]] || positive_int COMFYUI_IMAGE_STEPS "$COMFYUI_IMAGE_STEPS"
[[ -z $ROUTER_IP ]] || ipv4 "$ROUTER_IP" || die 'ROUTER_IP must be IPv4.'
if [[ -n $OPENWEBUI_PORT ]]; then
    positive_int OPENWEBUI_PORT "$OPENWEBUI_PORT"
    (( OPENWEBUI_PORT <= 65535 )) || die 'OPENWEBUI_PORT must be <=65535.'
fi
[[ $COMMUNITY_SCRIPT_URL =~ ^https://[A-Za-z0-9./_-]+\.sh$ ]] || die 'COMMUNITY_SCRIPT_URL must be an https URL of a .sh file.'
[[ -z $COMMUNITY_SCRIPT_SHA256 || $COMMUNITY_SCRIPT_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || die 'COMMUNITY_SCRIPT_SHA256 must be 64 hex digits.'

# --- which Open WebUI to integrate with -----------------------------------------------
webui=1
[[ $mode != nowebui ]] || webui=0
router_kind=none
router_label=''
if (( webui )); then
    if [[ -n $ROUTER_CT_ID && -n $ROUTER_SSH_HOST ]] ||
       [[ -n $ROUTER && ( -n $ROUTER_CT_ID || -n $ROUTER_SSH_HOST ) ]]; then
        die 'Set only one of ROUTER, ROUTER_CT_ID, or ROUTER_SSH_HOST.'
    fi
    if [[ -z $ROUTER_CT_ID && -z $ROUTER_SSH_HOST ]]; then
        if [[ -z $ROUTER ]]; then
            [[ -t 0 ]] || die 'Set ROUTER to the router CT ID on this host, or the IP/hostname of the router LXC/VM (root SSH login); or use --no-webui.'
            printf 'Existing ollama-smart-router Open WebUI:\n' >&2
            printf '  a CT ID on this Proxmox host (e.g. 280), or\n' >&2
            printf '  the IP address or hostname of its LXC/VM, reached as %s over SSH\n' "$ROUTER_SSH_USER" >&2
            read -r -p 'Open WebUI CT ID or IP address: ' ROUTER || die 'No Open WebUI location was entered.'
        fi
        router_spec=$(classify_router "$ROUTER") ||
            die "ROUTER '$ROUTER' is neither a CT ID (100 or more) nor an IPv4 address or hostname."
        case $router_spec in
            ct\ *) ROUTER_CT_ID=${router_spec#ct } ;;
            ssh\ *) ROUTER_SSH_HOST=${router_spec#ssh } ;;
        esac
    fi
    if [[ -n $ROUTER_CT_ID ]]; then
        [[ $ROUTER_CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'ROUTER_CT_ID must be numeric and at least 100.'
        [[ $ROUTER_CT_ID != "$CT_ID" ]] || die 'The ComfyUI and router CT IDs must differ.'
        router_kind=ct
        router_label="router CT ${ROUTER_CT_ID}"
    else
        [[ $(classify_router "$ROUTER_SSH_HOST") == "ssh $ROUTER_SSH_HOST" ]] ||
            die 'ROUTER_SSH_HOST must be an IPv4 address or hostname.'
        [[ $ROUTER_SSH_USER == root ]] || die 'ROUTER_SSH_USER must be root for router staging and integration.'
        [[ $ROUTER_SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( ROUTER_SSH_PORT <= 65535 )) || die 'Invalid ROUTER_SSH_PORT.'
        router_kind=ssh
        router_label="router ${ROUTER_SSH_USER}@${ROUTER_SSH_HOST}"
    fi
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deploy=/root/comfyui-target-deploy
files=(install-target.sh comfyui-target.conf comfyui.env.example README.md klein-weights.txt)
for file in "${files[@]}" integrate-webui.py flux2-klein-4b-api.json flux2-klein-9b-api.json; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
verify_webui=$source_dir/../open-terminal/verify-webui.py
(( ! webui )) || [[ -r $verify_webui ]] || die "Missing $verify_webui."
nvidia_installer=''
# Keep the helper's historical filename; DRIVER_VERSION selects the release
# downloaded for the CT from this host's loaded kernel driver.
nvidia_installer=$source_dir/../../tools/install-nvidia-driver.sh
[[ -r $nvidia_installer ]] || nvidia_installer=''
[[ $gpu != nvidia || -n $nvidia_installer ]] || die 'An NVIDIA GPU needs tools/install-nvidia-driver.sh from the repository.'
nvidia_host_version=''
firewall_file=$PVE_ETC/firewall/${CT_ID}.fw

run() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
nvidia_guest_ready() {
    pct exec "$CT_ID" -- sh -c "$(nvidia_guest_ready_script)" sh "$nvidia_host_version"
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

stage=$(mktemp -d "${TMPDIR:-/tmp}/comfyui-setup.XXXXXX")
router_stage=''
# One multiplexed SSH connection for the whole run: a password is asked for once.
ssh_opts=(-p "$ROUTER_SSH_PORT" -o ConnectTimeout=15 -o ServerAliveInterval=15
    -o ControlMaster=auto -o "ControlPath=$stage/ssh-%C" -o ControlPersist=yes)
ssh_dest="${ROUTER_SSH_USER}@${ROUTER_SSH_HOST:-}"
# router_exec ARG...: run a command on the router (no dry-run handling).
router_exec() {
    if [[ $router_kind == ct ]]; then
        pct exec "$ROUTER_CT_ID" -- "$@"
    else
        ssh "${ssh_opts[@]}" "$ssh_dest" "$(remote_command "$@")"
    fi
}
# router_run ARG...: the same, but printed and skipped in a dry run.
router_run() {
    if [[ $router_kind == ct ]]; then
        run pct exec "$ROUTER_CT_ID" -- "$@"
    else
        printf '+ ssh %s@%s -- %s\n' "$ROUTER_SSH_USER" "$ROUTER_SSH_HOST" "$(remote_command "$@")"
        if (( ! dry_run )); then router_exec "$@"; fi
    fi
}
# router_push SRC DEST: copy a local file to the router, mode 0600.
router_push() {
    if [[ $router_kind == ct ]]; then
        run pct push "$ROUTER_CT_ID" "$1" "$2" --perms 0600
    else
        printf '+ ssh %s@%s -- write %s (0600) < %s\n' "$ROUTER_SSH_USER" "$ROUTER_SSH_HOST" "$2" "$1"
        if (( ! dry_run )); then
            ssh "${ssh_opts[@]}" "$ssh_dest" "umask 077 && cat > $(remote_command "$2")" < "$1"
        fi
    fi
}
created=0
guest_done=0
cleanup() {
    local rc=$?
    if [[ -n $router_stage ]] && (( ! dry_run )); then
        router_exec rm -rf -- "$router_stage" >/dev/null 2>&1 || true
    fi
    if [[ $router_kind == ssh ]] && (( ! dry_run )); then
        ssh "${ssh_opts[@]}" -O exit "$ssh_dest" >/dev/null 2>&1 || true
    fi
    if (( hf_token_pushed && ! dry_run )); then
        pct exec "$CT_ID" -- rm -f -- "$deploy/hf-token" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$stage" 2>/dev/null || true
    if (( rc != 0 && created && ! dry_run )); then
        printf 'Setup stopped. CT %s is kept for inspection (pct enter %s).\n' "$CT_ID" "$CT_ID" >&2
        if (( ! guest_done )); then
            printf 'After fixing the error, rerun the guest step: pct exec %s -- env COMFYUI_IMAGE_VARIANT=%s bash %s/install-target.sh\n' \
                "$CT_ID" "$download_variant" "$deploy" >&2
            if [[ $download_variant == klein-9b ]]; then
                printf '(klein-9b also needs HF_TOKEN_FILE=<a file in the CT with your Hugging Face token>.)\n' >&2
            fi
        fi
        (( ! webui )) || printf 'Then register it with Open WebUI: CT_ID=%s bash %s --integrate-only\n' "$CT_ID" "$0" >&2
    fi
}
trap cleanup EXIT

# --- check this host, the router and Open WebUI before anything is created ---------------
if (( ! dry_run )); then
    # id, not $EUID, so the tests can run the whole flow without root.
    [[ $(id -u) == 0 ]] || die 'Run as root on the intended PVE host.'
    for command_name in pveversion pct pvesh curl sha256sum; do command -v "$command_name" >/dev/null || die "Missing command: $command_name"; done
    [[ -d $PVE_ETC/nodes ]] || die '/etc/pve is unavailable; do not create a CT until the cluster filesystem is ready.'
    if [[ $mode != integrate && $gpu == nvidia ]]; then
        nvidia_host_version=$(nvidia_kernel_version < "${NVIDIA_HOST_VERSION_FILE:-/proc/driver/nvidia/version}") ||
            die 'Cannot read the loaded NVIDIA kernel driver version on this Proxmox host.'
        [[ $nvidia_host_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
            die 'Cannot determine the loaded NVIDIA kernel driver version on this Proxmox host.'
        note "Host NVIDIA driver version: $nvidia_host_version"
    fi
    if [[ $mode == integrate ]]; then
        pct status "$CT_ID" 2>/dev/null | grep -q 'status: running' || die "CT $CT_ID is not a running CT on this host."
    else
        if ! pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null; then
            if pct status "$CT_ID" >/dev/null 2>&1; then
                die "CT $CT_ID already exists. To re-register it, use --integrate-only; to resume or upgrade ComfyUI, run its guest install-target.sh in that CT."
            fi
            die "ID $CT_ID is unavailable in this cluster."
        fi
        [[ -d $SYS_NET_DIR/$BRIDGE ]] || die "Bridge interface is not present: $BRIDGE"
        [[ $FIREWALL == 0 || ! -e $firewall_file ]] || die "Refusing to replace existing firewall file: $firewall_file"
    fi
fi
if (( dry_run )) && [[ $mode != integrate && $gpu == nvidia ]]; then
    nvidia_host_version='<host-nvidia-driver-version>'
    printf '+ read loaded NVIDIA driver version from the Proxmox host\n'
fi
if (( webui )); then
    if (( dry_run )); then
        OPENWEBUI_PORT=${OPENWEBUI_PORT:-'<router-webui-port>'}
        printf '+ verify Open WebUI install, open-webui.service, /health and /api/version on %s:%s\n' "$router_label" "$OPENWEBUI_PORT"
    else
        if [[ $router_kind == ct ]]; then
            pct status "$ROUTER_CT_ID" 2>/dev/null | grep -q 'status: running' ||
                die "Router CT ${ROUTER_CT_ID} is not a running CT on this host. For a router elsewhere, set ROUTER to its IP address or hostname."
        else
            command -v ssh >/dev/null || die 'Missing command: ssh'
            note "Connecting to ${router_label} over SSH..."
            router_exec true || die "Cannot log in to ${router_label} on port ${ROUTER_SSH_PORT}."
        fi
        router_exec test -x /app/openwebui/venv/bin/open-webui ||
            die "Open WebUI is not installed at /app/openwebui on ${router_label}. Is this an ollama-smart-router install?"
        router_exec systemctl is-active --quiet open-webui.service ||
            die "Open WebUI (open-webui.service) is not active on ${router_label}."
        router_exec sh -c 'command -v python3 >/dev/null' || die "python3 is missing on ${router_label}."
        if [[ -z $OPENWEBUI_PORT ]]; then
            OPENWEBUI_PORT=$(router_exec sh -c "sed -n 's/^PORT=//p' /app/openwebui/.env 2>/dev/null | head -n1" || true)
            OPENWEBUI_PORT=${OPENWEBUI_PORT//[$'\r\n ']/}
            OPENWEBUI_PORT=${OPENWEBUI_PORT:-8080}
            [[ $OPENWEBUI_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( OPENWEBUI_PORT <= 65535 )) ||
                die "Invalid PORT in /app/openwebui/.env on ${router_label}."
        fi
        note "Verifying Open WebUI on ${router_label} (localhost:${OPENWEBUI_PORT})..."
        webui_version=$(router_exec python3 -c "$(cat "$verify_webui")" "$OPENWEBUI_PORT") ||
            die "No healthy Open WebUI answered on ${router_label} port ${OPENWEBUI_PORT}; CT ${CT_ID} was not touched."
        note "Verified Open WebUI ${webui_version} on ${router_label}."
        admin_token=$saved_admin_token
        if [[ -z $admin_token ]]; then
            [[ -t 0 ]] || die 'Set OPENWEBUI_ADMIN_TOKEN to an Open WebUI admin API key or JWT for unattended use.'
            read -r -s -p 'Open WebUI admin API key or JWT: ' admin_token
            printf '\n'
        fi
        [[ -n $admin_token ]] || die 'An Open WebUI admin API key or JWT is required (or use --no-webui).'
        printf '%s\n' "$admin_token" > "$stage/admin-token"
        unset admin_token
    fi
fi
unset saved_admin_token

# --- the image model's weights: reachable, and the token accepted, before the CT exists ---------
weights=$source_dir/klein-weights.txt
hf_token_pushed=0
if [[ $download_variant != none ]]; then
    mapfile -t weight_list < <(weight_urls "$weights" "$download_variant")
    (( ${#weight_list[@]} > 0 )) || die "$weights lists no files for $download_variant."
    gated_url=''
    for entry in "${weight_list[@]}"; do
        if [[ ${entry%% *} == gated ]]; then gated_url=${entry#* }; fi
    done
    if [[ -n $gated_url ]]; then
        license_page=${gated_url%%/resolve/*}
        if (( dry_run )); then
            printf '+ stage the Hugging Face token for %s (gated: %s)\n' "$download_variant" "$license_page"
        else
            hf_token=$saved_hf_token
            if [[ -z $hf_token ]]; then
                [[ -t 0 ]] || die "$download_variant is gated on Hugging Face: set HF_TOKEN (an account that accepted the license at $license_page), or choose klein-4b."
                note "$download_variant is gated: accept the FLUX Non-Commercial License at $license_page,"
                note "then create a read token under Hugging Face > Settings > Access Tokens."
                read -r -s -p 'Hugging Face token (hf_...): ' hf_token
                printf '\n'
            fi
            valid_hf_token "$hf_token" || die 'The Hugging Face token must be an access token (hf_...).'
            printf '%s\n' "$hf_token" > "$stage/hf-token"
            printf 'Authorization: Bearer %s\n' "$hf_token" > "$stage/hf-headers"
            unset hf_token
        fi
    fi
    if (( dry_run )); then
        printf '+ check that the %s weights answer on Hugging Face (%s files)\n' "$download_variant" "${#weight_list[@]}"
    else
        note "Checking the $download_variant weights on Hugging Face..."
        for entry in "${weight_list[@]}"; do
            url=${entry#* }
            headers=''
            if [[ ${entry%% *} == gated ]]; then headers=$stage/hf-headers; fi
            status=$(weight_status "$url" "$headers")
            case $status in
                2??|3??) ;;
                401|403) die "Hugging Face refused ${url##*/} (HTTP $status): accept the license at ${url%%/resolve/*} with the token's account, and check that the token can read it. Nothing was created." ;;
                *) die "${url##*/} did not answer from this host (HTTP ${status:-none}); check the internet access, or set COMFYUI_DOWNLOAD_WEIGHTS=0. Nothing was created." ;;
            esac
        done
    fi
fi
unset saved_hf_token

# --- the CT from the community script -------------------------------------------------------
comfyui_ip=''
if [[ -n $IP_CIDR && $IP_CIDR != dhcp ]]; then comfyui_ip=${IP_CIDR%/*}; fi
if [[ $mode != integrate ]]; then
    script=$stage/community-comfyui.sh
    run curl -fsSL -o "$script" "$COMMUNITY_SCRIPT_URL"
    if (( ! dry_run )); then
        actual=$(sha256sum "$script" | awk '{ print $1 }')
        printf 'Community script %s\n  sha256 %s\n' "$COMMUNITY_SCRIPT_URL" "$actual"
        if [[ -n $COMMUNITY_SCRIPT_SHA256 && $actual != "${COMMUNITY_SCRIPT_SHA256,,}" ]]; then
            die "The community script changed (expected $COMMUNITY_SCRIPT_SHA256). Review it, then update COMMUNITY_SCRIPT_SHA256."
        fi
    fi
    # The community script is interactive: it needs this terminal, not a pipe.
    # It creates an unprivileged CT, so give that child a normal extraction umask.
    (umask 022; run env "${presets[@]}" bash "$script")
    if (( ! dry_run )); then
        pct status "$CT_ID" >/dev/null 2>&1 || die "The community script did not create CT $CT_ID (did you change the ID in its menu?)."
        created=1
    fi
    narrow_gpu_devices
fi
if [[ -z $comfyui_ip ]]; then
    if (( dry_run )); then
        comfyui_ip='<CT address>'
    else
        comfyui_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{ print $1 }')
        ipv4 "$comfyui_ip" || die "Cannot read CT ${CT_ID}'s IPv4 address."
    fi
fi
if [[ -z $COMFYUI_PORT ]]; then
    COMFYUI_PORT=8188
    if [[ $mode == integrate ]] && (( ! dry_run )); then
        port=$(pct exec "$CT_ID" -- sed -n 's/^COMFYUI_PORT=//p' /etc/comfyui-target/comfyui.env 2>/dev/null | tail -n1 || true)
        port=${port//[$'\r\n ']/}
        if [[ $port =~ ^[1-9][0-9]{0,4}$ ]]; then COMFYUI_PORT=$port; fi
    fi
fi

# The firewall admits the address the router actually uses to reach the CT.
if (( webui )) && [[ -z $ROUTER_IP ]]; then
    if (( dry_run )); then
        ROUTER_IP='<router-source-ip>'
    else
        ROUTER_IP=$(router_exec ip -4 route get "$comfyui_ip" | route_src)
        ipv4 "$ROUTER_IP" || die "Cannot tell which address ${router_label} uses to reach ${comfyui_ip}; set ROUTER_IP."
    fi
fi

if [[ $mode != integrate ]]; then
    # --- firewall: ComfyUI has no authentication, so only the router (and
    # UI_ALLOW_CIDR) may reach its port ---------------------------------------------------
    if [[ $FIREWALL == 1 ]]; then
        sources=()
        (( ! webui )) || sources+=("$ROUTER_IP")
        sources+=("${ui_sources[@]}")
        firewall=$(firewall_config "$COMFYUI_PORT" "${sources[@]}")
        if (( dry_run )); then
            printf '+ write %s:\n%s\n' "$firewall_file" "$firewall"
            printf '+ pct set %s --net0 <net0 with firewall=1>\n' "$CT_ID"
        else
            [[ ! -e $firewall_file ]] || die "Refusing to replace existing firewall file: $firewall_file"
            # pmxcfs refuses chmod, so no install -d -m here.
            [[ -d $PVE_ETC/firewall ]] || mkdir -p -- "$PVE_ETC/firewall"
            printf '%s\n' "$firewall" > "$firewall_file"
            net0=$(pct config "$CT_ID" | sed -n 's/^net0: //p')
            [[ -n $net0 ]] || die "CT $CT_ID has no net0 to put behind the firewall."
            new_net0=$(net_with_firewall "$net0")
            if [[ $new_net0 != "$net0" ]]; then run pct set "$CT_ID" --net0 "$new_net0"; fi
            if command -v pve-firewall >/dev/null && ! pve-firewall status 2>/dev/null | grep -q 'enabled'; then
                note "Warning: the Proxmox firewall is not enabled for the datacenter, so CT ${CT_ID}'s rules have no effect."
                note "         Enable it under Datacenter > Firewall > Options (keep a rule that admits your own SSH/GUI access)."
            fi
        fi
    else
        note "FIREWALL=0: ComfyUI on ${comfyui_ip}:${COMFYUI_PORT} is open to anyone who can reach it (it has no authentication)."
    fi

    # --- adopt the install -------------------------------------------------------------------
    trap 'printf "Provisioning stopped at line %s.\n" "$LINENO" >&2' ERR
    run pct exec "$CT_ID" -- install -d -m 0700 "$deploy"
    for file in "${files[@]}"; do
        perms=0644
        [[ $file != *.sh ]] || perms=0755
        run pct push "$CT_ID" "$source_dir/$file" "$deploy/$file" --perms "$perms"
    done
    if [[ $gpu == nvidia ]]; then
        run pct push "$CT_ID" "$nvidia_installer" "$deploy/install-nvidia-driver.sh" --perms 0755
        # A working nvidia-smi alone does not prove CUDA is present. The
        # community installer may leave an older NVML or CUDA library behind.
        if (( dry_run )) || ! nvidia_guest_ready >/dev/null 2>&1; then
            # Confirm the CT sees this host's loaded module before changing
            # its driver packages or installing the matching NVIDIA release.
            if (( dry_run )); then
                printf '+ confirm CT %s sees host NVIDIA driver %s\n' "$CT_ID" "$nvidia_host_version"
            else
                nvidia_guest_version=$(pct exec "$CT_ID" -- cat /proc/driver/nvidia/version | nvidia_kernel_version) ||
                    die "CT $CT_ID cannot read the host NVIDIA driver version; leaving its Debian driver packages untouched."
                [[ $nvidia_guest_version == "$nvidia_host_version" ]] ||
                    die "CT $CT_ID sees NVIDIA driver '${nvidia_guest_version:-unknown}', expected $nvidia_host_version; leaving its Debian driver packages untouched."
            fi
            run pct exec "$CT_ID" -- systemctl stop comfyui
            run pct exec "$CT_ID" -- sh -c "$(nvidia_guest_cleanup_script)"
            run pct exec "$CT_ID" -- env "DRIVER_VERSION=$nvidia_host_version" bash "$deploy/install-nvidia-driver.sh" lxc
            if (( dry_run )); then
                printf '+ verify CT %s has NVIDIA NVML and CUDA userspace %s\n' "$CT_ID" "$nvidia_host_version"
            else
                nvidia_guest_ready ||
                    die "CT $CT_ID still lacks NVIDIA NVML and CUDA userspace $nvidia_host_version after installation. Check nvidia-smi, libcuda.so.1, and /var/log/nvidia-installer.log inside it."
            fi
        fi
    fi
    device=gpu
    [[ $gpu != none ]] || device=cpu
    guest_env=("COMFYUI_PORT=$COMFYUI_PORT" "COMFYUI_DEVICE=$device" "READY_TIMEOUT=$READY_TIMEOUT"
        "COMFYUI_MODEL_URL=$COMFYUI_MODEL_URL" "COMFYUI_MODEL_SHA256=$COMFYUI_MODEL_SHA256"
        "COMFYUI_MODEL_FOLDER=$COMFYUI_MODEL_FOLDER" "COMFYUI_MODEL_NAME=$COMFYUI_MODEL_NAME"
        "COMFYUI_IMAGE_VARIANT=$download_variant")
    if [[ -n ${gated_url:-} ]]; then
        # The token goes in as a root-only file (never an argument), removed afterwards.
        hf_token_pushed=1
        run pct push "$CT_ID" "$stage/hf-token" "$deploy/hf-token" --perms 0600
        guest_env+=("HF_TOKEN_FILE=$deploy/hf-token")
    fi
    run pct exec "$CT_ID" -- env "${guest_env[@]}" bash "$deploy/install-target.sh"
    guest_done=1
    if (( hf_token_pushed )); then
        run pct exec "$CT_ID" -- rm -f -- "$deploy/hf-token"
        hf_token_pushed=0
    fi
    trap - ERR
fi

# --- Open WebUI image generation ------------------------------------------------------------------
if (( webui )); then
    image_model=$COMFYUI_IMAGE_MODEL
    if (( dry_run )); then
        router_stage='<router-stage>'
        router_run mktemp -d /root/comfyui-integration.XXXXXX
    else
        # Validated before it is recorded: cleanup removes router_stage recursively.
        made=$(router_exec mktemp -d /root/comfyui-integration.XXXXXX)
        made=${made//[$'\r\n']/}
        [[ $made =~ ^/root/comfyui-integration\.[A-Za-z0-9]{6}$ ]] ||
            die "Unexpected router staging path: $made (not removed; check ${router_label} by hand)"
        router_stage=$made
    fi
    router_push "$stage/admin-token" "$router_stage/admin-token"
    router_push "$source_dir/integrate-webui.py" "$router_stage/integrate-webui.py"
    router_push "$source_dir/flux2-klein-4b-api.json" "$router_stage/flux2-klein-4b-api.json"
    router_push "$source_dir/flux2-klein-9b-api.json" "$router_stage/flux2-klein-9b-api.json"
    integrate=(python3 "$router_stage/integrate-webui.py"
        --webui-url "http://127.0.0.1:${OPENWEBUI_PORT}" --comfyui-url "http://${comfyui_ip}:${COMFYUI_PORT}"
        --admin-token-file "$router_stage/admin-token" --variant "$COMFYUI_IMAGE_VARIANT")
    [[ -z $image_model ]] || integrate+=(--model "$image_model")
    [[ -z $COMFYUI_IMAGE_SIZE ]] || integrate+=(--image-size "$COMFYUI_IMAGE_SIZE")
    [[ -z $COMFYUI_IMAGE_STEPS ]] || integrate+=(--image-steps "$COMFYUI_IMAGE_STEPS")
    router_run "${integrate[@]}"
    (( ! dry_run )) || router_stage=''
fi

printf '\nComfyUI: http://%s:%s in CT %s\n' "$comfyui_ip" "$COMFYUI_PORT" "$CT_ID"
if [[ $mode != integrate && $FIREWALL == 1 ]]; then
    admitted=("${sources[@]}")
    printf 'Its firewall admits TCP %s from %s only.\n' "$COMFYUI_PORT" "${admitted[*]}"
fi
if [[ $download_variant != none ]]; then
    printf 'The %s weights are in /var/lib/comfyui-target/models/{diffusion_models,text_encoders,vae}.\n' "$download_variant"
elif [[ $mode != integrate ]]; then
    printf 'No weights were downloaded. To fetch them: pct exec %s -- env COMFYUI_IMAGE_VARIANT=%s bash %s/install-target.sh\n' \
        "$CT_ID" "$COMFYUI_IMAGE_VARIANT" "$deploy"
fi
if (( webui )); then
    printf 'Open WebUI on %s uses the %s workflow: Admin Settings > Images. After changing the\n' "$router_label" "$COMFYUI_IMAGE_VARIANT"
    printf 'model files, rerun: CT_ID=%s COMFYUI_IMAGE_VARIANT=%s bash %s --integrate-only\n' "$CT_ID" "$COMFYUI_IMAGE_VARIANT" "$0"
fi
printf 'Pin and verify the ComfyUI release: pct exec %s -- bash %s/install-target.sh --upgrade\n' "$CT_ID" "$deploy"
