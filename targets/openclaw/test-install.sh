#!/usr/bin/env bash
# Exercise install-target.sh: its helpers and dry runs, then whole runs against
# a temporary tree with stubbed apt, runuser, systemctl, nvm, npm, openclaw and
# a fake router, dispatcher and Gateway (curl). Nothing is downloaded,
# installed or started. End-to-end cases need root (like the other targets'
# install tests).
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/install-target.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/openclaw-test.XXXXXX")
cleanup() {
  [[ $tmp_root == "${TMPDIR:-/tmp}"/openclaw-test.* ]] || return
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

# --- syntax, dry runs and validation --------------------------------------------
bash -n "$script" || fail 'shell syntax'
deploy_dry=$tmp_root/dry; mkdir -p "$deploy_dry"
cp "$script" "$here/openclaw-gateway.service" "$here/openclaw-direct.service" "$deploy_dry/"
cp "$here/../hermes/direct-dispatch.py" "$deploy_dry/"
dry() { env "$@" bash "$deploy_dry/install-target.sh" --dry-run; }
out=$(dry ROUTER_URL=http://192.168.11.80:8000) || fail 'dry run'
[[ $out == *'nvm v0.40.4 from https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh (SHA-256 4b7412c4'* ]] ||
  fail "dry run omitted the pinned nvm installer: $out"
[[ $out == *'nvm install 24, npm install -g openclaw@latest'* ]] || fail 'dry run omitted Node or OpenClaw'
[[ $out == *'baseUrl http://127.0.0.1:8765/v1, api openai-completions, apiKey <local placeholder>'* && $out == *'model osr/auto'* ]] ||
  fail 'dry run omitted the osr provider'
[[ $out == *'with the router API key'* && $out == *'offering a tool'* ]] || fail 'dry run omitted the router check or chat probe'
[[ $out == *'/v1/chat/completions stays disabled'* && $out == *'bind lan'* && $out == *'Control UI on http://'* ]] ||
  fail "dry run without OPENCLAW_API: $out"
[[ $out != *ollama.com* ]] || fail 'the plan installs Ollama (the router pool serves this agent)'
out=$(dry ROUTER_URL=http://r:8000 OPENCLAW_API=true OPENCLAW_DASHBOARD=false OPENCLAW_VERSION=2026.10.9 NVM_VERSION=v0.40.5) ||
  fail 'dry run with the API'
[[ $out == *'enable /v1/chat/completions; Open WebUI model openclaw'* && $out == *'Control UI disabled'* ]] || fail "API plan: $out"
[[ $out == *'openclaw@2026.10.9'* && $out == *'(SHA-256 unchecked)'* ]] || fail 'a different nvm release must not carry the v0.40.4 hash'
out=$(dry ROUTER_URL=http://r:8000 OPENCLAW_DASHBOARD=false) || fail 'loopback dry run'
[[ $out == *'bind loopback'* ]] || fail 'without Open WebUI and the Control UI the Gateway must stay on loopback'
pass 'dry runs plan nvm (pinned), Node, npm install -g openclaw, the osr provider and the Gateway; no Ollama'

refused() { if dry "$@" >/dev/null 2>&1; then fail "accepted: $*"; fi; }
refused ROUTER_URL=http://bad-host:8000/v1
msg=$(env -u ROUTER_URL bash "$deploy_dry/install-target.sh" --dry-run 2>&1 || true)
[[ $msg == *'ROUTER_URL is unset'* && $msg == *'provision-lxc.sh --reconfigure'* ]] || fail "missing router URL gives no recovery path: $msg"
refused ROUTER_URL=http://router:8000 OPENCLAW_MODEL='bad model'
refused ROUTER_URL=http://router:8000 OPENCLAW_CONTEXT_LENGTH=16384
refused ROUTER_URL=http://router:8000 OPENCLAW_MAX_TOKENS=64
refused ROUTER_URL=http://router:8000 OPENCLAW_CONTEXT_LENGTH=32768 OPENCLAW_MAX_TOKENS=20000
refused ROUTER_URL=http://router:8000 OPENCLAW_VERSION='latest; rm'
refused ROUTER_URL=http://router:8000 OPENCLAW_NODE_VERSION=22
refused ROUTER_URL=http://router:8000 OPENCLAW_NODE_VERSION=25
refused ROUTER_URL=http://router:8000 OPENCLAW_NODE_VERSION=24.16.0
refused ROUTER_URL=http://router:8000 NVM_VERSION=master
refused ROUTER_URL=http://router:8000 NVM_INSTALLER_SHA256=xyz
refused ROUTER_URL=http://router:8000 OPENCLAW_API=yes
refused ROUTER_URL=http://router:8000 OPENCLAW_DASHBOARD=yes
refused ROUTER_URL=http://router:8000 OPENCLAW_PORT=8765
refused ROUTER_URL=http://router:8000 OPENCLAW_PORT=70000
msg=$(ROUTER_URL=http://router:8000 OPENCLAW_CONTEXT_LENGTH=8192 bash "$deploy_dry/install-target.sh" --dry-run 2>&1 || true)
[[ $msg == *'at least 32768'* ]] || fail "context refusal does not explain the minimum: $msg"
msg=$(ROUTER_URL=http://router:8000 OPENCLAW_NODE_VERSION=24.20.0 bash "$deploy_dry/install-target.sh" --dry-run 2>&1 || true)
[[ $msg == *"below this target's security floor"* ]] || fail "old Node refusal: $msg"
dry ROUTER_URL=http://router:8000 OPENCLAW_NODE_VERSION=26.12.1 OPENCLAW_VERSION=beta >/dev/null || fail 'Node 26.12.1 or beta refused'
rm "$deploy_dry/direct-dispatch.py"
msg=$(dry ROUTER_URL=http://router:8000 2>&1 || true)
[[ $msg == *'Missing the OpenClaw units or direct dispatcher'* ]] || fail "missing dispatcher: $msg"
pass 'invalid endpoint, model, context, output budget, versions, Node lines, ports and a missing dispatcher are refused'

# --- helpers in isolation ----------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Install helpers/{c=1;next} /^# End install helpers\./{c=0} c' "$script")
for helper in settings_record env_file_update env_file_get models_has chat_probe_body error_message \
              version_of node_supported node_spec_matches exact_version origins_json providers_json kindi_target_names \
              provider_ids provider_entry; do
  declare -F "$helper" >/dev/null || fail "helper extraction failed: $helper"
done
envf=$tmp_root/helper.env
printf '# keep me\nOTHER=1\nOPENCLAW_GATEWAY_TOKEN=1\nOPENCLAW_GATEWAY_TOKEN=2\n' > "$envf"
ENV_SET_OPENCLAW_GATEWAY_TOKEN=abc ENV_SET_NEW='a=b c' ENV_UNSET_OTHER=1 env_file_update "$envf"
[[ $(< "$envf") == $'# keep me\nOPENCLAW_GATEWAY_TOKEN=abc\nNEW=a=b c' ]] || fail "env_file_update: $(< "$envf")"
[[ $(env_file_get "$envf" OPENCLAW_GATEWAY_TOKEN) == abc && -z $(env_file_get "$envf" NONE) ]] || fail env_file_get
pass 'the .env editor sets, removes and keeps lines'

[[ $(printf 'v24.22.1\n' | version_of) == 24.22.1 && $(printf 'OpenClaw 2026.10.10-beta.5 (abc)\n' | version_of) == 2026.10.10-beta.5 ]] ||
  fail version_of
for good in 24.22.1 24.30.0 26.12.1 27.0.0; do node_supported "$good" || fail "Node $good refused"; done
for bad in 24.22.0 24.16.0 25.1.0 26.12.0 22.20.0 v24.22.1 24; do
  if node_supported "$bad"; then fail "Node $bad accepted"; fi
done
node_spec_matches 24.30.0 24 && node_spec_matches 26.12.1 26.12.1 || fail 'node_spec_matches'
if node_spec_matches 26.12.1 24 || node_spec_matches 24.30.0 24.22.1; then fail 'node_spec_matches accepted another Node'; fi
exact_version 2026.10.9 && exact_version 2026.10.10-beta.5 || fail 'exact_version'
if exact_version latest || exact_version beta; then fail 'a dist-tag is not an exact version'; fi
[[ $(origins_json 18789 192.0.2.83 10.0.0.9) == '["http://192.0.2.83:18789","http://10.0.0.9:18789"]' ]] || fail origins_json
pass 'versions: target security floor (>=24.22.1 <25 or >=26.12.1), Node line pins, exact npm versions, Control UI origins'

printf '{"object":"list","data":[{"id":"qwen3:32b"},{"id":"auto"},{"id":"fast"}]}' > "$tmp_root/osr.json"
printf '{"data":[{"id":"tool-model","owned_by":"strata-a"}]}' > "$tmp_root/strata.json"
printf '{"strata-down":{"baseUrl":"x","models":[{"id":"kept"}]},"gone":{"baseUrl":"y"}}' > "$tmp_root/prev.json"
providers=$(providers_json 65536 8192 http://127.0.0.1:8765 "$tmp_root/prev.json" \
  "osr=$tmp_root/osr.json" "strata-a=$tmp_root/strata.json" strata-down=- never-listed=-)
python3 - "$providers" <<'PY' || fail "providers_json: $providers"
import json, sys
p = json.loads(sys.argv[1])
assert sorted(p) == ["osr", "strata-a", "strata-down"], sorted(p)
osr = p["osr"]
assert osr["baseUrl"] == "http://127.0.0.1:8765/v1" and osr["api"] == "openai-completions" and osr["apiKey"] == "no-key"
assert [m["id"] for m in osr["models"]] == ["auto", "fast", "qwen3:32b"]
m = osr["models"][0]
assert m["contextWindow"] == 65536 and m["maxTokens"] == 8192 and m["input"] == ["text"]
assert m["compat"] == {"supportsTools": True, "maxTokensField": "max_tokens"}
assert p["strata-a"]["baseUrl"] == "http://127.0.0.1:8765/t/strata-a/v1"
assert p["strata-down"] == {"baseUrl": "x", "models": [{"id": "kept"}]}
PY
[[ $(provider_ids <<< "$providers" | paste -sd' ') == 'osr strata-a strata-down' ]] || fail provider_ids
[[ $(provider_entry strata-a <<< "$providers") == *'"baseUrl":"http://127.0.0.1:8765/t/strata-a/v1"'* ]] || fail provider_entry
printf '{"data":[]}' > "$tmp_root/empty.json"
[[ $(providers_json 65536 8192 http://127.0.0.1:8765 - "osr=$tmp_root/empty.json") == '{}' ]] || fail 'a provider without models'
python3 -c 'import json,sys; p=json.loads(sys.argv[1]); assert not any("timeoutSeconds" in v for v in p.values())' "$providers" ||
  fail 'a pool without Kindi changed the providers'"'"' timeouts'
printf 'strata-a=strata+http://10.0.0.9:8080\nkindi-k=kindi+http://10.0.0.14:8093\n' > "$tmp_root/targets"
[[ $(kindi_target_names "$tmp_root/targets") == kindi-k ]] || fail kindi_target_names
printf '{"data":[{"id":"bonsai2-2b","owned_by":"kindi-k"}]}' > "$tmp_root/kindi.json"
providers=$(KINDI_TARGETS=kindi-k KINDI_CLIENT_TIMEOUT_SECONDS=9000 providers_json 65536 8192 http://127.0.0.1:8765 - \
  "osr=$tmp_root/osr.json" "strata-a=$tmp_root/strata.json" "kindi-k=$tmp_root/kindi.json")
python3 - "$providers" <<'PY' || fail "Kindi providers_json: $providers"
import json, sys
p = json.loads(sys.argv[1])
assert p["kindi-k"]["timeoutSeconds"] == 9000 and p["osr"]["timeoutSeconds"] == 9000
assert "timeoutSeconds" not in p["strata-a"]
PY
pass 'providers: osr first lists auto, each target its own server, a server that is down keeps its last models; Kindi and osr (with Kindi) wait an hour'

# settings_record reads these globals.
# shellcheck disable=SC2034
ROUTER_URL=http://r:8000 OPENCLAW_MODEL=auto OPENCLAW_CONTEXT_LENGTH=65536 OPENCLAW_MAX_TOKENS=8192 OPENCLAW_VERSION=latest
# shellcheck disable=SC2034
OPENCLAW_NODE_VERSION=24 NVM_VERSION=v0.40.4 OPENCLAW_API=true OPENCLAW_PORT=18789 OPENCLAW_DASHBOARD=true origins='[]'
# shellcheck disable=SC2034
backend_keys_sha256=none targets_sha256=none honcho_workspace=none providers_sha256=p unit_sha256=u HONCHO_URL='' honcho_key_sha256=none
# shellcheck disable=SC2034
OPEN_TERMINAL_URL='' ot_key_sha256=none
router_key_sha256=$(printf 'sk-secret-key' | sha256sum | cut -d' ' -f1)
record=$(settings_record)
[[ $record == *"ROUTER_KEY_SHA256=$router_key_sha256"* && $record != *sk-secret-key* ]] ||
  fail 'the settings record must hold the key hash, never the key'
[[ $record == *$'\nOPENCLAW_CONTEXT_LENGTH=65536\n'* && $record == *$'\nOPENCLAW_API=true\n'* ]] || fail 'the dispatcher and provisioner read these from the record'
printf '{"data":[{"id":"auto"},{"id":"qwen3:32b"}]}' | models_has qwen3:32b || fail models_has
if printf '{"data":[{"id":"auto"}]}' | models_has qwen3:32b; then fail 'models_has matched a missing id'; fi
chat_probe_body auto | python3 -c 'import json,sys; b=json.load(sys.stdin); assert b["tools"] and b["model"]=="auto"' ||
  fail 'the chat probe must offer a tool'
[[ $(printf '{"error":{"message":"m does not support tools"}}' | error_message) == 'm does not support tools' ]] ||
  fail error_message
pass 'settings, model listing, the tool probe body and error parsing'

unit=$here/openclaw-gateway.service
grep -qx 'ExecStart=/home/openclaw/.local/bin/openclaw gateway run' "$unit" || fail 'unit ExecStart'
grep -qx 'User=openclaw' "$unit" || fail 'unit runs as openclaw'
grep -qx 'ProtectHome=read-only' "$unit" && grep -qx 'ReadWritePaths=/home/openclaw' "$unit" || fail 'unit home access'
grep -qx 'RestartPreventExitStatus=78' "$unit" || fail 'an invalid config (exit 78) must not restart-loop'
grep -qx 'EnvironmentFile=/home/openclaw/.openclaw/.env' "$unit" || fail 'unit does not load the Gateway token'
grep -q '^MemoryDenyWriteExecute' "$unit" && fail "Node's JIT needs writable executable memory"
grep -qi 'token=' <(grep -v '^#' "$unit") && fail 'the Gateway token must not be in the unit'
direct=$here/openclaw-direct.service
grep -qx 'User=openclaw-direct' "$direct" || fail 'the dispatcher runs as the agent account'
grep -qx 'ExecStart=/usr/bin/python3 /usr/local/lib/openclaw-direct.py' "$direct" || fail 'dispatcher ExecStart'
grep -qx 'Environment=DIRECT_ETC=/etc/openclaw-target' "$direct" &&
  grep -qx 'Environment=DIRECT_SECRETS_FILE=/etc/openclaw-target/router.env' "$direct" &&
  grep -qx 'Environment=DIRECT_CONTEXT_SETTING=OPENCLAW_CONTEXT_LENGTH' "$direct" || fail 'dispatcher files'
pass "the units run hardened, the dispatcher apart from the agent, and carry no secret"

# Exercise the exact npm command from the generated runtime script without
# needing root or downloading Node.
runtime_install=$(awk '
  $0 == "if [[ $NEED_OPENCLAW == 1 ]]; then" { inside=1 }
  inside && $0 == "RUNTIME" { exit }
  inside { print }
' "$script")
[[ $runtime_install == *'npm install "${npm_args[@]}"'* ]] || fail 'could not extract the runtime npm install'
npm() {
  if [[ $1 == --version ]]; then printf '%s\n' "$test_npm_version"
  else printf 'npm %s\n' "$*"; fi
}
# shellcheck disable=SC2034  # read by the eval'd runtime snippet
NEED_OPENCLAW=1 OPENCLAW_SPEC=latest
for test_npm_version in 11.15.0 11.16.0 12.0.0; do
  out=$(eval "$runtime_install") || fail "npm $test_npm_version command failed: $out"
  case $test_npm_version in
    11.15.0) [[ $out == 'npm install -g --no-fund --no-audit openclaw@latest' ]] ;;
    *) [[ $out == 'npm install -g --no-fund --no-audit --allow-scripts=openclaw openclaw@latest' ]] ;;
  esac || fail "npm $test_npm_version selected the wrong flags: $out"
done
unset -f npm
pass 'npm 11.16 and 12 allow OpenClaw lifecycle scripts; npm 11.15 keeps the compatible command'

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
# Only the fake Node's npm (put on PATH by the fake `nvm use`) may run.
for command_name in npm node npx; do stub "$command_name" 'echo "the system $0 must not be run here" >&2; exit 99'; done
stub useradd 'name=${*: -1}; touch "$FAKE_STATE/user-$name"; [[ $* == *--system* ]] || mkdir -p "$OC_USER_HOME"'
stub id 'name=${*: -1}; [[ -e $FAKE_STATE/user-$name ]]'
stub getent '[[ $1 == passwd && -e $FAKE_STATE/user-openclaw ]] && printf "openclaw:x:1000:1000::%s:/bin/bash\n" "$OC_USER_HOME"'
# runuser -u USER -- CMD...: run CMD as the caller (no openclaw account here).
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
# install: drop -o/-g (the accounts do not exist here).
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub ip 'printf "2: eth0    inet 192.0.2.83/24 brd 192.0.2.255 scope global eth0\n"'
stub systemctl 'unit=${*: -1}; file=$FAKE_STATE/active
[[ $unit != openclaw-direct.service ]] || file=$FAKE_STATE/direct-active
case $1 in
  is-active) [[ -e $file ]]; exit ;;
  restart) touch "$file" ;;
  disable) [[ $2 != --now ]] || rm -f "$file" ;;
esac; exit 0'
# The nvm installer: writes an nvm.sh whose nvm installs a fake Node, whose
# npm installs a fake openclaw. OpenClaw keeps its config as key=value lines.
cat > "$tmp_root/nvm-install.sh" <<'NVMINSTALL'
#!/usr/bin/env bash
echo "nvm-install PROFILE=$PROFILE NVM_DIR=$NVM_DIR" >> "$FAKE_LOG"
mkdir -p "$NVM_DIR"
cat > "$NVM_DIR/nvm.sh" <<'NVMSH'
nvm() {
  echo "nvm $*" >> "$FAKE_LOG"
  local version=${FAKE_NODE_VERSION:-24.22.1} dir
  dir=$NVM_DIR/versions/node/v$version/bin
  case $1 in
    install)
      mkdir -p "$dir"
      printf '#!/usr/bin/env bash\necho v%s\n' "$version" > "$dir/node"
      cat > "$dir/npm" <<'NPM'
#!/usr/bin/env bash
echo "npm $*" >> "$FAKE_LOG"
if [[ $1 == --version ]]; then echo "${FAKE_NPM_VERSION:-11.15.0}"; exit 0; fi
spec=${*: -1}; spec=${spec#openclaw@}
version=${FAKE_OC_VERSION:-}
[[ -n $version ]] || { [[ $spec =~ ^[0-9] ]] && version=$spec || version=2026.10.9; }
here=$(dirname -- "$0")
sed "s/@VERSION@/$version/" "$FAKE_OPENCLAW" > "$here/openclaw"
chmod +x "$here/openclaw"
NPM
      chmod +x "$dir/node" "$dir/npm" ;;
    alias) printf '%s\n' "$version" > "$NVM_DIR/alias-default" ;;
    use) [[ -e $NVM_DIR/alias-default ]] || return 3
      PATH=$NVM_DIR/versions/node/v$(cat "$NVM_DIR/alias-default")/bin:$PATH ;;
    which) [[ -e $NVM_DIR/alias-default ]] && echo "$NVM_DIR/versions/node/v$(cat "$NVM_DIR/alias-default")/bin/node" ;;
  esac
}
NVMSH
NVMINSTALL
cat > "$tmp_root/openclaw" <<'OPENCLAW'
#!/usr/bin/env bash
echo "openclaw $*" >> "$FAKE_LOG"
cfg=$HOME/.openclaw/openclaw.json
case $1 in
  --version) echo 'OpenClaw @VERSION@ (test)' ;;
  setup) [[ $2 == --baseline ]] || exit 2; mkdir -p "$HOME/.openclaw/workspace"; touch "$cfg" ;;
  config)
    case $2 in
      validate) exit "${FAKE_VALIDATE_RC:-0}" ;;
      unset)
        grep -q -e "^$3=" -e "^$3\." "$cfg" || exit 1
        grep -v -e "^$3=" -e "^$3\." "$cfg" > "$cfg.new" || true; mv "$cfg.new" "$cfg" ;;
      set)
        path=$3 value=$4
        [[ ${FAKE_CONFIG_FAIL:-} != "$path" ]] || exit 1
        # openclaw-honcho 1.7.0's schema has no peerName (additionalProperties: false).
        if [[ $path == plugins.entries.openclaw-honcho.config.peerName ]]; then
          echo 'Config validation failed: plugins.entries.openclaw-honcho.config: invalid config: must not have additional properties: "peerName"' >&2
          exit 1
        fi
        if [[ $value == --ref-provider ]]; then value="ref:$7:$9"; fi
        if [[ $path == agents.defaults.model.primary ]] && grep -q '^agents.defaults.model="' "$cfg"; then exit 1; fi
        grep -v "^$path=" "$cfg" > "$cfg.new" 2>/dev/null || true
        printf '%s=%s\n' "$path" "$value" >> "$cfg.new"
        mv "$cfg.new" "$cfg" ;;
      *) exit 2 ;;
    esac ;;
  plugins)
    marker=$HOME/.openclaw/plugin-$3
    case $2 in
      inspect) [[ -e $marker ]] ;;
      install) [[ $3 == @honcho-ai/openclaw-honcho ]] || exit 2; touch "$HOME/.openclaw/plugin-openclaw-honcho" ;;
      enable|disable)
        [[ -e $marker ]] || exit 1
        grep -v "^plugins.entries.$3.enabled=" "$cfg" > "$cfg.new" 2>/dev/null || true
        printf 'plugins.entries.%s.enabled=%s\n' "$3" "$([[ $2 == enable ]] && echo true || echo false)" >> "$cfg.new"
        mv "$cfg.new" "$cfg" ;;
      *) exit 2 ;;
    esac ;;
  *) exit 2 ;;
