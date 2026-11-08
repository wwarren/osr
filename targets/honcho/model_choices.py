#!/usr/bin/env python3
"""Chat model choices for the Honcho provisioner, from the router's inventory.

Usage:
  model_choices.py chat INVENTORY MIN_CONTEXT   chat models the proxy can use

It prints one model per line, best first, as NAME<TAB>DESCRIPTION<TAB>BASE_URL
(the model host's OpenAI-compatible /v1), and writes the models it left out,
and why, to stderr. (Honcho's embedding model runs in its own CT and is not
chosen from the inventory.)
"""
import json
import re
import sys

def base_url(server):
    """The /v1 URL of an inventory server entry (strata+http://h:8080 -> http://h:8080/v1)."""
    url = server.split("+", 1)[1] if re.match(r"^[a-z]+\+https?://", server) else server
    return url.rstrip("/") + "/v1"


def load(path):
    with open(path, encoding="utf-8") as source:
        models = json.load(source).get("models") or []
    return [m for m in models if isinstance(m, dict) and isinstance(m.get("name"), str) and m["name"]]


def describe(entry, hosts):
    parts = []
    if isinstance(entry.get("context_length"), int):
        parts.append(f"{entry['context_length']}-token context")
    if entry.get("params_b"):
        parts.append(f"{entry['params_b']:g}B")
    if entry.get("loaded") is True:
        parts.append("loaded")
    parts.append(f"on {len(hosts)} servers" if len(hosts) > 1 else "on " + hosts[0])
    return ", ".join(parts)


def grouped(entries):
    """One line per model name (a model on several servers is one choice),
    keeping the best entry: loaded first, then the larger context."""
    seen = {}
    for entry in entries:
        key = entry["name"].lower()
        best, hosts = seen.get(key, (None, []))
        hosts.append(base_url(entry.get("server", "")).removesuffix("/v1"))
        if best is None or (entry.get("loaded") is True, entry.get("context_length") or 0) > \
                (best.get("loaded") is True, best.get("context_length") or 0):
            best = entry
        seen[key] = (best, hosts)
    return list(seen.values())


def ranked(groups):
    return sorted(groups, key=lambda g: (g[0].get("loaded") is not True, -(g[0].get("params_b") or 0),
                                         -(g[0].get("context_length") or 0), g[0]["name"].lower()))


def chat(models, min_context):
    """(usable, left out): the proxy's own test, tools reported and enough context."""
    usable, skipped = [], []
    for entry in models:
        if entry.get("is_embedding"):
            continue
        context = entry.get("context_length")
        if entry.get("tools") is not True:
            reason = "no tool support" if entry.get("tools") is False else "tool support not reported"
        elif not isinstance(context, int) or isinstance(context, bool):
            reason = "no reported context"
        elif context < min_context:
            reason = f"{context}-token context"
        else:
            usable.append(entry)
            continue
        skipped.append((entry["name"], reason))
    return ranked(grouped(usable)), sorted(set(skipped))


def print_groups(groups):
    for best, hosts in groups:
        print(f"{best['name']}\t{describe(best, hosts)}\t{base_url(best.get('server', ''))}")


def main(argv):
    if len(argv) == 3 and argv[0] == "chat":
        usable, skipped = chat(load(argv[1]), int(argv[2]))
        print_groups(usable)
        if skipped:
            print("Left out (the proxy needs reported tool support and context): "
                  + "; ".join(f"{name} ({reason})" for name, reason in skipped), file=sys.stderr)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
