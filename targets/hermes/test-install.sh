#!/usr/bin/env bash
# Exercise install-target.sh: its helpers and dry runs, then whole runs against
# a temporary tree with stubbed apt, runuser, systemctl, the upstream installer
# and a fake router and Hermes API (curl). Nothing is downloaded, installed or
# started. End-to-end cases need root (like the other targets' install tests).
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/install-target.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/hermes-test.XXXXXX")
cleanup() {
  [[ $tmp_root == "${TMPDIR:-/tmp}"/hermes-test.* ]] || return
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

# --- syntax, dry runs and validation --------------------------------------------
bash -n "$script" || fail 'shell syntax'
out=$(ROUTER_URL=http://192.168.11.80:8000 bash "$script" --dry-run) || fail 'dry run'
[[ $out == *'provider=custom'* && $out == *'model=auto'* && $out == *'--non-interactive'* ]] ||
  fail "dry run omitted the installer or router configuration: $out"
[[ $out == *'api_key=<router key>'* && $out == *'with the router API key'* ]] || fail 'dry run omitted the router key'
[[ $out == *'--channel stable'* && $out == *'offering a tool'* ]] || fail 'dry run omitted the channel or chat probe'
[[ $out == *'no API server'* ]] || fail 'dry run without HERMES_API_SERVER'
out=$(ROUTER_URL=http://r:8000 HERMES_API_SERVER=true HERMES_COMMIT="$(printf 'a%.0s' {1..40})" \
  bash "$script" --dry-run) || fail 'dry run with the API server'
[[ $out == *'API server on 0.0.0.0:8642 as model hermes-agent'* && $out == *'--commit aaaa'* ]] ||
  fail "dry run omitted the API server or pin: $out"
pass 'dry runs plan the official installer, the router key, the chat probe and the API server'

refused() { if env "$@" bash "$script" --dry-run >/dev/null 2>&1; then fail "accepted: $*"; fi; }
refused ROUTER_URL=http://bad-host:8000/v1
refused ROUTER_URL=http://router:8000 HERMES_MODEL='bad model'
refused ROUTER_URL=http://router:8000 HERMES_CONTEXT_LENGTH=32768
refused ROUTER_URL=http://router:8000 HERMES_CONTEXT_LENGTH=63999
refused ROUTER_URL=http://router:8000 HERMES_COMMIT=abc123
refused ROUTER_URL=http://router:8000 HERMES_INSTALLER_SHA256=xyz
refused ROUTER_URL=http://router:8000 HERMES_CHANNEL=nightly
refused ROUTER_URL=http://router:8000 HERMES_API_PORT=8645
refused ROUTER_URL=http://router:8000 HERMES_API_SERVER=yes
msg=$(ROUTER_URL=http://router:8000 HERMES_CONTEXT_LENGTH=8192 bash "$script" --dry-run 2>&1 || true)
[[ $msg == *'at least 64000'* ]] || fail "context refusal does not explain the minimum: $msg"
ROUTER_URL=http://router:8000 HERMES_CONTEXT_LENGTH=64000 bash "$script" --dry-run >/dev/null || fail '64000 refused'
pass 'invalid endpoint, model, context below 64K, pins, channel and reserved ports are refused'

# --- helpers in isolation ----------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Install helpers/{c=1;next} /^# End install helpers\./{c=0} c' "$script")
for helper in settings_record env_file_update env_file_get models_has chat_probe_body error_message; do
  declare -F "$helper" >/dev/null || fail "helper extraction failed: $helper"
done
envf=$tmp_root/helper.env
printf '# keep me\nOPENAI_API_KEY=no-key\nOTHER=1\nAPI_SERVER_PORT=1\nAPI_SERVER_PORT=2\n' > "$envf"
ENV_SET_API_SERVER_PORT=8642 ENV_SET_NEW='a=b c' ENV_UNSET_OTHER=1 ENV_UNSET_IF_OPENAI_API_KEY=no-key \
  env_file_update "$envf"
[[ $(< "$envf") == $'# keep me\nAPI_SERVER_PORT=8642\nNEW=a=b c' ]] || fail "env_file_update: $(< "$envf")"
printf 'OPENAI_API_KEY=sk-real\n' > "$envf"
ENV_UNSET_IF_OPENAI_API_KEY=no-key env_file_update "$envf"
[[ $(< "$envf") == 'OPENAI_API_KEY=sk-real' ]] || fail 'a real OPENAI_API_KEY was removed'
[[ $(env_file_get "$envf" OPENAI_API_KEY) == sk-real && -z $(env_file_get "$envf" NONE) ]] || fail env_file_get
pass 'the .env editor sets, removes and keeps lines, and only drops the old no-key placeholder'

# settings_record reads these globals.
# shellcheck disable=SC2034
ROUTER_URL=http://r:8000 HERMES_MODEL=auto HERMES_CONTEXT_LENGTH=65536 HERMES_CHANNEL=stable HERMES_COMMIT=
# shellcheck disable=SC2034
HERMES_API_SERVER=true HERMES_API_PORT=8642 HERMES_API_MODEL_NAME=hermes-agent unit_sha256=u
router_key_sha256=$(printf 'sk-secret-key' | sha256sum | cut -d' ' -f1)
record=$(settings_record)
[[ $record == *"ROUTER_KEY_SHA256=$router_key_sha256"* && $record != *sk-secret-key* ]] ||
  fail 'the settings record must hold the key hash, never the key'
printf '{"data":[{"id":"auto"},{"id":"qwen3:32b"}]}' | models_has qwen3:32b || fail models_has
if printf '{"data":[{"id":"auto"}]}' | models_has qwen3:32b; then fail 'models_has matched a missing id'; fi
chat_probe_body auto | python3 -c 'import json,sys; b=json.load(sys.stdin); assert b["tools"] and b["model"]=="auto"' ||
  fail 'the chat probe must offer a tool'
[[ $(printf '{"error":{"message":"m does not support tools"}}' | error_message) == 'm does not support tools' ]] ||
  fail error_message
pass 'settings, model listing, the tool probe body and error parsing'

unit=$here/hermes-gateway.service
grep -qx 'ExecStart=/home/hermes/.local/bin/hermes gateway run' "$unit" || fail 'unit ExecStart'
grep -qx 'User=hermes' "$unit" || fail 'unit runs as hermes'
grep -qx 'ProtectHome=read-only' "$unit" && grep -qx 'ReadWritePaths=/home/hermes' "$unit" || fail 'unit home access'
grep -q 'API_SERVER_KEY=' <(grep -v '^#' "$unit") && fail 'the API key must not be in the unit'
pass 'the gateway unit runs hardened as hermes and carries no secret'

# --- whole-script runs --------------------------------------------------------------
if (( EUID != 0 )); then
  printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
  printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
  exit 0
fi

bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
state=$tmp_root/state; mkdir -p "$state"
export FAKE_LOG=$log FAKE_STATE=$state
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
for command_name in apt-get chown sleep; do stub "$command_name" 'exit 0'; done
stub useradd 'touch "$FAKE_STATE/user"; mkdir -p "$HERMES_USER_HOME"'
stub id '[[ -e $FAKE_STATE/user ]]'
stub getent '[[ $1 == passwd && -e $FAKE_STATE/user ]] && printf "hermes:x:1000:1000::%s:/bin/bash\n" "$HERMES_USER_HOME"'
# runuser -u USER -- CMD...: run CMD as the caller (no hermes account here).
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
# install: drop -o/-g (the hermes account does not exist here).
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub git '[[ $1 == -C && $3 == rev-parse ]] || exit 1; cat "$2/.commit" 2>/dev/null || exit 128'
stub systemctl 'case $1 in
  is-active) [[ -e $FAKE_STATE/active ]] ;;
  restart) touch "$FAKE_STATE/active" ;;
  disable) [[ $2 != --now ]] || rm -f "$FAKE_STATE/active" ;;
