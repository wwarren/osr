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
    write_build_info set_aside restore_aside ensure_env_key target_healthy; do
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
stub systemctl 'case "$1" in show) echo not-found;; is-active) exit "${FAKE_ACTIVE_RC:-0}";; esac; exit 0'
stub curl '[[ ${FAKE_HEALTH:-ok} == ok ]]'
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
        FORCE_REBUILD="${FORCE_REBUILD:-false}" UPGRADE_HEALTH_TIMEOUT=10 \
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

make_install newcommit
out=$(upgrade 2>&1) || die "same-commit upgrade failed: $out"
[[ $out == *'not rebuilding'* ]] || die 'same commit was rebuilt'
! grep -q 'cmake' "$log" || die 'cmake ran for an unchanged commit'
cmp -s "$script_dir/bridge.py" "$tmp_root/opt/bridge.py" || die 'bridge.py not refreshed on a bridge-only upgrade'
pass 'unchanged llama.cpp commit: bridge-only upgrade, no rebuild'

make_install
FAKE_HEALTH=down upgrade >/dev/null 2>&1 && die 'an unhealthy upgrade reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die 'binary not rolled back'
[[ $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'bridge.py not rolled back'
[[ -f $tmp_root/opt/venv/marker ]] || die 'venv not rolled back'
grep -q '^resolved_commit=oldcommit$' "$tmp_root/opt/build-info.txt" || die 'build-info not rolled back'
[[ $(cat "$tmp_root/units/llama-server.service") == 'old unit' ]] || die 'unit not rolled back'
[[ ! -e $tmp_root/opt/bin/llama-server.prev ]] || die 'rollback left a .prev behind'
pass 'unhealthy upgrade: everything is rolled back and restarted'

make_install
FAKE_BUILD=fail upgrade >/dev/null 2>&1 && die 'a failed build reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' && $(cat "$tmp_root/opt/bridge.py") == 'old bridge' ]] || die 'failed build changed the install'
pass 'failed build: installation untouched'

make_install
echo 'stale from an earlier upgrade' > "$tmp_root/opt/bin/llama-server.prev"
FAKE_COMMIT=oldcommit FAKE_PIP=fail upgrade >/dev/null 2>&1 && die 'a failed pip install reported success'
[[ $("$tmp_root/opt/bin/llama-server") == 'version old' ]] || die 'a stale .prev was restored over the untouched binary'
pass 'rollback restores only what this run replaced'

make_install
FAKE_ACTIVE_RC=3 upgrade >/dev/null 2>&1 || die 'upgrade of stopped services failed'
! grep -q 'systemctl restart' "$log" || die 'stopped services were started'
pass 'stopped services stay stopped'

rm -rf "$tmp_root/opt/bin/llama-server"
upgrade >/dev/null 2>&1 && die 'upgrade without an installation succeeded'
pass 'upgrade refuses a target that is not installed'

printf '%s upgrade cases passed. No system files, builds or services were touched.\n' "$passed"
