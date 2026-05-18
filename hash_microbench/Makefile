# SPDX-License-Identifier: GPL-2.0
#
# hash_microbench: out-of-tree kernel module for benchmarking
#   jhash2 / hsiphash / siphash.
#
# Build:    make
# Clean:    make clean
# Load:     sudo insmod hash_microbench.ko hash_type=0 input_len=64 iterations=10000000
# Unload:   sudo rmmod hash_microbench
# Output:   sudo dmesg | grep HMB

obj-m += hash_microbench.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean
