# Experiment 2: OVS Datapath Benchmark

This folder contains the OVS testbed and datapath benchmark scripts for the next stage of the Linux kernel hash function project.

## Goal

Build a minimal OVS datapath testbed before modifying `net/openvswitch/flow_table.c`.

Current focus:

1. Build a namespace/veth/OVS bridge environment.
2. Confirm packets enter the OVS kernel datapath.
3. Observe datapath flows with `ovs-dpctl dump-flows`.
4. Generate UDP microflows to study megaflow/cache behavior.

## Topology

```text
ns1:veth1 (10.0.0.1)
    |
veth1-br
    |
OVS bridge br0
    |
veth2-br
    |
ns2:veth2 (10.0.0.2)
```

## Setup

```bash
./scripts/setup_ovs_testbed.sh
```

Connectivity test:

```bash
sudo ip netns exec ns1 ping -c 3 10.0.0.2
sudo ip netns exec ns2 ping -c 3 10.0.0.1
```

Check OVS bridge:

```bash
sudo ovs-vsctl show
```

Check datapath flows:

```bash
sudo ovs-dpctl dump-flows
```

## Cleanup

```bash
./scripts/cleanup_ovs_testbed.sh
```

## Useful commands

Show datapath ports:

```bash
sudo ovs-dpctl show
```

Show OpenFlow ports:

```bash
sudo ovs-ofctl show br0
```

Show OpenFlow rules:

```bash
sudo ovs-ofctl dump-flows br0
```

Clear datapath flows:

```bash
sudo ovs-dpctl del-flows
```

Observe datapath flow count:

```bash
watch -n 1 'sudo ovs-dpctl dump-flows | wc -l'
```

## Current status

Completed:

- Created `ns1` and `ns2`.
- Created two veth pairs.
- Created OVS bridge `br0`.
- Verified `ns1 <-> ns2` connectivity through OVS.
- Observed ARP datapath flows with `ovs-dpctl dump-flows`.

Current observation:

```text
recirc_id(0),in_port(2),eth(...),eth_type(0x0806),...,actions:3
recirc_id(0),in_port(3),eth(...),eth_type(0x0806),...,actions:2
```

Interpretation:

- `eth_type(0x0806)` indicates ARP traffic.
- `in_port(2)` and `in_port(3)` are OVS datapath ports.
- `actions:2` or `actions:3` means the matched packet is forwarded to the corresponding datapath port.
- This confirms that packets have entered the OVS kernel datapath.

## Why a default bridge hides the flow table hash path

The kernel flow table (`net/openvswitch/flow_table.c`) is consulted on every
packet via `ovs_flow_tbl_lookup_stats()` -> `flow_hash()`. But how *many distinct
entries* it holds depends on the megaflows OVS installs.

A default bridge runs the `NORMAL` action (learning switch). The forwarding
decision only depends on L2 fields (`in_port`, `eth_src/dst`, `eth_type`), so OVS
installs megaflows that **wildcard** L3/L4. Varying the UDP source port then
produces packets that all match **one** megaflow — the hash path is exercised,
but with no variety, so it tells us nothing about collisions or bucket spread.

`scripts/force_megaflow_rules.sh` fixes this by installing OpenFlow rules that
*reference* `tp_src`/`tp_dst`. To classify a packet against such a rule, OVS must
examine that field, so the field is **unwildcarded** in the resulting megaflow.
Each distinct UDP source port then installs its own datapath flow, driving
`flow_hash()` over many distinct keys — the condition our experiment needs.

## Runbook: make packets actually reach the flow table hash

```bash
# 1. Build the testbed (namespaces, veth, br0)
./scripts/setup_ovs_testbed.sh

# 2. Force per-source-port megaflows (the critical fix)
./scripts/force_megaflow_rules.sh
sudo ovs-ofctl dump-flows br0      # confirm the udp tp_src/tp_dst probe rules

# 3. In terminal A, watch the flow table being exercised
sudo ./scripts/observe_flows.sh --watch 30

# 4. In terminal B, generate varying-src-port UDP load
sudo ./scripts/pktgen_microflows.sh                 # high rate (kernel pktgen)
#   or, for a quick sanity check only:
sudo ip netns exec ns1 python3 scripts/send_microflows.py

# 5. Restore plain forwarding when done
./scripts/force_megaflow_rules.sh restore
```

### What proves the hash is being exercised

In the `observe_flows.sh --watch` output:

- **`flows`** climbs from ~1 into the thousands → the hash table now holds many
  distinct keys (one per source port).
- **`d_hit`** (fast-path matches/s) climbs → packets are matching existing
  datapath flows in the kernel, i.e. successful `flow_hash()` lookups per second.
- **`masks` / `hit/pkt`** → number of subtables searched per packet; each is one
  masked `flow_hash()` call, i.e. the per-packet hash cost.

If `flows` stays at 1, traffic is still collapsing to a single megaflow — re-check
that `force_megaflow_rules.sh` was applied.

## Generators

| Script | Use |
|---|---|
| `scripts/send_microflows.py` | sanity check only; Python/syscall overhead caps it at a few k pps |
| `scripts/pktgen_microflows.sh` | formal load; in-kernel pktgen, randomized UDP src port, millions of pps |

### pktgen fallback (if pktgen is not per-netns enabled)

`pktgen_microflows.sh` injects on `veth1` inside `ns1` and preflight-checks that
`/proc/net/pktgen` exists in that namespace. If it does not, inject from the root
namespace instead: create a dedicated `pg0 <-> pg0-br` veth pair, add `pg0-br` as
an OVS port, and run pktgen on `pg0` (root ns), with `dst_mac` set to ns2's MAC.

## Next step (kernel side)

With the testbed now able to stress `flow_hash()`, the remaining work is the core
deliverable: modify `net/openvswitch/flow_table.c` to switch the hash function
(jhash2 / hsiphash / siphash) at build or run time, then re-run this runbook to
compare datapath throughput, pps, softirq CPU, and bucket/collision distribution.
