#!/usr/bin/env bash
# Exercise install-target.sh --upgrade end to end against a temporary target
# tree. git, cmake, systemctl, curl, python3 and friends are stubs; nothing is
# built, installed system-wide, downloaded or restarted.
set -Eeuo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/llama-target-upgrade-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/llama-target-upgrade-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Build and upgrade helpers/ { capture=1; next }
    /^# End build and upgrade helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in valid_extra_args build_info fetch_llama_source build_llama_server install_bridge \
    write_build_info set_aside copy_aside restore_aside ensure_env_key target_healthy upgrade_unchanged; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done

valid_extra_args '--flash-attn on --cache-type-k q8_0' || die 'flags rejected'
valid_extra_args '' || die 'empty flags rejected'
! valid_extra_args '--x;reboot' || die 'metacharacters accepted'
! valid_extra_args '$(id)' || die 'substitution accepted'
pass 'LLAMA_EXTRA_ARGS validation'

TARGET_ROOT=$tmp_root/h; mkdir -p "$TARGET_ROOT"
printf 'requested_ref=v1\nresolved_commit=abc\nbackend=cpu\n' > "$TARGET_ROOT/build-info.txt"
[[ $(build_info backend) == cpu && $(build_info resolved_commit) == abc && -z $(build_info nope) ]] || die 'build_info'
pass 'build_info reads keys'

echo old > "$TARGET_ROOT/f"; echo older > "$TARGET_ROOT/f.prev"
set_aside "$TARGET_ROOT/f"; echo new > "$TARGET_ROOT/f"
[[ $(cat "$TARGET_ROOT/f.prev") == old ]] || die 'set_aside did not replace an older .prev'
restore_aside "$TARGET_ROOT/f"
[[ $(cat "$TARGET_ROOT/f") == old && ! -e $TARGET_ROOT/f.prev ]] || die 'restore_aside'
set_aside "$TARGET_ROOT/missing"; restore_aside "$TARGET_ROOT/missing"
pass 'set_aside / restore_aside round trip'

echo old > "$TARGET_ROOT/g"
copy_aside "$TARGET_ROOT/g"; echo edited >> "$TARGET_ROOT/g"
[[ $(cat "$TARGET_ROOT/g.prev") == old ]] || die 'copy_aside did not keep the original'
restore_aside "$TARGET_ROOT/g"
[[ $(cat "$TARGET_ROOT/g") == old && ! -e $TARGET_ROOT/g.prev ]] || die 'copy_aside / restore_aside'
pass 'copy_aside keeps the original for editing in place'

printf 'A=1\n' > "$TARGET_ROOT/env"
ensure_env_key "$TARGET_ROOT/env" A 2; ensure_env_key "$TARGET_ROOT/env" B ''
[[ $(cat "$TARGET_ROOT/env") == $'A=1\nB=' ]] || die 'ensure_env_key'
pass 'ensure_env_key adds, never rewrites'

# --- the full --upgrade run -------------------------------------------------
# install-target.sh insists on root and installs files owned by root.
if (( EUID != 0 )); then
    printf 'SKIP end-to-end upgrade cases (need root; helpers above were tested)\n'
    printf '%s upgrade cases passed. No system files, builds or services were touched.\n' "$passed"
    exit 0
fi
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log; : > "$log"
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub systemd-detect-virt 'echo lxc'
stub getent 'exit 0'
stub sleep 'exit 0'
stub ldd 'echo "	linux-vdso.so.1"'
stub systemctl 'case "$1" in
    show) if [[ $* == *ActiveState* ]]; then
              if [[ -n ${FAKE_ACTIVE_STATE:-} ]]; then echo "$FAKE_ACTIVE_STATE"
              elif [[ ${FAKE_ACTIVE_RC:-0} == 0 ]]; then echo active; else echo inactive; fi
          else echo not-found; fi ;;
    is-active) [[ ${FAKE_ACTIVE_STATE:-} == failed ]] && exit 3; exit "${FAKE_ACTIVE_RC:-0}" ;;
