#!/usr/bin/env bash
# Fixture variables are consumed by dynamically extracted helpers.
# shellcheck disable=SC2034
# Unit tests for the functions in manage-model-servers.sh
#
# Each test gets a throwaway config repo, so nothing touches a real deployment.

# Never read the caller's stdin: a prompt under test that is not fed input
# explicitly would otherwise block forever when run from a pipe or CI runner.
exec </dev/null

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-${HERE}/../install/manage-model-servers.sh}"
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
# Exported so `bash -c "source $FUNCS; ..."` subshells see it too.
export SECRETS_FILE="${WORK}/router/secrets.env"
LITELLM_DIR="${WORK}/litellm"
UNIT_DIR="${WORK}/units"
APPLY_BACKUP_DIR="${WORK}/backups"
APPLY_BACKUP_KEEP=2
HEALTH_TIMEOUT=4
OPENWEBUI_HEALTH_TIMEOUT=4
LITELLM_HEALTH_URL="http://127.0.0.1:65998/health/liveliness"
APPLY_ALL=false
LITELLM_REQ="${REPO_DIR}/services/litellm-proxy/requirements.txt"
LITELLM_LOCK="${REPO_DIR}/services/litellm-proxy/requirements.lock"
OLLAMA_PORT=11434
LMSTUDIO_PORT=1234
SERVER_TYPE=auto
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

# A fake venv interpreter that runs the real python3. Deliberately a wrapper
# SCRIPT, never a symlink: a later `printf > .../venv/bin/python` in another
# test would write THROUGH a symlink and overwrite the system interpreter.
use_real_python() {
  rm -f "$1"
  printf '#!/bin/sh\nexec python3 "$@"\n' > "$1"
  chmod +x "$1"
}

reset_repo() {
  rm -rf "$REPO_DIR"
  rm -f "$SECRETS_FILE"
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
assert_ok   "lmstudio://host"        valid_addr lmstudio://10.0.0.9
assert_ok   "lmstudio+http url"      valid_addr lmstudio+http://h:1234
assert_fail "lmstudio:// bad port"   valid_addr lmstudio://h:0
assert_ok   "strata://host"          valid_addr strata://10.0.0.8
assert_ok   "strata+http url"        valid_addr strata+http://h:8080
assert_ok   "basalt://host"          valid_addr basalt://10.0.0.8
assert_ok   "basalt+http url"        valid_addr basalt+http://h:8080
assert_ok   "maya://host"            valid_addr maya://10.0.0.9
assert_ok   "maya+http url"          valid_addr maya+http://h:8080
assert_ok   "xolotl://host"          valid_addr xolotl://10.0.0.12
assert_ok   "xolotl+http url"        valid_addr xolotl+http://h:8080

describe server_kind
assert_eq "ollama"   "ollama"   "$(server_kind http://h:11434)"
assert_eq "lmstudio" "lmstudio" "$(server_kind lmstudio+http://h:1234)"
assert_eq "strata"   "strata"   "$(server_kind strata+http://h:8080)"
assert_eq "basalt"   "basalt"   "$(server_kind basalt+http://h:8080)"
assert_eq "maya"     "maya"     "$(server_kind maya+http://h:8080)"
assert_eq "xolotl"   "xolotl"   "$(server_kind xolotl+http://h:8080)"

describe server_base
assert_eq "strips the prefix" "http://h:1234" "$(server_base lmstudio+http://h:1234)"
assert_eq "ollama unchanged"  "http://h:11434" "$(server_base http://h:11434)"
assert_eq "strata prefix"     "http://h:8080"  "$(server_base strata+http://h:8080)"
assert_eq "basalt prefix"     "http://h:8080"  "$(server_base basalt+http://h:8080)"
assert_eq "maya prefix"       "http://h:8080"  "$(server_base maya+http://h:8080)"
assert_eq "xolotl prefix"     "http://h:8080"  "$(server_base xolotl+http://h:8080)"

describe litellm_provider
assert_eq "ollama"   "ollama"    "$(litellm_provider http://h:11434)"
assert_eq "lmstudio" "lm_studio" "$(litellm_provider lmstudio+http://h:1234)"
assert_eq "strata uses OpenAI" "openai" "$(litellm_provider strata+http://h:8080)"
assert_eq "basalt uses OpenAI" "openai" "$(litellm_provider basalt+http://h:8080)"
assert_eq "maya uses OpenAI"   "openai" "$(litellm_provider maya+http://h:8080)"
assert_eq "xolotl uses OpenAI" "openai" "$(litellm_provider xolotl+http://h:8080)"

describe litellm_api_base
assert_eq "ollama base as-is"      "http://h:11434"   "$(litellm_api_base http://h:11434)"
assert_eq "lmstudio OpenAI base"   "http://h:1234/v1" "$(litellm_api_base lmstudio+http://h:1234)"
assert_eq "strata OpenAI base"     "http://h:8080/v1" "$(litellm_api_base strata+http://h:8080)"
assert_eq "basalt OpenAI base"     "http://h:8080/v1" "$(litellm_api_base basalt+http://h:8080)"
assert_eq "maya OpenAI base"       "http://h:8080/v1" "$(litellm_api_base maya+http://h:8080)"
assert_eq "xolotl OpenAI base"     "http://h:8080/v1" "$(litellm_api_base xolotl+http://h:8080)"

describe normalize_addr
assert_eq "adds scheme+port"   "http://10.0.0.5:11434" "$(normalize_addr 10.0.0.5)"
assert_eq "keeps explicit port" "http://10.0.0.5:9999" "$(normalize_addr 10.0.0.5:9999)"
assert_eq "strips trailing /"   "http://h:1"           "$(normalize_addr http://h:1/)"
assert_eq "matches the installer normalisation" \
  "http://ollama1.lan:11434" "$(normalize_addr ollama1.lan)"

assert_eq "lmstudio:// gets LM Studio's port" "lmstudio+http://10.0.0.9:1234" "$(normalize_addr lmstudio://10.0.0.9)"
assert_eq "lmstudio+http passes through"      "lmstudio+http://h:4321" "$(normalize_addr lmstudio+http://h:4321/)"
assert_eq "a forced kind applies"             "lmstudio+http://h:1234" "$(normalize_addr h lmstudio)"
assert_eq "strata:// default port"            "strata+http://h:8080" "$(normalize_addr strata://h)"
assert_eq "strata:// keeps port 11434"       "strata+http://h:11434" "$(normalize_addr strata://h:11434)"
assert_eq "strata+http passes through"        "strata+http://h:8888" "$(normalize_addr strata+http://h:8888/)"
assert_eq "basalt:// default port"            "basalt+http://h:8080" "$(normalize_addr basalt://h)"
assert_eq "basalt+http passes through"        "basalt+http://h:8888" "$(normalize_addr basalt+http://h:8888/)"
assert_eq "maya:// default port"              "maya+http://h:8080"   "$(normalize_addr maya://h)"
assert_eq "maya+http passes through"          "maya+http://h:8888"   "$(normalize_addr maya+http://h:8888/)"
assert_eq "xolotl:// default port"            "xolotl+http://h:8080" "$(normalize_addr xolotl://h)"
assert_eq "xolotl+http passes through"        "xolotl+http://h:8150" "$(normalize_addr xolotl+http://h:8150/)"
STRATA_PORT=11434
assert_eq "Strata default port can be 11434" "strata+http://h:11434" "$(normalize_addr strata://h)"
unset STRATA_PORT
SERVER_TYPE=lmstudio
assert_eq "--type lmstudio applies"           "lmstudio+http://h:5555" "$(normalize_addr h:5555)"
SERVER_TYPE=auto

describe valid_keep_alive
assert_ok   "blank"    valid_keep_alive ""
assert_ok   "-1"       valid_keep_alive -1
assert_ok   "2h"       valid_keep_alive 2h
assert_fail "junk"     valid_keep_alive abc

# ── env file access ───────────────────────────────────────────────────────────
describe env_get
reset_repo
assert_eq "reads a plain value"    "tester" "$(env_get GITEA_ADMIN_USER)"
assert_eq "reads a comma list"     "http://10.0.0.51:11434,http://10.0.0.52:11434,http://10.0.0.53:11434,http://10.0.0.54:11434" "$(env_get MODEL_SERVERS)"
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
env_set GITEA_DEPLOY_TOKEN "S3CRET"
assert_eq "a secret reads back"                "S3CRET" "$(env_get GITEA_DEPLOY_TOKEN)"
assert_fail "a secret never lands in the repo env file" grep -q S3CRET "$ENV_FILE"
assert_file_contains "it lands in the secrets file" "GITEA_DEPLOY_TOKEN=S3CRET" "$SECRETS_FILE"
reset_repo
kv_set "$ENV_FILE" GITEA_DEPLOY_TOKEN "LEGACY"
assert_eq "unmigrated secrets still resolve" "LEGACY" "$(env_get GITEA_DEPLOY_TOKEN)"
reset_repo

# ── secrets ───────────────────────────────────────────────────────────────────
describe secret_keys
assert_contains "the deploy token is secret" "GITEA_DEPLOY_TOKEN"     "$(secret_keys)"
assert_contains "the webhook is secret"      "MATTERMOST_WEBHOOK_URL" "$(secret_keys)"

describe is_secret_key
assert_ok   "token"            is_secret_key GITEA_DEPLOY_TOKEN
assert_fail "ordinary key"     is_secret_key MODEL_SERVERS
assert_fail "no prefix match"  is_secret_key GITEA_DEPLOY_TOKEN_OLD

describe kv_has
kvf="${WORK}/kv.env"; printf 'A=1\nEMPTY=\n' > "$kvf"
assert_ok   "present"                kv_has "$kvf" A
assert_ok   "present but empty"      kv_has "$kvf" EMPTY
assert_fail "absent"                 kv_has "$kvf" B
assert_fail "missing file"           kv_has "${WORK}/nope.env" A

describe kv_get
assert_eq "reads a value"            "1" "$(kv_get "$kvf" A)"
assert_eq "missing file is empty"    ""  "$(kv_get "${WORK}/nope.env" A)"

describe kv_set
kv_set "$kvf" A 'back\slash\n'
assert_eq "keeps backslashes literally" 'back\slash\n' "$(kv_get "$kvf" A)"
kv_set "$kvf" NEW v
assert_eq "appends a new key"        "v" "$(kv_get "$kvf" NEW)"
kv_set "${WORK}/fresh.env" K v
assert_eq "creates a missing file"   "v" "$(kv_get "${WORK}/fresh.env" K)"
rm -f "${WORK}/fresh.env"

describe kv_del
kv_del "$kvf" A
assert_fail "removes the key"        kv_has "$kvf" A
assert_ok   "keeps the others"       kv_has "$kvf" NEW
assert_ok   "absent key is a no-op"  kv_del "$kvf" A
rm -f "$kvf"

describe ensure_secrets_file
rm -f "$SECRETS_FILE"
ensure_secrets_file
assert_ok        "creates the file" test -f "$SECRETS_FILE"
assert_file_mode "group-readable only" "640" "$SECRETS_FILE"

describe migrate_secrets
reset_repo
kv_set "$ENV_FILE" GITEA_DEPLOY_TOKEN "LEAKED"
kv_set "$ENV_FILE" MATTERMOST_WEBHOOK_URL "https://mm.example.net/hooks/xyz"
out="$(migrate_secrets 2>&1)"
assert_contains "reports the move"            "Moved 2 secret" "$out"
assert_contains "says to rotate"              "rotate" "$out"
assert_fail "token gone from the repo file"   kv_has "$ENV_FILE" GITEA_DEPLOY_TOKEN
assert_fail "webhook gone from the repo file" kv_has "$ENV_FILE" MATTERMOST_WEBHOOK_URL
assert_eq "token kept in the secrets file"    "LEAKED" "$(kv_get "$SECRETS_FILE" GITEA_DEPLOY_TOKEN)"
assert_eq "env_get still resolves it"         "LEAKED" "$(env_get GITEA_DEPLOY_TOKEN)"
kv_set "$SECRETS_FILE" GITEA_DEPLOY_TOKEN "NEWER"
kv_set "$ENV_FILE" GITEA_DEPLOY_TOKEN "STALE"
migrate_secrets >/dev/null 2>&1
assert_eq "an existing secret is not clobbered" "NEWER" "$(kv_get "$SECRETS_FILE" GITEA_DEPLOY_TOKEN)"
assert_eq "nothing to move is silent" "" "$(migrate_secrets 2>&1)"
reset_repo

describe tier_env_key
assert_eq "fast"   "BACKEND_FAST"   "$(tier_env_key fast)"
assert_eq "medium" "BACKEND_MEDIUM" "$(tier_env_key medium)"
assert_eq "large"  "BACKEND_LARGE"  "$(tier_env_key large)"
assert_eq "xlarge" "BACKEND_XLARGE" "$(tier_env_key xlarge)"
assert_fail "rejects an unknown tier" bash -c "source '$FUNCS'; tier_env_key turbo"
assert_not_contains "no longer Qwen-specific" "QWEN" "$(tier_env_key fast)"

describe tier_model_name
reset_repo
assert_eq "reads from router.ini" "fast" "$(tier_model_name fast)"
printf '[tiers]\nfast = custom-fast\n' > "$ROUTER_INI"
assert_eq "honours a custom alias" "custom-fast" "$(tier_model_name fast)"
rm -f "$ROUTER_INI"
assert_eq "falls back when ini is missing" "large" "$(tier_model_name large)"
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
assert_eq "all servers"      "4" "$(get_servers | grep -c .)"
env_set MODEL_SERVERS ""
assert_eq "no servers configured yields nothing" "0" "$(get_servers | grep -c . || true)"
reset_repo

describe get_tier
assert_eq "fast tier"        "1" "$(get_tier fast | grep -c .)"
assert_eq "large tier (two)" "2" "$(get_tier large | grep -c .)"
assert_fail "an unknown tier is rejected" get_tier turbo

describe contains_line
assert_ok   "finds an exact match"     bash -c "source '$FUNCS'; printf 'a\nb\n' | contains_line b"
assert_fail "rejects a partial match"  bash -c "source '$FUNCS'; printf 'abc\n' | contains_line b"
assert_ok   "matches a final line without newline" \
  bash -c "source '$FUNCS'; printf 'a\nb' | contains_line b"

describe tiers_of
reset_repo
assert_eq "server in one tier"   "fast"        "$(tiers_of http://10.0.0.51:11434)"
assert_eq "server in two tiers"  "medium,large" "$(tiers_of http://10.0.0.52:11434)"
assert_eq "unassigned server"    "—"           "$(tiers_of http://10.0.0.99:11434)"

# ── yaml reading ──────────────────────────────────────────────────────────────
describe current_pair_tag
reset_repo
assert_eq "reads the tag for a specific host" \
  "qwen3:32b" "$(current_pair_tag large http://10.0.0.52:11434)"
assert_eq "a different host in the same tier has its own tag" \
  "mixtral:8x7b" "$(current_pair_tag large http://10.0.0.53:11434)"
assert_eq "unknown pair is empty" "" "$(current_pair_tag large http://10.0.0.99:11434)"

describe current_tier_tag
assert_eq "first tag for the tier" "qwen3:32b" "$(current_tier_tag large)"
assert_eq "fast tier"              "qwen2.5-coder:7b" "$(current_tier_tag fast)"
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

# LM Studio: native v1 list (embedding models are not chat models).
mock_script curl <<'EOF'
case "$*" in
  *"/api/v1/models"*) echo '{"models":[{"type":"llm","key":"qwen/qwen3-8b"},{"type":"embedding","key":"nomic"}]}';;
  *) exit 22;;
