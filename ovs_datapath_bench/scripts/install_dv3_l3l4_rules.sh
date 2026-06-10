#!/usr/bin/env bash
set -euo pipefail

BR=${BR:-br0}
OUTPUT_PORT=${OUTPUT_PORT:-2}

SRC_IP_BASE=${SRC_IP_BASE:-10.0.1}
DST_IP_BASE=${DST_IP_BASE:-10.0.2}

SRC_IP_MIN=${SRC_IP_MIN:-1}
SRC_IP_MAX=${SRC_IP_MAX:-10}

DST_IP_MIN=${DST_IP_MIN:-1}
DST_IP_MAX=${DST_IP_MAX:-5}

SRC_PORT_MIN=${SRC_PORT_MIN:-20000}
SRC_PORT_MAX=${SRC_PORT_MAX:-20049}

DST_PORT_MIN=${DST_PORT_MIN:-9000}
DST_PORT_MAX=${DST_PORT_MAX:-9009}

MODE=${1:-install}

if [ "$MODE" = "restore" ]; then
  echo "[INFO] restoring NORMAL flow on $BR"
  sudo ovs-ofctl del-flows "$BR"
  sudo ovs-ofctl add-flow "$BR" "priority=0,actions=NORMAL"
  echo "[OK] restored NORMAL"
  exit 0
fi

echo "[INFO] installing D-v3 L3+L4 exact rules on $BR"
echo "[INFO] src_ip=${SRC_IP_BASE}.${SRC_IP_MIN}-${SRC_IP_MAX}"
echo "[INFO] dst_ip=${DST_IP_BASE}.${DST_IP_MIN}-${DST_IP_MAX}"
echo "[INFO] src_port=${SRC_PORT_MIN}-${SRC_PORT_MAX}"
echo "[INFO] dst_port=${DST_PORT_MIN}-${DST_PORT_MAX}"
echo "[INFO] output_port=$OUTPUT_PORT"

sudo ovs-ofctl del-flows "$BR"

TMP=$(mktemp)

# Default drop.
echo "priority=0,actions=drop" >> "$TMP"

COUNT=0
for si in $(seq "$SRC_IP_MIN" "$SRC_IP_MAX"); do
  for di in $(seq "$DST_IP_MIN" "$DST_IP_MAX"); do
    for sp in $(seq "$SRC_PORT_MIN" "$SRC_PORT_MAX"); do
      for dp in $(seq "$DST_PORT_MIN" "$DST_PORT_MAX"); do

        src_ip="${SRC_IP_BASE}.${si}"
        dst_ip="${DST_IP_BASE}.${di}"

        # Mixed action to prevent easy prefix/action aggregation.
        # Adjacent IP/port combinations alternate between output and drop.
        if [ $(( (si + di + sp + dp) % 2 )) -eq 0 ]; then
          action="output:${OUTPUT_PORT}"
        else
          action="drop"
        fi

        echo "priority=100,ip,nw_proto=17,nw_src=${src_ip},nw_dst=${dst_ip},tp_src=${sp},tp_dst=${dp},actions=${action}" >> "$TMP"
        COUNT=$((COUNT + 1))
      done
    done
  done
done

echo "[INFO] generated $COUNT exact L3+L4 rules"
sudo ovs-ofctl add-flows "$BR" "$TMP"
rm -f "$TMP"

echo "[OK] installed D-v3 L3+L4 rules"
echo "[INFO] rule count:"
sudo ovs-ofctl dump-flows "$BR" | grep -c "nw_src=" || true
