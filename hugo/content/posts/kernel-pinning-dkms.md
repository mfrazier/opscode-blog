---
title: "The Kernel Updated. The Drivers Didn't."
date: 2026-06-06
tags: ["linux", "ansible", "kernel", "automation", "ethercat", "canbus", "real-time"]
author: Malcolm Frazier
---

I work with industrial Linux systems that have strict real-time requirements. The hosts
run low-latency kernels and depend on out-of-tree kernel drivers compiled against the
running kernel. When any part of that chain breaks, critical functionality is lost.

Kernel pinning and out-of-tree driver management are two related problems that need to be
solved together. This post covers why, and how.

---

## Why the low-latency kernel

The generic kernel runs fine on most Ubuntu hosts. The issue is not that it is broken; it
is that it does not meet the timing requirements of the software and hardware devices
connected to these systems.

Ubuntu ships both a General Availability (GA) generic kernel and a GA low-latency kernel
variant. Both are built from the same upstream kernel source but with different
configurations; the low-latency variant targets latency-sensitive workloads.

The two meaningful differences are build-time configuration choices. The low-latency
kernel enables `CONFIG_PREEMPT`, the maximum preemption model available in the mainline
kernel, allowing the kernel to be interrupted at almost any point to schedule
higher-priority work. It also sets `CONFIG_HZ_1000`, running the timer interrupt at
1000 Hz compared to 250 Hz in the generic kernel. That higher tick rate yields a best-case
timer resolution of 1ms versus 4ms, which reduces scheduling jitter for time-sensitive
workloads. The tradeoff is throughput: more frequent preemption means more context
switching overhead, which is an acceptable cost when the workload demands deterministic,
predictable timing such as EtherCAT communication cycles and CANbus scheduling.

The problem is that Ubuntu does not pin the kernel by default. `apt upgrade` will happily
install a newer low-latency kernel onto a host already running a validated one and update
the GRUB default. Left uncontrolled, there is an implicit assumption that every new kernel
performs deterministically on the hardware and that any out-of-tree drivers survive the
transition without intervention. Both assumptions will eventually be wrong.

---

## Kernel pinning

Pinning a kernel to a specific version requires three things working together.

**Package holds.** After installing the target kernel packages, the role marks them held
via `dpkg_selections`. A held package is not touched by `apt upgrade`, and any attempt to
do so produces a visible warning rather than silently proceeding.

```yaml
- name: "Mark kernel packages as held"
  dpkg_selections:
    name: "{{ pkg }}"
    selection: hold
  loop: "{{ kernel_install_packages }}"
```

**GRUB persistence.** Setting `GRUB_DEFAULT=saved` and calling `grub-set-default` with
the exact versioned entry string ensures the host always boots the intended kernel.
Without this, `update-grub` can silently change the default when new kernels are installed
or removed.

```yaml
- name: Set saved_entry in grubenv
  command: grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux {{ kernel_version }}"
  when: "kernel_version not in grub_saved_entry.stdout"
```

**Old kernel cleanup.** Hosts with multiple kernels installed create conditions that cause
other problems, which comes up again in the bugs section below. The role enumerates all
installed kernel images, excludes the running kernel and the target version, and removes
everything beyond a configurable count. It also cleans orphaned headers and module
packages that `apt autoremove` misses.

These three pieces work together. Package holds prevent unintended upgrades. GRUB
persistence ensures the pinned kernel is what actually boots even if something slips
through. Old kernel cleanup keeps the system clean and avoids state drift from leftover
packages.

Pinning alone is not sufficient, though. It keeps the kernel stable, but it does not
protect against the case where an intentional kernel update leaves out-of-tree drivers
behind. That is where DKMS comes in, and why the two belong together as a single strategy
rather than independent choices.

---

## The out-of-tree driver problem

The systems involved require two out-of-tree drivers:

- **pcan**: PEAK's CANbus driver
- **atemsys**: acontis' EtherCAT userspace access driver, which gives the EtherCAT master
  stack direct access to the network adapter

Neither ships with the kernel. Both must be compiled against the running kernel's headers
using the same GCC version that built the kernel. When the kernel changes, the compiled
modules are no longer valid and must be rebuilt from source.

The original implementation of the driver provisioning role handled this manually:
download the source tarball, detect the compiler version from `/proc/version`, build
against the running kernel headers, copy the `.ko` into the module tree, run `depmod`,
rebuild the initramfs. The role was idempotent in that re-running it was a no-op if the
driver was already installed for the running kernel.

The catch is in those last three words. Every kernel update requires a role re-run. Miss
one and the host boots a new kernel with no driver. Critical functionality is lost, with
no clear indication at the package manager level that anything went wrong.

