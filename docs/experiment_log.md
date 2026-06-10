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

## 2026-06-07 — Check-in：hsiphash 變體 first pass

### 今日方向

* 6/5 已完成 OVS module rebuild / reload pipeline 與 jhash-default skeleton。
* 今日進入第一個非 jhash backend：`hsiphash`。
* 目標是驗證 skeleton 能容納第二種 hash backend，並保持 datapath sanity。

### 今日任務

1. 檢查目前 `flow_hash()` skeleton 與 jhash default 路徑。
2. 查清 `hsiphash` API、key 型別與 input length 用法。
3. 在 skeleton 中加入 `hsiphash` branch，但暫不動 `find_bucket()` / `ufid_hash()` / mask cache。
4. 使用 running-kernel build context 重新 build，確認 `vermagic` 對齊。
5. reload 新 module，確認載入版本正確。
6. 重建 testbed，跑 ping 與 D-v2-mid sanity。

### 今日不做

* 不實作 `siphash`。
* 不做 runtime switching。
* 不做正式 cross-hash benchmark。
* 不解讀 pps / hit-pkt 效能差異。

### 今日成功標準

* 最低：`hsiphash` branch 能 compile。
* 中等：`hsiphash` 版本 reload 成功。
* 高：通過 D-v2-mid sanity，flows 能正常起來且 pktgen `errors:0`。

### 今日 deliverable

* `flow_hash()` 內新增可切換的 `hsiphash` 路徑。
* 在 notes 補充 `hsiphash` 的 key、length、alignment 處理方式與卡關點。

---
## 2026-06-07 — Check-out：hsiphash first pass 與 jhash perf path 釐清

### 今日完成

* 實作 `flow_hash()` 的第一個非 jhash backend：`hsiphash`。
* 完成 hsiphash 版本的 build / reload，並確認：

  * `vermagic` 對齊 `6.8.0-124-generic`
  * loaded `srcversion` 與 build artifact `srcversion` 一致
  * OVS userspace 可正常重啟
  * testbed 可重建，`ns1 -> ns2` ping 0% loss
* 完成 hsiphash D-v2-mid sanity 與 controlled delta run1。
* 修正 `agent_workflow.md`：mini benchmark 主指標改為 steady-state `perf` cycle%，pps / hit-missed-lost delta 降為輔助指標。
* 切回 jhash backend，完成 build / reload，並確認 jhash 版本已正確載入。
* 完成 jhash D-v2-mid steady-state perf run1。
* 釐清 jhash perf report 中出現 `__siphash_unaligned` 的原因。

### 關鍵結果

#### hsiphash first pass

* hsiphash build 成功，`srcversion = 1489A986A8265DDAE1DB93E`。
* D-v2-mid sanity 通過：

  * flows 約 `9752–9754`
  * pktgen `errors: 0`
  * ping 0% loss
* hsiphash controlled delta run1：

  * hit delta = `7,253,640`
  * missed delta = `25,942`
  * lost delta = `10,872`
  * pktgen 約 `730,395 pps`
  * pktgen `errors: 0`
* `lost delta` 主要視為初始 flow install burst 對 userspace upcall path 的壓力訊號，不作為 hsiphash 功能失敗判斷。

#### hsiphash perf baseline

* hsiphash steady-state perf baseline 已取得：

  * `masked_flow_lookup` 約 `7.72%`
  * `__hsiphash_unaligned` 約 `1.32%`
* 此結果確認 perf 可量到 OVS lookup path 與可見 hash symbol 的 cycle%，因此後續 mini benchmark 主指標應使用 perf，而不是只看 pps / delta。

#### jhash perf run1

* jhash backend reload 正確：

  * loaded `srcversion = C90156343EF867AED1CB6F0`
  * build artifact `srcversion = C90156343EF867AED1CB6F0`
  * `flow_table.c` define 為 `JHASH=1, HSIPHASH=0`
* jhash run1 workload 有效：

  * flows 約 `9752`
  * pktgen 約 `732,221 pps`
  * pktgen `errors: 0`
  * ping 0% loss
