# Upstream Fixes & Enhancements — range-development-ansible

Running log of issues, gaps, and suggested improvements discovered while deploying `ss-pp-ab`. Candidates for PRs or discussion with the `range-development-ansible` maintainers.

Severity key:
- **bug** — role malfunctions or produces incorrect results
- **gap** — missing functionality that ranges have to work around
- **enhancement** — works but could be more robust or ergonomic

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

## 2026-05-07 · gap · roles/common/tasks/windows.yml

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

**Update 2026-05-11:** the same TLS-to-Nexus failure recurs in **every** role that does `win_get_url` against Nexus on Server 2012 R2 — confirmed on `aue_agent` (`aue-agent-latest-setup-x86_64.exe`). PowerPlant workaround: added `ss-pp-ab/roles/prestage_aue_agent/` (controller→host WinRM copy + install) and a local override of `ss-pp-ab/roles/aue_agent/` that adds a `win_stat`-based skip-if-installed gate on the `win_get_url` task. The upstream `win_package` already has `creates_path` for idempotency; only `win_get_url` needed the gate. Expect this pattern to repeat for `drainhole`, `sysmon`, and any other role that hits Nexus on a Server 2012 R2 host. The clean upstream fix is to add a `<role>_local_path` opt-in variable on each download role, or to add a generic "use the local copy if `<playbook_dir>/files/<filename>` exists" preflight before any `win_get_url`.

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
