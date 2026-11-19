#!/usr/bin/env bash
# Runs inside the dedicated Colibri LXC after matching NVIDIA userspace is ready.
#
#   bash install-target.sh             install or update Colibri and start it
#   bash install-target.sh --upgrade   move to COLIBRI_COMMIT or an explicit COLIBRI_REF;
#                                      roll back to the previous commit on failure
#   bash install-target.sh --dry-run   print the plan; change nothing
#
# Colibri has no upstream installer to drive: the C/Python project in <checkout>/c
# is built and installed with make, and served with `coli serve`. So this script
# passes no options to an upstream setup script; it builds, runs `make install`
# into the checkout itself, writes its own launcher, and starts the unit on it.
set -Eeuo pipefail
# Upgrade signal guard
# upgrade_guard on|rollback|off: a signal (Ctrl-C, a closed SSH session,
# kill) during an upgrade must not stop this script before it can roll back.
# on: a signal is recorded in upgrade_interrupted; the upgrade's subshell dies
# from it, so its failure takes the rollback path. rollback: further signals
# are ignored while the previous release is restored. off: the defaults are
# back. After a hangup the output goes to OSR_INTERRUPT_LOG, so writes to the
# closed terminal cannot fail the rollback.
# Every copy matches targets/upgrade-guard.sh (tests/test-signal-rollback.sh).
upgrade_interrupted=''
upgrade_hangup() {
    upgrade_interrupted=${upgrade_interrupted:-129}
    exec >>"${OSR_INTERRUPT_LOG:-/var/log/osr-install-interrupted.log}" 2>&1 || exec >/dev/null 2>&1
}
upgrade_guard() {
    case $1 in
        on)
            upgrade_interrupted=''
            trap 'upgrade_interrupted=${upgrade_interrupted:-130}' INT
            trap 'upgrade_interrupted=${upgrade_interrupted:-143}' TERM
            trap upgrade_hangup HUP ;;
        rollback) trap '' INT TERM HUP ;;
        off) trap - INT TERM HUP ;;
    esac
}
# End upgrade signal guard.

COLIBRI_URL=https://github.com/JustVugg/colibri
# Paths are overridable for tests only; the unit file uses the defaults.
COLIBRI_DIR=${COLIBRI_DIR:-/opt/colibri}
COLIBRI_DATA_DIR=${COLIBRI_DATA_DIR:-/var/lib/colibri}
COLIBRI_ETC_DIR=${COLIBRI_ETC_DIR:-/etc/colibri-target}
# Root-only scratch for the pre-upgrade runtime snapshot (removed after use).
COLIBRI_STATE_DIR=${COLIBRI_STATE_DIR:-/var/lib/colibri-target}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
SERVICE_USER=${SERVICE_USER:-colibri}
# NVIDIA device nodes whose group the service user joins (glob-expanded). They
# are also what colibri_has_nvidia probes, so a test can point them at its own tree.
GPU_NODES=${GPU_NODES:-'/dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-uvm'}
# DRM render nodes (AMD Radeon, Intel Arc) for the Vulkan backend; same reasons.
DRI_NODES=${DRI_NODES:-'/dev/dri/renderD*'}
# Where a Vulkan ICD manifest is installed, in the order the loader looks. Same
# reason: overridable so a test can present an ICD, or none, deterministically.
COLIBRI_ICD_DIRS=${COLIBRI_ICD_DIRS:-'/etc/vulkan/icd.d /usr/share/vulkan/icd.d /usr/local/share/vulkan/icd.d'}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry_run )); then "$@"; fi
}
usage() {
    cat <<'USAGE'
Usage: bash install-target.sh [--dry-run] [--upgrade]
Installs Colibri from https://github.com/JustVugg/colibri as the "colibri"
service account: it builds the C project in <checkout>/c with make, installs it
into the checkout itself (PREFIX=$COLIBRI_DIR, so the launcher is
$COLIBRI_DIR/bin/coli), generates the launcher the service runs, and starts the
hardened colibri systemd service. Re-running fetches the tested default commit,
an explicit COLIBRI_COMMIT or the tip of an explicit COLIBRI_REF before stopping
anything. When the commit, settings and unit are unchanged and Colibri is healthy
it does nothing;
otherwise it upgrades with rollback to the previous commit on failure.

No model is downloaded: Colibri models are 18 GB-500 GB+, so an installer must
never fetch one automatically. The build, install, launcher and service are all
put in place with an empty model directory ($COLIBRI_DATA_DIR/model by
default), and the service parks itself with one line telling you where to put
a model. Copy one there and restart the service (or rerun this script).

--upgrade moves an existing install to COLIBRI_COMMIT (or the current tip of
COLIBRI_REF), rebuilds, restarts and health-checks the service, and returns to
the previous commit if any step fails.

Reruns, with or without --upgrade, keep the settings of the existing installation
(installed-env, or installed-settings for older installs); explicit, non-empty
environment values override them. A fresh install uses the defaults below.

Environment:
  COLIBRI_URL=https://github.com/JustVugg/colibri
  COLIBRI_REF=main, COLIBRI_COMMIT=<full SHA-1 pin, tested default by default>
  COLIBRI_MODEL_DIR=$COLIBRI_DATA_DIR/model (absolute path under COLIBRI_DATA_DIR
                                 for the model directory; created empty, never
                                 downloaded into: the service parks while it is)
  COLIBRI_BACKEND=auto          (auto|cpu|vulkan|cuda; auto = cuda if NVIDIA
                                 device nodes exist, else vulkan if a render node
                                 is passed in (Mesa's Vulkan driver is installed
                                 for it), else cpu. No GPU never fails the install)
  COLIBRI_HOST=0.0.0.0          (address coli serve binds)
  COLIBRI_PORT=8080             (the port OSR uses for Colibri)
  COLIBRI_ALLOWED_HOST=*        (Host headers colibri's DNS-rebinding guard
                                 accepts, comma-separated; * with a wildcard bind,
                                 since clients reach it by an address the CT cannot
                                 know. The API key is required either way)
  COLIBRI_READY_TIMEOUT=900     (seconds; a model load is long)
  COLIBRI_OS_RELEASE=/etc/os-release (override used only to pick the CUDA distro)
USAGE
}

# Install helpers (sourced by test-install.sh) ---------------------------------
# Colibri's build/run layer: make flags, the generated launcher, and the
# settings that decide them. There is no upstream setup.sh to interrogate:
# c/setup.sh only checks gcc/OpenMP, builds and self-tests, and takes no
# model/server/--api-key/--host/--port options, so nothing here parses its help
# or passes such flags to it.

# colibri_has_nvidia: does this CT have NVIDIA access at all? Device nodes are
# the signal; an absent GPU is a supported configuration, never an error.
colibri_has_nvidia() {
    local node
    # shellcheck disable=SC2086  # GPU_NODES is a glob list by design
    for node in $GPU_NODES; do [[ -e $node ]] && return 0; done
    return 1
}

# colibri_has_dri: was a DRM render node (AMD Radeon, Intel Arc) passed in?
colibri_has_dri() {
    local node
    # shellcheck disable=SC2086  # DRI_NODES is a glob list by design
    for node in $DRI_NODES; do [[ -e $node ]] && return 0; done
    return 1
}

# colibri_has_vulkan_icd: is a Vulkan ICD manifest installed? That (plus glslc
# for the shader build) is what makes a VK=1 build worth attempting.
colibri_has_vulkan_icd() {
    local dir
    # shellcheck disable=SC2086  # COLIBRI_ICD_DIRS is a path list by design
    for dir in $COLIBRI_ICD_DIRS; do
        [[ -n $(ls -A "$dir" 2>/dev/null) ]] && return 0
    done
    return 1
}

