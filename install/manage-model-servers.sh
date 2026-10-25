#!/usr/bin/env bash
set -euo pipefail
# ==============================================================================
# manage-model-servers.sh — add / remove / re-tier the Ollama model servers of
# a running ollama-smart-router container, without re-running the installer.
#
# Run it from either place, as root:
#   * inside the container:   ./manage-model-servers.sh list
#   * on the Proxmox host:    ./manage-model-servers.sh list
# When run on the host, it locates the container that actually holds the config
# (by testing for the file, not by guessing a name) and re-execs itself there.
# Set CT_ID to skip the search.
#
# It edits the version-controlled config in $CONFIG_REPO_DIR, regenerates
# litellm_config.yaml from the tier assignments, then (optionally) applies the
# result and restarts the affected services. Servers are tracked by URL, never
# by index, so removing one never silently re-points another.
# ==============================================================================

REPO_DIR="${CONFIG_REPO_DIR:-/app/config-repo}"
ROUTER_DIR="${ROUTER_DIR:-/app/router}"
ENV_FILE="${REPO_DIR}/env/router.env"
LITELLM_YAML="${REPO_DIR}/services/litellm-proxy/litellm_config.yaml"
ROUTER_INI="${REPO_DIR}/services/ollama-router/router.ini"
OPENWEBUI_REQ="${REPO_DIR}/services/open-webui/requirements.txt"
OPENWEBUI_DIR="${OPENWEBUI_DIR:-/app/openwebui}"
APPLY_SCRIPT="${REPO_DIR}/install/apply-config.sh"
# Secrets never live in the config repo: they are kept beside the runtime copy
# of the env file, readable by the service group only, and loaded by the units
# that need them through a second EnvironmentFile=.
SECRETS_FILE="${SECRETS_FILE:-${ROUTER_DIR}/secrets.env}"
# LiteLLM runs from its own venv (see services/litellm-proxy/requirements.txt).
LITELLM_DIR="${LITELLM_DIR:-/app/litellm}"
LITELLM_REQ="${REPO_DIR}/services/litellm-proxy/requirements.txt"
LITELLM_LOCK="${REPO_DIR}/services/litellm-proxy/requirements.lock"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
# Default ports of the other server kinds are in kind_field (LM Studio 1234,
# Strata/Basalt/Maya/Xolotl 8080); LMSTUDIO_PORT, STRATA_PORT, BASALT_PORT,
# MAYA_PORT and XOLOTL_PORT in the environment override them.
LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
SERVER_TYPE="auto"   # --type ollama|<kind>|auto for add / set-tier (see server_kinds)
MODEL_SERVER_MAX="${MODEL_SERVER_MAX:-20}"
MODEL_SERVER_MIN="${MODEL_SERVER_MIN:-1}"
ROUTER_URL="${ROUTER_URL:-http://127.0.0.1:8000}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-5}"
SERVICES=(litellm-proxy ollama-router ollama-monitor open-webui)
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
# Snapshots of the runtime files taken before each apply (root-only).
APPLY_BACKUP_DIR="${APPLY_BACKUP_DIR:-/var/backups/ollama-smart-router}"
APPLY_BACKUP_KEEP="${APPLY_BACKUP_KEEP:-5}"
# One config change at a time (this tool and install/update-router.sh share it).
# The lock is an flock on this file: it lasts only as long as the process that
# holds it, so a crash or reboot never leaves it in force. CONFIG_LOCK_WAIT
# seconds to wait for it (0 = fail at once); `clear-lock` deals with a hung holder.
CONFIG_LOCK_FILE="${CONFIG_LOCK_FILE:-/run/lock/ollama-smart-router-config.lock}"
CONFIG_LOCK_WAIT="${CONFIG_LOCK_WAIT:-0}"
# Seconds clear-lock --force gives a holder to exit after SIGTERM before SIGKILL.
LOCK_KILL_WAIT="${LOCK_KILL_WAIT:-10}"
# Seconds a restarted service gets to pass its health check. Open WebUI's
# first start downloads an embedding model, hence its longer allowance.
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
OPENWEBUI_HEALTH_TIMEOUT="${OPENWEBUI_HEALTH_TIMEOUT:-300}"
LITELLM_HEALTH_URL="${LITELLM_HEALTH_URL:-http://127.0.0.1:4000/health/liveliness}"
APPLY_ALL=false
CONFIG_LOCK_FD=""

declare -A TIER_MODEL_OVERRIDE=()   # tier            -> model tag
declare -A PAIR_MODEL_OVERRIDE=()   # "tier|server"   -> model tag

CHANGED=false      # set by a command that actually wrote something
DRY_RUN=false
NO_PROBE=false
AUTO_APPLY=false
AUTO_COMMIT=false
ASSUME_YES=false
FORCE=false

usage() {
  cat <<'USAGE'
Usage: manage-model-servers.sh <command> [options]

Commands:
  list                       Show configured servers and their tier assignments
  status                     As list, plus a live reachability probe of each host
  discover                   Ask the router to re-poll and print the live model inventory
  add <addr> [addr...]       Add server(s). Address may be IP, host:port or a URL.
                             LM Studio, Strata, Basalt, Maya and Xolotl are detected
                             automatically, or use lmstudio://host / strata://host /
                             basalt://host / maya://host / xolotl://host or --type.
                             Detection sends no API key.
  remove <addr> [addr...]    Remove server(s) by address (or by list number)
  set-tier <tier> <addr...>  Replace a tier's servers (tier: fast|medium|large|xlarge)
  set-model <tier> <model>   Set the model for EVERY server in a tier
  set-server-model <tier> <server> <model>
                             Set the model for ONE server within a tier
  set-keepalive <value>      Set how long Ollama keeps models resident
                             (e.g. 30m, 2h, -1 = never unload, blank = use the
                             server's own OLLAMA_KEEP_ALIVE)
  models                     List every model available across the configured hosts
  apply [--all]              Validate the config, apply it, restart only the
                             services whose files changed, health-check them,
                             and roll back automatically if one fails.
                             --all restarts every service regardless
  commit [message]           Commit and push the config repo to Gitea
  set-token [token]          Store/replace the Gitea deploy token used for
                             pushing (prompts if not given, then verifies it)
  test-alert [message]       Post a test message through the Mattermost webhook
                             and report exactly why it failed if it did
  set-webhook [url] [--channel <c>] [--username <u>] [--verify-tls true|false]
                             Configure Mattermost alerting. An empty url
                             disables posting; an empty --channel posts to
                             whichever channel the webhook is bound to
  set-lmstudio-token [token|--off]
                             Bearer token for LM Studio servers that require
                             authentication (stored in secrets.env)
  set-strata-token [token|--off]
                             Bearer token for Strata servers with an API key
                             (stored in secrets.env)
  set-basalt-token [token|--off]
                             Bearer token for Basalt servers with an API key
                             (stored in secrets.env)
  set-maya-token [token|--off]
                             Bearer token for Maya servers with an API key
                             (stored in secrets.env)
  set-xolotl-token [token|--off]
                             Bearer token for Xolotl servers with an API key
                             (stored in secrets.env)
  set-api-key [key|--generate|--off]
                             Require "Authorization: Bearer <key>" on the router
                             API (Open WebUI is given the same key)
  set-webui-version [v]      Show, or pin, the Open WebUI version (use 'latest').
                             Checks the version exists and that the venv's
                             Python satisfies its Requires-Python
  clear-lock [--force]       Show who holds the config lock. A crash or reboot
                             never leaves it in force (it dies with its
                             process); a live but hung holder is only stopped
                             with --force (SIGTERM, then SIGKILL)

Options:
  --tier <t[,t...]>          With 'add': also assign the new server(s) to these tiers
  --type <ollama|lmstudio|strata|basalt|maya|xolotl> With 'add' / 'set-tier': the server's API (default:
                             auto-detect by probing; ollama when --no-probe)
  --apply                    Apply + restart services after the change
  --commit[=msg]             Commit and push the change after applying
  --no-probe                 Skip the reachability check when adding, and the
                             model-availability check when setting a model
  --dry-run                  Show what would change; write nothing
  --yes, -y                  Do not prompt for confirmation
  --force                    With 'clear-lock': stop the process holding the lock
  -h, --help                 This help

Examples:
  manage-model-servers.sh add 10.0.0.55 --tier large --apply
  manage-model-servers.sh add ollama7.lan:11434 --tier fast,medium --apply --commit
  manage-model-servers.sh remove 10.0.0.52 --apply
  manage-model-servers.sh set-tier large 10.0.0.54 10.0.0.55 --apply
  manage-model-servers.sh models
  manage-model-servers.sh set-model large qwen3:32b --apply --commit
  manage-model-servers.sh set-server-model large 10.0.0.54 llama3.3:70b --apply
  manage-model-servers.sh set-server-model medium 192.168.11.14 smtek/Qwen3.8-27B:Q3_K_XL-16gb --apply
  manage-model-servers.sh set-keepalive 2h --apply
  manage-model-servers.sh set-webui-version latest --apply
USAGE
}

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

# --- address handling ---------------------------------------------------------
valid_hostname_or_ip() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

# --- server kinds -------------------------------------------------------------
# One table for every server kind that is not Ollama. Their entries are stored
# as <kind>+http://host:port, so each consumer knows which API to speak.
# router.py and monitor.py keep matching SERVER_KINDS tables, and
# tests/test_monitor.py checks that all three agree. Adding a kind here (and
# there) is all the manager needs: detection fingerprints aside, nothing below
# names a kind.
#   key    -- secrets.env variable with the bearer token for that kind
#   label  -- human name in messages
#   port   -- default port (overridable through the <KIND>_PORT variable)
#   openai -- 1 for Strata-style servers (models at /v1/models, LiteLLM's
#             openai provider), 0 for LM Studio (its own API and provider)
server_kinds() { printf '%s\n' lmstudio strata basalt maya xolotl; }
kind_field() {
  local spec key label port_var port_default openai value
  case "$1" in
    lmstudio) spec='LMSTUDIO_API_TOKEN|LM Studio|LMSTUDIO_PORT|1234|0' ;;
    strata)   spec='STRATA_API_KEY|Strata|STRATA_PORT|8080|1' ;;
    basalt)   spec='BASALT_API_KEY|Basalt|BASALT_PORT|8080|1' ;;
    maya)     spec='MAYA_API_KEY|Maya|MAYA_PORT|8080|1' ;;
    xolotl)   spec='XOLOTL_API_KEY|Xolotl|XOLOTL_PORT|8080|1' ;;
    *) return 1 ;;
  esac
  IFS='|' read -r key label port_var port_default openai <<< "$spec"
  case "$2" in
    key) printf '%s\n' "$key" ;;
    label) printf '%s\n' "$label" ;;
    port) value="${!port_var:-}"; printf '%s\n' "${value:-$port_default}" ;;
    openai) printf '%s\n' "$openai" ;;
    *) return 1 ;;
  esac
}
is_server_kind() { [[ -n "$1" ]] && server_kinds | grep -qx -- "$1"; }
is_openai_kind() { is_server_kind "$1" && [[ "$(kind_field "$1" openai)" == 1 ]]; }
openai_kinds() { local k; for k in $(server_kinds); do is_openai_kind "$k" && echo "$k"; done; return 0; }
# "Ollama, LM Studio, Strata, Basalt, Maya or Xolotl"
kind_labels() {
  local out=Ollama k label last=""
  for k in $(server_kinds); do
    label="$(kind_field "$k" label)"
    [[ -n "$last" ]] && out+=", ${last}"
    last="$label"
  done
  printf '%s or %s\n' "$out" "$last"
}
# The secret's name in messages: "LM Studio token", "Maya API key".
kind_secret_name() {
  if [[ "$1" == lmstudio ]]; then echo "LM Studio token"
  else printf '%s API key\n' "$(kind_field "$1" label)"; fi
}

server_kind() {
  local k
  for k in $(server_kinds); do
    [[ "$1" == "$k"+* ]] && { echo "$k"; return 0; }
  done
  echo ollama
}
server_base() {
  local kind; kind="$(server_kind "$1")"
  if [[ "$kind" == ollama ]]; then printf '%s\n' "$1"; else printf '%s\n' "${1#"$kind"+}"; fi
}
# LiteLLM provider prefix and api_base for a server entry. OpenAI-compatible
# servers use /v1; LM Studio uses LiteLLM's lm_studio/ provider.
litellm_provider() {
  local kind; kind="$(server_kind "$1")"
  if [[ "$kind" == lmstudio ]]; then echo lm_studio
  elif is_openai_kind "$kind"; then echo openai
  else echo ollama; fi
}
litellm_api_base() {
  if [[ "$(server_kind "$1")" != ollama ]]; then
    printf '%s/v1\n' "$(server_base "$1")"
  else
    printf '%s\n' "$1"
  fi
}

# curl against a server entry, with its API token when there is one.
# The header goes through a file descriptor so the token never shows in `ps`.
server_curl() {
  local url="$1" path="$2" token="" kind
  kind="$(server_kind "$url")"
  if [[ "$kind" != ollama ]]; then
    token="$(env_get "$(kind_field "$kind" key)" 2>/dev/null)"
  fi
  if [[ -n "$token" ]]; then
    curl -fsS --max-time "$PROBE_TIMEOUT" -H @<(printf 'Authorization: Bearer %s\n' "$token") \
      "$(server_base "$url")${path}"
  else
    curl -fsS --max-time "$PROBE_TIMEOUT" "$(server_base "$url")${path}"
  fi
}

