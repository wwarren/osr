#!/usr/bin/env bash
# Exercise install-target.sh against a temporary tree that looks like a fresh
# community-script CT (/opt/ComfyUI with a uv venv whose Python lives under
# root's home): helpers in isolation, adoption (and re-running it), and
# --upgrade with commit verification, a side-by-side build and rollback.
# systemctl, curl, git, uv, runuser and the account tools are stubs; nothing is
# downloaded, installed or started.
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/comfyui-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/comfyui-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in valid_version valid_commit valid_port valid_model_folder valid_file_name valid_torch_build model_file_name \
    env_value ensure_env_key api_base served_version served_device wait_for_version release_version release_commit \
    torch_build torch_index_args venv_interpreter private_interpreter relocate_interpreter as_service usable_by_service \
    adopt_data set_current prune_releases fetch_model build_release valid_variant valid_hf_token weight_rows hf_head \
    record_weight fetch_weight install_weights; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done

valid_version v0.42.1 && ! valid_version 0.42.1 && ! valid_version latest || die valid_version
valid_commit 63be2f9b82ad0dac88a7ceaa28a9cf3154125a18 && ! valid_commit 63be2f9 && ! valid_commit "$(printf 'A%.0s' {1..40})" || die valid_commit
valid_model_folder checkpoints && valid_model_folder text_encoders && ! valid_model_folder ../etc && ! valid_model_folder 'a b' || die valid_model_folder
valid_file_name sd_xl_base_1.0.safetensors && ! valid_file_name ../x && ! valid_file_name .hidden && ! valid_file_name 'a b' || die valid_file_name
for build in pypi cpu xpu cu130 cu128 rocm7.2 rocm6; do valid_torch_build "$build" || die "valid_torch_build $build"; done
! valid_torch_build cuda && ! valid_torch_build 'cu130 x' || die 'valid_torch_build accepted a bad build'
[[ $(model_file_name 'https://h.test/o/r/resolve/main/sd_xl_base_1.0.safetensors?download=true') == sd_xl_base_1.0.safetensors ]] || die model_file_name
pass 'input validation'

venv=$tmp_root/venv-a
mkdir -p "$venv/lib/python3.12/site-packages/torch-2.9.0+cu130.dist-info" "$venv/lib/python3.12/site-packages/torchvision-0.24.0+cu130.dist-info"
[[ $(torch_build "$venv") == cu130 ]] || die "torch_build cu130: $(torch_build "$venv")"
mkdir -p "$tmp_root/venv-b/lib/python3.12/site-packages/torch-2.9.0.dist-info"
[[ $(torch_build "$tmp_root/venv-b") == pypi ]] || die 'torch_build pypi'
[[ -z $(torch_build "$tmp_root/none") ]] || die 'torch_build without torch'
# shellcheck disable=SC2034  # read by the sourced helpers
TORCH_INDEX_BASE=https://torch.test/whl
[[ $(torch_index_args cu130 | paste -sd' ') == '--extra-index-url https://torch.test/whl/cu130' ]] || die 'cuda index'
[[ $(torch_index_args rocm7.2 | paste -sd' ') == '--index-url https://torch.test/whl/rocm7.2' ]] || die 'rocm index'
[[ -z $(torch_index_args pypi) ]] || die 'pypi index'
pass "the current venv's PyTorch build selects the index for a new one"

