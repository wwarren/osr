#!/usr/bin/env bash
# Add hcom to an EXISTING agent CT; this target does not create another agent.
set -Eeuo pipefail
umask 077
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$here/pve-select.sh"

usage() {
  cat <<'EOF'
Usage: bash targets/hcom/provision-lxc.sh [--reconfigure] [--dry-run]

Adds hcom to an EXISTING container; it creates none. Run as root on the
Proxmox host. In a terminal it asks for every setting below that is not set,
offering CTs by their tags. Unattended runs must preset the required ones.

Settings (environment variables):
  HCOM_TARGET         required  What the CT runs: hermes, openclaw or
                                deepseek-harness (an agent), or observer (no
                                agent; forwards handoffs to Mattermost).
  CT_ID               required  The existing CT to add hcom to. Offered: the CT
                                tagged with HCOM_TARGET (observer: the broker).
  MQTT_CT_ID          required  The broker CT made by targets/mqtt (tag mqtt);
                                its relay bundle is copied over privately.
  MATTERMOST_CT_ID    observer  The Mattermost CT to create the agent-handoffs
                                webhook in (tag mattermost). "none": keep the
                                observer's current webhook, or post nothing.
  HCOM_HERMES_NATIVE  hermes    true: Hermes's native hcom plugin, which gives
                                Hermes the relay key. Default false.
  HCOM_INSTRUCTIONS_FILE        A custom AGENTS.md for the managed block.

Options:
  --reconfigure  The CT already has hcom: asks for it first, then defaults to
                 the target, native mode and Mattermost it recorded.
  --dry-run      Print the plan and change nothing.
  -h, --help     This help.

Examples:
  bash targets/hcom/provision-lxc.sh --reconfigure        # asks
  CT_ID=282 MQTT_CT_ID=286 HCOM_TARGET=hermes bash targets/hcom/provision-lxc.sh
  CT_ID=286 MQTT_CT_ID=286 HCOM_TARGET=observer MATTERMOST_CT_ID=277 \
    bash targets/hcom/provision-lxc.sh
EOF
}

dry_run=0 reconfigure=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    --reconfigure) reconfigure=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $arg (see --help)" ;;
  esac
done

valid_target() { [[ $1 =~ ^(hermes|openclaw|deepseek-harness|observer)$ ]]; }
valid_optional_ct() { [[ -z $1 ]] || pve_valid_ct_id "$1"; }
for setting in CT_ID MQTT_CT_ID MATTERMOST_CT_ID; do
  [[ -z ${!setting:-} ]] || pve_valid_ct_id "${!setting}" || die "$setting must be a CT ID (100 or more), not '${!setting}'."
done
[[ -z ${HCOM_TARGET:-} ]] || valid_target "$HCOM_TARGET" ||
  die "HCOM_TARGET must be hermes, openclaw, deepseek-harness or observer, not '$HCOM_TARGET'."
[[ -z ${HCOM_HERMES_NATIVE:-} || $HCOM_HERMES_NATIVE =~ ^(true|false)$ ]] ||
  die "HCOM_HERMES_NATIVE must be true or false, not '$HCOM_HERMES_NATIVE'."
if ! pve_interactive; then
  missing=()
  [[ -n ${CT_ID:-} ]] || missing+=('CT_ID (the existing CT)')
  [[ -n ${MQTT_CT_ID:-} ]] || missing+=('MQTT_CT_ID (the broker CT)')
  # A reconfigure can take the target the CT recorded.
  [[ -n ${HCOM_TARGET:-} ]] || (( reconfigure )) || missing+=('HCOM_TARGET (hermes, openclaw, deepseek-harness or observer)')
  if (( ${#missing[@]} )); then
    printf 'Error: not running in a terminal, so nothing can be asked. Set:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf 'Or run it in a terminal on the PVE host to be asked. See --help.\n' >&2
    exit 1
  fi
fi

# What an earlier run recorded in the CT: its target, native Hermes mode, an
# observer's Mattermost webhook, and the broker address. Read only from a
# running CT, and not on a dry run (which makes no Proxmox queries).
recorded=''
read_recorded() {
  (( ! dry_run )) && command -v pct >/dev/null 2>&1 || return 0
  pct status "$CT_ID" 2>/dev/null | grep -q running || return 0
  recorded=$(pct exec "$CT_ID" -- sh -c '
    [ -r /etc/osr-hcom/target ] && echo "target=$(tr -d "[:space:]" < /etc/osr-hcom/target)"
    if grep -qs "\"relay_user\": \"hermes\"" /etc/osr-hcom/bus.json || [ -d /home/hermes/.hermes/plugins/hcom ]; then
      echo native=true
    fi
    [ -e /etc/osr-hcom/mattermost-webhook ] && echo mattermost=true
    for f in /var/lib/osr-hcom/.osr-hcom/config.toml /home/hermes/.osr-hcom/config.toml; do
      [ -r "$f" ] && sed -n "s|^url = \"mqtts\{0,1\}://\([^:/\"]*\).*|broker=\1|p" "$f" && break
    done
    exit 0' </dev/null 2>/dev/null || true)
}
recorded_value() { sed -n "s/^$1=//p" <<< "$recorded" | head -n 1; }

if (( reconfigure )); then
  pve_section 'hcom container to reconfigure'
  pve_suggest CT_ID 'CT ID with hcom' '' pve_valid_ct_id 'Use the existing CT ID (100 or more).'
  read_recorded
fi
pve_section 'hcom target'
pve_note 'hermes, openclaw or deepseek-harness: the agent this CT runs.'
pve_note 'observer: no agent; forwards handoffs to Mattermost (one per relay group).'
if [[ -n $(recorded_value target) ]]; then
  pve_ask HCOM_TARGET 'Target (hermes, openclaw, deepseek-harness, observer)' "$(recorded_value target)" valid_target 'Use hermes, openclaw, deepseek-harness or observer.'
else
  pve_suggest HCOM_TARGET 'Target (hermes, openclaw, deepseek-harness, observer)' '' valid_target 'Use hermes, openclaw, deepseek-harness or observer.'
fi
case $HCOM_TARGET in
  hermes) name=Hermes ;; openclaw) name=OpenClaw ;; deepseek-harness) name='DeepSeek Harness' ;; *) name=Observer ;;
