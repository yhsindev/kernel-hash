#!/usr/bin/env bash
# collect_backend_evidence.sh — 為「當前已 reload 的 backend」存一份證據檔
#
# 前置:backend 已 reload、D-v3B 規則已裝。
# 用法(repo 根): sudo -v && ./ovs_datapath_bench/scripts/collect_backend_evidence.sh siphash
#
# 產出 results/v3b/dv3b_evidence_<backend>/:
#   identity.txt   — loaded/build srcversion + nm -u(證明沒載錯 module)
#   calltree.txt   — perf callgraph 摘錄(wrapper → __*siphash_unaligned;jhash 看 flat self≈children)
#   flat.txt       — flat 模式 ovs_flow_hash_backend / masked_flow_lookup 兩行
#   dpctl.txt      — flows / masks / hit-pkt(workload validity)
set -uo pipefail

BACKEND="${1:?用法: collect_backend_evidence.sh <backend>}"
CORE="${CORE:-0}"
TOOL_CORE="${TOOL_CORE:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
cd "$REPO_DIR"
KO=kernel_work/linux-hwe-6.8-6.8.0/net/openvswitch/openvswitch.ko
OUT="ovs_datapath_bench/results/v3b/dv3b_evidence_${BACKEND}"
mkdir -p "$OUT"

echo ">>> identity"
{
  echo "=== loaded srcversion ===";  cat /sys/module/openvswitch/srcversion
  echo "=== build artifact srcversion ==="; modinfo "$KO" | grep -E 'srcversion|vermagic'
  echo "=== nm -u (hash imports) ==="
  nm -u "$KO" | grep -iE 'siphash|hash' || echo "(none)"
} > "$OUT/identity.txt"

echo ">>> traffic + perf(20s pktgen,10s record)"
sudo DURATION=20 "$SCRIPT_DIR/pktgen_dv3b_multimask.sh" >/tmp/pg_ev.txt 2>&1 &
PID=$!
sleep 5
sudo ovs-dpctl show | grep -E 'lookups:|flows:|masks:' > "$OUT/dpctl.txt"
sudo taskset -c "$TOOL_CORE" perf record -C "$CORE" -g -o /tmp/ev.data -- sleep 10 >/dev/null 2>&1
wait "$PID"

echo ">>> 萃取 call-tree / flat"
sudo perf report -i /tmp/ev.data --stdio -g graph,0.1,callee --percent-limit 0.1 2>/dev/null \
  | grep -B2 -A6 'ovs_flow_hash_backend' | head -120 > "$OUT/calltree.txt"
sudo perf report -i /tmp/ev.data --stdio 2>/dev/null \
  | grep -E '\[k\] ovs_flow_hash_backend$|\[k\] masked_flow_lookup$' | head -4 > "$OUT/flat.txt"
sudo rm -f /tmp/ev.data

echo ">>> saved to $OUT/"
echo "--- identity.txt ---"; cat "$OUT/identity.txt"
echo "--- flat.txt ---";     cat "$OUT/flat.txt"
echo "--- calltree.txt(前 20 行)---"; head -20 "$OUT/calltree.txt"
