#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals of the sourced script, set by the tests
# Unit tests for install_nvidia_580_173_02.sh. The script is sourced (its
# main only runs when executed), every system command is stubbed, and nothing
# is downloaded or installed.

exec </dev/null
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-${HERE}/../install_nvidia_580_173_02.sh}"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"
# shellcheck source=lib/mocks.sh
source "${HERE}/lib/mocks.sh"

mocks_init
WORK="$(mktemp -d)"
trap 'mocks_cleanup; rm -rf "$WORK"' EXIT
set +e
# shellcheck source=/dev/null
source "$SCRIPT"
set +euo pipefail
DOWNLOAD_DIR="${WORK}/dl"
PROC_DRIVER_VERSION="${WORK}/proc-version"
PROC_MODULES="${WORK}/proc-modules"
MODULES_LOAD_CONF="${WORK}/modules-load.d/nvidia-lxc.conf"
DEVICES_UNIT_DIR="${WORK}/systemd"
: > "$PROC_MODULES"

describe usage
out="$(bash "$SCRIPT" --help)"; rc=$?
assert_eq "help works without root" "0" "$rc"
assert_contains "documents DRIVER_SHA256" "DRIVER_SHA256" "$out"
assert_contains "no-arg prints usage too" "Usage:" "$(bash "$SCRIPT")"

describe main
out="$(bash "$SCRIPT" lxc --no-reboot 2>&1)"; rc=$?
assert_ne "--no-reboot is host-only" "0" "$rc"
assert_contains "and says so" "only applies to host mode" "$out"
assert_contains "unknown mode is rejected" "Unknown mode" "$(bash "$SCRIPT" nope 2>&1)"

describe host_driver_version
printf 'NVRM version: NVIDIA UNIX x86_64 Kernel Module  580.173.02  Tue Aug 12 2025\nGCC version: gcc 12\n' > "$PROC_DRIVER_VERSION"
assert_eq "parses the loaded module version" "580.173.02" "$(host_driver_version)"
printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  575.64.05  Release Build\n' > "$PROC_DRIVER_VERSION"
assert_eq "parses the open kernel module line" "575.64.05" "$(host_driver_version)"
rm -f "$PROC_DRIVER_VERSION"
assert_eq "no driver -> empty" "" "$(host_driver_version)"

describe installed_driver_version
mock_command nvidia-smi 0 "580.173.02"
assert_eq "reads nvidia-smi" "580.173.02" "$(installed_driver_version)"

describe check_host_version_match
printf 'NVIDIA UNIX x86_64 Kernel Module  575.64.05  x\n' > "$PROC_DRIVER_VERSION"
out="$( (check_host_version_match) 2>&1)"; rc=$?
assert_ne "a mismatch is refused" "0" "$rc"
assert_contains "naming both versions" "575.64.05" "$out"
FORCE=true
assert_ok "FORCE=true overrides" check_host_version_match
FORCE=false
printf 'NVIDIA UNIX x86_64 Kernel Module  580.173.02  x\n' > "$PROC_DRIVER_VERSION"
assert_ok "a match passes" check_host_version_match
rm -f "$PROC_DRIVER_VERSION"
assert_ok "an invisible host version is only a note" check_host_version_match

describe headers_package
mock_command pveversion 0 "pve-manager/9.0.3"
mock_command apt-cache 0
assert_eq "PVE 8+ uses proxmox-headers" "proxmox-headers-6.14.8-2-pve" "$(headers_package 6.14.8-2-pve)"
mock_command apt-cache 100
assert_eq "falls back to pve-headers" "pve-headers-6.2.16-3-pve" "$(headers_package 6.2.16-3-pve)"
rm -f "${MOCK_BIN}/pveversion"
PATH_SAVE="$PATH"; PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '^/usr/bin$' | paste -sd:)"
command -v pveversion >/dev/null 2>&1 || \
  assert_eq "plain Debian uses linux-headers" "linux-headers-6.1.0-1" "$(headers_package 6.1.0-1)"
PATH="$PATH_SAVE"

