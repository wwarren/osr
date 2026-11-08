#!/usr/bin/env python3
"""Follow hcom JSONL with a durable cursor and at-least-once webhook delivery."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from bus_config import atomic_write
from bus_server import decode_event

# Mattermost refused this one post (malformed or too large): retrying cannot help.
REJECTED = {400, 413, 422}
# The webhook itself is gone, disabled or forbidden: an operator must fix it.
MISCONFIGURED = {401, 403, 404, 410}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def payload_for(event):
    if event.get("type") != "message":
        return None
    data = event.get("data", {})
    adapted = decode_event(event)
    text = adapted["message"] if adapted else data.get("text", "")
    if not isinstance(text, str):
        raise ValueError("invalid message text")
    if not adapted and data.get("intent") != "request" and not re.search(
            r"\b(handoff|review|done|completed)\b|@[\w-]+", text, re.I):
        return None
    # Prevent agent text from triggering channel-wide mentions in Mattermost.
    text = text[:2000].replace("@", "@\u200b")
    sender = str(data.get("from", event.get("instance", "unknown")))[:100].replace("@", "@\u200b")
    destination = f" → {adapted['to']}" if adapted else ""
    return {"username": "OSR Agent Bus", "icon_emoji": ":arrows_counterclockwise:",
            "text": f"### Agent handoff\nFrom: {sender}{destination}\n\n" +
                    "\n".join("> " + line for line in text.splitlines()) +
                    f"\n\nhcom event {event['id']}"}


def post(url, payload):
    request = Request(url, data=json.dumps(payload).encode(),
                      headers={"Content-Type": "application/json"}, method="POST")
    with build_opener(NoRedirect).open(request, timeout=15) as response:
        if not 200 <= response.status < 300:
            raise OSError("webhook rejected")


def database_identity(db):
    # The inode only: st_dev of ZFS subvolumes and device-mapper volumes can
    # change across host reboots, restores and volume moves.
    return db.stat().st_ino


def initial_cursor(state, db):
    with sqlite3.connect(f"{db.as_uri()}?mode=ro", uri=True) as connection:
        newest = connection.execute("SELECT COALESCE(MAX(id), 0) FROM events").fetchone()[0]
    identity = database_identity(db)
    if state.exists():
        saved = json.loads(state.read_text())
        saved_database = saved.get("database")
        # Older cursors stored [st_dev, st_ino]. The device can change while
        # the database and its event IDs remain the same.
        if (isinstance(saved_database, list) and len(saved_database) == 2
                and all(isinstance(value, int) for value in saved_database)):
            saved_database = saved_database[1]
        if saved_database == identity and 0 <= saved["cursor"] <= newest:
            return saved["cursor"], identity
        # An unrecognised database (replaced, restored or reset while stopped)
        # resumes at its tail: replaying its whole history would flood the
        # channel. A reset seen while running arrives as db_reset instead.
        print("hcom database changed while the notifier was stopped; resuming at its newest event",
              file=sys.stderr)
    # First installation starts at the tail; persist it before spawning follow
    # so a crash before the first event cannot silently move this baseline.
    return newest, identity


def process_event(event, cursor, identity, state, url, deliver=post):
    if event.get("db_reset"):
        atomic_write(state, json.dumps({"cursor": 0, "database": identity}))
        return 0
    event_id = event["id"]
    if not isinstance(event_id, int) or event_id < 0:
        raise ValueError("invalid event ID")
    if event_id <= cursor:
        return cursor
    payload = payload_for(event)
    if payload:
        try:
            deliver(url, payload)  # A failure MUST NOT acknowledge this event.
        except HTTPError as error:
            if error.code not in REJECTED:
                raise
            # Never retried forever: one bad post must not block later ones.
            print(f"Mattermost rejected hcom event {event_id} (HTTP {error.code}); skipped",
                  file=sys.stderr)
    atomic_write(state, json.dumps({"cursor": event_id, "database": identity}))
    return event_id


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--webhook-file", type=Path, required=True)
    args = parser.parse_args()
    url = args.webhook_file.read_text().strip()
    parsed = urlsplit(url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or not parsed.path.startswith("/hooks/")):
        parser.error("invalid incoming webhook URL")
    args.state.parent.mkdir(parents=True, exist_ok=True)
    with open(str(args.state) + ".lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        db = Path(os.environ["HCOM_DIR"]) / "hcom.db"
        # A fresh relay worker may not have opened its database yet.
        for _ in range(30):
            if db.exists():
                break
            time.sleep(1)
        cursor, identity = initial_cursor(args.state, db)
        atomic_write(args.state, json.dumps({"cursor": cursor, "database": identity}))
        command = [os.environ.get("OSR_HCOM_BINARY", "/usr/local/bin/hcom"), "events",
                   "--follow", "--full", "--type", "message", "--after-id", str(cursor)]
        with subprocess.Popen(command, stdout=subprocess.PIPE, text=True) as child:
            try:
                for line in child.stdout:
                    event = json.loads(line)
                    if event.get("db_reset"):
                        identity = database_identity(db)
                    for attempt in range(6):
                        try:
                            cursor = process_event(event, cursor, identity, args.state, url)
                            break
                        except HTTPError as error:
                            # Print only the status: urllib's messages include the secret URL.
                            if error.code in MISCONFIGURED:
                                print(f"Mattermost webhook answered HTTP {error.code}: it is missing, disabled "
                                      "or forbidden. Rerun the observer provisioner.", file=sys.stderr)
                                return 1
                            print(f"Mattermost delivery failed (HTTP {error.code}); event retained for retry",
                                  file=sys.stderr)
                        except OSError:
                            print("Mattermost unreachable; event retained for retry", file=sys.stderr)
                        if attempt == 5:
                            return 1
                        time.sleep(min(2 ** attempt, 30))
                return child.wait() or 1  # Unexpected EOF must restart.
            finally:
                if child.poll() is None:
                    child.terminate()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # The type only: messages can contain the secret webhook URL.
        print(f"OSR bus bridge stopped ({type(error).__name__}); check configuration and state permissions",
              file=sys.stderr)
        sys.exit(1)
