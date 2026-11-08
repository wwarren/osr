#!/usr/bin/env bash
# Exercise install-target.sh: its helpers (checkout checks, the card's
# profile, model and context, the weights manifest, the engine environment,
# the config file, the settings record), then whole-script runs against a
# temporary tree with stubbed git, uv, the venv's python (Kindi's convert,
# verify and fast-head), systemctl, curl (Hugging Face and the API), the CUDA
# toolkit installer, nvidia-smi and account tools. Nothing is downloaded,
# built, installed or started.
# The KINDI_* assignments below are read by the sourced helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/kindi-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/kindi-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# A minimal Kindi checkout: the files, config keys, commands, engine settings
# and Dockerfile pins install-target.sh checks for.
fixture=$tmp_root/upstream
make_fixture() {
    local dir=$1 key var
    mkdir -p "$dir/kindi" "$dir/docker"
    {
        printf 'DEFAULTS = {\n'
        for key in pack state_dir host port api_key model_name ctx head repeat_stop checkpoint_budget_mb park_max \
                   prefix_max max_tokens; do
            printf '    "%s": "",\n' "$key"
        done
        printf '}\n'
    } > "$dir/kindi/config.py"
    for key in convert verify serve fast-head; do printf 's = sub.add_parser("%s", help="")\n' "$key"; done > "$dir/kindi/__main__.py"
    printf '%s\n' 'return {"ok": True, "kindi": __version__}' \
        'return {"data": [{"id": model_id, "owned_by": "kindi", "context_length": K.eng.ctx}]}' > "$dir/kindi/server.py"
    printf 'PACK_FORMAT = 1\n' > "$dir/kindi/convert.py"
    for var in KINDI_DEVICE KINDI_CARDS KINDI_BLOCKING_SYNC KINDI_DENSE_SPACING KINDI_TC KINDI_FD KINDI_ATT_TC \
               KINDI_CKPT_VRAM KINDI_SPEC KINDI_SPEC_K KINDI_SPEC_PACK KINDI_SPEC_WINDOW KINDI_TC_TMAX \
               KINDI_MEM_RESERVE_MB KINDI_CPU_CACHE; do
        printf 'os.environ.get("%s")\n' "$var"
    done > "$dir/kindi/engine.py"
    : > "$dir/kindi/verify.py"; : > "$dir/kindi/catalog.py"; : > "$dir/kindi/cpu.py"; : > "$dir/kindi/kcpu.c"
    printf '%s\n' 'RUN pip install "numpy==1.19.5" "fastrlock==0.8.3" "cupy-cuda102==9.6.0" \' \
        '    "fastapi==0.79.1" "uvicorn==0.16.0" "pydantic==1.9.2"' > "$dir/docker/Dockerfile"
}
make_fixture "$fixture"

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in validate_checkout pack_format model_field compute_cap_arch kepler_by_name profile_for auto_model \
              auto_context spec_active needed_models weight_rows model_file model_path pack_dir validate_settings \
              settings_env load_settings fingerprint_env saved_settings engine_env server_config config_file \
              settings_fingerprint; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done
source_dir=$script_dir
KINDI_DIR=$fixture KINDI_DATA_DIR=/var/lib/kindi KINDI_CONFIG_DIR=/etc/kindi KINDI_PACK_FORMAT=1
CUDA_HOME_DIR=/usr/local/cuda-10.2
KINDI_BACKEND=cuda KINDI_MODEL=bonsai-27b KINDI_PROFILE=tc KINDI_PORT=8093 KINDI_CONTEXT=131072 KINDI_HEAD=exact
KINDI_SPEC=auto KINDI_THREADS=auto KINDI_MODEL_NAME=bonsai2-27b KINDI_PYTHON_VERSION=3.9.25 KINDI_VERIFY=true

validate_checkout "$fixture" || fail 'the fixture checkout was refused'
[[ $(pack_format "$fixture") == 1 ]] || fail 'pack format'
for broken in kindi/server.py docker/Dockerfile; do
    cp -a "$fixture" "$tmp_root/broken"; rm -f "$tmp_root/broken/$broken"
    out=$(validate_checkout "$tmp_root/broken" 2>&1) && fail "a checkout without $broken was accepted"
    [[ $out == *"lacks: $broken"* ]] || fail "missing-file message: $out"
    rm -rf "$tmp_root/broken"
done
cp -a "$fixture" "$tmp_root/broken"
sed -i '/"api_key"/d' "$tmp_root/broken/kindi/config.py"; sed -i '/fast-head/d' "$tmp_root/broken/kindi/__main__.py"
sed -i 's/cupy-cuda102==9.6.0/cupy-cuda102==10.0.0/' "$tmp_root/broken/docker/Dockerfile"
sed -i '/KINDI_SPEC_PACK/d' "$tmp_root/broken/kindi/engine.py"
out=$(validate_checkout "$tmp_root/broken" 2>&1) && fail 'a checkout without api_key was accepted'
[[ $out == *'config key api_key'* && $out == *'kindi fast-head'* && $out == *'KINDI_SPEC_PACK'* &&
   $out == *'Dockerfile pin cupy-cuda102==9.6.0'* ]] || fail "checkout message: $out"
rm -rf "$tmp_root/broken"
pass 'a checkout must carry the files, config keys, commands, engine settings and Dockerfile pins the target relies on'

# requirements-cuda.in names exactly Kindi's Dockerfile pins, and both locks
# are complete hash locks.
for pin in "${REQUIRED_PINS[@]}"; do
    grep -qixF -- "$pin" <(cat "$script_dir/requirements-cpu.in" "$script_dir/requirements-cuda.in") ||
        fail "requirements .in lacks $pin"
    grep -qi "^${pin} " "$script_dir/requirements-cuda.lock" || fail "requirements-cuda.lock lacks $pin"
done
grep -qi '^cupy-cuda102==' "$script_dir/requirements-cpu.lock" && fail 'the CPU lock installs CuPy'
for lock in requirements-cpu.lock requirements-cuda.lock uv.lock; do
    awk '/^[A-Za-z0-9]/ && !/ \\$/ { exit 1 } /^[A-Za-z0-9]/ { pkgs++ } /--hash=sha256:[0-9a-f]{64}/ { hashes++ }
         END { exit !(pkgs > 0 && hashes >= pkgs) }' "$script_dir/$lock" || fail "$lock is not a hash lock"
    grep -qE '^[A-Za-z0-9_.-]+==[^ ]+ ' "$script_dir/$lock" || fail "$lock has no exact pins"
    grep -qE '^[A-Za-z0-9_.-]+(>=|<|~=)' "$script_dir/$lock" && fail "$lock has a range"
done
pass "the venv locks pin Kindi's Dockerfile versions with hashes; the CPU lock has no CuPy"

[[ $(compute_cap_arch <<< '8.9') == 89 && $(compute_cap_arch <<< $'6.1\n8.6') == 61 ]] || fail 'compute capability parsing'
compute_cap_arch <<< 'N/A' && fail 'a malformed compute capability was accepted'
kepler_by_name 'Quadro K420' && kepler_by_name 'Quadro K6000' && kepler_by_name 'Tesla K80' &&
    kepler_by_name 'GeForce GTX 780' && kepler_by_name 'GeForce GT 730' || fail 'Kepler names'
kepler_by_name 'GeForce GTX 750 Ti' && fail 'a Maxwell GTX 750 was taken for Kepler'
kepler_by_name 'Quadro M4000' && fail 'a Maxwell Quadro was taken for Kepler'
[[ $(profile_for 86 10240) == tc && $(profile_for 86 8192) == pascal8 && $(profile_for 61 8192) == pascal8 &&
   $(profile_for 60 16384) == p100 && $(profile_for 30 980) == kepler && $(profile_for 35 12288) == kepler &&
   $(profile_for 50 4096) == maxwell && $(profile_for 61 6144) == maxwell && $(profile_for 75 6144) == maxwell ]] ||
    fail 'profiles'
