#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/jhash.h>
#include <linux/siphash.h>
#include <linux/math64.h>
#include <linux/preempt.h>
#include <asm/msr.h>

static int hash_type = 0;
static int input_len = 64;
static unsigned long iterations = 10000000;

module_param(hash_type, int, 0444);
MODULE_PARM_DESC(hash_type, "0=jhash2, 1=hsiphash, 2=siphash");

module_param(input_len, int, 0444);
MODULE_PARM_DESC(input_len, "Input length in bytes");

module_param(iterations, ulong, 0444);
MODULE_PARM_DESC(iterations, "Number of hash iterations");

static volatile u64 hash_sink;

static const hsiphash_key_t hkey = {
	.key = { 0x03020100U, 0x07060504U },
};

static void fill_test_buffer(u8 *buf, int len)
{
	int i;

	for (i = 0; i < len; i++)
		buf[i] = (u8)(i * 131 + 17);
}

static int run_jhash2_bench(u8 *buf)
{
	u64 start, end, total;
	u64 avg_x100;
	u64 acc = 0;
	u32 result = 0;
	u32 seed = 0xdeadbeef;
	unsigned long i;
	u32 words;

	if (input_len <= 0 || input_len % sizeof(u32) != 0) {
		pr_err("hash_microbench: input_len must be a positive multiple of 4\n");
		return -EINVAL;
	}

	if (iterations == 0) {
		pr_err("hash_microbench: iterations must be greater than 0\n");
		return -EINVAL;
	}

	words = input_len / sizeof(u32);

	preempt_disable();
	start = rdtsc_ordered();

	for (i = 0; i < iterations; i++) {
		result = jhash2((const u32 *)buf, words, seed + i);
		acc += result;
	}

	end = rdtsc_ordered();
	preempt_enable();

	hash_sink += acc;
	total = end - start;
	avg_x100 = div64_u64(total * 100, iterations);

	pr_info("hash_microbench: jhash2 input_len=%d iterations=%lu total_cycles=%llu cycles_per_hash=%llu.%02llu sink=%llu\n",
		input_len,
		iterations,
		total,
		avg_x100 / 100,
		avg_x100 % 100,
		hash_sink);

	return 0;
}

static int run_hsiphash_bench(u8 *buf)
{
	u64 start, end, total;
	u64 avg_x100;
	u64 acc = 0;
	u32 result = 0;
	unsigned long i;

	if (input_len <= 0) {
		pr_err("hash_microbench: input_len must be positive\n");
		return -EINVAL;
	}

	if (iterations == 0) {
		pr_err("hash_microbench: iterations must be greater than 0\n");
		return -EINVAL;
	}

	preempt_disable();
	start = rdtsc_ordered();

	for (i = 0; i < iterations; i++) {
		result = hsiphash(buf, input_len, &hkey);
		acc += result;
	}

	end = rdtsc_ordered();
	preempt_enable();

	hash_sink += acc;
	total = end - start;
	avg_x100 = div64_u64(total * 100, iterations);

	pr_info("hash_microbench: hsiphash input_len=%d iterations=%lu total_cycles=%llu cycles_per_hash=%llu.%02llu sink=%llu\n",
		input_len,
		iterations,
		total,
		avg_x100 / 100,
		avg_x100 % 100,
		hash_sink);

	return 0;
}

static int __init hash_microbench_init(void)
{
	u8 *buf;
	int ret;

	pr_info("hash_microbench: loaded\n");
	pr_info("hash_microbench: hash_type=%d input_len=%d iterations=%lu\n",
		hash_type, input_len, iterations);

	if (input_len <= 0) {
		pr_err("hash_microbench: input_len must be positive\n");
		return -EINVAL;
	}

	buf = kmalloc(input_len, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	fill_test_buffer(buf, input_len);

	switch (hash_type) {
	case 0:
		ret = run_jhash2_bench(buf);
		break;
	case 1:
		ret = run_hsiphash_bench(buf);
		break;
	case 2:
		pr_err("hash_microbench: hash_type=2 (siphash) is not implemented in v4\n");
		ret = -EINVAL;
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