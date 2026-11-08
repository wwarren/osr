#!/usr/bin/env bash
# Install the CUDA 10.2 *toolkit* (runtime libraries, cuBLAS and NVRTC: Kindi
# compiles its kernels when it first starts) inside the Kindi LXC, without any
# kernel module or driver; only for KINDI_BACKEND=cuda. CUDA 10.2 is the last
# toolkit that builds for Kepler (sm_30) and CuPy 9.6, the last CuPy for it,
# needs exactly this release. The GPU's *driver* is a separate thing (the
# host-matched NVIDIA user space that install-nvidia-driver.sh installs), so
# this script never installs one.
#
# NVIDIA's apt repositories carry CUDA 10.2 only for Ubuntu 18.04 and older,
# so this uses NVIDIA's runfile, as Kindi's own docker/Dockerfile does, with
# --toolkit only: the driver, its kernel module and OpenGL libraries are not
# touched. The runfile is checked against the MD5 NVIDIA publishes for it
# (developer.download.nvidia.com/compute/cuda/10.2/Prod/docs/sidebar/md5sum.txt;
# NVIDIA published no SHA-256 for 10.2). CUDA_RUNFILE_SHA256 pins a SHA-256 as
# well, for a copy you have checked yourself.
#
#   bash cuda-toolkit.sh              install CUDA 10.2 into /usr/local/cuda-10.2
#   bash cuda-toolkit.sh --check      inside the CT: succeed when the toolkit is
#                                     installed, or this distro can run the runfile
#   bash cuda-toolkit.sh --check-repo only the distro table, for CUDA_DIST
#                                     (provision-lxc.sh, on the host)
#   (both checks need no root or network and change nothing)
#
# Idempotent: when CUDA_HOME_DIR/bin/nvcc already reports release 10.2 and its
# libraries are there, nothing is downloaded or installed.
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

CUDA_VERSION=10.2
CUDA_RUNFILE=${CUDA_RUNFILE:-cuda_10.2.89_440.33.01_linux.run}
CUDA_RUNFILE_URL=${CUDA_RUNFILE_URL:-https://developer.download.nvidia.com/compute/cuda/10.2/Prod/local_installers/$CUDA_RUNFILE}
CUDA_RUNFILE_MD5=${CUDA_RUNFILE_MD5:-3d816c583759efa8567a92c1a2af90db}
CUDA_RUNFILE_SHA256=${CUDA_RUNFILE_SHA256:-}
CUDA_HOME_DIR=${CUDA_HOME_DIR:-/usr/local/cuda-10.2}
# Where the ~2.6 GB runfile is kept while it is installed, and its scratch
# space (the runfile unpacks itself there: ~5 GB).
CUDA_DOWNLOAD_DIR=${CUDA_DOWNLOAD_DIR:-/var/cache/kindi-target}
LDCONF=${LDCONF:-/etc/ld.so.conf.d/cuda-10-2.conf}
OS_RELEASE=${OS_RELEASE:-/etc/os-release}

[[ $CUDA_RUNFILE =~ ^cuda_10\.2\.[0-9]+_[0-9.]+_linux\.run$ ]] || die "Invalid CUDA_RUNFILE: $CUDA_RUNFILE"
[[ $CUDA_RUNFILE_URL =~ ^https://[A-Za-z0-9./_-]+$ ]] || die "Invalid CUDA_RUNFILE_URL: $CUDA_RUNFILE_URL"
[[ $CUDA_RUNFILE_MD5 =~ ^[0-9a-f]{32}$ ]] || die 'CUDA_RUNFILE_MD5 must be 32 hex digits.'
[[ -z $CUDA_RUNFILE_SHA256 || $CUDA_RUNFILE_SHA256 =~ ^[0-9a-f]{64}$ ]] || die 'CUDA_RUNFILE_SHA256 must be 64 hex digits.'
for path_var in CUDA_HOME_DIR CUDA_DOWNLOAD_DIR LDCONF; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done

# The distro string (ubuntu2404, debian12, ...).
detect_dist() {
    local ID='' VERSION_ID=''
    # shellcheck disable=SC1090
    . "$OS_RELEASE"
    case $ID in
        ubuntu) printf 'ubuntu%s\n' "${VERSION_ID/./}" ;;
        debian) printf 'debian%s\n' "${VERSION_ID%%.*}" ;;
        *) die "Unsupported distro '$ID' for the CUDA 10.2 runfile; set CUDA_DIST to override." ;;
    esac
}

# dist_supported DIST: the distros this target runs the runfile on. Its
# installer is linked against libxml2.so.2, which all of them ship; other
# releases are refused rather than guessed at.
dist_supported() {
    case $1 in
        ubuntu2204|ubuntu2404|debian12|debian13) return 0 ;;
        *) return 1 ;;
    esac
}

