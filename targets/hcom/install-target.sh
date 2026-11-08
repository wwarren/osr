#!/usr/bin/env bash
# Install hcom into an existing OSR agent CT, or an observer CT for notifications.
#
# Layout: a relay account (osr-hcom) owns hcom's state and the relay group key
# and runs the relay worker. The agent reaches the bus only through
# /run/osr-hcom/bus.sock (osr-bus), served per connection by osr-hcom-bus@.service
# as that account. HCOM_HERMES_NATIVE=true instead runs everything as hermes so
# Hermes's native hcom plugin can work; the agent then holds the key too.
set -Eeuo pipefail
umask 077
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/install-state.sh"
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
dry_run=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    -h|--help) echo 'Usage: HCOM_TARGET=hermes|openclaw|deepseek-harness|observer HCOM_RELAY_BUNDLE=<file> [HCOM_HERMES_NATIVE=true] bash install-target.sh [--dry-run]'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done
target=${HCOM_TARGET:-}
native=${HCOM_HERMES_NATIVE:-false}
[[ $native == true || $native == false ]] || die 'HCOM_HERMES_NATIVE must be true or false.'
# Earlier releases kept hcom's state (with the relay key) in the agent's own
# account; old_state is moved into the current layout and old_instructions
# loses its managed block.
old_instructions=''
case $target in
  hermes) agent=hermes; instructions=/home/hermes/AGENTS.md; unit=hermes-gateway.service
          old_instructions=/home/hermes/.hermes/AGENTS.md ;;
  openclaw) agent=openclaw; instructions=/home/openclaw/.openclaw/workspace/AGENTS.md; unit=openclaw-gateway.service
            old_state=/home/openclaw/.osr-hcom ;;
  deepseek-harness) agent=deepseek-harness; instructions=/var/lib/deepseek-harness/home/AGENTS.md; unit=deepseek-harness.service
                    old_state=/var/lib/deepseek-harness/hcom ;;
  observer) agent=''; instructions=''; unit='' ;;
  *) die 'Set HCOM_TARGET to hermes, openclaw, deepseek-harness or observer.' ;;
esac
[[ $native == false || $target == hermes ]] || die 'HCOM_HERMES_NATIVE applies only to the hermes target.'
if [[ $native == true ]]; then
  relay_user=hermes; relay_home=/home/hermes; state=/home/hermes/.osr-hcom
  [[ $target != hermes ]] || old_state=/var/lib/osr-hcom/.osr-hcom
else
  relay_user=osr-hcom; relay_home=/var/lib/osr-hcom; state=/var/lib/osr-hcom/.osr-hcom
  [[ $target != hermes ]] || old_state=/home/hermes/.osr-hcom
fi
old_state=${old_state:-}
# Hermes reads AGENTS.md from its working directory (the gateway's is /home/hermes).
instructions=${HCOM_INSTRUCTIONS_FILE:-$instructions}
[[ -z $instructions || ( $instructions =~ ^/[A-Za-z0-9_./-]+$ && $instructions != *..* ) ]] ||
  die 'Invalid HCOM_INSTRUCTIONS_FILE.'
bundle=${HCOM_RELAY_BUNDLE:-}
[[ -r $bundle ]] || die 'HCOM_RELAY_BUNDLE must name the private broker relay.json file.'
python3 - "$here" "$bundle" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from bus_config import validate_bundle
validate_bundle(json.load(open(sys.argv[2])))
PY
webhook=${HCOM_MATTERMOST_WEBHOOK_FILE:-}
if [[ -z $webhook && $target == observer && -r /etc/osr-hcom/mattermost-webhook ]]; then
  webhook=/etc/osr-hcom/mattermost-webhook
fi
[[ -z $webhook || $target == observer ]] || die 'Run only one notifier, on the observer target.'
[[ -z $webhook || -r $webhook ]] || die 'Cannot read HCOM_MATTERMOST_WEBHOOK_FILE.'
if (( dry_run )); then
  printf '+ install checksum-pinned hcom 0.7.31; configure %s; relay account %s\n' "$target" "$relay_user"
  printf '+ hcom state and relay key in %s (not readable by the agent unless native)\n' "$state"
  [[ -z $agent ]] || printf '+ bus socket /run/osr-hcom/bus.sock for %s (osr-bus)\n' "$agent"
  [[ -z $instructions ]] || printf '+ update managed instructions in %s\n' "$instructions"
  [[ $native != true ]] || printf '+ hcom hooks add hermes (native plugin); HCOM_DIR drop-in for %s; restart it\n' "$unit"
  [[ -z $webhook ]] || printf '+ enable durable Mattermost handoff notifier with a private credential\n'
  exit 0
