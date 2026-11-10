#!/usr/bin/env bash
# Run as root in the dedicated Hermes LXC (provision-lxc.sh pushes this file,
# hermes-gateway.service and the router's API key). Hermes discovers models
# through the router but sends inference to model servers through a local
# loopback dispatcher.
#
#   bash install-target.sh            install, or apply changed settings
#   bash install-target.sh --dry-run  print the plan; change nothing
set -Eeuo pipefail
# Signal rollback helper
# A signal (Ctrl-C, a closed SSH session, kill) runs the same rollback as a
# failure: whatever the ERR trap holds at that moment, so a half-applied
# upgrade is undone; outside a rollback window it just stops the run. Further
# signals are ignored meanwhile, and after a hangup the output goes to
# OSR_INTERRUPT_LOG, so writes to the closed terminal cannot fail the rollback.
# Every copy matches targets/signal-rollback.sh (tests/test-signal-rollback.sh).
on_signal() {
    local status=$1 handler action
    local -a parts=()
    trap '' INT TERM HUP
    if [[ $status == 129 ]]; then
        exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
    fi
    printf '%s: stopped by a signal (status %s).\n' "${0##*/}" "$status" >&2
    handler=$(trap -p ERR)
    if [[ -n $handler ]]; then
        eval "parts=($handler)"
        action=${parts[2]}
        # The rollback handlers end in "exit 1": keep the signal's status.
        [[ $action != *'; exit 1' ]] || action="${action%exit 1}exit $status"
        trap - ERR
        eval "$action"
    fi
    exit "$status"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
# End signal rollback helper.
umask 077

INSTALL_URL=https://hermes-agent.nousresearch.com/install.sh
# Paths are overridable for tests only; hermes-gateway.service uses the defaults.
HERMES_USER=${HERMES_USER:-hermes}
HERMES_USER_HOME=${HERMES_USER_HOME:-/home/hermes}
HERMES_ETC=${HERMES_ETC:-/etc/hermes-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
DIRECT_LIB=${DIRECT_LIB:-/usr/local/lib/hermes-direct.py}
LOCK_FILE=${LOCK_FILE:-/etc/hermes-target.lock}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-60}
# One real direct chat request with a tool, to prove auth and inference.
CHAT_PROBE_TIMEOUT=${CHAT_PROBE_TIMEOUT:-300}
# Hermes needs at least 64K context for agent work with tools.
MIN_CONTEXT=64000

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash install-target.sh [--dry-run]

Inside an existing Hermes CT, a direct interactive run asks for the router
base URL when ROUTER_URL is unset. An unattended run must set ROUTER_URL.
CT ID and CT IP are chosen by provision-lxc.sh on the Proxmox host.

Installs Hermes Agent with the official POSIX installer and points its named
provider custom:osr at a local direct dispatcher. The dispatcher uses the
router's inventory and ranking, then calls model servers itself. Each model
server in the targets file is also a provider, custom:<target>, that the
dispatcher reaches without the router. Rerun to change settings;
an unchanged, healthy installation is left alone.

Environment:
  ROUTER_URL                   router base URL (host and port, no /v1)
  ROUTER_API_KEY_FILE          file holding the router's ROUTER_API_KEY
                               (default: router-api-key next to this script;
                               absent: keep the key already configured)
  HERMES_MODEL=auto            a model ID from the router's /v1/models
  HERMES_CONTEXT_LENGTH=65536  context the model's host really serves (>=64000)
  HERMES_CHANNEL=stable        upstream update channel (stable or main)
  HERMES_COMMIT=<sha>          pin the Hermes checkout to this commit
  HERMES_INSTALLER_SHA256      refuse an install.sh with another SHA-256
  HERMES_API_SERVER=false      true: run hermes-gateway.service with Hermes's
                               OpenAI-compatible API server (for Open WebUI)
  HERMES_API_PORT=8642         API server port
  HERMES_API_MODEL_NAME=hermes-agent   model name the API server advertises
  HERMES_DASHBOARD=true       start the authenticated dashboard on all CT IPv4 addresses, port 9119
  HERMES_SKIP_CHAT_PROBE=false true: skip the test chat request
  HONCHO_URL                   Honcho memory (HONCHO_API_KEY_FILE: its key); OSR's
                               Honcho names this CT's own workspace, another
                               Honcho uses HONCHO_WORKSPACE (default osr)
  OPEN_TERMINAL_URL            Open Terminal gateway (http://IP:port): Hermes's
                               own workspace there, as MCP server open_terminal;
                               empty after a run that set it disconnects it
  OPEN_TERMINAL_KEY_FILE       this CT's client key (default: open-terminal-key
                               next to this script, pushed by provision-lxc.sh)
Hermes code updates are made with `hermes update` as the hermes user.
USAGE
}

# Install helpers (sourced by test-install.sh) -------------------------------

# settings_record: the settings this installation runs with. The router key
# is recorded only as a hash, so rotating it is a change.
settings_record() {
  printf 'ROUTER_URL=%s\n' "$ROUTER_URL"
  printf 'HERMES_MODEL=%s\n' "$HERMES_MODEL"
  printf 'HERMES_CONTEXT_LENGTH=%s\n' "$HERMES_CONTEXT_LENGTH"
  printf 'HERMES_CHANNEL=%s\n' "$HERMES_CHANNEL"
  printf 'HERMES_COMMIT=%s\n' "$HERMES_COMMIT"
  printf 'HERMES_API_SERVER=%s\n' "$HERMES_API_SERVER"
  printf 'HERMES_API_PORT=%s\n' "$HERMES_API_PORT"
  printf 'HERMES_API_MODEL_NAME=%s\n' "$HERMES_API_MODEL_NAME"
  printf 'HERMES_DASHBOARD=%s\n' "$HERMES_DASHBOARD"
  printf 'KINDI_READ_TIMEOUT_SECONDS=%s\n' "${KINDI_READ_TIMEOUT_SECONDS:-3600}"
  printf 'HONCHO_URL=%s\nHONCHO_KEY_SHA256=%s\nHONCHO_WORKSPACE=%s\n' "$HONCHO_URL" "$honcho_key_sha256" "$honcho_workspace"
  printf 'OPEN_TERMINAL_URL=%s\nOPEN_TERMINAL_KEY_SHA256=%s\n' "$OPEN_TERMINAL_URL" "$ot_key_sha256"
  printf 'ROUTER_KEY_SHA256=%s\n' "$router_key_sha256"
  printf 'BACKEND_KEYS_SHA256=%s\n' "$backend_keys_sha256"
  printf 'TARGETS_SHA256=%s\n' "$targets_sha256"
  printf 'DASHBOARD_AUTH_SHA256=%s\n' "$dashboard_auth_sha256"
  printf 'UNIT_SHA256=%s\n' "$unit_sha256"
}

