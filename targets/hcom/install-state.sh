#!/usr/bin/env bash
# File snapshots for the bus installers. Callers hold their install lock.
# These functions also work on temporary trees in the non-root test suite.
snapshot_save() {
  local directory=$1 path index=0
  shift
  mkdir -p "$directory"
  : > "$directory/paths"
  for path in "$@"; do
    printf '%s\0' "$path" >> "$directory/paths"
    if [[ -e $path || -L $path ]]; then cp -a -- "$path" "$directory/$index" || return 1; fi
    index=$((index + 1))
  done
}
snapshot_restore() {
  local directory=$1 path index=0 failed=0
  while IFS= read -r -d '' path; do
    if ! rm -rf -- "$path"; then failed=1
    elif [[ -e $directory/$index || -L $directory/$index ]]; then
      mkdir -p "$(dirname -- "$path")" && cp -a -- "$directory/$index" "$path" || failed=1
    fi
    index=$((index + 1))
  done < "$directory/paths"
  return "$failed"
}

# A healthy installation can be left alone only when every managed file still
# matches its saved digest; inputs alone would miss removed or edited units.
files_match() {
  [[ -s $1 ]] && sha256sum --check --status "$1"
}
