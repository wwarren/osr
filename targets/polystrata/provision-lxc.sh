#!/usr/bin/env bash
# Run on the Proxmox host with the NVIDIA GPU, never inside the router CT.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/../nvidia-lxc.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/families.sh"
usage() {
    cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run]

The installer asks for the CT ID (default: the cluster's next free ID, which
unattended runs take), IP/CIDR (or dhcp) and a gateway for static IPs. Preset
CT_ID to choose another ID, and IP_CIDR and GATEWAY for unattended runs.

Creates an unprivileged Proxmox VE 9 LXC, passes an NVIDIA GPU through, clones
https://github.com/simplexai-labs/PolyStrata.git inside the CT, runs PolyStrata's
Linux setup for the chosen model family and size, and starts its API as a
systemd service. A random API key is generated inside the CT. Setup downloads
the model from PolyStrata's upstream sources (11 to 190 GB) and can take a long
time. --dry-run validates settings and prints the PVE command plan.

Required: TEMPLATE (downloaded Ubuntu 22.04/24.04 or
Debian 12/13 amd64), STORAGE (rootdir storage), IP_CIDR (a.b.c.d/nn or dhcp).
GATEWAY is required for a static address. The CT installs user-space matching
the loaded host NVIDIA driver.
Interactive runs list downloaded templates and eligible rootdir storage when
those values are unset. This script creates a new
CT; to resume or upgrade an existing PolyStrata CT, run its guest install-target.sh.

