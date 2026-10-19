#!/usr/bin/env bash
# Whole-script runs of install-target.sh against a temporary tree with stubbed
# git, python venv, cmake, nvcc, curl, systemctl and account tools: install,
# no-op rerun, upgrade, and rollback to the previous commit WITH the previous
# settings, model and unit. Nothing is downloaded, built or started.
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

if (( EUID != 0 )); then
    printf 'SKIP Basalt upgrade cases (install-target.sh needs root)\n'
    exit 0
fi

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/basalt-upgrade-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/basalt-upgrade-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT

# The installer runs from a copy, so a case can ship a changed unit.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
cp "$script_dir/install-target.sh" "$script_dir/basalt.service" "$deploy/"
target=$deploy/install-target.sh
log=$tmp_root/calls.log
printf '#!/usr/bin/env bash\necho "cuda-toolkit.sh $* CUDA_VERSION=$CUDA_VERSION" >> "%s"\n[[ ${1:-} == --check && ${FAKE_CUDA_UNAVAILABLE:-0} == 1 ]] && { echo "NVIDIA repository lacks it" >&2; exit 1; }\n[[ -z ${1:-} && ${FAKE_TOOLKIT_FAIL:-0} == 1 ]] && { echo "toolkit install failed" >&2; exit 1; }\nexit 0\n' "$log" > "$tmp_root/cuda-toolkit.sh"

bin=$tmp_root/bin; mkdir -p "$bin"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub getent 'exit 2'
stub mv 'if [[ ${FAKE_METADATA_FAIL:-0} == 1 && ${*: -1} == */installed-settings ]]; then exit 1; fi; exec /usr/bin/mv "$@"'
stub od 'if [[ ${FAKE_KEY_FAIL:-0} == 1 ]]; then printf "partial"; exit 1; fi; exec /usr/bin/od "$@"'
for command_name in apt-get groupadd useradd usermod chown sleep nvidia-smi g++ make openssl; do stub "$command_name" 'exit 0'; done
stub dpkg-query 'printf "install ok installed"'
stub stat 'if [[ $1 == -c && $2 == %G ]]; then echo "${FAKE_GROUP:-video}"; else exec /usr/bin/stat "$@"; fi'
stub systemctl 'case "$1" in is-failed) exit 1;; is-active) exit "${FAKE_INACTIVE:-0}";; esac; exit 0'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub nvcc 'echo "Cuda compilation tools, release 13.1, V13.1.88"'
# /health: loaded=true unless FAKE_READY=0.
stub curl 'url=${@: -1}
case $url in
    */health) if [[ ${FAKE_READY:-1} == 1 ]]; then echo "{\"status\":\"ok\",\"loaded\":true,\"service\":\"basalt\"}"; else echo "{\"status\":\"ok\",\"loaded\":false}"; fi ;;
    *) echo "unexpected download: $url" >&2; exit 22 ;;
esac'
# python3 -m venv: a fake venv whose python/pip only log.
stub python3 'if [[ $1 == -m && $2 == venv ]]; then
    mkdir -p "$3/bin"
    for t in python pip; do printf "#!/bin/sh\necho \"venv-$t \$*\" >> %s\n" "'"$log"'" > "$3/bin/$t"; chmod +x "$3/bin/$t"; done
    exit 0
fi
exec /usr/bin/python3 "$@"'
# cmake: the build fails on FAKE_BAD_COMMIT, otherwise writes bin/basalt.
stub cmake 'case $1 in
    --version) echo "cmake version 3.28.3" ;;
    --build) [[ $(< .git/HEAD) != "${FAKE_BAD_COMMIT:-none}" ]] || { rm -f .venv/rollback-marker; echo broken > runtime-from-failed-upgrade; echo "build failed" >&2; exit 1; }
             mkdir -p bin; printf "#!/bin/sh\n" > bin/basalt; chmod +x bin/basalt ;;
esac
exit 0'
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
        echo "\$want" > "\$dir/.git/HEAD" ;;
    rev-parse) if [[ \$2 == FETCH_HEAD* ]]; then cat "\$dir/.git/FETCH"; else cat "\$dir/.git/HEAD"; fi ;;
