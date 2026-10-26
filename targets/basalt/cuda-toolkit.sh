#!/usr/bin/env bash
# Install a CUDA 13.0+ *toolkit* (nvcc, headers, libcudart/cublas) inside the
# basalt LXC, without any kernel module or driver. basalt's CMake requires
# CUDA 13.0 or newer and a CUDAToolkit it can find; the GPU's *driver* is a
# separate thing (installed separately as host-matched NVIDIA user-space by
# install_nvidia_580_173_02.sh), so this script must never install a driver.
#
# We use the NVIDIA CUDA apt repository: it ships only user-space packages
# (cuda-nvcc, libcudart-13-0, ...) and therefore never touches the kernel,
# which is exactly what an unprivileged LXC needs. The .run installer is
# deliberately avoided: in a container it attempts the driver / kernel-module
# path and is the wrong tool here.
#
#   bash cuda-toolkit.sh            install the default toolkit (CUDA 13.0)
#   CUDA_VERSION=13.1 bash cuda-toolkit.sh
#   CUDA_DIST=ubuntu2404 CUDA_ARCH=x86_64 bash cuda-toolkit.sh
#   bash cuda-toolkit.sh --check        inside the CT: succeed when a toolkit
#                                       already meets CUDA_VERSION, or this
#                                       distro's NVIDIA repository carries it
#   bash cuda-toolkit.sh --check-repo   only the repository table, for CUDA_DIST
#                                       (provision-lxc.sh, on the host)
#   (both checks need no root or network and change nothing)
#
# Idempotent: a toolkit whose nvcc meets CUDA_VERSION is left alone, whatever
# the repository carries.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

mode=install
case ${1:-} in
    --check) mode=check ;;
    --check-repo) mode=check-repo ;;
    '') ;;
    *) die "Unknown option: $1 (--check or --check-repo)." ;;
esac

# CUDA_VERSION is the major.minor of the toolkit; the apt package is
# cuda-toolkit-<major>-<minor>. Default to 13.0 (the floor basalt requires).
CUDA_VERSION=${CUDA_VERSION:-13.0}
# The apt repo host and keyring are stable across CUDA releases.
CUDA_REPO_HOST=${CUDA_REPO_HOST:-https://developer.download.nvidia.com/compute/cuda/repos}
CUDA_KEYRING=${CUDA_KEYRING:-cuda-keyring_1.1-1_all.deb}
# NVIDIA's repository paths name the architecture x86_64, not Debian's amd64
# (a .../amd64/cuda-keyring_*.deb URL does not exist).
CUDA_ARCH=${CUDA_ARCH:-x86_64}
[[ $CUDA_ARCH == amd64 ]] && CUDA_ARCH=x86_64

[[ $CUDA_VERSION =~ ^[0-9]+\.[0-9]+$ ]] || die 'CUDA_VERSION must look like 13.0.'
# basalt's CMake hard-errors below 13.0, so never allow a lower major.
major=${CUDA_VERSION%%.*}
minor=${CUDA_VERSION##*.}
[[ $major -ge 13 ]] || die "basalt needs CUDA 13.0 or newer; CUDA_VERSION=$CUDA_VERSION is below that."
# Keep the package and the requested version consistent.
expected_pkg="cuda-toolkit-$major-$minor"
CUDA_TOOLKIT_PKG=${CUDA_TOOLKIT_PKG:-$expected_pkg}
[[ $CUDA_TOOLKIT_PKG == "$expected_pkg" ]] ||
    die "CUDA_TOOLKIT_PKG=$CUDA_TOOLKIT_PKG does not match CUDA_VERSION=$CUDA_VERSION (expected $expected_pkg)."

command -v nvcc >/dev/null 2>&1 && PATH_NVCC=$(command -v nvcc) || true

# toolkit_is_new_enough: true when a usable nvcc meets CUDA_VERSION.
toolkit_is_new_enough() {
    local cand nvcc_version
    for cand in "${PATH_NVCC:-}" /usr/local/cuda/bin/nvcc /usr/local/cuda-13*/bin/nvcc; do
        [[ -n $cand && -x $cand ]] || continue
        nvcc_version=$("$cand" --version 2>/dev/null | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -n1) || continue
        if [[ -n $nvcc_version ]]; then
            local nv_major nv_minor
            nv_major=${nvcc_version%%.*}; nv_minor=${nvcc_version##*.}
            if (( nv_major > major )) || { (( nv_major == major )) && (( nv_minor >= minor )); }; then
                note "CUDA toolkit already present (nvcc $nvcc_version at $cand); skipping install."
                return 0
            fi
        fi
    done
    return 1
}

if [[ $mode != check-repo ]] && toolkit_is_new_enough; then
    note "CUDA toolkit requirement (>= $CUDA_VERSION) is already satisfied."
    [[ $mode == check ]] && exit 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the basalt LXC.'
    # Still make sure the linker can see the runtime libraries.
    if [[ -d /usr/local/cuda/lib64 ]] && ! grep -qs '/usr/local/cuda/lib64' /etc/ld.so.conf.d/cuda.conf; then
        printf '/usr/local/cuda/lib64\n' > /etc/ld.so.conf.d/cuda.conf
        ldconfig
    fi
    exit 0
fi

# Detect the distro string the NVIDIA repo uses (ubuntu2404, debian12, ...).
detect_cuda_dist() {
    local id version_id
    . /etc/os-release
    id=${ID:-}; version_id=${VERSION_ID:-}
    case $id in
        ubuntu) printf 'ubuntu%s' "${version_id/./}" ;;
        debian) printf 'debian%s' "${version_id%%.*}" ;;
        *) die "Unsupported distro '$id' for the CUDA apt repo; set CUDA_DIST manually." ;;
    esac
}
CUDA_DIST=${CUDA_DIST:-}
if [[ -z $CUDA_DIST ]]; then
    CUDA_DIST=$(detect_cuda_dist)
    note "Detected CUDA apt distro: $CUDA_DIST ($CUDA_ARCH)."
