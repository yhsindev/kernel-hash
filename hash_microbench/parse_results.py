#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Join in-kernel cycles + external perf counters; print a summary table
and plot cycles/hash vs input length.

Requires: pandas, matplotlib  (apt install python3-pandas python3-matplotlib)
"""

import sys
from pathlib import Path

import pandas as pd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

RESULTS = Path("results")


def load() -> pd.DataFrame:
    dmesg = pd.read_csv(RESULTS / "dmesg.csv")
    perf = pd.read_csv(RESULTS / "perf.csv")

    # Coerce numeric (perf stat sometimes emits <not counted>)
    for col in ("cycles", "instructions", "branch_misses", "cache_misses"):
        perf[col] = pd.to_numeric(perf[col], errors="coerce")

    m = dmesg.merge(perf, on=["hash", "input_len", "repeat"], how="inner")
    m["ins_per_hash"] = m["instructions"] / m["iterations"]
    m["brmiss_per_hash"] = m["branch_misses"] / m["iterations"]
    m["cmiss_per_hash"] = m["cache_misses"] / m["iterations"]
    return m


def summarize(m: pd.DataFrame) -> pd.DataFrame:
    g = (
        m.groupby(["hash", "input_len"])
        .agg(
            cycles_per_hash_kernel=("cycles_per_hash", "median"),
            cycles_per_hash_kernel_std=("cycles_per_hash", "std"),
            ins_per_hash=("ins_per_hash", "median"),
            brmiss_per_hash=("brmiss_per_hash", "median"),
            cmiss_per_hash=("cmiss_per_hash", "median"),
            n=("repeat", "count"),
        )
        .reset_index()
    )
    return g


def emit_markdown(summary: pd.DataFrame, path: Path) -> None:
    cols = [
        "hash",
        "input_len",
        "cycles_per_hash_kernel",
        "ins_per_hash",
        "brmiss_per_hash",
        "cmiss_per_hash",
        "n",
    ]
    headers = [
        "Hash",
        "Input (B)",
        "Cycles/hash (kernel)",
        "Instr/hash",
        "Branch-miss/hash",
        "Cache-miss/hash",
        "Repeats",
    ]
    lines = []
    lines.append("| " + " | ".join(headers) + " |")
    lines.append("|" + "|".join(["---"] * len(headers)) + "|")
    for _, r in summary.sort_values(["hash", "input_len"]).iterrows():
        row = [
            str(r["hash"]),
            f"{int(r['input_len'])}",
            f"{r['cycles_per_hash_kernel']:.1f}",
            f"{r['ins_per_hash']:.2f}",
            f"{r['brmiss_per_hash']:.4f}",
            f"{r['cmiss_per_hash']:.4f}",
            f"{int(r['n'])}",
        ]
        lines.append("| " + " | ".join(row) + " |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def plot_cycles(summary: pd.DataFrame, path: Path) -> None:
    fig, ax = plt.subplots(figsize=(8, 5))
    for h, g in summary.groupby("hash"):
        g = g.sort_values("input_len")
        ax.plot(g.input_len, g.cycles_per_hash_kernel, marker="o", label=h)
    ax.set_xlabel("Input length (bytes)")
    ax.set_ylabel("Median cycles / hash (in-kernel TSC)")
    ax.set_xscale("log", base=2)
    ax.set_xticks(sorted(summary.input_len.unique()))
    ax.set_xticklabels([str(int(x)) for x in sorted(summary.input_len.unique())])
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    ax.set_title("Hash function cost vs input length")
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def plot_metric_at(summary: pd.DataFrame, metric: str, ylabel: str,
                   input_len: int, path: Path) -> None:
    d = summary[summary.input_len == input_len].sort_values("hash")
    if d.empty:
        return
    fig, ax = plt.subplots(figsize=(6, 4))
    ax.bar(d["hash"], d[metric])
    ax.set_ylabel(ylabel)
    ax.set_title(f"{ylabel} at input_len={input_len} B")
    ax.grid(True, axis="y", alpha=0.3)
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)


def main() -> int:
    if not (RESULTS / "dmesg.csv").exists() or not (RESULTS / "perf.csv").exists():
        print("Missing results/dmesg.csv or results/perf.csv — run ./run_all.sh first",
              file=sys.stderr)
        return 1

    m = load()
    if m.empty:
        print("No joined rows — check that dmesg.csv and perf.csv have matching keys",
              file=sys.stderr)
        return 1

    summary = summarize(m)
    print(summary.to_string(index=False))
    summary.to_csv(RESULTS / "summary.csv", index=False)

    emit_markdown(summary, RESULTS / "summary.md")
    plot_cycles(summary, RESULTS / "fig_cycles_vs_size.png")
    plot_metric_at(summary, "ins_per_hash",    "Instructions / hash",
                   64, RESULTS / "fig_ins_per_hash_64.png")
    plot_metric_at(summary, "brmiss_per_hash", "Branch misses / hash",
                   64, RESULTS / "fig_brmiss_per_hash_64.png")
    plot_metric_at(summary, "cmiss_per_hash",  "Cache misses / hash",
                   64, RESULTS / "fig_cmiss_per_hash_64.png")

    print("\nWrote:")
    for p in [
        "summary.csv",
        "summary.md",
        "fig_cycles_vs_size.png",
        "fig_ins_per_hash_64.png",
        "fig_brmiss_per_hash_64.png",
        "fig_cmiss_per_hash_64.png",
    ]:
        print(f"  results/{p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
