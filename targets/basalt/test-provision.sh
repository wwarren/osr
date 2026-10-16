#!/usr/bin/env bash
# Check the provisioning plan without Proxmox, a GPU, root or downloads.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
common=(CT_ID=250 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1)

has() { [[ $output == *"$1"* ]] || { printf 'FAIL missing %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
lacks() { [[ $output != *"$1"* ]] || { printf 'FAIL unexpected %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
plan() { output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1); }
reject() {
    local reason=$1; shift
    if output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1); then
        printf 'FAIL accepted invalid setting\n%s\n' "$output" >&2; exit 1
    fi
    has "$reason"
    lacks '+ pct create '
}

plan
has '--unprivileged 1'
has '--memory 131072'
has '--rootfs local-lvm:200'
has 'lxc.prlimit.memlock: unlimited'
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'cuda-toolkit.sh'
has 'nvidia-guest-install.sh lxc'
has 'bash /root/basalt-target-deploy/install-target.sh'
has 'BASALT_MODEL=Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt'
has 'BASALT_CONTEXT=32768'
has 'current router does not accept basalt:// addresses'

plan BASALT_PORT=11434 CUDA_VERSION=13.1 IP_CIDR=dhcp GATEWAY=
has 'BASALT_PORT=11434'
has 'CUDA_VERSION=13.1'
lacks 'gw='

reject 'CT_ID' CT_ID=99
reject 'BASALT_GPUS' BASALT_GPUS=none
reject 'BASALT_MODEL' BASALT_MODEL='../wrong.basalt'
reject 'BASALT_CONTEXT' BASALT_CONTEXT=0
reject 'CUDA_VERSION' CUDA_VERSION=12.9
reject 'Duplicate GPU device' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia0'
reject 'does not pass through /dev/nvidia1' BASALT_GPUS=0,1
plan BASALT_GPUS=0,1 GPU_DEVICES='/dev/nvidia0 /dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm'
has 'BASALT_GPUS=0\,1'

output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has 'git fetch --depth 1 https://github.com/jesdga95/basalt.git main into /opt/basalt'
has 'cmake build for sm_120 on CUDA 13.0+'
has 'systemctl enable basalt.service'
has '/health to report loaded=true'

output=$(env -i "PATH=$PATH" BASALT_URL=https://example.com/custom.git bash "$guest" --dry-run 2>&1)
has 'https://example.com/custom.git main into /opt/basalt'

installed=$(mktemp -d "${TMPDIR:-/tmp}/basalt-rerun-test.XXXXXX")
trap 'rm -rf -- "$installed"' EXIT
mkdir -p "$installed/opt/basalt/.git" "$installed/etc/systemd/system"
: > "$installed/etc/systemd/system/basalt.service"
output=$(env -i "PATH=$PATH" BASALT_DIR="$installed/opt/basalt" \
    UNIT_DIR="$installed/etc/systemd/system" bash "$guest" --dry-run 2>&1)
has 'before anything is stopped'
has 'systemctl stop basalt.service'
has 'previous commit locally (no network)'

unit=$here/basalt.service
grep -Fqx 'ExecStart=/bin/sh ${BASALT_RUN_SCRIPT}' "$unit"
grep -q '^User=basalt$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"
grep -q '^LimitMEMLOCK=infinity$' "$unit"

bash -n "$provision"
bash -n "$guest"
bash -n "$here/cuda-toolkit.sh"
printf 'Basalt dry-run plans, validation and shell syntax passed. No CT was created.\n'
