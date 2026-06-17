# 雜湊函數在攻擊性 key selection 下的 bucket-load robustness（以 OVS flow table 為系統案例）

> 主體是**通用 hash-table robustness** 的數學模型與三種雜湊函式比較;Open vSwitch flow table 是**第一個系統驗證平台(case study)**,不是唯一主體。資料夾沿用 `ovs_security/`,但研究範圍不限於 OVS。

## 文件地圖(先看這裡)

**本檔(README)就是實驗三的總覽/index。** 研究分 **3 個 Part**,各檔對應如下:

| 編號 | 是什麼 | 檔案 | 狀態 |
|---|---|---|---|
| — | **總覽 / 計畫**(本檔):定位、RQ、結構、指標、進度 | `README.md` | — |
| **Part 1** | 形式化**數學模型**(攻擊模型 + balls-into-bins + PRF 防禦) | `notes/formal_model.md` | 初稿,數學待你查證定稿 |
| 〃 支撐 | **文獻基礎**(cited,信心分級) | `notes/related_work.md` | 完成 |
| 〃 支撐 | **攻擊成本分析**(離線構造牆鐘 + 成本不對稱,實測錨點) | `notes/attack_cost.md` | 完成 |
| **Part 2** | **通用 hash-table 實驗(主實驗)**:harness + run/parse | `bucket_bench/` | 完成 |
| 〃 結果 | Part 2 五組 flow set × 三雜湊的分布 | `results/part2_bucket_bench.md` | 完成 |
| **Part 3** | **OVS case study**:在真實 flow table 驗證 | kernel 樁 `patches/flow_table_debug_instrumentation.diff`(`ovs_probelen` + `ovs_buckets`) | 樁完成 |
| 〃 結果 | Part 3 OVS 真實表 probe-count baseline(動態) | `results/part3_probe_dv3b.md` | baseline 完成 |
| 〃 結果 | Part 3 OVS 真實表 bucket-load snapshot(靜態) | `results/part3_buckets_dv3b.md` | baseline 完成(三 backend);攻擊情境 TBD |

**三個 Part 一句話**:Part 1 = 數學;Part 2 = 不碰 OVS 的通用主實驗;Part 3 = 拿 OVS 驗證。對應 **RQ1/2/3**(見下,RQ1 通用良性、RQ2 通用攻擊、RQ3 OVS 特例)。
(命名note:早期曾用「Phase A/B」,已全部併入 Part 1/2/3。)

## 研究定位

unkeyed 雜湊(如 OVS 用的 `jhash`/Jenkins lookup3)的問題不是「一定會自然碰撞」,而是**攻擊者能離線篩選輸入**把大量 key 逼進同一 bucket;keyed PRF(`hsiphash`/`siphash`)的價值不是「不會碰撞」,而是**攻擊者不知 secret key 時無法離線預測 bucket mapping**,攻擊成本回到隨機嘗試。本研究用一個標準的 algorithmic-complexity attack 框架,比較三種雜湊函式在**良性**與**攻擊性** key selection 下的 bucket-load robustness。

## 研究問題

> **不同雜湊函數在攻擊性 key selection 下的 bucket-load robustness 為何?以 OVS flow table 作為系統案例。**

- **RQ1（通用,良性）**:良性輸入下,jhash / hsiphash / siphash 的 bucket 分布是否都接近 uniform-random baseline(balls-into-bins)?
- **RQ2（通用,攻擊）**:adversarial key selection 下,unkeyed hash 與 keyed PRF 的攻擊成本差在哪?(offline 預算 vs online-only;線性 amplification vs √-bound)
- **RQ3（OVS case study）**:通用模型放進真實 OVS datapath 後,哪些預測仍成立、哪些被 OVS 系統機制(seed、`n_buckets` resize、megaflow mask、flow-key entropy budget、TSS 多 mask)稀釋或改變?

## 研究結構

| Part | 內容 | 是否碰 OVS |
|---|---|---|
| **Part 1** | Literature-grounded formal model:攻擊模型 + balls-into-bins max-load + universal/PRF 防禦 | 否(理論) |
| **Part 2（主實驗）** | Generic hash-table robustness experiment:固定 n/m/α,三雜湊函式 × {random, structured, collision-searched} key set,量分布指標 | 否(獨立 harness) |
| **Part 3（case study）** | OVS flow table 驗證:同指標,討論 OVS 特例 | 是(延續實驗二 testbed) |

