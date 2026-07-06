# 實驗三
> 分析 collision 與 bucket distribution: 需於 OVS flow table 中加入 debugfs、tracepoint 或 eBPF instrumentation，統計 bucket chain length, maximum chain depth, lookup probe count, bucket entropy, collision frequency 並比較隨機 flow、連續 IP flow、固定目的 IP、變動 source port、刻意搜尋 jhash collision 的 flow set 在不同 hash function 下的分佈差異

###  目前章節
1. Background and Threat Model
1.1 HashDoS 威脅模型：Algorithmic Complexity Attack
1.2 隨機分布基準：Balls-into-Bins Model
1.3 Keyed Hash 防禦：SipHash / HalfSipHash
1.4 Universal Hashing：隨機化雜湊 mapping
1.5 OVS 相關研究：Tuple Space Explosion DoS Attack
2. Formal Model and Attack Construction
2.1 Formal hash-table model
2.2 Bucket-load metrics：Lmax、C、entropy、probe count
2.3 Adversarial input construction：targeted-bucket search
2.4 Attack cost analysis：離線構造時間 + 成本不對稱
3. Generic Hash-Table Experiment
3.1 Experiment setup
3.2 Result A：Benign Bucket-Load Distribution Matches Poisson Baseline
3.3 Result B：五組 flow set 的輸入比較
3.4 Result C：同一 collision set 下 keyed vs unkeyed 對比
4. OVS Case Study
4.1 OVS lookup path：兩段雜湊與 masked key（含 instrumentation）
4.2 真實表的良性 baseline
4.3 OVS 對可利用性的系統限制
4.4 在真實 kernel 重現 HashDoS
4.5 Keyed-hash 防禦與效能成本


## Motivation：近期 HashDoS 案例

