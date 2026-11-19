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
cp "$script_dir/install-target.sh" "$script_dir/colibri.service" "$script_dir/model-select.sh" "$deploy/"
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
# Room on the model's filesystem for --model's fit check (bytes in column 4).
stub df 'printf "Filesystem 1B-blocks Used Available Use%% Mounted\nfake 0 0 %s 0%% /\n" "${FAKE_DF_FREE:-900000000000}"'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub sync 'if [[ ${FAKE_SYNC_FAIL:-0} == 1 && ${1:-} == -- && ${2:-} == "$FAKE_MODEL_DIR" ]]; then exit 74; fi; exec /usr/bin/sync "$@"'
# Fail after moving one published entry, simulating interruption during the
# non-atomic sequence of same-filesystem renames.
stub mv 'if [[ ${FAKE_PARTIAL_PUBLISH:-0} == 1 && ${1:-} == -t && ${2:-} == "$FAKE_MODEL_DIR" ]]; then
    /usr/bin/mv -t "$2" -- "$4"; exit 17
fi
exec /usr/bin/mv "$@"'
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
        # A model that never answers: the live manifest names this repository.
        [[ -n ${FAKE_UNHEALTHY_REPO:-} ]] && grep -qF "$FAKE_UNHEALTHY_REPO" "$FAKE_MODEL_DIR/.colibri-download.json" 2>/dev/null && exit 22
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
cp "$tmp_root/setup_download.py" "\$FAKE_COLIBRI_DIR/libexec/colibri/setup_download.py"
STUB
chmod +x "$bin/make"
# colibri's downloader as make install puts it in libexec, with the functions
# install-target.sh calls. FAKE_DL: ok (writes a complete model folder), fail
# (a transfer error), huge (more than the disk holds). It logs each call.
cat > "$tmp_root/setup_download.py" <<'PYSTUB'
import json
import os


class DownloadError(RuntimeError):
    pass


def _log(text):
    with open(os.environ["FAKE_DL_LOG"], "a", encoding="utf-8") as handle:
        handle.write(text + "\n")


def hf_token():
    return None


def list_repo_files(repo, revision="main", **_):
    _log(f"list {repo}@{revision}")
    size = 1 << 60 if os.environ.get("FAKE_DL") == "huge" else 4
    return [{"path": "config.json", "size": 2, "sha256": None, "git_oid": "x"},
            {"path": "model-00000.safetensors", "size": size, "sha256": "y", "git_oid": None}]


def bytes_present(model_dir, files, extra_dirs=()):
    return 0


def download_repo(repo, revision, model_dir, files, *, token=None, progress=None, **_):
    _log(f"download {repo}@{revision} -> {model_dir}")
    if os.environ.get("FAKE_DL") == "fail":
        raise DownloadError("connection reset")
    for spec in files:
        with open(os.path.join(model_dir, spec["path"]), "w", encoding="utf-8") as handle:
            handle.write("x" * min(spec["size"], 8))
    with open(os.path.join(model_dir, ".colibri-download.json"), "w", encoding="utf-8") as handle:
        json.dump({"repo": repo, "revision": revision, "complete": True, "files": files}, handle)
    if progress:
        progress({"file": "", "file_done": 1, "file_total": 1, "done": 1, "total": 1})
    return {"files": len(files), "bytes": 1}


def is_complete(model_dir, extra_dirs=()):
    try:
        with open(os.path.join(model_dir, ".colibri-download.json"), encoding="utf-8") as handle:
            return json.load(handle).get("complete") is True
    except OSError:
        return False
PYSTUB
dl_log=$tmp_root/download.log

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
        FAKE_COLIBRI_DIR="$tree/opt/colibri" FAKE_DL_LOG="$dl_log" \
        FAKE_MODEL_DIR="$tree/var/lib/colibri/model" COLIBRI_MEMINFO="$tmp_root/meminfo" NONINTERACTIVE=true \
        "${extra[@]+"${extra[@]}"}" bash "$target" "$@"
}
printf 'MemTotal:       67108864 kB\n' > "$tmp_root/meminfo"
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

