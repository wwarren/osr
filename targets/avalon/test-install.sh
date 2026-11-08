#!/usr/bin/env bash
# Exercise install-target.sh: its helpers (checkout checks, CMake arguments,
# GPU detection, the weights manifest, the server arguments, the settings
# record), then whole-script runs against a temporary tree with stubbed git,
# cmake, ldd, systemctl, curl (Hugging Face and the API), the toolkit
# installers, a fake AMD card in sysfs, nvidia-smi and account tools. Nothing
# is downloaded, built, installed or started.
# The AVALON_* assignments below are read by the sourced helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/avalon-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/avalon-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# A minimal Avalon checkout: the files, CMake options and server flags
# install-target.sh checks for.
fixture=$tmp_root/upstream
make_fixture() {
    local dir=$1 flag
    mkdir -p "$dir/common" "$dir/tools/server" "$dir/ggml/src/ggml-hip" "$dir/ggml/src/ggml-cuda"
    printf 'project(llama.cpp)\noption(LLAMA_BUILD_UI        "" OFF)\noption(LLAMA_USE_PREBUILT_UI "" ON)\noption(LLAMA_OPENSSL    "" ON)\n' > "$dir/CMakeLists.txt"
    mkdir -p "$dir/ggml"
    printf 'option(GGML_CUDA                "" OFF)\noption(GGML_HIP                 "" OFF)\n' > "$dir/ggml/CMakeLists.txt"
    : > "$dir/tools/server/server.cpp"; : > "$dir/ggml/src/ggml-hip/CMakeLists.txt"; : > "$dir/ggml/src/ggml-cuda/moe-cache.cu"
    for flag in -m --alias -c -b -ub -fa -ctk -ctv --jinja --parallel -md --spec-type --spec-draft-n-max -ubd \
                -ctkd -ctvd --host --port --api-key-file --no-webui; do
        printf '{"%s"},\n' "$flag"
    done > "$dir/common/arg.cpp"
    printf 'if (s == "draft-mtp") {}\n' > "$dir/common/speculative.cpp"
}
make_fixture "$fixture"

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in validate_checkout rocm_dir cmake_args compute_cap_arch gfx_of_pci_device amd_render_nodes gpu_vram_mib \
              context_for_vram model_path weight_rows validate_settings settings_env load_settings fingerprint_env \
              saved_settings server_args key_file start_env settings_fingerprint; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done
AVALON_DIR=$fixture AVALON_DATA_DIR=/var/lib/avalon AVALON_CONFIG_DIR=/etc/avalon AVALON_BACKEND=rocm
AVALON_ROCM_VERSION=7.2.4 AVALON_GPU_TARGET=gfx1100 AVALON_CUDA_VERSION=12.9 AVALON_NVCC=/usr/local/cuda-12.9/bin/nvcc
AVALON_CUDA_ARCH=auto AVALON_PORT=8080 AVALON_CONTEXT=262144 AVALON_MTP=true AVALON_MODEL_NAME=qwen3.8-flash-next-avalon

validate_checkout "$fixture" || fail 'the fixture checkout was refused'
for broken in common/arg.cpp ggml/src/ggml-cuda/moe-cache.cu; do
    cp -a "$fixture" "$tmp_root/broken"; rm -f "$tmp_root/broken/$broken"
    out=$(validate_checkout "$tmp_root/broken" 2>&1) && fail "a checkout without $broken was accepted"
    [[ $out == *"lacks: $broken"* ]] || fail "missing-file message: $out"
    rm -rf "$tmp_root/broken"
done
cp -a "$fixture" "$tmp_root/broken"; sed -i '/--api-key-file/d' "$tmp_root/broken/common/arg.cpp"
sed -i '/LLAMA_USE_PREBUILT_UI/d' "$tmp_root/broken/CMakeLists.txt"; : > "$tmp_root/broken/common/speculative.cpp"
out=$(validate_checkout "$tmp_root/broken" 2>&1) && fail 'a server without --api-key-file was accepted'
[[ $out == *'does not accept: -DLLAMA_USE_PREBUILT_UI --api-key-file --spec-type draft-mtp'* ]] || fail "flag message: $out"
rm -rf "$tmp_root/broken"
pass 'a checkout must carry the files, CMake options and llama-server flags the installer relies on'

args=$(cmake_args | tr '\n' ' ')
[[ $args == *"-G Ninja"* && $args == *"-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100"* &&
   $args == *"-DCMAKE_CXX_COMPILER=/opt/rocm-7.2.4/bin/amdclang++"* &&
   $args == *"-DCMAKE_HIP_COMPILER=/opt/rocm-7.2.4/llvm/bin/clang++"* &&
   $args == *"-DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF"* && $args != *CUDA* ]] || fail "rocm cmake args: $args"
AVALON_BACKEND=cuda AVALON_CUDA_ARCH=89
args=$(cmake_args | tr '\n' ' ')
[[ $args == *"-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.9/bin/nvcc"* &&
   $args != *HIP* ]] || fail "cuda cmake args: $args"
AVALON_BACKEND=rocm AVALON_CUDA_ARCH=auto
[[ $(compute_cap_arch <<< '8.9') == 89 && $(compute_cap_arch <<< $'12.0\n8.6') == 120 ]] || fail 'compute capability parsing'
compute_cap_arch <<< 'N/A' && fail 'a malformed compute capability was accepted'
[[ $(gfx_of_pci_device 0x744c) == gfx1100 && $(gfx_of_pci_device 0x7480) == gfx1102 &&
   $(gfx_of_pci_device 0x747E) == gfx1101 && -z $(gfx_of_pci_device 0x7550) && -z $(gfx_of_pci_device 0x73bf) ]] ||
    fail 'RDNA 3 PCI IDs'
[[ $(context_for_vram 20464) == 262144 && $(context_for_vram 16368) == 65536 ]] || fail 'context for VRAM'
pass 'llama-server is configured for the backend: HIP with ROCm'\''s compilers and the gfx target, or CUDA with its nvcc'