* jhash run1 perf：

  * `masked_flow_lookup` self 約 `7.72%`
  * perf 中出現 `__siphash_unaligned`，但 call chain 顯示它來自 `__skb_get_hash → __skb_flow_dissect → __siphash_unaligned`
  * 因此 `__siphash_unaligned` 屬於外部 skb hash / flow dissector path，不是 OVS `flow_hash()` jhash backend 成本

### 目前判斷

* hsiphash first pass 已通過 build、reload、ping sanity、D-v2-mid sanity 與 controlled delta run1。
* jhash backend reload 正確，並非仍停在 hsiphash。
* `perf -a` 是全系統取樣，會包含 OVS lookup path 之外的 kernel networking 成本；後續分析必須區分：

  * OVS flow table lookup path：`ovs_flow_tbl_lookup_stats → flow_lookup → masked_flow_lookup`
  * 外部 skb hash path：`__skb_get_hash → __skb_flow_dissect → __siphash_unaligned`
* 第一版比較規則暫定：

  * jhash：看 `masked_flow_lookup self%`
  * hsiphash：看 `masked_flow_lookup self% + __hsiphash_unaligned self%`
  * skb siphash：標記為外部 networking path，不納入 `flow_hash()` backend 成本

### 未解問題

* jhash 與 hsiphash 目前都還沒有足夠多次 perf run，不能下正式效能結論。
* 需要補 jhash run2 / run3，以及 hsiphash perf run2 / run3，才能整理第一版 mini benchmark 平均值。
* hsiphash 使用 fixed static key，只適合可重現的工程比較；後續報告需說明這不是 production security design。
* 需要確認最終表格如何呈現 inline jhash 與 non-inline hsiphash 的比較方式。

### 下一步

* 明天先維持 jhash backend，不切換。
* 跑 jhash D-v2-mid steady-state perf run2 / run3。
* 再切回 hsiphash，跑 hsiphash perf run2 / run3。
* 整理第一版 jhash vs hsiphash perf 對照表：

  * 主欄位：`masked_flow_lookup self%`、可見 hash symbol self%、合併 lookup/hash 成本
  * 輔助欄位：pps、flows、hit/missed/lost delta、pktgen errors、ping

### 文件與資料狀態

* `agent_workflow.md` 已更新為 perf 主指標版本。
* hsiphash sanity / delta run1 資料已產生，需確認是否補 summary。
* jhash perf run1 結果資料夾已產生。
* 今日結論應補進 `docs/experiment_log.md`，但目前仍屬 mini benchmark 前置與 preliminary perf validation，不寫成正式實驗結論。

## 2026-06-08 — Check-in：siphash backend + 三 backend perf 對照

### 今日方向
- backend 身分驗證方法已固定：以 `flow_table.c` define、`srcversion`、`nm -u` 交叉確認。
- 今日補齊第三個 backend：`siphash`。
- 若 siphash build / reload / sanity 通過，今天推進到三 backend steady-state perf，產出第一版對照表。

### 今日任務

#### Phase 1：siphash backend first pass
1. 實作 `flow_table.c` 的 `SIPHASH` 分支：`siphash()` + `u64 → u32` folding。
2. build siphash backend，確認 `vermagic` 對齊。
3. 用 `nm -u openvswitch.ko` 確認 import `__siphash_unaligned`。
4. reload siphash module，確認 loaded `srcversion` = build artifact `srcversion`。
5. 跑 D-v2-mid sanity：flows 約 9752、pktgen errors 0、ping 0% loss。

#### Phase 2：siphash perf run
1. 跑 siphash D-v2-mid steady-state perf run1。
2. 檢查 `__siphash_unaligned` call-tree 歸屬，區分：
   - OVS `flow_hash()` path
   - 外部 `__skb_get_hash / __skb_flow_dissect` path

#### Phase 3：三 backend mini benchmark
1. jhash / hsiphash / siphash 各補到 N≥3 steady-state perf。
2. 每次 run 前固定驗 backend 身分：define、srcversion、`nm -u`。
3. 整理第一版三 backend perf 對照表。