esac
STUB
chmod +x "$bin/git"

tree=$tmp_root/tree
dev=$tmp_root/dev
reset_tree() {
    rm -rf "$tree" "$dev"
    mkdir -p "$tree/etc/systemd/system" "$tree/var/lib/basalt/models" "$dev"
    touch "$dev/nvidia0" "$dev/nvidiactl" "$dev/nvidia-uvm"
    # Two models already downloaded (sparse, but past the 1 GB sanity floor).
    truncate -s 2G "$tree/var/lib/basalt/models/old.basalt" "$tree/var/lib/basalt/models/new.basalt"
    : > "$log"
}
run_target() {
    env PATH="$bin:$PATH" CUDA_TOOLKIT_SH="$tmp_root/cuda-toolkit.sh" \
        BASALT_DIR="$tree/opt/basalt" BASALT_DATA_DIR="$tree/var/lib/basalt" \
        BASALT_ETC_DIR="$tree/etc/basalt-target" BASALT_STATE_DIR="$tree/var/lib/basalt-target" UNIT_DIR="$tree/etc/systemd/system" \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" BASALT_READY_TIMEOUT=5 \
        BASALT_MODEL="${BASALT_MODEL:-old.basalt}" BASALT_PORT="${BASALT_PORT:-8080}" \
        BASALT_COMMIT="${BASALT_COMMIT-}" \
        bash "$target" "$@"
}
contains() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }
unit=$tree/etc/systemd/system/basalt.service
launcher=$tree/opt/basalt/run-basalt.sh
etc=$tree/etc/basalt-target

good=0123456789abcdef0123456789abcdef01234567
bad=fedcba9876543210fedcba9876543210fedcba98

reset_tree
BASALT_COMMIT=$good run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
cmp -s "$unit" "$script_dir/basalt.service" || fail 'unit not installed'
contains "BASALT_RUN_SCRIPT=$launcher" "$etc/basalt.env"
contains "$tree/var/lib/basalt/models/old.basalt" "$launcher"
contains 'BASALT_MODEL=old.basalt' "$etc/installed-env"
contains 'BASALT_PORT=8080' "$etc/installed-env"
[[ ! -e $etc/installed.service ]] || fail 'the unused installed.service record was written'
key=$(< "$etc/api-key")
grep -q -- "$key" "$etc/installed-env" && fail 'the key is in the settings record'
grep -q -- "$key" "$tmp_root/out" && fail 'the key was printed'
pass 'a fresh install records its settings, without the key'

: > "$log"
BASALT_COMMIT=$good run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'no-op rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged rerun stopped the service'
pass 'an unchanged, healthy install is left running'

: > "$log"
cp "$etc/installed-env" "$tmp_root/env-before"
out=$(FAKE_CUDA_UNAVAILABLE=1 BASALT_COMMIT=$bad run_target --upgrade 2>&1) && fail 'an unavailable CUDA release was accepted'
[[ $out == *'is not available for this CT'* ]] || fail "unavailable CUDA message: $out"
grep -qE 'systemctl (stop|restart)|git .*fetch' "$log" && fail "a refused CUDA release touched the target: $(cat "$log")"
cmp -s "$etc/installed-env" "$tmp_root/env-before" || fail 'a refused CUDA release changed the settings record'
pass 'a CUDA release the CT cannot get is refused before anything is fetched or stopped'

: > "$log"
if FAKE_FETCH_FAIL=1 BASALT_COMMIT=$bad run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade without network reported success'
fi
contains 'was not stopped or changed' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'a failed fetch stopped the service'
pass 'a failed fetch leaves the running service untouched'

# The attempted upgrade changes the commit, the model, the port and the unit,
# and its build fails.
printf 'previous runtime\n' > "$tree/opt/basalt/.venv/rollback-marker"
cp "$unit" "$tmp_root/good.service"
cp "$launcher" "$tmp_root/good-launcher"
cp "$etc/installed-settings" "$tmp_root/good-settings"
printf '# changed by the attempted upgrade\n' >> "$deploy/basalt.service"
: > "$log"
if FAKE_BAD_COMMIT=$bad BASALT_COMMIT=$bad BASALT_MODEL=new.basalt BASALT_PORT=11434 \
        run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
