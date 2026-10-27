#!/usr/bin/env bash
# Run on the Proxmox host, as root, before creating GPU targets. The router
# installer runs it when GPU targets are selected; run it by hand before a
# GPU target's provision-lxc.sh on a host without a GPU driver.
set -Eeuo pipefail

usage() {
    cat <<'USAGE'
Usage: bash tools/setup-host-gpu.sh [--dry-run] [--need required|optional]
                                    [--vendors nvidia[,amd][,intel]] [--for "<targets>"]
                                    [--allow <gen>[,<gen>...]:<target>]... [--card <pci address>]
       bash tools/setup-host-gpu.sh --list [--vendors nvidia[,amd][,intel]]

Makes sure the host has a working driver for the GPU the targets will use. When
one is already working, it only reports it. Otherwise it lists the GPUs on the
PCI bus, asks which generation the card is (the engines are built for it) and,
once confirmed, sets the driver up:

  rtx20  GeForce RTX 20 series, Quadro RTX, TITAN RTX (Turing)          NVIDIA
  rtx30  GeForce RTX 30 series, RTX A2000-A6000 (Ampere)               NVIDIA
  rtx40  GeForce RTX 40 series, RTX Ada workstation cards (Ada)         NVIDIA
  rtx50  GeForce RTX 50 series, RTX PRO Blackwell (Blackwell)          NVIDIA
  rdna3  Radeon RX 7000 series, Radeon PRO W7000 (RDNA 3)              AMD
  rdna4  Radeon RX 9000 series, Radeon AI PRO R9700 (RDNA 4)           AMD
  arc-a  Arc A-series, Arc Pro A-series (Alchemist)                    Intel
  arc-b  Arc B-series, Arc Pro B-series (Battlemage)                   Intel

Other NVIDIA cards (V100, A100, H100, GTX 10, ...) work with the same driver
and are reported without a generation; only an --allow rule refuses them.

NVIDIA: installs the repository's NVIDIA driver (install_nvidia_580_173_02.sh
host, open kernel modules, DKMS), loaded at once and at every boot with the
/dev/nvidia* nodes the containers pass through. If nouveau still holds the
card, reboot and run this again.
AMD and Intel: the drivers (amdgpu, i915 for Arc A, xe for Arc B) are part of
the Proxmox kernel. This installs pve-firmware when the card's firmware is
missing, loads the driver now and at every boot, and checks the render node
(/dev/dri/renderD*) and, for AMD, /dev/kfd that the containers pass through.
A driver blacklisted in /etc/modprobe.d is reported, not changed. If the card
needs a reboot to pick up new firmware, reboot and run this again.

--need required   (default) a missing card, a declined setup or no terminal
                  to answer on is an error
--need optional   the targets also run without a GPU: those cases report
                  GPU_STATE=absent or GPU_STATE=declined and exit 0
--vendors         the GPU vendors the targets can use, in order of preference
                  (default: nvidia)
--for             the target names, for messages
--allow           generations a target accepts (e.g. rtx50:Basalt); repeatable
--card            only this card (PCI address, e.g. 0000:03:00.0, as --list
                  prints it): it must be one of the vendors, and it is the card
                  that is checked, set up and reported. Its generation comes
                  from its PCI ID when that is known, so it is not asked.
--list            print the cards of the vendors, one GPU_CARD=<address>|<vendor>|
                  <generation>|<driver in use>|<name> line each, and exit; nothing
                  is checked or changed. NVIDIA cards outside rtx20-rtx50 have an
                  empty generation; AMD and Intel cards are only listed when their
                  generation is supported.
--dry-run         show what would happen; change nothing

Environment: GPU_GENERATION=<gen> (or a model number such as 4090, 7900 XTX,
9070, A770 or B580) answers the question; INSTALL_HOST_DRIVER=yes|no answers
the consent; NVIDIA_HELPER=<path> another host/LXC NVIDIA driver helper.

Prints GPU_STATE=ready|absent|declined|planned, GPU_GENERATION, GPU_CUDA_ARCH
(NVIDIA), GPU_VENDOR, GPU_GFX (AMD, e.g. gfx1100), GPU_RENDER_NODE (AMD and
Intel), GPU_PCI (the card's PCI address, when known) and GPU_NVIDIA_MINOR (with
--card: the card's /dev/nvidia<minor>) lines on stdout; messages go to stderr. Exit status: 0, 1 on an error,
2 when the host must be rebooted before the driver can use the card.
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
run() {
    printf '+' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
    if (( ! dry_run )); then "$@" >&2; fi
}

# GPU generations, as name|vendor|label|CUDA compute capability|card match.
# NVIDIA cards match by codename (lspci shows e.g. AD102), AMD and Intel ones
# by PCI device ID: 1002:744x-749x is Navi 31-33, 1002:755x/759x Navi 48/44,
# 8086:56xx DG2 (Alchemist), 8086:e2xx Battlemage.
gpu_generations() {
    printf '%s\n' \
        'rtx20|nvidia|GeForce RTX 20 series, Quadro RTX, TITAN RTX (Turing)|75|\bTU1[0-1][0-9]\b' \
        'rtx30|nvidia|GeForce RTX 30 series, RTX A2000-A6000 (Ampere)|86|\bGA10[2-7]\b' \
        'rtx40|nvidia|GeForce RTX 40 series, RTX Ada workstation cards (Ada Lovelace)|89|\bAD10[2-7]\b' \
        'rtx50|nvidia|GeForce RTX 50 series, RTX PRO Blackwell (Blackwell)|120|\bGB20[2-7]\b' \
        'rdna3|amd|Radeon RX 7000 series, Radeon PRO W7000 (RDNA 3)||\[1002:74[4-9][0-9a-f]\]' \
        'rdna4|amd|Radeon RX 9000 series, Radeon AI PRO R9700 (RDNA 4)||\[1002:75[5-9][0-9a-f]\]' \
        'arc-a|intel|Arc A-series, Arc Pro A-series (Alchemist)||\[8086:56[0-9a-f]{2}\]' \
        'arc-b|intel|Arc B-series, Arc Pro B-series (Battlemage)||\[8086:e2[0-9a-f]{2}\]'
}
# generation_field NAME FIELD: vendor, label, arch or match of a generation.
generation_field() {
    local column
    case $2 in vendor) column=2 ;; label) column=3 ;; arch) column=4 ;; match) column=5 ;; *) return 1 ;; esac
    gpu_generations | awk -F'|' -v n="$1" -v c="$column" '$1 == n { print $c; found=1 } END { exit !found }'
}
# vendor_generations: the generations of the allowed vendors, in menu order.
vendor_generations() {
    local vendor
    for vendor in "${vendors[@]}"; do
        gpu_generations | awk -F'|' -v v="$vendor" '$2 == v { print $1 }'
    done
}
# arch_generation ARCH: the NVIDIA generation of a compute capability (89 -> rtx40).
arch_generation() { gpu_generations | awk -F'|' -v a="$1" '$2 == "nvidia" && $4 == a { print $1 }'; }
vendor_pci_id() { case $1 in nvidia) echo 10de ;; amd) echo 1002 ;; intel) echo 8086 ;; *) return 1 ;; esac; }
vendor_name() { case $1 in nvidia) echo NVIDIA ;; amd) echo 'AMD Radeon' ;; intel) echo 'Intel Arc' ;; esac; }
# vendor_phrase: "NVIDIA" or "NVIDIA, AMD Radeon or Intel Arc" for the allowed vendors.
vendor_phrase() {
    local -a names=() v
    for v in "${vendors[@]}"; do names+=("$(vendor_name "$v")"); done
    case ${#names[@]} in
        1) printf '%s' "${names[0]}" ;;
        2) printf '%s or %s' "${names[0]}" "${names[1]}" ;;
        *) printf '%s, %s or %s' "${names[0]}" "${names[1]}" "${names[2]}" ;;
    esac
}
vendor_allowed() { [[ " ${vendors[*]} " == *" $1 "* ]]; }

# normalize_generation INPUT: a generation from a menu number, a generation
# name (rtx40, 40, rdna3, arc-b) or a model number (4090, RTX 4070 Ti,
# RX 7900 XTX, W7800, 9070 XT, R9700, Arc A770, B580).
normalize_generation() {
    local value=${1,,} gen
    local prefix stripped=1
    value=${value//[[:space:]_-]/}
    while (( stripped )); do
        stripped=0
        for prefix in nvidia geforce amd radeon intel arc ai pro; do
            if [[ $value == "$prefix"?* ]]; then value=${value#"$prefix"}; stripped=1; fi
        done
    done
    if [[ $value =~ ^[1-9]$ ]]; then
        gen=$(vendor_generations | sed -n "${value}p")
        [[ -n $gen ]] && printf '%s\n' "$gen"
        return
    fi
    case $value in
        rtx[2-5]0|[2-5]0) printf 'rtx%s0\n' "${value: -2:1}" ;;
        rdna3|rdna4) printf '%s\n' "$value" ;;
        a|alchemist) echo arc-a ;;
        b|battlemage) echo arc-b ;;
        *)
            if [[ $value =~ ^(rtx)?([2-5])0([0-9]{2})(ti|super|tisuper)?$ ]]; then
                printf 'rtx%s0\n' "${BASH_REMATCH[2]}"
            elif [[ $value =~ ^(rx)?w?7[0-9]{3}(xtx|xt|gre|s)?$ ]]; then
                echo rdna3
            elif [[ $value =~ ^(rx)?9[0-9]{3}(xtlp|xt|gre|lp)?$ || $value =~ ^r9[0-9]{3}d?$ ]]; then
                echo rdna4
            elif [[ $value =~ ^a[0-9]{2,3}m?$ ]]; then
                echo arc-a
            elif [[ $value =~ ^b[0-9]{2,3}$ ]]; then
                echo arc-b
            else
                return 1
            fi ;;
    esac
}

