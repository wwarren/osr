#!/usr/bin/env bash
# Fixture variables are consumed by dynamically extracted helpers.
# shellcheck disable=SC2034
# Exercise CUDA GPU selection helpers without querying a real PVE host or GPU.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1090
source <(awk '
    /^# GPU configuration helpers \(read-only\)\./ { capture=1; next }
    /^# End GPU configuration helpers\./ { capture=0 }
    capture { print }
' "$script_dir/provision-lxc.sh")
declare -F list_nvidia_gpus list_nvidia_gpus_from_proc nvidia_gpu_minor_from_proc \
    nvidia_gpu_minor nvidia_device_node_exists configure_gpu_devices valid_gpu_device_list >/dev/null || die 'GPU helper extraction failed.'

passed=0
check() {
    local label=$1 expected=$2 needle=$3 output status=0
    shift 3
    output=$("$@" 2>&1) || status=$?
    if [[ $expected == ok ]]; then
        (( status == 0 )) || die "$label: unexpected failure: $output"
    else
        (( status != 0 )) || die "$label: invalid state was accepted: $output"
    fi
    [[ $output == *"$needle"* ]] || die "$label: expected '$needle' in: $output"
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
}

proc_inventory_is_preferred() {
    list_nvidia_gpus_from_proc() {
        printf '%s\n' $'0\tNVIDIA RTX PRO 2000 Blackwell at 00000000:06:00.0 (/dev/nvidia0)'
    }
    nvidia-smi() { die "nvidia-smi must not run when /proc has an authoritative mapping: $*"; }
    list_nvidia_gpus
}

proc_information_minor_is_parsed() {
    local information_file minor
    information_file=$(mktemp)
    trap 'rm -f -- "$information_file"' RETURN
    printf '%s\n' \
        'Model:             NVIDIA RTX PRO 2000 Blackwell' \
        'IRQ:               123' \
        'Bus Location:      00000000:06:00.0' \
        'Device Minor:      0' > "$information_file"
    minor=$(nvidia_gpu_minor_from_proc "$information_file")
    [[ $minor == 0 ]] || die "Expected Device Minor 0, got '$minor'."
    printf 'PROC_MINOR|%s\n' "$minor"
}

fallback_inventory_from_smi_l_and_detailed_query() {
    list_nvidia_gpus_from_proc() { return 1; }
    nvidia-smi() {
        case "$*" in
            *minor_number*) die "Unsupported nvidia-smi minor_number query was attempted: $*" ;;
            -L)
                printf '%s\n' \
                    'GPU 0: NVIDIA RTX 3090 (UUID: GPU-00000000-0000-0000-0000-000000000000)' \
                    'GPU 1: NVIDIA RTX PRO 4000 Blackwell (UUID: GPU-11111111-1111-1111-1111-111111111111)'
                ;;
            '-q -i 0') printf '%s\n' '    Minor Number                        : 7' ;;
            '-q -i 1') printf '%s\n' 'Minor Number : 3' ;;
            *) die "Unexpected nvidia-smi fallback arguments: $*" ;;
        esac
    }
    list_nvidia_gpus
}

select_second_gpu_from_smi_fallback() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_nvidia_gpus_from_proc() { return 1; }
    nvidia-smi() {
        case "$*" in
            *minor_number*) die "Unsupported nvidia-smi minor_number query was attempted: $*" ;;
            -L)
                printf '%s\n' \
                    'GPU 0: NVIDIA RTX 3090 (UUID: GPU-00000000-0000-0000-0000-000000000000)' \
                    'GPU 1: NVIDIA RTX PRO 4000 Blackwell (UUID: GPU-11111111-1111-1111-1111-111111111111)'
                ;;
            '-q -i 0') printf '%s\n' 'Minor Number : 7' ;;
            '-q -i 1') printf '%s\n' '    Minor Number                        : 3' ;;
            *) die "Unexpected nvidia-smi fallback arguments: $*" ;;
        esac
    }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

detailed_query_error_prompts_manual() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_nvidia_gpus_from_proc() { return 1; }
    nvidia_device_node_exists() { return 1; }
    nvidia-smi() {
        case "$*" in
            *minor_number*) die "Unsupported nvidia-smi minor_number query was attempted: $*" ;;
            -L) printf '%s\n' 'GPU 0: NVIDIA RTX PRO 2000 Blackwell (UUID: GPU-00000000-0000-0000-0000-000000000000)' ;;
            '-q -i 0') printf '%s\n' 'Failed to initialize NVML: Unknown Error' >&2; return 1 ;;
            *) die "Unexpected nvidia-smi fallback arguments: $*" ;;
        esac
    }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

