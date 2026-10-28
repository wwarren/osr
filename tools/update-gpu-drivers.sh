#!/usr/bin/env bash
# Run on the Proxmox host, as root. Checks the GPU drivers of the host and of
# every container a GPU is passed through to, finds the newest compatible
# release of each, shows a plan, asks, and updates what was chosen.
# tools/setup-host-gpu.sh sets a GPU up the first time; this keeps it current.
set -Eeuo pipefail

usage() {
    cat <<'USAGE'
Usage: bash tools/update-gpu-drivers.sh [--check] [--yes] [--nvidia <choice>]
                                        [--ct <id>[,<id>...]] [--include-stopped]
                                        [--no-probe] [--no-refresh] [--dry-run]

Checks the GPU drivers of this Proxmox host and of every LXC container that a
GPU is passed through to (/dev/nvidia*, /dev/dri/*, /dev/kfd in its config),
finds the newest compatible release of each, shows a plan, asks, and updates
what was chosen. Run it as root on the host once tools/setup-host-gpu.sh has
set the GPU up.

NVIDIA     The host's kernel driver and the user-space libraries in every
           container must be the same release. The candidates come from
           NVIDIA's archive (download.nvidia.com): the newest release of the
           installed branch, the newest production release and the newest
           release overall (a new feature branch). Cards older than Turing
           (compute capability below 7.5: Maxwell, Pascal, Volta) stay on the
           580 branch, the last that supports them. Before anything changes,
           the chosen release is downloaded and checked: its SHA-256, its list
           of supported GPUs (every card here, with open kernel modules when
           those are in use) and a test build of its kernel modules against
           the running kernel and the newest installed one. The update stops
           the containers that use the GPU, replaces the host driver (DKMS),
           loads it without a reboot when the old modules can be unloaded,
           installs the same release's user-space libraries in each container
           (install-nvidia-driver.sh lxc) and restarts them. Every NVIDIA
           container is checked first, before anything is downloaded: Debian's
           apt NVIDIA packages are replaced with the .run libraries (the same
           cleanup the provisioners use), but a container that cannot be
           checked, does not see the host driver, or has apt NVIDIA packages
           that cleanup does not remove (Ubuntu's or the CUDA repository's)
           blocks the host update. A container whose NVML or CUDA driver
           library does not match the host is offered the host's release.
AMD, Intel The kernel drivers (amdgpu, i915, xe) and their firmware are part of
           Proxmox VE, so the newest compatible ones are the pending updates
           of pve-firmware and of the running kernel series. In containers,
           Mesa (Vulkan), Intel's compute runtime and apt-installed ROCm come
           from the container's own repositories. ROCm, CUDA and PyTorch
           runtimes bundled with Ollama, ComfyUI or llama.cpp are not drivers:
           they move with the target's install-target.sh --upgrade.

Options:
  --check            report only: change nothing and ask nothing. Exit status
                     3 when updates are available
  --yes              take the recommended answer to every question
  --nvidia <choice>  the NVIDIA release, without asking: a version (also an
                     older one, to roll back), branch (newest of the installed
                     branch), production, newest, or keep
  --ct <ids>         only check and update these containers (comma-separated).
                     A new NVIDIA host release still updates every container
                     that uses the NVIDIA GPU: they must match it
  --include-stopped  start stopped GPU containers to check and update them;
                     they are stopped again afterwards
  --no-probe         skip the test build of the NVIDIA kernel modules
  --no-refresh       do not run apt-get update (host and containers)
  --dry-run          show the commands that would change something; run none
                     (package lists are still refreshed unless --no-refresh)
  -h, --help         this help

Environment: NVIDIA_HELPER (default ./install-nvidia-driver.sh),
SETUP_HOST_GPU (default ./setup-host-gpu.sh), DOWNLOAD_DIR (where NVIDIA
installers are kept, default /root), NVIDIA_BASE_URL.

Exit status: 0 done or nothing to do, 1 an error, 2 done but the host must be
rebooted, 3 (--check) updates are available.
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
heading() { printf '\n== %s\n' "$*"; }
# run CMD...: show a command that changes something, and run it unless --dry-run.
run() {
    printf '+' >&2; printf ' %q' "$@" >&2; printf '\n' >&2
    (( dry_run )) || "$@"
}
result() { RESULTS+=("$*"); }

# --- versions -------------------------------------------------------------------
valid_version() { [[ ${1:-} =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; }
version_major() { printf '%s\n' "${1%%.*}"; }
# version_gt A B: is release A newer than B?
version_gt() {
    [[ -n $1 && $1 != "$2" ]] || return 1
    [[ -z $2 ]] && return 0
    [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]
}

# --- downloads ------------------------------------------------------------------
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 -- "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=60 -- "$1"
    else
        return 1
    fi
}
download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 15 -o "$2" -- "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$2" -- "$1"
    else
        return 1
    fi
}

# --- the host -------------------------------------------------------------------
module_loaded() { grep -q "^$1 " "$PROC_MODULES" 2>/dev/null; }
running_kernel() { printf '%s\n' "${KERNEL_RELEASE:-$(uname -r)}"; }
# installed_kernels: the kernels with modules on disk, oldest first.
installed_kernels() {
    local dir
    for dir in "$MODULES_ROOT"/*; do
        [[ -d $dir/kernel ]] && printf '%s\n' "${dir##*/}"
    done | sort -V
}
kernel_series() { [[ $1 =~ ^([0-9]+\.[0-9]+) ]] && printf '%s\n' "${BASH_REMATCH[1]}"; }
kernel_has_headers() { [[ -e $MODULES_ROOT/$1/build ]]; }
# apt_versions PKG: "installed|candidate" from apt-cache policy (each may be empty).
apt_versions() {
    local -a lines
    mapfile -t lines < <(apt-cache policy "$1" 2>/dev/null |
        sed -n 's/^[[:space:]]*Installed:[[:space:]]*//p; s/^[[:space:]]*Candidate:[[:space:]]*//p')
    local inst=${lines[0]:-} cand=${lines[1]:-}
    [[ $inst != '(none)' ]] || inst=''
    [[ $cand != '(none)' ]] || cand=''
    printf '%s|%s\n' "$inst" "$cand"
}

# The NVIDIA kernel module that is loaded (empty when none), its flavour, and the
# one on disk for the running kernel (a different one waits for a reboot).
nvidia_loaded_version() {
    [[ -r $PROC_DRIVER_VERSION ]] || return 0
    sed -nE 's/.*Kernel Module( for x86_64)?[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\2/p' \
        "$PROC_DRIVER_VERSION" | head -n1
}
nvidia_loaded_type() {
    if grep -q 'Open Kernel Module' "$PROC_DRIVER_VERSION" 2>/dev/null; then echo open; else echo proprietary; fi
}
nvidia_disk_version() {
    local version
    version=$(modinfo -F version nvidia 2>/dev/null | head -n1) || version=''
    if valid_version "$version"; then printf '%s\n' "$version"; fi
}
# nvidia_apt_packages: NVIDIA driver packages installed with apt on the host.
nvidia_apt_packages() {
    dpkg-query -W -f='${Package} ${Status}\n' 'nvidia-*dkms*' 'nvidia-driver' 'nvidia-open' 'cuda-drivers*' 2>/dev/null |
        awk '$NF == "installed" { print $1 }' | paste -sd' ' - || true
}
# nvidia_install_method: run (NVIDIA's .run installer, as install-nvidia-driver.sh
# does), apt (distribution or CUDA repository packages) or unknown.
nvidia_install_method() {
    if [[ -n $(nvidia_apt_packages) ]]; then echo apt
    elif [[ -e $USR_BIN/nvidia-uninstall || -e $USR_BIN/nvidia-installer ]]; then echo run
    else echo unknown
    fi
}
# nvidia_gpus: "address|compute capability|name" for each GPU the host driver lists.
nvidia_gpus() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    local bus cap name
    nvidia-smi --query-gpu=pci.bus_id,compute_cap,name --format=csv,noheader 2>/dev/null |
        while IFS=, read -r bus cap name; do
            bus=${bus//[[:space:]]/}; bus=${bus,,}
            cap=${cap//[[:space:]]/}
            printf '%s|%s|%s\n' "${bus: -12}" "$cap" "${name# }"
        done || true
}
# pci_device_id ADDRESS: the device half of the card's PCI ID (2684 for 10de:2684).
pci_device_id() {
    lspci -n -s "$1" 2>/dev/null | awk 'NR == 1 { split($3, id, ":"); print id[2] }'
}
# nvidia_branch_cap: 580 when a card needs the last branch for Maxwell, Pascal
# and Volta (compute capability below 7.5), otherwise nothing.
nvidia_branch_cap() {
    local address cap
    for address in "${!NV_CAP[@]}"; do
        cap=${NV_CAP[$address]}
        [[ $cap =~ ^([0-9]+)\.([0-9])$ ]] || continue
        if (( BASH_REMATCH[1] * 10 + BASH_REMATCH[2] < 75 )); then echo 580; return 0; fi
    done
}

# --- containers -----------------------------------------------------------------
# ct_rows: "id|status|name" for every container.
ct_rows() {
    pct list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1 "|" $2 "|" (NF >= 3 ? $NF : "") }'
}
# ct_gpu_nodes ID: the host devices the container's current config (not its
# snapshots) passes through: devN entries and lxc.mount.entry sources.
ct_gpu_nodes() {
    local conf=$PVE_LXC_DIR/$1.conf
    [[ -r $conf ]] || return 0
    awk '/^\[/ { exit }
         /^dev[0-9]+:/ { v = $2; sub(/,.*/, "", v); print v; next }
         /^lxc\.mount\.entry:/ { print $2 }' "$conf" |
        grep -E '^/dev/(nvidia[0-9]+|nvidiactl|kfd|dri(/(renderD|card)[0-9]+)?/?)$' || true
}
# drm_vendor NODE: nvidia, amd or intel for a DRM node name (renderD128, card0).
drm_vendor() {
    local id
    id=$(cat "$SYSFS_ROOT/class/drm/$1/device/vendor" 2>/dev/null) || return 0
    case ${id,,} in
        0x10de) echo nvidia ;;
        0x1002) echo amd ;;
        0x8086) echo intel ;;
    esac
}
# ct_gpu_vendors ID: the GPU vendors passed to a container ("nvidia amd").
ct_gpu_vendors() {
    local node n nv=0 amd=0 intel=0 vendor
    local -a vendors=()
    while IFS= read -r node; do
        [[ -n $node ]] || continue
        vendors=()
        case $node in
            /dev/nvidia*) nv=1 ;;
            /dev/kfd) amd=1 ;;
            /dev/dri/renderD*|/dev/dri/card*) vendors=("$(drm_vendor "${node##*/}")") ;;
            /dev/dri|/dev/dri/)
                for n in "$SYSFS_ROOT"/class/drm/renderD*; do
                    [[ -e $n ]] && vendors+=("$(drm_vendor "${n##*/}")")
                done ;;
        esac
        for vendor in "${vendors[@]}"; do
            case $vendor in nvidia) nv=1 ;; amd) amd=1 ;; intel) intel=1 ;; esac
        done
    done < <(ct_gpu_nodes "$1")
    local -a out=()
    (( nv )) && out+=(nvidia)
    (( amd )) && out+=(amd)
    (( intel )) && out+=(intel)
    printf '%s\n' "${out[*]}"
}
ct_uses() { [[ " ${CT_VENDORS[$1]:-} " == *" $2 "* ]]; }
ct_label() {
    local label="CT $1"
    [[ -z ${CT_NAME[$1]:-} ]] || label+=" (${CT_NAME[$1]})"
    printf '%s\n' "$label"
}
ct_selected() { [[ -z $ct_filter || ",$ct_filter," == *",$1,"* ]]; }

