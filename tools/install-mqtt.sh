#!/usr/bin/env bash
# Provision the MQTT tool target from the Proxmox host.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$here/../targets/mqtt/provision-lxc.sh" "$@"
