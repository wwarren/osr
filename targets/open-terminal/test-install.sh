#!/usr/bin/env bash
# Exercise install-target.sh: its helpers, then whole runs against a temporary
# tree with stubbed apt, git, venv/pip, systemctl and curl. Nothing is
# downloaded, installed or started. End-to-end cases need root (like the other
# targets' install tests).
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target=$script_dir/install-target.sh
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/open-terminal-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/open-terminal-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# The dependency check parses pyproject.toml with tomllib (Python 3.11+, as on
# the CT's Debian 12/13). Say so instead of failing on an import error.
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' ||
    fail "python3 is $(python3 -c 'import platform; print(platform.python_version())'); these cases need Python 3.11+ (tomllib)"

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$target")
for helper in deps_mismatch service_env workspace_env limits_conf env_get key_hash clients_has healthy; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done

# pyproject_from REQUIREMENTS_IN [EXTRA]: a pyproject.toml whose dependencies
# are requirements.in's (minus hatchling), plus EXTRA, plus the Windows-only
# dependency upstream lists (which the check ignores).
pyproject_from() {
    {
        printf '[project]\nname = "open-terminal"\ndependencies = [\n'
        sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e '/^hatchling$/d' "$1" |
            while IFS= read -r dep; do printf '    "%s",\n' "$dep"; done
        [[ -z ${2:-} ]] || printf '    "%s",\n' "$2"
        printf '    "pywinpty>=2.0.0; sys_platform == '\''win32'\''",\n]\n'
    }
}
pyproject_from "$script_dir/requirements.in" > "$tmp_root/pyproject.toml"
[[ -z $(deps_mismatch "$tmp_root/pyproject.toml" "$script_dir/requirements.in") ]] ||
    fail 'matching dependencies reported as different'
pyproject_from "$script_dir/requirements.in" 'rich>=13' > "$tmp_root/pyproject.toml"
[[ $(deps_mismatch "$tmp_root/pyproject.toml" "$script_dir/requirements.in") == *'not in requirements.in: rich>=13'* ]] ||
    fail 'a new dependency was not reported'
pass 'dependency drift between the tag and requirements.in is detected'

# shellcheck disable=SC2034  # read by the sourced helpers
PORT=8001 IDLE_MINUTES=30 MAX_ACTIVE=4 WS_MEMORY=2G WS_TASKS=256 WS_CPU=200%
env_text=$(service_env)
[[ $env_text == *$'\nOPEN_TERMINAL_PORT=8001\nOPEN_TERMINAL_IDLE_MINUTES=30\nOPEN_TERMINAL_MAX_ACTIVE=4'* ]] || fail "service env: $env_text"
[[ $env_text != *API_KEY* ]] || fail 'the gateway env must hold no key'
ws_env=$(workspace_env)
grep -qx 'OPEN_TERMINAL_MULTI_USER=false' <<< "$ws_env" || fail 'workspaces must run single-user'
grep -qx 'OPEN_TERMINAL_CORS_ALLOWED_ORIGINS=http://127.0.0.1' <<< "$ws_env" || fail 'CORS must be an explicit origin (empty means *)'
grep -q '^OPEN_TERMINAL_SYSTEM_PROMPT="[^"]*{{os}}[^"]*"$' <<< "$ws_env" || fail 'system prompt must be one quoted line'
[[ $ws_env != *'{{user}}'* && $ws_env != *'{{home}}'* && $ws_env != *API_KEY* ]] ||
    fail 'the shared prompt must not name an account or path, and the shared env no key'
[[ $(limits_conf) == *$'MemoryMax=2G\nTasksMax=256\nCPUQuota=200%' ]] || fail "limits: $(limits_conf)"
printf 'A=1\nOPEN_TERMINAL_PORT=8123\n' > "$tmp_root/env"
[[ $(env_get "$tmp_root/env" OPEN_TERMINAL_PORT) == 8123 && -z $(env_get "$tmp_root/none" X) ]] || fail 'env_get'
printf ' secret-key-value-123 \n' > "$tmp_root/key"
[[ $(key_hash "$tmp_root/key") == "$(printf 'secret-key-value-123' | sha256sum | cut -d' ' -f1)" ]] || fail 'key_hash'
printf '{"clients": {"openwebui": {"key_sha256": "abc"}}}' > "$tmp_root/clients.json"
clients_has "$tmp_root/clients.json" openwebui abc || fail 'clients_has missed the hash'
! clients_has "$tmp_root/clients.json" openwebui abd || fail 'clients_has accepted another hash'
! clients_has "$tmp_root/none.json" openwebui abc || fail 'clients_has accepted a missing file'
pass 'the gateway env holds settings only; workspaces share a single-user env, prompt and limits'

