#!/usr/bin/env bash
# Unit tests for the functions in manage-model-servers.sh
#
# Each test gets a throwaway config repo, so nothing touches a real deployment.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-${HERE}/../manage-model-servers.sh}"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"
# shellcheck source=lib/mocks.sh
source "${HERE}/lib/mocks.sh"

[[ -f "$SCRIPT" ]] || { echo "script not found: $SCRIPT" >&2; exit 1; }

FUNCS="$(mktemp)"
python3 "${HERE}/lib/extract-functions.py" "$SCRIPT" > "$FUNCS" || exit 1
bash -n "$FUNCS" || { echo "extracted functions do not parse" >&2; exit 1; }

mocks_init
WORK="$(mktemp -d)"
trap 'mocks_cleanup; rm -rf "$WORK"; rm -f "$FUNCS"' EXIT

# Globals the functions expect.
REPO_DIR="${WORK}/repo"
ROUTER_DIR="${WORK}/router"
OPENWEBUI_DIR="${WORK}/openwebui"
ENV_FILE="${REPO_DIR}/env/router.env"
LITELLM_YAML="${REPO_DIR}/services/litellm-proxy/litellm_config.yaml"
ROUTER_INI="${REPO_DIR}/services/ollama-router/router.ini"
OPENWEBUI_REQ="${REPO_DIR}/services/open-webui/requirements.txt"
APPLY_SCRIPT="${REPO_DIR}/install/apply-config.sh"
OLLAMA_PORT=11434
MODEL_SERVER_MIN=1
MODEL_SERVER_MAX=20
ROUTER_URL="http://127.0.0.1:65999"
PROBE_TIMEOUT=2
SERVICES=(litellm-proxy ollama-router ollama-monitor open-webui)
declare -A TIER_MODEL_OVERRIDE=()
declare -A PAIR_MODEL_OVERRIDE=()
CHANGED=false; DRY_RUN=false; NO_PROBE=false
AUTO_APPLY=false; AUTO_COMMIT=false; ASSUME_YES=true
ORIG_ARGS=()
# shellcheck source=/dev/null
source "$FUNCS"

reset_repo() {
  rm -rf "$REPO_DIR"
  make_config_repo "$REPO_DIR"
  TIER_MODEL_OVERRIDE=(); PAIR_MODEL_OVERRIDE=(); CHANGED=false
}
reset_repo

echo "Testing $(basename "$SCRIPT") — $(python3 "${HERE}/lib/extract-functions.py" "$SCRIPT" --list | wc -l) functions extracted"

# ── trivial helpers ───────────────────────────────────────────────────────────
describe die
out="$(die "boom" 2>&1)"; rc=$?
assert_contains "prefixes ERROR" "ERROR: boom" "$out"
assert_status "exits non-zero" 1 bash -c "source '$FUNCS'; die x"

describe note
assert_eq "writes to stderr" "hello" "$(note hello 2>&1 1>/dev/null)"
assert_eq "writes nothing to stdout" "" "$(note hello 2>/dev/null)"

describe usage
out="$(usage)"
assert_contains "lists add"              "add <addr>"          "$out"
assert_contains "lists set-server-model" "set-server-model"    "$out"
assert_contains "lists set-webui-version" "set-webui-version"  "$out"
assert_contains "documents --dry-run"    "--dry-run"           "$out"

# ── address handling ──────────────────────────────────────────────────────────
describe valid_hostname_or_ip
assert_ok   "hostname"      valid_hostname_or_ip ollama1.lan
assert_fail "leading dash"  valid_hostname_or_ip -x
assert_fail "empty"         valid_hostname_or_ip ""

describe valid_addr
assert_ok   "bare ip"       valid_addr 10.0.0.5
assert_ok   "ip:port"       valid_addr 10.0.0.5:11434
assert_ok   "url"           valid_addr http://h:11434
assert_fail "port too big"  valid_addr 10.0.0.5:99999
assert_fail "empty"         valid_addr ""

