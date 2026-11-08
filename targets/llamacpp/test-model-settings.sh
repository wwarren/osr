#!/usr/bin/env bash
# Exercise only the installer configuration helpers; never execute installation.
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1090
source <(awk '
    /^# Model configuration helpers / { capture=1; next }
    /^# End model configuration helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
declare -F configure_model >/dev/null || die 'Installer helper extraction failed.'
passed=0
check() {
    local label=$1 expected=$2 needle=$3 output status=0
    shift 3
    output=$(
        unset MODEL_ALIAS MODEL_DOWNLOAD_URL MODEL_PATH MODEL_DIR MODEL_FILE NONINTERACTIVE
        "$@" 2>&1
    ) || status=$?
    if [[ $expected == ok ]]; then
        (( status == 0 )) || die "$label: unexpected failure: $output"
    else
        (( status != 0 )) || die "$label: invalid settings accepted"
    fi
    [[ $output == *"$needle"* ]] || die "$label: expected '$needle' in: $output"
    passed=$((passed + 1))
    printf 'PASS %s\n' "$label"
}
settings() {
    local entry
    for entry in "$@"; do export "${entry?}"; done
    configure_model
}
interactive() {
    # Mock terminal availability only; exercise the real read/validation/default loop.
    model_prompt_available() { return 0; }
    configure_model
}
check 'existing MODEL_PATH workflow' ok '/srv/models/weights.gguf' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_PATH=/srv/models/weights.gguf
check 'directory and filename workflow' ok '/mnt/models/weights.gguf' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_DIR=/mnt/models/ MODEL_FILE=weights.gguf
check 'bare model name uses latest tag' ok 'Model alias: qwen3:latest' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3 MODEL_FILE=weights.gguf
check 'unattended directory default' ok '/var/lib/llama-target/models/weights.gguf' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_FILE=weights.gguf
check 'download URL supplies the default GGUF filename' ok '/var/lib/llama-target/models/model.gguf' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/resolve/main/model.gguf
check 'explicit MODEL_PATH remains the download destination' ok '/srv/models/local-name.gguf' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/resolve/main/model.gguf MODEL_PATH=/srv/models/local-name.gguf
check 'browser blob URL is normalized before installation' ok '/resolve/main/model.gguf' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/blob/main/model.gguf MODEL_FILE=weights.gguf
check 'missing unattended filename fails' fail 'Set MODEL_FILE' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b
check 'conflicting directory fails' fail 'MODEL_DIR conflicts' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_PATH=/srv/models/weights.gguf MODEL_DIR=/mnt/models
check 'conflicting filename fails' fail 'MODEL_FILE conflicts' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_PATH=/srv/models/weights.gguf MODEL_FILE=other.gguf
check 'traversal rejected' fail 'absolute model directory' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_DIR=/srv/../root MODEL_FILE=weights.gguf
check 'filename cannot escape store' fail '.gguf filename' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b MODEL_FILE=../weights.gguf
for directory in /root/models /home/models /run/user/1000/models /tmp/models /var/tmp/models /; do
    check "hidden/root directory rejected: $directory" fail 'absolute model directory' settings NONINTERACTIVE=true MODEL_ALIAS=qwen3:8b "MODEL_DIR=$directory" MODEL_FILE=weights.gguf
done
check 'interactive input and default directory' ok '/var/lib/llama-target/models/weights.gguf' interactive <<'INPUT'
qwen3:8b


weights.gguf
INPUT
check 'interactive invalid values re-prompt' ok '/srv/models/weights.gguf' interactive <<'INPUT'
bad name
qwen3

m
/root/models
/srv/models
../bad.gguf
weights.gguf
INPUT
# Regression: a single GGUF already in the store becomes the filename default.
# It used to be tested with "-n" inside (( )), which aborted under set -u
# ("n: unbound variable") and always overrode a download-supplied default.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
touch "$fixture/only.gguf"
eval "original_$(declare -f valid_model_dir)"
with_fixture_store() {
    valid_model_dir() { [[ $1 == "$fixture" || $1 == "$fixture"/* ]] || original_valid_model_dir "$1"; }
    model_prompt_available() { return 0; }
    local entry
    export MODEL_DIR=$fixture
    for entry in "$@"; do export "${entry?}"; done
    configure_model
}
check 'single GGUF in store is the default' ok "$fixture/only.gguf" with_fixture_store <<'INPUT'
qwen3:8b


INPUT
check 'download filename default is kept over a single stored GGUF' ok "$fixture/model.gguf" \
    with_fixture_store MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/resolve/main/model.gguf <<'INPUT'
qwen3:8b

INPUT
check 'interactive EOF aborts' fail 'Input ended' interactive </dev/null
printf '%s model configuration cases passed. No installation or model-store changes were made.\n' "$passed"