[[ $(auto_model tc 10240) == bonsai-27b && $(auto_model pascal8 8192) == bonsai-27b && $(auto_model kepler 980) == bonsai-2b &&
   $(auto_model kepler 1998) == bonsai-4b && $(auto_model kepler 12288) == bonsai-27b && $(auto_model maxwell 4096) == bonsai-9b &&
   $(auto_model maxwell 2048) == bonsai-4b && $(auto_model cpu 0) == bonsai-2b ]] || fail 'auto models'
[[ $(auto_context kepler 980 bonsai-2b) == 24576 && $(auto_context kepler 1998 bonsai-4b) == 23808 &&
   $(auto_context kepler 1998 bonsai-2b) == 65536 && $(auto_context tc 10240 bonsai-27b) == 131072 &&
   $(auto_context pascal8 8192 bonsai-27b) == 65536 && $(auto_context nanbeige 24576 nanbeige-33b) == 16384 &&
   $(auto_context cpu 0 bonsai-2b) == 24576 && $(auto_context maxwell 4096 bonsai-9b) == 24576 ]] || fail 'auto contexts'
[[ $(model_field bonsai-27b name) == bonsai2-27b && $(model_field nanbeige-33b name) == nanbeige-33b-iq3 &&
   $(model_field bonsai-27b vram) == 7600 ]] || fail 'model fields'
model_field bonsai-9b cpu && ! model_field bonsai-27b cpu || fail 'the CPU models'
pass "the card's profile, model and context follow Kindi's installer (K420 to RTX 30, Kepler by name on the 470 driver)"

# The shipped manifest: every model, each pinned to a commit, with Kindi's
# own catalog hashes and sizes.
manifest=$script_dir/kindi-weights.txt
rows=$(weight_rows "$manifest" "${MODEL_IDS[@]}") || fail 'the shipped manifest was refused'
[[ $(wc -l <<< "$rows") == 5 ]] || fail 'the five models'
grep -q '^bonsai-2b Ternary-Bonsai-2-2B-PTQ1_0.gguf 429183456 sha256:36061ad406df8a4903a6db005be350c50fabfaf717f9ef0acf4b76adcd9929fa ' <<< "$rows" ||
    fail 'the 2B row'
grep -q '^nanbeige-33b AH-Nanbeige4.3-33B-IQ3_XXS.gguf 13108685952 ' <<< "$rows" || fail 'the Nanbeige row'
awk '$5 !~ /\/resolve\/[0-9a-f]{40}\// { exit 1 }' <<< "$rows" || fail 'a URL is not pinned to a commit'
[[ $(weight_rows "$manifest" bonsai-9b | cut -d' ' -f1) == bonsai-9b ]] || fail 'one model'
out=$(weight_rows "$manifest" bonsai-70b 2>&1) && fail 'an unknown model was listed'
[[ $out == *'does not list every model'* ]] || fail "unknown model message: $out"
for bad in 'bonsai-2b ../x.gguf 1 sha256:'"$(printf '0%.0s' {1..64})"' https://huggingface.co/a/b/resolve/0123456789abcdef0123456789abcdef01234567/x.gguf' \
           'bonsai-2b x.gguf 1 sha256:abc https://huggingface.co/a/b/resolve/0123456789abcdef0123456789abcdef01234567/x.gguf' \
           'bonsai-2b x.gguf 1 sha256:'"$(printf '0%.0s' {1..64})"' https://huggingface.co/a/b/resolve/main/x.gguf' \
           'bonsai-2b x.gguf 1 sha256:'"$(printf '0%.0s' {1..64})"' https://example.com/a/b/resolve/0123456789abcdef0123456789abcdef01234567/x.gguf' \
           'bonsai-2b x.gguf 1 sha256:'"$(printf '0%.0s' {1..64})"' https://huggingface.co/a/b/resolve/0123456789abcdef0123456789abcdef01234567/y.gguf'; do
    printf '%s\n' "$bad" > "$tmp_root/bad-manifest"
    out=$(weight_rows "$tmp_root/bad-manifest" bonsai-2b 2>&1) && fail "a malformed manifest row was accepted: $bad"
    [[ $out == *'malformed row'* ]] || fail "malformed row message: $out"
done
pass 'the weights manifest pins every model to a commit and its catalog hash, and is strictly parsed'

[[ $(needed_models | paste -sd' ' -) == 'bonsai-27b bonsai-2b' ]] || fail 'the 27B drafts with the 2B on tc'
KINDI_SPEC=off
[[ $(needed_models) == bonsai-27b ]] || fail 'KINDI_SPEC=off still downloads the draft model'
KINDI_SPEC=auto KINDI_PROFILE=pascal8
[[ $(needed_models) == bonsai-27b ]] || fail 'the draft model off the tensor-core profile'
KINDI_PROFILE=tc
env_out=$(engine_env)
for line in KINDI_CARDS=1 KINDI_TC=1 KINDI_FD=1 KINDI_ATT_TC=1 KINDI_SPEC=auto KINDI_SPEC_K=3 \
            KINDI_SPEC_PACK=/var/lib/kindi/packs/bonsai-2b-f1 KINDI_MAX_TOKENS=65536 CUDA_PATH=/usr/local/cuda-10.2 \
            LD_LIBRARY_PATH=/usr/local/cuda-10.2/lib64 KINDI_CPU_CACHE=/var/lib/kindi/.cache/kindi; do
    grep -qx -- "$line" <<< "$env_out" || fail "tc engine env lacks $line: $env_out"
done
grep -q KINDI_BLOCKING_SYNC <<< "$env_out" && fail 'tc keeps blocking sync on'
KINDI_PROFILE=pascal8
env_out=$(engine_env)
grep -qx KINDI_BLOCKING_SYNC=0 <<< "$env_out" && grep -qx KINDI_CARDS=1 <<< "$env_out" || fail "pascal8 env: $env_out"
grep -q 'KINDI_TC\|KINDI_SPEC' <<< "$env_out" && fail 'pascal8 uses the tensor cores'
KINDI_PROFILE=kepler KINDI_MODEL=bonsai-2b
env_out=$(engine_env)
[[ $(grep -vc '^#' <<< "$env_out") == 5 ]] || fail "kepler 2B env: $env_out"
KINDI_BACKEND=cpu KINDI_PROFILE=cpu KINDI_THREADS=6
env_out=$(engine_env)
grep -qx KINDI_DEVICE=cpu <<< "$env_out" && grep -qx OMP_NUM_THREADS=6 <<< "$env_out" || fail "cpu env: $env_out"
grep -q CUDA_PATH <<< "$env_out" && fail 'the CPU engine gets the CUDA paths'
KINDI_BACKEND=cuda KINDI_PROFILE=tc KINDI_MODEL=bonsai-27b KINDI_THREADS=auto
pass "the unit's environment is Kindi's profile for the card: tensor cores and the 2B draft on RTX 30+, blocking sync elsewhere off"

api_key=sk-test-key
config=$(server_config)
[[ $config == *'pack = /var/lib/kindi/packs/bonsai-27b-f1'* && $config == *'host = 0.0.0.0'* &&
   $config == *'port = 8093'* && $config == *'api_key = sk-test-key'* && $config == *'model_name = bonsai2-27b'* &&
   $config == *'ctx = 131072'* && $config == *'head = exact'* && $config == *'state_dir = /var/lib/kindi/state'* ]] ||
    fail "server config: $config"
[[ $(server_config '[key]') != *sk-test-key* ]] || fail 'the redacted config has the key'
[[ $(settings_fingerprint) != *sk-test-key* ]] || fail 'the fingerprint has the key'
[[ $(engine_env) != *sk-test-key* ]] || fail 'the environment has the key'
pass 'the server config holds the pack, address, context, model id and key; the environment and fingerprint never the key'

