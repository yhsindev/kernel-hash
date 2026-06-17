# Part 3（OVS case study）：真實 flow table 的 bucket-load snapshot（jhash / hsiphash / siphash）

`ovs_probelen`(查找過程的 probe-count,[part3_probe_dv3b.md](part3_probe_dv3b.md))的**靜態互補面**:用 `/sys/kernel/debug/ovs_buckets` 對真實 OVS flow table 取 bucket-load snapshot,得 chain-length 分布、Lmax、collisions,並由 user-space 算 normalized bucket entropy。與 Part 2 通用 harness 同一組指標,放在真實表上。

目的:確認良性(D-v3B)工作負載下,三個雜湊函式在真實表的**靜態** bucket 分布也都健康(非僅查找過程健康),作為 Part 3 攻擊情境(collision flow set)長 chain 的對照底噪。

> 狀態:**完成**(三 backend snapshot 已取得、指標已算、觀察已寫)。

## 量測條件

* 工作負載:D-v3B 多 mask 規則(`install_dv3b_multimask_rules.sh`),~18,785 flows;`pktgen_dv3b_multimask.sh` 灌流量填滿 datapath flow table。
* 平台:kernel 6.8.0-124-generic,OVS 2.17.9,自建 `openvswitch.ko`(`OVS_FLOW_HASH_DEBUG_LEN=1`)。
* 量測:`/sys/kernel/debug/ovs_buckets`(on-demand snapshot,走當前 `table_instance` 的 `ti->buckets`)。
* snapshot 時機:pktgen 跑動、datapath flow table 填滿(header `total_flows` ≈ 18k)時抓一次;idle 約 10s 會逐出,故不可在流量停後才抓。
* backend 身分(`nm -u`):jhash inline(無 import)、hsiphash `__hsiphash_unaligned`、siphash `__siphash_unaligned`。
* srcversion(本次 build):jhash `5B5A392BDB36BA343D4CB2F`、hsiphash `5CE9FA69221CD17DE039016`、siphash `BE6E49F56DE607A380BF59B`(每次 build 會變,以 `modinfo` 為準、`nm -u` 認 backend)。

## 原始 snapshot

```
# jhash    —— results/part3_buckets_jhash.txt
# n_buckets 16384 total_flows 15439 Lmax 7 nonempty 9905 collisions 7458
0 6479  1 5924  2 2737  3 987  4 214  5 35  6 7  7 1

# hsiphash —— results/part3_buckets_hsiphash.txt
# n_buckets 16384 total_flows 15443 Lmax 7 nonempty 10004 collisions 7209
0 6380  1 5971  2 2924  3 867  4 196  5 40  6 3  7 3

# siphash  —— results/part3_buckets_siphash.txt
# n_buckets 16384 total_flows 15443 Lmax 7 nonempty 10007 collisions 7270
0 6377  1 6011  2 2879  3 855  4 210  5 44  6 7  7 1
```

## 指標對照（`parse_ovs_buckets.py` 輸出）

| backend | n_buckets (m) | flows (n) | α=n/m | Lmax | collisions C | expected C | H_norm |
|---|---:|---:|---:|---:|---:|---:|---:|
| jhash | 16384 | 15439 | 0.942 | 7 | 7458 | 7274 | 0.9364 |
| hsiphash | 16384 | 15443 | 0.943 | 7 | 7209 | 7278 | 0.9379 |
| siphash | 16384 | 15443 | 0.943 | 7 | 7270 | 7278 | 0.9377 |

(expected C = n(n−1)/2m,uniform baseline;H_norm 趨近 1 = 接近均勻。)

## chain-length 分布（佔比）

（佔比 = 該 chain_len 的 bucket 數 / nonempty bucket 數;jhash nonempty=9905、hsiphash=10004、siphash=10007。）

| chain_len | jhash | hsiphash | siphash |
|---:|---:|---:|---:|
| 1 | 59.8% | 59.7% | 60.1% |
| 2 | 27.6% | 29.2% | 28.8% |
| 3 | 10.0% | 8.67% | 8.54% |
| 4 | 2.16% | 1.96% | 2.10% |
| 5 | 0.35% | 0.40% | 0.44% |
| 6 | 0.07% | 0.03% | 0.07% |
| 7 | 0.01% | 0.03% | 0.01% |

## 觀察

* **三者統計上不可區分、全部健康**:Lmax 都是 7、H_norm 都 ~0.937、α 都 ~0.94。collisions C 都落在 uniform baseline `E[C]=n(n−1)/2m` 的 ±2.5% 內(jhash 7458/7274=1.025、hsiphash 7209/7278=0.991、siphash 7270/7278=0.999),siphash 幾乎完全吻合。
* **靜態 snapshot 與動態 probe 互相呼應**:此處 Lmax=7 與 `ovs_probelen` 的 max probe(jhash 7 / hsiphash 8 / siphash 7,[part3_probe_dv3b.md](part3_probe_dv3b.md))同量級;chain-length 分布(集中在 1–3)亦與 probe 分布(集中在 0–2)一致。一個看靜態表結構、一個看查找過程,兩個獨立視角給出同一結論。
* **確認「良性下雜湊函式選擇不影響 bucket 分布品質」**:無論動態或靜態指標,三個雜湊函式皆符合 balls-into-bins 基準,彼此無實質差別。安全差異不在良性 baseline 顯現,須由攻擊性 collision flow set(Test 2)檢驗——這正是本 baseline 作為攻擊長 chain 對照底噪的用途。
* 次要:三次 snapshot 的 `total_flows` 都是 ~15.4k(< 安裝的 18,785 規則),因 snapshot 在 pktgen 跑動中抓取、datapath flow 隨 upcall 裝入與 idle 逐出而動;α≈0.94、量測點一致,三者可直接對照。

## 範圍限定

* 各 backend 單次 snapshot(計數乾淨但重複性未確認)。
* snapshot 為某一瞬間的 table 狀態;flow 數隨 upcall/逐出微動,header `total_flows` 記錄當下值。
* 良性 baseline;攻擊情境(collision flow set)見後續 Test 2。