---

## What DKMS fixes

DKMS (Dynamic Kernel Module Support) is the standard Linux answer to this problem. The
idea is straightforward: register a module's source with DKMS once, and from that point
on, every time a new kernel is installed via `apt`, DKMS hooks into the post-install
process and automatically rebuilds and installs the module. No manual step required.

The DKMS lifecycle for a module looks like this:

```
# Register source, stored at /usr/src/<module>-<version>/
dkms add <module>/<version>

# Compile against specified kernel headers
dkms build <module>/<version> -k <kernel>

# Place .ko in /lib/modules/<kernel>/updates/dkms/
dkms install <module>/<version> -k <kernel>

# On future kernel installs via apt, the DKMS hook fires automatically
# and rebuilds the module without any manual step
apt install linux-headers-<new-kernel>
```

One operational requirement: the source directory under `/usr/src/` must remain on disk
permanently, as DKMS needs it every time a new kernel triggers a rebuild.

This is also where kernel pinning and DKMS complete each other as a strategy. Pinning
prevents unintended kernel changes. DKMS handles intended ones automatically. Running only
one leaves a gap: uncontrolled kernel updates defeat a validated deterministic
configuration, and manual driver rebuilds after every kernel change are a reliability risk
that compounds over time. Together, they close the loop.

---

## Migrating pcan to DKMS

The pcan driver from PEAK has native DKMS support built into its Makefile via the
`install_with_dkms` target and the `DKMS=DKMS_SUPPORT` build flag. These handle source
symlinking, `dkms.conf` generation, and DKMS registration in one step.

Replacing the manual `make install` in the role comes down to two tasks:

```yaml
- name: Build PCAN driver with DKMS support
  command: >
    make -j{{ ansible_processor_vcpus }}
    CC=gcc-{{ _kernel_gcc_major.stdout }}
    DKMS=DKMS_SUPPORT
  args:
    chdir: "{{ _pcan_src_dir }}/driver"

- name: Install PCAN driver with DKMS
  command: >
    make CC=gcc-{{ _kernel_gcc_major.stdout }}
    DKMS=DKMS_SUPPORT
    install_with_dkms
  args:
    chdir: "{{ _pcan_src_dir }}/driver"
```

The idempotency check moves from `modinfo pcan` to `dkms status`, scoped to the running
kernel:

```yaml
- name: Check if pcan is installed via DKMS for running kernel
  command: dkms status peak-linux-driver/{{ pcan_version }} -k {{ ansible_kernel }}
  register: _pcan_dkms_status
  changed_when: false
  failed_when: false
```

If the output contains `installed`, the entire build block is skipped.

---

## Migrating atemsys to DKMS

The driver atemsys by acontis was harder to migrate. acontis does not ship a `dkms.conf`
with the driver source, and no community implementation exists anywhere. Writing one from
scratch was required, along with full end-to-end validation before being implemented in
the Ansible role.

The resulting `dkms.conf`:

```
PACKAGE_NAME="atemsys"
PACKAGE_VERSION="{{ atemsys_version }}"
CLEAN="make -C /lib/modules/$kernelver/build M=$dkms_tree/$module/$module_version/build clean"
MAKE[0]="make -C /lib/modules/$kernelver/build M=$dkms_tree/$module/$module_version/build modules"
BUILT_MODULE_NAME[0]="atemsys"
BUILT_MODULE_LOCATION[0]="."
DEST_MODULE_LOCATION[0]="/kernel/drivers/acontis"
AUTOINSTALL="yes"
```

The `AUTOINSTALL="yes"` directive is the key line. It tells DKMS to rebuild this module
automatically whenever new kernel headers are installed via `apt`.

Validation was done manually before being implemented in the Ansible role:

1. Extracted atemsys source to `/usr/src/atemsys-<version>/`
2. Ran `dkms add`, `dkms build`, and `dkms install` against the running kernel
3. Verified that `srcversion` in the DKMS-installed module matched the manually built
   module exactly, confirming identical source compilation
4. Installed a new kernel's headers via `apt install linux-headers-<new-version>`
5. Confirmed DKMS automatically triggered during that install and built atemsys without
   any manual step
6. Rebooted into the new kernel and confirmed atemsys loaded from the DKMS path at
   `/lib/modules/<new-kernel>/updates/dkms/atemsys.ko`

Once validated, the role was updated. Instead of building in a scratch directory and
copying the `.ko` manually, it now copies source files to
`/usr/src/atemsys-{{ version }}/`, renders the `dkms.conf` from a template, and runs the
DKMS lifecycle:

