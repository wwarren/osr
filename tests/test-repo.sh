#!/usr/bin/env bash
# Repository consistency checks: things that broke before and must not again.
#
#   * the installer's embedded service files match the repo (single source of truth)
#   * the installer-owned code list matches what the installer actually embeds
#   * no CRLF line endings in text files (bash cannot run them)
#   * no secrets in the version-controlled env files
#   * LiteLLM runs from its own venv with the [proxy] extra

# Never read the caller's stdin: a prompt under test that is not fed input
# explicitly would otherwise block forever when run from a pipe or CI runner.
exec </dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
INSTALLER="${1:-${ROOT}/ollama-smart-router-install.sh}"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"

describe embedded_copies
out="$(python3 "${ROOT}/tools/sync-embedded.py" --check 2>&1)"; rc=$?
assert_eq "installer heredocs match the repo files" "0" "$rc"
[[ $rc -eq 0 ]] || printf '%s\n' "$out" >&2

describe installer_owned_list
eval "$(sed -n '/^INSTALLER_OWNED_CODE=(/,/^)/p' "$INSTALLER")"
embedded="$(python3 "${ROOT}/tools/sync-embedded.py" --list | sort)"
owned="$(printf '%s\n' "${INSTALLER_OWNED_CODE[@]}" | sort)"
# Every embedded file except the tunables (*.ini) must be installer-owned...
missing="$(comm -23 <(grep -v '\.ini$' <<< "$embedded") <(printf '%s\n' "$owned"))"
assert_eq "every embedded code file is updated on re-install" "" "$missing"
# ...and every owned entry must be something the installer really ships.
extra="$(comm -13 <(printf '%s\n' "$embedded") <(printf '%s\n' "$owned" | grep -v 'requirements\.lock$'))"
assert_eq "no owned entry the installer does not ship" "" "$extra"
assert_fail "tunables stay seed-if-missing" grep -qx 'services/ollama-router/router.ini' <<< "$owned"

# scan_tracked_text MODE (crlf | mojibake | encoding): print offending files.
# Lists the tracked files with git; outside a git checkout (a tarball, the
# update stage) it walks the tree instead. Any failure to list or read exits
# non-zero, and the callers assert that status, so a broken scan can never
# report "ok".
scan_tracked_text() {
  python3 - "$ROOT" "$1" <<'PY'
import os
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
SKIP_DIRS = {".git", "__pycache__", ".pytest_cache", ".ruff_cache"}


def listed():
    if (root / ".git").exists():
        try:
            out = subprocess.check_output(["git", "ls-files", "--cached", "-z"], cwd=root)
        except (OSError, subprocess.CalledProcessError) as exc:
            sys.exit(f"scan_tracked_text: git ls-files failed: {exc}")
        return [p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p]
    names = []
    for here, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".venv")]
        names += [os.path.relpath(os.path.join(here, f), root) for f in files]
    return names


for name in sorted(listed()):
    path = root / name
    if not path.is_file():
        continue
    data = path.read_bytes()
    if b"\0" in data:
        continue
    if mode == "crlf" and b"\r" in data:
        print(name)
        continue
    try:
        decoded = data.decode("utf-8")
    except UnicodeDecodeError:
        if mode == "encoding":
            print(name)
        continue
    if mode == "mojibake" and ("\u00e2\u20ac" in decoded or "\u00c3" in decoded):
        print(name)
PY
}

describe line_endings
crlf="$(scan_tracked_text crlf)"; rc=$?
assert_eq "the CRLF scan ran" "0" "$rc"
assert_eq "no CRLF text files" "" "$crlf"
assert_file_contains "root .gitattributes forces LF" "eol=lf" "${ROOT}/.gitattributes"