### 今日不做
- 不做 runtime switching / module_param / sysctl。
- 不動 `find_bucket()` / `ufid_hash()` / mask cache。
- 不擴大 D-v2-large。
- 不用 pps / lost 當 hash 效能主指標。

### 成功標準
- 最低：siphash branch compile，且 `nm -u` 可確認 backend 身分。
- 中等：siphash reload 成功，D-v2-mid sanity 通過。
- 高：完成 siphash perf run1，並取得三 backend 第一版 steady-state perf 對照。
- 超標：三 backend 各 N≥3 perf 完成，整理成可放進進度報告的表格。

### 預設下一步
- 先實作 siphash branch。
- 若 build/reload 卡住，優先修 correctness。
- 若 siphash sanity 通過，立刻進 siphash perf run1。

## 2026-06-08 — Check-out：三 backend perf mini benchmark 與量測方法修正

### 今日完成

* 完成 `siphash` backend 實作（`flow_table.c` `SIPHASH` 分支：`siphash()` + `u64 → u32` folding）。
* 固定三個 backend 的身分驗證方法（每輪 reload 前交叉確認）：

  * `flow_table.c` define
  * loaded / build artifact `srcversion`
  * `nm -u openvswitch.ko` import symbol
* 完成 `noinline ovs_flow_hash_backend()` wrapper，讓 perf 可獨立觀察 hash backend 成本。
* 修正 perf 主指標：改看 `ovs_flow_hash_backend children%`，不再只看 `masked_flow_lookup self%`。
* 修正 build 流程：必須用 `make -C /lib/modules/$(uname -r)/build M=...`，避免在 source tree 內直接 `make` 把 vermagic 寫成 `6.8.12+`（debug 細節見 `lkm_build.md`）。
* 固定 CPU governor 為 `performance`，確認 12/12 logical CPUs 套用成功。
* 完成三 backend × N=5 clean perf run（jhash / hsiphash / siphash）。
* 強化 `run_perf_set()` 量測設計：

  * `flows_before_perf >= 9000` gate，避免 `flows=0` 時仍寫入假資料。
  * 正式 run **不 del-flows**：warm-up 建一次 flows，正式 run 直接命中既有 flows（純 fast-path）。
  * 因有獨立 warm-up 步驟，5 個正式 run **皆有效、run1 不丟**。
* 修正 OVS datapath / userspace 狀態異常（`flows=0`、`lost` 暴增、`failed to put[modify]`）：reload 腳本 Step 2 補上停 `ovsdb-server` + testbed rebuild 後恢復（根因與流程見 `datapath_reload_recovery.md`）。
* 抓取並保存 siphash call-tree attribution。

### 關鍵結果

#### Backend 身分

* jhash：`srcversion = 9934512B440806A9DEFA77A`；`nm -u` 無 out-of-line hash import + `ohash_self ≈ ohash_children`（0.714 ≈ 0.716）→ jhash2 inline（已證實）。
* hsiphash：`srcversion = 670B9FE03F3CECAF4D7F865`；`nm -u` 可見 `__hsiphash_unaligned`（out-of-line，`ohash_self ≈ 0.02`）。
* siphash：`srcversion = 75AA9FCC444232089DB6AD7`；`nm -u` 可見 `__siphash_unaligned`（out-of-line，`ohash_self ≈ 0.03`）。

（註：以上 srcversion 對應「noinline wrapper + 三 backend」版 `flow_table.c`，與 6/07 記錄的舊版 srcversion 不同，屬正常。）

#### Clean perf summary

| backend  | `ohash_children` mean ± sd | `ohash_self` mean | `masked_children` mean ± sd | pps mean |     flows |
| -------- | -------------------------: | ----------------: | --------------------------: | -------: | --------: |
| jhash    |              0.716 ± 0.139 |             0.714 |               6.840 ± 0.482 |  536,809 |      9752 |
| hsiphash |              0.408 ± 0.096 |             0.018 |               6.836 ± 0.499 |  515,804 | 9752–9754 |
| siphash  |              0.958 ± 0.204 |             0.032 |               8.042 ± 1.157 |  542,063 | 9752–9753 |