TARGET_ENV=$tmp_root/env
printf 'COMFYUI_PORT=8190\n' > "$TARGET_ENV"
[[ $(api_base) == http://127.0.0.1:8190 ]] || die "api_base: $(api_base)"
printf 'COMFYUI_PORT=nope\n' > "$TARGET_ENV"
[[ $(api_base) == http://127.0.0.1:8188 ]] || die 'api_base default port'
ensure_env_key "$TARGET_ENV" COMFYUI_PORT 1; ensure_env_key "$TARGET_ENV" COMFYUI_EXTRA_ARGS ''
[[ $(env_value "$TARGET_ENV" COMFYUI_PORT) == nope && $(grep -c '^COMFYUI_EXTRA_ARGS=$' "$TARGET_ENV") == 1 ]] || die ensure_env_key
curl() { printf '%s' '{"system": {"os": "linux", "comfyui_version": "0.42.1", "argv": ["main.py", "--port", "8188"]}, "devices": [{"name": "cuda:0 NVIDIA RTX, A", "type": "cuda", "index": 0}, {"name": "cpu", "type": "cpu"}]}'; }
[[ $(served_version) == 0.42.1 && $(served_device) == cuda ]] || die "system_stats parsing: $(served_version) $(served_device)"
curl() { return 7; }
[[ -z $(served_version) ]] && ! wait_for_version '' 0 || die 'a silent server was taken as answering'
unset -f curl
pass '/system_stats parsing and settings helpers'

mkdir -p "$tmp_root/rel/x"; printf '# generated\n__version__ = "0.41.0"\n' > "$tmp_root/rel/x/comfyui_version.py"
[[ $(release_version "$tmp_root/rel/x") == 0.41.0 && -z $(release_commit "$tmp_root/rel/x") ]] || die release_version
CURRENT=$tmp_root/rel/current RELEASES=$tmp_root/rel/releases
mkdir -p "$RELEASES/a" "$RELEASES/b" "$RELEASES/c.part"
set_current "$RELEASES/a"; set_current "$RELEASES/b"
[[ $(readlink "$CURRENT") == "$RELEASES/b" && ! -e $CURRENT.new ]] || die set_current
prune_releases "$RELEASES/b" "$tmp_root/rel/x"
[[ -d $RELEASES/b && ! -e $RELEASES/a && ! -e $RELEASES/c.part ]] || die prune_releases
pass 'the current link switches in one rename; pruning keeps only what it is told'

src=$tmp_root/community dest=$tmp_root/data
mkdir -p "$src/models/checkpoints" "$src/models/configs" "$src/models/loras" "$src/input" "$src/custom_nodes" "$src/user/default" "$dest/models/checkpoints"
: > "$src/models/checkpoints/put_checkpoints_here"
echo weights > "$src/models/checkpoints/mine.safetensors"
echo theirs > "$src/models/checkpoints/kept.safetensors"; echo ours > "$dest/models/checkpoints/kept.safetensors"
echo cfg > "$src/models/configs/v1-inference.yaml"
echo png > "$src/input/example.png"; echo node > "$src/custom_nodes/websocket_image_save.py"; echo '{}' > "$src/user/default/comfy.settings.json"
# shellcheck disable=SC2034  # read by the sourced helpers
DATA_DIRS="models custom_nodes input output temp user"
out=$(adopt_data "$src" "$dest")
[[ $(cat "$dest/models/checkpoints/mine.safetensors") == weights && ! -e $src/models/checkpoints/mine.safetensors ]] || die 'models not moved'
[[ $(cat "$dest/models/checkpoints/kept.safetensors") == ours && -e $src/models/checkpoints/kept.safetensors ]] || die 'a file was replaced'
[[ -f $dest/models/configs/v1-inference.yaml && -f $src/models/configs/v1-inference.yaml ]] || die 'model configs must be copied'
[[ -f $dest/input/example.png && -f $src/input/example.png && -f $dest/user/default/comfy.settings.json ]] || die 'data not copied'
[[ -d $dest/models/loras && ! -e $dest/models/checkpoints/put_checkpoints_here ]] || die 'folder skeleton / placeholders'
[[ $out == *'moved 1 model file(s), copied 4 other file(s)'* ]] || die "adopt_data report: $out"
pass 'community data: models moved, release files copied, nothing replaced, placeholders skipped'

# uv's layout: the venv links to a minor-version directory that links to the patch release.
uvdir=$tmp_root/roothome/.local/share/uv/python
mkdir -p "$uvdir/cpython-3.12.12-linux-x86_64-gnu/bin" "$uvdir/cpython-3.12.12-linux-x86_64-gnu/lib/python3.12"
printf '#!/bin/sh\nexit 0\n' > "$uvdir/cpython-3.12.12-linux-x86_64-gnu/bin/python3.12"; chmod 0700 "$uvdir/cpython-3.12.12-linux-x86_64-gnu/bin/python3.12"
ln -s cpython-3.12.12-linux-x86_64-gnu "$uvdir/cpython-3.12-linux-x86_64-gnu"
venv=$tmp_root/rv; mkdir -p "$venv/bin"
ln -s "$uvdir/cpython-3.12-linux-x86_64-gnu/bin/python3.12" "$venv/bin/python"; ln -s python "$venv/bin/python3"
printf 'home = %s/cpython-3.12-linux-x86_64-gnu/bin\nimplementation = CPython\nversion_info = 3.12.12\n' "$uvdir" > "$venv/pyvenv.cfg"
# shellcheck disable=SC2034  # read by the sourced helpers
TARGET_OPT=$tmp_root/optt PRIVATE_PREFIXES=$tmp_root/roothome
out=$(relocate_interpreter "$venv")
copy=$TARGET_OPT/python/cpython-3.12.12-linux-x86_64-gnu
[[ $(venv_interpreter "$venv") == "$copy/bin/python3.12" ]] || die "venv not repointed: $(venv_interpreter "$venv")"
[[ $(readlink -f "$venv/bin/python3") == "$copy/bin/python3.12" && -d $copy/lib/python3.12 ]] || die 'python3 link or stdlib'
grep -qx "home = $copy/bin" "$venv/pyvenv.cfg" && grep -qx 'version_info = 3.12.12' "$venv/pyvenv.cfg" || die "pyvenv.cfg: $(cat "$venv/pyvenv.cfg")"
[[ $(stat -c %a "$copy/bin/python3.12") == 755 ]] || die 'the copy must be executable by others'
! private_interpreter "$(venv_interpreter "$venv")" || die 'still private'
[[ -z $(relocate_interpreter "$venv") ]] || die 'relocation is not idempotent'
pass "uv's Python under /root is copied out and the venv repointed (minor-version links included)"

KLEIN_WEIGHTS=$script_dir/klein-weights.txt
for variant in klein-4b klein-9b; do
    rows=$(weight_rows "$variant") || die "the shipped manifest has a malformed $variant row"
    [[ $(wc -l <<< "$rows") == 3 && $(cut -d' ' -f1 <<< "$rows" | paste -sd' ') == 'diffusion_models text_encoders vae' ]] ||
        die "$variant must list a diffusion model, a text encoder and a VAE: $rows"
done
rows_9b=$(weight_rows klein-9b); rows_4b=$(weight_rows klein-4b)
[[ $(grep -c ' gated https:' "$KLEIN_WEIGHTS") == 1 && $rows_9b == *$'\n'* &&
    $(grep '^diffusion_models ' <<< "$rows_9b") == *' hf gated https://huggingface.co/black-forest-labs/'* ]] ||
    die 'only the 9B diffusion model is gated (and it carries no hash of its own)'
[[ $rows_4b != *' gated '* && $rows_4b != *' hf '* ]] || die 'every 4B file is open and hash-pinned'
! weight_rows sdxl 2>/dev/null || die 'an unknown variant has rows'
valid_variant none && valid_variant klein-9b && ! valid_variant sdxl || die valid_variant
valid_hf_token "hf_$(printf 'a%.0s' {1..34})" && ! valid_hf_token hf_short && ! valid_hf_token "$(printf 'a%.0s' {1..37})" || die valid_hf_token
pass 'the shipped weights manifest: three pinned files per variant; only the 9B diffusion model is gated'

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
bin=$tmp_root/bin; mkdir -p "$bin" "$tmp_root/run"
log=$tmp_root/calls.log
upstream=$tmp_root/upstream
downloads=$tmp_root/downloads
hf=$tmp_root/hf
running=$tmp_root/running
optt=$tmp_root/optt
community=$tmp_root/opt/ComfyUI
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for command_name in getent groupadd useradd usermod sleep apt-get; do stub "$command_name" 'exit 0'; done
stub runuser 'shift 2; [[ $1 == -- ]] && shift; exec "$@"'
# systemd: start/restart make the server "run" (unless FAKE_START_FAIL), stop ends it.
stub systemctl 'case "$1" in
    start|restart) [[ -n ${FAKE_START_FAIL:-} ]] && exit 1; touch "'"$running"'" ;;
    stop) rm -f "'"$running"'" ;;
    show) if [[ -n ${FAKE_ACTIVE_STATE:-} ]]; then echo "$FAKE_ACTIVE_STATE"
          elif [[ -e "'"$running"'" ]]; then echo active; else echo inactive; fi ;;
    is-active) [[ -e "'"$running"'" && ${FAKE_ACTIVE_STATE:-} != failed ]] ;;
