#!/usr/bin/env bash
set -euo pipefail

# v7 perf counter benchmark for hash_microbench.ko
# hash_type:
#   0 = jhash2
#   1 = hsiphash
#   2 = siphash folded to u32

ITERATIONS=10000000
REPEATS=5
HASH_TYPES=(0 1 2)
INPUT_LENS=(16 32 64 128 256)

MODULE="./hash_microbench.ko"
RESULT_DIR="results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${RESULT_DIR}/v7_perf_${TIMESTAMP}.log"

EVENTS="cycles,instructions,branches,branch-misses,cache-references,cache-misses"

mkdir -p "${RESULT_DIR}"

if [[ ! -f "${MODULE}" ]]; then
	echo "Error: ${MODULE} not found. Run 'make' first."
	exit 1
fi

echo "hash_microbench v7 perf benchmark" | tee -a "${OUT}"
echo "timestamp=${TIMESTAMP}" | tee -a "${OUT}"
echo "iterations=${ITERATIONS}" | tee -a "${OUT}"
echo "repeats=${REPEATS}" | tee -a "${OUT}"
echo "input_lens=${INPUT_LENS[*]}" | tee -a "${OUT}"
echo "hash_types=${HASH_TYPES[*]}" | tee -a "${OUT}"
echo "events=${EVENTS}" | tee -a "${OUT}"
echo "" | tee -a "${OUT}"

for repeat in $(seq 1 "${REPEATS}"); do
	for hash_type in "${HASH_TYPES[@]}"; do
		for len in "${INPUT_LENS[@]}"; do
			echo "=== repeat=${repeat} hash_type=${hash_type} len=${len} ===" | tee -a "${OUT}"

			sudo dmesg -C

			# perf stat writes results to stderr, so redirect both stdout and stderr.
			sudo perf stat \
				-e "${EVENTS}" \
				sudo insmod "${MODULE}" \
					hash_type="${hash_type}" \
					input_len="${len}" \
					iterations="${ITERATIONS}" \
				2>&1 | tee -a "${OUT}"

			sudo rmmod hash_microbench

			echo "--- dmesg ---" | tee -a "${OUT}"
			sudo dmesg | grep "hash_microbench:" | tee -a "${OUT}"
			echo "" | tee -a "${OUT}"
		done
	done
done

echo "Saved results to ${OUT}"