# The shipped manifest: one pinned revision, the 33 shards, the MTP head.
manifest=$script_dir/avalon-weights.txt
rows=$(weight_rows "$manifest") || fail 'the shipped manifest was refused'
[[ $(grep -c 'IQ3KS-000[0-9][0-9]-of-00033.gguf ' <<< "$rows") == 33 ]] || fail 'the 33 shards'
grep -q "^$MODEL_FILE " <<< "$rows" || fail 'the first shard'
grep -q "^$MTP_FILE " <<< "$rows" || fail 'MTP head missing with AVALON_MTP=true'
grep -q '^moe-cache-ranking.bin ' <<< "$rows" || fail 'the expert ranking'
[[ $(awk '{ print $4 }' <<< "$rows" | sed -E 's|/resolve/([0-9a-f]{40})/.*|\1|' | sort -u | wc -l) == 1 ]] || fail 'more than one revision'
awk '$4 !~ /\/resolve\/[0-9a-f]{40}\// { exit 1 }' <<< "$rows" || fail 'a URL is not pinned to a commit'
awk '{ s += $2 } END { exit !(s > 95e9 && s < 97e9) }' <<< "$rows" || fail 'the total size'
AVALON_MTP=false
grep -q '^MTP/' <<< "$(weight_rows "$manifest")" && fail 'the MTP head is listed without MTP'
AVALON_MTP=true
for bad in 'model ../etc/passwd 1 sha256:'"$(printf '0%.0s' {1..64})"' https://huggingface.co/x' \
           'model a/b 1 sha256:abc https://huggingface.co/x' \
           'model a/b 1 git:'"$(printf 'a%.0s' {1..40})"' http://huggingface.co/x' \
           'model a/b 1 git:'"$(printf 'a%.0s' {1..40})"' https://example.com/x' \
           'draft a/b 1 sha256:'"$(printf '0%.0s' {1..64})"' https://huggingface.co/x'; do
    printf '%s\n' "$bad" > "$tmp_root/bad-manifest"
    out=$(weight_rows "$tmp_root/bad-manifest" 2>&1) && fail "a malformed manifest row was accepted: $bad"
    [[ $out == *'malformed row'* ]] || fail "malformed row message: $out"
done
pass 'the weights manifest is pinned to one revision, complete and strictly parsed'

api_key=sk-test-key
args=$(server_args | tr '\n' ' ')
[[ $args == "-m /var/lib/avalon/models/$MODEL_FILE --alias qwen3.8-flash-next-avalon -c 262144 -b 9536 -ub 9536 -fa on -ctk q8_0 -ctv q4_0 --jinja --parallel 1 -md /var/lib/avalon/models/$MTP_FILE --spec-type draft-mtp --spec-draft-n-max 2 -ubd 256 -ctkd q8_0 -ctvd q8_0 --host 0.0.0.0 --port 8080 --api-key-file /etc/avalon/api-key --no-webui " ]] ||
    fail "server args: $args"
[[ $(start_env) == *'AVALON_ARGS=-m '* && $(start_env) != *sk-test-key* ]] || fail "unit environment: $(start_env)"
AVALON_MTP=false
[[ $(server_args) != *-md* && $(server_args) != *draft-mtp* ]] || fail 'MTP arguments without AVALON_MTP'
AVALON_MTP=true
pass 'the server runs upstream'\''s command with absolute paths, the alias and a key file; no key in its arguments'

settings_env > "$tmp_root/installed-env"
[[ $(grep -c '^AVALON_' "$tmp_root/installed-env") == 10 ]] || fail "settings record: $(cat "$tmp_root/installed-env")"
AVALON_CONTEXT=65536 AVALON_PORT=11434 AVALON_GPU_TARGET=gfx1101
load_settings "$tmp_root/installed-env" || fail 'a valid record was not loaded'
[[ $AVALON_CONTEXT == 262144 && $AVALON_PORT == 8080 && $AVALON_GPU_TARGET == gfx1100 ]] ||
    fail "record not restored: $AVALON_CONTEXT $AVALON_PORT $AVALON_GPU_TARGET"
for bad in 's/^AVALON_PORT=.*/AVALON_PORT=99999/' 's/^AVALON_GPU_TARGET=.*/AVALON_GPU_TARGET=gfx1201/' \
           's/^AVALON_MTP=.*/AVALON_MTP=yes/' 's/^AVALON_BACKEND=.*/AVALON_BACKEND=vulkan/' \
           's/^AVALON_CONTEXT=.*/AVALON_CONTEXT=999999/'; do
    sed "$bad" "$tmp_root/installed-env" > "$tmp_root/bad-env"
    AVALON_PORT=11434
    load_settings "$tmp_root/bad-env" && fail "an invalid record was loaded ($bad)"
    [[ $AVALON_PORT == 11434 ]] || fail 'an invalid record changed a setting'
done
grep -v '^AVALON_MTP=' "$tmp_root/installed-env" > "$tmp_root/old-env"
load_settings "$tmp_root/old-env" && fail 'a record without every key was loaded'
printf 'AVALON_PORT=8080; touch %s/pwned\n' "$tmp_root" > "$tmp_root/evil-env"
load_settings "$tmp_root/evil-env" && fail 'a malformed record was loaded'
[[ ! -e $tmp_root/pwned ]] || fail 'the record was executed'
AVALON_PORT=8080
pass 'the settings record is read back all-or-nothing and never executed'
# The whole-script runs below start from the defaults.
unset "${SETTING_KEYS[@]}"

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
# The installer runs from a copy whose toolkit installers are stubs that only
# log (the real ones install packages) and whose manifest lists small fixture
# files served by the curl stub.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
cp "$script_dir/install-target.sh" "$script_dir/avalon.service" "$script_dir/upstream-commit.txt" "$deploy/"
log=$tmp_root/calls.log
printf '#!/usr/bin/env bash\necho "rocm-toolkit.sh $* ROCM_VERSION=$ROCM_VERSION ROCM_DIR=$ROCM_DIR" >> "%s"\n[[ $1 == --check && ${FAKE_ROCM_UNAVAILABLE:-0} == 1 ]] && { echo "AMD has no such repository" >&2; exit 1; }\nexit 0\n' "$log" > "$deploy/rocm-toolkit.sh"
printf '#!/usr/bin/env bash\necho "cuda-toolkit.sh $* CUDA_VERSION=$CUDA_VERSION CUDA_NVCC=${CUDA_NVCC:-}" >> "%s"\n[[ $1 == --check && ${FAKE_CUDA_UNAVAILABLE:-0} == 1 ]] && { echo "NVIDIA repository lacks it" >&2; exit 1; }\nexit 0\n' "$log" > "$deploy/cuda-toolkit.sh"
target=$deploy/install-target.sh

