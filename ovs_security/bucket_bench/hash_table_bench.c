// SPDX-License-Identifier: GPL-2.0
/*
 * hash_table_bench.c — Part 2：通用 hash-table bucket-load robustness harness
 *
 * 把 n 個 key 分進 m 個 bucket(B(x)=H(x) mod m),量 bucket-load 分布,比較
 * jhash2 / hsiphash / siphash 在不同 key set 下的 robustness。用核心真正的雜湊
 * 實作(與 Experiment 1 一致),不在 user-space 重刻。
 *
 * 與 OVS 無關 —— 這是 generic 主實驗;OVS flow table 是另外的 case study。
 *
 * 參數:
 *   hash_type : 0=jhash2(seed=0,同 OVS) 1=hsiphash 2=siphash
 *   n_buckets : m,須為 2 的次冪
 *   n_keys    : n
 *   key_len   : 每個 key 的 byte 數(須為 4 的倍數;jhash2 以 u32 字計)
 *   key_mode  : 0=random  1=structured(序列)  2=collision-vs-jhash
 *   rng_seed  : LCG 種子(可重現)
 *   target_bucket : key_mode=2 時,構造一組全部落此 bucket(在 jhash 下)的 key
 *
 * 輸出(dmesg,機器可讀):
 *   HTB hash=.. mode=.. n=.. m=.. key_len=.. Lmax=.. nonempty=.. collisions=.. expC=..
 *   HTB_hist load=<L> buckets=<#buckets with load L>   (僅印非零)
 * bucket entropy H_norm 由 user-space 從 HTB_hist 計算(核心不做 log)。
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/jhash.h>
#include <linux/siphash.h>
#include <asm/unaligned.h>

static int hash_type = 0;
static int n_buckets = 4096;
static int n_keys = 4096;
static int key_len = 16;
static int key_mode = 0;
static unsigned int rng_seed = 0x12345678u;
static int target_bucket;

module_param(hash_type, int, 0444);
MODULE_PARM_DESC(hash_type, "0=jhash2 1=hsiphash 2=siphash");
module_param(n_buckets, int, 0444);
MODULE_PARM_DESC(n_buckets, "number of buckets m (power of 2)");
module_param(n_keys, int, 0444);
MODULE_PARM_DESC(n_keys, "number of keys n");
module_param(key_len, int, 0444);
MODULE_PARM_DESC(key_len, "key length in bytes (multiple of 4)");
module_param(key_mode, int, 0444);
MODULE_PARM_DESC(key_mode, "0=random 1=seq_ip 2=fixed_dst 3=vary_srcport 4=collision-vs-jhash");
module_param(rng_seed, uint, 0444);
MODULE_PARM_DESC(rng_seed, "LCG seed for reproducibility");
module_param(target_bucket, int, 0444);
MODULE_PARM_DESC(target_bucket, "target bucket for key_mode=4 (collision-vs-jhash)");

/* 固定的「祕密」金鑰:代表攻擊者不知道的 key。collision set 是對 public jhash
 * 構造的;若 keyed hash 用此祕密金鑰仍把它打散,即證明攻擊者無法預測 keyed mapping。 */
static const hsiphash_key_t hkey = {
	.key = { 0x0706050403020100UL, 0x0f0e0d0c0b0a0908UL },
};
static const siphash_key_t skey = {
	.key = { 0x0706050403020100ULL, 0x0f0e0d0c0b0a0908ULL },
};

static u32 lcg_state;
static inline u32 lcg_next(void)
{
	lcg_state = lcg_state * 1664525u + 1013904223u;
	return lcg_state;
}

static const char *hash_name(void)
{
	switch (hash_type) {
	case 0: return "jhash2";
	case 1: return "hsiphash";
	case 2: return "siphash";
	}
	return "?";
}

/* 通用 5-tuple flow key 佈局(前 16 bytes):src_ip|dst_ip|src_port|dst_port|proto|pad。
 * 五個 key_mode 對應五組 flow set;變動單一欄位測雜湊 avalanche 是否把它打散。 */
enum { FK_SRC_IP = 0, FK_DST_IP = 4, FK_SRC_PORT = 8, FK_DST_PORT = 10, FK_PROTO = 12 };
static const u32 BASE_SRC_IP = 0x0a000001;  /* 10.0.0.1 */
static const u32 BASE_DST_IP = 0x0a000002;  /* 10.0.0.2 */
static const u16 BASE_SRC_PORT = 1024;
static const u16 BASE_DST_PORT = 80;
static const u8  BASE_PROTO = 6;            /* TCP */

/* bucket index under the selected hash */
static u32 bucket_of(const void *buf, int len)
{
	switch (hash_type) {
	case 1: return (u32)hsiphash(buf, len, &hkey) & (n_buckets - 1);
	case 2: return (u32)siphash(buf, len, &skey) & (n_buckets - 1);
	default: return jhash2((const u32 *)buf, len / 4, 0) & (n_buckets - 1);
	}
}

/* bucket index under jhash2 specifically (for the collision search; seed=0 = OVS) */
static u32 jbucket(const void *buf, int len)
{
	return jhash2((const u32 *)buf, len / 4, 0) & (n_buckets - 1);
}