# The GPU packages a container's apt keeps current: Mesa (Vulkan, OpenGL,
# VA-API), libdrm, Intel's compute runtime and apt-installed ROCm.
ct_apt_packages() {
    printf '%s ' mesa-vulkan-drivers libvulkan1 mesa-libgallium libgl1-mesa-dri libglx-mesa0 \
        libegl-mesa0 libgbm1 mesa-va-drivers mesa-opencl-icd libdrm2 libdrm-amdgpu1 libdrm-intel1 \
        intel-media-va-driver intel-opencl-icd libze1 libze-intel-gpu1 intel-level-zero-gpu \
        libigc2 libigdgmm12 "'rocm*'" "'hip-runtime*'" "'hsa-rocr*'"
}
# ct_probe_script: run in a container with sh (POSIX). $1: 1 to apt-get update
# first, $2: 1 to report the GPU apt packages. Prints KEY=value lines.
ct_probe_script() {
    cat <<'PROBE'
refresh=$1 apt=$2
if [ -r /etc/os-release ]; then . /etc/os-release; echo "OS=${PRETTY_NAME:-${ID:-unknown}}"; fi
libver() {
    p=$(ldconfig -p 2>/dev/null | awk -v n="$1" '$1 == n && $2 ~ /x86-64/ { print $NF; exit }')
    [ -n "$p" ] || return 0
    r=$(readlink -f "$p" 2>/dev/null) || return 0
    echo "${r##*.so.}"
}
echo "NV_USER=$(libver libnvidia-ml.so.1)"
echo "NV_CUDA_LIB=$(libver libcuda.so.1)"
echo "NV_GUEST_KERNEL=$(sed -nE 's/.*Kernel Module( for x86_64)?[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\2/p' /proc/driver/nvidia/version 2>/dev/null | head -n1)"
# The NVIDIA driver packages apt installed (not CUDA toolkits or the container toolkit).
drv=$(dpkg-query -W -f='${Package} ${Status}\n' 'libnvidia-*' libcuda1 'nvidia-*' 'cuda-drivers*' 'libnvcuvid*' \
        'libgl1-nvidia*' 'libegl-nvidia*' 'libgles-nvidia*' 'libglx-nvidia*' glx-alternative-nvidia 'xserver-xorg-video-nvidia*' 2>/dev/null |
    awk '$NF == "installed" { print $1 }' |
    grep -Ev '^(nvidia-cuda-|nvidia-container-|libnvidia-container|nvidia-cudnn|nvidia-profiler|nvidia-visual-profiler|nvidia-nsight|nvidia-opencl-dev)' |
    sort -u)
echo "NV_APT=$(echo $drv)"
# What purging the cleanup packages (targets/nvidia-lxc.sh) would remove, from
# apt's own simulation: NV_APT_LEFT stays behind, NV_APT_COLLATERAL goes too.
if [ -n "$drv" ]; then
    set --
    for package in @CLEANUP@; do
        if dpkg -s "$package" 2>/dev/null | grep -q '^Status: install ok installed$'; then set -- "$@" "$package"; fi
    done
    purged=''
    if [ "$#" -gt 0 ]; then
        if sim=$(apt-get -s purge "$@" 2>/dev/null); then
            purged=$(printf '%s\n' "$sim" | awk '$1 == "Purg" { sub(/:.*/, "", $2); print $2 }' | sort -u)
        else
            echo NV_APT_SIM=failed
        fi
    fi
    left='' extra=''
    for p in $drv; do printf '%s\n' "$purged" | grep -qx "$p" || left="$left $p"; done
    for p in $purged; do printf '%s\n' "$drv" | grep -qx "$p" || extra="$extra $p"; done
    echo "NV_APT_LEFT=${left# }"
    echo "NV_APT_COLLATERAL=${extra# }"
fi
nvcc=$(command -v nvcc 2>/dev/null || true)
if [ -z "$nvcc" ] && [ -x /usr/local/cuda/bin/nvcc ]; then nvcc=/usr/local/cuda/bin/nvcc; fi
if [ -n "$nvcc" ]; then echo "CUDA=$("$nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9][0-9.]*\),.*/\1/p' | head -n1)"; fi
for d in /root/*-target-deploy; do
    if [ -d "$d" ]; then d=${d##*/}; echo "TARGET=${d%-target-deploy}"; fi
done
if [ "$apt" = 1 ] && command -v apt-cache >/dev/null 2>&1; then
    if [ "$refresh" = 1 ]; then apt-get update -qq >/dev/null 2>&1 || echo APT_REFRESH=failed; fi
    for p in $(dpkg-query -W -f='${Package} ${Status}\n' @PACKAGES@ 2>/dev/null | awk '$NF == "installed" { print $1 }' | sort -u); do
        inst=$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)
        cand=$(apt-cache policy "$p" 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n1)
        echo "PKG=$p|$inst|$cand"
    done
fi
PROBE
}
# ct_probe ID: check a running container's GPU user space.
ct_probe() {
    local id=$1 apt=0 out line key value script
    if ct_uses "$id" amd || ct_uses "$id" intel; then apt=1; fi
    script=$(ct_probe_script)
    script=${script//@PACKAGES@/$(ct_apt_packages)}
    script=${script//@CLEANUP@/$(nvidia_lxc_guest_cleanup_packages)}
    if ! out=$(timeout "$PROBE_TIMEOUT" pct exec "$id" -- sh -c "$script" probe "$refresh" "$apt" </dev/null 2>/dev/null); then
        CT_NOTE[$id]='could not be checked (pct exec failed)'
        return 0
    fi
    CT_PROBED[$id]=1
    while IFS= read -r line; do
        key=${line%%=*}; value=${line#*=}
        case $key in
            OS) CT_OS[$id]=$value ;;
            NV_USER) if valid_version "$value"; then CT_NV_USER[$id]=$value; fi ;;
            NV_CUDA_LIB) if valid_version "$value"; then CT_NV_CUDA_LIB[$id]=$value; fi ;;
            NV_APT) CT_NV_APT[$id]=${value% } ;;
            NV_APT_LEFT) CT_NV_APT_LEFT[$id]=$value ;;
            NV_APT_COLLATERAL) CT_NV_APT_EXTRA[$id]=$value ;;
            NV_APT_SIM) CT_NV_APT_SIM[$id]=$value ;;
            NV_GUEST_KERNEL) if valid_version "$value"; then CT_NV_GUEST[$id]=$value; fi ;;
            CUDA) CT_CUDA[$id]=$value ;;
            TARGET) CT_TARGET[$id]="${CT_TARGET[$id]:+${CT_TARGET[$id]} }$value" ;;
            PKG) CT_PKGS[$id]+="$value"$'\n' ;;
            APT_REFRESH) CT_NOTE[$id]='apt-get update failed in the container' ;;
        esac
    done <<< "$out"
    return 0
}
# ct_apt_pending ID: the container's GPU packages with a newer candidate.
ct_apt_pending() {
    local pkg inst cand
    while IFS='|' read -r pkg inst cand; do
        [[ -n $pkg && -n $inst && -n $cand && $cand != '(none)' && $inst != "$cand" ]] || continue
        printf '%s\n' "$pkg"
    done <<< "${CT_PKGS[$1]:-}"
}
# nvidia_ct_apt_blocker ID: why the container's apt NVIDIA packages cannot be
# replaced with the .run libraries; nothing when they can (the guest cleanup
# removes them all, and nothing else) or there are none.
nvidia_ct_apt_blocker() {
    local id=$1
    if [[ -n ${CT_NV_APT_LEFT[$id]:-} ]]; then
        printf 'its apt NVIDIA packages %s are not ones the .run conversion removes%s\n' "${CT_NV_APT_LEFT[$id]}" \
            "$([[ -z ${CT_NV_APT_SIM[$id]:-} ]] || echo ' (apt could not simulate their removal)')"
    elif [[ -n ${CT_NV_APT_EXTRA[$id]:-} ]]; then
        printf 'removing its apt NVIDIA packages would also remove %s\n' "${CT_NV_APT_EXTRA[$id]}"
    fi
}
# nvidia_ct_blocker ID: why the container cannot follow a new host release
# (checked, sees the loaded host driver, apt packages convertible); nothing if it can.
nvidia_ct_blocker() {
    local id=$1
    if [[ ${CT_PROBED[$id]:-0} != 1 ]]; then echo 'it could not be checked'; return 0; fi
    if [[ -n $NV_LOADED && ${CT_NV_GUEST[$id]:-} != "$NV_LOADED" ]]; then
        printf "it sees NVIDIA driver %s, not the host's %s\n" "${CT_NV_GUEST[$id]:-(none)}" "$NV_LOADED"
        return 0
    fi
    nvidia_ct_apt_blocker "$id"
}
ct_start_wait() {
    run pct start "$1" || return 1
    (( dry_run )) || timeout 180 pct exec "$1" -- systemctl is-system-running --wait </dev/null >/dev/null 2>&1 || true
}
ct_stop() {
    run pct shutdown "$1" --timeout "$CT_STOP_TIMEOUT" || run pct stop "$1"
}

