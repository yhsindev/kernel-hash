# Linux Kernel Hash Function Trade-off Analysis

Comparing `jhash2()`, `hsiphash()`, and `siphash()` for Linux kernel hash-table use,
with the Open vSwitch (OVS) kernel datapath flow table as the target scenario.

**Research question.** OVS `net/openvswitch/flow_table.c::flow_hash()` currently uses
`jhash2(..., 0)`, a non-keyed hash with a fixed seed. Replacing it with a keyed hash
(hsiphash / siphash) has two independent sides:

- **Security** (independent of input length): a fixed-seed jhash is predictable and open
  to hash-flooding; a keyed hash is not.
- **Performance** (depends on real input length): the relative cost of the three hashes
  changes with the length of the hashed key.

## Layout

| Path | What |
|---|---|
| [`hash_microbench/`](./hash_microbench/) | Exp 1 — standalone kernel hash microbenchmark |
| [`ovs_datapath_bench/`](./ovs_datapath_bench/) | Exp 2 — OVS datapath testbed, measurement tools, formal data |
| [`ovs_security/`](./ovs_security/) | Exp 3 — hash-flooding / collision and bucket-distribution analysis |
| [`docs/`](./docs/) | Reports and daily log |
| `kernel_work/` | Self-built `openvswitch.ko` source tree (gitignored) |
| [`slides/`](./slides/) | Checkpoint slides |
| [`archive/`](./archive/) | Historical / exploration-phase data |

## Documents

| File | Content |
|---|---|
| [`docs/exp2_report.md`](./docs/exp2_report.md) | Exp 2 report — OVS integration cost of the three hashes |
| [`docs/exp2_ovn_report.md`](./docs/exp2_ovn_report.md) | Exp 2 supplement — real megaflow input length on a local OVN |
| [`docs/exp3_report.md`](./docs/exp3_report.md) | Exp 3 report — security / collision analysis |
| [`docs/experiment_log.md`](./docs/experiment_log.md) | Daily progress log |
| [`docs/agent_workflow.md`](./docs/agent_workflow.md) | Measurement rules and workflow |
| [`ovs_datapath_bench/notes/benchmark_runbook.md`](./ovs_datapath_bench/notes/benchmark_runbook.md) | Full build / reload / measure procedure |

## Status

| Stage | Status | Note |
|---|---|---|
| Exp 1 — microbenchmark | Done | cost per hash across input lengths |
| Exp 2 — OVS integration | Draft done | N=10 per hash on the D-v3B workload |
| Exp 2 — OVN real-world supplement | Done | measured real megaflow input length |
| Exp 3 — security / collision | In progress | threat model and bucket analysis |

## Key findings (see the reports for detail)

- **Exp 1**: `siphash` has the highest per-hash cost at every input length. `jhash2` and
  `hsiphash` swap ranking with length — jhash is cheaper below ~64 bytes, hsiphash above,
  with a crossover near 64 bytes.
- **Exp 2**: on the D-v3B workload (about 88-byte hash input), the cost ranking is
  `hsiphash < jhash < siphash`; the keyed `hsiphash` is actually cheaper than the current
  `jhash` at this length. Measured with a `noinline ovs_flow_hash_backend()` wrapper and
  CPU0-scoped perf, N=10.
- **Real-world input length is deployment-dependent**: a plain L2 bridge produces short
  keys (jhash's favorable range), while OVN / conntrack / overlay produce longer keys.
  This is what decides whether the performance side favours switching, and it is the main
  open question driving Exp 3 and further real-world measurement.

## Environment

Kernel 6.8.0-124-generic, Intel Core i5-10500 (12 logical cores), CPU governor `performance`.
