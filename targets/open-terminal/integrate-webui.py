#!/usr/bin/env python3
"""Add one system Open Terminal connection through Open WebUI's admin API.

Run inside the router CT. Secrets are read from temporary files, not argv.
--access-only changes nothing but who may use a connection that is already
registered (tools/upgrade-all.sh, after it upgraded the terminal CT): it
needs no terminal URL or key, and leaves an Open WebUI without that
connection alone.
"""
import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# Open WebUI's grant for every signed-in user (what "Public" saves in its
# access dialog). Without any grant a connection is admin-only.
ALL_USERS = {"principal_type": "user", "principal_id": "*", "permission": "read"}


def is_all_users(grant):
    return isinstance(grant, dict) and all(grant.get(key) == value for key, value in ALL_USERS.items())


def open_to_all_users(connection):
    """CONNECTION enabled, with the all-users grant beside the grants it has."""
    config = connection.get("config")
    config = dict(config) if isinstance(config, dict) else {}
    grants = config.get("access_grants")
    grants = list(grants) if isinstance(grants, list) else []
    if not any(is_all_users(grant) for grant in grants):
        grants.append(dict(ALL_USERS))
    config["access_grants"] = grants
    return {**connection, "enabled": True, "config": config}


def request(url, token=None, data=None, expect=dict):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(data, separators=(",", ":")).encode()
    try:
        with OPENER.open(
            urllib.request.Request(url, data=data, headers=headers), timeout=20
        ) as response:
            body = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read(500).decode("utf-8", "replace")
        exc.close()
        raise RuntimeError(f"{url}: HTTP {exc.code}: {detail}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{url}: response is not JSON") from exc
    if expect is not None and not isinstance(body, expect):
        raise RuntimeError(f"{url}: unexpected {type(body).__name__} response")
    return body


def check_terminal_key(terminal, key):
    """Prove the key against the workspace gateway, which requires it.

    Open WebUI's own verify only calls GET /api/config, which answers without
    a working key, so a wrong key would pass it and fail only when someone
    first uses the terminal. GET /osr/v1/whoami answers 401 to a missing or
    wrong key and names the client the key belongs to: it must be openwebui,
    whose users each get their own workspace.
    """
    try:
        body = request(f"{terminal}/osr/v1/whoami", key)
    except RuntimeError as exc:
        if "HTTP 401" in str(exc) or "HTTP 403" in str(exc):
            raise RuntimeError("Open Terminal rejected the API key "
                               "(/etc/open-terminal/api-key and the key given here differ)") from exc
        if "HTTP 404" in str(exc):
            raise RuntimeError("Open Terminal has no workspace gateway (an install from before per-user "
                               "workspaces): rerun install-target.sh in the terminal CT first") from exc
        raise
    if body.get("client") != "openwebui":
        raise RuntimeError(f"{terminal}/osr/v1/whoami: the key belongs to client "
                           f"{body.get('client')!r}, not openwebui")


def access_label(connection):
    grants = (connection.get("config") or {}).get("access_grants") or []
    if any(is_all_users(grant) for grant in grants):
        return "enabled for all users"
    if grants:
        return "access limited to the users and groups granted in Open WebUI"
    return "admin-only"


def read_connections(base, admin_token, connection_id):
    """Open WebUI's terminal connections and the ones with CONNECTION_ID."""
    current = request(base, admin_token).get("TERMINAL_SERVER_CONNECTIONS")
    if not isinstance(current, list):
        raise RuntimeError("Unexpected terminal connection response from Open WebUI")
    if not all(isinstance(item, dict) for item in current):
        raise RuntimeError("Unexpected terminal connection entry from Open WebUI")
    matches = [item for item in current if item.get("id") == connection_id]
    if len(matches) > 1:
        raise RuntimeError(f"Duplicate terminal connection ID: {connection_id}")
    return current, matches


