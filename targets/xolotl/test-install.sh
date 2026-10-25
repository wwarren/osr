#!/usr/bin/env bash
# Exercise install-target.sh: its helpers (checkout checks, CMake arguments,
# the weights manifest, the server config, the settings record) and
# engram-index.py, then whole-script runs against a temporary tree with stubbed
# git, the venv, cmake, systemctl, curl (Hugging Face and the API), nvidia-smi
# and account tools. Nothing is downloaded, built, installed or started.
# The XOLOTL_* assignments below are read by the sourced helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/xolotl-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/xolotl-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# A minimal Xolotl checkout: the files, CMake options, engine flags and server
# config keys install-target.sh checks for.
fixture=$tmp_root/upstream
make_fixture() {
    local dir=$1 flag
    mkdir -p "$dir/tools/xolotl" "$dir/tools/v41/serve" "$dir/tools/v41/engine" "$dir/serve"
    printf 'project(strata)\noption(STRATA_ENABLE_CUDA "" OFF)\noption(STRATA_GGML_CUDA "" OFF)\noption(STRATA_MMQ_KQUANTS "" ON)\nset(STRATA_GGML_DIR "")\n' > "$dir/CMakeLists.txt"
    printf 'option(STRATA_DSV41_FQ_OP "" OFF)\noption(STRATA_DSV41_HC_MIX "" OFF)\n' > "$dir/tools/v41/engine/v41_engine.cmake"
    : > "$dir/requirements.txt"
    printf '#!/usr/bin/env bash\nPIN=3cf03257f219afbe7334045ff7c6a06ac68c627d\n' > "$dir/tools/xolotl/fetch-llama.sh"
    printf 'print("serve")\n' > "$dir/tools/v41/serve/serve_ds41.py"
    printf '0 1 2\n' > "$dir/tools/v41/serve/dspark_expert_counts.txt"
    for flag in -m --backend --experts --engram --rank --ctx --stop --arena-adapt --kv-fp4 --route-bias \
                --route-bias-file --arena-gib --tier-batch-pcie --prompt-batch; do
        printf 'if (a == "%s") {}\n' "$flag"
    done > "$dir/tools/v41/engine/ds41_generate.cpp"
    printf 'a.host = a.host or cfg.get("host")\nsvc.api_key = api_key_of(a.api_key or cfg.get("api_key", ""))\n' > "$dir/serve/server.py"
}
make_fixture "$fixture"

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in validate_checkout cmake_args compute_cap_arch model_path engram_dir weight_rows validate_settings \
              settings_env load_settings fingerprint_env saved_settings server_config settings_fingerprint start_env; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done
XOLOTL_DIR=$fixture XOLOTL_DATA_DIR=/var/lib/xolotl XOLOTL_CUDA_VERSION=13.0 XOLOTL_NVCC=/usr/local/cuda-13.0/bin/nvcc
XOLOTL_CUDA_ARCH=89 XOLOTL_PORT=8080 XOLOTL_CONTEXT=131072 XOLOTL_ARENA_GIB=60 XOLOTL_DSPARK=true
XOLOTL_MODEL_NAME=deepseek-v4.1-flash

validate_checkout "$fixture" || fail 'the fixture checkout was refused'
for broken in serve/server.py tools/v41/serve/dspark_expert_counts.txt; do
    cp -a "$fixture" "$tmp_root/broken"; rm -f "$tmp_root/broken/$broken"
    out=$(validate_checkout "$tmp_root/broken" 2>&1) && fail "a checkout without $broken was accepted"
    [[ $out == *"lacks: $broken"* ]] || fail "missing-file message: $out"
    rm -rf "$tmp_root/broken"
done
cp -a "$fixture" "$tmp_root/broken"; sed -i '/--tier-batch-pcie/d' "$tmp_root/broken/tools/v41/engine/ds41_generate.cpp"
sed -i '/STRATA_DSV41_HC_MIX/d' "$tmp_root/broken/tools/v41/engine/v41_engine.cmake"
out=$(validate_checkout "$tmp_root/broken" 2>&1) && fail 'an engine without --tier-batch-pcie was accepted'
[[ $out == *'does not accept: -DSTRATA_DSV41_HC_MIX --tier-batch-pcie'* ]] || fail "flag message: $out"
rm -rf "$tmp_root/broken"; cp -a "$fixture" "$tmp_root/broken"; sed -i '/api_key/d' "$tmp_root/broken/serve/server.py"
out=$(validate_checkout "$tmp_root/broken" 2>&1) && fail 'a server that ignores the config key was accepted'
[[ $out == *'does not read "api_key"'* ]] || fail "server message: $out"
rm -rf "$tmp_root/broken"
pass 'a checkout must carry the files, CMake options, engine flags and config keys the installer relies on'

args=$(cmake_args | tr '\n' ' ')
[[ $args == *"-G Ninja"* && $args == *"-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc"* &&
   $args == *"-DCMAKE_CUDA_ARCHITECTURES=89"* && $args == *"-DSTRATA_GGML_DIR=$fixture/third_party/llama.cpp"* &&
   $args == *"-DSTRATA_DSV41_FQ_OP=ON -DSTRATA_DSV41_HC_MIX=ON"* && $args == *"-DCMAKE_MAKE_PROGRAM=$fixture/.venv/bin/ninja"* ]] ||
    fail "cmake args: $args"
[[ $(compute_cap_arch <<< '8.9') == 89 && $(compute_cap_arch <<< $'12.0\n8.6') == 120 && $(compute_cap_arch <<< ' 7.5 ') == 75 ]] ||
    fail 'compute capability parsing'
compute_cap_arch <<< 'N/A' && fail 'a malformed compute capability was accepted'
pass 'the engine is configured with the installed nvcc, the GPU architecture and the patched llama.cpp'

# The shipped manifest: pinned revisions, the parts add up to the joined file.
manifest=$script_dir/xolotl-weights.txt
rows=$(weight_rows "$manifest") || fail 'the shipped manifest was refused'
[[ $(grep -c '^part ' <<< "$rows") == 16 && $(grep -c '^join ' <<< "$rows") == 1 ]] || fail 'part and join rows'
[[ $(awk '$1 == "part" { s += $3 } $1 == "join" { j = $3 } END { print s == j }' <<< "$rows") == 1 ]] ||
    fail 'the parts do not add up to the joined size'