ws_unit=$script_dir/open-terminal-ws@.service
gw_unit=$script_dir/open-terminal-gateway.service
sp_unit=$script_dir/open-terminal-spawner.service
grep -qx 'User=ot-%i' "$ws_unit" || fail 'each workspace runs as its own account'
grep -qx 'EnvironmentFile=/etc/open-terminal/workspace.env' "$ws_unit" || fail 'ws shared env'
grep -qx 'EnvironmentFile=/etc/open-terminal/ws/%i.env' "$ws_unit" || fail 'ws own env file'
grep -q 'OPEN_TERMINAL_API_KEY_FILE=' <(grep -v '^#' "$ws_unit") && fail 'unit sets OPEN_TERMINAL_API_KEY_FILE'
grep -qx 'ExecStart=/opt/open-terminal/venv/bin/open-terminal run --host 127.0.0.1 --port ${OPEN_TERMINAL_PORT} --cwd /srv/open-terminal/ws/%i' "$ws_unit" ||
    fail 'a workspace must listen on loopback only, in its own directory'
for directive in 'ReadWritePaths=/srv/open-terminal/ws/%i' 'ProtectProc=invisible' 'PrivateTmp=true' \
                 'NoNewPrivileges=true' 'CapabilityBoundingSet=' 'ProtectSystem=strict' 'ProtectHome=true'; do
    grep -qx -- "$directive" "$ws_unit" || fail "workspace unit lacks $directive"
done
grep -qx 'User=ot-gateway' "$gw_unit" || fail 'the gateway is unprivileged'
grep -qx 'EnvironmentFile=/etc/open-terminal/service.env' "$gw_unit" || fail 'gateway env'
grep -qx 'Requires=open-terminal-spawner.service' "$gw_unit" || fail 'gateway needs the spawner'
grep -qx 'CapabilityBoundingSet=' "$gw_unit" || fail 'gateway capabilities'
grep -q '^User=' "$sp_unit" && fail 'the spawner runs as root'
grep -qx 'ExecStart=/usr/bin/python3 -I /opt/open-terminal/lib/spawner.py' "$sp_unit" || fail 'spawner ExecStart'
grep -qx 'CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER CAP_DAC_OVERRIDE CAP_AUDIT_WRITE' "$sp_unit" || fail 'the spawner keeps only the capabilities account setup needs'
pass 'units: one sandboxed loopback instance per workspace, an unprivileged gateway, a root spawner'

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
real_python=$(command -v python3)
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for command_name in apt-get useradd sleep; do stub "$command_name" 'exit 0'; done
# systemctl: a unit is active when its file is installed (FAKE_INACTIVE: none
# is). FAKE_RESTART_FAIL fails the gateway's restart on port 8123.
stub systemctl 'case "$1" in
    is-active) [[ -z ${FAKE_INACTIVE:-} && -e $UNIT_DIR/${@: -1} ]] || exit 3 ;;
    restart) if [[ ${FAKE_RESTART_FAIL:-0} == 1 && " $* " == *" open-terminal-gateway.service"* ]] &&
                 grep -qx OPEN_TERMINAL_PORT=8123 "$OT_ETC/service.env"; then exit 1; fi ;;
