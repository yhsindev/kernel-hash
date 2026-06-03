# Experiment Log

本檔案記錄每日實驗進度、觀察結果與下一步。  
原則：只記錄會影響實驗設計或後續操作的資訊，不寫完整報告。

---

## 2026-05-27 — OVS workload validation

### 今日目標
- 驗證 UDP source port variation 是否會增加 OVS datapath flow diversity。
- 釐清五元組變化、OpenFlow rules、megaflow mask 與 `flow_hash()` 成本的關係。

### 今日操作
- 使用 `send_microflows.py` 在 `ns1` 產生 UDP packets。
- 封包格式：`10.0.0.1:random_src_port -> 10.0.0.2:9000`。
- 使用 `tcpdump` 在 `ns2` 確認封包到達。
- 使用 `ovs-dpctl show`、`ovs-dpctl dump-flows`、`ovs-dpctl dump-flows -m` 觀察 datapath flows 與 masks。
- 嘗試加入 port-sensitive probe rules，觀察 flow/mask 行為是否改變。

### 觀察結果
- Python generator 可成功產生 source port 變化的 UDP microflows。
- `ns2` 可透過 `tcpdump` 觀察到 UDP packets，確認封包通過 OVS bridge。
- 在目前設定下，datapath flows 仍維持少數幾條，沒有隨 source port variation 大量增加。
- `dump-flows -m` 顯示 UDP port mask 仍為 partial mask，而不是完整 `0xffff` exact match。

### 目前判斷
- 目前結果只能支持：在 `NORMAL` forwarding 或目前 probe rules 下，單純變化 UDP source port 不足以產生大量 datapath flow diversity。
- 目前還不能推論「五元組變化本身一定不足以破壞 megaflow cache」，因為尚未測試同時變化 `src_port + dst_port`、`src_ip + src_port` 等情境。
- 對 Experiment 2 而言，重點不只是讓封包欄位變化，而是要設計 OpenFlow rules，使變動欄位實際參與 classification，進而影響 megaflow mask 與 `flow_hash()` input。

### 下一步
- 修改 `send_microflows.py`，支援 `dst-port-min` / `dst-port-max`。
- 測試 Case B：同時變化 UDP source port 與 destination port，在 `NORMAL` forwarding 下觀察 flow/mask 是否仍被合併。
- 再測試 Case D：加入 irregular port-sensitive OpenFlow rules，觀察 `masks total`、`hit/pkt` 與 UDP port mask 是否變細。



---

## 2026-06-03 — Case A→D 完整證明 OVS megaflow 多樣性由 classifier 決定

### 今日目標
- 釐清 5/27 規劃中 Case D 與 `force_megaflow_rules.sh` 的關係。
- 完成 generator 修改，讓既有腳本支援 src/dst port + src_ip 三個欄位的範圍變化。
- 依 Case A/B/C/D 順序測「packet 變化是否能驅動 megaflow 多樣性」的核心假設。
- 取得 baseline workload，能讓 kernel datapath `flow_hash()` 被多樣化呼叫。

### 今日操作
- `pktgen_microflows.sh` 修正兩處關鍵 bug：
  - 第 36 行 `DSTMIN =` 賦值前空白，bash 把賦值誤判為命令執行。
  - 初版以 `flag UDPSRC_RND,UDPDST_RND` 寫多 flag，實測 pktgen `strn_len()` 不接受 comma，整串被當成單一未知 flag 靜默忽略。改寫成「heredoc 內固定 `flag UDPSRC_RND`、heredoc 外條件追加 `flag UDPDST_RND`」，利用 pktgen flag 的 OR-累加語意。
- 確認 `sudo VAR=val ./script` 為穩定寫法；前置 `VAR=val sudo ./script` 因 sudoers `env_reset` 機制行為不可靠（同一條指令裡 DURATION 會被擋、DSTMIN/DSTMAX 卻過得去）。
- 新增 `SRCIPMIN`/`SRCIPMAX` env var 與條件式 `IPSRC_RND` flag（IP 用字串比較 `!=`，整數 `-ne` 會抗議）。
- 依序執行 Case B / C / D-weak / D-v1，搭配 `observe_flows.sh --watch` + `ovs-dpctl dump-flows` / `-m` 量測。

