---
title: "DHCP Option 81 in systemd-networkd: The Undocumented Behavior"
date: 2026-03-08
draft: false
ShowToc: true
tags: ["linux", "networking", "dhcp", "systemd", "ubuntu", "sysadmin"]
description: "I inherited a set of Ubuntu servers with inconsistent Dynamic DNS updates and ended up submitting a fix to the systemd man page."
---

I inherited a set of Ubuntu servers that were provisioned outside of our normal
provisioning and configuration methods of Foreman and Ansible, talking to Windows
DHCP servers that use DHCP Option 81 for dynamic DNS registration. The problem was
that some servers were getting their DNS A records registered correctly and some were
not. The inconsistency was problematic, and the more I dug into it, the worse it got.

This is the story of chasing that inconsistency, finding a workaround, realising the
workaround was unnecessary, and ending up with a PR open against systemd upstream to
fix a man page that has been inconsistent and ambiguous for years.

---

## The Setup

The Windows DHCP servers in our environment use Option 81 (the Client FQDN option,
[RFC 4702](https://www.rfc-editor.org/rfc/rfc4702)) to do dynamic DNS updates. When a DHCP client sends Option 81 with its
fully-qualified domain name, the DHCP server takes that as the authoritative
hostname and registers a DNS A record for it. When Option 81 is absent, the server
falls back to Option 12 (the plain Hostname option). Windows DHCP servers can be
configured to perform dynamic DNS updates using Option 12,
but in our environment this is configured per-scope rather than globally, making
Option 81 the more reliable path for consistent DNS registration across all scopes.

The Ubuntu servers are managed by systemd-networkd. Some were sending Option 81 and
getting proper DNS entries. Others were sending only Option 12 with a short hostname
and either getting a broken DNS entry or nothing at all. The difference came down to
what was set as the kernel UTS hostname: servers with an FQDN were sending Option 81,
and servers with a single-label short name were sending only Option 12.

---

## Finding the Bug Report

Searching for a way to force Option 81 from systemd-networkd, I found
[Launchpad bug #2037719](https://bugs.launchpad.net/ubuntu/+source/netplan.io/+bug/2037719)
which was asking essentially the same question. A maintainer responded by citing the
`systemd.network(5)` man page text for `Hostname=` under `[DHCPv4]`:

> The hostname... must consist only of 7-bit ASCII lower-case characters and **no spaces or dots**.

The maintainer's conclusion: multi-label hostnames (FQDNs) are explicitly prohibited
by this directive, and the correct approach if you need Option 81 is to use
`SendOption=` to construct a raw DHCP option manually.

At the time I read this, it seemed authoritative. The man page said dots were
forbidden. A maintainer had cited the man page. So I set about figuring out how to
make `SendOption=` work.

---

## The Drop-in Workaround

I put together a `SendOption=` drop-in for systemd-networkd:
```ini
[DHCPv4]
SendOption=81:string:\x01\x00\x00lnx-app-01.corp.example.com
```

I tested this and the implementation was functional, so I moved forward with it.
But the approach felt wrong from the start. The encoding was manual and brittle,
constructing a raw DHCP option payload by hand with flag bytes from
[RFC 4702](https://www.rfc-editor.org/rfc/rfc4702).

While working with a colleague, we looked at the `dhcp4-overrides` options in
netplan and found that setting `hostname` there also resulted in Option 81 being
sent. At the time we assumed this was still only producing Option 12. After
looking more carefully at the packet captures, that turned out to be wrong. I kept
digging to understand what was actually happening.

---

## The Packet Captures

I ran a series of packet captures across seven configurations, capturing full DHCP
handshakes and verifying the kernel UTS hostname state before each test.

The result that stopped me was **Test 2**: kernel UTS hostname set to
`lnx-app-01.corp.example.com`, no drop-in, no netplan overrides, no configuration
at all.
```
DHCP-Message (53), length 1: Discover
FQDN (81), length 31: [SE] "^Klnx-app-01^Dcorp^Gexample^Ccom^@"
```

Option 81. Correct DNS wire format. Flags `[SE]` = 0x05. Option 12 absent.

No configuration required. Just an FQDN as the kernel UTS hostname.

I ran it again to make sure. Same result.
The code sends a correctly encoded Option 81.

The `^K`, `^D`, `^G`, `^C` control characters in the tcpdump output are
[RFC 1035](https://www.rfc-editor.org/rfc/rfc1035) DNS label length bytes, each one
being the byte count of the label that follows. `^K` is 11 (the length of
`lnx-app-01`), `^D` is 4 (`corp`), `^G` is 7 (`example`), `^C` is 3 (`com`). The
trailing `^@` is the null root terminator. This is exactly what
`dns_name_to_wire_format()` produces. Perfect [RFC 4702](https://www.rfc-editor.org/rfc/rfc4702)
wire format, generated natively by systemd-networkd, with zero configuration.

The dangerous result was **Test 6**: FQDN as the kernel UTS hostname *and* the
`SendOption=` drop-in deployed simultaneously.
```
FQDN (81), length 31: [SE] "^Klnx-app-01^Dcorp^Gexample^Ccom^@"
FQDN (81), length 29: [SE] "lnx-app-01.corp.example.com"
```

Two Option 81 instances in the same packet. The first is from the native code in
DNS wire format; the second is from `SendOption=` in plain ASCII with a flag byte
claiming DNS wire format encoding, which is a flag/encoding mismatch.
[RFC 4702](https://www.rfc-editor.org/rfc/rfc4702) does not define behavior
for duplicate Option 81, and systemd-networkd produces no warning.

---

## Reading the Source

To understand what was actually happening, I pulled
[`src/libsystemd-network/sd-dhcp-client.c`](https://github.com/systemd/systemd/blob/main/src/libsystemd-network/sd-dhcp-client.c)
from the systemd source. The relevant function is
[`client_append_fqdn_option()`](https://github.com/systemd/systemd/blob/main/src/libsystemd-network/sd-dhcp-client.c#:~:text=client_append_fqdn_option):
```c
static int client_append_fqdn_option(
                DHCPMessage *message,
                size_t optlen,
                size_t *optoffset,
                const char *fqdn) {

        uint8_t buffer[3 + DHCP_MAX_FQDN_LENGTH];
        int r;

        buffer[0] = DHCP_FQDN_FLAG_S | /* Request server to perform A RR DNS updates */
                    DHCP_FQDN_FLAG_E;  /* Canonical wire format */
        buffer[1] = 0;                 /* RCODE1 (deprecated) */
        buffer[2] = 0;                 /* RCODE2 (deprecated) */

        r = dns_name_to_wire_format(fqdn, buffer + 3, sizeof(buffer) - 3, false);
        if (r > 0)
                r = dhcp_option_append(message, optlen, optoffset, 0,
                                       SD_DHCP_OPTION_FQDN, 3 + r, buffer);

        return r;
}
```

The decision point is `dns_name_is_single_label()`, called earlier in `dhcp4_set_hostname()`.
When the hostname is a single-label name, Option 12 is sent. When it is a multi-label
name, `client_append_fqdn_option()` is called and Option 81 is sent in DNS wire format
with flags 0x05. The `hostname_is_valid()` function used to validate the configured
hostname accepts multi-label names at this point in the logic. The "no dots"
prohibition in the man page is ambiguous and misleading.

The reason the affected Ubuntu servers never reach the FQDN branch is straightforward:
`dhcp4_set_hostname()` reads the kernel UTS hostname via `gethostname_strict()`, which
calls `uname()` rather than performing DNS resolution. The FQDN returned by `hostname -f`
is a runtime DNS lookup artifact and is never consulted during DHCP packet construction.
Servers provisioned with a single-label hostname in `/etc/hostname` will always have a
single-label kernel UTS hostname, which always produces Option 12.

One operational note: modifying `/etc/hostname` directly does not update the running
kernel UTS hostname. `hostnamectl set-hostname` must be used for the change to take
effect immediately, since `gethostname_strict()` reads from kernel memory via `uname()`,
not from disk.

---

## The Full Test Results

Seven tests on Ubuntu 22.04 (systemd 249.11), packet captured across full DHCP
handshakes.

| Test | Kernel UTS Hostname | Configuration | Option 12 | Option 81 | Encoding |
|---|---|---|---|---|---|
| 1 | Single-label | None | Yes | No | - |
| 2 | FQDN | None | No | Yes `[SE]` | Wire format |
| 3a | Single-label | netplan FQDN override | No | Yes `[SE]` | Wire format |
| 3b | Single-label | netplan single-label override | Yes | No | - |
| 4 | Single-label | `SendOption=` `\x05` | Yes | Yes `[SE]` | ASCII, flag mismatch |
| 5 | Single-label | `SendOption=` `\x01` | Yes | Yes `[S]` | ASCII |
| 6 | FQDN | `SendOption=` drop-in | No | Yes x2 | Wire format + ASCII (mismatch) |
| 7 | Single-label | `Hostname=` FQDN in drop-in | No | Yes `[SE]` | Wire format |

Tests 2, 3a, and 7 produced identical output. All three invoke the same
`client_append_fqdn_option()` function, produce correct [RFC 4702](https://www.rfc-editor.org/rfc/rfc4702)
DNS wire format, suppress Option 12, and require no manual encoding.

---

## Conclusions: Ranked Approaches

**1. FQDN as the kernel UTS hostname** - zero configuration, native path, correct wire
format, Option 12 suppressed (Test 2). Works if your provisioning system sets
the FQDN via `hostnamectl set-hostname`.

**2. `Hostname=<fqdn>` in a systemd-networkd drop-in** - correct for servers where
the kernel UTS hostname is single-label by convention. Same native function, same
wire format, Option 12 suppressed, single clean Option 81 (Test 7).

**3. `dhcp4-overrides.hostname: <fqdn>` in netplan** - equivalent to option 2,
operates above the networkd layer but produces identical wire format output (Test 3a).

**4. `SendOption=81:string:\x01\x00\x00<fqdn>`** - functional but sends Option 12
alongside Option 81 and uses ASCII encoding. Use only if the native `Hostname=`
directive is unavailable.

**5. `SendOption=81:string:\x05\x00\x00<fqdn>`** - avoid. Claims DNS wire format
encoding but the payload is ASCII. Also sends Option 12 alongside Option 81.

The configuration to actively avoid is Test 6. Any automation deploying a
`SendOption=` drop-in fleet-wide without checking whether the kernel UTS hostname is
already an FQDN will produce duplicate Option 81 with conflicting encodings on
correctly-configured machines, with no warning from systemd-networkd. If you are
deploying a drop-in, use `Hostname=` not `SendOption=`, and guard against machines
whose kernel UTS hostname is already multi-label.

---

## Fixing the Documentation

The man page language is ambiguous. The "no dots" text in `SendHostname=` and
`Hostname=` under `[DHCPv4]` describes a constraint that applies to Option 12
specifically. [RFC 2132](https://www.rfc-editor.org/rfc/rfc2132) option 12 is
conventionally a single-label name, and the guidance is accurate in that context.
But the directive is not limited to Option 12, and the text gives no indication that
multi-label hostnames are not just accepted but result in a completely different DHCP
option being sent.

I posted a comment to [Launchpad bug #2037719](https://bugs.launchpad.net/ubuntu/+source/netplan.io/+bug/2037719)
with the test results, and submitted
[systemd/systemd PR #40996](https://github.com/systemd/systemd/pull/40996) to fix
both `SendHostname=` and `Hostname=` in `man/systemd.network.xml`.

The fix removes "or dots" from the affected text and adds a note explaining the
actual behavior:

> A single-label hostname is sent as DHCP option 12 (Host Name, RFC 2132); a
> multi-label hostname (FQDN) is sent instead as DHCP option 81 (Client FQDN, RFC 4702).

The code has always been correct. It just needed the documentation to catch up.

---

## References

- [systemd/systemd PR #40996](https://github.com/systemd/systemd/pull/40996)
- [Launchpad bug #2037719](https://bugs.launchpad.net/ubuntu/+source/netplan.io/+bug/2037719)
- [`client_append_fqdn_option()` in sd-dhcp-client.c](https://github.com/systemd/systemd/blob/main/src/libsystemd-network/sd-dhcp-client.c#:~:text=client_append_fqdn_option)
- [systemd.network(5) - \[DHCPv4\] Section Options](https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html#%5BDHCPV4%5D%20SECTION%20OPTIONS)
- [RFC 4702 - The DHCP Client FQDN Option](https://www.rfc-editor.org/rfc/rfc4702)
- [RFC 2132 - DHCP Options and BOOTP Vendor Extensions](https://www.rfc-editor.org/rfc/rfc2132)
- [RFC 1035 - Domain Names: Implementation and Specification](https://www.rfc-editor.org/rfc/rfc1035)
