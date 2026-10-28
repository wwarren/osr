#!/usr/bin/env bash
# Exercise install-target.sh: the setup.sh --help parsing helpers against two
# real-world help layouts (the documented options, and a checkout that lacks
# --host/--api-key/--data-dir), then whole-script runs against a temporary tree
# with stubbed git, setup.sh, systemctl, curl and account tools. Nothing is
# downloaded, installed or started.
# The STRATA_* and SETUP_HELP assignments below are read by the sourced helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target=$script_dir/install-target.sh
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/strata-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/strata-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# Two help layouts. "documented" follows docs/INSTALL.md; "minimal" is a
# setup.py whose argparse lacks the network and storage options.
help_documented=$tmp_root/help-documented
cat > "$help_documented" <<'HELP'
usage: setup.py [-h] [--family {qwen,swift,coder}] [--model MODEL] [--context CONTEXT]
                [--vision {yes,no,none,gpu,cpu}] [--host HOST] [--port PORT]
                [--api-key API_KEY] [--data-dir DATA_DIR] [--yes] [--setup]
                [--no-start] [--no-browser] [--check]
options:
  --family {qwen,swift,coder}
  --host HOST           address to listen on
  --api-key API_KEY     require this key
  --data-dir DATA_DIR   keep model files elsewhere
  --no-browser          do not open a browser
HELP
help_minimal=$tmp_root/help-minimal
cat > "$help_minimal" <<'HELP'
usage: setup.py [-h] [--family {qwen,swift}] [--model {Q2_0,IQ2_XS,IQ3_XXS,IQ3_S}]
                [--context CONTEXT] [--vision {yes,no,none,gpu,cpu}] [--port PORT]
                [--models-dir MODELS_DIR] [--gguf-dir GGUF_DIR] [--yes] [--setup]
                [--no-start] [--build] [--prebuilt PREBUILT] [--check]
options:
  --family {qwen,swift}
                        qwen = Qwen3.8-Flash-Next, swift = Swift 1.5
  --models-dir MODELS_DIR
                        where the GGUF files go (~70 GB)
  --no-start            install only, do not start the model
HELP

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$target")
for helper in help_has help_choices check_choice validate_setup_options setup_args select_run_script start_env \
              validate_settings settings_env load_settings fingerprint_env saved_settings; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done
STRATA_FAMILY=qwen STRATA_MODEL=IQ2_XS STRATA_CONTEXT=32768 STRATA_VISION=no
STRATA_PORT=8080 STRATA_DATA_DIR=/var/lib/strata STRATA_ALLOW_NO_KEY=false

SETUP_HELP=$(< "$help_documented")
help_has --host && help_has --api-key && help_has --no-start && help_has --data-dir || fail 'documented flags'
! help_has --models-dir && ! help_has --hos && ! help_has --api || fail 'partial flag names matched'
[[ $(help_choices --family) == 'qwen swift coder' ]] || fail "family choices: $(help_choices --family)"
[[ -z $(help_choices --model) ]] || fail 'free-form --model has no choices'
(validate_setup_options) || fail 'documented help rejected'
args=$(setup_args | tr '\n' ' ')
[[ $args == '--setup --no-start --yes --no-browser --family qwen --model IQ2_XS --context 32768 --vision no --host 0.0.0.0 --port 8080 --data-dir /var/lib/strata ' ]] ||
    fail "setup args: $args"
[[ $(setup_args) != *api-key* ]] || fail 'the key must never be in the args'
pass 'documented setup.sh options are used'

SETUP_HELP=$(< "$help_minimal")
[[ $(help_choices --model) == 'Q2_0 IQ2_XS IQ3_XXS IQ3_S' ]] || fail 'model choices'
out=$( (validate_setup_options) 2>&1 ) && fail 'a checkout without --host/--api-key was accepted'
[[ $out == *'does not accept: --host --api-key'* ]] || fail "missing-flag message: $out"
STRATA_ALLOW_NO_KEY=true
out=$( (validate_setup_options) 2>&1 ) && fail 'a checkout without --host was accepted'
[[ $out == *'does not accept: --host.'* ]] || fail "host message: $out"
STRATA_ALLOW_NO_KEY=false
[[ $(setup_args | tr '\n' ' ') == *'--models-dir /var/lib/strata/models '* ]] || fail 'models-dir fallback'
[[ $(setup_args) != *--no-browser* && $(setup_args) != *--data-dir* ]] || fail 'unsupported options passed'
pass 'unsupported options are refused or left out'

SETUP_HELP=$(< "$help_minimal" sed 's/\[--port PORT\]/[--port PORT] [--host HOST] [--api-key KEY]/')
STRATA_FAMILY=coder
out=$( (validate_setup_options) 2>&1 ) && fail 'family outside the listed choices was accepted'
[[ $out == *'does not accept --family coder (it offers: qwen swift)'* ]] || fail "choice message: $out"
STRATA_FAMILY=qwen STRATA_MODEL=IQ1_M
out=$( (validate_setup_options) 2>&1 ) && fail 'model outside the listed choices was accepted'
STRATA_MODEL=IQ2_XS
(validate_setup_options) || fail 'valid choices rejected'
pass 'family, model and vision are checked against the listed choices'

