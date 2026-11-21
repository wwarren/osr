#!/usr/bin/env bash
# install/setup-metrics.sh, run for real against stand-ins for apt-get,
# systemctl, wget, chown, promtool and gpg, writing under a scratch directory
# (OSR_METRICS_ROOT) instead of /. Nothing is installed and no network is used.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lib/assert.sh
source "${HERE}/lib/assert.sh"

script="${ROOT}/install/setup-metrics.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
bin="${tmp}/bin"; calls="${tmp}/calls"; state="${tmp}/state"
mkdir -p "$bin" "$state"
export STUB_CALLS="$calls" STUB_STATE="$state"

cat > "${bin}/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_CALLS"
unit="${*: -1}"
case "$1" in
  is-active) [[ -e "$STUB_STATE/active-$unit" ]] ;;
  is-failed) [[ -e "$STUB_STATE/failed-$unit" ]] ;;
  restart|start) touch "$STUB_STATE/active-$unit" ;;
  stop) rm -f "$STUB_STATE/active-$unit" ;;
  mask) [[ "$2" == --now ]] && rm -f "$STUB_STATE/active-$unit"; true ;;
  *) true ;;
esac
STUB
cat > "${bin}/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$STUB_CALLS"
case " $* " in
  *" prometheus "*) mkdir -p "$OSR_METRICS_ROOT/etc/prometheus" ;;
  *" grafana"*) [[ ! -e "$STUB_STATE/grafana-unavailable" ]] || exit 100
                 [[ ! -s "$OSR_METRICS_ROOT/etc/grafana/osr.env" ]] || echo "password-ready-before-grafana" >> "$STUB_CALLS" ;;
