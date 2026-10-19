#!/usr/bin/env bash
# Exercise install-target.sh: the setup.sh --help helpers against Maya's real
# v1.1.15 usage text and an older layout, then whole-script runs against a
# temporary tree with stubbed git, setup.sh, systemctl, curl, nvcc and account
# tools. Nothing is downloaded, installed or started.
# The MAYA_* and SETUP_HELP assignments below are read by the sourced helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/maya-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/maya-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# The usage block `./setup.sh --help` prints at v1.1.15 (a4e1ff0), verbatim.
help_current=$tmp_root/help-current
cat > "$help_current" <<'HELP'
usage: maya.py [-h] [--backend {cuda,hip}] [--setup] [--check] [--no-start]
               [--yes] [--plain] [--download-model]
               [--model {Maya-S-v2-IQ2_XXS,Maya-S24,Maya-M,Maya-M-Derisked,Maya-L,EXL3-3.05bpw,EXL3-4.05bpw}]
               [--draft {mtp,dflash2}] [--no-vision] [--gguf-dir GGUF_DIR]
               [--models-dir MODELS_DIR] [--gpu GPU] [--gpus GPUS]
               [--context CONTEXT] [--parallel N] [--vram-reserve-mib N]
               [--port PORT] [--host HOST] [--api-key API_KEY]
               [--env KEY=VALUE] [--nvcc NVCC] [--host-compiler HOST_COMPILER]
               [--llama-dir LLAMA_DIR] [--rebuild] [--repack] [--report]
               [--bench] [--calibrate] [--speed-calibration]
               [--no-speed-calibration] [--config CONFIG]
HELP
# An older release: no --draft, no --nvcc, no --plain.
help_older=$tmp_root/help-older
cat > "$help_older" <<'HELP'
usage: maya.py [-h] [--setup] [--check] [--no-start] [--yes] [--download-model]
               [--model {Maya-S-v2-IQ2_XXS,Maya-S24,Maya-M,Maya-L}] [--no-vision]
               [--models-dir MODELS_DIR] [--context CONTEXT] [--port PORT]
               [--host HOST] [--api-key API_KEY]
HELP
# A layout without --api-key, which the installer must refuse.
help_keyless=$tmp_root/help-keyless
sed 's/ \[--api-key API_KEY\]//' "$help_current" > "$help_keyless"

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in help_has help_choices check_choice validate_setup_options setup_args \
              select_run_script newest_release_tag start_env validate_settings settings_env \
              load_settings fingerprint_env saved_settings; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done
MAYA_MODEL=Maya-S-v2-IQ2_XXS MAYA_CONTEXT=32768 MAYA_NO_VISION=false MAYA_DRAFT=mtp
MAYA_PORT=8080 MAYA_DATA_DIR=/var/lib/maya MAYA_NVCC=/usr/local/cuda-12.8/bin/nvcc

SETUP_HELP=$(< "$help_current")
help_has --draft && help_has --nvcc && help_has --host && help_has --api-key || fail 'current flags'
! help_has --hos && ! help_has --api || fail 'partial flag names matched'
help_has --host-compiler && help_has --host || fail '--host must not depend on --host-compiler'
[[ $(help_choices --draft) == 'mtp dflash2' ]] || fail "draft choices: $(help_choices --draft)"
[[ $(help_choices --model) == *'Maya-S24 Maya-M Maya-M-Derisked Maya-L'* ]] || fail "model choices: $(help_choices --model)"
(validate_setup_options) || fail 'current help rejected'
args=$(setup_args | tr '\n' ' ')
[[ $args == '--setup --no-start --yes --download-model --plain --model Maya-S-v2-IQ2_XXS --draft mtp --nvcc /usr/local/cuda-12.8/bin/nvcc --context 32768 --host 0.0.0.0 --port 8080 --models-dir /var/lib/maya/models ' ]] ||
    fail "setup args: $args"
[[ $(setup_args) != *api-key* ]] || fail 'the key must never be in the args'
MAYA_NO_VISION=true
[[ $(setup_args | tr '\n' ' ') == *' --no-vision '* ]] || fail 'no-vision not passed'
MAYA_NO_VISION=false
pass 'setup is given the model, --draft mtp and the installed nvcc, never the key'

SETUP_HELP=$(< "$help_older")
(validate_setup_options) || fail 'older help rejected with the default draft'
args=$(setup_args | tr '\n' ' ')
[[ $args != *--draft* && $args != *--nvcc* && $args != *--plain* ]] || fail "older args: $args"
out=$( (MAYA_DRAFT=dflash2; validate_setup_options) 2>&1 ) && fail 'dflash2 accepted without --draft'
[[ $out == *'no --draft option'* ]] || fail "draft message: $out"
pass 'an older checkout without --draft/--nvcc gets neither, and refuses another draft'

SETUP_HELP=$(< "$help_keyless")
out=$( (validate_setup_options) 2>&1 ) && fail 'a checkout without --api-key was accepted'
[[ $out == *'does not accept: --api-key'* ]] || fail "missing-flag message: $out"
SETUP_HELP=$(< "$help_current")
out=$( (MAYA_MODEL=Maya-XL; validate_setup_options) 2>&1 ) && fail 'unknown model accepted'
[[ $out == *'does not accept --model Maya-XL'* ]] || fail "model message: $out"
out=$( (MAYA_DRAFT=eagle; validate_setup_options) 2>&1 ) && fail 'unknown draft accepted'
[[ $out == *'does not accept --draft eagle (it offers: mtp dflash2)'* ]] || fail "draft choice message: $out"
pass 'required options, model and draft are checked against the help'

