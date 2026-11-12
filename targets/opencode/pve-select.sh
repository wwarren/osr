#!/usr/bin/env bash
# Proxmox template, storage, and required-input prompts. Keep the copy in each target
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

# Never infer an address or an existing CT. A caller can preset the value, or
# an interactive run asks for it before the Proxmox creation steps begin. (A
# new CT's ID has a default: pve_new_ct_id.)
pve_prompt_required() {
    local variable=$1 label=$2 answer
    [[ -z ${!variable:-} ]] || return 0
    [[ ${NONINTERACTIVE:-false} != true && -t 0 ]] ||
        die "Set $variable for unattended provisioning, or run interactively on the PVE host."
    while true; do
        IFS= read -r -p "$label: " answer || die "Input ended while reading $variable."
        if [[ -n $answer ]]; then
            printf -v "$variable" '%s' "$answer"
            return 0
        fi
        printf '%s is required.\n' "$label" >&2
    done
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

# --- Guided prompts -----------------------------------------------------------
# Every provisioner asks in the same order, one titled section at a time:
#   create:      Router (companions) -> <target> container -> <target> settings
#   reconfigure: <target> container to change -> Router -> <target> settings
# then pve_summary and pve_confirm. A value set in the environment is never
# asked again. On --reconfigure the caller passes the CT's recorded value as the
# default, so Enter keeps it. A new CT's ID defaults to the cluster's next free
# ID (pve_new_ct_id). An address is never filled in: pve_suggest offers one in
# brackets, but only a person can accept it.

# pve_interactive: prompts may be shown. PVE_INTERACTIVE=true|false overrides
# the terminal check (tests feed answers on stdin).
pve_interactive() {
    case ${PVE_INTERACTIVE:-} in
        true) return 0 ;;
        false) return 1 ;;
    esac
    [[ ${NONINTERACTIVE:-false} != true && -t 0 ]]
}

# pve_section TITLE: the heading of the next group of prompts. It is printed
# with the group's first prompt, so a section with nothing to ask stays silent.
_PVE_SECTION='' _PVE_NOTES=()
pve_section() { _PVE_SECTION=$1; _PVE_NOTES=(); }

# pve_note TEXT: one line of guidance under the section heading.
pve_note() { _PVE_NOTES+=("$1"); }

# _pve_heading: the pending heading and notes, once.
_pve_heading() {
    local line
    [[ -n $_PVE_SECTION ]] || return 0
    printf '\n== %s ==\n' "$_PVE_SECTION" >&2
    for line in "${_PVE_NOTES[@]}"; do printf '  %s\n' "$line" >&2; done
    _PVE_SECTION='' _PVE_NOTES=()
}

# pve_asks: settings with a default are asked. The OSR installer sets
# PVE_ACCEPT_DEFAULTS=true: it asked its own questions, so a run under it takes
# defaults and skips offers, and only a missing required value is asked.
pve_asks() { [[ ${PVE_ACCEPT_DEFAULTS:-false} != true ]] && pve_interactive; }

# _pve_read VAR LABEL SHOWN VALIDATOR HINT: ask until VALIDATOR accepts the
# answer (Enter takes SHOWN). Without a validator, anything but empty passes.
_pve_read() {
    local variable=$1 label=$2 shown=$3 validator=$4 hint=$5 answer
    _pve_heading
    while true; do
        printf '  %s%s: ' "$label" "${shown:+ [$shown]}" >&2
        IFS= read -r answer || { printf '\n' >&2; die "Input ended while reading $variable."; }
        answer=${answer:-$shown}
        # "none" clears an optional setting that has a suggestion.
        if [[ ${answer,,} == none && -n $validator ]] && "$validator" ''; then answer=''; break; fi
        if [[ -n $validator ]]; then
            "$validator" "$answer" && break
            printf '    %s\n' "${hint:-Not a valid $label: ${answer:-(empty)}.}" >&2
        else
            [[ -n $answer ]] && break
            printf '    %s is required.\n' "$label" >&2
        fi
    done
    printf -v "$variable" '%s' "$answer"
}