esac
EOF
assert_eq "LM Studio v1 list, no embeddings" "qwen/qwen3-8b" "$(server_models lmstudio+http://h:1234)"
mock_script curl <<'EOF'
case "$*" in
  *"/api/v0/models"*) echo '{"data":[{"id":"llama-3.1-8b","type":"llm"},{"id":"e","type":"embeddings"}]}';;
  *) exit 22;;
esac
EOF
assert_eq "falls back to v0" "llama-3.1-8b" "$(server_models lmstudio+http://h:1234)"
mock_script curl <<'EOF'
case "$*" in
  *"/v1/models"*) [[ "$*" == *"/api/"* ]] && exit 22; echo '{"data":[{"id":"plain"}]}';;
  *) exit 22;;
esac
EOF
assert_eq "then to /v1/models" "plain" "$(server_models lmstudio+http://h:1234)"
assert_eq "Strata reads /v1/models" "plain" "$(server_models strata+http://h:8080)"
assert_eq "Basalt reads /v1/models" "plain" "$(server_models basalt+http://h:8080)"
assert_eq "Maya reads /v1/models" "plain" "$(server_models maya+http://h:8080)"
mock_command curl 7
assert_status "unreachable LM Studio -> 1" 1 server_models lmstudio+http://h:1234

describe server_curl
reset_repo
mock_reset_log; mock_command curl 0 '{}'
server_curl lmstudio+http://h:1234 /v1/models >/dev/null
assert_contains "strips the prefix from the URL" "http://h:1234/v1/models" "$(mock_calls)"
assert_not_contains "no token -> no header" "-H" "$(mock_calls)"
env_set LMSTUDIO_API_TOKEN "lms-tok-123"
mock_reset_log
server_curl lmstudio+http://h:1234 /v1/models >/dev/null
assert_contains "token via a header file" "-H @" "$(mock_calls)"
assert_not_contains "never on the command line" "lms-tok-123" "$(mock_calls)"
env_set STRATA_API_KEY "strata-tok-123"
mock_reset_log
server_curl strata+http://h:8080 /v1/models >/dev/null
assert_contains "Strata uses its own key" "http://h:8080/v1/models" "$(mock_calls)"
assert_contains "Strata key in header file" "-H @" "$(mock_calls)"
assert_not_contains "Strata key absent from argv" "strata-tok-123" "$(mock_calls)"
env_set BASALT_API_KEY "basalt-tok-123"
mock_reset_log
server_curl basalt+http://h:8080 /v1/models >/dev/null
assert_contains "Basalt uses its own key" "http://h:8080/v1/models" "$(mock_calls)"
assert_contains "Basalt key in header file" "-H @" "$(mock_calls)"
assert_not_contains "Basalt key absent from argv" "basalt-tok-123" "$(mock_calls)"
env_set MAYA_API_KEY "maya-tok-123"
mock_reset_log
server_curl maya+http://h:8080 /v1/models >/dev/null
assert_contains "Maya uses its own key" "http://h:8080/v1/models" "$(mock_calls)"
assert_contains "Maya key in header file" "-H @" "$(mock_calls)"
assert_not_contains "Maya key absent from argv" "maya-tok-123" "$(mock_calls)"
env_set XOLOTL_API_KEY "xolotl-tok-123"
env_set STRATA_API_KEY "strata-tok-456"
mock_reset_log
server_curl xolotl+http://h:8080 /v1/models >/dev/null
assert_contains "Xolotl uses its own key" "http://h:8080/v1/models" "$(mock_calls)"
assert_not_contains "Xolotl key absent from argv" "xolotl-tok-123" "$(mock_calls)"
assert_eq "Xolotl's key is the one sent" "XOLOTL_API_KEY" "$(kind_field "$(server_kind xolotl+http://h:8080)" key)"
mock_reset_log
server_curl http://h:11434 /api/tags >/dev/null
assert_not_contains "never sent to Ollama" "-H" "$(mock_calls)"
reset_repo

describe detect_server_kind
mock_script curl <<'EOF'
case "$*" in *"/api/tags"*) echo '{"models":[]}';; *) exit 7;; esac
EOF
assert_eq "Ollama answers /api/tags" "ollama" "$(detect_server_kind http://h:11434)"
mock_script curl <<'EOF'
case "$*" in *"/api/tags"*) exit 22;; *"/api/v1/models"*) printf 200;; *) printf 404;; esac
EOF
assert_eq "LM Studio answers /api/v1/models" "lmstudio" "$(detect_server_kind http://h:1234)"
mock_script curl <<'EOF'
case "$*" in *"/api/tags"*) exit 22;; *"/api/v1/models"*) printf 401;; *) printf 404;; esac
EOF
assert_eq "a 401 still identifies LM Studio" "lmstudio" "$(detect_server_kind http://h:1234)"
mock_script curl <<'EOF'
case "$*" in
  *"/api/tags"*) exit 22;;
  *"/health"*) printf '{"status":"ok","loaded":true,"service":"strata","api_key":true}';;
  *"/v1/models"*) exit 22;;
  *) printf 401;;
esac
EOF
mock_reset_log
assert_eq "a keyed Strata on 11434 identifies through public /health" "strata" "$(detect_server_kind http://h:11434)"
assert_not_contains "health identification sends no key" "-H @" "$(mock_calls)"
mock_script curl <<'EOF'
case "$*" in
  *"/api/tags"*) exit 22;;
  *"/health"*) printf '{"status":"ok","service":"basalt","loaded":true}';;
  *) exit 22;;
