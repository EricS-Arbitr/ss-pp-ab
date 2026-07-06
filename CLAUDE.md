# CLAUDE.md — ss-pp-ab onboarding guide

This file provides guidance to Claude Code (claude.ai/code) and to human developers picking up the PowerPlant range overlay. Read this first.

## What this project is

This directory (`ss-pp-ab/`) is a **range-specific Ansible overlay** for the **PowerPlant** cyber-range scenario (`voltgrid.com` domain) deployed on the **SimSpace NG** platform. It is NOT a standalone playbook — it layers on top of the customer's shared platform repo at `../range-development-ansible/`. See [range-development-ansible/CLAUDE.md](../range-development-ansible/CLAUDE.md) for the platform-level architecture.

Two-sentence summary: `range-development-ansible` ships base roles and a reference playbook. `ss-pp-ab` ships range-specific inventory + host_vars + group_vars + custom roles + a range-specific playbook (`arbitr_pp_playbook.yaml`), bundles selected base roles + the custom overlays into a tarball (`build_tarball.sh` → `ab_pp.tgz`), and the tarball deploys to `/etc/ansible` on the range's Ansible host where `deploy.sh` runs the playbook.

## Repo layout (just this directory)

```
ss-pp-ab/
├── CLAUDE.md                    ← you are here
├── README.md                    ← just says "temp repo"; ignore
├── PROJECT_LOG.md               ← chronological build history (Apr–May 2026)
├── ACTION_PLAN.md               ← original phased plan (mostly done)
├── UPSTREAM_FIXES.md            ← ★ running log of customer-repo bugs/gaps + overlay workarounds
├── arbitr_pp_playbook.yaml      ← the range's playbook (30+ plays)
├── hosts                        ← inventory
├── group_vars/                  ← all.yml, linux.yml, windows.yml, pfsense.yml, vyos_routes_only.yml, voltgrid.yml, proxy.yml
├── host_vars/                   ← one yaml per managed host (51 files)
├── roles/                       ← custom roles that override or supplement base roles
├── build_tarball.sh             ← auto-discovers roles from playbook, bundles ab_pp.tgz
├── deploy.sh                    ← runs ansible-playbook (3 attempts on failure)
├── verify_vars.py               ← Jinja-var presence checker (run as part of build_tarball.sh)
├── requirements.yml             ← Ansible Galaxy collections (currently pfsensible.core)
└── ab_pp.tgz                    ← built artifact (gitignored in practice; rebuild with build_tarball.sh)
```

Custom roles currently in `roles/` (those not in the base repo, or that override it):

| Role | Purpose |
|---|---|
| `pfsense_firewall` | Drives pfSense 2.8.1 via pfsensible.core (+ php -r shims for what the collection lacks). Configures interfaces, gateways, default-gw pin, outbound-NAT disable, static routes, lab firewall rules, and FRR/BGP. |
| `syslog_server` | Configures pp-syslog as central rsyslog collector (UDP+TCP 514, per-host files). |
| `splunk-forwarder` | Overlay of base splunk-forwarder role; extends `lin_inputs.conf.j2` to tail `/var/log/remote/` when host is in `[syslog]`. |
| `wordpress-pv` | Overlay of base wordpress-pv role; binds container to 127.0.0.1:8080 so host nginx can vhost-route. |
| `billing_site` | Voltgrid Power customer billing portal (Flask + gunicorn on pp-www). |
| `voltgrid_site` | Marketing-style site at www.voltgrid.com (sits on pp-www nginx default vhost via wordpress-pv container). |
| `disable_defender` | Overlay of base role with PowerPlant-specific tweaks. |
| `strip_apipa` | Removes 169.254.x.x addresses Windows assigns when DHCP-then-static handoff lags. |
| `additional_dc` | Promotes pp-dc02 into the existing voltgrid.com forest (no sibling role in base repo). |
| `network_discovery` | Suppresses the Win10/11 "Public / Private network" Pop-up + enables network discovery. |
| `splunk-es` | Overlay of base splunk-es role with custom indices and app installation. |

## Build and deploy workflow

