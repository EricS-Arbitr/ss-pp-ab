# PowerPlant — Action Plan to Finish

Drafted 2026-04-24. Current state per [PROJECT_LOG.md](PROJECT_LOG.md).

Phases are roughly sequenced, but items within a phase can run in parallel except where noted.

---

## Phase A — Validate the current build (gate before adding more)

Until the existing 18-play deploy comes up clean against the latest range, adding more plays just compounds debug surface. Do this first.

| # | Item | Acceptance criteria |
|---|---|---|
| A1 | Reprovision the range from `ARBITR_PP_122.yml` and run `./deploy.sh` end-to-end | Exits 0; PLAY RECAP shows zero `failed` and zero `unreachable` for every managed host |
| A2 | Verify BGP/OSPF convergence on each VyOS device | `show ip bgp summary` on every VyOS device shows all neighbors `Established`; `show ip route` on `pp-corp-router` lists routes to `172.16.8.0/24` (DMZ), `172.16.9.0/24` (security), `192.168.x.x` (OT) — none "directly connected" twice |
| A3 | Cross-subnet smoke test | From `pp-eng-wkstn-2`: `Test-NetConnection 172.16.2.7 -Port 389` → True; from `pp-www`: `nc -zv 172.16.2.3 445` → succeeds |
| A4 | Confirm domain join completes on all 28 `[members]` | `Get-ADComputer -Filter *` on `pp-dc01` lists all 28; no host stuck in WORKGROUP |
| A5 | Resolve `pp-eng-wkstn-1` connectivity (vNIC L2 attachment issue from Apr 21) | Host can ARP its gateway; if SimSpace reprovision didn't fix it, escalate to platform team |
| A6 | Verify `pp-ot-router` (image `RC_NG_OT_Router`) actually accepts the `vyos` role's commands | If it does: leave in `[vyos]`. If it doesn't: drop from `[vyos]`, treat as appliance, and either author a thin role or accept it self-configures from image |

**Exit criterion for Phase A:** A clean `./deploy.sh` run against a fresh reprovision, with the smoke-test commands succeeding.

---

## Phase B — Reach feature parity with reference playbook

Seven plays that exist in `range-development-ansible/playbook.yaml` but not yet in ours. Each gets added after Phase A is green.

| # | Play | Targets | What it does | Notes |
|---|---|---|---|---|
| B1 | `splunk` | `[splunk]` (`pp-splunk`) | Installs Splunk server + ES app | Need `splunk_license` URL accessible from proxy; `splunk_admin_password` in group_vars |
| B2 | `splunk-forwarder` | `[splunk-forwarder]` (every Windows + Linux that should ship logs) | Installs UF, points at `pp-splunk:9997` | New `[splunk-forwarder]` group needs to be defined in `hosts` |
| B3 | `hunt` | `[hunt]` (`win-hunt-1`) | `chrome` + `autologin` for SOC analyst | Already have `[hunt]` group |
| B4 | `crowdstrike` | `[crowdstrike]` (TBD) | Installs Falcon sensor with customer's `cs_customer_id` / `cs_group_tag` | Decide which subset gets it — full fleet or just the AD/AE hosts? |
| B5 | `sql2022` | `[sql2022]` (`pp-sql`) | Installs SQL Server 2022 | Need `[sql2022]` group; install URL in `windows.yml` already |
| B6 | `global_dns` | `[global_dns]` (`is-inet`) | External DNS simulation (containerized unbound) | Already have records in `all.yml` |
| B7 | `trafficgen` | `[trafficgen]` (`is-inet`) | Generates background traffic to mimic realistic network | Same target as global_dns; works with the `inet` simulation infra |

Each gets the same treatment: add play to `arbitr_pp_playbook.yaml`, populate any required `group_vars`, add inventory groups, run `build_tarball.sh`, test with `--tags <tag> --limit <host>` first, then full playbook run.

---

## Phase C — PowerPlant-specific roles for systems that don't have one

These hosts are in inventory but no play targets them. Each may need a custom role authored in `ss-pp-ab/roles/`.

