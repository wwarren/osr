#!/usr/bin/env bash
# install-target.sh end to end against a temporary tree: a fake router and
# Honcho MCP server (a local HTTP server), and stubbed apt, npm, systemd and
# runuser. The real configure.mjs runs on the real Node.js; the installed
# "release" is a stub whose bin.js only answers --dump-config. Nothing is
# downloaded or started, and no root is needed: the script's paths point into
# the tree and `id -u` answers 0.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
script=$here/install-target.sh

command -v node >/dev/null || { printf 'skip all cases: node is not installed\n'; exit 0; }
command -v flock >/dev/null || { printf 'skip all cases: flock is not installed\n'; exit 0; }
real_node=$(command -v node)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dsh-install-test.XXXXXX")
server_pid=''
cleanup() {
  [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
  [[ $tmp == "${TMPDIR:-/tmp}"/dsh-install-test.* ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT
bin=$tmp/bin fake=$tmp/fake
mkdir -p "$bin" "$fake"
export FAKE_DIR=$fake FAKE_LOG=$tmp/calls.log

# --- router and Honcho MCP: behaviour read from files in $fake per request ---
cat > "$tmp/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
state = sys.argv[1]
def get(name, default=""):
    try:
        with open(os.path.join(state, name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return default
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def send(self, status, body=None, headers=()):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if self.path == "/osr/v1/whoami":
            # OSR's Honcho gateway names this agent's own workspace.
            if self.headers.get("Authorization") != "Bearer " + get("honcho-key"):
                return self.send(401, {"detail": "Invalid API key"})
            return self.send(200, {"client": "deepseek-harness-281", "user": None,
                                   "workspace": "deepseek-harness-281", "per_user": False})
        if self.headers.get("Authorization") != "Bearer " + get("router-key"):
            return self.send(401, {"error": "bad key"})
        if self.path == "/v1/models":
            return self.send(200, {"data": [{"id": m} for m in ("auto", "code-model", "chat-only")]})
        if self.path == "/routing/inventory":
            return self.send(200, {"models": [
                {"name": "code-model", "tools": True, "context_length": 65536},
                {"name": "chat-only", "tools": False, "context_length": 65536}]})
        self.send(404, {})
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        with open(os.path.join(state, "mcp-requests"), "a") as f:
            f.write(json.dumps({"auth": self.headers.get("Authorization"),
                                "workspace": self.headers.get("X-Honcho-Workspace-ID"),
                                "method": json.loads(body or b"{}").get("method")}) + "\n")
        if self.path != "/mcp":
            return self.send(404, {})
        # The same endpoint plays Honcho's MCP server and the Open Terminal
        # gateway's (each with its own key).
        if self.headers.get("Authorization") not in ("Bearer " + get("honcho-key"), "Bearer " + get("ot-key")):
            return self.send(401, {"error": "bad key"})
        self.send(200, {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-06-18",
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-honcho", "version": "0"}}},
                  headers=[("mcp-session-id", "s1")])
    def do_DELETE(self):
        self.send(200, {})
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(state, "port"), "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
printf 'router-secret' > "$fake/router-key"
printf 'honcho-client-key' > "$fake/honcho-key"
printf 'ot-client-key-0123456789' > "$fake/ot-key"
python3 "$tmp/server.py" "$fake" & server_pid=$!
for _ in $(seq 50); do [[ -s $fake/port ]] && break; sleep 0.1; done
[[ -s $fake/port ]] || { echo 'FAIL the fake server did not start'; exit 1; }
port=$(< "$fake/port")

# --- stubs -----------------------------------------------------------------
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_LOG"\n%s\n' "$1" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub id 'if [[ ${1:-} == -u ]]; then echo 0; fi; exit 0'
for name in apt-get useradd gpg chown; do stub "$name" 'exit 0'; done
stub sleep 'exit 0'
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub journalctl 'echo "fake journal line"'
# systemctl: the unit is active when $FAKE_DIR/active exists. A restart runs
# the release the current link points to; a version listed in $FAKE_DIR/bad
# starts but never answers (inactive).
stub systemctl 'case $1 in
  is-active) [[ -e $FAKE_DIR/active ]] ;;
  restart)
    version=$(basename "$(readlink -f "$DSH_OPT_DIR/current")" | sed "s/_.*//")
    echo "$version" >> "$FAKE_DIR/restarts"
    # A signal test needs this restart to take a moment.
    [[ $version != "$(cat "$FAKE_DIR/slow-restart" 2>/dev/null)" ]] || /bin/sleep 2
    if grep -qx -- "$version" "$FAKE_DIR/bad" 2>/dev/null; then rm -f "$FAKE_DIR/active"; else echo "$version" > "$FAKE_DIR/active"; fi ;;
esac; exit 0'
# curl: only the Web UI health check reaches it; 401 is an answer.
stub curl 'if [[ -e $FAKE_DIR/active ]]; then if [[ -e $FAKE_DIR/http-code ]]; then cat "$FAKE_DIR/http-code"; else printf 401; fi; else printf 000; exit 7; fi'
# npm: view answers $FAKE_DIR/latest; install writes a stub release (unless
# $FAKE_DIR/npm-fail exists) whose bin.js fails --dump-config when
# $FAKE_DIR/dump-fail exists.
stub npm 'echo "npm umask $(umask)" >> "$FAKE_LOG"
case $1 in
  --version) echo 11.16.0 ;;
  view) cat "$FAKE_DIR/latest" ;;
  install)
    [[ ! -e $FAKE_DIR/npm-fail ]] || exit 1
    prefix="" spec=""
    while (( $# )); do case $1 in --prefix) prefix=$2; shift 2 ;; @deepseek-ai/dsh@*) spec=$1; shift ;; *) shift ;; esac; done
    pkg=$prefix/node_modules/@deepseek-ai/dsh
    mkdir -p "$pkg/lib"
    printf "{\"name\":\"@deepseek-ai/dsh\",\"version\":\"%s\"}\n" "${spec##*@}" > "$pkg/package.json"
    printf "%s\n" "const fs = require(\"fs\");" \
      "if (fs.existsSync(process.env.FAKE_DIR + \"/dump-fail\")) { console.error(\"patch rejected\"); process.exit(1); }" \
      "console.log(\"- id: llm-pi-ai\");" > "$pkg/lib/bin.js" ;;
esac'
# node: the real one, except that the version check passes (CI may run 22).
cat > "$bin/node" <<STUB
#!/usr/bin/env bash
if [[ \$1 == -e && \$2 == *process.versions.node* ]]; then exit 0; fi
exec "$real_node" "\$@"
STUB
chmod +x "$bin/node"
export PATH="$bin:$PATH"

# --- the tree --------------------------------------------------------------
export DSH_ETC_DIR=$tmp/etc DSH_OPT_DIR=$tmp/opt DSH_STATE_DIR=$tmp/state
export DSH_ROLLBACK_DIR=$tmp/target/rollback DSH_UNIT_DIR=$tmp/units
mkdir -p "$DSH_UNIT_DIR"
deploy=$tmp/deploy
# push_deploy [HONCHO]: what provision-lxc.sh pushes before each run.
push_deploy() {
  rm -rf -- "$deploy"
  mkdir -p "$deploy"
  cp "$here/install-target.sh" "$here/configure.mjs" "$here/deepseek-harness.service" "$deploy/"
  printf 'router-secret\n' > "$deploy/router-api-key"
  if [[ ${1:-} == honcho ]]; then printf 'honcho-client-key\n' > "$deploy/honcho-api-key"; fi
  if [[ ${1:-} == open-terminal ]]; then printf 'ot-client-key-0123456789\n' > "$deploy/open-terminal-key"; fi
}
base_env=(DSH_ROUTER_URL="http://127.0.0.1:$port" DSH_BIND_IP=127.0.0.1 DSH_MODEL=code-model DSH_CONTEXT_WINDOW=32768)
out=''
# install [ENV...]: one run; output in $out, status returned.
install_run() {
  local status=0
  : > "$FAKE_LOG"
  out=$(env "${base_env[@]}" "$@" bash "$deploy/install-target.sh" 2>&1) || status=$?
  return "$status"
}
# run_fails LABEL [ENV...]: install_run must fail. Not in a subshell (as
# assert_fail is), so the cases after it can read $out.
run_fails() {
  local label=$1
  shift
  if install_run "$@"; then _fail "$label" "non-zero exit" "exit 0"; else _pass "$label"; fi
}
link() { basename "$(readlink -f "$DSH_OPT_DIR/current")"; }
calls() { cat "$FAKE_LOG"; }

describe install_dry_run
plan=$(env "${base_env[@]}" bash "$script" --dry-run 2>&1)
assert_contains "the dry run names the pinned release" "@deepseek-ai/dsh@0.2.1-rc.5" "$plan"
assert_contains "and says Honcho is off" "no Honcho memory" "$plan"
plan=$(env "${base_env[@]}" DSH_HONCHO_MCP_URL=http://192.0.2.85:3000/mcp bash "$script" --dry-run 2>&1)
assert_contains "Honcho is planned with its workspace and peers" "its own workspace, peers user and deepseek-harness" "$plan"
assert_fail "Honcho needs a 32k window" env "${base_env[@]}" DSH_CONTEXT_WINDOW=16384 DSH_HONCHO_MCP_URL=http://192.0.2.85:3000/mcp bash "$script" --dry-run
assert_fail "a Honcho URL with a query is refused" env "${base_env[@]}" DSH_HONCHO_MCP_URL='http://h:3000/mcp?x=1' bash "$script" --dry-run
assert_fail "a router URL with a path is refused" env "${base_env[@]}" DSH_ROUTER_URL=http://127.0.0.1:8000/v1 bash "$script" --dry-run

describe install_fresh
push_deploy
assert_ok "a first install succeeds" install_run
printf '%s\n' "$out" | tail -n 3
assert_eq "the current link points at a release of the pinned version" 0.2.1-rc.5 "$(link | sed 's/_.*//')"
assert_file_contains "the overlay names the OSR provider" 'baseURL: "http://127.0.0.1:'"$port"'/v1"' "$DSH_ETC_DIR/osr.patch.yml"
assert_file_contains "and the model" 'model: "code-model"' "$DSH_ETC_DIR/osr.patch.yml"
assert_ok "the overlay never holds the key" bash -c "! grep -q router-secret '$DSH_ETC_DIR/osr.patch.yml'"
assert_file_contains "the service gets the key from its env file" 'OSR_API_KEY=router-secret' "$DSH_ETC_DIR/service.env"
assert_file_mode "which is root-only" 600 "$DSH_ETC_DIR/service.env"
assert_ok "no Honcho key without Honcho" bash -c "! grep -q HONCHO_API_KEY '$DSH_ETC_DIR/service.env'"
assert_file_contains "the unit runs the current release" '/opt/deepseek-harness/current/node_modules/@deepseek-ai/dsh/lib/bin.js' "$DSH_UNIT_DIR/deepseek-harness.service"
assert_file_contains "a settings record is written" 'DSH_VERSION=0.2.1-rc.5' "$DSH_ETC_DIR/settings"
assert_file_contains "with the model a reconfigure keeps" 'DSH_MODEL=code-model' "$DSH_ETC_DIR/settings"
assert_ok "the record holds a key hash, not the key" bash -c "! grep -q router-secret '$DSH_ETC_DIR/settings'"
assert_contains "the service was restarted" "systemctl restart deepseek-harness.service" "$(calls)"
assert_ok "the pushed keys are removed from the deploy directory" test ! -e "$deploy/router-api-key"
assert_ok "and the router key is kept in /etc" test -s "$DSH_ETC_DIR/router-api-key"
assert_ok "no snapshot is left" test ! -e "$DSH_ROLLBACK_DIR"
# The release belongs to root after install; the service reads it as "other".
pkg=$(readlink -f "$DSH_OPT_DIR/current")/node_modules/@deepseek-ai/dsh
assert_eq "the release's code is readable by the service user" 644 "$(stat -c %a "$pkg/lib/bin.js")"
assert_eq "and its directories can be entered" 755 "$(stat -c %a "$pkg/lib")"
assert_contains "npm runs under umask 022" "npm umask 0022" "$(calls)"
first_release=$(link)

describe install_unchanged
push_deploy
assert_ok "a rerun with the same settings succeeds" install_run
assert_contains "and says there is nothing to do" "nothing to do" "$out"
assert_not_contains "without npm" "npm install" "$(calls)"
assert_not_contains "or a restart" "systemctl restart" "$(calls)"

describe install_reconfigure
push_deploy
assert_ok "a model change succeeds" install_run DSH_MODEL=auto
assert_contains "and keeps the installed release" "Keeping the installed @deepseek-ai/dsh@0.2.1-rc.5" "$out"
assert_eq "the same release still runs" "$first_release" "$(link)"
assert_file_contains "the overlay has the new model" 'model: "auto"' "$DSH_ETC_DIR/osr.patch.yml"
assert_contains "an alias is flagged for checking" "Selected OSR alias" "$out"
chmod -R go-rwx "$(readlink -f "$DSH_OPT_DIR/current")"
push_deploy
assert_ok "a reconfigure over an owner-only release (an earlier run's) succeeds" install_run DSH_MODEL=code-model
assert_eq "and makes it readable again" 644 "$(stat -c %a "$(readlink -f "$DSH_OPT_DIR/current")/node_modules/@deepseek-ai/dsh/lib/bin.js")"
push_deploy
assert_ok "back to the alias" install_run DSH_MODEL=auto
push_deploy
run_fails "a model the router does not advertise is refused" DSH_MODEL=missing-model
assert_contains "before anything is restarted" "DeepSeek Harness was not stopped or changed" "$out"
assert_file_contains "the previous overlay is back" 'model: "auto"' "$DSH_ETC_DIR/osr.patch.yml"
assert_not_contains "and the service was left alone" "systemctl restart" "$(calls)"
push_deploy
run_fails "a model reported without tools is refused" DSH_MODEL=chat-only
push_deploy
printf 'wrong\n' > "$deploy/router-api-key"
run_fails "a wrong router key is refused"
assert_contains "by the router" "HTTP 401" "$out"
assert_file_contains "and the working key stays installed" 'OSR_API_KEY=router-secret' "$DSH_ETC_DIR/service.env"

describe install_upgrade_rollback
push_deploy
echo 0.2.2 > "$fake/bad"
run_fails "an upgrade to a release that never answers fails" DSH_VERSION=0.2.2
assert_contains "and rolls back" "Rolling back to 0.2.1-rc.5" "$out"
assert_contains "to the previous release, running again" "DeepSeek Harness 0.2.1-rc.5 is running again" "$out"
assert_eq "the current link is back" "$first_release" "$(link)"
assert_eq "the failed release is removed" 1 "$(find "$DSH_OPT_DIR/releases" -mindepth 1 -maxdepth 1 | wc -l)"
assert_file_contains "the settings record is the old one" 'DSH_VERSION=0.2.1-rc.5' "$DSH_ETC_DIR/settings"
assert_ok "and the snapshot is cleared" test ! -e "$DSH_ROLLBACK_DIR"
assert_eq "the service runs the old release" 0.2.1-rc.5 "$(cat "$fake/active")"

describe install_signal_rollback
# A signal while the new release restarts (Ctrl-C, a closed SSH session, kill)
# rolls back like a failure. At that moment $? is 0: without the signal traps
# bash would run the EXIT trap with status 0 and keep the new release. perl
# restores SIGINT, which a background job otherwise starts with ignored.
for signal in TERM INT HUP; do
  push_deploy
  echo 0.2.2 > "$fake/slow-restart"; : > "$fake/restarts"; : > "$FAKE_LOG"
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' -- \
    env "${base_env[@]}" DSH_VERSION=0.2.2 OSR_INTERRUPT_LOG="$fake/interrupt.log" \
    bash "$deploy/install-target.sh" > "$fake/signal-out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do grep -qx 0.2.2 "$fake/restarts" && break; /bin/sleep 0.1; done
  kill -"$signal" "$pid"
  status=0; wait "$pid" || status=$?
  rm -f -- "$fake/slow-restart"
  out=$(cat "$fake/signal-out" "$fake/interrupt.log" 2>/dev/null || true)
  assert_ok "SIG$signal during the restart fails the run" test "$status" -ne 0
  assert_contains "and rolls back" "Rolling back to 0.2.1-rc.5" "$out"
  assert_contains "to the previous release, running again" "DeepSeek Harness 0.2.1-rc.5 is running again" "$out"
  assert_eq "the current link is back" "$first_release" "$(link)"
  assert_ok "the snapshot is cleared" test ! -e "$DSH_ROLLBACK_DIR"
  if [[ $signal == HUP ]]; then
    assert_file_contains "after a hangup the rollback reports to OSR_INTERRUPT_LOG" 'Rolling back' "$fake/interrupt.log"
  fi
  rm -f -- "$fake/interrupt.log"
done

describe install_rollback_fails
push_deploy
printf '0.2.2\n0.2.1-rc.5\n' > "$fake/bad"
run_fails "when the previous release does not come back either" DSH_VERSION=0.2.2
assert_contains "the run says the rollback failed too" "did not become healthy either" "$out"
assert_ok "and keeps the snapshot" test -d "$DSH_ROLLBACK_DIR"
push_deploy
rm -f "$fake/bad"
run_fails "the next run refuses to overwrite it" DSH_VERSION=0.2.2
assert_contains "and points at it" "A snapshot from a failed rollback is kept in" "$out"
assert_ok "the refused run still removes the pushed keys" test ! -e "$deploy/router-api-key"
printf '0.2.1-rc.5\n' > "$fake/active"
push_deploy
# The same settings as the recorded run, so the unchanged shortcut would apply.
run_fails "a recovered service cannot hide the failed rollback snapshot" DSH_VERSION=0.2.1-rc.5 DSH_MODEL=auto
assert_contains "the snapshot still takes precedence over an unchanged run" "A snapshot from a failed rollback is kept in" "$out"
rm -rf -- "$DSH_ROLLBACK_DIR"
systemctl restart >/dev/null

describe install_health_check
# shellcheck disable=SC1090
source <(awk '/^# Install helpers$/{c=1;next} /^# End install helpers\.$/{c=0} c' "$script")
# shellcheck disable=SC2034  # read by the sourced healthy()
BIND_IP=127.0.0.1 PORT=3080
printf '500\n' > "$fake/http-code"
assert_fail "HTTP 500 is not healthy" healthy
printf '404\n' > "$fake/http-code"
assert_fail "HTTP 404 is not the DeepSeek login response" healthy
printf '401\n' > "$fake/http-code"
assert_ok "the unauthenticated DeepSeek response is healthy" healthy
rm -f -- "$fake/http-code"

describe install_nodesource_repo
# The keyring and source list must be readable by apt's _apt user although the
# installer runs under umask 077 (Debian 13: "Failed to parse keyring ...
# Permission denied", then "The repository ... is not signed").
ns=$(mktemp -d)
mkdir -p "$ns/bin"
printf '#!/bin/sh\nprintf "armored key\\n"\n' > "$ns/bin/curl"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\ncat > "$out"\n' > "$ns/bin/gpg"
chmod +x "$ns/bin/curl" "$ns/bin/gpg"
(umask 077; PATH="$ns/bin:$PATH" nodesource_repo "$ns/keyrings/nodesource.gpg" "$ns/sources/nodesource.list")
assert_eq "under umask 077 the keyring is world-readable" 644 "$(stat -c %a "$ns/keyrings/nodesource.gpg")"
assert_eq "and so is the source list" 644 "$(stat -c %a "$ns/sources/nodesource.list")"
assert_eq "with the key" 'armored key' "$(cat "$ns/keyrings/nodesource.gpg")"
assert_eq "and the repository signed by it" "deb [signed-by=$ns/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" "$(cat "$ns/sources/nodesource.list")"
chmod 0600 "$ns/keyrings/nodesource.gpg" "$ns/sources/nodesource.list"
(umask 077; PATH="$ns/bin:$PATH" nodesource_repo "$ns/keyrings/nodesource.gpg" "$ns/sources/nodesource.list")
assert_eq "a root-only keyring from an earlier run is repaired" 644 "$(stat -c %a "$ns/keyrings/nodesource.gpg")"
chmod 0600 "$ns/keyrings/nodesource.gpg" "$ns/sources/nodesource.list"
nodesource_readable "$ns/keyrings/nodesource.gpg" "$ns/sources/nodesource.list" "$ns/keyrings/missing.gpg"
assert_eq "before apt runs, a root-only keyring left behind is made readable" 644 "$(stat -c %a "$ns/keyrings/nodesource.gpg")"
assert_eq "and its source list" 644 "$(stat -c %a "$ns/sources/nodesource.list")"
assert_ok "a missing one is no error" test ! -e "$ns/keyrings/missing.gpg"
assert_ok "the installer does that before its first apt-get update" \
  awk '/^nodesource_readable \/usr\/share\/keyrings\/nodesource.gpg/{r=NR} /^  apt-get update$/ && !u{u=NR} END{exit !(r && u && r < u)}' "$script"
printf '#!/bin/sh\nexit 22\n' > "$ns/bin/curl"
assert_fail "a failed key download fails" env PATH="$ns/bin:$PATH" bash -c "$(declare -f nodesource_repo); set -Eeuo pipefail; nodesource_repo '$ns/k2/nodesource.gpg' '$ns/s2/nodesource.list'"
rm -rf -- "$ns"

describe install_npm_failure
push_deploy
touch "$fake/npm-fail"
run_fails "an npm failure stops the run" DSH_VERSION=0.2.3
assert_contains "before anything changes" "DeepSeek Harness was not stopped or changed" "$out"
assert_eq "the release is unchanged" "$first_release" "$(link)"
assert_not_contains "and nothing restarted" "systemctl restart" "$(calls)"
rm -f "$fake/npm-fail"

describe install_dump_failure
push_deploy
touch "$fake/dump-fail"
run_fails "a patch DeepSeek rejects stops the run" DSH_VERSION=0.2.3
assert_contains "the previous configuration is restored without a restart" "The previous configuration is back" "$out"
assert_eq "on the previous release" "$first_release" "$(link)"
rm -f "$fake/dump-fail"

describe install_latest
push_deploy
echo 0.2.4 > "$fake/latest"
assert_ok "latest resolves to an exact release" install_run DSH_VERSION=latest
assert_contains "and says which" "@deepseek-ai/dsh@latest is 0.2.4" "$out"
assert_file_contains "the record holds the exact version" 'DSH_VERSION=0.2.4' "$DSH_ETC_DIR/settings"
assert_eq "only the running release is kept" 1 "$(find "$DSH_OPT_DIR/releases" -mindepth 1 -maxdepth 1 | wc -l)"
push_deploy
assert_ok "an unchanged latest" install_run DSH_VERSION=latest
assert_contains "does nothing" "nothing to do" "$out"

describe install_honcho
push_deploy honcho
mkdir -p "$DSH_STATE_DIR/home"
printf '# My own notes\n\nKeep answers short.\n' > "$DSH_STATE_DIR/home/AGENTS.md"
rm -f "$fake/mcp-requests"
honcho_env=(DSH_VERSION=0.2.4 DSH_HONCHO_MCP_URL="http://127.0.0.1:$port/mcp")
assert_ok "Honcho memory can be turned on" install_run "${honcho_env[@]}"
assert_file_contains "the overlay adds the Honcho MCP server" 'serverName: honcho' "$DSH_ETC_DIR/osr.patch.yml"
assert_file_contains "with its URL" "url: \"http://127.0.0.1:$port/mcp\"" "$DSH_ETC_DIR/osr.patch.yml"
assert_file_contains "the key comes from the environment" 'Authorization: !!js '"'"'`Bearer ${process.env.HONCHO_API_KEY}`'"'" "$DSH_ETC_DIR/osr.patch.yml"
assert_file_contains "and the workspace Honcho names for its key, its own" 'X-Honcho-Workspace-ID: "deepseek-harness-281"' "$DSH_ETC_DIR/osr.patch.yml"
assert_ok "the overlay never holds the Honcho key" bash -c "! grep -q honcho-client-key '$DSH_ETC_DIR/osr.patch.yml'"
assert_file_contains "the service gets the Honcho key" 'HONCHO_API_KEY=honcho-client-key' "$DSH_ETC_DIR/service.env"
assert_contains "the key was checked with an MCP initialize" '"auth": "Bearer honcho-client-key", "workspace": "deepseek-harness-281", "method": "initialize"' "$(cat "$fake/mcp-requests")"
agents=$(cat "$DSH_STATE_DIR/home/AGENTS.md")
assert_contains "the instructions name the user peer" 'peer `user`' "$agents"
assert_contains "and its own workspace" 'Workspace: `deepseek-harness-281`' "$agents"
assert_contains "and this agent's peer" 'you are peer `deepseek-harness`' "$agents"
assert_contains "the user's own instructions are kept" "Keep answers short." "$agents"
push_deploy honcho
assert_ok "a rerun keeps one managed block" install_run "${honcho_env[@]}"
assert_eq "exactly one" 1 "$(grep -c 'osr-honcho:begin' "$DSH_STATE_DIR/home/AGENTS.md")"
push_deploy
printf 'wrong-key\n' > "$deploy/honcho-api-key"
run_fails "a key Honcho rejects stops the run" "${honcho_env[@]}" DSH_MODEL=auto
assert_contains "and says so" "Honcho rejected the key" "$out"
assert_file_contains "the previous Honcho key is back" 'HONCHO_API_KEY=honcho-client-key' "$DSH_ETC_DIR/service.env"
push_deploy
assert_ok "a reconfigure without a new key reuses the installed one" install_run "${honcho_env[@]}" DSH_MODEL=auto
push_deploy
assert_ok "Honcho can be turned off" install_run DSH_VERSION=0.2.4 DSH_MODEL=auto
assert_ok "the Honcho server is gone from the overlay" bash -c "! grep -q memory-honcho '$DSH_ETC_DIR/osr.patch.yml'"
assert_ok "the key from the service env" bash -c "! grep -q HONCHO_API_KEY '$DSH_ETC_DIR/service.env'"
assert_ok "and from /etc" test ! -e "$DSH_ETC_DIR/honcho-api-key"
agents=$(cat "$DSH_STATE_DIR/home/AGENTS.md")
assert_not_contains "the managed block is removed" "osr-honcho" "$agents"
assert_contains "and the user's text stays" "Keep answers short." "$agents"

describe install_open_terminal
push_deploy open-terminal
rm -f "$fake/mcp-requests"
ot_env=(DSH_VERSION=0.2.4 DSH_MODEL=auto DSH_OPEN_TERMINAL_URL="http://127.0.0.1:$port/")
assert_ok "the Open Terminal workspace can be connected" install_run "${ot_env[@]}"
assert_file_contains "the overlay adds the Open Terminal MCP server" 'serverName: open_terminal' "$DSH_ETC_DIR/osr.patch.yml"
assert_file_contains "at the gateway's /mcp" "url: \"http://127.0.0.1:$port/mcp\"" "$DSH_ETC_DIR/osr.patch.yml"
assert_file_contains "keyed from the environment" 'Authorization: !!js '"'"'`Bearer ${process.env.OSR_OPEN_TERMINAL_KEY}`'"'" "$DSH_ETC_DIR/osr.patch.yml"
assert_ok "the overlay never holds the key" bash -c "! grep -q ot-client-key '$DSH_ETC_DIR/osr.patch.yml'"
assert_file_contains "the service gets the key" 'OSR_OPEN_TERMINAL_KEY=ot-client-key-0123456789' "$DSH_ETC_DIR/service.env"
assert_file_mode "the installed key is root-only" 600 "$DSH_ETC_DIR/open-terminal-key"
assert_contains "the key was checked with an MCP initialize" '"auth": "Bearer ot-client-key-0123456789", "workspace": null, "method": "initialize"' "$(cat "$fake/mcp-requests")"
assert_file_contains "the record has the gateway" "DSH_OPEN_TERMINAL_URL=http://127.0.0.1:$port" "$DSH_ETC_DIR/settings"
assert_ok "and not the key" bash -c "! grep -q ot-client-key '$DSH_ETC_DIR/settings'"
assert_ok "the pushed key is consumed" test ! -e "$deploy/open-terminal-key"
push_deploy
assert_ok "a rerun reuses the installed key" install_run "${ot_env[@]}"
assert_contains "and changes nothing" "nothing to do" "$out"
push_deploy
printf 'wrong-key-0123456789abc\n' > "$deploy/open-terminal-key"
run_fails "a key the terminal rejects stops the run" "${ot_env[@]}" DSH_MAX_TOKENS=4096
assert_contains "and says so" "rejected this CT's key" "$out"
assert_file_contains "the previous key is back" 'OSR_OPEN_TERMINAL_KEY=ot-client-key-0123456789' "$DSH_ETC_DIR/service.env"
push_deploy
assert_ok "the workspace can be disconnected" install_run DSH_VERSION=0.2.4 DSH_MODEL=auto
assert_ok "the MCP server is gone from the overlay" bash -c "! grep -q open_terminal '$DSH_ETC_DIR/osr.patch.yml'"
assert_ok "the key from the service env" bash -c "! grep -q OSR_OPEN_TERMINAL_KEY '$DSH_ETC_DIR/service.env'"
assert_ok "and from /etc" test ! -e "$DSH_ETC_DIR/open-terminal-key"
assert_status "a URL with a path is refused" 1 env "${base_env[@]}" DSH_OPEN_TERMINAL_URL="http://127.0.0.1:$port/mcp" bash "$deploy/install-target.sh" --dry-run

describe install_first_layout
# The first version of this target installed into /opt/deepseek-harness
# directly and wrote no settings record; an upgrade moves it to releases/.
rm -rf -- "$DSH_OPT_DIR" "$DSH_ETC_DIR/settings"
mkdir -p "$DSH_OPT_DIR/node_modules/@deepseek-ai/dsh/lib"
printf '{"version":"0.2.1-rc.4"}\n' > "$DSH_OPT_DIR/node_modules/@deepseek-ai/dsh/package.json"
: > "$DSH_OPT_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"
: > "$DSH_OPT_DIR/package.json"
push_deploy
assert_ok "an install over the first layout succeeds" install_run
assert_eq "it runs a release" 0.2.1-rc.5 "$(link | sed 's/_.*//')"
assert_ok "and the old layout is removed" test ! -e "$DSH_OPT_DIR/node_modules"

summary
