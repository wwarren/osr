#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
#
# Colibri differs from the other model targets in two ways this file is built
# around: GPU passthrough is optional (it runs on the CPU), and no model is ever
# fetched, so the service is expected to come up parked.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
fake=$(mktemp -d "${TMPDIR:-/tmp}/colibri-provision-test.XXXXXX")
trap 'rm -rf -- "$fake"' EXIT
mkdir -p "$fake/bin" "$fake/none"
cat > "$fake/bin/nvidia-smi" <<'SMI'
#!/bin/sh
printf '00000000:01:00.0, %s\n' "${FAKE_VRAM_MIB:-16311}"
SMI
chmod +x "$fake/bin/nvidia-smi"

pin=$(sed -n 's/^COLIBRI_DEFAULT_COMMIT=\([0-9a-f]\{40\}\)$/\1/p' "$here/install-target.sh")
[[ $pin =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL missing Colibri test pin' >&2; exit 1; }

# A GPU CT by default; the CPU-only case passes GPU_DEVICES= explicitly.
common=(CT_ID=280 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1
        GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm')
passed=0

has()   { [[ $output == *"$1"* ]] || { printf 'FAIL missing %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
lacks() { [[ $output != *"$1"* ]] || { printf 'FAIL unexpected %s\n%s\n' "$1" "$output" >&2; exit 1; }; }
plan() {
    output=$(env -i "PATH=$fake/bin:$PATH" "${common[@]}" "$@" "NVIDIA_PROC=$fake/none" \
        bash "$provision" --dry-run 2>&1) || {
        printf 'FAIL plan\n%s\n' "$output" >&2; exit 1; }
    passed=$((passed + 1))
}
reject() {
    local reason=$1; shift
    if output=$(env -i "PATH=$fake/bin:$PATH" "${common[@]}" "$@" "NVIDIA_PROC=$fake/none" \
        bash "$provision" --dry-run 2>&1); then
        printf 'FAIL accepted invalid setting\n%s\n' "$output" >&2; exit 1
    fi
    has "$reason"; lacks '+ pct create '
    passed=$((passed + 1))
}

# --- the container itself -----------------------------------------------------
plan
has '+ pct create 280 '
has '--unprivileged 1'
has '--features nesting=1'
has '--tags ai\;ai-model\;osr-target\;colibri'
has '--memory 65536'
has '--rootfs local-lvm:160'
has 'lxc.prlimit.memlock: unlimited'
has 'ip=192.0.2.80/24\,firewall=1'; has 'gw=192.0.2.1'
lacks 'gid=0\,'
# It is pushed into the CT and run there; the clone happens inside the CT.
has 'bash /root/colibri-target-deploy/install-target.sh'
has '/root/colibri-target-deploy/install-target.sh --perms 0755'
has '/root/colibri-target-deploy/colibri.service --perms 0644'
lacks 'git clone'
# Settings the guest installer is launched with.
has "COLIBRI_COMMIT=$pin"; has 'COLIBRI_REF=main'
has 'COLIBRI_BACKEND=auto'; has 'COLIBRI_HOST=0.0.0.0'; has 'COLIBRI_PORT=8080'
has 'COLIBRI_READY_TIMEOUT=900'
# Nothing is asked and nothing is downloaded: the model is left to the operator.
has '/var/lib/colibri/model, created empty (parked until a model is copied in; none is downloaded)'
has 'COLIBRI_MODEL_DIR=/var/lib/colibri/model'
lacks '== Colibri settings =='
# The closing lines name the router's colibri kind and its token command.
has 'manage-model-servers set-colibri-token'; has 'add colibri://<CT address>:8080'
lacks 'colibri+http'

# --- GPU passthrough is optional ---------------------------------------------
# A GPU CT gets the nodes and the guest driver, and the driver must be new enough.
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'path=/dev/nvidia-uvm\,gid=44\,mode=0660'
has 'nvidia-guest-install.sh lxc'; has 'DRIVER_VERSION='
plan NVIDIA_DRIVER_VERSION=590.48.01
has 'DRIVER_VERSION=590.48.01'
reject 'CUDA 13 needs NVIDIA driver 580 or newer' NVIDIA_DRIVER_VERSION=575.64.05
plan GPU_GID=1000
has 'path=/dev/nvidia0\,gid=1000\,mode=0660'
plan GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
has '--dev3 path=/dev/nvidia-uvm-tools'

# With no devices it is a CPU-only CT: no --devN line, no driver install, and
# nvidia-smi is not required at all.
plan GPU_DEVICES=
lacks 'path=/dev/nvidia'; lacks 'DRIVER_VERSION='
has 'COLIBRI_BACKEND=auto'
plan COLIBRI_BACKEND=cpu GPU_DEVICES=
has 'COLIBRI_BACKEND=cpu'; lacks 'path=/dev/nvidia'
has 'none (CPU)'
reject 'must include /dev/nvidiaN' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl'
reject 'Duplicate GPU device' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia0'
# Vulkan on AMD Radeon or Intel Arc: the card's render node, at the same gid,
# and no NVIDIA user-space (install-target.sh installs Mesa's Vulkan driver).
plan COLIBRI_BACKEND=vulkan GPU_DEVICES=/dev/dri/renderD128
has '--dev0 path=/dev/dri/renderD128\,gid=44\,mode=0660'
has 'COLIBRI_BACKEND=vulkan'; has 'render node (Vulkan): /dev/dri/renderD128'
lacks 'DRIVER_VERSION='; lacks 'nvidia-guest-install.sh lxc'
plan GPU_DEVICES=/dev/dri/renderD129
has 'path=/dev/dri/renderD129'; has 'COLIBRI_BACKEND=auto'
reject 'mixes NVIDIA nodes and a render node' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/dri/renderD128'
reject 'takes NVIDIA nodes (/dev/nvidia*) or a render node' GPU_DEVICES=/dev/dri/card0
# An explicit GPU backend needs its device, or the CT would quietly run on the CPU.
reject 'COLIBRI_BACKEND=cuda needs the NVIDIA nodes' COLIBRI_BACKEND=cuda GPU_DEVICES=
reject 'COLIBRI_BACKEND=vulkan needs the card' COLIBRI_BACKEND=vulkan GPU_DEVICES=
reject 'COLIBRI_BACKEND=vulkan needs the card' COLIBRI_BACKEND=vulkan

# --- Colibri settings ---------------------------------------------------------
plan COLIBRI_BACKEND=cuda
has 'COLIBRI_BACKEND=cuda'
plan COLIBRI_MODEL_DIR=/var/lib/colibri/models/qwen
has 'COLIBRI_MODEL_DIR=/var/lib/colibri/models/qwen'
has '/var/lib/colibri/models/qwen, created empty'
plan COLIBRI_HOST=127.0.0.1 COLIBRI_ALLOWED_HOST=colibri.internal,192.0.2.80 COLIBRI_PORT=11434
has 'COLIBRI_HOST=127.0.0.1'; has 'COLIBRI_ALLOWED_HOST=colibri.internal\,192.0.2.80'
has 'COLIBRI_PORT=11434'; has 'host 127.0.0.1, port 11434'
plan COLIBRI_REF=v0.1.40
has 'COLIBRI_REF=v0.1.40'; has 'COLIBRI_COMMIT='
plan COLIBRI_COMMIT=
has 'COLIBRI_REF=main'; has 'COLIBRI_COMMIT='

plan IP_CIDR=dhcp GATEWAY=
has 'ip=dhcp\,firewall=1'; lacks 'gw='

reject 'COLIBRI_BACKEND must be auto, cpu, vulkan or cuda' COLIBRI_BACKEND=metal
reject 'COLIBRI_MODEL_DIR must be empty or an absolute path' COLIBRI_MODEL_DIR=relative/path
reject 'COLIBRI_MODEL_DIR must be empty or an absolute path' COLIBRI_MODEL_DIR='/var/lib/colibri/../etc'
reject 'COLIBRI_ALLOWED_HOST' COLIBRI_ALLOWED_HOST='bad host'
reject 'COLIBRI_PORT' COLIBRI_PORT=70000
reject 'COLIBRI_COMMIT' COLIBRI_COMMIT=bad
reject 'GPU_GID' GPU_GID=0
reject 'MEMORY_MB must be at least 8192' MEMORY_MB=4096
reject 'ROOTFS_GB must be at least 40' ROOTFS_GB=20
reject 'CT_ID' CT_ID=99
reject 'Set CT_ID for unattended provisioning' CT_ID=
reject 'Set TEMPLATE for unattended provisioning' TEMPLATE=
reject 'Set STORAGE for unattended provisioning' STORAGE=
reject 'Set IP_CIDR for unattended provisioning' IP_CIDR=
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'TEMPLATE' TEMPLATE=local:vztmpl/alpine-3.20-standard_amd64.tar.zst

# --- the guest installer, as the provisioner launches it ----------------------
# It runs as root inside the CT; a dry run must plan without touching anything.
output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1) || {
    printf 'FAIL guest dry run\n%s\n' "$output" >&2; exit 1; }
has "make -C /opt/colibri/c install"          # one make call builds and installs
has 'PREFIX=/opt/colibri'
has '--host 0.0.0.0 --port 8080'
# Bound to every address, the router reaches it by the CT's IP, which the
# DNS-rebinding guard only accepts when allowed: * (the key still applies).
has '--allowed-host * --model /var/lib/colibri/model --auto-tier'
lacks '--allowed-host 0.0.0.0'
lacks '--api-key'                             # the key is never on a command line
has 'secrets.env (0600: COLI_API_KEY)'
has 'COLIBRI_RUN_SCRIPT'
has 'systemctl enable colibri.service'
has 'systemctl restart colibri.service'
has 'serve the model in /var/lib/colibri/model (parked while it is empty)'
has '--model /var/lib/colibri/model'
lacks 'setup.sh --help'                       # colibri has no such option audit
lacks 'sudo'
passed=$((passed + 1))

# An explicit allowlist is kept, one --allowed-host per entry.
output=$(env -i "PATH=$PATH" COLIBRI_ALLOWED_HOST=colibri.lan,192.0.2.80 bash "$guest" --dry-run 2>&1) || {
    printf 'FAIL guest dry run with an allowlist\n%s\n' "$output" >&2; exit 1; }
has '--allowed-host colibri.lan,192.0.2.80'
output=$(env -i "PATH=$PATH" COLIBRI_ALLOWED_HOST='a,,b' bash "$guest" --dry-run 2>&1) && {
    printf 'FAIL accepted an empty COLIBRI_ALLOWED_HOST entry\n' >&2; exit 1; }
has 'Invalid COLIBRI_ALLOWED_HOST'
passed=$((passed + 1))

# A parked install is a success, not a timeout: the readiness wait says so.
output=$(env -i "PATH=$PATH" COLIBRI_BACKEND=metal bash "$guest" --dry-run 2>&1) && {
    printf 'FAIL accepted COLIBRI_BACKEND=metal\n' >&2; exit 1; }
has 'COLIBRI_BACKEND must be auto, cpu, vulkan or cuda'
passed=$((passed + 1))

# --- the unit file ------------------------------------------------------------
unit=$here/colibri.service
grep -Fqx 'ExecStart=/bin/sh ${COLIBRI_RUN_SCRIPT}' "$unit"
grep -q '^EnvironmentFile=/etc/colibri-target/colibri.env$' "$unit"
grep -q '^EnvironmentFile=/etc/colibri-target/secrets.env$' "$unit"
! grep -q 'COLIBRI_EXECV' "$unit"
grep -q '^User=colibri$' "$unit"
grep -q '^Group=colibri$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
grep -q '^ReadWritePaths=/opt/colibri /var/lib/colibri$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"     # GPU nodes must stay visible
grep -q '^LimitMEMLOCK=infinity$' "$unit"
passed=$((passed + 1))

bash -n "$provision"
bash -n "$guest"
printf '%s Colibri dry-run cases and shell syntax checks passed. No CT was created.\n' "$passed"