Optional: CT_HOSTNAME=polystrata-target, BRIDGE=vmbr0, CORES=8, MEMORY_MB=65536
          (at least 16384; setup's RAM estimate for the size is shown in the
          menu), SWAP_MB=0, ROOTFS_GB=160 (at least 60), ONBOOT=1, NAMESERVER, VLAN_TAG,
          SSH_PUBLIC_KEY=<readable file>,
          GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
                      (plus /dev/nvidia-uvm-tools when the host has it),
          GPU_GID=44 (the CT group given the GPU nodes; 44 is "video"),
          NVIDIA_DRIVER_VERSION=auto (loaded host driver; or an exact-version check),
          NVIDIA_GUEST_INSTALLER=<host path to matching LXC helper>,
          POLYSTRATA_COMMIT=36e654b1b7eb4cb462202445be296ba012c75edf (tested default),
          POLYSTRATA_REF=<branch or tag> (explicitly follow it when no commit is set),
          POLYSTRATA_FAMILY=<asked, default qwen> (families.sh: qwen, swift,
                    coder, unsloth, gyro, nvfp4 on the Strata engine; glm,
                    deepseek, lfm25, inkling, flint, kolibri, groot, qwen36,
                    clover, ornith, gemma4, tiel, minicpmv, ornith122 on
                    PolyStrata's experimental engine),
          POLYSTRATA_MODEL=<asked, default the family's in families.sh>,
          POLYSTRATA_CONTEXT=65536, POLYSTRATA_PARALLEL=1 (1 to 8),
          POLYSTRATA_KV=<asked when there is a choice> (the KV cache. Strata
                    engine: int8, k8v4 = 8-bit keys and 4-bit values, or q4_0;
                    suggested: int8 when the cache fits in the CT's RAM from a
                    64K context, else k8v4 for 12 and 16 GB cards and int8 for
                    24 and 32 GB cards. PolyStrata engine: auto (fp16) or the
                    family's smaller formats, e.g. q8_0. auto passes no --kv),
          POLYSTRATA_MESSAGE_CACHE=<asked on the Strata engine, default false>
                    (true: checkpoint a long conversation before its last
                    message, for agents that rewrite it),
          POLYSTRATA_VISION=no, POLYSTRATA_PORT=8080 (or 11434),
          POLYSTRATA_READY_TIMEOUT=900, POLYSTRATA_ALLOW_NO_KEY=false.

PolyStrata's setup.sh options vary between releases; the guest installer reads
setup.sh --help and stops with an explanation when a required one (--host,
--api-key, --no-start, ...) is missing. Explicit POLYSTRATA_REF or an empty
POLYSTRATA_COMMIT follows a branch tip (main if no ref is set).

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

# polystrata_gpu_vram_mib NODE...: the memory in MiB of the card behind the first
# /dev/nvidiaN among NODE, or nothing when it is not known (no driver, no
# nvidia-smi, or the card is not listed). The driver's /proc information maps
# the node's minor number to the card's PCI address; nvidia-smi gives its size.
polystrata_gpu_vram_mib() {
    local node minor info address='' bus mib
    for node in "$@"; do
        [[ $node =~ ^/dev/nvidia([0-9]+)$ ]] || continue
        minor=${BASH_REMATCH[1]}
        for info in "${NVIDIA_PROC:-/proc/driver/nvidia}"/gpus/*/information; do
            [[ -r $info ]] || continue
            if [[ $(sed -n 's/^Device Minor:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$info" | head -n1) == "$minor" ]]; then
                address=${info%/information}; address=${address##*/}
                break
            fi
        done
        [[ -n $address ]] && command -v nvidia-smi >/dev/null 2>&1 || return 0
        while IFS=', ' read -r bus mib; do
            [[ $mib =~ ^[0-9]+$ ]] || continue
            # nvidia-smi writes the domain with 8 digits (00000000:03:00.0).
            if [[ ${bus,,} == *":${address#*:}" ]]; then printf '%s\n' "$mib"; return 0; fi
        done < <(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null)
        return 0
    done
    return 0
}
# polystrata_kv_streams CONTEXT MODEL RAM_MIB: will setup keep this context's KV
# cache in RAM, with only a 32K-token window on the GPU? Its rule: from 65536
# tokens, when the RAM (GiB) holds the model's RAM, the 8-bit cache (13 x 1056
# bytes per token, in GB) and 1 GB more. Compared in integers.
polystrata_kv_streams() {
    local ram_gb
    [[ $1 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] && (( $1 >= 65536 )) || return 1
    ram_gb=$(polystrata_model_ram_gb "$POLYSTRATA_FAMILY" "$2")
    [[ -n $ram_gb ]] || return 1
    (( $3 * 1000000000 >= 1024 * ((ram_gb + 1) * 1000000000 + $1 * 13728) ))
}
# polystrata_kv_recommendation VRAM_MIB [CONTEXT MODEL RAM_MIB]: VALUE|REASON, the
# KV cache to suggest on the Strata engine (the OSR installer suggests the same). When the cache is
# streamed to RAM (polystrata_kv_streams), int8: the GPU holds only a 32K window,
# so the most precise cache costs it about 0.1 GB more than k8v4. Otherwise by
# the card: below 24 GB (12 and 16 GB cards) k8v4, whose 23% smaller cache
# leaves room for more of the model on the GPU (about 700 experts per GB
# freed) and reads long documents better than q4_0; on 24 and 32 GB cards,
# and on an unknown card, int8, the Strata engine's default.
polystrata_kv_recommendation() {
    if polystrata_kv_streams "${2:-}" "${3:-}" "${4:-}"; then
        echo "int8|at this context the cache is kept in the CT's RAM with only a 32K window on the GPU"
    elif [[ ! $1 =~ ^[0-9]+$ ]]; then
        echo "int8|the GPU's memory is not known; int8 is the Strata engine's default"
    elif (( $1 >= 24000 )); then
        echo "int8|its $1 MiB GPU has room for the most precise cache"
    else
        echo "k8v4|its $1 MiB GPU fits more of the model with a 23% smaller cache"
    fi
}
# valid_polystrata_kv VALUE: one of the chosen family's formats (families.sh).
valid_polystrata_kv() { [[ " $(polystrata_kv_choices "$POLYSTRATA_FAMILY") " == *" $1 "* ]]; }

# polystrata_menu_select VARIABLE HEADING NOUN DEFAULT VALIDATOR ROWS: the
# shared target_model_select menu (ROWS are ID|description lines) with its own
# heading and prompt, for the family and the size questions. A preset
# VARIABLE skips it; unattended runs take DEFAULT.
polystrata_menu_select() {
    local variable=$1 heading=$2 noun=$3 default=$4 validator=$5 rows=$6
    local answer id description index=0 found
    [[ -z ${!variable:-} ]] || return 0
    if pve_asks; then
        pve_section "$heading"
        while IFS='|' read -r id description; do
            [[ -n $id ]] || continue
            index=$((index + 1))
            pve_note "  $index) $id${description:+ - $description}"
        done <<< "$rows"
        pve_note "Enter a number or $noun name. The guest checks it against its pinned checkout."
        _pve_heading
        while true; do
            printf '  PolyStrata %s [Enter: %s]: ' "$noun" "$default" >&2
            IFS= read -r answer || { printf '\n' >&2; return 1; }
            [[ -n $answer ]] || answer=$default
            if [[ $answer =~ ^[0-9]+$ ]]; then
                index=0 found=false
                while IFS='|' read -r id description; do
                    [[ -n $id ]] || continue
                    index=$((index + 1))
                    if [[ $answer == "$index" ]]; then answer=$id; found=true; break; fi
                done <<< "$rows"
                if [[ $found == false ]]; then
                    printf '    Choose a number from the list.\n' >&2
                    continue
                fi
            fi
            if "$validator" "$answer"; then break; fi
            printf '    Choose a listed number or a valid %s name.\n' "$noun" >&2
        done
    else
        answer=$default
    fi
    printf -v "$variable" '%s' "$answer"
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
CT_HOSTNAME=${CT_HOSTNAME:-polystrata-target}
BRIDGE=${BRIDGE:-vmbr0}
CORES=${CORES:-8}
MEMORY_MB=${MEMORY_MB:-65536}
SWAP_MB=${SWAP_MB:-0}
ROOTFS_GB=${ROOTFS_GB:-160}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY:-}
if [[ -z ${GPU_DEVICES:-} ]]; then
    GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
    # Optional: only some driver setups create it, and nothing here needs it.
    [[ -c /dev/nvidia-uvm-tools ]] && GPU_DEVICES+=' /dev/nvidia-uvm-tools'
fi
# The PolyStrata service runs as an unprivileged account that joins this group, so
# the nodes must not be root's group inside the CT.
GPU_GID=${GPU_GID:-44}
NVIDIA_DRIVER_VERSION=${NVIDIA_DRIVER_VERSION:-auto}
# Pin an unconfigured install to the source used by the upstream regression
# test. An explicit ref, or an explicitly empty commit, opts into branch tips.
POLYSTRATA_DEFAULT_COMMIT=36e654b1b7eb4cb462202445be296ba012c75edf
if [[ ! ${POLYSTRATA_COMMIT+x} && ! ${POLYSTRATA_REF+x} ]]; then
    POLYSTRATA_COMMIT=$POLYSTRATA_DEFAULT_COMMIT
else
    POLYSTRATA_COMMIT=${POLYSTRATA_COMMIT:-}
fi
POLYSTRATA_REF=${POLYSTRATA_REF:-main}
POLYSTRATA_FAMILY=${POLYSTRATA_FAMILY:-}
POLYSTRATA_MODEL=${POLYSTRATA_MODEL:-}
POLYSTRATA_CONTEXT=${POLYSTRATA_CONTEXT:-65536}
POLYSTRATA_PARALLEL=${POLYSTRATA_PARALLEL:-1}
POLYSTRATA_KV=${POLYSTRATA_KV:-}
POLYSTRATA_MESSAGE_CACHE=${POLYSTRATA_MESSAGE_CACHE:-}
POLYSTRATA_VISION=${POLYSTRATA_VISION:-no}
POLYSTRATA_PORT=${POLYSTRATA_PORT:-8080}
POLYSTRATA_READY_TIMEOUT=${POLYSTRATA_READY_TIMEOUT:-900}
POLYSTRATA_ALLOW_NO_KEY=${POLYSTRATA_ALLOW_NO_KEY:-false}

# --- Questions: the container, one section ----------------------------------
valid_template_volume() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/[A-Za-z0-9._-]+$ ]]; }
valid_storage_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
pve_ask_new_ct PolyStrata
positive_int ROOTFS_GB "$ROOTFS_GB"
if pve_interactive && (( ! dry_run )); then _pve_heading; fi
pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
pve_select_storage STORAGE rootdir "$ROOTFS_GB"
pve_suggest TEMPLATE 'Ubuntu 22.04/24.04 or Debian 12/13 amd64 template' '' valid_template_volume 'Use a downloaded LXC template volume (storage:vztmpl/...).'
pve_suggest STORAGE 'Root disk storage' '' valid_storage_id
pve_ask_network PolyStrata dhcp
# Family, then size. A preset POLYSTRATA_FAMILY or POLYSTRATA_MODEL skips its
# menu; the guest checks both against the pinned checkout's setup.sh.
valid_polystrata_menu_family() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }
valid_polystrata_menu_model() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
polystrata_menu_select POLYSTRATA_FAMILY 'PolyStrata model family' family qwen valid_polystrata_menu_family \
    "$(polystrata_menu_families)" || die 'Family selection cancelled.'