for bad in 'KINDI_BACKEND=rocm' 'KINDI_MODEL=bonsai-70b' 'KINDI_PROFILE=ampere' 'KINDI_CONTEXT=512' \
           'KINDI_CONTEXT=524288' 'KINDI_HEAD=approx' 'KINDI_SPEC=on' 'KINDI_THREADS=8' 'KINDI_PYTHON_VERSION=3.10.4' \
           'KINDI_MODEL_NAME=Bonsai 27B' 'KINDI_PORT=70000'; do
    ( eval "${bad%%=*}=\"${bad#*=}\""; validate_settings ) >/dev/null 2>&1 && fail "accepted $bad"
done
( KINDI_BACKEND=cpu KINDI_PROFILE=cpu KINDI_MODEL=bonsai-27b; validate_settings ) >/dev/null 2>&1 &&
    fail 'the CPU engine accepted the 27B'
( KINDI_MODEL=nanbeige-33b KINDI_PROFILE=auto KINDI_HEAD=fast; validate_settings ) >/dev/null 2>&1 &&
    fail 'Nanbeige accepted the fast head'
( KINDI_BACKEND=cpu KINDI_PROFILE=cpu KINDI_MODEL=bonsai-9b KINDI_THREADS=8; validate_settings ) || fail 'a CPU 9B was refused'
pass 'settings are validated: the CPU engine runs the 2B to 9B, Nanbeige only the exact head'

settings_env > "$tmp_root/installed-env"
[[ $(grep -c '^KINDI_' "$tmp_root/installed-env") == 10 ]] || fail "settings record: $(cat "$tmp_root/installed-env")"
KINDI_CONTEXT=65536 KINDI_PORT=11434 KINDI_PROFILE=pascal8
load_settings "$tmp_root/installed-env" || fail 'a valid record was not loaded'
[[ $KINDI_CONTEXT == 131072 && $KINDI_PORT == 8093 && $KINDI_PROFILE == tc ]] ||
    fail "record not restored: $KINDI_CONTEXT $KINDI_PORT $KINDI_PROFILE"
for bad in 's/^KINDI_PORT=.*/KINDI_PORT=99999/' 's/^KINDI_PROFILE=.*/KINDI_PROFILE=ampere/' \
           's/^KINDI_HEAD=.*/KINDI_HEAD=yes/' 's/^KINDI_BACKEND=.*/KINDI_BACKEND=vulkan/' \
           's/^KINDI_CONTEXT=.*/KINDI_CONTEXT=999999/'; do
    sed "$bad" "$tmp_root/installed-env" > "$tmp_root/bad-env"
    KINDI_PORT=11434
    load_settings "$tmp_root/bad-env" && fail "an invalid record was loaded ($bad)"
    [[ $KINDI_PORT == 11434 ]] || fail 'an invalid record changed a setting'
done
grep -v '^KINDI_SPEC=' "$tmp_root/installed-env" > "$tmp_root/old-env"
load_settings "$tmp_root/old-env" && fail 'a record without every key was loaded'
printf 'KINDI_PORT=8093; touch %s/pwned\n' "$tmp_root" > "$tmp_root/evil-env"
load_settings "$tmp_root/evil-env" && fail 'a malformed record was loaded'
[[ ! -e $tmp_root/pwned ]] || fail 'the record was executed'
KINDI_PORT=8093
settings_fingerprint > "$tmp_root/fingerprint"
KINDI_PORT=1
load_settings <(fingerprint_env "$tmp_root/fingerprint") || fail 'the fingerprint was not read back'
[[ $KINDI_PORT == 8093 ]] || fail 'the fingerprint port'
pass 'the settings record is read back all-or-nothing and never executed'
# The whole-script runs below start from the defaults.
unset "${SETTING_KEYS[@]}" KINDI_VERIFY source_dir KINDI_DIR KINDI_DATA_DIR KINDI_CONFIG_DIR KINDI_PACK_FORMAT CUDA_HOME_DIR

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
# The installer runs from a copy whose CUDA installer is a stub that only logs
# and whose manifest lists small fixture files served by the curl stub.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
cp "$script_dir/install-target.sh" "$script_dir/kindi.service" "$script_dir/upstream-commit.txt" \
    "$script_dir/requirements-cpu.lock" "$script_dir/requirements-cuda.lock" "$script_dir/uv.lock" "$deploy/"
log=$tmp_root/calls.log
printf '#!/usr/bin/env bash\necho "cuda-toolkit.sh $* CUDA_HOME_DIR=$CUDA_HOME_DIR" >> "%s"\n[[ $1 == --check && ${FAKE_CUDA_UNAVAILABLE:-0} == 1 ]] && { echo "not on this distro" >&2; exit 1; }\nexit 0\n' "$log" > "$deploy/cuda-toolkit.sh"
target=$deploy/install-target.sh

# The fixture "Hugging Face": files by URL basename.
hf=$tmp_root/hf; mkdir -p "$hf"
declare -A fixture_file=([bonsai-2b]=Ternary-Bonsai-2-2B-PTQ1_0.gguf [bonsai-4b]=Ternary-Bonsai-2-4B-PTQ1_0.gguf
    [bonsai-9b]=Ternary-Bonsai-2-9B-PTQ1_0.gguf [bonsai-27b]=Ternary-Bonsai-2-27B-PTQ1_0.gguf
    [nanbeige-33b]=AH-Nanbeige4.3-33B-IQ3_XXS.gguf)
sha() { sha256sum "$1" | cut -d' ' -f1; }
size() { stat -c %s "$1"; }
url=https://huggingface.co/test/repo/resolve/0123456789abcdef0123456789abcdef01234567
for model in bonsai-2b bonsai-4b bonsai-9b bonsai-27b nanbeige-33b; do
    { printf GGUF; head -c $(( 1000 + RANDOM % 1000 )) /dev/urandom; } > "$hf/${fixture_file[$model]}"
done
for model in bonsai-2b bonsai-4b bonsai-9b bonsai-27b nanbeige-33b; do
    f=${fixture_file[$model]}
    printf '%s %s %s sha256:%s %s/%s\n' "$model" "$f" "$(size "$hf/$f")" "$(sha "$hf/$f")" "$url" "$f"
done > "$tmp_root/good-weights.txt"

bin=$tmp_root/bin; mkdir -p "$bin"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub getent 'exit 2'   # no kindi group yet, so it is created
stub mv 'if [[ ${FAKE_METADATA_FAIL:-0} == 1 && ${*: -1} == */installed-settings ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
for command_name in apt-get groupadd useradd usermod chown chgrp sleep; do stub "$command_name" 'exit 0'; done
stub stat 'if [[ $1 == -c && $2 == %G ]]; then echo "${FAKE_GROUP:-video}"; else exec /usr/bin/stat "$@"; fi'
stub systemctl 'case "$1" in is-failed) exit 1;; is-active) exit "${FAKE_INACTIVE:-0}";; esac; exit 0'
stub tar 'if [[ ${FAKE_SNAPSHOT_FAIL:-0} == 1 && $* == *"-cpf "* ]]; then exit 1; fi; exec /usr/bin/tar "$@"'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub df 'printf "Filesystem 1-blocks Used Available Capacity Mounted\nfake 1 1 %s 1%% /\n" "${FAKE_DF_AVAIL:-1099511627776}"'
stub nproc 'echo "${FAKE_NPROC:-6}"'
# nvidia-smi: FAKE_CAP (empty: a 470 driver, which has no compute_cap field),
# FAKE_VRAM_MIB and FAKE_GPU_NAME.
stub nvidia-smi 'case $* in
    *compute_cap*) [[ -n ${FAKE_CAP-8.6} ]] || exit 6; echo "${FAKE_CAP-8.6}" ;;
    *memory.total*) echo "${FAKE_VRAM_MIB:-10240}" ;;
    *name*) echo "${FAKE_GPU_NAME:-NVIDIA GeForce RTX 3080}" ;;
    *) echo "GPU 0: ${FAKE_GPU_NAME:-NVIDIA GeForce RTX 3080}" ;;