esac; exit 0'
# FAKE_HEALTH: ok, down, or old-only (only the previous build answers).
stub curl 'case ${FAKE_HEALTH:-ok} in ok) exit 0;; old-only) "$TARGET_ROOT/bin/llama-server" | grep -q "version old";; *) exit 1;; esac'
stub git 'case "$*" in *"init -q "*) mkdir -p "${@: -1}";; *rev-parse*) echo "$FAKE_COMMIT";; esac; exit 0'
stub cmake 'if [[ $1 == --build ]]; then mkdir -p "$2/bin"; printf "#!/bin/sh\necho version $FAKE_COMMIT\n" > "$2/bin/llama-server"; chmod +x "$2/bin/llama-server"; fi; [[ ${FAKE_BUILD:-ok} == ok ]]'
# python3 -m venv DIR creates a venv whose python accepts pip / py_compile.
stub python3 'if [[ $1 == -m && $2 == venv ]]; then mkdir -p "$3/bin"; printf "#!/bin/sh\necho \"venv-python \$*\" >> %s\n[ \"\${FAKE_PIP:-ok}\" = ok ]\n" "'"$log"'" > "$3/bin/python"; chmod +x "$3/bin/python"; fi'

make_install() {
    rm -rf "${tmp_root:?}/opt" "${tmp_root:?}/etc" "${tmp_root:?}/units"
    mkdir -p "$tmp_root/opt/bin" "$tmp_root/opt/src" "$tmp_root/opt/venv/bin" "$tmp_root/etc" "$tmp_root/units" "$tmp_root/run"
    printf '#!/bin/sh\necho version old\n' > "$tmp_root/opt/bin/llama-server"; chmod +x "$tmp_root/opt/bin/llama-server"
    echo 'old bridge' > "$tmp_root/opt/bridge.py"; echo 'old venv' > "$tmp_root/opt/venv/marker"
    printf 'requested_ref=v0.4.0\nresolved_commit=%s\nbackend=cpu\n' "${1:-oldcommit}" > "$tmp_root/opt/build-info.txt"
    printf 'MODEL_PATH=/m.gguf\nMODEL_ALIAS=m:latest\n' > "$tmp_root/etc/llama-server.env"
    printf 'MODEL_ALIAS=m:latest\n' > "$tmp_root/etc/bridge.env"
    echo 'old unit' > "$tmp_root/units/llama-server.service"
    printf 'ID=debian\nVERSION_ID=12\n' > "$tmp_root/os-release"
    : > "$log"
}
upgrade() {
    env -i "PATH=$bin:/usr/bin:/bin" TARGET_ROOT="$tmp_root/opt" TARGET_ETC="$tmp_root/etc" \
        TARGET_UNITS="$tmp_root/units" SYSTEMD_RUN_DIR="$tmp_root/run" OS_RELEASE_FILE="$tmp_root/os-release" \
        LLAMA_CPP_REF=v0.5.0 FAKE_COMMIT="${FAKE_COMMIT:-newcommit}" FAKE_HEALTH="${FAKE_HEALTH:-ok}" \
        FAKE_BUILD="${FAKE_BUILD:-ok}" FAKE_PIP="${FAKE_PIP:-ok}" FAKE_ACTIVE_RC="${FAKE_ACTIVE_RC:-0}" \
        BACKEND="${BACKEND:-}" FAKE_ACTIVE_STATE="${FAKE_ACTIVE_STATE:-}" \
        FORCE_REBUILD="${FORCE_REBUILD:-false}" UPGRADE_HEALTH_TIMEOUT=10 \
        GPU_LAYERS="${GPU_LAYERS:-}" CUDA_COMPILER="${CUDA_COMPILER:-}" \
        bash "$script_dir/install-target.sh" --upgrade
}