describe normalize_addr
assert_eq "adds scheme+port"   "http://10.0.0.5:11434" "$(normalize_addr 10.0.0.5)"
assert_eq "keeps explicit port" "http://10.0.0.5:9999" "$(normalize_addr 10.0.0.5:9999)"
assert_eq "strips trailing /"   "http://h:1"           "$(normalize_addr http://h:1/)"
assert_eq "matches the installer normalisation" \
  "http://ollama1.lan:11434" "$(normalize_addr ollama1.lan)"

describe valid_keep_alive
assert_ok   "blank"    valid_keep_alive ""
assert_ok   "-1"       valid_keep_alive -1
assert_ok   "2h"       valid_keep_alive 2h
assert_fail "junk"     valid_keep_alive abc

# ── env file access ───────────────────────────────────────────────────────────
describe env_get
reset_repo
assert_eq "reads a plain value"    "tester" "$(env_get GITEA_ADMIN_USER)"
assert_eq "reads a comma list"     "http://10.0.0.51:11434,http://10.0.0.52:11434,http://10.0.0.53:11434" "$(env_get MODEL_SERVERS)"
assert_eq "reads an empty value"   ""       "$(env_get OLLAMA_KEEP_ALIVE)"
assert_eq "missing key is empty"   ""       "$(env_get NO_SUCH_KEY)"
assert_eq "value containing = is preserved" \
  "http://127.0.0.1:4000" "$(env_get LITELLM_BASE_URL)"

describe env_set
reset_repo
env_set OLLAMA_KEEP_ALIVE "2h"
assert_eq "updates in place"          "2h" "$(env_get OLLAMA_KEEP_ALIVE)"
env_set BRAND_NEW_KEY "hello"
assert_eq "appends a missing key"     "hello" "$(env_get BRAND_NEW_KEY)"
assert_eq "leaves other keys intact"  "tester" "$(env_get GITEA_ADMIN_USER)"
chmod 0640 "$ENV_FILE"
env_set OLLAMA_KEEP_ALIVE "3h"
assert_file_mode "preserves file mode (secrets stay 0640)" "640" "$ENV_FILE"
DRY_RUN=true
env_set OLLAMA_KEEP_ALIVE "9h" >/dev/null
assert_eq "dry-run writes nothing" "3h" "$(env_get OLLAMA_KEEP_ALIVE)"
DRY_RUN=false

describe tier_env_key
assert_eq "fast"   "BACKEND_QWEN_FAST"   "$(tier_env_key fast)"
assert_eq "medium" "BACKEND_QWEN_MEDIUM" "$(tier_env_key medium)"
assert_eq "heavy"  "BACKEND_QWEN_HEAVY"  "$(tier_env_key heavy)"
assert_fail "rejects an unknown tier" bash -c "source '$FUNCS'; tier_env_key turbo"

describe tier_model_name
reset_repo
assert_eq "reads from router.ini" "qwen-fast" "$(tier_model_name fast)"
printf '[tiers]\nfast = custom-fast\n' > "$ROUTER_INI"
assert_eq "honours a custom alias" "custom-fast" "$(tier_model_name fast)"
rm -f "$ROUTER_INI"
assert_eq "falls back when ini is missing" "qwen-heavy" "$(tier_model_name heavy)"
reset_repo

# ── list helpers ──────────────────────────────────────────────────────────────
describe csv_to_lines
assert_eq "splits on commas"        "3" "$(csv_to_lines 'a,b,c' | grep -c .)"
assert_eq "keeps the LAST element"  "c" "$(csv_to_lines 'a,b,c' | tail -1)"
assert_eq "empty input -> no lines" "0" "$(csv_to_lines '' | grep -c . || true)"
assert_eq "drops blank fields"      "2" "$(csv_to_lines 'a,,b' | grep -c .)"

describe lines_to_csv
assert_eq "joins with commas" "a,b,c" "$(printf 'a\nb\nc\n' | lines_to_csv)"
assert_eq "single line"       "a"     "$(printf 'a\n' | lines_to_csv)"

