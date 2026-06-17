#!/usr/bin/env python3
"""parse_ovs_keydump.py — 解析 /sys/kernel/debug/ovs_keydump 印到 kernel log 的 masked-key dump。

Part 3(OVS case study)用:把 flow_key_insert() dump 的 masked-key 還原成位元組陣列,
依 (start, len) 分組,統計 stable / varying 位元組,並對 IPv4/UDP 分支解碼出
src_ip / dst_ip / src_port / dst_port,進而統計每筆實際呈現的 mask pattern
(哪些欄位被設定、哪些被 wildcard 成 0)。供 masked-key layout 推論與後續
controlled bucket-load measurement 的 group / 子集選擇。

輸入格式(dmesg 行,kernel timestamp 前綴會被忽略):
  ovs_keydump: start=<N> len=<L> hash=0x<H>
  ovs_keydump: 00000000: 0a 00 01 02 ...        (DUMP_PREFIX_OFFSET, 每列 ≤16 byte)

欄位錨定:以 eth.type=08 00(IPv4)在 region 中的位置 E 為錨,固定間距:
  ip.proto=E+4  ct_zone=E+8  tp.src=E+10  tp.dst=E+12  tp.flags=E+14
  ipv4.addr.src=E+16  ipv4.addr.dst=E+20
(由 struct sw_flow_key 推得;0x0000/0x00000000 視為 wildcard,顯示 '—'。)

用法:
  parse_ovs_keydump.py results/keydump_dv3b.log
"""
import sys
import re

HDR = re.compile(r"ovs_keydump: start=(\d+) len=(\d+) hash=0x([0-9a-fA-F]+)")
HEX = re.compile(r"ovs_(keydump|keymask):\s+([0-9a-fA-F]{8}):\s+((?:[0-9a-fA-F]{2}\s*)+)$")


def parse(path):
    """回傳 record list:每筆 dict(start, len, hash, key=bytes, mask=bytes|None)。

    mask 來自 ovs_keymask:(若 instrumentation 有印);沒有則為 None,
    decode 退回「值==0 視為 wildcard」的啟發式。"""
    records, cur, buf, mbuf = [], None, {}, {}

    def flush():
        if cur is not None:
            n = max([*buf, *mbuf]) + 1 if (buf or mbuf) else 0
            key = bytes(buf.get(i, 0) for i in range(n))
            mask = bytes(mbuf.get(i, 0) for i in range(n)) if mbuf else None
            records.append(dict(start=cur[0], len=cur[1], hash=cur[2],
                                key=key, mask=mask))

    with open(path) as f:
        for line in f:
            m = HDR.search(line)
            if m:
                flush()
                cur = (int(m.group(1)), int(m.group(2)), int(m.group(3), 16))
                buf, mbuf = {}, {}
                continue
            m = HEX.search(line)
            if m and cur is not None:
                dst = buf if m.group(1) == "keydump" else mbuf
                off = int(m.group(2), 16)
                for j, b in enumerate(m.group(3).split()):
                    dst[off + j] = int(b, 16)
    flush()
    return records


def anchor_ethtype(key):
    """找 eth.type=08 00(IPv4)的 region offset;找不到回傳 None。"""
    for i in range(0, len(key) - 1, 2):
        if key[i] == 0x08 and key[i + 1] == 0x00:
            return i
    return None


def decode_fields(key, mask=None):
    """以 eth.type 為錨,解碼 IPv4/UDP 5-tuple。

    某欄位是否「被設定」:有 mask 時看 mask 對應位元組是否非零(精確);
    無 mask 時退回值非零的啟發式(無法區分真值 0 與 wildcard)。
    被 wildcard 的欄位回傳 None。"""
    e = anchor_ethtype(key)
    if e is None or e + 21 >= len(key):
        return None
    be16 = lambda o: (key[o] << 8) | key[o + 1]
    ip = lambda o: ".".join(str(b) for b in key[o:o + 4])
    # set?:有 mask 看 mask,無 mask 退回 key 值非零
    src = mask if mask is not None else key
    setp = lambda o, n: any(src[o:o + n])
    return dict(
        proto=key[e + 4],
        src_port=be16(e + 10) if setp(e + 10, 2) else None,
        dst_port=be16(e + 12) if setp(e + 12, 2) else None,
        src_ip=ip(e + 16) if setp(e + 16, 4) else None,
        dst_ip=ip(e + 20) if setp(e + 20, 4) else None,
    )


