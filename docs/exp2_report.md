# 實驗二報告：OVS kernel datapath `flow_hash()` 之 jhash / hsiphash / siphash 成本比較

> 狀態：初稿完成（§1 至 §12 全部填寫，待整體校閱）。
> 對應資料：`ovs_datapath_bench/results/v3b/dv3b_formal_perf.csv`、`dv3b_formal_summary.csv`、
> `dv3b_evidence_{jhash,hsiphash,siphash}/`、`ovs_flow_hash_backend_patch.diff`；
> 工具：`run_dv3b_benchmark.sh`、`summarize_dv3b.py`、`collect_backend_evidence.sh`、`benchmark_runbook.md`。

---

## 1. 摘要

本實驗在 Linux 核心（kernel 版本 6.8.0-124-generic）的 Open vSwitch datapath 之
`net/openvswitch/flow_table.c::flow_hash()` 中，以可切換的三種雜湊函式（`jhash2`、`hsiphash`、
`siphash`）取代原本固定的 `jhash2`，並透過一個 `noinline` 的包裝函式 `ovs_flow_hash_backend()`
將雜湊函式的成本隔離出來，使 perf 能公平地量到各雜湊函式的成本佔比。

在固定的 D-v3B multimask 工作負載、CPU0-scoped 的 perf 量測、CPU-bound 條件，以及每種
雜湊函式重複 N=10 次的相同協議下，量得三者在包裝函式 `ovs_flow_hash_backend()` 的成本
（children 百分比）如下：

| 雜湊函式 | `ovs_flow_hash_backend()` children%（N=10） | 每次雜湊呼叫估計成本 |
|---|---|---|
| hsiphash | 5.65 ± 0.12 | 約 71 cycles |
| jhash | 9.50 ± 0.14 | 約 124 cycles |
| siphash | 9.95 ± 0.13 | 約 133 cycles |

**成本排序為 hsiphash < jhash < siphash。** 另外透過核心內量測，確認此工作負載下 `flow_hash()`
的輸入長度約為 **88 bytes**（佔 98% 以上的呼叫）。在此長度，實驗一（純函式 microbenchmark）的
primitive 成本排序與本實驗一致，且 hsiphash、siphash 的絕對成本與實驗一在 64 至 128 bytes 區間相符。

**範圍限定**：以上為特定工作負載、特定處理器、特定核心版本下的 **integration 層級**成本
（包含共同的包裝函式開銷），並非純雜湊 primitive 的 microbenchmark。真實部署環境下 `flow_hash()`
的輸入長度分布**尚未量測**（列為後續工作），因此「將 jhash 換成 keyed 雜湊函式在真實情境下的效能效益」
**尚不能定論**。此效能面向取決於真實輸入長度，且在輸入偏短時有可能對 jhash 有利。另一方面，
安全性面向（現行 `jhash2` 使用固定的 seed=0、輸出可預測，理論上可被 hash-flooding 攻擊）與輸入
長度無關，可獨立成立。

---

## 2. 背景與動機

### 2.1 雜湊表與 hash-flooding 阻斷服務攻擊
核心網路子系統大量使用雜湊表（hash table）做查找，例如 socket、連線追蹤、鄰居表、封包導向等。
若所用的雜湊函式**可被預測**，攻擊者可刻意建構大量「雜湊到同一個 bucket」的輸入，使查找從平均
O(1) 退化為 O(n)，形成 **hash-flooding 阻斷服務（DoS）攻擊**。

### 2.2 Linux 核心走向 keyed 雜湊函式
為抵抗上述攻擊，Linux 核心已將多處安全敏感、且會吃外部可控輸入的雜湊改為 **keyed 的 SipHash 系列**，
其金鑰為每次開機隨機產生的秘密值，攻擊者無法預測輸出。例如封包導向使用的 `__skb_get_hash`
（flow dissector）、socket 查找、TCP 初始序號（`secure_seq.c`）等都已改用。`jhash` 為非加密、
無秘密金鑰的雜湊函式，僅有可預測的 seed，不具此抗性。

### 2.3 OVS 流量表仍使用 jhash2
OVS kernel datapath 的 megaflow 查找（tuple-space search）在 `flow_table.c::flow_hash()` 中，
對封包的 flow key 範圍呼叫 `jhash2(..., 0)`，其 **seed 固定為 0，完全可預測**。OVS megaflow 的
key 來自封包欄位，部分為外部可控。因此，這個雜湊使用點與上述那些「核心已加強安全防護」的案例
**性質相同**，只是目前尚未做同樣的處理。

### 2.4 研究問題
> 在 OVS kernel datapath 的 `flow_hash()`，將 `jhash2` 換成 keyed 的 hsiphash 或 siphash，
> **成本是多少**？維持現行 jhash 的**效能正當性**是否成立？

實驗一（`hash_microbench/`）已在純函式層級量測三種雜湊函式的 primitive 成本，包含 cycles、
instructions、cache miss 對輸入長度的關係。**本實驗二**將其推進到**真實 OVS datapath 的
integration 層級**，在固定的工作負載下量測三者在 `flow_hash()` 的成本，並與實驗一交叉對照。

---

## 3. 實驗目標與假說

### 3.1 目標
在 OVS kernel datapath 的 `flow_hash()` integration 層級，量化並比較 `jhash2`、`hsiphash`、
`siphash` 的成本，要求三項。