```bash
# Build the tarball (run from this directory)
./build_tarball.sh                    # writes ab_pp.tgz

# Inspect the playbook order
grep '^- name:' arbitr_pp_playbook.yaml

# On the Ansible host (after copying ab_pp.tgz over and extracting to /etc/ansible)
./deploy.sh                           # runs ansible-playbook with 3-attempt retry

# Direct playbook run (on the Ansible host)
ansible-playbook arbitr_pp_playbook.yaml
ansible-playbook arbitr_pp_playbook.yaml --tags pfsense       # tag-scoped slice
ansible-playbook arbitr_pp_playbook.yaml --limit pp-ot-firewall
```

`build_tarball.sh` auto-discovers roles from `arbitr_pp_playbook.yaml`'s `roles:` blocks (plus meta dependencies), pulls each from `../range-development-ansible/roles/` first then overrides with the local `./roles/`. **Don't manually edit the role list in build_tarball.sh — add a role by referencing it in a play.**

`verify_vars.py` runs at the end of `build_tarball.sh` and warns about Jinja `{{ var }}` references that don't resolve from any `group_vars`, `host_vars`, or `role/defaults`. The three current "expected" warnings (`billing_secret_key`, `nat`, `pfsense_stale_gateways`) all have `| default(...)` filters and are intentional.

## Network topology (the mental model)

```
                 ┌──────────────────────────────────────────────┐
                 │  is-inet (200.200.200.2, owns /32 aliases)   │
                 └──────────────────────────────────────────────┘
                                  │ default
                       200.200.200.0/24
                                  │
              ┌──────────────────────────────────────────────┐
              │  pp-isp-router (VyOS, AS 65002)              │
              └──────────────────────────────────────────────┘
                       eBGP │ 75.21.1.0/30
              ┌──────────────────────────────────────────────┐
              │  pp-external-firewall (pfSense 2.8.1)        │ ← DMZ 172.16.8.0/24
              │  AS 65001 · eBGP peer + OSPF                 │   (pp-www)
              └──────────────────────────────────────────────┘
                       static │ 172.16.0.8/30
              ┌──────────────────────────────────────────────┐
              │  site-edge-router (VyOS, static-only)        │
              └──────────────────────────────────────────────┘
                       static │ 172.16.0.16/30 · OSPF adj
              ┌──────────────────────────────────────────────┐
              │  pp-internal-firewall (pfSense 2.8.1)        │
              │  OSPF-only (no BGP)                          │
              └──────────────────────────────────────────────┘
                       static │ 172.16.0.24/30
              ┌──────────────────────────────────────────────┐
              │  pp-internal-router (VyOS, static-only)      │ ← pp-security 172.16.9.0/24
              └──────────────────────────────────────────────┘
                  │ 172.16.0.40/30      │ 172.16.0.48/30
                  │ static              │ static
       ┌──────────────────────┐   ┌─────────────────────────────────┐
       │ pp-corp-router       │   │ pp-ot-firewall (pfSense)         │
       │ VyOS, static-only    │   │ static-only (no BGP, no OSPF)    │
       │                      │   └─────────────────────────────────┘
       │ Corp /24s:           │                │  static
       │ 172.16.2.0/24 PP-Svc │                │  192.168.200.200/30
       │ 172.16.3.0/24 BP     │   ┌─────────────────────────────────┐
       │ 172.16.4.0/24 Eng    │   │ pp-ot-router (RC_NG_OT_Router,  │
       │ 172.16.5.0/24 LS     │   │ VyOS-CLI only — vyos_routes_only)│
       │ 172.16.6.0/24 IS     │   │                                 │
       └──────────────────────┘   │ OT subnets:                     │
                                  │ 192.168.95.0/24 Gas-Turbine     │
                                  │ 192.168.90.0/27 Gas-Turbine-Sim │
                                  │ 192.168.90.96/27 PP-OT-Services │
                                  │ 192.168.90.128/27 PP-OT-DMZ     │
                                  └─────────────────────────────────┘
```