主結論來自 Part 2(乾淨、可控、可一般化);Part 3 是 real-system validation,不是唯一主體。

## 數學指標

n 個 key 雜湊到 m 個 bucket,load factor `α = n/m`。bucket b 的 load `L_b = |{x_i : B(x_i)=b}|`,其中 `B(x) = H(x) mod m`。

| 指標 | 定義 |
|---|---|
| maximum bucket load | `L_max = max_b L_b` ← 安全核心(對應 max chain depth / worst-case probe) |
| normalized bucket entropy | `H_norm = -(1/log m) · Σ_b p_b log p_b`,`p_b = L_b/n`;均勻→1 |
| collision count | `C = Σ_b C(L_b, 2)`;uniform baseline `E[C] = C(n,2)/m` |
| lookup probe count | 每次查找走過的 chain 節點數(我們已 instrument) |
| offline 構造成本 | `q_offline ≈ K·m`(湊 K 個 key 進目標 bucket,每個命中機率 1/m) |

理論對照:uniform-random 下 `L_max = Θ(log n / log log n)`(α≈1);adversarial + public hash 可達 `L_max = Θ(n)` → 查找 O(n)、總成本 Θ(n²)。

## Instrumentation

| 介面 / 工具 | 內容 | 狀態 |
|---|---|---|
| Part 2 generic harness | `bucket_bench/`:kernel module,用核心真正的 jhash2/hsiphash/siphash 對 key set 分桶,輸出 L_b 分布;附 run/parse 腳本 | 已建,待跑 |
| `/sys/kernel/debug/ovs_probelen` | OVS `masked_flow_lookup` probe-count 直方圖 | 已完成(Part 3) |
| `/sys/kernel/debug/ovs_buckets` | table snapshot:走 `ti->buckets` 出 chain-length 直方圖 + Lmax + collisions(entropy 由 user-space 算) | 已建,待跑(Part 3) |

kernel 改動在 `kernel_work/`(版控排除),以 patch 留存(`patches/flow_table_debug_instrumentation.diff`)。

## 切換雜湊函式

`flow_table.c` 頂端編譯期 macro `OVS_FLOW_HASH_{JHASH,HSIPHASH,SIPHASH}` 三選一 → rebuild → `reload_ovs_module.sh <srcversion>`。backend 身分以 `nm -u` 確認。

## 文獻

見 `notes/related_work.md`(cited、信心分級)、`notes/formal_model.md`(Part 1 數學)。閱讀順序:Crosby-Wallach(攻擊模型)→ Mitzenmacher-Upfal / Raab-Steger(balls-into-bins、max load、Chernoff)→ Carter-Wegman(universal hashing)→ Aumasson-Bernstein SipHash + Linux SipHash docs(keyed PRF)→ Klink-Wälde 28C3(實務 hash flooding)→ Tuple Space Explosion(OVS/TSS related work)。

## 目前進度

- Part 3 的 probe-count instrumentation(`ovs_probelen`)+ table snapshot(`ovs_buckets`)完成;OVS 真實表 jhash baseline(dv3b ~18,785 flows)平均 ~1.05 probes/lookup、max 7(見 `results/part3_probe_dv3b.md`)。
- 已 reframe 為通用 robustness 研究(本檔);Part 1 formal model 完成(`notes/formal_model.md`);Part 2 generic harness 建好(`bucket_bench/`,module 已 build,待 `sudo ./run_bucket_bench.sh`)。
- **下一步:(你)讀文獻定稿 §2 `L_max` / §3b √-bound;(回來後)跑 Part 2 harness 取得三雜湊函式 × {random/structured/collision} 的分布數據。**

## 待釐清

- balls-into-bins `Θ(log n/log log n)` 的確切定理陳述須回查 Raab-Steger / Mitzenmacher-Upfal。
- Part 2 harness 選 kernel module(用真核心雜湊、與 Exp1 一致)還是 user-space。
- collision-searched key set 對 jhash 的構造法(targeted-bucket + entropy budget 為主、lookup3 differential 為加分);keyed 實驗設計:用對 jhash 構造的 set,展示在 secret-key 的 hsiphash/siphash 下散開。
- OVS 特例對通用模型的修正:seed、`n_buckets` resize、mask wildcard 限制 entropy budget、TSS 多 mask。