* `sd = population stdev`（N=5）。
* 註：`pps` 為 pktgen 送包速率（offered load），**非 OVS 轉發吞吐量**，不可解讀為 backend 效能；此處僅佐證「三組負載量級相當」。
* 資料來源：`hash_backend_perf.csv`、`hash_backend_perf_summary.csv`。

#### Call-tree attribution（siphash）

```text
masked_flow_lookup (7.25%)
  → ovs_flow_hash_backend (0.77%)
    → __siphash_unaligned (0.77%)
```

* wrapper 的 children% 整條流進 `__siphash_unaligned`（0.77% → 0.77%），無其他 callee → `ovs_flow_hash_backend children%` 確實涵蓋 siphash out-of-line hash cost。
* 該 `__siphash_unaligned` 接在 `masked_flow_lookup` 底下（OVS fast-path），**不是** `__skb_get_hash → __skb_flow_dissect`（外部 skb hash path）。flat `__siphash_unaligned` 數字不可直接解讀，需靠此 caller→callee 邊區分。
* 證據保存於 `siphash_calltree_attribution_20260608/`。

### 目前判斷

* 今日最重要成果不是得出最終 hash 排名，而是**建立可信的量測方法**。
* `noinline ovs_flow_hash_backend()` 解決了 jhash inline、hsiphash / siphash out-of-line 造成的 perf attribution 不公平問題（統一看 wrapper children%）。
* `flows gate` 解決了先前 `flows=0` 卻仍錄 perf 的假資料問題。
* preliminary 結果：

  * `siphash` 的 backend subtree cost 最高（≈ 0.96%）。
  * `jhash` 與 `hsiphash` 在整體 `masked_flow_lookup` path 上幾乎一樣（≈ 6.84%）。
  * `hsiphash` 的 `ohash_children` 低於 jhash，但仍應保守解讀，不可直接宣稱演算法本質上更快（百分比是全系統 perf sample 佔比，非 cycles/op）。
* 排序對取樣穩健：丟不丟 run1，`hsiphash < jhash < siphash` 都成立。
* D-v2-mid workload 可用，但 hash signal 仍偏小（0.4–1.0%），結果應定位為 **first-pass mini benchmark**，非 final benchmark。

### 未解問題

* `ohash_children` 僅約 0.4–1.0%，hash signal 偏小，後續可能需放大訊號（提高每封包 hash lookup 次數 / 加長 `flow_hash()` input length / 補 `perf annotate` instruction-level 證據）。
* OVS datapath 曾出現 `flows=0`、`lost` 暴增；後續每輪 run 前必須保留 health check 與 flows gate。
* 符號歧義**只有 siphash** 需持續用 call-tree 區分（`__siphash_unaligned` 與 skb-hash 共用）；jhash（inline）與 hsiphash（`__hsiphash_unaligned`，skb-hash 不用）本身即無歧義，不需每輪都重抓三個 call tree。

### 下一步

* 先不盲目重跑同一批 N=5。
* 把今日結果整理進 `docs/experiment_log.md`（本篇）、`hash_backend_sanity.md`、`agent_workflow.md` 量測規則段。
* 以 `hash_backend_perf.csv`、`hash_backend_perf_summary.csv`、`siphash_calltree_attribution_20260608/` 作為本輪 preliminary mini benchmark 資料。
* 下一輪技術方向：

  1. 保留 noinline wrapper 與 flows gate。
  2. 先評估是否需放大 hash signal。
  3. 若放大，優先設計小規模 confirmation run，不直接擴到大實驗。
  4. 若寫報告，先把今日結果定義為「measurement methodology validation + preliminary comparison」。
* D-v3 workload exploration 門檻採兩層（探索階段只跑 jhash）：candidate 能把 `hit/pkt` 拉過 2、`ovs_flow_hash_backend children%` 過 2%（baseline D-v2-mid ≈ 0.7%、hit/pkt ≈ 1.0）即值得保留；要 `hit/pkt ≥ 3`、`children%` 達 3–5% 且 run-to-run sd < mean 的 20–30%，才升格為三 backend 正式 benchmark 候選（理想目標 `hit/pkt ≥ 5`、`children% ≥ 5%`，非硬門檻）。

