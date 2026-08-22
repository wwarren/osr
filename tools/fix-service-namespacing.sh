#!/usr/bin/env bash
#
# fix-service-namespacing.sh -- repair "502 Bad Gateway" caused by
#                               status=226/NAMESPACE in an ollama-smart-router
#                               container.
#
# Run this ON THE PROXMOX HOST:   ./fix-service-namespacing.sh <CTID>
#
# THE FAULT
# ---------
# The four units this system installs carry
#     PrivateTmp=true / ProtectSystem=full / ProtectHome=true
# Those are not process flags. systemd implements them by building a private
# MOUNT NAMESPACE before it execs the binary. Whether an LXC container may build
# one is decided by the AppArmor profile the host applies, which depends on the
# container's `features` (nesting) and its privilege level.
#
# When it is refused the failure is total, not graceful:
#     open-webui.service: Failed to set up mount namespacing: Permission denied
#     open-webui.service: Failed at step NAMESPACE spawning ...: Permission denied
#     open-webui.service: Main process exited, code=exited, status=226/NAMESPACE
# systemd never runs the binary at all, Restart=always loops forever, nothing
# binds the upstream port, and nginx in front of it answers 502 Bad Gateway.
#
# WHAT THIS DOES
# --------------
#   1. Reports the container's privilege level and features.
#   2. Probes namespacing with a real transient unit -- the same code path the
#      services use, so the answer is measured rather than guessed.
#   3. If it is refused and nesting=1 is missing, offers to add it and reboot the
#      container, then re-probes. That is the fix that KEEPS the hardening.
#   4. If it is still refused, strips the three directives from the units --
#      both the live copies in /etc/systemd/system and the source copies in
#      /app/config-repo, so `manage-model-servers apply` does not put them back.
#   5. Reloads, restarts, and reports what is actually listening.
#
# It is safe to run repeatedly, and it makes no change without saying so first.
set -euo pipefail

CT_ID="${1:-}"
if [[ -z "$CT_ID" || ! "$CT_ID" =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <CTID>" >&2
  exit 2
fi
if ! command -v pct >/dev/null 2>&1; then
  echo "This script runs on the Proxmox host (pct not found)." >&2
  exit 2
fi
if ! pct status "$CT_ID" >/dev/null 2>&1; then
  echo "No such container: ${CT_ID}" >&2
  exit 2
fi

ASSUME_YES=false
[[ "${2:-}" == "-y" || "${AUTO_YES:-}" == "1" ]] && ASSUME_YES=true

run_ct() { pct exec "$CT_ID" -- "$@"; }

# Capture one line of container output with carriage returns removed.
#
# `pct exec` goes through lxc-attach, which allocates a pty whenever the host's
# stdout is a terminal — i.e. every interactive run of this script. The pty's
# ONLCR turns each \n into \r\n, and command substitution strips the trailing
# newline but NOT the \r. So a captured "active" is really "active\r": it PRINTS
# as "active" and compares equal to nothing. An earlier version of this script
# listed all four units as active and then announced that some were not.
ct_out() {
  run_ct "$@" 2>/dev/null | tr -d '\r' | awk 'NF {print; exit}'
}

# Is anything listening on this TCP port inside the container? Anchored on the
# port so 8088 does not match 18088.
ct_listening() {
  run_ct ss -lnt 2>/dev/null | tr -d '\r' \
    | awk -v p=":${1}\$" '$4 ~ p {found=1} END {exit !found}'
}

confirm() {
  $ASSUME_YES && return 0
  local reply
  read -r -p "$1 [y/N] " reply || true
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

UNITS=(litellm-proxy ollama-router ollama-monitor open-webui)

# --- 1. what kind of container is this? ---------------------------------------
echo "=============================================================================="
echo "Container ${CT_ID}"
priv="$(pct config "$CT_ID" | awk -F': ' '/^unprivileged:/ {print $2}')"
feat="$(pct config "$CT_ID" | awk -F': ' '/^features:/ {print $2}')"
if [[ "$priv" == "1" ]]; then
  echo "  privilege : unprivileged"
else
  echo "  privilege : PRIVILEGED"
fi
echo "  features  : ${feat:-<none>}"

if pct status "$CT_ID" | grep -q stopped; then
  echo "  the container is stopped; starting it."
  pct start "$CT_ID"
  sleep 5
fi

# --- 2. probe -------------------------------------------------------------------
# Two probes. "The sandbox was refused" and "the probe itself did not run" are
# different findings and lead to opposite actions, so they are not conflated.
probe() {
  if ! run_ct systemd-run --quiet --wait --collect --unit=osr-ns-probe-plain \
       /bin/true >/dev/null 2>&1; then
    echo "unknown"; return 0
  fi
  if run_ct systemd-run --quiet --wait --collect --unit=osr-ns-probe-sandbox \
       -p PrivateTmp=yes -p ProtectSystem=full -p ProtectHome=yes \
       /bin/true >/dev/null 2>&1; then
    echo "ok"
  else
    echo "denied"
  fi
}

echo
echo "Probing systemd mount namespacing inside the container."
verdict="$(probe)"
case "$verdict" in
  ok)      echo "  RESULT: permitted — the hardening directives work here." ;;
  denied)  echo "  RESULT: DENIED — this is the cause of status=226/NAMESPACE." ;;
  unknown) echo "  RESULT: inconclusive — a plain transient unit would not run" ;;