esac
EOF
mock_reset_log
assert_eq "keyed Basalt identified from public health" "basalt" "$(detect_server_kind http://h:11434)"
assert_not_contains "Basalt detection sends no key" "-H @" "$(mock_calls)"
mock_script curl <<'EOF'
case "$*" in
  *"/api/tags"*) exit 22;;
  *"/health"*) printf '{"status":"ok","model":"glm-5.3-flash","version":"1.1.13"}';;
  *) exit 22;;
esac
EOF
mock_reset_log
assert_eq "keyed Maya identified from public health" "maya" "$(detect_server_kind http://h:8080)"
assert_not_contains "Maya detection sends no key" "-H @" "$(mock_calls)"
mock_script curl <<'EOF'
case "$*" in
  *"/api/tags"*) exit 22;;
  *"/health"*) printf '{"status":"ok","max_context":131072,"model":"deepseek-v4.1-flash","api_key":true,"loaded":true,"service":"strata"}';;
  *) exit 22;;
esac
EOF
mock_reset_log
assert_eq "keyed Xolotl (Strata's server, a DeepSeek-V4 model) identified from public health" "xolotl" "$(detect_server_kind http://h:8080)"
assert_not_contains "Xolotl detection sends no key" "-H @" "$(mock_calls)"
mock_script curl <<'EOF'
case "$*" in
  *"/api/tags"*) exit 22;;
  *"/health"*) printf '{"status":"ok","model":"qwen3.8-flash-next","loaded":true,"service":"strata"}';;
  *) exit 22;;
esac
EOF
assert_eq "Strata with a Qwen model stays Strata" "strata" "$(detect_server_kind http://h:8080)"
mock_script curl <<'EOF'
case "$*" in
  *"/v1/status"*) printf '{"loaded":true,"auto_load":true}\n200';;
  *"/api/v1/models"*|*"/api/v0/models"*) printf 404;;
  *) exit 22;;
esac
EOF
assert_eq "Strata answers /v1/status" "strata" "$(detect_server_kind http://h:8080)"
mock_script curl <<'EOF'
case "$*" in
  *"/v1/status"*) printf 'not found\n404';;
  *"/v1/models"*) echo '{"object":"list","data":[{"id":"strata","object":"model"}]}';;
  *) exit 22;;
esac
EOF
assert_eq "Strata's model id identifies it" "strata" "$(detect_server_kind http://h:8080)"
# A keyed older Strata without a distinguishing public /health response still
# cannot be identified safely, so such a host has to be named.
reset_repo
env_set STRATA_API_KEY "strata-tok-123"
mock_script curl <<'EOF'
case "$*" in
  *"/api/tags"*) exit 22;;
  *"/v1/status"*) printf 'unauthorized\n401';;
  *"/api/v1/models"*|*"/api/v0/models"*) printf 401;;
  *) exit 22;;
esac
EOF
mock_reset_log
assert_status "keyed host off LM Studio's port is not guessed" 1 detect_server_kind http://h:11434
assert_not_contains "detection never sends a key" "-H @" "$(mock_calls)"
out="$(detect_server_kind http://h:11434 2>&1 >/dev/null || true)"
assert_contains "says how to add it" "strata://h:11434" "$out"
assert_status "a bare keyed address is not resolved" 1 resolve_server h:11434
assert_eq "an explicit strata:// address needs no probe" "strata+http://h:11434" "$(resolve_server strata://h:11434)"
assert_eq "a keyed host on LM Studio's port is LM Studio" "lmstudio" "$(detect_server_kind http://h:1234)"
assert_not_contains "still no key sent" "-H @" "$(mock_calls)"
reset_repo
mock_command curl 7 "000"
assert_status "nothing answers -> 1" 1 detect_server_kind http://h:1

describe resolve_server
NO_PROBE=false
mock_script curl <<'EOF'
case "$*" in
  *":11434/api/tags"*) exit 7;;
  *":1234/api/v1/models"*) printf 200;;
  *) printf 000; exit 7;;
esac
EOF
assert_eq "a bare host found on LM Studio's port" "lmstudio+http://10.0.0.9:1234" "$(resolve_server 10.0.0.9)"
assert_eq "host:port detected as LM Studio"       "lmstudio+http://10.0.0.9:1234" "$(resolve_server 10.0.0.9:1234)"
mock_script curl <<'EOF'
case "$*" in
  *"/v1/status"*) printf '{"loaded":true,"auto_load":true}\n200';;
  *"/api/v1/models"*|*"/api/v0/models"*) printf 404;;
  *) exit 22;;
esac
EOF
assert_eq "Strata at Ollama's port auto-detected" "strata+http://10.0.0.9:11434" "$(resolve_server 10.0.0.9:11434)"
assert_eq "bare Strata host at Ollama's port detected" "strata+http://10.0.0.9:11434" "$(resolve_server 10.0.0.9)"
mock_script curl <<'EOF'
case "$*" in
  *":8080/health"*) printf '{"status":"ok","service":"basalt"}';;
  *) exit 22;;
esac
EOF
assert_eq "bare Basalt host on default port detected" "basalt+http://10.0.0.9:8080" "$(resolve_server 10.0.0.9)"
mock_script curl <<'EOF'
case "$*" in
  *":8080/health"*) printf '{"status":"ok","model":"glm-5.3-flash","version":"1.1.13"}';;
  *) exit 22;;
esac
EOF
assert_eq "bare Maya host on default port detected" "maya+http://10.0.0.9:8080" "$(resolve_server 10.0.0.9)"
mock_script curl <<'EOF'
case "$*" in
  *":8080/health"*) printf '{"status":"ok","model":"deepseek-v4.1-flash","loaded":false,"service":"strata"}';;
  *) exit 22;;
esac
EOF
assert_eq "bare Xolotl host on default port detected" "xolotl+http://10.0.0.12:8080" "$(resolve_server 10.0.0.12)"
BASALT_PORT=8181
mock_script curl <<'EOF'
case "$*" in
  *":8181/health"*) printf '{"status":"ok","service":"basalt"}';;
  *) exit 22;;
esac
EOF
assert_eq "bare Basalt host on configured port detected" "basalt+http://10.0.0.9:8181" "$(resolve_server 10.0.0.9)"
unset BASALT_PORT
mock_command curl 7 "000"
assert_status "nothing answers -> 1" 1 resolve_server 10.0.0.9
NO_PROBE=true
assert_eq "--no-probe assumes Ollama"             "http://10.0.0.9:11434" "$(resolve_server 10.0.0.9)"
assert_eq "an explicit lmstudio:// needs no probe" "lmstudio+http://10.0.0.9:1234" "$(resolve_server lmstudio://10.0.0.9)"
assert_eq "explicit Strata on port 11434 needs no probe" "strata+http://10.0.0.9:11434" "$(resolve_server strata://10.0.0.9:11434)"
assert_eq "explicit Basalt on port 11434 needs no probe" "basalt+http://10.0.0.9:11434" "$(resolve_server basalt://10.0.0.9:11434)"
assert_eq "explicit Maya on port 11434 needs no probe" "maya+http://10.0.0.9:11434" "$(resolve_server maya://10.0.0.9:11434)"
assert_eq "explicit Xolotl on port 8150 needs no probe" "xolotl+http://10.0.0.12:8150" "$(resolve_server xolotl://10.0.0.12:8150)"
SERVER_TYPE=lmstudio
assert_eq "--type lmstudio needs no probe"        "lmstudio+http://10.0.0.9:1234" "$(resolve_server 10.0.0.9)"
SERVER_TYPE=strata
assert_eq "--type strata needs no probe"          "strata+http://10.0.0.9:8080" "$(resolve_server 10.0.0.9)"
SERVER_TYPE=basalt
assert_eq "--type basalt needs no probe"          "basalt+http://10.0.0.9:8080" "$(resolve_server 10.0.0.9)"
SERVER_TYPE=auto

describe configured_entry
reset_repo
env_set MODEL_SERVERS "http://10.0.0.51:11434,lmstudio+http://10.0.0.9:1234,strata+http://10.0.0.8:8080,basalt+http://10.0.0.7:8080"
assert_eq "finds the LM Studio entry without the prefix" "lmstudio+http://10.0.0.9:1234" "$(configured_entry 10.0.0.9:1234)"
assert_eq "finds the Strata entry without the prefix"    "strata+http://10.0.0.8:8080"  "$(configured_entry 10.0.0.8:8080)"
assert_eq "finds the Basalt entry without the prefix"    "basalt+http://10.0.0.7:8080"  "$(configured_entry 10.0.0.7:8080)"
assert_eq "finds an Ollama entry"                         "http://10.0.0.51:11434"       "$(configured_entry 10.0.0.51)"
assert_eq "unknown -> normalized form"                    "http://10.0.0.99:11434"       "$(configured_entry 10.0.0.99)"
reset_repo

describe model_present_on
mock_command curl 0 '{"models":[{"name":"qwen3:32b"},{"name":"phi4:latest"}]}'
assert_status "exact match -> 0"            0 model_present_on http://h qwen3:32b
assert_status "absent -> 1"                 1 model_present_on http://h nope:1b
assert_status "bare name matches :latest"   0 model_present_on http://h phi4
mock_script curl <<'EOF'
case "$*" in *"/api/v1/models"*) echo '{"models":[{"type":"llm","key":"phi4:latest"}]}';; *) exit 22;; esac
EOF
assert_status "no :latest aliasing on LM Studio" 1 model_present_on lmstudio+http://h:1234 phi4
mock_command curl 0 '{"models":[{"name":"smtek/Qwen3.8-27B:Q3_K_XL-16gb"},{"name":"smtek/Qwen3.8-27B:latest"}]}'
assert_status "namespaced extended tag matches exactly" 0 model_present_on http://h smtek/Qwen3.8-27B:Q3_K_XL-16gb
assert_status "namespaced bare name matches :latest"    0 model_present_on http://h smtek/Qwen3.8-27B
assert_status "namespace is required for a match"       1 model_present_on http://h Qwen3.8-27B:Q3_K_XL-16gb
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
assert_eq "one deployment per (tier,server) pair" "5" "$(grep -c 'model_name:' "$LITELLM_YAML")"
TIER_MODEL_OVERRIDE[large]="new:1b"
regenerate_litellm >/dev/null 2>&1
assert_eq "tier override applies to every host in the tier" \
  "2" "$(grep -c 'ollama/new:1b' "$LITELLM_YAML")"
