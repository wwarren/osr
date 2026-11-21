# Applying configuration changes

The config repo is cloned once, at provisioning, so services never need Gitea
to start. To change a running CT:

```bash
cd /app/config-repo && git pull     # local mode: edit /app/config-repo directly
manage-model-servers apply          # or --all to restart every service
```

`apply`:

1. **Validates** the LiteLLM YAML (models, `api_base`, fallbacks), the ini files
   and keyword JSON, the env files, and that `router.py`/`monitor.py` compile;
   on any error nothing changes.
2. **Snapshots** the installed files to `/var/backups/open-smart-router/`
   (root-only; `APPLY_BACKUP_KEEP`, default 5). Snapshots from before the
   rename, in `/var/backups/ollama-smart-router/`, are moved there first.
3. **Applies** the files, brings the LiteLLM venv and any explicitly pinned
   Open WebUI venv in line with their requirements (backing up `webui.db` before
   a WebUI upgrade), and restarts only affected services.
4. **Health-checks** router `/healthz`, LiteLLM `/health/liveliness`, Open
   WebUI `/health` and the monitor; on failure restores the snapshot and
   restarts the old files. Rebuilt venvs are not rolled back, except that a
   failed Open WebUI upgrade reinstalls the previous version and database.

Regenerating the LiteLLM config keeps model tags and hand-edited
`router_settings` (`num_retries: 2`, `timeout: 600`), rebuilds `fallbacks`
from existing tiers (never to an identical tier, and into a Kindi tier only
from a tier on other Kindi servers), keeps operator retry policies for other
tiers and writes Kindi's own for Kindi tiers
([Kindi timeouts](targets/kindi/README.md#timeouts-and-retries)).

**Secrets** (deploy token, webhook, router key, backend tokens, cloud keys)
live only in `/app/router/secrets.env` (`0640 root:osr-router`); `apply` and
`commit` move any found in `env/router.env` there. Commits made before 2026-09
contain the old deploy token: rotate it in Gitea.

**Where settings live.** `env/router.env` says where things are: Gitea and
Mattermost, the model servers and tiers, LiteLLM, cloud model IDs; every key in
it is read by the router, the monitor or `manage-model-servers`. How the
services behave is tuned in `router.ini` and `monitor.ini`. The monitor still
lets an environment variable override its file (`MONITOR_INTERVAL_SECONDS`,
`MONITOR_TIMEOUT_SECONDS`, `MONITOR_HEALTH_PATH`, `MONITOR_FAIL_THRESHOLD`,
`MONITOR_RECOVER_THRESHOLD`, `KEEP_ALIVE_REFRESH_SECONDS`) and logs at start
each one that changes what `monitor.ini` says. `apply` and `commit` remove what
older installers wrote to `router.env` without effect: `LITELLM_HEALTH_URL` and
`MODEL_SERVER_COUNT` (read by nothing), `LITELLM_URL` when it only repeats
`LITELLM_BASE_URL`, and `MONITOR_INTERVAL_SECONDS` or
`KEEP_ALIVE_REFRESH_SECONDS` when they repeat `monitor.ini`; a value that
differs was chosen and is kept.

**Config lock.** `update-router.sh` and every writing command take
`/run/lock/open-smart-router-config.lock`. A second change fails at once
(`CONFIG_LOCK_WAIT=<seconds>` waits). The lock dies with its process. For a
hung holder, `clear-lock --force` confirms, then sends SIGTERM and SIGKILL
after `LOCK_KILL_WAIT` (10) s (`--yes` skips the prompt; without a terminal it
cancels). A change stopped midway can leave the repo or services half-updated.