make_install
out=$(upgrade 2>&1) || die "healthy upgrade failed: $out"
[[ $("$tmp_root/opt/bin/llama-server") == 'version newcommit' ]] || die 'new binary not installed'
[[ $(cat "$tmp_root/opt/bin/llama-server.prev") == *'version old'* ]] || die 'old binary not kept as .prev'
grep -q '^resolved_commit=newcommit$' "$tmp_root/opt/build-info.txt" || die 'build-info not updated'
grep -q '^backend=cpu$' "$tmp_root/opt/build-info.txt" || die 'backend not carried over'
grep -q '^LLAMA_EXTRA_ARGS=$' "$tmp_root/etc/llama-server.env" || die 'LLAMA_EXTRA_ARGS not added'
grep -q '^MODEL_PATH=/m.gguf$' "$tmp_root/etc/llama-server.env" || die 'existing settings touched'
cmp -s "$script_dir/bridge.py" "$tmp_root/opt/bridge.py" || die 'bridge.py not refreshed'
cmp -s "$script_dir/llama-server.service" "$tmp_root/units/llama-server.service" || die 'unit not refreshed'
grep -q 'systemctl restart llama-server.service llama-ollama-bridge.service' "$log" || die 'services not restarted'
pass 'healthy upgrade: rebuilds, refreshes bridge and units, keeps settings, restarts'

# A second upgrade to the same ref, bridge, units and settings changes nothing.
: > "$log"
cp "$tmp_root/opt/bin/llama-server.prev" "$tmp_root/prev-before"
out=$(upgrade 2>&1) || die "unchanged upgrade failed: $out"
[[ $out == *'unchanged and the target is healthy; nothing to do'* ]] || die "unchanged upgrade did work: $out"
! grep -qE 'systemctl (stop|restart|start)|cmake|venv-python' "$log" || die "an unchanged upgrade touched the target: $(cat "$log")"
cmp -s "$tmp_root/opt/bin/llama-server.prev" "$tmp_root/prev-before" || die 'an unchanged upgrade replaced the kept .prev'
[[ ! -e $tmp_root/opt/src/llama.cpp.new ]] || die 'the fetched source was left behind'
out=$(FAKE_ACTIVE_RC=3 upgrade 2>&1) || die "unchanged upgrade of stopped services failed: $out"
[[ $out == *'nothing to do (the services stay stopped)'* ]] || die "stopped no-op: $out"
pass 'an unchanged upgrade does nothing, running or stopped, and keeps the previous .prev'

: > "$log"
out=$(FAKE_ACTIVE_STATE=failed upgrade 2>&1) || die "failed service recovery: $out"
grep -q 'systemctl restart' "$log" || die 'a failed service was mistaken for stopped'
pass 'an unchanged failed service is restarted'

: > "$log"
sed -i "s/^backend=cpu$/backend=cuda/" "$tmp_root/opt/build-info.txt"
out=$(BACKEND=cpu upgrade 2>&1) || die "backend change failed: $out"
grep -q 'cmake ' "$log" || die 'a backend change did not rebuild'
grep -q '^backend=cpu$' "$tmp_root/opt/build-info.txt" || die 'backend not recorded'
pass 'a backend change on the same commit rebuilds the executable'


: > "$log"
out=$(FAKE_HEALTH=old-only upgrade 2>&1) && die 'an unhealthy re-apply reported success'
[[ $out == *'not healthy; re-applying'* ]] || die "unhealthy unchanged target was not re-applied: $out"
grep -q 'systemctl restart' "$log" || die 'the re-apply did not restart'
: > "$log"
out=$(FORCE_REBUILD=true upgrade 2>&1) || die "forced rebuild failed: $out"
grep -q 'cmake' "$log" || die 'FORCE_REBUILD=true did not rebuild an unchanged target'
pass 'an unchanged but unhealthy target is re-applied; FORCE_REBUILD=true always rebuilds'

