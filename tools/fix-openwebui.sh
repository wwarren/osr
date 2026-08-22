#!/usr/bin/env bash
# fix-openwebui.sh — recover a container whose Open WebUI died mid-migration.
#
#   pct push <CTID> fix-openwebui.sh /tmp/fix.sh
#   pct exec <CTID> -- bash /tmp/fix.sh            # --dry-run to preview
#
# Two things go wrong together, and both are fixed here:
#
#   1. Every unit declared Requires= on its upstream. Requires= propagates
#      stop/restart, so a crash-looping litellm-proxy stopped ollama-router,
#      which stopped open-webui -- nine seconds into its first-ever start,
#      part way through the alembic migration. Fixed by rewriting those to
#      Wants= (ordering via After= is kept).
#
#   2. That interrupted migration left data/webui.db with the new column added
#      but the alembic revision unstamped, so every later start dies with
#      "duplicate column name: info_json". Fixed by moving the database aside
#      -- but ONLY after checking it holds no accounts, so an established
#      install is never silently wiped.
set -uo pipefail

OPENWEBUI_DIR="${OPENWEBUI_DIR:-/app/openwebui}"
REPO_DIR="${REPO_DIR:-/app/config-repo}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
DB="${OPENWEBUI_DIR}/data/webui.db"
PORT="$(grep -E '^PORT=' "${OPENWEBUI_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '\r')"
PORT="${PORT:-8080}"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ -t 1 ]]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else G=""; R=""; Y=""; B=""; N=""; fi
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
sec()  { printf '\n%s== %s%s\n' "$B" "$*" "$N"; }

[[ $EUID -eq 0 ]] || die "run this as root inside the container"

# ── 1. dependency propagation ────────────────────────────────────────────────
sec "1. Unit dependencies"
changed_units=false
fix_unit() {                     # fix_unit <file> <upstream unit>
  local f="$1" up="$2"
  [[ -f "$f" ]] || return 0
  grep -q "^Requires=${up}\$" "$f" || return 0
  if $DRY_RUN; then
    printf '  [dry-run] would rewrite Requires=%s -> Wants= in %s\n' "$up" "$f"
    changed_units=true       # so the "nothing to change" line stays truthful
    return 0
  fi
  # Fold the upstream into the existing Wants= line if there is one, so the
  # unit does not end up with two Wants= directives saying different things.
  if grep -q '^Wants=' "$f"; then
    sed -i -e "/^Requires=${up}\$/d" \
           -e "s|^Wants=\(.*\)\$|Wants=\1 ${up}|" "$f"
  else
    sed -i "s|^Requires=${up}\$|Wants=${up}|" "$f"
  fi
  changed_units=true
  ok "$(basename "$f"): Requires=${up} -> Wants="
}
for dir in "$UNIT_DIR" "${REPO_DIR}/services/ollama-router" \
           "${REPO_DIR}/services/ollama-monitor" "${REPO_DIR}/services/open-webui"; do
  fix_unit "${dir}/ollama-router.service"  "litellm-proxy.service"
  fix_unit "${dir}/ollama-monitor.service" "litellm-proxy.service"
  fix_unit "${dir}/open-webui.service"     "ollama-router.service"
done
$changed_units || ok "already using Wants= (nothing to change)"
if $changed_units && ! $DRY_RUN; then
  systemctl daemon-reload && ok "systemd reloaded"
fi

# ── 2. the database ──────────────────────────────────────────────────────────
sec "2. Open WebUI database"
$DRY_RUN || systemctl stop open-webui 2>/dev/null

if [[ ! -f "$DB" ]]; then
  ok "no database yet — it will be created cleanly on the next start"
else
  # Is the schema actually broken? If the column exists but alembic has not
  # stamped the revision that adds it, the next start repeats the ALTER.
  users="?"
  if command -v sqlite3 >/dev/null; then
    users="$(sqlite3 "$DB" 'SELECT count(*) FROM user;' 2>/dev/null || echo "?")"
  elif [[ -x "${OPENWEBUI_DIR}/venv/bin/python" ]]; then
    users="$("${OPENWEBUI_DIR}/venv/bin/python" - "$DB" <<'PY' 2>/dev/null || echo "?"