dashboard_auth_hash() {
  [[ $HERMES_DASHBOARD == true && -f $HERMES_HOME/.env ]] || { printf 'none\n'; return; }
  awk -F= '$1 ~ /^HERMES_DASHBOARD_(BASIC_AUTH|OAUTH|OIDC)_/ {print}' "$HERMES_HOME/.env" |
    sha256sum | cut -d' ' -f1
}

# env_file_update FILE: set or remove KEY=VALUE lines in a dotenv file. The
# changes come from the environment (ENV_SET_<KEY>=value sets, ENV_UNSET_<KEY>
# removes; ENV_UNSET_IF_<KEY>=value removes only that value), never from argv.
env_file_update() {
  python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
sets = {k[len("ENV_SET_"):]: v for k, v in os.environ.items() if k.startswith("ENV_SET_")}
unsets = {k[len("ENV_UNSET_"):] for k in os.environ if k.startswith("ENV_UNSET_")
          and not k.startswith("ENV_UNSET_IF_")}
unset_if = {k[len("ENV_UNSET_IF_"):]: v for k, v in os.environ.items()
            if k.startswith("ENV_UNSET_IF_")}
try:
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
except FileNotFoundError:
    lines = []
out, done = [], set()
for line in lines:
    key, sep, value = line.partition("=")
    key = key.strip()
    if sep and key in unsets:
        continue
    if sep and key in unset_if and value.strip() == unset_if[key]:
        continue
    if sep and key in sets:
        if key in done:
            continue
        line = f"{key}={sets[key]}"
        done.add(key)
    out.append(line)
for key, value in sets.items():
    if key not in done:
        out.append(f"{key}={value}")
with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out) + ("\n" if out else ""))
PY
}

# env_file_get FILE KEY: the first KEY=value in a dotenv file (empty if none).
env_file_get() {
  [[ -f $1 ]] || return 0
  awk -v k="$2" -F= '$1==k {sub(/^[^=]*=/,""); print; exit}' "$1"
}

# models_has ID < /v1/models JSON: is ID listed?
models_has() {
  python3 -c 'import json,sys
data = json.load(sys.stdin)
sys.exit(0 if any(isinstance(m, dict) and m.get("id") == sys.argv[1] for m in data.get("data", [])) else 1)' "$1"
}

# chat_probe_body MODEL: a minimal chat request that offers one tool, so the
# router has to pick (or the named model has to be) tool-capable.
chat_probe_body() {
  python3 -c 'import json,sys
print(json.dumps({"model": sys.argv[1], "max_tokens": 16, "stream": False,
  "messages": [{"role": "user", "content": "Reply with the single word: ready"}],
  "tools": [{"type": "function", "function": {"name": "noop",
    "description": "Does nothing.", "parameters": {"type": "object", "properties": {}}}}]}))' "$1"
}

# error_message < JSON: the error text of an OpenAI-style error body.
error_message() {
  python3 -c 'import json,sys
try:
    body = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
error = body.get("error") if isinstance(body, dict) else None
if isinstance(error, dict):
    print(error.get("message") or error.get("code") or "")
elif isinstance(body, dict) and body.get("detail"):
    print(body["detail"])
' 2>/dev/null || true
}
# End install helpers. ----------------------------------------------------------

