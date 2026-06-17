# Part 3（OVS case study）：masked-key layout 推論（ovs_keydump diagnostic）

`/sys/kernel/debug/ovs_keydump`:寫 `1` 開啟後,`flow_key_insert()` 會把接下來最多 `OVS_KEYDUMP_CAP=64` 筆 flow 插入時、實際送進 `flow_hash()` 的那段 masked-key 印到 kernel log(`pr_info` + `print_hex_dump`),每筆以 `start=<N> len=<L> hash=<H>` 開頭。本文件用此 diagnostic 反推 D-v3B 工作負載下 masked-key 的位元組 layout,作為後續 controlled bucket-load measurement 的**規劃依據**。

不產生 exploit、不注入封包、不宣稱漏洞;僅做 defensive log 分析與 layout 推論。

## 目的

理解 OVS masked-key 在 `struct sw_flow_key` 中的位元組排列:找出 `(start, len)` 對應的 mask/range group、各欄位(src_ip / dst_ip / src_port / dst_port / protocol)落在 masked-key 的哪個位元組 offset,並判斷哪一個 group 最適合後續可控量測。

## 狀態

**完成(mask 確證)**。兩份 dump:
* `results/ovs/keydump_dv3b.log` — 192 筆,僅 masked-key(早期 instrumentation)。
* `results/ovs/keydump_dv3b_masked.log` — 64 筆,**含 `ovs_keymask:` mask dump**(instrumentation 加印 `flow->mask->key`)。

以 `scripts/parse_ovs_keydump.py` 分組、解碼、統計 mask pattern。layout 對應已完整驗證,且 `00` 的 wildcard/真值歧義已由 mask 確證消除(見下)。

## 量測條件

* 工作負載:D-v3B 多 mask 規則,`src_ip=10.0.1.1–16`、`dst_ip=10.0.2.1–8`、`src_port=20000–20063`、`dst_port=9000–9015`、`output_port=2`,共 18,786 條規則(priority=100);`pktgen_dv3b_multimask.sh` 灌流量觸發 datapath flow 插入。
* 平台:kernel 6.8.0-124-generic,OVS 2.17.9,自建 `openvswitch.ko`(`OVS_FLOW_HASH_DEBUG_LEN=1`)。
* diagnostic:`/sys/kernel/debug/ovs_keydump`,寫 `1` 開啟、額度 `OVS_KEYDUMP_CAP=64`;輸出在 kernel log。每筆印兩段:`ovs_keydump:`(masked-key = `key & mask`)與 `ovs_keymask:`(mask 本身,`flow->mask->key` 同段 region)。
* dump 格式:`print_hex_dump(KERN_INFO, ..., DUMP_PREFIX_OFFSET, 16, 1, ..., mklen, false)` — offset 欄為 8 位 hex、相對 region 起點(非絕對 `sw_flow_key` offset),每列最多 16 位元組。
* masked-key 被 wildcard 的位元組讀為 `00`;mask 位元組 `ff`=該位元組參與比對、`00`=wildcard,用以精確區分 masked-key 的 `00` 是真值還是 wildcard。

## 觀測到的 group

192 筆全部落在**單一** group:`start=296, len=88`(region offset `0x00`–`0x57`)。`len=88` 與 OVN megaflow 的 IPv4=88B 量測一致。varying 位元組僅 `0x4a–0x4d`(兩埠)、`0x50/0x52/0x53`(src_ip;`0x51` 恆 `00`)、`0x57`(dst_ip 末 byte;`0x54–0x56` 恆 `0a 00 02`),其餘全 stable。

## 欄位 offset 對應（以資料錨定，非單純推測）

錨點:`eth.type = 08 00`(IPv4)出現在 region offset `0x40`。由此 `recirc_id` 落在 region `0x28`(對應絕對 offset 336,故 `start=296` 之起點位於 `tun_key` 尾端)。各欄位間距由 `struct sw_flow_key`(flow.h)固定,逐一對上樣本:

