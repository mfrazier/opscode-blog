---
title: "Root Was Full. The Disk Wasn't."
date: 2026-11-01
description: "Auditing and safely growing root on about 200 Ubuntu hosts whose installer left part of the disk unallocated in the volume group. 82 hosts expanded, 28.3 TiB reclaimed, no reboots."
tags: ["linux", "ubuntu", "lvm", "ansible", "automation", "storage"]
author: Malcolm Frazier
---

A Kubernetes node started evicting pods for DiskPressure. kubelet raises
DiskPressure when the filesystem holding `/var/lib/kubelet` or the container image
store runs low, and that filesystem was nearly full. The disk underneath had
hundreds of GiB that had never been allocated.

Kubernetes was where it surfaced, but a full `/` or `/var` breaks plenty of other
things first: `apt` fails mid-upgrade, journald and application logs stop writing,
and services that need to write state fail in ways that rarely say "disk full".

The environment is about 200 Ubuntu 22.04 hosts across four sites. The goal: audit
every host, grow the right filesystem to use the whole disk, and fix the install
images.
The one hard requirement: **don't break any disk or brick any device.**

Results up front:

- The installer's default LVM sizing leaves part of the volume group unallocated.
  `df` only shows the filesystem. The free space sits one or more layers down, and
  each layer needs its own tool to see it.
- **82 hosts expanded, 28.3 TiB reclaimed, no reboots, zero failures caused by the
  expand.**
- Median gain was 35.8 GiB per host. The big wins were servers stuck at a 100 GiB
  root on 1.8 TiB disks.

---

## Where did the space go?

When Subiquity, the default Ubuntu server installer, sets up LVM, it sizes the root
LV based on how much space the volume group has:

| VG size | Root LV gets |
|---|---|
| Under 10 GiB | All of it |
| 10 to 20 GiB | 10 GiB |
| 20 to 200 GiB | Half |
| 200 GiB or more | 100 GiB |

It sizes from the space left in the VG after the EFI and `/boot` partitions, so a
200 GB disk counts as a little under 200. The rest is left unused on purpose. From
`subiquity/common/storage/sizes.py`:

```python
# Scale the usage of the vg to leave room for snapshots and such. We should
# use more of a smaller disk to avoid the user running into out of space errors
# earlier than they probably expect to.
def scaled_rootfs_size(available: int):
    if available < 10 * (1 << 30):
        # Use all of a small (<10G) disk.
        return available
    elif available < 20 * (1 << 30):
        # Use 10G of a smallish (<20G) disk.
        return 10 * (1 << 30)
    elif available < 200 * (1 << 30):
        # Use half of a larger (<200G) disk.
        return available // 2
    else:
        # Use at most 100G of a large disk.
        return 100 * (1 << 30)
```

### Finding it

Unused space can hide at any layer between the disk and the filesystem, and `df`
only sees the last one. Check each layer:

```bash
sudo fdisk -l /dev/sda        # disk size vs partition sizes: unpartitioned space
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS   # partition size vs the LV mounted on it
sudo pvs                      # PSize vs PFree, and whether the PV fills its partition
sudo vgs                      # VFree: unallocated space in the volume group
sudo lvs                      # LV sizes
df -h / /var                  # filesystem size and usage
```

The largest servers showed the giveaway in `lsblk`: a partition of about 1.8T with
a 100G `ubuntu--vg-ubuntu--lv` on top of it, and `vgs` reported the difference as
`VFree`.

---

## The tooling

A Python collector runs on each host and a reporter builds the combined report,
packaged as two Ansible playbooks: `root-disk-audit.yml` (read-only) and
`root-disk-expand.yml`.

**Audit.** The collector walks disk → partition → (LUKS) → PV → VG → LV →
filesystem, measures unused space at each layer, and assigns one verdict:

| Verdict | Meaning |
|---|---|
| EXPAND | Unused space can be given to `/` |
| OK | `/` already uses the whole disk |
| BLOCKED | Space only reachable by repartitioning |
| REVIEW | Layout the tool won't touch: btrfs, zfs, RAID, multipath, thin or striped LV, LUKS on an LV |
| ERROR | Collector failed |