esac; exit 0'
# install: drop -o/-g (the accounts do not exist here).
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
# curl: healthy unless the active venv belongs to FAKE_BAD_COMMIT.
stub curl 'active=$(readlink "$OT_OPT/venv" 2>/dev/null || true)
[[ -n ${FAKE_BAD_COMMIT:-} && $active == *"/venv-$FAKE_BAD_COMMIT-"* ]] && exit 22
[[ -n ${FAKE_BAD_PORT:-} && ${@: -1} == *":$FAKE_BAD_PORT/health" ]] && exit 22
[[ ${FAKE_DOWN:-0} == 1 ]] && exit 22
printf "{\"status\":\"ok\"}"'
# python3: "-m venv DIR" builds a fake venv whose python logs pip calls and,
# for the final --no-deps install, provides bin/open-terminal. Everything else
# (the version check, the dependency check, open-terminal-clients) is the
# real interpreter.
cat > "$bin/python3" <<STUB
#!/usr/bin/env bash
if [[ \$1 == -m && \$2 == venv ]]; then
    echo "python3 \$*" >> "$log"
    mkdir -p "\$3/bin"
    cat > "\$3/bin/python" <<'PY'
#!/usr/bin/env bash
venv=\$(cd "\$(dirname "\$0")/.." && pwd)
echo "venv-python \$venv \$*" >> "$log"
if [[ " \$* " == *" --no-deps "* ]]; then
    printf '#!/bin/sh\nexit 0\n' > "\$venv/bin/open-terminal"; chmod +x "\$venv/bin/open-terminal"
    [[ \${FAKE_PIP_FAIL:-0} != 1 ]] || exit 1
fi
PY
    chmod +x "\$3/bin/python"
    exit 0
fi
exec "$real_python" "\$@"
STUB
chmod +x "$bin/python3"
# git: the tag resolves to FAKE_TAG_COMMIT (default: the reviewed commit for
# v0.14.0); checkout writes a pyproject.toml matching requirements.in, plus
# FAKE_EXTRA_DEP when set.
default_commit=$(sed -n 's/^DEFAULT_COMMIT=//p' "$target")
cat > "$bin/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >> "$log"
dir=.
while [[ \$1 == -C ]]; do dir=\$2; shift 2; done
case \$1 in
    init) mkdir -p "\${@: -1}/.git" ;;
    remote) : ;;
    fetch) : ;;
    checkout)
        $(declare -f pyproject_from)
        pyproject_from "$script_dir/requirements.in" "\${FAKE_EXTRA_DEP:-}" > "\$dir/pyproject.toml"
        echo "\${FAKE_TAG_COMMIT:-$default_commit}" > "\$dir/.git/HEAD" ;;
    rev-parse) cat "\$dir/.git/HEAD" ;;
esac
STUB
chmod +x "$bin/git"

# Whole-script runs use a copy of the deployment files, so a case can ship a
# changed unit for one attempted upgrade.
deploy=$tmp_root/deploy; mkdir -p "$deploy"
deploy_files=(install-target.sh open-terminal-gateway.service open-terminal-spawner.service open-terminal-ws@.service
              gateway.py spawner.py open-terminal-clients requirements.in requirements.lock)
for f in "${deploy_files[@]}"; do cp "$script_dir/$f" "$deploy/"; done
target=$deploy/install-target.sh
tree=$tmp_root/tree
owui_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
reset_tree() {
    rm -rf "$tree"; mkdir -p "$tree/etc/open-terminal" "$tree/etc/systemd/system" "$tree/opt" "$tree/srv" "$tree/sbin" "$tree/var"
    printf '%s\n' "$owui_key" > "$tree/etc/open-terminal/api-key"
    : > "$log"
}
run_target() {
    env PATH="$bin:$PATH" OT_ETC="$tree/etc/open-terminal" OT_OPT="$tree/opt/open-terminal" \
        OT_SRV="$tree/srv/open-terminal" OT_VAR="$tree/var/open-terminal" UNIT_DIR="$tree/etc/systemd/system" \
        SBIN_DIR="$tree/sbin" GATEWAY_USER=root HEALTH_TIMEOUT=2 bash "$target"
}
contains() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }
export OT_OPT="$tree/opt/open-terminal"
venv_for() {
    printf '%s/venv-%s-%s' "$OT_OPT" "$1" "$(sha256sum "${2:-$script_dir/requirements.lock}" | cut -d' ' -f1)"
}
default_venv=$(venv_for "$default_commit")
envf=$tree/etc/open-terminal/service.env
clients=$tree/etc/open-terminal/clients.json
units=$tree/etc/systemd/system
gw=$units/open-terminal-gateway.service
owui_hash=$(printf '%s' "$owui_key" | sha256sum | cut -d' ' -f1)