dry_run=0
while (( $# )); do
  case $1 in
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROUTER_URL=${ROUTER_URL:-}
ROUTER_API_KEY_FILE=${ROUTER_API_KEY_FILE:-$source_dir/router-api-key}
HERMES_MODEL=${HERMES_MODEL:-auto}
HERMES_CONTEXT_LENGTH=${HERMES_CONTEXT_LENGTH:-65536}
HERMES_CHANNEL=${HERMES_CHANNEL:-stable}
HERMES_COMMIT=${HERMES_COMMIT:-}
HERMES_INSTALLER_SHA256=${HERMES_INSTALLER_SHA256:-}
HERMES_API_SERVER=${HERMES_API_SERVER:-false}
HERMES_API_PORT=${HERMES_API_PORT:-8642}
HERMES_API_MODEL_NAME=${HERMES_API_MODEL_NAME:-hermes-agent}
HERMES_DASHBOARD=${HERMES_DASHBOARD:-true}
HERMES_SKIP_CHAT_PROBE=${HERMES_SKIP_CHAT_PROBE:-false}
HONCHO_URL=${HONCHO_URL:-}
HONCHO_API_KEY_FILE=${HONCHO_API_KEY_FILE:-$source_dir/honcho-api-key}
honcho_key_owned=false
[[ $HONCHO_API_KEY_FILE != "$source_dir/honcho-api-key" ]] || honcho_key_owned=true
# Open Terminal: Hermes's own workspace in the terminal CT, reached as MCP
# tools (the gateway's /mcp) with this CT's client key.
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL:-}
OPEN_TERMINAL_KEY_FILE=${OPEN_TERMINAL_KEY_FILE:-$source_dir/open-terminal-key}
ot_key_owned=false
[[ $OPEN_TERMINAL_KEY_FILE != "$source_dir/open-terminal-key" ]] || ot_key_owned=true
HERMES_HOME=$HERMES_USER_HOME/.hermes
HERMES_BIN=$HERMES_USER_HOME/.local/bin/hermes
UNIT=hermes-gateway.service
DIRECT_UNIT=hermes-direct.service
DASHBOARD_UNIT=hermes-dashboard.service
DASHBOARD_PORT=9119
DIRECT_URL=http://127.0.0.1:8765
BACKEND_KEYS_FILE=${BACKEND_KEYS_FILE:-$source_dir/backend-keys}
# NAME=SERVER per model server, from the router's inventory (provision-lxc.sh).
TARGETS_FILE=${TARGETS_FILE:-$source_dir/targets}
# target_names FILE: the direct target names in a targets file.
target_names() { [[ -f $1 ]] && cut -d= -f1 "$1" || true; }
kindi_target_names() { [[ -f $1 ]] && awk -F= '$2 ~ /^kindi[+]/ {print $1}' "$1" || true; }
# This run's targets: the pushed file, else the installed one.
targets_source=$TARGETS_FILE
[[ -f $targets_source ]] || targets_source=$HERMES_ETC/targets
KINDI_READ_TIMEOUT_SECONDS=${KINDI_READ_TIMEOUT_SECONDS:-3600}
[[ $KINDI_READ_TIMEOUT_SECONDS =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid KINDI_READ_TIMEOUT_SECONDS.'
# Hermes's limits for Kindi-facing providers. Its non-streaming stale watchdog
# runs from the start of a call without resetting on progress, so it is a
# deadline for the whole reply: twice the dispatcher's silent-read budget plus
# an 8192-token reply at one token a second.
KINDI_CLIENT_TIMEOUT_SECONDS=$((KINDI_READ_TIMEOUT_SECONDS * 2 + 8192))
kindi_targets="$(kindi_target_names "$targets_source" | paste -sd' ' -)"
previous_kindi_targets="$(kindi_target_names "$HERMES_ETC/targets" | paste -sd' ' -)"

if [[ -z $ROUTER_URL && ${NONINTERACTIVE:-false} != true && -t 0 ]]; then
  IFS= read -r -p 'Router base URL (http(s)://router-address:port): ' ROUTER_URL ||
    die 'No router URL was entered.'
fi
[[ -n $ROUTER_URL ]] ||
  die 'ROUTER_URL is unset. Resume from the Proxmox host with provision-lxc.sh --reconfigure; unattended guest runs must set ROUTER_URL=http://router-address:8000.'
[[ $ROUTER_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] ||
  die 'ROUTER_URL must be an HTTP(S) host and port, such as http://router-address:8000.'
[[ -z $HONCHO_URL || $HONCHO_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] || die 'Invalid HONCHO_URL.'
[[ -z $OPEN_TERMINAL_URL || $OPEN_TERMINAL_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] || die 'Invalid OPEN_TERMINAL_URL.'
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL%/}
ROUTER_URL=${ROUTER_URL%/}
[[ $HERMES_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid HERMES_MODEL.'
[[ $HERMES_CONTEXT_LENGTH =~ ^[1-9][0-9]{4,6}$ ]] && (( HERMES_CONTEXT_LENGTH >= MIN_CONTEXT )) ||
  die "HERMES_CONTEXT_LENGTH must be at least $MIN_CONTEXT: Hermes needs 64K context for agent work with tools. The model's host must serve that much too."
[[ $HERMES_CHANNEL =~ ^(stable|main)$ ]] || die 'HERMES_CHANNEL must be stable or main.'
[[ -z $HERMES_COMMIT || $HERMES_COMMIT =~ ^[0-9a-f]{40}$ ]] ||
  die 'HERMES_COMMIT must be a full 40-digit lowercase SHA-1.'
[[ -z $HERMES_INSTALLER_SHA256 || $HERMES_INSTALLER_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
  die 'HERMES_INSTALLER_SHA256 must be 64 lowercase hex digits.'
[[ $HERMES_API_SERVER =~ ^(true|false)$ ]] || die 'HERMES_API_SERVER must be true or false.'
[[ $HERMES_DASHBOARD =~ ^(true|false)$ ]] || die 'HERMES_DASHBOARD must be true or false.'
[[ $HERMES_SKIP_CHAT_PROBE =~ ^(true|false)$ ]] || die 'HERMES_SKIP_CHAT_PROBE must be true or false.'
[[ $HERMES_API_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( HERMES_API_PORT <= 65535 )) || die 'Invalid HERMES_API_PORT.'
# Hermes reserves 8644-8646 for other gateway adapters.
(( HERMES_API_PORT < 8644 || HERMES_API_PORT > 8646 )) || die 'HERMES_API_PORT 8644-8646 are reserved by Hermes.'
[[ $HERMES_API_MODEL_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$ ]] || die 'Invalid HERMES_API_MODEL_NAME.'
[[ $HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid HEALTH_TIMEOUT.'
[[ $CHAT_PROBE_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid CHAT_PROBE_TIMEOUT.'
for path_var in HERMES_USER_HOME HERMES_ETC UNIT_DIR LOCK_FILE DIRECT_LIB; do
  [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $HERMES_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid HERMES_USER.'
if [[ $HERMES_API_SERVER == true ]]; then
  [[ -r $source_dir/$UNIT ]] || die "Missing $source_dir/$UNIT (provision-lxc.sh pushes it)."
fi
if [[ $HERMES_DASHBOARD == true ]]; then
  [[ -r $source_dir/$DASHBOARD_UNIT ]] || die "Missing $source_dir/$DASHBOARD_UNIT (provision-lxc.sh pushes it)."
fi
[[ -r $source_dir/$DIRECT_UNIT && -r $source_dir/direct-dispatch.py ]] ||
  die 'Missing Hermes direct dispatcher and service (provision-lxc.sh pushes them).'

if (( dry_run )); then
  printf '+ verify %s/v1/models (with the router API key) advertises %s\n' "$ROUTER_URL" "$HERMES_MODEL"
  printf '+ apt-get install ca-certificates curl git tar coreutils libatomic1 python3 openssl util-linux\n'
  printf '+ create unprivileged user %s; install Hermes via %s --non-interactive --skip-browser --skip-computer-use --channel %s%s\n' \
    "$HERMES_USER" "$INSTALL_URL" "$HERMES_CHANNEL" "${HERMES_COMMIT:+ --commit $HERMES_COMMIT}"
  printf '+ configure provider=custom:osr (api %s/v1), model=%s, context_length=%s, api_key=<local placeholder>\n' \
    "$DIRECT_URL" "$HERMES_MODEL" "$HERMES_CONTEXT_LENGTH"
  printf '+ configure direct providers custom:<target> (api %s/t/<target>/v1) for: %s\n' \
    "$DIRECT_URL" "$(target_names "$targets_source" | paste -sd' ' - | sed 's/^$/none/')"
  printf '+ install %s, start %s, discover models via router and dispatch inference directly\n' \
    "$DIRECT_LIB" "$DIRECT_UNIT"
  [[ $HERMES_SKIP_CHAT_PROBE == true ]] ||
    printf '+ send one chat request offering a tool through the local dispatcher to a model server (model %s)\n' "$HERMES_MODEL"
  if [[ $HERMES_API_SERVER == true ]]; then
    printf '+ API server on 0.0.0.0:%s as model %s; key in %s/api-key and %s/.env\n' \
      "$HERMES_API_PORT" "$HERMES_API_MODEL_NAME" "$HERMES_ETC" "$HERMES_HOME"
    printf '+ install %s/%s, enable and start it, wait for /health and /v1/models\n' "$UNIT_DIR" "$UNIT"
  else
    printf '+ no API server: stop and remove %s if present\n' "$UNIT"
  fi
  if [[ $HERMES_DASHBOARD == true ]]; then
    printf '+ generate dashboard login if needed; enable %s on 0.0.0.0:%s; verify /api/status requires authentication\n' "$DASHBOARD_UNIT" "$DASHBOARD_PORT"
  else
    printf '+ stop and remove %s if present\n' "$DASHBOARD_UNIT"
  fi
  if [[ -n $OPEN_TERMINAL_URL ]]; then
    printf '+ check %s/osr/v1/whoami with this CT'\''s key; MCP server open_terminal at %s/mcp (key in %s/.env)\n' \
      "$OPEN_TERMINAL_URL" "$OPEN_TERMINAL_URL" "$HERMES_HOME"
  fi
  exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the Hermes CT.'
# A minimal Debian template may not have Python or curl, which the router
# probes need. Install only these before touching Hermes.
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v flock >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl python3 util-linux
fi

# One run at a time. The lock is released when this shell exits.
exec {install_lock_fd}>>"$LOCK_FILE"
flock -n "$install_lock_fd" || die "Another install-target.sh run holds $LOCK_FILE."

stage=$(mktemp -d "${TMPDIR:-/tmp}/hermes-target.XXXXXX")
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT

# --- the router key: the pushed file, else the one already configured ----------
router_key=''
key_source='none'
if [[ -f $ROUTER_API_KEY_FILE ]]; then
  router_key=$(tr -d '\r\n' < "$ROUTER_API_KEY_FILE")
  key_source=$ROUTER_API_KEY_FILE
elif [[ -f $HERMES_HOME/.env ]]; then
  router_key=$(env_file_get "$HERMES_HOME/.env" ROUTER_API_KEY | tr -d '\r\n')
  [[ -z $router_key ]] || key_source="$HERMES_HOME/.env"
fi
[[ -z $router_key || $router_key =~ ^[A-Za-z0-9._~+/=-]{8,512}$ ]] ||
  die "The router API key in ${ROUTER_API_KEY_FILE} has unexpected characters."
router_key_sha256=none
honcho_key_sha256=none
# The Honcho URL of the last completed run, read before this run rewrites the
# settings: an empty HONCHO_URL turns off only a Honcho this target set up.
prev_honcho_url=$(env_file_get "$HERMES_ETC/settings" HONCHO_URL 2>/dev/null || true)
if [[ -n $HONCHO_URL ]]; then
  [[ -s $HONCHO_API_KEY_FILE ]] || die "HONCHO_URL needs $HONCHO_API_KEY_FILE."
  honcho_key_sha256=$(sha256sum "$HONCHO_API_KEY_FILE" | cut -d' ' -f1)
fi
ot_key_sha256=none
ot_key=''
prev_ot_url=$(env_file_get "$HERMES_ETC/settings" OPEN_TERMINAL_URL 2>/dev/null || true)
if [[ -n $OPEN_TERMINAL_URL ]]; then
  [[ -s $OPEN_TERMINAL_KEY_FILE ]] || die "OPEN_TERMINAL_URL needs $OPEN_TERMINAL_KEY_FILE (provision-lxc.sh pushes it)."
  ot_key=$(tr -d '\r\n\t ' < "$OPEN_TERMINAL_KEY_FILE")
  [[ $ot_key =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]] || die "$OPEN_TERMINAL_KEY_FILE does not hold a usable key."
  ot_key_sha256=$(printf '%s' "$ot_key" | sha256sum | cut -d' ' -f1)
fi
if [[ -n $router_key ]]; then
  router_key_sha256=$(printf '%s' "$router_key" | sha256sum | cut -d' ' -f1)
  # curl reads the header from this file, so the key never appears in argv.
  printf 'Authorization: Bearer %s\n' "$router_key" > "$stage/router-auth"
fi
targets_sha256=none
if [[ -f $targets_source ]]; then
  if grep -Evq '^[a-z0-9][a-z0-9-]{0,62}=[^[:space:]]+$' "$targets_source"; then
    die "$targets_source has an invalid line; rerun provision-lxc.sh --reconfigure."
  fi
  targets_sha256=$(sha256sum "$targets_source" | cut -d' ' -f1)
fi
backend_keys_sha256=none
if [[ -f $BACKEND_KEYS_FILE ]]; then
  backend_keys_sha256=$(sha256sum "$BACKEND_KEYS_FILE" | cut -d' ' -f1)
elif [[ -f $HERMES_ETC/backend-keys ]]; then
  backend_keys_sha256=$(sha256sum "$HERMES_ETC/backend-keys" | cut -d' ' -f1)
fi

# api URL AUTH_FILE [BODY_FILE] [TIMEOUT]: print the HTTP status ("000" when no
# connection); the body is left in $stage/response.
api() {
  local url=$1 auth=$2 body=${3:-} timeout=${4:-15}
  local -a args=(--silent --show-error --max-time "$timeout" -o "$stage/response" -w '%{http_code}')
  if [[ -s $auth ]]; then args+=(-H "@$auth"); fi
  if [[ -n $body ]]; then args+=(-H 'Content-Type: application/json' --data-binary "@$body"); fi
  : > "$stage/response"
  curl "${args[@]}" "$url" 2>"$stage/curl-error" || true
}

# --- the router answers, accepts the key and serves the model -------------------
status=$(api "$ROUTER_URL/v1/models" "$stage/router-auth")
case $status in
  200) ;;
  401|403)
    if [[ -z $router_key ]]; then
      die "The router at $ROUTER_URL requires its API key. Run provision-lxc.sh --reconfigure, or put ROUTER_API_KEY from the router's /app/router/secrets.env into $ROUTER_API_KEY_FILE."
    fi
    die "The router at $ROUTER_URL rejected the API key from $key_source (HTTP $status). It may have been rotated with set-api-key: run provision-lxc.sh --reconfigure." ;;
  000) die "The router at $ROUTER_URL is unreachable: $(head -c 300 "$stage/curl-error")" ;;
  *) die "The router at $ROUTER_URL answered /v1/models with HTTP $status." ;;
esac
models_has "$HERMES_MODEL" < "$stage/response" ||
  die "The router does not advertise model '$HERMES_MODEL'. Choose one from $ROUTER_URL/v1/models."

# --- the Open Terminal gateway admits this CT and accepts its key ---------------
if [[ -n $OPEN_TERMINAL_URL ]]; then
  printf 'Authorization: Bearer %s\n' "$ot_key" > "$stage/open-terminal-auth"
  status=$(api "$OPEN_TERMINAL_URL/osr/v1/whoami" "$stage/open-terminal-auth")
  case $status in
    200) ;;
    401|403) die "Open Terminal at $OPEN_TERMINAL_URL rejected this CT's key. Rerun provision-lxc.sh --reconfigure with OPEN_TERMINAL_CT_ID to issue a new one." ;;
    000) die "Open Terminal at $OPEN_TERMINAL_URL is unreachable from this CT: $(head -c 300 "$stage/curl-error"). Its firewall must admit this CT (provision-lxc.sh does that with OPEN_TERMINAL_CT_ID)." ;;
    *) die "Open Terminal at $OPEN_TERMINAL_URL answered /osr/v1/whoami with HTTP $status (is it the workspace gateway?)." ;;
  esac
fi

# --- the Honcho gateway accepts this CT's key and names its workspace -----------
# OSR's Honcho gives each agent a workspace of its own and says which one at
# /osr/v1/whoami. A Honcho without that gateway (404) gets HONCHO_WORKSPACE,
# osr by default.
honcho_workspace=none
if [[ -n $HONCHO_URL ]]; then
  printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$HONCHO_API_KEY_FILE")" > "$stage/honcho-auth"
  status=$(api "${HONCHO_URL%/}/osr/v1/whoami" "$stage/honcho-auth")
  case $status in
    200) honcho_workspace=$(python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
w = d.get("workspace") if isinstance(d, dict) and not d.get("per_user") else None
print(w if isinstance(w, str) else "")' "$stage/response" 2>/dev/null || true) ;;
    404) honcho_workspace=${HONCHO_WORKSPACE:-osr} ;;
    401|403) die "Honcho at $HONCHO_URL rejected this CT's key. Rerun provision-lxc.sh --reconfigure with HONCHO_CT_ID to issue a new one." ;;
    000) die "Honcho at $HONCHO_URL is unreachable from this CT: $(head -c 300 "$stage/curl-error"). Its firewall must admit this CT (HONCHO_CLIENT_IPS of targets/honcho/provision-lxc.sh)." ;;
    *) die "Honcho at $HONCHO_URL answered /osr/v1/whoami with HTTP $status." ;;
  esac
  [[ $honcho_workspace =~ ^[A-Za-z0-9_-]{1,100}$ ]] ||
    die "Honcho at $HONCHO_URL names no workspace of its own for this CT's key (Open WebUI's key?). Rerun provision-lxc.sh --reconfigure with HONCHO_CT_ID."
fi

# --- unchanged and healthy: nothing to do ---------------------------------------
unit_sha256=none
if [[ $HERMES_API_SERVER == true ]]; then
  unit_sha256=$(sha256sum "$source_dir/$UNIT" | cut -d' ' -f1)
fi
if [[ $HERMES_DASHBOARD == true ]]; then
  unit_sha256=$(printf '%s\n' "$unit_sha256" | cat - "$source_dir/$DASHBOARD_UNIT" | sha256sum | cut -d' ' -f1)
fi
unit_sha256=$(printf '%s\n' "$unit_sha256" | cat - "$source_dir/$DIRECT_UNIT" "$source_dir/direct-dispatch.py" | sha256sum | cut -d' ' -f1)
dashboard_auth_sha256=$(dashboard_auth_hash)
settings=$(settings_record)

# gateway_healthy [PORT] [MODEL_NAME]: /health is ok and /v1/models, with the
# API key, lists the model. Defaults: the settings of this run.
gateway_healthy() {
  local port=${1:-$HERMES_API_PORT} name=${2:-$HERMES_API_MODEL_NAME} key_file=$stage/api-auth
  [[ -s $HERMES_ETC/api-key ]] || return 1
  printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$HERMES_ETC/api-key")" > "$key_file"
  [[ $(api "http://127.0.0.1:$port/health" /dev/null) == 200 ]] || return 1
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' "$stage/response" || return 1
  [[ $(api "http://127.0.0.1:$port/v1/models" "$key_file") == 200 ]] || return 1
  models_has "$name" < "$stage/response"
}
wait_gateway() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    gateway_healthy "$@" && return 0
    sleep 2
  done
  return 1
}
dashboard_healthy() {
  [[ $(api "http://127.0.0.1:$DASHBOARD_PORT/api/status" /dev/null) == 200 ]] || return 1
  python3 - "$stage/response" <<'PY'
import json, sys
try:
    status = json.load(open(sys.argv[1], encoding="utf-8"))
    assert status.get("auth_required") is True
    assert status.get("auth_providers")
except (OSError, ValueError, AssertionError):
    raise SystemExit(1)
PY
}
wait_dashboard() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    dashboard_healthy && return 0
    sleep 2
  done
  return 1
}
direct_healthy() {
  [[ $(api "$DIRECT_URL/healthz" /dev/null) == 200 ]] || return 1
  [[ $(api "$DIRECT_URL/v1/models" /dev/null) == 200 ]] || return 1
  models_has auto < "$stage/response"
}
wait_direct() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    direct_healthy && return 0
    sleep 2
  done
  return 1
}
run_hermes() {
  runuser -u "$HERMES_USER" -- env HOME="$HERMES_USER_HOME" HERMES_HOME="$HERMES_HOME" \
    PATH="$HERMES_USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$HERMES_BIN" "$@"
}
dashboard_config_value() {
  local value
  value=$(run_hermes config get "$1" --json 2>/dev/null || true)
  python3 -c 'import json,sys
try: value=json.load(sys.stdin)
except (ValueError, OSError): value=None
if isinstance(value,str) and value: print(value)' <<< "$value"
}
dashboard_config_has_auth() {
  [[ -z $(dashboard_config_value dashboard.oauth.client_id) ]] || return 0
  if [[ -n $(dashboard_config_value dashboard.oauth.self_hosted.issuer) &&
        -n $(dashboard_config_value dashboard.oauth.self_hosted.client_id) ]]; then return 0; fi
  if [[ -n $(dashboard_config_value dashboard.basic_auth.username) &&
        ( -n $(dashboard_config_value dashboard.basic_auth.password) ||
          -n $(dashboard_config_value dashboard.basic_auth.password_hash) ) ]]; then return 0; fi
  return 1
}
# installed_commit: the checkout's commit. It belongs to the hermes account, so
# root's git must name it safe, or git refuses it ("dubious ownership") and the
# commit reads as empty: a pinned HERMES_COMMIT then never matches.
installed_commit() {
  git -c safe.directory="$HERMES_HOME/hermes-agent" -C "$HERMES_HOME/hermes-agent" rev-parse HEAD 2>/dev/null || true
}