grep -q 'V41-MTP-Vision-1017.Q2_K.gguf' <<< "$rows" || fail 'DSpark sidecar missing with XOLOTL_DSPARK=true'
[[ $(grep -c '^file engram-1017/model-0004[78]-of-00048.safetensors ' <<< "$rows") == 2 ]] || fail 'engram shards'
awk '$1 != "join" && $5 !~ /\/resolve\/[0-9a-f]{40}\// { exit 1 }' <<< "$rows" || fail 'a URL is not pinned to a commit'
XOLOTL_DSPARK=false
grep -q 'V41-MTP-Vision' <<< "$(weight_rows "$manifest")" && fail 'the sidecar is listed without DSpark'
XOLOTL_DSPARK=true
for bad in 'model file ../etc/passwd 1 sha256:'"$(printf '0%.0s' {1..64})"' https://huggingface.co/x' \
           'model file a/b 1 sha256:abc https://huggingface.co/x' \
           'model file a/b 1 git:'"$(printf 'a%.0s' {1..40})"' http://huggingface.co/x' \
           'model file a/b 1 git:'"$(printf 'a%.0s' {1..40})"' https://example.com/x' \
           'model join a/b 1 sha256:'"$(printf '0%.0s' {1..64})"' https://huggingface.co/x'; do
    printf '%s\n' "$bad" > "$tmp_root/bad-manifest"
    out=$(weight_rows "$tmp_root/bad-manifest" 2>&1) && fail "a malformed manifest row was accepted: $bad"
    [[ $out == *'malformed row'* ]] || fail "malformed row message: $out"
done
pass 'the weights manifest is pinned, consistent and strictly parsed'

api_key=sk-test-key
config=$(server_config)
python3 -c '
import json, sys
c = json.loads(sys.argv[1])
assert c["api_key"] == "sk-test-key" and c["host"] == "0.0.0.0" and c["model_name"] == "deepseek-v4.1-flash"
assert c["exe"].endswith("/build-xolotl/ds41_generate") and c["tokenizer"] == "/var/lib/xolotl/models/v41-xq-1017-v4/tokenizer"
a = c["args"]
assert a[a.index("--engram") + 1] == "/var/lib/xolotl/models/engram-1017"
assert a[a.index("--rank") + 1].endswith("/rank-1017-v4.bin")
assert a[a.index("--ctx") + 1] == "131072" and a[a.index("--arena-gib") + 1] == "60"
assert a[a.index("--tier-batch-pcie") + 1] == "0.25"
assert c["env"]["STRATA_SERVE_DSPARK"].endswith("V41-MTP-Vision-1017.Q2_K.gguf")
assert c["env"]["STRATA_ENGRAM_RAWDEV"] == "0"
assert c["env"]["STRATA_DENSE_REQUANT_CACHE"] == "/var/lib/xolotl/cache/dense-requant"
' "$config" || fail "server config: $config"
XOLOTL_DSPARK=false
[[ $(server_config) != *DSPARK* ]] || fail 'DSpark settings without XOLOTL_DSPARK'
XOLOTL_DSPARK=true
[[ $(start_env) == *'XOLOTL_PORT=8080' && $(start_env) != *sk-test-key* ]] || fail "unit environment: $(start_env)"
pass 'the server config carries the model, Engram, rank, arena and key; the unit environment does not carry the key'

settings_env > "$tmp_root/installed-env"
[[ $(grep -c '^XOLOTL_' "$tmp_root/installed-env") == 8 ]] || fail "settings record: $(cat "$tmp_root/installed-env")"
XOLOTL_CONTEXT=65536 XOLOTL_PORT=11434 XOLOTL_CUDA_ARCH=120
load_settings "$tmp_root/installed-env" || fail 'a valid record was not loaded'
[[ $XOLOTL_CONTEXT == 131072 && $XOLOTL_PORT == 8080 && $XOLOTL_CUDA_ARCH == 89 ]] ||
    fail "record not restored: $XOLOTL_CONTEXT $XOLOTL_PORT $XOLOTL_CUDA_ARCH"
for bad in 's/^XOLOTL_PORT=.*/XOLOTL_PORT=99999/' 's/^XOLOTL_CUDA_ARCH=.*/XOLOTL_CUDA_ARCH=70/' \
           's/^XOLOTL_DSPARK=.*/XOLOTL_DSPARK=yes/' 's/^XOLOTL_MODEL_NAME=.*/XOLOTL_MODEL_NAME=Bad Name/'; do
    sed "$bad" "$tmp_root/installed-env" > "$tmp_root/bad-env"
    XOLOTL_PORT=11434
    load_settings "$tmp_root/bad-env" && fail "an invalid record was loaded ($bad)"
    [[ $XOLOTL_PORT == 11434 ]] || fail 'an invalid record changed a setting'
done
grep -v '^XOLOTL_DSPARK=' "$tmp_root/installed-env" > "$tmp_root/old-env"
load_settings "$tmp_root/old-env" && fail 'a record without every key was loaded'
printf 'XOLOTL_PORT=8080; touch %s/pwned\n' "$tmp_root" > "$tmp_root/evil-env"
load_settings "$tmp_root/evil-env" && fail 'a malformed record was loaded'
[[ ! -e $tmp_root/pwned ]] || fail 'the record was executed'
XOLOTL_PORT=8080
pass 'the settings record is read back all-or-nothing and never executed'

# engram-index.py: the index the engine reads, from the shards' own headers.
make_shard() {   # make_shard FILE LAYER [extra tensor name]
    python3 - "$@" <<'PY'
import json, struct, sys
path, layer = sys.argv[1], sys.argv[2]
names = [f"layers.{layer}.engram.embed.weight", f"layers.{layer}.engram.embed.scale"] + sys.argv[3:]
hdr, off = {"__metadata__": {"format": "pt"}}, 0
for n in names:
    hdr[n] = {"dtype": "F8_E4M3", "shape": [4], "data_offsets": [off, off + 4]}
    off += 4
raw = json.dumps(hdr).encode()
open(path, "wb").write(struct.pack("<Q", len(raw)) + raw + bytes(off))
PY
}
edir=$tmp_root/engram; mkdir -p "$edir"
make_shard "$edir/model-00047-of-00048.safetensors" 1
make_shard "$edir/model-00048-of-00048.safetensors" 14 layers.14.ffn.weight
python3 "$script_dir/engram-index.py" "$edir" model-00047-of-00048.safetensors model-00048-of-00048.safetensors > /dev/null ||
    fail 'valid shards were not indexed'
