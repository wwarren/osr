#!/usr/bin/env python3
"""Add one system Open Terminal connection through Open WebUI's admin API.

Run inside the router CT. Secrets are read from temporary files, not argv.
"""
import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


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
    """Prove the key against an endpoint that requires it.

    Open WebUI's own verify only calls GET /api/config, which Open Terminal
    serves without authentication, so a wrong key would pass it and fail only
    when someone first uses the terminal. GET /files/cwd answers 401 to a
    missing or wrong key.
    """
    try:
        body = request(f"{terminal}/files/cwd", key)
    except RuntimeError as exc:
        if "HTTP 401" in str(exc) or "HTTP 403" in str(exc):
            raise RuntimeError("Open Terminal rejected the API key "
                               "(/etc/open-terminal/api-key and the key given here differ)") from exc
        raise
    if "cwd" not in body:
        raise RuntimeError(f"{terminal}/files/cwd: not an Open Terminal response: {body}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--webui-url", required=True)
    parser.add_argument("--terminal-url", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--name", default="Open Terminal LXC")
    parser.add_argument("--admin-token-file", required=True)
    parser.add_argument("--terminal-key-file", required=True)
    args = parser.parse_args()

    admin_token = pathlib.Path(args.admin_token_file).read_text().strip()
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
        # Empty grants keep the shared shell admin-only. Grant groups in the UI.
        "config": {"access_grants": []},
    }

    # Both checks run from the router CT before anything is saved: the key
    # against the terminal directly, then reachability as Open WebUI's backend
    # sees it (its verify does not check the key, see check_terminal_key).
    check_terminal_key(terminal, terminal_key)
    verified = request(f"{base}/verify", admin_token, connection)
    if verified.get("status") is not True or verified.get("type") != "terminal":
        raise RuntimeError(f"Open WebUI did not verify the terminal: {verified}")

    current = request(base, admin_token).get("TERMINAL_SERVER_CONNECTIONS")
    if not isinstance(current, list):
        raise RuntimeError("Unexpected terminal connection response from Open WebUI")
    if not all(isinstance(item, dict) for item in current):
        raise RuntimeError("Unexpected terminal connection entry from Open WebUI")
    matches = [item for item in current if item.get("id") == args.id]
    if len(matches) > 1:
        raise RuntimeError(f"Duplicate terminal connection ID: {args.id}")
    if matches:
        # Keep any access grants and other admin choices from the existing entry.
        old = matches[0]
        connection = {**old, "url": terminal, "key": terminal_key, "auth_type": "bearer"}
        current = [connection if item.get("id") == args.id else item for item in current]
    else:
        current.append(connection)
    request(base, admin_token, {"TERMINAL_SERVER_CONNECTIONS": current})
    saved = request(base, admin_token).get("TERMINAL_SERVER_CONNECTIONS")
    if not isinstance(saved, list) or not any(
            isinstance(item, dict) and item.get("id") == args.id for item in saved):
        raise RuntimeError("Open WebUI did not retain the connection")
    print(f"Open WebUI connection {args.id} saved and verified.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as exc:
        print(f"Integration failed: {exc}", file=sys.stderr)
        sys.exit(1)
