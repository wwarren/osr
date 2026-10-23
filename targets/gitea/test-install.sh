#!/usr/bin/env bash
# install-target.sh: helpers and the dry run, then whole runs as root against a
# fake gitea binary (accounts, tokens and the migrate step kept in a state
# directory), stubbed systemctl/runuser and a fake Gitea API (curl). Nothing is
# installed or started.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/install-target.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gitea-target-test.XXXXXX")
cleanup() { [[ $tmp == "${TMPDIR:-/tmp}"/gitea-target-test.* ]] && rm -rf -- "$tmp"; }
trap cleanup EXIT

bash -n "$script" || fail 'shell syntax'

# --- helpers --------------------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Install helpers/{c=1;next} /^# End install helpers\./{c=0} c' "$script")
for helper in valid_username valid_email app_ini install_locked token_from_output root_url user_listed write_secret; do
  declare -F "$helper" >/dev/null || fail "helper extraction failed: $helper"
done
valid_username ollama-router && valid_username gitea-admin || fail 'valid names refused'
for bad in admin Admin api -x 'two words' a; do
  if valid_username "$bad"; then fail "accepted user name '$bad'"; fi
done
valid_email 'a.b@192.0.2.75.local' || fail 'a .local address was refused'
if valid_email 'nobody@'; then fail 'accepted a bad email'; fi
# app_ini reads these globals.
# shellcheck disable=SC2034
GITEA_SERVICE_USER=gitea GITEA_WORK_DIR=/var/lib/gitea GITEA_PORT=3000
ini=$(app_ini 192.0.2.75 sk it jw)
for line in 'INSTALL_LOCK = true' 'DISABLE_REGISTRATION = true' 'ROOT_URL = http://192.0.2.75:3000/' \
            'DB_TYPE = sqlite3' 'SECRET_KEY = sk' 'INTERNAL_TOKEN = it' 'JWT_SECRET = jw' 'REQUIRE_SIGNIN_VIEW = true'; do
  grep -qxF "$line" <<< "$ini" || fail "app.ini lacks: $line"