esac
if (( ! reconfigure )); then
  pve_section "$name container"
  if [[ $HCOM_TARGET == observer ]]; then
    pve_note 'Any existing CT with Python 3.11+; the broker CT is a common choice.'
    tag=mqtt
  else
    tag=$HCOM_TARGET
  fi
  pve_suggest CT_ID "Existing $name CT ID" "$(pve_tagged_ct "$tag")" pve_valid_ct_id 'Use the existing CT ID (100 or more).'
  read_recorded
fi
pve_section 'MQTT broker'
broker_ct=''
[[ -z $(recorded_value broker) ]] || broker_ct=$(pve_ct_with_ip "$(recorded_value broker)")
pve_suggest MQTT_CT_ID 'MQTT broker CT ID' "${broker_ct:-$(pve_tagged_ct mqtt)}" pve_valid_ct_id \
  'Use the CT ID of the broker made by targets/mqtt.'
if [[ $HCOM_TARGET == observer ]]; then
  pve_section 'Mattermost handoffs'
  if [[ $(recorded_value mattermost) == true ]]; then
    pve_note 'This observer already posts to Mattermost; "none" keeps its current webhook.'
  else
    pve_note 'The agent-handoffs channel and webhook are created there; "none" posts nothing.'
  fi
  pve_offer MATTERMOST_CT_ID 'Mattermost CT ID' "$(pve_tagged_ct mattermost)" valid_optional_ct 'Use a CT ID, or none.'
elif [[ -n ${MATTERMOST_CT_ID:-} ]]; then
  die "MATTERMOST_CT_ID is for HCOM_TARGET=observer only (this run is $HCOM_TARGET)."
fi
if [[ $HCOM_TARGET == hermes ]]; then
  pve_section 'Hermes'
  pve_note "Native mode adds Hermes's own hcom plugin for messaging-platform chats; it gives Hermes the relay key."
  recorded_native=$(recorded_value native)
  pve_ask_yes_no HCOM_HERMES_NATIVE "Use Hermes's native hcom plugin?" "${recorded_native:-false}"
elif [[ ${HCOM_HERMES_NATIVE:-false} == true ]]; then
  die "HCOM_HERMES_NATIVE=true is for HCOM_TARGET=hermes only (this run is $HCOM_TARGET)."
fi
native=${HCOM_HERMES_NATIVE:-false}

if (( reconfigure )); then verb=Reconfigure; else verb=Install; fi
pve_summary "hcom: ${verb,,} in CT $CT_ID"
pve_row 'Target' "$HCOM_TARGET"
pve_row 'CT' "$CT_ID"
pve_row 'MQTT broker CT' "$MQTT_CT_ID"
if [[ $HCOM_TARGET == observer ]]; then
  if [[ -n ${MATTERMOST_CT_ID:-} ]]; then pve_row 'Mattermost CT' "$MATTERMOST_CT_ID"
  elif [[ $(recorded_value mattermost) == true ]]; then pve_row 'Mattermost' 'keep the current webhook'
  else pve_row 'Mattermost' 'none'; fi
fi
[[ $HCOM_TARGET != hermes ]] || pve_row 'Native Hermes plugin' "$native"
[[ -z ${HCOM_INSTRUCTIONS_FILE:-} ]] || pve_row 'Instructions file' "$HCOM_INSTRUCTIONS_FILE"
pve_confirm "$verb hcom in CT $CT_ID?"