esac; exit 0'
# The upstream installer: logs its arguments, writes the launcher and a checkout.
cat > "$tmp_root/upstream-install.sh" <<'UP'
#!/usr/bin/env bash
echo "upstream-install $*" >> "$FAKE_LOG"
commit=cafe000000000000000000000000000000000000
while (( $# )); do [[ $1 == --commit ]] && commit=$2; shift; done
[[ -n ${FAKE_PIN_IGNORED:-} ]] && commit=$FAKE_PIN_IGNORED
mkdir -p "$HERMES_HOME/hermes-agent" "$HOME/.local/bin"
printf '%s\n' "$commit" > "$HERMES_HOME/hermes-agent/.commit"
cat > "$HOME/.local/bin/hermes" <<'HERMES'
#!/usr/bin/env bash
echo "hermes $*" >> "$FAKE_LOG"
case $1 in
  --version) echo 'Hermes Agent 0.0-test' ;;
  config)
    [[ $2 == set ]] || exit 2
    [[ ${FAKE_CONFIG_FAIL:-} != "$3" ]] || exit 1
    grep -v "^$3=" "$HERMES_HOME/config.kv" > "$HERMES_HOME/config.kv.new" 2>/dev/null || true
    printf '%s=%s\n' "$3" "$4" >> "$HERMES_HOME/config.kv.new"
    mv "$HERMES_HOME/config.kv.new" "$HERMES_HOME/config.kv"
    touch "$HERMES_HOME/config.yaml" ;;