reset_repo
PAIR_MODEL_OVERRIDE["large|http://10.0.0.53:11434"]="solo:7b"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "per-pair override applied"      "ollama/solo:7b"     "$LITELLM_YAML"
assert_file_contains "the other host is untouched"    "ollama/qwen3:32b"   "$LITELLM_YAML"
reset_repo
env_set OLLAMA_KEEP_ALIVE "2h"
regenerate_litellm >/dev/null 2>&1
assert_eq "keep_alive emitted per deployment" "5" "$(grep -c 'keep_alive: 2h' "$LITELLM_YAML")"
env_set OLLAMA_KEEP_ALIVE ""
regenerate_litellm >/dev/null 2>&1
assert_eq "blank keep_alive emits nothing" "0" "$(grep -c 'keep_alive' "$LITELLM_YAML" || true)"
reset_repo
# router_settings: hand-edited keys survive, fallbacks are rebuilt, and a
# section after router_settings is left alone.
cat >> "$LITELLM_YAML" <<'EOF'
  num_retries: 2
litellm_settings:
  drop_params: true
EOF
sed -i 's/    - xlarge: \["large", "medium", "fast"\]/    - qwen-heavy: ["qwen-fast"]/' "$LITELLM_YAML"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "keeps other router_settings keys" "  num_retries: 2" "$LITELLM_YAML"
assert_file_contains "keeps later sections"             "litellm_settings:" "$LITELLM_YAML"
assert_fail "drops fallbacks to tiers that no longer exist" grep -q "qwen-heavy" "$LITELLM_YAML"
assert_file_contains "regenerates fallbacks for current tiers" '- fast: ["medium", "large", "xlarge"]' "$LITELLM_YAML"
assert_eq "exactly one fallbacks key" "1" "$(grep -c '^  fallbacks:' "$LITELLM_YAML")"
assert_ok "the result is valid for LiteLLM" validate_config
reset_repo

# An LM Studio server gets LiteLLM's lm_studio provider and its /v1 base.
env_set MODEL_SERVERS "http://10.0.0.51:11434,lmstudio+http://10.0.0.9:1234"
env_set BACKEND_FAST "lmstudio+http://10.0.0.9:1234"
env_set OLLAMA_KEEP_ALIVE "2h"
TIER_MODEL_OVERRIDE[fast]="qwen/qwen3-8b"
regenerate_litellm >/dev/null 2>&1
TIER_MODEL_OVERRIDE=()
assert_file_contains "lm_studio provider"  "model: lm_studio/qwen/qwen3-8b" "$LITELLM_YAML"
assert_file_contains "OpenAI /v1 base"     "api_base: http://10.0.0.9:1234/v1" "$LITELLM_YAML"
assert_eq "keep_alive only on Ollama deployments" "4" "$(grep -c 'keep_alive: 2h' "$LITELLM_YAML")"
assert_eq "reads back its own tag" "qwen/qwen3-8b" "$(current_pair_tag fast lmstudio+http://10.0.0.9:1234)"
assert_not_contains "no api_key without a token" "api_key" "$(cat "$LITELLM_YAML")"
env_set LMSTUDIO_API_TOKEN "tok"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "api_key from the environment" "api_key: os.environ/LMSTUDIO_API_TOKEN" "$LITELLM_YAML"
assert_fail "the token itself never enters the YAML" grep -q "tok$" "$LITELLM_YAML"
assert_ok "and the result validates" validate_config
reset_repo

env_set MODEL_SERVERS "strata+http://10.0.0.8:11434"
env_set BACKEND_XLARGE "strata+http://10.0.0.8:11434"
TIER_MODEL_OVERRIDE[xlarge]="strata"
regenerate_litellm >/dev/null 2>&1
TIER_MODEL_OVERRIDE=()
assert_file_contains "Strata OpenAI provider" "model: openai/strata" "$LITELLM_YAML"
assert_file_contains "Strata /v1 base on port 11434" "api_base: http://10.0.0.8:11434/v1" "$LITELLM_YAML"
assert_file_contains "Strata no-key placeholder" "api_key: none" "$LITELLM_YAML"
assert_eq "reads Strata pair tag" "strata" "$(current_pair_tag xlarge strata+http://10.0.0.8:11434)"
env_set STRATA_API_KEY "strata-key"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "Strata key reference" "api_key: os.environ/STRATA_API_KEY" "$LITELLM_YAML"
assert_fail "Strata key never enters YAML" grep -q 'strata-key' "$LITELLM_YAML"
reset_repo

env_set MODEL_SERVERS "basalt+http://10.0.0.7:8080"
env_set BACKEND_XLARGE "basalt+http://10.0.0.7:8080"
TIER_MODEL_OVERRIDE[xlarge]="qwen3.8-flash-next"
regenerate_litellm >/dev/null 2>&1
TIER_MODEL_OVERRIDE=()
assert_file_contains "Basalt OpenAI provider" "model: openai/qwen3.8-flash-next" "$LITELLM_YAML"
assert_file_contains "Basalt /v1 base" "api_base: http://10.0.0.7:8080/v1" "$LITELLM_YAML"
assert_file_contains "Basalt no-key placeholder" "api_key: none" "$LITELLM_YAML"
env_set BASALT_API_KEY "basalt-key"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "Basalt key reference" "api_key: os.environ/BASALT_API_KEY" "$LITELLM_YAML"
assert_fail "Basalt key never enters YAML" grep -q 'basalt-key' "$LITELLM_YAML"
reset_repo

env_set MODEL_SERVERS "maya+http://10.0.0.9:8080"
env_set BACKEND_XLARGE "maya+http://10.0.0.9:8080"
TIER_MODEL_OVERRIDE[xlarge]="glm-5.3-flash"
regenerate_litellm >/dev/null 2>&1
TIER_MODEL_OVERRIDE=()
assert_file_contains "Maya OpenAI provider" "model: openai/glm-5.3-flash" "$LITELLM_YAML"
assert_file_contains "Maya /v1 base" "api_base: http://10.0.0.9:8080/v1" "$LITELLM_YAML"
assert_file_contains "Maya no-key placeholder" "api_key: none" "$LITELLM_YAML"
env_set MAYA_API_KEY "maya-key"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "Maya key reference" "api_key: os.environ/MAYA_API_KEY" "$LITELLM_YAML"
assert_fail "Maya key never enters YAML" grep -q 'maya-key' "$LITELLM_YAML"
reset_repo

env_set MODEL_SERVERS "xolotl+http://10.0.0.12:8080"
env_set BACKEND_XLARGE "xolotl+http://10.0.0.12:8080"
TIER_MODEL_OVERRIDE[xlarge]="deepseek-v4.1-flash"
regenerate_litellm >/dev/null 2>&1
TIER_MODEL_OVERRIDE=()
assert_file_contains "Xolotl OpenAI provider" "model: openai/deepseek-v4.1-flash" "$LITELLM_YAML"
assert_file_contains "Xolotl /v1 base" "api_base: http://10.0.0.12:8080/v1" "$LITELLM_YAML"
env_set XOLOTL_API_KEY "xolotl-key"
env_set STRATA_API_KEY "strata-key"
regenerate_litellm >/dev/null 2>&1
assert_file_contains "Xolotl key reference" "api_key: os.environ/XOLOTL_API_KEY" "$LITELLM_YAML"
assert_fail "the Strata key is not used for Xolotl" grep -q 'STRATA_API_KEY' "$LITELLM_YAML"
assert_fail "Xolotl key never enters YAML" grep -q 'xolotl-key' "$LITELLM_YAML"
reset_repo

describe litellm_fallbacks
out="$(printf 'fast a@1\nmedium b@2\nlarge b@2\nxlarge c@3\n' | litellm_fallbacks)"
assert_contains "nearest tier first"             '- fast: ["medium", "large", "xlarge"]' "$out"
assert_contains "identical deployments skipped"  '- medium: ["fast", "xlarge"]' "$out"
assert_not_contains "never falls back to itself" '"medium", "medium"' "$out"
assert_eq "no tiers -> no block" "" "$(printf '' | litellm_fallbacks)"
assert_eq "one tier -> no block" "" "$(printf 'fast a@1\n' | litellm_fallbacks)"

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
assert_eq "server appended"     "5" "$(get_servers | grep -c .)"
assert_eq "not tiered by default" "—" "$(tiers_of http://10.0.0.60:11434)"
reset_repo
TIER_ARG="large"; cmd_add 10.0.0.60 >/dev/null 2>&1; TIER_ARG=""
assert_eq "--tier assigns it"   "large" "$(tiers_of http://10.0.0.60:11434)"
reset_repo
cmd_add 10.0.0.51 >/dev/null 2>&1
assert_eq "duplicate is skipped" "4" "$(get_servers | grep -c .)"
assert_fail "rejects an invalid address" bash -c "source '$FUNCS'; REPO_DIR='$REPO_DIR'; ENV_FILE='$ENV_FILE'; NO_PROBE=true; ASSUME_YES=true; cmd_add 'not valid'"
MODEL_SERVER_MAX=3
assert_fail "refuses to exceed the maximum" cmd_add 10.0.0.70
MODEL_SERVER_MAX=20
reset_repo; NO_PROBE=false
mock_script curl <<'EOF'
case "$*" in
  *":11434/"*) printf 000; exit 7;;
  *"-w"*) printf 200;;
  *"/api/v1/models"*) echo '{"models":[{"type":"llm","key":"qwen/qwen3-8b"}]}';;
  *) exit 7;;
esac
EOF
out="$(cmd_add 10.0.0.9 2>&1)"
assert_contains "an LM Studio server is detected" "LM Studio server" "$out"
assert_ok "and stored with its prefix" bash -c "grep -q 'lmstudio+http://10.0.0.9:1234' '$ENV_FILE'"
reset_repo
mock_script curl <<'EOF'
case "$*" in
  *"/api/tags"*) exit 22;;
  *"/v1/status"*) echo '{"loaded":true,"auto_load":true}';;
  *"/v1/models"*) echo '{"data":[{"id":"strata"}]}';;
  *) exit 22;;
esac
EOF
out="$(cmd_add 10.0.0.9:11434 2>&1)"
assert_contains "Strata on port 11434 is detected" "Strata server" "$out"
assert_ok "and stored with its prefix" bash -c "grep -q 'strata+http://10.0.0.9:11434' '$ENV_FILE'"
mock_command curl 7 "000"
assert_fail "an unreachable address is refused" cmd_add 10.0.0.77
NO_PROBE=true

