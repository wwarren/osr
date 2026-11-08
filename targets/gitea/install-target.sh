#!/usr/bin/env bash
# Run as root in the Gitea CT made by the Proxmox VE community script
# (provision-lxc.sh pushes and runs this). It finishes Gitea's setup without the
# browser and prepares what the router's configuration repository needs:
#
#   * /etc/gitea/app.ini with SQLite, the CT's address as ROOT_URL, generated
#     secrets, INSTALL_LOCK (the web installer is closed) and self-registration
#     off. An existing locked app.ini is kept as it is.
#   * an administrator account (password in /etc/gitea-target/admin-password)
#   * a non-admin router account and its access token (write:repository and
#     write:user, so the router installer can create its repository)
#
# Reruns keep what exists: accounts are never recreated, and a token that still
# works is kept.
#   bash install-target.sh            configure, or check and repair
#   bash install-target.sh --dry-run  print the plan; change nothing
set -Eeuo pipefail
umask 077

# Paths are overridable for tests only; the community script uses these.
GITEA_BIN=${GITEA_BIN:-/usr/local/bin/gitea}
GITEA_CONF_DIR=${GITEA_CONF_DIR:-/etc/gitea}
GITEA_WORK_DIR=${GITEA_WORK_DIR:-/var/lib/gitea}
GITEA_TARGET_ETC=${GITEA_TARGET_ETC:-/etc/gitea-target}
GITEA_SERVICE_USER=${GITEA_SERVICE_USER:-gitea}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-120}
GITEA_PORT=3000

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash install-target.sh [--dry-run]

Settings (environment; all optional):
  GITEA_DOMAIN=<this CT's IPv4>        host name or address in ROOT_URL
  GITEA_SITE_ADMIN=gitea-admin         administrator account
  GITEA_SITE_ADMIN_EMAIL=<admin>@<domain>.local
  GITEA_ROUTER_USER=ollama-router      the router's non-admin account
  GITEA_ROUTER_EMAIL=<router>@<domain>.local
Results (root-only, 0600) in /etc/gitea-target: url, admin-user,
admin-password, router-user, router-token.
USAGE
}

# Install helpers (sourced by test-install.sh) -------------------------------

# valid_username NAME: a Gitea login name this target may create. Gitea
# reserves "admin" (and other route names) for itself.
valid_username() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,38}[A-Za-z0-9]$ ]] || return 1
  case ${1,,} in admin|api|assets|explore|ghost|gitea-actions|login|org|repo|user|v2) return 1 ;; esac
}
valid_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

# app_ini DOMAIN SECRET_KEY INTERNAL_TOKEN JWT_SECRET: the configuration the
# web installer would write, with registration closed.
app_ini() {
  cat <<INI
APP_NAME = Gitea
RUN_USER = ${GITEA_SERVICE_USER}
RUN_MODE = prod
WORK_PATH = ${GITEA_WORK_DIR}

[database]
DB_TYPE = sqlite3
PATH = ${GITEA_WORK_DIR}/data/gitea.db

[repository]
ROOT = ${GITEA_WORK_DIR}/data/gitea-repositories

[server]
PROTOCOL = http
DOMAIN = $1
HTTP_PORT = ${GITEA_PORT}
ROOT_URL = http://$1:${GITEA_PORT}/
APP_DATA_PATH = ${GITEA_WORK_DIR}/data
DISABLE_SSH = true
LFS_START_SERVER = false

[security]
INSTALL_LOCK = true
SECRET_KEY = $2
INTERNAL_TOKEN = $3

[oauth2]
JWT_SECRET = $4

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true
DEFAULT_KEEP_EMAIL_PRIVATE = true

[log]
MODE = console
LEVEL = Info
ROOT_PATH = ${GITEA_WORK_DIR}/log
INI
}

# install_locked FILE: does an app.ini already finish the installation?
install_locked() {
  [[ -f $1 ]] && grep -Eq '^[[:space:]]*INSTALL_LOCK[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$1"
}

# token_from_output: the access token in generate-access-token's output (the
# token alone with --raw, else the last word of its success message).
token_from_output() {
  local token
  token=$(tr -s '[:space:]' '\n' | grep -E '^[0-9a-f]{40}$' | tail -n 1)
  [[ -n $token ]] && printf '%s\n' "$token"
}

# root_url FILE: an app.ini's [server] ROOT_URL, without the trailing slash.
root_url() {
  awk -F= '/^[[:space:]]*\[/ {s=$0} s ~ /\[server\]/ && $1 ~ /^[[:space:]]*ROOT_URL[[:space:]]*$/ {
    v=$2; for (i = 3; i <= NF; i++) v = v "=" $i; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); sub(/\/$/, "", v); print v; exit }' "$1"
}

