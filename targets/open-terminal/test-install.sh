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

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$target")
for helper in deps_mismatch service_env healthy; do
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

env_text=$(service_env abc123def456ghi789 8001)
[[ $env_text == *$'\nOPEN_TERMINAL_API_KEY=abc123def456ghi789\nOPEN_TERMINAL_PORT=8001' ]] || fail "service env: $env_text"
[[ $(grep -c '^OPEN_TERMINAL_API_KEY_FILE=' <<< "$env_text") == 0 ]] || fail 'the _FILE variant must never be set'
pass 'the service gets the key as OPEN_TERMINAL_API_KEY, never the conflicting _FILE variant'

unit=$script_dir/open-terminal.service
grep -qx 'EnvironmentFile=/etc/open-terminal/service.env' "$unit" || fail 'unit env file'
grep -q 'OPEN_TERMINAL_API_KEY_FILE=' <(grep -v '^#' "$unit") && fail 'unit sets OPEN_TERMINAL_API_KEY_FILE'
grep -qx 'Environment=OPEN_TERMINAL_CORS_ALLOWED_ORIGINS=http://127.0.0.1' "$unit" || fail 'CORS must be an explicit origin (empty means *)'
grep -qx 'ExecStart=/opt/open-terminal/venv/bin/open-terminal run --host 0.0.0.0 --port ${OPEN_TERMINAL_PORT} --cwd /srv/open-terminal/workspace' "$unit" || fail 'ExecStart'
pass 'the unit loads the root-only env file and restricts CORS explicitly'

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
stub systemctl 'exit 0'
# install: drop -o/-g (the open-terminal account does not exist here).
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
# curl: healthy unless the active venv belongs to FAKE_BAD_COMMIT.
stub curl 'active=$(readlink "$OT_OPT/venv" 2>/dev/null || true)
[[ -n ${FAKE_BAD_COMMIT:-} && $active == *"$FAKE_BAD_COMMIT" ]] && exit 22
printf "{\"status\":\"ok\"}"'
# python3: "-m venv DIR" builds a fake venv whose python logs pip calls and,
# for the final --no-deps install, provides bin/open-terminal. Everything else
# (the version check, the dependency check) is the real interpreter.
cat > "$bin/python3" <<STUB
#!/usr/bin/env bash
if [[ \$1 == -m && \$2 == venv ]]; then
    echo "python3 \$*" >> "$log"
    mkdir -p "\$3/bin"
    cat > "\$3/bin/python" <<'PY'
#!/usr/bin/env bash
venv=\$(cd "\$(dirname "\$0")/.." && pwd)
echo "venv-python \$venv \$*" >> "$log"
if [[ " \$* " == *" --no-deps "* ]]; then printf '#!/bin/sh\nexit 0\n' > "\$venv/bin/open-terminal"; chmod +x "\$venv/bin/open-terminal"; fi
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
        source <(awk '/^# Install helpers/{c=1;next} /^# End install helpers\./{c=0} c' "$target") 2>/dev/null
        $(declare -f pyproject_from)
        pyproject_from "$script_dir/requirements.in" "\${FAKE_EXTRA_DEP:-}" > "\$dir/pyproject.toml"
        echo "\${FAKE_TAG_COMMIT:-$default_commit}" > "\$dir/.git/HEAD" ;;
    rev-parse) cat "\$dir/.git/HEAD" ;;
esac
STUB
chmod +x "$bin/git"

tree=$tmp_root/tree
reset_tree() {
    rm -rf "$tree"; mkdir -p "$tree/etc/open-terminal" "$tree/etc/systemd/system" "$tree/opt" "$tree/srv"
    printf '%s\n' "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$tree/etc/open-terminal/api-key"
    : > "$log"
}
run_target() {
    env PATH="$bin:$PATH" OT_ETC="$tree/etc/open-terminal" OT_OPT="$tree/opt/open-terminal" \
        OT_SRV="$tree/srv/open-terminal" UNIT_DIR="$tree/etc/systemd/system" HEALTH_TIMEOUT=2 \
        bash "$target"
}
contains() { grep -Fq -- "$1" "$2" || fail "$2 lacks: $1"; }
export OT_OPT="$tree/opt/open-terminal"

