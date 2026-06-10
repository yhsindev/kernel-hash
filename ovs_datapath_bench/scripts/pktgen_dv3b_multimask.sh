#!/usr/bin/env bash
set -euo pipefail

NS=${NS:-ns1}
DEV=${DEV:-veth1}
DURATION=${DURATION:-10}
PKT_SIZE=${PKT_SIZE:-64}
THREAD=${THREAD:-0}

SRC_IP_BASE=${SRC_IP_BASE:-10.0.1}
DST_IP_BASE=${DST_IP_BASE:-10.0.2}

SRC_IP_MIN=${SRC_IP_MIN:-1}
SRC_IP_MAX=${SRC_IP_MAX:-16}

DST_IP_MIN=${DST_IP_MIN:-1}
DST_IP_MAX=${DST_IP_MAX:-8}

SRC_PORT_MIN=${SRC_PORT_MIN:-20000}
SRC_PORT_MAX=${SRC_PORT_MAX:-20063}

DST_PORT_MIN=${DST_PORT_MIN:-9000}
DST_PORT_MAX=${DST_PORT_MAX:-9015}

sudo modprobe pktgen

if ! sudo ip netns exec "$NS" test -d /proc/net/pktgen; then
  echo "[ERROR] /proc/net/pktgen is not available inside namespace $NS"
  exit 1
fi

PGDEV="kpktgend_${THREAD}"
PKTGEN_DEV="${DEV}@${THREAD}"

echo "[INFO] D-v3B multimask pktgen"
echo "[INFO] ns=$NS dev=$DEV duration=${DURATION}s"
echo "[INFO] src_ip=${SRC_IP_BASE}.${SRC_IP_MIN}-${SRC_IP_MAX}"
echo "[INFO] dst_ip=${DST_IP_BASE}.${DST_IP_MIN}-${DST_IP_MAX}"
echo "[INFO] src_port=${SRC_PORT_MIN}-${SRC_PORT_MAX}"
echo "[INFO] dst_port=${DST_PORT_MIN}-${DST_PORT_MAX}"

sudo ip netns exec "$NS" bash -c '
set -e

PGDEV="'"$PGDEV"'"
PKTGEN_DEV="'"$PKTGEN_DEV"'"
DURATION="'"$DURATION"'"
PKT_SIZE="'"$PKT_SIZE"'"

SRC_IP_BASE="'"$SRC_IP_BASE"'"
DST_IP_BASE="'"$DST_IP_BASE"'"

SRC_IP_MIN="'"$SRC_IP_MIN"'"
SRC_IP_MAX="'"$SRC_IP_MAX"'"
DST_IP_MIN="'"$DST_IP_MIN"'"
DST_IP_MAX="'"$DST_IP_MAX"'"

SRC_PORT_MIN="'"$SRC_PORT_MIN"'"
SRC_PORT_MAX="'"$SRC_PORT_MAX"'"
DST_PORT_MIN="'"$DST_PORT_MIN"'"
DST_PORT_MAX="'"$DST_PORT_MAX"'"

PGCTRL=/proc/net/pktgen/pgctrl
PGTHREAD=/proc/net/pktgen/$PGDEV
PGPKT=/proc/net/pktgen/$PKTGEN_DEV

echo "stop" > "$PGCTRL" || true
echo "rem_device_all" > "$PGTHREAD" || true
echo "add_device $PKTGEN_DEV" > "$PGTHREAD"

echo "clone_skb 0" > "$PGPKT"
echo "pkt_size $PKT_SIZE" > "$PGPKT"
echo "count 0" > "$PGPKT"
echo "delay 0" > "$PGPKT"

echo "src_min ${SRC_IP_BASE}.${SRC_IP_MIN}" > "$PGPKT"
echo "src_max ${SRC_IP_BASE}.${SRC_IP_MAX}" > "$PGPKT"
echo "dst_min ${DST_IP_BASE}.${DST_IP_MIN}" > "$PGPKT"
echo "dst_max ${DST_IP_BASE}.${DST_IP_MAX}" > "$PGPKT"

echo "udp_src_min $SRC_PORT_MIN" > "$PGPKT"
echo "udp_src_max $SRC_PORT_MAX" > "$PGPKT"
echo "udp_dst_min $DST_PORT_MIN" > "$PGPKT"
echo "udp_dst_max $DST_PORT_MAX" > "$PGPKT"

echo "flag IPSRC_RND" > "$PGPKT"
echo "flag IPDST_RND" > "$PGPKT"
echo "flag UDPSRC_RND" > "$PGPKT"
echo "flag UDPDST_RND" > "$PGPKT"

# count 0 means infinite. Start in background, then stop after duration.
echo "start" > "$PGCTRL" &
START_PID=$!

sleep "$DURATION"

echo "stop" > "$PGCTRL" || true
wait "$START_PID" || true

cat "$PGPKT"
'
