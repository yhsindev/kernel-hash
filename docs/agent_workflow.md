# Agent Workflow：OVS flow_hash 實驗推進規則

## 專案目標

本專題目標是修改 Linux kernel Open vSwitch datapath 中的 `net/openvswitch/flow_table.c::flow_hash()`，比較 `jhash2`、`hsiphash`、`siphash` 在 OVS flow table lookup path 中的工程可行性與效能影響。

目前主線：

* Experiment 1：kernel module microbenchmark，建立 hash function 純成本模型。
* Experiment 2：OVS datapath benchmark，使用 D-v2-mid workload 建立約 10k UDP-specific datapath flows。
* 目前優先任務：完成 `jhash` vs `hsiphash` 的第一版 mini benchmark，之後再考慮 `siphash`。

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

**主指標：perf 中 `masked_flow_lookup` 與可見 hash symbol（如 `__hsiphash_unaligned`）的 cycle%。**
這是唯一能歸因到 fast-path hash 計算成本的指標。

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