fw=/etc/pve/firewall/$CT_ID.fw
if (( dry_run )); then
  printf '+ copy private relay bundle from broker CT %s to existing %s CT %s\n' "$MQTT_CT_ID" "$HCOM_TARGET" "$CT_ID"
  printf '+ if CT %s restricts outbound traffic, allow it to reach the broker%s\n' "$CT_ID" "${MATTERMOST_CT_ID:+ and Mattermost}"
  printf '+ install hcom, the relay account and the agent bus socket\n'
  [[ -z ${MATTERMOST_CT_ID:-} ]] || printf '+ configure dedicated agent-handoffs webhook in Mattermost CT %s; install observer notifier\n' "$MATTERMOST_CT_ID"
  exit 0
fi
[[ $EUID == 0 ]] || die 'Run as root on the Proxmox host.'
for id in "$CT_ID" "$MQTT_CT_ID" "${MATTERMOST_CT_ID:-}"; do
  [[ -z $id ]] || pct status "$id" 2>/dev/null | grep -q running ||
    die "CT $id must exist and be running (pct status $id)."
done
stage=$(mktemp -d)
fw_changed=false
cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 )) && $fw_changed; then
    # Restore the rule even if staging or a pct push failed before the guest
    # installer started. The swap refuses to overwrite concurrent edits.
    perl "$here/../pve-firewall-swap.pl" "$fw" "$stage/firewall" "$stage/firewall.before" "$CT_ID" /etc/pve ||
      echo "Could not restore CT $CT_ID's previous firewall; check the '# osr-hcom-' rules." >&2
  fi
  pct exec "$CT_ID" -- rm -rf /root/osr-hcom-setup 2>/dev/null || true
  [[ -z ${MATTERMOST_CT_ID:-} ]] || pct exec "$MATTERMOST_CT_ID" -- rm -f /root/osr-agent-handoffs-setup.sh 2>/dev/null || true
  rm -rf -- "$stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
pct pull "$MQTT_CT_ID" /etc/mqtt-target/relay.json "$stage/relay.json"
chmod 0600 "$stage/relay.json"
if [[ -n ${MATTERMOST_CT_ID:-} ]]; then
  pct push "$MATTERMOST_CT_ID" "$here/../mattermost/configure-agent-handoffs.sh" /root/osr-agent-handoffs-setup.sh --perms 0600
  pct exec "$MATTERMOST_CT_ID" -- bash /root/osr-agent-handoffs-setup.sh
  pct pull "$MATTERMOST_CT_ID" /etc/mattermost-target/agent-handoffs-webhook-url "$stage/webhook"
  chmod 0600 "$stage/webhook"
fi

# A CT with restricted egress (Hermes and OpenClaw default to policy_out: DROP)
# gets owned allow rules for the broker (and, for an observer, Mattermost);
# see firewall_rules.py. The Hermes/OpenClaw provisioners keep lines they do not own.
if [[ -f $fw ]] && python3 "$here/firewall_rules.py" restricted "$fw"; then
  python3 "$here/firewall_rules.py" endpoints "$stage/relay.json" ${MATTERMOST_CT_ID:+"$stage/webhook"} > "$stage/endpoints" ||
    die 'Could not work out the firewall rule.'
  cp "$fw" "$stage/firewall.before"
  python3 "$here/firewall_rules.py" insert "$stage/firewall.before" "$stage/firewall" "$stage/endpoints"
  if ! cmp -s "$stage/firewall.before" "$stage/firewall"; then
    perl "$here/../pve-firewall-swap.pl" "$fw" "$stage/firewall.before" "$stage/firewall" "$CT_ID" /etc/pve ||
      die "CT $CT_ID's firewall changed meanwhile or could not be written; rerun."
    fw_changed=true
    echo "CT $CT_ID restricts outbound traffic: allowed it to reach the broker${MATTERMOST_CT_ID:+ and Mattermost}."
  fi
fi

pct exec "$CT_ID" -- install -d -m 0700 /root/osr-hcom-setup
for file in install-target.sh install-state.sh bus_config.py bus_server.py osr_bus.py mattermost_bridge.py; do
  pct push "$CT_ID" "$here/$file" "/root/osr-hcom-setup/$file" --perms 0600
done
pct push "$CT_ID" "$stage/relay.json" /root/osr-hcom-setup/relay.json --perms 0600
env_args=("HCOM_TARGET=$HCOM_TARGET" HCOM_RELAY_BUNDLE=/root/osr-hcom-setup/relay.json "HCOM_HERMES_NATIVE=$native")
[[ -z ${HCOM_INSTRUCTIONS_FILE:-} ]] || env_args+=("HCOM_INSTRUCTIONS_FILE=$HCOM_INSTRUCTIONS_FILE")
if [[ -n ${MATTERMOST_CT_ID:-} ]]; then
  pct push "$CT_ID" "$stage/webhook" /root/osr-hcom-setup/webhook --perms 0600
  env_args+=(HCOM_MATTERMOST_WEBHOOK_FILE=/root/osr-hcom-setup/webhook)
fi
pct exec "$CT_ID" -- env "${env_args[@]}" bash /root/osr-hcom-setup/install-target.sh