reset_tree
chmod 0640 "$tree/etc/open-terminal/api-key"    # the old layout: group-readable
chmod 0700 "$tree/etc/open-terminal"            # the layout that blocked config.toml lookup
out=$(FAKE_DOWN=1 run_target 2>&1) && fail 'an unhealthy first install was accepted'
[[ $out == *'no previous installation was running'* && $out != *'Rollback failed'* ]] ||
    fail "first-install rollback message: $out"
for f in "$envf" "$clients" "$gw" "$units/open-terminal-ws@.service" "$tree/etc/open-terminal/workspace.env" "$OT_OPT/venv"; do
    [[ ! -e $f ]] || fail "failed first install left $f"
done
[[ ! -e $tree/etc/open-terminal/rollback ]] || fail 'a completed rollback left its copies (they include clients.json)'
[[ -f $default_venv/.install-complete ]] || fail 'failed first install lost its reusable built venv'
contains "--require-hashes -r $deploy/requirements.lock" "$log"
contains "--no-deps --no-build-isolation $OT_OPT/source" "$log"
: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
grep -q 'python3 -m venv' "$log" && fail 'retry rebuilt the complete venv'
for f in open-terminal-gateway.service open-terminal-spawner.service open-terminal-ws@.service; do
    cmp -s "$units/$f" "$script_dir/$f" || fail "$f not installed from the repo file"
done
cmp -s "$OT_OPT/lib/gateway.py" "$script_dir/gateway.py" || fail 'gateway.py'
cmp -s "$OT_OPT/lib/spawner.py" "$script_dir/spawner.py" || fail 'spawner.py'
[[ -x $tree/sbin/open-terminal-clients ]] || fail 'open-terminal-clients is not installed executable'
contains 'MemoryMax=1G' "$units/open-terminal-ws@.service.d/50-osr-limits.conf"
[[ $(stat -c '%a %U' "$tree/etc/open-terminal") == '711 root' ]] ||
    fail "config directory mode: $(stat -c '%a %U' "$tree/etc/open-terminal")"
[[ $(stat -c '%a' "$envf") == 600 ]] || fail "service.env mode: $(stat -c '%a' "$envf")"
[[ $(stat -c '%a' "$tree/etc/open-terminal/api-key") == 600 ]] || fail 'api-key is still group-readable'
[[ $(stat -c '%a' "$clients") == 640 ]] || fail "clients.json mode: $(stat -c '%a' "$clients")"
[[ $(stat -c '%a' "$tree/etc/open-terminal/ws") == 700 && $(stat -c '%a' "$tree/srv/open-terminal/ws") == 711 ]] ||
    fail 'workspace key and home directories'
contains 'OPEN_TERMINAL_PORT=8000' "$envf"
contains 'OPEN_TERMINAL_IDLE_MINUTES=120' "$envf"
contains "\"key_sha256\": \"$owui_hash\"" "$clients"
grep -q -- "$owui_key" "$envf" "$clients" && fail 'a key is stored in clear outside api-key'
[[ $(readlink "$OT_OPT/venv") == "$default_venv" ]] || fail 'venv symlink'
contains "fetch -q --depth 1 origin +refs/tags/v0.14.0:refs/tags/v0.14.0" "$log"
[[ $(grep -c '^systemctl restart open-terminal-spawner.service open-terminal-gateway.service$' "$log") == 1 ]] ||
    fail 'the services must be started exactly once'
contains 'systemctl enable open-terminal-spawner.service open-terminal-gateway.service' "$log"
grep -q 'enable --now' "$log" && fail 'enable --now plus restart starts it twice'
grep -q -- '0123456789abcdef0123' "$tmp_root/out" && fail 'the key was printed'
[[ ! -e $tree/etc/open-terminal/rollback ]] || fail 'a successful run left its rollback copies'
pass 'fresh install: hash-locked venv, gateway and spawner, hashed client key, root-only files, one start'

