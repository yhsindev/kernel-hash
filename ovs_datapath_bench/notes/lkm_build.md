# OVS kernel module rebuild notes

## 目標

本文件紀錄如何在 Ubuntu 22.04 HWE kernel 環境下，重新編譯 Linux kernel 內建的 Open vSwitch kernel datapath module。

目前實驗目標是修改：

```text
net/openvswitch/flow_table.c::flow_hash()
```

因此第一步不是直接修改程式碼，而是先確認原始未修改版本的 `openvswitch.ko` 能否重新編譯，並且產生與目前 running kernel 相容的 module。

---

## 1. 確認目前 kernel 與 OVS module 狀態

先確認目前正在執行的 kernel：

```bash
uname -r
```

範例輸出：

```text
6.8.0-124-generic
```

確認 `openvswitch` 是否是 kernel module：

```bash
lsmod | grep openvswitch
```

確認目前系統使用的 `openvswitch.ko` 位置與版本資訊：

```bash
modinfo openvswitch | head -40
modinfo openvswitch | grep filename
```

範例重點：

```text
filename: /lib/modules/6.8.0-124-generic/kernel/net/openvswitch/openvswitch.ko
vermagic: 6.8.0-124-generic SMP preempt mod_unload modversions
```

判斷原則：

* `openvswitch` 有出現在 `lsmod`，表示目前 OVS kernel datapath 是以 module 方式載入。
* `vermagic` 必須和 `uname -r` 對齊，後續自己 build 出來的 `.ko` 也必須符合這個版本字串。

---

## 2. 不要直接使用 `linux-source`

在 Ubuntu 22.04 上，直接執行：

```bash
sudo apt install linux-source
```

可能只會安裝 GA kernel 的 source，例如：

```text
linux-source-5.15.0
```

但如果目前 running kernel 是：

```text
6.8.0-124-generic
```

那 `linux-source-5.15.0` 不適合拿來 build 目前 kernel 的 `openvswitch.ko`。

判斷原則：

```text
source version 必須對齊目前 running kernel 的 kernel family。
```

若系統使用 HWE 6.8 kernel，應取得 `linux-hwe-6.8` source，而不是 `linux-source-5.15.0`。

---

## 3. 開啟 deb-src repository

若執行：

```bash
apt source linux-hwe-6.8
```

出現：

```text
E: You must put some 'deb-src' URIs in your sources.list
```

代表系統沒有開啟 source package repository。

先備份 `/etc/apt/sources.list`：

```bash
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d_%H%M%S)
```

加入 Ubuntu source repository：

```bash
sudo tee -a /etc/apt/sources.list >/dev/null <<'EOF'

# Source repositories for apt source
deb-src http://tw.archive.ubuntu.com/ubuntu/ jammy main restricted universe multiverse
deb-src http://tw.archive.ubuntu.com/ubuntu/ jammy-updates main restricted universe multiverse
deb-src http://tw.archive.ubuntu.com/ubuntu/ jammy-backports main restricted universe multiverse
deb-src http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOF
```

更新 apt index：

```bash
sudo apt update
```

---

## 4. 取得 HWE 6.8 kernel source

建立工作目錄：

```bash
cd ~/projects/kernel-hash
mkdir -p kernel_work
cd kernel_work
```

抓取 HWE 6.8 source：

```bash
apt source linux-hwe-6.8
```

確認 source tree 是否存在：

```bash
ls
```

應看到類似：

```text
linux-hwe-6.8-6.8.0
```

確認 `flow_table.c` 是否存在：

```bash
find . -path "*net/openvswitch/flow_table.c"
```

範例結果：

```text
./linux-hwe-6.8-6.8.0/net/openvswitch/flow_table.c
```

確認 `flow_hash()` 位置：

```bash
grep -R -n "static u32 flow_hash" . | head
```

範例結果：

```text
./linux-hwe-6.8-6.8.0/net/openvswitch/flow_table.c:645:static u32 flow_hash(...)
```

---

## 5. 建立 git baseline

進入 source tree：

```bash
cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0
```

初始化 git，先只追蹤目標檔案：

```bash
git init
git add net/openvswitch/flow_table.c
git commit -m "Import original HWE 6.8 OVS flow_table.c"
```