describe get_servers
reset_repo
assert_eq "all servers"      "3" "$(get_servers | grep -c .)"
env_set MODEL_SERVERS ""
assert_eq "no servers configured yields nothing" "0" "$(get_servers | grep -c . || true)"
reset_repo

describe get_tier
assert_eq "fast tier"        "1" "$(get_tier fast | grep -c .)"
assert_eq "heavy tier (two)" "2" "$(get_tier heavy | grep -c .)"
assert_fail "an unknown tier is rejected" get_tier turbo

describe contains_line
assert_ok   "finds an exact match"     bash -c "source '$FUNCS'; printf 'a\nb\n' | contains_line b"
assert_fail "rejects a partial match"  bash -c "source '$FUNCS'; printf 'abc\n' | contains_line b"
assert_ok   "matches a final line without newline" \
  bash -c "source '$FUNCS'; printf 'a\nb' | contains_line b"

describe tiers_of
reset_repo
assert_eq "server in one tier"   "fast"        "$(tiers_of http://10.0.0.51:11434)"
assert_eq "server in two tiers"  "medium,heavy" "$(tiers_of http://10.0.0.52:11434)"
assert_eq "unassigned server"    "—"           "$(tiers_of http://10.0.0.99:11434)"

# ── yaml reading ──────────────────────────────────────────────────────────────
describe current_pair_tag
reset_repo
assert_eq "reads the tag for a specific host" \
  "qwen3:32b" "$(current_pair_tag qwen-heavy http://10.0.0.52:11434)"
assert_eq "a different host in the same tier has its own tag" \
  "mixtral:8x7b" "$(current_pair_tag qwen-heavy http://10.0.0.53:11434)"
assert_eq "unknown pair is empty" "" "$(current_pair_tag qwen-heavy http://10.0.0.99:11434)"

describe current_tier_tag
assert_eq "first tag for the tier" "qwen3:32b" "$(current_tier_tag qwen-heavy)"
assert_eq "fast tier"              "qwen2.5-coder:7b" "$(current_tier_tag qwen-fast)"
assert_eq "unknown alias is empty" ""          "$(current_tier_tag nope)"

# ── reachability ──────────────────────────────────────────────────────────────
describe probe_server
mock_command curl 0 '{"models":[{"name":"a"},{"name":"b"}]}'
assert_eq "counts models"        "2" "$(probe_server http://h)"
mock_command curl 7
assert_eq "unreachable marker"   "-" "$(probe_server http://h)"
mock_command curl 0 'not json'
assert_eq "unparseable marker"   "?" "$(probe_server http://h)"

describe server_models
mock_command curl 0 '{"models":[{"name":"qwen3:32b"},{"name":"llava:13b"}]}'
assert_eq "lists names"  "qwen3:32b llava:13b" "$(server_models http://h | tr '\n' ' ' | sed 's/ $//')"
mock_command curl 7
assert_eq "unreachable yields nothing" "" "$(server_models http://h)"

describe model_present_on
mock_command curl 0 '{"models":[{"name":"qwen3:32b"},{"name":"phi4:latest"}]}'
assert_status "exact match -> 0"            0 model_present_on http://h qwen3:32b
assert_status "absent -> 1"                 1 model_present_on http://h nope:1b
assert_status "bare name matches :latest"   0 model_present_on http://h phi4
mock_command curl 7
assert_status "unreachable -> 2"            2 model_present_on http://h qwen3:32b

# ── regeneration ──────────────────────────────────────────────────────────────
describe regenerate_litellm
reset_repo
regenerate_litellm >/dev/null 2>&1
assert_file_contains "keeps per-host model A" "ollama/qwen3:32b"   "$LITELLM_YAML"
assert_file_contains "keeps per-host model B" "ollama/mixtral:8x7b" "$LITELLM_YAML"
assert_file_contains "preserves router_settings" "latency-based-routing" "$LITELLM_YAML"
assert_file_contains "preserves fallbacks"       "fallbacks"             "$LITELLM_YAML"
assert_eq "one deployment per (tier,server) pair" "4" "$(grep -c 'model_name:' "$LITELLM_YAML")"
TIER_MODEL_OVERRIDE[heavy]="new:1b"
regenerate_litellm >/dev/null 2>&1
assert_eq "tier override applies to every host in the tier" \
  "2" "$(grep -c 'ollama/new:1b' "$LITELLM_YAML")"