: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun'; }
contains 'already installed with these settings and is healthy; nothing to do' "$tmp_root/out"
grep -qE 'systemctl (restart|daemon-reload|stop)|python3 -m venv' "$log" && fail "an unchanged rerun touched the terminal: $(cat "$log")"
: > "$log"
OPEN_TERMINAL_PORT=8124 OPEN_TERMINAL_IDLE_MINUTES=15 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'settings change'; }
grep -q 'python3 -m venv' "$log" && fail 'a settings change on the same commit rebuilt the venv'
grep -q 'systemctl restart open-terminal-spawner.service open-terminal-gateway.service' "$log" || fail 'a settings change was not applied'
contains "systemctl stop open-terminal-ws@*.service" "$log"
contains 'OPEN_TERMINAL_PORT=8124' "$envf"
: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun with recorded settings'; }
contains 'nothing to do' "$tmp_root/out"
contains 'OPEN_TERMINAL_IDLE_MINUTES=15' "$envf"
OPEN_TERMINAL_PORT=8000 OPEN_TERMINAL_IDLE_MINUTES=120 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'settings back'; }
: > "$log"
FAKE_INACTIVE=3 run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'stopped rerun'; }
grep -q 'systemctl restart open-terminal-spawner.service open-terminal-gateway.service' "$log" || fail 'a stopped terminal was not brought back'
contains 'OPEN_TERMINAL_PORT=8000' "$envf"
grep -q 'python3 -m venv' "$log" && fail 'a rerun of the same commit rebuilt the venv'
pass 'an unchanged rerun does nothing; settings are applied and kept by later runs without rebuilding the venv'

for bad in 'OPEN_TERMINAL_PORT=20001' 'OPEN_TERMINAL_IDLE_MINUTES=soon' 'OPEN_TERMINAL_MAX_ACTIVE=0' \
           'OPEN_TERMINAL_WS_MEMORY=lots' 'OPEN_TERMINAL_WS_CPU=2'; do
    cp "$envf" "$tmp_root/env-before"
    out=$(export "${bad?}"; run_target 2>&1) && fail "accepted $bad"
    [[ $out == *Error:* ]] || fail "$bad: $out"
    cmp -s "$envf" "$tmp_root/env-before" || fail "$bad changed service.env"
done
pass 'invalid ports, limits and timeouts are refused before anything changes'

# A new client key in api-key (a reprovisioned router) is registered; the
# agents' entries in clients.json are kept.
python3 - "$clients" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
data["clients"]["hermes-282"] = {"key_sha256": "a" * 64, "default_user": "default"}
json.dump(data, open(sys.argv[1], "w"))
PY
printf 'fedcba9876543210fedcba9876543210\n' > "$tree/etc/open-terminal/api-key"
: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'new Open WebUI key'; }
contains "\"key_sha256\": \"$(printf 'fedcba9876543210fedcba9876543210' | sha256sum | cut -d' ' -f1)\"" "$clients"
contains '"hermes-282"' "$clients"
printf '%s\n' "$owui_key" > "$tree/etc/open-terminal/api-key"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'old Open WebUI key back'; }
pass 'a changed Open WebUI key is registered and agent clients are kept'

# The same upstream commit with a new lock needs a separate, rollbackable venv.
cp "$deploy/requirements.lock" "$tmp_root/original.lock"
sed -i 's/^click==[0-9.]* /click==99.0.0 /' "$deploy/requirements.lock"
changed_venv=$(venv_for "$default_commit" "$deploy/requirements.lock")
: > "$log"
if out=$(FAKE_BAD_PORT=8123 OPEN_TERMINAL_PORT=8123 run_target 2>&1); then
    fail 'an unhealthy lock-only upgrade reported success'
fi
[[ $out == *'previous Open Terminal is running again'* ]] || fail "lock rollback: $out"
[[ $(readlink "$OT_OPT/venv") == "$default_venv" && -x $default_venv/bin/open-terminal ]] ||
    fail 'lock-only rollback lost the previous environment'
contains "venv-python $changed_venv" "$log"
pass 'a lock-only upgrade builds a separate venv and rolls back on failure'
: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'lock-only upgrade'; }
[[ $(readlink "$OT_OPT/venv") == "$changed_venv" && -d $default_venv ]] ||
    fail 'lock-only upgrade did not switch venvs and retain the old one'