### 觀察結果

| Case | 設定 | flows | masks | hit/pkt | pps |
|---|---|---|---|---|---|
| A (5/27) | NORMAL + src_port 變 | 少數幾條 | 1 | 1.00 | — |
| B | NORMAL + src_port + dst_port 變 | 2–4 | 1–2 | 1.00 | ~290 K |
| C | NORMAL + src_ip + src_port 變 | **241（全是 ARP）** | 2 | 1.00 | ~310 K |
| D-weak | `tp_src=1,actions=drop` probe rule | 5–7 | 5–6 | 1.11 | ~300 K |
| **D-v1** | **500 條 specific (sp, dp) rule + mixed action** | **442** | **2–3** | **1.08** | **~785 K** |

- **Case B**：證實單純變 L4 在 NORMAL 下被完整 wildcard，megaflow 塌縮 ≤4 條，啟動瞬間少量 upcall 後完全 fast path。
- **Case C**：表面 flows 暴增至 241，但 `dump-flows` 揭露**全是 ARP**（`eth_type=0x0806`）。原因：ns2 對 UDP closed port 回 ICMP unreachable → 需對每個 src_ip 廣播 ARP request → OVS NORMAL 對 ARP 有特殊處理（responder/learning），讀 `arp.sip/tip/op` → 每對 (sip, tip) 一條 megaflow。UDP forward path 仍只有 1–2 條 megaflow。**修訂理解**：NORMAL wildcarding 是 per-eth_type 不對稱的（IPv4 wildcard L3/L4；ARP 不 wildcard arp body）。
- **Case D-weak**：probe rule `tp_src=1` 被 OVS 的 **lazy bit-prefix unwildcarding** 繞過——classifier 只讀 high bits 就能否決，megaflow mask 出現 `udp(src=32768/0x8000, dst=16384/0xc000)` 形式，最後切出 4 種 prefix 區段而非上千 megaflow。
- **Case D-v1**：用 50×10 = 500 條 specific (sp, dp) rule、相鄰組合 action 翻轉（`(sp+dp)%2`：drop / output），堵住 prefix shortcut。megaflow key 變成 `udp(src=20002, dst=9003)` 等 16-bit exact match。`dump-flows -m` 確認 L3 / MAC / ToS / TTL 全部顯式 `/0` wildcard，L4 完全 exact。pps 跳到 785 K（drop action 在 kernel 端短路釋放 skb，比 output 路徑顯著便宜）。

### 目前判斷
- **核心結論**：OVS megaflow 的 hash table 多樣性**由 classifier 設計決定**，與 packet 內容變化量無關。Case A→D 四組對照完整證明。
- **次要發現**：
  - OVS 使用 lazy bit-level unwildcarding：megaflow mask 由「classifier 實際讀過的 bit」決定，不是「rule 形式上提到的欄位」。強制 full unwildcarding 需 dense rule + mixed action。
  - NORMAL action 對 ARP / IPv4 / 其他 eth_type 行為不對稱，做負控制時要分別觀察 `eth_type(0x0800)` 跟 `eth_type(0x0806)`。
  - drop action 在 kernel 短路比 output 路徑便宜很多，會顯著抬高 pktgen pps（290 K → 785 K）。
- **baseline workload 確立**：Case D-v1 提供 442 megaflow、~850 K `flow_hash()` 呼叫/秒 的純 fast-path 環境，可作為後續 hash function 比較的測試 setup。

### 下一步
- **Case D-v2 構想**：擴大 port pair 空間（如 100×100 = 10 000），測 megaflow 規模 → `flow_hash()` 桶/碰撞分佈的關係。可選 (a) 加 ns3 並用兩個 output port 取代 drop，看 action 平衡是否影響行為；(b) 純擴 rule density 觀察 `flow-limit` 是否觸發 dynamic eviction。
- 跑核心 deliverable：clone kernel source、修改 `net/openvswitch/flow_table.c::flow_hash()` 切換 jhash2 / hsiphash / siphash，於 Case D-v1 baseline 上比較 throughput / cycles / 碰撞分佈。
- 今日對 `pktgen_microflows.sh` / `send_microflows.py` 的修改 commit 進 git；更新 `ovs_datapath_bench/README.md` 加入 Case A→D runbook。
