#!/usr/bin/env python3
"""parse_bucket_bench.py — 從 run_bucket_bench.sh 的 raw 檔算 bucket-load 指標。

讀 HTB / HTB_hist 行,輸出每個 (mode,hash) 的:
  Lmax、collisions C、expected C、normalized bucket entropy H_norm。

H_norm = -(1/log m) * Σ_b p_b log p_b,  p_b = L_b / n
       由 histogram(load=L 的 bucket 數)計:Σ_L hist[L] * (-(L/n) log(L/n))。
均勻分布趨近 1;collision-vs-jhash 在 jhash 下應崩到接近 0。
"""
import sys
import re
import math

raw = sys.argv[1] if len(sys.argv) > 1 else "results/bucket_bench_raw.txt"
MODE = {"0": "random", "1": "seq_ip", "2": "fixed_dst",
        "3": "vary_srcport", "4": "collision"}

runs = []
cur = None
with open(raw) as f:
    for line in f:
        line = line.strip()
        if "HTB hash=" in line:
            # 去掉 dmesg 的 [timestamp] 前綴後再抽 key=value
            payload = line.split("HTB ", 1)[1]
            kv = dict(re.findall(r"(\w+)=(\S+)", payload))
            cur = {**kv, "hist": {}}
            runs.append(cur)
        elif "HTB_hist" in line and cur is not None:
            m = re.search(r"load=(\d+) buckets=(\d+)", line)
            if m:
                cur["hist"][int(m.group(1))] = int(m.group(2))

hdr = f"{'mode':12} {'hash':9} {'n':>6} {'m':>6} {'Lmax':>5} {'C':>9} {'expC':>6} {'H_norm':>7}"
print(hdr)
print("-" * len(hdr))
for r in runs:
    n = int(r["n"]); m = int(r["m"])
    H = 0.0
    for L, cnt in r["hist"].items():
        if L > 0:
            p = L / n
            H += cnt * (-p * math.log(p))
    Hn = H / math.log(m) if m > 1 else 0.0
    mode = MODE.get(r.get("mode", "?"), r.get("mode", "?"))
    print(f"{mode:12} {r['hash']:9} {n:6} {m:6} {r['Lmax']:>5} "
          f"{r['collisions']:>9} {r['expC']:>6} {Hn:7.4f}")
