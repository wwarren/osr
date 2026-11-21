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
INSTALLER="${1:-${ROOT}/open-smart-router-install.sh}"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"

describe embedded_copies
out="$(python3 "${ROOT}/tools/sync-embedded.py" --check 2>&1)"; rc=$?
assert_eq "installer heredocs match the repo files" "0" "$rc"
[[ $rc -eq 0 ]] || printf '%s\n' "$out" >&2

describe installer_owned_list
eval "$(sed -n '/^INSTALLER_OWNED_CODE=(/,/^)/p' "$INSTALLER")"
# Windows Python emits CRLF even when invoked from Git Bash.
embedded="$(python3 "${ROOT}/tools/sync-embedded.py" --list | tr -d '\r' | sort)"
owned="$(printf '%s\n' "${INSTALLER_OWNED_CODE[@]}" | sort)"
# Every embedded file except the tunables (*.ini) must be installer-owned...
missing="$(comm -23 <(grep -v '\.ini$' <<< "$embedded") <(printf '%s\n' "$owned"))"
assert_eq "every embedded code file is updated on re-install" "" "$missing"
# ...and every owned entry must be something the installer really ships.
extra="$(comm -13 <(printf '%s\n' "$embedded") <(printf '%s\n' "$owned" | grep -v 'requirements\.lock$'))"
assert_eq "no owned entry the installer does not ship" "" "$extra"
assert_fail "tunables stay seed-if-missing" grep -qx 'services/osr-router/router.ini' <<< "$owned"

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
  "EnvironmentFile=-/app/router/secrets.env" "${ROOT}/services/osr-monitor/osr-monitor.service"

describe unit_hardening
for unit in "${ROOT}"/services/*/*.service "${ROOT}"/targets/*/*.service; do
  assert_file_contains "$(basename "$unit") is ProtectSystem=strict" "ProtectSystem=strict" "$unit"
  assert_file_contains "$(basename "$unit") drops capabilities" "CapabilityBoundingSet=" "$unit"
done

