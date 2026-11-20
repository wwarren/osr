#!/usr/bin/env bash
# A small model menu for targets whose model catalog is selected by the guest
# installer. ROWS are ID|description lines; the guest remains the authority on
# which choices its pinned checkout supports.
target_model_select() {
    local variable=$1 label=$2 default=$3 validator=$4 rows=$5
    local answer id description index=0 found
    [[ -z ${!variable:-} ]] || return 0
    if pve_asks; then
        pve_section "$label model"
        while IFS='|' read -r id description; do
            [[ -n $id ]] || continue
            index=$((index + 1))
            pve_note "  $index) $id${description:+ - $description}"
        done <<< "$rows"
        pve_note 'Enter a number or model ID. The guest checks availability against its pinned checkout.'
        _pve_heading
        while true; do
            printf '  %s model [Enter: %s]: ' "$label" "$default" >&2
            IFS= read -r answer || { printf '\n' >&2; return 1; }
            [[ -n $answer ]] || answer=$default
            if [[ $answer =~ ^[0-9]+$ ]]; then
                index=0 found=false
                while IFS='|' read -r id description; do
                    [[ -n $id ]] || continue
                    index=$((index + 1))
                    if [[ $answer == "$index" ]]; then answer=$id; found=true; break; fi
                done <<< "$rows"
                if [[ $found == false ]]; then
                    printf '    Choose a number from the list.\n' >&2
                    continue
                fi
            fi
            if "$validator" "$answer"; then break; fi
            printf '    Choose a listed number or a valid model ID.\n' >&2
        done
    else
        answer=$default
    fi
    printf -v "$variable" '%s' "$answer"
}