fi
[[ $EUID == 0 ]] || die 'Run as root inside the target CT.'
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' ||
  die 'hcom setup needs Python 3.11 or newer (Debian 12/13, Ubuntu 24.04+).'
if [[ -n $agent ]]; then
  id "$agent" >/dev/null 2>&1 || die "Install the $target agent first (missing $agent account)."
fi
if [[ $native == true && ! -f /etc/systemd/system/$unit ]]; then
  die "Native Hermes needs $unit (the Hermes provisioner's Open WebUI option)."
fi
if [[ $relay_user == osr-hcom ]] && ! id osr-hcom >/dev/null 2>&1; then
  useradd --system --user-group --create-home --home-dir "$relay_home" --shell /usr/sbin/nologin osr-hcom
fi
relay_group=$(id -gn "$relay_user")
socket_group=$relay_group
[[ -z $agent ]] || socket_group=$(id -gn "$agent")
install -d -m 0755 /usr/local/lib/osr-hcom /usr/local/bin /etc/osr-hcom
exec {lock_fd}>/etc/osr-hcom/install.lock
flock -n "$lock_fd" || die 'Another hcom installer is running.'
[[ ! -r /etc/osr-hcom/target || $(</etc/osr-hcom/target) == "$target" ]] || die 'A different hcom target is already installed in this CT.'
[[ ! -d /etc/osr-hcom/rollback ]] || die 'A failed rollback is preserved in /etc/osr-hcom/rollback; repair it before rerunning.'
input_sha=$( { cat "$bundle" "$here"/*.py "$here/install-target.sh" "$here/install-state.sh"
               printf '%s\n' "$target" "$instructions" "$native"; [[ -z $webhook ]] || cat "$webhook"; } | sha256sum | cut -d' ' -f1)
if [[ -r /etc/osr-hcom/settings && $(</etc/osr-hcom/settings) == "$input_sha" ]] &&
   files_match /etc/osr-hcom/managed.sha256 && systemctl is-active --quiet osr-hcom-relay.service &&
   systemctl is-active --quiet osr-hcom-bus.socket &&
   { [[ -z $old_state || ! -e $old_state ]]; } &&
   { [[ $native == false ]] || systemctl is-active --quiet "$unit"; } &&
   { [[ -z $webhook ]] || systemctl is-active --quiet osr-hcom-mattermost.service; }; then
  echo 'hcom is configured and running: nothing to do.'
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl python3 tar
stage=$(mktemp -d)
chmod 0755 "$stage"   # Holds only the public hcom release; account switches run it.
trap 'rm -rf -- "$stage"' EXIT
case $(uname -m) in
  x86_64) triple=x86_64-unknown-linux-musl; sha=5fdbe20d2ce03e8966e2c18aee32c327453dbe4b66d1c7c6731decb2189ca9d5 ;;
  aarch64) triple=aarch64-unknown-linux-musl; sha=fcd531a1e80a95f658feba0df93f206ddf0679b2fe38fcf5c8f9c0d8904b0fe7 ;;
  *) die 'hcom target supports Linux x86_64 and aarch64.' ;;
esac
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  "https://github.com/aannoo/hcom/releases/download/v0.7.31/hcom-$triple.tar.gz" -o "$stage/hcom.tar.gz"
printf '%s  %s\n' "$sha" "$stage/hcom.tar.gz" | sha256sum --check --status || die 'hcom archive checksum mismatch.'
tar xzf "$stage/hcom.tar.gz" -C "$stage" "hcom-$triple/hcom"
chmod -R a+rX "$stage/hcom-$triple"
[[ $("$stage/hcom-$triple/hcom" --version) == 'hcom 0.7.31' ]] || die 'Unexpected hcom version.'

units=/etc/systemd/system
dropin=''
[[ -z $unit ]] || dropin=$units/$unit.d/30-osr-hcom.conf
hermes_home=/home/hermes/.hermes
managed=(/usr/local/bin/hcom /usr/local/bin/osr-bus /usr/local/lib/osr-hcom "$state/config.toml"
  "$units/osr-hcom-relay.service" "$units/osr-hcom-mattermost.service" "$units/osr-hcom-bus.socket"
  "$units/osr-hcom-bus@.service" /etc/osr-hcom/bus.json /etc/osr-hcom/mattermost-webhook /etc/osr-hcom/target)
[[ -z $instructions ]] || managed+=("$instructions")
[[ $native != true ]] || managed+=("$dropin" "$hermes_home/config.yaml" "$hermes_home/plugins/hcom")
files=("${managed[@]}" /etc/osr-hcom/settings /etc/osr-hcom/managed.sha256)
[[ -z $dropin || $native == true ]] || files+=("$dropin")
[[ -z $old_instructions || $old_instructions == "$instructions" ]] || files+=("$old_instructions")
[[ $target != hermes || $native == true ]] || files+=("$hermes_home/config.yaml" "$hermes_home/plugins/hcom")
migrate=false
if [[ -n $old_state && -e $old_state && $old_state != "$state" ]]; then
  # Both whole state directories, so a failed migration puts them back.
  migrate=true
  files+=("$old_state" "$state")
fi
snapshot_save /etc/osr-hcom/rollback "${files[@]}"
was_active() { systemctl is-active --quiet "$1" && echo true || echo false; }
was_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null && echo true || echo false; }
old_relay=$(was_active osr-hcom-relay.service); old_relay_enabled=$(was_enabled osr-hcom-relay.service)
old_bridge=$(was_active osr-hcom-mattermost.service); old_bridge_enabled=$(was_enabled osr-hcom-mattermost.service)
old_socket=$(was_active osr-hcom-bus.socket); old_socket_enabled=$(was_enabled osr-hcom-bus.socket)
restart_agent=false
finish() {
  local status=$? recovered=true
  trap - EXIT
  if (( status != 0 )); then
    systemctl stop osr-hcom-mattermost.service osr-hcom-bus.socket osr-hcom-relay.service 2>/dev/null || true
    $old_relay_enabled || systemctl disable osr-hcom-relay.service 2>/dev/null || true
    $old_bridge_enabled || systemctl disable osr-hcom-mattermost.service 2>/dev/null || true
    $old_socket_enabled || systemctl disable osr-hcom-bus.socket 2>/dev/null || true
    snapshot_restore /etc/osr-hcom/rollback || recovered=false
    systemctl daemon-reload || recovered=false
    local service
    for service in osr-hcom-relay.service:$old_relay osr-hcom-bus.socket:$old_socket osr-hcom-mattermost.service:$old_bridge; do
      [[ ${service#*:} == true ]] || continue
      systemctl restart "${service%:*}" && systemctl is-active --quiet "${service%:*}" || recovered=false
    done
    if $restart_agent; then systemctl restart "$unit" && systemctl is-active --quiet "$unit" || recovered=false; fi
    if $recovered; then echo 'Previous hcom configuration running again (or first install removed).' >&2
    else echo 'hcom rollback failed too; snapshot kept in /etc/osr-hcom/rollback.' >&2; fi
  fi
  if (( status == 0 )) || $recovered; then rm -rf /etc/osr-hcom/rollback; fi
  rm -rf -- "$stage"
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Stop every worker before moving or rewriting relay state.
systemctl stop osr-hcom-mattermost.service osr-hcom-relay.service 2>/dev/null || true
stop_worker() {  # USER HOME STATE: a worker, even one an agent started itself.
  [[ -d $3 ]] || return 0
  runuser -u "$1" -- env HOME="$2" HCOM_DIR="$3" "$stage/hcom-$triple/hcom" relay daemon stop >/dev/null
}
stop_worker "$relay_user" "$relay_home" "$state"
if $migrate; then
  owner=$(stat -c %U "$old_state")
  stop_worker "$owner" "$(getent passwd "$owner" | cut -d: -f6)" "$old_state"
  if [[ -e $state ]]; then
    rm -rf -- "$old_state"   # The current location wins; the old copy holds the key.
  else
    [[ -d $(dirname -- "$state") ]] || install -d -m 0700 -o "$relay_user" -g "$relay_group" "$(dirname -- "$state")"
    mv -- "$old_state" "$state"
  fi
fi
[[ $relay_user != osr-hcom ]] || chmod 0700 "$relay_home"
install -d -m 0700 -o "$relay_user" -g "$relay_group" "$state"
chown -R "$relay_user:$relay_group" "$state"

install -m 0755 "$stage/hcom-$triple/hcom" /usr/local/bin/hcom.new
mv -f /usr/local/bin/hcom.new /usr/local/bin/hcom
for file in bus_config.py bus_server.py osr_bus.py mattermost_bridge.py; do
  install -m 0644 "$here/$file" "/usr/local/lib/osr-hcom/$file"
done
printf '#!/bin/sh\nexec /usr/bin/python3 /usr/local/lib/osr-hcom/osr_bus.py "$@"\n' > /usr/local/bin/osr-bus
chmod 0755 /usr/local/bin/osr-bus
python3 - "$target" "$relay_user" "$relay_home" "$state" > /etc/osr-hcom/bus.json <<'PY'
import json, sys
print(json.dumps(dict(zip(("target", "relay_user", "relay_home", "state"), sys.argv[1:]))))
PY
chmod 0644 /etc/osr-hcom/bus.json

config_args=(client --bundle "$bundle" --target "$target" --state "$state")
[[ -z $instructions ]] || config_args+=(--instructions "$instructions")
[[ -z $old_instructions ]] || config_args+=(--remove-instructions "$old_instructions")
if [[ -n $instructions && ! -d $(dirname -- "$instructions") ]]; then
  runuser -u "$agent" -- mkdir -p -- "$(dirname -- "$instructions")"
fi
python3 "$here/bus_config.py" "${config_args[@]}"
chown "$relay_user:$relay_group" "$state/config.toml"

if [[ $target == hermes ]]; then
  hermes_env=(env HOME=/home/hermes HERMES_HOME="$hermes_home" PATH="/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin")
  if [[ $native == true ]]; then
    runuser -u hermes -- "${hermes_env[@]}" HCOM_DIR="$state" /usr/local/bin/hcom hooks add hermes
  elif [[ -d $hermes_home/plugins/hcom ]]; then
    # Leaving native mode: the plugin would need the key it no longer has.
    scratch=$(runuser -u hermes -- mktemp -d /home/hermes/.osr-hcom-remove.XXXXXX)
    runuser -u hermes -- "${hermes_env[@]}" HCOM_DIR="$scratch" /usr/local/bin/hcom hooks remove hermes >/dev/null
    rm -rf -- "$scratch"
    restart_agent=true
  fi
fi
if [[ -n $dropin ]]; then
  if [[ $native == true ]]; then
    want=$(printf '[Service]\nEnvironment=HCOM_DIR=%s\n' "$state")
    if [[ ! -f $dropin || $(<"$dropin") != "$want" ]]; then
      install -d -m 0755 "$units/$unit.d"
      printf '%s\n' "$want" > "$dropin"
      chmod 0644 "$dropin"
    fi
    restart_agent=true   # Loads the plugin and its environment.
  elif [[ -f $dropin ]]; then
    rm -f -- "$dropin"
    rmdir --ignore-fail-on-non-empty "$units/$unit.d"
    restart_agent=true   # The agent must lose HCOM_DIR (and any worker it started).
  fi
fi

hardening="NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$state
CapabilityBoundingSet=
UMask=0077"
cat > "$units/osr-hcom-relay.service" <<EOF
[Unit]
Description=OSR hcom MQTT relay ($target)
Wants=network-online.target
After=network-online.target
[Service]
User=$relay_user
Group=$relay_group
Environment=HOME=$relay_home
Environment=HCOM_DIR=$state
# hcom starts its own detached worker when none runs; this unit owns the worker.
ExecStartPre=-/usr/local/bin/hcom relay daemon stop
ExecStart=/usr/local/bin/hcom relay-worker
Restart=always
RestartSec=5
$hardening
[Install]
WantedBy=multi-user.target
EOF
allow=''
[[ -z $agent ]] || allow=" --allow-user $agent"
cat > "$units/osr-hcom-bus.socket" <<EOF
[Unit]
Description=OSR agent bus socket ($target)
[Socket]
ListenStream=/run/osr-hcom/bus.sock
SocketUser=root
SocketGroup=$socket_group
SocketMode=0660
DirectoryMode=0755
Accept=yes
MaxConnections=16
[Install]
WantedBy=sockets.target
EOF
cat > "$units/osr-hcom-bus@.service" <<EOF
[Unit]
Description=OSR agent bus request ($target)
[Service]
User=$relay_user
Group=$relay_group
Environment=HOME=$relay_home
Environment=HCOM_DIR=$state
ExecStart=/usr/bin/python3 /usr/local/lib/osr-hcom/bus_server.py --target $target$allow
StandardInput=socket
StandardOutput=socket
StandardError=journal
$hardening
EOF
if [[ -n $webhook ]]; then
  if [[ $webhook != /etc/osr-hcom/mattermost-webhook ]]; then
    install -m 0600 "$webhook" /etc/osr-hcom/mattermost-webhook
  fi
  install -d -m 0700 -o "$relay_user" -g "$relay_group" "$relay_home/bridge"
  cat > "$units/osr-hcom-mattermost.service" <<EOF
[Unit]
Description=OSR hcom handoffs to Mattermost
Wants=network-online.target
Requires=osr-hcom-relay.service
After=network-online.target osr-hcom-relay.service
[Service]
User=$relay_user
Group=$relay_group
Environment=HCOM_DIR=$state
LoadCredential=webhook:/etc/osr-hcom/mattermost-webhook
ExecStart=/usr/bin/python3 /usr/local/lib/osr-hcom/mattermost_bridge.py --state $relay_home/bridge/cursor.json --webhook-file %d/webhook
Restart=on-failure
RestartSec=10
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$relay_home
CapabilityBoundingSet=
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
fi
chmod 0644 "$units"/osr-hcom-*.service "$units"/osr-hcom-bus.socket
systemctl daemon-reload
systemctl enable --now osr-hcom-relay.service
systemctl enable osr-hcom-bus.socket
systemctl restart osr-hcom-bus.socket
! $restart_agent || systemctl restart "$unit"
if [[ -n $webhook ]]; then
  systemctl enable osr-hcom-mattermost.service
  systemctl restart osr-hcom-mattermost.service
fi
sleep 2
systemctl is-active --quiet osr-hcom-relay.service || die 'hcom relay did not stay active (journalctl -u osr-hcom-relay).'
relay_check=$stage/relay-status
if ! runuser -u "$relay_user" -- env HOME="$relay_home" HCOM_DIR="$state" /usr/local/bin/hcom relay on > "$relay_check" 2>&1; then
  grep -E '^(Status|Broker):' "$relay_check" >&2 || true
  broker=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["broker"])' "$bundle")
  die "hcom could not connect to $broker. Check that the broker CT is running, that MQTT_CLIENT_CIDR admits this CT, and this CT's outbound firewall (hcom's provisioner adds the rule)."
fi
# The whole agent path: socket, per-connection service, relay account, hcom.
/usr/local/bin/osr-bus status >/dev/null || die 'The bus socket did not answer (journalctl -u "osr-hcom-bus@*").'
if [[ -n $agent ]]; then
  runuser -u "$agent" -- /usr/local/bin/osr-bus status >/dev/null || die "$agent cannot use the bus socket."
  if runuser -u "$agent" -- test -r "$state/config.toml" && [[ $native == false ]]; then
    die "$agent can read the relay key in $state; check its permissions."
  fi
fi
if $restart_agent; then systemctl is-active --quiet "$unit" || die 'Agent service failed after configuration.'; fi
[[ -z $webhook ]] || systemctl is-active --quiet osr-hcom-mattermost.service || die 'Notifier failed after configuration.'
printf '%s\n' "$input_sha" > /etc/osr-hcom/settings
printf '%s\n' "$target" > /etc/osr-hcom/target
digests=()
for file in "${managed[@]}"; do
  if [[ -d $file ]]; then
    while IFS= read -r -d '' member; do digests+=("$member"); done < <(
      find "$file" -type f ! -name '*.pyc' ! -name '.hcom-config-stamp' -print0
    )
  elif [[ -f $file ]]; then
    digests+=("$file")
  fi
done
sha256sum "${digests[@]}" > /etc/osr-hcom/managed.sha256
echo "hcom configured for $target (relay account $relay_user). Check: osr-bus status"
