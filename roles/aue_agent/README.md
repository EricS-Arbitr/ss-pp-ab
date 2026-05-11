# aue_agent Role — Local Override

Mirrors upstream `range-development-ansible/roles/aue_agent/`. The only change: the `win_get_url` task is gated by a `win_stat` check that skips the download when AUE Agent is already installed at `C:\Program Files\AUEAgent`.

This change is necessary because Server 2012 R2 hosts in the PowerPlant range cannot complete TLS 1.2 handshakes to the customer Nexus (see [UPSTREAM_FIXES.md](../../UPSTREAM_FIXES.md)) — the `win_get_url` task fails with `"Could not create SSL/TLS secure channel"` regardless of registry-level TLS 1.2 enablement. The `prestage_aue_agent` role installs the agent ahead of time via WinRM file transfer, after which the upstream win_get_url is no longer needed.

When AUE Agent is NOT pre-installed (e.g., on Server 2022 hosts that can TLS to Nexus normally), this role behaves identically to upstream — downloads and installs.

The downstream `win_package` task is unchanged (it already has `creates_path: C:\Program Files\AUEAgent` so the install itself is idempotent).