esac'
# curl: downloads come from $downloads; /system_stats answers while "running",
# as the version of the release current points to, unless that version is FAKE_BROKEN.
# curl: Hugging Face (https://hf.test) serves $hf/<file>: HEAD gives its size
# and SHA-256 (X-Linked-Etag); a GET honours -C; files in FAKE_GATED need the
# header file with FAKE_HF_TOKEN; FAKE_CUT cuts the first transfer short. Other
# downloads come from $downloads; /system_stats answers while "running", as the
# version of the release current points to, unless that version is FAKE_BROKEN.
stub curl 'out=""; url="${@: -1}"; head=0; header=""; offset=0; prev=""
for a in "$@"; do
    [[ $prev == -o ]] && out=$a; [[ $prev == -H ]] && header=${a#@}; [[ $prev == -C ]] && offset=$a
    [[ $a == -I ]] && head=1; prev=$a
done
if [[ $url == https://hf.test/* ]]; then
    file="'"$hf"'/${url##*/}"
    if [[ " ${FAKE_GATED:-} " == *" ${url##*/} "* ]] && ! grep -qx "Authorization: Bearer ${FAKE_HF_TOKEN:-none}" "$header" 2>/dev/null; then
        if (( head )); then printf "HTTP/2 403\r\n\r\n"; exit 0; fi
        exit 22
    fi
    if (( head )); then
        printf "HTTP/2 302\r\nX-Linked-Size: %s\r\nX-Linked-Etag: \"%s\"\r\nLocation: https://cdn.test/x\r\n\r\n" \
            "$(stat -c %s "$file")" "${FAKE_ETAG:-$(sha256sum "$file" | cut -d" " -f1)}"
        exit 0
    fi
    if [[ -n ${FAKE_CUT:-} && ! -e "'"$tmp_root"'/cut-done" ]]; then
        touch "'"$tmp_root"'/cut-done"; tail -c +$((offset + 1)) "$file" | head -c "$FAKE_CUT"; exit 18
    fi
    tail -c +$((offset + 1)) "$file"; exit 0
fi
if [[ -n $out ]]; then name=${url%%\?*}; cp -- "'"$downloads"'/${name##*/}" "$out"; exit; fi
[[ -e "'"$running"'" ]] || exit 7
release="'"$community"'"; [[ -L "'"$optt"'/current" ]] && release=$(readlink -f "'"$optt"'/current")
version=$(sed -nE "s/^__version__ = \"(.*)\"/\1/p" "$release/comfyui_version.py")
[[ ${FAKE_BROKEN:-} == all || ${FAKE_BROKEN:-} == "$version" ]] && exit 7
printf "{\"system\": {\"comfyui_version\": \"%s\"}, \"devices\": [{\"name\": \"x\", \"type\": \"%s\"}]}" "$version" "${FAKE_DEVICE:-cuda}"'
stub df 'printf "Filesystem 1B-blocks Used Available Capacity Mounted on\n/dev/x 1 1 %s 1%% /\n" "${FAKE_DF_AVAIL:-1000000000000000}"'
# git: a clone copies $upstream/<tag>; HEAD is $upstream/<tag>.commit.
stub git 'if [[ $* == *" clone "* || $3 == clone ]]; then
    dir="${@: -1}"; tag=""; prev=""
    for a in "$@"; do [[ $prev == --branch ]] && tag=$a; prev=$a; done
    [[ -d "'"$upstream"'/$tag" ]] || exit 128
    cp -a "'"$upstream"'/$tag" "$dir"; mkdir -p "$dir/.git"; cp "'"$upstream"'/$tag.commit" "$dir/.git/HEAD"; exit 0
fi
if [[ $1 == -C && $3 == rev-parse ]]; then cat "$2/.git/HEAD"; exit 0; fi
exit 1'
# uv: venv links the given Python; pip install of torch records the build it was given.
stub uv '[[ -n ${FAKE_UV_FAIL:-} && $1 == pip ]] && exit 1
if [[ $1 == venv ]]; then
    py=""; prev=""; for a in "$@"; do [[ $prev == --python ]] && py=$a; prev=$a; done
    dir="${@: -1}"; mkdir -p "$dir/bin"; ln -s "$py" "$dir/bin/python"; printf "home = %s\n" "${py%/*}" > "$dir/pyvenv.cfg"; exit 0
fi
py=""; index=""; prev=""; for a in "$@"; do
    [[ $prev == --python ]] && py=$a; [[ $prev == --*index-url ]] && index=${a##*/}; prev=$a; done
venv=${py%/bin/python}
if [[ $* == *" torch torchvision torchaudio"* ]]; then mkdir -p "$venv/lib/python3.12/site-packages/torch-2.9.0${index:++$index}.dist-info"; fi
exit 0'

commit_a=63be2f9b82ad0dac88a7ceaa28a9cf3154125a18     # the default pin, v0.42.1
commit_b=$(printf 'b%.0s' {1..40})
# make_upstream TAG COMMIT: the tree a clone of TAG gives.
make_upstream() {
    local tag=$1 dir=$upstream/$1
    rm -rf "$dir"; mkdir -p "$dir"
    printf '# generated\n__version__ = "%s"\n' "${tag#v}" > "$dir/comfyui_version.py"
    echo 'print("comfyui")' > "$dir/main.py"; echo torch > "$dir/requirements.txt"
    echo "$2" > "$dir.commit"
}
# community_ct: what ct/comfyui.sh leaves: /opt/ComfyUI 0.41.0 with a uv venv
# whose Python is under root's home, data in the tree, the unit running as root.
community_ct() {
    rm -rf "${tmp_root:?}/opt" "${tmp_root:?}/etc" "${tmp_root:?}/state" "${tmp_root:?}/units" "${optt:?}" "${tmp_root:?}/rh" "$running"
    local py=$tmp_root/rh/.local/share/uv/python/cpython-3.12.12-linux-x86_64-gnu
    mkdir -p "$py/bin" "$py/lib/python3.12" "$community/venv/bin" "$community/venv/lib/python3.12/site-packages/torch-2.9.0+cu130.dist-info" \
        "$community/models/checkpoints" "$community/models/configs" "$community/custom_nodes" "$community/input" "$tmp_root/units"
    printf '#!/bin/sh\n[ "$2" = "import sys" ] && exit 0\nexit "${FAKE_IMPORT_RC:-0}"\n' > "$py/bin/python3.12"; chmod 0700 "$py/bin/python3.12"
    ln -s cpython-3.12.12-linux-x86_64-gnu "$tmp_root/rh/.local/share/uv/python/cpython-3.12-linux-x86_64-gnu"
    ln -s "$tmp_root/rh/.local/share/uv/python/cpython-3.12-linux-x86_64-gnu/bin/python3.12" "$community/venv/bin/python"
    printf 'home = %s/rh/.local/share/uv/python/cpython-3.12-linux-x86_64-gnu/bin\n' "$tmp_root" > "$community/venv/pyvenv.cfg"
    printf '# generated\n__version__ = "0.41.0"\n' > "$community/comfyui_version.py"
    echo 'print("comfyui")' > "$community/main.py"
    : > "$community/models/checkpoints/put_checkpoints_here"; echo cfg > "$community/models/configs/v1-inference.yaml"
    echo weights > "$community/models/checkpoints/early.safetensors"
    printf '[Service]\nUser=root\nExecStart=/opt/ComfyUI/venv/bin/python /opt/ComfyUI/main.py --listen --port 8188\n' > "$tmp_root/units/comfyui.service"
    touch "$running"
    : > "$log"
}
target() {
    env -i "PATH=$bin:/usr/bin:/bin" TARGET_ETC="$tmp_root/etc" TARGET_STATE="$tmp_root/state" TARGET_OPT="$optt" \
        TARGET_UNITS="$tmp_root/units" TARGET_USER=root COMMUNITY_DIR="$community" PRIVATE_PREFIXES="$tmp_root/rh" \
        COMFYUI_REPO=https://github.test/Comfy-Org/ComfyUI.git TORCH_INDEX_BASE=https://torch.test/whl \
        LOCK_FILE="$tmp_root/lock" SYSTEMD_RUN_DIR="$tmp_root/run" READY_TIMEOUT=6 UPGRADE_HEALTH_TIMEOUT=6 \
        FAKE_BROKEN="${FAKE_BROKEN:-}" FAKE_ACTIVE_STATE="${FAKE_ACTIVE_STATE:-}" FAKE_START_FAIL="${FAKE_START_FAIL:-}" \
        FAKE_UV_FAIL="${FAKE_UV_FAIL:-}" FAKE_IMPORT_RC="${FAKE_IMPORT_RC:-0}" FAKE_DEVICE="${FAKE_DEVICE:-cuda}" \
        "$@" bash "$script_dir/install-target.sh" ${ARGS:-}
}
dropin=$tmp_root/units/comfyui.service.d/10-comfyui-target.conf
current() { readlink -f "$optt/current"; }

community_ct
mkdir -p "$downloads"; echo 'sdxl weights' > "$downloads/sd_xl_base_1.0.safetensors"
sha=$(sha256sum "$downloads/sd_xl_base_1.0.safetensors" | awk '{ print $1 }')
out=$(target COMFYUI_DEVICE=cpu COMFYUI_PORT=8188 COMFYUI_MODEL_URL='https://h.test/o/r/resolve/main/sd_xl_base_1.0.safetensors?download=true' \
    COMFYUI_MODEL_SHA256="$sha" 2>&1) || die "adoption failed: $out"
cmp -s "$script_dir/comfyui-target.conf" "$dropin" || die 'drop-in not installed'
[[ $(cat "$tmp_root/units/comfyui.service") == *'User=root'* ]] || die 'community unit was edited'
[[ $(stat -c %a "$tmp_root/etc/comfyui.env") == 640 ]] || die 'env file must be 0640'
grep -qx 'COMFYUI_EXTRA_ARGS=--cpu' "$tmp_root/etc/comfyui.env" && grep -qx 'COMFYUI_PORT=8188' "$tmp_root/etc/comfyui.env" || die 'env settings'
[[ $(current) == "$community" ]] || die 'current does not point at the community tree'
[[ $(readlink -f "$community/venv/bin/python") == "$optt/python/cpython-3.12.12-linux-x86_64-gnu/bin/python3.12" ]] || die 'interpreter not relocated'
[[ $(cat "$tmp_root/state/models/checkpoints/early.safetensors") == weights && -f $tmp_root/state/models/configs/v1-inference.yaml ]] || die 'data not adopted'
for dir in models custom_nodes input output temp user; do [[ -d $tmp_root/state/$dir ]] || die "missing data folder $dir"; done
[[ $(cat "$tmp_root/state/models/checkpoints/sd_xl_base_1.0.safetensors") == 'sdxl weights' ]] || die 'model not downloaded'
grep -q 'systemctl restart comfyui.service' "$log" || die 'service not restarted'
[[ $out == *'ComfyUI 0.41.0 is serving as root'*'(device: cuda)'* ]] || die "adoption report: $out"
pass 'adoption: drop-in, env file, Python moved out of /root, data adopted, unit untouched, model downloaded and verified'

echo 'COMFYUI_EXTRA_ARGS=--lowvram' >> "$tmp_root/etc/comfyui.env"
out=$(target COMFYUI_PORT=8190 COMFYUI_MODEL_URL=https://h.test/o/r/resolve/main/sd_xl_base_1.0.safetensors COMFYUI_MODEL_SHA256="$sha" 2>&1) ||
    die "re-running adoption failed: $out"
[[ $(env_value "$tmp_root/etc/comfyui.env" COMFYUI_EXTRA_ARGS) == --lowvram ]] || die 'settings rewritten on re-run'
[[ $out == *'COMFYUI_PORT=8190 is not applied'* && $out == *'Keeping the existing'* ]] || die "re-run report: $out"
pass 'adoption is safe to re-run: settings and models kept, a different port is reported, not applied'

out=$(target COMFYUI_MODEL_URL=https://h.test/o/r/resolve/main/sd_xl_base_1.0.safetensors COMFYUI_MODEL_SHA256="$(printf '0%.0s' {1..64})" 2>&1) &&
    die 'an existing model with another checksum was accepted'
[[ $out == *'exists with checksum'* ]] || die "checksum refusal unclear: $out"
rm -f "$tmp_root/state/models/checkpoints/sd_xl_base_1.0.safetensors"
out=$(target COMFYUI_MODEL_URL=https://h.test/o/r/resolve/main/sd_xl_base_1.0.safetensors COMFYUI_MODEL_SHA256="$(printf '0%.0s' {1..64})" 2>&1) &&
    die 'a download with another checksum was kept'
[[ $out == *'Checksum mismatch'* && ! -e $tmp_root/state/models/checkpoints/sd_xl_base_1.0.safetensors && ! -e $tmp_root/state/models/checkpoints/sd_xl_base_1.0.safetensors.part ]] ||
    die "bad download not removed: $out"
pass 'model checksums are enforced for existing files and downloads'

community_ct
out=$(FAKE_BROKEN=all target 2>&1) && die 'adoption reported success with the server down'
[[ $out == *'did not answer'* && $out == *'COMFYUI_EXTRA_ARGS=--cpu'* ]] || die "unclear failure: $out"
pass 'adoption fails loudly when ComfyUI does not come back, with the CPU hint'

community_ct
out=$(FAKE_DEVICE=cpu target 2>&1) || die "adoption failed: $out"
[[ $out == *'Warning: ComfyUI runs on the CPU'* ]] || die 'a GPU target on the CPU was not reported'
pass 'a GPU target that ends up on the CPU is reported'

rm -rf "${community:?}" "${optt:?}"
out=$(target 2>&1) && die 'adoption without a community install succeeded'
[[ $out == *'provision-lxc.sh'* ]] || die 'missing-install refusal unclear'
pass 'refuses a CT without the community-script install'

# --- FLUX.2 Klein weights --------------------------------------------------------
mkdir -p "$hf" "$tmp_root/tmpd"
printf 'diffusion-4b-weights' > "$hf/d4.safetensors"; printf 'qwen-4b-encoder' > "$hf/e4.safetensors"
printf 'flux2-vae' > "$hf/vae.safetensors"; printf 'diffusion-9b-gated' > "$hf/d9.safetensors"; printf 'qwen-8b-encoder' > "$hf/e9.safetensors"
weights=$tmp_root/weights.txt
# row VARIANT FOLDER FILE [ACCESS] [SHA256]: a manifest line for a file in $hf.
row() {
    printf '%s %s %s %s %s %s https://hf.test/o/r/resolve/main/%s\n' "$1" "$2" "$3" "$(stat -c %s "$hf/$3")" \
        "${5:-$(sha256sum "$hf/$3" | cut -d' ' -f1)}" "${4:-open}" "$3"
}
write_weights() {
    { echo '# variant folder file size sha256 access url'
      row klein-4b diffusion_models d4.safetensors; row klein-4b text_encoders e4.safetensors; row klein-4b vae vae.safetensors
      row klein-9b diffusion_models d9.safetensors gated hf; row klein-9b text_encoders e9.safetensors; row klein-9b vae vae.safetensors
    } > "$weights"
}
write_weights
token=hf_Z9y8X7w6V5Z9y8X7w6V5Z9y8X7w6V5Z9y8X7w6V5
printf '%s\n' "$token" > "$tmp_root/hf-token"
wt() { target KLEIN_WEIGHTS="$weights" TMPDIR="$tmp_root/tmpd" FAKE_GATED=d9.safetensors FAKE_HF_TOKEN="$token" "$@"; }
models=$tmp_root/state/models

community_ct
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b 2>&1) || die "4B weights failed: $out"
[[ $(cat "$models/diffusion_models/d4.safetensors") == diffusion-4b-weights && $(cat "$models/text_encoders/e4.safetensors") == qwen-4b-encoder &&
    $(cat "$models/vae/vae.safetensors") == flux2-vae ]] || die "4B files: $out"
[[ $(grep -c '^curl .* -C 0 ' "$log") == 3 && $(wc -l < "$tmp_root/etc/verified-weights") == 3 ]] || die 'three downloads, three verified records'
[[ $out == *'The klein-4b weights are installed.'* ]] || die "4B report: $out"
[[ -z $(find "$models" -name '*.part') ]] || die 'a partial download was left'
pass 'klein-4b: the diffusion model, text encoder and VAE are downloaded, checked and recorded'

: > "$log"
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b 2>&1) || die "rerun failed: $out"
[[ $(grep -c '(verified)' <<< "$out") == 3 ]] && ! grep -q -- ' -C ' "$log" || die "a rerun downloaded again: $(cat "$log")"
pass 'a rerun downloads nothing and does not hash the files again'

community_ct
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b FAKE_CUT=7 2>&1) || die "resume failed: $out"
rm -f "$tmp_root/cut-done"
grep -q -- ' -C 7 ' "$log" && [[ $(cat "$models/diffusion_models/d4.safetensors") == diffusion-4b-weights ]] || die "not resumed: $(cat "$log")"
[[ $out == *'resuming'* ]] || die "resume not reported: $out"
pass 'an interrupted download is resumed where it stopped'

community_ct
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b FAKE_DF_AVAIL=1024 2>&1) && die 'downloaded without the space for it'
[[ $out == *'GB free'*'pct resize'* ]] && ! grep -q -- ' -C ' "$log" || die "space refusal: $out"
pass 'too little disk space is refused before anything is downloaded'

community_ct
printf 'diffusion-4b-WEIGHTS' > "$hf/d4.safetensors"   # same size, other bytes upstream
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b 2>&1) && die 'a file with another hash was installed'
[[ $out == *'Checksum mismatch for d4.safetensors'* && ! -e $models/diffusion_models/d4.safetensors &&
    -z $(find "$models" -name '*.part') ]] || die "bad hash: $out"
printf 'diffusion-4b-weights' > "$hf/d4.safetensors"
mkdir -p "$models/diffusion_models"; printf 'diffusion-4b-WEIGHTS' > "$models/diffusion_models/d4.safetensors"
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b 2>&1) && die 'a local file with another hash was kept'
[[ $out == *'has checksum'*'Move it aside'* ]] || die "local mismatch: $out"
printf 'longer diffusion weights' > "$hf/d4.safetensors"
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b 2>&1) && die 'an upstream size change was accepted'
[[ $out == *'bytes upstream, not the reviewed'* ]] || die "size change: $out"
printf 'diffusion-4b-weights' > "$hf/d4.safetensors"
pass 'hashes and sizes: a wrong download is removed, a wrong local file or a changed upstream file is refused'

