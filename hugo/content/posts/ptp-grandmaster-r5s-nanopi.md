---
title: "Stratum 1 PTP Grandmaster: NanoPi R5S-LTS + NEO-M8N (Part 2)"
date: 2026-04-19
description: "Building a GPS-disciplined PTP grandmaster from a NanoPi R5S-LTS and a NEO-M8N GPS module. Part 2 of the homelab PTP series."
tags: ["ptp", "ntp", "linux", "networking", "gps"]
author: "Malcolm Frazier"
showToc: true
TocOpen: false
draft: false
---

This is part 2 of the homelab PTP grandmaster series. [Part 1](/posts/ptp-grandmaster-cm4-sr1723u10/) used a Raspberry Pi CM4 with SatPulse. This build uses a NanoPi R5S-LTS and takes a different path to the same destination.

The R5S has no standard GPIO header. It has an FPC connector. Getting a GPS module talking to it required a breakout board, a ribbon cable, a soldering iron, and more debugging than expected. The results made it worth it.

## Hardware

| Component | Cost |
|-----------|------|
| NanoPi R5S-LTS with case | $115.00 |
| HamGeek NEO-M8N GPS module | $20.67 |
| MECCANIXITY FPC-12P 0.5mm breakout (5-pack) | $8.39 |
| uxcell 12-pin 0.5mm FPC ribbon cable (5-pack) | $6.89 |
| **Total** | **$150.95** |

OS: `rk3568-sd-ubuntu-noble-core-6.1-arm64-20260319.img.gz`. Kernel 6.1.

The R5S has three Ethernet ports. eth0 is the onboard RK3568 GMAC with hardware PTP timestamping. eth1 and eth2 are RTL8125BG 2.5G NICs via PCIe with no reliable hardware timestamping. eth0 is the only interface that matters for this build.

The NEO-M8N comes with pins pre-soldered from the factory. The FPC breakout board needed a 2x6 2.54mm male header soldered on. That is the only soldering required.

![NanoPi R5S-LTS board with FPC breakout and NEO-M8N GPS module connected via ribbon cable](/images/ptp-r5s-hardware-overview.jpg)

![Assembled NanoPi R5S-LTS in case with GPS module and FPC breakout board connected externally](/images/ptp-r5s-hardware-exterior.jpg)

The GPS module and FPC breakout board sit outside the enclosure. The ribbon cable exits through the side of the case near the FPC connector.

## The FPC connector

The R5S exposes GPIO via a 12-pin 0.5mm pitch FPC connector on the board edge. A breakout board is required to work with standard Dupont wires. The relevant pins:

| FPC Pin | Signal |
|---------|--------|
| 1 | 3.3V |
| 3 | UART5_RX |
| 5 | UART5_TX |
| 9 | UART9 |
| 10 | UART9 |
| 12 | GPIO3_C5 |

The wiki documents UART5 on pins 3 and 5. UART5 does not work on kernel 6.1. After patching the DTB and verifying the pinmux, GPIO3-18 and GPIO3-19 show the correct configuration but remain unclaimed by the UART driver:

```
gpio-114 (PIN_05)
gpio-115 (PIN_03)
```

UART9 on pins 9 and 10 works out of the box with no DTB changes. This build uses `/dev/ttyS9`.

PPS on pin 12 (GPIO3_C5) requires a DTB patch to enable the `pps-gpio` driver.

## DTB patching for PPS

The DTB lives in the Rockchip resource partition, not in `/boot`. Extract and decompile:

```bash
apt-get install -y device-tree-compiler
git clone https://github.com/friendlyarm/sd-fuse_rk3568.git /root/sd-fuse
dd if=/dev/mmcblk0p4 of=/root/resource.img bs=512
mkdir -p /root/dtb-work && cd /root/dtb-work
/root/sd-fuse/tools/aarch64/resource_tool --unpack --image=/root/resource.img
dtc -I dtb -O dts /root/dtb-work/out/rk3568-nanopi5-rev05.dtb -o /root/r5s.dts 2>/dev/null
```

Add the `pps-gpio` node at the end of the root node in `/root/r5s.dts`:

```
pps {
    compatible = "pps-gpio";
    gpios = <0xbc 0x15 0x00>;
    assert-falling-edge;
    status = "okay";
};
```

