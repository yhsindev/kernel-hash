# Part 3（OVS case study）攻擊 (A)：jhash full-hash collision 構造 — 模型驗證與工具鏈

把 §5a(`notes/formal_model.md`)的 seed-independent full-hash collision 走法,落實成可重現的離線工具鏈,並用真實 kernel 資料驗證離線雜湊模型逐位元忠實。本篇記錄**構造端**的方法、驗證與待執行的量測協定;實際植入後的 bucket-load 量測為後續另記。

不產生可部署攻擊;碰撞集在自有 testbed 內植入、量測,屬 defensive 案例研究。攻擊面與防禦結論見 `notes/formal_model.md` §3b/§5、`notes/attack_cost.md`。

## 目的

驗證「離線重算的 `flow_hash` 與 kernel 實算逐位元相同」,並建立 key→規則→封包的構造工具鏈,使搜出的 full-hash collision 植入真實 OVS flow table 後確實落同一 bucket。這是 §5a 走法 (iii) 可行性的前置確認。

## 狀態

**構造端完成、量測端待執行**。離線 jhash2 模型已對 64 筆真實資料驗證;工具鏈三件套已就緒並端到端跑通(K=8 demo)。尚未植入真實表、尚未取 bucket-load 量測。

## 方法與工具鏈

兩段雜湊(`flow_table.c:562` `find_bucket`):`bucket = jhash_1word(flow_hash(key), ti->hash_seed) & (m−1)`。第 1 段 `flow_hash` = `jhash2(masked_key 22 words, initval=0)`,無祕密;完整 32-bit 輸出相等 → 經任意隨機 `hash_seed` 仍落同桶(seed/resize 無關,§5a)。

工具鏈:

1. **模板萃取** — `scripts/parse_ovs_keydump.py LOG --template` 從 keydump 吐出 22-word 的 `g_base` 固定常數模板(恆定 word→值、可控 word→0)。產物 `attack/dv3b_base_template.txt`:固定非零僅 `w8=0x00010006`(in_port=6, mac_proto=1)、`w16=0x00000008`(eth.type=IPv4)、`w17=0x00000011`(ip.proto=UDP);可控 `w20`=src_ip、`w21`=dst_ip。
2. **碰撞搜尋** — `attack/find_jhash_collision --base T --keys K --out keys.txt`:在可控 word(預設 `var=[20,2)`,64 bit)上暴搜 `jhash2(key)=t` 的 K 個 key。`t` = 模板(var=0)的 jhash2。成本 `K·2³²`(每候選命中機率 2⁻³²),實測 ~280M jhash/s(本機 12 執行緒)。**必須給 `--base`**:`g_base` 全 0 會與 kernel 固定常數不符,碰撞在真實表無效。
3. **key→規則/封包** — `attack/keys_to_rules.py keys.txt --template T`:解 `w20/w21` 為 nw_src/nw_dst,輸出 OF 規則(`ip,nw_proto=17,nw_src,nw_dst,in_port,actions=output:N`,ports 不匹配 → 對齊模板的 ports-wildcard mask shape)與 (src_ip,dst_ip) 配對清單。含**驗證閘**:每 key 固定 word 須吻合模板、且全部 key 的 jhash2 須相等,否則中止不輸出。

## 模型驗證（已完成）

離線 jhash2(22 words、little-endian、initval=0)對 `results/keydump_dv3b_masked.log` 的 64 筆 (masked-key, kernel hash) 配對:**64/64 完全吻合**。據此:

- 當前 backend = jhash(seed-0 jhash2)、masked-key word 佈局 = 22 words 均經確認;
- 離線模型逐位元忠實 → 搜出的碰撞植入後在真實表會碰撞(消除 `find_jhash_collision.c` 註解所警示的最大風險)。

端到端 demo(K=8,真實模板):`verify=OK`,獨立以離線 jhash2 複核 8 個 key 全 = 共同 target;`keys_to_rules.py` 驗證閘正向通過、且竄改固定 word 時正確中止。

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
- 構造端完成不等於攻擊已驗證;bucket-load 效果須待植入量測(本篇狀態)。
