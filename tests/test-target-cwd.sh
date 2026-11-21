#!/usr/bin/env bash
# Agent CLIs must not inherit /root from pct exec before they spawn children.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/target-cwd-test.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/foreign" "$tmp/home/bin" "$tmp/home/state" "$tmp/home/workspace"

check() {  # TARGET FUNCTION EXPECTED_CWD [SCRIPT] [HOME]: HOME stands for each service directory
  local target=$1 function=$2 expected=$3 script=$root/targets/$1/${4:-install-target.sh} home=${5:-$tmp/home}
  (
    # Extract only the wrapper; the rest of each installer needs a CT.
    source <(sed -n "/^${function}() {/,/^}/p" "$script")
    declare -F "$function" >/dev/null
    runuser() { [[ $PWD == "$expected" ]] || { printf 'wrong cwd: %s\n' "$PWD" >&2; return 91; }; }
    OC_USER=openclaw OC_USER_HOME=$home
    HERMES_USER=hermes HERMES_USER_HOME=$home HERMES_HOME=$home/.hermes HERMES_BIN=/bin/true
    SERVICE_USER=deepseek-harness STATE_DIR=$home DSH_HOME_DIR=$home/dsh
    GITEA_SERVICE_USER=gitea GITEA_WORK_DIR=$home GITEA_BIN=/bin/true conf=/tmp/app.ini
    MM_SERVICE_USER=mattermost MM_HOME=$home MMCTL=/bin/true
    service_user=mattermost mmctl=/bin/true
    NVM_DIR=$tmp/home/.nvm
    cd "$tmp/foreign"
    "$function" /bin/true
  ) || { printf 'FAIL %s %s retained the caller cwd\n' "$target" "$function" >&2; exit 1; }
  printf 'PASS %s %s starts in its service directory\n' "$target" "$function"
}

check openclaw run_as_oc "$tmp/home"
check hermes run_hermes "$tmp/home"
check opencode run_as_oc "$tmp/home"
check deepseek-harness as_service "$tmp/home/workspace"
check gitea as_gitea "$tmp/home"
check mattermost mm "$tmp/home"
check mattermost mm "$tmp/home" configure-agent-handoffs.sh
# Where the service directory is missing (Gitea adopted with its paths
# elsewhere, MMCTL set without MM_HOME), they start in /, never in the caller's cwd.
check gitea as_gitea / install-target.sh "$tmp/missing"
check mattermost mm / install-target.sh "$tmp/missing"
check mattermost mm / configure-agent-handoffs.sh "$tmp/missing"

(
  source <(sed -n '/^stop_worker() {/,/^}/p' "$root/targets/hcom/install-target.sh")
  runuser() { [[ $PWD == "$tmp/home" ]] || return 91; }
  stage=$tmp triple=test
  cd "$tmp/foreign"
  stop_worker hermes "$tmp/home" "$tmp/home/state"
) || { echo 'FAIL hcom stop_worker retained the caller cwd' >&2; exit 1; }
echo 'PASS hcom stop_worker starts in the relay home'

(
  source <(sed -n '/^honcho_run() {/,/^}/p' "$root/targets/honcho/install-target.sh")
  as_honcho() { [[ $PWD == "$tmp/home" ]] || return 91; }
  opt=$tmp/home uv=/bin/true etc=$tmp
  cd "$tmp/foreign"
  honcho_run python --version
) || { echo 'FAIL honcho_run retained the caller cwd' >&2; exit 1; }
echo 'PASS honcho_run starts in the checkout'

(
  source <(sed -n '/^as_postgres() {/p' "$root/targets/honcho/install-target.sh")
  declare -F as_postgres >/dev/null
  runuser() { [[ $PWD == / && $1 == -u && $2 == postgres && $3 == -- && $4 == psql ]] || return 91; }
  cd "$tmp/foreign"
  as_postgres psql -Atqc 'SELECT 1'
) || { echo 'FAIL honcho as_postgres retained the caller cwd' >&2; exit 1; }
echo 'PASS honcho runs postgres commands from /'

(
  source <(sed -n '/^update_hermes() {/,/^}/p' "$root/tools/upgrade-all.sh")
  I_CT=(282)
  hermes_recorded_pin() { :; }
  hermes_commit() {
    if [[ -f $tmp/hermes-updated ]]; then printf 'b%.0s' {1..40}
    else printf 'a%.0s' {1..40}; fi
  }
  note() { :; }
  pct() {
    printf '%s\n' "$*" >> "$tmp/hermes-calls"
    case $* in
      *'hermes update --help') echo '--no-gateway-restart' ;;
      *'hermes update --no-gateway-restart') touch "$tmp/hermes-updated" ;;
    esac
  }
  output=$(update_hermes 0)
  [[ $output == *'OSR-HERMES: moved aaaaaaaaaaaa to bbbbbbbbbbbb'* ]]
  grep -Fq 'runuser -u hermes -- env -C /home/hermes HOME=/home/hermes /home/hermes/.local/bin/hermes update --help' "$tmp/hermes-calls"
  grep -Fq 'runuser -u hermes -- env -C /home/hermes HOME=/home/hermes /home/hermes/.local/bin/hermes update --no-gateway-restart' "$tmp/hermes-calls"
) || { echo 'FAIL upgrade-all Hermes update did not enter the service home' >&2; exit 1; }
echo 'PASS upgrade-all updates Hermes from its home'
