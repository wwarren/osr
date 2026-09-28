#!/usr/bin/env bash
set -euo pipefail

DRIVER_VERSION="580.173.02"
DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/${DRIVER_FILE}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/root}"
GLVND_EGL_CONFIG_PATH="/usr/share/glvnd/egl_vendor.d"
# Optional: pin the installer's SHA-256 (from a copy you have verified). The
# .run file's own embedded checksum is always checked as well.
DRIVER_SHA256="${DRIVER_SHA256:-}"
# lxc mode refuses to install user-space libraries that do not match the
# host's kernel driver (the classic "Failed to initialize NVML: Driver/library
# version mismatch"). FORCE=true overrides.
FORCE="${FORCE:-false}"
PROC_DRIVER_VERSION="${PROC_DRIVER_VERSION:-/proc/driver/nvidia/version}"
APT_UPDATED=false

usage() {
  cat <<EOF
Usage:
  sudo ./install_nvidia_580_173_02.sh host [--no-reboot]
  sudo ./install_nvidia_580_173_02.sh lxc

Modes:
  host  Install NVIDIA ${DRIVER_VERSION} kernel driver and dependencies on Proxmox/Debian host.
  lxc   Install NVIDIA ${DRIVER_VERSION} user-space libraries only inside an LXC container.

Environment:
  DRIVER_SHA256=<hex>  Also require this SHA-256 for the downloaded installer.
  DOWNLOAD_DIR=<dir>   Where the installer is kept (default /root).
  FORCE=true           lxc mode: install even if the host driver version differs.

Notes:
  - For Proxmox LXC GPU passthrough, run host mode on the Proxmox host first.
  - Run lxc mode inside the container after /dev/nvidia* devices are passed through.
  - Do not run host mode inside an LXC container.
  - Re-running with the same version already installed is a no-op.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root, for example: sudo $0 $*"
  fi
}

detect_lxc() {
  [[ -f /.dockerenv ]] && return 1
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --container --quiet && return 0
  fi
  grep -qaE 'lxc|liblxc' /proc/1/environ 2>/dev/null
}

# apt-get update once per run, not before every install.
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$APT_UPDATED" != "true" ]]; then
    apt-get update
    APT_UPDATED=true
  fi
  apt-get install -y "$@"
}

# The version of the NVIDIA kernel module that is loaded, from /proc (visible
# inside an LXC too). Empty when no driver is loaded.
host_driver_version() {
  [[ -r "$PROC_DRIVER_VERSION" ]] || return 0
  sed -nE 's/.*Kernel Module( for x86_64)?[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\2/p' \
    "$PROC_DRIVER_VERSION" | head -n1
}

# The user-space driver version currently installed (empty when none).
installed_driver_version() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]'
}

# Check the installer: its own embedded checksum (makeself --check), plus the
# pinned SHA-256 when DRIVER_SHA256 is set.
verify_driver() {
  local file="$1" actual
  sh "$file" --check >/dev/null 2>&1 || return 1
  if [[ -n "$DRIVER_SHA256" ]]; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    [[ "${actual,,}" == "${DRIVER_SHA256,,}" ]] || return 1
  fi
  return 0
}

# Download to a .part file and only rename it once complete and verified, so
# an interrupted download is never mistaken for a finished one on the next run.
download_driver() {
  mkdir -p "${DOWNLOAD_DIR}"
  cd "${DOWNLOAD_DIR}"

  if [[ -f "${DRIVER_FILE}" ]]; then
    if verify_driver "${DRIVER_FILE}"; then
      log "Using existing ${DOWNLOAD_DIR}/${DRIVER_FILE}"
      chmod +x "${DRIVER_FILE}"
      return 0
    fi
    log "Existing ${DRIVER_FILE} failed verification; downloading it again"
    mv -f "${DRIVER_FILE}" "${DRIVER_FILE}.bad"
  fi

  log "Downloading ${DRIVER_FILE}"
  rm -f "${DRIVER_FILE}.part"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "${DRIVER_FILE}.part" "${DRIVER_URL}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${DRIVER_FILE}.part" "${DRIVER_URL}"
  else
    die "Neither curl nor wget is installed."
  fi
  verify_driver "${DRIVER_FILE}.part" || die "Downloaded ${DRIVER_FILE} failed verification (corrupt or wrong DRIVER_SHA256)."
  mv -f "${DRIVER_FILE}.part" "${DRIVER_FILE}"
  chmod +x "${DRIVER_FILE}"
}

# Kernel headers package for the running kernel. Proxmox VE 8+ renamed
# pve-headers-* to proxmox-headers-* (the old name is a transitional package
# that may not exist for newer kernels).
headers_package() {
  local kernel="${1:-$(uname -r)}"
  if command -v pveversion >/dev/null 2>&1; then
    if apt-cache show "proxmox-headers-${kernel}" >/dev/null 2>&1; then
      printf 'proxmox-headers-%s\n' "$kernel"
    else
      printf 'pve-headers-%s\n' "$kernel"
    fi
  else
    printf 'linux-headers-%s\n' "$kernel"
  fi
}