esac'
# The venv's python: the import check (FAKE_BAD_COMMIT fails it at that
# commit), and Kindi's convert, verify and fast-head (FAKE_VERIFY_FAIL=1).
cat > "$tmp_root/fake-python" <<STUB
#!/usr/bin/env bash
echo "python \$*" >> "$log"
head=\$(cat "\${PYTHONPATH}/.git/HEAD" 2>/dev/null || true)
if [[ \$1 == -c ]]; then
    if [[ \$head == "\${FAKE_BAD_COMMIT:-none}" ]]; then echo broken > "\${PYTHONPATH}/runtime-from-failed-upgrade"; echo 'ImportError'; exit 1; fi
    [[ \${FAKE_IMPORT_FAIL:-0} == 1 ]] && { echo 'ImportError: libcudart.so.10.2'; exit 1; }
    echo ok; exit 0
fi
[[ \$1 == -m && \$2 == kindi ]] || exit 2
shift 2
pack=''
while [[ \$1 == --* ]]; do [[ \$1 == --pack ]] && pack=\$2; shift 2; done
case \$1 in
    convert)
        gguf=\$2 out=\$4
        mkdir -p "\$out"
        printf '{\n  "pack_format": 1,\n  "source_sha256": "%s"\n}\n' "\$(sha256sum "\$gguf" | cut -d' ' -f1)" > "\$out/kindi_pack.json" ;;
    verify) echo "verify \$pack KINDI_DEVICE=\${KINDI_DEVICE:-gpu} KINDI_CARDS=\${KINDI_CARDS:-}" >> "$log"; [[ \${FAKE_VERIFY_FAIL:-0} == 1 ]] && exit 1; exit 0 ;;
    fast-head) : > "\$pack/head_clusters.npz" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$tmp_root/fake-python"
# uv: reports the pinned version (ensure_uv keeps it), "installs" Python and
# makes a venv whose python is the fake above.
uv_version=$(sed -n 's/^uv==\([^ ]*\) .*/\1/p' "$script_dir/uv.lock")
cat > "$tmp_root/fake-uv" <<STUB
#!/usr/bin/env bash
echo "uv \$*" >> "$log"
case \$1 in
    --version) echo "uv $uv_version" ;;
    python) [[ \$2 == find ]] && echo "\$UV_PYTHON_INSTALL_DIR/cpython-\${@: -1}-linux-x86_64-gnu/bin/python3.9"; exit 0 ;;
    venv) mkdir -p "\${@: -1}/bin"; cp "$tmp_root/fake-python" "\${@: -1}/bin/python" ;;
    pip) [[ " \$* " == *' --require-hashes '* ]] || exit 1 ;;
esac
STUB
chmod +x "$tmp_root/fake-uv"
# curl: Hugging Face HEAD answers (X-Linked-Size/-Etag as the CDN sends them),
# resumable downloads from the fixture directory, and Kindi's API, which
# answers with the model id and context of the config file.
# FAKE_HF_DOWN=1: Hugging Face does not answer; FAKE_ETAG=<hex>: a different
# upstream hash; FAKE_CORRUPT=<name>: that file arrives with a flipped byte;
# FAKE_CUT=<name>: that download stops half-way once; FAKE_READY=0: the
# server never answers; FAKE_SERVED_CTX: the context the engine fits.
cat > "$bin/curl" <<STUB
#!/usr/bin/env bash
echo "curl \$*" >> "$log"
url=\${@: -1}
conf=\$KINDI_TEST_CONF
case \$url in
    https://huggingface.co/*)
        [[ \${FAKE_HF_DOWN:-0} == 1 ]] && exit 6
        name=\${url##*/}; src="$hf/\$name"
        [[ -f \$src ]] || exit 22
        if [[ " \$* " == *' -I '* ]]; then
            printf 'HTTP/2 302\r\nx-linked-size: %s\r\nx-linked-etag: "%s"\r\n' "\$(stat -c %s "\$src")" "\${FAKE_ETAG:-\$(sha256sum "\$src" | cut -d' ' -f1)}"
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
    */health)
        [[ \${FAKE_READY:-1} == 1 ]] || exit 7
        name=\$(sed -n 's/^model_name = //p' "\$conf"); ctx=\$(sed -n 's/^ctx = //p' "\$conf")
        printf '{"ok": true, "kindi": "0.4.0", "model": "%s", "ctx": %s}\n' "\${FAKE_MODEL:-\$name}" "\${FAKE_SERVED_CTX:-\$ctx}" ;;
    */v1/models)
        name=\$(sed -n 's/^model_name = //p' "\$conf")
        printf '{"object":"list","data":[{"id":"%s","owned_by":"kindi"}]}\n' "\${FAKE_MODEL:-\$name}" ;;
    *) exit 22 ;;
esac
STUB
chmod +x "$bin/curl"
# git: a fake shallow checkout. Names resolve to a fixed hash; commits that
# were fetched or pinned with update-ref are "local" and can be checked out
# offline (the fixture tree is copied in). FAKE_FETCH_FAIL=1: every fetch
# fails (no network). FAKE_PACK_FORMAT_AT=<commit>: that commit's converter
# writes pack format 2.
cat > "$bin/git" <<STUB
#!/usr/bin/env bash
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
        cp -r "$fixture/." "\$dir/"
        if [[ \$want == "\${FAKE_PACK_FORMAT_AT:-none}" ]]; then echo 'PACK_FORMAT = 2' > "\$dir/kindi/convert.py"; fi ;;
    rev-parse)
        if [[ \$2 == FETCH_HEAD* ]]; then cat "\$dir/.git/FETCH"; else cat "\$dir/.git/HEAD"; fi ;;
esac
STUB
chmod +x "$bin/git"

tree=$tmp_root/tree
dev=$tmp_root/dev
meminfo=$tmp_root/meminfo
cpuinfo=$tmp_root/cpuinfo
# reset_tree: an empty CT with the NVIDIA nodes passed in (FAKE_NVIDIA=0: none),
# uv already in its runtime directory.
reset_tree() {
    rm -rf "$tree" "$dev" "$tmp_root/cut-done"
    mkdir -p "$tree/etc/systemd/system" "$dev" "$tree/opt/kindi-runtime/uv/bin"
    cp "$tmp_root/fake-uv" "$tree/opt/kindi-runtime/uv/bin/uv"
    if [[ ${FAKE_NVIDIA:-1} == 1 ]]; then touch "$dev/nvidia0" "$dev/nvidiactl" "$dev/nvidia-uvm"; fi
    printf 'MemTotal:       %s kB\n' "${FAKE_MEM_KIB:-16303104}" > "$meminfo"
    printf 'flags\t\t: fpu sse2 %s fma\n' "${FAKE_CPU_FLAG:-avx2}" > "$cpuinfo"
    cp "$tmp_root/good-weights.txt" "$deploy/kindi-weights.txt"
    : > "$log"
}
common_env() {
    printf '%s\n' "PATH=$bin:$PATH" "KINDI_DIR=$tree/opt/kindi" "KINDI_DATA_DIR=$tree/var/lib/kindi" \
        "KINDI_ETC_DIR=$tree/etc/kindi-target" "KINDI_CONFIG_DIR=$tree/etc/kindi" \
        "KINDI_STATE_DIR=$tree/var/lib/kindi-target" "KINDI_RUNTIME_DIR=$tree/opt/kindi-runtime" \
        "CUDA_HOME_DIR=$tree/usr/local/cuda-10.2" "UNIT_DIR=$tree/etc/systemd/system" \
        "MEMINFO=$meminfo" "CPUINFO=$cpuinfo" "KINDI_READY_TIMEOUT=5" "KINDI_NVIDIA_NODE_GLOB=$dev/nvidia[0-9]*" \
        "KINDI_TEST_CONF=$tree/etc/kindi/kindi.conf" "GPU_NODES=$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm"
}
run_target() {
    local -a e
    mapfile -t e < <(common_env)
    env "${e[@]}" KINDI_COMMIT="${KINDI_COMMIT-}" KINDI_REF="${KINDI_REF-}" KINDI_PORT="${KINDI_PORT:-}" \
        KINDI_CONTEXT="${KINDI_CONTEXT:-}" KINDI_MODEL="${KINDI_MODEL:-}" \
        bash "$target" "$@"
}
contains() { grep -Fq -- "$1" "$2" || { sed -n '1,60p' "$2" >&2; fail "$2 lacks: $1"; }; }
models=$tree/var/lib/kindi/models
packs=$tree/var/lib/kindi/packs
envfile=$tree/etc/kindi-target/kindi.env
conf=$tree/etc/kindi/kindi.conf

