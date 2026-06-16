# 實驗三文獻基礎：HashDoS、碰撞構造與 PRF 防禦

> 來源：deep-research（fan-out 搜尋 + 對抗式驗證,2026-06-15）。每條主張標註信心等級;高信心 = 從 primary source 逐字驗證且 3-0 通過。**標示「待補」者尚未在本輪驗證通過,引用前須自行查證 primary source。**

對應四個需求:**(a) 攻擊模型 / (b) 可實作的碰撞構造法 / (c) max-load 數學 / (d) PRF 防禦論證**。

---

## 1. 攻擊模型 — Crosby & Wallach 2003〔canonical, 高信心〕

**Crosby & Wallach, "Denial of Service via Algorithmic Complexity Attacks," 12th USENIX Security Symposium, 2003.**

- 三個**必要前提**(必要、非完整形式化):① 雜湊函式 deterministic 且攻擊者已知;② 攻擊者能預測/提供所有餵進雜湊的輸入;③ 足量攻擊輸入抵達受害者。外加明確的 no-security-through-obscurity 立場(假設攻擊者有原始碼)。
- 核心威脅數學:chained hash table 從 O(n) 退化到 **O(n²) total / O(n) per-op**,當輸入被逼進單一 bucket(表「degenerates to a linked list」)。
- 隨機輸入基準:n 個物件全落同一 bucket 的機率僅 **1/b^(n-1)**(b 個 bucket)→ 最壞情況實際上只在 adversarial 下發生。
- 對 OVS 的對應:操作是 **lookup**(無條件掃整條 chain),故 O(n) per-op 更直接成立。
- **框架注意**(來自 2-1 票):這三條是必要前提,不是完整形式化;論文後續還加上「攻擊者須理解 insertion 前的資料處理、可能須窮舉算出 colliding 輸入、可能不知 bucket 數須推測、面對 search-space reduction」。引用時寫「necessary preconditions」並搭配後續的 collision-computation 討論,別當成封閉模型。

---

## 2. 碰撞構造法 — 按雜湊弱點分級〔高信心;但無一針對 jhash〕

碰撞構造的難度取決於雜湊的代數結構。文獻給的是一道「弱→強」的階梯:

| 雜湊類型 | 構造法 | 成本 | 來源 |
|---|---|---|---|
| pure-XOR(Bro IDS、Linux protocol stack) | 直接代數:GF(2)-linear → preimage 是 kernel 的 **affine subspace (coset)** | 每個 32-bit target 直接得 2^16 個輸入 | Crosby-Wallach 2003 |
| DJBX33A(PHP5、Java `String.hashCode`,linear multiplicative) | **equivalent substrings**:短 colliding 對(h('Ez')=h('FY'))串接 → 2^n/3^n multicollision | 近乎零額外搜尋 | Klink & Wälde, 28C3, 2011 |
| DJBX33X(PHP4、Python、v8,nonlinear) | **meet-in-the-middle**:用 modular inverse(33·1041204193≡1 mod 2³²)把 mix 倒著跑,前綴 forward × 後綴 backward | TMTO,~2^16 預算表 | Aumasson, Bernstein & Boßlet, 29C3, 2012 |
| MurmurHash2/3、CityHash64(strong non-crypto) | **inject-and-cancel 差分分析**:在 k1 注入差分 D1,下一塊用 D2 抵消使 state 差回 0;**結果與 seed 無關(universal)** | 鏈接 n 對 → 2^n collision | Aumasson, Bernstein & Boßlet, AppSec12/29C3, 2012 |

**對我們最關鍵的一點:以上沒有一個針對 Jenkins lookup3 / jhash。** 所以**對 lookup3 的碰撞構造是我們自己的實作工作**(genuine work,不是文獻查得到的),這正是專案的技術貢獻之一。可轉移的技術(依適用度排序):

1. **inject-and-cancel 差分分析**(最有希望)—— lookup3 是 ARX-style mix(add/xor/rotate),與 MurmurHash 同類,差分法最對路;須自行推導 lookup3 `mix()`/`final()` 的 differential trail。
2. **meet-in-the-middle** —— lookup3 的 mix 與 final 步驟可逆,可倒著跑。
3. **linear-subspace** —— 針對 lookup3 任何近線性的成分。
4. **(baseline)targeted-bucket brute force** —— 對 m 個 bucket,平均 m 次試得一個落在目標 bucket 的 key;K 個要 O(K·m)。最易實作,當作對照下限。OVS seed=0 unkeyed → 整個搜尋可離線。