# pci_gpus: the display controllers of the allowed vendors (lspci -Dnnk lines,
# with the "Kernel driver in use" line folded in as {driver}). Empty without lspci.
pci_gpus() {
    local ids='' v
    command -v lspci >/dev/null 2>&1 || return 0
    for v in "${vendors[@]}"; do ids+="${ids:+|}$(vendor_pci_id "$v")"; done
    lspci -Dnnk 2>/dev/null | awk -v ids="$ids" '
        /^[0-9a-f]/ {
            if (line != "") print line
            line = ($0 ~ /\[03(00|02|80)\]/ && $0 ~ ("\\[(" ids "):[0-9a-f][0-9a-f][0-9a-f][0-9a-f]\\]")) ? $0 : ""
            next
        }
        line != "" && /Kernel driver in use:/ { sub(/.*Kernel driver in use:[[:space:]]*/, ""); line = line " {" $0 "}" }
        END { if (line != "") print line }' | {
        # --card: only that card's line.
        if [[ -z $card_filter ]]; then
            cat
        else
            while IFS= read -r line; do
                [[ $(card_address "$line") != "$card_filter" ]] || printf '%s\n' "$line"
            done
        fi
    }
}
# normalize_pci_address ADDRESS: 0000:03:00.0 for 03:00.0 or 0000:03:00.0 (any case).
normalize_pci_address() {
    local address=${1,,}
    [[ $address =~ ^([0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || return 1
    [[ $address == *:*:* ]] || address=0000:$address
    printf '%s\n' "$address"
}
# card_name LINE: the card's name without the class, vendor company, IDs and
# driver ("AMD Radeon Navi 31 [Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M]").
card_name() {
    local name=${1#*]: }
    name=$(sed -E 's/ \{[^}]*\}$//; s/ \(rev [0-9a-f]+\)//; s/ \[[0-9a-f]{4}:[0-9a-f]{4}\]//;
        s/^(NVIDIA Corporation|Advanced Micro Devices, Inc\. \[AMD\/ATI\]|Intel Corporation) //' <<< "$name")
    printf '%s %s\n' "$(vendor_name "$(card_vendor "$1")")" "$name"
}
# list_cards: the GPU_CARD lines of --list: every NVIDIA card, and the AMD and
# Intel cards of a supported generation.
list_cards() {
    local line gen vendor
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        vendor=$(card_vendor "$line")
        gen=$(card_generation "$line")
        [[ $vendor == nvidia || -n $gen ]] || continue
        printf 'GPU_CARD=%s|%s|%s|%s|%s\n' "$(card_address "$line")" "$vendor" "$gen" \
            "$(card_driver "$line" || true)" "$(card_name "$line")"
    done <<< "$(pci_gpus)"
}
card_vendor() {
    case $1 in
        *'[10de:'*) echo nvidia ;;
        *'[1002:'*) echo amd ;;
        *'[8086:'*) echo intel ;;
    esac
}
# card_generation LINE: the generation a card belongs to, or nothing.
card_generation() {
    local name vendor match
    while IFS='|' read -r name vendor _ _ match; do
        if grep -Eq -- "$match" <<< "$1"; then printf '%s\n' "$name"; return 0; fi
    done < <(gpu_generations)
}
card_driver() { [[ $1 =~ \{([A-Za-z0-9_-]+)\}$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"; }
card_address() {
    local address=${1%% *}
    [[ $address == *:*:* ]] || address=0000:$address
    printf '%s\n' "$address"
}
# card_render_node LINE: /dev/dri/renderD<n> of a bound card (from sysfs), once
# udev has created the device node.
card_render_node() {
    local node
    for node in "$SYSFS_ROOT/bus/pci/devices/$(card_address "$1")/drm/"renderD*; do
        [[ -e $node && -e $DEV_ROOT/dri/${node##*/} ]] || continue
        printf '/dev/dri/%s\n' "${node##*/}"
        return 0
    done
    return 1
}
# card_gfx LINE: the LLVM target ROCm builds for an AMD card (gfx1100, ...).
card_gfx() {
    [[ $1 =~ \[1002:(75[5-9]|74[4-9])[0-9a-f]\] ]] || return 0
    case ${BASH_REMATCH[1]} in
        744|745) echo gfx1100 ;;
        746|747) echo gfx1101 ;;
        748|749) echo gfx1102 ;;
        755|756|757|758) echo gfx1201 ;;
        759) echo gfx1200 ;;
    esac
}
# card_usable LINE: is this card's driver bound and its device nodes present?
card_usable() {
    local driver gen
    gen=$(card_generation "$1")
    [[ -n $gen ]] || return 1
    driver=$(card_driver "$1" || true)
    case $(generation_field "$gen" vendor) in
        amd) [[ $driver == amdgpu && -e $DEV_ROOT/kfd ]] || return 1 ;;
        intel) [[ $driver == i915 || $driver == xe ]] || return 1 ;;
        *) return 1 ;;
    esac
    card_render_node "$1" >/dev/null
}

host_driver_loaded() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }
module_loaded() { grep -q "^$1 " "${PROC_MODULES:-/proc/modules}" 2>/dev/null; }
nouveau_loaded() { module_loaded nouveau; }
# nvidia_card_listed: does the loaded NVIDIA driver list the --card card?
nvidia_card_listed() {
    local bus
    while IFS=, read -r _ bus _; do
        bus=${bus//[[:space:]]/}; bus=${bus,,}
        [[ ${bus: -12} == "$card_filter" ]] && return 0
    done < <(nvidia-smi --query-gpu=index,pci.bus_id,compute_cap --format=csv,noheader 2>/dev/null)
    return 1
}
# gpu0_arch: the compute capability the driver reports (89), or nothing: GPU
# 0's, or with --card that card's.
gpu0_arch() {
    local cap='' bus c
    if [[ -n $card_filter ]]; then
        while IFS=, read -r _ bus c; do
            bus=${bus//[[:space:]]/}; bus=${bus,,}
            [[ ${bus: -12} == "$card_filter" ]] && cap=${c//[[:space:]]/}
        done < <(nvidia-smi --query-gpu=index,pci.bus_id,compute_cap --format=csv,noheader 2>/dev/null)
    else
        cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader -i 0 2>/dev/null | head -n1 | tr -d '[:space:]')
    fi
    [[ $cap =~ ^([0-9]+)\.([0-9])$ ]] && printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
# nvidia_minor: the --card card's /dev/nvidia<minor> number, from the driver's
# /proc/driver/nvidia/gpus/<address>/information.
nvidia_minor() {
    [[ -n $card_filter ]] || return 0
    sed -n 's/^Device Minor:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' \
        "$NVIDIA_PROC/gpus/$card_filter/information" 2>/dev/null | head -n1
}
# kernel_module GEN: the in-kernel driver of an AMD or Intel generation.
kernel_module() { case $1 in rdna3|rdna4) echo amdgpu ;; arc-a) echo i915 ;; arc-b) echo xe ;; *) return 1 ;; esac; }
# firmware_glob GEN: the firmware files the card loads (any one is enough).
firmware_glob() {
    case $1 in
        rdna3) echo 'amdgpu/gc_11_0_*' ;;
        rdna4) echo 'amdgpu/gc_12_0_*' ;;
        arc-a) echo 'i915/dg2_*' ;;
        arc-b) echo 'xe/bmg_*' ;;
    esac
}
firmware_present() {
    local file
    for file in $FIRMWARE_DIR/$(firmware_glob "$1"); do
        [[ -e $file ]] && return 0
    done
    return 1
}
# blacklisted_in MODULE: the modprobe.d files that blacklist MODULE.
blacklisted_in() {
    grep -lsE "^[[:space:]]*blacklist[[:space:]]+$1([[:space:]]|\$)" "$MODPROBE_DIR"/*.conf 2>/dev/null || true
}
# kernel_at_least MAJOR.MINOR: is the running kernel that new?
kernel_at_least() {
    local release=${KERNEL_RELEASE:-$(uname -r)}
    [[ $release =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    local have=$(( BASH_REMATCH[1] * 1000 + BASH_REMATCH[2] ))
    [[ $1 =~ ^([0-9]+)\.([0-9]+)$ ]]
    (( have >= BASH_REMATCH[1] * 1000 + BASH_REMATCH[2] ))
}

# nvidia_unlisted_ok ARCH: an NVIDIA card outside rtx20-rtx50 (V100, A100,
# H100, GTX 10, ...) is fine for targets that accept any generation; only an
# --allow rule needs a known generation.
nvidia_unlisted_ok() {
    (( ${#allow_rules[@]} == 0 )) && return 0
    local rule limits=''
    for rule in "${allow_rules[@]}"; do limits+="${limits:+; }${rule#*:}: ${rule%%:*}"; done
    not_usable "$nv_label's compute capability (${1:-unreadable}) is not a generation the targets accept ($limits)." absent
}

# check_allowed GEN: GEN's vendor must be allowed, and every --allow list must contain GEN.
check_allowed() {
    local rule gens target
    vendor_allowed "$(generation_field "$1" vendor)" ||
        die "$1 ($(generation_field "$1" label)) is not an option here: ${for_targets:-these targets} need $(vendor_phrase)."
    for rule in "${allow_rules[@]}"; do
        gens=${rule%%:*}; target=${rule#*:}
        [[ ",$gens," == *",$1,"* ]] ||
            die "$target needs an ${gens//,/ or } GPU ($(generation_field "${gens%%,*}" label)); this one is $1. Deselect $target, or use another GPU."
    done
}

# choose_gpu_generation SUGGESTION: ask for the generation on the terminal.
choose_gpu_generation() {
    local suggestion=$1 answer name i=0 arch last
    local -a gens
    [[ -t 0 ]] || return 1
    mapfile -t gens < <(vendor_generations)
    last=${#gens[@]}
    printf 'Which generation is the GPU? The inference engines are built for it.\n' >&2
    for name in "${gens[@]}"; do
        i=$((i + 1))
        arch=$(generation_field "$name" arch)
        if [[ -n $arch ]]; then
            printf '  %d) %-6s %s, compute capability %s.%s\n' "$i" "$name" "$(generation_field "$name" label)" "${arch:0:-1}" "${arch: -1}" >&2
        else
            printf '  %d) %-6s %s\n' "$i" "$name" "$(generation_field "$name" label)" >&2
        fi
    done
    while true; do
        read -r -p "GPU generation (1-$last, ${gens[0]}..${gens[last - 1]} or a model number like $(model_example))${suggestion:+ [$suggestion]}: " answer ||
            die 'No GPU generation was entered.'
        answer=${answer:-$suggestion}
        if [[ -n $answer ]] && GPU_GENERATION=$(normalize_generation "$answer") && [[ -n $GPU_GENERATION ]] &&
                vendor_allowed "$(generation_field "$GPU_GENERATION" vendor)"; then
            return 0
        fi
        printf '  Enter 1-%d, %s, or a model number such as %s.\n' "$last" "$(printf '%s, ' "${gens[@]}" | sed 's/, $//')" "$(model_examples)" >&2
    done
}
model_example() { vendor_allowed nvidia && echo 4090 && return; vendor_allowed amd && echo 7900 && return; echo B580; }
model_examples() {
    local -a ex=()
    vendor_allowed nvidia && ex+=(3090 5080)
    vendor_allowed amd && ex+=(7900 9070)
    vendor_allowed intel && ex+=(A770 B580)
    printf '%s' "${ex[0]}"
    (( ${#ex[@]} > 2 )) && printf ', %s' "${ex[@]:1:${#ex[@]}-2}"
    printf ' or %s' "${ex[-1]}"
}

# confirm_host_driver WHAT: INSTALL_HOST_DRIVER=yes, or a yes on the terminal.
# Returns 1 for a no (the caller decides whether that is an error).
confirm_host_driver() {
    local answer
    case $INSTALL_HOST_DRIVER in
        yes) return 0 ;;
        no) return 1 ;;
    esac
    if [[ ! -t 0 ]]; then
        [[ $need == optional ]] && return 1
        die "Set INSTALL_HOST_DRIVER=yes to set up $1 on this host without a terminal."
    fi
    read -r -p "$2 [y/N] " answer || answer=''
    [[ ${answer,,} == y || ${answer,,} == yes ]]
}

# report STATE [GEN] [ARCH] [VENDOR] [GFX] [RENDER] [PCI] [MINOR]: the
# machine-readable result on stdout (PCI defaults to --card).
report() {
    printf 'GPU_STATE=%s\nGPU_GENERATION=%s\nGPU_CUDA_ARCH=%s\nGPU_VENDOR=%s\nGPU_GFX=%s\nGPU_RENDER_NODE=%s\nGPU_PCI=%s\nGPU_NVIDIA_MINOR=%s\n' \
        "$1" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-$card_filter}" "${8:-}"
}
# report_card STATE LINE: report an AMD or Intel card.
report_card() {
    local gen
    gen=$(card_generation "$2")
    report "$1" "$gen" '' "$(generation_field "$gen" vendor)" "$(card_gfx "$2")" "$(card_render_node "$2" || true)" \
        "$(card_address "$2")"
}

# not_usable MESSAGE STATE: required targets stop here; optional ones go on without a GPU.
not_usable() {
    if [[ $need == optional ]]; then
        note "$1 ${for_targets:-The targets} will run without a GPU."
        report "$2"
        exit 0
    fi
    die "$1 An $(vendor_phrase) GPU is needed for ${for_targets:-these targets}."
}

# ready_vendor VENDOR: report a working GPU of VENDOR and succeed, or fail.
ready_vendor() {
    local line real_arch
    case $1 in
        nvidia)
            host_driver_loaded || return 1
            if [[ -n $card_filter ]] && ! nvidia_card_listed; then
                line=${gpus%%$'\n'*}
                [[ $(card_vendor "$line") == nvidia ]] || return 1
                if [[ $(card_driver "$line" || true) == vfio-pci ]]; then
                    not_usable "The GPU at $card_filter is bound to vfio-pci (reserved for VM passthrough); release it from vfio-pci and reboot to use it here." absent
                fi
                note "An NVIDIA driver is loaded, but it does not list the GPU at $card_filter ($(card_driver "$line" || echo 'no driver') holds it). Reboot this host, then run this again; nothing was changed."
                exit 2
            fi
            real_arch=$(gpu0_arch || true)
            GPU_GENERATION=$(arch_generation "$real_arch")
            note "An NVIDIA driver is loaded ($nv_label: compute capability ${real_arch:-unreadable})."
            if [[ -n $GPU_GENERATION ]]; then
                check_allowed "$GPU_GENERATION"
            else
                nvidia_unlisted_ok "$real_arch"
            fi
            report ready "$GPU_GENERATION" "$real_arch" nvidia '' '' '' "$(nvidia_minor)"
            return 0 ;;
        amd|intel)
            while IFS= read -r line; do
                [[ -n $line && $(card_vendor "$line") == "$1" ]] || continue
                card_usable "$line" || continue
                GPU_GENERATION=$(card_generation "$line")
                note "$(vendor_name "$1") GPU ready: ${line#* } ($(card_render_node "$line")$( [[ $1 != amd ]] || printf ', %s' "$DEV_ROOT/kfd"))."
                check_allowed "$GPU_GENERATION"
                report_card ready "$line"
                return 0
            done <<< "$gpus"
            return 1 ;;
    esac
}

# setup_nvidia: install the NVIDIA driver for GPU_GENERATION.
setup_nvidia() {
    local arch real_arch
    arch=$(generation_field "$GPU_GENERATION" arch)
    note "GPU generation $GPU_GENERATION: $(generation_field "$GPU_GENERATION" label), compute capability $arch."
    if (( ! dry_run )) && ! confirm_host_driver "NVIDIA $driver_version" \
            "Install NVIDIA $driver_version (open kernel modules, DKMS) on this Proxmox host now? It blacklists nouveau and may need a reboot."; then
        not_usable "No NVIDIA driver was installed (install NVIDIA $driver_version on this host yourself to use the GPU)." declined
    fi
    run env KERNEL_MODULE_TYPE=open bash "$NVIDIA_HELPER" host --no-reboot
    if (( dry_run )); then report planned "$GPU_GENERATION" "$arch" nvidia; return 0; fi
    if ! host_driver_loaded; then
        if nouveau_loaded; then
            note "NVIDIA $driver_version is installed, but nouveau still holds the GPU. Reboot this host, then run this again (GPU_GENERATION=$GPU_GENERATION); nothing else was changed."
            exit 2
        fi
        die "NVIDIA $driver_version is installed but did not load (see above). Reboot this host, then run this again."
    fi
    # The driver sees the card now: trust what it reports over the answer.
    real_arch=$(gpu0_arch || true)
    if [[ -z $real_arch ]]; then
        note "Note: $nv_label's compute capability is unreadable after installing NVIDIA $driver_version."
    elif [[ $real_arch != "$arch" ]]; then
        note "Note: $nv_label reports compute capability $real_arch, not $GPU_GENERATION's $arch; using $real_arch."
    fi
    GPU_GENERATION=$(arch_generation "$real_arch")
    arch=$real_arch
    if [[ -n $GPU_GENERATION ]]; then
        check_allowed "$GPU_GENERATION"
    else
        nvidia_unlisted_ok "$real_arch"
    fi
    note "NVIDIA $driver_version is loaded."
    report ready "$GPU_GENERATION" "$arch" nvidia '' '' '' "$(nvidia_minor)"
}

# setup_kernel_driver: firmware, the in-kernel driver and device nodes for an
# AMD or Intel GPU_GENERATION.
setup_kernel_driver() {
    local vendor module files line card='' was_loaded=0 firmware_added=0 conf
    vendor=$(generation_field "$GPU_GENERATION" vendor)
    module=$(kernel_module "$GPU_GENERATION")
    note "GPU generation $GPU_GENERATION: $(generation_field "$GPU_GENERATION" label), driver $module."
    while IFS= read -r line; do
        [[ -n $line && $(card_generation "$line") == "$GPU_GENERATION" && $(card_driver "$line" || true) != vfio-pci ]] || continue
        card=$line; break
    done <<< "$gpus"
    if [[ -z $card ]] && command -v lspci >/dev/null 2>&1; then
        not_usable "No $GPU_GENERATION card ($(generation_field "$GPU_GENERATION" label)) is on this host's PCI bus outside vfio-pci." absent
    fi
    if [[ $GPU_GENERATION == arc-b ]] && ! kernel_at_least 6.12; then
        die "Arc B-series cards need Linux 6.12 or newer (xe); this host runs ${KERNEL_RELEASE:-$(uname -r)}. Install a newer Proxmox kernel (apt install proxmox-default-kernel), reboot, then run this again."
    fi
    files=$(blacklisted_in "$module")
    if [[ -n $files ]]; then
        not_usable "$module is blacklisted in ${files//$'\n'/, } (often for VM passthrough). Remove that line, run update-initramfs -u -k all and reboot to use the card here." absent
    fi
    if (( ! dry_run )) && ! confirm_host_driver "$module for the $(vendor_name "$vendor") GPU" \
            "Set up the $module driver for this $(vendor_name "$vendor") GPU on this Proxmox host now (pve-firmware if its firmware is missing, $module loaded now and at boot)?"; then
        not_usable "The $module driver was not set up (load it on this host yourself to use the GPU)." declined
    fi
    module_loaded "$module" && was_loaded=1
    if ! firmware_present "$GPU_GENERATION"; then
        note "The firmware for $GPU_GENERATION ($FIRMWARE_DIR/$(firmware_glob "$GPU_GENERATION")) is missing; installing pve-firmware."
        run apt-get update
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y pve-firmware
        firmware_added=1
        if (( ! dry_run )) && ! firmware_present "$GPU_GENERATION"; then
            die "pve-firmware has no firmware for $GPU_GENERATION. Update this host (apt full-upgrade), reboot, then run this again."
        fi
    fi
    (( was_loaded )) || run modprobe "$module"
    # The device nodes come from udev, a moment after the driver binds.
    if (( ! dry_run )) && command -v udevadm >/dev/null 2>&1; then udevadm settle --timeout=15 || true; fi
    conf=$MODULES_LOAD_DIR/gpu-lxc.conf
    if ! grep -qsx "$module" "$conf"; then
        note "+ add $module to $conf (loaded at every boot)"
        if (( ! dry_run )); then
            install -d -m 0755 "$MODULES_LOAD_DIR"
            printf '%s\n' "$module" >> "$conf"
        fi
    fi
    if (( dry_run )); then
        if [[ -n $card ]]; then report_card planned "$card"; else report planned "$GPU_GENERATION" '' "$vendor"; fi
        return 0
    fi
    gpus=$(pci_gpus)
    while IFS= read -r line; do
        [[ -n $line && $(card_vendor "$line") == "$vendor" ]] && card_usable "$line" || continue
        if [[ $(card_generation "$line") != "$GPU_GENERATION" ]]; then
            note "Note: the card is $(card_generation "$line"), not $GPU_GENERATION; using $(card_generation "$line")."
            GPU_GENERATION=$(card_generation "$line")
            check_allowed "$GPU_GENERATION"
        fi
        note "$module is loaded: ${line#* } ($(card_render_node "$line")$( [[ $vendor != amd ]] || printf ', %s' "$DEV_ROOT/kfd"))."
        report_card ready "$line"
        return 0
    done <<< "$gpus"
    if (( was_loaded || firmware_added )); then
        note "$module could not take the card without a restart (new firmware, or the card failed to start at boot). Reboot this host, then run this again (GPU_GENERATION=$GPU_GENERATION); nothing else was changed."
        exit 2
    fi
    die "$module is loaded but the card has no render node$( [[ $vendor != amd ]] || printf ' or no %s' "$DEV_ROOT/kfd"). See dmesg | grep -i $module."
}

main() {
    local suggestion vendor line candidates='' usable=0 gen found=''
    gpus=$(pci_gpus)
    if [[ -n $card_filter && -z $gpus ]]; then
        # A card of another vendor is a wrong choice, not a missing card.
        local -a allowed=("${vendors[@]}")
        vendors=(nvidia amd intel)
        line=$(pci_gpus)
        vendors=("${allowed[@]}")
        [[ -z $line ]] ||
            die "The GPU at $card_filter is $(vendor_name "$(card_vendor "$line")"), not $(vendor_phrase)${for_targets:+ (for $for_targets)}."
    fi
    if [[ -n $card_filter && -n $gpus ]]; then
        gen=$(card_generation "$gpus")
        # The card's generation is known from its PCI ID: no need to ask.
        if [[ -z $GPU_GENERATION && -n $gen ]]; then GPU_GENERATION=$gen; fi
    elif [[ -n $card_filter ]] && command -v lspci >/dev/null 2>&1; then
        not_usable "No supported $(vendor_phrase) GPU is at $card_filter on this host's PCI bus." absent
    fi
    for vendor in "${vendors[@]}"; do
        ready_vendor "$vendor" && return 0
    done
    (( dry_run )) || [[ $(id -u) == 0 ]] || die 'Run as root on the Proxmox host.'
    if [[ ${vendors[*]} == nvidia ]]; then
        note "No NVIDIA driver is loaded on this host (nvidia-smi lists no GPU)."
    else
        note "No $(vendor_phrase) GPU is ready on this host."
    fi
    # Candidates: every NVIDIA card (the driver covers older ones too) and the
    # AMD and Intel cards of a known generation.
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        gen=$(card_generation "$line")
        [[ $(card_vendor "$line") == nvidia || -n $gen ]] || continue
        candidates+="$line"$'\n'
        [[ $(card_driver "$line" || true) == vfio-pci ]] && continue
        usable=1
        [[ -z $gen || ,$found, == *",$gen,"* ]] || found+="${found:+,}$gen"
    done <<< "$gpus"
    if [[ -n $candidates ]]; then
        note "$(vendor_phrase) GPUs on the PCI bus:"
        candidates=${candidates%$'\n'}
        note "  ${candidates//$'\n'/$'\n'  }"
        if (( ! usable )); then
            not_usable "The GPU is bound to vfio-pci (reserved for VM passthrough); release it from vfio-pci and reboot to use it here." absent
        fi
    elif command -v lspci >/dev/null 2>&1; then
        if [[ ${vendors[*]} == nvidia ]]; then
            not_usable "No NVIDIA GPU is on this host's PCI bus (lspci -d 10de:)." absent
        fi
        not_usable "No supported $(vendor_phrase) GPU is on this host's PCI bus." absent
    fi
    [[ $found == *,* ]] || suggestion=$found
    if [[ -z $GPU_GENERATION ]] && ! choose_gpu_generation "${suggestion:-}"; then
        if (( dry_run )); then
            note "+ ask for the GPU generation ($(vendor_generations | paste -sd, - | sed 's/,\([^,]*\)$/ or \1/; s/,/, /g')${suggestion:+; suggested: $suggestion}), then set up its driver"
            report planned "${suggestion:-}" "$( [[ -z ${suggestion:-} ]] || generation_field "$suggestion" arch)" \
                "$( [[ -z ${suggestion:-} ]] || generation_field "$suggestion" vendor)"
            return 0
        fi
        [[ $need == optional ]] && not_usable 'No GPU generation was given (GPU_GENERATION) and there is no terminal to ask on.' declined
        die "No terminal to ask the GPU generation on: set GPU_GENERATION=$(vendor_generations | paste -sd'|' -) and INSTALL_HOST_DRIVER=yes to set the driver up unattended."
    fi
    check_allowed "$GPU_GENERATION"
    if [[ $(generation_field "$GPU_GENERATION" vendor) == nvidia ]]; then
        setup_nvidia
    else
        setup_kernel_driver
    fi
}

dry_run=0
list_only=0
card_filter=''
need=required
for_targets=''
allow_rules=()
vendors=(nvidia)
gpus=''
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        --need) [[ ${2:-} =~ ^(required|optional)$ ]] || die '--need takes required or optional.'; need=$2; shift ;;
        --vendors)
            [[ ${2:-} =~ ^(nvidia|amd|intel)(,(nvidia|amd|intel))*$ ]] || die '--vendors takes nvidia, amd and/or intel, comma-separated.'
            IFS=, read -r -a vendors <<< "$2"; shift ;;
        --for) for_targets=${2:-}; shift ;;
        --card) card_filter=$(normalize_pci_address "${2:-}") || die '--card takes a PCI address such as 0000:03:00.0.'; shift ;;
        --list) list_only=1 ;;
        --allow)
            [[ ${2:-} =~ ^([a-z0-9-]+(,[a-z0-9-]+)*):[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]] ||
                die '--allow takes <gen>[,<gen>...]:<target>, e.g. rtx50:Basalt.'
            for gen in ${BASH_REMATCH[1]//,/ }; do
                generation_field "$gen" vendor >/dev/null || die "--allow: unknown GPU generation $gen."
            done
            allow_rules+=("$2"); shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
GPU_GENERATION=${GPU_GENERATION:-}
INSTALL_HOST_DRIVER=${INSTALL_HOST_DRIVER:-}
SYSFS_ROOT=${SYSFS_ROOT:-/sys}
DEV_ROOT=${DEV_ROOT:-/dev}
FIRMWARE_DIR=${FIRMWARE_DIR:-/lib/firmware}
MODPROBE_DIR=${MODPROBE_DIR:-/etc/modprobe.d}
MODULES_LOAD_DIR=${MODULES_LOAD_DIR:-/etc/modules-load.d}
NVIDIA_PROC=${NVIDIA_PROC:-/proc/driver/nvidia}
nv_label='GPU 0'
[[ -z $card_filter ]] || nv_label="The GPU at $card_filter"
if (( list_only )); then list_cards; exit 0; fi
if [[ -n $GPU_GENERATION ]]; then
    GPU_GENERATION=$(normalize_generation "$GPU_GENERATION") && [[ -n $GPU_GENERATION ]] ||
        die "GPU_GENERATION must be $(vendor_generations | paste -sd, - | sed 's/,\([^,]*\)$/ or \1/; s/,/, /g') (or a model number such as $(model_examples))."
    vendor_allowed "$(generation_field "$GPU_GENERATION" vendor)" ||
        die "GPU_GENERATION: $GPU_GENERATION ($(generation_field "$GPU_GENERATION" label)) is not an option here: ${for_targets:-these targets} need $(vendor_phrase)."
fi
[[ -z $INSTALL_HOST_DRIVER || $INSTALL_HOST_DRIVER =~ ^(yes|no)$ ]] || die 'INSTALL_HOST_DRIVER must be yes or no.'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
driver_version=''
if vendor_allowed nvidia; then
    NVIDIA_HELPER=${NVIDIA_HELPER:-$here/../install_nvidia_580_173_02.sh}
    [[ -r $NVIDIA_HELPER ]] || die "Missing NVIDIA driver helper: $NVIDIA_HELPER"
    driver_version=$(sed -n 's/^DRIVER_VERSION="\([0-9.]*\)"$/\1/p' "$NVIDIA_HELPER" | head -n1)
    [[ -n $driver_version ]] || die "$NVIDIA_HELPER names no DRIVER_VERSION."
fi
main
