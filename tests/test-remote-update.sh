#!/usr/bin/env bash
# Update launcher: mock pct and service tools, but inspect a real host tarball.
set -Eeuo pipefail
exec </dev/null

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
tool=$root/tools/update-router-services.sh
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/elsewhere"

cat > "$tmp/bin/pct" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
case $1 in
    list)
        printf 'VMID Status Lock Name\n280 running - router\n281 running - other\n'
        ;;
    status)
        printf 'status: %s\n' "${MOCK_STATUS:-running}"
        ;;
    exec)
        id=$2; shift 3
        case $1 in
            test)
                [[ " $MOCK_ROUTER_IDS " == *" $id "* ]] || exit 1
                ;;
            systemctl)
                [[ " $MOCK_ROUTER_IDS " == *" $id "* ]] || exit 1
                service=${6%.service}
                case $4 in
                    FragmentPath) printf '/etc/systemd/system/%s.service\n' "$service" ;;
                    WorkingDirectory)
                        if [[ $service == open-webui ]]; then
                            printf '%s\n' "${MOCK_WEBUI_DIR:-/app/openwebui}"
                        else
                            printf '%s\n' "${MOCK_ROUTER_DIR:-/app/router}"
                        fi
                        ;;
                esac
                ;;
            find)
                printf '%s\n' "${MOCK_RUNTIME_FILES:-router.py}" monitor.py litellm_config.yaml
                ;;
            readlink)
                [[ ${MOCK_MANAGER_LINK:-present} == present ]] || exit 1
                printf '/app/config-repo/install/manage-model-servers.sh\n'
                ;;
            sh)
                printf '/app/config-repo/install/manage-model-servers.sh\n'
                ;;
            mktemp)
                printf '%s\n' "${MOCK_STAGE_PATH:-/root/osr-update.ABCDEFGH}"
                ;;
            env)
                exit "${MOCK_UPDATE_EXIT:-0}"
                ;;
        esac
        ;;
    push)
        cp -- "$3" "$MOCK_ARCHIVE"
        ;;
esac
MOCK
chmod +x "$tmp/bin/pct"
cat > "$tmp/bin/id" <<'MOCK'
#!/bin/sh
if [ "$1" = -u ]; then printf '0\n'; else /usr/bin/id "$@"; fi
MOCK
chmod +x "$tmp/bin/id"

export MOCK_LOG="$tmp/calls" MOCK_ARCHIVE="$tmp/source.tar.gz"
export MOCK_ROUTER_IDS=280
real_bash=$(command -v bash)
export PATH="$tmp/bin:$PATH"
pass=0
check() { "$@" || { printf 'FAIL: %s\n' "$*" >&2; exit 1; }; pass=$((pass + 1)); }
contains() { grep -Fq -- "$1" "$2"; }
lacks() { ! grep -Fq -- "$1" "$2"; }

: > "$MOCK_LOG"
output=$(cd "$tmp/elsewhere" && CT_ID=280 bash "$tool" --host --dry-run --diff 2>&1)
check contains 'Found CT 280 installation: config /app/config-repo, runtime /app/router, units /etc/systemd/system' <(printf '%s\n' "$output")
check contains 'Updating router CT 280 from ' <(printf '%s\n' "$output")
check contains 'exec 280 -- find /app/router -maxdepth 1' "$MOCK_LOG"
check contains 'exec 280 -- env CONFIG_REPO_DIR=/app/config-repo ROUTER_DIR=/app/router bash /root/osr-update.ABCDEFGH/install/update-router.sh --dry-run --diff' "$MOCK_LOG"
check contains 'exec 280 -- rm -rf -- /root/osr-update.ABCDEFGH' "$MOCK_LOG"
tar -tzf "$MOCK_ARCHIVE" > "$tmp/manifest"
check contains 'ollama-smart-router-install.sh' "$tmp/manifest"
check contains 'install/update-router.sh' "$tmp/manifest"
check contains 'services/ollama-router/router.py' "$tmp/manifest"
check lacks 'env/router.env' "$tmp/manifest"
check lacks 'litellm_config.yaml' "$tmp/manifest"
check lacks 'router.ini' "$tmp/manifest"

