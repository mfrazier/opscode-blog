---
title: "A Tale of Two Network Interfaces"
date: 2026-03-15
draft: false
tags:
  - cmmc
  - linux
  - networking
  - sysadmin
  - routing
  - security
description: >
  What actually breaks when you assign two Linux NICs to the same subnet, when it's
  genuinely necessary, and exactly what you must configure if you have no choice.
showToc: true
TocOpen: false
---

Two NICs, one subnet. Seems fine. It isn't.

I frequently run into this on Linux servers, PTP Grandmaster clocks, telemetry acquisition
and analysis servers, industrial controllers and other appliances where Linux is running
under the hood whether the vendor advertises it or not. Most of them cover this limitation
somewhere in their published documentation. It is worth reading before you plug in the second cable.

The symptoms are always the same: traffic arrives on one interface, replies leave on another,
sessions drop for no apparent reason, and nothing in the logs explains it.

This post breaks down exactly why it happens, what breaks, and what you have to do if you
genuinely cannot avoid the configuration. The examples are from a real EndRun Technologies
Meridian II PTP Grandmaster, a dual-Ethernet appliance that was deployed with both ports
on the same `/24`. There was a legitimate reason for it, which we will get to shortly.

---

## What do the vendors say?

The warning is consistent across hardware that ships with Linux inside.

