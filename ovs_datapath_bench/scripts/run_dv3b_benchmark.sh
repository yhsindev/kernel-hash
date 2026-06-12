#!/usr/bin/env bash
# run_dv3b_benchmark.sh — D-v3B 正式量測:一個 backend 連跑 N 輪,結果 append 進 CSV
#
# 對應 benchmark_runbook.md step 5(perf record/stat 都 -C 0,背景 mpstat 記 %soft)。
# 前置:backend 已 build + reload(runbook step 1-2)、D-v3B 規則已裝(step 3)。
#
# 用法(repo 根目錄):
#   sudo -v
#   ./ovs_datapath_bench/scripts/run_dv3b_benchmark.sh jhash 5
#
# CSV 欄位:
#   backend,run,srcversion,flows,masks_total,hit_per_pkt,ohash_children,ohash_self,
#   masked_children,masked_self,cycles,instructions,ipc,soft_pct,pps
set -uo pipefail

BACKEND="${1:?用法: run_dv3b_benchmark.sh <backend> [N]}"
N="${2:-5}"
CORE="${CORE:-0}"                       # 轉發核心(step 4 gate 定為 CPU 0)
TOOL_CORE="${TOOL_CORE:-3}"             # 量測工具(perf/mpstat user-space)pin 到的核:遠離 CORE 與其 SMT 雙生核(0,6)
CSV="${CSV:-ovs_datapath_bench/results/dv3b_formal_perf.csv}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
cd "$REPO_DIR"

PKTGEN="$SCRIPT_DIR/pktgen_dv3b_multimask.sh"

# --- Layer 0:backend 身分(印出來,人工比對 runbook 的期望 srcversion 表)---
SV=$(cat /sys/module/openvswitch/srcversion)
echo ">>> backend=$BACKEND  loaded srcversion=$SV  (core=$CORE, N=$N)"
nm -u kernel_work/linux-hwe-6.8-6.8.0/net/openvswitch/openvswitch.ko 2>/dev/null \
  | grep -iE 'siphash|hsiphash' || echo "    (無 out-of-line hash import → jhash inline)"

# --- CSV header(不存在才寫)---
if [ ! -f "$CSV" ]; then
  echo "backend,run,srcversion,flows,masks_total,hit_per_pkt,ohash_children,ohash_self,masked_children,masked_self,cycles,instructions,ipc,soft_pct,pps" > "$CSV"
fi

# --- warm-up:建 flows(不記錄)---
echo ">>> warm-up 15s(建 flows,不記錄)"
sudo DURATION=15 "$PKTGEN" >/tmp/pg.txt 2>&1
WARM_FL=$(sudo ovs-dpctl show | awk -F'[: ]+' '/flows:/{print $3; exit}')
echo "    warm-up 後 flows=$WARM_FL"
if [ -z "$WARM_FL" ] || [ "$WARM_FL" -lt 9000 ]; then
  echo "ABORT: warm-up flows=$WARM_FL < 9000,workload 沒建起來"; exit 1
fi

for i in $(seq 1 "$N"); do
  echo ">>> run $i/$N"
  sudo DURATION=35 "$PKTGEN" >/tmp/pg.txt 2>&1 &
  PID=$!
  sleep 5

  # Layer 0:flows gate + masks/hit-pkt
  DP=$(sudo ovs-dpctl show)
  FL=$(echo "$DP" | awk -F'[: ]+' '/flows:/{print $3; exit}')
  MT=$(echo "$DP" | grep -oE 'total:[0-9]+' | grep -oE '[0-9]+')
  HP=$(echo "$DP" | grep -oE 'hit/pkt:[0-9.]+' | grep -oE '[0-9.]+')
  if [ -z "$FL" ] || [ "$FL" -lt 9000 ]; then
    echo "ABORT: run$i flows=$FL < 9000"; wait "$PID"; exit 1
  fi

  # Layer 3 佐證:背景 mpstat 記 CPU $CORE(涵蓋兩個 10s 窗口)
  # 工具本身 taskset 到 $TOOL_CORE:避免 perf/mpstat 的 user-space 被排到 CPU $CORE 的 SMT 雙生核(0,6)搶資源
  LC_ALL=C taskset -c "$TOOL_CORE" mpstat -P "$CORE" 1 21 >/tmp/soft.txt 2>&1 &
  MPID=$!

  # Layer 1-2:perf record -C 0(children%/self%;-C 是「監測哪顆核」,taskset 是「perf 程式自己跑哪顆」)
  sudo taskset -c "$TOOL_CORE" perf record -C "$CORE" -g -o /tmp/p.data -- sleep 10 >/dev/null 2>&1
  # Layer 3:perf stat -C 0(cycles/instructions;LC_ALL=C 避免千分位格式因 locale 而異)
  sudo LC_ALL=C taskset -c "$TOOL_CORE" perf stat -C "$CORE" -e cycles,instructions -- sleep 10 2>/tmp/stat.txt

  wait "$PID"
  wait "$MPID" 2>/dev/null

  # pktgen errors gate
  ERR=$(grep -oE 'errors: [0-9]+' /tmp/pg.txt | tail -1 | grep -oE '[0-9]+')
  if [ -n "$ERR" ] && [ "$ERR" -ne 0 ]; then
    echo "ABORT: run$i pktgen errors=$ERR"; exit 1
  fi

  # 讀數
  REP=$(sudo perf report -i /tmp/p.data --stdio 2>/dev/null)
  oh=$(echo "$REP" | grep -E '^[[:space:]]+[0-9.]+%[[:space:]]+[0-9.]+%.*\[k\] ovs_flow_hash_backend$' | head -1)
  mk=$(echo "$REP" | grep -E '^[[:space:]]+[0-9.]+%[[:space:]]+[0-9.]+%.*\[k\] masked_flow_lookup$' | head -1)
  OH_C=$(echo "$oh" | awk '{print $1+0}'); OH_S=$(echo "$oh" | awk '{print $2+0}')
  MK_C=$(echo "$mk" | awk '{print $1+0}'); MK_S=$(echo "$mk" | awk '{print $2+0}')

  CYC=$(grep -E 'cycles' /tmp/stat.txt | head -1 | awk '{gsub(",","",$1); print $1}')
  INS=$(grep -E 'instructions' /tmp/stat.txt | head -1 | awk '{gsub(",","",$1); print $1}')
  IPC=$(grep -oE '[0-9.]+ *insn per cycle' /tmp/stat.txt | grep -oE '^[0-9.]+')

  SOFT=$(grep -E '^Average' /tmp/soft.txt | tail -1 | awk '{print $(NF-4)}')   # %soft = 倒數第5欄(NF-4)
  PPS=$(grep -oE '[0-9]+pps' /tmp/pg.txt | head -1 | tr -d 'ps')

  echo "$BACKEND,$i,$SV,$FL,$MT,$HP,$OH_C,$OH_S,$MK_C,$MK_S,$CYC,$INS,$IPC,$SOFT,$PPS" | tee -a "$CSV"
  sudo rm -f /tmp/p.data
done

echo ">>> done: $BACKEND x $N 已寫入 $CSV"
echo ">>> 產 summary: python3 ovs_datapath_bench/scripts/summarize_dv3b.py"
