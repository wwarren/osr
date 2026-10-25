#!/usr/bin/env bash
# Portable, non-mutating input/command validation. No PVE, root, or GPU required.
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
provision="$script_dir/provision-lxc.sh"
nvidia_installer="$script_dir/../../tools/install_nvidia_580_173_02.sh"
[[ -r $nvidia_installer ]] || nvidia_installer="$script_dir/../../install_nvidia_580_173_02.sh"
bash_bin=$(command -v bash)
common=(CT_ID=250 TEMPLATE=local:vztmpl/debian-12-standard_test_amd64.tar.zst STORAGE=local-lvm IP_CIDR=192.0.2.50/24 GATEWAY=192.0.2.1 GPU_DEVICES='/dev/nvidia99999 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools')
passed=0

check() {
    local expected=$1 label=$2 mode=$3 output status=0
    shift 3
    local -a flags=(--dry-run)
    case "$mode" in
        create) flags+=(--create-only) ;;
        install) flags+=(--install-target) ;;
        create-after-install) flags+=(--install-target --create-only) ;;
        create-before-install) flags+=(--create-only --install-target) ;;
        install-url) flags+=(--install-target) ;;
    esac
    # Clearing inherited configuration keeps these cases independent of operator env.
    # Every invocation carries --dry-run, including all rejection cases.
    output=$(env -i "PATH=$PATH" "${common[@]}" "$@" "$bash_bin" "$provision" "${flags[@]}" 2>&1) || status=$?
    if [[ $expected == success ]]; then
        if (( status != 0 )); then printf 'FAIL %s\n%s\n' "$label" "$output" >&2; exit 1; fi
        [[ $output == *'+ pct create 250 '* && $output == *'--unprivileged 1'* && $output == *'--features nesting=1'* && $output == *'+ pct push 250 '* ]] || { printf 'FAIL %s: incomplete command plan\n' "$label" >&2; exit 1; }
        [[ $output == *'install_nvidia_580_173_02.sh /root/llama-target-deploy/install_nvidia_580_173_02.sh --perms 0755'* ]] || { printf 'FAIL %s: NVIDIA helper was not copied into the deployment directory\n' "$label" >&2; exit 1; }
        [[ $output != *'CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc'* ]] || { printf 'FAIL %s: command plan injected a CUDA compiler path that was not configured\n' "$label" >&2; exit 1; }
        if [[ $mode == install || $mode == install-env || $mode == install-url ]]; then
            [[ $output != *'Guest installation skipped'* && $output == *'bash /root/llama-target-deploy/install-target.sh'* ]] || { printf 'FAIL %s: guest installation missing from command plan\n' "$label" >&2; exit 1; }
            if [[ $output == *'BACKEND=cpu'* ]]; then
                [[ $output != *'+ pct exec 250 -- bash /root/llama-target-deploy/install_nvidia_580_173_02.sh lxc'* ]] || { printf 'FAIL %s: CPU install executed the NVIDIA helper\n' "$label" >&2; exit 1; }
            else
                [[ $output == *'+ pct exec 250 -- bash /root/llama-target-deploy/install_nvidia_580_173_02.sh lxc'*'+ pct exec 250 -- env '*'bash /root/llama-target-deploy/install-target.sh'* ]] || { printf 'FAIL %s: NVIDIA helper did not execute before the CUDA target installer\n' "$label" >&2; exit 1; }
                if [[ $output != *'GPU_LAYERS=all'* && $output != *'GPU_LAYERS='[0-9]* ]]; then
                    [[ $output == *'GPU_LAYERS=auto'* ]] || { printf 'FAIL %s: CUDA install did not preserve automatic GPU-layer fitting\n' "$label" >&2; exit 1; }
                fi
            fi
            if [[ $mode == install-url ]]; then
                [[ $output == *'NONINTERACTIVE=true'* && $output == *'MODEL_DOWNLOAD_URL=https://huggingface.co/'* ]] || { printf 'FAIL %s: download URL was not forwarded to the guest\n' "$label" >&2; exit 1; }
            fi
        else
            [[ $output == *'Guest installation skipped'* ]] || { printf 'FAIL %s: create-only did not skip install\n' "$label" >&2; exit 1; }
            [[ $output != *'+ pct exec 250 -- env '* ]] || { printf 'FAIL %s: create-only executed the installer\n' "$label" >&2; exit 1; }
            [[ $output != *'+ pct exec 250 -- bash /root/llama-target-deploy/install_nvidia_580_173_02.sh lxc'* ]] || { printf 'FAIL %s: create-only executed the NVIDIA helper\n' "$label" >&2; exit 1; }
            if [[ $output == *'BACKEND=cpu'* ]]; then
                [[ $output != *$'\n  bash /root/llama-target-deploy/install_nvidia_580_173_02.sh lxc'* ]] || { printf 'FAIL %s: CPU create-only instructions included the NVIDIA helper\n' "$label" >&2; exit 1; }
            else
                [[ $output == *$'\n  bash /root/llama-target-deploy/install_nvidia_580_173_02.sh lxc'* ]] || { printf 'FAIL %s: CUDA create-only instructions omitted the NVIDIA helper\n' "$label" >&2; exit 1; }
            fi
        fi
    else
        if (( status == 0 )); then printf 'FAIL %s: invalid input was accepted\n' "$label" >&2; exit 1; fi
        [[ $output != *'+ pct create '* ]] || { printf 'FAIL %s: validation occurred after creation plan\n' "$label" >&2; exit 1; }
    fi
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
}