: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'unchanged lock rerun'; }
contains 'nothing to do' "$tmp_root/out"
grep -qE 'python3 -m venv|systemctl restart' "$log" && fail 'an unchanged lock rebuilt or restarted'
pass 'a successful lock-only update switches venvs; the same lock rerun is a no-op'
printf '\n# another lock fixture\n' >> "$deploy/requirements.lock"
partial_venv=$(venv_for "$default_commit" "$deploy/requirements.lock")
: > "$log"
if out=$(FAKE_PIP_FAIL=1 run_target 2>&1); then fail 'a failed package install was accepted'; fi
[[ $(readlink "$OT_OPT/venv") == "$changed_venv" && ! -f $partial_venv/.install-complete ]] ||
    fail 'a failed build changed the active environment or marked itself complete'
: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'retry partial lock build'; }
contains "python3 -m venv $partial_venv" "$log"
[[ $(readlink "$OT_OPT/venv") == "$partial_venv" && -f $partial_venv/.install-complete ]] ||
    fail 'a retry did not finish and activate the rebuilt environment'
pass 'a failed dependency build keeps the active venv; retry rebuilds partial environments'

cp "$tmp_root/original.lock" "$deploy/requirements.lock"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'restore original lock'; }

cp "$envf" "$tmp_root/env-good"
cp "$gw" "$tmp_root/unit-good"
cp "$clients" "$tmp_root/clients-good"
printf '# attempted settings-only unit\n' >> "$deploy/open-terminal-gateway.service"
for failure in health restart; do
    : > "$log"
    if [[ $failure == health ]]; then
        out=$(FAKE_BAD_PORT=8123 OPEN_TERMINAL_PORT=8123 run_target 2>&1) && fail 'bad same-commit port was accepted'
    else
        out=$(FAKE_RESTART_FAIL=1 OPEN_TERMINAL_PORT=8123 run_target 2>&1) && fail 'failed restart was accepted'
    fi
    [[ $out == *'previous Open Terminal is running again'* ]] || fail "$failure rollback: $out"
    cmp -s "$envf" "$tmp_root/env-good" || fail "$failure kept the attempted port"
    cmp -s "$gw" "$tmp_root/unit-good" || fail "$failure kept the attempted unit"
    cmp -s "$clients" "$tmp_root/clients-good" || fail "$failure changed clients.json"
    grep -q 'python3 -m venv' "$log" && fail 'settings-only failure rebuilt the venv'
done
cp "$script_dir/open-terminal-gateway.service" "$deploy/open-terminal-gateway.service"
pass 'same-commit health and restart failures restore the previous configuration'

# A write that fails inside the (umask ...) subshell must roll back once. A
# second pass would find rollback/ gone and delete the restored files.
mkdir "$tree/etc/open-terminal/service.env.new"
: > "$log"
out=$(OPEN_TERMINAL_PORT=8123 run_target 2>&1) && fail 'a failed service.env write was accepted'
rmdir "$tree/etc/open-terminal/service.env.new"
[[ $(grep -c 'previous Open Terminal is running again' <<< "$out") == 1 ]] || fail "rolled back more than once: $out"
[[ $out != *'Rollback failed'* ]] || fail "rollback reported a failure: $out"
cmp -s "$envf" "$tmp_root/env-good" || fail 'a double rollback lost service.env'
cmp -s "$gw" "$tmp_root/unit-good" || fail 'a double rollback lost the unit'
pass 'a failure inside a subshell rolls back exactly once and keeps the configuration'

cp "$envf" "$tmp_root/env-before"
out=$(OPEN_TERMINAL_PORT=8123 FAKE_TAG_COMMIT=ffffffffffffffffffffffffffffffffffffffff run_target 2>&1) && fail 'a moved tag was installed'
cmp -s "$envf" "$tmp_root/env-before" || fail "a refused run changed service.env: $(cat "$envf")"
pass 'a refused run leaves the installed configuration untouched'

reset_tree
out=$(OPEN_TERMINAL_PORT=8123 FAKE_TAG_COMMIT=ffffffffffffffffffffffffffffffffffffffff run_target 2>&1) && fail 'a moved tag was installed'
[[ ! -e $envf ]] || fail 'a refused install wrote service.env'
[[ $out == *'is commit ffffffff'*'not the reviewed'* ]] || fail "moved tag message: $out"
[[ ! -e $gw ]] || fail 'unit installed from a moved tag'
pass 'a tag that no longer points at the reviewed commit is refused'