| # | Host(s) | Function | Decision needed |
|---|---|---|---|
| C1 | `pp-mail` | Internal mail server (Win Server 2012) | Pick a mail stack — Exchange? hMailServer? Postfix on a Linux replacement? Implications for `internal_dns_records.mail` already pointing at it |
| C2 | `pp-wec` | Windows Event Collector | Configure WEF subscriptions; decide which channels (Security, Sysmon) and which sources |
| C3 | `pp-syslog` | Linux syslog collector | Decide collector (rsyslog vs journald-remote vs syslog-ng); receive from where (network devices, Linux hosts)? |
| C4 | `pp-dmz-dns` | External-facing DNS | What zones does it serve? Likely complements `global_dns` |
| C5 | `pp-dmz-smtp` | DMZ mail relay | Inbound? Outbound? Pair with `pp-mail` |
| C6 | `pp-ot-router` | New OT appliance | Confirmed in A6 — either keep in `[vyos]` or move to a new group with no role |

Author roles in dependency order: pp-syslog and pp-wec first (they're collectors others ship to), then mail stack (pp-mail/pp-dmz-smtp together), then pp-dmz-dns.

---

## Phase D — Upstream feedback to customer

Stop accumulating workarounds; push the `UPSTREAM_FIXES.md` items back to the customer.

| # | Item | Action |
|---|---|---|
| D1 | Format `UPSTREAM_FIXES.md` entries as discrete GitHub issues / PRs | One issue per entry; severity tag in title |
| D2 | Submit PRs for the obvious wins (typo `Ehternet0`, `static_route` README mismatch) | Tasks-match-README is the lower-friction direction |
| D3 | Discuss the harder items with the maintainer (vyos role not idempotent on reconfigure, deploy.sh retry semantics, additional_dc role) | Decide whether `additional_dc` belongs in their repo or stays a per-range role |
| D4 | Once `range-development-ansible` ships fixes, drop the corresponding entries from `ss-pp-ab/roles/` (keep only those not yet upstreamed) | Currently 3 custom roles; potentially 0 once everything's accepted |

---

## Phase E — Operational hardening

Quality-of-life improvements before handoff.

| # | Item |
|---|---|
| E1 | Add `--check` / `--diff` test runs to `deploy.sh` (or document the workflow) |
| E2 | Add `--verify` mode to `build_tarball.sh` that lists what will change without rebuilding |
| E3 | Document the customer Nexus URLs we depend on (every installer URL in `windows.yml` / `linux.yml`) — cache local copies if any are unreliable |
| E4 | Create a single `README.md` in `ss-pp-ab/` covering: what this overlay does, how to deploy, how to add a play, how to add a host, where to look for help |
| E5 | Vault the credentials in `group_vars/all.yml` and `group_vars/voltgrid.yml` (currently plaintext) |
| E6 | Periodically `diff` `ss-pp-ab/group_vars/{windows,linux,all}.yml` against `range-development-ansible/group_vars/*.yml` to catch missing installer/bootstrap vars before they trigger "undefined variable" errors at runtime. Trigger this whenever a new play is added, or build a `build_tarball.sh --verify` step that flags vars referenced by bundled roles but not present in any group_vars |

---

## Phase F — Cyber-range scenario validation (the real point of all this)

Once functionality is proven, validate that the range actually supports the planned exercises.

| # | Item |
|---|---|
| F1 | AUE simulation runs (autologin → user activity → network traffic) on each workstation subnet |
| F2 | AE simulation runs (servers in `[ae]` accept aue_agent driven activity) |
| F3 | Hunt persona on `win-hunt-1` can pivot through Splunk, query AD, RDP to workstations |
| F4 | Adversary scenarios (inbound from `red-net`, lateral via DMZ, OT pivot via gas-turbine sim) |
| F5 | Sign-off from whoever defined the training scenarios |

This is the success criterion the project actually exists for.

---

## Tracked outside this plan

- **`pp-eng-wkstn-1` L2 attachment** — flagged in A5; if it's a recurring SimSpace bug, escalate to that team rather than adding more host-side workarounds
- **VyOS interface naming gotcha** (mgmt shares the first data-plane eth) — already documented in `UPSTREAM_FIXES.md`. Watch for it on any future router additions
- **Image version drift** (`RDP_Windows_10:1.0.6` vs `1.1.0`) — pinned at 1.0.6 in 122 to avoid the DHCP-default issue. Re-evaluate when customer ships a fixed image

---

## Quick prioritization

If you have one day → **A1, A2, A3** (verify what we've already built actually works).

If you have one week → A1–A6, B3 (`hunt`), B5 (`sql2022`), and B6/B7 (`global_dns`/`trafficgen`) — plays with the smallest blast radius.

If you have one month → all of A–C plus E4 (the `README.md`), with D items submitted in parallel.
