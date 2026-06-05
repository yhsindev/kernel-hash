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


## 2026-06-04 — Check-in：Case D-v2 port-pair workload

### 今日方向
- 將 Case D-v1 從固定 `50 × 10 = 500` port pairs，改成可參數化的 D-v2 workload。
- 先跑 D-v2-small：`100 × 20 = 2,000` port pairs。
- 若 small 穩定，再放大到 D-v2-mid：`200 × 50 = 10,000` port pairs。
- 今日暫不加入 ns3，先沿用 output/drop rules，降低拓樸變因。

### 為什麼做這一步
- D-v1 已證明 port-sensitive rules 能讓 UDP port pair 進入 datapath flows。
- 但 D-v1 只有約 `442` flows，`hit/pkt ≈ 1.07`，比較像 flow-entry diversity workload，還不是高 lookup pressure workload。
- D-v2 目標是測試更大的 port-pair key space 是否會提高 flows、影響 d_hit / d_missed / masks / hit-pkt。

### 先做的事
1. 參數化 `install_irregular_udp_rules.sh`。
2. 跑 D-v2-small。
3. 保存 `ovs-dpctl show`、`dump-flows`、`dump-flows -m`、`ovs-ofctl dump-flows`。
4. 視結果決定是否今天推進 D-v2-mid。

### 今日成功標準
- 完成可參數化 rules script。
- 至少完成 D-v2-small 一次有效 run。
- 能初步比較 D-v1 與 D-v2-small 的 flows / masks / hit-pkt / d_hit / d_missed。

### 今日結果補充：NORMAL same-range baseline

使用與 D-v2-mid 相同的 pktgen range：

- UDP source port：`20000–20199`
- UDP destination port：`9000–9049`
- 理論 port pairs：`200 × 50 = 10,000`
- OpenFlow rules：`priority=0,actions=NORMAL`

觀察結果顯示，NORMAL forwarding 下 OVS datapath flows 僅維持在 `2–4` 條，masks 約為 `1–2`，`hit/pkt ≈ 1.03`。`dump-flows` 顯示主要為兩個方向的 IPv4 forwarding flows，而非 UDP port-specific flows。

此結果與 D-v2-mid 形成明確對照：同樣的 10,000 port-pair traffic，在 NORMAL forwarding 下會被 OVS megaflow cache 合併；而 D-v2-mid 透過 port-sensitive irregular OpenFlow rules，可產生約 `9,752–9,754` 條 UDP-specific datapath flows。因此，D-v2-mid 可定位為 controlled flow-entry diversity workload，用於後續觀察大量 UDP-specific datapath flows 下的 hash lookup 行為。

限制：兩組實驗的 `hit/pkt` 仍接近 1，代表目前 workload 主要放大 flow table working set，而非 multi-mask lookup pressure。

---

## 2026-06-04 — Check-out：Case D-v2 port-pair workload

### 今日目標
- 將 Case D-v1 的固定 `50×10 = 500` port pairs，改成可參數化的 D-v2 workload。
- 測試 D-v2-small (`100×20 = 2,000`) 與 D-v2-mid (`200×50 = 10,000`)。
- 補一組 `normal_same_range` baseline，確認同樣 pktgen traffic 在 NORMAL forwarding 下是否會自然產生大量 UDP-specific flows。

### 今日操作
- 新增 `install_irregular_udp_rules.sh`：
  - 支援 `SRCMIN/SRCMAX/DSTMIN/DSTMAX/OUTPUT_PORT` 參數化。
  - 會動態解析 OpenFlow port number，避免 hardcode output port。
  - 使用 `ovs-ofctl add-flows -` 批次安裝 rules。
  - 加入 rule 數量 safety stop 與 port range 檢查。

- 完成三組實驗：
  - `normal_same_range`：同樣使用 `200×50` port range，但只套 `NORMAL` rule。
  - `case_d_v2_small`：`100×20 = 2,000` rules。
  - `case_d_v2_mid`：`200×50 = 10,000` rules。

### 觀察結果

| Case | Rules | Port pairs | flows | masks | hit/pkt | pktgen pps | 初步解讀 |
|---|---:|---:|---:|---:|---:|---:|---|
| normal_same_range | NORMAL only | 10,000 | 2–4 | 1–2 | ~1.03 | ~507K | NORMAL 會把 port variation 合併成少數 megaflows |
| D-v2-small | 2,000 | 2,000 | ~1,882 | 2–3 | ~1.04–1.06 | ~721K | port-sensitive rules 可穩定放大 UDP flow entries |
| D-v2-mid | 10,000 | 10,000 | ~9,752 | 2–3 | ~1.03–1.04 | ~652K | 成功建立接近 10k UDP-specific datapath flows |

