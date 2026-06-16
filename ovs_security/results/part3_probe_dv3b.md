# Part 3（OVS case study）：真實 flow table 的 probe-count baseline（jhash / hsiphash / siphash）

OVS case study 的良性 baseline。非攻擊的結構化工作負載下,三種雜湊函式在**真實 OVS flow table** 的 `masked_flow_lookup` probe-count 分布對照(經 `/sys/kernel/debug/ovs_probelen`)。目的:確立「正常流量下雜湊函式選擇不影響 bucket 分布品質」,作為 Part 3 攻擊情境(jhash-collision,TBD)的對照基準。

> 命名note:本檔早期稱「Phase A」,已併入 Part 3(OVS case study)。

## 量測條件

* 工作負載：D-v3B 多 mask 規則（`install_dv3b_multimask_rules.sh`），~18,785 flows；`pktgen_dv3b_multimask.sh` DURATION=15s。
* 平台：kernel 6.8.0-124-generic，OVS 2.17.9，自建 `openvswitch.ko`（`OVS_FLOW_HASH_DEBUG_LEN=1`）。
* 量測：`/sys/kernel/debug/ovs_probelen`（`masked_flow_lookup` 每次走過的 hlist 節點數）。
* backend 身分（`nm -u`）：jhash inline（無 import）、hsiphash `__hsiphash_unaligned`、siphash `__siphash_unaligned`。
* srcversion：jhash `362C7A7C537732CF315FF72`、hsiphash `FD9FF3346CCC7C721F6D665`、siphash `1C79A38978E031EEDCE62ED`。

## 原始計數

```
# jhash    total_lookups=49269142  overflow=0
0 15832383  1 20306889  2 8996856  3 3119947  4 849518  5 66556  6 96615  7 378

# hsiphash total_lookups=48855651  overflow=0
0 14533409  1 19655554  2 9938216  3 2862805  4 1749564  5 90496  6 25312  7 135  8 160

# siphash  total_lookups=40505110  overflow=0
0 11092320  1 16162473  2 10298584  3 2332738  4 511415  5 95494  6 12072  7 14
```

## 分布對照（佔比）

| probes | jhash | hsiphash | siphash |
|---:|---:|---:|---:|
| 0 | 32.1% | 29.7% | 27.4% |
| 1 | 41.2% | 40.2% | 39.9% |
| 2 | 18.3% | 20.3% | 25.4% |
| 3 | 6.3% | 5.9% | 5.8% |
| 4 | 1.7% | 3.6% | 1.3% |
| 5 | 0.14% | 0.19% | 0.24% |
| 6 | 0.20% | 0.05% | 0.03% |
| 7 | 0.0008% | 0.0003% | 0.00003% |
| 8 | — | 0.0003% | — |
| 平均 probes/lookup | ~1.05 | ~1.14 | ~1.14 |
| max | 7 | 8 | 7 |

## 觀察

* 三者分布幾乎一致、都健康：平均 1.05–1.14 probes/lookup、max ≤ 8、無 overflow、無病態長 chain。
* jhash 在此工作負載略緊（平均 1.05），但差距小、各為單次量測，不宜過度解讀。
* 正常（非攻擊）流量下，雜湊函式選擇不影響 bucket 分布品質。安全差異不在此顯現，須由 Part 3 的刻意 collision flow set 檢驗。
* 次要（弱）：相同 15s 下 siphash `total_lookups`（40.5M）< hsiphash / jhash（48.9 / 49.3M），方向與「siphash per-call 成本最高」一致；但 DEBUG 樁在跑、非乾淨 perf 量測，僅供參考。