STRATA_DIR=$tmp_root/strata; mkdir -p "$STRATA_DIR"
printf '#!/bin/sh\nexit 0\n' > "$STRATA_DIR/run-iq2_xs.sh"
chmod +x "$STRATA_DIR/run-iq2_xs.sh"
printf '  [ok] start script: run-iq2_xs.sh\n' > "$tmp_root/setup.log"
select_run_script "$tmp_root/setup.log"
[[ $(start_env | tail -n1) == "STRATA_RUN_SCRIPT=$STRATA_DIR/run-iq2_xs.sh" ]] || fail 'generated launcher not selected'
out=$( (printf '  [ok] start script: run-missing.sh\n' > "$tmp_root/setup.log"; select_run_script "$tmp_root/setup.log") 2>&1) && fail 'missing launcher accepted'
[[ $out == *'did not generate an executable'* ]] || fail "missing launcher message: $out"
pass 'the generated executable launcher is required for the unit'

# Setup that does not name its launcher: the one run-*.sh written after the
# marker is used; several fresh ones are refused.
marker=$tmp_root/marker; touch -d '@1000000000' "$marker"
touch -d '@999999999' "$STRATA_DIR/run-iq2_xs.sh"            # older than the marker
printf '#!/bin/sh\n' > "$STRATA_DIR/run-swift-iq2_xs.sh"; chmod +x "$STRATA_DIR/run-swift-iq2_xs.sh"
printf 'setup finished\n' > "$tmp_root/setup.log"
out=$(select_run_script "$tmp_root/setup.log" "$marker" 2>&1; start_env | tail -n1)
[[ $out == *'did not name its start script; using run-swift-iq2_xs.sh'* ]] || fail "fallback note: $out"
[[ $out == *"STRATA_RUN_SCRIPT=$STRATA_DIR/run-swift-iq2_xs.sh" ]] || fail "fallback launcher: $out"
touch "$STRATA_DIR/run-iq2_xs.sh"                              # now two are fresh
out=$( (select_run_script "$tmp_root/setup.log" "$marker") 2>&1) && fail 'two fresh launchers accepted'
[[ $out == *'wrote several run scripts'* ]] || fail "ambiguous message: $out"
rm -f "$STRATA_DIR"/run-*.sh
out=$( (select_run_script "$tmp_root/setup.log" "$marker") 2>&1) && fail 'no launcher accepted'
[[ $out == *'did not report or write'* ]] || fail "no launcher message: $out"
pass 'an unnamed launcher falls back to the one setup just wrote, never a guess'

# The settings record a rollback restores: KEY=value, read back
# all-or-nothing, never sourced.
STRATA_FAMILY=qwen STRATA_MODEL=IQ2_XS STRATA_CONTEXT=32768 STRATA_VISION=no STRATA_PORT=8080
settings_env > "$tmp_root/installed-env"
[[ $(grep -c '^STRATA_' "$tmp_root/installed-env") == 6 ]] || fail "settings record: $(cat "$tmp_root/installed-env")"
STRATA_MODEL=IQ3_S STRATA_PORT=11434
load_settings "$tmp_root/installed-env" || fail 'a valid record was not loaded'
[[ $STRATA_MODEL == IQ2_XS && $STRATA_PORT == 8080 ]] || fail "record not restored: $STRATA_MODEL $STRATA_PORT"
sed 's/^STRATA_VISION=.*/STRATA_VISION=maybe/' "$tmp_root/installed-env" > "$tmp_root/bad-env"
STRATA_PORT=11434
load_settings "$tmp_root/bad-env" && fail 'an invalid record was loaded'
[[ $STRATA_PORT == 11434 ]] || fail 'an invalid record changed a setting'
printf 'STRATA_PORT=8080; touch %s/pwned\n' "$tmp_root" > "$tmp_root/evil-env"
load_settings "$tmp_root/evil-env" && fail 'a malformed record was loaded'
[[ ! -e $tmp_root/pwned ]] || fail 'the record was executed'
STRATA_PORT=8080
pass 'the settings record is read back all-or-nothing and never executed'

# Exercise the GPU access decision without root or Proxmox. A root-group node
# is accepted only when the service user can actually read and write it.
# shellcheck disable=SC1090
source <(awk '/^ensure_service_user\(\) \{/ { capture=1 } capture { print } capture && /^}/ { exit }' "$target")
mkdir -p "$tmp_root/dev"; touch "$tmp_root/dev/nvidia0"
gpu_access_case() (
    local fake_gid=$1 fake_access=$2 fake_smi=$3
    SERVICE_USER=strata GPU_NODES="$tmp_root/dev/nvidia0"
    getent() { return 0; }
    id() { return 0; }
    stat() { [[ $2 == %g ]] && printf '%s\n' "$fake_gid" || printf '%s\n' video; }
    usermod() { printf 'joined %s\n' "$2"; }
    as_service() {
        case $1 in
            test) [[ $fake_access == yes ]] ;;
            nvidia-smi) [[ $fake_smi == yes ]] ;;
            *) return 1 ;;
        esac
    }
    note() { printf '%s\n' "$*"; }
    ensure_service_user
)
out=$(gpu_access_case 0 yes yes) || fail 'accessible root-group GPU node was rejected'
[[ $out == *'group root'* && $out != *'joined'* ]] || fail "root-group access decision: $out"
out=$(gpu_access_case 0 no yes 2>&1) && fail 'inaccessible root-group GPU node was accepted'
[[ $out == *'gid=44,mode=0660'* ]] || fail "root-group repair message: $out"
out=$(gpu_access_case 44 yes yes) || fail 'video-group GPU node was rejected'
[[ $out == *'joined video'* ]] || fail "video-group membership: $out"
out=$(gpu_access_case 44 yes no 2>&1) && fail 'service-user nvidia-smi failure was ignored'
[[ $out == *'cannot use the NVIDIA GPU'* ]] || fail "GPU probe message: $out"
pass 'GPU access is checked as the service user without joining group root'

