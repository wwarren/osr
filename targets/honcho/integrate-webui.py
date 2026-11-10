#!/usr/bin/env python3
"""Register Honcho's MCP endpoint in the router's Open WebUI, idempotently.

The connection carries Open WebUI's gateway key and X-User-Id: {{USER_ID}},
which Open WebUI fills in with the user's ID on every request; the Honcho
gateway gives each user a workspace of their own.
"""
import json
import os
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request(url, token, payload=None):
    headers = {"Authorization": "Bearer " + token}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    req = Request(url, data=payload, headers=headers,
                  method="POST" if payload is not None else "GET")
    with urlopen(req, timeout=20) as response:
        return json.load(response)


USER_HEADER = "X-User-Id"
USER_TEMPLATE = "{{USER_ID}}"
# Headers the gateway sets itself; an older registration sent the workspace.
MANAGED_HEADERS = ("x-user-id", "x-honcho-workspace-id")


def check_gateway_key(mcp_url, key):
    """Prove KEY against the Honcho gateway before Open WebUI stores it.

    GET /osr/v1/whoami answers 401 to a wrong key and names its client, which
    must be openwebui with a workspace per user (not an agent's key, which
    would put every user in the agents' shared memory).
    """
    try:
        body = request(mcp_url.rstrip("/") + "/osr/v1/whoami", key)
    except HTTPError as exc:
        if exc.code in (401, 403):
            raise ValueError("the Honcho gateway rejected the key (/etc/honcho-target/openwebui-key "
                             "and the key given here differ)") from exc
        if exc.code == 404:
            raise ValueError("Honcho has no client gateway (an install from before per-user "
                             "memory): rerun the Honcho provisioner with --reconfigure first") from exc
        raise
    if not isinstance(body, dict) or body.get("client") != "openwebui" or body.get("per_user") is not True:
        raise ValueError(f"the key belongs to Honcho client {body.get('client') if isinstance(body, dict) else body!r}, "
                         "not openwebui with a workspace per user")


def connection_headers(previous):
    """PREVIOUS headers an admin added, with the user header the gateway needs."""
    headers = {}
    if isinstance(previous, dict):
        headers = {name: value for name, value in previous.items()
                   if str(name).lower() not in MANAGED_HEADERS}
    headers[USER_HEADER] = USER_TEMPLATE
    return headers


def is_honcho(item):
    return (isinstance(item, dict) and isinstance(item.get("info"), dict)
            and item["info"].get("id") == "honcho")


def main():
    args = sys.argv[1:]
    mode = args[0] if args and args[0] in ("--check", "--snapshot", "--restore") else "register"
    if mode == "--check" and len(args) == 3:
        base, admin_file = args[1:]
    elif mode in ("--snapshot", "--restore") and len(args) == 4:
        base, admin_file, snapshot_file = args[1:]
    elif mode == "register" and len(args) == 4:
        base, admin_file, honcho_file, mcp_url = args
    else:
        raise ValueError("use --check BASE ADMIN_FILE, --snapshot/--restore BASE ADMIN_FILE FILE, or BASE ADMIN_FILE HONCHO_FILE MCP_URL")
    admin = Path(admin_file).read_text(encoding="utf-8").strip()
    if not admin:
        raise ValueError("missing Open WebUI admin token")
    endpoint = base.rstrip("/") + "/api/v1/configs/tool_servers"
    response = request(endpoint, admin)
    if not isinstance(response, dict):
        raise ValueError("Open WebUI returned an invalid tool server response")
    connections = response.get("TOOL_SERVER_CONNECTIONS")
    if not isinstance(connections, list):
        raise ValueError("Open WebUI returned an invalid tool server list")
    if mode == "--check":
        print("Open WebUI admin access verified")
        return
    if mode == "--snapshot":
        snapshot = {"position": next((i for i, item in enumerate(connections) if is_honcho(item)), len(connections)),
                    "connections": [item for item in connections if is_honcho(item)]}
        fd = os.open(snapshot_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(snapshot, stream)
        print("Honcho Open WebUI connection saved")
        return
    if mode == "--restore":
        snapshot = json.loads(Path(snapshot_file).read_text(encoding="utf-8"))
        if not isinstance(snapshot, dict):
            raise ValueError("invalid Honcho connection snapshot")
        saved = snapshot.get("connections")
        position = snapshot.get("position")
        if not isinstance(saved, list) or not all(is_honcho(item) for item in saved) or \
                type(position) is not int or position < 0:
            raise ValueError("invalid Honcho connection snapshot")
        next_connections = [item for item in connections if not is_honcho(item)]
        next_connections[min(position, len(next_connections)):min(position, len(next_connections))] = saved
        if next_connections != connections:
            request(endpoint, admin, json.dumps({"TOOL_SERVER_CONNECTIONS": next_connections}).encode())
        print("Honcho Open WebUI connection restored")
        return
    honcho = Path(honcho_file).read_text(encoding="utf-8").strip()
    if not honcho:
        raise ValueError("missing Honcho gateway key")
    check_gateway_key(mcp_url, honcho)
    connection = {
        "type": "mcp", "url": mcp_url.rstrip("/") + "/mcp", "path": "/mcp",
        "auth_type": "bearer", "key": honcho,
        "headers": connection_headers(None),
        "config": {"enable": True},
        "info": {"id": "honcho", "name": "Honcho Memory",
                 "description": "Memory tools; every user has a memory of their own"},
    }
    existing = [item for item in connections if is_honcho(item)]
    if existing:
        previous = existing[0]
        updated = dict(previous)
        updated.update({key: connection[key] for key in
                        ("type", "url", "path", "auth_type", "key")})
        updated["config"] = dict(previous.get("config") or connection["config"])
        updated["info"] = dict(previous.get("info") or connection["info"])
        updated["headers"] = connection_headers(previous.get("headers"))
        connection = updated
    if len(existing) == 1 and existing[0] == connection:
        print("Honcho MCP is already registered in Open WebUI")
        return
    next_connections = [item for item in connections if not is_honcho(item)]
    next_connections.append(connection)
    if next_connections != connections:
        request(endpoint, admin, json.dumps(
            {"TOOL_SERVER_CONNECTIONS": next_connections}).encode())
    print("Honcho MCP registered in Open WebUI")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, HTTPError, URLError, OSError, KeyError) as exc:
        print(f"Honcho Open WebUI integration failed: {exc}", file=sys.stderr)
        sys.exit(1)
