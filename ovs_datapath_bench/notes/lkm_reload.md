# OVS kernel module reload runbook

## 目標

本 runbook 用來驗證：自己從 HWE 6.8 source build 出來的 unmodified `openvswitch.ko`，是否可以被目前 running kernel 載入，並讓 OVS testbed 正常運作。

本階段不修改 `flow_hash()`，不做 hash function 比較，也不覆蓋系統原版 module。

---

## 0. 前置條件

確認新 build 的 module `vermagic` 已對齊目前 kernel：

```bash
uname -r

cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0
modinfo net/openvswitch/openvswitch.ko | grep -E "filename|name|vermagic|depends"
```

預期重點：

```text
uname -r = 6.8.0-124-generic
vermagic = 6.8.0-124-generic SMP preempt mod_unload modversions
```

若 `vermagic` 不一致，不要繼續 reload。

---

## 1. 記錄目前狀態

```bash
cd ~/projects/kernel-hash

uname -r
modinfo openvswitch | grep -E "filename|vermagic|srcversion"
lsmod | grep openvswitch || true

sudo ovs-vsctl show || true
sudo ovs-dpctl show || true
systemctl list-units | grep -E "openvswitch|ovs" || true
```

目的：先記錄系統目前使用的原版 `openvswitch.ko`、OVS service 狀態，以及 datapath 狀態，方便 reload 後比對。

結果
```bash
185749a2-d41a-4c13-a561-ec8904d228e9
    Bridge br0
        Port br0
            Interface br0
                type: internal
        Port veth2-br
            Interface veth2-br
                error: "could not open network device veth2-br (No such device)"
        Port veth1-br
            Interface veth1-br
                error: "could not open network device veth1-br (No such device)"
    ovs_version: "2.17.9"
system@ovs-system:
  lookups: hit:0 missed:0 lost:0
  flows: 0
  masks: hit:0 total:0 hit/pkt:0.00
  caches:
    masks-cache: size:256
  port 0: ovs-system (internal)
  port 1: br0 (internal)
  sys-devices-virtual-net-ovs\x2dsystem.device                                                            loaded active plugged   /sys/devices/virtual/net/ovs-system
  sys-subsystem-net-devices-ovs\x2dsystem.device                                                          loaded active plugged   /sys/subsystem/net/devices/ovs-system
  openvswitch-switch.service                                                                              loaded active exited    Open vSwitch
  ovs-record-hostname.service                                                                             loaded active exited    Open vSwitch Record Hostname
  ovs-vswitchd.service                                                                                    loaded active running   Open vSwitch Forwarding Unit
  ovsdb-server.service                                                                                    loaded active running   Open vSwitch Database Unit
```

---

## 2. 備份系統原版 module

```bash
mkdir -p ~/projects/kernel-hash/kernel_work/module_backup

sudo cp "$(modinfo -n openvswitch)" \
  ~/projects/kernel-hash/kernel_work/module_backup/openvswitch.ko.system.$(date +%Y%m%d_%H%M%S)
```

目的：雖然本流程不覆蓋 `/lib/modules/.../openvswitch.ko`，但仍先備份原版 module，降低操作風險。

---

## 3. 清除目前 OVS testbed

```bash
cd ~/projects/kernel-hash
sudo ./ovs_datapath_bench/scripts/cleanup_ovs_testbed.sh || true
```

目的：先移除自己建立的 `br0`、veth、network namespaces，降低 `openvswitch` module 被 datapath 或 interface reference 卡住的機率。

注意：刪除 `br0` 會使該 bridge 上透過 `ovs-ofctl add-flow` 安裝的 OpenFlow rules 失效。這些 rules 不應視為 OVSDB 中的長期設定；下一階段要重跑 D-v2-mid 時，需要重新執行 `install_irregular_udp_rules.sh` 安裝 rules。

---

## 4. 停止 OVS userspace

從這一步開始會動到 kernel module，**另開一個 terminal 全程跑 kernel log 即時監看**：

```bash
sudo dmesg -w
```

目的：`insmod` / `modprobe` 的真相幾乎都在 kernel log，不在你下指令的 terminal。unknown symbol 的確切 symbol 名、version mismatch 細節、甚至 oops stack 都只會出現在 dmesg。`-w`（follow mode，類似 `tail -f`）讓你即時看到，不用事後 `dmesg | tail` 撈。整個 reload 過程保持這個 terminal 開著。

---

先停 forwarding daemon：

```bash
sudo systemctl stop ovs-vswitchd.service
```

再停 wrapper service：

```bash
sudo systemctl stop openvswitch-switch.service
```

先停 `ovs-vswitchd.service` 與 `openvswitch-switch.service`。`ovsdb-server.service` 可先保留，因為它主要保存 OVSDB 狀態，不一定會直接占用 kernel datapath。若後續 `modprobe -r openvswitch` 失敗，再停止 `ovsdb-server.service`。

檢查狀態：

```bash
systemctl list-units | grep -E "openvswitch|ovs" || true
ps aux | grep -E "ovs-vswitchd" | grep -v grep || true
ps aux | grep -E "ovsdb-server" | grep -v grep || true
```

若保留 ovsdb-server，看到 ovsdb-server process 是可接受的；但不應看到 ovs-vswitchd。

目的：`ovs-vswitchd` 會和 kernel datapath 互動，是最可能讓 `openvswitch.ko` refcount 無法歸零的 process。

---

## 5. 卸載舊的 openvswitch module

先檢查目前 refcount：

```bash
lsmod | grep openvswitch || true
```

卸載：

```bash
sudo modprobe -r openvswitch
```

確認已卸載：

```bash
lsmod | grep openvswitch || true
```