# toolkit_ready: nvcc reports 10.2 and the libraries CuPy 9.6 loads are there.
toolkit_ready() {
    local release lib
    [[ -x $CUDA_HOME_DIR/bin/nvcc ]] || return 1
    release=$("$CUDA_HOME_DIR/bin/nvcc" --version 2>/dev/null | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -n1)
    [[ $release == "$CUDA_VERSION" ]] || return 1
    for lib in libcudart.so.10.2 libnvrtc.so.10.2 libcublas.so.10; do
        [[ -e $CUDA_HOME_DIR/lib64/$lib ]] || return 1
    done
}

link_runtime() {
    printf '%s\n' "$CUDA_HOME_DIR/lib64" > "$LDCONF.new"
    mv -f -- "$LDCONF.new" "$LDCONF"
    ldconfig
}

if [[ $mode != check-repo ]] && toolkit_ready; then
    note "CUDA $CUDA_VERSION toolkit already present ($CUDA_HOME_DIR); skipping install."
    [[ $mode == check ]] && exit 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Kindi LXC.'
    link_runtime
    exit 0
fi

CUDA_DIST=${CUDA_DIST:-}
[[ -n $CUDA_DIST ]] || CUDA_DIST=$(detect_dist)
[[ $CUDA_DIST =~ ^(ubuntu[0-9]{4}|debian[0-9]{2})$ ]] || die "Invalid CUDA_DIST: $CUDA_DIST (expected e.g. ubuntu2404 or debian12)."
if ! dist_supported "$CUDA_DIST"; then
    note "The CUDA 10.2 runfile is not checked on $CUDA_DIST: its installer needs libxml2.so.2, which Debian 12/13 and Ubuntu 22.04/24.04 ship."
    note "Use one of those templates, or KINDI_BACKEND=cpu."
    exit 1
fi
if [[ $mode != install ]]; then
    note "CUDA $CUDA_VERSION (NVIDIA's runfile, toolkit only) can be installed on $CUDA_DIST."
    exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the Kindi LXC.'
export DEBIAN_FRONTEND=noninteractive
# libxml2: the runfile's installer is linked against it.
apt-get install -y ca-certificates curl libxml2

install -d -m 0700 "$CUDA_DOWNLOAD_DIR"
runfile=$CUDA_DOWNLOAD_DIR/$CUDA_RUNFILE
# check_runfile: the published MD5 (and the optional SHA-256) of the download.
check_runfile() {
    local md5 sha
    md5=$(md5sum -- "$runfile" | cut -d' ' -f1)
    [[ $md5 == "$CUDA_RUNFILE_MD5" ]] || { note "$CUDA_RUNFILE has MD5 $md5, not NVIDIA's $CUDA_RUNFILE_MD5."; return 1; }
    if [[ -n $CUDA_RUNFILE_SHA256 ]]; then
        sha=$(sha256sum -- "$runfile" | cut -d' ' -f1)
        [[ $sha == "$CUDA_RUNFILE_SHA256" ]] || { note "$CUDA_RUNFILE has SHA-256 $sha, not $CUDA_RUNFILE_SHA256."; return 1; }
    fi
}
if [[ ! -f $runfile ]] || ! check_runfile 2>/dev/null; then
    note "Downloading $CUDA_RUNFILE (about 2.6 GB) from NVIDIA."
    attempt=0
    until curl -fSL --progress-bar --proto '=https' --retry 3 --speed-limit 65536 --speed-time 120 \
            -C - -o "$runfile" -- "$CUDA_RUNFILE_URL"; do
        attempt=$((attempt + 1))
        (( attempt < 5 )) || die "Downloading $CUDA_RUNFILE_URL failed; rerun install-target.sh to resume it."
        note 'The download was interrupted; resuming.'
        sleep 5
    done
fi
if ! check_runfile; then
    rm -f -- "$runfile"
    die "The CUDA 10.2 runfile does not match its published checksum; it was removed. Rerun to download it again."
fi

scratch=$(mktemp -d "$CUDA_DOWNLOAD_DIR/unpack.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
note "Installing the CUDA $CUDA_VERSION toolkit into $CUDA_HOME_DIR (toolkit only: no driver, kernel module or OpenGL libraries)."
# Kindi's docker/Dockerfile flags, with this CT's paths.
sh "$runfile" --silent --toolkit "--toolkitpath=$CUDA_HOME_DIR" --no-opengl-libs --no-man-page --override "--tmpdir=$scratch"
# What Kindi does not use (as its Dockerfile removes it): about 1 GB.
rm -rf -- "$CUDA_HOME_DIR/doc" "$CUDA_HOME_DIR/samples" "$CUDA_HOME_DIR"/nsight* "$CUDA_HOME_DIR/libnsight" \
    "$CUDA_HOME_DIR/libnvvp" "$CUDA_HOME_DIR/extras"
link_runtime
toolkit_ready || die "The runfile did not leave a working CUDA $CUDA_VERSION toolkit in $CUDA_HOME_DIR (see /var/log/cuda-installer.log)."
rm -f -- "$runfile"
note "CUDA toolkit ready: $("$CUDA_HOME_DIR/bin/nvcc" --version | sed -n 's/.*\(release [0-9.]*\).*/\1/p' | head -n1) ($CUDA_HOME_DIR)."
