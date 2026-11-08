#!/usr/bin/env bash
# Run as root in the Mattermost CT made by the Proxmox VE community script
# (provision-lxc.sh pushes and runs this). It does the first-run setup the
# browser would, with mmctl in local mode, and prepares the router's alerts:
#
#   * local mode, through a systemd drop-in (MM_SERVICESETTINGS_ENABLELOCALMODE):
#     mmctl then talks to the server over a socket only root and the
#     mattermost account can open
#   * an administrator (password in /etc/mattermost-target/admin-password),
#     a team and the alert channel
#   * incoming webhooks and username/icon overrides enabled (the monitor posts
#     as MATTERMOST_MONITOR_USER), and one incoming webhook for the channel,
#     whose URL is written to /etc/mattermost-target/webhook-url
#
# Reruns keep what exists: accounts, team and channel are never recreated, and
# a webhook that still exists is kept.
#   bash install-target.sh            configure, or check and repair
#   bash install-target.sh --dry-run  print the plan; change nothing
set -Eeuo pipefail
umask 077

# Paths are overridable for tests only; the community script uses these.
MM_HOME=${MM_HOME:-/opt/mattermost}
MMCTL=${MMCTL:-$MM_HOME/bin/mmctl}
MM_SERVICE_USER=${MM_SERVICE_USER:-mattermost}
MM_TARGET_ETC=${MM_TARGET_ETC:-/etc/mattermost-target}
MM_DROPIN_DIR=${MM_DROPIN_DIR:-/etc/systemd/system/mattermost.service.d}
MM_SOCKET=${MM_SOCKET:-/var/tmp/mattermost_local.socket}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-180}
MM_PORT=8065

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'USAGE'
Usage: bash install-target.sh [--dry-run]

Settings (environment; all optional):
  MATTERMOST_TEAM=ollama               team (its URL name)
  MATTERMOST_CHANNEL=ollama-monitor    alert channel (its URL name)
  MATTERMOST_ADMIN_USER=mmadmin        administrator account
  MATTERMOST_ADMIN_EMAIL=<admin>@<host>.local
Results (root-only, 0600) in /etc/mattermost-target: url, admin-user,
admin-password, webhook-url.
USAGE
}

# Install helpers (sourced by test-install.sh) -------------------------------

