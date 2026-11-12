#!/usr/bin/env bash
# Exercise install-target.sh: its helpers and dry runs, then whole runs against
# a temporary tree with stubbed apt, runuser and systemctl, a fake npm
# registry (manifests and platform tarballs holding a fake opencode binary),
# and a fake router, dispatcher, Honcho, Open Terminal, OpenCode server and
# chat endpoint (curl). Nothing is downloaded, installed or started. End-to-end cases need
# root (like the other targets' install tests).
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/install-target.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/opencode-test.XXXXXX")
cleanup() {
  [[ $tmp_root == "${TMPDIR:-/tmp}"/opencode-test.* ]] || return
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

# --- syntax, dry runs and validation --------------------------------------------
bash -n "$script" || fail 'shell syntax'
deploy_dry=$tmp_root/dry; mkdir -p "$deploy_dry"
cp "$script" "$here/opencode.service" "$here/opencode-direct.service" "$here/opencode-api.service" \
  "$here/openai-proxy.py" "$deploy_dry/"
cp "$here/../hermes/direct-dispatch.py" "$deploy_dry/"
dry() { env "$@" bash "$deploy_dry/install-target.sh" --dry-run; }
out=$(dry ROUTER_URL=http://192.168.11.80:8000) || fail 'dry run'
[[ $out == *'resolve @opencode/cli@2.2.7 on https://registry.npmjs.org'*'check its sha512 integrity'* ]] ||
  fail "dry run omitted the pinned release or its integrity check: $out"
[[ $out == *'@opencode/ai/providers/openai-compatible, baseURL http://127.0.0.1:8765/v1, apiKey <local placeholder>'* &&
   $out == *'model osr/auto'* ]] || fail 'dry run omitted the osr provider'
[[ $out == *'with the router API key'* && $out == *'offering a tool'* ]] || fail 'dry run omitted the router check or chat probe'
[[ $out == *'server on 0.0.0.0:4096, Basic auth as opencode'* && $out == *'web UI on http://'* ]] || fail "dry run web UI: $out"
[[ $out == *'hide OpenCode'\''s free cloud models'* ]] || fail 'free models are hidden by default'
[[ $out != *node* && $out != *nvm* ]] || fail 'the plan installs Node (OpenCode 2 is one native binary)'
out=$(dry ROUTER_URL=http://r:8000 OPENCODE_WEB=false OPENCODE_VERSION=latest OPENCODE_FREE_MODELS=true \
  HONCHO_URL=http://192.0.2.85:8000 OPEN_TERMINAL_URL=http://192.0.2.70:8000) || fail 'dry run with integrations'
[[ $out == *'server on 127.0.0.1:4096'* && $out == *'web UI on loopback only'* ]] || fail "loopback plan: $out"
[[ $out == *'@opencode/cli@latest'* && $out != *'free cloud models'* ]] || fail 'latest or free models plan'
[[ $out == *'plugin @honcho-ai/opencode-honcho@0.2.1'* && $out == *'MCP server open-terminal at http://192.0.2.70:8000/mcp'* ]] ||
  fail "integration plan: $out"
[[ $out == *'no OpenAI-compatible endpoint'* ]] || fail 'the chat endpoint is off by default in a guest run'
out=$(dry ROUTER_URL=http://r:8000 OPENCODE_API=true OPENCODE_API_PORT=4200 OPENCODE_API_PERMISSIONS=reject) || fail 'dry run with the chat endpoint'
[[ $out == *'create unprivileged user opencode-api'* && $out == *'OpenAI-compatible endpoint http://<CT IPv4>:4200/v1, model opencode, permissions: reject'* &&
   $out == *'/healthz and /v1/models (with the key) on port 4200'* ]] || fail "chat endpoint plan: $out"
pass 'dry runs plan the pinned release from the npm registry (sha512), the osr provider, the server, Honcho, Open Terminal and the chat endpoint; no Node'

refused() { if dry "$@" >/dev/null 2>&1; then fail "accepted: $*"; fi; }
refused ROUTER_URL=http://bad-host:8000/v1
msg=$(env -u ROUTER_URL bash "$deploy_dry/install-target.sh" --dry-run 2>&1 || true)
[[ $msg == *'ROUTER_URL is unset'* && $msg == *'provision-lxc.sh --reconfigure'* ]] || fail "missing router URL gives no recovery path: $msg"
refused ROUTER_URL=http://router:8000 OPENCODE_MODEL='bad model'
refused ROUTER_URL=http://router:8000 OPENCODE_CONTEXT_LENGTH=16384
refused ROUTER_URL=http://router:8000 OPENCODE_MAX_TOKENS=64
refused ROUTER_URL=http://router:8000 OPENCODE_CONTEXT_LENGTH=32768 OPENCODE_MAX_TOKENS=20000
refused ROUTER_URL=http://router:8000 OPENCODE_VERSION='latest; rm'
refused ROUTER_URL=http://router:8000 OPENCODE_VERSION=beta
refused ROUTER_URL=http://router:8000 OPENCODE_VERSION=1.18.23
refused ROUTER_URL=http://router:8000 HONCHO_PLUGIN_VERSION=latest
refused ROUTER_URL=http://router:8000 OPENCODE_WEB=yes
refused ROUTER_URL=http://router:8000 OPENCODE_FREE_MODELS=1
refused ROUTER_URL=http://router:8000 OPENCODE_PORT=8765
refused ROUTER_URL=http://router:8000 OPENCODE_PORT=70000
refused ROUTER_URL=http://router:8000 HONCHO_URL=http://honcho/
refused ROUTER_URL=http://router:8000 OPENCODE_API=yes
refused ROUTER_URL=http://router:8000 OPENCODE_API=true OPENCODE_API_PORT=4096
refused ROUTER_URL=http://router:8000 OPENCODE_API=true OPENCODE_API_PORT=8765
refused ROUTER_URL=http://router:8000 OPENCODE_API=true OPENCODE_API_PORT=99999
refused ROUTER_URL=http://router:8000 OPENCODE_API=true OPENCODE_API_PERMISSIONS=ask
msg=$(ROUTER_URL=http://router:8000 OPENCODE_CONTEXT_LENGTH=8192 bash "$deploy_dry/install-target.sh" --dry-run 2>&1 || true)
[[ $msg == *'at least 32768'* ]] || fail "context refusal does not explain the minimum: $msg"
msg=$(ROUTER_URL=http://router:8000 OPENCODE_VERSION=1.18.23 bash "$deploy_dry/install-target.sh" --dry-run 2>&1 || true)
[[ $msg == *'OpenCode 2 or newer'* ]] || fail "OpenCode 1 refusal: $msg"
rm "$deploy_dry/openai-proxy.py"
msg=$(dry ROUTER_URL=http://router:8000 2>&1 || true)
[[ $msg == *'Missing the OpenCode units, direct dispatcher or chat endpoint'* ]] || fail "missing chat endpoint: $msg"
cp "$here/openai-proxy.py" "$deploy_dry/"
rm "$deploy_dry/direct-dispatch.py"
msg=$(dry ROUTER_URL=http://router:8000 2>&1 || true)
[[ $msg == *'Missing the OpenCode units, direct dispatcher or chat endpoint'* ]] || fail "missing dispatcher: $msg"
pass 'invalid endpoint, model, context, output budget, releases (and OpenCode 1), ports, chat endpoint settings and missing files are refused'

# --- helpers in isolation ----------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Install helpers/{c=1;next} /^# End install helpers\./{c=0} c' "$script")
for helper in settings_record env_file_update env_file_get models_has chat_probe_body error_message version_of \
              exact_version platform_candidates pick_platform manifest_field integrity_ok providers_json provider_ids \
              opencode_config honcho_config default_model_is kindi_target_names; do
  declare -F "$helper" >/dev/null || fail "helper extraction failed: $helper"
done
envf=$tmp_root/helper.env
printf '# keep me\nOTHER=1\nOPENCODE_PASSWORD=1\nOPENCODE_PASSWORD=2\n' > "$envf"
ENV_SET_OPENCODE_PASSWORD=abc ENV_SET_NEW='a=b c' ENV_UNSET_OTHER=1 env_file_update "$envf"
[[ $(< "$envf") == $'# keep me\nOPENCODE_PASSWORD=abc\nNEW=a=b c' ]] || fail "env_file_update: $(< "$envf")"
[[ $(env_file_get "$envf" OPENCODE_PASSWORD) == abc && -z $(env_file_get "$envf" NONE) ]] || fail env_file_get
pass 'the environment-file editor sets, removes and keeps lines'

[[ $(printf '2.2.7\n' | version_of) == 2.2.7 && $(printf 'opencode 2.3.0-beta.1 (linux)\n' | version_of) == 2.3.0-beta.1 ]] ||
  fail version_of
exact_version 2.2.7 && exact_version 2.3.0-beta.1 || fail exact_version
if exact_version latest || exact_version 2.2; then fail 'exact_version accepted a tag or a short version'; fi
printf 'flags\t: fpu sse4_2 avx avx2 bmi2\n' > "$tmp_root/cpu-avx2"
printf 'flags\t: fpu sse4_2 avx\n' > "$tmp_root/cpu-old"
[[ $(platform_candidates x86_64 "$tmp_root/cpu-avx2" | paste -sd' ') == '@opencode/cli-linux-x64 @opencode/cli-linux-x64-baseline' ]] ||
  fail 'AVX2 x64 prefers the regular build'
[[ $(platform_candidates x86_64 "$tmp_root/cpu-old" | head -n1) == @opencode/cli-linux-x64-baseline ]] ||
  fail 'x64 without AVX2 prefers the baseline build'
[[ $(platform_candidates aarch64 /dev/null) == @opencode/cli-linux-arm64 ]] || fail 'arm64 build'
if platform_candidates riscv64 /dev/null >/dev/null; then fail 'an unknown machine got a build'; fi
cat > "$tmp_root/cli.json" <<'JSON'
{"name":"@opencode/cli","version":"2.2.7","optionalDependencies":{"@opencode/cli-linux-x64":"2.2.6",
 "@opencode/cli-linux-x64-baseline":"2.2.7","@opencode/cli-linux-arm64":"2.2.7"}}
JSON
[[ $(pick_platform "$tmp_root/cli.json" @opencode/cli-linux-x64 @opencode/cli-linux-x64-baseline) == @opencode/cli-linux-x64-baseline ]] ||
  fail 'a platform package of another version must not be picked'
if pick_platform "$tmp_root/cli.json" @opencode/cli-linux-x64 >/dev/null; then fail 'picked a mismatching platform package'; fi
printf 'payload' > "$tmp_root/blob"
blob_sri=$(python3 -c 'import base64,hashlib,sys; print("sha512-"+base64.b64encode(hashlib.sha512(open(sys.argv[1],"rb").read()).digest()).decode())' "$tmp_root/blob")
integrity_ok "$tmp_root/blob" "$blob_sri" || fail 'integrity_ok refused a matching file'
printf 'payloaD' > "$tmp_root/blob2"
if integrity_ok "$tmp_root/blob2" "$blob_sri"; then fail 'integrity_ok accepted another file'; fi
printf '{"version":"2.2.7","dist":{"tarball":"https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-2.2.7.tgz","integrity":"%s"}}' "$blob_sri" > "$tmp_root/plat.json"
[[ $(manifest_field "$tmp_root/plat.json" version) == 2.2.7 && $(manifest_field "$tmp_root/plat.json" integrity) == "$blob_sri" &&
   $(manifest_field "$tmp_root/plat.json" tarball) == https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-2.2.7.tgz ]] ||
  fail manifest_field
printf '{"version":"2.2.7","dist":{"tarball":"https://evil.example/x.tgz","integrity":"sha1-abc"}}' > "$tmp_root/bad.json"
if manifest_field "$tmp_root/bad.json" tarball >/dev/null || manifest_field "$tmp_root/bad.json" integrity >/dev/null; then
  fail 'a tarball outside the registry or a non-sha512 integrity was accepted'
fi
pass 'releases: exact versions, the platform build (baseline without AVX2) matching the release, registry-only tarballs, sha512 integrity'

printf '{"object":"list","data":[{"id":"qwen3:32b"},{"id":"auto"},{"id":"fast"}]}' > "$tmp_root/osr.json"
printf '{"data":[{"id":"tool-model","owned_by":"strata-a"}]}' > "$tmp_root/strata.json"
printf '{"strata-down":{"settings":{"baseURL":"x"},"models":{"kept":{}}},"gone":{"settings":{"baseURL":"y"}}}' > "$tmp_root/prev.json"
providers=$(providers_json 65536 8192 http://127.0.0.1:8765 "$tmp_root/prev.json" \
  "osr=$tmp_root/osr.json" "strata-a=$tmp_root/strata.json" strata-down=- never-listed=-)
python3 - "$providers" <<'PY' || fail "providers_json: $providers"
import json, sys
p = json.loads(sys.argv[1])
assert sorted(p) == ["osr", "strata-a", "strata-down"], sorted(p)
osr = p["osr"]
assert osr["package"] == "@opencode/ai/providers/openai-compatible"
assert osr["settings"] == {"baseURL": "http://127.0.0.1:8765/v1", "apiKey": "no-key"}
assert osr["compatibility"] == {"maxTokensField": "max_tokens"}
assert list(osr["models"]) == ["auto", "fast", "qwen3:32b"]
m = osr["models"]["auto"]
assert m["limit"] == {"context": 65536, "output": 8192}
assert m["capabilities"] == {"tools": True, "freeform": [], "input": ["text"], "output": ["text"]}
assert p["strata-a"]["settings"]["baseURL"] == "http://127.0.0.1:8765/t/strata-a/v1"
assert p["strata-down"] == {"settings": {"baseURL": "x"}, "models": {"kept": {}}}
PY
[[ $(provider_ids <<< "$providers" | paste -sd' ') == 'osr strata-a strata-down' ]] || fail provider_ids
printf '{"data":[]}' > "$tmp_root/empty.json"
[[ $(providers_json 65536 8192 http://127.0.0.1:8765 - "osr=$tmp_root/empty.json") == '{}' ]] || fail 'a provider without models'
python3 -c 'import json,sys; p=json.loads(sys.argv[1]); assert not any("headerTimeout" in v["settings"] for v in p.values())' "$providers" ||
  fail 'a pool without Kindi changed the providers'"'"' timeouts'
printf 'strata-a=strata+http://10.0.0.9:8080\nkindi-k=kindi+http://10.0.0.14:8093\n' > "$tmp_root/targets"
[[ $(kindi_target_names "$tmp_root/targets") == kindi-k ]] || fail kindi_target_names
printf '{"data":[{"id":"bonsai2-2b","owned_by":"kindi-k"}]}' > "$tmp_root/kindi.json"
providers=$(KINDI_TARGETS=kindi-k KINDI_HEADER_TIMEOUT_MS=9000000 providers_json 65536 8192 http://127.0.0.1:8765 - \
  "osr=$tmp_root/osr.json" "strata-a=$tmp_root/strata.json" "kindi-k=$tmp_root/kindi.json")
python3 - "$providers" <<'PY' || fail "Kindi providers_json: $providers"
import json, sys
p = json.loads(sys.argv[1])
assert p["kindi-k"]["settings"]["headerTimeout"] == 9000000 and p["osr"]["settings"]["headerTimeout"] == 9000000
assert "headerTimeout" not in p["strata-a"]["settings"]
PY
pass 'providers: osr lists auto first, each target its own server, text-only JSON tools, a server that is down keeps its models; Kindi and osr (with Kindi) wait for headers'

# opencode_config: this target's keys, the operator's kept.
cfg=$tmp_root/opencode.json
cat > "$cfg" <<'JSON'
{"theme": "mine", "model": "anthropic/x", "providers": {"mine": {"name": "Mine"}, "gone-target": {}},
 "plugins": ["opencode-acme", "@honcho-ai/opencode-honcho@0.1.4", {"package": "@honcho-ai/opencode-honcho", "options": {}}],
 "mcp": {"servers": {"context7": {"type": "remote", "url": "https://mcp.context7.com/mcp"}}}}
JSON
printf '{"osr":{"settings":{"baseURL":"b"}},"t1":{}}' > "$tmp_root/new.json"
printf '{"osr":{},"gone-target":{}}' > "$tmp_root/old.json"
OC_OT_URL=http://192.0.2.70:8000 OC_HONCHO_SPEC=@honcho-ai/opencode-honcho@0.2.1 \
  opencode_config "$cfg" "$tmp_root/new.json" "$tmp_root/old.json" fast || fail 'opencode_config'
python3 - "$cfg" <<'PY' || fail "merged config: $(cat "$cfg")"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["theme"] == "mine" and c["model"] == "osr/fast" and c["update"] == "disable"
assert c["$schema"] == "https://opencode.ai/config.json"
assert sorted(c["providers"]) == ["mine", "osr", "t1"], c["providers"]
assert c["plugins"] == ["opencode-acme", "@honcho-ai/opencode-honcho@0.2.1"], c["plugins"]
s = c["mcp"]["servers"]
assert sorted(s) == ["context7", "open-terminal"]
assert s["open-terminal"] == {"type": "remote", "url": "http://192.0.2.70:8000/mcp", "oauth": False,
                              "headers": {"Authorization": "Bearer {env:OSR_OPEN_TERMINAL_KEY}"}}
PY
OC_OT_PREV=1 opencode_config "$cfg" "$tmp_root/new.json" "$tmp_root/new.json" auto || fail 'opencode_config off'
python3 - "$cfg" <<'PY' || fail "integrations off: $(cat "$cfg")"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["plugins"] == ["opencode-acme"] and list(c["mcp"]["servers"]) == ["context7"]
PY
opencode_config "$tmp_root/fresh.json" "$tmp_root/new.json" - auto || fail 'a fresh config'
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert "plugins" not in c and "mcp" not in c' "$tmp_root/fresh.json" ||
  fail 'a fresh config grew empty plugins or mcp keys'
printf '{\n  // my comment\n  "model": "x",\n}\n' > "$tmp_root/jsonc.json"
cp "$tmp_root/jsonc.json" "$tmp_root/jsonc.expected"
msg=$(opencode_config "$tmp_root/jsonc.json" "$tmp_root/new.json" - auto 2>&1) && fail 'a JSONC config was rewritten'
[[ $msg == *'not plain JSON'*'comments'* ]] && cmp -s "$tmp_root/jsonc.json" "$tmp_root/jsonc.expected" ||
  fail "JSONC: no reason given, or the file changed: $msg"
pass 'opencode.json: provider, model, update and integrations set; the operator'"'"'s providers, plugins, MCP servers and keys kept; JSONC refused'

hcfg=$tmp_root/honcho.json
printf '{"other": 1, "apiKey": "old", "hosts": {"opencode": {"apiKey": "host", "recallMode": "tools"}, "claude": {}}}' > "$hcfg"
printf 'hch-key-123\n' > "$tmp_root/hkey"
honcho_config "$hcfg" http://192.0.2.85:8000 "$tmp_root/hkey" opencode-284 || fail honcho_config
python3 - "$hcfg" <<'PY' || fail "Honcho config: $(cat "$hcfg")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["apiKey"] == "hch-key-123" and d["baseUrl"] == "http://192.0.2.85:8000" and d["peerName"] == "user" and d["other"] == 1
h = d["hosts"]["opencode"]
assert "apiKey" not in h and h["workspace"] == "opencode-284" and h["aiPeer"] == "opencode"
assert h["recallMode"] == "tools" and h["sessionStrategy"] == "per-directory"
assert h["observationMode"] == "unified" and h["removeUserPrefix"] is True and "claude" in d["hosts"]
PY
[[ $(stat -c %a "$hcfg") == 600 ]] || fail 'the Honcho config is not private'
pass 'the Honcho plugin config: this CT'"'"'s key, URL and workspace; a host key override dropped; other settings kept'

# settings_record reads these globals.
# shellcheck disable=SC2034
ROUTER_URL=http://r:8000 OPENCODE_MODEL=auto OPENCODE_CONTEXT_LENGTH=65536 OPENCODE_MAX_TOKENS=8192 OPENCODE_VERSION=2.2.7
# shellcheck disable=SC2034
release_name=2.2.7-linux-x64 OPENCODE_PORT=4096 OPENCODE_WEB=true OPENCODE_FREE_MODELS=false HONCHO_PLUGIN_VERSION=0.2.1
# shellcheck disable=SC2034
backend_keys_sha256=none targets_sha256=none honcho_workspace=none providers_sha256=p unit_sha256=u HONCHO_URL='' honcho_key_sha256=none
# shellcheck disable=SC2034
OPEN_TERMINAL_URL='' ot_key_sha256=none
# shellcheck disable=SC2034
OPENCODE_API=true OPENCODE_API_PORT=4097 OPENCODE_API_PERMISSIONS=allow api_key_sha256=$(printf 'api-secret' | sha256sum | cut -d' ' -f1)
router_key_sha256=$(printf 'sk-secret-key' | sha256sum | cut -d' ' -f1)
record=$(settings_record)
[[ $record == *"ROUTER_KEY_SHA256=$router_key_sha256"* && $record != *sk-secret-key* ]] ||
  fail 'the settings record must hold the key hash, never the key'
[[ $record == *$'\nOPENCODE_CONTEXT_LENGTH=65536\n'* && $record == *$'\nOPENCODE_RELEASE=2.2.7-linux-x64\n'* ]] ||
  fail 'the dispatcher and provisioner read these from the record'
[[ $record == *$'\nOPENCODE_API=true\nOPENCODE_API_PORT=4097\nOPENCODE_API_PERMISSIONS=allow\n'* &&
   $record == *"API_KEY_SHA256=$api_key_sha256"* && $record != *api-secret* ]] ||
  fail 'the chat endpoint settings (and only its key hash) are recorded'
printf '{"data":[{"id":"auto"},{"id":"qwen3:32b"}]}' | models_has qwen3:32b || fail models_has
chat_probe_body auto | python3 -c 'import json,sys; b=json.load(sys.stdin); assert b["tools"] and b["model"]=="auto"' ||
  fail 'the chat probe must offer a tool'
[[ $(printf '{"error":{"message":"m does not support tools"}}' | error_message) == 'm does not support tools' ]] ||
  fail error_message
printf '{"location":{},"data":{"id":"auto","providerID":"osr"}}' | default_model_is osr auto || fail default_model_is
if printf '{"data":{"id":"claude","providerID":"opencode"}}' | default_model_is osr auto; then fail 'another default model passed'; fi
pass 'settings, model listing, the tool probe body, error parsing and the default-model check'

unit=$here/opencode.service
grep -qx 'ExecStart=/usr/local/bin/opencode serve --hostname ${OSR_OPENCODE_BIND} --port ${OSR_OPENCODE_PORT}' "$unit" ||
  fail 'unit ExecStart'
grep -qx 'User=opencode' "$unit" && grep -qx 'WorkingDirectory=/home/opencode/workspace' "$unit" || fail 'unit runs as opencode in its workspace'
grep -qx 'ProtectHome=read-only' "$unit" && grep -qx 'ReadWritePaths=/home/opencode' "$unit" || fail 'unit home access'
grep -qx 'EnvironmentFile=/etc/opencode-target/opencode.env' "$unit" || fail 'unit does not load the password'
grep -qx 'Environment=OPENCODE_DISABLE_AUTOUPDATE=1' "$unit" || fail 'OpenCode must not update its own binary'
grep -q '^MemoryDenyWriteExecute' "$unit" && fail 'the JavaScript JIT needs writable executable memory'
grep -qi 'password=' <(grep -v '^#' "$unit") && fail 'the password must not be in the unit'
direct=$here/opencode-direct.service
grep -qx 'User=opencode-direct' "$direct" || fail 'the dispatcher runs as its own account'
grep -qx 'ExecStart=/usr/bin/python3 /usr/local/lib/opencode-direct.py' "$direct" || fail 'dispatcher ExecStart'
grep -qx 'Environment=DIRECT_ETC=/etc/opencode-target' "$direct" &&
  grep -qx 'Environment=DIRECT_SECRETS_FILE=/etc/opencode-target/router.env' "$direct" &&
  grep -qx 'Environment=DIRECT_CONTEXT_SETTING=OPENCODE_CONTEXT_LENGTH' "$direct" || fail 'dispatcher files'
api_unit=$here/opencode-api.service
grep -qx 'User=opencode-api' "$api_unit" || fail 'the chat endpoint runs as its own account'
grep -qx 'ExecStart=/usr/bin/python3 /usr/local/lib/opencode-api.py' "$api_unit" || fail 'chat endpoint ExecStart'
grep -qx 'EnvironmentFile=/etc/opencode-target/api.env' "$api_unit" && grep -qx 'Requires=opencode.service' "$api_unit" &&
  grep -qx 'StateDirectory=opencode-api' "$api_unit" && grep -qx 'ProtectHome=true' "$api_unit" || fail 'chat endpoint files and sandbox'
grep -qi -e 'password=' -e 'api_key=' <(grep -v '^#' "$api_unit") && fail 'a secret is in the chat endpoint unit'
pass 'the units run hardened, the dispatcher and chat endpoint apart from the agent, and carry no secret'

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
for command_name in npm node npx; do stub "$command_name" 'echo "$0 must not be run (OpenCode 2 needs no Node)" >&2; exit 99'; done
stub useradd 'name=${*: -1}; touch "$FAKE_STATE/user-$name"; [[ $* == *--system* ]] || mkdir -p "$OC_USER_HOME"'
stub id 'name=${*: -1}; [[ -e $FAKE_STATE/user-$name ]]'
stub getent '[[ $1 == passwd && -e $FAKE_STATE/user-opencode ]] && printf "opencode:x:1000:1000::%s:/bin/bash\n" "$OC_USER_HOME"'
# runuser -u USER -- CMD...: run CMD as the caller (no opencode account here).
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
# install: drop -o/-g (the accounts do not exist here).
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub ip 'printf "2: eth0    inet 192.0.2.84/24 brd 192.0.2.255 scope global eth0\n"'
stub uname 'echo x86_64'
stub systemctl 'unit=${*: -1}; file=$FAKE_STATE/active
[[ $unit != opencode-direct.service ]] || file=$FAKE_STATE/direct-active
[[ $unit != opencode-api.service ]] || file=$FAKE_STATE/api-active
case $1 in
  is-active) [[ -e $file ]]; exit ;;
  restart) touch "$file" ;;
  disable) [[ $2 != --now ]] || rm -f "$file" ;;
esac; exit 0'
# The fake opencode binary in every platform tarball.
cat > "$tmp_root/opencode" <<'OPENCODE'
#!/usr/bin/env bash
echo "opencode $*" >> "$FAKE_LOG"
case $1 in
  --version) echo '@VERSION@' ;;
  *) exit 2 ;;
esac
OPENCODE
# curl: the npm registry, the router, the local dispatcher, Honcho, Open
# Terminal and the OpenCode server.
cat > "$bin/curl" <<'CURL'
#!/usr/bin/env python3
import base64, hashlib, io, json, os, sys, tarfile
args = sys.argv[1:]
log, state = os.environ["FAKE_LOG"], os.environ["FAKE_STATE"]
with open(log, "a") as f:
    f.write("curl " + " ".join(args) + "\n")
out = fmt = data = None
headers, url, fail_flag = [], None, False
i = 0
while i < len(args):
    a = args[i]
    if a in ("-o", "-w", "-H", "--data-binary", "--max-time", "--proto"):
        v = args[i + 1]; i += 2
        if a == "-o": out = v
        elif a == "-w": fmt = v
        elif a == "-H": headers.append(open(v[1:]).read().strip() if v.startswith("@") else v)
        elif a == "--data-binary": data = open(v[1:]).read()
        continue
    if a == "--fail": fail_flag = True
    if a.startswith("http"):
        url = a
    i += 1
def header(prefix):
    return next((h.split(" ", 2)[2] for h in headers if h.lower().startswith(prefix)), "")
bearer = header("authorization: bearer ")
basic = header("authorization: basic ")
home, etc, opt = os.environ["OC_USER_HOME"], os.environ["OC_ETC"], os.environ["OPT_DIR"]
def kv(path, key):
    try:
        for line in open(path):
            k, _, v = line.rstrip("\n").partition("=")
            if k == key: return v
    except FileNotFoundError:
        pass
    return ""
def reply(status, body):
    if fail_flag and status >= 400:
        sys.stderr.write(f"curl: (22) The requested URL returned error: {status}\n")
        sys.exit(22)
    if out:
        with open(out, "wb") as f:
            f.write(body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode())
    if fmt:
        sys.stdout.write(str(status))
    sys.exit(0)
def refused():
    sys.stderr.write("curl: (7) Failed to connect\n")
    if fmt: sys.stdout.write("000")
    sys.exit(7)
reg = "https://registry.npmjs.org/"
platforms = ["linux-x64", "linux-x64-baseline", "linux-arm64"]
def tarball(platform, version):
    path = os.path.join(state, f"tgz-{platform}-{version}")
    if not os.path.exists(path):
        script = open(os.environ["FAKE_OPENCODE"]).read().replace("@VERSION@", os.environ.get("FAKE_BIN_VERSION", version)).encode()
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w:gz") as t:
            for name, content, mode in (("package/package.json", b"{}", 0o644), ("package/bin/opencode", script, 0o755)):
                info = tarfile.TarInfo(name); info.size = len(content); info.mode = mode
                t.addfile(info, io.BytesIO(content))
        open(path, "wb").write(buf.getvalue())
    return open(path, "rb").read()
if url and url.startswith(reg):
    if os.environ.get("FAKE_REGISTRY_DOWN"): refused()
    rest = url[len(reg):]
    if rest.startswith("@opencode%2fcli/"):
        spec = rest.split("/", 1)[1]
        version = os.environ.get("FAKE_LATEST", "2.2.8") if spec == "latest" else spec
        lag = os.environ.get("FAKE_PLATFORM_LAG", "")
        deps = {f"@opencode/cli-{p}": (lag if lag and p == "linux-x64" else version) for p in platforms}
        reply(200, {"name": "@opencode/cli", "version": version, "optionalDependencies": deps})
    for p in platforms:
        prefix = f"@opencode%2fcli-{p}/"
        if rest.startswith(prefix):
            version = rest[len(prefix):]
            body = tarball(p, version)
            if os.environ.get("FAKE_BAD_INTEGRITY"): body = body + b"x"
            sri = "sha512-" + base64.b64encode(hashlib.sha512(body).digest()).decode()
            reply(200, {"name": f"@opencode/cli-{p}", "version": version,
                        "dist": {"tarball": f"{reg}@opencode/cli-{p}/-/cli-{p}-{version}.tgz", "integrity": sri}})
        if rest.startswith(f"@opencode/cli-{p}/-/cli-{p}-") and rest.endswith(".tgz"):
            version = rest[len(f"@opencode/cli-{p}/-/cli-{p}-"):-len(".tgz")]
            reply(200, tarball(p, version))
    reply(404, {"error": "Not found"})
router = os.environ.get("FAKE_ROUTER_URL", "http://192.168.11.80:8000")
terminal = os.environ.get("FAKE_OT_URL", "http://192.0.2.70:8000")
honcho = os.environ.get("FAKE_HONCHO_URL", "http://192.0.2.85:8000")
if url.startswith(honcho):
    if os.environ.get("FAKE_HONCHO_DOWN"): refused()
    if url.endswith("/osr/v1/whoami"):
        if os.environ.get("FAKE_HONCHO_NO_GATEWAY"): reply(404, {"detail": "Not Found"})
        if bearer == os.environ.get("FAKE_HONCHO_BAD_KEY", "-"): reply(401, {"detail": "Invalid API key"})
        reply(200, {"client": "opencode-284", "user": None, "workspace": "opencode-284", "per_user": False})
if url.startswith(terminal):
    if os.environ.get("FAKE_OT_DOWN"): refused()
    if url.endswith("/osr/v1/whoami"):
        if bearer != os.environ.get("FAKE_OT_KEY", "ot-key-0123456789abcdef"):
            reply(401, {"detail": "Invalid API key"})
        reply(200, {"client": "opencode-284", "user": "default", "workspace": "0123456789abcdef"})
if url.startswith(router):
    if os.environ.get("FAKE_ROUTER_DOWN"): refused()
    if bearer != os.environ.get("FAKE_ROUTER_KEY", ""):
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
api_env = os.path.join(etc, "api.env")
if url.startswith("http://127.0.0.1:") and os.path.exists(api_env) and \
        url.split(":")[2].split("/")[0] == kv(api_env, "OPENCODE_API_PORT"):
    # The chat endpoint: runs while its unit and the server's are active, with
    # the key of its environment file.
    if not os.path.exists(os.path.join(state, "api-active")) or os.environ.get("FAKE_API_DOWN"): refused()
    path = "/" + url.split("/", 3)[3]
    if path == "/healthz":
        reply(200 if os.path.exists(os.path.join(state, "active")) else 503, {"status": "ok"})
    if bearer != kv(api_env, "OPENCODE_API_KEY") or not bearer:
        reply(401, {"error": {"message": "Invalid API key"}})
    if path == "/v1/models":
        reply(200, {"object": "list", "data": [{"id": kv(api_env, "OPENCODE_API_MODEL") or "opencode"}]})
if url.startswith("http://127.0.0.1:"):
    # The OpenCode server: runs while the unit is active, on the port and with
    # the password of its environment file, from the release behind "current".
    port = url.split(":")[2].split("/")[0]
    path = url.split(port, 1)[1]
    env = os.path.join(etc, "opencode.env")
    if not os.path.exists(os.path.join(state, "active")): refused()
    if port != kv(env, "OSR_OPENCODE_PORT") or port == os.environ.get("FAKE_BAD_PORT"): refused()
    release = os.path.basename(os.readlink(os.path.join(opt, "current"))) if os.path.islink(os.path.join(opt, "current")) else ""
    if release and release == os.environ.get("FAKE_BROKEN_RELEASE"): refused()
    if base64.b64decode(basic or "").decode() != "opencode:" + kv(env, "OPENCODE_PASSWORD"):
        reply(401, {"_tag": "UnauthorizedError", "message": "Authentication required"})
    if path == "/api/info": reply(200, {"version": release.split("-")[0], "pid": 1, "urls": [], "paths": {}})
    if path == "/api/model/default":
        try:
            # OpenCode reads JSONC: comment lines are allowed.
            text = "".join(l for l in open(os.path.join(home, ".config/opencode/opencode.json"))
                           if not l.lstrip().startswith("//"))
            cfg = json.loads(text)
        except (OSError, ValueError):
            reply(200, {"location": {}, "data": None})
        provider, _, model = cfg.get("model", "").partition("/")
        if model not in ((cfg.get("providers") or {}).get(provider) or {}).get("models", {}):
            reply(200, {"location": {}, "data": {"id": "big-pickle", "providerID": "opencode"}})
        reply(200, {"location": {}, "data": {"id": model, "providerID": provider}})
sys.stderr.write(f"fake curl: unexpected {url}\n")
sys.exit(22)
CURL
chmod +x "$bin/curl"
if ! command -v openssl >/dev/null; then
  stub openssl 'python3 -c "import secrets; print(secrets.token_hex(32))"'
fi

deploy=$tmp_root/deploy
home=$tmp_root/home/opencode
etc=$tmp_root/etc/opencode-target
opt=$tmp_root/opt/opencode
units=$tmp_root/systemd
reset_tree() {
  rm -rf -- "${deploy:?}" "${tmp_root:?}/home" "${tmp_root:?}/etc" "${tmp_root:?}/opt" "${tmp_root:?}/usr" "${units:?}" "${state:?}"/* "${log:?}"
  mkdir -p "$deploy" "$units" "$tmp_root/etc"
  cp "$script" "$here/opencode.service" "$here/opencode-direct.service" "$here/opencode-api.service" \
    "$here/openai-proxy.py" "$deploy/"
  cp "$here/../hermes/direct-dispatch.py" "$deploy/"
  : > "$log"
}
router_key=sk-router-0123456789abcdef
push_key() { printf '%s\n' "${1:-$router_key}" > "$deploy/router-api-key"; chmod 0600 "$deploy/router-api-key"; }
# guest [VAR=value ...]: run the deployed installer in the fake tree.
guest() {
  env PATH="$bin:$PATH" OC_USER_HOME="$home" OC_ETC="$etc" OPT_DIR="$opt" BIN_LINK="$tmp_root/usr/local/bin/opencode" \
    UNIT_DIR="$units" DIRECT_LIB="$tmp_root/opencode-direct.py" API_LIB="$tmp_root/opencode-api.py" CPUINFO="$tmp_root/cpu-avx2" \
    LOCK_FILE="$tmp_root/etc/opencode-target.lock" HEALTH_TIMEOUT=2 \
    FAKE_OPENCODE="$tmp_root/opencode" FAKE_ROUTER_KEY="$router_key" \
    ROUTER_URL=http://192.168.11.80:8000 "$@" \
    bash "$deploy/install-target.sh" 2>&1
}
kv() { awk -v k="$1" -F= '$1==k {sub(/^[^=]*=/,""); print; exit}' "$2"; }
jq_() { python3 -c 'import json,sys
v = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    v = v[k] if isinstance(v, dict) and k in v else None
print(json.dumps(v, sort_keys=True, separators=(",", ":")) if not isinstance(v, str) else v)' "$1" "$2"; }
config=$home/.config/opencode/opencode.json
env_file=$etc/opencode.env

# 1. A release whose tarball does not match the registry's integrity is refused.
reset_tree; push_key
out=$(guest FAKE_BAD_INTEGRITY=1) && fail 'a tarball with another sha512 was installed'
[[ $out == *"does not match the registry's sha512 integrity. Nothing was installed."* ]] || fail "integrity message: $out"
[[ ! -e $opt/current && -z $(ls -A "$opt/releases" 2>/dev/null) && ! -e $units/opencode.service ]] ||
  fail 'a refused release left files behind'
pass 'a platform tarball that does not match the registry'"'"'s sha512 integrity is refused before anything is installed'

# 2. A fresh install with the web UI.
reset_tree; push_key
out=$(guest) || fail "fresh install: $out"
grep -q '^curl .*https://registry.npmjs.org/@opencode%2fcli/2.2.7 ' "$log" || fail 'the pinned release was not resolved'
grep -q '^curl .*https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-2.2.7.tgz ' "$log" ||
  fail 'the AVX2 platform tarball was not downloaded from the registry'
[[ $(readlink "$opt/current") == "$opt/releases/2.2.7-linux-x64" && $(readlink "$tmp_root/usr/local/bin/opencode") == "$opt/current/opencode" ]] ||
  fail 'the release and binary links'
[[ $(stat -c %a "$opt/releases/2.2.7-linux-x64/opencode") == 755 ]] || fail 'the binary is not world-executable and root-writable only'
grep -q '^@opencode/cli-linux-x64@2.2.7$' "$opt/releases/2.2.7-linux-x64/SOURCE" || fail 'the release does not record its source'
python3 - "$config" <<'PY' || fail "config: $(cat "$config")"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["model"] == "osr/auto" and c["update"] == "disable" and "plugins" not in c and "mcp" not in c
osr = c["providers"]["osr"]
assert osr["settings"] == {"baseURL": "http://127.0.0.1:8765/v1", "apiKey": "no-key"}
assert list(osr["models"]) == ["auto", "fast", "qwen3:32b"]
assert all(m["limit"] == {"context": 65536, "output": 8192} for m in osr["models"].values())
PY
[[ $(kv OPENCODE_PASSWORD "$env_file") == "$(< "$etc/password")" && $(wc -c < "$etc/password") -ge 64 ]] || fail 'server password'
[[ $(kv OSR_OPENCODE_BIND "$env_file") == 0.0.0.0 && $(kv OSR_OPENCODE_PORT "$env_file") == 4096 &&
   $(kv OPENCODE_DISABLE_FREE_MODELS "$env_file") == 1 ]] || fail "server environment: $(cat "$env_file")"
grep -q "$(< "$etc/password")" "$config" && fail 'opencode.json holds the server password'
[[ $(kv ROUTER_API_KEY "$etc/router.env") == "$router_key" ]] || fail 'ROUTER_API_KEY not kept for the dispatcher'
[[ $(stat -c %a "$env_file") == 600 && $(stat -c %a "$etc/password") == 600 && $(stat -c %a "$etc/router.env") == 640 &&
   $(stat -c %a "$config") == 600 ]] || fail 'file modes'
grep -q 'chown root:opencode-direct .*/router.env' "$log" || fail 'the router key is not owned by the dispatcher account'
grep -q 'chown opencode:opencode .*/opencode.json' "$log" || fail 'the agent does not own its config'
[[ ! -e $deploy/router-api-key ]] || fail 'the pushed router key was not removed'
[[ -f $units/opencode.service && -f $units/opencode-direct.service && -e $state/active && -e $state/direct-active ]] ||
  fail 'server or dispatcher not started'
cmp -s "$tmp_root/opencode-direct.py" "$here/../hermes/direct-dispatch.py" || fail "the Hermes target's dispatcher was not installed"
grep -q '^OPENCODE_CONTEXT_LENGTH=65536$' "$etc/settings" && grep -q '^OPENCODE_RELEASE=2.2.7-linux-x64$' "$etc/settings" ||
  fail 'the settings record'
grep -q '^PROVIDERS_SHA256=pending$' "$etc/settings" && fail 'the final settings record was not written'
grep -q "$router_key" "$etc/settings" && fail 'the settings record holds the router key'
grep '^curl ' "$log" | grep -q -e "$router_key" -e "$(< "$etc/password")" && fail 'a secret was passed to curl in argv'
python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["tools"]' "$state/probe.json" ||
  fail 'the chat probe did not offer a tool'
[[ $out == *'Web UI: http://192.0.2.84:4096/'* ]] || fail "summary: $out"
pass 'fresh install: the checked binary in its release, providers and default model, password kept out of the config, router key kept apart'

# 3. Unchanged: nothing to do, and no registry call for an installed exact release.
: > "$log"
out=$(guest) || fail "rerun: $out"
[[ $out == *'nothing to do'* ]] || fail "unchanged rerun did work: $out"
grep -qE '^(apt-get|systemctl restart|curl .*registry)' "$log" && fail 'unchanged rerun touched packages, the registry or the units'
pass 'an unchanged, healthy installation is left alone, without asking the npm registry'

# 4. A new pool model, then a rotated router key: applied without a download.
: > "$log"
out=$(guest FAKE_DIRECT_MODELS=auto,fast,qwen3:32b,gemma4:27b) || fail "new model: $out"
[[ $(jq_ "$config" providers.osr.models) == *'"gemma4:27b"'* ]] || fail 'the new model is not in provider osr'
old_password=$(< "$etc/password")
router_key=sk-router-rotated-999999
push_key
out=$(guest FAKE_DIRECT_MODELS=auto,fast,qwen3:32b,gemma4:27b) || fail "rotation: $out"
[[ $(kv ROUTER_API_KEY "$etc/router.env") == "$router_key" && $(< "$etc/password") == "$old_password" ]] ||
  fail 'the rotated key was not applied, or the password changed'
grep -q '\.tgz ' "$log" && fail 'a model change or key rotation downloaded OpenCode again'
pass 'a pool model and a rotated router key are applied on rerun, keeping the password and the release'

# 5. The router rejects the key; a router that needs a key gets none.
before=$(cat "$config" "$env_file" "$etc/router.env")
out=$(guest FAKE_ROUTER_KEY=sk-router-something-else) && fail 'a rejected key was accepted'
[[ $out == *'rejected the API key'*'--reconfigure'* ]] || fail "rejected key message: $out"
[[ $(cat "$config" "$env_file" "$etc/router.env") == "$before" ]] || fail 'a rejected key changed the configuration'
reset_tree
out=$(guest) && fail 'a missing key was accepted'
[[ $out == *'requires its API key'* ]] || fail "missing key message: $out"
grep -q '^apt-get install' "$log" && fail 'packages installed before the probe'
pass 'a key the router rejects, or no key at all, stops the run before anything changes'

# 6. The direct tool probe fails: rolled back; it can be skipped.
reset_tree; push_key
out=$(guest FAKE_CHAT_STATUS=400 FAKE_CHAT_ERROR='gemma3:12b does not support tools') && fail 'a failed tool probe was accepted'
[[ $out == *'Direct model-server chat probe failed'*'does not support tools'* ]] || fail "probe message: $out"
[[ ! -e $etc/settings && ! -e $state/direct-active && ! -e $opt/current && ! -d $opt/releases/2.2.7-linux-x64 ]] ||
  fail 'settings, dispatcher or the new release kept after a failed probe'
[[ -e $deploy/router-api-key ]] || fail 'the key file must stay for a retry'
rm -f "$state/probe.json"
out=$(guest FAKE_CHAT_STATUS=400 OPENCODE_SKIP_CHAT_PROBE=true) || fail "skip probe: $out"
[[ ! -e $state/probe.json ]] || fail 'OPENCODE_SKIP_CHAT_PROBE still sent a chat request'
pass 'a failed direct tool-call probe rolls back the settings and the new release; it can be skipped explicitly'

# 7. Unknown model, unreachable router, a model the dispatcher cannot use.
reset_tree; push_key
out=$(guest OPENCODE_MODEL=nope:1b) && fail 'an unadvertised model was accepted'
[[ $out == *"does not advertise model 'nope:1b'"* ]] || fail "model message: $out"
out=$(guest FAKE_ROUTER_DOWN=1) && fail 'an unreachable router was accepted'
[[ $out == *'unreachable'* ]] || fail "unreachable message: $out"
out=$(guest OPENCODE_MODEL=large) && fail 'a model without tools or context was accepted'
[[ $out == *"does not offer OPENCODE_MODEL 'large'"* ]] || fail "unusable model message: $out"
out=$(guest FAKE_REGISTRY_DOWN=1) && fail 'an unreachable registry was accepted'
[[ $out == *'Could not download https://registry.npmjs.org/'* ]] || fail "registry message: $out"
pass 'an unadvertised model, an unreachable router or registry, or a model the dispatcher refuses is reported'

# 8. Releases: an upgrade switches the link and keeps the previous release; a
# release that does not start is rolled back to the running one.
reset_tree; push_key
guest >/dev/null || fail 'setup for the upgrade'
prev_config=$(< "$config")
out=$(guest OPENCODE_VERSION=2.2.8) || fail "upgrade: $out"
[[ $(readlink "$opt/current") == "$opt/releases/2.2.8-linux-x64" && -d $opt/releases/2.2.7-linux-x64 ]] ||
  fail 'the upgrade did not switch to 2.2.8 and keep 2.2.7'
grep -q '^OPENCODE_RELEASE=2.2.8-linux-x64$' "$etc/settings" || fail 'the new release is not recorded'
prev_config=$(< "$config"); prev_settings=$(< "$etc/settings")
out=$(guest OPENCODE_VERSION=2.2.9 FAKE_BROKEN_RELEASE=2.2.9-linux-x64) && fail 'a release that does not start was accepted'
[[ $out == *'did not answer on port 4096'*'running again'* ]] || fail "upgrade rollback message: $out"
[[ $(readlink "$opt/current") == "$opt/releases/2.2.8-linux-x64" && ! -e $opt/releases/2.2.9-linux-x64 ]] ||
  fail 'the rollback did not switch back to 2.2.8 and remove 2.2.9'
[[ $(< "$config") == "$prev_config" && $(< "$etc/settings") == "$prev_settings" ]] || fail 'rollback did not restore the config and settings'
out=$(guest OPENCODE_VERSION=2.2.10) || fail "second upgrade: $out"
[[ -d $opt/releases/2.2.8-linux-x64 && ! -e $opt/releases/2.2.7-linux-x64 ]] || fail 'only the running and the previous release are kept'
pass 'an upgrade installs the new release beside the old; one that does not start is rolled back and running again; two releases are kept'

# 9. The previous server fails too: every server call is refused.
mv "$bin/curl" "$bin/curl.real"
cat > "$bin/curl" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ \$a == http://127.0.0.1:4* ]]; then
    [[ " \$* " == *" -w "* ]] && printf 000
    exit 7
  fi
done
exec "$bin/curl.real" "\$@"
WRAP
chmod +x "$bin/curl"
out=$(guest OPENCODE_VERSION=2.2.10 OPENCODE_MAX_TOKENS=4096) && fail 'a double failure was accepted'
mv -f "$bin/curl.real" "$bin/curl"
[[ $out == *'did not become healthy either'* ]] || fail "double failure message: $out"
pass 'a rollback whose previous server does not come back either is reported as failed too'

# 10. latest is resolved, recorded exactly and followed; a CPU without AVX2 gets the baseline build.
reset_tree; push_key
out=$(guest OPENCODE_VERSION=latest FAKE_LATEST=2.3.0 CPUINFO="$tmp_root/cpu-old") || fail "latest: $out"
[[ $(readlink "$opt/current") == "$opt/releases/2.3.0-linux-x64-baseline" ]] || fail 'latest or the baseline build'
grep -q '^OPENCODE_VERSION=latest$' "$etc/settings" && grep -q '^OPENCODE_RELEASE=2.3.0-linux-x64-baseline$' "$etc/settings" ||
  fail 'latest is not recorded with its exact release'
[[ $out == *'Pin this release with OPENCODE_VERSION=2.3.0'* ]] || fail "pin hint: $out"
out=$(guest OPENCODE_VERSION=latest FAKE_LATEST=2.3.0 CPUINFO="$tmp_root/cpu-old") || fail "latest rerun: $out"
[[ $out == *'nothing to do'* ]] || fail 'an unchanged latest did work'
out=$(guest OPENCODE_VERSION=latest FAKE_LATEST=2.3.1 CPUINFO="$tmp_root/cpu-old") || fail "latest moved: $out"
[[ $(readlink "$opt/current") == "$opt/releases/2.3.1-linux-x64-baseline" ]] || fail 'a moved latest was not followed'
reset_tree; push_key
out=$(guest FAKE_PLATFORM_LAG=2.2.6 CPUINFO="$tmp_root/cpu-avx2") || fail "platform lag: $out"
[[ $(readlink "$opt/current") == "$opt/releases/2.2.7-linux-x64-baseline" ]] || fail 'a platform package of another version was used'
reset_tree; push_key
out=$(guest FAKE_BIN_VERSION=2.2.6) && fail 'a binary reporting another version was accepted'
[[ $out == *'does not run or does not report 2.2.7'* ]] || fail "binary version message: $out"
pass 'latest is recorded as its exact release and followed; no AVX2 or a lagging platform package selects the baseline; the binary must report its release'

# 11. A JSONC config written by hand is refused, and everything is restored.
reset_tree; push_key
guest >/dev/null || fail 'setup for JSONC'
sed -i '1a\  // mine' "$config"
prev_env=$(< "$env_file")
out=$(guest OPENCODE_MAX_TOKENS=4096) && fail 'a JSONC config was accepted'
[[ $out == *'not plain JSON'* && $out == *'running again'* ]] || fail "JSONC message: $out"
grep -q '// mine' "$config" && [[ $(< "$env_file") == "$prev_env" ]] || fail 'the JSONC file or the environment was not restored'
grep -q '^OPENCODE_MAX_TOKENS=8192$' "$etc/settings" || fail 'settings not restored'
pass 'a hand-written JSONC opencode.json is not rewritten: the run is rolled back'

# 12. Web UI off, free models on, another port.
reset_tree; push_key
out=$(guest OPENCODE_WEB=false OPENCODE_FREE_MODELS=true OPENCODE_PORT=4100) || fail "web off: $out"
[[ $(kv OSR_OPENCODE_BIND "$env_file") == 127.0.0.1 && $(kv OSR_OPENCODE_PORT "$env_file") == 4100 ]] || fail 'loopback bind or port'
[[ -z $(kv OPENCODE_DISABLE_FREE_MODELS "$env_file") ]] || fail 'OPENCODE_FREE_MODELS=true still hides the free models'
pass 'OPENCODE_WEB=false binds loopback; OPENCODE_FREE_MODELS=true offers the free models; the port follows OPENCODE_PORT'

# 13. Direct targets: one provider each; a removed one goes; one that is down keeps its models; the operator's stay.
reset_tree; push_key
printf 'strata-192-168-11-154-8080=strata+http://192.168.11.154:8080\nollama-192-168-11-153-11434=http://192.168.11.153:11434\n' > "$deploy/targets"
out=$(guest) || fail "install with targets: $out"
for name in strata-192-168-11-154-8080 ollama-192-168-11-153-11434; do
  [[ $(jq_ "$config" "providers.$name.settings.baseURL") == "http://127.0.0.1:8765/t/$name/v1" &&
     $(jq_ "$config" "providers.$name.models") == *"\"$name-model\""* ]] || fail "direct provider $name"
done
cmp -s "$deploy/targets" "$etc/targets" || fail 'the targets file was not installed for the dispatcher'
python3 - "$config" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["providers"]["mine"] = {"name": "Mine"}
c["theme"] = "mine"
json.dump(c, open(sys.argv[1], "w"))
PY
out=$(guest FAKE_TARGET_DOWN=strata-192-168-11-154-8080) || fail "a target down: $out"
[[ $out == *'Could not list the models of strata-192-168-11-154-8080'* ]] || fail 'a target that is down is not reported'
[[ $(jq_ "$config" providers.strata-192-168-11-154-8080.models) == *'strata-192-168-11-154-8080-model'* ]] || fail 'a target that is down lost its provider'
printf 'strata-192-168-11-154-8080=strata+http://192.168.11.154:8080\n' > "$deploy/targets"
out=$(guest) || fail "rerun with a target removed: $out"
[[ $(jq_ "$config" providers.ollama-192-168-11-153-11434) == null ]] || fail 'the stale provider is still configured'
[[ $(jq_ "$config" providers.mine.name) == Mine && $(jq_ "$config" theme) == mine ]] || fail "the operator's settings were dropped"
printf 'Bad Name=http://x:1\n' > "$deploy/targets"
out=$(guest) && fail "an invalid targets file was accepted: $out"
[[ $out == *'invalid line'* ]] || fail "invalid targets message: $out"
printf 'osr=http://x:1\n' > "$deploy/targets"
out=$(guest) && fail 'a target named osr was accepted'
rm -f "$deploy/targets"
pass "direct targets: a provider per model server, kept through an outage, removed with the server; the operator's own settings stay"

# 13b. A Kindi target: it and osr wait twice the router's budget for headers.
reset_tree; push_key
printf 'kindi-192-168-11-14-8093=kindi+http://192.168.11.14:8093\n' > "$deploy/targets"
out=$(guest KINDI_READ_TIMEOUT_SECONDS=5400) || fail "install with a Kindi target: $out"
for name in osr kindi-192-168-11-14-8093; do
  [[ $(jq_ "$config" "providers.$name.settings.headerTimeout") == $((5400 * 2000)) ]] || fail "Kindi header timeout on $name"
done
grep -qx 'KINDI_READ_TIMEOUT_SECONDS=5400' "$etc/settings" || fail 'the dispatcher budget is not in the settings record'
out=$(guest KINDI_READ_TIMEOUT_SECONDS=0) && fail "an invalid Kindi budget was accepted: $out"
rm -f "$deploy/targets"
pass 'a Kindi target: it and osr wait twice the router'"'"'s read budget for response headers'

# 14. One run at a time.
exec {held}>>"$tmp_root/etc/opencode-target.lock"
flock "$held"
out=$(guest) && fail 'a second concurrent run was accepted'
[[ $out == *'Another install-target.sh run holds'* ]] || fail "lock message: $out"
exec {held}>&-
pass 'a second concurrent run is refused'

# 15. Honcho memory: plugin pinned, config with this CT's workspace; a failed
# run restores it; HONCHO_URL= removes it.
reset_tree; push_key
printf 'honcho-key-A\n' > "$deploy/honcho-api-key"
out=$(guest HONCHO_URL=http://192.0.2.85:8000/) || fail "Honcho on: $out"
[[ $(jq_ "$config" plugins) == '["@honcho-ai/opencode-honcho@0.2.1"]' ]] || fail "plugin entry: $(jq_ "$config" plugins)"
honcho_cfg=$home/.honcho/config.json
python3 - "$honcho_cfg" <<'PY' || fail "Honcho config: $(cat "$honcho_cfg")"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["apiKey"] == "honcho-key-A" and d["baseUrl"] == "http://192.0.2.85:8000"
assert d["hosts"]["opencode"]["workspace"] == "opencode-284"
PY
grep -q honcho-key-A "$config" && fail 'opencode.json holds the Honcho key'
[[ $(stat -c %a "$honcho_cfg") == 600 ]] || fail 'the Honcho config is not private'
grep -q '^HONCHO_WORKSPACE=opencode-284$' "$etc/settings" || fail 'the workspace is not recorded'
printf 'honcho-key-B\n' > "$deploy/honcho-api-key"
out=$(guest HONCHO_URL=http://192.0.2.85:8000 FAKE_CHAT_STATUS=400) && fail 'a failed probe was accepted'
grep -q honcho-key-A "$honcho_cfg" || fail 'a failed run did not put the previous Honcho config back'
out=$(guest HONCHO_URL=http://192.0.2.85:8000 HONCHO_PLUGIN_VERSION=0.2.2) || fail "plugin bump: $out"
[[ $(jq_ "$config" plugins) == '["@honcho-ai/opencode-honcho@0.2.2"]' ]] || fail 'a new plugin release did not replace the old entry'
out=$(guest HONCHO_URL=) || fail "Honcho off: $out"
[[ $(jq_ "$config" plugins) == '[]' && ! -e $honcho_cfg && ! -e $deploy/honcho-api-key ]] || fail 'HONCHO_URL= left the plugin or the key behind'
external_honcho_key=$tmp_root/external-honcho-key
printf 'external-honcho-key\n' > "$external_honcho_key"
out=$(guest HONCHO_URL=http://192.0.2.85:8000 HONCHO_API_KEY_FILE="$external_honcho_key" FAKE_HONCHO_NO_GATEWAY=1) || fail "external Honcho on: $out"
[[ $(jq_ "$honcho_cfg" hosts.opencode.workspace) == osr ]] || fail 'a Honcho without OSR'"'"'s gateway did not get the osr workspace'
out=$(guest HONCHO_URL=http://192.0.2.85:8000 HONCHO_API_KEY_FILE="$external_honcho_key" FAKE_HONCHO_BAD_KEY=external-honcho-key) && fail 'a rejected Honcho key was accepted'
[[ $out == *"rejected this CT's key"* ]] || fail "no rejected-key error: $out"
out=$(guest HONCHO_URL= HONCHO_API_KEY_FILE="$external_honcho_key") || fail "external Honcho off: $out"
[[ $(<"$external_honcho_key") == external-honcho-key ]] || fail 'disabling Honcho deleted a caller-supplied key file'
pass 'Honcho: the pinned plugin with the workspace the gateway names; a failed run restores it; a new release replaces it; HONCHO_URL= removes it'

# 16. Open Terminal: OpenCode's own workspace as MCP server open-terminal.
reset_tree; push_key
ot_key=ot-key-0123456789abcdef
printf '%s\n' "$ot_key" > "$deploy/open-terminal-key"
out=$(guest OPEN_TERMINAL_URL=http://192.0.2.70:8000/) || fail "Open Terminal on: $out"
[[ $(jq_ "$config" mcp.servers.open-terminal) == '{"headers":{"Authorization":"Bearer {env:OSR_OPEN_TERMINAL_KEY}"},"oauth":false,"type":"remote","url":"http://192.0.2.70:8000/mcp"}' ]] ||
  fail "MCP entry: $(jq_ "$config" mcp.servers.open-terminal)"
grep -q "$ot_key" "$config" && fail 'opencode.json holds the Open Terminal key'
[[ $(kv OSR_OPEN_TERMINAL_KEY "$env_file") == "$ot_key" ]] || fail 'the key is not in the server environment'
grep -q -- "$ot_key" "$log" && fail 'the Open Terminal key appeared in a command line'
out=$(guest OPEN_TERMINAL_URL=http://192.0.2.70:8000 FAKE_OT_KEY=another-key-0123456789) && fail 'a rejected key was accepted'
[[ $out == *'rejected this CT'* ]] || fail "rejected key message: $out"
out=$(guest OPEN_TERMINAL_URL=http://192.0.2.70:8000 FAKE_OT_DOWN=1) && fail 'an unreachable terminal was accepted'
[[ $out == *'unreachable from this CT'* ]] || fail "unreachable message: $out"
out=$(guest OPEN_TERMINAL_URL=) || fail "Open Terminal off: $out"
[[ $(jq_ "$config" mcp.servers) == '{}' ]] || fail 'OPEN_TERMINAL_URL= left the MCP server'
grep -q '^OSR_OPEN_TERMINAL_KEY=' "$env_file" && fail 'OPEN_TERMINAL_URL= left the key in the environment'
[[ ! -e $deploy/open-terminal-key ]] || fail 'OPEN_TERMINAL_URL= left the pushed key'
pass 'Open Terminal: MCP server with the key only in the root-only environment, checked from the CT; OPEN_TERMINAL_URL= removes it'

# 17. The chat endpoint for Open WebUI: its own key and account, a root-only
# environment, health-checked; a failure rolls back; off removes it, keeps the key.
reset_tree; push_key
out=$(guest OPENCODE_API=true) || fail "chat endpoint on: $out"
api_env=$etc/api.env
[[ -s $etc/api-key && $(stat -c %a "$etc/api-key") == 600 && $(wc -c < "$etc/api-key") -ge 64 ]] || fail 'the bearer key'
api_key=$(< "$etc/api-key")
[[ $(kv OPENCODE_API_KEY "$api_env") == "$api_key" && $(kv OPENCODE_PASSWORD "$api_env") == "$(< "$etc/password")" &&
   $(kv OPENCODE_PORT "$api_env") == 4096 && $(kv OPENCODE_API_PORT "$api_env") == 4097 &&
   $(kv OPENCODE_API_PERMISSIONS "$api_env") == allow && $(kv OPENCODE_API_MODEL "$api_env") == opencode ]] ||
  fail "chat endpoint environment: $(sed 's/=.*/=.../' "$api_env")"
[[ $(stat -c %a "$api_env") == 600 ]] && grep -q "chown root:root $api_env" "$log" || fail 'the chat endpoint environment is not root-only'
[[ -e $state/user-opencode-api && -e $state/api-active && -f $units/opencode-api.service ]] || fail 'account, unit or start'
cmp -s "$tmp_root/opencode-api.py" "$here/openai-proxy.py" || fail 'the chat endpoint was not installed'
grep -q '^OPENCODE_API=true$' "$etc/settings" && grep -q "^API_KEY_SHA256=$(printf '%s' "$api_key" | sha256sum | cut -d' ' -f1)\$" "$etc/settings" ||
  fail 'the chat endpoint is not recorded'
grep -q -- "$api_key" "$etc/settings" "$config" "$env_file" && fail 'the bearer key is somewhere besides api-key and api.env'
grep '^curl ' "$log" | grep -q -- "$api_key" && fail 'the bearer key was passed to curl in argv'
grep -q '^curl .*http://127.0.0.1:4097/v1/models' "$log" || fail 'the chat endpoint was not health-checked with the key'
[[ $out == *'Chat endpoint: http://<CT IPv4>:4097/v1, model opencode'* ]] || fail "chat endpoint summary: $out"
: > "$log"
out=$(guest OPENCODE_API=true) || fail "chat endpoint rerun: $out"
[[ $out == *'nothing to do'* ]] || fail "an unchanged chat endpoint did work: $out"
rm -f "$state/api-active"
out=$(guest OPENCODE_API=true) || fail "stopped chat endpoint: $out"
[[ $out == *'not running or not healthy'* && -e $state/api-active && $(< "$etc/api-key") == "$api_key" ]] ||
  fail 'a stopped chat endpoint was not started again with the same key'
prev_api_env=$(< "$api_env"); prev_settings=$(< "$etc/settings")
: > "$log"
out=$(guest OPENCODE_API=true OPENCODE_API_PORT=4200 FAKE_API_DOWN=1) && fail 'a chat endpoint that does not answer was accepted'
[[ $out == *'opencode-api.service did not answer /healthz and /v1/models on port 4200'* && $out == *'running again'* ]] ||
  fail "chat endpoint failure: $out"
[[ $(< "$api_env") == "$prev_api_env" && $(< "$etc/settings") == "$prev_settings" ]] || fail 'the chat endpoint failure was not rolled back'
[[ -e $state/api-active && $(grep -c '^systemctl restart opencode-api.service$' "$log") == 2 ]] ||
  fail 'the rollback did not restart the previous chat endpoint (with its restored settings)'
out=$(guest OPENCODE_API=true OPENCODE_API_PORT=4200 OPENCODE_API_PERMISSIONS=reject) || fail "chat endpoint port: $out"
[[ $(kv OPENCODE_API_PORT "$api_env") == 4200 && $(kv OPENCODE_API_PERMISSIONS "$api_env") == reject ]] || fail 'port or permissions not applied'
out=$(guest OPENCODE_API=false) || fail "chat endpoint off: $out"
[[ ! -e $state/api-active && ! -e $units/opencode-api.service && ! -e $api_env && ! -e $tmp_root/opencode-api.py ]] ||
  fail 'OPENCODE_API=false left the chat endpoint behind'
[[ $(< "$etc/api-key") == "$api_key" ]] || fail 'turning the chat endpoint off dropped its key (Open WebUI'"'"'s connection uses it)'
[[ $out == *'chat endpoint is off'* ]] || fail "chat endpoint off message: $out"
out=$(guest OPENCODE_API=false) || fail "chat endpoint off rerun: $out"
[[ $out == *'nothing to do'* ]] || fail 'an unchanged installation without the chat endpoint did work'
out=$(guest OPENCODE_API=true) || fail "chat endpoint on again: $out"
[[ $(kv OPENCODE_API_KEY "$api_env") == "$api_key" ]] || fail 'the chat endpoint came back with another key'
pass 'the chat endpoint: its own key, account and root-only environment, health-checked; rolled back on failure; off removes it but keeps the key'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
