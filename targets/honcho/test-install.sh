#!/usr/bin/env bash
# install-target.sh end to end against a temporary tree: a fake router (a local
# HTTP server) and stubbed apt, systemd, PostgreSQL, git, uv and Bun. Nothing is
# downloaded, installed or started, and no root is needed: the script's paths
# are pointed into the tree and `id -u` answers 0.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
script=$here/install-target.sh

tmp=$(mktemp -d "${TMPDIR:-/tmp}/honcho-install-test.XXXXXX")
server_pid=''
cleanup() {
  [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
  [[ $tmp == "${TMPDIR:-/tmp}"/honcho-install-test.* ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT
bin=$tmp/bin fake=$tmp/fake
mkdir -p "$bin" "$fake"
export FAKE_DIR=$fake FAKE_LOG=$tmp/calls.log

# --- router inventory and a distinct /direct model-target path --------------
# Behaviour is read from files in $fake per request, so cases change it freely.
cat > "$tmp/router.py" <<'PY'
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
    def send(self, status, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def authorized(self):
        return self.headers.get("Authorization") == "Bearer " + get("router-key")
    def do_GET(self):
        if not self.authorized():
            return self.send(401, {"error": {"message": "bad key"}})
        if self.path == "/v1/models":
            return self.send(200, {"data": [{"id": m} for m in get("models", "auto,fast").split(",")]})
        if self.path == "/routing/inventory":
            server = "http://127.0.0.1:%s/direct" % self.server.server_port
            return self.send(200, {"enabled": True, "servers": [server],
                                   "server_status": {server: {"up": True}},
                                   "models": [
                                       {"server": server, "name": "fast-model", "tools": not bool(get("chat-warning")),
                                        "context_length": 131072, "loaded": True, "is_embedding": False},
                                       {"server": server, "name": "nomic-embed-text", "loaded": True,
                                        "is_embedding": True}]})
        self.send(404, {})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/routing/explain":
            if not self.authorized():
                return self.send(401, {"error": {"message": "bad key"}})
            server = "http://127.0.0.1:%s/direct" % self.server.server_port
            return self.send(200, {"candidates": [{"server": server, "model": "fast-model"}]})
        if self.path == "/direct/v1/chat/completions":
            if body.get("tools"):
                with open(os.path.join(state, "tool-probe.json"), "w") as f:
                    json.dump(body, f)
                return self.send(200, {"choices": [{"message": {"role": "assistant", "content": "",
                    "tool_calls": [{"id": "call-1", "type": "function",
                                    "function": {"name": "noop", "arguments": "{}"}}]}}]})
            with open(os.path.join(state, "probe.json"), "w") as f:
                json.dump(body, f)
            status = int(get("chat-status", "200"))
            if status != 200:
                return self.send(status, {"error": {"message": "response_format json_schema is not supported"}})
            return self.send(200, {"choices": [{"message": {"role": "assistant", "content": '{"ready": true}'}}]})
        if self.path in ("/direct/v1/embeddings", "/v1/embeddings"):
            with open(os.path.join(state, "embedding-auth"), "w") as f:
                f.write(self.headers.get("Authorization", ""))
            return self.send(200, {"data": [{"embedding": [0.0] * int(get("dims", "768"))}]})
        self.send(404, {})
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(state, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
printf 'sk-router-test-key\n' > "$fake/router-key"
python3 "$tmp/router.py" "$fake" & server_pid=$!
for _ in {1..50}; do [[ -s $fake/port ]] && break; sleep 0.1; done
[[ -s $fake/port ]] || { echo 'the fake router did not start' >&2; exit 1; }
router=http://127.0.0.1:$(<"$fake/port")

# --- stubs ------------------------------------------------------------------------
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub id 'case $1 in -u) echo 0 ;; honcho|honcho-proxy|honcho-embedding) [[ -e $FAKE_DIR/user-$1 ]] ;; esac'
stub useradd 'echo "useradd $*" >> "$FAKE_LOG"; touch "$FAKE_DIR/user-${@: -1}"'
stub chown 'echo "chown $*" >> "$FAKE_LOG"'
stub sleep ':'
# The Windows Git Bash runner cannot chmod directories under its temporary
# mount. The fixture needs file copies and directory creation, not ownership.
stub install 'directory=false; mode=""; args=()
while (( $# )); do
  case $1 in
    -o|-g) shift 2 ;;
    -m) mode=$2; shift 2 ;;
    -d) directory=true; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if $directory; then mkdir -p -- "${args[@]}"; exit; fi
dest=${args[${#args[@]}-1]}
if (( ${#args[@]} > 2 )); then mkdir -p -- "$dest"; fi
for (( i=0; i<${#args[@]}-1; i++ )); do
  cp -- "${args[i]}" "$dest" || exit
done
[[ -z $mode ]] || chmod "$mode" -- "$dest" 2>/dev/null || true'
stub apt-get 'echo "apt-get $*" >> "$FAKE_LOG"
[[ -z ${FAKE_NO_PGVECTOR:-} || $* != *pgvector* ]] || exit 100'
stub systemctl 'echo "systemctl $*" >> "$FAKE_LOG"
cmd=$1; shift
for unit in "$@"; do
  case $cmd in
    restart) touch "$FAKE_DIR/active-${unit%.service}" ;;
    stop) rm -f "$FAKE_DIR/active-${unit%.service}" ;;
  esac
done; exit 0'
stub runuser 'echo "runuser $2 ${*:4}" >> "$FAKE_LOG"; exec "${@:4}"'
# PostgreSQL: the database's content is one line in $FAKE_DIR/db-data.
stub psql 'echo "psql $*" >> "$FAKE_LOG"
case $* in
  *server_version_num*) echo 170005 ;;
  *pg_roles*) [[ -e $FAKE_DIR/pg-role ]] && echo 1 ;;
  *"CREATE ROLE"*) touch "$FAKE_DIR/pg-role" ;;
  *pg_encoding_to_char*) if [[ -e $FAKE_DIR/pg-db ]]; then cat "$FAKE_DIR/db-encoding"; fi ;;
  *pg_database*) [[ -e $FAKE_DIR/pg-db ]] && echo 1 ;;
  *alembic_version*) if [[ -e $FAKE_DIR/db-data ]]; then echo t; else echo f; fi ;;
esac; exit 0'
stub createdb 'echo "createdb $*" >> "$FAKE_LOG"; touch "$FAKE_DIR/pg-db"; echo UTF8 > "$FAKE_DIR/db-encoding"'
stub dropdb 'echo "dropdb $*" >> "$FAKE_LOG"; rm -f "$FAKE_DIR/pg-db" "$FAKE_DIR/db-data" "$FAKE_DIR/db-encoding"'
stub pg_dump 'echo "pg_dump $*" >> "$FAKE_LOG"; cat "$FAKE_DIR/db-data"'
stub pg_restore 'echo "pg_restore $*" >> "$FAKE_LOG"; cat > "$FAKE_DIR/db-data"'
# git: the checkout is the commit named in .git/FAKE_HEAD; tags map to commits.
# Like real git as root, a call into the honcho-owned checkout must name it
# safe (-c safe.directory=DIR) or it fails with "dubious ownership". The
# llama.cpp source is root's own, fetched by tag: FETCH_HEAD is the commit
# FAKE_LLAMA_COMMIT names, the pinned one unless a case says otherwise.
stub git 'echo "git $*" >> "$FAKE_LOG"
dir="" safe=""
while [[ $1 == -c || $1 == -C ]]; do
  if [[ $1 == -C ]]; then dir=$2; elif [[ $2 == safe.directory=* ]]; then safe=${2#safe.directory=}; fi
  shift 2
done
if [[ -n $dir && $dir == "$FAKE_OPT" && -e $dir/.git/FAKE_HEAD && $safe != "$dir" ]]; then
  echo "fatal: detected dubious ownership in repository at $dir" >&2; exit 128
fi
if [[ $1 == checkout && ${@: -1} == FETCH_HEAD ]]; then
  printf "%s\n" "${FAKE_LLAMA_COMMIT:-7fe450e19305b828c199d602c23a8337aaa1f03b}" > "$dir/.git/FAKE_HEAD"; exit
fi
case $1 in
  init) mkdir -p "${@: -1}/.git" ;;
  clone) mkdir -p "$3/.git" "$3/mcp" ;;
  fetch) : ;;
  rev-parse)
    if [[ $2 == HEAD ]]; then cat "$dir/.git/FAKE_HEAD"; exit; fi
    ref=${3%^\{commit\}}
    case $ref in
      v3.5.0) printf "a%.0s" {1..40} ;; v3.6.0) printf "b%.0s" {1..40} ;; v3.7.0) printf "d%.0s" {1..40} ;;
      origin/main) printf "c%.0s" {1..40} ;;
      *) [[ $ref =~ ^[0-9a-f]{40}$ ]] || exit 128; printf %s "$ref" ;;
    esac; echo ;;
  checkout) printf "%s\n" "$3" > "$dir/.git/FAKE_HEAD" ;;