esac
OPENCLAW
# curl: the nvm download, the router, the local dispatcher and the Gateway.
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
home = os.environ["OC_USER_HOME"]
def kv(path, key):
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
terminal = os.environ.get("FAKE_OT_URL", "http://192.0.2.70:8000")
honcho = os.environ.get("FAKE_HONCHO_URL", "http://192.0.2.85:8000")
if url and url.startswith(honcho):
    if os.environ.get("FAKE_HONCHO_DOWN"): refused()
    if url.endswith("/osr/v1/whoami"):
        # OSR's Honcho gateway: this CT's own workspace; another Honcho has no such route.
        if os.environ.get("FAKE_HONCHO_NO_GATEWAY"): reply(404, {"detail": "Not Found"})
        if auth == os.environ.get("FAKE_HONCHO_BAD_KEY", "-"): reply(401, {"detail": "Invalid API key"})
        if os.environ.get("FAKE_HONCHO_PER_USER"):
            reply(200, {"client": "openwebui", "user": None, "workspace": None, "per_user": True})
        reply(200, {"client": "openclaw-283", "user": None, "workspace": "openclaw-283", "per_user": False})
if url and url.startswith(terminal):
    if os.environ.get("FAKE_OT_DOWN"): refused()
    if url.endswith("/osr/v1/whoami"):
        if auth != os.environ.get("FAKE_OT_KEY", "ot-key-0123456789abcdef"):
            reply(401, {"detail": "Invalid API key"})
        reply(200, {"client": "openclaw-283", "user": "default", "workspace": "0123456789abcdef"})
