# Part 2：通用 hash-table bucket-load robustness（jhash2 / hsiphash / siphash）

主實驗(與 OVS 無關)。用核心真正的雜湊把 n 個 flow key 分進 m 個 bucket,比較三種雜湊函式在作業指定的**五組 flow set** 下的 bucket-load 分布。

## 量測條件

- harness:`ovs_security/bucket_bench/hash_table_bench.c`(kernel module,核心真正的 `jhash2`(seed=0)/`hsiphash`/`siphash`)。
- `n = 4096` keys,`m = 4096` buckets(load factor α=1),5-tuple flow key(`key_len=16`:src_ip|dst_ip|src_port|dst_port|proto),`rng_seed=0x12345678`。
- 五組 flow set(key_mode):`random`(隨機 flow)、`seq_ip`(連續 IP,src_ip 遞增)、`fixed_dst`(固定目的 IP)、`vary_srcport`(只動 source port)、`collision-vs-jhash`(對 jhash seed=0 離線構造、全落單一 bucket)。
- 指標:`Lmax` 最大 bucket load、`C=Σ C(L_b,2)` 碰撞對數、`expC=C(n,2)/m=2047` 均勻基準、`H_norm` normalized bucket entropy(均勻→1)。
- 原始 dmesg:`part2_bucket_bench_raw.txt`。

## 結果

### 表 A：五組 flow set 的輸入比較(以 jhash2 為代表)

四組良性 key set 下三種雜湊函式分布同等(皆通過 Poisson 擬合,見下節),故以 jhash2 一列代表;碰撞組另見表 B。

| key set | Lmax | C | expC | H_norm |
|---|---:|---:|---:|---:|
| random | 6 | 2038 | 2047 | 0.9308 |
| seq_ip | 6 | 2065 | 2047 | 0.9308 |
| fixed_dst | 7 | 1994 | 2047 | 0.9326 |
| vary_srcport | 6 | 2002 | 2047 | 0.9320 |
| **collision-vs-jhash** | **4096** | **8,386,560** | 2047 | **0.0000** |

### 表 B：碰撞組下的 keyed vs unkeyed 對比(同一 collision set)

同一組「對 jhash 離線構造」的 collision set,餵入三種雜湊函式:

| hash | Lmax | C | expC | H_norm |
|---|---:|---:|---:|---:|
| jhash2(unkeyed) | **4096** | **8,386,560** | 2047 | **0.0000** |
| hsiphash(keyed) | 7 | 1994 | 2047 | 0.9323 |
| siphash(keyed) | 7 | 1985 | 2047 | 0.9327 |

collision 構造成本:`filled=4096/4096, tries=16,579,328`(≈ `K·m = 4096×4096 = 16,777,216`)。`C(4096,2)=8,386,560` 與 jhash collision 的 C 完全相等 → 4096 個 key 全在同一 bucket。

> 完整 3 雜湊 × 5 flow set 原始數據見 `part2_bucket_bench_raw.txt`;良性四組三雜湊的差異皆在抽樣誤差內。

## 解讀(對應 RQ 與 formal_model）

**RQ1（benign,四組;表 A)✓** —— random / seq_ip / fixed_dst / vary_srcport 下,三種雜湊函式**全部**接近 balls-into-bins 基準:`Lmax 5–8`、`C ≈ expC = 2047`、`H_norm ≈ 0.93`(`formal_model §2`)。重點:**連 low-entropy 的單欄位變動**(seq_ip 只動 src_ip;vary_srcport 只動 2-byte src_port)三種雜湊都打散得乾淨 —— 代表 jhash / hsiphash / siphash 的 avalanche 都夠好,**沒有任何一個對結構化良性流量出現聚集**。(siphash 在 fixed_dst / vary_srcport 偶見 `Lmax=8`,屬 balls-into-bins 正常變異,`H_norm` 仍 0.93,非聚集。)

**RQ2（adversarial;表 B)✓ —— 頭條** —— 同一組「對 jhash 離線構造」的 collision set:
- **jhash2**:`Lmax = 4096 = n`(全擠一桶)、`C = C(n,2)`(最壞)、`H_norm = 0`(entropy 崩塌)→ `formal_model §1` 的 **per-lookup O(n)、總 O(n²)** 被實現(`Lmax 6 → 4096`,~680×)。
- **hsiphash / siphash**:**同一組 key**,`Lmax = 7`、`H_norm ≈ 0.93` → 退回隨機基準,**完全不受影響**。

