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

After `xIPAddress` applies a static IP, any leftover APIPA (`169.254.x.x`) address from a pre-static DHCP attempt stays on the adapter. Windows sometimes selects the APIPA as source address for outbound traffic, breaking routing. Observed on the `.2` workstation in every subnet during PowerPlant deploy — domain join failed with "The specified domain either does not exist or could not be contacted."

**Fix:** add a follow-up task to remove stale APIPA entries after IP configuration:
```yaml
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