: > "$MOCK_LOG"
output=$(cd "$tmp/elsewhere" && printf '1\n280\n' | bash "$tool" --with-tunables --no-push 2>&1)
check contains 'Where is this script running?' <(printf '%s\n' "$output")
check contains 'Router CT_ID:' <(printf '%s\n' "$output")
check contains 'list' "$MOCK_LOG"
check contains 'Updating router CT 280 from ' <(printf '%s\n' "$output")
check contains 'exec 280 -- env CONFIG_REPO_DIR=/app/config-repo ROUTER_DIR=/app/router bash /root/osr-update.ABCDEFGH/install/update-router.sh --with-tunables --no-push' "$MOCK_LOG"
tar -tzf "$MOCK_ARCHIVE" > "$tmp/manifest"
check contains 'services/ollama-router/router.ini' "$tmp/manifest"
check contains 'services/ollama-monitor/monitor.ini' "$tmp/manifest"

: > "$MOCK_LOG"
output=$(CT_ID=280 MOCK_MANAGER_LINK=missing bash "$tool" --host --dry-run 2>&1)
check contains 'Found CT 280 installation:' <(printf '%s\n' "$output")
check contains 'exec 280 -- sh -c for base in /app /opt /srv /root' "$MOCK_LOG"

: > "$MOCK_LOG"
if printf '1\nabc\n' | bash "$tool" --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: invalid prompted CT ID was accepted\n' >&2; exit 1
fi
check contains 'CT_ID must be a numeric Proxmox CT ID' "$tmp/output"
check lacks 'exec ' "$MOCK_LOG"

: > "$MOCK_LOG"
if CT_ID=281 bash "$tool" --host --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: non-router CT was accepted\n' >&2; exit 1
fi
check contains 'Cannot inspect litellm-proxy.service in CT 281' "$tmp/output"
check lacks 'push ' "$MOCK_LOG"

: > "$MOCK_LOG"
if CT_ID=280 MOCK_RUNTIME_FILES=wrong.py bash "$tool" --host --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: missing runtime code was accepted\n' >&2; exit 1
fi
check contains 'missing /app/router/router.py' "$tmp/output"
check lacks 'push ' "$MOCK_LOG"

: > "$MOCK_LOG"
if CT_ID=280 MOCK_ROUTER_DIR=/custom/router bash "$tool" --host --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: nonstandard service paths were accepted\n' >&2; exit 1
fi
check contains 'nonstandard runtime paths' "$tmp/output"
check lacks 'push ' "$MOCK_LOG"

: > "$MOCK_LOG"
if CT_ID=280 MOCK_UPDATE_EXIT=19 bash "$tool" --host --no-push > "$tmp/output" 2>&1; then
    printf 'FAIL: updater failure was hidden\n' >&2; exit 1
fi
check contains 'exec 280 -- rm -rf -- /root/osr-update.ABCDEFGH' "$MOCK_LOG"

: > "$MOCK_LOG"
if CT_ID=280 MOCK_STAGE_PATH=/etc bash "$tool" --host --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: unsafe CT staging path was accepted\n' >&2; exit 1
fi
check contains 'Unexpected CT staging path: /etc' "$tmp/output"
check lacks 'rm -rf -- /etc' "$MOCK_LOG"

# In-container mode scans local service files, then invokes the updater from
# this clone. Its commands are mocked so this suite can run outside a CT.
cat > "$tmp/bin/systemctl" <<'MOCK'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
service=${5%.service}
case $3 in
    FragmentPath) printf '/etc/systemd/system/%s.service\n' "$service" ;;
    WorkingDirectory)
        if [ "$service" = open-webui ]; then printf '/app/openwebui\n'
        else printf '/app/router\n'; fi ;;