/* 依 key_mode 產生第 idx 個 flow key(模式 0–3;模式 4 collision 另在 init 處理） */
static void fill_key(u8 *key, u32 idx)
{
	int i;

	memset(key, 0, key_len);
	switch (key_mode) {
	case 0: /* 隨機 flow:整把 key 隨機 */
		for (i = 0; i < key_len; i += 4)
			put_unaligned_le32(lcg_next(), key + i);
		break;
	case 1: /* 連續 IP flow:src_ip 遞增,其餘固定 */
		put_unaligned_be32(BASE_SRC_IP + idx, key + FK_SRC_IP);
		put_unaligned_be32(BASE_DST_IP, key + FK_DST_IP);
		put_unaligned_be16(BASE_SRC_PORT, key + FK_SRC_PORT);
		put_unaligned_be16(BASE_DST_PORT, key + FK_DST_PORT);
		key[FK_PROTO] = BASE_PROTO;
		break;
	case 2: /* 固定目的 IP:dst_ip 固定,src_ip / ports 隨機 */
		put_unaligned_le32(lcg_next(), key + FK_SRC_IP);
		put_unaligned_be32(BASE_DST_IP, key + FK_DST_IP);
		put_unaligned_le16((u16)lcg_next(), key + FK_SRC_PORT);
		put_unaligned_le16((u16)lcg_next(), key + FK_DST_PORT);
		key[FK_PROTO] = BASE_PROTO;
		break;
	case 3: /* 變動 source port:只有 src_port 遞增,其餘固定 */
		put_unaligned_be32(BASE_SRC_IP, key + FK_SRC_IP);
		put_unaligned_be32(BASE_DST_IP, key + FK_DST_IP);
		put_unaligned_be16((u16)(BASE_SRC_PORT + idx), key + FK_SRC_PORT);
		put_unaligned_be16(BASE_DST_PORT, key + FK_DST_PORT);
		key[FK_PROTO] = BASE_PROTO;
		break;
	}
}

static int __init htb_init(void)
{
	u32 *load, *hist;
	u8 *key;
	u32 b, Lmax = 0, nonempty = 0;
	u64 collisions = 0, expC;
	int i;

	if (key_len < 16 || key_len % 4 != 0) {
		pr_err("hash_table_bench: key_len must be >=16 and a multiple of 4 (5-tuple flow key)\n");
		return -EINVAL;
	}
	if (n_buckets <= 0 || (n_buckets & (n_buckets - 1)) != 0) {
		pr_err("hash_table_bench: n_buckets must be a power of 2\n");
		return -EINVAL;
	}
	if (n_keys <= 0)
		return -EINVAL;

	load = vzalloc((size_t)n_buckets * sizeof(u32));
	hist = vzalloc(((size_t)n_keys + 1) * sizeof(u32));
	key = kmalloc(key_len, GFP_KERNEL);
	if (!load || !hist || !key) {
		vfree(load); vfree(hist); kfree(key);
		return -ENOMEM;
	}
	lcg_state = rng_seed;

	if (key_mode == 4) {
		/* collision-vs-jhash:構造 n_keys 個在 jhash 下全落 target_bucket 的 key,
		 * 再用選定的 hash_type 分桶(jhash → 全擠一桶;keyed → 應散開)。 */
		u32 tb = (u32)target_bucket & (n_buckets - 1);
		u64 tries = 0, cap = (u64)n_keys * n_buckets * 64ULL;
		int filled = 0;

		while (filled < n_keys && tries < cap) {
			for (i = 0; i < key_len; i += 4)
				put_unaligned_le32(lcg_next(), key + i);
			tries++;
			if (jbucket(key, key_len) == tb) {
				load[bucket_of(key, key_len)]++;
				filled++;
			}
		}
		pr_info("hash_table_bench: collision-vs-jhash filled=%d/%d tries=%llu target=%u\n",
			filled, n_keys, tries, tb);
		if (filled < n_keys)
			pr_warn("hash_table_bench: search cap hit; partial set\n");
	} else {
		for (i = 0; i < n_keys; i++) {
			fill_key(key, (u32)i);
			load[bucket_of(key, key_len)]++;
		}
	}

	for (b = 0; b < (u32)n_buckets; b++) {
		u32 L = load[b];

		if (L) {
			nonempty++;
			if (L > Lmax)
				Lmax = L;
			collisions += (u64)L * (L - 1) / 2;
		}
		if (L <= (u32)n_keys)
			hist[L]++;
	}
	expC = (u64)n_keys * (n_keys - 1) / 2 / n_buckets;

	pr_info("HTB hash=%s mode=%d n=%d m=%d key_len=%d Lmax=%u nonempty=%u collisions=%llu expC=%llu\n",
		hash_name(), key_mode, n_keys, n_buckets, key_len,
		Lmax, nonempty, collisions, expC);
	for (i = 0; i <= (int)Lmax; i++)
		if (hist[i])
			pr_info("HTB_hist load=%d buckets=%u\n", i, hist[i]);

	vfree(load);
	vfree(hist);
	kfree(key);
	return 0;
}

static void __exit htb_exit(void)
{
	pr_info("hash_table_bench: unloaded\n");
}

module_init(htb_init);
module_exit(htb_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Generic hash-table bucket-load robustness harness (jhash2/hsiphash/siphash)");