- 三種雜湊函式在**完全相同**的工作負載、量測範圍、包裝函式整合方式下比較（公平性）。
- 成本能正確算到雜湊函式本身，而非整條 lookup path，也不混入核心其他位置的雜湊使用。
- 結果可重現，變異可量化。

### 3.2 兩個獨立的論點
是否應將 OVS 的 jhash 換成 keyed 雜湊函式，取決於兩件**彼此獨立**的事。

1. **安全性論點（與輸入長度無關）**。`jhash2` 的 seed=0 可預測，理論上可被 hash-flooding 攻擊，
   因此換成 keyed 雜湊函式可加強其安全防護。此論點不論輸入長短皆成立。
2. **效能論點（取決於真實輸入長度）**。換成 keyed 雜湊函式後成本是否可接受，取決於 `flow_hash()`
   的真實輸入長度。原因是三者的相對成本**會隨輸入長度改變**（見實驗一，短輸入時 jhash 最便宜，
   長輸入時 hsiphash 反超）。

### 3.3 本實驗二的範圍，以及明確保留的「待證／可能反向」之處
- 本實驗二量測的是，**在一個固定且可重現的工作負載下**，三種雜湊函式的成本，以及該成本
  對輸入長度的依賴關係。
- 本實驗二**不能明確證明**真實世界的輸入長度分布。該分布由真實部署的 OpenFlow 規則決定，只能以
  真實資料量測（列為後續工作，包含本地 OVN、真實叢集 dump、文獻佐證）。
- **明確保留 null 可能性**。真實部署的 megaflow 因為 OVS 的 megaflow 最佳化策略（盡量 wildcard）
  可能產生**較短**的輸入，使 jhash 落在其最佳區間。若如此，效能論點不成立，整體論述將保守說明為
  「僅具安全性理由」。本報告不預設結論方向。

---

## 4. 方法學

### 4.1 以 noinline 包裝函式隔離雜湊成本

最直覺的做法是直接在 perf 報告裡比較 `jhash2`、`hsiphash`、`siphash` 三個 symbol 的成本，但這對
三者並不公平，因為編譯器對它們的處理方式不同。

- `jhash2` 在 `linux/jhash.h` 宣告為 `static inline`，會被**內聯**進呼叫它的函式，沒有獨立 symbol，
  成本落在呼叫者的 self。
- `hsiphash`、`siphash` 是 `lib/siphash.c` 的 **out-of-line** 函式（實際符號為 `__hsiphash_unaligned`、
  `__siphash_unaligned`），成本落在這些被呼叫的子函式上。

直接比 symbol 等於拿不同的量測基準互比。jhash 的成本藏在被內聯進的函式裡，SipHash 系列的成本則散在
獨立 symbol。為了公平，本實驗在 `flow_hash()` 與實際雜湊函式之間插入一個刻意標記 `noinline` 的
包裝函式。

```c
static noinline u32 ovs_flow_hash_backend(const void *hash_data, size_t hash_len)
{
#if OVS_FLOW_HASH_JHASH
    return jhash2((const u32 *)hash_data, (u32)(hash_len >> 2), 0);
#elif OVS_FLOW_HASH_HSIPHASH
    return hsiphash(hash_data, hash_len, &ovs_flow_hsiphash_key);
#elif OVS_FLOW_HASH_SIPHASH
    u64 h = siphash(hash_data, hash_len, &ovs_flow_siphash_key);
    return (u32)(h ^ (h >> 32));   /* flow_hash() 回傳 u32，故將 64-bit 輸出摺疊 */
#endif
}
```

`noinline` 確保這個包裝函式在三種雜湊函式下都是一個**獨立且穩定的 symbol**。於是 perf 裡的
`ovs_flow_hash_backend` 這一行就是統一的量測點。主要指標選用它的 **children 百分比**，也就是函式
本身的 self 加上它呼叫的所有子函式。

jhash 因內聯，成本落在 self，而且它沒有子呼叫，所以 children 約等於 self。hsiphash 與 siphash 因
out-of-line，包裝函式的 self 約為 0，成本落在子函式，由 children 涵蓋。因此 children 百分比對三者
一致。不論雜湊碼被內聯進包裝函式、或被呼叫出去，都會被計入。這同時構成一個可驗證的預測（見 §6）。

| 雜湊函式 | 編譯型態 | 預期 self | 雜湊成本由何者涵蓋 |
|---|---|---|---|
| jhash | inline | 約等於 children | self（亦即 children） |
| hsiphash | out-of-line | 約為 0 | children（在子函式 `__hsiphash_unaligned`） |
| siphash | out-of-line | 約為 0 | children（在子函式 `__siphash_unaligned`） |

### 4.2 雜湊函式身分驗證

每切換一次雜湊函式都要重新編譯與載入核心模組，因此每一輪都必須確認載入的就是預期的那一個。
本實驗以三項交叉驗證。

1. `flow_table.c` 的 `OVS_FLOW_HASH_*` define。
2. build 產物與已載入模組的 `srcversion` 一致（`modinfo` 對 `/sys/module/openvswitch/srcversion`）。
3. `nm -u openvswitch.ko` 的未定義 symbol，也就是 import 清單。

第三項最具決定性。`srcversion` 只是原始碼的 MD5，會隨任何改動而變，無法單獨指出是哪一種雜湊函式。
`nm -u` 則直接顯示模組需要外部提供的雜湊 symbol。

