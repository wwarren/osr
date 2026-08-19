#!/usr/bin/env bash
# fix-openwebui-bind.sh — repair a container answering 502 from the TLS proxy.
#
#   pct push <CTID> fix-openwebui-bind.sh /tmp/fixbind.sh
#   pct exec <CTID> -- bash /tmp/fixbind.sh          # --dry-run to preview
#
# Cause: open-webui's serve() is declared
#
#     def serve(host: str = "0.0.0.0", port: int = 8080):
#
# with LITERAL defaults. It never reads HOST or PORT from the environment, so
# setting them in /app/openwebui/.env did nothing: Open WebUI kept binding
# 0.0.0.0:8080 — the port nginx now owns — died with "address already in use",
# and nginx returned 502 for 127.0.0.1:8088 where nothing was listening.
#
# Fix: pass --host/--port on the command line. Typer exposes plain keyword
# parameters as CLI options automatically, so the flags work, and a flag cannot
# be silently ignored the way the env vars were.
set -uo pipefail

UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
REPO_DIR="${REPO_DIR:-/app/config-repo}"
OPENWEBUI_DIR="${OPENWEBUI_DIR:-/app/openwebui}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
sec()  { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }

[[ $EUID -eq 0 ]] || die "run this as root inside the container"

WANT='ExecStart=/app/openwebui/venv/bin/open-webui serve --host ${HOST} --port ${PORT}'

sec "1. What is actually happening"
port="$(grep -E '^PORT=' "${OPENWEBUI_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')"
port="${port:-8080}"
host="$(grep -E '^HOST=' "${OPENWEBUI_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')"
printf '       .env says HOST=%s PORT=%s\n' "${host:-<unset>}" "$port"
if ss -lnt 2>/dev/null | grep -q ":${port}[[:space:]]"; then
  ok "something is already listening on ${port}"
else
  warn "nothing is listening on ${port} — this is what nginx 502s against"
fi
if journalctl -u open-webui -n 200 --no-pager 2>/dev/null \
     | grep -qiE "address already in use|error while attempting to bind"; then
  ok "confirmed: the journal shows a failed bind (it tried the wrong port)"
else
  warn "no bind error in the journal; the 502 may have another cause."
  warn "Check:  journalctl -u open-webui -n 50 --no-pager"
fi

sec "2. Unit file"
changed=false
fix_unit() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -q -- '--host' "$f" && { ok "$(basename "$f") already passes --host/--port"; return 0; }
  grep -q '^ExecStart=.*open-webui serve' "$f" || { warn "no open-webui ExecStart in $f"; return 0; }
  if $DRY_RUN; then
    printf '  [dry-run] would rewrite ExecStart in %s\n' "$f"
    changed=true; return 0
  fi
  # Replace the whole ExecStart line rather than appending, so running this
  # twice cannot produce "serve --host X --port Y --host X --port Y".
  python3 - "$f" "$WANT" <<'PY'
import sys
path, want = sys.argv[1], sys.argv[2]
out = []
for line in open(path, encoding="utf-8"):
    if line.startswith("ExecStart=") and "open-webui serve" in line:
        line = want + "\n"
    out.append(line)
open(path, "w", encoding="utf-8").write("".join(out))
PY
  changed=true
  ok "$(basename "$f"): ExecStart now passes --host/--port"
}
fix_unit "${UNIT_DIR}/open-webui.service"
fix_unit "${REPO_DIR}/services/open-webui/open-webui.service"
$changed || ok "nothing to change"

sec "3. Restart and wait"
if $DRY_RUN; then
  printf '  [dry-run] would daemon-reload and restart open-webui\n'
  exit 0
fi
systemctl daemon-reload
systemctl restart open-webui
printf '       waiting for %s (first start also runs migrations)...\n' "$port"
listening=false
for i in $(seq 1 120); do
  if ss -lnt 2>/dev/null | grep -q ":${port}[[:space:]]"; then listening=true; break; fi
  case "$(systemctl is-active open-webui 2>/dev/null)" in
    active|activating|reloading) ;;
    *) warn "the unit stopped while we were waiting"; break ;;
  esac
  sleep 5
  (( i % 12 == 0 )) && printf '       still starting (%dm)...\n' $(( i / 12 ))
done

if $listening; then
  ok "Open WebUI is listening on ${port}"
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 \
          "https://127.0.0.1:$(grep -oE 'listen +[0-9]+ +ssl' /etc/nginx/conf.d/ollama-smart-router.conf \
             2>/dev/null | head -1 | grep -oE '[0-9]+')/" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^[23] ]]; then
    ok "the proxy now answers HTTP ${code} (no more 502)"
  else
    warn "the proxy answered ${code}; check: journalctl -u nginx -n 30 --no-pager"
  fi
else
  warn "still not listening. Last 30 log lines:"
  journalctl -u open-webui -n 30 --no-pager | sed 's/^/       /' >&2
fi

sec "Done"
echo "Commit the unit change so a later apply-config does not undo it:"
echo "  manage-model-servers commit -m 'open-webui: pass --host/--port explicitly'"
