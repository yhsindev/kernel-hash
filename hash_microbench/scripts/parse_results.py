#!/usr/bin/env python3
import re
import sys
import csv

HASH_NAME = {
    "0": "jhash2",
    "1": "hsiphash",
    "2": "siphash",
}

header_re = re.compile(r"=== repeat=(\d+) hash_type=(\d+) len=(\d+) ===")
result_re = re.compile(
    r"hash_microbench: (jhash2|hsiphash|siphash) "
    r"input_len=(\d+) iterations=(\d+) "
    r"total_cycles=(\d+) cycles_per_hash=([0-9.]+)"
)

current = None
rows = []

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input_log> <output_csv>", file=sys.stderr)
    sys.exit(1)

input_log = sys.argv[1]
output_csv = sys.argv[2]

with open(input_log, "r", encoding="utf-8") as f:
    for line in f:
        h = header_re.search(line)
        if h:
            current = {
                "repeat": int(h.group(1)),
                "hash_type": h.group(2),
                "input_len": int(h.group(3)),
            }
            continue

        r = result_re.search(line)
        if r and current:
            hash_name = r.group(1)
            rows.append({
                "repeat": current["repeat"],
                "hash_type": current["hash_type"],
                "hash_name": hash_name,
                "input_len": int(r.group(2)),
                "iterations": int(r.group(3)),
                "total_cycles": int(r.group(4)),
                "cycles_per_hash": float(r.group(5)),
            })

with open(output_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=[
            "repeat",
            "hash_type",
            "hash_name",
            "input_len",
            "iterations",
            "total_cycles",
            "cycles_per_hash",
        ],
    )
    writer.writeheader()
    writer.writerows(rows)

print(f"Wrote {len(rows)} rows to {output_csv}")