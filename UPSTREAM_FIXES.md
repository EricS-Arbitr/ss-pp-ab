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
