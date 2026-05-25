#!/usr/bin/env python3
import re
import sys
import csv

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input_log> <output_csv>", file=sys.stderr)
    sys.exit(1)

input_log = sys.argv[1]
output_csv = sys.argv[2]

hash_names = {
    "0": "jhash2",
    "1": "hsiphash",
    "2": "siphash",
}

header_re = re.compile(r"=== repeat=(\d+) hash_type=(\d+) len=(\d+) ===")
event_re = re.compile(r"^\s*([\d,]+)\s+([A-Za-z0-9_-]+)")
cycles_per_hash_re = re.compile(
    r"hash_microbench: (jhash2|hsiphash|siphash) "
    r"input_len=(\d+) iterations=(\d+) "
    r"total_cycles=(\d+) cycles_per_hash=([0-9.]+)"
)

events = [
    "cycles",
    "instructions",
    "branches",
    "branch-misses",
    "cache-references",
    "cache-misses",
]

rows = []
current = None

def flush_current():
    if current and "hash_name" in current:
        iterations = int(current.get("iterations", 0))
        row = {
            "repeat": current["repeat"],
            "hash_type": current["hash_type"],
            "hash_name": current["hash_name"],
            "input_len": current["input_len"],
            "iterations": iterations,
            "module_total_cycles": current.get("module_total_cycles", ""),
            "module_cycles_per_hash": current.get("module_cycles_per_hash", ""),
        }

        for ev in events:
            row[ev] = current.get(ev, "")

        if iterations > 0:
            for ev in events:
                val = current.get(ev, "")
                if isinstance(val, int):
                    row[f"{ev}_per_hash"] = val / iterations
                else:
                    row[f"{ev}_per_hash"] = ""
        else:
            for ev in events:
                row[f"{ev}_per_hash"] = ""

        rows.append(row)

with open(input_log, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        h = header_re.search(line)
        if h:
            flush_current()
            current = {
                "repeat": int(h.group(1)),
                "hash_type": h.group(2),
                "input_len": int(h.group(3)),
            }
            continue

        if current is None:
            continue

        ev = event_re.search(line)
        if ev:
            raw_value = ev.group(1).replace(",", "")
            event_name = ev.group(2)
            if event_name in events:
                try:
                    current[event_name] = int(raw_value)
                except ValueError:
                    pass
            continue

        cph = cycles_per_hash_re.search(line)
        if cph:
            current["hash_name"] = cph.group(1)
            current["iterations"] = int(cph.group(3))
            current["module_total_cycles"] = int(cph.group(4))
            current["module_cycles_per_hash"] = float(cph.group(5))

flush_current()

fieldnames = [
    "repeat",
    "hash_type",
    "hash_name",
    "input_len",
    "iterations",
    "module_total_cycles",
    "module_cycles_per_hash",
]
fieldnames += events
fieldnames += [f"{ev}_per_hash" for ev in events]

with open(output_csv, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

print(f"Wrote {len(rows)} rows to {output_csv}")