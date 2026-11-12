#!/usr/bin/env bash
# Run as root in the dedicated OpenCode LXC (provision-lxc.sh pushes this file,
# the units, the dispatcher, the chat endpoint and the router's API key).
# OpenCode discovers models through the router but sends inference to model
# servers through a local loopback dispatcher (the Hermes target's
# direct-dispatch.py). With OPENCODE_API=true an OpenAI-compatible chat endpoint
# (openai-proxy.py, its own account) puts OpenCode in Open WebUI.
#
# OpenCode 2 is one native binary. The official npm package @opencode/cli only
# selects that binary for the platform (its postinstall script); this target
# does the same selection itself and downloads the platform package from the
# npm registry, checked against the registry's sha512 integrity, so no Node.js
# is needed. Each release lives in /opt/opencode/releases/<version>-<platform>
# behind a "current" link, so a failed run can switch back.
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
OC_USER=${OC_USER:-opencode}
OC_USER_HOME=${OC_USER_HOME:-/home/opencode}
DIRECT_USER=${DIRECT_USER:-opencode-direct}
API_USER=${API_USER:-opencode-api}
OC_ETC=${OC_ETC:-/etc/opencode-target}
OPT_DIR=${OPT_DIR:-/opt/opencode}
BIN_LINK=${BIN_LINK:-/usr/local/bin/opencode}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
DIRECT_LIB=${DIRECT_LIB:-/usr/local/lib/opencode-direct.py}
API_LIB=${API_LIB:-/usr/local/lib/opencode-api.py}
LOCK_FILE=${LOCK_FILE:-/etc/opencode-target.lock}
CPUINFO=${CPUINFO:-/proc/cpuinfo}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-120}
# One real direct chat request with a tool, to prove auth and inference.
CHAT_PROBE_TIMEOUT=${CHAT_PROBE_TIMEOUT:-300}
# OpenCode's system prompt, tool schemas and history need room. Below 32K a
# coding turn does not fit.
MIN_CONTEXT=32768
# The release this target was checked against (config schema, serve flags,
# Basic auth, /api/info and /api/model/default) on 2026-11-11: npm latest.
DEFAULT_OPENCODE_VERSION=2.2.7
# Honcho's OpenCode plugin; 0.2.0 is the first release for OpenCode 2.
DEFAULT_HONCHO_PLUGIN_VERSION=0.2.1
NPM_REGISTRY=https://registry.npmjs.org
HONCHO_PLUGIN=@honcho-ai/opencode-honcho
# The runtime package that speaks the OpenAI chat format (OpenCode 2 names).
PROVIDER_PACKAGE=@opencode/ai/providers/openai-compatible

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash install-target.sh [--dry-run]

Inside an existing OpenCode CT, a direct interactive run asks for the router
base URL when ROUTER_URL is unset. An unattended run must set ROUTER_URL.
CT ID and CT IP are chosen by provision-lxc.sh on the Proxmox host.

Installs OpenCode 2 (the native binary from the npm registry, checked against
its sha512 integrity) and points its provider "osr" at a local direct
dispatcher. The dispatcher uses the router's inventory and ranking, then calls
model servers itself. Each model server in the targets file is also a
provider, <target>/<model>, that the dispatcher reaches without the router.
Rerun to change settings; an unchanged, healthy installation is left alone.

Environment:
  ROUTER_URL                   router base URL (host and port, no /v1)
  ROUTER_API_KEY_FILE          file holding the router's ROUTER_API_KEY
                               (default: router-api-key next to this script;
                               absent: keep the key already configured)
  OPENCODE_MODEL=auto          default model: an ID from the router's /v1/models
  OPENCODE_CONTEXT_LENGTH=65536  context the model hosts really serve (>=32768)
  OPENCODE_MAX_TOKENS=8192     output tokens per reply OpenCode may ask for
  OPENCODE_VERSION=2.2.7       exact @opencode/cli release, or latest
  OPENCODE_PORT=4096           server port (web UI and HTTP API)
  OPENCODE_WEB=true            listen on every CT address for the web UI;
                               false: loopback only (CLI with --server)
  OPENCODE_FREE_MODELS=false   true: also offer OpenCode's free cloud models
  OPENCODE_API=false           true: an OpenAI-compatible chat endpoint (model
                               "opencode", bearer key in api-key) for Open WebUI
  OPENCODE_API_PORT=4097       its port
  OPENCODE_API_PERMISSIONS=allow  what it answers OpenCode's permission requests
                               with (nobody is there to ask): allow or reject
  HONCHO_URL                   Honcho API (http://IP:port): long-term memory
                               through Honcho's OpenCode plugin; empty after a
                               run that set it turns it off
  HONCHO_API_KEY_FILE          this CT's Honcho key (default: honcho-api-key
                               next to this script)
  HONCHO_PLUGIN_VERSION=0.2.1  @honcho-ai/opencode-honcho release
  OPEN_TERMINAL_URL            Open Terminal gateway (http://IP:port): OpenCode's
                               own workspace there, as MCP server open-terminal;
                               empty after a run that set it disconnects it
  OPEN_TERMINAL_KEY_FILE       this CT's client key (default: open-terminal-key
                               next to this script, pushed by provision-lxc.sh)
  OPENCODE_SKIP_CHAT_PROBE=false  true: skip the test chat request
USAGE
}

# Install helpers (sourced by test-install.sh) -------------------------------

# settings_record: the settings this installation runs with. Keys are
# recorded only as hashes, so rotating one is a change.
settings_record() {
  printf 'ROUTER_URL=%s\n' "$ROUTER_URL"
  printf 'OPENCODE_MODEL=%s\n' "$OPENCODE_MODEL"
  printf 'OPENCODE_CONTEXT_LENGTH=%s\n' "$OPENCODE_CONTEXT_LENGTH"
  printf 'OPENCODE_MAX_TOKENS=%s\n' "$OPENCODE_MAX_TOKENS"
  printf 'KINDI_READ_TIMEOUT_SECONDS=%s\n' "${KINDI_READ_TIMEOUT_SECONDS:-3600}"
  printf 'OPENCODE_VERSION=%s\n' "$OPENCODE_VERSION"
  printf 'OPENCODE_RELEASE=%s\n' "$release_name"
  printf 'OPENCODE_PORT=%s\n' "$OPENCODE_PORT"
  printf 'OPENCODE_WEB=%s\n' "$OPENCODE_WEB"
  printf 'OPENCODE_FREE_MODELS=%s\n' "$OPENCODE_FREE_MODELS"
  printf 'OPENCODE_API=%s\nOPENCODE_API_PORT=%s\nOPENCODE_API_PERMISSIONS=%s\nAPI_KEY_SHA256=%s\n' \
    "$OPENCODE_API" "$OPENCODE_API_PORT" "$OPENCODE_API_PERMISSIONS" "$api_key_sha256"
  printf 'HONCHO_URL=%s\nHONCHO_KEY_SHA256=%s\nHONCHO_WORKSPACE=%s\nHONCHO_PLUGIN_VERSION=%s\n' \
    "$HONCHO_URL" "$honcho_key_sha256" "$honcho_workspace" "$HONCHO_PLUGIN_VERSION"
  printf 'OPEN_TERMINAL_URL=%s\nOPEN_TERMINAL_KEY_SHA256=%s\n' "$OPEN_TERMINAL_URL" "$ot_key_sha256"
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
elif isinstance(body, dict) and (body.get("detail") or body.get("message")):
    print(body.get("detail") or body.get("message"))
' 2>/dev/null || true
}