cp "$script_dir/basalt.service" "$deploy/basalt.service"
contains "Basalt is running $good again" "$tmp_root/out"
contains 'Restoring the settings it last ran with' "$tmp_root/out"
[[ $(< "$tree/opt/basalt/.git/HEAD") == "$good" ]] || fail 'rollback did not restore the commit'
cmp -s "$launcher" "$tmp_root/good-launcher" || fail "rollback launcher differs: $(cat "$launcher")"
contains '--port 8080' "$launcher"
grep -q 'new.basalt' "$launcher" && fail 'rollback launches the attempted model'
cmp -s "$unit" "$tmp_root/good.service" || fail 'rollback kept the attempted unit'
cmp -s "$etc/installed-settings" "$tmp_root/good-settings" || fail 'a failed upgrade changed the record'
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "the rollback was not checked on the recorded port: $(grep '^curl ' "$log" | tail -n1)"
[[ ! -e $tree/var/lib/basalt-target/rollback-runtime.tar ]] || fail 'the snapshot was kept after a successful rollback'
[[ $(grep -c '^git .* fetch ' "$log") == 1 ]] || fail 'rollback fetched again instead of using the local commit'
contains "update-ref refs/basalt/previous $good" "$log"
: > "$log"
BASALT_COMMIT=$good run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun after rollback'; }
contains 'nothing to do' "$tmp_root/out"
[[ $(cat "$tree/opt/basalt/.venv/rollback-marker") == 'previous runtime' ]] || fail 'venv not restored'
[[ ! -e $tree/opt/basalt/runtime-from-failed-upgrade ]] || fail 'failed runtime file survived'
awk '/^git .* reset / {restoring=1;next} restoring && /^venv-|^cmake / {exit 1}' "$log" || fail 'rollback rebuilt or ran pip'
pass 'rollback restores the previous commit, settings, model and unit, offline'

: > "$log"
next=123456789abcdef0123456789abcdef012345678
printf 'legacy\n' > "$etc/rollback-runtime.tar"; printf 'legacy\n' > "$etc/rollback.env"
BASALT_COMMIT=$next BASALT_MODEL=new.basalt run_target --upgrade > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'upgrade with a new model'; }
[[ ! -e $tree/var/lib/basalt-target/rollback-runtime.tar && ! -e $tree/var/lib/basalt-target/rollback.env ]] || fail 'the snapshot was kept after a successful upgrade'
[[ ! -e $etc/rollback-runtime.tar && ! -e $etc/rollback.env ]] || fail 'a snapshot left in /etc by an earlier revision was not removed'
[[ $(stat -c %a "$tree/var/lib/basalt-target") == 700 ]] || fail 'the snapshot directory is not root-only'
contains "Basalt is running $next" "$tmp_root/out"
contains "$tree/var/lib/basalt/models/new.basalt" "$launcher"
contains 'BASALT_MODEL=new.basalt' "$etc/installed-env"
pass 'a successful upgrade switches model and records the new settings'

rm -f "$etc/installed-env"
: > "$log"
BASALT_MODEL=new.basalt BASALT_COMMIT=$next run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'legacy migration'; }
[[ -f $etc/installed-env ]] || fail 'a healthy legacy rerun did not backfill its settings'
grep -q 'systemctl stop' "$log" && fail 'legacy migration stopped the service'
pass 'a healthy legacy rerun backfills rollback records without restarting'

rm -f "$etc/installed-env"
: > "$log"
if FAKE_BAD_COMMIT=$bad BASALT_COMMIT=$bad BASALT_MODEL=new.basalt BASALT_PORT=11434 run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'a failed upgrade reported success'
fi
contains 'No record of the previous settings' "$tmp_root/out"
contains "Basalt is running $next again" "$tmp_root/out"
[[ $(grep '^curl ' "$log" | tail -n1) == *':8080/'* ]] || fail "a legacy rollback was not checked on the fingerprint's port: $(grep '^curl ' "$log" | tail -n1)"
pass 'an install without a settings record still rolls back, from its runtime snapshot'