# select_run_script against the line setup really prints (the full path).
MAYA_DIR=$tmp_root/maya; mkdir -p "$MAYA_DIR"
launcher=$MAYA_DIR/run-maya-maya-s-v2-iq2_xxs.sh
printf '#!/bin/sh\nexit 0\n' > "$launcher"; chmod +x "$launcher"
printf '  [ok] config: %s/maya-maya-s-v2-iq2_xxs.json\n  [ok] start script: %s\n' "$MAYA_DIR" "$launcher" > "$tmp_root/setup.log"
run_script=''
select_run_script "$tmp_root/setup.log" || fail 'the full-path line Maya prints was refused'
[[ $(start_env | tail -n1) == "MAYA_RUN_SCRIPT=$launcher" ]] || fail "full-path launcher: $(start_env)"
printf '  [ok] start script: run-maya-maya-s-v2-iq2_xxs.sh\n' > "$tmp_root/setup.log"
select_run_script "$tmp_root/setup.log" || fail 'bare launcher name refused'
[[ $run_script == "$launcher" ]] || fail 'bare launcher name selected wrongly'
printf '  [ok] start script: /srv/other/run-maya-x.sh\n' > "$tmp_root/setup.log"
out=$( (select_run_script "$tmp_root/setup.log") 2>&1) && fail 'launcher outside MAYA_DIR accepted'
[[ $out == *'outside'* ]] || fail "outside message: $out"
printf '  [ok] start script: %s/run-other.sh\n' "$MAYA_DIR" > "$tmp_root/setup.log"
out=$( (select_run_script "$tmp_root/setup.log") 2>&1) && fail 'non-Maya launcher accepted'
printf '  [ok] start script: %s/run-maya-missing.sh\n' "$MAYA_DIR" > "$tmp_root/setup.log"
out=$( (select_run_script "$tmp_root/setup.log") 2>&1) && fail 'missing launcher accepted'
[[ $out == *'did not generate an executable'* ]] || fail "missing launcher message: $out"
pass 'the launcher is taken from the full path setup prints, and only inside MAYA_DIR'

marker=$tmp_root/marker; touch -d '@1000000000' "$marker"
touch -d '@999999999' "$launcher"                                    # older than the marker
printf '#!/bin/sh\n' > "$MAYA_DIR/run-maya-maya-s24.sh"; chmod +x "$MAYA_DIR/run-maya-maya-s24.sh"
printf 'setup finished\n' > "$tmp_root/setup.log"
out=$(select_run_script "$tmp_root/setup.log" "$marker" 2>&1; start_env | tail -n1)
[[ $out == *'did not name its start script; using run-maya-maya-s24.sh'* ]] || fail "fallback note: $out"
[[ $out == *"MAYA_RUN_SCRIPT=$MAYA_DIR/run-maya-maya-s24.sh" ]] || fail "fallback launcher: $out"
touch "$launcher"                                                    # now two are fresh
out=$( (select_run_script "$tmp_root/setup.log" "$marker") 2>&1) && fail 'two fresh launchers accepted'
[[ $out == *'wrote several run scripts'* ]] || fail "ambiguous message: $out"
rm -f "$MAYA_DIR"/run-*.sh
out=$( (select_run_script "$tmp_root/setup.log" "$marker") 2>&1) && fail 'no launcher accepted'
[[ $out == *'did not report or write'* ]] || fail "no launcher message: $out"
pass 'an unnamed launcher falls back to the one setup just wrote, never a guess'

tags=$'8c131f4e58acded569ced748a6e223789c48fe6e\trefs/tags/v1.1.5
6a35bd4b73d498065419ee99a1ac76f8a1421efc\trefs/tags/v1.1.9
a4e1ff087a4097a73713336df5912d03a1453c46\trefs/tags/v1.1.15
1111111111111111111111111111111111111111\trefs/tags/v1.2.0-rc1
2222222222222222222222222222222222222222\trefs/tags/v1.1.15^{}
3333333333333333333333333333333333333333\trefs/tags/nightly'
[[ $(newest_release_tag <<< "$tags") == refs/tags/v1.1.15 ]] || fail "newest tag: $(newest_release_tag <<< "$tags")"
[[ -z $(newest_release_tag <<< $'3333333333333333333333333333333333333333\trefs/tags/nightly') ]] ||
    fail 'a non-version tag was taken as a release'
pass 'the newest vX.Y.Z tag is chosen by version, not by name (v1.1.15 > v1.1.9), and -rc tags are ignored'

