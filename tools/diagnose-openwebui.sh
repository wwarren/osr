#!/usr/bin/env bash
# diagnose-openwebui.sh — work out why Open WebUI is not reachable.
#
# Run INSIDE the container:
#   pct push <CTID> diagnose-openwebui.sh /tmp/diag.sh
#   pct exec <CTID> -- bash /tmp/diag.sh
#
# Read-only: it starts nothing, stops nothing and writes nothing outside /tmp.
# Every check prints PASS / FAIL / WARN plus the evidence, and the summary at
# the end names the most likely cause.
set -uo pipefail

OPENWEBUI_DIR="${OPENWEBUI_DIR:-/app/openwebui}"
ENV_FILE="${OPENWEBUI_DIR}/.env"
UNIT="open-webui"

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi

problems=()
pass() { printf '  %sPASS%s %s\n' "$G" "$N" "$*"; }
fail() { printf '  %sFAIL%s %s\n' "$R" "$N" "$*"; problems+=("$*"); }
warn() { printf '  %sWARN%s %s\n' "$Y" "$N" "$*"; }
info() { printf '       %s\n' "$*"; }
sec()  { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }

# --- 1. is the unit even running -------------------------------------------
sec "1. Service state"
state="$(systemctl is-active "$UNIT" 2>/dev/null || true)"
enabled="$(systemctl is-enabled "$UNIT" 2>/dev/null || true)"
restarts="$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || echo '?')"
result="$(systemctl show "$UNIT" -p Result --value 2>/dev/null || echo '?')"
mainpid="$(systemctl show "$UNIT" -p MainPID --value 2>/dev/null || echo 0)"
info "is-active=${state}  is-enabled=${enabled}  NRestarts=${restarts}  Result=${result}  MainPID=${mainpid}"
case "$state" in
  active)     pass "the unit is running" ;;
  activating) warn "still starting — first boot downloads an embedding model (TimeoutStartSec=600)" ;;
  *)          fail "the unit is not running (${state:-unknown})" ;;
esac
# A high restart count with an active state is a crash loop, not a healthy service.
if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts > 3 )); then
  fail "restarted ${restarts} times — it is crash-looping, so a momentary 'active' means nothing"
fi

# --- 2. what it says on the way down ---------------------------------------
sec "2. Last 40 journal lines"
journalctl -u "$UNIT" -n 40 --no-pager 2>/dev/null | sed 's/^/       /' || info "(no journal)"
jrnl="$(journalctl -u "$UNIT" -n 200 --no-pager 2>/dev/null || true)"
case "$jrnl" in
  # This one MUST be tested before the generic "Permission denied" below, which
  # it would otherwise match — sending you to look at file modes for a failure
  # that has nothing to do with them. 226/NAMESPACE means systemd could not
  # build the private mount namespace that PrivateTmp=/ProtectSystem=/
  # ProtectHome= are made of, so the binary never ran at all.
  *"226/NAMESPACE"*|*"Failed to set up mount namespacing"*)
    fail "systemd could not build a mount namespace (status=226/NAMESPACE)."
    fail "  The binary NEVER RAN — this is not a file-permission problem."
    fail "  PrivateTmp=/ProtectSystem=/ProtectHome= need a namespace this"
    fail "  container is not allowed to create. On the PROXMOX HOST run:"
    fail "      ./fix-service-namespacing.sh <CTID>"
    fail "  which enables nesting=1 if that is what is missing, and otherwise"
    fail "  removes those three directives from the units."
    ;;
  *"No space left on device"*)   fail "the journal reports a FULL DISK — see section 6" ;;
  *"Permission denied"*)         fail "the journal reports a permission error — see section 5" ;;
  *"Address already in use"*)    fail "the port is already taken by another process — see section 4" ;;
  *"ModuleNotFoundError"*|*"ImportError"*) fail "a Python import failed — the venv is incomplete, see section 3" ;;
esac

# --- 3. the venv and the entry point ---------------------------------------
sec "3. Virtualenv"
py="${OPENWEBUI_DIR}/venv/bin/python"
bin="${OPENWEBUI_DIR}/venv/bin/open-webui"
if [[ -x "$py" ]]; then
  pass "python: $("$py" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>&1)"
  # open-webui requires >=3.11,<3.13; 3.13 is what Debian 13 ships, which is
  # exactly the mistake the dedicated interpreter exists to avoid.
  pv="$("$py" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
  case "$pv" in
    3.11|3.12) : ;;
    *) fail "venv python is ${pv}; open-webui needs >=3.11,<3.13" ;;
  esac
else
  fail "no venv interpreter at ${py}"
fi
if [[ -x "$bin" ]]; then
  pass "entry point present: ${bin}"
else
  fail "missing entry point ${bin} — the pip install did not complete"
fi
ver="$("$py" - <<'PY' 2>/dev/null || true
import importlib.metadata as m
try: print(m.version("open-webui"))
except Exception as e: print("NOT INSTALLED (%s)" % e)
PY
)"
info "installed open-webui: ${ver:-unknown}"
# Import the app itself: a missing native dependency shows up here, not in pip.
if [[ -x "$py" ]]; then
  if out="$("$py" -c 'import open_webui' 2>&1)"; then
    pass "the package imports cleanly"
  else
    fail "importing open_webui fails: $(printf '%s' "$out" | tail -1)"
  fi
fi

