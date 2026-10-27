#!/usr/bin/env bash
# Dry-run validation of provision-lxc.sh. No PVE, root, GPU or network required;
# every invocation carries --dry-run.
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$script_dir/provision-lxc.sh
bash_bin=$(command -v bash)
common=(NONINTERACTIVE=true CT_ID=260 TEMPLATE=local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
    STORAGE=local-lvm IP_CIDR=192.0.2.60/24 GATEWAY=192.0.2.1)
passed=0
out=''

run_plan() { env -i "PATH=$PATH" "$@" "$bash_bin" "$provision" --dry-run ${FLAGS:-} 2>&1; }
ok() {
    local label=$1; shift
    out=$(run_plan "${common[@]}" "$@") || { printf 'FAIL %s\n%s\n' "$label" "$out" >&2; exit 1; }
    [[ $out == *'+ pct create 260 '* && $out == *'--unprivileged 1'* && $out == *'+ pct push 260 '* ]] || \
        { printf 'FAIL %s: incomplete plan\n%s\n' "$label" "$out" >&2; exit 1; }
    [[ $out != *'--password'* ]] || { printf 'FAIL %s: a root password is on the command line\n' "$label" >&2; exit 1; }
    passed=$((passed + 1)); printf 'PASS %s\n' "$label"
}
fails() {
    local label=$1 expect=$2; shift 2
    if out=$(run_plan "${common[@]}" "$@"); then printf 'FAIL %s: accepted\n%s\n' "$label" "$out" >&2; exit 1; fi
    [[ $out == *"$expect"* ]] || { printf 'FAIL %s: expected "%s"\n%s\n' "$label" "$expect" "$out" >&2; exit 1; }
    [[ $out != *'+ pct create'* ]] || { printf 'FAIL %s: created before refusing\n' "$label" >&2; exit 1; }
    passed=$((passed + 1)); printf 'PASS %s\n' "$label"
}
has() { [[ $out == *"$1"* ]] || { printf 'FAIL: plan lacks %s\n%s\n' "$1" "$out" >&2; exit 1; }; }
lacks() { [[ $out != *"$1"* ]] || { printf 'FAIL: plan contains %s\n%s\n' "$1" "$out" >&2; exit 1; }; }

ok 'default 72B plan sizes the disk for download + shards'
has '--rootfs local-lvm:323'; has '--memory 32768'; has '--ostype debian'
has 'Guest installation skipped'; lacks '+ pct exec 260 -- env'
lacks 'install_nvidia'

FLAGS=--install-target ok 'install plan runs the guest installer with the model settings' \
    AIRLLM_MODEL_ID=org/Small-7B AIRLLM_MODEL_ALIAS=small:7b
has '--rootfs local-lvm:64'
has 'AIRLLM_MODEL_ID=org/Small-7B AIRLLM_MODEL_ALIAS=small:7b AIRLLM_DEVICE=cpu bash /root/airllm-target-deploy/install-target.sh'
lacks 'install_nvidia'

FLAGS=--install-target ok 'GPU devices pass through and the NVIDIA helper runs first' \
    AIRLLM_MODEL_ID=org/Small-7B GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm'
has '--dev0 path=/dev/nvidia0\,gid=993\,mode=0660'; has '--dev2 path=/dev/nvidia-uvm'
has 'AIRLLM_DEVICE=cuda:0'
[[ $out == *'install_nvidia_580_173_02.sh lxc'*'install-target.sh'* ]] || { echo 'FAIL: NVIDIA helper not before the installer' >&2; exit 1; }

ok 'Ubuntu 26.04 LTS templates are accepted' TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
has '--ostype ubuntu'

ok 'DHCP needs no gateway' IP_CIDR=dhcp GATEWAY=
has 'ip=dhcp\,firewall=1'; lacks '\,gw='

ok 'an explicit larger disk wins' ROOTFS_GB=500
has '--rootfs local-lvm:500'

ok 'a small disk is allowed only on request' ROOTFS_GB=100 ALLOW_SMALL_DISK=true
has '--rootfs local-lvm:100'

fails 'a disk too small for the model is refused' 'needs about 323 GB' ROOTFS_GB=300
fails 'too little RAM is refused' 'MEMORY_MB must be at least' MEMORY_MB=4096
fails 'an unsupported template is refused' 'TEMPLATE' TEMPLATE=local:vztmpl/alpine-3.20-default_amd64.tar.xz
fails 'a template for another CPU architecture is refused' 'TEMPLATE' TEMPLATE=local:vztmpl/debian-12-standard_12.12-1_arm64.tar.zst
fails 'a bad address is refused' 'IP_CIDR' IP_CIDR=192.0.2.300/24
fails 'unattended runs need the required settings' 'Set CT_ID' CT_ID=
fails 'a bad device path is refused' 'Invalid device path' GPU_DEVICES='/dev/../etc/passwd'
fails 'duplicate devices are refused' 'Duplicate device path' GPU_DEVICES='/dev/nvidia0 /dev/nvidia0'
fails 'a bad model id is refused' 'AIRLLM_MODEL_ID' AIRLLM_MODEL_ID='bad id'

"$bash_bin" -n "$provision"
"$bash_bin" -n "$script_dir/install-target.sh"
printf '%s dry-run cases and both shell syntax checks passed. No CT or service was changed.\n' "$passed"