reset_repo
PAIR_MODEL_OVERRIDE["heavy|http://10.0.0.53:11434"]="solo:7b"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "per-pair override applied"      "ollama/solo:7b"     "$LITELLM_YAML"
assert_file_contains "the other host is untouched"    "ollama/qwen3:32b"   "$LITELLM_YAML"
reset_repo
env_set OLLAMA_KEEP_ALIVE "2h"
regenerate_litellm >/dev/null 2>&1
assert_eq "keep_alive emitted per deployment" "4" "$(grep -c 'keep_alive: 2h' "$LITELLM_YAML")"
env_set OLLAMA_KEEP_ALIVE ""
regenerate_litellm >/dev/null 2>&1
assert_eq "blank keep_alive emits nothing" "0" "$(grep -c 'keep_alive' "$LITELLM_YAML" || true)"
reset_repo

describe confirm
ASSUME_YES=true
assert_ok "yes flag skips the prompt" confirm "ok?"
ASSUME_YES=false; DRY_RUN=true
assert_ok "dry-run skips the prompt" confirm "ok?"
DRY_RUN=false
assert_ok   "accepts y" bash -c "source '$FUNCS'; ASSUME_YES=false; DRY_RUN=false; confirm x <<< 'y'"
assert_fail "rejects n" bash -c "source '$FUNCS'; ASSUME_YES=false; DRY_RUN=false; confirm x <<< 'n'"
ASSUME_YES=true

# ── mutating commands ─────────────────────────────────────────────────────────
describe cmd_add
reset_repo; NO_PROBE=true
cmd_add 10.0.0.60 >/dev/null 2>&1
assert_eq "server appended"     "4" "$(get_servers | grep -c .)"
assert_eq "not tiered by default" "—" "$(tiers_of http://10.0.0.60:11434)"
reset_repo
TIER_ARG="heavy"; cmd_add 10.0.0.60 >/dev/null 2>&1; TIER_ARG=""
assert_eq "--tier assigns it"   "heavy" "$(tiers_of http://10.0.0.60:11434)"
reset_repo
cmd_add 10.0.0.51 >/dev/null 2>&1
assert_eq "duplicate is skipped" "3" "$(get_servers | grep -c .)"
assert_fail "rejects an invalid address" bash -c "source '$FUNCS'; REPO_DIR='$REPO_DIR'; ENV_FILE='$ENV_FILE'; NO_PROBE=true; ASSUME_YES=true; cmd_add 'not valid'"
MODEL_SERVER_MAX=3
assert_fail "refuses to exceed the maximum" cmd_add 10.0.0.70
MODEL_SERVER_MAX=20

describe cmd_remove
reset_repo
cmd_remove http://10.0.0.53:11434 >/dev/null 2>&1
assert_eq "server removed"        "2" "$(get_servers | grep -c .)"
assert_eq "tier membership cleaned" "1" "$(get_tier heavy | grep -c .)"
reset_repo
cmd_remove 1 >/dev/null 2>&1
assert_eq "removal by list number" "2" "$(get_servers | grep -c .)"
reset_repo
MODEL_SERVER_MIN=3
assert_fail "refuses to drop below the minimum" cmd_remove 1
MODEL_SERVER_MIN=1
reset_repo
out="$(cmd_remove http://10.0.0.51:11434 2>&1)"
assert_contains "warns when a tier is emptied" "no servers" "$out"

describe cmd_set_tier
reset_repo
cmd_set_tier medium http://10.0.0.51:11434 http://10.0.0.53:11434 >/dev/null 2>&1
assert_eq "replaces the membership" "2" "$(get_tier medium | grep -c .)"
assert_fail "rejects an unconfigured server" cmd_set_tier medium 10.9.9.9
assert_fail "rejects an unknown tier"        cmd_set_tier turbo http://10.0.0.51:11434
reset_repo