reset_tree
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
unit=$tree/etc/systemd/system/kindi.service
cmp -s "$unit" "$script_dir/kindi.service" || fail 'unit not installed'
key=$(< "$tree/etc/kindi-target/api-key")
[[ $key =~ ^[0-9a-f]{64}$ ]] || fail 'no generated key'
[[ $(stat -c %a "$tree/etc/kindi-target/api-key") == 600 ]] || fail 'key file mode'
[[ $(stat -c %a "$conf") == 640 ]] || fail "server config mode $(stat -c %a "$conf")"
contains "api_key = $key" "$conf"
grep -q -- "$key" "$tmp_root/out" && fail 'the key was printed'
grep -q -- "$key" "$envfile" && fail 'the key is in the unit environment'
grep -q -- "$key" "$log" && fail 'the key reached a command line'
contains "cuda-toolkit.sh --check CUDA_HOME_DIR=$tree/usr/local/cuda-10.2" "$log"
contains 'GPU 0: NVIDIA GeForce RTX 3080, 10240 MiB, compute capability 8.6.' "$tmp_root/out"
contains 'Kindi profile for this card: tc.' "$tmp_root/out"
contains 'Model for this card: bonsai-27b.' "$tmp_root/out"
contains 'uv python install --quiet --no-bin 3.9.25' "$log"
contains "uv pip sync --quiet --require-hashes --no-build --python $tree/opt/kindi/.venv/bin/python" "$log"
cmp -s "$tree/var/lib/kindi/requirements.lock" "$script_dir/requirements-cuda.lock" || fail 'the venv was not built from the CUDA lock'
contains 'cupy as cp' "$log"
contains 'usermod -aG video kindi' "$log"
contains 'systemctl enable kindi.service' "$log"
contains "pack = $packs/bonsai-27b-f1" "$conf"
contains 'model_name = bonsai2-27b' "$conf"
contains 'ctx = 131072' "$conf"
contains "KINDI_SPEC_PACK=$packs/bonsai-2b-f1" "$envfile"
contains "verify $packs/bonsai-27b-f1 KINDI_DEVICE=gpu KINDI_CARDS=1" "$log"
contains 'profile=tc' "$tree/etc/kindi-target/installed-settings"
contains 'KINDI_MODEL=bonsai-27b' "$tree/etc/kindi-target/installed-env"
pass 'fresh CUDA install as the kindi account: the card'\''s profile and model, a hash-locked venv, the key only in root:kindi files'

cmp -s "$models/${fixture_file[bonsai-27b]}" "$hf/${fixture_file[bonsai-27b]}" || fail 'the 27B differs'
cmp -s "$models/${fixture_file[bonsai-2b]}" "$hf/${fixture_file[bonsai-2b]}" || fail 'the draft 2B differs'
[[ ! -e $models/${fixture_file[bonsai-9b]} ]] || fail 'a model that is not needed was downloaded'
[[ -f $packs/bonsai-27b-f1/kindi_pack.json && -f $packs/bonsai-2b-f1/kindi_pack.json ]] || fail 'the packs were not converted'
[[ -z $(find "$models" -name '.*.part') && ! -e $packs/bonsai-27b-f1.new ]] || fail 'download or conversion leftovers remain'
[[ $(wc -l < "$tree/etc/kindi-target/verified-weights") == 2 ]] || fail "verified record: $(cat "$tree/etc/kindi-target/verified-weights")"
pass 'the 27B and its 2B draft are downloaded, verified and converted; nothing else'

: > "$log"
FAKE_HF_DOWN=1 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'no-op rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged rerun stopped the service'
grep -q -- '-m kindi' "$log" && fail 'an unchanged rerun converted or verified'
grep -q 'huggingface.co' "$log" && fail 'an unchanged rerun contacted Hugging Face'
grep -q 'sha256sum' "$log" && fail 'an unchanged rerun hashed the weights again'
pass 'an unchanged, healthy install is left running, with no download, conversion or rehash'

: > "$log"
FAKE_MAIN_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa KINDI_REF=main run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'new main rerun'; }
[[ $(< "$tree/opt/kindi/.git/HEAD") == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || fail 'rerun did not move to the new main'
contains 'Upgrading Kindi' "$tmp_root/out"
contains 'systemctl stop kindi.service' "$log"
contains "update-ref refs/kindi/previous $(< "$script_dir/upstream-commit.txt")" "$log"
contains 'uv pip sync' "$log"
contains 'Have the bonsai-27b pack (format 1).' "$tmp_root/out"
grep -q 'kindi convert' "$log" && fail 'an upgrade with the same pack format converted again'
contains 'verify ' "$log"
[[ $(< "$tree/etc/kindi-target/api-key") == "$key" ]] || fail 'rerun replaced the key'
pass 'a new upstream commit rebuilds the venv and verifies on a rerun, keeping the key, the packs and a rollback ref'

commit=0123456789abcdef0123456789abcdef01234567
: > "$log"
KINDI_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'pinned rerun'; }
[[ $(< "$tree/opt/kindi/.git/HEAD") == "$commit" ]] || fail 'pinned rerun did not move HEAD'
contains "fetch -q --depth 1 origin $commit" "$log"
pass 'an explicit commit pin overrides the branch'

: > "$log"
FAKE_INACTIVE=3 KINDI_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'inactive rerun'; }
contains 'Re-applying Kindi' "$tmp_root/out"
contains 'systemctl restart kindi.service' "$log"
pass 'a stopped service is brought back on a rerun even when nothing changed'

: > "$log"
KINDI_COMMIT=$commit KINDI_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'context rerun'; }
contains 'Re-applying Kindi' "$tmp_root/out"
contains 'ctx = 65536' "$conf"
contains 'KINDI_CONTEXT=65536' "$tree/etc/kindi-target/installed-env"
printf 'KINDI_CARDS=2\n' > "$envfile"
: > "$log"
KINDI_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'edited environment rerun'; }
contains 'Re-applying Kindi' "$tmp_root/out"
contains 'KINDI_CARDS=1' "$envfile"
pass 'a changed setting or a hand-edited unit environment is re-applied, and the setting is kept afterwards'

: > "$log"
KINDI_COMMIT=$commit FAKE_SERVED_CTX=110592 KINDI_CONTEXT=131072 run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'fitted context'; }
contains 'Kindi fitted the context to the free memory: 110592 tokens (asked for 131072).' "$tmp_root/out"
pass 'the context the engine fitted to the card is reported'

: > "$log"
before=$(< "$tree/opt/kindi/.git/HEAD")
if FAKE_FETCH_FAIL=1 KINDI_COMMIT=123456789abcdef0123456789abcdef012345678 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade without network reported success'
fi
contains 'was not stopped or changed' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'a failed fetch stopped the service'
[[ $(< "$tree/opt/kindi/.git/HEAD") == "$before" ]] || fail 'a failed fetch moved the checkout'
pass 'a failed fetch leaves the running service untouched'

: > "$log"
if FAKE_SNAPSHOT_FAIL=1 KINDI_COMMIT=$commit KINDI_PORT=8123 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed runtime snapshot reported success'
fi
contains 'Runtime snapshot failed; the previous service is running again.' "$tmp_root/out"
grep -q 'uv venv' "$log" && fail 'a failed snapshot reached the venv build'
[[ ! -e $tree/var/lib/kindi-target/rollback-runtime.tar.new ]] || fail 'partial snapshot was not removed'
[[ $(grep '^curl ' "$log" | tail -n1) == *'127.0.0.1:8093/'* ]] || fail 'snapshot failure probed the attempted port'
pass 'a snapshot failure aborts before the build and restarts the original service'

