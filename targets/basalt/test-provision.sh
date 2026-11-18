#!/usr/bin/env bash
# Check the provisioning plan without Proxmox, a GPU, root or downloads.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
source "$here/model-select.sh"
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
has '--tags ai\;ai-model\;osr-target\;basalt'
has '--features nesting=1'
has '--memory 131072'
has '--rootfs local-lvm:200'
has 'lxc.prlimit.memlock: unlimited'
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'cuda-toolkit.sh'
has 'nvidia-guest-install.sh lxc'
has 'DRIVER_VERSION='; has 'confirm CT 250 sees host NVIDIA driver'
has 'bash /root/basalt-target-deploy/install-target.sh'
has 'BASALT_MODEL=Qwen3.8-FN-UD-IQ3_XXS.basalt'
has 'BASALT_CONTEXT=65536'
has 'BASALT_KV=fp16'
has 'BASALT_KV_RESIDENT=0'
has 'Router registration: set the Basalt key, then add basalt://<CT-address>'
plan NVIDIA_DRIVER_VERSION=590.48.01
has 'DRIVER_VERSION=590.48.01'
reject 'CUDA 13 needs NVIDIA driver 580 or newer' NVIDIA_DRIVER_VERSION=575.64.05

plan BASALT_PORT=11434 CUDA_VERSION=13.1 IP_CIDR=dhcp GATEWAY=
has 'BASALT_PORT=11434'
has 'CUDA_VERSION=13.1'
lacks 'gw='

reject 'CT_ID' CT_ID=99
reject 'BASALT_GPUS' BASALT_GPUS=none
reject 'BASALT_MODEL' BASALT_MODEL='../wrong.basalt'
reject 'BASALT_CONTEXT' BASALT_CONTEXT=0
reject 'at most 999999 tokens' BASALT_CONTEXT=1000000
plan BASALT_MODEL=UD-IQ3_XXS BASALT_CONTEXT=999999
has 'BASALT_CONTEXT=999999'
reject 'BASALT_KV' BASALT_KV=bad
reject 'BASALT_KV_RESIDENT' BASALT_KV_RESIDENT=1000
reject 'cannot be combined' BASALT_KV=k8v4 BASALT_KV_RESIDENT=32768
plan BASALT_CONTEXT=131072 BASALT_KV=int8 BASALT_KV_RESIDENT=32768
has 'BASALT_KV=int8'
has 'BASALT_KV_RESIDENT=32768'
has 'KV streaming'
has 'about 1.6 GiB pinned RAM'
lacks 'Warning: the streamed KV cache'
# The CT at its 64 GiB floor cannot hold the UD-IQ3_XXS experts, 16 GiB and
# the pinned cache: a warning, not a refusal.
plan BASALT_MODEL=UD-IQ3_XXS MEMORY_MB=65536 BASALT_CONTEXT=131072 BASALT_KV=int8 BASALT_KV_RESIDENT=32768
has "Warning: the streamed KV cache pins about 1.6 GiB of RAM; with the pack's 46.8 GiB of routed experts"
has "more than the CT's RAM (MEMORY_MB) (64.0 GiB)"
has 'pct create'
plan BASALT_MODEL=UD-IQ3_XXS MEMORY_MB=65536
lacks 'KV streaming'
lacks 'Warning: the streamed KV cache'
reject 'Set BASALT_MODEL when BASALT_HF_REPO is a custom repository' BASALT_HF_REPO=https://huggingface.co/example/custom
plan BASALT_MODEL=UD-IQ2_XS
has 'BASALT_MODEL=Qwen3.8-FN-UD-IQ2_XS.basalt'
plan BASALT_MODEL=custom.basalt
has 'BASALT_MODEL=custom.basalt'
reject 'CUDA_VERSION' CUDA_VERSION=12.9
reject 'cannot be installed in a debian13 CT' TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst
plan TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst CUDA_VERSION=13.1
has 'CUDA 13.1 is available for debian13'
has 'CUDA_VERSION=13.1'
plan TEMPLATE=local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst
has 'CUDA 13.0 is available for debian12'
reject 'cannot be installed in a ubuntu2604 CT' TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst
plan TEMPLATE=local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst CUDA_VERSION=13.3
has 'CUDA 13.3 is available for ubuntu2604'
has '--ostype ubuntu'
reject 'Duplicate GPU device' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia0'
reject 'does not pass through /dev/nvidia1' BASALT_GPUS=0,1
plan BASALT_GPUS=0,1 GPU_DEVICES='/dev/nvidia0 /dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm'
has 'BASALT_GPUS=0\,1'