if [[ -z $POLYSTRATA_MODEL ]]; then
    polystrata_model_default=$(polystrata_family_default "$POLYSTRATA_FAMILY") ||
        die "families.sh has no sizes for POLYSTRATA_FAMILY=$POLYSTRATA_FAMILY; set POLYSTRATA_MODEL too."
    polystrata_menu_select POLYSTRATA_MODEL "PolyStrata $POLYSTRATA_FAMILY size" size "$polystrata_model_default" \
        valid_polystrata_menu_model "$(polystrata_menu_models "$POLYSTRATA_FAMILY")" || die 'Model selection cancelled.'
fi
polystrata_engine=$(polystrata_family_engine "$POLYSTRATA_FAMILY" || true)

[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] || die 'CT_ID must be an unused numeric ID of 100 or more.'
[[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/(ubuntu-(22\.04|24\.04)|debian-(12|13))-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] || \
    die 'TEMPLATE must be a downloaded Ubuntu 22.04/24.04 or Debian 12/13 amd64 LXC template.'
[[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'STORAGE must be a Proxmox rootdir storage ID.'
valid_ip_cidr "$IP_CIDR" || die 'IP_CIDR must be dhcp or a valid IPv4 address/CIDR.'
if [[ $IP_CIDR != dhcp ]]; then ipv4 "$GATEWAY" || die 'GATEWAY must be a valid IPv4 address for a static IP.'; fi
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'CT_HOSTNAME must be a DNS label.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
for name in CORES MEMORY_MB ROOTFS_GB POLYSTRATA_CONTEXT; do positive_int "$name" "${!name}"; done
(( MEMORY_MB >= 16384 )) || die 'MEMORY_MB must be at least 16384 for PolyStrata.'
(( ROOTFS_GB >= 60 )) || die 'ROOTFS_GB must be at least 60 for PolyStrata model downloads.'
if [[ $POLYSTRATA_FAMILY == unsloth && $POLYSTRATA_MODEL == Q8_0 ]] && (( ROOTFS_GB < 200 )); then
    die 'Unsloth Q8_0 downloads about 188 GB before setup overhead; set ROOTFS_GB to at least 200.'
fi
polystrata_ram_gb=$(polystrata_model_ram_gb "$POLYSTRATA_FAMILY" "$POLYSTRATA_MODEL")
if [[ -n $polystrata_ram_gb ]] && (( MEMORY_MB < polystrata_ram_gb * 1000 * 1000 / 1024 )); then
    printf 'Warning: %s %s wants about %s GB of RAM by setup'"'"'s estimate and the CT gets %s MiB; setup may page experts from disk or refuse it.\n' \
        "$POLYSTRATA_FAMILY" "$POLYSTRATA_MODEL" "$polystrata_ram_gb" "$MEMORY_MB" >&2
fi
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ ]] || die 'SWAP_MB must be a nonnegative integer.'
[[ $ONBOOT =~ ^[01]$ ]] || die 'ONBOOT must be 0 or 1.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be one IPv4 address.'
if [[ -n $VLAN_TAG ]]; then positive_int VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be 1..4094.'; fi
[[ -z $SSH_PUBLIC_KEY || -r $SSH_PUBLIC_KEY ]] || die 'SSH_PUBLIC_KEY must be a readable file.'
[[ $GPU_GID =~ ^[1-9][0-9]{0,4}$ ]] && (( GPU_GID <= 65535 )) || die 'GPU_GID must be a non-root group ID (1..65535).'
[[ $NVIDIA_DRIVER_VERSION == auto || $NVIDIA_DRIVER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid NVIDIA_DRIVER_VERSION.'
[[ $NVIDIA_DRIVER_VERSION == auto ]] || nvidia_lxc_require_series "$NVIDIA_DRIVER_VERSION" 580 'CUDA 13'
[[ $POLYSTRATA_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $POLYSTRATA_REF != HEAD && $POLYSTRATA_REF != *..* ]] || die 'POLYSTRATA_REF must be a branch or tag name.'
[[ -z $POLYSTRATA_COMMIT || $POLYSTRATA_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'POLYSTRATA_COMMIT must be a full 40-digit SHA-1.'
[[ $POLYSTRATA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid POLYSTRATA_MODEL.'
[[ $POLYSTRATA_FAMILY =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || die 'POLYSTRATA_FAMILY must be a family name such as qwen, glm or qwen36 (the guest checks it against setup.sh).'
[[ $POLYSTRATA_VISION =~ ^(yes|no|gpu|cpu)$ ]] || die 'POLYSTRATA_VISION must be yes, no, gpu, or cpu.'
[[ $POLYSTRATA_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( POLYSTRATA_PORT <= 65535 )) || die 'POLYSTRATA_PORT must be 1..65535.'
[[ $POLYSTRATA_PARALLEL =~ ^[1-8]$ ]] || die 'POLYSTRATA_PARALLEL must be 1 to 8.'
[[ $POLYSTRATA_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'POLYSTRATA_READY_TIMEOUT must be a positive number of seconds.'
[[ $POLYSTRATA_ALLOW_NO_KEY =~ ^(true|false)$ ]] || die 'POLYSTRATA_ALLOW_NO_KEY must be true or false.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Where to send a host without an NVIDIA driver (the router installer runs it too).
gpu_hint=" Without an NVIDIA driver on this host, run: bash ${source_dir%/*/*}/tools/setup-host-gpu.sh"
for file in install-target.sh polystrata.service families.sh; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
NVIDIA_GUEST_INSTALLER=${NVIDIA_GUEST_INSTALLER:-$source_dir/../../tools/install-nvidia-driver.sh}
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

# --- Questions: PolyStrata settings -----------------------------------------
# The KV cache formats depend on the family's engine (families.sh).
polystrata_kv_formats=$(polystrata_kv_choices "$POLYSTRATA_FAMILY")
if [[ -n $POLYSTRATA_KV ]]; then
    :
elif [[ $polystrata_engine == strata ]] && (( POLYSTRATA_CONTEXT <= 8192 )); then
    POLYSTRATA_KV=auto   # the Strata engine keeps a 16-bit cache up to 8192 tokens: nothing to choose.
elif [[ $polystrata_engine == strata ]]; then
    IFS='|' read -r kv_suggestion kv_reason <<< "$(polystrata_kv_recommendation "$(polystrata_gpu_vram_mib "${devices[@]}")" \
        "$POLYSTRATA_CONTEXT" "$POLYSTRATA_MODEL" "$MEMORY_MB")"
    pve_section 'PolyStrata settings'
    pve_note 'KV cache: how the Strata engine stores the text it is working on (its context).'
    pve_note "  int8  8-bit keys and values: the most precise, the engine's default"
    pve_note '  k8v4  8-bit keys, 4-bit values: 23% smaller, more of the model fits on the GPU'
    pve_note '  q4_0  4-bit keys and values: 45% smaller, less precise on long documents'
    pve_note 'Suggested: k8v4 for 12 GB and 16 GB cards, int8 for 24 GB and 32 GB cards;'
    pve_note '  int8 on any card when the cache fits in the CT'"'"'s RAM (from a 64K context).'
    pve_note "This CT: $kv_suggestion ($kv_reason)."
    pve_ask POLYSTRATA_KV 'KV cache (int8, k8v4 or q4_0)' "$kv_suggestion" valid_polystrata_kv 'Choose int8, k8v4 or q4_0.'
elif [[ $polystrata_kv_formats == 'auto fp16' || $polystrata_kv_formats == auto ]]; then
    POLYSTRATA_KV=auto   # this family's engine has only its 16-bit cache: nothing to choose.
else
    pve_section 'PolyStrata settings'
    pve_note "KV cache: how PolyStrata's engine stores the $POLYSTRATA_FAMILY family's context."
    pve_note '  auto  16-bit (fp16), the engine'"'"'s default and the most precise'
    pve_note "  other formats for this family: ${polystrata_kv_formats#auto fp16 } (smaller, a little less precise)"
    pve_ask POLYSTRATA_KV "KV cache (${polystrata_kv_formats// /, })" auto valid_polystrata_kv \
        "Choose one of: ${polystrata_kv_formats// /, }."
fi
valid_polystrata_kv "$POLYSTRATA_KV" ||
    die "POLYSTRATA_KV=$POLYSTRATA_KV does not fit the $POLYSTRATA_FAMILY family; choose one of: $polystrata_kv_formats."
if [[ -n $POLYSTRATA_MESSAGE_CACHE ]]; then
    :
elif [[ $polystrata_engine != strata ]] || (( POLYSTRATA_CONTEXT <= 8192 )); then
    # A Strata-engine checkpoint, and only for prompts of 8192 tokens or more.
    POLYSTRATA_MESSAGE_CACHE=false
else
    pve_section 'PolyStrata settings'
    pve_note 'Message cache: one more checkpoint before the last message of a long'
    pve_note '  conversation (8192+ tokens), so an agent that rewrites its last message does'
    pve_note '  not make the engine read the history again. Off upstream by default: it adds'
    pve_note '  about 0.2 s to a fresh long request.'
    pve_ask_yes_no POLYSTRATA_MESSAGE_CACHE 'Message cache for agents that rewrite their last message' false
fi
[[ $POLYSTRATA_MESSAGE_CACHE =~ ^(true|false)$ ]] || die 'POLYSTRATA_MESSAGE_CACHE must be true or false.'
[[ $POLYSTRATA_MESSAGE_CACHE == false || $polystrata_engine == strata ]] ||
    die "POLYSTRATA_MESSAGE_CACHE=true is a Strata-engine setting; the $POLYSTRATA_FAMILY family runs on another engine."

ostype=debian
[[ $TEMPLATE == *:vztmpl/ubuntu-* ]] && ostype=ubuntu
net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,firewall=1"
[[ -z $GATEWAY || $IP_CIDR == dhcp ]] || net+=",gw=$GATEWAY"
[[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype "$ostype"
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT" --tags 'ai;ai-model;osr-target;polystrata'
    --description "PolyStrata inference target; OpenAI API on TCP $POLYSTRATA_PORT")
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
    if ! pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null; then
        if pct status "$CT_ID" >/dev/null 2>&1; then
            die "CT $CT_ID already exists. This script only creates new PolyStrata CTs; resume or upgrade it with: pct exec $CT_ID -- bash /root/polystrata-target-deploy/install-target.sh"
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
    host_driver=$(nvidia_lxc_host_version) || die 'Cannot determine the loaded NVIDIA driver version on this Proxmox host.'
    [[ $NVIDIA_DRIVER_VERSION == auto || $host_driver == "$NVIDIA_DRIVER_VERSION" ]] ||
        die "Host NVIDIA driver is $host_driver; expected $NVIDIA_DRIVER_VERSION."
    NVIDIA_DRIVER_VERSION=$host_driver
    nvidia_lxc_require_series "$NVIDIA_DRIVER_VERSION" 580 'CUDA 13'
else
    [[ $NVIDIA_DRIVER_VERSION != auto ]] || NVIDIA_DRIVER_VERSION='<host-nvidia-driver-version>'
fi

trap 'printf "Provisioning stopped at line %s. CT %s is kept for inspection.\n" "$LINENO" "$CT_ID" >&2' ERR
pve_summary "PolyStrata: create"
pve_row 'PolyStrata CT' "$CT_ID ($CT_HOSTNAME), $CORES cores, ${MEMORY_MB} MiB, ${ROOTFS_GB} GiB on $STORAGE"
pve_row 'Template' "$TEMPLATE"
pve_row 'Network' "$IP_CIDR${GATEWAY:+ via $GATEWAY} on $BRIDGE${VLAN_TAG:+ (VLAN $VLAN_TAG)}"
pve_row 'Model' "$POLYSTRATA_FAMILY $POLYSTRATA_MODEL ($( polystrata_family_title "$POLYSTRATA_FAMILY" 2>/dev/null || printf 'not in families.sh' ))${polystrata_ram_gb:+, about $polystrata_ram_gb GB of RAM}"
pve_row 'Server' "context $POLYSTRATA_CONTEXT, parallel $POLYSTRATA_PARALLEL, KV cache $POLYSTRATA_KV, message cache $POLYSTRATA_MESSAGE_CACHE, port $POLYSTRATA_PORT"
pve_confirm "Create PolyStrata CT $CT_ID?"
(umask 022; run "${create[@]}")
# PolyStrata pins tens of GiB of model memory. systemd's LimitMEMLOCK must be
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
            printf 'Warning: CT %s sees %s with gid %s and mode %s although --dev%s requests gid %s and mode 0660. The guest installer will check access as the polystrata account.\n' \
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
run pct exec "$CT_ID" -- install -d -m 0700 /root/polystrata-target-deploy
run pct push "$CT_ID" "$source_dir/install-target.sh" /root/polystrata-target-deploy/install-target.sh --perms 0755
run pct push "$CT_ID" "$source_dir/polystrata.service" /root/polystrata-target-deploy/polystrata.service --perms 0644
run pct push "$CT_ID" "$source_dir/families.sh" /root/polystrata-target-deploy/families.sh --perms 0644
run pct push "$CT_ID" "$NVIDIA_GUEST_INSTALLER" /root/polystrata-target-deploy/nvidia-guest-install.sh --perms 0755
nvidia_lxc_install_guest "$CT_ID" "$NVIDIA_DRIVER_VERSION" /root/polystrata-target-deploy/nvidia-guest-install.sh
run pct exec "$CT_ID" -- env "POLYSTRATA_REF=$POLYSTRATA_REF" "POLYSTRATA_COMMIT=$POLYSTRATA_COMMIT" \
    "POLYSTRATA_MODEL=$POLYSTRATA_MODEL" "POLYSTRATA_FAMILY=$POLYSTRATA_FAMILY" \
    "POLYSTRATA_CONTEXT=$POLYSTRATA_CONTEXT" "POLYSTRATA_PARALLEL=$POLYSTRATA_PARALLEL" "POLYSTRATA_KV=$POLYSTRATA_KV" "POLYSTRATA_MESSAGE_CACHE=$POLYSTRATA_MESSAGE_CACHE" \
    "POLYSTRATA_VISION=$POLYSTRATA_VISION" "POLYSTRATA_PORT=$POLYSTRATA_PORT" \
    "POLYSTRATA_READY_TIMEOUT=$POLYSTRATA_READY_TIMEOUT" "POLYSTRATA_ALLOW_NO_KEY=$POLYSTRATA_ALLOW_NO_KEY" \
    bash /root/polystrata-target-deploy/install-target.sh

printf '\nPolyStrata target CT %s: API port %s. Read its generated key with:\n' "$CT_ID" "$POLYSTRATA_PORT"
printf '  pct exec %s -- cat /etc/polystrata-target/api-key\n' "$CT_ID"
printf 'Then on the router: manage-model-servers set-polystrata-token --apply, and\n'
printf '  manage-model-servers add polystrata://<CT address>:%s --apply\n' "$POLYSTRATA_PORT"
printf 'Service logs: pct exec %s -- journalctl -u polystrata -f\n' "$CT_ID"
printf 'Upgrade later: push the current install-target.sh, polystrata.service and families.sh to\n'
printf '  /root/polystrata-target-deploy in the CT, then run it there with --upgrade.\n'
