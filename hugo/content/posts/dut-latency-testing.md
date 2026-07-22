---
title: "Nanosecond DUT Latency Testing with Hardware Timestamping"
date: 2026-07-19
author: Malcolm Frazier
description: "Measuring device-under-test (DUT) latency with i350 hardware timestamping and network namespaces: repeater hub vs 10/100 switch vs gigabit switch."
tags: ["Linux", "Networking", "PTP", "DUT"]
---

I wanted to measure how much latency a network device adds to a path, precisely
enough to characterize a DUT (Device Under Test) that adds less than a
microsecond. The instrument is a quad-port Intel i350, which does per-packet
hardware timestamping and exposes a PTP hardware clock per port. The DUTs: a
Netgear FE104 repeater hub, a Netgear FS105 10/100 switch, and a Netgear GS305
gigabit switch.

Results up front:

| | FE104 | FS105 | GS305 |
| --- | --- | --- | --- |
| Architecture | repeater | store-and-forward | store-and-forward |
| Link | 100M half | 100M full | 1000M full |
| Path delay, small frames | **2.96 µs** | **11.65 µs** | **3.08 µs** |
| DUT latency (baseline subtracted) | 480 ns | 9.2 µs | 2.56 µs |
| Frame-size dependence | none | 80 ns/byte | 7.6 ns/byte |
| Jitter | +/-0.4 ns | +/-60 ns | +/-90 ns |
| Factory gotcha | must force 100/half | none | EEE adds ~23 µs |

