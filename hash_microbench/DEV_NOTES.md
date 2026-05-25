# hash_microbench — Dev Notes

## Project status

本專案目前完成 **Experiment 1: Linux kernel hash function microbenchmark**。

本階段目標是在修改 OVS datapath 前，先建立 Linux kernel hash function 本身的成本模型。實驗直接在 loadable kernel module 中重複執行 `jhash2()`、`hsiphash()` 與 `siphash()`，並量測不同 input length 下的：

* cycles per hash
* instructions per hash
* branch misses per hash
* cache misses per hash

目前正式結果採用 **v8 grouped perf benchmark**：

```text
Hash functions: jhash2, hsiphash, siphash
Input lengths: 16, 32, 64, 128, 256 bytes
Iterations: 10,000,000 per run
Repeats: 10
Perf event groups:
  core   = cycles,instructions
  branch = branches,branch-misses
  cache  = cache-references,cache-misses
```

使用 event grouping 的原因是避免一次量測過多 perf events 造成 hardware counter multiplexing。先前一次量測六個 events 時，perf output 中出現約 66%–83% counted percentage；分組量測後，raw log 中可觀察到 measured events 的 counted percentage 為 `100.00`，因此 v8 結果作為正式分析版本。

---

## Files

| File                                                         | Purpose                                                                                                           |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `Makefile`                                                   | out-of-tree kernel module Kbuild stub                                                                             |
| `hash_microbench.c`                                          | kernel module body; runs selected hash function in `module_init()` and prints in-kernel timing results to `dmesg` |
| `scripts/run_bench.sh`                                       | earlier cycles/hash automation script                                                                             |
| `scripts/parse_results.py`                                   | parses earlier v6 log into CSV                                                                                    |
| `scripts/summarize_results.py`                               | summarizes earlier v6 cycles/hash results                                                                         |
| `scripts/run_perf_grouped.sh`                                | v8 formal grouped perf benchmark script                                                                           |
| `scripts/summarize_perf_grouped.py`                          | summarizes v8 grouped perf CSV into pivot tables                                                                  |
| `results/v8_perf_grouped_*.raw.log`                          | raw perf stat + dmesg output                                                                                      |
| `results/v8_perf_grouped_*.csv`                              | structured grouped perf result                                                                                    |
| `results/v8_perf_grouped_*_pivot_cycles_per_hash.csv`        | cycles/hash pivot table                                                                                           |
| `results/v8_perf_grouped_*_pivot_instructions_per_hash.csv`  | instructions/hash pivot table                                                                                     |
| `results/v8_perf_grouped_*_pivot_branch_misses_per_hash.csv` | branch-misses/hash pivot table                                                                                    |
| `results/v8_perf_grouped_*_pivot_cache_misses_per_hash.csv`  | cache-misses/hash pivot table                                                                                     |
| `.gitignore`                                                 | excludes kernel build artifacts and temporary files                                                               |

---

## Environment

```bash
uname -a
cat /etc/os-release
lscpu | grep "Model name"
gcc --version | head -1
```

Current test environment:

| Item               | Value                                  |
| ------------------ | -------------------------------------- |
| OS                 | Ubuntu 22.04.5 LTS                     |
| Kernel             | Linux 6.8.0-111-generic                |
| Architecture       | x86_64                                 |
| CPU                | Intel Core i5-10500 @ 3.10GHz          |
| Compiler           | GCC 12.3.0                             |
| Module type        | out-of-tree loadable kernel module     |
| Main timing method | `rdtsc_ordered()` inside kernel module |
| External counters  | `perf stat`                            |

---

## Build

```bash
make clean
make
ls -l hash_microbench.ko
modinfo hash_microbench.ko | head -n 15
```

Expected result:

```text
hash_microbench.ko is generated
MODULE_LICENSE should be GPL
```

The following build messages are acceptable:

```text
warning: the compiler differs from the one used to build the kernel
Skipping BTF generation ... due to unavailability of vmlinux
```

They do not indicate build failure.

---

## Smoke test

### jhash2

```bash
sudo dmesg -C
sudo insmod ./hash_microbench.ko hash_type=0 input_len=64 iterations=1000000
sudo rmmod hash_microbench
sudo dmesg | grep "hash_microbench:"
```

### hsiphash

```bash
sudo dmesg -C
sudo insmod ./hash_microbench.ko hash_type=1 input_len=64 iterations=1000000
sudo rmmod hash_microbench
sudo dmesg | grep "hash_microbench:"
```

### siphash