if [[ -x $HERMES_BIN && -f $HERMES_ETC/settings ]] &&
   [[ $(< "$HERMES_ETC/settings") == "$settings" ]] &&
   { [[ -z $HERMES_COMMIT ]] || [[ $(installed_commit) == "$HERMES_COMMIT" ]]; } &&
   run_hermes --version >/dev/null 2>&1; then
  if systemctl is-active --quiet "$DIRECT_UNIT" && direct_healthy &&
     { [[ $HERMES_API_SERVER == false ]] ||
       { systemctl is-active --quiet "$UNIT" && gateway_healthy; }; } &&
     { [[ $HERMES_DASHBOARD == false ]] ||
       { systemctl is-active --quiet "$DASHBOARD_UNIT" && dashboard_healthy; }; }; then
    rm -f -- "$ROUTER_API_KEY_FILE"
    note 'Hermes is healthy with these settings; nothing to do.'
    exit 0
  fi
  note "$UNIT is not running or not healthy; applying the settings again."
fi

# --- packages, account, Hermes itself -------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git tar coreutils libatomic1 python3 openssl util-linux
if ! id "$HERMES_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$HERMES_USER_HOME" --shell /bin/bash "$HERMES_USER"
fi
[[ $(getent passwd "$HERMES_USER" | cut -d: -f6) == "$HERMES_USER_HOME" ]] ||
  die "Existing $HERMES_USER account has a different home."
