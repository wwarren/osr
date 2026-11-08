#!/usr/bin/env python3
"""Add Hermes's API server to Open WebUI as an OpenAI connection.

Run inside the router CT. Secrets are read from temporary files, not argv.

Steps, each checked before anything is saved:
  1. the Hermes key against Hermes's own /v1/models (and the model is listed);
  2. Open WebUI's /openai/verify, which calls Hermes from Open WebUI's backend,
     so it also proves the Hermes CT firewall admits the router;
  3. the OpenAI connection list is updated in place: an entry for this URL is
     updated, others (the router's own connection first) are kept as they are;
  4. optionally, the external task model (titles, tags, follow-ups) is set to a
     router model, so those background requests do not start agent runs.
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
            urllib.request.Request(url, data=data, headers=headers), timeout=30
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


def model_ids(body):
    data = body.get("data") if isinstance(body, dict) else None
    return [m.get("id") for m in data or [] if isinstance(m, dict)]


def check_hermes(hermes, key, model):
    """Prove the key and the advertised model against Hermes itself."""
    try:
        body = request(f"{hermes}/models", key)
    except RuntimeError as exc:
        if "HTTP 401" in str(exc) or "HTTP 403" in str(exc):
            raise RuntimeError("Hermes rejected the API key "
                               "(/etc/hermes-target/api-key and the key given here differ)") from exc
        raise
    if model not in model_ids(body):
        raise RuntimeError(f"Hermes does not advertise model {model!r} at {hermes}/models: {body}")


def save_connection(webui, admin, hermes, key):
    """Add or update the connection for this URL; return its index."""
    base = f"{webui}/openai/config"
    current = request(base, admin)
    urls = current.get("OPENAI_API_BASE_URLS")
    keys = current.get("OPENAI_API_KEYS")
    configs = current.get("OPENAI_API_CONFIGS")
    if not isinstance(urls, list) or not all(isinstance(u, str) for u in urls):
        raise RuntimeError("Unexpected OPENAI_API_BASE_URLS from Open WebUI")
    if not isinstance(keys, list) or not all(isinstance(k, str) for k in keys):
        raise RuntimeError("Unexpected OPENAI_API_KEYS from Open WebUI")
    if configs is None:
        configs = {}
    if not isinstance(configs, dict):
        raise RuntimeError("Unexpected OPENAI_API_CONFIGS from Open WebUI")
    # Open WebUI pads or trims the key list to the URL list; do the same, so the
    # indices below line up.
    keys = (keys + [""] * len(urls))[: len(urls)]
    matches = [i for i, u in enumerate(urls) if u.rstrip("/") == hermes]
    if len(matches) > 1:
        raise RuntimeError(f"Open WebUI has {len(matches)} connections to {hermes}; remove the extras first")
    if matches:
        index = matches[0]
        keys[index] = key
        entry = dict(configs.get(str(index)) or {})
        entry["enable"] = True
    else:
        index = len(urls)
        urls.append(hermes)
        keys.append(key)
        entry = {"enable": True, "prefix_id": "", "model_ids": [], "tags": [],
                 "connection_type": "external"}
    configs = dict(configs)
    configs[str(index)] = entry
    update = {
        "ENABLE_OPENAI_API": current.get("ENABLE_OPENAI_API", True),
        "OPENAI_API_BASE_URLS": urls,
        "OPENAI_API_KEYS": keys,
        "OPENAI_API_CONFIGS": configs,
    }
    request(f"{base}/update", admin, update)
    saved = request(base, admin)
    saved_urls = saved.get("OPENAI_API_BASE_URLS") or []
    saved_keys = saved.get("OPENAI_API_KEYS") or []
    if (len(saved_urls) != len(urls) or index >= len(saved_keys)
            or saved_urls[index].rstrip("/") != hermes or saved_keys[index] != key):
        raise RuntimeError("Open WebUI did not retain the connection")
    return index, bool(matches)


def set_task_model(webui, admin, task_model, hermes_model):
    """Point the external task model at a router model. Returns a message.

    A choice the admin already made is kept, unless it is Hermes itself, which
    would run the agent for every title and tag. Problems here are reported,
    never fatal: the connection is already saved."""
    try:
        config = request(f"{webui}/api/v1/tasks/config", admin)
        current = config.get("TASK_MODEL_EXTERNAL") or ""
        if current and current != hermes_model:
            return f"Task model (external) is already {current!r}; left unchanged."
        available = model_ids(request(f"{webui}/api/models", admin))
        if task_model not in available:
            return (f"WARNING: router model {task_model!r} is not in Open WebUI's model list; "
                    "set Admin Settings > Interface > Task Model (External) to a router model by hand.")
        config["TASK_MODEL_EXTERNAL"] = task_model
        saved = request(f"{webui}/api/v1/tasks/config/update", admin, config)
        if saved.get("TASK_MODEL_EXTERNAL") != task_model:
            raise RuntimeError("the setting was not retained")
        return f"Task model (external) set to {task_model!r}, so titles and tags do not run the agent."
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as exc:
        return (f"WARNING: could not set the task model ({exc}); set Admin Settings > Interface > "
                "Task Model (External) to a router model by hand.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--webui-url", required=True)
    parser.add_argument("--hermes-url", required=True, help="Hermes API base, ending in /v1")
    parser.add_argument("--model-name", default="hermes-agent")
    parser.add_argument("--task-model", default="", help="router model for Open WebUI tasks; blank: leave it")
    parser.add_argument("--admin-token-file", required=True)
    parser.add_argument("--hermes-key-file", required=True)
    args = parser.parse_args()

    admin = pathlib.Path(args.admin_token_file).read_text().strip()
    key = pathlib.Path(args.hermes_key_file).read_text().strip()
    if not admin or not key:
        raise RuntimeError("Admin token and Hermes key must both be nonempty")
    webui = args.webui_url.rstrip("/")
    hermes = args.hermes_url.rstrip("/")
    if not hermes.endswith("/v1"):
        raise RuntimeError("--hermes-url must end in /v1")

    check_hermes(hermes, key, args.model_name)
    verified = request(f"{webui}/openai/verify", admin, {"url": hermes, "key": key})
    if args.model_name not in model_ids(verified):
        raise RuntimeError(f"Open WebUI could not list {args.model_name!r} from {hermes}: {verified}")
    index, existed = save_connection(webui, admin, hermes, key)
    print(f"Open WebUI connection {index} ({hermes}) {'updated' if existed else 'added'} and verified.")
    if args.task_model:
        print(set_task_model(webui, admin, args.task_model, args.model_name))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, urllib.error.URLError, OSError, ValueError) as exc:
        print(f"Integration failed: {exc}", file=sys.stderr)
        sys.exit(1)
