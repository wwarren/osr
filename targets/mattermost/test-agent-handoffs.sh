#!/usr/bin/env bash
# Verify the new mmctl JSON parser and channel separation without a server.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$here/../../tests/lib/extract-functions.py" "$here/configure-agent-handoffs.sh" --only find_field)"
[[ $(printf '%s' '[{"id":"one","name":"agent-handoffs"},{"id":"two","name":"health"}]' |
  find_field name agent-handoffs id) == one ]] || exit 1
[[ $(printf '%s\n' '{"id":"one","channel_id":"target"}' '{"id":"two","channel_id":"other"}' |
  find_field id two channel_id) == other ]] || exit 1
if printf '%s' '[]' | find_field name absent id; then echo 'FAIL: absent object accepted'; exit 1; fi
if printf '%s' 'bad JSON' | find_field name absent id 2>/dev/null; then echo 'FAIL: invalid JSON accepted'; exit 1; fi
output=$(bash "$here/configure-agent-handoffs.sh" --dry-run)
[[ $output == *agent-handoffs-webhook-url* && $output != *'/hooks/'* ]] || exit 1
if HCOM_MATTERMOST_CHANNEL=ollama-monitor bash "$here/configure-agent-handoffs.sh" --dry-run 2>/dev/null; then exit 1; fi
if MATTERMOST_CHANNEL=health HCOM_MATTERMOST_CHANNEL=health bash "$here/configure-agent-handoffs.sh" --dry-run 2>/dev/null; then exit 1; fi
if HCOM_MATTERMOST_CHANNEL='unsafe channel' bash "$here/configure-agent-handoffs.sh" --dry-run 2>/dev/null; then exit 1; fi
# Whole runs against a fake mmctl that, like the real one, prints help text for
# a webhook subcommand it does not have. They need root (EUID check, runuser);
# unshare -r runs them as an ordinary user.
if (( EUID != 0 )); then
  echo 'SKIP handoff end-to-end cases (need root; try unshare -r)'
  echo 'PASS Mattermost handoffs: JSON object/array/NDJSON parsing, separate channel and dry run without secrets'
  exit 0
fi
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
etc=$tmp/etc; bin=$tmp/bin; mkdir -p "$etc" "$bin"
printf 'admin\n' > "$etc/admin-user"; printf 'http://192.0.2.77:8065\n' > "$etc/url"
printf '#!/bin/sh\nwhile [ "$1" != -- ]; do shift; done; shift; exec "$@"\n' > "$bin/runuser"
cat > "$bin/mmctl" <<'PY'
#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_MM"]
st = json.load(open(path))
args = [a for a in sys.argv[1:] if a not in ("--local", "--suppress-warnings", "--json")]
cmd = " ".join(args[:2])
def opt(name): return args[args.index(name) + 1]
def new_id(): return "%026d" % (len(st["hooks"]) + len(st["channels"]) + 1)
if cmd == "user list": print(json.dumps(st["users"]))
elif cmd == "channel list": print(json.dumps(st["channels"]))
elif cmd == "channel create": st["channels"].append({"id": "c" + new_id()[1:], "name": opt("--name")})
elif cmd == "channel users": pass
elif cmd == "webhook show":
    hook = next((h for h in st["hooks"] if h["id"] == args[2]), None)
    if hook is None: sys.exit(f"Error: Webhook with id '{args[2]}' not found")
    print(json.dumps(hook))
elif cmd == "webhook create-incoming":
    hook = {"id": "h" + new_id()[1:], "channel_id": opt("--channel"), "channel_locked": "--lock-to-channel" in args}
    st["hooks"].append(hook); print(json.dumps(hook))
elif cmd == "webhook modify-incoming":
    next(h for h in st["hooks"] if h["id"] == args[2])["channel_locked"] = "--lock-to-channel" in args
elif args[:1] == ["webhook"]:
    print("Management of webhooks\n\nUsage:\n  mmctl webhook [command]"); sys.exit(0)
else: sys.exit(f"fake mmctl: unexpected {args}")
json.dump(st, open(path, "w"))
PY
chmod +x "$bin/mmctl" "$bin/runuser"
health=h0000000000000000000000001
printf '{"users":[{"id":"u0000000000000000000000001","username":"admin"}],
 "channels":[{"id":"c0000000000000000000000001","name":"ollama-monitor"}],
 "hooks":[{"id":"%s","channel_id":"c0000000000000000000000001","channel_locked":false}]}' "$health" > "$tmp/mm.json"
printf 'http://192.0.2.77:8065/hooks/%s\n' "$health" > "$etc/webhook-url"
run() { env PATH="$bin:$PATH" FAKE_MM="$tmp/mm.json" MM_TARGET_ETC="$etc" MMCTL="$bin/mmctl" bash "$here/configure-agent-handoffs.sh" 2>&1; }
state() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$tmp/mm.json" "$1"; }
out=$(run) || { echo "FAIL: fresh handoff setup: $out"; exit 1; }
saved=$(<"$etc/agent-handoffs-webhook-url"); hook=${saved##*/}
[[ $(state "[h for h in s['hooks'] if h['id']=='$hook'][0]['channel_locked']") == True && $out != *"$hook"* ]] ||
  { echo 'FAIL: a new handoff webhook must be locked to its channel and its URL never printed'; exit 1; }
[[ $(state "[h for h in s['hooks'] if h['id']=='$hook'][0]['channel_id'] != 'c0000000000000000000000001'") == True ]] ||
  { echo 'FAIL: handoffs went to the health channel'; exit 1; }
out=$(run) || { echo "FAIL: rerun: $out"; exit 1; }
[[ $(<"$etc/agent-handoffs-webhook-url") == "$saved" && $(state 'len(s["hooks"])') == 2 ]] || { echo 'FAIL: a rerun replaced the handoff webhook'; exit 1; }
# A webhook from an earlier release, unlocked, is locked in place.
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["hooks"][1]["channel_locked"]=False; json.dump(s,open(p,"w"))' "$tmp/mm.json"
run >/dev/null || { echo 'FAIL: rerun with an unlocked webhook'; exit 1; }
[[ $(<"$etc/agent-handoffs-webhook-url") == "$saved" && $(state 's["hooks"][1]["channel_locked"]') == True ]] ||
  { echo 'FAIL: an unlocked handoff webhook was not locked in place'; exit 1; }
# A health webhook deleted in Mattermost no longer blocks the setup.
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["hooks"]=s["hooks"][1:]; json.dump(s,open(p,"w"))' "$tmp/mm.json"
out=$(run) || { echo "FAIL: setup with a deleted health webhook: $out"; exit 1; }
[[ $out == *'no longer exists'* ]] || { echo 'FAIL: deleted health webhook not reported'; exit 1; }
# A health webhook (custom channel name) bound to the handoff channel is refused.
python3 -c 'import json,sys; p=sys.argv[1]; s=json.load(open(p)); s["hooks"].append({"id":sys.argv[2],"channel_id":s["hooks"][0]["channel_id"],"channel_locked":False}); json.dump(s,open(p,"w"))' "$tmp/mm.json" "$health"
if run >/dev/null; then echo 'FAIL: handoffs accepted in the health channel'; exit 1; fi
echo 'PASS Mattermost handoffs: JSON parsing, separate channel, dry run without secrets, whole runs (locked webhook, kept on rerun, old webhook locked, deleted health webhook)'
