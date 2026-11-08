#!/usr/bin/env bash
# install/update-router.sh against a temporary "container": a git config repo,
# a router dir and a stub router venv. The management tool is a stub, so no
# service is applied or restarted and nothing is pushed.
exec </dev/null
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
UPDATE="${1:-${ROOT}/install/update-router.sh}"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- helpers --------------------------------------------------------------------
# shellcheck disable=SC1090
source "$UPDATE"

describe owned_code_list
printf 'x=1\nINSTALLER_OWNED_CODE=(\n  services/a/a.py   # comment\n  install/b.sh\n  $(rm -rf /)\n)\n' > "$TMP/inst.sh"
assert_eq "entries parsed as text, junk dropped" $'services/a/a.py\ninstall/b.sh' "$(owned_code_list "$TMP/inst.sh")"
assert_eq "the real installer lists the router code" "yes" \
  "$(owned_code_list "${ROOT}/ollama-smart-router-install.sh" | grep -qx services/ollama-router/router.py && echo yes)"

describe safe_rel_path
assert_ok   "plain path"           safe_rel_path services/ollama-router/router.py
assert_fail "parent escape"        safe_rel_path ../etc/passwd
assert_fail "absolute path"        safe_rel_path /etc/passwd
assert_fail "embedded dot-dot"     safe_rel_path services/../x

describe crlf_and_syntax
mkdir -p "$TMP/src"
printf 'echo ok\n' > "$TMP/src/good.sh"; printf 'echo ok\r\n' > "$TMP/src/crlf.sh"
printf 'if then\n' > "$TMP/src/bad.sh"; printf 'x = (\n' > "$TMP/src/bad.py"; printf 'x = 1\n' > "$TMP/src/good.py"
assert_eq "CRLF file found" "crlf.sh" "$(crlf_files "$TMP/src" good.sh crlf.sh missing.sh)"
assert_eq "syntax failures listed" $'bad.sh\nbad.py' "$(syntax_errors "$TMP/src" good.sh bad.sh good.py bad.py)"
assert_ok "clean files pass" syntax_errors "$TMP/src" good.sh good.py

describe changed_files
mkdir -p "$TMP/a" "$TMP/b"; echo 1 > "$TMP/a/same"; echo 1 > "$TMP/b/same"; echo 2 > "$TMP/a/diff"; echo 3 > "$TMP/b/diff"; echo n > "$TMP/a/new"
assert_eq "changed and new files" $'diff\nnew' "$(changed_files "$TMP/a" "$TMP/b" same diff new absent)"
assert_eq "diff_stat" "+1 -1" "$(diff_stat "$TMP/b/diff" "$TMP/a/diff")"

# --- whole-script runs ----------------------------------------------------------
if (( EUID != 0 )); then
  skip "end-to-end update cases (update-router.sh needs root)"
  summary; exit $?
fi

# A source checkout: a copy of this repository. A "container": a config repo
# committed from the same files, the router dir and a stub venv.
make_world() {
  rm -rf "$TMP/w"; mkdir -p "$TMP/w/router/venv/bin"
  mkdir -p "$TMP/w/src"
  (cd "$ROOT" && tar --exclude=.git --exclude='.venv*' --exclude=__pycache__ --exclude=.pytest_cache \
     --exclude=.ruff_cache -cf - .) | tar -C "$TMP/w/src" -xf -
  cp -a "$TMP/w/src" "$TMP/w/repo"
  git -C "$TMP/w/repo" init -q && git -C "$TMP/w/repo" add -A &&
    git -C "$TMP/w/repo" -c user.name=t -c user.email=t@t commit -qm seed
  # Stub venv: pip logs its arguments; FAKE_PIP=fail makes installs fail.
  cat > "$TMP/w/router/venv/bin/pip" <<EOF
#!/bin/sh
echo "pip \$*" >> "$TMP/w/calls"
[ "\$1" = freeze ] && { echo 'fastapi==0.1'; exit 0; }
[ "\$1" = list ] && { echo '[]'; exit 0; }
[ "\${FAKE_PIP:-ok}" = ok ]
EOF
  chmod +x "$TMP/w/router/venv/bin/pip"
  # Stub manage-model-servers: logs, and FAKE_APPLY=fail makes apply fail.
  cat > "$TMP/w/manage" <<EOF
#!/bin/sh
echo "manage \$*" >> "$TMP/w/calls"
# Record the lock descriptor handed over, and what it points at.
[ -n "\${CONFIG_LOCK_INHERITED_FD:-}" ] && readlink "/proc/self/fd/\$CONFIG_LOCK_INHERITED_FD" > "$TMP/w/inherited"
[ "\$1" = apply ] && [ "\${FAKE_APPLY:-ok}" != ok ] && exit 1
[ "\$1" = commit ] && [ "\${FAKE_PUSH:-ok}" != ok ] && exit 1
exit 0
EOF
  chmod +x "$TMP/w/manage"
  : > "$TMP/w/calls"
}
run_update() {
  CONFIG_REPO_DIR="$TMP/w/repo" ROUTER_DIR="$TMP/w/router" \
    MANAGE_CMD="${MANAGE_CMD_OVERRIDE:-$TMP/w/manage}" CONFIG_LOCK_FILE="${LOCK_FILE_OVERRIDE:-$TMP/w/update.lock}" \
    PYTHON=python3 bash "$UPDATE" "$@" "$TMP/w/src" 2>&1
}
head_of() { git -C "$TMP/w/repo" rev-parse HEAD; }
router="services/ollama-router/router.py"

