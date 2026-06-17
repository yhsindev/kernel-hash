#!/usr/bin/env python3
"""plot_part3.py — 從 Part 3 raw 輸出畫關鍵實驗圖(防禦掃描 + microbench)。

讀 results/ 下的 ovs_buckets / ovs_probelen / ovs_hashcycles 快照與 hash_microbench
log,輸出 4 張 PNG 到 results/figs/:
  fig1_probe_attack.png   攻擊下 probe-count 分佈(3 backend)
  fig2_hashcyc_attack.png 攻擊下 per-hash cycle 分佈(3 backend)
  fig3_microbench_len.png cycles/hash vs 輸入長度(3 backend)
  fig4_summary_lmax.png   attack Lmax / probe-max 長條(3 backend)

用法:
  plot_part3.py [RESULTS_DIR] [MICROBENCH_LOG]
  預設 RESULTS_DIR=../results/ovs(part3 raw)、figs 輸出到 ../results/figs、
  MICROBENCH=../../hash_microbench/results/v6_all_hashes_20260519_115509.log
"""
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BACKENDS = ["jhash", "hsiphash", "siphash"]
COLORS = {"jhash": "#d62728", "hsiphash": "#1f77b4", "siphash": "#2ca02c"}


def parse_hist(path, data_header):
    """讀『# <header>』之後的 `key count` 行,回傳 {int key: int count} + meta dict。"""
    hist, meta, in_data = {}, {}, False
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("#"):
                for k, v in re.findall(r"(\w+)[ =](\d+)", line):
                    meta[k] = int(v)
                if data_header in line:
                    in_data = True
                continue
            m = re.match(r"(\d+)\s+(\d+)$", line)
            if m and in_data:
                hist[int(m.group(1))] = int(m.group(2))
    return hist, meta


def parse_microbench(path):
    """回傳 {hash_name: {input_len: mean cycles_per_hash}}(跨 repeat 平均)。"""
    acc = {}
    rx = re.compile(r"hash_microbench: (\w+) input_len=(\d+) .*cycles_per_hash=([\d.]+)")
    with open(path) as f:
        for line in f:
            m = rx.search(line)
            if m:
                name, ln, cyc = m.group(1), int(m.group(2)), float(m.group(3))
                acc.setdefault(name, {}).setdefault(ln, []).append(cyc)
    return {n: {l: sum(v) / len(v) for l, v in d.items()} for n, d in acc.items()}


def mode_of(hist):
    return max(hist, key=hist.get) if hist else 0


def fig1_probe(rdir, figdir):
    plt.figure(figsize=(7, 4.5))
    for b in BACKENDS:
        p = os.path.join(rdir, f"part3_probe_attack_{b}.txt")
        if not os.path.exists(p):
            continue
        h, _ = parse_hist(p, "probes count")
        xs = sorted(h)
        ys = [h[x] for x in xs]
        plt.step(xs, ys, where="mid", label=b, color=COLORS[b], linewidth=2)
    plt.xlabel("probes walked per lookup")
    plt.ylabel("lookups")
    plt.title("Probe-count per lookup under collision attack (K=16)")
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(figdir, "fig1_probe_attack.png"), dpi=150)
    plt.close()


def fig2_hashcyc(rdir, figdir):
    plt.figure(figsize=(7, 4.5))
    lo, hi = 1e9, 0
    for b in BACKENDS:
        p = os.path.join(rdir, f"part3_hashcyc_attack_{b}.txt")
        if not os.path.exists(p):
            continue
        h, meta = parse_hist(p, "cycles count")
        ovh = meta.get("rdtsc_pair_overhead_min", 0)
        xs = sorted(h)
        ys = [h[x] for x in xs]
        md = mode_of(h)
        plt.step(xs, ys, where="mid", color=COLORS[b], linewidth=1.5,
                 label=f"{b}  (mode {md}, ~{md - ovh} cyc net)")
        plt.axvline(md, color=COLORS[b], linestyle="--", alpha=0.5)
        lo, hi = min(lo, md - 40), max(hi, md + 60)
    plt.xlim(lo, hi)
    plt.xlabel("cycles per flow_hash (raw rdtsc delta, incl ~29 cyc overhead)")
    plt.ylabel("count")
    plt.title("In-context per-hash cost under attack (88B masked key)")
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(figdir, "fig2_hashcyc_attack.png"), dpi=150)
    plt.close()