# version_of < TEXT: the first version number in `opencode --version` output.
version_of() {
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -n 1 || true
}

# exact_version SPEC: is OPENCODE_VERSION an exact release (not a dist-tag)?
exact_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; }

# platform_candidates MACHINE CPUINFO: the @opencode/cli platform packages for
# this CT, best first, as the package's own postinstall script orders them on
# glibc Linux: x64 without AVX2 prefers the baseline build.
platform_candidates() {
  case $1 in
    x86_64|amd64)
      if grep -qwi avx2 "$2" 2>/dev/null; then
        printf '%s\n' @opencode/cli-linux-x64 @opencode/cli-linux-x64-baseline
      else
        printf '%s\n' @opencode/cli-linux-x64-baseline @opencode/cli-linux-x64
      fi ;;
    aarch64|arm64) printf '%s\n' @opencode/cli-linux-arm64 ;;
    *) return 1 ;;
  esac
}

# pick_platform MANIFEST CANDIDATE...: the first candidate the @opencode/cli
# manifest lists as an optional dependency of exactly its own version.
pick_platform() {
  python3 - "$@" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
deps = manifest.get("optionalDependencies") or {}
version = manifest.get("version")
for name in sys.argv[2:]:
    if deps.get(name) == version:
        print(name)
        sys.exit(0)
sys.exit(1)
PY
}

# manifest_field MANIFEST FIELD: version, tarball or integrity of a registry
# version manifest. The tarball must come from the registry itself.
manifest_field() {
  python3 - "$@" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
field = sys.argv[2]
if field == "version":
    v = m.get("version", "")
    ok = re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?", v)
elif field == "tarball":
    v = (m.get("dist") or {}).get("tarball", "")
    ok = v.startswith("https://registry.npmjs.org/") and ".." not in v
elif field == "integrity":
    v = (m.get("dist") or {}).get("integrity", "")
    ok = re.fullmatch(r"sha512-[A-Za-z0-9+/]{86}==", v)
else:
    ok = False
if not ok:
    sys.exit(1)
print(v)
PY
}

# integrity_ok FILE SRI: does FILE match an npm "sha512-<base64>" integrity?
integrity_ok() {
  python3 - "$1" "$2" <<'PY'
import base64, hashlib, sys
digest = hashlib.sha512()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        digest.update(chunk)
sys.exit(0 if "sha512-" + base64.b64encode(digest.digest()).decode() == sys.argv[2] else 1)
PY
}

# providers_json CONTEXT MAX_TOKENS DIRECT_URL PREVIOUS NAME=MODELS_FILE...: the
# OpenCode providers. "osr" is the router-ranked dispatcher; every other NAME
# is one model server under DIRECT_URL/t/NAME. MODELS_FILE is that endpoint's
# /v1/models answer, or "-" when it could not be listed: then the entry in
# PREVIOUS (the last providers written, or "-") is kept, so a model server that
# is down for a moment keeps its provider. KINDI_TARGETS names the Kindi
# targets (space-separated): those, and osr while there are any, get
# KINDI_HEADER_TIMEOUT_MS as settings.headerTimeout. Kindi reads a long prompt
# slowly and sends nothing until it has read it, which OpenCode's five-minute
# wait for response headers would otherwise cut off; the dispatcher still
# bounds every server's silence at its own read timeout.
providers_json() {
  python3 - "$@" <<'PY'
import json, os, sys
context, max_tokens, direct = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3].rstrip("/")
package = os.environ.get("PROVIDER_PACKAGE", "@opencode/ai/providers/openai-compatible")
kindi_targets = set(os.environ.get("KINDI_TARGETS", "").split())
kindi_timeout = int(os.environ.get("KINDI_HEADER_TIMEOUT_MS", "7200000"))
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
    settings = {"baseURL": base, "apiKey": "no-key"}
    if name in kindi_targets or (name == "osr" and kindi_targets):
        settings["headerTimeout"] = kindi_timeout
    # Tool calls are what the agent is for; max_tokens is the field every
    # pool server (Ollama, llama.cpp, vLLM-style) accepts. Pool servers take
    # JSON tool calls only (no freeform grammars) and text only.
    out[name] = {
        "name": "OSR (router-ranked)" if name == "osr" else f"OSR server {name}",
        "package": package,
        "settings": settings,
        "compatibility": {"maxTokensField": "max_tokens"},
        "models": {i: {"name": i,
                       "capabilities": {"tools": True, "freeform": [], "input": ["text"], "output": ["text"]},
                       "limit": {"context": context, "output": max_tokens}}
                   for i in ids},
    }
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