```bash
sudo dmesg -C
sudo insmod ./hash_microbench.ko hash_type=2 input_len=64 iterations=1000000
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

---

## Module parameters

| Parameter     | Meaning                                          |
| ------------- | ------------------------------------------------ |
| `hash_type=0` | run `jhash2()`                                   |
| `hash_type=1` | run `hsiphash()`                                 |
| `hash_type=2` | run `siphash()` and fold 64-bit output to 32-bit |
| `input_len`   | input buffer length in bytes                     |
| `iterations`  | number of hash loop iterations                   |

---

## Hash implementation details

### jhash2

`jhash2()` takes a `const u32 *` input and its length is measured in 32-bit words, not bytes. Therefore:

```c
words = input_len / sizeof(u32);
result = jhash2((const u32 *)buf, words, seed);
```

The benchmark requires `input_len` to be a positive multiple of 4.

### hsiphash

`hsiphash()` takes a byte buffer and byte length:

```c
result = hsiphash(buf, input_len, &hkey);
```

It returns a 32-bit hash value.

### siphash

`siphash()` returns a 64-bit value, while the OVS-like hash interface uses a 32-bit value. Therefore the benchmark folds the high and low 32-bit halves:

```c
u64 h = siphash(buf, input_len, &skey);

/* Fold SipHash to OVS's 32-bit hash format; include folding cost. */
u32 folded = (u32)h ^ (u32)(h >> 32);
```

The folding cost is included in the timed region because it represents the practical conversion cost if SipHash is used in a 32-bit hash path.

---

## Timing design

The kernel module measures the hash loop using one timing window:

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

Example:

```text
iterations = 10,000,000
total_cycles = 626,940,594
cycles_per_hash = 626,940,594 / 10,000,000 = 62.69
```

This means:

```text
The benchmark called the hash function 10,000,000 times.
These 10,000,000 calls consumed 626,940,594 CPU cycles in total.
On average, each hash call consumed about 62.69 cycles.
```

The timing window includes:

```text
hash function call
loop control
local accumulator update
```

It does not include:

```text
module loading
kmalloc
buffer initialization
pr_info output
rmmod
```

---

## Full grouped perf benchmark

Run the formal v8 benchmark:

```bash
chmod +x scripts/run_perf_grouped.sh
make clean
make
./scripts/run_perf_grouped.sh
```

Formal v8 matrix:

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

Total number of perf runs:

```text
3 hash functions × 5 input lengths × 10 repeats × 3 event groups = 450 runs
```

Outputs:

```text
results/v8_perf_grouped_<timestamp>.raw.log
results/v8_perf_grouped_<timestamp>.csv
```

---

## Summarize v8 results

```bash
chmod +x scripts/summarize_perf_grouped.py

./scripts/summarize_perf_grouped.py \
  results/v8_perf_grouped_<timestamp>.csv \
  results/v8_perf_grouped_<timestamp>
```

This produces:

```text
results/v8_perf_grouped_<timestamp>_cycles_summary.csv
results/v8_perf_grouped_<timestamp>_instructions_summary.csv
results/v8_perf_grouped_<timestamp>_branch_misses_summary.csv
results/v8_perf_grouped_<timestamp>_cache_misses_summary.csv

