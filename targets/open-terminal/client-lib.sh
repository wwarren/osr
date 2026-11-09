# shellcheck shell=bash
# shellcheck disable=SC2154  # stage and dry_run come from the caller
# Open Terminal client helpers, sourced by the agent provisioners (Hermes,
# OpenClaw, DeepSeek Harness) on the Proxmox host. An agent CT becomes a
# client of the terminal CT's workspace gateway: it gets its own key (the
# terminal stores only its hash) and its own workspace, and the terminal's
# firewall admits its address. The caller defines die, note, dry_run, PVE_ETC
# and a private, existing stage directory ($stage).
#
# Not executable on its own; every function is prefixed ot_.

ot_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OT_FW_TAG=osr-open-terminal-client

# Pure helpers (tested in targets/open-terminal/test-client-lib.sh) ----------

# ot_valid_url URL: empty, or the gateway as http://IPv4:PORT (no path).
ot_valid_url() {
  [[ -z $1 || $1 =~ ^http://(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])){3}:[1-9][0-9]{0,4}/?$ ]]
}
# ot_url_ip URL / ot_url_port URL: its parts (URL already valid).
ot_url_ip() { local u=${1#http://}; printf '%s\n' "${u%%:*}"; }
ot_url_port() { local u=${1##*:}; printf '%s\n' "${u%/}"; }
# ot_client_name KIND CT_ID: the client name the terminal knows this agent by.
ot_client_name() { printf '%s-%s\n' "$1" "$2"; }
# ot_fw_with_client FILE IP PORT NAME: FILE with NAME's one rule (IP to the
# gateway PORT) first in [RULES]; an older rule for NAME is dropped, every
# other line kept.
ot_fw_with_client() {
  awk -v rule="IN ACCEPT -source $2/32 -p tcp -dport $3 -log nolog # $OT_FW_TAG $4" \
      -v tag=" # $OT_FW_TAG $4" '
    substr($0, length($0) - length(tag) + 1) == tag { next }
    $0 == "[RULES]" && !seen { print; print rule; seen=1; next }
    { print }
    END { if (!seen) { print ""; print "[RULES]"; print rule } }
  ' "$1"
}
# ot_fw_without_client FILE NAME: FILE without NAME's rule.
ot_fw_without_client() {
  awk -v tag=" # $OT_FW_TAG $2" 'substr($0, length($0) - length(tag) + 1) != tag' "$1"
}
# End pure helpers. -------------------------------------------------------------

# ot_fw_apply TERMINAL_CT CONTENT_FUNCTION ARGS...: rewrite the terminal CT's
# firewall file through targets/pve-firewall-swap.pl (Proxmox's per-CT lock,
# only if unchanged since read). A missing file is reported, not created.
ot_fw_apply() {
  local ct=$1; shift
  local file=$PVE_ETC/firewall/$ct.fw status=0
  if [[ ! -e $file ]]; then
    note "Warning: $file does not exist, so Open Terminal CT $ct does not filter by address; not creating it."
    return 0
  fi
  cp -- "$file" "$stage/ot-firewall.seen" || die "Could not read $file."
  "$@" "$stage/ot-firewall.seen" > "$stage/ot-firewall.new" || die "Could not build the new $file."
  cmp -s "$stage/ot-firewall.seen" "$stage/ot-firewall.new" && return 0
  perl "$ot_lib_dir/../pve-firewall-swap.pl" "$file" "$stage/ot-firewall.seen" "$stage/ot-firewall.new" "$ct" "$PVE_ETC" || status=$?
  case $status in
    0) ;;
    1) die "$file changed while it was being updated; nothing was changed there. Rerun." ;;
    *) die "Could not update $file." ;;
  esac
}
_ot_with() { ot_fw_with_client "$4" "$1" "$2" "$3"; }
_ot_without() { ot_fw_without_client "$2" "$1"; }

# ot_terminal_port TERMINAL_CT: the gateway port recorded in the terminal CT,
# after checking that it runs the workspace gateway at all.
ot_terminal_port() {
  local port
  pct exec "$1" -- test -x /usr/local/sbin/open-terminal-clients ||
    die "Open Terminal CT $1 has no workspace gateway (an install from before per-user workspaces). Rerun install-target.sh there first (README: Upgrade and roll back)."
  port=$(pct exec "$1" -- sed -n 's/^OPEN_TERMINAL_PORT=//p' /etc/open-terminal/service.env | tail -n 1 | tr -d '\r')
  [[ $port =~ ^[1-9][0-9]{0,4}$ ]] || die "Could not read Open Terminal CT $1's gateway port."
  printf '%s\n' "$port"
}

# ot_connect TERMINAL_CT AGENT_IP NAME KEY_SHA256 OUTFILE: admit AGENT_IP in
# the terminal's firewall and make sure NAME has a key. KEY_SHA256 is the hash
# of the key the agent already holds (or empty): when the terminal accepts it,
# the key is kept and OUTFILE stays empty; otherwise a new key is issued into
# OUTFILE (0600; the old one stops working).
ot_connect() {
  local ct=$1 ip=$2 name=$3 have=$4 out=$5 port
  if (( dry_run )); then
    printf '+ admit %s in Open Terminal CT %s'\''s firewall (# %s %s)\n' "$ip" "$ct" "$OT_FW_TAG" "$name"
    printf '+ keep client %s'\''s key if the terminal accepts it, else: pct exec %s -- open-terminal-clients issue %s --default-user default\n' "$name" "$ct" "$name"
    return 0
  fi
  port=$(ot_terminal_port "$ct")
  ot_fw_apply "$ct" _ot_with "$ip" "$port" "$name"
  : > "$out"
  chmod 0600 "$out"
  if [[ -n $have ]] && pct exec "$ct" -- /usr/local/sbin/open-terminal-clients has "$name" "$have"; then
    note "Keeping client $name's Open Terminal key."
    return 0
  fi
  pct exec "$ct" -- /usr/local/sbin/open-terminal-clients issue "$name" --default-user default > "$out" ||
    die "Could not issue an Open Terminal key for $name in CT $ct."
  [[ $(tr -d '\r\n' < "$out") =~ ^[A-Za-z0-9._~+/=-]{16,}$ ]] || die "Open Terminal CT $ct returned no usable key."
  note "Issued a new Open Terminal key for client $name."
}

# ot_disconnect TERMINAL_CT NAME: revoke NAME's key and remove its firewall
# rule. Its workspace files stay in the terminal CT.
ot_disconnect() {
  local ct=$1 name=$2
  if (( dry_run )); then
    printf '+ pct exec %s -- open-terminal-clients revoke %s; remove its rule from %s\n' "$ct" "$name" "$PVE_ETC/firewall/$ct.fw"
    return 0
  fi
  pct exec "$ct" -- /usr/local/sbin/open-terminal-clients revoke "$name" --missing-ok ||
    note "Warning: could not revoke Open Terminal client $name in CT $ct; run open-terminal-clients revoke $name there."
  ot_fw_apply "$ct" _ot_without "$name"
}