describe cmd_set_model
reset_repo
cmd_set_model heavy newmodel:1b >/dev/null 2>&1
assert_eq "applies to every host in the tier" "2" "$(grep -c 'ollama/newmodel:1b' "$LITELLM_YAML")"
assert_fail "rejects an ollama/ prefix" cmd_set_model heavy ollama/x
assert_fail "rejects an unknown tier"   cmd_set_model turbo x
reset_repo

describe cmd_set_server_model
reset_repo; NO_PROBE=true
cmd_set_server_model heavy http://10.0.0.53:11434 solo:7b >/dev/null 2>&1
assert_file_contains "sets the chosen host"       "ollama/solo:7b"   "$LITELLM_YAML"
assert_file_contains "leaves the other host alone" "ollama/qwen3:32b" "$LITELLM_YAML"
assert_fail "rejects a host outside the tier" cmd_set_server_model fast http://10.0.0.53:11434 x:1b
assert_fail "rejects an unconfigured host"    cmd_set_server_model heavy 10.9.9.9 x:1b
assert_fail "rejects an ollama/ prefix"       cmd_set_server_model heavy http://10.0.0.53:11434 ollama/x
reset_repo

describe resolve_server_arg
reset_repo
assert_eq "by address" "http://10.0.0.51:11434" "$(resolve_server_arg 10.0.0.51)"
assert_eq "by number"  "http://10.0.0.52:11434" "$(resolve_server_arg 2)"
assert_fail "unknown address" resolve_server_arg 10.9.9.9
assert_fail "out-of-range number" resolve_server_arg 99

describe cmd_set_keepalive
reset_repo
cmd_set_keepalive 2h >/dev/null 2>&1
assert_eq "stores the value" "2h" "$(env_get OLLAMA_KEEP_ALIVE)"
assert_file_contains "regenerates the yaml with it" "keep_alive: 2h" "$LITELLM_YAML"
cmd_set_keepalive "" >/dev/null 2>&1
assert_eq "blank clears it" "" "$(env_get OLLAMA_KEEP_ALIVE)"
assert_fail "rejects a bad value" cmd_set_keepalive 5x

describe cmd_models
reset_repo
mock_command curl 0 '{"models":[{"name":"qwen3:32b"}]}'
out="$(cmd_models 2>&1)"
assert_contains "lists the model"     "qwen3:32b" "$out"
assert_contains "shows a HOSTS column" "HOSTS"    "$out"
mock_command curl 7
out="$(cmd_models 2>&1)"
assert_contains "reports when nothing answers" "none" "$out"

describe cmd_list
reset_repo
out="$(cmd_list false 2>&1)"
assert_contains "shows servers"         "10.0.0.51" "$out"
assert_contains "shows the keep-alive"  "Keep-alive" "$out"
assert_contains "one row per deployment" "qwen-heavy" "$out"
assert_contains "shows per-host models" "mixtral:8x7b" "$out"

describe cmd_discover
reset_repo
mock_command curl 7
out="$(cmd_discover 2>&1)"; rc=$?
assert_contains "reports an unreachable router" "Could not reach the router" "$out"
assert_ne "returns non-zero" "0" "$rc"
mock_command curl 0 '{"server_status":{"http://a":{"up":true,"model_count":2}},"age_seconds":1.5,"models":[{"server":"http://a","name":"m1","params_b":7,"is_code":true,"is_vision":false,"is_embedding":false}],"errors":{}}'
out="$(cmd_discover 2>&1)"
assert_contains "renders host status" "up" "$out"
assert_contains "renders the inventory" "m1" "$out"
assert_contains "renders capability flags" "code" "$out"
mock_command curl 0 'not json'
out="$(cmd_discover 2>&1)"
assert_contains "handles a non-JSON reply" "did not parse" "$out"

# ── open webui version ────────────────────────────────────────────────────────
describe openwebui_current_version
reset_repo
assert_eq "reads the pin" "0.6.5" "$(openwebui_current_version)"
printf '' > "$OPENWEBUI_REQ"
assert_eq "empty file is empty" "" "$(openwebui_current_version)"
reset_repo

