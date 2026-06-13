# 實驗二補充報告：以本機 OVN 量測 OVS kernel datapath `flow_hash()` 之真實 megaflow 輸入長度

> 狀態：初稿（P0 量測完成，待整體校閱）。
> 對應工具：自建 `openvswitch.ko` 之 `OVS_FLOW_HASH_DEBUG_LEN` 直方圖 + debugfs `/sys/kernel/debug/ovs_hashlen`。
> 量測日期：2026-06-14。本機單節點 OVN，OVS 2.17.9，kernel 6.8.0-124-generic。

---

## 1. 摘要

實驗二（`exp2_report.md`）以合成 pktgen multimask 工作負載比較 jhash / hsiphash / siphash 三種雜湊函式在 `flow_hash()` 的成本。該工作負載的 masked-key 長度由人工規則決定，**未必對應真實部署中 `flow_hash()` 實際看到的輸入長度分布**。本補充報告的目的，是在本機架設單節點 OVN，量測「真實 OVN 控制平面所產生的 megaflow」在 fast-path `flow_hash()` 被雜湊時的輸入長度（即 `range_n_bytes(&mask->range)`）。

主要量測結果：

- **stateless IPv4 流量的 masked-key 長度為單一值 88 bytes**，且不因 L2-switched 或經 logical router 的 L3-routed、亦不因 TCP / ICMP / UDP、或 IP 位址為 exact match 或 wildcard 而改變。
- **啟用 stateful ACL（conntrack）後，post-conntrack 的 lookup 之 masked-key 長度為 160 bytes**；在雙向（from-lport + to-lport）stateful ACL 下，88 與 160 的呼叫次數比為 **1 : 2**。
- 由此，stateful ACL 條件下每封包的 `flow_hash()` 工作量（以 byte-hash 計）約為 stateless 的 4.6 倍，且平均輸入長度由 88 升至約 136 bytes。

範圍限定：本報告為單節點、最小拓樸的受控量測，**非 production 流量側錄**。各條件目前各一次量測（計數量大、比例乾淨），尚未做重複性確認。

---

## 2. 背景與動機

`flow_hash()` 對 `[range.start, range.end)` 這段 masked key 計算雜湊；其 per-call 成本與**輸入長度**直接相關（見 `exp2_report.md` §7、實驗一的長度相依成本曲線）。因此「三種雜湊函式何者較省」這個問題的答案，取決於真實流量讓 `flow_hash()` 實際看到的輸入長度分布。

`exp2_report.md` 的 D-v3B 工作負載以人工 multimask 規則撐出長度差異，屬受控合成負載。本報告補上另一面：在真實 OVN pipeline 下，`flow_hash()` 的輸入長度實際落在哪裡。

研究問題：

> 在真實 OVN（logical switch / router / stateful ACL）所產生的 datapath megaflow 下，`flow_hash()` 被雜湊的 masked-key 長度分布為何？此分布應如何約束三種雜湊函式的比較條件？

---

## 3. 實驗目標與範圍

### 3.1 目標

1. 在本機建立可運作的單節點 OVN，使其產生具代表性的 L2 / L3 / stateful 邏輯 pipeline。
2. 在 kernel datapath 內就地量測每次 `flow_hash()` 呼叫的 `range_n_bytes`，得到頻率加權的長度直方圖。
3. 對照 `ovs-dpctl dump-flows -m` 的逐條 megaflow mask，解釋直方圖各峰值的來源。

### 3.2 本報告涵蓋（IS）

- masked-key 長度（`range_n_bytes` = `range.end - range.start`）這一個量，亦即 `flow_hash()` 的輸入長度。
- 受控、最小拓樸下的 L2、L2+L3、L2+stateful ACL 三種條件。

### 3.3 本報告不涵蓋（IS NOT）

- 不是 production 流量側錄；端點數、流量組成皆為人工。
- 不量雜湊函式成本本身（cycles）；本報告固定 jhash 雜湊函式，只量輸入長度。三種雜湊函式的成本比較見 `exp2_report.md` 與後續實驗。
- 未做多次重複與環境敏感度分析。

---

## 4. 方法學

### 4.1 量測樁：debugfs 直方圖

在自建 `openvswitch.ko` 的 `ovs_flow_hash_backend()` 包裝函式中，於 `OVS_FLOW_HASH_DEBUG_LEN` 條件下，對每次呼叫累加一個以 `hash_len`（即 `range_n_bytes`）為索引的 atomic 直方圖，並透過 debugfs 暴露：

- `cat /sys/kernel/debug/ovs_hashlen` — 印出 `total_calls`、`overflow(>=512)` 與各 `hash_len count`。
- `echo <任意> > /sys/kernel/debug/ovs_hashlen` — 將直方圖與計數歸零（灌測試流量前清乾淨）。