describe inference_targets
for dir in "${ROOT}"/targets/*/; do
  name=$(basename "$dir")
  assert_fail "targets/${name} is not a nested git repository" test -e "${dir}.git"
  # FreeLLMAPI's CT is its container image (a Proxmox OCI-image CT): there is
  # no guest to install into, so its provisioner does the whole job.
  if [[ $name == freellmapi ]]; then
    assert_fail "targets/${name} has no guest installer (the CT is the image)" test -e "${dir}install-target.sh"
  else
    assert_ok "targets/${name} has an install-target.sh" test -f "${dir}install-target.sh"
  fi
  assert_ok "targets/${name} has a provision-lxc.sh" test -f "${dir}provision-lxc.sh"
done
dropin="${ROOT}/targets/ollama/ollama-target.conf"
assert_file_contains "the Ollama drop-in is ProtectSystem=strict" "ProtectSystem=strict" "$dropin"
assert_file_contains "the Ollama drop-in drops capabilities" "CapabilityBoundingSet=" "$dropin"
assert_file_contains "the Ollama drop-in runs unprivileged" "User=ollama" "$dropin"
assert_ok "the Ollama target starts from the community script" \
  grep -q 'community-scripts/ProxmoxVE/main/ct/ollama.sh' "${ROOT}/targets/ollama/provision-lxc.sh"
comfy="${ROOT}/targets/comfyui"
assert_file_contains "the ComfyUI drop-in is ProtectSystem=strict" "ProtectSystem=strict" "${comfy}/comfyui-target.conf"
assert_file_contains "the ComfyUI drop-in drops capabilities" "CapabilityBoundingSet=" "${comfy}/comfyui-target.conf"
assert_file_contains "the ComfyUI drop-in runs unprivileged" "User=comfyui" "${comfy}/comfyui-target.conf"
assert_ok "the ComfyUI drop-in replaces the community unit's root ExecStart" grep -qx 'ExecStart=' "${comfy}/comfyui-target.conf"
assert_ok "and keeps every writable ComfyUI folder in its state directory" \
  grep -q -- '--base-directory /var/lib/comfyui-target' "${comfy}/comfyui-target.conf"
assert_ok "the ComfyUI target starts from the community script" \
  grep -q 'community-scripts/ProxmoxVE/main/ct/comfyui.sh' "${comfy}/provision-lxc.sh"
# ComfyUI has no authentication: its CT must drop what the firewall does not admit.
assert_ok "the ComfyUI target firewalls its port" grep -q 'policy_in: DROP' "${comfy}/provision-lxc.sh"
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
for name in strata basalt maya xolotl avalon kindi colibri; do
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
assert_ok "open-terminal: rollback restores every saved file" grep -q 'cp -p -- "\$saved/file.\$i" "\${snapshot\[i\]}"' "$ot"
assert_ok "open-terminal: rollback removes files the run added" grep -q 'rm -f -- "\${snapshot\[i\]:?}"' "$ot"
assert_ok "open-terminal: the earlier shared-workspace unit is in the snapshot" grep -q 'snapshot+=("\$OT_ETC/clients.json" "\$UNIT_DIR/\$LEGACY_UNIT")' "$ot"
# Configuration must not change before the new venv is ready (a refused tag or
# dependency drift would otherwise leave a new port behind).
env_line=$(grep -n 'content_of "\$from" > "\$dest.new"' "$ot" | head -n1 | cut -d: -f1)
venv_line=$(grep -n 'pip install --no-cache-dir --no-deps' "$ot" | head -n1 | cut -d: -f1)
assert_ok "open-terminal: configuration is written after the venv is built" \
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
  # Hermes and OpenClaw (agent clients), Honcho (memory infrastructure), and the Gitea and Mattermost services
  # are upgraded by their own updaters (hermes update, openclaw update, the
  # community script, apt); the inference-target rollback contract does not
  # apply to them.
  case $name in hermes|openclaw|honcho|gitea|mattermost) continue ;; esac
  # Code lines of the target's tests (comments do not count as a test).
  tests_code="cat '${dir}'test-*.sh | grep -vE '^[[:space:]]*#'"
  upgrader="${dir}install-target.sh"
  [[ -f $upgrader ]] || upgrader="${dir}provision-lxc.sh"   # freellmapi: no guest installer
  if grep -qE -- '--upgrade\)' "$upgrader"; then
    assert_ok "${name}: a test runs --upgrade" bash -c "${tests_code} | grep -q -- '--upgrade'"
  fi
  assert_ok "${name}: a test checks a rollback that succeeds" bash -c "${tests_code} | grep -qE 'running.* again'"
  assert_ok "${name}: a test checks a rollback that fails too" \
    bash -c "${tests_code} | grep -qE 'did not (become healthy|answer|come back) either|failed too'"
  # An upgrade with nothing to change leaves the target alone, and a test says so.
  assert_ok "${name}: an unchanged upgrade does nothing" grep -q 'nothing to do' "$upgrader"
  assert_ok "${name}: and a test checks it" bash -c "grep -lq 'nothing to do' '${dir}'test-*.sh"
done

describe pct_create_umask
# Proxmox extracts an unprivileged CT template with the caller's umask; under a
# script-wide umask 077 the mapped root user cannot open the rootfs and
# pct create fails ("tar: /var/lib/lxc/<id>/rootfs: Cannot open: Permission
# denied"). Every provisioner that creates a CT scopes umask 022 to it.
for p in "${ROOT}"/targets/*/provision-lxc.sh; do
  name=$(basename "$(dirname "$p")")
  grep -vE '^[[:space:]]*#' "$p" | grep -qE 'pct create|create=\(pct create' || continue
  assert_ok "${name}: pct create runs under umask 022" grep -qE 'umask 022' "$p"
  assert_fail "${name}: never runs the create command under the script's umask" \
    grep -qE '^[[:space:]]*(run )?"\$\{create\[@\]\}"[[:space:]]*$' "$p"
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

describe xolotl_target
# The Xolotl target downloads ~372 GB from Hugging Face and serves an API key
# from a config file: keep its weights pinned and its key out of the unit.
xolotl="${ROOT}/targets/xolotl"
assert_ok "every weight URL names a commit of its repository" \
  awk '!/^#/ && NF && $2 != "join" && $6 !~ /^https:\/\/huggingface\.co\/[^ ]+\/resolve\/[0-9a-f]{40}\// { exit 1 }' "${xolotl}/xolotl-weights.txt"
