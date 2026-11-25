#!/usr/bin/env bash
# Plans only: no Proxmox, GPU, download, or root privileges are required.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision=$here/provision-lxc.sh
guest=$here/install-target.sh
fake=$(mktemp -d "${TMPDIR:-/tmp}/polystrata-provision-test.XXXXXX")
installed=''
trap 'rm -rf -- "$fake" ${installed:+"$installed"}' EXIT
mkdir -p "$fake/bin" "$fake/none" "$fake/proc/gpus/0000:01:00.0" "$fake/proc/gpus/0000:02:00.0"
printf 'Model: \t\t NVIDIA RTX PRO 2000 Blackwell\nDevice Minor: \t 0\n' > "$fake/proc/gpus/0000:01:00.0/information"
printf 'Model: \t\t NVIDIA RTX 5090\nDevice Minor: \t 1\n' > "$fake/proc/gpus/0000:02:00.0/information"
cat > "$fake/bin/nvidia-smi" <<'SMI'
#!/bin/sh
printf '00000000:01:00.0, %s\n00000000:02:00.0, 32607\n' "${FAKE_VRAM_MIB:-16311}"
SMI
chmod +x "$fake/bin/nvidia-smi"
gpu=("PATH=$fake/bin:$PATH" "NVIDIA_PROC=$fake/proc")
common=(CT_ID=280 TEMPLATE=local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst
        STORAGE=local-lvm IP_CIDR=192.0.2.80/24 GATEWAY=192.0.2.1 "NVIDIA_PROC=$fake/none")
pin=$(sed -n 's/^PIN = "\([0-9a-f]\{40\}\)"$/\1/p' "$here/test-pinned-upstream.py")
[[ $pin =~ ^[0-9a-f]{40}$ ]] || { echo 'FAIL missing PolyStrata test pin' >&2; exit 1; }
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
has '+ pct create 280 '
has '--unprivileged 1'
has '--tags ai\;ai-model\;osr-target\;polystrata'
has '--features nesting=1'
has '--memory 65536'
has '--rootfs local-lvm:160'
has 'lxc.prlimit.memlock: unlimited'
has 'path=/dev/nvidia0\,gid=44\,mode=0660'
has 'path=/dev/nvidia-uvm\,gid=44\,mode=0660'
lacks 'gid=0\,'
has 'POLYSTRATA_READY_TIMEOUT=900'
has 'nvidia-guest-install.sh lxc'
has 'DRIVER_VERSION='; has 'confirm CT 280 sees host NVIDIA driver'
has 'bash /root/polystrata-target-deploy/install-target.sh'
has 'POLYSTRATA_PORT=8080'
has "POLYSTRATA_COMMIT=$pin"
lacks 'https://github.com/simplexai-labs/PolyStrata.git'  # cloning happens inside the CT
plan NVIDIA_DRIVER_VERSION=590.48.01
has 'DRIVER_VERSION=590.48.01'
reject 'CUDA 13 needs NVIDIA driver 580 or newer' NVIDIA_DRIVER_VERSION=575.64.05

plan POLYSTRATA_REF=v0.1.40
has 'POLYSTRATA_REF=v0.1.40'
has 'POLYSTRATA_COMMIT='
plan POLYSTRATA_COMMIT=
has 'POLYSTRATA_REF=main'
has 'POLYSTRATA_COMMIT='

plan POLYSTRATA_PORT=11434 IP_CIDR=dhcp GATEWAY= POLYSTRATA_MODEL=IQ3_S
has 'POLYSTRATA_PORT=11434'
has 'POLYSTRATA_MODEL=IQ3_S'
has 'ip=dhcp\,firewall=1'
lacks 'gw='

plan POLYSTRATA_FAMILY=coder
has 'POLYSTRATA_MODEL=IQ1_M'

plan POLYSTRATA_FAMILY=unsloth
has 'POLYSTRATA_FAMILY=unsloth'
has 'POLYSTRATA_MODEL=UD-IQ4_XS'
has 'unsloth UD-IQ4_XS (Qwen3.8-Flash-Next (Unsloth quantizations)), about 48 GB of RAM'
lacks 'Warning: unsloth'

