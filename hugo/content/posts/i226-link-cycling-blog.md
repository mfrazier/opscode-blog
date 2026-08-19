---
title: "Ethernet Link Cycling During Boot on the Intel i226"
date: 2026-08-18
description: "Root cause analysis of repeated link up/down transitions at 10 and 100 Mbps during boot on Intel i226 controllers, from an embedded ARM platform to COTS cards on a desktop."
tags: ["DUT", "kernel", "Linux", "networking", "raspberry-pi"]
---

While investigating a separate network issue at work, we observed unexpected
Ethernet link behavior on an embedded ARM system. During boot, the switch port
facing it reports link up at 100 Mbps, then down, then up at 100 Mbps again,
three times in total, before finally settling at 1 Gbps once the operating
system is up. Before proceeding, we needed to determine whether the cycling
was related to the issue at hand or independent behavior that could be ruled
out.

The cycling had no operational impact: traffic passed cleanly once the system
was up. But unexplained behavior on a system this critical still needed a root
cause. I supported the investigation from the Linux systems engineering side,
then continued testing at home on a desktop with two COTS i226 cards to
determine how much of the behavior was specific to that platform. The answer:
none of it.

Results up front:

- The link cycling is expected i226 behavior, not a fault (and the underlying
  cause, PCIe endpoint resets during boot, applies to practically any NIC on
  any platform; what varies is whether you notice).
- Each link drop corresponds to a PCIe reset issued by a boot stage taking
  ownership of the bus. The controller re-establishes link on its own after
  every reset, per its NVM configuration.
- The i226 does not advertise gigabit until a driver claims the device,
  whether that is the operating system's kernel driver or a driver in platform
  firmware. The claimed and unclaimed states are visible as a single
  undocumented bit in the PHY Power Management register, which the hardware
  manages itself and rejects host writes to.
- COTS i226-V and i226-LM cards in a desktop show the same cycling. The
  difference is when gigabit arrives: consumer desktop firmware ships its own
  NIC driver and claims the controller during POST, so the desktop reaches
  gigabit before the operating system starts. The embedded platform's boot
  firmware ships no driver for this part, so it stays at the lower speed
  until Linux loads the igc NIC driver.

## The observation

The system is an embedded ARM platform on a custom carrier board running a
vendor Linux BSP, using Intel I226-IT controllers on PCIe. It boots through a
multi-stage vendor chain ending in UEFI, each stage separately signed.

Cold boot, switch port and serial console captured side by side:

| # | Switch port              | Stage                              |
|---|--------------------------|------------------------------------|
| 1 | Up, 100 Mbps, ~7s        | Early boot firmware                |
| 2 | Down, ~5s                | UEFI initializes PCIe              |
| 3 | Up, 100 Mbps, ~5s        | UEFI idle                          |
| 4 | Down, ~3s                | UEFI-to-kernel handoff             |
| 5 | Up, 100 Mbps, ~6s        | Early kernel boot                  |
| 6 | Down, ~10s               | Kernel PCIe setup, then igc probe  |
| 7 | Up, 1 Gbps, stable, ~18s | igc running. Final state           |

The kernel logs exactly one Ethernet event for the entire boot:

```
igc 0000:01:00.0 eth2: NIC Link is Up 1000 Mbps Full Duplex
```

Every 100 Mbps transition happens before the kernel is loaded, which rules
out the operating system and everything in it in one step. The cause lives in
firmware.

## The resets

The platform vendor publishes their UEFI source, and it answers the question
directly, comment included:

```c
/* Apply PERST# to endpoint and go for link up */
/* Assert PEX_RST */
val  = MmioRead32 (Private->ApplSpace + 0x0);
val &= ~(0x1);
MmioWrite32 (Private->ApplSpace + 0x0, val);
```

Every link drop in the table is a PCIe reset. UEFI resets the NIC when it
initializes PCIe, resets it again at kernel handoff, the kernel's PCIe driver
resets it a third time during enumeration, and igc resets it twice more
during probe. Each stage that takes ownership of the bus resets the endpoint
into a known state before training the link. That is standard PCIe bring-up on
any platform. Five resets, but only three observable drops, because the last
three fall inside one window.

The controller brings the link back up by itself. Per the I226 datasheet, it
reloads its configuration from NVM automatically after power-up, after PCIe
reset is released, or on a software reset, then negotiates a link with no host
involvement.

## Why 100 Mbps

The i226 treats "driver attached" and "powered but no driver" as different
states, and it does not advertise gigabit in the second one. This is not a
forced speed; the NVM reads back auto-negotiate. It is Intel power-management
behavior, which Intel names in family documentation but never fully documents
for the I226: neither the relevant NVM bits nor the PHY Power Management
register layout are published.

The system has no ethtool and no network access, so the readback is raw
Python against the controller's PCI memory window:

```python
import mmap, os, struct
fd = os.open("/sys/bus/pci/devices/0000:01:00.0/resource0", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 0x20000)
def rd(o): return struct.unpack("<I", m[o:o+4])[0]
print("PHPM = 0x%08X" % rd(0x0E14))
```