# resolve_backend: turn COLIBRI_BACKEND (auto|cpu|vulkan|cuda) into the one
# backend actually built, in colibri_backend, plus its make flags. Deliberately
# never fatal: Colibri "runs on the CPU with nothing else installed" (upstream
# README:291), so a backend this CT cannot use is reported and downgraded to cpu.
resolve_backend() {
    colibri_backend=cpu
    colibri_build_flags=()
    case $COLIBRI_BACKEND in
        cuda)
            if colibri_has_nvidia; then colibri_backend=cuda
            else note 'WARNING: COLIBRI_BACKEND=cuda but no NVIDIA device node is visible in this CT; building the CPU backend instead (a GPU can be passed through later and the install rerun).'; fi ;;
        vulkan)
            if colibri_has_vulkan_icd; then colibri_backend=vulkan
            else note 'WARNING: COLIBRI_BACKEND=vulkan but no Vulkan ICD manifest was found (/etc/vulkan/icd.d, /usr/share/vulkan/icd.d); building the CPU backend instead.'; fi ;;
        cpu) : ;;
        *)
            # A Vulkan ICD alone is no GPU (Mesa ships a CPU renderer): auto
            # takes vulkan only for a render node passed into the CT.
            if colibri_has_nvidia; then
                colibri_backend=cuda
            elif colibri_has_dri && colibri_has_vulkan_icd; then
                colibri_backend=vulkan
            else
                note 'No NVIDIA device node and no GPU render node with a Vulkan driver: Colibri builds and runs on the CPU backend, which is fully supported.'
            fi ;;
    esac
    # VK=1 compiles the shaders with glslc; without shaderc the build cannot
    # start, so the auto path does not pick vulkan for it. An explicit
    # COLIBRI_BACKEND=vulkan keeps the request (and upstream's own error).
    if [[ $colibri_backend == vulkan ]] && ! command -v glslc >/dev/null 2>&1; then
        if [[ $COLIBRI_BACKEND == auto ]]; then
            note 'WARNING: glslc (shaderc) is not installed, so the Vulkan shaders cannot be built; falling back to the CPU backend.'
            colibri_backend=cpu
        else
            note 'WARNING: glslc (shaderc) is not installed; the VK=1 build will fail until it is (apt-get install glslc).'
        fi
    fi
    case $colibri_backend in
        cuda) colibri_build_flags=( CUDA=1 ) ;;
        vulkan) colibri_build_flags=( VK=1 ) ;;
    esac
}

