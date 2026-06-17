# Part 3 防禦掃描 runbook（3 backend × benign/attack + per-hash cycle）

目標:在真實 OVS 上量化 jhash / hsiphash / siphash 在碰撞攻擊下的 bucket-load 與 per-hash 成本,證明「jhash 單桶崩潰、keyed 雜湊散開」且量出防禦的固定成本。靜態(`ovs_buckets`)+ 動態(`ovs_probelen`)+ per-hash cycle(`ovs_hashcycles`)三證據。

> keyed-hash 金鑰已改為 **per-boot 隨機**(`ovs_flow_init` 以 `get_random_bytes` 填,比照 OVS `ti->hash_seed`),所以量測在部署等級的金鑰下進行。

## §0 一次性前置

直接引用、不重跑:
- benign bucket-load × 3 backend → `results/part3_buckets_dv3b.md`
- benign probe × 3 → `results/part3_probe_dv3b.md`
- per-hash 微觀成本 × 3(isolated)→ `hash_microbench v6`(88B 內插:jhash≈85、hsiphash≈78、siphash≈130 cyc)

鎖頻(cycle 量測前一次,三輪共用):
```
sudo cpupower frequency-set -g performance
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

碰撞集規則/配對(從已 commit 的 keys4 重生):
```
cd ~/projects/kernel-hash/ovs_security/attack
python3 keys_to_rules.py keys4.txt --template attack4_template.txt --rules-out /tmp/coll_rules4.txt --pairs-out /tmp/coll_pairs4.txt
```

### 鐵則（本次 debug 踩過的坑）
1. reload 一定用「剛 build 的 srcversion」(`modinfo` 取),不要用系統版/舊值。
2. reload 後先確認 `ovs_buckets` 不是 `# no flow table registered`(否則 `ovs_dbg_tbl` 沒接上)。
3. **絕不手動 `ovs-dpctl del-flows`**(破壞 dpif 同步、flow 之後裝不進去);清 OF 規則只用 `ovs-ofctl del-flows br0`,清 datapath flow 靠停流量 idle 逐出。
4. 攻擊規則**不含 NORMAL**(MAC learning 會讓 masked-key 佈局飄)、**不 match in_port**(OF 埠號≠dp 埠號,`keys_to_rules.py --in-port` 預設 -1 不寫)。
5. pktgen 先 `echo reset > pgctrl`、**前景**跑(背景 `&` 會因 sudo/dirty state 失敗)。
6. 信 `Lmax` 前先用 keydump `uniq -c` 驗碰撞。
7. 此 build 每包多兩個 `rdtsc_ordered`,**只量 cycle、不量 throughput**。

## §1 每個 backend 一輪（jhash → hsiphash → siphash）

### 步驟 A:切 backend + build + reload
編輯 `kernel_work/linux-hwe-6.8-6.8.0/net/openvswitch/flow_table.c` 的 backend 三個 `#define`:
- jhash:`JHASH 1 / HSIPHASH 0 / SIPHASH 0`
- hsiphash:`0 / 1 / 0`
- siphash:`0 / 0 / 1`

```
cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0
make M=net/openvswitch clean
make -C /lib/modules/$(uname -r)/build M=$PWD/net/openvswitch modules -j$(nproc) 2>&1 | tail -3
SRC=$(modinfo net/openvswitch/openvswitch.ko | awk '/^srcversion:/{print $2}')
~/projects/kernel-hash/ovs_datapath_bench/scripts/reload_ovs_module.sh "$SRC"
nm -u net/openvswitch/openvswitch.ko | grep -iE 'siphash' || echo "no keyed import = jhash"
sudo cat /sys/kernel/debug/ovs_buckets | head -1
```
驗:`nm -u` → jhash 無 import、hsiphash 出 `__hsiphash_unaligned`、siphash 出 `__siphash_unaligned`;`ovs_buckets` 第一行非 "no flow table registered"。

### 步驟 B:裝攻擊規則 + 灌流量 + 抓四個量
把 `B=` 改成當前 backend 名:
```
B=jhash
sudo ovs-ofctl del-flows br0
sudo ovs-ofctl add-flows br0 /tmp/coll_rules4.txt
cd ~/projects/kernel-hash/ovs_datapath_bench/scripts
sudo ip netns exec ns1 bash -c 'echo reset > /proc/net/pktgen/pgctrl'
sudo dmesg -C
echo 0 | sudo tee /sys/kernel/debug/ovs_probelen >/dev/null
echo 0 | sudo tee /sys/kernel/debug/ovs_hashcycles >/dev/null
echo 1 | sudo tee /sys/kernel/debug/ovs_keydump >/dev/null
DURATION=8 COUNT=500 ./pktgen_pairs.sh /tmp/coll_pairs4.txt
sudo cat /sys/kernel/debug/ovs_buckets    | tee ~/projects/kernel-hash/ovs_security/results/part3_buckets_attack_$B.txt
sudo cat /sys/kernel/debug/ovs_probelen   | tee ~/projects/kernel-hash/ovs_security/results/part3_probe_attack_$B.txt
sudo cat /sys/kernel/debug/ovs_hashcycles | tee ~/projects/kernel-hash/ovs_security/results/part3_hashcyc_attack_$B.txt
sudo dmesg | grep -oE 'hash=0x[0-9a-f]+' | sort | uniq -c | sort -rn | head
```

### 步驟 C:判讀（每輪）
- `uniq -c`:**jhash → `16 hash=0x…`(全同,撞)**;**hsiphash/siphash → 16 個各 1(散開,防禦成立)**。
- `ovs_buckets` `Lmax`:jhash=16;keyed ≈ 1–2。
- `ovs_probelen`:jhash 尾巴到 16;keyed 集中 1。
- `ovs_hashcycles`:讀 `rdtsc_pair_overhead_min`,取 histogram mode → **per-hash ≈ mode − overhead_min**(此 backend、88B)。

## §2 結果記錄表

| backend | per-hash cyc(in-ctx, mode−ovh) | per-hash(microbench@88B) | attack Lmax | attack probe-max | keydump 驗證 |
|---|---|---|---|---|---|
| jhash | ___ | ~85 | 16 | 16 | 16×同 hash |
| hsiphash | ___ | ~78 | ___（預期 1–2） | ___ | 16×不同 |
| siphash | ___ | ~130 | ___（預期 1–2） | ___ | 16×不同 |

benign 欄(Lmax/H_norm)由 `part3_buckets_dv3b.md` 引用填入。

## §3 結論與 caveats（跑完寫）
- **主結論**:jhash 在碰撞集下單桶 `Lmax=K`、probe→K;hsiphash/siphash 用同一組 key 散開回 baseline → 防禦來自(隨機)金鑰、與 backend 選擇無關。
- **效能**:in-context cycle 與 microbench 對齊(88B 下 hsiphash≈jhash、siphash≈1.5×);此固定 per-hash 開銷遠小於擋掉的 chain-walk(jhash probe→K)。
- **caveats**:K=16(結構性足夠,OVS 規模化意義有限);cycle 報 mode−overhead 且鎖頻;此 instrumented build 不量 throughput;keyed 金鑰為 per-boot 隨機(部署等級)。
