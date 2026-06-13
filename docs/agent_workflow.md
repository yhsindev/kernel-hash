# Agent Workflow：OVS flow_hash 實驗推進規則

## 專案目標

本專題目標是修改 Linux kernel Open vSwitch datapath 中的 `net/openvswitch/flow_table.c::flow_hash()`，比較 `jhash2`、`hsiphash`、`siphash` 在 OVS flow table lookup path 中的工程可行性與效能影響。

目前主線：

* Experiment 1：kernel module microbenchmark，建立 hash function 純成本模型。
* Experiment 2：OVS datapath benchmark，使用 D-v2-mid workload 建立約 10k UDP-specific datapath flows。
* Experiment 3：collision 與 bucket distribution 分析（安全面）。量 `jhash` / `hsiphash` / `siphash` 在 OVS flow table 的雜湊分布品質：於 flow table 加 debugfs / tracepoint / eBPF instrumentation，統計 bucket chain length、maximum chain depth、lookup probe count、bucket entropy、collision frequency。比較不同 flow set 在三種雜湊函式下的分布差異：
  * 隨機 flow、連續 IP flow、固定目的 IP、變動 source port（測一般分布均勻度）；
  * 刻意搜尋 jhash collision 的 flow set（安全核心）：離線預算出一組在固定 seed 的 `jhash` 下撞同 bucket 的 key，展示其在 `jhash` 製造病態長 chain，但在 keyed 的 `hsiphash`/`siphash` 下散開 —— 直接演示 keyed hash 對 HashDoS 的抵抗。
  * 對應內部：`flow_hash()` → `find_bucket(ti, hash)` 決定 bucket，同 bucket 的 flow 串成 hlist chain，`masked_flow_lookup()` 逐一比對；整張表共用 `ti->buckets`，故分布即「`flow_hash` 把 key 打散得好不好」。

* 背景脈絡（數學/安全）：`hash_32()` 用 Fibonacci hashing 與黃金比例常數 `0x61c88647`（乘法雜湊取高位元改善 bucket 分散，Three-gap theorem）；`jhash`（Jenkins）追求低延遲高吞吐但 unkeyed；`siphash`/`hsiphash` 引入 secret key 抵抗 HashDoS 與 hashtable poisoning。Linux 並未全面改用 SipHash —— OVS datapath hot path（每秒數百萬次查表）下 hash latency / cache locality / branch behavior 比理論安全性更直接影響轉送效能；這正是本專題要量化的取捨。

* 目前優先任務：Experiment 3 instrumentation。先做 lookup probe-count 直方圖（在 `masked_flow_lookup` 數走過的 hlist 節點，複用 `ovs_hashlen` 的 debugfs pattern），再視需要做 table snapshot（chain length 分布 / entropy / max depth）。

---

## Agent 回答原則

在使用者未明確說「收工」、「check-out」、「今天到這裡」以前，所有回答都應視為下一步實作計畫。

每次回答優先提供：

1. 下一步要做什麼。
2. 為什麼現在做這一步。
3. 具體指令。
4. 成功 / 失敗判斷標準。
5. 失敗時應貼哪些輸出。

不要過早導向：

* 收尾
* commit
* 大量整理
* 重複 sanity
* 擴大新實驗分支

---

## Check-in 規則

Check-in 是每日啟動任務用，需保持簡短。

格式：

```markdown
## YYYY-MM-DD — Check-in：主題

### 今日方向
- ...

### 今日任務
1. ...
2. ...
3. ...

### 今日不做
- ...

### 成功標準
- 最低：
- 中等：
- 高：

### 預設下一步
- ...
```

Check-in 不放完整指令、不展開背景、不寫過多備案。

---

## Check-out 規則

Check-out 只在使用者明確要求「check-out」、「收工」、「今天到這裡」、「整理今天成果」時進行。

格式：

```markdown
## YYYY-MM-DD — Check-out：主題

### 今日完成
- ...

### 關鍵結果
- ...

### 目前判斷
- ...

### 未解問題
- ...

### 下一步
- ...

### 文件與資料狀態
- ...
```

Check-out 要避免把 sanity test 寫成正式 benchmark 結論。

---

## Sanity / Controlled Run / Benchmark 區分

### Sanity test

用途：確認功能沒壞。

只判斷：

* build 成功
* reload 成功
* srcversion 對上
* ping 通
* flows 能起來
* pktgen errors = 0

不能用 sanity test 宣稱哪個 hash function 較快。

### Controlled run

用途：收集可判讀的單次 run 資料。

必須保存：

* `dpctl_show_before.txt`
* `dpctl_show_after.txt`
* `lookups_delta.txt`
* `observe_watch.txt`
* `pktgen_output.txt`
* `ping_after.txt`
* `srcversion_loaded.txt`
* `modinfo_openvswitch.txt`
* `perf.data`
* `perf_report_full.txt`

Controlled run 可用來看趨勢，但不能直接當 final benchmark。

### Mini benchmark

用途：做第一版可比較結果。

**主指標：perf 中 `ovs_flow_hash_backend`（noinline wrapper）的 children%。**
這是統一三個 backend、能歸因到 fast-path hash 計算成本的指標
（jhash inline 時 self≈children；hsiphash/siphash out-of-line 看 children）。
完整指標分層見下方「量測指標分層規格（Layer 0–4）」。

**輔助指標：pps、flows、hit/missed/lost delta、pktgen errors、ping。**
這些用來確認 workload 是否有效、datapath 是否正常、perf 樣本是否可信，
**不可**單獨用來宣稱哪個 hash 較快。

