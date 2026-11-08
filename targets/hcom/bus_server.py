#!/usr/bin/env python3
"""Per-connection OSR bus service (systemd Accept=yes, socket on stdin/stdout).

It runs as the relay account, which alone can read hcom's state and the relay
group key. Agents reach the bus only through this socket: they can send short
handoffs (the sender name is stamped here, from this CT's target) and read
their inbox, but cannot read the key, issue hcom's remote relay RPCs, or start
a stray relay worker. No request runs a shell; hcom gets argument arrays.
"""
import argparse
import json
import os
import pwd
import select
import socket
import struct
import subprocess
import sys

PEERS = ("hermes", "openclaw", "deepseek-harness", "all")
MAX_REQUEST = 16384
MAX_MESSAGE = 2000


def decode_event(event):
    """The OSR envelope inside an hcom message event, or None."""
    if event.get("type") != "message":
        return None
    data = event.get("data", {})
    try:
        message = json.loads(data.get("text", ""))
    except (ValueError, TypeError):
        return None
    if not isinstance(message, dict) or message.get("osr_bus") != 1:
        return None
    if message.get("to") not in PEERS or not isinstance(message.get("message"), str):
        return None
    return {"id": event["id"], "ts": event.get("ts"), "from": data.get("from"),
            "to": message["to"], "message": message["message"]}


def inbox_line(event, target):
    """What one hcom event shows this CT's agent: JSON text, or None to hide it."""
    if event.get("db_reset"):
        return json.dumps({"db_reset": True})
    message = decode_event(event)
    if message is None:
        # Native hcom messages (e.g. a Hermes chat on hcom) stay visible.
        return json.dumps(event) if event.get("type") == "message" else None
    data = event.get("data", {})
    if "_relay" not in data and data.get("from") == "osr-" + target:
        return None  # This CT's own handoff, not new work for it.
    return json.dumps(message) if message["to"] in (target, "all") else None


def validate(request):
    """A checked copy of one request, or ValueError with a short reason."""
    if not isinstance(request, dict):
        raise ValueError("request must be a JSON object")
    op = request.get("op")
    if op == "send":
        to, message = request.get("to"), request.get("message")
        if to not in PEERS:
            raise ValueError("destination must be one of: " + ", ".join(PEERS))
        if not isinstance(message, str) or not 1 <= len(message) <= MAX_MESSAGE:
            raise ValueError(f"messages must contain 1-{MAX_MESSAGE} characters")
        return {"op": op, "to": to, "message": message}
    if op == "inbox":
        last = request.get("last", 100)
        if isinstance(last, bool) or not isinstance(last, int) or not 1 <= last <= 10000:
            raise ValueError("last must be between 1 and 10000")
        return {"op": op, "last": last}
    if op == "follow":
        after = request.get("after_id")
        if after is not None and (isinstance(after, bool) or not isinstance(after, int) or after < 0):
            raise ValueError("after_id must be a non-negative integer")
        return {"op": op, "after_id": after}
    if op == "status":
        return {"op": op}
    raise ValueError("unknown operation")


def hcom_command(request, target, binary):
    if request["op"] == "send":
        payload = json.dumps({"osr_bus": 1, "to": request["to"], "message": request["message"]})
        # `--` makes this a broadcast; @words in the text are not hcom recipients.
        return [binary, "send", "--from", "osr-" + target, "--go", "--intent", "request", "--", payload]
    if request["op"] == "status":
        return [binary, "relay", "status"]
    command = [binary, "events", "--type", "message", "--full"]
    if request["op"] == "inbox":
        return command + ["--last", str(request["last"])]
    command.append("--follow")
    if request["after_id"] is not None:
        command += ["--after-id", str(request["after_id"])]
    return command


def peer_uid(connection):
    credentials = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
    return struct.unpack("3i", credentials)[1]


def read_request(connection, timeout=10):
    data = b""
    while b"\n" not in data:
        if len(data) > MAX_REQUEST or not select.select([connection], [], [], timeout)[0]:
            raise ValueError("request too long or too slow")
        chunk = connection.recv(4096)
        if not chunk:
            break
        data += chunk
    line = data.split(b"\n", 1)[0]
    if len(line) > MAX_REQUEST:
        raise ValueError("request too long")
    return json.loads(line.decode("utf-8"))


def stream(connection, request, target, binary):
    """Run hcom; write JSON lines; stop when the client goes away. Returns hcom's status."""
    command = hcom_command(request, target, binary)
    if request["op"] in ("send", "status"):
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=60)
        text = (result.stdout + result.stderr).strip()
        if text:
            send_line(connection, {"text": text})
        return result.returncode
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as child:
        buffer = b""
        try:
            while True:
                ready = select.select([child.stdout, connection], [], [])[0]
                if connection in ready and not connection.recv(1, socket.MSG_PEEK):
                    return 0  # Client disconnected.
                if child.stdout in ready:
                    chunk = os.read(child.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    buffer += chunk
                    *lines, buffer = buffer.split(b"\n")
                    for raw in lines:
                        if not raw.strip():
                            continue
                        try:
                            line = inbox_line(json.loads(raw), target)
                        except (ValueError, KeyError, TypeError):
                            line = None  # Not hcom JSONL; never forward it raw.
                        if line:
                            connection.sendall(line.encode() + b"\n")
            return child.wait()
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)


def send_line(connection, value):
    connection.sendall(json.dumps(value).encode() + b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=("hermes", "openclaw", "deepseek-harness", "observer"))
    parser.add_argument("--allow-user", help="agent account allowed besides root")
    args = parser.parse_args()
    connection = socket.socket(fileno=sys.stdin.fileno())
    binary = os.environ.get("OSR_HCOM_BINARY", "/usr/local/bin/hcom")
    allowed = {0}
    if args.allow_user:
        allowed.add(pwd.getpwnam(args.allow_user).pw_uid)
    try:
        # Read (bounded) before answering, so a refusal is not lost to a reset
        # from closing with unread data.
        raw = read_request(connection)
        if peer_uid(connection) not in allowed:
            send_line(connection, {"error": "this account may not use the bus", "osr_bus_exit": 77})
            return 77
        request = validate(raw)
        status = stream(connection, request, args.target, binary)
        send_line(connection, {"osr_bus_exit": status})
        return 0
    except (ValueError, UnicodeDecodeError) as error:
        send_line(connection, {"error": str(error), "osr_bus_exit": 2})
        return 0
    except (BrokenPipeError, ConnectionResetError):
        return 0
    except subprocess.TimeoutExpired:
        send_line(connection, {"error": "hcom did not answer in time", "osr_bus_exit": 1})
        return 1


if __name__ == "__main__":
    sys.exit(main())