# A backend switch sets GPU_LAYERS for the new backend (the upgrade otherwise
# never rewrites a setting); GPU_LAYERS overrides; a rollback restores it.
printf '#!/bin/sh\necho "Cuda compilation tools, release 13.0"\n' > "$tmp_root/nvcc"; chmod +x "$tmp_root/nvcc"
layers() { sed -n 's/^GPU_LAYERS=//p' "$tmp_root/etc/llama-server.env"; }
make_install
echo 'GPU_LAYERS=0' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) || die "cpu->cuda upgrade failed: $out"
[[ $(layers) == auto ]] || die "cpu->cuda left GPU_LAYERS=$(layers): $out"
[[ $out == *'setting GPU_LAYERS=auto (was 0)'* ]] || die "GPU_LAYERS change not reported: $out"
grep -q '^MODEL_PATH=/m.gguf$' "$tmp_root/etc/llama-server.env" || die 'other settings touched'
make_install
echo 'GPU_LAYERS=0' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cuda GPU_LAYERS=40 CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) || die "cpu->cuda with GPU_LAYERS failed: $out"
[[ $(layers) == 40 ]] || die "GPU_LAYERS=40 not applied: $(layers)"
make_install
sed -i 's/^backend=cpu$/backend=cuda/' "$tmp_root/opt/build-info.txt"
echo 'GPU_LAYERS=auto' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cpu upgrade 2>&1) || die "cuda->cpu upgrade failed: $out"
[[ $(layers) == 0 && $(grep -c '^GPU_LAYERS=' "$tmp_root/etc/llama-server.env") == 1 ]] || die "cuda->cpu left GPU_LAYERS=$(layers)"
make_install
sed -i 's/^backend=cpu$/backend=cuda/' "$tmp_root/opt/build-info.txt"
: > "$log"
out=$(BACKEND=cpu GPU_LAYERS=20 upgrade 2>&1) && die 'a CPU build with GPU layers was accepted'
[[ $out == *'A CPU build requires GPU_LAYERS=0'* ]] || die "cpu GPU_LAYERS message: $out"
grep -qE 'cmake|systemctl (stop|restart)' "$log" && die 'a refused GPU_LAYERS touched the target'
make_install
echo 'GPU_LAYERS=0' >> "$tmp_root/etc/llama-server.env"
cp "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc FAKE_HEALTH=old-only upgrade 2>&1) && die 'an unhealthy backend switch reported success'
cmp -s "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before" || die "rollback kept GPU_LAYERS=$(layers)"
pass 'a backend switch sets GPU_LAYERS for the new backend (GPU_LAYERS overrides), and rollback restores it'
make_install
printf 'GPU_LAYERS=0\n  GPU_LAYERS = 0\n\tGPU_LAYERS = "12"\n' >> "$tmp_root/etc/llama-server.env"
out=$(BACKEND=cuda CUDA_COMPILER=$tmp_root/nvcc upgrade 2>&1) || die "spaced GPU_LAYERS upgrade failed: $out"
[[ $out == *'setting GPU_LAYERS=auto (was 12)'* ]] || die "the message did not show the effective (last) value: $out"
[[ $(layers) == auto ]] || die "spaced GPU_LAYERS was not rewritten: $(layers)"
[[ $(grep -cE '^[[:space:]]*GPU_LAYERS[[:space:]]*=' "$tmp_root/etc/llama-server.env") == 1 ]] ||
    die 'a whitespace-prefixed GPU_LAYERS duplicate survived'
grep -q '^MODEL_PATH=/m.gguf$' "$tmp_root/etc/llama-server.env" || die 'unrelated settings changed'
pass 'a backend switch rewrites whitespace-prefixed settings and drops all duplicates'