: > "$log"
next=123456789abcdef0123456789abcdef012345678
KINDI_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade'; }
[[ ! -e $tree/var/lib/kindi-target/rollback-runtime.tar && ! -e $tree/var/lib/kindi-target/rollback.conf ]] ||
    fail 'the snapshot was kept after a successful upgrade'
[[ $(< "$tree/opt/kindi/.git/HEAD") == "$next" ]] || fail 'upgrade did not move HEAD'
printf 'previous runtime\n' > "$tree/opt/kindi/.venv/rollback-marker"
bad=fedcba9876543210fedcba9876543210fedcba98
: > "$log"
if FAKE_BAD_COMMIT=$bad KINDI_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains "Kindi is running $next again" "$tmp_root/out"
[[ $(< "$tree/opt/kindi/.git/HEAD") == "$next" ]] || fail 'rollback did not restore HEAD'
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] || fail 'rollback fetched again instead of using the local commit'
[[ $(cat "$tree/opt/kindi/.venv/rollback-marker") == 'previous runtime' ]] || fail 'the venv was not restored'
[[ ! -e $tree/opt/kindi/runtime-from-failed-upgrade ]] || fail 'failed runtime file survived'
awk '/^git .* reset / {restoring=1;next} restoring && /^uv (venv|pip)/ {exit 1}' "$log" || fail 'rollback rebuilt the venv'
[[ ! -e $tree/var/lib/kindi-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful rollback'
pass 'a failed upgrade returns to the previous commit and venv without the network'

: > "$log"
pack_manifest=$packs/bonsai-27b-f1/kindi_pack.json
cp "$pack_manifest" "$tmp_root/good-pack.json"
printf '{"source_sha256": "previous-weight-pin"}\n' > "$pack_manifest"
if FAKE_VERIFY_FAIL=1 KINDI_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade that failed kindi verify reported success'
fi
contains 'kindi verify failed' "$tmp_root/out"
contains "Kindi is running $next again" "$tmp_root/out"
contains 'previous-weight-pin' "$pack_manifest"
[[ ! -e $tree/var/lib/kindi-target/rollback-packs ]] || fail 'a restored pack backup was kept'
cp "$tmp_root/good-pack.json" "$pack_manifest"
pass 'a failed verify restores the previous commit, venv and any replaced same-format pack'

: > "$log"
if FAKE_READY=0 KINDI_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade whose server never answered reported success'
fi
contains 'has not answered' "$tmp_root/out"
contains "Rollback to $next failed too" "$tmp_root/out"
contains 'the snapshot is kept in' "$tmp_root/out"
[[ -s $tree/var/lib/kindi-target/rollback-runtime.tar ]] || fail 'a failed rollback removed the snapshot'
pass 'an upgrade is not healthy until /health names the model and /v1/models lists it; a failed rollback keeps its snapshot'

[[ -e $tree/var/lib/kindi-target/rollback-failed ]] || fail 'a failed rollback left no marker'
cp "$tree/var/lib/kindi-target/rollback-runtime.tar" "$tmp_root/kept.tar"
: > "$log"
if KINDI_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade over a failed rollback went ahead'
fi
contains 'A rollback failed earlier' "$tmp_root/out"
if grep -qE '^(systemctl stop|git .* fetch )' "$log"; then fail 'a refused run stopped or fetched anything'; fi
cmp -s "$tmp_root/kept.tar" "$tree/var/lib/kindi-target/rollback-runtime.tar" || fail 'a refused run changed the kept snapshot'
if KINDI_COMMIT=$next run_target > "$tmp_root/out" 2>&1; then
    fail 'an install over a failed rollback went ahead'
fi
contains 'A rollback failed earlier' "$tmp_root/out"
rm -f -- "$tree/var/lib/kindi-target/rollback-failed" "$tmp_root/kept.tar"
pass 'after a failed rollback the next run stops, changing nothing, until its marker is removed'

: > "$log"
KINDI_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'reset to a healthy install'; }
cp "$unit" "$tmp_root/good.service"; cp "$envfile" "$tmp_root/good.env"; cp "$conf" "$tmp_root/good.conf"
cp "$tree/etc/kindi-target/installed-settings" "$tmp_root/good-settings"
cp "$deploy/kindi.service" "$tmp_root/deploy.service"
printf '# changed by the attempted upgrade\n' >> "$deploy/kindi.service"
: > "$log"
if FAKE_BAD_COMMIT=$bad KINDI_COMMIT=$bad KINDI_CONTEXT=32768 KINDI_PORT=11434 \
        run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade with new settings reported success'
fi
cp "$tmp_root/deploy.service" "$deploy/kindi.service"
contains "Kindi is running $next again" "$tmp_root/out"
contains 'Restoring the settings it last ran with' "$tmp_root/out"
cmp -s "$unit" "$tmp_root/good.service" || fail 'rollback kept the attempted unit'
cmp -s "$envfile" "$tmp_root/good.env" || fail 'rollback kept the attempted environment'
cmp -s "$conf" "$tmp_root/good.conf" || fail 'rollback kept the attempted server config'
cmp -s "$tree/etc/kindi-target/installed-settings" "$tmp_root/good-settings" || fail 'a failed upgrade changed the record'
[[ $(grep '^curl ' "$log" | tail -n1) == *':8093/'* ]] || fail "the rollback was not checked on the recorded port"
: > "$log"
KINDI_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after rollback'; }
contains 'nothing to do' "$tmp_root/out"
pass 'rollback restores the previous settings, environment, config and unit, not the ones that failed'

rm -f "$tree/etc/kindi-target/installed-env"
: > "$log"
KINDI_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'record migration'; }
[[ -f $tree/etc/kindi-target/installed-env ]] || fail 'a healthy rerun did not backfill its settings'
grep -q 'systemctl stop' "$log" && fail 'record migration stopped the service'
pass 'a healthy rerun without installed-env backfills it without restarting'

rm -f "$tree/etc/kindi-target/installed-env"
: > "$log"
if FAKE_BAD_COMMIT=$bad KINDI_COMMIT=$bad KINDI_PORT=11434 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains 'No record of the previous settings' "$tmp_root/out"
contains "Kindi is running $next again" "$tmp_root/out"
[[ $(grep '^curl ' "$log" | tail -n1) == *':8093/'* ]] || fail "a rollback without installed-env was not checked on the fingerprint's port"
pass 'an install without a settings record still rolls back, from its runtime snapshot'

# A new pack format: the next commit converts into a pack of its own; a
# rollback still has the old one.
: > "$log"
newfmt=1111111111111111111111111111111111111111
FAKE_PACK_FORMAT_AT=$newfmt KINDI_COMMIT=$newfmt run_target --upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'new pack format'; }
[[ -f $packs/bonsai-27b-f2/kindi_pack.json && -f $packs/bonsai-27b-f1/kindi_pack.json ]] || fail 'the new format replaced the old pack'
contains "pack = $packs/bonsai-27b-f2" "$conf"
: > "$log"
FAKE_PACK_FORMAT_AT=$newfmt KINDI_COMMIT=$newfmt run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun at the new format'; }
contains 'nothing to do' "$tmp_root/out"
pass 'a new pack format converts beside the old pack (kept for a rollback) and is recorded as installed'

# --- weights: resume, corruption, upstream changes, disk space -------------------
reset_tree
KINDI_MODEL=bonsai-9b FAKE_CUT=${fixture_file[bonsai-9b]} run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resumed download'; }
contains "download ${fixture_file[bonsai-9b]} from 100" "$log"
cmp -s "$models/${fixture_file[bonsai-9b]}" "$hf/${fixture_file[bonsai-9b]}" || fail 'the resumed download differs'
contains 'KINDI_MODEL=bonsai-9b' "$tree/etc/kindi-target/installed-env"
pass 'an interrupted download resumes where it stopped; an explicit model is kept'

