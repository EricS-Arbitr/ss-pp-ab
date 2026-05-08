# Prestage Range Agent Role

## Description
Pre-installs `range-agent-bootstrap` on hosts that cannot reach the customer Nexus over HTTPS. Specifically a workaround for Server 2012 R2, which fails the `common` role's `range-agent-bootstrap using win_get_url with proxy settings` task with `"Could not create SSL/TLS secure channel"` despite full TLS 1.2 enablement (SChannel + .NET 4 + WinHTTP all configured per [enable_tls12](../enable_tls12/) and confirmed via registry). The handshake to the Nexus endpoint fails for reasons we couldn't isolate.

This role pre-installs the MSI via WinRM file transfer instead, sidestepping HTTPS entirely. Once installed, `common`'s `Check if RangeAgent Service Exists` returns `True` and the failing download/install tasks are skipped via the existing `when: not service_check.exists` guard.

## Required Variables

| Variable | Source | Description |
|---|---|---|
| `range_agent_bootstrap` | `group_vars/windows.yml` | Filename of the MSI (matches the upstream variable) |

## Required Files
The MSI must be present at `<playbook_dir>/files/<range_agent_bootstrap>` on the controller. Ansible's `win_copy` looks there automatically when given a bare filename. The bundled `build_tarball.sh` checks customer Nexus on each build and refreshes this file if a newer version is available.

## Where to apply
Target `[winserver2012]` in the playbook **after** `enable_tls12` and **before** `Common Role`. After both roles run, `common`'s download path is bypassed and the host continues normally.

## Why it lives in ss-pp-ab and not upstream
Logged in [UPSTREAM_FIXES.md](../../UPSTREAM_FIXES.md) — the upstream `common` role should detect older Server SKUs and pre-install from a bundled file rather than depending on HTTPS, OR offer a `range_agent_bootstrap_local_path` override that skips the download.
