#!/usr/bin/env bash
# Runs inside the dedicated Avalon LXC once its GPU is passed through (and, for
# CUDA, matching NVIDIA user space is installed).
#
#   bash install-target.sh             install or update Avalon and start it
#   bash install-target.sh --upgrade   move to AVALON_COMMIT or AVALON_REF (default
#                                      tested commit in upstream-commit.txt);
#                                      roll back to the previous commit
#                                      and runtime on failure
#   bash install-target.sh --dry-run   print the plan; change nothing
#
# Avalon (https://github.com/freriadoc/Avalon) is a llama.cpp fork built for
# one model, Qwen3.8-Flash-Next (125B MoE), on one consumer GPU with the
# experts in system RAM. This target builds its llama-server for the CT's GPU,
# with ROCm (AMD Radeon RX 7000, RDNA 3: upstream's reference) or CUDA
# (NVIDIA), downloads the pinned IQ3_KS GGUF and its MTP draft head listed in
# avalon-weights.txt (about 90 GiB), and serves the OpenAI-compatible API.
set -Eeuo pipefail
# Upgrade signal guard
# upgrade_guard on|rollback|off: a signal (Ctrl-C, a closed SSH session,
# kill) during an upgrade must not stop this script before it can roll back.
# on: a signal is recorded in upgrade_interrupted; the upgrade's subshell dies
# from it, so its failure takes the rollback path. rollback: further signals
# are ignored while the previous release is restored. off: the defaults are
# back. After a hangup the output goes to OSR_INTERRUPT_LOG, so writes to the
# closed terminal cannot fail the rollback.
# Every copy matches targets/upgrade-guard.sh (tests/test-signal-rollback.sh).
upgrade_interrupted=''
upgrade_hangup() {
    upgrade_interrupted=${upgrade_interrupted:-129}
    exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
}
upgrade_guard() {
    case $1 in
        on)
            upgrade_interrupted=''
            trap 'upgrade_interrupted=${upgrade_interrupted:-130}' INT
            trap 'upgrade_interrupted=${upgrade_interrupted:-143}' TERM
            trap upgrade_hangup HUP ;;
        rollback) trap '' INT TERM HUP ;;
        off) trap - INT TERM HUP ;;
    esac
}
# End upgrade signal guard.