reset_tree
out=$(KINDI_MODEL=bonsai-4b FAKE_CORRUPT=${fixture_file[bonsai-4b]} run_target 2>&1) && fail 'a corrupt model was accepted'
[[ $out == *"Checksum mismatch for ${fixture_file[bonsai-4b]}"* ]] || fail "corrupt model message: $out"
[[ ! -e $models/.${fixture_file[bonsai-4b]}.part ]] || fail 'the corrupt download was kept'
[[ ! -e $unit ]] || fail 'a unit was installed with corrupt weights'
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after a corrupt model'; }
cmp -s "$models/${fixture_file[bonsai-4b]}" "$hf/${fixture_file[bonsai-4b]}" || fail 'the model after a corrupt download'
contains 'Resuming an interrupted install' "$tmp_root/out"
pass 'a corrupt download is removed and a rerun fetches it again with the settings it was started with'

reset_tree
out=$(FAKE_ETAG=$(printf 'f%.0s' {1..64}) run_target 2>&1) && fail 'a changed upstream file was downloaded'
[[ $out == *'not the reviewed'* && $out == *'update kindi-weights.txt'* ]] || fail "etag message: $out"
grep -q '^download ' "$log" && fail 'something was downloaded before the upstream hashes were checked'
pass 'an upstream file whose hash changed is refused before anything is downloaded'

reset_tree
out=$(FAKE_DF_AVAIL=1073741824 run_target 2>&1) && fail 'an install without room for the model was started'
[[ $out == *'pct resize'* ]] || fail "disk message: $out"
grep -q '^download ' "$log" && fail 'a download started without room for it'
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'install after freeing space'; }
: > "$log"
FAKE_DF_AVAIL=1024 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'a verified rerun on a full disk'; }
contains 'nothing to do' "$tmp_root/out"
pass 'missing disk space is reported, with the resize command, before any download; a complete install needs no spare room'

# --- other cards ------------------------------------------------------------------
reset_tree
FAKE_CAP='' FAKE_VRAM_MIB=980 FAKE_GPU_NAME='Quadro K420' run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'Quadro K420 install'; }
contains 'GPU 0: Quadro K420, 980 MiB, compute capability 3.0.' "$tmp_root/out"
contains 'Kindi profile for this card: kepler.' "$tmp_root/out"
contains 'model_name = bonsai2-2b' "$conf"
contains 'ctx = 24576' "$conf"
contains 'KINDI_BLOCKING_SYNC=0' "$envfile"
grep -q 'KINDI_TC=\|KINDI_SPEC' "$envfile" && fail 'a Kepler card got the tensor-core settings'
[[ ! -e $models/${fixture_file[bonsai-27b]} ]] || fail 'the K420 got the 27B'
pass 'a 1 GB Quadro K420 on the 470 driver (no compute capability) gets the 2B, by its name'

reset_tree
out=$(FAKE_CAP='' FAKE_GPU_NAME='Quadro M4000' run_target 2>&1) && fail 'a card without a compute capability was guessed'
[[ $out == *'set KINDI_PROFILE'* ]] || fail "unknown card message: $out"
FAKE_CAP='' FAKE_GPU_NAME='Quadro M4000' FAKE_VRAM_MIB=8192 KINDI_PROFILE=maxwell run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'an explicit profile'; }
contains 'model_name = bonsai2-9b' "$conf"
pass 'a card whose compute capability cannot be read needs KINDI_PROFILE'

reset_tree
FAKE_CAP=6.1 FAKE_VRAM_MIB=8192 FAKE_GPU_NAME='NVIDIA GeForce GTX 1080' run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'GTX 1080 install'; }
contains 'Kindi profile for this card: pascal8.' "$tmp_root/out"
contains 'ctx = 65536' "$conf"
[[ ! -e $models/${fixture_file[bonsai-2b]} ]] || fail 'the GTX 1080 downloaded a draft model'
pass 'a GTX 1080 runs the 27B with the pascal8 profile and no draft model'

reset_tree
out=$(FAKE_VRAM_MIB=4096 FAKE_CAP=5.0 KINDI_MODEL=bonsai-27b run_target 2>&1) && fail 'a 27B was installed on a 4 GB card'
[[ $out == *'needs a card with 7600 MiB'* ]] || fail "VRAM message: $out"
grep -qE '^(apt-get|git|download) ' "$log" && fail 'something changed before the VRAM check'
out=$(FAKE_VRAM_MIB=24576 FAKE_CAP=7.5 KINDI_MODEL=nanbeige-33b run_target 2>&1) && fail 'Nanbeige on an RTX 20 card'
[[ $out == *'compute capability 8.0 or newer'* ]] || fail "Nanbeige message: $out"
FAKE_VRAM_MIB=24576 FAKE_CAP=8.6 KINDI_MODEL=nanbeige-33b run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'Nanbeige install'; }
contains 'model_name = nanbeige-33b-iq3' "$conf"
contains 'ctx = 16384' "$conf"
contains 'KINDI_MAX_TOKENS=16384' "$envfile"
pass 'a model the card cannot hold is refused before any download; Nanbeige needs sm_80 and gets its own profile'

FAKE_NVIDIA=0 reset_tree
FAKE_NVIDIA=0 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'CPU install'; }
contains "Kindi's CPU engine: bonsai-2b on 6 threads." "$tmp_root/out"
grep -q 'cuda-toolkit.sh' "$log" && fail 'a CPU install installed CUDA'
grep -q 'cupy' "$log" && fail 'a CPU install checked CuPy'
cmp -s "$tree/var/lib/kindi/requirements.lock" "$script_dir/requirements-cpu.lock" || fail 'the CPU venv lock'
contains 'KINDI_DEVICE=cpu' "$envfile"
contains 'OMP_NUM_THREADS=6' "$envfile"
contains 'verify ' "$log"
contains 'KINDI_DEVICE=cpu' "$log"
contains 'KINDI_BACKEND=cpu' "$tree/etc/kindi-target/installed-env"
FAKE_NVIDIA=0 FAKE_CPU_FLAG=sse4_2 reset_tree
out=$(FAKE_NVIDIA=0 run_target 2>&1) && fail 'a CPU without AVX2 was accepted'
[[ $out == *'no AVX2'* ]] || fail "AVX2 message: $out"
out=$(FAKE_NVIDIA=0 KINDI_MODEL=bonsai-27b run_target 2>&1) && fail 'a CPU 27B was accepted'
[[ $out == *'CPU engine runs bonsai-2b, bonsai-4b and bonsai-9b'* ]] || fail "CPU model message: $out"
pass 'without an NVIDIA GPU the CPU engine serves the 2B on the CT'\''s cores; no CUDA, no CuPy'

# --- refusals before anything changes ---------------------------------------------
reset_tree
out=$(FAKE_CUDA_UNAVAILABLE=1 run_target 2>&1) && fail 'an unavailable CUDA toolkit was accepted'
[[ $out == *'CUDA 10.2 toolkit cannot be installed in this CT'* ]] || fail "CUDA preflight message: $out"
grep -qE '^(apt-get|git|uv) ' "$log" && fail 'something was installed or fetched before the CUDA preflight'
pass 'a distro the CUDA 10.2 runfile does not run on stops the installer before anything changes'

reset_tree
out=$(FAKE_IMPORT_FAIL=1 run_target 2>&1) && fail 'a venv that cannot load CuPy was accepted'
[[ $out == *"Kindi's venv does not work on this cuda backend"* ]] || fail "venv message: $out"
grep -q '^download ' "$log" && fail 'the model was downloaded before the runtime worked'
pass 'a runtime that cannot run a kernel on the GPU fails before the download'

reset_tree
out=$(FAKE_VERIFY_FAIL=1 run_target 2>&1) && fail 'a model that failed kindi verify was served'
[[ $out == *'kindi verify failed'* ]] || fail "verify message: $out"
[[ ! -e $unit ]] || fail 'a unit was installed after a failed verify'
pass 'a model that fails kindi verify is not served'