esac
MOCK
cat > "$tmp/bin/find" <<'MOCK'
#!/bin/sh
printf 'find %s\n' "$*" >> "$MOCK_LOG"
printf 'router.py\nmonitor.py\nlitellm_config.yaml\n'
MOCK
cat > "$tmp/bin/readlink" <<'MOCK'
#!/bin/sh
printf 'readlink %s\n' "$*" >> "$MOCK_LOG"
printf '/app/config-repo/install/manage-model-servers.sh\n'
MOCK
cat > "$tmp/bin/test" <<'MOCK'
#!/bin/sh
printf 'test %s\n' "$*" >> "$MOCK_LOG"
exit 0
MOCK
cat > "$tmp/bin/bash" <<'MOCK'
#!/bin/sh
printf 'container-updater: repo=%s runtime=%s args=%s\n' \
    "$CONFIG_REPO_DIR" "$ROUTER_DIR" "$*" >> "$MOCK_LOG"
exit "${MOCK_UPDATE_EXIT:-0}"
MOCK
chmod +x "$tmp/bin/systemctl" "$tmp/bin/find" "$tmp/bin/readlink" "$tmp/bin/test" "$tmp/bin/bash"

: > "$MOCK_LOG"
output=$(cd "$tmp/elsewhere" && "$real_bash" "$tool" --container --dry-run --diff 2>&1)
check contains 'Found this container installation: config /app/config-repo, runtime /app/router, units /etc/systemd/system' <(printf '%s\n' "$output")
check contains 'Updating this router container from ' <(printf '%s\n' "$output")
check contains 'systemctl show -p FragmentPath --value litellm-proxy.service' "$MOCK_LOG"
check contains 'find /app/router -maxdepth 1' "$MOCK_LOG"
check contains "container-updater: repo=/app/config-repo runtime=/app/router args=$root/install/update-router.sh --dry-run --diff $root" "$MOCK_LOG"
check lacks 'exec 280' "$MOCK_LOG"

: > "$MOCK_LOG"
output=$(cd "$tmp/elsewhere" && printf '2\n' | "$real_bash" "$tool" --no-push 2>&1)
check contains 'Where is this script running?' <(printf '%s\n' "$output")
check contains "container-updater: repo=/app/config-repo runtime=/app/router args=$root/install/update-router.sh --no-push $root" "$MOCK_LOG"
check lacks 'Router CT_ID:' <(printf '%s\n' "$output")

: > "$MOCK_LOG"
if MOCK_UPDATE_EXIT=19 "$real_bash" "$tool" --container --no-push > "$tmp/output" 2>&1; then
    printf 'FAIL: container updater failure was hidden\n' >&2; exit 1
fi
check contains 'container-updater: repo=/app/config-repo runtime=/app/router' "$MOCK_LOG"

: > "$MOCK_LOG"
if printf '3\n' | "$real_bash" "$tool" > "$tmp/output" 2>&1; then
    printf 'FAIL: invalid location was accepted\n' >&2; exit 1
fi
check contains 'Choose 1 for Proxmox host or 2 for inside the container.' "$tmp/output"
check lacks 'systemctl ' "$MOCK_LOG"

if "$real_bash" "$tool" --host --container > "$tmp/output" 2>&1; then
    printf 'FAIL: conflicting locations were accepted\n' >&2; exit 1
fi
check contains 'Choose only one of --host or --container.' "$tmp/output"

# --- source checks, ownership, and the clone-vs-deployed-repo distinction -----
# Host mode again (pct mocked); restore the real tools the container cases hid.
rm -f "$tmp/bin/bash" "$tmp/bin/test" "$tmp/bin/find" "$tmp/bin/readlink" "$tmp/bin/systemctl"

: > "$MOCK_LOG"
output=$(CT_ID=280 "$real_bash" "$tool" --host --dry-run 2>&1)
tar --numeric-owner -tvzf "$MOCK_ARCHIVE" | awk '{print $2}' | sort -u > "$tmp/owners"
check contains '0/0' "$tmp/owners"
check test "$(wc -l < "$tmp/owners")" -eq 1
check contains 'exec 280 -- tar --no-same-owner -xzf' "$MOCK_LOG"