# opencode_config CONFIG NEW_PROVIDERS OLD_PROVIDERS MODEL: write OpenCode's
# global config with this target's settings, keeping everything else the
# operator put there. Providers listed in OLD_PROVIDERS ("-" for none) and no
# longer in NEW_PROVIDERS are removed. From the environment: OC_OT_URL (the
# Open Terminal MCP server, empty: none), OC_OT_PREV=1 (remove an earlier
# open-terminal server), OC_HONCHO_SPEC (the Honcho plugin entry, empty:
# none; any other release of it is replaced or removed). The file must be
# plain JSON; a hand-edited JSONC file (comments) is refused, not rewritten.
opencode_config() {
  python3 - "$@" <<'PY'
import json, os, sys
path, new_path, old_path, model = sys.argv[1:5]
try:
    with open(path, encoding="utf-8") as f:
        text = f.read()
except FileNotFoundError:
    text = ""
try:
    config = json.loads(text) if text.strip() else {}
except ValueError as exc:
    sys.exit(f"{path} is not plain JSON ({exc}); remove its comments or move it aside, then rerun.")
if not isinstance(config, dict):
    sys.exit(f"{path} does not hold a JSON object.")
new = json.load(open(new_path, encoding="utf-8"))
old = {}
if old_path != "-":
    try:
        old = json.load(open(old_path, encoding="utf-8"))
    except (OSError, ValueError):
        old = {}
config["$schema"] = "https://opencode.ai/config.json"
# Releases come from install-target.sh; OpenCode must not replace its binary.
config["update"] = "disable"
config["model"] = f"osr/{model}"
providers = config.get("providers")
if not isinstance(providers, dict):
    providers = {}
for name in old:
    if name not in new:
        providers.pop(name, None)
providers.update(new)
config["providers"] = providers
mcp = config.get("mcp") if isinstance(config.get("mcp"), dict) else {}
servers = mcp.get("servers") if isinstance(mcp.get("servers"), dict) else {}
ot_url = os.environ.get("OC_OT_URL", "")
if ot_url:
    # OpenCode substitutes {env:...} from the server's environment, so the
    # config holds no key. OAuth off: the gateway takes a bearer key.
    servers["open-terminal"] = {"type": "remote", "url": ot_url + "/mcp", "oauth": False,
                                "headers": {"Authorization": "Bearer {env:OSR_OPEN_TERMINAL_KEY}"}}
elif os.environ.get("OC_OT_PREV") == "1":
    servers.pop("open-terminal", None)
if servers or "servers" in mcp:
    mcp["servers"] = servers
if mcp:
    config["mcp"] = mcp
plugins = config.get("plugins") if isinstance(config.get("plugins"), list) else []
plugin = "@honcho-ai/opencode-honcho"
def is_honcho(entry):
    name = entry if isinstance(entry, str) else entry.get("package") if isinstance(entry, dict) else None
    return isinstance(name, str) and (name == plugin or name.startswith(plugin + "@"))
plugins = [p for p in plugins if not is_honcho(p)]
spec = os.environ.get("OC_HONCHO_SPEC", "")
if spec:
    plugins.append(spec)
if plugins or "plugins" in config:
    config["plugins"] = plugins
with open(path + ".new", "w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
os.replace(path + ".new", path)
PY
}

# honcho_config FILE URL KEY_FILE WORKSPACE: the shared Honcho config the
# OpenCode plugin reads (~/.honcho/config.json), with this CT's key, URL and
# workspace; other settings in it are kept. Peers: "user" (the people who use
# this agent) and "opencode" (the agent).
honcho_config() {
  python3 - "$@" <<'PY'
import json, os, sys
path, url, key_file, workspace = sys.argv[1:5]
try:
    data = json.load(open(path, encoding="utf-8"))
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
data["apiKey"] = open(key_file, encoding="utf-8").read().strip()
data["baseUrl"] = url
data["peerName"] = "user"
hosts = data.get("hosts") if isinstance(data.get("hosts"), dict) else {}
host = hosts.get("opencode") if isinstance(hosts.get("opencode"), dict) else {}
host.pop("apiKey", None)
host.update({"workspace": workspace, "aiPeer": "opencode", "removeUserPrefix": True,
             "observationMode": "unified"})
host.setdefault("recallMode", "hybrid")
host.setdefault("sessionStrategy", "per-directory")
hosts["opencode"] = host
data["hosts"] = hosts
with open(path + ".new", "w", encoding="utf-8") as f:
    os.fchmod(f.fileno(), 0o600)
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".new", path)
PY
}

