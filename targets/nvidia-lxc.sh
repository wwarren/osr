#!/usr/bin/env bash
# Shared host/guest NVIDIA version checks for CUDA LXC target provisioners.
# Callers supply die(), run(), and dry_run.
# shellcheck disable=SC2154  # dry_run is the caller's

nvidia_lxc_version_valid() {
    [[ $1 =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
}

nvidia_lxc_require_series() {
    local version=$1 minimum=$2 workload=$3
    nvidia_lxc_version_valid "$version" || die "Invalid NVIDIA driver version: $version"
    (( 10#${version%%.*} >= minimum )) ||
        die "$workload needs NVIDIA driver $minimum or newer; host driver is $version."
}

nvidia_lxc_kernel_version() {
    sed -nE 's/.*Kernel Module( for x86_64)?[[:space:]]+([0-9]+\.[0-9]+(\.[0-9]+)?).*/\2/p' | head -n1
}

nvidia_lxc_host_version() {
    local version
    if [[ -n ${NVIDIA_HOST_VERSION_FILE:-} ]]; then
        [[ -r $NVIDIA_HOST_VERSION_FILE ]] || return 1
        version=$(nvidia_lxc_kernel_version < "$NVIDIA_HOST_VERSION_FILE") || return 1
    else
        version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]') || return 1
    fi
    nvidia_lxc_version_valid "$version" || return 1
    printf '%s\n' "$version"
}

nvidia_lxc_guest_ready_script() {
    printf '%s' 'expected=$1; nvml=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d "[:space:]"); '
    printf '%s' '[ "$nvml" = "$expected" ] || exit 1; '
    printf '%s' 'cuda=$(ldconfig -p | awk '\''$1 == "libcuda.so.1" && $2 ~ /x86-64/ { print $NF; exit }'\''); '
    printf '%s\n' '[ -n "$cuda" ] && [ -r "$cuda" ] && [ "$(basename "$(readlink -f "$cuda")")" = "libcuda.so.$expected" ]'
}

nvidia_lxc_guest_ready() {
    local ct=$1 version=$2
    pct exec "$ct" -- sh -c "$(nvidia_lxc_guest_ready_script)" sh "$version"
}

# The distribution NVIDIA packages a .run guest install replaces. Purging
# nvidia-alternative also removes the Debian driver libraries that depend on it.
nvidia_lxc_guest_cleanup_packages() {
    printf '%s\n' 'nvidia-smi libnvidia-ml1 libcuda1 nvidia-alternative glx-alternative-nvidia nvidia-legacy-check nvidia-installer-cleanup'
}

nvidia_lxc_guest_cleanup_script() {
    printf '%s' "set --; for package in $(nvidia_lxc_guest_cleanup_packages); do "
    printf '%s' 'if dpkg -s "$package" 2>/dev/null | grep -q "^Status: install ok installed$"; '
    printf '%s' 'then set -- "$@" "$package"; fi; done; '
    printf '%s\n' 'if [ "$#" -gt 0 ]; then DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"; fi'
}

# Install the loaded host release into an already-created CT. The helper has
# already been pushed into the CT by the caller. Remove distro packages only
# after checking the CT sees the same host kernel module.
nvidia_lxc_install_guest() {
    local ct=$1 version=$2 installer=$3 guest_version
    nvidia_lxc_version_valid "$version" || { (( dry_run )) || die "Invalid host NVIDIA driver version: $version"; }
    if (( dry_run )); then
        printf '+ confirm CT %s sees host NVIDIA driver %s\n' "$ct" "$version"
    else
        guest_version=$(pct exec "$ct" -- cat /proc/driver/nvidia/version | nvidia_lxc_kernel_version) ||
            die "CT $ct cannot read the host NVIDIA driver version; leaving its driver packages untouched."
        [[ $guest_version == "$version" ]] ||
            die "CT $ct sees NVIDIA driver '${guest_version:-unknown}', expected $version; leaving its driver packages untouched."
    fi
    run pct exec "$ct" -- sh -c "$(nvidia_lxc_guest_cleanup_script)"
    run pct exec "$ct" -- env "DRIVER_VERSION=$version" bash "$installer" lxc
    if (( dry_run )); then
        printf '+ verify CT %s has NVIDIA NVML and CUDA userspace %s\n' "$ct" "$version"
    else
        nvidia_lxc_guest_ready "$ct" "$version" ||
            die "CT $ct still lacks NVIDIA NVML and CUDA userspace $version after installation. Check nvidia-smi, libcuda.so.1, and /var/log/nvidia-installer.log inside it."
    fi
}
