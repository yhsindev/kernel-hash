#!/usr/bin/env bash
#
# reload_ovs_module.sh — reload 當前 build 的 openvswitch.ko 並自動驗證
#
# Backend-agnostic:只負責把 kernel_work 內「當前 build 出的」openvswitch.ko
# 換上 running kernel,重啟 OVS userspace、重建 testbed、做 ping sanity。
# build 哪個 backend(jhash / hsiphash / siphash)是 build 步驟的事,本腳本不管。
#
# 用法(用一般使用者執行即可,內部各特權步驟自帶 sudo,sudo 會 cache 密碼):
#   ./reload_ovs_module.sh
#   ./reload_ovs_module.sh <EXPECT_SRCVERSION>
#
# 強烈建議帶上 EXPECT_SRCVERSION(從 `modinfo .../openvswitch.ko | grep srcversion`
# 取得):reload 後會比對 kernel 實際載入的 srcversion,不符就 abort——這能防止
# 「以為換好了、其實還是舊 module」的 backend 混淆。
#
# 例:
#   ./reload_ovs_module.sh 04C7DF5A2D0C2BD7092D02B   # 要求載入的必須是 siphash 那顆
#
set -uo pipefail   # 刻意不含 -e:reload 流程有「預期可能非零退出」的步驟(已停的 service 等)

# --- 路徑由腳本自身位置推導,不依賴當前工作目錄 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$BENCH_DIR")"
KERNEL_SRC="$REPO_DIR/kernel_work/linux-hwe-6.8-6.8.0"
KO="$KERNEL_SRC/net/openvswitch/openvswitch.ko"

EXPECT_SRCVERSION="${1:-}"
DEPS="nsh nf_conncount nf_nat nf_conntrack libcrc32c"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

# === 0. 前置:.ko 存在 + vermagic 對齊 running kernel(否則拒絕動 live module)===
step "0. 前置檢查"
[ -f "$KO" ] || die "找不到 $KO — 請先 build"
if ! modinfo "$KO" | grep -q "vermagic:.*$(uname -r)"; then
	modinfo "$KO" | grep vermagic >&2
	die "vermagic 不符 running kernel $(uname -r),拒絕 reload"
fi
echo "ko               : $KO"
echo "build srcversion : $(modinfo "$KO" | awk '/^srcversion:/{print $2}')"
[ -n "$EXPECT_SRCVERSION" ] && echo "expect srcversion: $EXPECT_SRCVERSION"

# === 1. 清除 testbed(釋放對 module 的 reference)===
step "1. cleanup testbed"
sudo "$SCRIPT_DIR/cleanup_ovs_testbed.sh" || true

# === 2. 停 OVS userspace(連 ovsdb 一起停,避免 datapath 重建後狀態不同步 → put ENOENT)===
step "2. stop OVS services"
sudo systemctl stop ovs-vswitchd.service || true
sudo systemctl stop openvswitch-switch.service || true
sudo systemctl stop ovsdb-server.service || true

# === 3. 卸載舊 module(失敗 → 拆殘留 datapath 再試)===
step "3. unload openvswitch"
if ! sudo modprobe -r openvswitch 2>/dev/null; then
	echo "modprobe -r 失敗,嘗試拆除殘留 datapath..." >&2
	sudo ovs-dpctl del-dp system@ovs-system 2>/dev/null || true
	sudo modprobe -r openvswitch || die "仍無法卸載 openvswitch(refcount>0?用 lsmod 檢查)"
fi
lsmod | grep -q "^openvswitch " && die "openvswitch 仍在記憶體,卸載未完成"
echo "openvswitch 已卸載"

# === 4. 預載依賴 + insmod 自製 .ko ===
step "4. load self-built openvswitch.ko"
for m in $DEPS; do sudo modprobe "$m" || die "modprobe $m 失敗"; done
sudo insmod "$KO" || die "insmod 失敗 — 查 'sudo dmesg | tail' 看 unknown symbol / version mismatch"

# === 5. 自動驗 srcversion(確認載入的就是剛 build 的那顆)===
step "5. verify loaded srcversion"
LOADED="$(cat /sys/module/openvswitch/srcversion)"
echo "loaded srcversion: $LOADED"
if [ -n "$EXPECT_SRCVERSION" ] && [ "$LOADED" != "$EXPECT_SRCVERSION" ]; then
	die "srcversion 不符!期望 $EXPECT_SRCVERSION,實際 $LOADED — reload 沒生效或 build 錯 backend"
fi

# === 6. 重啟 OVS userspace ===
step "6. start OVS services"
sudo systemctl start ovsdb-server.service     || die "ovsdb-server 啟動失敗"
sudo systemctl start ovs-vswitchd.service      || die "ovs-vswitchd 啟動失敗"
sudo systemctl start openvswitch-switch.service || true

# === 7. 重建 testbed + ping sanity(失敗 loud)===
step "7. rebuild testbed + ping sanity"
sudo "$SCRIPT_DIR/setup_ovs_testbed.sh" || die "setup_ovs_testbed.sh 失敗"
if ! sudo ip netns exec ns1 ping -c 3 -W 2 10.0.0.2 >/dev/null 2>&1; then
	die "ns1 -> ns2 ping 失敗,datapath 異常"
fi

step "DONE"
echo "[OK] reload 完成"
echo "     srcversion = $LOADED"
echo "     nm -u hash symbol(自行確認 backend 身分):"
nm -u "$KO" 2>/dev/null | grep -iE "siphash|hsiphash" | sed 's/^/       /' || echo "       (無 siphash/hsiphash import → jhash inline)"