### 目前判斷
- D-v2-mid 的價值在於：同樣的 `200×50` traffic，在 NORMAL 下只有 `2–4` 條 flows；套 port-sensitive rules 後可產生約 `9.7k` 條 UDP-specific datapath flows。
- 這表示 D-v2-mid 可以作為 controlled flow-entry diversity workload，用來觀察大量 UDP-specific datapath flows 下的 lookup 行為。
- `hit/pkt` 仍接近 1，代表目前 workload 主要放大 flow table working set，而不是 multi-mask lookup pressure。
- D-v2-mid 有觀察到 `lost` counter，需要後續正式 run 用 before/after delta 再確認，暫時不直接解讀成明確瓶頸。
- D-v2-mid 不是 production-like workload，而是 controlled workload；後續若要更貼近 forwarding throughput，可再設計 D-v3，例如多 output port、避免 drop path。

### 今日結論
- D-v2 workload 設計成立：rules 規模從 2k 放大到 10k 時，observed flows 也跟著接近線性放大。
- NORMAL baseline 補足後，D-v2-mid 的實驗意義更清楚：大量 UDP-specific flows 主要由 OpenFlow rules 設計造成，而不是 packet variety 自然造成。
- 目前可以把 D-v2-mid 作為後續 `flow_hash()` 替換實驗的第一版 controlled workload，但不能過度解讀為一般 OVS production 場景。

### 下一步
- 整理 result files，確認 `normal_same_range / case_d_v2_small / case_d_v2_mid` 都有保存 `pktgen_output`、`dpctl_show`、`dump-flows`、`dump-flows -m`、`ofctl_dump_flows`。
- 下一階段開始看 Linux 6.8 `net/openvswitch/flow_table.c::flow_hash()`。
- 第一版修改範圍先限定在 `flow_hash()`，暫不動 `find_bucket()`、`ufid_hash()` 或 mask cache 相關 path。

## 2026-06-05 — Check-in：flow_hash() patch first pass
### 今日方向
- 6/4 已完成 D-v2-mid controlled workload 與 NORMAL baseline。
- 今日開始進入 `net/openvswitch/flow_table.c::flow_hash()` 修改前準備與最小 patch。
- 目標不是完成正式效能比較，而是找出 build / key / alignment / reload 的工程困難點。

### 今日任務
1. 確認 kernel 與 openvswitch module 狀態。
2. 找到 Linux 6.8 source tree（先用 /lib/modules/$(uname -r)/build 路徑或 Ubuntu linux-source 套件）與 flow_table.c。
3. 明確限定第一版範圍：只改 flow_hash()。
4. 設計 compile-time hash selection 機制（只決定 #define 結構，code 還沒寫）。
5a. 用 unmodified flow_table.c 跑通 out-of-tree module rebuild → unload/reload → 短 traffic sanity。
5b. 若 5a 通過：加 hash selection #define skeleton，保留 jhash 為 default 可 build。
#define OVS_FLOW_HASH_JHASH 1
#define OVS_FLOW_HASH_HSIPHASH 0
#define OVS_FLOW_HASH_SIPHASH 0
6. 若 5b 通過：用 D-v2-mid 跑 sanity（只驗 module 載入後 datapath 仍通，不比效能）。

### 今日不做
- 不做 D-v2-large。
- 不加入 ns3。
- 不改 find_bucket() / ufid_hash() / mask cache。
- 不今天就 build 出 siphash / hsiphash 變體。
- 不做 runtime switching / module_param / sysctl 機制。
- 不做 cross-hash function 數據對照。
- 不改 OVS userspace。

### 今日成功標準
- 最低成功：確認 kernel / OVS module 狀態，找到 source tree 與 `flow_table.c`。
- 中等成功：unmodified module rebuild / reload 成功。
- 高成功：加入 jhash default 的 hash selection skeleton，並通過 D-v2-mid sanity。

### 今日 deliverable
- `docs/kernel_patch_notes.md`
  - kernel / openvswitch module 狀態
  - source tree 位置
  - unmodified rebuild / reload 步驟
  - unload/reload 是否成功
  - sanity traffic 結果
  - 卡關點與下次接續事項
- 若 5b/6 通過，commit hash selection skeleton。


---

## 2026-06-05 — Check-out：flow_hash() patch first pass

### 今日目標