community_ct
out=$(wt COMFYUI_IMAGE_VARIANT=klein-9b 2>&1) && die '9B without a token was attempted'
[[ $out == *'gated on Hugging Face: set HF_TOKEN_FILE'* ]] && ! grep -q 'systemctl stop' "$log" || die "token refusal: $out"
printf 'hf_%s\n' "$(printf 'q%.0s' {1..34})" > "$tmp_root/wrong-token"
out=$(wt COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN_FILE="$tmp_root/wrong-token" 2>&1) && die 'a refused token was accepted'
[[ $out == *'Hugging Face refused d9.safetensors (HTTP 403)'*'Accept the license'* ]] || die "403: $out"
out=$(wt COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN=not-a-token 2>&1) && die 'a malformed token was accepted'
[[ $out == *'must be an access token'* ]] || die "malformed token: $out"
pass '9B is gated: no token, a refused token or a malformed one stops it, with the reason'

community_ct
out=$(wt COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN_FILE="$tmp_root/hf-token" 2>&1) || die "9B failed: $out"
[[ $(cat "$models/diffusion_models/d9.safetensors") == diffusion-9b-gated && $(cat "$models/text_encoders/e9.safetensors") == qwen-8b-encoder ]] ||
    die "9B files: $out"
grep -q "diffusion_models/d9.safetensors $(sha256sum "$hf/d9.safetensors" | cut -d' ' -f1) " "$tmp_root/etc/verified-weights" ||
    die "the gated file was not checked against Hugging Face's hash"