**Expand.** Bottom-up, re-reading the layout after each step: `growpart`,
`cryptsetup resize`, `pvresize`, then `lvextend -r -l +100%FREE` naming only the PVs
already under `/`, so root never spreads onto a second disk.

**Safety guards:**

- Dry run by default. Nothing changes without `-e rd_dry_run=false`.
- `growpart` (the only partition table change) is blocked unless explicitly allowed.
- `serial: 1` and `max_fail_percentage: 0`: one host at a time, stop on first failure.
- Preflight refuses a read-only `/`, an unclean filesystem, or any device `/`
  doesn't sit on.
- `sfdisk -d` and `vgcfgbackup` run first. If a backup fails, nothing changes.
- No task timeout on the expand, so a resize can never be killed halfway.

The backups repair a damaged partition table or LVM layout. They don't undo a grow,
and a grown host doesn't need undoing.

---

## Rollout

The audit reached 162 of 209 hosts and flagged 87 as EXPAND. Which filesystem to
grow depended on the partition layout:

- **Bare metal (78 hosts, automated).** The installer's default layout: one
  `ubuntu-vg/ubuntu-lv` holding `/`, with `/var` inside it. Growing `/` grows
  everything, including kubelet and container data.
- **VMs (8 hosts, by hand).** A custom `sysvg` with separate `root`, `home`, `opt`
  and `var` LVs. Jump hosts got `/` grown. The Kubernetes VMs got `/var` grown, since
  that is the filesystem kubelet and the container runtime write to; growing `/`
  there would not have cleared DiskPressure. One VM with an already-enlarged virtual
  disk needed `growpart` and `pvresize` first.

Rollout order: dry run, one canary, then site by site, smallest first. Each
automated host ran:

```bash
sfdisk -d /dev/<disk> > /var/backups/rootdisk/<UTC>/<disk>.sfdisk
vgcfgbackup -f /var/backups/rootdisk/<UTC>/ubuntu-vg.vg ubuntu-vg
lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv /dev/<pv>
```

The VMs ran the same backups, then `lvextend -r -l +100%FREE` against
`/dev/sysvg/root` or `/dev/sysvg/var`. A re-audit showed every expanded host as OK.

---

## Results

**28.3 TiB reclaimed across 82 hosts.** Median gain was **35.8 GiB** per host; most
hosts simply doubled a half-sized root.

The outliers are where the space was:

- **7 servers went from 100 GiB to 1,784 GiB**, gaining 1.6 TiB each. Root usage
  dropped from 27-43% to 2%.
- **16 servers went from 100 GiB to 891 GiB**, gaining 790 GiB each.

Those 23 hosts account for 24.4 TiB, about 86% of the total. The fullest hosts went
from 74-81% used to 35-40%.

---

## Fixing the install images

Set `sizing-policy: all` so new hosts get the whole disk:

```yaml
autoinstall:
  storage:
    layout:
      name: lvm
      sizing-policy: all
```

---

## Takeaways

- **Check every layer, not just `df`.** `fdisk -l` for unpartitioned space, `lsblk`
  for partition vs LV size, `pvs`/`vgs`/`lvs` for PV slack and `VFree`.
- **Know the partition layout before you grow anything.** Whether `/var` is its own
  LV decides which volume actually fixes the problem.
- **Audit read-only first and show the exact commands.** One identical `lvextend -r`
  per host made approval easy.
- **Make the dangerous path opt-in.** Dry run by default, one host at a time, stop on
  first failure.

---

## References

- [Ubuntu autoinstall reference: sizing-policy](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
- [subiquity/common/storage/sizes.py](https://github.com/canonical/subiquity/blob/main/subiquity/common/storage/sizes.py) (canonical/subiquity, main)
- [Kubernetes: Node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
- [lvextend(8)](https://man7.org/linux/man-pages/man8/lvextend.8.html)
- [vgcfgbackup(8)](https://man7.org/linux/man-pages/man8/vgcfgbackup.8.html)
