#!/usr/bin/env bash
#
# force_megaflow_rules.sh
#
# Problem this solves:
#   A default OVS bridge runs the NORMAL action (learning switch). The forwarding
#   decision only depends on L2 fields (in_port, eth_src/dst, eth_type), so OVS
#   installs *megaflows* that WILDCARD the L3/L4 fields. As a result, varying the
#   UDP source port produces packets that all match ONE datapath flow: the kernel
#   flow table (net/openvswitch/flow_table.c) lookup is barely exercised and the
#   hash path is never stressed with variety.
#
# Fix:
#   Install OpenFlow rules that *reference* L4 ports (tp_src / tp_dst). To decide
#   whether a packet matches such a rule, the OVS classifier must EXAMINE that
#   field, so the field is unwildcarded in the resulting megaflow. Each distinct
#   UDP source port therefore installs its own datapath flow, which forces
#   ovs_flow_tbl_lookup() -> flow_hash() to run on many distinct keys.
#
#   The probe rules below match port value 1 (which our test traffic never uses)
#   with action=drop, purely to force unwildcarding. Real traffic falls through
#   to the priority=0 NORMAL rule, so ns1<->ns2 connectivity (ping/ARP) still works.
#
# Usage:
#   ./force_megaflow_rules.sh           # apply: force per-src-port megaflows
#   ./force_megaflow_rules.sh restore   # restore plain NORMAL forwarding
#   BR=br0 ./force_megaflow_rules.sh    # override bridge name
#
set -euo pipefail

BR="${BR:-br0}"
MODE="${1:-force}"

if [[ "$MODE" == "restore" || "$MODE" == "--restore" ]]; then
	sudo ovs-ofctl del-flows "$BR"
	sudo ovs-ofctl add-flow "$BR" "priority=0,actions=NORMAL"
	echo "[OK] restored plain NORMAL forwarding on $BR"
	echo "Verify: sudo ovs-ofctl dump-flows $BR"
	exit 0
fi

if [[ "$MODE" != "force" ]]; then
	echo "usage: $0 [force|restore]" >&2
	exit 2
fi

# Clear existing OpenFlow rules, then install:
#   1. probe rules that reference tp_src / tp_dst  -> force L4 unwildcarding
#   2. a NORMAL fallback so non-matching traffic still forwards/learns
sudo ovs-ofctl del-flows "$BR"
sudo ovs-ofctl add-flow "$BR" "priority=200,udp,tp_src=1,actions=drop"
sudo ovs-ofctl add-flow "$BR" "priority=200,udp,tp_dst=1,actions=drop"
sudo ovs-ofctl add-flow "$BR" "priority=0,actions=NORMAL"

echo "[OK] forced per-5-tuple megaflows on $BR"
echo "     (the udp tp_src/tp_dst probe rules unwildcard L4 ports;"
echo "      every distinct UDP source port now installs its own datapath flow)"
echo
echo "Verify OpenFlow rules : sudo ovs-ofctl dump-flows $BR"
echo "Then generate traffic : sudo ip netns exec ns1 python3 send_microflows.py"
echo "          (or pktgen) : sudo ./scripts/pktgen_microflows.sh"
echo "Watch the hash get hit: sudo ./scripts/observe_flows.sh --watch 10"
