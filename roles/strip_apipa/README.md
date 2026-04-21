# Strip APIPA Role

## Description
Removes stale APIPA (link-local `169.254.0.0/16`) IPv4 addresses from every interface listed in a host's `network_interfaces`. Windows occasionally retains an APIPA address alongside a later-applied static IP — usually from an early DHCP attempt before the static config took effect — and may select that APIPA as the outbound source address, breaking routing to other subnets. Running this role after static IPs are set and before any task that depends on cross-subnet connectivity (e.g., domain join) prevents that failure mode.

## Required Variables

### In host_vars/[hostname].yml

| Variable | Required | Description |
|----------|----------|-------------|
| network_interfaces | Yes | List of interfaces to clean; each must include a `name` field (matches InterfaceAlias in Windows) |

If `network_interfaces` isn't defined, the role is a no-op.

## Behavior
For each entry in `network_interfaces`, runs:
```powershell
Get-NetIPAddress -InterfaceAlias <name> -AddressFamily IPv4 |
    Where-Object IPAddress -Like '169.254.*' |
    Remove-NetIPAddress -Confirm:$false
```
No-op if no APIPA address is present on the adapter.

## Why it lives in ss-pp-ab and not upstream
The equivalent fix has been added as an enhancement suggestion in [UPSTREAM_FIXES.md](../../UPSTREAM_FIXES.md) for the `common` role. Once that lands upstream, this role can be removed.