describe openwebui_installed_version
mkdir -p "${OPENWEBUI_DIR}/venv/bin"
printf '#!/usr/bin/env bash\necho 0.9.1\n' > "${OPENWEBUI_DIR}/venv/bin/python"
chmod +x "${OPENWEBUI_DIR}/venv/bin/python"
assert_eq "queries the venv" "0.9.1" "$(openwebui_installed_version)"
rm -f "${OPENWEBUI_DIR}/venv/bin/python"
assert_eq "no venv -> empty" "" "$(openwebui_installed_version)"

describe openwebui_python_ok
mkdir -p "${OPENWEBUI_DIR}/venv/bin"
ln -sf "$(command -v python3)" "${OPENWEBUI_DIR}/venv/bin/python"
pv="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
assert_ok   "empty spec always passes" openwebui_python_ok ""
assert_ok   "satisfied spec"           openwebui_python_ok ">=3.0"
assert_fail "unsatisfiable spec"       openwebui_python_ok ">=99.0"
assert_fail "excluded upper bound"     openwebui_python_ok "<3.0"

describe pypi_openwebui_info
if timeout 20 python3 -c "import urllib.request;urllib.request.urlopen('https://pypi.org/pypi/open-webui/json',timeout=15)" >/dev/null 2>&1; then
  info="$(pypi_openwebui_info latest)"
  assert_ne "returns a latest version"   "" "$(printf '%s' "$info" | cut -f1)"
  assert_contains "reports Requires-Python" "3.1" "$(printf '%s' "$info" | cut -f3)"
  info="$(pypi_openwebui_info 99.99.99)"
  assert_eq "unknown version resolves to empty target" "" "$(printf '%s' "$info" | cut -f2)"
else
  skip "pypi_openwebui_info live query" "PyPI unreachable"
  skip "pypi_openwebui_info unknown version" "PyPI unreachable"
fi

describe cmd_set_webui_version
reset_repo
mkdir -p "${OPENWEBUI_DIR}/venv/bin"
ln -sf "$(command -v python3)" "${OPENWEBUI_DIR}/venv/bin/python"
assert_fail "rejects a nonexistent release" cmd_set_webui_version 99.99.99
out="$(cmd_set_webui_version 2>&1)"
assert_contains "no-arg shows the pinned version" "0.6.5" "$out"

# ── apply / install ───────────────────────────────────────────────────────────
describe openwebui_install
reset_repo
mkdir -p "${OPENWEBUI_DIR}/venv/bin"
cat > "${OPENWEBUI_DIR}/venv/bin/pip" <<PIPEOF
#!/usr/bin/env bash
echo "pip \$*" >> "${WORK}/pip.log"
if [[ "\$1" == "list" ]]; then
  printf 'torch==2.13.0\nnvidia-cublas==1.0\ntriton==3.7.1\nopen-webui==0.6.5\n'
fi
[[ -f "${WORK}/PIPFAIL" && "\$*" == *pytorch* ]] && exit 1
exit 0
PIPEOF
chmod +x "${OPENWEBUI_DIR}/venv/bin/pip"
: > "${WORK}/pip.log"
env_set TORCH_CPU_ONLY "true"
openwebui_install >/dev/null 2>&1
assert_file_contains "installs CPU torch first" "download.pytorch.org" "${WORK}/pip.log"
assert_file_contains "purges orphaned CUDA wheels" "uninstall -y nvidia-cublas triton" "${WORK}/pip.log"
assert_file_contains "then installs requirements" "-r ${OPENWEBUI_REQ}" "${WORK}/pip.log"
: > "${WORK}/pip.log"; touch "${WORK}/PIPFAIL"
openwebui_install >/dev/null 2>&1
assert_eq "cpu failure does not uninstall anything" "0" "$(grep -c uninstall "${WORK}/pip.log" || true)"
assert_file_contains "still installs requirements" "-r ${OPENWEBUI_REQ}" "${WORK}/pip.log"
rm -f "${WORK}/PIPFAIL"
: > "${WORK}/pip.log"
env_set TORCH_CPU_ONLY "false"
openwebui_install >/dev/null 2>&1
assert_eq "cpu-only disabled skips the extra index" "0" "$(grep -c pytorch.org "${WORK}/pip.log" || true)"
env_set TORCH_CPU_ONLY "true"