describe text_encoding
# A UTF-8 file re-saved through Windows-1252 can acquire double-encoded text.
# Scan tracked text, including this test file, without embedding those bytes.
mojibake="$(scan_tracked_text mojibake)"; rc=$?
assert_eq "the double-encoding scan ran" "0" "$rc"
assert_eq "no Windows-1252 double-encoded text" "" "$mojibake"
not_utf8="$(scan_tracked_text encoding)"; rc=$?
assert_eq "the UTF-8 scan ran" "0" "$rc"
assert_eq "text files are valid UTF-8" "" "$not_utf8"

describe secrets
for f in "${ROOT}"/env/*.env; do
  assert_fail "$(basename "$f") has no deploy token" grep -Eq '^GITEA_DEPLOY_TOKEN=.+' "$f"
  assert_fail "$(basename "$f") has no webhook URL"  grep -Eq '^MATTERMOST_WEBHOOK_URL=.+' "$f"
  assert_fail "$(basename "$f") has no router API key" grep -Eq '^ROUTER_API_KEY=.+' "$f"
done
assert_file_contains "the monitor loads the secrets file" \
  "EnvironmentFile=-/app/router/secrets.env" "${ROOT}/services/ollama-monitor/ollama-monitor.service"

describe unit_hardening
for unit in "${ROOT}"/services/*/*.service "${ROOT}"/targets/*/*.service; do
  assert_file_contains "$(basename "$unit") is ProtectSystem=strict" "ProtectSystem=strict" "$unit"
  assert_file_contains "$(basename "$unit") drops capabilities" "CapabilityBoundingSet=" "$unit"
done

describe inference_targets
for dir in "${ROOT}"/targets/*/; do
  name=$(basename "$dir")
  assert_fail "targets/${name} is not a nested git repository" test -e "${dir}.git"
  assert_ok "targets/${name} has an install-target.sh" test -f "${dir}install-target.sh"
  assert_ok "targets/${name} has a provision-lxc.sh" test -f "${dir}provision-lxc.sh"
done
dropin="${ROOT}/targets/ollama/ollama-target.conf"
assert_file_contains "the Ollama drop-in is ProtectSystem=strict" "ProtectSystem=strict" "$dropin"
assert_file_contains "the Ollama drop-in drops capabilities" "CapabilityBoundingSet=" "$dropin"
assert_file_contains "the Ollama drop-in runs unprivileged" "User=ollama" "$dropin"
assert_ok "the Ollama target starts from the community script" \
  grep -q 'community-scripts/ProxmoxVE/main/ct/ollama.sh' "${ROOT}/targets/ollama/provision-lxc.sh"
airllm="${ROOT}/targets/airllm"
assert_ok "the AirLLM target installs from a hash lock" grep -q -- '--require-hashes' "${airllm}/install-target.sh"
assert_fail "the AirLLM requirements are exact pins" grep -Eq '^[A-Za-z].*(>=|~=|<)' "${airllm}/requirements.txt"
pin="$(sed -nE 's/^airllm==([^[:space:]#]+).*/\1/p' "${airllm}/requirements.txt")"
assert_ok "the AirLLM lock matches its pin" grep -q "^airllm==${pin} " "${airllm}/requirements.lock"

