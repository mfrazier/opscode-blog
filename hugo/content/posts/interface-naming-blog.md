---
title: "Linux Predictable Interface Names Are Only as Stable as Your PCI Bus"
date: 2026-08-29
description: "A complete account of how Linux names network interfaces, why those names change without warning, and how to write configuration that survives it. Starting from a RAID controller that renamed four NICs."
tags: ["kernel", "linux", "networking", "systemd", "ubuntu"]
---

A fleet of servers, ordered as the same part number, imaged identically,
configured by the same Ansible role. One of them booted with no network.

Nothing in the configuration was wrong. Nothing in the operating system had
changed. A storage controller was mounted in the front bay rather than a rear
riser slot, which put it on a PCIe root port that enumerates earlier, which
shifted every PCI bus number behind it, which renamed four network interfaces,
which meant every line of network configuration matching those names quietly
applied to nothing at all.

Predictable interface names are in use on every modern Linux system and rarely
examined beyond the fact that they exist. The mechanism producing them is
documented, but the conditions under which a name changes are distributed
across systemd, the kernel, platform firmware and the PCI enumeration process,
and they tend to become relevant only after a name has already moved.

This post covers that mechanism end to end: where each name comes from, the
four inputs that can change it, and how to write network configuration that
survives the change.

Results up front:

- Predictable names are **derived**, not permanent. `enp` names encode PCI bus
  position and change when enumeration changes. `eno` names encode a firmware
  index and survive bus renumbering, though not a firmware change that alters
  that index.
- Four independent inputs determine a name: PCI topology, platform firmware,
  the kernel driver, and the systemd naming scheme version. Any of them
  moving moves the name, and three of them move on ordinary maintenance.
- Netplan does not warn when a match matches nothing. The data path fails
  closed, in that an unmatched interface stays down rather than coming up with
  the wrong addressing, but the control path fails silently: no error is
  raised to indicate the configuration did not apply.
- The durable fix is to match on something belonging to the card, in practice
  its MAC address, whether expressed in netplan or in a systemd `.link` file.
  Matching on interface name or PCI path keys on the enumeration and fails the
  same way. The tradeoff is real: MAC matching is deterministic but per host,
  so it requires inventory data that name matching does not.

## Part 1: How names get assigned

### The classic scheme, and why it was replaced

There was never really a scheme. A network driver allocates its device with a
name template, conventionally `"eth%d"`. When it calls `register_netdev()`,
the kernel expands the `%d` to the lowest index not currently in use for that
template and writes it into `dev->name`. This happens under RTNL, inside the
kernel, before any userspace process knows the device exists.