# validate_settings: die unless every setting has a value this script accepts.
# An empty COLIBRI_MODEL_DIR is legal and means "install with no model".
validate_settings() {
    if [[ -n $COLIBRI_MODEL_DIR ]]; then
        [[ $COLIBRI_MODEL_DIR == /* ]] || die 'COLIBRI_MODEL_DIR must be an absolute path.'
        [[ $COLIBRI_MODEL_DIR != *..* ]] || die 'COLIBRI_MODEL_DIR must not contain "..".'
        [[ $COLIBRI_MODEL_DIR == "$COLIBRI_DATA_DIR"/* ]] ||
            die "COLIBRI_MODEL_DIR must be inside COLIBRI_DATA_DIR ($COLIBRI_DATA_DIR)."
    fi
    [[ $COLIBRI_BACKEND =~ ^(auto|cpu|vulkan|cuda)$ ]] || die 'COLIBRI_BACKEND must be auto, cpu, vulkan or cuda.'
    [[ $COLIBRI_HOST =~ ^[A-Za-z0-9._:-]{1,63}$ ]] || die 'Invalid COLIBRI_HOST.'
    [[ $COLIBRI_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( COLIBRI_PORT <= 65535 )) || die 'Invalid COLIBRI_PORT.'
    valid_allowed_hosts "$COLIBRI_ALLOWED_HOST" || die 'Invalid COLIBRI_ALLOWED_HOST.'
}

# valid_allowed_hosts LIST: comma-separated Host names for coli serve's
# --allowed-host (each a host name, an address, a bracketed IPv6 address, or *).
valid_allowed_hosts() {
    local host
    local -a hosts=()
    [[ -n $1 && ${#1} -le 255 && $1 != *,, && $1 != ,* && $1 != *, ]] || return 1
    IFS=, read -r -a hosts <<< "$1"
    for host in "${hosts[@]}"; do
        # ']' must come first in a bracket expression; a backslash would be literal.
        [[ $host == '*' || $host =~ ^[][A-Za-z0-9._:-]+$ ]] || return 1
    done
}

# model_placed: is there a model to serve? COLIBRI_MODEL_DIR set and not
# empty. Without one the service parks (the launcher exits 0); that is the
# state of every install until an operator places a model.
model_placed() {
    [[ -n $COLIBRI_MODEL_DIR && -n $(ls -A "$COLIBRI_MODEL_DIR" 2>/dev/null) ]]
}

# settings_fingerprint: what the running service was built and launched with. A
# re-run that finds the same commit, these settings and the same unit does
# nothing. built_backend is the backend resolve_backend chose for this CT (not
# only the one asked for): a GPU passed in later, or taken away, changes it, so
# the next run rebuilds for it.
settings_fingerprint() {
    local key_hash
    key_hash=$(printf '%s' "${api_key:-}" | sha256sum | cut -d' ' -f1) || return 1
    printf 'model_dir=%s\nbackend=%s\nbuilt_backend=%s\nhost=%s\nport=%s\nallowed_host=%s\ndata_dir=%s\nkey_sha256=%s\n' \
        "$COLIBRI_MODEL_DIR" "$COLIBRI_BACKEND" "${colibri_backend:-}" "$COLIBRI_HOST" "$COLIBRI_PORT" \
        "$COLIBRI_ALLOWED_HOST" "$COLIBRI_DATA_DIR" "$key_hash" || return 1
}

# The settings that decide how Colibri is built and launched. save_settings
# records them after every successful install or upgrade, so a failed upgrade can
# roll back to what last worked rather than relaunching with the settings that
# failed (including another model). COLIBRI_READY_TIMEOUT and the CUDA distro
# override are deliberately not here: they change no artefact.
SETTING_KEYS=(COLIBRI_MODEL_DIR COLIBRI_BACKEND COLIBRI_HOST COLIBRI_PORT COLIBRI_ALLOWED_HOST)
# Settings added after records existed, with the value those installs ran with.
# A record without one of them is still complete. (None yet.)
declare -gA SETTING_LEGACY_DEFAULTS=()

# required_setting_keys: the settings every record must hold.
required_setting_keys() {
    local key
    for key in "${SETTING_KEYS[@]}"; do
        [[ -v SETTING_LEGACY_DEFAULTS[$key] ]] || printf '%s\n' "$key"
    done
}

# settings_env: the settings as KEY=value lines (no secrets). An empty
# COLIBRI_MODEL_DIR records as an empty value, which is a real setting here.
settings_env() {
    local key
    for key in "${SETTING_KEYS[@]}"; do printf '%s=%s\n' "$key" "${!key}" || return 1; done
}

# load_settings FILE: set the recorded settings from FILE. The file is parsed,
# never sourced: only the known keys are read, and nothing is changed unless
# every key is present and valid (a key in SETTING_LEGACY_DEFAULTS may be
# missing: it takes that value). Unknown lines are ignored, so a record with
# keys this version no longer knows cannot crash the installer.
load_settings() {
    local file=$1 line key
    local -A found=()
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        [[ $line =~ ^(COLIBRI_[A-Z_]+)=(.*)$ ]] || continue
        [[ " ${SETTING_KEYS[*]} " == *" ${BASH_REMATCH[1]} "* ]] || continue
        found[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    done < "$file"
    for key in "${!SETTING_LEGACY_DEFAULTS[@]}"; do
        [[ -v found[$key] ]] || found[$key]=${SETTING_LEGACY_DEFAULTS[$key]}
    done
    for key in "${SETTING_KEYS[@]}"; do [[ -v found[$key] ]] || return 1; done
    # Validate in a subshell first: validate_settings dies on a bad value.
    (
        for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
        validate_settings
    ) >/dev/null 2>&1 || return 1
    for key in "${SETTING_KEYS[@]}"; do printf -v "$key" '%s' "${found[$key]}"; done
}

# start_env: the unit's first EnvironmentFile: the launcher path ExecStart
# expands. Only that; it is world-readable. The backend and model are fixed in
# the generated launcher (rerun this script to change them).
start_env() {
    printf '# Written by install-target.sh for this Colibri checkout; do not edit.\n'
    printf 'COLIBRI_RUN_SCRIPT=%s\n' "$run_script"
}

# secrets_env: the unit's second EnvironmentFile, root-only (0600): systemd
# reads it before it drops to the service account, and coli serve takes its
# --api-key default from COLI_API_KEY. The key is never on a command line
# (/proc/<pid>/cmdline is readable by every CT user) or in a file the service
# account can read.
secrets_env() {
    printf '# Written by install-target.sh from %s/api-key; do not edit.\n' "$COLIBRI_ETC_DIR"
    printf 'COLI_API_KEY=%s\n' "$api_key"
}

# fingerprint_env FILE: an installed-settings fingerprint (written by every
# version of this script) as the KEY=value lines load_settings reads.
fingerprint_env() {
    sed -n -e 's/^model_dir=/COLIBRI_MODEL_DIR=/p' \
        -e 's/^backend=/COLIBRI_BACKEND=/p' \
        -e 's/^host=/COLIBRI_HOST=/p' \
        -e 's/^port=/COLIBRI_PORT=/p' \
        -e 's/^allowed_host=/COLIBRI_ALLOWED_HOST=/p' "$1"
}

# saved_settings: an existing installation keeps its settings on every rerun,
# with or without --upgrade: the record of its last good install, or for an
# install made before that record existed, its installed-settings fingerprint.
# Explicit, non-empty environment values win. Only a fresh install with no
# checkout, unit or settings record uses the defaults below.
saved_settings() {
    local key
    local -A overrides=()
    for key in "${SETTING_KEYS[@]}"; do
        if [[ -n ${!key-} ]]; then overrides[$key]=${!key}; fi
    done
    if [[ -e $COLIBRI_ETC_DIR/installed-env ]]; then
        load_settings "$COLIBRI_ETC_DIR/installed-env" ||
            die "Invalid or incomplete $COLIBRI_ETC_DIR/installed-env. Fix it, or remove it to fall back to installed-settings; explicit settings in the environment still win."
    elif [[ -e $COLIBRI_ETC_DIR/installed-settings || -L $COLIBRI_ETC_DIR/installed-settings ||
            -e $COLIBRI_ETC_DIR/pending-env || -L $COLIBRI_ETC_DIR/pending-env ||
            -e $COLIBRI_DIR/.git || -L $COLIBRI_DIR/.git ||
            -e $UNIT_DIR/colibri.service || -L $UNIT_DIR/colibri.service ]]; then
        # A checkout or unit still identifies an existing installation when
        # its records have been lost. Never apply fresh defaults to it.
        if [[ -f $COLIBRI_ETC_DIR/installed-settings && -r $COLIBRI_ETC_DIR/installed-settings ]] &&
                load_settings <(fingerprint_env "$COLIBRI_ETC_DIR/installed-settings"); then
            note "Using the settings recorded in $COLIBRI_ETC_DIR/installed-settings (an install from before installed-env)."
        elif [[ ! -e $COLIBRI_ETC_DIR/installed-settings && ! -L $COLIBRI_ETC_DIR/installed-settings &&
                -f $COLIBRI_ETC_DIR/pending-env && -r $COLIBRI_ETC_DIR/pending-env ]] &&
                load_settings "$COLIBRI_ETC_DIR/pending-env"; then
            # A first install that stopped part-way resumes with the settings it
            # was started with, never with the defaults.
            note "Resuming an interrupted install with the settings it was started with ($COLIBRI_ETC_DIR/pending-env)."
        else
            local missing
            if [[ -e $COLIBRI_ETC_DIR/installed-settings || -L $COLIBRI_ETC_DIR/installed-settings ]]; then
                missing="Cannot read this installation's settings from $COLIBRI_ETC_DIR/installed-settings"
            else
                missing="Found an existing Colibri installation (checkout, unit or pending-env) but no readable settings record (installed-env, installed-settings or pending-env in $COLIBRI_ETC_DIR)"
            fi
            local -a required
            mapfile -t required < <(required_setting_keys)
            for key in "${required[@]}"; do
                [[ -v overrides[$key] ]] ||
                    die "$missing; set ${required[*]} explicitly, or restore a record."
            done
        fi
    fi
    for key in "${!overrides[@]}"; do printf -v "$key" '%s' "${overrides[$key]}"; done
}

# End install helpers. ----------------------------------------------------------

# as_service CMD...: run CMD as the service account. The installer lock's
# descriptor is closed for it, so nothing it leaves running in the background
# (git's detached housekeeping, an upstream script's helper) holds the lock
# after the installer has exited.
as_service() {
    if [[ -n ${install_lock_fd:-} ]]; then
        runuser -u "$SERVICE_USER" -- env HOME="$COLIBRI_DATA_DIR" "$@" {install_lock_fd}>&-
    else
        runuser -u "$SERVICE_USER" -- env HOME="$COLIBRI_DATA_DIR" "$@"
    fi
}
git_root() { git -c safe.directory="$COLIBRI_DIR" -C "$COLIBRI_DIR" "$@"; }
verify_source_origin() {
    local origin
    origin=$(git_root remote get-url origin)
    [[ $origin == "$COLIBRI_URL" ]] || die "Existing $COLIBRI_DIR origin is not official: $origin"
}

# Fetch COLIBRI_COMMIT (or the tip of COLIBRI_REF) into FETCH_HEAD without
# touching the checkout, and print the fetched commit. A fetch by commit works
# for any commit, not only a branch tip.
fetch_target() {
    local fetched
    if [[ ! -d $COLIBRI_DIR/.git ]]; then
        as_service git init -q "$COLIBRI_DIR"
        as_service git -C "$COLIBRI_DIR" remote add origin "$COLIBRI_URL"
    fi
    as_service git -c gc.autoDetach=false -c maintenance.autoDetach=false -C "$COLIBRI_DIR" fetch -q --depth 1 origin "${COLIBRI_COMMIT:-$COLIBRI_REF}" >&2 || return 1
    fetched=$(git_root rev-parse FETCH_HEAD) || return 1
    if [[ -n $COLIBRI_COMMIT && ${fetched,,} != "${COLIBRI_COMMIT,,}" ]]; then
        note "Fetched $fetched; expected $COLIBRI_COMMIT."
        return 1
    fi
    printf '%s\n' "$fetched"
}

# Check out a commit that is already in the local repository (no network).
checkout_local() {
    as_service git -C "$COLIBRI_DIR" checkout -q --detach "$1"
    printf 'Colibri source commit: %s\n' "$(git_root rev-parse HEAD)"
}

# probe_build_env: this target used to interrogate an upstream setup.sh --help
# and refuse a checkout missing --api-key/--host/--model; Colibri has no such
# script (c/setup.sh only checks the compiler, builds and self-tests), so that
# whole validation layer is gone. What remains is the one contract the build
# needs: the C project must be in the checkout. Resolving the backend here
# means a GPU the CT cannot use is reported before anything is built.
probe_build_env() {
    [[ -f $COLIBRI_DIR/c/Makefile ]] ||
        die "No c/Makefile in $COLIBRI_DIR: that Colibri checkout has no C project to build (make -C \"$COLIBRI_DIR/c\" is how this target installs it)."
    resolve_backend
    if [[ $colibri_backend == vulkan ]] && (( ! dry_run )); then check_vulkan_device; fi
}

# Mesa's Vulkan driver, the loader and its headers, glslc and the SPIR-V
# headers: what a VK=1 build and its run need (the llama.cpp target uses the
# same set), and vulkaninfo for check_vulkan_device.
VULKAN_PACKAGES='mesa-vulkan-drivers libvulkan1 libvulkan-dev glslc spirv-headers vulkan-tools'
# ensure_vulkan_packages: install them for a CT that was given a render node
# (or told COLIBRI_BACKEND=vulkan) and lacks them. A CT without one never gets
# them, so auto cannot mistake Mesa's CPU renderer for a GPU.
ensure_vulkan_packages() {
    case $COLIBRI_BACKEND in
        vulkan) ;;
        auto) colibri_has_nvidia && return 0; colibri_has_dri || return 0 ;;
        *) return 0 ;;
    esac
    command -v glslc >/dev/null 2>&1 && command -v vulkaninfo >/dev/null 2>&1 && return 0
    # shellcheck disable=SC2086  # a package list
    run env DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y $VULKAN_PACKAGES
}

# check_vulkan_device: the service account must reach a GPU through Vulkan (not
# only Mesa's CPU renderer) on a render node it can open, or a VK=1 build would
# run on the CPU and say nothing.
check_vulkan_device() {
    local node usable=0 summary
    # shellcheck disable=SC2086  # DRI_NODES is a glob list by design
    for node in $DRI_NODES; do
        [[ -e $node ]] || continue
        as_service test -r "$node" -a -w "$node" && usable=1
    done
    (( usable )) || die "$SERVICE_USER cannot open a GPU render node ($DRI_NODES); pass the card's render node into the CT (path=/dev/dri/renderD<n>,gid=44,mode=0660), or set COLIBRI_BACKEND=cpu."
    summary=$(as_service vulkaninfo --summary 2>&1) || die "vulkaninfo failed as $SERVICE_USER: $summary"
    [[ $summary == *PHYSICAL_DEVICE_TYPE_DISCRETE_GPU* || $summary == *PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU* ]] ||
        die "Vulkan sees no GPU in this CT (only: $(grep -o 'deviceName *= .*' <<< "$summary" | paste -sd, -)). Check the host driver (tools/setup-host-gpu.sh) and the render node, or set COLIBRI_BACKEND=cpu."
}

# colibri_nvcc: the CUDA compiler the build uses. c/Makefile defaults to
# /usr/local/cuda/bin/nvcc; a toolkit without that link is found on PATH or
# under /usr/local/cuda-X.Y, and passed as CUDA_HOME (which also sets the
# engines' rpath to its lib64).
colibri_nvcc() {
    local candidate
    for candidate in "${COLIBRI_NVCC:-}" /usr/local/cuda/bin/nvcc "$(command -v nvcc 2>/dev/null)"; do
        [[ -n $candidate && -x $candidate ]] && { printf '%s\n' "$candidate"; return 0; }
    done
    candidate=$(compgen -G '/usr/local/cuda-*/bin/nvcc' | sort -V | tail -n1)
    [[ -n $candidate && -x $candidate ]] && printf '%s\n' "$candidate"
}

# Upstream make needs a system toolkit for a CUDA build. Choose a toolkit NVIDIA
# publishes for this CT; cuda-toolkit-X-Y does not install a kernel driver.
# Optional: only reached when COLIBRI_BACKEND resolved to cuda and nvcc is
# missing, so a CPU or Vulkan install never touches NVIDIA's repository.
cuda_toolkit_target() {
    local ID VERSION_ID
    # shellcheck disable=SC1090,SC1091
    . "${COLIBRI_OS_RELEASE:-/etc/os-release}"
    case $ID:$VERSION_ID in
        ubuntu:22.04) printf 'ubuntu2204 13.0\n' ;;
        ubuntu:24.04) printf 'ubuntu2404 13.0\n' ;;
        debian:12) printf 'debian12 13.0\n' ;;
        debian:13) printf 'debian13 13.1\n' ;;
        *) return 1 ;;
    esac
}

