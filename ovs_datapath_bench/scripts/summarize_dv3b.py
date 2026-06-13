#!/usr/bin/env python3
"""summarize_dv3b.py — 從 dv3b_formal_perf.csv 產 per-backend summary(mean/sd + derived metrics)。

用法(repo 根目錄): python3 ovs_datapath_bench/scripts/summarize_dv3b.py
輸出: 終端表格 + ovs_datapath_bench/results/v3b/dv3b_formal_summary.csv
"""
import csv
import statistics as st
from collections import defaultdict
from pathlib import Path

CSV_IN = Path("ovs_datapath_bench/results/v3b/dv3b_formal_perf.csv")
CSV_OUT = Path("ovs_datapath_bench/results/v3b/dv3b_formal_summary.csv")
PERF_WINDOW_S = 10  # perf stat 視窗長度,封包數 = pps × 視窗

rows = list(csv.DictReader(CSV_IN.open()))
by = defaultdict(list)
for r in rows:
    by[r["backend"]].append(r)

def fmean(rs, col):
    return st.mean(float(x[col]) for x in rs)

def fsd(rs, col):
    vals = [float(x[col]) for x in rs]
    return st.stdev(vals) if len(vals) > 1 else 0.0  # 樣本標準差(n-1)

order = [b for b in ("jhash", "hsiphash", "siphash") if b in by] + \
        [b for b in by if b not in ("jhash", "hsiphash", "siphash")]

out = [[
    "backend", "n", "ohash_children_mean", "ohash_children_sd",
    "ohash_self_mean", "masked_children_mean", "masked_children_sd",
    "hit_per_pkt_mean", "pps_mean", "ipc_mean", "soft_pct_mean",
    "cycles_per_packet", "instructions_per_packet",
    "hash_cycles_per_packet", "lookup_cycles_per_packet",
    "hash_lookup_ratio_pct", "flows_min", "flows_max", "masks_total",
]]

hdr = (f'{"backend":9} | {"n":>2} | {"ohash_ch%":>12} | {"masked_ch%":>12} | '
       f'{"hit/pkt":>7} | {"cyc/pkt":>8} | {"hash cyc/pkt":>12} | {"h/l ratio":>9} | {"%soft":>6}')
print(hdr)
print("-" * len(hdr))

for b in order:
    rs = by[b]
    n = len(rs)
    oc, ocs = fmean(rs, "ohash_children"), fsd(rs, "ohash_children")
    osm = fmean(rs, "ohash_self")
    mc, mcs = fmean(rs, "masked_children"), fsd(rs, "masked_children")
    hp = fmean(rs, "hit_per_pkt")
    pps = fmean(rs, "pps")
    ipc = fmean(rs, "ipc")
    soft = fmean(rs, "soft_pct")
    cyc = fmean(rs, "cycles")
    ins = fmean(rs, "instructions")

    pkts = pps * PERF_WINDOW_S
    cpp = cyc / pkts                      # cycles / packet(CPU0,含產包+轉發)
    ipp = ins / pkts
    hash_cpp = cpp * oc / 100             # hash cycles / packet
    lookup_cpp = cpp * mc / 100           # lookup cycles / packet
    ratio = oc / mc * 100                 # hash 占 lookup path 比例

    fl = [int(x["flows"]) for x in rs]
    mt = rs[0]["masks_total"]

    print(f'{b:9} | {n:>2} | {oc:6.2f}±{ocs:5.2f} | {mc:6.2f}±{mcs:5.2f} | '
          f'{hp:7.2f} | {cpp:8.0f} | {hash_cpp:12.0f} | {ratio:8.1f}% | {soft:6.1f}')

    out.append([b, n, round(oc, 3), round(ocs, 3), round(osm, 3),
                round(mc, 3), round(mcs, 3), round(hp, 2), round(pps, 0),
                round(ipc, 2), round(soft, 1), round(cpp, 0), round(ipp, 0),
                round(hash_cpp, 0), round(lookup_cpp, 0), round(ratio, 1),
                min(fl), max(fl), mt])

with CSV_OUT.open("w", newline="") as fp:
    csv.writer(fp).writerows(out)
print(f"\n[OK] wrote {CSV_OUT}")
print(f"備註: sd=樣本標準差(n-1); cycles/packet 為 CPU0 全部工作(含 pktgen 產包)÷ 封包數;")
print(f"      hash_cycles_per_packet = cycles/packet × ohash_children%; 視窗={PERF_WINDOW_S}s。")
