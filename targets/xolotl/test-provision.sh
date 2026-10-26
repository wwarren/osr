#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
common=(CT_ID=282 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.82/24 GATEWAY=192.0.2.1)
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
has '+ pct create 282 '
has '--hostname xolotl-target'
has '--unprivileged 1'
has '--memory 98304'
has '--rootfs local-lvm:420'
has 'firewall=1'
has 'lxc.prlimit.memlock: unlimited'
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'path=/dev/nvidiactl\,gid=44\,mode=0660'
has 'path=/dev/nvidia-uvm\,gid=44\,mode=0660'
lacks 'gid=0\,'
has 'nvidia-guest-install.sh lxc'
for file in install-target.sh cuda-toolkit.sh engram-index.py xolotl.service xolotl-weights.txt upstream-commit.txt; do
    has "$file /root/xolotl-target-deploy/$file"
done
has 'bash /root/xolotl-target-deploy/install-target.sh'
has 'XOLOTL_REF=main'
pin=$(< "$here/upstream-commit.txt")
has "XOLOTL_COMMIT=$pin"
has 'XOLOTL_CUDA_VERSION=13.0'
has 'XOLOTL_CUDA_ARCH=auto'
has 'XOLOTL_PORT=8080'
has 'XOLOTL_CONTEXT=131072'
has 'XOLOTL_ARENA_GIB=60'
has 'XOLOTL_DSPARK=true'
has 'XOLOTL_MODEL_NAME=deepseek-v4.1-flash'
has 'XOLOTL_READY_TIMEOUT=1800'
has 'CUDA 13.0 is available for ubuntu2404'
has 'add xolotl://<CT address>:8080'
lacks 'https://github.com/Indras-Mirror/Xolotl.git'   # fetching happens inside the CT
lacks 'huggingface.co'                                # and so does every download

plan XOLOTL_PORT=11434 IP_CIDR=dhcp GATEWAY= XOLOTL_CUDA_ARCH=120 XOLOTL_DSPARK=false XOLOTL_MODEL_NAME=dsv41
has 'XOLOTL_PORT=11434'
has 'XOLOTL_CUDA_ARCH=120'
has 'XOLOTL_DSPARK=false'
has 'XOLOTL_MODEL_NAME=dsv41'
has 'ip=dhcp\,firewall=1'
lacks 'gw='

commit=0123456789abcdef0123456789abcdef01234567
plan XOLOTL_COMMIT=$commit XOLOTL_REF=dev XOLOTL_CUDA_VERSION=13.1 XOLOTL_CONTEXT=524288
has "XOLOTL_COMMIT=$commit"
has 'XOLOTL_REF=dev'
has 'XOLOTL_CUDA_VERSION=13.1'
has 'XOLOTL_CONTEXT=524288'

plan VLAN_TAG=30 NAMESERVER=192.0.2.53 CORES=16 MEMORY_MB=262144 ROOTFS_GB=600 XOLOTL_ARENA_GIB=200
has 'tag=30'
has '--nameserver 192.0.2.53'
has '--cores 16'
has '--memory 262144'
has '--rootfs local-lvm:600'
has 'XOLOTL_ARENA_GIB=200'
plan MEMORY_MB=65536 XOLOTL_ARENA_GIB=48
has '--memory 65536'

