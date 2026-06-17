# Part 3（OVS case study）攻擊 (A)：jhash full-hash collision 構造 — 模型驗證與工具鏈

把 §5a(`notes/formal_model.md`)的 seed-independent full-hash collision 走法,落實成可重現的離線工具鏈,並用真實 kernel 資料驗證離線雜湊模型逐位元忠實。本篇記錄**構造端**的方法、驗證與待執行的量測協定;實際植入後的 bucket-load 量測為後續另記。

不產生可部署攻擊;碰撞集在自有 testbed 內植入、量測,屬 defensive 案例研究。攻擊面與防禦結論見 `notes/formal_model.md` §3b/§5、`notes/attack_cost.md`。

## 目的

驗證「離線重算的 `flow_hash` 與 kernel 實算逐位元相同」,並建立 key→規則→封包的構造工具鏈,使搜出的 full-hash collision 植入真實 OVS flow table 後確實落同一 bucket。這是 §5a 走法 (iii) 可行性的前置確認。

## 狀態

**攻擊已在真實表重現(靜態 + 動態證據完成)**。離線 jhash2 模型對 64 筆真實資料驗證 64/64;K=16 碰撞集植入真實 OVS datapath:16 條 flow 的 in-kernel `flow_hash` 全 = `0xcaa92980`(同 hash);`ovs_buckets` 取得 `Lmax=16`、單一桶 chain=16、`collisions=120`=C(16,2);`ovs_probelen` probe 數延伸到 16(baseline ≤7)。三重佐證一致。

## 方法與工具鏈

兩段雜湊(`flow_table.c:562` `find_bucket`):`bucket = jhash_1word(flow_hash(key), ti->hash_seed) & (m−1)`。第 1 段 `flow_hash` = `jhash2(masked_key 22 words, initval=0)`,無祕密;完整 32-bit 輸出相等 → 經任意隨機 `hash_seed` 仍落同桶(seed/resize 無關,§5a)。

工具鏈:

1. **模板萃取** — `scripts/parse_ovs_keydump.py LOG --template` 從 keydump 吐出 22-word 的 `g_base` 固定常數模板(恆定 word→值、可控 word→0)。產物 `attack/dv3b_base_template.txt`:固定非零僅 `w8=0x00010006`(in_port=6, mac_proto=1)、`w16=0x00000008`(eth.type=IPv4)、`w17=0x00000011`(ip.proto=UDP);可控 `w20`=src_ip、`w21`=dst_ip。
2. **碰撞搜尋** — `attack/find_jhash_collision --base T --keys K --out keys.txt`:在可控 word(預設 `var=[20,2)`,64 bit)上暴搜 `jhash2(key)=t` 的 K 個 key。`t` = 模板(var=0)的 jhash2。成本 `K·2³²`(每候選命中機率 2⁻³²),實測 ~280M jhash/s(本機 12 執行緒)。**必須給 `--base`**:`g_base` 全 0 會與 kernel 固定常數不符,碰撞在真實表無效。
3. **key→規則/封包** — `attack/keys_to_rules.py keys.txt --template T`:解 `w20/w21` 為 nw_src/nw_dst,輸出 OF 規則(`ip,nw_proto=17,nw_src,nw_dst,in_port,actions=output:N`,ports 不匹配 → 對齊模板的 ports-wildcard mask shape)與 (src_ip,dst_ip) 配對清單。含**驗證閘**:每 key 固定 word 須吻合模板、且全部 key 的 jhash2 須相等,否則中止不輸出。

## 模型驗證（已完成）

離線 jhash2(22 words、little-endian、initval=0)對 `results/ovs/keydump_dv3b_masked.log` 的 64 筆 (masked-key, kernel hash) 配對:**64/64 完全吻合**。據此:

- 當前 backend = jhash(seed-0 jhash2)、masked-key word 佈局 = 22 words 均經確認;
- 離線模型逐位元忠實 → 搜出的碰撞植入後在真實表會碰撞(消除 `find_jhash_collision.c` 註解所警示的最大風險)。

端到端 demo(K=8,真實模板):`verify=OK`,獨立以離線 jhash2 複核 8 個 key 全 = 共同 target;`keys_to_rules.py` 驗證閘正向通過、且竄改固定 word 時正確中止。

## 在真實表的攻擊結果（K=16）

工作負載:K=16 碰撞集(對攻擊規則自身佈局的模板 `attack4_template.txt` 搜出,target `0xcaa92980`),裝成 16 條 `priority=100,ip,nw_proto=17,nw_src,nw_dst,actions=output:2` 規則(不含 NORMAL),`pktgen_pairs.sh` 逐對灌入。

