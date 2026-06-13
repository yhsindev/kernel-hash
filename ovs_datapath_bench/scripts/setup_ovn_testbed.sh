#!/usr/bin/env bash
#
# setup_ovn_testbed.sh — 建立/重建單節點 OVN testbed(量測真實 megaflow flow_hash 輸入長度用)
#
# 冪等:可在 fresh 狀態,或 reload_ovs_module.sh 之後重跑。模組 reload 會清掉 datapath、
# 把 OVN internal port(ovn1/2/3)的 netdev 打回 root namespace;本腳本負責把它們
# 重新綁回各自 netns(rebind),並修掉 reload 後常見的 chassis/Encap 重複(OVNSB commit 迴圈)。
#
# 拓樸:
#   ls0 (10.1.0.0/24): lp1 -> ns_a 10.1.0.1   lp2 -> ns_b 10.1.0.2
#   ls1 (10.2.0.0/24): lp3 -> ns_c 10.2.0.3
#   lr0: 連 ls0(gw 10.1.0.254)與 ls1(gw 10.2.0.254)
#   STATEFUL=1(預設)時於 ls0 加 stateful ACL(allow-related → conntrack;post-ct key=160B)
#
# 用法(一般使用者執行即可,內部各步驟自帶 sudo,sudo 會 cache 密碼):
#   ./setup_ovn_testbed.sh             # 含 stateful ACL(conntrack)
#   STATEFUL=0 ./setup_ovn_testbed.sh  # 不含 ACL(純 stateless,只有 88B)
#
# 刻意不含 -e:多數步驟為「可能已存在」的冪等操作,個別非零退出屬預期。
set -uo pipefail

STATEFUL="${STATEFUL:-1}"
SB_SOCK="unix:/var/run/ovn/ovnsb_db.sock"

nb() { sudo ovn-nbctl "$@"; }
vs() { sudo ovs-vsctl "$@"; }

# === 1. 本機 OVS 設為 OVN chassis(external-ids 存在 conf.db,reload 後仍在;重設為 no-op)===
echo "=== 1. chassis 設定 ==="
vs set open . \
	external-ids:system-id=chassis-local \
	external-ids:ovn-remote="$SB_SOCK" \
	external-ids:ovn-encap-type=geneve \
	external-ids:ovn-encap-ip=127.0.0.1

# === 2. 清殘留 chassis 三表,讓 ovn-controller 以 system-id=chassis-local 乾淨重註冊 ===
#   reload 只重啟 ovs-vswitchd、不動 SB,舊列會與 controller 新插入的撞唯一性約束
#   (Chassis_Private.name / Encap(type,ip))→ OVNSB commit 迴圈、port 永遠認領不了。
#   三張表都要清:Chassis_Private、Chassis、Encap。
echo "=== 2. 清 chassis 三表並等重註冊 ==="
sudo ovn-sbctl --all destroy Chassis_Private 2>/dev/null || true
sudo ovn-sbctl --all destroy Chassis         2>/dev/null || true
sudo ovn-sbctl --all destroy Encap           2>/dev/null || true
for _ in $(seq 1 15); do
	sudo ovn-sbctl show 2>/dev/null | grep -q '^Chassis' && break
	sleep 1
done

# === 3. 邏輯拓樸(NB):2 switch + 1 router ===
echo "=== 3. 邏輯拓樸 ==="
nb --may-exist ls-add ls0
nb --may-exist ls-add ls1
nb --may-exist lr-add lr0

nb --may-exist lsp-add ls0 lp1; nb lsp-set-addresses lp1 "00:00:00:00:01:01 10.1.0.1"
nb --may-exist lsp-add ls0 lp2; nb lsp-set-addresses lp2 "00:00:00:00:01:02 10.1.0.2"
nb --may-exist lsp-add ls1 lp3; nb lsp-set-addresses lp3 "00:00:00:00:02:03 10.2.0.3"