describe upgrade_contract
# Every target's upgrade follows one contract (ARCHITECTURE.md §16): the
# rollback restores configuration as well as code, is health-checked, and
# says when it failed too. The behaviour itself is exercised by each target's
# own tests; this keeps a new or edited target from silently dropping a part.
for name in strata basalt maya; do
  t="${ROOT}/targets/${name}/install-target.sh"
  assert_ok "${name}: stages the settings of a good install" grep -q 'stage_record "\$[A-Z_]*ETC_DIR/installed-env" settings_env' "$t"
  assert_ok "${name}: publishes installed settings durably" grep -q 'publish_record "\$env_temporary" "\$[A-Z_]*ETC_DIR/installed-env"' "$t"
  assert_eq "${name}: locks before loading settings" saved_settings "$(sed -n '/^acquire_install_lock$/{n;p;}' "$t")"
  assert_fail "${name}: git fetch keeps its housekeeping in the foreground (no detached lock holder)" \
    bash -c "grep -E 'as_service git .*fetch' '$t' | grep -qv 'gc.autoDetach=false -c maintenance.autoDetach=false'"
  assert_ok "${name}: as_service closes the installer lock for its command" grep -q '{install_lock_fd}>&-' "$t"
  assert_ok "${name}: snapshots the unit before changing it" grep -q 'STATE_DIR/rollback.service" || return 1' "$t"
  assert_ok "${name}: the snapshot is removed after a success or a rollback" test "$(grep -c '^ *clear_snapshot$' "$t")" -ge 2
  assert_ok "${name}: a failed rollback keeps the snapshot" grep -q 'the snapshot is kept in' "$t"
  assert_fail "${name}: no snapshot is written under /etc" grep -q 'ETC_DIR/rollback-runtime.tar.new" \.' "$t"
  assert_ok "${name}: rollback restores the recorded settings" grep -q 'if load_settings "\$[A-Z_]*ETC_DIR/installed-env"; then' "$t"
  assert_ok "${name}: rollback restores its runnable snapshot" grep -q 'restore_runtime "\$previous"' "$t"
  assert_ok "${name}: the settings record is parsed, never sourced" grep -q 'printf -v "\$key"' "$t"
  assert_fail "${name}: the settings record is never sourced" grep -Eq '(source|\.) "?\$[A-Z_]*ETC_DIR/installed-env' "$t"
  assert_ok "${name}: a failed rollback is reported" grep -q 'Rollback to \$previous failed too' "$t"
  assert_ok "${name}: a fetch failure stops nothing" grep -q 'was not stopped or changed' "$t"
done
for name in llamacpp airllm; do
  t="${ROOT}/targets/${name}/install-target.sh"
  assert_ok "${name}: settings files are set aside before they are edited" grep -q 'stash_copy "\$TARGET_E' "$t"
  assert_ok "${name}: rollback is health-checked" grep -q 'did not become healthy either' "$t"
done
assert_ok "ollama: rollback is health-checked" \
  grep -q 'did not answer either' "${ROOT}/targets/ollama/install-target.sh"
ot="${ROOT}/targets/open-terminal/install-target.sh"
assert_ok "open-terminal: rollback restores service.env" grep -q 'mv -f -- "\$OT_ETC/service.env.prev"' "$ot"
assert_ok "open-terminal: rollback restores the unit" grep -q 'install -m 0644 "\$OT_ETC/open-terminal.service.prev"' "$ot"
# Configuration must not change before the new venv is ready (a refused tag or
# dependency drift would otherwise leave a new port behind).
env_line=$(grep -n 'service_env "\$key" "\$PORT" >' "$ot" | head -n1 | cut -d: -f1)
venv_line=$(grep -n 'pip install --no-cache-dir --no-deps' "$ot" | head -n1 | cut -d: -f1)
assert_ok "open-terminal: service.env is written after the venv is built" \
  test "${env_line:-0}" -gt "${venv_line:-999999}"
# With set -E an ERR trap also fires inside ( ... ) subshells; a rollback trap
# must act only in the main shell, or a failure there rolls back twice.
for t in "${ROOT}"/targets/*/install-target.sh; do
  name=$(basename "$(dirname "$t")")
  assert_fail "${name}: every ERR rollback trap is guarded against subshells" \
    bash -c "grep -E \"trap '.*rollback.*' ERR\" '$t' | grep -qv 'BASHPID'"
done
for dir in "${ROOT}"/targets/*/; do
  name=$(basename "$dir")
  # Code lines of the target's tests (comments do not count as a test).
  tests_code="cat '${dir}'test-*.sh | grep -vE '^[[:space:]]*#'"
  if grep -qE -- '--upgrade\)' "${dir}install-target.sh"; then
    assert_ok "${name}: a test runs --upgrade" bash -c "${tests_code} | grep -q -- '--upgrade'"
  fi
  assert_ok "${name}: a test checks a rollback that succeeds" bash -c "${tests_code} | grep -qE 'running.* again'"
  assert_ok "${name}: a test checks a rollback that fails too" \
    bash -c "${tests_code} | grep -qE 'did not (become healthy|answer|come back) either|failed too'"
  # An upgrade with nothing to change leaves the target alone, and a test says so.
  assert_ok "${name}: an unchanged upgrade does nothing" grep -q 'nothing to do' "${dir}install-target.sh"
  assert_ok "${name}: and a test checks it" bash -c "grep -lq 'nothing to do' '${dir}'test-*.sh"
