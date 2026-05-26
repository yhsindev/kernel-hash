# Linux Kernel Hash Function Trade-off Analysis

This repository contains the implementation notes, experiment scripts, and checkpoint materials for a Linux kernel design project on hash function trade-offs.

The project compares `jhash2()`, `hsiphash()`, and `siphash()` in the context of Linux kernel hash table usage, with Open vSwitch flow table lookup as the target system scenario.

## Project Index

| Path | Description |
|---|---|
| [`hash_microbench/`](./hash_microbench/) | Experiment 1: kernel-side hash function microbenchmark |
| [`ovs_datapath_bench/`](./ovs_datapath_bench/) | Experiment 2: OVS namespace/veth/bridge datapath testbed |
| [`slides/`](./slides/) | First checkpoint Slidev slides and exported PDF |

## Current Status

| Stage | Status | Notes |
|---|---|---|
| Experiment 1 | Completed | Measured cycles/hash, instructions/hash, branch-misses/hash, and cache-misses/hash |
| Experiment 2 | Started | Built minimal OVS testbed with namespaces, veth pairs, and OVS bridge |
| Checkpoint slides | Completed | See `slides/slides.pdf` |

## Key Links

- Experiment 1 README: [`hash_microbench/README.md`](./hash_microbench/README.md)
- Experiment 2 README: [`ovs_datapath_bench/README.md`](./ovs_datapath_bench/README.md)
- Checkpoint slides source: [`slides/slides.md`](./slides/slides.md)
- Checkpoint slides PDF: [`slides/slides.pdf`](./slides/slides.pdf)

## Experiment 1 Summary

Experiment 1 measures the standalone cost of Linux kernel hash functions before modifying OVS.

Tested hash functions:

- `jhash2()`
- `hsiphash()`
- `siphash()` with 64-bit to 32-bit folding

Formal setting:

| Item | Setting |
|---|---|
| Input lengths | 16, 32, 64, 128, 256 bytes |
| Iterations | 10,000,000 per run |
| Repeats | 10 |
| Perf method | grouped events |

Main observation:

`siphash()` has the highest cycles/hash and instructions/hash across all tested input lengths. Branch/cache misses remain low and similar across the three hash functions.

## Experiment 2 Summary

Experiment 2 builds a minimal OVS datapath testbed before modifying `net/openvswitch/flow_table.c`.

Current testbed:

- `ns1` and `ns2`
- veth pairs
- OVS bridge `br0`
- verified namespace-to-namespace connectivity
- observed ARP datapath flows with `ovs-dpctl dump-flows`

Next step:

Generate UDP microflows with varying source ports and observe datapath flow / megaflow cache behavior.