assert_ok "every weight has a hash" \
  awk '!/^#/ && NF && $5 !~ /^(sha256:[0-9a-f]{64}|git:[0-9a-f]{40})$/ { exit 1 }' "${xolotl}/xolotl-weights.txt"
assert_fail "the unit carries no key" grep -qi 'api.key' <(grep -v '^#' "${xolotl}/xolotl.service")
assert_ok "the unit leaves the checkout read-only" grep -qx 'ReadWritePaths=/var/lib/xolotl /dev/shm' "${xolotl}/xolotl.service"
pin="$(< "${xolotl}/upstream-commit.txt")"
assert_ok "the Xolotl default pin is a full commit" grep -Eq '^[0-9a-f]{40}$' "${xolotl}/upstream-commit.txt"
assert_ok "the README names the tested pin" grep -q "$pin" "${xolotl}/README.md"
assert_ok "CI fetches the default pin" grep -q 'targets/xolotl/upstream-commit.txt' "${ROOT}/.gitea/workflows/tests.yml"
assert_ok "CI checks the target against the pinned upstream code" \
  grep -q 'targets/xolotl/test-pinned-upstream.py' "${ROOT}/.gitea/workflows/tests.yml"

describe avalon_target
# The Avalon target downloads ~90 GiB from Hugging Face and reads its API key
# from a file: keep its weights pinned to one revision and its key out of the
# unit and its environment, and its ROCm repository pinned to AMD's key.
avalon="${ROOT}/targets/avalon"
assert_ok "every weight URL names a commit of its repository" \
  awk '!/^#/ && NF && $5 !~ /^https:\/\/huggingface\.co\/[^ ]+\/resolve\/[0-9a-f]{40}\// { exit 1 }' "${avalon}/avalon-weights.txt"
assert_ok "every weight has a hash" \
  awk '!/^#/ && NF && $4 !~ /^(sha256:[0-9a-f]{64}|git:[0-9a-f]{40})$/ { exit 1 }' "${avalon}/avalon-weights.txt"
assert_eq "one revision for every weight" 1 \
  "$(grep -v '^#' "${avalon}/avalon-weights.txt" | grep -oE '/resolve/[0-9a-f]{40}/' | sort -u | wc -l | tr -d ' ')"
assert_fail "the unit carries no key" grep -qi 'api.key' <(grep -v '^#' "${avalon}/avalon.service")
assert_ok "the key reaches llama-server as a file" grep -q -- '--api-key-file "\$(key_file)"' "${avalon}/install-target.sh"
assert_fail "and never as --api-key" grep -qE -- '--api-key[^-]' "${avalon}/install-target.sh"
assert_ok "the unit leaves the checkout read-only" grep -qx 'ReadWritePaths=/var/lib/avalon /dev/shm' "${avalon}/avalon.service"
assert_ok "ROCm's repository key is checked against AMD's fingerprint" \
  grep -qx 'ROCM_KEY_FINGERPRINT=CA8BB4727A47B4D09B4EE8969386B48A1A693C5C' "${avalon}/rocm-toolkit.sh"
assert_ok "the web UI is neither built nor downloaded" grep -q -- '-DLLAMA_USE_PREBUILT_UI=OFF' "${avalon}/install-target.sh"
pin="$(< "${avalon}/upstream-commit.txt")"
assert_ok "the Avalon default pin is a full commit" grep -Eq '^[0-9a-f]{40}$' "${avalon}/upstream-commit.txt"
assert_ok "the README names the tested pin" grep -q "$pin" "${avalon}/README.md"
assert_ok "CI fetches the default pin" grep -q 'targets/avalon/upstream-commit.txt' "${ROOT}/.gitea/workflows/tests.yml"
assert_ok "CI checks the target against the pinned upstream code" \
  grep -q 'targets/avalon/test-pinned-upstream.py' "${ROOT}/.gitea/workflows/tests.yml"

describe kindi_target
# The Kindi target downloads pinned model files and CUDA 10.2, builds a venv
# from hash locks and keeps its API key in Kindi's config file only.
kindi="${ROOT}/targets/kindi"
assert_ok "every weight URL names a commit of its repository" \
  awk '!/^#/ && NF && $5 !~ /^https:\/\/huggingface\.co\/[^ ]+\/resolve\/[0-9a-f]{40}\// { exit 1 }' "${kindi}/kindi-weights.txt"
