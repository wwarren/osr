#!/usr/bin/env bash
# Run as root in the dedicated OpenClaw LXC (provision-lxc.sh pushes this file,
# the units, the dispatcher and the router's API key). OpenClaw discovers
# models through the router but sends inference to model servers through a
# local loopback dispatcher (the Hermes target's direct-dispatch.py).
#
# OpenClaw itself is installed the way https://brax.me/openclaw/install.sh does
# it, checked against https://docs.openclaw.ai/install: nvm, Node 24 through
# nvm, then `npm install -g openclaw`. That script's Ollama step is left out:
# the router's model pool serves this agent.
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

# Paths are overridable for tests only; the units use the defaults.
OC_USER=${OC_USER:-openclaw}
OC_USER_HOME=${OC_USER_HOME:-/home/openclaw}
DIRECT_USER=${DIRECT_USER:-openclaw-direct}
OC_ETC=${OC_ETC:-/etc/openclaw-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
DIRECT_LIB=${DIRECT_LIB:-/usr/local/lib/openclaw-direct.py}
LOCK_FILE=${LOCK_FILE:-/etc/openclaw-target.lock}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-120}
# One real direct chat request with a tool, to prove auth and inference.
CHAT_PROBE_TIMEOUT=${CHAT_PROBE_TIMEOUT:-300}
# OpenClaw's prompt, tools and history need room; its managed local-model
# recipes use 64K. Below 32K an agent turn does not fit.
MIN_CONTEXT=32768
# The nvm release brax.me's script installs, and the SHA-256 of its install.sh.
DEFAULT_NVM_VERSION=v0.40.4
DEFAULT_NVM_SHA256=4b7412c49960c7d31e8df72da90c1fb5b8cccb419ac99537b737028d497aba4f
# The model OpenClaw's OpenAI-compatible endpoint lists for the default agent.
API_MODEL=openclaw

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash install-target.sh [--dry-run]

Inside an existing OpenClaw CT, a direct interactive run asks for the router
base URL when ROUTER_URL is unset. An unattended run must set ROUTER_URL.
CT ID and CT IP are chosen by provision-lxc.sh on the Proxmox host.

Installs OpenClaw (nvm, Node through nvm, npm install -g openclaw) and points
its provider "osr" at a local direct dispatcher. The dispatcher uses the
router's inventory and ranking, then calls model servers itself. Each model
server in the targets file is also a provider, <target>/<model>, that the
dispatcher reaches without the router. Rerun to change settings; an
unchanged, healthy installation is left alone.

Environment:
  ROUTER_URL                   router base URL (host and port, no /v1)
  ROUTER_API_KEY_FILE          file holding the router's ROUTER_API_KEY
                               (default: router-api-key next to this script;
                               absent: keep the key already configured)
  OPENCLAW_MODEL=auto          default model: an ID from the router's /v1/models
  OPENCLAW_CONTEXT_LENGTH=65536  context the model hosts really serve (>=32768)
  OPENCLAW_MAX_TOKENS=8192     output tokens per reply OpenClaw may ask for
  OPENCLAW_VERSION=latest      npm version or dist-tag of openclaw
  OPENCLAW_NODE_VERSION=24     Node for nvm: 24 or 26, or an exact 24.x.y/26.x.y
  NVM_VERSION=v0.40.4          nvm release to install
  NVM_INSTALLER_SHA256         refuse an nvm install.sh with another SHA-256
                               (default: the known hash of v0.40.4)
  OPENCLAW_API=false           true: enable the Gateway's /v1/chat/completions
                               (for Open WebUI) and listen on every address
  OPENCLAW_PORT=18789          Gateway port (WebSocket, Control UI, HTTP API)
  OPENCLAW_DASHBOARD=true      serve the Control UI on every CT IPv4 address
  OPEN_TERMINAL_URL            Open Terminal gateway (http://IP:port): OpenClaw's
                               own workspace there, as MCP server open-terminal;
                               empty after a run that set it disconnects it
  OPEN_TERMINAL_KEY_FILE       this CT's client key (default: open-terminal-key
                               next to this script, pushed by provision-lxc.sh)
  OPENCLAW_SKIP_CHAT_PROBE=false  true: skip the test chat request
OpenClaw updates are made with `openclaw update` as the openclaw user.
USAGE
}

# Install helpers (sourced by test-install.sh) -------------------------------

# settings_record: the settings this installation runs with. Keys are
# recorded only as hashes, so rotating one is a change.
settings_record() {
  printf 'ROUTER_URL=%s\n' "$ROUTER_URL"
  printf 'OPENCLAW_MODEL=%s\n' "$OPENCLAW_MODEL"
  printf 'OPENCLAW_CONTEXT_LENGTH=%s\n' "$OPENCLAW_CONTEXT_LENGTH"
  printf 'OPENCLAW_MAX_TOKENS=%s\n' "$OPENCLAW_MAX_TOKENS"
  printf 'KINDI_READ_TIMEOUT_SECONDS=%s\n' "${KINDI_READ_TIMEOUT_SECONDS:-3600}"
  printf 'OPENCLAW_VERSION=%s\n' "$OPENCLAW_VERSION"
  printf 'OPENCLAW_NODE_VERSION=%s\n' "$OPENCLAW_NODE_VERSION"
  printf 'NVM_VERSION=%s\n' "$NVM_VERSION"
  printf 'OPENCLAW_API=%s\n' "$OPENCLAW_API"
  printf 'OPENCLAW_PORT=%s\n' "$OPENCLAW_PORT"
  printf 'OPENCLAW_DASHBOARD=%s\n' "$OPENCLAW_DASHBOARD"
  printf 'HONCHO_URL=%s\nHONCHO_KEY_SHA256=%s\n' "$HONCHO_URL" "$honcho_key_sha256"
  printf 'OPEN_TERMINAL_URL=%s\nOPEN_TERMINAL_KEY_SHA256=%s\n' "$OPEN_TERMINAL_URL" "$ot_key_sha256"
  printf 'ORIGINS=%s\n' "$origins"
  printf 'ROUTER_KEY_SHA256=%s\n' "$router_key_sha256"
  printf 'BACKEND_KEYS_SHA256=%s\n' "$backend_keys_sha256"
  printf 'TARGETS_SHA256=%s\n' "$targets_sha256"
  printf 'PROVIDERS_SHA256=%s\n' "$providers_sha256"
  printf 'UNIT_SHA256=%s\n' "$unit_sha256"
}