| 雜湊函式 | srcversion（本版原始碼） | `nm -u` 應出現 |
|---|---|---|
| jhash | `9934512B440806A9DEFA77A` | （無 out-of-line 雜湊 import） |
| hsiphash | `670B9FE03F3CECAF4D7F865` | `__hsiphash_unaligned` |
| siphash | `75AA9FCC444232089DB6AD7` | `__siphash_unaligned` |

jhash 因內聯而沒有外部雜湊 import，正好與另兩者形成對照。

### 4.3 D-v3B multimask 工作負載設計

要量到雜湊成本，前提是雜湊在整體開銷中佔得夠大、不被雜訊淹沒。先前以 L4 埠號配對為主的 D-v2-mid
baseline，量到的 `ovs_flow_hash_backend` children 百分比僅約 0.7%，太小而不可靠。放大雜湊訊號有兩條
彼此獨立的途徑。一是加長每次雜湊的輸入位元組數，二是提高每個封包觸發的雜湊次數（hit/pkt）。

D-v3B 採用第二條。OVS 的查找是 tuple-space search，每個封包會依序對各個 mask（subtable）做一次
masked-key 雜湊與查找，直到命中。因此只要存在多個被頻繁使用的 mask，每個封包就會做多次雜湊，
hit/pkt 隨之上升。D-v3B 以八個規則家族構成，每個家族 match 不同的欄位組合（皆含 `nw_dst`，再分別
搭配 `nw_src`、`tp_src`、`tp_dst` 的不同子集），並讓流量平均分散到各家族，使資料路徑形成多個
mask 形狀。實測得到約 7 個 mask、hit/pkt 約 4.0，將 children 百分比拉到個位數百分比的可量測範圍。

過程中也測試並否決了一條途徑，值得記錄。原本想同時用 IP prefix 長度變化來增加 mask 多樣性，預期
不同 prefix 會產生不同 mask，但實測失敗。OVS 預設不會產生 prefix megaflow，會把 IP 直接 unwildcard
到 /32，使八個 prefix 組合塌成同一個 mask，children 百分比反而下降。結論是 mask 的多樣性必須來自
「match 哪些欄位」的差異，而非 prefix 長度。

### 4.4 量測範圍與環境控制

**CPU0-scoped 量測（`-C 0`）。** perf record 的 children 百分比是「落在該函式子樹的取樣數」除以
「總取樣數」。若用系統全域量測（`-a`），分母會納入所有核心的取樣，而閒置與背景核心的取樣數**每次
不固定**，使分母浮動、children 百分比不穩，實測曾在 4.3% 至 7.7% 之間跳動。將 perf record 與
perf stat 都限定到實際做封包轉發的核心（CPU 0），分母就只含該核心的工作，數值穩定，語意也更精準，
代表「轉發核心的 cycle 中花在雜湊的比例」。

**CPU-bound gate。** 系統層指標（cycles/pkt、%soft）要能反映雜湊成本，前提是轉發核心確實是瓶頸。
以 `mpstat -P ALL` 確認，CPU 0 的 `%idle` 為 0、`%iowait` 為 0，時間集中在 `%soft`（約 66%）與
`%sys`（約 33%），其餘核心閒置。`%iowait` 為 0，加上資料路徑為核心內 pktgen 加 veth（無實體 I/O），
據此判定工作負載為「轉發路徑上的單核 CPU-bound」，而非 IO-bound。

**SMT 雙生核與環境控制。** CPU 0 的同時多執行緒（SMT）雙生核為 CPU 6（`thread_siblings_list` 為
`0,6`，共用同一個實體核）。CPU 6 上的任何活動都會與轉發工作爭用同一實體核的執行單元與 L1／L2 快取，
使 IPC 下降、`masked_flow_lookup` 百分比異常升高。因此量測工具（perf、mpstat）以 `taskset` 固定到
CPU 3，量測期間並保持機器閒置。受污染的回合（IPC 低於 1.5、`masked_flow_lookup` 百分比飆高）一律
作廢。

### 4.5 指標分層與衍生指標

量測指標分為五層，避免把不同性質的數字混為一談。

| 層 | 內容 | 角色 |
|---|---|---|
| Layer 0 | srcversion、`nm -u`、flows、masks 數、hit/pkt、pktgen errors | 有效性，非效能結論 |
| Layer 1 | `ovs_flow_hash_backend` 的 children%／self%、每包雜湊成本 | 雜湊函式主結論 |
| Layer 2 | `masked_flow_lookup` 的 children%／self%、hash/lookup 比例 | lookup path |
| Layer 3 | cycles/pkt、%soft（須通過 CPU-bound gate） | 系統層 |
| Layer 4 | 函式級延遲分布 | 本實驗未做 |

衍生指標由原始量測推得，封包數以 `pps × 視窗長度` 估計。

```text
cycles_per_packet          = cycles / (pps × 視窗秒數)
hash_cycles_per_packet     = cycles_per_packet × ovs_flow_hash_backend_children%
cycles_per_hash_invocation = hash_cycles_per_packet / hit_per_packet
hash_lookup_ratio          = ovs_flow_hash_backend_children% / masked_flow_lookup_children%
```

`hash_cycles_per_packet` 即使 `cycles_per_packet` 含 pktgen 產生封包的成本仍然乾淨，因為乘上
children 百分比後只取出屬於雜湊的那一份。產生封包的成本落在其餘比例，不會被計入。