`0xbc` is the phandle for GPIO3. `0x15` is 21 decimal, which is GPIO3_C5 (bank C, pin 5: 16 + 5 = 21). Recompile and flash:

```bash
dtc -I dts -O dtb /root/r5s.dts -o /root/dtb-work/out/rk3568-nanopi5-rev05.dtb 2>/dev/null
cd /root/dtb-work/out
/root/sd-fuse/tools/aarch64/resource_tool --pack --image=/root/resource-new.img *
dd if=/root/resource-new.img of=/dev/mmcblk0p4 bs=512
reboot
```

After reboot `/dev/pps0` appears and works.

## Wiring

| FPC Pin | Signal | GPS Pad |
|---------|--------|---------|
| 1 | 3.3V | VCC |
| 9 | UART9 | TXD |
| 12 | GPIO3_C5 | TIMEPULSE (PPS) |
| GND | GND | GND |

No TX wire to the GPS. gpsd only needs to receive NMEA. Connecting a TX wire caused frame errors on the GPS RXD input.

Verify NMEA is flowing:

```bash
stty -F /dev/ttyS9 9600 raw -echo
timeout 10 cat /dev/ttyS9
```

Verify PPS:

```bash
ppstest /dev/pps0
```

```
source 0 - assert 1776474438.102968279, sequence: 1184 - clear  0.000000000, sequence: 0
source 0 - assert 1776474439.102977401, sequence: 1185 - clear  0.000000000, sequence: 0
source 0 - assert 1776474440.102974722, sequence: 1186 - clear  0.000000000, sequence: 0
```

## Software stack

The CM4 build used SatPulse. This build uses gpsd + chrony + ptp4l + phc2sys directly.

### gpsd

`/etc/default/gpsd`:

```
START_DAEMON="true"
OPTIONS="-n -b"
DEVICES="/dev/ttyS9 /dev/pps0"
USBAUTO="false"
```

Use `OPTIONS=` not `GPSD_OPTIONS=`. The Ubuntu 24.04 gpsd service reads `OPTIONS`. Using the wrong variable causes gpsd to start without `-n`, so it will not write to SHM until a client connects.

```bash
systemctl enable gpsd
systemctl start gpsd
```

Verify SHM output with `ntpshmmon`. You should see NTP0 (GPS NMEA) and NTP2 (PPS).

### chrony

Add to `/etc/chrony/chrony.conf`:

```
refclock PPS /dev/pps0 refid PPS precision 1e-9 trust
refclock SHM 0 refid GPS precision 1e-1 offset 0.060 delay 0.2 noselect
allow 172.22.22.0/24
makestep 1 3
leapsectz right/UTC
```

When locked to PPS, tracking looks like this:

```
Reference ID    : 50505300 (PPS)
Stratum         : 1
Last offset     : +0.000000068 seconds
RMS offset      : 0.000000109 seconds
```

### ptp4l

`/etc/linuxptp/ptp4l.conf`:

```ini
[global]
serverOnly 1
tx_timestamp_timeout 100
ptp_minor_version 0
utc_offset 37

[eth0]
```

`/etc/systemd/system/ptp4l.service`:

```ini
[Unit]
Description=Precision Time Protocol (PTP) service
After=network-online.target chrony.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/ptp4l -f /etc/linuxptp/ptp4l.conf
ExecStartPost=/bin/sh -c 'sleep 15 && pmc -u -b 0 "SET GRANDMASTER_SETTINGS_NP clockClass 6 clockAccuracy 0x22 offsetScaledLogVariance 0xffff currentUtcOffset 37 leap61 0 leap59 0 currentUtcOffsetValid 1 ptpTimescale 1 timeTraceable 1 frequencyTraceable 1 timeSource 0x20"'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

The `ExecStartPost` pmc command is required. Without it, ptp4l announces `currentUtcOffsetValid 0` and clients cannot correctly apply the TAI offset. The `-t 1` flag must be omitted. With it, the SET appears to succeed but the values do not apply. The sleep 15 gives ptp4l time to reach MASTER state first.

Verify it applied:

```bash
pmc -u -b 0 'GET TIME_PROPERTIES_DATA_SET'
```

```
currentUtcOffset      37
currentUtcOffsetValid 1
timeTraceable         1
```

### phc2sys

The PHC runs in TAI. The system clock runs in UTC. TAI is currently 37 seconds ahead of UTC. phc2sys keeps the PHC at system clock + 37 seconds.

`/etc/systemd/system/phc2sys.service`:

```ini
[Unit]
Description=Synchronize PTP hardware clock to system clock
After=ptp4l.service chrony.service
Requires=ptp4l.service