assert_ok "every weight has a SHA-256" \
  awk '!/^#/ && NF && $4 !~ /^sha256:[0-9a-f]{64}$/ { exit 1 }' "${kindi}/kindi-weights.txt"
assert_fail "the unit carries no key" grep -qi 'api.key' <(grep -v '^#' "${kindi}/kindi.service")
assert_ok "the unit leaves the checkout read-only" grep -qx 'ReadWritePaths=/var/lib/kindi /dev/shm' "${kindi}/kindi.service"
assert_ok "the venv is built from a hash lock" grep -q 'pip sync --quiet --require-hashes' "${kindi}/install-target.sh"
assert_ok "and uv from its own" grep -q -- '--no-deps --require-hashes' "${kindi}/install-target.sh"
for lock in requirements-cpu.lock requirements-cuda.lock uv.lock; do
  assert_ok "${lock} pins every package with a hash" \
    awk '/^[A-Za-z0-9]/ { if ($0 !~ /^[A-Za-z0-9_.-]+==[^ ]+ \\$/) exit 1; n++ } /--hash=sha256:/ { h++ } END { exit !(n && h >= n) }' "${kindi}/${lock}"
done
assert_ok "the CUDA 10.2 runfile is checked against NVIDIA's published MD5" \
  grep -qx 'CUDA_RUNFILE_MD5=${CUDA_RUNFILE_MD5:-3d816c583759efa8567a92c1a2af90db}' "${kindi}/cuda-toolkit.sh"
assert_ok "and installed as the toolkit only" grep -q 'sh "$runfile" --silent --toolkit ' "${kindi}/cuda-toolkit.sh"
pin="$(< "${kindi}/upstream-commit.txt")"
assert_ok "the Kindi default pin is a full commit" grep -Eq '^[0-9a-f]{40}$' "${kindi}/upstream-commit.txt"
assert_ok "the README names the tested pin" grep -q "$pin" "${kindi}/README.md"
assert_ok "CI fetches the default pin" grep -q 'targets/kindi/upstream-commit.txt' "${ROOT}/.gitea/workflows/tests.yml"
assert_ok "CI checks the target against the pinned upstream code" \
  grep -q 'targets/kindi/test-pinned-upstream.py' "${ROOT}/.gitea/workflows/tests.yml"

describe colibri_target
# The Colibri target builds a pinned commit, never downloads a model, and gives
# coli serve its key through a root-only EnvironmentFile (never argv).
colibri="${ROOT}/targets/colibri"
pin="$(sed -n 's/^COLIBRI_DEFAULT_COMMIT=\([0-9a-f]\{40\}\)$/\1/p' "${colibri}/install-target.sh")"
assert_ok "the Colibri default pin is a full commit" test "${#pin}" -eq 40
assert_eq "the provisioner pins the same commit" "$pin" \
  "$(sed -n 's/^COLIBRI_DEFAULT_COMMIT=\([0-9a-f]\{40\}\)$/\1/p' "${colibri}/provision-lxc.sh")"
assert_ok "the README names the tested pin" grep -q "$pin" "${colibri}/README.md"
assert_ok "CI fetches the default pin" grep -q 'targets/colibri/install-target.sh)' "${ROOT}/.gitea/workflows/tests.yml"
assert_ok "CI checks the target against the pinned upstream code" \
  grep -q 'targets/colibri/test-pinned-upstream.py' "${ROOT}/.gitea/workflows/tests.yml"
assert_ok "the unit loads the key from secrets.env" grep -qx 'EnvironmentFile=/etc/colibri-target/secrets.env' "${colibri}/colibri.service"
assert_fail "the unit names no key file" grep -q '/api-key' <(grep -v '^#' "${colibri}/colibri.service")
assert_fail "the launcher never puts the key on a command line" grep -qE -- '--api-key "\$api_key"|\( *--api-key' "${colibri}/install-target.sh"
assert_ok "the router knows the colibri kind" grep -q '"colibri": {"prefix": "colibri+", "key_env": "COLIBRI_API_KEY"' "${ROOT}/services/osr-router/router.py"
assert_ok "the installer offers the target with its key" grep -q "'colibri|model|.*|colibri+http://@IP@:@PORT@|colibri|optional:nvidia,amd,intel'" "$INSTALLER"
for agent in hermes openclaw opencode; do
  assert_ok "${agent} reaches colibri servers" grep -q '"kindi", "colibri")' "${ROOT}/targets/${agent}/provision-lxc.sh"