# --- an explicit model download ------------------------------------------------
# COLIBRI_MODEL_ID downloads the pinned commit with colibri's own downloader,
# as the service account, into the model directory's staging folder, and
# publishes it only when complete.
modeldir=$tree/var/lib/colibri/model
qwen_stage=$modeldir/.colibri-staging/qwen36-35b-c619aa594ad1e70af82168fb6b4878427896e21c
coder_stage=$modeldir/.colibri-staging/qwen3-coder-30b-d839110a17d31b4e6fa9f3d973b751f779b6b9c6
reset_tree; : > "$dl_log"
rt COLIBRI_MODEL_ID=qwen3-coder-30b COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a first install with a model download'; }
grep -qx 'list Justvugg/Qwen3-Coder-30B-A3B-colibri-int4@d839110a17d31b4e6fa9f3d973b751f779b6b9c6' "$dl_log" ||
    fail "the download was not of the pinned commit: $(cat "$dl_log")"
contains "download Justvugg/Qwen3-Coder-30B-A3B-colibri-int4@d839110a17d31b4e6fa9f3d973b751f779b6b9c6 -> $coder_stage" "$dl_log"
contains "Published Qwen3-Coder-30B-A3B in $modeldir" "$tmp_root/out"
[[ -f $modeldir/config.json && -f $modeldir/model-00000.safetensors ]] || fail 'the model was not published in the model directory'
[[ ! -e $modeldir/.colibri-staging ]] || fail 'the staging folder was left behind'
grep -q 'runuser -u colibri' "$log" || fail 'the download did not run as the service account'
grep -qE 'pip|venv|huggingface_hub' "$log" && fail "the download installed Python packages: $(grep -E 'pip|venv' "$log")"
contains 'COLIBRI_MODEL_DIR=' "$etc/installed-env"
grep -q 'COLIBRI_MODEL_ID' "$etc/installed-env" && fail 'COLIBRI_MODEL_ID was recorded as a setting'
pass 'COLIBRI_MODEL_ID downloads the pinned commit as the service account and publishes it whole'

# A model already there is never replaced.
: > "$dl_log"
rt COLIBRI_MODEL_ID=qwen36-35b "$(at_head)" -- > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'a rerun over a model'; }
contains 'downloads nothing' "$tmp_root/out"
[[ ! -s $dl_log ]] || fail "a model in place was downloaded over: $(cat "$dl_log")"
pass 'a model already in place is never downloaded over'

# On an installed, parked CT the same ID downloads, and the restart path
# serves it: nothing is rebuilt.
reset_tree; : > "$dl_log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a parked install'; }
: > "$log"; rm -f -- "$tmp_root/healed"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive FAKE_RESTART_HEALS="$tmp_root/healed" \
    COLIBRI_MODEL_ID=qwen36-35b "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a download on an installed CT'; }
contains 'list Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64@c619aa594ad1e70af82168fb6b4878427896e21c' "$dl_log"
contains 'Published Qwen3.6-35B-A3B' "$tmp_root/out"
grep -q 'systemctl restart colibri.service' "$log" || fail 'the downloaded model was not restarted'
grep -q '^make ' "$log" && fail 'a download on an installed CT rebuilt the engines'
pass 'a download asked for on an installed CT is served after a restart, without a rebuild'

# A failed or partial download publishes nothing, and the launcher still parks:
# the staging folder is not a model.
reset_tree; : > "$dl_log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a parked install'; }
: > "$log"
if rt FAKE_DL=fail COLIBRI_MODEL_ID=qwen36-35b "$(at_head)" -- > "$tmp_root/out" 2>&1; then
    fail 'a failed download reported success'
fi
contains 'Model download failed: connection reset' "$tmp_root/out"
contains 'nothing was published. Rerun with COLIBRI_MODEL_ID=qwen36-35b to resume it' "$tmp_root/out"
[[ -d $qwen_stage ]] || fail 'the partial download was not kept for a resume'
[[ ! -e $modeldir/config.json ]] || fail 'a failed download published files'
grep -qE 'systemctl (stop|restart)|^make ' "$log" && fail "a failed download touched the service: $(cat "$log")"
: > "$qwen_stage/config.json"
sh "$launcher" | grep -q 'is empty' || fail 'the launcher took a partial download for a model'
pass 'a failed download publishes nothing, keeps its staging folder to resume, and the launcher still parks'

