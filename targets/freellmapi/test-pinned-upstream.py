#!/usr/bin/env python3
"""test-pinned-upstream.py FREELLMAPI_CHECKOUT

Check provision-lxc.sh against FreeLLMAPI's real code at the commit this
target is tested with (upstream-commit.txt). The target runs the published
image unchanged, so what it relies on is the image's layout and a few server
behaviours:

  * the release tag named by DEFAULT_FREELLMAPI_VERSION is the version of the
    checkout, and the image workflow publishes ghcr.io/<owner>/freellmapi with
    that tag and a revision label;
  * the image's entrypoint, command, working directory, account and data
    directory are the ones the provisioner expects (IMAGE_ENTRYPOINT_RE,
    /app, node, /app/server/data);
  * the server reads /app/.env, takes PORT, HOST, PROXY_RATE_LIMIT_RPM,
    FREELLMAPI_UPDATE_CHECK, ENCRYPTION_KEY (64 hex digits) and
    FREEAPI_CONFIG_PATH from it, and creates the first account from the
    config file's "admin" entry;
  * /api/ping answers {"status": "ok"} without a key, /api/auth/status has
    needsSetup, and the unified key is settings.unified_api_key in
    data/freeapi.db, written as freellmapi-<hex>.

With a built checkout (npm ci && npm run build -w server) and node, the
provisioner's own guest scripts are then run against the real server: the env
file and link, the account from the bootstrap file, the health and account
probes, reading the key and using it, and a restart without the bootstrap.

Change upstream-commit.txt and DEFAULT_FREELLMAPI_VERSION only after this
passes against the new release.
"""
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROVISION = (HERE / "provision-lxc.sh").read_text()
passed = 0


def ok(condition, label):
    global passed
    if not condition:
        sys.exit(f"FAIL {label}")
    passed += 1
    print(f"PASS {label}")


def setting(name):
    match = re.search(rf"^{name}=(.*)$", PROVISION, re.M)
    if not match:
        sys.exit(f"provision-lxc.sh has no {name}")
    return match.group(1).strip("'\"")


def guest(name):
    """A guest script of the provisioner: NAME='...' (never a quote inside)."""
    match = re.search(rf"^{name}='(.*?)'$", PROVISION, re.M | re.S)
    if not match:
        sys.exit(f"provision-lxc.sh has no {name}")
    return match.group(1)