# user_listed NAME < `gitea admin user list` output: is NAME an account?
user_listed() {
  awk -v n="${1,,}" 'NR > 1 && tolower($2) == n {found=1} END {exit !found}'
}

# write_secret FILE VALUE: a root-only file, replaced atomically.
write_secret() {
  printf '%s\n' "$2" > "$1.new"
  chmod 0600 "$1.new"
  mv -f -- "$1.new" "$1"
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

GITEA_DOMAIN=${GITEA_DOMAIN:-}
if [[ -z $GITEA_DOMAIN ]]; then
  GITEA_DOMAIN=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 1 || true)
  (( ! dry_run )) || GITEA_DOMAIN=${GITEA_DOMAIN:-<CT address>}
fi
GITEA_SITE_ADMIN=${GITEA_SITE_ADMIN:-gitea-admin}
GITEA_ROUTER_USER=${GITEA_ROUTER_USER:-ollama-router}
mail_domain=${GITEA_DOMAIN//[^A-Za-z0-9.-]/}
[[ $mail_domain == *[A-Za-z]* ]] || mail_domain=gitea
GITEA_SITE_ADMIN_EMAIL=${GITEA_SITE_ADMIN_EMAIL:-$GITEA_SITE_ADMIN@$mail_domain.local}
GITEA_ROUTER_EMAIL=${GITEA_ROUTER_EMAIL:-$GITEA_ROUTER_USER@$mail_domain.local}

if (( ! dry_run )); then
  [[ $GITEA_DOMAIN =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] ||
    die 'Cannot tell this CT address; set GITEA_DOMAIN to the host name or address the router uses.'
fi
valid_username "$GITEA_SITE_ADMIN" || die "GITEA_SITE_ADMIN '$GITEA_SITE_ADMIN' is not a usable Gitea user name."
valid_username "$GITEA_ROUTER_USER" || die "GITEA_ROUTER_USER '$GITEA_ROUTER_USER' is not a usable Gitea user name."
[[ ${GITEA_SITE_ADMIN,,} != "${GITEA_ROUTER_USER,,}" ]] ||
  die 'The router account must not be the administrator (it gets a token).'
valid_email "$GITEA_SITE_ADMIN_EMAIL" || die 'Invalid GITEA_SITE_ADMIN_EMAIL.'
valid_email "$GITEA_ROUTER_EMAIL" || die 'Invalid GITEA_ROUTER_EMAIL.'
[[ $HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid HEALTH_TIMEOUT.'
url="http://$GITEA_DOMAIN:$GITEA_PORT"
conf=$GITEA_CONF_DIR/app.ini

if (( dry_run )); then
  printf '+ stop gitea; write %s (SQLite, ROOT_URL %s/, INSTALL_LOCK, registration off) unless it is already locked\n' "$conf" "$url"
  printf '+ gitea migrate; start gitea; wait for %s/api/healthz\n' "http://127.0.0.1:$GITEA_PORT"
  printf '+ create administrator %s (password in %s/admin-password) if missing\n' "$GITEA_SITE_ADMIN" "$GITEA_TARGET_ETC"
  printf '+ create non-admin %s and a write:repository,write:user token in %s/router-token\n' "$GITEA_ROUTER_USER" "$GITEA_TARGET_ETC"
  exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the Gitea CT.'
[[ -x $GITEA_BIN ]] || die "No Gitea at $GITEA_BIN. Create the CT with provision-lxc.sh (the community script) first."
id "$GITEA_SERVICE_USER" >/dev/null 2>&1 || die "The $GITEA_SERVICE_USER account is missing; this is not a community-script Gitea CT."
command -v openssl >/dev/null || { apt-get update && apt-get install -y --no-install-recommends openssl; }

as_gitea() {
  runuser -u "$GITEA_SERVICE_USER" -- env HOME="$GITEA_WORK_DIR/data" USER="$GITEA_SERVICE_USER" \
    GITEA_WORK_DIR="$GITEA_WORK_DIR" "$GITEA_BIN" --config "$conf" --work-path "$GITEA_WORK_DIR" "$@"
}
# /api/healthz needs no sign-in (it checks the database and cache). The
# /api/v1 routes, /api/v1/version included, answer 401 to anonymous callers
# once REQUIRE_SIGNIN_VIEW is on, so they cannot tell when Gitea is up.
gitea_ready() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$GITEA_PORT/api/healthz" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

install -d -m 0700 "$GITEA_TARGET_ETC"

# --- app.ini: the web installer's job, done here --------------------------------
if install_locked "$conf"; then
  note "Keeping the existing $conf (the installation is already locked)."
  existing=$(root_url "$conf")
  [[ -z $existing ]] || url=$existing
else
  note "Configuring Gitea at $url (SQLite, registration off)."
  systemctl stop gitea.service || true
  [[ ! -f $conf ]] || cp -a -- "$conf" "$conf.before-gitea-target"
  secret_key=$("$GITEA_BIN" generate secret SECRET_KEY)
  internal_token=$("$GITEA_BIN" generate secret INTERNAL_TOKEN)
  jwt_secret=$("$GITEA_BIN" generate secret JWT_SECRET)
  [[ -n $secret_key && -n $internal_token && -n $jwt_secret ]] || die 'gitea generate secret produced nothing.'
  install -d -m 0750 -o "$GITEA_SERVICE_USER" -g "$GITEA_SERVICE_USER" "$GITEA_CONF_DIR" \
    "$GITEA_WORK_DIR/data" "$GITEA_WORK_DIR/log"
  app_ini "$GITEA_DOMAIN" "$secret_key" "$internal_token" "$jwt_secret" > "$conf.new"
  unset secret_key internal_token jwt_secret
  chown "$GITEA_SERVICE_USER:$GITEA_SERVICE_USER" "$conf.new"
  chmod 0640 "$conf.new"
  mv -f -- "$conf.new" "$conf"
  as_gitea migrate >/dev/null
fi
systemctl enable gitea.service >/dev/null 2>&1 || true
systemctl restart gitea.service
gitea_ready || die "Gitea did not answer http://127.0.0.1:$GITEA_PORT/api/healthz within ${HEALTH_TIMEOUT}s; see: journalctl -u gitea"
write_secret "$GITEA_TARGET_ETC/url" "$url"

# --- accounts ---------------------------------------------------------------------
users=$(as_gitea admin user list)
if user_listed "$GITEA_SITE_ADMIN" <<< "$users"; then
  note "Administrator $GITEA_SITE_ADMIN exists."
else
  password=$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 24)
  # Saved before the account exists, so a failure never loses the password.
  write_secret "$GITEA_TARGET_ETC/admin-password" "$password"
  as_gitea admin user create --admin --username "$GITEA_SITE_ADMIN" --email "$GITEA_SITE_ADMIN_EMAIL" \
    --password "$password" --must-change-password=true >/dev/null
  unset password
  note "Created administrator $GITEA_SITE_ADMIN (change the password at first sign-in)."
fi
write_secret "$GITEA_TARGET_ETC/admin-user" "$GITEA_SITE_ADMIN"
if user_listed "$GITEA_ROUTER_USER" <<< "$users"; then
  note "Router account $GITEA_ROUTER_USER exists."
else
  # Nobody signs in as the router: a random password it never uses.
  as_gitea admin user create --username "$GITEA_ROUTER_USER" --email "$GITEA_ROUTER_EMAIL" \
    --random-password --must-change-password=false >/dev/null
  note "Created the non-admin router account $GITEA_ROUTER_USER."
fi
write_secret "$GITEA_TARGET_ETC/router-user" "$GITEA_ROUTER_USER"

# --- the router's token -------------------------------------------------------------
token_ok() {
  [[ -s $GITEA_TARGET_ETC/router-token ]] || return 1
  printf 'Authorization: token %s\n' "$(tr -d '\r\n' < "$GITEA_TARGET_ETC/router-token")" > "$GITEA_TARGET_ETC/.auth"
  curl -fsS --max-time 10 -o /dev/null -H "@$GITEA_TARGET_ETC/.auth" "http://127.0.0.1:$GITEA_PORT/api/v1/user" 2>/dev/null
  local rc=$?
  rm -f -- "$GITEA_TARGET_ETC/.auth"
  return "$rc"
}
if token_ok; then
  note "The router token in $GITEA_TARGET_ETC/router-token still works; kept."
else
  token=$(as_gitea admin user generate-access-token --username "$GITEA_ROUTER_USER" \
    --token-name "ollama-smart-router-$(date +%Y%m%d%H%M%S)" --scopes write:repository,write:user --raw |
    token_from_output) || die 'Gitea did not return an access token.'
  write_secret "$GITEA_TARGET_ETC/router-token" "$token"
  unset token
  token_ok || die 'The new router token is not accepted by Gitea.'
  note "Created the router token ($GITEA_TARGET_ETC/router-token)."
fi

note "Gitea is ready at $url. Router account: $GITEA_ROUTER_USER."
