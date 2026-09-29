#!/usr/bin/env bash
# Run INSIDE a dedicated Debian 12 inference-target LXC, never on the router or PVE host.
set -Eeuo pipefail
umask 027

# Official release reviewed for Debian 12 / CUDA 13.0 / SM 86, 89 and 120.
# https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0
# Release commit: 7fe450e19305b828c199d602c23a8337aaa1f03b
# Keep this fixed until a newer release has been reviewed; never resolve "latest".
readonly LLAMA_CPP_DEFAULT_REF=v0.5.0
LLAMA_CPP_REF=${LLAMA_CPP_REF:-$LLAMA_CPP_DEFAULT_REF}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<USAGE
Usage: bash install-target.sh                 # prompt for model and storage
       MODEL_ALIAS=<name:tag> \\
       MODEL_PATH=/var/lib/llama-target/models/model.gguf bash install-target.sh
       MODEL_ALIAS=<name:tag> \\
       MODEL_DOWNLOAD_URL=https://huggingface.co/org/repo/resolve/revision/model.gguf bash install-target.sh

Without --upgrade: fresh installations only. Missing model settings are prompted on a terminal.
MODEL_ALIAS accepts a model name or name:tag (a bare name gets :latest).
Set MODEL_PATH, or MODEL_DIR plus MODEL_FILE, to skip the storage prompts.
MODEL_DIR defaults to /var/lib/llama-target/models; MODEL_FILE is a GGUF basename.
MODEL_DOWNLOAD_URL optionally fetches one public GGUF from a direct
https://huggingface.co/<org>/<repo>/resolve/<revision>/<file>.gguf URL.
NONINTERACTIVE=true disables prompts and requires MODEL_ALIAS plus a GGUF file
setting or a valid MODEL_DOWNLOAD_URL.
Optional: LLAMA_CPP_REF=<release-tag-or-full-commit> ($LLAMA_CPP_DEFAULT_REF),
          BACKEND=cuda|cpu (cuda), BUILD_JOBS=4, CONTEXT_SIZE=8192,
          PARALLEL_SLOTS=1, THREADS=4, GPU_LAYERS=auto (0 for cpu),
          MODEL_PARAMETER_SIZE=unknown, MODEL_FAMILY=unknown,
          MODEL_QUANTIZATION=unknown, MODEL_CAPABILITIES=completion,
          CUDA_ARCHITECTURES=native (or 86;89;120), CUDA_COMPILER=<nvcc-path>
          (auto-detected when unset), LLAMA_EXTRA_ARGS="<extra llama-server flags>".

Upgrade an installed target in place (same model and settings):
       LLAMA_CPP_REF=<tag-or-commit> bash install-target.sh --upgrade
Rebuilds llama.cpp only when the ref resolves to a different commit
(FORCE_REBUILD=true to force), always refreshes bridge.py, its venv and the
units, restarts services that were running and waits for them to be healthy.
Everything replaced is kept as *.prev and restored if the upgrade fails.

CUDA requires host-matched userspace driver libraries inside the CT, with GPU
devices passed through. If nvcc is missing, the CUDA 13.0 toolkit is installed
from NVIDIA's Debian 12 repository. No NVIDIA drivers are installed.
Services are enabled but are NOT started by this script.
USAGE
}

