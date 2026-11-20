#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
#
# GPU passthrough and model download are both optional. Dry runs never fetch a
# model or create a CT; without an explicit model choice, the service parks.
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
# tools/setup-host-gpu.sh as the provisioner calls it with no GPU_DEVICES: it
# logs its arguments and reports the host FAKE_GPU names (absent, nvidia, amd,
# declined, reboot), failing as the real tool does when --need required finds
# no GPU.
cat > "$fake/setup-host-gpu.sh" <<'TOOL'
printf '%s\n' "$*" > "$FAKE_GPU_LOG"
need=optional; card=''
while (( $# )); do case $1 in --need) need=$2; shift ;; --card) card=$2; shift ;; esac; shift; done
case ${FAKE_GPU:-absent} in
    nvidia) printf 'GPU_STATE=ready\nGPU_VENDOR=nvidia\nGPU_CUDA_ARCH=120\nGPU_PCI=%s\nGPU_NVIDIA_MINOR=%s\n' "${card:-0000:01:00.0}" "${FAKE_GPU_MINOR-0}" ;;
    # A dry run on a host without the NVIDIA driver: planned, and no minor yet.
    nvidia-planned) printf 'GPU_STATE=planned\nGPU_GENERATION=rtx50\nGPU_VENDOR=nvidia\nGPU_PCI=%s\nGPU_NVIDIA_MINOR=\n' "${card:-}" ;;
    amd) printf 'GPU_STATE=ready\nGPU_VENDOR=amd\nGPU_RENDER_NODE=/dev/dri/renderD129\nGPU_PCI=0000:03:00.0\nGPU_NVIDIA_MINOR=\n' ;;
    reboot) echo 'reboot needed' >&2; exit 2 ;;
    *)
        if [[ $need == required ]]; then echo 'Error: no GPU on this host' >&2; exit 1; fi
        printf 'GPU_STATE=%s\nGPU_VENDOR=\n' "${FAKE_GPU:-absent}" ;;