install_cuda_toolkit() {
    local version distro package keyring keyring_url temporary nvcc
    read -r distro version < <(cuda_toolkit_target) || return 1
    [[ -n $distro && -n $version ]] || return 1
    package=cuda-toolkit-${version/./-}
    nvcc=${COLIBRI_NVCC:-/usr/local/cuda-$version/bin/nvcc}
    keyring=cuda-keyring_1.1-1_all.deb
    keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/$distro/x86_64/$keyring"
    note "Colibri needs the CUDA toolkit for the requested cuda backend; installing $package from NVIDIA's $distro repository as root."
    apt-get update
    apt-get install -y ca-certificates curl build-essential
    temporary=$(mktemp "${TMPDIR:-/tmp}/colibri-cuda-keyring.XXXXXX.deb")
    if ! curl -fsSL --retry 3 -o "$temporary" "$keyring_url"; then
        rm -f -- "$temporary"
        die "Could not download NVIDIA's CUDA keyring from $keyring_url."
    fi
    if ! dpkg -i "$temporary"; then
        rm -f -- "$temporary"
        die "Could not install NVIDIA's CUDA keyring for $distro."
    fi
    rm -f -- "$temporary"
    apt-get update
    apt-cache show "$package" >/dev/null 2>&1 ||
        die "NVIDIA's $distro repository does not offer $package."
    apt-get install -y "$package"
    [[ -x $nvcc ]] || die "$package installed but $nvcc is missing."
    "$nvcc" --version | grep -Fq "release $version" ||
        die "$nvcc does not report CUDA $version after installing $package."
    as_service nvidia-smi -L >/dev/null || die 'NVIDIA GPU access failed after the CUDA toolkit install.'
    note "CUDA $version toolkit is ready; building Colibri as $SERVICE_USER."
}

# generate_run_script: the launcher the service runs, generated here because
# Colibri installs a CLI (coli), not a per-model start script. One exec of
# `coli serve`, whose flags are read from the argparse contract in c/coli
# (serve: --host, --port, --api-key, --allowed-host, and --model, --auto-tier
# and --gpu from the shared parent parser) - and never `coli web`, which opens
# a browser. The flags follow what upstream's own `coli start` runs
# (setup_flow.launcher_args): --auto-tier applies the RAM/VRAM plan (without it
# most families run a fixed default cache), --gpu auto puts the plan's VRAM tier
# on a CUDA card, and a Vulkan engine needs COLI_VULKAN=1 to use the GPU at all,
# plus COLI_VK_SHADERS (make install copies no shaders to libexec).
#
# The API key is not here: coli serve reads COLI_API_KEY, which systemd sets
# from the root-only secrets.env.
#
# No model is a supported state, not an error: models are 18 GB-500 GB+, so an
# installer must never fetch one. The launcher then logs one actionable line
# and exits 0, which leaves the unit inactive (dead) under Restart=on-failure
# instead of crash-looping. It checks again at every start, so a model copied
# into a configured COLIBRI_MODEL_DIR needs only a restart.
generate_run_script() {
    local part host message
    local -a args hosts=()
    run_script=$COLIBRI_DIR/run-colibri.sh
    args=( serve --host "$COLIBRI_HOST" --port "$COLIBRI_PORT" )
    IFS=, read -r -a hosts <<< "$COLIBRI_ALLOWED_HOST"
    for host in "${hosts[@]}"; do args+=( --allowed-host "$host" ); done
    [[ -z $COLIBRI_MODEL_DIR ]] || args+=( --model "$COLIBRI_MODEL_DIR" )
    args+=( --auto-tier )
    [[ ${colibri_backend:-cpu} != cuda ]] || args+=( --gpu auto )
    if [[ -n $COLIBRI_MODEL_DIR ]]; then
        message="colibri: parked, $COLIBRI_MODEL_DIR is empty. Copy a model directory there, then: systemctl restart colibri"
    else
        message="colibri: parked, no model configured. Put a model directory under $COLIBRI_DATA_DIR, then rerun: COLIBRI_MODEL_DIR=$COLIBRI_DATA_DIR/<model> bash /root/colibri-target-deploy/install-target.sh"
    fi
    {
        printf '#!/bin/sh\n'
        printf '# Generated by colibri install-target.sh; do not edit (rerun it with COLIBRI_* settings).\n'
        printf '# The API key reaches coli serve as COLI_API_KEY from %s/secrets.env.\n' "$COLIBRI_ETC_DIR"
        printf 'model=%q\n' "${COLIBRI_MODEL_DIR:-}"
        printf 'if [ -z "$model" ] || [ -z "$(ls -A "$model" 2>/dev/null)" ]; then\n'
        printf '  echo %q\n' "$message"
        printf '  exit 0\n'
        printf 'fi\n'
        if [[ ${colibri_backend:-cpu} == vulkan ]]; then
            printf 'export COLI_VULKAN=1\n'
            printf 'export COLI_VK_SHADERS=%q\n' "$COLIBRI_DIR/c/shaders"
        fi
        printf 'cd %q\n' "$COLIBRI_DIR"
        printf 'exec %q' "$COLIBRI_DIR/bin/coli"
        for part in "${args[@]}"; do printf ' %q' "$part"; done
        printf '\n'
    } > "$run_script"
    chmod 0700 "$run_script"
    chown "$SERVICE_USER:$SERVICE_USER" "$run_script"
}