# pve_ask VAR LABEL [DEFAULT] [VALIDATOR] [HINT]: a setting with a default (the
# built-in one, or on --reconfigure the CT's recorded value). Kept when VAR is
# already set; asked with [DEFAULT] when interactive; DEFAULT when unattended.
# A VALIDATOR that accepts '' makes the setting optional.
pve_ask() {
    local variable=$1 label=$2 default=${3-} validator=${4:-} hint=${5:-}
    [[ -z ${!variable:-} ]] || return 0
    if pve_asks || { pve_interactive && [[ -z $default ]] && ! { [[ -n $validator ]] && "$validator" ''; }; }; then
        _pve_read "$variable" "$label" "$default" "$validator" "$hint"
        return 0
    fi
    if [[ -z $default ]] && ! { [[ -n $validator ]] && "$validator" ''; }; then
        die "Set $variable for unattended provisioning, or run interactively on the PVE host."
    fi
    printf -v "$variable" '%s' "$default"
}

# pve_suggest VAR LABEL SUGGESTION [VALIDATOR] [HINT]: a value that must be
# chosen (a CT ID, an address, a gateway). SUGGESTION is offered in brackets to
# a person; an unattended run needs VAR preset and never takes it.
pve_suggest() {
    local variable=$1 label=$2 suggestion=${3-} validator=${4:-} hint=${5:-}
    [[ -z ${!variable:-} ]] || return 0
    pve_interactive ||
        die "Set $variable for unattended provisioning, or run interactively on the PVE host."
    _pve_read "$variable" "$label" "$suggestion" "$validator" "$hint"
}

# pve_offer VAR LABEL SUGGESTION VALIDATOR [HINT]: an optional setting with a
# suggestion a person can take (Enter) or refuse ("none"). Unattended runs
# leave it empty unless VAR is preset. VALIDATOR must accept ''.
pve_offer() {
    local variable=$1 label=$2 suggestion=${3-} validator=$4 hint=${5:-}
    [[ -z ${!variable:-} ]] || return 0
    pve_asks || return 0
    _pve_read "$variable" "$label${suggestion:+ (none to skip)}" "$suggestion" "$validator" "$hint"
}

# pve_ask_yes_no VAR LABEL DEFAULT(true|false): a true/false setting.
pve_ask_yes_no() {
    local variable=$1 label=$2 default=$3 answer
    [[ -z ${!variable:-} ]] || return 0
    if ! pve_asks; then printf -v "$variable" '%s' "$default"; return 0; fi
    _pve_heading
    while true; do
        if [[ $default == true ]]; then printf '  %s [Y/n]: ' "$label" >&2; else printf '  %s [y/N]: ' "$label" >&2; fi
        IFS= read -r answer || { printf '\n' >&2; die "Input ended while reading $variable."; }
        case ${answer,,} in
            '') printf -v "$variable" '%s' "$default"; return 0 ;;
            y|yes) printf -v "$variable" true; return 0 ;;
            n|no) printf -v "$variable" false; return 0 ;;
        esac
        printf '    Answer y or n.\n' >&2
    done
}

# pve_summary TITLE: the heading of the plan; pve_row LABEL VALUE: one line of
# it. Printed for every run, so a log shows what was used.
pve_summary() { _PVE_SECTION=''; printf '\n== %s ==\n' "$1" >&2; }
pve_row() { printf '  %-26s %s\n' "$1" "${2:-(none)}" >&2; }

# pve_confirm QUESTION: an interactive run confirms the plan before anything
# changes. Unattended runs, dry runs and PVE_CONFIRM=false (the OSR installer,
# which already confirmed its plan) go ahead.
pve_confirm() {
    local answer
    [[ ${PVE_CONFIRM:-true} == true && ${dry_run:-0} == 0 ]] && pve_interactive || return 0
    printf '\n%s [Y/n]: ' "$1" >&2
    IFS= read -r answer || { printf '\n' >&2; die 'Input ended; nothing was changed.'; }
    [[ ${answer,,} =~ ^(|y|yes)$ ]] || die 'Stopped at your request; nothing was changed.'
}

# pve_tagged_ct TAG: the ID of the one CT on this node tagged TAG (the router
# is tagged osr-router, each target with its name), or nothing when there is
# none or more than one.
pve_tagged_ct() {
    local tag=$1 dir=${PVE_LXC_DIR:-/etc/pve/lxc} file found=''
    [[ -d $dir ]] || return 0
    for file in "$dir"/*.conf; do
        [[ -f $file ]] || continue
        # The first section only: later [snapshot] sections repeat old settings.
        if awk -v tag="$tag" '
            /^\[/ { exit }
            /^tags:/ { sub(/^tags:[[:space:]]*/, ""); n = split($0, t, /[;, ]+/)
                       for (i = 1; i <= n; i++) if (t[i] == tag) found = 1 }
            END { exit !found }' "$file"; then
            [[ -z $found ]] || return 0
            found=$(basename "$file" .conf)
        fi
    done
    [[ -z $found ]] || printf '%s\n' "$found"
}