PHY Power Management (PHPM) lives at offset 0x0E14. Read it with no driver
loaded, load igc, read again:

```
no driver   PHPM = 0x00045298   link = 100 Mbps
igc loaded  PHPM = 0x00045288   link = 1000 Mbps
XOR         =      0x00000010   bit 4
```

Loading the driver coincides with exactly one bit changing, and the link
goes from 100 Mbps to gigabit. Two measurements pin down what that bit is.
Host writes to it are rejected in both directions, while fourteen other bits
in the same register accept writes and hold. And the igc source never writes
this register at all, only reads it. So the hardware manages the bit itself,
flipping it when the device is claimed: a state marker, not a switch. That
same write protection is why this stays a correlation rather than causal
proof; the bit cannot be flipped in isolation to confirm it.

## Reproducing it on a desktop

To separate chip behavior from platform behavior: a Dell desktop, the two
COTS cards, and a Raspberry Pi cabled directly to the card under test as the
link monitor, polling carrier and speed at 10 Hz:

```bash
IF=eth0
while true; do
  printf '%s carrier=%s speed=%s\n' "$(date +%H:%M:%S.%3N)" \
    "$(cat /sys/class/net/$IF/carrier)" "$(cat /sys/class/net/$IF/speed)"
  sleep 0.1
done | tee /tmp/linklog.txt
```

With igc blacklisted so no operating system driver could load, a cold boot
produced:

```
20:56:29.033  UP    10 Mbps
20:56:33.074  DOWN            after 4.0s
20:56:38.253  UP  1000 Mbps   after 5.2s
```

Different vendor, board, and firmware. Same mechanism: link at a lower speed,
reset, gigabit once claimed.

Reading the NVM configuration off all three parts:

|                | Embedded I226-IT | Desktop I226-V | Desktop I226-LM |
|----------------|------------------|----------------|-----------------|
| Word 0x24      | 0x0681         | 0x0681         | 0x0601          |
| Word 0x0F      | 0x8200         | 0x8200         | 0x8200          |
| Option ROM     | none           | none           | present         |
| Subsystem ID   | Intel default  | Intel default  | 0x0002          |

The V is byte-identical to the I226-IT on the embedded system on every
relevant word, so that system's NIC configuration is Intel's stock
configuration. The register probe agreed: identical writable bits, identical
protected bits including bit 4, identical driver-transition delta on both
desktop cards.

## The variant detour

The first card tested identified as an I226-LM (`8086:125b`) rather than the
consumer I226-V (`8086:125c`) and behaved differently: it reported a driver
attached with igc blacklisted, reached gigabit before the operating system
started, and linked at 10 Mbps on some boots and 100 on others. The table
shows it is configured differently too, including an option ROM the other
parts lack.

I could not fully attribute that behavior to the card, since the test machine
is a vPro system with an active Management Engine and the V showed some of the
same pre-OS behavior in the same machine.

Check the device ID before trusting any result. Product listings frequently
advertise an i226 and ship an i225, and the i226 itself has multiple variants
with different NVM configurations. The PCI vendor and device ID come from the
controller's own configuration space, so they identify the silicon regardless
of what the packaging says:

```bash
lspci -nn | grep -i eth   # 8086:125b = LM, 8086:125c = V, 8086:125d = IT
```

## Two firmware menus

Parked at the embedded system's UEFI menu, the link holds at 100 Mbps
indefinitely. Parked in the Dell BIOS setup, it holds at 1000. Same silicon,
same NVM configuration, same protected bit. The difference is that Dell's
firmware includes a NIC driver that claims the controller during POST, and the
embedded platform's ships none, so it stays in the unclaimed state until Linux
loads the igc NIC driver.

Disabling PXE and the UEFI network stack on the Dell did not change it; the
network stack serves pre-OS features independently of PXE per Dell's own
documentation, and this is a vPro machine with an active Management Engine,
which is not governed by those BIOS settings.

The rule that explains all of it: **the i226 does not advertise gigabit until
a driver claims it.** How much cycling you see depends on how many times your
boot chain resets the endpoint and whether your firmware claims the part. The
resets generalize to any NIC on any platform; linking at a lower speed while
unclaimed is Intel i225/i226 family design, and three i226s is as far as I
verified.

## Takeaways

- **Boot-time link cycling is normal.** PCIe resets from each boot stage
  drop the link on any NIC; linking at a lower speed while unclaimed is
  Intel's design, and platform firmware determines how much of it you see.
- **The kernel log locates the problem.** A single igc link event for the
  whole boot eliminated every operating-system-level explanation before the
  investigation properly started.
- **Vendor source beats speculation.** The platform vendor publishes their
  UEFI source and the resets are in it, commented. Most of this work was
  reading public code.
- **You can read controller registers with nothing installed.** No ethtool,
  no package manager, no network access: map the card's PCI memory window
  through sysfs and read it directly. Thirty lines of Python answered a
  question the documentation does not.
- **Identify silicon by device ID, not by product listing.** The i226-LM and
  i226-V ship different NVM configurations and behaved differently before the
  operating system loaded, and cards sold as i226 are frequently i225.
  `lspci -nn` reads it out of configuration space and settles it.