# The recommendation uses GPU VRAM, available host RAM and planned CT RAM/disk.
nvidia-smi() { case $2 in 0) echo 16384 ;; 1) echo 24576 ;; *) return 1 ;; esac; }
[[ $(basalt_gpu_vram_mib 0,1) == 40960 ]] || { echo 'FAIL selected GPU VRAM total' >&2; exit 1; }
unset -f nvidia-smi
[[ $(basalt_model_recommendation 16384 131072 131072 200) == UD-IQ3_XXS ]] || { echo 'FAIL 16 GiB GPU recommendation' >&2; exit 1; }
[[ $(basalt_model_recommendation 24576 131072 131072 200) == UD-IQ4_XS ]] || { echo 'FAIL 24 GiB GPU recommendation' >&2; exit 1; }
[[ $(basalt_model_recommendation 32768 131072 131072 200) == UD-Q4_K_XL ]] || { echo 'FAIL 32 GiB GPU recommendation' >&2; exit 1; }
[[ $(basalt_model_recommendation 16384 59392 65536 120) == UD-IQ2_XS ]] || { echo 'FAIL host RAM recommendation' >&2; exit 1; }
[[ $(basalt_model_recommendation 16384 131072 131072 100) == UD-IQ1_M ]] || { echo 'FAIL disk recommendation' >&2; exit 1; }
[[ -z $(basalt_model_recommendation 16384 40000 65536 120) ]] || { echo 'FAIL insufficient host RAM recommendation' >&2; exit 1; }

output=$(printf 'UD-IQ2_XS\n' | env -i "PATH=$PATH" PVE_INTERACTIVE=true "${common[@]}" bash "$provision" --dry-run 2>&1)
has '== Basalt model =='
has 'Suggested: UD-IQ3_XXS'
has 'BASALT_MODEL=Qwen3.8-FN-UD-IQ2_XS.basalt'

# The CT installer carries the host's KV RAM estimate; the copies must match,
# and so must its expert table.
shared_block() { sed -n '/^# BEGIN shared KV RAM estimate$/,/^# END shared KV RAM estimate$/p' "$1"; }
[[ -n $(shared_block "$here/model-select.sh") && $(shared_block "$here/model-select.sh") == "$(shared_block "$guest")" ]] ||
    { echo 'FAIL the KV RAM estimate in install-target.sh differs from model-select.sh' >&2; exit 1; }
source <(sed -n '/^basalt_pack_experts_mib() {/,/^}/p' "$guest")
while IFS='|' read -r suffix _ _; do
    [[ $(basalt_pack_experts_mib "$(basalt_model_file "$suffix")") == "$(basalt_model_experts_mib "$suffix")" ]] ||
        { echo "FAIL install-target.sh expert size for $suffix" >&2; exit 1; }
done < <(basalt_model_rows)
[[ -z $(basalt_pack_experts_mib custom.basalt) ]] || { echo 'FAIL expert size for a custom pack' >&2; exit 1; }
# Bytes per cell from upstream's geometry (Basalt's docs: int8 1,056 per layer).
[[ $(basalt_kv_host_mib 131072 int8 32768) == 1716 ]] || { echo 'FAIL int8 KV RAM' >&2; exit 1; }
[[ $(basalt_kv_host_mib 131072 fp16 32768) == 3328 ]] || { echo 'FAIL fp16 KV RAM' >&2; exit 1; }
[[ $(basalt_kv_host_mib 131072 q4_0 32768) == 936 ]] || { echo 'FAIL q4_0 KV RAM' >&2; exit 1; }
[[ $(basalt_kv_host_mib 131072 int8 0) == 0 && $(basalt_kv_host_mib 131072 int8 131072) == 0 ]] ||
    { echo 'FAIL KV RAM without streaming' >&2; exit 1; }
[[ -z $(basalt_kv_ram_warning 1716 47923 131072 x) && -n $(basalt_kv_ram_warning 1716 47923 65536 x) ]] ||
    { echo 'FAIL KV RAM warning threshold' >&2; exit 1; }
[[ -z $(basalt_kv_ram_warning 1716 47923 '' x) ]] || { echo 'FAIL KV RAM warning with an unknown limit' >&2; exit 1; }