### 4.6 量測協議

每種雜湊函式重複 N=10 次，三者採用完全相同的協議。先以一段 warm-up 流量建立 flows（不計入），
確認 `flows ≥ 9000` 才開始（flows gate）。正式量測**不**清除 flows，使量測落在純 fast-path 的
steady state。在同一段連續 pktgen 流量中，先做 10 秒 perf record（`-C 0`，取 children 與 self），
再做 10 秒 perf stat（`-C 0`，取 cycles 與 instructions），並以背景 mpstat（`-P 0`）記錄 %soft。
受污染回合依 §4.4 的條件作廢。先前以舊協議跑的 pilot 與正式量測分開保存、不混用，確保正式對照表的
所有回合來自同一協議與同一 N。

### 4.7 量測工具與環境

量測環境固定為 kernel 6.8.0-124-generic、Intel Core i5-10500（12 個邏輯核心）、CPU governor 設為
`performance`。所用的量測軟體堆疊如下。

- **pktgen**。核心內封包產生器，依 D-v3B 的 IP 與埠號範圍產生 UDP 流量。
- **perf**。`perf record` 以取樣方式取得 children 與 self 百分比，`perf stat` 讀硬體計數器取得
  cycles 與 instructions，兩者都以 `-C 0` 限定到轉發核心。
- **mpstat**。記錄各核心使用率，用於 CPU-bound gate 判定，以及記錄 %soft 作為系統層佐證。

三個自訂腳本將上述流程記錄成可重現的步驟。

| 腳本 | 用途 |
|---|---|
| `run_dv3b_benchmark.sh` | 對單一雜湊函式跑 N 輪，含 warm-up、flows gate、perf record/stat、mpstat，結果逐筆寫入 CSV |
| `summarize_dv3b.py` | 讀 CSV，計算平均值與標準差，以及 §4.5 的衍生指標，產出 summary |
| `collect_backend_evidence.sh` | 為每種雜湊函式保存身分（srcversion、`nm -u`）與 call-tree 證據 |

完整的重現步驟記錄在 `benchmark_runbook.md`（見 §12）。

### 4.8 各指標的實際取得方式

為了讓本報告可重現，也方便日後回頭查證每個數字怎麼來的，以下列出各指標實際使用的指令與讀法。

- **children% 與 self%**。先以 `sudo perf record -C 0 -g -o /tmp/p.data -- sleep 10` 取樣，再以
  `sudo perf report -i /tmp/p.data --stdio` 產生報告，在輸出中找到 `[k] ovs_flow_hash_backend`
  那一行，最前面兩欄即為 children% 與 self%。`masked_flow_lookup` 用同樣讀法。
- **cycles、instructions、IPC**。`sudo perf stat -C 0 -e cycles,instructions -- sleep 10`，
  輸出直接列出兩個計數器的值，以及 `insn per cycle`（也就是 IPC）。
- **%soft**。`mpstat -P 0 1 N` 對 CPU 0 每秒取一筆、共 N 筆，最後的 Average 列為平均，讀 `%soft`
  欄。%soft 是該核心花在軟體中斷（softirq）的時間比例，OVS 的封包接收與查找正是在 softirq 中執行。
  需注意 %soft 涵蓋該核心**所有** softirq，並非只有雜湊，因此只作為系統層的概略佐證。
- **flows、masks 數、hit/pkt**。`sudo ovs-dpctl show`，讀輸出的 `flows:` 與
  `masks: ... total:N hit/pkt:M`。
- **pps**。讀 pktgen 結束後的輸出（`Result: OK: ... Xpps`）。
- **雜湊輸入長度（range_n_bytes）**。沒有現成指令可讀，需在核心內加診斷量測，做法見 §7。

## 5. 結果

### 5.1 工作負載有效性

三種雜湊函式在量測期間的工作負載狀態幾乎一致，確認三者跑在同一個環境，比較成立。

| 雜湊函式 | flows | masks 數 | hit/pkt | pktgen errors |
|---|---|---|---|---|
| hsiphash | 約 15440 | 7 至 8 | 4.01 | 0 |
| jhash | 約 15439 | 7 | 4.00 | 0 |
| siphash | 約 15440 | 7 | 4.01 | 0 |

hit/pkt 穩定在約 4.0，代表每個封包平均對 4 個 mask 做雜湊與查找，三者一致，因此成本差異可歸於
雜湊函式本身，而非工作負載不同。

### 5.2 雜湊函式成本（Layer 1 與 Layer 2）

以下為每種雜湊函式 N=10 的平均值，誤差為樣本標準差。表格依成本由低到高排列。

| 雜湊函式 | children% | self% | 每包雜湊 cycles | 每次呼叫估計 cycles | `masked_flow_lookup` children% | hash/lookup 比例 |
|---|---|---|---|---|---|---|
| hsiphash | 5.65 ± 0.12 | 約 0.02 | 285 | 約 71 | 26.46 ± 0.28 | 21.3% |
| jhash | 9.50 ± 0.14 | 約 9.46 | 497 | 約 124 | 27.05 ± 0.33 | 35.1% |
| siphash | 9.95 ± 0.13 | 約 0.03 | 535 | 約 133 | 30.63 ± 0.33 | 32.5% |