# The settings record a rollback restores: written as KEY=value, read back
# all-or-nothing, never sourced.
MAYA_CUDA_VERSION=12.8
settings_env > "$tmp_root/installed-env"
[[ $(grep -c '^MAYA_' "$tmp_root/installed-env") == 7 ]] || fail "settings record: $(cat "$tmp_root/installed-env")"
MAYA_DRAFT=dflash2 MAYA_PORT=11434 MAYA_MODEL=Maya-S24
load_settings "$tmp_root/installed-env" || fail 'a valid record was not loaded'
[[ $MAYA_DRAFT == mtp && $MAYA_PORT == 8080 && $MAYA_MODEL == Maya-S-v2-IQ2_XXS ]] ||
    fail "record not restored: $MAYA_DRAFT $MAYA_PORT $MAYA_MODEL"
sed 's/^MAYA_PORT=.*/MAYA_PORT=99999/' "$tmp_root/installed-env" > "$tmp_root/bad-env"
MAYA_PORT=11434
load_settings "$tmp_root/bad-env" && fail 'an invalid record was loaded'
[[ $MAYA_PORT == 11434 ]] || fail 'an invalid record changed a setting'
grep -v '^MAYA_DRAFT=' "$tmp_root/installed-env" > "$tmp_root/old-env"
load_settings "$tmp_root/old-env" && fail 'a record without every key was loaded'
printf 'MAYA_PORT=8080; touch %s/pwned\n' "$tmp_root" > "$tmp_root/evil-env"
load_settings "$tmp_root/evil-env" && fail 'a malformed record was loaded'
[[ ! -e $tmp_root/pwned ]] || fail 'the record was executed'
load_settings "$tmp_root/missing-env" && fail 'a missing record was loaded'
MAYA_PORT=8080
pass 'the settings record is read back all-or-nothing and never executed'

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
# The installer runs from a copy whose cuda-toolkit.sh is a stub that only
# logs: the real one installs packages.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
cp "$script_dir/install-target.sh" "$script_dir/maya.service" "$deploy/"
log=$tmp_root/calls.log
printf '#!/usr/bin/env bash\necho "cuda-toolkit.sh $* CUDA_VERSION=$CUDA_VERSION CUDA_NVCC=${CUDA_NVCC:-}" >> "%s"\n[[ $1 == --check && ${FAKE_CUDA_UNAVAILABLE:-0} == 1 ]] && { echo "NVIDIA repository lacks it" >&2; exit 1; }\nexit 0\n' "$log" > "$deploy/cuda-toolkit.sh"
target=$deploy/install-target.sh

bin=$tmp_root/bin; mkdir -p "$bin"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub getent 'exit 2'   # no maya group yet, so it is created
stub mv 'if [[ ${FAKE_METADATA_FAIL:-0} == 1 && ${*: -1} == */installed-settings ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
for command_name in apt-get groupadd useradd usermod chown sleep nvidia-smi; do stub "$command_name" 'exit 0'; done
stub stat 'if [[ $1 == -c ]]; then echo "${FAKE_GROUP:-video}"; else exec /usr/bin/stat "$@"; fi'
stub systemctl 'case "$1" in is-failed) exit 1;; is-active) exit "${FAKE_INACTIVE:-0}";; esac; exit 0'
stub tar 'if [[ ${FAKE_SNAPSHOT_FAIL:-0} == 1 && $* == *"-cpf "* ]]; then exit 1; fi; exec /usr/bin/tar "$@"'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
# /health answers while the engine loads; /v1/models lists the model only
# once it is loaded (FAKE_READY=0: never).
stub curl 'url=${@: -1}
case $url in
    */health) printf '\''{"status":"ok","model":"glm-5.3-flash","version":"1.1.15"}\n'\'' ;;
    */v1/models) if [[ ${FAKE_READY:-1} == 1 ]]; then printf '\''{"data":[{"id":"glm-5.3-flash"}]}\n'\''; else printf '\''{"data":[]}\n'\''; fi ;;
    *) exit 22 ;;
esac'
nvcc=$tmp_root/cuda-12.8/bin/nvcc
mkdir -p "${nvcc%/*}"; printf '#!/bin/sh\necho "Cuda compilation tools, release 12.8, V12.8.93"\n' > "$nvcc"; chmod +x "$nvcc"
# git: a fake shallow checkout. Names resolve to a fixed hash; commits that
# were fetched or pinned with update-ref are "local" and can be checked out
# offline. ls-remote prints FAKE_TAGS. FAKE_FETCH_FAIL=1: every fetch and
# ls-remote fails (no network).
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
    ls-remote)
        [[ \${FAKE_FETCH_FAIL:-0} == 1 ]] && { echo 'fatal: unable to access' >&2; exit 128; }
        printf '%s\n' "\${FAKE_TAGS:-}" ;;
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
        cp "$tmp_root/setup.sh" "\$dir/setup.sh" ;;
    rev-parse) if [[ \$2 == FETCH_HEAD* ]]; then cat "\$dir/.git/FETCH"; else cat "\$dir/.git/HEAD"; fi ;;
esac
STUB
chmod +x "$bin/git"
# setup.sh: prints FAKE_HELP for --help; otherwise records its arguments,
# writes the launcher and prints the line Maya prints (with the full path).
# Fails when the checkout is FAKE_BAD_COMMIT.
cat > "$tmp_root/setup.sh" <<STUB
#!/usr/bin/env bash
[[ \$1 == --help ]] && { cat "\$FAKE_HELP"; exit 0; }
echo "setup.sh \$* @\$(< .git/HEAD)" >> "$log"
if [[ \$(< .git/HEAD) == "\${FAKE_BAD_COMMIT:-none}" ]]; then
    rm -f .venv/rollback-marker
    echo broken > runtime-from-failed-upgrade
    exit 1
