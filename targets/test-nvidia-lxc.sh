#!/usr/bin/env bash
# The shared NVIDIA LXC flow against fake host and CT commands.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/nvidia-lxc.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/nvidia-lxc-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/nvidia-smi" <<'SH'
#!/bin/sh
printf '%s\n' "${FAKE_NVML_VERSION:-580.173.02}"
SH
cat > "$tmp/bin/ldconfig" <<'SH'
#!/bin/sh
printf 'libcuda.so.1 (libc6,x86-64) => %s/libcuda.so.%s\n' "$FAKE_CUDA_DIR" "${FAKE_CUDA_VERSION:-580.173.02}"
SH
chmod +x "$tmp/bin/nvidia-smi" "$tmp/bin/ldconfig"
touch "$tmp/libcuda.so.580.173.02" "$tmp/libcuda.so.575.64.05"
export PATH="$tmp/bin:$PATH" FAKE_CUDA_DIR="$tmp"

[[ $(nvidia_lxc_host_version) == 580.173.02 ]] || { echo 'host version was not detected' >&2; exit 1; }
[[ $(FAKE_NVML_VERSION=575.64.05 nvidia_lxc_host_version) == 575.64.05 ]] || {
    echo 'alternate host version was not detected' >&2; exit 1;
}
FAKE_NVML_VERSION=invalid nvidia_lxc_host_version >/dev/null 2>&1 && {
    echo 'invalid host version was accepted' >&2; exit 1;
}
printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  590.48.01  Release Build\n' > "$tmp/proc-version"
[[ $(NVIDIA_HOST_VERSION_FILE="$tmp/proc-version" nvidia_lxc_host_version) == 590.48.01 ]] || {
    echo 'kernel module version was not parsed' >&2; exit 1;
}

ready_script=$(nvidia_lxc_guest_ready_script)
sh -c "$ready_script" sh 580.173.02 || { echo 'matching NVML/CUDA was refused' >&2; exit 1; }
FAKE_NVML_VERSION=550.163.01 sh -c "$ready_script" sh 580.173.02 && {
    echo 'old NVML was accepted' >&2; exit 1;
}
FAKE_CUDA_VERSION=575.64.05 sh -c "$ready_script" sh 580.173.02 && {
    echo 'old CUDA library was accepted' >&2; exit 1;
}
FAKE_CUDA_VERSION=580.173.03 sh -c "$ready_script" sh 580.173.02 && {
    echo 'missing CUDA library was accepted' >&2; exit 1;
}
FAKE_NVML_VERSION=575.64.05 FAKE_CUDA_VERSION=575.64.05 sh -c "$ready_script" sh 575.64.05 || {
    echo 'matching alternate release was refused' >&2; exit 1;
}

cat > "$tmp/bin/dpkg" <<'SH'
#!/bin/sh
case " ${FAKE_INSTALLED_NVIDIA:-} " in *" $2 "*) echo 'Status: install ok installed' ;; *) exit 1 ;; esac
SH
cat > "$tmp/bin/apt-get" <<'SH'
#!/bin/sh
printf '%s %s\n' "$DEBIAN_FRONTEND" "$*" >> "$FAKE_APT_LOG"
SH
chmod +x "$tmp/bin/dpkg" "$tmp/bin/apt-get"
export FAKE_APT_LOG="$tmp/apt.log"
sh -c "$(nvidia_lxc_guest_cleanup_script)"
[[ ! -e $FAKE_APT_LOG ]] || { echo 'clean guest purged packages' >&2; exit 1; }
FAKE_INSTALLED_NVIDIA='nvidia-smi libnvidia-ml1 nvidia-installer-cleanup cuda-keyring' \
    sh -c "$(nvidia_lxc_guest_cleanup_script)"
[[ $(cat "$FAKE_APT_LOG") == 'noninteractive purge -y nvidia-smi libnvidia-ml1 nvidia-installer-cleanup' ]] || {
    echo 'cleanup selected wrong packages' >&2; exit 1;
}

# shellcheck disable=SC2034  # read by the sourced nvidia-lxc.sh
dry_run=0
die() { printf '%s\n' "$*" >&2; exit 1; }
run() { printf '%s\n' "$*" >> "$tmp/run.log"; }
nvidia_lxc_require_series 580.173.02 580 'CUDA 13'
( nvidia_lxc_require_series 575.64.05 580 'CUDA 13' ) >/dev/null 2>&1 && {
    echo 'unsupported host series was accepted for CUDA 13' >&2; exit 1;
}
pct() {
    if [[ $* == 'exec 286 -- cat /proc/driver/nvidia/version' ]]; then
        printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  %s  Release Build\n' "${FAKE_GUEST_VERSION:-580.173.02}"
    fi
}
nvidia_lxc_guest_ready() { printf 'ready %s\n' "$2" >> "$tmp/run.log"; return "${FAKE_READY_RC:-0}"; }
( FAKE_GUEST_VERSION=550.163.01 nvidia_lxc_install_guest 286 580.173.02 /root/helper.sh ) >/dev/null 2>&1 && {
    echo 'guest kernel mismatch was accepted' >&2; exit 1;
}
[[ ! -e $tmp/run.log ]] || { echo 'guest changed before kernel check' >&2; exit 1; }
nvidia_lxc_install_guest 286 580.173.02 /root/helper.sh
grep -q 'exec 286 -- env DRIVER_VERSION=580.173.02 bash /root/helper.sh lxc' "$tmp/run.log" || {
    echo 'host version was not passed into guest helper' >&2; exit 1;
}
grep -q 'ready 580.173.02' "$tmp/run.log" || { echo 'post-install verification was skipped' >&2; exit 1; }
( FAKE_READY_RC=1 nvidia_lxc_install_guest 286 580.173.02 /root/helper.sh ) >/dev/null 2>&1 && {
    echo 'failed post-install verification was accepted' >&2; exit 1;
}
printf 'Shared NVIDIA LXC host, guest, cleanup, and verification checks passed.\n'