最低要求：

* 同一 workload / duration / port range
* 每個 backend 多次 run
* perf 與 pktgen 流量重疊取樣
* 記錄 backend srcversion
* 主對照欄位 = `masked_flow_lookup` cycle%；pps / delta 放輔助欄位

#### Perf run 必須量 steady-state（重要）

D-v2-mid 啟動時 missed/lost 集中在前幾秒的 flow install burst（約 t=3 單秒、
~25k upcalls）。perf 若一邊 install flows 一邊取樣，會混入 upcall/install path，
污染 hash 成本量測。

原則：**先讓 ~9752 flows 建好，再開始 perf 取樣。**
實作（單段連續 pktgen，避免 flows idle timeout 過期）：

```text
install rules → del-flows
→ 背景啟動 pktgen（DURATION 涵蓋 warm-up + perf window，例如 15s）
→ sleep 3–5s（install burst 過、flows 建滿至 ~9752）
→ perf record 10s（落在 steady-state 窗口內）
→ 兩者結束後 perf report
```

（用單段連續 pktgen，而非「warm-up 一段 + perf 另一段」，是為了避免兩段之間
flows idle timeout 過期而再次觸發 install burst。）

#### 量測指標分層規格（Layer 0–4）

原則：hash 只占每包工作的一小部分，backend 之間的差異更小。越貼著 hash 的指標越乾淨，
越末端（pps/throughput）越被稀釋。所以**分層呈現**：主結論用 hash-isolated 指標，
系統層只當佐證且須先過 CPU-bound gate。

**Layer 0 — workload validity（不比快慢，證明實驗有效，每輪必附）**
- backend srcversion + `nm -u` hash symbol（backend 身分）
- `flows_before_perf`（perf window 非空跑）、`masks total`（是否 multimask）、`hit/pkt`（每包 lookup 壓力）
- pktgen errors、OVS lost/missed delta（流量產生器與 datapath 正常）

**Layer 1 — hash backend（主結論核心）**
- `ovs_flow_hash_backend` **children%**（主指標）
- **hash_cycles/packet = (cycles/packet) × children%** — 把比例換成每包絕對成本；
  此式不受瓶頸影響（children% 是占總取樣比例，乘回總 cycles/pkt 即每包 hash cycles）。
- call-tree attribution（hsiphash/siphash 確認 child symbol 真的掛在 wrapper 底下，非 skb-hash noise）

**Layer 2 — lookup path**
- `masked_flow_lookup` children% / self%
- **hash/lookup ratio = ohash_children% / masked_children%**（用 flat 數字，非 call-tree 片段）。
  這是 lookup path **內部比例**，對 pps/系統雜訊不敏感，比單看 children% 更穩、更有說服力。

**Layer 3 — datapath system impact（⚠️ 須先過 CPU-bound GATE）**
- **GATE：先 `mpstat -P ALL 1` 確認轉發核心 `%soft` 貼近 100%（CPU-bound）。**
  若否（瓶頸在單執行緒 pktgen 產包）→ pps/throughput/softirq **不反映** hash 差異，
  此時誠實寫「此 setup 未 CPU-bound，系統層無法歸因」，**不得宣稱 system impact**。
- pps / Mbps（sanity；CPU-bound 時才升為系統佐證）
- `cycles/packet`：須 **core-scoped 到轉發核心**（`perf stat -C <core>`，排除 pktgen sender），否則被稀釋
- softirq `%soft`；（可選）instructions/packet、cache/branch misses

**Layer 4 — latency（supplementary，非主結論）**
- bpftrace histogram 量 **`masked_flow_lookup`**（不要量奈秒級的 wrapper —— kprobe 進出開銷會蓋過訊號）
- 先驗「探針開銷 << 訊號」；只報**相對位移**（「siphash 把分布右移」），不報絕對 ns

呈現原則：主結論 = Layer 1 + Layer 2 ratio；Layer 3 須過 GATE 才算 system impact；
Layer 0 每輪必附；Layer 4 選配。三個 derived metric（hash_cycles/pkt、hash/lookup ratio、
lookup_cycles/pkt）都從現有 perf 資料算得出，不用多跑，優先補。

目前目標是先完成：

* `hsiphash` D-v2-mid perf baseline（已取得：`masked_flow_lookup` 7.72%、
  `__hsiphash_unaligned` 1.32%）
* `jhash` D-v2-mid perf run（steady-state）
* 第一版 `jhash` vs `hsiphash` perf 對照表（主指標 cycle%，pps/delta 輔助）

---

## 目前專案狀態

已完成：

* D-v2-mid workload
* OVS module rebuild / reload pipeline
* jhash-default skeleton
* hsiphash first pass
* hsiphash D-v2-mid sanity + controlled delta run1
* **perf 量 fast-path hash cycle% 可行性確認**
* **hsiphash perf baseline（steady-state）：`masked_flow_lookup` 7.72%、`__hsiphash_unaligned` 1.32%**

預設下一步：

1. 若 hsiphash perf baseline 已保存，切回 jhash backend。
2. build / reload jhash backend（srcversion 須 ≠ hsiphash 的 1489A986…）。
3. 對 jhash 做同一套 **steady-state** perf run（warm-up 後再取樣）。
4. 整理 jhash vs hsiphash 第一版 perf 對照（主指標 `masked_flow_lookup` cycle%）。
5. pps / lost / flows 只放輔助欄位。
6. 對照完成後再決定是否實作 `siphash`。