fi
if [[ \${FAKE_NO_RUN_SCRIPT:-0} != 1 ]]; then
    printf '#!/bin/sh\nexit 0\n' > run-maya-maya-s-v2-iq2_xxs.sh
    chmod +x run-maya-maya-s-v2-iq2_xxs.sh
    echo "  [ok] config: \$PWD/maya-maya-s-v2-iq2_xxs.json"
    echo "  [ok] start script: \$PWD/run-maya-maya-s-v2-iq2_xxs.sh"
fi
STUB

tree=$tmp_root/tree
dev=$tmp_root/dev
release_tags=$tags
reset_tree() {
    rm -rf "$tree" "$dev"; mkdir -p "$tree/etc/systemd/system" "$dev"
    touch "$dev/nvidia0" "$dev/nvidiactl" "$dev/nvidia-uvm"
    : > "$log"
}
run_target() {
    env PATH="$bin:$PATH" FAKE_HELP="${FAKE_HELP:-$help_current}" FAKE_TAGS="${FAKE_TAGS-$release_tags}" \
        MAYA_DIR="$tree/opt/maya" MAYA_DATA_DIR="$tree/var/lib/maya" \
        MAYA_ETC_DIR="$tree/etc/maya-target" MAYA_STATE_DIR="$tree/var/lib/maya-target" UNIT_DIR="$tree/etc/systemd/system" \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" MAYA_READY_TIMEOUT=5 \
        MAYA_COMMIT="${MAYA_COMMIT-}" MAYA_REF="${MAYA_REF-}" MAYA_PORT="${MAYA_PORT:-8080}" \
        MAYA_DRAFT="${MAYA_DRAFT:-mtp}" MAYA_NVCC="${MAYA_NVCC_PATH:-$nvcc}" \
        bash "$target" "$@"
}
contains() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }
sha_of() { printf '%s' "$1" | sha1sum | cut -c1-40; }
v1115=$(sha_of refs/tags/v1.1.15)

reset_tree
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
unit=$tree/etc/systemd/system/maya.service
cmp -s "$unit" "$script_dir/maya.service" || fail 'unit not installed'
launcher=$tree/opt/maya/run-maya-maya-s-v2-iq2_xxs.sh
contains "MAYA_RUN_SCRIPT=$launcher" "$tree/etc/maya-target/maya.env"
contains 'ExecStart=/bin/sh ${MAYA_RUN_SCRIPT}' "$unit"
grep -q 'did not name its start script' "$tmp_root/out" && fail 'the start-script line Maya prints was not recognised'
key=$(< "$tree/etc/maya-target/api-key")
[[ $key =~ ^[0-9a-f]{64}$ ]] || fail 'no generated key'
[[ $(stat -c %a "$tree/etc/maya-target/api-key") == 600 ]] || fail 'key file mode'
contains 'cuda-toolkit.sh --check CUDA_VERSION=12.8' "$log"
contains "cuda-toolkit.sh --check CUDA_VERSION=12.8 CUDA_NVCC=$nvcc" "$log"
contains 'cuda-toolkit.sh  CUDA_VERSION=12.8' "$log"
contains "--setup --no-start --yes --download-model --plain --model Maya-S-v2-IQ2_XXS --draft mtp --nvcc $nvcc" "$log"
contains "--api-key $key" "$log"
contains 'usermod -aG video maya' "$log"
contains 'curl -fsS --max-time 5 http://127.0.0.1:8080/health' "$log"
contains 'systemctl enable maya.service' "$log"
grep -q -- "$key" "$tmp_root/out" && fail 'the key was printed'
grep -q -- "$key" "$tree/etc/maya-target/maya.env" && fail 'the key is in the unit environment'
contains 'draft=mtp' "$tree/etc/maya-target/installed-settings"
pass 'fresh install as the maya account, from the full-path launcher line; key kept out of logs and the unit'

contains "ls-remote --tags --refs https://github.com/mw00/project-maya.git v*" "$log"
contains 'fetch -q --depth 1 origin refs/tags/v1.1.15' "$log"
contains 'Latest Maya release: v1.1.15' "$tmp_root/out"
[[ $(< "$tree/opt/maya/.git/HEAD") == "$v1115" ]] || fail 'not on the v1.1.15 commit'
pass 'by default the newest release tag is installed, not main'

: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'no-op rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged rerun stopped the service'
grep -q '^setup.sh ' "$log" && fail 'an unchanged rerun re-ran setup'
pass 'an unchanged, healthy install on the same release is left running'

: > "$log"
FAKE_TAGS="$release_tags"$'\n4444444444444444444444444444444444444444\trefs/tags/v1.1.16' \
    run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'new release rerun'; }
[[ $(< "$tree/opt/maya/.git/HEAD") == "$(sha_of refs/tags/v1.1.16)" ]] || fail 'rerun did not move to the new release'
contains 'Upgrading Maya' "$tmp_root/out"
contains 'systemctl stop maya.service' "$log"
contains "update-ref refs/maya/previous $v1115" "$log"
[[ $(< "$tree/etc/maya-target/api-key") == "$key" ]] || fail 'rerun replaced the key'
pass 'a new release tag upgrades on a rerun, keeping the key and a rollback ref'

