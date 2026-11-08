#!/usr/bin/env bash
# Add the hcom tool target to an existing OSR agent container.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$here/../targets/hcom/provision-lxc.sh" "$@"