# env_file_update FILE: set or remove KEY=VALUE lines in a dotenv file. The
# changes come from the environment (ENV_SET_<KEY>=value sets, ENV_UNSET_<KEY>
# removes), never from argv.
env_file_update() {
  python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
sets = {k[len("ENV_SET_"):]: v for k, v in os.environ.items() if k.startswith("ENV_SET_")}
unsets = {k[len("ENV_UNSET_"):] for k in os.environ if k.startswith("ENV_UNSET_")}
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

# version_of < TEXT: the first version number in `node -v` or
# `openclaw --version` output (v24.22.1 -> 24.22.1; 2026.10.9-beta.5 kept).
version_of() {
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -n 1 || true
}

# node_supported VERSION: this target's security floor, per the official docs.
node_supported() {
  python3 - "$1" <<'PY'
import re, sys
m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
if not m:
    sys.exit(1)
v = tuple(int(x) for x in m.groups())
sys.exit(0 if (24, 22, 1) <= v < (25, 0, 0) or v >= (26, 12, 1) else 1)
PY
}

# node_spec_matches VERSION SPEC: is the installed Node what OPENCLAW_NODE_VERSION asks for?
node_spec_matches() {
  if [[ $2 == *.* ]]; then [[ $1 == "$2" ]]; else [[ ${1%%.*} == "$2" ]]; fi
}

# exact_version SPEC: is OPENCLAW_VERSION an exact release (not a dist-tag)?
exact_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; }

# origins_json PORT IP...: the Control UI's allowed browser origins.
origins_json() {
  python3 -c 'import json,sys
port = sys.argv[1]
print(json.dumps([f"http://{ip}:{port}" for ip in sys.argv[2:]], separators=(",", ":")))' "$@"
}

# providers_json CONTEXT MAX_TOKENS DIRECT_URL PREVIOUS NAME=MODELS_FILE...: the
# models.providers entries. "osr" is the router-ranked dispatcher; every other
# NAME is one model server under DIRECT_URL/t/NAME. MODELS_FILE is that
# endpoint's /v1/models answer, or "-" when it could not be listed: then the
# entry in PREVIOUS (the last providers written, or "-") is kept, so a model
# server that is down for a moment keeps its provider. KINDI_TARGETS names the
# Kindi targets (space-separated): those, and osr while there are any, get
# KINDI_CLIENT_TIMEOUT_SECONDS as timeoutSeconds. Kindi reads a long prompt
# slowly and sends nothing until it has read it, which OpenClaw's own
# first-event limit (5 minutes for a local endpoint) would otherwise cut off.
# OpenClaw uses timeoutSeconds both as its silence limit and as a deadline for
# the whole request, so the value covers a silent read of the full Kindi budget
# twice over plus a full reply at one token a second. The dispatcher still
# bounds every server's silence at its own read timeout.
providers_json() {
  python3 - "$@" <<'PY'
import json, os, sys
context, max_tokens, direct = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3].rstrip("/")
kindi_targets = set(os.environ.get("KINDI_TARGETS", "").split())
kindi_client_timeout = int(os.environ.get("KINDI_CLIENT_TIMEOUT_SECONDS", "7200"))
previous = {}
if sys.argv[4] != "-":
    try:
        with open(sys.argv[4], encoding="utf-8") as f:
            previous = json.load(f)
    except (OSError, ValueError):
        previous = {}