* 確認目前 kernel 與 Open vSwitch kernel module 狀態。
* 取得可用的 Linux 6.8 HWE source tree，定位 `net/openvswitch/flow_table.c::flow_hash()`。
* 先走通 unmodified `openvswitch.ko` 的 rebuild / reload / sanity pipeline。
* 若 reload pipeline 成功，再加入 jhash-default 的 hash selection skeleton，確認修改過的 module 仍可正常運作。

### 今日操作

* 確認目前環境為 `6.8.0-124-generic`，`openvswitch` 以 kernel module 形式載入，且 `vermagic` 含 `mod_unload`，可進行 unload / reload 測試。
* 使用 `apt source linux-hwe-6.8` 取得 HWE 6.8 source。過程中需先開啟 `deb-src` repository，避免誤用 Ubuntu 22.04 預設的 `linux-source-5.15.0`。
* 在 source tree 中定位 `net/openvswitch/flow_table.c::flow_hash()`，並建立 git baseline。
* 解決 `vermagic` 不一致問題：直接在 HWE source tree build 會得到 `6.8.12+`，與 running kernel `6.8.0-124-generic` 不符。因此改用：

  ```bash
  make -C /lib/modules/$(uname -r)/build \
    M=$PWD/net/openvswitch \
    modules -j$(nproc)
  ```

  讓 module 使用 running kernel 的 build context，成功產生 `vermagic = 6.8.0-124-generic` 的 `openvswitch.ko`。
* 走通 reload pipeline：備份系統原版 module、cleanup testbed、停止 OVS userspace、卸載舊 module、載入自製 module、重啟 OVS userspace、重建 testbed，最後用 `ns1 -> ns2` ping 做 sanity test。
* 加入 jhash-default hash selection skeleton。此階段只加入 compile-time selection 結構，實際 backend 仍為 `jhash2()`，尚未實作 `hsiphash` / `siphash`。
* 重新 build / reload skeleton module，並用 D-v2-mid 做 sanity run。

### 觀察結果

* 最低成功標準完成：kernel / module 狀態確認、Linux 6.8 HWE source 取得、`flow_hash()` 定位完成。
* 中等成功標準完成：unmodified `openvswitch.ko` rebuild / reload 成功，`ns1 -> ns2` ping 為 0% packet loss。
* 高成功標準完成：jhash-default skeleton module reload 成功，D-v2-mid sanity run 中 observed flows 約 `9752–9754`，pktgen `errors: 0`。
* `srcversion` 實測可區分自製 module 與系統原版 module。自製 module 的 `srcversion` 與系統原版不同，且與 `/sys/module/openvswitch/srcversion` 現載入值一致，可作為確認 kernel 載入自製版本的依據。

### 目前判斷

* `vermagic` 對齊是 HWE kernel 環境下的主要工程門檻。直接從 HWE source root build 會得到不相容的 `6.8.12+`，需改用 running kernel headers build context。
* OVS kernel module 的 rebuild / reload pipeline 已經打通，後續可以用同一流程反覆測試修改後的 `openvswitch.ko`。
* jhash-default skeleton 通過 D-v2-mid sanity，代表「改 `flow_table.c` → build → reload → workload sanity」的迭代迴路已成立。
* 目前尚未做任何 hash function 效能比較；今天只驗證修改過的 datapath module 仍能正常載入與處理封包。

### 今日結論

* 第一版 kernel patch 工程流程已建立完成。
* 修改範圍目前仍限定在 `flow_hash()`，並保留 `jhash2()` 作為 default backend。
* `find_bucket()`、`ufid_hash()`、mask cache 與 runtime switching 均暫不處理，以避免過早引入額外變因。
* 後續可以開始實作第一個非 jhash backend，但應先從 `hsiphash` 開始，並只做 sanity，不立即做正式 benchmark。

### 下一步

* 回實驗室後，在 skeleton 中實作 `hsiphash` branch，先確認 API、key、length、alignment 與 output 型別處理。
* 第一版 `hsiphash` 可先使用 fixed static key 做工程 sanity；正式報告需註明 fixed key 不代表完整安全部署。
* `siphash` 因輸出為 64-bit，需另外設計 u64 → u32 folding，建議晚於 `hsiphash` 實作。
* `.gitignore` 需排除 `kernel_work/`，避免將 HWE source tree 與大型 tarball 放進主專案 repo。主 repo 只保留 notes、scripts 與 experiment log。

### 細節文件
本日誌只記錄今日進度。完整操作細節請看：
- `ovs_datapath_bench/notes/lkm_build.md`：kernel source、build dependency、vermagic 對齊與 module rebuild。
- `ovs_datapath_bench/notes/lkm_reload.md`：module unload / reload、OVS service restart、testbed sanity 與 rollback。