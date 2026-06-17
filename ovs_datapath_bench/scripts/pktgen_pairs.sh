#!/usr/bin/env bash
#
# pktgen_pairs.sh — 逐對(src_ip dst_ip)送 UDP 封包,供 Part 3 攻擊碰撞集植入。
#
# 與 pktgen_dv3b_multimask.sh 的差別:那支用「範圍 + *_RND」隨機,兩軸獨立,
# 無法產生特定配對;碰撞集是 K 組「特定 (src_ip, dst_ip)」,必須逐對固定送
# (src_min=src_max、dst_min=dst_max、不設 RND)。其餘 netns/device 處理相同。
#
# 用法:
#   ./pktgen_pairs.sh <pairs.txt>            # 每行 "src_ip dst_ip"(keys_to_rules.py --pairs-out)
#   DURATION=30 COUNT=2000 ./pktgen_pairs.sh /path/coll_pairs.txt
#
# 持續灌 DURATION 秒(把整份配對迴圈重送),維持 megaflow 不被 idle 逐出,
# 好讓另一終端機抓 ovs_buckets / ovs_probelen snapshot。
# UDP 埠任意(碰撞規則 wildcard 掉 ports),這裡固定一組即可。
set -euo pipefail

PAIRS=${1:?用法: pktgen_pairs.sh <pairs.txt>}
NS=${NS:-ns1}
DEV=${DEV:-veth1}
THREAD=${THREAD:-0}
PKT_SIZE=${PKT_SIZE:-64}
COUNT=${COUNT:-2000}       # 每對每輪封包數(finite,start 會阻塞到送完)
DURATION=${DURATION:-30}   # 總持續秒數(迴圈重送整份配對)
UDP_SRC=${UDP_SRC:-1234}
UDP_DST=${UDP_DST:-5678}

PAIRS_ABS=$(readlink -f "$PAIRS")
[ -r "$PAIRS_ABS" ] || { echo "[ERROR] 讀不到 pairs 檔:$PAIRS_ABS"; exit 1; }

sudo modprobe pktgen
if ! sudo ip netns exec "$NS" test -d /proc/net/pktgen; then
  echo "[ERROR] netns $NS 內無 /proc/net/pktgen"; exit 1
fi

echo "[INFO] pktgen pairs: ns=$NS dev=$DEV pairs=$PAIRS_ABS ($(grep -c . "$PAIRS_ABS") 對) duration=${DURATION}s count/pair=$COUNT"

sudo ip netns exec "$NS" bash -c '
set -e
PGDEV=kpktgend_'"$THREAD"'
DEVQ="'"$DEV"'@'"$THREAD"'"
PGCTRL=/proc/net/pktgen/pgctrl
PGTHREAD=/proc/net/pktgen/$PGDEV
PGPKT=/proc/net/pktgen/$DEVQ

echo "stop" > "$PGCTRL" || true
echo "rem_device_all" > "$PGTHREAD" || true
echo "add_device $DEVQ" > "$PGTHREAD"

# 每對固定不變的設定(不設 *_RND → src/dst 取 min 值,即固定 IP)
echo "clone_skb 0" > "$PGPKT"
echo "pkt_size '"$PKT_SIZE"'" > "$PGPKT"
echo "delay 0" > "$PGPKT"
echo "count '"$COUNT"'" > "$PGPKT"
echo "udp_src_min '"$UDP_SRC"'" > "$PGPKT"; echo "udp_src_max '"$UDP_SRC"'" > "$PGPKT"
echo "udp_dst_min '"$UDP_DST"'" > "$PGPKT"; echo "udp_dst_max '"$UDP_DST"'" > "$PGPKT"

end=$((SECONDS + '"$DURATION"'))
cyc=0
while [ $SECONDS -lt $end ]; do
  cyc=$((cyc + 1))
  while read -r A B _; do
    [ -z "${A:-}" ] && continue
    echo "src_min $A" > "$PGPKT"; echo "src_max $A" > "$PGPKT"
    echo "dst_min $B" > "$PGPKT"; echo "dst_max $B" > "$PGPKT"
    echo "start" > "$PGCTRL"   # finite count → 阻塞到本對送完,再換下一對
  done < "'"$PAIRS_ABS"'"
done
echo "[INFO] 送完 $cyc 輪"
'