done
for agent in hermes openclaw opencode honcho; do
  assert_ok "${agent} copies the Colibri key" grep -q 'KINDI_API_KEY|COLIBRI_API_KEY)' "${ROOT}/targets/${agent}/provision-lxc.sh"
done

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
# install/manage-model-servers.sh is the only copy. A second file of the same
# name (the old repo-root launcher) drifted from it once, and was later copied
# over the real tool in a container by mistake.
assert_ok "install/manage-model-servers.sh exists" test -f "${ROOT}/install/manage-model-servers.sh"
assert_fail "no manage-model-servers.sh in the repo root" test -e "${ROOT}/manage-model-servers.sh"
others="$(cd "$ROOT" && find . -name 'manage-model-servers*' -not -path './.git/*' -not -path ./install/manage-model-servers.sh -not -path './tests/*')"
assert_eq "no other copy anywhere in the tree" "" "$others"

describe honcho_dispatch_copy
# Honcho's proxy imports the Hermes dispatcher from its own directory; the copy
# must stay the same file, or a fix to one would silently miss the other.
assert_ok "targets/honcho/direct_dispatch.py is the same as targets/hermes/direct-dispatch.py" \
  cmp -s "${ROOT}/targets/honcho/direct_dispatch.py" "${ROOT}/targets/hermes/direct-dispatch.py"
assert_contains "the proxy unit runs it from a directory of its own" \
  "/usr/local/lib/honcho-proxy/honcho-proxy.py" "$(cat "${ROOT}/targets/honcho/honcho-proxy.service")"

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
ci="${ROOT}/.gitea/workflows/tests.yml"
assert_ok "CI builds the retry test's LiteLLM from the hash lock" \
  grep -q 'pip install --require-hashes -r services/litellm-proxy/requirements.lock' "$ci"
assert_ok "CI runs the retry test under that LiteLLM" grep -q 'LITELLM_PYTHON: .*/.venv-litellm/bin/python' "$ci"
assert_ok "the runner registers the retry test" grep -q 'test-litellm-retries.py.*LITELLM_PYTHON' "${ROOT}/tests/run-tests.sh"
assert_ok "CI checks Honcho's model-client timeout at the pinned release" \
  grep -q 'targets/honcho/test-pinned-upstream.py' "$ci"

