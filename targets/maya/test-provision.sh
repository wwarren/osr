#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
common=(CT_ID=281 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1)
passed=0

has() { [[ $output == *"$1"* ]] || { printf 'FAIL missing %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
lacks() { [[ $output != *"$1"* ]] || { printf 'FAIL unexpected %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
plan() {
    output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1) || {
        printf 'FAIL plan\n%s\n' "$output" >&2; exit 1;
    }
    passed=$((passed + 1))
}
reject() {
    local reason=$1; shift
    if output=$(env -i "PATH=$PATH" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1); then
        printf 'FAIL accepted invalid setting\n%s\n' "$output" >&2; exit 1
    fi
    has "$reason"
    lacks '+ pct create '
    passed=$((passed + 1))
}

plan
has '+ pct create 281 '
has '--unprivileged 1'
has '--memory 65536'
has '--rootfs local-lvm:160'
has 'firewall=1'
has 'lxc.prlimit.memlock: unlimited'
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'path=/dev/nvidiactl\,gid=44\,mode=0660'
has 'path=/dev/nvidia-uvm\,gid=44\,mode=0660'
lacks 'gid=0\,'
has 'nvidia-guest-install.sh lxc'
has 'cuda-toolkit.sh /root/maya-target-deploy/cuda-toolkit.sh'
has 'bash /root/maya-target-deploy/install-target.sh'
has 'MAYA_REF=latest'
has 'MAYA_COMMIT='
has 'MAYA_MODEL=Maya-S-v2-IQ2_XXS'
has 'MAYA_DRAFT=mtp'
has 'MAYA_CUDA_VERSION=12.8'
has 'MAYA_PORT=8080'
has 'MAYA_READY_TIMEOUT=900'
lacks 'https://github.com/mw00/project-maya.git'   # fetching happens inside the CT

plan MAYA_PORT=11434 IP_CIDR=dhcp GATEWAY= MAYA_MODEL=Maya-S24 MAYA_DRAFT=dflash2
has 'MAYA_PORT=11434'
has 'MAYA_MODEL=Maya-S24'
has 'MAYA_DRAFT=dflash2'
has 'ip=dhcp\,firewall=1'
lacks 'gw='

commit=0123456789abcdef0123456789abcdef01234567
plan MAYA_COMMIT=$commit MAYA_REF=main MAYA_NO_VISION=true MAYA_CUDA_VERSION=12.9
has "MAYA_COMMIT=$commit"
has 'MAYA_REF=main'
has 'MAYA_NO_VISION=true'
has 'MAYA_CUDA_VERSION=12.9'

plan VLAN_TAG=30 NAMESERVER=192.0.2.53 CORES=16 MEMORY_MB=131072 ROOTFS_GB=300
has 'tag=30'
has '--nameserver 192.0.2.53'
has '--cores 16'
has '--memory 131072'
has '--rootfs local-lvm:300'

plan TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst MAYA_CUDA_VERSION=13.1
has 'MAYA_CUDA_VERSION=13.1'
has '--ostype debian'
plan TEMPLATE=local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst
has 'CUDA 12.8 is available for debian12'
plan TEMPLATE=local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
has 'CUDA 12.8 is available for ubuntu2204'
reject 'cannot be installed in a ubuntu2604 CT' TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
plan TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst MAYA_CUDA_VERSION=13.3
has 'CUDA 13.3 is available for ubuntu2604'
has '--ostype ubuntu'

plan GPU_GID=1000
has 'path=/dev/nvidia0\,gid=1000\,mode=0660'
plan GPU_DEVICES='/dev/nvidia0 /dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
has '--dev1 path=/dev/nvidia1'
has '--dev4 path=/dev/nvidia-uvm-tools'

reject 'CT_ID' CT_ID=99
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'GATEWAY' GATEWAY=
reject 'TEMPLATE' TEMPLATE=local:vztmpl/alpine-3.20-standard_amd64.tar.zst
reject 'TEMPLATE' TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_arm64.tar.zst
reject 'Duplicate GPU device' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia0'
reject 'must include /dev/nvidiaN' GPU_DEVICES='/dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
reject 'Invalid GPU device path' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/../dev/nvidia-uvm'
reject 'GPU_GID' GPU_GID=0
reject 'MEMORY_MB' MEMORY_MB=16384
reject 'ROOTFS_GB' ROOTFS_GB=64
reject 'MAYA_PORT' MAYA_PORT=70000
reject 'MAYA_COMMIT' MAYA_COMMIT=bad
reject 'MAYA_REF' MAYA_REF='a..b'
reject 'MAYA_MODEL' MAYA_MODEL='Maya;x'
reject 'MAYA_DRAFT' MAYA_DRAFT='Mtp;x'
reject 'MAYA_NO_VISION' MAYA_NO_VISION=yes
reject 'MAYA_CUDA_VERSION' MAYA_CUDA_VERSION=12.4
reject 'MAYA_READY_TIMEOUT' MAYA_READY_TIMEOUT=0
reject 'cannot be installed in a debian13 CT' TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
reject 'cannot be installed in a debian13 CT' TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst MAYA_CUDA_VERSION=13.0
reject 'VLAN_TAG' VLAN_TAG=5000
reject 'SSH_PUBLIC_KEY' SSH_PUBLIC_KEY=/nonexistent/key.pub

# The guest installer's own plan.
output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has 'bash cuda-toolkit.sh (CUDA 12.8 toolkit, user space only)'
has 'git fetch --depth 1 https://github.com/mw00/project-maya.git the latest vX.Y.Z release tag into /opt/maya (as maya)'
has '--draft mtp --nvcc /usr/local/cuda-12.8/bin/nvcc'
has '--host 0.0.0.0 --port 8080'
has '--api-key [redacted]'
has 'MAYA_RUN_SCRIPT'
has 'systemctl enable maya.service'
has '/v1/models to list a loaded model (up to 900s)'
lacks 'sudo'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" MAYA_CUDA_VERSION=12.9 MAYA_DRAFT=dflash2 MAYA_REF=v1.1.15 bash "$guest" --dry-run 2>&1)
has 'project-maya.git v1.1.15 into'
has '--draft dflash2 --nvcc /usr/local/cuda-12.9/bin/nvcc'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" MAYA_COMMIT=0123456789abcdef0123456789abcdef01234567 bash "$guest" --dry-run 2>&1)
has 'project-maya.git 0123456789abcdef0123456789abcdef01234567 into'
passed=$((passed + 1))

installed=$(mktemp -d "${TMPDIR:-/tmp}/maya-rerun-test.XXXXXX")
trap 'rm -rf -- "$installed"' EXIT
mkdir -p "$installed/opt/maya/.git" "$installed/etc/systemd/system" "$installed/etc/maya-target"
: > "$installed/etc/systemd/system/maya.service"
# An installed target has a settings record; a rerun plans from it.
printf 'MAYA_MODEL=Maya-S-v2-IQ2_XXS\nMAYA_CONTEXT=32768\nMAYA_DRAFT=mtp\nMAYA_NO_VISION=false\nMAYA_CUDA_VERSION=12.8\nMAYA_NVCC=/usr/local/cuda-12.8/bin/nvcc\nMAYA_PORT=8123\n' > "$installed/etc/maya-target/installed-env"
rerun_plan() {
    env -i "PATH=$PATH" MAYA_DIR="$installed/opt/maya" MAYA_ETC_DIR="$installed/etc/maya-target" \
        UNIT_DIR="$installed/etc/systemd/system" bash "$guest" --dry-run 2>&1
}
output=$(rerun_plan)
has 'the latest vX.Y.Z release tag (before anything is stopped'
has 'nothing to do'
has 'previous commit locally (no network)'
passed=$((passed + 1))

# Without any settings record the same checkout is refused, not planned with
# fresh-install defaults.
rm "$installed/etc/maya-target/installed-env"
if output=$(rerun_plan); then
    printf 'FAIL a checkout without a settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Found an existing'
has 'no readable settings record'

for bad in "MAYA_REF=a..b|Invalid MAYA_REF" "MAYA_DRAFT=X;y|Invalid MAYA_DRAFT" \
           "MAYA_NVCC=relative/nvcc|Invalid MAYA_NVCC" "MAYA_CONTEXT=0|Invalid MAYA_CONTEXT"; do
    if output=$(env -i "PATH=$PATH" "${bad%%|*}" bash "$guest" --dry-run 2>&1); then
        printf 'FAIL accepted %s\n' "${bad%%|*}" >&2; exit 1
    fi
    has "${bad#*|}"
done
passed=$((passed + 1))

unit=$here/maya.service
grep -Fqx 'ExecStart=/bin/sh ${MAYA_RUN_SCRIPT}' "$unit"
grep -q '^EnvironmentFile=/etc/maya-target/maya.env$' "$unit"
grep -q '^User=maya$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
grep -q '^ReadWritePaths=/opt/maya /var/lib/maya /dev/shm$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"   # the GPU nodes must stay visible
grep -q '^LimitMEMLOCK=infinity$' "$unit"
grep -q '^Environment=MAYA_UPDATE_CHECK=0$' "$unit"
passed=$((passed + 1))

bash -n "$provision"
bash -n "$guest"
bash -n "$here/cuda-toolkit.sh"
printf '%s Maya dry-run cases and shell syntax checks passed. No CT was created.\n' "$passed"