直方圖上界設為 512，足以涵蓋整把 `sw_flow_key`（見 §5.4）；超界者計入 `overflow` 以避免靜默漏計。模組身分以 `nm -u` 與 srcversion 驗證（見 `ovs-backend-identity-check`）；本次量測載入之 srcversion 為 `E38B8A00D1192D1A6ED286B`，jhash 雜湊函式（無 out-of-line siphash import）。

> 注意：此樁每封包都會跑（atomic inc），會污染 perf 的 cycle 量測，故量 cycle 時須關閉 `OVS_FLOW_HASH_DEBUG_LEN`。本報告只量長度，不量 cycle，故開啟無妨。

### 4.2 OVN 拓樸

單節點，本機 OVS 設為 OVN chassis（`ovn-remote` 指向本機 SB unix socket，geneve encap）。整合橋接 `br-int` 由 ovn-controller 自動建立。邏輯拓樸：

- logical switch `ls0`（10.1.0.0/24）：port `lp1`（10.1.0.1）、`lp2`（10.1.0.2）。
- logical switch `ls1`（10.2.0.0/24）：port `lp3`（10.2.0.3）。
- logical router `lr0`：連接 `ls0`（gw 10.1.0.254）與 `ls1`（gw 10.2.0.254）。
- 各 logical port 以 OVS internal port（`external-ids:iface-id`）落地到獨立 network namespace（`ns_a` / `ns_b` / `ns_c`）。

stateful 條件再於 `ls0` 加上 ACL：`ip4 && tcp` 之 `allow-related`（from-lport 與 to-lport 各一），及 `ip4` 之 `allow`（非 TCP 放行）。

### 4.3 工作負載

以 `ping`（ICMP）與 `iperf3`（TCP、UDP）在 namespace 間灌流量，每次量測前先 `echo reset` 歸零。三種條件：

- **L2 baseline**：`ns_a ↔ ns_b`（同網），ICMP + TCP + UDP 混合。
- **L2 + L3**：另加 `ns_a ↔ ns_c`（跨網，經 `lr0`）。
- **L2 + stateful ACL**：`ls0` 加 stateful ACL 後，`ns_a ↔ ns_b` TCP。

---

## 5. 結果

### 5.1 L2 baseline：單一長度 88 bytes

`total_calls = 8,049,436`，其中 `hash_len = 88` 佔 8,049,432，僅 `104`（×3）、`120`（×1）為 flow setup 階段零頭。`ovs-dpctl dump-flows -m` 顯示全部流量塌縮為 2 條 megaflow（每方向一條），且 IPv4 欄位全部 wildcard：

```
ipv4(src=0.0.0.0/0.0.0.0, dst=0.0.0.0/0.0.0.0, proto=0/0, tos=0/0, ttl=0/0, frag=no)
```

即不論灌 ICMP / TCP / UDP，純 L2 pipeline 將 L3/L4 全部 wildcard，megaflow 輸入長度為單一值 88。

### 5.2 加入 L3 routing：長度不變，仍為 88

`total_calls = 14,406,301`，`hash_len = 88` 佔 14,406,298（`104` ×3）。`dump-flows` 出現 6 條 megaflow，其中 routed flow 明確 unwildcard 了更多欄位：

```
ipv4(src=10.1.0.0/255.255.255.128, dst=10.2.0.3, proto=6, ttl=64, frag=no), tcp(src=0/0,dst=0/0)
```

惟封包數加總（≈14.4M）等於 `total_calls`，且幾乎全部落在 88。亦即 routed flow（src prefix、dst exact、proto、ttl 皆進 match）的 `range_n_bytes` 與純 L2 相同。routed flow 的 action 為 inline header rewrite（`set(eth...),set(ipv4(ttl=63))`），`recirc_id` 為 0，故每封包仍僅一次 `flow_hash()`。

**判讀**：unwildcard「更多欄位的值」不改變 `range` 的 byte span（見 §6 機制）。要改變長度需改變「出現哪些協定層」或啟用會延伸 key 的功能（conntrack）。此點與既有觀察一致（`ovs-megaflow-unwildcard`）。

### 5.3 加入 stateful ACL（conntrack）：出現 160 bytes，比例 1:2

512-cap 樁下，`total_calls = 9,556,178`，`overflow(>=512) = 0`：

| hash_len | count | 佔比 | 來源 |
|---|---|---|---|
| 88 | 3,185,415 | 33.3% | pre-conntrack lookup（`recirc_id=0`，match IPv4+TCP，action 為 `ct(),recirc`）|
| 160 | 6,370,763 | 66.7% | post-conntrack lookup（recirc 後，match `ct_state` 等 ct 欄位）|

`dump-flows` 對照：`recirc_id=0` 的 pre-ct flow 帶 `ct_state(0/0)`、action 為 `ct(zone),recirc`；`recirc_id` 非 0 的 post-ct flow 帶 `ct_state(0x22/0x3f)` 等已被 conntrack 標記之值。

兩點觀察：