| region offset | 欄位 | 樣本觀測 |
|---|---|---|
| `0x00`–`0x17` | `tun_key` 尾段 | 全 `00`(無 tunnel) |
| `0x20`–`0x21` | `phy.in_port` | `06 00` = 6（穩定） |
| `0x22` | `mac_proto` | `01` = Ethernet（穩定） |
| `0x23` | `tun_proto` | `00`（穩定） |
| `0x24`–`0x27` | `ovs_flow_hash` | `00`（穩定） |
| `0x28`–`0x2b` | `recirc_id` | `00`（穩定） |
| `0x2c`–`0x37` | `eth.src` / `eth.dst` | 全 `00`（MAC 被 wildcard） |
| `0x40`–`0x41` | **`eth.type`** | `08 00` = IPv4（穩定，錨點） |
| `0x44` | **`ip.proto`** | `11` = UDP（穩定） |
| `0x48`–`0x49` | `ct_zone` | `00`（穩定） |
| `0x4a`–`0x4b` | **`tp.src`（src_port）** | 變動／或 `00`(wildcard) |
| `0x4c`–`0x4d` | **`tp.dst`（dst_port）** | 變動／或 `00`(wildcard) |
| `0x4e`–`0x4f` | `tp.flags` | `00`（UDP，穩定） |
| `0x50`–`0x53` | **`ipv4.addr.src`（src_ip）** | `0a 00 01 xx`／或 `00`(wildcard) |
| `0x54`–`0x57` | **`ipv4.addr.dst`（dst_ip）** | `0a 00 02 xx` |

注意:masked-key 中**埠號(`tp`)排在 IPv4 位址之前**,與封包標頭線序(位址在前)相反 — 這是 `sw_flow_key` 結構順序使然。可控位元組共 12 個:`0x4a–0x4d`(兩個埠)與 `0x50–0x57`(兩個位址)。

## 解碼樣本（stable / varying）

stable 位元組(全筆相同):除 `0x4a–0x4d`(埠)與 `0x50–0x57`(位址)外全部固定 → in_port=6、Ethernet、IPv4、UDP、flags=0、無 tunnel/VLAN/conntrack。varying 位置:`0x4a–0x4d`、`0x50–0x57`。

| # | hash | src_port | dst_port | src_ip | dst_ip |
|---|---|---|---|---|---|
| 1 | c64d15be | —(0) | —(0) | —(0) | 10.0.2.1 |
| 2 | 920bc4cb | —(0) | —(0) | 10.0.1.7 | 10.0.2.4 |
| 3 | 57b9e3ce | 20016 | —(0) | 10.0.1.8 | 10.0.2.6 |
| 4 | 61636521 | —(0) | —(0) | 10.0.1.11 | 10.0.2.4 |
| 5 | 4b4f1031 | 20061 | 9002 | 10.0.1.3 | 10.0.2.7 |
| 6 | 3bef0a66 | 20050 | —(0) | —(0) | 10.0.2.3 |
| 7 | cd1f3d76 | 20020 | —(0) | 10.0.1.2 | 10.0.2.6 |
| 8 | 2c533808 | 20031 | —(0) | 10.0.1.4 | 10.0.2.6 |
| 9 | c6f2f7a5 | —(0) | —(0) | 10.0.1.5 | 10.0.2.4 |
| 10 | b78b3e42 | 20010 | —(0) | 10.0.1.14 | 10.0.2.6 |
| 11 | 1c226f61 | 20024 | —(0) | —(0) | 10.0.2.3 |
| 12 | d97e2281 | 20019 | 9007 | 10.0.1.1 | 10.0.2.7 |
| 13 | b8664a1c | —(0) | 9000 | (截斷) | (截斷) |

所有非零值皆落在工作負載範圍內(src_port 20000–20063、dst_port 9000–9015、src_ip 10.0.1.1–16、dst_ip 10.0.2.1–8),交叉驗證 layout 對應正確。(上表為早期 192 筆 log 的前段樣本;下方 mask 確證與統計改用 64 筆 masked log。)

## mask 確證:88-byte region 的三類位元組

`ovs_keymask:` dump 把 region 每個位元組精確分成三類(mask 的結構部分全 64 筆一致):

**(a) 全程被比對(`ff`)但值固定** — 進 hash 但不提供 flow set 內變異:
in_port=6(0x20–21)、mac_proto=1(0x22)、tun_proto=0(0x23)、recirc_id=0(0x28–2b)、vlan.tci=0(0x3a–3b)、cvlan.tci=0(0x3e–3f)、eth.type=0x0800(0x40–41)、ip.proto=0x11(0x44)、ip.frag=0(0x47)、**dst_ip(0x54–57,全 64 筆皆 match)**。

**(b) 全程 wildcard(`00`)** — masked-key 恆為 0:
ovs_flow_hash(0x24–27)、eth.src/dst(0x2c–37)、vlan/cvlan.tpid(0x38–39,0x3c–3d)、ct_state/ct_orig_proto(0x42–43)、ip.tos/ttl(0x45–46)、ct_zone(0x48–49)、tp.flags(0x4e–4f)。

**(c) 逐筆變動的 match(multimask 維度)**:src_port(0x4a–4b)、dst_port(0x4c–4d)、src_ip(0x50–53)。

