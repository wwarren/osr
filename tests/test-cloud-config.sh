#!/usr/bin/env bash
# Check cloud deployments survive regeneration and credentials stay outside git.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(realpath "${TMPDIR:-/tmp}")"
scratch="$(mktemp -d "${tmp_root}/osr-cloud.XXXXXXXX")"
case "$(realpath "$scratch")" in
  "$tmp_root"/osr-cloud.*) trap 'rm -rf -- "$scratch"' EXIT ;;
  *) echo 'unsafe temporary test path' >&2; exit 1 ;;
esac
mkdir -p "$scratch/repo/env" "$scratch/repo/services/litellm-proxy" \
  "$scratch/repo/services/ollama-router" "$scratch/runtime"
cp "$repo/env/router.env" "$scratch/repo/env/"
cp "$repo/services/litellm-proxy/litellm_config.yaml" "$scratch/repo/services/litellm-proxy/"
cp "$repo/services/ollama-router/router.ini" "$scratch/repo/services/ollama-router/"

export CONFIG_REPO_DIR="$scratch/repo"
export ROUTER_DIR="$scratch/runtime"
export CONFIG_LOCK_FILE="$scratch/config.lock"
manage="$repo/install/manage-model-servers.sh"
yaml="$scratch/repo/services/litellm-proxy/litellm_config.yaml"

bash "$manage" set-cloud-models gemini 'gemini-test-model' >/dev/null
! grep -q 'model_name: gemini/gemini-test-model' "$yaml"
bash "$manage" set-cloud-key gemini 'test-api-key' >/dev/null
grep -q 'model_name: gemini/gemini-test-model' "$yaml"
grep -q 'model: gemini/gemini-test-model' "$yaml"
grep -q 'api_key: os.environ/GEMINI_API_KEY' "$yaml"
grep -q '^GEMINI_API_KEY=test-api-key$' "$scratch/runtime/secrets.env"
! grep -q 'test-api-key' "$scratch/repo/env/router.env"

bash "$manage" set-keepalive 30m --yes >/dev/null
grep -q 'model_name: gemini/gemini-test-model' "$yaml"
bash "$manage" set-cloud-key gemini --off >/dev/null
! grep -q 'model_name: gemini/gemini-test-model' "$yaml"
echo 'cloud config: PASS'
