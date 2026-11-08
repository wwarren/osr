#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
common=(CT_ID=284 TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.84/24 GATEWAY=192.0.2.1)
cuda=(GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm')
passed=0
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kindi-provision-test.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
# A host without an NVIDIA driver (nvidia-smi fails), and one whose driver
# lists a card.
mkdir -p "$scratch/none" "$scratch/nvidia"
printf '#!/bin/sh\nexit 9\n' > "$scratch/none/nvidia-smi"
printf '#!/bin/sh\ncase "$*" in *driver_version*) echo 470.256.02 ;; *) echo "GPU 0: Quadro K420" ;; esac\n' > "$scratch/nvidia/nvidia-smi"
chmod +x "$scratch/none/nvidia-smi" "$scratch/nvidia/nvidia-smi"
hostenv=("PATH=$scratch/none:$PATH")

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

# Without an NVIDIA driver, the CPU engine.
plan
has "Kindi runs its CPU engine (KINDI_BACKEND=cpu)"
has '+ pct create 284 '
has '--hostname kindi-target'
has '--unprivileged 1'
has '--tags ai\;ai-model\;osr-target\;kindi'
has '--features nesting=1'
has '--memory 16384'
has '--rootfs local-lvm:64'
has 'firewall=1'
lacks '--dev0'
lacks 'nvidia'
lacks 'cuda-toolkit.sh --check-repo'
for file in install-target.sh cuda-toolkit.sh kindi.service kindi-weights.txt upstream-commit.txt \
            requirements-cpu.lock requirements-cuda.lock uv.lock; do
    has "$file /root/kindi-target-deploy/$file"
done
has 'bash /root/kindi-target-deploy/install-target.sh'
has 'KINDI_REF=main'
pin=$(< "$here/upstream-commit.txt")
has "KINDI_COMMIT=$pin"
has 'KINDI_BACKEND=cpu'
has 'KINDI_MODEL=auto'
has 'KINDI_PORT=8093'
has 'KINDI_CONTEXT=auto'
has 'KINDI_HEAD=exact'
has 'KINDI_SPEC=auto'
has 'KINDI_VERIFY=true'
has 'KINDI_PYTHON_VERSION=3.9.25'
has 'KINDI_READY_TIMEOUT=1800'
has 'add kindi://<CT address>:8093'
lacks 'https://github.com/ahtx/kindi.git'   # fetching happens inside the CT
lacks 'huggingface.co'                      # and so does every download

plan KINDI_BACKEND=cpu KINDI_MODEL=bonsai-9b KINDI_THREADS=12 ROOTFS_GB=16 MEMORY_MB=8192 IP_CIDR=dhcp GATEWAY=
has 'KINDI_MODEL=bonsai-9b'
has 'KINDI_THREADS=12'
has '--rootfs local-lvm:16'
has 'ip=dhcp\,firewall=1'
lacks 'gw='
lacks 'CPU engine (KINDI_BACKEND=cpu). To use'

# CUDA: chosen from the NVIDIA nodes in GPU_DEVICES.
plan "${cuda[@]}"
has 'no NVIDIA driver is loaded on this host; a real run stops here until bash'
has 'KINDI_BACKEND=cuda'
has 'CUDA 10.2 (NVIDIA'\''s runfile, toolkit only) can be installed on debian13'
has '--dev0 path=/dev/nvidia0\,gid=44\,mode=0660'
has '--dev1 path=/dev/nvidiactl\,gid=44\,mode=0660'
has '--dev2 path=/dev/nvidia-uvm\,gid=44\,mode=0660'
lacks 'gid=0\,'
has 'install-nvidia-driver.sh /root/kindi-target-deploy/install-nvidia-driver.sh'
has 'install-nvidia-driver.sh lxc'
has 'DRIVER_VERSION='
plan "${cuda[@]}" TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst KINDI_MODEL=bonsai-27b \
    KINDI_PORT=11434 KINDI_CONTEXT=65536 KINDI_HEAD=fast KINDI_SPEC=off
has '--ostype ubuntu'
has 'can be installed on ubuntu2404'
has 'KINDI_MODEL=bonsai-27b'
has 'KINDI_PORT=11434'
has 'KINDI_CONTEXT=65536'
has 'KINDI_HEAD=fast'
has 'KINDI_SPEC=off'
plan "${cuda[@]}" NVIDIA_DRIVER_VERSION=470.256.02 GPU_DEVICES='/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
has '--dev0 path=/dev/nvidia1'
has '--dev3 path=/dev/nvidia-uvm-tools'
has 'DRIVER_VERSION=470.256.02'

