#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

static int hash_type = 0;
static int input_len = 64;
static unsigned long iterations = 10000000;

module_param(hash_type, int, 0444);
MODULE_PARM_DESC(hash_type, "0=jhash2, 1=hsiphash, 2=siphash");

module_param(input_len, int, 0444);
MODULE_PARM_DESC(input_len, "Input length in bytes");

module_param(iterations, ulong, 0444);
MODULE_PARM_DESC(iterations, "Number of hash iterations");

static int __init hash_microbench_init(void)
{
	pr_info("hash_microbench: loaded\n");
	pr_info("hash_microbench: hash_type=%d input_len=%d iterations=%lu\n",
		hash_type, input_len, iterations);
	return 0;
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