# A checkout can need a locally compiled engine. Upstream setup runs as an
# unprivileged user, so the target installs only NVIDIA's versioned toolkit
# package as root and retries setup once.
# shellcheck disable=SC1090
source <(awk '/^cuda_toolkit_target\(\)/ { capture=1 } /^# Serialize real runs/ { capture=0 } capture { print }' "$target")
printf 'ID=debian\nVERSION_ID=13\n' > "$tmp_root/os-release"
[[ $(STRATA_OS_RELEASE="$tmp_root/os-release" cuda_toolkit_target) == 'debian13 13.1' ]] || fail 'Debian 13 CUDA version'
printf 'ID=debian\nVERSION_ID=12\n' > "$tmp_root/os-release-12"
[[ $(STRATA_OS_RELEASE="$tmp_root/os-release-12" cuda_toolkit_target) == 'debian12 13.0' ]] || fail 'Debian 12 CUDA version'
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$tmp_root/os-release-ubuntu"
[[ $(STRATA_OS_RELEASE="$tmp_root/os-release-ubuntu" cuda_toolkit_target) == 'ubuntu2404 13.0' ]] || fail 'Ubuntu 24.04 CUDA version'
cat > "$tmp_root/nvcc" <<'NVCC'
#!/bin/sh
echo 'Cuda compilation tools, release 13.1, V13.1.80'
NVCC
chmod +x "$tmp_root/nvcc"
out=$(
    STRATA_OS_RELEASE="$tmp_root/os-release" STRATA_NVCC="$tmp_root/nvcc" TMPDIR="$tmp_root" SERVICE_USER=strata
    note() { printf '%s\n' "$*"; }
    apt-get() { printf 'apt-get %s\n' "$*"; }
    apt-cache() { printf 'apt-cache %s\n' "$*"; }
    curl() {
        printf 'curl %s\n' "$*"
        while (( $# )); do
            if [[ $1 == -o ]]; then : > "$2"; break; fi
            shift
        done
    }
    dpkg() { printf 'dpkg %s\n' "$*"; }
    as_service() { [[ $1 == nvidia-smi && $2 == -L ]]; }
    install_cuda_toolkit
) || fail 'CUDA toolkit installer failed against its command stubs'
[[ $out == *'repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb'* ]] || fail "CUDA repo URL: $out"
[[ $out == *'apt-get install -y cuda-toolkit-13-1'* ]] || fail "CUDA package choice: $out"
[[ $out != *'apt-get install -y cuda '* && $out != *'cuda-drivers'* ]] || fail 'CUDA installer selected a driver package'
pass 'CUDA install selects NVIDIA toolkit 13.1 without a driver package'

SETUP_HELP=$(< "$help_documented")
STRATA_DIR=$tmp_root/retry/strata
STRATA_ETC_DIR=$tmp_root/retry/etc
mkdir -p "$STRATA_DIR" "$STRATA_ETC_DIR"
api_key=test-key
cat > "$STRATA_DIR/setup.sh" <<'SETUP'
#!/bin/bash
if [[ ! -e .attempted ]]; then
    touch .attempted
    echo '[X] the CUDA Toolkit can be installed automatically on Ubuntu 22.04 / 24.04 only'
    exit 1
fi
printf '#!/bin/sh\nexit 0\n' > run-iq2_xs.sh
chmod +x run-iq2_xs.sh
echo '  [ok] start script: run-iq2_xs.sh'
SETUP
out=$(
    note() { printf '%s\n' "$*"; }
    as_service() { "$@"; }
    cuda_toolkit_target() { printf 'debian13 13.1\n'; }
    install_cuda_toolkit() { touch "$tmp_root/retry/cuda-installed"; }
    run_setup
    start_env | tail -n1
) || fail 'setup did not resume after installing the Debian toolkit'
[[ -f $tmp_root/retry/cuda-installed && $out == *"STRATA_RUN_SCRIPT=$STRATA_DIR/run-iq2_xs.sh"* ]] ||
    fail "CUDA retry or launcher selection failed: $out"
pass 'setup retries once after the Debian CUDA failure and selects its launcher'

rm -f "$STRATA_DIR/.attempted" "$tmp_root/retry/cuda-installed"
sed -i "s@echo '\[X\] the CUDA Toolkit can be installed automatically on Ubuntu 22.04 / 24.04 only'@sudo dpkg -i /tmp/cuda-keyring.deb@" "$STRATA_DIR/setup.sh"
out=$(
    note() { printf '%s\n' "$*"; }
    as_service() { "$@"; }
    cuda_toolkit_target() { printf 'ubuntu2404 13.0\n'; }
    install_cuda_toolkit() { touch "$tmp_root/retry/cuda-installed"; }
    run_setup
) || fail 'setup did not resume after an unprivileged sudo prompt'
[[ -f $tmp_root/retry/cuda-installed ]] || fail 'the sudo prompt did not trigger a root CUDA install'
[[ $out == *'strata-target: upstream setup requested sudo'* ]] || fail 'upstream setup reached sudo without the guard'
pass 'Ubuntu sudo password prompts trigger the root toolkit install and one retry'

# --- whole-script runs --------------------------------------------------------
# From a copy, so a case can ship a changed unit for one attempted upgrade.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
cp "$script_dir/install-target.sh" "$script_dir/strata.service" "$deploy/"
target=$deploy/install-target.sh
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub getent 'exit 2'   # no strata group yet, so it is created
stub mv 'if [[ ${FAKE_METADATA_FAIL:-0} == 1 && ${*: -1} == */installed-settings ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
stub openssl 'if [[ ${FAKE_KEY_FAIL:-0} == 1 ]]; then printf "partial"; exit 1; fi; exec /usr/bin/openssl "$@"'
for command_name in apt-get groupadd useradd usermod chown sleep nvidia-smi; do stub "$command_name" 'exit 0'; done
stub stat 'case $2 in %g) [[ ${FAKE_GROUP:-video} == root ]] && echo 0 || echo 44;; %G) echo "${FAKE_GROUP:-video}";; *) exec /usr/bin/stat "$@";; esac'
stub test 'if [[ ${FAKE_GROUP:-video} == root && ( $1 == -r || $1 == -w ) ]]; then exit 1; fi; exec /usr/bin/test "$@"'
stub systemctl 'case "$1" in is-failed) exit 1;; is-active) exit "${FAKE_INACTIVE:-0}";; esac; exit 0'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
# install: drop -o/-g (the strata account does not exist here).
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
# /health returns 200 while loading too; only loaded=true is ready.
stub curl 'if [[ ${FAKE_READY:-1} == 1 ]]; then printf '\''{"status":"ok","loaded":true,"service":"strata"}\n'\''; else printf '\''{"status":"ok","loaded":false,"service":"strata"}\n'\''; fi'
# git: a fake shallow checkout. Names resolve to a fixed hash; commits that were
# fetched or pinned with update-ref are "local" and can be checked out offline.
# FAKE_FETCH_FAIL=1 makes every fetch fail (no network).
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
        cp "$tmp_root/setup.sh" "\$dir/setup.sh" ;;
    rev-parse) if [[ \$2 == FETCH_HEAD ]]; then cat "\$dir/.git/FETCH"; else cat "\$dir/.git/HEAD"; fi ;;
esac
STUB
chmod +x "$bin/git"
# setup.sh: prints FAKE_HELP for --help; otherwise records its arguments and
# fails when the checkout is FAKE_BAD_COMMIT.
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
    printf '#!/bin/sh\nexit 0\n' > run-iq2_xs.sh
    chmod +x run-iq2_xs.sh
fi
[[ \${FAKE_NO_START_LINE:-0} == 1 ]] || echo '  [ok] start script: run-iq2_xs.sh'
STUB

tree=$tmp_root/tree
dev=$tmp_root/dev
reset_tree() {
    rm -rf "$tree" "$dev"; mkdir -p "$tree/etc/systemd/system" "$dev"
    touch "$dev/nvidia0" "$dev/nvidiactl" "$dev/nvidia-uvm"
    : > "$log"
}
run_target() {
    env PATH="$bin:$PATH" FAKE_HELP="${FAKE_HELP:-$help_documented}" \
        STRATA_DIR="$tree/opt/strata" STRATA_DATA_DIR="$tree/var/lib/strata" \
        STRATA_ETC_DIR="$tree/etc/strata-target" STRATA_STATE_DIR="$tree/var/lib/strata-target" UNIT_DIR="$tree/etc/systemd/system" \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" STRATA_READY_TIMEOUT=5 \
        STRATA_COMMIT="${STRATA_COMMIT-}" STRATA_PORT="${STRATA_PORT:-8080}" \
        bash "$target" "$@"
}
contains() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }

reset_tree
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
unit=$tree/etc/systemd/system/strata.service
cmp -s "$unit" "$script_dir/strata.service" || fail 'unit not installed'
contains "STRATA_RUN_SCRIPT=$tree/opt/strata/run-iq2_xs.sh" "$tree/etc/strata-target/strata.env"
contains 'ExecStart=/bin/sh ${STRATA_RUN_SCRIPT}' "$unit"
key=$(< "$tree/etc/strata-target/api-key")
[[ $key =~ ^[0-9a-f]{64}$ ]] || fail 'no generated key'
[[ $(stat -c %a "$tree/etc/strata-target/api-key") == 600 ]] || fail 'key file mode'
contains "--setup --no-start --yes" "$log"
contains "--api-key $key" "$log"
contains 'usermod -aG video strata' "$log"
contains 'curl -fsS --max-time 5 http://127.0.0.1:8080/health' "$log"
contains 'systemctl enable strata.service' "$log"
grep -q -- "$key" "$tmp_root/out" && fail 'the key was printed'
grep -q -- "$key" "$tree/etc/strata-target/strata.env" && fail 'the key is in the unit environment'
pass 'fresh install as the strata account, key kept out of logs and the unit'

: > "$log"
new_main=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FAKE_MAIN_COMMIT=$new_main run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun update'; }
[[ $(< "$tree/opt/strata/.git/HEAD") == "$new_main" ]] || fail 'rerun did not move to latest main'
contains 'fetch -q --depth 1 origin main' "$log"
contains 'systemctl stop strata.service' "$log"
[[ $(< "$tree/etc/strata-target/api-key") == "$key" ]] || fail 'rerun replaced the key'
pass 're-running fetches latest main with upgrade rollback and preserves the key'

