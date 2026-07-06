#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/jhash.h>
#include <linux/siphash.h>
#include <linux/math64.h>
#include <linux/preempt.h>
#include <linux/irqflags.h>
#include <linux/sort.h>
#include <asm/msr.h>

/*
 * 量測效度硬化(對照舊 v6 run:hsiphash 在 16/32/128 std 高達 34.9):
 *   (1) 計時迴圈以 local_irq_save() 關中斷 —— preempt_disable() 只擋搶占/遷移,
 *       不擋硬體 IRQ;rdtsc 量 wall cycles,未遮蔽的 timer/裝置中斷會被算進取樣,
 *       單次即造成 +數十 cyc/hash 的 outlier。關 IRQ 使每趟乾淨。
 *   (3) 跑 trials 趟、各自獨立計時,回報 median(headline)/min/mean/max。median 與
 *       min 對單趟擾動穩健;另含一趟 warmup(丟棄)填 icache/dcache/branch predictor。
 * 注意:irq-off 窗 ≈ iterations × cyc/hash / freq,故 iterations 預設放小(5e4),
 * 避免長時間關中斷(掉 tick / 影響網路);量測請在 isolcpus + 鎖頻 + 閒置機器上跑。
 */

static int hash_type = 0;
static int input_len = 64;
static unsigned long iterations = 50000;   /* 每趟迭代數;放小以縮短 irq-off 窗 */
static int trials = 25;                     /* 計時趟數;回報 min/median/mean/max */

module_param(hash_type, int, 0444);
MODULE_PARM_DESC(hash_type, "0=jhash2, 1=hsiphash, 2=siphash");
module_param(input_len, int, 0444);
MODULE_PARM_DESC(input_len, "Input length in bytes");
module_param(iterations, ulong, 0444);
MODULE_PARM_DESC(iterations, "Hash iterations per trial");
module_param(trials, int, 0444);
MODULE_PARM_DESC(trials, "Number of timed trials (report min/median/mean/max)");

#define MAX_TRIALS 64

static volatile u64 hash_sink;

static const hsiphash_key_t hkey = {
	.key = { 0x03020100U, 0x07060504U },
};

static const siphash_key_t skey = {
	.key = { 0x0706050403020100ULL, 0x0f0e0d0c0b0a0908ULL },
};

static void fill_test_buffer(u8 *buf, int len)
{
	int i;

	for (i = 0; i < len; i++)
		buf[i] = (u8)(i * 131 + 17);
}

/*
 * 每趟:關中斷下對指定雜湊函式跑 iterations 次,回傳該趟 total_cycles。
 * 三個雜湊各一支,避免在熱迴圈內以分支選擇而污染量測(尤其最便宜的 jhash2)。
 */
static u64 trial_jhash2(const u8 *buf)
{
	u64 start, end, acc = 0;
	u32 words = (u32)input_len / sizeof(u32);
	unsigned long i, flags;

	local_irq_save(flags);
	start = rdtsc_ordered();
	for (i = 0; i < iterations; i++)
		acc += jhash2((const u32 *)buf, words, 0xdeadbeef);
	end = rdtsc_ordered();
	local_irq_restore(flags);

	hash_sink += acc;
	return end - start;
}

static u64 trial_hsiphash(const u8 *buf)
{
	u64 start, end, acc = 0;
	unsigned long i, flags;

	local_irq_save(flags);
	start = rdtsc_ordered();
	for (i = 0; i < iterations; i++)
		acc += hsiphash(buf, input_len, &hkey);
	end = rdtsc_ordered();
	local_irq_restore(flags);

	hash_sink += acc;
	return end - start;
}

static u64 trial_siphash(const u8 *buf)
{
	u64 start, end, acc = 0, h;
	unsigned long i, flags;

	local_irq_save(flags);
	start = rdtsc_ordered();
	for (i = 0; i < iterations; i++) {
		h = siphash(buf, input_len, &skey);
		acc += (u32)h ^ (u32)(h >> 32);   /* 折成 OVS 32-bit,計入折疊成本 */
	}
	end = rdtsc_ordered();
	local_irq_restore(flags);

	hash_sink += acc;
	return end - start;
}

static int cmp_u64(const void *a, const void *b)
{
	u64 x = *(const u64 *)a, y = *(const u64 *)b;

	return (x > y) - (x < y);
}

static int run_bench(const u8 *buf, const char *name, u64 (*trial)(const u8 *))
{
	u64 perc[MAX_TRIALS];   /* 每趟 cycles_per_hash ×100 */
	u64 sum = 0, mn, md, mean, mx;
	int t;

	if (trials < 1 || trials > MAX_TRIALS) {
		pr_err("hash_microbench: trials must be 1..%d\n", MAX_TRIALS);
		return -EINVAL;
	}

	trial(buf);   /* warmup:丟棄,填 icache/dcache/branch predictor */

	for (t = 0; t < trials; t++) {
		perc[t] = div64_u64(trial(buf) * 100, iterations);
		sum += perc[t];
	}

	sort(perc, trials, sizeof(perc[0]), cmp_u64, NULL);
	mn = perc[0];
	mx = perc[trials - 1];
	md = perc[trials / 2];
	mean = div64_u64(sum, trials);

	/* headline cycles_per_hash = median(抗單趟擾動);min/mean/max 供判讀量測效度。 */
	pr_info("hash_microbench: %s input_len=%d iterations=%lu trials=%d cycles_per_hash=%llu.%02llu min=%llu.%02llu mean=%llu.%02llu max=%llu.%02llu sink=%llu\n",
		name, input_len, iterations, trials,
		md / 100, md % 100, mn / 100, mn % 100,
		mean / 100, mean % 100, mx / 100, mx % 100, hash_sink);

	return 0;
}

static int __init hash_microbench_init(void)
{
	u8 *buf;
	int ret;

	pr_info("hash_microbench: loaded\n");
	pr_info("hash_microbench: hash_type=%d input_len=%d iterations=%lu trials=%d\n",
		hash_type, input_len, iterations, trials);

	if (input_len <= 0) {
		pr_err("hash_microbench: input_len must be positive\n");
		return -EINVAL;
	}
	if (iterations == 0) {
		pr_err("hash_microbench: iterations must be greater than 0\n");
		return -EINVAL;
	}
	if (hash_type == 0 && input_len % sizeof(u32) != 0) {
		pr_err("hash_microbench: jhash2 needs input_len a multiple of 4\n");
		return -EINVAL;
	}

	buf = kmalloc(input_len, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	fill_test_buffer(buf, input_len);

	switch (hash_type) {
	case 0:
		ret = run_bench(buf, "jhash2", trial_jhash2);
		break;
	case 1:
		ret = run_bench(buf, "hsiphash", trial_hsiphash);
		break;
	case 2:
		ret = run_bench(buf, "siphash", trial_siphash);
		break;
	default:
		pr_err("hash_microbench: invalid hash_type=%d\n", hash_type);
		ret = -EINVAL;
		break;
	}

	kfree(buf);
	return ret;
}

static void __exit hash_microbench_exit(void)
{
	pr_info("hash_microbench: unloaded\n");
}

module_init(hash_microbench_init);
module_exit(hash_microbench_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("yhsindev");
MODULE_DESCRIPTION("Microbenchmark for Linux kernel hash functions");
