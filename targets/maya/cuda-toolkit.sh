#!/usr/bin/env bash
# Install a CUDA 12.8+ *toolkit* (nvcc, headers, libcudart/cublas) inside the
# Maya LXC, without any kernel module or driver. CUDA 12.8 supports Blackwell
# while remaining on CUDA 12.x for Volta/V100 GPUs. The GPU's *driver* is a
# separate thing (installed separately as host-matched NVIDIA user-space by
# install-nvidia-driver.sh), so this script must never install a driver.
#
# We use the NVIDIA CUDA apt repository: it ships only user-space packages
# (cuda-nvcc, libcudart, ...) and therefore never touches the kernel,
# which is exactly what an unprivileged LXC needs. The .run installer is
# deliberately avoided: in a container it attempts the driver / kernel-module
# path and is the wrong tool here.
#
#   bash cuda-toolkit.sh            install the default toolkit (CUDA 12.8)
#   bash cuda-toolkit.sh --check    inside the CT: succeed when the toolkit is
#                                   already installed, or this distro's NVIDIA
#                                   repository carries CUDA_VERSION
#   bash cuda-toolkit.sh --check-repo   only the repository table, for CUDA_DIST
#                                   (provision-lxc.sh, on the host)
#   (both checks need no root or network and change nothing)
#   CUDA_VERSION=12.9 bash cuda-toolkit.sh
#   CUDA_DIST=ubuntu2404 bash cuda-toolkit.sh
#
# Idempotent: when /usr/local/cuda-<CUDA_VERSION>/bin/nvcc (or CUDA_NVCC)
# already reports that release, nothing is installed, whatever the repository
# carries (a toolkit installed some other way is accepted).
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
# cuda-toolkit-<major>-<minor>. Default to CUDA 12.8.
CUDA_VERSION=${CUDA_VERSION:-12.8}
# The apt repo host and keyring are stable across CUDA releases. NVIDIA's
# repository paths name the architecture x86_64 (not Debian's amd64).
CUDA_REPO_HOST=${CUDA_REPO_HOST:-https://developer.download.nvidia.com/compute/cuda/repos}
CUDA_KEYRING=${CUDA_KEYRING:-cuda-keyring_1.1-1_all.deb}
CUDA_REPO_ARCH=${CUDA_REPO_ARCH:-x86_64}
[[ $CUDA_REPO_ARCH =~ ^(x86_64|sbsa)$ ]] || die "Invalid CUDA_REPO_ARCH: $CUDA_REPO_ARCH (x86_64 or sbsa)."

[[ $CUDA_VERSION =~ ^[0-9]+\.[0-9]+$ ]] || die 'CUDA_VERSION must look like 12.8.'
major=${CUDA_VERSION%%.*}
minor=${CUDA_VERSION##*.}
(( major > 12 || (major == 12 && minor >= 8) )) ||
    die "Maya needs CUDA 12.8 or newer; CUDA_VERSION=$CUDA_VERSION is below that."
# Keep the package and the requested version consistent.
expected_pkg="cuda-toolkit-$major-$minor"
CUDA_TOOLKIT_PKG=${CUDA_TOOLKIT_PKG:-$expected_pkg}
[[ $CUDA_TOOLKIT_PKG == "$expected_pkg" ]] ||
    die "CUDA_TOOLKIT_PKG=$CUDA_TOOLKIT_PKG does not match CUDA_VERSION=$CUDA_VERSION (expected $expected_pkg)."

# The distro string NVIDIA's repository uses (ubuntu2404, debian12, ...).
detect_cuda_dist() {
    local id version_id
    # shellcheck disable=SC1091
    . /etc/os-release
    id=${ID:-}; version_id=${VERSION_ID:-}
    case $id in
        ubuntu) printf 'ubuntu%s' "${version_id/./}" ;;
        debian) printf 'debian%s' "${version_id%%.*}" ;;
        *) die "Unsupported distro '$id' for the CUDA apt repo; set CUDA_DIST manually." ;;
    esac
}

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