# pve_ensure_tags ID TAG...: add each TAG the CT lacks to its tags, keeping the
# ones it has. tools/upgrade-all.sh finds the router by its osr-router tag and a
# target by osr-target plus the target's name, so a provisioner runs this on
# the CT it created or reconfigured: a community script's menus can change or
# drop the tags it was given, and a CT made by hand or by an older version may
# have none. A failure is reported, not fatal: the target works untagged.
pve_ensure_tags() {
    local id=$1 current tag
    local -a have=() missing=() merged=()
    shift
    if [[ ${dry_run:-0} != 0 ]]; then
        printf '+ tag CT %s %s (pct set --tags, keeping its other tags)\n' "$id" "$(IFS=';'; printf '%s' "$*")"
        return 0
    fi
    current=$(pct config "$id" 2>/dev/null | sed -n 's/^tags:[[:space:]]*//p' | head -n 1) || current=''
    read -r -a have <<< "${current//[;,]/ }"
    for tag in "$@"; do
        [[ " ${have[*]} " == *" $tag "* ]] || missing+=("$tag")
    done
    (( ${#missing[@]} )) || return 0
    merged=("${have[@]}" "${missing[@]}")
    if pct set "$id" --tags "$(IFS=';'; printf '%s' "${merged[*]}")" >/dev/null; then
        printf 'Tagged CT %s %s.\n' "$id" "$(IFS=';'; printf '%s' "${missing[*]}")" >&2
    else
        printf 'Warning: could not tag CT %s; tools/upgrade-all.sh does not find it until: pct set %s --tags %q\n' \
            "$id" "$id" "$(IFS=';'; printf '%s' "${merged[*]}")" >&2
    fi
    return 0
}

# pve_ct_with_ip IP: the ID of the CT on this node whose net0 has IP, or nothing.
pve_ct_with_ip() {
    local dir=${PVE_LXC_DIR:-/etc/pve/lxc} file
    [[ -n $1 && -d $dir ]] || return 0
    for file in "$dir"/*.conf; do
        [[ -f $file ]] || continue
        if awk -v ip="$1" '/^\[/ { exit } /^net0:/ && index($0, "ip=" ip "/") { found = 1 } END { exit !found }' "$file"; then
            basename "$file" .conf; return 0
        fi
    done
}

# pve_ct_described ID TEXT: is TEXT the first line of the CT's description?
# Proxmox keeps the description URL-encoded on one line ("%0A" for a newline);
# saving the Notes field in the GUI adds a trailing newline, and a person may
# add notes below. So the description is decoded, and only its first line,
# without trailing white space, has to match.
pve_ct_described() {
    local raw first
    raw=$(pct config "$1" 2>/dev/null | sed -n 's/^description: //p' | head -n 1) || return 1
    [[ -n $raw ]] || return 1
    first=$(perl -e '$_ = shift; s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; s/\n.*//s; s/\s+\z//; print' -- "$raw") || return 1
    [[ $first == "$2" ]]
}

# pve_ct_net ID ip|gw|cidr|bridge: one field of a CT's net0 on this node (ip
# without its prefix), or nothing.
pve_ct_net() {
    local file=${PVE_LXC_DIR:-/etc/pve/lxc}/$1.conf value
    [[ -r $file ]] || return 0
    value=$(awk '/^\[/ { exit } /^net0:/ { print; exit }' "$file")
    case $2 in
        ip) value=$(sed -nE 's/.*[ ,:]ip=([0-9.]+)\/[0-9]+.*/\1/p' <<< "$value") ;;
        cidr) value=$(sed -nE 's/.*[ ,:]ip=([0-9.]+\/[0-9]+).*/\1/p' <<< "$value") ;;
        gw) value=$(sed -nE 's/.*[ ,:]gw=([0-9.]+).*/\1/p' <<< "$value") ;;
        bridge) value=$(sed -nE 's/.*[ ,:]bridge=([^,]+).*/\1/p' <<< "$value") ;;
        *) return 1 ;;
    esac
    [[ -z $value ]] || printf '%s\n' "$value"
}

