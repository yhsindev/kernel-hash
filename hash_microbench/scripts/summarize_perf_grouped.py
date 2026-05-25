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

# Each metric only exists in its corresponding group.
# Keep non-empty metric values and aggregate them separately.

def summarize_metric(metric_col):
    sub = df[df[metric_col].notna()]
    return (
        sub.groupby(["hash_name", "input_len"])
           .agg(
               mean=(metric_col, "mean"),
               std=(metric_col, "std"),
               min=(metric_col, "min"),
               max=(metric_col, "max"),
               repeats=(metric_col, "count"),
           )
           .reset_index()
    )

cycles_summary = summarize_metric("module_cycles_per_hash")
instr_summary = summarize_metric("instructions_per_hash")
branch_summary = summarize_metric("branch_misses_per_hash")
cache_summary = summarize_metric("cache_misses_per_hash")

# module_cycles_per_hash appears in every group because dmesg is printed every time.
# To avoid counting 3 groups as separate repeats, use only core group for cycles.
cycles_summary = summarize_metric_from_core = (
    df[df["group"] == "core"]
      .groupby(["hash_name", "input_len"])
      .agg(
          mean=("module_cycles_per_hash", "mean"),
          std=("module_cycles_per_hash", "std"),
          min=("module_cycles_per_hash", "min"),
          max=("module_cycles_per_hash", "max"),
          repeats=("module_cycles_per_hash", "count"),
      )
      .reset_index()
)

def order_and_pivot(summary, value_name):
    summary["hash_name"] = pd.Categorical(
        summary["hash_name"],
        categories=hash_order,
        ordered=True,
    )
    summary = summary.sort_values(["input_len", "hash_name"])
    pivot = summary.pivot(
        index="input_len",
        columns="hash_name",
        values="mean",
    )[hash_order]
    return summary, pivot

cycles_summary, pivot_cycles = order_and_pivot(cycles_summary, "cycles")
instr_summary, pivot_instr = order_and_pivot(instr_summary, "instructions")
branch_summary, pivot_branch = order_and_pivot(branch_summary, "branch")
cache_summary, pivot_cache = order_and_pivot(cache_summary, "cache")

cycles_summary.to_csv(f"{output_prefix}_cycles_summary.csv", index=False)
instr_summary.to_csv(f"{output_prefix}_instructions_summary.csv", index=False)
branch_summary.to_csv(f"{output_prefix}_branch_misses_summary.csv", index=False)
cache_summary.to_csv(f"{output_prefix}_cache_misses_summary.csv", index=False)

pivot_cycles.to_csv(f"{output_prefix}_pivot_cycles_per_hash.csv")
pivot_instr.to_csv(f"{output_prefix}_pivot_instructions_per_hash.csv")
pivot_branch.to_csv(f"{output_prefix}_pivot_branch_misses_per_hash.csv")
pivot_cache.to_csv(f"{output_prefix}_pivot_cache_misses_per_hash.csv")

print("\n=== module cycles per hash ===")
print(pivot_cycles.round(4).to_string())

print("\n=== instructions per hash ===")
print(pivot_instr.round(4).to_string())

print("\n=== branch misses per hash ===")
print(pivot_branch.round(8).to_string())

print("\n=== cache misses per hash ===")
print(pivot_cache.round(8).to_string())

print(f"\nWrote grouped summaries with prefix: {output_prefix}")