done
printf '%s\n' "$ini" > "$tmp/app.ini"
install_locked "$tmp/app.ini" || fail 'a locked app.ini was not recognised'
[[ $(root_url "$tmp/app.ini") == http://192.0.2.75:3000 ]] || fail "root_url: $(root_url "$tmp/app.ini")"
printf '[security]\nINSTALL_LOCK = false\n' > "$tmp/app.ini"
if install_locked "$tmp/app.ini"; then fail 'an unlocked app.ini counted as locked'; fi
tok=0123456789abcdef0123456789abcdef01234567
[[ $(printf '%s\n' "$tok" | token_from_output) == "$tok" ]] || fail 'raw token'
[[ $(printf 'Access token was successfully created: %s\n' "$tok" | token_from_output) == "$tok" ]] || fail 'token message'
if printf 'error\n' | token_from_output >/dev/null; then fail 'no token was accepted'; fi
users=$'ID   Username       Email   IsActive IsAdmin 2FA\n1    gitea-admin    a@b.c   true     true    false'
user_listed gitea-admin <<< "$users" || fail 'user_listed missed a user'
if user_listed ollama-router <<< "$users"; then fail 'user_listed invented a user'; fi
if user_listed Username <<< "$users"; then fail 'the header counted as a user'; fi
pass 'helpers: names, app.ini, the lock, ROOT_URL, token output and the user list'

out=$(bash "$script" --dry-run) || fail 'dry run'
[[ $out == *'INSTALL_LOCK, registration off'* && $out == *'write:repository,write:user token'* ]] || fail "dry run: $out"
for bad in GITEA_ROUTER_USER=admin GITEA_SITE_ADMIN=ollama-router GITEA_SITE_ADMIN_EMAIL=nope; do
  if env "$bad" bash "$script" --dry-run >/dev/null 2>&1; then fail "accepted $bad"; fi
done
pass 'the dry run plans the setup; reserved or clashing names and bad emails are refused'

if (( EUID != 0 )); then
  printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
  printf '%s Gitea target install cases passed. Nothing was installed.\n' "$passed"
  exit 0
fi

# --- whole runs -------------------------------------------------------------------
bin=$tmp/bin; state=$tmp/state; log=$tmp/calls.log
mkdir -p "$bin" "$state"
export FAKE_STATE=$state FAKE_LOG=$log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub id '[[ $1 == gitea ]]'
stub chown 'exit 0'
stub sleep 'exit 0'
stub hostname '[[ $1 == -I ]] && echo "192.0.2.75 fd00::75"'
stub install 'a=(); while (( $# )); do case $1 in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done; exec /usr/bin/install "${a[@]}"'
stub systemctl 'case $1 in stop) rm -f "$FAKE_STATE/running" ;; restart) [[ -n ${FAKE_NO_START:-} ]] || touch "$FAKE_STATE/running" ;; esac; exit 0'
# gitea: generate secret, migrate, admin user list/create/generate-access-token.
cat > "$bin/gitea" <<'EOF'
#!/usr/bin/env bash
echo "gitea $*" >> "$FAKE_LOG"
args=()
while (( $# )); do case $1 in --config|--work-path) shift 2 ;; *) args+=("$1"); shift ;; esac; done
set -- "${args[@]}"
users=$FAKE_STATE/users
case "$1 $2 $3" in
  "generate secret "*) printf 'secret-%s-%s\n' "$3" "$RANDOM" ;;
  migrate*) touch "$FAKE_STATE/migrated" ;;
  "admin user list")
    printf 'ID   Username   Email   IsActive IsAdmin 2FA\n'
    if [[ -f $users ]]; then cat "$users"; fi ;;
  "admin user create")
    shift 3; name='' admin=false
    while (( $# )); do case $1 in --username) name=$2; shift ;; --admin) admin=true ;; esac; shift; done
    grep -q " $name " "$users" 2>/dev/null && { echo "user already exists [name: $name]" >&2; exit 1; }
    printf '%s %s x@y.z true %s false\n' "$(( $(wc -l < "$users" 2>/dev/null || echo 0) + 1 ))" "$name" "$admin" >> "$users" ;;
  "admin user generate-access-token")
    token=$(printf '%040x' "$(( $(date +%s%N) % 99999999 ))" | tail -c 40)
    echo "$token" >> "$FAKE_STATE/tokens"
    if [[ " $* " == *" --raw "* ]]; then echo "$token"; else echo "Access token was successfully created: $token"; fi ;;
  *) echo "fake gitea: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$bin/gitea"