! grep -q "$token" "$log" || die 'the token appeared in a command line'
grep -q -- '-H @' "$log" || die 'curl did not read the token from a header file'
[[ -z $(find "$tmp_root/tmpd" -mindepth 1) ]] || die 'the header file was left behind'
pass "9B with a token: the gated file is checked against Hugging Face's hash; the token only ever in a root-only file"

community_ct
out=$(wt COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN_FILE="$tmp_root/hf-token" FAKE_ETAG="$(printf 'e%.0s' {1..64})" 2>&1) &&
    die 'a gated file not matching its hash was installed'
[[ $out == *'Checksum mismatch for d9.safetensors'* ]] || die "etag mismatch: $out"
out=$(wt COMFYUI_IMAGE_VARIANT=klein-9b HF_TOKEN_FILE="$tmp_root/hf-token" COMFYUI_KLEIN_9B_SHA256="$(printf 'a%.0s' {1..64})" 2>&1) &&
    die 'a COMFYUI_KLEIN_9B_SHA256 pin was ignored'
[[ $out == *'not COMFYUI_KLEIN_9B_SHA256'* ]] || die "pin: $out"
pass "the gated file must match Hugging Face's hash, and COMFYUI_KLEIN_9B_SHA256 when it is pinned"

community_ct
printf 'klein-4b vae ../escape.safetensors 9 %s open https://hf.test/x\n' "$(printf 'a%.0s' {1..64})" >> "$weights"
out=$(wt COMFYUI_IMAGE_VARIANT=klein-4b 2>&1) && die 'a malformed manifest was used'
[[ $out == *'malformed klein-4b row'* ]] && ! grep -q 'systemctl stop' "$log" || die "manifest: $out"
write_weights
pass 'a malformed manifest row is refused before anything changes'