* **同 hash(直接證據)**:植入後抓 keydump,16 條 flow 的 in-kernel `flow_hash` **全部 = `0xcaa92980`**(`grep hash | uniq -c` → `16 hash=0xcaa92980`)。因 `bucket = jhash_1word(0xcaa92980, seed) & (m−1)` 對任意 seed 同值,16 條必落同一桶。此為 §5a seed-independent 走法的真實表實證。
* **靜態(`ovs_buckets`)**:`# n_buckets 1024 total_flows 17 Lmax 16 nonempty 2 collisions 120`,chain-length 直方圖 = `{0:1022, 1:1, 16:1}` —— **單一桶 chain 長度 = 16**,其餘 ≤1。`collisions=120`=C(16,2) 精確對應 16 條同桶;`H_norm≈0.032`(良性 baseline ~0.94)= 極度集中。對照:17 條若隨機散佈,期望 Lmax ≈ 1–2。(`results/ovs/part3_buckets_attack_jhash.txt`)
* **動態(`ovs_probelen`,probe 退化)**:直方圖延伸到 **16**(overflow 0),16 對平均送 → probe 數在 1..16 大致均勻、上限 = K = 16。對照良性 D-v3B baseline(probe max ~7、集中 0–2,見 `part3_probe_dv3b.md`):**單桶 chain 把該桶查找從 O(1) 推到 O(K)**。

結論:離線構造的完整 jhash 碰撞,在真實 OVS kernel datapath 重現為單桶長 chain,靜態(同 hash)與動態(probe 走滿 chain)雙重佐證,且不受隨機 `hash_seed` 影響。

## 量測踩到的坑（操作教訓,供重跑參考）

1. **OF in_port ≠ datapath in_port**:規則寫 `in_port=<dp 埠號>` 比對不到(OF 埠號不同)→ 封包落 NORMAL flood。改為規則不 match in_port(OVS 仍會在 megaflow 自動 pin in_port,masked-key 佈局不變)。`keys_to_rules.py --in-port` 預設 -1(不寫)。
2. **NORMAL 觸發 MAC learning → eth.src 時而被 unwildcard**(`w11/w12` 在 match/wildcard 間飄),模板不穩。移除 NORMAL → MAC 恆 wildcard=0,模板固定。
3. **手動 `ovs-dpctl del-flows` 會破壞 dpif 同步**(revalidator `failed to put[modify]/flow_del (No such file or directory)`),之後 upcall 一條 flow 都裝不進去 → 需 `systemctl restart ovs-vswitchd`。改用 idle 逐出清 flow,勿手動刪 datapath。
4. **`restart ovs-vswitchd` 後 `ovs_dbg_tbl` 掉成 NULL** → `ovs_buckets` 顯示 "no flow table registered";需重建 datapath(reload 模組)重設。`ovs_probelen` 不受影響。
5. 驗證 flow 是否真的裝上,用 keydump 記錄數(插入當下記),勿只看事後 `dump-flows`(會被 idle 逐出誤導)。

## 待執行（下一步）

1. **scaling**:K=16/32/64/128 各量,看 jhash 下 Lmax / probe-max 隨 K 線性成長(K=16 已得 Lmax=16)。
2. **掃雜湊函式**:同流程在 hsiphash / siphash build 重跑 → 預期回 baseline(keyed 雜湊重新散開)。「jhash 線性 vs keyed 平坦」即「換 keyed 雜湊可擋」的實證。
3. 提醒:reload 後須以 keydump `uniq -c` 確認碰撞仍成立(dp in_port 等佈局未變),再信 `ovs_buckets` 數字;本次 K=16 reload 後仍 16×`0xcaa92980`,佈局穩定。

## 待執行的量測協定

1. 搜碰撞(K=64 起,scaling 取 16/32/64/128)→ `keys_to_rules.py` 轉規則/配對。
2. 植入:`priority=0,actions=NORMAL` 底噪 + K 條碰撞規則;**逐對**送 UDP/IPv4 封包(範圍隨機無法產生特定配對),持續送防 idle 逐出。
3. **植入後複驗佈局**:keydump 抓數筆 → 確認仍 `(start=296, len=88)` 且固定 word == 模板;不符則重萃模板、重搜(模板綁定 ruleset/testbed,尤其 in_port 與 range floor)。
4. 量測:`ovs_buckets`(L_max / collisions C / H_norm)+ `ovs_probelen`,對照良性 D-v3B baseline。每 cell ≥3–5 次重複。
5. 掃雜湊函式:同一組 rules/pairs 在 jhash / hsiphash / siphash build 下重跑。
6. **假說**:jhash 下單一 bucket chain 長度 = K、隨 K 線性成長(`L_max≫` baseline 7);hsiphash/siphash 下重新散開、回 baseline。此「線性 vs 平坦」對照即「換 keyed 雜湊可擋」的實證。

## 範圍限定

- 模型驗證僅涵蓋當前 jhash build 與 UDP/IPv4 分支;keyed 雜湊無法離線重算(正是防禦點),其「不可構造」由不知金鑰推得,非實測。
- 模板綁定 D-v3B ruleset/testbed;不同 ruleset 的 range/佈局須重萃。
- 搜出的 IP 為任意值,需裝對應 exact-match 規則才可達;量測前以第 3 步實測把關。
- 成本模型 `K·2³²` 為固定目標暴搜;牆鐘與成本不對稱見 `notes/attack_cost.md`。
- 攻擊已在 K=16 真實表重現(同 hash + probe 走滿 chain);靜態 `ovs_buckets` Lmax 圖、scaling、keyed 雜湊對照尚待補(見「待執行」)。
