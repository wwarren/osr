#!/usr/bin/env bash
# Colibri's model catalog and the menu that picks one, shared by the OSR
# installer, provision-lxc.sh (create and --reconfigure), tools/upgrade-all.sh
# and install-target.sh (in the CT).
#
# Every text model of colibri's own catalog at the tested pin
# 0a5504a1dc64f86fcd0fe7db298b0448c730e7e6 (c/setup_catalog.py: id, repo,
# disk_gb, ram_min_gb, ram_good_gb, exclude, post_install), smallest first.
# Each is pinned to a Hugging Face commit (the catalog follows main except for
# Qwen3.8-Flash-Next, whose pin is upstream's), so a download is always the
# same files; colibri's downloader checks every file against that commit's
# SHA-256 listing. test-pinned-upstream.py keeps this table equal to the
# catalog. Move a pin only after checking the new commit with this target.
#
# One model is served at a time (coli serve runs one per process); picking
# another replaces it.

COLIBRI_MODEL_IDS=(qwen3-coder-30b qwen36-35b deepseek-v4-flash-reap deepseek-v4-flash
                   mimo-v2.6-flash qwen38-flash-next glm-5.3 glm-5.2 inkling mimo-v2.6-pro kimi-k3)

# colibri_model_details ID: set COLIBRI_MODEL_NAME, _REPO, _REVISION, _GB (the
# download, GB of 10^9 bytes), _MIN_MIB and _GOOD_MIB (the catalog's RAM in GB,
# counted as GiB), _EXCLUDE (repository paths the engine never reads,
# space-separated globs) and _POST (tool:file, a step after the download).
# The COLIBRI_MODEL_* values are read by the scripts that source this file.
# shellcheck disable=SC2034
colibri_model_details() {
    COLIBRI_MODEL_EXCLUDE='' COLIBRI_MODEL_POST=''
    case $1 in
        qwen3-coder-30b)
            COLIBRI_MODEL_NAME=Qwen3-Coder-30B-A3B
            COLIBRI_MODEL_REPO=Justvugg/Qwen3-Coder-30B-A3B-colibri-int4
            COLIBRI_MODEL_REVISION=d839110a17d31b4e6fa9f3d973b751f779b6b9c6
            COLIBRI_MODEL_GB=19.4 COLIBRI_MODEL_MIN_MIB=8192 COLIBRI_MODEL_GOOD_MIB=18432 ;;
        qwen36-35b)
            COLIBRI_MODEL_NAME=Qwen3.6-35B-A3B
            COLIBRI_MODEL_REPO=Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64
            COLIBRI_MODEL_REVISION=c619aa594ad1e70af82168fb6b4878427896e21c
            COLIBRI_MODEL_GB=23.1 COLIBRI_MODEL_MIN_MIB=10240 COLIBRI_MODEL_GOOD_MIB=20480 ;;
        deepseek-v4-flash-reap)
            COLIBRI_MODEL_NAME='DeepSeek V4 Flash REAP 150B'
            COLIBRI_MODEL_REPO=puwaer/DeepSeek-V4-Flash-0731-reap-150b
            COLIBRI_MODEL_REVISION=7c76db22034eb30ea6b22018da29b514fb5bb983
            COLIBRI_MODEL_GB=84.7 COLIBRI_MODEL_MIN_MIB=16384 COLIBRI_MODEL_GOOD_MIB=32768 ;;
        deepseek-v4-flash)
            COLIBRI_MODEL_NAME='DeepSeek V4 Flash'
            COLIBRI_MODEL_REPO=deepseek-ai/DeepSeek-V4-Flash-0731
            COLIBRI_MODEL_REVISION=7872f01b1d1fe23eabc4c98b48bffcef5a386062
            COLIBRI_MODEL_GB=166.9 COLIBRI_MODEL_MIN_MIB=16384 COLIBRI_MODEL_GOOD_MIB=32768 ;;
        mimo-v2.6-flash)
            COLIBRI_MODEL_NAME='MiMo-V2.6 Flash'
            COLIBRI_MODEL_REPO=XiaomiMiMo/MiMo-V2.6-Flash-MOPD
            COLIBRI_MODEL_REVISION=5220c3f513065a0426be5e094571cbed0983386e
            COLIBRI_MODEL_GB=171.8 COLIBRI_MODEL_MIN_MIB=32768 COLIBRI_MODEL_GOOD_MIB=53248
            COLIBRI_MODEL_EXCLUDE='dflash/* audio_tokenizer/* model_mtp.safetensors' ;;
        qwen38-flash-next)
            COLIBRI_MODEL_NAME=Qwen3.8-Flash-Next
            COLIBRI_MODEL_REPO=Qwen/Qwen3.8-Flash-Next-FP8
            COLIBRI_MODEL_REVISION=bcd9f01ddc9cff2316eb84281bebcd5b058bddce
            COLIBRI_MODEL_GB=185.6 COLIBRI_MODEL_MIN_MIB=24576 COLIBRI_MODEL_GOOD_MIB=32768 ;;
        glm-5.3)
            COLIBRI_MODEL_NAME=GLM-5.3
            COLIBRI_MODEL_REPO=Justvugg/GLM-5.3-colibri-int4-g64
            COLIBRI_MODEL_REVISION=3930f4bb756e6586e6103d57b42c9b0a7bbf6f4c
            COLIBRI_MODEL_GB=419.3 COLIBRI_MODEL_MIN_MIB=16384 COLIBRI_MODEL_GOOD_MIB=24576 ;;
        glm-5.2)
            COLIBRI_MODEL_NAME=GLM-5.2
            COLIBRI_MODEL_REPO=mastouri/GLM-5.2-colibri-int4-g64-with-int8-mtp
            COLIBRI_MODEL_REVISION=6bbb01ed3e515a8730b694dfae73aadfd6774581
            COLIBRI_MODEL_GB=429.3 COLIBRI_MODEL_MIN_MIB=16384 COLIBRI_MODEL_GOOD_MIB=24576 ;;
        inkling)
            COLIBRI_MODEL_NAME=Inkling
            COLIBRI_MODEL_REPO=nbeerbower/Inkling-colibri-int4
            COLIBRI_MODEL_REVISION=3981e658ed68ec681554d48a62f9a29dd9e61543
            COLIBRI_MODEL_GB=514.1 COLIBRI_MODEL_MIN_MIB=122880 COLIBRI_MODEL_GOOD_MIB=131072 ;;
        mimo-v2.6-pro)
            COLIBRI_MODEL_NAME='MiMo-V2.6 Pro'
            COLIBRI_MODEL_REPO=XiaomiMiMo/MiMo-V2.6-Pro-MOPD
            COLIBRI_MODEL_REVISION=da71ee15e76a8849bd1a9610195c452007a79678
            COLIBRI_MODEL_GB=563.6 COLIBRI_MODEL_MIN_MIB=55296 COLIBRI_MODEL_GOOD_MIB=65536
            COLIBRI_MODEL_EXCLUDE='dflash/* audio_tokenizer/* model_mtp.safetensors' ;;
        kimi-k3)
            COLIBRI_MODEL_NAME='Kimi K3'
            COLIBRI_MODEL_REPO=moonshotai/Kimi-K3
            COLIBRI_MODEL_REVISION=f831ab66814297da540d832a5235f8e904f29d06
            COLIBRI_MODEL_GB=1561.0 COLIBRI_MODEL_MIN_MIB=32768 COLIBRI_MODEL_GOOD_MIB=65536
            COLIBRI_MODEL_POST=k3_tokenizer:tokenizer.json ;;
        *) return 1 ;;
    esac
}