# A host whose NVIDIA driver lists a card: auto picks CUDA and GPU 0.
hostenv=("PATH=$scratch/nvidia:$PATH")
plan
has 'KINDI_BACKEND=cuda'
has '--dev0 path=/dev/nvidia0'
lacks 'CPU engine'
plan KINDI_BACKEND=cpu
has 'KINDI_BACKEND=cpu'
lacks '--dev0'
hostenv=("PATH=$scratch/none:$PATH")

plan VLAN_TAG=30 NAMESERVER=192.0.2.53 CORES=16 MEMORY_MB=32768 ROOTFS_GB=200 GPU_GID=1000 "${cuda[@]}"
has 'tag=30'
has '--nameserver 192.0.2.53'
has '--cores 16'
has '--memory 32768'
has '--rootfs local-lvm:200'
has 'path=/dev/nvidia0\,gid=1000\,mode=0660'

reject 'CT_ID' CT_ID=99
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'GATEWAY' GATEWAY=
reject 'Debian 12/13 or Ubuntu 22.04/24.04' TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
reject 'TEMPLATE' TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_arm64.tar.zst
reject 'TEMPLATE' TEMPLATE=local:vztmpl/alpine-3.20-default_20240908_amd64.tar.xz
reject 'Duplicate GPU device' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia0'
reject 'must include one /dev/nvidiaN' GPU_DEVICES='/dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
reject 'must include one /dev/nvidiaN' GPU_DEVICES='/dev/nvidia0 /dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm'
reject 'Invalid GPU device path' GPU_DEVICES='/dev/nvidia0 /dev/../dev/nvidiactl /dev/nvidia-uvm'
reject 'GPU_DEVICES is for KINDI_BACKEND=cuda' KINDI_BACKEND=cpu "${cuda[@]}"
reject 'GPU_GID' GPU_GID=0
reject 'KINDI_BACKEND must be' KINDI_BACKEND=rocm
reject 'MEMORY_MB must be at least 4096' MEMORY_MB=2048
reject 'ROOTFS_GB must be at least 32' ROOTFS_GB=20 "${cuda[@]}"
reject 'ROOTFS_GB must be at least 16' ROOTFS_GB=8
reject 'KINDI_PORT' KINDI_PORT=70000
reject 'KINDI_COMMIT' KINDI_COMMIT=bad
reject 'KINDI_REF' KINDI_REF='a..b'
reject 'KINDI_MODEL must be' KINDI_MODEL=bonsai-70b
reject "CPU engine runs bonsai-2b, bonsai-4b and bonsai-9b" KINDI_MODEL=bonsai-27b
reject 'KINDI_PROFILE must be' KINDI_PROFILE=ampere
reject 'cpu profile needs KINDI_BACKEND=cpu' "${cuda[@]}" KINDI_PROFILE=cpu
reject 'KINDI_THREADS is for the CPU engine' "${cuda[@]}" KINDI_THREADS=8
reject 'KINDI_CONTEXT' KINDI_CONTEXT=512
reject 'KINDI_CONTEXT' KINDI_CONTEXT=524288
reject 'KINDI_HEAD' KINDI_HEAD=approx
reject 'KINDI_SPEC' KINDI_SPEC=on
reject 'KINDI_MODEL_NAME' KINDI_MODEL_NAME='Bonsai 27B'
reject 'KINDI_VERIFY' KINDI_VERIFY=yes
reject 'KINDI_PYTHON_VERSION' KINDI_PYTHON_VERSION=3.12.3
reject 'KINDI_READY_TIMEOUT' KINDI_READY_TIMEOUT=0
reject 'VLAN_TAG' VLAN_TAG=5000
reject 'SSH_PUBLIC_KEY' SSH_PUBLIC_KEY=/nonexistent/key.pub
reject 'CUDA 10.2 needs NVIDIA driver 440.33 or newer' "${cuda[@]}" NVIDIA_DRIVER_VERSION=418.226.00

# A real run off a Proxmox host stops before anything is created.
if output=$(env -i "PATH=$scratch/none:$PATH" "${common[@]}" "${cuda[@]}" bash "$provision" 2>&1); then
    printf 'FAIL a real run went on without a GPU driver\n' >&2; exit 1
fi
if (( EUID == 0 )); then has 'Missing PVE command: pveversion'; else has 'Run as root on the PVE host'; fi
lacks '+ pct create '
passed=$((passed + 1))