python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))["weight_map"]
assert m["layers.1.engram.embed.weight"] == "model-00047-of-00048.safetensors"
assert m["layers.14.engram.embed.scale"] == "model-00048-of-00048.safetensors"
assert m["layers.14.ffn.weight"] == "model-00048-of-00048.safetensors"
' "$edir/model.safetensors.index.json" || fail 'index contents'
cp "$edir/model.safetensors.index.json" "$tmp_root/good-index"
python3 - "$edir/model-00048-of-00048.safetensors" <<'PY'
import json, struct, sys
raw = json.dumps({"layers.14.engram.embed.weight": {"dtype": "F8_E4M3", "shape": [4], "data_offsets": [0, 4]}}).encode()
open(sys.argv[1], "wb").write(struct.pack("<Q", len(raw)) + raw + bytes(4))
PY
out=$(python3 "$script_dir/engram-index.py" "$edir" model-00047-of-00048.safetensors model-00048-of-00048.safetensors 2>&1) &&
    fail 'a layer without its scale was indexed'
[[ $out == *'lack an Engram weight or scale'* ]] || fail "incomplete layer message: $out"
cmp -s "$edir/model.safetensors.index.json" "$tmp_root/good-index" || fail 'a failed run replaced the index'
make_shard "$edir/model-00048-of-00048.safetensors" 1
out=$(python3 "$script_dir/engram-index.py" "$edir" model-00047-of-00048.safetensors model-00048-of-00048.safetensors 2>&1) &&
    fail 'a tensor in two shards was indexed'
[[ $out == *'is in both'* ]] || fail "duplicate message: $out"
printf 'garbage' > "$edir/model-00048-of-00048.safetensors"
out=$(python3 "$script_dir/engram-index.py" "$edir" model-00047-of-00048.safetensors model-00048-of-00048.safetensors 2>&1) &&
    fail 'a truncated shard was indexed'
out=$(python3 "$script_dir/engram-index.py" "$edir" ../model-00047-of-00048.safetensors 2>&1) &&
    fail 'a shard outside the directory was accepted'
pass 'engram-index.py maps every Engram tensor to its shard and refuses incomplete, duplicate or broken shards'

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
# The installer runs from a copy whose cuda-toolkit.sh is a stub that only logs
# (the real one installs packages) and whose manifest lists small fixture files
# served by the curl stub.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
cp "$script_dir/install-target.sh" "$script_dir/xolotl.service" "$script_dir/engram-index.py" \
    "$script_dir/upstream-commit.txt" "$deploy/"
log=$tmp_root/calls.log
printf '#!/usr/bin/env bash\necho "cuda-toolkit.sh $* CUDA_VERSION=$CUDA_VERSION CUDA_NVCC=${CUDA_NVCC:-}" >> "%s"\n[[ $1 == --check && ${FAKE_CUDA_UNAVAILABLE:-0} == 1 ]] && { echo "NVIDIA repository lacks it" >&2; exit 1; }\nexit 0\n' "$log" > "$deploy/cuda-toolkit.sh"
target=$deploy/install-target.sh

# The fixture "Hugging Face": files by URL basename.
hf=$tmp_root/hf; mkdir -p "$hf"
head -c 3000 /dev/urandom > "$hf/model.gguf"
head -c 1200 "$hf/model.gguf" > "$hf/part-1"
tail -c +1201 "$hf/model.gguf" | head -c 1200 > "$hf/part-2"
tail -c +2401 "$hf/model.gguf" > "$hf/part-3"
head -c 400 /dev/urandom > "$hf/rank-1017-v4.bin"
printf '{"a": 1}\n' > "$hf/vocab.json"
head -c 700 /dev/urandom > "$hf/V41-MTP-Vision-1017.Q2_K.gguf"
make_shard "$hf/model-00047-of-00048.safetensors" 1
make_shard "$hf/model-00048-of-00048.safetensors" 14
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }
url=https://huggingface.co/test/repo/resolve/0123456789abcdef0123456789abcdef01234567
{
    for n in 1 2 3; do printf 'model part v41-xq-1017-v4/V41-XQ-1017-v4.gguf %s sha256:%s %s/part-%s\n' "$(size "$hf/part-$n")" "$(sha "$hf/part-$n")" "$url" "$n"; done
    printf 'model join v41-xq-1017-v4/V41-XQ-1017-v4.gguf %s sha256:%s -\n' "$(size "$hf/model.gguf")" "$(sha "$hf/model.gguf")"
    printf 'model file v41-xq-1017-v4/rank-1017-v4.bin %s sha256:%s %s/rank-1017-v4.bin\n' "$(size "$hf/rank-1017-v4.bin")" "$(sha "$hf/rank-1017-v4.bin")" "$url"
    printf 'model file v41-xq-1017-v4/tokenizer/vocab.json %s git:%s %s/vocab.json\n' "$(size "$hf/vocab.json")" "$(git hash-object --no-filters "$hf/vocab.json")" "$url"
    printf 'dspark file v41-xq-1017-v4/V41-MTP-Vision-1017.Q2_K.gguf %s sha256:%s %s/V41-MTP-Vision-1017.Q2_K.gguf\n' "$(size "$hf/V41-MTP-Vision-1017.Q2_K.gguf")" "$(sha "$hf/V41-MTP-Vision-1017.Q2_K.gguf")" "$url"
    for n in 47 48; do f=model-000$n-of-00048.safetensors; printf 'engram file engram-1017/%s %s sha256:%s %s/%s\n' "$f" "$(size "$hf/$f")" "$(sha "$hf/$f")" "$url" "$f"; done
} > "$deploy/xolotl-weights.txt"
cp "$deploy/xolotl-weights.txt" "$tmp_root/good-weights.txt"