nb --may-exist lrp-add lr0 lrp0 00:00:00:00:0a:01 10.1.0.254/24
nb --may-exist lrp-add lr0 lrp1 00:00:00:00:0a:02 10.2.0.254/24
nb --may-exist lsp-add ls0 ls0-lr0
nb lsp-set-type      ls0-lr0 router
nb lsp-set-addresses ls0-lr0 router
nb lsp-set-options   ls0-lr0 router-port=lrp0
nb --may-exist lsp-add ls1 ls1-lr0
nb lsp-set-type      ls1-lr0 router
nb lsp-set-addresses ls1-lr0 router
nb lsp-set-options   ls1-lr0 router-port=lrp1

# === 4. stateful ACL(可選)===
echo "=== 4. ACL (STATEFUL=$STATEFUL) ==="
nb acl-del ls0 2>/dev/null || true
if [ "$STATEFUL" = "1" ]; then
	nb acl-add ls0 from-lport 1001 'ip4 && tcp' allow-related
	nb acl-add ls0 to-lport   1000 'ip4 && tcp' allow-related
	nb acl-add ls0 from-lport 1002 'ip4'        allow
	nb acl-add ls0 to-lport   1003 'ip4'        allow
fi

# === 5. 落地 logical port 到 netns(冪等;涵蓋 fresh 與 reload 後 rebind)===
echo "=== 5. 綁定 port 到 netns ==="
realize_port() {  # port ns mac cidr gw lsp
	local port=$1 ns=$2 mac=$3 cidr=$4 gw=$5 lsp=$6

	sudo ip netns add "$ns" 2>/dev/null || true
	vs --may-exist add-port br-int "$port" -- set interface "$port" type=internal
	vs set interface "$port" external-ids:iface-id="$lsp"

	# netdev 若已在目標 netns(fresh setup)→ 就地設定;否則等它出現於 root ns 再搬(reload 後)
	if ! sudo ip netns exec "$ns" ip link show "$port" >/dev/null 2>&1; then
		for _ in $(seq 1 20); do
			sudo ip link show "$port" >/dev/null 2>&1 && break
			sleep 0.2
		done
		sudo ip link set "$port" netns "$ns" 2>/dev/null || true
	fi

	sudo ip netns exec "$ns" ip link set "$port" address "$mac" 2>/dev/null || true
	sudo ip netns exec "$ns" ip addr replace "$cidr" dev "$port"
	sudo ip netns exec "$ns" ip link set lo up
	sudo ip netns exec "$ns" ip link set "$port" up
	sudo ip netns exec "$ns" ip route replace default via "$gw"
}
realize_port ovn1 ns_a 00:00:00:00:01:01 10.1.0.1/24 10.1.0.254 lp1
realize_port ovn2 ns_b 00:00:00:00:01:02 10.1.0.2/24 10.1.0.254 lp2
realize_port ovn3 ns_c 00:00:00:00:02:03 10.2.0.3/24 10.2.0.254 lp3

# === 6. 等 ovn-controller 認領 port binding(以 ns_a -> ns_b ping 通為準)===
echo "=== 6. 等 binding 收斂(ping gate)==="
gate_ok=0
for _ in $(seq 1 20); do
	if sudo ip netns exec ns_a ping -c1 -W1 10.1.0.2 >/dev/null 2>&1; then
		gate_ok=1; break
	fi
	sleep 1
done
if [ "$gate_ok" != 1 ]; then
	echo "[WARN] ns_a -> ns_b 20s 內仍不通,binding 可能未收斂。" >&2
	echo "       檢查: sudo ovn-sbctl list port_binding | grep -E 'logical_port|chassis '" >&2
	echo "             sudo tail /var/log/ovn/ovn-controller.log" >&2
fi

echo "[OK] OVN testbed ready (STATEFUL=$STATEFUL, ping_gate=$gate_ok)"
echo "  驗證: sudo ip netns exec ns_a ping -c2 10.1.0.2   # 同網 L2"
echo "        sudo ip netns exec ns_a ping -c2 10.2.0.3   # 跨網 L3(經 lr0)"
echo "  量測: echo reset | sudo tee /sys/kernel/debug/ovs_hashlen >/dev/null"
echo "        <灌流量>; sudo cat /sys/kernel/debug/ovs_hashlen"
