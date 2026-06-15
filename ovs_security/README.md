# 實驗三：OVS flow table 雜湊分布與抗碰撞分析（安全面）

本實驗對應專題「security-performance trade-offs」的 **security 半邊**：

| 實驗 | 資料夾 | 量什麼 |
|---|---|---|
| Experiment 1 | `hash_microbench/` | 雜湊函式純成本（cycles / instructions per hash） |
| Experiment 2 | `ovs_datapath_bench/` | OVS datapath 效能（throughput / pps / flow_hash cycles） |
| **Experiment 3** | `ovs_security/` | **OVS flow table 的雜湊分布品質與對 HashDoS 的抵抗** |

比較 `jhash2`、`hsiphash`、`siphash` 在 OVS flow table lookup path 的 **bucket 分布**與**抗碰撞**能力。核心安全論證：unkeyed 的 `jhash` 在攻擊者可控輸入下可被構造大量 collision，使 lookup 退化為最壞情況；keyed 的 `hsiphash` / `siphash` 因 secret key 不可預測而能抵抗此類 hashtable poisoning。

## 量測對象（OVS flow table 內部）

```
flow_hash(masked_key, &mask->range)
        └─> find_bucket(ti, hash) = &ti->buckets[hash & (n_buckets-1)]   ← 決定 bucket
                └─> 同 bucket 之 flow 串成 hlist chain
                        └─> masked_flow_lookup() 逐一比對
```

整張表共用 `ti->buckets`，所有 flow 依各自 `flow_hash` 散布。因此 bucket 分布即「`flow_hash` 把 key 打散得好不好」；切換雜湊函式即改變此分布。`masked_flow_lookup()` 走過的 hlist 節點數（probe count）直接反映 chain 長度。

## Metrics

| metric | 定義 / 量法 |
|---|---|
| bucket chain length | 每個 bucket 的 hlist 長度（需 table snapshot） |
| maximum chain depth | 上者的最大值 |
| lookup probe count | `masked_flow_lookup()` 每次走過的 hlist 節點數 |
| bucket entropy | 佔用分布的 Shannon entropy，`H = -Σ p_i·log2(p_i)`，`p_i = bucket_i flow 數 / 總 flow 數`；均勻分布趨近 `log2(n_buckets)` |
| collision frequency | chain ≥ 2 的 bucket 數，或 `Σ max(0, chain_len−1) / 總 flow 數` |

## Flow sets（對照組）

* **一般分布均勻度**：random flow、連續 IP flow、固定目的 IP、變動 source port。預期三種雜湊函式都散得不錯。
* **安全核心**：刻意搜尋 `jhash` collision 的 flow set —— 離線（`jhash2` seed 固定為 0）算出一組撞同 bucket 的 masked key，展示其在 `jhash` 製造病態長 chain，但在 keyed 的 `hsiphash` / `siphash` 下散開。這直接演示 keyed hash 對 **HashDoS** 的抵抗。

## Instrumentation

採 debugfs（複用 Exp1/2 的 `ovs_hashlen` pattern），全程以 `OVS_FLOW_HASH_DEBUG_LEN` gate，避免污染 cycle 量測。

| 介面 | 內容 | 狀態 |
|---|---|---|
| `/sys/kernel/debug/ovs_probelen` | `masked_flow_lookup` probe-count 直方圖（讀取 + 歸零） | 已完成 |
| table snapshot | 走 `ti->buckets` 算 chain length 分布 / max depth / entropy | 規劃中 |

kernel 端改動位於 `net/openvswitch/flow_table.c`（在 `kernel_work/`，被版控排除）；比照 Exp2 慣例以 patch diff 留存（見 `ovs_datapath_bench/patches/`）。

## 切換雜湊函式

編譯期 macro（`flow_table.c` 頂端）：

```c
#define OVS_FLOW_HASH_JHASH     1   /* 三選一 */
#define OVS_FLOW_HASH_HSIPHASH  0
#define OVS_FLOW_HASH_SIPHASH   0
```

改完 rebuild → `reload_ovs_module.sh <srcversion>` → 灌 flow set → 讀 debugfs。backend 身分以 `nm -u`（`__hsiphash_unaligned` / `__siphash_unaligned` import）確認，不靠 srcversion。

## 目前進度

* probe-count instrumentation 完成；**jhash baseline**（dv3b 多 mask 工作負載，~18,785 flows）：

  | probes | 0 | 1 | 2 | 3 | 4 | 5–7 |
  |---:|---:|---:|---:|---:|---:|---:|
  | 佔比 | 32.1% | 41.2% | 18.3% | 6.3% | 1.7% | 0.33% |

  `total_lookups` 49.3M、**max = 7、無 overflow、平均 ≈ 1.05 probes/lookup** —— 正常工作負載下 `jhash` 分布良好、無病態 chain（非攻擊情境）。

* 待做：hsiphash / siphash 在同工作負載的對照、table snapshot（entropy / chain length）、jhash-collision 攻擊（安全核心）。

## 待釐清

* `table_instance` rehash 時機與 `n_buckets` 計算 → 決定 collision 搜尋鎖定「固定 `n_buckets` 的低位元」還是「完整 32-bit hash 相等」。
* table snapshot 從 debugfs handler 取得 `dp->table` 的方式（全域指標 vs 遍歷 datapath；與 RCU / locking 相容）。
* megaflow wildcard 對「攻擊者可控 entropy」的限制：只有 unwildcarded 欄位是 collision 可操作的部分。
