#!/usr/bin/env python3
"""Optional upstream smoke test: real hcom, Mosquitto and a local HTTP webhook.

Usage: python3 test-live.py --hcom /path/to/hcom --mosquitto /path/to/mosquitto
       --mosquitto-passwd /path/to/mosquitto_passwd
All state and secrets are temporary. No external webhook or agent is contacted.
Each simulated CT gets its own state and bus socket; connections are served
by bus_server.py one process per connection, as osr-hcom-bus.socket does.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pwd
import socket
import subprocess
import sys
import tempfile
import threading
import time

from bus_config import atomic_write, make_bundle, relay_config

HERE = Path(__file__).resolve().parent


def wait_for(check, description, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    raise RuntimeError("Timed out: " + description)


def check_anonymous_rejected(port):
    client_id = b"osr-anonymous-probe"
    body = b"\x00\x04MQTT\x05\x02\x00\x3c\x00" + len(client_id).to_bytes(2, "big") + client_id
    with socket.create_connection(("127.0.0.1", port), timeout=3) as connection:
        connection.sendall(b"\x10" + bytes([len(body)]) + body)
        response = connection.recv(16)
    assert response[0] == 0x20 and response[3] != 0, "anonymous MQTT connection was accepted"


class BusSocket:
    """systemd's Accept=yes socket for one CT: bus_server.py per connection."""

    def __init__(self, path, target, env, log):
        self.path, self.servers = str(path), []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(8)
        # As the unit passes the agent's account (root is always allowed).
        self.args = [sys.executable, str(HERE / "bus_server.py"), "--target", target,
                     "--allow-user", pwd.getpwuid(os.getuid()).pw_name]
        self.env, self.log = env, log
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            with connection:
                self.servers.append(subprocess.Popen(self.args, stdin=connection, stdout=connection,
                                                     stderr=self.log, env=self.env))

    def close(self):
        self.listener.close()
        for server in self.servers:
            if server.poll() is None:
                server.kill()


def osr_bus(bus, *args, **kwargs):
    env = dict(os.environ, OSR_BUS_SOCKET=bus.path)
    return subprocess.run([sys.executable, str(HERE / "osr_bus.py"), *args], env=env,
                          capture_output=True, text=True, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hcom", required=True)
    parser.add_argument("--mosquitto", required=True)
    parser.add_argument("--mosquitto-passwd", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="osr-bus-live-") as temporary:
        root = Path(temporary)
        with socket.socket() as free:
            free.bind(("127.0.0.1", 0))
            port = free.getsockname()[1]
        bundle = make_bundle(f"mqtt://127.0.0.1:{port}")
        password = root / "password"
        atomic_write(password, "hcom:" + bundle["password"] + "\n")
        subprocess.run([args.mosquitto_passwd, "-U", str(password)], check=True)
        atomic_write(root / "acl", "user hcom\ntopic readwrite " + bundle["relay_id"] + "/#\n")
        atomic_write(root / "mosquitto.conf", f"listener {port} 127.0.0.1\nallow_anonymous false\n"
                     f"password_file {password}\nacl_file {root / 'acl'}\n")
        environments = {}
        for target in ("hermes", "openclaw"):
            state = root / target
            state.mkdir()
            atomic_write(state / "config.toml", relay_config(bundle))
            environments[target] = dict(os.environ, HCOM_DIR=str(state), OSR_HCOM_BINARY=args.hcom, NO_COLOR="1")
        processes, buses = [], {}
        received, attempts = [], []
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                attempts.append(payload)
                if len(attempts) == 1:
                    self.send_response(503)  # Exercise the actual retry path.
                else:
                    received.append(payload)
                    self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")
            def log_message(self, *unused):
                pass
        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server, open(root / "process.log", "w+") as log:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                processes.append(subprocess.Popen([args.mosquitto, "-c", str(root / "mosquitto.conf")], stdout=log, stderr=log))
                time.sleep(0.5)
                check_anonymous_rejected(port)
                for env in environments.values():
                    subprocess.run([args.hcom, "events", "--last", "0"], env=env, check=True, stdout=log, stderr=log)
                # A stray worker hcom started by itself (as an agent's `hcom send`
                # would) must not keep the unit's worker out: ExecStartPre stops it.
                hermes = environments["hermes"]
                subprocess.run([args.hcom, "relay", "daemon", "start"], env=hermes, check=True, stdout=log, stderr=log)
                subprocess.run([args.hcom, "relay", "daemon", "stop"], env=hermes, check=True, stdout=log, stderr=log)
                for target, env in environments.items():
                    processes.append(subprocess.Popen([args.hcom, "relay-worker"], env=env, stdout=log, stderr=log))
                    buses[target] = BusSocket(root / f"{target}.sock", target, env, log)
                time.sleep(1)
                assert all(p.poll() is None for p in processes), "a unit's relay-worker exited"
                def connected():
                    return all("connected" in osr_bus(bus, "status").stdout.lower() for bus in buses.values())
                wait_for(connected, "both real hcom workers connected (status through the bus socket)")
                webhook = root / "webhook"
                atomic_write(webhook, f"http://127.0.0.1:{server.server_port}/hooks/local-test")
                state = root / "cursor.json"
                bridge_args = [sys.executable, str(HERE / "mattermost_bridge.py"), "--state", str(state),
                               "--webhook-file", str(webhook)]
                processes.append(subprocess.Popen(bridge_args, env=environments["openclaw"], stdout=log, stderr=log))
                wait_for(state.exists, "notifier baseline persisted")
                follow_env = dict(os.environ, OSR_BUS_SOCKET=buses["openclaw"].path)
                follower = subprocess.Popen([sys.executable, str(HERE / "osr_bus.py"), "follow"], env=follow_env,
                                            stdout=subprocess.PIPE, text=True)
                expected = ['review "quoted"\n@unknown literal', 'handoff two', 'done three']
                for message in expected:
                    osr_bus(buses["hermes"], "send", "openclaw", message)
                osr_bus(buses["hermes"], "send", "deepseek-harness", "not for openclaw")
                first = json.loads(follower.stdout.readline())
                assert first["message"] == expected[0] and first["from"].startswith("osr-hermes:"), first
                follower.terminate()
                follower.wait(timeout=5)
                wait_for(lambda: len(received) == 4, "four remote handoffs delivered after HTTP retry")
                inbox = osr_bus(buses["openclaw"], "inbox")
                messages = [json.loads(line) for line in inbox.stdout.splitlines()]
                assert [m.get("message") for m in messages] == expected, messages
                assert len(attempts) == 5
                assert all("channel" not in item for item in received)
                own = osr_bus(buses["hermes"], "inbox").stdout
                assert "handoff two" not in own, "a CT's own handoffs must not come back as new work"
                wait_for(lambda: all(s.poll() is not None for s in buses["openclaw"].servers),
                         "follow's bus process ended when its client went away", 10)
                # Replaying from the persisted cursor must not post duplicates.
                bridge = processes.pop()
                bridge.terminate()
                bridge.wait(timeout=5)
                processes.append(subprocess.Popen(bridge_args, env=environments["openclaw"], stdout=log, stderr=log))
                time.sleep(1)
                assert len(received) == 4
                print("PASS real hcom 0.7.31 + authenticated Mosquitto: bus sockets, stamped senders, cross-device "
                      "routing, own-echo filter, follow, quoted messages, HTTP retry, restart cursor, unit owns worker")
            except Exception:
                print("Live test failed; check pinned binary compatibility and local process permissions", file=sys.stderr)
                raise
            finally:
                for bus in buses.values():
                    bus.close()
                for process in reversed(processes):
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    main()