esac
TOOL
gpu_log=$fake/gpu-tool.log

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
    : > "$gpu_log"
    output=$(env -i "PATH=$fake/bin:$PATH" "HOST_GPU_TOOL=$fake/setup-host-gpu.sh" "FAKE_GPU_LOG=$gpu_log" \
        "${common[@]}" "$@" "NVIDIA_PROC=$fake/none" \
        bash "$provision" --dry-run 2>&1) || {
        printf 'FAIL plan\n%s\n' "$output" >&2; exit 1; }
    passed=$((passed + 1))
}
reject() {
    local reason=$1; shift
    : > "$gpu_log"
    if output=$(env -i "PATH=$fake/bin:$PATH" "HOST_GPU_TOOL=$fake/setup-host-gpu.sh" "FAKE_GPU_LOG=$gpu_log" \
        "${common[@]}" "$@" "NVIDIA_PROC=$fake/none" \
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
has '/root/colibri-target-deploy/model-select.sh --perms 0644'
lacks 'git clone'
# Settings the guest installer is launched with.
has "COLIBRI_COMMIT=$pin"; has 'COLIBRI_REF=main'
has 'COLIBRI_BACKEND=auto'; has 'COLIBRI_HOST=0.0.0.0'; has 'COLIBRI_PORT=8080'
has 'COLIBRI_READY_TIMEOUT=900'
# An unattended run without an explicit model remains parked.
has '/var/lib/colibri/model, created empty (parked until a model is copied in; none is downloaded)'
has 'COLIBRI_MODEL_DIR=/var/lib/colibri/model'
has 'COLIBRI_MODEL_ID='
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

# Named devices are used as given: the host GPU tool is not asked.
[[ ! -s $gpu_log ]] || { printf 'FAIL the host GPU tool ran although GPU_DEVICES was given: %s\n' "$(cat "$gpu_log")" >&2; exit 1; }

# --- No GPU_DEVICES: the host's GPU is found ----------------------------------
# The host tool checks (and with consent sets up) the driver for any vendor
# Colibri can use; an NVIDIA GPU gives CUDA with that card's nodes and the
# guest's NVIDIA user-space.
plan GPU_DEVICES= FAKE_GPU=nvidia
grep -qx -- '--need optional --vendors nvidia,amd,intel --for Colibri --amd-render-only --dry-run' "$gpu_log" ||
    { printf 'FAIL host GPU tool called as: %s\n' "$(cat "$gpu_log")" >&2; exit 1; }
has '--dev0 path=/dev/nvidia0\,gid=44\,mode=0660'; has 'path=/dev/nvidiactl'; has 'path=/dev/nvidia-uvm\,'
has 'COLIBRI_BACKEND=cuda'; has 'nvidia-guest-install.sh lxc'; has 'DRIVER_VERSION='
has 'found on this host: nvidia at 0000:01:00.0'
# The card's own minor, e.g. a second GPU, and GPU_CARD picks the card.
plan GPU_DEVICES= FAKE_GPU=nvidia FAKE_GPU_MINOR=1 GPU_CARD=0000:02:00.0
grep -q -- '--card 0000:02:00.0' "$gpu_log" || { printf 'FAIL GPU_CARD did not reach the host GPU tool: %s\n' "$(cat "$gpu_log")" >&2; exit 1; }
has '--dev0 path=/dev/nvidia1\,gid=44'; has 'nvidia at 0000:02:00.0'
reject 'could not identify /dev/nvidia<minor> for GPU_CARD=0000:02:00.0' \
    GPU_DEVICES= FAKE_GPU=nvidia FAKE_GPU_MINOR= GPU_CARD=0000:02:00.0
# Before the driver is installed a dry run cannot know the card's minor: it
# still plans, and says that a real run maps the card's own minor.
plan GPU_DEVICES= FAKE_GPU=nvidia-planned GPU_CARD=0000:02:00.0
has 'COLIBRI_BACKEND=cuda'; has 'path=/dev/nvidiactl'
has "Note: GPU_CARD=0000:02:00.0 (dry run: the NVIDIA driver is not installed yet, so this card's /dev/nvidia<minor> is unknown"
has 'a real run maps the card'"'"'s own minor)'
# Without GPU_CARD the planned GPU is the driver's GPU 0, so nothing is pending.
plan GPU_DEVICES= FAKE_GPU=nvidia-planned
has 'path=/dev/nvidia0'; lacks 'is unknown'
reject 'GPU_CARD must be a PCI address' GPU_DEVICES= GPU_CARD=gpu0
# An AMD Radeon or Intel Arc GPU gives Vulkan with its render node, no NVIDIA user-space.
plan GPU_DEVICES= FAKE_GPU=amd
has '--dev0 path=/dev/dri/renderD129\,gid=44\,mode=0660'; has 'COLIBRI_BACKEND=vulkan'
lacks 'DRIVER_VERSION='; lacks 'nvidia-guest-install.sh lxc'
# No usable GPU (none on the bus, or its driver setup declined): the CPU, said so.
plan GPU_DEVICES=
lacks 'path=/dev/nvidia'; lacks 'DRIVER_VERSION='
has 'COLIBRI_BACKEND=auto'; has 'no usable GPU on this host (absent); Colibri runs on the CPU'
plan GPU_DEVICES= FAKE_GPU=declined
has 'no usable GPU on this host (declined)'; lacks 'path=/dev/'
# A driver that needs a reboot stops before anything is created.
reject 'Reboot this host, then run this again' GPU_DEVICES= FAKE_GPU=reboot
# cpu never looks for a GPU.
plan COLIBRI_BACKEND=cpu GPU_DEVICES= FAKE_GPU=nvidia
[[ ! -s $gpu_log ]] || { printf 'FAIL COLIBRI_BACKEND=cpu ran the host GPU tool\n' >&2; exit 1; }
has 'COLIBRI_BACKEND=cpu'; lacks 'path=/dev/nvidia'
has 'none (CPU)'
# An explicit backend asks only for its vendors, and needs its GPU.
plan COLIBRI_BACKEND=cuda GPU_DEVICES= FAKE_GPU=nvidia
grep -q -- '--need required --vendors nvidia ' "$gpu_log" || { printf 'FAIL cuda asked: %s\n' "$(cat "$gpu_log")" >&2; exit 1; }
has 'path=/dev/nvidia0'; has 'COLIBRI_BACKEND=cuda'
plan COLIBRI_BACKEND=vulkan GPU_DEVICES= FAKE_GPU=amd
grep -q -- '--need required --vendors amd,intel ' "$gpu_log" || { printf 'FAIL vulkan asked: %s\n' "$(cat "$gpu_log")" >&2; exit 1; }
grep -q -- '--amd-render-only' "$gpu_log" || { printf 'FAIL vulkan did not allow render-only AMD: %s\n' "$(cat "$gpu_log")" >&2; exit 1; }
has 'path=/dev/dri/renderD129'
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
reject "The host's GPU is not ready for COLIBRI_BACKEND=cuda" COLIBRI_BACKEND=cuda GPU_DEVICES=
reject "The host's GPU is not ready for COLIBRI_BACKEND=vulkan" COLIBRI_BACKEND=vulkan GPU_DEVICES=
reject 'COLIBRI_BACKEND=vulkan needs the card' COLIBRI_BACKEND=vulkan GPU_DEVICES=/dev/nvidia0\ /dev/nvidiactl\ /dev/nvidia-uvm

# --- Colibri settings ---------------------------------------------------------
plan COLIBRI_BACKEND=cuda
has 'COLIBRI_BACKEND=cuda'
plan COLIBRI_MODEL_DIR=/var/lib/colibri/models/qwen
has 'COLIBRI_MODEL_DIR=/var/lib/colibri/models/qwen'
has '/var/lib/colibri/models/qwen, created empty'
source "$here/model-select.sh"
[[ $(colibri_model_recommend 8192 cpu) == qwen3-coder-30b ]] || { echo 'FAIL 8 GiB recommendation' >&2; exit 1; }
[[ $(colibri_model_recommend 12288 cpu) == qwen3-coder-30b ]] || { echo 'FAIL CPU recommendation' >&2; exit 1; }
[[ $(colibri_model_recommend 12288 cuda) == qwen36-35b ]] || { echo 'FAIL GPU recommendation' >&2; exit 1; }
[[ $(colibri_model_recommend 65536 cpu) == qwen36-35b ]] || { echo 'FAIL 64 GiB recommendation' >&2; exit 1; }
plan COLIBRI_MODEL_ID=qwen36-35b
has 'Qwen3.6-35B-A3B (23.1 GB) from Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64'
has 'COLIBRI_MODEL_ID=qwen36-35b'
plan COLIBRI_MODEL_ID=qwen3-coder-30b MEMORY_MB=8192 GPU_DEVICES=
has 'Qwen3-Coder-30B-A3B (19.4 GB)'
reject 'qwen36-35b does not fit this CT: needs 10 GiB RAM' COLIBRI_MODEL_ID=qwen36-35b MEMORY_MB=8192
# The model goes on the root disk: a model larger than it is refused, a larger
# root disk takes it. Every catalog ID is accepted where it fits.
reject 'glm-5.2 does not fit this CT: needs 429.3 GB disk' COLIBRI_MODEL_ID=glm-5.2
plan COLIBRI_MODEL_ID=qwen-image-2.1
has 'Qwen-Image-2.1 (33.1 GB) from Qwen/Qwen-Image-2.1'; has 'It draws pictures (POST /v1/images/generations)'
has 'webui-images.sh --expect-model qwen-image-2.1-colibri'
plan COLIBRI_MODEL_ID=glm-5.3 ROOTFS_GB=500
has 'GLM-5.3 (419.3 GB) from Justvugg/GLM-5.3-colibri-int4-g64'
plan COLIBRI_MODEL_ID=kimi-k3 ROOTFS_GB=1700
has 'Kimi K3 (1561.0 GB) from moonshotai/Kimi-K3'
reject 'inkling does not fit this CT: needs 120 GiB RAM' COLIBRI_MODEL_ID=inkling ROOTFS_GB=600
reject 'COLIBRI_MODEL_ID=remove only applies to an installed CT' COLIBRI_MODEL_ID=remove
# Unattended with no ID: a suggestion and how to opt in, nothing downloaded.
plan
has 'Colibri suggestion for 65536 MiB RAM'; has 'set COLIBRI_MODEL_ID=qwen36-35b (or another ID of model-select.sh)'
# none is the OSR installer's answer already given: nothing suggested again.
plan COLIBRI_MODEL_ID=none
lacks 'Colibri suggestion'; has 'COLIBRI_MODEL_ID= '; has 'none is downloaded'
reject 'COLIBRI_MODEL_ID must be' COLIBRI_MODEL_ID=unknown
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

output=$(env -i "PATH=$PATH" COLIBRI_MODEL_ID=qwen36-35b bash "$guest" --dry-run 2>&1) || {
    printf 'FAIL guest model dry run\n%s\n' "$output" >&2; exit 1; }
has 'download Qwen3.6-35B-A3B (23.1 GB)'
has 'Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64'
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

# --- --reconfigure: an existing CT, read through a fake pct ------------------
# FAKE_MANIFEST is the served model's download manifest (none: nothing served),
# FAKE_FREE the free bytes on its filesystem; FAKE_STAGED a resumable download.
cat > "$fake/bin/pct" <<'PCT'
#!/usr/bin/env bash
case "$1 $*" in
    status*) [[ ${FAKE_CT:-running} == missing ]] && exit 2; echo "status: ${FAKE_CT:-running}" ;;
    config*) printf 'arch: amd64\nmemory: %s\nrootfs: local-lvm:vm-280-disk-0,size=160G\n' "${FAKE_MEMORY:-65536}"
             [[ ${FAKE_GPU_LINE:-nvidia} != nvidia ]] || printf 'dev0: path=/dev/nvidia0,gid=44,mode=0660\n'
             [[ ${FAKE_GPU_LINE:-} != amd ]] || printf 'dev0: path=/dev/dri/renderD128,gid=44,mode=0660\n' ;;
    *' test -x /opt/colibri/bin/coli') [[ ${FAKE_INSTALLED:-1} == 1 ]] ;;
    *installed-env) echo /srv/models/colibri ;;  # the value sed prints in the CT
    *' df -PB1 '*) printf 'Filesystem 1B-blocks Used Available Use%% Mounted\nfake 0 0 %s 0%% /\n' "${FAKE_FREE:-200000000000}" ;;
    *'.colibri-staging'*) [[ ${FAKE_STAGED:-0} == 0 ]] || printf '%s /srv/models/colibri/.colibri-staging/partial\n' "$FAKE_STAGED" ;;
    *' cat '*) [[ ${FAKE_MANIFEST:-none} != none ]] || exit 1
               printf '{"repo": "%s", "revision": "%s", "complete": true}\n' "${FAKE_MANIFEST%@*}" "${FAKE_MANIFEST#*@}" ;;
    *' find '*) [[ ${FAKE_HAND:-0} == 0 ]] || echo /srv/models/colibri/weights.bin ;;
    *) echo "unexpected pct $*" >&2; exit 9 ;;