# Switching IDs after a failed transfer removes the first model's partial
# download before the free-space check (its disk is needed), and never
# publishes any of it.
: > "$qwen_stage/old-model.part"
: > "$log"; rm -f -- "$tmp_root/healed"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive FAKE_RESTART_HEALS="$tmp_root/healed" \
    COLIBRI_MODEL_ID=qwen3-coder-30b "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'switching models after a failed download'; }
[[ ! -e $qwen_stage ]] || fail 'the other model'"'"'s partial download was kept'
contains "Removed the unfinished or leftover download ${qwen_stage##*/}" "$tmp_root/out"
[[ ! -e $modeldir/old-model.part ]] || fail 'a stale partial file was published with another model'
[[ -f $modeldir/config.json && -f $modeldir/model-00000.safetensors ]] ||
    fail 'the newly selected model was not published'
[[ ! -e $modeldir/.colibri-staging ]] || fail 'the staging folder was left after a publication'
pass 'switching models removes the other partial download first and publishes only the new model'

# A plain rerun keeps an unfinished download (it is resumable) and says so.
reset_tree; : > "$dl_log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a parked install'; }
rt FAKE_DL=fail COLIBRI_MODEL_ID=qwen36-35b "$(at_head)" -- > "$tmp_root/out" 2>&1 && fail 'a failed download reported success'
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a plain rerun with an unfinished download'; }
[[ -d $qwen_stage ]] || fail 'a plain rerun removed a resumable download'
contains "rerun with COLIBRI_MODEL_ID=qwen36-35b to finish it" "$tmp_root/out"
pass 'a plain rerun keeps an unfinished download and names the ID that resumes it'

# A failed directory sync stops publication with its marker still available to
# the next invocation. It must not report that the model was published.
reset_tree; : > "$dl_log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a parked install before the sync failure'; }
if rt FAKE_SYNC_FAIL=1 COLIBRI_MODEL_ID=qwen36-35b "$(at_head)" -- > "$tmp_root/out" 2>&1; then
    fail 'a failed model directory sync reported success'
fi
[[ -f $modeldir/.colibri-publishing && -d $qwen_stage ]] ||
    fail 'a sync failure lost the publication marker or its complete stage'
[[ ! -e $modeldir/config.json ]] || fail 'a sync failure published files anyway'
pass 'a model directory sync error stops publication and keeps the stage recoverable'

# A crash during publication leaves a marker that parks the launcher. The next
# run restores moved entries to stage, verifies them, and finishes publication.
reset_tree; : > "$dl_log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a parked install before interrupted publication'; }
: > "$log"
if rt FAKE_PARTIAL_PUBLISH=1 COLIBRI_MODEL_ID=qwen36-35b "$(at_head)" -- > "$tmp_root/out" 2>&1; then
    fail 'an interrupted publication reported success'
fi
[[ -f $modeldir/.colibri-publishing ]] || fail 'the interrupted publication lost its marker'
[[ -d $qwen_stage ]] || fail 'the interrupted publication lost its stage'
[[ -n $(find "$modeldir" -mindepth 1 -maxdepth 1 ! -name .colibri-staging ! -name .colibri-publishing -print -quit) ]] ||
    fail 'the interruption did not move a model entry'
sh "$launcher" | grep -q 'publication in .* was interrupted' || fail 'the launcher did not report the interrupted publication'
grep -qE 'systemctl (stop|restart)|^make ' "$log" && fail 'an interrupted publication touched the service'
# A plain rerun (no COLIBRI_MODEL_ID, as tools/upgrade-all.sh runs it) finishes it.
: > "$log"; : > "$dl_log"; rm -f -- "$tmp_root/healed"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive FAKE_RESTART_HEALS="$tmp_root/healed" \
    "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'resuming an interrupted publication'; }
contains 'Finished an interrupted model publication' "$tmp_root/out"
grep -q 'systemctl restart colibri.service' "$log" || fail 'the recovered publication was not restarted'
[[ ! -s $dl_log ]] || fail 'finishing a publication downloaded again'
[[ ! -e $modeldir/.colibri-publishing && ! -e $qwen_stage ]] ||
    fail 'the publication marker or stage remained after recovery'
[[ -f $modeldir/config.json && -f $modeldir/model-00000.safetensors ]] ||
    fail 'recovery did not publish the whole model'