**Routing model** (verified 2026-07-06 via host_vars audit; supersedes earlier all-iBGP intent in PROJECT_LOG.md Phase 1):
- **eBGP-only-at-edge**: exactly ONE BGP session in the fabric — pp-isp-router (AS 65002) ↔ pp-external-firewall (AS 65001). Everything else in AS 65001 is BGP-free.
- **OSPF between the two upstream firewalls**: pp-external-firewall ↔ pp-internal-firewall run OSPF to exchange corp routes. pp-external-firewall carries `redistribute_ospf: true` in its `pfsense_bgp` so those corp routes propagate up to the ISP via eBGP.
- **Static everywhere else**: pp-corp-router, pp-internal-router, and site-edge-router all carry `remove_vyos_bgp: true` in host_vars — corp core is intentionally static-only. pp-ot-firewall has neither BGP nor OSPF (comment in its host_vars: "ESP boundary; default-deny, static-only"). pp-ot-router is in `[vyos_routes_only]` because its image (`RC_NG_OT_Router`) doesn't accept the base `vyos` role's interface commands — only raw static routes via `vyos_config`.
- **OT umbrella reachability**: 192.168.100.0/24 (OT domain + pp-dcs-ctrl + pp-ctl-wks-*) reaches corp via static routes at each pfSense boundary, backstopped by pp-internal-firewall's FRR-RIB.

**Management plane**: every managed host has a SimSpace-assigned IP in `10.255.240.0/20` on its first NIC (Linux/Windows host_vars eth0/Ethernet0; pfSense vmx0 — *on the 2.8.1 image*). That subnet is out-of-band — workstation→server traffic must NOT traverse it during scenario play. Two consequences:
- Windows DDNS on the mgmt adapter is disabled (`Strip mgmt interface from AD DNS registration` play); mgmt-IP A records are scrubbed from AD DNS.
- `pp-isp-router` is excluded from the syslog client play (it represents the ISP, not corp gear).

## Inventory groups (the design)

Hosts belong to multiple overlapping groups. Group meanings:

- **Platform**: `windows`, `linux` (with `ubuntu22` child), `vyos`, `vyos_routes_only`, `pfsense` — drive OS/device-specific task loading.
- **Role**: `pdc`, `additional_dc`, `domain_controllers`, `file`, `proxy`, `splunk`, `syslog`, `members`, `corporate_servers`, `dmz`, `infrastructure`, `wordpress-pv`.
- **Posture**: `ae` (attack emulation hosts — pp-dc01/02, pp-file, pp-sql, pp-mail), `aue` (attack-user-experience workstations).
- **OS version**: `win10`, `win11`, `winserver2022`, `winserver2019`.
- **Services**: `splunk-forwarder` (built via `:children`), `global_dns`, `hunt`, `voltgrid:children` (workstations + DCs + corporate_servers).
- **Special**: `unmanaged` — hard-coded; not targeted by any play. Contains OT PLCs/HMIs that come pre-configured from their image.

## Variable hierarchy (lowest → highest precedence)

1. `group_vars/all.yml` — credentials, proxy, Splunk indices, syslog/splunk server IPs.
2. `group_vars/<group>.yml` — `linux.yml`, `windows.yml`, `pfsense.yml`, `vyos_routes_only.yml`, `voltgrid.yml`, `proxy.yml`.
3. `host_vars/<host>.yml` — per-host IPs/interfaces/role-specific tuning.
4. Inline play vars in `arbitr_pp_playbook.yaml`.

Notable shared variables (defined in `group_vars/all.yml`):
- `inet_proxy_addr` / `inet_proxy_port` — corporate proxy (10.255.240.1:3128) for any `apt`/`pip`/`win_get_url` traffic.
- `splunk_server_ip` (`172.16.9.20`), `splunk_forwarder_port` (`9997`).
- `syslog_server_ip` (`172.16.2.9`) — referenced by the three syslog-client plays.
- `indices` — Splunk index declarations (linux, windows, netfw, sysmon, proxy, mail).

## Conventions specific to this overlay

1. **Customer-role workarounds live as plays, not role forks.** If a base role has a bug or gap, the preferred fix is an additional play in `arbitr_pp_playbook.yaml` that compensates after the base role runs. Only fork a role into `roles/<name>/` when the workaround can't be expressed as additional tasks (e.g., `splunk-forwarder` needed template content changes).

2. **Every overlay workaround → an UPSTREAM_FIXES.md entry, same turn it lands.** Per `~/.claude/projects/-Users-eric-starace-vCity/memory/feedback_upstream_fixes_log.md`. Standard format: `## YYYY-MM-DD · <severity> · <target path / heading>`, severity = `bug` / `gap` / `enhancement` / `platform`. Each entry has Symptom → Detection (if non-obvious) → Fix (upstream) → Workaround (overlay).