esac

if [[ "$verdict" == "unknown" ]]; then
  echo
  echo "systemd-run could not start even an unsandboxed unit, so nothing here can" >&2
  echo "be concluded about namespacing. Look at the container's own systemd first:" >&2
  echo "  pct exec ${CT_ID} -- systemctl status" >&2
  exit 1
fi

# --- 3. preferred fix: nesting, which keeps the hardening -----------------------
if [[ "$verdict" == "denied" && "$feat" != *nesting=1* ]]; then
  echo
  echo "nesting=1 is NOT set on this container. That is the setting that selects"
  echo "the AppArmor profile permitting these mounts, and enabling it is the fix"
  echo "that keeps the service hardening intact. It requires a container reboot."
  if confirm "Enable nesting=1 and reboot container ${CT_ID}?"; then
    if [[ -n "$feat" ]]; then
      pct set "$CT_ID" -features "${feat},nesting=1"
    else
      pct set "$CT_ID" -features nesting=1
    fi
    echo "  rebooting."
    pct reboot "$CT_ID"
    for _ in $(seq 1 60); do
      state="$(ct_out systemctl is-system-running || true)"
      [[ "$state" == "running" || "$state" == "degraded" ]] && break
      sleep 2
    done
    echo "  re-probing."
    verdict="$(probe)"
    case "$verdict" in
      ok)     echo "  RESULT: permitted now. Nesting was the whole problem." ;;
      *)      echo "  RESULT: still denied even with nesting=1." ;;
    esac
  fi
fi

if [[ "$verdict" == "ok" ]]; then
  echo
  echo "Namespacing works. Clearing the crash-loop counters and restarting."
  for u in "${UNITS[@]}"; do
    run_ct systemctl reset-failed "${u}.service" >/dev/null 2>&1 || true
  done
  run_ct systemctl daemon-reload
  run_ct systemctl restart "${UNITS[@]/%/.service}" || true
else
  # --- 4. fallback: remove what the container will not grant -------------------
  echo
  echo "The container will not grant a mount namespace, so the units must stop"
  echo "asking for one — a unit that asks and is refused does not start at all."
  echo "Removing PrivateTmp=, ProtectSystem= and ProtectHome= from:"
  echo "  /etc/systemd/system/{$(IFS=,; echo "${UNITS[*]}")}.service"
  echo "  /app/config-repo/services/*/*.service   (so 'apply' does not undo it)"
  echo "NoNewPrivileges= is kept: it is a prctl flag, not a mount."
  if ! confirm "Proceed?"; then
    echo "Nothing changed."
    exit 0
  fi

  # One awk program, applied in place to every unit file in both locations.
  run_ct bash -s <<'REMOTE'
set -euo pipefail
strip_one() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -qE '^(PrivateTmp|ProtectSystem|ProtectHome)=' "$f" || return 0
  cp -a "$f" "${f}.ns-backup"
  awk '
    /^(PrivateTmp|ProtectSystem|ProtectHome)=/ { next }
    /^NoNewPrivileges=/ {
      print
      print "# PrivateTmp=, ProtectSystem= and ProtectHome= were removed because"
      print "# this container denies systemd the mount namespacing they are built"
      print "# from. A unit that asks for one here does not start AT ALL"
      print "# (status=226/NAMESPACE) -- it does not merely run unhardened."
      print "# NoNewPrivileges= is a process flag rather than a mount, so it stays."
      next
    }
    { print }
  ' "$f" > "${f}.tmp"
  mv "${f}.tmp" "$f"
  echo "  rewrote ${f} (original kept as ${f}.ns-backup)"
}
for u in litellm-proxy ollama-router ollama-monitor open-webui; do
  strip_one "/etc/systemd/system/${u}.service"
  strip_one "/app/config-repo/services/${u}/${u}.service"