describe target_tags
# tools/upgrade-all.sh finds the router by its osr-router tag and each target by
# osr-target plus the target's name. Every tag list a provisioner sets (pct
# create --tags, a community script's var_tags, pve_ensure_tags) must say the
# same, and a community-script target must re-apply its tags after the script.
eval "$(sed -n '/^TARGET_ORDER=(/,/)/p' "${ROOT}/tools/upgrade-all.sh")"
assert_ok "upgrade-all.sh lists its targets" test "${#TARGET_ORDER[@]}" -gt 0
for dir in "${ROOT}"/targets/*/; do
  name=$(basename "$dir")
  [[ -f ${dir}provision-lxc.sh && $name != hcom ]] || continue
  assert_contains "upgrade-all.sh upgrades the ${name} target" " ${name} " " ${TARGET_ORDER[*]} "
done
for name in "${TARGET_ORDER[@]}"; do
  provisioner="${ROOT}/targets/${name}/provision-lxc.sh"
  lists="$( { grep -oE -- "--tags '[^']*'" "$provisioner" | sed -E "s/^--tags '(.*)'$/\1/"
              grep -oE 'var_tags=[^" ]*' "$provisioner" | sed 's/^var_tags=//'
              grep -oE 'pve_ensure_tags "\$CT_ID" [a-z0-9 -]*' "$provisioner" |
                sed -E 's/^pve_ensure_tags "\$CT_ID" //; s/ +$//; s/ /;/g'; } | sort -u)"
  assert_ok "${name} tags its CT" test -n "$lists"
  if [[ $lists != "ai;ai-model;osr-target;${name}" && $lists != "ai;ai-tools;osr-target;${name}" ]]; then
    _fail "${name} tags its CT with osr-target and ${name}, the same everywhere" \
      "ai;ai-model;osr-target;${name} or ai;ai-tools;osr-target;${name}" "$(tr '\n' ' ' <<< "$lists")"
  else
    _pass "${name} tags its CT with osr-target and ${name}, the same everywhere"
  fi
  if grep -q 'var_tags=' "$provisioner"; then
    assert_ok "${name} re-applies its tags after the community script" grep -q '^ *pve_ensure_tags "\$CT_ID"' "$provisioner"
  fi
done
assert_ok "the router CT is tagged osr-router" grep -qE -- '-tags "([^"]*;)?osr-router(;[^"]*)?"' "$INSTALLER"

# env/router.env says where things are; what the installer writes there must be
# read by something, and the sample in the repository must show the same keys.
describe env_settings
template="$(sed -n '/^cat > "\${REPO_DIR}\/env\/router.env" <<EOF$/,/^EOF$/p' "$INSTALLER")"
written="$(grep -oE '^[A-Z][A-Z0-9_]*=' <<< "$template" | tr -d '=')"
sample="$(grep -oE '^[A-Z][A-Z0-9_]*=' "${ROOT}/env/router.env" | tr -d '=')"
assert_ok "the installer's router.env template is found" test -n "$written"
assert_eq "the sample env/router.env has the installer's keys, in its order" "$written" "$sample"
readers=("${ROOT}/services/osr-router/router.py" "${ROOT}/services/osr-monitor/monitor.py"
         "${ROOT}/install/manage-model-servers.sh")
for key in $written KEEP_ALIVE_REFRESH_SECONDS; do
  case $key in
    CLOUD_*_MODELS) pattern='CLOUD_[{%]' ;;     # read by name pattern, per provider
    *) pattern="\\b${key}\\b" ;;
  esac
  assert_ok "${key} is read by the router, the monitor or the manager" grep -Eq "$pattern" "${readers[@]}"
done
for key in LITELLM_HEALTH_URL LITELLM_URL MODEL_SERVER_COUNT MONITOR_INTERVAL_SECONDS; do
  assert_not_contains "the installer no longer writes ${key}" "${key}=" "$template"
done
assert_fail "a comment in the template cannot expand anything" grep -Eq '^#.*[$`]' <<< "$template"
for name in $(sed -n '/^ENV_OVERRIDES = (/,/^)/p' "${ROOT}/services/osr-monitor/monitor.py" | grep -oE '"(MONITOR|KEEP)_[A-Z_]+"' | tr -d '"'); do
  assert_ok "README names the monitor override ${name}" grep -q "$name" "${ROOT}/README.md"
done

describe router_requirements
req="${ROOT}/services/osr-router/requirements.txt"
for package in fastapi uvicorn httpx uvloop httptools; do
  assert_ok "the router pins ${package} exactly" grep -Eq "^${package}==[0-9][0-9A-Za-z.]*( *;.*)?$" "$req"
done
assert_fail "uvicorn's extras are not pulled in wholesale" grep -q 'uvicorn\[' "$req"
for package in uvloop httptools; do
  assert_ok "${package} is skipped where it has no wheel" grep -Eq "^${package}==.*; *sys_platform == \"linux\" and \(platform_machine" "$req"
done
unit="${ROOT}/services/open-webui/open-webui.service"
assert_fail "a router restart does not restart Open WebUI" grep -Eq '^(Requires|BindsTo|PartOf)=.*osr-router' "$unit"
assert_ok "Open WebUI still starts the router, and after it" bash -c \
  "grep -Eq '^Wants=.*osr-router\.service' '$unit' && grep -Eq '^After=.*osr-router\.service' '$unit'"

# Gitea reads .gitea/workflows, GitHub .github/workflows: one workflow, two
# places, kept identical so neither forge runs a stale copy.
describe ci_workflows
assert_ok "the GitHub workflow is the Gitea workflow" \
  cmp -s "${ROOT}/.gitea/workflows/tests.yml" "${ROOT}/.github/workflows/tests.yml"
assert_file_contains "CI installs Node.js for configure.test.mjs" "actions/setup-node@" "${ROOT}/.gitea/workflows/tests.yml"
assert_file_contains "CI runs the suites strictly" "tests/run-tests.sh --strict" "${ROOT}/.gitea/workflows/tests.yml"

# Every companion in the installer's target table waits for the Open WebUI
# admin key (provision_selected_targets), so README's Install section must
# name each of them. A new companion needs a name here and in that sentence.
describe readme_admin_key_companions
sentence="$(tr '\n' ' ' < "${ROOT}/README.md" | grep -oE 'Companions that register with Open +WebUI +\([^)]*\) +need an Open WebUI +admin API key' | tr -s ' ')"
assert_ok "README names the companions that need the admin key" test -n "$sentence"
companions="$(sed -n "/^target_table() {/,/^}/p" "$INSTALLER" | grep -oE "'[a-z-]+\|companion\|" | sed -E "s/^'([a-z-]+)\|.*/\1/")"
assert_ok "the installer's target table lists companions" test -n "$companions"
listed="${sentence#*(}"; listed=", ${listed%%)*},"
for name in $companions; do
  case $name in
    honcho) label='Honcho' ;; hermes) label='Hermes' ;; openclaw) label='OpenClaw' ;;
    deepseek-harness) label='DeepSeek Harness' ;; opencode) label='OpenCode' ;;
    open-terminal) label='Open Terminal' ;; comfyui) label='ComfyUI' ;;
    *) label="(no README name for ${name})" ;;
  esac
  assert_contains "README lists ${name} among the admin-key companions" ", ${label}," "$listed"