plan TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst XOLOTL_CUDA_VERSION=13.1
has '--ostype debian'
plan TEMPLATE=local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst
has 'CUDA 13.0 is available for debian12'
plan TEMPLATE=local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst XOLOTL_CUDA_VERSION=12.9
has 'CUDA 12.9 is available for ubuntu2204'
reject 'cannot be installed in a ubuntu2604 CT' TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
plan TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst XOLOTL_CUDA_VERSION=13.3
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
reject 'MEMORY_MB must be at least 65536' MEMORY_MB=32768
reject 'needs MEMORY_MB of at least 77824' MEMORY_MB=65536
reject 'XOLOTL_ARENA_GIB must be at least 8' XOLOTL_ARENA_GIB=4
reject 'ROOTFS_GB must be at least 380' ROOTFS_GB=300
reject 'XOLOTL_PORT' XOLOTL_PORT=70000
reject 'XOLOTL_COMMIT' XOLOTL_COMMIT=bad
reject 'XOLOTL_REF' XOLOTL_REF='a..b'
reject 'XOLOTL_CUDA_ARCH' XOLOTL_CUDA_ARCH=70
reject 'XOLOTL_CUDA_ARCH' XOLOTL_CUDA_ARCH='89;x'
reject 'XOLOTL_CUDA_VERSION' XOLOTL_CUDA_VERSION=12.4
reject 'XOLOTL_CONTEXT' XOLOTL_CONTEXT=500
reject 'XOLOTL_DSPARK' XOLOTL_DSPARK=yes
reject 'XOLOTL_MODEL_NAME' XOLOTL_MODEL_NAME='DeepSeek V4'
reject 'XOLOTL_READY_TIMEOUT' XOLOTL_READY_TIMEOUT=0
reject 'cannot be installed in a debian13 CT' TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
reject 'VLAN_TAG' VLAN_TAG=5000
reject 'SSH_PUBLIC_KEY' SSH_PUBLIC_KEY=/nonexistent/key.pub
reject 'CUDA 13.0 needs NVIDIA driver 580 or newer' NVIDIA_DRIVER_VERSION=575.64.05
reject 'Compute capability 120 (RTX 50) needs XOLOTL_CUDA_VERSION=13.0' XOLOTL_CUDA_ARCH=120 XOLOTL_CUDA_VERSION=12.9

# The guest installer's own plan.
output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has 'bash cuda-toolkit.sh (CUDA 13.0 toolkit, user space only)'
has "git fetch --depth 1 https://github.com/Indras-Mirror/Xolotl.git $pin into /opt/xolotl (as xolotl)"
has '-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc'
has '-DSTRATA_DSV41_FQ_OP=ON -DSTRATA_DSV41_HC_MIX=ON'
has 'cmake --build build-xolotl --target ds41_generate'
has 'about 372 GB'
has 'with the key [redacted]'
has 'systemctl enable xolotl.service'
has '/v1/models to list deepseek-v4.1-flash (up to 1800s)'
lacks 'sudo'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" XOLOTL_CUDA_VERSION=13.1 XOLOTL_CUDA_ARCH=120 XOLOTL_REF=dev bash "$guest" --dry-run 2>&1)
has 'Xolotl.git dev into'
has '-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.1/bin/nvcc'
has '-DCMAKE_CUDA_ARCHITECTURES=120'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" XOLOTL_COMMIT=0123456789abcdef0123456789abcdef01234567 bash "$guest" --dry-run 2>&1)
has 'Xolotl.git 0123456789abcdef0123456789abcdef01234567 into'
passed=$((passed + 1))

installed=$(mktemp -d "${TMPDIR:-/tmp}/xolotl-rerun-test.XXXXXX")
trap 'rm -rf -- "$installed"' EXIT
mkdir -p "$installed/opt/xolotl/.git" "$installed/etc/systemd/system" "$installed/etc/xolotl-target"
: > "$installed/etc/systemd/system/xolotl.service"
# An installed target has a settings record; a rerun plans from it.
printf 'XOLOTL_CUDA_VERSION=13.0\nXOLOTL_NVCC=/usr/local/cuda-13.0/bin/nvcc\nXOLOTL_CUDA_ARCH=89\nXOLOTL_PORT=8123\nXOLOTL_CONTEXT=131072\nXOLOTL_ARENA_GIB=60\nXOLOTL_DSPARK=true\nXOLOTL_MODEL_NAME=deepseek-v4.1-flash\n' \
    > "$installed/etc/xolotl-target/installed-env"
rerun_plan() {
    env -i "PATH=$PATH" XOLOTL_DIR="$installed/opt/xolotl" XOLOTL_ETC_DIR="$installed/etc/xolotl-target" \
        UNIT_DIR="$installed/etc/systemd/system" bash "$guest" --dry-run 2>&1
}
output=$(rerun_plan)
has "Xolotl.git $pin (before anything is stopped"
has 'while the service keeps running'
has 'nothing to do'
has 'previous commit locally (no network)'
has 'configured on TCP 8123'
passed=$((passed + 1))

