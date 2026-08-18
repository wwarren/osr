#!/usr/bin/env bash
# One-shot upgrade of a deployed ollama-smart-router configuration repo.
#
# The tiers were renamed twice and a fourth tier was added:
#
#   BACKEND_QWEN_HEAVY  ->  BACKEND_HEAVY  ->  BACKEND_LARGE
#   model_name qwen-heavy  ->  heavy  ->  large
#   (new)  xlarge, for 70B+ models
#
# manage-model-servers.sh deliberately carries no migration code, so a repo
# provisioned before this change keeps serving the old names — and because
# apply-config.sh is a straight copy *from* the repo, re-applying reinstalls
# them. This script brings the repo forward once. Run it, apply, delete it.
#
# It replaces router.py, monitor.py and manage-model-servers.sh with the
# versions carried inside the installer (the tier aliases live in the code, so
# renaming config alone would leave 'large'/'xlarge' missing from the model
# list), then rewrites router.env, router.ini and litellm_config.yaml in place
# so your servers, model tags and any hand-tuning survive.
#
# Usage:
#   ./migrate-config.sh --installer ./ollama-smart-router-install.sh [options]
#
#   --repo DIR        config repo to migrate      (default /app/config-repo)
#   --installer FILE  ollama-smart-router-install.sh, the source of the new
#                     router.py / monitor.py / manage-model-servers.sh.
#                     Omit to migrate only the config files (leaves the tier
#                     aliases incomplete — not recommended).
#   --dry-run         report what would change, write nothing
#   --apply           run install/apply-config.sh and restart the services
#   --no-backup       skip the tarball backup
#   -h, --help
#
# Safe to re-run: every step is idempotent and reports "already current".

set -euo pipefail

REPO_DIR="/app/config-repo"
INSTALLER=""
DRY_RUN=false
DO_APPLY=false
DO_BACKUP=true
CHANGES=0

c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
COLOR=1
[[ -t 1 ]] || { c_grn=""; c_yel=""; c_red=""; c_dim=""; c_off=""; COLOR=0; }

die()  { echo "${c_red}ERROR:${c_off} $*" >&2; exit 1; }
note() { echo "$*" >&2; }
step() { echo; echo "${c_dim}── $*${c_off}"; }
did()  { CHANGES=$((CHANGES + 1)); echo "  ${c_grn}changed${c_off}  $*"; }
same() { echo "  ${c_dim}current  $*${c_off}"; }
warn() { echo "  ${c_yel}note${c_off}     $*"; }

usage() { sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case "$1" in
    --repo)      REPO_DIR="${2:?--repo needs a directory}"; shift 2 ;;
    --installer) INSTALLER="${2:?--installer needs a file}"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --apply)     DO_APPLY=true; shift ;;
    --no-backup) DO_BACKUP=false; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option '$1' (try --help)" ;;
  esac
done

ENV_FILE="${REPO_DIR}/env/router.env"
ROUTER_INI="${REPO_DIR}/services/ollama-router/router.ini"
LITELLM_YAML="${REPO_DIR}/services/litellm-proxy/litellm_config.yaml"

[[ -d "$REPO_DIR" ]]  || die "config repo not found: ${REPO_DIR} (use --repo)"
[[ -f "$ENV_FILE" ]]  || die "not a config repo: ${ENV_FILE} is missing"
command -v python3 >/dev/null || die "python3 is required"
[[ -z "$INSTALLER" || -f "$INSTALLER" ]] || die "installer not found: ${INSTALLER}"

echo "Repo:      ${REPO_DIR}"
echo "Installer: ${INSTALLER:-<none — config files only>}"
$DRY_RUN && note "(dry run — nothing will be written)"

# ── backup ────────────────────────────────────────────────────────────────────
if $DO_BACKUP && ! $DRY_RUN; then
  backup="/root/config-repo-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  if tar -czf "$backup" -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")" 2>/dev/null; then
    note "Backup: ${backup}"
  else
    backup="$(mktemp -d)/config-repo-backup.tar.gz"
    tar -czf "$backup" -C "$(dirname "$REPO_DIR")" "$(basename "$REPO_DIR")"
    note "Backup: ${backup}"
  fi
fi

# ── 1. code: router.py / monitor.py / manage-model-servers.sh ────────────────
# The tier aliases the router advertises on /v1/models come from the CODE
# (TIER_XLARGE and friends), not only from router.ini. Migrating config alone
# leaves 'large' and 'xlarge' absent from Open WebUI's picker.
step "service code"
if [[ -z "$INSTALLER" ]]; then
  warn "no --installer given; router.py/monitor.py left as-is."
  warn "'large' and 'xlarge' will NOT appear until these are updated."