valid_handle() { [[ $1 =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; }
valid_username() { [[ $1 =~ ^[a-z][a-z0-9._-]{2,21}$ ]]; }
valid_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

# json_find FIELD VALUE [RESULT]: from mmctl --json output on stdin (an object,
# a list, or one object per line), the RESULT field (default id) of the first
# object whose FIELD equals VALUE. Exit 1 when none matches.
json_find() {
  python3 -c '
import json, sys
field, value = sys.argv[1], sys.argv[2]
result = sys.argv[3] if len(sys.argv) > 3 else "id"
text = sys.stdin.read()
items = []
try:
    data = json.loads(text)
    items = data if isinstance(data, list) else [data]
except ValueError:
    decoder, pos = json.JSONDecoder(), 0
    while pos < len(text):
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            break
        try:
            obj, pos = decoder.raw_decode(text, pos)
        except ValueError:
            break
        items.extend(obj if isinstance(obj, list) else [obj])
for item in items:
    if isinstance(item, dict) and str(item.get(field, "")).lower() == value.lower():
        print(item.get(result, ""))
        sys.exit(0)
sys.exit(1)
' "$@"
}

# config_value < `mmctl config get` output: the value without JSON quotes.
config_value() {
  python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    value = json.loads(raw)
except ValueError:
    value = raw
print(value if isinstance(value, str) else json.dumps(value))
'
}

# dropin: the systemd drop-in that turns local mode on.
dropin() {
  printf '%s\n' '# Written by the ollama-smart-router mattermost target: lets mmctl --local' \
    '# manage this server over a socket only root and the mattermost account can open.' \
    '[Service]' 'Environment=MM_SERVICESETTINGS_ENABLELOCALMODE=true'
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

MATTERMOST_TEAM=${MATTERMOST_TEAM:-ollama}
MATTERMOST_CHANNEL=${MATTERMOST_CHANNEL:-ollama-monitor}
MATTERMOST_ADMIN_USER=${MATTERMOST_ADMIN_USER:-mmadmin}
host=$(hostname 2>/dev/null || echo mattermost)
host=${host//[^A-Za-z0-9.-]/}
MATTERMOST_ADMIN_EMAIL=${MATTERMOST_ADMIN_EMAIL:-$MATTERMOST_ADMIN_USER@${host:-mattermost}.local}

valid_handle "$MATTERMOST_TEAM" || die "MATTERMOST_TEAM '$MATTERMOST_TEAM' must be a URL name (lowercase letters, digits, - and _)."
(( ${#MATTERMOST_TEAM} >= 2 )) || die 'MATTERMOST_TEAM must be at least 2 characters.'
valid_handle "$MATTERMOST_CHANNEL" || die "MATTERMOST_CHANNEL '$MATTERMOST_CHANNEL' must be a URL name (lowercase letters, digits, - and _)."
(( ${#MATTERMOST_CHANNEL} >= 2 )) || die 'MATTERMOST_CHANNEL must be at least 2 characters.'
valid_username "$MATTERMOST_ADMIN_USER" || die "MATTERMOST_ADMIN_USER '$MATTERMOST_ADMIN_USER' must be 3-22 lowercase letters, digits, . _ or -, starting with a letter."
valid_email "$MATTERMOST_ADMIN_EMAIL" || die 'Invalid MATTERMOST_ADMIN_EMAIL.'
[[ $HEALTH_TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die 'Invalid HEALTH_TIMEOUT.'

if (( dry_run )); then
  printf '+ write %s/10-local-mode.conf (MM_SERVICESETTINGS_ENABLELOCALMODE=true); restart mattermost\n' "$MM_DROPIN_DIR"
  printf '+ wait for http://127.0.0.1:%s/api/v4/system/ping and %s\n' "$MM_PORT" "$MM_SOCKET"
  printf '+ create administrator %s (password in %s/admin-password), team %s, channel %s if missing\n' \
    "$MATTERMOST_ADMIN_USER" "$MM_TARGET_ETC" "$MATTERMOST_TEAM" "$MATTERMOST_CHANNEL"
  printf '+ enable incoming webhooks and username/icon overrides\n'
  printf '+ create an incoming webhook for %s:%s; its URL in %s/webhook-url\n' \
    "$MATTERMOST_TEAM" "$MATTERMOST_CHANNEL" "$MM_TARGET_ETC"
  exit 0
fi

[[ $EUID -eq 0 ]] || die 'Run as root inside the Mattermost CT.'
[[ -x $MMCTL ]] || die "No mmctl at $MMCTL. Create the CT with provision-lxc.sh (the community script) first."
id "$MM_SERVICE_USER" >/dev/null 2>&1 || die "The $MM_SERVICE_USER account is missing; this is not a community-script Mattermost CT."
command -v python3 >/dev/null || die 'python3 is required (the community script installs it).'
command -v openssl >/dev/null || die 'openssl is required.'

mm() { runuser -u "$MM_SERVICE_USER" -- "$MMCTL" --local --suppress-warnings "$@"; }
mm_json() { mm --json "$@"; }
mm_ready() {
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$MM_PORT/api/v4/system/ping" 2>/dev/null &&
       [[ -S $MM_SOCKET ]] && mm system version >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

install -d -m 0700 "$MM_TARGET_ETC"

# --- local mode -----------------------------------------------------------------------
install -d -m 0755 "$MM_DROPIN_DIR"
if [[ "$(cat "$MM_DROPIN_DIR/10-local-mode.conf" 2>/dev/null)" != "$(dropin)" ]]; then
  dropin > "$MM_DROPIN_DIR/10-local-mode.conf"
  chmod 0644 "$MM_DROPIN_DIR/10-local-mode.conf"
  systemctl daemon-reload
  systemctl restart mattermost.service
  note 'Enabled mmctl local mode (systemd drop-in) and restarted Mattermost.'
fi
mm_ready || die "Mattermost or its local socket $MM_SOCKET did not come up within ${HEALTH_TIMEOUT}s; see: journalctl -u mattermost"

site_url=$(mm config get ServiceSettings.SiteURL 2>/dev/null | config_value || true)
if [[ -z $site_url ]]; then
  address=$(hostname -I 2>/dev/null | awk '{ print $1 }')
  [[ -n $address ]] || die 'Mattermost has no SiteURL and this CT reports no address.'
  site_url="http://$address:$MM_PORT"
  mm config set ServiceSettings.SiteURL "$site_url" >/dev/null
fi
site_url=${site_url%/}
write_secret "$MM_TARGET_ETC/url" "$site_url"

# --- administrator, team, channel -------------------------------------------------------
if admin_id=$(mm_json user list --all | json_find username "$MATTERMOST_ADMIN_USER"); then
  note "Administrator $MATTERMOST_ADMIN_USER exists."
else
  password="$(openssl rand -base64 24 | tr -d '/+=\n' | head -c 20)Aa1!"
  # Saved before the account exists, so a failure never loses the password.
  write_secret "$MM_TARGET_ETC/admin-password" "$password"
  mm user create --email "$MATTERMOST_ADMIN_EMAIL" --username "$MATTERMOST_ADMIN_USER" \
    --password "$password" --system-admin --email-verified --disable-welcome-email >/dev/null
  unset password
  admin_id=$(mm_json user list --all | json_find username "$MATTERMOST_ADMIN_USER") ||
    die "The administrator $MATTERMOST_ADMIN_USER was not created."
  note "Created administrator $MATTERMOST_ADMIN_USER."
fi
write_secret "$MM_TARGET_ETC/admin-user" "$MATTERMOST_ADMIN_USER"

if mm_json team list | json_find name "$MATTERMOST_TEAM" >/dev/null; then
  note "Team $MATTERMOST_TEAM exists."
else
  mm team create --name "$MATTERMOST_TEAM" --display-name "Ollama Smart Router" >/dev/null
  note "Created the team $MATTERMOST_TEAM."
fi
# Already a member is fine; anything else only costs the admin the UI view.
mm team users add "$MATTERMOST_TEAM" "$MATTERMOST_ADMIN_USER" >/dev/null 2>&1 ||
  note "Note: could not add $MATTERMOST_ADMIN_USER to $MATTERMOST_TEAM (already a member?)."

if channel_id=$(mm_json channel list "$MATTERMOST_TEAM" | json_find name "$MATTERMOST_CHANNEL"); then
  note "Channel $MATTERMOST_CHANNEL exists."
else
  mm channel create --team "$MATTERMOST_TEAM" --name "$MATTERMOST_CHANNEL" --display-name "Ollama monitor" >/dev/null
  channel_id=$(mm_json channel list "$MATTERMOST_TEAM" | json_find name "$MATTERMOST_CHANNEL") ||
    die "The channel $MATTERMOST_CHANNEL was not created."
  note "Created the channel $MATTERMOST_CHANNEL."
fi
mm channel users add "$MATTERMOST_TEAM:$MATTERMOST_CHANNEL" "$MATTERMOST_ADMIN_USER" >/dev/null 2>&1 || true

# --- webhooks ------------------------------------------------------------------------------
for setting in ServiceSettings.EnableIncomingWebhooks ServiceSettings.EnablePostUsernameOverride \
               ServiceSettings.EnablePostIconOverride; do
  mm config set "$setting" true >/dev/null
done

hook_id=''
if [[ -s $MM_TARGET_ETC/webhook-url ]]; then
  saved=$(tr -d '\r\n' < "$MM_TARGET_ETC/webhook-url")
  saved_id=${saved##*/hooks/}
  if [[ $saved == "$site_url/hooks/$saved_id" && -n $saved_id ]] &&
     mm_json webhook list-incoming | json_find id "$saved_id" channel_id | grep -qx "$channel_id"; then
    hook_id=$saved_id
    note "The webhook in $MM_TARGET_ETC/webhook-url still exists; kept."
  fi
fi
if [[ -z $hook_id ]]; then
  hook_id=$(mm_json webhook create-incoming --channel "$channel_id" --user "$admin_id" \
    --display-name "Ollama Smart Router monitor" --description "Health alerts from ollama-monitor" |
    json_find channel_id "$channel_id" id) || die 'Mattermost did not return the new webhook.'
  [[ $hook_id =~ ^[a-z0-9]{26}$ ]] || die "Unexpected webhook id: $hook_id"
  write_secret "$MM_TARGET_ETC/webhook-url" "$site_url/hooks/$hook_id"
  note "Created the incoming webhook for $MATTERMOST_TEAM:$MATTERMOST_CHANNEL."
fi

note "Mattermost is ready at $site_url. Alerts go to $MATTERMOST_TEAM:$MATTERMOST_CHANNEL."
