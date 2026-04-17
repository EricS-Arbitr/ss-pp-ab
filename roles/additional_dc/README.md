# Additional Domain Controller Role

## Description
Promotes a Windows Server into an existing Active Directory domain as an additional domain controller. Installs RSAT tools, joins the target DC to the domain, installs DNS, and replicates from the existing PDC. Must run after `dcpromo` has created the forest on the primary DC.

## Variable Definition Location
Variables for this role should be defined in **group_vars/[domain].yml** where [domain] matches your AD domain inventory group name (e.g., corporate.yml).

## Required Variables

### In group_vars/all.yml

| Variable | Required | Description |
|----------|----------|-------------|
| domain_admin | Yes | Username with rights to add a DC to the domain |
| domain_admin_password | Yes | Password for domain_admin; also used as DSRM/safe-mode password |

### In group_vars/[domain].yml

| Variable | Required | Description |
|----------|----------|-------------|
| domain_name | Yes | Fully qualified domain name the host will join as a DC |

## Prerequisites
- The primary DC (`pdc` group) must be fully promoted and reachable.
- The target host's DNS must point to the primary DC so it can locate the domain.
- The target host must be able to reach the primary DC over standard AD ports.

## Notes
- Uses the `microsoft.ad.domain_controller` module, distinct from `microsoft.ad.domain` used by the `dcpromo` role (which creates a new forest).
- Triggers a reboot via the shared `Reboot Windows` handler.