commit=0123456789abcdef0123456789abcdef01234567
STRATA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'pinned rerun'; }
[[ $(< "$tree/opt/strata/.git/HEAD") == "$commit" ]] || fail 'pinned rerun did not move HEAD'
contains "fetch -q --depth 1 origin $commit" "$log"
pass 'an explicit commit pin is honored on a normal rerun'

: > "$log"
STRATA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'no-op rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged rerun stopped the service'
grep -q '^setup.sh ' "$log" && fail 'an unchanged rerun re-ran setup'
contains "fetch -q --depth 1 origin $commit" "$log"
pass 'an unchanged, healthy install is left running'

: > "$log"
FAKE_INACTIVE=3 STRATA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'inactive rerun'; }
contains 'Re-applying Strata' "$tmp_root/out"
contains 'systemctl restart strata.service' "$log"
pass 'a stopped service is brought back on a rerun even when nothing changed'

: > "$log"
STRATA_PORT=11434 STRATA_COMMIT=$commit run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'settings rerun'; }
contains 'Re-applying Strata' "$tmp_root/out"
contains '--port 11434' "$log"
contains 'systemctl stop strata.service' "$log"
pass 'changed settings on the same commit re-run setup'

: > "$log"
before=$(< "$tree/opt/strata/.git/HEAD")
if FAKE_FETCH_FAIL=1 STRATA_COMMIT=123456789abcdef0123456789abcdef012345678 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade without network reported success'
fi
contains 'was not stopped or changed' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'a failed fetch stopped the service'
[[ $(< "$tree/opt/strata/.git/HEAD") == "$before" ]] || fail 'a failed fetch moved the checkout'
pass 'a failed fetch leaves the running service untouched'

: > "$log"
next=123456789abcdef0123456789abcdef012345678
printf 'legacy\n' > "$tree/etc/strata-target/rollback-runtime.tar"; printf 'legacy\n' > "$tree/etc/strata-target/rollback.env"
STRATA_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade'; }
[[ ! -e $tree/var/lib/strata-target/rollback-runtime.tar && ! -e $tree/var/lib/strata-target/rollback.env ]] || fail 'the snapshot was kept after a successful upgrade'
[[ ! -e $tree/etc/strata-target/rollback-runtime.tar && ! -e $tree/etc/strata-target/rollback.env ]] || fail 'a snapshot left in /etc by an earlier revision was not removed'
[[ ! -e $tree/etc/strata-target/installed.service ]] || fail 'the unused installed.service record was written'
[[ $(stat -c %a "$tree/var/lib/strata-target") == 700 ]] || fail 'the snapshot directory is not root-only'
[[ $(< "$tree/opt/strata/.git/HEAD") == "$next" ]] || fail 'upgrade did not move HEAD'
contains "fetch -q --depth 1 origin $next" "$log"
contains 'systemctl stop strata.service' "$log"
contains "@$next" "$log"
pass '--upgrade fetches the pinned commit (not only a branch tip) and re-runs setup'