# run_setup: build and install, then write the launcher.
#
# One make invocation does both, on purpose: c/Makefile's `install` target
# depends on every engine binary (colibri glm53 inkling kimi_k3 olmoe qwen36
# qwen38 deepseek_v41 mimo qwenimage laya gliner_decide, plus deepseek-v4 when
# supported), so `make install` builds them all and a separate build first
# would only re-enter make over the same objects. PREFIX is the checkout itself
# (c/Makefile: PREFIX, BINDIR and LIBEXECDIR are ?= overridable), so coli lands
# at $COLIBRI_DIR/bin/coli and the engines at $COLIBRI_DIR/libexec/colibri/
# (coli finds them relative to itself), nothing is written to /usr/local, and a
# rollback of the checkout takes the install with it. VK=1 / CUDA=1 come from
# the resolved backend; the CPU build passes neither. c/setup.sh is not used: it
# builds too, which would compile everything twice.
run_setup() {
    local build_log nvcc
    if (( dry_run )); then return 0; fi
    # The CUDA lane needs nvcc; install the toolkit as root only for it.
    if [[ $colibri_backend == cuda ]]; then
        nvcc=$(colibri_nvcc) || nvcc=''
        if [[ -z $nvcc ]]; then
            note 'No nvcc found for the cuda backend.'
            cuda_toolkit_target >/dev/null ||
                die 'COLIBRI_BACKEND=cuda and this CT has no nvcc; install a CUDA toolkit, or set COLIBRI_BACKEND=cpu or vulkan.'
            install_cuda_toolkit
            nvcc=$(colibri_nvcc) || die 'The CUDA toolkit is installed but no nvcc was found.'
        fi
        colibri_build_flags+=( "CUDA_HOME=${nvcc%/bin/nvcc}" )
    fi
    build_log=$(mktemp "$COLIBRI_ETC_DIR/build-output.XXXXXX")
    printf '+ (as %s) make -C %s/c install PREFIX=%s -j%s %s\n' \
        "$SERVICE_USER" "$COLIBRI_DIR" "$COLIBRI_DIR" "$(nproc)" "${colibri_build_flags[*]-}"
    if ! ( as_service make -C "$COLIBRI_DIR/c" install "PREFIX=$COLIBRI_DIR" -j"$(nproc)" \
            "${colibri_build_flags[@]+"${colibri_build_flags[@]}"}" 2>&1 | tee "$build_log" ); then
        note "Build or install failed; the last lines are in $build_log."
        return 1
    fi
    rm -f -- "$build_log"
    # The contract every later step assumes: the launcher make install put there.
    [[ -x "$COLIBRI_DIR/bin/coli" ]] || \
        die "make install reported success but $COLIBRI_DIR/bin/coli is missing or not executable; check the BINDIR/PREFIX of the make output above (expected PREFIX=$COLIBRI_DIR, engines in $COLIBRI_DIR/libexec/colibri)."
    generate_run_script
}

# Serialize real runs before reading saved settings. Keep the descriptor open
# for the entire installer; never unlink the lock file while another run may
# be waiting on its inode. Dry runs do not write or take the lock.
acquire_install_lock() {
    (( dry_run )) && return 0
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Colibri LXC.'
    [[ $COLIBRI_ETC_DIR =~ ^/[A-Za-z0-9._/-]+$ && $COLIBRI_ETC_DIR != *..* ]] || die 'Invalid COLIBRI_ETC_DIR.'
    local previous_umask lock_directory
    lock_directory=$(realpath -m -- "$COLIBRI_ETC_DIR") || return 1
    previous_umask=$(umask)
    umask 077
    exec {install_lock_fd}>>"$lock_directory.lock"
    umask "$previous_umask"
    flock -n "$install_lock_fd" || die 'Another Colibri installer is already running (or a process it started still holds the lock).'
}

# A rename is durable only after its containing directory has been flushed.
# In save_settings this also orders settings publication before the fingerprint.
publish_record() {
    local temporary=$1 destination=$2
    mv -fT -- "$temporary" "$destination" || return 1
    sync -- "${destination%/*}"
}

# Stage a complete, private record beside its destination. Only rename it
# after the writer succeeds, so a failed write cannot truncate a good record.
stage_record() {
    local destination=$1 temporary
    shift
    # A run killed while staging leaves its mktemp file behind (an api-key one
    # holds the key); drop such leftovers before staging a new one.
    rm -f -- "$destination".?????? || return 1
    temporary=$(mktemp "$destination.XXXXXX") || return 1
    # Flush the contents before the caller renames the file into place, so a
    # power loss cannot leave the new name pointing at an empty file.
    if ! "$@" > "$temporary" || ! sync -- "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    printf '%s\n' "$temporary"
}

# write_pending: record the settings a fresh (or resumed) install runs with
# before it changes anything, so an interrupted first install resumes with
# them instead of the defaults. save_settings removes it.
write_pending() {
    (( dry_run )) && return 0
    install -d -m 0700 "$COLIBRI_ETC_DIR"
    # Persist a newly created record directory before relying on its checkpoint.
    sync -- "$COLIBRI_ETC_DIR/.." || return 1
    local temporary
    temporary=$(stage_record "$COLIBRI_ETC_DIR/pending-env" settings_env) || return 1
    if ! publish_record "$temporary" "$COLIBRI_ETC_DIR/pending-env"; then
        rm -f -- "$temporary"
        return 1
    fi
}

save_settings() {
    local fingerprint_temporary env_temporary
    fingerprint_temporary=$(stage_record "$COLIBRI_ETC_DIR/installed-settings" settings_fingerprint) || return 1
    if ! env_temporary=$(stage_record "$COLIBRI_ETC_DIR/installed-env" settings_env); then
        rm -f -- "$fingerprint_temporary"
        return 1
    fi
    # Prepare both records before publishing either. Each rename publishes a
    # complete record. installed-env (the settings every rerun starts from) goes
    # first and the fingerprint (the "nothing to do" marker) last: interrupted
    # between the two, the next run has the new settings and an old marker, so
    # it re-applies them once instead of reverting to the previous settings.
    if ! publish_record "$env_temporary" "$COLIBRI_ETC_DIR/installed-env" ||
        ! publish_record "$fingerprint_temporary" "$COLIBRI_ETC_DIR/installed-settings"; then
        rm -f -- "$fingerprint_temporary" "$env_temporary"
        return 1
    fi
    rm -f -- "$COLIBRI_ETC_DIR/pending-env" || return 1
    sync -- "$COLIBRI_ETC_DIR"
}

ensure_api_key() {
    install -d -m 0700 "$COLIBRI_ETC_DIR"
    # A key write killed mid-way leaves its staging file (holding a key) even
    # when a key is in place by now; never keep such copies around.
    rm -f -- "$COLIBRI_ETC_DIR/api-key".?????? || return 1
    if [[ ! -s $COLIBRI_ETC_DIR/api-key ]]; then
        local temporary
        temporary=$(stage_record "$COLIBRI_ETC_DIR/api-key" openssl rand -hex 32) || return 1
        if ! publish_record "$temporary" "$COLIBRI_ETC_DIR/api-key"; then
            rm -f -- "$temporary"
            return 1
        fi
    fi
    chmod 0600 "$COLIBRI_ETC_DIR/api-key"
    sync -- "$COLIBRI_ETC_DIR/api-key" "$COLIBRI_ETC_DIR" || return 1
    api_key=$(< "$COLIBRI_ETC_DIR/api-key")
}

# installed_unchanged: built and configured exactly as the last successful run
# left it: same settings (and resolved backend), same unit, and the installed
# coli and launcher still in place.
installed_unchanged() {
    [[ -f $COLIBRI_ETC_DIR/installed-settings ]] &&
        [[ $(settings_fingerprint) == "$(< "$COLIBRI_ETC_DIR/installed-settings")" ]] &&
        cmp -s "$source_dir/colibri.service" "$UNIT_DIR/colibri.service" &&
        [[ -x $COLIBRI_DIR/bin/coli && -x $run_script && -s $COLIBRI_ETC_DIR/secrets.env ]]
}