```yaml
- name: Add atemsys to DKMS
  command: dkms add atemsys/{{ atemsys_version }}

- name: Build atemsys with DKMS
  command: dkms build atemsys/{{ atemsys_version }} -k {{ ansible_kernel }}

- name: Install atemsys with DKMS
  command: dkms install atemsys/{{ atemsys_version }} -k {{ ansible_kernel }}
```

The build directory used for tarball extraction is removed after install. The source
directory at `/usr/src/atemsys-{{ version }}/` is kept permanently so DKMS can rebuild on
future kernel installs.

---

## Bugs found along the way

Moving to DKMS meant re-examining the full initramfs and module loading path, which
surfaced several bugs in the original role that had been failing silently.

**`update-initramfs` targeting the wrong kernel on multi-kernel hosts.** The handler ran
`update-initramfs -u` with no kernel specified. On hosts with multiple kernels installed,
`-u` targets the most recently installed kernel, not the running one. On one host, the
role installed a new lowlatency kernel and rebooted into it, but `update-initramfs`
silently updated the generic kernel instead. The module blacklists ended up in the wrong
initramfs. The fix is simple and should have been there from the start:
`update-initramfs -u -k {{ ansible_kernel }}`, everywhere, unconditionally.

**Ansible handler deduplication silently dropping the Beckhoff blacklist.** Ansible
deduplicates handlers within a play: if the same handler is notified more than once, it
only runs once. Both the pcan and atemsys tasks notified the same `Update initramfs`
handler. Whichever triggered first consumed it, and the second notification was silently
dropped.

The result: `/etc/modprobe.d/blacklist-beckhoff.conf` was written to disk but never made
it into the initramfs. At early boot, the kernel had no knowledge of the blacklist and
loaded `ec_bhf` freely. By the time the real filesystem was available, `ec_bhf` was
already bound to the Beckhoff device and `atemsys` could not claim it. Confirmed on one
host with:

```bash
lsinitramfs /boot/initrd.img-<kernel-version> | grep blacklist-beckhoff
# (no output)
```

The fix is to eliminate the handler entirely for this use case and replace every
`notify: Update initramfs` with an explicit unconditional task immediately after each
blacklist is written:

```yaml
- name: Update initramfs after Beckhoff blacklist change
  command: update-initramfs -u -k {{ ansible_kernel }}
  become: true
  changed_when: true
```

No handlers, no deduplication, no silent omission.

**Silent success when `ec_bhf` survived the unload.** The module unload tasks used
`failed_when: false`, which is correct since the module may not be loaded at all. The
problem was the absence of any check afterward to confirm the device was actually free. If
`ec_bhf` remained bound, `atemsys` could not claim the Beckhoff device, and the role
completed without error in a broken state.

The fix is to run `lspci -Dk` after the unload attempts and emit a visible warning if
`ec_bhf` or `ec_bhk` is still shown as `Kernel driver in use`. The same check applies at
the end of the role: verify that `atemsys_pci` is the active driver for the Beckhoff
device. If it is not, something went wrong and the operator needs to know immediately
rather than discovering it when the application fails to start.

```yaml
- name: Warn if atemsys_pci is not bound to Beckhoff device
  debug:
    msg: >
      WARNING: atemsys_pci is not bound to the Beckhoff device after role completion.
      Manual intervention may be required.
      lspci output: {{ _lspci_final.stdout }}
  when: "'Kernel driver in use: atemsys_pci' not in _lspci_final.stdout"
```

A successful Ansible run should mean the host is in the correct state. Without end-state
verification, it only means the role ran without throwing an exception, which is a much
weaker guarantee.

---

## The result

After these changes, the driver provisioning lifecycle is:

1. Run the role once on a host to install both drivers via DKMS.
2. When a kernel update is needed, update the pinned version and run the kernel role. DKMS
   rebuilds both drivers automatically during the headers install. No separate driver role
   run is required.
3. Reboot.

The driver role is still needed for initial provisioning and for driver version changes.
The case that was causing quiet breakage, a kernel update leaving drivers behind, is now
handled at the package manager level where it belongs.

Kernel pinning and DKMS solve different halves of the same problem. Pinning ensures kernel
changes happen intentionally, on your terms. DKMS ensures that when they do happen,
whether planned or not, the drivers follow automatically. Together, they close the loop.

---

## References

- [EtherCAT and Linux](https://www.acontis.com/en/ethercat-master-linux.html) - EtherCAT master stack and atemsys kernel driver by acontis
- [PEAK-System pcan Linux driver](https://www.peak-system.com/fileadmin/media/linux/index.php) - Official driver download and documentation
- [DKMS on GitHub](https://github.com/dkms-project/dkms) - Source and documentation for the Dynamic Kernel Module Support framework