# --upgrade
adopted() { community_ct; target >/dev/null 2>&1 || die 'setup adoption failed'; : > "$log"; }
upgrade() { ARGS=--upgrade target "$@"; }

community_ct
out=$(upgrade 2>&1) && die 'upgrade before adoption succeeded'
[[ $out == *'not been adopted'* ]] || die 'pre-adoption refusal unclear'
pass 'upgrade refuses a target that has not been adopted'

adopted; make_upstream v0.42.1 "$commit_a"
out=$(upgrade 2>&1) || die "healthy upgrade failed: $out"
new=$(current)
[[ $new == "$optt"/releases/v0.42.1-63be2f9b82ad-* && $(release_commit "$new") == "$commit_a" ]] || die "new release: $new"
[[ ! -e $new/.git && -x $new/venv/bin/python ]] || die 'the release keeps .git or has no venv'
grep -q -- 'clone --quiet --depth 1 --branch v0.42.1 --single-branch https://github.test/Comfy-Org/ComfyUI.git' "$log" || die 'clone call'
grep -q -- 'uv pip install --quiet --python .* torch torchvision torchaudio --extra-index-url https://torch.test/whl/cu130' "$log" || die 'the current PyTorch build was not kept'
[[ $(readlink -f "$new/venv/bin/python") == "$optt/python/"* ]] || die 'the new venv does not use the relocated Python'
[[ -d $community && $out == *'ComfyUI v0.42.1 is serving'* && $out == *"kept as $community"* ]] || die "upgrade report: $out"
# Build before stop: the old release kept running while the new one was prepared.
[[ $(grep -n 'uv pip' "$log" | tail -n1 | cut -d: -f1) -lt $(grep -n 'systemctl stop' "$log" | head -n1 | cut -d: -f1) ]] || die 'the service was stopped before the build'
pass 'healthy upgrade: commit-verified build beside the running release, same PyTorch build, then a switch'