: > "$log"
MAYA_REF=main FAKE_MAIN_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'MAYA_REF=main'; }
grep -q 'ls-remote' "$log" && fail 'an explicit ref still listed tags'
contains 'fetch -q --depth 1 origin main' "$log"
pass 'MAYA_REF=main still follows the branch when asked'

commit=0123456789abcdef0123456789abcdef01234567
: > "$log"
MAYA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'pinned rerun'; }
[[ $(< "$tree/opt/maya/.git/HEAD") == "$commit" ]] || fail 'pinned rerun did not move HEAD'
contains "fetch -q --depth 1 origin $commit" "$log"
grep -q 'ls-remote' "$log" && fail 'a pinned commit still listed tags'
pass 'an explicit commit pin overrides the release default'

: > "$log"
FAKE_INACTIVE=3 MAYA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'inactive rerun'; }
contains 'Re-applying Maya' "$tmp_root/out"
contains 'systemctl restart maya.service' "$log"
pass 'a stopped service is brought back on a rerun even when nothing changed'

: > "$log"
MAYA_DRAFT=dflash2 MAYA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'draft rerun'; }
contains 'Re-applying Maya' "$tmp_root/out"
contains '--draft dflash2' "$log"
contains 'draft=dflash2' "$tree/etc/maya-target/installed-settings"
: > "$log"
MAYA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'draft back to mtp'; }
contains '--draft mtp' "$log"
pass 'a changed draft re-runs setup, and going back passes --draft mtp explicitly'

: > "$log"
before=$(< "$tree/opt/maya/.git/HEAD")
if FAKE_FETCH_FAIL=1 MAYA_COMMIT=123456789abcdef0123456789abcdef012345678 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade without network reported success'
fi
contains 'was not stopped or changed' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'a failed fetch stopped the service'
[[ $(< "$tree/opt/maya/.git/HEAD") == "$before" ]] || fail 'a failed fetch moved the checkout'
: > "$log"
if FAKE_FETCH_FAIL=1 run_target > "$tmp_root/out" 2>&1; then
    fail 'a rerun that could not list release tags reported success'
fi
contains 'Could not list the release tags' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unreachable tag list stopped the service'
pass 'a failed fetch or tag listing leaves the running service untouched'

: > "$log"
if FAKE_SNAPSHOT_FAIL=1 MAYA_PORT=8123 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed runtime snapshot reported success'
fi
contains 'Runtime snapshot failed; the previous service is running again.' "$tmp_root/out"
grep -q '^setup.sh ' "$log" && fail 'a failed snapshot reached setup'
[[ ! -e $tree/var/lib/maya-target/rollback-runtime.tar.new ]] || fail 'partial snapshot was not removed'
[[ $(grep '^curl ' "$log" | tail -n1) == *'127.0.0.1:8080/v1/models'* ]] || fail 'snapshot failure probed the attempted port'
pass 'a snapshot failure aborts before setup and restarts the original service'

