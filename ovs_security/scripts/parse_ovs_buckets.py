#!/usr/bin/env python3
"""parse_ovs_buckets.py — 從 /sys/kernel/debug/ovs_buckets 的 snapshot 算 bucket-load 指標。

Part 3(OVS case study)用:把真實 flow table 的 bucket-load snapshot 化成與 Part 2
同一組指標(Lmax、collisions C、expected C、normalized bucket entropy H_norm),
讓 OVS 真實表能直接對照通用模型 / 三個雜湊函式彼此。

snapshot 格式(ovs_buckets_show 輸出):
  # n_buckets <nb> total_flows <n> Lmax <L> nonempty <ne> collisions <c>
  # chain_len buckets
  <len> <count>
  ...

H_norm = -(1/log m) * Σ_b p_b log p_b,  p_b = L_b / n
       由 histogram 計:Σ_{L>0} hist[L] * (-(L/n) log(L/n)) / log m。
均勻分布趨近 1。expected C = n(n-1)/(2m)(uniform baseline)。

用法:
  parse_ovs_buckets.py jhash=results/part3_buckets_jhash.txt \\
                       hsiphash=results/part3_buckets_hsiphash.txt \\
                       siphash=results/part3_buckets_siphash.txt
  (label= 可省;省略時用檔名當 label)
"""
import sys
import re
import math


def load(path):
    nb = n = lmax = nonempty = coll = 0
    hist = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("# n_buckets"):
                kv = dict(re.findall(r"(\w+)\s+(\d+)", line))
                nb = int(kv.get("n_buckets", 0))
                n = int(kv.get("total_flows", 0))
                lmax = int(kv.get("Lmax", 0))
                nonempty = int(kv.get("nonempty", 0))
                coll = int(kv.get("collisions", 0))
            elif line and not line.startswith("#"):
                mobj = re.match(r"(\d+)\s+(\d+)$", line)
                if mobj:
                    hist[int(mobj.group(1))] = int(mobj.group(2))
    return dict(nb=nb, n=n, lmax=lmax, nonempty=nonempty, coll=coll, hist=hist)


def metrics(d):
    nb, n = d["nb"], d["n"]
    H = 0.0
    for L, cnt in d["hist"].items():
        if L > 0 and n > 0:
            p = L / n
            H += cnt * (-p * math.log(p))
    h_norm = H / math.log(nb) if nb > 1 else 0.0
    exp_c = n * (n - 1) / (2 * nb) if nb > 0 else 0.0
    alpha = n / nb if nb > 0 else 0.0
    return alpha, exp_c, h_norm


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)

    hdr = (f"{'backend':10} {'n_buckets':>9} {'flows':>7} {'alpha':>6} "
           f"{'Lmax':>5} {'C':>9} {'expC':>9} {'H_norm':>7}")
    print(hdr)
    print("-" * len(hdr))
    for a in args:
        label, _, path = a.partition("=")
        if not path:
            path, label = label, label.rsplit("/", 1)[-1]
        d = load(path)
        alpha, exp_c, h_norm = metrics(d)
        print(f"{label:10} {d['nb']:>9} {d['n']:>7} {alpha:6.3f} "
              f"{d['lmax']:>5} {d['coll']:>9} {exp_c:>9.0f} {h_norm:7.4f}")


if __name__ == "__main__":
    main()
