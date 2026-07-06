#!/usr/bin/env python3
"""實驗一:per-hash 成本 vs 輸入長度,論文風格折線圖(grayscale-safe)。

畫兩個指標、風格統一,各輸出 PDF(向量,給 LaTeX)+ PNG@300dpi 到 ../results/figs/:
  fig_exp1_cycles_per_hash       cycles/hash       ← v8 perf 同一 run,mean
  fig_exp1_instructions_per_hash instructions/hash ← v8 perf 同一 run,mean

兩指標取自同一個 v8 perf run(10 reps),故可直接對照 IPC。v8 std 極小(cycles CV<2%、
instructions ~0.01),mean 即穩定 —— 對照舊的 v6 rdtsc run,hsiphash 在 16/32/128 因
單趟 IRQ 擾動 std 高達 34.9(見 microbench 量測效度討論),v8 已無此問題。
"""
import csv
import os

import matplotlib as mpl
mpl.use("Agg")
import matplotlib.pyplot as plt

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(BASE, "results")
FIGS = os.path.join(RESULTS, "figs")
os.makedirs(FIGS, exist_ok=True)

CYC_CSV = os.path.join(
    RESULTS, "v8_perf_grouped_20260525_141508_pivot_cycles_per_hash.csv")
INS_CSV = os.path.join(
    RESULTS, "v8_perf_grouped_20260525_141508_pivot_instructions_per_hash.csv")

LENGTHS = [16, 32, 64, 128, 256]
SERIES = ["jhash2", "hsiphash", "siphash"]
STYLE = {
    "jhash2":   dict(color="#1b1b1b", marker="o", ls="-"),
    "hsiphash": dict(color="#3b6fb0", marker="s", ls="--"),
    "siphash":  dict(color="#b4413a", marker="^", ls=":"),
}
LABEL = {
    "jhash2": "jhash2",
    "hsiphash": "hsiphash (SipHash-1-3)",
    "siphash": "siphash (SipHash-2-4)",
}


def load_pivot(path):
    """讀 input_len,jhash2,hsiphash,siphash 的 pivot CSV → {hash: [值 by 長度]}。"""
    by_len = {}
    with open(path) as f:
        for row in csv.DictReader(f):
            by_len[int(row["input_len"])] = row
    return {h: [float(by_len[L][h]) for L in LENGTHS] for h in SERIES}


def plot_metric(series, ylabel, out, ylim):
    mpl.rcParams.update({
        "font.family": "serif",
        "font.serif": ["DejaVu Serif"],
        "mathtext.fontset": "dejavuserif",
        "font.size": 11,
        "axes.labelsize": 12,
        "legend.fontsize": 9.5,
        "xtick.labelsize": 10,
        "ytick.labelsize": 10,
        "axes.linewidth": 0.8,
        "lines.linewidth": 1.6,
    })
    fig, ax = plt.subplots(figsize=(6.0, 4.0))
    for h in SERIES:
        ax.plot(LENGTHS, series[h], label=LABEL[h], markersize=6,
                markerfacecolor="white", markeredgewidth=1.4, **STYLE[h])
    ax.set_xlabel("Input length (bytes)")
    ax.set_ylabel(ylabel)
    ax.set_xticks(LENGTHS)
    ax.set_xlim(0, 272)
    ax.set_ylim(0, ylim)
    ax.grid(True, ls=":", lw=0.5, alpha=0.55)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="in", length=4)
    ax.legend(frameon=False, loc="upper left", handlelength=2.6)
    fig.tight_layout()
    fig.savefig(out + ".pdf")
    fig.savefig(out + ".png", dpi=300)
    print("wrote", out + ".{pdf,png}")
    for h in SERIES:
        print(f"  {h:9s}", "  ".join(f"{v:7.1f}" for v in series[h]))


cyc = load_pivot(CYC_CSV)
ins = load_pivot(INS_CSV)
plot_metric(cyc, "Cycles per hash",
            os.path.join(FIGS, "fig_exp1_cycles_per_hash"), 340)
plot_metric(ins, "Instructions per hash",
            os.path.join(FIGS, "fig_exp1_instructions_per_hash"), 1350)
