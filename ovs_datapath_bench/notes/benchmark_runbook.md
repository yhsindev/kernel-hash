# OVS hash-backend benchmark runbook（切 backend → 在 D-v3B 上量測）

對應任務:把 jhash / hsiphash / siphash 各在 **D-v3B multimask** workload 上跑 N≥5，套 Layer 0–4。
每步「為什麼」見 `lkm_build.md` / `lkm_reload.md` / `datapath_reload_recovery.md`；本檔只給「照抄就能跑」的流程。

**重要:每段 code block 開頭都有 `📂` 標明要在哪個目錄執行。只有兩個目錄:**
- **repo 根**:`~/projects/kernel-hash`（裝規則、reload、跑 pktgen/perf 都在這）
- **kernel source**:`~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0`（只有 build module 在這）

每段都明確 `cd` 絕對路徑、不靠變數,所以你**單獨複製任何一段都能跑**。

---

## 0. 每日 / reboot 後 preflight（一次）

reboot 會把 governor 打回 powersave、載回系統原版 module，**必做**:

```bash
sudo cpupower frequency-set -g performance
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c   # 期望 12 performance
cat /sys/module/openvswitch/srcversion                                       # 系統版=0E035C1F(代表要重 reload 自製)
```

---

## 1. 切換 + build 一個 backend

`flow_table.c` 第 ~646–648 行三選一(改成 1，其餘 0)。三個 backend 對應的**期望 srcversion**:

| backend | define | 期望 srcversion | nm -u 應出現 |
|---|---|---|---|
| jhash    | `OVS_FLOW_HASH_JHASH 1`    | `9934512B440806A9DEFA77A` | (無 out-of-line hash import) |
| hsiphash | `OVS_FLOW_HASH_HSIPHASH 1` | `670B9FE03F3CECAF4D7F865` | `__hsiphash_unaligned` |
| siphash  | `OVS_FLOW_HASH_SIPHASH 1`  | `75AA9FCC444232089DB6AD7` | `__siphash_unaligned` |

改好 define 後 build（**一定要 `-C /lib/modules/.../build`，否則 vermagic 變 6.8.12+**）:

```bash
# 📂 kernel source 目錄
cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0
make M=net/openvswitch clean
make -C /lib/modules/$(uname -r)/build M=$PWD/net/openvswitch modules -j$(nproc) 2>&1 | tail -3
```

(這段用絕對路徑 `cd`,`$PWD` 一定是 kernel source、`$(uname -r)` 一定有值,不會再跑去 `/home/iris`。)

---

## 2. 驗身分 + reload

```bash
# 📂 repo 根目錄
cd ~/projects/kernel-hash
KO=kernel_work/linux-hwe-6.8-6.8.0/net/openvswitch/openvswitch.ko
modinfo "$KO" | grep -E 'vermagic|srcversion'          # vermagic 必須 = 6.8.0-124-generic
nm -u "$KO" | grep -iE 'siphash|hsiphash' || echo '(jhash inline)'

SV=$(modinfo "$KO" | awk '/^srcversion:/{print $2}')
./ovs_datapath_bench/scripts/reload_ovs_module.sh "$SV"   # 帶 srcversion → 不符會 abort
```

（`KO` / `SV` 在這同一段內設好才用,複製整段就行。）

reload 腳本會重建 testbed（br0 / veth / ns）並做 ping sanity；**它會清掉 OpenFlow 規則,所以下一步要重裝 D-v3B。**

---

## 3. 裝 D-v3B workload + sanity（preflight 過關才往下）

```bash
# 📂 repo 根目錄
cd ~/projects/kernel-hash
./ovs_datapath_bench/scripts/install_dv3b_multimask_rules.sh

sudo -v
sudo DURATION=10 ./ovs_datapath_bench/scripts/pktgen_dv3b_multimask.sh >/tmp/pg.txt 2>&1 &
sleep 6
sudo ovs-dpctl show | grep -E 'flows:|masks:'     # 期望 flows≥9000、masks total≈7、hit/pkt>2
sudo ovs-dpctl dump-flows -m | grep -m5 udp        # 期望多種 mask shape(不同欄位組合)
wait
```