else
  extract_one() {  # <repo-relative-path> <heredoc-marker>
    python3 - "$INSTALLER" "$1" "$2" <<'EXTRACT'
import re, sys
installer, target, marker = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(installer, encoding="utf-8").read().split("\n")
# The generator line is:  cat > "${REPO_DIR}/<target>" <<'MARKER'
needle = 'cat > "${REPO_DIR}/%s" <<' % target
start = None
for i, line in enumerate(text):
    if line.startswith(needle):
        start = i + 1
        break
if start is None:
    sys.exit("could not find the generator for %s" % target)
try:
    end = next(j for j in range(start, len(text)) if text[j] == marker)
except StopIteration:
    sys.exit("unterminated %s heredoc for %s" % (marker, target))
sys.stdout.write("\n".join(text[start:end]) + "\n")
EXTRACT
  }

  install_one() {  # <repo-relative-path> <marker> [mode]
    local rel="$1" marker="$2" mode="${3:-0644}"
    local dest="${REPO_DIR}/${rel}" tmp
    tmp="$(mktemp)"
    if ! extract_one "$rel" "$marker" > "$tmp"; then
      rm -f "$tmp"; die "extraction failed for ${rel}"
    fi
    [[ -s "$tmp" ]] || { rm -f "$tmp"; die "extracted an empty ${rel}"; }
    # A shell file must at least parse; a python file must at least compile.
    case "$rel" in
      *.sh) bash -n "$tmp" || { rm -f "$tmp"; die "extracted ${rel} does not parse"; } ;;
      *.py) python3 -c 'import sys;compile(open(sys.argv[1]).read(),"x","exec")' "$tmp" \
              || { rm -f "$tmp"; die "extracted ${rel} does not compile"; } ;;
    esac
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
      same "$rel"; rm -f "$tmp"; return 0
    fi
    if $DRY_RUN; then
      did "$rel (would replace, $(wc -l < "$tmp") lines)"
    else
      mkdir -p "$(dirname "$dest")"
      cat "$tmp" > "$dest"; chmod "$mode" "$dest"
      did "$rel"
    fi
    rm -f "$tmp"
  }

  install_one "services/ollama-router/router.py"   PYEOF
  install_one "services/ollama-monitor/monitor.py" PYEOF
  install_one "install/apply-config.sh"            APPLYEOF 0755
  install_one "install/manage-model-servers.sh"    MANAGEEOF 0755
fi

# ── 2. env/router.env ─────────────────────────────────────────────────────────
step "env/router.env"
rc=0
python3 - "$ENV_FILE" "$DRY_RUN" "$COLOR" <<'ENVMIG' || rc=$?
import sys
path, dry = sys.argv[1], sys.argv[2] == "true"
COLOR = len(sys.argv) > 3 and sys.argv[3] == "1"
GRN = "\033[32m" if COLOR else ""
DIM = "\033[2m" if COLOR else ""
OFF = "\033[0m" if COLOR else ""
def changed(msg): print("  %schanged%s  %s" % (GRN, OFF, msg))
def current(msg): print("  %scurrent  %s%s" % (DIM, msg, OFF))
lines = open(path, encoding="utf-8").read().split("\n")

# current -> older names, most recent legacy first.
RENAMES = [
    ("BACKEND_FAST",       ["BACKEND_QWEN_FAST"]),
    ("BACKEND_MEDIUM",     ["BACKEND_QWEN_MEDIUM"]),
    ("BACKEND_LARGE",      ["BACKEND_HEAVY", "BACKEND_QWEN_HEAVY"]),
    ("MODEL_LARGE",        ["MODEL_HEAVY"]),
    ("TIER_LARGE_SERVERS", ["TIER_HEAVY_SERVERS"]),
]

def key_of(line):
    return line.split("=", 1)[0] if "=" in line and not line.lstrip().startswith("#") else None

present = {key_of(l) for l in lines if key_of(l)}
out, msgs = [], []
for line in lines:
    k = key_of(line)
    if k is None:
        out.append(line); continue
    replaced = False
    # NB: not named `current` -- that would shadow the current() reporter above
    # and only blow up on a second, already-migrated run.
    for modern, legacies in RENAMES:
        if k in legacies:
            if modern in present:
                # Both exist (hand-edited): the modern key wins, drop the stale.
                msgs.append("dropped stale %s (%s already set)" % (k, modern))
                replaced = True
                break
            # Rename in place so the file keeps its key order.
            out.append(modern + "=" + line.split("=", 1)[1])
            present.add(modern)
            msgs.append("%s -> %s" % (k, modern))
            replaced = True
            break
    if not replaced:
        out.append(line)