describe cmd_remove
reset_repo
cmd_remove http://10.0.0.53:11434 >/dev/null 2>&1
assert_eq "server removed"        "3" "$(get_servers | grep -c .)"
assert_eq "tier membership cleaned" "1" "$(get_tier large | grep -c .)"
reset_repo
cmd_remove 1 >/dev/null 2>&1
assert_eq "removal by list number" "3" "$(get_servers | grep -c .)"
reset_repo
MODEL_SERVER_MIN=4
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
cmd_set_model large newmodel:1b >/dev/null 2>&1
assert_eq "applies to every host in the tier" "2" "$(grep -c 'ollama/newmodel:1b' "$LITELLM_YAML")"
assert_fail "rejects an ollama/ prefix" cmd_set_model large ollama/x
assert_fail "rejects an unknown tier"   cmd_set_model turbo x
reset_repo
NO_PROBE=false
namespaced_tag="smtek/Qwen3.8-27B:Q3_K_XL-16gb"
mock_command curl 0 '{"models":[{"name":"smtek/Qwen3.8-27B:Q3_K_XL-16gb"}]}'
assert_status "accepts an available third-party model for a tier" 0 cmd_set_model large "$namespaced_tag"
assert_eq "writes the full namespaced tag for every host" \
  "2" "$(grep -Fc "model: ollama/${namespaced_tag}" "$LITELLM_YAML" || true)"
assert_eq "reads back the full namespaced tier tag" "$namespaced_tag" "$(current_tier_tag large)"
regenerate_litellm >/dev/null 2>&1
assert_eq "namespaced tier tags survive regeneration" \
  "2" "$(grep -Fc "model: ollama/${namespaced_tag}" "$LITELLM_YAML" || true)"
assert_fail "still rejects a provider-prefixed third-party model" cmd_set_model large "ollama/${namespaced_tag}"
reset_repo

describe cmd_set_server_model
reset_repo; NO_PROBE=true
cmd_set_server_model large http://10.0.0.53:11434 solo:7b >/dev/null 2>&1
assert_file_contains "sets the chosen host"       "ollama/solo:7b"   "$LITELLM_YAML"
assert_file_contains "leaves the other host alone" "ollama/qwen3:32b" "$LITELLM_YAML"
assert_fail "rejects a host outside the tier" cmd_set_server_model fast http://10.0.0.53:11434 x:1b
assert_fail "rejects an unconfigured host"    cmd_set_server_model large 10.9.9.9 x:1b
assert_fail "rejects an ollama/ prefix"       cmd_set_server_model large http://10.0.0.53:11434 ollama/x
reset_repo
NO_PROBE=false
mock_command curl 0 '{"models":[{"name":"smtek/Qwen3.8-27B:Q3_K_XL-16gb"}]}'
assert_status "accepts an available third-party model for one server" 0 cmd_set_server_model large 10.0.0.53 "$namespaced_tag"
assert_eq "reads back the full namespaced per-server tag" \
  "$namespaced_tag" "$(current_pair_tag large http://10.0.0.53:11434)"
assert_eq "third-party override leaves the other host alone" \
  "qwen3:32b" "$(current_pair_tag large http://10.0.0.52:11434)"
regenerate_litellm >/dev/null 2>&1
assert_eq "namespaced per-server tag survives regeneration" \
  "$namespaced_tag" "$(current_pair_tag large http://10.0.0.53:11434)"
assert_fail "still rejects a provider-prefixed third-party model" cmd_set_server_model large 10.0.0.53 "ollama/${namespaced_tag}"
reset_repo; NO_PROBE=true

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
assert_contains "one row per deployment" "large" "$out"
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
env_set ROUTER_API_KEY "sk-router-testkey-000000"
mock_reset_log
cmd_discover >/dev/null 2>&1
assert_contains "sends the router key when one is set" "-H @" "$(mock_calls)"
assert_not_contains "never puts the key on the command line" "sk-router-testkey" "$(mock_calls)"
reset_repo

# ── open webui version ────────────────────────────────────────────────────────
describe openwebui_current_version
reset_repo
assert_eq "reads the pin" "0.6.5" "$(openwebui_current_version)"
printf '' > "$OPENWEBUI_REQ"
assert_eq "empty file is empty" "" "$(openwebui_current_version)"
reset_repo

describe openwebui_installed_version
mkdir -p "${OPENWEBUI_DIR}/venv/bin"
rm -f "${OPENWEBUI_DIR}/venv/bin/python"
printf '#!/usr/bin/env bash\necho 0.9.1\n' > "${OPENWEBUI_DIR}/venv/bin/python"
chmod +x "${OPENWEBUI_DIR}/venv/bin/python"
assert_eq "queries the venv" "0.9.1" "$(openwebui_installed_version)"
rm -f "${OPENWEBUI_DIR}/venv/bin/python"
assert_eq "no venv -> empty" "" "$(openwebui_installed_version)"

describe openwebui_python_ok
mkdir -p "${OPENWEBUI_DIR}/venv/bin"
use_real_python "${OPENWEBUI_DIR}/venv/bin/python"
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
use_real_python "${OPENWEBUI_DIR}/venv/bin/python"
assert_fail "rejects a nonexistent release" cmd_set_webui_version 99.99.99
out="$(cmd_set_webui_version 2>&1)"
assert_contains "no-arg shows the pinned version" "0.6.5" "$out"

# ── apply / install ───────────────────────────────────────────────────────────
# A stand-in LiteLLM venv: python reports version $1 and "imports" succeed;
# pip logs its arguments and then reports the pinned version from then on.
make_fake_litellm_venv() {
  rm -rf "$LITELLM_DIR"; mkdir -p "${LITELLM_DIR}/venv/bin"
  echo "$1" > "${LITELLM_DIR}/version"
  cat > "${LITELLM_DIR}/venv/bin/python" <<PYEOF
#!/usr/bin/env bash
[[ "\$*" == *importlib.metadata* ]] && cat "${LITELLM_DIR}/version"
[[ -f "${WORK}/IMPORTFAIL" && "\$*" == *proxy_server* ]] && exit 1
exit 0
PYEOF
  cat > "${LITELLM_DIR}/venv/bin/pip" <<PIPEOF
#!/usr/bin/env bash
echo "pip \$*" >> "${WORK}/litellm-pip.log"
echo 1.75.5.post1 > "${LITELLM_DIR}/version"
PIPEOF
  chmod +x "${LITELLM_DIR}/venv/bin/python" "${LITELLM_DIR}/venv/bin/pip"
  printf 'litellm[proxy]==1.75.5.post1\n' > "$LITELLM_REQ"
  printf 'litellm==1.75.5.post1 --hash=sha256:00\n' > "$LITELLM_LOCK"
  : > "${WORK}/litellm-pip.log"
}

describe litellm_pinned_version
reset_repo
printf '# c\nlitellm[proxy]==1.75.5.post1  # pin\n' > "$LITELLM_REQ"
assert_eq "reads the pin through the extra" "1.75.5.post1" "$(litellm_pinned_version)"
printf 'litellm==1.2.3\n' > "$LITELLM_REQ"
assert_eq "reads a plain pin" "1.2.3" "$(litellm_pinned_version)"
rm -f "$LITELLM_REQ"
assert_eq "no file -> empty" "" "$(litellm_pinned_version)"

describe litellm_installed_version
rm -rf "$LITELLM_DIR"
assert_eq "no venv -> empty" "" "$(litellm_installed_version)"
make_fake_litellm_venv 1.75.5.post1
assert_eq "queries the venv" "1.75.5.post1" "$(litellm_installed_version)"

describe litellm_venv_ok
make_fake_litellm_venv 1.75.5.post1
assert_ok   "pinned version with working imports" litellm_venv_ok
make_fake_litellm_venv 1.70.0
assert_fail "version drift"                       litellm_venv_ok
make_fake_litellm_venv 1.75.5.post1; touch "${WORK}/IMPORTFAIL"
assert_fail "proxy extra missing"                 litellm_venv_ok
rm -f "${WORK}/IMPORTFAIL"; rm -rf "$LITELLM_DIR"
assert_fail "no venv"                             litellm_venv_ok

describe litellm_install
make_fake_litellm_venv 1.70.0
litellm_install >/dev/null 2>&1
assert_file_contains "prefers the hash lock" "--require-hashes -r ${LITELLM_LOCK}" "${WORK}/litellm-pip.log"
rm -f "$LITELLM_LOCK"; : > "${WORK}/litellm-pip.log"
out="$(litellm_install 2>&1)"
assert_contains "warns without a lock" "without hash checking" "$out"
assert_file_contains "falls back to requirements.txt" "-r ${LITELLM_REQ}" "${WORK}/litellm-pip.log"
# A restrictive umask in the operator's shell must not leave the venv unreadable
# for the service account (it failed with status=203/EXEC, Permission denied).
make_fake_litellm_venv 1.70.0
chmod -R go-rwx "$LITELLM_DIR"
( umask 077; litellm_install >/dev/null 2>&1 )
assert_eq "venv readable by the service account after install" "755" "$(stat -c %a "${LITELLM_DIR}/venv/bin")"
assert_eq "entry point executable by others" "755" "$(stat -c %a "${LITELLM_DIR}/venv/bin/python")"
assert_eq "its parent is traversable" "1" "$(( $(stat -c %a "$LITELLM_DIR" | cut -c3) & 1 ))"
rm -rf "$LITELLM_DIR"; reset_repo

describe venv_make_readable
mkdir -p "${WORK}/v/venv/bin" "${WORK}/v/secret"
printf 'x\n' > "${WORK}/v/venv/bin/tool"; chmod 0700 "${WORK}/v/venv/bin/tool"
printf 'x\n' > "${WORK}/v/venv/data"; chmod 0600 "${WORK}/v/venv/data"
chmod 0700 "${WORK}/v" "${WORK}/v/venv" "${WORK}/v/venv/bin" "${WORK}/v/secret"
venv_make_readable "${WORK}/v/venv"
assert_eq "executables become 755" "755" "$(stat -c %a "${WORK}/v/venv/bin/tool")"
assert_eq "plain files become 644" "644" "$(stat -c %a "${WORK}/v/venv/data")"
assert_eq "directories become 755" "755" "$(stat -c %a "${WORK}/v/venv/bin")"
assert_eq "the parent is only made traversable" "711" "$(stat -c %a "${WORK}/v")"
assert_eq "siblings are not touched" "700" "$(stat -c %a "${WORK}/v/secret")"
chmod 0666 "${WORK}/v/venv/data"; venv_make_readable "${WORK}/v/venv"
assert_eq "group/other write is removed" "644" "$(stat -c %a "${WORK}/v/venv/data")"
assert_ok "a missing venv is a no-op" venv_make_readable "${WORK}/nope"
rm -rf "${WORK}/v"

