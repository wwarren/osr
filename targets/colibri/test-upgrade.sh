#!/usr/bin/env bash
# Whole-script runs of install-target.sh against a temporary tree with stubbed
# git, make, curl, systemctl and account tools: install, unchanged rerun,
# --upgrade, and rollback to the previous commit WITH the previous settings,
# build, launcher and unit. Nothing is downloaded, built or started.
#
# install-target.sh needs root (chown of the checkout, the 0700 records, the
# service account), so it is re-execed inside a user namespace where it is root;
# every command that could touch the real system is a stub on PATH.
#
# Settings and fakes reach the installer through rt's leading ENV=VAL arguments
# rather than a call prefix: bash keeps a prefix assignment in the calling shell
# afterwards, which would leak one case's fakes into the next.
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

if (( EUID != 0 )); then
    if command -v unshare >/dev/null 2>&1 && unshare -Ur true >/dev/null 2>&1; then
        exec unshare -Ur bash "${BASH_SOURCE[0]}" "$@"
    fi
    printf 'SKIP Colibri upgrade cases (install-target.sh needs root, no user namespace available)\n'
    exit 0
fi

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/colibri-upgrade-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/colibri-upgrade-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT

# The installer runs from a copy, so a case can ship a changed unit.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
cp "$script_dir/install-target.sh" "$script_dir/colibri.service" "$deploy/"
target=$deploy/install-target.sh
log=$tmp_root/calls.log

bin=$tmp_root/bin; mkdir -p "$bin"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for command_name in apt-get groupadd useradd usermod chown sleep nvidia-smi; do stub "$command_name" 'exit 0'; done
# The service account does not exist in the namespace, so install's ownership
# flags are stripped and it creates the directories for real.
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub getent 'exit 2'
# openssl rand -hex 32 is the API-key generator: a fixed value so the checks
# below can look for it without a real CSPRNG call.
stub openssl 'case "$1 $2" in "rand -hex") printf "%s\n" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";; *) exit 0;; esac'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
# is-failed exits 1 = "not failed"; is-active prints what wait_ready reads
# (inactive is the parked no-model state). With FAKE_RESTART_HEALS=FILE a
# restart creates FILE, after which the service is active and healthy: a
# stopped service that only needed a restart.
stub systemctl 'case "$1" in
    is-failed) exit "${FAKE_FAILED:-1}";;
    is-active)
        if [[ -n ${FAKE_RESTART_HEALS:-} && -e $FAKE_RESTART_HEALS ]]; then echo active; exit 0; fi
        printf "%s\n" "${FAKE_ACTIVE:-active}"; [[ ${FAKE_ACTIVE:-active} == active ]];;
    restart) [[ -z ${FAKE_RESTART_HEALS:-} ]] || : > "$FAKE_RESTART_HEALS";;
esac; exit 0'
# /v1/models is the readiness probe; any other URL would be a download.
stub curl 'url=${@: -1}
case $url in
    */v1/models)
        [[ -n ${FAKE_RESTART_HEALS:-} && -e $FAKE_RESTART_HEALS ]] && exit 0
        [[ ${FAKE_HEALTHY:-1} == 1 ]] || exit 22 ;;
    *) echo "unexpected download: $url" >&2; exit 22 ;;
