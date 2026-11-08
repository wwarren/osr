#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
common=(CT_ID=283 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.83/24 GATEWAY=192.0.2.1)
cuda=(GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm')
passed=0
scratch=$(mktemp -d "${TMPDIR:-/tmp}/avalon-provision-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
# A host without any GPU: no sysfs cards, no /dev/kfd, no nvidia-smi.
mkdir -p "$scratch/empty/sys/class/drm" "$scratch/empty/dev" "$scratch/stubs"
printf '#!/bin/sh\nexit 9\n' > "$scratch/stubs/nvidia-smi"; chmod +x "$scratch/stubs/nvidia-smi"
hostenv=("PATH=$scratch/stubs:$PATH" "HOST_SYSFS=$scratch/empty/sys" "HOST_DEV=$scratch/empty/dev")

has() { [[ $output == *"$1"* ]] || { printf 'FAIL missing %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
lacks() { [[ $output != *"$1"* ]] || { printf 'FAIL unexpected %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
plan() {
    output=$(env -i "${hostenv[@]}" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1) || {
        printf 'FAIL plan\n%s\n' "$output" >&2; exit 1;
    }
    passed=$((passed + 1))
}
reject() {
    local reason=$1; shift
    if output=$(env -i "${hostenv[@]}" "${common[@]}" "$@" bash "$provision" --dry-run 2>&1); then
        printf 'FAIL accepted invalid setting\n%s\n' "$output" >&2; exit 1
    fi
    has "$reason"
    lacks '+ pct create '
    passed=$((passed + 1))
}

plan
has 'no RDNA 3 card on amdgpu and no NVIDIA driver on this host; planning for rocm'
has '+ pct create 283 '
has '--hostname avalon-target'
has '--unprivileged 1'
has '--tags ai\;ai-model\;osr-target\;avalon'
has '--features nesting=1'
has '--memory 65536'
has '--rootfs local-lvm:160'
has 'firewall=1'
has 'lxc.prlimit.memlock: unlimited'
has '--dev0 path=/dev/kfd\,gid=44\,mode=0660'
has '--dev1 path=/dev/dri/renderD128\,gid=44\,mode=0660'
lacks 'gid=0\,'
lacks 'nvidia'
has 'ROCm 7.2.4 can be installed on ubuntu2404 (noble)'
for file in install-target.sh rocm-toolkit.sh cuda-toolkit.sh avalon.service avalon-weights.txt upstream-commit.txt; do
    has "$file /root/avalon-target-deploy/$file"
done
has 'bash /root/avalon-target-deploy/install-target.sh'
has 'AVALON_REF=main'
pin=$(< "$here/upstream-commit.txt")
has "AVALON_COMMIT=$pin"
has 'AVALON_BACKEND=rocm'
has 'AVALON_ROCM_VERSION=7.2.4'
has 'AVALON_GPU_TARGET=auto'
has 'AVALON_PORT=8080'
has 'AVALON_CONTEXT=65536'
has 'AVALON_MTP=true'
has 'AVALON_MODEL_NAME=qwen3.8-flash-next-avalon'
has 'AVALON_READY_TIMEOUT=1800'
has 'add avalon://<CT address>:8080'
lacks 'https://github.com/freriadoc/Avalon.git'   # fetching happens inside the CT
lacks 'huggingface.co'                             # and so does every download

plan AVALON_PORT=11434 IP_CIDR=dhcp GATEWAY= AVALON_GPU_TARGET=gfx1101 AVALON_MTP=false AVALON_CONTEXT=131072 \
    GPU_DEVICES='/dev/kfd /dev/dri/renderD129'
has 'AVALON_PORT=11434'
has 'AVALON_GPU_TARGET=gfx1101'
has 'AVALON_MTP=false'
has 'AVALON_CONTEXT=131072'
has '--dev1 path=/dev/dri/renderD129'
has 'ip=dhcp\,firewall=1'
lacks 'gw='
lacks 'planning for rocm'

plan TEMPLATE=local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst
has 'ROCm 7.2.4 can be installed on ubuntu2204 (jammy)'

# CUDA: chosen from the NVIDIA nodes in GPU_DEVICES.
plan "${cuda[@]}"
has 'no NVIDIA driver is loaded on this host; a real run stops here until bash'
has 'AVALON_BACKEND=cuda'
has 'AVALON_CUDA_VERSION=12.9'
has 'AVALON_CUDA_ARCH=auto'
has 'CUDA 12.9 is available for ubuntu2404'
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'nvidia-guest-install.sh lxc'
has 'DRIVER_VERSION='
lacks '/dev/kfd'
lacks 'rocm-toolkit.sh --check'
plan "${cuda[@]}" TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst AVALON_CUDA_VERSION=13.1 AVALON_CUDA_ARCH=120
has '--ostype debian'
has 'CUDA 13.1 is available for debian13'
has 'AVALON_CUDA_ARCH=120'
plan AVALON_BACKEND=cuda
has 'path=/dev/nvidia0'
has 'AVALON_BACKEND=cuda'

plan VLAN_TAG=30 NAMESERVER=192.0.2.53 CORES=16 MEMORY_MB=131072 ROOTFS_GB=300 GPU_GID=1000
has 'tag=30'
has '--nameserver 192.0.2.53'
has '--cores 16'
has '--memory 131072'
has '--rootfs local-lvm:300'
has 'path=/dev/kfd\,gid=1000\,mode=0660'

reject 'CT_ID' CT_ID=99
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'GATEWAY' GATEWAY=
reject 'Ubuntu 24.04 or 22.04 (AMD supports ROCm on Radeon cards on these only)' \
    TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
reject 'TEMPLATE' TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
reject 'TEMPLATE' TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_arm64.tar.zst
reject 'cannot be installed in a ubuntu2604 CT' "${cuda[@]}" TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
reject 'cannot be installed in a debian13 CT' "${cuda[@]}" TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
reject 'Duplicate GPU device' GPU_DEVICES='/dev/kfd /dev/dri/renderD128 /dev/kfd'
reject 'must include /dev/kfd' GPU_DEVICES='/dev/dri/renderD128 /dev/dri/card0'
reject 'must include /dev/kfd' AVALON_BACKEND=rocm GPU_DEVICES='/dev/kfd /dev/dri/renderD128 /dev/nvidia0'
reject 'must include /dev/nvidiaN' AVALON_BACKEND=cuda GPU_DEVICES='/dev/kfd /dev/dri/renderD128'
reject 'Invalid GPU device path' GPU_DEVICES='/dev/kfd /dev/../dev/dri/renderD128'
reject 'GPU_GID' GPU_GID=0
reject 'AVALON_BACKEND must be' AVALON_BACKEND=vulkan
reject 'MEMORY_MB must be at least 32768' MEMORY_MB=16384
reject 'ROOTFS_GB must be at least 130' ROOTFS_GB=100
reject 'AVALON_PORT' AVALON_PORT=70000
reject 'AVALON_COMMIT' AVALON_COMMIT=bad
reject 'AVALON_REF' AVALON_REF='a..b'
reject 'AVALON_ROCM_VERSION' AVALON_ROCM_VERSION=6.4.1
reject 'AVALON_GPU_TARGET' AVALON_GPU_TARGET=gfx1201
reject 'AVALON_CUDA_ARCH' "${cuda[@]}" AVALON_CUDA_ARCH=70
reject 'AVALON_CUDA_VERSION' "${cuda[@]}" AVALON_CUDA_VERSION=12.2
reject 'AVALON_CONTEXT' AVALON_CONTEXT=1000
reject 'AVALON_CONTEXT' AVALON_CONTEXT=524288
reject 'AVALON_MTP' AVALON_MTP=yes
reject 'AVALON_MODEL_NAME' AVALON_MODEL_NAME='Qwen Avalon'
reject 'AVALON_READY_TIMEOUT' AVALON_READY_TIMEOUT=0
reject 'VLAN_TAG' VLAN_TAG=5000
reject 'SSH_PUBLIC_KEY' SSH_PUBLIC_KEY=/nonexistent/key.pub
reject 'CUDA 12.9 needs NVIDIA driver 570 or newer' "${cuda[@]}" NVIDIA_DRIVER_VERSION=560.35.03
reject 'Compute capability 120 (RTX 50) needs AVALON_CUDA_VERSION=12.8' "${cuda[@]}" AVALON_CUDA_ARCH=120 AVALON_CUDA_VERSION=12.6

# --- the host's GPUs, from sysfs -------------------------------------------------
# card NAME VENDOR DEVICE DRIVER: a render node in a fake sysfs and /dev.
fake=$scratch/host
card() {
    mkdir -p "$fake/sys/class/drm/$1/device" "$fake/drivers/$4" "$fake/dev/dri"
    echo "$2" > "$fake/sys/class/drm/$1/device/vendor"
    echo "$3" > "$fake/sys/class/drm/$1/device/device"
    ln -sfn "$fake/drivers/$4" "$fake/sys/class/drm/$1/device/driver"
    : > "$fake/dev/dri/$1"
}
mkdir -p "$fake/dev"; : > "$fake/dev/kfd"
card renderD128 0x8086 0x56a0 i915        # an Intel Arc card: not for Avalon
card renderD129 0x1002 0x744c amdgpu      # RX 7900 XTX
hostenv=("PATH=$scratch/stubs:$PATH" "HOST_SYSFS=$fake/sys" "HOST_DEV=$fake/dev")
plan
has '--dev0 path=/dev/kfd'
has '--dev1 path=/dev/dri/renderD129'
has 'AVALON_BACKEND=rocm'
lacks 'Note:'
card renderD130 0x1002 0x7480 amdgpu      # RX 7600: a second RDNA 3 card
reject 'Several RDNA 3 cards are on this host'
plan GPU_DEVICES='/dev/kfd /dev/dri/renderD130'
has '--dev1 path=/dev/dri/renderD130'
rm -rf "$fake/sys/class/drm/renderD129" "$fake/sys/class/drm/renderD130"
card renderD131 0x1002 0x7550 amdgpu      # RX 9070 (RDNA 4): Avalon's kernels do not target it
card renderD132 0x1002 0x744c vfio-pci    # passed to a VM
plan
has 'planning for rocm'
has '--dev1 path=/dev/dri/renderD128'     # the placeholder of a dry run
passed=$((passed + 1))
# shellcheck disable=SC1090
source <(python3 "$here/../../tests/lib/extract-functions.py" "$provision" --only rdna3_render_nodes)
# shellcheck disable=SC2034  # read by the sourced rdna3_render_nodes
HOST_SYSFS=$fake/sys HOST_DEV=$fake/dev
[[ -z $(rdna3_render_nodes) ]] || { printf 'FAIL an RDNA 4 or vfio-pci card was offered\n' >&2; exit 1; }
card renderD133 0x1002 0x747e amdgpu
[[ $(rdna3_render_nodes) == '/dev/dri/renderD133 gfx1101' ]] || { printf 'FAIL RDNA 3 card: %s\n' "$(rdna3_render_nodes)" >&2; exit 1; }
rm "$fake/dev/kfd"
[[ -z $(rdna3_render_nodes) ]] || { printf 'FAIL a card was offered without /dev/kfd\n' >&2; exit 1; }
passed=$((passed + 1))

# A real run on a host without a usable GPU points to tools/setup-host-gpu.sh.
if output=$(env -i "PATH=$scratch/stubs:$PATH" "HOST_SYSFS=$scratch/empty/sys" "HOST_DEV=$scratch/empty/dev" \
        "${common[@]}" bash "$provision" 2>&1); then
    printf 'FAIL a real run went on without a GPU\n' >&2; exit 1
fi
has 'No usable GPU on this host'
has 'tools/setup-host-gpu.sh --vendors amd,nvidia'
lacks '+ pct create '
passed=$((passed + 1))

# The guest installer's own plan.
output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has 'bash rocm-toolkit.sh (ROCm 7.2.4 from repo.radeon.com'
has "git fetch --depth 1 https://github.com/freriadoc/Avalon.git $pin into /opt/avalon (as avalon)"
has '-DGGML_HIP=ON'
has '-DCMAKE_CXX_COMPILER=/opt/rocm-7.2.4/bin/amdclang++'
has '-DLLAMA_USE_PREBUILT_UI=OFF'
has 'cmake --build build --target llama-server'
has 'about 90 GiB'
has 'the key [redacted]'
has 'systemctl enable avalon.service'
has '/v1/models to list qwen3.8-flash-next-avalon (up to 1800s)'
lacks 'sudo'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" AVALON_BACKEND=cuda AVALON_CUDA_VERSION=13.0 AVALON_CUDA_ARCH=120 AVALON_REF=dev bash "$guest" --dry-run 2>&1)
has 'Avalon.git dev into'
has '-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc'
has '-DCMAKE_CUDA_ARCHITECTURES=120'
lacks 'HIP'
passed=$((passed + 1))

installed=$scratch/installed
mkdir -p "$installed/opt/avalon/.git" "$installed/etc/systemd/system" "$installed/etc/avalon-target"
: > "$installed/etc/systemd/system/avalon.service"
# An installed target has a settings record; a rerun plans from it.
printf 'AVALON_BACKEND=rocm\nAVALON_ROCM_VERSION=7.2.4\nAVALON_GPU_TARGET=gfx1100\nAVALON_CUDA_VERSION=12.9\nAVALON_NVCC=/usr/local/cuda-12.9/bin/nvcc\nAVALON_CUDA_ARCH=auto\nAVALON_PORT=8123\nAVALON_CONTEXT=262144\nAVALON_MTP=true\nAVALON_MODEL_NAME=qwen3.8-flash-next-avalon\n' \
    > "$installed/etc/avalon-target/installed-env"
rerun_plan() {
    env -i "PATH=$PATH" AVALON_DIR="$installed/opt/avalon" AVALON_ETC_DIR="$installed/etc/avalon-target" \
        UNIT_DIR="$installed/etc/systemd/system" bash "$guest" --dry-run 2>&1
}
output=$(rerun_plan)
has "Avalon.git $pin (before anything is stopped"
has 'while the service keeps running'
has 'nothing to do'
has 'previous commit locally (no network)'
has 'configured on TCP 8123'
passed=$((passed + 1))

# Without any settings record the same checkout is refused, not planned with
# fresh-install defaults.
rm "$installed/etc/avalon-target/installed-env"
if output=$(rerun_plan); then
    printf 'FAIL a checkout without a settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Found an existing'
has 'no readable settings record'

for bad in "AVALON_REF=a..b|Invalid AVALON_REF" "AVALON_NVCC=relative/nvcc|Invalid AVALON_NVCC" \
           "AVALON_CONTEXT=0|AVALON_CONTEXT must be" "AVALON_CUDA_ARCH=61|AVALON_CUDA_ARCH must be" \
           "AVALON_GPU_TARGET=gfx1030|AVALON_GPU_TARGET must be" "AVALON_MTP=1|AVALON_MTP must be" \
           "AVALON_BACKEND=vulkan|AVALON_BACKEND must be"; do
    if output=$(env -i "PATH=$PATH" "${bad%%|*}" bash "$guest" --dry-run 2>&1); then
        printf 'FAIL accepted %s\n' "${bad%%|*}" >&2; exit 1
    fi
    has "${bad#*|}"
done
passed=$((passed + 1))

unit=$here/avalon.service
grep -Fqx 'ExecStart=/opt/avalon/build/bin/llama-server $AVALON_ARGS' "$unit"
grep -q '^EnvironmentFile=/etc/avalon-target/avalon.env$' "$unit"
grep -q '^User=avalon$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
# The checkout stays read-only for the service: only data and shared memory are writable.
grep -q '^ReadWritePaths=/var/lib/avalon /dev/shm$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"   # the GPU nodes must stay visible
grep -q '^LimitMEMLOCK=infinity$' "$unit"
if grep -qi 'api.key' <(grep -v '^#' "$unit"); then printf 'FAIL the unit carries a key setting\n' >&2; exit 1; fi
passed=$((passed + 1))

bash -n "$provision"
bash -n "$guest"
bash -n "$here/rocm-toolkit.sh"
bash -n "$here/cuda-toolkit.sh"
printf '%s Avalon dry-run cases and shell syntax checks passed. No CT was created.\n' "$passed"