**成本排序為 hsiphash < jhash < siphash。** 各組的標準差皆不超過 0.14，遠小於彼此之間的差距，
排序穩定可信。

兩點值得注意。第一，**hsiphash 雖然是 keyed 雜湊函式，成本卻比 jhash 低**，每包雜湊 cycles 為 285
相對於 497，約低四成。第二，**siphash 相對 jhash 的成本增加有限**，每包 535 相對於 497，約高 8%。
self 百分比的型態（jhash 約等於 children、hsiphash 與 siphash 約為 0）符合 §4.1 對 inline 與
out-of-line 的預測，詳細佐證見 §6。

### 5.3 系統層觀察（Layer 3）

在通過 CPU-bound gate 的前提下，系統層指標與上述雜湊成本排序方向一致。

| 雜湊函式 | cycles/pkt | pps | IPC | %soft |
|---|---|---|---|---|
| hsiphash | 5052 | 約 880 K | 1.90 | 64.9 |
| jhash | 5228 | 約 851 K | 1.82 | 66.3 |
| siphash | 5379 | 約 826 K | 1.92 | 67.2 |

cycles/pkt（轉發核心每處理一個封包的總成本）與 %soft 都隨雜湊成本上升，pps 則隨之下降，三項與
Layer 1 的排序一致。IPC 方面，hsiphash 與 siphash（約 1.90 至 1.92）高於 jhash（約 1.82），
與「SipHash 系列的 ARX 運算具較高指令級平行度」的假說相符，此點屬合理解釋而非已證結論，留待 §9 討論。

需提醒的是，cycles/pkt 為轉發核心的**整體**每包成本，包含 pktgen 產生封包與 OVS 轉發兩部分
（兩者共用 CPU 0），因此其絕對值不應單獨解讀為純轉發成本。雜湊本身的每包成本請見 §5.2 的
「每包雜湊 cycles」（由 cycles/pkt 乘上 children 百分比取得，已排除產生封包的部分）。

## 6. 證據與方法學自我驗證

### 6.1 雜湊函式身分
每種雜湊函式都保存了一份身分證據（`dv3b_evidence_{jhash,hsiphash,siphash}/identity.txt`），內含
已載入模組的 `srcversion`、build 產物的 `srcversion`、以及 `nm -u` 的雜湊 import。三者與 §4.2 的
對照表相符。jhash 的 `nm -u` 沒有任何 out-of-line 雜湊 import，hsiphash 有 `__hsiphash_unaligned`，
siphash 有 `__siphash_unaligned`，確認每一輪載入的都是預期的雜湊函式。

### 6.2 inline 與 out-of-line 的預測命中
§4.1 預測 jhash 的 self 會約等於 children（inline），hsiphash 與 siphash 的 self 會約為 0
（out-of-line）。實測（各取一輪的 flat 數字）與預測一致。

| 雜湊函式 | children% | self% | 判讀 |
|---|---|---|---|
| jhash | 9.13 | 9.09 | self 約等於 children，成本在內聯碼，確為 inline |
| hsiphash | 5.56 | 0.23 | self 約為 0，成本在子函式，確為 out-of-line |
| siphash | 9.81 | 0.29 | self 約為 0，成本在子函式，確為 out-of-line |

這代表量測工具本身通過了一致性檢查，包裝函式的 children 百分比確實是公平的共同量測點。

### 6.3 從 perf caller tree 找出符號撞名並排除非觀測函式
這一段記錄實際的摸索過程，因為它說明了為什麼主指標不能直接看 flat 清單。

一開始的想法是直接讀 perf flat 清單裡的雜湊 symbol。在 siphash build 下，flat 清單的
`__siphash_unaligned` 約為 14.68%。若直接把它當成「siphash 的成本」，會高估。

起疑的點是，在 jhash build（原始碼裡完全沒有 siphash）下，perf 報告竟然也出現 `__siphash_unaligned`。
這表示它不全是我們的雜湊，核心其他地方也在用同一個 symbol。

為了查清楚，改用 call tree 展開呼叫路徑，看 `__siphash_unaligned` 是從誰呼叫下來的。指令為
`sudo perf report --stdio -g graph,0.1,callee`，輸出保存於各 evidence 目錄的 `calltree.txt`，
其中關鍵的一段節錄如下。

```text
# 節錄自 dv3b_evidence_siphash/calltree.txt
--14.68%--__siphash_unaligned
          |--9.51%--ovs_flow_hash_backend          （我們的 flow_hash）
          |          masked_flow_lookup
          |          flow_lookup.constprop.0
          |          ovs_flow_tbl_lookup_stats
          |          ovs_dp_process_packet
          |          ...
           --（其餘約 5%）--__skb_get_hash          （核心 flow dissector，與 OVS 無關）
                            __skb_flow_dissect
                            ...
```

可以看到 `__siphash_unaligned` 的 14.68% 分成兩條來源。

- 約 9.51% 來自 `ovs_flow_hash_backend ← masked_flow_lookup ← flow_lookup ← ovs_dp_process_packet`，
  這是我們的 `flow_hash()`。
- 其餘約 5% 來自 `__skb_get_hash ← __skb_flow_dissect`，這是核心收封包時計算 skb 雜湊用的
  flow dissector，與 OVS 的雜湊函式無關，而且三種 build 都會跑。