esac
HERMES
chmod +x "$HOME/.local/bin/hermes"
UP
# curl: the router, the upstream download and the Hermes API server.
cat > "$bin/curl" <<'CURL'
#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
log, state = os.environ["FAKE_LOG"], os.environ["FAKE_STATE"]
with open(log, "a") as f:
    f.write("curl " + " ".join(args) + "\n")
out = fmt = data = None
headers, url = [], None
i = 0
while i < len(args):
    a = args[i]
    if a in ("-o", "-w", "-H", "--data-binary", "--max-time"):
        v = args[i + 1]; i += 2
        if a == "-o": out = v
        elif a == "-w": fmt = v
        elif a == "-H": headers.append(open(v[1:]).read().strip() if v.startswith("@") else v)
        elif a == "--data-binary": data = open(v[1:]).read()
        continue
    if a.startswith("http"):
        url = a
    i += 1
auth = next((h.split(" ", 2)[2] for h in headers if h.lower().startswith("authorization: bearer ")), "")
def env_file(key):
    path = os.path.join(os.environ["HERMES_USER_HOME"], ".hermes/.env")
    try:
        for line in open(path):
            k, _, v = line.rstrip("\n").partition("=")
            if k == key: return v
    except FileNotFoundError:
        pass
    return ""
def reply(status, body):
    if out:
        with open(out, "w") as f:
            f.write(body if isinstance(body, str) else json.dumps(body))
    if fmt:
        sys.stdout.write(str(status))
    sys.exit(0)
def refused():
    sys.stderr.write("curl: (7) Failed to connect\n")
    if fmt: sys.stdout.write("000")
    sys.exit(7)
router = os.environ.get("FAKE_ROUTER_URL", "http://192.168.11.80:8000")
if url == "https://hermes-agent.nousresearch.com/install.sh":
    with open(out, "w") as f:
        f.write(open(os.environ["FAKE_INSTALLER"]).read())
    sys.exit(0)
if url.startswith(router):
    if os.environ.get("FAKE_ROUTER_DOWN"): refused()
    if auth != os.environ.get("FAKE_ROUTER_KEY", ""):
        reply(401, {"error": {"message": "Invalid or missing API key", "code": "invalid_api_key"}})
    if url.endswith("/v1/models"):
        ids = os.environ.get("FAKE_MODELS", "auto,fast,large,qwen3:32b").split(",")
        reply(200, {"object": "list", "data": [{"id": m} for m in ids]})
    if url.endswith("/v1/chat/completions"):
        with open(os.path.join(state, "probe.json"), "w") as f: f.write(data or "")
        status = int(os.environ.get("FAKE_CHAT_STATUS", "200"))
        if status != 200:
            reply(status, {"error": {"message": os.environ.get("FAKE_CHAT_ERROR", "boom")}})
        reply(200, {"choices": [{"message": {"role": "assistant", "content": "ready"}}]})
if url.startswith("http://127.0.0.1:"):
    port = url.split(":")[2].split("/")[0]
    if not os.path.exists(os.path.join(state, "active")): refused()
    if port != env_file("API_SERVER_PORT") or port == os.environ.get("FAKE_BAD_PORT"): refused()
    if url.endswith("/health"):
        reply(200, {"status": "ok"})
    if url.endswith("/v1/models"):
        if not auth or auth != env_file("API_SERVER_KEY"):
            reply(401, {"error": {"message": "Invalid API key"}})
        reply(200, {"object": "list", "data": [{"id": env_file("API_SERVER_MODEL_NAME") or "hermes-agent"}]})
sys.stderr.write(f"fake curl: unexpected {url}\n")
sys.exit(22)
CURL
chmod +x "$bin/curl"
if ! command -v openssl >/dev/null; then
  stub openssl 'python3 -c "import secrets; print(secrets.token_hex(32))"'