# colibri_model_bytes ID: the download in bytes (its GB, one decimal, x 10^9).
colibri_model_bytes() {
    colibri_model_details "$1" || return 1
    printf '%s\n' "$(( ${COLIBRI_MODEL_GB/./} * 100000000 ))"
}

# colibri_model_from_manifest REPO REVISION: the catalog ID of a downloaded
# model (from its .colibri-download.json), or nothing.
colibri_model_from_manifest() {
    local id
    for id in "${COLIBRI_MODEL_IDS[@]}"; do
        colibri_model_details "$id"
        if [[ $COLIBRI_MODEL_REPO == "$1" && $COLIBRI_MODEL_REVISION == "$2" ]]; then
            printf '%s\n' "$id"; return 0
        fi
    done
    return 1
}

# Use Colibri's small-model RAM guidance. A CPU target gets the larger general
# model at its measured 20 GiB comfort point; a GPU can use it at its 10 GiB
# minimum. Below those thresholds, the coding model is the lighter choice. The
# large models stream their experts from disk and are picked by name.
colibri_model_recommend() {
    local memory_mib=$1 backend=$2
    if (( memory_mib >= 20480 )) ||
       { [[ $backend != cpu ]] && (( memory_mib >= 10240 )); }; then
        printf 'qwen36-35b\n'
    else
        printf 'qwen3-coder-30b\n'
    fi
}