One setup note on the FE104: the NIC ports facing it are set to
`speed 100 duplex half autoneg off`. Repeater hubs are half-duplex
[CSMA/CD](https://en.wikipedia.org/wiki/Carrier-sense_multiple_access_with_collision_detection)
devices that predate autonegotiation. Locking the link makes the test
conditions deterministic and rules out a duplex mismatch: a port mistakenly
running full duplex against a hub links fine and passes light traffic, then
produces late collisions and lost frames under load.

## The loop-through topology and Linux loopback delivery

The test is a loop-through: packet out port A, through the DUT, back in port B.
One machine timestamps both ends.

The catch is that Linux will not put that packet on the wire. Route lookups
consult the routing policy database in priority order, and the priority-0 rule
points at the [local table](https://man7.org/linux/man-pages/man8/ip-rule.8.html),
a special table holding a route for every address configured on the machine. Ping one of your own interfaces from another and the lookup matches
there first, so the kernel delivers the packet internally over loopback. The
physical interfaces are never consulted. This is by design: Linux uses the
[weak host model](https://en.wikipedia.org/wiki/Host_model), in which an IP
address belongs to the host, not to an interface.

With both ports configured in netplan and nothing else:

```
# ping reports success
$ ping -c 5 10.82.0.5
rtt min/avg/max/mdev = 0.036/0.041/0.047/0.004 ms

# but nothing appears on the physical interface
$ tcpdump -ni enp3s0f0 icmp
0 packets captured

# because the kernel routed it over loopback
$ ip route get 10.82.0.5
local 10.82.0.5 dev lo src 10.82.0.5
```

Every tool reports success. The recorded latency describes the kernel's
loopback path. The DUT never saw a packet, and nothing warns you.

## Policy based routing vs network namespaces

Two configurations can force this traffic onto the physical wire: policy based
routing (PBR) and network namespaces. I set up both to compare them, using the
same two ports and addresses.

**PBR**, everything required before loop-through traffic works:

```bash
# accept packets sourced from our own addresses, disable reverse-path filtering
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.enp3s0f0.rp_filter=0 net.ipv4.conf.enp3s0f0.accept_local=1
sysctl -w net.ipv4.conf.enp3s0f1.rp_filter=0 net.ipv4.conf.enp3s0f1.accept_local=1

# custom route tables forcing each destination out a physical port
ip route add 10.82.0.5/32 dev enp3s0f0 table 101
ip route add 10.82.0.4/32 dev enp3s0f1 table 102

# rules for locally generated traffic only; undirected rules also match
# the inbound lookup and black-hole all return traffic
ip rule add from 10.82.0.4 to 10.82.0.5 iif lo lookup 101 pref 10
ip rule add from 10.82.0.5 to 10.82.0.4 iif lo lookup 102 pref 11

# demote the kernel's priority-0 local rule so the rules above are consulted
ip rule add from all lookup local pref 100
ip rule del pref 0

# static ARP entries; a Linux host will not answer ARP between its own interfaces
ip neigh replace 10.82.0.5 lladdr 50:7c:6f:90:31:75 dev enp3s0f0 nud permanent
ip neigh replace 10.82.0.4 lladdr 50:7c:6f:90:31:74 dev enp3s0f1 nud permanent
```

**[Network namespaces](https://man7.org/linux/man-pages/man8/ip-netns.8.html)**,
everything required:

```bash
ip netns add hub1
ip link set enp3s0f1 netns hub1
ip addr add 10.82.0.4/24 dev enp3s0f0
ip netns exec hub1 ip addr add 10.82.0.5/24 dev enp3s0f1
```

A namespace is a separate network stack. The two ports become different hosts
as far as the kernel is concerned, so every problem PBR patches individually
simply doesn't exist.

PBR is clearly more complex, but complexity is the lesser problem. The real
difference is what happens when the configuration breaks. PBR fails open: lose
any piece of it and traffic silently reverts to loopback while every tool
continues reporting success. Namespaces fail closed: there is no loopback path
between namespaces, so a broken setup, an unplugged cable, or a dead DUT stops
traffic entirely. For a measurement rig that distinction is everything,
because the dangerous outcome is not missing data, it is wrong data that looks
right. Both configurations produce identical latency once traffic is on the
wire; routing configuration selects the path, it does not slow it.

## Kernel overhead dominates software measurements

Ping and sockperf timestamp packets in userspace and at the socket layer.
Every measurement therefore includes the full kernel network stack and the
NIC's interrupt handling, in both directions. That overhead is enormous
compared to the DUT: about 450 µs of latency and +/-30 µs of jitter per round
trip, while the DUTs themselves add 3 to 12 µs. The DUT's latency disappears
inside the tool's own noise.

Measured against both 100 Mbps DUTs. The first three rows are round-trip times
reported by each tool; the last row is the one-way path delay from hardware
timestamps:

| Method | Reports | FS105 | FE104 | Result |
| --- | --- | --- | --- | --- |
| ping | round trip | 453 µs | 440 µs | ranked the repeater *slower* |
| ping -f | round trip | 240 µs | 240 µs | identical |
| sockperf, 120k samples | round trip, p50 | 244.911 µs | 244.910 µs | identical |
| ptp4l | one-way, hardware | 11.65 µs | 2.96 µs | clearly resolved |

Only the hardware-timestamped row separates the two devices. ptp4l shows the
FS105 path at 11.65 µs and the FE104 path at 2.96 µs, roughly four times
apart, and after the test rig's own latency is subtracted the devices
themselves differ by 19 times (9.2 µs versus 480 ns). sockperf reported the
two devices as identical because the number it produces is dominated by the
NIC's interrupt moderation timer, which is the same no matter which DUT is in
the path. ping did worse than identical: it ranked the repeater as the slower
device.

## The measurement: ptp4l as the instrument

PTP computes path delay from four hardware timestamps as part of normal
operation, and the calculation is designed so that the offset between the two
clocks drops out of the result. Run a master on one side of the DUT and a
slave on the other, and the path delay column is a live, hardware-timestamped,
one-way latency measurement of whatever sits between the ports:

```bash
ptp4l -i enp3s0f0 -m --serverOnly 1 &
ip netns exec hub1 ptp4l -i enp3s0f1 -m --clientOnly 1
```

```
ptp4l[7544.288]: master offset  0 s2 freq -0 path delay  2960
ptp4l[7545.288]: master offset  0 s2 freq -0 path delay  2960
```

+/-5 ns stability through the FE104. The `/dev/ptpX` clocks are not namespaced,
so this works cleanly across the namespace boundary.

The path delay includes the rig itself: the two NIC PHYs and the cable. To
isolate the DUT, connect the two ports directly with a cable and measure
again. That direct-cable number is the rig's baseline, and:

```
DUT latency = path delay through DUT − direct-cable baseline
```

- **FE104:** 2.96 µs through the hub, 2.48 µs direct cable, so the hub itself
  adds **480 ns**. The IEEE 802.3 limit for a Class II repeater is 920 ns;
  this one uses about half of it.
- **FS105:** 11.65 µs through the switch, so the switch itself adds about
  9.2 µs. That splits into two parts: ~6.9 µs to fully receive the 86-byte
  test frame at 100 Mbps before forwarding begins, and ~2.3 µs for the
  switch's forwarding logic.

## Frame-size sweeps

Latency versus frame size is the clearest way to see the difference between the
two architectures. [isochron](https://github.com/NXP/isochron) measures
per-packet one-way latency at chosen frame sizes on top of the ptp4l-disciplined
clocks:

| Frame | FE104 | FS105 | GS305 |
| --- | --- | --- | --- |
| 64 B | 2960 ns | 10.4 µs | 3075 ns |
| 256 B | 2973 ns | 29.0 µs | 4582 ns |
| 1024 B | 2960 ns | 86.8 µs | 10,166 ns |
| 1514 B | 2963 ns | 126.0 µs | 14,098 ns |

The repeater's latency never changes with frame size, because it never stores
the frame. It regenerates each bit as it arrives.

Both switches grow linearly with frame size, because a store-and-forward device
must receive the entire frame before it can start forwarding. Each byte adds one
byte-time of latency: 80 ns per byte at 100 Mbps, and 8 ns per byte at 1 Gbps.
The FS105 measured 79.7 ns per byte and the GS305 measured 7.6 ns per byte, both
close to those rates. The gigabit switch shows the same architecture as the
100 Mbps switch, running ten times faster.

The practical point: the latency of a store-and-forward device depends on frame
size. A single latency figure without a stated frame size is incomplete. The
complete description is a fixed cost plus a per-byte rate.

## Under load

iperf3 supplies load through the DUT while isochron keeps measuring. Two
design requirements for any loaded measurement:

- **Keep control traffic off the DUT.** isochron's sender and receiver
  coordinate over a TCP session. That session runs over a veth pair between
  the namespaces, so only test traffic crosses the DUT.
- **Keep clock sync off the DUT.** PTP assumes both directions of the path are
  equally fast. Load breaks that assumption and corrupts the synchronized
  clocks, and with them the measurement. Clock sync must not run through a
  loaded DUT.

The results:

- **FS105:** loaded latency takes one of two values. A test frame arriving
  while the output port is idle passes in ~25 µs. A test frame arriving while
  the port is transmitting a 1400-byte load frame waits for it, and passes in
  ~120 µs. More load means the second case happens more often; at 95% load
  the port is never idle and every frame waits.
- **FE104:** a repeater has no queue. Test and load frames share one wire
  using CSMA/CD. It carried 40 Mbps of bidirectional load with 0% loss, and
  latency stayed at the unloaded 2.96 µs at most load levels. When test and
  load frames did collide, latency jumped to a mean of 48 µs with a worst
  case of 163 µs. The repeater's typical case beats the switch, but its worst
  case is worse and unpredictable.

## Modern switch EEE behavior

The expectation for a gigabit store-and-forward DUT was 2 to 4 µs. Instead the
GS305 first measured **26 µs, and unstable**, higher than either 100 Mbps DUT
despite running at ten times their link speed.

```
$ ethtool --show-eee enp3s0f0
EEE status: enabled - active
```

[Energy-Efficient Ethernet](https://en.wikipedia.org/wiki/Energy-Efficient_Ethernet)
(IEEE 802.3az) is enabled by default on the GS305, and the i350 negotiates it.
Sparse traffic is EEE's worst case: the link drops into low-power idle between
packets, and every frame pays a wake-up cost that varies from packet to packet.
Disable it on the NIC side and the link renegotiates without it:

```bash
ethtool --set-eee enp3s0f0 eee off
```

Path delay dropped from 26 µs to **3.08 µs**, stable, and all the GS305 numbers
in this post were taken with EEE off. EEE was adding roughly 23 µs per frame,
about seven times the switch's real path delay. Check EEE before trusting any
latency number through commodity gigabit gear. The other DUTs predate 802.3az,
and links with autonegotiation disabled cannot negotiate it, so no other
measurement here was affected.

## Takeaways

- **Use namespaces for loop-through testing.** They force traffic onto the wire
  with one mechanism instead of six, and they fail closed: a broken setup stops
  traffic instead of silently measuring loopback.
- **Use hardware timestamps when the effect is under ~100 µs.** The kernel path
  adds about 450 µs of its own latency and +/-30 µs of jitter. That is so much
  larger than the DUTs themselves that ping and sockperf ranked the faster and
  slower devices in the wrong order.
- **Route the test setup's control and clock-sync traffic around the loaded
  DUT.** When they shared the congested wire, the load corrupted the
  measurement itself.
- **Lower latency does not mean better.** The repeater has the lowest latency of
  the three at 480 ns, but it only repeats bits. It does not switch, filter, or
  run full duplex. A switch spends latency to do those things, which is why
  switches replaced hubs.
- **Check EEE.** One default setting raised a gigabit switch's path delay from
  3.08 µs to 26 µs.
