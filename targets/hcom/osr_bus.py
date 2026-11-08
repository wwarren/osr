#!/usr/bin/env python3
"""osr-bus: the agent side of the OSR bus. It talks only to the local bus socket.

Agents never read hcom's state or the relay group key; the socket service,
running as the relay account, does the hcom work (see bus_server.py).
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import sys

PEERS = ("hermes", "openclaw", "deepseek-harness", "all")
SOCKET = "/run/osr-hcom/bus.sock"
SETTINGS = "/etc/osr-hcom/bus.json"


def request_for(args):
    if args.command == "send":
        return {"op": "send", "to": args.to, "message": args.message}
    if args.command == "inbox":
        return {"op": "inbox", "last": args.last}
    if args.command == "follow":
        return {"op": "follow", "after_id": args.after_id}
    return {"op": "status"}


def run(request, path):
    """Send one request and print the answer. Returns the exit status."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        try:
            connection.connect(path)
        except PermissionError:
            print("osr-bus: this account may not use the bus (only root and this CT's agent)", file=sys.stderr)
            return 77
        except OSError as error:
            print(f"osr-bus: cannot reach the bus at {path} ({error.strerror}); "
                  "is osr-hcom-bus.socket running?", file=sys.stderr)
            return 69
        connection.sendall(json.dumps(request).encode() + b"\n")
        with connection.makefile("r", encoding="utf-8") as answers:
            for line in answers:
                try:
                    value = json.loads(line)
                except ValueError:
                    continue
                if isinstance(value, dict) and "osr_bus_exit" in value:
                    if "error" in value:
                        print("osr-bus: " + value["error"], file=sys.stderr)
                    return int(value["osr_bus_exit"])
                if isinstance(value, dict) and set(value) == {"text"}:
                    print(value["text"], flush=True)
                else:
                    print(line.rstrip("\n"), flush=True)
    print("osr-bus: the bus closed the connection early", file=sys.stderr)
    return 1


def tui():
    """hcom's dashboard for root, run as the relay account."""
    if os.geteuid() != 0:
        print("osr-bus tui: run as root; agents use send/inbox/follow", file=sys.stderr)
        return 77
    settings = json.loads(Path(SETTINGS).read_text())
    os.execvp("runuser", ["runuser", "-u", settings["relay_user"], "--", "env",
                          "HOME=" + settings["relay_home"], "HCOM_DIR=" + settings["state"],
                          "/usr/local/bin/hcom"])


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    send = sub.add_parser("send", help="send a short handoff")
    send.add_argument("to", choices=PEERS)
    send.add_argument("message")
    inbox = sub.add_parser("inbox", help="recent messages for this agent")
    inbox.add_argument("--last", type=int, default=100)
    follow = sub.add_parser("follow", help="stream new messages")
    follow.add_argument("--after-id", type=int)
    sub.add_parser("status", help="relay connection status")
    sub.add_parser("tui", help="hcom dashboard (root only)")
    args = parser.parse_args()
    if args.command == "tui":
        return tui()
    if args.command == "send" and not 1 <= len(args.message) <= 2000:
        parser.error("messages must contain 1-2000 characters")
    if args.command == "inbox" and not 1 <= args.last <= 10000:
        parser.error("--last must be between 1 and 10000")
    try:
        return run(request_for(args), os.environ.get("OSR_BUS_SOCKET", SOCKET))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
