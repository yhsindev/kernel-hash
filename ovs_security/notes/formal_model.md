# Part 1：形式化模型（攻擊 + bucket-load + PRF 防禦）

> 通用 hash-table robustness 的數學骨架,OVS 為特化案例。標記:**✅** = 已由文獻(deep-research 對抗式驗證,3-0)確認;**⚠️** = load-bearing,**你務必親自讀懂並回查 primary source**(末節集中列出)。本檔是「讀文獻的地圖」與報告數學草稿,不代替你的理解 —— 老師會問,你要能自己推。

記號:n = key 數,m = bucket 數,load factor `α = n/m`。bucket index `B(x) = H(x) mod m`。bucket b 的 load `L_b = |{ i : B(x_i)=b }|`,最大 load `L_max = max_b L_b`。

---

## 1. 攻擊模型(Crosby & Wallach 2003）✅

hash table（chaining）在**良性**輸入下,n 次 insert/lookup 約 O(n) total、O(1) amortized per op。**最壞**情況:若所有 key 落同一 bucket,該 bucket 退化成長度 n 的 linked list,每次操作掃 O(n);處理 n 個這種操作 → **Θ(n²) total**。

隨機輸入基準:n 個 key 全落「某一個」bucket 的機率
```
P(all in one specified bucket) = (1/m)^n
P(all in SOME single bucket)   = m·(1/m)^n = (1/m)^(n-1) = 1/m^(n-1)
```
→ vanishingly small,故最壞情況實際上**只在 adversarial 下發生**。這就是「bucket collision 是安全問題、不只是效能問題」的定義性論證。

三個必要前提(necessary preconditions,非完整形式化):① H deterministic 且攻擊者已知;② 攻擊者能預測/提供餵進 H 的輸入;③ 足量攻擊輸入抵達。外加 no-security-through-obscurity(假設原始碼已知)。對 OVS:操作是 **lookup**(無條件掃 chain),故 O(n) per-op 更直接成立。

---

## 2. Bucket-load 模型(balls-into-bins)

**理想化假設:** H 表現如 random function → `B(x_i)` 為 i.i.d. uniform on {0,…,m−1}(n 顆球丟 m 個桶)。

**單桶 load 分布** ✅(標準):
```
L_b ~ Binomial(n, 1/m),  E[L_b] = n/m = α
n,m 大、α 固定:  L_b ≈ Poisson(α),  P(L_b=k) ≈ e^(−α)·α^k / k!
```

**碰撞數** ✅:
```
C = Σ_b C(L_b, 2)        (C(·,2) = 取 2 組合)
E[C] = C(n,2)/m          (每一對 key 以機率 1/m 同桶)
```
這給良性 baseline:量到的 C 應接近 `C(n,2)/m`,三雜湊函式都該如此(RQ1)。

**最大 load 的尾界** ⚠️(須回查確切形式):由 Poisson/Chernoff 尾界
```
P(L_b ≥ t) ≤ (e·α / t)^t
union over m 桶:  P(L_max ≥ t) ≤ m·(e·α / t)^t
```
**推 L_max 量級(heuristic,須以 Raab-Steger 嚴格化):** 令上式 RHS ~ 1,取 α=1(n=m):
```
m·(e/t)^t ≤ 1  ⇒  t·ln(t/e) ≳ ln m  ⇒  t ≈ ln m / ln ln m
```
故 **`L_max = Θ(log n / log log n)`(α≈1,w.h.p.)** ⚠️。這是「防禦後」的健康上界,對應我們量到的小 probe / 短 chain。**此定理本研究 deep-research 未在 corpus 內逐字驗證 → 必須回查 Raab-Steger(1998,tight bound)與 Mitzenmacher-Upfal Ch.5(Poisson 近似 + max-load 推導)定稿。**

---

## 3. Adversarial key selection 的成本(攻擊核心)

### 3a. 公開 / unkeyed hash(jhash,seed=0)✅
攻擊者能**離線**算 `B(x)`。要湊 K 個 key 進選定的目標桶 b*:每個隨機候選命中 b* 機率 1/m → 期望約 m 次試得一個 → 離線成本
```
q_offline ≈ K · m        (每 key 幾何分布,期望 m 次)
```
結果 `L_{b*} = K`(攻擊者可控)。取 K = Θ(n) → 最壞 lookup O(n)、總 Θ(n²)。
(利用 hash 結構的構造法可把成本壓到 K·m 以下;對 lookup3 那是待做的 differential 分析,K·m 是保證下限。OVS seed=0 → 全程離線。)
**牆鐘成本(實測錨點 + 推導)與成本不對稱論證見 `attack_cost.md`**:bucket collision `K·m` 為亞秒級,full hash collision `K·2³²` 為單核小時級 / 多核分鐘級,且屬一次性、可平行、可重用的離線成本。