# Unchanged since the last successful install or upgrade, and in the state it
# should be in: serving its model, or parked (enabled, not failed) without one.
nothing_to_do() {
    installed_unchanged || return 1
    if model_placed; then
        systemctl is-active --quiet colibri.service && probe_health
    else
        systemctl is-enabled --quiet colibri.service && ! systemctl is-failed --quiet colibri.service
    fi
}

write_unit() {
    local temporary
    start_env > "$COLIBRI_ETC_DIR/colibri.env"
    chmod 0644 "$COLIBRI_ETC_DIR/colibri.env"
    temporary=$(stage_record "$COLIBRI_ETC_DIR/secrets.env" secrets_env) || return 1
    chmod 0600 "$temporary"
    publish_record "$temporary" "$COLIBRI_ETC_DIR/secrets.env" || { rm -f -- "$temporary"; return 1; }
    install -m 0644 "$source_dir/colibri.service" "$UNIT_DIR/colibri.service"
    systemctl daemon-reload
}

# Colibri exposes no /health endpoint. The readiness signal is the OpenAI
# catalogue: GET /v1/models answers 200 once the server is listening, and
# curl -f turns any non-2xx into a failure. An EMPTY model list still counts as
# up: a server with no model loaded is the parked state this installer installs,
# and it answers requests (a request for a model it lacks is the server's error
# to give, not a dead socket). The key comes from the file, never from argv the
# installer prints.
probe_health() {
    local host=$COLIBRI_HOST
    # 0.0.0.0/:: are bind addresses, not client addresses; probe loopback.
    [[ -n $host && $host != 0.0.0.0 && $host != '::' && $host != '[::]' ]] || host=127.0.0.1
    [[ -r $COLIBRI_ETC_DIR/api-key ]] || return 1
    curl -fsS --max-time 5 \
        -H "Authorization: Bearer $(cat "$COLIBRI_ETC_DIR/api-key")" \
        "http://$host:$COLIBRI_PORT/v1/models" >/dev/null 2>&1
}

wait_ready() {
    local deadline=$(( SECONDS + COLIBRI_READY_TIMEOUT ))
    while (( SECONDS < deadline )); do
        probe_health && return 0
        if systemctl is-failed --quiet colibri.service; then
            note "colibri.service failed; see journalctl -u colibri."
            return 1
        fi
        # The parked state (no model configured, or its directory empty) is a
        # success: the launcher logs where to put a model and exits 0, so the
        # unit settles at inactive (dead) and Restart=on-failure leaves it
        # there. Waiting for /v1/models would time out on an install that is
        # exactly as configured as it should be.
        if ! model_placed && [[ $(systemctl is-active colibri.service 2>/dev/null) == inactive ]]; then
            if [[ -n $COLIBRI_MODEL_DIR ]]; then
                note "Colibri is installed and parked: $COLIBRI_MODEL_DIR is empty. Copy a model directory there and run 'systemctl restart colibri'."
            else
                note "Colibri is installed and parked: no model is configured. Put a model directory under $COLIBRI_DATA_DIR and rerun this script with COLIBRI_MODEL_DIR=$COLIBRI_DATA_DIR/<model>."
            fi
            return 0
        fi
        sleep 5
    done
    note "Colibri has not answered on port $COLIBRI_PORT within ${COLIBRI_READY_TIMEOUT}s; see journalctl -u colibri."
    return 1
}

ensure_service_user() {
    local node group gid
    getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
    id -u "$SERVICE_USER" >/dev/null 2>&1 ||
        useradd --system --gid "$SERVICE_USER" --home-dir "$COLIBRI_DATA_DIR" \
            --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    # GPU access: join each passed-through node's non-root group. A root-group
    # node may still be usable when the service account itself has read/write
    # access (for example mode 0666); never add the account to group root.
    # The account joins video (gid 44, provision-lxc.sh's GPU_GID default)
    # anyway, so the service keeps its GPU when the mapping is later tightened
    # to gid=44,mode=0660 and the CT restarts.
    # shellcheck disable=SC2086  # GPU_NODES and DRI_NODES are glob lists by design
    for node in $GPU_NODES $DRI_NODES; do
        [[ -e $node ]] || continue
        gid=$(stat -c %g "$node")
        if [[ $gid == 0 ]]; then
            if as_service test -r "$node" && as_service test -w "$node"; then
                note "WARNING: $node is group root, but $SERVICE_USER can read and write it. Check its actual permissions against the PVE --devN setting; mode 0666 exposes the GPU to all CT users."
                if getent group video >/dev/null; then
                    usermod -aG video "$SERVICE_USER"
                fi
                continue
            fi
            die "$node is group root and $SERVICE_USER cannot read and write it. On the PVE host compare 'pct config <CT_ID>' with the node's actual CT permissions. If its --devN mapping is missing or wrong, set path=$node,gid=44,mode=0660 (44 is video), reboot the CT, and retry; otherwise investigate the device mount and NVIDIA setup."
        fi
        group=$(stat -c %G "$node")
        usermod -aG "$group" "$SERVICE_USER"
        as_service test -r "$node" && as_service test -w "$node" ||
            die "$SERVICE_USER cannot read and write $node after joining group $group (gid $gid); check its CT mode and Proxmox --devN mapping."
    done
    # A CT with no GPU is a supported configuration (Colibri runs on the CPU
    # with nothing else installed), so this is only checked when NVIDIA nodes
    # exist. A render node is checked through Vulkan once the backend is known.
    colibri_has_nvidia || return 0
    as_service nvidia-smi -L >/dev/null ||
        die "$SERVICE_USER cannot use the NVIDIA GPU even though the device nodes are visible; inspect the CT's --devN mappings and permissions, or set COLIBRI_BACKEND=cpu."
}