esac'
# A CUDA toolkit's compiler, for the backend-change case.
mkdir -p "$tmp_root/cuda/bin"; printf '#!/bin/sh\nexit 0\n' > "$tmp_root/cuda/bin/nvcc"; chmod +x "$tmp_root/cuda/bin/nvcc"
mkdir -p "$tmp_root/gpus"; : > "$tmp_root/gpus/nvidia0"
cat > "$bin/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >> "$log"
dir=.
while [[ \$1 == -c || \$1 == -C ]]; do [[ \$1 == -C ]] && dir=\$2; shift 2; done
case \$1 in
    init) mkdir -p "\${@: -1}/.git" ;;
    remote) if [[ \$2 == add ]]; then echo "\$4" > "\$dir/.git/url"; else cat "\$dir/.git/url"; fi ;;
    fetch)
        [[ \${FAKE_FETCH_FAIL:-0} == 1 ]] && { echo 'fatal: unable to access' >&2; exit 128; }
        want=\${@: -1}
        [[ \$want =~ ^[0-9a-f]{40}\$ ]] || want=\$(printf '%s' "\$want" | sha1sum | cut -c1-40)
        echo "\$want" > "\$dir/.git/FETCH"; echo "\$want" >> "\$dir/.git/known" ;;
    update-ref) echo "\$3" >> "\$dir/.git/known" ;;
    checkout|reset)
        want=\${@: -1}
        grep -qx "\$want" "\$dir/.git/known" || { echo "fatal: reference is not a tree: \$want" >&2; exit 128; }
        echo "\$want" > "\$dir/.git/HEAD"
        # probe_build_env needs a C project in the checkout.
        mkdir -p "\$dir/c"; printf 'all:\n' > "\$dir/c/Makefile" ;;
    rev-parse) if [[ \$2 == FETCH_HEAD* ]]; then cat "\$dir/.git/FETCH"; else cat "\$dir/.git/HEAD"; fi ;;
esac
STUB
chmod +x "$bin/git"
# One make call builds and installs. It fails on FAKE_BAD_COMMIT and otherwise
# leaves the artefacts the installer asserts on: bin/coli, plus an engine marker
# naming the commit it was built from, so a rollback can be shown to have
# restored the previous build without rebuilding.
cat > "$bin/make" <<STUB
#!/usr/bin/env bash
echo "make \$*" >> "$log"
head=\$(cat "\$FAKE_COLIBRI_DIR/.git/HEAD")
[[ \$head == "\${FAKE_BAD_COMMIT:-none}" ]] && { echo 'error: build failed' >&2; exit 2; }
mkdir -p "\$FAKE_COLIBRI_DIR/bin" "\$FAKE_COLIBRI_DIR/libexec/colibri"
printf '#!/bin/sh\necho coli %s\\n' "\$head" > "\$FAKE_COLIBRI_DIR/bin/coli"
chmod 0755 "\$FAKE_COLIBRI_DIR/bin/coli"
printf 'engine built from %s\\n' "\$head" > "\$FAKE_COLIBRI_DIR/libexec/colibri/engine"
STUB
chmod +x "$bin/make"

tree=$tmp_root/tree
reset_tree() {
    rm -rf "$tree"
    mkdir -p "$tree/etc/systemd/system" "$tree/var/lib/colibri" "$tmp_root/no-icd"
    : > "$log"
}