def static_checks(src):
    read = lambda rel: (src / rel).read_text()  # noqa: E731
    version = setting("DEFAULT_FREELLMAPI_VERSION")
    head = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"], capture_output=True, text=True)
    pin = (HERE / "upstream-commit.txt").read_text().strip()
    if head.returncode == 0:
        ok(head.stdout.strip() == pin, "the checkout is the commit in upstream-commit.txt")
    package = json.loads(read("desktop/package.json"))["version"]
    ok(f"v{package}" == version, f"DEFAULT_FREELLMAPI_VERSION ({version}) is the checkout's release (v{package})")

    workflow = read(".github/workflows/docker.yml")
    repo = setting("FREELLMAPI_IMAGE_REPO")
    ok(repo == "ghcr.io/tashfeenahmed/freellmapi" and "ghcr.io/${{ github.repository_owner }}/freellmapi" in workflow,
       "the workflow publishes the image the provisioner pulls")
    ok("tags: ['v*.*.*']" in workflow and "type=ref,event=tag" in workflow,
       "a release tag is published as an image tag of the same name")
    ok("docker/metadata-action" in workflow and "labels: ${{ steps.meta.outputs.labels }}" in workflow,
       "the image carries the metadata labels (org.opencontainers.image.revision)")

    dockerfile = read("Dockerfile")
    entry = re.search(r'^ENTRYPOINT \["([^"]+)"\]$', dockerfile, re.M)
    cmd = re.search(r"^CMD \[(.+)\]$", dockerfile, re.M)
    ok(entry and cmd, "the Dockerfile has an exec-form ENTRYPOINT and CMD")
    command = " ".join([entry.group(1)] + json.loads(f"[{cmd.group(1)}]"))
    ok(re.fullmatch(setting("IMAGE_ENTRYPOINT_RE"), command), f"IMAGE_ENTRYPOINT_RE matches the image's '{command}'")
    runtime = dockerfile[dockerfile.index("AS runtime"):]
    ok(re.search(r"^WORKDIR /app$", runtime, re.M) and re.search(r"^USER root$", runtime, re.M),
       "the image works in /app and starts as root (its entrypoint drops to node)")
    ok(re.search(r"^ARG NODE_IMAGE=node:[0-9.]+-bookworm-slim", dockerfile, re.M),
       "the image is Debian with Node (sh, coreutils, tar, setpriv, the node account)")
    entrypoint = read("docker-entrypoint.sh")
    ok("ensure_owned /app/server/data" in entrypoint and "mkdir -p /app/server/data" in dockerfile and
       setting("GUEST_DATA") == "/app/server/data",
       "the data directory is /app/server/data")
    ok("setpriv --reuid=node --regid=node --init-groups" in entrypoint and
       "setpriv --reuid=node --regid=node --init-groups node" in PROVISION,
       "the server runs as node, and the key is read as node the same way")
    ok('[ "$(stat -c %u "$dir" 2>/dev/null)" = "$NODE_UID" ]' in entrypoint,
       "a data directory owned by node is left alone (our root-owned directory in it stays root's)")

    ok("process.env.FREEAPI_ENV_PATH ?? path.resolve(__dirname, '../../.env')" in read("server/src/env.ts"),
       "the server reads /app/.env")
    prepare = guest("GUEST_PREPARE")
    ok('ln -sfn "$env" /app/.env' in prepare, "the provisioner links /app/.env to its env file")
    index = read("server/src/index.ts")
    settings = read("server/src/lib/config.ts")
    ok("process.env.PORT" in settings and "process.env.HOST" in settings, "PORT and HOST are read")
    ok("PROXY_RATE_LIMIT_RPM" in read("server/src/middleware/rateLimit.ts"), "PROXY_RATE_LIMIT_RPM is read")
    ok("FREELLMAPI_UPDATE_CHECK" in read("server/src/routes/update.ts"), "FREELLMAPI_UPDATE_CHECK is read")
    crypto = read("server/src/lib/crypto.ts")
    ok("process.env.ENCRYPTION_KEY" in crypto and re.search(r"KEY_BYTES = 32\b", crypto) and "KEY_HEX_LEN = KEY_BYTES * 2" in crypto,
       "ENCRYPTION_KEY is 64 hex digits")
    config = read("server/src/services/declarative-config.ts")
    ok("FREEAPI_CONFIG_PATH" in config and "admin: adminSchema.optional()" in config and
       "email: z.string().email()" in config and "password: z.string().min(8)" in config,
       "FREEAPI_CONFIG_PATH's admin entry takes an e-mail and a password of 8 or more characters")
    ok(re.search(r"^\s+applyDeclarativeConfigFromEnv\(\);", index, re.M), "the config file is applied at start")

    app = read("server/src/app.ts")
    ok(re.search(r"app\.get\('/api/ping', \(_req, res\) => \{\s*res\.json\(\{ status: 'ok'", app),
       "/api/ping answers status ok without a key")
    ok("needsSetup: userCount() === 0" in read("server/src/routes/auth.ts"), "/api/auth/status has needsSetup")
    db = read("server/src/db/index.ts")
    ok("data/freeapi.db" in db and "WHERE key = 'unified_api_key'" in db and "`freellmapi-${crypto.randomBytes(24).toString('hex')}`" in db,
       "the unified key is settings.unified_api_key in data/freeapi.db, freellmapi-<hex>")
    proxy = read("server/src/routes/proxy.ts")
    ok("req.query.available" in proxy and "owned_by: 'freellmapi'" in proxy,
       "/v1/models takes available=true and marks its own routing entries (the router's listing)")


def run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, timeout=60, **kwargs)


