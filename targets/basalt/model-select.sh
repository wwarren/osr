#!/usr/bin/env bash
# Official Qwen3.8-Flash-Next Basalt packs. Sizes are tenths of GiB from the
# model card; the third column is the routed expert set, not total RAM use.
# Keep rows in increasing quality order for the recommendation below.
basalt_model_rows() {
    cat <<'PACKS'
UD-IQ1_S|656|311
UD-IQ1_M|671|324
UD-IQ2_XS|744|394
UD-IQ3_XXS|816|468
UD-IQ4_XS|909|562
NVFP4-DQ6_K|1220|633
NVFP4-DQ8|1233|633
UD-Q4_K_XL|1067|717
UD-Q5_K_XL|1505|916
UD-Q6_K_XL|1606|1017
Q8_0|1783|1195
PACKS
}

basalt_model_file() { printf 'Qwen3.8-FN-%s.basalt\n' "$1"; }

basalt_model_choice() {
    local suffix file experts
    while IFS='|' read -r suffix file experts; do
        [[ $1 == "$suffix" || $1 == "$(basalt_model_file "$suffix")" ]] && return 0
    done < <(basalt_model_rows)
    return 1
}

basalt_model_menu() {
    local suffix file experts
    while IFS='|' read -r suffix file experts; do
        printf '  %-15s %5d.%d GiB file, %5d.%d GiB experts\n' \
            "$suffix" "$((file / 10))" "$((file % 10))" \
            "$((experts / 10))" "$((experts % 10))"
    done < <(basalt_model_rows)
}

basalt_gpu_vram_mib() {
    command -v nvidia-smi >/dev/null 2>&1 || return 0
    local index value total=0
    local -a indices
    IFS=, read -r -a indices <<< "$1"
    for index in "${indices[@]}"; do
        value=$(nvidia-smi -i "$index" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null) || return 0
        value=${value//[[:space:]]/}
        [[ $value =~ ^[0-9]+$ ]] || return 0
        total=$((total + value))
    done
    (( total > 0 )) && printf '%s\n' "$total"
    return 0
}

basalt_host_available_mib() {
    [[ -r /proc/meminfo ]] || return 0
    awk '/^MemAvailable:/ { printf "%d\n", $2 / 1024; exit }' /proc/meminfo
}

# Recommend the highest-quality pack that fits a conservative resident-expert
# budget: experts plus 16 GiB for the server, host buffers and context, and a
# disk budget of file size plus 30 GiB for the OS, CUDA, source and build.
# GPU tiers limit the suggestion for smaller cards; they are performance
# guidance, not a claim that larger packs cannot run. Empty means none fits.
basalt_model_recommendation() {
    local vram=${1:-} host_ram=${2:-} ct_ram=$3 disk_gb=$4
    local max_tier=11 tier=0 suffix file experts chosen=''
    if [[ ! $vram =~ ^[0-9]+$ ]]; then max_tier=4
    elif (( vram < 12000 )); then max_tier=2
    elif (( vram < 16000 )); then max_tier=3
    elif (( vram < 24000 )); then max_tier=4
    elif (( vram < 32000 )); then max_tier=5
    elif (( vram < 48000 )); then max_tier=8
    fi
    while IFS='|' read -r suffix file experts; do
        tier=$((tier + 1))
        (( tier <= max_tier )) || continue
        # Values are in tenths of GiB; compare in MiB to avoid rounding down.
        (( file * 1024 + 300 * 1024 <= disk_gb * 10240 )) || continue
        (( experts * 1024 + 160 * 1024 <= ct_ram * 10 )) || continue
        if [[ $host_ram =~ ^[0-9]+$ ]]; then
            (( experts * 1024 + 160 * 1024 <= host_ram * 10 )) || continue
        fi
        chosen=$suffix
    done < <(basalt_model_rows)
    [[ -z $chosen ]] || printf '%s\n' "$chosen"
}