grep -q '^make ' "$log" && fail 'recovering publication rebuilt the engines'
pass 'an interrupted publication parks, says so, and any rerun finishes it without a download'

# The first catalog-download version wrote the stage key alone in the marker.
reset_tree
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a parked install before a legacy marker'; }
mkdir -p "$qwen_stage"; printf '{}' > "$qwen_stage/.colibri-download.json"; : > "$qwen_stage/model-00000.safetensors"
: > "$modeldir/config.json"; printf '%s\n' "${qwen_stage##*/}" > "$modeldir/.colibri-publishing"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive FAKE_RESTART_HEALS="$tmp_root/healed" "$(at_head)" -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'recovering a legacy marker'; }
[[ -f $modeldir/config.json && -f $modeldir/model-00000.safetensors && ! -e $modeldir/.colibri-publishing ]] ||
    fail 'a legacy marker was not finished'
pass 'a marker of the first download version is finished too'

# Too little disk stops before anything is fetched.
reset_tree; : > "$dl_log"
rt FAKE_HEALTHY=0 FAKE_ACTIVE=inactive COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a parked install before the disk check'; }
if rt FAKE_DL=huge COLIBRI_MODEL_ID=qwen36-35b "$(at_head)" -- > "$tmp_root/out" 2>&1; then
    fail 'a download larger than the disk reported success'
fi
contains 'Not enough disk for the model' "$tmp_root/out"
grep -q '^download ' "$dl_log" && fail 'a download started without the disk for it'
pass 'a download larger than the free disk stops before fetching anything'

# --- install-target.sh --model ------------------------------------------------
# A served catalog model is replaced: the new one downloads while the old keeps
# serving, the service stops only for the swap, the old download is deleted.
reset_tree; : > "$dl_log"
rt COLIBRI_MODEL_ID=qwen3-coder-30b COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'an install serving a model'; }
: > "$log"; : > "$dl_log"
rt COLIBRI_MODEL_ID=qwen36-35b -- --model > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail '--model replacing a served model'; }
contains 'Served now: Qwen3-Coder-30B-A3B (19.4 GB).' "$tmp_root/out"
contains 'list Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64@c619aa594ad1e70af82168fb6b4878427896e21c' "$dl_log"
contains '"repo": "Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64"' "$modeldir/.colibri-download.json"
contains 'Removed the replaced catalog model, Qwen3-Coder-30B-A3B (19.4 GB).' "$tmp_root/out"
contains 'Colibri now serves Qwen3.6-35B-A3B' "$tmp_root/out"
[[ ! -e $modeldir/.colibri-staging && ! -e $modeldir/.colibri-publishing ]] || fail '--model left staging behind'
grep -q '^make ' "$log" && fail '--model rebuilt the engines'
[[ $(grep -n 'systemctl stop' "$log" | head -1 | cut -d: -f1) -gt $(grep -n 'runuser' "$log" | head -1 | cut -d: -f1) ]] ||
    fail 'the service stopped before the new model was downloaded'
pass '--model downloads beside the served model, swaps it in, and deletes the replaced download'

# The same model again, or keep, changes nothing.
: > "$log"; : > "$dl_log"
rt COLIBRI_MODEL_ID=qwen36-35b -- --model > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail '--model with the served ID'; }
rt COLIBRI_MODEL_ID=keep -- --model >> "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail '--model keep'; }
rt -- --model >> "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail '--model unattended without an ID'; }
[[ $(grep -c 'The served model stays as it is.' "$tmp_root/out") == 3 ]] || { cat "$tmp_root/out"; fail '--model keep did not keep'; }
[[ ! -s $dl_log ]] && ! grep -q 'systemctl stop' "$log" || fail '--model keep touched the model or the service'
pass '--model with the served ID, keep, or no answer changes nothing'

# A new model that does not come up is swapped back out.
: > "$log"; : > "$dl_log"
if rt FAKE_UNHEALTHY_REPO=Justvugg/Qwen3-Coder COLIBRI_MODEL_ID=qwen3-coder-30b -- --model > "$tmp_root/out" 2>&1; then
    fail '--model reported success for a model that never answered'
