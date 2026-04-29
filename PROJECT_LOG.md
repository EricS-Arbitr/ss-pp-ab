# PowerPlant / ss-pp-ab — Project Activity Log

Period: 2026-04-14 → 2026-04-24

## Outcome

A working Ansible overlay (`ss-pp-ab`) that provisions the **voltgrid.com** PowerPlant cyber range on top of customer's `range-development-ansible` base. As of this writing the deployment provisions:

- 2 domain controllers (`pp-dc01` primary, `pp-dc02` additional) with replicated domain `voltgrid.com`
- 34 `DomainUsers` (1 admin + 33 named workstation users) with workstation auto-logon configured
- File share `\\pp-file.voltgrid.com\Share` with GPO-mapped drive `S:`
- DMZ services: WordPress site (`pp-www`), forward proxy (`pp-proxy`)
- DNS records (forward + reverse) for internal services (mail, file, sql, smtp, www)
- 8 VyOS routers/firewalls running iBGP (AS 65001 internal, AS 65002 ISP) + OSPF
- 24 Windows workstations + corp servers domain-joined and configured for AE/AUE simulation postures
- Splunk + hunt subnet (`pp-splunk`, `win-hunt-1`)

51 host_vars, 5 group_vars, 18 plays in `arbitr_pp_playbook.yaml`, 29 roles bundled (26 base + 3 custom).

## Phases

### Phase 1 — Foundation (Apr 14–17)

- Identified `ss-pp-ab/` as the range-specific overlay layered on top of `range-development-ansible/` at `/etc/ansible` deploy time.
- Reconciled `hosts` inventory and `host_vars/` against the reference playbook's expected groups (`pdc`, `members`, `vyos`, `aue`, `ae`, etc.).
- Created `group_vars/{all,windows,linux}.yml` with credentials, connection settings, and customer Nexus installer URLs.
- Created `group_vars/voltgrid.yml` (originally `corporate.yml`, renamed to match the new group name) with `domain_name`, `short_domain_name`, `file_server_ip`, `map_drive_*`, `internal_dns_records`, and DomainUsers.
- Bootstrapped first playbook: `init` → `common` → `dcpromo` on `[pdc]`.

### Phase 2 — Domain Controllers (Apr 17)

- Authored **`additional_dc` role** (custom, in `ss-pp-ab/roles/`) using `microsoft.ad.domain_controller` because the upstream `dcpromo` role only creates new forests.
- First DC join failed: `simspace` user wasn't yet a Domain Admin. Resolved by reordering plays so `Create Users` runs on `pdc` (creates simspace as Domain Admin) before `Additional DC` runs on `pp-dc02`.
- Populated `DomainUsers` list from every workstation's `logon_user` (33 workstations) so each user can log on locally on their assigned machine after domain join.
- Added `dc_status` play for replication health checks.

### Phase 3 — Domain Services (Apr 17–20)