install -d -m 0700 -o "$HERMES_USER" -g "$HERMES_USER" "$HERMES_HOME"
install -d -m 0750 -o root -g "$HERMES_USER" "$HERMES_ETC"

if [[ ! -x $HERMES_BIN ]] || { [[ -n $HERMES_COMMIT ]] && [[ $(installed_commit) != "$HERMES_COMMIT" ]]; }; then
  curl --fail --silent --show-error --location --max-time 60 "$INSTALL_URL" -o "$stage/install.sh"
  installer_sha256=$(sha256sum "$stage/install.sh" | cut -d' ' -f1)
  note "Hermes installer SHA-256: $installer_sha256 (pin it with HERMES_INSTALLER_SHA256)."
  if [[ -n $HERMES_INSTALLER_SHA256 && $installer_sha256 != "$HERMES_INSTALLER_SHA256" ]]; then
    die "The downloaded installer's SHA-256 is $installer_sha256, not HERMES_INSTALLER_SHA256. Nothing was installed."
  fi
  [[ $(head -n 1 "$stage/install.sh") == '#!'*sh* ]] ||
    die 'The downloaded Hermes installer is not a shell script.'
  installer_args=(--non-interactive --skip-browser --skip-computer-use --channel "$HERMES_CHANNEL")
  [[ -z $HERMES_COMMIT ]] || installer_args+=(--commit "$HERMES_COMMIT")
  # The unprivileged account must reach the installer, but not list the
  # stage (which holds the router key, mode 0600).
  install -d -m 0755 "$stage/installer"
  install -m 0644 "$stage/install.sh" "$stage/installer/install.sh"
  chmod 0711 "$stage"
  ( cd "$stage/installer" && runuser -u "$HERMES_USER" -- env HOME="$HERMES_USER_HOME" HERMES_HOME="$HERMES_HOME" \
      PATH="$HERMES_USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
      bash "$stage/installer/install.sh" "${installer_args[@]}" {install_lock_fd}>&- )
  chmod 0700 "$stage"