: > "$log"
if FAKE_READY=0 FAKE_BAD_COMMIT=$bad BASALT_COMMIT=$bad BASALT_MODEL=new.basalt run_target --upgrade > "$tmp_root/out" 2>&1; then
    fail 'an upgrade and rollback that never became healthy reported success'
fi
contains "Rollback to $next failed too" "$tmp_root/out"
contains 'the snapshot is kept in' "$tmp_root/out"
[[ -s $tree/var/lib/basalt-target/rollback-runtime.tar ]] || fail 'a failed rollback removed the snapshot'
pass 'a rollback that does not become healthy is reported, and its snapshot kept'


# Unlike run_target's explicit defaults, this is the documented bare --upgrade.
saved_upgrade() {
    env -i PATH="$bin:$PATH" CUDA_TOOLKIT_SH="$tmp_root/cuda-toolkit.sh" \
        BASALT_DIR="$tree/opt/basalt" BASALT_DATA_DIR="$tree/var/lib/basalt" \
        BASALT_ETC_DIR="$tree/etc/basalt-target" BASALT_STATE_DIR="$tree/var/lib/basalt-target" \
        UNIT_DIR="$tree/etc/systemd/system" BASALT_READY_TIMEOUT=5 \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        BASALT_COMMIT="$(< "$tree/opt/basalt/.git/HEAD")" \
        "$@" bash "$target" --upgrade
}
reset_tree
BASALT_PORT=8123 BASALT_MODEL=new.basalt BASALT_CONTEXT=65536 BASALT_ALIAS=custom CUDA_VERSION=13.1 run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'custom install before saved-settings upgrade'; }
record=$tree/etc/basalt-target/installed-env
cp "$record" "$tmp_root/custom-settings"
: > "$log"
saved_upgrade > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'bare upgrade with saved settings'; }
cmp -s "$record" "$tmp_root/custom-settings" || fail 'bare upgrade reset saved settings'
contains 'nothing to do' "$tmp_root/out"
grep -q 'systemctl stop' "$log" && fail 'an unchanged saved-settings upgrade stopped the service'
pass 'a bare --upgrade preserves custom settings and leaves an unchanged service running'
saved_upgrade BASALT_PORT=8124 > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'saved-settings explicit override'; }
sed 's/^BASALT_PORT=.*/BASALT_PORT=8124/' "$tmp_root/custom-settings" > "$tmp_root/expected-settings"
cmp -s "$record" "$tmp_root/expected-settings" || fail 'an explicit override reset another saved setting'
pass 'an explicit upgrade setting overrides only that saved value'
cp "$record" "$tmp_root/valid-settings"
sed -i 's/^BASALT_PORT=.*/BASALT_PORT=99999/' "$record"
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
    env -i PATH="$bin:$PATH" CUDA_TOOLKIT_SH="$tmp_root/cuda-toolkit.sh" \
        BASALT_DIR="$tree/opt/basalt" BASALT_DATA_DIR="$tree/var/lib/basalt" \
        BASALT_ETC_DIR="$tree/etc/basalt-target" BASALT_STATE_DIR="$tree/var/lib/basalt-target" \
        UNIT_DIR="$tree/etc/systemd/system" BASALT_READY_TIMEOUT=5 \
        GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" \
        BASALT_COMMIT="$(< "$tree/opt/basalt/.git/HEAD")" \
        bash "$target"
}
cp "$record" "$tmp_root/current-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'plain rerun with saved settings'; }
cmp -s "$record" "$tmp_root/current-settings" || fail "a plain rerun reset saved settings: $(tr '\n' ' ' < "$record")"
contains 'nothing to do' "$tmp_root/out"
pass 'a plain rerun (no --upgrade) keeps the saved settings'

: > "$log"
saved_upgrade BASALT_PORT= > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'upgrade with an empty port'; }
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
cp "$tree/etc/basalt-target/installed-settings" "$tmp_root/fingerprint"
sed -i '/^port=/d' "$tree/etc/basalt-target/installed-settings"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'an unreadable fingerprint fell back to defaults'; fi
contains 'Cannot read this installation' "$tmp_root/out"
[[ ! -s $log ]] || fail 'an unreadable fingerprint touched the installation'
mv "$tmp_root/fingerprint" "$tree/etc/basalt-target/installed-settings"
cp "$tmp_root/current-settings" "$record"
pass 'an unreadable fingerprint is refused before anything runs, unless every setting is given'