def group(records):
    g = {}
    for r in records:
        g.setdefault((r["start"], r["len"]), []).append(r)
    return g


def stable_varying(recs):
    """回傳 (stable_positions, varying_positions),以 region offset 表示。"""
    n = min(len(r["key"]) for r in recs)
    stable, varying = [], []
    for i in range(n):
        vals = {r["key"][i] for r in recs}
        (stable if len(vals) == 1 else varying).append(i)
    return stable, varying


def fmt(v):
    return str(v) if v is not None else "—"


def emit_template(recs):
    """把單一 group 化成 find_jhash_collision 的 g_base 模板:
    每個 u32 word 跨全筆恆定者輸出其值,變動者輸出 0(= 可控/wildcard,留給搜尋填)。
    輸出每行一個 hex word,'# var' 標出變動 word。給 find_jhash_collision --base 讀。"""
    n = min(len(r["key"]) for r in recs)
    nwords = n // 4
    lines = [f"# template from {len(recs)} records, {nwords} words (88B = OVS L3 masked-key)"]
    for i in range(nwords):
        vals = {int.from_bytes(r["key"][4 * i:4 * i + 4], "little") for r in recs}
        const = len(vals) == 1
        val = next(iter(vals)) if const else 0
        tag = "" if const else f"   # var (word {i}, {len(vals)} distinct)"
        lines.append(f"0x{val:08x}{tag}")
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    path = args[0]
    records = parse(path)
    groups = group(records)

    if not records:
        print(f"# {path}: 0 records — log 為空。擷取時要有流量觸發 flow 插入"
              f"(pktgen 須在送、且 keydump 額度未耗盡)。", file=sys.stderr)
        sys.exit(1)

    if "--template" in args:
        # 取最大 group 出模板
        recs = max(groups.values(), key=len)
        print(emit_template(recs))
        return

    print(f"# {path}: {len(records)} records, {len(groups)} (start,len) group(s)\n")

    for (start, length), recs in sorted(groups.items()):
        sv_stable, sv_vary = stable_varying(recs)
        print(f"## group start={start} len={length}  records={len(recs)}")
        print(f"   varying region offsets: "
              + " ".join(f"0x{i:02x}" for i in sv_vary))

        decoded = [(r, decode_fields(r["key"], r["mask"])) for r in recs]
        ok = [(r, d) for r, d in decoded if d]
        if not ok:
            print("   (no IPv4 eth.type anchor found; skipping field decode)\n")
            continue
        e = anchor_ethtype(ok[0][0]["key"])
        print(f"   eth.type anchor E=0x{e:02x}  ->  "
              f"proto=0x{e+4:02x} sport=0x{e+10:02x} dport=0x{e+12:02x} "
              f"sip=0x{e+16:02x} dip=0x{e+20:02x}")

        # per-field presence (set vs wildcard) + distinct values
        for field in ("src_ip", "dst_ip", "src_port", "dst_port"):
            vals = [d[field] for _, d in ok]
            present = [v for v in vals if v is not None]
            distinct = sorted(set(present), key=lambda x: (str(type(x)), x))
            print(f"   {field:9}: set={len(present):>3}/{len(ok)} "
                  f"wildcard={len(ok)-len(present):>3}  distinct={len(distinct)} "
                  f"{distinct if len(distinct) <= 16 else ''}")

        # mask-pattern distribution: which of the 4 fields are present
        patt = {}
        for _, d in ok:
            key = tuple(f for f in ("src_ip", "dst_ip", "src_port", "dst_port")
                        if d[f] is not None)
            patt[key] = patt.get(key, 0) + 1
        print("   mask patterns (present fields -> count):")
        for k, c in sorted(patt.items(), key=lambda kv: -kv[1]):
            print(f"     {c:>4}  {', '.join(k) if k else '(all wildcard)'}")
        print()


if __name__ == "__main__":
    main()
