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

## Next step

Generate UDP microflows with varying source ports.

Purpose:

1. Confirm UDP packets pass through the OVS bridge.
2. Observe whether datapath flow count changes.
3. Check whether megaflow caching still merges different 5-tuples.

The first UDP microflow generator is only for sanity checking. It is not a formal throughput benchmark because Python socket overhead will dominate packet generation cost.
