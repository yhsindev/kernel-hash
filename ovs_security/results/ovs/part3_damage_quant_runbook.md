# Part 3 攻擊傷害量化 runbook（chain-walk → pps / CPU 退化）

目標:把 §4.4 的「結構退化」（chain 1→K、probe→K）推進成「**系統傷害**」——量出碰撞攻擊下 datapath 的 **pps 下降 / softirq CPU 上升**，並證明 (a) 傷害隨 K 線性成長、(b) keyed 雜湊把傷害壓回 baseline。此步用既有效能量測去量資安傷害,把專題的效能與資安兩半縫成單一論證。

> 與 §4.4 的關係:§4.4 用 DEBUG build 解釋**為什麼**會退化(probe 走滿 chain、16 條同 hash);本篇用**乾淨 build** 量**退化多少**(pps/CPU)。兩 build、兩用途,不可混用。

## §0 為什麼必須換乾淨 build（blocking）

現行 instrumented build（`flow_table.c` 頂端 `#define OVS_FLOW_HASH_DEBUG_LEN 1`）在熱路徑 `masked_flow_lookup()` 每包多夾兩個 `rdtsc_ordered()`（量 `ovs_hashcycles`）＋每節點一次 atomic64 increment（量 `ovs_probelen`）。這些開銷本身就會壓低 throughput → 量到的 pps 不是真實 datapath 的 pps。

**乾淨量測 build**:把 `OVS_FLOW_HASH_DEBUG_LEN` 設 `0` 重建。此時熱路徑與上游原版逐字相同(patch 已用 `#if/#else` 包好,`DEBUG_LEN 0` 走原版 `hash = flow_hash(...)`,無 rdtsc、無 probe 計數)。pps/CPU 在此 build 量。

> 代價:`DEBUG_LEN 0` 同時關掉 `ovs_buckets`/`ovs_probelen`/`ovs_keydump`。所以流程是「先 DEBUG build 確認碰撞集仍成立(keydump uniq -c、Lmax=K)→ 不動規則/流量,切乾淨 build reload → 量 pps/CPU」。碰撞集的正確性靠 DEBUG build 背書,傷害數字靠乾淨 build 取得。

## §1 量測模型:三向對照(實驗的智識核心)

傷害必須對照才有意義。對固定 K,在**同一個 mask shape、同一包速**下跑三條件,只變「IP 選擇」與「雜湊函式」一個變數:

| 條件 | 雜湊 | flow set | 預期 chain | 用途 |
|---|---|---|---|---|
| (a) attack | jhash | K 條 full-hash 碰撞 IP（全落 1 桶） | 長 = K | 傷害 |
| (b) benign 控制 | jhash | K 條**隨機 IP**（散在 ~K 桶） | ~1 | 隔離「chain walk」與「裝了 K 條 flow」 |
| (c) attack-keys | hsiphash/siphash | **同 (a) 那組碰撞 IP** | ~1（散開） | 證明 keyed 移除傷害 |

判讀:若 (a) 的 CPU/pps-loss ≫ (b),傷害確實來自 chain walk 而非 flow 數;若 (c) ≈ (b),keyed 雜湊把傷害消掉。三者放在同一張「cost-per-packet vs K」圖:**(a) 隨 K 線性上升,(b)(c) 平坦**——這一張圖同時是「攻擊有效」與「修法有效」。

控制要點:(b) 要用**同一 mask shape**(同樣的 OF 規則 priority/欄位,只把 nw_src/nw_dst 換成隨機不碰撞值),這樣每包走訪的 mask 數相同,唯一差別是目標桶的 chain 長度。

## §2 K ladder（讓傷害可量測）

K=16 的 chain walk(≤16 節點)可能太小,蓋不過固定 lookup 成本 → throughput 差異不明顯。需 scaling:

- K ∈ {16, 64, 128, 256}
- 構造成本 `K·2³²`,本機 ~280M jhash/s:K=256 ≈ 66 min 離線,可接受。
- 每包平均走 K/2 次 `flow_cmp_masked_key`(88B 比對);K=256 → 平均 ~128 次比對/包,足以在 pps/CPU 上產生清楚訊號。