done

describe maya_update_switch
# Maya's dashboard can fast-forward its own checkout (About > Updates) when the
# server was started through maya.py, which maya.service does. That would move
# /opt/maya off install-target.sh's pinned commit and its rollback ref, so the
# unit must switch the updater off, and nothing may switch it back on: an
# EnvironmentFile= value would override the Environment= line.
maya="${ROOT}/targets/maya"
assert_ok "maya.service turns the dashboard updater off" \
  grep -qx 'Environment=MAYA_UPDATE_CHECK=0' "${maya}/maya.service"
assert_eq "and sets MAYA_UPDATE_CHECK nowhere else" "1" \
  "$(grep -c 'MAYA_UPDATE_CHECK' "${maya}/maya.service" | tr -d ' ')"
assert_fail "the unit does not unset it" grep -q '^UnsetEnvironment=.*MAYA_UPDATE_CHECK' "${maya}/maya.service"
assert_fail "the generated maya.env cannot override it" grep -q 'MAYA_UPDATE_CHECK' "${maya}/install-target.sh"
assert_ok "CI checks the update switch against the pinned upstream code" \
  grep -q 'targets/maya/test-pinned-run-script.py' "${ROOT}/.gitea/workflows/tests.yml"

describe venv_permissions
# Venvs are built after the secret-bearing tree (umask 077); the service account
# must still be able to run them (litellm-proxy failed with 203/EXEC otherwise).
tree_umask="$(grep -n '^umask 077$' "$INSTALLER" | head -n1 | cut -d: -f1)"
reset_umask="$(grep -n '^umask 022$' "$INSTALLER" | head -n1 | cut -d: -f1)"
first_venv="$(grep -n 'run_ct python3 -m venv' "$INSTALLER" | head -n1 | cut -d: -f1)"
assert_ok "umask is reset to 022 before the first venv is built" \
  test "${tree_umask:-0}" -lt "${reset_umask:-0}" -a "${reset_umask:-0}" -lt "${first_venv:-0}"
assert_ok "the LiteLLM venv is made readable after install" \
  grep -q 'chmod -R u+rwX,go+rX,go-w /app/litellm' "$INSTALLER"

describe single_management_tool
assert_ok "the root script only wraps install/" grep -q 'exec bash "\$target"' "${ROOT}/manage-model-servers.sh"
assert_ok "and is tiny" test "$(wc -l < "${ROOT}/manage-model-servers.sh")" -lt 30

describe litellm_venv
req="${ROOT}/services/litellm-proxy/requirements.txt"
assert_ok "requirements pin the [proxy] extra" grep -Eq '^litellm\[proxy\]==' "$req"
assert_file_contains "unit runs from its own venv" "/app/litellm/venv/bin/litellm" \
  "${ROOT}/services/litellm-proxy/litellm-proxy.service"
lock="${ROOT}/services/litellm-proxy/requirements.lock"
assert_ok "a hash lock exists" test -f "$lock"
pin="$(sed -nE 's/^litellm\[proxy\]==([^[:space:]#]+).*/\1/p' "$req")"
assert_ok "the lock matches the pin" grep -q "^litellm==${pin} " "$lock"
assert_fail "the lock never contains the compromised releases" grep -Eq '^litellm==1\.82\.[78] ' "$lock"
router_venv="$(sed -n '/python3 -m venv \/app\/router\/venv/,/Installing LiteLLM/p' "$INSTALLER")"
assert_not_contains "the router venv no longer installs litellm" "litellm-proxy/requirements" "$router_venv"

summary
