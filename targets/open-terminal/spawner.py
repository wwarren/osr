#!/usr/bin/env python3
"""Root helper that creates and starts Open Terminal workspaces.

Listens on a Unix socket that only root and the gateway account may use
(socket mode 0660, group ot-gateway, peer credentials checked). One JSON
request per connection, one JSON reply:

  {"op": "ensure", "id": ID, "client": NAME, "user": USER}
      Create the workspace if needed and start it. Reply: port and key.
  {"op": "stop", "id": ID}      Stop the workspace's service.
  {"op": "list"}                The IDs of running workspaces.

A workspace ID is 16 lowercase hex digits (the gateway hashes the client and
user names). For each one this creates:

  ot-<id>                         Linux account (locked password), home below
  /srv/open-terminal/ws/<id>      its workspace, mode 0700
  /etc/open-terminal/ws/<id>.env  root-only: OPEN_TERMINAL_API_KEY, _PORT
  /var/lib/open-terminal/workspaces/<id>.json   whose workspace it is

and starts open-terminal-ws@<id>.service. An ID already recorded for another
client or user is refused, so two names can never share a workspace.
Standard library only; runs as root under the system python3.
"""

import grp
import json
import os
import pwd
import re
import secrets
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

ID_RE = re.compile(r"[0-9a-f]{16}")
META_ID = "0" * 16
CLIENT_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")
USER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._@:+-]{0,127}")

SOCKET = os.environ.get("OT_SPAWNER_SOCKET", "/run/open-terminal-spawner/spawner.sock")
WS_ROOT = os.environ.get("OT_WS_ROOT", "/srv/open-terminal/ws")
ENV_DIR = os.environ.get("OT_WS_ENV_DIR", "/etc/open-terminal/ws")
RECORD_DIR = os.environ.get("OT_WS_RECORD_DIR", "/var/lib/open-terminal/workspaces")
GATEWAY_USER = os.environ.get("OT_GATEWAY_USER", "ot-gateway")
PORT_MIN = int(os.environ.get("OT_WS_PORT_MIN", "20000"))
PORT_MAX = int(os.environ.get("OT_WS_PORT_MAX", "29999"))
SYSTEMCTL = os.environ.get("OT_SYSTEMCTL", "systemctl")
USERADD = os.environ.get("OT_USERADD", "useradd")
# Tests run unprivileged with stub commands: no accounts, no ownership.
CHOWN_DIRS = os.environ.get("OT_CHOWN", "1") == "1"
UNIT = "open-terminal-ws@{}.service"

lock = threading.Lock()


class RequestError(Exception):
    pass


def account(ws):
    return f"ot-{ws}"


def run(*cmd):
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise RequestError(f"{cmd[0]} {cmd[1] if len(cmd) > 1 else ''} failed: "
                           f"{detail[-1] if detail else result.returncode}")
    return result.stdout


def atomic_write(path, text, mode):
    tmp = f"{path}.tmp.{os.getpid()}.{threading.get_ident()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def read_env(path):
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            name, sep, value = line.rstrip("\n").partition("=")
            if sep and not name.startswith("#"):
                values[name.strip()] = value
    return values


def used_ports():
    ports = set()
    try:
        names = os.listdir(ENV_DIR)
    except FileNotFoundError:
        return ports
    for name in names:
        if name.endswith(".env"):
            try:
                ports.add(int(read_env(os.path.join(ENV_DIR, name)).get("OPEN_TERMINAL_PORT", "0")))
            except (OSError, ValueError):
                continue
    return ports


def port_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def allocate_port():
    taken = used_ports()
    for port in range(PORT_MIN, PORT_MAX + 1):
        if port not in taken and port_free(port):
            return port
    raise RequestError("no free workspace port")


