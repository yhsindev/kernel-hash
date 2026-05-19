#!/usr/bin/env bash
set -euo pipefail

# v6 benchmark automation for hash_microbench.ko
# Hash type:
#   0 = jhash2
#   1 = hsiphash
#   2 = siphash folded to u32

ITERATIONS=1000000
REPEATS=5
HASH_TYPES=(0 1 2)
INPUT_LENS=(16 32 64 128 256)

MODULE="./hash_microbench.ko"
RESULT_DIR="results"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUT="${RESULT_DIR}/v6_all_hashes_${TIMESTAMP}.log"

mkdir -p "${RESULT_DIR}"

if [[ ! -f "${MODULE}" ]]; then
	echo "Error: ${MODULE} not found. Run 'make' first."
	exit 1
fi

echo "hash_microbench v6 benchmark" | tee -a "${OUT}"
echo "timestamp=${TIMESTAMP}" | tee -a "${OUT}"
echo "iterations=${ITERATIONS}" | tee -a "${OUT}"
echo "repeats=${REPEATS}" | tee -a "${OUT}"
echo "input_lens=${INPUT_LENS[*]}" | tee -a "${OUT}"
echo "hash_types=${HASH_TYPES[*]}" | tee -a "${OUT}"
echo "" | tee -a "${OUT}"

for repeat in $(seq 1 "${REPEATS}"); do
	for hash_type in "${HASH_TYPES[@]}"; do
		for len in "${INPUT_LENS[@]}"; do
			echo "=== repeat=${repeat} hash_type=${hash_type} len=${len} ===" | tee -a "${OUT}"

			# Clear kernel log so each run only records its own output.
			sudo dmesg -C

			sudo insmod "${MODULE}" \
				hash_type="${hash_type}" \
				input_len="${len}" \
				iterations="${ITERATIONS}"

			sudo rmmod hash_microbench

			sudo dmesg | grep "hash_microbench:" | tee -a "${OUT}"
			echo "" | tee -a "${OUT}"
		done
	done
done

echo "Saved results to ${OUT}"