esac'
# cmake: configuring is logged; building leaves a llama-server that answers --version.
stub cmake 'echo "cmake $*" >> "$FAKE_LOG"
if [[ $1 == --build ]]; then
  mkdir -p "$2/bin"
  printf "#!/usr/bin/env bash\necho \"version: fake llama\"\n" > "$2/bin/llama-server"
  chmod +x "$2/bin/llama-server"
fi'
# curl: the health checks (healthy unless the checkout is FAKE_UNHEALTHY_COMMIT),
# the local embedding model (its health and one vector of FAKE_DIR/embed-dims
# values, 1024 unless a case says otherwise), and the Bun and model downloads.
stub curl 'echo "curl $*" >> "$FAKE_LOG"
out=""; url=""
while (( $# )); do case $1 in -o) out=$2; shift 2 ;; http*) url=$1; shift ;; *) shift ;; esac; done
case $url in
  http://127.0.0.1:8766/health)
    [[ -e $FAKE_DIR/active-honcho-embedding ]] || exit 7 ;;
  http://127.0.0.1:8766/v1/embeddings)
    [[ -e $FAKE_DIR/active-honcho-embedding ]] || exit 7
    python3 -c "import json, sys; print(json.dumps({\"data\": [{\"embedding\": [0.0] * int(sys.argv[1])}]}))" \
      "$(cat "$FAKE_DIR/embed-dims" 2>/dev/null || echo 1024)" ;;
  https://models.test/*) echo "download $url" >> "$FAKE_LOG"; cp "$FAKE_DIR/model.gguf" "$out" ;;
  http://127.0.0.1:8765/healthz)
    [[ -e $FAKE_DIR/active-honcho-proxy ]] || exit 7 ;;
  http://127.0.0.1:8000/health|http://127.0.0.1:3000/health)
    [[ -e $FAKE_DIR/active-honcho-api && -e $FAKE_DIR/active-honcho-mcp ]] || exit 7
    [[ $(cat "$FAKE_OPT/.git/FAKE_HEAD") != "${FAKE_UNHEALTHY_COMMIT:-none}" ]] || exit 22 ;;
  https://github.com/oven-sh/bun/*) cp "$FAKE_BUN_ZIP" "$out" ;;
  *) exit 6 ;;
esac'

# uv and Bun live where the script expects them, so it does not install them.
make_uv() {
  mkdir -p "$tmp/uv/bin"
  cat > "$tmp/uv/bin/uv" <<'UV'
#!/usr/bin/env bash
[[ $1 == --directory ]] && shift 2
head=$(cat "$FAKE_OPT/.git/FAKE_HEAD")
case $1 in
  sync) echo "uv sync $head" >> "$FAKE_LOG"; exit 0 ;;
  run) shift ;;
esac
env_file=''
while [[ $1 == --* ]]; do [[ $1 == --env-file ]] && { env_file=$2; shift; }; shift; done
case $* in
  'alembic upgrade head')
    echo "alembic dims=${EMBEDDING_VECTOR_DIMENSIONS:-from-env-file} $head" >> "$FAKE_LOG"
    echo "half-migrated $head" > "$FAKE_DIR/db-data"
    # A signal test interrupts this migration halfway.
    if [[ $head == "${FAKE_SLOW_MIGRATE_COMMIT:-none}" ]]; then : > "$FAKE_DIR/migrating"; /bin/sleep 10; fi
    [[ $head != "${FAKE_MIGRATE_FAIL_COMMIT:-none}" ]] || exit 1
    echo "migrated $head" > "$FAKE_DIR/db-data" ;;
  'python scripts/configure_embeddings.py --yes') echo 'configure_embeddings' >> "$FAKE_LOG" ;;
  python\ scripts/generate_jwt.py*)
    secret=$(sed -n 's/^AUTH_JWT_SECRET=//p' "$env_file")
    shift 2; echo "generate_jwt $*" >> "$FAKE_LOG"
    echo "jwt-${secret:0:8}-${*// /_}" ;;
  *) echo "unexpected uv run: $*" >&2; exit 3 ;;