reset_tree
out=$(FAKE_EXTRA_DEP='rich>=13' run_target 2>&1) && fail 'dependency drift was installed'
[[ $out == *'different Python dependencies'*'rich>=13'* ]] || fail "drift message: $out"
grep -q 'python3 -m venv' "$log" && fail 'a venv was built despite the drift'
pass 'a release whose dependencies differ from the lock is refused before pip runs'

reset_tree
out=$(OPEN_TERMINAL_VERSION=v0.15.0 run_target 2>&1) && fail 'a new version without a commit pin was accepted'
[[ $out == *'Set OPEN_TERMINAL_COMMIT'* ]] || fail "pin message: $out"
pass 'a non-default version needs an explicit reviewed commit'

# The earlier installer: one shared workspace (open-terminal.service), the key
# in service.env, and a venv that is a directory, not a symlink.
legacy_tree() {
    reset_tree
    mkdir -p "$OT_OPT/venv/bin" "$tree/srv/open-terminal/workspace"
    printf '#!/bin/sh\n' > "$OT_OPT/venv/bin/open-terminal"; chmod +x "$OT_OPT/venv/bin/open-terminal"
    printf 'shared work\n' > "$tree/srv/open-terminal/workspace/notes.txt"
    printf '[Service]\nExecStart=/opt/open-terminal/venv/bin/open-terminal run\n' > "$units/open-terminal.service"
    printf 'OPEN_TERMINAL_API_KEY=%s\nOPEN_TERMINAL_PORT=8000\n' "$owui_key" > "$envf"
    chmod 0600 "$envf"
    cp "$units/open-terminal.service" "$tmp_root/legacy-unit"
    cp "$envf" "$tmp_root/legacy-env"
}
legacy_tree
: > "$log"
if out=$(FAKE_RESTART_FAIL=1 OPEN_TERMINAL_PORT=8123 run_target 2>&1); then fail 'a failed migration reported success'; fi
[[ $out == *'previous Open Terminal is running again'* ]] || fail "migration rollback: $out"
cmp -s "$units/open-terminal.service" "$tmp_root/legacy-unit" || fail 'rollback lost the shared-workspace unit'
cmp -s "$envf" "$tmp_root/legacy-env" || fail 'rollback lost the earlier service.env'
[[ ! -e $clients && ! -e $gw ]] || fail 'rollback left the gateway configuration'
contains 'systemctl restart open-terminal.service' "$log"
grep -q '^systemctl disable open-terminal-gateway.service open-terminal-spawner.service$' "$log" ||
    fail 'the rollback left the gateway enabled without its unit file'
grep -q '^systemctl enable open-terminal.service$' "$log" || fail 'the earlier service was not enabled again'
[[ -x $OT_OPT/venv-legacy/bin/open-terminal && $(readlink "$OT_OPT/venv") == "$OT_OPT/venv-legacy" ]] ||
    fail 'rollback did not point back at the earlier venv'
pass 'a failed move from the shared workspace brings the earlier service back'

legacy_tree
: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'legacy migration'; }
[[ -x $OT_OPT/venv-legacy/bin/open-terminal ]] || fail 'the old venv was not kept'
[[ -L $OT_OPT/venv ]] || fail 'venv is not a symlink after migration'
[[ ! -e $units/open-terminal.service ]] || fail 'the shared-workspace unit is still installed'
contains 'systemctl disable --now open-terminal.service' "$log"
grep -q API_KEY "$envf" && fail 'the key stayed in service.env'
contains "\"key_sha256\": \"$owui_hash\"" "$clients"
[[ $(cat "$tree/srv/open-terminal/workspace/notes.txt") == 'shared work' ]] || fail 'the shared workspace files were touched'
contains 'its files stay in' "$tmp_root/out"
pass 'an install from the earlier script moves to per-user workspaces, keeps its venv for rollback and its files'

