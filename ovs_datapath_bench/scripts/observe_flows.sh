#!/usr/bin/env bash
#
# observe_flows.sh
#
# Snapshot or live-watch the OVS kernel datapath to PROVE that packets are
# reaching the flow table (net/openvswitch/flow_table.c) hash path.
#
# Key signals from `ovs-dpctl show`:
#   lookups: hit:H missed:M lost:L
#       hit    -> packets matched an existing datapath flow in the kernel
#                 (the fast path; each hit is a successful flow table hash lookup)
#       missed -> upcalls to userspace (a new megaflow had to be installed)
#   flows: N
#       N      -> number of datapath flows currently installed (hash table size)
#   masks: hit:X total:T hit/pkt:P
#       T      -> number of masks (subtables) searched; each mask = one masked
#                 flow_hash() per packet, so this is the per-packet hash cost
#
# If, after applying force_megaflow_rules.sh and sending varying-src-port UDP,
# you see `flows` grow into the thousands and `hit` climbing fast, the kernel
# flow table hash is being exercised with variety -- exactly what we want.
#
# Usage:
#   ./observe_flows.sh                 # one detailed snapshot
#   ./observe_flows.sh --watch [SECS]  # live per-second deltas (default 15s)
#
set -euo pipefail

BR="${BR:-br0}"

# Parse `ovs-dpctl show` into: HIT MISSED LOST FLOWS MASK_HIT MASK_TOTAL HIT_PER_PKT
parse_dp() {
	sudo ovs-dpctl show 2>/dev/null | awk '
		/lookups:/ {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^hit:/)    { split($i, a, ":"); hit  = a[2] }
				if ($i ~ /^missed:/) { split($i, a, ":"); miss = a[2] }
				if ($i ~ /^lost:/)   { split($i, a, ":"); lost = a[2] }
			}
		}
		/flows:/ {
			for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) flows = $i
		}
		/masks:/ {
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^hit:/)      { split($i, a, ":"); mhit = a[2] }
				if ($i ~ /^total:/)    { split($i, a, ":"); mtot = a[2] }
				if ($i ~ /^hit\/pkt:/) { split($i, a, ":"); hpp  = a[2] }
			}
		}
		END {
			printf "%d %d %d %d %d %d %s\n",
			       hit + 0, miss + 0, lost + 0, flows + 0, mhit + 0, mtot + 0, (hpp == "" ? "0" : hpp)
		}
	'
}

if [[ "${1:-}" == "--watch" ]]; then
	secs="${2:-15}"
	echo "Watching $BR datapath for ${secs}s (per-second deltas)..."
	echo "  d_hit    = fast-path flow-table matches/s (successful hash lookups/s)"
	echo "  d_missed = upcalls/s (new megaflows installed)"
	echo "  flows    = datapath flows currently installed (hash table entries)"
	echo "  masks    = subtables searched (masked flow_hash() per packet)"
	echo "  hit/pkt  = avg mask lookups per packet"
	echo
	printf "%-8s %12s %12s %10s %8s %8s\n" "t(s)" "d_hit" "d_missed" "flows" "masks" "hit/pkt"

	read -r p_hit p_miss _ _ _ _ _ <<<"$(parse_dp)"
	for ((t = 1; t <= secs; t++)); do
		sleep 1
		read -r hit miss _ flows _ mtot hpp <<<"$(parse_dp)"
		printf "%-8d %12d %12d %10d %8d %8s\n" \
			"$t" "$((hit - p_hit))" "$((miss - p_miss))" "$flows" "$mtot" "$hpp"
		p_hit="$hit"
		p_miss="$miss"
	done
	exit 0
fi

# ---- one detailed snapshot ----
echo "=== OVS bridge ==="
sudo ovs-vsctl show

echo
echo "=== Datapath ports ==="
sudo ovs-dpctl show

echo
echo "=== OpenFlow rules (br0) ==="
sudo ovs-ofctl dump-flows "$BR"

echo
echo "=== Kernel datapath flows (sample) ==="
sudo ovs-dpctl dump-flows | head -10
echo
echo "=== Kernel datapath flows with masks (sample) ==="
sudo ovs-dpctl dump-flows -m | head -10


echo
read -r hit miss lost flows mhit mtot hpp <<<"$(parse_dp)"
echo "=== Flow-table hash activity ==="
echo "  datapath flows installed : $flows"
echo "  lookups hit / missed/lost: $hit / $miss / $lost"
echo "  masks searched (subtbls) : $mtot   (avg ${hpp} mask lookups per packet)"
echo
if [[ "$flows" -eq 0 ]]; then
	echo "  -> no active datapath flows at this moment."
elif [[ "$flows" -lt 10 ]]; then
	echo "  -> low flow diversity: traffic may be collapsed into a small number of megaflows."
else
	echo "  -> non-trivial datapath flow diversity observed. Check masks and hit/pkt before using it as a benchmark workload."
fi