describe repair_venv_access
# runuser stub: the service account can run the interpreter only when it and
# its directory are world-executable (what the real kernel check comes down to).
mock_script runuser <<'RUNEOF'
py="$4"
[[ $(( $(stat -c %a "$py") % 10 & 1 )) == 1 && $(( $(stat -c %a "$(dirname "$py")") % 10 & 1 )) == 1 ]]
RUNEOF
SERVICE_USER=root
make_fake_litellm_venv 1.75.5.post1
chmod -R go-rwx "${LITELLM_DIR}/venv"
out="$(repair_venv_access 2>&1)"; rc=$?
assert_eq "repairs an unreadable venv" "0" "$rc"
assert_contains "and says which" "${LITELLM_DIR}/venv is not usable" "$out"
assert_eq "the interpreter is executable again" "755" "$(stat -c %a "${LITELLM_DIR}/venv/bin/python")"
out="$(repair_venv_access 2>&1)"
assert_eq "a healthy venv is left alone" "" "$out"
mock_command runuser 1
out="$(repair_venv_access 2>&1)"; rc=$?
assert_eq "reports a venv it cannot repair" "1" "$rc"
assert_contains "with a hint" "parent directories" "$out"
SERVICE_USER=no-such-user-xyz
assert_ok "no service account (not a router container): nothing to do" repair_venv_access
SERVICE_USER=ollama-router
rm -f "${MOCK_BIN}/runuser"; rm -rf "$LITELLM_DIR"; reset_repo

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

# ── safe apply ────────────────────────────────────────────────────────────────
describe validate_config
reset_repo
assert_ok "a sane repo validates" validate_config
printf 'model_list: [\n' > "$LITELLM_YAML"
out="$(validate_config)"; rc=$?
assert_ne "broken YAML fails" "0" "$rc"
assert_contains "and says why" "not valid YAML" "$out"
reset_repo
sed -i 's/- large: \["medium", "fast"\]/- large: ["ghost"]/' "$LITELLM_YAML"
assert_contains "fallback to an unknown tier fails" "'ghost'" "$(validate_config)"
reset_repo
printf 'not a key value line\n' >> "$ENV_FILE"
assert_contains "bad env line fails" "not KEY=value" "$(validate_config)"
reset_repo
printf '[keywords]\ncode = ["def ",\n' > "$ROUTER_INI"
assert_fail "bad keyword JSON fails" validate_config
printf '[keywords]\ncode = ["re:(unclosed"]\n' > "$ROUTER_INI"
assert_contains "a bad keyword regex fails" "bad regex" "$(validate_config)"
reset_repo
printf 'def broken(:\n' > "${REPO_DIR}/services/ollama-router/router.py"
assert_contains "a syntax error fails" "does not compile" "$(validate_config)"
reset_repo

describe apply_map
assert_eq "maps every installed file" "11" "$(apply_map | grep -c '|')"
assert_contains "env feeds three services" "litellm-proxy ollama-router ollama-monitor" "$(apply_map)"

describe secrets_fingerprint
rm -f "$SECRETS_FILE"
assert_eq "no file -> none" "none" "$(secrets_fingerprint)"
kv_set "$SECRETS_FILE" A 1; f1="$(secrets_fingerprint)"
kv_set "$SECRETS_FILE" A 2
assert_ne "changes with content" "$f1" "$(secrets_fingerprint)"
rm -f "$SECRETS_FILE"

# Runtime copies identical to the repo, as after a successful apply.
install_runtime() {
  export ROUTER_DIR OPENWEBUI_DIR
  migrate_secrets >/dev/null 2>&1
  bash "$APPLY_SCRIPT" "$REPO_DIR" >/dev/null
  mkdir -p "$UNIT_DIR"
  secrets_fingerprint > "${ROUTER_DIR}/.secrets.applied"
}

describe affected_services
reset_repo; install_runtime
mock_command systemctl 0
assert_eq "nothing changed -> nothing to restart" "" "$(affected_services)"
echo "# tweak" >> "$ROUTER_INI"
assert_eq "router.ini -> router only" "ollama-router" "$(affected_services)"
install_runtime
echo "EXTRA=1" >> "$ENV_FILE"
assert_eq "router.env -> its three services" "litellm-proxy ollama-router ollama-monitor" \
  "$(affected_services | paste -sd' ')"
install_runtime
kv_set "$SECRETS_FILE" ROUTER_API_KEY "k"
assert_eq "secrets -> the services that load them" "ollama-router ollama-monitor open-webui" \
  "$(affected_services | paste -sd' ')"
install_runtime
mock_script systemctl <<'EOF'
[[ "$*" == *open-webui* ]] && exit 3
exit 0
EOF
assert_eq "a stopped service is brought up" "open-webui" "$(affected_services)"
APPLY_ALL=true
assert_eq "--all restarts everything" "4" "$(affected_services | grep -c .)"
APPLY_ALL=false
rm -f "$SECRETS_FILE"

describe snapshot_runtime
reset_repo; install_runtime
snap="$(snapshot_runtime)"
assert_file_contains "records what it saved" "${ROUTER_DIR}/router.ini" "${snap}/MANIFEST"
assert_file_mode "snapshots are root-only" "700" "$snap"
snapshot_runtime >/dev/null; sleep 1; snapshot_runtime >/dev/null
assert_eq "old snapshots are pruned" "2" "$(ls -1d "$APPLY_BACKUP_DIR"/*/ | wc -l)"

describe restore_runtime
snap="$(snapshot_runtime)"
echo "broken" > "${ROUTER_DIR}/router.ini"
restore_runtime "$snap"
assert_ok "puts the previous file back" cmp -s "$ROUTER_INI" "${ROUTER_DIR}/router.ini"
assert_fail "a snapshot without a manifest is refused" restore_runtime "${WORK}/nope"

describe health_url
assert_eq "router"     "${ROUTER_URL}/healthz"            "$(health_url ollama-router)"
assert_eq "litellm"    "$LITELLM_HEALTH_URL"              "$(health_url litellm-proxy)"
assert_eq "open webui" "http://127.0.0.1:8080/health"     "$(health_url open-webui)"
assert_eq "monitor has none" ""                           "$(health_url ollama-monitor)"

describe wait_healthy
mock_command sleep 0
mock_command systemctl 0 "active"
mock_command curl 0
assert_ok   "active and answering"     wait_healthy ollama-router 4
mock_command curl 7
assert_fail "never answers -> timeout" wait_healthy ollama-router 4
mock_command systemctl 3 "failed"
mock_reset_log
assert_fail "a failed unit gives up at once" wait_healthy ollama-router 60
assert_eq   "without waiting it out" "0" "$(mock_call_count 'sleep')"
mock_command systemctl 0 "active"
assert_ok   "no URL -> stays active" wait_healthy ollama-monitor 4

describe restart_and_check
mock_command systemctl 0 "active"
mock_command curl 0
assert_eq "all healthy -> no output" "" "$(restart_and_check litellm-proxy ollama-router 2>/dev/null)"
mock_script curl <<'EOF'
[[ "$*" == *healthz* ]] && exit 7
exit 0
EOF
out="$(restart_and_check litellm-proxy ollama-router open-webui 2>/dev/null)"; rc=$?
assert_eq "names the first unhealthy service" "ollama-router" "$out"
assert_ne "and fails" "0" "$rc"

describe openwebui_data_dir
reset_repo
assert_eq "defaults under OPENWEBUI_DIR" "${OPENWEBUI_DIR}/data" "$(openwebui_data_dir)"
printf 'DATA_DIR=/srv/owui\n' >> "${REPO_DIR}/env/openwebui.env"
assert_eq "honours DATA_DIR" "/srv/owui" "$(openwebui_data_dir)"
reset_repo

describe openwebui_backup_db
mkdir -p "${OPENWEBUI_DIR}/data"; echo "v1" > "${OPENWEBUI_DIR}/data/webui.db"
snap="${WORK}/snapdb"; rm -rf "$snap"; mkdir -p "$snap"
openwebui_backup_db "$snap"
assert_file_contains "copies the database" "v1" "${snap}/openwebui-data/webui.db"

describe openwebui_restore_db
echo "v2-migrated" > "${OPENWEBUI_DIR}/data/webui.db"; touch "${OPENWEBUI_DIR}/data/webui.db-wal"
openwebui_restore_db "$snap"
assert_file_contains "puts the old database back" "v1" "${OPENWEBUI_DIR}/data/webui.db"
assert_fail "drops the new write-ahead log" test -f "${OPENWEBUI_DIR}/data/webui.db-wal"
assert_ok "a snapshot without a database is a no-op" openwebui_restore_db "${WORK}/nope"
rm -rf "$snap" "${OPENWEBUI_DIR}/data"

describe cmd_apply
reset_repo
make_fake_litellm_venv 1.75.5.post1
kv_set "$ENV_FILE" GITEA_DEPLOY_TOKEN "LEAKED"
mock_command systemctl 1     # simulate "systemd not running here"
: > "${WORK}/pip.log"
out="$(cmd_apply 2>&1)"
assert_contains "runs apply-config"        "apply-config ran" "$out"
assert_contains "degrades without systemd" "systemd is not available" "$out"
assert_fail "migrates secrets before applying" kv_has "$ENV_FILE" GITEA_DEPLOY_TOKEN
assert_not_contains "a healthy LiteLLM venv is left alone" "LiteLLM venv missing" "$out"
make_fake_litellm_venv 1.70.0
out="$(cmd_apply 2>&1)"
assert_contains "an outdated LiteLLM venv is rebuilt" "LiteLLM venv missing or out of date" "$out"
assert_file_contains "installs from the hash lock" "--require-hashes -r ${LITELLM_LOCK}" "${WORK}/litellm-pip.log"

# Full cycle with systemd: only changed services restart, and are checked.
reset_repo; make_fake_litellm_venv 1.75.5.post1; install_runtime
mkdir -p "${OPENWEBUI_DIR}/venv/bin"
rm -f "${OPENWEBUI_DIR}/venv/bin/python"
printf '#!/usr/bin/env bash\necho 0.6.5\n' > "${OPENWEBUI_DIR}/venv/bin/python"
chmod +x "${OPENWEBUI_DIR}/venv/bin/python"
mock_command sleep 0
mock_command systemctl 0 "active"
mock_command curl 0
out="$(cmd_apply 2>&1)"
assert_contains "nothing changed -> nothing restarted" "nothing restarted" "$out"
echo "# tweak" >> "$ROUTER_INI"
mock_reset_log
out="$(cmd_apply 2>&1)"
assert_contains "restarts only the router" "Restarting: ollama-router" "$out"
assert_eq "exactly one restart issued" "1" "$(mock_call_count 'restart ')"
assert_contains "reports health" "healthy" "$out"