def check_record(ws, client, user):
    path = os.path.join(RECORD_DIR, f"{ws}.json")
    try:
        with open(path, encoding="utf-8") as f:
            record = json.load(f)
    except FileNotFoundError:
        record = {"id": ws, "client": client, "user": user,
                  "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        atomic_write(path, json.dumps(record, sort_keys=True) + "\n", 0o600)
        return
    if record.get("client") != client or record.get("user") != user:
        raise RequestError(f"workspace {ws} already belongs to another client or user")


def lookup(name):
    try:
        return pwd.getpwnam(name)
    except KeyError:
        return None


def ensure_account(ws):
    name = account(ws)
    home = os.path.join(WS_ROOT, ws)
    pw = lookup(name)
    if pw is None:
        run(USERADD, "--home-dir", home, "--no-create-home", "--shell", "/bin/bash",
            "--user-group", "--comment", f"Open Terminal workspace {ws}", name)
        pw = lookup(name)
        if pw is None and CHOWN_DIRS:
            raise RequestError(f"useradd did not create {name}")
    if not os.path.isdir(home):
        os.mkdir(home, 0o700)
        if CHOWN_DIRS:
            os.chown(home, pw.pw_uid, pw.pw_gid)
    if not CHOWN_DIRS:
        return
    st = os.stat(home)
    if st.st_uid != pw.pw_uid or st.st_mode & 0o077:
        # Never hand over a directory someone else owns (for example after an
        # account was deleted and its UID reused); an admin decides.
        raise RequestError(f"{home} is not a private directory of {name}; fix it by hand")


def ensure_env(ws):
    path = os.path.join(ENV_DIR, f"{ws}.env")
    if os.path.exists(path):
        values = read_env(path)
        port, key = values.get("OPEN_TERMINAL_PORT", ""), values.get("OPEN_TERMINAL_API_KEY", "")
        if port.isdigit() and len(key) >= 32:
            return int(port), key
    port, key = allocate_port(), secrets.token_urlsafe(32)
    atomic_write(path, "# Written by the Open Terminal spawner; root-only.\n"
                       f"OPEN_TERMINAL_API_KEY={key}\nOPEN_TERMINAL_PORT={port}\n", 0o600)
    return port, key


def ensure(request):
    ws, client, user = request.get("id"), request.get("client"), request.get("user")
    if not isinstance(ws, str) or not ID_RE.fullmatch(ws):
        raise RequestError("invalid workspace id")
    if ws == META_ID:
        if (client, user) != ("_gateway", "metadata"):
            raise RequestError("invalid metadata workspace request")
    elif not (isinstance(client, str) and CLIENT_RE.fullmatch(client)
              and isinstance(user, str) and USER_RE.fullmatch(user)):
        raise RequestError("invalid client or user")
    with lock:
        check_record(ws, client, user)
        ensure_account(ws)
        port, key = ensure_env(ws)
    run(SYSTEMCTL, "start", UNIT.format(ws))
    return {"ok": True, "port": port, "key": key}


def stop(request):
    ws = request.get("id")
    if not isinstance(ws, str) or not ID_RE.fullmatch(ws):
        raise RequestError("invalid workspace id")
    run(SYSTEMCTL, "stop", UNIT.format(ws))
    return {"ok": True}


def active():
    out = run(SYSTEMCTL, "list-units", "--plain", "--no-legend", "--state=active",
              "open-terminal-ws@*.service")
    found = []
    for line in out.splitlines():
        match = re.match(r"\s*open-terminal-ws@([0-9a-f]{16})\.service\s", line + " ")
        if match:
            found.append(match.group(1))
    return {"ok": True, "active": found}


def allowed_uids():
    uids = {0}
    try:
        uids.add(pwd.getpwnam(GATEWAY_USER).pw_uid)
    except KeyError:
        pass
    return uids


class Handler(socketserver.StreamRequestHandler):
    timeout = 30

    def handle(self):
        creds = self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _, uid, _ = struct.unpack("3i", creds)
        if uid not in allowed_uids():
            self.reply({"ok": False, "error": "not allowed"})
            return
        try:
            line = self.rfile.readline(4096)
            request = json.loads(line)
            if not isinstance(request, dict):
                raise RequestError("invalid request")
            op = request.get("op")
            if op == "ensure":
                reply = ensure(request)
            elif op == "stop":
                reply = stop(request)
            elif op == "list":
                reply = active()
            else:
                raise RequestError("unknown op")
        except (RequestError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
            reply = {"ok": False, "error": str(exc)}
            if not isinstance(exc, RequestError):
                print(f"spawner: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        self.reply(reply)

    def reply(self, data):
        try:
            self.wfile.write(json.dumps(data).encode() + b"\n")
        except OSError:
            pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    for path, mode in ((WS_ROOT, 0o711), (ENV_DIR, 0o700), (RECORD_DIR, 0o700)):
        os.makedirs(path, mode=mode, exist_ok=True)
    directory = os.path.dirname(SOCKET)
    os.makedirs(directory, exist_ok=True)
    try:
        os.unlink(SOCKET)
    except FileNotFoundError:
        pass
    server = Server(SOCKET, Handler)
    try:
        gid = grp.getgrnam(GATEWAY_USER).gr_gid
    except KeyError:
        gid = None
    if gid is not None and os.geteuid() == 0:
        os.chown(directory, 0, gid)
        os.chown(SOCKET, 0, gid)
    os.chmod(directory, 0o750)
    os.chmod(SOCKET, 0o660)
    print(f"spawner: listening on {SOCKET}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