single_gpu_detail_failure_uses_index_only_with_device_node() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_nvidia_gpus_from_proc() { return 1; }
    nvidia_device_node_exists() { [[ $1 == /dev/nvidia5 || $1 == 5 ]]; }
    nvidia-smi() {
        case "$*" in
            *minor_number*) die "Unsupported nvidia-smi minor_number query was attempted: $*" ;;
            -L) printf '%s\n' 'GPU 5: NVIDIA RTX PRO 2000 Blackwell (UUID: GPU-55555555-5555-5555-5555-555555555555)' ;;
            '-q -i 5') printf '%s\n' 'GPU query unavailable' >&2; return 1 ;;
            *) die "Unexpected nvidia-smi fallback arguments: $*" ;;
        esac
    }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

multiple_gpu_detail_failures_do_not_guess_minors() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_nvidia_gpus_from_proc() { return 1; }
    nvidia_device_node_exists() { die 'Index fallback must not inspect device nodes when multiple physical GPUs were listed.'; }
    nvidia-smi() {
        case "$*" in
            *minor_number*) die "Unsupported nvidia-smi minor_number query was attempted: $*" ;;
            -L)
                printf '%s\n' \
                    'GPU 0: NVIDIA RTX PRO 2000 Blackwell (UUID: GPU-00000000-0000-0000-0000-000000000000)' \
                    'GPU 1: NVIDIA RTX 3090 (UUID: GPU-11111111-1111-1111-1111-111111111111)'
                ;;
            '-q -i 0'|'-q -i 1') printf '%s\n' 'GPU query unavailable' >&2; return 1 ;;
            *) die "Unexpected nvidia-smi fallback arguments: $*" ;;
        esac
    }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

valid_device_lists() {
    valid_gpu_device_list '/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' || die 'Valid GPU device list rejected.'
    ! valid_gpu_device_list '' || die 'Empty device list accepted.'
    ! valid_gpu_device_list '/dev/nvidia0 /dev/../bad' || die 'Traversal device list accepted.'
    ! valid_gpu_device_list 'relative-device' || die 'Relative device list accepted.'
    printf 'VALIDATED\n'
}

select_second_gpu() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_nvidia_gpus() {
        printf '%s\n' \
            $'7\tGPU 0: NVIDIA RTX 3090 (/dev/nvidia7)' \
            $'3\tGPU 1: NVIDIA RTX PRO 4000 Blackwell (/dev/nvidia3)'
    }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

manual_gpu_devices() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_nvidia_gpus() { printf '%s\n' $'7\tGPU 0: NVIDIA RTX 3090 (/dev/nvidia7)'; }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

explicit_devices_skip_discovery() {
    BACKEND=cuda
    GPU_DEVICES='/dev/nvidia9 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools'
    NONINTERACTIVE=false
    container_prompt_available() { die 'Prompt detection must not run for explicit GPU_DEVICES.'; }
    list_nvidia_gpus() { die 'GPU discovery must not run for explicit GPU_DEVICES.'; }
    configure_gpu_devices || die 'Explicit GPU_DEVICES made configure_gpu_devices return nonzero.'
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

cpu_skips_selection() {
    BACKEND=cpu
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { die 'Prompt detection must not run for CPU.'; }
    list_nvidia_gpus() { die 'GPU discovery must not run for CPU.'; }
    configure_gpu_devices || die 'CPU backend made configure_gpu_devices return nonzero.'
    printf 'CPU SKIPPED\n'
}

unattended_cuda_requires_devices() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=true
    container_prompt_available() { return 1; }
    list_nvidia_gpus() { die 'GPU discovery must not run without a terminal.'; }
    configure_gpu_devices
}

empty_inventory_allows_manual_devices() {
    BACKEND=cuda
    GPU_DEVICES=''
    NONINTERACTIVE=false
    container_prompt_available() { return 0; }
    list_nvidia_gpus() { :; }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}

