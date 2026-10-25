#!/usr/bin/env bash
# Run INSIDE a ComfyUI target CT created by the Proxmox community script
# (ct/comfyui.sh, via provision-lxc.sh), never on the router CT or the PVE host.
# Adopts that install into this repository's target conventions:
#   * comfyui.service runs as the unprivileged `comfyui` account under a
#     hardening drop-in (comfyui.service.d/10-comfyui-target.conf), not as root
#   * the code it runs is /opt/comfyui-target/current; models, custom nodes,
#     inputs, outputs and user settings live in /var/lib/comfyui-target
#   * settings in /etc/comfyui-target/comfyui.env
#   * --upgrade builds a pinned, commit-verified release beside the running one
#     and switches to it, with rollback
set -Eeuo pipefail

# Release reviewed for this repository for --upgrade. Keep it fixed until a newer
# release has been reviewed; never resolve "latest".
readonly COMFYUI_DEFAULT_VERSION=v0.42.1
readonly COMFYUI_DEFAULT_COMMIT=63be2f9b82ad0dac88a7ceaa28a9cf3154125a18

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<USAGE
Usage: bash install-target.sh              # adopt the community-script install (safe to re-run)
       bash install-target.sh --upgrade    # build and switch to the pinned ComfyUI release

Settings (environment; all optional):
  COMFYUI_PORT=8188          port for a new comfyui.env (an existing one is kept)
  COMFYUI_DEVICE=gpu|cpu     cpu adds --cpu to a new comfyui.env (no GPU in the CT)
  READY_TIMEOUT=300          seconds to wait for ComfyUI after adoption
  COMFYUI_MODEL_URL=<https URL>   download a model into models/<folder>
  COMFYUI_MODEL_SHA256=<hex>      and require this checksum
  COMFYUI_MODEL_FOLDER=checkpoints  COMFYUI_MODEL_NAME=<file name; from the URL>
  COMFYUI_IMAGE_VARIANT=none|klein-4b|klein-9b   download that FLUX.2 Klein model's diffusion
                             file, text encoder and VAE (klein-weights.txt; checksums checked,
                             interrupted downloads resumed, kept files not downloaded again)
  HF_TOKEN_FILE=<file>       a Hugging Face token for klein-9b (gated: its account must
                             have accepted the FLUX Non-Commercial License)
  COMFYUI_KLEIN_9B_SHA256=<hex>  pin the gated 9B file (default: Hugging Face's own hash)
  COMFYUI_VERSION=$COMFYUI_DEFAULT_VERSION    release for --upgrade
  COMFYUI_COMMIT=<sha1>      the reviewed commit of that tag (required for a non-default version)
  COMFYUI_TORCH=<build>      PyTorch build for --upgrade: cu130, cu128, rocm7.2, xpu, cpu or
                             pypi (default: the build the current release uses)
  FORCE_REBUILD=true         rebuild even when the release is already installed
  UPGRADE_HEALTH_TIMEOUT=300 seconds the new release has to answer before rollback
Server settings live in /etc/comfyui-target/comfyui.env (see comfyui.env.example).

--upgrade clones the tag from GitHub, checks that it is the expected commit,
builds a new venv in /opt/comfyui-target/releases/ while the current release
keeps running, then switches /opt/comfyui-target/current to it. If ComfyUI does
not answer as the new version, the previous release is put back and checked.
Models and settings are not touched. The community script's \`update\` only
points to ComfyUI-Manager; use --upgrade instead.
USAGE
}

