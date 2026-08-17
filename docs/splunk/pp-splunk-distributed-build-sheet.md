# Distributed Splunk + Enterprise Security — PowerPlant Build Sheet

**Subsystem:** SIEM — indexer cluster, dedicated ES search head, management tier
**Enclave:** `security` — PP-Security `172.16.9.0/24` (gw `172.16.9.1`, `pp-internal-router`)
**Management:** all hosts dual-homed onto `10.255.240.0/20`; `ansible_host` is the mgmt IP
**Deployment:** 100% Ansible, blueprint-driven and hands-off
**Supersedes:** the single-instance `pp-splunk` running indexer + search head + Enterprise Security on one VM

**This is a MIGRATION, not an addition.** PowerPlant already runs Enterprise Security — `arbitr_pp_playbook.yaml` applies both `splunk` and `splunk-es` to `hosts: splunk`. Everything below splits three roles that currently share one box.

**This sheet is a plan. Nothing in it is built.**

---

## 1. What is different about PowerPlant

Two differences from the airfield sheet, and both cut in PowerPlant's favour.

**ES is already deployed and already sourced offline.** `roles/splunk-es` installs from `{{ ansible_installers }}/splunk/splunk-es.spl` and a directory of apps at `{{ ansible_installers }}/splunk/apps/*.tg*`, with `ansible_installers` = `/var/share/installers/` — pre-staged on the controller image. **The gating artifact problem in the airfield sheet (§8 there) does not exist here.** It is already solved, and this is the proven pattern airfield should copy rather than inventing a Nexus dependency.

**The variable migration is far simpler.** `splunk_server_ip` has exactly one functional consumer — `roles/splunk-forwarder/templates/outputs.conf.j2`. Airfield additionally derives `wazuh_manager_ip` from it, which PowerPlant does not. Nothing else silently follows a change.

**But one thing cuts against it: PowerPlant has ONE analyst workstation.** `[hunt]` contains `win-hunt-1` and nothing else. The ">10 concurrent analysts" driver that justifies a dedicated ES search head is not currently true here — see §11, decision 1. The ES-isolation argument stands on its own; the *sizing* argument does not, yet.

---

## 2. Host inventory

| Host | Role | PP-Security | mgmt | vCPU / RAM / disk | Status |
|---|---|---|---|---|---|
| `pp-splunk` | **ES search head** (dedicated) | 172.16.9.20 | 10.255.240.175 | 32 / 64 GB / 300 GB | **exists** — role changes, address unchanged |
| `pp-splunk-idx01` | Indexer, cluster peer | 172.16.9.21 | 10.255.240.209 | 16 / 32 GB / 1 TB | new |
| `pp-splunk-idx02` | Indexer, cluster peer | 172.16.9.22 | 10.255.240.210 | 16 / 32 GB / 1 TB | new |
| `pp-splunk-cm` | Cluster manager + license manager + deployment server + monitoring console | 172.16.9.23 | 10.255.240.211 | 8 / 16 GB / 100 GB | new |

**Addressing.** PP-Security currently uses `.1` (`pp-internal-router`), `.11` (`win-hunt-1`), `.20` (`pp-splunk`), and `.30/.35/.40–.42` (the Security Onion grid). `.21`–`.29` are free and contiguous. Management continues at `.209` — current high-water is `.208`.

`pp-splunk` keeps `172.16.9.20` deliberately: it is the analyst-facing address and `splunk_server_ip` currently points at it. What changes is what that address *means* — see §5.

---

## 3. Why split, given ES is already running

The single instance is indexer **and** search head **and** ES host. Those three have conflicting resource profiles, and ES is the one that loses:

- ES ships 100+ correlation searches on schedules. `max_searches_perc` reserves 50% of search concurrency for scheduled work, so on a combined box those compete directly with both ad-hoc analyst search *and* the indexing pipeline.
- **CIM data model acceleration runs on the indexing tier** and is typically the dominant load in an ES deployment — more than ingest. On a combined instance it competes with the searches it exists to serve.
- A single indexer means no replication. Losing it loses the data.

