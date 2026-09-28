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

describe install_host_driver
mock_command systemd-detect-virt 1
out="$( (install_host_driver true) 2>&1)"
assert_contains "an already-loaded driver is a no-op" "already loaded" "$out"
mock_command systemd-detect-virt 0
out="$( (install_host_driver true) 2>&1)"; rc=$?
assert_ne "refuses host mode inside a container" "0" "$rc"
rm -f "$PROC_DRIVER_VERSION"

summary
