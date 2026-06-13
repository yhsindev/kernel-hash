#!/usr/bin/env bash
#
# cleanup_ovn_testbed.sh — 移除 setup_ovn_testbed.sh 建立的 OVN testbed
#
# 移除邏輯拓樸(ls0/ls1/lr0)、br-int 上的 ovn1/2/3 port、netns ns_a/b/c。
# br-int 與 chassis 由 ovn-controller 管理,保留不動。
#
set -uo pipefail

sudo ovn-nbctl --if-exists ls-del ls0
sudo ovn-nbctl --if-exists ls-del ls1
sudo ovn-nbctl --if-exists lr-del lr0

for p in ovn1 ovn2 ovn3; do
	sudo ovs-vsctl --if-exists del-port br-int "$p"
done

for n in ns_a ns_b ns_c; do
	sudo ip netns del "$n" 2>/dev/null || true
done

echo "[OK] OVN testbed cleaned (br-int 與 chassis 保留,由 ovn-controller 管理)"