### 文件與資料狀態

* `hash_backend_perf.csv`：三 backend × N=5 clean perf 結果。
* `hash_backend_perf_summary.csv`：已產生。
* `siphash_calltree_attribution_20260608/`：siphash call-tree 證據已保存。
* `reload_ovs_module.sh`：Step 2 已加停 `ovsdb-server`。
* `lkm_build.md`：已補 vermagic `6.8.12+` debug log。
* 先前 `flows=0` 的 jhash 資料視為 invalid，不納入結果。
* 今日結果可進入 commit，但正式結論需標註為 preliminary。

## 2026-06-09 — Check-in：D-v3 workload exploration（放大 hash signal）

### 今日方向

* 三 backend preliminary benchmark 已完成，但 `ovs_flow_hash_backend children%` 只有約 0.4–1.0%，hash signal 偏低。
* 今日進入 D-v3 workload exploration，探索階段只跑 jhash。
* 目標不是正式三 backend 對照，而是找出能放大 hash signal 的 workload candidate。

### 今日任務

1. 設計 1–2 個 D-v3 candidate workload：

   * Candidate A：加長 `flow_hash()` input，例如讓 megaflow key unwildcard `nw_src / nw_dst`。
   * Candidate B：提高 mask / subtable lookup 壓力，目標拉高 `hit/pkt`。
2. 每個 candidate 只跑 jhash：

   * 驗 backend 身分：define / srcversion / `nm -u`
   * warm-up 建 flows
   * perf 前檢查 `flows >= 9000`
   * 記錄 `ovs_flow_hash_backend children%`、`masked_flow_lookup children%`、`hit/pkt`、flows、pktgen errors。
3. 對照 D-v2-mid baseline：

   * `ovs_flow_hash_backend children% ≈ 0.7%`
   * `hit/pkt ≈ 1.0`
   * flows 約 9752

### 今日不做

* 不切 hsiphash / siphash。
* 不跑三 backend N=5。
* 不做 runtime switching / module_param。
* 不動 `find_bucket()` / `ufid_hash()` / mask cache。
* 不擴 D-v2-large。

### 成功標準

* 最低：至少一個 D-v3 candidate 能穩定建 flows（≥ 9000）、pktgen errors = 0，並跑出有效 jhash perf。
* 中等：

  * 若是 input-length candidate：`ovs_flow_hash_backend children%` 明顯高於 baseline，至少 > 2%。
  * 若是 multi-mask candidate：`hit/pkt > 2`，且 `ovs_flow_hash_backend children% > 2%`。
* 高：

  * `ovs_flow_hash_backend children%` 達 3–5%。
  * 或 `hit/pkt >= 3` 且 flow / mask 狀態穩定。
  * 可升格為三 backend 正式 benchmark candidate。

### 預設下一步

* 若 candidate 過正式門檻，下一輪再對該 workload 跑 jhash / hsiphash / siphash N≥5。
* 若所有 candidate 都低於 2%，停止盲跑，改評估更強的 signal amplification：更長 hash input、更多 mask/subtable、或 perf annotate / instruction-level evidence。

## 2026-06-09 — Check-out：D-v3 L3+L4 Candidate A（input 加長已確認，children% 未量）

### 今日完成
* 寫好兩個 D-v3 腳本：`install_dv3_l3l4_rules.sh`（L3+L4 exact rules，相鄰 mixed action 堵 prefix 捷徑）、`pktgen_dv3_l3l4.sh`（src/dst IP + src/dst port 四欄位 RND）。
* rebuild jhash（srcversion `9934512B`、vermagic `6.8.0-124-generic`、`nm -u` 無 out-of-line hash import）。
* 跑 Candidate A：`10 src_ip × 5 dst_ip × 50 src_port × 10 dst_port = 25,000` 條 exact L3+L4 rules。