# The new tier, added empty: a migration must not invent a server assignment.
for k in ("BACKEND_XLARGE", "MODEL_XLARGE"):
    if k not in present:
        while out and out[-1].strip() == "":
            out.pop()
        out.append(k + "=")
        msgs.append("added %s (empty)" % k)
        present.add(k)

if msgs:
    if not dry:
        # Copy content rather than replace the file, so it keeps its
        # 0640 root:ollama-router ownership and mode.
        open(path, "w", encoding="utf-8").write("\n".join(out) + ("" if out and out[-1]=="" else "\n"))
    for m in msgs:
        changed(m)
    sys.exit(10)
current("no legacy keys")
ENVMIG
[[ $rc -eq 10 ]] && CHANGES=$((CHANGES + 1)); [[ $rc -le 10 ]] || exit $rc

# ── 3. services/ollama-router/router.ini ──────────────────────────────────────
step "services/ollama-router/router.ini"
if [[ ! -f "$ROUTER_INI" ]]; then
  warn "router.ini absent — router.py falls back to its built-in defaults."
else
rc=0
python3 - "$ROUTER_INI" "$DRY_RUN" "$COLOR" <<'INIMIG' || rc=$?
import re, sys
path, dry = sys.argv[1], sys.argv[2] == "true"
COLOR = len(sys.argv) > 3 and sys.argv[3] == "1"
GRN = "\033[32m" if COLOR else ""
DIM = "\033[2m" if COLOR else ""
OFF = "\033[0m" if COLOR else ""
def changed(msg): print("  %schanged%s  %s" % (GRN, OFF, msg))
def current(msg): print("  %scurrent  %s%s" % (DIM, msg, OFF))
lines = open(path, encoding="utf-8").read().split("\n")
msgs = []

# Renamed tunables, valid in any section.
KEY_RENAMES = {
    "heavy_params": "large_params",
    "prefer_larger_heavy": "prefer_larger",
    "prefer_smaller_fast": "prefer_smaller",
}
# In these sections the bare key "heavy" became "large".
TIER_SECTIONS = {"thresholds", "keywords", "tiers"}
# Keys that must exist after the migration, with their current defaults.
REQUIRED = {
    "thresholds": [("xlarge", "2000")],
    "keywords":   [("xlarge", '["prove", "derive", "rigorous", "comprehensive", '
                              '"exhaustive", "step by step proof", "entire codebase", '
                              '"whole repository", "research report", "literature review"]')],
    "tiers":      [("xlarge", "xlarge")],
    "discovery":  [("xlarge_params", "70:999")],
}
KV = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(.*)$")

section = None
seen = {}          # section -> set(keys)
out = []
for line in lines:
    m_sec = re.match(r"^\s*\[([^\]]+)\]", line)
    if m_sec:
        section = m_sec.group(1).strip().lower()
        seen.setdefault(section, set())
        out.append(line); continue
    m = KV.match(line)
    if not m or line.lstrip().startswith(("#", ";")):
        out.append(line); continue
    indent, key, sep, value = m.groups()
    orig_key, orig_value = key, value

    if key in KEY_RENAMES:
        key = KEY_RENAMES[key]
    elif section in TIER_SECTIONS and key == "heavy":
        key = "large"

    # Values: tier ALIASES only. Model tags like qwen3:32b must survive.
    value = re.sub(r"\bqwen-heavy\b", "large", value)
    value = re.sub(r"\bqwen-(fast|medium)\b", r"\1", value)
    if section == "tiers":
        value = re.sub(r"\bheavy\b", "large", value)

    # The old band ran to the top. Split it, but only if it is still the
    # untouched default — a hand-tuned ceiling is the operator's decision.
    if section == "discovery" and key == "large_params" and value.strip() in ("20:999", "20:1000"):
        value = "20:70"

    if key != orig_key or value != orig_value:
        msgs.append("%s%s -> %s%s" % (
            orig_key, (" = " + orig_value.strip()) if value != orig_value else "",
            key, (" = " + value.strip()) if value != orig_value else ""))
    seen.setdefault(section, set()).add(key)
    out.append(indent + key + sep + value)

