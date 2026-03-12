---
title: "CMMC: Compliant on Paper, Broken in Practice"
date: 2026-03-11
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

Prior to OpenSSH 8.2, setting `ClientAliveCountMax` to `0` had an unintended side
effect: it disabled probe sending entirely, so when no data arrived within
`ClientAliveInterval`, the server would drop the connection. This was never
designed behavior. It was a bug. OpenSSH's upstream maintainers have described it
as such: SSH never had, intentionally, the capability to drop idle users based on
these settings. The combination of `ClientAliveCountMax=0` and a nonzero `Interval` just
happened to cause an accidental cutoff as a side effect of how probe logic was
implemented.

This unintentional behavior became the de facto basis for SSH idle timeout guidance
across the industry, embedded in security hardening automation, compliance auditing
tools, and countless hardening blog posts. It was a side effect that got copied uncritically into compliance tooling and
frozen there. The OpenSSH project [fixed the bug in 8.2](https://www.openssh.com/txt/release-8.2)
and the ecosystem largely hasn't caught up. Security researchers recommend this
method. Auditing tools pass. The timeout does not work.

References:
- OpenSSH source: [`serverloop.c`](https://github.com/openssh/openssh-portable/blob/master/serverloop.c)
- Launchpad bug documenting the breakage on upgrade: [LP #1978816](https://bugs.launchpad.net/ubuntu/+source/openssh/+bug/1978816)
- Red Hat Bugzilla tracking the same patch: [BZ #2015828](https://bugzilla.redhat.com/show_bug.cgi?id=2015828)

### After OpenSSH 8.2

OpenSSH 8.2 fixed the bug. `ClientAliveCountMax 0` now explicitly disables
connection termination. The server will no longer drop connections based on
these settings with that value. See the [OpenSSH 8.2 release notes](https://www.openssh.com/txt/release-8.2)
for the documented change.

The correct pattern to approximate a 15 minute idle timeout using
`ClientAlive*` on patched OpenSSH is:

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

**`ChannelTimeout`**: This directive specifies the timeout interval (in seconds)
after which, if no data has been received from the client, the `sshd` service
will send a message through the encrypted channel requesting data.

**`UnusedConnectionTimeout`**: Introduced in OpenSSH 9.2, this directive allows
the server to terminate client connections that do not have any open channels
for a specified duration. This feature complements the `ChannelTimeout` setting,
providing an additional layer of connection management.

For distros running OpenSSH ≥ 9.2, this is the native way to meet both controls:

```
# /etc/ssh/sshd_config.d/99-session-timeout.conf

# Close an idle interactive session after 15 minutes of inactivity
ChannelTimeout session:*=900

# Terminate the connection once no channels remain open for 60 seconds
UnusedConnectionTimeout 60
```

`ChannelTimeout session:*` applies to interactive sessions. You can also scope
it to `direct-tcpip`, `forwarded-tcpip`, or `agent-connection` independently.
`UnusedConnectionTimeout` handles the cleanup after all channels close.

However, these directives are only available in OpenSSH 9.2 and later.

## Impact on Popular Linux Distributions

**Ubuntu 22.04 LTS** ships OpenSSH 8.9p1. `ClientAliveCountMax 0` disables
connection termination. `ChannelTimeout` and `UnusedConnectionTimeout` are not
available. **Ubuntu 24.04 LTS** ships 9.6p1 and has both.

**RHEL 8, AlmaLinux 8, Rocky Linux 8**: RHEL 8 ships OpenSSH 8.0p1, but Red Hat
backported the 8.2 behavior change into that package at RHEL 8.5. The RPM changelog
is explicit: "Upstream: ClientAliveCountMax=0 disable the connection killing
behaviour." AlmaLinux 8 and Rocky Linux 8 carry the same package. All of these have
the new `ClientAliveCountMax=0` semantics regardless of what `ssh -V` reports.

**RHEL 9, AlmaLinux 9, Rocky Linux 9**: Ships OpenSSH 8.7p1. Same `ClientAliveCountMax=0`
behavior. No `ChannelTimeout` or `UnusedConnectionTimeout`.

**RHEL 10, AlmaLinux 10, Rocky Linux 10**: Ships OpenSSH 9.9p1. Both new
directives are available.

### Distribution Compatibility Matrix

| Distribution | OpenSSH Version | Old `CountMax=0` workaround ² | `ChannelTimeout` (9.2+) | `UnusedConnectionTimeout` (9.2+) |
|---|---|:---:|:---:|:---:|
| RHEL 8 / Rocky 8 / Alma 8 | 8.0p1 (backported fix¹) | ⚠️ does nothing | ❌ | ❌ |
| RHEL 9 / Rocky 9 / Alma 9 | 8.7p1 | ⚠️ does nothing | ❌ | ❌ |
| RHEL 10 / Rocky 10 / Alma 10 | 9.9p1 | ⚠️ does nothing | ✅ | ✅ |
| Ubuntu 22.04 LTS | 8.9p1 | ⚠️ does nothing | ❌ | ❌ |
| Ubuntu 24.04 LTS | 9.6p1 | ⚠️ does nothing | ✅ | ✅ |

¹ Red Hat backported the 8.2 behavior change into openssh-8.0p1 at RHEL 8.5
([BZ #2015828](https://bugzilla.redhat.com/show_bug.cgi?id=2015828)). AlmaLinux 8
and Rocky Linux 8 carry the same package. All current RHEL 8 family systems are
affected regardless of what `ssh -V` reports.

² Every distro in this table ships OpenSSH 8.2 or later (or has the fix
backported). On all of them, `ClientAliveCountMax 0` now works exactly as
intended by the OpenSSH developers: it disables connection termination. The
old compliance workaround that relied on the pre-8.2 bug no longer functions.
Any configuration carrying `ClientAliveCountMax 0` is not in compliance.

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

The second candidate was `StopIdleSessionSec` in systemd-logind. It's built into
the init system, which makes it attractive, and RHEL 8.7+ and Ubuntu 22.04 both
ship a systemd version that supports it. The problem is in how it determines
idleness for SSH and terminal sessions. Rather than relying on a signal from the
session itself, it checks the access time (atime) of the pseudo-TTY device
associated with the login. Only keystrokes update that atime. Program output does
not.

The consequence: any session running a long job that produces output but waits for
no keyboard input looks idle by atime and gets terminated. Scrolling through a
`man` page with arrow keys, watching `tail -f` stream log output, or `journalctl -f` tailing the system journal --- all produce no keystroke input
to the PTY and all look idle by atime. Red Hat documented exactly this after
backporting `StopIdleSessionSec` into RHEL and deploying it via the STIG role
([RHEL-24340](https://issues.redhat.com/browse/RHEL-24340)): active sessions were
being terminated unexpectedly,
including GDM graphical sessions. There is also a separate failure mode in the
opposite direction: SSH ControlMaster multiplexed sessions are never terminated even
when genuinely idle, because the subordinate connections share the master's PTY
record and the idle check does not reach them correctly.

On RHEL 8 before 8.7, `StopIdleSessionSec` was not yet backported, so it was not
even available across the full fleet. Between the false-kill behavior on long-running
jobs and the ControlMaster gap, it was not a viable option.

I landed on **[autolog](https://github.com/JKDingwall/autolog)**, a standalone C
daemon that enforces idle session termination by polling the utmp file and killing
sessions based on TTY idle time.

The key difference from `TMOUT` is where autolog operates. It terminates the SSH
login session, specifically the process registered in utmp against a pseudo-TTY.
A detached tmux or screen server does not have a utmp entry; it's a
background process outside the tracked session. When autolog fires, the SSH
connection closes and re-authentication is required, but a detached tmux or screen
session survives and can be reattached. (This assumes `KillUserProcesses=no` in
systemd-logind, which is the default on both Ubuntu server and RHEL-variants.)

The autolog config sets `idle=14 grace=60`: 14 minutes of idle time with a
60 second warning before termination, meeting the 15 minute policy threshold.

On a fleet running OpenSSH 9.2+, `ChannelTimeout` and `UnusedConnectionTimeout`
are the right native answer. On these distros, they weren't available, and
autolog filled that gap.

---

If you're doing CMMC on a Linux fleet and you copied `ClientAliveInterval 900` and
`ClientAliveCountMax 0` into your `sshd_config` from a hardening guide and called
it done, it's worth
verifying what you actually have. The control you're trying to meet and the
mechanism you're using to meet it may not be the same thing, especially
depending on which OpenSSH version your distro ships.

Trust, but verify.