mkdir -p "$tree/opt/strata/.venv"
printf 'previous runtime\n' > "$tree/opt/strata/.venv/rollback-marker"
bad=fedcba9876543210fedcba9876543210fedcba98
: > "$log"
if FAKE_BAD_COMMIT=$bad STRATA_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains "Strata is running $next again" "$tmp_root/out"
[[ $(< "$tree/opt/strata/.git/HEAD") == "$next" ]] || fail 'rollback did not restore HEAD'
grep -q "^setup.sh .*@$next" "$log" && fail 'rollback ran setup'
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] || fail 'rollback fetched again instead of using the local commit'
contains "update-ref refs/strata/previous $next" "$log"
[[ $(cat "$tree/opt/strata/.venv/rollback-marker") == 'previous runtime' ]] || fail 'venv not restored'
[[ ! -e $tree/opt/strata/runtime-from-failed-upgrade ]] || fail 'failed runtime file survived'
awk '/^git .* reset / {restoring=1;next} restoring && /^setup.sh / {exit 1}' "$log" || fail 'rollback invoked setup'
[[ ! -e $tree/var/lib/strata-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful rollback'
pass 'a failed upgrade returns to the previous commit without the network'

# A failed upgrade that also changed settings and the unit must come back on
# the previous commit with the previous settings and unit.
: > "$log"
STRATA_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'healthy install before the attempt'; }
contains 'STRATA_MODEL=IQ2_XS' "$tree/etc/strata-target/installed-env"
cp "$unit" "$tmp_root/good.service"
cp "$tree/etc/strata-target/installed-settings" "$tmp_root/good-settings"
printf '# changed by the attempted upgrade\n' >> "$deploy/strata.service"
: > "$log"
if FAKE_BAD_COMMIT=$bad STRATA_COMMIT=$bad STRATA_MODEL=IQ3_S STRATA_PORT=11434 \
        run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade with new settings reported success'
fi
cp "$script_dir/strata.service" "$deploy/strata.service"
contains "Strata is running $next again" "$tmp_root/out"
contains 'Restoring the settings it last ran with' "$tmp_root/out"
attempt=$(grep "^setup.sh .*@$bad" "$log" | tail -n1)
rollback=$(grep "^setup.sh .*@$next" "$log" | tail -n1 || true)
[[ $attempt == *'--model IQ3_S'* && $attempt == *'--port 11434'* ]] || fail "attempt: $attempt"
[[ -z $rollback ]] || fail "rollback invoked setup: $rollback"
cmp -s "$unit" "$tmp_root/good.service" || fail 'rollback kept the attempted unit'
cmp -s "$tree/etc/strata-target/installed-settings" "$tmp_root/good-settings" || fail 'a failed upgrade changed the record'
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "the rollback was not checked on the recorded port: $(grep '^curl ' "$log" | tail -n1)"
: > "$log"
STRATA_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after rollback'; }
contains 'nothing to do' "$tmp_root/out"
pass 'rollback restores the previous settings and unit, not the ones that failed'

rm -f "$tree/etc/strata-target/installed-env"
: > "$log"
STRATA_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'legacy migration'; }
[[ -f $tree/etc/strata-target/installed-env ]] || fail 'a healthy legacy rerun did not backfill its settings'
grep -q 'systemctl stop' "$log" && fail 'legacy migration stopped the service'
pass 'a healthy legacy rerun backfills rollback records without restarting'

rm -f "$tree/etc/strata-target/installed-env"
: > "$log"
if FAKE_BAD_COMMIT=$bad STRATA_COMMIT=$bad STRATA_PORT=11434 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains 'No record of the previous settings' "$tmp_root/out"
contains "Strata is running $next again" "$tmp_root/out"
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "a legacy rollback was not checked on the fingerprint's port: $(grep '^curl ' "$log" | tail -n1)"
pass 'an install without a settings record still rolls back, from its runtime snapshot'

: > "$log"
if FAKE_READY=0 FAKE_BAD_COMMIT=$bad STRATA_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade and rollback that never became healthy reported success'
fi
contains "Rollback to $next failed too" "$tmp_root/out"
contains 'the snapshot is kept in' "$tmp_root/out"
[[ -s $tree/var/lib/strata-target/rollback-runtime.tar ]] || fail 'a failed rollback removed the snapshot'
pass 'a rollback that does not become healthy is reported, and its snapshot kept'

reset_tree
out=$(FAKE_HELP=$help_minimal run_target 2>&1) && fail 'a checkout without --host/--api-key was installed'
[[ $out == *'does not accept: --host --api-key'* ]] || fail "minimal help message: $out"
[[ ! -e $tree/etc/systemd/system/strata.service ]] || fail 'unit installed despite the refusal'
grep -q '^setup.sh ' "$log" && fail 'setup ran despite the refusal'
pass 'a checkout without the required options is refused before setup runs'

reset_tree
out=$(FAKE_NO_RUN_SCRIPT=1 run_target 2>&1) && fail 'setup without a generated launcher was accepted'
[[ $out == *'did not generate an executable'* ]] || fail "missing launcher message: $out"
[[ ! -e $tree/etc/systemd/system/strata.service ]] || fail 'unit installed without launcher'
pass 'install refuses to start when setup does not generate a launcher'

reset_tree
FAKE_NO_START_LINE=1 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'unnamed launcher install'; }
contains 'did not name its start script; using run-iq2_xs.sh' "$tmp_root/out"
contains "STRATA_RUN_SCRIPT=$tree/opt/strata/run-iq2_xs.sh" "$tree/etc/strata-target/strata.env"
pass 'an install whose setup does not name the launcher uses the one it wrote'

reset_tree
out=$(FAKE_GROUP=root run_target 2>&1) && fail 'GPU nodes in group root were accepted'
[[ $out == *'gid=44'* ]] || fail "root group message: $out"
pass 'GPU nodes owned by group root are refused with the pct set fix'

reset_tree
mkdir -p "$tree/opt/strata"; touch "$tree/opt/strata/stray"
out=$(run_target 2>&1) && fail 'a non-git /opt/strata was used'
[[ $out == *'is not a Git checkout'* ]] || fail "non-git message: $out"
pass 'a non-empty non-git source directory is refused'


