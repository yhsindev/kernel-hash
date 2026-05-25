#!/usr/bin/env bash
set -euo pipefail

# v8 grouped perf counter benchmark for hash_microbench.ko
# hash_type:
#   0 = jhash2
#   1 = hsiphash
#   2 = siphash folded to u32

ITERATIONS=10000000
REPEATS=10
HASH_TYPES=(0 1 2)
INPUT_LENS=(16 32 64 128 256)

MODULE="./hash_microbench.ko"
RESULT_DIR="results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

RAW_LOG="${RESULT_DIR}/v8_perf_grouped_${TIMESTAMP}.raw.log"
CSV_OUT="${RESULT_DIR}/v8_perf_grouped_${TIMESTAMP}.csv"

mkdir -p "${RESULT_DIR}"

if [[ ! -f "${MODULE}" ]]; then
	echo "Error: ${MODULE} not found. Run 'make' first."
	exit 1
fi

cat > "${CSV_OUT}" <<EOF
repeat,group,hash_type,hash_name,input_len,iterations,module_total_cycles,module_cycles_per_hash,perf_cycles,perf_instructions,perf_branches,perf_branch_misses,perf_cache_references,perf_cache_misses,instructions_per_hash,branch_misses_per_hash,cache_misses_per_hash
EOF

{
	echo "hash_microbench v8 grouped perf benchmark"
	echo "timestamp=${TIMESTAMP}"
	echo "iterations=${ITERATIONS}"
	echo "repeats=${REPEATS}"
	echo "input_lens=${INPUT_LENS[*]}"
	echo "hash_types=${HASH_TYPES[*]}"
	echo "event_groups=core,branch,cache"
	echo ""
} | tee -a "${RAW_LOG}"

run_one_group() {
	local repeat="$1"
	local group="$2"
	local events="$3"
	local hash_type="$4"
	local len="$5"

	echo "=== repeat=${repeat} group=${group} hash_type=${hash_type} len=${len} ===" | tee -a "${RAW_LOG}"

	sudo dmesg -C

	local perf_tmp
	local dmesg_tmp
	perf_tmp="$(mktemp)"
	dmesg_tmp="$(mktemp)"

	sudo perf stat \
	-x, \
	-e "${events}" \
	-- insmod "${MODULE}" \
		hash_type="${hash_type}" \
		input_len="${len}" \
		iterations="${ITERATIONS}" \
	2> "${perf_tmp}"

	sudo rmmod hash_microbench

	sudo dmesg | grep "hash_microbench:" > "${dmesg_tmp}" || true

	echo "--- perf stat (${group}) ---" | tee -a "${RAW_LOG}"
	cat "${perf_tmp}" | tee -a "${RAW_LOG}"

	echo "--- dmesg ---" | tee -a "${RAW_LOG}"
	cat "${dmesg_tmp}" | tee -a "${RAW_LOG}"

	python3 - "$repeat" "$group" "$hash_type" "$len" "$ITERATIONS" "$perf_tmp" "$dmesg_tmp" "$CSV_OUT" <<'PY'
import csv
import re
import sys

repeat = int(sys.argv[1])
group = sys.argv[2]
hash_type = sys.argv[3]
input_len = int(sys.argv[4])
iterations = int(sys.argv[5])
perf_path = sys.argv[6]
dmesg_path = sys.argv[7]
csv_path = sys.argv[8]

hash_type_to_name = {
    "0": "jhash2",
    "1": "hsiphash",
    "2": "siphash",
}

events = {
    "cycles": "",
    "instructions": "",
    "branches": "",
    "branch-misses": "",
    "cache-references": "",
    "cache-misses": "",
}

def clean_num(s):
    s = s.strip().replace(",", "")
    if s in ("", "<not counted>", "<not supported>"):
        return ""
    try:
        return int(float(s))
    except ValueError:
        return ""

with open(perf_path, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        parts = line.strip().split(",")
        if len(parts) < 3:
            continue
        value = clean_num(parts[0])
        event = parts[2].strip()
        if event in events:
            events[event] = value

module_total_cycles = ""
module_cycles_per_hash = ""
hash_name = hash_type_to_name.get(hash_type, "unknown")

dmesg_re = re.compile(
    r"hash_microbench: (jhash2|hsiphash|siphash) "
    r"input_len=(\d+) iterations=(\d+) "
    r"total_cycles=(\d+) cycles_per_hash=([0-9.]+)"
)

with open(dmesg_path, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        m = dmesg_re.search(line)
        if m:
            hash_name = m.group(1)
            module_total_cycles = int(m.group(4))
            module_cycles_per_hash = float(m.group(5))

def per_hash(value):
    if value == "":
        return ""
    return value / iterations

row = {
    "repeat": repeat,
    "group": group,
    "hash_type": hash_type,
    "hash_name": hash_name,
    "input_len": input_len,
    "iterations": iterations,
    "module_total_cycles": module_total_cycles,
    "module_cycles_per_hash": module_cycles_per_hash,
    "perf_cycles": events["cycles"],
    "perf_instructions": events["instructions"],
    "perf_branches": events["branches"],
    "perf_branch_misses": events["branch-misses"],
    "perf_cache_references": events["cache-references"],
    "perf_cache_misses": events["cache-misses"],
    "instructions_per_hash": per_hash(events["instructions"]),
    "branch_misses_per_hash": per_hash(events["branch-misses"]),
    "cache_misses_per_hash": per_hash(events["cache-misses"]),
}

with open(csv_path, "a", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=list(row.keys()))
    writer.writerow(row)
PY

	rm -f "${perf_tmp}" "${dmesg_tmp}"
	echo "" | tee -a "${RAW_LOG}"
}

for repeat in $(seq 1 "${REPEATS}"); do
	for hash_type in "${HASH_TYPES[@]}"; do
		for len in "${INPUT_LENS[@]}"; do
			run_one_group "${repeat}" "core" "cycles,instructions" "${hash_type}" "${len}"
			run_one_group "${repeat}" "branch" "branches,branch-misses" "${hash_type}" "${len}"
			run_one_group "${repeat}" "cache" "cache-references,cache-misses" "${hash_type}" "${len}"
		done
	done
done

echo "Saved raw log to ${RAW_LOG}"
echo "Saved CSV to ${CSV_OUT}"
