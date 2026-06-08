# OVS datapath reload 不穩定:根因、修正、reboot 重置流程

2026-06-08 記錄。多次 reload 自製 `openvswitch.ko` 後,datapath 進入壞狀態,
benchmark 數據全失真。本筆記記根因 + 修法 + reboot 後接續流程。

---

## 症狀

- `ovs-dpctl show` → `flows: 0`(megaflow 一條都裝不進),`lost` 衝到億級。
- `ovs-vswitchd.log` → 反覆 `failed to put[modify] (No such file or directory)`,
  `poll_loop(handler1) ... 99% CPU usage`。
- perf:`masked_flow_lookup` / `ovs_flow_hash_backend` 時有時無、或整批 0
  (因為沒有 megaflow,fast-path lookup 根本不被呼叫)。
- benchmark CSV 出現 `0,0,0,0`(該 run flows 沒建起來)。

判斷:只要 `flows: 0` 且 log 有 `failed to put ... No such file or directory`,
就是這個問題,當下所有 perf 數字作廢。

---

## 根因

1. 反覆 `modprobe -r openvswitch` / `insmod` 對同一個 running 系統。
2. `reload_ovs_module.sh` 原本只停 `ovs-vswitchd` + `openvswitch-switch`,
   **保留 `ovsdb-server` 沒重啟**。
3. 每次 module reload → datapath `ovs-system` 整個重建、port 重編號。
4. ovsdb 保留著跨多次 reload 的舊 bridge/port 狀態 → vswitchd 重啟後從舊 ovsdb
   讀狀態,卻面對全新 datapath → port 對不上 → `put ENOENT` → megaflow 裝不進
   → `flows: 0`。
5. 多次累積後,即使 `restart` OVS 也只能暫時恢復,跑一陣子又退化。

---

## 暫時修(撐一下,非根治)

完整 restart 三個 service(關鍵是**連 ovsdb 一起**):

```bash
sudo ./ovs_datapath_bench/scripts/cleanup_ovs_testbed.sh 2>/dev/null || true
sudo systemctl restart ovsdb-server.service
sudo systemctl restart ovs-vswitchd.service
sudo systemctl restart openvswitch-switch.service
sudo ./ovs_datapath_bench/scripts/setup_ovs_testbed.sh
sudo SRCMAX=20199 DSTMAX=9049 ./ovs_datapath_bench/scripts/install_irregular_udp_rules.sh
```

→ flows 暫時回 ~9760,但反覆 reload 會再壞。

---

## reload 腳本必要修正

`reload_ovs_module.sh` Step 2 補上停 ovsdb(Step 6 已有 start ovsdb):

```bash
# === 2. 停 OVS userspace(連 ovsdb 一起停,避免 datapath 重建後狀態不同步)===
sudo systemctl stop ovs-vswitchd.service || true
sudo systemctl stop openvswitch-switch.service || true
sudo systemctl stop ovsdb-server.service || true     # ← 新增
```

每次 reload 變成完整重啟 OVS,vswitchd 從乾淨 ovsdb 重新 sync 新 datapath。
**ovsdb restart 不丟 rules/bridge 配置**(持久化在 `/etc/openvswitch/conf.db`)。

---

## 徹底重置:reboot

reboot 只清掉 running kernel 記憶體裡的壞 datapath 狀態。**硬碟上的東西全保留**:

| 保留 | 說明 |
|---|---|
| `kernel_work/`(source tree) | 不用重 apt source |
| 自製 `openvswitch.ko` | 不用重 build |
| `flow_table.c` patch(noinline wrapper + 三 backend) | 不用重改 |
| notes / CSV / experiment_log | 在 repo |

reboot 後系統會自動載入**系統原版** openvswitch,所以要重新 reload 自製 .ko。

---

## reboot 後接續流程

```bash
# 1. CPU 頻率回 performance(reboot 會回預設)
sudo cpupower frequency-set -g performance

# 2. 先確認「系統原版」OVS 乾淨環境正常(A/B 診斷:排除是 patch 本身的問題)
cd ~/projects/kernel-hash
sudo ./ovs_datapath_bench/scripts/setup_ovs_testbed.sh
sudo SRCMAX=20199 DSTMAX=9049 ./ovs_datapath_bench/scripts/install_irregular_udp_rules.sh
sudo DURATION=8 SRCMIN=20000 SRCMAX=20199 DSTMIN=9000 DSTMAX=9049 \
  ./ovs_datapath_bench/scripts/pktgen_microflows.sh >/dev/null 2>&1
sudo ovs-dpctl show | grep flows:        # 系統原版應穩定 ~9760

# 3. 改好 reload 腳本(加 stop ovsdb)後,reload 自製 .ko
cd ~/projects/kernel-hash/kernel_work/linux-hwe-6.8-6.8.0
SV=$(modinfo net/openvswitch/openvswitch.ko | awk '/^srcversion:/{print $2}')
cd ~/projects/kernel-hash
./ovs_datapath_bench/scripts/reload_ovs_module.sh "$SV"
sudo SRCMAX=20199 DSTMAX=9049 ./ovs_datapath_bench/scripts/install_irregular_udp_rules.sh
sudo DURATION=8 ... pktgen >/dev/null 2>&1; sudo ovs-dpctl show | grep flows:   # 自製也應 ~9760
```

flows 穩定後才開始 benchmark。

---

## 預防原則(避免再壞)

1. **每個 backend 只 reload 一次** → 跑完 N 次 → 才切下一個。**絕不反覆 reload 同一 backend**。
2. reload 一定用「含 stop ovsdb」的完整重啟版腳本。
3. benchmark 正式 run **不要 del-flows**:warm-up 建好 flows 一次,正式 run 直接灌、
   命中既有 flows(純 fast-path),避免反覆 install storm 把 vswitchd 打爆。
4. 每個 run 記 `flows` 數;若某 run flows 掉到 0/異常,該 run 作廢。
5. 每序列第一個正式 run 視為 warm-up 丟棄(install/系統未穩),統計從 run2 起。

---

## 量測方法現狀(已驗證可用,reboot 後沿用)

- backend 身分:`flow_table.c` define + `srcversion` + `nm -u`(別靠 perf call-tree)。
- noinline wrapper `ovs_flow_hash_backend` 已隔離 hash 成本:jhash 看其 **self%**
  (jhash2 inline),hsiphash/siphash 看其 **children%**(hash out-of-line)。
- perf 裡的 `__siphash_unaligned → __skb_get_hash` 是 kernel skb-hash,**與 backend 無關**,忽略。
- CPU 固定 performance、CSV append(`hash_backend_perf.csv`)、warm-up + run1 丟棄。
- 已知:D-v2-mid 的 hash 訊號 <1%,信噪比偏低;若不夠,下一步用「加長 key」放大(策略 A)。
