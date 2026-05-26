# Experiment 1: Linux Kernel Hash Microbenchmark

This repository contains the first-stage microbenchmark for the final project:

**Linux Kernel Hash Function Design: Mathematical Foundations and Security-Performance Trade-offs**

The goal of this experiment is to measure the cost of Linux kernel hash functions before modifying the Open vSwitch datapath. The benchmark compares `jhash2()`, `hsiphash()`, and `siphash()` under different input lengths.

## Experiment Scope

This repository currently completes **Experiment 1: kernel-side hash microbenchmark**.

Measured metrics:

- cycles per hash
- instructions per hash
- branch misses per hash
- cache misses per hash

The benchmark is implemented as an out-of-tree Linux kernel module. The module runs the selected hash function inside `module_init()` and prints in-kernel timing results to `dmesg`. Hardware performance counters are collected externally using `perf stat`.

## Files

| File | Purpose |
|---|---|
| `Makefile` | Out-of-tree kernel module build file |
| `hash_microbench.c` | Kernel module benchmark implementation |
| `scripts/run_bench.sh` | Earlier cycles/hash benchmark automation |
| `scripts/parse_results.py` | Parser for earlier cycles/hash logs |
| `scripts/summarize_results.py` | Summary script for earlier cycles/hash results |
| `scripts/run_perf_grouped.sh` | Formal grouped perf counter benchmark |
| `scripts/summarize_perf_grouped.py` | Summary script for grouped perf results |
| `results/` | Raw logs, CSV files, and summary tables |

## Environment

Current test environment:

| Item | Value |
|---|---|
| OS | Ubuntu 22.04.5 LTS |
| Kernel | Linux 6.8.0-111-generic |
| Architecture | x86_64 |
| CPU | Intel Core i5-10500 @ 3.10GHz |
| Compiler | GCC 12.3.0 |
| Module type | out-of-tree loadable kernel module |
| Internal timing | `rdtsc_ordered()` |
| External counters | `perf stat` |

## Build

```bash
make clean
make
````

Expected output:

```text
hash_microbench.ko
```

The following warnings are acceptable and do not indicate build failure:

```text
warning: the compiler differs from the one used to build the kernel
Skipping BTF generation ... due to unavailability of vmlinux
```

## Smoke Test

Run one benchmark manually:

```bash
sudo dmesg -C
sudo insmod ./hash_microbench.ko hash_type=0 input_len=64 iterations=1000000
sudo rmmod hash_microbench
sudo dmesg | grep "hash_microbench:"
```

Expected output format:

```text
hash_microbench: loaded
hash_microbench: hash_type=0 input_len=64 iterations=1000000
hash_microbench: jhash2 input_len=64 iterations=1000000 total_cycles=... cycles_per_hash=... sink=...
hash_microbench: unloaded
```

## Module Parameters

| Parameter     | Meaning                                          |
| ------------- | ------------------------------------------------ |
| `hash_type=0` | Run `jhash2()`                                   |
| `hash_type=1` | Run `hsiphash()`                                 |
| `hash_type=2` | Run `siphash()` and fold 64-bit output to 32-bit |
| `input_len`   | Input buffer length in bytes                     |
| `iterations`  | Number of hash loop iterations                   |

## Hash Function Details

### jhash2

`jhash2()` takes a `const u32 *` input and its length is measured in 32-bit words, not bytes.

```c
words = input_len / sizeof(u32);
result = jhash2((const u32 *)buf, words, seed);
```

Therefore, `input_len` must be a positive multiple of 4.

### hsiphash

`hsiphash()` takes a byte buffer and byte length:

```c
result = hsiphash(buf, input_len, &hkey);
```

It returns a 32-bit hash value.

### siphash

`siphash()` returns a 64-bit value. Since the OVS-like hash interface uses a 32-bit hash value, the benchmark folds the high and low 32-bit halves:

```c
u64 h = siphash(buf, input_len, &skey);
u32 folded = (u32)h ^ (u32)(h >> 32);
```

The folding cost is included in the timed region.

## Timing Method

The kernel module measures the hash loop with one timing window:

```c
start = rdtsc_ordered();

for (i = 0; i < iterations; i++) {
    result = hash(...);
    acc += result;
}

end = rdtsc_ordered();
```

Then:

```text
total_cycles = end - start
cycles_per_hash = total_cycles / iterations
```

Interpretation:

```text
iterations = number of hash function calls
total_cycles = total CPU cycles consumed by the whole hash loop
cycles_per_hash = average CPU cycles per hash call
```

## Formal Perf Benchmark

Run the formal grouped perf benchmark:

```bash
chmod +x scripts/run_perf_grouped.sh
make clean
make
./scripts/run_perf_grouped.sh
```

Formal benchmark matrix:

```text
Hash functions: jhash2, hsiphash, siphash
Input lengths: 16, 32, 64, 128, 256 bytes
Iterations: 10,000,000
Repeats: 10
Event groups:
  core   = cycles,instructions
  branch = branches,branch-misses
  cache  = cache-references,cache-misses