> 被否決、勿引用:Crosby-Wallach 的「Perl 5.6.1,30 分鐘找到 46 個 zero-hashing generators,46³≈97k collision」這個逸事兩次驗證都無法逐字確認(1-2、0-3)。原理(找 generator 映射初始 state 到自身再串接)是對的,但別引用那個具體數字,除非自己回查 primary source。

---

## 3. PRF 防禦〔高信心〕

**數學基礎 — Carter & Wegman, "Universal Classes of Hash Functions," STOC 1977 / JCSS 1979.** universal hashing 的核心 bound:從合適的 hash family `H` 隨機選 h,對任意兩相異 key,`Pr_{h←H}[h(x)=h(y)] ≤ 1/m`。這提供比「SipHash 很安全」**更一般**的說法:防 HashDoS 的核心不是某個雜湊的名字,而是**攻擊者無法事先知道/預測實際使用的 mapping**(random choice of hash function 讓任意 adversarial 輸入序列仍有平均線性時間保證)。keyed PRF 是這個想法的密碼學實例化。

**前驅 — Crosby & Wallach 2003:** 已提出 keyed-hash / universal hashing 防禦。keyed MD5/SHA-1(HMAC,程式啟動時選隨機 key)變成攻擊者不可預測的 **PRF**;universal (Carter-Wegman) family 保證任兩訊息 Pr[h(M)=h(M')] < ε。**效能不必崩**:6MB working set 下 weak XOR12 = 50 MB/s,tuned Carter-Wegman CW12-20 = 33 MB/s ——「universal hashing 可逼近最弱雜湊的效能,且 provably secure」。直接支撐我們「換 keyed hash 效能不必崩」的論點。

**現代解 — Aumasson & Bernstein, "SipHash: a fast short-input PRF," INDOCRYPT 2012(ePrint 2012/351):**
- SipHash 是為短輸入最佳化的 PRF family;明確把「hash-table lookup 抗 hash-flooding」列為目標應用,並建議「hash tables 改用 SipHash」。
- **防禦論證(可直接寫進報告):** 若 H 是 strong PRF,則其截斷 **H mod l(l 為 2 的次冪 = bucket index)也是 strong PRF、因而是 strong MAC**;即使觀察了許多 attacker-chosen m 的 H(m) mod l,攻擊者仍**無法預測任何新字串的 H(m) mod l** —— 這正是「對 public hash 如 jhash 能離線構造碰撞、對 keyed PRF 不能」的關鍵。
- SipHash-2-4:128-bit key、無 key expansion、256-bit state(四個 64-bit word)、round = 4 add + 4 xor + 6 rotate。

**量化對比(need (d) 的核心)〔高信心〕:** 對 strong secret-keyed PRF,HashDoS 的 **CPU amplification factor n ≤ √(攻擊者通訊量)**(找到兩個碰撞字串約 √l 次猜測,之後每個同雜湊字串約 l 次 → n 個要通訊 ~n·l≈n² 個字串)。相對地,**weak secret hash 與(弱或強)public hash 都讓 n 隨通訊量「線性」成長**。這就是「public jhash → O(n²) 退化可達成 vs keyed SipHash → 被 √ 上界壓住」的精確數學陳述。

**為何小 seed 隨機化不夠(支撐選 hsiphash/siphash 而非 seeded jhash)〔高信心〕:**
- **Bar-Yosef & Wool, "Remote Algorithmic Complexity Attacks against Randomized Hash Tables," SECRYPT 2007.** 攻擊者觀察網路回應可**遠端回復**祕密雜湊參數,擊潰標準隨機化防禦 —— 條件是「secret 夠小」,且「不依賴特定雜湊的弱點」。(注意:威脅的是**小 seed**,不是 128-bit SipHash key。)
- Python 的新隨機化(非加密)雜湊被 Aumasson-Bernstein 攻破,可回復 128-bit seed;PEP 456:「Only a proper cryptographic hash function prevents the extraction of secret randomization keys.」

**Linux 採用 SipHash〔中信心,須回查 primary〕:** kernel SipHash 文件(docs.kernel.org/security/siphash)重述同一 PRF 理由,並描述 hsiphash 緩解「hashtable flooding DoS」、優於 jhash;Jason Donenfeld 2016 LKML patch 確認 SipHash-2-4 構造、稱其為「cryptographically secure PRF」。**建議直接抓 `Documentation/security/siphash.rst` 與 `lib/siphash.c` commit 作 primary 引用以提升到高信心。**

---

## 4. max-load / balls-into-bins〔worst-case 高信心;average-case 待補〕

- **worst case(adversarial)**:Crosby-Wallach 已給 —— Θ(n) per-op、O(n²) total。對應我們的 **maximum chain depth / lookup probe count** 指標的攻擊上界。
- **average case(random/PRF hash)**:max bucket load = **Θ(log n / log log n)**(n 球丟 n 桶)—— 這是「防禦後」的預期上界,對應我們量到的健康分布。**但此結果在本輪驗證中無 balls-into-bins 論文通過**(openQuestion 明列)。canonical 參考(須自行查證確切定理陳述):
  - Gonnet, "Expected Length of the Longest Probe Sequence in Hash Code Searching," JACM 1981.
  - Raab & Steger, "Balls into Bins — A Simple and Tight Analysis," RANDOM 1998.
  - Mitzenmacher & Upfal, *Probability and Computing*(教科書,occupancy/max-load 章節)。
- **待釐清(openQuestion):** 如何把抽象 max-load 理論「對應」到我們已 instrument 的指標(max chain depth、probe count、chain-length 分布、bucket entropy、collision frequency)。本 corpus 無前人方法學直接連接 Θ(log n/log log n) 與這些指標 —— 我們的量測方法學可能要自己從第一原理或 occupancy 文獻論證。

---

## 5. 攻擊衝擊基準數字〔高信心,但屬 2011 歷史〕

28C3 / AppSec12:**~200,000 個 ~10-byte colliding 字串(~2MB POST)→ ~40,000,000,000(200k²)次字串比較 → 1GHz 上至少 40s**。頻寬極省:PHP ~70-100 kbit/s 壓滿一顆 i7 core(1 Gbit/s ≈ 萬核);ASP.NET ~30 kbit/s;Tomcat/Java ~6 kbit/s;CRuby 1.8 ~720 bit/s。PHP/ASP.NET/Java/Python/Ruby/v8 全中(POST 參數存進 hash table)。

**時效注意:** 這些是 2011 未修補平台的數字,引用為**歷史攻擊基準**,非當前漏洞(均已修)。但威脅仍活:**CVE-2026-40164(jq 因硬編 MurmurHash3 seed 被 DoS)**、Node.js HashDoS advisory(2026-03)。

---

## 6. OVS related work 與我們的貢獻定位

**Tuple Space Explosion — Csikor et al., "Tuple Space Explosion: A Denial-of-Service Attack Against a Software Packet Classifier," CoNEXT 2019.** 這是 OVS / TSS 的 DoS prior work,但**作用在不同資料結構層級**:TSE 攻擊 Tuple Space Search 的 **tuple / mask 維度**(讓 mask 數量爆炸 → 跨 mask 的 linear lookup expansion),**不是 per-bucket 的 hash-chain collision**。

由此精準定位我們的貢獻(也修正 deep-research「沒人做過 OVS DoS」的說法 —— 有人做過,但不同層):

> TSE 分析 packet classifier 中 **tuple-space 數量**造成的 lookup expansion;本研究分析 **hash-table bucket-load distribution** 在不同雜湊函式下、攻擊性 key selection 下造成的 **chain / probe expansion**。兩者都屬 algorithmic complexity attack,但作用在不同資料結構層級。

所以新穎點是:**比較不同雜湊函式的 bucket-load robustness(generic),OVS 為系統案例**。本 corpus 仍無人對「OVS flow-table 的 per-bucket hash-chain load、且跨 jhash/hsiphash/siphash 比較」做過分析。寫進報告主張新穎性前,建議再針對性搜尋一次(OVS/megaflow + "hash flooding"/"collision"/"bucket",2019–2026)確認 TSE 之外無重疊。

---

## 7. 引用時的 caveats(對抗式驗證標出的）

1. **PRF 防禦是條件式**:√ 上界與「無法預測 H(m) mod l」皆**條件於 SipHash 是 strong PRF**(設計猜想,非已證定理;He & Yu 2019 只破 reduced-round 2-1/2-2)。寫「if H is a strong PRF」,別宣稱無條件證明。整個防禦繫於 **key secrecy**;key 洩漏或小 seed 被回復則崩。hsiphash(HalfSipHash)brute-force margin 弱於 full siphash;可考慮 per-boot key 是否有 remote timing side-channel。
2. **碰撞構造的 relevance gap**:所有已驗證構造法都針對「別的」雜湊;對 lookup3/jhash 須自行做差分/代數分析(見 §2)。
3. 勿引用 Perl「46 generators」逸事(§2)。
4. Bar-Yosef & Wool 只引「小 seed 隨機化不足」這個保守結論,別過度延伸成「這就是 128-bit key 有效的理由」(該過度主張已被 0-3 否決)。

---

## 8. 攻擊方法分類(A/B/C)的文獻依據〔2026-06-16 verification pass,25/25 claims 通過〕

我們把碰撞/HashDoS 構造法分成 **A 搜尋類(generic)/ B 結構利用類(structural)/ C 表-種子類** —— **此分組是本研究自行整理**:本輪查證確認**無單一 survey** 把它做成現成分類,但底層的 **generic(black-box / algorithm-independent)vs structural(cryptanalytic)** 區分有教科書依據,須如此陳述(不可歸給某篇現成 survey)。

- **分組依據(generic vs structural)**〔verified〕:**Handbook of Applied Cryptography**(Menezes, van Oorschot & Vanstone, CRC Press 1996),Ch.9〈Hash Functions and Data Integrity〉—— §9.7.1 generic/algorithm-independent vs structural、§9.2 classification framework、Fact 9.33 birthday 界 `2^n / 2^(n/2)`;§9.7.3 把差分分析連到雜湊碰撞。
- **A 類(generic)代表**〔verified〕:**van Oorschot & Wiener, "Parallel Collision Search with Cryptanalytic Applications," J. Cryptology 12(1):1–28, 1999**(DOI 10.1007/PL00003816)—— distinguished-points,~O(√n)、低記憶體,在任意 black-box 函式找碰撞。引為「高效、structure-free 地找大量 full-hash 碰撞」之法。
- **B 類(structural)源頭**〔verified;頁碼已修正〕:**Biham & Shamir, "Differential Cryptanalysis of DES-like Cryptosystems"** —— CRYPTO'90(LNCS 537, Springer 1991, **pp.2–21**,DOI 10.1007/3-540-38424-3_1)及 **J. Cryptology 4(1):3–72, 1991**(DOI 10.1007/BF00630563)。differential = 輸入 XOR 差分如何傳播到輸出差(離散差,**非微分**);後由 ABB 2012 套到 ARX 雜湊。
- **未驗證(本輪零通過 → 引用前自行確認,勿當已證)**:Mironov & Zhang, "Applications of SAT Solvers to Cryptanalysis of Hash Functions"(SAT 2006);Katz & Lindell, *Introduction to Modern Cryptography*。

---

## 來源(verified primary)

- Crosby & Wallach 2003 — usenix.org/legacy/events/sec03/tech/full_papers/crosby/crosby.pdf
- Klink & Wälde, 28C3 2011 — youtube R2Cq3CLI6H8(talk)
- Aumasson/Bernstein/Boßlet, AppSec12/29C3 2012 — aumasson.jp/siphash/siphashdos_appsec12_slides.pdf;fahrplan.events.ccc.de/congress/2012/.../5152
- Aumasson & Bernstein, SipHash 2012 — eprint.iacr.org/2012/351;cr.yp.to/siphash/siphash-20120918.pdf
- Bar-Yosef & Wool, SECRYPT 2007 — researchgate 221436424
- Linux SipHash — kernel.org/doc/html/latest/security/siphash.html;patchwork Donenfeld 2016 patch;github.com/veorq/SipHash
- jhash/lookup3 本體 — burtleburtle.net/bob/c/lookup3.c
- "Breaking Murmur"(Boßlet)— emboss.github.io/blog/2012/12/14/breaking-murmur-hash-flooding-dos-reloaded/
- balls-into-bins〔待查證〕— Raab-Steger(springer 3-540-49543-6_13);Mitzenmacher-Upfal(book);Gonnet(dl.acm 322248.322254)
- Carter & Wegman, "Universal Classes of Hash Functions," STOC 1977 / JCSS 1979 — cs.princeton.edu/courses/archive/fall09/cos521/Handouts/universalclasses.pdf〔由 6/15 討論補入,須回查 primary〕
- Csikor et al., "Tuple Space Explosion: A DoS Attack Against a Software Packet Classifier," CoNEXT 2019 — dl.acm.org/doi/10.1145/3359989.3365431〔OVS/TSS related work,由 6/15 討論補入〕
- van Oorschot & Wiener, "Parallel Collision Search with Cryptanalytic Applications," J. Cryptology 12(1):1–28, 1999 — DOI 10.1007/PL00003816〔verified 6/16〕
- Biham & Shamir, "Differential Cryptanalysis of DES-like Cryptosystems," CRYPTO'90(LNCS 537, pp.2–21)/ J. Cryptology 4(1):3–72, 1991 — DOI 10.1007/BF00630563〔verified 6/16〕
- Handbook of Applied Cryptography (Menezes, van Oorschot & Vanstone, CRC 1996), Ch.9 §9.2/§9.7.1/Fact 9.33 — cacr.uwaterloo.ca/hac〔verified 6/16:generic-vs-structural 依據〕
- Mironov & Zhang, "Applications of SAT Solvers to Cryptanalysis of Hash Functions," SAT 2006;Katz & Lindell, *Introduction to Modern Cryptography*〔未驗證,引用前自行確認〕