printf '#!/bin/sh\necho 1000\n' > "$tmp/bin/id"; chmod +x "$tmp/bin/id"
: > "$MOCK_LOG"
if CT_ID=280 "$real_bash" "$tool" --host --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: non-root run was accepted\n' >&2; exit 1
fi
check contains 'Run as root' "$tmp/output"
check lacks 'exec ' "$MOCK_LOG"
printf '#!/bin/sh\nif [ "$1" = -u ]; then echo 0; else /usr/bin/id "$@"; fi\n' > "$tmp/bin/id"
chmod +x "$tmp/bin/id"

# A clone with a CRLF file is refused before any CT is touched.
clone=$tmp/clone
mkdir -p "$clone"
(cd "$root" && tar -cf - tools install services ollama-smart-router-install.sh) | tar -xf - -C "$clone"
printf 'x = 1\r\n' >> "$clone/services/ollama-router/router.py"
: > "$MOCK_LOG"
if CT_ID=280 "$real_bash" "$clone/tools/update-router-services.sh" --host --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: CRLF source was accepted\n' >&2; exit 1
fi
check contains 'services/ollama-router/router.py' "$tmp/output"
check contains 'CRLF' "$tmp/output"
check lacks 'exec ' "$MOCK_LOG"

# Container mode, no manage-model-servers link: the search also finds the clone
# this script runs from (it lives under /root). It must be skipped, not
# reported as a second config repository.
cat > "$tmp/bin/systemctl" <<'MOCK'
#!/bin/sh
service=${5%.service}
case $3 in
    FragmentPath) printf '/etc/systemd/system/%s.service\n' "$service" ;;
    WorkingDirectory)
        if [ "$service" = open-webui ]; then printf '/app/openwebui\n'
        else printf '/app/router\n'; fi ;;
esac
MOCK
cat > "$tmp/bin/find" <<MOCK
#!/bin/sh
case "\$*" in
    *manage-model-servers.sh*)
        # Answer once (for /root, which exists everywhere), as the real scan
        # of /app and /root would.
        if [ "\$1" = /root ]; then
            printf '%s\n' /app/config-repo/install/manage-model-servers.sh \
                "$clone/install/manage-model-servers.sh"
        fi ;;
    *) printf 'router.py\nmonitor.py\nlitellm_config.yaml\n' ;;
esac
MOCK
cat > "$tmp/bin/sh" <<MOCK
#!/bin/sh
printf '%s\n' /app/config-repo/install/manage-model-servers.sh \
    "$clone/install/manage-model-servers.sh"
MOCK
cat > "$tmp/bin/readlink" <<'MOCK'
#!/bin/sh
[ -n "$MOCK_LINK_TARGET" ] || exit 1
printf '%s\n' "$MOCK_LINK_TARGET"
MOCK
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/test"
cat > "$tmp/bin/bash" <<'MOCK'
#!/bin/sh
printf 'container-updater: repo=%s args=%s\n' "$CONFIG_REPO_DIR" "$*" >> "$MOCK_LOG"
MOCK
chmod +x "$tmp/bin/systemctl" "$tmp/bin/find" "$tmp/bin/sh" "$tmp/bin/readlink" "$tmp/bin/test" "$tmp/bin/bash"
sed -i 's/\r$//' "$clone/services/ollama-router/router.py"

: > "$MOCK_LOG"
output=$("$real_bash" "$clone/tools/update-router-services.sh" --container --dry-run 2>&1)
check contains 'Found this container installation: config /app/config-repo' <(printf '%s\n' "$output")
check contains 'container-updater: repo=/app/config-repo' "$MOCK_LOG"

: > "$MOCK_LOG"
if MOCK_LINK_TARGET="$clone/install/manage-model-servers.sh" \
        "$real_bash" "$clone/tools/update-router-services.sh" --container --dry-run > "$tmp/output" 2>&1; then
    printf 'FAIL: running from the deployed config repository was accepted\n' >&2; exit 1
fi
check contains 'runs from the deployed config repository' "$tmp/output"
check lacks 'container-updater' "$MOCK_LOG"

printf '%s update wrapper checks passed; pct and container commands were mocked.\n' "$pass"
