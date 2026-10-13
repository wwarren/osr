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
