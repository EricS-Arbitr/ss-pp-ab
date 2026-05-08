# Enable TLS 1.2 Role

## Description
Forces TLS 1.2 as the default secure protocol for .NET Framework 4 and WinHTTP on the target host. Required for Windows Server 2012 (and earlier) where the system defaults to TLS 1.0/SSL 3.0 and fails to negotiate HTTPS to modern endpoints (e.g., the customer Nexus).

Symptom this role fixes: `win_get_url` fails with `"The request was aborted: Could not create SSL/TLS secure channel."`

## Required Variables
None.

## What it does
Sets three registry values:
1. `HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto = 1`
2. `HKLM\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto = 1`
3. `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp\DefaultSecureProtocols = 0x00000A00`

Reboots the host once if any of those values changed; idempotent on subsequent runs.

## Where to apply
Target the `[winserver2012]` group in the playbook **before** the `common` role runs (which performs the win_get_url that hits Nexus).

## Why it lives in ss-pp-ab and not upstream
Logged in [UPSTREAM_FIXES.md](../../UPSTREAM_FIXES.md) for the `common` role. Once a Server 2012-aware preflight is added upstream, this role can be removed.