# The fixture "Hugging Face": files by URL basename.
hf=$tmp_root/hf; mkdir -p "$hf"
head -c 3000 /dev/urandom > "$hf/$MODEL_FILE"
head -c 2000 /dev/urandom > "$hf/Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf"
head -c 700 /dev/urandom > "$hf/${MTP_FILE#MTP/}"
head -c 400 /dev/urandom > "$hf/moe-cache-ranking.bin"
printf 'Qwen Community License\n' > "$hf/LICENSE"
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }
url=https://huggingface.co/test/repo/resolve/0123456789abcdef0123456789abcdef01234567
{
    for f in "$MODEL_FILE" Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf moe-cache-ranking.bin; do
        printf 'model %s %s sha256:%s %s/%s\n' "$f" "$(size "$hf/$f")" "$(sha "$hf/$f")" "$url" "$f"
    done
    printf 'model LICENSE %s git:%s %s/LICENSE\n' "$(size "$hf/LICENSE")" "$(git hash-object --no-filters "$hf/LICENSE")" "$url"
    printf 'mtp %s %s sha256:%s %s/%s\n' "$MTP_FILE" "$(size "$hf/${MTP_FILE#MTP/}")" "$(sha "$hf/${MTP_FILE#MTP/}")" "$url" "$MTP_FILE"
} > "$tmp_root/good-weights.txt"

bin=$tmp_root/bin; mkdir -p "$bin"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub getent 'exit 2'   # no avalon group yet, so it is created
stub mv 'if [[ ${FAKE_METADATA_FAIL:-0} == 1 && ${*: -1} == */installed-settings ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
for command_name in apt-get groupadd useradd usermod chown chgrp sleep; do stub "$command_name" 'exit 0'; done
stub stat 'if [[ $1 == -c && $2 == %G ]]; then echo "${FAKE_GROUP:-video}"; else exec /usr/bin/stat "$@"; fi'
stub systemctl 'case "$1" in is-failed) exit 1;; is-active) exit "${FAKE_INACTIVE:-0}";; esac; exit 0'
stub tar 'if [[ ${FAKE_SNAPSHOT_FAIL:-0} == 1 && $* == *"-cpf "* ]]; then exit 1; fi; exec /usr/bin/tar "$@"'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub df 'printf "Filesystem 1-blocks Used Available Capacity Mounted\nfake 1 1 %s 1%% /\n" "${FAKE_DF_AVAIL:-1099511627776}"'
stub ldd 'if [[ -n ${FAKE_LDD_MISSING:-} ]]; then printf "\t%s => not found\n" "$FAKE_LDD_MISSING"; fi; exit 0'
stub nvidia-smi 'if [[ $* == *compute_cap* ]]; then echo "${FAKE_CAP:-8.9}"; elif [[ $* == *memory.total* ]]; then echo "${FAKE_VRAM_MIB:-24564}"; else echo "GPU 0: NVIDIA GeForce RTX 4090"; fi'
# cmake (the distro's): logs the configure and "builds" llama-server
# (FAKE_BAD_COMMIT: the build fails at that commit).
cat > "$bin/cmake" <<STUB
#!/usr/bin/env bash
echo "cmake \$* @\$(cat .git/HEAD) ROCM_PATH=\${ROCM_PATH:-}" >> "$log"
if [[ \$1 == --build ]]; then
    [[ \$(cat .git/HEAD) == "\${FAKE_BAD_COMMIT:-none}" ]] && { rm -f build/rollback-marker; echo broken > runtime-from-failed-upgrade; exit 1; }
    mkdir -p build/bin; printf '#!/bin/sh\n' > build/bin/llama-server; chmod +x build/bin/llama-server
fi
exit 0
STUB
chmod +x "$bin/cmake"
# curl: Hugging Face HEAD answers (X-Linked-Size/-Etag as the CDN sends them),
# resumable downloads from the fixture directory, and llama-server's API.
# FAKE_HF_DOWN=1: Hugging Face does not answer; FAKE_ETAG=<hex>: a different
# upstream hash; FAKE_CORRUPT=<name>: that file arrives with a flipped byte;
# FAKE_CUT=<name>: that download stops half-way once; FAKE_READY=0: the model
# never loads (503 on /health).
cat > "$bin/curl" <<STUB
#!/usr/bin/env bash
echo "curl \$*" >> "$log"
url=\${@: -1}
case \$url in
    https://huggingface.co/*)
        [[ \${FAKE_HF_DOWN:-0} == 1 ]] && exit 6
        name=\${url##*/}; src="$hf/\$name"
        [[ -f \$src ]] || exit 22
        if [[ " \$* " == *' -I '* ]]; then
            printf 'HTTP/2 302\r\n'
            case \$name in
                LICENSE) ;;
                *) printf 'x-linked-size: %s\r\nx-linked-etag: "%s"\r\n' "\$(stat -c %s "\$src")" "\${FAKE_ETAG:-\$(sha256sum "\$src" | cut -d' ' -f1)}" ;;
            esac
            exit 0
        fi
        out=''; from=0
        while (( \$# )); do case \$1 in -o) out=\$2; shift 2;; -C) from=\$2; shift 2;; *) shift;; esac; done
        echo "download \$name from \$from" >> "$log"
        if [[ \${FAKE_CUT:-} == "\$name" && ! -e "$tmp_root/cut-done" ]]; then
            touch "$tmp_root/cut-done"
            tail -c +\$(( from + 1 )) "\$src" | head -c 100 >> "\$out"; exit 18
        fi
        tail -c +\$(( from + 1 )) "\$src" >> "\$out"
        if [[ \${FAKE_CORRUPT:-} == "\$name" ]]; then printf 'X' | dd of="\$out" bs=1 seek=0 conv=notrunc status=none; fi
        exit 0 ;;
    */health) [[ \${FAKE_READY:-1} == 1 ]] || exit 22; printf '{"status":"ok"}\n' ;;
    */v1/models) printf '{"object":"list","data":[{"id":"%s","owned_by":"llamacpp"}]}\n' "\${FAKE_MODEL:-qwen3.8-flash-next-avalon}" ;;
    *) exit 22 ;;
esac
STUB
chmod +x "$bin/curl"
# git: a fake shallow checkout. Names resolve to a fixed hash; commits that
# were fetched or pinned with update-ref are "local" and can be checked out
# offline (the fixture tree is copied in). hash-object is the real one.
# FAKE_FETCH_FAIL=1: every fetch fails (no network).
real_git=$(command -v git)
cat > "$bin/git" <<STUB
#!/usr/bin/env bash
[[ \$1 == hash-object ]] && exec "$real_git" "\$@"
echo "git \$*" >> "$log"
dir=.
while [[ \$1 == -c || \$1 == -C ]]; do [[ \$1 == -C ]] && dir=\$2; shift 2; done
resolve() {
    local want=\$1
    [[ \$want == main && -n \${FAKE_MAIN_COMMIT:-} ]] && want=\$FAKE_MAIN_COMMIT
    [[ \$want =~ ^[0-9a-f]{40}\$ ]] || want=\$(printf '%s' "\$want" | sha1sum | cut -c1-40)
    printf '%s\n' "\$want"
}
case \$1 in
    init) mkdir -p "\${@: -1}/.git" ;;
    remote) if [[ \$2 == add ]]; then echo "\$4" > "\$dir/.git/url"; else cat "\$dir/.git/url"; fi ;;
    fetch)
        [[ \${FAKE_FETCH_FAIL:-0} == 1 ]] && { echo 'fatal: unable to access' >&2; exit 128; }
        sha=\$(resolve "\${@: -1}")
        echo "\$sha" > "\$dir/.git/FETCH"; echo "\$sha" >> "\$dir/.git/known" ;;
    update-ref) echo "\$3" >> "\$dir/.git/known" ;;
    checkout|reset)
        want=\${@: -1}
        [[ \$want == FETCH_HEAD ]] && want=\$(< "\$dir/.git/FETCH")
        grep -qx "\$want" "\$dir/.git/known" || { echo "fatal: reference is not a tree: \$want" >&2; exit 128; }
        echo "\$want" > "\$dir/.git/HEAD"
        cp -r "$fixture/." "\$dir/" ;;
    rev-parse)
        if [[ \$2 == FETCH_HEAD* ]]; then cat "\$dir/.git/FETCH"; else cat "\$dir/.git/HEAD"; fi ;;