# default_model_is PROVIDER MODEL < /api/model/default JSON: does the server
# use PROVIDER/MODEL when a session picks none?
default_model_is() {
  python3 -c 'import json,sys
try:
    d = json.load(sys.stdin).get("data") or {}
except (ValueError, AttributeError):
    sys.exit(1)
sys.exit(0 if d.get("providerID") == sys.argv[1] and d.get("id") == sys.argv[2] else 1)' "$1" "$2"
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
OPENCODE_MODEL=${OPENCODE_MODEL:-auto}
OPENCODE_CONTEXT_LENGTH=${OPENCODE_CONTEXT_LENGTH:-65536}
OPENCODE_MAX_TOKENS=${OPENCODE_MAX_TOKENS:-8192}
OPENCODE_VERSION=${OPENCODE_VERSION:-$DEFAULT_OPENCODE_VERSION}
OPENCODE_PORT=${OPENCODE_PORT:-4096}
OPENCODE_WEB=${OPENCODE_WEB:-true}
OPENCODE_FREE_MODELS=${OPENCODE_FREE_MODELS:-false}
OPENCODE_API=${OPENCODE_API:-false}
OPENCODE_API_PORT=${OPENCODE_API_PORT:-4097}
OPENCODE_API_PERMISSIONS=${OPENCODE_API_PERMISSIONS:-allow}
HONCHO_URL=${HONCHO_URL:-}
HONCHO_API_KEY_FILE=${HONCHO_API_KEY_FILE:-$source_dir/honcho-api-key}
HONCHO_PLUGIN_VERSION=${HONCHO_PLUGIN_VERSION:-$DEFAULT_HONCHO_PLUGIN_VERSION}
honcho_key_owned=false
[[ $HONCHO_API_KEY_FILE != "$source_dir/honcho-api-key" ]] || honcho_key_owned=true
# Open Terminal: OpenCode's own workspace in the terminal CT, reached as MCP
# tools (the gateway's /mcp) with this CT's client key.
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL:-}
OPEN_TERMINAL_KEY_FILE=${OPEN_TERMINAL_KEY_FILE:-$source_dir/open-terminal-key}
ot_key_owned=false
[[ $OPEN_TERMINAL_KEY_FILE != "$source_dir/open-terminal-key" ]] || ot_key_owned=true
OPENCODE_SKIP_CHAT_PROBE=${OPENCODE_SKIP_CHAT_PROBE:-false}
OC_CONFIG_DIR=$OC_USER_HOME/.config/opencode
OC_CONFIG=$OC_CONFIG_DIR/opencode.json
OC_WORKSPACE=$OC_USER_HOME/workspace
OC_ENV=$OC_ETC/opencode.env
HONCHO_CONFIG=$OC_USER_HOME/.honcho/config.json
RELEASES=$OPT_DIR/releases
CURRENT=$OPT_DIR/current
UNIT=opencode.service
DIRECT_UNIT=opencode-direct.service
API_UNIT=opencode-api.service
API_ENV=$OC_ETC/api.env
API_KEY=$OC_ETC/api-key
# The name Open WebUI shows (integrate-webui.py --model-name).
API_MODEL=opencode
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
# The server listens on every address when a browser needs it.
bind=127.0.0.1
[[ $OPENCODE_WEB != true ]] || bind=0.0.0.0

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
[[ $OPENCODE_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid OPENCODE_MODEL.'
[[ $OPENCODE_CONTEXT_LENGTH =~ ^[1-9][0-9]{4,6}$ ]] && (( OPENCODE_CONTEXT_LENGTH >= MIN_CONTEXT )) ||
  die "OPENCODE_CONTEXT_LENGTH must be at least $MIN_CONTEXT: OpenCode's prompt, tools and history need it. The model's host must serve that much too."
[[ $OPENCODE_MAX_TOKENS =~ ^[1-9][0-9]{2,6}$ ]] && (( OPENCODE_MAX_TOKENS >= 256 && OPENCODE_MAX_TOKENS * 2 <= OPENCODE_CONTEXT_LENGTH )) ||
  die 'OPENCODE_MAX_TOKENS must be at least 256 and at most half of OPENCODE_CONTEXT_LENGTH.'
# OpenCode's wait for response headers from a Kindi server: see providers_json.
KINDI_HEADER_TIMEOUT_MS=$(( KINDI_READ_TIMEOUT_SECONDS * 2 * 1000 ))
[[ $OPENCODE_VERSION == latest ]] || exact_version "$OPENCODE_VERSION" ||
  die 'OPENCODE_VERSION must be latest or an exact @opencode/cli release such as 2.2.7.'
[[ ${OPENCODE_VERSION%%.*} == latest || ${OPENCODE_VERSION%%.*} -ge 2 ]] ||
  die 'OPENCODE_VERSION must be OpenCode 2 or newer (OpenCode 1 uses another config and server API).'
exact_version "$HONCHO_PLUGIN_VERSION" || die 'HONCHO_PLUGIN_VERSION must be an exact release such as 0.2.1.'
[[ $OPENCODE_WEB =~ ^(true|false)$ ]] || die 'OPENCODE_WEB must be true or false.'
[[ $OPENCODE_FREE_MODELS =~ ^(true|false)$ ]] || die 'OPENCODE_FREE_MODELS must be true or false.'
[[ $OPENCODE_SKIP_CHAT_PROBE =~ ^(true|false)$ ]] || die 'OPENCODE_SKIP_CHAT_PROBE must be true or false.'
[[ $OPENCODE_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( OPENCODE_PORT <= 65535 )) || die 'Invalid OPENCODE_PORT.'
(( OPENCODE_PORT != 8765 )) || die 'OPENCODE_PORT 8765 is the local dispatcher.'
[[ $OPENCODE_API =~ ^(true|false)$ ]] || die 'OPENCODE_API must be true or false.'
[[ $OPENCODE_API_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( OPENCODE_API_PORT <= 65535 )) || die 'Invalid OPENCODE_API_PORT.'
(( OPENCODE_API_PORT != 8765 && OPENCODE_API_PORT != OPENCODE_PORT )) ||
  die 'OPENCODE_API_PORT must differ from OPENCODE_PORT and 8765 (the local dispatcher).'
[[ $OPENCODE_API_PERMISSIONS =~ ^(allow|reject)$ ]] || die 'OPENCODE_API_PERMISSIONS must be allow or reject.'
[[ $HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid HEALTH_TIMEOUT.'
[[ $CHAT_PROBE_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid CHAT_PROBE_TIMEOUT.'
for path_var in OC_USER_HOME OC_ETC OPT_DIR BIN_LINK UNIT_DIR LOCK_FILE DIRECT_LIB API_LIB; do
  [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
for user_var in OC_USER DIRECT_USER API_USER; do
  [[ ${!user_var} =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid $user_var."
done
[[ -r $source_dir/$UNIT && -r $source_dir/$DIRECT_UNIT && -r $source_dir/direct-dispatch.py &&
   -r $source_dir/$API_UNIT && -r $source_dir/openai-proxy.py ]] ||
  die 'Missing the OpenCode units, direct dispatcher or chat endpoint (provision-lxc.sh pushes them).'

if (( dry_run )); then
  printf '+ verify %s/v1/models (with the router API key) advertises %s\n' "$ROUTER_URL" "$OPENCODE_MODEL"
  printf '+ apt-get install ca-certificates curl git ripgrep tar coreutils python3 openssl util-linux iproute2\n'
  printf '+ create unprivileged users %s (agent) and %s (dispatcher)\n' "$OC_USER" "$DIRECT_USER"
  printf '+ resolve @opencode/cli@%s on %s; download its platform package for %s, check its sha512 integrity;\n' \
    "$OPENCODE_VERSION" "$NPM_REGISTRY" "$(uname -m)"
  printf '  install the binary in %s/<version>-<platform>, link %s and %s\n' "$RELEASES" "$CURRENT" "$BIN_LINK"
  printf '+ install %s, start %s; discover models via the router and dispatch inference directly\n' \
    "$DIRECT_LIB" "$DIRECT_UNIT"
  [[ $OPENCODE_SKIP_CHAT_PROBE == true ]] ||
    printf '+ send one chat request offering a tool through the local dispatcher to a model server (model %s)\n' "$OPENCODE_MODEL"
  printf '+ configure provider osr (%s, baseURL %s/v1, apiKey <local placeholder>), model osr/%s, context %s\n' \
    "$PROVIDER_PACKAGE" "$DIRECT_URL" "$OPENCODE_MODEL" "$OPENCODE_CONTEXT_LENGTH"
  printf '+ configure direct providers <target> (baseURL %s/t/<target>/v1) for: %s\n' \
    "$DIRECT_URL" "$(target_names "$targets_source" | paste -sd' ' - | sed 's/^$/none/')"
  printf '+ server on %s:%s, Basic auth as opencode (password in %s/password and %s)\n' \
    "$bind" "$OPENCODE_PORT" "$OC_ETC" "$OC_ENV"
  if [[ $OPENCODE_WEB == true ]]; then
    printf '+ web UI on http://<CT IPv4 addresses>:%s/ (user opencode, the server password)\n' "$OPENCODE_PORT"
  else
    printf '+ web UI on loopback only (opencode --server http://127.0.0.1:%s in the CT)\n' "$OPENCODE_PORT"
  fi
  [[ $OPENCODE_FREE_MODELS == true ]] || printf '+ hide OpenCode'\''s free cloud models (OPENCODE_DISABLE_FREE_MODELS=1)\n'
  if [[ -n $HONCHO_URL ]]; then
    printf '+ check %s/osr/v1/whoami with this CT'\''s key; plugin %s@%s, %s (workspace from Honcho)\n' \
      "$HONCHO_URL" "$HONCHO_PLUGIN" "$HONCHO_PLUGIN_VERSION" "$HONCHO_CONFIG"
  fi
  if [[ -n $OPEN_TERMINAL_URL ]]; then
    printf '+ check %s/osr/v1/whoami with this CT'\''s key; MCP server open-terminal at %s/mcp (key in %s)\n' \
      "$OPEN_TERMINAL_URL" "$OPEN_TERMINAL_URL" "$OC_ENV"
  fi
  printf '+ install %s/%s, enable and start it, wait for /api/info and the default model osr/%s\n' \
    "$UNIT_DIR" "$UNIT" "$OPENCODE_MODEL"
  if [[ $OPENCODE_API == true ]]; then
    printf '+ create unprivileged user %s; bearer key in %s; %s (root 0600) holds it and the server password\n' \
      "$API_USER" "$API_KEY" "$API_ENV"
    printf '+ install %s and %s/%s: OpenAI-compatible endpoint http://<CT IPv4>:%s/v1, model %s, permissions: %s\n' \
      "$API_LIB" "$UNIT_DIR" "$API_UNIT" "$OPENCODE_API_PORT" "$API_MODEL" "$OPENCODE_API_PERMISSIONS"
    printf '+ wait for /healthz and /v1/models (with the key) on port %s\n' "$OPENCODE_API_PORT"
  else
    printf '+ no OpenAI-compatible endpoint (stop and remove %s if present)\n' "$API_UNIT"
  fi
  exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the OpenCode CT.'
# A minimal Debian template may not have Python or curl, which the router
# probes need. Install only these before touching OpenCode.
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || ! command -v flock >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl python3 util-linux
fi

# One run at a time. The lock is released when this shell exits.
exec {install_lock_fd}>>"$LOCK_FILE"
flock -n "$install_lock_fd" || die "Another install-target.sh run holds $LOCK_FILE."

stage=$(mktemp -d "${TMPDIR:-/tmp}/opencode-target.XXXXXX")
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
models_has "$OPENCODE_MODEL" < "$stage/response" ||
  die "The router does not advertise model '$OPENCODE_MODEL'. Choose one from $ROUTER_URL/v1/models."

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

# --- health checks and the commands they need ---------------------------------
run_as_oc() {
  runuser -u "$OC_USER" -- env HOME="$OC_USER_HOME" USER="$OC_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin" OPENCODE_DISABLE_AUTOUPDATE=1 "$@"
}
# release_version DIR: the version the binary in a release directory reports.
release_version() {
  [[ -x $1/opencode ]] || return 0
  { run_as_oc "$1/opencode" --version 2>/dev/null || true; } | version_of
}
installed_release() { [[ -L $CURRENT ]] && basename -- "$(readlink -- "$CURRENT")" || true; }
installed_opencode() { [[ -L $CURRENT ]] && release_version "$CURRENT" || true; }

# server_healthy [PORT]: /api/info answers the password, and the server's
# default model is osr/OPENCODE_MODEL, which proves it loaded this config and
# its providers. Default: the port of this run.
server_healthy() {
  local port=${1:-$OPENCODE_PORT} model=${2:-$OPENCODE_MODEL} auth=$stage/server-auth
  [[ -s $OC_ETC/password ]] || return 1
  printf 'Authorization: Basic %s\n' "$(printf 'opencode:%s' "$(tr -d '\r\n' < "$OC_ETC/password")" | base64 -w0)" > "$auth"
  [[ $(api "http://127.0.0.1:$port/api/info" "$auth") == 200 ]] || return 1
  [[ $(api "http://127.0.0.1:$port/api/model/default" "$auth") == 200 ]] || return 1
  default_model_is osr "$model" < "$stage/response"
}
wait_server() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    server_healthy "$@" && return 0
    sleep 2
  done
  return 1
}
# api_healthy: the chat endpoint is up on this run's port, reaches OpenCode,
# and lists its model to the bearer key.
api_healthy() {
  local port=$OPENCODE_API_PORT auth=$stage/api-auth
  [[ -s $API_KEY ]] || return 1
  printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$API_KEY")" > "$auth"
  [[ $(api "http://127.0.0.1:$port/healthz" /dev/null) == 200 ]] || return 1
  [[ $(api "http://127.0.0.1:$port/v1/models" "$auth") == 200 ]] || return 1
  models_has "$API_MODEL" < "$stage/response"
}
wait_api() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    api_healthy && return 0
    sleep 2
  done
  return 1
}
# api_state_ok: the chat endpoint is as this run wants it (running and healthy,
# or not running).
api_state_ok() {
  if [[ $OPENCODE_API == true ]]; then
    systemctl is-active --quiet "$API_UNIT" && api_healthy
  else
    ! systemctl is-active --quiet "$API_UNIT" 2>/dev/null
  fi
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
    KINDI_HEADER_TIMEOUT_MS="$KINDI_HEADER_TIMEOUT_MS" PROVIDER_PACKAGE="$PROVIDER_PACKAGE" \
    providers_json "$OPENCODE_CONTEXT_LENGTH" "$OPENCODE_MAX_TOKENS" "$DIRECT_URL" "$previous" "${lists[@]}" > "$out"
}
# fetch URL OUT: a registry download over HTTPS only.
fetch() {
  curl --fail --silent --show-error --location --proto '=https' --max-time "${2:-60}" "$1" -o "$3" 2>"$stage/curl-error" ||
    die "Could not download $1: $(head -c 300 "$stage/curl-error")"
}

# --- which release this run wants ------------------------------------------------
# An exact release that is already installed needs no registry; a dist-tag
# (latest) is resolved on every run and recorded as the exact release.
current_name=$(installed_release)
if exact_version "$OPENCODE_VERSION" && [[ $current_name == "$OPENCODE_VERSION"-* ]] &&
   [[ $(installed_opencode) == "$OPENCODE_VERSION" ]]; then
  want_version=$OPENCODE_VERSION
  release_name=$current_name
  platform="@opencode/cli-${release_name#"$want_version"-}"
else
  fetch "$NPM_REGISTRY/@opencode%2fcli/$OPENCODE_VERSION" 60 "$stage/cli.json"
  want_version=$(manifest_field "$stage/cli.json" version) ||
    die "The npm registry gave no usable @opencode/cli manifest for $OPENCODE_VERSION."
  if exact_version "$OPENCODE_VERSION" && [[ $want_version != "$OPENCODE_VERSION" ]]; then
    die "The npm registry answered @opencode/cli@$OPENCODE_VERSION with $want_version."
  fi
  [[ ${want_version%%.*} -ge 2 ]] || die "@opencode/cli $want_version is OpenCode 1; this target needs OpenCode 2."
  candidates=()
  mapfile -t candidates < <(platform_candidates "$(uname -m)" "$CPUINFO" || true)
  (( ${#candidates[@]} )) || die "OpenCode has no Linux build for $(uname -m) that this target knows."
  platform=$(pick_platform "$stage/cli.json" "${candidates[@]}") ||
    die "@opencode/cli $want_version lists no platform package for this CT (${candidates[*]})."
  release_name="$want_version-${platform#@opencode/cli-}"
fi
[[ $release_name =~ ^[A-Za-z0-9._-]+$ ]] || die "Unexpected release name: $release_name"
release_dir=$RELEASES/$release_name

# --- unchanged and healthy: nothing to do ---------------------------------------
unit_sha256=$(cat "$source_dir/$UNIT" "$source_dir/$DIRECT_UNIT" "$source_dir/direct-dispatch.py" \
  "$source_dir/$API_UNIT" "$source_dir/openai-proxy.py" | sha256sum | cut -d' ' -f1)
providers_sha256=pending
# The chat endpoint's key is made once, in the CT; a rotated or missing one is a change.
api_key_sha256=''
if [[ $OPENCODE_API == true ]]; then
  api_key_sha256=missing
  [[ ! -s $API_KEY ]] || api_key_sha256=$(tr -d '\r\n' < "$API_KEY" | sha256sum | cut -d' ' -f1)
fi
if [[ -f $OC_ETC/settings && $(installed_release) == "$release_name" && $(installed_opencode) == "$want_version" ]] &&
   systemctl is-active --quiet "$DIRECT_UNIT" && direct_healthy; then
  build_providers "$stage/providers.json"
  providers_sha256=$(sha256sum "$stage/providers.json" | cut -d' ' -f1)
  if [[ $(< "$OC_ETC/settings") == "$(settings_record)" ]]; then
    if systemctl is-active --quiet "$UNIT" && server_healthy && api_state_ok; then
      rm -f -- "$ROUTER_API_KEY_FILE"
      note 'OpenCode is healthy with these settings; nothing to do.'
      exit 0
    fi
    note "$UNIT or $API_UNIT is not running or not healthy; applying the settings again."
  fi
fi

# --- packages, accounts and the OpenCode release --------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git ripgrep tar coreutils python3 openssl util-linux iproute2
if ! id "$OC_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$OC_USER_HOME" --shell /bin/bash "$OC_USER"
fi
[[ $(getent passwd "$OC_USER" | cut -d: -f6) == "$OC_USER_HOME" ]] ||
  die "Existing $OC_USER account has a different home."
if ! id "$DIRECT_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$DIRECT_USER"
fi
if [[ $OPENCODE_API == true ]] && ! id "$API_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$API_USER"
fi
install -d -m 0755 -o "$OC_USER" -g "$OC_USER" "$OC_USER_HOME/.config"
install -d -m 0700 -o "$OC_USER" -g "$OC_USER" "$OC_CONFIG_DIR" "$OC_WORKSPACE"
install -d -m 0750 -o root -g "$DIRECT_USER" "$OC_ETC"
install -d -m 0755 -o root -g root "$OPT_DIR" "$RELEASES" "$(dirname -- "$BIN_LINK")"

# The binary is root's and world-readable: the agent can run it, not change it.
# A release directory is complete only once its binary reports its version, so
# an interrupted download is fetched again.
new_release=0
if [[ $(release_version "$release_dir") != "$want_version" ]]; then
  fetch "$NPM_REGISTRY/${platform/\//%2f}/$want_version" 60 "$stage/platform.json"
  [[ $(manifest_field "$stage/platform.json" version) == "$want_version" ]] ||
    die "The npm registry gave no usable $platform@$want_version manifest."
  tarball=$(manifest_field "$stage/platform.json" tarball) || die "$platform@$want_version has no registry tarball."
  integrity=$(manifest_field "$stage/platform.json" integrity) || die "$platform@$want_version has no sha512 integrity."
  note "Downloading $platform@$want_version ($tarball)..."
  fetch "$tarball" 900 "$stage/platform.tgz"
  integrity_ok "$stage/platform.tgz" "$integrity" ||
    die "$platform@$want_version does not match the registry's sha512 integrity. Nothing was installed."
  mkdir -p "$stage/unpack"
  tar -xzf "$stage/platform.tgz" -C "$stage/unpack" package/bin/opencode ||
    die "$platform@$want_version holds no package/bin/opencode."
  rm -rf -- "$release_dir.new"
  install -d -m 0755 "$release_dir.new"
  install -m 0755 "$stage/unpack/package/bin/opencode" "$release_dir.new/opencode"
  printf '%s@%s\n%s\n' "$platform" "$want_version" "$integrity" > "$release_dir.new/SOURCE"
  chmod 0644 "$release_dir.new/SOURCE"
  rm -rf -- "$release_dir"
  mv -- "$release_dir.new" "$release_dir"
  if [[ $(release_version "$release_dir") != "$want_version" ]]; then
    rm -rf -- "$release_dir"
    die "The OpenCode binary of $platform@$want_version does not run or does not report $want_version. Nothing was changed."
  fi
  new_release=1
fi
chmod -R a+rX,go-w "$release_dir"

# --- configuration, with a rollback --------------------------------------------
# Everything this run changes is set aside first; a failure puts it back.
backup=$stage/backup
install -d -m 0700 "$backup"
owned_files=("$OC_CONFIG" "$OC_ENV" "$UNIT_DIR/$UNIT" "$UNIT_DIR/$DIRECT_UNIT" "$DIRECT_LIB"
  "$API_ENV" "$UNIT_DIR/$API_UNIT" "$API_LIB"
  "$OC_ETC/backend-keys" "$OC_ETC/router.env" "$OC_ETC/settings" "$OC_ETC/targets" "$OC_ETC/providers.json"
  "$HONCHO_CONFIG")
[[ $honcho_key_owned == false ]] || owned_files+=("$HONCHO_API_KEY_FILE")
[[ $ot_key_owned == false ]] || owned_files+=("$OPEN_TERMINAL_KEY_FILE")
for file in "${owned_files[@]}"; do
  if [[ -f $file ]]; then cp -a -- "$file" "$backup/$(basename "$file").prev"; fi
done
prev_link=''
[[ ! -L $CURRENT ]] || prev_link=$(readlink -- "$CURRENT")
prev_bin_link=''
[[ ! -L $BIN_LINK ]] || prev_bin_link=$(readlink -- "$BIN_LINK")
server_was_active=0
if systemctl is-active --quiet "$UNIT" 2>/dev/null; then server_was_active=1; fi
direct_was_active=0
if systemctl is-active --quiet "$DIRECT_UNIT" 2>/dev/null; then direct_was_active=1; fi
api_was_active=0
if systemctl is-active --quiet "$API_UNIT" 2>/dev/null; then api_was_active=1; fi

restore() {
  local file name port model
  for file in "${owned_files[@]}"; do
    name=$(basename "$file")
    if [[ -f $backup/$name.prev ]]; then cp -a -- "$backup/$name.prev" "$file"; else rm -f -- "$file"; fi
  done
  if [[ -n $prev_link ]]; then ln -sfn -- "$prev_link" "$CURRENT"; else rm -f -- "$CURRENT"; fi
  if [[ -n $prev_bin_link ]]; then ln -sfn -- "$prev_bin_link" "$BIN_LINK"; else rm -f -- "$BIN_LINK"; fi
  # A release this run downloaded and nothing else uses.
  if (( new_release )) && [[ $prev_link != "$release_dir" ]]; then
    rm -rf -- "$release_dir"
  fi
  systemctl daemon-reload || true
  if (( direct_was_active )); then systemctl restart "$DIRECT_UNIT" || true
  else systemctl disable --now "$DIRECT_UNIT" >/dev/null 2>&1 || true; fi
  if (( server_was_active )); then
    # Health-check the restored settings, not the ones that failed.
    port=$(env_file_get "$OC_ETC/settings" OPENCODE_PORT)
    model=$(env_file_get "$OC_ETC/settings" OPENCODE_MODEL)
    systemctl restart "$UNIT" || true
    if wait_server "${port:-4096}" "${model:-auto}"; then
      note "The previous OpenCode release and configuration are restored and $UNIT is running again."
    else
      note "The previous OpenCode release and configuration are restored, but $UNIT did not become healthy either. Check: journalctl -u $UNIT"
    fi
  else
    systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
    note 'The previous OpenCode configuration is restored.'
  fi
  # The chat endpoint follows the server (it requires it).
  if (( api_was_active && server_was_active )) && [[ -f $UNIT_DIR/$API_UNIT ]]; then
    systemctl enable "$API_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$API_UNIT" || true
  else
    systemctl disable --now "$API_UNIT" >/dev/null 2>&1 || true
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
if [[ $OPENCODE_SKIP_CHAT_PROBE != true ]]; then
  chat_probe_body "$OPENCODE_MODEL" > "$stage/probe.json"
  status=$(api "$DIRECT_URL/v1/chat/completions" /dev/null "$stage/probe.json" "$CHAT_PROBE_TIMEOUT")
  [[ $status == 200 ]] ||
    fail "Direct model-server chat probe failed (HTTP $status): $(error_message < "$stage/response"). Check backend keys and that the model host admits the OpenCode CT address."
fi

# 2. The providers the dispatcher lists.
build_providers "$stage/providers.json"
mapfile -t new_providers < <(provider_ids < "$stage/providers.json")
[[ " ${new_providers[*]} " == *" osr "* ]] || fail 'The local dispatcher lists no usable model for provider osr.'
python3 -c 'import json,sys
models = json.load(open(sys.argv[1]))["osr"]["models"]
sys.exit(0 if sys.argv[2] in models else 1)' "$stage/providers.json" "$OPENCODE_MODEL" ||
  fail "The local dispatcher does not offer OPENCODE_MODEL '$OPENCODE_MODEL' (no tool support or less than $OPENCODE_CONTEXT_LENGTH tokens of context on every server)."
providers_sha256=$(sha256sum "$stage/providers.json" | cut -d' ' -f1)

# 3. The release: the unit runs /usr/local/bin/opencode -> current/opencode.
ln -sfn -- "$release_dir" "$CURRENT"
ln -sfn -- "$CURRENT/opencode" "$BIN_LINK"

# 4. OpenCode's configuration. The server password and the Open Terminal key
# live in a root-only environment file systemd reads; opencode.json holds no
# secret.
if [[ ! -s $OC_ETC/password ]]; then
  openssl rand -hex 32 > "$OC_ETC/password.new"
  chmod 0600 "$OC_ETC/password.new"
  mv -f -- "$OC_ETC/password.new" "$OC_ETC/password"
fi
touch "$OC_ENV"
chmod 0600 "$OC_ENV"
ENV_SET_OPENCODE_PASSWORD=$(tr -d '\r\n' < "$OC_ETC/password") ENV_SET_OSR_OPENCODE_BIND=$bind \
  ENV_SET_OSR_OPENCODE_PORT=$OPENCODE_PORT env_file_update "$OC_ENV"
if [[ $OPENCODE_FREE_MODELS == true ]]; then
  ENV_UNSET_OPENCODE_DISABLE_FREE_MODELS=1 env_file_update "$OC_ENV"
else
  ENV_SET_OPENCODE_DISABLE_FREE_MODELS=1 env_file_update "$OC_ENV"
fi
if [[ -n $OPEN_TERMINAL_URL ]]; then
  ENV_SET_OSR_OPEN_TERMINAL_KEY=$ot_key env_file_update "$OC_ENV"
else
  ENV_UNSET_OSR_OPEN_TERMINAL_KEY=1 env_file_update "$OC_ENV"
fi
unset ot_key
chown root:root "$OC_ENV"
chmod 0600 "$OC_ENV"
honcho_spec=''
if [[ -n $HONCHO_URL ]]; then
  # Honcho's OpenCode plugin (hooks: it records every turn and injects memory,
  # whatever the model) reads ~/.honcho/config.json. An exact release stays
  # pinned: OpenCode installs it at startup and does not update it.
  honcho_spec="$HONCHO_PLUGIN@$HONCHO_PLUGIN_VERSION"
  install -d -m 0700 -o "$OC_USER" -g "$OC_USER" "$(dirname -- "$HONCHO_CONFIG")"
  honcho_config "$HONCHO_CONFIG" "$HONCHO_URL" "$HONCHO_API_KEY_FILE" "$honcho_workspace"
  chown "$OC_USER:$OC_USER" "$HONCHO_CONFIG"
  chmod 0600 "$HONCHO_CONFIG"
elif [[ -n $prev_honcho_url ]]; then
  # The last run set up Honcho; HONCHO_URL is now empty, so turn it off.
  rm -f -- "$HONCHO_CONFIG"
  [[ $honcho_key_owned == false ]] || rm -f -- "$HONCHO_API_KEY_FILE"
  note 'The OpenCode Honcho plugin is removed.'
fi
ot_prev=0
if [[ -z $OPEN_TERMINAL_URL && -n $prev_ot_url ]]; then
  ot_prev=1
  [[ $ot_key_owned == false ]] || rm -f -- "$OPEN_TERMINAL_KEY_FILE"
  note 'Open Terminal is disconnected from OpenCode.'
fi
old_providers=-
[[ ! -s $OC_ETC/providers.json ]] || old_providers=$OC_ETC/providers.json
OC_OT_URL=$OPEN_TERMINAL_URL OC_OT_PREV=$ot_prev OC_HONCHO_SPEC=$honcho_spec \
  opencode_config "$OC_CONFIG" "$stage/providers.json" "$old_providers" "$OPENCODE_MODEL" ||
  fail "Could not write $OC_CONFIG."
chown "$OC_USER:$OC_USER" "$OC_CONFIG"
chmod 0600 "$OC_CONFIG"
install -m 0644 "$stage/providers.json" "$OC_ETC/providers.json"

# 5. The server.
install -m 0644 "$source_dir/$UNIT" "$UNIT_DIR/$UNIT"
systemctl daemon-reload
systemctl enable "$UNIT" >/dev/null
systemctl restart "$UNIT"
wait_server ||
  fail "$UNIT did not answer on port $OPENCODE_PORT with default model osr/$OPENCODE_MODEL within ${HEALTH_TIMEOUT}s. Check: journalctl -u $UNIT"

# 6. The OpenAI-compatible chat endpoint for Open WebUI: its own account, which
# gets the server password and its bearer key only through a root-only
# environment file systemd reads. The key is made once and kept, also while
# the endpoint is off, so Open WebUI's connection stays valid.
if [[ $OPENCODE_API == true ]]; then
  if [[ ! -s $API_KEY ]]; then
    openssl rand -hex 32 > "$API_KEY.new"
    chmod 0600 "$API_KEY.new"
    mv -f -- "$API_KEY.new" "$API_KEY"
  fi
  api_key_sha256=$(tr -d '\r\n' < "$API_KEY" | sha256sum | cut -d' ' -f1)
  touch "$API_ENV"
  chmod 0600 "$API_ENV"
  ENV_SET_OPENCODE_PASSWORD=$(tr -d '\r\n' < "$OC_ETC/password") ENV_SET_OPENCODE_API_KEY=$(tr -d '\r\n' < "$API_KEY") \
    ENV_SET_OPENCODE_PORT=$OPENCODE_PORT ENV_SET_OPENCODE_API_PORT=$OPENCODE_API_PORT \
    ENV_SET_OPENCODE_API_PERMISSIONS=$OPENCODE_API_PERMISSIONS ENV_SET_OPENCODE_API_MODEL=$API_MODEL \
    env_file_update "$API_ENV"
  chown root:root "$API_ENV"
  chmod 0600 "$API_ENV"
  install -m 0644 "$source_dir/openai-proxy.py" "$API_LIB"
  install -m 0644 "$source_dir/$API_UNIT" "$UNIT_DIR/$API_UNIT"
  systemctl daemon-reload
  systemctl enable "$API_UNIT" >/dev/null
  systemctl restart "$API_UNIT"
  wait_api ||
    fail "$API_UNIT did not answer /healthz and /v1/models on port $OPENCODE_API_PORT within ${HEALTH_TIMEOUT}s. Check: journalctl -u $API_UNIT"
elif [[ -f $UNIT_DIR/$API_UNIT || -f $API_ENV ]]; then
  systemctl disable --now "$API_UNIT" >/dev/null 2>&1 || true
  rm -f -- "$UNIT_DIR/$API_UNIT" "$API_LIB" "$API_ENV"
  systemctl daemon-reload
  note "The OpenAI-compatible chat endpoint is off ($API_UNIT removed; Open WebUI's connection to it no longer answers)."
fi
write_settings

trap - ERR
# The key now lives in the dispatcher's own file.
rm -f -- "$ROUTER_API_KEY_FILE"
# Keep the release now running and the one before it (for a manual switch back).
keep_prev=$(basename -- "${prev_link:-none}")
for dir in "$RELEASES"/*/; do
  dir=${dir%/}
  name=$(basename -- "$dir")
  [[ $name == "$release_name" || $name == "$keep_prev" ]] || rm -rf -- "$dir"
done
note "OpenCode $want_version ($release_name) discovers via $ROUTER_URL and calls model servers directly with model osr/$OPENCODE_MODEL (context $OPENCODE_CONTEXT_LENGTH)."
exact_version "$OPENCODE_VERSION" || note "Pin this release with OPENCODE_VERSION=$want_version."
if [[ $OPENCODE_WEB == true ]]; then
  note "Web UI: http://$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}'):$OPENCODE_PORT/ (user opencode, password in $OC_ETC/password)."
fi
if [[ $OPENCODE_API == true ]]; then
  note "Chat endpoint: http://<CT IPv4>:$OPENCODE_API_PORT/v1, model $API_MODEL (bearer key in $API_KEY; tool permissions: $OPENCODE_API_PERMISSIONS)."
fi
[[ -z $HONCHO_URL ]] || note "Honcho memory: plugin $honcho_spec, workspace $honcho_workspace (OpenCode installs the plugin in the background on its first start; check with /honcho:status)."
note "Run the CLI with: runuser -u $OC_USER -- env HOME=$OC_USER_HOME OPENCODE_PASSWORD=\$(cat $OC_ETC/password) opencode --server http://127.0.0.1:$OPENCODE_PORT"