describe up_to_date
make_world
out="$(run_update)"; rc=$?
assert_eq "no change exits 0" "0" "$rc"
assert_contains "says up to date" "Already up to date" "$out"
assert_eq "manage never called" "" "$(cat "$TMP/w/calls")"

describe dry_run
make_world
echo '# new line' >> "$TMP/w/src/$router"
before="$(head_of)"
out="$(run_update --dry-run --diff)"
assert_contains "lists the changed file" "$router" "$out"
assert_contains "shows the diff" "+# new line" "$out"
assert_eq "repo untouched" "$before" "$(head_of)"
assert_eq "working tree untouched" "" "$(git -C "$TMP/w/repo" status --porcelain)"

describe diff_implies_dry_run_and_shows_new_files
make_world
rm "$TMP/w/repo/install/update-router.sh"
git -C "$TMP/w/repo" add -A && git -C "$TMP/w/repo" -c user.name=t -c user.email=t@t commit -qm remove-update
out="$(run_update --diff)"
assert_contains "diff implies dry run" "[dry-run] nothing was changed" "$out"
assert_contains "new file diff is shown" "+#!/usr/bin/env bash" "$out"
assert_eq "new-file repo untouched" "" "$(git -C "$TMP/w/repo" status --porcelain)"

describe update_applies_and_pushes
make_world
echo '# new line' >> "$TMP/w/src/$router"
out="$(run_update)"; rc=$?
assert_eq "update succeeds" "0" "$rc"
assert_ok "router.py updated in the repo" cmp -s "$TMP/w/src/$router" "$TMP/w/repo/$router"
assert_contains "commit names the source" "Update router components from" "$(git -C "$TMP/w/repo" log -1 --format=%s)"
assert_contains "commit lists the file" "$router" "$(git -C "$TMP/w/repo" log -1 --format=%b)"
assert_eq "apply without --all, then push" $'manage apply\nmanage commit Update router components' "$(cat "$TMP/w/calls")"
assert_eq "manage gets the held lock descriptor" "$TMP/w/update.lock" "$(cat "$TMP/w/inherited" 2>/dev/null)"

describe push_failure_is_reported
make_world
echo '# push failure' >> "$TMP/w/src/$router"
out="$(FAKE_PUSH=fail run_update)"; rc=$?
assert_eq "push failure is non-zero" "1" "$rc"
assert_contains "push failure is explained" "push failed" "$out"
assert_ok "applied commit is kept locally" cmp -s "$TMP/w/src/$router" "$TMP/w/repo/$router"

describe tunables_and_config_are_kept
make_world
echo 'my_setting = 1' >> "$TMP/w/repo/services/ollama-router/router.ini"
echo 'OLLAMA_SERVERS=mine' >> "$TMP/w/repo/env/router.env"
git -C "$TMP/w/repo" -c user.name=t -c user.email=t@t commit -qam local
echo '# upstream' >> "$TMP/w/src/services/ollama-router/router.ini"
echo '# upstream' >> "$TMP/w/src/env/router.env"
echo '# upstream' >> "$TMP/w/src/$router"
run_update >/dev/null
assert_file_contains "router.ini edits kept" "my_setting = 1" "$TMP/w/repo/services/ollama-router/router.ini"
assert_file_contains "env untouched" "OLLAMA_SERVERS=mine" "$TMP/w/repo/env/router.env"
assert_fail "env never gets upstream lines" grep -q upstream "$TMP/w/repo/env/router.env"
run_update --with-tunables >/dev/null
assert_file_contains "--with-tunables replaces router.ini" "# upstream" "$TMP/w/repo/services/ollama-router/router.ini"
assert_fail "env still untouched" grep -q upstream "$TMP/w/repo/env/router.env"

describe failed_apply_is_undone
make_world
echo '# broken' >> "$TMP/w/src/$router"
before="$(head_of)"
out="$(FAKE_APPLY=fail run_update)"; rc=$?
assert_eq "fails" "1" "$rc"
assert_eq "repo back to the previous commit" "$before" "$(head_of)"
assert_fail "router.py restored" grep -q '# broken' "$TMP/w/repo/$router"
assert_not_contains "nothing pushed" "manage commit" "$(cat "$TMP/w/calls")"