歧義消除已交叉驗證:mask 判定與「值≠0」啟發式在 64 筆 × 4 欄共 **0 筆不一致**,且無任何「mask=ff 但 masked-value 全 0」的可控欄位 —— 即此 workload 無「真值剛好為 0」的可控欄位,故啟發式碰巧正確,mask 將其升級為確證。

## 欄位 presence 與 mask-pattern 分佈（64 筆 masked log，mask 判定）

| 欄位 | 被設定 | wildcard | distinct 值 |
|---|---:|---:|---:|
| dst_ip | 64/64 | 0 | 7（10.0.2.1–7） |
| src_ip | 45/64 | 19 | 15（10.0.1.1–15） |
| src_port | 38/64 | 26 | 25 |
| dst_port | 32/64 | 32 | 13（9001–9014） |

`dst_ip` 在全部紀錄皆被設定 → 為此組規則的共同 match 欄位;其餘三欄為選擇性。共 **7 種 mask pattern**:

| 筆數 | present 欄位 |
|---:|---|
| 15 | src_ip, dst_ip, src_port, dst_port（full 5-tuple） |
| 13 | src_ip, dst_ip, src_port |
| 10 | dst_ip, src_port |
| 9 | src_ip, dst_ip, dst_port |
| 8 | dst_ip, dst_port |
| 8 | src_ip, dst_ip |
| 1 | dst_ip |

## 餵進雜湊函式的有效變異很窄

88-byte region 中絕大多數位元組屬上述 (a)/(b)(固定常數或 wildcard 補 0),flow set 內真正變動的只有 src_ip/dst_ip/src_port/dst_port,且高位元組固定(`0a 00 01`/`0a 00 02`、port 高 byte `4e`/`23`)。有效 key 熵約 **17 bits**(src_ip 低 byte ~4 bit、dst_ip ~3 bit、src_port ~6 bit、dst_port ~4 bit,且依 mask pattern 部分 wildcard)。對後續 bucket-load measurement 的意義:雜湊函式實際被餵入的變異維度很低,這是評估良性 baseline 與攻擊情境的共同前提。

## 觀察

* **layout 推論完整成立**:port-before-address 順序、12 個可控位元組的位置、protocol/eth.type 的值,全部與 `struct sw_flow_key` 預測一致。
* **這是 multimask**:192 筆共用同一 `(start=296, len=88)` envelope,但分屬 7 種 mask pattern,各自 wildcard 的欄位子集不同。成因:`update_range()` 取所有 mask 的 union 後 `rounddown/roundup` 到 8 位元組,故不同 mask 共享同一 range,內部各自 wildcard 不同欄位。`dst_ip` 為唯一全程被設定的欄位。
* **`00` 歧義已由 mask 確證消除**:`ovs_keymask:` 直接給出每位元組是 match(`ff`)還是 wildcard(`00`),不再依賴值啟發式(見「mask 確證」一節)。
* **本批 (masked-key, hash) 配對另作離線雜湊模型的 oracle**:offline jhash2(22 words, LE, init0)對 64 筆 == kernel `flow_table.hash`,64/64 吻合 → 確認 backend=jhash 且離線模型逐位元忠實。詳見 [part3_attack_collision.md](part3_attack_collision.md)。

## 後續 controlled measurement 的 group 選擇

`(start=296, len=88)` 即候選 group,四項標準皆滿足:range 穩定、可觀測欄位清楚、可控位元組充足(12)、與封包欄位一一對應。因屬 multimask(7 種 pattern),做乾淨量測時建議**只取 full 5-tuple mask 子集**(src_ip + dst_ip + src_port + dst_port 全設,64 筆 masked log 中 15 筆),使 12 個可控位元組全部 deterministic;混入部分 wildcard 的 mask 會使 hash 輸入維度不一致、難以歸因。

## 範圍限定／不確定

* 非完整流量取樣(masked log 64 筆受 `OVS_KEYDUMP_CAP` 限制);distinct 值有覆蓋缺口(dst_ip 僅見 .1–7、src_ip .1–15、dst_port 9001–9014),為取樣未及而非規則缺漏。
* (已解決)`00` = wildcard vs 真值 0:已加印 `ovs_keymask:`,逐位元組確證。
* `start=296` 起點落在 `tun_key` 尾端;region `0x00–0x17` 為被 wildcard 的 tunnel 欄位尾段,對量測無資訊但仍進 hash 輸入。絕對 offset 若需確認,對 `.ko` 跑 `pahole -C sw_flow_key`(需 DWARF)。
* 僅觀測到 UDP/IPv4 分支;TCP(proto=06、flags 非 0)或 IPv6 走 union 不同分支,offset 表需重判。