esac
PCT
chmod +x "$fake/bin/pct"
coder=Justvugg/Qwen3-Coder-30B-A3B-colibri-int4@d839110a17d31b4e6fa9f3d973b751f779b6b9c6
reconf() {
    output=$(env -i "PATH=$fake/bin:$PATH" CT_ID=280 "$@" bash "$provision" --reconfigure --dry-run 2>&1) || {
        printf 'FAIL reconfigure plan\n%s\n' "$output" >&2; exit 1; }
    passed=$((passed + 1))
}
reconf_reject() {
    local reason=$1; shift
    if output=$(env -i "PATH=$fake/bin:$PATH" CT_ID=280 "$@" bash "$provision" --reconfigure --dry-run 2>&1); then
        printf 'FAIL reconfigure accepted\n%s\n' "$output" >&2; exit 1
    fi
    has "$reason"; lacks '+ pct push'
    passed=$((passed + 1))
}
reconf FAKE_MANIFEST=$coder COLIBRI_MODEL_ID=glm-5.3 FAKE_FREE=600000000000
has 'Colibri: change the model of CT 280'; has '65536 MiB, cuda, 598 GB free for the model'
has 'Served now                 Qwen3-Coder-30B-A3B (19.4 GB) in /srv/models/colibri'
has 'serve GLM-5.3 (419.3 GB from Justvugg/GLM-5.3-colibri-int4-g64@3930f4bb756e)'
has '/root/colibri-target-deploy/model-select.sh --perms 0644'
has 'env NONINTERACTIVE=true COLIBRI_MODEL_ID=glm-5.3 bash /root/colibri-target-deploy/install-target.sh --model'
lacks '+ pct create'
reconf FAKE_MANIFEST=$coder COLIBRI_MODEL_ID=qwen3-coder-30b
has 'Nothing to change.'; lacks '+ pct push'
reconf FAKE_MANIFEST=$coder COLIBRI_MODEL_ID=keep
has 'Nothing to change.'
reconf FAKE_MANIFEST=$coder
has 'Nothing to change.'; lacks 'Colibri suggestion'
reconf FAKE_HAND=1 COLIBRI_MODEL_ID=remove FAKE_GPU_LINE=amd
has 'a model placed by hand in /srv/models/colibri'; has 'vulkan'; has 'COLIBRI_MODEL_ID=remove'
reconf FAKE_MANIFEST=other/repo@0123456789012345678901234567890123456789 COLIBRI_MODEL_ID=qwen36-35b FAKE_GPU_LINE=cpu
has 'a downloaded model not in this catalog'; has '65536 MiB, cpu'
reconf COLIBRI_MODEL_ID=remove
has 'Nothing to change.'
reconf FAKE_MANIFEST=$coder COLIBRI_MODEL_ID=qwen-image-2.1
has 'serve Qwen-Image-2.1 (33.1 GB'; has 'the router lists it as qwen-image-2.1-colibri'
has 'tools/webui-images.sh --expect-model qwen-image-2.1-colibri'
reconf_reject 'glm-5.2 does not fit this CT: needs 429.3 GB disk' COLIBRI_MODEL_ID=glm-5.2
reconf_reject 'qwen36-35b does not fit this CT' COLIBRI_MODEL_ID=qwen36-35b FAKE_FREE=10000000000
reconf COLIBRI_MODEL_ID=qwen36-35b FAKE_FREE=10000000000 FAKE_STAGED=15000000000
has 'serve Qwen3.6-35B-A3B'; has '23 GB free for the model'
reconf_reject 'needs 32 GiB RAM' COLIBRI_MODEL_ID=mimo-v2.6-flash FAKE_MEMORY=16384 FAKE_FREE=900000000000
reconf_reject 'CT 280 is not running' FAKE_CT=stopped COLIBRI_MODEL_ID=qwen36-35b
reconf_reject 'CT 280 has no Colibri installation' FAKE_INSTALLED=0 COLIBRI_MODEL_ID=qwen36-35b
reconf_reject 'COLIBRI_MODEL_ID must be one of' COLIBRI_MODEL_ID=bogus