next=1111111111111111111111111111111111111111
: > "$log"
OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=$next FAKE_TAG_COMMIT=$next run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'upgrade'; }
[[ $(readlink "$OT_OPT/venv") == "$(venv_for "$next")" ]] || fail 'upgrade did not switch the venv'
[[ -d $default_venv ]] || fail 'the previous venv was not kept for rollback'
[[ ! -e $OT_OPT/venv-legacy ]] || fail 'a venv older than the previous one was kept'
contains "systemctl stop open-terminal-ws@*.service" "$log"
pass 'an upgrade to a pinned new version switches venvs, keeps the previous one and restarts workspaces'

# A settings-only change on that commit keeps the previous commit's venv (the
# rollback target) and leaves no copy of the old configuration behind.
: > "$log"
OPEN_TERMINAL_PORT=8125 OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=$next FAKE_TAG_COMMIT=$next \
    run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'port change after the upgrade'; }
grep -q 'python3 -m venv' "$log" && fail 'a port change rebuilt the venv'
[[ -d $default_venv ]] || fail 'a settings-only change removed the previous commit venv'
[[ ! -e $tree/etc/open-terminal/rollback ]] || fail 'a successful run left a copy of the old configuration'
OPEN_TERMINAL_PORT=8000 OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=$next FAKE_TAG_COMMIT=$next run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'port change back'; }
pass 'a settings-only change keeps the previous commit venv and clears the rollback copies'

# Nothing answers, so the rollback cannot bring the terminal back either: that
# is reported as such, and the previous configuration is still put back.
cp "$envf" "$tmp_root/env-good"
: > "$log"
if out=$(FAKE_DOWN=1 OPEN_TERMINAL_PORT=8127 OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=$next \
        FAKE_TAG_COMMIT=$next run_target 2>&1); then
    fail 'an upgrade and rollback that never became healthy reported success'
fi
[[ $out == *'did not come back either'* && $out == *'Rollback failed'* ]] || fail "failed rollback not reported: $out"
cmp -s "$envf" "$tmp_root/env-good" || fail 'a failed rollback did not restore service.env'
[[ -d $tree/etc/open-terminal/rollback ]] || fail 'a failed rollback must keep its copies for inspection'
pass 'a rollback that does not become healthy is reported as such and keeps its copies'

bad=2222222222222222222222222222222222222222
if FAKE_BAD_COMMIT=$bad OPEN_TERMINAL_VERSION=v0.16.0 OPEN_TERMINAL_COMMIT=$bad FAKE_TAG_COMMIT=$bad \
        run_target > "$tmp_root/out" 2>&1; then
    fail 'an unhealthy upgrade reported success'
fi
contains 'previous Open Terminal is running again' "$tmp_root/out"
[[ $(readlink "$OT_OPT/venv") == "$(venv_for "$next")" ]] || fail 'rollback did not switch back'
pass 'an upgrade that does not become healthy switches back to the previous venv'

# The attempted upgrade also changes the port and the unit: the rollback must
# restore both, and check health on the previous port.
cp "$envf" "$tmp_root/env-good"
cp "$gw" "$tmp_root/unit-good"
printf '# changed by the attempted upgrade\n' >> "$deploy/open-terminal-gateway.service"
: > "$log"
if FAKE_BAD_COMMIT=$bad OPEN_TERMINAL_PORT=8123 OPEN_TERMINAL_VERSION=v0.16.0 OPEN_TERMINAL_COMMIT=$bad \
        FAKE_TAG_COMMIT=$bad run_target > "$tmp_root/out" 2>&1; then
    fail 'an unhealthy upgrade reported success'
fi
cp "$script_dir/open-terminal-gateway.service" "$deploy/open-terminal-gateway.service"
contains 'previous Open Terminal is running again' "$tmp_root/out"
cmp -s "$envf" "$tmp_root/env-good" || fail "rollback kept the attempted service.env: $(cat "$envf")"
cmp -s "$gw" "$tmp_root/unit-good" || fail 'rollback kept the attempted unit'
grep -q 'curl .*127.0.0.1:8123/health' "$log" || fail 'the attempt was not checked on its own port'
[[ $(grep 'curl ' "$log" | tail -n1) == *'127.0.0.1:8000/health'* ]] || fail 'the rollback was not checked on the previous port'
[[ ! -e $tree/etc/open-terminal/rollback ]] || fail 'rollback left its copies behind'
pass 'rollback restores the previous unit and service.env, and checks health on the previous port'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
