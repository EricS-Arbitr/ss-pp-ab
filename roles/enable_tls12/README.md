# Enable TLS 1.2 Role

## Description
Forces TLS 1.2 as the default secure protocol for .NET Framework 4 and WinHTTP on the target host. Required for Windows Server 2012 (and earlier) where the system defaults to TLS 1.0/SSL 3.0 and fails to negotiate HTTPS to modern endpoints (e.g., the customer Nexus).

Symptom this role fixes: `win_get_url` fails with `"The request was aborted: Could not create SSL/TLS secure channel."`

## Required Variables
None.

## What it does
Server 2012 / 2012 R2 require both **SChannel-level** TLS 1.2 enablement *and* `.NET` / `WinHTTP` defaults to be updated — `SchUseStrongCrypto` alone is not enough because SChannel itself refuses TLS 1.2 without the protocol keys. This role sets the full Microsoft-recommended set:

1. SChannel TLS 1.2 client + server (`Enabled=1`, `DisabledByDefault=0`)
2. `.NET 4.0` `SchUseStrongCrypto` + `SystemDefaultTlsVersions` (64-bit and 32-bit)
3. `.NET 2.0/3.5` `SchUseStrongCrypto` (64-bit and 32-bit)
4. WinHTTP `DefaultSecureProtocols = 0x00000A00` (TLS 1.1 + 1.2; 64-bit and 32-bit)

Reboots once after any of those values changed; idempotent on subsequent runs.

## Where to apply
Target the `[winserver2012]` group in the playbook **before** the `common` role runs (which performs the win_get_url that hits Nexus).

## Why it lives in ss-pp-ab and not upstream
Logged in [UPSTREAM_FIXES.md](../../UPSTREAM_FIXES.md) for the `common` role. Once a Server 2012-aware preflight is added upstream, this role can be removed.