esac
UV
  chmod +x "$tmp/uv/bin/uv"
}
make_bun() {
  mkdir -p "$tmp/bun"
  printf '#!/usr/bin/env bash\n[[ $1 == --version ]] && { echo %s; exit; }\n[[ $1 == install && $2 == --frozen-lockfile && $PWD == "$FAKE_OPT/mcp" ]] || { echo "unexpected Bun command: $* in $PWD" >&2; exit 3; }\necho "bun $* cwd=$PWD" >> "$FAKE_LOG"\n' "${1:-1.4.4}" > "$tmp/bun/bun"
  chmod +x "$tmp/bun/bun"
}

# fresh: an empty CT. guest VAR=...: one run of the script; its output is $out.
printf 'GGUF fake Qwen3-Embedding\n' > "$fake/model.gguf"
model_sha=$(sha256sum "$fake/model.gguf" | cut -d' ' -f1)
fresh() {
  rm -rf -- "$tmp/ct" "$tmp/uv" "$tmp/bun" "$fake"/active-* "$fake"/failed-* "$fake"/pg-* "$fake/db-data" "$fake/db-encoding" "$fake"/user-honcho* "$fake/probe.json" "$fake/tool-probe.json"
  rm -f "$fake/chat-status" "$fake/chat-warning" "$fake/embed-dims"
  mkdir -p "$tmp/ct/deploy" "$tmp/ct/units"
  cp "$here"/honcho-*.service "$here/budgets.py" "$here/honcho-proxy.py" "$here/direct_dispatch.py" "$tmp/ct/deploy/"
  cp "$fake/router-key" "$tmp/ct/deploy/router-api-key"
  : > "$tmp/ct/deploy/backend-keys"
  printf 'flags : fpu sse2 avx avx2\n' > "$tmp/ct/cpuinfo"
  make_uv; make_bun
  : > "$FAKE_LOG"
}
guest_prefix=() guest_exec=''
guest() {
  : > "$FAKE_LOG"
  ${guest_exec:+exec} "${guest_prefix[@]}" env PATH="$bin:$PATH" FAKE_OPT="$tmp/ct/opt" \
    HONCHO_DEPLOY_DIR="$tmp/ct/deploy" HONCHO_OPT="$tmp/ct/opt" HONCHO_ETC="$tmp/ct/etc" \
    HONCHO_STATE_DIR="$tmp/ct/state" HONCHO_HOME="$tmp/ct/home" HONCHO_UV_DIR="$tmp/uv" \
    HONCHO_BUN_DIR="$tmp/bun" HONCHO_UNIT_DIR="$tmp/ct/units" HONCHO_CPUINFO="$tmp/ct/cpuinfo" \
    HONCHO_PROXY_LIB_DIR="$tmp/ct/lib" HONCHO_LLAMA_DIR="$tmp/ct/llama" \
    HONCHO_EMBEDDING_DIR="$tmp/ct/embedding" HONCHO_EMBEDDING_FILE_URL=https://models.test/model.gguf \
    HONCHO_EMBEDDING_FILE_SHA256="$model_sha" \
    HONCHO_HEALTH_TRIES=2 ROUTER_URL="$router" \
    "$@" bash "$script" 2>&1
}
calls() { cat "$FAKE_LOG"; }
etc=$tmp/ct/etc
file_mode() {
  case $(uname -s) in
    MINGW*|MSYS*) skip "$1" 'Git Bash temporary files do not preserve Unix modes' ;;
    *) assert_file_mode "$1" "$2" "$3" ;;
  esac
}

describe honcho_required_inputs
out=$(env PATH="$bin:$PATH" NONINTERACTIVE=true env -u ROUTER_URL bash "$script" 2>&1 || true)
assert_contains "an unattended guest needs the router's URL, and no embedding settings" \
  'Set ROUTER_URL' "$out"

describe honcho_database_encoding
fresh
touch "$fake/pg-db"
printf 'SQL_ASCII\n' > "$fake/db-encoding"
out=$(guest) && rc=0 || rc=$?
assert_ne "an existing SQL_ASCII database is refused" 0 "$rc"
assert_contains "with safe recovery guidance" 'Do not drop a database that contains Honcho data' "$out"
assert_not_contains "and is not dropped by the installer" 'dropdb' "$(calls)"