check success 'default CUDA provisioning needs no model or build ref' default
check success 'explicit CUDA create-only needs no model or build ref' create
check success 'user template and root disk storage IDs support underscores' default TEMPLATE=iso_fs:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst STORAGE=vm_pool CT_HOSTNAME=ant-rtxpro2k-llama1 IP_CIDR=192.168.10.10/23 CORES=12 MEMORY_MB=32768 ROOTFS_GB=1024
check success 'create-only overrides environment install request' create INSTALL_TARGET=1
check success 'create-only overrides an earlier install flag' create-after-install
check success 'create-only overrides a later install flag' create-before-install
check success 'CPU create-only needs no GPU paths' create BACKEND=cpu GPU_DEVICES=
check success 'DHCP omits a static gateway' create IP_CIDR=dhcp GATEWAY=
check success 'explicit GPU paths and CUDA fleet architectures' create CUDA_ARCHITECTURES='86;89;120'
check success 'install plan includes required model settings' install LLAMA_CPP_REF=b9999 MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check success 'install permits the default release without an override' install MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check success 'install permits a full commit override' install LLAMA_CPP_REF=7fe450e19305b828c199d602c23a8337aaa1f03b MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check success 'CUDA install accepts an intentional all-layers override' install GPU_LAYERS=all MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check success 'CPU install skips the NVIDIA user-space helper' install BACKEND=cpu GPU_DEVICES= GPU_LAYERS=0 MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check success 'install URL-only source is forwarded to the noninteractive guest' install-url MODEL_ALIAS=llama3.1:8b MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/resolve/main/model.gguf?download=true
check success 'install URL can use an explicit custom model path' install MODEL_ALIAS=llama3.1:8b MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/resolve/main/model.gguf MODEL_PATH=/mnt/models/local.gguf
check success 'environment can explicitly enable guest installation' install-env INSTALL_TARGET=1 MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check failure 'guest install still requires model settings' install
check failure 'environment guest install still requires model settings' install-env INSTALL_TARGET=1
check failure 'guest install requires a model source as well as alias' install MODEL_ALIAS=llama3.1:8b
check failure 'invalid install mode rejected' default INSTALL_TARGET=invalid
check failure 'VMID below Proxmox range' create CT_ID=99
check failure 'invalid IPv4 octet' create IP_CIDR=192.0.2.999/24
check failure 'invalid network prefix' create IP_CIDR=192.0.2.50/33
check failure 'DHCP rejects a static gateway' create IP_CIDR=dhcp
check failure 'CUDA requires explicit devices' create GPU_DEVICES=
check failure 'duplicate devices rejected' create GPU_DEVICES='/dev/nvidia0 /dev/nvidia0'
check success 'stale model settings do not block CT-only provisioning' default MODEL_ALIAS=llama MODEL_PATH=/models/../model.gguf LLAMA_CPP_REF=main
check success 'a bare alias gets :latest, as in install-target' install MODEL_ALIAS=llama MODEL_PATH=/var/lib/llama-target/models/model.gguf
out=$(env -i "PATH=$PATH" "${common[@]}" MODEL_ALIAS=llama MODEL_PATH=/var/lib/llama-target/models/model.gguf "$bash_bin" "$provision" --dry-run --install-target 2>&1)
[[ $out == *'MODEL_ALIAS=llama:latest'* ]] || { printf 'FAIL bare alias was not given :latest\n' >&2; exit 1; }
passed=$((passed + 1)); printf 'PASS bare alias is passed on as name:latest\n'
check failure 'guest install rejects an invalid alias' install 'MODEL_ALIAS=bad name' MODEL_PATH=/var/lib/llama-target/models/model.gguf
check success 'LLAMA_EXTRA_ARGS is passed to the guest' install MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf 'LLAMA_EXTRA_ARGS=--flash-attn on'
check failure 'LLAMA_EXTRA_ARGS rejects shell metacharacters' install MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf 'LLAMA_EXTRA_ARGS=--x;reboot'
check failure 'guest install rejects model traversal' install MODEL_ALIAS=llama3.1:8b MODEL_PATH=/models/../model.gguf
check failure 'guest install rejects an unsafe model download URL' install MODEL_ALIAS=llama3.1:8b MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/blob/main/model.gguf
check failure 'guest install rejects a noncanonical Hugging Face host' install MODEL_ALIAS=llama3.1:8b MODEL_DOWNLOAD_URL=https://huggingface.com/org/repo/resolve/main/model.gguf
check failure 'guest install rejects an unpinned build ref' install LLAMA_CPP_REF=main MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check failure 'invalid GPU layer policy is rejected' install GPU_LAYERS=maximum MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check failure 'CPU install requires zero GPU layers' install BACKEND=cpu GPU_DEVICES= GPU_LAYERS=auto MODEL_ALIAS=llama3.1:8b MODEL_PATH=/var/lib/llama-target/models/model.gguf
check failure 'guest template must match supported OS' create TEMPLATE=local:vztmpl/debian-13-standard_test_amd64.tar.zst

