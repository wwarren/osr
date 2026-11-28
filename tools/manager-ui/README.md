# Manager UI

A small web front end for [`manage-model-servers`](../../MODEL_SERVERS.md),
served by Node.js 26 from the router CT on HTTP port 80. It has no npm
dependencies: `server.mjs` (HTTP, auth, streaming), `commands.mjs` (the
allowed commands and how their arguments are built) and `public/` (the page).

```bash
pct exec <CT_ID> -- bash /app/config-repo/tools/manager-ui/install.sh
# → Manager UI: http://<ct-ip>/  (user: admin)   Password: … (shown once)
```

The installer downloads the newest Node.js 26 from nodejs.org into
`/opt/node` (checked against the release's `SHASUMS256.txt`), copies the UI to
`/opt/osr-manager-ui`, writes a random password to
`/etc/osr-manager-ui/password` and enables `osr-manager-ui.service`. Re-run it
after a `git pull` to update the UI. `NODE_VERSION=26.x.y` pins a release,
`UI_PORT=8081` changes the port, `--uninstall` removes the unit and the app.

## What it does

The page lists every `manage-model-servers` command as a form: inspect
(`status`, `list`, `models`, `discover`), servers, models, cloud models and
ComfyUI, secrets, alerts, `apply` and `commit`. Output streams into the page
as the script runs, so a long `apply` shows its health checks as they happen.
The page shows the command line it is about to run before you run it.

## Security

* **Root.** `manage-model-servers` is root-only, so the service runs as root.
  It is not under `services/` because the repo tests require those units to
  run as `osr-router` with no capabilities.
* **Authentication.** HTTP Basic, user `admin`, password from
  `/etc/osr-manager-ui/password`. The server refuses to start without a
  password. After 10 failed logins, an address is blocked for 5 minutes.
* **Plain HTTP.** Port 80 has no TLS, so the password and any token you type
  cross the network in clear text. Use it on a trusted LAN only, or put a TLS
  reverse proxy in front.
* **No shell.** Commands run with `spawn(argv)`. Only commands in
  `commands.mjs` run. Tiers and kinds must be on its lists, and no value may
  start with `-` unless the spec allows that value (`--off`, `--generate`,
  `-1`).
* **Secrets.** Tokens and API keys go to the script on stdin, the way its
  "enter, confirm" prompt reads them. They never appear on the command line or
  in the log. Webhook URLs and a custom router API key are not handled this
  way, because the script takes them only as arguments.
* **CSRF.** A browser sends Basic credentials along with requests from any
  site. To block forged requests, `POST /api/run` requires a JSON body and an
  `X-OSR-UI` header, and it refuses a foreign `Origin`. A strict CSP and
  `X-Frame-Options: DENY` are set on every page.
* **One write at a time.** A second writing command gets HTTP 409 while one
  is running. The script's own config lock still applies (`CONFIG_LOCK_WAIT=5`).
* **No interruptions.** Closing the tab does not stop a running command, and
  the unit uses `KillMode=process`, so restarting the UI does not cut off an
  `apply` that is halfway done.

## Development

```bash
node --test tools/manager-ui/manager-ui.test.mjs
# run against a fake script:
UI_PASSWORD=dev PORT=8099 MMS_BIN=/path/to/fake node tools/manager-ui/server.mjs
```