排除方式是只取「掛在 `ovs_flow_hash_backend` 底下」那一條（caller-edge 成本歸屬），把
`__skb_get_hash` 那一條當作背景雜訊排除。而這正好是包裝函式 children 百分比天生會做的事。children
只涵蓋從自己往下的子樹，`__skb_get_hash` 掛在不同的 parent，自動不會被計入。

同樣的撞名在 hsiphash 也出現。`__hsiphash_unaligned` 全域為 7.28%，但掛在包裝函式底下的只有 5.27%，
其餘來自核心其他使用者。

因此結論是，不能直接看 flat 清單的 symbol，否則會把核心其他位置的雜湊使用一起算進來。必須看包裝
函式的 children，或等價地用 call tree 的 caller-edge 區分。若忽略這點，siphash 會被高估約 50%
（14.68 相對於 9.51）。

### 6.4 patch 只改雜湊選擇與包裝函式
完整 diff 保存於 `ovs_flow_hash_backend_patch.diff`。改動範圍只有雜湊函式的選擇巨集、三把金鑰常數、
以及 `ovs_flow_hash_backend()` 包裝函式與 `flow_hash()` 的接線。megaflow 查找邏輯本身（mask 套用、
key 比對、bucket 走訪）完全沒有更動。因此三種雜湊函式之間的成本差異，可歸於雜湊函式本身，而非
lookup path 的改動。

## 7. `flow_hash()` 輸入長度量測

### 7.1 雜湊的輸入是什麼，以及一個常見的誤會
`flow_hash()` 餵給雜湊函式的輸入是 `range_n_bytes(range)`，也就是 megaflow mask 在 flow key 上
涵蓋的那一段位元組。這裡有一個容易混淆的點要先釐清。pktgen 的 `pkt_size=64` 指的是**封包大小**
（64-byte 的封包），與雜湊輸入長度**無關**。雜湊輸入是核心內 `sw_flow_key` 結構的一段，由
megaflow mask 決定，跟線上那個 64-byte 封包不是同一回事。

更進一步說，輸入長度由 **megaflow mask（也就是 OpenFlow 規則）** 決定，而非核心或雜湊函式本身。
`range->start` 是 `flow_key_start`，是一個從 metadata 與 L2 起算的固定起點，並不是「第一個被 match
的欄位」。`range->end` 則是最後一個被 match 的欄位的結尾。因此即使是「只 match `nw_dst`」的 mask，
範圍也會從 key 起點一路算到 `nw_dst`，得到數十位元組。

### 7.2 量測方法
OVS 沒有把 `range_n_bytes` 暴露給使用者空間，因此需要在核心內加診斷。本實驗在
`ovs_flow_hash_backend()` 內加入一段以 `OVS_FLOW_HASH_DEBUG_LEN` 開關控制的計數器，統計每個
`hash_len` 出現幾次，並每一千萬次呼叫 dump 一次累積直方圖。

```c
#if OVS_FLOW_HASH_DEBUG_LEN
    static atomic64_t ovs_hash_hist[160];      /* 每個 hash_len 的次數 */
    static atomic64_t ovs_hash_calls;
    unsigned long n;

    if (hash_len < 160)
        atomic64_inc(&ovs_hash_hist[hash_len]);
    n = atomic64_inc_return(&ovs_hash_calls);
    if (n % 10000000UL == 0) {
        /* 印出目前累積的 hash_len 直方圖（取最後一次最完整） */
        ...
    }
#endif
```

這是一次性的診斷 build。它改動了原始碼，因此 `srcversion` 會與正式 build 不同，而且這段計數器
每個封包都會執行，會污染 cycle 量測，所以量完輸入長度後便將開關設回 0、重新 build，回到乾淨的
正式版本。本節的數據與 §5 的成本量測來自不同的 build，互不污染。

### 7.3 結果
在 D-v3B 工作負載下，最後一次直方圖 dump（累積 6000 萬次呼叫）節錄如下。

```text
=== ovs_flow_hash_backend hist @ 60000000 calls ===
  hash_len= 40 count=36
  hash_len= 48 count=1
  hash_len= 64 count=18
  hash_len= 72 count=437331
  hash_len= 88 count=59007245
  hash_len=104 count=114898
  hash_len=120 count=440459
  hash_len=136 count=9
  hash_len=152 count=3
```

換算成佔比後，分布其實高度集中。

| hash_len（bytes） | 次數 | 佔比 | 來源判讀 |
|---|---|---|---|
| 88 | 59,007,245 | 98.35% | D-v3B 主要流量 |
| 120 | 440,459 | 0.73% | D-v3B |
| 72 | 437,331 | 0.73% | D-v3B |
| 104 | 114,898 | 0.19% | D-v3B |
| 40／48／64／136／152 | 個位至雙位數 | 約 0% | reload 時的 ping sanity 與少量瞬間 mask |

關鍵結論有兩點。第一，**D-v3B 的雜湊輸入實際上幾乎是單一長度 88 bytes**（佔 98.35%），而非先前
從「出現過哪些長度」所誤以為的廣分布。第二，**輸入幾乎全部落在 64 bytes 以上**（小於 64 的只有
個位數次），這一點在 §8 與實驗一交叉對照時是關鍵，因為它決定了 D-v3B 落在 hsiphash 比 jhash 便宜
的區間。次數為個位至雙位數的那幾個長度，是 reload 過程的 ping sanity 與少量瞬間 mask 造成的，
並非 D-v3B 的穩態流量。