describe cmd_apply
reset_repo
mock_command systemctl 1     # simulate "systemd not running here"
: > "${WORK}/pip.log"
out="$(cmd_apply 2>&1)"
assert_contains "runs apply-config"        "apply-config ran" "$out"
assert_contains "degrades without systemd" "systemd is not available" "$out"

# ── git / gitea ───────────────────────────────────────────────────────────────
describe git_push_authenticated
reset_repo
# Real git exits 128 for `remote get-url origin` when no such remote exists;
# a stub that exits 0 with empty output would let a bug slip through.
mock_command git 128
assert_fail "fails when there is no origin remote" git_push_authenticated
mock_command git 0
assert_fail "fails when the remote resolves empty" git_push_authenticated
mock_script git <<'EOF'
case "$*" in
  *"remote get-url"*) echo "http://git.example.net/o/r.git";;
  *"symbolic-ref"*)   echo "main";;
  *push*)             exit 0;;
esac
exit 0
EOF
env_set GITEA_DEPLOY_TOKEN ""
out="$(git_push_authenticated 2>&1)"; rc=$?
assert_contains "explains that Gitea needs a token" "token" "$out"
assert_ne "returns non-zero without a token" "0" "$rc"
env_set GITEA_DEPLOY_TOKEN "SECRET123"
mock_reset_log
git_push_authenticated >/dev/null 2>&1
assert_contains "uses a credential helper" "credential.helper" "$(mock_calls)"
assert_contains "pushes the current branch" "push origin HEAD:main" "$(mock_calls)"
assert_not_contains "token never appears on the command line" "SECRET123" "$(mock_calls)"

describe cmd_commit
reset_repo
mock_command git 0
out="$(cmd_commit "msg" 2>&1)"
assert_contains "no-git config dir is a no-op" "not a git repository" "$out"

describe cmd_set_token
reset_repo
mock_command curl 0 '{"login":"tester"}'
cmd_set_token "TOKENVALUE" >/dev/null 2>&1
assert_eq "stores the token" "TOKENVALUE" "$(env_get GITEA_DEPLOY_TOKEN)"
assert_fail "rejects an empty token" cmd_set_token ""

# ── host/container detection ──────────────────────────────────────────────────
describe running_ct_ids
mock_command pct 0 'VMID       Status     Lock         Name
101        running                 gitea
105        running                 router
110        stopped                 old'
assert_eq "lists only running ids" "101 105" "$(running_ct_ids | tr '\n' ' ' | sed 's/ $//')"

describe ct_name_of
mock_command pct 0 'hostname: ollama-smart-router
cores: 2'
assert_eq "reads the hostname" "ollama-smart-router" "$(ct_name_of 105)"

describe find_router_ct
mock_script pct <<'EOF'
case "$1" in
  list) echo "VMID       Status     Lock         Name"; echo "101        running                 a"; echo "105        running                 b";;
  exec) [ "$2" = "105" ] && exit 0 || exit 1;;
esac
exit 0
EOF
assert_eq "finds the container holding the config" "105" "$(find_router_ct)"
CT_ID=42
assert_eq "an explicit CT_ID short-circuits" "42" "$(find_router_ct)"
unset CT_ID

describe in_container_command
mock_script pct <<'EOF'
case "$*" in
  *"/usr/local/bin/manage-model-servers"*) exit 0;;
  *) exit 1;;
esac
EOF
assert_eq "prefers the installed symlink" "/usr/local/bin/manage-model-servers" "$(in_container_command 105)"
mock_command pct 1
assert_eq "none available -> empty" "" "$(in_container_command 105)"

describe ensure_config_or_forward
reset_repo
assert_ok "returns immediately when the config is local" ensure_config_or_forward

summary