Splitting gives ES a search head whose scheduled work does not contend with indexing, and spreads acceleration across two peers.

**Two indexers, RF=2 / SF=2.** A third becomes worthwhile past a few hundred GB/day, which this range is nowhere near.

**One management node carrying four roles.** Cluster manager, license manager, deployment server and monitoring console are all light singletons. Splitting them costs three more VMs that must come up unattended and buys nothing here.

**No search head cluster.** The textbook answer above ~10 analysts is a 3-member SHC. Against it: ES on SHC requires the deployer with a fiddly app-deployment path, it triples ES-sized hardware, and it adds captain election and artifact replication to a deploy that runs with nobody at a keyboard. A search head failure in a training range is a restart, not an outage. **Revisit** when investigations must survive a search head failure, or concurrency passes ~20 analysts.

**Concurrency arithmetic** — `base_max_searches (6) + max_searches_per_cpu (1) × cores`, with 50% reserved for scheduled work:

| cores | total | scheduled (ES) | ad-hoc | analysts at ~1.5 concurrent |
|---|---|---|---|---|
| 16 | 22 | 11 | 11 | 7 |
| 24 | 30 | 15 | 15 | 10 |
| **32** | **38** | **19** | **19** | **12–13** |

**With one hunt box today, 16 cores is sufficient.** 32 is sized for the stated future. Choosing between them is decision 1.

---

## 4. Blueprint additions