## 8. 實驗一與實驗二交叉對照

### 8.1 實驗一的長度相依成本
實驗一在純函式層級量測三者每次呼叫的 cycle 數，並掃過多種輸入長度。結果如下（每格為 10 次重複的
平均，單位 cycles）。

| 輸入長度（bytes） | jhash2 | hsiphash | siphash | 該長度的排序 |
|---|---|---|---|---|
| 16 | 16.7 | 28.6 | 45.4 | jhash < hsiphash < siphash |
| 32 | 26.9 | 38.3 | 64.5 | jhash < hsiphash < siphash |
| 64 | 61.4 | 57.2 | 101.9 | hsiphash < jhash < siphash |
| 128 | 119.9 | 95.9 | 174.8 | hsiphash < jhash < siphash |
| 256 | 249.8 | 171.0 | 324.9 | hsiphash < jhash < siphash |

這裡有兩個重要觀察。第一，**排序會隨輸入長度改變**。短輸入（32 bytes 以下）jhash 最便宜，長輸入
（64 bytes 以上）hsiphash 反超，交叉點約在 64 bytes。第二，**siphash 在所有長度皆最貴**。
合理的解釋是 jhash2 的成本隨長度線性累積得快，而 hsiphash（在 64 位元核心上實作為減輪的
SipHash-1-3）固定啟動成本較高、但每位元組成本較低，因此輸入夠長才划算。

### 8.2 與實驗二對照
§7 量得 D-v3B 的雜湊輸入約為 88 bytes，落在實驗一的「64 bytes 以上」區間，也就是 hsiphash 比
jhash 便宜的那一側。實驗二量到的排序正是 hsiphash < jhash < siphash，與實驗一在此區間的排序一致。

把實驗一在 88 bytes 的成本（以 64 與 128 的數據內插）與實驗二每次呼叫的估計成本並列。

| 雜湊函式 | 實驗一 @88 bytes（內插，cycles） | 實驗二每次呼叫（cycles） | 比較 |
|---|---|---|---|
| hsiphash | 約 72 | 約 71 | 相符（約 1%） |
| siphash | 約 129 | 約 133 | 相符（約 3%） |
| jhash | 約 83 | 約 124 | 實驗二偏高約 50% |

hsiphash 與 siphash 兩者的絕對成本在兩個獨立實驗間相符到個位數百分比。jhash 在實驗二明顯偏高，
此處誠實記錄並提出一個假說，但不當作已證結論：jhash2 的內部是一條較長的相依鏈，在真實 datapath
中每次呼叫是孤立的，無法像實驗一的緊湊迴圈那樣跨呼叫重疊、填滿管線，因此延遲被完整曝露。SipHash
系列單次呼叫內的指令級平行度較高，較不受此影響。由於 hsiphash 與 siphash 使用相同的每包估計方式
卻吻合，可排除「每包除以 hit/pkt 的估計方式」本身造成此偏差。

### 8.3 交叉印證的意義
兩個層級完全不同的量測（實驗一的純函式 microbenchmark 與實驗二的 OVS integration）在排序上一致，
其中 **siphash 在兩個實驗、所有長度都最貴**，是最穩固的不變量。更重要的是，§7 量到的 88 bytes
讓這個對照不只是方向一致，而是能明確說出「為什麼一致」，因為它把實驗二定位在實驗一曲線上 hsiphash
低於 jhash 的那一段。需重申的是，實驗一與實驗二在不同的核心版本上執行（實驗一為 6.8.0-111，實驗二
為 6.8.0-124，處理器同為 i5-10500），因此穩健的比較是排序，絕對值的相符（特別是 hsiphash 與
siphash）則是額外的佐證。

## 9. 討論與範圍限定

### 9.1 結果的意義
本實驗在 88 bytes 的雜湊輸入下量到 hsiphash < jhash < siphash。這個結果對「OVS 維持 jhash 是因為
它最快」這個假設提出了直接的反例。在此輸入長度，keyed 的 hsiphash 不僅沒有比 jhash 慢，每包雜湊
成本反而低約四成（285 相對於 497 cycles），而完整的 siphash 相對 jhash 也只貴約 8%。

### 9.2 對「是否換掉 jhash」的意涵
§3.2 提出兩個獨立論點，這裡以實驗數據重新檢視。

安全性論點與輸入長度無關，因此不受本實驗的輸入長度影響。`jhash2` 的 seed 固定為 0、輸出可預測，
理論上可被 hash-flooding 攻擊，而 keyed 的 hsiphash 與 siphash 不可預測。這個理由在任何輸入長度下
都成立。

效能論點則取決於真實輸入長度。在 88 bytes（本實驗的工作負載）下，效能論點對換掉 jhash 有利，因為
hsiphash 更便宜。但這個 88 bytes 是由 D-v3B 的規則決定的，不代表真實部署。若真實部署的雜湊輸入較短
（小於約 64 bytes），排序會反轉成 jhash 最便宜，效能論點便不成立。因此一個誠實的 patch 決策邏輯是，
先量出真實輸入長度落在交叉點的哪一側，再決定效能論點是否站得住。安全性論點則無論如何都可獨立支撐
換成 keyed 雜湊函式。

## 10. 限制與效度威脅

