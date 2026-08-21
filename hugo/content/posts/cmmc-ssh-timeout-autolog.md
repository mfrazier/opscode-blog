---
title: "CMMC: Compliant on Paper, Broken in Practice"
date: 2026-03-11
lastmod: 2026-08-20
draft: false
ShowToc: true
TocOpen: true
tags:
  - cmmc
  - openssh
  - linux
  - ubuntu
  - almalinux
  - rocky-linux
  - security
  - compliance
description: >
  How a CMMC Level 2 requirement for automatic session termination
  exposed a subtle OpenSSH behavior change, and why I ended up using
  autolog instead of native sshd_config directives.
---

SSH session timeouts looked like a straightforward CMMC Level 2 control. After
digging through man pages, source code, bug trackers, and a fair amount of
testing, I had a completely different solution than I started with. This is what
happened.

## The Controls

Two CMMC Level 2 controls are directly relevant here:

**[AC.L2-3.1.11](https://ndisac.org/dibscc/cyberassist/cybersecurity-maturity-model-certification/level-2/ac-l2-3-1-11/)** (NIST SP 800-171 3.1.11): *Automatically terminate user sessions after a defined condition.*

This means a full termination, not a screen lock, not a network disconnect. The
user's processes must be cleaned up and re-authentication required. For SSH on
Linux, the shell must actually exit.

**[SC.L2-3.13.9](https://www.lakeridge.io/nist-sp-800-171-and-cmmc/controls/3-13-9)** (NIST SP 800-171 3.13.9): *Terminate network connections associated with communications sessions at the end of the sessions or after a defined period of inactivity.*

This is the network-layer companion: drop the TCP connection after idle time.
The session timing out and requiring re-authentication was the acceptable
evidence of control.

## The `ClientAlive*` Trap

The OpenSSH directives `ClientAliveInterval` and `ClientAliveCountMax` control
server-side keepalive behavior. Standard compliance guidance points here first,
and this is where every CIS benchmark and compliance scanner will look.

```
ClientAliveInterval 900
ClientAliveCountMax 0
```

The problem is that this configuration means something very different depending
on which version of OpenSSH is running on your server.

### Before OpenSSH 8.2

Prior to OpenSSH 8.2, setting `ClientAliveCountMax` to `0` had an unintended
side effect: when the first liveness probe came due — `ClientAliveInterval`
seconds after the last data from the client — sshd sent the probe and then
killed the connection immediately, without waiting to see whether the client
answered it. The upstream fix commit describes the old behavior in exactly
those terms. The practical result was a connection cutoff after roughly one
interval of client silence, no matter how alive the client was.

This was never designed behavior. It was a bug. OpenSSH's upstream maintainers
have described it as such: SSH never had, intentionally, the capability to drop
idle users based on these settings. The combination of `ClientAliveCountMax=0`
and a nonzero `Interval` just happened to cause an accidental cutoff as a side
effect of how the probe logic was implemented.

This unintentional behavior became the de facto basis for SSH idle timeout guidance
across the industry, embedded in security hardening automation, compliance auditing
tools, and countless hardening blog posts. It was a side effect that got copied
uncritically into compliance tooling and frozen there. The OpenSSH project
[fixed the bug in 8.2](https://www.openssh.com/txt/release-8.2)
and the ecosystem largely hasn't caught up. Security researchers recommend this
method. Auditing tools pass. The timeout does not work.

References:
- Upstream fix: [openssh-portable commit 6933499](https://github.com/openssh/openssh-portable/commit/69334996ae203c51c70bf01d414c918a44618f8e), referencing [upstream bz#2627](https://bugzilla.mindrot.org/show_bug.cgi?id=2627)
- OpenSSH source: [`serverloop.c`](https://github.com/openssh/openssh-portable/blob/master/serverloop.c)
- Launchpad bug documenting the breakage on upgrade: [LP #1978816](https://bugs.launchpad.net/ubuntu/+source/openssh/+bug/1978816) — filed, as it happens, by the maintainer of the autolog fork this post ends up recommending
- Red Hat Bugzilla tracking the backport of the same patch: [BZ #2015828](https://bugzilla.redhat.com/show_bug.cgi?id=2015828)

### After OpenSSH 8.2

OpenSSH 8.2 fixed the bug. `ClientAliveCountMax 0` now explicitly disables
connection termination. The server will no longer drop connections based on
these settings with that value. See the [OpenSSH 8.2 release notes](https://www.openssh.com/txt/release-8.2)
for the documented change.

The correct pattern to approximate a 15-minute *unresponsive-client* timeout
using `ClientAlive*` on patched OpenSSH is:

```
# 3 probes × 300s = drop after ~15 min if client stops responding
ClientAliveInterval 300
ClientAliveCountMax 3
```

But this only handles the case where the **client stops responding to probes**,
a dead or crashed endpoint. A live SSH client responds to keepalives
automatically, regardless of whether a human is at the keyboard. There is no
way using `ClientAlive*` alone to terminate a session because the user has been
idle. SC.L2-3.13.9 is eventually satisfied; AC.L2-3.1.11 is not.

## New Directives: `ChannelTimeout` and `UnusedConnectionTimeout`

[OpenSSH 9.2](https://www.openssh.com/txt/release-9.2) introduced two directives
that get much closer to what compliance actually requires:

**`ChannelTimeout`**: Tells `sshd` to close any channel that has seen no
traffic for the configured interval. Unlike the `ClientAlive*` mechanism,
there is no probe and no client acknowledgment involved. Nothing is sent; the
timer resets only on actual channel traffic, so a quiet session gets its
channel closed no matter how alive the client process is. The man page's own
example states that a five-minute session timeout "would cause all sessions
to terminate after five minutes of inactivity." Two caveats from the same man
page: terminating an inactive session does not guarantee removal of all
resources associated with it (shell processes relating to the session may
continue to execute), and closing a channel does not by itself prevent the
client from opening another one of the same type. Pair it with
`UnusedConnectionTimeout`, and test termination behavior on your own builds
before presenting this as your AC.L2-3.1.11 mechanism.

One nuance worth knowing: because output counts as traffic, a session that is
still producing output — a running build, `tail -f` on a log — is not
considered inactive and stays up. As you'll see below, that is the opposite
failure profile from `StopIdleSessionSec`, and on a fleet full of long-running
jobs it's the profile you want.

**`UnusedConnectionTimeout`**: Also introduced in OpenSSH 9.2, this directive
allows the server to terminate client connections that have no open channels
for a specified duration. It complements `ChannelTimeout`: channels time out
individually, then the empty connection is reaped.

For distros running OpenSSH ≥ 9.2, this is the native way to meet both controls:

```
# /etc/ssh/sshd_config.d/99-session-timeout.conf

# Close idle interactive sessions after 15 minutes without channel traffic.
# "session*" (wildcard, no colon) is deliberate — see the syntax note below.
ChannelTimeout session*=900

# Terminate the connection once no channels remain open for 60 seconds
UnusedConnectionTimeout 60
```

**A syntax trap inside the fix for a syntax trap.** The channel type names
changed between OpenSSH releases. The sshd_config man page shipped with
OpenSSH 9.6 (Ubuntu 24.04) documents session *subtypes* —
`session:command`, `session:shell`, `session:subsystem:...` — and its own
example is `session:*=5m`. Current upstream man pages instead document a
single `session` type, plus a `global` keyword (added in OpenSSH 9.7) that
times out all channels collectively and is deliberately *not* matched by
wildcards. A config that says `session:*` can silently match nothing on newer
builds, and one that says plain `session` can silently match nothing on 9.6.
The wildcard `session*` matches both generations. Given that this entire post
is about configuration that scans clean while doing nothing, verify: check
`sudo sshd -T | grep -i channeltimeout`, then leave a test session idle past
the threshold and confirm it actually dies.

You can also scope timeouts independently to `direct-tcpip`,
`forwarded-tcpip`, `x11-connection`, or `agent-connection` channels.
`UnusedConnectionTimeout` handles the cleanup after all channels close (note
its timer also runs between authentication and the first channel open, so
don't set it aggressively short).

However, these directives are only available in OpenSSH 9.2 and later.

## Impact on Popular Linux Distributions

**Ubuntu 22.04 LTS** ships OpenSSH 8.9p1. `ClientAliveCountMax 0` disables
connection termination. `ChannelTimeout` and `UnusedConnectionTimeout` are not
available. **Ubuntu 24.04 LTS** ships 9.6p1 and has both.

**RHEL 8, AlmaLinux 8, Rocky Linux 8**: RHEL 8 ships OpenSSH 8.0p1, but Red Hat
backported the 8.2 behavior change into that package in RHEL 8.6, via
openssh-8.0p1-13.el8 ([RHSA-2022:2013](https://access.redhat.com/errata/RHSA-2022:2013)).
The changelog entry is dated October 2021, which makes it easy to misattribute
to RHEL 8.5 — but 8.5 shipped 8.0p1-10, and the build carrying the change
landed with the 8.6 errata batch. The RPM changelog is explicit: "Upstream:
ClientAliveCountMax=0 disable the connection killing behaviour." AlmaLinux 8
and Rocky Linux 8 carry the same package. All current RHEL 8 family systems
have the new `ClientAliveCountMax=0` semantics regardless of what `ssh -V`
reports.

**RHEL 9, AlmaLinux 9, Rocky Linux 9**: RHEL 9.0 through 9.7 ship OpenSSH
8.7p1 — same `ClientAliveCountMax=0` behavior, no `ChannelTimeout` or
`UnusedConnectionTimeout`. RHEL 9.8 rebased to OpenSSH 9.9, which brings both
directives. AlmaLinux and Rocky Linux rebuild RHEL sources; confirm what your
rebuild's 9.8 actually ships with `ssh -V` rather than assuming.

**RHEL 10, AlmaLinux 10, Rocky Linux 10**: Ships OpenSSH 9.9p1. Both new
directives are available.

### Distribution Compatibility Matrix

| Distribution | OpenSSH Version | Old `CountMax=0` workaround ² | `ChannelTimeout` (9.2+) | `UnusedConnectionTimeout` (9.2+) |
|---|---|:---:|:---:|:---:|
| RHEL 8 / Rocky 8 / Alma 8 | 8.0p1 (backported fix¹) | ⚠️ does nothing | ❌ | ❌ |
| RHEL 9 / Rocky 9 / Alma 9 (9.0–9.7) | 8.7p1 | ⚠️ does nothing | ❌ | ❌ |
| RHEL 9 (9.8+) ³ | 9.9p1 | ⚠️ does nothing | ✅ | ✅ |
| RHEL 10 / Rocky 10 / Alma 10 | 9.9p1 | ⚠️ does nothing | ✅ | ✅ |
| Ubuntu 22.04 LTS | 8.9p1 | ⚠️ does nothing | ❌ | ❌ |
| Ubuntu 24.04 LTS | 9.6p1 | ⚠️ does nothing | ✅ | ✅ |

¹ Red Hat backported the 8.2 behavior change into openssh-8.0p1 in RHEL 8.6
(openssh-8.0p1-13.el8, [BZ #2015828](https://bugzilla.redhat.com/show_bug.cgi?id=2015828),
shipped in [RHSA-2022:2013](https://access.redhat.com/errata/RHSA-2022:2013)).
AlmaLinux 8 and Rocky Linux 8 carry the same package. All current RHEL 8 family
systems are affected regardless of what `ssh -V` reports.

² Every distro in this table ships OpenSSH 8.2 or later (or has the fix
backported). On all of them, `ClientAliveCountMax 0` now works exactly as
intended by the OpenSSH developers: it disables connection termination. The
old compliance workaround that relied on the pre-8.2 bug no longer functions.
Any configuration carrying `ClientAliveCountMax 0` is not in compliance.

³ RHEL 9.8 rebased openssh from 8.7p1 to 9.9p1, per the
[RHEL 9.8 release notes](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/9.8_release_notes/new-features).
Mind the minor version: a "RHEL 9" box may sit on either side of this line.

## So What Did I Do?

The fleet being certified ran AlmaLinux 8, Rocky Linux 8, and Ubuntu 22.04 LTS.
None ship OpenSSH 9.2 or later, so `ChannelTimeout` and `UnusedConnectionTimeout`
were off the table. The `ClientAlive*` directives cannot enforce what AC.L2-3.1.11
requires: a terminated user session, not just a dropped connection.

The first candidate was `TMOUT`, a bash shell variable that kills an idle shell
after a configured number of seconds. The problem is that `TMOUT` is evaluated
by each bash instance individually. Every shell inside a tmux or screen pane
inherits it and gets killed when it fires. On a fleet where engineers, researchers,
and scientists keep tmux and screen sessions running for long jobs, that's a
non-starter. `TMOUT` has no awareness of the session hierarchy; it kills the shell
whether or not it's attached to an active multiplexer.

The second candidate was `StopIdleSessionSec` in systemd-logind, added upstream
in [systemd 252](https://lwn.net/Articles/913287/) (November 2022). It's built
into the init system, which makes it attractive — but availability is uneven.
Red Hat backported it into RHEL 8.7+ and RHEL 9. Ubuntu 22.04 never got it:
jammy ships systemd 249, three releases too old, and Canonical did not backport
the option. (Ubuntu 24.04, on systemd 255, has it.) So on the Ubuntu 22.04
portion of this fleet, the option simply does not exist.

Where it does exist, the problem is how it determines idleness for SSH and
terminal sessions. Rather than relying on a signal from the session itself, it
checks the access time (atime) of the pseudo-TTY device associated with the
login. Only reads of the device — user input — refresh that atime. Program
output does not.

The consequence: any session running a long job that produces output but waits
for no keyboard input looks idle by atime and gets terminated. Watching
`tail -f` stream log output or `journalctl -f` tailing the system journal will
not keep your session alive. And the false kills aren't limited to output-only
sessions. Red Hat's tracker for the fallout
([RHEL-24340](https://issues.redhat.com/browse/RHEL-24340)), filed after
`StopIdleSessionSec` was backported into RHEL and deployed via the STIG role,
documents sessions disconnected while the user was actively arrow-keying
through a `man` page, background processes killed despite
`KillUserProcesses=no`, and unexpected termination of GDM graphical sessions.
There is also a reported failure mode in the opposite direction: on RHEL 8-era
systemd, ControlMaster-multiplexed SSH sessions were never terminated even when
genuinely idle
([systemd #29967](https://github.com/systemd/systemd/issues/29967) — in that
report, regular sessions were stopped on schedule while the multiplexed ones
outlived the timeout indefinitely).

On RHEL 8 before 8.7, `StopIdleSessionSec` was not yet backported, so it was not
available across that part of the fleet either. Between the missing support on
Ubuntu 22.04, the false-kill behavior on long-running jobs, and the
ControlMaster gap, it was not a viable option.

I landed on **[autolog](https://github.com/JKDingwall/autolog)**, a standalone C
daemon that enforces idle session termination by polling the utmp file and killing
sessions based on TTY idle time.

The key difference from `TMOUT` is where autolog operates. It terminates the SSH
login session, specifically the process registered in utmp against a pseudo-TTY.
A detached tmux server does not write utmp entries; it's a background process
outside the tracked session. (GNU screen *can* write utmp entries for its
windows when built with utmp support and login mode is enabled — check your
distro's defaults and run `who -a` against a detached session before relying on
this.) When autolog fires, the SSH connection closes and re-authentication is
required, but a detached multiplexer session survives and can be reattached.
(This depends on `KillUserProcesses=no` in systemd-logind. Verify the
effective setting on your systems and confirm that a detached session actually
survives an autolog termination before relying on it.)

The autolog config sets `idle=14 grace=60`: 14 minutes of idle time with a
60-second warning before termination, meeting the 15-minute policy threshold.

On a fleet running OpenSSH 9.2+, `ChannelTimeout` and `UnusedConnectionTimeout`
are the right native answer. On these distros, they weren't available, and
autolog filled that gap.

## Postscript: DISA Corrected This Too

The pre-8.2 workaround wasn't just in hardening guides; it was a DISA
requirement. The RHEL 8 STIG rule for SSH connection termination
(RHEL-08-010201 / [V-244525](https://www.stigviewer.com/stigs/red_hat_enterprise_linux_8/2026-02-05/finding/V-244525))
shows the correction across its archived revisions on
[STIG-A-View](https://stigaview.com/products/rhel8/):

- **Through V1R7:** required `ClientAliveCountMax 0`, described as termination
  "at the end of the session or after 10 minutes of inactivity." On patched
  OpenSSH, that configuration disables termination entirely.
- **V1R8:** values changed to `ClientAliveInterval 600` and
  `ClientAliveCountMax 1`. The text still said "inactivity."
- **[V1R11](https://stigaview.com/products/rhel8/v1r11/RHEL-08-010201/):**
  language corrected to "terminated after 10 minutes of becoming
  unresponsive." Note that the rule's "Satisfies" list still includes
  SRG-OS-000279 (user-session termination), which this mechanism cannot
  enforce. DISA added a separate rule for that:
  [V-257258](https://www.stigviewer.com/stigs/red_hat_enterprise_linux_8/2025-05-14/finding/V-257258),
  `StopIdleSessionSec=600`, RHEL 8.7+ only.

The Ubuntu 22.04 STIG has said "unresponsive" since its first release
([V1R1, April 2024](https://stigaview.com/products/ubuntu2204/v1r1/UBTU-22-255035/)),
tagged to SRG-OS-000163 (network connection termination), with the idle-user
intent in the separate TMOUT rule (UBTU-22-412030, SRG-OS-000279). The Ubuntu
20.04 STIG still said "inactivity" in its 2024 release
([V-238213](https://stigviewer.com/stigs/canonical_ubuntu_20.04_lts/2024-02-18/finding/V-238213)).

If your sshd_config carries `ClientAliveCountMax 0` from a hardening guide,
you are not compliant at all. That value fails the current checks outright
(the RHEL 8 and Ubuntu 22.04 STIGs both require `ClientAliveCountMax 1`), and
it never met the intent of the control in the first place: on patched OpenSSH
it disables termination entirely. A STIG rule is satisfied by meeting the
control's objective, not by matching a configuration string from an old
revision of the fix text.

---

If you're doing CMMC on a Linux fleet and you copied `ClientAliveInterval 900` and
`ClientAliveCountMax 0` into your `sshd_config` from a hardening guide and called
it done, it's worth
verifying what you actually have. The control you're trying to meet and the
mechanism you're using to meet it may not be the same thing, especially
depending on which OpenSSH version your distro ships.

Trust, but verify.