3. **php -r is the universal pfSense escape hatch.** pfsensible.core 0.7.x doesn't expose: `<defaultgw4>`, `<nat><outbound><mode>`, `<installedpackages><frr>`, `<syslog>`. All of those are driven via `ansible.builtin.shell: php -r '...'` tasks that `require_once("/etc/inc/config.inc")` and call `config_set_path()` + `write_config()`. Pattern is well-established in `roles/pfsense_firewall/tasks/main.yml`.

4. **Per-host opt-in cleanup lists.** Two parallel patterns for "delete things that shouldn't be here":
   - `extra_static_routes_remove: [{network, next_hop}]` on VyOS host_vars → driven by the `Remove stale VyOS static routes` play.
   - `pfsense_stale_gateways: ['GW_WAN', ...]` on pfSense host_vars → driven by the GW pinning task in `pfsense_firewall` role.

5. **Static-route comments cite the destination.** Every `next_hop` value gets an inline comment naming the device on the other end (e.g., `next_hop: "172.16.0.25" # pp-internal-firewall (vmx1 INTERNAL on 172.16.0.24/30)`). This single convention has prevented a known recurring bug class — confusing the local /30 IP with the peer's /30 IP and creating a self-loop default.

6. **Two ansible_user accounts, two truths**:
   - **pfSense** (`group_vars/pfsense.yml`): `admin:simspace1`. `simspace` user exists but lacks write access to `/cf/conf/config.xml` (a known pfsensible.core fallback-path issue).
   - **Linux** (`group_vars/linux.yml`): `simspace:Simspace1!` with `become: true` for root tasks.
   - **VyOS** (`group_vars/vyos_routes_only.yml` and equivalent in customer's `group_vars/vyos.yml`): `vyos:Simspace1!`.

7. **SimSpace image quirks are platform issues, not Ansible issues.** Document them in UPSTREAM_FIXES.md with severity `platform`. Workarounds go in overlay plays but don't try to "fix" the image from Ansible (e.g., the OT-pfSense:1.0.0 wizard requirement was unrecoverable from Ansible; the new pfSense 2.8.1 image fixed it at the source).

## Common pitfalls (things we kept tripping on)

These are sorted roughly by frequency-of-mistake. Read this list before debugging routing or DNS issues from scratch.

1. **VyOS image bakes self-loop default routes per /24 interface IP.** Symptom: `show ip route` has no `S>* 0.0.0.0/0` line even though host_vars declares one. FRR refuses to install a default whose next-hop resolves to a local interface. Fix: `extra_static_routes_remove` per-host. See UPSTREAM_FIXES.md 2026-05-27 entry.

2. **`next_hop` typo: own IP instead of peer's IP.** Specifically: a /30 has only two usable addresses; the next-hop should be the OTHER one. The `# pp-X-router` comments next to each next_hop value are not decoration — they exist because we lost an afternoon to `172.16.0.26` (self) vs `172.16.0.25` (firewall) on pp-internal-router's `static_route`.

3. **Windows DDNS registers BOTH adapters into AD DNS.** Customer's `common/tasks/windows.yml` has a task to disable this, but it has two bugs (typo `Ehternet0` and wrong cmdlet parameter `RegisterThisConnectionAddress` vs `RegisterThisConnectionsAddress`). Net result: `ping pp-dc01` resolves to a mgmt IP half the time. The `Strip mgmt interface from AD DNS registration` overlay play fixes this; the underlying bugs are logged in UPSTREAM_FIXES.md 2026-05-27 entry.

4. **LLMNR / NetBIOS resolution on the mgmt segment.** All Windows hosts share the 10.255.240.0/20 mgmt subnet, so cross-host name resolution can leak via LLMNR/NetBIOS even when AD DNS is correct. `ping pp-www` returns the mgmt IP because pp-www responds to LLMNR on the shared mgmt L2. The full fix (disabling LLMNR + NetBIOS on Ethernet0) is sketched in chat history but not yet wired in; the DDNS fix above usually resolves the immediate symptom.

5. **pfSense `/cf/conf/config.xml` permission denied with non-admin user.** pfsensible.core writes via temp file + rename; `/tmp` and `/cf` are separate mounts on pfSense, so the rename falls back to copy. Only `admin` can copy onto the root-owned config file. `ansible_user: admin` is mandatory — `simspace` (the other pre-provisioned user) will fail.

6. **pfSense FRR runtime dir doesn't auto-create.** `/var/run/frr/` is missing on boot; watchfrr fails with `Can't create pid lock file`. The `pfsense_firewall` role pre-creates it before `service frr onestart`. If you re-architect the FRR startup, keep this task.

7. **Ubuntu Desktop's GNOME Initial Setup wizard.** Pops "Connect Your Online Accounts" on first interactive login. Overlay drops `~/.config/gnome-initial-setup-done` for every existing user and in `/etc/skel`. Tag `gnome_initial_setup`.

8. **NIC ordering inversion between pfSense images**: The old OT-pfSense:1.0.0 image had `managementInterface.position: LAST` (mgmt on vmx3 for 4-NIC hosts). The new pfSense 2.8.1 image has mgmt on the FIRST NIC (vmx0). Anytime a pfSense `host_vars` file references `vmx0` as a data-plane interface, that's stale and needs flipping.

9. **Customer `vyos` role's `static_route` is a single dict, not a list.** A host that needs more than one static gets the first via `static_route:` and the rest via `extra_static_routes:` — driven by the `Additional VyOS static routes` overlay play.

10. **The dns role doesn't configure forwarders.** `nslookup www.voltgrid.com` works, `nslookup hbo.com` times out. The `Configure DNS forwarders to is-inet` overlay play sets them to `8.8.8.8, 8.8.4.4, 1.1.1.1` (is-inet's unbound aliases). Logged in UPSTREAM_FIXES.md 2026-05-22 entry.

## Verification recipes

After a deploy, three layers to check before declaring success.

### L1 — Routing convergence
On each VyOS router:
```
show ip bgp summary       # every neighbor State = Established
show ip route bgp         # learned prefixes from each neighbor
show ip route 0.0.0.0/0   # default route should be in FIB
```

On each pfSense:
```
vtysh -c "show ip bgp summary"
vtysh -c "show ip route bgp"
netstat -rn -f inet | awk '$1=="default"||$1~/^172|^192|^10|^75/'
```

### L2 — pfSense-specific config integrity
On each pfSense (use `sh -c` if running under tcsh):
```sh
xmllint --xpath 'string(//gateways/defaultgw4)' /cf/conf/config.xml; echo
xmllint --xpath 'string(//nat/outbound/mode)' /cf/conf/config.xml; echo
xmllint --xpath '//gateways/gateway_item/name/text()' /cf/conf/config.xml
pfctl -vsr | grep -c 'label "USER_RULE'
```

Expected per host:

| Host | `defaultgw4` | Outbound NAT | Gateways | USER_RULE count |
|---|---|---|---|---|
| pp-ot-firewall | `GW_INTERNAL` | `disabled` | `GW_INTERNAL`, `GW_OT_ROUTER` | ≥ 4 |
| pp-internal-firewall | `GW_EDGE` | `disabled` | `GW_EDGE`, `GW_INT_ROUTER` | ≥ 3 |
| pp-external-firewall | `GW_ISP` | `disabled` | `GW_ISP`, `GW_EDGE_TRANSIT` | ≥ 4 |

### L3 — End-to-end from a corp workstation
```powershell
# From pp-bp-wkstn-3 (PowerShell)
Test-NetConnection -ComputerName 172.16.8.5 -Port 80     # DMZ reachable
tracert -d 192.168.95.2                                   # OT reachable
Resolve-DnsName pp-dc01 -DnsOnly                          # AD DNS only (no LLMNR)
ping pp-dc01                                              # Resolves to 172.16.2.7, not mgmt
```

## Working with future Claude sessions

A few things that will save the next session time:

1. **Read UPSTREAM_FIXES.md before making any change to network or AD plumbing.** Half the time, the problem you're seeing has already been diagnosed there.

2. **Auto-memory lives at `~/.claude/projects/-Users-eric-starace-vCity/memory/`.** Two entries currently load: the customer-repo location pointer (`ansible_repo_reference.md`) and the "keep UPSTREAM_FIXES.md current" feedback (`feedback_upstream_fixes_log.md`). Append new feedback or project memories as discoveries warrant; don't duplicate what's already in UPSTREAM_FIXES.md.

3. **The `/code-review ultra` workflow is user-triggered and billed; don't attempt to launch it yourself.**

4. **Customer repo (`../range-development-ansible/`) has its own CLAUDE.md.** Treat that as the platform-level reference; treat this file as the range-level reference. Edits to base roles live in the customer repo; edits to range vars / plays live here.

5. **Don't touch base roles directly to fix bugs.** Add an overlay role with the same name (build_tarball.sh prefers `./roles/<name>` over `../range-development-ansible/roles/<name>`), OR add a compensating play in `arbitr_pp_playbook.yaml`. Either way, log an UPSTREAM_FIXES.md entry naming the original file and proposing the upstream fix.

6. **For routing changes**: always confirm the FIB matches the configured intent (`show ip route` on VyOS, `netstat -rn` or `vtysh -c "show ip route"` on pfSense). "The config has the line" is not the same as "the kernel installed the route." Multiple equal-cost statics, image-baked junk routes, and self-loop next-hops all cause FRR to silently drop routes from the FIB.

7. **For Windows changes**: pre-existing GPOs, DDNS auto-registration, LLMNR/NetBIOS fallback, and the mgmt subnet being on every host all conspire to produce surprising name-resolution behavior. `Resolve-DnsName -DnsOnly` is the gold-standard test; `ping` and `nslookup` each have their own footguns.

8. **For pfSense**: `pfctl -vsr`, `xmllint --xpath '//path' /cf/conf/config.xml`, `vtysh`, and `php -r` are the four tools you need. The webConfigurator GUI is a crutch — every change should ultimately be expressible as one of those four.

## Useful filesystem locations on a deployed Ansible host

```
/etc/ansible/                          ← extracted tarball lives here
/etc/ansible/arbitr_pp_playbook.yaml
/etc/ansible/hosts
/etc/ansible/{host_vars,group_vars,roles}/
/etc/ansible/deploy.sh
/etc/ansible/files/                    ← pre-staged installers (if any)
~/.ansible/ansible.log                  ← per-run log
~/.ansible/retry/                       ← failure retry hostlists
/home/simspace/.vault_pass              ← vault password (customer convention)
```

## Recipes — common changes

**Add a new firewall rule on every pfSense**: append to each host_vars' `pfsense_rules:`. No role change needed.

**Add a static route on a VyOS host**: add to `extra_static_routes:` in the host's host_vars; the `Additional VyOS static routes` play picks it up via tag `extra_static_routes`.

**Strip a stale static route on VyOS**: add to `extra_static_routes_remove:`; tag `extra_static_routes_remove`.

**Add a new DNS record**: append to `group_vars/voltgrid.yml`'s `internal_dns_records:`. Run the `dns` play (`--tags dns`) to apply.

**Add a new Linux host**: create `host_vars/<name>.yml` with `ansible_host`, `network_interfaces`, add to `[ubuntu22]` and any service groups in `hosts`. The Linux pre-config play picks up NM management automatically.

**Add a new SimSpace Splunk index**: append to `group_vars/all.yml`'s `indices:` and run `--tags splunk`.

**Forward a new device's syslog to pp-syslog**: VyOS / pfSense are already covered by the platform-targeted plays. For a new Linux host, just adding it to `[linux]` automatically triggers the `Syslog client — Linux` play (excludes `[syslog]` itself).

**Rebuild the tarball**: `./build_tarball.sh`. Check the WARN section at the bottom for unresolved Jinja vars before shipping.

## Last-known-good state (as of the most recent session)

- Three pfSense firewalls (pp-ot-firewall, pp-internal-firewall, pp-external-firewall) on pfSense 2.8.1 image — auth working with `admin:simspace1`, FRR runtime dir creation fix landed but full FRR convergence pending verification.
- Routing model: eBGP-only-at-edge (pp-isp-router AS 65002 ↔ pp-external-firewall AS 65001), OSPF between the two upstream firewalls, STATIC everywhere else (all VyOS corp routers carry `remove_vyos_bgp: true`; pp-ot-firewall has neither BGP nor OSPF). Verified against host_vars 2026-07-06.
- Syslog collection wired end-to-end (Linux → rsyslog forwarder; VyOS → `set system syslog host`; pfSense → `<syslog>` block via php -r) into pp-syslog → Splunk UF → `netfw` index.
- GNOME initial-setup wizard suppressed on Linux desktops.
- DDNS mgmt-IP leakage stripped from AD DNS.
- Image-baked stale static defaults on VyOS routers cleaned up via `extra_static_routes_remove`.

If something on this list doesn't match what you see in a fresh deploy, the most likely cause is an upstream change in the customer repo or a new SimSpace image revision — check UPSTREAM_FIXES.md tail for new entries before re-deriving.