describe requirements_change_updates_the_venv
make_world
echo 'rich==13.0.0' >> "$TMP/w/src/services/ollama-router/requirements.txt"
out="$(run_update)"; rc=$?
assert_eq "succeeds" "0" "$rc"
assert_contains "venv reinstalled from both requirements" "ollama-monitor/requirements.txt" "$(grep 'pip install' "$TMP/w/calls")"
assert_contains "apply restarts everything" "manage apply --all" "$(cat "$TMP/w/calls")"

make_world
echo 'rich==13.0.0' >> "$TMP/w/src/services/ollama-router/requirements.txt"
before="$(head_of)"
out="$(FAKE_APPLY=fail run_update)"; rc=$?
assert_eq "failed apply after a venv change fails" "1" "$rc"
assert_eq "repo reset" "$before" "$(head_of)"
assert_contains "venv restored from the freeze" "pip install -q --no-cache-dir -r ${TMP}/w/router/.venv-before-update.txt" "$(cat "$TMP/w/calls")"

make_world
echo 'rich==13.0.0' >> "$TMP/w/src/services/ollama-router/requirements.txt"
before="$(head_of)"
out="$(FAKE_PIP=fail run_update)"; rc=$?
assert_eq "failed pip install fails" "1" "$rc"
assert_eq "repo reset after pip failure" "$before" "$(head_of)"
assert_not_contains "nothing applied" "manage apply" "$(cat "$TMP/w/calls")"

describe no_apply_requirements_must_not_push
make_world
echo 'rich==13.0.0' >> "$TMP/w/src/services/ollama-router/requirements.txt"
out="$(run_update --no-apply)"; rc=$?
assert_eq "requirements no-apply push is refused" "1" "$rc"
assert_contains "explains the safe follow-up" "--no-push" "$out"
assert_eq "nothing was committed" "seed" "$(git -C "$TMP/w/repo" log -1 --format=%s)"

describe refusals
make_world
echo '# x' >> "$TMP/w/src/$router"
echo 'dirty' >> "$TMP/w/repo/README.md"
out="$(run_update)"; rc=$?
assert_eq "dirty config repo refused" "1" "$rc"
assert_contains "points at commit" "manage-model-servers commit" "$out"
git -C "$TMP/w/repo" checkout -q -- README.md

printf 'echo hi\r\n' >> "$TMP/w/src/install/apply-config.sh"
out="$(run_update)"; rc=$?
assert_eq "CRLF source refused" "1" "$rc"
assert_contains "names the file" "install/apply-config.sh" "$out"

make_world
printf 'def broken(:\n' >> "$TMP/w/src/services/ollama-monitor/monitor.py"
before="$(head_of)"
out="$(run_update)"; rc=$?
assert_eq "syntax error refused" "1" "$rc"
assert_eq "nothing committed" "$before" "$(head_of)"

make_world
rm "$TMP/w/src/services/ollama-monitor/monitor.py"
ln -s /etc/passwd "$TMP/w/src/services/ollama-monitor/monitor.py"
out="$(run_update)"; rc=$?
assert_eq "source symlink refused" "1" "$rc"
assert_contains "names the symlink refusal" "symlinked" "$out"

make_world
mkdir -p "$TMP/w/with space"
cp "$TMP/w/manage" "$TMP/w/with space/manage"
chmod +x "$TMP/w/with space/manage"
out="$(MANAGE_CMD_OVERRIDE="$TMP/w/with space/manage" run_update)"; rc=$?
assert_eq "manager path with spaces works" "0" "$rc"

describe concurrent_update_is_refused
make_world
echo '# locked' >> "$TMP/w/src/$router"
exec 9>"$TMP/w/held.lock"
flock -n 9
out="$(LOCK_FILE_OVERRIDE="$TMP/w/held.lock" run_update)"; rc=$?
assert_eq "held lock refuses update" "1" "$rc"
assert_contains "lock refusal is explained" "another config update" "$out"
assert_contains "and points at clear-lock" "clear-lock" "$out"
exec 9>&-

make_world
out="$(CONFIG_REPO_DIR="$TMP/w/repo" ROUTER_DIR="$TMP/w/router" MANAGE_CMD="$TMP/w/manage" bash "$UPDATE" "$TMP/w/repo" 2>&1)"; rc=$?
assert_eq "updating from the config repo itself is refused" "1" "$rc"
out="$(CONFIG_REPO_DIR="$TMP/w/repo" ROUTER_DIR="$TMP/w/router" MANAGE_CMD="$TMP/w/manage" bash "$UPDATE" "$TMP" 2>&1)"; rc=$?
assert_eq "a non-repo directory is refused" "1" "$rc"

describe no_apply_no_push
make_world
echo '# y' >> "$TMP/w/src/$router"
out="$(run_update --no-apply --no-push)"; rc=$?
assert_eq "succeeds" "0" "$rc"
assert_eq "manage not called" "" "$(cat "$TMP/w/calls")"
assert_ok "but committed" cmp -s "$TMP/w/src/$router" "$TMP/w/repo/$router"

summary
