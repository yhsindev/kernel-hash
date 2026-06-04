#!/usr/bin/env bash
#
# pktgen_microflows.sh
#
# High-rate UDP microflow generator using the in-kernel pktgen module. Replaces
# send_microflows.py for the throughput benchmark: Python's per-packet socket()/bind()/sendto() 
# overhead can dominate the cost, so it is unsuitable for final throughput benchmarking,
# whereas pktgen crafts frames in kernel space at millions of pps.
#
# It randomizes the UDP source port (flag UDPSRC_RND) and, when DSTMIN != DSTMAX,
# the destination port (flag UDPDST_RND) as well. Combined with
# force_megaflow_rules.sh every packet can install/hit a distinct datapath flow,
# stressing net/openvswitch/flow_table.c flow_hash().
#
# Injection point:
#   pktgen transmits on veth1 (inside ns1). veth1's peer veth1-br is an OVS port,
#   so frames enter the kernel datapath exactly like real ns1->ns2 traffic.
#   (pktgen is per-netns aware on modern kernels; the preflight below verifies it.)
#
# Usage:
#   sudo ./pktgen_microflows.sh                            # 20s, src ports 20000-60000, fixed dst
#   DURATION=60 SRCMAX=65000 sudo ./pktgen_microflows.sh
#   DSTMIN=20000 DSTMAX=60000 sudo ./pktgen_microflows.sh  # also vary dst port
#   COUNT=1000000 sudo ./pktgen_microflows.sh              # send a fixed number then stop
#
set -euo pipefail

NETNS="${NETNS:-ns1}"
DEV="${DEV:-veth1}"
SRC_IP="${SRC_IP:-10.0.0.1}"
DST_IP="${DST_IP:-10.0.0.2}"
DST_PORT="${DST_PORT:-9000}"
SRCMIN="${SRCMIN:-20000}"
SRCMAX="${SRCMAX:-60000}"
PKT_SIZE="${PKT_SIZE:-64}"   # minimum 60; Ethernet+IP+UDP headers fit in 64
COUNT="${COUNT:-0}"          # 0 = run continuously until DURATION elapses
DURATION="${DURATION:-20}"
DSTMIN="${DSTMIN:-$DST_PORT}"
DSTMAX="${DSTMAX:-$DST_PORT}"
SRCIPMIN="${SRCIPMIN:-$SRC_IP}"
SRCIPMAX="${SRCIPMAX:-$SRC_IP}"


# check root privileges
if [[ "$(id -u)" -ne 0 ]]; then
	echo "Run as root: sudo $0" >&2
	exit 1
fi

# load pktgen module
modprobe pktgen

# Preflight: pktgen control interface must be visible inside the target netns.
if ! ip netns exec "$NETNS" test -e /proc/net/pktgen/pgctrl; then
	echo "ERROR: /proc/net/pktgen not present in netns '$NETNS'." >&2
	echo "Your kernel's pktgen may not be per-netns enabled. Fallback options:" >&2
	echo "  - inject from the root namespace on a dedicated veth whose peer is an" >&2
	echo "    OVS port (see ovs_datapath_bench/README.md, 'pktgen fallback')." >&2
	exit 1
fi
if ! ip netns exec "$NETNS" test -e "/sys/class/net/$DEV"; then
	echo "ERROR: device '$DEV' not found in netns '$NETNS'. Run setup_ovs_testbed.sh first." >&2
	exit 1
fi

# Destination MAC: ns2's veth2 so the bridge forwards toward ns2. (Even a wrong
# MAC still enters the datapath and triggers a lookup, but the real MAC lets the
# packets be delivered/learned.)
DST_MAC="${DST_MAC:-$(ip netns exec ns2 cat /sys/class/net/veth2/address 2>/dev/null || true)}"
DST_MAC="${DST_MAC:-02:00:00:00:00:02}"

ip netns exec "$NETNS" ip link set "$DEV" up

echo "pktgen config:"
echo "  netns=$NETNS dev=$DEV  $SRC_IP -> $DST_IP (mac $DST_MAC)"
echo "  udp src port: $SRCMIN-$SRCMAX (random)"
echo "  udp dst port: $DSTMIN-$DSTMAX $([[ "$DSTMAX" -ne "$DSTMIN" ]] && echo "(random)" || echo "(fixed)")"
echo "  pkt_size=$PKT_SIZE count=$COUNT duration=${DURATION}s"

# Configure the device on thread 0. clone_skb=0 forces a fresh skb per packet so
# UDPSRC_RND (and UDPDST_RND when enabled) actually varies the port on every packet.
ip netns exec "$NETNS" bash <<EOF
set -e
CTL=/proc/net/pktgen/kpktgend_0
PGDEV=/proc/net/pktgen/$DEV
echo "rem_device_all"          > "\$CTL"
echo "add_device $DEV"         > "\$CTL"
echo "count $COUNT"            > "\$PGDEV"
echo "clone_skb 0"             > "\$PGDEV"
echo "delay 0"                 > "\$PGDEV"
echo "pkt_size $PKT_SIZE"      > "\$PGDEV"
echo "src_min $SRCIPMIN"       > "\$PGDEV"
echo "src_max $SRCIPMAX"       > "\$PGDEV"
echo "dst $DST_IP"             > "\$PGDEV"
echo "dst_mac $DST_MAC"        > "\$PGDEV"
echo "udp_dst_min $DSTMIN"     > "\$PGDEV"
echo "udp_dst_max $DSTMAX"     > "\$PGDEV"
echo "udp_src_min $SRCMIN"     > "\$PGDEV"
echo "udp_src_max $SRCMAX"     > "\$PGDEV"
echo "flag UDPSRC_RND"         > "\$PGDEV"
EOF

# Conditionally enable dst port randomization. pktgen's "flag" command only
# accepts ONE flag name per write (its parser doesn't split on comma), so we
# issue a second write here instead of joining flags in the heredoc above.
if [[ "$DSTMAX" -ne "$DSTMIN" ]]; then
    ip netns exec "$NETNS" bash -c "echo 'flag UDPDST_RND' > /proc/net/pktgen/$DEV"
fi

if [[ "$SRCIPMAX" != "$SRCIPMIN" ]]; then
    ip netns exec "$NETNS" bash -c "echo 'flag IPSRC_RND' > /proc/net/pktgen/$DEV"
fi

echo "Starting pktgen... (tip: in another terminal run ./observe_flows.sh --watch ${DURATION})"

if [[ "$COUNT" -eq 0 ]]; then
	# Continuous: start in background, stop after DURATION.
	ip netns exec "$NETNS" bash -c 'echo start > /proc/net/pktgen/pgctrl' &
	pg_pid=$!
	sleep "$DURATION"
	ip netns exec "$NETNS" bash -c 'echo stop > /proc/net/pktgen/pgctrl' || true
	wait "$pg_pid" 2>/dev/null || true
else
	# Fixed count: start blocks until COUNT packets are sent.
	ip netns exec "$NETNS" bash -c 'echo start > /proc/net/pktgen/pgctrl'
fi

echo
echo "=== pktgen result ($DEV) ==="
ip netns exec "$NETNS" cat "/proc/net/pktgen/$DEV" | sed -n '/Result:/,$p'
