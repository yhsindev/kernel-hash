#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>

static int __init hash_microbench_init(void)
{
	pr_info("hash_microbench: loaded\n");
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