bin=$tmp_root/bin; mkdir -p "$bin"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub getent 'exit 2'   # no xolotl group yet, so it is created
stub mv 'if [[ ${FAKE_METADATA_FAIL:-0} == 1 && ${*: -1} == */installed-settings ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
for command_name in apt-get groupadd useradd usermod chown chgrp sleep; do stub "$command_name" 'exit 0'; done
stub stat 'if [[ $1 == -c && $2 == %G ]]; then echo "${FAKE_GROUP:-video}"; else exec /usr/bin/stat "$@"; fi'
stub systemctl 'case "$1" in is-failed) exit 1;; is-active) exit "${FAKE_INACTIVE:-0}";; esac; exit 0'
stub tar 'if [[ ${FAKE_SNAPSHOT_FAIL:-0} == 1 && $* == *"-cpf "* ]]; then exit 1; fi; exec /usr/bin/tar "$@"'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub df 'printf "Filesystem 1-blocks Used Available Capacity Mounted\nfake 1 1 %s 1%% /\n" "${FAKE_DF_AVAIL:-1099511627776}"'
stub nvidia-smi 'if [[ $* == *compute_cap* ]]; then echo "${FAKE_CAP:-8.9}"; elif [[ $* == *memory.total* ]]; then echo "${FAKE_VRAM_MIB:-24564}"; else echo "GPU 0: NVIDIA GeForce RTX 4090"; fi'
# curl: Hugging Face HEAD answers (X-Linked-Size/-Etag as the CDN sends them),
# resumable downloads from the fixture directory, and the Xolotl API.
# FAKE_HF_DOWN=1: Hugging Face does not answer; FAKE_ETAG=<hex>: a different
# upstream hash; FAKE_CORRUPT=<name>: that file arrives with a flipped byte;
# FAKE_CUT=<name>: that download stops half-way once; FAKE_READY=0: the model
# never loads.
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
                vocab.json) ;;
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
    */health) printf '{"status":"ok","model":"%s","loaded":%s,"service":"strata"}\n' "\${FAKE_MODEL:-deepseek-v4.1-flash}" "\$( [[ \${FAKE_READY:-1} == 1 ]] && echo true || echo false)" ;;
    */v1/models) printf '{"data":[{"id":"%s"}]}\n' "\${FAKE_MODEL:-deepseek-v4.1-flash}" ;;
    *) exit 22 ;;
esac
STUB
chmod +x "$bin/curl"
# python3: "-m venv" makes a fake venv whose python logs pip and whose cmake
# logs the configure and "builds" ds41_generate (FAKE_BAD_COMMIT: the build
# fails at that commit); everything else is the real interpreter.
real_python=$(command -v python3)
cat > "$bin/python3" <<STUB
#!/usr/bin/env bash
if [[ \$1 == -m && \$2 == venv ]]; then
    echo "python3 -m venv \$3" >> "$log"
    mkdir -p "\$3/bin"
    printf '#!/usr/bin/env bash\necho "venv-python \$*" >> "$log"\nexit 0\n' > "\$3/bin/python"
    cat > "\$3/bin/cmake" <<'CMAKE'
#!/usr/bin/env bash
echo "cmake \$* @\$(cat .git/HEAD)" >> "$log"
if [[ \$1 == --build ]]; then
    [[ \$(cat .git/HEAD) == "\${FAKE_BAD_COMMIT:-none}" ]] && { rm -f build-xolotl/rollback-marker; echo broken > runtime-from-failed-upgrade; exit 1; }
    mkdir -p build-xolotl; printf '#!/bin/sh\n' > build-xolotl/ds41_generate; chmod +x build-xolotl/ds41_generate
fi
exit 0
CMAKE
    chmod +x "\$3/bin/python" "\$3/bin/cmake"
    exit 0
fi
exec "$real_python" "\$@"
STUB
chmod +x "$bin/python3"
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
        if [[ \$2 == FETCH_HEAD* ]]; then cat "\$dir/.git/FETCH"
        elif [[ -f \$dir/.git/HEAD ]]; then cat "\$dir/.git/HEAD"
        else cat "\$dir/HEAD-llama" 2>/dev/null || exit 128; fi ;;
esac
STUB
chmod +x "$bin/git"
# fetch-llama.sh of the fixture: logs and "clones" llama.cpp at its pin.
printf '#!/usr/bin/env bash\necho "fetch-llama.sh" >> "%s"\nmkdir -p third_party/llama.cpp\nsed -n "s/^PIN=//p" "$0" > third_party/llama.cpp/HEAD-llama\n' "$log" >> "$fixture/tools/xolotl/fetch-llama.sh"

tree=$tmp_root/tree
dev=$tmp_root/dev
meminfo=$tmp_root/meminfo
reset_tree() {
    rm -rf "$tree" "$dev" "$tmp_root/cut-done"; mkdir -p "$tree/etc/systemd/system" "$dev"
    touch "$dev/nvidia0" "$dev/nvidiactl" "$dev/nvidia-uvm"
    printf 'MemTotal:       %s kB\n' "${FAKE_MEM_KIB:-100663296}" > "$meminfo"
    cp "$tmp_root/good-weights.txt" "$deploy/xolotl-weights.txt"
    : > "$log"
}
run_target() {
    env PATH="$bin:$PATH" XOLOTL_DIR="$tree/opt/xolotl" XOLOTL_DATA_DIR="$tree/var/lib/xolotl" \
        XOLOTL_ETC_DIR="$tree/etc/xolotl-target" XOLOTL_CONFIG_DIR="$tree/etc/xolotl" \
        XOLOTL_STATE_DIR="$tree/var/lib/xolotl-target" UNIT_DIR="$tree/etc/systemd/system" \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" MEMINFO="$meminfo" XOLOTL_READY_TIMEOUT=5 \
        XOLOTL_COMMIT="${XOLOTL_COMMIT-}" XOLOTL_REF="${XOLOTL_REF-}" XOLOTL_PORT="${XOLOTL_PORT:-8080}" \
        XOLOTL_CONTEXT="${XOLOTL_CONTEXT:-131072}" XOLOTL_NVCC="${XOLOTL_NVCC_PATH:-$nvcc}" \
        bash "$target" "$@"
}
contains() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }
sha_of() { printf '%s' "$1" | sha1sum | cut -c1-40; }
nvcc=$tmp_root/cuda-13.0/bin/nvcc
mkdir -p "${nvcc%/*}"; printf '#!/bin/sh\necho "Cuda compilation tools, release 13.0, V13.0.48"\n' > "$nvcc"; chmod +x "$nvcc"
models=$tree/var/lib/xolotl/models
cfg=$tree/etc/xolotl/xolotl-ds41.json