# Invalid config: stop before touching anything.
printf 'model_list: [\n' > "$LITELLM_YAML"
mock_reset_log
out="$(cmd_apply 2>&1)"; rc=$?
assert_ne "invalid config fails" "0" "$rc"
assert_contains "and says nothing was applied" "nothing was applied" "$out"
assert_eq "no restart was attempted" "0" "$(mock_call_count 'restart ')"
reset_repo; make_fake_litellm_venv 1.75.5.post1; install_runtime

# Unhealthy after restart: roll back to the previous files.
good="$(cat "${ROUTER_DIR}/router.ini")"
echo "# bad change" >> "$ROUTER_INI"
mock_script curl <<'EOF'
grep -q "bad change" "$ROUTER_DIR_WATCH/router.ini" && exit 7
exit 0
EOF
export ROUTER_DIR_WATCH="$ROUTER_DIR"
out="$(cmd_apply 2>&1)"; rc=$?
assert_ne "an unhealthy restart fails the apply" "0" "$rc"
assert_contains "names the service" "ollama-router did not become healthy" "$out"
assert_contains "rolls back" "Rolled back; the previous configuration is running again" "$out"
assert_eq "the previous file is back in place" "$good" "$(cat "${ROUTER_DIR}/router.ini")"

# A failed Open WebUI upgrade: the old version is reinstalled and the database
# (migrated by the new version) is put back.
reset_repo; make_fake_litellm_venv 1.75.5.post1; install_runtime
mkdir -p "${OPENWEBUI_DIR}/venv/bin" "${OPENWEBUI_DIR}/data"
rm -f "${OPENWEBUI_DIR}/venv/bin/python" "${OPENWEBUI_DIR}/venv/bin/pip"
printf '#!/usr/bin/env bash\necho 0.5.0\n' > "${OPENWEBUI_DIR}/venv/bin/python"
printf '#!/usr/bin/env bash\necho "pip $*" >> "%s/webui-pip.log"\n[[ "$*" == *" -r "* ]] && echo migrated > "%s/data/webui.db"\nexit 0\n' \
  "$WORK" "$OPENWEBUI_DIR" > "${OPENWEBUI_DIR}/venv/bin/pip"
chmod +x "${OPENWEBUI_DIR}/venv/bin/python" "${OPENWEBUI_DIR}/venv/bin/pip"
echo "original" > "${OPENWEBUI_DIR}/data/webui.db"
: > "${WORK}/webui-pip.log"
mock_script curl <<'EOF'
[[ "$*" == *":8080/health"* ]] && exit 7
exit 0
EOF
out="$(cmd_apply 2>&1)"; rc=$?
assert_ne "a failed Open WebUI upgrade fails the apply" "0" "$rc"
assert_contains "reports the reinstall" "Reinstalling open-webui 0.5.0" "$out"
assert_file_contains "reinstalls the previous version" "install --no-cache-dir open-webui==0.5.0" "${WORK}/webui-pip.log"
assert_file_contains "restores the pre-upgrade database" "original" "${OPENWEBUI_DIR}/data/webui.db"
rm -rf "${OPENWEBUI_DIR}/venv" "${OPENWEBUI_DIR}/data"
rm -rf "$LITELLM_DIR"

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

describe cmd_set_api_key
reset_repo
out="$(cmd_set_api_key 2>&1)"
key="$(kv_get "$SECRETS_FILE" ROUTER_API_KEY)"
assert_contains "generates a key by default" "sk-router-" "$key"
assert_eq "gives Open WebUI the same key" "$key" "$(kv_get "$SECRETS_FILE" OPENAI_API_KEYS)"
assert_fail "never written to the repo env file" grep -q ROUTER_API_KEY "$ENV_FILE"
assert_contains "explains the Open WebUI caveat" "FIRST start" "$out"
cmd_set_api_key "my-explicit-key-1234" >/dev/null 2>&1
assert_eq "accepts an explicit key" "my-explicit-key-1234" "$(env_get ROUTER_API_KEY)"
assert_fail "rejects a short key" cmd_set_api_key "short"
assert_fail "rejects spaces" cmd_set_api_key "has spaces in the key!!"
cmd_set_api_key --off >/dev/null 2>&1
assert_eq "--off clears it" "" "$(env_get ROUTER_API_KEY)"
reset_repo

describe server_kinds
assert_eq "kinds, in detection order" "lmstudio strata basalt maya xolotl" "$(server_kinds | paste -sd' ' -)"

describe kind_field
assert_eq "maya key" MAYA_API_KEY "$(kind_field maya key)"
assert_eq "maya label" Maya "$(kind_field maya label)"
assert_eq "LM Studio default port" 1234 "$(kind_field lmstudio port)"
assert_eq "a <KIND>_PORT overrides the default" 9090 "$(MAYA_PORT=9090 kind_field maya port)"
assert_eq "LM Studio is not an OpenAI-style kind" 0 "$(kind_field lmstudio openai)"
assert_fail "Ollama is not in the table" kind_field ollama key
assert_fail "unknown field" kind_field maya colour

describe is_server_kind
assert_ok "maya is a kind" is_server_kind maya
assert_fail "ollama is the default, not a table entry" is_server_kind ollama
assert_fail "empty is not a kind" is_server_kind ""

describe is_openai_kind
assert_ok "basalt is OpenAI-style" is_openai_kind basalt
assert_fail "LM Studio is not" is_openai_kind lmstudio
assert_fail "nor is Ollama" is_openai_kind ollama

describe openai_kinds
assert_eq "OpenAI-style kinds" "strata basalt maya xolotl" "$(openai_kinds | paste -sd' ' -)"

describe kind_labels
assert_eq "labels for messages" "Ollama, LM Studio, Strata, Basalt, Maya or Xolotl" "$(kind_labels)"

describe kind_secret_name
assert_eq "LM Studio has a token" "LM Studio token" "$(kind_secret_name lmstudio)"
assert_eq "Maya has an API key" "Maya API key" "$(kind_secret_name maya)"

describe token_command_kind
assert_eq "set-maya-token names maya" maya "$(token_command_kind set-maya-token)"
assert_eq "set-xolotl-token names xolotl" xolotl "$(token_command_kind set-xolotl-token)"
assert_eq "xolotl key" XOLOTL_API_KEY "$(kind_field xolotl key)"
assert_eq "xolotl default port" 8080 "$(kind_field xolotl port)"
assert_eq "set-lmstudio-token names lmstudio" lmstudio "$(token_command_kind set-lmstudio-token)"
assert_eq "set-token is not a kind command" "" "$(token_command_kind set-token)"
assert_eq "set-ollama-token is not a kind command" "" "$(token_command_kind set-ollama-token)"
assert_ok "token commands take the config lock" command_writes set-basalt-token
assert_fail "unknown token commands do not" command_writes set-bogus-token

describe secret_keys
assert_eq "secrets include every kind's key" \
  "LMSTUDIO_API_TOKEN STRATA_API_KEY BASALT_API_KEY MAYA_API_KEY XOLOTL_API_KEY" \
  "$(secret_keys | tail -n 5 | paste -sd' ' -)"

describe litellm_provider
assert_eq "litellm provider for maya" openai "$(litellm_provider maya+http://h:8080)"
assert_eq "litellm provider for LM Studio" lm_studio "$(litellm_provider lmstudio+http://h:1234)"
assert_eq "litellm provider for Ollama" ollama "$(litellm_provider http://h:11434)"
assert_eq "server_base strips only the kind prefix" "http://h:8080" "$(server_base maya+http://h:8080)"

describe cmd_set_kind_token
for kind in $(server_kinds); do
  key_env="$(kind_field "$kind" key)"
  reset_repo
  cmd_set_kind_token "$kind" "${kind}-abc.123" >/dev/null 2>&1
  assert_eq "${kind}: stores the token" "${kind}-abc.123" "$(env_get "$key_env")"
  assert_fail "${kind}: keeps it out of the repo" grep -q "$key_env" "$ENV_FILE"
  assert_fail "${kind}: rejects odd characters" cmd_set_kind_token "$kind" 'a b;c'
  cmd_set_kind_token "$kind" --off >/dev/null 2>&1
  assert_eq "${kind}: --off clears it" "" "$(env_get "$key_env")"
done
assert_fail "an unknown kind is refused" cmd_set_kind_token bogus abc
reset_repo

describe cmd_commit
reset_repo
mock_command git 0
out="$(cmd_commit "msg" 2>&1)"
assert_contains "no-git config dir is a no-op" "not a git repository" "$out"
mkdir -p "${REPO_DIR}/.git"
kv_set "$ENV_FILE" GITEA_DEPLOY_TOKEN "LEAKED"
cmd_commit "msg" >/dev/null 2>&1
assert_fail "a token is moved out before anything is staged" grep -q LEAKED "$ENV_FILE"
unset REQUIRE_PUSH
assert_ok "by default a failed push still succeeds (the commit is kept)" cmd_commit "msg"
out="$(cmd_commit "msg" 2>&1)"
assert_contains "and says the commit is kept locally" "saved locally" "$out"
REQUIRE_PUSH=true
assert_fail "strict mode reports push failure" cmd_commit "msg"
unset REQUIRE_PUSH
rm -rf "${REPO_DIR}/.git"

describe cmd_set_webhook
reset_repo
env_set MATTERMOST_WEBHOOK_URL ""
env_set MATTERMOST_CHANNEL "ollama-monitor"
env_set MATTERMOST_MONITOR_USER "OllamaMonitor"
env_set MATTERMOST_VERIFY_TLS "true"
cmd_set_webhook "https://mm.example.net/hooks/abc" >/dev/null 2>&1
assert_eq "stores the url" "https://mm.example.net/hooks/abc" "$(env_get MATTERMOST_WEBHOOK_URL)"
cmd_set_webhook --verify-tls false >/dev/null 2>&1
assert_eq "sets verify-tls"  "false" "$(env_get MATTERMOST_VERIFY_TLS)"
cmd_set_webhook --username "Bot" >/dev/null 2>&1
assert_eq "sets the username" "Bot" "$(env_get MATTERMOST_MONITOR_USER)"
# An EMPTY channel is meaningful: post wherever the webhook is bound.
cmd_set_webhook --channel "" >/dev/null 2>&1
assert_eq "clears the channel override" "" "$(env_get MATTERMOST_CHANNEL)"
# An empty URL is also meaningful: it disables posting.
cmd_set_webhook "" >/dev/null 2>&1
assert_eq "an empty url disables alerting" "" "$(env_get MATTERMOST_WEBHOOK_URL)"
assert_fail "rejects a non-url"        cmd_set_webhook "not-a-url"
assert_fail "rejects a bad verify-tls" cmd_set_webhook --verify-tls maybe
assert_fail "rejects an unknown flag"  cmd_set_webhook --nope x
out="$(cmd_set_webhook "https://mm.example.net/hooks/secret123" 2>&1)"
assert_not_contains "never echoes the full webhook path" "secret123" "$out"
reset_repo