esac
STUB
chmod +x "$bin/git"

tree=$tmp_root/tree
dev=$tmp_root/dev
sysfs=$tmp_root/sys
meminfo=$tmp_root/meminfo
cpuinfo=$tmp_root/cpuinfo
rocm=$tmp_root/rocm-7.2.4
mkdir -p "$rocm/bin" "$rocm/llvm/bin"
for c in "$rocm/bin/amdclang" "$rocm/bin/amdclang++" "$rocm/llvm/bin/clang++"; do printf '#!/bin/sh\n' > "$c"; chmod +x "$c"; done
nvcc=$tmp_root/cuda-12.9/bin/nvcc
mkdir -p "${nvcc%/*}"; printf '#!/bin/sh\necho "Cuda compilation tools, release 12.9, V12.9.86"\n' > "$nvcc"; chmod +x "$nvcc"
# reset_tree: an empty CT with one AMD card (FAKE_PCI_DEVICE, FAKE_VRAM_BYTES)
# passed in as /dev/kfd and renderD128, or the NVIDIA nodes (FAKE_NVIDIA=1).
reset_tree() {
    rm -rf "$tree" "$dev" "$sysfs" "$tmp_root/cut-done"
    mkdir -p "$tree/etc/systemd/system" "$dev/dri" "$sysfs/renderD128/device"
    if [[ ${FAKE_NVIDIA:-0} == 1 ]]; then
        touch "$dev/nvidia0" "$dev/nvidiactl" "$dev/nvidia-uvm"
    else
        touch "$dev/kfd" "$dev/dri/renderD128"
        echo 0x1002 > "$sysfs/renderD128/device/vendor"
        echo "${FAKE_PCI_DEVICE:-0x744c}" > "$sysfs/renderD128/device/device"
        echo "${FAKE_VRAM_BYTES:-21458059264}" > "$sysfs/renderD128/device/mem_info_vram_total"
    fi
    printf 'MemTotal:       %s kB\n' "${FAKE_MEM_KIB:-65863680}" > "$meminfo"
    printf 'flags\t\t: fpu sse2 %s fma\n' "${FAKE_CPU_FLAG:-avx2}" > "$cpuinfo"
    cp "$tmp_root/good-weights.txt" "$deploy/avalon-weights.txt"
    : > "$log"
}
common_env() {
    printf '%s\n' "PATH=$bin:$PATH" "AVALON_DIR=$tree/opt/avalon" "AVALON_DATA_DIR=$tree/var/lib/avalon" \
        "AVALON_ETC_DIR=$tree/etc/avalon-target" "AVALON_CONFIG_DIR=$tree/etc/avalon" \
        "AVALON_STATE_DIR=$tree/var/lib/avalon-target" "UNIT_DIR=$tree/etc/systemd/system" \
        "AVALON_KFD=$dev/kfd" "DEV_DRI=$dev/dri" "DRM_SYSFS=$sysfs" "MEMINFO=$meminfo" "CPUINFO=$cpuinfo" \
        "AVALON_READY_TIMEOUT=5" "AVALON_ROCM_DIR=${AVALON_ROCM_DIR:-$rocm}" "CMAKE_BIN=$bin/cmake"
    if [[ ${FAKE_NVIDIA:-0} == 1 ]]; then
        printf '%s\n' "GPU_NODES=$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm"
    else
        printf '%s\n' "GPU_NODES=$dev/kfd $dev/dri/renderD*"
    fi
}
run_target() {
    local -a e
    mapfile -t e < <(common_env)
    env "${e[@]}" AVALON_COMMIT="${AVALON_COMMIT-}" AVALON_REF="${AVALON_REF-}" AVALON_PORT="${AVALON_PORT:-}" \
        AVALON_CONTEXT="${AVALON_CONTEXT:-}" AVALON_NVCC="${AVALON_NVCC_PATH:-$nvcc}" \
        bash "$target" "$@"
}
contains() { grep -Fq -- "$1" "$2" || { sed -n '1,40p' "$2" >&2; fail "$2 lacks: $1"; }; }
models=$tree/var/lib/avalon/models
envfile=$tree/etc/avalon-target/avalon.env
keycopy=$tree/etc/avalon/api-key

reset_tree
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
unit=$tree/etc/systemd/system/avalon.service
cmp -s "$unit" "$script_dir/avalon.service" || fail 'unit not installed'
key=$(< "$tree/etc/avalon-target/api-key")
[[ $key =~ ^[0-9a-f]{64}$ ]] || fail 'no generated key'
[[ $(stat -c %a "$tree/etc/avalon-target/api-key") == 600 ]] || fail 'key file mode'
[[ $(stat -c %a "$keycopy") == 640 && $(< "$keycopy") == "$key" ]] || fail "server key copy $(stat -c %a "$keycopy")"
contains "--api-key-file $keycopy" "$envfile"
grep -q -- "$key" "$tmp_root/out" && fail 'the key was printed'
grep -q -- "$key" "$envfile" && fail 'the key is in the unit environment'
grep -q -- "$key" "$log" && fail 'the key reached a command line'
contains "rocm-toolkit.sh --check ROCM_VERSION=7.2.4 ROCM_DIR=$rocm" "$log"
contains 'The AMD card is gfx1100.' "$tmp_root/out"
grep -q 'of VRAM: context' "$tmp_root/out" && fail 'the default context was sized from the VRAM'
contains '-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100' "$log"
contains "-DCMAKE_CXX_COMPILER=$rocm/bin/amdclang++" "$log"
contains "ROCM_PATH=$rocm" "$log"
contains 'cmake --build build --target llama-server' "$log"
contains 'usermod -aG video avalon' "$log"
contains 'systemctl enable avalon.service' "$log"
contains ' -c 65536 ' "$envfile"
contains 'gpu_target=gfx1100' "$tree/etc/avalon-target/installed-settings"
contains 'AVALON_BACKEND=rocm' "$tree/etc/avalon-target/installed-env"
pass 'fresh ROCm install as the avalon account: llama-server built for the card'\''s gfx target, the key only in root:avalon files'

cmp -s "$models/$MODEL_FILE" "$hf/$MODEL_FILE" || fail 'the first shard differs'
cmp -s "$models/$MTP_FILE" "$hf/${MTP_FILE#MTP/}" || fail 'the MTP head differs'
[[ -z $(find "$models" -name '.*.part') ]] || fail 'download leftovers remain'
[[ $(wc -l < "$tree/etc/avalon-target/verified-weights") == 5 ]] || fail "verified record: $(cat "$tree/etc/avalon-target/verified-weights")"
pass 'the weights are downloaded and verified (SHA-256, or the git blob id of the license)'

: > "$log"
FAKE_HF_DOWN=1 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'no-op rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged rerun stopped the service'
grep -q '^cmake ' "$log" && fail 'an unchanged rerun rebuilt'
grep -q 'huggingface.co' "$log" && fail 'an unchanged rerun contacted Hugging Face'
grep -q 'sha256sum' "$log" && fail 'an unchanged rerun hashed the weights again'
pass 'an unchanged, healthy install is left running, with no download and no rehash'

