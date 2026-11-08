#!/usr/bin/env bash
# Kept for existing instructions and scripts: the Gitea service is now the
# targets/gitea target. This runs its provisioner with --create-only, which is
# what this script always did (the community script, then the browser setup
# steps). Run targets/gitea/provision-lxc.sh directly to have Gitea configured
# too; see targets/gitea/README.md.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
target=$here/../targets/gitea/provision-lxc.sh
[[ -r $target ]] || { printf 'Error: %s is missing; run this from the full repository checkout.\n' "$target" >&2; exit 1; }
for arg in "$@"; do
    case $arg in --create-only|--reconfigure) exec bash "$target" "$@" ;; esac
done
exec bash "$target" --create-only "$@"