do_install() {
    # A complete installation uses the upgrade path on a normal rerun too, so
    # the service is stopped and the previous commit can be restored on failure.
    if [[ -d $COLIBRI_DIR/.git && -f $UNIT_DIR/colibri.service ]]; then
        do_upgrade
        return
    fi
    write_pending
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git openssl python3 build-essential
    ensure_vulkan_packages
    resolve_backend
    if (( dry_run )); then
        printf '+ create the %s service account; add it to the groups of %s %s (skipped for a CT with no GPU)\n' "$SERVICE_USER" "$GPU_NODES" "$DRI_NODES"
        printf '+ git fetch --depth 1 %s %s into %s (as %s)\n' "$COLIBRI_URL" "${COLIBRI_COMMIT:-$COLIBRI_REF}" "$COLIBRI_DIR" "$SERVICE_USER"
        printf '+ build backend: %s (COLIBRI_BACKEND=%s)%s\n' "$colibri_backend" "$COLIBRI_BACKEND" "$( [[ $colibri_backend == cuda ]] && printf '; installs the NVIDIA CUDA toolkit as root first if nvcc is missing')$( [[ $colibri_backend == vulkan ]] && printf '; checks with vulkaninfo that %s reaches the GPU' "$SERVICE_USER")"
        printf '+ (as %s) make -C %s/c install PREFIX=%s -j<nproc>%s\n' "$SERVICE_USER" "$COLIBRI_DIR" "$COLIBRI_DIR" "$( [[ $colibri_backend == cuda ]] && printf ' CUDA=1 CUDA_HOME=<toolkit>' )$( [[ $colibri_backend == vulkan ]] && printf ' VK=1' )"
        printf '+ one make call: c/Makefile install depends on every engine binary, so there is no separate build step (and c/setup.sh is not run; it would compile everything a second time)\n'
        printf '+ assert %s/bin/coli is executable (engines in %s/libexec/colibri)\n' "$COLIBRI_DIR" "$COLIBRI_DIR"
        printf '+ write %s/run-colibri.sh (0700, %s-owned): exec %s/bin/coli serve --host %s --port %s --allowed-host %s%s --auto-tier%s\n' \
            "$COLIBRI_DIR" "$SERVICE_USER" "$COLIBRI_DIR" "$COLIBRI_HOST" "$COLIBRI_PORT" "$COLIBRI_ALLOWED_HOST" \
            "$( [[ -n $COLIBRI_MODEL_DIR ]] && printf ' --model %s' "$COLIBRI_MODEL_DIR" )" \
            "$( [[ $colibri_backend == cuda ]] && printf ' --gpu auto' )$( [[ $colibri_backend == vulkan ]] && printf ' (with COLI_VULKAN=1)' )"
        printf '+ %s\n' "$( [[ -n $COLIBRI_MODEL_DIR ]] && printf 'serve the model in %s (parked while it is empty)' "$COLIBRI_MODEL_DIR" || printf 'no model configured (no COLIBRI_MODEL_DIR): the launcher logs where to put a model and exits 0 (no model is ever downloaded; they are 18GB-500GB+), and the unit parks inactive')"
        printf '+ write %s/colibri.env (COLIBRI_RUN_SCRIPT only), %s/secrets.env (0600: COLI_API_KEY) and %s/colibri.service\n' "$COLIBRI_ETC_DIR" "$COLIBRI_ETC_DIR" "$UNIT_DIR"
        run systemctl enable colibri.service
        run systemctl restart colibri.service
        printf '+ wait for GET http://%s:%s/v1/models to answer 200 with the bearer key, up to %ss; a parked install (no model yet) is ready once the launcher has exited 0\n' \
            "$( [[ $COLIBRI_HOST == 0.0.0.0 || $COLIBRI_HOST == :: ]] && printf 127.0.0.1 || printf '%s' "$COLIBRI_HOST" )" "$COLIBRI_PORT" "$COLIBRI_READY_TIMEOUT"
        return 0
    fi
    ensure_api_key
    ensure_service_user
    install -d -m 0700 "$COLIBRI_ETC_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$COLIBRI_DATA_DIR"
    if [[ -n $COLIBRI_MODEL_DIR ]]; then
        # Created for the operator to copy a model into, never downloaded: an
        # empty directory parks the service instead of failing the install.
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$COLIBRI_MODEL_DIR"
        model_placed ||
            note "WARNING: $COLIBRI_MODEL_DIR is empty; Colibri will park until a model is placed there."
    fi
    if [[ -d $COLIBRI_DIR/.git ]]; then
        verify_source_origin
        # A resumed install: the tree belongs to the service account (a step run
        # as root, or a copy made by hand, may have left root-owned files).
        chown -R "$SERVICE_USER:$SERVICE_USER" "$COLIBRI_DIR" "$COLIBRI_DATA_DIR"
        printf 'Resuming the incomplete Colibri checkout at %s.\n' "$COLIBRI_DIR"
    else
        install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0755 "$COLIBRI_DIR"
    fi
    local target
    target=$(fetch_target) || die "Could not fetch $COLIBRI_URL ${COLIBRI_COMMIT:-$COLIBRI_REF}."
    checkout_local "$target"
    probe_build_env
    run_setup
    write_unit
    systemctl enable colibri.service
    systemctl restart colibri.service
    wait_ready || die 'Colibri did not become ready.'
    save_settings
}

# Check out COMMIT (already local) and bring the service up on it. Runs in a
# subshell with errexit, so any failure returns non-zero to the caller.
apply_checkout() {
    set -e
    checkout_local "$1"
    probe_build_env
    run_setup
    write_unit
    systemctl restart colibri.service
    wait_ready
}

# Keep a complete runnable checkout at its original absolute path on rollback.
# Models in the separate data directory are not copied. Stop the service before
# taking this snapshot so the checkout, engines and launcher form one state.
snapshot_runtime() {
    install -d -m 0700 "$COLIBRI_STATE_DIR"
    (umask 077
     tar -C "$COLIBRI_DIR" --exclude='./.git' -cpf "$COLIBRI_STATE_DIR/rollback-runtime.tar.new" . &&
     mv -f -- "$COLIBRI_STATE_DIR/rollback-runtime.tar.new" "$COLIBRI_STATE_DIR/rollback-runtime.tar") || {
        rm -f -- "$COLIBRI_STATE_DIR/rollback-runtime.tar.new"
        return 1
    }
    cp -p -- "$UNIT_DIR/colibri.service" "$COLIBRI_STATE_DIR/rollback.service" || return 1
    cp -p -- "$COLIBRI_ETC_DIR/colibri.env" "$COLIBRI_STATE_DIR/rollback.env"
}

# clear_snapshot: drop the snapshot once it is no longer needed (after a
# successful upgrade or rollback). A failed rollback keeps it for inspection.
clear_snapshot() {
    rm -f -- "$COLIBRI_STATE_DIR/rollback-runtime.tar" "$COLIBRI_STATE_DIR/rollback-runtime.tar.new" "$COLIBRI_STATE_DIR/rollback.service" "$COLIBRI_STATE_DIR/rollback.env"
}

# restore_probe_settings: the port from the fingerprint, for installs made
# before installed-env existed.
restore_probe_settings() {
    local port
    port=$(sed -n 's/^port=//p' "$COLIBRI_ETC_DIR/installed-settings" 2>/dev/null | tail -n1) || true
    if [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )); then COLIBRI_PORT=$port; fi
}

# No build, install or model download is invoked on this path. The caller has
# set the settings the previous runtime ran with (wait_ready uses its port).
restore_runtime() {
    set -e
    [[ $COLIBRI_DIR != / && -d $COLIBRI_DIR/.git && -s $COLIBRI_STATE_DIR/rollback-runtime.tar ]]
    as_service git -C "$COLIBRI_DIR" reset -q --hard "$1"
    find "$COLIBRI_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
    tar -C "$COLIBRI_DIR" -xpf "$COLIBRI_STATE_DIR/rollback-runtime.tar"
    install -m 0644 "$COLIBRI_STATE_DIR/rollback.service" "$UNIT_DIR/colibri.service"
    cp -p -- "$COLIBRI_STATE_DIR/rollback.env" "$COLIBRI_ETC_DIR/colibri.env"
    systemctl daemon-reload
    systemctl restart colibri.service
    wait_ready
}