results/v8_perf_grouped_<timestamp>_pivot_cycles_per_hash.csv
results/v8_perf_grouped_<timestamp>_pivot_instructions_per_hash.csv
results/v8_perf_grouped_<timestamp>_pivot_branch_misses_per_hash.csv
results/v8_perf_grouped_<timestamp>_pivot_cache_misses_per_hash.csv
```

---

## Current v8 summary

### module cycles per hash

| Input length |  jhash2 | hsiphash | siphash |
| -----------: | ------: | -------: | ------: |
|           16 |  16.712 |   28.554 |  45.376 |
|           32 |  26.869 |   38.341 |  64.480 |
|           64 |  61.426 |   57.203 | 101.947 |
|          128 | 119.872 |   95.860 | 174.763 |
|          256 | 249.810 |  171.048 | 324.874 |

### instructions per hash

| Input length |   jhash2 | hsiphash |   siphash |
| -----------: | -------: | -------: | --------: |
|           16 |  83.3841 | 148.3923 |  207.4183 |
|           32 | 118.3891 | 190.4117 |  279.4423 |
|           64 | 235.4635 | 274.4387 |  423.5020 |
|          128 | 422.5506 | 442.5090 |  711.6016 |
|          256 | 843.7541 | 778.6210 | 1287.8416 |

### branch misses per hash

| Input length |   jhash2 | hsiphash |  siphash |
| -----------: | -------: | -------: | -------: |
|           16 | 0.001924 | 0.002005 | 0.002126 |
|           32 | 0.001985 | 0.002163 | 0.002212 |
|           64 | 0.002653 | 0.002183 | 0.002759 |
|          128 | 0.003056 | 0.002452 | 0.003606 |
|          256 | 0.003757 | 0.003457 | 0.004906 |

### cache misses per hash

| Input length |   jhash2 | hsiphash |  siphash |
| -----------: | -------: | -------: | -------: |
|           16 | 0.008311 | 0.008926 | 0.009173 |
|           32 | 0.009374 | 0.009937 | 0.009592 |
|           64 | 0.008803 | 0.009353 | 0.010399 |
|          128 | 0.010604 | 0.010418 | 0.010648 |
|          256 | 0.011192 | 0.010811 | 0.011560 |

---

## Checking perf counted percentage

Because `run_perf_grouped.sh` uses:

```bash
perf stat -x,
```

the raw perf output is CSV-like.

Example:

```text
230073315,,cycles,64014526,100.00,,
```

Field meaning:

| Field |       Value | Meaning            |
| ----- | ----------: | ------------------ |
| 1     | `230073315` | event count        |
| 3     |    `cycles` | event name         |
| 5     |    `100.00` | counted percentage |

Check all events:

```bash
awk -F, '
$3=="cycles" || $3=="instructions" || $3=="branches" || $3=="branch-misses" || $3=="cache-references" || $3=="cache-misses" {
    print $3, $5
}' results/v8_perf_grouped_<timestamp>.raw.log | sort | uniq -c
```

Find events that are not counted at 100%:

```bash
awk -F, '
($3=="cycles" || $3=="instructions" || $3=="branches" || $3=="branch-misses" || $3=="cache-references" || $3=="cache-misses") && $5!="100.00" {
    print $0
}' results/v8_perf_grouped_<timestamp>.raw.log | head -50
```

If this prints nothing, the measured events were counted at `100.00%`.

---

## grep and awk notes

### grep

`grep` searches lines that contain a given string.

This command is too broad:

```bash
grep "cycles" results/v8_perf_grouped_<timestamp>.raw.log | head -20
```

It matches both perf event lines:

```text
230073315,,cycles,64014526,100.00,,
```

and dmesg lines:

```text
hash_microbench: jhash2 input_len=16 ... total_cycles=... cycles_per_hash=...
```

To match only perf `cycles` event lines:

```bash
grep ",,cycles," results/v8_perf_grouped_<timestamp>.raw.log | head -20
```

### awk

`awk -F,` treats each line as comma-separated fields.

For perf CSV-like output:

```text
230073315,,cycles,64014526,100.00,,
```

* `$1` = event count
* `$3` = event name
* `$5` = counted percentage

Example:

```bash
awk -F, '$3=="cycles" {print $1, $3, $5}' results/v8_perf_grouped_<timestamp>.raw.log | head
```

---

## Analysis summary

1. `siphash` has the highest cycles/hash across all input lengths.
2. `siphash` also has the highest instructions/hash, supporting the interpretation that its higher cost mainly comes from heavier computation.
3. `branch_misses_per_hash` remains very low across all three hash functions, so branch prediction is not the main differentiating factor.
4. `cache_misses_per_hash` is also similar across the three hash functions, likely because the input buffer is small and repeatedly reused.
5. `hsiphash` has lower cycles/hash than `jhash2` for longer inputs in this benchmark. This should be reported as an observation, not as a universal conclusion, because cycles are affected by instruction-level parallelism, pipeline behavior, compiler implementation path, and CPU execution characteristics.

---

## Report-ready conclusion

```text
The grouped perf results show that SipHash has the highest cycles/hash and instructions/hash across all tested input lengths. Branch misses and cache misses remain low and similar among jhash2, HalfSipHash, and SipHash. Therefore, in this microbenchmark, the main performance difference is better explained by instruction count and hash computation complexity rather than branch prediction failure or cache locality.
```

---

## Common issues

| Symptom                                                           | Cause                                                | Fix                                                                       |
| ----------------------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------- |
| `make: *** No rule to make target 'modules'`                      | missing kernel headers                               | `sudo apt install linux-headers-$(uname -r)`                              |
| `Makefile:NN: *** missing separator. Stop.`                       | Makefile uses spaces instead of TAB                  | use `cat -A Makefile` to check for `^I`                                   |
| `insmod: ERROR: could not insert module: Operation not permitted` | Secure Boot blocks unsigned module                   | disable Secure Boot or sign module with MOK                               |
| `perf stat: No permission to enable cycles event`                 | perf permission restriction                          | check `/proc/sys/kernel/perf_event_paranoid`; lower temporarily if needed |
| perf counted percentage is 66%–83%                                | too many events measured at once; multiplexing       | use grouped perf measurement                                              |
| `grep "cycles"` shows both perf and dmesg lines                   | pattern too broad                                    | use `grep ",,cycles,"` or `awk -F, '$3=="cycles"'`                        |
| `failed to create output file` from perf `-o`                     | perf cannot open temp output file under sudo context | redirect stderr with `2> "$perf_tmp"` instead of using `-o`               |

---

## Current status

| Version | Purpose                                             | Result                                                                                                       |
| ------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| v1      | minimal module lifecycle                            | `loaded / unloaded` success                                                                                  |
| v2      | module parameters                                   | `hash_type / input_len / iterations` printed correctly                                                       |
| v3      | `jhash2()` benchmark                                | printed `total_cycles / cycles_per_hash / sink`                                                              |
| v4      | `hsiphash()` benchmark                              | `hash_type=1` works                                                                                          |
| v5      | `siphash()` benchmark with 64-bit to 32-bit folding | `hash_type=2` works                                                                                          |
| v6      | automated cycles/hash benchmark                     | completed 3 hashes × 5 input lengths × 5 repeats                                                             |
| v7      | initial perf counter benchmark                      | collected perf counters, but earlier version still risked multiplexing                                       |
| v8      | grouped perf counter benchmark                      | completed 3 hashes × 5 input lengths × 10 repeats × 3 event groups; raw log shows 100.00% counted percentage |