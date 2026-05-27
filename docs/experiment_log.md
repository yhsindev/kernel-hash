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