FAKE_MEM_KIB=8388608 reset_tree
out=$(run_target 2>&1) && fail 'the 27B in an 8 GiB CT was accepted'
[[ $out == *'bonsai-27b needs about 13824 MiB'* ]] || fail "RAM message: $out"
grep -qE '^(apt-get|git) ' "$log" && fail 'something changed before the RAM check'
pass 'a CT without the RAM the model needs is refused before anything changes'

reset_tree
out=$(FAKE_GROUP=root run_target 2>&1) && fail 'GPU nodes in group root were accepted'
[[ $out == *'gid=44'* ]] || fail "root group message: $out"
pass 'GPU nodes owned by group root are refused with the pct set fix'

reset_tree
mkdir -p "$tree/opt/kindi"; touch "$tree/opt/kindi/stray"
out=$(run_target 2>&1) && fail 'a non-git /opt/kindi was used'
[[ $out == *'is not a Git checkout'* ]] || fail "non-git message: $out"
pass 'a non-empty non-git source directory is refused'

reset_tree
KINDI_HEAD=fast run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fast head install'; }
[[ -f $packs/bonsai-27b-f1/head_clusters.npz ]] || fail 'the fast head was not built'
contains 'head = fast' "$conf"
pass 'KINDI_HEAD=fast builds the fast head'\''s cluster file'

output=$(env -i "PATH=$PATH" bash "$script_dir/install-target.sh" --dry-run 2>&1)
[[ $output == *"git fetch --depth 1 https://github.com/ahtx/kindi.git $(< "$script_dir/upstream-commit.txt") into /opt/kindi"* ]] || fail "dry-run fetch: $output"
[[ $output == *'cuda-toolkit.sh (CUDA 10.2'* && $output == *'requirements-cuda.lock'* ]] || fail "dry-run cuda: $output"
[[ $output == *'the key [redacted]'* ]] || fail 'dry-run key'
output=$(env -i "PATH=$PATH" KINDI_BACKEND=cpu bash "$script_dir/install-target.sh" --dry-run 2>&1)
[[ $output == *'requirements-cpu.lock'* && $output == *'GGUF of bonsai-2b'* && $output != *cuda-toolkit* ]] ||
    fail "dry-run cpu: $output"
pass 'the dry run shows the pinned commit, the toolkit and lock of either backend and no key'

# --- saved settings -------------------------------------------------------------
saved_env() {
    local -a e
    mapfile -t e < <(common_env)
    env -i "${e[@]}" KINDI_COMMIT="$(< "$tree/opt/kindi/.git/HEAD")" "$@"
}
saved_upgrade() { saved_env "$@" bash "$target" --upgrade; }
saved_rerun() { saved_env bash "$target"; }
reset_tree
KINDI_PORT=8123 KINDI_CONTEXT=65536 KINDI_MODEL=bonsai-9b run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'custom install before saved-settings upgrade'; }
record=$tree/etc/kindi-target/installed-env
contains 'KINDI_MODEL=bonsai-9b' "$record"
cp "$record" "$tmp_root/custom-settings"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'bare upgrade with saved settings'; }
cmp -s "$record" "$tmp_root/custom-settings" || fail 'bare upgrade reset saved settings'
contains 'nothing to do' "$tmp_root/out"
grep -q 'Model for this card' "$tmp_root/out" && fail 'a saved model was chosen again'
pass 'a bare --upgrade preserves custom settings (the model too) and leaves an unchanged service running'
saved_upgrade KINDI_PORT=8124 > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'saved-settings explicit override'; }
sed 's/^KINDI_PORT=.*/KINDI_PORT=8124/' "$tmp_root/custom-settings" > "$tmp_root/expected-settings"
cmp -s "$record" "$tmp_root/expected-settings" || fail 'an explicit override reset another saved setting'
pass 'an explicit upgrade setting overrides only that saved value'
cp "$record" "$tmp_root/valid-settings"
sed -i 's/^KINDI_PORT=.*/KINDI_PORT=99999/' "$record"
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
saved_upgrade KINDI_PORT= > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade with an empty port'; }
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
cp "$tree/etc/kindi-target/installed-settings" "$tmp_root/fingerprint"
sed -i '/^port=/d' "$tree/etc/kindi-target/installed-settings"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'an unreadable fingerprint fell back to defaults'; fi
contains 'Cannot read this installation' "$tmp_root/out"
[[ ! -s $log ]] || fail 'an unreadable fingerprint touched the installation'
mv "$tmp_root/fingerprint" "$tree/etc/kindi-target/installed-settings"
cp "$tmp_root/current-settings" "$record"
pass 'an unreadable fingerprint is refused before anything runs, unless every setting is given'
(
    unset "${SETTING_KEYS[@]}"
    KINDI_ETC_DIR="$tree/etc/kindi-target" KINDI_DIR="$tree/opt/kindi" UNIT_DIR="$tree/etc/systemd/system"
    KINDI_MODEL=bonsai-4b
    saved_settings
    [[ $KINDI_MODEL == bonsai-4b && $KINDI_CONTEXT == auto && $KINDI_MODEL_NAME == auto && $KINDI_PROFILE == auto &&
       $KINDI_PORT == 8124 ]] || fail "a model switch kept the old sizing: $KINDI_CONTEXT $KINDI_MODEL_NAME $KINDI_PROFILE"
) || fail 'model override'
(
    unset "${SETTING_KEYS[@]}"
    KINDI_ETC_DIR="$tree/etc/kindi-target" KINDI_DIR="$tree/opt/kindi" UNIT_DIR="$tree/etc/systemd/system"
    KINDI_BACKEND=cpu
    saved_settings
    [[ $KINDI_BACKEND == cpu && $KINDI_MODEL == auto && $KINDI_PROFILE == auto && $KINDI_THREADS == auto ]] ||
        fail "a backend switch kept the old model: $KINDI_MODEL $KINDI_PROFILE"
) || fail 'backend override'
pass 'a model or backend switch sizes the profile, context and model id for the card again'

# Lost metadata must not turn a configured target into a fresh installation.
cp "$record" "$tmp_root/recovery-settings"
rm -f "$record" "$tree/etc/kindi-target/installed-settings"
for metadata_state in missing dangling; do
    if [[ $metadata_state == dangling ]]; then
        ln -s "$tree/etc/kindi-target/missing-fingerprint" "$tree/etc/kindi-target/installed-settings"
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
    rm -f "$tree/etc/kindi-target/installed-settings"
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
[[ -s $tree/etc/kindi-target/installed-settings ]] || fail 'explicit recovery did not recreate the fingerprint'
pass 'complete explicit settings recover lost metadata without resetting custom values'

# A first install that stops part-way resumes with the settings it was started with.
reset_tree
pbad=fedcba9876543210fedcba9876543210fedcba98
if FAKE_BAD_COMMIT=$pbad KINDI_COMMIT=$pbad KINDI_PORT=8123 KINDI_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a first install whose runtime fails reported success'
fi
pending=$tree/etc/kindi-target/pending-env
[[ -f $pending && ! -e $record ]] || fail 'an interrupted first install left no pending-env, or a settings record'
[[ $(stat -c %a "$pending") == 600 ]] || fail 'pending-env is not root-only'
contains 'KINDI_PORT=8123' "$pending"
contains 'KINDI_PROFILE=tc' "$pending"
cp "$pending" "$tmp_root/started-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming the interrupted install'; }
contains 'Resuming an interrupted install' "$tmp_root/out"
cmp -s "$record" "$tmp_root/started-settings" || fail "the resumed install did not keep its settings: $(tr '\n' ' ' < "$record")"
[[ ! -e $pending ]] || fail 'pending-env was left after a successful install'
pass 'an interrupted first install resumes with the settings it was started with'

reset_tree
if FAKE_METADATA_FAIL=1 KINDI_PORT=8123 KINDI_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed fingerprint rename reported success'
fi
[[ -f $pending && -s $record && ! -e $tree/etc/kindi-target/installed-settings ]] ||
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