make_install newcommit
out=$(upgrade 2>&1) || die "same-commit upgrade failed: $out"
[[ $out == *'not rebuilding'* ]] || die 'same commit was rebuilt'
! grep -q 'cmake' "$log" || die 'cmake ran for an unchanged commit'
cmp -s "$script_dir/bridge.py" "$tmp_root/opt/bridge.py" || die 'bridge.py not refreshed on a bridge-only upgrade'
pass 'unchanged llama.cpp commit: bridge-only upgrade, no rebuild'

make_install
cp "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before"
out=$(FAKE_HEALTH=old-only upgrade 2>&1) && die 'an unhealthy upgrade reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die 'binary not rolled back'
[[ $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'bridge.py not rolled back'
[[ -f $tmp_root/opt/venv/marker ]] || die 'venv not rolled back'
grep -q '^resolved_commit=oldcommit$' "$tmp_root/opt/build-info.txt" || die 'build-info not rolled back'
[[ $(cat "$tmp_root/units/llama-server.service") == 'old unit' ]] || die 'unit not rolled back'
cmp -s "$tmp_root/etc/llama-server.env" "$tmp_root/settings-before" || die 'settings file not rolled back'
[[ ! -e $tmp_root/opt/bin/llama-server.prev && ! -e $tmp_root/etc/llama-server.env.prev ]] || die 'rollback left a .prev behind'
[[ $out == *'the previous installation is running again'* ]] || die "rollback outcome not reported: $out"
pass 'unhealthy upgrade: code, units and settings are rolled back, and the old build is checked healthy'

make_install
out=$(FAKE_HEALTH=down upgrade 2>&1) && die 'an unhealthy upgrade reported success'
[[ $out == *'did not become healthy either'* ]] || die "failed rollback not reported: $out"
pass 'a rollback that does not become healthy is reported as such'

make_install
FAKE_BUILD=fail upgrade >/dev/null 2>&1 && die 'a failed build reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' && $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'failed build changed the install'
pass 'failed build: installation untouched'

make_install
echo 'stale from an earlier upgrade' > "$tmp_root/opt/bin/llama-server.prev"
FAKE_COMMIT=oldcommit FAKE_PIP=fail upgrade >/dev/null 2>&1 && die 'a failed pip install reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die 'a stale .prev was restored over the untouched binary'
pass 'rollback restores only what this run replaced'

# A failure inside a subshell (pip in install_bridge) must not fire the ERR
# trap twice: the second pass would stop the restored services and wait again.
make_install
: > "$log"
out=$(FAKE_PIP=fail upgrade 2>&1) && die 'a failed pip install reported success'
[[ $(grep -c 'restoring the previous installation' <<< "$out") == 1 ]] || die "pip failure rolled back more than once: $out"
[[ $(grep -c '^systemctl start' "$log") == 1 ]] || die "the restored services were restarted more than once: $(grep systemctl "$log")"
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' && $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'pip failure: install not restored'
[[ $out == *'the previous installation is running again'* ]] || die "rollback outcome not reported: $out"
pass 'a failure inside a subshell rolls back exactly once'

make_install
FAKE_ACTIVE_RC=3 upgrade >/dev/null 2>&1 || die 'upgrade of stopped services failed'
! grep -q 'systemctl restart' "$log" || die 'stopped services were started'
make_install
out=$(FAKE_ACTIVE_RC=3 FAKE_PIP=fail upgrade 2>&1) && die 'a failed upgrade of stopped services reported success'
[[ $out == *'services stay stopped as they were'* ]] || die "stopped rollback not reported: $out"
! grep -q 'systemctl start' "$log" || die 'a rollback started services that were stopped'
pass 'stopped services stay stopped, on success and on rollback'

rm -rf "$tmp_root/opt/bin/llama-server"
upgrade >/dev/null 2>&1 && die 'upgrade without an installation succeeded'
pass 'upgrade refuses a target that is not installed'

printf '%s upgrade cases passed. No system files, builds or services were touched.\n' "$passed"