確認 `flow_hash()` 原始內容：

```bash
grep -n "static u32 flow_hash" net/openvswitch/flow_table.c
sed -n '640,660p' net/openvswitch/flow_table.c
```

原始版本大致如下：

```c
static u32 flow_hash(const struct sw_flow_key *key,
		     const struct sw_flow_key_range *range)
{
	const u32 *hash_key = (const u32 *)((const u8 *)key + range->start);

	/* Make sure number of hash bytes are multiple of u32. */
	int hash_u32s = range_n_bytes(range) >> 2;

	return jhash2(hash_key, hash_u32s, 0);
}
```

---

## 6. 安裝 kernel build dependencies

若第一次執行 `make olddefconfig` 時出現：

```text
/bin/sh: 1: flex: not found
```

代表缺少 kernel build 工具。

安裝必要套件：

```bash
sudo apt install -y build-essential flex bison libssl-dev libelf-dev bc dwarves pahole
```

套件用途：

| 套件                   | 用途                                                |
| -------------------- | ------------------------------------------------- |
| `build-essential`    | 基本編譯工具，包含 gcc、g++、make                            |
| `flex`               | 產生 lexer，Kconfig 需要                               |
| `bison`              | 產生 parser，Kconfig 需要                              |
| `libssl-dev`         | kernel build / signing tools 可能需要 OpenSSL headers |
| `libelf-dev`         | objtool、BPF、module build 可能需要 ELF library         |
| `bc`                 | kernel scripts 可能使用的計算工具                          |
| `dwarves` / `pahole` | BTF / debug type information 相關工具                 |

---

## 7. 使用目前 kernel config 準備 build tree

複製目前 running kernel 的 config：

```bash
cp /boot/config-$(uname -r) .config
```

例如目前 kernel 是 `6.8.0-124-generic`，實際等於：

```bash
cp /boot/config-6.8.0-124-generic .config
```

整理 config：

```bash
make olddefconfig
```

成功時會看到：

```text
# configuration written to .config
```

準備 kernel module build 需要的 generated headers 與工具：

```bash
make prepare
make modules_prepare
```

複製目前 kernel headers 中的 symbol version table：

```bash
cp /lib/modules/$(uname -r)/build/Module.symvers .
```

確認：

```bash
ls -lh Module.symvers
```

---

## 8. 注意：不要直接用 source root build 的產物載入

如果直接在 source tree 中執行：

```bash
make M=net/openvswitch modules -j$(nproc)
```

可能會成功產生：

```text
net/openvswitch/openvswitch.ko
```

但 `vermagic` 可能是：

```text
6.8.12+
```

檢查方式：

```bash
modinfo net/openvswitch/openvswitch.ko | grep -E "filename|name|vermagic|depends"
```

若看到：

```text
vermagic: 6.8.12+ SMP preempt mod_unload modversions
```

代表它不符合目前 running kernel：

```text
6.8.0-124-generic
```

這顆 module 不應該載入。

原因是 Ubuntu HWE source tree 底層可能是 upstream `6.8.12`，但 Ubuntu binary kernel package 的 release string 是 `6.8.0-124-generic`。Kernel module 載入時會檢查 `vermagic`，所以必須用目前 running kernel headers 當 build tree。

---

## 9. 正確做法：用 running kernel headers build OVS module

先清掉前一次在 source tree 中產生的 OVS build 產物：

```bash
cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0
make M=net/openvswitch clean
```

用目前 running kernel 的 build directory 編譯 OVS module：

```bash
make -C /lib/modules/$(uname -r)/build \
  M=$PWD/net/openvswitch \
  modules -j$(nproc)
```

這行的意思：

| 片段                                  | 意義                                    |
| ----------------------------------- | ------------------------------------- |
| `-C /lib/modules/$(uname -r)/build` | 使用目前 running kernel 的 build directory |
| `M=$PWD/net/openvswitch`            | 指定要編譯的 module source 目錄               |
| `modules`                           | 只編譯 kernel module                     |
| `-j$(nproc)`                        | 使用 CPU 核心數平行編譯                        |

成功時會看到：

```text
LD [M] .../net/openvswitch/openvswitch.ko
```