# PolyStrata's own engine: each family's default size, KV cache auto (fp16)
# unattended, the family's own formats only, no message cache.
plan POLYSTRATA_FAMILY=qwen36
has 'POLYSTRATA_FAMILY=qwen36'; has 'POLYSTRATA_MODEL=UD-Q3_K_M'
has 'POLYSTRATA_KV=auto'; has 'POLYSTRATA_MESSAGE_CACHE=false'
plan POLYSTRATA_FAMILY=glm
has 'POLYSTRATA_MODEL=3.0BIT'; has 'POLYSTRATA_KV=auto'
has 'Warning: glm 3.0BIT wants about 96 GB of RAM'
plan POLYSTRATA_FAMILY=qwen36 POLYSTRATA_KV=q8_0
has 'POLYSTRATA_KV=q8_0'
plan POLYSTRATA_FAMILY=gemma4 POLYSTRATA_KV=int8k MEMORY_MB=16384 ROOTFS_GB=60
has 'POLYSTRATA_KV=int8k'; has '--memory 16384'; has '--rootfs local-lvm:60'
reject 'does not fit the glm family' POLYSTRATA_FAMILY=glm POLYSTRATA_KV=q8_0
reject 'does not fit the qwen36 family' POLYSTRATA_FAMILY=qwen36 POLYSTRATA_KV=k8v4
reject 'is a Strata-engine setting' POLYSTRATA_FAMILY=qwen36 POLYSTRATA_MESSAGE_CACHE=true
reject 'families.sh has no sizes' POLYSTRATA_FAMILY=hy4-flash
plan POLYSTRATA_FAMILY=hy4-flash POLYSTRATA_MODEL=SQ-96
has 'POLYSTRATA_FAMILY=hy4-flash'; has 'POLYSTRATA_KV=auto'; has 'not in families.sh'
reject 'does not fit the hy4-flash family' POLYSTRATA_FAMILY=hy4-flash POLYSTRATA_MODEL=SQ-96 POLYSTRATA_KV=fp16
plan POLYSTRATA_FAMILY=unsloth POLYSTRATA_MODEL=Q8_0
has 'Warning: unsloth Q8_0 wants about 136 GB of RAM'
has '+ pct push 280 '; has 'families.sh /root/polystrata-target-deploy/families.sh'

reject 'CT_ID' CT_ID=99
reject 'Set CT_ID for unattended provisioning' CT_ID=
reject 'Set TEMPLATE for unattended provisioning' TEMPLATE=
reject 'Set STORAGE for unattended provisioning' STORAGE=
reject 'Set IP_CIDR for unattended provisioning' IP_CIDR=
reject 'Set GATEWAY for unattended provisioning' GATEWAY=
reject 'IP_CIDR' IP_CIDR=192.0.2.999/24
reject 'TEMPLATE' TEMPLATE=local:vztmpl/alpine-3.20-standard_amd64.tar.zst
reject 'Duplicate GPU device' GPU_DEVICES='/dev/nvidia0 /dev/nvidiactl /dev/nvidia0'
reject 'POLYSTRATA_PORT' POLYSTRATA_PORT=70000
reject 'MEMORY_MB' MEMORY_MB=8192
reject 'ROOTFS_GB' ROOTFS_GB=40
reject 'POLYSTRATA_COMMIT' POLYSTRATA_COMMIT=bad
reject 'GPU_GID' GPU_GID=0

# The KV cache. From a 64K context, when the CT's RAM holds the model, the
# 8-bit cache and 1 GB, PolyStrata keeps the cache in RAM (a 32K window on the
# GPU): int8 is suggested on any card. Otherwise by the card: k8v4 under 24 GB,
# int8 from 24 GB or for an unknown card. A preset is kept; up to 8192 tokens
# nothing is asked. Unattended runs take the suggestion.
plan
has 'POLYSTRATA_KV=int8'; has 'KV cache int8'
plan "${gpu[@]}" FAKE_VRAM_MIB=16311          # 64K, 64 GiB, IQ2_XS: streamed
has 'POLYSTRATA_KV=int8'; has 'context 65536, parallel 1, KV cache int8, message cache false, port 8080'
plan "${gpu[@]}" POLYSTRATA_PARALLEL=4
has 'POLYSTRATA_PARALLEL=4'
reject 'POLYSTRATA_PARALLEL' POLYSTRATA_PARALLEL=9
plan "${gpu[@]}" FAKE_VRAM_MIB=16311 POLYSTRATA_MODEL=IQ3_S POLYSTRATA_CONTEXT=262144 MEMORY_MB=90112
has 'POLYSTRATA_KV=int8'                          # 96 GB host: IQ3_S at 256K in an 88 GiB CT
plan "${gpu[@]}" FAKE_VRAM_MIB=16311 POLYSTRATA_MODEL=IQ3_XXS POLYSTRATA_CONTEXT=131072 MEMORY_MB=61440
has 'POLYSTRATA_KV=k8v4'                          # 60 GiB: IQ3_XXS's 128K cache stays on the GPU
plan "${gpu[@]}" FAKE_VRAM_MIB=16311 POLYSTRATA_MODEL=IQ3_S POLYSTRATA_CONTEXT=262144
has 'POLYSTRATA_KV=k8v4'                          # 64 GiB is short of 62 + 3.6 + 1 GB
plan "${gpu[@]}" FAKE_VRAM_MIB=16311 POLYSTRATA_MODEL=Q9_X POLYSTRATA_CONTEXT=262144 MEMORY_MB=131072
has 'POLYSTRATA_KV=k8v4'                          # an unknown model: by the card
for ram_case in '12282 k8v4' '16311 k8v4' '24564 int8' '32607 int8'; do
    read -r mib kv <<< "$ram_case"
    plan "${gpu[@]}" FAKE_VRAM_MIB="$mib" POLYSTRATA_CONTEXT=32768   # below 64K: never streamed
    has "POLYSTRATA_KV=$kv"
