#!/usr/bin/env bash
# Run inside the dedicated DeepSeek Harness LXC after provision-lxc.sh pushes
# the keys and this target's files. Installs or reconfigures DeepSeek; on an
# installed CT a failed run puts the previous release and configuration back.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash install-target.sh [--dry-run]
Install or reconfigure DeepSeek Harness as an unprivileged systemd service.
Keys: router-api-key (empty for a keyless OSR), with Honcho honcho-api-key,
  with Open Terminal open-terminal-key (this CT's client key), next to this
  script or already in /etc/deepseek-harness.
Environment: DSH_ROUTER_URL, DSH_BIND_IP, DSH_MODEL=auto,
  DSH_CONTEXT_WINDOW=32768, DSH_MAX_TOKENS=8192, DSH_PORT=3080,
  DSH_VERSION=0.2.1-rc.5 (an exact npm release, or latest),
  DSH_HONCHO_MCP_URL (Honcho memory through its MCP server; empty = off),
  DSH_OPEN_TERMINAL_URL (this agent's own Open Terminal workspace, the
  gateway as http://IP:port, as MCP tools; empty = off).
An unchanged rerun does nothing. A failed upgrade or reconfigure restores the
previous release, configuration and unit and restarts them.
USAGE
}

# The release this target was tested with (dsh --dump-config, a headless chat
# through the OSR provider and the Honcho MCP connection). DeepSeek is a
# developer preview with breaking changes; move the pin after testing.
DEFAULT_VERSION=0.2.1-rc.5

dry_run=0
while (( $# )); do
  case $1 in
    --dry-run) dry_run=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

ROUTER_URL=${DSH_ROUTER_URL:-}
BIND_IP=${DSH_BIND_IP:-}
MODEL=${DSH_MODEL:-auto}
CONTEXT_WINDOW=${DSH_CONTEXT_WINDOW:-32768}
MAX_TOKENS=${DSH_MAX_TOKENS:-8192}
PORT=${DSH_PORT:-3080}
VERSION=${DSH_VERSION:-$DEFAULT_VERSION}
HONCHO_MCP_URL=${DSH_HONCHO_MCP_URL:-}
OPEN_TERMINAL_URL=${DSH_OPEN_TERMINAL_URL:-}
ETC_DIR=${DSH_ETC_DIR:-/etc/deepseek-harness}
OPT_DIR=${DSH_OPT_DIR:-/opt/deepseek-harness}
STATE_DIR=${DSH_STATE_DIR:-/var/lib/deepseek-harness}
ROLLBACK_DIR=${DSH_ROLLBACK_DIR:-/var/lib/deepseek-harness-target/rollback}
UNIT_DIR=${DSH_UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${DSH_SERVICE_USER:-deepseek-harness}
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DSH_HOME_DIR=$STATE_DIR/home
UNIT=$UNIT_DIR/deepseek-harness.service
PACKAGE=@deepseek-ai/dsh

[[ $ROUTER_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?$ ]] || die 'DSH_ROUTER_URL must be an HTTP(S) origin.'
[[ $BIND_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'DSH_BIND_IP must be the CT IPv4 address.'
for value in "$CONTEXT_WINDOW" "$MAX_TOKENS" "$PORT"; do
  [[ $value =~ ^[1-9][0-9]{0,7}$ ]] || die 'Context, max tokens and port must be positive integers.'
done
(( MAX_TOKENS < CONTEXT_WINDOW && PORT <= 65535 )) || die 'Invalid context, max tokens or port.'
[[ $VERSION =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)$ ]] || die 'DSH_VERSION must be latest or an exact npm version.'
[[ $MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid DSH_MODEL.'
if [[ -n $HONCHO_MCP_URL ]]; then
  [[ $HONCHO_MCP_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] ||
    die 'DSH_HONCHO_MCP_URL must be an HTTP(S) URL such as http://<honcho-ip>:3000/mcp.'
  (( CONTEXT_WINDOW >= 32768 )) ||
    die 'Honcho memory adds about 40 tool definitions; it needs DSH_CONTEXT_WINDOW of 32768 or more.'
fi
[[ -z $OPEN_TERMINAL_URL || $OPEN_TERMINAL_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/?$ ]] ||
  die 'DSH_OPEN_TERMINAL_URL must be the Open Terminal gateway, such as http://<terminal-ip>:8000.'
OPEN_TERMINAL_URL=${OPEN_TERMINAL_URL%/}
for path in "$ETC_DIR" "$OPT_DIR" "$STATE_DIR" "$ROLLBACK_DIR" "$UNIT_DIR"; do
  [[ $path == /* && $path != *..* ]] || die "Invalid path: $path"
done
[[ -r $SOURCE_DIR/configure.mjs && -r $SOURCE_DIR/deepseek-harness.service ]] ||
  die 'Missing configure.mjs or deepseek-harness.service.'

# Install helpers
# record_get FILE KEY: KEY's value in a KEY=VALUE record; the record is
# parsed, never sourced.
record_get() {
  [[ -r $1 ]] || return 1
  awk -v key="$2" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1; exit } END { exit !found }' "$1"
}
# settings_record VERSION ROUTER_KEY_SHA HONCHO_KEY_SHA FILES_SHA: what one
# completed run installed. Rerunning with the same record changes nothing.
settings_record() {
  printf 'DSH_VERSION=%s\nDSH_MODEL=%s\nDSH_CONTEXT_WINDOW=%s\nDSH_MAX_TOKENS=%s\nDSH_PORT=%s\n' \
    "$1" "$MODEL" "$CONTEXT_WINDOW" "$MAX_TOKENS" "$PORT"
  printf 'DSH_ROUTER_URL=%s\nDSH_BIND_IP=%s\nDSH_HONCHO_MCP_URL=%s\n' "$ROUTER_URL" "$BIND_IP" "$HONCHO_MCP_URL"
  printf 'ROUTER_KEY_SHA256=%s\nHONCHO_KEY_SHA256=%s\nFILES_SHA256=%s\n' "$2" "$3" "$4"
  printf 'DSH_OPEN_TERMINAL_URL=%s\nOPEN_TERMINAL_KEY_SHA256=%s\n' "$OPEN_TERMINAL_URL" "${ot_key_sha:-none}"
}
# release_version DIR: the dsh version installed in a release directory.
release_version() {
  [[ -f $1/node_modules/@deepseek-ai/dsh/package.json && -f $1/node_modules/@deepseek-ai/dsh/lib/bin.js ]] || return 1
  node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' \
    "$1/node_modules/@deepseek-ai/dsh/package.json"
}
# current_release: the release the service runs (the current link to
# releases/<version>_<time>_<pid>), or the
# single-directory layout of the first version of this target.
current_release() {
  if [[ -L $OPT_DIR/current ]]; then readlink -f -- "$OPT_DIR/current"
  elif [[ -d $OPT_DIR/node_modules ]]; then printf '%s\n' "$OPT_DIR"
  else return 1; fi
}
# healthy: the unit is active and the Web UI answers normally. The unauthenticated
# root request returns 401; 200 is possible when a local session is accepted.
healthy() {
  local code
  systemctl is-active --quiet deepseek-harness.service || return 1
  code=$(curl --silent --max-time 2 --output /dev/null --write-out '%{http_code}' "http://$BIND_IP:$PORT/" 2>/dev/null) || true
  [[ $code == 200 || $code == 401 ]]
}
wait_healthy() {
  local attempt
  for (( attempt=0; attempt<45; attempt++ )); do
    healthy && return 0
    sleep 2
  done
  return 1
}
node_ok() {
  command -v node >/dev/null 2>&1 &&
    node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>24 || a===24 && b>=9 ? 0 : 1)'
}
# nodesource_repo KEYRING LIST: NodeSource's signing key and apt source, both
# world-readable. This script runs under umask 077, and apt on Debian 13 checks
# signatures as its unprivileged _apt user (sqv): a root-only keyring makes
# "Permission denied" and an unsigned repository. Rewriting the files also
# repairs ones left root-only by an earlier run.
nodesource_repo() {
  local keyring=$1 list=$2
  install -d -m 0755 "$(dirname -- "$keyring")" "$(dirname -- "$list")"
  ( umask 022
    curl --fail --silent --show-error --location \
      https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
      gpg --batch --yes --dearmor -o "$keyring"
    printf 'deb [signed-by=%s] https://deb.nodesource.com/node_24.x nodistro main\n' "$keyring" > "$list" )
  chmod 0644 -- "$keyring" "$list"
}
# nodesource_readable KEYRING LIST: make a keyring and source list left by an
# earlier run readable before apt runs at all. Otherwise the first apt-get
# update (for curl and gnupg) already fails on the root-only keyring, before
# nodesource_repo could rewrite it.
nodesource_readable() {
  local file
  for file in "$@"; do
    [[ ! -e $file || -n $(find "$file" -maxdepth 0 -perm -0444) ]] || chmod 0644 -- "$file"
  done
}
# End install helpers.

if (( dry_run )); then
  printf '+ install Node.js 24 and %s@%s in %s/releases\n' "$PACKAGE" "$VERSION" "$OPT_DIR"
  printf '+ validate %s against %s and write the OSR provider overlay\n' "$MODEL" "$ROUTER_URL"
  if [[ -n $HONCHO_MCP_URL ]]; then
    printf '+ connect Honcho memory at %s (its own workspace, peers user and deepseek-harness)\n' "$HONCHO_MCP_URL"
  else
    printf '+ no Honcho memory\n'
  fi
  if [[ -n $OPEN_TERMINAL_URL ]]; then
    printf '+ connect this agent'\''s Open Terminal workspace at %s/mcp (MCP initialize with this CT'\''s key)\n' "$OPEN_TERMINAL_URL"
  fi
  printf '+ install and start deepseek-harness.service on %s:%s; roll back on failure\n' "$BIND_IP" "$PORT"
  exit 0
fi

[[ $(id -u) == 0 ]] || die 'Run as root inside the DeepSeek CT.'
install -d -m 0750 "$ETC_DIR"
exec {lock_fd}> "$ETC_DIR/.install.lock"
flock -n "$lock_fd" || die 'Another install-target.sh run holds the lock.'
# The pushed copies are one-shot inputs: gone after this run, whatever happens,
# also when the snapshot check below refuses it. Set after the lock, so a run
# refused by the lock cannot remove keys a running install is about to read.
trap 'rm -f -- "$SOURCE_DIR/router-api-key" "$SOURCE_DIR/honcho-api-key" "$SOURCE_DIR/open-terminal-key"' EXIT
# A signal (Ctrl-C, a closed SSH session, kill) must reach the EXIT trap as a
# failure so it rolls back: after a signal bash runs it with $? = 0. After a
# hangup the output goes to OSR_INTERRUPT_LOG, so writes to the closed
# terminal cannot fail the rollback.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1; exit 129' HUP
# A failed rollback snapshot takes precedence over the unchanged shortcut.
# Even a service that became healthy later must not hide manual recovery work.
[[ ! -e $ROLLBACK_DIR ]] ||
  die "A snapshot from a failed rollback is kept in $ROLLBACK_DIR; see targets/deepseek-harness/README.md before rerunning."

# Keys: a fresh copy pushed next to this script wins; otherwise the one this
# target installed before (a reconfigure that did not fetch it again).
key_source() {
  if [[ -f $SOURCE_DIR/$1 ]]; then printf '%s\n' "$SOURCE_DIR/$1"
  elif [[ -f $ETC_DIR/$1 ]]; then printf '%s\n' "$ETC_DIR/$1"
  else return 1; fi
}
router_key_file=$(key_source router-api-key) || die 'Missing router-api-key (an empty file means a keyless OSR).'
router_key=$(tr -d '\r\n' < "$router_key_file")
[[ -z $router_key || $router_key =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die 'Router key has unsupported characters.'
service_router_key=${router_key:-osr-keyless-placeholder}
honcho_key='' honcho_key_file=''
if [[ -n $HONCHO_MCP_URL ]]; then
  honcho_key_file=$(key_source honcho-api-key) || die 'DSH_HONCHO_MCP_URL needs honcho-api-key.'
  honcho_key=$(tr -d '\r\n' < "$honcho_key_file")
  [[ $honcho_key =~ ^[A-Za-z0-9._~+/=-]+$ ]] || die 'The Honcho key is empty or has unsupported characters.'
fi
ot_key=''
if [[ -n $OPEN_TERMINAL_URL ]]; then
  ot_key_file=$(key_source open-terminal-key) || die 'DSH_OPEN_TERMINAL_URL needs open-terminal-key (provision-lxc.sh pushes it).'
  ot_key=$(tr -d '\r\n\t ' < "$ot_key_file")
  [[ $ot_key =~ ^[A-Za-z0-9._~+/=-]{16,512}$ ]] || die 'The Open Terminal key is empty or has unsupported characters.'
fi
key_sha() { if [[ -n $1 ]]; then printf '%s' "$1" | sha256sum | cut -d' ' -f1; else echo none; fi; }
router_key_sha=$(key_sha "$router_key")
honcho_key_sha=$(key_sha "$honcho_key")
ot_key_sha=$(key_sha "$ot_key")
files_sha=$(cat "$SOURCE_DIR/configure.mjs" "$SOURCE_DIR/deepseek-harness.service" | sha256sum | cut -d' ' -f1)

previous_record=''
[[ ! -r $ETC_DIR/settings ]] || previous_record=$(< "$ETC_DIR/settings")
previous_release=$(current_release 2>/dev/null || true)
previous_version=''
[[ -z $previous_release ]] || previous_version=$(release_version "$previous_release" 2>/dev/null || true)
installed=false
[[ ! -f $UNIT ]] || installed=true

# unchanged VERSION: true (and says so) when a completed run installed this
# exact record and the service is healthy, so there is nothing to do.
unchanged() {
  [[ -n $previous_record && $previous_version == "$1" ]] || return 1
  [[ $(settings_record "$1" "$router_key_sha" "$honcho_key_sha" "$files_sha") == "$previous_record" ]] || return 1
  healthy || return 1
  note "DeepSeek Harness $1 is installed with these settings and running: nothing to do."
}
if [[ $VERSION != latest ]] && unchanged "$VERSION"; then exit 0; fi

export DEBIAN_FRONTEND=noninteractive
nodesource_readable /usr/share/keyrings/nodesource.gpg /etc/apt/sources.list.d/nodesource.list
if ! node_ok || ! command -v curl >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
fi
if ! node_ok; then
  note 'Installing Node.js 24 from the NodeSource signed apt repository.'
  nodesource_repo /usr/share/keyrings/nodesource.gpg /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y --no-install-recommends nodejs
fi
node_ok || die 'DeepSeek Harness requires Node.js 24.9 or newer.'
command -v npm >/dev/null || die 'npm was not installed with Node.js.'

id "$SERVICE_USER" >/dev/null 2>&1 ||
  useradd --system --create-home --home-dir "$STATE_DIR" --shell /bin/bash "$SERVICE_USER"
install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR" "$DSH_HOME_DIR" "$STATE_DIR/workspace" "$STATE_DIR/npm-cache"
install -d -m 0755 "$OPT_DIR" "$OPT_DIR/releases"
install -d -m 0700 "$(dirname -- "$ROLLBACK_DIR")"
chown "root:$SERVICE_USER" "$ETC_DIR"
as_service() { runuser -u "$SERVICE_USER" -- env HOME="$STATE_DIR" DSH_HOME="$DSH_HOME_DIR" npm_config_cache="$STATE_DIR/npm-cache" "$@"; }

if [[ $VERSION == latest ]]; then
  resolved=$(as_service npm view "$PACKAGE@latest" version 2>/dev/null | tail -n1) ||
    die "npm could not resolve $PACKAGE@latest. DeepSeek Harness was not stopped or changed."
  [[ $resolved =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]] ||
    die "npm returned an unexpected version for $PACKAGE@latest: $resolved"
  note "$PACKAGE@latest is $resolved."
  if unchanged "$resolved"; then exit 0; fi
else
  resolved=$VERSION
fi

# --- the new release, built beside the running one -----------------------
new_release=''
if [[ $previous_version == "$resolved" && $previous_release == "$OPT_DIR/releases/"* ]]; then
  release=$previous_release
  note "Keeping the installed $PACKAGE@$resolved."
else
  release=$OPT_DIR/releases/${resolved}_$(date +%Y%m%d%H%M%S)_$$
  new_release=$release
  install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$release"
  note "Installing $PACKAGE@$resolved as $SERVICE_USER."
  # npm inherits this script's umask 077: without 022 the release would be
  # owner-only, and unreadable by the service once it is handed to root below.
  if ! (umask 022; as_service npm install --prefix "$release" --no-audit --no-fund --save-exact "$PACKAGE@$resolved") ||
     [[ $(release_version "$release" 2>/dev/null || true) != "$resolved" ]]; then
    rm -rf -- "$release"
    die "npm could not install $PACKAGE@$resolved. DeepSeek Harness was not stopped or changed."
  fi
  # The agent runs as the service user; it must not be able to edit its code.
  chown -R root:root "$release"
fi
# It must read it, as "other" (the release belongs to root). Also repairs a
# reused release installed owner-only by an earlier run.
chmod -R a+rX,go-w -- "$release"

# --- snapshot, then change -------------------------------------------------
# Everything below is put back on failure when a previous install exists.
snapshot_files=("$ETC_DIR/osr.patch.yml" "$ETC_DIR/service.env" "$ETC_DIR/settings"
  "$ETC_DIR/router-api-key" "$ETC_DIR/honcho-api-key" "$UNIT" "$DSH_HOME_DIR/AGENTS.md"
  "$ETC_DIR/open-terminal-key")
take_snapshot() {
  local file i=0
  install -d -m 0700 "$ROLLBACK_DIR"
  for file in "${snapshot_files[@]}"; do
    if [[ -e $file ]]; then cp -a -- "$file" "$ROLLBACK_DIR/file.$i"; else : > "$ROLLBACK_DIR/absent.$i"; fi
    i=$((i + 1))
  done
  if [[ -d $DSH_HOME_DIR/profiles ]]; then tar -C "$DSH_HOME_DIR" -cf "$ROLLBACK_DIR/profiles.tar" profiles; fi
  printf '%s\n' "$previous_release" > "$ROLLBACK_DIR/release"
}
restore_snapshot() {
  local file i=0
  for file in "${snapshot_files[@]}"; do
    if [[ -e $ROLLBACK_DIR/file.$i ]]; then cp -a -- "$ROLLBACK_DIR/file.$i" "$file" || return 1
    else rm -f -- "$file" || return 1; fi
    i=$((i + 1))
  done
  if [[ -f $ROLLBACK_DIR/profiles.tar ]]; then
    rm -rf -- "$DSH_HOME_DIR/profiles" && tar -C "$DSH_HOME_DIR" -xpf "$ROLLBACK_DIR/profiles.tar" || return 1
  fi
  if [[ $previous_release == "$OPT_DIR/releases/"* ]]; then
    ln -sfn -- "$previous_release" "$OPT_DIR/current" || return 1
  else
    rm -f -- "$OPT_DIR/current" || return 1
  fi
  systemctl daemon-reload
}
clear_snapshot() { rm -rf -- "$ROLLBACK_DIR"; }

phase=prepare restarted=false
on_exit() {
  local status=$1
  trap - EXIT
  trap '' INT TERM HUP  # the rollback below must finish
  rm -f -- "$SOURCE_DIR/router-api-key" "$SOURCE_DIR/honcho-api-key" "$SOURCE_DIR/open-terminal-key"
  if (( status == 0 )); then return 0; fi
  # A failed upgrade goes back to the previous release; a failed first
  # install keeps its release for inspection (a rerun reuses it).
  [[ -z $new_release || $installed == false || $phase == finished ]] || rm -rf -- "$new_release"
  if [[ $phase == finished ]]; then
    note 'DeepSeek Harness is installed and running; only removing old releases failed.'
  elif [[ $phase == prepare ]]; then
    note 'DeepSeek Harness was not stopped or changed.'
  elif [[ $installed == false ]]; then
    note 'The first install failed; the CT keeps its files for inspection. Rerun with --reconfigure after fixing the cause.'
    clear_snapshot
  elif ! restore_snapshot; then
    note "Restoring the previous configuration failed; the snapshot is kept in $ROLLBACK_DIR."
  elif [[ $restarted == false ]]; then
    note 'The previous configuration is back. DeepSeek Harness was not stopped or changed.'
    clear_snapshot
  else
    note "Rolling back to ${previous_version:-the previous release}."
    if systemctl restart deepseek-harness.service && wait_healthy; then
      note "DeepSeek Harness ${previous_version:-(previous release)} is running again."
      clear_snapshot
    else
      journalctl -u deepseek-harness.service -n 40 --no-pager >&2 || true
      note "Rollback to ${previous_version:-the previous release} failed too: it did not become healthy either. The snapshot is kept in $ROLLBACK_DIR."
    fi
  fi
  exit "$status"
}
trap 'on_exit $?' EXIT

if $installed; then take_snapshot; fi
phase=configure
for name in router-api-key honcho-api-key open-terminal-key; do
  if [[ -f $SOURCE_DIR/$name ]]; then install -m 0600 "$SOURCE_DIR/$name" "$ETC_DIR/$name"; fi
done
[[ -n $HONCHO_MCP_URL ]] || rm -f -- "$ETC_DIR/honcho-api-key"
[[ -n $OPEN_TERMINAL_URL ]] || rm -f -- "$ETC_DIR/open-terminal-key"

overlay_tmp=$(mktemp "$ETC_DIR/osr.patch.yml.XXXXXX")
configure_args=(--router-url "$ROUTER_URL" --model "$MODEL" --context-window "$CONTEXT_WINDOW"
  --max-tokens "$MAX_TOKENS" --output "$overlay_tmp" --force --instructions "$DSH_HOME_DIR/AGENTS.md")
[[ -z $HONCHO_MCP_URL ]] || configure_args+=(--honcho-mcp-url "$HONCHO_MCP_URL")
[[ -z $OPEN_TERMINAL_URL ]] || configure_args+=(--open-terminal-url "$OPEN_TERMINAL_URL")
if ! OSR_API_KEY="$service_router_key" HONCHO_API_KEY="$honcho_key" OSR_OPEN_TERMINAL_KEY="$ot_key" \
    node "$SOURCE_DIR/configure.mjs" "${configure_args[@]}"; then
  rm -f -- "$overlay_tmp"
  die 'The OSR, Honcho or Open Terminal check failed (above).'
fi
[[ ! -f $DSH_HOME_DIR/AGENTS.md ]] || { chown "$SERVICE_USER:$SERVICE_USER" "$DSH_HOME_DIR/AGENTS.md"; chmod 0640 "$DSH_HOME_DIR/AGENTS.md"; }
install -m 0640 -g "$SERVICE_USER" "$overlay_tmp" "$ETC_DIR/osr.patch.yml"
rm -f -- "$overlay_tmp"

# systemd reads this root-only file and sets the keys in the unprivileged
# process environment. They never reach argv, the unit or the patch.
service_env=$(mktemp "$ETC_DIR/service.env.XXXXXX")
{
  printf 'OSR_API_KEY=%s\n' "$service_router_key"
  [[ -z $honcho_key ]] || printf 'HONCHO_API_KEY=%s\n' "$honcho_key"
  [[ -z $ot_key ]] || printf 'OSR_OPEN_TERMINAL_KEY=%s\n' "$ot_key"
  printf 'DSH_HOME=%s\nDSH_BIND_IP=%s\nDSH_PORT=%s\n' "$DSH_HOME_DIR" "$BIND_IP" "$PORT"
} > "$service_env"
chmod 0600 "$service_env"
mv -f -- "$service_env" "$ETC_DIR/service.env"

# A configuration dump with the new release validates DeepSeek's patch syntax
# without a model request. Keep the dump private: it shows the composition.
dump=$(mktemp)
if ! runuser -u "$SERVICE_USER" -- env HOME="$STATE_DIR" DSH_HOME="$DSH_HOME_DIR" \
    node "$release/node_modules/@deepseek-ai/dsh/lib/bin.js" \
    --profile web --patch "$ETC_DIR/osr.patch.yml" --dump-config > "$dump" 2>&1; then
  tail -n 40 "$dump" >&2
  rm -f -- "$dump"
  die 'DeepSeek rejected the generated patch.'
fi
rm -f -- "$dump"

install -m 0644 "$SOURCE_DIR/deepseek-harness.service" "$UNIT"
ln -sfn -- "$release" "$OPT_DIR/current"
systemctl daemon-reload
systemctl enable deepseek-harness.service
phase=restart restarted=true
systemctl restart deepseek-harness.service
if ! wait_healthy; then
  journalctl -u deepseek-harness.service -n 60 --no-pager >&2 || true
  die "DeepSeek Harness $resolved did not become healthy within 90 seconds."
fi

settings_record "$resolved" "$router_key_sha" "$honcho_key_sha" "$files_sha" > "$ETC_DIR/settings.new"
chmod 0640 "$ETC_DIR/settings.new"
mv -f -- "$ETC_DIR/settings.new" "$ETC_DIR/settings"
phase=finished
clear_snapshot
# Only the running release stays; the first layout of this target is removed.
for old in "$OPT_DIR"/releases/*; do
  [[ $old == "$release" || ! -d $old ]] || rm -rf -- "$old"
done
if [[ -d $OPT_DIR/node_modules ]]; then
  rm -rf -- "$OPT_DIR/node_modules" "$OPT_DIR/package.json" "$OPT_DIR/package-lock.json"
fi
note "DeepSeek Harness $resolved is serving on http://$BIND_IP:$PORT/ (open the tokenized URL from its journal)."
if [[ -n $HONCHO_MCP_URL ]]; then note "Honcho memory: $HONCHO_MCP_URL (its own workspace, peer user)."; fi
if [[ -n $OPEN_TERMINAL_URL ]]; then note "Open Terminal workspace: $OPEN_TERMINAL_URL (tools mcp__open_terminal__*)."; fi
