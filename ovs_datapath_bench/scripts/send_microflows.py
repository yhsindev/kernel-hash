#!/usr/bin/env python3
"""Sanity-only UDP microflow generator (varies the source port).

MUST be run inside ns1 so that the source IP exists:

    sudo ip netns exec ns1 python3 send_microflows.py

This is NOT a throughput benchmark: opening a socket per packet means Python and
syscall overhead dominate (a few k pps at most). Use pktgen_microflows.sh for
real load. This script only confirms that varying-src-port UDP installs distinct
datapath flows once force_megaflow_rules.sh is applied.
"""
import argparse
import random
import socket
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--dst-ip", default="10.0.0.2")
parser.add_argument("--dst-port-min", type=int, default=20000)
parser.add_argument("--dst-port-max", type=int, default=60000)
parser.add_argument("--src-ip", default="10.0.0.1")
parser.add_argument("--duration", type=float, default=30.0)
parser.add_argument("--payload-len", type=int, default=64)
parser.add_argument("--src-port-min", type=int, default=20000)
parser.add_argument("--src-port-max", type=int, default=60000)
parser.add_argument("--sleep-us", type=int, default=0)
args = parser.parse_args()

# Preflight: make sure the source IP is local to this namespace. If we are not
# inside ns1, bind() fails with EADDRNOTAVAIL -- give an actionable hint instead.
try:
    _probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    _probe.bind((args.src_ip, 0))
    _probe.close()
except OSError as e:
    print(f"cannot bind src-ip {args.src_ip}: {e}", file=sys.stderr)
    print("Run inside ns1:  sudo ip netns exec ns1 python3 send_microflows.py",
          file=sys.stderr)
    sys.exit(1)

payload = b"x" * args.payload_len
end_time = time.time() + args.duration
count = 0
last_report = time.time()

while time.time() < end_time:
    src_port = random.randint(args.src_port_min, args.src_port_max)
    dst_port = random.randint(args.dst_port_min, args.dst_port_max)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((args.src_ip, src_port))
    s.sendto(payload, (args.dst_ip, dst_port))
    s.close()

    count += 1

    if args.sleep_us > 0:
        time.sleep(args.sleep_us / 1_000_000)

    now = time.time()
    if now - last_report >= 1.0:
        print(f"sent={count}")
        last_report = now

print(f"done sent={count}")