1. **post-conntrack 的 masked-key 長度為 160 bytes**（stateless 為 88）。
2. **88 : 160 的呼叫次數比恰為 1 : 2**（3,185,415 : 6,370,763 = 1 : 2.0001）。每封包 1 次 pre-ct（88）+ 2 次 post-ct（160）；2 次 post-ct 源於 stateful ACL 同時掛在 from-lport（ingress zone）與 to-lport（egress zone），兩段 conntrack 各觸發一次 recirculation 與一次長 key lookup。

### 5.4 `sw_flow_key` 欄位 offset（佐證）

模組載入時印出（bytes）：

```
sizeof(sw_flow_key)=472  phy=320  eth=340  ip=364  tp=370  ipv4=376  ipv6=376  ct=448
```

非 tunnel flow 的 `range.start` 由 `rounddown(offsetof(phy), 8) = 320` 起算。conntrack 的 ct 欄位（`ct_state` 及尾端 `ct { orig_tp, mark, labels }`）位於 key 尾端（`ct=448`，至 key 結束 472），故 conntrack match 會把 `range.end` 拉到接近 key 尾端——與實測 post-ct = 160 bytes 一致。

---

## 6. 機制：長度由協定層 / conntrack 量子化，而非 flow 精細度

`range` 的計算在 netlink 解析時由 `update_range()`（`flow_netlink.c`）完成：

```c
size_t start = rounddown(offset, sizeof(long));   /* sizeof(long)=8 */
size_t end   = roundup(offset + size, sizeof(long));
/* range = 對「每個被寫入 mask 的欄位」取 [start,end) 的聯集 */
```

因此 `range` 是「所有被觸碰的 key 欄位」之 8-byte 對齊**連續聯集**，而非 unwildcard 欄位的個數。關鍵在於：userspace（ovs-vswitchd）依封包出現的協定層送出 mask attribute——只要 `eth_type = 0x0800`，即送出 `OVS_KEY_ATTR_IPV4`（即使所有 IP 子欄位 mask 為 0/wildcard），於是 `range` 被撐到 ipv4 區段。

由此可解釋 §5：

- 凡 IPv4 封包（L2-switched 或 L3-routed、TCP 或 ICMP、位址 exact 或 wildcard）皆送 IPV4 attr → `range` 涵蓋至 ipv4 區 → 長度同為 88。
- 改變 L3/L4 欄位的值只改 mask 的內容，不改 `range` 的 span。
- conntrack 使 datapath flow 帶 ct 欄位 match → `range` 延伸至 key 尾端 ct 區 → 長度跳至 160，且 recirculation 使每封包的 `flow_hash()` 呼叫次數倍增。

亦即 `flow_hash()` 的 per-call 輸入長度**不是連續分布，而是被「協定層 / 是否走 conntrack」量子化為少數離散值**。

---

## 7. 對三種雜湊函式比較的意義

以本次 stateful ACL 條件估算每封包的 `flow_hash()` 工作量（以 byte-hash = 長度 × 呼叫次數 計）：

| 條件 | 每封包 flow_hash | byte-hash / 封包 |
|---|---|---|
| stateless IPv4 | 1 × 88 | 88 |
| stateful（雙向 ACL）| 1 × 88 + 2 × 160 | 408 |

stateful 約為 stateless 的 4.6 倍；該條件下平均輸入長度約 136 bytes（88×⅓ + 160×⅔）。

推論（待後續實驗證實）：真實 OVN 部署（如 ovn-kubernetes 普遍使用 stateful ACL）中，`flow_hash()` 的輸入以 88 與 160 的混合為主、且 160 佔約 ⅔。三種雜湊函式（jhash / hsiphash / siphash）的成本比較**應在 88 與 160 兩個長度上進行，且 160-byte 路徑權重更高**。`exp2_report.md` 的 D-v3B 合成負載僅覆蓋單一 mask（一個長度點），本結果指出其代表性的限制。

---

## 8. 範圍限定與後續

### 8.1 限定

- 單節點、最小拓樸（3 端點、1 router、單一 stateful ACL 規則組），非 production 流量組成。
- 各條件目前各一次量測。計數量大且比例乾淨（1:2 精確至四位），但重複性尚未確認。
- 1 : 2 比例與雙向 ACL 的 pipeline 設定綁定；不同 ACL 方向 / zone 設計會改變比例，原因待逐項釐清。
- 量測固定 jhash 雜湊函式；本報告不主張任何雜湊函式的成本優劣。

### 8.2 後續（範圍限定）

1. 將 OVN testbed 設定與 reload 後的 port rebind 收成可重跑 script，使換雜湊函式的 reload 可重複。
2. 在 88 與 160 兩個長度上比較三種雜湊函式的 per-call 成本（microbench 或 OVN 流量驅動的 perf），先不擴張拓樸規模。
3. debugfs instrumentation 因 `kernel_work/` 被版控排除，須另存為 patch diff 納入 repo（比照 `ovs_flow_hash_backend_patch.diff`）。
