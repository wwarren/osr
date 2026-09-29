#!/usr/bin/env bash
# Exercise install-target.sh against a temporary target tree: its helpers in
# isolation, then a fresh install, a legacy migration and --upgrade with rollback.
# apt-get, systemctl, curl, python3 and friends are stubs; nothing is installed
# system-wide, downloaded or started.
set -Eeuo pipefail
exec </dev/null
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/airllm-target-test.XXXXXX")
cleanup() {
    [[ $tmp_root == "${TMPDIR:-/tmp}"/airllm-target-test.* ]] || return
    rm -rf -- "$tmp_root"
}
trap cleanup EXIT
passed=0
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }

# --- helpers in isolation ----------------------------------------------------
# shellcheck disable=SC1090
source <(awk '
    /^# Install helpers/ { capture=1; next }
    /^# End install helpers\./ { capture=0 }
    capture { print }
' "$script_dir/install-target.sh")
for helper in valid_model_id valid_alias valid_device env_value set_env_value ensure_env_key model_billions \
    required_disk_gb free_disk_gb install_server set_aside restore_aside target_url wait_for migrate_legacy; do
    declare -F "$helper" >/dev/null || die "Helper extraction failed: $helper"
done

valid_model_id Qwen/Qwen2.5-72B-Instruct && valid_model_id /srv/models/local || die 'good model ids rejected'
! valid_model_id 'Qwen' && ! valid_model_id 'a/b c' && ! valid_model_id 'a/$(id)' || die 'bad model id accepted'
valid_alias '' && valid_alias qwen2.5:72b || die 'good alias rejected'
! valid_alias 'x y' || die 'bad alias accepted'
valid_device cpu && valid_device cuda && valid_device cuda:1 || die 'good device rejected'
! valid_device gpu && ! valid_device 'cuda:x' || die 'bad device accepted'
pass 'input validation'

[[ $(model_billions Qwen/Qwen2.5-72B-Instruct) == 72 ]] || die "72B parsed as $(model_billions Qwen/Qwen2.5-72B-Instruct)"
[[ $(model_billions meta-llama/Llama-3.1-8B) == 8 ]] || die '8B'
[[ $(model_billions org/Model-1.5B) == 1.5 ]] || die '1.5B'
[[ -z $(model_billions org/NoSize-Instruct) ]] || die 'unknown size parsed'
[[ $(required_disk_gb Qwen/Qwen2.5-72B-Instruct) == 323 ]] || die "72B needs $(required_disk_gb Qwen/Qwen2.5-72B-Instruct)"
[[ $(required_disk_gb org/NoSize) == 0 ]] || die 'unknown size must not block'
[[ $(free_disk_gb "$tmp_root/does/not/exist") =~ ^[0-9]+$ ]] || die 'free_disk_gb on a missing path'
pass 'model size and disk estimate'

f=$tmp_root/env
printf 'A=1\n# A=comment\nB="quoted value"\nA=2\n' > "$f"
[[ $(env_value "$f" A) == 2 && $(env_value "$f" B) == 'quoted value' && -z $(env_value "$f" C) ]] || die 'env_value'
set_env_value "$f" A 'x&y\1/z'
[[ $(grep -c '^A=' "$f") == 1 && $(env_value "$f" A) == 'x&y\1/z' ]] || die "set_env_value: $(cat "$f")"
set_env_value "$f" C new
[[ $(env_value "$f" C) == new ]] || die 'set_env_value append'
ensure_env_key "$f" C other; ensure_env_key "$f" D ''
[[ $(env_value "$f" C) == new && $(grep -c '^D=$' "$f") == 1 ]] || die 'ensure_env_key'
for _ in 1 2 3; do set_env_value "$f" E v; ensure_env_key "$f" E w; done
[[ $(grep -c '^E=' "$f") == 1 ]] || die 're-running duplicated a key'
pass 'env file edits never duplicate a key'

echo old > "$tmp_root/g"; echo older > "$tmp_root/g.prev"
set_aside "$tmp_root/g"; echo new > "$tmp_root/g"
restore_aside "$tmp_root/g"
[[ $(cat "$tmp_root/g") == old && ! -e $tmp_root/g.prev ]] || die 'set_aside / restore_aside'
pass 'set_aside / restore_aside round trip'

# --- whole-script runs --------------------------------------------------------
if (( EUID != 0 )); then
    printf 'SKIP end-to-end cases (install-target.sh needs root; helpers above were tested)\n'
    printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
    exit 0
fi
bin=$tmp_root/bin; mkdir -p "$bin"
log=$tmp_root/calls.log
stub() { printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$log" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub apt-get 'exit 0'
stub getent 'exit 0'
stub groupadd 'exit 0'
stub useradd 'exit 0'
stub sleep 'exit 0'
stub nvidia-smi 'exit 1'
stub systemctl 'case "$1" in is-active) exit "${FAKE_ACTIVE_RC:-0}";; esac; exit 0'
# /healthz and /api/version: 200 when FAKE_HEALTH=ok, 503 otherwise.
stub curl 'if [[ ${FAKE_HEALTH:-ok} == ok ]]; then printf 200; else printf 503; fi'
# python3 -m venv DIR makes a venv whose python accepts pip / py_compile / freeze.
stub python3 'if [[ $1 == -m && $2 == venv ]]; then mkdir -p "$3/bin"; printf "#!/bin/sh\necho \"venv-python \$*\" >> %s\n[ \"\${FAKE_PIP:-ok}\" = ok ]\n" "'"$log"'" > "$3/bin/python"; chmod +x "$3/bin/python"; fi; exit 0'

reset_tree() {
    rm -rf "${tmp_root:?}/opt" "${tmp_root:?}/etc" "${tmp_root:?}/state" "${tmp_root:?}/units" "${tmp_root:?}/legacy"*
    mkdir -p "$tmp_root/units" "$tmp_root/run"
    printf 'ID=debian\nVERSION_ID=12\n' > "$tmp_root/os-release"
    : > "$log"
}
target() {
    env -i "PATH=$bin:/usr/bin:/bin" TARGET_ROOT="$tmp_root/opt" TARGET_ETC="$tmp_root/etc" \
        TARGET_STATE="$tmp_root/state" TARGET_UNITS="$tmp_root/units" TARGET_USER=root \
        LEGACY_ROOT="$tmp_root/legacy" SYSTEMD_RUN_DIR="$tmp_root/run" OS_RELEASE_FILE="$tmp_root/os-release" \
        FAKE_HEALTH="${FAKE_HEALTH:-ok}" FAKE_PIP="${FAKE_PIP:-ok}" FAKE_ACTIVE_RC="${FAKE_ACTIVE_RC:-0}" \
        UPGRADE_HEALTH_TIMEOUT=10 "$@" bash "$script_dir/install-target.sh" ${ARGS:-}
}

reset_tree
out=$(target AIRLLM_MODEL_ID=org/Tiny AIRLLM_MODEL_ALIAS=tiny:1b 2>&1) || die "fresh install failed: $out"
envf=$tmp_root/etc/airllm.env
[[ $(env_value "$envf" AIRLLM_MODEL_ID) == org/Tiny && $(env_value "$envf" AIRLLM_MODEL_ALIAS) == tiny:1b ]] || die 'model not written'
[[ $(env_value "$envf" AIRLLM_DEVICE) == cpu ]] || die 'no GPU must mean cpu'
[[ $(env_value "$envf" HF_HOME) == "$tmp_root/state/hf-cache" ]] || die 'HF_HOME not under the state dir'
[[ $(grep -c '^AIRLLM_DEVICE=' "$envf") == 1 ]] || die 'duplicate AIRLLM_DEVICE'
[[ $(stat -c %a "$envf") == 640 ]] || die 'env file must be 0640'
cmp -s "$script_dir/server.py" "$tmp_root/opt/server.py" || die 'server.py not installed'
cmp -s "$script_dir/airllm-ollama-api.service" "$tmp_root/units/airllm-ollama-api.service" || die 'unit not installed'
grep -q -- '--require-hashes' "$log" || die 'pip did not use the hash lock'
grep -q 'systemctl restart airllm-ollama-api.service' "$log" || die 'service not started'
[[ $out == *'"model":"tiny:1b"'* ]] || die 'smoke test does not use the served model name'
pass 'fresh install: hash-locked venv, settings, unit, start, a smoke test that works'

out=$(target AIRLLM_MODEL_ID=org/Tiny 2>&1) && die 'a second install succeeded'
[[ $out == *'--upgrade'* ]] || die 'second install did not point at --upgrade'
pass 'fresh install refuses an installed target'

reset_tree
out=$(target 2>&1) && die 'a 72B install on a small disk succeeded'
[[ $out == *'needs about 323 GB'* ]] || die "disk refusal unclear: $out"
[[ ! -e $tmp_root/opt/venv ]] || die 'disk refusal happened after installing'
pass 'fresh install refuses a disk too small for the model'

reset_tree
stub nvidia-smi 'exit 0'
out=$(target AIRLLM_MODEL_ID=org/Tiny START_SERVICE=false 2>&1) || die "GPU install failed: $out"
[[ $(env_value "$tmp_root/etc/airllm.env" AIRLLM_DEVICE) == cuda:0 ]] || die 'GPU not picked up'
! grep -q 'systemctl restart' "$log" || die 'START_SERVICE=false started the service'
stub nvidia-smi 'exit 1'
pass 'GPU hosts default to cuda:0; START_SERVICE=false leaves it stopped'

reset_tree
mkdir -p "$tmp_root/legacy/hf-cache/hub" "$tmp_root/legacy/shards/layer0"
printf 'AIRLLM_MODEL_ID=org/Old-3B\nHF_TOKEN=hf_secret\nAIRLLM_DEVICE=cpu\nHF_HOME=%s/legacy/hf-cache\n' "$tmp_root" > "$tmp_root/legacy/.env"
echo 'legacy unit' > "$tmp_root/units/airllm-ollama-api.service"
out=$(target 2>&1) && die 'install over a legacy tree succeeded without MIGRATE_LEGACY'
[[ $out == *MIGRATE_LEGACY=true* ]] || die 'legacy refusal unclear'
out=$(target MIGRATE_LEGACY=true 2>&1) || die "migration failed: $out"
envf=$tmp_root/etc/airllm.env
[[ $(env_value "$envf" AIRLLM_MODEL_ID) == org/Old-3B && $(env_value "$envf" HF_TOKEN) == hf_secret ]] || die 'settings not migrated'
[[ $(env_value "$envf" HF_HOME) == "$tmp_root/state/hf-cache" ]] || die 'HF_HOME must point at the new state dir'
[[ -d $tmp_root/state/hf-cache/hub && -d $tmp_root/state/shards/layer0 ]] || die 'weights/shards not moved'
[[ -d $tmp_root/legacy.legacy && ! -e $tmp_root/legacy ]] || die 'legacy tree not kept aside'
grep -q 'systemctl disable --now airllm-ollama-api.service' "$log" || die 'legacy service not stopped'
cmp -s "$script_dir/airllm-ollama-api.service" "$tmp_root/units/airllm-ollama-api.service" || die 'legacy unit not replaced'
pass 'legacy migration: settings, weights and shards carried over, nothing re-downloaded'

# --upgrade
make_install() {
    reset_tree
    mkdir -p "$tmp_root/opt/venv/bin" "$tmp_root/etc" "$tmp_root/state"
    printf '#!/bin/sh\nexit 0\n' > "$tmp_root/opt/venv/bin/python"; chmod +x "$tmp_root/opt/venv/bin/python"
    echo 'old venv' > "$tmp_root/opt/venv/marker"
    echo 'old server' > "$tmp_root/opt/server.py"
    printf 'AIRLLM_MODEL_ID=org/Keep-7B\nAIRLLM_PORT=11434\n' > "$tmp_root/etc/airllm.env"
    echo 'old unit' > "$tmp_root/units/airllm-ollama-api.service"
}
upgrade() { ARGS=--upgrade target "$@"; }

make_install
out=$(upgrade 2>&1) || die "healthy upgrade failed: $out"
cmp -s "$script_dir/server.py" "$tmp_root/opt/server.py" || die 'server.py not refreshed'
[[ $(cat "$tmp_root/opt/server.py.prev") == 'old server' ]] || die 'old server.py not kept'
cmp -s "$script_dir/airllm-ollama-api.service" "$tmp_root/units/airllm-ollama-api.service" || die 'unit not refreshed'
[[ $(env_value "$tmp_root/etc/airllm.env" AIRLLM_MODEL_ID) == org/Keep-7B ]] || die 'settings touched'
grep -q '^AIRLLM_EXIT_ON_LOAD_FAILURE=true$' "$tmp_root/etc/airllm.env" || die 'new setting not added'
grep -q 'systemctl restart airllm-ollama-api.service' "$log" || die 'not restarted'
pass 'healthy upgrade: refreshes code, venv and unit, keeps settings, restarts'

make_install
out=$(FAKE_HEALTH=down upgrade 2>&1) && die 'upgrade interrupted a loading target'
[[ $out == *ALLOW_INTERRUPT* && $(cat "$tmp_root/opt/server.py") == 'old server' ]] || die 'loading target was touched'
pass 'upgrade refuses to interrupt a download unless ALLOW_INTERRUPT=true'

make_install
FAKE_HEALTH=down upgrade ALLOW_INTERRUPT=true >/dev/null 2>&1 && die 'an unhealthy upgrade reported success'
[[ $(cat "$tmp_root/opt/server.py") == 'old server' && -f $tmp_root/opt/venv/marker ]] || die 'code/venv not rolled back'
[[ $(cat "$tmp_root/units/airllm-ollama-api.service") == 'old unit' ]] || die 'unit not rolled back'
[[ ! -e $tmp_root/opt/server.py.prev ]] || die 'rollback left a .prev behind'
pass 'unhealthy upgrade: everything is rolled back'

make_install
echo 'stale' > "$tmp_root/units/airllm-ollama-api.service.prev"
FAKE_PIP=fail upgrade >/dev/null 2>&1 && die 'a failed pip install reported success'
[[ $(cat "$tmp_root/units/airllm-ollama-api.service") == 'old unit' ]] || die 'a stale .prev was restored'
[[ $(cat "$tmp_root/opt/server.py") == 'old server' ]] || die 'failed pip changed the install'
pass 'rollback restores only what this run replaced'

make_install
FAKE_ACTIVE_RC=3 upgrade >/dev/null 2>&1 || die 'upgrade of a stopped service failed'
! grep -q 'systemctl restart' "$log" || die 'a stopped service was started'
pass 'a stopped service stays stopped'

reset_tree
upgrade >/dev/null 2>&1 && die 'upgrade without an installation succeeded'
pass 'upgrade refuses a target that is not installed'

printf '%s install cases passed. No system files, packages or services were touched.\n' "$passed"
