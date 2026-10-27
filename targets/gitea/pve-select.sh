#!/usr/bin/env bash
# Read-only Proxmox template and storage menus. Keep the copy in each target
# directory identical so a target can still be copied to a PVE host alone.

pve_select_parse_status() {
    awk '
      NR == 1 {
        header = $0; gsub(/\([^)]*\)/, "", header)
        count = split(header, columns, /[[:space:]]+/)
        position = 0
        for (i = 1; i <= count; i++) {
          if (columns[i] == "") continue
          position++
          column = tolower(columns[i])
          if (column == "name") name = position
          if (column == "type") type = position
          if (column == "status") status = position
          if (column == "available" || column == "avail") available = position
        }
        next
      }
      name && type && status && available && NF >= available && $(status) == "active" {
        printf "%s\t%s\t%s\n", $(name), $(type), $(available)
      }'
}

# Emits name, type, free KiB for active storages supporting the content type.
# Some PVE versions return no rows for a filtered status query; cross-check
# the unfiltered table against storage.cfg in that case.
pve_select_storage_rows() {
    local content=$1 filtered rows all allowed config=${STORAGE_CFG:-/etc/pve/storage.cfg}
    filtered=$(pvesm status -content "$content" 2>/dev/null) || filtered=''
    rows=$(printf '%s\n' "$filtered" | pve_select_parse_status)
    if [[ -n $rows ]]; then printf '%s\n' "$rows"; return 0; fi
    [[ -r $config ]] || return 1
    all=$(pvesm status 2>/dev/null) || return 1
    allowed=$(awk -v want="$content" '
      /^[a-z]+:[[:space:]]*[^[:space:]]+/ {
        split($0, fields, ":"); name = fields[2]; gsub(/[[:space:]]/, "", name); next
      }
      /^[[:space:]]*content[[:space:]]/ {
        line = $0; sub(/^[[:space:]]*content[[:space:]]+/, "", line)
        count = split(line, types, ",")
        for (i = 1; i <= count; i++) {
          gsub(/[[:space:]]/, "", types[i])
          if (types[i] == want && name != "") { print name; break }
        }
      }' "$config")
    [[ -n $allowed ]] || return 0
    printf '%s\n' "$all" | pve_select_parse_status |
      awk -F '\t' -v list="$allowed" '
        BEGIN { count = split(list, names, "\n"); for (i = 1; i <= count; i++) ok[names[i]] = 1 }
        $1 in ok'
}

pve_select_available() {
    [[ ${dry_run:-0} == 0 && ${NONINTERACTIVE:-false} != true && -t 0 ]]
}

pve_select_template() {
    local variable=$1 pattern=$2 ref storage type available choice i
    local -a choices=()
    [[ -z ${!variable:-} ]] && pve_select_available || return 0
    command -v pvesm >/dev/null && command -v pveam >/dev/null || die 'pvesm and pveam are required for the template selector.'
    while IFS=$'\t' read -r storage type available; do
        [[ -n $storage ]] || continue
        while IFS= read -r ref; do
            [[ $ref =~ $pattern ]] && choices+=("$ref")
        done < <(pveam list "$storage" 2>/dev/null | awk 'NR > 1 {print $1}')
    done < <(pve_select_storage_rows vztmpl)
    (( ${#choices[@]} )) || die 'No compatible downloaded LXC template was found on active vztmpl storage. Inspect pveam available and download one with pveam download <storage> <template-name>.'
    mapfile -t choices < <(printf '%s\n' "${choices[@]}" | awk -F/ '{print $NF "\t" $0}' | sort -V -r | cut -f2-)
    printf '\nDownloaded LXC templates:\n' >&2
    for i in "${!choices[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${choices[i]}" >&2; done
    while true; do
        printf 'Select template [1]: ' >&2
        IFS= read -r choice || die 'No template was selected.'
        choice=${choice:-1}
        if [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#choices[@]} )); then
            printf -v "$variable" '%s' "${choices[choice - 1]}"
            printf 'Using template: %s\n' "${!variable}" >&2
            return 0
        fi
        printf 'Enter a number from 1 to %s.\n' "${#choices[@]}" >&2
    done
}

pve_select_storage() {
    local variable=$1 content=$2 need_gib=$3 name type available gib choice i best=0 best_free=-1
    local -a names=() types=() frees=()
    [[ -z ${!variable:-} ]] && pve_select_available || return 0
    command -v pvesm >/dev/null || die 'pvesm is required for the storage selector.'
    while IFS=$'\t' read -r name type available; do
        [[ -n $name && $available =~ ^[0-9]+$ ]] || continue
        gib=$((available / 1048576))
        names+=("$name"); types+=("$type"); frees+=("$gib")
        if (( gib >= need_gib && gib > best_free )); then best=${#names[@]}; best_free=$gib; fi
    done < <(pve_select_storage_rows "$content")
    (( ${#names[@]} )) || die "No active storage supporting ${content} was found (check pvesm status -content ${content})."
    (( best )) || die "No active ${content} storage has ${need_gib} GiB free. Free space or reduce ROOTFS_GB."
    if [[ $content == vztmpl ]]; then
        printf '\nStorage for the LXC template:\n' >&2
    else
        printf '\nStorage for the CT root disk (need %s GiB):\n' "$need_gib" >&2
    fi
    for i in "${!names[@]}"; do
        printf '  %d) %s (%s, %s GiB free)' "$((i + 1))" "${names[i]}" "${types[i]}" "${frees[i]}" >&2
        if (( frees[i] < need_gib )); then printf ' [too small]' >&2; fi
        printf '\n' >&2
    done
    while true; do
        printf 'Select storage [%s]: ' "$best" >&2
        IFS= read -r choice || die 'No storage was selected.'
        choice=${choice:-$best}
        if [[ $choice =~ ^[1-9][0-9]{0,5}$ ]] && (( choice <= ${#names[@]} )); then
            if (( frees[choice - 1] >= need_gib )); then
                printf -v "$variable" '%s' "${names[choice - 1]}"
                printf 'Using storage: %s (%s GiB free)\n' "${!variable}" "${frees[choice - 1]}" >&2
                return 0
            fi
            printf '%s has only %s GiB free; %s GiB is required.\n' "${names[choice - 1]}" "${frees[choice - 1]}" "$need_gib" >&2
        else
            printf 'Enter a number from 1 to %s.\n' "${#names[@]}" >&2
        fi
    done
}
