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
echo 'PASS Mattermost handoffs: JSON object/array/NDJSON parsing, separate channel and dry run without secrets'
