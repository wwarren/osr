#!/usr/bin/env bash
set -euo pipefail

DRIVER_VERSION="580.173.02"
DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/${DRIVER_FILE}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/root}"
GLVND_EGL_CONFIG_PATH="/usr/share/glvnd/egl_vendor.d"

usage() {
  cat <<EOF
Usage:
  sudo ./install_nvidia_580_173_02.sh host [--no-reboot]
  sudo ./install_nvidia_580_173_02.sh lxc

Modes:
  host  Install NVIDIA ${DRIVER_VERSION} kernel driver and dependencies on Proxmox/Debian host.
  lxc   Install NVIDIA ${DRIVER_VERSION} user-space libraries only inside an LXC container.

Notes:
  - For Proxmox LXC GPU passthrough, run host mode on the Proxmox host first.
  - Run lxc mode inside the container after /dev/nvidia* devices are passed through.
  - Do not run host mode inside an LXC container.
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

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "$@"
}

download_driver() {
  mkdir -p "${DOWNLOAD_DIR}"
  cd "${DOWNLOAD_DIR}"

  if [[ -f "${DRIVER_FILE}" ]]; then
    log "Using existing ${DOWNLOAD_DIR}/${DRIVER_FILE}"
  else
    log "Downloading ${DRIVER_FILE}"
    if command -v curl >/dev/null 2>&1; then
      curl -fL --retry 3 -o "${DRIVER_FILE}" "${DRIVER_URL}"
    elif command -v wget >/dev/null 2>&1; then
      wget -O "${DRIVER_FILE}" "${DRIVER_URL}"
    else
      die "Neither curl nor wget is installed."
    fi
  fi

  chmod +x "${DRIVER_FILE}"
}

install_host_deps() {
  log "Installing host build dependencies"
  apt_install ca-certificates curl wget gnupg build-essential dkms pkg-config libglvnd-dev

  if command -v pveversion >/dev/null 2>&1; then
    log "Detected Proxmox; installing matching pve headers"
    apt_install "pve-headers-$(uname -r)"
  else
    log "Installing generic Linux headers"
    apt_install "linux-headers-$(uname -r)"
  fi
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

install_lxc_userspace() {
  if ! detect_lxc; then
    cat <<EOF
WARNING: This does not look like an LXC/container environment.
Continuing with user-space-only install because lxc mode was requested.
EOF
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
  need_root "$@"

  local mode="${1:-}"
  local no_reboot="false"
  shift || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-reboot)
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
      install_host_driver "${no_reboot}"
      ;;
    lxc)
      install_lxc_userspace
      ;;
    -h|--help|"")
      usage
      ;;
    *)
      die "Unknown mode: ${mode}"
      ;;
  esac
}

main "$@"