fi
contains 'did not come up; putting the previous model back' "$tmp_root/out"
contains 'the previous model is back' "$tmp_root/out"
contains '"repo": "Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64"' "$modeldir/.colibri-download.json"
[[ -f $coder_stage/.colibri-download.json ]] || fail 'the failed model'"'"'s download was not kept to try again'
[[ ! -e $modeldir/.colibri-publishing ]] || fail 'the restore left a publication marker'
pass '--model puts the previous model back when the new one does not answer, keeping the download'

# A crash in the middle of the retire phase: the next run finishes the swap.
mkdir -p "$modeldir/.colibri-staging/retired-1"
mv "$modeldir/config.json" "$modeldir/.colibri-staging/retired-1/"
printf 'retire %s retired-1\n' "${coder_stage##*/}" > "$modeldir/.colibri-publishing"
: > "$log"
rt COLIBRI_MODEL_ID=keep -- --model > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail '--model after an interrupted swap'; }
contains 'Finished an interrupted model publication' "$tmp_root/out"
contains '"repo": "Justvugg/Qwen3-Coder-30B-A3B-colibri-int4"' "$modeldir/.colibri-download.json"
[[ ! -e $modeldir/.colibri-staging ]] || fail 'the replaced model was not removed once the new one answered'
pass 'an interrupted swap is finished, and the replaced model removed once the served one answers'

# A crash after the files moved but before health validation must also be
# recoverable by a plain upgrade. An unhealthy new model returns to its stage.
mkdir -p "$qwen_stage" "$modeldir/.colibri-staging/retired-2"
printf '{"repo": "Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64", "revision": "c619aa594ad1e70af82168fb6b4878427896e21c"}\n' > "$qwen_stage/.colibri-download.json"
: > "$qwen_stage/config.json"; : > "$qwen_stage/model-00000.safetensors"
find "$modeldir" -mindepth 1 -maxdepth 1 ! -name .colibri-staging -exec mv -t "$modeldir/.colibri-staging/retired-2" -- {} +
find "$qwen_stage" -mindepth 1 -maxdepth 1 -exec mv -t "$modeldir" -- {} +
rmdir "$qwen_stage"
printf 'validate %s retired-2 forward\n' "${qwen_stage##*/}" > "$modeldir/.colibri-publishing"
sh "$launcher" | grep -q '^coli ' || fail 'the launcher parked during model validation'
: > "$log"; : > "$dl_log"
if rt FAKE_UNHEALTHY_REPO=Kreuzzelg/qwen36 "$(at_head)" -- --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an unhealthy pending model switch was accepted by a plain upgrade'
fi
contains 'the previous model is back' "$tmp_root/out"
contains '"repo": "Justvugg/Qwen3-Coder-30B-A3B-colibri-int4"' "$modeldir/.colibri-download.json"
[[ -f $qwen_stage/.colibri-download.json && ! -e $modeldir/.colibri-publishing ]] ||
    fail 'a plain upgrade did not restore the old model and keep the failed download'
[[ ! -s $dl_log ]] || fail 'a plain upgrade downloaded the failed model again'
grep -q '^make ' "$log" && fail 'a failed model switch rebuilt the runtime'
pass 'a plain upgrade rolls back an unhealthy model after an interrupted validation'

# The same pending switch with a healthy model finalizes the old files.
mkdir -p "$modeldir/.colibri-staging/retired-3"
find "$modeldir" -mindepth 1 -maxdepth 1 ! -name .colibri-staging -exec mv -t "$modeldir/.colibri-staging/retired-3" -- {} +
find "$qwen_stage" -mindepth 1 -maxdepth 1 -exec mv -t "$modeldir" -- {} +
rmdir "$qwen_stage"
printf 'validate %s retired-3 forward\n' "${qwen_stage##*/}" > "$modeldir/.colibri-publishing"
: > "$log"; : > "$dl_log"
rt "$(at_head)" -- --upgrade > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'a healthy pending model switch on a plain upgrade'; }
contains '"repo": "Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64"' "$modeldir/.colibri-download.json"
[[ ! -e $modeldir/.colibri-publishing && ! -e $modeldir/.colibri-staging ]] ||
    fail 'a plain upgrade left a validated model switch unfinished'
[[ ! -s $dl_log ]] || fail 'a plain upgrade downloaded the validated model again'
grep -q '^make ' "$log" && fail 'a healthy model switch rebuilt the runtime'
pass 'a plain upgrade finalizes a healthy model after an interrupted validation'