describe cmd_test_alert
reset_repo
env_set MATTERMOST_WEBHOOK_URL ""
out="$(cmd_test_alert 2>&1)"; rc=$?
assert_contains "explains a missing webhook" "not set" "$out"
assert_contains "says how to set one"        "set-webhook" "$out"
assert_ne "returns non-zero"                 "0" "$rc"

env_set MATTERMOST_WEBHOOK_URL "https://mm.example.net/hooks/abc"
env_set MATTERMOST_CHANNEL "ollama-monitor"
env_set MATTERMOST_VERIFY_TLS "true"

# Delivered.
mock_command curl 0 "200"
out="$(cmd_test_alert 2>&1)"
assert_contains "reports delivery"        "Delivered" "$out"
assert_contains "names the channel"       "#ollama-monitor" "$out"
assert_ok "exits 0 on success" bash -c "source '$FUNCS'; ENV_FILE='$ENV_FILE'; cmd_test_alert >/dev/null 2>&1"

# The payload must carry the channel override and the username.
mock_reset_log; mock_command curl 0 "200"; cmd_test_alert >/dev/null 2>&1
assert_contains "posts JSON"              "Content-Type: application/json" "$(mock_calls)"
assert_contains "includes the channel"    "ollama-monitor" "$(mock_calls)"

# Transport failure: curl exits non-zero and prints no HTTP code.
mock_command curl 7 ""
out="$(cmd_test_alert 2>&1)"
assert_contains "reports a connection failure" "Could not reach" "$out"
assert_contains "explains curl exit 7"         "Connection refused" "$out"
mock_command curl 60 ""
out="$(cmd_test_alert 2>&1)"
assert_contains "maps a TLS failure to the fix" "verify-tls false" "$out"

# 4xx WITH a channel override: retried without it, and that retry succeeds.
mock_script curl <<'EOF'
for a in "$@"; do case "$a" in *'"channel"'*) echo -n 403; exit 0;; esac; done
echo -n 200
EOF
out="$(cmd_test_alert 2>&1)"
assert_contains "retries without the override"  "Retrying without" "$out"
assert_contains "identifies the override as the fault" "refusing to redirect" "$out"

# 4xx both ways: the webhook itself is wrong.
mock_command curl 0 "404"
out="$(cmd_test_alert 2>&1)"
assert_contains "reports a dead webhook" "wrong or has been deleted" "$out"
reset_repo

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

describe command_writes
for c in add remove set-tier set-model set-server-model set-keepalive apply commit \
         set-token set-api-key set-lmstudio-token set-strata-token set-webhook set-webui-version; do
  assert_ok "${c} takes the lock" command_writes "$c"
done
for c in list status models discover test-alert clear-lock; do
  assert_fail "${c} never waits on the lock" command_writes "$c"
done

# The lock tests need real time: earlier sections stub `sleep` out.
rm -f "${MOCK_BIN}/sleep"

# hold_lock FILE [ignore-term]: a background process that takes the lock and
# keeps it; prints its PID once the lock is really held. (Run in $(...), so the
# caller sets CONFIG_LOCK_FILE itself.)
hold_lock() {
  local f="$1" pid
  if [[ "${2:-}" == ignore-term ]]; then
    bash -c 'trap "" TERM; exec 9>>"$1"; flock 9; while :; do sleep 0.1; done' _ "$f" >/dev/null 2>&1 &
  else
    bash -c 'exec 9>>"$1"; flock 9; exec sleep 60' _ "$f" >/dev/null 2>&1 &
  fi
  pid=$!
  for _ in $(seq 50); do CONFIG_LOCK_FILE="$f" lock_is_free || break; sleep 0.1; done
  printf '%s\n' "$pid"
}
# stop_holder PID: end a hold_lock process and wait until the lock is free.
stop_holder() {
  kill "$1" 2>/dev/null || true
  for _ in $(seq 50); do lock_is_free && return 0; sleep 0.1; done
}

describe lock_path
mkdir -p "$WORK/real"; ln -sfn "$WORK/real" "$WORK/link"
CONFIG_LOCK_FILE="$WORK/link/x.lock"
assert_eq "resolves symlinked directories (so /proc fd links compare equal)" "$WORK/real/x.lock" "$(lock_path)"

describe lock_is_free
CONFIG_LOCK_FILE="$WORK/free.lock"
assert_ok "a missing lock file is free" lock_is_free
assert_fail "probing does not create the file" test -e "$WORK/free.lock"
: > "$WORK/free.lock"
assert_ok "an unlocked file is free" lock_is_free
holder="$(hold_lock "$WORK/free.lock")"
assert_fail "a held lock is not free" lock_is_free
stop_holder "$holder"
assert_ok "free again once the holder exits (nothing to clean up after a crash)" lock_is_free

describe lock_holders
CONFIG_LOCK_FILE="$WORK/holders.lock"; holder="$(hold_lock "$WORK/holders.lock")"
assert_contains "lists the holding process" "$holder" "$(lock_holders)"
stop_holder "$holder"
assert_eq "empty once it exits" "" "$(lock_holders)"

describe lock_inherited
CONFIG_LOCK_FILE="$WORK/inherit.lock"
unset CONFIG_LOCK_INHERITED_FD
assert_fail "no descriptor handed over" lock_inherited
exec 7>>"$WORK/inherit.lock"
CONFIG_LOCK_INHERITED_FD=7
assert_fail "an open but unlocked descriptor is not enough" lock_inherited
flock -n 7
assert_ok "an open, locked descriptor on the lock file is inherited" lock_inherited
CONFIG_LOCK_INHERITED_FD=abc
assert_fail "a non-numeric value is ignored" lock_inherited
exec 6>>"$WORK/other.lock"; flock -n 6
CONFIG_LOCK_INHERITED_FD=6
assert_fail "a descriptor on another file is ignored" lock_inherited
exec 6>&- 7>&-
unset CONFIG_LOCK_INHERITED_FD

describe acquire_config_lock
CONFIG_LOCK_FILE="$WORK/config.lock"
CONFIG_LOCK_FD=""
CONFIG_LOCK_WAIT=0
acquire_config_lock
assert_ok "acquires an available lock" test -f "$CONFIG_LOCK_FILE"
eval "exec ${CONFIG_LOCK_FD}>&-"
exec 9>"$WORK/held.lock"
flock -n 9
CONFIG_LOCK_FILE="$WORK/held.lock"
out="$( (acquire_config_lock) 2>&1)"; rc=$?
assert_eq "refuses a held lock" "1" "$rc"
assert_contains "and points at clear-lock" "clear-lock" "$out"
exec 9>&-
CONFIG_LOCK_FILE="$WORK/named.lock"; holder="$(hold_lock "$WORK/named.lock")"
out="$( (acquire_config_lock) 2>&1)"
assert_eq "names only the real holder, not itself" "$holder" "$(sed -n 's/.*PID(s): *//p' <<< "$out" | xargs)"
stop_holder "$holder"
holder="$(hold_lock "$WORK/wait.lock")"
( sleep 1; kill "$holder" ) &
CONFIG_LOCK_WAIT=5
assert_ok "CONFIG_LOCK_WAIT waits for the holder to finish" bash -c "source '$FUNCS'; die(){ exit 1; }; note(){ :; }
  CONFIG_LOCK_FILE='$WORK/wait.lock' CONFIG_LOCK_WAIT=5 CONFIG_LOCK_FD=''; acquire_config_lock"
CONFIG_LOCK_WAIT=abc
assert_fail "CONFIG_LOCK_WAIT must be a number" acquire_config_lock
CONFIG_LOCK_WAIT=0
wait 2>/dev/null

describe cmd_clear_lock
ASSUME_YES=true; DRY_RUN=false; FORCE=false; LOCK_KILL_WAIT=1
CONFIG_LOCK_FILE="$WORK/none.lock"
out="$(cmd_clear_lock 2>&1)"; rc=$?
assert_eq "no lock file: nothing to do" "0" "$rc"
: > "$WORK/stale.lock"; CONFIG_LOCK_FILE="$WORK/stale.lock"
out="$(cmd_clear_lock 2>&1)"; rc=$?
assert_eq "a leftover file after a crash is not a lock" "0" "$rc"
assert_contains "and says so" "not held" "$out"
assert_ok "the file is kept (deleting it could split the lock)" test -e "$WORK/stale.lock"
CONFIG_LOCK_FILE="$WORK/live.lock"; holder="$(hold_lock "$WORK/live.lock")"
out="$(cmd_clear_lock 2>&1)"; rc=$?
assert_eq "a live holder is not touched without --force" "1" "$rc"
assert_contains "names the holder" "$holder" "$out"
assert_ok "the holder is still running" kill -0 "$holder"
FORCE=true
out="$(cmd_clear_lock 2>&1)"; rc=$?
assert_eq "--force stops the holder" "0" "$rc"
assert_ok "the lock is free afterwards" lock_is_free
assert_contains "and suggests re-applying" "apply" "$out"
wait "$holder" 2>/dev/null
CONFIG_LOCK_FILE="$WORK/stubborn.lock"; holder="$(hold_lock "$WORK/stubborn.lock" ignore-term)"
out="$(cmd_clear_lock 2>&1)"; rc=$?
assert_eq "a holder that ignores SIGTERM gets SIGKILL" "0" "$rc"
assert_contains "and the escalation is reported" "SIGKILL" "$out"
assert_ok "the lock is free afterwards" lock_is_free
wait 2>/dev/null
CONFIG_LOCK_FILE="$WORK/confirm.lock"; holder="$(hold_lock "$WORK/confirm.lock")"
ASSUME_YES=false
out="$(cmd_clear_lock 2>&1 </dev/null)"; rc=$?
assert_eq "an unconfirmed --force stops nothing" "1" "$rc"
assert_ok "the holder is still running" kill -0 "$holder"
stop_holder "$holder"
ASSUME_YES=true; FORCE=false

summary