do_upgrade() {
    if (( dry_run )); then
        ensure_vulkan_packages
        resolve_backend
        printf '+ git fetch --depth 1 %s %s (before anything is stopped; a failed fetch changes nothing)\n' \
            "$COLIBRI_URL" "${COLIBRI_COMMIT:-$COLIBRI_REF}"
        printf '+ same commit, settings (model dir, backend as built, host, port, allowed hosts) and unit, and serving (or parked without a model): nothing to do\n'
        printf '+ the same, but not serving: restart it; rebuild only if that does not bring it back\n'
        printf '+ otherwise: record the current commit; systemctl stop colibri.service; checkout; make -C %s/c install PREFIX=%s %s; regenerate run-colibri.sh; restart; wait for /v1/models to answer 200\n' "$COLIBRI_DIR" "$COLIBRI_DIR" "${colibri_build_flags[*]-}"
        printf '+ on failure: check out the previous commit locally (no network) and restore its runnable checkout, launcher and unit without a build or downloads (%s/rollback-runtime.tar, removed afterwards)\n' "$COLIBRI_STATE_DIR"
        return 0
    fi
    [[ -d $COLIBRI_DIR/.git && -f $UNIT_DIR/colibri.service ]] ||
        die "No Colibri installation at $COLIBRI_DIR; run without --upgrade first."
    verify_source_origin
    ensure_api_key
    ensure_service_user
    chown -R "$SERVICE_USER:$SERVICE_USER" "$COLIBRI_DIR" "$COLIBRI_DATA_DIR"
    # The backend this CT gets now (a GPU may have been passed in or taken away
    # since the last run); the fingerprint compares it with the one built.
    ensure_vulkan_packages
    resolve_backend
    local previous target rc
    previous=$(git_root rev-parse HEAD)
    # Keep the running commit reachable so rollback never needs the network.
    as_service git -C "$COLIBRI_DIR" update-ref refs/colibri/previous "$previous"
    target=$(fetch_target) ||
        die "Could not fetch $COLIBRI_URL ${COLIBRI_COMMIT:-$COLIBRI_REF}; Colibri was not stopped or changed."
    if [[ $target == "$previous" ]] && nothing_to_do; then
        # A matching legacy fingerprint is sufficient to migrate its records.
        if [[ ! -f $COLIBRI_ETC_DIR/installed-env ]]; then
            save_settings
        fi
        if model_placed; then
            printf 'Colibri is already at %s with these settings and is healthy; nothing to do.\n' "$previous"
        else
            printf 'Colibri is already at %s with these settings and is parked without a model; nothing to do.\n' "$previous"
        fi
        return 0
    fi
    # Built and configured as before but not serving (a model copied in since,
    # a crash, a reboot that left it stopped): the launcher reads the model at
    # every start, so a restart is all it may need. Rebuild only if it is not.
    if [[ $target == "$previous" ]] && installed_unchanged; then
        printf 'Colibri %s is built with these settings; restarting it.\n' "$previous"
        systemctl restart colibri.service
        if wait_ready; then
            printf 'Colibri %s is back after a restart (serving, or parked without a model); nothing to rebuild.\n' "$previous"
            return 0
        fi
        note 'A restart did not bring Colibri back; re-applying the build.'
    fi
    if [[ $target == "$previous" ]]; then
        printf 'Re-applying Colibri %s (settings, unit or health changed).\n' "$previous"
    else
        printf 'Upgrading Colibri from %s to %s.\n' "$previous" "$target"
    fi
    upgrade_guard on
    systemctl stop colibri.service
    if ! snapshot_runtime; then
        note 'Could not snapshot the previous runtime; no upgrade was applied.'
        (load_settings "$COLIBRI_ETC_DIR/installed-env" || restore_probe_settings
         systemctl restart colibri.service; wait_ready) ||
            die 'Snapshot failed and the previous service did not become ready.'
        die 'Runtime snapshot failed; the previous service is running again.'
    fi
    set +e
    ( apply_checkout "$target" )
    rc=$?
    set -e
    if (( rc == 0 )); then
        save_settings
        clear_snapshot
        printf 'Colibri is running %s.\n' "$(git_root rev-parse HEAD)"
        upgrade_guard off
        return 0
    fi
    note "Upgrade failed; returning to $previous."
    upgrade_guard rollback
    systemctl stop colibri.service || true
    # The settings the previous runtime ran with: the record of the last good
    # install (the fingerprint's port for older installs). wait_ready checks
    # the restored service on that port.
    if load_settings "$COLIBRI_ETC_DIR/installed-env"; then
        note "Restoring the settings it last ran with: $(settings_env | tr '\n' ' ')"
    else
        restore_probe_settings
        note 'No record of the previous settings; restoring the complete runtime snapshot.'
    fi
    set +e
    ( restore_runtime "$previous" )
    rc=$?
    set -e
    if (( rc != 0 )); then
        : > "$COLIBRI_STATE_DIR/rollback-failed" || true
        die "Rollback to $previous failed too; inspect journalctl -u colibri and $COLIBRI_DIR; the snapshot is kept in $COLIBRI_STATE_DIR."
    fi
    clear_snapshot
    die "Upgrade failed; Colibri is running $previous again."
}

dry_run=0
mode=install
while (( $# )); do
    case $1 in
        --dry-run) dry_run=1 ;;
        --upgrade) mode=upgrade ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done
acquire_install_lock
saved_settings
# A failed rollback keeps the last good runtime in $COLIBRI_STATE_DIR; an upgrade
# would snapshot over it and an unchanged run would hide it, so stop until
# someone has looked (see the README).
if (( ! dry_run )) && [[ -e $COLIBRI_STATE_DIR/rollback-failed ]]; then
    die "A rollback failed earlier; the previous runtime is kept in $COLIBRI_STATE_DIR. Inspect or restore it, then delete $COLIBRI_STATE_DIR/rollback-failed and rerun."
fi
# A fresh invocation without a commit or ref uses the tested source. An
# explicit ref, or an explicitly empty commit, keeps branch-based upgrades
# available without silently following an upstream change by default.
COLIBRI_DEFAULT_COMMIT=0a5504a1dc64f86fcd0fe7db298b0448c730e7e6
if [[ ! ${COLIBRI_COMMIT+x} && ! ${COLIBRI_REF+x} ]]; then
    COLIBRI_COMMIT=$COLIBRI_DEFAULT_COMMIT
else
    COLIBRI_COMMIT=${COLIBRI_COMMIT:-}
fi
COLIBRI_REF=${COLIBRI_REF:-main}
# No model is fetched: they are 18 GB-500 GB+. The model directory is created
# empty; the service parks until an operator copies a model into it, and then
# needs only a restart (the launcher, and so the build, does not change).
COLIBRI_MODEL_DIR=${COLIBRI_MODEL_DIR:-$COLIBRI_DATA_DIR/model}
COLIBRI_BACKEND=${COLIBRI_BACKEND:-auto}
COLIBRI_HOST=${COLIBRI_HOST:-0.0.0.0}
COLIBRI_PORT=${COLIBRI_PORT:-8080}
# Colibri's DNS-rebinding guard accepts loopback, the bind address and these
# Host names. Bound to every address, clients (the router included) reach it by
# an address or name the CT cannot know, so * (upstream's own advice for a
# public bind); the API key still guards every request. A record holding the
# wildcard bind address itself (0.0.0.0, which admits no client) gets the same.
case ${COLIBRI_ALLOWED_HOST:-} in
    ''|0.0.0.0|::|'[::]')
        if [[ $COLIBRI_HOST == 0.0.0.0 || $COLIBRI_HOST == :: ]]; then COLIBRI_ALLOWED_HOST='*'
        else COLIBRI_ALLOWED_HOST=$COLIBRI_HOST; fi ;;
esac
COLIBRI_READY_TIMEOUT=${COLIBRI_READY_TIMEOUT:-900}
[[ $COLIBRI_REF =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $COLIBRI_REF != HEAD && $COLIBRI_REF != *..* ]] || die 'Invalid COLIBRI_REF.'
[[ -z $COLIBRI_COMMIT || $COLIBRI_COMMIT =~ ^[0-9a-fA-F]{40}$ ]] || die 'Invalid COLIBRI_COMMIT.'
validate_settings
[[ $COLIBRI_READY_TIMEOUT =~ ^[1-9][0-9]{0,5}$ ]] || die 'Invalid COLIBRI_READY_TIMEOUT.'
for path_var in COLIBRI_DIR COLIBRI_DATA_DIR COLIBRI_ETC_DIR COLIBRI_STATE_DIR UNIT_DIR; do
    [[ ${!path_var} =~ ^/[A-Za-z0-9._/-]+$ && ${!path_var} != *..* ]] || die "Invalid $path_var."
done
[[ $SERVICE_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid SERVICE_USER.'

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -r $source_dir/colibri.service ]] || die "Missing $source_dir/colibri.service"
api_key='[generated inside CT]'
colibri_backend=''
colibri_build_flags=()
run_script=$COLIBRI_DIR/run-colibri.sh
if (( ! dry_run )); then
    [[ $EUID -eq 0 ]] || die 'Run as root inside the Colibri LXC.'
    if [[ -e $COLIBRI_DIR && ! -d $COLIBRI_DIR/.git ]] && [[ -n $(ls -A "$COLIBRI_DIR" 2>/dev/null) ]]; then
        die "$COLIBRI_DIR exists but is not a Git checkout; inspect it before continuing."
    fi
    # A GPU is optional: Colibri is CPU-first and builds for Vulkan or CUDA.
    # No userspace and no device nodes is a supported configuration, so nothing
    # here dies for it; the backend simply resolves to cpu.
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        note 'No nvidia-smi in this CT: Colibri installs on the CPU or Vulkan backend (a CUDA build needs the NVIDIA userspace).'
    elif ! nvidia-smi -L >/dev/null 2>&1; then
        note 'WARNING: nvidia-smi is installed but the GPU is not accessible; Colibri will build and run without it. Check the CT --devN mappings if a GPU was expected.'
    fi
fi

if [[ $mode == upgrade ]]; then
    do_upgrade
else
    do_install
fi
printf 'Colibri is configured on %s:%s; API key: %s/api-key\n' "$COLIBRI_HOST" "$COLIBRI_PORT" "$COLIBRI_ETC_DIR"