### 3b. Keyed PRF（siphash / hsiphash,secret key k）✅
`B_k(x) = H_k(x) mod m`。攻擊者不知 k → 無法離線算 B_k → 無法預選同桶 key。**√-bound(SipHash 論文 §7):** 對 strong PRF,找到一個碰撞對約需 √l 次猜測,之後每個同雜湊 key 約 l 次;湊 n 個 mutually-colliding key 須通訊 ~n·l ≈ n²(l≈n)個字串,故
```
amplification n ≤ √(攻擊者通訊量)        ← keyed PRF
amplification n ∝ 攻擊者通訊量(線性)     ← (弱或強)public hash
```
而且 keyed 下**無法鎖定特定 bucket b**(沒 key → 不知 mapping → 沒 feedback),只能盲目線上嘗試(rate-limited、可偵測)。→ keyed 是雙重困難(√-bound + 只能 online、無 offline 預算)。

---

## 4. Universal hashing / PRF 防禦的 reduction

**Carter-Wegman universal hashing** ✅:從合適 family `H` 隨機選 h,對任意 x≠y
```
Pr_{h←H}[ h(x)=h(y) ] ≤ 1/m
```
關鍵:h 在**獨立於 / 後於**攻擊者選輸入時抽出 → 任何固定 adversarial 輸入序列的期望碰撞被 1/m 壓住 → 期望 chain 長 O(1+α) → 期望 lookup O(1)。**防 HashDoS 的核心是「攻擊者無法事先知道實際 mapping」,不是雜湊的名字。** keyed PRF 是這想法的密碼學實例化。

**PRF reduction** ⚠️(須理解結構,條件式):視 `B_k(x)=H_k(x) mod m`。若 H_k 是 secure PRF,則對任意 efficient adversary A
```
| Pr[ A^{B_k} 成功 ] − Pr[ A^{B_R} 成功 ] | ≤ Adv^{PRF}_H(A)
```
B_R 用真隨機函數 R。對 R,攻擊者最佳 max-load 就是 §2 的 balls-into-bins `Θ(log n/log log n)`。故**在 strong-PRF 假設下,keyed hash 繼承隨機 baseline 的 robustness**。(條件於 SipHash 為 strong PRF —— 設計猜想,非已證定理;且繫於 key secrecy。truncation `H mod l` 仍為 strong PRF ✅,故可用低位元當 bucket index。)

---

## 5. OVS 特化(case study：通用模型被哪些系統因素改變)

**scope 決策(報告框架):** 本研究只替換 `flow_hash()`(雜湊函式那一層),**不重構 `find_bucket()`**。報告的攻擊主軸是**通用模型** `bucket = H(x) mod m`(Part 2);OVS 在其上的額外層(下述 hash_seed)是**案例特有**,在 Part 3 註明、不當主軸 —— 即「把更通用的攻擊情境寫進報告,而不只針對 OVS」。

- **兩層 bucket index(關鍵:OVS 不是 `H mod m`)**:OVS 實際 bucket 是
  ```
  bucket = jhash_1word( flow_hash(masked_key), ti->hash_seed ) & (n_buckets-1)
  ```
  `ti->hash_seed` 是 `get_random_bytes()` 的**隨機 32-bit seed**(每 table_instance 一個,resize 時重隨機)。即 OVS 在 flow_hash 之上於 find_bucket **還有一層隨機 seed 擾動**,與 flow_hash 選 jhash 或 siphash 無關。攻擊層次:
  - **targeted-bucket(只撞低位元)**:被隨機 seed 擋(不知 seed → 無法離線預測低位元);resize 重隨機更難。
  - **full flow_hash multicollision(輸出值完全相同)**:`jhash_1word(同值, seed)` 相同 → **同一 bucket,與 seed 無關**。對 unkeyed jhash 可離線構造,需**整 32-bit 輸出相等**;走法(固定目標值暴搜)與可行性見 §5a。
  - **keyed PRF flow_hash(siphash)**:攻擊者**連 flow_hash(x) 都算不出** → 無從構造。雙重防線。
  - 註:`hash_seed` 僅 32-bit、非密碼學 → 屬 Bar-Yosef-Wool「小 seed 可被遠端回復」那類;keyed PRF 的 128-bit key 不可暴破。