out = {}
for item in sys.argv[5:]:
    name, _, path = item.partition("=")
    if path == "-":
        if isinstance(previous.get(name), dict):
            out[name] = previous[name]
        continue
    with open(path, encoding="utf-8") as f:
        listed = json.load(f)
    ids = sorted({m["id"] for m in listed.get("data") or []
                  if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"]})
    if name == "osr" and "auto" in ids:
        ids = ["auto"] + [i for i in ids if i != "auto"]
    if not ids:
        continue
    base = f"{direct}/v1" if name == "osr" else f"{direct}/t/{name}/v1"
    # Tool calls are what the agent is for; max_tokens is the field every
    # pool server (Ollama, llama.cpp, vLLM-style) accepts.
    out[name] = {"baseUrl": base, "apiKey": "no-key", "api": "openai-completions",
                 "models": [{"id": i, "name": i, "input": ["text"], "contextWindow": context,
                             "maxTokens": max_tokens,
                             "compat": {"supportsTools": True, "maxTokensField": "max_tokens"}}
                            for i in ids]}
    if name in kindi_targets or (name == "osr" and kindi_targets):
        out[name]["timeoutSeconds"] = kindi_client_timeout
print(json.dumps(out, sort_keys=True, separators=(",", ":")))
PY
}

# provider_ids < PROVIDERS JSON: the provider names, one per line.
provider_ids() {
  python3 -c 'import json,sys
try: data = json.load(sys.stdin)
except ValueError: data = {}
print("\n".join(sorted(data)))'
}

# provider_entry ID < PROVIDERS JSON: one provider entry as compact JSON.
provider_entry() {
  python3 -c 'import json,sys
print(json.dumps(json.load(sys.stdin)[sys.argv[1]], separators=(",", ":")))' "$1"
}
# kindi_target_names TARGETS_FILE: the names of its Kindi servers (NAME=SERVER).
kindi_target_names() { [[ -f $1 ]] && awk -F= '$2 ~ /^kindi[+]/ {print $1}' "$1" || true; }
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
OPENCLAW_MODEL=${OPENCLAW_MODEL:-auto}
OPENCLAW_CONTEXT_LENGTH=${OPENCLAW_CONTEXT_LENGTH:-65536}
OPENCLAW_MAX_TOKENS=${OPENCLAW_MAX_TOKENS:-8192}
OPENCLAW_VERSION=${OPENCLAW_VERSION:-latest}
OPENCLAW_NODE_VERSION=${OPENCLAW_NODE_VERSION:-24}
NVM_VERSION=${NVM_VERSION:-$DEFAULT_NVM_VERSION}
if [[ -z ${NVM_INSTALLER_SHA256+set} ]]; then
  NVM_INSTALLER_SHA256=''
  [[ $NVM_VERSION != "$DEFAULT_NVM_VERSION" ]] || NVM_INSTALLER_SHA256=$DEFAULT_NVM_SHA256
fi
OPENCLAW_API=${OPENCLAW_API:-false}
OPENCLAW_PORT=${OPENCLAW_PORT:-18789}
OPENCLAW_DASHBOARD=${OPENCLAW_DASHBOARD:-true}
HONCHO_URL=${HONCHO_URL:-}
HONCHO_API_KEY_FILE=${HONCHO_API_KEY_FILE:-$source_dir/honcho-api-key}
honcho_key_owned=false
[[ $HONCHO_API_KEY_FILE != "$source_dir/honcho-api-key" ]] || honcho_key_owned=true
# Open Terminal: OpenClaw's own workspace in the terminal CT, reached as MCP
# tools (the gateway's /mcp) with this CT's client key.
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL:-}
OPEN_TERMINAL_KEY_FILE=${OPEN_TERMINAL_KEY_FILE:-$source_dir/open-terminal-key}
ot_key_owned=false
[[ $OPEN_TERMINAL_KEY_FILE != "$source_dir/open-terminal-key" ]] || ot_key_owned=true
OPENCLAW_SKIP_CHAT_PROBE=${OPENCLAW_SKIP_CHAT_PROBE:-false}
OC_STATE=$OC_USER_HOME/.openclaw
OC_CONFIG=$OC_STATE/openclaw.json
OC_ENV=$OC_STATE/.env
OC_BIN=$OC_USER_HOME/.local/bin/openclaw
NODE_LINK=$OC_USER_HOME/.local/bin/node
NVM_DIR=$OC_USER_HOME/.nvm
NVM_INSTALL_URL=https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh
UNIT=openclaw-gateway.service
DIRECT_UNIT=openclaw-direct.service
DIRECT_URL=http://127.0.0.1:8765
BACKEND_KEYS_FILE=${BACKEND_KEYS_FILE:-$source_dir/backend-keys}
# NAME=SERVER per model server, from the router's inventory (provision-lxc.sh).
TARGETS_FILE=${TARGETS_FILE:-$source_dir/targets}
# target_names FILE: the direct target names in a targets file.
target_names() { [[ -f $1 ]] && cut -d= -f1 "$1" || true; }
# This run's targets: the pushed file, else the installed one.
targets_source=$TARGETS_FILE
[[ -f $targets_source ]] || targets_source=$OC_ETC/targets
KINDI_READ_TIMEOUT_SECONDS=${KINDI_READ_TIMEOUT_SECONDS:-3600}
[[ $KINDI_READ_TIMEOUT_SECONDS =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid KINDI_READ_TIMEOUT_SECONDS.'
# The Gateway listens on every address when Open WebUI or a browser needs it.
bind=loopback
[[ $OPENCLAW_API != true && $OPENCLAW_DASHBOARD != true ]] || bind=lan

if [[ -z $ROUTER_URL && ${NONINTERACTIVE:-false} != true && -t 0 ]]; then
  IFS= read -r -p 'Router base URL (http(s)://router-address:port): ' ROUTER_URL ||
    die 'No router URL was entered.'
fi
[[ -n $ROUTER_URL ]] ||
  die 'ROUTER_URL is unset. Resume from the Proxmox host with provision-lxc.sh --reconfigure; unattended guest runs must set ROUTER_URL=http://router-address:8000.'
[[ $ROUTER_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] ||
  die 'ROUTER_URL must be an HTTP(S) host and port, such as http://router-address:8000.'
ROUTER_URL=${ROUTER_URL%/}
[[ -z $HONCHO_URL || $HONCHO_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] || die 'Invalid HONCHO_URL.'
HONCHO_URL=${HONCHO_URL%/}
[[ -z $OPEN_TERMINAL_URL || $OPEN_TERMINAL_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] || die 'Invalid OPEN_TERMINAL_URL.'
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL%/}
[[ $OPENCLAW_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid OPENCLAW_MODEL.'
[[ $OPENCLAW_CONTEXT_LENGTH =~ ^[1-9][0-9]{4,6}$ ]] && (( OPENCLAW_CONTEXT_LENGTH >= MIN_CONTEXT )) ||
  die "OPENCLAW_CONTEXT_LENGTH must be at least $MIN_CONTEXT: OpenClaw's prompt, tools and history need it. The model's host must serve that much too."
[[ $OPENCLAW_MAX_TOKENS =~ ^[1-9][0-9]{2,6}$ ]] && (( OPENCLAW_MAX_TOKENS >= 256 && OPENCLAW_MAX_TOKENS * 2 <= OPENCLAW_CONTEXT_LENGTH )) ||
  die 'OPENCLAW_MAX_TOKENS must be at least 256 and at most half of OPENCLAW_CONTEXT_LENGTH.'
# OpenClaw's whole-request deadline for Kindi: see providers_json.
KINDI_CLIENT_TIMEOUT_SECONDS=$((KINDI_READ_TIMEOUT_SECONDS * 2 + OPENCLAW_MAX_TOKENS))
[[ $OPENCLAW_VERSION =~ ^([a-z][a-z0-9-]{0,31}|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?)$ ]] ||
  die 'OPENCLAW_VERSION must be an npm dist-tag (latest, beta) or an exact version such as 2026.10.9.'
[[ $OPENCLAW_NODE_VERSION =~ ^(24|26)(\.[0-9]+\.[0-9]+)?$ ]] ||
  die 'OPENCLAW_NODE_VERSION must be 24 or 26, or an exact 24.x.y or 26.x.y (OpenClaw supports no other Node line).'
if [[ $OPENCLAW_NODE_VERSION == *.* ]]; then
  node_supported "$OPENCLAW_NODE_VERSION" ||
    die "Node $OPENCLAW_NODE_VERSION is below this target's security floor (24.22.1 on the 24 line, 26.12.1 on 26)."
fi
[[ $NVM_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'NVM_VERSION must be an nvm release tag such as v0.40.4.'
[[ -z $NVM_INSTALLER_SHA256 || $NVM_INSTALLER_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
  die 'NVM_INSTALLER_SHA256 must be 64 lowercase hex digits.'
[[ $OPENCLAW_API =~ ^(true|false)$ ]] || die 'OPENCLAW_API must be true or false.'
[[ $OPENCLAW_DASHBOARD =~ ^(true|false)$ ]] || die 'OPENCLAW_DASHBOARD must be true or false.'
[[ $OPENCLAW_SKIP_CHAT_PROBE =~ ^(true|false)$ ]] || die 'OPENCLAW_SKIP_CHAT_PROBE must be true or false.'
[[ $OPENCLAW_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( OPENCLAW_PORT <= 65535 )) || die 'Invalid OPENCLAW_PORT.'
(( OPENCLAW_PORT != 8765 )) || die 'OPENCLAW_PORT 8765 is the local dispatcher.'
[[ $HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid HEALTH_TIMEOUT.'
[[ $CHAT_PROBE_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid CHAT_PROBE_TIMEOUT.'
for path_var in OC_USER_HOME OC_ETC UNIT_DIR LOCK_FILE DIRECT_LIB; do
  [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
for user_var in OC_USER DIRECT_USER; do
  [[ ${!user_var} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid $user_var."
done
[[ -r $source_dir/$UNIT && -r $source_dir/$DIRECT_UNIT && -r $source_dir/direct-dispatch.py ]] ||
  die 'Missing the OpenClaw units or direct dispatcher (provision-lxc.sh pushes them).'

if (( dry_run )); then
  printf '+ verify %s/v1/models (with the router API key) advertises %s\n' "$ROUTER_URL" "$OPENCLAW_MODEL"
  printf '+ apt-get install ca-certificates curl git tar xz-utils coreutils python3 openssl util-linux iproute2\n'
  printf '+ create unprivileged users %s (agent) and %s (dispatcher)\n' "$OC_USER" "$DIRECT_USER"
  printf '+ as %s: nvm %s from %s (SHA-256 %s), nvm install %s, npm install -g openclaw@%s\n' \
    "$OC_USER" "$NVM_VERSION" "$NVM_INSTALL_URL" "${NVM_INSTALLER_SHA256:-unchecked}" \
    "$OPENCLAW_NODE_VERSION" "$OPENCLAW_VERSION"
  printf '+ install %s, start %s; discover models via the router and dispatch inference directly\n' \
    "$DIRECT_LIB" "$DIRECT_UNIT"
  [[ $OPENCLAW_SKIP_CHAT_PROBE == true ]] ||
    printf '+ send one chat request offering a tool through the local dispatcher to a model server (model %s)\n' "$OPENCLAW_MODEL"
  printf '+ configure provider osr (baseUrl %s/v1, api openai-completions, apiKey <local placeholder>), model osr/%s, contextWindow %s\n' \
    "$DIRECT_URL" "$OPENCLAW_MODEL" "$OPENCLAW_CONTEXT_LENGTH"
  printf '+ configure direct providers <target> (baseUrl %s/t/<target>/v1) for: %s\n' \
    "$DIRECT_URL" "$(target_names "$targets_source" | paste -sd' ' - | sed 's/^$/none/')"
  printf '+ Gateway on port %s, bind %s, token auth (key in %s/api-key and %s)\n' \
    "$OPENCLAW_PORT" "$bind" "$OC_ETC" "$OC_ENV"
  if [[ $OPENCLAW_API == true ]]; then
    printf '+ enable /v1/chat/completions; Open WebUI model %s\n' "$API_MODEL"
  else
    printf '+ /v1/chat/completions stays disabled\n'
  fi
  if [[ $OPENCLAW_DASHBOARD == true ]]; then
    printf '+ Control UI on http://<CT IPv4 addresses>:%s/ (Gateway token, then device pairing)\n' "$OPENCLAW_PORT"
  else
    printf '+ Control UI disabled\n'
  fi
  if [[ -n $OPEN_TERMINAL_URL ]]; then
    printf '+ check %s/osr/v1/whoami with this CT'\''s key; MCP server open-terminal at %s/mcp (key in %s)\n' \
      "$OPEN_TERMINAL_URL" "$OPEN_TERMINAL_URL" "$OC_ENV"
  fi
  printf '+ install %s/%s, enable and start it, wait for /healthz\n' "$UNIT_DIR" "$UNIT"
  exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the OpenClaw CT.'
# A minimal Debian template may not have Python or curl, which the router
# probes need. Install only these before touching OpenClaw.
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v flock >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl python3 util-linux
fi

# One run at a time. The lock is released when this shell exits.
exec {install_lock_fd}>>"$LOCK_FILE"
flock -n "$install_lock_fd" || die "Another install-target.sh run holds $LOCK_FILE."

stage=$(mktemp -d "${TMPDIR:-/tmp}/openclaw-target.XXXXXX")
cleanup() { rm -rf -- "$stage"; }
trap cleanup EXIT

# --- the router key: the pushed file, else the one already configured ----------
router_key=''
key_source='none'
if [[ -f $ROUTER_API_KEY_FILE ]]; then
  router_key=$(tr -d '\r\n' < "$ROUTER_API_KEY_FILE")
  key_source=$ROUTER_API_KEY_FILE
elif [[ -f $OC_ETC/router.env ]]; then
  router_key=$(env_file_get "$OC_ETC/router.env" ROUTER_API_KEY | tr -d '\r\n')
  [[ -z $router_key ]] || key_source="$OC_ETC/router.env"
fi
[[ -z $router_key || $router_key =~ ^[A-Za-z0-9._~+/=-]{8,512}$ ]] ||
  die "The router API key in ${ROUTER_API_KEY_FILE} has unexpected characters."
router_key_sha256=none
honcho_key_sha256=none
# The Honcho URL of the last completed run, read before this run rewrites the
# settings: an empty HONCHO_URL turns off only a Honcho this target set up.
prev_honcho_url=$(env_file_get "$OC_ETC/settings" HONCHO_URL 2>/dev/null || true)
if [[ -n $HONCHO_URL ]]; then
  [[ -s $HONCHO_API_KEY_FILE ]] || die "HONCHO_URL needs $HONCHO_API_KEY_FILE."
  honcho_key_sha256=$(sha256sum "$HONCHO_API_KEY_FILE" | cut -d' ' -f1)
fi
ot_key_sha256=none
ot_key=''
prev_ot_url=$(env_file_get "$OC_ETC/settings" OPEN_TERMINAL_URL 2>/dev/null || true)
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
  ! grep -q '^osr=' "$targets_source" || die "$targets_source names a target osr, which is the router's provider."
  targets_sha256=$(sha256sum "$targets_source" | cut -d' ' -f1)
fi
backend_keys_sha256=none
if [[ -f $BACKEND_KEYS_FILE ]]; then
  backend_keys_sha256=$(sha256sum "$BACKEND_KEYS_FILE" | cut -d' ' -f1)
elif [[ -f $OC_ETC/backend-keys ]]; then
  backend_keys_sha256=$(sha256sum "$OC_ETC/backend-keys" | cut -d' ' -f1)
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
models_has "$OPENCLAW_MODEL" < "$stage/response" ||
  die "The router does not advertise model '$OPENCLAW_MODEL'. Choose one from $ROUTER_URL/v1/models."

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

# --- health checks and the commands they need ---------------------------------
run_as_oc() {
  runuser -u "$OC_USER" -- env HOME="$OC_USER_HOME" USER="$OC_USER" NVM_DIR="$NVM_DIR" \
    PATH="$OC_USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}
run_oc() { run_as_oc "$OC_BIN" "$@"; }
installed_openclaw() { { run_oc --version 2>/dev/null || true; } | version_of; }
installed_node() { [[ -x $NODE_LINK ]] && "$NODE_LINK" -v 2>/dev/null | version_of || true; }
# ct_ipv4s: this CT's global IPv4 addresses, for the Control UI's origins.
ct_ipv4s() { ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u; }

# gateway_healthy [PORT API DASHBOARD]: /healthz is live; with the API, the
# token lists the agent model; with the dashboard, the Control UI is served.
# Defaults: the settings of this run.
gateway_healthy() {
  local port=${1:-$OPENCLAW_PORT} with_api=${2:-$OPENCLAW_API} with_ui=${3:-$OPENCLAW_DASHBOARD}
  local key_file=$stage/gateway-auth
  [[ -s $OC_ETC/api-key ]] || return 1
  printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$OC_ETC/api-key")" > "$key_file"
  [[ $(api "http://127.0.0.1:$port/healthz" /dev/null) == 200 ]] || return 1
  grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' "$stage/response" || return 1
  if [[ $with_api == true ]]; then
    [[ $(api "http://127.0.0.1:$port/v1/models" "$key_file") == 200 ]] || return 1
    models_has "$API_MODEL" < "$stage/response" || return 1
  fi
  if [[ $with_ui == true ]]; then
    [[ $(api "http://127.0.0.1:$port/" /dev/null) == 200 ]] || return 1
  fi
}
wait_gateway() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    gateway_healthy "$@" && return 0
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
# build_providers OUT: the providers for this run, listed by the running
# dispatcher: osr, then each direct target.
build_providers() {
  local out=$1 name previous=- n=0
  local -a lists=()
  [[ ! -s $OC_ETC/providers.json ]] || previous=$OC_ETC/providers.json
  if [[ $(api "$DIRECT_URL/v1/models" /dev/null) == 200 ]]; then
    cp "$stage/response" "$stage/models-osr.json"; lists+=("osr=$stage/models-osr.json")
  else
    lists+=("osr=-")
  fi
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    n=$((n + 1))
    if [[ $(api "$DIRECT_URL/t/$name/v1/models" /dev/null) == 200 ]]; then
      cp "$stage/response" "$stage/models-$n.json"; lists+=("$name=$stage/models-$n.json")
    else
      note "Could not list the models of $name ($(error_message < "$stage/response")); keeping its previous provider, if any."
      lists+=("$name=-")
    fi
  done < <(target_names "$targets_source")
  KINDI_TARGETS="$(kindi_target_names "$targets_source" | paste -sd' ' -)" \
    KINDI_CLIENT_TIMEOUT_SECONDS="$KINDI_CLIENT_TIMEOUT_SECONDS" \
    providers_json "$OPENCLAW_CONTEXT_LENGTH" "$OPENCLAW_MAX_TOKENS" "$DIRECT_URL" "$previous" "${lists[@]}" > "$out"
}

# --- unchanged and healthy: nothing to do ---------------------------------------
unit_sha256=$(cat "$source_dir/$UNIT" "$source_dir/$DIRECT_UNIT" "$source_dir/direct-dispatch.py" | sha256sum | cut -d' ' -f1)
origins='[]'
if [[ $OPENCLAW_DASHBOARD == true ]]; then
  mapfile -t ct_addresses < <(ct_ipv4s)
  (( ${#ct_addresses[@]} )) || die 'Cannot list this CT'"'"'s IPv4 addresses for the Control UI; set OPENCLAW_DASHBOARD=false or fix the network.'
  origins=$(origins_json "$OPENCLAW_PORT" "${ct_addresses[@]}")
fi
providers_sha256=pending
if [[ -x $OC_BIN && -f $OC_ETC/settings ]] &&
   { ! exact_version "$OPENCLAW_VERSION" || [[ $(installed_openclaw) == "$OPENCLAW_VERSION" ]]; } &&
   [[ -n $(installed_openclaw) ]] &&
   systemctl is-active --quiet "$DIRECT_UNIT" && direct_healthy; then
  build_providers "$stage/providers.json"
  providers_sha256=$(sha256sum "$stage/providers.json" | cut -d' ' -f1)
  if [[ $(< "$OC_ETC/settings") == "$(settings_record)" ]]; then
    if systemctl is-active --quiet "$UNIT" && gateway_healthy; then
      rm -f -- "$ROUTER_API_KEY_FILE"
      note 'OpenClaw is healthy with these settings; nothing to do.'
      exit 0
    fi
    note "$UNIT is not running or not healthy; applying the settings again."
  fi
fi

# --- packages, accounts, Node and OpenClaw --------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git tar xz-utils coreutils python3 openssl util-linux iproute2
if ! id "$OC_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$OC_USER_HOME" --shell /bin/bash "$OC_USER"
fi
[[ $(getent passwd "$OC_USER" | cut -d: -f6) == "$OC_USER_HOME" ]] ||
  die "Existing $OC_USER account has a different home."
if ! id "$DIRECT_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$DIRECT_USER"
fi
install -d -m 0700 -o "$OC_USER" -g "$OC_USER" "$OC_STATE"
install -d -m 0755 -o "$OC_USER" -g "$OC_USER" "$OC_USER_HOME/.local" "$OC_USER_HOME/.local/bin"
install -d -m 0750 -o root -g "$DIRECT_USER" "$OC_ETC"

node_now=$(installed_node)
need_nvm=0 need_node=0 need_openclaw=0
[[ -s $NVM_DIR/nvm.sh ]] || need_nvm=1
if [[ -z $node_now ]] || ! node_supported "$node_now" || ! node_spec_matches "$node_now" "$OPENCLAW_NODE_VERSION"; then
  need_node=1
fi
if (( need_node )) || [[ ! -x $OC_BIN ]] || [[ -z $(installed_openclaw) ]] ||
   { exact_version "$OPENCLAW_VERSION" && [[ $(installed_openclaw) != "$OPENCLAW_VERSION" ]]; }; then
  need_openclaw=1
fi
if (( need_nvm || need_node || need_openclaw )); then
  install -d -m 0755 "$stage/installer"
  if (( need_nvm )); then
    curl --fail --silent --show-error --location --max-time 60 "$NVM_INSTALL_URL" -o "$stage/nvm-install.sh"
    nvm_sha256=$(sha256sum "$stage/nvm-install.sh" | cut -d' ' -f1)
    note "nvm $NVM_VERSION installer SHA-256: $nvm_sha256."
    if [[ -n $NVM_INSTALLER_SHA256 && $nvm_sha256 != "$NVM_INSTALLER_SHA256" ]]; then
      die "The downloaded nvm installer's SHA-256 is $nvm_sha256, not NVM_INSTALLER_SHA256. Nothing was installed."
    fi
    [[ $(head -n 1 "$stage/nvm-install.sh") == '#!'*sh* ]] || die 'The downloaded nvm installer is not a shell script.'
    install -m 0644 "$stage/nvm-install.sh" "$stage/installer/nvm-install.sh"
  fi
  # The steps of brax.me's install.sh, as the unprivileged account, minus its
  # Ollama install. nvm.sh is not written for set -e or set -u, so each step
  # is checked by hand. PROFILE=/dev/null: nvm leaves the shell profile alone.
  cat > "$stage/installer/runtime.sh" <<'RUNTIME'
export PROFILE=/dev/null
if [[ $NEED_NVM == 1 ]]; then bash "$NVM_INSTALLER" || exit 1; fi
. "$NVM_DIR/nvm.sh" --no-use
command -v nvm >/dev/null || { echo "nvm did not load from $NVM_DIR" >&2; exit 1; }
if [[ $NEED_NODE == 1 ]]; then
  nvm install "$NODE_SPEC" || exit 1
  nvm alias default "$NODE_SPEC" || exit 1
fi
nvm use default >/dev/null || exit 1
if [[ $NEED_OPENCLAW == 1 ]]; then
  # npm 12 blocks package lifecycle scripts by default. npm 11.16+ accepts
  # --allow-scripts, while npm 11.15 and older reject the option.
  npm_version=$(npm --version) || exit 1
  [[ $npm_version =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]] || {
    echo "Cannot parse npm version: $npm_version" >&2; exit 1;
  }
  npm_args=(-g --no-fund --no-audit)
  if (( BASH_REMATCH[1] >= 12 || (BASH_REMATCH[1] == 11 && BASH_REMATCH[2] >= 16) )); then
    npm_args+=(--allow-scripts=openclaw)
  fi
  npm install "${npm_args[@]}" "openclaw@$OPENCLAW_SPEC" || exit 1
fi
RUNTIME
  chmod 0644 "$stage/installer/runtime.sh"
  # The unprivileged account must reach the installer, but not list the
  # stage (which holds the router key, mode 0600).
  chmod 0711 "$stage"
  note "Installing for $OC_USER:$( (( need_nvm )) && printf ' nvm %s,' "$NVM_VERSION")$( (( need_node )) && printf ' Node %s,' "$OPENCLAW_NODE_VERSION") openclaw@$OPENCLAW_VERSION."
  ( cd "$stage/installer" && run_as_oc env NEED_NVM="$need_nvm" NEED_NODE="$need_node" NEED_OPENCLAW="$need_openclaw" \
      NVM_INSTALLER="$stage/installer/nvm-install.sh" NODE_SPEC="$OPENCLAW_NODE_VERSION" \
      OPENCLAW_SPEC="$OPENCLAW_VERSION" bash "$stage/installer/runtime.sh" {install_lock_fd}>&- )
  chmod 0700 "$stage"
  # Stable paths for the unit and for root: links into nvm's default Node.
  node_path=$(run_as_oc bash -c '. "$NVM_DIR/nvm.sh" --no-use; nvm which default' 2>/dev/null | tail -n 1)
  [[ $node_path == "$NVM_DIR"/*/bin/node && -x $node_path ]] || die "nvm reports no usable default Node (got '$node_path')."
  node_dir=$(dirname -- "$node_path")
  for tool in node npm npx openclaw; do
    [[ -e $node_dir/$tool ]] || continue
    ln -sfn -- "$node_dir/$tool" "$OC_USER_HOME/.local/bin/$tool"
  done
fi
node_now=$(installed_node)
[[ -n $node_now ]] && node_supported "$node_now" ||
  die "Node ${node_now:-(none)} is below this target's security floor (>=24.22.1 <25 or >=26.12.1)."
[[ -x $OC_BIN && -n $(installed_openclaw) ]] || die "openclaw is not runnable at $OC_BIN."
if exact_version "$OPENCLAW_VERSION" && [[ $(installed_openclaw) != "$OPENCLAW_VERSION" ]]; then
  die "OpenClaw $(installed_openclaw) is installed, not OPENCLAW_VERSION $OPENCLAW_VERSION."
fi

# --- configuration, with a rollback --------------------------------------------
# Everything this run changes is set aside first; a failure puts it back.
backup=$stage/backup
install -d -m 0700 "$backup"
owned_files=("$OC_CONFIG" "$OC_ENV" "$UNIT_DIR/$UNIT" "$UNIT_DIR/$DIRECT_UNIT" "$DIRECT_LIB"
  "$OC_ETC/backend-keys" "$OC_ETC/router.env" "$OC_ETC/settings" "$OC_ETC/targets" "$OC_ETC/providers.json"
  "$OC_USER_HOME/.honcho/config.json")
[[ $honcho_key_owned == false ]] || owned_files+=("$HONCHO_API_KEY_FILE")
[[ $ot_key_owned == false ]] || owned_files+=("$OPEN_TERMINAL_KEY_FILE")
for file in "${owned_files[@]}"; do
  if [[ -f $file ]]; then cp -a -- "$file" "$backup/$(basename "$file").prev"; fi
done
gateway_was_active=0
if systemctl is-active --quiet "$UNIT" 2>/dev/null; then gateway_was_active=1; fi
direct_was_active=0
if systemctl is-active --quiet "$DIRECT_UNIT" 2>/dev/null; then direct_was_active=1; fi

restore() {
  local file name port with_api with_ui
  for file in "${owned_files[@]}"; do
    name=$(basename "$file")
    if [[ -f $backup/$name.prev ]]; then cp -a -- "$backup/$name.prev" "$file"; else rm -f -- "$file"; fi
  done
  systemctl daemon-reload || true
  if (( direct_was_active )); then systemctl restart "$DIRECT_UNIT" || true
  else systemctl disable --now "$DIRECT_UNIT" >/dev/null 2>&1 || true; fi
  if (( gateway_was_active )); then
    # Health-check the restored settings, not the ones that failed.
    port=$(env_file_get "$OC_ETC/settings" OPENCLAW_PORT)
    with_api=$(env_file_get "$OC_ETC/settings" OPENCLAW_API)
    with_ui=$(env_file_get "$OC_ETC/settings" OPENCLAW_DASHBOARD)
    systemctl restart "$UNIT" || true
    if wait_gateway "${port:-18789}" "${with_api:-false}" "${with_ui:-false}"; then
      note "The previous OpenClaw configuration is restored and $UNIT is running again."
    else
      note "The previous OpenClaw configuration is restored, but $UNIT did not become healthy either. Check: journalctl -u $UNIT"
    fi
  else
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    note 'The previous OpenClaw configuration is restored.'
  fi
}
rollback() {
  trap - ERR
  restore
}
trap '[[ $BASHPID == "$$" ]] || exit 1; rollback; exit 1' ERR

# fail MESSAGE: undo this run and stop.
fail() {
  trap - ERR
  note "$1"
  restore
  exit 1
}

# 1. The dispatcher: its keys and settings, readable by its own account only.
if [[ -f $BACKEND_KEYS_FILE ]]; then
  install -m 0640 "$BACKEND_KEYS_FILE" "$OC_ETC/backend-keys"
  chown "root:$DIRECT_USER" "$OC_ETC/backend-keys"
fi
if [[ -f $TARGETS_FILE ]]; then
  install -m 0644 "$TARGETS_FILE" "$OC_ETC/targets"
fi
touch "$OC_ETC/router.env"
ENV_SET_ROUTER_API_KEY=$router_key env_file_update "$OC_ETC/router.env"
chown "root:$DIRECT_USER" "$OC_ETC/router.env"
chmod 0640 "$OC_ETC/router.env"
write_settings() {
  printf '%s\n' "$(settings_record)" > "$OC_ETC/settings.new"
  chmod 0640 "$OC_ETC/settings.new"
  chown "root:$DIRECT_USER" "$OC_ETC/settings.new"
  mv -f -- "$OC_ETC/settings.new" "$OC_ETC/settings"
}
providers_sha256=pending
write_settings
install -m 0644 "$source_dir/direct-dispatch.py" "$DIRECT_LIB"
install -m 0644 "$source_dir/$DIRECT_UNIT" "$UNIT_DIR/$DIRECT_UNIT"
systemctl daemon-reload
systemctl enable "$DIRECT_UNIT" >/dev/null
systemctl restart "$DIRECT_UNIT"
wait_direct ||
  fail "$DIRECT_UNIT did not answer /healthz and /v1/models within ${HEALTH_TIMEOUT}s. Check: journalctl -u $DIRECT_UNIT"
if [[ $OPENCLAW_SKIP_CHAT_PROBE != true ]]; then
  chat_probe_body "$OPENCLAW_MODEL" > "$stage/probe.json"
  status=$(api "$DIRECT_URL/v1/chat/completions" /dev/null "$stage/probe.json" "$CHAT_PROBE_TIMEOUT")
  [[ $status == 200 ]] ||
    fail "Direct model-server chat probe failed (HTTP $status): $(error_message < "$stage/response"). Check backend keys and that the model host admits the OpenClaw CT address."
fi

# 2. The providers the dispatcher lists.
build_providers "$stage/providers.json"
mapfile -t new_providers < <(provider_ids < "$stage/providers.json")
[[ " ${new_providers[*]} " == *" osr "* ]] || fail 'The local dispatcher lists no usable model for provider osr.'
python3 -c 'import json,sys
models = json.load(open(sys.argv[1]))["osr"]["models"]
sys.exit(0 if any(m["id"] == sys.argv[2] for m in models) else 1)' "$stage/providers.json" "$OPENCLAW_MODEL" ||
  fail "The local dispatcher does not offer OPENCLAW_MODEL '$OPENCLAW_MODEL' (no tool support or less than $OPENCLAW_CONTEXT_LENGTH tokens of context on every server)."
providers_sha256=$(sha256sum "$stage/providers.json" | cut -d' ' -f1)

# 3. OpenClaw's configuration. The Gateway token lives in OpenClaw's .env
# (OPENCLAW_GATEWAY_TOKEN), referenced from the config, never in argv.
if [[ ! -f $OC_CONFIG ]]; then
  run_oc setup --baseline
fi
if [[ ! -s $OC_ETC/api-key ]]; then
  openssl rand -hex 32 > "$OC_ETC/api-key.new"
  chmod 0600 "$OC_ETC/api-key.new"
  mv -f -- "$OC_ETC/api-key.new" "$OC_ETC/api-key"
fi
touch "$OC_ENV"
ENV_SET_OPENCLAW_GATEWAY_TOKEN=$(tr -d '\r\n' < "$OC_ETC/api-key") env_file_update "$OC_ENV"
if [[ -n $OPEN_TERMINAL_URL ]]; then
  ENV_SET_OSR_OPEN_TERMINAL_KEY=$ot_key env_file_update "$OC_ENV"
elif [[ -n $prev_ot_url ]]; then
  ENV_UNSET_OSR_OPEN_TERMINAL_KEY=1 env_file_update "$OC_ENV"
fi
unset ot_key
chown "$OC_USER:$OC_USER" "$OC_ENV"
chmod 0600 "$OC_ENV"
run_oc config set gateway.mode local
run_oc config set gateway.port "$OPENCLAW_PORT" --strict-json
run_oc config set gateway.auth.mode token
run_oc config set gateway.auth.token --ref-provider default --ref-source env --ref-id OPENCLAW_GATEWAY_TOKEN
run_oc config set gateway.bind "$bind"
run_oc config set gateway.http.endpoints.chatCompletions.enabled "$OPENCLAW_API" --strict-json
run_oc config set gateway.controlUi.enabled "$OPENCLAW_DASHBOARD" --strict-json
if [[ -n $HONCHO_URL ]]; then
  # `plugins inspect` is how the plugin's own README checks it; it fails for a
  # plugin OpenClaw does not know.
  if ! run_oc plugins inspect openclaw-honcho >/dev/null 2>&1; then
    run_oc plugins install @honcho-ai/openclaw-honcho
  fi
  run_oc plugins enable openclaw-honcho
  run_oc config set plugins.entries.openclaw-honcho.hooks.allowConversationAccess true --strict-json
  run_oc config set plugins.entries.openclaw-honcho.config.baseUrl "$HONCHO_URL"
  run_oc config set plugins.entries.openclaw-honcho.config.workspaceId osr
  run_oc config set plugins.entries.openclaw-honcho.config.peerName user
  install -d -m 0700 -o "$OC_USER" -g "$OC_USER" "$OC_USER_HOME/.honcho"
  python3 - "$HONCHO_API_KEY_FILE" "$HONCHO_URL" "$OC_USER_HOME/.honcho/config.json" <<'PY'
import json, sys
data = {"apiKey": open(sys.argv[1], encoding="utf-8").read().strip(),
        "baseUrl": sys.argv[2]}
with open(sys.argv[3], "w", encoding="utf-8") as f:
    json.dump(data, f)
    f.write("\n")
PY
  chown "$OC_USER:$OC_USER" "$OC_USER_HOME/.honcho/config.json"
  chmod 0600 "$OC_USER_HOME/.honcho/config.json"
elif [[ -n $prev_honcho_url ]]; then
  # The last run set up Honcho; HONCHO_URL is now empty, so turn it off.
  run_oc plugins disable openclaw-honcho
  rm -f -- "$OC_USER_HOME/.honcho/config.json"
  [[ $honcho_key_owned == false ]] || rm -f -- "$HONCHO_API_KEY_FILE"
  note 'The OpenClaw Honcho plugin is disabled.'
fi
# Open Terminal: an MCP server whose bearer key OpenClaw substitutes from its
# .env (${OSR_OPEN_TERMINAL_KEY}), so openclaw.json holds no key. OpenClaw's
# own exec tool still runs here; these add its private workspace.
if [[ -n $OPEN_TERMINAL_URL ]]; then
  run_oc config set mcp.servers.open-terminal \
    "{\"url\":\"$OPEN_TERMINAL_URL/mcp\",\"transport\":\"streamable-http\",\"headers\":{\"Authorization\":\"Bearer \${OSR_OPEN_TERMINAL_KEY}\"}}" \
    --strict-json --replace
elif [[ -n $prev_ot_url ]]; then
  # The last run connected Open Terminal; OPEN_TERMINAL_URL is now empty.
  run_oc config unset mcp.servers.open-terminal ||
    note "Could not remove mcp.servers.open-terminal from $OC_CONFIG; delete it there by hand."
  [[ $ot_key_owned == false ]] || rm -f -- "$OPEN_TERMINAL_KEY_FILE"
  note 'Open Terminal is disconnected from OpenClaw.'
fi
if [[ $OPENCLAW_DASHBOARD == true ]]; then
  run_oc config set gateway.controlUi.allowedOrigins "$origins" --strict-json
fi
run_oc config set models.mode merge
for name in "${new_providers[@]}"; do
  run_oc config set "models.providers.$name" "$(provider_entry "$name" < "$stage/providers.json")" --strict-json --replace
done
# Providers of targets the router no longer lists.
if [[ -s $OC_ETC/providers.json ]]; then
  while IFS= read -r name; do
    [[ -n $name && " ${new_providers[*]} " != *" $name "* ]] || continue
    run_oc config unset "models.providers.$name" ||
      note "Could not remove provider $name from $OC_CONFIG; delete it there by hand."
  done < <(provider_ids < "$OC_ETC/providers.json")
fi
# An existing string model setting ("provider/model") becomes the object form.
run_oc config set agents.defaults.model.primary "osr/$OPENCLAW_MODEL" ||
  run_oc config set agents.defaults.model "{\"primary\":\"osr/$OPENCLAW_MODEL\"}" --strict-json
run_oc config validate
install -m 0644 "$stage/providers.json" "$OC_ETC/providers.json"

# 4. The Gateway.
install -m 0644 "$source_dir/$UNIT" "$UNIT_DIR/$UNIT"
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null
systemctl restart "$UNIT"
wait_gateway ||
  fail "$UNIT did not become healthy on port $OPENCLAW_PORT within ${HEALTH_TIMEOUT}s. Check: journalctl -u $UNIT"
write_settings

trap - ERR
# The key now lives in the dispatcher's own file.
rm -f -- "$ROUTER_API_KEY_FILE"
version=$(installed_openclaw)
note "OpenClaw $version (Node $(installed_node)) discovers via $ROUTER_URL and calls model servers directly with model osr/$OPENCLAW_MODEL (context $OPENCLAW_CONTEXT_LENGTH)."
exact_version "$OPENCLAW_VERSION" || note "Pin this version with OPENCLAW_VERSION=$version."
[[ $OPENCLAW_API != true ]] || note "OpenAI-compatible API: http://0.0.0.0:$OPENCLAW_PORT/v1 (model $API_MODEL)."
if [[ $OPENCLAW_DASHBOARD == true ]]; then
  note "Control UI: http://${ct_addresses[0]}:$OPENCLAW_PORT/ (the Gateway token from $OC_ETC/api-key, then approve the browser with: openclaw devices approve <id>)."
fi
note "Run the CLI with: runuser -u $OC_USER -- env HOME=$OC_USER_HOME PATH=$OC_USER_HOME/.local/bin:/usr/bin:/bin openclaw"
