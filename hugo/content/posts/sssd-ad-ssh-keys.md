---
title: "SSSD Didn't Get the Memo: Disabled Accounts and Stale Keys with Active Directory"
date: 2026-03-21
draft: false
ShowToc: true
TocOpen: false
tags:
  - linux
  - sssd
  - activedirectory
  - ssh
  - security
  - sysadmin
  - cmmc
description: >
  Setting up sss_ssh_authorizedkeys in a lab environment uncovered two security issues
  in a common SSSD configuration: disabled AD accounts could authenticate via SSH key,
  and revoked keys stayed valid for up to 90 minutes after removal from AD.
---

This post covers setting up SSH public key authentication on AD-joined Linux hosts using SSSD and `sss_ssh_authorizedkeys`, and two security issues I found in a common SSSD configuration while testing the setup in a lab environment.

The pattern stores SSH public keys in Active Directory. SSSD fetches them at login time via the `ldap_user_ssh_public_key` attribute mapping and hands them to sshd. The relevant snippet in `/etc/ssh/sshd_config`:

```
AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys %u
AuthorizedKeysCommandUser nobody
```

During testing two issues surfaced that are worth documenting: disabled AD accounts could authenticate via SSH key, and revoked keys remained valid for up to 90 minutes after removal from AD.

---

## Lab setup

The test hosts are Linux VMs joined to an Active Directory domain using `realmd` with `adcli` as the join backend. SSSD handles identity and authentication via the AD provider. The starting configuration for this testing was a common baseline for AD-joined Linux:

```ini
[sssd]
domains = lab.opscode.io
config_file_version = 2
services = nss, pam, ssh

[domain/lab.opscode.io]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = LAB.OPSCODE.IO
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u
ad_domain = lab.opscode.io
use_fully_qualified_names = False
ldap_id_mapping = True
access_provider = simple
simple_allow_groups = linux-admins, linux-users
ldap_user_ssh_public_key = <ad attribute>
```

`access_provider = simple` with `simple_allow_groups` is a common pattern to restrict login to members of specific AD groups. `ldap_user_ssh_public_key` tells SSSD which AD attribute holds the SSH public key.

---

## Finding 1: Disabled AD accounts can SSH into systems

The first issue came up during initial testing. A test account was disabled in Active Directory, then SSH was attempted to a jump server with that account's key.

It worked.

The account had `userAccountControl: 514` in AD, confirmed via ldapsearch:

```
$ ldapsearch -H ldaps://dc01.lab.opscode.io -x -W -D "lab\svc-ldap" \
  -b "OU=AdminAccounts,OU=Users,DC=lab,DC=opscode,DC=io" \
  "(sAMAccountName=charlie-admin)" userAccountControl

dn: CN=charlie-admin,OU=AdminAccounts,OU=Users,DC=lab,DC=opscode,DC=io
userAccountControl: 514
```

`514` is `0x202` - account disabled. The login succeeded regardless.

### Why

`access_provider = simple` evaluates exactly one thing: whether the user is a member of the groups listed in `simple_allow_groups`. Disabled and locked account states are never checked. If the account is in the allowed group, `simple` returns success.

The SSSD backend logs confirmed this. SSSD read and stored `adUserAccountControl [514]` during the user object fetch:

```
[sdap_attrs_add_ldap_attr] Adding adUserAccountControl [514] to attributes of [charlie-admin@lab.opscode.io].
```

And then did nothing with it. The access check that ran was `sdap_account_expired_ad`, which only evaluates `adAccountExpires`. Expiration was `9223372036854775807` (never), so it passed. Disabled status was never evaluated, and the PAM account phase where account status is normally enforced was never reached.

---

## Finding 2: Revoked SSH keys stay valid for up to 90 minutes

SSSD's default `entry_cache_timeout` is `5400` seconds - 90 minutes. User objects, including their cached SSH public keys, are served from SSSD's local LDB database until that TTL expires.

After removing a key from AD, `sssctl user-show` confirmed what was happening:

```
$ sssctl user-show charlie-admin
Cache entry last update time: 03/20/26 21:31:17
Cache entry expiration time: 03/20/26 23:01:17
```

Last update to expiration: exactly 90 minutes. The key stayed in the local SSSD cache, served on every auth attempt, until that TTL elapsed regardless of what AD said.

The default `entry_cache_nowait_percentage = 50` compounds this. At 50% of the TTL window SSSD begins refreshing the cache entry in the background but still immediately returns the stale cached value to any concurrent auth attempt. A key removed from AD can be served beyond the 50% mark while the background refresh is still in flight.

---

## The fix

### 1. Change access_provider from simple to ad

```ini
access_provider = ad
ad_access_filter = (|(memberOf=CN=linux-admins,OU=Groups,DC=lab,DC=opscode,DC=io)(memberOf=CN=linux-users,OU=Groups,DC=lab,DC=opscode,DC=io))
```