# Vulkan (AMD Radeon, Intel Arc): a Debian 13 template and the card's render node.
vulkan=(TEMPLATE=local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst BACKEND=vulkan GPU_DEVICES=/dev/dri/renderD128)
# shellcheck disable=SC2086  # VFLAGS: zero or more flags
vplan() { out=$(env -i "PATH=$PATH" "${common[@]}" "${vulkan[@]}" "$@" "$bash_bin" "$provision" --dry-run ${VFLAGS:-} 2>&1); }
vcheck() { local label=$1; passed=$((passed + 1)); printf 'PASS %s\n' "$label"; }
VFLAGS=--install-target vplan MODEL_ALIAS=qwen3:8b MODEL_PATH=/var/lib/llama-target/models/m.gguf ||
    { printf 'FAIL vulkan install plan\n%s\n' "$out" >&2; exit 1; }
[[ $out == *'+ pct create 250 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst '*'--dev0 path=/dev/dri/renderD128\,gid=993\,mode=0660'* ||
   $out == *'+ pct create 250 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst '*'--dev0 path=/dev/dri/renderD128,gid=993,mode=0660'* ]] ||
    { printf 'FAIL vulkan device\n%s\n' "$out" >&2; exit 1; }
[[ $out == *'BACKEND=vulkan'* && $out == *'GPU_LAYERS=auto'* ]] || { printf 'FAIL vulkan guest env\n%s\n' "$out" >&2; exit 1; }
[[ $out != *'install_nvidia_580_173_02.sh lxc'* ]] || { printf 'FAIL vulkan ran the NVIDIA helper\n%s\n' "$out" >&2; exit 1; }
vcheck 'Vulkan: a Debian 13 CT with the render node, GPU layers on, no NVIDIA helper'
VFLAGS=--create-only vplan || { printf 'FAIL vulkan create-only\n%s\n' "$out" >&2; exit 1; }
[[ $out == *"Mesa's Vulkan driver and the build tools install automatically"* && $out != *'install_nvidia_580_173_02.sh lxc'* ]] ||
    { printf 'FAIL vulkan create-only instructions\n%s\n' "$out" >&2; exit 1; }
vcheck 'Vulkan create-only: instructions without the NVIDIA helper'
for bad in 'TEMPLATE=local:vztmpl/debian-12-standard_test_amd64.tar.zst|Debian 13' 'GPU_DEVICES=|Vulkan requires explicit GPU_DEVICES' \
        'GPU_DEVICES=/dev/nvidia0|render node only' 'BACKEND=rocm|BACKEND must be cpu, cuda or vulkan'; do
    if vplan "${bad%%|*}"; then printf 'FAIL accepted %s\n%s\n' "$bad" "$out" >&2; exit 1; fi
    [[ $out == *"${bad#*|}"* && $out != *'+ pct create'* ]] || { printf 'FAIL %s\n%s\n' "$bad" "$out" >&2; exit 1; }
done
vcheck 'Vulkan refuses a Debian 12 template, a missing or non-render device, and unknown backends'

"$bash_bin" -n "$provision"
"$bash_bin" -n "$script_dir/install-target.sh"
"$bash_bin" -n "$nvidia_installer"
printf '%s dry-run cases and all three shell syntax checks passed. No CT or service was changed.\n' "$passed"
