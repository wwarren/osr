#!/usr/bin/env python3
"""Check that the selected router serves a running Open WebUI on loopback."""

import json
import sys
import urllib.error
import urllib.request


def probe(port):
    base = f"http://127.0.0.1:{port}"
    # A proxy inherited from the router environment must not intercept loopback.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for path in ("/health", "/api/version"):
        try:
            request = urllib.request.Request(base + path, headers={"Accept": "application/json"})
            with opener.open(request, timeout=5) as response:
                body = response.read(65537)
                if response.status != 200 or len(body) > 65536:
                    raise ValueError("unexpected HTTP status or oversized response")
                result = json.loads(body)
        except (OSError, urllib.error.URLError, ValueError) as exc:
            raise RuntimeError(f"{base}{path}: {exc}") from exc
        if not isinstance(result, dict):
            raise RuntimeError(f"{base}{path}: unexpected response")
        if path == "/health" and result.get("status") is not True:
            raise RuntimeError(f"{base}{path}: Open WebUI is not healthy")
        if path == "/api/version" and not (
            isinstance(result.get("version"), str) and result["version"].strip()
        ):
            raise RuntimeError(f"{base}{path}: Open WebUI version is missing")
    return result["version"]


if __name__ == "__main__":
    try:
        print(probe(int(sys.argv[1])))
    except (IndexError, ValueError, RuntimeError) as exc:
        print(f"Open WebUI verification failed: {exc}", file=sys.stderr)
        sys.exit(1)
