# Prestage AUE Agent Role

## Description
Pre-installs the AUE agent on Windows Server 2012 R2 hosts (or any host that can't reach the customer Nexus over HTTPS). Same pattern as `prestage_range_agent`. The upstream `aue_agent` role's `win_get_url` call to Nexus fails with `"Could not create SSL/TLS secure channel"` on Server 2012 R2 despite full TLS 1.2 enablement (SChannel + .NET 4 + WinHTTP).

This role copies the AUE installer via WinRM (no HTTPS) and runs it. The companion `ss-pp-ab/roles/aue_agent/` override adds a skip-if-installed check so the upstream role's failing download is bypassed when this prestage has succeeded.

## Required Variables

| Variable | Source | Description |
|---|---|---|
| `aue_agent` | `group_vars/windows.yml` | Filename of the installer (matches upstream variable) |

## Required Files
The installer must be present at `<playbook_dir>/files/<aue_agent>` on the controller. `build_tarball.sh`'s `NEXUS_FETCH` array refreshes this file each build when Nexus is reachable.

## Where to apply
Target `winserver2012:&ae` (or similar — any winserver2012 host that's also in `[aue]` or `[ae]`) in the playbook **before** the `apply AUE settings` and `apply AE settings` plays so the agent is in place when those plays' `aue_agent` role runs.

## Why it lives in ss-pp-ab and not upstream
Tracked in [UPSTREAM_FIXES.md](../../UPSTREAM_FIXES.md). Once the upstream `aue_agent` role supports a `aue_agent_local_path` override (analogous to the suggested `range_agent_bootstrap_local_path`), this role can be retired.