[Service]
Type=simple
ExecStart=/usr/sbin/phc2sys -s CLOCK_REALTIME -c eth0 -O 37 -r -r -m
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Bugs and gotchas

### UART5 is broken on kernel 6.1

The FriendlyElec wiki documents UART5 on FPC pins 3 and 5. On kernel 6.1 with the stock Ubuntu Noble image, these pins show the correct pinmux but remain unclaimed by the UART driver regardless of DTB configuration. Use UART9 on pins 9 and 10 (`/dev/ttyS9`) instead.

### pmc SET requires no -t 1 flag

On this version of linuxptp, `SET GRANDMASTER_SETTINGS_NP` appears to succeed with `-t 1` but the values do not take effect. Run pmc without it and verify with `GET TIME_PROPERTIES_DATA_SET`.

### gpsd OPTIONS vs GPSD_OPTIONS

The Ubuntu 24.04 gpsd service reads `OPTIONS` from `/etc/default/gpsd`. Using `GPSD_OPTIONS` instead causes gpsd to start without `-n` and the SHM refclocks stay empty.

### makestep 1 -1 causes runaway clock stepping

WAN NTP servers are typically ~100ms behind GPS truth. With `makestep 1 -1`, chrony steps the clock on every update indefinitely and oscillates between GPS time and WAN NTP time. Use `makestep 1 3`.

### Clients need trust prefer on the PHC refclock

With enough WAN NTP servers in the config, chrony's majority vote algorithm marks the PHC as a falseticker because it disagrees with WAN NTP by ~100ms. The fix:

```
refclock PHC /dev/ptp0 poll 0 dpoll -2 tai refid PTP trust prefer
```

`trust` prevents the PHC from being marked as a falseticker. `prefer` selects it over other sources. WAN NTP servers remain as fallback.

## Client configuration

Both clients are unchanged from the CM4 build. No phc2sys on clients. Chrony reads the PHC directly via the `tai` refclock.

`/etc/chrony/conf.d/ptp.conf`:

```
refclock PHC /dev/ptp0 poll 0 dpoll -2 tai refid PTP trust prefer
server nanopi-rp5s-lts.lab.opscode.io iburst minpoll 0 maxpoll 4
server rpi-cm4-ptp.lab.opscode.io iburst minpoll 0 maxpoll 4
```

`/etc/systemd/system/chrony.service.d/ptp.conf`:

```ini
[Unit]
After=ptp4l.service
```

**RK1** (Ubuntu 22.04, linuxptp 3) at `/etc/linuxptp/ptp4l.conf`:

```ini
[global]
slaveOnly 1
tx_timestamp_timeout 100

[eth0]
```

**CM4** (Ubuntu 24.04, linuxptp 4) at `/etc/linuxptp/ptp4l.conf`:

```ini
[global]
clientOnly 1
tx_timestamp_timeout 200
ptp_minor_version 0

[eth0]
```

## Results

### Grandmaster accuracy

```
$ chronyc sourcestats
Name/IP Address            NP  NR  Span  Frequency  Freq Skew  Offset  Std Dev
==============================================================================
PPS                        22  11   333     -0.000      0.005     -0ns   625ns

$ chronyc tracking
Reference ID    : 50505300 (PPS)
Stratum         : 1
Last offset     : +0.000000068 seconds
RMS offset      : 0.000000109 seconds
```

109ns RMS from GPS truth.

### Three-way timing comparison

| Source | Offset | Uncertainty |
|--------|--------|-------------|
| PTP, hardware timestamping | -1 to -6 ns | ±84 to 291 ns |
| LAN NTP, from this grandmaster | -7 to -66 µs | ±171 to 253 µs |
| WAN NTP, public pools | -96 to -104 ms | ±31 to 96 ms |

Same three-tier pattern as Part 1. Each tier is roughly 1000x worse than the one above it. The WAN NTP offset of ~100ms from GPS is not a misconfiguration. Those servers are genuinely less accurate than GPS.