`access_provider = ad` evaluates AD account status - disabled, locked, expired - via `userAccountControl` during the PAM account phase. `access_provider = simple` does not.

The `ad_access_filter` preserves the group restriction that `simple_allow_groups` was providing. After applying this configuration the same disabled account was correctly denied:

```
sshd: pam_sss(sshd:account): system info: [The user account is disabled on the AD server]
sshd: pam_sss(sshd:account): Access denied for user charlie-admin: 6 (Permission denied)
sshd: fatal: Access denied for user charlie-admin by PAM account configuration [preauth]
```

### 2. Reduce the cache TTL

```ini
entry_cache_timeout = 1
entry_cache_nowait_percentage = 0
```

`entry_cache_timeout = 1` means any authentication attempt more than 1 second after the last lookup for that user triggers a live LDAP query to AD. It cannot be set to 0 - SSSD always writes to the LDB cache after every fetch, this is architectural. With a 1-second TTL the cache expires almost immediately, so every real world auth hits AD live.

`entry_cache_nowait_percentage = 0` disables the background stale and refresh behavior described above. At the default of 50, SSSD serves stale data immediately past the 50% mark of the TTL window while refreshing in the background. Setting it to 0 means the foreground request waits for the live AD result rather than receiving a stale cached value.

### 3. Disable credential caching

```ini
cache_credentials = false
krb5_store_password_if_offline = false
```

`cache_credentials = false` means SSSD does not store a local password hash for domain users. If AD is unreachable, password-based authentication will fail. `krb5_store_password_if_offline = false` prevents Kerberos credentials from being stored locally for offline use.

### 4. Explicit PAM offline settings

```ini
[pam]
offline_credentials_expiration = 0
offline_failed_login_attempts = 0
```

These explicitly zero out offline PAM auth behavior, consistent with `cache_credentials = false`.

### 5. Flush cache on restart

A plain `systemctl restart sssd` does not flush the LDB cache. Existing entries with old TTLs survive a restart and continue to be served until they individually expire. The correct restart procedure is:

```bash
systemctl stop sssd
rm -rf /var/lib/sss/db/*
rm -rf /var/lib/sss/mc/*
systemctl start sssd
```

---

## Warning - AD query cost at scale

At scale, proper LDAP query structure and optimization is critical. Large domains with many objects and concurrent authentications will degrade under poorly structured filters regardless of caching configuration. This is especially true when local SSSD caching is effectively disabled via `entry_cache_timeout = 1`, where every authentication attempt becomes a live LDAP query to AD with no local buffering. I am not an AD or LDAP expert so I won't elaborate further here and would defer to someone with that expertise.

---

## Operational note - SSH key revocation

With `entry_cache_timeout = 1` the practical revocation window is AD replication latency - roughly 30-60 seconds in my testing. That is the floor - SSSD cannot know a key is gone before AD has propagated the change to the DC it is querying.

If you want a longer cache TTL for performance reasons but still need near-immediate key revocation, the procedure is:

1. Remove the key from the AD attribute
2. Wait for AD replication
3. Clear the local SSSD cache for the user in question

---

## Final config

```ini
[nss]
cache_first = false
entry_cache_nowait_percentage = 0

[sssd]
domains = lab.opscode.io
config_file_version = 2
services = nss, pam, ssh

[domain/lab.opscode.io]
default_shell = /bin/bash
krb5_store_password_if_offline = false
cache_credentials = false
krb5_realm = LAB.OPSCODE.IO
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u
ad_domain = lab.opscode.io
use_fully_qualified_names = False
ldap_id_mapping = True
access_provider = ad
ad_access_filter = (|(memberOf=CN=linux-admins,OU=Groups,DC=lab,DC=opscode,DC=io)(memberOf=CN=linux-users,OU=Groups,DC=lab,DC=opscode,DC=io))
ldap_referrals = false
ldap_user_ssh_public_key = <ad attribute>
entry_cache_timeout = 1
entry_cache_nowait_percentage = 0
ldap_purge_cache_timeout = 60

[pam]
offline_credentials_expiration = 0
offline_failed_login_attempts = 0
```

## CMMC relevance

Both findings in this post map directly to CMMC Level 2 controls.

**AC.L1-3.1.1** requires limiting system access to authorized users. A disabled AD account is by definition no longer authorized. With `access_provider = simple`, SSSD reads `userAccountControl` from AD, stores it in its local cache, and never acts on it. Authentication succeeds regardless of account state.

**IA.L2-3.5.6** requires disabling identifiers after a defined period of inactivity. The intent of this control is that disabling an account actually revokes access. With the default 90 minute `entry_cache_timeout`, a disabled account's SSH key remains valid on every affected host until the cache TTL expires independently on each one, up to 90 minutes after the account was disabled in AD.

Switching to `access_provider = ad` and reducing `entry_cache_timeout` closes both gaps. The account status check is enforced at the PAM layer on every authentication attempt, and key revocation takes effect within AD replication time rather than within the SSSD cache TTL window.