reset_tree
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
unit=$tree/etc/systemd/system/xolotl.service
cmp -s "$unit" "$script_dir/xolotl.service" || fail 'unit not installed'
contains 'XOLOTL_PORT=8080' "$tree/etc/xolotl-target/xolotl.env"
key=$(< "$tree/etc/xolotl-target/api-key")
[[ $key =~ ^[0-9a-f]{64}$ ]] || fail 'no generated key'
[[ $(stat -c %a "$tree/etc/xolotl-target/api-key") == 600 ]] || fail 'key file mode'
[[ $(stat -c %a "$cfg") == 640 ]] || fail "config mode $(stat -c %a "$cfg")"
contains "\"api_key\": \"$key\"" "$cfg"
grep -q -- "$key" "$tmp_root/out" && fail 'the key was printed'
grep -q -- "$key" "$tree/etc/xolotl-target/xolotl.env" && fail 'the key is in the unit environment'
grep -q -- "$key" "$log" && fail 'the key reached a command line'
contains 'cuda-toolkit.sh --check CUDA_VERSION=13.0' "$log"
contains 'GPU 0 has compute capability 89.' "$tmp_root/out"
contains "-DCMAKE_CUDA_ARCHITECTURES=89" "$log"
contains "-DCMAKE_CUDA_COMPILER=$nvcc" "$log"
contains 'cmake --build build-xolotl --target ds41_generate' "$log"
contains 'fetch-llama.sh' "$log"
contains 'usermod -aG video xolotl' "$log"
contains 'systemctl enable xolotl.service' "$log"
contains 'arch=89' "$tree/etc/xolotl-target/installed-settings"
pass 'fresh install as the xolotl account: engine built for the GPU found, key only in the root:xolotl config'

cmp -s "$models/v41-xq-1017-v4/V41-XQ-1017-v4.gguf" "$hf/model.gguf" || fail 'the joined model differs from its parts'
[[ -z $(find "$models" -name '.*.part*' -o -name '.*.joining') ]] || fail 'download leftovers remain'
cmp -s "$models/v41-xq-1017-v4/tokenizer/vocab.json" "$hf/vocab.json" || fail 'tokenizer file'
[[ -f $models/v41-xq-1017-v4/V41-MTP-Vision-1017.Q2_K.gguf ]] || fail 'DSpark sidecar'
contains '"layers.14.engram.embed.weight": "model-00048-of-00048.safetensors"' "$models/engram-1017/model.safetensors.index.json"
[[ $(wc -l < "$tree/etc/xolotl-target/verified-weights") == 6 ]] || fail "verified record: $(cat "$tree/etc/xolotl-target/verified-weights")"
[[ $(grep -c 'download part-' "$log") == 3 ]] || fail 'each part was not downloaded exactly once'
pass 'the weights are downloaded, verified, joined part by part, and the Engram shards indexed'

: > "$log"
FAKE_HF_DOWN=1 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'no-op rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged rerun stopped the service'
grep -q '^cmake ' "$log" && fail 'an unchanged rerun rebuilt'
grep -q 'huggingface.co' "$log" && fail 'an unchanged rerun contacted Hugging Face'
grep -q 'sha256sum' "$log" && fail 'an unchanged rerun hashed the weights again'
pass 'an unchanged, healthy install is left running, with no download and no rehash'

: > "$log"
FAKE_MAIN_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa XOLOTL_REF=main run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'new main rerun'; }
[[ $(< "$tree/opt/xolotl/.git/HEAD") == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || fail 'rerun did not move to the new main'
contains 'Upgrading Xolotl' "$tmp_root/out"
contains 'systemctl stop xolotl.service' "$log"
contains "update-ref refs/xolotl/previous $(< "$script_dir/upstream-commit.txt")" "$log"
contains 'cmake --build build-xolotl --target ds41_generate' "$log"
[[ $(< "$tree/etc/xolotl-target/api-key") == "$key" ]] || fail 'rerun replaced the key'
pass 'a new upstream commit rebuilds on a rerun, keeping the key and a rollback ref'

commit=0123456789abcdef0123456789abcdef01234567
: > "$log"
XOLOTL_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'pinned rerun'; }
[[ $(< "$tree/opt/xolotl/.git/HEAD") == "$commit" ]] || fail 'pinned rerun did not move HEAD'
contains "fetch -q --depth 1 origin $commit" "$log"
pass 'an explicit commit pin overrides the branch'

: > "$log"
FAKE_INACTIVE=3 XOLOTL_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'inactive rerun'; }
contains 'Re-applying Xolotl' "$tmp_root/out"
contains 'systemctl restart xolotl.service' "$log"
pass 'a stopped service is brought back on a rerun even when nothing changed'

: > "$log"
XOLOTL_COMMIT=$commit XOLOTL_CONTEXT=262144 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'context rerun'; }
contains 'Re-applying Xolotl' "$tmp_root/out"
contains '"262144"' "$cfg"
contains 'XOLOTL_CONTEXT=262144' "$tree/etc/xolotl-target/installed-env"
printf '{"edited": true}\n' > "$cfg"
: > "$log"
XOLOTL_COMMIT=$commit XOLOTL_CONTEXT=262144 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'edited config rerun'; }
contains 'Re-applying Xolotl' "$tmp_root/out"
contains '"262144"' "$cfg"
pass 'a changed setting or a hand-edited config is re-applied, and the setting is kept afterwards'

# A stale llama.cpp tree (fetch-llama.sh keeps any patched tree) is replaced.
printf '1111111111111111111111111111111111111111\n' > "$tree/opt/xolotl/third_party/llama.cpp/HEAD-llama"
: > "$log"
FAKE_INACTIVE=3 XOLOTL_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'stale llama.cpp rerun'; }
contains 'not the pinned 3cf03257f219afbe7334045ff7c6a06ac68c627d; fetching it again' "$tmp_root/out"
[[ $(< "$tree/opt/xolotl/third_party/llama.cpp/HEAD-llama") == 3cf03257f219afbe7334045ff7c6a06ac68c627d ]] || fail 'llama.cpp not refetched'
pass 'a llama.cpp tree at another commit than the checkout pins is fetched again'