### 關鍵結果
* **L3 確實進了 hash range**：`dump-flows -m` 顯示 megaflow key `ipv4(src=10.0.1.6,dst=10.0.2.2,…),udp(src=20008,dst=9008)`，nw_src/nw_dst 為 exact（非 `/0`）→ hash input 從「只含 L4」延伸到「L3+L4」，**A 的設計成立、input 已加長**。
* flows ≈ `15,876`（短窗未跑滿 25k）；**masks total:1、hit/pkt 1.00** — 25k 規則同一 mask 形狀、單 mask 命中，符合預期。
* pktgen `959,981 pps`、errors 0。

### 目前判斷
* A 的放大槓桿是 **input 長度**，不是 hit/pkt；hit/pkt=1.0 是預期，不算失敗。
* 但**最關鍵的 `ovs_flow_hash_backend children%` 未量**（睡著前停在此），無法判斷 A 是否過探索門檻（> 2%）。

### 未解問題
* A 的 children% 待量；reboot 已清掉 runtime 環境（governor→powersave、載回系統 module `0E035C1F`），需整套重建才能量。

### 下一步
* 順延至 6/10：重建環境 → 量 A children% → 做 Candidate B（多 mask 拉 hit/pkt）。

### 文件與資料狀態
* `install_dv3_l3l4_rules.sh`、`pktgen_dv3_l3l4.sh` 已寫好，待 commit。
* A 無 perf 存檔（children% 未量），本筆視為 in-progress、非完整結果。

## 2026-06-10 — Check-in：D-v3 children% 量測 + Candidate B（多 mask）

### 今日方向
- 接 6/09：Candidate A 已確認 L3-exact（input 加長），但 children% 未量。今天先量 A 的 children%，判斷「加長 input」能否把 jhash children% 從 baseline ~0.72% 推過探索門檻（> 2%）。
- 再做 Candidate B：多 mask 設計（不同欄位組合）拉高 hit/pkt → 每包多次 hash，測「更多 hash 次數」這條獨立放大路徑。

### 今日任務
1. 重建環境：governor→performance、reload jhash（`9934512B`）、install D-v3 A 規則、確認 flows + L3 exact。
2. 量 Candidate A 的 `ovs_flow_hash_backend children%`（jhash，多次取平均），對照 baseline 0.72%。
3. 設計 Candidate B：混合欄位組合規則造多 mask（目標 hit/pkt > 1），只跑 jhash，量 children% + hit/pkt。
4. 用探索門檻（children% > 2%）判斷 A / B 是否值得升格三 backend 正式 benchmark。

### 今日不做
- 不切 hsiphash / siphash（探索只 jhash）。
- 不跑 N=5 正式三 backend benchmark（過門檻才升格）。
- 不動 find_bucket / ufid_hash / mask cache；不擴 D-v2-large。

### 成功標準
- 最低：重建環境成功、量到 A 的有效 children%。
- 中等：A 或 B 任一把 children% 拉過 2%（達探索門檻）。
- 高：確定一條放大路徑（input 長度 or 多 mask）穩定 > 3%，可升格正式 benchmark 候選。

### 預設下一步
- 若 A / B 過門檻 → 下一輪對該 workload 跑三 backend N≥5 正式對照。
- 若都卡 < 2% → 評估更激進放大（更長 input / 多 mask 疊加）或改 perf annotate。

## 2026-06-10 — Check-out：D-v3 訊號放大、multimask workload 成功與量測指標分層

### 今日完成

* 補齊 Candidate A（L3+L4 長 input）的 jhash perf probe，取得 `ovs_flow_hash_backend` children%。
* 設計並執行 Candidate B（D-v3B multimask workload），透過變化 match 欄位組合製造多種 datapath masks。
* 設計並執行 Candidate A+B（prefix-length combined workload），測試「長 input + 多 mask」是否可同時成立。
* 釐清 A+B prefix 版失敗原因：prefix 長度變化沒有轉換成預期的 datapath multimask pressure。
* 與 GPT 討論並定版「量測指標分層規格（Layer 0–4）」，將主指標、系統層指標與補充 latency 指標分開解讀。
* 更新 `agent_workflow.md`：主指標改以 `ovs_flow_hash_backend children%` 為核心，並加入 CPU-bound gate 與 Layer 0–4 指標分層。

