#!/usr/bin/env bash
set -euo pipefail

sudo ovs-vsctl --if-exists del-br br0

sudo ip netns del ns1 2>/dev/null || true
sudo ip netns del ns2 2>/dev/null || true

sudo ip link del veth1-br 2>/dev/null || true
sudo ip link del veth2-br 2>/dev/null || true

echo "[OK] OVS testbed cleaned"
