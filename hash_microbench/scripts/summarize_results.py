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

summary = (
    df.groupby(["hash_name", "input_len"])
      .agg(
          mean_cycles_per_hash=("cycles_per_hash", "mean"),
          std_cycles_per_hash=("cycles_per_hash", "std"),
          min_cycles_per_hash=("cycles_per_hash", "min"),
          max_cycles_per_hash=("cycles_per_hash", "max"),
          repeats=("cycles_per_hash", "count"),
      )
      .reset_index()
)

summary["hash_name"] = pd.Categorical(
    summary["hash_name"],
    categories=hash_order,
    ordered=True,
)

summary = summary.sort_values(["input_len", "hash_name"])

pivot_mean = summary.pivot(
    index="input_len",
    columns="hash_name",
    values="mean_cycles_per_hash",
)

pivot_std = summary.pivot(
    index="input_len",
    columns="hash_name",
    values="std_cycles_per_hash",
)

pivot_mean = pivot_mean[hash_order]
pivot_std = pivot_std[hash_order]

summary.to_csv(f"{output_prefix}_summary.csv", index=False)
pivot_mean.to_csv(f"{output_prefix}_pivot_mean.csv")
pivot_std.to_csv(f"{output_prefix}_pivot_std.csv")

print("\n=== Mean cycles per hash ===")
print(pivot_mean.round(2).to_string())

print("\n=== Std cycles per hash ===")
print(pivot_std.round(2).to_string())

print(f"\nWrote detailed summary to {output_prefix}_summary.csv")
print(f"Wrote pivot mean table to {output_prefix}_pivot_mean.csv")
print(f"Wrote pivot std table to {output_prefix}_pivot_std.csv")