```

Total runs:

```text
3 hash functions × 5 input lengths × 10 repeats × 3 event groups = 450 perf runs
```

Event grouping is used to reduce hardware counter multiplexing. The raw perf log showed `100.00%` counted percentage for measured events after grouping.

## Summarize Results

```bash
chmod +x scripts/summarize_perf_grouped.py

./scripts/summarize_perf_grouped.py \
  results/v8_perf_grouped_<timestamp>.csv \
  results/v8_perf_grouped_<timestamp>
```

This generates pivot tables for:

* cycles per hash
* instructions per hash
* branch misses per hash
* cache misses per hash

## Current v8 Result Summary

### Cycles per hash

| Input length |  jhash2 | hsiphash | siphash |
| -----------: | ------: | -------: | ------: |
|           16 |  16.712 |   28.554 |  45.376 |
|           32 |  26.869 |   38.341 |  64.480 |
|           64 |  61.426 |   57.203 | 101.947 |
|          128 | 119.872 |   95.860 | 174.763 |
|          256 | 249.810 |  171.048 | 324.874 |

### Instructions per hash

| Input length |   jhash2 | hsiphash |   siphash |
| -----------: | -------: | -------: | --------: |
|           16 |  83.3841 | 148.3923 |  207.4183 |
|           32 | 118.3891 | 190.4117 |  279.4423 |
|           64 | 235.4635 | 274.4387 |  423.5020 |
|          128 | 422.5506 | 442.5090 |  711.6016 |
|          256 | 843.7541 | 778.6210 | 1287.8416 |

### Branch misses per hash

| Input length |   jhash2 | hsiphash |  siphash |
| -----------: | -------: | -------: | -------: |
|           16 | 0.001924 | 0.002005 | 0.002126 |
|           32 | 0.001985 | 0.002163 | 0.002212 |
|           64 | 0.002653 | 0.002183 | 0.002759 |
|          128 | 0.003056 | 0.002452 | 0.003606 |
|          256 | 0.003757 | 0.003457 | 0.004906 |

### Cache misses per hash

| Input length |   jhash2 | hsiphash |  siphash |
| -----------: | -------: | -------: | -------: |
|           16 | 0.008311 | 0.008926 | 0.009173 |
|           32 | 0.009374 | 0.009937 | 0.009592 |
|           64 | 0.008803 | 0.009353 | 0.010399 |
|          128 | 0.010604 | 0.010418 | 0.010648 |
|          256 | 0.011192 | 0.010811 | 0.011560 |

## Interpretation

The grouped perf results show that `siphash()` has the highest cycles/hash and instructions/hash across all tested input lengths. Branch misses and cache misses remain low and similar among `jhash2()`, `hsiphash()`, and `siphash()`.

Therefore, in this microbenchmark, the main performance difference is better explained by instruction count and hash computation complexity rather than branch prediction failure or cache locality.

`hsiphash()` has lower cycles/hash than `jhash2()` for longer inputs in this benchmark. This is reported as an observation, not as a universal conclusion, because cycles are affected by instruction-level parallelism, pipeline behavior, compiler implementation path, and CPU execution characteristics.

## Current Status

| Version | Purpose                                             | Result                                                                 |
| ------- | --------------------------------------------------- | ---------------------------------------------------------------------- |
| v1      | minimal module lifecycle                            | `loaded / unloaded` success                                            |
| v2      | module parameters                                   | `hash_type / input_len / iterations` printed correctly                 |
| v3      | `jhash2()` benchmark                                | printed `total_cycles / cycles_per_hash / sink`                        |
| v4      | `hsiphash()` benchmark                              | `hash_type=1` works                                                    |
| v5      | `siphash()` benchmark with 64-bit to 32-bit folding | `hash_type=2` works                                                    |
| v6      | automated cycles/hash benchmark                     | completed 3 hashes × 5 input lengths × 5 repeats                       |
| v7      | initial perf counter benchmark                      | collected perf counters, but earlier version still risked multiplexing |
| v8      | grouped perf counter benchmark                      | completed 3 hashes × 5 input lengths × 10 repeats × 3 event groups     |

## Next Steps

* Analyze scaling trend with input length.
* Compare the microbenchmark result with OVS `flow_hash()` usage.
* Implement OVS flow hash replacement path.
* Evaluate OVS datapath throughput, CPU usage, and lookup behavior.
* Analyze bucket distribution and collision behavior.