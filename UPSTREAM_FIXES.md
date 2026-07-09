# Upstream Fixes & Enhancements — range-development-ansible

Running log of issues, gaps, and suggested improvements discovered while deploying `ss-pp-ab`. Candidates for PRs or discussion with the `range-development-ansible` maintainers.

Severity key:
- **bug** — role malfunctions or produces incorrect results
- **gap** — missing functionality that ranges have to work around
- **enhancement** — works but could be more robust or ergonomic

---

## 2026-07-09 · bug · roles/is_inet_fix (back-ported from airfield-range) — eth1 provisioning + unbound supervisor

**Landed on branch `is-inet-persistence` (not main). Reviewer approval needed before merging.**

**Symptom.** On the 2026-05-22 entry below we documented that the RC-IS-INET image brings eth1 up as `/32` with no default gateway, and noted that a durable fix would be "a small `is_inet_fix` role (planned)". Airfield-range hit the same wall on 2026-07-08 plus a second latent issue: the container's entrypoint doesn't launch unbound at all. The `reload unbound` handler in `range-development-ansible/roles/handlers/` uses `ignore_errors: yes`, so PowerPlant deploys silently succeed even though corp DNS to 8.8.8.8 never actually reaches unbound.

**Fix (overlay, back-ported).** Copied `roles/is_inet_fix/` verbatim from airfield-range 2026-07-08. Deploys:
1. Netplan drop-in at `/etc/netplan/99-airfield-eth1.yaml` — corrects the /32 → /24 mask + adds default gateway (200.200.200.1 = pp-isp-router). Values driven from `host_vars/is-inet.yml` (`isinet_dataplane_ip`, `_prefix`, `_gateway`).
2. Systemd oneshot + timer at `/etc/systemd/system/airfield-unbound-supervise.{service,timer}` — checks whether unbound is listening in the container, starts it via `docker exec -d is-inet /usr/sbin/unbound` if not. Also creates `/var/log/unbound.log` with `unbound:unbound` ownership (the image doesn't ship it, and unbound aborts at start "Could not open logfile"). Re-runs every 60 seconds so container restarts self-heal.

Wired into `arbitr_pp_playbook.yaml` as a new play immediately before `global_dns`, tagged `is_inet_fix` and `is_inet`.

**Also back-ported.** Extended `roles/global_dns/templates/simspace_includes.conf.j2` to emit `local-zone: "<zone>." transparent` for every unique zone at the top of the file. This defeats the `redirect` zones the corpora ships that would otherwise abort unbound at startup with "local-data in redirect zone must reside at top of zone." Airfield hit this because global_dns_records includes github.com / google.com etc. PowerPlant's records (voltgrid.com, outlook.com) may not currently collide, but the safety net costs nothing.

**Fix (upstream / platform).** Same as the 2026-05-22 entry (SimSpace image should honor YAML-declared prefix + gateway), plus:
- Container image should either bake `/var/log/unbound.log` with unbound-user ownership OR extend entrypoint to launch unbound.
- Customer `reload unbound` handler should NOT swallow errors with `ignore_errors: yes`; masks the "unbound never actually running" state.

**Review notes for main merge.** The `roles/is_inet_fix/` scripts hard-code `is-inet` as the container name (matches this range's `global_dns_container_name`). If PowerPlant ever renames it, parametrize via a role default. Otherwise the role is drop-in.

---

## 2026-07-06 · gap · roles/syslog_server/templates — pfSense sources land in IP-named dirs, not hostname-named

**Symptom.** `verify_deployment.sh` Section 6 flagged the 3 pfSense firewalls as not forwarding syslog. Investigation confirmed they ARE forwarding (packets caught via tcpdump on pp-syslog; matching per-source directories exist under `/var/log/remote/`) — but the directories are named by **source IP**, not hostname:
```
/var/log/remote/172.16.0.9/    <- pp-external-firewall
/var/log/remote/172.16.0.25/   <- pp-internal-firewall
/var/log/remote/172.16.0.50/   <- pp-ot-firewall
/var/log/remote/pp-corp-router/     <- VyOS routers land under hostname
/var/log/remote/pp-internal-router/
...
```
Any downstream tooling that expects `/var/log/remote/<hostname>/` for pfSense sources (Splunk inputs, ad-hoc grep, verify_deployment.sh) breaks.

**Root cause.** pfSense's built-in `syslogd` doesn't fill in the syslog HOSTNAME field the way modern rsyslog senders do (or fills it with something like `pfSense`, not the FQDN). The `syslog_server` role's rsyslog template on pp-syslog uses `%HOSTNAME%` for the directory name, which resolves to the source IP when the header field is missing or generic. Result: 3 IP-named dirs plus 6 hostname-named dirs on the same box.

**Fix (upstream).** Change the rsyslog template on the syslog collector to prefer `%FROMHOST-IP% ↔ hostname` reverse resolution before falling back to raw `%HOSTNAME%`. Two options:
1. Static map in the rsyslog config: `set $.friendlyname = re_extract($fromhost-ip, "^172\\.16\\.0\\.9$", 0, 0, "pp-external-firewall") ; ...` — brittle but explicit.
2. Reverse DNS: rsyslog's `%FROMHOST%` property does PTR resolution if the collector has the AD DNS forwarders + PTR zones populated. Cheapest fix, but requires PTR records for the transit /30 addresses (`172.16.0.9`, `172.16.0.25`, `172.16.0.50`) — currently only production /24 hosts have PTRs.

Option 2 is preferred because it's declarative and works for any future pfSense/appliance sources without a template edit. Would need to add PTR records for the /30 links in `internal_dns_records` (group_vars/voltgrid.yml).

**Workaround (overlay).** `verify_deployment.sh` Section 6 hardcodes the IP-based dir names for the 3 pfSense firewalls. If firewall count or link addressing changes, update the mapping in the script.

---

## 2026-07-03 · gap · roles/domain_member_retry/tasks/main.yml — `pause` incompatible with `strategy: free`

**Symptom.** With the Join Domain play set to `strategy: free` (added on 2026-07-02 as a wall-clock optimization for per-host reboots), the deploy fails immediately after the first host's "Check if already domain joined" task:
```
ERROR! The 'pause' module bypasses the host loop, which is currently not supported in the free strategy and would instead execute for every host in the inventory list.
The offending line appears to be:
    - name: Wait for network reconfiguration to complete
```
All 3 deploy.sh attempts fail identically before any host actually joins.

**Root cause.** `domain_member_retry/tasks/main.yml:22` uses `ansible.builtin.pause` to wait for the post-join NIC flap to settle. Ansible's `free` strategy explicitly rejects `pause` because pause is a per-play blocker, not per-host — under free, it would either block all hosts (defeating the point) or fire N times per host (nonsense). Ansible chose to hard-fail the play rather than pick either behavior.

**Fix (overlay).** Reverted `strategy: free` on just the Join Domain play in `arbitr_pp_playbook.yaml`. The other 5 plays that got `strategy: free` (strip_apipa, root_certs, network_discovery, AUE bundle, AE bundle) keep the speedup — none of them use `pause`.

**Fix (upstream).** In `domain_member_retry/tasks/main.yml`, replace `pause: seconds: N` with a delegated `wait_for` on the local Ansible controller, e.g.:
```yaml
- name: Wait for network reconfiguration to complete
  ansible.builtin.wait_for:
    timeout: 30
  delegate_to: localhost
  become: false
```
`wait_for` (unlike `pause`) works under `strategy: free`. This would let the Join Domain play — the single slowest play in the deploy — parallelize like the others.

---

## 2026-07-02 · bug · roles/pfsense_firewall/handlers/main.yml — FRR handler smushes bgpd/ospfd launches

**Symptom.** On a fresh-range deploy the pfsense_firewall role's `restart frr` handler fails on any pfSense host that defines BOTH `pfsense_bgp` and `pfsense_ospf` in host_vars (currently `pp-external-firewall`). stderr from the handler shell:
```
-A option specified more than once!
Invalid options.
Usage: bgpd [OPTION...]
```
FRR never comes up → OSPF adjacencies never form → pp-external-firewall doesn't advertise the WAN default via OSPF → corp side loses upstream + DNS forwarders → domain joins fail on `pp-ctl-wks-*` and `pp-dcs-ctrl` + additional DC promotion fails on `pp-dc03` → the whole deploy cascades.

**Root cause.** The handler had the two conditional launch lines inlined:
```
{% if pfsense_bgp is defined %}/usr/local/sbin/bgpd -d -A 127.0.0.1 -f /var/etc/frr/frr.conf{% endif %}
{% if pfsense_ospf is defined %}/usr/local/sbin/ospfd -d -A 127.0.0.1 -f /var/etc/frr/frr.conf{% endif %}
```
Jinja's `trim_blocks` (default in Ansible) strips the newline after the `{% endif %}` on the first line. The bgpd and ospfd invocations end up concatenated on a single shell line: `/usr/local/sbin/bgpd -d -A 127.0.0.1 -f /var/etc/frr/frr.conf/usr/local/sbin/ospfd -d -A 127.0.0.1 -f /var/etc/frr/frr.conf`. bgpd sees two `-A 127.0.0.1` args (one from its own line, one from the smushed ospfd line) and rejects them as "specified more than once".

**Fix (overlay).** Put each `{% if %}`, the launch command, and `{% endif %}` on their own line so `trim_blocks` only eats the newlines around the block tags and leaves the command's terminating newline intact. Same fix landed on 2026-06-25 in the mirror airfield-range repo — this repo missed it since they're separate git repos.

**Fix (upstream).** File issue against range-development-ansible with the same patch. The handler template pattern is used in other roles too and should get a consistent trim_blocks-safe convention (each Jinja block tag on its own line).

---

## 2026-07-02 · gap · roles/global_dns/templates/simspace_includes.conf.j2 — no zone-apex A record support

**Symptom.** Cannot add a bare-domain A record to `global_dns_records` (e.g. `voltgrid.com A 200.200.200.2`) because the base template unconditionally concatenates `record.name + "." + record.zone`, producing invalid `.voltgrid.com. A ...` output when name is empty or `@`.

**Root cause.** All record-type branches in `simspace_includes.conf.j2` treat `record.name` as a mandatory subdomain label. There's no handling for the zone-apex case.

**Impact.** Any range that wants "user@voltgrid.com" style webmail login can't easily do it — the `email` role uses `email_domains[].name` as (a) cert CN/SAN, (b) webmail login domain, and (c) `imap_host` inside the container. Setting that to `voltgrid.com` means the container has to resolve `voltgrid.com` to an IP where Dovecot listens (is-inet primary address). Without a zone-apex A record, resolution fails and webmail login errors with "Can't connect to server."

**Fix (upstream).** Add zone-apex handling in the A-record block, e.g.:
```jinja
{% set _apex = (record.name | default('') in ['', '@']) %}
{% if _apex %}
local-data: "{{ record.zone | default(domain_name) }}. A {{ record.value }}"
local-data-ptr: "{{ record.value }} {{ record.zone | default(domain_name) }}."
{% else %}
local-data: "{{ record.name }}.{{ record.zone | default(domain_name) }}. A {{ record.value }}"
local-data-ptr: "{{ record.value }} {{ record.name }}.{{ record.zone | default(domain_name) }}."
{% endif %}
```

**Fix (overlay).** Forked into `ss-pp-ab/roles/global_dns/` with the zone-apex patch above. Range's `global_dns_records` gains two apex entries: `voltgrid.com → 200.200.200.2` and `outlook.com → 52.96.223.2`. Then `email_domains` in group_vars/all.yml switches from `mail.<domain>` to bare `<domain>`, so the email role's generated ini/certs use bare-domain names and RainLoop login accepts `bob.burke@voltgrid.com`.

---

## 2026-07-02 · platform · pfSense data-plane dhclient poisons zebra route installation

**Symptom.** On fresh-range deploys, Windows hosts behind pp-ot-firewall (specifically pp-dc03, pp-ctl-wks-01..04, pp-dcs-ctrl — all on the new 192.168.100.0/24 OT subnet from blueprint 145) intermittently fail domain join with "The specified domain either does not exist or could not be contacted." Retry gets partial success (some hosts join on attempt 3, others still fail with different WinRM errors). Signature is flaky routing, not hard config break. pp-dc03 additional-DC promotion fails with "AD domain controller for voltgrid.com could not be contacted."

**Root cause.** SimSpace's pfSense 2.8.1 image (`RC_pfSense:1.0.0`) auto-spawns `dhclient` on every `vmxN` data-plane interface at boot, regardless of whether config.xml declares the interface as `ipv4_type=static`. dhclient transiently acquires DHCP leases from SimSpace backend platform networks (10.41.240.x, 192.168.1.x observed) before pfSense's `interface_configure()` sets the intended static. Zebra reads the connected-route table during its startup and records those transient subnets as `C>*`. Zebra then silently refuses to install OSPF/BGP-learned routes via that interface — FRR RIB shows `O>*` / `B>*` (selected + installed marker), but `netstat -rn` doesn't have them and `route get` returns "not found." Full root-cause writeup in airfield-range's UPSTREAM_FIXES.md 2026-06-30 entry.

**Fix (upstream).** SimSpace's pfSense image should either (a) set data-plane interfaces to `ipv4_type=staticv4` at the `rc.conf` level so dhclient never spawns on them, or (b) have pfSense's `interface_configure()` explicitly `pkill -f "dhclient.*<phys>"` when transitioning an interface from DHCP → static.

**Fix (overlay).** `roles/pfsense_firewall/tasks/main.yml` gains a standalone `pkill -f 'dhclient.*vmx[1-9]'` task placed AFTER the post-flight interface rebind and BEFORE `meta: flush_handlers` (which triggers the `restart frr` handler). Net effect: when zebra restarts, dhclient is dead on every vmx1+ interface, connected-route view is clean, and OSPF/BGP route installation works. Kill uses `ansible.builtin.command` (not `shell`) — the multi-line shell variant was seen to get SIGTERM'd on pfSense 2.8.1 when watchfrr/sysrc cascaded a kill to adjacent shell descendants (see airfield UPSTREAM_FIXES.md 2026-07-01). `failed_when: false` absorbs pkill's rc=1 idempotent no-op.

Same fix landed in airfield-range's `pfsense_firewall` role 2026-06-30 and permanently unblocked Eng+SOC domain joins there. Porting to ss-pp-ab because the failure signature on 192.168.100.0/24 (partial success on retry) matches airfield's exactly.

---

## 2026-04-17 · bug · roles/common/tasks/windows.yml

Typo: line 56 has `Ehternet0` instead of `Ethernet0` in the "Disable control net DNS registration" loop.

```yaml
loop:
  - Ehternet0   # typo — never matches an actual adapter
  - Ethernet2
```

**Fix:** correct the spelling and align with the interface names used elsewhere in the role.

---

## 2026-04-17 · enhancement · roles/common/tasks/windows.yml

The "Disable control net DNS registration" task hardcodes adapter names (`Ehternet0`, `Ethernet2`) while the IP/gateway/DNS tasks above it iterate dynamically over `network_interfaces`. Hosts whose adapters are named `Ethernet0`/`Ethernet1` (SimSpace's default pattern in current images) have the DNS-registration step silently fail to match.

**Fix:** replace the hardcoded list with a loop over `network_interfaces`, taking the `.name` attribute:
```yaml
loop: "{{ network_interfaces | map(attribute='name') | list }}"
```

---

## 2026-04-20 · gap · roles/common/tasks/windows.yml

After `xIPAddress` applies a static IP, Windows' IPv4 Autoconfiguration feature (separate from DHCP) can assign an APIPA address (`169.254.x.x`) alongside the static during interface startup. Windows sometimes selects the APIPA as source address for outbound traffic, breaking cross-subnet routing. Observed on the `.2` workstation in every subnet during PowerPlant deploy — domain join failed with "The specified domain either does not exist or could not be contacted."

Simply removing the 169.254 address is insufficient: after any reboot, autoconfig re-assigns a new one. The permanent fix is to disable autoconfig globally via registry.

**Fix:** add a preflight block that disables IPv4 autoconfiguration (reboot required, once per host), then cleans any stale APIPA addresses that already exist:
```yaml
- name: Disable IPv4 autoconfiguration globally (prevents APIPA fallback)
  ansible.windows.win_regedit:
    path: HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters
    name: IPAutoconfigurationEnabled
    data: 0
    type: dword
    state: present
  register: autoconf_reg

- name: Reboot if autoconfig setting changed
  ansible.windows.win_reboot:
    reboot_timeout: 600
  when: autoconf_reg.changed

- name: Remove APIPA addresses on configured interfaces
  ansible.windows.win_powershell:
    script: |
      Get-NetIPAddress -InterfaceAlias "{{ item.name }}" -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object IPAddress -Like '169.254.*' |
          Remove-NetIPAddress -Confirm:$false
  loop: "{{ network_interfaces }}"
```

---

## 2026-04-20 · gap · roles/common/tasks/windows.yml

`xIPAddress` fails with a cryptic "Not found" error (from CIM) on hosts where DHCP is still enabled on the target interface. Observed on `win-hunt-1` running image `RDP_Windows_10:1.1.0`; did not occur on image `1.0.6` hosts because DHCP was off by default there.

**Fix:** add a preflight task to explicitly disable DHCP before `xIPAddress` runs:
```yaml
- name: Disable DHCP on target interfaces before static IP assignment
  ansible.windows.win_shell: "Set-NetIPInterface -InterfaceAlias '{{ item.name }}' -Dhcp Disabled"
  loop: "{{ network_interfaces }}"
```

---

## 2026-04-17 · bug · roles/group_assignment/

Role is structurally invalid. `main.yml` sits at the role root (instead of `tasks/main.yml`) and its contents are in standalone-playbook format (`- name: ...; hosts: pdc; tasks: [...]`) rather than a task list. When included via `roles: - group_assignment`, Ansible loads nothing — the role is effectively a no-op. The parent `create_users/tasks/main.yml` already performs group assignment internally, so listing both roles in the reference playbook is misleading.

**Fix:** either
- (a) move tasks into `tasks/main.yml` as a task list and remove the duplication from `create_users`, or
- (b) delete the `group_assignment` role and its references throughout the repo.

---

## 2026-04-17 · gap · roles/dcpromo/ (no sibling role)

`dcpromo` promotes a Windows Server to be the **primary** DC of a new forest via `microsoft.ad.domain`. There is no sibling role for promoting an **additional** DC into an existing domain. When a range needs two DCs in one domain, the project has to author its own role — as `ss-pp-ab/roles/additional_dc/` does, using `microsoft.ad.domain_controller`.

**Fix:** add an `additional_dc` role to the shared repo so multi-DC ranges don't each reinvent it. Document the primary/additional pattern in the READMEs.

---

## 2026-04-17 · enhancement · deploy.sh

Retry loop treats every non-zero Ansible exit code as a retry signal, including legitimate task failures and parse errors. It also re-runs transparently on exit code `3` (unreachable host) — which is often transient and worth retrying, but indistinguishable from code `2` (task failed) in current logic. End result: every deploy with at least one Ansible-unmanaged host (PLCs, HMIs, phones, etc.) always goes through three attempts, then exits 1, confusing operators who see "Attempt 3 failed" despite no real failure.

**Fix:** switch on the exit code — retry only on `3`, treat `0` as success, and bail fast on `≥1 && !=3`:
```bash
ansible-playbook "$PLAYBOOK" "$@"
rc=$?
case $rc in
  0) echo "Success on attempt $i"; break ;;
  3) echo "Unreachable host on attempt $i — retrying" ;;
  *) echo "Non-retryable failure (exit $rc)"; exit $rc ;;
esac
```

---

## 2026-05-07 · gap · roles/common/tasks/windows.yml

**PowerPlant status (2026-05-11): resolved by host migration.** `pp-mail` and `pp-dmz-smtp` were re-imaged from Server 2012 R2 to Server 2019 (which has TLS 1.2 default-on). No Server 2012 hosts remain in this range. The `enable_tls12` and `prestage_range_agent` overlay roles, and their plays, have been removed. The upstream fix remains worth doing for future ranges that need Server 2012 hosts.

---

The `range-agent-bootstrap using win_get_url with proxy settings` task fails on Windows Server 2012 with `"The request was aborted: Could not create SSL/TLS secure channel"`. Server 2012's .NET 4 / WinHTTP defaults to TLS 1.0 / SSL 3.0; the customer Nexus only accepts TLS 1.2. Server 2022 has TLS 1.2 default-on and is unaffected. Observed on `pp-mail` and `pp-dmz-smtp` in the PowerPlant deploy.

**Fix:** add a Server 2012-aware preflight in `common` (or a sibling role). Note: `SchUseStrongCrypto` *alone* is NOT sufficient — Server 2012 SChannel refuses TLS 1.2 unless the protocol-specific keys are explicitly enabled. The full minimum set is:

```
# 1. Enable TLS 1.2 in SChannel itself
HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client\Enabled = 1
HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client\DisabledByDefault = 0
HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server\Enabled = 1
HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server\DisabledByDefault = 0

# 2. Force .NET 4.x to use system-default TLS (now includes 1.2)
HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto = 1
HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\SystemDefaultTlsVersions = 1
HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto = 1
HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319\SystemDefaultTlsVersions = 1

# 3. Force .NET 2.0/3.5 to use strong crypto
HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727\SchUseStrongCrypto = 1
HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v2.0.50727\SchUseStrongCrypto = 1

# 4. Force WinHTTP DefaultSecureProtocols to TLS 1.1+1.2 (0x00000A00)
HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp\DefaultSecureProtocols = 0x00000A00
HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp\DefaultSecureProtocols = 0x00000A00
```

A reboot is required after the SChannel keys change. Could be conditional on `ansible_facts['distribution_version']` so it's a no-op on Server 2022. Implementation in PowerPlant overlay: `ss-pp-ab/roles/enable_tls12/`.

**Update 2026-05-08:** even with the full prescription above applied (registry verified post-reboot on Server 2012 R2 / build 6.3.9600), `win_get_url` against Nexus still fails with `Could not create SSL/TLS secure channel`. Reproduced both via `win_get_url` and via direct `System.Net.WebClient.DownloadFile()` in PowerShell with `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12` set explicitly in the session. Cipher-suite enumeration (`Get-TlsCipherSuite`) isn't available on 2012 R2 to confirm a cipher-suite mismatch with Nexus, but the symptom is consistent with one. **Workaround:** pre-install the MSI via `win_copy` from the Ansible controller before `common` runs — its `Check if RangeAgent Service Exists` then returns `True` and the failing download is skipped. Implemented as `ss-pp-ab/roles/prestage_range_agent/` in the PowerPlant overlay.

**Suggested upstream improvement:** the `common` role's `range-agent-bootstrap` task pair should support a `range_agent_bootstrap_local_path` variable that, when set, copies a controller-local MSI via `win_copy` instead of attempting `win_get_url`. Defaults to current behavior; opt-in for problem hosts.

**Update 2026-05-11:** the same TLS-to-Nexus failure recurs in **every** role that does `win_get_url` against Nexus on Server 2012 R2 — confirmed on `aue_agent` (`aue-agent-latest-setup-x86_64.exe`). Pre-staging is a workable per-role workaround (proven for `range-agent-bootstrap`) but requires authoring a parallel install pipeline and a local override of the upstream role for every affected installer. In PowerPlant we chose to **exclude pp-mail from `[ae]`** rather than carry that infrastructure for a single host whose mail-server use case doesn't need user-activity simulation. If more Server 2012 R2 hosts join `[ae]`/`[aue]` later, the prestage pattern (see `prestage_range_agent`) is the precedent. The cleaner upstream fix remains: add a `<role>_local_path` opt-in variable on each download role, or add a generic "use the local copy if `<playbook_dir>/files/<filename>` exists" preflight before any `win_get_url`.

---

## 2026-05-08 · platform · SimSpace subnet IP reservation

The `.2` IP of every workstation subnet appears to be silently reserved by a SimSpace-managed VM (likely a platform service — agent / telemetry / control plane). Symptom: any range-author-assigned VM at `<subnet>.2` boots, applies its static IP, and Windows DAD immediately marks the address `Duplicate` because something else on the L2 segment is already responding to ARP for it. The colliding VM has a different MAC OUI byte (`00:50:56:98:xx:xx`) than the user-template VMs (`00:50:56:a8:xx:xx`), so it's a distinct VM — not just the workstation's own duplicate.

Effects on a host that gets stuck in `Duplicate`:
- Connected route for the subnet is never installed (`Get-NetRoute` empty for that subnet)
- `Find-NetRoute` fails with `Windows System Error 1232: The network location cannot be reached`
- Outbound ARP requests don't fire — host can't even reach its own gateway, can't join the domain
- Inbound to `<subnet>.2` works because the *other* device responds, masking the issue

Reproduced on PowerPlant for `172.16.3.2`, `172.16.4.2`, `172.16.5.2`, `172.16.6.2` — exactly the four subnets where range authors had assigned the first workstation to `.2`.

**Fix (range author side):** never assign user VMs to `<subnet>.2`. Skip to `.3` or `.10`+. Worked around in PowerPlant by re-IPing `pp-bp-wkstn-1`, `pp-eng-wkstn-1`, `pp-ls-wkstn-1`, `pp-is-wkstn-1` to `.10` (2026-05-08), and `pp-mail` from `172.16.2.2` → `172.16.2.5` (2026-05-11). The reservation applies to **server subnets as well** (PP-Services 172.16.2.0/24), not just workstation subnets.

**Fix (SimSpace side):** document the reservation in their range-author guide; or better, surface a YAML-validation warning when a `VmInstance.networkInterfaces[].ipAddress` lands on `.2`.

---

## 2026-04-23 · platform · range YAML / SimSpace

VyOS-image VMs (`RC-VyOS-Router`, `RC-VyOS-Firewall`) need `managementInterface.position: "LAST"` to wire data-plane vNICs to their target subnets at the hypervisor level. The default `"FIRST"` (which works for Windows/Linux end-host VMs) leaves VyOS data-plane vNICs unbound — the VM has the right IPs configured but ARP and ICMP fail because the vNICs aren't actually on the target vSwitches.

Symptom: VyOS routers show interfaces "u/u" with correct IPs, but `ping` to directly-connected peers returns `Destination Host Unreachable` and ARP table entries stay `FAILED`. Workstation-to-workstation L2 within the same subnet works fine, confirming end-host vNICs are correct. Reproduced across all three VyOS routers in the PowerPlant range.

**Fix:** range-design template / linter should default `position: "LAST"` for any VmInstance whose image starts with `RC-VyOS-`. Or, in the SimSpace platform itself, change the default vNIC binding behavior for VyOS images. Workaround: range authors must remember to set `position: "LAST"` on every VyOS device manually.

---

## 2026-04-22 · bug · roles/vyos/tasks/main.yml

Two variable-name / shape mismatches between the role code and the role README:

**1. `source_nat` vs `nat`** — README documents NAT config under `source_nat:` with fields `rule`, `source_address`, `outbound_interface`, `translation_address`. The role code reads from variable `nat:` with fields `source` (rule #), `address`, `outbound_interface`. Result: users following the README silently get no NAT configured.

**2. `static_route` shape** — README shows `static_route` as a list of routes (`- route: ... next_hop: ...`). The role code treats it as a single dict: `{{ static_route.route }}`. The `when: static_route.route is defined` never matches a list, so the task silently skips. Users who follow the README get no static routes.

**Fix:** either rewrite the tasks to match the README (recommended), or rewrite the README to match the tasks. Tasks-match-README would look like:

```yaml
- name: Configure static routes
  vyos.vyos.vyos_config:
    match: line
    lines:
      - "set protocols static route {{ item.route }} next-hop {{ item.next_hop }}"
    save: true
  with_items: "{{ static_route | default([]) }}"
  when: item.route is defined

- name: Configure Source NAT
  vyos.vyos.vyos_config:
    match: line
    lines:
      - "set nat source rule {{ item.rule }} source address {{ item.source_address }}"
      - "set nat source rule {{ item.rule }} translation address {{ item.translation_address }}"
      - "set nat source rule {{ item.rule }} outbound-interface name {{ item.outbound_interface }}"
    save: true
  with_items: "{{ source_nat | default([]) }}"
```

---

## 2026-04-22 · bug · roles/vyos/tasks/main.yml

Interface configuration uses `vyos.vyos.vyos_config` with `match: line`, which only appends missing lines — it never removes outdated ones. If a VyOS device's `network_interfaces` is ever changed (renumbered, re-IP'd), re-running the role **adds** the new addresses on top of the old ones, leaving multiple IPs per interface and broken routing.

Observed in PowerPlant during the initial VyOS deploy: host_vars assumed `eth0` = management and data-plane started at `eth1`. In fact, SimSpace's `managementInterface.position: "FIRST"` means management is assigned as a *secondary* IP on `eth0`, so data-plane starts at `eth0`. The corrected host_vars pushed (for example on pp-corp-router) `172.16.2.1/24` onto `eth0` — which was correct — but when originally mis-numbered, pushed it onto `eth1` on top of `172.16.3.1/24`. The wrong address now persists on `eth1` until manually deleted.

**Fix:** before adding interface addresses, delete all existing user-assigned addresses on the target interfaces. Rough shape:
```yaml
- name: Gather current addresses on interfaces we manage
  vyos.vyos.vyos_command:
    commands: "show interfaces ethernet {{ item.name }} brief"
  with_items: "{{ network_interfaces }}"
  register: current_addrs

# Delete any address on these interfaces not in the target list, then set desired.
```
Or, document clearly in the README that the role is not safe to re-run after any interface/IP change without first doing a manual `delete interfaces ethernet ethX address …` pass.

---

## 2026-05-13 · bug · roles/common — Linux interface naming contract

The role's README example shows `network_interfaces[].name: "Ethernet0"` for Linux hosts, but stock Ubuntu 22 images on SimSpace name kernel devices `eth0`/`eth1` (no rename udev rule). The `community.general.nmcli` task binds `ifname: "{{ item.name }}"` — so on Linux it creates connection profiles bound to non-existent devices that *silently* fail to activate. The mgmt NIC happened to come up via DHCP from the SimSpace platform with the desired IP, masking the bug, while the data-plane NIC pulled a random `.4` lease from VyOS-side DHCP.

Symptoms in PowerPlant: pp-splunk console showed `eth1` at `172.16.9.4` instead of host_vars-configured `172.16.9.20`; `nmcli con show` listed `Ethernet0`/`Ethernet1` profiles with empty `DEVICE` columns. Reproduced on every Linux host (pp-splunk, pp-www, pp-proxy, pp-syslog, pp-is-wkstn-4 when it was Ubuntu) until host_vars were rewritten to use `eth0`/`eth1`.

**Fix:** either (a) document in the README that Linux hosts should use kernel-default names (`eth0`/`eth1`) while Windows hosts continue to use `Ethernet0`/`Ethernet1`, or (b) have the `common` role discover the real interface (by MAC or PCI position) and rename it to the configured value before the `nmcli` task. PowerPlant overlay went with (a) — host_vars on `pp-splunk`, `pp-www`, `pp-proxy`, `pp-syslog`, and `pp-is-wkstn-4` (when it was Linux) all use `eth*`.

---

## 2026-05-13 · gap · roles/common/tasks/linux.yml

The role drops `files/99-netcfg-vmware.yaml` with `renderer: NetworkManager` and an empty `ethernets:` block. Netplan then generates `/run/NetworkManager/conf.d/10-globally-managed-devices.conf` containing `unmanaged-devices=*` (effectively "manage nothing"), so NetworkManager refuses to activate any nmcli-created connection profile. `nmcli con up eth1` returns `Connection activation failed: No suitable device found (device is strictly unmanaged)`.

Worked around in PowerPlant by adding a `Linux NM managed-devices pre-config` play before `Common Role` that drops `/etc/NetworkManager/conf.d/99-pp-eth-managed.conf` with `[keyfile] unmanaged-devices=` (blank) and a `[device-eth-managed] match-device=interface-name:eth* managed=true` block, plus a runtime `nmcli device set eth* managed yes` as belt-and-suspenders.

**Fix:** either drop a managed-devices opt-in conf as part of the `common` role on Linux hosts, or list the relevant interfaces under `netplan.ethernets:` (which would make netplan whitelist them rather than blacklist all).

---

## 2026-05-13 · bug · roles/splunk/tasks/main.yml

`Create Indices` task loops over `indices` with `loop: "{{ indices }}"` and accesses `item.name` in both the condition and the `splunk add index` command. The role's README example shows `indices` as a list of `- name: "..."` dicts, but ranges following more concise YAML conventions (or copying from the simpler `splunk_user`/`admin_users` shapes nearby) easily land on a flat list of strings. Result: `error while evaluating conditional 'item.name not in existing_indices.stdout_lines': 'str object' has no attribute 'name'`.

**Fix:** either (a) coerce strings to dicts at the top of the task (`indices: "{{ indices | map('default', {}) | ... }}"` style normalisation) so both shapes work, or (b) tighten the README to make the dict requirement loud — current example is buried in a long YAML block. PowerPlant resolved by switching `group_vars/all.yml` to the dict form.

---

## 2026-05-18 · bug · roles/splunk-forwarder/templates/inputs.conf.j2

Every `[WinEventLog://...]` stanza in `templates/inputs.conf.j2` hardcodes `index = windows`. `lin_inputs.conf.j2` hardcodes `index = linux` (and `index = main` for the wordpress-pv docker-monitor branch). The `splunk` role's `Create Indices` task creates whatever index names appear in `indices` — but if the range author picks different names (e.g. `wineventlog`, `sysmon` split-out), Splunk silently drops every event because the destination index doesn't exist. Diagnosed in PowerPlant after `| metadata type=hosts index=*` showed only `pp-www` (its docker logs in `main`) — every other forwarder was sending events to non-existent `wineventlog`.

**Fix:** parameterise the index in the templates via group_vars (`windows_index: "windows"`, `linux_index: "linux"`, `sysmon_index: "windows"`, `squid_index: "linux"`, with sensible defaults). Range authors who want to split Sysmon into its own index or send Squid to a `proxy` index could then override without forking the role. PowerPlant resolved by overlaying the role and changing the templates directly (sysmon → `sysmon`, squid → `proxy`).

---

## 2026-05-18 · gap · roles/splunk-forwarder/tasks/linux.yml

The role adds the splunk service user (`admin`) to the `adm` group **after** the deb is installed, but before any `splunk start` task runs the first time. That happens to work on fresh installs because the role then starts splunkd via `splunk enable boot-start`, which forks a *new* process that inherits the updated group set. But re-runs (or re-runs after a host respin where splunkd is already running and only the inputs.conf needs to be updated) silently leave the live splunkd without `adm` group access — it monitors `/var/log/syslog` but can't read it, fails silently, and no events flow.

**Fix:** add `notify: Restart SplunkForwarder` to the `Add splunk user to adm group` task (and the matching `splunkfwd` and `proxy` group tasks) so any group change triggers a service restart at handler-flush time. The current play assumes process credentials track group membership live, which Linux processes don't.

---

## 2026-05-13 · bug · roles/splunk-es/tasks/main.yml

`Get Splunk Apps` uses `delegate_to: localhost` to list installer files on the Ansible controller. The play that loads this role typically sets `become: true` (the customer's `playbook.yaml` does), so the delegated task tries `sudo` on the controller. The controller's `simspace` user doesn't have passwordless sudo by default, and no `ansible_become_pass` is set for `localhost` (the `[linux]` group's value doesn't apply to the implicit localhost). Result: `sudo: a password is required`, role fails before any app installs.

**Fix:** add `become: false` to that one task — listing files for a `find` lookup doesn't need root. The current implementation only inherits the play-level become for what amounts to a directory read. PowerPlant worked around it by adding `host_vars/localhost.yml` with `ansible_become_pass: simspace1`, but per-task `become: false` is the correct fix.

---

## 2026-05-14 · bug+gap (multi-part) · roles/splunk-es/tasks/main.yml

ES bootstrap (`essinstall`) is fragile under realistic VM sizing. Five distinct failures observed in PowerPlant, each requiring its own workaround in the `ss-pp-ab` overlay:

**(a) `Install Splunk Apps` HTTP-thread saturation.** The role installs each `.tgz` in a serial loop via `splunk install app`. After a few installs Splunkd's REST server hits `httpServer.maxThreads` (default `vcpus*2` per the role's own `server.conf.j2`) and starts rejecting with `HTTP 503 Too many HTTP threads (8) already running, try again later`. No retries — a single 503 fails the task. **Fix:** add `retries: 6, delay: 20, until: rc == 0` to the loop, and raise `[httpServer] maxThreads` to `64` (or expose it as a var) before the app-install loop runs.

**(b) `Install Enterprise Security App` same root cause.** Single shot, no retry. Same fix.

**(c) `Configure Enterprise Security App` (essinstall) races bootstrap.** The role only waits for `/services/server/info` to return 200 before firing `essinstall`. That endpoint comes up far before `/services/admin/localapps` (which `essinstall` actually hits), so essinstall fails with `JSONDecodeError: Expecting value: line 1 column 1 (char 0)` — an HTML 503 body being parsed as JSON. **Fix:** add a second readiness probe on `/services/admin/localapps?count=0` with `retries: 30, delay: 30` between the existing wait and essinstall.

**(d) essinstall's `disable_apps` stage hangs on `missioncontrol`.** essinstall preemptively disables Splunk Mission Control before installing ES. Mission Control's own modular inputs hold REST threads, the disable call to `/services/admin/localapps/missioncontrol/disable` times out, and essinstall dies. **Fix:** pre-disable `missioncontrol` (and `splunk_secure_gateway`, which has the same shape) before essinstall runs.

**(e) essinstall under memory pressure.** With default-sized Splunk VMs (8 vCPU, 8–16 GB RAM), essinstall's restart cycles trigger SIGKILLs of search processes (`splunkd.log` shows `vm_major=3108` page faults — swap thrashing). **Fix is environmental, not in the role:** ES on this app set needs ≥16 vCPU / ≥32 GB RAM. In PowerPlant the SimSpace VM spec for `pp-splunk` was bumped to that floor and essinstall completes cleanly.

PowerPlant's full overlay lives in `ss-pp-ab/roles/splunk-es/tasks/main.yml`.

---

## 2026-05-20 · gap · roles/vyos/tasks/main.yml — BGP default-route propagation

The role auto-adds `set protocols bgp address-family ipv4-unicast redistribute static` whenever `bgp` is defined. In FRR this redistributes non-default static routes but **not** `0.0.0.0/0` — by design, to prevent accidental default-leakage. To propagate a default route through iBGP, FRR requires `neighbor X default-originate` per-neighbor, which the role doesn't expose.

Symptom in PowerPlant: pp-external-firewall had `static_route: 0.0.0.0/0 → 75.21.1.2` (toward pp-isp-router) and BGP redistribution turned on. pp-corp-router never learned the default; workstations got `Destination net unreachable` from pp-corp-router for anything off-prefix (e.g. `8.8.8.8` hosted on is-inet). Worked around by adding a static `0.0.0.0/0` to *each* internal VyOS hop pointing toward pp-external-firewall, plus one on pp-isp-router pointing at is-inet.

**Fix:** expose `default_originate: true` per BGP neighbor in the role's schema:
```yaml
bgp:
  - as: 65001
    neighbor:
      ip: "172.16.0.10"
      as: 65001
      default_originate: true
```
which would render `set protocols bgp neighbor 172.16.0.10 address-family ipv4-unicast default-originate`. Or add a `default_originate_to: [list-of-neighbors]` shortcut.

While at it, also worth extending `static_route` to accept a list (currently a single dict) — overlapping with the 2026-04-22 entry on README-vs-code mismatch, but specifically: a router that needs *both* a default route *and* a more-specific static can't currently express it.

---

## 2026-05-20 · enhancement · roles/common/tasks/windows.yml — NLA "Public/Private" popup

On first login, fresh Windows hosts pop the "Do you want to allow your PC to be discoverable on this network?" prompt. Until answered, the network stays classified as `Public` and Network Discovery / File-and-Printer-Sharing firewall groups are off — Windows hosts can't see each other in File Explorer's Network pane. Domain-joined hosts auto-promote to `DomainAuthenticated` once a DC is reachable, but the prompt still fires once before that, and non-domain-joined hosts (e.g. `win-hunt-1`) never auto-classify at all.

**Fix:** add a small `network_discovery` role to the customer repo (or fold it into `common`) that:
1. Creates `HKLM:\System\CurrentControlSet\Control\Network\NewNetworkWindowOff` (suppresses the prompt globally).
2. Sets any still-`Public` NetConnectionProfiles to `Private` (`Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private`).
3. Enables the `Network Discovery` and `File and Printer Sharing` firewall rule groups.
4. Ensures `FDResPub`, `SSDPSRV`, `fdPHost`, `upnphost` are `Started + Automatic`.

PowerPlant's overlay lives at `ss-pp-ab/roles/network_discovery/`.

---

## 2026-05-21 · bug · roles/common/tasks/windows.yml — Windows adapter naming

The `xIPAddress` / `xDefaultGatewayAddress` / `xDNSServerAddress` tasks use `InterfaceAlias: "{{ item.name }}"` keyed on `network_interfaces[].name` (e.g. `Ethernet0`, `Ethernet1`). The role assumes Windows adapters are already named that way — there's no rename step. Most SimSpace Windows images do ship with that pattern, but the `RDP_Windows_Server_2019:1.1.0` image (used by pp-mail, pp-dmz-dns, pp-dmz-smtp on PowerPlant) leaves the default Windows names like `Ethernet`, `Ethernet 2`. Result: DSC fails on the first task with `Interface "Ethernet0" is not available. Please select a valid interface and try again. Parameter name: InterfaceAlias`.

PowerPlant worked around it by adding a `Windows adapter rename pre-config` play before `Common Role` that:
1. `Get-NetAdapter | Sort-Object ifIndex`
2. Renames each adapter in order to `Ethernet0`, `Ethernet1`, `Ethernet2`, ...
3. Reports `changed` only if at least one rename happened (idempotent on re-run).

All Windows hosts in PowerPlant use `managementInterface.position: FIRST`, so mgmt gets `ifIndex 0` and becomes `Ethernet0` — matching the host_vars convention.

**Fix:** add the rename step as a preflight in the `common` role for Windows. Optionally, if positional renaming is too fragile, support a MAC-based mapping in host_vars (`network_interfaces[].mac: "00:50:56:a8:..."`) and rename by MAC match.

**Update 2026-05-22:** the naive "sort by ifIndex, rename to `Ethernet$i`" approach is unsafe on SimSpace Windows 10/11 images. Those images ship with canonical `Ethernet0`/`Ethernet1` names already assigned and the IP/role mapping correct, but Windows' `ifIndex` ordering doesn't correspond to the existing alphabetic Name ordering — so a sort-by-ifIndex pass tries to "fix" already-correct hosts, races on the existing names (`Rename-NetAdapter` fails with `Windows System Error 698 / Object Exists`), and would silently swap the mgmt/data-plane mapping if it succeeded. Two safety rails for any implementation:

1. **Skip if all canonical names already exist among the adapters.** A host whose `Get-NetAdapter | Select Name` includes every `EthernetN` for `N in 0..count-1` is already correctly named — don't touch it.
2. **When a rename is needed, do a two-pass swap through temp names** (`_temp_0`, `_temp_1`, ...). Otherwise the first rename can collide with an existing target name and the role aborts mid-loop, leaving the host in a broken half-renamed state.

PowerPlant's pre-play in `arbitr_pp_playbook.yaml` implements both rails.

---

## 2026-05-26 · platform · SimSpace OT-pfSense image — first-boot interactive setup required

The `OT-pfSense:1.0.0` image (used to replace VyOS on pp-ot-firewall) does **not** apply SimSpace's YAML interface assignments at first boot. It arrives at the pfSense interactive interface-assignment wizard prompting the operator to map physical NICs (named `vmx0..vmx3` — VMXNET3 driver) to WAN/LAN/OPT roles. The `a` (auto-detect) option doesn't work in VMs because it relies on physically unplugging cables. As a result:

- No management IP is bound to any NIC on first boot, so Ansible can't reach the host (`No route to host` from `10.255.240.0/20`).
- SSH is not enabled by default; the `admin` user has no shell privilege by default. Both are required for `pfsensible.core` to drive config.

**Workaround in PowerPlant overlay (one-time manual step per provision):**

On the pfSense console:
1. Walk the wizard, assigning WAN=vmx0, LAN=vmx3 (where `position: LAST` places mgmt), OPT1=vmx1, OPT2=vmx2.
2. Menu option `2` → LAN → static IP `10.255.240.190/20`, no gateway, no DHCP server.
3. Browse `https://10.255.240.190`, log in `admin/pfsense`, enable SSH under System → Advanced → Admin Access, and add "User - System: Shell account access" to the admin user under System → User Manager.

After that, the Ansible `pfsense_ot_firewall` role drives the rest of the config (interfaces, gateways, routes, firewall rules).

**Fix (SimSpace side):** the `RC-IS-INET` and `RC-VyOS-*` images already self-configure their interfaces from the YAML's `networkInterfaces` block at first boot. `OT-pfSense:1.0.0` should do the same — drop a `config.xml` (or run `pfSsh.php playback assigninterfaces ...`) during cloud-init that:
- Assigns NICs to roles based on the YAML's interface order
- Sets the mgmt IP on whichever NIC corresponds to `managementInterface.position`
- Enables SSH and gives the default admin user shell access (or ships with a known-good credential pair pre-configured for Ansible)

Until that lands, every fresh provision of an OT-pfSense VM requires the manual console step above.

**Post-wizard config quirks (also worked around in PowerPlant overlay)**:

1. **Stale `GW_WAN` gateway pointing at `192.168.90.1`** survives in `config.xml` regardless of what we configure with `pfsensible.core.pfsense_gateway`. pfSense's `<defaultgw4>` is auto-set to this stale entry, which then becomes the system default route on the wrong interface (`vmx1`/OT_TRANSIT). The bad default triggers `antispoof` to silently drop inbound packets on `WAN_INTERNAL` (uRPF reply path mismatch). Worked around by a `php -r` task that deletes any `gateway_item` named `GW_WAN` and pins `<defaultgw4>` to our `GW_INTERNAL`.

2. **Automatic Outbound NAT is wrong for a transit firewall**. The default mode rewrites every local-subnet source IP to the WAN interface IP when egressing — fine for an internet edge, wrong for an internal transit point where defenders/monitoring need to see real device source IPs. Worked around by a `php -r` task that sets `<nat><outbound><mode>` to `disabled`.

3. **`pfsensible.core 0.7.x` doesn't expose `<defaultgw4>` or `<nat><outbound><mode>`** — both fixes have to bypass the collection and call `config_set_path()` via `php -r` on the appliance. Worth filing an enhancement against pfsensible.core to expose these in `pfsense_gateway` and `pfsense_nat_outbound` respectively.

---

## 2026-05-22 · platform · SimSpace RC-IS-INET image — wrong netmask on eth1

The `RC-IS-INET:1.0.6` image (used for PowerPlant's `is-inet` VM) brings up its data-plane interface (`eth1`) with a `/32` mask instead of the `/24` specified in the range YAML's `PowerPlant-External-Placeholder` subnet. With `/32`, is-inet has **no connected route to its own LAN segment** — the only IPv4 routes are `10.255.240.0/20` on `eth0` (management) and the host's own `/32`. The image also ships with **no default gateway** on the data plane.

Effects:
- pp-isp-router (`200.200.200.1`) can ARP-resolve `200.200.200.2` and deliver frames to is-inet, but is-inet has no return route — every reply gets `ENETUNREACH` and is silently dropped.
- ICMP echo from a NAT'd LAN host appears to "work" only because the trace's final hop reports the destination on TTL-exhaustion at upstream routers; the actual ICMP echo reply never makes it back.
- DNS queries hit unbound but the response can't escape the box.

Visible from `is-inet$ ip -br addr | grep eth1`:
```
eth1   UP   200.200.200.2/32 ...
```
…and `ip route` shows no `200.200.200.0/24` line and no `default via …`.

**Workaround (non-persistent — reverts on reboot):**
```bash
sudo ip addr del 200.200.200.2/32 dev eth1
sudo ip addr add 200.200.200.2/24 dev eth1
sudo ip route add default via 200.200.200.1
```

**Durable fix in PowerPlant overlay:** wrap the above in a small `is_inet_fix` role (planned), so it re-asserts after each provision.

**Fix (SimSpace side):** the image's cloud-init / netplan should honor the YAML-declared `prefix: 24` and configure a default gateway pointing at the subnet's `GATEWAY`-roled neighbor. Today the image silently downgrades to `/32` and skips the gateway entirely.

---

## 2026-05-22 · platform · SimSpace RC-IS-INET image — DNS service binds only to alias IPs

is-inet's unbound (running in a host-network docker container) binds to `8.8.8.8`, `8.8.4.4`, `1.1.1.1` (and possibly others among the thousands of `/32` aliases on `lo`), but **not** to the primary data-plane IP `200.200.200.2`. A query to `200.200.200.2:53` from any source returns `connection refused` (TCP) or times out (UDP).

Visible from `is-inet$ sudo ss -lntu | grep :53` — listening sockets are on the alias IPs only.

Consequence for range authors: a DNS forwarder configured to point at is-inet's "obvious" primary IP (`200.200.200.2`) will silently fail. PowerPlant's `dns_forwarder` play forwards to `8.8.8.8` and `8.8.4.4` instead.

**Fix (SimSpace side):** either bind unbound to `0.0.0.0:53` so the primary IP also answers, or document the alias-IP-only binding so range authors don't burn time chasing a "DNS server not responding" symptom.

---

## 2026-05-22 · gap · roles/dns/tasks/main.yml — no forwarder configuration

The `dns` role creates AD-integrated forward/reverse zones and `internal_dns_records` entries, but never configures DNS forwarders on the DC. Result: domain-joined hosts can resolve names within the AD zones (e.g. `voltgrid.com`) but every lookup for anything else times out — Windows DNS has nothing to forward to and no working root hints in a sealed range.

Symptom in PowerPlant after deploy: `nslookup www.voltgrid.com` resolves, `nslookup hbo.com` times out with `*** Request to pp-dc01.voltgrid.com timed-out`. is-inet was up and reachable, listening on `200.200.200.2` (plus aliases like `8.8.8.8`) with simulated public DNS — but pp-dc01 wasn't asking it.

**Fix:** add an optional `dns_forwarders` variable to the role and, when set, run:
```yaml
- name: Configure DNS forwarders
  ansible.windows.win_powershell:
    script: |
      Set-DnsServerForwarder -IPAddress {{ dns_forwarders | join(',') }} -UseRootHint $false -Timeout 3
  when: dns_forwarders is defined
```
Range authors then declare `dns_forwarders: ['200.200.200.2']` (or whatever the simulated-internet DNS IP is) in group_vars. Disabling root hints is important in sealed ranges — otherwise queries that miss the forwarder fall back to root hints and consume the full `forwarder_timeout` window before failing.

PowerPlant overlay adds a one-task play after the `dns` play in `arbitr_pp_playbook.yaml` that runs against `domain_controllers` (covers both the primary DC and any additional DCs — forwarder config is per-DC, not replicated via AD).

---

## 2026-05-27 · bug · roles/common/tasks/windows.yml

Same "Disable control net DNS registration" task (lines 51–57) has a **second** bug beyond the `Ehternet0` typo already logged on 2026-04-17: the cmdlet parameter is misspelled. The task uses `set-DnsClient -RegisterThisConnectionAddress $false` (singular *Connection*); the real PowerShell parameter is `-RegisterThisConnectionsAddress` (plural *Connections*). So even if the typo were fixed and the loop matched real adapters, `Set-DnsClient` would error with "A parameter cannot be found that matches parameter name 'RegisterThisConnectionAddress'". Net effect: every Windows host DDNS-registers its mgmt adapter (Ethernet0 → 10.255.240.0/20) into the AD zone, so `ping pp-dc01` from a corp workstation round-robins onto the orchestration IP that's supposed to be out-of-play.

**Fix (upstream):** correct both the adapter loop AND the parameter:
```yaml
- name: Disable DDNS on mgmt adapter
  ansible.windows.win_powershell:
    script: |
      Set-DnsClient -InterfaceAlias "{{ item }}" -RegisterThisConnectionsAddress $false
      ipconfig /registerdns | Out-Null
  loop: "{{ network_interfaces | map(attribute='name') | list | first | list }}"
```
(Or hardcode `Ethernet0` if mgmt is always the first adapter in the SimSpace pattern.)

**Workaround in PowerPlant overlay:** added two plays to `arbitr_pp_playbook.yaml` after the `dc_status` play (tag `strip_mgmt_dns`). First disables DDNS on Ethernet0 across all Windows hosts and re-registers; second runs against the PDC to delete any A record in voltgrid.com whose IPv4 falls in 10.255.240.0/20, and any PTR record in the matching reverse zones. Idempotent.

---

## 2026-05-27 · bug · SimSpace VyOS image template (`RC-VyOS-Router`)

The SimSpace VyOS 1.5-rolling image bakes one stale `set protocols static route 0.0.0.0/0 next-hop <X>` entry for **every /24 "departmental" interface** on the router after first boot. The next-hop is always the router's own connected IP on that /24 — i.e., a self-loop. /30 transit interfaces are unaffected. Observed across `pp-internal-router` (1 stale), `pp-isp-router` (2 stale), `pp-corp-router` (5 stale). `site-edge-router` is clean because it only has /30 interfaces.

**Symptom**: FRR refuses to install a default route whose next-hop resolves to a local interface IP, and with multiple equal-cost competing statics it drops the *entire* `0.0.0.0/0` out of the FIB. `show ip route` has no `S>* 0.0.0.0/0` line at all; the router returns ICMP "Destination net unreachable" for everything outside connected / OSPF / BGP routes. On PowerPlant this broke corp→DMZ reachability after the firewall pfSense migration (the BGP-learned defaults that used to mask the broken statics were gone).

**Detection**: on each VyOS host, `show configuration commands | match "0.0.0.0/0"` — anything more than one default-route line is the bug.

**Fix (upstream)**: SimSpace should strip the post-provision script (or template config) that injects per-interface default routes. Routers should ship with no static defaults; the Ansible role's `static_route` is authoritative.

**Workaround in PowerPlant overlay**: added a new play to `arbitr_pp_playbook.yaml` ("Remove stale VyOS static routes", tag `extra_static_routes_remove`) that iterates a per-host `extra_static_routes_remove: [{network, next_hop}]` list and issues `delete protocols static route <n> next-hop <nh>` via `vyos_config`. Each affected host_vars file declares the IPs to strip; the play runs idempotently after the `Additional VyOS static routes` play, so the only surviving default is whatever the customer `vyos` role set from `static_route`.

---

## 2026-05-26 · gap · range-development-ansible has no pfSense role

The shared repo ships `vyos` and `panos` roles for network gear but no role for pfSense. PowerPlant migrated all three firewalls (`pp-ot-firewall`, `pp-internal-firewall`, `pp-external-firewall`) from VyOS to pfSense and had to build a `pfsense_firewall` role from scratch using the `pfsensible.core` Ansible collection (v0.7.x — installed via `requirements.yml`).

What the overlay role covers (could be lifted into the shared repo largely as-is):
- `pfsense_setup` for hostname/domain
- `pfsense_interface` loop driven by `pfsense_interfaces[]` (descr + physical NIC + IPv4) — supports per-interface `blockpriv` / `blockbogons` override needed when the role's "WAN-tagged" interface is actually carrying RFC1918 traffic
- `pfsense_gateway` loop for named gateways, plus a `php -r` task that pins `<defaultgw4>` and strips stale image-baked gateways (collection 0.7.x doesn't expose `<defaultgw4>`)
- `php -r` task to set `<nat><outbound><mode>` to `disabled` for transit-firewall mode (also unsupported by the collection)
- `pfsense_route` loop for static routes
- `pfsense_rule` loop for lab-mode permit-any rules

**Fix (upstream)**: add a `pfsense_firewall` (or `pfsense`) role to the shared repo following the `vyos` role's variable-driven convention, including the `php -r` shims for things the collection still can't drive. The PowerPlant overlay at `ss-pp-ab/roles/pfsense_firewall/` is a working reference.

---

## 2026-05-29 · gap · range-development-ansible has no central syslog collector role

There's no role for standing up a host as a centralized syslog receiver. Ranges that want one have to author their own. PowerPlant has pp-syslog as the collector and uses Splunk UF on the same host to ship into the `netfw` index; the overlay carries `ss-pp-ab/roles/syslog_server/`, which installs rsyslog, opens UDP **and** TCP 514, and writes per-host files at `/var/log/remote/<hostname>/syslog.log` (path layout chosen so Splunk UF's `host_segment=4` correctly attributes events to the sending device, not pp-syslog).

**Fix (upstream)**: add a `syslog_server` (or `rsyslog_collector`) role with the same shape — variable-driven listener config, per-host file layout, defensive `omfile`+`stop` so received events don't double-log into the collector's own `/var/log/syslog`. The overlay role is small enough (~25 lines tasks + a 35-line rsyslog template + 5-line handler) to land verbatim.

---

## 2026-05-29 · gap · roles/common, roles/vyos — no syslog client config

Once a range has a collector, every device needs a small bit of config to forward to it. None of the shared roles do this today:

- **`roles/common/tasks/linux.yml`** has no task that drops an `/etc/rsyslog.d/*-forward.conf` snippet.
- **`roles/vyos/tasks/main.yml`** has no task that pushes `set system syslog host <ip> facility all level info`.

PowerPlant handles all of this in three inline plays in `arbitr_pp_playbook.yaml` (tag `syslog_client`) gated by a single new variable `syslog_server_ip` in `group_vars/all.yml`. Linux clients get a one-line UDP forwarder, VyOS clients get the `set system syslog host` line via `vyos_config`, and pfSense clients get a `php -r` task that writes the `<syslog>` block in `config.xml`. Hosts that shouldn't forward (e.g., `pp-isp-router`, which represents the ISP rather than corp gear) are excluded via host pattern (`vyos:vyos_routes_only:!pp-isp-router`).

**Fix (upstream)**:
1. In `roles/common/tasks/linux.yml`, drop an rsyslog forwarder snippet whenever `syslog_server_ip` is defined, with a notified handler to restart rsyslog. ~10 lines.
2. In `roles/vyos/tasks/main.yml`, add a `vyos_config` task with the same gate. ~6 lines.
3. Add a sibling pfSense role (see 2026-05-26 gap above) and include the `<syslog>` block there.

---

## 2026-05-29 · gap · roles/splunk-forwarder/templates/lin_inputs.conf.j2 — no support for tailing a central syslog tree

`lin_inputs.conf.j2` covers `/var/log/syslog`, `/var/log/auth.log`, Squid (when host is in `[proxy]`), and Docker container logs (when host is in `[wordpress-pv]`) — but there's no stanza for tailing a central collector's per-host directory tree (`/var/log/remote/<sender>/...`). Ranges that put a syslog collector on a Splunk-forwarder host have no way to surface the collected events without overriding the template.

PowerPlant adds the missing stanza in the overlay copy of the file:

```jinja
{% if 'syslog' in group_names %}
[monitor:///var/log/remote/.../syslog.log]
disabled = false
index = netfw
sourcetype = syslog
host_segment = 4
{% endif %}
```

`host_segment = 4` is the key — without it Splunk attributes everything to the collector host rather than the sender. The `netfw` index is already declared (but unused) in `group_vars/all.yml`'s `indices` list, with a comment "reserved for pfsense/vyatta syslog when wired up" — this finally uses it.

**Fix (upstream)**: add the conditional stanza in the shared template, gated on a `[syslog]` group name (or a `syslog_collector_path` variable). Keeps every range's UF inputs.conf consistent and removes the need to fork the template.

---

## 2026-05-29 · gap · roles/common/tasks/linux.yml — Ubuntu Desktop first-login wizard

The Ubuntu Desktop images SimSpace uses ship with `gnome-initial-setup` enabled, so the first interactive login on every Linux host pops the "Connect Your Online Accounts" / Welcome wizard. Not a routing or service failure — it just clutters the desktop for anyone driving the range manually, and a scripted operator that types into the wizard's password field has typed into nothing real.

PowerPlant suppresses it with a small play after `Common Role` (tag `gnome_initial_setup`) that drops the documented `~/.config/gnome-initial-setup-done` flag with content `yes` into each `/home/*` directory and into `/etc/skel` (so future users inherit it). `gnome-initial-setup` checks this file at startup and exits silently when present.

**Fix (upstream)**: add the same flag-file drop to `roles/common/tasks/linux.yml`, gated on the host having a Desktop session (e.g., `ansible.builtin.stat: path=/usr/bin/gnome-shell` or `package_facts` for `gnome-initial-setup`). Alternative: `apt purge gnome-initial-setup` is more invasive but removes the package entirely. Flag-file approach is reversible.

---

## 2026-05-29 · platform · SimSpace pfSense 2.8.1 image — closes most OT-pfSense:1.0.0 gaps, new things to know

The replacement SimSpace pfSense image (pfSense 2.8.1) supersedes `OT-pfSense:1.0.0` for all PowerPlant firewalls (`pp-ot-firewall`, `pp-internal-firewall`, `pp-external-firewall`). Net effect: most of the 2026-05-26 OT-pfSense entry is now historical. Specifically:

- **Mgmt NIC is now first (`vmx0`) and takes DHCP.** SimSpace platform DHCP hands it the mgmt IP from the layout YAML's `managementInterface` block on first boot. Ansible can SSH straight in — **no interactive interface-assignment wizard needed**. The per-host wizard interface table (kept in chat-history as a fallback) is no longer the default path.
- **WAN NIC is second (`vmx1`), also DHCP by default.** Our `pfsense_interface` task reconfigures it to the host's static IP. The brief DHCP-no-lease state during initial provisioning is harmless because Ansible talks over mgmt.
- **Two pre-provisioned users**: `admin:simspace1` and `simspace:simspace1`. The overlay keeps `ansible_user: admin` because pfsensible.core 0.7.x writes `/cf/conf/config.xml` directly (no sudo). On pfSense `/tmp` and `/cf` are separate filesystems, so the collection's `shutil.move` falls back from `os.rename` to `copy`, and `copy` then needs write access to a root-owned file. Only `admin` has that on the new image; `simspace` would `EACCES`. Worth a bug report against `pfsensible.core` to either (a) write the tempfile under `/cf/conf/` so the atomic rename stays on one filesystem or (b) sudo-escalate writes. Until then, `admin` is mandatory.
- **FRR is pre-installed.** The previous "static-routing only because pfsensible.core has no FRR module" workaround is no longer needed. The overlay's `pfsense_firewall` role now enables the FRR package via `php -r` and pushes BGP config via `vtysh -f` from `templates/frr.conf.j2`, driven by a new per-host `pfsense_bgp` variable. iBGP AS 65001 + eBGP AS 65002 to `pp-isp-router` is restored, and all the per-`/24` `extra_static_routes` workarounds on `pp-isp-router`, `site-edge-router`, and `pp-internal-router` have been stripped. The VyOS routers' `bgp:` blocks (which were inert because their pfSense neighbors didn't speak BGP) are live again.
- **Other pre-installed packages**: `ntopng`, `Open-VM-Tools`, `softflowd`, `WireGuard`. Not yet driven by the role — relevant for future NetFlow ingestion (`softflowd` → pp-splunk) and out-of-band management VPN (`WireGuard`).

**Remaining gaps (still worth raising upstream)**:

1. **pfsensible.core 0.7.x still has no FRR module.** Our role enables FRR via `installedpackages/frr/config/0/enable` and pushes the actual routing config via `vtysh -f` + `write memory`. That works but it's outside the collection's schema. Worth filing against the collection to expose FRR/BGP/OSPF as proper modules so the role doesn't need the `vtysh` shim.

2. **pfSense FRR package may regenerate `frr.conf` at boot from its own config tree.** If that happens, `write memory` is overridden on reboot. Mitigation if observed: push our entire FRR config into the package's `rawconfig` (or equivalent) field — schema varies by package version, so the overlay defers this until the boot behavior is confirmed.

3. **The 2026-05-26 entry's manual-wizard procedure is still a useful fallback** if a future image regresses or someone needs to re-do interface assignment manually. Left in place rather than deleted.

4. **NIC ordering inversion (mgmt = first instead of LAST)** is a layout/host_vars contract change, not a customer-repo gap. The PowerPlant overlay's three firewall host_vars files were rewritten in this turn to match the new contract; SimSpace YAML's `managementInterface.position` needs to be `FIRST` to match.

---

## 2026-06-04 · platform · SimSpace pfSense 2.8.1 image — `system_syslogd_start()` writes config but fails to leave a daemon running

On the new pfSense 2.8.1 image (`pfSense-pkg-frr-2.0.2_6`, `frr9-9.1.2_1`), calling `system_syslogd_start()` after the `<syslog>` block is set:

1. Successfully writes `/etc/syslog.conf` (`include /var/etc/syslog.d`) and `/var/etc/syslog.d/pfSense.conf` with the correct `*.*  @<remoteserver>` forwarder line.
2. Attempts to start syslogd via FreeBSD's `service syslogd start`.
3. The rc script wraps syslogd in `protect -p <pid>` for OOM resistance.
4. The `-p` argument expansion is empty (a pfSense-side variable that should hold the pid is uninitialized), so `protect` exits with `option requires an argument -- p`.
5. The PHP wrapper swallows the error (uses `mwexec()` which discards stderr), so the function returns 0 with no daemon running.

Net effect: the `<syslog>` block looks correct in `config.xml`, `/etc/syslog.conf` and `/var/etc/syslog.d/pfSense.conf` look correct, but **no syslog events ever leave the box** (including no local writes to `/var/log/system.log` / `/var/log/filter.log` etc., since those go via syslogd too). Symptom is identical to "remote syslog server is unreachable."

Compounded by a secondary fault: even when syslogd does start, if the remote-server `<remoteserver>` is not currently reachable (e.g., BGP hasn't converged yet on a fresh deploy), syslogd's startup `connect()` to the remote address returns `ENETUNREACH` and the daemon exits cleanly. Catch-22: the routing protocol (FRR/BGP) needs syslog up to send its own logs, and syslog needs routing up to reach the collector.

**Detection**: `ps -axwww | grep '[s]yslogd'` returns nothing after a deploy; `tail /var/log/system.log` shows the last entry is from boot time; `/usr/sbin/syslogd -dd -ss -f /etc/syslog.conf` in the foreground reveals `connect: Network is unreachable` or (if routing IS up) starts cleanly.

**Fix (upstream)**: 
1. pfSense should initialize the variable that's passed to `protect -p` before invoking it (or drop the `protect` wrapper for syslogd since OOM-killing syslogd is not the threat model that wrapper was meant for).
2. `syslogd` should be started in a mode that tolerates initial DNS / connect failures and retries — most syslog implementations do this; FreeBSD's syslogd does not.

**Workaround in PowerPlant overlay**: ensure FRR/BGP is up before the syslog client task runs (already true: pfsense_firewall role runs FRR setup before the syslog client play in the playbook). Beyond that, the syslog client play's `system_syslogd_start()` call is best-effort — if it fails silently, the next play (or a manual `/usr/sbin/syslogd -ss -f /etc/syslog.conf -P /var/run/syslog.pid` from a console) will recover it.

---

## 2026-06-04 · platform · SimSpace pfSense 2.8.1 image — FRR package's `<enable>on</enable>` does not actually render config files

The pfSense FRR package (`pfSense-pkg-frr-2.0.2_6`) is pre-installed on the new image, with `frr9-9.1.2_1` binaries at `/usr/local/sbin/{watchfrr,zebra,bgpd}` + `/usr/local/bin/vtysh`. Setting `<installedpackages><frr><config><enable>on</enable></config></frr>` in config.xml *enables* the package per its own metadata but does NOT cause the package's render function to populate `/var/etc/frr/{daemons,vtysh.conf,frr.conf}`. The package's renderer requires additional per-feature schema blocks (`<frrbgp>`, `<frrglobalraw>`, etc.) whose layout varies by package version and is not worth coding against.

Net effect on a fresh deploy where the overlay only set `<enable>on</enable>`: `/var/etc/frr/` exists but is empty, `vtysh` errors with `Can't open configuration file /var/etc/frr/vtysh.conf`, `service frr onestart` either silently does nothing or trips the same `protect` arg bug that affects syslogd. No FRR daemons run. No BGP. No routes. The whole network sits with default routes only (where configured) and `Destination net unreachable` everywhere else.

**Detection**: `pkg info | grep -i frr` shows FRR installed; `ls /var/etc/frr/` is empty or contains only stub files written by the rc script's auto-creation guard; `vtysh -c "show ip bgp summary"` reports "failed to connect to any daemons".

**Fix (upstream)**:
1. The pfSense FRR package's PHP layer should render at least default `daemons` and `vtysh.conf` files when `<enable>on</enable>` is set, even if no per-feature config is provided. The current "enable does nothing without features" pattern is a UX cliff.
2. The package should also provide a stable, documented "raw config" field (`<frrglobalraw><rawconfig>...</rawconfig></frrglobalraw>` in some versions) so ranges can push a full FRR config without learning the per-feature schema.

**Workaround in PowerPlant overlay**: `roles/pfsense_firewall/` bypasses the package's renderer entirely. Three templates (`frr.daemons.j2`, `frr.vtysh.conf.j2`, `frr.conf.j2`) are dropped directly into `/var/etc/frr/` (the path the rc script reads from — verified via `grep "/var/etc/frr" /usr/local/etc/rc.d/frr`). The role still toggles `<installedpackages><frr><config><enable>on</enable></config></frr>` so the rc script gets autoloaded at boot and the GUI doesn't show FRR as "disabled." A handler (`restart frr`) reloads daemons via `service frr` with a fallback to launching `watchfrr -d -F traditional zebra bgpd` directly if the rc wrapper trips. The `frr.conf` template generates the per-host BGP config from the `pfsense_bgp` host_vars block (asn, router_id, neighbors[]).

---

## 2026-06-09 · bug · pfsensible.core 0.7.x — `pfsense_interface` writes config.xml but never applies to kernel

On pfSense 2.8.1 (`pfSense-pkg-frr-2.0.2_6`, fresh image, `pfsensible.core 0.7.1`), calling `pfsense_interface` with `ipv4_type=static / ipv4_address / ipv4_prefixlen` correctly updates the `<interfaces><wan>...</wan></interfaces>` block in `/cf/conf/config.xml`. The SSH banner and webConfigurator both reflect the new IP because both read from config.xml. **But the kernel interface never gets the IP bound.**

```
vmx1: flags=1008843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
   description: WAN_EDGE
   ether 00:50:56:a8:66:90
   inet6 fe80::250:56ff:fea8:6690%vmx1 prefixlen 64 scopeid 0x2     ← only IPv6 LL
```

No `inet 172.16.0.18` line. `netstat -rn` has no connected route for the subnet. Everything downstream of the affected interface fails with "No route to host" or silently times out — BGP neighbors stick in Active state forever, syslog can't reach its collector, etc.

Root cause: the pfSense GUI's interface-save flow calls `interface_configure($key)` (from `/etc/inc/interfaces.inc`) which runs the `ifconfig` invocations that bind the IP. The Ansible module skips this step on this image — possibly because pfsensible.core's commit-changes path calls `system_routing_configure()` and `filter_configure()` but not `interface_configure()` per interface.

**Detection**: after running `pfsense_interface`, check `ifconfig <iface>` — if there's no `inet x.x.x.x` line matching config.xml, you've hit this.

**Fix (upstream)**: pfsensible.core's `pfsense_interface` module should invoke `interface_configure($if)` for each modified interface as part of its commit path. Same fix probably belongs in any other module that touches the `<interfaces>` block.

**Workaround in PowerPlant overlay**: a new task in `roles/pfsense_firewall/tasks/main.yml` runs immediately after the `pfsense_interface` loop. It walks the `pfsense_interfaces` list (matched by descr), checks whether each interface's wanted IP is already bound to the underlying physical NIC via `ifconfig`, and only invokes `interface_configure($key)` if not. Filtered to only OUR data-plane descrs — explicitly NOT `lan` (which is the mgmt interface in the new image's NIC ordering; reconfiguring it would tear down the Ansible SSH session). Notifies the `restart frr` handler so FRR/zebra re-scans the now-populated interface state and BGP can converge. See main.yml task "Apply pfSense interface config to the kernel".

---

## 2026-06-09 · gap · roles/vyos — iBGP no-readvertise (RFC 4271 §9.2) needs route reflectors (SUPERSEDED)

> **SUPERSEDED 2026-06-10:** The per-/24 static-route workarounds described below (on `pp-internal-firewall`, `pp-external-firewall`, `site-edge-router`, `pp-isp-router`) were **removed** in the 2026-06-10 architectural redesign, which shifted the corp domain from iBGP to OSPF area 0 as the IGP. Under OSPF, the no-readvertise rule is not an issue — every internal router learns every corp prefix. See the 2026-06-10 entry below for the full new routing model. The root-cause explanation and the upstream `route_reflector: true` proposal remain valid guidance for any future range that stays on iBGP.


PowerPlant's BGP design has pp-internal-router as the central hub of a hub-and-spoke iBGP topology in AS 65001. Its three iBGP peers:

- pp-corp-router (172.16.0.42) — origin of corp /24s (172.16.2-6.0/24, 172.16.9.0/24)
- pp-internal-firewall (172.16.0.25) — pfSense, transit to site-edge / pp-external-firewall
- pp-ot-firewall (172.16.0.50) — pfSense, transit + redistribute static for OT prefixes

Without `route-reflector-client` configured, pp-internal-router **does not re-advertise iBGP-learned routes to its other iBGP neighbors** (per RFC 4271 §9.2 — standard split-horizon behavior). Effects:

- pp-internal-firewall never sees the corp /24s in its BGP table (pp-corp-router → pp-internal-router → ...full stop). All corp-bound traffic falls through to default → site-edge → pp-external-firewall → pp-isp-router → black hole.
- pp-external-firewall has the same problem.
- pp-ot-firewall works for the inbound case (its default already points at pp-internal-router which IS the route origin).
- site-edge-router, pp-isp-router similarly miss the deeper corp prefixes.

**Symptom that surfaced this**: pp-syslog (172.16.2.9) was reachable from pp-ot-firewall but not from pp-internal-firewall / pp-external-firewall. Syslog flowed from one box but not the other two.

**Detection**: on each pfSense / VyOS, `show ip bgp 172.16.2.0/24`. If the spokes don't have a BGP entry for the corp /24s and pp-internal-router does, you've hit this.

**Fix (upstream)**: the customer `roles/vyos/tasks/main.yml` BGP block should support a `route_reflector: true` flag in the host_vars `bgp:` neighbor block. When set, the role would emit:
```
set protocols bgp neighbor X.X.X.X address-family ipv4-unicast route-reflector-client
```
…and pp-internal-router's host_vars would declare all three iBGP neighbors as RR clients. That's the standard pattern for a hub-and-spoke iBGP design — every utility's central router runs this way.

Alternative — full mesh — doesn't scale and is irrelevant for a 4-node AS but conceptually possible.

**Workaround in PowerPlant overlay**: per-/24 statics on the affected hosts:
- `host_vars/pp-internal-firewall.yml`: `pfsense_routes` for 172.16.2-6.0/24, .9.0/24, and 192.168.0.0/16 via `GW_INT_ROUTER` (= 172.16.0.26 = pp-internal-router).
- `host_vars/pp-external-firewall.yml`: same /24s via `GW_EDGE_TRANSIT` (= 172.16.0.10 = site-edge-router).
- `host_vars/site-edge-router.yml`: `extra_static_routes` for the same /24s via 172.16.0.18 (pp-internal-firewall).
- `host_vars/pp-isp-router.yml`: umbrella `extra_static_routes` 172.16.0.0/16 + 192.168.0.0/16 via 75.21.1.1 (pp-external-firewall) so return traffic from is-inet has a back-stop.

Each block is commented inline pointing at this entry. When the upstream `vyos` role gains RR support, all of those overlay statics can come back out.

---

## 2026-06-10 · architecture · OSPF area 0 IGP + eBGP-only edge + static-at-ESP (utility-realistic redesign)

Earlier deployments ran iBGP AS 65001 as the corp IGP, with workarounds (per-/24 statics on multiple hosts) to defeat iBGP's no-readvertise rule. That works but isn't how a real electric utility deploys its IT/OT network. **The 2026-06-10 redesign moves the corp domain to OSPF area 0 as the IGP, restricts BGP to a single eBGP session at the WAN edge, and uses static routing at the ESP boundary**. This matches NERC CIP-005 and NIST SP 800-82 guidance for utility IT/OT segmentation.

### What changed by zone

| Domain | Old | New |
|---|---|---|
| pp-corp-router ↔ pp-internal-router (172.16.0.40/30) | iBGP + OSPF (already there) | **OSPF area 0** only |
| pp-internal-router ↔ pp-internal-firewall (172.16.0.24/30) | iBGP, pfSense FRR | **OSPF area 0** on both ends |
| site-edge-router ↔ pp-internal-firewall (172.16.0.16/30) | iBGP | **OSPF area 0** |
| site-edge-router ↔ pp-external-firewall (172.16.0.8/30) | iBGP | **OSPF area 0** |
| Corp /24s on pp-corp-router (172.16.2-6.0/24) | iBGP redist connected | OSPF advertise via interface flag |
| DMZ /24 on pp-external-firewall (172.16.8.0/24) | iBGP redist connected | OSPF advertise |
| pp-internal-router ↔ pp-ot-firewall (172.16.0.48/30) | iBGP | **STATIC both sides — ESP boundary, no protocol crosses** |
| pp-isp-router ↔ pp-external-firewall (75.21.1.0/30) | eBGP AS 65001↔65002 | **eBGP unchanged — only BGP session in the fabric** |

### How redistribution flows

- **pp-external-firewall** (corp edge):
  - OSPF area 0 on `vmx2` (DMZ) and `vmx3` (EDGE_TRANSIT).
  - eBGP to pp-isp-router on `vmx1`.
  - `redistribute_ospf: true` in BGP — corp prefixes flow to the ISP.
  - `default_originate: true` in OSPF — the BGP-learned default re-enters the corp OSPF domain so non-edge speakers learn the WAN exit.
  - `redistribute_bgp: true` in OSPF — any eBGP-learned external prefixes propagate into corp.

- **All other corp routers / firewalls** (VyOS + pp-internal-firewall):
  - OSPF area 0 on every internal interface.
  - No BGP at all.
  - Existing static defaults (admin distance 1, lower than OSPF's 110) win over OSPF-learned default — kept as primary; OSPF-learned default is backup.

### ESP boundary (NERC CIP-005)

- **pp-ot-firewall** runs no routing protocol. Default static to pp-internal-router, static routes for the three OT /24-/27 subnets via pp-ot-router. FRR is stopped on this host (role detects "no protocol declared" and cleans up).
- **pp-internal-router** has a static `192.168.0.0/16 → 172.16.0.50` (the ESP umbrella to pp-ot-firewall).
- **pp-internal-firewall** and **pp-external-firewall** keep a corresponding `192.168.0.0/16` static as a return-path back-stop (pp-ot prefixes don't enter OSPF because the boundary is static-only).
- **pp-isp-router** keeps `extra_static_routes: 172.16.0.0/16 + 192.168.0.0/16 → 75.21.1.1` so is-inet-side replies for any internal prefix reach the corp edge regardless of BGP advertisement timing.

### Overlay implementation

- **Role**: `roles/pfsense_firewall/templates/frr.conf.j2` now emits OSPF (`router ospf`) and/or BGP (`router bgp`) blocks conditionally based on `pfsense_ospf` / `pfsense_bgp` host_vars. `frr.daemons.j2` enables `bgpd` / `ospfd` only when the corresponding protocol is declared. Tasks added: `Ensure ospfd is running`, and `Stop FRR if no routing protocol declared` (idle pp-ot-firewall cleanly).
- **Host_vars**:
  - `pp-ot-firewall.yml`: removed `pfsense_bgp`, kept three OT statics.
  - `pp-internal-firewall.yml`: replaced `pfsense_bgp` with `pfsense_ospf`. Reduced `pfsense_routes` to just the OT umbrella back-stop.
  - `pp-external-firewall.yml`: kept `pfsense_bgp` with eBGP-only neighbor + `redistribute_ospf: true`. Added `pfsense_ospf` with `default_originate: true` + `redistribute_static: true` + `redistribute_bgp: true`. Reduced `pfsense_routes` to OT umbrella only.
  - `site-edge-router.yml` / `pp-internal-router.yml` / `pp-corp-router.yml`: removed legacy `bgp:` block, set `remove_vyos_bgp: true`. Removed per-/24 corp `extra_static_routes` on site-edge (OSPF carries).
- **Playbook**: new "Remove stale VyOS iBGP" play (tag `remove_vyos_bgp`) issues `delete protocols bgp` on hosts where `remove_vyos_bgp: true` so the previously-pushed iBGP config goes away.

### Upstream-fix opportunity

The customer `vyos` role already supports OSPF (per-interface `ospf: true` flag). It does NOT currently support a `delete protocols bgp` opt-out per host — adding that as a first-class capability (`remove_protocols: [bgp]` host_var?) would let other ranges do the same shift without an overlay play. See companion entry on the customer's `vyos` role's BGP-only redistribute pattern (2026-06-09 entry above).

---

## 2026-06-16 · platform · SimSpace pfSense image — management vNIC provisioned outside VMware MAC pool, lands on infrastructure network instead of range mgmt (LIKELY RESOLVED)

> **Status update 2026-07-08:** Every fresh-range PowerPlant deploy since 2026-07-02 has come up with all three pfSense hosts reachable over mgmt (`10.255.240.190/191/197`) on the first boot. The 3-for-3 `02:00:00:00:00:XX` MAC pattern documented below has not recurred. Either SimSpace patched the image's `managementInterface` provisioning code path, or the blueprint moved off the affected image variant. Entry retained for historical context and the reproducer methodology; verify against the current live image before assuming the issue is fully gone.


The SimSpace `RC_pfSense:1.0.0` image provisions the **management vNIC** (vmx0) through a different platform code path than the data-plane vNICs (vmx1+). The management vNIC ends up with:

- A **locally-administered MAC** in the `02:00:00:00:00:XX` range (sequentially allocated per VM — observed `:21`, `:26`, `:34` across pp-external-firewall, pp-internal-firewall, pp-ot-firewall in a single range deploy) instead of a MAC from VMware's `00:50:56:` OUI pool.
- Attached to what appears to be **SimSpace's internal infrastructure network** (DHCP lease from `10.41.241.0/24`, immediately withdrawn) instead of the range's documented mgmt vSwitch on `10.255.240.0/20`.
- Lease withdrawal causes `dhclient` to exit, leaving vmx0 with only an IPv6 link-local.

The three data-plane vNICs on each VM provision normally — proper `00:50:56:a8:XX:XX` VMware MACs, attached to the correct range vSwitches per the layout YAML's `networkInterfaces:` array. So the bug is narrowly scoped to the `managementInterface:` block handling.

**Reproducibility**: 3-for-3 across a fresh range deploy of PowerPlant on `ARBITR_PP_1328.yml`. Other VM image families (VyOS, Windows, Linux) in the same range deploy normally — only `RC_pfSense:1.0.0` is affected.

**Minimal reproducer (2026-06-16)**: a stripped-down test blueprint with 1 pfSense VM, 3 subnets, and 1 Ubuntu 22 workstation in each subnet — no Ansible, no post-deployment configuration, no `role:` hints on data-plane interfaces — reproduces the same `02:` MAC on the pfSense management vNIC. This removes the entire PowerPlant overlay (host_vars, playbook, role) as a variable. Bug is entirely platform-side in how SimSpace's provisioning handles the `managementInterface` block for VMs running the `RC_pfSense:1.0.0` image.

**Symptom from the pfSense console**:
```
[2.8.1-RELEASE][root@pfSense.home.arpa]/root: sh -c 'ifconfig vmx0 | grep ether'
        ether 02:00:00:00:00:21
[2.8.1-RELEASE][root@pfSense.home.arpa]/root: sh -c 'dhclient -d vmx0'
DHCPDISCOVER on vmx0 ...
DHCPDISCOVER on vmx0 ... interval 17
My address (10.41.241.169) was re-added
My address (10.41.241.169) was deleted, dhclient exiting
```

Hostname stays at factory `pfSense.home.arpa` because the platform's hostname-via-DHCP-option-12 flow also depends on the mgmt vSwitch attachment.

**Fix (upstream)**: SimSpace platform team needs to investigate the pfSense image's provisioning code path. The data-plane vNIC attach/MAC-allocate logic works fine; mimic it for the mgmt vNIC. Best repro evidence to file with the ticket: the 3-MAC sequential pattern (`02:00:00:00:00:21/26/34`) shows the allocation is deterministic, not random — which should be a clear pointer for the platform engineer.

**Workaround in PowerPlant overlay**: none currently feasible. Without a working mgmt vSwitch attachment, the Ansible host (which sits on `10.255.240.152` mgmt subnet) cannot SSH to the pfSense VMs. Options if SimSpace fix is delayed:

1. **Re-target Ansible through a data-plane SSH jump**: install a jump-host config so SSH to pfSense routes through `pp-www` (which has DMZ-side reach to pp-external-firewall via 172.16.8.x) and through `pp-internal-router` (which has INTERNAL transit reach to pp-internal-firewall via 172.16.0.26 ↔ 172.16.0.25). Brittle and hacky; only worth it for a long platform-fix wait.
2. **Bypass SimSpace YAML's `managementInterface` block**: define mgmt as just another `networkInterfaces:` entry (so it's allocated through the working data-plane code path). The `managementInterface.position` semantics may break, but the vNIC would attach to the right vSwitch.
3. **Wait for the platform fix** — preferred, since options 1 and 2 each introduce other maintenance burden.

Per the status update at the top of this entry (2026-07-08), every fresh-range deploy since 2026-07-02 has been unaffected. Retain the reproducer methodology (minimal blueprint, 3-MAC sequential pattern as diagnostic evidence) in case this recurs with a future image variant.
