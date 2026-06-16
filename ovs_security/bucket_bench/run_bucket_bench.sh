#!/usr/bin/env bash
#
# run_bucket_bench.sh — sweep {jhash2,hsiphash,siphash} × {random,structured,collision-vs-jhash}
# 把每次 insmod 的 HTB 輸出收進一個 raw 檔,供 parse_bucket_bench.py 計算。
#
# Run as root:  sudo ./run_bucket_bench.sh
# 可由環境變數覆寫:N_KEYS / N_BUCKETS / KEY_LEN / RNG_SEED / OUT
#
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
cd "$(dirname "$0")"

MOD=hash_table_bench
KO=./$MOD.ko
N_KEYS=${N_KEYS:-4096}
N_BUCKETS=${N_BUCKETS:-4096}
KEY_LEN=${KEY_LEN:-16}
RNG_SEED=${RNG_SEED:-305419896}   # 0x12345678
OUT=${OUT:-results}

[ -f "$KO" ] || { echo "module not built — run: make" >&2; exit 1; }
mkdir -p "$OUT"
RAW="$OUT/bucket_bench_raw.txt"
: > "$RAW"
{
	echo "# bucket_bench sweep  n=$N_KEYS m=$N_BUCKETS key_len=$KEY_LEN seed=$RNG_SEED"
} >> "$RAW"

HN=(jhash2 hsiphash siphash)
MN=(random seq_ip fixed_dst vary_srcport collision-vs-jhash)

rmmod "$MOD" 2>/dev/null || true
for mode in 0 1 2 3 4; do
	for ht in 0 1 2; do
		echo "== mode=${MN[$mode]} hash=${HN[$ht]} =="
		dmesg -C >/dev/null
		if ! insmod "$KO" hash_type=$ht n_keys=$N_KEYS n_buckets=$N_BUCKETS \
		     key_len=$KEY_LEN key_mode=$mode rng_seed=$RNG_SEED 2>/dev/null; then
			echo "  insmod failed (mode=$mode hash=$ht)"
			continue
		fi
		rmmod "$MOD" 2>/dev/null || true
		{
			echo "### mode=${MN[$mode]} hash=${HN[$ht]}"
			dmesg | grep -E 'collision-vs-jhash filled'   # q_offline 構造成本(tries)
			dmesg | grep -E 'HTB '
			dmesg | grep -E 'HTB_hist'
		} >> "$RAW"
	done
done

echo "[OK] raw -> $RAW"
echo "next: python3 parse_bucket_bench.py $RAW"