The [EndRun Technologies Meridian II documentation](https://endruntechnologies.com/pdf/USM3043-0000-000.pdf)
(a GPS-disciplined NTP/PTP grandmaster with dual Ethernet ports), page 13, under network setup:

> *"Be sure that they are NOT on the same subnet."*


Beckhoff's TwinCAT documentation for its [real-time Ethernet Miniport driver](https://infosys.beckhoff.com/content/1033/tcsystemmanager/1089138443.html):

> *"If Real-Time Ethernet and 'normal' Ethernet are both used on the same system with two
> different network adapters, the subnet addresses of these adapters (NICs) must differ!"*

Red Hat's support knowledge base, [Solution 30564](https://access.redhat.com/solutions/30564):

> *"It is usually not a good idea to connect two interfaces using the same subnet on the system."*

The NetAcquire Server documentation (NA-MAN-001), section 20.6, under "Only One of Two NICs
is Reachable":

> *"For systems having two NIC connections, each one must be assigned to a different subnet.
> Ensure that the NICs are not configured on the same network subnet by using the good
> connection to browse to the main web page."*

None of these are boilerplate. They're all pointing at the same two failure modes.

The Linux kernel's own ip-sysctl documentation, under the `arp_filter` entry at
[docs.kernel.org](https://docs.kernel.org/networking/ip-sysctl.html), puts it plainly:

> *"1 - Allows you to have multiple network interfaces on the same subnet, and have the
> ARPs for each interface be answered based on whether or not the kernel would route a
> packet from the ARP'd IP out that interface (therefore you must use source based routing
> for this to work)."*

The fact that the kernel documentation describes a dedicated sysctl parameter specifically
for controlling ARP behavior in the multi-NIC-same-subnet case tells you everything about
how well-known this problem is at the lowest level of the stack.

---

## Why does Linux behave this way?

Linux uses what's called the **weak host model**. When a packet arrives destined for any
locally configured IP address, Linux accepts it regardless of which interface it came in
on. Outbound traffic follows the routing table, not the interface the inbound packet used.

This is deliberate and generally useful. The problem is that it creates ambiguity when two
interfaces share the same subnet.

---

## The misconfiguration in the wild

The Meridian II in question had a specific reason for this configuration. `eth0` was
serving NTP to clients on `10.151.16.0/24`. `eth1` was serving PTP to a boundary clock
that also terminated on that same subnet. Two different timing protocols, two different
interfaces, one subnet. The intent was interface-level traffic separation. The result was
the problems described in this post.

The natural fix would be to disable PTP on `eth0` and NTP on `eth1` through the device's
management interface. The Meridian II does not provide this functionality. There is no
per-interface toggle for PTP or NTP in the web UI or via the command line interface. Disabling a
service on a specific interface requires reaching into the init system and making it
non-executable directly:

```bash
chmod -x /etc/rc.d/rc.ptpd0
```

That is a workaround, not a feature. It is fragile across firmware updates and not
documented as a supported configuration. This is a genuine shortcoming in EndRun's
Meridian product line. A device with dual Ethernet ports explicitly intended for network
redundancy or traffic separation should provide a straightforward way to bind individual
timing services to individual interfaces. It doesn't, and that gap pushes operators toward
the exact subnet misconfiguration described here.

Here is the device with both ports on `10.151.16.0/24`:

```
eth0: inet 10.151.16.11  netmask 255.255.255.0  ether 00:0e:fe:01:3e:4e
eth1: inet 10.151.16.12  netmask 255.255.255.0  ether 00:0e:fe:01:3e:4f
```


The routing table makes the problem immediately visible:

```
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         10.151.16.1     0.0.0.0         UG    0      0        0 eth1
0.0.0.0         10.151.16.1     0.0.0.0         UG    0      0        0 eth0
10.151.16.0     0.0.0.0         255.255.255.0   U     0      0        0 eth0
10.151.16.0     0.0.0.0         255.255.255.0   U     0      0        0 eth1
127.0.0.0       0.0.0.0         255.0.0.0       U     0      0        0 lo
```


Two default routes. Two identical `/24` entries. Both the same subnet, both the same gateway.
The kernel can only act on one of them at a time. The other interface is essentially invisible
to the routing decision, which is where everything goes wrong.

---

## Problem one: asymmetric routing

When the kernel sees two routes to `10.151.16.0/24`, it uses the first one, `eth0`. That
entry wins the tie. Any traffic destined for `eth1`'s address (`10.151.16.12`) will have
its reply routed out through `eth0` instead.

You can confirm this with `ip route get`, which asks the kernel directly: given this
destination, which interface and source address do you plan to use?

```
MeridianII# ip route get 10.151.16.15
10.151.16.15 dev eth0  src 10.151.16.11
```


No matter what address you query on that subnet, the answer is always `dev eth0`. The
kernel has no concept that `.12` exists on a different interface.

To see it break in real traffic, watch both interfaces simultaneously while a remote host
pings each IP:

```bash
# Terminal 1: on the Meridian II
tcpdump -ni eth0 icmp

# Terminal 2: on the Meridian II
tcpdump -ni eth1 icmp
```

**eth0 captures:**

```
# Ping to .11 (eth0's own IP): symmetric, correct
10.151.16.15 > 10.151.16.11: ICMP echo request, id 15, seq 1
10.151.16.11 > 10.151.16.15: ICMP echo reply,   id 15, seq 1

# Ping to .12 (eth1's IP): replies appear here instead, on the wrong interface
10.151.16.12 > 10.151.16.15: ICMP echo reply, id 16, seq 1
10.151.16.12 > 10.151.16.15: ICMP echo reply, id 16, seq 2
10.151.16.12 > 10.151.16.15: ICMP echo reply, id 16, seq 3
10.151.16.12 > 10.151.16.15: ICMP echo reply, id 16, seq 4
```

**eth1 captures:**

```
# Ping to .12: requests arrive here, but there are no replies
10.151.16.15 > 10.151.16.12: ICMP echo request, id 16, seq 1
10.151.16.15 > 10.151.16.12: ICMP echo request, id 16, seq 2
10.151.16.15 > 10.151.16.12: ICMP echo request, id 16, seq 3
10.151.16.15 > 10.151.16.12: ICMP echo request, id 16, seq 4
```


The request for `.12` arrived on `eth1` at `18:38:58.871225`. The reply left on `eth0` at
`18:38:58.871292`, 67 microseconds later, sourced from `.12`, out the wrong port. The
remote host received the reply in this case because there was nothing stateful in the path.

### "But ping still worked"

This is always the first objection. The remote host got its replies (`0% packet loss`)
so surely nothing is really broken?

Ping worked here because there was nothing in the path enforcing source validation. The
asymmetric routing is still present. We can expose it immediately by enabling strict
Reverse Path Filtering on the Meridian II itself:

```bash
# On the Meridian II
sysctl -w net.ipv4.conf.eth1.rp_filter=1
```

Now ping `.12` from the remote host:

```
PING 10.151.16.12 (10.151.16.12): 56 data bytes
Request timeout for icmp_seq 0
Request timeout for icmp_seq 1
Request timeout for icmp_seq 2
Request timeout for icmp_seq 3
--- 10.151.16.12 ping statistics ---
4 packets transmitted, 0 packets received, 100% packet loss
```

The request arrives on `eth1`. The kernel tries to reply via `eth0`. Strict RPF on `eth1`
checks: does the route for the source address point back out `eth1`? No. Drop. The
Meridian II is now discarding its own incoming traffic on that interface.

### Why worry about asymmetric routing?

Two reasons. First, **Reverse Path Filtering** will silently drop traffic. When RPF is enabled, the kernel discards any packet arriving on an interface that wouldn't be used to route back to the source, before conntrack, before iptables, before anything in userspace has a chance to see it. Packet captures show the packet arriving. The application never receives it. Nothing in the logs tells you why.

Second, even with RPF out of the picture, asymmetric routing can convolute debugging network related issues on a host. Requests visible on one interface, replies leaving on another. If you are not already aware of Linux's weak host model, that asymmetry is the kind of thing that muddies an otherwise straightforward investigation.

Lastly, RPF is a required control under DISA STIGs and CIS Benchmarks, and several major distributions ship with it enabled out of the box.

| Framework | Requirement |
|---|---|
| DISA STIG | Required, explicit finding if not set to `1` |
| CIS Benchmarks Level 1 | Required, `rp_filter=1` |

Several major distributions ship with RPF enabled out of the box.

| Distribution | Default | Mode |
|---|---|---|
| RHEL / CentOS 6+ | 1 | Strict |
| Rocky Linux | 1 | Strict |
| AlmaLinux | 1 | Strict |
| Fedora | 2 | Loose |
| Ubuntu 20.04+ | 2 | Loose |
| Debian | 0 | Disabled |

Loose mode (`rp_filter=2`) checks whether the source address is reachable via any
interface. In the same-subnet scenario in this post, it is reachable, so loose mode
passes the traffic through. Only strict mode (`rp_filter=1`) triggers the drop shown
above. The distributions shipping with strict mode by default are the ones where this
misconfiguration will cause immediate, reproducible failures.

Fixing the routing correctly means the device behaves predictably regardless of what
surrounds it.

---

## Problem two: ARP flux

The Address Resolution Protocol maps IPs to MAC addresses. When any host on the subnet
broadcasts an ARP request for `10.151.16.12`, both `eth0` and `eth1` on the Meridian II
are eligible to respond, and both do.

The Meridian II tcpdumps on both interfaces during an arping run from `10.151.16.14` tell
the story. Look at the same ARP request arriving at `18:47:35.696`:

**eth0:**
```
18:47:35.696472 ARP, Request who-has 10.151.16.12 tell 10.151.16.14
18:47:35.696512 ARP, Reply 10.151.16.12 is-at 00:0e:fe:01:3e:4e
```

**eth1:**
```
18:47:35.696386 ARP, Request who-has 10.151.16.12 tell 10.151.16.14
18:47:35.696443 ARP, Reply 10.151.16.12 is-at 00:0e:fe:01:3e:4f
```


Both interfaces answered the same broadcast. `eth1` replied with its own MAC (`3e:4f`),
which is correct. `eth0` replied with its MAC (`3e:4e`), advertising a mapping that is
wrong: it's claiming to own an IP it doesn't hold.

In this test, `arping` on the remote host consistently returned `3e:4f` (eth1's correct
MAC). From the remote host's perspective everything looks clean:

```
[client-host]# arping -c 6 -I enp2s0 10.151.16.12
ARPING 10.151.16.12
60 bytes from 00:0e:fe:01:3e:4f (10.151.16.12): index=0 time=1.136 msec
60 bytes from 00:0e:fe:01:3e:4f (10.151.16.12): index=1 time=1.057 msec
60 bytes from 00:0e:fe:01:3e:4f (10.151.16.12): index=2 time=1.486 msec
60 bytes from 00:0e:fe:01:3e:4f (10.151.16.12): index=3 time=1.140 msec
60 bytes from 00:0e:fe:01:3e:4f (10.151.16.12): index=4 time=1.120 msec
60 bytes from 00:0e:fe:01:3e:4f (10.151.16.12): index=5 time=1.284 msec
--- 10.151.16.12 statistics ---
6 packets transmitted, 6 packets received,   0% unanswered (0 extra)
rtt min/avg/max/std-dev = 1.057/1.204/1.486/0.143 ms
```

One MAC, every time. The dual reply is only visible when you watch both interfaces on the
device simultaneously. A standard arping test from a remote host gives no indication
anything is wrong.

The behavior is nondeterministic by topology, not by time. Right now `eth1` consistently
wins because the switch delivers the broadcast to `eth1` first, probably due to port
ordering or path length. Swap the cables, change the switch, or add a spanning tree
recalculation, and `eth0` starts winning. At that point every host on the subnet starts
sending `.12` traffic to `3e:4e` (eth0's MAC), which hits the wrong interface, and the
asymmetric routing problem compounds with the ARP problem simultaneously.

You can see the collateral damage on any host that has been talking to the Meridian II.
Its ARP cache shows whichever MAC won the last race:

```bash
# On a remote host
arp -n 10.151.16.12
```

```
Address          HWtype  HWaddress           Flags Mask  Iface
10.151.16.12     ether   00:0e:fe:01:3e:4e   C           enp2s0
```


That entry is wrong. The host believes `.12` is reachable via eth0's MAC. Traffic sent
there will arrive on the wrong interface and hit the asymmetric routing problem immediately.


## When it is genuinely necessary

These are just a few examples where this configuration shows up in practice:

- **Load balancers** distributing inbound requests across multiple interfaces on the same subnet
- **Kubernetes nodes** with multiple NICs where policy routing is required to handle traffic correctly across interfaces on the same subnet
- **Bare-metal provisioning hosts** dual-homed on both a provisioning and production network that share the same address space
- **iSCSI multipath storage** where a NAS or storage appliance exposes two IPs on the same subnet for redundant initiator paths across separate switches
- **Proxmox hypervisors** separating host management traffic from VM bridge traffic on the same subnet to prevent VM workloads from saturating the management interface
- **Application/replication traffic separation** on services like Kafka or Elasticsearch, where client-facing and intracluster replication traffic are intentionally isolated to different interfaces

If you are in one of these situations, you need to fix both problems: the routing problem
and the ARP problem. One without the other leaves you half-broken.

---

## Fixing the routing problem: policy routing

The [ip-rule(8)](https://man7.org/linux/man-pages/man8/ip-rule.8.html)
and [ip-route(8)](https://man7.org/linux/man-pages/man8/ip-route.8.html) man pages cover
the full syntax for what follows.

The solution is to give each interface its own private routing table and use policy rules to
force traffic to enter and exit through the same interface.

First, register named tables:

```bash
echo "100 eth0rt" >> /etc/iproute2/rt_tables
echo "101 eth1rt" >> /etc/iproute2/rt_tables
```

Populate each table with the subnet route and a default gateway:

```bash
ip route add 192.168.10.0/24 dev eth0 src 192.168.10.5  table eth0rt
ip route add default via 192.168.10.1 dev eth0            table eth0rt

ip route add 192.168.10.0/24 dev eth1 src 192.168.10.10 table eth1rt
ip route add default via 192.168.10.1 dev eth1            table eth1rt
```

Install the policy rules:

```bash
ip rule add from 192.168.10.5  table eth0rt priority 100
ip rule add to   192.168.10.5  table eth0rt priority 100
ip rule add from 192.168.10.10 table eth1rt priority 101
ip rule add to   192.168.10.10 table eth1rt priority 101
```

Priority must be specified explicitly. Without it, iproute2 auto-assigns a value that
makes it harder to reason about rule ordering and will not match the verification output
below.

Now verify the rules are in place:

```bash
$ ip rule list
0:      from all lookup local
100:    from 192.168.10.5 lookup eth0rt
100:    to 192.168.10.5 lookup eth0rt
101:    from 192.168.10.10 lookup eth1rt
101:    to 192.168.10.10 lookup eth1rt
32766:  from all lookup main
32767:  from all lookup default
```

And verify each table has the routes you expect:

```bash
$ ip route show table eth0rt
default via 192.168.10.1 dev eth0 src 192.168.10.5
192.168.10.0/24 dev eth0 scope link src 192.168.10.5

$ ip route show table eth1rt
default via 192.168.10.1 dev eth1 src 192.168.10.10
192.168.10.0/24 dev eth1 scope link src 192.168.10.10
```

If either table is empty or the rules are missing from `ip rule list`, the configuration
did not apply. Do not assume it worked just because the commands returned no errors.

Traffic sourced from `eth1`'s IP now uses `eth1`'s table and exits via `eth1`. Run the
tcpdump test again and both IPs will show symmetric traffic. Run `ip route get` and you
will see each IP return its own interface.

---

## Fixing the ARP problem

The kernel's own documentation for `arp_ignore`, `arp_announce`, and `arp_filter` is at
[docs.kernel.org/networking/ip-sysctl.html](https://docs.kernel.org/networking/ip-sysctl.html).
The `arp_filter` entry explicitly acknowledges the multi-NIC-same-subnet case and is worth
reading alongside this section.

```bash
sysctl -w net.ipv4.conf.all.arp_announce=2
sysctl -w net.ipv4.conf.all.arp_ignore=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.eth0.rp_filter=0
sysctl -w net.ipv4.conf.eth1.rp_filter=0
```

What each setting does:

- `arp_announce=2`: When sending ARP, only use a source IP that belongs to the same subnet
  as the target. Prevents `eth0` from advertising `eth1`'s address across the broadcast domain.
- `arp_ignore=1`: Only respond to ARP requests where the target IP is configured on the
  interface that received the request.
- `rp_filter=0`: Disables strict Reverse Path Filter validation, which would otherwise
  silently drop packets arriving on the interface that lost the routing table race.

### arp_ignore vs arp_filter: which one?

You may see some guides recommend `arp_filter=1` instead of `arp_ignore`. They are not
equivalent:

- `arp_filter=1` uses the routing table to decide which interface should answer an ARP
  request. It requires that policy routing is already correctly configured, because it
  defers to whatever `ip rule` would do. If your routing tables are wrong, your ARP
  responses will be wrong too.

- `arp_ignore=1` is simpler and more direct: only the interface the IP is actually bound to
  will answer. It works independently of the routing configuration.

In practice, use `arp_ignore=1`. It's the safer default and doesn't silently depend on
routing correctness to function. Use `arp_filter` only if you have a specific reason to tie
ARP behavior directly to your routing policy.

After applying, re-run the arping test and watch both interfaces. You should see `eth1`
replying and `eth0` silent for requests targeting `.12`. The remote host's ARP cache should
settle on `eth1`'s correct MAC and stay there.

---

## References

**Linux weak host model**
- RFC 1122, Requirements for Internet Hosts, Section 3.3.4 (strong vs. weak end system model): [rfc-editor.org](https://www.rfc-editor.org/rfc/rfc1122#section-3.3.4)

**ARP flux**
- Linux kernel ip-sysctl documentation, `arp_announce`, `arp_ignore`, `arp_filter`: [docs.kernel.org](https://docs.kernel.org/networking/ip-sysctl.html)

**Policy routing**
- Linux `ip-rule(8)` man page: [man7.org](https://man7.org/linux/man-pages/man8/ip-rule.8.html)
- Linux `ip-route(8)` man page: [man7.org](https://man7.org/linux/man-pages/man8/ip-route.8.html)

**Reverse Path Filtering**
- RFC 3704, Ingress Filtering for Multihomed Networks: [rfc-editor.org](https://www.rfc-editor.org/rfc/rfc3704)
- Linux kernel ip-sysctl documentation, `rp_filter`: [docs.kernel.org](https://docs.kernel.org/networking/ip-sysctl.html)