import sqlite3, sys
try:
    c = sqlite3.connect(sys.argv[1])
    print(c.execute("SELECT count(*) FROM user").fetchone()[0])
except Exception:
    print("?")
PY
)"
  fi
  printf '       accounts in the database: %s\n' "$users"

  if [[ "$users" == "0" || "$users" == "?" ]]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    if $DRY_RUN; then
      printf '  [dry-run] would move %s aside to %s.broken-%s\n' "$DB" "$DB" "$stamp"
    else
      for f in "$DB" "${DB}-wal" "${DB}-shm"; do
        [[ -e "$f" ]] && mv "$f" "${f}.broken-${stamp}"
      done
      ok "moved the half-migrated database aside (kept as *.broken-${stamp})"
    fi
    [[ "$users" == "?" ]] && warn "could not read the account count; the copy is kept, nothing is deleted"
  else
    warn "the database holds ${users} account(s) — NOT touching it."
    warn "This is an established install, so the schema needs repairing rather"
    warn "than replacing. Back it up, then stamp the current revision:"
    warn "  cp ${DB} ${DB}.bak"
    warn "  cd ${OPENWEBUI_DIR} && venv/bin/python -m alembic -c \\"
    warn "      venv/lib/python3.12/site-packages/open_webui/alembic.ini stamp head"
  fi
fi

# ── 3. start it, once, and wait ──────────────────────────────────────────────
sec "3. Starting Open WebUI"
if $DRY_RUN; then
  printf '  [dry-run] would start open-webui and wait for :%s\n' "$PORT"
else
  if ! systemctl start open-webui; then
    die "systemctl could not start open-webui (see: systemctl status open-webui)"
  fi
  printf '       first start runs migrations and downloads an embedding model;\n'
  printf '       waiting up to 10 minutes...\n'
  listening=false
  for i in $(seq 1 120); do
    if ss -lnt 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then listening=true; break; fi
    # Anything other than running or starting means waiting is pointless --
    # without this the loop sat out the full ten minutes on a unit that had
    # already given up.
    case "$(systemctl is-active open-webui 2>/dev/null)" in
      active|activating|reloading) ;;
      *) warn "the unit stopped while we were waiting"; break ;;
    esac
    sleep 5
    (( i % 12 == 0 )) && printf '       still starting (%dm)...\n' $(( i / 12 ))
  done
  if $listening; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/" || echo "000")"
    ok "listening on ${PORT}, HTTP ${code}"
  else
    warn "still not listening. The last 30 log lines:"
    journalctl -u open-webui -n 30 --no-pager | sed 's/^/       /' >&2
  fi
fi

# ── 4. why was litellm-proxy flapping ────────────────────────────────────────
sec "4. litellm-proxy"
state="$(systemctl is-active litellm-proxy 2>/dev/null || true)"
restarts="$(systemctl show litellm-proxy -p NRestarts --value 2>/dev/null || echo '?')"
printf '       is-active=%s  NRestarts=%s\n' "$state" "$restarts"
if [[ "$state" == "active" ]] && [[ "$restarts" == "0" ]]; then
  ok "healthy"
else
  warn "not healthy — with Wants= this no longer takes the UI down, but the"
  warn "LiteLLM fallback path is unavailable until it is fixed. Recent log:"
  journalctl -u litellm-proxy -n 30 --no-pager | sed 's/^/       /' >&2
  warn "Most often the generated YAML references a model no host serves."
  warn "Check:  manage-model-servers list"
  warn "        /app/router/venv/bin/litellm --config /app/router/litellm_config.yaml --port 4000 --host 127.0.0.1"
fi

sec "Done"
echo "If the UI is up, browse to http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}/"
echo "and create the admin account."
echo
echo "Commit the unit change so a later apply-config does not reintroduce it:"
echo "  manage-model-servers commit -m 'units: Wants= instead of Requires='"