: > "$log"
before=$(< "$tree/opt/xolotl/.git/HEAD")
if FAKE_FETCH_FAIL=1 XOLOTL_COMMIT=123456789abcdef0123456789abcdef012345678 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade without network reported success'
fi
contains 'was not stopped or changed' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'a failed fetch stopped the service'
[[ $(< "$tree/opt/xolotl/.git/HEAD") == "$before" ]] || fail 'a failed fetch moved the checkout'
pass 'a failed fetch leaves the running service untouched'

: > "$log"
if FAKE_SNAPSHOT_FAIL=1 XOLOTL_COMMIT=$commit XOLOTL_PORT=8123 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed runtime snapshot reported success'
fi
contains 'Runtime snapshot failed; the previous service is running again.' "$tmp_root/out"
grep -q '^cmake ' "$log" && fail 'a failed snapshot reached the build'
[[ ! -e $tree/var/lib/xolotl-target/rollback-runtime.tar.new ]] || fail 'partial snapshot was not removed'
[[ $(grep '^curl ' "$log" | tail -n1) == *'127.0.0.1:8080/v1/models'* ]] || fail 'snapshot failure probed the attempted port'
pass 'a snapshot failure aborts before the build and restarts the original service'

: > "$log"
next=123456789abcdef0123456789abcdef012345678
XOLOTL_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade'; }
[[ ! -e $tree/var/lib/xolotl-target/rollback-runtime.tar && ! -e $tree/var/lib/xolotl-target/rollback.json ]] ||
    fail 'the snapshot was kept after a successful upgrade'
[[ $(< "$tree/opt/xolotl/.git/HEAD") == "$next" ]] || fail 'upgrade did not move HEAD'
printf 'previous runtime\n' > "$tree/opt/xolotl/build-xolotl/rollback-marker"
bad=fedcba9876543210fedcba9876543210fedcba98
: > "$log"
if FAKE_BAD_COMMIT=$bad XOLOTL_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains "Xolotl is running $next again" "$tmp_root/out"
[[ $(< "$tree/opt/xolotl/.git/HEAD") == "$next" ]] || fail 'rollback did not restore HEAD'
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] || fail 'rollback fetched again instead of using the local commit'
[[ $(cat "$tree/opt/xolotl/build-xolotl/rollback-marker") == 'previous runtime' ]] || fail 'engine build not restored'
[[ ! -e $tree/opt/xolotl/runtime-from-failed-upgrade ]] || fail 'failed runtime file survived'
awk '/^git .* reset / {restoring=1;next} restoring && /^cmake / {exit 1}' "$log" || fail 'rollback rebuilt'
[[ ! -e $tree/var/lib/xolotl-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful rollback'
pass 'a failed upgrade returns to the previous commit and engine build without the network'

: > "$log"
if FAKE_READY=0 XOLOTL_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade whose model never loaded reported success'
fi
contains 'has not answered' "$tmp_root/out"
contains "Rollback to $next failed too" "$tmp_root/out"
contains 'the snapshot is kept in' "$tmp_root/out"
[[ -s $tree/var/lib/xolotl-target/rollback-runtime.tar ]] || fail 'a failed rollback removed the snapshot'
pass 'an upgrade is not healthy until /health reports the model loaded; a failed rollback keeps its snapshot'

: > "$log"
XOLOTL_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'reset to a healthy install'; }
cp "$unit" "$tmp_root/good.service"; cp "$cfg" "$tmp_root/good.json"
cp "$tree/etc/xolotl-target/installed-settings" "$tmp_root/good-settings"
cp "$deploy/xolotl.service" "$tmp_root/deploy.service"
printf '# changed by the attempted upgrade\n' >> "$deploy/xolotl.service"
: > "$log"
if FAKE_BAD_COMMIT=$bad XOLOTL_COMMIT=$bad XOLOTL_CONTEXT=65536 XOLOTL_PORT=11434 \
        run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade with new settings reported success'
fi
cp "$tmp_root/deploy.service" "$deploy/xolotl.service"
contains "Xolotl is running $next again" "$tmp_root/out"
contains 'Restoring the settings it last ran with' "$tmp_root/out"
cmp -s "$unit" "$tmp_root/good.service" || fail 'rollback kept the attempted unit'
cmp -s "$cfg" "$tmp_root/good.json" || fail 'rollback kept the attempted config'
contains 'XOLOTL_PORT=8080' "$tree/etc/xolotl-target/xolotl.env"
cmp -s "$tree/etc/xolotl-target/installed-settings" "$tmp_root/good-settings" || fail 'a failed upgrade changed the record'
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "the rollback was not checked on the recorded port"
: > "$log"
XOLOTL_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after rollback'; }
contains 'nothing to do' "$tmp_root/out"
pass 'rollback restores the previous settings, config and unit, not the ones that failed'

rm -f "$tree/etc/xolotl-target/installed-env"
: > "$log"
XOLOTL_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'record migration'; }
[[ -f $tree/etc/xolotl-target/installed-env ]] || fail 'a healthy rerun did not backfill its settings'
grep -q 'systemctl stop' "$log" && fail 'record migration stopped the service'
pass 'a healthy rerun without installed-env backfills it without restarting'

rm -f "$tree/etc/xolotl-target/installed-env"
: > "$log"
if FAKE_BAD_COMMIT=$bad XOLOTL_COMMIT=$bad XOLOTL_PORT=11434 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains 'No record of the previous settings' "$tmp_root/out"
contains "Xolotl is running $next again" "$tmp_root/out"
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "a rollback without installed-env was not checked on the fingerprint's port"
pass 'an install without a settings record still rolls back, from its runtime snapshot'

# --- weights: resume, corruption, upstream changes, disk space -------------------
reset_tree
mkdir -p "$models/v41-xq-1017-v4"
head -c 1500 "$hf/model.gguf" > "$models/v41-xq-1017-v4/.V41-XQ-1017-v4.gguf.joining"   # part 1 + 300 bytes
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resumed join'; }
contains 'Dropping 300 bytes of an incomplete append of part 2' "$tmp_root/out"
grep -q 'download part-1' "$log" && fail 'a part already appended was downloaded again'
cmp -s "$models/v41-xq-1017-v4/V41-XQ-1017-v4.gguf" "$hf/model.gguf" || fail 'the resumed join differs'
pass 'an interrupted join resumes after the last whole part, dropping a half-appended one'

