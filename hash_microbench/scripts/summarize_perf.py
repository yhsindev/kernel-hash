#!/usr/bin/env python3
import sys
import pandas as pd

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} <input_csv> <output_prefix>", file=sys.stderr)
    sys.exit(1)

input_csv = sys.argv[1]
output_prefix = sys.argv[2]

df = pd.read_csv(input_csv)

hash_order = ["jhash2", "hsiphash", "siphash"]

metrics = [
    "module_cycles_per_hash",
    "instructions_per_hash",
    "branch-misses_per_hash",
    "cache-misses_per_hash",
]

summary = (
    df.groupby(["hash_name", "input_len"])
      .agg(
          module_cycles_per_hash=("module_cycles_per_hash", "mean"),
          instructions_per_hash=("instructions_per_hash", "mean"),
          branch_misses_per_hash=("branch-misses_per_hash", "mean"),
          cache_misses_per_hash=("cache-misses_per_hash", "mean"),
          repeats=("module_cycles_per_hash", "count"),
      )
      .reset_index()
)

summary["hash_name"] = pd.Categorical(
    summary["hash_name"],
    categories=hash_order,
    ordered=True,
)

summary = summary.sort_values(["input_len", "hash_name"])
summary.to_csv(f"{output_prefix}_summary.csv", index=False)

print(summary.round(4).to_string(index=False))
print(f"\nWrote summary to {output_prefix}_summary.csv")