# Model configuration helpers (no filesystem mutations).
valid_model_alias() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*(:[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]
}
valid_model_dir() {
    local resolved
    [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != *'/../'* && $1 != */.. && $1 != *'/./'* && $1 != */. ]] || return 1
    resolved=$(realpath -m -- "$1") || return 1
    [[ $resolved =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    # Both services hide home and temporary directories with systemd sandboxing.
    case "$resolved" in
        /|/root|/root/*|/home|/home/*|/run/user|/run/user/*|/tmp|/tmp/*|/var/tmp|/var/tmp/*) return 1 ;;
    esac
}
valid_model_file() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*\.gguf$ ]]
}
valid_huggingface_gguf_url() {
    local url=$1 path
    [[ $url != *[[:space:]]* && $url != *'#'* ]] || return 1
    path=${url%%\?*}
    [[ $path != *'/../'* && $path != */.. && $path != *'/./'* && $path != */. ]] || return 1
    [[ $url =~ ^https://huggingface\.co/[^/?#]+/[^/?#]+/resolve/[^?#]+\.gguf(\?[^#[:space:]]*)?$ ]]
}
huggingface_gguf_filename() {
    local path filename
    valid_huggingface_gguf_url "$1" || return 1
    path=${1%%\?*}
    filename=${path##*/}
    valid_model_file "$filename" || return 1
    printf '%s\n' "$filename"
}
model_prompt_available() {
    [[ $NONINTERACTIVE == false && -t 0 ]]
}
prompt_model_setting() {
    local name=$1 label=$2 default=$3 validator=$4 guidance=$5 value
    if [[ -n ${!name:-} ]]; then
        "$validator" "${!name}" || die "$name: $guidance"
        return
    fi
    if ! model_prompt_available; then
        [[ -n $default ]] || die "Set $name for unattended installation, or run interactively in the target CT."
        value=$default
        "$validator" "$value" || die "$name: $guidance"
        printf -v "$name" '%s' "$value"
        return
    fi
    while true; do
        printf '%s' "$label" >&2
        [[ -z $default ]] || printf ' [%s]' "$default" >&2
        printf ': ' >&2
        IFS= read -r value || die "Input ended while reading $name."
        value=${value:-$default}
        if "$validator" "$value"; then
            printf -v "$name" '%s' "$value"
            return
        fi
        printf '%s\n' "$guidance" >&2
    done
}
prompt_optional_model_setting() {
    local name=$1 label=$2 validator=$3 guidance=$4 value
    if [[ -v $name ]]; then
        value=${!name}
        [[ -z $value ]] || "$validator" "$value" || die "$name: $guidance"
        return
    fi
    if ! model_prompt_available; then
        printf -v "$name" '%s' ''
        return
    fi
    while true; do
        printf '%s (leave blank to skip): ' "$label" >&2
        IFS= read -r value || die "Input ended while reading $name."
        if [[ -z $value ]] || "$validator" "$value"; then
            printf -v "$name" '%s' "$value"
            return
        fi
        printf '%s\n' "$guidance" >&2
    done
}
list_model_storage_volumes() {
    local target source fstype options resolved candidate
    command -v findmnt >/dev/null 2>&1 || return 0
    while read -r target source fstype options; do
        [[ -n $target && -n $source && -n $fstype && -n $options ]] || continue
        case ",$options," in *,ro,*) continue ;; esac
        case "$fstype" in
            autofs|cgroup|cgroup2|configfs|debugfs|devpts|devtmpfs|fusectl|mqueue|nsfs|proc|pstore|rpc_pipefs|securityfs|sysfs|tmpfs|tracefs) continue ;;
        esac
        resolved=$(realpath -m -- "$target") || continue
        [[ $resolved != / ]] || continue
        case "$resolved" in /dev|/dev/*|/proc|/proc/*|/run|/run/*|/sys|/sys/*) continue ;; esac
        valid_model_dir "$resolved" || continue
        case "$resolved" in /var/lib/llama-target|/var/lib/llama-target/*) continue ;; esac
        candidate=$(realpath -m -- "$resolved/llama-target/models") || continue
        [[ $candidate != /var/lib/llama-target/models ]] || continue
        printf '%s\t%s on %s (%s)\n' "$resolved" "$resolved" "$source" "$fstype"
    done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)
}
select_model_storage() {
    local default_dir=/var/lib/llama-target/models choice selection directory label
    local -a mountpoints=() labels=()
    [[ -z ${MODEL_PATH:-} && -z ${MODEL_DIR:-} ]] || return 0
    if ! model_prompt_available; then
        MODEL_DIR=$default_dir
        return
    fi
    while IFS=$'\t' read -r directory label; do
        [[ -n $directory && -n $label ]] || continue
        mountpoints+=("$directory")
        labels+=("$label")
    done < <(list_model_storage_volumes)
    printf '\nModel storage volumes visible in this container:\n' >&2
    printf '  1) %s (default model store)\n' "$default_dir" >&2
    for selection in "${!mountpoints[@]}"; do
        printf '  %s) %s\n' "$((selection + 2))" "${labels[selection]}" >&2
    done
    printf '  m) Enter a directory manually\n' >&2
    while true; do
        printf 'Select model storage [1]: ' >&2
        IFS= read -r choice || die 'Input ended while selecting model storage.'
        choice=${choice:-1}
        case "$choice" in
            m|M)
                prompt_model_setting MODEL_DIR 'Directory containing or storing GGUF models' '' valid_model_dir \
                    'Use an absolute model directory without spaces or traversal components, outside home and temporary directories.'
                return
                ;;
            *)
                if [[ $choice =~ ^[1-9][0-9]*$ ]]; then
                    selection=$((10#$choice))
                    if (( selection == 1 )); then
                        MODEL_DIR=$default_dir
                        return
                    fi
                    if (( selection >= 2 && selection < ${#mountpoints[@]} + 2 )); then
                        MODEL_DIR=$(realpath -m -- "${mountpoints[selection - 2]}/llama-target/models")
                        valid_model_dir "$MODEL_DIR" || die 'Selected model storage resolves to an unsafe directory.'
                        return
                    fi
                fi
                printf 'Choose a displayed number or m for a custom directory.\n' >&2
                ;;
        esac
    done
}
configure_model() {
    NONINTERACTIVE=${NONINTERACTIVE:-false}
    [[ $NONINTERACTIVE == true || $NONINTERACTIVE == false ]] || die 'NONINTERACTIVE must be true or false.'
    MODEL_ALIAS=${MODEL_ALIAS:-}
    MODEL_DIR=${MODEL_DIR:-}
    MODEL_FILE=${MODEL_FILE:-}
    MODEL_PATH=${MODEL_PATH:-}
    prompt_model_setting MODEL_ALIAS 'Model name or API tag (e.g. qwen3:8b)' '' valid_model_alias \
        'Enter a model name or name:tag using letters, numbers, dots, underscores, hyphens or namespace slashes.'
    [[ $MODEL_ALIAS == *:* ]] || MODEL_ALIAS+=:latest
    local directory_guidance='Use an absolute model directory without spaces or traversal components, outside home and temporary directories.'
    local file_default='' candidate download_filename=''
    prompt_optional_model_setting MODEL_DOWNLOAD_URL 'Hugging Face GGUF download URL' valid_huggingface_gguf_url \
        'Use a direct HTTPS huggingface.co/<org>/<repo>/resolve/<revision>/<file>.gguf URL, or leave it blank.'
    if [[ -n $MODEL_DOWNLOAD_URL ]]; then
        download_filename=$(huggingface_gguf_filename "$MODEL_DOWNLOAD_URL") || die 'MODEL_DOWNLOAD_URL must end with a supported .gguf filename.'
    fi
    if [[ -n $MODEL_PATH ]]; then
        [[ $MODEL_PATH == /* && $MODEL_PATH != */ ]] || die 'MODEL_PATH must be an absolute GGUF filename.'
        valid_model_dir "${MODEL_PATH%/*}" || die "MODEL_PATH: $directory_guidance"
        valid_model_file "${MODEL_PATH##*/}" || die 'MODEL_PATH must end with a .gguf filename.'
        if [[ -n $MODEL_DIR ]]; then
            valid_model_dir "$MODEL_DIR" || die "MODEL_DIR: $directory_guidance"
            [[ $(realpath -m -- "$MODEL_DIR") == "$(realpath -m -- "${MODEL_PATH%/*}")" ]] || die 'MODEL_DIR conflicts with MODEL_PATH.'
        fi
        [[ -z $MODEL_FILE || $MODEL_FILE == "${MODEL_PATH##*/}" ]] || die 'MODEL_FILE conflicts with MODEL_PATH.'
        MODEL_DIR=${MODEL_PATH%/*}
        MODEL_FILE=${MODEL_PATH##*/}
    else
        [[ -n $MODEL_DIR ]] || select_model_storage
        prompt_model_setting MODEL_DIR 'Directory containing or storing GGUF models' /var/lib/llama-target/models valid_model_dir "$directory_guidance"
        MODEL_DIR=$(realpath -m -- "$MODEL_DIR")
        file_default=$download_filename
        if [[ -z $MODEL_FILE ]] && model_prompt_available; then
            local -a candidates=()
            for candidate in "$MODEL_DIR"/*.gguf; do
                [[ -f $candidate ]] || continue
                valid_model_file "${candidate##*/}" || continue
                candidates+=("${candidate##*/}")
            done
            if (( ${#candidates[@]} )); then
                printf 'GGUF files in %s:\n' "$MODEL_DIR" >&2
                printf '  %s\n' "${candidates[@]}" >&2
                # Offer the only GGUF present as the default, unless a download
                # filename already supplied one. (Test strings with [[ ]]; inside
                # (( )) "-n" is arithmetic negation of a variable named n.)
                if (( ${#candidates[@]} == 1 )) && [[ -z $file_default ]]; then
                    file_default=${candidates[0]}
                fi
            fi
        fi
        prompt_model_setting MODEL_FILE 'GGUF filename to load or store (first part if split)' "$file_default" valid_model_file \
            'Enter a .gguf filename, not an Ollama tag or URL (no directory components or spaces).'
        MODEL_PATH=$MODEL_DIR/$MODEL_FILE
    fi
    # Resolve existing symlinks too, so a hidden /home or /tmp target is not accepted.
    MODEL_PATH=$(realpath -m -- "$MODEL_PATH")
    MODEL_DIR=${MODEL_PATH%/*}
    MODEL_FILE=${MODEL_PATH##*/}
    valid_model_dir "$MODEL_DIR" || die "MODEL_PATH resolves to an inaccessible location. $directory_guidance"
    valid_model_file "$MODEL_FILE" || die 'The resolved MODEL_PATH must end with a .gguf filename.'
    [[ ! -e $MODEL_DIR || -d $MODEL_DIR ]] || die 'MODEL_DIR already exists and is not a directory.'
    [[ ! -e $MODEL_PATH || -f $MODEL_PATH ]] || die 'MODEL_PATH already exists and is not a regular file.'
    printf '\nModel alias: %s\nModel directory: %s\nGGUF file: %s\n' "$MODEL_ALIAS" "$MODEL_DIR" "$MODEL_PATH"
    if [[ -n $MODEL_DOWNLOAD_URL ]]; then
        printf 'GGUF download URL: %s\n' "$MODEL_DOWNLOAD_URL"
        [[ -f $MODEL_PATH ]] || printf 'The installer will download the GGUF to this path before building llama.cpp.\n'
    else
        [[ -f $MODEL_PATH ]] || printf 'GGUF not present yet; place it at this path before starting the services.\n'
    fi
}
# End model configuration helpers.

download_requested_gguf() {
    [[ -n ${MODEL_DOWNLOAD_URL:-} ]] || return 0
    if [[ -f $MODEL_PATH ]]; then
        printf 'Using the existing GGUF at %s; MODEL_DOWNLOAD_URL will not overwrite it.\n' "$MODEL_PATH"
        return
    fi
    local partial="$MODEL_PATH.part" header
    [[ ! -e $partial && ! -L $partial ]] || die "A partial GGUF download already exists at $partial; inspect or remove it before retrying."
    runuser -u llama-target -- test -w "$MODEL_DIR" || die "llama-target cannot write $MODEL_DIR; grant write access to download the GGUF."
    printf 'Downloading the requested GGUF to %s ...\n' "$MODEL_PATH"
    runuser -u llama-target -- curl --disable --fail --location --show-error \
        --proto '=https' --proto-redir '=https' --max-redirs 5 \
        --retry 3 --retry-all-errors --connect-timeout 30 \
        --output "$partial" "$MODEL_DOWNLOAD_URL"
    [[ -s $partial ]] || die "The downloaded GGUF is empty: $partial"
    header=$(head -c 4 -- "$partial")
    [[ $header == GGUF ]] || die "The downloaded file does not have a GGUF header: $partial"
    chown root:llama-target "$partial"
    chmod 0640 "$partial"
    [[ ! -e $MODEL_PATH && ! -L $MODEL_PATH ]] || die "Refusing to overwrite an existing GGUF: $MODEL_PATH"
    mv -n -- "$partial" "$MODEL_PATH"
    [[ -f $MODEL_PATH && ! -e $partial ]] || die "Could not promote the downloaded GGUF to $MODEL_PATH"
    runuser -u llama-target -- test -r "$MODEL_PATH" || die "llama-target cannot read downloaded GGUF: $MODEL_PATH"
    printf 'Downloaded GGUF is ready at %s.\n' "$MODEL_PATH"
}

# CUDA compiler discovery helpers (no filesystem mutations).
cuda_compiler_candidates() {
    local candidate
    candidate=$(command -v nvcc 2>/dev/null || true)
    [[ $candidate == /* ]] && printf '%s\n' "$candidate"
    for candidate in \
        /usr/local/cuda/bin/nvcc \
        /usr/local/cuda-13.0/bin/nvcc \
        /usr/bin/nvcc \
        /usr/local/cuda-*/bin/nvcc; do
        [[ -e $candidate || -L $candidate ]] || continue
        printf '%s\n' "$candidate"
    done
}
cuda_compiler_missing() {
    local requested=${1:-}
    if [[ -n $requested ]]; then
        printf 'Configured CUDA compiler is not executable: %s\n' "$requested" >&2
    else
        printf 'No executable CUDA compiler (nvcc) was found inside this target CT.\n' >&2
    fi
    cat >&2 <<'GUIDANCE'
The NVIDIA LXC user-space driver helper does not install the CUDA toolkit.
Install the toolkit inside this Debian 12 target, then rerun the installer:
  apt-get update
  apt-get install -y ca-certificates wget
  wget -O /tmp/cuda-keyring.deb https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
  dpkg -i /tmp/cuda-keyring.deb
  apt-get update
  apt-get install --no-install-recommends -y cuda-toolkit-13-0
  /usr/local/cuda-13.0/bin/nvcc --version
Then unset CUDA_COMPILER and run install-target.sh again; it will discover nvcc.
GUIDANCE
    die 'CUDA toolkit 13.0 is required for BACKEND=cuda.'
}
resolve_cuda_compiler() {
    local requested=${CUDA_COMPILER:-} candidate resolved=''
    if [[ -n $requested && -x $requested ]]; then
        CUDA_COMPILER=$(realpath -e -- "$requested")
        return 0
    fi
    while IFS= read -r candidate; do
        [[ $candidate == /* && -x $candidate ]] || continue
        resolved=$(realpath -e -- "$candidate") || continue
        break
    done < <(cuda_compiler_candidates)
    [[ -n $resolved ]] || return 1
    if [[ -n $requested ]]; then
        printf 'Configured CUDA compiler %s is unavailable; using detected compiler %s.\n' "$requested" "$resolved" >&2
    fi
    CUDA_COMPILER=$resolved
}
install_cuda_toolkit_13_0() {
    local keyring_url=https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
    printf 'CUDA compiler was not found; installing the CUDA 13.0 toolkit inside this target CT.\n'
    apt-get update
    apt-get install -y ca-certificates wget
    wget --https-only -O /tmp/cuda-keyring.deb "$keyring_url"
    dpkg -i /tmp/cuda-keyring.deb
    apt-get update
    apt-get install --no-install-recommends -y cuda-toolkit-13-0
    /usr/local/cuda-13.0/bin/nvcc --version
}
ensure_cuda_compiler() {
    local requested=${CUDA_COMPILER:-}
    if resolve_cuda_compiler; then
        return 0
    fi
    install_cuda_toolkit_13_0
    resolve_cuda_compiler || cuda_compiler_missing "$requested"
}
# End CUDA compiler discovery helpers.

# Build and upgrade helpers (paths are overridable so tests can use a temp tree).
TARGET_ROOT=${TARGET_ROOT:-/opt/llama-target}
TARGET_ETC=${TARGET_ETC:-/etc/llama-target}
TARGET_UNITS=${TARGET_UNITS:-/etc/systemd/system}
TARGET_HEALTH_URL=${TARGET_HEALTH_URL:-http://127.0.0.1:11434/healthz}
# Extra llama-server flags (llama-server.env): e.g. "--flash-attn on
# --cache-type-k q8_0 --cache-type-v q8_0". Word-split by systemd.
valid_extra_args() {
    [[ $1 =~ ^[A-Za-z0-9\ ._,:=/+-]*$ ]]
}
# One key from build-info.txt (empty when absent).
build_info() {
    [[ -f $TARGET_ROOT/build-info.txt ]] || return 0
    sed -n "s/^$1=//p" "$TARGET_ROOT/build-info.txt" | head -n1
}
# Fetch LLAMA_CPP_REF into a fresh clone at $1; print the resolved commit.
fetch_llama_source() {
    local repo=$1
    rm -rf -- "$repo"
    git init -q "$repo"
    git -C "$repo" remote add origin https://github.com/ggml-org/llama.cpp.git
    if [[ $LLAMA_CPP_REF =~ ^[0-9a-fA-F]{40}$ ]]; then
        git -C "$repo" fetch -q --depth 1 origin "$LLAMA_CPP_REF"
    else
        # Fetch a tag explicitly so a branch with a similar name cannot move the build.
        git -C "$repo" fetch -q --depth 1 origin "refs/tags/$LLAMA_CPP_REF"
    fi
    git -C "$repo" checkout -q --detach FETCH_HEAD
    git -C "$repo" rev-parse HEAD
}
# Build llama-server from the clone at $1 and install it as $2, verified.
build_llama_server() {
    local repo=$1 dest=$2 dependencies
    local -a cmake_args=(-S "$repo" -B "$repo/build" -G Ninja -DCMAKE_BUILD_TYPE=Release
        -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TESTS=OFF
        -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_OPENSSL=ON
        -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF)
    if [[ $LLAMA_CPP_REF =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        cmake_args+=(-DLLAMA_BUILD_IS_DEV=OFF)
    fi
    if [[ $BACKEND == cuda ]]; then
        cmake_args+=(-DGGML_CUDA=ON "-DCMAKE_CUDA_COMPILER=$CUDA_COMPILER")
        [[ -z $CUDA_ARCHITECTURES ]] || cmake_args+=("-DCMAKE_CUDA_ARCHITECTURES=$CUDA_ARCHITECTURES")
    else
        cmake_args+=(-DGGML_CUDA=OFF)
    fi
    cmake "${cmake_args[@]}"
    cmake --build "$repo/build" --target llama-server --parallel "$BUILD_JOBS"
    install -o root -g root -m 0755 "$repo/build/bin/llama-server" "$dest"
    dependencies=$(ldd "$dest")
    printf '%s\n' "$dependencies"
    [[ $dependencies != *'not found'* ]] || die 'The built llama-server is missing a shared library. Check CUDA userspace paths/ldconfig inside this CT.'
    "$dest" --version
}
# (Re)create the bridge venv and install bridge.py from $1.
install_bridge() {
    local src=$1
    # The service account must be able to traverse and read the root-owned venv.
    ( umask 022
      python3 -m venv "$TARGET_ROOT/venv"
      "$TARGET_ROOT/venv/bin/python" -m pip install -q --disable-pip-version-check -r "$src/requirements.txt"
      install -o root -g root -m 0644 "$src/bridge.py" "$src/requirements.txt" "$TARGET_ROOT/"
      "$TARGET_ROOT/venv/bin/python" -m py_compile "$TARGET_ROOT/bridge.py"
      "$TARGET_ROOT/venv/bin/python" -m pip freeze > "$TARGET_ROOT/python-packages.txt" )
}
write_build_info() {
    ( umask 022
      cat > "$TARGET_ROOT/build-info.txt" <<BUILDINFO
llama.cpp repository=https://github.com/ggml-org/llama.cpp.git
requested_ref=$LLAMA_CPP_REF
resolved_commit=$1
backend=$BACKEND
BUILDINFO
    )
}
# Move $1 aside as $1.prev (replacing an older .prev); a no-op when absent.
set_aside() {
    [[ -e $1 || -L $1 ]] || return 0
    rm -rf -- "$1.prev"
    mv -- "$1" "$1.prev"
}
# Undo set_aside: put $1.prev back in place of whatever is at $1.
restore_aside() {
    [[ -e $1.prev || -L $1.prev ]] || return 0
    rm -rf -- "$1"
    mv -- "$1.prev" "$1"
}
# Append KEY=value to an env file when the key is missing (never rewrites one).
ensure_env_key() {
    grep -q "^$2=" "$1" 2>/dev/null || printf '%s=%s\n' "$2" "$3" >> "$1"
}
# Wait up to $1 seconds (default 300: a large model takes a while to load) for
# the bridge to report the model ready.
target_healthy() {
    local limit=${1:-300} waited=0
    while (( waited < limit )); do
        curl -fsS -o /dev/null --max-time 5 "$TARGET_HEALTH_URL" 2>/dev/null && return 0
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}
# End build and upgrade helpers.

MODE=install
case "${1:-}" in
    '') ;;
    --help) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
    --upgrade) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; MODE=upgrade ;;
    *) usage >&2; exit 2 ;;
esac
[[ ${EUID} -eq 0 ]] || die 'Run as root inside the dedicated target CT.'
[[ ! -d /etc/pve ]] || die 'This is a Proxmox host. Use provision-lxc.sh here instead.'
[[ -d ${SYSTEMD_RUN_DIR:-/run/systemd/system} ]] || die 'A running systemd environment is required.'
command -v systemd-detect-virt >/dev/null || die 'systemd-detect-virt is required.'
[[ $(systemd-detect-virt --container) == lxc ]] || die 'Install only in the dedicated inference-target LXC.'
# shellcheck disable=SC1090,SC1091
source "${OS_RELEASE_FILE:-/etc/os-release}"
[[ ${ID:-} == debian && ${VERSION_ID:-} == 12 ]] || die 'This CUDA 13.0 deployment targets a Debian 12 guest.'
[[ ! -d /app/router ]] || die 'The smart-router installation is present. Install this stack in a separate inference-target CT.'
[[ $(systemctl show ollama-router.service -p LoadState --value) == not-found ]] || die 'The smart-router service is present. Install this stack in a separate inference-target CT.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in bridge.py requirements.txt llama-server.service llama-ollama-bridge.service; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done

if [[ $MODE == upgrade ]]; then
    # Upgrade an existing target in place: new llama.cpp ref and/or new bridge
    # code, same model and settings. Every replaced piece is kept as *.prev and
    # put back automatically if the target does not come back healthy.
    [[ -x $TARGET_ROOT/bin/llama-server && -f $TARGET_ETC/llama-server.env && -f $TARGET_ETC/bridge.env ]] || \
        die "No existing installation under $TARGET_ROOT and $TARGET_ETC; run without --upgrade to install."
    getent passwd llama-target >/dev/null || die 'The llama-target user is missing; this is not an installed target.'
    BACKEND=${BACKEND:-$(build_info backend)}
    BACKEND=${BACKEND:-cuda}
    BUILD_JOBS=${BUILD_JOBS:-4}
    CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES:-native}
    CUDA_COMPILER=${CUDA_COMPILER:-}
    FORCE_REBUILD=${FORCE_REBUILD:-false}
    [[ $BACKEND == cpu || $BACKEND == cuda ]] || die 'BACKEND must be cpu or cuda.'
    [[ $BUILD_JOBS =~ ^[1-9][0-9]{0,8}$ ]] || die 'BUILD_JOBS must be a positive integer.'
    [[ $LLAMA_CPP_REF =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Use a release tag or full 40-character commit, without a refs/ prefix.'
    [[ $LLAMA_CPP_REF != HEAD && $LLAMA_CPP_REF != master && $LLAMA_CPP_REF != main ]] || die 'Choose a pinned release tag or commit, not a branch.'
    [[ $CUDA_ARCHITECTURES == native || $CUDA_ARCHITECTURES =~ ^[0-9]+(-real|-virtual)?(\;[0-9]+(-real|-virtual)?)*$ ]] || die 'Invalid CUDA_ARCHITECTURES.'
    [[ -z $CUDA_COMPILER || $CUDA_COMPILER =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'CUDA_COMPILER must be an absolute executable path without spaces.'
    export DEBIAN_FRONTEND=noninteractive
    if [[ $BACKEND == cuda ]]; then
        ensure_cuda_compiler
        printf 'Using CUDA compiler: %s\n' "$CUDA_COMPILER"
    fi

    current_commit=$(build_info resolved_commit)
    printf 'Installed llama.cpp: %s (%s)\nRequested ref: %s\n' "${current_commit:-unknown}" "$(build_info requested_ref)" "$LLAMA_CPP_REF"
    new_repo=$TARGET_ROOT/src/llama.cpp.new
    new_commit=$(fetch_llama_source "$new_repo")
    rebuild=false
    [[ $new_commit != "$current_commit" || $FORCE_REBUILD == true ]] && rebuild=true

    was_active=false
    systemctl is-active --quiet llama-server.service && was_active=true
    # Only what THIS run set aside is restored: a *.prev left by an earlier
    # upgrade must never be mistaken for the version to go back to.
    aside=()
    stash() { set_aside "$1"; aside+=("$1"); }
    rollback() {
        local path
        printf 'Upgrade failed; restoring the previous installation...\n' >&2
        systemctl stop llama-ollama-bridge.service llama-server.service 2>/dev/null || true
        rm -f -- "$TARGET_ROOT/bin/llama-server.new"
        for path in "${aside[@]}"; do restore_aside "$path"; done
        systemctl daemon-reload
        if $was_active; then systemctl start llama-server.service llama-ollama-bridge.service || true; fi
    }
    trap 'rollback; exit 1' ERR

    if $rebuild; then
        printf 'Building llama.cpp %s (%s)...\n' "$LLAMA_CPP_REF" "$new_commit"
        build_llama_server "$new_repo" "$TARGET_ROOT/bin/llama-server.new"
        stash "$TARGET_ROOT/bin/llama-server"
        mv -- "$TARGET_ROOT/bin/llama-server.new" "$TARGET_ROOT/bin/llama-server"
        rm -rf -- "$TARGET_ROOT/src/llama.cpp"
        mv -- "$new_repo" "$TARGET_ROOT/src/llama.cpp"
    else
        printf 'llama.cpp is already at %s; not rebuilding (FORCE_REBUILD=true to force).\n' "$new_commit"
        rm -rf -- "$new_repo"
    fi
    stash "$TARGET_ROOT/bridge.py"
    stash "$TARGET_ROOT/requirements.txt"
    stash "$TARGET_ROOT/venv"
    install_bridge "$source_dir"
    stash "$TARGET_ROOT/build-info.txt"
    write_build_info "$new_commit"
    for unit in llama-server.service llama-ollama-bridge.service; do
        stash "$TARGET_UNITS/$unit"
        install -o root -g root -m 0644 "$source_dir/$unit" "$TARGET_UNITS/$unit"
    done
    # New settings get their defaults; existing values are never rewritten.
    ensure_env_key "$TARGET_ETC/llama-server.env" LLAMA_EXTRA_ARGS ''
    systemctl daemon-reload

    if $was_active; then
        systemctl restart llama-server.service llama-ollama-bridge.service
        printf 'Waiting for the target to report ready...\n'
        target_healthy "${UPGRADE_HEALTH_TIMEOUT:-300}" || false
        printf 'Target is healthy on the upgraded build.\n'
    else
        printf 'Services were stopped before the upgrade and are left stopped.\n'
    fi
    trap - ERR
    printf 'Upgrade complete: llama.cpp %s (%s). Previous files are kept as *.prev.\n' "$LLAMA_CPP_REF" "$new_commit"
    exit 0
fi

configure_model
BACKEND=${BACKEND:-cuda}
BUILD_JOBS=${BUILD_JOBS:-4}
CONTEXT_SIZE=${CONTEXT_SIZE:-8192}
PARALLEL_SLOTS=${PARALLEL_SLOTS:-1}
THREADS=${THREADS:-4}
if [[ $BACKEND == cuda ]]; then GPU_LAYERS=${GPU_LAYERS:-auto}; else GPU_LAYERS=${GPU_LAYERS:-0}; fi
MODEL_PARAMETER_SIZE=${MODEL_PARAMETER_SIZE:-unknown}
MODEL_FAMILY=${MODEL_FAMILY:-unknown}
MODEL_QUANTIZATION=${MODEL_QUANTIZATION:-unknown}
MODEL_CAPABILITIES=${MODEL_CAPABILITIES:-completion}
CUDA_ARCHITECTURES=${CUDA_ARCHITECTURES:-native}
CUDA_COMPILER=${CUDA_COMPILER:-}
LLAMA_EXTRA_ARGS=${LLAMA_EXTRA_ARGS:-}

positive_int() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
for name in BUILD_JOBS CONTEXT_SIZE PARALLEL_SLOTS THREADS; do positive_int "$name" "${!name}"; done
[[ $GPU_LAYERS == auto || $GPU_LAYERS == all || $GPU_LAYERS =~ ^(0|[1-9][0-9]{0,5})$ ]] || die 'GPU_LAYERS must be auto, all, or a nonnegative integer.'
[[ $BACKEND == cpu || $BACKEND == cuda ]] || die 'BACKEND must be cpu or cuda.'
[[ $BACKEND == cuda || $GPU_LAYERS == 0 ]] || die 'A CPU build requires GPU_LAYERS=0.'
[[ $LLAMA_CPP_REF =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Use a release tag or full 40-character commit, without a refs/ prefix.'
[[ $LLAMA_CPP_REF != HEAD && $LLAMA_CPP_REF != master && $LLAMA_CPP_REF != main ]] || die 'Choose a pinned release tag or commit, not a branch.'
for name in MODEL_PARAMETER_SIZE MODEL_FAMILY MODEL_QUANTIZATION; do
    [[ ${!name} =~ ^[A-Za-z0-9._-]+$ ]] || die "$name contains unsupported characters."
done
[[ $MODEL_CAPABILITIES =~ ^(completion|tools|vision|embedding)(,(completion|tools|vision|embedding))*$ ]] || die 'MODEL_CAPABILITIES may contain completion,tools,vision,embedding.'
[[ $CUDA_ARCHITECTURES == native || $CUDA_ARCHITECTURES =~ ^[0-9]+(-real|-virtual)?(\;[0-9]+(-real|-virtual)?)*$ ]] || die 'CUDA_ARCHITECTURES must be native or a semicolon-separated CMake architecture list, e.g. 89 or 86;89;120.'
[[ -z $CUDA_COMPILER || $CUDA_COMPILER =~ ^/[A-Za-z0-9_./-]+$ ]] || die 'CUDA_COMPILER must be an absolute executable path without spaces.'
valid_extra_args "$LLAMA_EXTRA_ARGS" || die 'LLAMA_EXTRA_ARGS may contain only letters, digits, spaces and . _ , : = / + -'

for path in /opt/llama-target /etc/llama-target /etc/systemd/system/llama-server.service /etc/systemd/system/llama-ollama-bridge.service; do
    [[ ! -e $path && ! -L $path ]] || die "Refusing to overwrite $path. Inspect the existing installation before a manual update."
done
getent passwd llama-target >/dev/null && die 'The llama-target user already exists; inspect before installing.'
getent group llama-target >/dev/null && die 'The llama-target group already exists; inspect before installing.'
getent group 993 >/dev/null && die 'GID 993 is already in use. Resolve the dedicated target group and device mapping before installing.'
if command -v ss >/dev/null; then
    [[ -z $(ss -H -ltn '( sport = :8081 or sport = :11434 )') ]] || die 'Port 8081 or 11434 is already in use. Do not install over a live Ollama target.'
fi

trap 'printf "Installation stopped at line %s. Services were not started. Inspect partial files before retrying; no existing installation is overwritten.\n" "$LINENO" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
if [[ $BACKEND == cuda ]]; then
    command -v nvidia-smi >/dev/null || die 'CUDA requested but nvidia-smi is missing; prepare matched userspace driver libraries first.'
    nvidia-smi -L || die 'GPU access is not working inside this CT.'
    ensure_cuda_compiler
    printf 'Using CUDA compiler: %s\n' "$CUDA_COMPILER"
    "$CUDA_COMPILER" --version || die "CUDA compiler could not run: $CUDA_COMPILER"
fi

apt-get -o Acquire::Retries=3 update
apt-get install --no-install-recommends -y ca-certificates curl git build-essential cmake ninja-build pkg-config python3 python3-venv libcurl4-openssl-dev libssl-dev
groupadd --system --gid 993 llama-target
useradd --system --gid llama-target --home-dir /var/lib/llama-target --no-create-home --shell /usr/sbin/nologin llama-target
if [[ $BACKEND == cuda ]]; then
    runuser -u llama-target -- nvidia-smi -L || die 'The llama-target account cannot access the GPU; check CT device gid=993 and mode=0660.'
fi
install -d -o root -g root -m 0755 /opt/llama-target /opt/llama-target/bin /opt/llama-target/src
install -d -o root -g llama-target -m 0750 /etc/llama-target
if [[ ! -d /var/lib/llama-target ]]; then
    install -d -o llama-target -g llama-target -m 0750 /var/lib/llama-target
fi
runuser -u llama-target -- test -w /var/lib/llama-target || die 'llama-target needs write access to its state directory /var/lib/llama-target.'
# Preserve existing shared/bind-mounted stores and their file ownership.
if [[ ! -d $MODEL_DIR ]]; then
    install -d -o llama-target -g llama-target -m 0750 "$MODEL_DIR"
fi
runuser -u llama-target -- test -x "$MODEL_DIR" || die "llama-target cannot traverse $MODEL_DIR; grant access to this model store."
if [[ -f $MODEL_PATH ]]; then
    runuser -u llama-target -- test -r "$MODEL_PATH" || die "llama-target cannot read $MODEL_PATH; grant read access to the GGUF."
fi
download_requested_gguf

printf 'Building llama.cpp from pinned ref: %s\n' "$LLAMA_CPP_REF"
resolved_commit=$(fetch_llama_source "$TARGET_ROOT/src/llama.cpp")
build_llama_server "$TARGET_ROOT/src/llama.cpp" "$TARGET_ROOT/bin/llama-server"
install_bridge "$source_dir"
write_build_info "$resolved_commit"

umask 027
cat > /etc/llama-target/llama-server.env <<SERVERENV
MODEL_PATH=$MODEL_PATH
MODEL_ALIAS=$MODEL_ALIAS
CONTEXT_SIZE=$CONTEXT_SIZE
PARALLEL_SLOTS=$PARALLEL_SLOTS
THREADS=$THREADS
GPU_LAYERS=$GPU_LAYERS
LLAMA_EXTRA_ARGS=$LLAMA_EXTRA_ARGS
SERVERENV
cat > /etc/llama-target/bridge.env <<BRIDGEENV
LLAMA_BASE_URL=http://127.0.0.1:8081
MODEL_ALIAS=$MODEL_ALIAS
MODEL_PATH=$MODEL_PATH
MODEL_PARAMETER_SIZE=$MODEL_PARAMETER_SIZE
MODEL_FAMILY=$MODEL_FAMILY
MODEL_QUANTIZATION=$MODEL_QUANTIZATION
MODEL_CAPABILITIES=$MODEL_CAPABILITIES
REQUEST_TIMEOUT_SECONDS=600
BRIDGEENV
chown root:llama-target /etc/llama-target/*.env
chmod 0640 /etc/llama-target/*.env
install -o root -g root -m 0644 "$source_dir/llama-server.service" "$source_dir/llama-ollama-bridge.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable llama-server.service llama-ollama-bridge.service

printf '\nInstalled target build %s (%s). Services are enabled and currently stopped.\n' "$resolved_commit" "$BACKEND"
if [[ -n $MODEL_DOWNLOAD_URL ]]; then
    printf 'GGUF is available at %s, readable by llama-target.\n' "$MODEL_PATH"
else
    printf 'Stage the local GGUF at %s, readable by llama-target.\n' "$MODEL_PATH"
fi
printf 'Review /etc/llama-target/*.env and restrict TCP 11434 to trusted clients.\n'
printf 'Then run: systemctl start llama-server llama-ollama-bridge\n'
printf 'Check readiness: curl --fail http://127.0.0.1:11434/healthz\n'
