#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Sweep (hash_type, input_len) × repeats, capturing:
#   - in-kernel cycles/hash (from `dmesg | grep HMB,`)
#   - external HW counters (from `perf stat`)
#
# Run as root:   sudo ./run_all.sh
# Output: results/dmesg.csv  results/perf.csv

set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

MOD=hash_microbench
KO=./${MOD}.ko
RESULTS=results
ITER=${ITER:-10000000}
REPEATS=${REPEATS:-5}
HASH_TYPES=(0 1 2)
HASH_NAMES=(jhash2 hsiphash siphash)
# 掃描的輸入長度(bytes)。預設為實驗一的長度序列;可由環境變數覆寫,例如量
# OVS 真實 megaflow 長度時:INPUT_LENS="88 160" ./run_all.sh
#   88  = stateless IPv4 的 masked-key 長度
#   160 = 走 conntrack(stateful ACL)post-ct 的 masked-key 長度
#   (見 docs/exp2_ovn_report.md)
# 各長度量到的是 per-call 成本;真實部署要不要把不同長度加權合併,取決於部署
# 型態(例:雙向 stateful ACL 下 88:160 ≈ 1:2),屬後續分析,不在此預設。
read -ra INPUT_LENS <<< "${INPUT_LENS:-16 32 64 128 256}"
PERF_EVENTS=cycles,instructions,branch-misses,cache-misses

if [ ! -f "$KO" ]; then
    echo "Module not built. Run: make" >&2
    exit 1
fi

mkdir -p "$RESULTS"
DMESG_CSV="$RESULTS/dmesg.csv"
PERF_CSV="$RESULTS/perf.csv"
PERF_RAW_DIR="$RESULTS/perf_raw"
mkdir -p "$PERF_RAW_DIR"

# CSV headers
echo "hash,input_len,iterations,total_cycles,cycles_per_hash,checksum,repeat" > "$DMESG_CSV"
echo "hash,input_len,repeat,cycles,instructions,branch_misses,cache_misses" > "$PERF_CSV"

# Ensure module is unloaded from any previous run
rmmod $MOD 2>/dev/null || true

# Hygiene: lock CPU frequency to maximum, disable NMI watchdog
if command -v cpupower >/dev/null 2>&1; then
    cpupower frequency-set -g performance >/dev/null || \
        echo "warn: cpupower governor set failed (continuing)"
fi
echo 0 > /proc/sys/kernel/nmi_watchdog || \
    echo "warn: could not disable nmi_watchdog (continuing)"

total_runs=$((REPEATS * ${#HASH_TYPES[@]} * ${#INPUT_LENS[@]}))
run_idx=0

for repeat in $(seq 1 $REPEATS); do
    for i in "${!HASH_TYPES[@]}"; do
        hash_type=${HASH_TYPES[$i]}
        name=${HASH_NAMES[$i]}
        for input_len in "${INPUT_LENS[@]}"; do
            run_idx=$((run_idx + 1))
            echo "[$run_idx/$total_runs] repeat=$repeat hash=$name input_len=$input_len iter=$ITER"

            dmesg -C
            perf_tmp="$PERF_RAW_DIR/${name}-${input_len}-r${repeat}.txt"

            # perf stat -a (system-wide) over the insmod+rmmod window.
            # -x , gives a comma-separated machine-readable format.
            perf stat -a -x , -e "$PERF_EVENTS" -o "$perf_tmp" -- \
                bash -c "insmod $KO hash_type=$hash_type input_len=$input_len iterations=$ITER && rmmod $MOD" \
                2>/dev/null || {
                    echo "  WARN: perf stat invocation failed for repeat=$repeat hash=$name input_len=$input_len"
                    continue
                }

            # Pull events out of perf CSV. Columns: value,unit,event,...
            cyc=$(awk -F, '$3=="cycles"{print $1; exit}' "$perf_tmp")
            ins=$(awk -F, '$3=="instructions"{print $1; exit}' "$perf_tmp")
            brm=$(awk -F, '$3=="branch-misses"{print $1; exit}' "$perf_tmp")
            cmm=$(awk -F, '$3=="cache-misses"{print $1; exit}' "$perf_tmp")
            echo "$name,$input_len,$repeat,${cyc:--1},${ins:--1},${brm:--1},${cmm:--1}" >> "$PERF_CSV"

            # 從模組 pr_info 取數值。實際格式(非 HMB, CSV):
            #   hash_microbench: <name> input_len=N iterations=N total_cycles=N cycles_per_hash=N.NN sink=N
            line=$(dmesg | grep -E "hash_microbench: (jhash2|hsiphash|siphash) input_len=" | tail -n1 || true)
            if [ -n "$line" ]; then
                il=$(grep -oE 'input_len=[0-9]+'         <<<"$line" | cut -d= -f2)
                it=$(grep -oE 'iterations=[0-9]+'        <<<"$line" | cut -d= -f2)
                tc=$(grep -oE 'total_cycles=[0-9]+'      <<<"$line" | cut -d= -f2)
                cph=$(grep -oE 'cycles_per_hash=[0-9.]+' <<<"$line" | cut -d= -f2)
                echo "$name,$il,$it,$tc,$cph,NA,$repeat" >> "$DMESG_CSV"
            else
                echo "  WARN: no hash_microbench result line in dmesg"
            fi
        done
    done
done

echo
echo "===== Done ====="
echo "In-kernel cycles:  $DMESG_CSV"
echo "Perf HW counters:  $PERF_CSV"
echo "Raw perf output:   $PERF_RAW_DIR/"
echo
echo "Next:  python3 parse_results.py"
