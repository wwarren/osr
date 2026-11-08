#!/usr/bin/env bash
# Add hcom to an EXISTING agent CT; this target does not create another agent.
set -Eeuo pipefail
umask 077
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
dry_run=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    --reconfigure) : ;;
    -h|--help) echo 'Usage: CT_ID=<existing-agent> MQTT_CT_ID=<broker> HCOM_TARGET=hermes|openclaw|deepseek-harness|observer [MATTERMOST_CT_ID=...] [HCOM_HERMES_NATIVE=true] bash provision-lxc.sh [--dry-run]'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done
[[ ${CT_ID:-} =~ ^[1-9][0-9]{2,8}$ && ${MQTT_CT_ID:-} =~ ^[1-9][0-9]{2,8}$ ]] || die 'Set CT_ID and MQTT_CT_ID to existing CT IDs.'
case ${HCOM_TARGET:-} in hermes|openclaw|deepseek-harness|observer) ;; *) die 'Invalid HCOM_TARGET.' ;; esac
if [[ -n ${MATTERMOST_CT_ID:-} ]]; then
  [[ $MATTERMOST_CT_ID =~ ^[1-9][0-9]{2,8}$ && $HCOM_TARGET == observer ]] || die 'MATTERMOST_CT_ID requires an observer target and valid CT ID.'
fi
native=${HCOM_HERMES_NATIVE:-false}
[[ $native == false || ( $native == true && $HCOM_TARGET == hermes ) ]] || die 'HCOM_HERMES_NATIVE=true applies only to the hermes target.'
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
  [[ -z $id ]] || pct status "$id" | grep -q running || die "CT $id must be running."
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
