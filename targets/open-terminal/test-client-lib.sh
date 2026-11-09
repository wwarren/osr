#!/usr/bin/env bash
# client-lib.sh, the agent provisioners' Open Terminal helpers: URL checks,
# the terminal firewall rule per client, and connect/disconnect against a
# stubbed pct and a fixture firewall directory. Needs no root.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
# shellcheck source=targets/open-terminal/client-lib.sh
source "$here/client-lib.sh"

describe ot_valid_url
assert_ok 'empty means off' ot_valid_url ''
assert_ok 'http, IPv4 and port' ot_valid_url 'http://192.0.2.70:8000'
assert_ok 'a trailing slash' ot_valid_url 'http://192.0.2.70:8000/'
assert_fail 'no port' ot_valid_url 'http://192.0.2.70'
assert_fail 'a host name (the firewall needs an address)' ot_valid_url 'http://terminal:8000'
assert_fail 'a path' ot_valid_url 'http://192.0.2.70:8000/mcp'
assert_fail 'an octet above 255' ot_valid_url 'http://192.0.2.700:8000'
assert_eq 'ip' 192.0.2.70 "$(ot_url_ip 'http://192.0.2.70:8000/')"
assert_eq 'port' 8000 "$(ot_url_port 'http://192.0.2.70:8000/')"
assert_eq 'client name' hermes-282 "$(ot_client_name hermes 282)"

describe ot_fw_with_client
printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8000 -log nolog\n' > "$tmp/fw"
out=$(ot_fw_with_client "$tmp/fw" 192.0.2.82 8000 hermes-282)
assert_eq 'the client rule comes first in [RULES], the router rule stays' \
  "$(printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\n\n[RULES]\nIN ACCEPT -source 192.0.2.82/32 -p tcp -dport 8000 -log nolog # osr-open-terminal-client hermes-282\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8000 -log nolog')" "$out"
printf '%s\n' "$out" > "$tmp/fw2"
out=$(ot_fw_with_client "$tmp/fw2" 192.0.2.99 8001 hermes-282)
assert_eq 'a moved client has one rule, with the new address' 1 "$(grep -c 'hermes-282' <<< "$out")"
assert_contains 'new address' '-source 192.0.2.99/32 -p tcp -dport 8001' "$out"
out=$(ot_fw_with_client "$tmp/fw2" 192.0.2.83 8000 openclaw-283)
assert_contains 'another client keeps its rule' 'hermes-282' "$out"
assert_contains 'and gets its own' 'openclaw-283' "$out"
assert_eq 'a prefix of another name does not match' 1 "$(ot_fw_with_client "$tmp/fw2" 192.0.2.84 8000 hermes-28 | grep -c 'hermes-282$')"
printf '[OPTIONS]\nenable: 1\n' > "$tmp/fw3"
assert_contains 'a file without [RULES] gets one' $'[RULES]\nIN ACCEPT -source 192.0.2.82/32' "$(ot_fw_with_client "$tmp/fw3" 192.0.2.82 8000 hermes-282)"

describe ot_fw_without_client
out=$(ot_fw_without_client "$tmp/fw2" hermes-282)
assert_not_contains 'the client rule is gone' 'hermes-282' "$out"
assert_contains 'the router rule stays' '-source 192.0.2.80/32' "$out"

describe ot_connect
mkdir -p "$tmp/pve/firewall" "$tmp/bin" "$tmp/stage"
# shellcheck disable=SC2034  # read by the sourced helpers
PVE_ETC=$tmp/pve stage=$tmp/stage dry_run=0
cp "$tmp/fw" "$tmp/pve/firewall/270.fw"
log=$tmp/pct.log
cat > "$tmp/bin/pct" <<STUB
#!/usr/bin/env bash
echo "pct \$*" >> "$log"
shift 2; [[ \$1 == -- ]] && shift
case "\$*" in
  'test -x /usr/local/sbin/open-terminal-clients') [[ \${FAKE_NO_GATEWAY:-0} == 0 ]] ;;
  sed*) echo OPEN_TERMINAL_PORT=8000 | sed -n 's/^OPEN_TERMINAL_PORT=//p' ;;
  *' has '*) [[ \${FAKE_HAS:-0} == 1 ]] ;;
  *' issue '*) echo 'new-key-0123456789abcdefghij' ;;
  *' revoke '*) : ;;
esac
STUB
chmod +x "$tmp/bin/pct"
PATH=$tmp/bin:$PATH
: > "$log"
ot_connect 270 192.0.2.82 hermes-282 '' "$tmp/key" 2> "$tmp/err"
assert_eq 'a client without a key gets one' new-key-0123456789abcdefghij "$(cat "$tmp/key")"
assert_file_mode 'the key file is private' 600 "$tmp/key"
assert_file_contains 'issued with the default user' 'issue hermes-282 --default-user default' "$log"
assert_file_contains 'the terminal firewall admits the agent' '-source 192.0.2.82/32 -p tcp -dport 8000 -log nolog # osr-open-terminal-client hermes-282' "$tmp/pve/firewall/270.fw"
: > "$log"
FAKE_HAS=1 ot_connect 270 192.0.2.82 hermes-282 "$(printf a%.0s {1..64})" "$tmp/key" 2> "$tmp/err"
assert_eq 'a key the terminal accepts is kept (nothing new to push)' '' "$(cat "$tmp/key")"
assert_not_contains 'and not rotated' ' issue ' "$(cat "$log")"
assert_eq 'one rule for the client' 1 "$(grep -c 'hermes-282' "$tmp/pve/firewall/270.fw")"
assert_status 'a terminal without the gateway is refused' 1 env FAKE_NO_GATEWAY=1 bash -c \
  "$(declare -f die note ot_terminal_port ot_connect ot_fw_apply _ot_with ot_fw_with_client); OT_FW_TAG=$OT_FW_TAG dry_run=0 stage=$tmp/stage PVE_ETC=$tmp/pve; ot_connect 270 192.0.2.82 hermes-282 '' $tmp/key"
# shellcheck disable=SC2034
dry_run=1
assert_contains 'a dry run only describes it' 'admit 192.0.2.82' "$(ot_connect 270 192.0.2.82 hermes-282 '' "$tmp/key")"
# shellcheck disable=SC2034
dry_run=0

describe ot_disconnect
: > "$log"
ot_disconnect 270 hermes-282 2> "$tmp/err"
assert_file_contains 'the key is revoked' 'revoke hermes-282 --missing-ok' "$log"
assert_eq 'the rule is removed' 0 "$(grep -c 'hermes-282' "$tmp/pve/firewall/270.fw")"
assert_file_contains 'the router rule stays' '-source 192.0.2.80/32' "$tmp/pve/firewall/270.fw"
rm "$tmp/pve/firewall/270.fw"
ot_disconnect 270 hermes-282 2> "$tmp/err"
assert_contains 'a missing firewall file is reported, not created' 'does not exist' "$(cat "$tmp/err")"
assert_ok 'and stays missing' test ! -e "$tmp/pve/firewall/270.fw"

summary
