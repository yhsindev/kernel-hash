#!/usr/bin/env bash
set -euo pipefail

BR=${BR:-br0}
OUTPUT_PORT=${OUTPUT_PORT:-2}

SRC_IP_BASE=${SRC_IP_BASE:-10.0.1}
DST_IP_BASE=${DST_IP_BASE:-10.0.2}

SRC_IP_MIN=${SRC_IP_MIN:-1}
SRC_IP_MAX=${SRC_IP_MAX:-16}

DST_PORT_MIN=${DST_PORT_MIN:-9000}
DST_PORT_MAX=${DST_PORT_MAX:-9015}

SRC_PORT_MIN=${SRC_PORT_MIN:-20000}
SRC_PORT_MAX=${SRC_PORT_MAX:-20063}

MODE=${1:-install}

if [ "$MODE" = "restore" ]; then
  echo "[INFO] restoring NORMAL flow on $BR"
  sudo ovs-ofctl del-flows "$BR"
  sudo ovs-ofctl add-flow "$BR" "priority=0,actions=NORMAL"
  echo "[OK] restored NORMAL"
  exit 0
fi

echo "[INFO] installing D-v3B multimask rules on $BR"
echo "[INFO] src_ip=${SRC_IP_BASE}.${SRC_IP_MIN}-${SRC_IP_MAX}"
echo "[INFO] dst_ip groups=${DST_IP_BASE}.1-8"
echo "[INFO] src_port=${SRC_PORT_MIN}-${SRC_PORT_MAX}"
echo "[INFO] dst_port=${DST_PORT_MIN}-${DST_PORT_MAX}"
echo "[INFO] output_port=$OUTPUT_PORT"

sudo ovs-ofctl del-flows "$BR"

TMP=$(mktemp)
COUNT=0

emit() {
  echo "$1" >> "$TMP"
  COUNT=$((COUNT + 1))
}

act() {
  local x="$1"
  if [ $((x % 2)) -eq 0 ]; then
    echo "output:${OUTPUT_PORT}"
  else
    echo "drop"
  fi
}

# Default drop.
emit "priority=0,actions=drop"

# G1: nw_dst only
# Mask shape: nw_dst
emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.1,actions=output:${OUTPUT_PORT}"

# G2: nw_dst + tp_dst
# Mask shape: nw_dst,tp_dst
for dp in $(seq "$DST_PORT_MIN" "$DST_PORT_MAX"); do
  action=$(act "$dp")
  emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.2,tp_dst=${dp},actions=${action}"
done

# G3: nw_dst + tp_src
# Mask shape: nw_dst,tp_src
for sp in $(seq "$SRC_PORT_MIN" "$SRC_PORT_MAX"); do
  action=$(act "$sp")
  emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.3,tp_src=${sp},actions=${action}"
done

# G4: nw_dst + nw_src
# Mask shape: nw_dst,nw_src
for si in $(seq "$SRC_IP_MIN" "$SRC_IP_MAX"); do
  src_ip="${SRC_IP_BASE}.${si}"
  action=$(act "$si")
  emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.4,nw_src=${src_ip},actions=${action}"
done

# G5: nw_dst + nw_src + tp_dst
# Mask shape: nw_dst,nw_src,tp_dst
for si in $(seq "$SRC_IP_MIN" "$SRC_IP_MAX"); do
  src_ip="${SRC_IP_BASE}.${si}"
  for dp in $(seq "$DST_PORT_MIN" "$DST_PORT_MAX"); do
    action=$(act "$((si + dp))")
    emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.5,nw_src=${src_ip},tp_dst=${dp},actions=${action}"
  done
done

# G6: nw_dst + nw_src + tp_src
# Mask shape: nw_dst,nw_src,tp_src
for si in $(seq "$SRC_IP_MIN" "$SRC_IP_MAX"); do
  src_ip="${SRC_IP_BASE}.${si}"
  for sp in $(seq "$SRC_PORT_MIN" "$SRC_PORT_MAX"); do
    action=$(act "$((si + sp))")
    emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.6,nw_src=${src_ip},tp_src=${sp},actions=${action}"
  done
done

# G7: nw_dst + tp_src + tp_dst
# Mask shape: nw_dst,tp_src,tp_dst
for sp in $(seq "$SRC_PORT_MIN" "$SRC_PORT_MAX"); do
  for dp in $(seq "$DST_PORT_MIN" "$DST_PORT_MAX"); do
    action=$(act "$((sp + dp))")
    emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.7,tp_src=${sp},tp_dst=${dp},actions=${action}"
  done
done

# G8: nw_dst + nw_src + tp_src + tp_dst
# Mask shape: nw_dst,nw_src,tp_src,tp_dst
for si in $(seq "$SRC_IP_MIN" "$SRC_IP_MAX"); do
  src_ip="${SRC_IP_BASE}.${si}"
  for sp in $(seq "$SRC_PORT_MIN" "$SRC_PORT_MAX"); do
    for dp in $(seq "$DST_PORT_MIN" "$DST_PORT_MAX"); do
      action=$(act "$((si + sp + dp))")
      emit "priority=100,ip,nw_proto=17,nw_dst=${DST_IP_BASE}.8,nw_src=${src_ip},tp_src=${sp},tp_dst=${dp},actions=${action}"
    done
  done
done

echo "[INFO] generated $COUNT rules"
sudo ovs-ofctl add-flows "$BR" "$TMP"
rm -f "$TMP"

echo "[OK] installed D-v3B multimask rules"
echo "[INFO] priority=100 rule count:"
sudo ovs-ofctl dump-flows "$BR" | awk '/priority=100/ {c++} END {print c+0}'