# Unlike run_target's explicit defaults, this is the documented bare --upgrade.
saved_upgrade() {
    env -i PATH="$bin:$PATH" FAKE_HELP="$help_documented" \
        STRATA_DIR="$tree/opt/strata" STRATA_DATA_DIR="$tree/var/lib/strata" \
        STRATA_ETC_DIR="$tree/etc/strata-target" STRATA_STATE_DIR="$tree/var/lib/strata-target" \
        UNIT_DIR="$tree/etc/systemd/system" STRATA_READY_TIMEOUT=5 \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        STRATA_COMMIT="$(< "$tree/opt/strata/.git/HEAD")" \
        "$@" bash "$target" --upgrade
}
reset_tree
STRATA_PORT=8123 STRATA_MODEL=IQ3_S STRATA_CONTEXT=65536 STRATA_VISION=yes run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'custom install before saved-settings upgrade'; }
record=$tree/etc/strata-target/installed-env
cp "$record" "$tmp_root/custom-settings"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'bare upgrade with saved settings'; }
cmp -s "$record" "$tmp_root/custom-settings" || fail 'bare upgrade reset saved settings'
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged saved-settings upgrade stopped the service'
pass 'a bare --upgrade preserves custom settings and leaves an unchanged service running'
saved_upgrade STRATA_PORT=8124 > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'saved-settings explicit override'; }
sed 's/^STRATA_PORT=.*/STRATA_PORT=8124/' "$tmp_root/custom-settings" > "$tmp_root/expected-settings"
cmp -s "$record" "$tmp_root/expected-settings" || fail 'an explicit override reset another saved setting'
pass 'an explicit upgrade setting overrides only that saved value'
cp "$record" "$tmp_root/valid-settings"
sed -i 's/^STRATA_PORT=.*/STRATA_PORT=99999/' "$record"
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
    env -i PATH="$bin:$PATH" FAKE_HELP="$help_documented" \
        STRATA_DIR="$tree/opt/strata" STRATA_DATA_DIR="$tree/var/lib/strata" \
        STRATA_ETC_DIR="$tree/etc/strata-target" STRATA_STATE_DIR="$tree/var/lib/strata-target" \
        UNIT_DIR="$tree/etc/systemd/system" STRATA_READY_TIMEOUT=5 \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        STRATA_COMMIT="$(< "$tree/opt/strata/.git/HEAD")" \
        bash "$target"
}
cp "$record" "$tmp_root/current-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'plain rerun with saved settings'; }
cmp -s "$record" "$tmp_root/current-settings" || fail "a plain rerun reset saved settings: $(tr '\n' ' ' < "$record")"
contains 'nothing to do' "$tmp_root/out"
pass 'a plain rerun (no --upgrade) keeps the saved settings'

: > "$log"
saved_upgrade STRATA_PORT= > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade with an empty port'; }
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
cp "$tree/etc/strata-target/installed-settings" "$tmp_root/fingerprint"
sed -i '/^port=/d' "$tree/etc/strata-target/installed-settings"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'an unreadable fingerprint fell back to defaults'; fi
contains 'Cannot read this installation' "$tmp_root/out"
[[ ! -s $log ]] || fail 'an unreadable fingerprint touched the installation'
mv "$tmp_root/fingerprint" "$tree/etc/strata-target/installed-settings"
cp "$tmp_root/current-settings" "$record"
pass 'an unreadable fingerprint is refused before anything runs, unless every setting is given'

reset_tree
STRATA_FAMILY=coder STRATA_PORT=8123 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'coder install'; }
contains 'STRATA_MODEL=IQ1_M' "$record"
saved_upgrade STRATA_FAMILY=qwen > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'family change'; }
contains 'STRATA_FAMILY=qwen' "$record"
contains 'STRATA_MODEL=IQ2_XS' "$record"
contains 'STRATA_PORT=8123' "$record"
saved_upgrade STRATA_FAMILY=coder STRATA_MODEL=IQ1_M > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'family and model change'; }
contains 'STRATA_MODEL=IQ1_M' "$record"
pass 'a family override takes that family default model unless a model is given; other saved settings stay'


# Lost metadata must not turn a configured target into a fresh installation.
cp "$record" "$tmp_root/recovery-settings"
rm -f "$record" "$tree/etc/strata-target/installed-settings"
for metadata_state in missing dangling; do
    if [[ $metadata_state == dangling ]]; then
        ln -s "$tree/etc/strata-target/missing-fingerprint" "$tree/etc/strata-target/installed-settings"
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
    rm -f "$tree/etc/strata-target/installed-settings"
done
pass 'missing and dangling settings records are refused before a plain rerun or upgrade changes anything'

# Either a checkout or a unit is enough evidence to protect existing settings.
mv "$unit" "$tmp_root/recovery-unit"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'a checkout without metadata was treated as fresh'; fi
contains 'Found an existing' "$tmp_root/out"
[[ ! -s $log ]] || fail 'a checkout without metadata was changed'
mv "$tmp_root/recovery-unit" "$unit"
mv "$tree/opt/strata/.git" "$tmp_root/recovery-git"
# The fixture's runner reads HEAD; use the installer directly for a unit-only target.
if env -i PATH="$bin:$PATH" STRATA_DIR="$tree/opt/strata" \
        STRATA_DATA_DIR="$tree/var/lib/strata" STRATA_ETC_DIR="$tree/etc/strata-target" \
        UNIT_DIR="$tree/etc/systemd/system" bash "$target" > "$tmp_root/out" 2>&1; then
    fail 'a unit without metadata was treated as fresh'
fi
contains 'Found an existing' "$tmp_root/out"
[[ ! -s $log ]] || fail 'a unit without metadata was changed'
mv "$tmp_root/recovery-git" "$tree/opt/strata/.git"
pass 'an existing checkout or unit is protected independently of the settings records'