reset_tree
FAKE_CUT=rank-1017-v4.bin run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resumed download'; }
contains 'download rank-1017-v4.bin from 100' "$log"
cmp -s "$models/v41-xq-1017-v4/rank-1017-v4.bin" "$hf/rank-1017-v4.bin" || fail 'the resumed download differs'
pass 'an interrupted download resumes where it stopped'

reset_tree
out=$(FAKE_CORRUPT=part-2 run_target 2>&1) && fail 'a corrupt part was accepted'
[[ $out == *'Checksum mismatch for part 2'* ]] || fail "corrupt part message: $out"
[[ ! -e $models/v41-xq-1017-v4/.V41-XQ-1017-v4.gguf.part-2 ]] || fail 'the corrupt part was kept'
[[ $(stat -c %s "$models/v41-xq-1017-v4/.V41-XQ-1017-v4.gguf.joining") == 1200 ]] || fail 'the corrupt part was appended'
[[ ! -e $unit ]] || fail 'a unit was installed with corrupt weights'
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after a corrupt part'; }
cmp -s "$models/v41-xq-1017-v4/V41-XQ-1017-v4.gguf" "$hf/model.gguf" || fail 'the model after a corrupt part'
pass 'a corrupt part is removed, never appended, and a rerun fetches it again'

reset_tree
out=$(FAKE_CORRUPT=vocab.json run_target 2>&1) && fail 'a tokenizer file with the wrong blob id was accepted'
[[ $out == *'Checksum mismatch for v41-xq-1017-v4/tokenizer/vocab.json'* ]] || fail "git hash message: $out"
pass 'small non-LFS files are checked against their git blob id'

reset_tree
out=$(FAKE_ETAG=$(printf 'f%.0s' {1..64}) run_target 2>&1) && fail 'a changed upstream file was downloaded'
[[ $out == *'not the reviewed'* && $out == *'update xolotl-weights.txt'* ]] || fail "etag message: $out"
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
XOLOTL_DSPARK=false run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'install without DSpark'; }
grep -q 'download V41-MTP-Vision' "$log" && fail 'the sidecar was downloaded without DSpark'
grep -q DSPARK "$cfg" && fail 'DSpark settings in the config without DSpark'
pass 'XOLOTL_DSPARK=false skips the sidecar and its settings'

# --- refusals before anything changes ---------------------------------------------
reset_tree
out=$(XOLOTL_NVCC_PATH=$tmp_root/cuda-13.1/bin/nvcc run_target 2>&1) && fail 'a missing nvcc was accepted'
[[ $out == *'cuda-13.1/bin/nvcc is missing'* ]] || fail "nvcc message: $out"
grep -q '^cmake ' "$log" && fail 'cmake ran without its nvcc'
pass 'the engine is not built when the CUDA toolkit it is pointed at is missing'

reset_tree
out=$(FAKE_CUDA_UNAVAILABLE=1 run_target 2>&1) && fail 'an unavailable CUDA version was accepted'
[[ $out == *'CUDA 13.0 is not available for this'* ]] || fail "CUDA preflight message: $out"
grep -qE '^(apt-get|git|cmake) ' "$log" && fail 'something was installed or fetched before the CUDA preflight'
pass 'a CUDA version the distro cannot install stops the installer before anything changes'

reset_tree
out=$(FAKE_VRAM_MIB=8192 run_target 2>&1) && fail 'an 8 GB GPU was accepted'
[[ $out == *'needs a 16 GB card or larger'* ]] || fail "VRAM message: $out"
grep -qE '^(apt-get|git|curl) ' "$log" && fail 'something changed before the VRAM check'
pass 'a GPU with less than 16 GB VRAM is refused before downloads or installation'

reset_tree
out=$(FAKE_VRAM_MIB=unknown run_target 2>&1) && fail 'an unknown VRAM size was accepted'
[[ $out == *'Cannot read GPU 0 VRAM'* ]] || fail "unknown VRAM message: $out"
pass 'an unreadable GPU VRAM size is refused'

reset_tree
out=$(FAKE_CAP=7.0 run_target 2>&1) && fail 'a Volta GPU was accepted'
[[ $out == *'needs 7.5 or newer'* ]] || fail "compute capability message: $out"
grep -qE '^(apt-get|git) ' "$log" && fail 'something changed before the GPU check'
pass 'a GPU below compute capability 7.5 is refused before anything changes'

FAKE_MEM_KIB=67108864 reset_tree
out=$(run_target 2>&1) && fail 'an arena larger than the RAM allows was accepted'
[[ $out == *'XOLOTL_ARENA_GIB=60 needs at least 76 GiB'* ]] || fail "RAM message: $out"
grep -qE '^(apt-get|git) ' "$log" && fail 'something changed before the RAM check'
pass 'an arena the CT cannot pin is refused before anything changes'

reset_tree
out=$(FAKE_GROUP=root run_target 2>&1) && fail 'GPU nodes in group root were accepted'
[[ $out == *'gid=44'* ]] || fail "root group message: $out"
pass 'GPU nodes owned by group root are refused with the pct set fix'

reset_tree
mkdir -p "$tree/opt/xolotl"; touch "$tree/opt/xolotl/stray"
out=$(run_target 2>&1) && fail 'a non-git /opt/xolotl was used'
[[ $out == *'is not a Git checkout'* ]] || fail "non-git message: $out"
pass 'a non-empty non-git source directory is refused'

output=$(env -i "PATH=$PATH" bash "$script_dir/install-target.sh" --dry-run 2>&1)
[[ $output == *"git fetch --depth 1 https://github.com/Indras-Mirror/Xolotl.git $(< "$script_dir/upstream-commit.txt") into /opt/xolotl"* ]] || fail "dry-run fetch: $output"
[[ $output == *'-DCMAKE_CUDA_ARCHITECTURES=<GPU 0 compute capability>'* ]] || fail "dry-run cmake: $output"
[[ $output == *'with the key [redacted]'* ]] || fail 'dry-run key'
pass 'the dry run shows the pinned commit, the CMake configure and no key'