fi
if [[ ! -x $HERMES_BIN ]]; then
  # The launcher's location is upstream's choice; the unit expects this path.
  found=$(runuser -u "$HERMES_USER" -- env HOME="$HERMES_USER_HOME" \
    PATH="$HERMES_USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" sh -c 'command -v hermes' 2>/dev/null || true)
  [[ -n $found && -x $found ]] || die "The Hermes launcher was not found at $HERMES_BIN or on the hermes PATH."
  install -d -m 0755 -o "$HERMES_USER" -g "$HERMES_USER" "$HERMES_USER_HOME/.local" "$HERMES_USER_HOME/.local/bin"
  ln -sfn -- "$found" "$HERMES_BIN"
fi
if [[ -n $HERMES_COMMIT && $(installed_commit) != "$HERMES_COMMIT" ]]; then
  die "The Hermes checkout is at $(installed_commit), not HERMES_COMMIT $HERMES_COMMIT."
fi

# --- configuration, with a rollback --------------------------------------------
# Everything this run changes is set aside first; a failure puts it back.
backup=$stage/backup
install -d -m 0700 "$backup"
owned_files=("$HERMES_HOME/config.yaml" "$HERMES_HOME/.env" "$UNIT_DIR/$UNIT" \
            "$UNIT_DIR/$DIRECT_UNIT" "$UNIT_DIR/$DASHBOARD_UNIT" "$DIRECT_LIB" "$HERMES_ETC/backend-keys" "$HERMES_ETC/settings" "$HERMES_ETC/targets" \
            "$HERMES_HOME/honcho.json")
[[ $honcho_key_owned == false ]] || owned_files+=("$HONCHO_API_KEY_FILE")
[[ $ot_key_owned == false ]] || owned_files+=("$OPEN_TERMINAL_KEY_FILE")
for file in "${owned_files[@]}"; do
  if [[ -f $file ]]; then cp -a -- "$file" "$backup/$(basename "$file").prev"; fi
done
gateway_was_active=0
if systemctl is-active --quiet "$UNIT" 2>/dev/null; then gateway_was_active=1; fi
direct_was_active=0
if systemctl is-active --quiet "$DIRECT_UNIT" 2>/dev/null; then direct_was_active=1; fi
dashboard_was_active=0
if systemctl is-active --quiet "$DASHBOARD_UNIT" 2>/dev/null; then dashboard_was_active=1; fi

restore() {
  local file name
  for file in "${owned_files[@]}"; do
    name=$(basename "$file")
    if [[ -f $backup/$name.prev ]]; then cp -a -- "$backup/$name.prev" "$file"; else rm -f -- "$file"; fi
  done
  systemctl daemon-reload || true
  if (( direct_was_active )); then systemctl restart "$DIRECT_UNIT" || true
  else systemctl disable --now "$DIRECT_UNIT" >/dev/null 2>&1 || true; fi
  if (( dashboard_was_active )); then systemctl restart "$DASHBOARD_UNIT" || true
  else systemctl disable --now "$DASHBOARD_UNIT" >/dev/null 2>&1 || true; fi
  if (( gateway_was_active )); then
    # Health-check the restored settings, not the ones that failed.
    local port name
    port=$(env_file_get "$HERMES_HOME/.env" API_SERVER_PORT)
    name=$(env_file_get "$HERMES_HOME/.env" API_SERVER_MODEL_NAME)
    systemctl restart "$UNIT" || true
    if wait_gateway "${port:-8642}" "${name:-hermes-agent}"; then
      note "The previous Hermes configuration is restored and $UNIT is running again."
    else
      note "The previous Hermes configuration is restored, but $UNIT did not become healthy either. Check: journalctl -u $UNIT"
    fi
  else
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    note 'The previous Hermes configuration is restored.'
  fi
}
rollback() {
  trap - ERR
  restore
}
trap '[[ $BASHPID == "$$" ]] || exit 1; rollback; exit 1' ERR