if url == "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh":
    with open(out, "w") as f:
        f.write(open(os.environ["FAKE_NVM_INSTALLER"]).read())
    sys.exit(0)
if url.startswith(router):
    if os.environ.get("FAKE_ROUTER_DOWN"): refused()
    if auth != os.environ.get("FAKE_ROUTER_KEY", ""):
        reply(401, {"error": {"message": "Invalid or missing API key", "code": "invalid_api_key"}})
    if url.endswith("/v1/models"):
        ids = os.environ.get("FAKE_MODELS", "auto,fast,large,qwen3:32b").split(",")
        reply(200, {"object": "list", "data": [{"id": m} for m in ids]})
if url.startswith("http://127.0.0.1:8765"):
    if not os.path.exists(os.path.join(state, "direct-active")): refused()
    path = url[len("http://127.0.0.1:8765"):]
    if path == "/healthz": reply(200, {"status": "ok"})
    if path == "/v1/models":
        ids = os.environ.get("FAKE_DIRECT_MODELS", "auto,fast,qwen3:32b").split(",")
        reply(200, {"object": "list", "data": [{"id": m} for m in ids]})
    if path.startswith("/t/") and path.endswith("/v1/models"):
        name = path.split("/")[2]
        if name in os.environ.get("FAKE_TARGET_DOWN", "").split(","):
            reply(502, {"error": {"message": f"Direct target {name} did not list its models"}})
        reply(200, {"object": "list", "data": [{"id": f"{name}-model", "owned_by": name}]})
    if path == "/v1/chat/completions":
        with open(os.path.join(state, "probe.json"), "w") as f: f.write(data or "")
        status = int(os.environ.get("FAKE_CHAT_STATUS", "200"))
        if status != 200:
            reply(status, {"error": {"message": os.environ.get("FAKE_CHAT_ERROR", "boom")}})
        reply(200, {"choices": [{"message": {"role": "assistant", "content": "ready"}}]})