→ `formal_model §4` 的 PRF 防禦實證:攻擊者對 public jhash(seed=0)能離線構造 collision,但**無法預測 keyed hash 的 mapping**(hkey/skey 為祕密),故攻擊**不轉移**到 hsiphash/siphash。

## 良性分布對 Poisson 基準的擬合

§ 解讀(RQ1)觀察到三種雜湊函式在良性 key set 下分布相當。本節以 balls-into-bins 模型量化此觀察。模型:n 個 key 隨機落入 m 個 bucket(對應「雜湊近似 uniform random mapping」之假設);單一 bucket 的 load `L_b ~ Binomial(n, 1/m)`,當 n、m 大且 `α = n/m` 固定時收斂至 **Poisson(α)**。本實驗 n = m = 4096,故 α = 1。

random / jhash2 的實測 bucket-load 直方圖對 Poisson(1) 理論預測:

| bucket load k | 理論機率 P(k) | 理論桶數 m·P(k) | 實測桶數 |
|---:|---:|---:|---:|
| 0 | 0.368 | 1507 | 1521 |
| 1 | 0.368 | 1507 | 1471 |
| 2 | 0.184 | 753 | 768 |
| 3 | 0.061 | 251 | 271 |
| 4 | 0.015 | 63 | 52 |
| ≥5 | 0.004 | 15 | 13 |

各 bin 的觀測與理論差異落在抽樣誤差範圍內。Pearson χ² goodness-of-fit 為 **χ² = 4.96(df = 5,臨界值 χ²₀.₀₅(5) = 11.07)**,不拒絕「服從 Poisson(1)」的虛無假設。兩個衍生量亦與理論一致:碰撞對數實測 `C = 2038` 對 `E[C] = C(n,2)/m = 2047`;`H_norm` 實測 0.931 對 Poisson(1) 理論值 0.931(α=1 時 `P(0)=P(1)=1/e`)。

**詮釋:** bucket-load 服從 Poisson,表示雜湊對該 key set 的行為**在統計上不可與 uniform random function 區分**,無系統性偏移或聚集。三種雜湊函式在四組良性 key set 下皆通過此擬合,即為 RQ1 三者不可區分的依據;Poisson(α) 構成「隨機雜湊」的 null model 與各指標基準。`H_norm = 0.931 < 1` 非缺陷:Poisson 分布本身含空桶與多載桶,理想隨機雜湊在 α=1 的 `H_norm` 亦為 0.931。

**與攻擊對照:** collision-vs-jhash 下 jhash 的分布(4095 桶 load=0、1 桶 load=4096)為 Poisson 的退化反例,對 Poisson(1) 的 χ² 極大、強烈拒絕。由此,bucket distribution 的安全性可表述為對 Poisson 基準的 goodness-of-fit:良性輸入不拒絕;unkeyed 雜湊在 adversarial key selection 下強烈拒絕(load 向單一 bucket 集中,對應 O(n²) 退化);keyed PRF 因攻擊者無法預測 mapping,adversarial 下仍維持 Poisson 基準。

## 範圍與 caveats

- generic 主實驗(Part 2),非 OVS。OVS case study(Part 3,`ovs_probelen` + table snapshot)另行驗證通用結論在真實 datapath 是否成立。
- collision set 用 targeted-bucket brute-force 構造(`q_offline≈K·m`,實測 tries 16.58M ≈ 預測 16.78M;`formal_model §3a`)。lookup3 differential(更省、§3b/§5)為可選深化。
- 固定 `rng_seed`、α=1、每格單次。benign `Lmax` 數量級與 `Θ(log n/log log n)` 一致(n=m=4096 → ~4–8),確切常數待回查 Raab-Steger 定稿。
- 後續可掃 α(改 n_keys/n_buckets)描理論曲線。

## 重現

```bash
cd ovs_security/bucket_bench && make
sudo ./run_bucket_bench.sh          # 可用 N_KEYS / N_BUCKETS / KEY_LEN / RNG_SEED 覆寫
python3 parse_bucket_bench.py results/bucket_bench_raw.txt
```