vulkan_render_nodes() {
    local drm
    drm=$(mktemp -d); trap 'rm -rf -- "$drm"' RETURN
    mkdir -p "$drm/renderD128/device" "$drm/renderD129/device" "$drm/renderD130/device"
    printf '0x8086\n' > "$drm/renderD128/device/vendor"; printf '0xa780\n' > "$drm/renderD128/device/device"
    printf '0x1002\n' > "$drm/renderD129/device/vendor"; printf '0x744c\n' > "$drm/renderD129/device/device"
    printf '0x10de\n' > "$drm/renderD130/device/vendor"; printf '0x2684\n' > "$drm/renderD130/device/device"
    BACKEND=vulkan GPU_DEVICES='' NONINTERACTIVE=false DRM_SYSFS=$drm
    container_prompt_available() { return 0; }
    list_nvidia_gpus() { die 'NVIDIA discovery must not run for Vulkan.'; }
    configure_gpu_devices
    printf 'DEVICES|%s\n' "$GPU_DEVICES"
}
unattended_vulkan_requires_devices() {
    BACKEND=vulkan GPU_DEVICES='' NONINTERACTIVE=true
    container_prompt_available() { return 1; }
    configure_gpu_devices
}

check 'Vulkan lists AMD and Intel render nodes (not NVIDIA) and maps the choice' ok 'DEVICES|/dev/dri/renderD129' vulkan_render_nodes <<'INPUT'
2
INPUT
check 'unattended Vulkan requires the render node' fail 'Vulkan requires explicit GPU_DEVICES' unattended_vulkan_requires_devices
check 'authoritative /proc mapping is preferred without running nvidia-smi' ok $'0\tNVIDIA RTX PRO 2000 Blackwell at 00000000:06:00.0 (/dev/nvidia0)' proc_inventory_is_preferred
check 'NVIDIA /proc information Device Minor is parsed' ok 'PROC_MINOR|0' proc_information_minor_is_parsed
check 'nvidia-smi -L plus detailed query maps actual GPU minors without minor_number query' ok $'3\tGPU 1: NVIDIA RTX PRO 4000 Blackwell (/dev/nvidia3)' fallback_inventory_from_smi_l_and_detailed_query
check 'GPU device-list validation accepts only safe nonempty device paths' ok VALIDATED valid_device_lists
check 'numbered GPU selection maps the selected minor and required control devices' ok 'DEVICES|/dev/nvidia3 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' select_second_gpu <<'INPUT'
2
INPUT
check 'fallback GPU selector uses detailed-query minor instead of NVIDIA index' ok 'DEVICES|/dev/nvidia3 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' select_second_gpu_from_smi_fallback <<'INPUT'
2
INPUT
check 'detailed nvidia-smi failure is surfaced before manual device entry' ok 'nvidia-smi detailed query failed for GPU 0: Failed to initialize NVML: Unknown Error' detailed_query_error_prompts_manual <<'INPUT'
/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools
INPUT
check 'detailed query failure still accepts manual GPU device paths' ok 'DEVICES|/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' detailed_query_error_prompts_manual <<'INPUT'
/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools
INPUT
check 'single-GPU index fallback requires and uses an existing character device' ok 'DEVICES|/dev/nvidia5 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' single_gpu_detail_failure_uses_index_only_with_device_node <<'INPUT'
1
INPUT
check 'multiple failed detailed queries do not infer minors from indices' ok 'DEVICES|/dev/nvidia11 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' multiple_gpu_detail_failures_do_not_guess_minors <<'INPUT'
/dev/nvidia11 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools
INPUT
check 'manual GPU selection validates and retains explicit device paths' ok 'DEVICES|/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' manual_gpu_devices <<'INPUT'
m
/dev/../bad
/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools
INPUT
check 'explicit GPU device paths skip prompt and discovery' ok 'DEVICES|/dev/nvidia9 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' explicit_devices_skip_discovery </dev/null
check 'CPU backend skips GPU selection' ok 'CPU SKIPPED' cpu_skips_selection </dev/null
check 'CUDA without a terminal requires explicit GPU devices' fail 'CUDA requires explicit GPU_DEVICES' unattended_cuda_requires_devices </dev/null
check 'empty interactive GPU inventory falls back to validated manual paths' ok 'DEVICES|/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools' empty_inventory_allows_manual_devices <<'INPUT'
/dev/nvidia7 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools
INPUT

printf '%s GPU selection cases passed. No PVE, GPU, or CT changes were made.\n' "$passed"