預期結果：沒有任何 `openvswitch` 輸出。

若 `modprobe -r openvswitch` 失敗，不要強制操作；先記錄錯誤訊息，並檢查是否仍有 datapath、bridge 或 process 使用 OVS。

最常見的卡住原因是：bridge 都刪了，但 datapath `ovs-system` 還在（停 ovs-vswitchd 後 datapath 不一定自動消失），refcount 因此無法歸零。備案：

```bash
sudo ovs-dpctl show                      # 看還有沒有殘留 datapath
sudo ovs-dpctl del-dp system@ovs-system  # 手動拆掉 datapath
lsmod | grep openvswitch                 # 確認 Used by 歸 0
sudo modprobe -r openvswitch             # 再卸一次
```

---

## 6. 載入自己 build 的 unmodified openvswitch.ko

```bash
cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0

sudo insmod net/openvswitch/openvswitch.ko
```

確認 module 已載入：

```bash
lsmod | grep openvswitch
sudo dmesg | tail -30
```

若出現 unknown symbol，先檢查 dependencies 是否存在：

```bash
modinfo net/openvswitch/openvswitch.ko | grep depends
lsmod | grep -E "nf_conntrack|nsh|nf_nat|nf_conncount|libcrc32c" || true
```

必要時先載入 dependencies：

```bash
sudo modprobe nsh
sudo modprobe nf_conncount
sudo modprobe nf_nat
sudo modprobe nf_conntrack
sudo modprobe libcrc32c

lsmod | grep -E "nsh|nf_conncount|nf_nat|nf_conntrack|libcrc32c"

sudo insmod net/openvswitch/openvswitch.ko
```

確認 kernel 載入的 module 來源（比對 srcversion）：

```bash
cat /sys/module/openvswitch/srcversion                       # kernel 現在載入的
modinfo net/openvswitch/openvswitch.ko | grep srcversion     # 你 build 的
```

說明：`srcversion` 是源碼的 MD5，實測 unmodified rebuild 的 srcversion 跟系統原版不同（E582... vs 0E03...）。

apt source linux-hwe-6.8 拿到的源碼 + 你的 build 環境，跟 Ubuntu 官方打包那顆 binary 的源碼/patch/環境不完全一致 → modpost 算出的 MD5 不同。含意：srcversion 比對「現在這一步就已經能區分自製 vs 系統版」，比我預期的更早有用——不用等改 flow_hash()。

---

## 7. 重新啟動 OVS userspace

```bash
sudo systemctl start ovsdb-server.service
sudo systemctl start ovs-vswitchd.service
sudo systemctl start openvswitch-switch.service
```

檢查狀態：

```bash
systemctl status ovsdb-server.service --no-pager
systemctl status ovs-vswitchd.service --no-pager
systemctl status openvswitch-switch.service --no-pager
```

確認 OVS 可以回應：

```bash
sudo ovs-vsctl show
sudo ovs-dpctl show || true
```

---

## 8. 重建 testbed 並做 sanity test

```bash
cd ~/projects/kernel-hash

sudo ./ovs_datapath_bench/scripts/setup_ovs_testbed.sh

sudo ip netns exec ns1 ping -c 3 10.0.0.2

sudo ovs-vsctl show
sudo ovs-dpctl show
```

成功標準：

```text
1. openvswitch module 已載入。
2. ovs-vswitchd / ovsdb-server 正常 running。
3. setup_ovs_testbed.sh 可重新建立 br0 / veth / ns1 / ns2。
4. ns1 可以 ping 到 ns2。
5. ovs-dpctl show 可正常顯示 datapath。
```

---

## 9. 回復系統原版 module

若自己 build 的 module 載入失敗，或 OVS service 無法正常運作，使用以下方式回到系統原版 module：

```bash
sudo systemctl stop ovs-vswitchd.service
sudo systemctl stop openvswitch-switch.service

sudo modprobe -r openvswitch || true

sudo modprobe openvswitch

sudo systemctl start ovsdb-server.service
sudo systemctl start ovs-vswitchd.service
sudo systemctl start openvswitch-switch.service
```

重新建立 testbed：

```bash
cd ~/projects/kernel-hash

sudo ./ovs_datapath_bench/scripts/cleanup_ovs_testbed.sh || true
sudo ./ovs_datapath_bench/scripts/setup_ovs_testbed.sh
sudo ip netns exec ns1 ping -c 3 10.0.0.2
```

---

## 適用範圍

此 runbook 原本用於 unmodified `openvswitch.ko` reload sanity。  
若已加入 `flow_hash()` skeleton patch，也可沿用同一套 reload 流程；差別只在於前置條件需重新確認：

- `git diff` 或 commit 確認本次修改範圍只在 `flow_table.c`
- 重新 build `openvswitch.ko`
- `vermagic` 仍需對齊 `uname -r`
- reload 後先跑 ping sanity，再跑 D-v2-mid sanity

## 本階段不做的事
Unmodified reload 階段：
- 不修改 flow_hash()
- 不跑 D-v2-mid benchmark

Skeleton reload 階段：
- 可加入 flow_hash() selection skeleton
- 仍不實作 hsiphash / siphash
- D-v2-mid 只做 sanity，不做效能解讀

## 2026-06-05 verified result

- Self-built unmodified `openvswitch.ko` reload 成功。
- OVS userspace services restart 成功。
- `setup_ovs_testbed.sh` 成功重建 `br0 / veth1-br / veth2-br`。
- `ns1 -> ns2` ping 通，0% packet loss。
- 加入 `flow_hash()` selection skeleton 後，modified `openvswitch.ko` reload 成功。
- D-v2-mid sanity 成功：observed flows 約 `9752–9754`，pktgen `errors: 0`。