describe apt_install
mock_command apt-get 0
mock_reset_log
APT_UPDATED=false
apt_install a; apt_install b
assert_eq "updates only once per run" "1" "$(mock_call_count 'apt-get update')"

describe verify_driver
good="${WORK}/good.run"; printf '#!/bin/sh\n[ "$1" = --check ] && exit 0\n' > "$good"
bad="${WORK}/bad.run";   printf '#!/bin/sh\nexit 1\n' > "$bad"
assert_ok   "embedded checksum ok" verify_driver "$good"
assert_fail "embedded checksum bad" verify_driver "$bad"
DRIVER_SHA256="$(sha256sum "$good" | cut -d' ' -f1)"
assert_ok   "matching pinned sha" verify_driver "$good"
DRIVER_SHA256="0000"
assert_fail "wrong pinned sha" verify_driver "$good"
DRIVER_SHA256=""

describe download_driver
mock_script curl <<EOF
out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
cp "${good}" "\$out"
EOF
(download_driver) >/dev/null 2>&1
assert_ok   "the verified download is renamed into place" test -f "${DOWNLOAD_DIR}/${DRIVER_FILE}"
assert_fail "no .part is left behind" test -e "${DOWNLOAD_DIR}/${DRIVER_FILE}.part"
mock_reset_log
(download_driver) >/dev/null 2>&1
assert_eq "a verified existing file is reused" "0" "$(mock_call_count 'curl')"
printf 'corrupt' > "${DOWNLOAD_DIR}/${DRIVER_FILE}"
mock_script curl <<EOF
out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
cp "${bad}" "\$out"
EOF
out="$( (download_driver) 2>&1)"; rc=$?
assert_ne "a download that fails verification aborts" "0" "$rc"
assert_contains "and says why" "failed verification" "$out"
assert_fail "and is never promoted" test -f "${DOWNLOAD_DIR}/${DRIVER_FILE}"

describe install_lxc_userspace
printf 'NVIDIA UNIX x86_64 Kernel Module  580.173.02  x\n' > "$PROC_DRIVER_VERSION"
mock_command nvidia-smi 0 "580.173.02"
mock_command systemd-detect-virt 0
mock_reset_log
out="$( (install_lxc_userspace) 2>&1)"
assert_contains "same version already installed is a no-op" "nothing to do" "$out"
assert_eq "nothing is downloaded" "0" "$(mock_call_count 'curl')"

describe validate_kernel_module_type
for KERNEL_MODULE_TYPE in "" open proprietary; do
  assert_ok "accepts '${KERNEL_MODULE_TYPE}'" validate_kernel_module_type
done
KERNEL_MODULE_TYPE=kernel-open
assert_fail "refuses another flavour" validate_kernel_module_type
KERNEL_MODULE_TYPE=""

describe nouveau_loaded
assert_fail "not loaded" nouveau_loaded
printf 'nouveau 2973696 0 - Live 0x0000000000000000\n' > "$PROC_MODULES"
assert_ok "loaded" nouveau_loaded
: > "$PROC_MODULES"

describe host_installer_args
out="$(host_installer_args | paste -sd' ')"
assert_eq "the default flags" "--silent --dkms --no-questions --ui=none --glvnd-egl-config-path=/usr/share/glvnd/egl_vendor.d" "$out"
KERNEL_MODULE_TYPE=open
assert_contains "the open kernel modules on request" "--kernel-module-type=open" "$(host_installer_args)"
KERNEL_MODULE_TYPE=""
assert_not_contains "no flavour unless asked" "--kernel-module-type" "$(host_installer_args)"
printf 'nouveau 2973696 0 - Live 0x0000000000000000\n' > "$PROC_MODULES"
assert_contains "nouveau still loaded: install now, switch at the reboot" "--no-nouveau-check" "$(host_installer_args)"
: > "$PROC_MODULES"