- **`n_buckets = m` 動態 resize**(約 ≥ n 的最小 2 次冪):resize 時 `ti` 與 hash_seed 一起換 → targeted-bucket 構造更不穩;full-multicollision 不受影響。
- **megaflow mask / wildcard → entropy budget**:攻擊者只能動 unwildcarded 欄位;若該區給 B 個自由位元,則相異 key 上界 `2^B` → 限制 `K ≤ 2^B` 與離線搜尋空間。**OVS 特有、可量化的攻擊面上界。**
- **TSS 多 mask**:每包查多個 mask(各一次 masked_flow_lookup);per-mask bucket 才是 chain-load 的對象(對照 Tuple Space Explosion 打的是 mask 維度,不同層)。

---

## 5a. 威脅模型與 entropy budget(Part 3 攻擊走法定案)

沿用 §1 的三前提。前提①(jhash2 seed 固定為 0、原始碼公開)與前提③(離線搜定後線上只需送 K 個封包)直接成立,真正的約束落在前提②。送入 `flow_hash()` 的不是攻擊者的原始封包,而是經 megaflow mask 蓋過後的 masked key,因此攻擊者能控制的只有「未被 wildcard、且自身可設值」的位元。記其數量為 B,則攻擊者能造出的相異 key 上界為 `2^B`。

**走法 (iii):seed-independent 的 full-hash collision。** 攻擊者先固定一個 32-bit 目標值 t,在 `2^B` 的可控空間裡離線搜出 K 個滿足 `jhash2(key)=t` 的 key。由於 `jhash_1word(t, seed)` 對任意 seed 都給出相同結果,這 K 個 key 會落進同一 bucket,與 §5 的隨機 `hash_seed` 無關,因此既不需要 differential、也不需要回復 seed。

每個候選命中 t 的機率為 `2^−32`,故離線成本約為 `K·2^32`;以 K=64 計約 `2^38` 次 jhash2(實測錨點下單核約 2.1 小時、本機 6 核約 21 分、64 核雲節點約 2 分,牆鐘推導見 `attack_cost.md`)。可行的條件是:`2^B` 空間內 `jhash2=t` 的期望命中數 `2^(B−32)` 要不小於 K,亦即 **B 至少要 `32 + log₂K`**(K=64 時為 38 bit)。

這裡門檻是 32 bit 而非 `log₂m`(=15),原因在於隨機 `hash_seed` 套在 `jhash_1word` 的外層:只讓 flow_hash 的低 15 位相同沒有用,seed 會把全 32 位重新打散後才取低位,所以攻擊者必須讓整個 32-bit 輸出相等。seed 的真正作用不是把 bucket 保密,而是把所需碰撞寬度從 15 bit 抬高到 32 bit,多吃掉 17 bit 的 entropy budget。

K 的取值由良性分布決定。良性表的 max chain 為 7,以 Poisson(α≈0.57) 估計 chain 長度達 12 以上的全表期望 bucket 數已低於 `10^−7`,良性流量下不可能自然出現這麼長的 chain。因此 demo 取 K 約 50 到 100,即可讓 `L_max` 高出良性一個數量級、在 `ovs_probelen` 上形成一根孤立尖峰,沒有與良性分布混淆的空間。

**B 在真實 OVS megaflow 下的上界:**

| 情境 | 可控 unwildcarded B | full-hash collision 可行? |
|---|---|---|
| stateless、可 spoof src IP | src IP 32 加 src port 16,約 **64** | 可行(需可 spoof 的轉發環境) |
| stateful ACL / conntrack、單機不可 spoof | 只剩 src/dst port,約 **16 到 32** | **不可行(B 小於 38)** |

值得注意的是,160-byte(post-conntrack)的 masked key 雖比 88-byte 長,但多出來的 ct 區(ct_state、ct_zone、ct_mark、ct_label、ct_orig_tuple)是由 conntrack 從連線推導、攻擊者無法直接設值的,所以 key 變長並不會增加 B。至於 B 約 32 的攻擊者,即使改去搜 multicollision,在 `2^32` 個值上撒 `2^32` 個 key 的最大重數也只有 10 上下,壓不過上面說的 12 這道門檻。

**攻擊前提。** 構造性 demo 要成立,需同時滿足三個條件:datapath 為 stateless(不走 conntrack)、port 沒有開 anti-spoofing(攻擊者能寫任意 src IP;一旦開了 `port_security` 或 OVN port_security,src IP 被鎖死,B 就跌回 16 到 32)、且攻擊者已在內部(惡意租戶、被攻陷的 workload,或 east-west 的橫向移動)。對應的三道系統機制是 megaflow wildcarding、conntrack 與 port security,任一存在都會讓 B 跌破 38。這是一類公認的雲端威脅,但明顯窄於 remote external 攻擊者。