# Validators for the shared prompts.
pve_valid_ct_id() { [[ $1 =~ ^[1-9][0-9]{2,8}$ ]]; }
pve_valid_ipv4() {
    local octet
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do (( 10#$octet <= 255 )) || return 1; done
}
pve_valid_cidr() {
    local address prefix
    [[ $1 =~ ^([0-9.]+)/([0-9]{1,2})$ ]] || return 1
    address=${BASH_REMATCH[1]} prefix=${BASH_REMATCH[2]}
    pve_valid_ipv4 "$address" && (( 10#$prefix >= 1 && 10#$prefix <= 32 ))
}
pve_valid_cidr_or_dhcp() { [[ $1 == dhcp ]] || pve_valid_cidr "$1"; }
pve_valid_optional_ipv4() { [[ -z $1 ]] || pve_valid_ipv4 "$1"; }

# pve_ask_router [ip]: the Router section for a companion. ROUTER_CT_ID is
# offered from PVE_ROUTER_SUGGESTION, else the one CT tagged osr-router; with
# "ip", ROUTER_IP (the address this target reaches the router at) from that
# CT's net0.
pve_ask_router() {
    local suggestion
    pve_section 'Router'
    # A reconfigure offers the router the CT recorded (PVE_ROUTER_SUGGESTION).
    suggestion=${PVE_ROUTER_SUGGESTION:-$(pve_tagged_ct osr-router)}
    pve_suggest ROUTER_CT_ID 'Router CT ID' "$suggestion" pve_valid_ct_id 'Use the router CT ID (100 or more).'
    if [[ ${1:-} == ip ]]; then
        suggestion=$(pve_ct_net "$ROUTER_CT_ID" ip)
        pve_suggest ROUTER_IP 'Router IP' "$suggestion" pve_valid_ipv4 'Use the IPv4 address the router answers on.'
    fi
}

# pve_ask_existing_ct TAG NAME [VERB]: the CT a --reconfigure (VERB) changes,
# offered from the one CT tagged TAG.
pve_ask_existing_ct() {
    pve_section "$2 container to ${3:-reconfigure}"
    pve_suggest CT_ID "$2 CT ID" "$(pve_tagged_ct "$1")" pve_valid_ct_id 'Use the existing CT ID (100 or more).'
}

# pve_next_ct_id: the cluster's next free CT ID (pvesh get /cluster/nextid), or
# nothing on a dry run (which makes no Proxmox queries) or when it cannot be read.
pve_next_ct_id() {
    local id
    [[ ${dry_run:-0} == 0 ]] || return 0
    command -v pvesh >/dev/null 2>&1 || return 0
    id=$(pvesh get /cluster/nextid 2>/dev/null) || return 0
    id=${id//[^0-9]/}
    pve_valid_ct_id "$id" || return 0
    printf '%s\n' "$id"
}

# pve_new_ct_id VAR LABEL: a new CT's ID. A preset VAR wins. Otherwise the
# cluster's next free ID is the default: offered in brackets to a person, who
# can type another, and taken by an unattended run, which says so. Without it
# (a dry run, no pvesh) a person must type one and an unattended run stops.
pve_new_ct_id() {
    local variable=$1 label=$2 next
    [[ -z ${!variable:-} ]] || return 0
    next=$(pve_next_ct_id)
    if pve_interactive; then
        _pve_read "$variable" "$label" "$next" pve_valid_ct_id 'Use a free numeric ID of 100 or more.'
        return 0
    fi
    [[ -n $next ]] || die "Set $variable for unattended provisioning, or run interactively on the PVE host."
    printf -v "$variable" '%s' "$next"
    printf '  %s: %s (the next free CT ID; set %s to choose another)\n' "$label" "$next" "$variable" >&2
}

# pve_ask_new_ct NAME: the new CT's ID, first in the NAME container section.
pve_ask_new_ct() {
    pve_section "$1 container"
    pve_new_ct_id CT_ID "New $1 CT ID (unused)"
}

# pve_ask_network NAME [dhcp]: IP_CIDR, then GATEWAY (skipped for dhcp, which
# "dhcp" allows). The gateway is offered from the router CT, or else the one
# CT tagged osr-router: targets usually share its network.
pve_ask_network() {
    local validator=pve_valid_cidr hint='Use a.b.c.d/nn.' router suggestion
    if [[ ${2:-} == dhcp ]]; then validator=pve_valid_cidr_or_dhcp hint='Use a.b.c.d/nn or dhcp.'; fi
    pve_suggest IP_CIDR "$1 IP/CIDR${2:+ (or dhcp)}" '' "$validator" "$hint"
    [[ $IP_CIDR != dhcp ]] || return 0
    router=${ROUTER_CT_ID:-$(pve_tagged_ct osr-router)}
    suggestion=''
    [[ -z $router ]] || suggestion=$(pve_ct_net "$router" gw)
    pve_suggest GATEWAY "$1 gateway" "$suggestion" pve_valid_ipv4 'Use an IPv4 address.'
}