def live_checks(src):
    node = shutil.which("node")
    if not node or not (src / "server/dist/index.js").exists():
        print("NOTE the live checks need node and a built checkout (npm ci && npm run build -w server); not run")
        return
    data, link = src / "server/data", src / ".env"
    if data.exists() or link.exists() or link.is_symlink():
        sys.exit(f"{data} or {link} exists; the live checks need a clean checkout")
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = str(probe.getsockname()[1])
    app = str(src)
    here = lambda text: text.replace("/app/", app + "/")  # noqa: E731
    # The image's accounts do not exist here: ownership steps are skipped.
    shell = lambda text: re.sub(r"^chown (node:node|root:node) ", ": ", here(text), flags=re.M) \
        .replace("id node >/dev/null", ":").replace("install -d -o root -g node -m 0750", "install -d -m 0750")  # noqa: E731
    env = dict(os.environ, NODE_ENV="production", NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
    server = None

    def start():
        log = tempfile.TemporaryFile()
        return subprocess.Popen([node, "server/dist/index.js"], cwd=src, env=env, stdout=log, stderr=log)

    def probe_js(name, *args, stdin=None):
        return run([node, "-e", here(guest(name)), *args], input=stdin, env=env).returncode

    def wait_ping():
        deadline = time.time() + 60
        while time.time() < deadline:
            if server.poll() is not None:
                return False
            if probe_js("GUEST_PING", port) == 0:
                return True
            time.sleep(0.5)
        return False

    try:
        data.mkdir()
        done = run(["sh", "-c", shell(guest("GUEST_PREPARE")), "sh", port, "600", "bootstrap"])
        ok(done.returncode == 0, f"GUEST_PREPARE runs ({done.stderr.strip()})")
        env_file = data / "osr-target/freellmapi.env"
        lines = env_file.read_text().splitlines()
        ok(link.is_symlink() and os.readlink(link) == str(env_file) and
           sum(bool(re.fullmatch(r"ENCRYPTION_KEY=[0-9a-f]{64}", line)) for line in lines) == 1 and
           f"FREEAPI_CONFIG_PATH={data}/osr-target/bootstrap.json" in lines,
           "the env file has one encryption key and names the bootstrap file")
        done = run([node, "-e", guest("GUEST_BOOTSTRAP"), str(data / "osr-target")],
                   input="admin@osr.local\n")
        generated = (data / "osr-target/initial-admin-password").read_text().strip()
        ok(done.returncode == 0 and len(generated) >= 20 and
           json.loads((data / "osr-target/bootstrap.json").read_text()) ==
           {"admin": {"email": "admin@osr.local", "password": generated}},
           "GUEST_BOOTSTRAP writes the account with a generated password")
        ok(probe_js("GUEST_PING", port) != 0, "GUEST_PING fails while nothing listens")
        server = start()
        ok(wait_ping(), "the real server starts from the env file and GUEST_PING sees it")
        ok(probe_js("GUEST_ACCOUNT", port) == 0, "the bootstrap file created the account (GUEST_ACCOUNT)")
        done = run(["sh", "-c", shell(guest("GUEST_BOOTSTRAP_DONE"))])
        ok(done.returncode == 0 and not (data / "osr-target/bootstrap.json").exists() and
           "FREEAPI_CONFIG_PATH" not in env_file.read_text() and "ENCRYPTION_KEY=" in env_file.read_text(),
           "GUEST_BOOTSTRAP_DONE removes the bootstrap file and its line, not the key")
        read_key = run([node, "-e", here(guest("GUEST_KEY")), str(data)], env=env)
        key = read_key.stdout
        ok(read_key.returncode == 0 and re.fullmatch(r"freellmapi-[0-9a-f]{48}", key),
           f"GUEST_KEY reads the unified key from the running server's database ({read_key.stderr.strip()[-200:]})")
        ok(probe_js("GUEST_KEY_WORKS", port, stdin=key + "\n") == 0, "GUEST_KEY_WORKS accepts that key")
        ok(probe_js("GUEST_KEY_WORKS", port, stdin="freellmapi-" + "0" * 48 + "\n") != 0, "and refuses another")
        server.terminate()
        server.wait(timeout=30)
        done = run(["sh", "-c", shell(guest("GUEST_PREPARE")), "sh", port, "0", "keep"])
        after = env_file.read_text().splitlines()
        ok(done.returncode == 0 and "PROXY_RATE_LIMIT_RPM=0" in after and
           [line for line in after if line.startswith("ENCRYPTION_KEY=")] ==
           [line for line in lines if line.startswith("ENCRYPTION_KEY=")],
           "a second GUEST_PREPARE changes settings and keeps the key")
        server = start()
        ok(wait_ping() and probe_js("GUEST_ACCOUNT", port) == 0 and
           run([node, "-e", here(guest("GUEST_KEY")), str(data)], env=env).stdout == key,
           "after a restart without the bootstrap file: healthy, same account and key")
        (data / "osr-target/freellmapi.env").write_text("PORT=1\n")
        (data / "probe.db").touch()
        done = run(["sh", "-c", shell(guest("GUEST_PREPARE")), "sh", port, "600", "keep"])
        ok(done.returncode != 0 and "no ENCRYPTION_KEY" in done.stderr,
           "GUEST_PREPARE refuses to invent a key beside an existing database")
    finally:
        if server and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=30)
            except subprocess.TimeoutExpired:
                server.kill()
        if link.is_symlink():
            link.unlink()
        shutil.rmtree(data, ignore_errors=True)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1]).resolve()
    if not (src / "docker-entrypoint.sh").is_file():
        sys.exit(f"{src} is not a FreeLLMAPI checkout")
    static_checks(src)
    live_checks(src)
    print(f"passed {passed}")


if __name__ == "__main__":
    main()
