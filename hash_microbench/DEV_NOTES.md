# hash_microbench — Dev Notes

對應計畫：`C:\Users\itlab\.claude\plans\linux-foamy-toucan.md`
專案位置：`D:\kernel-hash\hash_microbench\`

## 檔案

| 檔案 | 用途 |
|------|------|
| `Makefile` | out-of-tree Kbuild stub |
| `hash_microbench.c` | 模組本體：載入時跑 `iterations` 次 hash，用 `get_cycles()` 量 cycles，印到 `dmesg` |
| `run_all.sh` | 5 × 3 × 5 = 75 次 `insmod`/`rmmod` 迴圈，外加 `perf stat` 抓 HW counter |
| `parse_results.py` | 合併 in-kernel cycles + 外部 perf，產 summary 表 + 4 張 PNG |
| `.gitignore` | 排除 build artifacts |

## 一次性傳檔到 Linux box

從 Windows 開 PowerShell（或 git bash）：
```powershell
scp -r D:\kernel-hash\hash_microbench user@lab-box:~/
ssh user@lab-box
```

或者用 git：
```powershell
cd D:\kernel-hash
git init; git add hash_microbench; git commit -m "exp1 v1"
# push 到任何 remote，然後 lab box 上 git clone
```

## Linux box 上的步驟

### 1. 環境檢查
```sh
uname -r
zcat /proc/config.gz 2>/dev/null \
    | grep -E '^CONFIG_(X86_TSC|PERF_EVENTS|HW_PERF_EVENTS|MODULES|MODULE_UNLOAD)=' \
    || grep -E '^CONFIG_(X86_TSC|PERF_EVENTS|HW_PERF_EVENTS|MODULES|MODULE_UNLOAD)=' \
       /boot/config-$(uname -r)
dpkg -l | grep -q linux-headers-$(uname -r) \
    || sudo apt install -y linux-headers-$(uname -r)
which perf || sudo apt install -y linux-tools-$(uname -r) linux-tools-common
python3 -c "import pandas, matplotlib" || sudo apt install -y python3-pandas python3-matplotlib
```

### 2. Build
```sh
cd ~/hash_microbench
make
ls -l hash_microbench.ko
modinfo hash_microbench.ko | head -n 15      # should show MODULE_LICENSE("GPL")
```

### 3. Smoke test — single load
```sh
sudo dmesg -C
sudo insmod ./hash_microbench.ko hash_type=0 input_len=64 iterations=1000000
sudo dmesg | tail
sudo rmmod hash_microbench
```

預期 `dmesg` 輸出（數字會浮動）：
```
hash_microbench: hash=jhash2 input_len=64 iterations=1000000 total_cycles=35421080 cycles_per_hash=35 checksum=0xabcdef01
HMB,jhash2,64,1000000,35421080,35,0xabcdef01
hash_microbench: unloaded
```

Sanity check 範圍（@ 3 GHz）：
- `jhash2`  64 B：30 – 60 cyc / hash
- `hsiphash` 64 B：80 – 150 cyc / hash
- `siphash` 64 B：120 – 250 cyc / hash

差太多（10× 以上）代表 hash 被 inline 量到 0，或 `get_cycles()` 在 VM 上不穩。

### 4. 全部跑完
```sh
chmod +x run_all.sh
sudo ./run_all.sh
```

預估耗時：~5 分鐘。輸出在 `results/`：
- `dmesg.csv`  — in-kernel cycles 每次 trial 一行
- `perf.csv`   — 外部 perf HW counter 每次 trial 一行
- `perf_raw/`  — 每次 trial 的 raw perf output（debug 用）

可調環境變數：
```sh
sudo REPEATS=3 ITER=5000000 ./run_all.sh
```

### 5. 整理 + 圖
```sh
python3 parse_results.py
ls results/
```

會產出：
- `summary.csv` / `summary.md` — 三 hash × 五 size 的 median table
- `fig_cycles_vs_size.png` — 主圖（HackMD 用這張）
- `fig_ins_per_hash_64.png` / `fig_brmiss_per_hash_64.png` / `fig_cmiss_per_hash_64.png` — 64 B 切片

把 `summary.md` 內容貼進 HackMD 第一檢核點的表格；`fig_cycles_vs_size.png` 是文末那張圖。

## 常見錯誤對照表

| 徵狀 | 原因 | 修法 |
|------|------|------|
| `make: *** No rule to make target 'modules'` | KDIR 或 headers 沒裝 | `sudo apt install linux-headers-$(uname -r)` |
| `Makefile:NN: *** missing separator. Stop.` | 編輯器把 TAB 換成空格 | 用 `cat -A Makefile` 確認行首是 `^I`（TAB）不是空格 |
| `insmod: ERROR: could not insert module: Unknown symbol` | 沒寫 `MODULE_LICENSE("GPL")` 或寫成 "GPL v2" | C 檔末尾必須是 `MODULE_LICENSE("GPL");` |
| `insmod: ERROR: Operation not permitted` | Secure Boot 阻擋未簽章模組 | BIOS 關 Secure Boot，或 enroll MOK 簽章模組 |
| `cycles_per_hash=0` 或 `=1` | 編譯器把 hash 整段 inline + DCE | 確認 `do_jhash2` 有 `noinline`；`objdump -d hash_microbench.ko \| grep do_jhash2` 應該看到 `call` |
| 連跑兩次 `cycles_per_hash` 差 > 5% | CPU 頻率沒鎖、turbo 在跳、SMT sibling 在搶 | `sudo cpupower frequency-set -g performance`；BIOS 關 turbo；`taskset -c <isol_cpu>` |
| `perf stat: <not supported>` | hypervisor 沒透傳 HW counter | VM 改 host-passthrough；fallback：先看 in-kernel cycles，HW counter 之後再補 |
| `dmesg` 看不到 `HMB,` 行 | `dmesg -C` 之後 `insmod` 失敗了 | `dmesg | tail`，找 OOPS / EINVAL 訊息 |

## 設計上的取捨

1. **單一 .c 檔**：照你筆記的 V1 結構，沒拆 `hash_bench_perf.c`。HW counter 走外部 `perf stat` 而不是 in-kernel `perf_event_create_kernel_counter` — 簡單、不會踩 KVM 透傳問題。代價：perf 是系統範圍量測，hash loop 必須夠長到 dominate，這就是為什麼 `iterations` 預設 10M。

2. **SipHash XOR-fold**：照你筆記 `(u32)h ^ (u32)(h >> 32)`，這層成本算進計時。否則 SipHash 多出來的 32-bit output bandwidth 不能跟 jhash2/hsiphash 公平比。

3. **`hash_type=0` jhash2 用 seed=0**：和 `net/openvswitch/flow_table.c` 的 `flow_hash()` 一致，後續 Exp 3 攻擊面分析時這個假設才連得起來。

4. **單次 timing window 涵蓋整個 10M loop**（不是每個 iter 一次 `get_cycles()`）：`get_cycles()` 自己有 ~30 cyc 成本，攤到 10M iter 上趨近 0；中間穿插 `get_cycles()` 反而會搞亂量測。換成「總 cycles ÷ iterations」是 V1 最乾淨的做法。

5. **沒實作 KUnit**：你筆記 V2 才需要。V1 用 module 比較好控變因。

## 之後幾天的計畫摘要

- **Day 2 (現在)**：跑完 `run_all.sh`，貼 summary 表 + 圖到 HackMD
- **Day 3-5**：寫分析報告（cycles / byte 線性回歸、HashDoS 鋪陳）
- **Week 2 起**：Exp 3 (bucket distribution) 跟 Exp 2 (datapath benchmark)
