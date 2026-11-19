#!/usr/bin/env bash
# The two text models that run from RAM in Colibri's catalog at the tested pin
# 0a5504a1dc64f86fcd0fe7db298b0448c730e7e6 (c/setup_catalog.py: id, repo,
# disk_gb, ram_min_gb). Each is pinned to a Hugging Face commit (the catalog
# follows main), so a download is always the same files; colibri's downloader
# then checks every file against that commit's SHA-256 listing. Move a pin only
# after checking the new commit with this target.
# The COLIBRI_MODEL_* values are read by the scripts that source this file.
# shellcheck disable=SC2034
colibri_model_details() {
    case $1 in
        qwen36-35b)
            COLIBRI_MODEL_NAME=Qwen3.6-35B-A3B
            COLIBRI_MODEL_REPO=Kreuzzelg/qwen36-35b-a3b-colibri-i4-gs64
            COLIBRI_MODEL_REVISION=c619aa594ad1e70af82168fb6b4878427896e21c
            COLIBRI_MODEL_GB=23.1
            COLIBRI_MODEL_MIN_MIB=10240 ;;
        qwen3-coder-30b)
            COLIBRI_MODEL_NAME=Qwen3-Coder-30B-A3B
            COLIBRI_MODEL_REPO=Justvugg/Qwen3-Coder-30B-A3B-colibri-int4
            COLIBRI_MODEL_REVISION=d839110a17d31b4e6fa9f3d973b751f779b6b9c6
            COLIBRI_MODEL_GB=19.4
            COLIBRI_MODEL_MIN_MIB=8192 ;;
        *) return 1 ;;
    esac
}

# Use Colibri's small-model RAM guidance. A CPU target gets the larger general
# model at its measured 20 GiB comfort point; a GPU can use it at its 10 GiB
# minimum. Below those thresholds, the coding model is the lighter choice.
colibri_model_recommend() {
    local memory_mib=$1 backend=$2
    if (( memory_mib >= 20480 )) ||
       { [[ $backend != cpu ]] && (( memory_mib >= 10240 )); }; then
        printf 'qwen36-35b\n'
    else
        printf 'qwen3-coder-30b\n'
    fi
}

# Called by either host installer once the target RAM and GPU are known. A
# preset ID is an explicit opt-in; unattended runs with no ID download nothing.
# none is an answer already given (the OSR installer passes it on when the
# download was declined), so nothing is suggested or asked again.
colibri_choose_model() {
    local memory_mib=$1 backend=$2 model_dir=$3 interactive=$4 recommended answer
    if [[ ${COLIBRI_MODEL_ID:-} == none ]]; then
        COLIBRI_MODEL_ID=''
        export COLIBRI_MODEL_ID
        return 0
    fi
    if [[ -z ${COLIBRI_MODEL_ID:-} ]]; then
        recommended=$(colibri_model_recommend "$memory_mib" "$backend")
        colibri_model_details "$recommended"
        printf 'Colibri suggestion for %s MiB RAM, %s: %s (%s GB from %s).\n' \
            "$memory_mib" "$backend" "$COLIBRI_MODEL_NAME" "$COLIBRI_MODEL_GB" "$COLIBRI_MODEL_REPO" >&2
        [[ $interactive == true ]] ||
            printf 'Nothing is downloaded unattended; set COLIBRI_MODEL_ID=%s to download it.\n' "$recommended" >&2
    fi
    if [[ -z ${COLIBRI_MODEL_ID:-} && $interactive == true ]]; then
        while true; do
            printf 'Download %s to %s in the target CT? [y/N]: ' "$COLIBRI_MODEL_NAME" "$model_dir" >&2
            IFS= read -r answer || { printf '\n' >&2; return 1; }
            case ${answer,,} in
                y|yes) COLIBRI_MODEL_ID=$recommended; break ;;
                ''|n|no) COLIBRI_MODEL_ID=''; break ;;
                *) printf 'Answer y or n.\n' >&2 ;;
            esac
        done
    fi
    if [[ -n ${COLIBRI_MODEL_ID:-} ]]; then
        colibri_model_details "$COLIBRI_MODEL_ID" || {
            printf 'COLIBRI_MODEL_ID must be qwen36-35b or qwen3-coder-30b.\n' >&2; return 1;
        }
        if (( memory_mib < COLIBRI_MODEL_MIN_MIB )); then
            printf '%s needs at least %s MiB target RAM.\n' "$COLIBRI_MODEL_ID" "$COLIBRI_MODEL_MIN_MIB" >&2
            return 1
        fi
    fi
    export COLIBRI_MODEL_ID
}