: > "$log"
FAKE_MAIN_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa AVALON_REF=main run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'new main rerun'; }
[[ $(< "$tree/opt/avalon/.git/HEAD") == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || fail 'rerun did not move to the new main'
contains 'Upgrading Avalon' "$tmp_root/out"
contains 'systemctl stop avalon.service' "$log"
contains "update-ref refs/avalon/previous $(< "$script_dir/upstream-commit.txt")" "$log"
contains 'cmake --build build --target llama-server' "$log"
[[ $(< "$tree/etc/avalon-target/api-key") == "$key" ]] || fail 'rerun replaced the key'
pass 'a new upstream commit rebuilds on a rerun, keeping the key and a rollback ref'

commit=0123456789abcdef0123456789abcdef01234567
: > "$log"
AVALON_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'pinned rerun'; }
[[ $(< "$tree/opt/avalon/.git/HEAD") == "$commit" ]] || fail 'pinned rerun did not move HEAD'
contains "fetch -q --depth 1 origin $commit" "$log"
pass 'an explicit commit pin overrides the branch'

: > "$log"
FAKE_INACTIVE=3 AVALON_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'inactive rerun'; }
contains 'Re-applying Avalon' "$tmp_root/out"
contains 'systemctl restart avalon.service' "$log"
pass 'a stopped service is brought back on a rerun even when nothing changed'

: > "$log"
AVALON_COMMIT=$commit AVALON_CONTEXT=131072 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'context rerun'; }
contains 'Re-applying Avalon' "$tmp_root/out"
contains ' -c 131072 ' "$envfile"
contains 'AVALON_CONTEXT=131072' "$tree/etc/avalon-target/installed-env"
printf 'AVALON_ARGS=--edited\n' > "$envfile"
: > "$log"
AVALON_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'edited environment rerun'; }
contains 'Re-applying Avalon' "$tmp_root/out"
contains ' -c 131072 ' "$envfile"
pass 'a changed setting or a hand-edited unit environment is re-applied, and the setting is kept afterwards'

: > "$log"
before=$(< "$tree/opt/avalon/.git/HEAD")
if FAKE_FETCH_FAIL=1 AVALON_COMMIT=123456789abcdef0123456789abcdef012345678 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade without network reported success'
fi
contains 'was not stopped or changed' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'a failed fetch stopped the service'
[[ $(< "$tree/opt/avalon/.git/HEAD") == "$before" ]] || fail 'a failed fetch moved the checkout'
pass 'a failed fetch leaves the running service untouched'

: > "$log"
if FAKE_SNAPSHOT_FAIL=1 AVALON_COMMIT=$commit AVALON_PORT=8123 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed runtime snapshot reported success'
fi
contains 'Runtime snapshot failed; the previous service is running again.' "$tmp_root/out"
grep -q '^cmake ' "$log" && fail 'a failed snapshot reached the build'
[[ ! -e $tree/var/lib/avalon-target/rollback-runtime.tar.new ]] || fail 'partial snapshot was not removed'
[[ $(grep '^curl ' "$log" | tail -n1) == *'127.0.0.1:8080/v1/models'* ]] || fail 'snapshot failure probed the attempted port'
pass 'a snapshot failure aborts before the build and restarts the original service'

: > "$log"
next=123456789abcdef0123456789abcdef012345678
AVALON_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade'; }
[[ ! -e $tree/var/lib/avalon-target/rollback-runtime.tar && ! -e $tree/var/lib/avalon-target/rollback.key ]] ||
    fail 'the snapshot was kept after a successful upgrade'
[[ $(< "$tree/opt/avalon/.git/HEAD") == "$next" ]] || fail 'upgrade did not move HEAD'
printf 'previous runtime\n' > "$tree/opt/avalon/build/rollback-marker"
bad=fedcba9876543210fedcba9876543210fedcba98
: > "$log"
if FAKE_BAD_COMMIT=$bad AVALON_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains "Avalon is running $next again" "$tmp_root/out"
[[ $(< "$tree/opt/avalon/.git/HEAD") == "$next" ]] || fail 'rollback did not restore HEAD'
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] || fail 'rollback fetched again instead of using the local commit'
[[ $(cat "$tree/opt/avalon/build/rollback-marker") == 'previous runtime' ]] || fail 'build not restored'
[[ ! -e $tree/opt/avalon/runtime-from-failed-upgrade ]] || fail 'failed runtime file survived'
awk '/^git .* reset / {restoring=1;next} restoring && /^cmake / {exit 1}' "$log" || fail 'rollback rebuilt'
[[ ! -e $tree/var/lib/avalon-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful rollback'
pass 'a failed upgrade returns to the previous commit and build without the network'

: > "$log"
if FAKE_READY=0 AVALON_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade whose model never loaded reported success'
fi
contains 'has not answered' "$tmp_root/out"
contains "Rollback to $next failed too" "$tmp_root/out"
contains 'the snapshot is kept in' "$tmp_root/out"
[[ -s $tree/var/lib/avalon-target/rollback-runtime.tar ]] || fail 'a failed rollback removed the snapshot'
pass 'an upgrade is not healthy until /health answers and /v1/models lists the model; a failed rollback keeps its snapshot'

# The kept snapshot is the last good runtime: the next run must not snapshot
# over it or call an unchanged install healthy until someone has looked.
[[ -e $tree/var/lib/avalon-target/rollback-failed ]] || fail 'a failed rollback left no marker'
cp "$tree/var/lib/avalon-target/rollback-runtime.tar" "$tmp_root/kept.tar"
: > "$log"
if AVALON_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade over a failed rollback went ahead'
fi
contains 'A rollback failed earlier' "$tmp_root/out"
if grep -qE '^(systemctl stop|git .* fetch )' "$log"; then fail 'a refused run stopped or fetched anything'; fi
cmp -s "$tmp_root/kept.tar" "$tree/var/lib/avalon-target/rollback-runtime.tar" || fail 'a refused run changed the kept snapshot'
if AVALON_COMMIT=$next run_target > "$tmp_root/out" 2>&1; then
    fail 'an install over a failed rollback went ahead'
fi
contains 'A rollback failed earlier' "$tmp_root/out"
rm -f -- "$tree/var/lib/avalon-target/rollback-failed" "$tmp_root/kept.tar"
pass 'after a failed rollback the next run stops, changing nothing, until its marker is removed'

: > "$log"
AVALON_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'reset to a healthy install'; }
cp "$unit" "$tmp_root/good.service"; cp "$envfile" "$tmp_root/good.env"
cp "$tree/etc/avalon-target/installed-settings" "$tmp_root/good-settings"
cp "$deploy/avalon.service" "$tmp_root/deploy.service"
printf '# changed by the attempted upgrade\n' >> "$deploy/avalon.service"
: > "$log"
if FAKE_BAD_COMMIT=$bad AVALON_COMMIT=$bad AVALON_CONTEXT=65536 AVALON_PORT=11434 \
        run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade with new settings reported success'
fi
cp "$tmp_root/deploy.service" "$deploy/avalon.service"
contains "Avalon is running $next again" "$tmp_root/out"
contains 'Restoring the settings it last ran with' "$tmp_root/out"
cmp -s "$unit" "$tmp_root/good.service" || fail 'rollback kept the attempted unit'
cmp -s "$envfile" "$tmp_root/good.env" || fail 'rollback kept the attempted environment'
cmp -s "$tree/etc/avalon-target/installed-settings" "$tmp_root/good-settings" || fail 'a failed upgrade changed the record'
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "the rollback was not checked on the recorded port"
: > "$log"
AVALON_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after rollback'; }
contains 'nothing to do' "$tmp_root/out"
pass 'rollback restores the previous settings, environment and unit, not the ones that failed'

rm -f "$tree/etc/avalon-target/installed-env"
: > "$log"
AVALON_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'record migration'; }
[[ -f $tree/etc/avalon-target/installed-env ]] || fail 'a healthy rerun did not backfill its settings'
grep -q 'systemctl stop' "$log" && fail 'record migration stopped the service'
pass 'a healthy rerun without installed-env backfills it without restarting'