Added in playbook order:
- **File Share** on `pp-file` (`fileserver` role; `share_name: Share`, `share_path: c:\share`)
- **Mapped Drive** on `pdc` (`mapped_drive` role; creates "Mapped Network Drives" GPO that's auto-replicated to dc02 via SYSVOL)
- **squid** on `[proxy]` — required `group_vars/proxy.yml` to scope `domain_name` and `proxy_server` to the DMZ outbound proxy without putting it inside the AD domain.
- **wordpress-pv** on `pp-www` (DMZ web server; `docker` + `wordpress-pv` roles)
- **dns** on `pdc` — populated `internal_dns_records` with `www`, `mail`, `sql`, `file` aliases (for AD-joined hosts) plus static A records for non-AD DMZ hosts (`pp-dmz-smtp`, `pp-dmz-dns`, `pp-proxy`) and matching PTR records.
- **ae_gpo** on `pdc` (creates Default Domain Policy GPO loosening UAC + password complexity); **disable_defender** also on `pdc` gated by `groups.get('ae', []) | length > 0` — `disable_defender` was missing from the customer's deployed image, so it was copied into `ss-pp-ab/roles/`.
- **Strip APIPA → Join Domain → Install root certs → apply AUE/AE settings** — completes the workstation posture.

### Phase 4 — Workstation Troubleshooting (Apr 20–21)

Three independent issues, all root-caused and resolved (or worked around):

1. **`win-hunt-1` couldn't get a static IP.** DSC `xIPAddress` returned a generic "Not found" error. Diagnostics showed the adapter was DHCP-enabled (`Dhcp = Enabled`) — image `RDP_Windows_10:1.1.0` defaulted DHCP on, where 1.0.6 didn't. Mitigated by reverting to 1.0.6 image. Filed the gap upstream as a `common` role enhancement.

2. **First workstation in each subnet (`pp-bp-wkstn-1`, `pp-eng-wkstn-1`, `pp-ls-wkstn-1`, `pp-is-wkstn-1`) failed domain join.** Symptom: "domain could not be contacted." Diagnostics revealed Windows had assigned an APIPA `169.254.x.x` alongside the static IP and was preferring it as the outbound source address. Stripping APIPA once didn't help — Windows re-assigned it on the next reboot.
   - Built **`strip_apipa` role** (custom): sets `HKLM:\…\Tcpip\Parameters\IPAutoconfigurationEnabled = 0` (idempotent), reboots if changed, removes any existing 169.254 addresses.
   - Inserted as a play immediately before `Join Domain`.

3. **`pp-eng-wkstn-1` still failed even after APIPA fix.** Diagnostics showed the host couldn't ARP its gateway (`172.16.4.1`) — the empty ARP table indicated a SimSpace-side L2 issue (vNIC not actually attached at the hypervisor level), not a config problem on our end. Resolution path: SimSpace reprovision / vNIC toggle.

### Phase 5 — VyOS Migration (Apr 22)

Customer migrated from SimSpace `Firewall`/`Router` primitives to VyOS VMs (`RC-VyOS-Firewall`, `RC-VyOS-Router`).

- Authored 11 VyOS `host_vars` files (interfaces, OSPF on each, BGP peers).
- Added `Vyos Role` play after `Common Role`.
- BGP single-AS iBGP for the internal fabric, eBGP to `pp-isp-router` (split AS to 65002 to model the ISP boundary).
- NAT masquerade on `pp-external-firewall`'s external interface (switch-0).

**Caveat surfaced and resolved:** my initial host_vars assumed `managementInterface.position: "FIRST"` meant management took its own `eth0` and data-plane started at `eth1`. In reality SimSpace puts the management as a *secondary* IP on the first data-plane interface. Symptom: every router's interfaces had the wrong IP on the wrong eth, OSPF formed but BGP stayed `Active`/0 messages, cross-subnet routing broke. Rewrote all 11 host_vars to start at `eth0 = first data-plane`. Reprovisioning was clean since the customer rebuilds VyOS from defaults.

### Phase 6 — Operational tooling (Apr 23–24)

- **`build_tarball.sh`** — auto-discovers roles referenced by the playbook, walks `meta/main.yml` for transitive dependencies (e.g. `dcpromo` → `handlers`), pulls each role from `ss-pp-ab/roles/` first (custom overlay) or `range-development-ansible/roles/` (base), bundles host_vars/group_vars/hosts/playbook/deploy.sh. Triggered after the customer hit `aue_agent role missing` on a stale ansible VM image — now every deploy ships with the latest base roles even if the on-host repo is out of sync.
- **`UPSTREAM_FIXES.md`** — local-only running log of bugs and gaps in the customer's `range-development-ansible` repo, suitable for direct PR/discussion handoff. Populated from real findings during this work.

### Phase 7 — OT topology refactor (Apr 24)

Customer rebuilt the OT side:
- New OT router `pp-ot-router` is now a SimSpace appliance (`RC_NG_OT_Router`) on a different subnet (192.168.200.0/30 transit, plus Gas-Turbine 192.168.95.0/24, Gas-Turbine-Sim 192.168.90.0/27, new PP-OT-Services 192.168.90.96/27).
- `pp-ot-firewall` moved from switch-5 to switch-8; added PP-OT-DMZ (192.168.90.128/27) gateway.
- 5 new hard-coded OT simulators (`pp-gas-sim`, `pp-gasplant-plc`, `pp-gasvibsens`, `pp-ot-hist`, `pp-engws`) — no `managementInterface`, intentionally outside Ansible scope.
- All previous OT systems (control workstations, ICS data servers, HMIs, VoIP, PLCs, modbus gateway, controller firewall, ctrl router, OT VyOS leftovers) **deleted** from the YAML.

Cleanup in `ss-pp-ab`:
- Deleted 31 `host_vars` files
- Removed 4 routers/firewalls from `[vyos]`: `pp-modbus-gtwy`, `pp-ot-router-old`, `pp-ctrl-rtr`, `pp-controller-firewall`
- Collapsed `[control_workstations]`, `[ot_servers]`, `[hmi]`, `[voip]`, `[ot:children]` (now empty)
- New `[unmanaged]` group documents the 5 hard-coded OT sims
- Removed `ot_servers` from `[servers:children]`

## Custom roles added (live in ss-pp-ab/roles/)

| Role | Purpose |
|---|---|
| `additional_dc` | Promote a Windows host as an additional DC in an existing forest (upstream gap — `dcpromo` only does primary forests) |
| `disable_defender` | Copied verbatim from base because customer's deployed image was missing this role |
| `strip_apipa` | Disable IPv4 autoconfiguration globally + remove existing 169.254 addresses; runs before domain join |

## Upstream issues filed (in `UPSTREAM_FIXES.md`)

1. `common/windows.yml` — typo `Ehternet0`
2. `common/windows.yml` — hardcoded adapter names diverge from the dynamic `network_interfaces` loop
3. `common/windows.yml` — no APIPA cleanup after static IP assignment
4. `common/windows.yml` — no DHCP-disable before `xIPAddress` (image 1.1.0 default)
5. `group_assignment/` — malformed role structure (effectively a no-op)
6. `dcpromo/` — no companion role for additional DCs
7. `deploy.sh` — retry logic doesn't distinguish failure types vs unreachable
8. `vyos/` — `source_nat`/`static_route` README format doesn't match what the role actually reads
9. `vyos/` — interface task uses `match: line` so it appends without removing old addresses (re-runs leave duplicates)

## Tarball state

- Path: `ss-pp-ab/ab_pp.tgz`
- Built by: `ss-pp-ab/build_tarball.sh`
- Latest size: ~185K
- Contents: 51 host_vars, 5 group_vars, 29 roles, hosts, arbitr_pp_playbook.yaml, deploy.sh
- Excluded by design: `UPSTREAM_FIXES.md`, `PROJECT_LOG.md` (local docs)