: > "$log"
out=$(upgrade 2>&1) || die "unchanged upgrade failed: $out"
[[ $out == *'already installed and serving; nothing to do'* ]] || die "unchanged upgrade did work: $out"
! grep -qE 'systemctl (stop|start|restart)|^git |^uv ' "$log" || die "an unchanged upgrade touched the target: $(cat "$log")"
systemctl_stopped() { rm -f "$running"; }
systemctl_stopped
out=$(upgrade 2>&1) || die "unchanged upgrade of a stopped service failed: $out"
[[ $out == *'nothing to do (the service stays stopped)'* && ! -e $running ]] || die "stopped no-op: $out"
touch "$running"; : > "$log"
out=$(FAKE_ACTIVE_STATE=failed upgrade 2>&1) || die "failed service recovery: $out"
[[ $out == *'does not answer as that version; rebuilding'* ]] || die "failed unit not re-applied: $out"
grep -q 'systemctl start' "$log" || die 'a failed service was mistaken for deliberately stopped'
pass 'an unchanged upgrade does nothing; a failed unit is rebuilt and started'

adopted; make_upstream v0.42.1 "$commit_b"
out=$(upgrade 2>&1) && die 'a tag at an unexpected commit was installed'
[[ $out == *"is commit $commit_b, not the reviewed $commit_a"* && $out == *'was not stopped or changed'* ]] || die "commit refusal: $out"
! grep -q 'systemctl stop' "$log" || die 'service stopped before the release was verified'
[[ $(current) == "$community" && -z $(find "$optt/releases" -mindepth 1 -maxdepth 1) ]] || die 'a refused build was left behind'
make_upstream v0.42.1 "$commit_a"
out=$(FAKE_UV_FAIL=1 upgrade 2>&1) && die 'a failed build was installed'
[[ $out == *'was not stopped or changed'* && $(current) == "$community" && -e $running ]] || die "build failure: $out"
out=$(FAKE_IMPORT_RC=1 upgrade 2>&1) && die 'a venv that cannot import was installed'
[[ $out == *"cannot import ComfyUI's dependencies"* && $(current) == "$community" ]] || die "import failure: $out"
pass 'a moved tag, a failed build or a broken venv stops nothing'