---

### 今日關鍵結果

#### D-v3 workload comparison（jhash backend）

| workload                  | 放大槓桿                   |  hit/pkt | masks total | `ovs_flow_hash_backend` children% | 判斷                  |
| ------------------------- | ---------------------- | -------: | ----------: | --------------------------------: | ------------------- |
| D-v2-mid baseline         | baseline               |    約 1.0 |         1–2 |                             0.72% | signal 太小           |
| Candidate A：L3+L4 長 input | 加長 hash input          |    約 1.0 |           2 |                             2.72% | 有改善，但不足以當主 workload |
| **Candidate B：multimask** | **每包多次 hash lookup**   | **2.74** |       **7** |                         **4.59%** | **目前最佳正式候選**        |
| Candidate A+B：prefix 版    | 試圖結合 input + multimask |      不採用 |       **1** |                             1.47% | 失敗，保留為負結論           |

---

### Candidate B 結論

D-v3B multimask 是目前最強 workload candidate。

有效證據：

* active datapath flows：`15439`
* masks total：`7`
* hit/pkt：`2.74`
* pktgen errors：`0`
* jhash `ovs_flow_hash_backend` children%：約 `4.59%`
* hash signal 從 D-v2-mid baseline 的約 `0.72%` 放大到約 `4%+`

判斷：

* D-v3B 成功提高 OVS classifier lookup pressure。
* 它不是單純增加 flow 數，而是透過多種 match 欄位組合形成多個 datapath masks。
* 每個 packet 平均需要查約 2.7 次 mask，使 `flow_hash()` 呼叫密度提高。
* 目前可升格為正式三 backend benchmark candidate。

---

### Candidate A 結論

Candidate A 成功驗證 L3+L4 exact megaflow 可以形成。

觀察：

* `nw_src / nw_dst / tp_src / tp_dst` 可被放入 datapath megaflow key。
* 代表加長 `flow_hash()` input 的方向在結構上成立。
* 但 `masks total` 仍低，`hit/pkt` 約 1.0，因此只增加單次 hash input 長度，沒有增加每包 lookup 次數。

判斷：

* 可作為 structural validation。
* 不適合作為正式三 backend benchmark 的主 workload。
* 若報告需要說明探索過程，可保留為「input-length amplification works, but weaker than multimask」。

---

### Candidate A+B 結論

A+B prefix 版失敗，應保留為負結論，不納入正式結果。

失敗觀察：

* rules 雖有多種 prefix 長度設計，例如 `/32`、`/24`、`/16`。
* 但 kernel datapath 最終只形成 `masks total = 1`。
* `ovs_flow_hash_backend` children% 只有約 `1.47%`，低於 D-v3B。
* `udp src=0/0` 顯示部分 L4 欄位被 wildcard，沒有保住預期 lookup pressure。

根因判斷：

* prefix 長度變化不是可靠的 multimask 製造方式。
* OVS datapath 可能將 prefix-based rules 泛化或轉成相同 mask shape。
* 可靠的 multimask 手段是變化「match 欄位組合」，不是只變化 prefix 長度。

---

### 今日方法論修正

#### 1. `hit/pkt` 需要小心解讀

`ovs-dpctl show` 的 `hit/pkt` 是累積值。如果切換 workload 後沒有完整清理或即時 live sampling，可能被前一輪污染。

後續判斷 workload 時：

* `masks total`：看當下 datapath mask 數量。
* `flows_before_perf`：看 perf window 是否有效。
* `hit/pkt`：要用同一段 run 的 live sample 或 delta，避免累積污染。
* `perf children%`：作為新鮮 perf window 的主判斷。

#### 2. 主指標與系統指標分層

後續正式 benchmark 不只看 perf percentage，但也不能把所有指標混在一起。

量測分層如下：

##### Layer 0 — Workload validity

用來證明 run 有效，不作為效能主結論。

* backend srcversion
* `nm -u` hash symbol
* flows_before_perf
* masks total
* hit/pkt
* pktgen errors
* lost / missed delta
* ping sanity

