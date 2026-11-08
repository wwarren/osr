#!/usr/bin/env bash
# Install the ROCm *user space* Avalon's HIP build needs (amdclang, HIP,
# hipBLAS, rocBLAS, rocminfo) inside the Avalon LXC, from AMD's apt repository
# for one ROCm release. No kernel module is installed: the host's in-kernel
# amdgpu driver serves /dev/kfd and the card's render node, which
# provision-lxc.sh passes through. Only for AVALON_BACKEND=rocm.
#
# Upstream builds and measures Avalon with ROCm 7.2.4 on gfx1100 (RX 7900 XT);
# its install.sh accepts ROCm 7.x only. AMD supports ROCm on Radeon cards on
# Ubuntu 24.04 and 22.04 (not Debian), and its 7.2.4 repository has noble and
# jammy only.
#
#   bash rocm-toolkit.sh               install ROCm ROCM_VERSION (default 7.2.4)
#   bash rocm-toolkit.sh --check       inside the CT: succeed when that release is
#                                      already installed, or AMD's repository has
#                                      it for this distro
#   bash rocm-toolkit.sh --check-repo  only the distro table, for ROCM_DIST
#                                      (provision-lxc.sh, on the host)
#   (both checks need no root or network and change nothing)
#
# The repository key is checked against AMD's published fingerprint before
# apt trusts it, and the repository is pinned to this one release.
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

ROCM_VERSION=${ROCM_VERSION:-7.2.4}
[[ $ROCM_VERSION =~ ^7\.[0-9]+(\.[0-9]+)?$ ]] ||
    die "ROCM_VERSION must be a ROCm 7.x release such as 7.2.4 (Avalon's install.sh accepts 7.x only), not '$ROCM_VERSION'."
ROCM_REPO=${ROCM_REPO:-https://repo.radeon.com/rocm/apt}
ROCM_KEY_URL=${ROCM_KEY_URL:-https://repo.radeon.com/rocm/rocm.gpg.key}
# "AMD MLSE DevOps <dl.MLSE.DevOps@amd.com>", the key that signs repo.radeon.com.
ROCM_KEY_FINGERPRINT=CA8BB4727A47B4D09B4EE8969386B48A1A693C5C
ROCM_DIR=${ROCM_DIR:-/opt/rocm-$ROCM_VERSION}
KEYRING=${ROCM_KEYRING:-/etc/apt/keyrings/rocm.gpg}
SOURCES=${ROCM_SOURCES:-/etc/apt/sources.list.d/rocm.list}
PIN_FILE=${ROCM_PIN_FILE:-/etc/apt/preferences.d/rocm-pin-600}
# What the HIP build of llama-server links (ggml-hip: hip, hipblas, rocblas)
# and what install-target.sh runs (amdclang, rocminfo). hip-dev brings hipcc,
# rocm-llvm (amdclang) and the HIP runtime; rocm-llvm only recommends the
# device libraries every HIP compile links, so they are named. About 8 GB;
# every dependency outside this repository is in Ubuntu's own archive.
PACKAGES=(hip-dev hipblas-dev rocblas-dev rocm-device-libs rocminfo)

# The distro name AMD's repository uses for an os-release ID and version.
detect_rocm_dist() {
    local id version_id
    # shellcheck disable=SC1091
    . /etc/os-release
    id=${ID:-}; version_id=${VERSION_ID:-}
    case $id in
        ubuntu) printf 'ubuntu%s' "${version_id/./}" ;;
        debian) printf 'debian%s' "${version_id%%.*}" ;;
        *) printf '%s%s' "${id:-unknown}" "${version_id/./}" ;;
    esac
}
# codename DIST: the suite in AMD's repository, empty when it has none.
codename() {
    case $1 in
        ubuntu2404) echo noble ;;
        ubuntu2204) echo jammy ;;
        *) echo '' ;;
    esac
}

# rocm_release DIR: "7.2.4" for an installed ROCm tree, empty otherwise.
rocm_release() {
    [[ -r $1/.info/version ]] || return 0
    cut -d- -f1 < "$1/.info/version" | head -n1
}
installed_ok() {
    [[ $(rocm_release "$ROCM_DIR") == "$ROCM_VERSION" && -x $ROCM_DIR/bin/amdclang++ && -x $ROCM_DIR/bin/rocminfo ]]
}

if [[ $mode != check-repo ]] && installed_ok; then
    note "ROCm $ROCM_VERSION already present ($ROCM_DIR); skipping install."
    exit 0
fi

ROCM_DIST=${ROCM_DIST:-}
if [[ -z $ROCM_DIST ]]; then
    ROCM_DIST=$(detect_rocm_dist)
    note "Detected distro: $ROCM_DIST."
fi
[[ $ROCM_DIST =~ ^[a-z]+[0-9]{2,4}$ ]] || die "Invalid ROCM_DIST: $ROCM_DIST (expected e.g. ubuntu2404)."
suite=$(codename "$ROCM_DIST")
if [[ -z $suite ]]; then
    note "AMD supports ROCm on Radeon cards on Ubuntu 24.04 and 22.04 only; its repository has no $ROCM_DIST."
    note "Use an Ubuntu 24.04 or 22.04 template for AVALON_BACKEND=rocm."
    exit 1
fi
if [[ $mode != install ]]; then
    note "ROCm $ROCM_VERSION can be installed on $ROCM_DIST ($suite)."
    exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the Avalon LXC.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg
key=$(mktemp)
trap 'rm -f -- "$key" "$key.gpg"' EXIT
curl -fsSL --proto '=https' -o "$key" "$ROCM_KEY_URL"
fingerprints=$(gpg --batch --quiet --with-colons --show-keys "$key" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')
primary=$(head -n1 <<< "$fingerprints")
[[ $primary == "$ROCM_KEY_FINGERPRINT" ]] ||
    die "The key at $ROCM_KEY_URL has fingerprint ${primary:-none}, not AMD's $ROCM_KEY_FINGERPRINT. Nothing was installed."
gpg --batch --yes --dearmor -o "$key.gpg" "$key"
install -d -m 0755 "${KEYRING%/*}"
install -m 0644 "$key.gpg" "$KEYRING"
printf 'deb [arch=amd64 signed-by=%s] %s/%s %s main\n' "$KEYRING" "$ROCM_REPO" "$ROCM_VERSION" "$suite" > "$SOURCES"
# AMD's own instructions pin repo.radeon.com above the distro's packages.
printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' > "$PIN_FILE"
apt-get update
apt-get install -y "${PACKAGES[@]}"
installed_ok ||
    die "The packages did not install ROCm $ROCM_VERSION at $ROCM_DIR (found: $(rocm_release "$ROCM_DIR"), amdclang++ and rocminfo needed)."
ldconfig
note "ROCm ready: $ROCM_VERSION ($ROCM_DIR)."