### 10.1 合成工作負載偏誤（最關鍵）
D-v3B 是為了放大雜湊訊號而刻意設計的工作負載，它的雜湊輸入長度（88 bytes）由我們自己選的規則決定，
不能代表真實部署。更重要的是，OVS 的 megaflow 最佳化策略會盡量 wildcard 欄位以減少 mask，真實部署
的輸入有可能比 88 bytes 短。因此**不能用一個自己設計成長輸入的工作負載，去證明真實輸入很長**，那會
是循環論證。真實輸入長度只能以真實 controller 產生的規則（例如 OVN、Antrea）或生產環境的 megaflow
dump 來量測，這是後續工作（見 §11）。

### 10.2 量到的是 integration 層級成本，非純 primitive
所有成本都包含共同的包裝函式開銷（函式呼叫的進出場）。由於三者都經過同一個包裝函式，這份開銷對
比較是對稱的、不影響排序，但絕對值不應被解讀為純雜湊 primitive 的成本。

### 10.3 單一處理器與微架構
本實驗只在一顆 x86 處理器（i5-10500）上量測。SipHash 系列的優勢部分來自指令級平行度，而這隨微架構
不同。在不同處理器上，jhash 與 hsiphash 的交叉點可能移動，排序在某些輸入長度也可能不同。

### 10.4 量測上的近似
cycles/pkt 為 steady-state 近似，封包數以整段 pktgen 的平均 pps 乘上 perf 視窗估計，而非該視窗內的
精確計數。每次呼叫成本是估計值，以每包雜湊成本除以 hit/pkt 得到，而 hit/pkt 是累積平均，並非逐包
精確的呼叫次數。%soft 涵蓋整個核心的 softirq，並非只有雜湊。這些都使對應數字適合看趨勢與量級，
不宜當作精準值。

### 10.5 適用範圍
本結論僅適用於使用核心 datapath（`type=system`，也就是 `openvswitch.ko`）的軟體 OVS。採用 DOCA、
硬體卸載、netdev 或 TC-flower 的資料路徑不會走核心的 `flow_hash()`，本結論與潛在 patch 都不適用於
那些路徑。

## 11. 結論與後續工作

### 11.1 結論
在固定的 D-v3B 工作負載（雜湊輸入約 88 bytes）下，三種雜湊函式在 OVS `flow_hash()` 的成本排序為
hsiphash < jhash < siphash。hsiphash 作為 keyed 雜湊函式，在此輸入長度甚至比現行的 jhash 便宜，
siphash 相對 jhash 的成本增加也有限（約 8%）。方法學方面，noinline 包裝函式、呼叫路徑成本歸屬、
CPU0-scoped 量測、N=10 與 CPU-bound gate，經 §6 的自我驗證確認可信。實驗一與實驗二在排序上互相
印證，且 88 bytes 的輸入長度量測讓兩者的一致有了機制上的解釋。

### 11.2 後續工作
本實驗最大的未決問題是真實部署的雜湊輸入長度分布，它決定效能論點是否成立。後續依下列順序進行。

- **P0**。在本機架設 OVN，以標準邏輯拓樸讓 OVN 自己產生 megaflow，量測真實 controller 規則下的
  輸入長度分布。此法的欄位由 OVN 決定，避免手刻規則的循環論證。
- **P1**。向有真實部署（OVN、Antrea、OpenStack）的環境取得唯讀的 megaflow dump（`dump-flows -m`），
  作為生產環境的佐證。
- **P2**。以 OVS 與 OVN 的文獻補充真實 megaflow 欄位複雜度的合理性。

若上述量測顯示真實輸入長度落在 hsiphash 比 jhash 便宜的區間，則效能論點成立，搭配與長度無關的
安全性論點，便構成將 OVS `flow_hash()` 改用 keyed 雜湊函式的 kernel patch 依據。若真實輸入偏短，
則論述保守收斂為僅具安全性理由。

## 12. 附錄：工具與重現步驟

### 12.1 環境
| 項目 | 值 |
|---|---|
| 核心版本 | 6.8.0-124-generic（實驗一為 6.8.0-111-generic） |
| 處理器 | Intel Core i5-10500，12 個邏輯核心 |
| CPU governor | performance |
| 轉發核心 | CPU 0（SMT 雙生核為 CPU 6） |
| 量測工具固定核心 | CPU 3 |

### 12.2 工具與腳本
| 檔案 | 用途 |
|---|---|
| `run_dv3b_benchmark.sh` | 對單一雜湊函式跑 N 輪，含 warm-up、flows gate、perf record/stat、mpstat |
| `summarize_dv3b.py` | 彙整 CSV，計算平均、標準差與衍生指標 |
| `collect_backend_evidence.sh` | 保存每種雜湊函式的身分與 call tree 證據 |
| `benchmark_runbook.md` | 完整的切換、build、reload、量測重現步驟 |

### 12.3 資料
| 檔案 | 內容 |
|---|---|
| `dv3b_formal_perf.csv` | 三種雜湊函式各 N=10 的逐筆量測 |
| `dv3b_formal_summary.csv` | 上者的彙整（平均、標準差、衍生指標） |
| `dv3b_evidence_{jhash,hsiphash,siphash}/` | 身分（identity.txt）、flat 與 call tree（flat.txt、calltree.txt） |
| `ovs_flow_hash_backend_patch.diff` | `flow_table.c` 的改動 |

完整重現步驟見 `benchmark_runbook.md`。