describe honcho_fresh_install
fresh
out=$(guest) && rc=0 || rc=$?
assert_eq "a fresh install succeeds" 0 "$rc"
assert_contains "MCP dependencies install from the mcp package" "bun install --frozen-lockfile cwd=$tmp/ct/opt/mcp" "$(calls)"
assert_contains "the database is created in UTF8 even if template1 is SQL_ASCII" 'createdb -O honcho --encoding=UTF8 --template=template0 honcho' "$(calls)"
assert_eq "and records that encoding" UTF8 "$(<"$fake/db-encoding")"
assert_contains "the connection requests UTF8 text decoding" '?client_encoding=utf8' "$(<"$etc/honcho.env")"
assert_contains "and reports both services healthy" "Honcho API and MCP are healthy." "$out"
assert_contains "the release is checked out" "git -c safe.directory=$tmp/ct/opt -C $tmp/ct/opt checkout --detach $(printf 'a%.0s' {1..40})" "$(calls)"
assert_not_contains "every git call into the checkout names it safe (it belongs to honcho)" "git -C $tmp/ct/opt" "$(calls)"
assert_contains "the probe offered a tool" '"name": "noop"' "$(cat "$fake/tool-probe.json")"
assert_contains "and asked for JSON-schema output" '"type": "json_schema"' "$(cat "$fake/probe.json")"
assert_contains "btree_gin is created with the other extensions" "CREATE EXTENSION IF NOT EXISTS btree_gin" "$(calls)"
assert_contains "the first migration makes the default 1536 columns" "alembic dims=1536" "$(calls)"
assert_contains "then the columns get the model's size" "configure_embeddings" "$(calls)"
assert_contains "an admin key is made" "generate_jwt --admin" "$(calls)"
assert_contains "and a key scoped to the osr workspace" "generate_jwt --workspace osr" "$(calls)"
file_mode "the admin key is root-only" 600 "$etc/api-key"
file_mode "so is the client key" 600 "$etc/client-api-key"
file_mode "the router key is limited to the proxy group" 640 "$etc/router-api-key"
file_mode "the backend keys are limited to the proxy group" 640 "$etc/backend-keys"
assert_contains "llama.cpp is fetched by its release tag" "fetch -q --depth 1 origin refs/tags/v0.5.0" "$(calls)"
assert_contains "and built for the CPU's instruction sets, not natively" "-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_F16C=OFF -DGGML_FMA=OFF -DGGML_AVX2=ON -DGGML_BMI2=OFF" "$(calls)"
assert_contains "without the web UI download" "-DLLAMA_USE_PREBUILT_UI=OFF" "$(calls)"
assert_ok "llama-server is installed" test -x "$tmp/ct/llama/bin/llama-server"
assert_contains "the pinned model file is downloaded" "download https://models.test/model.gguf" "$(calls)"
assert_ok "and kept under its own name" cmp -s "$fake/model.gguf" "$tmp/ct/embedding/Qwen3-Embedding-0.6B-Q8_0.gguf"
file_mode "readable by the embedding service's group only" 640 "$tmp/ct/embedding/Qwen3-Embedding-0.6B-Q8_0.gguf"
assert_ok "the embedding unit is installed" cmp -s "$here/honcho-embedding.service" "$tmp/ct/units/honcho-embedding.service"
assert_contains "with this CT's cores" "HONCHO_EMBEDDING_THREADS=$(nproc)" "$(cat "$etc/embedding.env")"
assert_contains "and its account" "useradd --system --no-create-home --shell /usr/sbin/nologin honcho-embedding" "$(calls)"
assert_contains "it is checked with one embedding before Honcho is set up" "Local embedding model ready: qwen3-embedding-0.6b (1024 dimensions)" "$out"
assert_contains "the env file has its vector size" "EMBEDDING_VECTOR_DIMENSIONS=1024" "$(cat "$etc/honcho.env")"
assert_contains "and its model" "EMBEDDING_MODEL_CONFIG__MODEL=qwen3-embedding-0.6b" "$(cat "$etc/honcho.env")"
assert_contains "at the local server" "EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=http://127.0.0.1:8766/v1" "$(cat "$etc/honcho.env")"
assert_contains "which gets no dimensions= field" "EMBEDDING_MODEL_CONFIG__DIMENSIONS_MODE=never" "$(cat "$etc/honcho.env")"
assert_contains "inputs that fit its 2048-token batch" "EMBEDDING_MAX_INPUT_TOKENS=1536" "$(cat "$etc/honcho.env")"
assert_contains "and CPU-sized requests" "EMBEDDING_MAX_TOKENS_PER_REQUEST=4096" "$(cat "$etc/honcho.env")"
assert_not_contains "nothing is cleared on a first install" "UPDATE documents" "$(calls)"
assert_contains "and the local proxy as the model endpoint" "DERIVER_MODEL_CONFIG__OVERRIDES__BASE_URL=http://127.0.0.1:8765/v1" "$(cat "$etc/honcho.env")"
assert_contains "and allows headroom beyond Kindi's silent read" "DERIVER_MODEL_CONFIG__OVERRIDES__PROVIDER_PARAMS__TIMEOUT=7200" "$(cat "$etc/honcho.env")"
assert_contains "for every dialectic level" "DIALECTIC_LEVELS__max__MODEL_CONFIG__OVERRIDES__PROVIDER_PARAMS__TIMEOUT=7200" "$(cat "$etc/honcho.env")"
assert_not_contains "Honcho does not hold the router address" "$router" "$(cat "$etc/honcho.env")"
assert_not_contains "Honcho does not hold the router key" "sk-router-test-key" "$(cat "$etc/honcho.env")"
assert_not_contains "upstream's structured output by default" "STRUCTURED_OUTPUT_MODE" "$(cat "$etc/honcho.env")"
assert_not_contains "the proxy is no longer told about embeddings" "EMBEDDING" "$(<"$etc/proxy.settings")"
assert_not_contains "nothing is dumped on a first install" "pg_dump" "$(calls)"
assert_ok "the proxy unit is installed" test -f "$tmp/ct/units/honcho-proxy.service"
assert_contains "the proxy pins the resolved model" 'RESOLVED_MODEL=fast-model' "$(<"$etc/proxy.settings")"
assert_fail "and nothing is left set aside" test -e "$tmp/ct/state/rollback"
assert_eq "a first install sizes its budgets for 65536 tokens" "HONCHO_CONTEXT_TOKENS=65536" "$(<"$etc/budgets.env")"
assert_contains "and says so" "Honcho budgets for a 65536-token context" "$out"
assert_contains "the proxy asks for that much context" "HONCHO_CONTEXT_TOKENS=65536" "$(<"$etc/proxy.settings")"
admin_key=$(<"$etc/api-key") client_key=$(<"$etc/client-api-key")

describe honcho_rerun
out=$(guest) && rc=0 || rc=$?
assert_eq "an unchanged rerun succeeds" 0 "$rc"
assert_not_contains "it migrates with the real vector size" "alembic dims=1536" "$(calls)"
assert_contains "taken from the env file" "alembic dims=from-env-file" "$(calls)"
assert_contains "even the same commit gets a rollback dump" "pg_dump -Fc honcho" "$(calls)"
assert_eq "the admin key is kept" "$admin_key" "$(<"$etc/api-key")"
assert_eq "and the client key" "$client_key" "$(<"$etc/client-api-key")"
assert_eq "and the first install's context" "HONCHO_CONTEXT_TOKENS=65536" "$(<"$etc/budgets.env")"
assert_not_contains "llama.cpp is not built again" "cmake -S" "$(calls)"
assert_not_contains "nor the model downloaded again" "download" "$(calls)"
assert_not_contains "and the stored vectors stay" "UPDATE documents" "$(calls)"
out=$(guest HONCHO_EMBEDDING_MODEL=nomic-embed-text) && rc=0 || rc=$?
assert_eq "an old embedding setting does not stop a run" 0 "$rc"
assert_contains "it is named as no longer used" "HONCHO_EMBEDDING_MODEL is no longer used" "$out"