def fig3_microbench(mlog, figdir):
    if not os.path.exists(mlog):
        print(f"[skip fig3] microbench log 不存在:{mlog}", file=sys.stderr)
        return
    data = parse_microbench(mlog)
    name_map = {"jhash2": "jhash", "hsiphash": "hsiphash", "siphash": "siphash"}
    plt.figure(figsize=(7, 4.5))
    for raw, b in name_map.items():
        if raw not in data:
            continue
        lens = sorted(data[raw])
        plt.plot(lens, [data[raw][l] for l in lens], "o-",
                 color=COLORS[b], label=b, linewidth=2)
    plt.axvline(88, color="gray", linestyle=":", label="OVS L3 masked key = 88B")
    plt.xlabel("input length (bytes)")
    plt.ylabel("cycles per hash (isolated)")
    plt.title("Per-hash cost vs input length (hash_microbench)")
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(figdir, "fig3_microbench_len.png"), dpi=150)
    plt.close()


def fig4_summary(rdir, figdir):
    lmax, pmax = {}, {}
    for b in BACKENDS:
        bp = os.path.join(rdir, f"part3_buckets_attack_{b}.txt")
        pp = os.path.join(rdir, f"part3_probe_attack_{b}.txt")
        if os.path.exists(bp):
            _, meta = parse_hist(bp, "chain_len buckets")
            lmax[b] = meta.get("Lmax", 0)
        if os.path.exists(pp):
            h, _ = parse_hist(pp, "probes count")
            pmax[b] = max(h) if h else 0
    import numpy as np
    x = np.arange(len(BACKENDS))
    w = 0.35
    plt.figure(figsize=(7, 4.5))
    plt.bar(x - w / 2, [lmax.get(b, 0) for b in BACKENDS], w, label="Lmax (longest chain)", color="#d62728")
    plt.bar(x + w / 2, [pmax.get(b, 0) for b in BACKENDS], w, label="max probes/lookup", color="#1f77b4")
    for i, b in enumerate(BACKENDS):
        plt.text(i - w / 2, lmax.get(b, 0) + 0.2, str(lmax.get(b, 0)), ha="center")
        plt.text(i + w / 2, pmax.get(b, 0) + 0.2, str(pmax.get(b, 0)), ha="center")
    plt.xticks(x, BACKENDS)
    plt.ylabel("count")
    plt.title("Attack effect by backend (same K=16 jhash-collision set)")
    plt.legend()
    plt.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(figdir, "fig4_summary_lmax.png"), dpi=150)
    plt.close()


def fig5_bucket_scatter(rdir, figdir):
    """每個 bucket 一個點:y=chain 長度,x=backend(加 jitter)。從 chain_len histogram 重建。"""
    import numpy as np
    rng = np.random.default_rng(0)
    plt.figure(figsize=(7, 4.5))
    for i, b in enumerate(BACKENDS):
        bp = os.path.join(rdir, f"part3_buckets_attack_{b}.txt")
        if not os.path.exists(bp):
            continue
        h, meta = parse_hist(bp, "chain_len buckets")
        loads = []
        for L, cnt in h.items():
            loads += [L] * cnt
        loads = np.array(loads)
        x = i + (rng.random(len(loads)) - 0.5) * 0.6
        plt.scatter(x, loads, s=8, alpha=0.25, color=COLORS[b])
        lmax = meta.get("Lmax", int(loads.max()) if len(loads) else 0)
        plt.text(i, lmax + 0.4, f"Lmax={lmax}", ha="center", color=COLORS[b])
    plt.xticks(range(len(BACKENDS)), BACKENDS)
    plt.ylabel("bucket chain length")
    plt.title("Per-bucket load under attack (each dot = one of 1024 buckets)")
    plt.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(os.path.join(figdir, "fig5_bucket_scatter.png"), dpi=150)
    plt.close()


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    rdir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "results", "ovs")
    mlog = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        here, "..", "..", "hash_microbench", "results",
        "v6_all_hashes_20260519_115509.log")
    figdir = os.path.join(here, "..", "results", "figs")
    os.makedirs(figdir, exist_ok=True)
    fig1_probe(rdir, figdir)
    fig2_hashcyc(rdir, figdir)
    fig3_microbench(mlog, figdir)
    fig4_summary(rdir, figdir)
    fig5_bucket_scatter(rdir, figdir)
    print(f"figs -> {figdir}")


if __name__ == "__main__":
    main()