# --- NVIDIA releases --------------------------------------------------------------
# nvidia_releases: every Linux x86_64 release in NVIDIA's archive, oldest first.
nvidia_releases() {
    fetch "$NVIDIA_BASE_URL/" | grep -oE '(^|[^0-9.])[0-9]{3}\.[0-9]+(\.[0-9]+)?/' |
        grep -oE '[0-9]{3}\.[0-9]+(\.[0-9]+)?' | sort -uV
}
# nvidia_production: the newest production branch release (NVIDIA's latest.txt).
nvidia_production() {
    local version
    version=$(fetch "$NVIDIA_BASE_URL/latest.txt" | awk 'NR == 1 { print $1 }') || return 0
    if valid_version "$version"; then printf '%s\n' "$version"; fi
}
# cuda_floor CUDA: the oldest driver branch a CUDA toolkit runs on (CUDA's
# minor-version compatibility: 13.x needs 580, 12.x needs 525, 11.x needs 450).
cuda_floor() {
    case ${1%%.*} in
        13) echo 580 ;;
        12) echo 525 ;;
        11) echo 450 ;;
    esac
}
# cuda_blockers VERSION: the containers whose CUDA toolkit is too new for VERSION.
cuda_blockers() {
    local id floor
    for id in "${CT_IDS[@]}"; do
        [[ -n ${CT_CUDA[$id]:-} ]] || continue
        floor=$(cuda_floor "${CT_CUDA[$id]}")
        [[ -n $floor ]] && (( $(version_major "$1") < floor )) || continue
        printf '%s (CUDA %s needs the %s branch or newer)\n' "$(ct_label "$id")" "${CT_CUDA[$id]}" "$floor"
    done
}
release_label() {
    local major
    major=$(version_major "$1")
    if [[ -n $NV_PRODUCTION && $major == "$(version_major "$NV_PRODUCTION")" ]]; then
        echo 'production branch'
    elif [[ -n $NV_PRODUCTION ]] && (( major > $(version_major "$NV_PRODUCTION") )); then
        echo 'new feature branch'
    elif [[ $major == 580 ]]; then
        echo '580 branch, the last for Maxwell, Pascal and Volta'
    else
        echo "$major branch"
    fi
}
# candidate_label VERSION: release_label, plus whether it is the installed branch.
candidate_label() {
    local label
    label=$(release_label "$1")
    if [[ $label != 'production branch' && -n $NV_LOADED && $(version_major "$1") == "$(version_major "$NV_LOADED")" ]]; then
        label+='; the installed branch'
    fi
    printf '%s\n' "$label"
}
# nvidia_pick_candidates INSTALLED CAP: the newer releases to offer, from
# NV_RELEASES and NV_PRODUCTION; CAP is the highest branch the cards allow.
nvidia_pick_candidates() {
    local installed=$1 cap=$2 version allowed='' major
    while IFS= read -r version; do
        [[ -n $version ]] || continue
        major=$(version_major "$version")
        [[ -z $cap ]] || (( major <= cap )) || continue
        allowed+="$version"$'\n'
    done <<< "$NV_RELEASES"
    NV_CAND_BRANCH=$(awk -F. -v m="$(version_major "$installed")" '$1 == m' <<< "$allowed" | tail -n1)
    version_gt "$NV_CAND_BRANCH" "$installed" || NV_CAND_BRANCH=''
    NV_CAND_PRODUCTION=''
    if [[ -n $NV_PRODUCTION ]] && version_gt "$NV_PRODUCTION" "$installed" &&
            { [[ -z $cap ]] || (( $(version_major "$NV_PRODUCTION") <= cap )); }; then
        NV_CAND_PRODUCTION=$NV_PRODUCTION
    fi
    NV_CAND_NEWEST=$(sed '/^$/d' <<< "$allowed" | tail -n1)
    version_gt "$NV_CAND_NEWEST" "$installed" || NV_CAND_NEWEST=''
    [[ $NV_CAND_BRANCH != "$NV_CAND_PRODUCTION" ]] || NV_CAND_BRANCH=''
    [[ $NV_CAND_NEWEST != "$NV_CAND_PRODUCTION" && $NV_CAND_NEWEST != "$NV_CAND_BRANCH" ]] || NV_CAND_NEWEST=''
    NV_RECOMMENDED=${NV_CAND_PRODUCTION:-${NV_CAND_BRANCH:-$NV_CAND_NEWEST}}
    return 0
}
# nvidia_candidates: the offered releases, recommended first, one per line.
nvidia_candidates() {
    local version
    for version in "$NV_RECOMMENDED" "$NV_CAND_PRODUCTION" "$NV_CAND_BRANCH" "$NV_CAND_NEWEST"; do
        [[ -n $version ]] && printf '%s\n' "$version"
    done | awk '!seen[$0]++'
}
nvidia_run_file() { printf 'NVIDIA-Linux-x86_64-%s.run\n' "$1"; }
# nvidia_fetch_release VERSION: the verified installer in DOWNLOAD_DIR; sets NV_SHA256.
nvidia_fetch_release() {
    local version=$1 file url sha
    file=$(nvidia_run_file "$version")
    url=$NVIDIA_BASE_URL/$version/$file
    NV_SHA256=''
    sha=$(fetch "$url.sha256sum" | awk 'NR == 1 { print $1 }') || sha=''
    if [[ $sha =~ ^[0-9a-fA-F]{64}$ ]]; then
        NV_SHA256=${sha,,}
    elif [[ -f $DOWNLOAD_DIR/$file ]] && sh "$DOWNLOAD_DIR/$file" --check >/dev/null 2>&1; then
        warn "No SHA-256 for NVIDIA $version from $url.sha256sum; using $DOWNLOAD_DIR/$file, whose own checksum passes."
        return 0
    else
        note "NVIDIA $version is not available ($url.sha256sum could not be read)."
        return 1
    fi
    if (( dry_run )); then
        note "+ download $url into $DOWNLOAD_DIR (SHA-256 $NV_SHA256), unless it is there already"
        return 0
    fi
    mkdir -p "$DOWNLOAD_DIR"
    if [[ -f $DOWNLOAD_DIR/$file && $(sha256sum "$DOWNLOAD_DIR/$file" | cut -d' ' -f1) == "$NV_SHA256" ]]; then
        return 0
    fi
    note "Downloading $file (about 400 MB) into $DOWNLOAD_DIR..."
    rm -f -- "$DOWNLOAD_DIR/$file.part"
    if ! download "$url" "$DOWNLOAD_DIR/$file.part"; then
        rm -f -- "$DOWNLOAD_DIR/$file.part"
        note "The download of $url failed."
        return 1
    fi
    if [[ $(sha256sum "$DOWNLOAD_DIR/$file.part" | cut -d' ' -f1) != "$NV_SHA256" ]] ||
            ! sh "$DOWNLOAD_DIR/$file.part" --check >/dev/null 2>&1; then
        rm -f -- "$DOWNLOAD_DIR/$file.part"
        note "The downloaded $file failed its checksum."
        return 1
    fi
    mv -f -- "$DOWNLOAD_DIR/$file.part" "$DOWNLOAD_DIR/$file"
    chmod +x "$DOWNLOAD_DIR/$file"
}
# nvidia_supports_cards DIR TYPE: does the extracted release support every
# NVIDIA card of the host (NV_DEVIDS), with the open kernel modules for TYPE open?
nvidia_supports_cards() {
    local json
    json=$(find "$1" -name supported-gpus.json -print -quit 2>/dev/null)
    if [[ -z $json ]]; then
        warn "This release has no supported-gpus.json; its GPU support is not checked."
        return 0
    fi
    (( ${#NV_DEVIDS[@]} )) || return 0
    python3 -I - "$json" "$2" "${NV_DEVIDS[@]}" <<'PY' >&2
import json
import sys

path, kind, *wanted = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
chips = []


def walk(node):
    if isinstance(node, dict):
        if "devid" in node:
            chips.append(node)
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)


walk(data)
failed = False
for devid in wanted:
    entries = [c for c in chips if str(c.get("devid", "")).lower() == "0x" + devid.lower()]
    current = [c for c in entries if not c.get("legacybranch")]
    name = entries[0].get("name", "") if entries else ""
    label = f"10de:{devid}" + (f" ({name})" if name else "")
    if not current:
        branch = entries[0].get("legacybranch") if entries else ""
        print(f"  {label}: " + (f"only supported by the {branch} legacy branch" if branch else "not in its list of supported GPUs"))
        failed = True
    elif kind == "open" and not any("kernelopen" in (c.get("features") or []) for c in current):
        print(f"  {label}: not supported by the open kernel modules")
        failed = True
sys.exit(1 if failed else 0)
PY
}
# nvidia_test_build DIR TYPE KERNEL: build the release's kernel modules for KERNEL.
nvidia_test_build() {
    local dir=$1 type=$2 kernel=$3 src log
    src=$dir/kernel
    [[ $type == open ]] && src=$dir/kernel-open
    [[ -d $src ]] || { note "  The release has no ${src##*/} directory to build."; return 1; }
    log=$DOWNLOAD_DIR/nvidia-build-$kernel.log
    note "Test-building its $type kernel modules for $kernel (a few minutes)..."
    if make -C "$src" -j"$(nproc)" KERNEL_UNAME="$kernel" SYSSRC="$MODULES_ROOT/$kernel/build" modules >"$log" 2>&1; then
        rm -f -- "$log"
        return 0
    fi
    note "  The build for $kernel failed (full log: $log). Its last lines:"
    tail -n 12 "$log" | sed 's/^/    /' >&2
    return 1
}
# ensure_build_tools KERNEL...: the compiler and the kernels' headers a module build needs.
ensure_build_tools() {
    local -a pkgs=()
    local kernel
    command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1 || pkgs+=(build-essential)
    command -v dkms >/dev/null 2>&1 || pkgs+=(dkms)
    for kernel in "$@"; do
        kernel_has_headers "$kernel" && continue
        if apt-cache show "proxmox-headers-$kernel" >/dev/null 2>&1; then
            pkgs+=("proxmox-headers-$kernel")
        else
            pkgs+=("pve-headers-$kernel")
        fi
    done
    (( ${#pkgs[@]} )) || return 0
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${pkgs[@]}"
}
# nvidia_verify_release VERSION TYPE: download it and check it fits this host.
nvidia_verify_release() {
    local version=$1 type=$2 work kernel newest ok=0
    local -a kernels
    heading "Checking NVIDIA $version ($(release_label "$version"))"
    nvidia_fetch_release "$version" || return 1
    if (( dry_run )); then
        note "+ check its supported GPUs and test-build its kernel modules"
        return 0
    fi
    kernels=("$(running_kernel)")
    newest=$(installed_kernels | tail -n1)
    if [[ -n $newest ]] && version_gt "$newest" "${kernels[0]}"; then kernels+=("$newest"); fi
    (( no_probe )) || ensure_build_tools "${kernels[@]}" || { note 'The build tools could not be installed.'; return 1; }
    work=$(mktemp -d "$DOWNLOAD_DIR/.nvidia-check.XXXXXX")
    if ! (cd "$work" && sh "$DOWNLOAD_DIR/$(nvidia_run_file "$version")" --extract-only >/dev/null 2>&1); then
        rm -rf -- "$work"
        note "The installer could not be unpacked."
        return 1
    fi
    local dir=$work/NVIDIA-Linux-x86_64-$version
    [[ -d $dir ]] || dir=$(find "$work" -mindepth 1 -maxdepth 1 -type d -print -quit)
    if nvidia_supports_cards "$dir" "$type"; then
        note "It supports every NVIDIA GPU of this host${type:+ ($type kernel modules)}."
        ok=1
        if (( ! no_probe )); then
            for kernel in "${kernels[@]}"; do
                if ! nvidia_test_build "$dir" "$type" "$kernel"; then ok=0; break; fi
                note "  It builds for $kernel."
            done
        fi
    else
        note "NVIDIA $version does not support the GPU(s) above."
    fi
    rm -rf -- "$work"
    (( ok ))
}
# nvidia_holders: "pid name" of the processes that have an NVIDIA device open.
nvidia_holders() {
    local fd target pid
    for fd in "$PROC_ROOT"/[0-9]*/fd/*; do
        target=$(readlink "$fd" 2>/dev/null) || continue
        [[ $target == /dev/nvidia* ]] || continue
        pid=${fd#"$PROC_ROOT"/}; pid=${pid%%/*}
        printf '%s %s\n' "$pid" "$(cat "$PROC_ROOT/$pid/comm" 2>/dev/null)"
    done | sort -u
}
# nvidia_unload: unload the NVIDIA modules; NV_RELOAD lists the display ones to load again.
nvidia_unload() {
    local module
    NV_RELOAD=()
    for module in nvidia_drm nvidia_modeset nvidia_peermem nvidia_uvm nvidia; do
        module_loaded "$module" || continue
        [[ $module != nvidia_drm ]] || NV_RELOAD+=(nvidia_drm)
        run modprobe -r "$module" || return 1
    done
}
# nvidia_dkms_other_kernels VERSION: build the new driver for the newer kernels too,
# so the next boot finds it.
nvidia_dkms_other_kernels() {
    local version=$1 kernel running
    running=$(running_kernel)
    while IFS= read -r kernel; do
        if [[ -z $kernel || $kernel == "$running" ]] || ! version_gt "$kernel" "$running"; then continue; fi
        if ! kernel_has_headers "$kernel"; then
            warn "No headers for kernel $kernel: NVIDIA $version is not built for it, so the GPU would be missing after booting it. Install proxmox-headers-$kernel and run: dkms install -m nvidia -v $version -k $kernel"
            continue
        fi
        if dkms status -m nvidia -v "$version" -k "$kernel" 2>/dev/null | grep -q installed; then continue; fi
        run dkms install -m nvidia -v "$version" -k "$kernel" ||
            warn "DKMS could not build NVIDIA $version for kernel $kernel; do not boot it until that works."
    done < <(installed_kernels)
}

# --- inventory ---------------------------------------------------------------------
inventory_host() {
    local line address vendor gen driver name version
    HOST_KERNEL=$(running_kernel)
    HOST_PVE=$(pveversion 2>/dev/null | sed -n '1s#^pve-manager/\([^/ ]*\).*#\1#p') || HOST_PVE=''
    if (( refresh )); then
        apt-get update -qq >/dev/null 2>&1 || warn 'apt-get update failed on the host; its package versions may be stale.'
    fi
    HOST_CARDS=()
    while IFS= read -r line; do
        [[ $line == GPU_CARD=* ]] && HOST_CARDS+=("${line#GPU_CARD=}")
    done < <(bash "$SETUP_HOST_GPU" --list --vendors nvidia,amd,intel 2>/dev/null </dev/null || true)
    HAS_NV=0; HAS_KMS=0; NV_DEVIDS=()
    for line in "${HOST_CARDS[@]}"; do
        IFS='|' read -r address vendor gen driver name <<< "$line"
        [[ $driver != vfio-pci ]] || continue
        case $vendor in
            nvidia)
                HAS_NV=1
                version=$(pci_device_id "$address")
                [[ -z $version ]] || NV_DEVIDS+=("$version") ;;
            amd|intel) HAS_KMS=1 ;;
        esac
    done
    NV_LOADED=$(nvidia_loaded_version)
    NV_TYPE=''; NV_DISK=''; NV_METHOD=''; NV_APT_PKGS=''
    NV_CAP=()
    if (( HAS_NV )) || [[ -n $NV_LOADED ]]; then
        [[ -z $NV_LOADED ]] || NV_TYPE=$(nvidia_loaded_type)
        NV_DISK=$(nvidia_disk_version)
        NV_APT_PKGS=$(nvidia_apt_packages)
        NV_METHOD=$(nvidia_install_method)
        while IFS='|' read -r address version name; do
            [[ -n $address ]] || continue
            NV_CAP[$address]=$version
        done < <(nvidia_gpus)
    fi
    # Kernel and firmware: the AMD and Intel drivers, and what DKMS builds NVIDIA for.
    HOST_PKG_INFO=(); HOST_APT_PENDING=()
    local pkg versions series
    local -a pkgs=(pve-firmware proxmox-default-kernel)
    series=$(kernel_series "$HOST_KERNEL") || series=''
    [[ -z $series ]] || pkgs+=("proxmox-kernel-$series")
    for pkg in "${pkgs[@]}"; do
        versions=$(apt_versions "$pkg")
        [[ -n ${versions%%|*} ]] || continue
        HOST_PKG_INFO+=("$pkg|$versions")
        if [[ -n ${versions#*|} && ${versions%%|*} != "${versions#*|}" ]]; then HOST_APT_PENDING+=("$pkg"); fi
    done
    HOST_HEADERS_MISSING=0
    if [[ $NV_METHOD == run && -n $NV_LOADED ]]; then
        versions=$(apt_versions proxmox-default-headers)
        [[ -n ${versions%%|*} || -z ${versions#*|} ]] || HOST_HEADERS_MISSING=1
    fi
    # A newer opt-in kernel series than the running one (reported, never installed).
    HOST_OPTIN=$(apt-cache pkgnames proxmox-kernel- 2>/dev/null | grep -E '^proxmox-kernel-[0-9]+\.[0-9]+$' |
        sed 's/^proxmox-kernel-//' | sort -V | tail -n1) || HOST_OPTIN=''
    if [[ -n $HOST_OPTIN && -n $series ]] && ! version_gt "$HOST_OPTIN" "$series"; then HOST_OPTIN=''; fi
    return 0
}

inventory_cts() {
    local id status name vendors
    CT_IDS=()
    command -v pct >/dev/null 2>&1 || return 0
    while IFS='|' read -r id status name; do
        [[ -n $id ]] || continue
        vendors=$(ct_gpu_vendors "$id")
        [[ -n $vendors ]] || continue
        CT_IDS+=("$id")
        CT_STATUS[$id]=$status; CT_NAME[$id]=$name; CT_VENDORS[$id]=$vendors
        if [[ $status != running ]] && (( include_stopped )) && ct_selected "$id"; then
            note "Starting stopped $(ct_label "$id") to check it (--include-stopped)..."
            if ct_start_wait "$id"; then
                STARTED_HERE[$id]=1
                (( dry_run )) || CT_STATUS[$id]=running
            else
                CT_NOTE[$id]='could not be started (--include-stopped)'
            fi
        fi
        if [[ ${CT_STATUS[$id]} == running ]] && ct_selected "$id"; then ct_probe "$id"; fi
    done < <(ct_rows)
    return 0
}

# --- what is out of date ----------------------------------------------------------
evaluate_nvidia() {
    NV_STATE=none; NV_NOTE=''; NV_RELEASES=''; NV_PRODUCTION=''; NV_BRANCH_CAP=''
    NV_CAND_BRANCH=''; NV_CAND_PRODUCTION=''; NV_CAND_NEWEST=''; NV_RECOMMENDED=''
    NV_CT_MISMATCH=(); NV_BLOCKERS=()
    local reason
    (( HAS_NV )) || [[ -n $NV_LOADED ]] || return 0
    if [[ -z $NV_LOADED ]]; then
        NV_STATE=unloaded
        if [[ -n $NV_DISK ]]; then
            NV_NOTE="NVIDIA $NV_DISK is installed but not loaded: reboot the host, then run this again."
        else
            NV_NOTE='No NVIDIA driver is loaded: set the GPU up with tools/setup-host-gpu.sh first.'
        fi
        return 0
    fi
    if [[ -n $NV_DISK && $NV_DISK != "$NV_LOADED" ]]; then
        NV_STATE=reboot
        NV_NOTE="NVIDIA $NV_DISK is installed but $NV_LOADED is still loaded: reboot the host, then run this again."
        return 0
    fi
    local id
    for id in "${CT_IDS[@]}"; do
        ct_uses "$id" nvidia && ct_selected "$id" && [[ ${CT_PROBED[$id]:-0} == 1 ]] || continue
        [[ ${CT_NV_USER[$id]:-} == "$NV_LOADED" && ${CT_NV_CUDA_LIB[$id]:-} == "$NV_LOADED" ]] ||
            NV_CT_MISMATCH+=("$id")
    done
    if [[ $NV_METHOD == apt ]]; then
        NV_STATE=apt
        NV_NOTE="The host's NVIDIA driver comes from apt ($NV_APT_PKGS); update it with apt, then run this again to bring the containers in line."
        return 0
    fi
    NV_STATE=current
    NV_BRANCH_CAP=$(nvidia_branch_cap)
    NV_RELEASES=$(nvidia_releases || true)
    NV_PRODUCTION=$(nvidia_production || true)
    if [[ -z $NV_RELEASES ]]; then
        NV_STATE=offline
        NV_NOTE="NVIDIA's archive ($NVIDIA_BASE_URL/) could not be read, so newer releases are unknown."
        return 0
    fi
    nvidia_pick_candidates "$NV_LOADED" "$NV_BRANCH_CAP"
    [[ -z $NV_RECOMMENDED ]] || NV_STATE=outdated
    [[ $NV_STATE == outdated || -n $nvidia_choice ]] || return 0
    # Every running NVIDIA container must be able to follow a new host release,
    # also one --ct leaves out. Stopped ones are checked when they are started.
    for id in "${CT_IDS[@]}"; do
        ct_uses "$id" nvidia && [[ ${CT_STATUS[$id]} == running ]] || continue
        if [[ ${CT_PROBED[$id]:-0} != 1 ]] && ! ct_selected "$id"; then ct_probe "$id"; fi
        reason=$(nvidia_ct_blocker "$id")
        [[ -z $reason ]] || NV_BLOCKERS+=("$(ct_label "$id"): $reason")
    done
    return 0
}

updates_available() {
    local id
    [[ $NV_STATE == outdated ]] && return 0
    (( ${#NV_CT_MISMATCH[@]} )) && return 0
    (( HAS_KMS && ${#HOST_APT_PENDING[@]} )) && return 0
    (( HOST_HEADERS_MISSING )) && return 0
    for id in "${CT_IDS[@]}"; do
        ct_selected "$id" || continue
        [[ -z $(ct_apt_pending "$id") ]] || return 0
    done
    return 1
}

# --- report -------------------------------------------------------------------------
report() {
    local line address vendor gen driver name id extra pkg inst cand version reason
    heading "Host $(hostname 2>/dev/null || echo '?') (Proxmox VE ${HOST_PVE:-?}, kernel $HOST_KERNEL)"
    if (( ! ${#HOST_CARDS[@]} )); then
        printf '  No NVIDIA, AMD Radeon (RDNA 3/4) or Intel Arc GPU on the PCI bus.\n'
    fi
    for line in "${HOST_CARDS[@]}"; do
        IFS='|' read -r address vendor gen driver name <<< "$line"
        extra=${gen:+$gen}
        if [[ -n ${NV_CAP[$address]:-} ]]; then extra+="${extra:+, }compute ${NV_CAP[$address]}"; fi
        printf '  %s  %s%s  driver: %s\n' "$address" "$name" "${extra:+ ($extra)}" "${driver:-none}"
    done
    if [[ -n $NV_LOADED ]]; then
        printf '  NVIDIA driver %s loaded (%s kernel modules; %s)\n' "$NV_LOADED" "$NV_TYPE" \
            "$(case $NV_METHOD in run) echo 'NVIDIA installer, DKMS' ;; apt) echo "apt: $NV_APT_PKGS" ;; *) echo 'installed by an unknown method' ;; esac)"
    fi
    for line in "${HOST_PKG_INFO[@]}"; do
        IFS='|' read -r pkg inst cand <<< "$line"
        if [[ -n $cand && $cand != "$inst" ]]; then
            printf '  %s %s (%s available)\n' "$pkg" "$inst" "$cand"
        else
            printf '  %s %s\n' "$pkg" "$inst"
        fi
    done
    if (( HOST_HEADERS_MISSING )); then
        printf '  proxmox-default-headers is not installed: DKMS cannot build NVIDIA for new kernels.\n'
    fi
    if [[ -n $HOST_OPTIN ]] && (( HAS_KMS )); then
        printf '  A newer opt-in kernel series is available (%s); this script stays on the running series.\n' "$HOST_OPTIN"
    fi

    heading 'Containers with a GPU'
    (( ${#CT_IDS[@]} )) || printf '  None.\n'
    for id in "${CT_IDS[@]}"; do
        printf '  %-5s %-16s %-8s %s' "$id" "${CT_NAME[$id]:-}" "${CT_STATUS[$id]}" "${CT_VENDORS[$id]// /+}"
        [[ -z ${CT_TARGET[$id]:-} ]] || printf '  target: %s' "${CT_TARGET[$id]}"
        printf '\n'
        if ! ct_selected "$id"; then printf '        not selected (--ct)\n'; continue; fi
        if [[ ${CT_PROBED[$id]:-0} != 1 ]]; then
            printf '        not checked: %s\n' "${CT_NOTE[$id]:-stopped (--include-stopped checks it)}"
            continue
        fi
        [[ -z ${CT_OS[$id]:-} ]] || printf '        %s\n' "${CT_OS[$id]}"
        if ct_uses "$id" nvidia; then
            version=${CT_NV_USER[$id]:-}
            if [[ -n ${CT_NV_APT[$id]:-} ]]; then
                printf '        NVIDIA user space %s from apt (%s)\n' "${version:-?}" "${CT_NV_APT[$id]}"
                reason=$(nvidia_ct_apt_blocker "$id")
                if [[ -n $reason ]]; then
                    printf '        It cannot be converted to the .run libraries: %s\n' "$reason"
                else
                    printf "        An NVIDIA update replaces those packages with NVIDIA's .run libraries.\n"
                fi
            elif [[ -z $version ]]; then
                printf '        NVIDIA user space: not installed\n'
            elif [[ -n $NV_LOADED && $version != "$NV_LOADED" ]]; then
                printf '        NVIDIA user space %s: does not match the host (%s)\n' "$version" "$NV_LOADED"
            else
                printf '        NVIDIA user space %s\n' "$version"
            fi
            if [[ -n $NV_LOADED && ${CT_NV_GUEST[$id]:-} != "$NV_LOADED" ]]; then
                printf "        It sees NVIDIA driver %s, not the host's %s.\n" "${CT_NV_GUEST[$id]:-(none)}" "$NV_LOADED"
            fi
            if [[ ${CT_NV_CUDA_LIB[$id]:-} != "$NV_LOADED" && -n $NV_LOADED ]]; then
                printf '        CUDA driver library %s: does not match the host (%s)\n' "${CT_NV_CUDA_LIB[$id]:-missing}" "$NV_LOADED"
            fi
            [[ -z ${CT_CUDA[$id]:-} ]] || printf '        CUDA toolkit %s\n' "${CT_CUDA[$id]}"
        fi
        while IFS='|' read -r pkg inst cand; do
            [[ -n $pkg ]] || continue
            if [[ -n $cand && $cand != '(none)' && $cand != "$inst" ]]; then
                printf '        %s %s (%s available)\n' "$pkg" "$inst" "$cand"
            else
                printf '        %s %s\n' "$pkg" "$inst"
            fi
        done <<< "${CT_PKGS[$id]:-}"
        [[ -z ${CT_NOTE[$id]:-} ]] || printf '        %s\n' "${CT_NOTE[$id]}"
        case " ${CT_TARGET[$id]:-} " in
            *' ollama '*) printf '        Ollama bundles its CUDA/ROCm runtime: it moves with install-target.sh --upgrade.\n' ;;
            *' comfyui '*) printf '        PyTorch bundles its CUDA/ROCm/XPU runtime: it moves with install-target.sh --upgrade.\n' ;;
        esac
    done

    heading 'Newest compatible drivers'
    case $NV_STATE in
        none) ;;
        outdated)
            printf '  NVIDIA (installed %s):\n' "$NV_LOADED"
            while IFS= read -r version; do
                printf '    %s  %s%s\n' "$version" "$(candidate_label "$version")" \
                    "$([[ $version == "$NV_RECOMMENDED" ]] && echo '  [recommended]')"
            done < <(nvidia_candidates)
            ;;
        current)
            printf '  NVIDIA %s is the newest compatible release (%s).\n' "$NV_LOADED" "$(release_label "$NV_LOADED")" ;;
        *) printf '  NVIDIA: %s\n' "$NV_NOTE" ;;
    esac
    if (( ${#NV_BLOCKERS[@]} )); then
        printf '  The NVIDIA host update is blocked until these containers can follow it:\n'
        printf '    %s\n' "${NV_BLOCKERS[@]}"
    fi
    if [[ -n $NV_BRANCH_CAP && -n $NV_PRODUCTION ]] && (( $(version_major "$NV_PRODUCTION") > NV_BRANCH_CAP )); then
        printf '  A card older than Turing keeps NVIDIA on the %s branch (newer branches dropped it).\n' "$NV_BRANCH_CAP"
    fi
    if (( ${#NV_CT_MISMATCH[@]} )); then
        printf '  NVIDIA user space to match the host (%s): %s\n' "$NV_LOADED" "$(for id in "${NV_CT_MISMATCH[@]}"; do printf '%s ' "$id"; done)"
    fi
    if (( HAS_KMS )); then
        if (( ${#HOST_APT_PENDING[@]} )); then
            printf '  AMD/Intel host driver and firmware: %s\n' "${HOST_APT_PENDING[*]} (from the Proxmox repositories)"
        else
            printf '  AMD/Intel host driver and firmware are current for kernel series %s.\n' "$(kernel_series "$HOST_KERNEL")"
        fi
    fi
    for id in "${CT_IDS[@]}"; do
        ct_selected "$id" || continue
        pkg=$(ct_apt_pending "$id" | paste -sd' ' -)
        [[ -z $pkg ]] || printf '  %s: upgrade %s\n' "$(ct_label "$id")" "$pkg"
    done
    return 0
}

# --- questions ----------------------------------------------------------------------
# ask_yes PROMPT DEFAULT: y or n, DEFAULT with --yes or an empty answer.
ask_yes() {
    local answer hint='[y/N]'
    [[ $2 == y ]] && hint='[Y/n]'
    if (( assume_yes )); then
        note "$1 $hint ${2} (--yes)"
        [[ $2 == y ]]
        return
    fi
    read -r -p "$1 $hint " answer || answer=''
    answer=${answer:-$2}
    [[ ${answer,,} == y || ${answer,,} == yes ]]
}
# choose_nvidia: sets NV_TARGET to the release to install, or nothing.
choose_nvidia() {
    local -a options
    local answer i version
    NV_TARGET=''
    case $NV_STATE in
        outdated|current|offline) ;;
        *) [[ -z $nvidia_choice ]] || note "--nvidia $nvidia_choice is ignored: ${NV_NOTE:-there is no NVIDIA driver to update}"
           return 0 ;;
    esac
    [[ $nvidia_choice != keep ]] || return 0
    if (( ${#NV_BLOCKERS[@]} )) && [[ $NV_STATE == outdated || -n $nvidia_choice ]]; then
        result "Host NVIDIA: not updated; blocked by ${NV_BLOCKERS[*]}"
        FAILED=1
        return 0
    fi
    case $nvidia_choice in
        keep) return 0 ;;
        production) NV_TARGET=$NV_CAND_PRODUCTION ;;
        branch)
            NV_TARGET=$NV_CAND_BRANCH
            if [[ -z $NV_TARGET && -n $NV_CAND_PRODUCTION &&
                  $(version_major "$NV_CAND_PRODUCTION") == "$(version_major "$NV_LOADED")" ]]; then
                NV_TARGET=$NV_CAND_PRODUCTION
            fi ;;
        newest) NV_TARGET=$(nvidia_candidates | sort -V | tail -n1) ;;
        '') ;;
        *)
            [[ $nvidia_choice != "$NV_LOADED" ]] || { note "NVIDIA $NV_LOADED is already installed."; return 0; }
            if [[ -n $NV_RELEASES ]] && ! grep -qx -- "$nvidia_choice" <<< "$NV_RELEASES"; then
                die "NVIDIA $nvidia_choice is not in NVIDIA's archive."
            fi
            if [[ -n $NV_BRANCH_CAP ]] && (( $(version_major "$nvidia_choice") > NV_BRANCH_CAP )); then
                die "NVIDIA $nvidia_choice does not support this host's older card (the $NV_BRANCH_CAP branch is the last that does)."
            fi
            version_gt "$nvidia_choice" "$NV_LOADED" || warn "NVIDIA $nvidia_choice is older than the installed $NV_LOADED (a rollback)."
            local blockers
            blockers=$(cuda_blockers "$nvidia_choice")
            [[ -z $blockers ]] || die "NVIDIA $nvidia_choice is too old for: ${blockers//$'\n'/; }"
            NV_TARGET=$nvidia_choice
            return 0 ;;
    esac
    if [[ -n $nvidia_choice ]]; then
        [[ -n $NV_TARGET ]] || note "No newer NVIDIA $nvidia_choice release than $NV_LOADED; the NVIDIA driver stays."
        return 0
    fi
    [[ $NV_STATE == outdated ]] || return 0
    mapfile -t options < <(nvidia_candidates)
    if (( assume_yes )); then
        NV_TARGET=$NV_RECOMMENDED
        note "NVIDIA: $NV_TARGET (recommended, --yes)"
        return 0
    fi
    printf '\nUpdate the NVIDIA driver on the host and in its containers (installed: %s)?\n' "$NV_LOADED" >&2
    i=0
    for version in "${options[@]}"; do
        i=$((i + 1))
        printf '  %d) %s  %s%s\n' "$i" "$version" "$(candidate_label "$version")" \
            "$([[ $version == "$NV_RECOMMENDED" ]] && echo '  [recommended]')" >&2
    done
    printf '  s) skip: keep %s\n' "$NV_LOADED" >&2
    while true; do
        read -r -p "Choice [1]: " answer || answer=s
        answer=${answer:-1}
        case $answer in
            s|S|skip) return 0 ;;
            *)
                if [[ $answer =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
                    NV_TARGET=${options[answer - 1]}
                    return 0
                fi ;;
        esac
        note "  Enter 1-${#options[@]} or s."
    done
}

plan() {
    local id pkgs reason question
    PLAN_HOST_APT=(); PLAN_HEADERS=0; PLAN_NV_CTS=(); PLAN_NV_SYNC=(); PLAN_CT_APT=()
    choose_nvidia
    if [[ -n $NV_TARGET ]]; then
        # Every container that uses the NVIDIA GPU must follow the host.
        for id in "${CT_IDS[@]}"; do
            ct_uses "$id" nvidia || continue
            if [[ ${CT_STATUS[$id]} == running || -n ${STARTED_HERE[$id]:-} ]]; then
                PLAN_NV_CTS+=("$id")
            elif ask_yes "$(ct_label "$id") is stopped and uses the NVIDIA GPU. Start it briefly to install NVIDIA $NV_TARGET's libraries too (otherwise its GPU fails on its next start)?" y; then
                PLAN_NV_CTS+=("$id")
            else
                result "Host NVIDIA $NV_TARGET: not installed because $(ct_label "$id") was not started for synchronization"
                NV_TARGET=''; PLAN_NV_CTS=()
                break
            fi
        done
        if [[ -n $NV_TARGET ]]; then
            note "The containers using the NVIDIA GPU are stopped while the host driver is replaced: ${PLAN_NV_CTS[*]:-none}."
            if ! ask_yes "Install NVIDIA $NV_TARGET on the host and in those containers now?" y; then
                NV_TARGET=''; PLAN_NV_CTS=()
            fi
        fi
    fi
    if [[ -z $NV_TARGET ]]; then
        for id in "${NV_CT_MISMATCH[@]}"; do
            reason=$(nvidia_ct_blocker "$id")
            if [[ -n $reason ]]; then
                result "$(ct_label "$id"): not given NVIDIA $NV_LOADED's user space; $reason"
                continue
            fi
            if [[ -n ${CT_NV_APT[$id]:-} ]]; then
                question="Replace the apt NVIDIA packages in $(ct_label "$id") (${CT_NV_APT[$id]}) with NVIDIA $NV_LOADED's .run user space, and restart it?"
            else
                question="Install NVIDIA $NV_LOADED's user space in $(ct_label "$id") to match the host, and restart it?"
            fi
            if ask_yes "$question" y; then
                PLAN_NV_SYNC+=("$id")
            fi
        done
    fi
    if (( HAS_KMS && ${#HOST_APT_PENDING[@]} )); then
        if ask_yes "Upgrade ${HOST_APT_PENDING[*]} on the host (the AMD/Intel driver and firmware; a reboot loads them)?" y; then
            PLAN_HOST_APT=("${HOST_APT_PENDING[@]}")
        fi
    fi
    if (( HOST_HEADERS_MISSING )); then
        if ask_yes 'Install proxmox-default-headers, so DKMS builds the NVIDIA driver for every new kernel?' y; then
            PLAN_HEADERS=1
        fi
    fi
    for id in "${CT_IDS[@]}"; do
        ct_selected "$id" || continue
        pkgs=$(ct_apt_pending "$id" | paste -sd' ' -)
        [[ -n $pkgs ]] || continue
        if ask_yes "Upgrade $pkgs in $(ct_label "$id") and restart it?" y; then
            PLAN_CT_APT+=("$id")
        fi
    done
    return 0
}

# --- changes ------------------------------------------------------------------------
# ct_nvidia_userspace ID VERSION: install VERSION's user-space libraries in a
# running container from the installer already in DOWNLOAD_DIR.
ct_nvidia_userspace() {
    local id=$1 version=$2 deploy=/root/osr-gpu-driver-update file force=false guest_version host_version
    file=$(nvidia_run_file "$version")
    host_version=$(nvidia_loaded_version)
    [[ $host_version == "$version" ]] || force=true
    if (( ! dry_run )) && [[ -n $host_version ]]; then
        guest_version=$(pct exec "$id" -- cat /proc/driver/nvidia/version </dev/null | nvidia_lxc_kernel_version) || return 1
        [[ $guest_version == "$host_version" ]] || {
            warn "$(ct_label "$id") does not see the loaded host NVIDIA driver $host_version; leaving its packages untouched."
            return 1
        }
    fi
    run pct exec "$id" -- mkdir -p "$deploy" </dev/null || return 1
    run pct push "$id" "$NVIDIA_HELPER" "$deploy/install_nvidia.sh" --perms 0755 || return 1
    run pct push "$id" "$DOWNLOAD_DIR/$file" "$deploy/$file" --perms 0755 || return 1
    if ! run pct exec "$id" -- sh -c "$(nvidia_lxc_guest_cleanup_script)" </dev/null; then
        run pct exec "$id" -- rm -rf "$deploy" </dev/null || true
        return 1
    fi
    if ! run pct exec "$id" -- env "DRIVER_VERSION=$version" "DRIVER_SHA256=$NV_SHA256" "DOWNLOAD_DIR=$deploy" \
            "FORCE=$force" bash "$deploy/install_nvidia.sh" lxc </dev/null; then
        run pct exec "$id" -- rm -rf "$deploy" </dev/null || true
        return 1
    fi
    run pct exec "$id" -- rm -rf "$deploy" </dev/null || true
}
# ct_nvidia_check ID VERSION: do NVML and libcuda in the container match VERSION?
ct_nvidia_check() {
    (( ! dry_run )) || return 0
    timeout 180 pct exec "$1" -- systemctl is-system-running --wait </dev/null >/dev/null 2>&1 || true
    timeout 60 pct exec "$1" -- sh -c "$(nvidia_lxc_guest_ready_script)" sh "$2" </dev/null >/dev/null 2>&1
}
# ct_sync_nvidia ID VERSION WAS_RUNNING: install the libraries, then restart the
# container (or stop it again, when it was stopped before).
ct_sync_nvidia() {
    local id=$1 version=$2 was_running=$3 healthy=1 reason=''
    [[ ${CT_PROBED[$id]:-0} != 1 ]] || reason=$(nvidia_ct_apt_blocker "$id")
    if [[ -n $reason ]]; then
        result "$(ct_label "$id"): NVIDIA $version's user space not installed; $reason"
        FAILED=1
        (( was_running )) || ct_stop "$id" || true
        return 0
    fi
    if ! ct_nvidia_userspace "$id" "$version"; then
        result "$(ct_label "$id"): FAILED to install NVIDIA $version's user space; run install-nvidia-driver.sh lxc in it with DRIVER_VERSION=$version"
        FAILED=1
        (( was_running )) || ct_stop "$id" || true
        return 0
    fi
    if (( was_running )); then
        run pct reboot "$id" || true
        if [[ $(nvidia_loaded_version) != "$version" ]] && (( ! dry_run )); then
            result "$(ct_label "$id"): NVIDIA $version user space installed; its GPU works after the host reboot"
        elif ct_nvidia_check "$id" "$version"; then
            result "$(ct_label "$id"): NVIDIA $version, NVML and CUDA work"
        else
            result "$(ct_label "$id"): NVIDIA $version installed, but NVML or CUDA does not match; check the container"
            FAILED=1
        fi
    else
        if (( ! dry_run )) && [[ $(nvidia_loaded_version) == "$version" ]] && ! ct_nvidia_check "$id" "$version"; then
            healthy=0
        fi
        ct_stop "$id" || true
        if (( healthy )); then
            result "$(ct_label "$id"): NVIDIA $version user space installed (left stopped)"
        else
            result "$(ct_label "$id"): NVIDIA $version installed, but NVML or CUDA does not match (left stopped)"
            FAILED=1
        fi
    fi
}
restart_cts() {
    local ct
    for ct in "$@"; do run pct start "$ct" || true; done
}
# host_nvidia_install VERSION: replace the host driver with VERSION.
host_nvidia_install() {
    local version=$1
    run env "DRIVER_VERSION=$version" "DRIVER_SHA256=$NV_SHA256" "KERNEL_MODULE_TYPE=$NV_TYPE" \
        "DOWNLOAD_DIR=$DOWNLOAD_DIR" bash "$NVIDIA_HELPER" host --no-reboot </dev/null
}

apply_nvidia() {
    local version=$1 id holders persistenced=0 module ok=1 previous=$NV_LOADED reason
    local -A was_running=()
    local -a restart=()
    # Before downloading or stopping anything: every NVIDIA container,
    # including stopped and --ct-excluded ones, must be able to follow the new
    # release (checked, seeing the loaded host driver, apt packages convertible).
    # A container that could not would lose its GPU after the upgrade.
    for id in "${PLAN_NV_CTS[@]}"; do
        if [[ ${CT_STATUS[$id]} != running ]]; then
            if ! ct_start_wait "$id"; then
                result "NVIDIA $version: not installed; $(ct_label "$id") could not be started for checking"
                FAILED=1
                return 0
            fi
            STARTED_HERE[$id]=1
            (( dry_run )) || CT_STATUS[$id]=running
        fi
        if [[ ${CT_PROBED[$id]:-0} != 1 ]]; then
            (( ! dry_run )) || continue
            ct_probe "$id"
        fi
        reason=$(nvidia_ct_blocker "$id")
        if [[ -n $reason ]]; then
            result "NVIDIA $version: not installed; $(ct_label "$id"): $reason"
            FAILED=1
            return 0
        fi
    done
    # Check the release before anything stops.
    while ! nvidia_verify_release "$version" "$NV_TYPE"; do
        result "NVIDIA $version: not installed (it failed the checks above)"
        local -a rest=()
        mapfile -t rest < <(nvidia_candidates | awk -v v="$version" 'found { print } $0 == v { found = 1 }')
        if (( ${#rest[@]} == 0 )) || (( assume_yes )) || ! ask_yes "Try NVIDIA ${rest[0]} ($(release_label "${rest[0]}")) instead?" n; then
            FAILED=1
            return 0
        fi
        version=${rest[0]}
    done
    heading "Installing NVIDIA $version"
    for id in "${PLAN_NV_CTS[@]}"; do
        if [[ ${CT_STATUS[$id]} == running && -z ${STARTED_HERE[$id]:-} ]]; then was_running[$id]=1; else was_running[$id]=0; fi
        [[ ${CT_STATUS[$id]} == running ]] || continue
        if ! ct_stop "$id"; then
            result "NVIDIA $version: not installed; $(ct_label "$id") did not stop"
            FAILED=1
            restart_cts "${restart[@]}"
            return 0
        fi
        (( ! ${was_running[$id]} )) || restart+=("$id")
    done
    if systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
        persistenced=1
        run systemctl stop nvidia-persistenced || true
    fi
    holders=$( (( dry_run )) || nvidia_holders)
    if [[ -n $holders ]]; then
        note "These host processes still use the NVIDIA GPU:"
        note "${holders//$'\n'/$'\n'  }"
        ok=0
    elif ! nvidia_unload; then
        note 'The NVIDIA kernel modules could not be unloaded. Their use counts:'
        grep -E '^nvidia' "$PROC_MODULES" | awk '{ print "  " $1 " (used by " $3 ($4 != "-" ? ": " $4 : "") ")" }' >&2 || true
        ok=0
    fi
    if (( ! ok )); then
        result "NVIDIA $version: not installed; stop what uses the GPU on the host, then run this again"
        FAILED=1
        for module in nvidia nvidia_uvm "${NV_RELOAD[@]}"; do run modprobe "$module" || true; done
        (( ! persistenced )) || run systemctl start nvidia-persistenced || true
        restart_cts "${restart[@]}"
        return 0
    fi
    if ! host_nvidia_install "$version"; then
        result "NVIDIA $version: the host install FAILED"
        FAILED=1
        if [[ -n $previous ]] && nvidia_fetch_release "$previous"; then
            note "Putting NVIDIA $previous back..."
            if host_nvidia_install "$previous"; then
                result "NVIDIA $previous: put back on the host"
            else
                result "NVIDIA $previous: could not be put back; the host has no working NVIDIA driver (see the output above)"
            fi
        fi
        restart_cts "${restart[@]}"
        return 0
    fi
    for module in "${NV_RELOAD[@]}"; do run modprobe "$module" || true; done
    (( ! persistenced )) || run systemctl start nvidia-persistenced || true
    if (( dry_run )) || [[ $(nvidia_loaded_version) == "$version" ]]; then
        result "Host: NVIDIA $version loaded"
    else
        result "Host: NVIDIA $version installed; reboot the host to load it"
        REBOOT=1
    fi
    nvidia_dkms_other_kernels "$version"
    NV_INSTALLED=$version
    for id in "${PLAN_NV_CTS[@]}"; do
        heading "$(ct_label "$id"): NVIDIA $version user space"
        if ! ct_start_wait "$id"; then
            result "$(ct_label "$id"): could not be started to install NVIDIA $version's user space"
            FAILED=1
            continue
        fi
        # A container that was stopped (or not selected) is checked now: its
        # libraries may come from apt.
        if [[ ${CT_PROBED[$id]:-0} != 1 ]] && (( ! dry_run )); then ct_probe "$id"; fi
        ct_sync_nvidia "$id" "$version" "${was_running[$id]}"
    done
}

apply_nvidia_sync() {
    local id was
    nvidia_fetch_release "$NV_LOADED" || { result "NVIDIA $NV_LOADED's installer is unavailable; the containers were not changed"; FAILED=1; return 0; }
    for id in "${PLAN_NV_SYNC[@]}"; do
        heading "$(ct_label "$id"): NVIDIA $NV_LOADED user space"
        was=1
        [[ -z ${STARTED_HERE[$id]:-} ]] || was=0
        ct_sync_nvidia "$id" "$NV_LOADED" "$was"
    done
}

apply_host_apt() {
    local -a pkgs=("${PLAN_HOST_APT[@]}")
    (( PLAN_HEADERS )) && pkgs+=(proxmox-default-headers)
    (( ${#pkgs[@]} )) || return 0
    heading 'Host packages'
    # Headers first: a new kernel's DKMS build of NVIDIA needs them.
    if (( PLAN_HEADERS )); then
        if run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q proxmox-default-headers </dev/null; then
            result 'Host: installed proxmox-default-headers'
        else
            result 'Host: proxmox-default-headers could not be installed'; FAILED=1
        fi
    fi
    if (( ${#PLAN_HOST_APT[@]} )); then
        run env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade "${PLAN_HOST_APT[@]}" </dev/null ||
            { result "Host: the upgrade of ${PLAN_HOST_APT[*]} FAILED"; FAILED=1; return 0; }
        result "Host: upgraded ${PLAN_HOST_APT[*]}; reboot to load the new kernel driver and firmware"
        REBOOT=1
    fi
}

apply_ct_apt() {
    local id pkgs
    for id in "${PLAN_CT_APT[@]}"; do
        mapfile -t pkgs < <(ct_apt_pending "$id")
        heading "$(ct_label "$id"): ${pkgs[*]}"
        if run pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade "${pkgs[@]}" </dev/null; then
            if [[ -n ${STARTED_HERE[$id]:-} ]]; then
                result "$(ct_label "$id"): upgraded ${pkgs[*]}"
            else
                run pct reboot "$id" || true
                result "$(ct_label "$id"): upgraded ${pkgs[*]} and restarted"
            fi
        else
            result "$(ct_label "$id"): the upgrade of ${pkgs[*]} FAILED"
            FAILED=1
        fi
    done
}

# check_next_boot: after a kernel change, will the NVIDIA driver be there on the next boot?
check_next_boot() {
    local newest version=${NV_INSTALLED:-$NV_LOADED}
    (( ! dry_run )) && [[ $NV_METHOD == run && -n $version ]] || return 0
    newest=$(installed_kernels | tail -n1)
    [[ -n $newest && $newest != "$HOST_KERNEL" ]] && version_gt "$newest" "$HOST_KERNEL" || return 0
    [[ -n $NV_INSTALLED ]] || nvidia_dkms_other_kernels "$version"
    if ! dkms status -m nvidia -v "$version" -k "$newest" 2>/dev/null | grep -q installed; then
        warn "DKMS has not built NVIDIA $version for kernel $newest, the one the host boots next. Fix that (dkms install -m nvidia -v $version -k $newest) or pin the running kernel (proxmox-boot-tool kernel pin $HOST_KERNEL) before rebooting."
        FAILED=1
    fi
}

# finish_stopped: stop the containers this run started, unless that happened already.
finish_stopped() {
    local id
    for id in "${!STARTED_HERE[@]}"; do
        if (( ! dry_run )) && [[ $(pct status "$id" 2>/dev/null) != *running* ]]; then continue; fi
        ct_stop "$id" || true
    done
}

main() {
    while (( $# )); do
        case $1 in
            --check) check_only=1 ;;
            --yes|-y) assume_yes=1 ;;
            --nvidia)
                [[ ${2:-} =~ ^(keep|branch|production|newest)$ ]] || valid_version "${2:-}" ||
                    die '--nvidia takes a version (e.g. 595.112.07), branch, production, newest or keep.'
                nvidia_choice=$2; shift ;;
            --ct)
                [[ ${2:-} =~ ^[0-9]+(,[0-9]+)*$ ]] || die '--ct takes container IDs, comma-separated (e.g. 201,202).'
                ct_filter=$2; shift ;;
            --include-stopped) include_stopped=1 ;;
            --no-probe) no_probe=1 ;;
            --no-refresh) refresh=0 ;;
            --dry-run) dry_run=1 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done
    [[ $(id -u) == 0 ]] || die 'Run as root on the Proxmox host.'
    command -v pct >/dev/null 2>&1 || die 'pct is missing: run this on the Proxmox VE host, not in a container.'
    [[ -r $SETUP_HOST_GPU ]] || die "Missing $SETUP_HOST_GPU (it lists the host's GPUs)."
    [[ -r $NVIDIA_HELPER ]] || die "Missing NVIDIA driver helper: $NVIDIA_HELPER"
    if (( ! check_only && ! assume_yes )) && [[ ! -t 0 ]]; then
        die 'No terminal to ask on: use --yes to take the recommended answers, or --check to only report.'
    fi
    if (( ! check_only && ! dry_run )); then
        mkdir -p "$(dirname -- "$LOCK_FILE")"
        exec {lock_fd}>"$LOCK_FILE"
        flock -n "$lock_fd" || die "Another run holds $LOCK_FILE."
    fi

    note 'Checking the host and its containers...'
    inventory_host
    inventory_cts
    evaluate_nvidia
    report

    if ! updates_available; then
        printf '\nEverything is up to date.\n'
        finish_stopped
        exit 0
    fi
    if (( check_only )); then
        printf '\nUpdates are available: run this without --check to install them.\n'
        finish_stopped
        exit 3
    fi

    printf '\n'
    plan
    apply_host_apt
    if [[ -n $NV_TARGET ]]; then apply_nvidia "$NV_TARGET"; fi
    (( ${#PLAN_NV_SYNC[@]} == 0 )) || apply_nvidia_sync
    apply_ct_apt
    check_next_boot
    finish_stopped

    heading 'Result'
    if (( ${#RESULTS[@]} )); then printf '  %s\n' "${RESULTS[@]}"; else printf '  Nothing was changed.\n'; fi
    (( ! REBOOT )) || printf '\nReboot the host to finish, then run this again to check.\n'
    (( ! FAILED )) || exit 1
    (( ! REBOOT )) || exit 2
    exit 0
}

# Settings (the paths can be moved for tests).
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../targets/nvidia-lxc.sh
source "$here/../targets/nvidia-lxc.sh"
NVIDIA_HELPER=${NVIDIA_HELPER:-$here/install-nvidia-driver.sh}
SETUP_HOST_GPU=${SETUP_HOST_GPU:-$here/setup-host-gpu.sh}
NVIDIA_BASE_URL=${NVIDIA_BASE_URL:-https://download.nvidia.com/XFree86/Linux-x86_64}
DOWNLOAD_DIR=${DOWNLOAD_DIR:-/root}
PVE_LXC_DIR=${PVE_LXC_DIR:-/etc/pve/lxc}
SYSFS_ROOT=${SYSFS_ROOT:-/sys}
PROC_ROOT=${PROC_ROOT:-/proc}
PROC_MODULES=${PROC_MODULES:-/proc/modules}
PROC_DRIVER_VERSION=${PROC_DRIVER_VERSION:-/proc/driver/nvidia/version}
MODULES_ROOT=${MODULES_ROOT:-/lib/modules}
USR_BIN=${USR_BIN:-/usr/bin}
LOCK_FILE=${LOCK_FILE:-/run/lock/osr-gpu-driver-update.lock}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-300}
CT_STOP_TIMEOUT=${CT_STOP_TIMEOUT:-180}

check_only=0; assume_yes=0; include_stopped=0; no_probe=0; refresh=1; dry_run=0
nvidia_choice=''; ct_filter=''
FAILED=0; REBOOT=0; RESULTS=()
NV_TARGET=''; NV_INSTALLED=''; NV_SHA256=''; NV_RELOAD=()
HOST_CARDS=(); HOST_PKG_INFO=(); HOST_APT_PENDING=(); NV_DEVIDS=(); NV_CT_MISMATCH=(); NV_BLOCKERS=()
PLAN_HOST_APT=(); PLAN_HEADERS=0; PLAN_NV_CTS=(); PLAN_NV_SYNC=(); PLAN_CT_APT=()
CT_IDS=()
declare -A CT_STATUS=() CT_NAME=() CT_VENDORS=() CT_PROBED=() CT_NOTE=() CT_OS=() CT_NV_USER=() CT_NV_CUDA_LIB=() \
    CT_NV_APT=() CT_NV_APT_LEFT=() CT_NV_APT_EXTRA=() CT_NV_APT_SIM=() CT_NV_GUEST=() CT_CUDA=() CT_TARGET=() CT_PKGS=() STARTED_HERE=() NV_CAP=()

# Sourcing (the tests do) defines the functions without running anything.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
