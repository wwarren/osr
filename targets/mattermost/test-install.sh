#!/usr/bin/env bash
# install-target.sh: helpers and the dry run, then whole runs as root against a
# fake mmctl (users, teams, channels, config and webhooks kept in a JSON state
# file), stubbed systemctl/runuser and a fake ping endpoint (curl). Nothing is
# installed or started.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=$here/install-target.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/mattermost-target-test.XXXXXX")
cleanup() { [[ $tmp == "${TMPDIR:-/tmp}"/mattermost-target-test.* ]] && rm -rf -- "$tmp"; }
trap cleanup EXIT

bash -n "$script" || fail 'shell syntax'

# --- helpers --------------------------------------------------------------------
# shellcheck disable=SC1090
source <(awk '/^# Install helpers/{c=1;next} /^# End install helpers\./{c=0} c' "$script")
for helper in valid_handle valid_username valid_email json_find config_value dropin write_secret; do
  declare -F "$helper" >/dev/null || fail "helper extraction failed: $helper"
done
valid_handle ollama-monitor && valid_username mmadmin || fail 'valid names refused'
for bad in 'Ollama Monitor' -x UPPER; do if valid_handle "$bad"; then fail "accepted handle '$bad'"; fi; done
for bad in X 9admin ab; do if valid_username "$bad"; then fail "accepted user name '$bad'"; fi; done
[[ $(printf '[{"id":"a1","name":"ops"},{"id":"b2","name":"ollama"}]' | json_find name ollama) == b2 ]] || fail 'json_find in a list'
[[ $(printf '{"id":"c3","username":"MMadmin"}' | json_find username mmadmin) == c3 ]] || fail 'json_find in one object, ignoring case'
[[ $(printf '{"id":"d4","name":"x"}\n{"id":"e5","name":"y"}\n' | json_find name y) == e5 ]] || fail 'json_find in one object per line'
[[ $(printf '[{"id":"f6","channel_id":"ch"}]' | json_find id f6 channel_id) == ch ]] || fail 'json_find RESULT field'
if printf '[]' | json_find name nope >/dev/null; then fail 'json_find matched nothing and succeeded'; fi
[[ $(printf '"http://192.0.2.76:8065"\n' | config_value) == http://192.0.2.76:8065 ]] || fail 'config_value strips JSON quotes'
[[ $(printf 'http://x:8065\n' | config_value) == http://x:8065 ]] || fail 'config_value keeps a plain value'
[[ $(dropin) == *'Environment=MM_SERVICESETTINGS_ENABLELOCALMODE=true'* ]] || fail 'drop-in'
pass 'helpers: names, JSON lookups in every mmctl output shape, config values and the drop-in'

out=$(bash "$script" --dry-run) || fail 'dry run'
[[ $out == *'MM_SERVICESETTINGS_ENABLELOCALMODE=true'* && $out == *'incoming webhook for ollama:ollama-monitor'* ]] || fail "dry run: $out"
for bad in 'MATTERMOST_TEAM=Ops Team' MATTERMOST_CHANNEL=x MATTERMOST_ADMIN_USER=Admin MATTERMOST_ADMIN_EMAIL=nope; do
  if env "$bad" bash "$script" --dry-run >/dev/null 2>&1; then fail "accepted $bad"; fi
done
pass 'the dry run plans the setup; bad team, channel, user and email values are refused'

if (( EUID != 0 )); then
  printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
  printf '%s Mattermost target install cases passed. Nothing was installed.\n' "$passed"
  exit 0
fi

# --- whole runs -------------------------------------------------------------------
bin=$tmp/bin; state=$tmp/state; log=$tmp/calls.log
mkdir -p "$bin" "$state"
export FAKE_STATE=$state FAKE_LOG=$log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub runuser 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
stub id '[[ $1 == mattermost ]]'
stub sleep 'exit 0'
stub hostname 'if [[ ${1:-} == -I ]]; then echo "192.0.2.76 fd00::76"; else echo mattermost; fi'
stub systemctl 'case $1 in restart) [[ -n ${FAKE_NO_START:-} ]] || touch "$FAKE_STATE/running" ;; esac; exit 0'
stub curl '[[ -e $FAKE_STATE/running ]] || exit 7; [[ ${*: -1} == */api/v4/system/ping ]]'
cat > "$bin/mmctl" <<'EOF'
#!/usr/bin/env python3
import json, os, random, string, sys
state_file = os.path.join(os.environ["FAKE_STATE"], "mm.json")
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("mmctl " + " ".join(sys.argv[1:]) + "\n")
if not os.path.exists(os.path.join(os.environ["FAKE_STATE"], "running")):
    sys.exit("Error: socket file not found")
try:
    st = json.load(open(state_file))
except FileNotFoundError:
    st = {"users": [], "teams": [], "channels": [], "hooks": [], "config": {
        "ServiceSettings.SiteURL": os.environ.get("FAKE_SITE_URL", "http://192.0.2.76:8065")}}
args = [a for a in sys.argv[1:] if a not in ("--local", "--suppress-warnings")]
as_json = "--json" in args
args = [a for a in args if a != "--json"]
def opt(name):
    # Like mmctl's flag parser, the last occurrence wins.
    hits = [i for i, a in enumerate(args[:-1]) if a == name]
    return args[hits[-1] + 1] if hits else ""
def new_id():
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(26))
def out(value):
    print(json.dumps(value) if as_json else value)
cmd = " ".join(args[:2])
if cmd == "system version":
    print("Server version 10.11.0")
elif cmd == "config get":
    print(json.dumps(st["config"].get(args[2], "")))
elif cmd == "config set":
    st["config"][args[2]] = args[3]
elif cmd == "user list":
    out(st["users"])
elif cmd == "user create":
    st["users"].append({"id": new_id(), "username": opt("--username"), "email": opt("--email"),
                        "roles": "system_admin system_user" if "--system-admin" in args else "system_user"})
elif cmd == "team list":
    out(st["teams"])
elif cmd == "team create":
    st["teams"].append({"id": new_id(), "name": opt("--name"), "type": "I" if "--private" in args else "O"})
elif cmd == "team users":
    pass
elif cmd == "channel list":
    team = next(t for t in st["teams"] if t["name"] == args[2])
    out([c for c in st["channels"] if c["team_id"] == team["id"]])
elif cmd == "channel create":
    team = next(t for t in st["teams"] if t["name"] == opt("--team"))
    st["channels"].append({"id": new_id(), "name": opt("--name"), "team_id": team["id"]})
elif cmd == "channel users":
    pass
elif cmd == "webhook list-incoming":
    out(st["hooks"])
elif cmd == "webhook create-incoming":
    channel, user = opt("--channel"), opt("--user")
    if not any(c["id"] == channel for c in st["channels"]) or not any(u["id"] == user for u in st["users"]):
        sys.exit("Error: unable to find channel or user (IDs required)")
    hook = {"id": new_id(), "channel_id": channel, "user_id": user, "display_name": opt("--display-name")}
    st["hooks"].append(hook)
    out(hook)
else:
    sys.exit(f"fake mmctl: unexpected {args}")
json.dump(st, open(state_file, "w"))
EOF
chmod +x "$bin/mmctl"
# A real Unix socket where local mode puts it.
sock=$tmp/mattermost_local.socket
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"

target=$tmp/etc/mattermost-target; dropins=$tmp/systemd/mattermost.service.d
guest() {
  env PATH="$bin:$PATH" MMCTL="$bin/mmctl" MM_TARGET_ETC="$target" MM_DROPIN_DIR="$dropins" \
    MM_SOCKET="$sock" HEALTH_TIMEOUT=2 "$@" bash "$script" 2>&1
}
mm_state() { python3 -c 'import json,sys; print(eval(sys.argv[1], {"s": json.load(open(sys.argv[2]))}))' "$1" "$state/mm.json"; }
reset() { rm -rf -- "${tmp:?}/etc" "${tmp:?}/systemd" "$state/mm.json" "$state/running"; : > "$log"; }

reset
out=$(guest) || fail "fresh setup: $out"
grep -qx 'Environment=MM_SERVICESETTINGS_ENABLELOCALMODE=true' "$dropins/10-local-mode.conf" || fail 'local mode drop-in'
grep -q 'systemctl daemon-reload' "$log" && grep -q 'systemctl restart mattermost.service' "$log" || fail 'not restarted for local mode'
grep -q 'mmctl --local --suppress-warnings user create --email mmadmin@mattermost.local --username mmadmin .*--system-admin' "$log" ||
  fail 'administrator'
[[ $(mm_state '[t["name"] for t in s["teams"]]') == "['ollama']" ]] || fail 'team'
[[ $(mm_state '[c["name"] for c in s["channels"]]') == "['ollama-monitor']" ]] || fail 'channel'
for setting in EnableIncomingWebhooks EnablePostUsernameOverride EnablePostIconOverride; do
  [[ $(mm_state "s['config']['ServiceSettings.$setting']") == true ]] || fail "$setting not enabled"
done
hook=$(mm_state 's["hooks"][0]["id"]')
[[ $(< "$target/webhook-url") == "http://192.0.2.76:8065/hooks/$hook" ]] || fail "webhook URL: $(< "$target/webhook-url")"
[[ $(mm_state 's["hooks"][0]["channel_id"] == s["channels"][0]["id"]') == True ]] || fail 'the webhook is not for the alert channel'
for f in url admin-user admin-password webhook-url; do
  [[ $(stat -c %a "$target/$f") == 600 ]] || fail "$f is not 0600"
done
[[ $(< "$target/admin-password") =~ [A-Z] && $(< "$target/admin-password") =~ [0-9] ]] || fail 'weak admin password'
pass 'fresh setup: local mode, administrator, team, channel, webhook settings and a 0600 webhook URL'

: > "$log"
url=$(< "$target/webhook-url")
out=$(guest) || fail "rerun: $out"
grep -q 'create\|systemctl restart' "$log" && fail "a rerun recreated something or restarted: $(grep 'create\|restart' "$log")"
[[ $(< "$target/webhook-url") == "$url" && $out == *'still exists; kept'* ]] || fail 'a rerun replaced the webhook'
pass 'a rerun keeps the accounts, team, channel and webhook, and does not restart Mattermost'

python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["hooks"]=[]; json.dump(s, open(p,"w"))' "$state/mm.json"
out=$(guest) || fail "webhook repair: $out"
[[ $(< "$target/webhook-url") != "$url" && $(mm_state 'len(s["hooks"])') == 1 ]] || fail 'a deleted webhook was not recreated'
pass 'a webhook deleted in Mattermost is recreated'

reset
out=$(guest FAKE_SITE_URL= MATTERMOST_TEAM=ops MATTERMOST_CHANNEL=alerts) || fail "custom names: $out"
[[ $(mm_state 's["config"]["ServiceSettings.SiteURL"]') == http://192.0.2.76:8065 ]] || fail 'an empty SiteURL was not set'
[[ $(< "$target/webhook-url") == http://192.0.2.76:8065/hooks/* ]] || fail 'webhook URL without SiteURL'
[[ $(mm_state '[c["name"] for c in s["channels"]]') == "['alerts']" ]] || fail 'MATTERMOST_CHANNEL was not used'
pass 'an empty SiteURL is set to the CT address; team and channel names are honoured'

reset
if out=$(guest FAKE_NO_START=1); then fail 'a Mattermost that never answered was accepted'; fi
[[ $out == *'did not come up'* && $out == *'journalctl -u mattermost'* ]] || fail "not-ready message: $out"
pass 'a Mattermost or local socket that does not come up is reported'

reset
if out=$(guest MMCTL="$tmp/none"); then fail 'a CT without mmctl was accepted'; fi
[[ $out == *'No mmctl at'* ]] || fail "missing mmctl message: $out"
pass 'a CT without the community-script Mattermost is refused'

printf '%s Mattermost target install cases passed. Nothing was installed.\n' "$passed"