### Client comparison: CM4 vs RK1

```
#* PTP   0   0   377   1    -1ns[  -1ns] +/-  291ns   <- RK1 (Rockchip GMAC)
#* PTP   0   0   210   2    -6ns[  -6ns] +/-   84ns   <- CM4 (BCM54210PE)
```

Same result as Part 1. The BCM54210PE timestamps at the PHY layer. The Rockchip GMAC timestamps at the MAC layer. That extra stage costs about 3-4x in uncertainty.

### Topology matters

Same test as Part 1. See that post for the explanation. Numbers here are consistent with Part 1.

**Through the TP-Link AXE5400 consumer router:**

```
ptp4l: master offset     -84886 s2 path delay    299121
ptp4l: master offset     167775 s2 path delay    299121
ptp4l: master offset    -700862 s2 path delay    373459
```

**Direct to the Turing Pi switch:**

```
ptp4l: master offset         12 s2 path delay      2829
ptp4l: master offset         76 s2 path delay      2824
ptp4l: master offset        -20 s2 path delay      2824
```

300µs path delay through the router. 2.8µs direct to the switch.

### Holdover test

GPS antenna disconnected at 01:08 UTC. Reconnected at 15:47 UTC.

Duration: 14 hours 39 minutes. Total drift from GPS truth: **82.6 microseconds.**

Both clients stayed on PTP the entire time without falling back to WAN NTP.

```
#* PTP   0   0   377   1    +62ns[  +148ns] +/-  291ns   <- RK1 after 14h holdover
#* PTP   0   0   210   3     -9ns[   -23ns] +/-   77ns   <- CM4 after 14h holdover
```

Recovery after antenna reconnect: under 2 minutes.

## Monitoring

Same Prometheus and Grafana stack as Part 1. `node_exporter` and `chrony_exporter` on all three machines. No satpulse exporter on this build.

![PTP Timing Dashboard showing GPS locked, stratum 1, nanosecond accuracy on both clients](/images/ptp-r5s-dashboard-full.png)

## CM4 vs R5S: which is the better grandmaster

Both builds produce a working stratum 1 PTP grandmaster at sub-microsecond client accuracy. The differences are in software complexity, physical form factor, and holdover performance.

The CM4 build uses SatPulse, which handles GPS configuration, PHC discipline, and chrony integration in a single daemon. It is significantly easier to configure, and everything fits cleanly inside the enclosure. The R5S build requires manually wiring together gpsd, chrony, ptp4l, phc2sys, and pmc, with several non-obvious gotchas along the way. The GPS module and breakout board sit outside the case.

The R5S also gives you three Ethernet ports and a capable Linux router out of the box. If you want a grandmaster and a router in one device, the R5S is the better fit.

The holdover results were not expected:

| Build | Duration | Total drift | Drift rate |
|-------|----------|-------------|------------|
| CM4 + SR1723U10 | 10 hours | ~15ms | ~1.5ms/hr |
| R5S + NEO-M8N | 14h 39m | 82.6µs | ~5.6µs/hr |

The R5S crystal held 270x tighter over a longer test period. Whether this reflects a better crystal in the RK3568 SoC or operating temperature differences during the test is unclear. Either way, 82.6µs of drift over nearly 15 hours from an uncompensated crystal is a strong result.

For client accuracy, both grandmasters produce the same results on the same clients. The grandmaster accuracy floor is well below what the clients can measure.

If you have a CM4 available and just want a grandmaster, use that build. SatPulse makes it dramatically simpler.

## References

- [NanoPi R5S-LTS product page](https://www.friendlyelec.com/index.php?route=product/product&product_id=287)
- [Kyle Manna: FriendlyElec NanoPi R5S as PTP Grandmaster Clock with GNSS/GPS Discipline](https://blog.kylemanna.com/hardware/nanopi-r5s-as-ptp-grandmaster-clock-with-gnss-gps-discipline/)
- [amagai-ak/nanopi-r5s-ptp](https://github.com/amagai-ak/nanopi-r5s-ptp)
- [Part 1: Stratum 1 PTP Grandmaster: CM4 + SR1723U10 (Part 1)](/posts/ptp-grandmaster-cm4-sr1723u10/)