# The model suggestion sets the pinned cache aside: 6.5 GiB of fp16 KV leaves a
# 64 GiB CT room for UD-IQ2_XS rather than UD-IQ3_XXS.
output=$(printf '\n' | env -i "PATH=$PATH" PVE_INTERACTIVE=true "${common[@]}" MEMORY_MB=65536 ROOTFS_GB=120 bash "$provision" --dry-run 2>&1)
has 'Suggested: UD-IQ3_XXS'
output=$(printf '\n' | env -i "PATH=$PATH" PVE_INTERACTIVE=true "${common[@]}" MEMORY_MB=65536 ROOTFS_GB=120 \
    BASALT_CONTEXT=262144 BASALT_KV=fp16 BASALT_KV_RESIDENT=32768 bash "$provision" --dry-run 2>&1)
has 'Streamed KV cache: about 6.5 GiB of pinned RAM'
has 'Suggested: UD-IQ2_XS'
has 'BASALT_MODEL=Qwen3.8-FN-UD-IQ2_XS.basalt'

output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has 'git fetch --depth 1 https://github.com/jesdga95/basalt.git main into /opt/basalt'
has 'cmake build for sm_120 on CUDA 13.0+'
has 'systemctl enable basalt.service'
has '/health to report loaded=true'

output=$(env -i "PATH=$PATH" BASALT_URL=https://example.com/custom.git bash "$guest" --dry-run 2>&1)
has 'https://example.com/custom.git main into /opt/basalt'

installed=$(mktemp -d "${TMPDIR:-/tmp}/basalt-rerun-test.XXXXXX")
trap 'rm -rf -- "$installed"' EXIT
mkdir -p "$installed/opt/basalt/.git" "$installed/etc/systemd/system" "$installed/etc/basalt-target"
: > "$installed/etc/systemd/system/basalt.service"
# An installed target has a settings record; a rerun plans from it.
printf 'BASALT_MODEL=Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt\nBASALT_HF_REPO=https://huggingface.co/jesdga/Qwen3.8-Flash-Next-Basalt\nBASALT_ALIAS=qwen3.8-flash-next\nBASALT_GPUS=0\nBASALT_CONTEXT=32768\nBASALT_PORT=8123\nBASALT_ALLOW_NO_KEY=false\nCUDA_VERSION=13.0\n' > "$installed/etc/basalt-target/installed-env"
rerun_plan() {
    env -i "PATH=$PATH" BASALT_DIR="$installed/opt/basalt" BASALT_ETC_DIR="$installed/etc/basalt-target" \
        UNIT_DIR="$installed/etc/systemd/system" "$@" bash "$guest" --dry-run 2>&1
}
output=$(rerun_plan)
has 'before anything is stopped'
has 'systemctl stop basalt.service'
has 'previous commit locally (no network)'

# A failed first install keeps its old choice in pending-env. An explicit
# replacement must win when resuming that checkout.
mv "$installed/etc/basalt-target/installed-env" "$installed/etc/basalt-target/pending-env"
rm "$installed/etc/systemd/system/basalt.service"
output=$(rerun_plan BASALT_MODEL=Qwen3.8-FN-UD-IQ3_XXS.basalt)
has 'download Qwen3.8-FN-UD-IQ3_XXS.basalt'
lacks 'download Qwen3.8-FN-GSQ-RCO-IQ3_S.basalt'

# Without any settings record the same checkout is refused, not planned with
# fresh-install defaults.
rm "$installed/etc/basalt-target/pending-env"
if output=$(rerun_plan); then
    printf 'FAIL a checkout without a settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Found an existing'
has 'no readable settings record'

unit=$here/basalt.service
grep -Fqx 'ExecStart=/bin/sh ${BASALT_RUN_SCRIPT}' "$unit"
grep -q '^User=basalt$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"
grep -q '^LimitMEMLOCK=infinity$' "$unit"

# The CT installer: six-digit context, and a KV streaming report on a rerun
# that turns it on (its warning depends on this machine's memory).
if output=$(env -i "PATH=$PATH" BASALT_CONTEXT=1000000 bash "$guest" --dry-run 2>&1); then
    printf 'FAIL the guest accepted a seven-digit context\n%s\n' "$output" >&2; exit 1
fi
has '1 to 999999 tokens'
output=$(env -i "PATH=$PATH" BASALT_CONTEXT=131072 BASALT_KV=int8 BASALT_KV_RESIDENT=32768 bash "$guest" --dry-run 2>&1)
has 'KV streaming: 32768 of 131072 cells stay in VRAM; the whole int8 cache takes about 1.6 GiB of pinned RAM.'

bash -n "$provision"
bash -n "$guest"
bash -n "$here/model-select.sh"
bash -n "$here/cuda-toolkit.sh"
printf 'Basalt dry-run plans, validation and shell syntax passed. No CT was created.\n'