# Lost metadata must not turn a configured target into a fresh installation.
cp "$record" "$tmp_root/recovery-settings"
rm -f "$record" "$tree/etc/basalt-target/installed-settings"
for metadata_state in missing dangling; do
    if [[ $metadata_state == dangling ]]; then
        ln -s "$tree/etc/basalt-target/missing-fingerprint" "$tree/etc/basalt-target/installed-settings"
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
    rm -f "$tree/etc/basalt-target/installed-settings"
done
pass 'missing and dangling settings records are refused before a plain rerun or upgrade changes anything'

# Either a checkout or a unit is enough evidence to protect existing settings.
mv "$unit" "$tmp_root/recovery-unit"
: > "$log"
if saved_rerun > "$tmp_root/out" 2>&1; then fail 'a checkout without metadata was treated as fresh'; fi
contains 'Found an existing' "$tmp_root/out"
[[ ! -s $log ]] || fail 'a checkout without metadata was changed'
mv "$tmp_root/recovery-unit" "$unit"
mv "$tree/opt/basalt/.git" "$tmp_root/recovery-git"
# The fixture's runner reads HEAD; use the installer directly for a unit-only target.
if env -i PATH="$bin:$PATH" BASALT_DIR="$tree/opt/basalt" \
        BASALT_DATA_DIR="$tree/var/lib/basalt" BASALT_ETC_DIR="$tree/etc/basalt-target" \
        UNIT_DIR="$tree/etc/systemd/system" bash "$target" > "$tmp_root/out" 2>&1; then
    fail 'a unit without metadata was treated as fresh'
fi
contains 'Found an existing' "$tmp_root/out"
[[ ! -s $log ]] || fail 'a unit without metadata was changed'
mv "$tmp_root/recovery-git" "$tree/opt/basalt/.git"
pass 'an existing checkout or unit is protected independently of the settings records'

# Recovery is possible only with every non-empty setting supplied explicitly.
mapfile -t recovery_settings < "$tmp_root/recovery-settings"
saved_upgrade "${recovery_settings[@]}" > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'explicit recovery from missing metadata'; }
cmp -s "$record" "$tmp_root/recovery-settings" || fail 'explicit recovery changed a setting'
[[ -s $tree/etc/basalt-target/installed-settings ]] || fail 'explicit recovery did not recreate the fingerprint'
pass 'complete explicit settings recover lost metadata without resetting custom values'


# A first install that stops part-way leaves a checkout but no settings record.
# A rerun resumes with the settings it was started with (pending-env, written
# before the first change), never with the defaults, and drops it on success.
reset_tree
pbad=fedcba9876543210fedcba9876543210fedcba98
if FAKE_BAD_COMMIT=$pbad BASALT_COMMIT=$pbad BASALT_PORT=8123 BASALT_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a first install whose setup fails reported success'
fi
pending=$tree/etc/basalt-target/pending-env
[[ -f $pending && ! -e $record ]] || fail 'an interrupted first install left no pending-env, or a settings record'
[[ $(stat -c %a "$pending") == 600 ]] || fail 'pending-env is not root-only'
contains 'BASALT_PORT=8123' "$pending"
cp "$pending" "$tmp_root/started-settings"
: > "$log"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming the interrupted install'; }
contains 'Resuming an interrupted install' "$tmp_root/out"
cmp -s "$record" "$tmp_root/started-settings" ||
    fail "the resumed install did not keep its settings: $(tr '\n' ' ' < "$record")"
[[ ! -e $pending ]] || fail 'pending-env was left after a successful install'
pass 'an interrupted first install resumes with the settings it was started with'