done
plan "${gpu[@]}" GPU_DEVICES='/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm' POLYSTRATA_CONTEXT=32768
has 'POLYSTRATA_KV=int8'   # minor 1 is the 32 GB card, not GPU 0
plan "${gpu[@]}" POLYSTRATA_KV=q4_0
has 'POLYSTRATA_KV=q4_0'
plan "${gpu[@]}" POLYSTRATA_CONTEXT=8192
has 'POLYSTRATA_KV=auto'; has 'POLYSTRATA_MESSAGE_CACHE=false'
reject 'does not fit the qwen family' POLYSTRATA_KV=q8
reject 'does not fit the qwen family' POLYSTRATA_KV=q8_0

# The message cache: off unless chosen; a preset is passed on.
plan
has 'POLYSTRATA_MESSAGE_CACHE=false'
plan POLYSTRATA_MESSAGE_CACHE=true
has 'POLYSTRATA_MESSAGE_CACHE=true'; has 'message cache true'
reject 'POLYSTRATA_MESSAGE_CACHE must be true or false' POLYSTRATA_MESSAGE_CACHE=yes

# Interactive: each question shows its suggestion; Enter takes it, a bad answer
# is asked again.
ask() {
    local input=$1; shift
    output=$(printf '%b' "$input" | env -i "PATH=$fake/bin:$PATH" "${common[@]}" "NVIDIA_PROC=$fake/proc" \
        PVE_INTERACTIVE=true FAKE_VRAM_MIB=16311 "$@" bash "$provision" --dry-run 2>&1) || {
        printf 'FAIL interactive plan\n%s\n' "$output" >&2; exit 1;
    }
    passed=$((passed + 1))
}
ask '\n\n\n\n' POLYSTRATA_CONTEXT=32768
has '== PolyStrata model family =='
has '7) glm - GLM 5.3 Flash (32 GB card), experimental engine'
has 'PolyStrata family [Enter: qwen]:'
has '== PolyStrata qwen size =='
has '2) IQ2_XS - about 48 GB of RAM'
has 'PolyStrata size [Enter: IQ2_XS]:'
has 'POLYSTRATA_FAMILY=qwen'
has 'POLYSTRATA_MODEL=IQ2_XS'
has '== PolyStrata settings =='
has 'Suggested: k8v4 for 12 GB and 16 GB cards, int8 for 24 GB and 32 GB cards;'
has "int8 on any card when the cache fits in the CT's RAM (from a 64K context)."
has 'This CT: k8v4 (its 16311 MiB GPU'
has 'KV cache (int8, k8v4 or q4_0) [k8v4]:'
has 'Message cache for agents that rewrite their last message [y/N]:'
has 'POLYSTRATA_KV=k8v4'; has 'POLYSTRATA_MESSAGE_CACHE=false'
ask '\n\nq8\nint8\ny\n' POLYSTRATA_CONTEXT=32768
has 'Choose int8, k8v4 or q4_0.'
has 'POLYSTRATA_KV=int8'; has 'POLYSTRATA_MESSAGE_CACHE=true'
ask '\n1\n\n\n' POLYSTRATA_CONTEXT=32768
has 'POLYSTRATA_MODEL=Q2_0'
ask '14\n9\n\n\n' POLYSTRATA_CONTEXT=32768
has 'Choose a number from the list.'
ask 'qwen36\n3\nq4_0\nq8_0\n' POLYSTRATA_CONTEXT=32768
has '== PolyStrata qwen36 size =='; has 'POLYSTRATA_MODEL=UD-Q4_K_M'
has 'KV cache (auto, fp16, q8_0) [auto]:'; has 'Choose one of: auto, fp16, q8_0.'
has 'POLYSTRATA_KV=q8_0'; lacks 'Message cache for agents'; has 'POLYSTRATA_MESSAGE_CACHE=false'
ask 'glm\n\n' POLYSTRATA_CONTEXT=32768 MEMORY_MB=131072
has 'POLYSTRATA_MODEL=3.0BIT'; has 'POLYSTRATA_KV=auto'; lacks 'KV cache ('; lacks 'Warning: glm'
ask '\n' POLYSTRATA_FAMILY=deepseek POLYSTRATA_CONTEXT=32768
lacks '== PolyStrata model family =='; has 'POLYSTRATA_MODEL=UD-IQ2_XXS'
ask '\n\n\n' POLYSTRATA_MODEL=IQ3_S POLYSTRATA_CONTEXT=262144 MEMORY_MB=90112
has "This CT: int8 (at this context the cache is kept in the CT's RAM with only a 32K window on the GPU)."
has 'KV cache (int8, k8v4 or q4_0) [int8]:'

