#!/usr/bin/env bash
#
# install_irregular_udp_rules.sh
#
# Install a parameterized matrix of UDP port-pair rules on an OVS bridge.
#
# Purpose:
#   This script is used for Case D workloads in Experiment 2. It installs many
#   specific UDP (tp_src, tp_dst) OpenFlow rules so that L4 ports become relevant
#   to OVS classification. Whether OVS fully exact-matches the ports in datapath
#   megaflows must still be verified with:
#
#       sudo ovs-dpctl dump-flows -m
#
# Workloads:
#   D-v1      : 50 x 10   = 500 rules
#   D-v2-small: 100 x 20  = 2000 rules
#   D-v2-mid  : 200 x 50  = 10000 rules
#
# Usage:
#   sudo ./install_irregular_udp_rules.sh
#
#   sudo SRCMAX=20049 DSTMAX=9009 \
#        ./install_irregular_udp_rules.sh
#
#   sudo SRCMAX=20199 DSTMAX=9049 \
#        ./install_irregular_udp_rules.sh
#
#   sudo ./install_irregular_udp_rules.sh restore
#

set -euo pipefail

BR="${BR:-br0}"
MODE="${1:-install}"

SRCMIN="${SRCMIN:-20000}"
SRCMAX="${SRCMAX:-20099}"

DSTMIN="${DSTMIN:-9000}"
DSTMAX="${DSTMAX:-9019}"

OUTPUT_PORT="${OUTPUT_PORT:-veth2-br}"

# Safety stop: prevent accidental huge rule installation.
MAX_RULES_WARN="${MAX_RULES_WARN:-15000}"

if [[ "$MODE" == "restore" || "$MODE" == "--restore" ]]; then
	sudo ovs-ofctl del-flows "$BR"
	sudo ovs-ofctl add-flow "$BR" "priority=0,actions=NORMAL"
	echo "[OK] $BR restored to plain NORMAL forwarding"
	exit 0
fi

if [[ "$MODE" != "install" ]]; then
	echo "usage: $0 [install|restore]" >&2
	exit 2
fi

# Validate ranges.
if [[ "$SRCMAX" -lt "$SRCMIN" ]]; then
	echo "ERROR: SRCMAX ($SRCMAX) is smaller than SRCMIN ($SRCMIN)." >&2
	exit 1
fi

if [[ "$DSTMAX" -lt "$DSTMIN" ]]; then
	echo "ERROR: DSTMAX ($DSTMAX) is smaller than DSTMIN ($DSTMIN)." >&2
	exit 1
fi

# Compute total rule count.
src_count=$((SRCMAX - SRCMIN + 1))
dst_count=$((DSTMAX - DSTMIN + 1))
total=$((src_count * dst_count))

echo "Planned install:"
echo "  bridge      : $BR"
echo "  src ports   : $SRCMIN-$SRCMAX  ($src_count values)"
echo "  dst ports   : $DSTMIN-$DSTMAX  ($dst_count values)"
echo "  output port : $OUTPUT_PORT"
echo "  total rules : $total  (plus 1 NORMAL fallback)"
echo

if [[ "$total" -gt "$MAX_RULES_WARN" ]]; then
	echo "ABORT: $total rules exceeds MAX_RULES_WARN=$MAX_RULES_WARN." >&2
	echo "       Set MAX_RULES_WARN=<N> to override if this range is intentional." >&2
	exit 1
fi

# Resolve OUTPUT_PORT name to OpenFlow port number.
#
# This replaces the weaker grep-only check. OpenFlow actions are safer when
# written with the actual ofport number, e.g. output:3, rather than relying on
# a port name string.
OFPORT="$(
	sudo ovs-ofctl show "$BR" \
		| sed -nE "s/^[[:space:]]*([0-9]+)\(${OUTPUT_PORT}\):.*/\1/p" \
		| head -n1
)"

if [[ -z "$OFPORT" ]]; then
	echo "ERROR: OpenFlow port '$OUTPUT_PORT' not present on $BR." >&2
	echo "       Available ports:" >&2
	sudo ovs-ofctl show "$BR" >&2
	echo "       Set OUTPUT_PORT=<name> to a valid OpenFlow port name." >&2
	exit 1
fi

echo "Resolved output port:"
echo "  $OUTPUT_PORT -> OpenFlow port $OFPORT"
echo

# Wipe previous OpenFlow rules so old probes or old workloads do not shadow this run.
sudo ovs-ofctl del-flows "$BR"

# Build all rules and install them in one ovs-ofctl invocation.
#
# The output/drop mapping makes UDP port pairs relevant to classification.
# It does not, by itself, prove full exact-match datapath masks; verify with:
#   sudo ovs-dpctl dump-flows -m | grep udp | head -30
{
	for sp in $(seq "$SRCMIN" "$SRCMAX"); do
		for dp in $(seq "$DSTMIN" "$DSTMAX"); do
			if [[ $(((sp + dp) % 2)) -eq 0 ]]; then
				echo "priority=100,udp,tp_src=$sp,tp_dst=$dp,actions=output:$OFPORT"
			else
				echo "priority=100,udp,tp_src=$sp,tp_dst=$dp,actions=drop"
			fi
		done
	done

	# Fallback rule for ARP, ping, and traffic outside the tested UDP range.
	echo "priority=0,actions=NORMAL"
} | sudo ovs-ofctl add-flows "$BR" -

# Verify final rule count.
installed=$(sudo ovs-ofctl dump-flows "$BR" | grep -c 'priority=')
expected=$((total + 1))

if [[ "$installed" -ne "$expected" ]]; then
	echo "WARNING: installed $installed rules, expected $expected." >&2
	echo "         Some rules may have been rejected." >&2
	echo "         Inspect with: sudo ovs-ofctl dump-flows $BR | head" >&2
else
	echo "[OK] $installed rules installed on $BR"
fi

echo
echo "Next steps:"
echo "  Inspect rules:"
echo "    sudo ovs-ofctl dump-flows $BR | head -5"
echo
echo "  Run traffic:"
echo "    sudo DURATION=20 \\"
echo "         SRCMIN=$SRCMIN SRCMAX=$SRCMAX \\"
echo "         DSTMIN=$DSTMIN DSTMAX=$DSTMAX \\"
echo "         ./ovs_datapath_bench/scripts/pktgen_microflows.sh"
echo
echo "  Watch datapath:"
echo "    sudo ./ovs_datapath_bench/scripts/observe_flows.sh --watch 30"
echo
echo "  Verify masks:"
echo "    sudo ovs-dpctl dump-flows -m | grep udp | head -30"
echo
echo "  Restore NORMAL:"
echo "    sudo ./ovs_datapath_bench/scripts/$(basename "$0") restore"