# Append any missing required key at the END of its section, so comments and
# ordering elsewhere are untouched.
def section_end(buf, name):
    start = None
    for i, l in enumerate(buf):
        m = re.match(r"^\s*\[([^\]]+)\]", l)
        if m and m.group(1).strip().lower() == name:
            start = i; break
    if start is None:
        return None
    i = start + 1
    last = start
    while i < len(buf):
        if re.match(r"^\s*\[([^\]]+)\]", buf[i]):
            break
        if buf[i].strip():
            last = i
        i += 1
    return last + 1

for name, wanted in REQUIRED.items():
    for key, default in wanted:
        if key in seen.get(name, set()):
            continue
        pos = section_end(out, name)
        if pos is None:
            while out and out[-1].strip() == "":
                out.pop()
            out.extend(["", "[%s]" % name, "%s = %s" % (key, default)])
        else:
            out.insert(pos, "%s = %s" % (key, default))
        seen.setdefault(name, set()).add(key)
        msgs.append("added [%s] %s = %s" % (name, key, default.split("[")[0].strip() or default[:40]))

if msgs:
    if not dry:
        open(path, "w", encoding="utf-8").write("\n".join(out))
    for m in msgs:
        changed(m)
    sys.exit(10)
current("no legacy tunables")
INIMIG
[[ $rc -eq 10 ]] && CHANGES=$((CHANGES + 1)); [[ $rc -le 10 ]] || exit $rc
fi

# ── 4. services/litellm-proxy/litellm_config.yaml ────────────────────────────
step "services/litellm-proxy/litellm_config.yaml"
if [[ ! -f "$LITELLM_YAML" ]]; then
  warn "litellm_config.yaml absent — skipped."
else
rc=0
python3 - "$LITELLM_YAML" "$DRY_RUN" "$COLOR" <<'YAMLMIG' || rc=$?
import re, sys
path, dry = sys.argv[1], sys.argv[2] == "true"
COLOR = len(sys.argv) > 3 and sys.argv[3] == "1"
GRN = "\033[32m" if COLOR else ""
DIM = "\033[2m" if COLOR else ""
OFF = "\033[0m" if COLOR else ""
def changed(msg): print("  %schanged%s  %s" % (GRN, OFF, msg))
def current(msg): print("  %scurrent  %s%s" % (DIM, msg, OFF))
text = open(path, encoding="utf-8").read()
orig = text
msgs = []

# Rename tier ALIASES only. A model tag (model: ollama/qwen3:32b) must survive,
# so the substitutions are anchored to where aliases actually appear:
# "model_name:" values and the fallbacks map.
def rename_alias(s):
    s = re.sub(r"\bqwen-heavy\b", "large", s)
    s = re.sub(r"\bqwen-(fast|medium)\b", r"\1", s)
    return s

new_lines = []
for line in text.split("\n"):
    m = re.match(r"^(\s*-?\s*model_name:\s*)(\S+)\s*$", line)
    if m:
        before = m.group(2)
        after = rename_alias(before)
        after = re.sub(r"^heavy$", "large", after)
        if after != before:
            msgs.append("model_name %s -> %s" % (before, after))
        new_lines.append(m.group(1) + after)
        continue
    # Fallback entries:  - heavy: ["medium", "fast"]
    if re.match(r"^\s*-\s*[A-Za-z0-9_-]+\s*:\s*\[", line):
        after = rename_alias(line)
        after = re.sub(r"(^\s*-\s*)heavy(\s*:)", r"\1large\2", after)
        after = re.sub(r'"heavy"', '"large"', after)
        if after != line:
            msgs.append("fallback entry updated")
        new_lines.append(after)
        continue
    new_lines.append(line)
text = "\n".join(new_lines)

# LiteLLM only advertises a tier that has at least one deployment, so with no
# xlarge servers assigned yet the fallback chain is what keeps an xlarge
# request answerable on the LiteLLM path.
if re.search(r"^\s*fallbacks:\s*$", text, re.M) and not re.search(r"^\s*-\s*xlarge\s*:", text, re.M):
    text = re.sub(r"(^\s*fallbacks:\s*$)",
                  r'\1\n    - xlarge: ["large", "medium", "fast"]',
                  text, count=1, flags=re.M)
    msgs.append('added fallback  - xlarge: ["large", "medium", "fast"]')

if text != orig:
    if not dry:
        open(path, "w", encoding="utf-8").write(text)
    for m in dict.fromkeys(msgs):
        changed(m)
    sys.exit(10)