run_hermes config set model.base_url "$DIRECT_URL/v1"
run_hermes config set model.default "$HERMES_MODEL"
run_hermes config set model.context_length "$HERMES_CONTEXT_LENGTH"
# The router key stays in .env for discovery, never in a backend request.
run_hermes config set model.api_key no-key
# Named providers, so Hermes's /model switcher can pick them: custom:osr is the
# router-ranked dispatcher; each custom:<target> is one model server, reached
# by the dispatcher with no router at all. Backend keys stay in the dispatcher.
set_provider() {
  run_hermes config set "providers.$1.api" "$2"
  run_hermes config set "providers.$1.api_key" no-key
  run_hermes config set "providers.$1.transport" chat_completions
  run_hermes config set "providers.$1.context_length" "$HERMES_CONTEXT_LENGTH"
  if [[ $1 == osr && -n $kindi_targets || " $kindi_targets " == *" $1 "* ]]; then
    run_hermes config set "providers.$1.request_timeout_seconds" "$KINDI_CLIENT_TIMEOUT_SECONDS"
    run_hermes config set "providers.$1.stale_timeout_seconds" "$KINDI_CLIENT_TIMEOUT_SECONDS"
  elif [[ $1 == osr && -n $previous_kindi_targets || " $previous_kindi_targets " == *" $1 "* ]]; then
    run_hermes config unset "providers.$1.request_timeout_seconds" || true
    run_hermes config unset "providers.$1.stale_timeout_seconds" || true
  fi
}
set_provider osr "$DIRECT_URL/v1"
run_hermes config set providers.osr.default_model "$HERMES_MODEL"
mapfile -t new_targets < <(target_names "$targets_source")
for name in "${new_targets[@]}"; do set_provider "$name" "$DIRECT_URL/t/$name/v1"; done
# Providers of targets no longer registered with the router.
while IFS= read -r name; do
  [[ -n $name && " ${new_targets[*]} " != *" $name "* ]] || continue
  run_hermes config unset "providers.$name" ||
    note "Could not remove provider $name from Hermes's config.yaml; delete it there by hand."
done < <(target_names "$HERMES_ETC/targets")
run_hermes config set model.provider custom:osr
if [[ -n $HONCHO_URL ]]; then
  if ! python3 - "$HERMES_HOME/plugins/.install-metadata.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as source:
        metadata = json.load(source)
except (OSError, ValueError):
    metadata = {}
sys.exit(0 if "honcho" in metadata else 1)
PY
  then
    plugin_flags=(--enable --yes-deps)
    [[ ! -d $HERMES_HOME/plugins/honcho ]] || plugin_flags+=(--force)
    run_hermes plugins install honcho "${plugin_flags[@]}"
  fi
  python3 - "$HONCHO_API_KEY_FILE" "$HONCHO_URL" "$HERMES_HOME/honcho.json" "$honcho_workspace" <<'PY'
import json, sys
key = open(sys.argv[1], encoding="utf-8").read().strip()
data = {"apiKey": key, "baseUrl": sys.argv[2], "hosts": {"hermes": {
    "enabled": True, "aiPeer": "hermes", "peerName": "user", "workspace": sys.argv[4]}}}
with open(sys.argv[3], "w", encoding="utf-8") as f:
    json.dump(data, f)
    f.write("\n")
PY
  chown "$HERMES_USER:$HERMES_USER" "$HERMES_HOME/honcho.json"
  chmod 0600 "$HERMES_HOME/honcho.json"
  run_hermes config set memory.provider honcho
elif [[ -n $prev_honcho_url ]]; then
  # The last run set up Honcho; HONCHO_URL is now empty, so turn it off.
  run_hermes config set memory.provider builtin
  rm -f -- "$HERMES_HOME/honcho.json"
  [[ $honcho_key_owned == false ]] || rm -f -- "$HONCHO_API_KEY_FILE"
  note 'Honcho memory is off; Hermes uses its built-in memory.'
fi

# .env: the API server settings; ROUTER_API_KEY keeps the key for reruns. The
# placeholder OPENAI_API_KEY=no-key written by earlier versions is removed.
touch "$HERMES_HOME/.env"
if [[ $HERMES_API_SERVER == true ]]; then
  if [[ ! -s $HERMES_ETC/api-key ]]; then
    openssl rand -hex 32 > "$HERMES_ETC/api-key.new"
    chmod 0600 "$HERMES_ETC/api-key.new"
    mv -f -- "$HERMES_ETC/api-key.new" "$HERMES_ETC/api-key"
  fi
  ENV_SET_ROUTER_API_KEY=$router_key \
  ENV_SET_API_SERVER_ENABLED=true \
  ENV_SET_API_SERVER_HOST=0.0.0.0 \
  ENV_SET_API_SERVER_PORT=$HERMES_API_PORT \
  ENV_SET_API_SERVER_MODEL_NAME=$HERMES_API_MODEL_NAME \
  ENV_SET_API_SERVER_KEY=$(tr -d '\r\n' < "$HERMES_ETC/api-key") \
  ENV_UNSET_IF_OPENAI_API_KEY=no-key \
    env_file_update "$HERMES_HOME/.env"
else
  ENV_SET_ROUTER_API_KEY=$router_key \
  ENV_UNSET_API_SERVER_ENABLED=1 ENV_UNSET_API_SERVER_HOST=1 ENV_UNSET_API_SERVER_PORT=1 \
  ENV_UNSET_API_SERVER_MODEL_NAME=1 ENV_UNSET_API_SERVER_KEY=1 \
  ENV_UNSET_IF_OPENAI_API_KEY=no-key \
    env_file_update "$HERMES_HOME/.env"
fi
if [[ -n $kindi_targets ]]; then
  ENV_SET_HERMES_STREAM_READ_TIMEOUT=$KINDI_CLIENT_TIMEOUT_SECONDS \
  ENV_SET_HERMES_LOCAL_STREAM_STALE_TIMEOUT=$KINDI_CLIENT_TIMEOUT_SECONDS \
    env_file_update "$HERMES_HOME/.env"
elif [[ -n $previous_kindi_targets ]]; then
  ENV_UNSET_HERMES_STREAM_READ_TIMEOUT=1 ENV_UNSET_HERMES_LOCAL_STREAM_STALE_TIMEOUT=1 \
    env_file_update "$HERMES_HOME/.env"
fi
if [[ $HERMES_DASHBOARD == true &&
      -z $(env_file_get "$HERMES_HOME/.env" HERMES_DASHBOARD_OAUTH_CLIENT_ID) &&
      -z $(env_file_get "$HERMES_HOME/.env" HERMES_DASHBOARD_OIDC_CLIENT_ID) ]] &&
   ! dashboard_config_has_auth; then
  dashboard_user=$(env_file_get "$HERMES_HOME/.env" HERMES_DASHBOARD_BASIC_AUTH_USERNAME)
  dashboard_password=$(env_file_get "$HERMES_HOME/.env" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)
  dashboard_hash=$(env_file_get "$HERMES_HOME/.env" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH)
  if [[ -z $dashboard_user || ( -z $dashboard_password && -z $dashboard_hash ) ]]; then
    dashboard_user=${dashboard_user:-admin}
    dashboard_password=$(openssl rand -hex 24)
    ENV_SET_HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$dashboard_user \
    ENV_SET_HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$dashboard_password \
      env_file_update "$HERMES_HOME/.env"
    note "Generated Hermes dashboard username '$dashboard_user'; read its password from /home/hermes/.hermes/.env as root in the CT."
  fi
  if [[ -z $(env_file_get "$HERMES_HOME/.env" HERMES_DASHBOARD_BASIC_AUTH_SECRET) ]]; then
    ENV_SET_HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -hex 32) \
      env_file_update "$HERMES_HOME/.env"
  fi
  unset dashboard_user dashboard_password dashboard_hash