rm -f "$tree/etc/avalon-target/installed-env"
: > "$log"
if FAKE_BAD_COMMIT=$bad AVALON_COMMIT=$bad AVALON_PORT=11434 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains 'No record of the previous settings' "$tmp_root/out"
contains "Avalon is running $next again" "$tmp_root/out"
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "a rollback without installed-env was not checked on the fingerprint's port"
pass 'an install without a settings record still rolls back, from its runtime snapshot'

# --- weights: resume, corruption, upstream changes, disk space -------------------
reset_tree
FAKE_CUT=moe-cache-ranking.bin run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resumed download'; }
contains 'download moe-cache-ranking.bin from 100' "$log"
cmp -s "$models/moe-cache-ranking.bin" "$hf/moe-cache-ranking.bin" || fail 'the resumed download differs'
pass 'an interrupted download resumes where it stopped'

reset_tree
out=$(FAKE_CORRUPT=Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf run_target 2>&1) && fail 'a corrupt shard was accepted'
[[ $out == *'Checksum mismatch for Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf'* ]] || fail "corrupt shard message: $out"
[[ ! -e $models/.Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf.part ]] || fail 'the corrupt download was kept'
[[ ! -e $unit ]] || fail 'a unit was installed with corrupt weights'
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after a corrupt shard'; }
cmp -s "$models/Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf" "$hf/Qwen3.8-Flash-Next-Avalon-IQ3KS-00002-of-00033.gguf" ||
    fail 'the shard after a corrupt download'
pass 'a corrupt download is removed and a rerun fetches it again'

reset_tree
out=$(FAKE_CORRUPT=LICENSE run_target 2>&1) && fail 'a license with the wrong blob id was accepted'
[[ $out == *'Checksum mismatch for LICENSE'* ]] || fail "git hash message: $out"
pass 'small non-LFS files are checked against their git blob id'

reset_tree
out=$(FAKE_ETAG=$(printf 'f%.0s' {1..64}) run_target 2>&1) && fail 'a changed upstream file was downloaded'
[[ $out == *'not the reviewed'* && $out == *'update avalon-weights.txt'* ]] || fail "etag message: $out"
grep -q '^download ' "$log" && fail 'something was downloaded before the upstream hashes were checked'
pass 'an upstream file whose hash changed is refused before anything is downloaded'

reset_tree
out=$(FAKE_DF_AVAIL=1073741824 run_target 2>&1) && fail 'an install without room for the weights was started'
[[ $out == *'pct resize'* ]] || fail "disk message: $out"
grep -q '^download ' "$log" && fail 'a download started without room for it'
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'install after freeing space'; }
: > "$log"
FAKE_DF_AVAIL=1024 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'a verified rerun on a full disk'; }
contains 'nothing to do' "$tmp_root/out"
pass 'missing disk space is reported, with the resize command, before any download; a complete install needs no spare room'

reset_tree
AVALON_MTP=false run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'install without MTP'; }
grep -q "download ${MTP_FILE#MTP/}" "$log" && fail 'the MTP head was downloaded without MTP'
grep -q 'draft-mtp' "$envfile" && fail 'MTP arguments without MTP'
pass 'AVALON_MTP=false skips the draft head and its arguments'

reset_tree
AVALON_CONTEXT=auto run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'auto context install'; }
contains 'context 262144 tokens' "$tmp_root/out"
contains ' -c 262144 ' "$envfile"
contains 'AVALON_CONTEXT=262144' "$tree/etc/avalon-target/installed-env"
pass 'AVALON_CONTEXT=auto gives the full 256k on a 20 GB card'

FAKE_VRAM_BYTES=17163091968 reset_tree
AVALON_CONTEXT=auto run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'install on a 16 GB card'; }
contains 'The GPU has 16368 MiB of VRAM: context 65536 tokens.' "$tmp_root/out"
contains ' -c 65536 ' "$envfile"
pass 'with auto, a 16 GB card gets the 64k context upstream suggests below 20 GB'

# --- CUDA ---------------------------------------------------------------------
FAKE_NVIDIA=1 reset_tree
FAKE_NVIDIA=1 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh CUDA install'; }
contains 'cuda-toolkit.sh --check CUDA_VERSION=12.9' "$log"
contains 'GPU 0 has compute capability 89.' "$tmp_root/out"
contains '-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89' "$log"
contains "-DCMAKE_CUDA_COMPILER=$nvcc" "$log"
grep -q 'rocm-toolkit.sh' "$log" && fail 'a CUDA install used the ROCm installer'
contains 'AVALON_BACKEND=cuda' "$tree/etc/avalon-target/installed-env"
contains ' -c 65536 ' "$envfile"
pass 'without /dev/kfd the target builds with CUDA for GPU 0'\''s compute capability'

FAKE_NVIDIA=1 reset_tree
out=$(FAKE_NVIDIA=1 FAKE_CAP=7.0 run_target 2>&1) && fail 'a Volta GPU was accepted'
[[ $out == *'needs 7.5 or newer'* ]] || fail "compute capability message: $out"
grep -qE '^(apt-get|git) ' "$log" && fail 'something changed before the GPU check'
out=$(FAKE_NVIDIA=1 FAKE_CAP=12.0 AVALON_CUDA_VERSION=12.6 AVALON_NVCC_PATH=$tmp_root/cuda-12.6/bin/nvcc run_target 2>&1) &&
    fail 'RTX 50 with CUDA 12.6 was accepted'
