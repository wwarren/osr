#!/usr/bin/env python3
"""Outbound allow rules for an agent CT whose Proxmox firewall restricts egress.

  firewall_rules.py endpoints RELAY_JSON [WEBHOOK_FILE]  -> "<ipv4> <port> <tag>" lines
  firewall_rules.py restricted FW                        -> exit 0 when policy_out is DROP
  firewall_rules.py insert FW_IN FW_OUT ENDPOINTS        -> FW_OUT with the owned rules

Owned rules carry a "# osr-hcom-…" comment, which Proxmox keeps. They are
placed before the first outbound DROP/REJECT in [RULES] (Proxmox applies the
first match), and every other line is kept as it is. The webhook URL's path
is secret: only its host and port are read.
"""
import ipaddress
import json
import socket
import sys
from urllib.parse import urlsplit

TAGS = ("osr-hcom-relay", "osr-hcom-mattermost")


def endpoint(url, defaults, tag, resolve=socket.getaddrinfo):
    part = urlsplit(url)
    host, port = part.hostname, part.port or defaults[part.scheme]
    try:
        address = str(ipaddress.IPv4Address(host))
    except ValueError:
        try:
            address = resolve(host, port, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
        except OSError:
            raise SystemExit(f"Cannot resolve {host} on this host for the CT firewall rule.") from None
    return address, port, tag


def endpoints(relay, webhook=None, resolve=socket.getaddrinfo):
    result = [endpoint(relay["broker"], {"mqtt": 1883, "mqtts": 8883}, TAGS[0], resolve)]
    if webhook:
        result.append(endpoint(webhook, {"http": 80, "https": 443}, TAGS[1], resolve))
    return result


def restricted(text):
    section = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("["):
            section = line
        elif section == "[OPTIONS]" and line.replace(" ", "").replace("\t", "") == "policy_out:DROP":
            return True
    return False


def insert(text, wanted):
    kept = [line for line in text.splitlines() if not line.rstrip().endswith(tuple(" # " + t for t in TAGS))]
    rules = [f"OUT ACCEPT -dest {address}/32 -p tcp -dport {port} -log nolog # {tag}" for address, port, tag in wanted]
    if "[RULES]" not in kept:
        kept += ["", "[RULES]"]
    start = kept.index("[RULES]") + 1
    end = next((i for i in range(start, len(kept)) if kept[i].startswith("[")), len(kept))
    at = next((i for i in range(start, end) if kept[i].split()[:2] in (["OUT", "DROP"], ["OUT", "REJECT"])), end)
    while at > start and not kept[at - 1].strip():
        at -= 1
    return "\n".join(kept[:at] + rules + kept[at:]) + "\n"


def main(argv):
    if argv[:1] == ["endpoints"] and len(argv) in (2, 3):
        webhook = open(argv[2]).read().strip() if len(argv) == 3 else None
        for address, port, tag in endpoints(json.load(open(argv[1])), webhook):
            print(address, port, tag)
        return 0
    if argv[:1] == ["restricted"] and len(argv) == 2:
        return 0 if restricted(open(argv[1]).read()) else 1
    if argv[:1] == ["insert"] and len(argv) == 4:
        wanted = [line.split() for line in open(argv[3]) if line.strip()]
        with open(argv[2], "w") as output:
            output.write(insert(open(argv[1]).read(), wanted))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