fi
# Open Terminal: an MCP server whose bearer key Hermes expands from .env at
# connect time, so config.yaml holds no key. Hermes's tools still run here
# as well; these add its private workspace in the terminal CT.
if [[ -n $OPEN_TERMINAL_URL ]]; then
  ENV_SET_OSR_OPEN_TERMINAL_KEY=$ot_key env_file_update "$HERMES_HOME/.env"
  run_hermes config set mcp_servers.open_terminal.url "$OPEN_TERMINAL_URL/mcp"
  # shellcheck disable=SC2016  # Hermes expands it, not the shell
  run_hermes config set mcp_servers.open_terminal.headers.Authorization 'Bearer ${OSR_OPEN_TERMINAL_KEY}'
  run_hermes config set mcp_servers.open_terminal.timeout 660
  run_hermes config set mcp_servers.open_terminal.enabled true
elif [[ -n $prev_ot_url ]]; then
  # The last run connected Open Terminal; OPEN_TERMINAL_URL is now empty.
  run_hermes config unset mcp_servers.open_terminal ||
    note 'Could not remove mcp_servers.open_terminal from config.yaml; delete it there by hand.'
  ENV_UNSET_OSR_OPEN_TERMINAL_KEY=1 env_file_update "$HERMES_HOME/.env"
  [[ $ot_key_owned == false ]] || rm -f -- "$OPEN_TERMINAL_KEY_FILE"
  note 'Open Terminal is disconnected from Hermes.'
fi
unset ot_key
chown "$HERMES_USER:$HERMES_USER" "$HERMES_HOME/.env"
chmod 0600 "$HERMES_HOME/.env"
dashboard_auth_sha256=$(dashboard_auth_hash)
settings=$(settings_record)
run_hermes --version >/dev/null

# The local dispatcher runs for both CLI and API-server installations.
if [[ -f $BACKEND_KEYS_FILE ]]; then
  install -m 0640 "$BACKEND_KEYS_FILE" "$HERMES_ETC/backend-keys"
  chown "$HERMES_USER:$HERMES_USER" "$HERMES_ETC/backend-keys"
fi
if [[ -f $TARGETS_FILE ]]; then
  install -m 0644 "$TARGETS_FILE" "$HERMES_ETC/targets"
fi
install -m 0644 "$source_dir/direct-dispatch.py" "$DIRECT_LIB"
install -m 0644 "$source_dir/$DIRECT_UNIT" "$UNIT_DIR/$DIRECT_UNIT"
printf '%s\n' "$settings" > "$HERMES_ETC/settings.new"
chmod 0640 "$HERMES_ETC/settings.new"
chown "root:$HERMES_USER" "$HERMES_ETC/settings.new"
mv -f -- "$HERMES_ETC/settings.new" "$HERMES_ETC/settings"
systemctl daemon-reload
systemctl enable "$DIRECT_UNIT" >/dev/null
systemctl restart "$DIRECT_UNIT"
if ! wait_direct; then
  trap - ERR
  note "$DIRECT_UNIT did not answer /healthz and /v1/models within ${HEALTH_TIMEOUT}s. Check: journalctl -u $DIRECT_UNIT"
  restore
  exit 1
fi
if [[ $HERMES_SKIP_CHAT_PROBE != true ]]; then
  chat_probe_body "$HERMES_MODEL" > "$stage/probe.json"
  status=$(api "$DIRECT_URL/v1/chat/completions" /dev/null "$stage/probe.json" "$CHAT_PROBE_TIMEOUT")
  if [[ $status != 200 ]]; then
    trap - ERR
    note "Direct model-server chat probe failed (HTTP $status): $(error_message < "$stage/response"). Check backend keys and that the model host admits the Hermes CT address."
    restore
    exit 1
  fi
fi

if [[ $HERMES_API_SERVER == true ]]; then
  install -m 0644 "$source_dir/$UNIT" "$UNIT_DIR/$UNIT"
  systemctl daemon-reload
  systemctl enable "$UNIT" >/dev/null
  systemctl restart "$UNIT"
  if ! wait_gateway; then
    trap - ERR
    note "$UNIT did not answer /health and /v1/models within ${HEALTH_TIMEOUT}s. Check: journalctl -u $UNIT"
    restore
    exit 1
  fi
  note "Hermes API server: http://0.0.0.0:$HERMES_API_PORT/v1 (model $HERMES_API_MODEL_NAME)."
elif [[ -f $UNIT_DIR/$UNIT ]]; then
  systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_DIR/$UNIT"
  systemctl daemon-reload
  note "$UNIT was stopped and removed (HERMES_API_SERVER=false)."
fi

if [[ $HERMES_DASHBOARD == true ]]; then
  install -m 0644 "$source_dir/$DASHBOARD_UNIT" "$UNIT_DIR/$DASHBOARD_UNIT"
  systemctl daemon-reload
  systemctl enable "$DASHBOARD_UNIT" >/dev/null
  systemctl restart "$DASHBOARD_UNIT"
  if ! wait_dashboard; then
    trap - ERR
    note "$DASHBOARD_UNIT did not answer /api/status with authentication within ${HEALTH_TIMEOUT}s. Check: journalctl -u $DASHBOARD_UNIT"
    restore
    exit 1
  fi
  note "Hermes dashboard: http://<CT-IP>:$DASHBOARD_PORT/ (login required)."
elif [[ -f $UNIT_DIR/$DASHBOARD_UNIT ]]; then
  systemctl disable --now "$DASHBOARD_UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_DIR/$DASHBOARD_UNIT"
  systemctl daemon-reload
  note "$DASHBOARD_UNIT was stopped and removed (HERMES_DASHBOARD=false)."
fi

trap - ERR
# The key now lives in Hermes's own configuration.
rm -f -- "$ROUTER_API_KEY_FILE"
commit=$(installed_commit)
note "Hermes${commit:+ $commit} discovers via $ROUTER_URL and calls model servers directly with model $HERMES_MODEL (context $HERMES_CONTEXT_LENGTH)."
[[ -n $HERMES_COMMIT || -z $commit ]] || note "Pin this version with HERMES_COMMIT=$commit."
note "Start a shell with: runuser -u $HERMES_USER -- env HOME=$HERMES_USER_HOME $HERMES_BIN"