# Recovery is possible only with every non-empty setting supplied explicitly.
mapfile -t recovery_settings < "$tmp_root/recovery-settings"
saved_upgrade "${recovery_settings[@]}" > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'explicit recovery from missing metadata'; }
cmp -s "$record" "$tmp_root/recovery-settings" || fail 'explicit recovery changed a setting'
[[ -s $tree/etc/strata-target/installed-settings ]] || fail 'explicit recovery did not recreate the fingerprint'
pass 'complete explicit settings recover lost metadata without resetting custom values'


# A first install that stops part-way leaves a checkout but no settings record.
# A rerun resumes with the settings it was started with (pending-env, written
# before the first change), never with the defaults, and drops it on success.
reset_tree
pbad=fedcba9876543210fedcba9876543210fedcba98
if FAKE_BAD_COMMIT=$pbad STRATA_COMMIT=$pbad STRATA_PORT=8123 STRATA_MODEL=IQ3_S STRATA_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a first install whose setup fails reported success'
fi
pending=$tree/etc/strata-target/pending-env
[[ -f $pending && ! -e $record ]] || fail 'an interrupted first install left no pending-env, or a settings record'
[[ $(stat -c %a "$pending") == 600 ]] || fail 'pending-env is not root-only'
contains 'STRATA_PORT=8123' "$pending"
cp "$pending" "$tmp_root/started-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming the interrupted install'; }
contains 'Resuming an interrupted install' "$tmp_root/out"
cmp -s "$record" "$tmp_root/started-settings" ||
    fail "the resumed install did not keep its settings: $(tr '\n' ' ' < "$record")"
[[ ! -e $pending ]] || fail 'pending-env was left after a successful install'
pass 'an interrupted first install resumes with the settings it was started with'

# Even API-key creation can fail before a checkout exists. The settings must
# already be checkpointed, and partial key output must not become an API key.
reset_tree
if FAKE_KEY_FAIL=1 STRATA_COMMIT=$commit STRATA_PORT=8123 STRATA_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed API-key generator reported success'
fi
[[ -f $pending && ! -e $tree/opt/strata/.git && ! -e $tree/etc/strata-target/api-key ]] ||
    fail 'key failure lost its checkpoint or published a partial key'
contains 'STRATA_PORT=8123' "$pending"
contains 'STRATA_CONTEXT=65536' "$pending"
cp "$pending" "$tmp_root/started-settings"
contains 'apt-get install -y ca-certificates curl git openssl' "$log"
env -i PATH="$bin:$PATH" FAKE_HELP="$help_documented" \
    STRATA_DIR="$tree/opt/strata" STRATA_DATA_DIR="$tree/var/lib/strata" \
    STRATA_ETC_DIR="$tree/etc/strata-target" STRATA_STATE_DIR="$tree/var/lib/strata-target" \
    UNIT_DIR="$tree/etc/systemd/system" STRATA_READY_TIMEOUT=5 \
    GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" STRATA_COMMIT=$commit \
    bash "$target" > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming after API-key failure'; }
cmp -s "$record" "$tmp_root/started-settings" || fail 'key-failure resume lost custom settings'
[[ ! -e $pending ]] || fail 'key-failure resume retained checkpoint'
pass 'API-key failure before checkout preserves settings for a bare retry'

# Interrupt promotion between its two renames. installed-env is published
# first and the fingerprint last, so the settings are complete and only the
# "nothing to do" marker is missing; pending-env stays until both are in place.
reset_tree
if FAKE_METADATA_FAIL=1 STRATA_PORT=8123 STRATA_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed fingerprint rename reported success'
fi
[[ -f $pending && -s $record && ! -e $tree/etc/strata-target/installed-settings ]] ||
    fail 'failed metadata promotion lost its complete recovery records'
cp "$pending" "$tmp_root/started-settings"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming after metadata publication failure'; }
cmp -s "$record" "$tmp_root/started-settings" || fail 'metadata-failure resume lost custom settings'
[[ ! -e $pending ]] || fail 'metadata-failure resume retained checkpoint'
pass 'a bare rerun recovers settings after interruption between metadata renames'

# The same interruption during an upgrade leaves the new settings next to the
# old fingerprint: the next bare rerun re-applies the new settings once, and
# never reverts to the ones the upgrade replaced.
if saved_upgrade FAKE_METADATA_FAIL=1 STRATA_PORT=8124 > "$tmp_root/out" 2>&1; then
    fail 'an upgrade whose fingerprint rename failed reported success'
fi
contains 'STRATA_PORT=8124' "$record"
grep -q '^port=8123$' "$tree/etc/strata-target/installed-settings" || fail 'the fingerprint was published despite the failed rename'
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after an interrupted upgrade promotion'; }
contains 'STRATA_PORT=8124' "$record"
grep -q '^port=8124$' "$tree/etc/strata-target/installed-settings" || fail 'the rerun reverted the upgraded settings'
pass 'an upgrade interrupted between the renames is completed, not reverted, by the next rerun'

bash "$script_dir/../../tests/lib/check-target-records.sh" "$script_dir/install-target.sh" "$tmp_root/record-failures" ||
    fail 'atomic settings record failure tests'
pass 'failed and interrupted metadata writes preserve complete settings records'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