: > "$log"
next=123456789abcdef0123456789abcdef012345678
printf 'legacy\n' > "$tree/etc/maya-target/rollback-runtime.tar"; printf 'legacy\n' > "$tree/etc/maya-target/rollback.env"
MAYA_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade'; }
[[ ! -e $tree/var/lib/maya-target/rollback-runtime.tar && ! -e $tree/var/lib/maya-target/rollback.env ]] || fail 'the snapshot was kept after a successful upgrade'
[[ ! -e $tree/etc/maya-target/rollback-runtime.tar && ! -e $tree/etc/maya-target/rollback.env ]] || fail 'a snapshot left in /etc by an earlier revision was not removed'
[[ ! -e $tree/etc/maya-target/installed.service ]] || fail 'the unused installed.service record was written'
[[ $(< "$tree/opt/maya/.git/HEAD") == "$next" ]] || fail 'upgrade did not move HEAD'
contains "@$next" "$log"
mkdir -p "$tree/opt/maya/.venv"
printf 'previous runtime\n' > "$tree/opt/maya/.venv/rollback-marker"
bad=fedcba9876543210fedcba9876543210fedcba98
: > "$log"
if FAKE_BAD_COMMIT=$bad MAYA_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains "Maya is running $next again" "$tmp_root/out"
[[ $(< "$tree/opt/maya/.git/HEAD") == "$next" ]] || fail 'rollback did not restore HEAD'
grep -q "^setup.sh .*@$next" "$log" && fail 'rollback ran setup'
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] || fail 'rollback fetched again instead of using the local commit'
[[ $(cat "$tree/opt/maya/.venv/rollback-marker") == 'previous runtime' ]] || fail 'venv not restored'
[[ ! -e $tree/opt/maya/runtime-from-failed-upgrade ]] || fail 'failed runtime file survived'
awk '/^git .* reset / {restoring=1;next} restoring && /^setup.sh / {exit 1}' "$log" || fail 'rollback invoked setup'
[[ ! -e $tree/var/lib/maya-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful rollback'
pass 'a failed upgrade returns to the previous commit without the network'

: > "$log"
if FAKE_READY=0 MAYA_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade whose model never loaded reported success'
fi
contains 'has not answered' "$tmp_root/out"
contains "Rollback to $next failed too" "$tmp_root/out"
contains 'the snapshot is kept in' "$tmp_root/out"
[[ -s $tree/var/lib/maya-target/rollback-runtime.tar ]] || fail 'a failed rollback removed the snapshot'
pass 'an upgrade is not healthy until /v1/models lists the loaded model; a failed rollback keeps its snapshot'

# A failed upgrade that also changed settings and the unit must come back on
# the previous commit with the previous settings and unit, not the new ones.
: > "$log"
MAYA_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'reset to a healthy install'; }
contains 'MAYA_DRAFT=mtp' "$tree/etc/maya-target/installed-env"
cp "$unit" "$tmp_root/good.service"
cp "$tree/etc/maya-target/installed-settings" "$tmp_root/good-settings"
cp "$deploy/maya.service" "$tmp_root/deploy.service"
printf '# changed by the attempted upgrade\n' >> "$deploy/maya.service"
: > "$log"
if FAKE_BAD_COMMIT=$bad MAYA_COMMIT=$bad MAYA_DRAFT=dflash2 MAYA_PORT=11434 \
        run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade with new settings reported success'
fi
cp "$tmp_root/deploy.service" "$deploy/maya.service"
contains "Maya is running $next again" "$tmp_root/out"
contains 'Restoring the settings it last ran with' "$tmp_root/out"
attempt=$(grep "^setup.sh .*@$bad" "$log" | tail -n1)
rollback=$(grep "^setup.sh .*@$next" "$log" | tail -n1 || true)
[[ $attempt == *'--draft dflash2'* && $attempt == *'--port 11434'* ]] || fail "attempt: $attempt"
[[ -z $rollback ]] || fail "rollback invoked setup: $rollback"
cmp -s "$unit" "$tmp_root/good.service" || fail 'rollback kept the attempted unit'
cmp -s "$tree/etc/maya-target/installed-settings" "$tmp_root/good-settings" || fail 'a failed upgrade changed the record'
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "the rollback was not checked on the recorded port: $(grep '^curl ' "$log" | tail -n1)"
: > "$log"
MAYA_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after rollback'; }
contains 'nothing to do' "$tmp_root/out"   # back exactly where the last good install was
pass 'rollback restores the previous settings and unit, not the ones that failed'

rm -f "$tree/etc/maya-target/installed-env"
: > "$log"
MAYA_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'legacy migration'; }
[[ -f $tree/etc/maya-target/installed-env ]] || fail 'a healthy legacy rerun did not backfill its settings'
grep -q 'systemctl stop' "$log" && fail 'legacy migration stopped the service'
pass 'a healthy legacy rerun backfills rollback records without restarting'

rm -f "$tree/etc/maya-target/installed-env"   # as an install by the earlier script left it
: > "$log"
if FAKE_BAD_COMMIT=$bad MAYA_COMMIT=$bad MAYA_PORT=11434 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains 'No record of the previous settings' "$tmp_root/out"
contains "Maya is running $next again" "$tmp_root/out"
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "a legacy rollback was not checked on the fingerprint's port: $(grep '^curl ' "$log" | tail -n1)"
pass 'an install without a settings record still rolls back, from its runtime snapshot'

reset_tree
out=$(MAYA_NVCC_PATH=$tmp_root/cuda-12.9/bin/nvcc run_target 2>&1) && fail 'a missing nvcc was accepted'
[[ $out == *'cuda-12.9/bin/nvcc is missing'* ]] || fail "nvcc message: $out"
grep -q '^setup.sh ' "$log" && fail 'setup ran without its nvcc'
pass 'setup does not run when the CUDA toolkit it is pointed at is missing'

reset_tree
out=$(FAKE_HELP=$help_keyless run_target 2>&1) && fail 'a checkout without --api-key was installed'
[[ $out == *'does not accept: --api-key'* ]] || fail "keyless help message: $out"
[[ ! -e $tree/etc/systemd/system/maya.service ]] || fail 'unit installed despite the refusal'
grep -q '^setup.sh ' "$log" && fail 'setup ran despite the refusal'
pass 'a checkout without the required options is refused before setup runs'

reset_tree
out=$(FAKE_NO_RUN_SCRIPT=1 run_target 2>&1) && fail 'setup without a launcher was accepted'
[[ $out == *'did not report or write'* ]] || fail "missing launcher message: $out"
[[ ! -e $tree/etc/systemd/system/maya.service ]] || fail 'unit installed without launcher'
pass 'install refuses to start when setup does not generate a launcher'

reset_tree
out=$(FAKE_CUDA_UNAVAILABLE=1 run_target 2>&1) && fail 'an unavailable CUDA version was accepted'
[[ $out == *'CUDA 12.8 is not available for this'* ]] || fail "CUDA preflight message: $out"
grep -qE '^(apt-get|setup.sh|git) ' "$log" && fail 'something was installed or fetched before the CUDA preflight'
pass 'a CUDA version the distro cannot install stops the installer before anything changes'