# The menu: numbers, IDs, fit refusals and Enter (driven through model-select.sh).
menu_out=$( (source "$here/model-select.sh"; COLIBRI_MODEL_ID=''
    colibri_choose_model 65536 cuda /m true 200000000000 qwen3-coder-30b <<< $'8\nnope\n3'
    printf 'chosen=%s\n' "$COLIBRI_MODEL_ID") 2>&1)
output=$menu_out
has 'r) remove it'; has '0) keep the current model: Qwen3-Coder-30B-A3B (19.4 GB)'
has 'glm-5.2 does not fit this CT: needs 429.3 GB disk. Pick another'
has 'Answer a number from the list'; has 'chosen=deepseek-v4-flash-reap'
has '1) qwen3-coder-30b         Qwen3-Coder-30B-A3B             19.4 GB  RAM   8- 18 GiB  fits (current)'
has '12) qwen-image-2.1'
output=$( (source "$here/model-select.sh"; COLIBRI_MODEL_ID=''
    colibri_choose_model 8192 cpu /m true '' '' <<< ''; printf 'chosen=[%s]\n' "$COLIBRI_MODEL_ID") 2>&1)
has '0) none: download nothing'; has 'chosen=[]'
has 'qwen3-coder-30b         Qwen3-Coder-30B-A3B             19.4 GB  RAM   8- 18 GiB  fits, tight (best with 18 GiB) (suggested)'
# The menu is grouped by type, with a suggestion in each group the CT can run.
has 'Chat, runs from RAM'; has 'Chat, large: the dense part stays in RAM'
has 'Images: text to picture on POST /v1/images/generations, not chat; on this CT the CPU draws them'
has 'qwen-image-2.1          Qwen-Image-2.1                  33.1 GB  RAM  12- 18 GiB  needs 12 GiB RAM; non-commercial licence'
output=$( (source "$here/model-select.sh"; colibri_model_menu 65536 cuda 400000000000 '') 2>&1)
has 'on this CT the CPU draws them (colibri'"'"'s image engine has no CUDA lane)'
has 'qwen-image-2.1          Qwen-Image-2.1                  33.1 GB  RAM  12- 18 GiB  fits (suggested); CPU only here (no CUDA lane); non-commercial licence'
has 'mimo-v2.6-flash         MiMo-V2.6 Flash                171.8 GB  RAM  32- 52 GiB  fits; CPU only here (no CUDA lane)'
has 'glm-5.3                 GLM-5.3                        419.3 GB  RAM  16- 24 GiB  needs 419.3 GB disk'
output=$( (source "$here/model-select.sh"; colibri_model_menu 16384 vulkan 200000000000 '') 2>&1)
has 'on this CT the GPU draws them (Vulkan)'
has 'qwen-image-2.1          Qwen-Image-2.1                  33.1 GB  RAM  12- 18 GiB  fits, tight (best with 18 GiB) (suggested)'
# Suggestions per group: the most capable that runs well, a GPU lane first.
sug() { (source "$here/model-select.sh"; colibri_model_suggest "$@"); }
[[ $(sug chat-ram 65536 cpu 400000000000) == qwen36-35b ]] || { echo 'FAIL chat-ram suggestion' >&2; exit 1; }
[[ $(sug chat-ram 65536 cpu 21000000000) == qwen3-coder-30b ]] || { echo 'FAIL chat-ram suggestion on a small disk' >&2; exit 1; }
[[ $(sug chat-disk 65536 cuda 150000000000) == deepseek-v4-flash-reap ]] || { echo 'FAIL chat-disk on 150 GB' >&2; exit 1; }
[[ $(sug chat-disk 65536 cuda 450000000000) == glm-5.3 ]] || { echo 'FAIL chat-disk with CUDA' >&2; exit 1; }
[[ $(sug chat-disk 65536 vulkan 600000000000) == mimo-v2.6-pro ]] || { echo 'FAIL chat-disk with Vulkan' >&2; exit 1; }
[[ $(sug chat-disk 16384 cpu 200000000000) == deepseek-v4-flash-reap ]] || { echo 'FAIL tight chat-disk takes the smallest' >&2; exit 1; }
[[ -z $(sug chat-disk 8192 cpu 200000000000) ]] || { echo 'FAIL chat-disk suggested without the RAM' >&2; exit 1; }
[[ $(sug image 16384 cpu 200000000000) == qwen-image-2.1 && -z $(sug image 8192 cpu 200000000000) ]] ||
    { echo 'FAIL image suggestion' >&2; exit 1; }
output=$( (source "$here/model-select.sh"; COLIBRI_MODEL_ID=qwen-image-2.1; colibri_choose_model 16384 vulkan /m false 200000000000 && echo "chosen=$COLIBRI_MODEL_ID") 2>&1)
has 'chosen=qwen-image-2.1'
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