**定案。** 在 OVS 真正暴露給不可信流量的部署(stateful security group 或 ACL)下,前提②被上述三道機制壓到 B 小於 38,brute-force full-hash collision 不可行;只有在「stateless、無 anti-spoofing、內部攻擊者」這個窗口裡才成立。據此 RQ3 的系統性結論是:通用模型所說的「unkeyed hash 可被離線攻破」在 OVS 被 masked-key 的 entropy budget 層層墊高門檻,攻擊面被壓縮到一個窄但真實的內部威脅面;Part 3 的 demo 須在此窗口下進行,並在報告中標明前提。

### 可控位元 B 的計算法(子系統通用,本研究的可移植產物)

要評估任何「用雜湊做 bucket 或索引」的核心子系統對 algorithmic-complexity attack 的暴露度,都可套同一套步驟,不限於 OVS:

1. **定位真正進入雜湊的輸入。** 重點不是攻擊者的原始輸入,而是經子系統 normalize、mask 或 canonicalize 後實際餵進 `H()` 的位元組。在 OVS 是 megaflow masked key,在其他子系統則是各自 transform 後的輸入。
2. **數出 B。** B 是同時滿足兩個條件的位元數:攻擊者可設值,且通過上述 transform 後仍進入雜湊輸入。凡被 mask、被 wildcard、由系統推導、或被 anti-spoofing 鎖死的位元都不計入。
3. **比對防禦設下的門檻。** 若是 unkeyed 的單層 `H mod m`,撞目標 bucket 只需低 `log₂m` 位,門檻為 `B ≥ log₂m + log₂K`;若 unkeyed 之上還有一層輸出擾動(如 OVS 的 `jhash_1word(·, seed)`),隨機 seed 會迫使整個輸出寬度相等,門檻升為 `B ≥ w + log₂K`,其中 w 是雜湊輸出寬度(OVS 為 32);若是 keyed PRF,則不論 B 多大,離線都得不到 feedback,攻擊不可行。
4. **判定。** 攻擊可行的條件是 B 不小於門檻,而 B 與門檻的差就是該子系統「輸入 transform 所提供的安全餘裕」。

這套方法的價值在於把「雜湊選得好不好」與「子系統把多少可控 entropy 餵進雜湊」拆成兩件事分別量化,而後者往往才是決定暴露度的主因。它可直接套用到其他以雜湊索引的核心路徑,例如 conntrack tuple hash、route cache(FIB)、nftables set、socket demux、dcache 等。

---

## 6. 理論 → 可量測指標

| 理論量 | 量測指標(已/將 instrument) |
|---|---|
| `L_max` | maximum chain depth ↔ worst-case probe count（安全頭條） |
| `L_b` 分布 | bucket chain-length 分布 ↔ probe-count 直方圖（`ovs_probelen`） |
| 均勻度 | normalized bucket entropy `H_norm = −(1/log m) Σ_b p_b log p_b`,`p_b=L_b/n`（uniform→1） |
| `C` | collision frequency;比對 baseline `E[C]=C(n,2)/m` |

---

## ⚠️ 你務必親自讀懂並查證的數學式(老師會問這幾條）

1. **balls-into-bins 最大 load**(§2)—— 尾界 `Pr[L_max≥t] ≤ m(eα/t)^t` 與結論 `L_max=Θ(log n/log log n)`(α≈1)。**這是 average-case 的中心結果,deep-research 未驗證 → 回查 Raab-Steger 1998 與 Mitzenmacher-Upfal Ch.5,確認確切定理與成立條件(尤其 α≠1 時的形式)。** 要能自己講「為什麼是 log n / log log n」。
2. **SipHash √-bound**(§3b)—— `n ≤ √(通訊量)` vs public 的線性。**回查 SipHash 論文 §7「Stopping advanced hash flooding」**,確認 √l / l 的推導,要能解釋「為何 keyed → √、public → 線性」。
3. **Carter-Wegman `Pr[h(x)=h(y)] ≤ 1/m` + PRF reduction**(§4)—— 回查 Carter-Wegman(universal class 定義 + 1/m bound)與標準 PRF 定義,要能講「random choice of hash 為何擋固定 adversarial 輸入」以及 reduction 的條件性(strong-PRF 假設 + key secrecy)。
4. **攻擊退化 + 隨機基準**(§1)—— `Θ(n²)` 與 `1/m^(n-1)`,回查 Crosby-Wallach,確認攻擊模型陳述。
5. **離線構造成本 `q_offline≈K·m`**(§3a)—— 幾何分布(每次命中 1/m)的期望;並把它接到 OVS 的 `entropy budget ≤ 2^B` 上界(§5),這是我們把通用成本模型「特化到 OVS」的原創接點。

> 建議讀的順序見 `README.md`;讀時對著上面 5 條「抽特定式子驗證」,不要冷讀全文。讀完我們再把 §2 的 `L_max` 與 §3b 的 √-bound 定稿(這兩條目前是 heuristic / 待你確認的)。
