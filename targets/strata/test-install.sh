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
for helper in help_has help_choices check_choice validate_setup_options setup_args select_run_script start_env; do
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

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub getent 'exit 2'   # no strata group yet, so it is created
for command_name in apt-get groupadd useradd usermod chown sleep nvidia-smi; do stub "$command_name" 'exit 0'; done
stub stat 'echo "${FAKE_GROUP:-video}"'
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
    checkout)
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
[[ \$(< .git/HEAD) != "\${FAKE_BAD_COMMIT:-none}" ]] || exit 1
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
        STRATA_ETC_DIR="$tree/etc/strata-target" UNIT_DIR="$tree/etc/systemd/system" \
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
STRATA_COMMIT=$next run_target --upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade'; }
[[ $(< "$tree/opt/strata/.git/HEAD") == "$next" ]] || fail 'upgrade did not move HEAD'
contains "fetch -q --depth 1 origin $next" "$log"
contains 'systemctl stop strata.service' "$log"
contains "@$next" "$log"
pass '--upgrade fetches the pinned commit (not only a branch tip) and re-runs setup'

bad=fedcba9876543210fedcba9876543210fedcba98
: > "$log"
if FAKE_BAD_COMMIT=$bad STRATA_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains "Strata is running $next again" "$tmp_root/out"
[[ $(< "$tree/opt/strata/.git/HEAD") == "$next" ]] || fail 'rollback did not restore HEAD'
contains "@$next" "$log"   # setup re-run on the previous commit
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] || fail 'rollback fetched again instead of using the local commit'
contains "update-ref refs/strata/previous $next" "$log"
pass 'a failed upgrade returns to the previous commit without the network'

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

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