[[ $out == *'needs AVALON_CUDA_VERSION=12.8 or newer'* ]] || fail "RTX 50 message: $out"
out=$(FAKE_NVIDIA=1 FAKE_CUDA_UNAVAILABLE=1 run_target 2>&1) && fail 'an unavailable CUDA version was accepted'
[[ $out == *'CUDA 12.9 is not available for this'* ]] || fail "CUDA preflight message: $out"
out=$(FAKE_NVIDIA=1 AVALON_NVCC_PATH=$tmp_root/cuda-13.0/bin/nvcc run_target 2>&1) && fail 'a missing nvcc was accepted'
[[ $out == *'cuda-13.0/bin/nvcc is missing'* ]] || fail "nvcc message: $out"
pass 'CUDA: old GPUs, RTX 50 on CUDA below 12.8, an unavailable toolkit and a missing nvcc are refused'

# --- refusals before anything changes ---------------------------------------------
reset_tree
out=$(AVALON_ROCM_DIR=$tmp_root/rocm-missing run_target 2>&1) && fail 'a missing ROCm was accepted'
[[ $out == *'rocm-missing/bin/amdclang++ is missing'* ]] || fail "ROCm message: $out"
pass 'llama-server is not built when the ROCm tree it is pointed at is missing'

reset_tree
out=$(FAKE_ROCM_UNAVAILABLE=1 run_target 2>&1) && fail 'an unavailable ROCm was accepted'
[[ $out == *'ROCm 7.2.4 is not available for this'* ]] || fail "ROCm preflight message: $out"
grep -qE '^(apt-get|git|cmake) ' "$log" && fail 'something was installed or fetched before the ROCm preflight'
pass 'a ROCm release the distro cannot install stops the installer before anything changes'

FAKE_PCI_DEVICE=0x7550 reset_tree
out=$(run_target 2>&1) && fail 'an RDNA 4 card was accepted'
[[ $out == *'is not RDNA 3'* ]] || fail "RDNA message: $out"
grep -qE '^(apt-get|git|curl) ' "$log" && fail 'something changed before the GPU check'
FAKE_PCI_DEVICE=0x7480 reset_tree
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'install on gfx1102'; }
contains 'gfx1102 should work but is not measured upstream' "$tmp_root/out"
pass 'only RDNA 3 cards are accepted; other RDNA 3 targets than gfx1100 are noted as unmeasured'

FAKE_VRAM_BYTES=8573157376 reset_tree
out=$(run_target 2>&1) && fail 'an 8 GB GPU was accepted'
[[ $out == *'needs a 16 GB card or larger'* ]] || fail "VRAM message: $out"
grep -qE '^(apt-get|git|curl) ' "$log" && fail 'something changed before the VRAM check'
pass 'a GPU with less than 16 GB VRAM is refused before downloads or installation'

reset_tree; rm -f "$dev/dri/renderD128"
out=$(run_target 2>&1) && fail 'a CT without a render node was accepted'
[[ $out == *'No AMD render node'* ]] || fail "render node message: $out"
pass 'a CT without the card'\''s render node is refused'

FAKE_CPU_FLAG=sse4_2 reset_tree
out=$(run_target 2>&1) && fail 'a CPU without AVX2 was accepted'
[[ $out == *'no AVX2'* ]] || fail "AVX2 message: $out"
pass 'a CPU without AVX2 is refused'

FAKE_MEM_KIB=16777216 reset_tree
out=$(run_target 2>&1) && fail 'a 16 GiB CT was accepted'
[[ $out == *'measured with 32 GB or more'* ]] || fail "RAM message: $out"
grep -qE '^(apt-get|git) ' "$log" && fail 'something changed before the RAM check'
pass 'a CT with less than 28 GiB of RAM is refused before anything changes'

reset_tree
out=$(FAKE_GROUP=root run_target 2>&1) && fail 'GPU nodes in group root were accepted'
[[ $out == *'gid=44'* ]] || fail "root group message: $out"
pass 'GPU nodes owned by group root are refused with the pct set fix'

reset_tree
out=$(FAKE_LDD_MISSING=libhipblas.so.3 run_target 2>&1) && fail 'a binary with a missing library was accepted'
[[ $out == *'llama-server cannot find: libhipblas.so.3'* ]] || fail "ldd message: $out"
pass 'a llama-server whose libraries do not resolve fails the build step'

reset_tree
mkdir -p "$tree/opt/avalon"; touch "$tree/opt/avalon/stray"
out=$(run_target 2>&1) && fail 'a non-git /opt/avalon was used'
[[ $out == *'is not a Git checkout'* ]] || fail "non-git message: $out"
pass 'a non-empty non-git source directory is refused'

output=$(env -i "PATH=$PATH" bash "$script_dir/install-target.sh" --dry-run 2>&1)
[[ $output == *"git fetch --depth 1 https://github.com/freriadoc/Avalon.git $(< "$script_dir/upstream-commit.txt") into /opt/avalon"* ]] || fail "dry-run fetch: $output"
[[ $output == *'-DAMDGPU_TARGETS=<the card'\''s gfx target>'* ]] || fail "dry-run cmake: $output"
[[ $output == *'the key [redacted]'* ]] || fail 'dry-run key'
output=$(env -i "PATH=$PATH" AVALON_BACKEND=cuda bash "$script_dir/install-target.sh" --dry-run 2>&1)
[[ $output == *'-DCMAKE_CUDA_ARCHITECTURES=<GPU 0 compute capability>'* && $output == *'cuda-toolkit.sh (CUDA 12.9'* ]] ||
    fail "dry-run cuda: $output"
pass 'the dry run shows the pinned commit, the CMake configure for either backend and no key'

# --- saved settings -------------------------------------------------------------
saved_env() {
    local -a e
    mapfile -t e < <(common_env)
    env -i "${e[@]}" AVALON_COMMIT="$(< "$tree/opt/avalon/.git/HEAD")" "$@"
}
saved_upgrade() { saved_env "$@" bash "$target" --upgrade; }
saved_rerun() { saved_env bash "$target"; }
reset_tree
AVALON_PORT=8123 AVALON_CONTEXT=65536 AVALON_GPU_TARGET=gfx1101 AVALON_MTP=false run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'custom install before saved-settings upgrade'; }
record=$tree/etc/avalon-target/installed-env
contains 'AVALON_GPU_TARGET=gfx1101' "$record"
grep -q 'The AMD card is' "$tmp_root/out" && fail 'an explicit gfx target was detected anyway'
cp "$record" "$tmp_root/custom-settings"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'bare upgrade with saved settings'; }
cmp -s "$record" "$tmp_root/custom-settings" || fail 'bare upgrade reset saved settings'
contains 'nothing to do' "$tmp_root/out"
grep -q 'The AMD card is' "$tmp_root/out" && fail 'a saved gfx target was detected again'
pass 'a bare --upgrade preserves custom settings (the gfx target too) and leaves an unchanged service running'
saved_upgrade AVALON_PORT=8124 > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'saved-settings explicit override'; }
sed 's/^AVALON_PORT=.*/AVALON_PORT=8124/' "$tmp_root/custom-settings" > "$tmp_root/expected-settings"
cmp -s "$record" "$tmp_root/expected-settings" || fail 'an explicit override reset another saved setting'
pass 'an explicit upgrade setting overrides only that saved value'
cp "$record" "$tmp_root/valid-settings"
sed -i 's/^AVALON_PORT=.*/AVALON_PORT=99999/' "$record"
: > "$log"
if saved_upgrade > "$tmp_root/out" 2>&1; then fail 'invalid saved settings were accepted'; fi
contains 'Invalid or incomplete' "$tmp_root/out"
[[ ! -s $log ]] || fail 'invalid saved settings touched the installation'
mv "$tmp_root/valid-settings" "$record"
pass 'invalid saved settings are refused before external commands run'