out=$(upgrade COMFYUI_VERSION=v0.42.5 2>&1) && die 'a non-default version without a commit was accepted'
[[ $out == *'Set COMFYUI_COMMIT'* ]] || die 'commit requirement unclear'
make_upstream v0.42.5 "$commit_b"
out=$(upgrade COMFYUI_VERSION=v0.42.5 COMFYUI_COMMIT="$commit_b" COMFYUI_TORCH=cu128 2>&1) || die "pinned upgrade failed: $out"
grep -q -- '--extra-index-url https://torch.test/whl/cu128' "$log" || die 'COMFYUI_TORCH not used'
[[ $(release_version "$(current)") == 0.42.5 ]] || die 'not on 0.42.5'
pass 'another release needs its reviewed commit; COMFYUI_TORCH picks the PyTorch build'

adopted; make_upstream v0.42.1 "$commit_a"
out=$(FAKE_BROKEN=0.42.1 upgrade 2>&1) && die 'upgrade reported success while the new release did not answer'
[[ $(current) == "$community" && -z $(find "$optt/releases" -mindepth 1 -maxdepth 1) ]] || die 'not rolled back'
[[ $out == *'the previous release (0.41.0) is running again'* ]] || die "rollback outcome not reported: $out"
pass 'unhealthy upgrade: the previous release is restored, restarted and checked to answer as 0.41.0'

adopted
out=$(FAKE_BROKEN=all upgrade 2>&1) && die 'an upgrade with no answering server reported success'
[[ $(current) == "$community" && $out == *'the previous release did not answer either'* ]] || die "failed rollback not reported: $out"
pass 'a rollback whose server does not answer is reported as such'

adopted
sed -i 's/^TimeoutStopSec=60$/TimeoutStopSec=30/' "$dropin"
old_dropin=$(cat "$dropin")
out=$(FAKE_BROKEN=0.42.1 upgrade 2>&1) && die 'broken upgrade succeeded'
[[ $(cat "$dropin") == "$old_dropin" && ! -e $dropin.prev ]] || die 'the drop-in was not restored'
out=$(upgrade 2>&1) || die "upgrade with a new drop-in failed: $out"
cmp -s "$script_dir/comfyui-target.conf" "$dropin" && [[ ! -e $dropin.prev ]] || die 'the new drop-in was not installed'
pass "this repository's newer drop-in is installed by --upgrade and restored by a rollback"

adopted; rm -f "$running"
out=$(upgrade 2>&1) || die "upgrade of a stopped service failed: $out"
! grep -q 'systemctl start' "$log" && [[ $(release_commit "$(current)") == "$commit_a" ]] || die 'a stopped service was started'
[[ $out == *'left stopped'* ]] || die "stopped upgrade report: $out"
pass 'a stopped service stays stopped'

adopted
upgrade >/dev/null 2>&1 || die 'first upgrade failed'
first=$(current)
sleep 1   # a later build gets a later time stamp
make_upstream v0.42.5 "$commit_b"
out=$(upgrade COMFYUI_VERSION=v0.42.5 COMFYUI_COMMIT="$commit_b" 2>&1) || die "second upgrade failed: $out"
second=$(current)
make_upstream v0.42.6 "$commit_a"
out=$(upgrade COMFYUI_VERSION=v0.42.6 COMFYUI_COMMIT="$commit_a" 2>&1) || die "third upgrade failed: $out"
[[ ! -e $first && -d $second && ! -e $community/venv && -f $community/main.py ]] || die 'old builds not pruned'
pass 'only the current and the previous release are kept; the community venv goes once it is older'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
