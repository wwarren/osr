#!/usr/bin/env bash
# PolyStrata's model families, as setup.py lists them at the tested commit
# (POLYSTRATA_DEFAULT_COMMIT). provision-lxc.sh sources this file for its menus
# and its KV cache question; install-target.sh sources it in the CT for the
# default model of a family and the KV cache formats the family's engine has.
# test-pinned-upstream.py checks every row against upstream's setup.py
# (FAMILIES, family_models, POLY_KV, STRATA_KV), so a pin move that adds,
# drops or renames a family or a size fails there first.
#
# Fields: family|engine|default model|title|sizes (RAM GB each, setup's own
# estimate)
#   engine  strata  the Strata project's engine (Qwen3.8-Flash-Next and its
#                   fine-tunes); KV cache int8 (default), k8v4 or q4_0
#           poly    the engine written for PolyStrata ("strata-poly", marked
#                   experimental upstream); KV cache fp16 (default) and the
#                   formats in polystrata_poly_kv
# The default size is the one Enter takes: for the strata families the one
# the Strata target defaults to, for the others the first upstream lists
# (setup's own order of preference, poly_default).
polystrata_catalog() {
    cat <<'CATALOG'
qwen|strata|IQ2_XS|Qwen3.8-Flash-Next|Q2_0:48 IQ2_XS:48 IQ3_XXS:60 IQ3_S:62
swift|strata|IQ2_XS|Swift 1.5 (Qwen3.8-Flash-Next fine-tune, shorter thinking)|IQ2_XS:48 IQ3_XXS:60 IQ3_S:62
coder|strata|IQ1_M|Qwen3.8-Flash-Next Coder (half the experts)|IQ1_M:32
unsloth|strata|UD-IQ4_XS|Qwen3.8-Flash-Next (Unsloth quantizations)|UD-IQ4_XS:48 UD-Q4_K_XL:48 UD-Q5_K_XL:108 UD-Q6_K_XL:118 Q8_0:136 UD-IQ1_M:48 UD-Q2_0:48 UD-IQ2_XS:48 UD-Q2_K_XL:48 UD-IQ3_XXS:48 UD-Q3_K_XL:48 UD-IQ4_XS-v31:48
gyro|strata|Gyro-S|Qwen3.8-Flash-Next (Gyro, smallest sizes)|Gyro-S:28 Gyro-M:35
nvfp4|strata|NVFP4|Qwen3.8-Flash-Next (NVFP4 experts)|NVFP4:80 NVFP4-NVIDIA:80 NVFP4-QAD:80
glm|poly|3.0BIT|GLM 5.3 Flash (32 GB card)|3.0BIT:96 UD-IQ2_XXS:82 REAP50-Q3_K_M:60
deepseek|poly|UD-IQ2_XXS|DeepSeek V4 Flash (32 GB card)|UD-IQ2_XXS:72
lfm25|poly|UD-Q4_K_XL|LFM2.5-24B-A2B|UD-Q4_K_XL:20 UD-Q3_K_XL:16 QAD-Q4_0:18 UD-Q6_K_XL:27 Q8_0:31
inkling|poly|UD-Q4_K_XL|Inkling 2 Mini (text only)|UD-Q4_K_XL:21 UD-Q3_K_XL:17 UD-Q2_K_XL:13
flint|poly|UD-Q4_K_XL|Flint 40B-A2.5B|UD-Q4_K_XL:29 UD-Q3_K_XL:22 UD-Q6_K_XL:40 Q8_0:46
kolibri|poly|Q4_K_M|Kolibri 1 (German and English)|Q4_K_M:52 Q2_K:33 Q3_K_M:42
groot|poly|Q4_K_M|Groot 19B-A3B|Q4_K_M:17 Q6_K:21 Q8_0:24
qwen36|poly|UD-Q3_K_M|Qwen3.6-35B-A3B|UD-Q3_K_M:21 UD-Q2_K_XL:17 UD-Q4_K_M:27
clover|poly|Q3_K_M|Clover-35B-A3B-Preview|Q3_K_M:20 APEX-I-NANOPLUS:16 Q4_K_M:25
ornith|poly|APEX-I-COMPACT|Ornith 1.5 35B-A3B|APEX-I-COMPACT:22 APEX-I-MINI:18 APEX-I-QUALITY:28
gemma4|poly|UD-Q3_K_M|Gemma 4 26B-A4B|UD-Q3_K_M:18 UD-Q2_K_XL:15 UD-Q4_K_M:21 QAT-UD-Q4_K_XL:19
tiel|poly|UD-Q3_K_XL|Tiel Coder 35B-A3B|UD-Q3_K_XL:21 UD-IQ3_XXS:18 UD-Q4_K_XL:27
minicpmv|poly|Q4_K_M|MiniCPM-V 4.7 35B-A3B|Q4_K_M:25 mix_q3gud_im:19 Q6_K:31
ornith122|poly|UD-Q3_K_XL|Ornith 1.5 122B|UD-Q3_K_XL:47 UD-Q2_K_XL:32 UD-IQ3_XXS:37 UD-Q4_K_XL:66 Q8_0:119
CATALOG
}