install_host_deps() {
  log "Installing host build dependencies"
  apt_install ca-certificates curl wget gnupg build-essential dkms pkg-config libglvnd-dev
  local headers
  headers="$(headers_package)"
  log "Installing kernel headers: ${headers}"
  apt_install "$headers"
}

blacklist_nouveau() {
  log "Blacklisting nouveau"
  cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u
}

install_host_driver() {
  local no_reboot="${1:-false}"

  if detect_lxc; then
    die "This looks like a container. Use lxc mode inside LXC, not host mode."
  fi
  if [[ "$(host_driver_version)" == "$DRIVER_VERSION" ]]; then
    log "NVIDIA ${DRIVER_VERSION} is already loaded on this host; nothing to do."
    return 0
  fi

  install_host_deps
  blacklist_nouveau
  download_driver

  log "Installing NVIDIA ${DRIVER_VERSION} host driver with DKMS"
  "./${DRIVER_FILE}" \
    --silent \
    --dkms \
    --no-questions \
    --ui=none \
    --glvnd-egl-config-path="${GLVND_EGL_CONFIG_PATH}"

  log "NVIDIA installer completed"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
  fi

  if [[ "${no_reboot}" == "true" ]]; then
    log "Reboot skipped. Reboot before validating GPU passthrough."
  else
    log "Rebooting in 10 seconds. Press Ctrl+C to cancel."
    sleep 10
    reboot
  fi
}

install_lxc_deps() {
  log "Installing LXC user-space dependencies"
  apt_install \
    ca-certificates \
    curl \
    wget \
    kmod \
    binutils \
    pkg-config \
    libglvnd0 \
    libglvnd-dev \
    libegl-dev \
    libgles-dev \
    libgl1 \
    libgl1-mesa-dev
}

check_lxc_devices() {
  log "Checking NVIDIA device passthrough"
  if compgen -G "/dev/nvidia*" >/dev/null; then
    ls -l /dev/nvidia* || true
  else
    cat <<EOF
WARNING: No /dev/nvidia* devices are visible in this container.
The user-space install can continue, but nvidia-smi will fail until the
Proxmox host passes /dev/nvidia* into the LXC config.
EOF
  fi
}

# User-space libraries must match the host's kernel module exactly.
check_host_version_match() {
  local host
  host="$(host_driver_version)"
  if [[ -z "$host" ]]; then
    log "Host driver version not visible (${PROC_DRIVER_VERSION}); cannot verify it matches ${DRIVER_VERSION}."
    return 0
  fi
  if [[ "$host" != "$DRIVER_VERSION" ]]; then
    if [[ "$FORCE" == "true" ]]; then
      log "WARNING: host driver is ${host}, installing ${DRIVER_VERSION} anyway (FORCE=true)."
      return 0
    fi
    die "The host runs NVIDIA ${host}, but this script installs ${DRIVER_VERSION}. The versions must match; use the matching installer, or set FORCE=true."
  fi
  log "Host driver ${host} matches."
}

install_lxc_userspace() {
  if ! detect_lxc; then
    cat <<EOF
WARNING: This does not look like an LXC/container environment.
Continuing with user-space-only install because lxc mode was requested.
EOF
  fi

  check_host_version_match
  if [[ "$(installed_driver_version)" == "$DRIVER_VERSION" ]]; then
    log "NVIDIA ${DRIVER_VERSION} user-space libraries are already installed; nothing to do."
    return 0
  fi

  install_lxc_deps
  check_lxc_devices
  mkdir -p "${GLVND_EGL_CONFIG_PATH}"
  download_driver

  log "Installing NVIDIA ${DRIVER_VERSION} user-space libraries only"
  "./${DRIVER_FILE}" \
    --silent \
    --no-kernel-modules \
    --no-drm \
    --no-nouveau-check \
    --no-x-check \
    --no-questions \
    --ui=none \
    --glvnd-egl-config-path="${GLVND_EGL_CONFIG_PATH}"

  ldconfig

  log "NVIDIA user-space install completed"
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi || true
  else
    log "nvidia-smi is not on PATH; check /usr/bin/nvidia-smi or reinstall if needed."
  fi
}

main() {
  local mode="${1:-}"
  local no_reboot="false"
  shift || true

  # Help needs no privileges.
  case "${mode}" in
    -h|--help|"") usage; exit 0 ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-reboot)
        [[ "${mode}" == "host" ]] || die "--no-reboot only applies to host mode"
        no_reboot="true"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done

  case "${mode}" in
    host)
      need_root "${mode}"
      install_host_driver "${no_reboot}"
      ;;
    lxc)
      need_root "${mode}"
      install_lxc_userspace
      ;;
    *)
      die "Unknown mode: ${mode}"
      ;;
  esac
}

# Allow the functions to be sourced by tests without running anything.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