四項過關才算 workload valid:`flows≥9000`、`masks total≈7`、`hit/pkt>2`、`errors:0`。

---

## 4. CPU-bound gate（一次性，決定 Layer 3 能不能報）

「bound 在哪」= 哪個資源飽和、卡住吞吐量(放寬它吞吐才會上去)。用 mpstat 判定,不用「感覺」。
在有流量時開另一個 terminal:

```bash
# 📂 任意目錄
mpstat -P ALL 1 5      # 每核心、每秒一筆，跑 5 秒
```

### mpstat 各欄位意思（百分比 = 該核心時間佔比）

| 欄位 | 意思 | 本實驗對應 |
|---|---|---|
| `%usr` | user-space 應用程式 | 幾乎 0（沒跑 user app） |
| `%nice` | 調過 nice 的 user 程式 | 0 |
| `%sys` | kernel 模式（非中斷） | **pktgen 在核心內產包/送包** |
| `%iowait` | CPU 閒置、**等待 I/O 完成** | **IO-bound 的關鍵指標** |
| `%irq` | 處理硬體中斷 | ~0 |
| `%soft` | 處理軟體中斷 softirq | **NET_RX 收包 + OVS datapath lookup + `flow_hash`** ← 最關心 |
| `%steal` | 被 hypervisor 偷走（VM 才有意義） | 0 |
| `%guest`/`%gnice` | 跑 guest VM | 0 |
| `%idle` | 完全閒置（沒事做、也沒在等 I/O） | **飽和判斷** |

### 判定邏輯（兩步，都看數字）

**① 排除 IO-bound**：IO-bound 的特徵是 CPU 閒著等 I/O →「`%iowait` 高」或「`%idle` 高但吞吐上不去」。
- 看瓶頸核心 `%iowait` 是否 ≈ 0 → 沒在等 I/O。
- 結構佐證:pktgen 在核心內造包、走 **veth(純記憶體虛擬網卡)**,無實體 NIC/磁碟 → **根本沒有實體 I/O 可被 bound**。

**② 確立 CPU-bound**：瓶頸核心 `%idle = 0`(飽和)、且時間全在 **`%soft + %sys`**(在算,不是在等)。
其他核心若 `%idle ~100%` → workload **序列化在單核**(pktgen 單執行緒 + veth RX softirq 同核),多給 CPU 也沒用 → 吞吐被「該核每包 CPU 成本」卡死。

**實測範例（D-v3B, 2026-06-12）**:CPU 0 `%idle=0`、`%iowait=0`、`%soft≈66%`、`%sys≈33%`,其餘核心全閒
→ **單核 CPU-bound 在轉發路徑**,非 IO-bound。**轉發核心 = CPU 0**。

### 一個誠實的細節：compute-bound vs memory-bound

`%idle=0` 只代表「核心沒閒」,但可能是「真的在算指令」或「卡在等記憶體(cache miss)」。
mpstat **分不出來**;要分得看 `perf stat` 的 **IPC(instructions/cycle)** 與 cache-misses。
**但對 gate 不影響**:兩者都是 core-bound,吞吐都由每包 CPU 成本決定 → hash 變貴一定反映得到
(差異會表現在「多指令」或「多 cache 壓力」,兩者都進 `cycles/packet`)。

### gate 結論 → Layer 3 報法

- **過(CPU-bound)** → Layer 3 可報 system impact,指標盯**轉發核心**:`perf stat -C <CORE>`、`mpstat -P <CORE>`。
  - ⚠️ pktgen 與轉發**共用同一核**(本例 CPU 0)→ raw pps 被「產包+轉發共核」一起限制,分不清誰的成本,**pps 只當 sanity**;乾淨的系統指標是 **CPU 0 的 `cycles/packet` 與 `%soft`**。
- **沒過(瓶頸在別處 / 有 `%iowait`)** → Layer 3 **只報 sanity**,log 明寫「未 CPU-bound,系統層無法歸因」。
- 記下轉發核心編號 `<CORE>`,給 step 5 的 `perf stat -C`。

