# Strip APIPA Role

## Description
Prevents and removes stale APIPA (link-local `169.254.0.0/16`) IPv4 addresses that Windows assigns when its IPv4 Autoconfiguration feature kicks in. Even with DHCP disabled and a static IP configured, Windows can fall back to APIPA during interface startup and keep the 169.254 address alongside the static one — sometimes selecting it as the source address for outbound traffic and breaking cross-subnet routing. Observed on the first workstation in every PowerPlant subnet; domain join failed with "domain could not be contacted" because traffic to the DC left with a 169.254.x source.

## What the role does
1. Sets `HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\IPAutoconfigurationEnabled` to `0` — turns off the fallback globally.
2. Reboots the host if that registry value was just changed (required to take effect).
3. Removes any existing `169.254.*` addresses from every interface listed in `network_interfaces`.

Fully idempotent — on hosts that already have autoconfig disabled, step 2 is skipped and step 3 is a no-op.

## Required Variables

### In host_vars/[hostname].yml

| Variable | Required | Description |
|----------|----------|-------------|
| network_interfaces | Yes | List of interfaces to clean; each must include `name` (InterfaceAlias) |

If `network_interfaces` isn't defined, the APIPA cleanup step skips.

## Why it lives in ss-pp-ab and not upstream
The equivalent fix is logged as an enhancement suggestion in [UPSTREAM_FIXES.md](../../UPSTREAM_FIXES.md) for the `common` role. Once that lands upstream, this role can be removed.