# colibri_model_fit ID MEMORY_MIB [DISK_BYTES]: why the model does not fit, or
# nothing (and success) when it does. DISK_BYTES is the room for the model's
# files, empty when it is not known.
colibri_model_fit() {
    local need
    colibri_model_details "$1" || { printf 'unknown model\n'; return 1; }
    if (( $2 < COLIBRI_MODEL_MIN_MIB )); then
        printf 'needs %s GiB RAM\n' "$(( COLIBRI_MODEL_MIN_MIB / 1024 ))"; return 1
    fi
    if [[ ${3:-} =~ ^[0-9]+$ ]]; then
        need=$(colibri_model_bytes "$1")
        if (( need > $3 )); then printf 'needs %s GB disk\n' "$COLIBRI_MODEL_GB"; return 1; fi
    fi
    return 0
}

# colibri_model_label ID: "Name (GB GB)".
colibri_model_label() {
    case $1 in
        none) printf 'nothing\n'; return 0 ;;
        hand) printf 'a model placed by hand\n'; return 0 ;;
        other) printf 'a downloaded model not in this catalog\n'; return 0 ;;
    esac
    colibri_model_details "$1" || { printf '%s\n' "$1"; return 0; }
    printf '%s (%s GB)\n' "$COLIBRI_MODEL_NAME" "$COLIBRI_MODEL_GB"
}

# colibri_model_menu MEMORY_MIB BACKEND DISK_BYTES CURRENT RECOMMENDED: the
# catalog as a numbered list on stderr, each with whether it fits.
colibri_model_menu() {
    local memory_mib=$1 backend=$2 disk=$3 current=$4 recommended=$5 i=0 id why mark
    printf '  Colibri models for this CT (%s MiB RAM, %s%s); one is served at a time:\n' "$memory_mib" "$backend" \
        "$( [[ $disk =~ ^[0-9]+$ ]] && printf ', %s GB of disk for the model' "$(( disk / 1000000000 ))")" >&2
    if [[ -n $current ]]; then
        printf '    0) keep the current model: %s\n' "$(colibri_model_label "$current")" >&2
        [[ $current == none ]] || printf '    r) remove it (the service parks until a model is placed)\n' >&2
    else
        printf '    0) none: download nothing (the service parks until a model is placed)\n' >&2
    fi
    for id in "${COLIBRI_MODEL_IDS[@]}"; do
        i=$((i + 1))
        colibri_model_details "$id"
        why=$(colibri_model_fit "$id" "$memory_mib" "$disk") && why='fits'
        mark=''
        [[ $id != "$recommended" ]] || mark=' (suggested)'
        [[ $id != "$current" ]] || mark=' (current)'
        printf '   %2d) %-23s %-28s %7s GB  RAM %3s-%3s GiB  %s%s\n' "$i" "$id" "$COLIBRI_MODEL_NAME" "$COLIBRI_MODEL_GB" \
            "$(( COLIBRI_MODEL_MIN_MIB / 1024 ))" "$(( COLIBRI_MODEL_GOOD_MIB / 1024 ))" "$why" "$mark" >&2
    done
}