# --- saved settings -------------------------------------------------------------
saved_upgrade() {
    env -i PATH="$bin:$PATH" XOLOTL_DIR="$tree/opt/xolotl" XOLOTL_DATA_DIR="$tree/var/lib/xolotl" \
        XOLOTL_ETC_DIR="$tree/etc/xolotl-target" XOLOTL_CONFIG_DIR="$tree/etc/xolotl" \
        XOLOTL_STATE_DIR="$tree/var/lib/xolotl-target" UNIT_DIR="$tree/etc/systemd/system" \
        MEMINFO="$meminfo" XOLOTL_READY_TIMEOUT=5 GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        XOLOTL_COMMIT="$(< "$tree/opt/xolotl/.git/HEAD")" \
        "$@" bash "$target" --upgrade
}
saved_rerun() {
    env -i PATH="$bin:$PATH" XOLOTL_DIR="$tree/opt/xolotl" XOLOTL_DATA_DIR="$tree/var/lib/xolotl" \
        XOLOTL_ETC_DIR="$tree/etc/xolotl-target" XOLOTL_CONFIG_DIR="$tree/etc/xolotl" \
        XOLOTL_STATE_DIR="$tree/var/lib/xolotl-target" UNIT_DIR="$tree/etc/systemd/system" \
        MEMINFO="$meminfo" XOLOTL_READY_TIMEOUT=5 GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        XOLOTL_COMMIT="$(< "$tree/opt/xolotl/.git/HEAD")" \
        bash "$target"
}
reset_tree
XOLOTL_PORT=8123 XOLOTL_CONTEXT=65536 XOLOTL_ARENA_GIB=48 XOLOTL_CUDA_ARCH=86 run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'custom install before saved-settings upgrade'; }
record=$tree/etc/xolotl-target/installed-env
contains 'XOLOTL_CUDA_ARCH=86' "$record"
grep -q 'compute capability' "$tmp_root/out" && fail 'an explicit architecture was detected anyway'
cp "$record" "$tmp_root/custom-settings"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'bare upgrade with saved settings'; }
cmp -s "$record" "$tmp_root/custom-settings" || fail 'bare upgrade reset saved settings'
contains 'nothing to do' "$tmp_root/out"
grep -q 'compute capability' "$tmp_root/out" && fail 'a saved architecture was detected again'
pass 'a bare --upgrade preserves custom settings (the architecture too) and leaves an unchanged service running'
saved_upgrade XOLOTL_PORT=8124 > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'saved-settings explicit override'; }
sed 's/^XOLOTL_PORT=.*/XOLOTL_PORT=8124/' "$tmp_root/custom-settings" > "$tmp_root/expected-settings"
cmp -s "$record" "$tmp_root/expected-settings" || fail 'an explicit override reset another saved setting'
pass 'an explicit upgrade setting overrides only that saved value'
cp "$record" "$tmp_root/valid-settings"
sed -i 's/^XOLOTL_PORT=.*/XOLOTL_PORT=99999/' "$record"
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
saved_upgrade XOLOTL_PORT= > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade with an empty port'; }
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
cp "$tree/etc/xolotl-target/installed-settings" "$tmp_root/fingerprint"
sed -i '/^port=/d' "$tree/etc/xolotl-target/installed-settings"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'an unreadable fingerprint fell back to defaults'; fi
contains 'Cannot read this installation' "$tmp_root/out"
[[ ! -s $log ]] || fail 'an unreadable fingerprint touched the installation'
mv "$tmp_root/fingerprint" "$tree/etc/xolotl-target/installed-settings"
cp "$tmp_root/current-settings" "$record"
pass 'an unreadable fingerprint is refused before anything runs, unless every setting is given'
(
    unset XOLOTL_NVCC
    XOLOTL_ETC_DIR="$tree/etc/xolotl-target"
    XOLOTL_CUDA_VERSION=13.1
    saved_settings
    [[ $XOLOTL_CUDA_VERSION == 13.1 && ! -v XOLOTL_NVCC ]] || fail 'a changed CUDA version retained the old compiler'
) || fail 'toolkit version override'
pass 'a CUDA version override derives a new default compiler instead of keeping the saved one'

# Lost metadata must not turn a configured target into a fresh installation.
cp "$record" "$tmp_root/recovery-settings"
rm -f "$record" "$tree/etc/xolotl-target/installed-settings"
for metadata_state in missing dangling; do
    if [[ $metadata_state == dangling ]]; then
        ln -s "$tree/etc/xolotl-target/missing-fingerprint" "$tree/etc/xolotl-target/installed-settings"
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
    rm -f "$tree/etc/xolotl-target/installed-settings"
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
[[ -s $tree/etc/xolotl-target/installed-settings ]] || fail 'explicit recovery did not recreate the fingerprint'
pass 'complete explicit settings recover lost metadata without resetting custom values'

# A first install that stops part-way resumes with the settings it was started with.
reset_tree
pbad=fedcba9876543210fedcba9876543210fedcba98
if FAKE_BAD_COMMIT=$pbad XOLOTL_COMMIT=$pbad XOLOTL_PORT=8123 XOLOTL_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a first install whose build fails reported success'
fi
pending=$tree/etc/xolotl-target/pending-env
[[ -f $pending && ! -e $record ]] || fail 'an interrupted first install left no pending-env, or a settings record'
[[ $(stat -c %a "$pending") == 600 ]] || fail 'pending-env is not root-only'
contains 'XOLOTL_PORT=8123' "$pending"
contains 'XOLOTL_CUDA_ARCH=89' "$pending"
cp "$pending" "$tmp_root/started-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming the interrupted install'; }
contains 'Resuming an interrupted install' "$tmp_root/out"
cmp -s "$record" "$tmp_root/started-settings" || fail "the resumed install did not keep its settings: $(tr '\n' ' ' < "$record")"
[[ ! -e $pending ]] || fail 'pending-env was left after a successful install'
pass 'an interrupted first install resumes with the settings it was started with'

reset_tree
if FAKE_METADATA_FAIL=1 XOLOTL_PORT=8123 XOLOTL_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed fingerprint rename reported success'
fi
[[ -f $pending && -s $record && ! -e $tree/etc/xolotl-target/installed-settings ]] ||
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
