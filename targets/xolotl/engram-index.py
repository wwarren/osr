#!/usr/bin/env python3
"""engram-index.py DIR SHARD [SHARD ...]

Write DIR/model.safetensors.index.json for the DeepSeek-V4.1-Flash Engram
shards in DIR, from the shards' own safetensors headers.

Xolotl's DeepSeek-V4.1 engine reads the Engram hash tables in place
(--engram DIR): it looks up each layers.<L>.engram.embed.{weight,scale}
tensor in DIR/model.safetensors.index.json and opens the shard it names. The
upstream index (7.5 MB, every tensor of the 48-shard model) has no published
hash, so the target downloads only the two shards it verified by SHA-256 and
derives the index from them instead.

Standard library only. Refuses shards whose header is malformed, a tensor
named twice, or a set of shards without both Engram tensors of a layer. The
index is written to a temporary file and renamed, so a failed run leaves the
previous index (if any) in place.
"""
import json
import os
import re
import struct
import sys

MAX_HEADER = 256 * 1024 * 1024
ENGRAM = re.compile(r"^layers\.(\d+)\.engram\.embed\.(weight|scale)$")


def header(path):
    with open(path, "rb") as f:
        raw = f.read(8)
        if len(raw) != 8:
            raise ValueError(f"{path}: too short for a safetensors file")
        (n,) = struct.unpack("<Q", raw)
        if not 2 <= n <= MAX_HEADER:
            raise ValueError(f"{path}: implausible safetensors header length {n}")
        body = f.read(n)
    if len(body) != n:
        raise ValueError(f"{path}: truncated safetensors header")
    data = json.loads(body)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: the safetensors header is not an object")
    size = os.path.getsize(path)
    tensors = {}
    for name, info in data.items():
        if name == "__metadata__":
            continue
        try:
            start, end = info["data_offsets"]
        except (TypeError, KeyError, ValueError):
            raise ValueError(f"{path}: tensor {name!r} has no data_offsets") from None
        if not (isinstance(start, int) and isinstance(end, int) and 0 <= start <= end and 8 + n + end <= size):
            raise ValueError(f"{path}: tensor {name!r} lies outside the file")
        tensors[name] = end - start
    return tensors


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    directory, shards = argv[1], argv[2:]
    weight_map, total = {}, 0
    for shard in shards:
        if os.path.basename(shard) != shard or not shard.endswith(".safetensors"):
            print(f"engram-index: {shard!r} must be a .safetensors file name in {directory}", file=sys.stderr)
            return 2
        try:
            tensors = header(os.path.join(directory, shard))
        except (OSError, ValueError) as e:
            print(f"engram-index: {e}", file=sys.stderr)
            return 1
        for name, nbytes in tensors.items():
            if name in weight_map:
                print(f"engram-index: {name} is in both {weight_map[name]} and {shard}", file=sys.stderr)
                return 1
            weight_map[name] = shard
            total += nbytes
    layers = {}
    for name in weight_map:
        m = ENGRAM.match(name)
        if m:
            layers.setdefault(int(m[1]), set()).add(m[2])
    if not layers:
        print("engram-index: the shards hold no layers.<L>.engram.embed tensors", file=sys.stderr)
        return 1
    incomplete = sorted(layer for layer, parts in layers.items() if parts != {"weight", "scale"})
    if incomplete:
        print(f"engram-index: layers {incomplete} lack an Engram weight or scale", file=sys.stderr)
        return 1
    index = {"metadata": {"total_size": total}, "weight_map": dict(sorted(weight_map.items()))}
    target = os.path.join(directory, "model.safetensors.index.json")
    temporary = target + ".tmp"
    with open(temporary, "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(temporary, target)
    print(f"engram-index: Engram layers {sorted(layers)} in {len(shards)} shard(s) -> {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