esac
exit 0
STUB
cat > "${bin}/wget" <<'STUB'
#!/usr/bin/env bash
echo "wget $*" >> "$STUB_CALLS"
[[ "$1" == -qO ]] && echo "-----BEGIN PGP PUBLIC KEY BLOCK-----" > "$2"
STUB
cat > "${bin}/gpg" <<'STUB'
#!/usr/bin/env bash
echo "gpg $*" >> "$STUB_CALLS"
printf 'pub:-:4096:1:963FA27710458545:1:::-:::scESC::::::23::0:\nfpr:::::::::%s:\nsub:-:4096:1:AAAA:1::::::e::::::23:\nfpr:::::::::FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:\n' "$(cat "$STUB_STATE/fingerprint")"
STUB
cat > "${bin}/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_CALLS"
case "$*" in
  # The sign-in check: the credentials arrive on stdin (-K -).
  *:3000/api/user) cat > "$STUB_STATE/login-stdin"
                   [[ ! -e "$STUB_STATE/grafana-down" ]] || exit 7
                   cat "$STUB_STATE/login-code" 2>/dev/null || printf 200 ;;
  *:3000/*) [[ ! -e "$STUB_STATE/grafana-silent" ]] ;;
  *) true ;;
esac
STUB
cat > "${bin}/journalctl" <<'STUB'
#!/usr/bin/env bash
echo "journalctl $*" >> "$STUB_CALLS"
echo "logger=server error: the reason it stopped"
STUB
printf '#!/usr/bin/env bash\necho "10.1.2.3 fd00::5"\n' > "${bin}/hostname"
for name in chown promtool sleep; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_CALLS"\n' "$name" > "${bin}/${name}"
done
chmod +x "${bin}"/*

# new_ct KEY: an empty stand-in for the router CT, with that router key.
new_ct() {
  fs="${tmp}/fs.$RANDOM$RANDOM"; router="${fs}/app/router"
  mkdir -p "$router"
  printf 'GITEA_DEPLOY_TOKEN=x\nROUTER_API_KEY=%s\n' "$1" > "${router}/secrets.env"
  : > "${router}/.env"
  rm -f "$state"/*; : > "$calls"
}
run() { OSR_METRICS_ROOT="$fs" ROUTER_DIR="$router" PATH="${bin}:${PATH}" bash "$script" "$@"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || echo missing; }
keyfile() { printf '%s\n' "${fs}/etc/prometheus/osr-router-key"; }

describe install
new_ct "s3cret-key"
out="$(run install 2>&1)"; rc=$?
assert_eq "a first install succeeds" "0" "$rc"
[[ $rc -eq 0 ]] || printf '%s\n' "$out" >&2
assert_contains "Prometheus comes without its recommended packages" \
  "apt-get install -y --no-install-recommends ca-certificates wget prometheus" "$(cat "$calls")"
assert_not_contains "nothing asks for the node exporter" "node-exporter" "$(cat "$calls")"
assert_contains "the package's own Prometheus is masked before it is installed" "systemctl mask prometheus.service" \
  "$(sed -n '1,/apt-get install/p' "$calls")"
assert_eq "the scrape key is the router key" "s3cret-key" "$(cat "$(keyfile)")"
assert_eq "and private" "600" "$(mode_of "$(keyfile)")"
assert_contains "it is handed to prometheus" "chown prometheus:prometheus" "$(cat "$calls")"
config="${fs}/etc/prometheus/osr.yml"
assert_file_contains "the scrape goes to the router on loopback" "targets: ['127.0.0.1:8000']" "$config"
assert_file_contains "with the key file's real path" "credentials_file: /etc/prometheus/osr-router-key" "$config"
assert_contains "the scrape configuration is checked" "promtool check config ${config}" "$(cat "$calls")"
unit="${fs}/etc/systemd/system/osr-prometheus.service"
assert_file_contains "Prometheus listens on loopback only" "--web.listen-address=127.0.0.1:9090" "$unit"
assert_file_contains "with a bounded store" "--storage.tsdb.retention.size=512MB" "$unit"
password_file="${fs}/etc/grafana/osr.env"
password="$(sed -n 's/^GF_SECURITY_ADMIN_PASSWORD=//p' "$password_file")"
assert_ok "Grafana gets a random admin password" bash -c "[[ ${#password} -ge 32 ]]"
assert_eq "kept private" "600" "$(mode_of "$password_file")"
assert_contains "written before Grafana is installed" "password-ready-before-grafana" "$(cat "$calls")"
assert_file_contains "anonymous access is off" "GF_AUTH_ANONYMOUS_ENABLED=false" \
  "${fs}/etc/systemd/system/grafana-server.service.d/osr.conf"
assert_eq "Grafana is the newest release unless pinned" "1" "$(grep -c '^apt-get install -y grafana$' "$calls")"
assert_file_contains "from Grafana's signed repository" "signed-by=/etc/apt/keyrings/grafana.asc" \
  "${fs}/etc/apt/sources.list.d/grafana.list"
assert_not_contains "the key is not inspected unless a fingerprint is given" "gpg " "$(cat "$calls")"
assert_ok "the dashboard is valid JSON on the provisioned data source" python3 -c '
import json, sys
board = json.load(open(sys.argv[1]))
assert board["uid"] == "osr-router" and len(board["panels"]) >= 6
assert all(p["datasource"]["uid"] == "osr-prometheus" for p in board["panels"])' "${fs}/etc/grafana/osr-dashboards/router.json"
assert_file_contains "the data source is the local Prometheus" "url: http://127.0.0.1:9090" \
  "${fs}/etc/grafana/provisioning/datasources/osr.yml"
assert_contains "both services are started" "systemctl restart grafana-server.service" "$(cat "$calls")"
assert_contains "Prometheus too" "systemctl restart osr-prometheus.service" "$(cat "$calls")"
assert_contains "and it says where things are" "ready: Grafana answers on port 3000" "$out"
assert_contains "ready means Grafana answered" "curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:3000/api/health" "$(cat "$calls")"
assert_contains "and Prometheus too" "http://127.0.0.1:9090/-/ready" "$(cat "$calls")"

describe rerun
: > "$calls"
printf 'ROUTER_PORT=8123\nROUTER_HOST=0.0.0.0\n' > "${router}/.env"
out="$(run install 2>&1)"; rc=$?
assert_eq "a second run succeeds" "0" "$rc"
assert_eq "the admin password is kept" "$password" "$(sed -n 's/^GF_SECURITY_ADMIN_PASSWORD=//p' "$password_file")"
assert_file_contains "a changed router port reaches the scrape" "targets: ['127.0.0.1:8123']" "$config"
assert_contains "and the running Prometheus is restarted to use it" "systemctl restart osr-prometheus.service" "$(cat "$calls")"
assert_not_contains "enable --now, which leaves a running service alone, is not relied on" "enable --now osr-prometheus" "$(cat "$calls")"
printf 'ROUTER_HOST=bad host;rm\n' > "${router}/.env"
assert_status "an unusable ROUTER_HOST is refused" 1 run install
printf 'ROUTER_PORT=99999\n' > "${router}/.env"
assert_status "and so is an impossible port" 1 run install
: > "${router}/.env"

describe show_login
new_ct "s3cret-key"
out="$(run install 2>/dev/null)"
password="$(sed -n 's/^GF_SECURITY_ADMIN_PASSWORD=//p' "${fs}/etc/grafana/osr.env")"
assert_contains "an install ends with Grafana's address" "Grafana:  http://10.1.2.3:3000" "$out"
assert_contains "the user name on its own line" "Username: admin" "$out"
assert_contains "and the password, ready to copy" "Password: ${password}" "$out"
: > "$calls"
out="$(run login 2>&1)"; rc=$?
assert_eq "login shows them again" "0|Password: ${password}" "${rc}|$(grep '^Password' <<< "$out")"
assert_not_contains "and changes nothing" "systemctl" "$(cat "$calls")"
assert_not_contains "the password is on no command line" "$password" "$(cat "$calls")"
assert_eq "curl reads it on stdin" "user = \"admin:${password}\"" "$(cat "${state}/login-stdin")"
printf 401 > "${state}/login-code"
out="$(run login 2>&1)"
assert_contains "a password changed in Grafana is said to be changed" "has been changed since setup" "$out"
assert_not_contains "and the old one is not shown" "$password" "$out"
assert_contains "the address still is" "http://10.1.2.3:3000" "$out"
rm -f "${state}/login-code"; touch "${state}/grafana-down"
out="$(run login 2>&1)"
assert_contains "a Grafana that is down still gets its first password" "Password: ${password}" "$out"
assert_contains "marked as unchecked" "not checked" "$out"
rm -f "${state}/grafana-down"
: > "${fs}/etc/grafana/osr.env"
out="$(run login 2>&1)"
assert_contains "a preserved login has no password to show" "kept the login it already had" "$out"
assert_not_contains "so none is" "Password:" "$out"
new_ct "s3cret-key"
assert_eq "a CT without the stack prints nothing" "0|" "$(run login 2>&1; echo "$?|")"
out="$(run nonsense 2>&1)"
assert_contains "the usage names the mode" "install|sync-key|sync-sensors|login" "$out"
# The cases below continue from an installed CT.
run install >/dev/null 2>&1

describe sync_key
: > "$calls"
run sync-key >/dev/null 2>&1
assert_not_contains "an unchanged key restarts nothing" "restart" "$(cat "$calls")"
printf 'ROUTER_API_KEY=rotated\n' > "${router}/secrets.env"
out="$(run sync-key 2>&1)"; rc=$?
assert_eq "a changed key is synced" "0|rotated" "${rc}|$(cat "$(keyfile)")"
assert_eq "still private" "600" "$(mode_of "$(keyfile)")"
assert_contains "and Prometheus restarted" "systemctl restart osr-prometheus.service" "$(cat "$calls")"
assert_contains "it says so" "router scrape key updated" "$out"
assert_eq "no temporary key file is left" "" "$(find "${fs}/etc/prometheus" -name '.osr-router-key.*')"

describe temperature_scrape
config="${fs}/etc/prometheus/osr.yml"
printf '%s\n' sensor-secret > "${fs}/etc/prometheus/osr-sensors-key"
: > "$calls"
out="$(OSR_SENSOR_TARGET=10.1.2.1:9408 run sync-sensors 2>&1)"; rc=$?
assert_eq "sensor scrape is configured" "0" "$rc"
assert_file_contains "sensor job is written" "job_name: osr-temperature" "$config"
assert_file_contains "host target is written" "targets: ['10.1.2.1:9408']" "$config"
assert_file_contains "separate bearer key is used" "credentials_file: /etc/prometheus/osr-sensors-key" "$config"
assert_contains "Prometheus reloads the sensor job" "systemctl restart osr-prometheus.service" "$(cat "$calls")"
assert_status "bad sensor targets are rejected" 1 env OSR_SENSOR_TARGET='bad-host:9408' OSR_METRICS_ROOT="$fs" ROUTER_DIR="$router" PATH="${bin}:${PATH}" bash "$script" sync-sensors
run install >/dev/null 2>&1
assert_file_contains "a normal reinstall retains the sensor job" "job_name: osr-temperature" "$config"
: > "${router}/secrets.env"
run sync-key >/dev/null 2>&1
assert_eq "a key turned off leaves the old one (the router ignores it)" "rotated" "$(cat "$(keyfile)")"
new_ct "s3cret-key"
assert_status "without the stack, sync-key does nothing and succeeds" 0 run sync-key
assert_ok "and creates nothing" bash -c "[[ ! -e '${fs}/etc/prometheus' ]]"

describe router_without_a_key
new_ct ""
out="$(run install 2>&1)"; rc=$?
assert_eq "a router with authentication off can install the stack" "0" "$rc"
assert_ok "with an empty key file for the scrape" bash -c "[[ -f '$(keyfile)' && ! -s '$(keyfile)' ]]"
printf 'ROUTER_API_KEY=set-later\n' > "${router}/secrets.env"
run sync-key >/dev/null 2>&1
assert_eq "a key set later is picked up" "set-later" "$(cat "$(keyfile)")"

describe refusals
new_ct "s3cret-key"
touch "${state}/active-prometheus.service"
out="$(run install 2>&1)"; rc=$?
assert_eq "an existing running Prometheus is left alone" "1" "$rc"
assert_contains "and named" "existing prometheus.service is running" "$out"
assert_not_contains "before anything is installed" "apt-get" "$(cat "$calls")"
new_ct "s3cret-key"
touch "${state}/grafana-unavailable"
assert_status "a failed Grafana install fails the setup" 100 run install
assert_ok "and starts nothing" bash -c "! grep -q 'restart' '$calls'"
# Started, but it never answers: that is not ready, and the log is shown.
new_ct "s3cret-key"
touch "${state}/grafana-silent"
out="$(READY_TIMEOUT=6 run install 2>&1)"; rc=$?
assert_eq "a Grafana that does not answer fails the setup" "1" "$rc"
assert_contains "saying which service and where" "grafana-server.service does not answer on http://127.0.0.1:3000/api/health" "$out"
assert_contains "with the end of its journal" "the reason it stopped" "$out"
assert_not_contains "and it is not called ready" "ready: Grafana answers" "$out"
assert_eq "it was asked more than once before giving up" "2" "$(grep -c ':3000/api/health' "$calls")"
new_ct "s3cret-key"
touch "${state}/grafana-silent" "${state}/failed-grafana-server.service"
out="$(run install 2>&1)"; rc=$?
assert_eq "a unit systemd reports failed is not waited for" "1|0" "${rc}|$(grep -c ':3000/api/health' "$calls")"
new_ct "s3cret-key"
rm -f "${router}/secrets.env"
assert_status "no secrets file is refused" 1 run install
assert_status "an unknown mode is refused" 1 run uninstall
if [[ $EUID -ne 0 ]]; then
  out="$(ROUTER_DIR="$router" PATH="${bin}:${PATH}" bash "$script" install 2>&1)"; rc=$?
  assert_eq "outside a test it must be root" "1|metrics setup: run as root in the router CT" "${rc}|${out}"
fi

describe grafana_pins
new_ct "s3cret-key"
assert_status "a pinned Grafana version installs" 0 env GRAFANA_VERSION=12.2.1 OSR_METRICS_ROOT="$fs" \
  ROUTER_DIR="$router" PATH="${bin}:${PATH}" bash "$script" install
assert_contains "as that exact package version" "apt-get install -y grafana=12.2.1" "$(cat "$calls")"
new_ct "s3cret-key"
assert_status "a version that is not one is refused" 1 env 'GRAFANA_VERSION=1; rm -rf /' OSR_METRICS_ROOT="$fs" \
  ROUTER_DIR="$router" PATH="${bin}:${PATH}" bash "$script" install
assert_not_contains "before anything is installed" "apt-get" "$(cat "$calls")"
new_ct "s3cret-key"
echo "ABCDEF0123456789ABCDEF0123456789ABCDEF01" > "${state}/fingerprint"
out="$(GRAFANA_KEY_FINGERPRINT='abcd ef01 2345 6789 abcd  ef01 2345 6789 abcd ef01' run install 2>&1)"; rc=$?
assert_eq "a signing key with the expected fingerprint is accepted" "0" "$rc"
assert_ok "and installed for apt" test -s "${fs}/etc/apt/keyrings/grafana.asc"
new_ct "s3cret-key"
echo "1111111111111111111111111111111111111111" > "${state}/fingerprint"
out="$(GRAFANA_KEY_FINGERPRINT=ABCDEF0123456789ABCDEF0123456789ABCDEF01 run install 2>&1)"; rc=$?
assert_eq "another key is refused" "1" "$rc"
assert_contains "naming what was found" "found: 1111111111111111111111111111111111111111" "$out"
assert_ok "it is not left for apt" bash -c "[[ -z \$(ls -A '${fs}/etc/apt/keyrings') ]]"
assert_not_contains "and Grafana is not installed" "install -y grafana" "$(cat "$calls")"
assert_status "a fingerprint that is not one is refused" 1 env GRAFANA_KEY_FINGERPRINT=abc OSR_METRICS_ROOT="$fs" \
  ROUTER_DIR="$router" PATH="${bin}:${PATH}" bash "$script" install

summary