HashDoS 並不是只存在於早期文獻中的問題。2026 年 jq 出現的 [CVE-2026-40164](https://zh-tw.tenable.com/plugins/nessus/306412) ，說明固定且公開的 non-cryptographic hash seed 仍可能在現代軟體中造成 algorithmic complexity DoS。

jq 是一個常用的命令列 JSON 處理器。在修補前，jq 於 JSON object hash table 操作中使用 MurmurHash3，並搭配公開且寫死的 seed `0x432A9843`，由於 hash mapping 可被離線預測，攻擊者可以事先構造大量會落到同一 bucket 的 JSON object keys。根據 jq 的 [GitHub security advisory](https://github.com/jqlang/jq/security/advisories/GHSA-wwj8-gxm6-jc29)，約 100 KB 的 crafted JSON 即可能使 hash table lookup 從 $O(1)$ 退化為 $O(n)$，進而使 jq expression 呈現 $O(n^2)$ 等級的 CPU exhaustion。

這個案例呼應本研究的核心問題：當 hash table 使用 predictable hash mapping，且輸入 keys 可被攻擊者控制時，adversarial key selection 可能造成 bucket-load 群聚，並導致 lookup cost 退化。因此，本研究進一步分析 jhash、hsiphash 與 siphash 在 bucket-load robustness 上的差異，並以 Open vSwitch flow table 作為系統層級 case study。



> 補充：[patch](https://github.com/jqlang/jq/commit/0c7d133c3c7e37c00b6d46b658a02244fdd3c784)


## 1. Background and Threat Model
### 1.1 HashDoS 威脅模型：Algorithmic Complexity Attack
> [Denial of Service via Algorithmic Complexity Attacks](https://www.usenix.org/conference/12th-usenix-security-symposium/denial-service-algorithmic-complexity-attacks)
> 12th USENIX Security Symposium 2003

不同雜湊函式在 hash table 中面對攻擊性輸入時的分布特性，理論基礎可追溯自 2003 年 HashDoS 論文 *《Denial of Service via Algorithmic Complexity Attacks》* 。

資料結構的效能分析通常會區分平均情況與最壞情況，以 chaining hash table 為例，在雜湊分布良好的情況下，每個 bucket 的 chain 長度很短，因此一次 insert 或 lookup 的期望成本接近 $O(1)$，處理 $n$ 筆資料的總成本約為 $O(n)$。然而，如果攻擊者能刻意選擇輸入，使大量 keys 落入同一個 bucket，該 bucket 會退化成長度為 $n$ 的 linked list，此時單次操作需要掃過很長的 chain，成本會退化為 $O(n)$，若系統持續處理 $n$ 筆這類輸入，總成本會變成 $\Theta(n^2)$。
![螢幕快照 2026-06-15 15-11-45](https://hackmd.io/_uploads/Bkk1nV6ZGg.png)

這個觀察使 hash collision 不只是效能問題，而是安全問題。正常隨機輸入下，所有 keys 剛好落到同一個 bucket 的機率極低，若 hash table 有 $m$ 個 buckets，$n$ 個 keys 全部落到某一個指定 bucket 的機率為 $\left(\frac{1}{m}\right)^n$。若不指定是哪一個 bucket，只要求全部集中在某一個 bucket，機率為

$$
m \cdot \left(\frac{1}{m}\right)^n=
\frac{1}{m^{n-1}}
$$

因此，嚴重的 bucket 群聚不會在良性隨機輸入中自然出現，它更合理地被視為 adversarial input 的結果。這也是本研究將 maximum chain depth、bucket load distribution、collision count 與 lookup probe count 作為安全性指標的原因。

論文進一步指出，攻擊成立需要**三個條件**。第一，雜湊函式必須是 deterministic 且可被攻擊者得知，第二，攻擊者必須能預測或控制實際送入雜湊函式的輸入，第三，系統必須接收足夠數量的攻擊性輸入，使最壞情況的複雜度足以造成可觀的效能退化。**本研究後續分析的威脅模型會建立於上述條件，關注的不是任意 collision，而是「外部可控制的 key space」在可預測雜湊函式下，是否可能被攻擊者用來形成高 bucket load。**

### collision 兩大分類
在 hash table 攻擊中，還需要區分兩種 collision。第一種是 **hash collision**，也就是多個不同輸入具有相同的完整 hash value：

$$Hash(k_1)=Hash(k_2)=\cdots=Hash(k_i)$$


這種 collision 不依賴 bucket 數量，因此即使 hash table resize，這些 keys 仍然會具有相同 hash value。第二種是 **bucket collision**，也就是不同輸入的完整 hash value 不一定相同，但經過 bucket mapping 後落到同一個 bucket：

$$Hash(k_1)\bmod m=Hash(k_2)\bmod m=\cdots=Hash(k_i)\bmod m$$

bucket collision 通常比完整 hash collision 容易構造，因為 bucket 數 $m$ 遠小於完整 hash output space，但它需要先得知 bucket 數量。如果 hash table 會 resize，針對某個 $m$ 構造的 bucket collision 會在 $m$ 改變後被拆散，因此，**對會動態調整 bucket 數量的系統而言，必須清楚區分 hash collision 與 bucket collision**。

### 攻擊者的 Input freedom / entropy budget
論文中實驗也說明，攻擊的可行性不只取決於 hash function，也取決於攻擊者的輸入自由度。例如在 Bro IDS 的案例中，攻擊者可控制 source IP address 與 destination port，有 $32+16=48$ bits 的輸入自由度，若 hash output 是 32 bits，則對某個 32-bit target hash value，理論上可期待約 $2^{48-32}=2^{16}$ 個可送出的 inputs 具有相同 hash value。這個觀察對網路系統特別重要，因為封包欄位並非任意，攻擊者能否產生足夠多不同的 colliding keys，取決於可控欄位的 entropy budget。

因此，對一個特定系統或 workload，我們不能只問「hash function 是否可能 collision」，而是要同時分析：$|D| = 2^B$，其中 $D$ 是攻擊者可產生的 key space，$B$ 是可控輸入位元數。若要找完整 $r$-bit hash collision，理想隨機情況下，對某個目標雜湊值的期望 preimage 數約為 $2^{B-r}$，若只要求落到某個 bucket，則期望可用候選輸入為 $\frac{2^B}{m}$，這表示攻擊面大小同時受到 hash output 大小、bucket 數量、以及攻擊者可控輸入空間限制。

### 那要如何防禦呢？
若使用 deterministic 且公開的 hash function，即使 hash function 本身較強，最後仍會被壓縮到有限 bucket 數，因此攻擊者仍可能離線搜尋 bucket collisions。相反地，若使用 keyed hash 或 universal hashing，實際使用的 hash mapping 會依賴系統啟動時產生的密鑰，攻擊者即使知道演算法，也無法知道系統中的 key 和 bucket 如何對應，因此無法在離線階段先篩選出相同 bucket keys。

這個差異可以用「offline 離線構造」與「online 線上嘗試」來分類。在 unkeyed hash model 中，攻擊者知道 bucket mapping：$B(x)=H(x)\bmod m$，因此可以先在自己的機器上大量產生候選 keys，離線計算哪些 keys 會落到同一個目標 bucket，只把篩選後的 collision keys 送進受害系統。若目標 bucket 為 $b^*$，每個 candidate 命中的機率約為 $1/m$，因此找出 $K$ 個同 bucket keys 的期望離線成本約為 $q_{\text{offline}}\approx K\cdot m$，這些搜尋成本不會消耗受害系統資源，受害系統最後只會收到已篩選好的 $K$ 個 collision keys。

相對地，在 keyed hash model 中，$B_k(x)=H_k(x)\bmod m$，bucket mapping 取決於密鑰，攻擊者即使知道演算法，也無法離線預測某個 key 會落到哪個 bucket，只能在線上送出候選 keys 嘗試碰撞，這些嘗試會成為可觀測及限制的流量。因此，keyed hash 的防禦策略不是讓 collision 不可能發生，而是阻止攻擊者離線預先構造 collision set。


這篇論文為威脅模型提供理論基礎，也支撐後續對 jhash、hsiphash、siphash 在 bucket-load robustness 上的比較。平均 $O(1)$ 的 hash table lookup，在攻擊性輸入下可能退化為 $O(n)$，進而造成 $\Theta(n^2)$ 等級的總成本，此攻擊是否可行，取決於 hash function 是否可預測、攻擊者是否有足夠 input freedom、以及系統是否允許足夠多攻擊性 input 進入。

### 1.2 隨機分布基準：Balls-into-Bins Model
> [“Balls into Bins” — A Simple and Tight Analysis](https://link.springer.com/chapter/10.1007/3-540-49543-6_13)
> Conference paper
First Online: 01 January 1999

在建立 HashDoS 威脅模型後，還需要定義 baseline，也就是良性情況下的 bucket 分佈。若雜湊函式表現接近均勻 random mapping，則 $n$ 個 keys 被分配到 $m$ 個 buckets 的過程可以視為 balls-into-bins model：每個 key 獨立且均勻地落入其中一個 bucket。

令 bucket $b$ 的 load 為 $L_b=|{i:B(x_i)=b}|$，其中 $B(x_i)=H(x_i)\bmod m$。在 random mapping 假設下，每個 key 落入 bucket $b$ 的機率為 $1/m$，而 key 是否會落入該個 bucket 有中和沒中兩種情況，因此可用二項分佈來描述每個 bucket 的負載：

$$
L_b\sim Binomial(n,\frac{1}{m})
$$

且 bucket b 的期望值定為負載因子 $E[L_b]=\frac{n}{m}=\alpha$，$\alpha$ 是 load factor。當 (n,m) 夠大、單一 key 落入某個 bucket 的機率 $1/m$ 很小，且 $\alpha=n/m$ 固定時，二項分佈可用 Poisson 分佈近似：

$$
L_b\approx Poisson(\alpha)
$$

其機率函數為

$$
P(L_b=k)\approx e^{-\alpha}\frac{\alpha^k}{k!}
$$

其中 $k$ 表示 bucket $b$ 中剛好有幾個 keys，$e$ 為自然常數。Poisson 近似的意義是：當我們丟很多 keys，但每個 key 命中特定 bucket 的機率很小時，能用平均 load factor $\alpha$ 估計單一 bucket 的負載分佈，計算上會比二項分佈容易。

例如當 $n\approx m$ 時，$\alpha\approx 1$，代表平均每個 bucket 約有 1 個 key。但這不表示每個 bucket 都剛好只有 1 個 key，在正常隨機分布下，仍然會自然出現空 bucket、單一 key bucket，以及少量含有 2 到 3 個 keys 的 bucket。因此，bucket collision 本身並不代表 hash function 異常，collision 明顯高於此正常 baseline 才會被視為惡性情況，而 collision count 可定義 $C=\sum_{b=1}^{m}\binom{L_b}{2}$，任意一對 keys 落入同一 bucket 的機率為 $1/m$，因此良性隨機模型下的期望 collision count 為 $E[C]=\binom{n}{2}\frac{1}{m}$。

### maximum bucket load 推導
此外，maximum bucket load $L_{\max}=\max_b L_b$，對應 chaining hash table 的 worst-case 搜尋長度。對單一 bucket，可由 Chernoff-type bound 得到近似尾界：

$$
P(L_b\ge t)\le \left(\frac{e\alpha}{t}\right)^t
$$

再對 $m$ 個 buckets 使用 union bound：

$$
P(L_{\max}\ge t)
\le
m\left(\frac{e\alpha}{t}\right)^t
$$

當 $n\approx m$ 且 $\alpha\approx 1$ 時，maximum load 在高機率下為

$$
L_{\max}=
\Theta\left(\frac{\log n}{\log\log n}\right)
$$

因此，若 hash function 接近隨機分布，最長 chain 應維持在非常緩慢成長的對數級，若在 adversarial key 下觀察到 $L_{\max}$ 明顯高於此基準，則代表 bucket-load 群聚效應被放大，導致 lookup 成本上升。

> 註：原文使用 first and second moment method 證明此 maximum-load bound

### 1.3 Keyed Hash 防禦：SipHash / HalfSipHash
> [SipHash : a fast short-input PRF](https://link.springer.com/chapter/10.1007/978-3-642-34931-7_28)

unkeyed hash 的主要風險在於攻擊者可以 offline 預測 key-to-bucket mapping，進而構造同 bucket collision set，為降低此風險，常見防禦方向是將 hash function 改為 keyed hash，攻擊者即使知道演算法，也無法預測某個 key 會落到哪個 bucket，因此能阻止攻擊者事先 offline 篩選 collision keys，使 bucket distribution 更接近隨機 balls-into-bins baseline。

SipHash 是針對 short input 設計的 keyed pseudorandom function，常被用於 hash-table hardening。從本研究角度來看，siphash 可作為較完整的 keyed PRF baseline，用來觀察較強安全假設下的 bucket-load robustness，hsiphash 則是較輕量的 keyed hash，用來評估在較低計算成本下是否仍能提供比 unkeyed hash 更好的分布特性。

因此，實驗三比較 jhash、hsiphash 與 siphash 時，不只要比較一般輸入下的 bucket 分佈，也是在比較三者面對 adversarial key 選擇時，是否能避免 $L_{\max}$、collision count 與 lookup probe count 明顯偏離 baseline。

### advanced hash flooding  
> Even if the hash function is secret, a hash table may still leak partial information through timing or enumeration behavior.
> §7 Application: defense against hash flooding

論文進一步討論 advanced hash flooding：即使 hash function 使用密鑰，hash table 的 timing 或列舉順序仍可能洩漏部分 bucket-index 資訊。也就是說，攻擊者可能觀察到某些已查詢輸入的結果：$H_k(x)\bmod \ell$，其中 $\ell$ 是 bucket 數。

然而，只要 $H_k$ 可視為 strong PRF，攻擊者即使知道已查詢字串的 bucket index，仍無法預測下一個未查詢字串會落到哪個 bucket。因此，每個新字串對攻擊者來說仍近似隨機落入 $\ell$個 buckets 之一，攻擊者平均約需 $\sqrt{\ell}$ 次嘗試，才會找到第一組 collision，這可用 birthday paradox 的原理解釋，第一組碰撞找到後，若要繼續增加同一 bucket 內的 keys，因為目標 bucket 已固定，每新增一個 key 平均需要約 $\ell$ 次嘗試。因此，形成 $K$ 個同 bucket keys 的 online 成本約為

$$
\sqrt{\ell}+(K-2)\ell \approx K\ell
$$

若 hash table 的 bucket 數與欲形成的 chain 長度同量級，即 $\ell\approx K$，則成本約為 $K\ell\approx K^2$

也就是說，在 strong keyed hash model 下，若攻擊者送出的總候選數為 $Q$，可形成的 collision chain 長度只隨 $\sqrt{Q}$ 成長，unkeyed hash model 中，攻擊者可以 offline 篩選 collision keys，online 送出 $Q$ 個精選 keys 就可能形成長度約 $Q$ 的 chain。**因此，keyed hash 的價值在於阻止攻擊者離線預測 bucket mapping，將攻擊效果從接近線性成長壓低為平方根級成長。**

### 1.4 Universal Hashing：隨機化雜湊 mapping
> [Paper：2003 Denial of Service via Algorithmic Complexity Attacks](https://www.usenix.org/conference/12th-usenix-security-symposium/denial-service-algorithmic-complexity-attacks)
> § 5.2 Universal hashing
> [CMU 的演算法講義 §2 Universal Hashing](https://www.cs.cmu.edu/afs/cs/project/pscico-guyb/realworld/www/slidesS14/hashing.pdf)
> [Paper：1978 Universal Classes of Hash Functions](https://www.cs.princeton.edu/courses/archive/fall09/cos521/Handouts/universalclasses.pdf)

除了使用 cryptographic PRF 之外，universal hashing 也是 HashDoS 的防禦策略，它不固定使用單一公開 hash function，而是從一個 hash function family 中隨機選出實際使用的函式。令 $\mathcal{H}$ 為一組 hash functions，若對任意兩個不同 keys $x\neq y$，都有

$$
\Pr_{h\leftarrow\mathcal{H}}[h(x)=h(y)]\leq \frac{1}{m}
$$

則表示在隨機選擇 hash function 的情況下，任兩個 keys 發生 collision 的機率不會高於均勻隨機分配到 $m$ 個 buckets 的基準。，若 hash function 是固定且公開的，攻擊者可以離線尋找會落入同一 bucket 的 keys，但若實際使用的 hash function 是系統啟動時隨機選出，且攻擊者事先不知道，則攻擊者無法針對固定 mapping 預先構造 collision set，換言之，**universal hashing 的防禦方式是將惡意輸入重新轉化為接近 random mapping 下的 bucket 分佈**。

### 1.5 OVS 相關研究：Tuple Space Explosion DoS Attack
> [Paper：2019 Tuple Space Explosion: A Denial-of-Service Attack Against a Software Packet Classifier](https://dl.acm.org/doi/abs/10.1145/3359989.3365431)

除了一般 hash table 的 HashDoS 模型外，OVS 本身也已有與 algorithmic complexity DoS 相關的研究，這篇分析 software packet classifier 中常見的 Tuple Space Search（TSS）演算法，TSS 依據 packet classification rule 的 wildcard pattern，將 rules 分成不同 tuple spaces。封包查詢時，系統需要在多個 tuple spaces 中尋找可能匹配的 rule，因此，若攻擊者能讓系統產生大量 tuple spaces，packet classification 的查詢成本就會上升。這類攻擊不一定需要大量流量，而是利用分類演算法本身的複雜度特性，使低速封包也能造成顯著效能退化。

這篇論文與本研究的關係在於，它同樣屬於 software datapath 中的 algorithmic complexity attack，但作用層級不同。Tuple Space Explosion 攻擊的是 packet classifier 的 tuple / mask 維度，使每個封包需要搜尋更多 tuple spaces，本研究關注的是 hash table bucket-load 維度，也就是在單一 hash table 或單一 bucket mapping 下，不同 hash function 是否會造成 bucket 分佈群聚、chain 長度增加與 lookup 搜尋成本上升。

因此， OVS datapath 的效能不只受封包數量影響，也受到資料結構與查詢演算法的最壞情況影響。不過，本研究的主軸不是 tuple-space explosion，而是比較 jhash、hsiphash 與 siphash 在 hash-table bucket distribution 上的 robustness。

### 回應一開始的破題，從 jq CVE 延伸的 HashDoS 研究方向

除了比較 OVS 中不同函式的效能與安全性，也可以建立一套通用 hash-table 安全性分析 workflow，用來檢查其他開源專案中是否存在「外部可控 key + 固定 seed non-cryptographic hash」的風險。

可能貢獻包括：

1. 建立 adversarial key 產生方法。
2. 比較 unkeyed hash 與 keyed hash 在 $L_{\max}$、collision count、entropy、probe count 上的差異。
3. 將 OVS 作為第一個 case study。
4. 未來擴展到 JSON parser、CLI data processor、log processor、network daemon 等使用 hash table 的專案。

希望能建立有系統的策略，並不是直接去找弱 hash 來替換，而是要判斷風險層級，該 hash 是否處理 untrusted input、mapping 是否可預測，以及攻擊者是否能構造足夠多 keys 造成 bucket 分佈群聚。

## 2. Formal Model and Attack Construction

前述威脅模型可整理成實驗使用的形式化定義，包含定義 bucket-load 指標、adversarial input 的構造方式，以及離線構造成本。

> 變數
$n： key$
$m： bucket$
$b： bucket\  id$
$L: Load$

### 2.1 Hash-Table Model

先考慮一個通用 hash table，令 key set 為 $S={x_1,x_2,\dots,x_n}$，hash table 共有 $m$ 個 buckets，對任意 key $x$，其 bucket index 定義為：

$$
B(x)=H(x)\bmod m
$$

其中 $H$ 為實驗中指定的 hash function，若使用 keyed hash，則 $H$ 會改為 $H_k$，其中 $k$ 是系統內部的 secret key。

### 2.2 Bucket-Load Metrics

bucket $b$ 的 load 定義為：

$$
L_b=\left|{x\in S:B(x)=b}\right|
$$

本研究主要使用三個指標描述 bucket-load 分佈。

第一是 **maximum bucket load**：

$$
L_{\max}=\max_b L_b
$$

此指標代表最長 bucket chain，對應最壞情況的 lookup path。

第二是 **collision count**：

$$
C=\sum_{b=1}^{m}\binom{L_b}{2}
$$

其 random baseline 為：

$$
E[C]=\binom{n}{2}\frac{1}{m}
$$

第三是 **normalized entropy** $H_{\text{norm}}$，用來衡量 bucket distribution 是否接近均勻，若 keys 分散均勻，entropy 接近 1；若 keys 全部集中到單一 bucket，entropy 接近 0。

### 2.3 Adversarial Input Construction

本研究採用 targeted-bucket search 產生 adversarial input，攻擊者選定目標 bucket $b^*$，離線枚舉 candidate keys，並只保留滿足：$B(x)=b^*$ 的 keys，重複此過程直到取得 $K$ 個同 bucket keys，形成 collision set。

此方法不假設特定 hash function 的差異化特性，而是測試 Unkeyed hash mapping 是否能被離線 target，若改用 keyed hash，攻擊者在不知道密鑰的情況下無法離線計算正確 bucket mapping，因此同一組針對 jhash2 構造出的 keys 應會重新分散。

### 2.4 Attack Cost

若 hash output 對候選 keys 近似均勻，則每個 candidate key 命中目標 bucket 的機率為：

$$
p=\frac{1}{m}
$$

因此，找到 $K$ 個同 bucket keys 的期望雜湊運算次數（或期望嘗試次數）次數為：

$$
E[q]=K\cdot m
$$

設定 $K=4096$、$m=4096$，理論期望為：

$$
4096\times4096=16,777,216
$$

實測 collision construction 使用 $16,579,328$ 次嘗試，與理論期望相近。這表示在 Unkeyed hash model 下，bucket collision set 的離線構造成本可被量化，且在本實驗規模下並不高。

另外，攻擊成本不對稱是關鍵切入點，攻擊者付出的是一次性的離線搜尋成本，受害端則在後續 lookup 中持續承擔較高的 bucket 搜尋成本。因此 keyed hash 的作用是阻止攻擊者離線預測 bucket mapping，而不是單純改變雜湊函式的運算速度。

## 3. Controlled Hash-Table Bucket-Load Experiment 

雖然本實驗使用 Linux kernel 中的 jhash2、hsiphash 與 siphash 實作，但它並未經過完整 OVS datapath，而是在可控 hash table 中隔離觀察 hash function 對 bucket-load distribution 的影響。因此，本章定位為通用型實驗，第四章才進一步放回真實 OVS flow table 進行 case study。

### 3.1 Experiment Setup

使用 [kernel module harness（核心模組測試載具）](https://docs.kernel.org/dev-tools/kselftest.html#test-harness) `hash_table_bench.c`，並直接呼叫核心中的雜湊函式，實驗設定如下：

| 項目             | 設定                                        |
| -------------- | ----------------------------------------- |
| keys 數量        | $n=4096$                                  |
| buckets 數量     | $m=4096$                                  |
| load factor    | $\alpha=n/m=1$                            |
| key format     | 16-byte 5-tuple flow key                  |
| key fields     | src_ip, dst_ip, src_port, dst_port, proto |
| random seed    | `0x12345678`                              |
| hash functions | jhash2, hsiphash, siphash                 |

使用五組 flow key set：

| key set            | 說明                                       |
| ------------------ | ---------------------------------------- |
| random             | 隨機產生的 flow keys                          |
| seq_ip             | source IP 連續遞增                           |
| fixed_dst          | 固定 destination IP                        |
| vary_srcport       | 只改變 source port                          |
| collision-vs-jhash | 針對 jhash2 seed=0 離線構造（或固定常數），使 keys 落入同一 bucket |

前四組代表良性或結構化但非攻擊性的輸入，第五組則是 adversarial input，用來
1. 測試 Unkeyed hash mapping 是否能被 targeted-bucket search 放大成極端 bucket 群聚。
2. 觀察四個指標：maximum bucket load $L_{\max}$、collision count $C$、random baseline $E[C]$，以及 normalized entropy $H_{\text{norm}}$。

```
/* 依 key_mode 產生第 idx 個 flow key(模式 0–3;模式 4 collision 另在 init 處理） */
static void fill_key(u8 *key, u32 idx)
{
	int i;

	memset(key, 0, key_len);
	switch (key_mode) {
	case 0: /* 隨機 flow:整把 key 隨機 */
		for (i = 0; i < key_len; i += 4)
			put_unaligned_le32(lcg_next(), key + i);
		break;
	case 1: /* 連續 IP flow:src_ip 遞增,其餘固定 */
		put_unaligned_be32(BASE_SRC_IP + idx, key + FK_SRC_IP);
		put_unaligned_be32(BASE_DST_IP, key + FK_DST_IP);
		put_unaligned_be16(BASE_SRC_PORT, key + FK_SRC_PORT);
		put_unaligned_be16(BASE_DST_PORT, key + FK_DST_PORT);
		key[FK_PROTO] = BASE_PROTO;
		break;
	case 2: /* 固定目的 IP:dst_ip 固定,src_ip / ports 隨機 */
		put_unaligned_le32(lcg_next(), key + FK_SRC_IP);
		put_unaligned_be32(BASE_DST_IP, key + FK_DST_IP);
		put_unaligned_le16((u16)lcg_next(), key + FK_SRC_PORT);
		put_unaligned_le16((u16)lcg_next(), key + FK_DST_PORT);
		key[FK_PROTO] = BASE_PROTO;
		break;
	case 3: /* 變動 source port:只有 src_port 遞增,其餘固定 */
		put_unaligned_be32(BASE_SRC_IP, key + FK_SRC_IP);
		put_unaligned_be32(BASE_DST_IP, key + FK_DST_IP);
		put_unaligned_be16((u16)(BASE_SRC_PORT + idx), key + FK_SRC_PORT);
		put_unaligned_be16(BASE_DST_PORT, key + FK_DST_PORT);
		key[FK_PROTO] = BASE_PROTO;
		break;
	}
}
```

### 3.2 Result A：Benign Bucket-Load Distribution Matches Poisson Baseline

在正常隨機輸入下，hash table 的 bucket-load 分佈是否接近理論上的 Poisson baseline?若成立，後續的指標才有明確的判讀依據。

本實驗設定 $n=m=4096$、$\alpha=1$，在理想隨機雜湊下，bucket load 並不會全部等於 1，而是應該自然出現空桶、單一 key bucket，以及少量高負載 bucket。對單一 bucket 而言，理論 baseline 為：

$$
L_b \approx Poisson(1)
$$

以 jhash2 為例，實測 bucket-load 與 $Poisson(1)$ 理論預測差異如下：

| bucket load $k$ | 理論機率 $P(k)$ | 理論桶數 $m \cdot P(k)$ | 實測桶數 |
| --------------: | ----------: | ------------------: | ---: |
|               0 |       0.368 |                1507 | 1521 |
|               1 |       0.368 |                1507 | 1471 |
|               2 |       0.184 |                 753 |  768 |
|               3 |       0.061 |                 251 |  271 |
|               4 |       0.015 |                  63 |   52 |
|        $\geq 5$ |       0.004 |                  15 |   13 |

jhash2 的 bucket-load distribution 與 $Poisson(1)$ 十分接近。空桶數、單一 key bucket 數、雙 key bucket 數，以及高負載 bucket 數都落在合理抽樣誤差範圍內。

進一步以 Pearson $\chi^2$ goodness-of-fit 檢定：

$$
\chi^2 = 4.96,\quad df=5
$$

在顯著水準 $0.05$ 下，臨界值為：

$$
\chi^2_{0.05}(5)=11.07
$$

由於：4.96 < 11.07

因此不拒絕「bucket-load distribution 服從 Poisson(1)」的虛無假設。這表示在 random benign input 下，jhash2 的 bucket 分布可視為接近 uniform random mapping，沒有觀察到系統性偏移或自然形成的 bucket clustering。

此結果也與其他 bucket-load 指標一致。random / jhash2 的 collision count 為：C=2038

而 random baseline 為：E[C]=2047

兩者非常接近。此外，實測 $H_{\text{norm}}=0.9308$，也與 $Poisson(1)$ 在 $\alpha=1$ 時的理論值約 0.931 一致。這點很重要，因為 $H_{\text{norm}}<1$ 並不代表 hash function 有缺陷，而是 Poisson 分布本身就包含空桶與多載桶；在$n=m$ 的設定下，理想隨機分布本來就不會是每個 bucket 剛好一個 key。

因此，random benign baseline 確實符合 Poisson(1) 的 balls-into-bins 預期。後續若觀察到 $L_{\max}$、$C$ 或 $H_{\text{norm}}$ 大幅偏離此基準，就不能簡單解釋為正常隨機變異，而需要回到 key set 結構或 adversarial key selection 來分析。

### 3.3 Result B：Flow Set 本身是否造成異常分布？

Result A 已確認 random benign input 的 bucket-load distribution 接近 $Poisson(1)$。進一步比較不同 flow key set 是否會自然造成異常分布。bucket clustering 是否來自 flow key 格式或簡單結構化輸入本身，還是來自刻意構造的 adversarial key selection。

四組 benign key set 下，三種 hash function 的結果皆接近 random baseline。為了避免表格過長，本節以 jhash2 作為代表，並將 collision-vs-jhash 作為 adversarial input 對照。

| key set                | $L_{\max}$ |           $C$ | $E[C]$ | $H_{\text{norm}}$ |
| ---------------------- | ---------: | ------------: | -----: | ----------------: |
| random                 |          6 |          2038 |   2047 |            0.9308 |
| seq_ip                 |          6 |          2065 |   2047 |            0.9308 |
| fixed_dst              |          7 |          1994 |   2047 |            0.9326 |
| vary_srcport           |          6 |          2002 |   2047 |            0.9320 |
| **collision-vs-jhash** |   **4096** | **8,386,560** |   2047 |        **0.0000** 


random、seq_ip、fixed_dst 與 vary_srcport 四組 benign input 的 collision count 都接近理論基準 $E[C]=2047$，且 $L_{\max}$ 僅為 6 到 7。這表示一般隨機輸入與簡單結構化輸入不會自然造成嚴重 bucket clustering。

seq_ip 與 vary_srcport 並不是完全隨機輸入。seq_ip 主要只改變 source IP，vary_srcport 則主要只改變 2-byte source port。即使輸入只在單一欄位上變動，jhash2 仍然能將 keys 打散到接近 random baseline 的分布。因此，low-entropy 或單欄位變動本身並不必然造成 bucket clustering。

相對地，collision-vs-jhash 組呈現完全不同的結果。該組輸入使 $L_{\max}=4096$，表示所有 4096 個 keys 都落入同一 bucket；collision count 也上升為：

$$
C=\binom{4096}{2}=8,386,560
$$

同時，$H_{\text{norm}}=0$，代表 bucket distribution 完全集中而沒有分散性。這種分布已經不是 Poisson(1) 的正常變異，而是 targeted-bucket search 針對 jhash2 mapping 所構造出的極端結果。

因此，flow key format 本身不是造成極端 bucket clustering 的原因。四組 benign flow sets 即使帶有簡單結構，仍然接近 random baseline；只有針對 jhash2 bucket mapping 構造出的 collision-vs-jhash key set 會使 hash table 退化成單一 bucket 集中。

### 3.4 Result C：同一 Collision Set 在 Keyed Hash 下是否重新分散？

Result B，collision-vs-jhash 能使 jhash2 產生極端 bucket clustering。本節進一步檢查 keyed hash 是否能破壞這種離線構造出的 collision structure。實驗方法是使用同一組 collision-vs-jhash keys，分別餵入 jhash2、hsiphash 與 siphash。

| hash            | $L_{\max}$ |           $C$ | $E[C]$ | $H_{\text{norm}}$ |
| --------------- | ---------: | ------------: | -----: | ----------------: |
| jhash2, unkeyed |   **4096** | **8,386,560** |   2047 |        **0.0000** |
| hsiphash, keyed |          7 |          1994 |   2047 |            0.9323 |
| siphash, keyed  |          7 |          1985 |   2047 |            0.9327 |

同一組 collision-vs-jhash keys 對 jhash2 仍然形成極端 clustering，但在 hsiphash 與 siphash 下會重新分散。hsiphash 與 siphash 的 $L_{\max}$ 都回到 7，collision count 也分別回到 1994 與 1985，接近 random baseline $E[C]=2047$，normalized entropy 則回到約 0.93。

collision construction 的實測結果為：

$$
\text{filled}=4096/4096,\quad \text{tries}=16,579,328
$$

這與 targeted-bucket search 的理論期望非常接近：

$$
K \cdot m = 4096 \times 4096 = 16,777,216
$$

此結果說明，在 unkeyed hash mapping 下，攻擊者若知道 hash function 與 bucket mapping，可以用約 (K \cdot m) 次離線 hash evaluation 找到 (K) 個落入同一 bucket 的 keys。本實驗中，攻擊者以約 1658 萬次嘗試找到 4096 個 jhash2 同 bucket keys，與理論期望約 1678 萬次相當接近。

此外，jhash2 的 collision count 正好等於：

$$
\binom{4096}{2}=8,386,560
$$

這代表 4096 個 keys 全部落入同一 bucket。若只是一般隨機輸入，collision count 應接近 $E[C]=2047$；但在此處，collision count 增加到約 4096 倍，顯示 hash table 已經退化到極端最壞情況。

相對地，同一組 keys 在 hsiphash 與 siphash 下沒有維持原本的 collision structure。這不是因為 keyed hash 讓 collision 不可能發生，而是因為原本的 key set 是針對 jhash2 mapping 離線篩選出來的；一旦 mapping 改為 secret-dependent keyed hash，這組 keys 與目標 bucket 的關係就不再成立，因此 bucket-load distribution 回到 random baseline 附近。

因此，keyed hash 的防禦效果不在於完全消除 collision，而在於破壞攻擊者的 offline predictability。對 jhash2 有效的 targeted collision set，無法直接轉移到 hsiphash 或 siphash；同一組 adversarial keys 在 keyed hash 下會重新分散。


## 4. OVS Case Study

第三章在隔離的 hash table 中確認了三種雜湊函式對 adversarial key selection 的反應差異。本章將同一組分析放回真實的 Open vSwitch kernel datapath flow table，檢驗第二章的形式化模型與第三章的結果在實際系統中哪些仍成立、哪些被 OVS 的系統機制（megaflow mask、per-table 隨機 seed、動態 resize、Tuple Space Search）改變或限制。與第三章「攻擊者完全控制 key」的乾淨設定不同，OVS 是一個受限的案例：送入雜湊函式的不是攻擊者的原始封包，而是被 megaflow mask 蓋過後的 masked key。

### 4.1 OVS lookup path：兩段雜湊與 masked key
OVS datapath 的 flow table 是 chaining hash table：$n\_buckets$ 個 bucket，每個 bucket 掛一條 hlist chain。封包的查找路徑（`masked_flow_lookup()`，`net/openvswitch/flow_table.c`）為：

1. `ovs_flow_mask_key()`：用該 mask 把封包的 `sw_flow_key` 蓋成 **masked key**（被 wildcard 的位元清 0）。
2. `flow_hash()`：對 masked key 的一段連續位元組計算 32-bit 雜湊。OVS 預設為 `jhash2`，**且 seed 固定為 0、無祕密金鑰**。
3. `find_bucket()`：$\text{bucket}=\texttt{jhash\_1word}(\text{hash},\ \texttt{ti->hash\_seed})\bmod n\_buckets$，其中 `ti->hash_seed` 是建表時 `get_random_bytes()` 取得的 per-table 隨機值。
4. 走訪該 bucket 的 hlist chain，對每個節點先比 32-bit hash 再比 masked key，直到命中，走訪的節點數即第二章的 lookup probe count。

被雜湊的 masked key 是 `sw_flow_key` 從 `range.start` 起、長 `range_n_bytes` 的連續區段，range 由該 mask 觸及的欄位以 8-byte 對齊推得。對 L3 / UDP 的 megaflow，實測為 `(start=296, len=88)`，即 22 個 u32。這 88 個位元組（含 in_port、eth.type、ip.proto、src/dst IP、ports 等，被 wildcard 的欄位為 0）才是真正進入雜湊函式的輸入 —— 不是原始封包。

上述查找路徑落實於 `flow_table.c` 的下列核心碼（已略去量測插樁，僅保留演算法本身）：

```c
/* 第 2 段:per-table 隨機 seed,jhash_1word 後取低位元映射到 bucket(flow_table.c:562) */
static struct hlist_head *find_bucket(struct table_instance *ti, u32 hash)
{
	hash = jhash_1word(hash, ti->hash_seed);
	return &ti->buckets[hash & (ti->n_buckets - 1)];
}

/* 第 1 段:對 masked key 的 range 區段算 32-bit 雜湊(預設 jhash2、seed=0、無祕密金鑰) */
static u32 flow_hash(const struct sw_flow_key *key,
		     const struct sw_flow_key_range *range)
{
	const void *hash_data = (const u8 *)key + range->start;

	return ovs_flow_hash_backend(hash_data, range_n_bytes(range));
}

static struct sw_flow *masked_flow_lookup(struct table_instance *ti, ...)
{
	ovs_flow_mask_key(&masked_key, unmasked, false, mask);  /* 封包 → masked key */
	hash = flow_hash(&masked_key, &mask->range);            /* 第 1 段 */
	head = find_bucket(ti, hash);                           /* 第 2 段 → bucket */

	hlist_for_each_entry_rcu(flow, head, ...) {             /* 走 chain:即 probe count */
		if (flow->mask == mask && flow->flow_table.hash == hash &&
		    flow_cmp_masked_key(flow, &masked_key, &mask->range))
			return flow;
	}
	return NULL;
}
```

`hlist_for_each_entry_rcu` 那個迴圈就是 §1.1 的最壞情況所在：bucket chain 越長，命中前走訪的節點數（probe count）越多，單次查找成本由 $O(1)$ 退化為 $O(\text{chain length})$。

這個「兩段」結構正好對應 §1.1 區分的兩種 collision。第 2 段的 `jhash_1word(·, hash_seed)` 帶 per-table 隨機 seed，且 $n\_buckets$ 會在 flow 數成長時動態加倍（resize），因此任何只瞄準「低位元 bucket index 相同」的 **bucket collision** 都不穩定：攻擊者不知 seed，resize 後又被打散。唯一 seed-／resize- 無關的是 **完整 32-bit hash collision**，若兩個 masked key 使第 1 段 `flow_hash` 輸出完全相同，則 `jhash_1word(同值, seed)` 對任意 seed、任意 $n\_buckets$ 都映到同一 bucket。

因此 OVS 的攻擊面落在**無祕密的第 1 段 `flow_hash`（seed=0 的 jhash2）**：它可被離線重算，攻擊者得以離線構造完整 hash collision；第 2 段的隨機 seed 只把「所需碰撞寬度」從 $\log_2 m$ 提高到完整 32-bit（見 4.3），並不能阻止第 1 段的碰撞。

#### 量測方式

為在真實表上取得第二章的指標，於 `flow_table.c` 加入數個 debugfs 介面（kernel 改動以 patch 留存，`patches/flow_table_debug_instrumentation.diff`）：

| debugfs 介面 | 量測 | 對應指標 |
| --- | --- | --- |
| `ovs_probelen` | `masked_flow_lookup` 每次走過的 hlist 節點數直方圖 | lookup probe count（動態） |
| `ovs_buckets` | 當前 `ti->buckets` 的 chain-length 分布 | $L_{\max}$、collision count $C$、$H_{\text{norm}}$（靜態） |
| `ovs_hashlen` | `flow_hash` 輸入長度（`range_n_bytes`）直方圖 | masked-key 長度 |
| `ovs_keydump` / `ovs_keymask` | flow 插入時 dump masked key 與其 mask | masked-key layout、entropy budget |
| `ovs_hashcycles` | `rdtsc_ordered()` 夾 `flow_hash` 的 in-context cycle 直方圖 | per-hash 成本（4.5） |

上表的 `ovs_probelen` 與 `ovs_hashcycles` 由 `masked_flow_lookup()` 熱路徑的插樁餵入，以 `#if OVS_FLOW_HASH_DEBUG_LEN` 包覆，僅量測 build 編入（§4.5 量 per-hash cycle 用此 build；量 throughput 則須關掉此巨集的乾淨 build，因每包多兩個 `rdtsc_ordered` 會擾動吞吐）：

```c
/* masked_flow_lookup() 內,#if OVS_FLOW_HASH_DEBUG_LEN 才編入 */
{
	u64 _c0 = ovs_rdtsc();                       /* rdtsc_ordered() 序列化夾 */
	hash = flow_hash(&masked_key, &mask->range);
	ovs_record_hashcyc(ovs_rdtsc() - _c0);       /* → ovs_hashcycles 直方圖 */
}
...
hlist_for_each_entry_rcu(flow, head, ...) {
	probes++;                                    /* 走過一個 hlist 節點 */
	if (flow->mask == mask && flow->flow_table.hash == hash &&
	    flow_cmp_masked_key(flow, &masked_key, &mask->range)) {
		ovs_record_probe(probes);            /* → ovs_probelen 直方圖 */
		return flow;
	}
}
```

三種雜湊函式以編譯期 macro 切換、各自重建模組，身分以 `nm -u` 確認（jhash inline、hsiphash `__hsiphash_unaligned`、siphash `__siphash_unaligned`）。切換落實於 `ovs_flow_hash_backend()`，三個 `#define` 三選一；這也是「實際修改核心、使 OVS 可切換雜湊函式」的本體：

```c
/* net/openvswitch/flow_table.c — OVS_FLOW_HASH_{JHASH,HSIPHASH,SIPHASH} 三選一 */
static u32 ovs_flow_hash_backend(const void *hash_data, size_t hash_len)
{
#if OVS_FLOW_HASH_JHASH
	return jhash2((const u32 *)hash_data, (u32)(hash_len >> 2), 0);  /* seed=0、無祕密 */
#elif OVS_FLOW_HASH_HSIPHASH
	return hsiphash(hash_data, hash_len, &ovs_flow_hsiphash_key);
#elif OVS_FLOW_HASH_SIPHASH
	{
		u64 h = siphash(hash_data, hash_len, &ovs_flow_siphash_key);

		return (u32)(h ^ (h >> 32));  /* flow_hash() 回傳 u32,折疊 SipHash 64-bit 輸出 */
	}
#endif
}
```

keyed 版的金鑰於建表時以 `get_random_bytes()` 取得（比照 `ti->hash_seed`），為 per-boot 隨機，即部署等級條件——這正是攻擊者無法離線預測 mapping 的根據：

```c
get_random_bytes(&ovs_flow_hsiphash_key, sizeof(ovs_flow_hsiphash_key));
get_random_bytes(&ovs_flow_siphash_key, sizeof(ovs_flow_siphash_key));
```

### 4.2 真實表的良性 baseline

放攻擊之前，先確認第三章 Result A（良性輸入下三雜湊皆接近 balls-into-bins）在真實 OVS 表上是否仍成立。工作負載為 D-v3B 多 mask 規則（~18,785 條 OpenFlow 規則），`pktgen` 灌入後 datapath 約 15k flows、$m=16384$、$\alpha\approx0.94$。

靜態 bucket-load（`ovs_buckets`）：

| hash | $m$ | flows $n$ | $\alpha$ | $L_{\max}$ | $C$ | $E[C]$ | $H_{\text{norm}}$ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| jhash | 16384 | 15439 | 0.942 | 7 | 7458 | 7274 | 0.9364 |
| hsiphash | 16384 | 15443 | 0.943 | 7 | 7209 | 7278 | 0.9379 |
| siphash | 16384 | 15443 | 0.943 | 7 | 7270 | 7278 | 0.9377 |

動態 probe-count（`ovs_probelen`，平均／max）：jhash 1.05／7、hsiphash 1.14／8、siphash 1.14／7。

三者統計上不可區分、皆健康：$L_{\max}=7$（與 balls-into-bins 在此 $\alpha$ 下的對數級預期相符）、$C$ 落在 random baseline $E[C]$ 的 ±2.5% 內、$H_{\text{norm}}\approx0.94$、probe 平均約 1 且無病態長 chain。這與第三章 Result A 一致：**良性流量下雜湊函式的選擇不影響 bucket 分布品質，安全差異不在 baseline 顯現**。因此後續若觀察到 $L_{\max}$ 或 probe 明顯偏離此基準，即為 adversarial input 的結果，而非自然變異。

### 4.3 OVS 對可利用性的系統限制

第三章的攻擊假設攻擊者完全控制 key，OVS 把這個假設大幅收緊，這也是 case study 的核心：

**(1) masked-key entropy budget。** 進入 `flow_hash` 的是 masked key，只有「未被 wildcard、且攻擊者能以封包設定」的位元組能提供變異。對 L3 megaflow，可控的是 src_ip／dst_ip／src_port／dst_port 共 12 位元組；但在受測工作負載中，IP 高位元組受子網固定（`0a 00 01`／`0a 00 02`）、port 高位元組受範圍固定，實際有效 entropy 約 17 bits。如 §1.1 的 entropy-budget 觀點（Bro IDS：48 bits 可控、32-bit hash → 約 $2^{16}$ preimage），攻擊可行性取決於 $2^B$ 是否夠大以構造足量 colliding keys。OVS 的 $B$ 受 mask 壓低，這是它比一般 user-space hash table（如 jq 直接吃完整 JSON key）更難攻的主因。

**(2) 隨機 seed + resize → 須瞄準完整 hash collision。** 承 4.1，第 2 段隨機 `hash_seed` 與動態 resize 使 bucket collision 不可用，攻擊者必須構造**完整 32-bit `flow_hash` collision**。所需碰撞寬度因此從 $\log_2 m=15$ bits 提高到 32 bits —— 隨機 seed 的作用不是隱藏 bucket，而是多吃掉約 17 bits 的 entropy budget。

**(3) 多 mask（TSS）。** megaflow 依 mask 分群，range 取所有 mask 欄位的 union，同一封包可能跨多個 mask 查找。本研究固定單一 mask shape 以隔離雜湊函式品質，不混入 TSS 維度（後者見 §1.5）。

**模型保真度驗證。** 由於攻擊在離線構造、必須與 kernel 實際雜湊逐位元一致才會在真實表碰撞，先以 `ovs_keydump` 取 64 筆真實 (masked-key, kernel hash)，用離線 jhash2（22 words、little-endian、initval=0）重算：**64/64 完全吻合**，確認離線模型忠實、構造出的碰撞植入後會在真實表成立。

> 小結：OVS 屬「受限的案例」—— 弱雜湊（seed=0 jhash2）雖可被離線重算，但可利用性還要看 masked-key entropy budget 是否足以在 32-bit 碰撞寬度下湊出足量 keys。這正是通用 robustness 分析中「不能只問雜湊弱不弱，要問攻擊者能否構造足夠碰撞」的具體化。

### 4.4 在真實 kernel 重現 HashDoS

依 §2.3 的 targeted 構造，但目標改為完整 hash collision：離線在可控的 src_ip／dst_ip 位元組上暴搜，找出 $K=16$ 個使 `flow_hash`（seed=0 jhash2、88-byte masked key）輸出皆等於同一目標值 `0xcaa92980` 的 key。將其轉成 16 條 exact-match OpenFlow 規則植入 br0，灌入對應封包後量測。

離線搜尋的核心是在攻擊者可控欄位（src_ip／dst_ip 位元組）上暴搜「完整 32-bit jhash2 等於目標值」的 key，與 §3.1 良性 `fill_key` 對稱，此處為 adversarial 構造（`find_jhash_collision.c`）：

```c
/* worker:隨機填可控欄位 → 算完整 jhash2 → 比目標值;命中即收入 collision set */
for (i = 0; i < g_var_words; i++)
	cand[g_var_start + i] = (uint32_t)splitmix64(&st);     /* 隨機 src_ip / dst_ip */
if ((jhash2(cand, g_nwords, 0) & g_mask) == g_target)      /* g_mask=0xffffffff = 完整 32-bit */
	/* 記錄此 key,湊滿 K 個即完成;期望嘗試 K·2^32(見 §2.4 成本不對稱) */
```

此處 `jhash2` 為核心 `include/linux/jhash.h` 逐位元移植、`initval=0`（即 OVS `flow_hash`），離線值須與 kernel 實算逐位元一致，碰撞植入後才會在真實表成立——此一致性已由 §4.3 的 64/64 模型保真度驗證背書。

結果（`results/ovs/part3_attack_collision.md`）：

| 指標 | 值 |
| --- | --- |
| 16 條 flow 的 in-kernel `flow_hash` | 全部 = `0xcaa92980`（`ovs_keydump` 確認） |
| 靜態 `ovs_buckets` | 單一 bucket chain = 16，$L_{\max}=16$，$C=120=\binom{16}{2}$，$H_{\text{norm}}\approx0.03$ |
| 動態 `ovs_probelen` | probe 數延伸到 16（對照 baseline max ≤ 8） |

16 條不同 IP 的 flow 因完整 hash 相同而落入同一 bucket，串成長度 16 的 chain，打到該桶的封包逐一比對需走滿 16 個節點。這就是 §1.1 的最壞情況（$O(1)\to O(K)$）在真實 datapath 的重現，且因瞄準完整 hash collision 而 **seed-／resize- 無關**。$C=\binom{16}{2}=120$ 精確對應 16 條同桶，$H_{\text{norm}}$ 從 baseline 的 0.94 崩到 0.03。

本實驗取 $K=16$ 作結構性示範，未規模化到大 $K$：OVS 的 masked-key entropy budget 與 megaflow 機制使大 $K$ 的構造與植入成本高、邊際資訊有限，而 $O(K)$ 的退化在 $K=16$ 已清楚成立（probe 由 ≤1 升到 16）。

### 4.5 Keyed-hash 防禦與效能成本

最後將同一組（對 jhash 構造的）碰撞集分別在 jhash／hsiphash／siphash 下植入、量測，這是第三章 Result C 在真實 OVS 表的對照；並在同一批 run 量 in-context per-hash 成本（`ovs_hashcycles`）。keyed hash 金鑰為開機隨機（`get_random_bytes`，比照 `ti->hash_seed`），即部署等級條件。

**安全（同一組 keys × 三種雜湊函式）：**

| hash（x86-64 實作） | $L_{\max}$ | max probe | 16 條 flow 的 in-kernel hash |
| --- | ---: | ---: | --- |
| jhash（unkeyed jhash2） | 16 | 16 | 全部相同（`0xcaa92980`） |
| hsiphash（SipHash-1-3） | 1 | 1 | 16 個各不相同 |
| siphash（SipHash-2-4） | 1 | 1 | 16 個各不相同 |

同一組 keys 在 jhash 下單桶 $L_{\max}=16$，在 hsiphash／siphash 下散開回 $L_{\max}=1$、16 個 hash 各異。與 Result C 一致：防禦不在於消除 collision，而在於破壞攻擊者的 offline predictability —— 對 jhash 構造的 set 無法轉移到 secret-keyed 的 hsiphash／siphash。

**效能（per-hash 成本）：** 以 `ovs_hashcycles` 在 88-byte masked key 上量 in-context cycle（鎖頻、取分布 mode 並扣除 rdtsc 對開銷 29 cyc），對照隔離 microbench（`hash_microbench`，88B 內插）：

| hash | in-context per-hash（cyc） | isolated microbench@88B（cyc） |
| --- | ---: | ---: |
| jhash | ~134 | ~85 |
| hsiphash | ~138 | ~78 |
| siphash | ~205 | ~130 |

in-context 絕對值因 cache／pipeline／呼叫開銷高於隔離值，但三者相對排序一致：**jhash ≈ hsiphash < siphash**，且 siphash／jhash ≈ 1.53 在兩種量法下吻合。在 x86-64 上 `hsiphash` 實作為 SipHash-1-3（非 32-bit 平台的 HalfSipHash），因此 per-hash 成本與 jhash 幾乎相同，卻提供 keyed 防禦；siphash 多約 50%。

**取捨結論：** keyed hash 多付的固定 per-hash 開銷（hsiphash 在 x86-64 近乎零、siphash +50%），遠小於它擋掉的 chain-walk —— jhash 在攻擊下每次查找走 $O(K)$ 個節點（本例 16，規模化下隨 $K$ 線性），keyed hash 維持 $O(1)$。因此就 HashDoS 防禦而言，將 OVS `flow_hash` 的第 1 段改為 keyed hash 是低成本、可擋的；成本分水嶺在「是否帶祕密金鑰」，而非 rounds 數。

> 限制：(1) $K=16$ 為結構性示範，未掃大 $K$；(2) `hsiphash` 安全性具平台依賴（x86-64 = SipHash-1-3 強，32-bit = HalfSipHash 弱），本結論限 64-bit；(3) per-hash 成本為 in-context mode、DEBUG 樁在跑，非乾淨 throughput benchmark；防禦針對「離線預構碰撞」威脅，key-recovery／online adaptive 等更強模型超出範圍。
 