def save_connections(base, admin_token, connections, connection):
    request(base, admin_token, {"TERMINAL_SERVER_CONNECTIONS": connections})
    saved = request(base, admin_token).get("TERMINAL_SERVER_CONNECTIONS")
    kept = [item for item in saved if isinstance(item, dict) and item.get("id") == connection["id"]] \
        if isinstance(saved, list) else []
    if not kept:
        raise RuntimeError("Open WebUI did not retain the connection")
    if access_label(kept[0]) != access_label(connection):
        raise RuntimeError("Open WebUI did not retain the connection's access")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--webui-url", required=True)
    parser.add_argument("--access-only", action="store_true",
                        help="only enable an already registered connection for every user")
    parser.add_argument("--terminal-url")
    parser.add_argument("--id", required=True)
    parser.add_argument("--name", default="Open Terminal LXC")
    parser.add_argument("--admin-token-file", required=True, help="a file, or - for stdin")
    parser.add_argument("--terminal-key-file")
    parser.add_argument("--access", choices=("all", "keep"), default="all",
                        help="all: enable the connection for every Open WebUI user; "
                             "keep: leave an existing connection's access alone (a new one is admin-only)")
    args = parser.parse_args()

    # "-" is the token on this process's own stdin. /dev/stdin cannot stand in
    # for it: opening that path opens the pipe again, which an unprivileged CT
    # refuses for a pipe that pct exec made on the host (EACCES).
    if args.admin_token_file == "-":
        admin_token = sys.stdin.read().strip()
    else:
        admin_token = pathlib.Path(args.admin_token_file).read_text().strip()
    if args.access_only:
        if not admin_token:
            raise RuntimeError("The admin token must be nonempty")
        base = f"{args.webui_url.rstrip('/')}/api/v1/configs/terminal_servers"
        current, matches = read_connections(base, admin_token, args.id)
        if not matches:
            print(f"This Open WebUI has no connection {args.id}; nothing was changed.")
            return
        connection = open_to_all_users(matches[0]) if args.access == "all" else matches[0]
        if connection == matches[0]:
            print(f"Open WebUI connection {args.id} unchanged ({access_label(connection)}).")
            return
        save_connections(base, admin_token,
                         [connection if item.get("id") == args.id else item for item in current], connection)
        print(f"Open WebUI connection {args.id} is now {access_label(connection)}.")
        return
    if not args.terminal_url or not args.terminal_key_file:
        parser.error("--terminal-url and --terminal-key-file are required")
    terminal_key = pathlib.Path(args.terminal_key_file).read_text().strip()
    if not admin_token or not terminal_key:
        raise RuntimeError("Admin token and terminal key must both be nonempty")
    webui = args.webui_url.rstrip("/")
    terminal = args.terminal_url.rstrip("/")
    base = f"{webui}/api/v1/configs/terminal_servers"
    connection = {
        "id": args.id,
        "name": args.name,
        "enabled": True,
        "url": terminal,
        "path": "/openapi.json",
        "key": terminal_key,
        "auth_type": "bearer",
        # Empty grants keep it admin-only. Every user with access gets their
        # own workspace (the gateway keys it on X-User-Id).
        "config": {"access_grants": []},
    }

    # Both checks run from the router CT before anything is saved: the key
    # against the terminal directly, then reachability as Open WebUI's backend
    # sees it (its verify does not check the key, see check_terminal_key).
    check_terminal_key(terminal, terminal_key)
    verified = request(f"{base}/verify", admin_token, connection)
    if verified.get("status") is not True or verified.get("type") != "terminal":
        raise RuntimeError(f"Open WebUI did not verify the terminal: {verified}")

    current, matches = read_connections(base, admin_token, args.id)
    if matches:
        # Keep any access grants and other admin choices from the existing entry.
        old = matches[0]
        connection = {**old, "url": terminal, "key": terminal_key, "auth_type": "bearer"}
    if args.access == "all":
        connection = open_to_all_users(connection)
    if matches:
        current = [connection if item.get("id") == args.id else item for item in current]
    else:
        current.append(connection)
    save_connections(base, admin_token, current, connection)
    print(f"Open WebUI connection {args.id} saved and verified ({access_label(connection)}).")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as exc:
        print(f"Integration failed: {exc}", file=sys.stderr)
        sys.exit(1)