# The guest installer's own plan.
output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has 'bash cuda-toolkit.sh (CUDA 10.2 toolkit from NVIDIA'\''s runfile, toolkit only'
has "git fetch --depth 1 https://github.com/ahtx/kindi.git $pin into /opt/kindi (as kindi)"
has 'Python 3.9.25; /opt/kindi/.venv from requirements-cuda.lock (hash-checked)'
has 'kindi convert into /var/lib/kindi/packs; kindi verify'
has 'the key [redacted]'
has 'systemctl enable kindi.service'
has '(up to 1800s)'
lacks 'sudo'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" KINDI_BACKEND=cpu KINDI_MODEL=bonsai-4b KINDI_HEAD=fast KINDI_REF=dev bash "$guest" --dry-run 2>&1)
has 'kindi.git dev into'
has 'requirements-cpu.lock'
has 'GGUF of bonsai-4b'
has 'kindi verify; kindi fast-head'
lacks 'cuda-toolkit.sh'
passed=$((passed + 1))

installed=$scratch/installed
mkdir -p "$installed/opt/kindi/.git" "$installed/etc/systemd/system" "$installed/etc/kindi-target"
: > "$installed/etc/systemd/system/kindi.service"
# An installed target has a settings record; a rerun plans from it.
printf 'KINDI_BACKEND=cuda\nKINDI_MODEL=bonsai-27b\nKINDI_PROFILE=pascal8\nKINDI_PORT=8123\nKINDI_CONTEXT=65536\nKINDI_HEAD=exact\nKINDI_SPEC=auto\nKINDI_THREADS=auto\nKINDI_MODEL_NAME=bonsai2-27b\nKINDI_PYTHON_VERSION=3.9.25\n' \
    > "$installed/etc/kindi-target/installed-env"
rerun_plan() {
    env -i "PATH=$PATH" KINDI_DIR="$installed/opt/kindi" KINDI_ETC_DIR="$installed/etc/kindi-target" \
        UNIT_DIR="$installed/etc/systemd/system" bash "$guest" --dry-run 2>&1
}
output=$(rerun_plan)
has "kindi.git $pin (before anything is stopped"
has 'while the service keeps running'
has 'nothing to do'
has 'previous commit locally (no network)'
has 'configured on TCP 8123 (model bonsai2-27b, cuda)'
passed=$((passed + 1))

# Without any settings record the same checkout is refused, not planned with
# fresh-install defaults.
rm "$installed/etc/kindi-target/installed-env"
if output=$(rerun_plan); then
    printf 'FAIL a checkout without a settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Found an existing'
has 'no readable settings record'

for bad in "KINDI_REF=a..b|Invalid KINDI_REF" "KINDI_CONTEXT=0|KINDI_CONTEXT must be" \
           "KINDI_PROFILE=ampere|KINDI_PROFILE must be" "KINDI_HEAD=1|KINDI_HEAD must be" \
           "KINDI_BACKEND=vulkan|KINDI_BACKEND must be" "KINDI_VERIFY=1|KINDI_VERIFY must be" \
           "KINDI_PYTHON_VERSION=3.11.2|KINDI_PYTHON_VERSION must be"; do
    if output=$(env -i "PATH=$PATH" "${bad%%|*}" bash "$guest" --dry-run 2>&1); then
        printf 'FAIL accepted %s\n' "${bad%%|*}" >&2; exit 1
    fi
    has "${bad#*|}"
done
passed=$((passed + 1))

unit=$here/kindi.service
grep -Fqx 'ExecStart=/opt/kindi/.venv/bin/python -m kindi serve' "$unit"
grep -q '^EnvironmentFile=/etc/kindi-target/kindi.env$' "$unit"
grep -q '^Environment=KINDI_CONFIG=/etc/kindi/kindi.conf$' "$unit"
grep -q '^User=kindi$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
# The checkout stays read-only for the service: only data and shared memory are writable.
grep -q '^ReadWritePaths=/var/lib/kindi /dev/shm$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"   # the GPU nodes must stay visible
if grep -qi 'api.key' <(grep -v '^#' "$unit"); then printf 'FAIL the unit carries a key setting\n' >&2; exit 1; fi
passed=$((passed + 1))

bash -n "$provision"
bash -n "$guest"
bash -n "$here/cuda-toolkit.sh"
printf '%s Kindi dry-run cases and shell syntax checks passed. No CT was created.\n' "$passed"