# polystrata_poly_kv: the KV cache formats beside fp16 that strata-poly has
# for a family's attention (upstream's POLY_KV), as format|families.
polystrata_poly_kv() {
    cat <<'POLYKV'
q8_0|qwen36 ornith ornith122 tiel minicpmv kolibri flint lfm25
int8|gemma4
int8k|gemma4
POLYKV
}

# polystrata_family_field FAMILY N: field N (1-based) of FAMILY's row; fails
# for a family the catalog does not list.
polystrata_family_field() {
    local family=$1 n=$2 row
    row=$(polystrata_catalog | awk -F'|' -v f="$family" '$1 == f { print; exit }')
    [[ -n $row ]] || return 1
    cut -d'|' -f"$n" <<< "$row"
}
polystrata_family_engine() { polystrata_family_field "$1" 2; }
polystrata_family_default() { polystrata_family_field "$1" 3; }
polystrata_family_title() { polystrata_family_field "$1" 4; }

# polystrata_family_models FAMILY: the family's sizes, one per line.
polystrata_family_models() {
    local sizes size
    sizes=$(polystrata_family_field "$1" 5) || return 1
    for size in $sizes; do printf '%s\n' "${size%%:*}"; done
}

# polystrata_model_ram_gb FAMILY MODEL: setup's RAM estimate for MODEL (GB),
# or nothing when the catalog does not know it.
polystrata_model_ram_gb() {
    local sizes size
    sizes=$(polystrata_family_field "$1" 5) || return 0
    for size in $sizes; do
        [[ ${size%%:*} == "$2" ]] && { printf '%s\n' "${size#*:}"; return 0; }
    done
    return 0
}

# polystrata_kv_choices FAMILY: the POLYSTRATA_KV values this family accepts,
# space separated. auto (pass no --kv: the engine's default) always works; a
# family the catalog does not list (one a newer pin adds, or hy4-flash, whose
# setup ignores --kv) gets only auto.
polystrata_kv_choices() {
    local engine format families
    engine=$(polystrata_family_engine "$1") || { printf 'auto\n'; return 0; }
    case $engine in
        strata) printf 'auto int8 k8v4 q4_0\n' ;;
        poly)
            printf 'auto fp16'
            while IFS='|' read -r format families; do
                [[ " $families " == *" $1 "* ]] && printf ' %s' "$format"
            done < <(polystrata_poly_kv)
            printf '\n' ;;
        *) printf 'auto\n' ;;
    esac
}

# polystrata_menu_families: family|description rows for target_model_select.
polystrata_menu_families() {
    local family engine title note
    while IFS="|" read -r family engine _ title _; do
        note=''
        [[ $engine == poly ]] && note=', experimental engine'
        printf '%s|%s%s\n' "$family" "$title" "$note"
    done < <(polystrata_catalog)
}

# polystrata_menu_models FAMILY: model|description rows for target_model_select.
polystrata_menu_models() {
    local sizes size
    sizes=$(polystrata_family_field "$1" 5) || return 1
    for size in $sizes; do printf '%s|about %s GB of RAM\n' "${size%%:*}" "${size#*:}"; done
}