# check_repo_carries DIST: fail with an explanation when DIST's repository
# cannot provide CUDA_VERSION.
check_repo_carries() {
    local dist=$1 min min_major min_minor
    min=$(repo_minimum "$dist")
    if [[ -z $min ]]; then
        note "Note: $dist is not a distro this script has checked; apt will decide whether $CUDA_TOOLKIT_PKG exists."
        return 0
    fi
    min_major=${min%%.*} min_minor=${min##*.}
    if (( major < min_major || (major == min_major && minor < min_minor) )); then
        note "NVIDIA's $dist repository starts at CUDA $min, so CUDA $CUDA_VERSION cannot be installed there."
        if (( min_major >= 13 )); then
            note "CUDA 13 no longer supports Volta (Tesla V100). For a V100, use an Ubuntu 24.04, Ubuntu 22.04"
            note "or Debian 12 CT with CUDA 12.8/12.9. For Turing or newer GPUs, set MAYA_CUDA_VERSION=$min or later."
        else
            note "Set MAYA_CUDA_VERSION=$min or later, or use another distro."
        fi
        return 1
    fi
}

# Maya is built with exactly this toolkit (install-target.sh passes its nvcc
# to setup as --nvcc), so the versioned directory is what counts. Another,
# newer toolkit elsewhere in the CT does not satisfy the request: CUDA 13 has
# dropped Volta (V100), for example.
CUDA_HOME_DIR=${CUDA_HOME_DIR:-/usr/local/cuda-$CUDA_VERSION}
NVCC=${CUDA_NVCC:-$CUDA_HOME_DIR/bin/nvcc}

# nvcc_release PATH: "12.8" for an nvcc of that release, empty otherwise.
nvcc_release() {
    [[ -x $1 ]] || return 0
    "$1" --version 2>/dev/null | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -n1
}

link_runtime() {
    if [[ -d $CUDA_HOME_DIR/lib64 ]] && ! grep -qsx "$CUDA_HOME_DIR/lib64" /etc/ld.so.conf.d/cuda.conf; then
        printf '%s\n' "$CUDA_HOME_DIR/lib64" > /etc/ld.so.conf.d/cuda.conf
    fi
    ldconfig
}

# An installed toolkit of exactly this release satisfies the request before
# the repository is consulted: it may have come from elsewhere (a runfile).
if [[ $mode != check-repo && $(nvcc_release "$NVCC") == "$CUDA_VERSION" ]]; then
    note "CUDA $CUDA_VERSION toolkit already present ($NVCC); skipping install."
    [[ $mode == check ]] && exit 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Maya LXC.'
    link_runtime
    exit 0
fi

CUDA_DIST=${CUDA_DIST:-}
if [[ -z $CUDA_DIST ]]; then
    CUDA_DIST=$(detect_cuda_dist)
    note "Detected CUDA apt distro: $CUDA_DIST ($CUDA_REPO_ARCH)."
fi
[[ $CUDA_DIST =~ ^ubuntu[0-9]{4}$ || $CUDA_DIST =~ ^debian[0-9]{2}$ ]] || die "Invalid CUDA_DIST: $CUDA_DIST (expected e.g. ubuntu2404 or debian12)."
check_repo_carries "$CUDA_DIST" || exit 1
if [[ $mode != install ]]; then
    note "CUDA $CUDA_VERSION is available for $CUDA_DIST."
    exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the Maya LXC.'

keyring_url="$CUDA_REPO_HOST/$CUDA_DIST/$CUDA_REPO_ARCH/$CUDA_KEYRING"
note "Installing $CUDA_TOOLKIT_PKG from $CUDA_DIST/$CUDA_REPO_ARCH (keyring: $keyring_url)."

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

# The toolkit package installs into /usr/local/cuda-<major>.<minor>.
link_runtime
installed=$(nvcc_release "$NVCC")
[[ $installed == "$CUDA_VERSION" ]] ||
    die "$CUDA_TOOLKIT_PKG did not provide CUDA $CUDA_VERSION at $NVCC (found: ${installed:-nothing})."
note "CUDA toolkit ready: nvcc $installed ($NVCC)."