### 報告可直接這樣寫

> 在 D-v3B 負載下,`mpstat -P ALL` 顯示轉發核心(CPU 0)`%idle = 0` 且 `%iowait = 0`,
> 時間集中在 softirq 與 system(`%soft ≈ 66%`、`%sys ≈ 33%`),其餘核心閒置。
> 配合核心內 pktgen + veth datapath(無實體 I/O),據此判定本 workload 為**轉發路徑上的單核 CPU-bound**,
> 而非 IO-bound。因此吞吐量受每包 CPU 成本決定,hash backend 的成本差異可在系統層(cycles per packet、`%soft`)被觀察到。

---

## 5. 量一輪（每個 backend 重複 N≥5 次）

正式 run **不 del-flows**（warm-up 已建好 flows，純 fast-path）。一輪同時抓 children% 與 cycles:

```bash
# 📂 repo 根目錄
cd ~/projects/kernel-hash
# 背景連續 pktgen（涵蓋 warm-up + 兩個量測窗口）
sudo -v
sudo DURATION=35 ./ovs_datapath_bench/scripts/pktgen_dv3b_multimask.sh >/tmp/pg.txt 2>&1 &
PID=$!
sleep 5                                            # warm-up:flows 建滿
sudo ovs-dpctl show | grep -E 'flows:|masks:'      # flows gate:確認 ≥9000
mpstat -P 0 1 22 >/tmp/soft.txt 2>&1 &             # 背景記 CPU 0 %soft（Layer 3 佐證,免費,涵蓋下面兩窗口）

# (A) perf record → children% / self%（-C 0 與 stat 同 scope，children% = 占轉發核心比例，較穩）
sudo perf record -C 0 -g -o /tmp/p.data -- sleep 10
# (B) perf stat → cycles / instructions(core-scoped 到轉發核心 CPU 0;見 step 4 gate)
sudo perf stat -C 0 -e cycles,instructions -- sleep 10 2>/tmp/stat.txt

wait "$PID"

# 讀數
echo "=== children% / self% ==="
sudo perf report -i /tmp/p.data --stdio 2>/dev/null \
  | grep -E '\[k\] ovs_flow_hash_backend$|\[k\] masked_flow_lookup$' | head -4
echo "=== cycles / instructions ==="; cat /tmp/stat.txt
echo "=== CPU 0 %soft / %sys（Average 列）==="; grep -iE 'average|平均' /tmp/soft.txt | tail -1
echo "=== pps ==="; grep -oE '[0-9]+pps' /tmp/pg.txt | head -1
sudo rm -f /tmp/p.data
```

每輪記錄(對應 Layer 0–2):
- L0:srcversion、`nm -u`、flows、masks total、hit/pkt、errors
- L1:`ovs_flow_hash_backend` children% / self%
- L2:`masked_flow_lookup` children% / self%
- 系統:pps、cycles、instructions

---

### 量測紀律（2026-06-12 實測教訓）

- **量測期間機器保持閒置**(不動 IDE/瀏覽器)。CPU 0 的 SMT 雙生核是 **CPU 6**
  (`cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list` → `0,6`,共用實體核):
  CPU 6 上任何活動都會搶執行單元/L1L2 → CPU 0 的 IPC 掉、masked% 暴漲。
- **污染輪特徵**:IPC < 1.5、masked_children 飆(~38% vs 正常 ~28%)、pps 掉 → 該輪作廢
  (留 mpstat -P 0,6 證據)。乾淨輪:IPC ~1.77–1.79、children% 聚在 ±0.2 內。
- 實測對照:閒置下 jhash 8 輪 children 9.01±0.14%;受干擾的 2 輪掉到 7.5%。

## 6. 三 backend 完整流程

```text
for backend in jhash hsiphash siphash:
    step 1  改 define + build (-C)
    step 2  驗身分 + reload(每 backend 只 reload 一次)
    step 3  裝 D-v3B + sanity
    step 5  量 N≥5 輪(不 del-flows;run1 視情況保留)
    把該 backend 的 N 輪數字 append 進 CSV
```

