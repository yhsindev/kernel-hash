#!/usr/bin/env bash
# D-v3 A+B 合體:長 input(每條都含 nw_src+nw_dst → L3 進 hash range)
#                + 多 mask(用 nw_src/nw_dst prefix 長度變化造出多種 mask 形狀)
#
# 設計:
#   - 用 dst_port 切 8 段(互斥),每段一種 (src_prefix, dst_prefix) 組合 → 8 種 mask。
#   - 每段都 match nw_src + nw_dst + tp_dst:range 一定從 nw_src 起算 → input 長(A)。
#   - prefix 只改 mask 的 bit pattern,不改要 hash 的 byte 數 → 長 input 不受影響。
#   - 同段內相鄰規則 output/drop 交替,避免被 OVS 聚合。
set -euo pipefail

BR=${BR:-br0}
OUTPUT_PORT=${OUTPUT_PORT:-2}

SRC_IP_BASE=${SRC_IP_BASE:-10.0.1}
DST_IP_BASE=${DST_IP_BASE:-10.0.2}
SRC_IP_MIN=${SRC_IP_MIN:-1}
SRC_IP_MAX=${SRC_IP_MAX:-16}
DST_IP_MIN=${DST_IP_MIN:-1}
DST_IP_MAX=${DST_IP_MAX:-8}

# 8 段,每段 2 個 dst_port(對齊 pktgen 的 9000-9015)。
DST_PORT_MIN=${DST_PORT_MIN:-9000}
BAND_WIDTH=${BAND_WIDTH:-2}

# 8 種 (src_prefix, dst_prefix) → 8 種 mask 形狀(全都含 nw_src+nw_dst → 長 input)。
PX=(32 32 24 24 16 32 16 24)
PY=(32 24 32 24 32 16 24 16)

MODE=${1:-install}

if [ "$MODE" = "restore" ]; then
  echo "[INFO] restoring NORMAL flow on $BR"
  sudo ovs-ofctl del-flows "$BR"
  sudo ovs-ofctl add-flow "$BR" "priority=0,actions=NORMAL"
  echo "[OK] restored NORMAL"
  exit 0
fi

SRC_PRE16=$(echo "$SRC_IP_BASE" | cut -d. -f1-2)   # 10.0.1 -> 10.0
DST_PRE16=$(echo "$DST_IP_BASE" | cut -d. -f1-2)

echo "[INFO] installing D-v3 A+B combined rules on $BR"
echo "[INFO] src_ip=${SRC_IP_BASE}.${SRC_IP_MIN}-${SRC_IP_MAX}  dst_ip=${DST_IP_BASE}.${DST_IP_MIN}-${DST_IP_MAX}"
echo "[INFO] 8 bands x ${BAND_WIDTH} dst_port, from ${DST_PORT_MIN}"
echo "[INFO] prefix combos (src,dst): 32/32 32/24 24/32 24/24 16/32 32/16 16/24 24/16"

sudo ovs-ofctl del-flows "$BR"

TMP=$(mktemp)
COUNT=0
emit() { echo "$1" >> "$TMP"; COUNT=$((COUNT + 1)); }
act()  { if [ $(( $1 % 2 )) -eq 0 ]; then echo "output:${OUTPUT_PORT}"; else echo "drop"; fi; }

# 依 prefix 列出 nw_src 的 match 字串(/32 列舉每個 IP;/24、/16 用一條 CIDR 涵蓋)。
src_list() {
  case "$1" in
    32) for si in $(seq "$SRC_IP_MIN" "$SRC_IP_MAX"); do echo "${SRC_IP_BASE}.${si}"; done ;;
    24) echo "${SRC_IP_BASE}.0/24" ;;
    16) echo "${SRC_PRE16}.0.0/16" ;;
  esac
}
dst_list() {
  case "$1" in
    32) for di in $(seq "$DST_IP_MIN" "$DST_IP_MAX"); do echo "${DST_IP_BASE}.${di}"; done ;;
    24) echo "${DST_IP_BASE}.0/24" ;;
    16) echo "${DST_PRE16}.0.0/16" ;;
  esac
}

# 預設 drop(沒對到任何 band 的封包)。
emit "priority=0,actions=drop"

i=0
while [ "$i" -lt 8 ]; do
  px=${PX[$i]}
  py=${PY[$i]}
  lo=$(( DST_PORT_MIN + i * BAND_WIDTH ))
  hi=$(( lo + BAND_WIDTH - 1 ))
  echo "[INFO] band $i: nw_src/${px}, nw_dst/${py}, tp_dst ${lo}-${hi}"

  k=0
  for s in $(src_list "$px"); do
    for d in $(dst_list "$py"); do
      for dp in $(seq "$lo" "$hi"); do
        emit "priority=100,ip,nw_proto=17,nw_src=${s},nw_dst=${d},tp_dst=${dp},actions=$(act "$k")"
        k=$((k + 1))
      done
    done
  done
  i=$((i + 1))
done

echo "[INFO] generated $COUNT rules"
sudo ovs-ofctl add-flows "$BR" "$TMP"
rm -f "$TMP"

echo "[OK] installed D-v3 A+B combined rules"
echo "[INFO] priority=100 rule count:"
sudo ovs-ofctl dump-flows "$BR" | awk '/priority=100/ {c++} END {print c+0}'