valid_addr() {
  local raw="$1" port
  [[ -n "$raw" ]] || return 1
  # Kind prefixes (maya+http://..., maya://host) select the non-Ollama APIs.
  local k
  for k in $(server_kinds); do
    raw="${raw#"$k"+}"
    [[ "$raw" == "$k"://* ]] && raw="${raw#"$k"://}"
  done
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    [[ "$raw" =~ ^https?://[A-Za-z0-9._-]+(:[0-9]+)?(/.*)?$ ]]
    return $?
  fi
  if [[ "$raw" == *:* ]]; then
    port="${raw##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    valid_hostname_or_ip "${raw%:*}"
    return $?
  fi
  valid_hostname_or_ip "$raw"
}

# Canonical form of an address: http://host:port for Ollama, or a kind prefix
# plus http://host:port for the OpenAI-compatible servers. $2 (or SERVER_TYPE)
# may force the kind; the default port follows it.
normalize_addr() {
  local raw="${1%/}" kind="${2:-$SERVER_TYPE}" port base k
  for k in $(server_kinds); do
    if [[ "$raw" == "$k"+* ]]; then kind="$k"; raw="${raw#"$k"+}"; break; fi
    if [[ "$raw" == "$k"://* ]]; then kind="$k"; raw="${raw#"$k"://}"; break; fi
  done
  if is_server_kind "$kind"; then port="$(kind_field "$kind" port)"; else port="$OLLAMA_PORT"; fi
  if [[ "$raw" == http://* || "$raw" == https://* ]]; then
    base="$raw"
  elif [[ "$raw" == *:* ]]; then
    base="http://${raw}"
  else
    base="http://${raw}:${port}"
  fi
  if is_server_kind "$kind"; then
    printf '%s+%s\n' "$kind" "$base"
  else printf '%s\n' "$base"; fi
}

# Which API answers at a plain http base URL.
detect_server_kind() {
  local base="$1" body
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${base}/api/tags" 2>/dev/null)" &&
     [[ "$body" == *'"models"'* ]]; then
    echo ollama; return 0
  fi
  # Both services identify themselves at public /health without credentials.
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${base}/health" 2>/dev/null)"; then
    if [[ "$body" =~ \"service\"[[:space:]]*:[[:space:]]*\"strata\" ]]; then
      # Xolotl serves through Strata's server; its DeepSeek-V4 engine (a model
      # upstream Strata does not run) tells it apart.
      if [[ "$body" =~ \"model\"[[:space:]]*:[[:space:]]*\"deepseek-v4 ]]; then
        echo xolotl; return 0
      fi
      echo strata; return 0
    fi
    if [[ "$body" =~ \"service\"[[:space:]]*:[[:space:]]*\"basalt\" ]]; then
      echo basalt; return 0
    fi
    if [[ "$body" =~ \"model\"[[:space:]]*:[[:space:]]*\"glm-5\.3-flash\" ]] &&
       [[ "$body" == *'"version"'* ]]; then
      echo maya; return 0
    fi
  fi
  local code path status_code=''
  body="$(curl -sS --max-time "$PROBE_TIMEOUT" -w '\n%{http_code}' "${base}/v1/status" 2>/dev/null || true)"
  status_code="${body##*$'\n'}"; body="${body%$'\n'*}"
  if [[ "$status_code" == 200 && "$body" == *'"auto_load"'* && "$body" == *'"loaded"'* ]]; then
    echo strata; return 0
  fi
  if body="$(curl -fsS --max-time "$PROBE_TIMEOUT" "${base}/v1/models" 2>/dev/null)" &&
     [[ "$body" =~ \"(id|owned_by)\"[[:space:]]*:[[:space:]]*\"strata\" ]]; then
    echo strata; return 0
  fi
  # LM Studio: its native model API (0.4+ /api/v1, 0.3 /api/v0). A 401 still
  # identifies it: authentication is on and needs set-lmstudio-token. An
  # older keyed server without a service marker on /health can also answer
  # 401 here; then only LM Studio's own port settles it.
  for path in /api/v1/models /api/v0/models; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$PROBE_TIMEOUT" "${base}${path}" 2>/dev/null || true)"
    [[ "$code" == 200 ]] && { echo lmstudio; return 0; }
    if [[ "$code" == 401 ]]; then
      if [[ "$status_code" != 401 || "${base##*:}" == "$LMSTUDIO_PORT" ]]; then
        echo lmstudio; return 0
      fi
      note "  ${base} requires authentication, so its API cannot be identified without sending a key."
      local k forms=()
      for k in $(openai_kinds) lmstudio; do forms+=("${k}://${base#*://}"); done
      note "  Add it as one of: ${forms[*]} (or use --type)."
      return 1
    fi
  done
  return 1
}

# The configured entry an address refers to, so "10.0.0.9:1234" finds a stored
# lmstudio+http://10.0.0.9:1234 without the prefix having to be typed. Prints
# the normalized form when nothing matches.
configured_entry() {
  local url alt k
  url="$(normalize_addr "$1")"
  get_servers | contains_line "$url" && { printf '%s\n' "$url"; return 0; }
  for k in lmstudio ollama $(openai_kinds); do
    alt="$(normalize_addr "$1" "$k")"
    get_servers | contains_line "$alt" && { printf '%s\n' "$alt"; return 0; }
  done
  printf '%s\n' "$url"
}

# Resolve a user-supplied address to a stored server entry, probing to find
# out what it is unless --type says so (or --no-probe is given, which assumes
# Ollama unless the address has a kind prefix). Prints the entry; returns 1 if
# nothing usable answers.
resolve_server() {
  local addr="$1" url base kind alt
  url="$(normalize_addr "$addr")"
  [[ "$SERVER_TYPE" != auto || "$(server_kind "$url")" != ollama ]] && { printf '%s\n' "$url"; return 0; }
  $NO_PROBE && { printf '%s\n' "$url"; return 0; }
  base="$(server_base "$url")"
  if kind="$(detect_server_kind "$base")"; then
    normalize_addr "$base" "$kind"; return 0
  fi
  # A bare host got Ollama's port; another API may be on its own port instead.
  # Each distinct default port is probed once, and whichever OpenAI-style
  # server answers there is accepted (they share 8080 unless overridden).
  if [[ "$addr" != *:* ]]; then
    alt="$(server_base "$(normalize_addr "$addr" lmstudio)")"
    if kind="$(detect_server_kind "$alt")" && [[ "$kind" == lmstudio ]]; then
      normalize_addr "$alt" lmstudio; return 0
    fi
    local k tried=" "
    for k in $(openai_kinds); do
      alt="$(server_base "$(normalize_addr "$addr" "$k")")"
      [[ "$tried" == *" $alt "* ]] && continue
      tried+="$alt "
      if kind="$(detect_server_kind "$alt")" && is_openai_kind "$kind"; then
        normalize_addr "$alt" "$kind"; return 0
      fi
    done
  fi
  return 1
}

# --- env file access ----------------------------------------------------------
# Keys that must never be written to the version-controlled env file.
secret_keys() {
  local k
  printf '%s\n' GITEA_DEPLOY_TOKEN MATTERMOST_WEBHOOK_URL ROUTER_API_KEY OPENAI_API_KEYS
  for k in $(server_kinds); do kind_field "$k" key; done
}
is_secret_key() { secret_keys | grep -qx -- "$1"; }

# Raw KEY=value access to one file. kv_get prints nothing for a missing key;
# kv_has distinguishes "absent" from "present but empty".
kv_has() { [[ -f "$1" ]] && grep -q "^${2}=" "$1"; }
kv_get() {
  [[ -f "$1" ]] || return 0
  awk -v k="$2" -F= '$1==k {sub(/^[^=]*=/,""); print; exit}' "$1"
}
kv_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if kv_has "$file" "$key"; then
    # ENVIRON, not -v: awk -v would interpret backslashes in the value.
    KV_VALUE="$value" awk -v k="$key" -F= \
      '{ if ($1==k) print k "=" ENVIRON["KV_VALUE"]; else print }' "$file" > "$tmp"
  else
    [[ -f "$file" ]] && cp "$file" "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  # Copy content rather than mv, so an existing file keeps its 0640
  # root:ollama-router ownership and mode instead of inheriting the temp file's.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}
kv_del() {
  local file="$1" key="$2" tmp
  kv_has "$file" "$key" || return 0
  tmp="$(mktemp)"
  awk -v k="$key" -F= '$1!=k' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Create the secrets file with service-group-only permissions if needed.
ensure_secrets_file() {
  [[ -f "$SECRETS_FILE" ]] && return 0
  mkdir -p "$(dirname "$SECRETS_FILE")"
  ( umask 027; : > "$SECRETS_FILE" )
  chown root:ollama-router "$SECRETS_FILE" 2>/dev/null || true
  chmod 0640 "$SECRETS_FILE"
}

# --- env file access ----------------------------------------------------------
# Secret keys resolve from SECRETS_FILE first and fall back to the repo env file,
# so a deployment that has not been migrated yet keeps working.
env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || die "env file not found: ${ENV_FILE}"
  if is_secret_key "$key" && kv_has "$SECRETS_FILE" "$key"; then
    kv_get "$SECRETS_FILE" "$key"
    return 0
  fi
  kv_get "$ENV_FILE" "$key"
}

env_set() {
  local key="$1" value="$2"
  if is_secret_key "$key"; then
    $DRY_RUN && { echo "  [dry-run] ${key}=<secret> -> ${SECRETS_FILE}"; return 0; }
    ensure_secrets_file
    kv_set "$SECRETS_FILE" "$key" "$value"
    kv_del "$ENV_FILE" "$key"
    return 0
  fi
  $DRY_RUN && { echo "  [dry-run] ${key}=${value}"; return 0; }
  kv_set "$ENV_FILE" "$key" "$value"
}

# Move any secret still sitting in the version-controlled env file into
# SECRETS_FILE. Runs before every commit and apply, so a token can never be
# committed again once this script has touched the deployment.
migrate_secrets() {
  local key value moved=0
  $DRY_RUN && return 0
  [[ -f "$ENV_FILE" ]] || return 0
  for key in $(secret_keys); do
    kv_has "$ENV_FILE" "$key" || continue
    value="$(kv_get "$ENV_FILE" "$key")"
    if [[ -n "$value" ]] && ! kv_has "$SECRETS_FILE" "$key"; then
      ensure_secrets_file
      kv_set "$SECRETS_FILE" "$key" "$value"
    fi
    kv_del "$ENV_FILE" "$key"
    [[ -n "$value" ]] && moved=$((moved + 1))
  done
  if (( moved )); then
    note "Moved ${moved} secret(s) out of $(basename "$ENV_FILE") into ${SECRETS_FILE}."
    note "  They are still in the repo's git history: rotate the Gitea token and"
    note "  the Mattermost webhook if the repo was ever pushed."
  fi
}

# NOTE for callers: this dies on an unknown tier, but a `die` inside $(...)
# only kills the subshell. Assignment sites must therefore append `|| exit 1`,
# or an invalid tier silently yields an empty key and corrupts router.env.
tier_env_key() {
  case "$1" in
    fast)   echo "BACKEND_FAST" ;;
    medium) echo "BACKEND_MEDIUM" ;;
    large)  echo "BACKEND_LARGE" ;;
    xlarge) echo "BACKEND_XLARGE" ;;
    *) die "unknown tier '$1' (expected fast, medium, large or xlarge)" ;;
  esac
}

# Tier model_name comes from router.ini so custom names are honoured.
tier_model_name() {
  local key="$1" val=""
  if [[ -f "$ROUTER_INI" ]]; then
    val="$(awk -v k="$key" '/^\[tiers\]/{f=1;next} /^\[/{f=0} f && $1==k {print $3; exit}' "$ROUTER_INI")"
  fi
  printf '%s' "${val:-${key}}"
}

# NOTE the trailing newline: without it the final element has no line
# terminator, and `while read` silently drops it.
csv_to_lines() { printf '%s\n' "$1" | tr ',' '\n' | sed '/^[[:space:]]*$/d'; }
lines_to_csv() { paste -sd, - ; }

get_servers()  { csv_to_lines "$(env_get MODEL_SERVERS)"; }
# Returns 1 rather than dying on an unknown tier: this runs inside command
# substitutions, where `exit` would kill only the subshell and the caller would
# see an empty (successful-looking) list. Callers that must abort validate the
# tier separately with `tier_env_key "$tier" >/dev/null`.
get_tier() {
  local __k
  __k="$(tier_env_key "$1")" || return 1
  csv_to_lines "$(env_get "$__k")"
}

contains_line() {  # $1 = needle, stdin = haystack
  local needle="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$needle" ]] && return 0
  done
  return 1
}

# --- reachability -------------------------------------------------------------
probe_server() {  # prints model count, "-" when unreachable, "?" when unreadable
  local url="$1" names rc=0
  names="$(server_models "$url")" || rc=$?
  case "$rc" in
    0) printf '%s' "$(printf '%s' "$names" | grep -c . || true)" ;;
    3) printf '%s' "?" ;;
    *) printf '%s' "-" ;;
  esac
}

# Chat-capable model names a server offers, one per line. Ollama: /api/tags.
# LM Studio: its native /api/v1 (or /api/v0) model list without embedding
# models, falling back to the OpenAI-compatible /v1/models.
# Exit status: 1 unreachable, 3 answered but not parseable.
server_models() {
  local url="$1" body path
  if [[ "$(server_kind "$url")" == ollama ]]; then
    body="$(server_curl "$url" /api/tags 2>/dev/null)" || return 1
  elif is_openai_kind "$(server_kind "$url")"; then
    body="$(server_curl "$url" /v1/models 2>/dev/null)" || return 1
  else
    for path in /api/v1/models /api/v0/models /v1/models; do
      body="$(server_curl "$url" "$path" 2>/dev/null)" && break
    done
    [[ -n "$body" ]] || return 1
  fi
  printf '%s' "$body" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    entries = data.get("models") or data.get("data") or []
except Exception:
    sys.exit(3)
for entry in entries:
    if not isinstance(entry, dict):
        continue
    if entry.get("type") in ("embedding", "embeddings"):
        continue
    name = entry.get("name") or entry.get("key") or entry.get("id") or ""
    if name:
        print(name)
'
}

model_present_on() {
  local url="$1" tag="$2" names
  names="$(server_models "$url")" || return 2
  [[ -n "$names" ]] || return 2
  printf '%s\n' "$names" | grep -Fxq "$tag" && return 0
  # Ollama treats a bare name as ":latest", so accept that spelling too.
  if [[ "$(server_kind "$url")" == ollama && "$tag" != *:* ]]; then
    printf '%s\n' "$names" | grep -Fxq "${tag}:latest" && return 0
  fi
  return 1
}

# The ollama tag configured for one specific (model_name, api_base) deployment.
# Deployments are per (tier, server), so each pair can carry its own model.
current_pair_tag() {
  local want_name="$1" want_base="$2"
  [[ -f "$LITELLM_YAML" ]] || return 0
  awk -v want="$want_name" -v base="$(litellm_api_base "$want_base")" '
    /^[[:space:]]*-[[:space:]]*model_name:/ {
      n = $0; sub(/.*model_name:[[:space:]]*/, "", n); sub(/[[:space:]]*$/, "", n)
      tag = ""; next
    }
    /^[[:space:]]*model:[[:space:]]*(ollama|lm_studio|openai)\// {
      tag = $0; sub(/.*model:[[:space:]]*(ollama|lm_studio|openai)\//, "", tag); sub(/[[:space:]]*(#.*)?$/, "", tag); next
    }
    /^[[:space:]]*api_base:[[:space:]]*/ {
      b = $0; sub(/.*api_base:[[:space:]]*/, "", b); sub(/[[:space:]]*$/, "", b)
      if (n == want && b == base && tag != "") { print tag; exit }
    }' "$LITELLM_YAML"
}

# The ollama tag currently configured for a LiteLLM model_name (first match).
current_tier_tag() {
  local want="$1"
  [[ -f "$LITELLM_YAML" ]] || return 0
  awk -v want="$want" '
    /^[[:space:]]*-[[:space:]]*model_name:/ {
      n=$0; sub(/.*model_name:[[:space:]]*/,"",n); sub(/[[:space:]]*$/,"",n); next
    }
    /^[[:space:]]*model:[[:space:]]*(ollama|lm_studio|openai)\// && n==want {
      t=$0; sub(/.*model:[[:space:]]*(ollama|lm_studio|openai)\//,"",t); sub(/[[:space:]]*(#.*)?$/,"",t); print t; exit
    }' "$LITELLM_YAML"
}

# --- rendering ----------------------------------------------------------------
tiers_of() {  # which tiers reference this URL
  local url="$1" tier out=""
  for tier in fast medium large xlarge; do
    if get_tier "$tier" | contains_line "$url"; then
      out="${out}${out:+,}${tier}"
    fi
  done
  printf '%s' "${out:-—}"
}

cmd_list() {
  local probe="${1:-false}" i=0 url count
  echo "Configured model servers (${ENV_FILE}):"
  printf '  %-3s %-34s %-18s' "#" "ADDRESS" "TIERS"
  $probe && printf ' %-8s' "MODELS"
  echo
  while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -n "$url" ]] || continue
    i=$((i + 1))
    printf '  %-3s %-34s %-18s' "$i" "$url" "$(tiers_of "$url")"
    if $probe; then
      count="$(probe_server "$url")"
      if [[ "$count" == "-" ]]; then printf ' %-8s' "DOWN"; else printf ' %-8s' "$count"; fi
    fi
    echo
  done < <(get_servers)
  (( i == 0 )) && echo "  (none configured)"
  echo
  local ka; ka="$(env_get OLLAMA_KEEP_ALIVE)"
  # No apostrophe inside the ${...:-default}: bash re-parses that word and a
  # lone quote there opens a quote context, breaking everything after it.
  echo "Keep-alive: ${ka:-<server default (OLLAMA_KEEP_ALIVE on each host)>}"
  echo
  # One row per (tier, server) deployment, because each pair can carry its own
  # model — a single MODEL column per tier would hide that.
  echo "Tier assignments (one row per server):"
  printf '  %-7s %-14s %-34s %s\n' "TIER" "ALIAS" "SERVER" "MODEL"
  local tier alias tag url any
  for tier in fast medium large xlarge; do
    alias="$(tier_model_name "$tier")"
    any=false
    while IFS= read -r url || [[ -n "$url" ]]; do
      [[ -n "$url" ]] || continue
      any=true
      tag="$(current_pair_tag "$alias" "$url")"
      [[ -n "$tag" ]] || tag="$(current_tier_tag "$alias")"
      printf '  %-7s %-14s %-34s %s\n' "$tier" "$alias" "$url" "$(litellm_provider "$url")/${tag:-?}"
    done < <(get_tier "$tier")
    $any || printf '  %-7s %-14s %-34s %s\n' "$tier" "$alias" "<no servers>" "-"
  done
}

cmd_discover() {
  local body rc=0
  echo "Asking the router to re-poll every configured host..."
  local key; key="$(env_get ROUTER_API_KEY)"
  if [[ -n "$key" ]]; then
    # Header read from a file descriptor, so the key never shows up in `ps`.
    body="$(curl -fsS -X POST -H @<(printf 'Authorization: Bearer %s\n' "$key") \
            "${ROUTER_URL}/routing/refresh" 2>/dev/null)" || rc=$?
  else
    body="$(curl -fsS -X POST "${ROUTER_URL}/routing/refresh" 2>/dev/null)" || rc=$?
  fi
  if (( rc != 0 )) || [[ -z "$body" ]]; then
    note "Could not reach the router at ${ROUTER_URL} (curl exit ${rc})."
    note "  Check it is running:  systemctl status ollama-router"
    note "  Or point elsewhere:   ROUTER_URL=http://host:8000 $0 discover"
    return 1
  fi
  # NOTE: %-formatting, not f-strings. This code is embedded in a shell-quoted
  # string, and a quote inside an f-string expression cannot be escaped without
  # producing invalid Python.
  printf '%s' "$body" | python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
except Exception as exc:
    print("  the router replied, but the response did not parse: %s" % exc)
    raise SystemExit(1)

status = data.get("server_status") or {}
print("  polled %d host(s), inventory age %ss" % (len(status), data.get("age_seconds")))
for host in sorted(status):
    info = status[host] or {}
    state = "up" if info.get("up") else "DOWN"
    print("    %-34s %-5s models=%s" % (host, state, info.get("model_count", 0)))

errors = data.get("errors") or {}
for host in sorted(errors):
    print("    ! %s: %s" % (host, str(errors[host])[:70]))

models = data.get("models") or []
if models:
    print("  live inventory:")
    for entry in sorted(models, key=lambda m: (m.get("server", ""), m.get("name", ""))):
        flags = ",".join(
            label for label, on in (
                ("code", entry.get("is_code")),
                ("vision", entry.get("is_vision")),
                ("embed", entry.get("is_embedding")),
            ) if on
        )
        print("    %-34s %-24s %6sB %s" % (
            entry.get("server", ""), entry.get("name", ""),
            entry.get("params_b", 0), flags))
else:
    print("  (no models discovered — are the hosts reachable from the container?)")
'
}

# --- mutations ----------------------------------------------------------------
# Print a `  fallbacks:` block for router_settings. Input on stdin, one tier
# per line in size order: "<model_name> <signature>", where the signature is
# the sorted list of its deployments (tag@url). Each tier falls back to the
# nearest other tiers, smaller first on a tie. A tier whose deployments are
# IDENTICAL to this one's is skipped: falling back to the same model on the
# same host cannot succeed where the original failed.
litellm_fallbacks() {
  python3 -c '
import json, sys
tiers = []
for line in sys.stdin.read().splitlines():
    if line.strip():
        name, _, sig = line.partition(" ")
        tiers.append((name, sig))
rows = []
for i, (name, sig) in enumerate(tiers):
    others = [(abs(i - j), j, other) for j, (other, osig) in enumerate(tiers)
              if other != name and osig != sig]
    if others:
        rows.append("    - %s: %s" % (name, json.dumps([o for _, _, o in sorted(others)])))
if rows:
    print("  fallbacks:")
    print("\n".join(rows))
'
}

regenerate_litellm() {
  local tmp tier name tag tier_tag url tail_block keep_alive fallbacks sig
  local -a sig_lines=()
  local kind key_env k
  local -A kind_has_token=()
  keep_alive="$(env_get OLLAMA_KEEP_ALIVE)"
  for k in $(server_kinds); do
    [[ -n "$(env_get "$(kind_field "$k" key)")" ]] && kind_has_token[$k]=1
  done
  $DRY_RUN && { echo "  [dry-run] would regenerate ${LITELLM_YAML}"; return 0; }
  [[ -f "$LITELLM_YAML" ]] || die "missing ${LITELLM_YAML}"
  tmp="$(mktemp)"
  {
    echo "model_list:"
    for tier in fast medium large xlarge; do
      name="$(tier_model_name "$tier")"
      tier_tag="${TIER_MODEL_OVERRIDE[$tier]:-}"
      [[ -n "$tier_tag" ]] || tier_tag="$(current_tier_tag "$name")"
      [[ -n "$tier_tag" ]] || tier_tag="$name"
      sig=""
      while IFS= read -r url || [[ -n "$url" ]]; do
        [[ -n "$url" ]] || continue
        # Resolve the model for THIS (tier, server) pair, most specific first:
        #   1. an explicit set-server-model for this pair
        #   2. an explicit set-model for the whole tier
        #   3. whatever this exact pair already had  <- without this, a server
        #      with its own model would be silently overwritten by the tier's
        #      first tag on the next add/remove
        #   4. the tier tag
        tag="${PAIR_MODEL_OVERRIDE[${tier}|${url}]:-}"
        if [[ -z "$tag" && -z "${TIER_MODEL_OVERRIDE[$tier]:-}" ]]; then
          tag="$(current_pair_tag "$name" "$url")"
        fi
        [[ -n "$tag" ]] || tag="$tier_tag"
        printf '  - model_name: %s\n' "$name"
        printf '    litellm_params:\n'
        printf '      model: %s/%s\n' "$(litellm_provider "$url")" "$tag"
        printf '      api_base: %s\n' "$(litellm_api_base "$url")"
        kind="$(server_kind "$url")"
        if [[ "$kind" == ollama ]]; then
          [[ -n "$keep_alive" ]] && printf '      keep_alive: %s\n' "$keep_alive"
        else
          # Tokens come from secrets.env, which the LiteLLM unit loads.
          # keep_alive is an Ollama setting and is never sent elsewhere.
          key_env="$(kind_field "$kind" key)"
          if [[ -n "${kind_has_token[$kind]:-}" ]]; then
            printf '      api_key: os.environ/%s\n' "$key_env"
          elif is_openai_kind "$kind"; then
            # LiteLLM's openai provider needs some key even for a keyless server.
            printf '      api_key: none\n'
          fi
        fi
        sig+="${tag}@${url} "
      done < <(get_tier "$tier")
      if [[ -n "$sig" ]]; then
        sig_lines+=("${name} $(tr ' ' '\n' <<< "$sig" | sed '/^$/d' | sort | paste -sd, -)")
      fi
    done
    # router_settings: every hand-edited key (strategy, retries, ...) is kept,
    # but `fallbacks` is REGENERATED from the tiers that exist now. Carrying it
    # verbatim left fallbacks pointing at renamed or removed tiers.
    fallbacks="$( ((${#sig_lines[@]})) && printf '%s\n' "${sig_lines[@]}" | litellm_fallbacks)"
    tail_block="$(awk '/^router_settings:/{f=1} f' "$LITELLM_YAML")"
    [[ -n "$tail_block" ]] || tail_block=$'router_settings:\n  routing_strategy: latency-based-routing\n  num_retries: 2\n  timeout: 600'
    printf '%s\n' "$tail_block" | FALLBACKS="$fallbacks" awk '
      /^router_settings:/ { print; if (ENVIRON["FALLBACKS"] != "") print ENVIRON["FALLBACKS"]; next }
      skip && ($0 ~ /^   / || $0 ~ /^  -/) { next }
      { skip = 0 }
      /^  fallbacks:/ { skip = 1; next }
      { print }'
  } > "$tmp"
  cat "$tmp" > "$LITELLM_YAML"
  rm -f "$tmp"
  echo "  regenerated $(basename "$LITELLM_YAML")"
  CHANGED=true
}

confirm() {
  $ASSUME_YES && return 0
  $DRY_RUN && return 0
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

cmd_add() {
  local -a wanted=("$@")
  local addr url current count tier kind
  (( ${#wanted[@]} > 0 )) || die "add: no address given"
  current="$(get_servers | lines_to_csv)"
  count="$(get_servers | grep -c . || true)"

  local -a to_add=()
  for addr in "${wanted[@]}"; do
    valid_addr "$addr" || die "not a valid address: '${addr}'"
    if ! url="$(resolve_server "$addr")"; then
      die "${addr} is not reachable as $(kind_labels). Use --type and/or --no-probe to add anyway."
    fi
    kind="$(server_kind "$url")"
    [[ "$kind" == ollama ]] || note "  ${addr}: $(kind_field "$kind" label) server -> ${url}"
    if get_servers | contains_line "$url"; then
      note "  already configured, skipping: ${url}"
      continue
    fi
    if printf '%s\n' "${to_add[@]:-}" | contains_line "$url"; then
      note "  duplicate in arguments, skipping: ${url}"
      continue
    fi
    if ! $NO_PROBE; then
      if [[ "$(probe_server "$url")" == "-" ]]; then
        if [[ "$kind" != ollama ]]; then
          die "${url} did not list its models. Is the $(kind_field "$kind" label) server running? If it requires authentication, run set-${kind}-token first. Use --no-probe to add anyway."
        fi
        die "${url} is not reachable (no /api/tags). Use --no-probe to add anyway."
      fi
    fi
    to_add+=("$url")
  done
  (( ${#to_add[@]} > 0 )) || { note "Nothing to add."; return 0; }

  if (( count + ${#to_add[@]} > MODEL_SERVER_MAX )); then
    die "that would make $(( count + ${#to_add[@]} )) servers; the maximum is ${MODEL_SERVER_MAX}."
  fi

  echo "Adding:"
  printf '  + %s\n' "${to_add[@]}"
  confirm "Apply this change?" || { note "Aborted."; return 1; }

  local new_list="$current"
  for url in "${to_add[@]}"; do
    new_list="${new_list}${new_list:+,}${url}"
  done
  env_set MODEL_SERVERS "$new_list"

  if [[ -n "${TIER_ARG:-}" ]]; then
    for tier in $(csv_to_lines "$TIER_ARG"); do
      local key existing
      key="$(tier_env_key "$tier")" || exit 1
      existing="$(get_tier "$tier" | lines_to_csv)"
      for url in "${to_add[@]}"; do
        existing="${existing}${existing:+,}${url}"
      done
      env_set "$key" "$existing"
      echo "  assigned to tier '${tier}'"
    done
    # Model names differ between Ollama and LM Studio (qwen3:14b vs
    # qwen/qwen3-14b), so the tier's tag is often wrong for a new LM Studio
    # server. Say so now rather than at the first failed request.
    local tag
    for url in "${to_add[@]}"; do
      [[ "$(server_kind "$url")" != ollama ]] || continue
      for tier in $(csv_to_lines "$TIER_ARG"); do
        tag="$(current_tier_tag "$(tier_model_name "$tier")")"
        [[ -n "$tag" ]] || continue
        if ! $NO_PROBE && ! model_present_on "$url" "$tag"; then
          note "  NOTE: ${url} has no model '${tag}' (tier ${tier}). Pick one it serves:"
          note "        $0 models"
          note "        $0 set-server-model ${tier} ${url} <model>"
        fi
      done
    done
  else
    note "  NOTE: not assigned to any tier. Discovery will still poll and can"
    note "        select it, but LiteLLM's static path will not use it."
  fi
  regenerate_litellm
}

cmd_remove() {
  local -a wanted=("$@")
  local addr url target remaining tier key kept
  (( ${#wanted[@]} > 0 )) || die "remove: no address given"

  local -a to_remove=()
  for addr in "${wanted[@]}"; do
    # Accept a list number as shown by 'list'.
    if [[ "$addr" =~ ^[0-9]+$ ]]; then
      target="$(get_servers | sed -n "${addr}p")"
      [[ -n "$target" ]] || die "no server number ${addr} in the list"
    else
      valid_addr "$addr" || die "not a valid address: '${addr}'"
      target="$(configured_entry "$addr")"
    fi
    if ! get_servers | contains_line "$target"; then
      note "  not configured, skipping: ${target}"
      continue
    fi
    to_remove+=("$target")
  done
  (( ${#to_remove[@]} > 0 )) || { note "Nothing to remove."; return 0; }

  local count remaining_count
  count="$(get_servers | grep -c . || true)"
  remaining_count=$(( count - ${#to_remove[@]} ))
  if (( remaining_count < MODEL_SERVER_MIN )); then
    die "that would leave ${remaining_count} servers; at least ${MODEL_SERVER_MIN} is required."
  fi

  echo "Removing:"
  printf '  - %s\n' "${to_remove[@]}"
  confirm "Apply this change?" || { note "Aborted."; return 1; }

  remaining="$(get_servers | grep -vxF -f <(printf '%s\n' "${to_remove[@]}") | lines_to_csv)"
  env_set MODEL_SERVERS "$remaining"

  for tier in fast medium large xlarge; do
    key="$(tier_env_key "$tier")" || exit 1
    kept="$(get_tier "$tier" | grep -vxF -f <(printf '%s\n' "${to_remove[@]}") | lines_to_csv || true)"
    if [[ "$kept" != "$(get_tier "$tier" | lines_to_csv)" ]]; then
      env_set "$key" "$kept"
      [[ -z "$kept" ]] && note "  WARNING: tier '${tier}' now has no servers on the LiteLLM path."
    fi
  done
  regenerate_litellm
}

cmd_set_tier() {
  local tier="${1:-}"; shift || true
  local -a wanted=("$@")
  local addr url key list
  [[ -n "$tier" ]] || die "set-tier: no tier given"
  key="$(tier_env_key "$tier")" || exit 1
  (( ${#wanted[@]} > 0 )) || die "set-tier: no servers given"

  list=""
  for addr in "${wanted[@]}"; do
    if [[ "$addr" =~ ^[0-9]+$ ]]; then
      url="$(get_servers | sed -n "${addr}p")"
      [[ -n "$url" ]] || die "no server number ${addr} in the list"
    else
      valid_addr "$addr" || die "not a valid address: '${addr}'"
      url="$(configured_entry "$addr")"
    fi
    get_servers | contains_line "$url" || die "${url} is not a configured server; add it first."
    list="${list}${list:+,}${url}"
  done

  echo "Setting tier '${tier}' to:"
  printf '  %s\n' "$list"
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  env_set "$key" "$list"
  regenerate_litellm
}

valid_keep_alive() {
  [[ -z "$1" ]] && return 0
  [[ "$1" == "-1" || "$1" == "0" ]] && return 0
  [[ "$1" =~ ^[0-9]+$ ]] && return 0
  [[ "$1" =~ ^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$ ]]
}

# Resolve an address (or list number) to a configured server URL.
resolve_server_arg() {
  local arg="$1" url
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    url="$(get_servers | sed -n "${arg}p")"
    [[ -n "$url" ]] || die "no server number ${arg} in the list"
  else
    valid_addr "$arg" || die "not a valid address: '${arg}'"
    url="$(configured_entry "$arg")"
  fi
  get_servers | contains_line "$url" || die "${url} is not a configured server; add it first."
  printf '%s\n' "$url"
}

cmd_set_server_model() {
  local tier="${1:-}" server="${2:-}" tag="${3:-}"
  local url alias current rc=0
  [[ -n "$tier" ]]   || die "set-server-model: no tier given"
  tier_env_key "$tier" >/dev/null
  [[ -n "$server" ]] || die "set-server-model: no server given"
  [[ -n "$tag" ]]    || die "set-server-model: no model given (e.g. qwen3:32b)"
  # Namespace slashes belong to the model name; only the provider prefix is forbidden.
  [[ "$tag" != ollama/* ]] || die "give the Ollama tag only, without the 'ollama/' prefix"

  url="$(resolve_server_arg "$server")"
  get_tier "$tier" | contains_line "$url" \
    || die "${url} is not in tier '${tier}'. Add it with: $0 set-tier ${tier} ... "

  alias="$(tier_model_name "$tier")"
  current="$(current_pair_tag "$alias" "$url")"
  [[ -n "$current" ]] || current="$(current_tier_tag "$alias")"
  if [[ "$current" == "$tag" ]]; then
    note "${url} already serves '${tag}' for tier '${tier}'. Nothing to do."
    return 0
  fi

  if ! $NO_PROBE; then
    rc=0; model_present_on "$url" "$tag" || rc=$?
    case "$rc" in
      1) note "  '${tag}' is not present on ${url}."
         note "  Pull it there (ollama pull ${tag}), see '$0 models', or use --no-probe."
         die "model '${tag}' is not available on ${url}" ;;
      2) note "  WARNING: ${url} is unreachable; cannot verify '${tag}' is present." ;;
    esac
  fi

  echo "Tier '${tier}' on ${url}:"
  echo "  ollama/${current:-<unset>}  ->  ollama/${tag}"
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  PAIR_MODEL_OVERRIDE["${tier}|${url}"]="$tag"
  regenerate_litellm
}

# --- Open WebUI version -------------------------------------------------------
openwebui_current_version() {
  [[ -f "$OPENWEBUI_REQ" ]] || return 0
  awk -F'==' '/^[[:space:]]*open-webui[[:space:]]*==/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' \
    "$OPENWEBUI_REQ"
}

openwebui_installed_version() {
  local py="${OPENWEBUI_DIR}/venv/bin/python"
  [[ -x "$py" ]] || return 0
  "$py" -c 'import importlib.metadata as m
try: print(m.version("open-webui"))
except Exception: pass' 2>/dev/null
}

# Ask PyPI for the newest release and the Requires-Python of a given version.
# Prints "<latest>\t<requires_python_for_requested>" (blank field when unknown).
pypi_openwebui_info() {
  local want="${1:-}"
  python3 - "$want" <<'PYEOF' 2>/dev/null
import json, re, sys, urllib.request

want = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    with urllib.request.urlopen("https://pypi.org/pypi/open-webui/json", timeout=20) as r:
        data = json.load(r)
except Exception:
    sys.exit(1)

def sort_key(v):
    return [int(x) for x in re.findall(r"\d+", v)[:3]] or [0]

stable = [v for v in data.get("releases", {}) if not re.search(r"(dev|rc|a\d|b\d)", v)]
stable.sort(key=sort_key)
latest = data.get("info", {}).get("version", stable[-1] if stable else "")

target = want if want and want != "latest" else latest
files = data.get("releases", {}).get(target) or []
requires = files[0].get("requires_python") if files else None
if not files:
    requires = ""          # version does not exist
    target = ""
print("%s\t%s\t%s" % (latest, target, requires or ""))
PYEOF
}

# Does the Open WebUI venv's interpreter satisfy a Requires-Python spec?
openwebui_python_ok() {
  local spec="$1" py="${OPENWEBUI_DIR}/venv/bin/python"
  [[ -n "$spec" ]] || return 0          # nothing declared: nothing to check
  [[ -x "$py" ]] || return 0            # no venv yet (fresh install): skip
  "$py" - "$spec" <<'PYEOF' 2>/dev/null
import sys
spec = sys.argv[1]
version = ".".join(str(p) for p in sys.version_info[:3])
try:
    from pip._vendor.packaging.specifiers import SpecifierSet
    sys.exit(0 if SpecifierSet(spec).contains(version, prereleases=True) else 1)
except Exception:
    pass
# Fallback: compare only the >= lower bound and < upper bound on major.minor.
import re
cur = sys.version_info[:2]
for clause in spec.split(","):
    clause = clause.strip()
    m = re.match(r"^(>=|<=|<|>|==)\s*(\d+)\.(\d+)", clause)
    if not m:
        continue
    op, major, minor = m.group(1), int(m.group(2)), int(m.group(3))
    other = (major, minor)
    if op == ">=" and not cur >= other: sys.exit(1)
    if op == ">"  and not cur >  other: sys.exit(1)
    if op == "<=" and not cur <= other: sys.exit(1)
    if op == "<"  and not cur <  other: sys.exit(1)
sys.exit(0)
PYEOF
}

cmd_set_webui_version() {
  local want="${1:-}" info latest target requires current installed pyver

  current="$(openwebui_current_version)"
  installed="$(openwebui_installed_version)"
  pyver="$("${OPENWEBUI_DIR}/venv/bin/python" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo "?")"

  info="$(pypi_openwebui_info "$want")" || {
    note "Could not reach PyPI to check versions."
    [[ -n "$want" ]] || return 1
    info=$'\t'"${want}"$'\t'
  }
  latest="$(printf '%s' "$info" | cut -f1)"
  target="$(printf '%s' "$info" | cut -f2)"
  requires="$(printf '%s' "$info" | cut -f3)"

  if [[ -z "$want" ]]; then
    echo "Open WebUI version:"
    printf '  pinned in repo : %s\n' "${current:-<none>}"
    printf '  installed now  : %s\n' "${installed:-<unknown>}"
    printf '  latest on PyPI : %s\n' "${latest:-<unknown>}"
    printf '  venv python    : %s\n' "$pyver"
    echo
    echo "Change it with:  $0 set-webui-version <version|latest> --apply"
    return 0
  fi

  [[ -n "$target" ]] || die "open-webui ${want} does not exist on PyPI"
  if [[ "$target" == "$current" ]]; then
    note "Already pinned to ${target}. Nothing to do."
    return 0
  fi

  # The whole dual-interpreter design exists because of this constraint, so
  # check it before writing anything rather than failing during pip install.
  if ! openwebui_python_ok "$requires"; then
    note "  open-webui ${target} requires Python '${requires}',"
    note "  but the Open WebUI venv is Python ${pyver}."
    note "  Rebuild that venv with a compatible interpreter first, or pick"
    note "  another version:  $0 set-webui-version <version>"
    die "incompatible Python for open-webui ${target}"
  fi

  echo "Open WebUI: ${current:-<none>}  ->  ${target}"
  [[ -n "$requires" ]] && echo "  requires Python ${requires} (venv is ${pyver})"
  [[ "$target" != "$latest" ]] && note "  note: ${latest} is the latest release."
  confirm "Apply this change?" || { note "Aborted."; return 1; }

  if $DRY_RUN; then
    echo "  [dry-run] would pin open-webui==${target} in ${OPENWEBUI_REQ}"
  else
    printf 'open-webui==%s\n' "$target" > "$OPENWEBUI_REQ"
    echo "  pinned open-webui==${target}"
  fi
  CHANGED=true
  note "  The new version is installed when you apply:  $0 apply"
  note "  (that step downloads a large dependency tree and takes a while)"
}

cmd_set_keepalive() {
  local value="${1-}" current
  valid_keep_alive "$value" || die "not a valid keep-alive: '${value}' (try 30m, 2h, -1, or blank)"
  current="$(env_get OLLAMA_KEEP_ALIVE)"
  if [[ "$current" == "$value" ]]; then
    note "Keep-alive is already '${value:-<server default>}'. Nothing to do."
    return 0
  fi
  echo "Keep-alive: ${current:-<server default>}  ->  ${value:-<server default>}"
  if [[ -z "$value" ]]; then
    note "  Blank: nothing will be sent, so each server's own OLLAMA_KEEP_ALIVE applies"
    note "  and the monitor's keep-alive maintainer switches off."
  fi
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  env_set OLLAMA_KEEP_ALIVE "$value"
  regenerate_litellm
  note "  NOTE: Ollama's OpenAI-compatible endpoint ignores keep_alive, so models"
  note "        served through the router are kept resident by the monitor, which"
  note "        re-pins them through the native API. Restart it to pick this up."
  note "        LM Studio servers are not affected: LM Studio loads models on demand"
  note "        and unloads them on its own idle TTL (set that in LM Studio)."
}

cmd_models() {
  local url count=0 tmp
  tmp="$(mktemp)"
  while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -n "$url" ]] || continue
    count=$((count + 1))
    if ! server_models "$url" | sed "s|\$|\t${url}|" >> "$tmp"; then
      note "  (unreachable: ${url})"
    fi
  done < <(get_servers)
  echo "Models available across ${count} configured host(s):"
  if [[ ! -s "$tmp" ]]; then
    echo "  (none — no host listed its models)"
    rm -f "$tmp"; return 0
  fi
  printf '  %-30s %s\n' "MODEL" "HOSTS"
  sort "$tmp" | awk -F'\t' '
    { if ($1 != prev) { if (prev != "") printf "  %-30s %s\n", prev, hosts
                        prev=$1; hosts=$2 }
      else hosts = hosts ", " $2 }
    END { if (prev != "") printf "  %-30s %s\n", prev, hosts }'
  rm -f "$tmp"
  echo
  echo "Set one for a tier with:  $0 set-model <fast|medium|large|xlarge> <model>"
}

cmd_set_model() {
  local tier="${1:-}" tag="${2:-}"
  local url current alias missing="" unreachable="" rc
  [[ -n "$tier" ]] || die "set-model: no tier given"
  tier_env_key "$tier" >/dev/null          # validates the tier name
  [[ -n "$tag" ]] || die "set-model: no model given (e.g. qwen3:32b)"
  # Namespace slashes belong to the model name; only the provider prefix is forbidden.
  [[ "$tag" != ollama/* ]] || die "give the Ollama tag only, without the 'ollama/' prefix"

  alias="$(tier_model_name "$tier")"
  current="$(current_tier_tag "$alias")"
  if [[ "$current" == "$tag" ]]; then
    note "Tier '${tier}' already serves '${tag}'. Nothing to do."
    return 0
  fi

  local -a servers=()
  while IFS= read -r url || [[ -n "$url" ]]; do
    [[ -n "$url" ]] && servers+=("$url")
  done < <(get_tier "$tier")
  if (( ${#servers[@]} == 0 )); then
    note "  WARNING: tier '${tier}' has no servers assigned; setting the tag anyway."
  fi

  # Verify the tag actually exists on the hosts that will be asked to serve it.
  if ! $NO_PROBE && (( ${#servers[@]} > 0 )); then
    for url in "${servers[@]}"; do
      rc=0; model_present_on "$url" "$tag" || rc=$?
      case "$rc" in
        1) missing="${missing}${missing:+, }${url}" ;;
        2) unreachable="${unreachable}${unreachable:+, }${url}" ;;
      esac
    done
    [[ -n "$unreachable" ]] && note "  WARNING: could not check ${unreachable} (unreachable)."
    if [[ -n "$missing" ]]; then
      note "  '${tag}' is not present on: ${missing}"
      note "  Pull it there first (ollama pull ${tag}), pick another with '$0 models',"
      note "  or re-run with --no-probe to set it anyway."
      die "model '${tag}' is not available on every server in tier '${tier}'"
    fi
  fi

  echo "Tier '${tier}' (${alias}) — ALL servers in this tier:"
  echo "  ollama/${current:-<unset>}  ->  ollama/${tag}"
  local n_servers
  n_servers="$(get_tier "$tier" | grep -c . || true)"
  if (( n_servers > 1 )); then
    note "  This overwrites the model on all ${n_servers} servers in the tier."
    note "  Use set-server-model to change just one."
  fi
  confirm "Apply this change?" || { note "Aborted."; return 1; }
  TIER_MODEL_OVERRIDE["$tier"]="$tag"
  regenerate_litellm
  note "  NOTE: the tier's model tag governs the LiteLLM fallback path. In"
  note "        discovery mode the router picks a model from the live inventory,"
  note "        so this does not by itself change discovery-mode routing."
}

# Install the pinned Open WebUI into its venv, CPU-only by default.
#
# This container never has a GPU, so the CUDA build of torch is ~4.5 GB of
# wheels that can never be used. Installing CPU-only torch FIRST leaves pip with
# its torch requirement already satisfied, so the CUDA stack is never pulled.
openwebui_install() {
  local pip="${OPENWEBUI_DIR}/venv/bin/pip"
  local cpu_only orphans
  [[ -x "$pip" ]] || { note "  no Open WebUI venv at ${OPENWEBUI_DIR}/venv"; return 1; }

  cpu_only="$(env_get TORCH_CPU_ONLY)"
  [[ -n "$cpu_only" ]] || cpu_only="true"

  if [[ "$cpu_only" == "true" ]]; then
    echo "  installing CPU-only torch first (no GPU in this container)..."
    # Deliberately the FIRST step: if the CPU index is unreachable this fails
    # while the venv is still intact, rather than after uninstalling anything.
    if "$pip" install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch; then
      # Any nvidia-*/triton wheels left from an earlier CUDA install are now
      # orphans. Removing them is what actually reclaims the disk.
      orphans="$("$pip" list --format=freeze 2>/dev/null |
                 sed 's/==.*//' | grep -E '^(nvidia-|triton$)' || true)"
      if [[ -n "$orphans" ]]; then
        echo "  removing orphaned CUDA packages:"
        printf '    %s\n' $orphans
        # shellcheck disable=SC2086
        "$pip" uninstall -y $orphans >/dev/null 2>&1 || \
          note "    (some could not be removed; harmless, just disk)"
      fi
    else
      note "  WARNING: CPU-only torch install failed — is download.pytorch.org"
      note "           reachable from this container? Continuing with the"
      note "           default build, which pulls ~4.5 GB of unusable CUDA wheels."
    fi
  fi

  "$pip" install --no-cache-dir -r "$OPENWEBUI_REQ"
}

# --- LiteLLM venv ---------------------------------------------------------------
litellm_pinned_version() {
  [[ -f "$LITELLM_REQ" ]] || return 0
  sed -nE 's/^[[:space:]]*litellm(\[[^]]*\])?[[:space:]]*==[[:space:]]*([^[:space:];#]+).*/\2/p' \
    "$LITELLM_REQ" | head -n1
}

litellm_installed_version() {
  local py="${LITELLM_DIR}/venv/bin/python"
  [[ -x "$py" ]] || return 0
  "$py" -c 'import importlib.metadata as m
try: print(m.version("litellm"))
except Exception: pass' 2>/dev/null
}

# True when the venv has the pinned litellm AND the proxy extra's imports work.
# The import is the real test: a plain `litellm` install passes a version check
# but `litellm --config` then dies with "Missing dependency ... backoff".
litellm_venv_ok() {
  local want have
  want="$(litellm_pinned_version)"
  have="$(litellm_installed_version)"
  [[ -n "$have" ]] || return 1
  [[ -z "$want" || "$want" == "$have" ]] || return 1
  "${LITELLM_DIR}/venv/bin/python" -c 'import litellm.proxy.proxy_server' >/dev/null 2>&1
}

# Build (or bring up to date) LiteLLM's own venv, hash-checked when the repo
# carries requirements.lock.
litellm_install() {
  local pip="${LITELLM_DIR}/venv/bin/pip" rc=0
  # The service runs as ollama-router from this root-owned tree: build it world-
  # readable whatever the calling shell's umask (a 077/027 umask here produced
  # "Failed to execute .../litellm: Permission denied", status=203/EXEC).
  (
    umask 022
    if [[ ! -x "$pip" ]]; then
      mkdir -p "$LITELLM_DIR"
      python3 -m venv "${LITELLM_DIR}/venv" || { note "  could not create ${LITELLM_DIR}/venv"; exit 1; }
    fi
    if [[ -f "$LITELLM_LOCK" ]]; then
      "$pip" install --no-cache-dir --require-hashes -r "$LITELLM_LOCK"
    else
      note "  WARNING: no $(basename "$LITELLM_LOCK"); installing without hash checking."
      "$pip" install --no-cache-dir -r "$LITELLM_REQ"
    fi
  ) || rc=$?
  venv_make_readable "${LITELLM_DIR}/venv"
  return "$rc"
}

# Give everyone read (and traverse/execute where set) access to a venv, and let
# them traverse its parent. Venvs hold no secrets; the service accounts need this.
venv_make_readable() {
  local venv="$1"
  [[ -d "$venv" ]] || return 0
  chmod -R u+rwX,go+rX,go-w -- "$venv"
  chmod go+x -- "$(dirname -- "$venv")"
}

# The service account every unit runs as.
SERVICE_USER="${SERVICE_USER:-ollama-router}"

# Before restarting anything, make sure the service account can actually run
# each venv's interpreter; repair the permissions when a restrictive umask
# (on an earlier install, pip run or update) left them unreadable. Prints the
# venvs it fixed; returns 1 when one is still unusable.
repair_venv_access() {
  local venv bad=0
  getent passwd "$SERVICE_USER" >/dev/null 2>&1 || return 0
  command -v runuser >/dev/null 2>&1 || return 0
  for venv in "${LITELLM_DIR}/venv" "${ROUTER_DIR}/venv" "${OPENWEBUI_DIR}/venv"; do
    [[ -x "${venv}/bin/python" ]] || continue
    runuser -u "$SERVICE_USER" -- "${venv}/bin/python" -c 'import sys' >/dev/null 2>&1 && continue
    echo "  ${venv} is not usable by ${SERVICE_USER}; making it readable"
    venv_make_readable "$venv"
    if ! runuser -u "$SERVICE_USER" -- "${venv}/bin/python" -c 'import sys' >/dev/null 2>&1; then
      note "  WARNING: ${SERVICE_USER} still cannot run ${venv}/bin/python; check the permissions of its parent directories."
      bad=1
    fi
  done
  return "$bad"
}

# --- safe apply ---------------------------------------------------------------
# Validate every file apply-config.sh is about to install. Prints one line per
# problem; returns 1 if there was any. Nothing on the running system changes.
validate_config() {
  local py=python3
  # The YAML check needs PyYAML. Debian's python3 may lack it; LiteLLM's venv
  # always has it. (Without either, only a basic structural check runs.)
  if ! python3 -c 'import yaml' 2>/dev/null && [[ -x "${LITELLM_DIR}/venv/bin/python" ]]; then
    py="${LITELLM_DIR}/venv/bin/python"
  fi
  "$py" - "$REPO_DIR" <<'PYEOF'
import configparser, json, re, sys
from pathlib import Path

repo = Path(sys.argv[1])
errors = []
deployments = {}   # model_name -> {(model, api_base)}

def err(path, message):
    errors.append("%s: %s" % (path, message))

# env files: KEY=value lines only (systemd EnvironmentFile syntax).
for rel in ("env/router.env", "env/openwebui.env"):
    path = repo / rel
    if not path.is_file():
        err(rel, "missing")
        continue
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if line.strip() and not line.lstrip().startswith("#") \
                and not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", line):
            err(rel, "line %d is not KEY=value: %r" % (number, line[:60]))

# Python services must at least compile.
for rel in ("services/ollama-router/router.py", "services/ollama-monitor/monitor.py"):
    try:
        compile((repo / rel).read_text(), rel, "exec")
    except (OSError, SyntaxError) as exc:
        err(rel, "does not compile: %s" % exc)

# router.ini
rel = "services/ollama-router/router.ini"
cp = configparser.ConfigParser()
try:
    cp.read(repo / rel)
    for option in ("code", "large", "xlarge"):
        if cp.has_option("keywords", option):
            value = json.loads(cp.get("keywords", option))
            if not isinstance(value, list):
                err(rel, "[keywords] %s must be a JSON array" % option)
                continue
            for entry in value:
                if str(entry).startswith("re:"):
                    try:
                        re.compile(str(entry)[3:])
                    except re.error as exc:
                        err(rel, "[keywords] %s: bad regex %r (%s)" % (option, entry, exc))
    for option in ("xlarge", "large", "medium"):
        if cp.has_option("thresholds", option):
            int(cp.get("thresholds", option))
    for option in ("fast_params", "medium_params", "large_params", "xlarge_params"):
        if cp.has_option("discovery", option):
            low, high = cp.get("discovery", option).split(":", 1)
            if float(low) > float(high):
                err(rel, "[discovery] %s has low > high" % option)
except (configparser.Error, ValueError) as exc:
    err(rel, str(exc))

# monitor.ini
rel = "services/ollama-monitor/monitor.ini"
cp = configparser.ConfigParser()
try:
    cp.read(repo / rel)
    for section, option in (("polling", "interval_seconds"), ("alerting", "fail_threshold"),
                            ("alerting", "recover_threshold")):
        if cp.has_option(section, option):
            int(cp.get(section, option))
except (configparser.Error, ValueError) as exc:
    err(rel, str(exc))

# litellm_config.yaml
rel = "services/litellm-proxy/litellm_config.yaml"
try:
    import yaml
except ImportError:
    yaml = None
text = (repo / rel).read_text() if (repo / rel).is_file() else None
if text is None:
    err(rel, "missing")
elif yaml is None:
    if not re.search(r"^model_list:", text, re.M):
        err(rel, "no model_list (PyYAML unavailable; only a basic check was possible)")
else:
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        err(rel, "is not valid YAML: %s" % str(exc).splitlines()[0])
        doc = None
    if doc is not None:
        names = set()
        models = doc.get("model_list") if isinstance(doc, dict) else None
        if not isinstance(models, list) or not models:
            err(rel, "model_list must be a non-empty list")
            models = []
        for index, item in enumerate(models):
            params = (item or {}).get("litellm_params") or {}
            if not (item or {}).get("model_name") or not params.get("model") \
                    or not params.get("api_base"):
                err(rel, "model_list[%d] needs model_name, litellm_params.model and api_base" % index)
            else:
                names.add(item["model_name"])
                deployments.setdefault(item["model_name"], set()).add(
                    (params["model"], params["api_base"]))
        settings = (doc.get("router_settings") or {}) if isinstance(doc, dict) else {}
        for entry in settings.get("fallbacks") or []:
            if not isinstance(entry, dict) or len(entry) != 1:
                err(rel, "each fallbacks entry must be {tier: [tiers]}")
                continue
            (source, targets), = entry.items()
            for name in [source] + list(targets or []):
                if name not in names:
                    err(rel, "fallback names %r, which has no deployment" % name)

if not errors:
    seen = {}
    for name, deps in sorted(deployments.items()):
        key = frozenset(deps)
        if key in seen:
            print("  note: tiers %r and %r serve the same model on the same host(s); "
                  "one of them adds nothing (not an error)" % (seen[key], name))
        else:
            seen[key] = name

for line in errors:
    print("  " + line)
sys.exit(1 if errors else 0)
PYEOF
}

# runtime path -> repo source, and the services that read it.
apply_map() {
  cat <<EOF
services/ollama-router/router.py|${ROUTER_DIR}/router.py|ollama-router
services/ollama-router/router.ini|${ROUTER_DIR}/router.ini|ollama-router
services/ollama-monitor/monitor.py|${ROUTER_DIR}/monitor.py|ollama-monitor
services/ollama-monitor/monitor.ini|${ROUTER_DIR}/monitor.ini|ollama-monitor
services/litellm-proxy/litellm_config.yaml|${ROUTER_DIR}/litellm_config.yaml|litellm-proxy
env/router.env|${ROUTER_DIR}/.env|litellm-proxy ollama-router ollama-monitor
env/openwebui.env|${OPENWEBUI_DIR}/.env|open-webui
services/litellm-proxy/litellm-proxy.service|${UNIT_DIR}/litellm-proxy.service|litellm-proxy
services/ollama-router/ollama-router.service|${UNIT_DIR}/ollama-router.service|ollama-router
services/ollama-monitor/ollama-monitor.service|${UNIT_DIR}/ollama-monitor.service|ollama-monitor
services/open-webui/open-webui.service|${UNIT_DIR}/open-webui.service|open-webui
EOF
}

# Fingerprint of the secrets file, recorded after each successful apply, so a
# set-token / set-webhook / set-api-key since then restarts the services that
# load it.
secrets_fingerprint() {
  if [[ -f "$SECRETS_FILE" ]]; then sha256sum < "$SECRETS_FILE" | cut -d' ' -f1; else echo none; fi
}

# Services that must restart for the pending apply, in SERVICES order: any
# whose files differ from what is installed, any that is not running, and the
# secret-loading ones when secrets.env changed. Run BEFORE apply-config.sh.
affected_services() {
  local src dest svcs svc
  local -A want=()
  if $APPLY_ALL; then printf '%s\n' "${SERVICES[@]}"; return 0; fi
  while IFS='|' read -r src dest svcs; do
    [[ -f "${REPO_DIR}/${src}" ]] || continue
    if ! cmp -s "${REPO_DIR}/${src}" "$dest"; then
      for svc in $svcs; do want[$svc]=1; done
    fi
  done < <(apply_map)
  if [[ "$(secrets_fingerprint)" != "$(cat "${ROUTER_DIR}/.secrets.applied" 2>/dev/null)" ]]; then
    want[ollama-router]=1; want[ollama-monitor]=1; want[open-webui]=1
  fi
  for svc in "${SERVICES[@]}"; do
    systemctl is-active --quiet "${svc}.service" 2>/dev/null || want[$svc]=1
  done
  for svc in "${SERVICES[@]}"; do
    [[ -n "${want[$svc]:-}" ]] && printf '%s\n' "$svc"
  done
  return 0
}

# Copy every runtime file apply-config.sh may overwrite into a new timestamped
# snapshot directory; print its path. Old snapshots beyond APPLY_BACKUP_KEEP
# are pruned.
snapshot_runtime() {
  local dir src dest svcs
  dir="${APPLY_BACKUP_DIR}/$(date +%Y%m%dT%H%M%S)-$$"
  mkdir -p "$dir" && chmod 0700 "$APPLY_BACKUP_DIR" "$dir"
  : > "${dir}/MANIFEST"
  while IFS='|' read -r src dest svcs; do
    [[ -f "$dest" ]] || continue
    mkdir -p "${dir}/files$(dirname "$dest")"
    cp -p "$dest" "${dir}/files${dest}"
    printf '%s\n' "$dest" >> "${dir}/MANIFEST"
  done < <(apply_map)
  # shellcheck disable=SC2012  # names are our own timestamps
  ls -1d "${APPLY_BACKUP_DIR}"/*/ 2>/dev/null | sort | head -n "-${APPLY_BACKUP_KEEP}" |
    while IFS= read -r old; do rm -rf -- "$old"; done
  printf '%s\n' "$dir"
}

# Put back every file recorded in a snapshot.
restore_runtime() {
  local dir="$1" dest
  [[ -f "${dir}/MANIFEST" ]] || { note "  snapshot ${dir} has no MANIFEST"; return 1; }
  while IFS= read -r dest; do
    [[ -n "$dest" ]] && cp -p "${dir}/files${dest}" "$dest"
  done < "${dir}/MANIFEST"
}

# The URL a service answers health checks on (empty: use systemd state only).
health_url() {
  local port
  case "$1" in
    litellm-proxy) printf '%s\n' "$LITELLM_HEALTH_URL" ;;
    ollama-router) printf '%s/healthz\n' "$ROUTER_URL" ;;
    open-webui)
      port="$(kv_get "${REPO_DIR}/env/openwebui.env" PORT)"
      printf 'http://127.0.0.1:%s/health\n' "${port:-8080}" ;;
    *) printf '\n' ;;
  esac
}

# Wait until a restarted service is active AND answers its health URL. A unit
# that systemd reports as failed is given up on at once. Returns 1 on timeout.
wait_healthy() {
  local svc="$1" limit="${2:-$HEALTH_TIMEOUT}" url waited=0 state
  url="$(health_url "$svc")"
  while (( waited < limit )); do
    state="$(systemctl is-active "${svc}.service" 2>/dev/null || true)"
    if [[ "$state" == failed ]]; then
      return 1
    fi
    if [[ "$state" == active ]]; then
      if [[ -z "$url" ]]; then
        # No HTTP health endpoint: require it to stay up for a few seconds.
        sleep 3
        systemctl is-active --quiet "${svc}.service" 2>/dev/null && return 0
        return 1
      fi
      curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null && return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# Restart the given services in order and health-check each. Prints the name
# of the first that fails and returns 1.
restart_and_check() {
  local svc limit
  for svc in "$@"; do
    systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 || continue
    if ! systemctl restart "${svc}.service" >/dev/null 2>&1; then
      printf '%s\n' "$svc"; return 1
    fi
    limit="$HEALTH_TIMEOUT"
    [[ "$svc" == open-webui ]] && limit="$OPENWEBUI_HEALTH_TIMEOUT"
    if wait_healthy "$svc" "$limit"; then
      echo "  restarted ${svc}: healthy" >&2
    else
      printf '%s\n' "$svc"; return 1
    fi
  done
}

# Open WebUI's data directory (its SQLite database lives there).
openwebui_data_dir() {
  local dir
  dir="$(kv_get "${REPO_DIR}/env/openwebui.env" DATA_DIR)"
  printf '%s\n' "${dir:-${OPENWEBUI_DIR}/data}"
}

# An Open WebUI upgrade migrates webui.db in place and cannot be undone by
# reinstalling the old version alone, so the database is copied into the apply
# snapshot first. (Uploads and the vector store are not copied: they are large
# and not rewritten by schema migrations.)
openwebui_backup_db() {
  local snap="$1" data f
  data="$(openwebui_data_dir)"
  mkdir -p "${snap}/openwebui-data"
  for f in "${data}"/webui.db "${data}"/webui.db-wal "${data}"/webui.db-shm; do
    [[ -f "$f" ]] && cp -p "$f" "${snap}/openwebui-data/"
  done
  return 0
}

openwebui_restore_db() {
  local snap="$1" data f
  data="$(openwebui_data_dir)"
  [[ -d "${snap}/openwebui-data" ]] || return 0
  rm -f "${data}/webui.db-wal" "${data}/webui.db-shm"
  for f in "${snap}"/openwebui-data/*; do
    [[ -f "$f" ]] && cp -p "$f" "${data}/"
  done
  return 0
}

cmd_apply() {
  local svc snapshot failed webui_from=""
  local -a affected=()
  if $DRY_RUN; then echo "  [dry-run] would apply config and restart services"; return 0; fi
  # Checked with -f, not -x: seeding through the Gitea contents API does not
  # preserve the executable bit, and we invoke it via `bash` anyway.
  [[ -f "$APPLY_SCRIPT" ]] || die "apply script not found: ${APPLY_SCRIPT}"
  migrate_secrets

  echo "Validating configuration..."
  if ! validate_config; then
    note "Configuration is invalid; nothing was applied or restarted."
    return 1
  fi

  mapfile -t affected < <(affected_services)
  snapshot="$(snapshot_runtime)"
  echo "Applying configuration (previous files saved in ${snapshot})..."
  bash "$APPLY_SCRIPT" "$REPO_DIR"

  # Older deployments ran LiteLLM from the router's venv without the [proxy]
  # extra, which crash-loops. Build its own venv before the unit is restarted.
  if ! litellm_venv_ok; then
    echo "LiteLLM venv missing or out of date; installing into ${LITELLM_DIR}/venv..."
    if litellm_install && litellm_venv_ok; then
      echo "  installed litellm $(litellm_installed_version)"
      affected+=(litellm-proxy)
    else
      note "  WARNING: LiteLLM install failed; litellm-proxy will not start."
    fi
  fi

  # If the pinned Open WebUI version no longer matches what is installed,
  # bring the venv in line before restarting the unit.
  local want_v have_v
  want_v="$(openwebui_current_version)"
  have_v="$(openwebui_installed_version)"
  if [[ -n "$want_v" && "$want_v" != "$have_v" ]]; then
    echo "Open WebUI ${have_v:-<none>} -> ${want_v}; installing (this takes a while)..."
    openwebui_backup_db "$snapshot"
    # umask 022: the UI runs as the service account from this root-owned venv.
    if ( umask 022; openwebui_install ); then
      echo "  installed open-webui ${want_v} (database backed up in ${snapshot})"
      webui_from="$have_v"
      affected+=(open-webui)
    else
      note "  WARNING: install failed; the service keeps running ${have_v:-its current version}."
    fi
  fi
  # A venv the service account cannot read fails at exec (status=203/EXEC).
  repair_venv_access || true
  # De-duplicate, keeping SERVICES order.
  mapfile -t affected < <(for svc in "${SERVICES[@]}"; do
    printf '%s\n' "${affected[@]}" | grep -qx -- "$svc" && echo "$svc"; done)

  # Files are already in place at this point. If systemd isn't running (a
  # chroot, a container without PID 1, a rescue shell), say so plainly rather
  # than dying with "Failed to connect to bus" after a partial job.
  if ! systemctl daemon-reload 2>/dev/null; then
    note "WARNING: systemd is not available here — configuration was copied into"
    note "         place, but no service was restarted. Restart them manually:"
    note "           systemctl restart ${SERVICES[*]}"
    return 0
  fi
  if (( ${#affected[@]} == 0 )); then
    echo "No service is affected by this change; nothing restarted."
    secrets_fingerprint > "${ROUTER_DIR}/.secrets.applied"
    return 0
  fi
  echo "Restarting: ${affected[*]}"
  if failed="$(restart_and_check "${affected[@]}")"; then
    secrets_fingerprint > "${ROUTER_DIR}/.secrets.applied"
    echo "Applied; all restarted services are healthy."
    return 0
  fi

  note "ERROR: ${failed} did not become healthy. Rolling back to the previous files..."
  note "  (see: journalctl -u ${failed} -n 50)"
  restore_runtime "$snapshot"
  if [[ -n "$webui_from" ]]; then
    note "  Reinstalling open-webui ${webui_from} and restoring its database..."
    systemctl stop open-webui.service 2>/dev/null || true
    ( umask 022; "${OPENWEBUI_DIR}/venv/bin/pip" install --no-cache-dir "open-webui==${webui_from}" ) >/dev/null 2>&1 || \
      note "  WARNING: reinstalling open-webui ${webui_from} failed."
    openwebui_restore_db "$snapshot"
  fi
  systemctl daemon-reload 2>/dev/null || true
  if restart_and_check "${affected[@]}" >/dev/null; then
    note "Rolled back; the previous configuration is running again."
  else
    note "Rolled back the files, but a service is still unhealthy — check it by hand."
  fi
  note "  The LiteLLM venv is not rolled back. The repo still holds the new config;"
  note "  fix it (or git revert) and run apply again."
  return 1
}

# Push using the Gitea deploy token from the secrets file.
#
# Gitea does not accept an account password for git-over-HTTP (it wants a token
# or an app password), and provisioning deliberately deletes the stored git
# credentials once the clone is done. Without this, git falls back to prompting
# for a username/password, which then fails against Gitea.
git_push_authenticated() {
  local remote branch token user host cred sslverify out rc=0 hostpart scheme
  remote="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null)" || remote=""
  if [[ -z "$remote" ]]; then
    note "  No 'origin' remote is configured; the commit stays local."
    return 1
  fi
  branch="$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || echo main)"

  # A non-HTTP remote (ssh) carries its own auth; just let git do its thing.
  if [[ "$remote" != http://* && "$remote" != https://* ]]; then
    if out="$(GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" push origin "HEAD:${branch}" 2>&1)"; then
      return 0
    fi
    note "  push failed: ${out}"
    return 1
  fi

  token="$(env_get GITEA_DEPLOY_TOKEN)"
  if [[ -z "$token" ]]; then
    note "  No GITEA_DEPLOY_TOKEN in ${SECRETS_FILE}."
    note "  Gitea needs a token for git over HTTP — an account password will be"
    note "  rejected. Store one with:  $0 set-token"
    return 1
  fi

  # Username: take it from the remote if it carries one, else the configured
  # Gitea user. Gitea accepts the token as the password for any valid user.
  hostpart="${remote#*://}"
  user="$(env_get GITEA_ADMIN_USER)"
  if [[ "$hostpart" == *@* ]]; then
    user="${hostpart%%@*}"
    hostpart="${hostpart#*@}"
  fi
  [[ -n "$user" ]] || user="git"
  host="${hostpart%%/*}"
  # The credential entry must carry the SAME scheme as the remote: git will not
  # match an https:// credential against an http:// request, and the push then
  # fails as if no credential existed at all.
  scheme="${remote%%://*}"

  sslverify="true"
  [[ "$(env_get GITEA_VERIFY_TLS)" == "true" ]] || sslverify="false"

  # Credentials go in a 0600 file, never on the command line where they would
  # show up in `ps`.
  cred="$(mktemp)"
  chmod 600 "$cred"
  printf '%s://%s:%s@%s\n' "$scheme" "$user" "$token" "$host" > "$cred"

  # GIT_TERMINAL_PROMPT/GIT_ASKPASS guarantee a hard failure instead of a
  # hanging password prompt if the token is wrong.
  out="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
        git -C "$REPO_DIR" \
            -c credential.helper="store --file=${cred}" \
            -c http.sslVerify="$sslverify" \
            push origin "HEAD:${branch}" 2>&1)" || rc=$?
  rm -f "$cred"

  if (( rc == 0 )); then
    return 0
  fi
  # Show the real error rather than swallowing it, with the token redacted.
  note "  push failed (git exit ${rc}):"
  printf '%s\n' "$out" | sed "s|${token}|<token>|g; s/^/    /" >&2
  case "$out" in
    *"401"*|*"Authentication failed"*|*"invalid credentials"*)
      note "  The token was rejected. Check it has write access to this repo:"
      note "    $0 set-token" ;;
    *"403"*)
      note "  Authenticated, but not authorised to push to this repository." ;;
    *"certificate"*|*"SSL"*|*"TLS"*)
      note "  TLS problem. GITEA_VERIFY_TLS in router.env is '${sslverify}'." ;;
  esac
  return 1
}

# Post a message through the configured webhook, exactly as monitor.py does,
# and report precisely why it failed. Without this there is no way to tell a
# missing URL from a TLS failure from a rejected channel override -- all three
# just look like "alerts do not arrive".
cmd_test_alert() {
  local message="${1:-}" url channel user verify host
  url="$(env_get MATTERMOST_WEBHOOK_URL)"
  channel="$(env_get MATTERMOST_CHANNEL)"
  user="$(env_get MATTERMOST_MONITOR_USER)"; [[ -n "$user" ]] || user="OllamaMonitor"
  verify="$(env_get MATTERMOST_VERIFY_TLS)"
  [[ -n "$message" ]] || message="Test alert from $(hostname) via ${0##*/} — if you can read this, monitor alerting works."

  if [[ -z "$url" ]]; then
    echo "MATTERMOST_WEBHOOK_URL is not set in ${SECRETS_FILE}."
    echo "The monitor logs alerts instead of posting them. Set one with:"
    echo "  $0 set-webhook <url>"
    return 1
  fi

  host="${url#*://}"; host="${host%%/*}"
  echo "Webhook host : ${host}"
  echo "Channel      : ${channel:-<webhook default>}"
  echo "Post as      : ${user}"
  echo "Verify TLS   : ${verify:-true}"
  echo

  local -a copts=(-sS -o /dev/null)
  [[ "$verify" == "false" ]] && copts+=(--insecure)

  _mm_post() {  # $1 = json payload -> prints "<http_code> <curl_rc>"
    local body="$1" code rc=0
    code="$(curl "${copts[@]}" -w '%{http_code}' -X POST \
            -H 'Content-Type: application/json' --data "$body" "$url" 2>/dev/null)" || rc=$?
    printf '%s %s' "${code:-000}" "$rc"
  }
  _mm_payload() {  # $1 = include the channel override? true/false
    python3 -c '
import json, sys
payload = {"username": sys.argv[1], "icon_emoji": ":white_check_mark:", "text": sys.argv[2]}
if sys.argv[3] == "true" and sys.argv[4]:
    payload["channel"] = sys.argv[4]
print(json.dumps(payload))' "$user" "$message" "$1" "$channel"
  }

  local result code rc
  result="$(_mm_post "$(_mm_payload true)")"
  code="${result%% *}"; rc="${result##* }"

  if [[ "$code" =~ ^2 ]]; then
    # NOTE: no apostrophe inside a ${var:-default}. Bash re-parses the default,
    # so a lone quote there opens a quote context and breaks the rest of the file.
    local where="the channel the webhook is bound to"
    [[ -n "$channel" ]] && where="#${channel}"
    echo "Delivered (HTTP ${code}). Check ${where} in Mattermost."
    return 0
  fi

  # Transport-level failure: curl never got an HTTP response.
  if [[ "$code" == "000" ]]; then
    echo "Could not reach the webhook (curl exit ${rc})."
    case "$rc" in
      6)  echo "  DNS: '${host}' does not resolve from inside this container." ;;
      7)  echo "  Connection refused — check the host, port and any firewall." ;;
      28) echo "  Timed out." ;;
      35|60)
          echo "  TLS failure. If Mattermost uses a self-signed or internal CA"
          echo "  certificate, turn verification off:"
          echo "    $0 set-webhook --verify-tls false" ;;
      *)  echo "  curl exit ${rc}." ;;
    esac
    return 1
  fi

  echo "Mattermost rejected the message (HTTP ${code})."

  # A 4xx WITH a channel override is very often the override itself: a webhook
  # is bound to one channel and many servers refuse to redirect it. Re-test
  # without the override so the report says which of the two is at fault.
  if [[ -n "$channel" && "$code" =~ ^4 ]]; then
    echo "Retrying without the channel override ..."
    result="$(_mm_post "$(_mm_payload false)")"
    if [[ "${result%% *}" =~ ^2 ]]; then
      echo
      echo "That worked. The webhook is fine; Mattermost is refusing to redirect"
      echo "it to '${channel}'. Either clear the override:"
      echo "    $0 set-webhook --channel ''"
      echo "  or allow channel overrides for this webhook in the System Console"
      echo "  (Integrations -> Incoming Webhooks), and confirm '${channel}' is the"
      echo "  channel's URL handle rather than its display name."
      return 1
    fi
    echo "  Still rejected (HTTP ${result%% *}) — the webhook URL itself is the problem."
  fi

  case "$code" in
    400) echo "  400 usually means a malformed payload or an unknown channel." ;;
    401|403) echo "  The webhook is not authorised to post there. Re-check it in"
             echo "  Integrations -> Incoming Webhooks." ;;
    404) echo "  404 means the webhook URL is wrong or has been deleted." ;;
  esac
  return 1
}

# Set the Mattermost webhook and its options without hand-editing router.env.
cmd_set_webhook() {
  local url="" set_url=false
  while (( $# )); do
    case "$1" in
      --channel)    env_set MATTERMOST_CHANNEL "${2-}"; CHANGED=true; shift 2 ;;
      --username)   env_set MATTERMOST_MONITOR_USER "${2:?--username needs a value}"; CHANGED=true; shift 2 ;;
      --verify-tls)
        [[ "${2-}" == "true" || "${2-}" == "false" ]] \
          || die "set-webhook: --verify-tls takes 'true' or 'false'"
        env_set MATTERMOST_VERIFY_TLS "$2"; CHANGED=true; shift 2 ;;
      -*) die "set-webhook: unknown option '$1'" ;;
      *)  url="$1"; set_url=true; shift ;;
    esac
  done

  if $set_url; then
    # An empty URL is meaningful: it disables posting and the monitor logs
    # alerts instead, which is the documented way to turn alerting off.
    if [[ -n "$url" ]]; then
      [[ "$url" =~ ^https?://[^[:space:]]+$ ]] \
        || die "set-webhook: '${url}' is not an http(s) URL"
    fi
    env_set MATTERMOST_WEBHOOK_URL "$url"
    CHANGED=true
    if [[ -n "$url" ]]; then
      echo "Webhook stored in ${SECRETS_FILE}."
    else
      echo "Webhook cleared — the monitor will log alerts instead of posting."
    fi
  fi

  $CHANGED || { echo "Nothing to change. See: $0 --help"; return 0; }
  echo
  echo "  webhook   : $(env_get MATTERMOST_WEBHOOK_URL | sed -E 's#(://[^/]+/).*#\1<redacted>#')"
  echo "  channel   : $(env_get MATTERMOST_CHANNEL)"
  echo "  username  : $(env_get MATTERMOST_MONITOR_USER)"
  echo "  verify tls: $(env_get MATTERMOST_VERIFY_TLS)"
  note "Run '$0 apply' to restart the monitor, then '$0 test-alert'."
}

cmd_set_token() {
  local token="${1:-}" confirm_token=""
  if [[ -z "$token" ]]; then
    if [[ "$ASSUME_YES" == "true" ]]; then
      die "set-token: no token given"
    fi
    read -r -s -p "Gitea deploy token: " token; echo
    read -r -s -p "Confirm token: " confirm_token; echo
    [[ "$token" == "$confirm_token" ]] || die "tokens did not match"
  fi
  [[ -n "$token" ]] || die "set-token: empty token"
  env_set GITEA_DEPLOY_TOKEN "$token"
  echo "Stored the deploy token in ${SECRETS_FILE}."
  note "  Verifying against $(env_get GITEA_SERVER_URL) ..."
  local base api code
  base="$(env_get GITEA_SERVER_URL)"; base="${base%/}"
  api="${base}/api/v1/user"
  local -a copts=(--location)
  [[ "$(env_get GITEA_VERIFY_TLS)" == "true" ]] || copts+=(--insecure)
  code="$(curl -o /dev/null -sS -w '%{http_code}' "${copts[@]}" \
          -H "Authorization: token ${token}" "$api" 2>/dev/null || echo "000")"
  case "$code" in
    200) note "  Token accepted by Gitea." ;;
    401) note "  WARNING: Gitea rejected the token (401)." ;;
    000) note "  WARNING: could not reach ${base} to verify." ;;
    *)   note "  WARNING: unexpected response from Gitea (HTTP ${code})." ;;
  esac
  CHANGED=true
}

# Router API key. Stored twice in the secrets file: ROUTER_API_KEY for the
# router, OPENAI_API_KEYS for Open WebUI, which authenticates to the router as
# an OpenAI connection. Both units load secrets.env.
cmd_set_api_key() {
  local key="${1:-}"
  case "$key" in
    --off)
      env_set ROUTER_API_KEY ""
      env_set OPENAI_API_KEYS ""
      echo "Router API key cleared: the API is open to anyone who can reach it."
      CHANGED=true
      return 0 ;;
    --generate|"")
      key="sk-router-$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')" ;;
  esac
  [[ "$key" =~ ^[A-Za-z0-9._~+/=-]{16,}$ ]] || \
    die "set-api-key: use at least 16 characters from A-Z a-z 0-9 . _ ~ + / = -"
  env_set ROUTER_API_KEY "$key"
  env_set OPENAI_API_KEYS "$key"
  echo "Stored the router API key in ${SECRETS_FILE}."
  $DRY_RUN || echo "  key: ${key}"
  note "  Clients must send:  Authorization: Bearer <key>"
  note "  Open WebUI reads OPENAI_API_KEYS only on its FIRST start; on an existing"
  note "  install also paste the key into Admin Settings > Connections > OpenAI."
  note "  Run '$0 apply' to restart the services with the key."
  CHANGED=true
}

# Bearer token for one server kind (set-lmstudio-token, set-maya-token, ...):
# LM Studio servers with "Require authentication" on, or Strata, Basalt, Maya
# and Xolotl servers started with an API key. One token per kind, stored in
# secrets.env (outside the repo) like the other secrets.
cmd_set_kind_token() {
  local kind="$1" token="${2:-}" confirm_token="" key_env name noun cmd
  is_server_kind "$kind" || die "unknown server kind '${kind}'"
  key_env="$(kind_field "$kind" key)"
  name="$(kind_secret_name "$kind")"
  noun="${name##* }"                     # token / key
  cmd="set-${kind}-token"
  if [[ "$token" == --off ]]; then
    env_set "$key_env" ""
    echo "${name} cleared."
    regenerate_litellm
    CHANGED=true
    return 0
  fi
  if [[ -z "$token" ]]; then
    [[ "$ASSUME_YES" == "true" ]] && die "${cmd}: no ${noun} given"
    read -r -s -p "$(kind_field "$kind" label) API ${noun}: " token; echo
    read -r -s -p "Confirm ${noun}: " confirm_token; echo
    [[ "$token" == "$confirm_token" ]] || die "${noun}s did not match"
  fi
  [[ -n "$token" ]] || die "${cmd}: empty ${noun}"
  [[ "$token" =~ ^[A-Za-z0-9._~+/=:-]+$ ]] || die "${cmd}: unexpected characters in ${noun}"
  env_set "$key_env" "$token"
  echo "Stored the ${name} in ${SECRETS_FILE}."
  regenerate_litellm
  CHANGED=true
}

# The kind a set-<kind>-token command names, or nothing.
token_command_kind() {
  local kind="${1#set-}"; kind="${kind%-token}"
  [[ "$1" == "set-${kind}-token" ]] && is_server_kind "$kind" && printf '%s\n' "$kind"
}

cmd_commit() {
  local message="${1:-Update model server list}"
  if $DRY_RUN; then echo "  [dry-run] would commit: ${message}"; return 0; fi
  command -v git >/dev/null 2>&1 || die "git is not installed"
  [[ -d "${REPO_DIR}/.git" ]] || {
    note "${REPO_DIR} is not a git repository (config was installed locally)."
    note "Nothing to commit or push."
    return 0
  }
  migrate_secrets
  git -C "$REPO_DIR" add -A
  if git -C "$REPO_DIR" diff --cached --quiet; then
    note "Nothing to commit."
  else
    git -C "$REPO_DIR" -c user.name="${GIT_AUTHOR_NAME:-ollama-smart-router}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-router@localhost}" \
        commit -q -m "$message"
    echo "Committed: ${message}"
  fi
  if git_push_authenticated; then
    echo "Pushed to Gitea."
  else
    note "  The commit is saved locally in ${REPO_DIR}; push it when resolved."
    # Only a caller that asked for it (update-router.sh) treats this as failure.
    if [[ "${REQUIRE_PUSH:-false}" == true ]]; then return 1; fi
  fi
  return 0
}

# Commands that write config, secrets or runtime files take the config lock;
# read-only ones (list, status, models, discover, test-alert) never wait on it.
command_writes() {
  case "$1" in
    add|remove|set-tier|set-model|set-server-model|set-keepalive|apply|commit|\
    set-token|set-api-key|set-webhook|set-webui-version) return 0 ;;
    *) [[ -n "$(token_command_kind "$1")" ]] ;;
  esac
}

lock_path() { readlink -f -- "$CONFIG_LOCK_FILE" 2>/dev/null || printf '%s\n' "$CONFIG_LOCK_FILE"; }

# True when nobody holds the lock (probed through a separate open of the file,
# so it also sees a lock held by this process's parent).
lock_is_free() {
  [[ -e "$CONFIG_LOCK_FILE" ]] || return 0
  ( flock -n 9 ) 9>>"$CONFIG_LOCK_FILE" 2>/dev/null
}

# True when a parent (install/update-router.sh) holds the lock and handed this
# process the descriptor: CONFIG_LOCK_INHERITED_FD must be an open descriptor on
# the lock file AND the lock must really be taken.
lock_inherited() {
  local fd="${CONFIG_LOCK_INHERITED_FD:-}"
  [[ "$fd" =~ ^[0-9]+$ ]] || return 1
  [[ "$(readlink -f "/proc/self/fd/${fd}" 2>/dev/null)" == "$(lock_path)" ]] || return 1
  ! lock_is_free
}

# PIDs of processes with the lock file open (holders and children that
# inherited the descriptor), excluding this shell.
lock_holders() {
  local target link pid
  target="$(lock_path)"
  for link in /proc/[0-9]*/fd/*; do
    [[ "$(readlink "$link" 2>/dev/null)" == "$target" ]] || continue
    pid="${link#/proc/}"; pid="${pid%%/*}"
    [[ "$pid" == "$$" || "$pid" == "${BASHPID:-}" ]] && continue
    printf '%s\n' "$pid"
  done | sort -un
}

acquire_config_lock() {
  local -a wait=(-n)
  command -v flock >/dev/null 2>&1 || die "flock is required to serialize config changes"
  [[ "$CONFIG_LOCK_WAIT" =~ ^[0-9]+$ ]] || die "CONFIG_LOCK_WAIT must be a number of seconds"
  (( CONFIG_LOCK_WAIT > 0 )) && wait=(-w "$CONFIG_LOCK_WAIT")
  exec {CONFIG_LOCK_FD}>>"$CONFIG_LOCK_FILE" || die "cannot open config lock: ${CONFIG_LOCK_FILE}"
  if ! flock "${wait[@]}" "$CONFIG_LOCK_FD"; then
    # Close ours first, or this process and its subshells list themselves.
    exec {CONFIG_LOCK_FD}>&-
    note "Another config change is running (lock: ${CONFIG_LOCK_FILE}), held by PID(s): $(lock_holders | tr '\n' ' ')"
    note "Wait for it (or set CONFIG_LOCK_WAIT=<seconds>). If it is hung: $0 clear-lock"
    exit 1
  fi
}

cmd_clear_lock() {
  local pid waited
  local -a pids=()
  if [[ ! -e "$CONFIG_LOCK_FILE" ]]; then
    echo "No lock file at ${CONFIG_LOCK_FILE}; nothing to clear."
    return 0
  fi
  if lock_is_free; then
    # The file is kept on purpose: deleting it while another process has it
    # open would let two changes lock two different files at once.
    echo "The config lock is not held; nothing to clear. ${CONFIG_LOCK_FILE} is only"
    echo "a placeholder: the lock dies with the process that holds it, so a crash"
    echo "or reboot never leaves it in force."
    return 0
  fi
  mapfile -t pids < <(lock_holders)
  note "The config lock (${CONFIG_LOCK_FILE}) is held by:"
  for pid in "${pids[@]}"; do
    note "  $(ps -o pid=,etime=,args= -p "$pid" 2>/dev/null || echo "$pid (exited)")"
  done
  (( ${#pids[@]} > 0 )) || die "no holding process is visible here (another container sharing the file?); not touching it."
  if ! $FORCE; then
    note "A change is in progress. If it is hung, stop it with: $0 clear-lock --force"
    return 1
  fi
  note "Stopping a change midway can leave the config repo or services half-updated."
  confirm "Stop these process(es)?" || die "cancelled; the lock is still held."
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for (( waited = 0; waited < LOCK_KILL_WAIT * 5; waited++ )); do
    lock_is_free && break
    sleep 0.2
  done
  if ! lock_is_free; then
    note "Still held after ${LOCK_KILL_WAIT}s; sending SIGKILL."
    mapfile -t pids < <(lock_holders)
    (( ${#pids[@]} == 0 )) || kill -KILL "${pids[@]}" 2>/dev/null || true
    for (( waited = 0; waited < 25; waited++ )); do
      lock_is_free && break
      sleep 0.2
    done
  fi
  lock_is_free || die "the lock is still held; check: ps -p $(lock_holders | tr '\n' ' ')"
  echo "Lock cleared. Check the config repo (git -C ${REPO_DIR} status) and run"
  echo "'$0 apply' so the running services match it."
}

# --- running from the Proxmox host -------------------------------------------
# The config this script edits lives inside the container. When invoked on the
# PVE host instead, find the container that actually holds it and re-exec there,
# rather than failing with a path the host was never going to have.

# Container IDs that are running, parsed by header position (pct list column
# order is not guaranteed).
running_ct_ids() {
  pct list 2>/dev/null | awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        h = tolower($i)
        if (h == "vmid") ci_id = i
        else if (h == "status") ci_status = i
      }
      if (!ci_id) ci_id = 1
      if (!ci_status) ci_status = 2
      next
    }
    NF >= ci_status && tolower($(ci_status)) == "running" { print $(ci_id) }'
}

ct_name_of() {
  pct config "$1" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2; exit}'
}

# The container holding the config is identified by actually having the file,
# not by guessing from its name.
find_router_ct() {
  local id
  if [[ -n "${CT_ID:-}" ]]; then
    printf '%s\n' "$CT_ID"
    return 0
  fi
  for id in $(running_ct_ids); do
    if pct exec "$id" -- test -f "$ENV_FILE" >/dev/null 2>&1; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

# Path to use for the in-container invocation, preferring the installed copies.
in_container_command() {
  local id="$1"
  if pct exec "$id" -- test -x /usr/local/bin/manage-model-servers >/dev/null 2>&1; then
    printf '%s\n' "/usr/local/bin/manage-model-servers"
  elif pct exec "$id" -- test -f "${REPO_DIR}/install/manage-model-servers.sh" >/dev/null 2>&1; then
    printf '%s\n' "${REPO_DIR}/install/manage-model-servers.sh"
  else
    printf '%s\n' ""
  fi
}

ensure_config_or_forward() {
  [[ -f "$ENV_FILE" ]] && return 0

  if ! command -v pct >/dev/null 2>&1; then
    die "config not found at ${ENV_FILE}. Run this inside the router container, or set CONFIG_REPO_DIR."
  fi

  # On a Proxmox host: locate the container and hand off to it.
  local id cmd
  if id="$(find_router_ct)"; then
    cmd="$(in_container_command "$id")"
    if [[ -n "$cmd" ]]; then
      note "Config lives inside container ${id} ($(ct_name_of "$id")); running there."
      exec pct exec "$id" -- "$cmd" "${ORIG_ARGS[@]}"
    fi
    # The container has the config but not the script: push this copy in.
    note "Container ${id} has the config but no installed tool; using this copy."
    pct push "$id" "$0" /tmp/manage-model-servers.sh --perms 0755 >/dev/null 2>&1 \
      || die "could not copy this script into container ${id}"
    exec pct exec "$id" -- bash /tmp/manage-model-servers.sh "${ORIG_ARGS[@]}"
  fi

  # Could not find it — say what was actually checked.
  echo "ERROR: ${ENV_FILE} does not exist here." >&2
  echo >&2
  echo "This tool edits configuration that lives INSIDE the router container," >&2
  echo "and you appear to be on the Proxmox host." >&2
  echo >&2
  local ids id2
  ids="$(running_ct_ids)"
  if [[ -n "$ids" ]]; then
    echo "Running containers checked (none had ${ENV_FILE}):" >&2
    for id2 in $ids; do
      printf '  %-6s %s\n' "$id2" "$(ct_name_of "$id2")" >&2
    done
    echo >&2
    echo "If the router container is one of these, run:" >&2
    echo "  CT_ID=<id> $0 ${ORIG_ARGS[*]}" >&2
  else
    echo "No running containers were found (pct list)." >&2
  fi
  echo >&2
  echo "Or run it inside the container directly:" >&2
  echo "  pct exec <CTID> -- manage-model-servers ${ORIG_ARGS[*]}" >&2
  echo >&2
  echo "If your config lives elsewhere, set CONFIG_REPO_DIR." >&2
  exit 1
}

# --- argument parsing ---------------------------------------------------------
ORIG_ARGS=("$@")     # kept verbatim so the hand-off re-runs the same request
COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || { usage; exit 1; }
shift || true
case "$COMMAND" in -h|--help|help) usage; exit 0 ;; esac

TIER_ARG=""
COMMIT_MSG=""
ARGS=()
while (( $# > 0 )); do
  case "$1" in
    --tier)      TIER_ARG="${2:-}"; shift 2 ;;
    --tier=*)    TIER_ARG="${1#*=}"; shift ;;
    --apply)     AUTO_APPLY=true; shift ;;
    --commit)    AUTO_COMMIT=true; shift ;;
    --commit=*)  AUTO_COMMIT=true; COMMIT_MSG="${1#*=}"; shift ;;
    --no-probe)  NO_PROBE=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -y|--yes)    ASSUME_YES=true; shift ;;
    --force)
      [[ "$COMMAND" == "clear-lock" ]] || die "unknown option: $1"
      FORCE=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    # set-webhook's own flags. They are passed through rather than handled
    # here, because they take a value that may legitimately be EMPTY
    # (--channel '' clears the override) and only that command understands them.
    --channel|--username|--verify-tls)
      [[ "$COMMAND" == "set-webhook" ]] || die "unknown option: $1"
      (( $# >= 2 )) || die "$1 needs a value"
      ARGS+=("$1" "$2"); shift 2 ;;
    --generate|--off)
      [[ "$COMMAND" == "set-api-key" || -n "$(token_command_kind "$COMMAND")" ]] || die "unknown option: $1"
      ARGS+=("$1"); shift ;;
    --all)       APPLY_ALL=true; shift ;;
    --type)      SERVER_TYPE="${2:-}"; shift 2 ;;
    --type=*)    SERVER_TYPE="${1#*=}"; shift ;;
    --*)         die "unknown option: $1" ;;
    *)           ARGS+=("$1"); shift ;;
  esac
done

for tier in $(csv_to_lines "${TIER_ARG:-}"); do
  tier_env_key "$tier" >/dev/null
done
if [[ "$SERVER_TYPE" != auto && "$SERVER_TYPE" != ollama ]] && ! is_server_kind "$SERVER_TYPE"; then
  die "--type must be ollama, $(server_kinds | paste -sd, - | sed 's/,/, /g') or auto (got '${SERVER_TYPE}')"
fi

ensure_config_or_forward
if command_writes "$COMMAND" && ! $DRY_RUN && ! lock_inherited; then
  acquire_config_lock
fi
$DRY_RUN && note "(dry run — no files will be written)"

case "$COMMAND" in
  list)     cmd_list false ;;
  status)   cmd_list true ;;
  discover) cmd_discover ;;
  add)      cmd_add "${ARGS[@]:-}" ;;
  remove)   cmd_remove "${ARGS[@]:-}" ;;
  set-tier) cmd_set_tier "${ARGS[@]:-}" ;;
  set-model) cmd_set_model "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
  set-server-model) cmd_set_server_model "${ARGS[0]:-}" "${ARGS[1]:-}" "${ARGS[2]:-}" ;;
  models)   cmd_models ;;
  set-keepalive) cmd_set_keepalive "${ARGS[0]-}" ;;
  apply)    cmd_apply ;;
  commit)   cmd_commit "${ARGS[0]:-Update model server list}" ;;
  set-token) cmd_set_token "${ARGS[0]:-}" ;;
  set-api-key) cmd_set_api_key "${ARGS[0]:-}" ;;
  set-*-token)
    token_kind="$(token_command_kind "$COMMAND")"
    [[ -n "$token_kind" ]] || die "unknown command '${COMMAND}' (try --help)"
    cmd_set_kind_token "$token_kind" "${ARGS[0]:-}" ;;
  test-alert) cmd_test_alert "${ARGS[0]:-}" ;;
  set-webhook) cmd_set_webhook ${ARGS[@]+"${ARGS[@]}"} ;;
  set-webui-version) cmd_set_webui_version "${ARGS[0]:-}" ;;
  clear-lock) cmd_clear_lock ;;
  *)        die "unknown command '${COMMAND}' (try --help)" ;;
esac

case "$COMMAND" in
  add|remove|set-tier|set-model|set-server-model|set-keepalive|set-webui-version|set-webhook)
    if ! $CHANGED && ! $DRY_RUN; then
      exit 0        # nothing was written; no need to nag about applying
    fi
    $AUTO_APPLY && cmd_apply
    $AUTO_COMMIT && cmd_commit "${COMMIT_MSG:-${COMMAND}: update model configuration}"
    echo
    cmd_list false
    if ! $AUTO_APPLY && ! $DRY_RUN; then
      echo
      note "Config changed but NOT applied. Run: $0 apply"
    fi
    ;;
  set-api-key|set-*-token)
    if $CHANGED && $AUTO_APPLY && ! $DRY_RUN; then cmd_apply; fi
    ;;
esac