reset_tree
out=$(FAKE_GROUP=root run_target 2>&1) && fail 'GPU nodes in group root were accepted'
[[ $out == *'gid=44'* ]] || fail "root group message: $out"
pass 'GPU nodes owned by group root are refused with the pct set fix'

reset_tree
mkdir -p "$tree/opt/maya"; touch "$tree/opt/maya/stray"
out=$(run_target 2>&1) && fail 'a non-git /opt/maya was used'
[[ $out == *'is not a Git checkout'* ]] || fail "non-git message: $out"
pass 'a non-empty non-git source directory is refused'

output=$(env -i "PATH=$PATH" bash "$script_dir/install-target.sh" --dry-run 2>&1)
[[ $output == *'the latest vX.Y.Z release tag into /opt/maya'* ]] || fail "dry-run fetch: $output"
[[ $output == *'--draft mtp --nvcc /usr/local/cuda-12.8/bin/nvcc'* ]] || fail "dry-run setup: $output"
[[ $output == *'--api-key [redacted]'* ]] || fail 'dry-run key'
pass 'the dry run shows the release default, --draft and --nvcc'


# Unlike run_target's explicit defaults, this is the documented bare --upgrade.
saved_upgrade() {
    env -i PATH="$bin:$PATH" FAKE_HELP="$help_current" FAKE_TAGS="$release_tags" \
        MAYA_DIR="$tree/opt/maya" MAYA_DATA_DIR="$tree/var/lib/maya" \
        MAYA_ETC_DIR="$tree/etc/maya-target" MAYA_STATE_DIR="$tree/var/lib/maya-target" \
        UNIT_DIR="$tree/etc/systemd/system" MAYA_READY_TIMEOUT=5 \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        MAYA_COMMIT="$(< "$tree/opt/maya/.git/HEAD")" \
        "$@" bash "$target" --upgrade
}
reset_tree
MAYA_PORT=8123 MAYA_MODEL=Maya-S24 MAYA_DRAFT=dflash2 MAYA_CONTEXT=65536 MAYA_NO_VISION=true run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'custom install before saved-settings upgrade'; }
record=$tree/etc/maya-target/installed-env
cp "$record" "$tmp_root/custom-settings"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'bare upgrade with saved settings'; }
cmp -s "$record" "$tmp_root/custom-settings" || fail 'bare upgrade reset saved settings'
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged saved-settings upgrade stopped the service'
pass 'a bare --upgrade preserves custom settings and leaves an unchanged service running'
saved_upgrade MAYA_PORT=8124 > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'saved-settings explicit override'; }
sed 's/^MAYA_PORT=.*/MAYA_PORT=8124/' "$tmp_root/custom-settings" > "$tmp_root/expected-settings"
cmp -s "$record" "$tmp_root/expected-settings" || fail 'an explicit override reset another saved setting'
pass 'an explicit upgrade setting overrides only that saved value'
cp "$record" "$tmp_root/valid-settings"
sed -i 's/^MAYA_PORT=.*/MAYA_PORT=99999/' "$record"
: > "$log"
if saved_upgrade > "$tmp_root/out" 2>&1; then fail 'invalid saved settings were accepted'; fi
contains 'Invalid or incomplete' "$tmp_root/out"
[[ ! -s $log ]] || fail 'invalid saved settings touched the installation'
mv "$tmp_root/valid-settings" "$record"
pass 'invalid saved settings are refused before external commands run'

# Every rerun keeps the installation's settings: a plain rerun (the way the
# README used to document upgrades), an empty value in the environment, and an
# install from before installed-env (its installed-settings fingerprint).
saved_rerun() {
    env -i PATH="$bin:$PATH" FAKE_HELP="$help_current" FAKE_TAGS="$release_tags" \
        MAYA_DIR="$tree/opt/maya" MAYA_DATA_DIR="$tree/var/lib/maya" \
        MAYA_ETC_DIR="$tree/etc/maya-target" MAYA_STATE_DIR="$tree/var/lib/maya-target" \
        UNIT_DIR="$tree/etc/systemd/system" MAYA_READY_TIMEOUT=5 \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        MAYA_COMMIT="$(< "$tree/opt/maya/.git/HEAD")" \
        bash "$target"
}
cp "$record" "$tmp_root/current-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'plain rerun with saved settings'; }
cmp -s "$record" "$tmp_root/current-settings" || fail "a plain rerun reset saved settings: $(tr '\n' ' ' < "$record")"
contains 'nothing to do' "$tmp_root/out"
pass 'a plain rerun (no --upgrade) keeps the saved settings'

: > "$log"
saved_upgrade MAYA_PORT= > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade with an empty port'; }
cmp -s "$record" "$tmp_root/current-settings" || fail 'an empty environment value replaced a saved setting'
contains 'nothing to do' "$tmp_root/out"
pass 'an empty environment value does not override a saved setting'

rm -f "$record"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'legacy upgrade from the fingerprint'; }
contains 'Using the settings recorded in' "$tmp_root/out"
contains 'nothing to do' "$tmp_root/out"
cmp -s "$record" "$tmp_root/current-settings" || fail "a legacy upgrade did not keep (and backfill) its settings: $(tr '\n' ' ' < "$record" 2>/dev/null)"
rm -f "$record"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'legacy plain rerun'; }
cmp -s "$record" "$tmp_root/current-settings" || fail 'a legacy plain rerun did not keep its settings'
pass 'an install from before installed-env keeps the settings in its fingerprint'