```
cd ~/projects/kernel-hash/ovs_security/attack
for K in 16 64 128 256; do
  ./find_jhash_collision --base dv3b_base_template.txt --keys $K --threads $(nproc) --out keys_k$K.txt
done
python3 keys_to_rules.py keys_k256.txt --template attack4_template.txt \
  --rules-out /tmp/coll_rules_k256.txt --pairs-out /tmp/coll_pairs_k256.txt
```

benign 控制組(b)的隨機 IP 規則:用同一 template 但 IP 隨機(不過碰撞搜尋),產同數量規則/配對。

## §3 傷害指標與擷取（hands-on 監控由你跑）

datapath flow lookup 跑在收端 veth 的 **NET_RX softirq**。先 `mpstat -P ALL 1` 找出忙的那顆核,並把該 softirq pin 到單核(RPS/affinity 或確認單核),否則負載散開、per-packet 成本讀不出來。

1. **pps（headline）** — 兩種讀法,擇一或都做:
   - *飽和*:pktgen 全速灌,讀**遞送** pps（收端 netns 介面 rx 計數 delta 或 `ovs-ofctl dump-ports` n_packets/牆鐘）。攻擊下遞送 pps 較低。
   - *定速*:pktgen 固定 sub-saturation 速率,改量 CPU(下一項)。因果更乾淨,建議先做這個。
2. **softirq CPU** — `mpstat -P ALL 1` 看目標核 `%soft`;同包速下 (a) 的 `%soft` 應高於 (b)/(c)。
3. **cycles 落點(冒煙槍)** — `sudo perf top` 或 `perf record -g` 灌流量時看:(a) 應由 `masked_flow_lookup` / `flow_cmp_masked_key` 吃掉大半 cycle,(b)/(c) 不會。這把 pps 下降直接歸因到 chain walk。
4. **p99 lookup latency（phase 2,選做）** — 乾淨 build 量不到 per-lookup latency;若要 p99,另在 DEBUG build 把 hashcyc 樁從「只夾 flow_hash」擴成「夾整個 masked_flow_lookup」取 cycle 直方圖 → 算 p99。或直接用既有 `ovs_probelen` 當 latency proxy(probe 數 ∝ latency)。

## §4 執行順序(每個 K、每條件)

1. DEBUG build:裝規則(a/b/c)、灌流量、keydump `uniq -c` 確認碰撞成立、記 `ovs_buckets` Lmax + `ovs_probelen`(機制證據,沿用 §4.4 流程)。
2. 不動規則與流量腳本,切乾淨 build(`DEBUG_LEN 0`)reload 模組。
3. 鎖頻(`cpupower ... performance`、關 turbo),灌流量,`mpstat`+`perf` 取 pps/CPU。每 cell ≥3–5 次重複取中位數。
4. 換 K、換條件重跑;(c) 換 hsiphash/siphash build。

## §5 結果表(跑完填)

| K | 條件 | 遞送 pps | %soft@核 | perf top 首位 symbol | (對照 §4.4 probe-max) |
|---|---|---|---|---|---|
| 256 | (a) attack/jhash | | | (預期 masked_flow_lookup) | 256 |
| 256 | (b) benign/jhash | | | | ~1–2 |
| 256 | (c) attack/siphash | | | | ~1 |
| …  | … | | | | |

## §6 結論骨架（跑完寫）
- **傷害量化**:jhash 下碰撞攻擊使遞送 pps 下降 ___% / softirq CPU 上升 ___pp,且隨 K 線性惡化;perf 證實 cycle 集中於 chain walk。
- **修法有效**:同一組攻擊 key 在 hsiphash/siphash 下 pps/CPU 回到 benign 控制組水準 → keyed 雜湊以近乎零的固定 per-hash 成本(§4.5:x86-64 hsiphash≈jhash)換掉線性成長的 chain-walk 傷害。
- **caveats**:單 mask shape(隔離雜湊品質,不混 TSS);傷害量於乾淨 build、機制證據於 DEBUG build;K 上限受 masked-key entropy budget 與構造成本約束。

## §7 踩坑提醒(沿用 defense_sweep runbook)
- reload 用剛 build 的 srcversion;reload 後確認 datapath 重建。
- 絕不手動 `ovs-dpctl del-flows`(破壞 dpif 同步);清 OF 規則只 `ovs-ofctl del-flows br0`。
- 攻擊規則不含 NORMAL、不 match in_port。
- pktgen 先 `echo reset > pgctrl`、前景跑。