# colibri_choose_model MEMORY_MIB BACKEND MODEL_DIR INTERACTIVE [DISK_BYTES] [CURRENT]
# Sets and exports COLIBRI_MODEL_ID:
#   ''      nothing to download (or, with CURRENT, nothing to change)
#   <ID>    download that catalog model (with CURRENT: replace the served one)
#   remove  with CURRENT only: take the served model away
# CURRENT is given when a model may already be served (reconfigure, upgrade,
# install-target.sh --model): none, a catalog ID, hand or other. A preset
# COLIBRI_MODEL_ID answers without a question: none, keep, remove or an ID.
# Unattended runs with no preset download nothing. none is also the OSR
# installer's answer already given, so nothing is suggested or asked again.
colibri_choose_model() {
    local memory_mib=$1 backend=$2 model_dir=$3 interactive=$4 disk=${5:-} current=${6:-}
    local recommended answer id why
    recommended=$(colibri_model_recommend "$memory_mib" "$backend")
    case ${COLIBRI_MODEL_ID:-} in
        none|keep)
            COLIBRI_MODEL_ID=''; export COLIBRI_MODEL_ID; return 0 ;;
        remove)
            if [[ -z $current ]]; then
                printf 'COLIBRI_MODEL_ID=remove only applies to an installed CT (reconfigure, upgrade, install-target.sh --model).\n' >&2
                return 1
            fi
            [[ $current != none ]] || COLIBRI_MODEL_ID=''
            export COLIBRI_MODEL_ID; return 0 ;;
        '')
            if [[ $interactive == true ]]; then
                colibri_model_menu "$memory_mib" "$backend" "$disk" "$current" "$recommended"
                while true; do
                    printf '  Model for %s (number or ID; Enter: %s): ' "$model_dir" "$( [[ -n $current ]] && echo keep || echo none)" >&2
                    IFS= read -r answer || { printf '\n' >&2; return 1; }
                    answer=${answer,,}
                    case $answer in
                        ''|0|none|keep) COLIBRI_MODEL_ID=''; break ;;
                        r|remove)
                            if [[ -n $current && $current != none ]]; then COLIBRI_MODEL_ID=remove; break; fi
                            printf '  There is no model to remove.\n' >&2; continue ;;
                    esac
                    id=''
                    if [[ $answer =~ ^[0-9]+$ ]] && (( 10#$answer >= 1 && 10#$answer <= ${#COLIBRI_MODEL_IDS[@]} )); then
                        id=${COLIBRI_MODEL_IDS[10#$answer - 1]}
                    elif colibri_model_details "$answer"; then
                        id=$answer
                    fi
                    if [[ -z $id ]]; then printf '  Answer a number from the list, an ID, or Enter.\n' >&2; continue; fi
                    if ! why=$(colibri_model_fit "$id" "$memory_mib" "$disk"); then
                        printf '  %s does not fit this CT: %s. Pick another, or Enter.\n' "$id" "$why" >&2; continue
                    fi
                    COLIBRI_MODEL_ID=$id; break
                done
            elif [[ -z $current ]]; then
                colibri_model_details "$recommended"
                printf 'Colibri suggestion for %s MiB RAM, %s: %s (%s GB from %s). Nothing is downloaded unattended; set COLIBRI_MODEL_ID=%s (or another ID of model-select.sh) to download one.\n' \
                    "$memory_mib" "$backend" "$COLIBRI_MODEL_NAME" "$COLIBRI_MODEL_GB" "$COLIBRI_MODEL_REPO" "$recommended" >&2
            fi ;;
    esac
    if [[ -n ${COLIBRI_MODEL_ID:-} && $COLIBRI_MODEL_ID != remove ]]; then
        colibri_model_details "$COLIBRI_MODEL_ID" || {
            printf 'COLIBRI_MODEL_ID must be one of: %s (or none%s).\n' "${COLIBRI_MODEL_IDS[*]}" \
                "$( [[ -z $current ]] || printf ', keep, remove')" >&2
            return 1
        }
        if ! why=$(colibri_model_fit "$COLIBRI_MODEL_ID" "$memory_mib" "$disk"); then
            printf '%s does not fit this CT: %s (it has %s MiB RAM%s).\n' "$COLIBRI_MODEL_ID" "$why" "$memory_mib" \
                "$( [[ $disk =~ ^[0-9]+$ ]] && printf ' and room for %s GB' "$(( disk / 1000000000 ))")" >&2
            return 1
        fi
        # Picking the model that is already served changes nothing.
        [[ $COLIBRI_MODEL_ID != "$current" ]] || COLIBRI_MODEL_ID=''
    fi
    export COLIBRI_MODEL_ID
}

# colibri_ct_facts CT_ID (on the Proxmox host): what the menu needs from an
# existing Colibri CT. Sets COLIBRI_CT_MEMORY_MIB, COLIBRI_CT_BACKEND (cuda,
# vulkan or cpu, from its device lines), COLIBRI_CT_MODEL_DIR, COLIBRI_CT_DISK
# (free bytes on the model's filesystem, less 1 GiB) and COLIBRI_CT_CURRENT
# (none, a catalog ID, hand or other).
# shellcheck disable=SC2034  # the COLIBRI_CT_* values are the result
colibri_ct_facts() {
    local id=$1 config dir free staged manifest repo revision
    config=$(pct config "$id") || return 1
    COLIBRI_CT_MEMORY_MIB=$(sed -n 's/^memory:[[:space:]]*\([0-9][0-9]*\)$/\1/p' <<< "$config" | head -n1)
    [[ $COLIBRI_CT_MEMORY_MIB =~ ^[0-9]+$ ]] || return 1
    COLIBRI_CT_BACKEND=cpu
    if grep -qE '^dev[0-9]+:.*path=/dev/nvidia[0-9]' <<< "$config"; then COLIBRI_CT_BACKEND=cuda
    elif grep -qE '^dev[0-9]+:.*path=/dev/dri/renderD' <<< "$config"; then COLIBRI_CT_BACKEND=vulkan
    fi
    dir=$(pct exec "$id" -- sed -n 's/^COLIBRI_MODEL_DIR=//p' /etc/colibri-target/installed-env 2>/dev/null </dev/null | tail -n1)
    [[ $dir == /* && $dir != *..* ]] || dir=/var/lib/colibri/model
    COLIBRI_CT_MODEL_DIR=$dir
    free=$(pct exec "$id" -- df -PB1 "$dir" 2>/dev/null </dev/null | awk 'NR == 2 { print $4 }')
    staged=$(pct exec "$id" -- find "$dir/.colibri-staging" -mindepth 1 -maxdepth 1 ! -name 'retired-*' -exec du -sb -- {} + 2>/dev/null </dev/null | awk '{ sum += $1 } END { print sum + 0 }')
    COLIBRI_CT_DISK=''
    if [[ $free =~ ^[0-9]+$ ]]; then
        free=$(( free + staged ))
        COLIBRI_CT_DISK=$(( free > 1073741824 ? free - 1073741824 : 0 ))
    fi
    manifest=$(pct exec "$id" -- cat "$dir/.colibri-download.json" 2>/dev/null </dev/null) || manifest=''
    COLIBRI_CT_CURRENT=none
    if [[ -n $manifest ]]; then
        repo=$(sed -n 's/.*"repo":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$manifest" | head -n1)
        revision=$(sed -n 's/.*"revision":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$manifest" | head -n1)
        COLIBRI_CT_CURRENT=$(colibri_model_from_manifest "$repo" "$revision") || COLIBRI_CT_CURRENT=other
    elif pct exec "$id" -- find "$dir" -mindepth 1 -maxdepth 1 ! -name '.colibri-*' -print -quit 2>/dev/null </dev/null | grep -q .; then
        COLIBRI_CT_CURRENT=hand
    fi
}
