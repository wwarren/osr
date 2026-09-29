#!/usr/bin/env bash
# Convenience entry point from a checkout of this repo. The real tool lives in
# install/manage-model-servers.sh (the copy the installer seeds and symlinks to
# /usr/local/bin/manage-model-servers); this file used to be a second, full
# copy of it, and the two drifted apart.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
target="${here}/install/manage-model-servers.sh"
if [[ ! -f "$target" ]]; then
  echo "ERROR: ${target} not found. Run the tool from a full checkout of the repo," >&2
  echo "       or copy install/manage-model-servers.sh itself." >&2
  exit 1
fi
exec bash "$target" "$@"