fi

deploy=$tmp_root/deploy
home=$tmp_root/home/hermes
etc=$tmp_root/etc/hermes-target
units=$tmp_root/systemd
reset_tree() {
  rm -rf -- "${deploy:?}" "${tmp_root:?}/home" "${tmp_root:?}/etc" "${units:?}" "${state:?}"/* "${log:?}"
  mkdir -p "$deploy" "$units" "$tmp_root/etc"
  cp "$script" "$here/hermes-gateway.service" "$deploy/"
  : > "$log"
}
router_key=sk-router-0123456789abcdef
push_key() { printf '%s\n' "${1:-$router_key}" > "$deploy/router-api-key"; chmod 0600 "$deploy/router-api-key"; }
# guest [VAR=value ...]: run the deployed installer in the fake tree.
guest() {
  env PATH="$bin:$PATH" HERMES_USER_HOME="$home" HERMES_ETC="$etc" UNIT_DIR="$units" \
    LOCK_FILE="$tmp_root/etc/hermes-target.lock" HEALTH_TIMEOUT=2 \
    FAKE_INSTALLER="$tmp_root/upstream-install.sh" FAKE_ROUTER_KEY="$router_key" \
    ROUTER_URL=http://192.168.11.80:8000 HERMES_API_SERVER=true "$@" \
    bash "$deploy/install-target.sh" 2>&1
}
kv() { awk -v k="$1" -F= '$1==k {sub(/^[^=]*=/,""); print; exit}' "$2"; }

# 1. A fresh install with the API server.
reset_tree; push_key
out=$(guest) || fail "fresh install: $out"
grep -q 'upstream-install --non-interactive --skip-browser --skip-computer-use --channel stable' "$log" ||
  fail 'upstream installer flags'
config=$home/.hermes/config.kv
[[ $(kv model.provider "$config") == custom && $(kv model.base_url "$config") == http://192.168.11.80:8000/v1 ]] ||
  fail "provider config: $(cat "$config")"
[[ $(kv model.api_key "$config") == "$router_key" ]] || fail 'model.api_key is not the router key'
[[ $(kv model.context_length "$config") == 65536 && $(kv model.default "$config") == auto ]] || fail 'model and context'
env_file=$home/.hermes/.env
[[ $(kv ROUTER_API_KEY "$env_file") == "$router_key" ]] || fail 'ROUTER_API_KEY not kept for reruns'
[[ $(kv API_SERVER_ENABLED "$env_file") == true && $(kv API_SERVER_HOST "$env_file") == 0.0.0.0 ]] || fail 'API server env'
[[ $(kv API_SERVER_PORT "$env_file") == 8642 && $(kv API_SERVER_MODEL_NAME "$env_file") == hermes-agent ]] || fail 'API port/name'
[[ $(kv API_SERVER_KEY "$env_file") == "$(< "$etc/api-key")" && $(wc -c < "$etc/api-key") -ge 64 ]] || fail 'API key'
[[ $(stat -c %a "$env_file") == 600 && $(stat -c %a "$etc/api-key") == 600 ]] || fail 'secret file modes'
[[ ! -e $deploy/router-api-key ]] || fail 'the pushed router key was not removed'
[[ -f $units/hermes-gateway.service && -e $state/active ]] || fail 'gateway unit not installed and started'
grep -q "ROUTER_KEY_SHA256=$(printf '%s' "$router_key" | sha256sum | cut -d' ' -f1)" "$etc/settings" || fail 'settings key hash'
grep -q "$router_key" "$etc/settings" && fail 'the settings record holds the router key'
grep '^curl ' "$log" | grep -q "$router_key" && fail 'the router key was passed to curl in argv'
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["tools"]' "$state/probe.json" ||
  fail 'the chat probe did not offer a tool'
[[ $out == *'Pin this version with HERMES_COMMIT=cafe'* ]] || fail 'the installed commit is not reported'
pass 'fresh install: router key as model.api_key, API server, unit started, key file removed, key never in curl argv'

# 2. Unchanged: nothing to do.
: > "$log"
out=$(guest) || fail "rerun: $out"
[[ $out == *'nothing to do'* ]] || fail "unchanged rerun did work: $out"
grep -qE '^(apt-get|upstream-install|systemctl restart)' "$log" && fail 'unchanged rerun touched packages or the unit'
pass 'an unchanged, healthy installation is left alone'

# 3. The router key was rotated: a new key file is applied.
old_api_key=$(< "$etc/api-key")
router_key=sk-router-rotated-999999
push_key
out=$(guest) || fail "rotation: $out"
[[ $(kv model.api_key "$config") == "$router_key" && $(kv ROUTER_API_KEY "$env_file") == "$router_key" ]] ||
  fail 'the rotated key was not applied'
[[ $(< "$etc/api-key") == "$old_api_key" ]] || fail 'the API server key changed on a router key rotation'
grep -q '^upstream-install' "$log" && fail 'a key rotation reinstalled Hermes'
pass 'a rotated router key is applied on rerun, keeping the API server key and the checkout'

# 4. The router rejects the configured key (rotated on the router, not pushed).
before=$(cat "$config" "$env_file")
out=$(guest FAKE_ROUTER_KEY=sk-router-something-else) && fail 'a rejected key was accepted'
[[ $out == *'rejected the API key'*'--reconfigure'* ]] || fail "rejected key message: $out"
[[ $(cat "$config" "$env_file") == "$before" ]] || fail 'a rejected key changed the configuration'
pass 'a key the router rejects stops the run before anything changes, and says how to fix it'

# 5. No key at all against a router that requires one.
reset_tree
out=$(guest) && fail 'a missing key was accepted'
[[ $out == *'requires its API key'* ]] || fail "missing key message: $out"
grep -q '^apt-get install -y --no-install-recommends ca-certificates curl git' "$log" && fail 'packages installed before the probe'
pass 'a router that needs a key and gets none is reported before anything is installed'

# 6. The tool probe fails: nothing is installed, the error names tools.
reset_tree; push_key
out=$(guest FAKE_CHAT_STATUS=400 FAKE_CHAT_ERROR='registry.ollama.ai/library/gemma3:12b does not support tools') &&
  fail 'a failed tool probe was accepted'
[[ $out == *'does not support tools'*'tool-capable model'*'Nothing was changed'* ]] || fail "probe message: $out"
[[ ! -e $home/.hermes/config.kv ]] || fail 'configuration written after a failed probe'
grep -q '^upstream-install' "$log" && fail 'Hermes installed after a failed probe'
[[ -e $deploy/router-api-key ]] || fail 'the key file must stay for a retry'
rm -f "$state/probe.json"
out=$(guest FAKE_CHAT_STATUS=400 HERMES_SKIP_CHAT_PROBE=true) || fail "skip probe: $out"
[[ ! -e $state/probe.json ]] || fail 'HERMES_SKIP_CHAT_PROBE still sent a chat request'
pass 'a failed tool-call probe stops the install with a tool hint; it can be skipped explicitly'

# 7. Unknown model, unreachable router.
reset_tree; push_key
out=$(guest HERMES_MODEL=nope:1b) && fail 'an unadvertised model was accepted'
[[ $out == *"does not advertise model 'nope:1b'"* ]] || fail "model message: $out"
out=$(guest FAKE_ROUTER_DOWN=1) && fail 'an unreachable router was accepted'
[[ $out == *'unreachable'* ]] || fail "unreachable message: $out"
pass 'an unadvertised model or an unreachable router is reported before anything changes'

# 8. A gateway that does not come up after a change: the previous one is back.
reset_tree; push_key
guest >/dev/null || fail 'setup for the gateway rollback'
prev_env=$(< "$env_file"); prev_settings=$(< "$etc/settings")
out=$(guest HERMES_API_PORT=8650 FAKE_BAD_PORT=8650) && fail 'an unhealthy gateway was accepted'
[[ $out == *'did not answer'*'running again'* ]] || fail "gateway rollback message: $out"
[[ $(< "$env_file") == "$prev_env" && $(< "$etc/settings") == "$prev_settings" ]] || fail 'rollback did not restore .env and settings'
[[ -e $state/active ]] || fail 'the previous gateway is not running'
pass 'a gateway that fails its health check after a change is rolled back and running again'

# 9. The previous gateway fails too: every loopback call is refused.
mv "$bin/curl" "$bin/curl.real"
cat > "$bin/curl" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ \$a == http://127.0.0.1:* ]]; then
    [[ " \$* " == *" -w "* ]] && printf 000
    exit 7
  fi
done
exec "$bin/curl.real" "\$@"
WRAP
chmod +x "$bin/curl"
out=$(guest HERMES_API_PORT=8650) && fail 'a double failure was accepted'
mv -f "$bin/curl.real" "$bin/curl"
[[ $out == *'did not become healthy either'* ]] || fail "double failure message: $out"
pass 'a rollback whose previous gateway does not come back either is reported as failed too'

# 10. A configuration command fails: the files are restored by the ERR trap.
reset_tree; push_key
guest >/dev/null || fail 'setup for the config failure'
prev_config=$(< "$config"); prev_env=$(< "$env_file")
out=$(guest HERMES_CONTEXT_LENGTH=131072 FAKE_CONFIG_FAIL=model.context_length) && fail "a failed config set was accepted: $out"
[[ $out == *'running again'* ]] || fail "config rollback message: $out"
[[ $(< "$env_file") == "$prev_env" ]] || fail '.env not restored'
grep -q '^model.context_length=65536$' "$config" || fail "config not restored: $(cat "$config")"
[[ $(grep -c . <<< "$prev_config") -ge 5 ]] || fail 'setup config incomplete'
pass 'a failing configuration command restores config.yaml, .env and the unit'

# 11. Switching the API server off removes the unit and the API settings.
out=$(guest HERMES_API_SERVER=false) || fail "API server off: $out"
[[ ! -e $units/hermes-gateway.service && ! -e $state/active ]] || fail 'the unit was not removed'
grep -q '^API_SERVER_' "$env_file" && fail 'API server settings left in .env'
[[ $(kv ROUTER_API_KEY "$env_file") == "$router_key" ]] || fail 'ROUTER_API_KEY lost'
pass 'HERMES_API_SERVER=false stops and removes the gateway and its settings'

# 12. An install made by the first version of this target is migrated.
reset_tree; push_key
guest HERMES_API_SERVER=false >/dev/null || fail 'setup for migration'
printf 'ROUTER_URL=http://192.168.11.80:8000\nHERMES_MODEL=auto\nHERMES_CONTEXT_LENGTH=65536\n' > "$etc/settings"
printf 'OPENAI_API_KEY=no-key\n' >> "$env_file"
push_key
out=$(guest HERMES_API_SERVER=false) || fail "migration: $out"
grep -q '^OPENAI_API_KEY=' "$env_file" && fail 'the old no-key placeholder was kept'
[[ $(kv model.api_key "$config") == "$router_key" ]] || fail 'migration did not set model.api_key'
pass 'an install from the first version gets the router key and loses the no-key placeholder'

# 13. Pins: the commit is passed, a changed pin re-runs the installer, and an
# installer whose SHA-256 differs is refused.
reset_tree; push_key
pin=$(printf 'b%.0s' {1..40})
out=$(guest HERMES_COMMIT="$pin") || fail "pinned install: $out"
grep -q -- "--commit $pin" "$log" || fail 'the pin was not passed to the installer'
: > "$log"
out=$(guest HERMES_COMMIT="$pin") || fail "pinned rerun: $out"
[[ $out == *'nothing to do'* ]] || fail 'an unchanged pinned install did work'
pin2=$(printf 'c%.0s' {1..40})
out=$(guest HERMES_COMMIT="$pin2") || fail "re-pin: $out"
grep -q -- "--commit $pin2" "$log" || fail 'a changed pin did not re-run the installer'
out=$(guest HERMES_COMMIT="$(printf 'd%.0s' {1..40})" FAKE_PIN_IGNORED="$pin2") && fail 'an unapplied pin was accepted'
[[ $out == *'not HERMES_COMMIT'* ]] || fail "pin mismatch message: $out"
reset_tree; push_key
out=$(guest HERMES_INSTALLER_SHA256="$(printf '0%.0s' {1..64})") && fail 'a mismatching installer was run'
[[ $out == *"not HERMES_INSTALLER_SHA256"* ]] || fail "installer checksum message: $out"
grep -q '^upstream-install' "$log" && fail 'the mismatching installer ran'
good=$(sha256sum "$tmp_root/upstream-install.sh" | cut -d' ' -f1)
out=$(guest HERMES_INSTALLER_SHA256="$good") || fail "matching installer checksum: $out"
pass 'commit and installer pins are applied, re-applied when changed, and enforced'

# 14. One run at a time.
exec {held}>>"$tmp_root/etc/hermes-target.lock"
flock "$held"
out=$(guest) && fail 'a second concurrent run was accepted'
[[ $out == *'Another install-target.sh run holds'* ]] || fail "lock message: $out"
exec {held}>&-
pass 'a second concurrent run is refused'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