plan GPU_GID=1000
has 'path=/dev/nvidia0\,gid=1000\,mode=0660'
plan GPU_DEVICES='/dev/nvidia1 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
has '--dev3 path=/dev/nvidia-uvm-tools'

output=$(env -i "PATH=$PATH" bash "$guest" --dry-run 2>&1)
has "git fetch --depth 1 https://github.com/simplexai-labs/PolyStrata.git $pin into /opt/polystrata (as polystrata)"
lacks '--kv'   # auto: the engine's default cache
has '[--family qwen] --model IQ2_XS'
has 'setup.sh --help: keep only the options this checkout supports'
has '--setup --no-start --yes'
has '--host 0.0.0.0 --port 8080'
has '--api-key [redacted]'
has 'POLYSTRATA_RUN_SCRIPT'
has 'systemctl enable polystrata.service'
has 'systemctl restart polystrata.service'
has '/health to report loaded=true (up to 900s)'
lacks 'api-key [generated inside CT]'
lacks 'sudo'
passed=$((passed + 1))

installed=$(mktemp -d "${TMPDIR:-/tmp}/polystrata-rerun-test.XXXXXX")
mkdir -p "$installed/opt/polystrata/.git" "$installed/etc/systemd/system" "$installed/etc/polystrata-target"
: > "$installed/etc/systemd/system/polystrata.service"
# An installed target has a settings record; a rerun plans from it.
printf 'POLYSTRATA_FAMILY=qwen\nPOLYSTRATA_MODEL=IQ2_XS\nPOLYSTRATA_CONTEXT=32768\nPOLYSTRATA_PARALLEL=1\nPOLYSTRATA_KV=auto\nPOLYSTRATA_MESSAGE_CACHE=false\nPOLYSTRATA_VISION=no\nPOLYSTRATA_PORT=8123\nPOLYSTRATA_ALLOW_NO_KEY=false\n' > "$installed/etc/polystrata-target/installed-env"
rerun_plan() {
    env -i "PATH=$PATH" POLYSTRATA_DIR="$installed/opt/polystrata" POLYSTRATA_ETC_DIR="$installed/etc/polystrata-target" \
        UNIT_DIR="$installed/etc/systemd/system" bash "$guest" --dry-run 2>&1
}
output=$(rerun_plan)
has "git fetch --depth 1 https://github.com/simplexai-labs/PolyStrata.git $pin (before anything is stopped"
has 'nothing to do'
has 'record the current commit; systemctl stop polystrata.service'
has 'previous commit locally (no network)'
passed=$((passed + 1))

# An incomplete record is refused: this target has no settings from before
# its records (SETTING_LEGACY_DEFAULTS is empty).
sed -i '/^POLYSTRATA_KV=/d' "$installed/etc/polystrata-target/installed-env"
if output=$(rerun_plan); then
    printf 'FAIL an incomplete settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Invalid or incomplete'
passed=$((passed + 1))