The index therefore reflects **registration order**, which is not a property
of the hardware. systemd's own documentation
([Predictable Network Interface Names](https://systemd.io/PREDICTABLE_INTERFACE_NAMES/))
puts the consequence plainly:

> As the driver probing is generally not predictable for modern technology
> this means that as soon as multiple network interfaces are available the
> assignment of the names `eth0`, `eth1` and so on is generally not fixed
> anymore and it might very well happen that `eth0` on one boot ends up being
> `eth1` on the next. This can have serious security implications, for example
> in firewall rules which are coded for certain naming schemes.

Several fixes were attempted before the current one. That same document is
worth reading for the history, but the short version is that udev once
supported pinning `ethX` names by MAC address, and it went badly: it required
a writable root, it broke statelessness because booting an image on new
hardware rewrote its own configuration, MAC addresses turned out not to be
fixed on plenty of embedded and virtualized hardware, and worst of all
userspace was racing the kernel for names in the same `ethX` namespace.

Dell's `biosdevname` took a different approach, deriving names from fixed slot
topology reported by firmware. systemd did not adopt `biosdevname` itself; it
implemented a natively supported scheme along similar lines, described in its
own documentation as generalizing the approach `biosdevname` pioneered.

One operational detail from that same document is worth remembering: if
`biosdevname` is installed it takes precedence over systemd's scheme, as do
any custom udev rules that set an interface name.

### The current scheme

Since systemd v197, udev derives interface names from stable device
attributes. The mechanism has two halves that are worth keeping separate in
your head.

**First**, the `net_id` udev builtin inspects the device and computes several
candidate names, exporting each as a device property. It does not rename
anything.

**Second**, a `.link` file selects among those candidates according to a
configured policy, and the winner is exported as `ID_NET_NAME`, which a udev
rule uses to set `NAME`.

The candidates:

| Property | Prefix | Derived from | Example |
|---|---|---|---|
| `ID_NET_NAME_ONBOARD` | `eno` | Firmware onboard index (SMBIOS type 41, ACPI `_DSM`) | `eno8303` |
| `ID_NET_NAME_SLOT` | `ens` | PCI hotplug slot index | `ens1f0` |
| `ID_NET_NAME_PATH` | `enp` | PCI bus, device, function | `enp65s0f0` |
| `ID_NET_NAME_MAC` | `enx` | MAC address | `enx0250b6000000` |
| none | `eth` | Kernel registration order | `eth0` |

**The prefix tells you the stability class.** `eno` and `ens` come from
firmware indices describing a physical connector, assigned per board design,
and are unaffected by bus renumbering. `enp` is computed from where the device
landed during PCI enumeration this boot. Neither is immutable: a firmware
change that alters an onboard or slot index moves an `eno` or `ens` name too.
The point is that two interfaces in the same machine can have very different
stability properties, and the only visible indication is two letters.

Inspect any interface:

```bash
udevadm test-builtin net_id /sys/class/net/enp65s0f0np0
```

### Reading an enp name

udev assembles `ID_NET_NAME_PATH` as `p<bus>s<slot>f<func>` plus an optional
port suffix:

| Fragment | Value | Source |
|---|---|---|
| `en` | Ethernet | Device type prefix |
| `p65` | PCI bus 65, which is 0x41 | Assigned at enumeration |
| `s0` | PCI device number 0 | Position on its bus |
| `f0` | PCI function 0 | Emitted when the function number is non-zero, or the device is multifunction |
| `np0` | Port `p0` | `n` is udev's prefix; `p0` is the kernel's `phys_port_name` |

Drivers on multi-port cards export `phys_port_name` to identify the
front-panel port matching a given PCI function. Where a driver exports a
non-zero `dev_port` instead, udev emits `d<n>`. Where it exports neither,
there is no suffix. On a quad-port card the functions are `f0` through `f3`,
and the function number is stable regardless of which bus receives the card.

### The selection policy

The shipped default, in `/usr/lib/systemd/network/99-default.link`:

```ini
[Match]
OriginalName=*

[Link]
NamePolicy=keep kernel database onboard slot path
AlternativeNamesPolicy=database onboard slot path
MACAddressPolicy=persistent
```

This file has changed over time. Current systemd appends `mac` to
`AlternativeNamesPolicy`, and older releases omit the `[Match]` section
entirely. `NamePolicy` has been stable, and it is the line that decides the
primary name, but read your own copy rather than trusting any published
version of it.

Each policy is tried in order and the first that succeeds wins:

| Token | Behaviour |
|---|---|
| `keep` | Stop if the name was already set by userspace |
| `kernel` | Stop if the kernel claims its own name is predictable |
| `database` | Use the udev hardware database entry |
| `onboard` | Use `ID_NET_NAME_ONBOARD` |
| `slot` | Use `ID_NET_NAME_SLOT` |
| `path` | Use `ID_NET_NAME_PATH` |

Note what is **not** there: `mac`. The `enx` name is computed on every
interface and is not used unless you ask for it. systemd's documentation
states only that the MAC-based policy is available but not applied by default;
it does not give a reason.

The first two tokens key on `dev->name_assign_type`, which the kernel records
at registration:

| Value | Constant | Meaning |
|---|---|---|
| 0 | `NET_NAME_UNKNOWN` | Origin not reported |
| 1 | `NET_NAME_ENUM` | Kernel registration order |
| 2 | `NET_NAME_PREDICTABLE` | Driver derived it from stable attributes |
| 3 | `NET_NAME_USER` | Set by userspace at creation |
| 4 | `NET_NAME_RENAMED` | Renamed by userspace after creation |

Readable at `/sys/class/net/<iface>/name_assign_type`, with one wrinkle:
`alloc_etherdev()` passes `NET_NAME_UNKNOWN`, so a driver that does not set
the field leaves it at 0 and the sysfs read returns `EINVAL` rather than a
number. udev treats unreadable or unparseable the same as `NET_NAME_ENUM`:
rename.

## Part 2: Four things that change a name

### 1. PCI topology

Bus numbers are not properties of slots. They are handed out during
enumeration, when firmware walks the PCI hierarchy depth-first and programs
each bridge's primary, secondary and subordinate bus number registers in its
type 1 configuration header. A bridge receives the next free number for its
secondary side, its subtree is walked to completion, and its subordinate
register is set to the highest number found beneath it.

The numbering is positional and sequential. It depends on how many bridges
precede a device in traversal order, **not** on which physical slot the
device occupies.

Populate a root port that is walked earlier and every bus number allocated
after it shifts upward. The device that triggers this does not have to be a
network card. In our case it was a RAID controller.

### 2. Platform firmware

Firmware performs the enumeration, so firmware settings that alter PCI
topology alter bus numbering: slot bifurcation, SR-IOV global enable,
disabling onboard devices or slots. A firmware update that changes any
default in those areas produces different bus numbers on identical hardware.

### 3. The kernel driver

That `np0` suffix exists only because the driver for that card exports
`phys_port_name`. The suffix is a property of the driver, not of the hardware,
which means it is subject to driver development.

If a driver begins exporting `phys_port_name` where it previously did not, the
same physical port changes from `enp65s0f0` to `enp65s0f0np0` with no hardware
change at all, and any configuration matching the old name stops matching. I
have not traced a specific driver where this happened, so treat this as a
mechanism the naming scheme permits rather than a documented incident.

### 4. The systemd naming scheme version

This is the one people miss. **The naming rules themselves are versioned.**

Each systemd release may change how names are derived, and each revision is a
named scheme. They accumulate, each inheriting the previous plus its own
flags. From `netif-naming-scheme.h`:

```c
NAMING_V250 = NAMING_V249 | NAMING_XEN_VIF,
NAMING_V251 = NAMING_V250 | NAMING_BRIDGE_MULTIFUNCTION_SLOT,
NAMING_V252 = NAMING_V251 | NAMING_DEVICETREE_ALIASES,
NAMING_V253 = NAMING_V252 | NAMING_USB_HOST,
```

And changes are sometimes reverted. From
[systemd.net-naming-scheme(7)](https://www.freedesktop.org/software/systemd/man/latest/systemd.net-naming-scheme.html)
on v251:

> Since version v247 we no longer set `ID_NET_NAME_SLOT` if we detect that a
> PCI device associated with a slot is a PCI bridge as that would create
> naming conflict when there are more child devices on that bridge. Now, this
> is relaxed and we will use slot information to generate the name based on it
> but only if the PCI device has multiple functions. ... Note, this is
> reverted in v255.

The change concerns `ID_NET_NAME_SLOT` specifically, so a multifunction card
behind a PCI bridge can receive an `ens` name under v251 through v254 and fall
back to an `enp` name under v255.

The default is fixed at systemd compile time, which in practice means fixed
per distribution release:

| Distribution | systemd | Default scheme |
|---|---|---|
| Ubuntu 22.04 LTS | 249 | v249 |
| Ubuntu 24.04 LTS | 255 | v255 |

Those are the upstream defaults for those systemd versions. A distribution can
patch the compiled-in default, so confirm on the machine rather than trusting
the table.

**A release upgrade moves the scheme by six versions.** This is not
hypothetical: [Launchpad bug 2092945](https://bugs.launchpad.net/ubuntu/+source/systemd/+bug/2092945)
records a 22.04 to 24.04 upgrade breaking static addressing because v250
introduced Xen netfront naming.

Pin it if you care:

```
GRUB_CMDLINE_LINUX_DEFAULT="net.naming-scheme=v249"
```

Check what is active:

```bash
udevadm test-builtin net_id /sys/class/net/eno1 2>&1 | grep NAMING_SCHEME
```

## Part 3: When a device gets no predictable name at all

Some cards never receive a predictable name. One of ours is an Oregano Systems
syn1588 PCIe NIC, a PTP timing card built around an Altera FPGA. `lspci`
classifies it correctly as class `0200`, an Ethernet controller, but cannot
resolve the device:

```
42:00.0 Ethernet controller [0200]: Altera Corporation Device [1172:1000]
```

The vendor and device ID belong to the FPGA, not to a NIC model in the PCI ID
database, because the Ethernet MAC is one function synthesized inside the FPGA
rather than a discrete controller. Its interface comes up as `eth0`.

The reason is not the FPGA, and not that the driver is out of tree. The netdev
has a perfectly good parent device link:

```
# ls -l /sys/class/net/eth0/device
/sys/class/net/eth0/device -> ../../../oregano-mac.4.auto
```

Full ancestry:

```
/sys/devices/pci0000:40/0000:40:03.2/0000:42:00.0/oregano-mac.4.auto/net/eth0
```

The PCI function is in the chain. It is just not the netdev's **immediate**
parent. The driver registers an intermediate platform device between the PCI
function and the network device. The `.auto` suffix is the kernel's
convention for a platform device registered with `PLATFORM_DEVID_AUTO`,
formatted `<name>.<id>.auto`.

That intermediate device is what breaks name generation:

```
ID_NET_NAME_MAC=enx02005e100000
eth0: Parent device is in the platform subsystem.
eth0: Failed to get platform ID: Invalid argument
eth0: Could not find usb parent device: No such file or directory
eth0: Could not get bcma parent device: No such file or directory
```

| Generator | Result | Why |
|---|---|---|
| `names_pci()` | Never runs | Requires the direct parent to be in the `pci` subsystem with no bus in between; returns `ENOENT` silently. This is why there is no PCI line in the output at all |
| `names_platform()` | `EINVAL` | Expects an ACPI-derived name of form `VVVVMMMM:II`, like `HISI00C2:00`. `oregano-mac.4.auto` does not parse |
| `names_devicetree()`, `names_usb()`, `names_bcma()` | Fail | No `of_node`, no USB or bcma ancestor |
| `names_mac()` | Succeeds | Produces the `enx` name, which the default policy does not consult |

No usable candidate, no rename, kernel registration name persists.

Two things worth taking from this. **Whether a device gets a predictable name
is a property of its driver's registration code, not of the silicon.** And
that `eth0` is deterministic only because exactly one interface on the machine
uses the `eth%d` template. A second such card would race on registration
order, and the problem predictable naming was invented to solve comes straight
back.

Diagnose any stubborn `ethN` with:

```bash
ls -l /sys/class/net/<iface>/device
udevadm test-builtin net_id /sys/class/net/<iface>
```

## Part 4: The incident

Two servers, same SKU, same image, same role. One had its RAID controller in a
rear riser, the other in the front bay.

The `0000:40` bus, from `lspci -tv`:

| Root port | Working | Broken |
|---|---|---|
| `40:01.1` | *(empty)* | **RAID controller, bus 0x41** |
| `40:03.1` | X710 quad, bus **0x41** | X710 quad, bus **0x42** |
| `40:03.2` | syn1588, bus 0x42 | I350 quad, bus **0x43** |

Root port `01.1` is enumerated before `03.1`. Unpopulated, the NIC slot gets
the first free bus number. Populated, the controller takes 0x41 and everything
behind it moves up one.

The X710 carried the primary uplink. Its ports:

| | Working | Broken |
|---|---|---|
| X710 quad | `enp65s0f0np0` .. `f3np3` (bus 65 = 0x41) | `enp66s0f0np0` .. `f3np3` (bus 66 = 0x42) |

Every `enp65*` stanza matched nothing.

### Why it failed silently

Netplan does not implement `match` plus `set-name` in networkd. It renders
them into systemd `.link` files under `/run/systemd/network/`, matching on
`OriginalName=`, at prefix `10-` so they beat `99-default.link`. You can watch
them being parsed:

```
Parsed configuration file "/run/systemd/network/10-netplan-eth0.link"
Parsed configuration file "/run/systemd/network/10-netplan-enp65s0f0np0.link"
```

When no device carries that `OriginalName`, the file matches nothing. No
error, boot proceeds, interfaces sit unrenamed and down.

So "matching by name in netplan" is really "matching `OriginalName=` in a
generated `.link` file," and it fails the way any unmatched `.link` file
fails: silently.

## Part 5: What to key on instead

Everything below trades convenience for determinism. Matching on interface
name is a single template that applies to every host in a fleet, which is
exactly why it is attractive and exactly why it breaks: it assumes an
enumeration outcome. Matching on MAC address does not assume anything, but the
MAC is a per host value, so it has to come from somewhere. Deciding where that
inventory comes from is the real cost of the change, not the YAML.

### In netplan

Per the [Netplan YAML reference](https://netplan.readthedocs.io/en/stable/netplan-yaml/),
`match` supports exactly three properties. There is no PCI path option.

| Property | Globs | Renderer | Survives renumbering |
|---|---|---|---|
| `name` | Yes | networkd, NetworkManager | **No**, if the pattern contains the bus number |
| `macaddress` | **No** | networkd, NetworkManager | **Yes** |
| `driver` | Yes | **networkd only** | **Yes**, but cannot distinguish ports on one card |

All specified properties must match; they combine with AND.

```yaml
# fragile
enp65s0f0np0:
  match:
    name: enp65s0f0np0
  set-name: uplink0

# durable
uplink0:
  match:
    macaddress: "02:00:5e:10:00:00"
  set-name: uplink0
  dhcp4: true
```

Two details from the reference worth knowing. On ambiguous matches:

> Any additional device that satisfies the match rules will then fail to get
> renamed and keep the original kernel name (and `dmesg` will show an error).

So a glob like `enp*s0f0` on a host with three identical quad-port cards
renames one of them and leaves the others under their kernel names. The
documentation does not specify which one wins. And netplan itself recommends MAC
matching for certain options:

> Some options will not work reliably for devices matched by name only and
> rendered by networkd, due to interactions with device renaming in udev.
> Match devices by MAC when setting options like: `wakeonlan` or `*-offload`.

The same warning appears on `macaddress` and `mtu`.

### Outside netplan

Netplan is a front end. The mechanism underneath is the systemd `.link` file
([systemd.link(5)](https://man7.org/linux/man-pages/man5/systemd.link.5.html)),
which udev applies during device setup, before netplan or networkd sees the
interface:

```ini
# /etc/systemd/network/10-uplink0.link
[Match]
MACAddress=02:00:5e:10:00:00

[Link]
Name=uplink0
```

Its `[Match]` section is richer than netplan's, supporting `MACAddress=`,
`PermanentMACAddress=`, `OriginalName=`, `Path=`, `Driver=`, `Type=`, `Kind=`
and `Property=`, and `[Link]` can set MTU, speed, duplex, wake-on-LAN and
offloads alongside the name.

Three things to know before writing one:

- **The first matching file wins.** Files are considered in lexical order and
  later matches are ignored, so a custom file needs a prefix below `99-` to
  have any effect. Hence the `10-` convention.
- **`Path=` is not a durable alternative.** It globs the udev `ID_PATH`
  property, which for a PCI device contains the bus number, so it fails under
  exactly the conditions described here.
- **Name constraints apply.** 1 to 15 characters, 7-bit ASCII excluding
  control characters, `:`, `/` and `%`. Avoid `ethN` targets: udev and the
  kernel both allocate from that namespace and either can win. Run
  `update-initramfs -u` if the interface is needed early in boot.

Two other mechanisms are worth knowing exist. Custom udev rules setting
`NAME=` take precedence over the systemd default policy, which matters mainly
because an inherited one can silently override everything else. And
predictable naming can be disabled outright with `net.ifnames=0` on the kernel
command line, or by masking the default policy with
`ln -s /dev/null /etc/systemd/network/99-default.link`. Both trade a name that
changes when hardware changes for one that can change between boots on
identical hardware, which is defensible for a single-NIC appliance image and
not much else.

## Part 6: The uncomfortable part

Matching by MAC solves the mechanical problem. It does not solve the whole
problem, and it is worth being honest about why.

"This port is the primary uplink" is a fact about which cable a technician
plugged into which connector. Nothing inside the machine can derive it. The
kernel can identify a port: its silicon, its driver, its MAC address, its
position on the bus. It cannot identify the port's purpose.

Some human-supplied mapping is therefore irreducible, under every naming
scheme and every configuration system. If you match by name today, that
mapping already exists: someone decided `enp65s0f0np0` was the uplink. It is
simply written in the least stable coordinate system available, and nobody
labeled it as a mapping.

The question is not whether to have one, but three others:

- **How many.** One per platform model is the floor, not one per host.
- **How stable each one remains.** Key them to connectors rather than to
  numbers firmware recomputes on every boot.
- **How loudly a wrong one fails.** This is the important one.

That last point deserves emphasis, because it is independent of everything
else in this post. Netplan does not error on an unmatched stanza, so
something else must. **Build the check yourself:** compare the interfaces the
configuration expects against the interfaces that actually exist, and fail
loudly on a mismatch.

Where it lives depends on how you manage configuration. If a config management
role renders the netplan, that role is the natural place, since it already
knows both halves and can fail the run instead of leaving a host half
configured. A boot-time unit covers the other case: a reboot
following a hardware change, with no converge run between the two. Either
approach is worth more than the matching strategy it protects.

## Takeaways

- **Predictable means derived, not permanent.** `enp` names are computed from
  PCI bus position, and bus position is recomputed every boot from whatever
  hardware is present.
- **Any device can move them.** It does not have to be a network card. A
  storage controller on an earlier root port will do it.
- **The naming rules are versioned too.** A distribution upgrade can rename
  interfaces on hardware that did not change. `net.naming-scheme=` pins them.
- **The prefix tells you the risk.** `eno` and `ens` come from firmware
  indices and survive bus renumbering. `enp` does not.
- **Match on the card, not its position.** The MAC address is the practical
  choice, in netplan or in a `.link` file. Name and `Path=` both encode the
  enumeration.
- **Budget for the inventory, not the YAML.** MAC matching is per host, so the
  work is deciding where those values come from: a BMC query at provisioning
  time, a first-boot fact gather, or a config management inventory. The
  configuration change itself is trivial.
- **Make the failure loud.** Netplan will not error on a stanza that matches
  nothing, so validate it where you converge configuration: compare the
  interfaces the config expects against the ones that exist, and fail the run.
  That check is worth more than the matching strategy it protects.
