#!/usr/bin/env bash
# A separate channel-bound webhook; never repurpose the health monitor's hook.
set -Eeuo pipefail
umask 077
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
etc=${MM_TARGET_ETC:-/etc/mattermost-target}
mmctl=${MMCTL:-/opt/mattermost/bin/mmctl}
service_user=${MM_SERVICE_USER:-mattermost}
team=${MATTERMOST_TEAM:-ollama}
channel=${HCOM_MATTERMOST_CHANNEL:-agent-handoffs}
[[ $team =~ ^[a-z0-9][a-z0-9_-]{1,63}$ && $channel =~ ^[a-z0-9][a-z0-9_-]{1,63}$ ]] || die 'Invalid team or handoff channel.'
[[ $channel != "${MATTERMOST_CHANNEL:-ollama-monitor}" ]] || die 'Handoffs must use a channel separate from health alerts.'
dry_run=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'Usage: bash configure-agent-handoffs.sh [--dry-run]'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done
if (( dry_run )); then
  printf '+ keep/create %s:%s and its own webhook in %s/agent-handoffs-webhook-url\n' "$team" "$channel" "$etc"
  exit 0
fi
[[ $EUID == 0 && -x $mmctl && -s $etc/admin-user && -s $etc/url ]] || die 'Configure the Mattermost target first.'
exec {lock_fd}>"$etc/agent-handoffs.lock"
flock -n "$lock_fd" || die 'Another handoff setup is running.'
mm() { runuser -u "$service_user" -- "$mmctl" --local --suppress-warnings "$@"; }
find_field() {
  python3 -c '
import json,sys
text=sys.stdin.read(); decoder=json.JSONDecoder(); rows=[]
while text.strip():
    item,end=decoder.raw_decode(text.lstrip()); text=text.lstrip()[end:]
    rows.extend(item if isinstance(item,list) else [item])
for row in rows:
    if str(row.get(sys.argv[1],"")) == sys.argv[2]:
        print(row[sys.argv[3]]); sys.exit(0)
sys.exit(1)
' "$@"
}
admin=$(<"$etc/admin-user")
admin_id=$(mm --json user list --all | find_field username "$admin" id)
if ! channel_id=$(mm --json channel list "$team" | find_field name "$channel" id); then
  mm channel create --team "$team" --name "$channel" --display-name 'Agent handoffs' >/dev/null
  channel_id=$(mm --json channel list "$team" | find_field name "$channel" id)
fi
# Reject even a custom health channel whose name was not supplied to this run.
if [[ -s $etc/webhook-url ]]; then
  health=$(<"$etc/webhook-url")
  health_channel=$(mm --json webhook list-incoming | find_field id "${health##*/}" channel_id) || die 'Cannot verify health webhook separation.'
  [[ $channel_id != "$health_channel" ]] || die 'Selected handoff channel is the health channel.'
fi
mm channel users add "$team:$channel" "$admin" >/dev/null 2>&1 || true
saved=$etc/agent-handoffs-webhook-url
url=$(<"$etc/url"); url=${url%/}
hook=''
if [[ -s $saved ]]; then
  old=$(<"$saved"); old_id=${old##*/}
  if [[ $old == "$url/hooks/$old_id" ]] && \
     [[ $(mm --json webhook list-incoming | find_field id "$old_id" channel_id || true) == "$channel_id" ]]; then hook=$old_id; fi
fi
if [[ -z $hook ]]; then
  hook=$(mm --json webhook create-incoming --channel "$channel_id" --user "$admin_id" \
    --display-name 'OSR Agent Bus' --description 'Real-time agent handoffs, separate from health alerts' |
    find_field channel_id "$channel_id" id)
fi
[[ $hook =~ ^[a-z0-9]{26}$ ]] || die 'Unexpected incoming webhook ID.'
printf '%s/hooks/%s\n' "$url" "$hook" > "$saved.new"
chmod 0600 "$saved.new"
mv -f "$saved.new" "$saved"
printf 'Handoff webhook ready in %s (secret URL omitted).\n' "$saved"