describe honcho_embedding_switch
# A CT installed before the local model embedded with another one.
sed -i -e 's/^EMBEDDING_MODEL_CONFIG__MODEL=.*/EMBEDDING_MODEL_CONFIG__MODEL=nomic-embed-text/' \
  -e 's/^EMBEDDING_VECTOR_DIMENSIONS=.*/EMBEDDING_VECTOR_DIMENSIONS=768/' "$etc/honcho.env"
rm -f "$tmp/ct/units/honcho-embedding.service"
before_env=$(<"$etc/honcho.env") before_db=$(<"$fake/db-data")
out=$(guest) && rc=0 || rc=$?
assert_ne "a model switch on an existing CT is refused" 0 "$rc"
assert_contains "with migration guidance" "Cannot change Honcho embeddings from nomic-embed-text to qwen3-embedding-0.6b" "$out"
assert_not_contains "before a database dump" "pg_dump" "$(calls)"
assert_not_contains "or vector deletion" "DELETE FROM message_embeddings" "$(calls)"
assert_eq "the old environment is kept" "$before_env" "$(<"$etc/honcho.env")"
assert_eq "and the database is kept" "$before_db" "$(<"$fake/db-data")"
assert_ok "with the old API still running" test -e "$fake/active-honcho-api"
assert_fail "and no rollback directory" test -e "$tmp/ct/state/rollback"
sed -i -e 's/^EMBEDDING_MODEL_CONFIG__MODEL=.*/EMBEDDING_MODEL_CONFIG__MODEL=qwen3-embedding-0.6b/' \
  -e 's/^EMBEDDING_VECTOR_DIMENSIONS=.*/EMBEDDING_VECTOR_DIMENSIONS=1024/' "$etc/honcho.env"
out=$(guest) && rc=0 || rc=$?
assert_eq "the same-model rerun still works" 0 "$rc"