cp "$record" "$tmp_root/current-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'plain rerun with saved settings'; }
cmp -s "$record" "$tmp_root/current-settings" || fail "a plain rerun reset saved settings: $(tr '\n' ' ' < "$record")"
contains 'nothing to do' "$tmp_root/out"
pass 'a plain rerun (no --upgrade) keeps the saved settings'

: > "$log"
saved_upgrade AVALON_PORT= > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade with an empty port'; }
cmp -s "$record" "$tmp_root/current-settings" || fail 'an empty environment value replaced a saved setting'
pass 'an empty environment value does not override a saved setting'

rm -f "$record"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade from the fingerprint'; }
contains 'Using the settings recorded in' "$tmp_root/out"
contains 'nothing to do' "$tmp_root/out"
cmp -s "$record" "$tmp_root/current-settings" || fail "an upgrade from the fingerprint did not keep (and backfill) its settings"
pass 'an install without installed-env keeps the settings in its fingerprint'

rm -f "$record"
cp "$tree/etc/avalon-target/installed-settings" "$tmp_root/fingerprint"
sed -i '/^port=/d' "$tree/etc/avalon-target/installed-settings"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'an unreadable fingerprint fell back to defaults'; fi
contains 'Cannot read this installation' "$tmp_root/out"
[[ ! -s $log ]] || fail 'an unreadable fingerprint touched the installation'
mv "$tmp_root/fingerprint" "$tree/etc/avalon-target/installed-settings"
cp "$tmp_root/current-settings" "$record"
pass 'an unreadable fingerprint is refused before anything runs, unless every setting is given'
(
    unset "${SETTING_KEYS[@]}"
    AVALON_ETC_DIR="$tree/etc/avalon-target"
    AVALON_CUDA_VERSION=13.0
    saved_settings
    [[ $AVALON_CUDA_VERSION == 13.0 && ! -v AVALON_NVCC ]] || fail 'a changed CUDA version retained the old compiler'
) || fail 'toolkit version override'
(
    unset "${SETTING_KEYS[@]}"
    AVALON_ETC_DIR="$tree/etc/avalon-target"
    AVALON_BACKEND=cuda
    saved_settings
    [[ $AVALON_BACKEND == cuda && $AVALON_GPU_TARGET == auto && $AVALON_CONTEXT == auto && $AVALON_PORT == 8124 ]] ||
        fail "a backend switch kept the old GPU settings: $AVALON_GPU_TARGET $AVALON_CONTEXT $AVALON_PORT"
) || fail 'backend override'
pass 'a CUDA version override derives a new compiler; a backend switch detects its GPU and context again'

# Lost metadata must not turn a configured target into a fresh installation.
cp "$record" "$tmp_root/recovery-settings"
rm -f "$record" "$tree/etc/avalon-target/installed-settings"
for metadata_state in missing dangling; do
    if [[ $metadata_state == dangling ]]; then
        ln -s "$tree/etc/avalon-target/missing-fingerprint" "$tree/etc/avalon-target/installed-settings"
    fi
    for invocation in saved_rerun saved_upgrade; do
        : > "$log"
        if "$invocation" > "$tmp_root/out" 2>&1; then
            fail "$metadata_state metadata was accepted by $invocation"
        fi
        if [[ $metadata_state == dangling ]]; then
            contains 'Cannot read this installation' "$tmp_root/out"
        else
            contains 'no readable settings record' "$tmp_root/out"
        fi
        [[ ! -s $log && ! -e $record ]] || fail "$metadata_state metadata touched the installation"
    done
    rm -f "$tree/etc/avalon-target/installed-settings"
done
pass 'missing and dangling settings records are refused before a plain rerun or upgrade changes anything'

mv "$unit" "$tmp_root/recovery-unit"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'a checkout without metadata was treated as fresh'; fi
contains 'Found an existing' "$tmp_root/out"
[[ ! -s $log ]] || fail 'a checkout without metadata was changed'
mv "$tmp_root/recovery-unit" "$unit"
pass 'an existing checkout is protected independently of the settings records'

mapfile -t recovery_settings < "$tmp_root/recovery-settings"
saved_upgrade "${recovery_settings[@]}" > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'explicit recovery from missing metadata'; }
cmp -s "$record" "$tmp_root/recovery-settings" || fail 'explicit recovery changed a setting'
[[ -s $tree/etc/avalon-target/installed-settings ]] || fail 'explicit recovery did not recreate the fingerprint'
pass 'complete explicit settings recover lost metadata without resetting custom values'

# A first install that stops part-way resumes with the settings it was started with.
reset_tree
pbad=fedcba9876543210fedcba9876543210fedcba98
if FAKE_BAD_COMMIT=$pbad AVALON_COMMIT=$pbad AVALON_PORT=8123 AVALON_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a first install whose build fails reported success'
fi
pending=$tree/etc/avalon-target/pending-env
[[ -f $pending && ! -e $record ]] || fail 'an interrupted first install left no pending-env, or a settings record'
[[ $(stat -c %a "$pending") == 600 ]] || fail 'pending-env is not root-only'
contains 'AVALON_PORT=8123' "$pending"
contains 'AVALON_GPU_TARGET=gfx1100' "$pending"
cp "$pending" "$tmp_root/started-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming the interrupted install'; }
contains 'Resuming an interrupted install' "$tmp_root/out"
cmp -s "$record" "$tmp_root/started-settings" || fail "the resumed install did not keep its settings: $(tr '\n' ' ' < "$record")"
[[ ! -e $pending ]] || fail 'pending-env was left after a successful install'
pass 'an interrupted first install resumes with the settings it was started with'

reset_tree
if FAKE_METADATA_FAIL=1 AVALON_PORT=8123 AVALON_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed fingerprint rename reported success'
fi
[[ -f $pending && -s $record && ! -e $tree/etc/avalon-target/installed-settings ]] ||
    fail 'failed metadata promotion lost its complete recovery records'
cp "$pending" "$tmp_root/started-settings"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming after metadata publication failure'; }
cmp -s "$record" "$tmp_root/started-settings" || fail 'metadata-failure resume lost custom settings'
[[ ! -e $pending ]] || fail 'metadata-failure resume retained checkpoint'
pass 'a bare rerun recovers settings after interruption between metadata renames'

bash "$script_dir/../../tests/lib/check-target-records.sh" "$script_dir/install-target.sh" "$tmp_root/record-failures" ||
    fail 'atomic settings record failure tests'
pass 'failed and interrupted metadata writes preserve complete settings records'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