CPU-bound gate（step 4）只需在第一個 backend 做一次。

---

## 7. derived metrics（跑完用現有數字算，不用多跑）

設某輪 perf stat 的 `cycles` 為 C，pktgen 該窗口封包數為 P（≈ pps × 10s）:

```text
cycles_per_packet        = C / P
hash_cycles_per_packet   = cycles_per_packet × (ohash_children% / 100)
lookup_cycles_per_packet = cycles_per_packet × (masked_children% / 100)
hash_lookup_ratio        = ohash_children% / masked_children%      (用 flat 數字)
instructions_per_packet  = instructions / P
```

主結論看 `hash_cycles_per_packet` 與 `hash_lookup_ratio`（最穩、最有工程意義）。

---

## 8. 異常排查（順序固定:先身分,再 validity）

1. backend 身分:`cat /sys/module/openvswitch/srcversion` + `nm -u $KO` —— 對不上 = build/reload 錯 backend。
2. workload validity:`ovs-dpctl show`（flows≥9000? masks≈7? hit/pkt>2?）+ vswitchd log 有沒有 `failed to put`（datapath ENOENT，見 `datapath_reload_recovery.md`）。
3. 數字全 0 / flows=0 → 多半是 datapath 壞或規則沒裝;**不要盲目重跑**,先修狀態。

---

## 9. 收工 / 回系統原版

```bash
./ovs_datapath_bench/scripts/install_dv3b_multimask_rules.sh restore   # 規則回 NORMAL
# 若要回系統原版 module:
sudo systemctl stop ovs-vswitchd ovsdb-server openvswitch-switch
sudo modprobe -r openvswitch && sudo modprobe openvswitch
sudo systemctl start ovsdb-server ovs-vswitchd openvswitch-switch
```

commit 時:**逐檔 `git add <path>`(不要 `-A`)**、commit message **不帶 Co-Authored-By trailer**。

iris@linux:~/projects/kernel-hash$ cd ~/projects/kernel-hash
sudo -v
./ovs_datapath_bench/scripts/run_dv3b_benchmark.sh jhash 5
python3 ovs_datapath_bench/scripts/summarize_dv3b.py
>>> backend=jhash  loaded srcversion=9934512B440806A9DEFA77A  (core=0, N=5)
    (無 out-of-line hash import → jhash inline)
>>> warm-up 15s(建 flows,不記錄)
    warm-up 後 flows=15439
>>> run 1/5
jhash,1,9934512B440806A9DEFA77A,15440,8,4.01,9.08,9.04,28.51,20.54,44014290457,78533662785,1.78,67.19,825650
>>> run 2/5
jhash,2,9934512B440806A9DEFA77A,15439,7,4.00,8.95,8.91,28.66,20.82,43977446408,77903640965,1.77,67.30,820603
>>> run 3/5
jhash,3,9934512B440806A9DEFA77A,15439,7,4.00,9.04,8.99,28.52,20.49,44043835232,78848901570,1.79,66.76,821098
>>> run 4/5
jhash,4,9934512B440806A9DEFA77A,15439,7,4.00,8.86,8.82,28.08,20.33,44017467248,78708979371,1.79,66.78,822833
>>> run 5/5
jhash,5,9934512B440806A9DEFA77A,15439,7,4.00,9.3,9.26,28.07,19.88,44029636616,78229679995,1.78,66.79,825202
>>> done: jhash x 5 已寫入 ovs_datapath_bench/results/v3b/dv3b_formal_perf.csv
>>> 產 summary: python3 ovs_datapath_bench/scripts/summarize_dv3b.py
backend   |  n |    ohash_ch% |   masked_ch% | hit/pkt |  cyc/pkt | hash cyc/pkt | h/l ratio |  %soft
-----------------------------------------------------------------------------------------------------
jhash     | 10 |   8.72± 0.63 |  30.60± 3.97 |    4.01 |     5598 |          488 |     28.5% |   68.2

