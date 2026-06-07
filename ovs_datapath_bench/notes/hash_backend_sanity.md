# OVS flow_hash() backend reload sanity

記錄每個 hash backend 換上 `net/openvswitch/flow_table.c::flow_hash()` 後的
reload + D-v2-mid sanity 結果。

**本檔只驗「修改過的 datapath module 是否仍正常載入並處理封包」，不含效能對照。**
jhash / hsiphash / siphash 的正式比較需另以 `perf` 量 fast-path `flow_hash()`
的 per-packet cycles，結果另行歸檔。

---

## 共同設定

- workload：D-v2-mid（200×50 = 10000 條 specific UDP port-pair rules，
  `install_irregular_udp_rules.sh` with `SRCMAX=20199 DSTMAX=9049`）
- pktgen：`SRCMIN=20000 SRCMAX=20199 DSTMIN=9000 DSTMAX=9049`
- 驗收標準：flows ≈ 9752、ns1↔ns2 ping 0% loss、pktgen `errors:0`

---

## backend 對照

| backend | srcversion | flows | masks | hit/pkt | ping | pktgen | 日期 | 備註 |
|---|---|---|---|---|---|---|---|---|
| jhash2 (default) | `E5822C0E…` (skeleton) | ~9752 | 2 | 1.03 | 0% loss | errors:0 | 6/5–6/7 | masks/hit-pkt 取自 6/4 同 workload（系統原版 jhash2）；6/5 skeleton sanity 僅記 flows~9752 / errors:0 |
| hsiphash | `1489A986…` | 9752 | 2 | 1.00 | 0% loss | 730395 pps, errors:0 | 6/7 | fixed `hsiphash_key_t`；64-bit 平台上 hsiphash 內部走 siphash 引擎。數據取自 6/7 controlled delta run（lost delta 10872，見附錄 A） |
| siphash | — | — | — | — | — | — | 未做 | 待實作 u64→u32 folding |

觀察：換 backend 後 `masks` / `hit/pkt` 不變（2 / ~1.0）。這是預期的——
`flow_hash()` 只負責計算 hash value，不影響 TSS 的 subtable 結構，所以 megaflow
的 mask 數與每封包查表次數與 hash function 無關。

---

## 重要：哪些 metric 不是 hash 效能指標

做正式 benchmark 前必須先分清楚每個數字屬於哪條路徑，否則會把無關的數字
誤當成 hash function 的效能差異。

| 指標 | 所屬路徑 | 受 `flow_hash()` 影響？ |
|---|---|---|
| `lookups: hit` | kernel fast-path（megaflow 命中） | 間接（hash 命中與否）；不是成本指標 |
| `lookups: missed` | userspace upcall path | ❌ 由 flow 是否已 install 決定 |
| `lookups: lost` | userspace upcall / netlink queue | ❌ install storm 副產品 |
| `pps`（pktgen Result） | 封包**發送端** | ❌ 受 CPU 排程、測試時長影響 |
| `masks total` / `hit/pkt` | TSS subtable 數 | ❌ 由 OpenFlow rule 形狀決定 |
| **`flow_hash()` per-packet cycles** | **kernel fast-path** | ✅ **這才是要比的對象** |

### lost 為什麼不是問題（6/7 hsiphash controlled delta run）

D-v2-mid 啟動瞬間，10000 個不同 (src_port, dst_port) 在 pktgen 全速（~730K pps）
灌入，每個第一次出現都觸發 upcall。vswitchd 的 upcall handler 一秒內被砸上萬個
install 請求 → netlink queue 滿 → 來不及收的封包記為 `lost`。

用 before/after counter delta（非累積值）量出**這次 run 真正新增的**：

| counter | delta |
|---|---|
| hit | 7 253 640 |
| missed | 25 942 |
| lost | 10 872 |

- **兩個獨立測量互證**：`missed` 的 counter delta（25942）≈ observe 逐秒在 t=3 抓到的
  單秒 `d_missed`（25940）。兩者吻合到個位數 → 整個 run 的 upcall 是一個「單秒事件」，
  10000 條 megaflow 在 t=3 那一秒全部 install，之後 `d_missed` 歸零、純 fast-path。
- `lost` delta 10872 / `hit` delta 7.25M ≈ **0.15%**，且穩態後不再增長。
- `missed` (25942) ≫ `flows` (9752)，比例 ~2.66:1：同 key 在 megaflow 裝好前的
  competing upcalls。被 `lost` 的封包後續同 key 會再 upcall，故 flow 最終仍完整裝到 9752。
- ping 0% loss → 穩態 datapath 完全正常。

結論：`lost` 反映的是 **userspace 的 install 吞吐上限**，與 fast-path 的
`flow_hash()` 計算成本無關。要比較 hash function，必須繞過這條路徑，直接量
fast-path 的 per-packet hash 成本（`perf`）。

---

## 正式 benchmark 待辦（不在本檔範圍）

- 用 `perf` 量穩態 fast-path 中 `flow_hash()` 的 cycles / instructions per packet
  （比照 Experiment 1 對裸 hash 的量法），在 jhash / hsiphash / siphash 間對照。
- 注意 64-bit 平台上 `hsiphash` 內部走 siphash 引擎，hsiphash 與 siphash 的成本
  差距可能不如 32-bit 平台明顯。

---

## 附錄 A：6/7 hsiphash controlled delta run 原始輸出

原始檔：`ovs_datapath_bench/results/hsiphash_d_v2_mid_delta_20260607/`。
保留為 sanity 佐證；數字不作效能解讀（理由見上節）。

### lookups counter delta（before → after，這次 run 新增量）
```
hit:    before=14696451  after=21950091  delta=7253640
missed: before=54566     after=80508     delta=25942
lost:   before=24819     after=35691     delta=10872
```
注意 before 的 lost 不是 0：`ovs-dpctl del-flows` 只清 datapath flows，不重置累積
counter，所以 delta（after−before）才是這次 run 的真實新增量。

### ovs-dpctl show（after）
```
lookups: hit:21950091 missed:80508 lost:35691
flows: 9752
masks: hit:22135647 total:2 hit/pkt:1.00
cache: hit:578294 hit-rate:2.62%
```
（EMC `cache` hit-rate 僅 2.62%：9752 flows 遠超 EMC 256-entry 容量，EMC 基本失效，
封包主要走 megaflow → 觸發 `flow_hash()`，正是要的工況。）

### observe_flows --watch 20（完整：啟動 → 穩態 → 結束）
```
t(s)   d_hit     d_missed   flows   masks   hit/pkt
2      0         0          0       0       1.01
3      569447    25940      9752    2       1.01    ← install storm：單秒 25940 upcalls
4      730843    0          9752    2       1.01    ← 已收斂，d_missed 歸零
...    (穩態 d_hit ~730K–755K 維持至 t=12)
13     8611      0          9754    3       1.00    ← pktgen 10s 結束
14–20  0         0          9752    -       1.00    ← 收尾
```
`missed` counter delta（25942）≈ observe t=3 單秒 `d_missed`（25940）→ 兩測量互證，
upcall 是單秒事件。

### pktgen
```
udp src 20000-20199 / dst 9000-9049 (both random), pkt_size=64, duration=10s
Result: 7279565 packets (64byte), 730395 pps, 373 Mb/sec, errors:0
```

### ping sanity
```
3 packets transmitted, 3 received, 0% packet loss
rtt min/avg/max/mdev = 0.082/0.094/0.109/0.011 ms
```