##### Layer 1 — Hash backend main metrics

用來支撐 hash function 成本比較。

* `ovs_flow_hash_backend children%`
* `ovs_flow_hash_backend self%`
* hash cycles / packet
* call-tree attribution

##### Layer 2 — OVS lookup path metrics

用來說明 hash 成本是否反映到 lookup path。

* `masked_flow_lookup children%`
* `masked_flow_lookup self%`
* lookup cycles / packet
* hash / lookup ratio

##### Layer 3 — Datapath system impact

只有通過 CPU-bound gate 後才可解讀。

* pps / throughput
* cycles per packet
* instructions per packet
* softirq CPU utilization
* NET_RX / NET_TX softirq delta

##### Layer 4 — Supplementary latency evidence

可用 bpftrace / ftrace 補充，不作為唯一主結論。

* `ovs_flow_hash_backend()` latency histogram
* `masked_flow_lookup()` latency histogram
* p50 / p90 / p99 relative comparison

---

### 目前判斷

* D-v3B 是目前最合理的正式 workload candidate。
* 它同時具備：

  * 足夠 flows
  * 多 masks
  * hit/pkt 顯著高於 baseline
  * hash signal 落在 3–5% 的可觀察區間
  * pktgen errors = 0
* 不建議繼續放大 A+B，因為 D-v3B 已達正式候選門檻，而 A+B 目前會讓 workload 塌回單一 mask。
* 下一階段重點不是再設計 workload，而是將 D-v3B 固定下來做公平三 backend comparison。

---

### 未解問題

* D-v3B 目前只有 jhash probe，尚未完成 N≥5。
* 尚未對 jhash / hsiphash / siphash 在 D-v3B 下做正式三 backend benchmark。
* 尚未確認 Layer 3 是否可報 system impact：

  * 需要 `mpstat -P ALL 1` 檢查轉發核心是否 CPU-bound。
* 尚未把 derived metrics 納入正式 CSV：

  * hash cycles / packet
  * lookup cycles / packet
  * hash / lookup ratio
  * cycles / packet
  * instructions / packet
* bpftrace latency histogram 尚未執行，暫列為 optional supplementary evidence。

---

### 下一步

1. 鎖定 D-v3B multimask 作為正式 workload。
2. 正式跑三 backend：

   * jhash
   * hsiphash
   * siphash
   * 每個 backend N≥5
3. 每次 run 都套用 Layer 0–3 指標：

   * backend identity
   * flows / masks / hit-pkt
   * pktgen pps / errors
   * perf children/self
   * cycles / instructions
   * derived metrics
4. 正式 run 前先用 `mpstat -P ALL 1` 判斷 CPU-bound。
5. 若時間允許，再用 bpftrace 做 `ovs_flow_hash_backend()` latency histogram，作為 supplementary evidence。

---

### 文件與資料狀態

新增或使用的腳本：

* `install_dv3_l3l4_rules.sh`
* `pktgen_dv3_l3l4.sh`
* `install_dv3b_multimask_rules.sh`
* `pktgen_dv3b_multimask.sh`
* `install_dv3ab_combined_rules.sh`

重要資料目錄：

* D-v3B jhash probe：

  * `ovs_datapath_bench/results/dv3b_multimask_jhash_probe_20260610_174557/`
* D-v3B live evidence：

  * `ovs_datapath_bench/results/dv3b_multimask_live_20260610_174101/`
* A+B prefix 版：

  * 視為 failed experiment / negative result，保留但不納入正式 benchmark。

---

### 今日總結

今天的主要成果是把 D-v3 workload exploration 收斂下來：

* Candidate A 證明「加長 input」可行但不夠強。
* Candidate B 證明「多 mask / 多 lookup」是有效 signal amplification 方法。
* Candidate A+B 證明「prefix 長度變化」不是可靠 multimask 方法。
* 正式 benchmark 應鎖定 D-v3B multimask，而不是繼續放大 workload。

明天的主線應該是：**不要再改 workload，先把 D-v3B 三 backend N≥5 正式跑完。**
