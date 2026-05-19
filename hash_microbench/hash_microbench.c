#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/jhash.h>
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

static void fill_test_buffer(u8 *buf, int len)
{
	int i;

	for (i = 0; i < len; i++)
		buf[i] = (u8)(i * 131 + 17);
}

static int run_jhash2_bench(u8 *buf)
{
	u64 start, end, total;
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
		hash_sink += result;
	}

	end = rdtsc_ordered();
	preempt_enable();

	total = end - start;

	pr_info("hash_microbench: jhash2 input_len=%d iterations=%lu total_cycles=%llu cycles_per_hash=%llu sink=%llu\n",
		input_len,
		iterations,
		total,
		div64_u64(total, iterations),
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

	if (hash_type != 0) {
		pr_err("hash_microbench: only hash_type=0 (jhash2) is implemented in v3\n");
		return -EINVAL;
	}

	buf = kmalloc(input_len, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	fill_test_buffer(buf, input_len);
	ret = run_jhash2_bench(buf);

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