if url.startswith("http://127.0.0.1:"):
    port = url.split(":")[2].split("/")[0]
    path = url.split(port, 1)[1]
    cfg = os.path.join(home, ".openclaw/openclaw.json")
    if not os.path.exists(os.path.join(state, "active")): refused()
    if port != kv(cfg, "gateway.port") or port == os.environ.get("FAKE_BAD_PORT"): refused()
    if path == "/healthz": reply(200, {"ok": True, "status": "live"})
    if path == "/v1/models":
        if kv(cfg, "gateway.http.endpoints.chatCompletions.enabled") != "true":
            reply(404, {"error": {"message": "Not Found"}})
        token = kv(os.path.join(home, ".openclaw/.env"), "OPENCLAW_GATEWAY_TOKEN")
        if kv(cfg, "gateway.auth.token") != "ref:env:OPENCLAW_GATEWAY_TOKEN" or not auth or auth != token:
            reply(401, {"error": {"message": "unauthorized"}})
        reply(200, {"object": "list", "data": [{"id": "openclaw"}, {"id": "openclaw/default"}, {"id": "openclaw/main"}]})
    if path == "/":
        if kv(cfg, "gateway.controlUi.enabled") != "true": reply(404, "not found")
        reply(200, "<!doctype html><title>OpenClaw Control</title>")
sys.stderr.write(f"fake curl: unexpected {url}\n")
sys.exit(22)
CURL
chmod +x "$bin/curl"
if ! command -v openssl >/dev/null; then
  stub openssl 'python3 -c "import secrets; print(secrets.token_hex(32))"'
fi
nvm_sha=$(sha256sum "$tmp_root/nvm-install.sh" | cut -d' ' -f1)