done
systemctl daemon-reload
for u in litellm-proxy ollama-router ollama-monitor open-webui; do
  systemctl reset-failed "${u}.service" >/dev/null 2>&1 || true
done
REMOTE

  echo "Restarting services."
  run_ct systemctl restart litellm-proxy.service ollama-router.service \
    ollama-monitor.service || true
  run_ct systemctl restart open-webui.service || true
fi

# --- 5. report what is really running ------------------------------------------
#
# Wait on the port Open WebUI ITSELF binds, never the public one. With TLS on,
# nginx is already listening on 8080/8000 the moment it starts, so a wait that
# accepts 8080 returns instantly and judges a service that has not begun to
# serve. The upstream port is whatever the env file says, because that env file
# is what systemd expands into --port.
OW_PORT="$(ct_out bash -c '. /app/openwebui/.env 2>/dev/null; printf %s "${PORT:-8088}"' || true)"
[[ "$OW_PORT" =~ ^[0-9]+$ ]] || OW_PORT=8088
echo
echo "Waiting for Open WebUI on its upstream port ${OW_PORT}. Its first start runs"
echo "database migrations and downloads an embedding model; this takes minutes."
waited=0
ow_up=false
while (( waited < 900 )); do
  if ct_listening "$OW_PORT"; then ow_up=true; break; fi
  # No point waiting out the deadline on a unit that has already given up.
  case "$(ct_out systemctl is-active open-webui.service || true)" in
    active|activating|reloading) ;;
    *) break ;;
  esac
  sleep 10; waited=$(( waited + 10 ))
  (( waited % 60 == 0 )) && echo "  still starting (${waited}s)..."
done

echo
echo "=============================================================================="
echo "Service status:"
for u in "${UNITS[@]}" nginx; do
  state="$(ct_out systemctl is-active "${u}.service" || true)"
  printf '  %-16s %s\n' "$u" "${state:-not-installed}"
done
printf '  %-16s %s\n' "webui upstream" \
  "$($ow_up && echo "listening on ${OW_PORT}" || echo "NOT listening on ${OW_PORT} — nginx will 502")"
echo
echo "Listening sockets:"
run_ct ss -lntp 2>/dev/null | tr -d '\r' | sed 's/^/  /' || true
echo "=============================================================================="

failed=false
for u in "${UNITS[@]}"; do
  state="$(ct_out systemctl is-active "${u}.service" || true)"
  [[ "$state" == "active" ]] || { echo "  ${u}: ${state:-unknown}" >&2; failed=true; }
done

if $failed; then
  echo "Some units are not active. Last 40 lines from open-webui:" >&2
  run_ct journalctl -u open-webui -n 40 --no-pager 2>/dev/null | sed 's/^/  /' >&2
  exit 1
fi

echo "All four services are active."
if ! $ow_up; then
  # Active but not listening is a real state, not a contradiction: Open WebUI is
  # Type=simple, so systemd calls it active as soon as it forks — minutes before
  # it binds. Say which of the two it is rather than calling it a failure.
  if run_ct journalctl -u open-webui -n 200 --no-pager 2>/dev/null \
       | grep -qE "duplicate column name|OperationalError"; then
    echo
    echo "Open WebUI is running but hit the known first-run migration bug." >&2
    echo "That is a SEPARATE fault from the namespacing one this script fixes." >&2
    echo "See 'When Open WebUI will not start' in the README." >&2
    exit 1
  fi
  echo
  echo "Open WebUI has not bound ${OW_PORT} yet — it was still running migrations"
  echo "when this script stopped waiting. Nothing is wrong with the namespacing"
  echo "fix; give it a few more minutes and check:"
  echo "  pct exec ${CT_ID} -- ss -lnt | grep ${OW_PORT}"
  echo "  pct exec ${CT_ID} -- journalctl -u open-webui -f"
fi
if [[ "$verdict" != "ok" ]]; then
  echo
  echo "Reminder: the mount-namespace hardening is OFF on this container. The"
  echo "installer now runs the same probe on every install, so a fresh install"
  echo "will make the same choice automatically."
fi