describe setup_lxc_device_nodes
mock_command systemctl 0
mock_reset_log
(setup_lxc_device_nodes) >/dev/null 2>&1
assert_eq "both modules load at boot" $'nvidia\nnvidia_uvm' "$(grep -v '^#' "$MODULES_LOAD_CONF")"
unit="${DEVICES_UNIT_DIR}/nvidia-lxc-devices.service"
assert_ok "a unit creates the nodes" grep -q 'ExecStart=/usr/bin/nvidia-modprobe -c0 -u' "$unit"
assert_ok "before Proxmox starts its guests" grep -qx 'Before=pve-guests.service' "$unit"
assert_contains "and is enabled" "systemctl enable nvidia-lxc-devices.service" "$(mock_calls)"
(setup_lxc_device_nodes) >/dev/null 2>&1
assert_eq "a rerun writes the same files" $'nvidia\nnvidia_uvm' "$(grep -v '^#' "$MODULES_LOAD_CONF")"

describe activate_host_driver
mock_command modprobe 0
mock_reset_log
assert_ok "loads the modules and creates the nodes" activate_host_driver
assert_contains "nvidia" "modprobe nvidia" "$(mock_calls)"
assert_contains "nvidia_uvm" "modprobe nvidia_uvm" "$(mock_calls)"
assert_contains "and the nodes" "systemctl restart nvidia-lxc-devices.service" "$(mock_calls)"
mock_command modprobe 1
assert_fail "a module that does not load fails" activate_host_driver
printf 'nouveau 2973696 0 - Live 0x0000000000000000\n' > "$PROC_MODULES"
mock_command modprobe 0
mock_reset_log
assert_fail "nouveau holds the GPU until a reboot" activate_host_driver
assert_eq "so nothing is loaded" "0" "$(mock_call_count 'modprobe')"
: > "$PROC_MODULES"

describe install_host_driver
mock_command systemd-detect-virt 1
mock_command systemctl 0
out="$( (install_host_driver true) 2>&1)"
assert_contains "an already-loaded driver is a no-op" "already loaded" "$out"
assert_contains "that still makes the boot-time nodes" "nvidia-lxc-devices.service" "$out"
mock_command systemd-detect-virt 0
out="$( (install_host_driver true) 2>&1)"; rc=$?
assert_ne "refuses host mode inside a container" "0" "$rc"
rm -f "$PROC_DRIVER_VERSION"
mock_command systemd-detect-virt 1
KERNEL_MODULE_TYPE=bogus
out="$( (install_host_driver true) 2>&1)"; rc=$?
assert_ne "refuses an unknown module flavour" "0" "$rc"
KERNEL_MODULE_TYPE=open
# A fresh install with the package steps stubbed and a fake .run installer.
fresh_install() {
  (
    install_host_deps() { :; }
    blacklist_nouveau() { :; }
    download_driver() { cd "$DOWNLOAD_DIR" || exit 1; }
    mkdir -p "$DOWNLOAD_DIR"
    printf '#!/bin/sh\necho "run $*" >> "%s"\n' "$MOCK_LOG" > "${DOWNLOAD_DIR}/${DRIVER_FILE}"
    chmod +x "${DOWNLOAD_DIR}/${DRIVER_FILE}"
    install_host_driver true
  ) 2>&1
}
mock_command modprobe 0
mock_command nvidia-smi 0 "GPU 0: NVIDIA GeForce RTX 5090"
mock_reset_log
out="$(fresh_install)"
assert_contains "installs the open kernel modules" "--kernel-module-type=open" "$(mock_calls)"
assert_contains "loads it without a reboot" "modprobe nvidia_uvm" "$(mock_calls)"
assert_contains "and says so" "NVIDIA 580.173.02 is loaded" "$out"
assert_not_contains "never reboots with --no-reboot" "reboot" "$(mock_calls)"
printf 'nouveau 2973696 0 - Live 0x0000000000000000\n' > "$PROC_MODULES"
mock_reset_log
out="$(fresh_install)"
assert_contains "with nouveau loaded the module is still installed" "--no-nouveau-check" "$(mock_calls)"
assert_eq "but not loaded" "0" "$(mock_call_count 'modprobe')"
assert_contains "and a reboot is asked for" "reboot the host to switch" "$out"
: > "$PROC_MODULES"
KERNEL_MODULE_TYPE=""

summary