Three new VMs. `pp-splunk` **is** explicitly sized today at 16 vCPU / 32 GB — `docs/security-onion/blueprint-additions.yml` records `so-manager` as "sized to match pp-splunk" at those values. (Airfield's equivalent had no `cpuCount`/`memory` at all and silently inherited the image default; PowerPlant does not have that problem.)

The ready-to-apply version of this section is `docs/splunk/blueprint-additions.yml`.

```yaml
# MODIFY — pp-splunk becomes the dedicated ES search head
- type: "range.resource.primitive.VmInstance::1.0.0"
  name: "pp-splunk"
  properties:
    cpuCount: 32                      # currently 16 — see decision 1
    memory: "65536"
    networkInterfaces:
    - name: "pp-security"
      ipAddress: "172.16.9.20"        # unchanged
      prefix: 24
    managementInterface:
      ipAddress: "10.255.240.175"     # unchanged
      position: "FIRST"

# NEW — indexer cluster peers
- type: "range.resource.primitive.VmInstance::1.0.0"
  name: "pp-splunk-idx01"
  properties:
    cpuCount: 16
    memory: "32768"
    networkInterfaces:
    - name: "pp-security"
      ipAddress: "172.16.9.21"
      prefix: 24
    managementInterface:
      ipAddress: "10.255.240.209"
      position: "FIRST"

- type: "range.resource.primitive.VmInstance::1.0.0"
  name: "pp-splunk-idx02"
  properties:
    cpuCount: 16
    memory: "32768"
    networkInterfaces:
    - name: "pp-security"
      ipAddress: "172.16.9.22"
      prefix: 24
    managementInterface:
      ipAddress: "10.255.240.210"
      position: "FIRST"

# NEW — management tier
- type: "range.resource.primitive.VmInstance::1.0.0"
  name: "pp-splunk-cm"
  properties:
    cpuCount: 8
    memory: "16384"
    networkInterfaces:
    - name: "pp-security"
      ipAddress: "172.16.9.23"
      prefix: 24
    managementInterface:
      ipAddress: "10.255.240.211"
      position: "FIRST"
```

Use the same image the existing SO grid nodes run, for consistency with what the platform has proven on this range.

**Indexer disk is retention-driven and 1 TB is a placeholder** until a retention window is chosen (decision 2).

---

## 5. Inventory, group_vars, host_vars

`splunk_server_ip` is `172.16.9.20` at line 21 of `group_vars/all.yml` (on `main`) or
`group_vars/all/main.yml` (on `security-onion` — the branches diverge here) and means
"the indexer". After the split, `.20` receives nothing.

```yaml
# group_vars/all.yml on main, group_vars/all/main.yml on security-onion
splunk_indexers:                        # NEW — the receiving tier
  - "172.16.9.21"
  - "172.16.9.22"
splunk_forwarder_port: "9997"
splunk_search_head_ip: "172.16.9.20"    # NEW — analyst-facing, receives nothing
splunk_cluster_manager_ip: "172.16.9.23"
splunk_replication_port: "9887"
splunk_rf: 2
splunk_sf: 2
# splunk_server_ip: RETIRED — migrate its one consumer deliberately rather
# than redefining it, so nothing inherits the old meaning by accident.
```

Only one functional consumer to migrate: `roles/splunk-forwarder/templates/outputs.conf.j2`, which renders `server = {{ splunk_server_ip }}:{{ splunk_forwarder_port }}` and a matching `[tcpout-server://…]` stanza. Both become the indexer list. `roles/splunk-forwarder/README.md` also references the variable and should be updated so it stops documenting the retired name.

**Prefer indexer discovery** via the cluster manager over the static list, so a third indexer later needs no forwarder change.

New groups:

```ini
[splunk_search_head]
pp-splunk

[splunk_indexer]
pp-splunk-idx01
pp-splunk-idx02

[splunk_cluster_manager]
pp-splunk-cm

[splunk_cluster:children]
splunk_search_head
splunk_indexer
splunk_cluster_manager
```

`[splunk-forwarder:children]` enumerates `domain_controllers`, `corporate_servers`, `dmz` and `workstations`, so the new Splunk hosts are **not** in it — good. Confirm none of them land in those groups when added, or they will forward to themselves.

The six `win-hunt-*` boxes **are** direct members of `[splunk-forwarder]` as of 2026-08-17, alongside `pp-proxy`. They are deliberately *not* in `[workstations]`: that group means "the simulated business's user endpoints", and while it feeds nothing but the forwarder group today, a future play targeting it for scenario activity or attack simulation should not silently include the blue team's own tooling.

---

## 6. Existing indexed data

`pp-splunk` currently holds every indexed bucket. After the split it is a search head and stores none.

For a range rebuilt between exercises this is a non-issue — a fresh deploy starts empty either way. **If this migration is ever applied to a running range with data worth keeping**, the buckets on `pp-splunk` do not move by themselves and become unsearchable. Either accept the loss, or plan a bucket migration separately; it is not in scope here.

The existing indexes (`windows`, `sysmon`, `linux`, `netfw`, `proxy`, `mail`) must be created **on the peers via the cluster manager's `manager-apps`**, not by editing peers directly. ES adds its own (`notable`, `risk`, `threat_activity`, …) the same way.

---

## 7. Roles

| Role | Runs on | Does |
|---|---|---|
| `splunk_cluster_manager` | `splunk_cluster_manager` | installs Splunk, cluster-manager mode with RF/SF, license manager, MC, deployment server |
| `splunk_indexer` | `splunk_indexer` | installs Splunk, joins as peer, enables receiving on 9997, license peer |
| `splunk_search_head` | `splunk_search_head` | installs Splunk, joins the CM as a search head, license peer |
| `splunk-es` (existing) | `splunk_search_head` | **mostly unchanged** — already installs from pre-staged artifacts; only its target group changes |
| `splunk_cim` | SH + peers via CM | CIM add-on, TAs, enable chosen accelerated data models |
| `splunk` (existing) | — | **narrow or retire** — it currently does single-instance indexer + search head |
| `splunk-forwarder` (existing) | unchanged | only its `outputs.conf` target changes |

`pass4SymmKey` and the cluster secret into `group_vars/all/vault.yml` beside the existing Splunk credentials.

---

## 8. Deployment order

1. **Cluster manager** — must exist before any peer can join
2. **Indexers** — join the cluster, enable receiving
3. **Search head** — connects to the CM as a search head
4. **ES** on the search head (existing role, retargeted)
5. **Indexes app pushed to peers via the CM** — both the range's six and ES's own
6. **CIM add-on and TAs**, then enable acceleration
7. **Forwarders repointed** to the indexers
8. **Verification** (§10)

Steps 5 and 7 are the ones most often got wrong: pushing indexes to peers by hand instead of through the cluster manager, and repointing forwarders before the indexers are receiving.

---

## 9. CIM normalization — still the larger half

ES is installed here, but **ES correlation searches fire off accelerated data models, not raw events.** Whether PowerPlant's data is CIM-compliant today is unverified and should be checked before assuming the split alone improves anything:

```
| tstats count from datamodel=Authentication where nodename=Authentication by sourcetype
```

If that returns little or nothing, the models are not being populated and ES has been generating few notables regardless of hardware.

Required add-ons: `Splunk_TA_nix`, `Splunk_TA_windows`, a Sysmon TA. pfSense and VyOS have no first-party TA and need sourcetype definitions written — note that `netfw` is listed as "currently unused; reserved for pfsense/vyatta syslog when wired up", so that feed may not exist yet at all.

Accelerate only the models the scenarios exercise — Authentication, Network_Traffic, Endpoint, Malware, Web. Every accelerated model is continuous indexer load, and the default set is larger than what this range feeds.

---

## 10. Acceptance tests

Each asserts an **outcome**, not that a service is running. Six defects in this project have come from checks that measured the transport and reported it as the outcome; see `UPSTREAM_FIXES.md`.

| # | Test | Pass |
|---|---|---|
| 1 | `splunk show cluster-status` on the CM | all peers Up, **search factor met**, replication factor met |
| 2 | `| rest /services/search/distributed/peers` on the SH | both indexers, status `Up` |
| 3 | Ingest reaches **both** peers | `| tstats count where index=* by splunk_server` returns both, non-zero |
| 4 | A UF on an arbitrary host | `splunk list forward-server` shows both indexers active |
| 5 | Indexes exist **on the peers** | the six range indexes plus ES's, present on both, pushed via CM |
| 6 | Data model acceleration progressing | each enabled model >0% and advancing between two samples |
| 7 | **ES generates notables** | `index=notable` non-zero within 24h — the test that proves ES is wired to the data |
| 8 | Concurrency headroom under load | ad-hoc slots remaining |

Test 7 is the one that matters. Tests 1–6 can all pass while ES produces nothing, because they verify plumbing and ES fires off *models*.

---

## 11. Open decisions

1. ~~**Analyst count**~~ — **RESOLVED 2026-08-17:** `pp-splunk` resized to 32 vCPU / 64 GB, and `[hunt]` grown from one workstation to six (`win-hunt-1`..`6`, `172.16.9.11`–`.16`). All six are now in `[members]` and domain-joined — `win-hunt-1` never had been. Six analyst workstations does not yet reach ">10 concurrent analysts", so the search head sizing still carries headroom beyond present need; adding `win-hunt-7`..`12` at `.17`–`.19` and `.24`–`.26` would close that gap.
2. **Retention window** — drives indexer disk; 1 TB is a placeholder.
3. **Which data models to accelerate** — §9 proposes five, contingent on the CIM check.
4. **Is `netfw` wired up?** It is listed as reserved. Network_Traffic has no feed without it.
5. **Bucket migration** — only if this is ever applied to a range whose data matters (§6).

---

## 12. Build-time version checklist

- Splunk Enterprise — must match across CM, peers and SH; version skew between search head and peers is unsupported
- Splunk Enterprise Security — check the ES↔Enterprise compatibility matrix before pinning
- Splunk CIM add-on
- `Splunk_TA_nix`, `Splunk_TA_windows`, Sysmon TA
- Universal Forwarder — a UF newer than the indexers is unsupported

Record resolved versions here once chosen.