rm -f "$record"
cp "$tree/etc/maya-target/installed-settings" "$tmp_root/fingerprint"
sed -i '/^port=/d' "$tree/etc/maya-target/installed-settings"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'an unreadable fingerprint fell back to defaults'; fi
contains 'Cannot read this installation' "$tmp_root/out"
[[ ! -s $log ]] || fail 'an unreadable fingerprint touched the installation'
mv "$tmp_root/fingerprint" "$tree/etc/maya-target/installed-settings"
cp "$tmp_root/current-settings" "$record"
pass 'an unreadable fingerprint is refused before anything runs, unless every setting is given'
(
    unset MAYA_NVCC
    MAYA_ETC_DIR="$tree/etc/maya-target"
    MAYA_CUDA_VERSION=12.9
    saved_settings
    [[ $MAYA_CUDA_VERSION == 12.9 && ! -v MAYA_NVCC ]] || fail 'a changed CUDA version retained the old compiler'
) || fail 'toolkit version override'
pass 'a CUDA version override derives a new default compiler instead of keeping the saved one'



# Lost metadata must not turn a configured target into a fresh installation.
cp "$record" "$tmp_root/recovery-settings"
rm -f "$record" "$tree/etc/maya-target/installed-settings"
for metadata_state in missing dangling; do
    if [[ $metadata_state == dangling ]]; then
        ln -s "$tree/etc/maya-target/missing-fingerprint" "$tree/etc/maya-target/installed-settings"
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
    rm -f "$tree/etc/maya-target/installed-settings"
done
pass 'missing and dangling settings records are refused before a plain rerun or upgrade changes anything'

# Either a checkout or a unit is enough evidence to protect existing settings.
mv "$unit" "$tmp_root/recovery-unit"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'a checkout without metadata was treated as fresh'; fi
contains 'Found an existing' "$tmp_root/out"
[[ ! -s $log ]] || fail 'a checkout without metadata was changed'
mv "$tmp_root/recovery-unit" "$unit"
mv "$tree/opt/maya/.git" "$tmp_root/recovery-git"
# The fixture's runner reads HEAD; use the installer directly for a unit-only target.
if env -i PATH="$bin:$PATH" MAYA_DIR="$tree/opt/maya" \
        MAYA_DATA_DIR="$tree/var/lib/maya" MAYA_ETC_DIR="$tree/etc/maya-target" \
        UNIT_DIR="$tree/etc/systemd/system" bash "$target" > "$tmp_root/out" 2>&1; then
    fail 'a unit without metadata was treated as fresh'
fi
contains 'Found an existing' "$tmp_root/out"
[[ ! -s $log ]] || fail 'a unit without metadata was changed'
mv "$tmp_root/recovery-git" "$tree/opt/maya/.git"
pass 'an existing checkout or unit is protected independently of the settings records'

# Recovery is possible only with every non-empty setting supplied explicitly.
mapfile -t recovery_settings < "$tmp_root/recovery-settings"
saved_upgrade "${recovery_settings[@]}" > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'explicit recovery from missing metadata'; }
cmp -s "$record" "$tmp_root/recovery-settings" || fail 'explicit recovery changed a setting'
[[ -s $tree/etc/maya-target/installed-settings ]] || fail 'explicit recovery did not recreate the fingerprint'
pass 'complete explicit settings recover lost metadata without resetting custom values'


# A first install that stops part-way leaves a checkout but no settings record.
# A rerun resumes with the settings it was started with (pending-env, written
# before the first change), never with the defaults, and drops it on success.
reset_tree
pbad=fedcba9876543210fedcba9876543210fedcba98
if FAKE_BAD_COMMIT=$pbad MAYA_COMMIT=$pbad MAYA_PORT=8123 MAYA_DRAFT=dflash2 MAYA_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a first install whose setup fails reported success'
fi
pending=$tree/etc/maya-target/pending-env
[[ -f $pending && ! -e $record ]] || fail 'an interrupted first install left no pending-env, or a settings record'
[[ $(stat -c %a "$pending") == 600 ]] || fail 'pending-env is not root-only'
contains 'MAYA_PORT=8123' "$pending"
cp "$pending" "$tmp_root/started-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming the interrupted install'; }
contains 'Resuming an interrupted install' "$tmp_root/out"
cmp -s "$record" "$tmp_root/started-settings" ||
    fail "the resumed install did not keep its settings: $(tr '\n' ' ' < "$record")"
[[ ! -e $pending ]] || fail 'pending-env was left after a successful install'
pass 'an interrupted first install resumes with the settings it was started with'

# Interrupt promotion between its two renames. installed-env is published
# first and the fingerprint last, so the settings are complete and only the
# "nothing to do" marker is missing; pending-env stays until both are in place.
reset_tree
if FAKE_METADATA_FAIL=1 MAYA_PORT=8123 MAYA_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed fingerprint rename reported success'
fi
[[ -f $pending && -s $record && ! -e $tree/etc/maya-target/installed-settings ]] ||
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