# Without any settings record the same checkout is refused, not planned with
# fresh-install defaults.
rm "$installed/etc/polystrata-target/installed-env"
if output=$(rerun_plan); then
    printf 'FAIL a checkout without a settings record was planned\n%s\n' "$output" >&2; exit 1
fi
has 'Found an existing'
has 'no readable settings record'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" POLYSTRATA_PORT=11434 POLYSTRATA_REF=v0.1.40 bash "$guest" --dry-run 2>&1)
has 'PolyStrata.git v0.1.40 into'
has '--port 11434'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" POLYSTRATA_COMMIT= bash "$guest" --dry-run 2>&1)
has 'PolyStrata.git main into'
passed=$((passed + 1))

commit=0123456789abcdef0123456789abcdef01234567
output=$(env -i "PATH=$PATH" POLYSTRATA_COMMIT=$commit bash "$guest" --dry-run 2>&1)
has "PolyStrata.git $commit into"   # fetched by commit, not cloned at a branch tip
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" POLYSTRATA_KV=k8v4 bash "$guest" --dry-run 2>&1)
has '[--kv k8v4]'
if output=$(env -i "PATH=$PATH" POLYSTRATA_KV=q8 bash "$guest" --dry-run 2>&1); then
    printf 'FAIL accepted POLYSTRATA_KV=q8\n' >&2; exit 1
fi
has 'POLYSTRATA_KV must be auto, int8, k8v4, q4_0, fp16, q8_0 or int8k.'
output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY=minicpmv POLYSTRATA_KV=q8_0 bash "$guest" --dry-run 2>&1)
has '[--family minicpmv] --model Q4_K_M'; has '[--kv q8_0]'
if output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY=minicpmv POLYSTRATA_KV=int8 bash "$guest" --dry-run 2>&1); then
    printf 'FAIL accepted int8 for minicpmv\n' >&2; exit 1
fi
has 'does not fit the minicpmv family'
if output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY=flint POLYSTRATA_MESSAGE_CACHE=true bash "$guest" --dry-run 2>&1); then
    printf 'FAIL accepted the message cache for flint\n' >&2; exit 1
fi
has 'is a Strata-engine setting'
if output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY=hy4-flash bash "$guest" --dry-run 2>&1); then
    printf 'FAIL planned hy4-flash without a model\n' >&2; exit 1
fi
has 'set POLYSTRATA_MODEL too'
output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY=hy4-flash POLYSTRATA_MODEL=SQ-64 bash "$guest" --dry-run 2>&1)
has '[--family hy4-flash] --model SQ-64'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY=coder bash "$guest" --dry-run 2>&1)
has '[--family coder] --model IQ1_M'
output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY=unsloth bash "$guest" --dry-run 2>&1)
has '[--family unsloth] --model UD-IQ4_XS'
if output=$(env -i "PATH=$PATH" POLYSTRATA_FAMILY='Qwen;x' bash "$guest" --dry-run 2>&1); then
    printf 'FAIL accepted a malformed POLYSTRATA_FAMILY\n' >&2; exit 1
fi
has 'Invalid POLYSTRATA_FAMILY'
passed=$((passed + 1))

output=$(env -i "PATH=$PATH" bash "$guest" --dry-run --upgrade 2>&1)
has 'on failure: check out the previous commit'
passed=$((passed + 1))

if output=$(env -i "PATH=$PATH" POLYSTRATA_REF='a..b' bash "$guest" --dry-run 2>&1); then
    printf 'FAIL accepted POLYSTRATA_REF with ..\n' >&2; exit 1
fi
has 'Invalid POLYSTRATA_REF'
passed=$((passed + 1))

unit=$here/polystrata.service
grep -Fqx 'ExecStart=/bin/sh ${POLYSTRATA_RUN_SCRIPT}' "$unit"
grep -q '^EnvironmentFile=/etc/polystrata-target/polystrata.env$' "$unit"
grep -q '^User=polystrata$' "$unit"
grep -q '^ProtectSystem=strict$' "$unit"
grep -q '^CapabilityBoundingSet=$' "$unit"
grep -q '^ReadWritePaths=/opt/polystrata /var/lib/polystrata$' "$unit"
grep -q '^PrivateDevices=false$' "$unit"   # the GPU nodes must stay visible
grep -q '^LimitMEMLOCK=infinity$' "$unit"
passed=$((passed + 1))

bash -n "$provision"
bash -n "$guest"
printf '%s PolyStrata dry-run cases and shell syntax checks passed. No CT was created.\n' "$passed"