current("no legacy aliases")
YAMLMIG
[[ $rc -eq 10 ]] && CHANGES=$((CHANGES + 1)); [[ $rc -le 10 ]] || exit $rc
fi

# ── 5. verify ─────────────────────────────────────────────────────────────────
step "verification"
if $DRY_RUN; then
  same "skipped — a dry run writes nothing, so the files still read as legacy"
else
  leftovers="$(grep -rnE '\bqwen-(fast|medium|heavy)\b|^BACKEND_(QWEN_)?HEAVY=|^MODEL_HEAVY=|^(heavy|heavy_params|prefer_larger_heavy|prefer_smaller_fast) *=' \
    "$REPO_DIR" 2>/dev/null || true)"
  if [[ -n "$leftovers" ]]; then
    warn "legacy names still present:"
    while IFS= read -r l; do [[ -n "$l" ]] && printf '           %s\n' "$l"; done <<< "$leftovers"
  else
    same "no legacy names anywhere in the repo"
  fi

  # A hand-tuned ceiling is left alone on purpose, but if it now reaches into
  # the xlarge band the two overlap and `large` can take xlarge's model.
  if [[ -f "$ROUTER_INI" ]]; then
    lp="$(grep -E '^large_params *=' "$ROUTER_INI" | head -1 | cut -d= -f2- | tr -d ' ')"
    xp="$(grep -E '^xlarge_params *=' "$ROUTER_INI" | head -1 | cut -d= -f2- | tr -d ' ')"
    if [[ -n "$lp" && -n "$xp" ]]; then
      lhigh="${lp##*:}"; xlow="${xp%%:*}"
      if awk "BEGIN{exit !(${lhigh:-0} > ${xlow:-0})}" 2>/dev/null; then
        warn "large_params (${lp}) overlaps xlarge_params (${xp})."
        warn "Bands should be disjoint, or 'large' will take the model that"
        warn "defines 'xlarge'. Left as-is because it is not the default."
      fi
    fi
  fi

  echo "  tier backends now:"
  for t in fast medium large xlarge; do
    key="BACKEND_$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')"
    if grep -q "^${key}=" "$ENV_FILE"; then
      val="$(grep "^${key}=" "$ENV_FILE" | head -1 | cut -d= -f2-)"
      printf '    %-7s %s\n' "$t" "${val:-${c_yel}<no servers assigned>${c_off}}"
    else
      printf '    %-7s %s\n' "$t" "${c_red}<key missing>${c_off}"
    fi
  done
fi

# ── 6. apply ──────────────────────────────────────────────────────────────────
step "next steps"
if $DRY_RUN; then
  note "Dry run — nothing was written. Re-run without --dry-run to apply."
elif (( CHANGES == 0 )); then
  note "Repo was already current; nothing to do."
elif $DO_APPLY; then
  if [[ -f "${REPO_DIR}/install/apply-config.sh" ]] && command -v systemctl >/dev/null; then
    bash "${REPO_DIR}/install/apply-config.sh" "$REPO_DIR"
    systemctl daemon-reload
    systemctl restart litellm-proxy ollama-router ollama-monitor open-webui
    note "Applied and restarted."
    note "Check:  curl -s localhost:8000/v1/models | grep -o '\"id\": *\"[^\"]*\"'"
  else
    die "cannot apply here (no apply-config.sh or no systemctl) — run this in the container"
  fi
else
  cat <<EOS

  Nothing has been applied to the running services yet. To do that:

    bash ${REPO_DIR}/install/apply-config.sh ${REPO_DIR}
    systemctl daemon-reload
    systemctl restart litellm-proxy ollama-router ollama-monitor open-webui

  Then confirm the tier aliases:

    curl -s localhost:8000/v1/models | grep -o '"id": *"[^"]*"'

  Give xlarge some capacity (it is empty by design):

    manage-model-servers set-tier  xlarge <addr>
    manage-model-servers set-model xlarge <tag> --apply --commit

  Commit the migrated repo so Gitea matches the container:

    git -C ${REPO_DIR} add -A && git -C ${REPO_DIR} commit -m 'Migrate tiers: heavy -> large, add xlarge'
    manage-model-servers commit 'Migrate tiers: heavy -> large, add xlarge'

  Open WebUI caches the model list in its own database. If the picker still
  shows the old names after the restart, reload the page; a pinned default
  model is cleared in Admin Panel -> Settings -> Models.
EOS
fi