# --- 4. is anything listening ----------------------------------------------
sec "4. Listening sockets"
port="$(grep -E '^PORT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')"
host="$(grep -E '^HOST=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')"
port="${port:-8080}"; host="${host:-0.0.0.0}"
info "configured HOST=${host} PORT=${port}"
if command -v ss >/dev/null; then
  ss -lntp 2>/dev/null | sed 's/^/       /'
  listen="$(ss -lnt 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {print $4}')"
  if [[ -n "$listen" ]]; then
    pass "something is listening on ${listen}"
    case "$listen" in
      127.0.0.1:*) fail "bound to LOOPBACK only — unreachable from the network; HOST must be 0.0.0.0" ;;
    esac
  else
    fail "nothing is listening on port ${port}"
  fi
else
  warn "ss not available; install iproute2 to check listeners"
fi

# --- 5. files and permissions ----------------------------------------------
sec "5. Files and ownership"
for p in "$OPENWEBUI_DIR" "${OPENWEBUI_DIR}/data" "${OPENWEBUI_DIR}/cache" "$ENV_FILE"; do
  if [[ -e "$p" ]]; then
    info "$(stat -c '%A %U:%G  %n' "$p")"
  else
    fail "missing: ${p}"
  fi
done
# The service runs as ollama-router; if it cannot write DATA_DIR it dies at boot.
if id ollama-router >/dev/null 2>&1; then
  for p in "${OPENWEBUI_DIR}/data" "${OPENWEBUI_DIR}/cache"; do
    [[ -d "$p" ]] || continue
    if runuser -u ollama-router -- test -w "$p" 2>/dev/null; then
      pass "ollama-router can write ${p}"
    else
      fail "ollama-router CANNOT write ${p} — fix: chown -R ollama-router:ollama-router ${OPENWEBUI_DIR}"
    fi
  done
else
  fail "the ollama-router account does not exist"
fi
if [[ -r "$ENV_FILE" ]]; then
  info "--- ${ENV_FILE} (keys redacted) ---"
  sed -E 's/^(OPENAI_API_KEYS|WEBUI_SECRET_KEY)=.*/\1=<redacted>/' "$ENV_FILE" | sed 's/^/       /'
else
  fail "cannot read ${ENV_FILE}"
fi

# --- 6. disk ----------------------------------------------------------------
sec "6. Disk space"
df -h / /app 2>/dev/null | sed 's/^/       /'
avail_pct="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [[ -n "$avail_pct" ]] && (( avail_pct >= 95 )); then
  fail "root filesystem is ${avail_pct}% full — Open WebUI cannot write its database"
elif [[ -n "$avail_pct" ]] && (( avail_pct >= 85 )); then
  warn "root filesystem is ${avail_pct}% full"
else
  pass "disk has room (${avail_pct:-?}% used)"
fi
# The CUDA fallback is the usual reason a 32 GB rootfs fills up.
if [[ -d "${OPENWEBUI_DIR}/venv" ]]; then
  info "venv size: $(du -sh "${OPENWEBUI_DIR}/venv" 2>/dev/null | cut -f1)"
  if compgen -G "${OPENWEBUI_DIR}/venv/lib/python*/site-packages/nvidia" >/dev/null; then
    warn "CUDA wheels are present — TORCH_CPU_ONLY fell back; this venv is ~7.5 GB"
  fi
fi

# --- 7. does it actually answer --------------------------------------------
sec "7. HTTP"
if command -v curl >/dev/null; then
  for target in "127.0.0.1:${port}" "$(hostname -I 2>/dev/null | awk '{print $1}'):${port}"; do
    [[ "$target" == :* ]] && continue
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${target}/" 2>/dev/null)"
    if [[ "$code" =~ ^[23] ]]; then
      pass "http://${target}/ -> ${code}"
    else
      fail "http://${target}/ -> ${code:-no answer}"
    fi
  done
else
  warn "curl not available"
fi

# --- 8. the dependency it Requires ------------------------------------------
sec "8. Upstream dependency"
# open-webui has Requires=ollama-router.service: if that unit fails, systemd
# stops open-webui too, and the symptom is 'unreachable' with a clean journal.
for dep in ollama-router litellm-proxy; do
  s="$(systemctl is-active "$dep" 2>/dev/null || true)"
  if [[ "$s" == "active" ]]; then pass "${dep} is ${s}"
  else fail "${dep} is ${s:-unknown} — Requires= pulls open-webui down with it"; fi
done

# --- verdict ----------------------------------------------------------------
printf '\n%s== Summary%s\n' "$B" "$N"
if ((${#problems[@]} == 0)); then
  pass "nothing failed in the container — if it is unreachable from your desk,"
  info "the problem is outside: Proxmox firewall (/etc/pve/firewall/<CTID>.fw),"
  info "the bridge/VLAN, or the client's route. Check from the Proxmox host:"
  info "  pct exec <CTID> -- curl -sI localhost:${port} | head -1"
  info "  curl -sI http://$(hostname -I 2>/dev/null | awk '{print $1}'):${port} | head -1"
else
  printf '  %d problem(s) found, most important first:\n' "${#problems[@]}"
  printf '    - %s\n' "${problems[@]}"
fi
echo
echo "Useful follow-ups:"
echo "  systemctl status ${UNIT} -l --no-pager"
echo "  journalctl -u ${UNIT} -n 200 --no-pager"
echo "  ${OPENWEBUI_DIR}/venv/bin/open-webui serve   # run it in the foreground"