deploy=$tmp_root/deploy
home=$tmp_root/home/openclaw
etc=$tmp_root/etc/openclaw-target
units=$tmp_root/systemd
reset_tree() {
  rm -rf -- "${deploy:?}" "${tmp_root:?}/home" "${tmp_root:?}/etc" "${units:?}" "${state:?}"/* "${log:?}"
  mkdir -p "$deploy" "$units" "$tmp_root/etc"
  cp "$script" "$here/openclaw-gateway.service" "$here/openclaw-direct.service" "$deploy/"
  cp "$here/../hermes/direct-dispatch.py" "$deploy/"
  : > "$log"
}
router_key=sk-router-0123456789abcdef
push_key() { printf '%s\n' "${1:-$router_key}" > "$deploy/router-api-key"; chmod 0600 "$deploy/router-api-key"; }
# guest [VAR=value ...]: run the deployed installer in the fake tree. The fake
# nvm installer is pinned by its own hash, unless nvm_pin is emptied.
nvm_pin=("NVM_INSTALLER_SHA256=$nvm_sha")
guest() {
  env -u NVM_INSTALLER_SHA256 PATH="$bin:$PATH" OC_USER_HOME="$home" OC_ETC="$etc" UNIT_DIR="$units" \
    DIRECT_LIB="$tmp_root/openclaw-direct.py" \
    LOCK_FILE="$tmp_root/etc/openclaw-target.lock" HEALTH_TIMEOUT=2 \
    FAKE_NVM_INSTALLER="$tmp_root/nvm-install.sh" FAKE_OPENCLAW="$tmp_root/openclaw" FAKE_ROUTER_KEY="$router_key" \
    "${nvm_pin[@]}" ROUTER_URL=http://192.168.11.80:8000 OPENCLAW_API=true "$@" \
    bash "$deploy/install-target.sh" 2>&1
}
kv() { awk -v k="$1" -F= '$1==k {sub(/^[^=]*=/,""); print; exit}' "$2"; }
config=$home/.openclaw/openclaw.json
env_file=$home/.openclaw/.env

# 1. The pinned nvm installer is enforced: a download with another hash is refused.
reset_tree; push_key
nvm_pin=()
out=$(guest) && fail 'an nvm installer with another SHA-256 was run'
nvm_pin=("NVM_INSTALLER_SHA256=$nvm_sha")
[[ $out == *'not NVM_INSTALLER_SHA256. Nothing was installed.'* ]] || fail "nvm checksum message: $out"
grep -q '^nvm-install' "$log" && fail 'the mismatching nvm installer ran'
pass 'by default the nvm v0.40.4 installer must match its known SHA-256, or nothing is installed'

# 2. A fresh install with the API and the Control UI.
reset_tree; push_key
out=$(guest) || fail "fresh install: $out"
grep -q "^nvm-install PROFILE=/dev/null NVM_DIR=$home/.nvm$" "$log" || fail 'nvm was not installed for the openclaw account, profile untouched'
grep -q '^nvm install 24$' "$log" && grep -q '^nvm alias default 24$' "$log" || fail 'Node 24 was not installed as the nvm default'
grep -q '^npm install -g --no-fund --no-audit openclaw@latest$' "$log" || fail 'openclaw was not installed with npm -g'
grep -q '^openclaw setup --baseline$' "$log" || fail 'the first config was not created with setup --baseline'
for tool in node npm openclaw; do
  [[ -L $home/.local/bin/$tool && $(readlink "$home/.local/bin/$tool") == "$home/.nvm/versions/node/v24.22.1/bin/$tool" ]] ||
    fail "$tool is not linked into nvm's default Node"
done
[[ $(kv gateway.mode "$config") == local && $(kv gateway.port "$config") == 18789 && $(kv gateway.bind "$config") == lan ]] ||
  fail "gateway settings: $(cat "$config")"
[[ $(kv gateway.auth.mode "$config") == token && $(kv gateway.auth.token "$config") == ref:env:OPENCLAW_GATEWAY_TOKEN ]] ||
  fail 'the Gateway token must be an env SecretRef'
[[ $(kv gateway.http.endpoints.chatCompletions.enabled "$config") == true && $(kv gateway.controlUi.enabled "$config") == true ]] ||
  fail 'chat completions or Control UI'
[[ $(kv gateway.controlUi.allowedOrigins "$config") == '["http://192.0.2.83:18789"]' ]] || fail 'Control UI origins'
[[ $(kv models.mode "$config") == merge && $(kv agents.defaults.model.primary "$config") == osr/auto ]] || fail 'models.mode or primary model'
python3 - "$(kv models.providers.osr "$config")" <<'PY' || fail "osr provider: $(kv models.providers.osr "$config")"
import json, sys
p = json.loads(sys.argv[1])
assert p["baseUrl"] == "http://127.0.0.1:8765/v1" and p["apiKey"] == "no-key" and p["api"] == "openai-completions"
assert [m["id"] for m in p["models"]] == ["auto", "fast", "qwen3:32b"]
assert all(m["contextWindow"] == 65536 and m["maxTokens"] == 8192 for m in p["models"])
PY
grep -q '^openclaw config set models.providers.osr .* --strict-json --replace$' "$log" || fail 'providers are not replaced as a whole'
grep -q '^openclaw config validate$' "$log" || fail 'the config was not validated'
[[ $(kv OPENCLAW_GATEWAY_TOKEN "$env_file") == "$(< "$etc/api-key")" && $(wc -c < "$etc/api-key") -ge 64 ]] || fail 'Gateway token'
grep '^openclaw ' "$log" | grep -q "$(< "$etc/api-key")" && fail 'the Gateway token was passed to openclaw in argv'
[[ $(kv ROUTER_API_KEY "$etc/router.env") == "$router_key" ]] || fail 'ROUTER_API_KEY not kept for the dispatcher'
[[ $(stat -c %a "$env_file") == 600 && $(stat -c %a "$etc/api-key") == 600 && $(stat -c %a "$etc/router.env") == 640 ]] ||
  fail 'secret file modes'
grep -q 'chown root:openclaw-direct .*/router.env' "$log" || fail 'the router key is not owned by the dispatcher account'
[[ ! -e $deploy/router-api-key ]] || fail 'the pushed router key was not removed'
[[ -f $units/openclaw-gateway.service && -f $units/openclaw-direct.service && -e $state/active && -e $state/direct-active ]] ||
  fail 'gateway or dispatcher not started'
[[ -f $tmp_root/openclaw-direct.py ]] && cmp -s "$tmp_root/openclaw-direct.py" "$here/../hermes/direct-dispatch.py" ||
  fail "the Hermes target's dispatcher was not installed"
grep -q "ROUTER_KEY_SHA256=$(printf '%s' "$router_key" | sha256sum | cut -d' ' -f1)" "$etc/settings" || fail 'settings key hash'
grep -q '^OPENCLAW_CONTEXT_LENGTH=65536$' "$etc/settings" || fail 'the dispatcher context floor is not in the settings'
grep -q '^PROVIDERS_SHA256=pending$' "$etc/settings" && fail 'the final settings record was not written'
grep -q "$router_key" "$etc/settings" && fail 'the settings record holds the router key'
grep '^curl ' "$log" | grep -q "$router_key" && fail 'the router key was passed to curl in argv'
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["tools"]' "$state/probe.json" ||
  fail 'the chat probe did not offer a tool'
[[ $out == *'Pin this version with OPENCLAW_VERSION=2026.10.9'* && $out == *'Control UI: http://192.0.2.83:18789/'* ]] ||
  fail "summary: $out"
pass 'fresh install: nvm, Node 24 and openclaw as the agent account; local provider, Gateway token, router key kept apart'

# 3. Unchanged: nothing to do.
: > "$log"
out=$(guest) || fail "rerun: $out"
[[ $out == *'nothing to do'* ]] || fail "unchanged rerun did work: $out"
grep -qE '^(apt-get|nvm|npm|systemctl restart|openclaw config set)' "$log" && fail 'unchanged rerun touched packages, Node or the units'
pass 'an unchanged, healthy installation is left alone'

# 4. A new model in the pool: the provider follows, nothing is reinstalled.
: > "$log"
out=$(guest FAKE_DIRECT_MODELS=auto,fast,qwen3:32b,gemma4:27b) || fail "new model: $out"
[[ $out != *'nothing to do'* ]] || fail 'a new pool model was not picked up'
[[ $(kv models.providers.osr "$config") == *'"gemma4:27b"'* ]] || fail 'the new model is not in provider osr'
grep -qE '^(nvm|npm)' "$log" && fail 'a model change reinstalled Node or OpenClaw'
pass 'a model added to the pool is added to provider osr on rerun, without reinstalling anything'

# 5. The router key was rotated: a new key file is applied.
old_api_key=$(< "$etc/api-key")
router_key=sk-router-rotated-999999
push_key
out=$(guest FAKE_DIRECT_MODELS=auto,fast,qwen3:32b,gemma4:27b) || fail "rotation: $out"
[[ $(kv ROUTER_API_KEY "$etc/router.env") == "$router_key" ]] || fail 'the rotated key was not applied'
[[ $(< "$etc/api-key") == "$old_api_key" ]] || fail 'the Gateway token changed on a router key rotation'
grep -qE '^(nvm-install|npm)' "$log" && fail 'a key rotation reinstalled OpenClaw'
pass 'a rotated router key is applied on rerun, keeping the Gateway token and the install'

# 6. The router rejects the configured key (rotated on the router, not pushed).
before=$(cat "$config" "$env_file" "$etc/router.env")
out=$(guest FAKE_ROUTER_KEY=sk-router-something-else) && fail 'a rejected key was accepted'
[[ $out == *'rejected the API key'*'--reconfigure'* ]] || fail "rejected key message: $out"
[[ $(cat "$config" "$env_file" "$etc/router.env") == "$before" ]] || fail 'a rejected key changed the configuration'
pass 'a key the router rejects stops the run before anything changes, and says how to fix it'

# 7. No key at all against a router that requires one.
reset_tree
out=$(guest) && fail 'a missing key was accepted'
[[ $out == *'requires its API key'* ]] || fail "missing key message: $out"
grep -q '^apt-get install -y --no-install-recommends ca-certificates curl git' "$log" && fail 'packages installed before the probe'
pass 'a router that needs a key and gets none is reported before anything is installed'

# 8. The direct tool probe fails: configuration is rolled back.
reset_tree; push_key
out=$(guest FAKE_CHAT_STATUS=400 FAKE_CHAT_ERROR='registry.ollama.ai/library/gemma3:12b does not support tools') &&
  fail 'a failed tool probe was accepted'
[[ $out == *'Direct model-server chat probe failed'*'does not support tools'* ]] || fail "probe message: $out"
[[ ! -e $etc/settings && ! -e $state/direct-active ]] || fail "settings or dispatcher kept after a failed probe"
[[ -e $deploy/router-api-key ]] || fail 'the key file must stay for a retry'
rm -f "$state/probe.json"
out=$(guest FAKE_CHAT_STATUS=400 OPENCLAW_SKIP_CHAT_PROBE=true) || fail "skip probe: $out"
[[ ! -e $state/probe.json ]] || fail 'OPENCLAW_SKIP_CHAT_PROBE still sent a chat request'
pass 'a failed direct tool-call probe rolls back the settings; it can be skipped explicitly'

# 9. Unknown model, unreachable router, a model the dispatcher cannot use.
reset_tree; push_key
out=$(guest OPENCLAW_MODEL=nope:1b) && fail 'an unadvertised model was accepted'
[[ $out == *"does not advertise model 'nope:1b'"* ]] || fail "model message: $out"
out=$(guest FAKE_ROUTER_DOWN=1) && fail 'an unreachable router was accepted'
[[ $out == *'unreachable'* ]] || fail "unreachable message: $out"
out=$(guest OPENCLAW_MODEL=large) && fail 'a model without tools or context was accepted'
[[ $out == *"does not offer OPENCLAW_MODEL 'large'"* ]] || fail "unusable model message: $out"
pass 'an unadvertised model, an unreachable router or a model the dispatcher refuses is reported'

# 10. A Gateway that does not come up after a change: the previous one is back.
reset_tree; push_key
guest >/dev/null || fail 'setup for the gateway rollback'
prev_config=$(< "$config"); prev_settings=$(< "$etc/settings")
out=$(guest OPENCLAW_PORT=18800 FAKE_BAD_PORT=18800) && fail 'an unhealthy gateway was accepted'
[[ $out == *'did not become healthy on port 18800'*'running again'* ]] || fail "gateway rollback message: $out"
[[ $(< "$config") == "$prev_config" && $(< "$etc/settings") == "$prev_settings" ]] || fail 'rollback did not restore the config and settings'
[[ -e $state/active ]] || fail 'the previous gateway is not running'
pass 'a Gateway that fails its health check after a change is rolled back and running again'

# 11. The previous Gateway fails too: every Gateway call is refused.
mv "$bin/curl" "$bin/curl.real"
cat > "$bin/curl" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ \$a == http://127.0.0.1:18* ]]; then
    [[ " \$* " == *" -w "* ]] && printf 000
    exit 7
  fi
done
exec "$bin/curl.real" "\$@"
WRAP
chmod +x "$bin/curl"
out=$(guest OPENCLAW_PORT=18800) && fail 'a double failure was accepted'
mv -f "$bin/curl.real" "$bin/curl"
[[ $out == *'did not become healthy either'* ]] || fail "double failure message: $out"
pass 'a rollback whose previous Gateway does not come back either is reported as failed too'

# 12. A configuration command fails: the files are restored by the ERR trap.
reset_tree; push_key
guest >/dev/null || fail 'setup for the config failure'
prev_config=$(< "$config"); prev_env=$(< "$env_file")
out=$(guest OPENCLAW_CONTEXT_LENGTH=131072 FAKE_CONFIG_FAIL=models.mode) && fail "a failed config set was accepted: $out"
[[ $out == *'running again'* ]] || fail "config rollback message: $out"
[[ $(< "$env_file") == "$prev_env" && $(< "$config") == "$prev_config" ]] || fail 'config or .env not restored'
grep -q '^OPENCLAW_CONTEXT_LENGTH=65536$' "$etc/settings" || fail 'settings not restored'
out=$(guest FAKE_VALIDATE_RC=1 OPENCLAW_MAX_TOKENS=4096) && fail 'an invalid config was accepted'
[[ $(< "$config") == "$prev_config" ]] || fail 'an invalid config was kept'
pass 'a failing or invalid configuration restores openclaw.json, .env, the settings and the units'

# 13. API and Control UI switched off.
out=$(guest OPENCLAW_API=false) || fail "API off: $out"
[[ $(kv gateway.http.endpoints.chatCompletions.enabled "$config") == false && $(kv gateway.bind "$config") == lan ]] ||
  fail 'API off with the Control UI on'
out=$(guest OPENCLAW_API=false OPENCLAW_DASHBOARD=false) || fail "both off: $out"
[[ $(kv gateway.bind "$config") == loopback && $(kv gateway.controlUi.enabled "$config") == false ]] ||
  fail 'with neither, the Gateway must be loopback-only with its Control UI off'
[[ -e $state/active ]] || fail 'the Gateway stopped (OpenClaw needs it for its CLI and channels)'
pass 'OPENCLAW_API=false closes /v1/chat/completions; without the Control UI either the Gateway binds loopback'

# 14. Version pins: an exact OpenClaw version is installed, kept and enforced.
reset_tree; push_key
out=$(guest OPENCLAW_VERSION=2026.9.36) || fail "pinned install: $out"
grep -q '^npm install -g --no-fund --no-audit openclaw@2026.9.36$' "$log" || fail 'the pin was not installed'
: > "$log"
out=$(guest OPENCLAW_VERSION=2026.9.36) || fail "pinned rerun: $out"
[[ $out == *'nothing to do'* ]] || fail 'an unchanged pinned install did work'
out=$(guest OPENCLAW_VERSION=2026.10.9) || fail "re-pin: $out"
grep -q '^npm install -g --no-fund --no-audit openclaw@2026.10.9$' "$log" || fail 'a changed pin did not reinstall'
grep -qE '^(nvm-install|nvm install)' "$log" && fail 'a new OpenClaw pin reinstalled nvm or Node'
out=$(guest OPENCLAW_VERSION=2026.10.10 FAKE_OC_VERSION=2026.10.9) && fail 'an unapplied pin was accepted'
[[ $out == *'not OPENCLAW_VERSION 2026.10.10'* ]] || fail "pin mismatch message: $out"
pass 'an exact OPENCLAW_VERSION is installed, left alone when unchanged, reinstalled when changed, and enforced'

# 15. Node: an nvm Node below the target floor is refused; a new line reinstalls OpenClaw.
reset_tree; push_key
out=$(guest FAKE_NODE_VERSION=24.20.0) && fail 'an unsupported Node was accepted'
[[ $out == *"Node 24.20.0 is below this target's security floor"* ]] || fail "old Node message: $out"
reset_tree; push_key
guest >/dev/null || fail 'setup for the Node change'
: > "$log"
out=$(guest OPENCLAW_NODE_VERSION=26 FAKE_NODE_VERSION=26.12.1) || fail "Node 26: $out"
grep -q '^nvm install 26$' "$log" && grep -q '^npm install -g' "$log" || fail 'Node 26 did not get its own OpenClaw'
grep -q '^nvm-install' "$log" && fail 'nvm was reinstalled'
[[ $(readlink "$home/.local/bin/openclaw") == "$home/.nvm/versions/node/v26.12.1/bin/openclaw" ]] || fail 'links do not follow the new Node'
pass "a Node below the target's security floor is refused; switching the Node line reinstalls OpenClaw for it"

# 16. Direct targets: one provider each; a removed one is unset; one that is down keeps its models.
reset_tree; push_key
printf 'strata-192-168-11-154-8080=strata+http://192.168.11.154:8080\nollama-192-168-11-153-11434=http://192.168.11.153:11434\n' > "$deploy/targets"
out=$(guest) || fail "install with targets: $out"
for name in strata-192-168-11-154-8080 ollama-192-168-11-153-11434; do
  [[ $(kv "models.providers.$name" "$config") == *"\"baseUrl\":\"http://127.0.0.1:8765/t/$name/v1\""*"\"id\":\"$name-model\""* ]] ||
    fail "direct provider $name: $(kv "models.providers.$name" "$config")"
done
cmp -s "$deploy/targets" "$etc/targets" || fail 'the targets file was not installed for the dispatcher'
: > "$log"
out=$(guest FAKE_TARGET_DOWN=strata-192-168-11-154-8080) || fail "a target down: $out"
[[ $out == *'Could not list the models of strata-192-168-11-154-8080'* ]] || fail 'a target that is down is not reported'
[[ $(kv models.providers.strata-192-168-11-154-8080 "$config") == *'strata-192-168-11-154-8080-model'* ]] || fail 'a target that is down lost its provider'
printf 'strata-192-168-11-154-8080=strata+http://192.168.11.154:8080\n' > "$deploy/targets"
out=$(guest) || fail "rerun with a target removed: $out"
grep -q '^openclaw config unset models.providers.ollama-192-168-11-153-11434$' "$log" || fail 'the stale provider was not unset'
grep -q '^models.providers.ollama-192-168-11-153-11434=' "$config" && fail "the stale provider is still configured"
printf 'Bad Name=http://x:1\n' > "$deploy/targets"
out=$(guest) && fail "an invalid targets file was accepted: $out"
[[ $out == *'invalid line'* ]] || fail "invalid targets message: $out"
printf 'osr=http://x:1\n' > "$deploy/targets"
out=$(guest) && fail 'a target named osr was accepted'
rm -f "$deploy/targets"
pass 'direct targets: a provider per model server, kept through an outage, removed with the server'

# 16b. A Kindi target: it and osr get a deadline for a silent read and a full reply.
reset_tree; push_key
printf 'kindi-192-168-11-14-8093=kindi+http://192.168.11.14:8093\n' > "$deploy/targets"
out=$(guest KINDI_READ_TIMEOUT_SECONDS=5400 OPENCLAW_MAX_TOKENS=4096) || fail "install with a Kindi target: $out"
want=$((5400 * 2 + 4096))
for name in osr kindi-192-168-11-14-8093; do
  [[ $(kv "models.providers.$name" "$config") == *"\"timeoutSeconds\":$want"* ]] ||
    fail "Kindi deadline on $name: $(kv "models.providers.$name" "$config")"
done
grep -qx 'KINDI_READ_TIMEOUT_SECONDS=5400' "$etc/settings" || fail 'the dispatcher budget is not in the settings record'
out=$(guest KINDI_READ_TIMEOUT_SECONDS=0) && fail "an invalid Kindi budget was accepted: $out"
[[ $out == *'Invalid KINDI_READ_TIMEOUT_SECONDS'* ]] || fail "invalid budget message: $out"
rm -f "$deploy/targets"
pass 'a Kindi target: it and osr allow a silent read of twice the budget plus a reply at one token a second'

# 17. An agents.defaults.model set as a string becomes the object form.
reset_tree; push_key
guest >/dev/null || fail 'setup for the model string'
sed -i '/^agents.defaults.model/d' "$config"
printf 'agents.defaults.model="other/model"\n' >> "$config"
out=$(guest OPENCLAW_MODEL=fast) || fail "string model: $out"
[[ $(kv agents.defaults.model "$config") == '{"primary":"osr/fast"}' ]] || fail "string model not replaced: $(cat "$config")"
pass 'a string default model is replaced by the object form with the osr primary'

# 18. One run at a time.
exec {held}>>"$tmp_root/etc/openclaw-target.lock"
flock "$held"
out=$(guest) && fail 'a second concurrent run was accepted'
[[ $out == *'Another install-target.sh run holds'* ]] || fail "lock message: $out"
exec {held}>&-
pass 'a second concurrent run is refused'

# 19. npm 11.16+ and 12 need explicit approval for OpenClaw's lifecycle scripts.
for npm_version in 11.16.0 12.0.0; do
  reset_tree; push_key
  out=$(guest "FAKE_NPM_VERSION=$npm_version") || fail "npm $npm_version install: $out"
  grep -q '^npm install -g --no-fund --no-audit --allow-scripts=openclaw openclaw@latest$' "$log" ||
    fail "npm $npm_version did not allow OpenClaw's install scripts"
done
pass 'npm 11.16 and 12 allow OpenClaw lifecycle scripts; older npm keeps the compatible command'

# Honcho memory: set up once, kept by a failed run, turned off again.
reset_tree; push_key
printf 'honcho-key-A\n' > "$deploy/honcho-api-key"
out=$(guest HONCHO_URL=http://192.0.2.85:8000/) || fail "Honcho on: $out"
[[ $(grep -c '^openclaw plugins install @honcho-ai/openclaw-honcho$' "$log") == 1 ]] || fail 'the plugin was not installed once'
[[ $(kv plugins.entries.openclaw-honcho.enabled "$config") == true ]] || fail 'the plugin is not enabled'
[[ $(kv plugins.entries.openclaw-honcho.hooks.allowConversationAccess "$config") == true ]] || fail 'no conversation access'
[[ $(kv plugins.entries.openclaw-honcho.config.baseUrl "$config") == http://192.0.2.85:8000 ]] || fail 'baseUrl (trailing slash kept?)'
[[ $(kv plugins.entries.openclaw-honcho.config.workspaceId "$config") == openclaw-283 ]] || fail 'workspace'
[[ -z $(kv plugins.entries.openclaw-honcho.config.peerName "$config") ]] || fail 'peerName is not in the plugin schema'
[[ $(kv HONCHO_API_KEY "$home/.openclaw/.env") == honcho-key-A ]] || fail 'the plugin gets no HONCHO_API_KEY in the gateway environment'
grep -q honcho-key-A "$config" && fail 'openclaw.json holds the Honcho key'
honcho_cfg=$home/.honcho/config.json
grep -q '"apiKey": "honcho-key-A"' "$honcho_cfg" || fail "Honcho key file: $(cat "$honcho_cfg")"
[[ $(stat -c %a "$honcho_cfg") == 600 ]] || fail 'the Honcho key file is not private'
: > "$log"
out=$(guest HONCHO_URL=http://192.0.2.85:8000 OPENCLAW_DASHBOARD=false) || fail "Honcho rerun: $out"
grep -q '^openclaw plugins install' "$log" && fail 'an installed plugin was installed again'
printf 'honcho-key-B\n' > "$deploy/honcho-api-key"
out=$(guest HONCHO_URL=http://192.0.2.85:8000 FAKE_CHAT_STATUS=400) && fail 'a failed probe was accepted'
grep -q honcho-key-A "$honcho_cfg" || fail 'a failed run did not put the previous Honcho key file back'
out=$(guest HONCHO_URL=) || fail "Honcho off: $out"
[[ $(kv plugins.entries.openclaw-honcho.enabled "$config") == false ]] || fail 'HONCHO_URL= did not disable the plugin'
[[ ! -e $honcho_cfg && ! -e $deploy/honcho-api-key ]] || fail 'HONCHO_URL= left the Honcho key behind'
[[ -z $(kv HONCHO_API_KEY "$home/.openclaw/.env") ]] || fail 'HONCHO_URL= left HONCHO_API_KEY in the .env'
external_honcho_key=$tmp_root/external-honcho-key
printf 'external-honcho-key\n' > "$external_honcho_key"
out=$(guest HONCHO_URL=http://192.0.2.85:8000 HONCHO_API_KEY_FILE="$external_honcho_key" FAKE_HONCHO_NO_GATEWAY=1) || fail "external Honcho on: $out"
[[ $(kv plugins.entries.openclaw-honcho.config.workspaceId "$config") == osr ]] || fail 'a Honcho without OSR'"'"'s gateway did not get the osr workspace'
out=$(guest HONCHO_URL=http://192.0.2.85:8000 HONCHO_API_KEY_FILE="$external_honcho_key" FAKE_HONCHO_BAD_KEY=external-honcho-key) && fail 'a rejected Honcho key was accepted'
[[ $out == *"rejected this CT's key"* ]] || fail "no rejected-key error: $out"
out=$(guest HONCHO_URL= HONCHO_API_KEY_FILE="$external_honcho_key") || fail "external Honcho off: $out"
[[ $(<"$external_honcho_key") == external-honcho-key ]] || fail 'disabling Honcho deleted a caller-supplied key file'
pass 'Honcho: the plugin installed once, enabled with the workspace the gateway names; a failed run restores it; HONCHO_URL= disables it'

# Open Terminal: OpenClaw's own workspace as MCP server open-terminal.
ot_key=ot-key-0123456789abcdef
printf '%s\n' "$ot_key" > "$deploy/open-terminal-key"
out=$(guest OPEN_TERMINAL_URL=http://192.0.2.70:8000/) || fail "Open Terminal on: $out"
entry=$(kv mcp.servers.open-terminal "$config")
python3 - "$entry" <<'PY' || fail "MCP entry: $entry"
import json, sys
e = json.loads(sys.argv[1])
assert e["url"] == "http://192.0.2.70:8000/mcp" and e["transport"] == "streamable-http"
assert e["headers"] == {"Authorization": "Bearer ${OSR_OPEN_TERMINAL_KEY}"}
PY
grep -q "$ot_key" "$config" && fail 'openclaw.json holds the Open Terminal key'
[[ $(kv OSR_OPEN_TERMINAL_KEY "$env_file") == "$ot_key" ]] || fail 'the key is not in OpenClaw .env'
[[ $(kv OPEN_TERMINAL_URL "$etc/settings") == http://192.0.2.70:8000 ]] || fail 'settings do not record OPEN_TERMINAL_URL'
grep -q -- "$ot_key" "$log" && fail 'the Open Terminal key appeared in a command line'
out=$(guest OPEN_TERMINAL_URL=http://192.0.2.70:8000 FAKE_OT_KEY=another-key-0123456789) && fail 'a rejected key was accepted'
[[ $out == *'rejected this CT'* ]] || fail "rejected key message: $out"
out=$(guest OPEN_TERMINAL_URL=http://192.0.2.70:8000 FAKE_OT_DOWN=1) && fail 'an unreachable terminal was accepted'
[[ $out == *'unreachable from this CT'* ]] || fail "unreachable message: $out"
out=$(guest OPEN_TERMINAL_URL=) || fail "Open Terminal off: $out"
grep -q '^mcp.servers.open-terminal' "$config" && fail 'OPEN_TERMINAL_URL= left the MCP server'
grep -q '^OSR_OPEN_TERMINAL_KEY=' "$env_file" && fail 'OPEN_TERMINAL_URL= left the key in .env'
[[ ! -e $deploy/open-terminal-key ]] || fail 'OPEN_TERMINAL_URL= left the pushed key'
: > "$log"
out=$(guest) || fail "rerun without Open Terminal: $out"
grep -q 'mcp.servers.open-terminal' "$log" && fail 'a run that never had Open Terminal touched the MCP config'
pass 'Open Terminal: MCP server with the key only in .env, checked from the CT; OPEN_TERMINAL_URL= removes it'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