fi
[[ $CUDA_DIST =~ ^ubuntu[0-9]{4}$ || $CUDA_DIST =~ ^debian[0-9]{2}$ ]] || die "Invalid CUDA_DIST: $CUDA_DIST (expected e.g. ubuntu2404 or debian12)."

# repo_minimum DIST: the oldest CUDA release NVIDIA's repository for DIST
# carries (checked 2026-10 against developer.download.nvidia.com). Each
# repository starts at some release and grows; it never gains older ones.
# Empty for a distro this script does not know.
repo_minimum() {
    case $1 in
        ubuntu2204) echo 11.7 ;;
        ubuntu2404) echo 12.5 ;;
        ubuntu2604) echo 13.3 ;;
        debian12) echo 12.3 ;;
        debian13) echo 13.1 ;;
        *) echo '' ;;
    esac
}
min=$(repo_minimum "$CUDA_DIST")
if [[ -z $min ]]; then
    note "Note: $CUDA_DIST is not a distro this script has checked; apt will decide whether $CUDA_TOOLKIT_PKG exists."
elif (( major < ${min%%.*} || (major == ${min%%.*} && minor < ${min##*.}) )); then
    note "NVIDIA's $CUDA_DIST repository starts at CUDA $min, so CUDA $CUDA_VERSION cannot be installed there."
    note "Set CUDA_VERSION=$min or later (Blackwell supports it), or use another distro."
    exit 1
fi
if [[ $mode != install ]]; then
    note "CUDA $CUDA_VERSION is available for $CUDA_DIST."
    exit 0
fi
[[ $EUID -eq 0 ]] || die 'Run as root inside the basalt LXC.'

keyring_url="$CUDA_REPO_HOST/$CUDA_DIST/$CUDA_ARCH/$CUDA_KEYRING"
note "Installing $CUDA_TOOLKIT_PKG from $CUDA_DIST/$CUDA_ARCH (keyring: $keyring_url)."

export DEBIAN_FRONTEND=noninteractive
apt-get update
# The keyring package is small and idempotent (reinstall is harmless).
curl -fsSL -o /usr/local/src/"$CUDA_KEYRING" "$keyring_url"
dpkg -i "/usr/local/src/$CUDA_KEYRING"
apt-get update
# The repository is authoritative: say what it offers instead of letting
# apt-get fail with "Unable to locate package".
if ! apt-cache show "$CUDA_TOOLKIT_PKG" >/dev/null 2>&1; then
    offered=$(apt-cache pkgnames cuda-toolkit- 2>/dev/null | grep -E '^cuda-toolkit-[0-9]+-[0-9]+$' |
        sed 's/^cuda-toolkit-//; s/-/./' | sort -V | paste -sd' ' -)
    die "NVIDIA's $CUDA_DIST repository has no $CUDA_TOOLKIT_PKG. It offers CUDA: ${offered:-none}."
fi
apt-get install -y "$CUDA_TOOLKIT_PKG"

# The toolkit package provides a versioned directory and a /usr/local/cuda
# symlink; ensure the linker can see the runtime libraries.
if [[ -d /usr/local/cuda/lib64 ]] && ! grep -qs '/usr/local/cuda/lib64' /etc/ld.so.conf.d/cuda.conf; then
    printf '/usr/local/cuda/lib64\n' > /etc/ld.so.conf.d/cuda.conf
fi
ldconfig

# Verify: nvcc must be on PATH (or under /usr/local/cuda/bin) and report >= 13.0.
verify_toolkit() {
    local nvcc version
    if command -v nvcc >/dev/null 2>&1; then
        nvcc=$(command -v nvcc)
    elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
        nvcc=/usr/local/cuda/bin/nvcc
    else
        die "nvcc was not found after installing $CUDA_TOOLKIT_PKG."
    fi
    version=$("$nvcc" --version | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -n1)
    local v_major v_minor
    v_major=${version%%.*}; v_minor=${version##*.}
    (( v_major > major || (v_major == major && v_minor >= minor) )) || \
        die "Installed CUDA reports $version but basalt needs >= $CUDA_VERSION."
    note "CUDA toolkit ready: nvcc $version ($nvcc)."
}
verify_toolkit