reset_tree
chmod 0640 "$tree/etc/open-terminal/api-key"    # the old layout: group-readable
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'fresh install'; }
cmp -s "$tree/etc/systemd/system/open-terminal.service" "$unit" || fail 'unit not installed from the repo file'
envf=$tree/etc/open-terminal/service.env
[[ $(stat -c '%a %U' "$envf") == '600 root' ]] || fail "service.env mode: $(stat -c '%a %U' "$envf")"
[[ $(stat -c '%a' "$tree/etc/open-terminal/api-key") == 600 ]] || fail 'api-key is still group-readable'
contains 'OPEN_TERMINAL_API_KEY=0123456789abcdef' "$envf"
contains 'OPEN_TERMINAL_PORT=8000' "$envf"
[[ $(readlink "$OT_OPT/venv") == "$OT_OPT/venv-$default_commit" ]] || fail 'venv symlink'
contains "--require-hashes -r $script_dir/requirements.lock" "$log"
contains "--no-deps --no-build-isolation $OT_OPT/source" "$log"
contains "fetch -q --depth 1 origin +refs/tags/v0.14.0:refs/tags/v0.14.0" "$log"
[[ $(grep -c '^systemctl restart open-terminal.service' "$log") == 1 ]] || fail 'the service must be started exactly once'
grep -q 'enable --now' "$log" && fail 'enable --now plus restart starts it twice'
grep -q -- '0123456789abcdef0123' "$tmp_root/out" && fail 'the key was printed'
pass 'fresh install: hash-locked venv, root-only key files, one start'

: > "$log"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'rerun'; }
grep -q 'python3 -m venv' "$log" && fail 'a rerun of the same commit rebuilt the venv'
pass 'a rerun of the same commit reuses its venv'

reset_tree
out=$(FAKE_TAG_COMMIT=ffffffffffffffffffffffffffffffffffffffff run_target 2>&1) && fail 'a moved tag was installed'
[[ $out == *'is commit ffffffff'*'not the reviewed'* ]] || fail "moved tag message: $out"
[[ ! -e $tree/etc/systemd/system/open-terminal.service ]] || fail 'unit installed from a moved tag'
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

reset_tree
mkdir -p "$OT_OPT/venv/bin"; printf '#!/bin/sh\n' > "$OT_OPT/venv/bin/open-terminal"; chmod +x "$OT_OPT/venv/bin/open-terminal"
run_target > "$tmp_root/out" 2>&1 || { cat "$tmp_root/out"; fail 'legacy migration'; }
[[ -x $OT_OPT/venv-legacy/bin/open-terminal ]] || fail 'the old venv was not kept'
[[ -L $OT_OPT/venv ]] || fail 'venv is not a symlink after migration'
pass 'an install from the earlier script keeps its venv as the rollback target'

next=1111111111111111111111111111111111111111
: > "$log"
OPEN_TERMINAL_VERSION=v0.15.0 OPEN_TERMINAL_COMMIT=$next FAKE_TAG_COMMIT=$next run_target > "$tmp_root/out" 2>&1 ||
    { cat "$tmp_root/out"; fail 'upgrade'; }
[[ $(readlink "$OT_OPT/venv") == "$OT_OPT/venv-$next" ]] || fail 'upgrade did not switch the venv'
[[ -d $OT_OPT/venv-$default_commit ]] || fail 'the previous venv was not kept for rollback'
[[ ! -e $OT_OPT/venv-legacy ]] || fail 'a venv older than the previous one was kept'
pass 'an upgrade to a pinned new version switches venvs and keeps the previous one'

bad=2222222222222222222222222222222222222222
if FAKE_BAD_COMMIT=$bad OPEN_TERMINAL_VERSION=v0.16.0 OPEN_TERMINAL_COMMIT=$bad FAKE_TAG_COMMIT=$bad \
        run_target > "$tmp_root/out" 2>&1; then
    fail 'an unhealthy upgrade reported success'
fi
contains 'previous Open Terminal is running again' "$tmp_root/out"
[[ $(readlink "$OT_OPT/venv") == "$OT_OPT/venv-$next" ]] || fail 'rollback did not switch back'
pass 'an upgrade that does not become healthy switches back to the previous venv'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
