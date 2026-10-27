#!/usr/bin/env bash
# Fixture variables are consumed by dynamically extracted helpers.
# shellcheck disable=SC2034
# Exercise model-volume selection and Hugging Face URL helpers without installing or downloading.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# shellcheck disable=SC1090
source <(awk '
    /^# Model configuration helpers / { capture=1; next }
    /^# End model configuration helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")

for helper in normalize_huggingface_gguf_url valid_huggingface_gguf_url huggingface_gguf_filename \
    list_model_storage_volumes select_model_storage configure_model; do
    declare -F "$helper" >/dev/null || die "Installer helper extraction failed: $helper"
done

passed=0
check() {
    local label=$1 expected=$2 needle=$3 output status=0
    shift 3
    output=$("$@" 2>&1) || status=$?
    if [[ $expected == ok ]]; then
        (( status == 0 )) || die "$label: unexpected failure: $output"
    else
        (( status != 0 )) || die "$label: invalid input was accepted: $output"
    fi
    [[ $output == *"$needle"* ]] || die "$label: expected '$needle' in: $output"
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
}

hf_url_valid() {
    local url='https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf?download=true'
    valid_huggingface_gguf_url "$url" || die 'Direct Hugging Face resolve URL was rejected.'
    printf 'URL|%s\n' "$url"
}

hf_filename() {
    local url='https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf?download=true'
    printf 'FILENAME|%s\n' "$(huggingface_gguf_filename "$url")"
}

hf_blob_normalized() {
    local url='https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/blob/main/Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf'
    printf 'NORMALIZED|%s\n' "$(normalize_huggingface_gguf_url "$url")"
}

hf_url_invalid() {
    local url
    for url in \
        'http://huggingface.co/org/repo/resolve/main/model.gguf' \
        'https://huggingface.com/org/repo/resolve/main/model.gguf' \
        'https://www.huggingface.co/org/repo/resolve/main/model.gguf' \
        'https://huggingface.co.evil.example/org/repo/resolve/main/model.gguf' \
        'https://huggingface.co@evil.example/org/repo/resolve/main/model.gguf' \
        'https://user@huggingface.co/org/repo/resolve/main/model.gguf' \
        'https://huggingface.co:443/org/repo/resolve/main/model.gguf' \
        'https://huggingface.co/org/repo/tree/main/model.gguf' \
        'https://huggingface.co/org/repo/resolve/main/model.safetensors' \
        'https://huggingface.co/org/repo/resolve/main/model.gguf#fragment' \
        'https://huggingface.co/org/repo/resolve/main/model.gguf%2Fetc' \
        'https://huggingface.co/org/repo/resolve/main/'; do
        ! valid_huggingface_gguf_url "$url" || die "Invalid model download URL accepted: $url"
    done
    printf 'REJECTED invalid Hugging Face URLs\n'
}

# The selector's public inventory contract is mountpoint<TAB>display label.  The
# real inventory remains read-only; replacing it here keeps this test portable.
storage_selector() {
    MODEL_DIR=''
    MODEL_PATH=''
    NONINTERACTIVE=false
    model_prompt_available() { return 0; }
    list_model_storage_volumes() {
        printf '%s\n' \
            $'/mnt/fast-models\tfast-models (ext4)' \
            $'/srv/nas-models\tnas-models (nfs)'
    }
    select_model_storage
    printf 'DIRECTORY|%s\n' "$MODEL_DIR"
}

manual_storage_selector() {
    MODEL_DIR=''
    MODEL_PATH=''
    NONINTERACTIVE=false
    model_prompt_available() { return 0; }
    list_model_storage_volumes() { printf '%s\n' $'/mnt/fast-models\tfast-models (ext4)'; }
    select_model_storage
    printf 'DIRECTORY|%s\n' "$MODEL_DIR"
}

storage_inventory_filters_unsafe_mounts() {
    local output
    findmnt() {
        [[ $* == '-rn -o TARGET,SOURCE,FSTYPE,OPTIONS' ]] || die "Unexpected findmnt arguments: $*"
        printf '%s\n' \
            '/ /dev/sda2 ext4 rw,relatime' \
            '/mnt/fast /dev/sdb1 ext4 rw,relatime' \
            '/srv/nas fileserver:/models nfs rw,relatime' \
            '/home /dev/sda3 ext4 rw,relatime' \
            '/tmp tmpfs tmpfs rw,nosuid,nodev' \
            '/var/tmp tmpfs tmpfs rw,nosuid,nodev' \
            '/var/lib/llama-target /dev/sdc1 ext4 rw,relatime' \
            '/mnt/read-only /dev/sdd1 ext4 ro,relatime' \
            '/proc proc proc rw,nosuid,nodev,noexec' \
            '/proc/cpuinfo lxcfs fuse.lxcfs rw,nosuid,nodev,noexec' \
            '/run tmpfs tmpfs rw,nosuid,nodev'
    }
    output=$(list_model_storage_volumes)
    [[ $output == *$'/mnt/fast\t'* ]] || die "Writable persistent /mnt volume omitted: $output"
    [[ $output == *$'/srv/nas\t'* ]] || die "Writable persistent NFS volume omitted: $output"
    [[ $output != */home* && $output != */tmp* && $output != */var/tmp* ]] || die "Unsafe home or temporary mount was listed: $output"
    [[ $output != */var/lib/llama-target* ]] || die "Default model-store volume was listed twice: $output"
    [[ $output != */mnt/read-only* && $output != */proc* && $output != */run* ]] || die "Read-only or pseudo mount was listed: $output"
    printf 'INVENTORY filtered safe writable persistent mounts\n'
}

explicit_model_dir_skips_storage_selector() {
    MODEL_ALIAS=qwen3:8b
    MODEL_DOWNLOAD_URL=''
    MODEL_PATH=''
    MODEL_DIR=/mnt/fast-models/llama-target/models
    MODEL_FILE=weights.gguf
    NONINTERACTIVE=false
    select_model_storage() { die 'Storage selector must not run for explicit MODEL_DIR.'; }
    configure_model
}

explicit_model_path_skips_storage_selector() {
    MODEL_ALIAS=qwen3:8b
    MODEL_DOWNLOAD_URL=''
    MODEL_PATH=/srv/models/weights.gguf
    MODEL_DIR=''
    MODEL_FILE=''
    NONINTERACTIVE=false
    select_model_storage() { die 'Storage selector must not run for explicit MODEL_PATH.'; }
    configure_model
}

check 'direct Hugging Face resolve GGUF URL is accepted' ok \
    'URL|https://huggingface.co/' hf_url_valid
check 'Hugging Face resolve URL with a query yields the GGUF filename' ok \
    'FILENAME|Qwen2.5-7B-Instruct-Q4_K_M.gguf' hf_filename
check 'Hugging Face blob GGUF URL is normalized to a raw resolve URL' ok \
    'NORMALIZED|https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf' hf_blob_normalized
check 'non-direct, non-HTTPS, lookalike, and non-GGUF URLs are rejected' ok \
    'REJECTED invalid Hugging Face URLs' hf_url_invalid
check 'empty selector input chooses the default model directory' ok \
    'DIRECTORY|/var/lib/llama-target/models' storage_selector <<'INPUT'

INPUT
check 'numbered volume selector maps mountpoint to its model directory' ok \
    'DIRECTORY|/mnt/fast-models/llama-target/models' storage_selector <<'INPUT'
2
INPUT
check 'volume selector displays all available model-storage mounts' ok \
    '/srv/nas-models' storage_selector <<'INPUT'
3
INPUT
check 'manual volume selection retains an explicitly entered model directory' ok \
    'DIRECTORY|/opt/model-store' manual_storage_selector <<'INPUT'
m
/opt/model-store
INPUT
check 'volume inventory keeps only writable persistent safe mountpoints' ok \
    'INVENTORY filtered safe writable persistent mounts' storage_inventory_filters_unsafe_mounts
check 'explicit MODEL_DIR bypasses storage discovery and selection' ok \
    '/mnt/fast-models/llama-target/models/weights.gguf' explicit_model_dir_skips_storage_selector </dev/null
check 'explicit MODEL_PATH bypasses storage discovery and selection' ok \
    '/srv/models/weights.gguf' explicit_model_path_skips_storage_selector </dev/null

printf '%s model storage and download URL cases passed. No model, mount, or installation changes were made.\n' "$passed"