# rt ENV=VAL... -- [args...]: run the installer with the fixed tree plus only
# the settings and fakes this case names. A CPU-only CT (no GPU nodes, no ICD)
# is the configuration every case starts from.
rt() {
    local -a extra=()
    while (( $# )) && [[ $1 != -- ]]; do extra+=("$1"); shift; done
    (( $# == 0 )) && set --
    [[ ${1:-} == -- ]] && shift
    env PATH="$bin:/usr/bin:/bin" HOME="$tmp_root" \
        COLIBRI_DIR="$tree/opt/colibri" COLIBRI_DATA_DIR="$tree/var/lib/colibri" \
        COLIBRI_ETC_DIR="$tree/etc/colibri-target" COLIBRI_STATE_DIR="$tree/var/lib/colibri-target" \
        UNIT_DIR="$tree/etc/systemd/system" COLIBRI_READY_TIMEOUT=2 \
        GPU_NODES= DRI_NODES= COLIBRI_ICD_DIRS="$tmp_root/no-icd" COLIBRI_BACKEND=cpu \
        COLIBRI_NVCC="$tmp_root/cuda/bin/nvcc" \
        FAKE_COLIBRI_DIR="$tree/opt/colibri" \
        "${extra[@]+"${extra[@]}"}" bash "$target" "$@"
}
# The commit already installed: how a rerun of an unchanged pin arrives.
at_head() { printf 'COLIBRI_COMMIT=%s' "$(cat "$tree/opt/colibri/.git/HEAD")"; }
contains() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }

# 40 hex characters each: install-target.sh pins by full SHA-1.
good=$(printf '0%.0s' {1..39})a
next=$(printf '1%.0s' {1..39})b
bad=$(printf 'f%.0s' {1..39})e

unit=$tree/etc/systemd/system/colibri.service
launcher=$tree/opt/colibri/run-colibri.sh
etc=$tree/etc/colibri-target
model=$tree/var/lib/colibri/models/qwen

# --- a fresh install with a model --------------------------------------------
# A non-empty model directory is what makes readiness real: the launcher serves
# and /v1/models has to answer. The parked no-model case is checked last.
reset_tree
mkdir -p "$model"; : > "$model/model.gguf"
rt COLIBRI_MODEL_DIR="$model" COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'fresh install'; }
cmp -s "$unit" "$script_dir/colibri.service" || fail 'unit not installed'
contains "COLIBRI_RUN_SCRIPT=$launcher" "$etc/colibri.env"
grep -q 'api' "$etc/colibri.env" && fail 'the env file holds more than the launcher path'
contains "serve --host 0.0.0.0 --port 8080 --allowed-host \\* --model $model --auto-tier" "$launcher"
[[ $(stat -c %a "$launcher") == 700 ]] || fail "the launcher is mode $(stat -c %a "$launcher")"
[[ $(stat -c %a "$etc/secrets.env") == 600 ]] || fail "secrets.env is mode $(stat -c %a "$etc/secrets.env")"
contains "COLIBRI_MODEL_DIR=$model" "$etc/installed-env"
contains 'COLIBRI_BACKEND=cpu' "$etc/installed-env"
[[ $(< "$tree/opt/colibri/libexec/colibri/engine") == "engine built from $good" ]] ||
    fail 'the install built from another commit'
key=$(< "$etc/api-key")
grep -q -- "$key" "$tmp_root/out" && fail 'the API key was printed'
grep -q -- "$key" "$unit" && fail 'the API key reached the unit file'
grep -q -- "$key" "$etc/installed-env" && fail 'the API key reached the settings record'
grep -q -- "$key" "$launcher" && fail 'the API key reached the launcher (and the command line)'
grep -qx "COLI_API_KEY=$key" "$etc/secrets.env" || fail 'secrets.env does not carry the key'
pass 'a fresh install builds, serves, and records its settings without the key'

# --- an unchanged rerun does nothing -----------------------------------------
# A complete installation takes the upgrade path on a plain rerun, so this is
# the nothing-to-do check: same commit, same settings, same unit, still healthy.
: > "$log"
rt "$(at_head)" -- > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'unchanged rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -qE 'systemctl (stop|restart)|^make ' "$log" && fail "an unchanged rerun touched the target: $(cat "$log")"
pass 'an unchanged, healthy rerun stops, rebuilds and restarts nothing'

# --- a failed fetch changes nothing ------------------------------------------
: > "$log"
cp "$etc/installed-env" "$tmp_root/env-before"
if rt FAKE_FETCH_FAIL=1 COLIBRI_COMMIT=$next -- --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade without network reported success'
fi
contains 'was not stopped or changed' "$tmp_root/out"
grep -qE 'systemctl (stop|restart)' "$log" && fail 'a failed fetch stopped the service'
cmp -s "$etc/installed-env" "$tmp_root/env-before" || fail 'a failed fetch changed the settings record'
pass 'a failed fetch leaves the running service and its records untouched'

# --- a healthy upgrade -------------------------------------------------------
: > "$log"
rt COLIBRI_COMMIT=$next -- --upgrade > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'healthy upgrade'; }
contains "Colibri is running $next" "$tmp_root/out"
[[ $(< "$tree/opt/colibri/.git/HEAD") == "$next" ]] || fail 'the upgrade did not check out the new commit'
[[ $(< "$tree/opt/colibri/libexec/colibri/engine") == "engine built from $next" ]] ||
    fail 'the upgrade did not rebuild'
[[ ! -e $tree/var/lib/colibri-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful upgrade'
[[ ! -e $tree/var/lib/colibri-target/rollback.service ]] || fail 'the unit snapshot was kept after a successful upgrade'
pass 'a healthy upgrade moves to the new commit and drops its snapshot'

# --- a failed upgrade rolls back ---------------------------------------------
# The attempted upgrade changes the commit and the unit; its build fails. The
# previous release must come back offline: previous commit, previous build,
# previous launcher and previous unit, then restarted and checked again.
cp "$unit" "$tmp_root/good.service"
cp "$launcher" "$tmp_root/good-launcher"
cp "$etc/installed-settings" "$tmp_root/good-settings"
printf '# changed by the attempted upgrade\n' >> "$deploy/colibri.service"
: > "$log"
if rt FAKE_BAD_COMMIT=$bad COLIBRI_COMMIT=$bad -- --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
cp "$script_dir/colibri.service" "$deploy/colibri.service"
contains "Upgrade failed; Colibri is running $next again" "$tmp_root/out"
contains 'Restoring the settings it last ran with' "$tmp_root/out"
[[ $(< "$tree/opt/colibri/.git/HEAD") == "$next" ]] || fail 'rollback did not restore the commit'
[[ $(< "$tree/opt/colibri/libexec/colibri/engine") == "engine built from $next" ]] ||
    fail 'rollback did not restore the previous build'
cmp -s "$launcher" "$tmp_root/good-launcher" || fail "rollback launcher differs: $(cat "$launcher")"
cmp -s "$unit" "$tmp_root/good.service" || fail 'rollback kept the attempted unit'
cmp -s "$etc/installed-settings" "$tmp_root/good-settings" || fail 'a failed upgrade changed the fingerprint record'
# as_service logs the runuser wrapper and the git stub logs the command, so
# one fetch is two lines here; what matters is that there is only one fetch.
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] ||
    fail "rollback fetched again instead of using the local commit: $(grep '^git .* fetch ' "$log")"
contains "update-ref refs/colibri/previous $next" "$log"
[[ $(grep -c '^make ' "$log") == 1 ]] || fail 'rollback rebuilt instead of restoring the snapshot'
grep -q '^systemctl restart colibri.service' "$log" || fail 'the rolled-back service was not restarted'
[[ ! -e $tree/var/lib/colibri-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful rollback'
pass 'a failed upgrade restores the previous commit, build, launcher and unit offline'

# After a rollback the target is whole again: the next rerun is a no-op.
: > "$log"
rt "$(at_head)" -- > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after rollback'; }
contains 'nothing to do' "$tmp_root/out"
pass 'the installation is consistent again after a rollback'

# --- a rollback that does not come back --------------------------------------
# Neither the new release nor the restored one is healthy. That must be
# reported as what it is, and the snapshot kept for whoever fixes it.
: > "$log"
if rt FAKE_HEALTHY=0 FAKE_BAD_COMMIT=$bad COLIBRI_COMMIT=$bad -- --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade and a rollback that never became healthy reported success'
fi
contains "Rollback to $next failed too" "$tmp_root/out"
contains 'the snapshot is kept in' "$tmp_root/out"
[[ -s $tree/var/lib/colibri-target/rollback-runtime.tar ]] || fail 'a failed rollback removed the snapshot'
pass 'a rollback that does not become healthy is reported, and its snapshot kept'

# The marker stops the next run from snapshotting over the kept runtime, until
# someone has looked at the failure.
[[ -e $tree/var/lib/colibri-target/rollback-failed ]] || fail 'a failed rollback left no marker'
cp "$tree/var/lib/colibri-target/rollback-runtime.tar" "$tmp_root/kept.tar"
: > "$log"
if rt COLIBRI_COMMIT=$next -- --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade over a failed rollback went ahead'
fi
contains 'A rollback failed earlier' "$tmp_root/out"
grep -qE 'systemctl (stop|restart)| fetch ' "$log" && fail "a refused run stopped or fetched anything: $(cat "$log")"
cmp -s "$tmp_root/kept.tar" "$tree/var/lib/colibri-target/rollback-runtime.tar" ||
    fail 'a refused run changed the kept snapshot'
if rt COLIBRI_COMMIT=$next -- > "$tmp_root/out" 2>&1; then
    fail 'an install over a failed rollback went ahead'
fi
contains 'A rollback failed earlier' "$tmp_root/out"
rm -f -- "$tree/var/lib/colibri-target/rollback-failed"
pass 'after a failed rollback the next run stops, changing nothing, until its marker is removed'

# --- a no-model install is a success, not a timeout ---------------------------
# This is what every fresh install looks like: the model directory is created
# empty, the launcher logs where to put a model and exits 0, the unit settles at inactive,
# and readiness accepts that instead of waiting for a /v1/models that will
# never answer.
reset_tree
if ! rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1; then
    cat "$tmp_root/out"; fail 'a parked no-model install was treated as a failure'
fi
contains "installed and parked: $tree/var/lib/colibri/model is empty" "$tmp_root/out"
[[ -d $tree/var/lib/colibri/model ]] || fail 'the default model directory was not created'
sh "$launcher" | grep -q 'is empty. Copy a model directory there' || fail 'the parked launcher gives no instruction'
contains "--model $tree/var/lib/colibri/model" "$launcher"
pass 'an install with no model parks the service and reports success'

# A parked install that is otherwise unchanged is left alone: no stop, no
# rebuild (every engine), no restart.
: > "$log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'rerun of a parked install'; }
contains 'parked without a model; nothing to do' "$tmp_root/out"
grep -qE 'systemctl (stop|restart)|^make ' "$log" && fail "a parked rerun touched the target: $(cat "$log")"
pass 'an unchanged parked install is nothing to do'

# --- a model copied in later needs only a restart ----------------------------
reset_tree
mkdir -p "$model"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_MODEL_DIR="$model" COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'an install with an empty model directory'; }
contains "installed and parked: $model is empty" "$tmp_root/out"
contains "--model $model" "$launcher"
: > "$model/config.json"
rm -f -- "$tmp_root/healed"
: > "$log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive FAKE_RESTART_HEALS="$tmp_root/healed" "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'the rerun after a model was copied in'; }
contains 'restarting it' "$tmp_root/out"
contains 'is back after a restart (serving, or parked without a model); nothing to rebuild' "$tmp_root/out"
grep -q '^make ' "$log" && fail 'a restart-only rerun rebuilt the engines'
grep -q '^systemctl restart colibri.service' "$log" || fail 'the service was not restarted'
pass 'a model copied into the configured directory needs only a restart'

# --- a GPU passed in later is built for ---------------------------------------
# The fingerprint holds the backend as built, so auto on a CT that now has an
# NVIDIA GPU rebuilds with CUDA=1 (and the toolkit it found) instead of saying
# there is nothing to do.
reset_tree
mkdir -p "$model"; : > "$model/config.json"
rt COLIBRI_BACKEND=auto COLIBRI_MODEL_DIR="$model" COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a CPU install with auto'; }
contains 'built_backend=cpu' "$etc/installed-settings"
: > "$log"
rt COLIBRI_BACKEND=auto GPU_NODES="$tmp_root/gpus/nvidia*" "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'the rerun with a GPU'; }
contains 'Re-applying Colibri' "$tmp_root/out"
grep -q "^make .* CUDA=1 CUDA_HOME=$tmp_root/cuda" "$log" || fail "the rebuild was not for CUDA: $(grep '^make ' "$log")"
contains 'built_backend=cuda' "$etc/installed-settings"
contains '--auto-tier --gpu auto' "$launcher"
pass 'a GPU passed in later makes the next run rebuild for it'

printf '%s Colibri upgrade cases passed. No system files, packages or services were touched.\n' "$passed"