`Skipping BTF generation ... due to unavailability of vmlinux` 不是致命錯誤；它只表示沒有產生 BTF debug metadata，但 `.ko` 仍然有產生。

---

## 10. 檢查 vermagic

編譯完成後，檢查新產物：

```bash
modinfo net/openvswitch/openvswitch.ko | grep -E "filename|name|vermagic|depends"
```

成功範例：

```text
filename:       /home/iris/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0/net/openvswitch/openvswitch.ko
depends:        nf_conntrack,nsh,nf_nat,nf_conncount,libcrc32c
name:           openvswitch
vermagic:       6.8.0-124-generic SMP preempt mod_unload modversions
```

判斷原則：

```text
vermagic 必須等於 uname -r 對應的 kernel release。
```

若 `uname -r` 是：

```text
6.8.0-124-generic
```

則新 build 的 `openvswitch.ko` 也必須是：

```text
6.8.0-124-generic SMP preempt mod_unload modversions
```

這一步成功後，才可以進入下一階段：備份原 module、停止 OVS、卸載舊 module、載入新 module。

---

## 目前狀態紀錄

目前已完成：

```text
- HWE 6.8 source 已取得
- flow_table.c 已定位
- git baseline 已建立
- build dependencies 已補齊
- unmodified openvswitch.ko 已成功 build
- 使用 running kernel headers build 後，vermagic 已對齊 6.8.0-124-generic
```

目前尚未做：

```text
- 尚未 reload 新 build 的 openvswitch.ko
- 尚未修改 flow_hash()
- 尚未加入 hash selection skeleton
- 尚未跑 D-v2-mid sanity after reload
```

下一步：

```text
備份目前系統 openvswitch.ko，停止 OVS，卸載舊 module，嘗試載入新 build 的 unmodified openvswitch.ko。
```

## reload Runbook
```text
# === 0. 記錄現狀，方便 reload 後比對 ===
sudo ovs-vsctl show                       # 記下 br0 結構
sudo ovs-ofctl dump-flows br0 | wc -l     # 記下 rule 數（你之前裝的 2001 或 10001）
modinfo openvswitch | grep filename       # 確認系統原版路徑，這是還原退路

# === 1. 備份系統原版 module（保險，雖然我們不覆蓋它）===
sudo cp /lib/modules/$(uname -r)/kernel/net/openvswitch/openvswitch.ko \
        ~/openvswitch.ko.orig-backup

# === 2. 停掉 OVS userspace ===
sudo systemctl stop openvswitch-switch
sudo systemctl stop ovs-vswitchd 2>/dev/null || true   # 視發行版 service 名

# === 3. 確認 refcount 歸 0 ===
lsmod | grep openvswitch
#   Used by 應該變成 0。如果還是 >0，表示 datapath 還在：
#   sudo ovs-dpctl del-dp system@ovs-system   # 手動拆 datapath
#   再重新 lsmod 確認

# === 4. 卸載舊 module ===
sudo rmmod openvswitch
lsmod | grep openvswitch     # 應該完全消失（無輸出）

# === 5. 載入你 build 的 unmodified 版本（用絕對路徑，不動系統檔）===
cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0
sudo insmod net/openvswitch/openvswitch.ko
#   若報 "unknown symbol"：是依賴 module（nsh/nf_conntrack...）沒載。
#   rmmod 只卸了 openvswitch，依賴應該還在，但若被連帶卸掉就：
#   sudo modprobe nsh nf_conntrack nf_nat nf_conncount  然後重 insmod

# === 6. 確認載入的是你的版本 ===
lsmod | grep openvswitch
sudo cat /sys/module/openvswitch/srcversion 2>/dev/null
modinfo net/openvswitch/openvswitch.ko | grep srcversion
#   兩個 srcversion 應一致，證明 kernel 載入的是你 build 的那顆

# === 7. 重啟 OVS userspace ===
sudo systemctl start openvswitch-switch

# === 8. 確認 datapath 回來 ===
sudo ovs-vsctl show          # br0 應該回來
sudo ovs-ofctl dump-flows br0 | wc -l   # 你的 rule 應該還在（OVS DB 持久化）
```