# A first install that stops before it has a checkout (here: the CUDA toolkit
# install fails) leaves only pending-env; that alone marks the installation and
# its settings, so the rerun does not start over with the defaults.
reset_tree
if FAKE_TOOLKIT_FAIL=1 BASALT_COMMIT=$good BASALT_PORT=8123 BASALT_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a first install whose toolkit install fails reported success'
fi
[[ -f $pending && ! -e $tree/opt/basalt/.git ]] || fail 'expected only pending-env after an early failure'
cp "$pending" "$tmp_root/started-settings"
env -i PATH="$bin:$PATH" CUDA_TOOLKIT_SH="$tmp_root/cuda-toolkit.sh" \
    BASALT_DIR="$tree/opt/basalt" BASALT_DATA_DIR="$tree/var/lib/basalt" \
    BASALT_ETC_DIR="$tree/etc/basalt-target" BASALT_STATE_DIR="$tree/var/lib/basalt-target" \
    UNIT_DIR="$tree/etc/systemd/system" BASALT_READY_TIMEOUT=5 \
    GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" BASALT_COMMIT=$good \
    bash "$target" > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming after an early failure'; }
contains 'Resuming an interrupted install' "$tmp_root/out"
cmp -s "$record" "$tmp_root/started-settings" || fail "the early-failure resume lost its settings: $(tr '\n' ' ' < "$record")"
pass 'a first install that failed before its checkout also resumes with its settings'

# Even API-key creation can fail before a checkout exists. The settings must
# already be checkpointed, and partial key output must not become an API key.
reset_tree
if FAKE_KEY_FAIL=1 BASALT_COMMIT=$good BASALT_PORT=8123 BASALT_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed API-key generator reported success'
fi
[[ -f $pending && ! -e $tree/opt/basalt/.git && ! -e $tree/etc/basalt-target/api-key ]] ||
    fail 'key failure lost its checkpoint or published a partial key'
contains 'BASALT_PORT=8123' "$pending"
contains 'BASALT_CONTEXT=65536' "$pending"
cp "$pending" "$tmp_root/started-settings"
env -i PATH="$bin:$PATH" CUDA_TOOLKIT_SH="$tmp_root/cuda-toolkit.sh" \
    BASALT_DIR="$tree/opt/basalt" BASALT_DATA_DIR="$tree/var/lib/basalt" \
    BASALT_ETC_DIR="$tree/etc/basalt-target" BASALT_STATE_DIR="$tree/var/lib/basalt-target" \
    UNIT_DIR="$tree/etc/systemd/system" BASALT_READY_TIMEOUT=5 \
    GPU_NODES="$dev/nvidia[0-9]* $dev/nvidiactl $dev/nvidia-uvm" BASALT_COMMIT=$good \
    bash "$target" > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming after API-key failure'; }
cmp -s "$record" "$tmp_root/started-settings" || fail 'key-failure resume lost custom settings'
[[ ! -e $pending ]] || fail 'key-failure resume retained checkpoint'
pass 'API-key failure before checkout preserves settings for a bare retry'

# Interrupt promotion between its two renames. installed-env is published
# first and the fingerprint last, so the settings are complete and only the
# "nothing to do" marker is missing; pending-env stays until both are in place.
reset_tree
if FAKE_METADATA_FAIL=1 BASALT_PORT=8123 BASALT_CONTEXT=65536 run_target > "$tmp_root/out" 2>&1; then
    fail 'a failed fingerprint rename reported success'
fi
[[ -f $pending && -s $record && ! -e $tree/etc/basalt-target/installed-settings ]] ||
    fail 'failed metadata promotion lost its complete recovery records'
cp "$pending" "$tmp_root/started-settings"
saved_rerun > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'resuming after metadata publication failure'; }
cmp -s "$record" "$tmp_root/started-settings" || fail 'metadata-failure resume lost custom settings'
[[ ! -e $pending ]] || fail 'metadata-failure resume retained checkpoint'
pass 'a bare rerun recovers settings after interruption between metadata renames'

bash "$script_dir/../../tests/lib/check-target-records.sh" "$script_dir/install-target.sh" "$tmp_root/record-failures" ||
    fail 'atomic settings record failure tests'
pass 'failed and interrupted metadata writes preserve complete settings records'

printf '%s Basalt upgrade cases passed. No system files, packages or services were touched.\n' "$passed"
