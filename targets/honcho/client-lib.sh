# shellcheck shell=bash
# shellcheck disable=SC2154  # dry_run comes from the caller
# Honcho client helpers, sourced by the agent provisioners (Hermes, OpenClaw,
# DeepSeek Harness) on the Proxmox host. An agent CT becomes a client of the
# Honcho CT's gateway: it gets its own key (Honcho stores only its hash),
# pinned to a workspace of its own named after the client, as an agent's Open
# Terminal workspace is. It can be revoked on its own and reaches neither
# another agent's memory nor an Open WebUI user's. The Honcho CT's firewall
# admits agents by address (HONCHO_CLIENT_IPS of targets/honcho/provision-lxc.sh).
# The caller defines die, note and dry_run.
#
# Not executable on its own; every function is prefixed hc_.

HC_CLIENTS=/usr/local/sbin/honcho-clients

# Pure helpers (tested in targets/honcho/test-client-lib.sh) ------------------

# hc_client_name KIND CT_ID: the client name the Honcho CT knows this agent by.
hc_client_name() { printf '%s-%s\n' "$1" "$2"; }
# hc_url_ip URL: the IPv4 address in an http(s)://IPv4:port[/path] URL, or nothing.
hc_url_ip() {
  [[ $1 =~ ^https?://([0-9]+(\.[0-9]+){3})[:/] ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  return 0
}
# End pure helpers. -------------------------------------------------------------

# hc_key_sha256 AGENT_CT FILE: the SHA-256 of the key in FILE inside AGENT_CT
# (whitespace removed, as honcho-clients hashes it), or nothing.
hc_key_sha256() {
  pct exec "$1" -- sh -c "[ -s '$2' ] && tr -d '\\r\\n\\t ' < '$2' | sha256sum | cut -d' ' -f1" 2>/dev/null |
    tr -d '\r' || true
}

# hc_connect HONCHO_CT NAME KEY_SHA256 OUTFILE: make sure client NAME has a
# gateway key, pinned to the workspace NAME. KEY_SHA256 is the hash of the
# key the agent already holds (or empty): when the Honcho CT accepts it for
# that workspace, the key is kept and OUTFILE stays empty; otherwise a new key
# is issued into OUTFILE (0600; the old one stops working at once).
hc_connect() {
  local ct=$1 name=$2 have=$3 out=$4
  if (( dry_run )); then
    printf '+ keep Honcho client %s'\''s key if Honcho CT %s accepts it, else: pct exec %s -- honcho-clients issue %s --workspace %s\n' \
      "$name" "$ct" "$ct" "$name" "$name"
    return 0
  fi
  pct exec "$ct" -- test -x "$HC_CLIENTS" ||
    die "Honcho CT $ct has no client gateway (an install from before per-user memory). Run targets/honcho/provision-lxc.sh --reconfigure for it first."
  : > "$out"
  chmod 0600 "$out"
  if [[ -n $have ]] && pct exec "$ct" -- "$HC_CLIENTS" has "$name" "$have" --workspace "$name"; then
    note "Keeping Honcho client $name's key."
    return 0
  fi
  pct exec "$ct" -- "$HC_CLIENTS" issue "$name" --workspace "$name" > "$out" ||
    die "Could not issue a Honcho key for $name in CT $ct."
  [[ $(tr -d '\r\n' < "$out") =~ ^[A-Za-z0-9._~+/=-]{16,}$ ]] || die "Honcho CT $ct returned no usable key."
  note "Issued a new Honcho key for client $name."
}

# hc_disconnect HONCHO_CT NAME: revoke NAME's key. Its workspace (the memories
# it wrote) stays in Honcho.
hc_disconnect() {
  local ct=$1 name=$2
  if (( dry_run )); then
    printf '+ pct exec %s -- honcho-clients revoke %s --missing-ok\n' "$ct" "$name"
    return 0
  fi
  pct exec "$ct" -- "$HC_CLIENTS" revoke "$name" --missing-ok ||
    note "Warning: could not revoke Honcho client $name in CT $ct; run honcho-clients revoke $name there."
}