# curl: the Gitea API answers while "running"; /api/v1/user checks the token.
cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
[[ -e $FAKE_STATE/running ]] || exit 7
hdr=''
while (( $# )); do
  [[ $1 == -H && $2 == @* ]] && hdr=$(cat "${2#@}")
  url=$1; shift
done
case $url in
  */api/v1/version) exit 0 ;;
  */api/v1/user) token=${hdr#Authorization: token }; grep -qx "$token" "$FAKE_STATE/tokens" 2>/dev/null || exit 22 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$bin/curl"

etc=$tmp/etc/gitea; target=$tmp/etc/gitea-target; work=$tmp/var/lib/gitea
guest() {
  env PATH="$bin:$PATH" GITEA_BIN="$bin/gitea" GITEA_CONF_DIR="$etc" GITEA_WORK_DIR="$work" \
    GITEA_TARGET_ETC="$target" HEALTH_TIMEOUT=2 "$@" bash "$script" 2>&1
}
reset() { rm -rf -- "${tmp:?}/etc" "${tmp:?}/var" "${state:?}"/*; : > "$log"; mkdir -p "$etc"; }

reset
out=$(guest) || fail "fresh setup: $out"
grep -qx 'INSTALL_LOCK = true' "$etc/app.ini" && grep -qx 'DISABLE_REGISTRATION = true' "$etc/app.ini" || fail 'app.ini not locked'
grep -qx 'ROOT_URL = http://192.0.2.75:3000/' "$etc/app.ini" || fail 'ROOT_URL is not the CT address'
grep -q '^SECRET_KEY = secret-SECRET_KEY-' "$etc/app.ini" || fail 'secrets were not generated'
[[ $(stat -c %a "$etc/app.ini") == 640 ]] || fail 'app.ini mode'
migrate_line=$(grep -n 'gitea .*migrate' "$log" | cut -d: -f1 | head -n1)
restart_line=$(grep -n 'systemctl restart gitea.service' "$log" | cut -d: -f1 | head -n1)
(( migrate_line < restart_line )) || fail 'the database was not migrated before the start'
grep -q 'admin user create --admin --username gitea-admin .*--must-change-password=true' "$log" || fail 'administrator'
grep -q 'admin user create --username ollama-router .*--random-password --must-change-password=false' "$log" || fail 'router account'
grep -q 'generate-access-token --username ollama-router .*--scopes write:repository,write:user --raw' "$log" || fail 'token scopes'
[[ $(< "$target/router-token") =~ ^[0-9a-f]{40}$ ]] || fail 'token file'
[[ $(< "$target/url") == http://192.0.2.75:3000 && $(< "$target/router-user") == ollama-router ]] || fail 'url/router-user'
[[ $(< "$target/admin-user") == gitea-admin && -s $target/admin-password ]] || fail 'admin files'
for f in url admin-user admin-password router-user router-token; do
  [[ $(stat -c %a "$target/$f") == 600 ]] || fail "$f is not 0600"
done
[[ ! -e $target/.auth ]] || fail 'the token header file was left behind'
grep '^curl ' "$log" | grep -q "$(< "$target/router-token")" && fail 'the token was passed to curl in argv'
pass 'fresh setup: locked app.ini, migrated before start, admin, non-admin router account and a 0600 token'

: > "$log"
token=$(< "$target/router-token"); config=$(< "$etc/app.ini")
out=$(guest) || fail "rerun: $out"
grep -q 'admin user create\|generate-access-token\|systemctl stop' "$log" && fail 'a rerun recreated something'
[[ $(< "$target/router-token") == "$token" && $(< "$etc/app.ini") == "$config" ]] || fail 'a rerun changed the token or app.ini'
[[ $out == *'still works; kept'* ]] || fail "rerun message: $out"
pass 'a rerun keeps the configuration, the accounts and a working token'

: > "$state/tokens"
out=$(guest) || fail "token repair: $out"
[[ $(< "$target/router-token") != "$token" ]] || fail 'a revoked token was kept'
pass 'a token Gitea no longer accepts is replaced'

reset
printf '[server]\nROOT_URL = https://git.example.net/\n[security]\nINSTALL_LOCK = true\n' > "$etc/app.ini"
out=$(guest) || fail "adopt: $out"
grep -q 'ROOT_URL = https://git.example.net/' "$etc/app.ini" || fail 'an existing locked app.ini was rewritten'
[[ $(< "$target/url") == https://git.example.net ]] || fail "the existing ROOT_URL was not reported: $(< "$target/url")"
grep -q 'migrate' "$log" && fail 'an adopted installation was migrated by this script'
[[ -s $target/router-token ]] || fail 'no token for an adopted installation'
pass 'an installation finished in the browser is adopted: its app.ini and URL are kept'

reset
if out=$(guest FAKE_NO_START=1); then fail 'a Gitea that never answered was accepted'; fi
[[ $out == *'did not answer'* && $out == *'journalctl -u gitea'* ]] || fail "not-ready message: $out"
pass 'a Gitea that does not come up is reported, with where to look'

reset
if out=$(guest GITEA_BIN="$tmp/none"); then fail 'a CT without Gitea was accepted'; fi
[[ $out == *'No Gitea at'* ]] || fail "missing binary message: $out"
pass 'a CT without the community-script Gitea is refused'

printf '%s Gitea target install cases passed. Nothing was installed.\n' "$passed"