# Install helpers (paths are overridable so tests can use a temp tree).
TARGET_ETC=${TARGET_ETC:-/etc/comfyui-target}
TARGET_STATE=${TARGET_STATE:-/var/lib/comfyui-target}
TARGET_OPT=${TARGET_OPT:-/opt/comfyui-target}
TARGET_UNITS=${TARGET_UNITS:-/etc/systemd/system}
TARGET_USER=${TARGET_USER:-comfyui}
COMMUNITY_DIR=${COMMUNITY_DIR:-/opt/ComfyUI}
COMFYUI_REPO=${COMFYUI_REPO:-https://github.com/Comfy-Org/ComfyUI.git}
TORCH_INDEX_BASE=${TORCH_INDEX_BASE:-https://download.pytorch.org/whl}
LOCK_FILE=${LOCK_FILE:-/etc/comfyui-target.lock}
# Home directories: an interpreter there is out of the service account's reach.
PRIVATE_PREFIXES=${PRIVATE_PREFIXES:-/root /home}
SERVICE=comfyui.service
DROPIN=$TARGET_UNITS/$SERVICE.d/10-comfyui-target.conf
TARGET_ENV=$TARGET_ETC/comfyui.env
CURRENT=$TARGET_OPT/current
RELEASES=$TARGET_OPT/releases
# ComfyUI's writable folders; --base-directory puts them all in TARGET_STATE.
DATA_DIRS="models custom_nodes input output temp user"

valid_version() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_commit() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
valid_model_folder() { [[ $1 =~ ^[a-z][a-z0-9_]{0,63}$ ]]; }
valid_file_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,200}$ && $1 != *..* ]]; }
valid_torch_build() { [[ $1 =~ ^(pypi|cpu|xpu|cu[0-9]{3}|rocm[0-9]+(\.[0-9]+)?)$ ]]; }
# model_file_name URL: the name a download is saved as (the last part of the URL path).
model_file_name() { local path=${1%%[?#]*}; printf '%s\n' "${path##*/}"; }
# Last value of KEY in an env file, without surrounding quotes (empty when absent).
env_value() {
    [[ -r $1 ]] || return 0
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" | tail -n1 | sed -E "s/^([\"'])(.*)\\1\$/\\2/"
}
# Append KEY=value when the key is missing (never rewrites one).
ensure_env_key() {
    grep -Eq "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || printf '%s=%s\n' "$2" "$3" >> "$1"
}
# The local API base for this target's COMFYUI_PORT (always loopback).
api_base() {
    local port
    port=$(env_value "$TARGET_ENV" COMFYUI_PORT)
    valid_port "${port:-x}" || port=8188
    printf 'http://127.0.0.1:%s' "$port"
}
# ComfyUI's /system_stats (empty when it does not answer).
system_stats() { curl -fsS --max-time 5 "$(api_base)/system_stats" 2>/dev/null || true; }
# The version the running server reports ("0.42.1"; empty when it does not answer).
served_version() {
    system_stats | sed -nE 's/.*"comfyui_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
}
# The type of the server's first torch device (cuda, cpu, xpu, ...).
served_device() {
    system_stats | tr ',{' '\n\n' | sed -nE 's/^[[:space:]]*"type"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
}
# Wait up to $2 seconds for the server to report version $1 (any version when empty).
wait_for_version() {
    local want=${1#v} limit=${2:-60} waited=0 got
    while (( waited < limit )); do
        got=$(served_version || true)
        if [[ -n $got && ( -z $want || $got == "$want" ) ]]; then return 0; fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}
# The ComfyUI version of the release in directory $1 (from comfyui_version.py).
release_version() {
    sed -nE 's/^__version__[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$1/comfyui_version.py" 2>/dev/null | head -n1
}
# The verified commit of release $1 (empty for the community install).
release_commit() { cat -- "$1/.comfyui-target-commit" 2>/dev/null || true; }
# torch_build VENV: the local version tag of the venv's torch (cu130, rocm7.2,
# xpu, cpu), "pypi" for a plain PyPI build; empty when torch is not installed.
torch_build() {
    local dist
    for dist in "$1"/lib/python3*/site-packages/torch-[0-9]*.dist-info; do
        [[ -d $dist ]] || continue
        dist=${dist##*/torch-}
        dist=${dist%.dist-info}
        if [[ $dist == *+* ]]; then printf '%s\n' "${dist##*+}"; else echo pypi; fi
        return 0
    done
}
# torch_index_args BUILD: the uv pip arguments that select that PyTorch build,
# one per line. CUDA builds are an extra index, as upstream's README has it.
torch_index_args() {
    case $1 in
        pypi) ;;
        cu*) printf '%s\n' --extra-index-url "$TORCH_INDEX_BASE/$1" ;;
        *) printf '%s\n' --index-url "$TORCH_INDEX_BASE/$1" ;;
    esac
}
# The interpreter venv $1 runs (all symlinks resolved).
venv_interpreter() { readlink -f -- "$1/bin/python"; }
# True when the service account cannot run interpreter $1: uv installs Python
# under root's home (/root/.local/share/uv/python), which it cannot enter.
private_interpreter() {
    local prefix
    for prefix in $PRIVATE_PREFIXES; do
        if [[ $1 == "$prefix"/* ]]; then return 0; fi
    done
    return 1
}
# relocate_interpreter VENV: copy the venv's interpreter out of a home
# directory into $TARGET_OPT/python and point the venv at the copy.
relocate_interpreter() {
    local venv=$1 interp prefix dest link resolved
    interp=$(venv_interpreter "$venv")
    private_interpreter "$interp" || return 0
    # A standalone (uv) Python: <prefix>/bin/python3.X with its own lib/.
    prefix=$(dirname -- "$(dirname -- "$interp")")
    [[ -d $prefix/lib ]] || die "The venv's interpreter $interp is not a relocatable Python installation."
    dest=$TARGET_OPT/python/${prefix##*/}
    if [[ ! -x $dest/bin/${interp##*/} ]]; then
        install -d -m 0755 "$TARGET_OPT/python"
        rm -rf -- "$dest.part"
        cp -a -- "$prefix" "$dest.part"
        chmod -R u+rwX,go+rX,go-w -- "$dest.part"
        mv -- "$dest.part" "$dest"
    fi
    for link in "$venv"/bin/python*; do
        [[ -L $link ]] || continue
        resolved=$(readlink -f -- "$link")
        [[ $resolved == "$prefix"/* ]] || continue
        ln -sfn -- "$dest${resolved#"$prefix"}" "$link"
    done
    sed -i -E "s|^(home[[:space:]]*=[[:space:]]*).*|\\1$dest/bin|; s|^(executable[[:space:]]*=[[:space:]]*).*|\\1$dest/bin/${interp##*/}|" "$venv/pyvenv.cfg"
    printf 'The venv now runs Python from %s (copied from %s).\n' "$dest" "$prefix"
}
# as_service CMD...: run CMD as the service account, without the installer
# lock's descriptor, so nothing it leaves behind can hold the lock.
as_service() {
    if [[ -n ${lock_fd:-} ]]; then
        runuser -u "$TARGET_USER" -- "$@" {lock_fd}>&-
    else
        runuser -u "$TARGET_USER" -- "$@"
    fi
}
# usable_by_service VENV: the service account can start the venv's Python.
usable_by_service() { as_service "$1/bin/python" -c 'import sys' >/dev/null 2>&1; }
# adopt_data SRC DEST: bring the data folders ($DATA_DIRS) of the community
# tree SRC into DEST, at the same relative paths and never replacing a file
# there. Model files are moved (they can be many GB); everything else is copied,
# since it may belong to the release (models/configs, the example input, the
# example custom node). ComfyUI's put_*_here placeholders are skipped.
adopt_data() {
    local src=$1 dest=$2 dir entry rel moved=0 copied=0
    for dir in $DATA_DIRS; do
        [[ -d $src/$dir ]] || continue
        while IFS= read -r -d '' entry; do
            install -d -m 0750 "$dest/${entry#"$src"/}"
        done < <(find "$src/$dir" -type d -print0)
        while IFS= read -r -d '' entry; do
            rel=${entry#"$src"/}
            [[ ! -e $dest/$rel ]] || continue
            if [[ $rel == models/* && $rel != models/configs/* ]]; then
                mv -- "$entry" "$dest/$rel"
                moved=$((moved + 1))
            else
                cp -p -- "$entry" "$dest/$rel"
                copied=$((copied + 1))
            fi
        done < <(find "$src/$dir" -type f ! -name 'put_*_here' -print0)
    done
    if (( moved + copied > 0 )); then
        printf 'From %s: moved %s model file(s), copied %s other file(s) to %s.\n' "$src" "$moved" "$copied" "$dest"
    fi
}
# set_current DIR: point $CURRENT at DIR in one rename.
set_current() {
    ln -sfn -- "$1" "$CURRENT.new"
    mv -Tf -- "$CURRENT.new" "$CURRENT"
}
# prune_releases KEEP...: delete every build under $RELEASES except KEEP.
prune_releases() {
    local dir keep skip
    for dir in "$RELEASES"/*; do
        [[ -d $dir ]] || continue
        skip=0
        for keep in "$@"; do
            if [[ $(readlink -f -- "$dir") == "$(readlink -f -- "$keep")" ]]; then skip=1; fi
        done
        if (( ! skip )); then rm -rf -- "$dir"; fi
    done
}
# fetch_model URL NAME FOLDER SHA256: download a model as the service account
# into models/FOLDER/NAME and verify it. An existing file is kept (and checked).
fetch_model() {
    local url=$1 name=$2 folder=$3 sha=${4,,} dir file actual
    dir=$TARGET_STATE/models/$folder
    file=$dir/$name
    if [[ -f $file ]]; then
        if [[ -n $sha ]]; then
            actual=$(sha256sum "$file" | awk '{ print $1 }')
            [[ $actual == "$sha" ]] || die "$file exists with checksum $actual, not COMFYUI_MODEL_SHA256 $sha. Move it aside to download again."
        fi
        printf 'Keeping the existing %s.\n' "$file"
        return 0
    fi
    install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0750 "$dir"
    rm -f -- "$file.part"
    printf 'Downloading %s...\n' "$url"
    if ! as_service curl -fL --retry 3 --proto '=https' -o "$file.part" "$url"; then
        rm -f -- "$file.part"
        die "Downloading $url failed."
    fi
    actual=$(sha256sum "$file.part" | awk '{ print $1 }')
    if [[ -n $sha && $actual != "$sha" ]]; then
        rm -f -- "$file.part"
        die "Checksum mismatch for $name: got $actual, COMFYUI_MODEL_SHA256 is $sha."
    fi
    mv -- "$file.part" "$file"
    printf 'Saved %s (sha256 %s).\n' "$file" "$actual"
}
# build_release TAG COMMIT DIR BUILD PYTHON: clone TAG into DIR, check that it
# is COMMIT and the version it claims, and build its venv with PYTHON and the
# PyTorch BUILD. Returns non-zero (with a message) on any failure.
build_release() {
    local tag=$1 commit=$2 dir=$3 build=$4 python=$5 got
    local -a index=()
    mapfile -t index < <(torch_index_args "$build")
    rm -rf -- "$dir"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" --single-branch "$COMFYUI_REPO" "$dir" || return 1
    got=$(git -C "$dir" rev-parse 'HEAD^{commit}') || return 1
    if [[ $got != "$commit" ]]; then
        printf 'Error: %s of %s is commit %s, not the reviewed %s.\n' "$tag" "$COMFYUI_REPO" "$got" "$commit" >&2
        return 1
    fi
    rm -rf -- "$dir/.git"
    printf '%s\n' "$commit" > "$dir/.comfyui-target-commit" || return 1
    got=$(release_version "$dir")
    if [[ $got != "${tag#v}" ]]; then
        printf 'Error: %s reports version %s, not %s.\n' "$tag" "${got:-none}" "${tag#v}" >&2
        return 1
    fi
    uv venv --quiet --python "$python" "$dir/venv" || return 1
    uv pip install --quiet --python "$dir/venv/bin/python" torch torchvision torchaudio "${index[@]}" || return 1
    uv pip install --quiet --python "$dir/venv/bin/python" -r "$dir/requirements.txt" || return 1
    "$dir/venv/bin/python" -c 'import torch, torchvision, aiohttp, sqlalchemy, yaml, safetensors' || {
        printf 'Error: the new venv cannot import ComfyUI'"'"'s dependencies.\n' >&2
        return 1
    }
    chmod -R u+rwX,go+rX,go-w -- "$dir" || return 1
}
valid_variant() { [[ $1 == none || $1 == klein-4b || $1 == klein-9b ]]; }
valid_hf_token() { [[ $1 =~ ^hf_[A-Za-z0-9]{30,}$ ]]; }
# weight_rows VARIANT: the rows of $KLEIN_WEIGHTS for VARIANT, checked, as
# "folder file size sha256 access url" lines.
weight_rows() {
    local variant folder file size sha access url extra found=0
    while read -r variant folder file size sha access url extra; do
        [[ -n $variant && $variant != \#* && $variant == "$1" ]] || continue
        if ! valid_model_folder "$folder" || ! valid_file_name "$file" || [[ ! $size =~ ^[1-9][0-9]{0,14}$ ]] ||
            [[ ! $sha =~ ^([0-9a-f]{64}|hf)$ ]] || [[ $access != open && $access != gated ]] ||
            [[ ! $url =~ ^https://[^[:space:]\'\"\`\$\\]+$ ]] || [[ -n $extra ]]; then
            printf 'Error: malformed %s row in %s: %s\n' "$1" "$KLEIN_WEIGHTS" "$folder $file" >&2
            return 1
        fi
        printf '%s %s %s %s %s %s\n' "$folder" "$file" "$size" "$sha" "$access" "$url"
        found=1
    done < "$KLEIN_WEIGHTS"
    if (( ! found )); then printf 'Error: %s lists no files for %s.\n' "$KLEIN_WEIGHTS" "$1" >&2; return 1; fi
}
# hf_head URL [HEADER_FILE]: "<status> <X-Linked-Size> <X-Linked-Etag>" of a
# Hugging Face resolve URL, without following its redirect ("-" when absent).
# The token, if any, is read by curl from HEADER_FILE, never from argv.
hf_head() {
    local -a auth=()
    if [[ -n ${2:-} ]]; then auth=(-H "@$2"); fi
    curl -sS --max-time 30 --proto '=https' -I "${auth[@]}" -- "$1" 2>/dev/null | tr -d '\r' | awk '
        tolower($1) ~ /^http\// { status = $2 }
        tolower($1) == "x-linked-size:" { size = $2 }
        tolower($1) == "x-linked-etag:" { etag = $2; gsub(/"/, "", etag) }
        END { printf "%s %s %s\n", status ? status : "000", size ? size : "-", etag ? tolower(etag) : "-" }'
}
# The record of weights already hashed: "folder/file sha256 size mtime" lines,
# root-owned, so a rerun need not hash many GB again.
VERIFIED_WEIGHTS=$TARGET_ETC/verified-weights
record_weight() {
    local temporary
    temporary=$(mktemp "$VERIFIED_WEIGHTS.XXXXXX")
    { grep -v -- "^$1 " "$VERIFIED_WEIGHTS" 2>/dev/null || true; printf '%s\n' "$*"; } > "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$VERIFIED_WEIGHTS"
}
# fetch_weight FOLDER FILE SIZE SHA256 URL [HEADER_FILE]: models/FOLDER/FILE,
# downloaded unless it is there and verified. curl runs as root (only root can
# read the token); every file operation in the service's data directory runs as
# the service account, so root never follows a link it planted there. An
# interrupted download is resumed (here and on a rerun); a wrong hash is removed.
fetch_weight() {
    local folder=$1 name=$2 size=$3 sha=$4 url=$5 headers=${6:-} dir file part have attempt actual stat
    local -a auth=()
    if [[ -n $headers ]]; then auth=(-H "@$headers"); fi
    dir=$TARGET_STATE/models/$folder
    file=$dir/$name
    part=$dir/.$name.part
    as_service mkdir -p -- "$dir"
    if as_service test -e "$file"; then
        stat=$(as_service stat -c '%s %Y' -- "$file")
        if grep -qxF -- "$folder/$name $sha $stat" "$VERIFIED_WEIGHTS" 2>/dev/null; then
            printf 'Have %s (verified).\n' "$file"
            return 0
        fi
        [[ ${stat%% *} == "$size" ]] || die "$file is ${stat%% *} bytes, not $size. Move it aside to download it again."
        printf 'Checking %s...\n' "$file"
        actual=$(as_service sha256sum -- "$file" | awk '{ print $1 }')
        [[ $actual == "$sha" ]] || die "$file has checksum $actual, not $sha. Move it aside to download it again."
        record_weight "$folder/$name" "$sha" "$stat"
        return 0
    fi
    for attempt in 1 2 3 4 5; do
        have=$(as_service stat -c %s -- "$part" 2>/dev/null || echo 0)
        if (( have > size )); then as_service rm -f -- "$part"; have=0; fi
        if (( have == size )); then break; fi
        printf 'Downloading %s (%s of %s MB)...\n' "$name" "$(( have / 1048576 ))" "$(( size / 1048576 ))"
        if curl -fSL --progress-bar --proto '=https' --speed-limit 65536 --speed-time 120 "${auth[@]}" -C "$have" -- "$url" |
                as_service sh -c 'cat >> "$1"' sh "$part"; then
            continue
        fi
        if (( attempt < 5 )); then printf 'The download was interrupted; resuming.\n' >&2; sleep 5; fi
    done
    have=$(as_service stat -c %s -- "$part" 2>/dev/null || echo 0)
    (( have == size )) ||
        die "Downloading $name failed ($have of $size bytes). Rerun install-target.sh to resume it."
    printf 'Checking %s...\n' "$name"
    actual=$(as_service sha256sum -- "$part" | awk '{ print $1 }')
    if [[ $actual != "$sha" ]]; then
        as_service rm -f -- "$part"
        die "Checksum mismatch for $name: got $actual, expected $sha. The download was removed."
    fi
    as_service mv -f -- "$part" "$file"
    record_weight "$folder/$name" "$sha" "$(as_service stat -c '%s %Y' -- "$file")"
    printf 'Installed %s.\n' "$file"
}
# install_weights VARIANT [HEADER_FILE]: the files of VARIANT. Every URL is
# checked (and the gated file's hash settled) and the free space compared with
# what is missing before anything is downloaded.
install_weights() {
    local variant=$1 headers=${2:-} rows folder name size sha access url status linked_size etag
    local entry auth have need=0 avail
    local -a plan=()
    rows=$(weight_rows "$variant") || exit 1
    while read -r folder name size sha access url; do
        auth=''
        if [[ $access == gated ]]; then
            [[ -n $headers ]] ||
                die "$name is gated: give a Hugging Face token (HF_TOKEN_FILE) of an account that accepted the license at ${url%%/resolve/*}."
            auth=$headers
        fi
        read -r status linked_size etag < <(hf_head "$url" "$auth")
        case $status in
            2??|3??) ;;
            401|403) die "Hugging Face refused $name (HTTP $status). Accept the license at ${url%%/resolve/*} with the account the token belongs to, and check that the token can read it." ;;
            *) die "$url did not answer (HTTP $status); check the CT's internet access." ;;
        esac
        [[ $linked_size == - || $linked_size == "$size" ]] ||
            die "$name is now $linked_size bytes upstream, not the reviewed $size. Review it and update $KLEIN_WEIGHTS."
        if [[ $sha == hf ]]; then
            if [[ -n ${COMFYUI_KLEIN_9B_SHA256:-} ]]; then
                sha=${COMFYUI_KLEIN_9B_SHA256,,}
                [[ $etag == - || $etag == "$sha" ]] || die "Hugging Face reports $etag for $name, not COMFYUI_KLEIN_9B_SHA256 $sha."
            else
                [[ $etag =~ ^[0-9a-f]{64}$ ]] ||
                    die "Hugging Face sent no SHA-256 for $name; set COMFYUI_KLEIN_9B_SHA256 to its reviewed hash."
                sha=$etag
            fi
        fi
        plan+=("$folder $name $size $sha $url $auth")
        if ! as_service test -e "$TARGET_STATE/models/$folder/$name"; then
            have=$(as_service stat -c %s -- "$TARGET_STATE/models/$folder/.$name.part" 2>/dev/null || echo 0)
            (( have <= size )) || have=0
            need=$(( need + size - have ))
        fi
    done <<< "$rows"
    avail=$(df -PB1 -- "$TARGET_STATE/models" | awk 'NR == 2 { print $4 }')
    [[ $avail =~ ^[0-9]+$ ]] || die "Cannot read the free space of $TARGET_STATE/models."
    if (( avail < need + 2147483648 )); then
        die "The $variant weights need $(( (need + 1073741823) / 1073741824 )) GB more, plus 2 GB of room, but $TARGET_STATE has $(( avail / 1073741824 )) GB free. Grow the CT's disk (pct resize <CT_ID> rootfs +<N>G) and rerun."
    fi
    for entry in "${plan[@]}"; do
        read -r folder name size sha url auth <<< "$entry"
        fetch_weight "$folder" "$name" "$size" "$sha" "$url" "$auth"
    done
    printf 'The %s weights are installed.\n' "$variant"
}
# End install helpers.

MODE=adopt
case "${1:-}" in
    '') ;;
    --help|-h) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; usage; exit 0 ;;
    --upgrade) [[ $# -eq 1 ]] || { usage >&2; exit 2; }; MODE=upgrade ;;
    *) usage >&2; exit 2 ;;
esac
[[ ${EUID} -eq 0 ]] || die 'Run as root inside the ComfyUI target CT.'
[[ ! -d /etc/pve ]] || die 'This is a Proxmox host. Use provision-lxc.sh here instead.'
[[ -d ${SYSTEMD_RUN_DIR:-/run/systemd/system} ]] || die 'A running systemd environment is required.'
[[ ! -d /app/router ]] || die 'The smart-router installation is present. Use a separate CT for the ComfyUI target.'

COMFYUI_PORT=${COMFYUI_PORT:-}
[[ -z $COMFYUI_PORT ]] || valid_port "$COMFYUI_PORT" || die 'COMFYUI_PORT must be 1..65535.'
COMFYUI_DEVICE=${COMFYUI_DEVICE:-gpu}
[[ $COMFYUI_DEVICE == gpu || $COMFYUI_DEVICE == cpu ]] || die 'COMFYUI_DEVICE must be gpu or cpu.'
READY_TIMEOUT=${READY_TIMEOUT:-300}
UPGRADE_HEALTH_TIMEOUT=${UPGRADE_HEALTH_TIMEOUT:-300}
[[ $READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ && $UPGRADE_HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] ||
    die 'READY_TIMEOUT and UPGRADE_HEALTH_TIMEOUT must be positive numbers of seconds.'
COMFYUI_MODEL_URL=${COMFYUI_MODEL_URL:-}
COMFYUI_MODEL_SHA256=${COMFYUI_MODEL_SHA256:-}
COMFYUI_MODEL_FOLDER=${COMFYUI_MODEL_FOLDER:-checkpoints}
COMFYUI_MODEL_NAME=${COMFYUI_MODEL_NAME:-}
[[ -z $COMFYUI_MODEL_URL || $COMFYUI_MODEL_URL =~ ^https://[^[:space:]\'\"\`\$\\]+$ ]] || die 'COMFYUI_MODEL_URL must be an https URL.'
[[ -z $COMFYUI_MODEL_SHA256 || $COMFYUI_MODEL_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || die 'COMFYUI_MODEL_SHA256 must be 64 hex digits.'
valid_model_folder "$COMFYUI_MODEL_FOLDER" || die 'COMFYUI_MODEL_FOLDER must be a models folder name such as checkpoints or loras.'
if [[ -n $COMFYUI_MODEL_URL && -z $COMFYUI_MODEL_NAME ]]; then COMFYUI_MODEL_NAME=$(model_file_name "$COMFYUI_MODEL_URL"); fi
[[ -z $COMFYUI_MODEL_URL ]] || valid_file_name "$COMFYUI_MODEL_NAME" ||
    die "Cannot use '$COMFYUI_MODEL_NAME' as the model's file name; set COMFYUI_MODEL_NAME."
COMFYUI_VERSION=${COMFYUI_VERSION:-$COMFYUI_DEFAULT_VERSION}
valid_version "$COMFYUI_VERSION" || die 'COMFYUI_VERSION must be a release tag such as v0.42.1.'
COMFYUI_COMMIT=${COMFYUI_COMMIT:-}
if [[ -z $COMFYUI_COMMIT ]]; then
    [[ $COMFYUI_VERSION == "$COMFYUI_DEFAULT_VERSION" ]] ||
        die "Set COMFYUI_COMMIT to the reviewed commit of $COMFYUI_VERSION (tags can be moved upstream)."
    COMFYUI_COMMIT=$COMFYUI_DEFAULT_COMMIT
fi
valid_commit "$COMFYUI_COMMIT" || die 'COMFYUI_COMMIT must be a full 40-digit lowercase SHA-1.'
COMFYUI_TORCH=${COMFYUI_TORCH:-}
[[ -z $COMFYUI_TORCH ]] || valid_torch_build "$COMFYUI_TORCH" || die 'COMFYUI_TORCH must be cuNNN, rocmX.Y, xpu, cpu or pypi.'
FORCE_REBUILD=${FORCE_REBUILD:-false}
[[ $FORCE_REBUILD == true || $FORCE_REBUILD == false ]] || die 'FORCE_REBUILD must be true or false.'
COMFYUI_IMAGE_VARIANT=${COMFYUI_IMAGE_VARIANT:-none}
valid_variant "$COMFYUI_IMAGE_VARIANT" || die 'COMFYUI_IMAGE_VARIANT must be klein-4b, klein-9b or none.'
COMFYUI_KLEIN_9B_SHA256=${COMFYUI_KLEIN_9B_SHA256:-}
[[ -z $COMFYUI_KLEIN_9B_SHA256 || $COMFYUI_KLEIN_9B_SHA256 =~ ^[0-9A-Fa-f]{64}$ ]] || die 'COMFYUI_KLEIN_9B_SHA256 must be 64 hex digits.'
# The Hugging Face token (for the gated 9B file) comes from a file, or from the
# environment; it is taken out of the environment at once.
hf_token=${HF_TOKEN:-}
unset HF_TOKEN
HF_TOKEN_FILE=${HF_TOKEN_FILE:-}
if [[ -z $hf_token && -n $HF_TOKEN_FILE ]]; then
    [[ -r $HF_TOKEN_FILE ]] || die "Cannot read HF_TOKEN_FILE $HF_TOKEN_FILE."
    hf_token=$(tr -d '\r\n' < "$HF_TOKEN_FILE")
fi
[[ -z $hf_token ]] || valid_hf_token "$hf_token" || die 'The Hugging Face token must be an access token (hf_...).'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in comfyui-target.conf comfyui.env.example README.md; do
    [[ -r $source_dir/$file ]] || die "Missing deployment file: $source_dir/$file"
done
KLEIN_WEIGHTS=${KLEIN_WEIGHTS:-$source_dir/klein-weights.txt}
if [[ $MODE == adopt && $COMFYUI_IMAGE_VARIANT != none ]]; then
    [[ -r $KLEIN_WEIGHTS ]] || die "Missing deployment file: $KLEIN_WEIGHTS"
    rows=$(weight_rows "$COMFYUI_IMAGE_VARIANT") || exit 1
    if [[ -z $hf_token && $rows == *' gated '* ]]; then
        die "$COMFYUI_IMAGE_VARIANT is gated on Hugging Face: set HF_TOKEN_FILE to a file with the token of an account that accepted its license."
    fi
fi
# The token reaches curl only through a root-only header file.
hf_headers=''
if [[ -n $hf_token ]]; then
    header_dir=$(mktemp -d "${TMPDIR:-/tmp}/comfyui-target-hf.XXXXXX")
    trap 'rm -rf -- "$header_dir"' EXIT
    ( umask 077; printf 'Authorization: Bearer %s\n' "$hf_token" > "$header_dir/headers" )
    hf_headers=$header_dir/headers
fi
unset hf_token

# One run at a time: two would race on the current link and the unit.
exec {lock_fd}>"$LOCK_FILE"
flock -n "$lock_fd" || die "Another install-target.sh holds $LOCK_FILE."

if [[ $MODE == upgrade ]]; then
    [[ -f $DROPIN && -f $TARGET_ENV && -L $CURRENT ]] ||
        die 'This target has not been adopted yet; run install-target.sh without --upgrade first.'
    previous=$(readlink -f -- "$CURRENT")
    want=${COMFYUI_VERSION#v}
    printf 'Installed ComfyUI: %s (%s)\nRequested: %s (%s)\n' "$(release_version "$previous")" \
        "$(release_commit "$previous" | grep . || echo 'community install, commit not verified')" "$want" "$COMFYUI_COMMIT"
    state=$(systemctl show "$SERVICE" -p ActiveState --value)
    dropin_same=false
    if cmp -s -- "$source_dir/comfyui-target.conf" "$DROPIN"; then dropin_same=true; fi
    # The requested release is the running one: nothing to build or restart,
    # unless the server does not answer as that version.
    if [[ $(release_commit "$previous") == "$COMFYUI_COMMIT" ]] && $dropin_same && [[ $FORCE_REBUILD == false ]]; then
        if [[ $state == inactive ]]; then
            printf 'ComfyUI %s is already installed; nothing to do (the service stays stopped).\n' "$COMFYUI_VERSION"
            exit 0
        elif systemctl is-active --quiet "$SERVICE" && [[ $(served_version || true) == "$want" ]]; then
            printf 'ComfyUI %s is already installed and serving; nothing to do.\n' "$COMFYUI_VERSION"
            exit 0
        fi
        printf 'ComfyUI %s is installed but the server does not answer as that version; rebuilding it.\n' "$COMFYUI_VERSION"
    fi

    # --- prepare: everything that can fail before ComfyUI is stopped ---------------
    if ! command -v git >/dev/null; then
        printf 'Installing git...\n'
        { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends git ca-certificates; } ||
            die 'Could not install git; ComfyUI was not stopped or changed.'
    fi
    command -v uv >/dev/null || die 'uv is missing (the community install provides /usr/local/bin/uv); ComfyUI was not stopped or changed.'
    build=${COMFYUI_TORCH:-$(torch_build "$previous/venv")}
    [[ -n $build ]] || die "Cannot tell which PyTorch build $previous/venv uses; set COMFYUI_TORCH (e.g. cu130, rocm7.2, xpu, cpu, pypi)."
    valid_torch_build "$build" || die "Unexpected PyTorch build '$build' in $previous/venv; set COMFYUI_TORCH."
    python=$(venv_interpreter "$previous/venv")
    [[ -x $python ]] && ! private_interpreter "$python" ||
        die "The current release's Python ($python) is not usable for a new build; run install-target.sh without --upgrade first."
    new=$RELEASES/${COMFYUI_VERSION}-${COMFYUI_COMMIT:0:12}-$(date +%Y%m%d%H%M%S)
    install -d -m 0755 "$RELEASES"
    printf 'Building ComfyUI %s with PyTorch %s in %s while the current release keeps running...\n' "$COMFYUI_VERSION" "$build" "$new"
    if ! ( umask 022; build_release "$COMFYUI_VERSION" "$COMFYUI_COMMIT" "$new.part" "$build" "$python" ); then
        rm -rf -- "$new.part"
        die "Preparing ComfyUI $COMFYUI_VERSION failed; ComfyUI was not stopped or changed."
    fi
    mv -- "$new.part" "$new"

    # --- switch, with rollback -----------------------------------------------------
    was_active=false
    [[ $state != inactive ]] && was_active=true
    # What the running server reports now, so a rollback can check for it.
    previous_version=''
    if $was_active; then previous_version=$(served_version || true); fi
    # The upgrade changes only the current link (and the drop-in when this
    # repository's copy is newer); comfyui.env and the data are untouched. So
    # that is all a rollback puts back; it then checks the previous release.
    rollback() {
        printf 'Upgrade failed; restoring the previous release...\n' >&2
        systemctl stop "$SERVICE" 2>/dev/null || true
        set_current "$previous"
        if [[ -f $DROPIN.prev ]]; then mv -f -- "$DROPIN.prev" "$DROPIN"; fi
        systemctl daemon-reload 2>/dev/null || true
        rm -rf -- "$new"
        if ! $was_active; then
            printf 'Upgrade failed; the previous release is back, and the service stays stopped as it was.\n' >&2
        elif systemctl start "$SERVICE" && wait_for_version "$previous_version" "$UPGRADE_HEALTH_TIMEOUT"; then
            printf 'Upgrade failed; the previous release%s is running again.\n' "${previous_version:+ ($previous_version)}" >&2
        else
            printf 'Upgrade failed, and the previous release did not answer either; see journalctl -u %s.\n' "$SERVICE" >&2
        fi
    }
    # With set -E a failure inside a ( ... ) subshell fires this trap in the
    # subshell and again in the parent; only the main shell rolls back.
    trap '[[ $BASHPID == "$$" ]] || exit 1; rollback; exit 1' ERR
    if $was_active; then systemctl stop "$SERVICE"; fi
    if ! $dropin_same; then
        cp -p -- "$DROPIN" "$DROPIN.prev"
        install -m 0644 "$source_dir/comfyui-target.conf" "$DROPIN"
    fi
    systemctl daemon-reload
    set_current "$new"
    if $was_active; then
        systemctl start "$SERVICE"
        printf 'Waiting for ComfyUI %s to answer...\n' "$COMFYUI_VERSION"
        wait_for_version "$want" "$UPGRADE_HEALTH_TIMEOUT" || false
        printf 'ComfyUI %s is serving; models and settings are unchanged.\n' "$COMFYUI_VERSION"
    else
        printf 'The service was stopped before the upgrade and is left stopped.\n'
    fi
    trap - ERR
    rm -f -- "$DROPIN.prev"
    prune_releases "$new" "$previous"
    if [[ $previous != "$COMMUNITY_DIR" && -d $COMMUNITY_DIR/venv ]]; then
        # The community tree is two releases back now; its venv is several GB.
        rm -rf -- "$COMMUNITY_DIR/venv"
        printf 'Removed the community install'"'"'s venv (%s/venv).\n' "$COMMUNITY_DIR"
    fi
    printf 'Upgrade complete. The previous release is kept as %s.\n' "$previous"
    exit 0
fi

# --- adopt (idempotent) ---------------------------------------------------------
if [[ -L $CURRENT ]]; then
    release=$(readlink -f -- "$CURRENT")
elif [[ -f $COMMUNITY_DIR/main.py && -x $COMMUNITY_DIR/venv/bin/python ]]; then
    release=$COMMUNITY_DIR
else
    die "No community-script ComfyUI install found ($COMMUNITY_DIR/main.py and its venv). Create the CT with provision-lxc.sh first."
fi
[[ -f $release/main.py && -e $release/venv/bin/python ]] || die "$CURRENT points to $release, which is not a ComfyUI release."
[[ -f $TARGET_UNITS/$SERVICE ]] || die "No $SERVICE in $TARGET_UNITS. Create the CT with provision-lxc.sh first."

getent group "$TARGET_USER" >/dev/null || groupadd --system "$TARGET_USER"
getent passwd "$TARGET_USER" >/dev/null || \
    useradd --system --gid "$TARGET_USER" --home-dir "$TARGET_STATE" --no-create-home --shell /usr/sbin/nologin "$TARGET_USER"
# Passed-through GPU device nodes are group video (gid 44) or render in the CT.
for group in video render; do
    if getent group "$group" >/dev/null; then usermod -a -G "$group" "$TARGET_USER"; fi
done
install -d -o root -g "$TARGET_USER" -m 0750 "$TARGET_ETC"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0750 "$TARGET_STATE"
install -o root -g root -m 0644 "$source_dir/README.md" "$TARGET_ETC/README.md"
if [[ -f $TARGET_ENV ]]; then
    printf 'Keeping existing %s\n' "$TARGET_ENV"
    ensure_env_key "$TARGET_ENV" COMFYUI_LISTEN 0.0.0.0
    ensure_env_key "$TARGET_ENV" COMFYUI_PORT "${COMFYUI_PORT:-8188}"
    ensure_env_key "$TARGET_ENV" COMFYUI_EXTRA_ARGS ''
    configured=$(env_value "$TARGET_ENV" COMFYUI_PORT)
    if [[ -n $COMFYUI_PORT && $configured != "$COMFYUI_PORT" ]]; then
        printf 'Note: %s sets COMFYUI_PORT=%s; COMFYUI_PORT=%s is not applied (edit the file to change it).\n' \
            "$TARGET_ENV" "$configured" "$COMFYUI_PORT"
    fi
else
    install -o root -g "$TARGET_USER" -m 0640 "$source_dir/comfyui.env.example" "$TARGET_ENV"
    if [[ -n $COMFYUI_PORT ]]; then sed -i -E "s/^COMFYUI_PORT=.*/COMFYUI_PORT=$COMFYUI_PORT/" "$TARGET_ENV"; fi
    if [[ $COMFYUI_DEVICE == cpu ]]; then sed -i -E 's/^COMFYUI_EXTRA_ARGS=.*/COMFYUI_EXTRA_ARGS=--cpu/' "$TARGET_ENV"; fi
fi

if [[ $(systemctl show "$SERVICE" -p ActiveState --value) != inactive ]]; then systemctl stop "$SERVICE"; fi
install -d -m 0755 "$TARGET_OPT" "$RELEASES"
relocate_interpreter "$release/venv"
usable_by_service "$release/venv" ||
    die "The $TARGET_USER account cannot run $release/venv/bin/python ($(venv_interpreter "$release/venv"))."
[[ -L $CURRENT ]] || set_current "$release"
adopt_data "$COMMUNITY_DIR" "$TARGET_STATE"
for dir in $DATA_DIRS; do install -d -m 0750 "$TARGET_STATE/$dir"; done
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_STATE"
install -d -o root -g root -m 0755 "$(dirname -- "$DROPIN")"
install -o root -g root -m 0644 "$source_dir/comfyui-target.conf" "$DROPIN"
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
printf 'Waiting for ComfyUI on %s (the first start can take a minute)...\n' "$(api_base)"
wait_for_version '' "$READY_TIMEOUT" || {
    systemctl status "$SERVICE" --no-pager --lines=40 || true
    die "$SERVICE did not answer on $(api_base)/system_stats within ${READY_TIMEOUT}s after adoption. Without a usable GPU, set COMFYUI_EXTRA_ARGS=--cpu in $TARGET_ENV and restart it."
}
device=$(served_device || true)
printf '\nComfyUI %s is serving as %s on %s (device: %s).\n' "$(served_version)" "$TARGET_USER" "$(api_base)" "${device:-unknown}"
if [[ $COMFYUI_DEVICE == gpu && $device == cpu ]]; then
    printf 'Warning: ComfyUI runs on the CPU. If the CT should have a GPU, check nvidia-smi in it.\n'
fi
if [[ -n $COMFYUI_MODEL_URL ]]; then
    fetch_model "$COMFYUI_MODEL_URL" "$COMFYUI_MODEL_NAME" "$COMFYUI_MODEL_FOLDER" "$COMFYUI_MODEL_SHA256"
fi
if [[ $COMFYUI_IMAGE_VARIANT != none ]]; then
    install_weights "$COMFYUI_IMAGE_VARIANT" "$hf_headers"
fi
cat <<DONE
  Settings:  $TARGET_ENV, then: systemctl restart $SERVICE
  Models:    $TARGET_STATE/models/<folder> (checkpoints, loras, vae, ...), owned by $TARGET_USER
  Outputs:   $TARGET_STATE/output
  Running:   $(readlink -f -- "$CURRENT")
  Upgrade:   bash install-target.sh --upgrade   (pinned $COMFYUI_DEFAULT_VERSION, with rollback)
DONE
