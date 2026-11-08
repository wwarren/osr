#!/usr/bin/env bash
# tools/install-mattermost.sh is a forwarder to targets/mattermost/provision-lxc.sh (whose
# own tests are targets/mattermost/test-*.sh). It keeps its old behaviour: create the
# CT and print the browser steps (--create-only), unless told otherwise.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tool=$here/../tools/install-mattermost.sh
target=$here/../targets/mattermost/provision-lxc.sh
common=(CT_ID=275 IP_CIDR=192.0.2.75/24 GATEWAY=192.0.2.1 STORAGE=local-lvm)
fail() { printf 'FAIL %s\n%s\n' "$1" "${out:-}" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
strip() { sed -E 's#/tmp/community-mattermost\.[A-Za-z0-9]+#<script>#g'; }

bash -n "$tool"
out=$(env -i "PATH=$PATH" "${common[@]}" bash "$tool" --dry-run 2>&1 | strip) || fail 'dry run'
want=$(env -i "PATH=$PATH" "${common[@]}" bash "$target" --dry-run --create-only 2>&1 | strip)
[[ $out == "$want" ]] || fail 'the forwarder is not the target in --create-only mode'
[[ $out != *'install-target.sh'* ]] || fail 'the forwarder configured the CT by default'
pass 'by default it runs the target provisioner with --create-only (the old behaviour)'

out=$(env -i "PATH=$PATH" "${common[@]}" bash "$tool" --dry-run --reconfigure 2>&1) || fail 'reconfigure'
[[ $out == *'install-target.sh'* && $out != *'+ env var_'* ]] || fail '--reconfigure was not passed through'
if out=$(env -i "PATH=$PATH" "${common[@]}" CT_ID=12 bash "$tool" --dry-run 2>&1); then fail 'a bad CT_ID was accepted'; fi
pass 'flags and settings are passed through, and validation is the target'"'"'s'

printf '%s forwarder cases passed. No CT was created.\n' "$passed"
