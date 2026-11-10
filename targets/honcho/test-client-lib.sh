#!/usr/bin/env bash
# client-lib.sh, the agent provisioners' Honcho client helpers, against a
# stubbed pct. Needs no root.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
# shellcheck source=targets/honcho/client-lib.sh
source "$here/client-lib.sh"

describe hc_client_name
assert_eq 'client name' hermes-282 "$(hc_client_name hermes 282)"
assert_eq 'the API URL names the Honcho address' 192.0.2.85 "$(hc_url_ip http://192.0.2.85:8000)"
assert_eq 'so does the MCP URL' 192.0.2.85 "$(hc_url_ip http://192.0.2.85:3000/mcp)"
assert_eq 'a host name gives nothing' '' "$(hc_url_ip http://honcho:8000)"

describe hc_connect
mkdir -p "$tmp/bin"
log=$tmp/pct.log
cat > "$tmp/bin/pct" <<STUB
#!/usr/bin/env bash
echo "pct \$*" >> "$log"
shift 2; [[ \$1 == -- ]] && shift
case "\$*" in
  'test -x /usr/local/sbin/honcho-clients') [[ \${FAKE_NO_GATEWAY:-0} == 0 ]] ;;
  '/usr/local/sbin/honcho-clients has '*) [[ \$4 == "\${FAKE_ACCEPTED:-none}" && \$5 == --workspace && \$6 == "\$3" ]] ;;
  '/usr/local/sbin/honcho-clients issue '*) [[ \${FAKE_ISSUE_FAILS:-0} == 0 ]] || exit 1; printf '%s\n' "\${FAKE_KEY:-issued-key-0123456789abcdef}" ;;
  '/usr/local/sbin/honcho-clients revoke '*) [[ \${FAKE_REVOKE_FAILS:-0} == 0 ]] ;;
  sh\ -c*) printf 'abc123\r\n' ;;
  *) echo "unexpected pct \$*" >&2; exit 9 ;;
esac
STUB
chmod +x "$tmp/bin/pct"
PATH=$tmp/bin:$PATH
# shellcheck disable=SC2034  # read by the sourced helpers
dry_run=0
out=$tmp/key
hc_connect 285 hermes-282 '' "$out" 2>"$tmp/err"
assert_eq 'without a key the agent gets a new one' issued-key-0123456789abcdef "$(<"$out")"
assert_contains 'pinned to a workspace of its own' 'honcho-clients issue hermes-282 --workspace hermes-282' "$(<"$log")"
assert_contains 'and says so' 'Issued a new Honcho key for client hermes-282' "$(<"$tmp/err")"
: > "$log"
FAKE_ACCEPTED=$(printf 'k%.0s' {1..64}) hc_connect 285 hermes-282 "$(printf 'k%.0s' {1..64})" "$out" 2>"$tmp/err"
assert_eq 'a key Honcho still accepts is kept' '' "$(<"$out")"
assert_not_contains 'nothing is issued' 'issue' "$(<"$log")"
assert_contains 'the key is checked for its own workspace' 'has hermes-282 kkkk' "$(<"$log")"
assert_contains 'and that workspace' '--workspace hermes-282' "$(<"$log")"
: > "$log"
hc_connect 285 hermes-282 "$(printf 'k%.0s' {1..64})" "$out" 2>/dev/null
assert_contains 'a key Honcho does not accept is replaced' 'issue hermes-282' "$(<"$log")"
rc=0; (FAKE_NO_GATEWAY=1 hc_connect 285 hermes-282 '' "$out") 2>"$tmp/err" || rc=$?
assert_ne 'a Honcho CT without the gateway is refused' 0 "$rc"
assert_contains 'with what to do' 'Run targets/honcho/provision-lxc.sh --reconfigure' "$(<"$tmp/err")"
rc=0; (FAKE_KEY=short hc_connect 285 hermes-282 '' "$out") 2>/dev/null || rc=$?
assert_ne 'an unusable key is refused' 0 "$rc"
rc=0; (FAKE_ISSUE_FAILS=1 hc_connect 285 hermes-282 '' "$out") 2>/dev/null || rc=$?
assert_ne 'a failed issue is refused' 0 "$rc"
assert_eq 'the key hash is read inside the agent CT' abc123 "$(hc_key_sha256 282 /root/deploy/honcho-api-key)"
dry_run=1
assert_contains 'a dry run only says what it would do' 'honcho-clients issue hermes-282 --workspace hermes-282' "$(hc_connect 285 hermes-282 '' "$out")"

describe hc_disconnect
dry_run=0
: > "$log"
hc_disconnect 285 hermes-282
assert_contains 'the key is revoked' 'honcho-clients revoke hermes-282 --missing-ok' "$(<"$log")"
FAKE_REVOKE_FAILS=1 hc_disconnect 285 hermes-282 2>"$tmp/err"
assert_contains 'a failed revoke is reported, not fatal' 'run honcho-clients revoke hermes-282 there' "$(<"$tmp/err")"
dry_run=1
assert_contains 'a dry run only says what it would do' 'honcho-clients revoke hermes-282' "$(hc_disconnect 285 hermes-282)"

summary
