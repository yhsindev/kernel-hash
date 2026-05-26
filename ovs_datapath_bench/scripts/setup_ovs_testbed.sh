#!/usr/bin/env bash
set -euo pipefail

sudo ip netns add ns1 2>/dev/null || true
sudo ip netns add ns2 2>/dev/null || true

sudo ip link add veth1 type veth peer name veth1-br 2>/dev/null || true
sudo ip link add veth2 type veth peer name veth2-br 2>/dev/null || true

sudo ip link set veth1 netns ns1 2>/dev/null || true
sudo ip link set veth2 netns ns2 2>/dev/null || true

sudo ip netns exec ns1 ip addr add 10.0.0.1/24 dev veth1 2>/dev/null || true
sudo ip netns exec ns2 ip addr add 10.0.0.2/24 dev veth2 2>/dev/null || true

sudo ip netns exec ns1 ip link set lo up
sudo ip netns exec ns2 ip link set lo up
sudo ip netns exec ns1 ip link set veth1 up
sudo ip netns exec ns2 ip link set veth2 up

sudo ip link set veth1-br up
sudo ip link set veth2-br up

sudo ovs-vsctl --may-exist add-br br0
sudo ovs-vsctl --may-exist add-port br0 veth1-br
sudo ovs-vsctl --may-exist add-port br0 veth2-br
sudo ip link set br0 up

echo "[OK] OVS testbed is ready"
echo "Test with: sudo ip netns exec ns1 ping -c 3 10.0.0.2"