# Previous installers could clear the marker before validation. A lone retired
# model still gives a plain upgrade enough information to reverse that switch.
mkdir -p "$coder_stage" "$modeldir/.colibri-staging/retired-4"
printf '{"repo": "Justvugg/Qwen3-Coder-30B-A3B-colibri-int4", "revision": "d839110a17d31b4e6fa9f3d973b751f779b6b9c6"}\n' > "$coder_stage/.colibri-download.json"
: > "$coder_stage/config.json"; : > "$coder_stage/model-00000.safetensors"
find "$modeldir" -mindepth 1 -maxdepth 1 ! -name .colibri-staging -exec mv -t "$modeldir/.colibri-staging/retired-4" -- {} +
find "$coder_stage" -mindepth 1 -maxdepth 1 -exec mv -t "$modeldir" -- {} +
rmdir "$coder_stage"
: > "$log"; : > "$dl_log"
if rt FAKE_UNHEALTHY_REPO=Justvugg/Qwen3-Coder "$(at_head)" -- --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an unmarked unhealthy switch was accepted by a plain upgrade'
fi
contains 'the previous model is back' "$tmp_root/out"
contains '"repo": "Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64"' "$modeldir/.colibri-download.json"
[[ -f $coder_stage/.colibri-download.json && ! -e $modeldir/.colibri-publishing ]] ||
    fail 'an unmarked model switch did not restore the old model'
[[ ! -s $dl_log ]] || fail 'an unmarked model switch downloaded again'
pass 'a plain upgrade restores the old model when an earlier installer cleared the marker too soon'

# remove parks the service; a model placed by hand is kept, not deleted.
: > "$log"
rt COLIBRI_MODEL_ID=remove -- --model > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail '--model remove'; }
[[ -z $(find "$modeldir" -mindepth 1 -print -quit) ]] || fail 'remove left files in the model directory'
contains 'The model was removed' "$tmp_root/out"
: > "$modeldir/weights.bin"
rt COLIBRI_MODEL_ID=remove -- --model > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail '--model remove of a hand-placed model'; }
contains 'it is kept in' "$tmp_root/out"
compgen -G "$tree/var/lib/colibri/model-replaced-*/weights.bin" >/dev/null || fail 'a hand-placed model was not kept'
pass '--model remove deletes a catalog download, keeps a hand-placed model aside, and parks'

# A model with a post-download step (Kimi K3's tokenizer.json from colibri's
# tools/k3_tokenizer.py) runs it as the service account before publishing.
mkdir -p "$tree/opt/colibri/libexec/colibri/tools"
printf 'import pathlib, sys\npathlib.Path(sys.argv[1], "tokenizer.json").write_text("{}")\n' \
    > "$tree/opt/colibri/libexec/colibri/tools/k3_tokenizer.py"
: > "$log"
rt FAKE_DF_FREE=2000000000000 COLIBRI_MODEL_ID=kimi-k3 -- --model > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail '--model kimi-k3'; }
contains 'Writing tokenizer.json for Kimi K3' "$tmp_root/out"
[[ -f $modeldir/tokenizer.json ]] || fail 'the post-download step did not run before publishing'
contains 'moonshotai/Kimi-K3@f831ab66814297da540d832a5235f8e904f29d06' "$dl_log"
pass 'a model with a post-download step gets it before it is published'

# Too large for the CT: refused before anything changes.
if rt FAKE_DF_FREE=50000000000 COLIBRI_MODEL_ID=glm-5.2 -- --model > "$tmp_root/out" 2>&1; then fail 'a model larger than the disk was accepted'; fi
contains 'glm-5.2 does not fit this CT: needs 429.3 GB disk' "$tmp_root/out"
if rt COLIBRI_MODEL_ID=inkling -- --model > "$tmp_root/out" 2>&1; then fail 'a model larger than the RAM was accepted'; fi
contains 'needs 120 GiB RAM' "$tmp_root/out"
if rt COLIBRI_MODEL_ID=remove COLIBRI_COMMIT=$good -- > "$tmp_root/out" 2>&1; then fail 'remove was accepted without --model'; fi
pass '--model refuses a model the RAM or disk cannot hold, and remove needs --model'

printf '%s Colibri upgrade cases passed. No system files, packages or services were touched.\n' "$passed"