[OK] wrote ovs_datapath_bench/results/v3b/dv3b_formal_summary.csv
備註: sd=樣本標準差(n-1); cycles/packet 為 CPU0 全部工作(含 pktgen 產包)÷ 封包數;
      hash_cycles_per_packet = cycles/packet × ohash_children%; 視窗=10s。
iris@linux:~/projects/kernel-hash$ cd ~/projects/kernel-hash
mv ovs_datapath_bench/results/v3b/dv3b_formal_perf.csv \
   ovs_datapath_bench/results/v3b/dv3b_pilot_jhash_20260612.csv
sudo -v
./ovs_datapath_bench/scripts/run_dv3b_benchmark.sh jhash 10   # ~8 分鐘,人離開機器
python3 ovs_datapath_bench/scripts/summarize_dv3b.py
>>> backend=jhash  loaded srcversion=9934512B440806A9DEFA77A  (core=0, N=10)
    (無 out-of-line hash import → jhash inline)
>>> warm-up 15s(建 flows,不記錄)
    warm-up 後 flows=15439
>>> run 1/10
jhash,1,9934512B440806A9DEFA77A,15439,7,4.00,9.55,9.5,26.67,18.31,44400096036,81095509867,1.83,66.67,850319
>>> run 2/10
jhash,2,9934512B440806A9DEFA77A,15439,7,4.00,9.4,9.34,27.43,19.08,44462517448,80871664377,1.82,66.43,848258
>>> run 3/10
jhash,3,9934512B440806A9DEFA77A,15439,7,4.00,9.43,9.39,27.55,19.28,44487813595,81411043033,1.83,66.05,851314
>>> run 4/10
jhash,4,9934512B440806A9DEFA77A,15439,7,4.00,9.43,9.4,26.96,18.7,44459359912,81215185621,1.83,66.43,853871
>>> run 5/10
jhash,5,9934512B440806A9DEFA77A,15439,7,4.00,9.58,9.53,26.48,18.01,44541369545,80938240877,1.82,66.06,852719
>>> run 6/10
jhash,6,9934512B440806A9DEFA77A,15439,7,4.00,9.71,9.67,27.02,18.48,44460800425,80801864970,1.82,66.38,849422
>>> run 7/10
jhash,7,9934512B440806A9DEFA77A,15439,7,4.00,9.57,9.53,27.19,18.82,44566870291,81932974821,1.84,65.84,853533
>>> run 8/10
jhash,8,9934512B440806A9DEFA77A,15439,7,4.00,9.71,9.68,26.84,18.28,44568296639,80976052682,1.82,66.43,854822
>>> run 9/10
jhash,9,9934512B440806A9DEFA77A,15439,7,4.00,9.39,9.35,27.28,19.08,44552659854,80997762688,1.82,66.33,852361
>>> run 10/10
jhash,10,9934512B440806A9DEFA77A,15439,7,4.00,9.27,9.22,27.1,18.94,44592780664,80446933677,1.80,66.52,847797
>>> done: jhash x 10 已寫入 ovs_datapath_bench/results/v3b/dv3b_formal_perf.csv
>>> 產 summary: python3 ovs_datapath_bench/scripts/summarize_dv3b.py
backend   |  n |    ohash_ch% |   masked_ch% | hit/pkt |  cyc/pkt | hash cyc/pkt | h/l ratio |  %soft
-----------------------------------------------------------------------------------------------------
jhash     | 10 |   9.50± 0.14 |  27.05± 0.33 |    4.00 |     5228 |          497 |     35.1% |   66.3

[OK] wrote ovs_datapath_bench/results/v3b/dv3b_formal_summary.csv
備註: sd=樣本標準差(n-1); cycles/packet 為 CPU0 全部工作(含 pktgen 產包)÷ 封包數;
      hash_cycles_per_packet = cycles/packet × ohash_children%; 視窗=10s。


平均時間：  CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
平均時間：    0    0.00    0.00   32.33    0.00    0.00   63.79    0.00    0.00    0.00    3.88
平均時間：    6    0.35    0.00    0.22    0.20    0.00    0.01    0.00    0.00    0.00   99.22