AVALON_URL=https://github.com/freriadoc/Avalon.git
# Paths are overridable for tests only; the unit file uses the defaults.
AVALON_DIR=${AVALON_DIR:-/opt/avalon}
AVALON_DATA_DIR=${AVALON_DATA_DIR:-/var/lib/avalon}
AVALON_ETC_DIR=${AVALON_ETC_DIR:-/etc/avalon-target}
# The server's copy of the API key: root may change it, the avalon group may
# only read it. Kept apart from the root-only records above.
AVALON_CONFIG_DIR=${AVALON_CONFIG_DIR:-/etc/avalon}
# Root-only scratch for the pre-upgrade runtime snapshot (removed after use).
AVALON_STATE_DIR=${AVALON_STATE_DIR:-/var/lib/avalon-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-avalon}
# GPU device nodes whose group the service user joins (glob-expanded). The
# default follows AVALON_BACKEND (set below).
GPU_NODES=${GPU_NODES:-}
DEV_DRI=${DEV_DRI:-/dev/dri}
DRM_SYSFS=${DRM_SYSFS:-/sys/class/drm}
MEMINFO=${MEMINFO:-/proc/meminfo}
CPUINFO=${CPUINFO:-/proc/cpuinfo}
# The distro's cmake (apt); its PATH is set per build step.
CMAKE_BIN=${CMAKE_BIN:-/usr/bin/cmake}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
usage() {
    cat <<'USAGE'
Usage: bash install-target.sh [--dry-run] [--upgrade]
Installs Avalon from https://github.com/freriadoc/Avalon.git as the "avalon"
service account, builds its llama-server with ROCm (AVALON_BACKEND=rocm, AMD
Radeon RX 7000) or CUDA (AVALON_BACKEND=cuda, NVIDIA) for the GPU found here,
downloads the pinned Qwen3.8-Flash-Next IQ3_KS GGUF and MTP draft head (about
90 GiB, see avalon-weights.txt), and starts the hardened avalon systemd
service. Re-running fetches AVALON_COMMIT or AVALON_REF before stopping
anything: when the commit, settings, weights and unit are unchanged and Avalon
is healthy it does nothing; otherwise it rebuilds and restarts, rolling back
to the previous commit and runtime on failure.

Reruns, with or without --upgrade, keep the settings of the existing installation
(installed-env, or installed-settings for older installs); explicit, non-empty
environment values override them. A fresh install uses the defaults below.

Environment: by default, use the tested commit in upstream-commit.txt.
AVALON_REF=<branch or tag, e.g. main> or AVALON_COMMIT=<full SHA-1 pin>
overrides that default (AVALON_COMMIT wins if both are set).
AVALON_BACKEND=auto (rocm when /dev/kfd is here, else cuda),
AVALON_ROCM_VERSION=7.2.4, AVALON_GPU_TARGET=auto (gfx1100, gfx1101 or
gfx1102, from the card's PCI ID), AVALON_CUDA_VERSION=12.9,
AVALON_CUDA_ARCH=auto (the GPU's compute capability, 75 or newer),
AVALON_PORT=8080, AVALON_CONTEXT=65536 (auto: 262144 tokens with 19 GB of
VRAM or more, else 65536), AVALON_MTP=true (speculative decoding with the 1.4 GB MTP
draft head), AVALON_MODEL_NAME=qwen3.8-flash-next-avalon (the API's model id),
AVALON_READY_TIMEOUT=1800 (seconds).
USAGE
}

# Install helpers (sourced by test-install.sh) ---------------------------------

# The files a checkout must carry, and the llama-server options the unit uses.
REQUIRED_FILES=(CMakeLists.txt common/arg.cpp tools/server/server.cpp ggml/src/ggml-hip/CMakeLists.txt
    ggml/src/ggml-cuda/moe-cache.cu)
REQUIRED_SERVER_FLAGS=(-m --alias -c -b -ub -fa -ctk -ctv --jinja --parallel -md --spec-type
    --spec-draft-n-max -ubd -ctkd -ctvd --host --port --api-key-file --no-webui)
REQUIRED_CMAKE_OPTIONS=(GGML_HIP GGML_CUDA LLAMA_BUILD_UI LLAMA_USE_PREBUILT_UI LLAMA_OPENSSL)

# validate_checkout DIR: refuse a checkout this installer does not know how to
# build or serve, before anything is built or stopped.
validate_checkout() {
    local dir=$1 file option flag
    local -a missing=()
    for file in "${REQUIRED_FILES[@]}"; do
        [[ -f $dir/$file ]] || missing+=("$file")
    done
    (( ${#missing[@]} == 0 )) ||
        { note "This Avalon checkout lacks: ${missing[*]}. Pin a compatible AVALON_COMMIT."; return 1; }
    for option in "${REQUIRED_CMAKE_OPTIONS[@]}"; do
        grep -qs -- "option($option " "$dir/CMakeLists.txt" "$dir/ggml/CMakeLists.txt" || missing+=("-D$option")
    done
    for flag in "${REQUIRED_SERVER_FLAGS[@]}"; do
        grep -qF -- "\"$flag\"" "$dir/common/arg.cpp" || missing+=("$flag")
    done
    grep -qF -- '"draft-mtp"' "$dir/common/arg.cpp" "$dir"/common/speculative.cpp 2>/dev/null || missing+=('--spec-type draft-mtp')
    (( ${#missing[@]} == 0 )) ||
        { note "This Avalon checkout's build or server does not accept: ${missing[*]}. Pin a compatible AVALON_COMMIT."; return 1; }
}

# rocm_dir: where rocm-toolkit.sh installs AVALON_ROCM_VERSION.
rocm_dir() { printf '%s\n' "${AVALON_ROCM_DIR:-/opt/rocm-$AVALON_ROCM_VERSION}"; }

# cmake_args: the configure arguments for llama-server (upstream README:
# Build), with this CT's compilers and GPU. The embedded web UI is neither
# built (npm) nor downloaded (a prebuilt bundle from Hugging Face) and the
# server runs with --no-webui; HTTPS client support is not needed.
cmake_args() {
    local rocm
    printf '%s\n' -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_UI=OFF \
        -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_OPENSSL=OFF
    if [[ $AVALON_BACKEND == rocm ]]; then
        rocm=$(rocm_dir)
        printf '%s\n' -DGGML_HIP=ON "-DAMDGPU_TARGETS=$AVALON_GPU_TARGET" \
            "-DCMAKE_C_COMPILER=$rocm/bin/amdclang" "-DCMAKE_CXX_COMPILER=$rocm/bin/amdclang++" \
            "-DCMAKE_HIP_COMPILER=$rocm/llvm/bin/clang++" "-DCMAKE_PREFIX_PATH=$rocm"
    else
        printf '%s\n' -DGGML_CUDA=ON "-DCMAKE_CUDA_ARCHITECTURES=$AVALON_CUDA_ARCH" \
            "-DCMAKE_CUDA_COMPILER=$AVALON_NVCC"
    fi
}

# compute_cap_arch: "8.9" (nvidia-smi --query-gpu=compute_cap) -> 89.
compute_cap_arch() {
    local cap
    cap=$(head -n1 | tr -d '[:space:]')
    [[ $cap =~ ^([0-9]+)\.([0-9])$ ]] || return 1
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# gfx_of_pci_device ID: the LLVM target of an RDNA 3 card by PCI device ID
# (0x744c -> gfx1100), as tools/setup-host-gpu.sh maps them; empty for others.
gfx_of_pci_device() {
    local id=${1,,}
    id=${id#0x}
    case ${id:0:3} in
        744|745) echo gfx1100 ;;
        746|747) echo gfx1101 ;;
        748|749) echo gfx1102 ;;
        *) echo '' ;;
    esac
}

# amd_render_nodes: "<node> <PCI device> <VRAM bytes>" for each AMD render
# node passed into the CT.
amd_render_nodes() {
    local node name sys vendor device vram
    for node in "$DEV_DRI"/renderD*; do
        [[ -e $node ]] || continue
        name=${node##*/}
        sys=$DRM_SYSFS/$name/device
        vendor=$(cat "$sys/vendor" 2>/dev/null || true)
        [[ ${vendor,,} == 0x1002 ]] || continue
        device=$(cat "$sys/device" 2>/dev/null || true)
        vram=$(cat "$sys/mem_info_vram_total" 2>/dev/null || true)
        [[ $vram =~ ^[0-9]+$ ]] || vram=0
        printf '%s %s %s\n' "$node" "${device:-unknown}" "$vram"
    done
}

# gpu_vram_mib: the VRAM of the CT's GPU in MiB (the first AMD render node for
# ROCm, GPU 0 for CUDA). A marketed 16 GB card reports slightly less than
# 16384 MiB after firmware reservations.
gpu_vram_mib() {
    local mib _node _device bytes
    if [[ $AVALON_BACKEND == rocm ]]; then
        read -r _node _device bytes < <(amd_render_nodes) || return 1
        [[ ${bytes:-0} -gt 0 ]] || return 1
        printf '%s\n' "$(( bytes / 1048576 ))"
        return 0
    fi
    mib=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits -i 0 2>/dev/null | head -n1 | tr -d '[:space:]') || return 1
    [[ $mib =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$mib"
}

# context_for_vram MIB: upstream fits the full 256k context with the MTP draft
# head under 19.7 GiB, and suggests -c 65536 below 20 GB.
context_for_vram() {
    if (( $1 >= 19000 )); then echo 262144; else echo 65536; fi
}

# Paths of the installed weights (see avalon-weights.txt).
model_path() { printf '%s/models/%s\n' "$AVALON_DATA_DIR" "$1"; }
MODEL_FILE=Qwen3.8-Flash-Next-Avalon-IQ3KS-00001-of-00033.gguf
MTP_FILE=MTP/mtp-Qwen3.8-Flash-Next-shared-IQ3K-IQ4NL-FR65k.gguf

# weight_rows FILE: the rows this install needs, checked, as
# "path size hash url" lines (mtp rows only with AVALON_MTP=true).
weight_rows() {
    local group path size hash url extra found=0
    while read -r group path size hash url extra; do
        [[ -n $group && $group != \#* ]] || continue
        if [[ ! $group =~ ^(model|mtp)$ ||
              ! $path =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ || $path == *..* ||
              ! $size =~ ^[1-9][0-9]{0,14}$ || ! $hash =~ ^(sha256:[0-9a-f]{64}|git:[0-9a-f]{40})$ || -n $extra ||
              ! $url =~ ^https://huggingface\.co/[^[:space:]\'\"\`\$\\]+$ ]]; then
            printf 'Error: malformed row in %s: %s %s\n' "$1" "$group" "$path" >&2
            return 1
        fi
        [[ $group != mtp || $AVALON_MTP == true ]] || continue
        printf '%s %s %s %s\n' "$path" "$size" "$hash" "$url"
        found=1
    done < "$1"
    (( found )) || { printf 'Error: %s lists no weights.\n' "$1" >&2; return 1; }
}

# The settings that decide how Avalon is built and served. save_settings
# records them after every successful install or upgrade, so a failed upgrade
# can roll back to what last worked.
SETTING_KEYS=(AVALON_BACKEND AVALON_ROCM_VERSION AVALON_GPU_TARGET AVALON_CUDA_VERSION AVALON_NVCC
    AVALON_CUDA_ARCH AVALON_PORT AVALON_CONTEXT AVALON_MTP AVALON_MODEL_NAME)

# validate_settings: die unless every setting has a value this script accepts.
validate_settings() {
    [[ $AVALON_BACKEND =~ ^(rocm|cuda)$ ]] || die 'AVALON_BACKEND must be rocm or cuda.'
    [[ $AVALON_ROCM_VERSION =~ ^7\.[0-9]+(\.[0-9]+)?$ ]] || die 'AVALON_ROCM_VERSION must be a ROCm 7.x release (7.2.4).'
    [[ $AVALON_GPU_TARGET =~ ^(auto|gfx110[012])$ ]] ||
        die 'AVALON_GPU_TARGET must be auto, gfx1100, gfx1101 or gfx1102 (RDNA 3: Avalon'\''s HIP kernels target these).'
    [[ $AVALON_CUDA_VERSION =~ ^(12\.([4-9])|1[3-9]\.[0-9]+)$ ]] || die 'AVALON_CUDA_VERSION must be 12.4 or newer.'
    [[ $AVALON_NVCC =~ ^/[A-Za-z0-9._/-]+$ && $AVALON_NVCC != *..* ]] || die 'Invalid AVALON_NVCC.'
    [[ $AVALON_CUDA_ARCH == auto || ( $AVALON_CUDA_ARCH =~ ^[1-9][0-9]{1,2}$ && $AVALON_CUDA_ARCH -ge 75 ) ]] ||
        die 'AVALON_CUDA_ARCH must be auto or a compute capability of 75 or newer (75, 80, 86, 89, 120, ...).'
    [[ $AVALON_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( AVALON_PORT <= 65535 )) || die 'Invalid AVALON_PORT.'
    [[ $AVALON_CONTEXT == auto || ( $AVALON_CONTEXT =~ ^[1-9][0-9]{3,5}$ && $AVALON_CONTEXT -ge 4096 &&
       $AVALON_CONTEXT -le 262144 ) ]] || die 'AVALON_CONTEXT must be auto or 4096..262144 tokens.'
    [[ $AVALON_MTP =~ ^(true|false)$ ]] || die 'AVALON_MTP must be true or false.'
    [[ $AVALON_MODEL_NAME =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die 'Invalid AVALON_MODEL_NAME (lowercase letters, digits, ., _ and -).'
}

# settings_env: the settings as KEY=value lines (no secrets).
settings_env() {
    local key
    for key in "${SETTING_KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}" || return 1; done
}

# load_settings FILE: set the recorded settings from FILE. The file is parsed,
# never sourced: only the known keys are read, and nothing is changed unless
# every key is present and valid.
load_settings() {
    local file=$1 line key
    local -A found=()
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^(AVALON_[A-Z_]+)=(.*)$ ]] || continue
        [[ " ${SETTING_KEYS[*]} " == *" ${BASH_REMATCH[1]} "* ]] || continue
        found[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    done < "$file"
    for key in "${SETTING_KEYS[@]}"; do [[ -v found[$key] ]] || return 1; done
    # Validate in a subshell first: validate_settings dies on a bad value.
    (
        for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
        validate_settings
    ) >/dev/null 2>&1 || return 1
    for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
}

# fingerprint_env FILE: an installed-settings fingerprint as the KEY=value
# lines load_settings reads.
fingerprint_env() {
    sed -n -e 's/^backend=/AVALON_BACKEND=/p' \
        -e 's/^rocm=/AVALON_ROCM_VERSION=/p' \
        -e 's/^gpu_target=/AVALON_GPU_TARGET=/p' \
        -e 's/^cuda=/AVALON_CUDA_VERSION=/p' \
        -e 's/^nvcc=/AVALON_NVCC=/p' \
        -e 's/^arch=/AVALON_CUDA_ARCH=/p' \
        -e 's/^port=/AVALON_PORT=/p' \
        -e 's/^context=/AVALON_CONTEXT=/p' \
        -e 's/^mtp=/AVALON_MTP=/p' \
        -e 's/^model_name=/AVALON_MODEL_NAME=/p' "$1"
}

# saved_settings: an existing installation keeps its settings on every rerun,
# with or without --upgrade. Explicit, non-empty environment values win. Only
# a fresh install with no checkout, unit or settings record uses the defaults.
saved_settings() {
    local key
    local -A overrides=()
    for key in "${SETTING_KEYS[@]}"; do
        if [[ -n ${!key-} ]]; then overrides[$key]=${!key}; fi
    done
    if [[ -e $AVALON_ETC_DIR/installed-env ]]; then
        load_settings "$AVALON_ETC_DIR/installed-env" ||
            die "Invalid or incomplete $AVALON_ETC_DIR/installed-env. Fix it, or remove it to fall back to installed-settings; explicit settings in the environment still win."
    elif [[ -e $AVALON_ETC_DIR/installed-settings || -L $AVALON_ETC_DIR/installed-settings ||
            -e $AVALON_ETC_DIR/pending-env || -L $AVALON_ETC_DIR/pending-env ||
            -e $AVALON_DIR/.git || -L $AVALON_DIR/.git ||
            -e $UNIT_DIR/avalon.service || -L $UNIT_DIR/avalon.service ]]; then
        # A checkout or unit still identifies an existing installation when
        # its records have been lost. Never apply fresh defaults to it.
        if [[ -f $AVALON_ETC_DIR/installed-settings && -r $AVALON_ETC_DIR/installed-settings ]] &&
                load_settings <(fingerprint_env "$AVALON_ETC_DIR/installed-settings"); then
            note "Using the settings recorded in $AVALON_ETC_DIR/installed-settings (installed-env is missing)."
        elif [[ ! -e $AVALON_ETC_DIR/installed-settings && ! -L $AVALON_ETC_DIR/installed-settings &&
                -f $AVALON_ETC_DIR/pending-env && -r $AVALON_ETC_DIR/pending-env ]] &&
                load_settings "$AVALON_ETC_DIR/pending-env"; then
            # A first install that stopped part-way resumes with the settings it
            # was started with, never with the defaults.
            note "Resuming an interrupted install with the settings it was started with ($AVALON_ETC_DIR/pending-env)."
        else
            local missing
            if [[ -e $AVALON_ETC_DIR/installed-settings || -L $AVALON_ETC_DIR/installed-settings ]]; then
                missing="Cannot read this installation's settings from $AVALON_ETC_DIR/installed-settings"
            else
                missing="Found an existing Avalon installation (checkout, unit or pending-env) but no readable settings record (installed-env, installed-settings or pending-env in $AVALON_ETC_DIR)"
            fi
            for key in "${SETTING_KEYS[@]}"; do
                [[ -v overrides[$key] ]] ||
                    die "$missing; set ${SETTING_KEYS[*]} explicitly, or restore a record."
            done
        fi
    fi
    # A changed toolkit version needs its matching default nvcc unless supplied.
    if [[ -v overrides[AVALON_CUDA_VERSION] && ! -v overrides[AVALON_NVCC] &&
          ${overrides[AVALON_CUDA_VERSION]} != "${AVALON_CUDA_VERSION:-}" ]]; then
        unset AVALON_NVCC
    fi
    # A changed backend detects its GPU again unless the target is supplied.
    if [[ -v overrides[AVALON_BACKEND] && ${overrides[AVALON_BACKEND]} != "${AVALON_BACKEND:-}" ]]; then
        [[ -v overrides[AVALON_GPU_TARGET] ]] || AVALON_GPU_TARGET=auto
        [[ -v overrides[AVALON_CUDA_ARCH] ]] || AVALON_CUDA_ARCH=auto
        [[ -v overrides[AVALON_CONTEXT] ]] || AVALON_CONTEXT=auto
    fi
    for key in "${!overrides[@]}"; do printf -v "$key" '%s' "${overrides[$key]}"; done
}

# server_args: llama-server's arguments (upstream README: Run, and the
# launcher its install.sh writes), with absolute model paths, this target's
# alias, context, address and key file. The key itself is never an argument.
server_args() {
    printf '%s\n' -m "$(model_path "$MODEL_FILE")" --alias "$AVALON_MODEL_NAME" -c "$AVALON_CONTEXT" \
        -b 9536 -ub 9536 -fa on -ctk q8_0 -ctv q4_0 --jinja --parallel 1
    if [[ $AVALON_MTP == true ]]; then
        printf '%s\n' -md "$(model_path "$MTP_FILE")" --spec-type draft-mtp --spec-draft-n-max 2 \
            -ubd 256 -ctkd q8_0 -ctvd q8_0
    fi
    printf '%s\n' --host 0.0.0.0 --port "$AVALON_PORT" --api-key-file "$(key_file)" --no-webui
}
key_file() { printf '%s/api-key\n' "$AVALON_CONFIG_DIR"; }

# start_env: the EnvironmentFile the unit expands into ExecStart (no secrets).
# systemd splits the unquoted $AVALON_ARGS on whitespace; no path has any.
start_env() {
    printf '# Written by install-target.sh; do not edit.\n'
    printf 'AVALON_ARGS=%s\n' "$(server_args | paste -sd' ' -)"
}

# settings_fingerprint: what the running service was set up with. A rerun that
# finds the same commit, this fingerprint and the same unit does nothing.
settings_fingerprint() {
    local env_hash toolkit_hash weights_hash
    env_hash=$(start_env | sha256sum | cut -d' ' -f1) || return 1
    toolkit_hash=$(cat "$source_dir/rocm-toolkit.sh" "$source_dir/cuda-toolkit.sh" | sha256sum | cut -d' ' -f1) || return 1
    weights_hash=$(sha256sum "$source_dir/avalon-weights.txt" | cut -d' ' -f1) || return 1
    printf 'backend=%s\nrocm=%s\ngpu_target=%s\ncuda=%s\nnvcc=%s\narch=%s\nport=%s\ncontext=%s\nmtp=%s\nmodel_name=%s\ntoolkit_sha256=%s\nweights_sha256=%s\nargs_sha256=%s\n' \
        "$AVALON_BACKEND" "$AVALON_ROCM_VERSION" "$AVALON_GPU_TARGET" "$AVALON_CUDA_VERSION" "$AVALON_NVCC" \
        "$AVALON_CUDA_ARCH" "$AVALON_PORT" "$AVALON_CONTEXT" "$AVALON_MTP" "$AVALON_MODEL_NAME" \
        "$toolkit_hash" "$weights_hash" "$env_hash"
}

# End install helpers. ----------------------------------------------------------

# as_service CMD...: run CMD as the service account. The installer lock's
# descriptor is closed for it, so nothing it leaves running in the background
# (git's detached housekeeping, an upstream script's helper) holds the lock
# after the installer has exited.
as_service() {
    if [[ -n ${install_lock_fd:-} ]]; then
        runuser -u "$SERVICE_USER" -- env HOME="$AVALON_DATA_DIR" "$@" {install_lock_fd}>&-
    else
        runuser -u "$SERVICE_USER" -- env HOME="$AVALON_DATA_DIR" "$@"
    fi
}
git_root() { git -c safe.directory="$AVALON_DIR" -C "$AVALON_DIR" "$@"; }
verify_source_origin() {
    local origin
    origin=$(git_root remote get-url origin)
    [[ $origin == "$AVALON_URL" ]] || die "Existing $AVALON_DIR origin is not official: $origin"
}

fetch_spec() {
    if [[ -n $AVALON_COMMIT ]]; then printf '%s\n' "$AVALON_COMMIT"; else printf '%s\n' "$AVALON_REF"; fi
}

# Fetch the target into FETCH_HEAD without touching the checkout, and print
# the fetched commit. A fetch by commit works for any commit, not only a
# branch tip.
fetch_target() {
    local fetched
    if [[ ! -d $AVALON_DIR/.git ]]; then
        as_service git init -q "$AVALON_DIR"
        as_service git -C "$AVALON_DIR" remote add origin "$AVALON_URL"
    fi
    as_service git -c gc.autoDetach=false -c maintenance.autoDetach=false -C "$AVALON_DIR" fetch -q --depth 1 origin "$(fetch_spec)" >&2 || return 1
    fetched=$(git_root rev-parse 'FETCH_HEAD^{commit}') || return 1
    if [[ -n $AVALON_COMMIT && ${fetched,,} != "${AVALON_COMMIT,,}" ]]; then
        note "Fetched $fetched; expected $AVALON_COMMIT."
        return 1
    fi
    printf '%s\n' "$fetched"
}

# Check out a commit that is already in the local repository (no network).
checkout_local() {
    as_service git -C "$AVALON_DIR" checkout -q --detach "$1"
    printf 'Avalon source commit: %s\n' "$(git_root rev-parse HEAD)"
}

# build_engine: llama-server for this CT's GPU, configured and built as the
# service account inside the checkout with the distro's cmake and ninja.
build_engine() {
    local -a args
    local path_prefix rocm missing
    validate_checkout "$AVALON_DIR" || return 1
    if [[ $AVALON_BACKEND == rocm ]]; then
        rocm=$(rocm_dir)
        [[ -x $rocm/bin/amdclang++ && -x $rocm/llvm/bin/clang++ ]] ||
            { note "$rocm/bin/amdclang++ is missing; rocm-toolkit.sh should have installed ROCm $AVALON_ROCM_VERSION there."; return 1; }
        path_prefix=$rocm/bin
    else
        [[ -x $AVALON_NVCC ]] ||
            { note "$AVALON_NVCC is missing; cuda-toolkit.sh should have installed CUDA $AVALON_CUDA_VERSION there."; return 1; }
        path_prefix=${AVALON_NVCC%/*}
    fi
    mapfile -t args < <(cmake_args)
    printf '+ cmake %s\n' "${args[*]}"
    (cd "$AVALON_DIR" && as_service env "PATH=$path_prefix:/usr/local/bin:/usr/bin:/bin" ${rocm:+"ROCM_PATH=$rocm" "HIP_PATH=$rocm"} \
        "$CMAKE_BIN" "${args[@]}") || return 1
    (cd "$AVALON_DIR" && as_service env "PATH=$path_prefix:/usr/local/bin:/usr/bin:/bin" ${rocm:+"ROCM_PATH=$rocm" "HIP_PATH=$rocm"} \
        "$CMAKE_BIN" --build build --target llama-server) || return 1
    [[ -x $AVALON_DIR/build/bin/llama-server && ! -L $AVALON_DIR/build/bin/llama-server ]] ||
        { note "The build did not produce $AVALON_DIR/build/bin/llama-server."; return 1; }
    # The unit sets no library path: every library must resolve from the
    # binary's own run path or the system's.
    missing=$(as_service ldd "$AVALON_DIR/build/bin/llama-server" 2>/dev/null | awk '/not found/ { print $1 }' | paste -sd' ' -)
    [[ -z $missing ]] || { note "llama-server cannot find: $missing."; return 1; }
}

# --- weights ------------------------------------------------------------------
# hf_head URL: "<status> <X-Linked-Size> <X-Linked-Etag>" of a Hugging Face
# resolve URL, without following its redirect ("-" when absent).
hf_head() {
    curl -sS --max-time 30 --proto '=https' -I -- "$1" 2>/dev/null | tr -d '\r' | awk '
        tolower($1) ~ /^http\// { status = $2 }
        tolower($1) == "x-linked-size:" { size = $2 }
        tolower($1) == "x-linked-etag:" { etag = $2; gsub(/"/, "", etag) }
        END { printf "%s %s %s\n", status ? status : "000", size ? size : "-", etag ? tolower(etag) : "-" }'
}
# The record of weights already verified: "path hash size mtime" lines,
# root-owned, so a rerun need not hash ~90 GiB again.
verified_record() { printf '%s/verified-weights\n' "$AVALON_ETC_DIR"; }
is_verified() {
    local path=$1 hash=$2 file stat
    file=$AVALON_DATA_DIR/models/$path
    as_service test -f "$file" || return 1
    stat=$(as_service stat -c '%s %Y' -- "$file") || return 1
    grep -qxF -- "$path $hash $stat" "$(verified_record)" 2>/dev/null
}
record_weight() {
    local record temporary
    record=$(verified_record)
    temporary=$(mktemp "$record.XXXXXX")
    { grep -v -- "^$1 " "$record" 2>/dev/null || true; printf '%s\n' "$*"; } > "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$record"
}
# hash_matches FILE HASH: sha256:<hex> or git:<blob id>. Runs as the service
# account, which owns the data directory.
hash_matches() {
    local file=$1 hash=$2 actual
    case $hash in
        sha256:*) actual=sha256:$(as_service sha256sum -- "$file" | awk '{ print $1 }') ;;
        git:*) actual=git:$(as_service git hash-object --no-filters -- "$file") ;;
        *) return 1 ;;
    esac
    [[ $actual == "$hash" ]] || { note "$file has ${actual%%:*} ${actual#*:}, not ${hash#*:}."; return 1; }
}
# download URL FILE SIZE: FILE (as the service account), resuming FILE if it
# is a shorter partial download; FILE ends up exactly SIZE bytes or this fails.
download() {
    local url=$1 file=$2 size=$3 have attempt
    for attempt in 1 2 3 4 5; do
        have=$(as_service stat -c %s -- "$file" 2>/dev/null || echo 0)
        if (( have > size )); then as_service rm -f -- "$file"; have=0; fi
        (( have == size )) && return 0
        printf 'Downloading %s (%s of %s MB)...\n' "${file##*/}" "$(( have / 1048576 ))" "$(( size / 1048576 ))"
        if as_service curl -fSL --progress-bar --proto '=https' --speed-limit 65536 --speed-time 120 \
                -C "$have" -o "$file" -- "$url"; then
            continue
        fi
        if (( attempt < 5 )); then note 'The download was interrupted; resuming.'; sleep 5; fi
    done
    have=$(as_service stat -c %s -- "$file" 2>/dev/null || echo 0)
    (( have == size )) || { note "Downloading ${file##*/} failed ($have of $size bytes). Rerun install-target.sh to resume it."; return 1; }
}
# fetch_file PATH SIZE HASH URL: models/PATH, downloaded unless verified.
fetch_file() {
    local path=$1 size=$2 hash=$3 url=$4 file partial stat
    file=$AVALON_DATA_DIR/models/$path
    partial=${file%/*}/.${file##*/}.part
    is_verified "$path" "$hash" && { printf 'Have %s (verified).\n' "$path"; return 0; }
    as_service mkdir -p -- "${file%/*}"
    if as_service test -e "$file"; then
        stat=$(as_service stat -c '%s %Y' -- "$file")
        [[ ${stat%% *} == "$size" ]] || die "$file is ${stat%% *} bytes, not $size. Move it aside to download it again."
        printf 'Checking %s...\n' "$path"
        hash_matches "$file" "$hash" || die "$file does not match avalon-weights.txt. Move it aside to download it again."
        record_weight "$path" "$hash" "$stat"
        return 0
    fi
    download "$url" "$partial" "$size" || exit 1
    printf 'Checking %s...\n' "$path"
    if ! hash_matches "$partial" "$hash"; then
        as_service rm -f -- "$partial"
        die "Checksum mismatch for $path. The download was removed."
    fi
    as_service mv -f -- "$partial" "$file"
    record_weight "$path" "$hash" "$(as_service stat -c '%s %Y' -- "$file")"
    printf 'Installed %s.\n' "$path"
}

# install_weights: every file of avalon-weights.txt this install needs. Files
# not yet verified are checked against Hugging Face (status, size and SHA-256)
# and the free space is compared with what is missing before anything is
# downloaded; a fully verified set needs no network.
install_weights() {
    local rows path size hash url status linked_size etag need=0 have avail partial
    local -a plan=()
    rows=$(weight_rows "$source_dir/avalon-weights.txt") || return 1
    as_service mkdir -p -- "$AVALON_DATA_DIR/models"
    while read -r path size hash url <&3; do
        plan+=("$path $size $hash $url")
        if is_verified "$path" "$hash" || as_service test -e "$AVALON_DATA_DIR/models/$path"; then continue; fi
        read -r status linked_size etag < <(hf_head "$url")
        case $status in
            2??|3??) ;;
            *) note "$url did not answer (HTTP $status); check the CT's internet access."; return 1 ;;
        esac
        [[ $linked_size == - || $linked_size == "$size" ]] ||
            { note "${url##*/} is now $linked_size bytes upstream, not the reviewed $size. Review it and update avalon-weights.txt."; return 1; }
        if [[ $hash == sha256:* && $etag != - && $etag != "${hash#sha256:}" ]]; then
            note "Hugging Face reports SHA-256 $etag for ${url##*/}, not the reviewed ${hash#sha256:}. Review it and update avalon-weights.txt."
            return 1
        fi
        partial=$AVALON_DATA_DIR/models/$path
        partial=${partial%/*}/.${partial##*/}.part
        have=$(as_service stat -c %s -- "$partial" 2>/dev/null || echo 0)
        (( have <= size )) || have=0
        need=$(( need + size - have ))
    done 3<<< "$rows"
    if (( need > 0 )); then
        avail=$(df -PB1 -- "$AVALON_DATA_DIR/models" | awk 'NR == 2 { print $4 }')
        [[ $avail =~ ^[0-9]+$ ]] || { note "Cannot read the free space of $AVALON_DATA_DIR/models."; return 1; }
        # Keep 1 GiB spare.
        if (( avail < need + 1073741824 )); then
            note "The weights need $(( (need + 1073741823) / 1073741824 )) GiB more, plus 1 GiB of room, but $AVALON_DATA_DIR has $(( avail / 1073741824 )) GiB free."
            note "Grow the CT's disk (pct resize <CT_ID> rootfs +<N>G on the PVE host) and rerun."
            return 1
        fi
    fi
    local entry epath esize ehash eurl
    for entry in "${plan[@]}"; do
        read -r epath esize ehash eurl <<< "$entry"
        fetch_file "$epath" "$esize" "$ehash" "$eurl"
    done
    printf 'The Qwen3.8-Flash-Next Avalon weights are installed.\n'
}

# Serialize real runs before reading saved settings. Keep the descriptor open
# for the entire installer; never unlink the lock file while another run may
# be waiting on its inode. Dry runs do not write or take the lock.
acquire_install_lock() {
    (( dry_run )) && return 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Avalon LXC.'
    [[ $AVALON_ETC_DIR =~ ^/[A-Za-z0-9._/-]+$ && $AVALON_ETC_DIR != *..* ]] || die 'Invalid AVALON_ETC_DIR.'
    local previous_umask lock_directory
    lock_directory=$(realpath -m -- "$AVALON_ETC_DIR") || return 1
    previous_umask=$(umask)
    umask 077
    exec {install_lock_fd}>>"$lock_directory.lock"
    umask "$previous_umask"
    flock -n "$install_lock_fd" || die 'Another Avalon installer is already running (or a process it started still holds the lock).'
}

# A rename is durable only after its containing directory has been flushed.
# In save_settings this also orders settings publication before the fingerprint.
publish_record() {
    local temporary=$1 destination=$2
    mv -fT -- "$temporary" "$destination" || return 1
    sync -- "${destination%/*}"
}

# Stage a complete, private record beside its destination. Only rename it
# after the writer succeeds, so a failed write cannot truncate a good record.
stage_record() {
    local destination=$1 temporary
    shift
    # A run killed while staging leaves its mktemp file behind (an api-key one
    # holds the key); drop such leftovers before staging a new one.
    rm -f -- "$destination".?????? || return 1
    temporary=$(mktemp "$destination.XXXXXX") || return 1
    # Flush the contents before the caller renames the file into place, so a
    # power loss cannot leave the new name pointing at an empty file.
    if ! "$@" > "$temporary" || ! sync -- "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    printf '%s\n' "$temporary"
}

# write_pending: record the settings a fresh (or resumed) install runs with
# before it changes anything, so an interrupted first install resumes with
# them instead of the defaults. save_settings removes it.
write_pending() {
    (( dry_run )) && return 0
    install -d -m 0700 "$AVALON_ETC_DIR"
    # Persist a newly created record directory before relying on its checkpoint.
    sync -- "$AVALON_ETC_DIR/.." || return 1
    local temporary
    temporary=$(stage_record "$AVALON_ETC_DIR/pending-env" settings_env) || return 1
    if ! publish_record "$temporary" "$AVALON_ETC_DIR/pending-env"; then
        rm -f -- "$temporary"
        return 1
    fi
}

save_settings() {
    local fingerprint_temporary env_temporary
    fingerprint_temporary=$(stage_record "$AVALON_ETC_DIR/installed-settings" settings_fingerprint) || return 1
    if ! env_temporary=$(stage_record "$AVALON_ETC_DIR/installed-env" settings_env); then
        rm -f -- "$fingerprint_temporary"
        return 1
    fi
    # Prepare both records before publishing either. Each rename publishes a
    # complete record. installed-env (the settings every rerun starts from) goes
    # first and the fingerprint (the "nothing to do" marker) last: interrupted
    # between the two, the next run has the new settings and an old marker, so
    # it re-applies them once instead of reverting to the previous settings.
    if ! publish_record "$env_temporary" "$AVALON_ETC_DIR/installed-env" ||
        ! publish_record "$fingerprint_temporary" "$AVALON_ETC_DIR/installed-settings"; then
        rm -f -- "$fingerprint_temporary" "$env_temporary"
        return 1
    fi
    rm -f -- "$AVALON_ETC_DIR/pending-env" || return 1
    sync -- "$AVALON_ETC_DIR"
}

ensure_api_key() {
    install -d -m 0700 "$AVALON_ETC_DIR"
    # A key write killed mid-way leaves its staging file (holding a key) even
    # when a key is in place by now; never keep such copies around.
    rm -f -- "$AVALON_ETC_DIR/api-key".?????? || return 1
    if [[ ! -s $AVALON_ETC_DIR/api-key ]]; then
        local temporary
        temporary=$(stage_record "$AVALON_ETC_DIR/api-key" openssl rand -hex 32) || return 1
        if ! publish_record "$temporary" "$AVALON_ETC_DIR/api-key"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    chmod 0600 "$AVALON_ETC_DIR/api-key"
    sync -- "$AVALON_ETC_DIR/api-key" "$AVALON_ETC_DIR" || return 1
    api_key=$(< "$AVALON_ETC_DIR/api-key")
}


# The installed key copy, environment and unit are what this run would write?
config_current() {
    [[ -f $(key_file) && $(< "$(key_file)") == "$api_key" ]] &&
        [[ -f $AVALON_ETC_DIR/avalon.env && $(start_env) == "$(< "$AVALON_ETC_DIR/avalon.env")" ]]
}

# Unchanged since the last successful install or upgrade, and serving?
nothing_to_do() {
    [[ -f $AVALON_ETC_DIR/installed-settings ]] &&
        [[ $(settings_fingerprint) == "$(< "$AVALON_ETC_DIR/installed-settings")" ]] &&
        config_current &&
        cmp -s "$source_dir/avalon.service" "$UNIT_DIR/avalon.service" &&
        systemctl is-active --quiet avalon.service &&
        probe_health
}

# write_unit: the server's key file (root and the avalon group may read it,
# nobody may change it but root), the unit's environment and the unit.
write_unit() {
    local temporary
    install -d -o root -g "$SERVICE_USER" -m 0750 "$AVALON_CONFIG_DIR"
    temporary=$(stage_record "$(key_file)" printf '%s\n' "$api_key") || return 1
    chgrp "$SERVICE_USER" "$temporary" && chmod 0640 "$temporary" || { rm -f -- "$temporary"; return 1; }
    publish_record "$temporary" "$(key_file)" || { rm -f -- "$temporary"; return 1; }
    start_env > "$AVALON_ETC_DIR/avalon.env"
    chmod 0644 "$AVALON_ETC_DIR/avalon.env"
    install -m 0644 "$source_dir/avalon.service" "$UNIT_DIR/avalon.service"
    systemctl daemon-reload
}

# /health answers 503 while the model loads and 200 once it serves; then
# /v1/models (with the key) must list the model id.
probe_health() {
    curl -fsS --max-time 5 "http://127.0.0.1:${AVALON_PORT}/health" 2>/dev/null |
        python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("status") == "ok" else 1)' \
            >/dev/null 2>&1 &&
    curl -fsS --max-time 5 -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
        "http://127.0.0.1:${AVALON_PORT}/v1/models" 2>/dev/null |
        AC_NAME=$AVALON_MODEL_NAME python3 -c 'import json,os,sys; ids=[m.get("id") for m in json.load(sys.stdin).get("data") or []]; sys.exit(0 if os.environ["AC_NAME"] in ids else 1)' \
            >/dev/null 2>&1
}

wait_ready() {
    local deadline=$(( SECONDS + AVALON_READY_TIMEOUT ))
    while (( SECONDS < deadline )); do
        probe_health && return 0
        if systemctl is-failed --quiet avalon.service; then
            note "avalon.service failed; see journalctl -u avalon."
            return 1
        fi
        sleep 5
    done
    note "Avalon has not answered on port $AVALON_PORT within ${AVALON_READY_TIMEOUT}s; see journalctl -u avalon."
    return 1
}

ensure_service_user() {
    local node group
    getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
    id -u "$SERVICE_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$SERVICE_USER" --home-dir "$AVALON_DATA_DIR" \
            --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    # GPU access: join the group that owns each passed-through node. Root's
    # group is refused: membership in it would grant far more than the GPU.
    # shellcheck disable=SC2086  # GPU_NODES is a glob list by design
    for node in $GPU_NODES; do
        [[ -e $node ]] || continue
        group=$(stat -c %G "$node")
        [[ $group != root ]] ||
            die "$node belongs to group root inside the CT. On the PVE host give the device a non-root group, e.g. pct set <CT_ID> --devN path=$node,gid=44,mode=0660 (44 is \"video\"), restart the CT and run this again."
        usermod -aG "$group" "$SERVICE_USER"
    done
}


# install_toolkit: ROCm or the CUDA toolkit (user space only) for the backend.
install_toolkit() {
    if [[ $AVALON_BACKEND == rocm ]]; then
        if (( dry_run )); then
            printf '+ bash rocm-toolkit.sh (ROCm %s from repo.radeon.com: hip-dev hipblas-dev rocblas-dev rocm-device-libs rocminfo)\n' "$AVALON_ROCM_VERSION"
            return 0
        fi
        ROCM_VERSION="$AVALON_ROCM_VERSION" ROCM_DIR="$(rocm_dir)" bash "$source_dir/rocm-toolkit.sh"
    else
        if (( dry_run )); then
            printf '+ bash cuda-toolkit.sh (CUDA %s toolkit, user space only)\n' "$AVALON_CUDA_VERSION"
            return 0
        fi
        CUDA_VERSION="$AVALON_CUDA_VERSION" CUDA_NVCC="$AVALON_NVCC" bash "$source_dir/cuda-toolkit.sh"
    fi
}

do_install() {
    # A complete installation uses the upgrade path on a normal rerun too, so
    # the service is stopped and the previous commit can be restored on failure.
    if [[ -d $AVALON_DIR/.git && -f $UNIT_DIR/avalon.service ]]; then
        do_upgrade
        return
    fi
    write_pending
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl python3 build-essential cmake ninja-build
    install_toolkit
    if (( dry_run )); then
        printf '+ create the %s service account; add it to the groups of %s\n' "$SERVICE_USER" "$GPU_NODES"
        printf '+ git fetch --depth 1 %s %s into %s (as %s)\n' "$AVALON_URL" "$(fetch_spec)" "$AVALON_DIR" "$SERVICE_USER"
        printf '+ check the checkout: required files, CMake options and llama-server flags\n'
        printf '+ cmake %s\n' "$(cmake_args | tr '\n' ' ' | sed -e 's/TARGETS=auto /TARGETS=<the card'\''s gfx target> /' \
            -e 's/ARCHITECTURES=auto /ARCHITECTURES=<GPU 0 compute capability> /')"
        printf '+ cmake --build build --target llama-server\n'
        printf '+ download and verify avalon-weights.txt into %s/models (about 90 GiB)\n' "$AVALON_DATA_DIR"
        printf '+ write %s (the key [redacted], root:%s 0640), %s/avalon.env and %s/avalon.service\n' "$(key_file)" "$SERVICE_USER" "$AVALON_ETC_DIR" "$UNIT_DIR"
        run systemctl enable avalon.service
        run systemctl restart avalon.service
        printf '+ wait for /health and /v1/models to list %s (up to %ss)\n' "$AVALON_MODEL_NAME" "$AVALON_READY_TIMEOUT"
        return 0
    fi
    ensure_api_key
    ensure_service_user
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$AVALON_DATA_DIR"
    if [[ -d $AVALON_DIR/.git ]]; then
        verify_source_origin
        chown -R "$SERVICE_USER:$SERVICE_USER" "$AVALON_DIR"
        printf 'Resuming the incomplete Avalon checkout at %s.\n' "$AVALON_DIR"
    else
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$AVALON_DIR"
    fi
    local target
    target=$(fetch_target) || die "Could not fetch $AVALON_URL $(fetch_spec)."
    checkout_local "$target"
    # llama-server is built before the long download, so a checkout that does
    # not build fails in minutes rather than after hours.
    build_engine || die 'Building Avalon'\''s llama-server failed (see above).'
    install_weights || die 'Installing the weights failed (see above); rerun to resume.'
    write_unit
    systemctl enable avalon.service
    systemctl restart avalon.service
    wait_ready || die 'Avalon did not become ready.'
    save_settings
}

# Check out COMMIT (already local) and bring the service up on it. Runs in a
# subshell with errexit, so any failure returns non-zero to the caller.
apply_checkout() {
    set -e
    checkout_local "$1"
    build_engine
    write_unit
    systemctl restart avalon.service
    wait_ready
}

# Keep a complete runnable checkout (venv, llama.cpp, engine build) at its
# original absolute path on rollback, with the unit, its environment and the
# server config. Models in the data directory are not copied. Stop the service
# before taking this snapshot so it forms one consistent state.
snapshot_runtime() {
    install -d -m 0700 "$AVALON_STATE_DIR"
    (umask 077
     tar -C "$AVALON_DIR" --exclude='./.git' -cpf "$AVALON_STATE_DIR/rollback-runtime.tar.new" . &&
     mv -f -- "$AVALON_STATE_DIR/rollback-runtime.tar.new" "$AVALON_STATE_DIR/rollback-runtime.tar") || {
        rm -f -- "$AVALON_STATE_DIR/rollback-runtime.tar.new"
        return 1
    }
    cp -p -- "$UNIT_DIR/avalon.service" "$AVALON_STATE_DIR/rollback.service" || return 1
    cp -p -- "$AVALON_ETC_DIR/avalon.env" "$AVALON_STATE_DIR/rollback.env" || return 1
    cp -p -- "$(key_file)" "$AVALON_STATE_DIR/rollback.key"
}

# clear_snapshot: drop the snapshot once it is no longer needed (after a
# successful upgrade or rollback). A failed rollback keeps it for inspection.
clear_snapshot() {
    rm -f -- "$AVALON_STATE_DIR/rollback-runtime.tar" "$AVALON_STATE_DIR/rollback-runtime.tar.new" \
        "$AVALON_STATE_DIR/rollback.service" "$AVALON_STATE_DIR/rollback.env" "$AVALON_STATE_DIR/rollback.key"
}

# restore_probe_settings: the port and model id from the fingerprint, for
# installs whose installed-env is missing.
restore_probe_settings() {
    local port name
    port=$(sed -n 's/^port=//p' "$AVALON_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then AVALON_PORT=$port; fi
    name=$(sed -n 's/^model_name=//p' "$AVALON_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $name =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; then AVALON_MODEL_NAME=$name; fi
}

# No build, pip, compiler or download is invoked on this path. The caller has
# set the settings the previous runtime ran with (wait_ready uses its port).
restore_runtime() {
    set -e
    [[ $AVALON_DIR != / && -d $AVALON_DIR/.git && -s $AVALON_STATE_DIR/rollback-runtime.tar ]]
    as_service git -C "$AVALON_DIR" reset -q --hard "$1"
    find "$AVALON_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    tar -C "$AVALON_DIR" -xpf "$AVALON_STATE_DIR/rollback-runtime.tar"
    install -m 0644 "$AVALON_STATE_DIR/rollback.service" "$UNIT_DIR/avalon.service"
    cp -p -- "$AVALON_STATE_DIR/rollback.env" "$AVALON_ETC_DIR/avalon.env"
    cp -p -- "$AVALON_STATE_DIR/rollback.key" "$(key_file)"
    systemctl daemon-reload
    systemctl restart avalon.service
    wait_ready
}

do_upgrade() {
    if (( dry_run )); then
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$AVALON_URL" "$(fetch_spec)"
        printf '+ verify (or resume downloading) the weights while the service keeps running\n'
        printf '+ same commit, settings, config and unit, and /health loaded: nothing to do\n'
        printf '+ otherwise: record the current commit; systemctl stop avalon.service; snapshot; checkout; rebuild llama-server; restart; wait for /health and /v1/models\n'
        printf '+ on failure: check out the previous commit locally (no network) and restore its runnable checkout, unit, environment and config without building or downloading (%s/rollback-runtime.tar, removed afterwards)\n' "$AVALON_STATE_DIR"
        return 0
    fi
    [[ -d $AVALON_DIR/.git && -f $UNIT_DIR/avalon.service ]] ||
        die "No Avalon installation at $AVALON_DIR; run without --upgrade first."
    verify_source_origin
    install_toolkit
    ensure_api_key
    ensure_service_user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$AVALON_DIR"
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$AVALON_DIR" update-ref refs/avalon/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $AVALON_URL $(fetch_spec); Avalon was not stopped or changed."
    install_weights ||
        die "The weights could not be verified or completed; Avalon was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        # A matching fingerprint without installed-env migrates its records.
        if [[ ! -f $AVALON_ETC_DIR/installed-env ]]; then
            save_settings
        fi
        printf 'Avalon is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        return 0
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying Avalon %s (settings, config, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading Avalon from %s to %s.\n' "$previous" "$target"
    fi
    upgrade_guard on
    systemctl stop avalon.service
    if ! snapshot_runtime; then
        note 'Could not snapshot the previous runtime; no upgrade was applied.'
        (load_settings "$AVALON_ETC_DIR/installed-env" || restore_probe_settings
         systemctl restart avalon.service; wait_ready) ||
            die 'Snapshot failed and the previous service did not become ready.'
        die 'Runtime snapshot failed; the previous service is running again.'
    fi
    set +e
    ( apply_checkout "$target" )
    rc=$?
    set -e
    if (( rc == 0 )); then
        save_settings
        clear_snapshot
        printf 'Avalon is running %s.\n' "$(git_root rev-parse HEAD)"
        upgrade_guard off
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    upgrade_guard rollback
    systemctl stop avalon.service || true
    # The settings the previous runtime ran with: the record of the last good
    # install (the fingerprint's port and model id otherwise). wait_ready
    # checks the restored service on that port.
    if load_settings "$AVALON_ETC_DIR/installed-env"; then
        note "Restoring the settings it last ran with: $(settings_env | tr '\n' ' ')"
    else
        restore_probe_settings
        note 'No record of the previous settings; restoring the complete runtime snapshot.'
    fi
    set +e
    ( restore_runtime "$previous" )
    rc=$?
    set -e
    if (( rc != 0 )); then
        : > "$AVALON_STATE_DIR/rollback-failed" || true
        die "Rollback to $previous failed too; inspect journalctl -u avalon and $AVALON_DIR; the snapshot is kept in $AVALON_STATE_DIR."
    fi
    clear_snapshot
    die "Upgrade failed; Avalon is running $previous again."
}


dry_run=0
mode=install
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        --upgrade) mode=upgrade ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
acquire_install_lock
saved_settings
# A failed rollback keeps the last good runtime in $AVALON_STATE_DIR; an upgrade
# would snapshot over it and an unchanged run would hide it, so stop until
# someone has looked (see the README).
if (( ! dry_run )) && [[ -e $AVALON_STATE_DIR/rollback-failed ]]; then
    die "A rollback failed earlier; the previous runtime is kept in $AVALON_STATE_DIR. Inspect or restore it, then delete $AVALON_STATE_DIR/rollback-failed and rerun."
fi
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/upstream-commit.txt ]] || die "Missing $source_dir/upstream-commit.txt"
default_commit=$(< "$source_dir/upstream-commit.txt")
[[ $default_commit =~ ^[0-9a-f]{40}$ ]] || die 'Invalid upstream-commit.txt.'
if [[ -z ${AVALON_REF:-} && -z ${AVALON_COMMIT:-} ]]; then AVALON_COMMIT=$default_commit; fi
AVALON_REF=${AVALON_REF:-main}
AVALON_COMMIT=${AVALON_COMMIT:-}
# auto: ROCm when the CT has the AMD compute node, else CUDA.
AVALON_BACKEND=${AVALON_BACKEND:-auto}
if [[ $AVALON_BACKEND == auto ]]; then
    if [[ -e ${AVALON_KFD:-/dev/kfd} ]] || (( dry_run )); then AVALON_BACKEND=rocm; else AVALON_BACKEND=cuda; fi
fi
AVALON_ROCM_VERSION=${AVALON_ROCM_VERSION:-7.2.4}
AVALON_GPU_TARGET=${AVALON_GPU_TARGET:-auto}
AVALON_CUDA_VERSION=${AVALON_CUDA_VERSION:-12.9}
AVALON_NVCC=${AVALON_NVCC:-/usr/local/cuda-$AVALON_CUDA_VERSION/bin/nvcc}
AVALON_CUDA_ARCH=${AVALON_CUDA_ARCH:-auto}
AVALON_PORT=${AVALON_PORT:-8080}
AVALON_CONTEXT=${AVALON_CONTEXT:-65536}
AVALON_MTP=${AVALON_MTP:-true}
AVALON_MODEL_NAME=${AVALON_MODEL_NAME:-qwen3.8-flash-next-avalon}
AVALON_READY_TIMEOUT=${AVALON_READY_TIMEOUT:-1800}
[[ $AVALON_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $AVALON_REF != HEAD && $AVALON_REF != *..* ]] || die 'Invalid AVALON_REF.'
[[ -z $AVALON_COMMIT || $AVALON_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'Invalid AVALON_COMMIT.'
validate_settings
[[ $AVALON_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid AVALON_READY_TIMEOUT.'
for path_var in AVALON_DIR AVALON_DATA_DIR AVALON_ETC_DIR AVALON_CONFIG_DIR AVALON_STATE_DIR UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SERVICE_USER.'
if [[ -z $GPU_NODES ]]; then
    if [[ $AVALON_BACKEND == rocm ]]; then GPU_NODES="${AVALON_KFD:-/dev/kfd} $DEV_DRI/renderD*"
    else GPU_NODES='/dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm'; fi
fi

for file in avalon.service rocm-toolkit.sh cuda-toolkit.sh avalon-weights.txt upstream-commit.txt; do
    [[ -r $source_dir/$file ]] || die "Missing $source_dir/$file"
done
weight_rows "$source_dir/avalon-weights.txt" >/dev/null || exit 1
# Every path below is absolute. The service account runs commands from here,
# not from the root-only deploy directory the installer was started in.
cd /
api_key='[generated inside CT]'
if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Avalon LXC.'
    if [[ -e $AVALON_DIR && ! -d $AVALON_DIR/.git ]] && [[ -n $(ls -A "$AVALON_DIR" 2>/dev/null) ]]; then
        die "$AVALON_DIR exists but is not a Git checkout; inspect it before continuing."
    fi
    # The experts computed on the CPU use AVX2 kernels.
    grep -qw avx2 "$CPUINFO" 2>/dev/null ||
        die "This CPU has no AVX2; Avalon computes the experts that are not on the GPU with AVX2 kernels."
    # Before anything is installed or stopped: is the toolkit already
    # installed, or can this distro's repository provide it?
    if [[ $AVALON_BACKEND == rocm ]]; then
        ROCM_VERSION="$AVALON_ROCM_VERSION" ROCM_DIR="$(rocm_dir)" bash "$source_dir/rocm-toolkit.sh" --check ||
            die "ROCm $AVALON_ROCM_VERSION is not available for this CT's distribution (see above)."
        [[ -c ${AVALON_KFD:-/dev/kfd} || -e ${AVALON_KFD:-/dev/kfd} ]] ||
            die '/dev/kfd is missing: pass it and the card'\''s render node into the CT (provision-lxc.sh does).'
        mapfile -t nodes < <(amd_render_nodes)
        (( ${#nodes[@]} > 0 )) ||
            die "No AMD render node in $DEV_DRI: pass the card's /dev/dri/renderD<n> into the CT."
        (( ${#nodes[@]} == 1 )) ||
            note "Several AMD render nodes are passed in; Avalon uses the first, ${nodes[0]%% *} (its multi-GPU mode is experimental upstream)."
        read -r _ pci_device _ <<< "${nodes[0]}"
        if [[ $AVALON_GPU_TARGET == auto ]]; then
            AVALON_GPU_TARGET=$(gfx_of_pci_device "$pci_device")
            [[ -n $AVALON_GPU_TARGET ]] ||
                die "The AMD card ($pci_device) is not RDNA 3 (Radeon RX 7000 / PRO W7000); Avalon's HIP kernels target gfx1100, gfx1101 and gfx1102."
            note "The AMD card is $AVALON_GPU_TARGET."
        fi
        [[ $AVALON_GPU_TARGET == gfx1100 ]] ||
            note "Avalon is tuned and measured on gfx1100 (RX 7900 XT / XTX); $AVALON_GPU_TARGET should work but is not measured upstream."
        vram_mib=$(gpu_vram_mib) ||
            die 'Cannot read the AMD card'\''s VRAM (mem_info_vram_total); check the passed-through render node before installing weights.'
    else
        CUDA_VERSION="$AVALON_CUDA_VERSION" CUDA_NVCC="$AVALON_NVCC" bash "$source_dir/cuda-toolkit.sh" --check ||
            die "CUDA $AVALON_CUDA_VERSION is not available for this CT's distribution (see above)."
        command -v nvidia-smi >/dev/null || die 'nvidia-smi is missing; install host-matched guest NVIDIA userspace first.'
        nvidia-smi -L || die 'NVIDIA GPU is not accessible inside the CT.'
        vram_mib=$(gpu_vram_mib) ||
            die 'Cannot read GPU 0 VRAM with nvidia-smi; check the passed-through GPU before installing weights.'
        if [[ $AVALON_CUDA_ARCH == auto ]]; then
            AVALON_CUDA_ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader -i 0 | compute_cap_arch) ||
                die 'Cannot read GPU 0'\''s compute capability; set AVALON_CUDA_ARCH (e.g. 89 for an RTX 40 card).'
            note "GPU 0 has compute capability $AVALON_CUDA_ARCH."
        fi
        (( AVALON_CUDA_ARCH >= 75 )) ||
            die "GPU 0 has compute capability $AVALON_CUDA_ARCH; Avalon's CUDA build needs 7.5 or newer (RTX 20 series and later)."
        if (( AVALON_CUDA_ARCH >= 120 )) && [[ $AVALON_CUDA_VERSION =~ ^12\.[4-7]$ ]]; then
            die "Compute capability $AVALON_CUDA_ARCH (RTX 50) needs AVALON_CUDA_VERSION=12.8 or newer, not $AVALON_CUDA_VERSION."
        fi
    fi
    (( vram_mib >= 16000 )) ||
        die "The GPU has ${vram_mib} MiB VRAM; Avalon needs a 16 GB card or larger (upstream: 20 GB for the full context). No weights were downloaded."
    if [[ $AVALON_CONTEXT == auto ]]; then
        AVALON_CONTEXT=$(context_for_vram "$vram_mib")
        note "The GPU has $vram_mib MiB of VRAM: context $AVALON_CONTEXT tokens."
    fi
    # The model is memory-mapped; upstream measured it down to a 28 GB cap.
    mem_kib=$(awk '$1 == "MemTotal:" { print $2 }' "$MEMINFO" 2>/dev/null || true)
    if [[ $mem_kib =~ ^[0-9]+$ ]] && (( mem_kib / 1048576 < 28 )); then
        die "The CT has $(( mem_kib / 1048576 )) GiB of RAM; Avalon is measured with 32 GB or more (the ~90 GiB model is memory-mapped). Raise the CT's memory."
    fi
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'Avalon is configured on TCP %s (model %s); API key: %s/api-key\n' "$AVALON_PORT" "$AVALON_MODEL_NAME" "$AVALON_ETC_DIR"