# Without any settings record the same checkout is refused, not planned with
# fresh-install defaults.
rm "$installed/etc/xolotl-target/installed-env"
if output=$(rerun_plan); then
    printf 'FAIL a checkout without a settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Found an existing'
has 'no readable settings record'

for bad in "XOLOTL_REF=a..b|Invalid XOLOTL_REF" "XOLOTL_NVCC=relative/nvcc|Invalid XOLOTL_NVCC" \
           "XOLOTL_CONTEXT=0|XOLOTL_CONTEXT must be" "XOLOTL_CUDA_ARCH=61|XOLOTL_CUDA_ARCH must be" \
           "XOLOTL_ARENA_GIB=2|XOLOTL_ARENA_GIB must be" "XOLOTL_DSPARK=1|XOLOTL_DSPARK must be"; do
    if output=$(env -i "PATH=$PATH" "${bad%%|*}" bash "$guest" --dry-run 2>&1); then
        printf 'FAIL accepted %s\n' "${bad%%|*}" >&2; exit 1
    fi
    has "${bad#*|}"
done
passed=$((passed + 1))

# --- the host's NVIDIA driver: without one, point to tools/setup-host-gpu.sh ---
stubs=$(mktemp -d "${TMPDIR:-/tmp}/xolotl-gpu-test.XXXXXX")
trap 'rm -rf -- "$installed" "$stubs"' EXIT
printf '#!/bin/sh\nexit 9\n' > "$stubs/nvidia-smi"; chmod +x "$stubs/nvidia-smi"
output=$(env -i "PATH=$stubs:$PATH" "${common[@]}" bash "$provision" --dry-run 2>&1) || { printf 'FAIL plan without a driver\n%s\n' "$output" >&2; exit 1; }
has 'no NVIDIA driver is loaded on this host; a real run stops here until bash'
has 'tools/setup-host-gpu.sh installs it'
has '+ pct create 282 '
lacks 'host --no-reboot'
passed=$((passed + 1))
# shellcheck disable=SC1090
source <(python3 "$here/../../tests/lib/extract-functions.py" "$provision" --only die,host_driver_loaded,require_host_gpu)
# shellcheck disable=SC2034  # read by the sourced require_host_gpu
dry_run=0 gpu_tool=/repo/tools/setup-host-gpu.sh
if output=$( (PATH="$stubs:$PATH"; require_host_gpu) 2>&1 ); then
    printf 'FAIL a real run went on without a driver\n' >&2; exit 1
fi
has 'No NVIDIA driver is loaded on this host (nvidia-smi lists no GPU). Run: bash /repo/tools/setup-host-gpu.sh'
printf '#!/bin/sh\necho "GPU 0: NVIDIA GeForce RTX 4090"\n' > "$stubs/nvidia-smi"
( PATH="$stubs:$PATH"; require_host_gpu ) ||
    { printf 'FAIL a loaded driver was refused\n' >&2; exit 1; }
passed=$((passed + 1))

unit=$here/xolotl.service
grep -Fqx 'ExecStart=/opt/xolotl/.venv/bin/python /opt/xolotl/tools/v41/serve/serve_ds41.py --engine strata --config /etc/xolotl/xolotl-ds41.json --port ${XOLOTL_PORT}' "$unit"
grep -q '^EnvironmentFile=/etc/xolotl-target/xolotl.env$' "$unit"
grep -q '^User=xolotl$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
# The checkout stays read-only for the service: only data and shared memory are writable.
grep -q '^ReadWritePaths=/var/lib/xolotl /dev/shm$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"   # the GPU nodes must stay visible
grep -q '^LimitMEMLOCK=infinity$' "$unit"
if grep -qi 'api.key' <(grep -v '^#' "$unit"); then printf 'FAIL the unit carries a key setting\n' >&2; exit 1; fi
passed=$((passed + 1))

bash -n "$provision"
bash -n "$guest"
bash -n "$here/cuda-toolkit.sh"
python3 -m py_compile "$here/engram-index.py" "$here/test-pinned-upstream.py"
printf '%s Xolotl dry-run cases and shell syntax checks passed. No CT was created.\n' "$passed"