done
count="$(grep -o ',' <<< "${listed#, }" | wc -l)"
assert_eq "and no target that is not a companion" "$(wc -w <<< "$companions" | tr -d ' ')" "$count"

describe router_metrics_stack
metrics_setup="${ROOT}/install/setup-metrics.sh"
assert_ok "metrics setup is valid bash" bash -n "$metrics_setup"
assert_file_contains "Prometheus uses a protected router key" 'credentials_file: ${KEY_FILE}' "$metrics_setup"
assert_file_contains "Prometheus only listens on loopback" '--web.listen-address=127.0.0.1:9090' "$metrics_setup"
assert_file_contains "the package Prometheus listener is masked" 'systemctl mask prometheus.service' "$metrics_setup"
assert_file_contains "metrics storage has a size limit" '--storage.tsdb.retention.size=512MB' "$metrics_setup"
assert_file_contains "Grafana does not allow anonymous access" 'GF_AUTH_ANONYMOUS_ENABLED=false' "$metrics_setup"
assert_file_contains "apply refreshes the Prometheus key" 'setup-metrics.sh" sync-key' "${ROOT}/install/manage-model-servers.sh"
assert_ok "Prometheus is installed without its recommended node exporter" \
  grep -q 'apt-get install -y --no-install-recommends ca-certificates wget prometheus' "$metrics_setup"
assert_file_contains "the installer can leave the metrics stack out" 'INSTALL_METRICS' "$INSTALLER"
assert_file_contains "the installer configures host temperatures" 'tools/setup-temperature-exporter.sh' "$INSTALLER"
assert_file_contains "host sensors have a separate scrape key" 'credentials_file: /etc/prometheus/osr-sensors-key' "$metrics_setup"
assert_ok "host exporter setup is valid bash" bash -n "${ROOT}/tools/setup-temperature-exporter.sh"
assert_ok "the firewall rule for Grafana cannot undo a finished install" bash -c \
  "[[ \$(grep -n -- '-dport 3000 -log nolog' '$INSTALLER' | head -1 | cut -d: -f1) -gt \$(grep -n '^trap - ERR' '$INSTALLER' | tail -1 | cut -d: -f1) ]]"
assert_file_contains "the installer opens Grafana to the trusted CIDR" '-dport 3000 -log nolog' "$INSTALLER"
assert_file_contains "the installer's summary shows the Grafana login" 'install/setup-metrics.sh" login' "$INSTALLER"
assert_file_contains "upgrade-all shows it too" 'setup-metrics.sh login' "${ROOT}/tools/upgrade-all.sh"
assert_ok "and only after its summary, which is what gets logged" bash -c \
  '! sed -n "/^print_summary() {/,/^}/p" "$1" | grep -q grafana' _ "${ROOT}/tools/upgrade-all.sh"
assert_file_contains "the README says how to see the login again" 'setup-metrics.sh login' "${ROOT}/README.md"
assert_ok "provisioned dashboard is valid JSON with all metric families" python3 - "$metrics_setup" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
assert source.index("EnvironmentFile=/etc/grafana/osr.env") < source.index('apt-get install -y "grafana')
assert source.index("systemctl mask prometheus.service") < source.index("apt-get install -y --no-install-recommends ca-certificates wget prometheus")
marker = "cat > \"${FS}/etc/grafana/osr-dashboards/router.json\" <<'EOF'\n"
dashboard = json.loads(source.split(marker, 1)[1].split("\nEOF", 1)[0])
expressions = "\n".join(target["expr"] for panel in dashboard["panels"]
                   for target in panel["targets"])
for name in ("osr_requests_total", "osr_upstream_failures_total",
             "osr_response_start_seconds_bucket", "osr_request_duration_seconds_bucket",
             "osr_in_flight_requests", "osr_server_up", "osr_server_models",
             "osr_inventory_age_seconds", "osr_remembered_conversations",
             "osr_cpu_temperature_celsius", "osr_gpu_temperature_celsius"):
    assert name in expressions, name
assert dashboard["uid"] == "osr-router"
assert len({panel["id"] for panel in dashboard["panels"]}) == len(dashboard["panels"])
assert all(0 <= panel["gridPos"]["x"] < 24 and
           panel["gridPos"]["x"] + panel["gridPos"]["w"] <= 24
           for panel in dashboard["panels"])
assert sum(panel["type"] == "stat" for panel in dashboard["panels"]) >= 4
assert 'up{job="osr"}' in expressions
assert 'status=~"5.."' in expressions
for name in ("osr_response_start_seconds_bucket", "osr_request_duration_seconds_bucket"):
    quantiles = [target["expr"] for panel in dashboard["panels"]
                 for target in panel["targets"] if name in target["expr"]]
    assert any(expr.startswith("histogram_quantile(0.5,") for expr in quantiles)
    assert any(expr.startswith("histogram_quantile(0.95,") for expr in quantiles)
PY

describe new_names_only
# A new install uses only the osr-* names: the units, their account, and the
# defaults for the Gitea router account and the Mattermost team, channel and
# posting name. Old names appear only where an existing install is migrated
# or recognised.
for unit in "$ROOT"/services/*/*.service; do
  if grep -E '^(User|Group)=' "$unit" | grep -qv '=osr-router$'; then
    assert_fail "${unit#"$ROOT"/} runs as osr-router" true
  else
    assert_ok "${unit#"$ROOT"/} runs as osr-router" true
  fi
done
inst="$ROOT/open-smart-router-install.sh"
assert_ok   "the installer creates the osr-router account" grep -q 'useradd --system --gid osr-router .* osr-router$' "$inst"
assert_fail "and no ollama-router account" grep -Eq '(useradd|groupadd).*ollama-router' "$inst"
assert_ok   "router.env posts as OSRMonitor" grep -qx 'MATTERMOST_MONITOR_USER=OSRMonitor' "$ROOT/env/router.env"
assert_ok   "to osr-monitor" grep -qx 'MATTERMOST_CHANNEL=osr-monitor' "$ROOT/env/router.env"
assert_ok   "the installer's channel default is osr-monitor" grep -q 'MATTERMOST_CHANNEL="${MATTERMOST_CHANNEL:-osr-monitor}"' "$inst"
assert_ok   "Gitea's router account default is osr-router" grep -q 'GITEA_ROUTER_USER=${GITEA_ROUTER_USER:-osr-router}' "$ROOT/targets/gitea/install-target.sh"
assert_ok   "Mattermost's team default is osr" grep -q 'default_team=osr default_channel=osr-monitor' "$ROOT/targets/mattermost/install-target.sh"
# Every other mention of an old name sits beside the migration or recognition
# code it belongs to: a line naming the old and the new name, or a comment
# saying it is from before the rename.
stray=$(cd "$ROOT" && git grep -n -E 'ollama-(router|monitor)|OllamaMonitor' -- \
          'services' 'install' 'env' 'targets/*/install-target.sh' 'targets/*/provision-lxc.sh' 'tools' 'open-smart-router-install.sh' 2>/dev/null |
        grep -viE 'osr-(router|monitor)|before (the|it was) renam|pre-rename|legacy|recorded|default_team=ollama')
assert_eq "no old name outside migration code" "" "$stray"

summary
