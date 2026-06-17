# Part 3 防禦掃描：jhash vs hsiphash vs siphash（攻擊下的 bucket-load + per-hash 成本）

把同一組 jhash 碰撞集(`keys4`,K=16,target `0xcaa92980`)植入真實 OVS datapath,於三個 hash backend 下量靜態 bucket-load(`ovs_buckets`)、動態 probe(`ovs_probelen`)、in-context per-hash cycle(`ovs_hashcycles`)。證明:jhash 單桶崩潰、hsiphash/siphash 散開回 baseline,且量化防禦的 per-hash 成本。

> keyed-hash 金鑰為 **per-boot 隨機**(`ovs_flow_init` 以 `get_random_bytes` 填,比照 OVS `ti->hash_seed`)→ 部署等級條件。

## 狀態

**完成**。三 backend × attack 全跑,靜態/動態/per-hash 三證據一致。流程見 `part3_defense_sweep_runbook.md`。

## 量測條件

* 平台:kernel 6.8.0-124-generic(x86-64),自建 `openvswitch.ko`,各 backend 由 `flow_table.c` 編譯期 macro 切換、各自 `make clean` 重建並 reload(`nm -u` 驗身分:jhash 無 import、hsiphash `__hsiphash_unaligned`、siphash `__siphash_unaligned`)。
* 攻擊集:`keys4`(16 個完整 jhash 碰撞)→ 16 條 `priority=100,ip,nw_proto=17,nw_src,nw_dst,actions=output:2`(不含 NORMAL、不 match in_port);`pktgen_pairs.sh` 逐對灌,每對 500 包 × ~4 輪。
* cycle 量測:CPU 鎖頻(performance governor + no_turbo);`ovs_hashcycles` 以 `rdtsc_ordered()` 夾 `flow_hash` call site;報 mode − `rdtsc_pair_overhead_min`(本機 = 29 cyc);只取 88B 純 keys4 的主峰,忽略 IRQ outlier 長尾。
* x86-64 上 hsiphash = **SipHash-1-3**、siphash = **SipHash-2-4**(`lib/siphash.c`)。

## 對照矩陣

| backend | attack Lmax | collisions | probe-max | keydump（16 flow 的 in-kernel hash） | in-ctx per-hash（mode−29） | microbench@88B（isolated） |
|---|---:|---:|---:|---|---:|---:|
| jhash | **16** | 120 | **16** | 16×**同** `0xcaa92980` | ~**134** cyc（mode 163） | ~85 |
| hsiphash | **1** | 0 | **1** | 16×**不同** | ~**138** cyc（mode 167） | ~78 |
| siphash | **1** | 0 | **1** | 16×**不同** | ~**205** cyc（mode 234） | ~130 |

raw:`results/part3_{buckets,probe,hashcyc}_attack_{jhash,hsiphash,siphash}.txt`。collisions=C(16,2)=120 對應 jhash 16 條同桶;keyed 兩者 0。

## 觀察

* **防禦成立且來自金鑰**:同一組 keys4 在 jhash 下單桶 `Lmax=16`、probe 走滿 16;在 hsiphash/siphash 下散成 `Lmax=1`、probe=1、16 個各不相同的 in-kernel hash。差別純粹是「第 1 段 flow_hash 有無祕密金鑰」,與 backend 是 1-3 還是 2-4 rounds 無關。
* **per-hash 成本(in-context)**:jhash 134 ≈ hsiphash 138 < siphash 205。**hsiphash 在 x86-64 上幾乎零成本防禦**;siphash ≈ jhash 的 **1.53×**。此比值與 microbench 的 130/85≈1.53 **一致**,in-context(絕對值較高,含 cache/pipeline/呼叫開銷)與 isolated 相對排序互相印證。
* **成本不對稱**:keyed hash 多付的固定 per-hash 開銷(hsiphash 近 0、siphash +71 cyc),遠小於它擋掉的 chain-walk —— jhash 每次查找走到 16 節點(規模化 O(K)),keyed 維持 1。
* **靜態↔動態一致**:`ovs_buckets` 的 Lmax 與 `ovs_probelen` 的 probe-max 在每個 cell 都吻合(jhash 16/16、keyed 1/1)。

## 範圍限定

* K=16(結構性對照足夠;OVS megaflow mask 限制可控 entropy,規模化意義有限,故未掃大 K)。
* per-hash cycle 為 in-context mode−overhead、已鎖頻;此 instrumented build 每包多兩個 `rdtsc_ordered`,**不用於 throughput** 量測。microbench 為 isolated hot-loop 的相對成本。
* hsiphash 在 x86-64 = SipHash-1-3(強);32-bit 平台會退化為 HalfSipHash1-3(較弱),安全性具平台依賴性——本結論限 64-bit。
* 防禦針對「離線預構碰撞」威脅;key-recovery / online adaptive 等更強模型超出本範圍。
* benign baseline(三 backend 健康)見 `part3_buckets_dv3b.md` / `part3_probe_dv3b.md`。