describe honcho_same_commit_rollback
before_env=$(<"$etc/honcho.env") before_db=$(<"$fake/db-data")
before_proxy=$(<"$etc/proxy.settings")
printf '# prior proxy revision\n' >> "$tmp/ct/lib/honcho-proxy.py"
before_proxy_code=$(<"$tmp/ct/lib/honcho-proxy.py")
out=$(guest HONCHO_CONTEXT_TOKENS=32768 FAKE_MIGRATE_FAIL_COMMIT="$(printf 'a%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a failed same-commit migration fails the run" 0 "$rc"
assert_contains "rollback also recreates the database in UTF8" 'createdb -O honcho --encoding=UTF8 --template=template0 honcho' "$(calls)"
assert_contains "its database is restored from the dump" "pg_restore --exit-on-error -d honcho" "$(calls)"
assert_eq "including the prior data" "$before_db" "$(<"$fake/db-data")"
assert_eq "and its env file" "$before_env" "$(<"$etc/honcho.env")"
assert_eq "and its prior proxy settings" "$before_proxy" "$(<"$etc/proxy.settings")"
assert_eq "and its prior proxy implementation" "$before_proxy_code" "$(<"$tmp/ct/lib/honcho-proxy.py")"

describe honcho_upgrade
out=$(guest HONCHO_REF=v3.6.0) && rc=0 || rc=$?
assert_eq "an upgrade succeeds" 0 "$rc"
assert_contains "it says what it does" "the database is dumped first" "$out"
log=$(calls)
stop_line=$(grep -n 'systemctl stop' <<< "$log" | head -n1 | cut -d: -f1)
dump_line=$(grep -n 'pg_dump' <<< "$log" | head -n1 | cut -d: -f1)
assert_ok "the services stop before the dump" test "${stop_line:-999}" -lt "${dump_line:-0}"
assert_eq "the database is migrated" "migrated $(printf 'b%.0s' {1..40})" "$(cat "$fake/db-data")"
assert_fail "and the dump is deleted after success" test -e "$tmp/ct/state/rollback"

describe honcho_upgrade_rollback
before_env=$(<"$etc/honcho.env")
out=$(guest HONCHO_REF=v3.7.0 FAKE_UNHEALTHY_COMMIT="$(printf 'd%.0s' {1..40})" HONCHO_MODEL=auto) && rc=0 || rc=$?
assert_ne "an upgrade that does not come up fails" 0 "$rc"
assert_contains "and puts the previous release back" "The previous Honcho (bbbbbbbbbbbb) is running again." "$out"
assert_eq "at its commit" "$(printf 'b%.0s' {1..40})" "$(cat "$tmp/ct/opt/.git/FAKE_HEAD")"
assert_contains "with its database restored from the dump" "pg_restore --exit-on-error -d honcho" "$(calls)"
assert_eq "rollback also installs from the mcp package" 2 "$(grep -Fc "bun install --frozen-lockfile cwd=$tmp/ct/opt/mcp" "$FAKE_LOG")"
assert_eq "as it was" "migrated $(printf 'b%.0s' {1..40})" "$(cat "$fake/db-data")"
assert_eq "and its env file" "$before_env" "$(<"$etc/honcho.env")"
assert_ok "running again" test -e "$fake/active-honcho-api"
out=$(guest HONCHO_REF=v3.7.0 FAKE_MIGRATE_FAIL_COMMIT="$(printf 'd%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a failed migration fails the run" 0 "$rc"
assert_eq "and the half-migrated database is replaced by the dump" "migrated $(printf 'b%.0s' {1..40})" "$(cat "$fake/db-data")"
assert_fail "nothing set aside remains after a clean rollback" test -e "$tmp/ct/state/rollback"

describe honcho_signal_rollback
# A signal halfway through a migration (Ctrl-C, a closed SSH session, kill)
# rolls back like a failure: without the signal traps bash would run the EXIT
# trap with status 0 and leave the half-migrated database. perl restores
# SIGINT, which a background job otherwise starts with ignored.
guest_prefix=(perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"' --)
for signal in TERM INT HUP; do
  rm -f -- "$fake/migrating"
  # The background subshell execs the installer, so $! is the installer.
  ( guest_exec=1 guest HONCHO_REF=v3.7.0 FAKE_SLOW_MIGRATE_COMMIT="$(printf 'd%.0s' {1..40})" \
      OSR_INTERRUPT_LOG="$fake/interrupt.log" > "$fake/signal-out" ) &
  pid=$!
  for _ in {1..100}; do [[ -e $fake/migrating ]] && break; /bin/sleep 0.1; done
  assert_ok "SIG$signal reaches the migration before it exits" test -e "$fake/migrating"
  kill -"$signal" "$pid"
  rc=0; wait "$pid" || rc=$?
  out=$(cat "$fake/signal-out" "$fake/interrupt.log" 2>/dev/null || true)
  assert_ne "SIG$signal halfway through a migration fails the run" 0 "$rc"
  assert_contains "and puts the previous release back" "The previous Honcho (bbbbbbbbbbbb) is running again." "$out"
  assert_eq "with the database from the dump" "migrated $(printf 'b%.0s' {1..40})" "$(cat "$fake/db-data")"
  assert_eq "at its commit" "$(printf 'b%.0s' {1..40})" "$(cat "$tmp/ct/opt/.git/FAKE_HEAD")"
  assert_fail "and nothing set aside remains" test -e "$tmp/ct/state/rollback"
  rm -f -- "$fake/interrupt.log"
done
guest_prefix=()

describe honcho_rotate_keys
secret=$(<"$etc/jwt-secret")
out=$(guest HONCHO_REF=v3.6.0 HONCHO_ROTATE_KEYS=true FAKE_UNHEALTHY_COMMIT="$(printf 'b%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a rotation whose restart fails is undone" 0 "$rc"
assert_eq "the old secret is back" "$secret" "$(<"$etc/jwt-secret")"
assert_eq "and the old client key" "$client_key" "$(<"$etc/client-api-key")"
# That commit is unhealthy before the rotation too, so the rollback cannot
# bring Honcho back: it keeps its copies, and the next run waits for them.
assert_contains "a rollback that cannot come back keeps its copies" "the set-aside copies are in $tmp/ct/state/rollback" "$out"
assert_ok "with the dump" test -s "$tmp/ct/state/rollback/honcho.dump"
out=$(guest HONCHO_REF=v3.6.0 HONCHO_ROTATE_KEYS=true) && rc=0 || rc=$?
assert_ne "the next run refuses while they remain" 0 "$rc"
assert_contains "and names them" "Previous rollback data remains in $tmp/ct/state/rollback" "$out"
assert_contains "and how to continue" "rm -r -- $tmp/ct/state/rollback" "$out"
assert_contains "pointing at the README" "When a rollback does not complete" "$out"
assert_not_contains "before stopping or dumping anything" "pg_dump" "$(calls)"
assert_eq "the secret is untouched" "$secret" "$(<"$etc/jwt-secret")"
rm -rf -- "$tmp/ct/state/rollback"
out=$(guest HONCHO_REF=v3.6.0 HONCHO_ROTATE_KEYS=true) && rc=0 || rc=$?
assert_eq "a rotation succeeds" 0 "$rc"
assert_ne "with a new JWT secret" "$secret" "$(<"$etc/jwt-secret")"
assert_ne "a new admin key" "$admin_key" "$(<"$etc/api-key")"
assert_ne "and a new client key" "$client_key" "$(<"$etc/client-api-key")"
assert_contains "made with the new secret" "jwt-$(head -c 8 "$etc/jwt-secret")" "$(<"$etc/client-api-key")"
assert_contains "env file uses the new secret" "AUTH_JWT_SECRET=$(<"$etc/jwt-secret")" "$(<"$etc/honcho.env")"

describe honcho_budgets
out=$(guest HONCHO_CONTEXT_TOKENS=32768) && rc=0 || rc=$?
assert_eq "a 32k context window installs" 0 "$rc"
assert_contains "and says which budgets it set" "Honcho budgets for a 32768-token context" "$out"
assert_contains "the dialectic input fits the window" "DIALECTIC_MAX_INPUT_TOKENS=24576" "$(<"$etc/honcho.env")"
assert_contains "dreams get a smaller output cap" "DREAM_DEDUCTION_MODEL_CONFIG__MAX_OUTPUT_TOKENS=4096" "$(<"$etc/honcho.env")"
assert_eq "the choice is recorded for later runs" "HONCHO_CONTEXT_TOKENS=32768" "$(<"$etc/budgets.env")"
file_mode "root-only" 600 "$etc/budgets.env"
out=$(guest) && rc=0 || rc=$?
assert_eq "a rerun without the variable succeeds" 0 "$rc"
assert_contains "and keeps the budgets" "DIALECTIC_MAX_INPUT_TOKENS=24576" "$(<"$etc/honcho.env")"
out=$(guest HONCHO_DIALECTIC_MAX_INPUT_TOKENS=20000 HONCHO_DREAM_ENABLED=false) && rc=0 || rc=$?
assert_eq "an override succeeds" 0 "$rc"
assert_contains "and wins over the derived value" "DIALECTIC_MAX_INPUT_TOKENS=20000" "$(<"$etc/honcho.env")"
assert_contains "dreams can be turned off" "DREAM_ENABLED=false" "$(<"$etc/honcho.env")"
before_env=$(<"$etc/honcho.env") before_record=$(<"$etc/budgets.env")
out=$(guest HONCHO_CONTEXT_TOKENS=4096) && rc=0 || rc=$?
assert_ne "a window too small for a request is refused" 0 "$rc"
assert_contains "naming the range" "HONCHO_CONTEXT_TOKENS must be a whole number from 8192" "$out"
assert_not_contains "before anything is stopped" "systemctl stop" "$(calls)"
assert_eq "the env file is untouched" "$before_env" "$(<"$etc/honcho.env")"
out=$(guest HONCHO_CONTEXT_TOKENS=65536 FAKE_UNHEALTHY_COMMIT="$(<"$tmp/ct/opt/.git/FAKE_HEAD")") && rc=0 || rc=$?
assert_ne "a run that fails after changing the budgets is rolled back" 0 "$rc"
assert_eq "with the previous budget record" "$before_record" "$(<"$etc/budgets.env")"
assert_eq "and env file" "$before_env" "$(<"$etc/honcho.env")"
rm -rf -- "$tmp/ct/state/rollback"
out=$(guest HONCHO_CONTEXT_TOKENS= HONCHO_DIALECTIC_MAX_INPUT_TOKENS= HONCHO_DREAM_ENABLED=) && rc=0 || rc=$?
assert_eq "empty values return to Honcho's defaults" 0 "$rc"
assert_not_contains "no budget settings remain" "DIALECTIC_MAX_INPUT_TOKENS" "$(<"$etc/honcho.env")"
assert_eq "and the record is empty" "" "$(<"$etc/budgets.env")"
assert_contains "the run says so" "Honcho budgets: Honcho's defaults." "$out"
out=$(guest) && rc=0 || rc=$?
assert_eq "a later run of an installed Honcho" 0 "$rc"
assert_eq "keeps Honcho's defaults (the 65536 default is for a first install only)" "" "$(<"$etc/budgets.env")"

describe honcho_kept_settings
head_now() { cat "$tmp/ct/opt/.git/FAKE_HEAD"; }
out=$(guest HONCHO_REF=v3.6.0 HONCHO_MODEL=auto HONCHO_STRUCTURED_OUTPUT_MODE=json_object) && rc=0 || rc=$?
assert_eq "a run that sets the release, model and output mode succeeds" 0 "$rc"
assert_eq "it records them" "$(printf 'HONCHO_REF=v3.6.0\nHONCHO_MODEL=auto\nHONCHO_STRUCTURED_OUTPUT_MODE=json_object')" "$(<"$etc/settings.env")"
file_mode "root-only" 600 "$etc/settings.env"
out=$(guest) && rc=0 || rc=$?
assert_eq "a plain rerun succeeds" 0 "$rc"
assert_eq "and stays on the recorded release instead of the default" "$(printf 'b%.0s' {1..40})" "$(head_now)"
assert_contains "with the recorded model" "DERIVER_MODEL_CONFIG__MODEL=auto" "$(<"$etc/honcho.env")"
assert_contains "and output mode" "DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object" "$(<"$etc/honcho.env")"
assert_contains "the probe used the recorded mode" '"type": "json_object"' "$(cat "$fake/probe.json")"
assert_contains "and says what it kept" "Kept from the last run: HONCHO_REF=v3.6.0 HONCHO_MODEL=auto" "$out"
out=$(guest HONCHO_STRUCTURED_OUTPUT_MODE= HONCHO_MODEL=) && rc=0 || rc=$?
assert_eq "empty values succeed" 0 "$rc"
assert_not_contains "and return the output mode to the default" "STRUCTURED_OUTPUT_MODE" "$(<"$etc/honcho.env")"
assert_contains "and the model" "DERIVER_MODEL_CONFIG__MODEL=fast" "$(<"$etc/honcho.env")"
assert_eq "only the release stays recorded" "HONCHO_REF=v3.6.0" "$(<"$etc/settings.env")"
before=$(<"$etc/settings.env")
out=$(guest HONCHO_REF=v3.7.0 FAKE_MIGRATE_FAIL_COMMIT="$(printf 'd%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a failed upgrade" 0 "$rc"
assert_eq "keeps the previous record" "$before" "$(<"$etc/settings.env")"
printf 'HONCHO_REF=v3.6.0\nPATH=/nowhere\nHONCHO_ROTATE_KEYS=true\n' > "$etc/settings.env"
out=$(guest) && rc=0 || rc=$?
assert_eq "unknown names in the record are ignored" 0 "$rc"
assert_not_contains "it does not rotate the keys" "Rotating the JWT secret" "$out"

describe honcho_model_probe
fresh
printf '400\n' > "$fake/chat-status"
out=$(guest) && rc=0 || rc=$?
assert_ne "a model without JSON-schema output stops the install" 0 "$rc"
assert_contains "with the fallback named" "HONCHO_STRUCTURED_OUTPUT_MODE=json_object" "$out"
assert_not_contains "before anything is created" "createdb" "$(calls)"
out=$(guest HONCHO_STRUCTURED_OUTPUT_MODE=json_object) && rc=0 || rc=$?
assert_ne "json_object mode is probed too" 0 "$rc"
assert_contains "with JSON mode" '"type": "json_object"' "$(cat "$fake/probe.json")"
rm -f "$fake/chat-status"
out=$(guest HONCHO_STRUCTURED_OUTPUT_MODE=json_object) && rc=0 || rc=$?
assert_eq "json_object mode installs" 0 "$rc"
assert_eq "and is set for all nine model configs" 9 "$(grep -c 'STRUCTURED_OUTPUT_MODE=json_object' "$etc/honcho.env")"
printf 'no-tool-model\n' > "$fake/chat-warning"
out=$(guest) && rc=0 || rc=$?
assert_ne "a router without a tool-capable model stops the run" 0 "$rc"
assert_contains "and says why" "no reachable model that reports tool support" "$out"
assert_ok "an existing install is left running" test -e "$fake/active-honcho-api"
out=$(guest HONCHO_SKIP_CHAT_PROBE=true) && rc=0 || rc=$?
assert_ne "skipping the active probe still checks inventory capabilities" 0 "$rc"
rm -f "$fake/chat-warning"
printf '400\n' > "$fake/chat-status"
out=$(guest HONCHO_SKIP_CHAT_PROBE=true) && rc=0 || rc=$?
assert_eq "the active chat probe can be skipped" 0 "$rc"
rm -f "$fake/chat-status"
printf '768\n' > "$fake/embed-dims"
out=$(guest) && rc=0 || rc=$?
assert_ne "a local model that returns the wrong vector size stops the run" 0 "$rc"
assert_contains "naming both sizes" "returned 768 vector instead of 1024 values" "$out"
assert_not_contains "before Honcho is stopped" "pg_dump" "$(calls)"
assert_ok "an existing install is left running" test -e "$fake/active-honcho-api"
rm -f "$fake/embed-dims"
out=$(guest HONCHO_MODEL=large) && rc=0 || rc=$?
assert_ne "a model the router does not list is refused" 0 "$rc"

describe honcho_local_embedding
fresh
out=$(guest HONCHO_EMBEDDING_FILE_SHA256="$(printf '0%.0s' {1..64})") && rc=0 || rc=$?
assert_ne "a model file that does not match its checksum is refused" 0 "$rc"
assert_contains "and says so" "does not match its pinned SHA-256" "$out"
assert_fail "nothing of it is kept" test -e "$tmp/ct/embedding/Qwen3-Embedding-0.6B-Q8_0.gguf.part"
assert_not_contains "before Honcho is set up" "createdb" "$(calls)"
rm -rf -- "$tmp/ct/llama"   # built by the run above, before its download
out=$(guest FAKE_LLAMA_COMMIT="$(printf 'e%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a llama.cpp tag that is not the reviewed commit is refused" 0 "$rc"
assert_contains "naming both" "llama.cpp v0.5.0 is not commit 7fe450e19305b828c199d602c23a8337aaa1f03b" "$out"
assert_not_contains "and not built" "cmake --build" "$(calls)"
out=$(guest) && rc=0 || rc=$?
assert_eq "the pinned commit and model install" 0 "$rc"
printf 'damaged\n' > "$tmp/ct/embedding/Qwen3-Embedding-0.6B-Q8_0.gguf"
out=$(guest) && rc=0 || rc=$?
assert_eq "a damaged model file is replaced" 0 "$rc"
assert_contains "by downloading it again" "download https://models.test/model.gguf" "$(calls)"
assert_ok "intact" cmp -s "$fake/model.gguf" "$tmp/ct/embedding/Qwen3-Embedding-0.6B-Q8_0.gguf"
printf 'flags : fpu sse2 avx f16c fma avx2 bmi2\n' > "$tmp/ct/cpuinfo"
out=$(guest) && rc=0 || rc=$?
assert_eq "another CPU (a migrated CT) gets llama.cpp built for it" 0 "$rc"
assert_contains "with its instruction sets" "-DGGML_FMA=ON -DGGML_AVX2=ON -DGGML_BMI2=ON" "$(calls)"
before=$(<"$tmp/ct/llama/build-info")
out=$(guest HONCHO_REF=v3.7.0 FAKE_MIGRATE_FAIL_COMMIT="$(printf 'd%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a failed run after the embedding step" 0 "$rc"
assert_contains "rolls back" "is running again" "$out"
assert_ok "with the local model's unit" test -f "$tmp/ct/units/honcho-embedding.service"
assert_ok "and running" test -e "$fake/active-honcho-embedding"
assert_eq "and its build record" "$before" "$(<"$tmp/ct/llama/build-info")"

describe honcho_bun
python3 - "$tmp/bun.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("bun-linux-x64/bun", '#!/usr/bin/env bash\n[[ $1 == --version ]] && { echo 9.9.9; exit; }\n[[ $1 == install && $2 == --frozen-lockfile && $PWD == "$FAKE_OPT/mcp" ]] || { echo "unexpected Bun command: $* in $PWD" >&2; exit 3; }\necho "bun $* cwd=$PWD" >> "$FAKE_LOG"\n')
PY
zip_sha=$(sha256sum "$tmp/bun.zip" | cut -d' ' -f1)
export FAKE_BUN_ZIP=$tmp/bun.zip
out=$(guest HONCHO_BUN_VERSION=9.9.9 HONCHO_BUN_SHA256="$(printf '0%.0s' {1..64})") && rc=0 || rc=$?
assert_ne "a Bun zip that does not match its checksum is refused" 0 "$rc"
assert_contains "and says so" "does not match its pinned SHA-256" "$out"
assert_eq "the previous Bun is put back" 1.4.4 "$("$tmp/bun/bun" --version)"
out=$(guest HONCHO_BUN_VERSION=9.9.9 HONCHO_BUN_SHA256="$zip_sha") && rc=0 || rc=$?
assert_eq "a matching zip is installed" 0 "$rc"
assert_contains "from the release URL of that version" "bun-v9.9.9/bun-linux-x64.zip" "$(calls)"
assert_eq "as the Bun the MCP unit runs" 9.9.9 "$("$tmp/bun/bun" --version)"
printf 'flags : fpu sse2\n' > "$tmp/ct/cpuinfo"
out=$(guest HONCHO_BUN_VERSION=9.9.8 HONCHO_BUN_SHA256="$zip_sha") && rc=0 || rc=$?
assert_ne "a CPU without AVX2 needs the baseline checksum" 0 "$rc"
assert_contains "and is told which one" "Set HONCHO_BUN_BASELINE_SHA256" "$out"
assert_contains "a run without Bun settings keeps the recorded pin" "HONCHO_BUN_VERSION=9.9.9" "$(<"$etc/settings.env")"
out=$(guest HONCHO_BUN_VERSION= HONCHO_BUN_SHA256=) && rc=0 || rc=$?
assert_contains "the default Bun takes the baseline build here" "bun-v1.4.4/bun-linux-x64-baseline.zip" "$(calls)"
assert_ne "and is held to its built-in checksum (the fake zip is not Bun 1.4.4)" 0 "$rc"
assert_contains "which it reports" "does not match its pinned SHA-256" "$out"

describe honcho_uv_venv
# The services run uv as honcho. A venv this script builds must be readable by
# others although the script runs under umask 077, and a root-only venv left by
# an earlier run is repaired (root could still run it, so it is not rebuilt).
fresh
cp "$tmp/uv/bin/uv" "$tmp/uv-template"
rm -rf -- "$tmp/uv"
real_python3=$(command -v python3)
cat > "$bin/python3" <<STUB
#!/usr/bin/env bash
if [[ \$1 == -m && \$2 == venv ]]; then
  echo "venv umask \$(umask)" >> "\$FAKE_LOG"
  mkdir -p "\$3/bin"
  printf '#!/usr/bin/env bash\\nmkdir -p "%s/bin"; cp "%s" "%s/bin/uv"\\n' "\$3" "$tmp/uv-template" "\$3" > "\$3/bin/pip"
  chmod +x "\$3/bin/pip"
  exit 0
fi
exec "$real_python3" "\$@"
STUB
chmod +x "$bin/python3"
out=$(guest) && rc=0 || rc=$?
rm -f "$bin/python3"
assert_eq "an install that builds the uv venv succeeds" 0 "$rc"
assert_contains "the venv is built under umask 022" "venv umask 0022" "$(calls)"
assert_eq "its directory is open to the honcho user" 755 "$(stat -c %a "$tmp/uv")"
assert_eq "and uv is executable by it" 755 "$(stat -c %a "$tmp/uv/bin/uv")"
chmod -R go-rwx "$tmp/uv"
out=$(guest) && rc=0 || rc=$?
assert_eq "a rerun over a root-only venv succeeds" 0 "$rc"
assert_eq "and repairs the directory" 755 "$(stat -c %a "$tmp/uv")"
assert_eq "and uv" 755 "$(stat -c %a "$tmp/uv/bin/uv")"
assert_not_contains "without rebuilding it" "venv umask" "$(calls)"
rm -f "$tmp/uv-template"

summary
