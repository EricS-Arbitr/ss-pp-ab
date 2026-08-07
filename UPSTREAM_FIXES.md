# Upstream Fixes & Enhancements — range-development-ansible

Running log of issues, gaps, and suggested improvements discovered while deploying `ss-pp-ab`. Candidates for PRs or discussion with the `range-development-ansible` maintainers.

Severity key:
- **bug** — role malfunctions or produces incorrect results
- **gap** — missing functionality that ranges have to work around
- **enhancement** — works but could be more robust or ergonomic

---



## 2026-08-07 (later 2) · bug · Every tarball shipped so far was ~50% AppleDouble junk, and macOS tar cannot see it

**Symptom.** `sudo tar xzvf ab_pp.tgz` on the controller listed a `._` companion
beside almost every real file.

**Measured, not estimated.** The archive at commit `0750421` — the one deployed —
contained:

```
members=942   junk=471
```

Exactly one `._` companion per real file. Half the archive, on every deploy
since the project began.

**Cause.** Apple's `tar` emits an AppleDouble `._name` member for any file
carrying an extended attribute, and `com.apple.provenance` is set on anything
downloaded, which covers most of a checked-out repo.

**`--no-xattrs` does not suppress them.** The build had carried that flag with a
comment claiming it did. Measured on a directory containing one xattr'd file:

| build | members | junk |
|---|---|---|
| plain `tar` | 4 | 2 |
| `tar --no-xattrs` (what we shipped) | 4 | 2 |
| `COPYFILE_DISABLE=1 tar` | 2 | 0 |

`COPYFILE_DISABLE=1` is the load-bearing setting.

**Why it went unnoticed for the entire project — and this is the real lesson.**
Apple's `tar -tzf` **HIDES** AppleDouble members when listing, merging them back
into xattrs. So:

```
tar -tzf ab_pp.tgz | grep -c '\._'   ->  0        (macOS: structurally blind)
python3 tarfile getnames()           ->  471      (the truth)
```

I checked with `tar -tzf` and reported "0 junk entries in the archive" — a check
that could not have detected the defect it was written for. Not a proxy for the
claim this time, but a TOOL incapable of observing it. The same class as
`so-elastic-agent-status | grep -c healthy`: the measurement was fine, the
instrument was wrong.

**Fix (both repos).**
- `COPYFILE_DISABLE=1` on the tar invocation.
- `--exclude='.DS_Store' --exclude='._*'` as a second layer.
- `find "$STAGE" \( -name '.DS_Store' -o -name '._*' \) -delete` across the
  whole stage, not just `files/` as before.
- Verified with `python3 tarfile`, not macOS tar: ss-pp-ab 471 members / 0 junk,
  so-ansible 131 / 0.

**Consequence on the target, worth acting on separately.** `tar -xzf` is
ADDITIVE — it never removes files absent from the archive. Every one of those
471 junk files persists in `/etc/ansible`, as does anything ever shipped and
later deleted. `roles/so_sensor/tasks/gre_tunnel.yml`, removed from the repo on
2026-08-05, is still on the controller. Nothing references it, but a stale role
or a renamed task file would be a live hazard. The durable fix belongs in the
blueprint: extract into a clean `/etc/ansible` rather than over the previous
one.

**Status: VERIFIED** for the build fix — measured before and after with a tool
that can see the difference.

## 2026-08-07 (later) · bug · Fresh blueprint deploy needed 3 attempts — two unrelated timing defects in the range baseline

**Symptom.** A hands-off, blueprint-driven deploy succeeded only on attempt 3.
Three multi-hour sweeps for one range, and no margin: had attempt 3 failed
there would have been nothing.

From `/var/log/playbook_run.log`, the two attempts failed for DIFFERENT reasons.

### 1. Windows WinRM readiness — `init` waits 60s (customer repo)

```
fatal: [pp-eng-wkstn-5]: "elapsed": 90, "msg": "timed out waiting for ping
module test: ... port=5985 ... Connection refused"
```

Four hosts (pp-eng-wkstn-5/6/7, pp-is-wkstn-3).
`range-development-ansible/roles/init/tasks/main.yaml` waits
`delay: 30` + `timeout: 60` — exactly the observed `elapsed: 90`. Sixty seconds
is not enough for a cold Windows boot on a freshly provisioned range, even
after `deploy.sh`'s `BOOT_DELAY=180` had already elapsed.

**Fix upstream:** raise the timeout in the base role, or expose it as a
variable. It is currently hardcoded.

**Workaround (overlay):** `roles/init/` locally, timings driven by
`init_wait_timeout` (900), `init_wait_delay` (15), `init_wait_sleep` (10). Task
names deliberately unchanged so logs stay comparable with the base role.

**Why not simply raise `BOOT_DELAY`:** that penalises EVERY deploy including
re-runs where everything is already up. A longer `wait_for_connection` costs
nothing when the host is ready — it returns as soon as the connection succeeds.
The blunt lever was already in the wrong place; a second blunt lever would not
help.

### 2. Domain join has no precondition — `domain_member_retry` (customer repo)

```
fatal: [pp-ls-wkstn-5]: "Computer 'pp-ls-wkstn-5' failed to join domain
'voltgrid.com' ... The specified domain either does not exist or could not be
contacted."
```

Failed on attempt 2 (twice — the role's own retry) and again on attempt 3.

`domain_member_retry` already retries with a reboot, but never checks whether
the DOMAIN is reachable: it joins, waits 45s, verifies, reboots, joins again.
When DNS is not yet answering, both attempts fail identically and the retry
adds nothing but time.

pp-ls-wkstn-5 is configured IDENTICALLY to pp-ls-wkstn-4 and -6 — same subnet,
same DNS server (172.16.2.7), adjacent addresses. Not a config defect; it
simply reached the join before the DC was answering.

**Fix upstream:** `domain_member_retry` should wait for the domain to be
resolvable before its first attempt, not only retry after failing.

**Workaround (overlay play):** `pre_tasks` on the Join Domain play waiting for
`_ldap._tcp.dc._msdcs.<domain>` to resolve — the SRV record domain join
actually looks up, so it is the precondition itself rather than a proxy like
"can I ping the DC". `-DnsOnly` prevents LLMNR/NetBIOS answering falsely
(CLAUDE.md pitfall 4). 30 × 20s, then a fail naming the host's configured DNS
server.

**A bug caught by rendering the failure message.** The diagnostic used
`selectattr('ipv4.dns', 'defined')`, but `dns` is a SIBLING of `ipv4` in
`network_interfaces`, not nested. It would have rendered "unknown" at best —
and the expression only evaluates INSIDE the failure path, so a template error
there would have replaced the diagnostic at exactly the moment it was needed.
Corrected and rendered against real host_vars plus two degenerate cases (a host
with no `dns` key, a host with no `network_interfaces` at all).

**Branch note.** Both fixes are to the RANGE BASELINE, not Security Onion, so
they would benefit the Splunk-only range too. Applied to `security-onion` only
for now by decision; to be pushed to `main` once verified on a fresh deploy.

**Status: PROPOSED** — verified by build (the local `init` overlay is the one
bundled) and by rendering; the real test is a fresh blueprint deploy reaching
success on attempt 1.

## 2026-08-07 · enhancement · pp-splunk generated 96% of its telemetry as file events — Defend exclusions via SO's own mechanism

**Finding.** `host.name: "pp-splunk" | groupby event.dataset` over 24h:

```
endpoint.events.file      11,147,502   (96%)
endpoint.events.process      410,342
system.syslog                 65,182
endpoint.events.network       33,463   (0.3%)
```

Flat at ~480,000/hour across the whole window — constant, not bursty.

**My first theory was wrong and worth recording.** I predicted network events
would dominate, reasoning that pp-splunk terminates 9997 from ~40 forwarders.
Network was 0.3%. The driver is Splunk writing its own index buckets: bucket
rotation, journal slices and tsidx files under `/opt/splunk/var/lib/splunk/`,
each logged as a file event. A database journaling to disk, one event at a
time.

**Why it matters beyond dashboard tidiness.** 11.1M events/day from one host
dominates Elasticsearch retention, ageing out the corp-workstation telemetry
actually worth hunting on. The agent stays — a SIEM indexer is a high-value
target and "someone logged in and stopped a service" is exactly what endpoint
telemetry is for. Only the bucket churn goes.

**Mechanism — SO ships the seam.** `so-elastic-defend-manage-filters.py` runs
from `config.sls`/`enabled.sls` and on a 03:00 cron, reading
`-i /opt/so/conf/elastic-fleet/defend-exclusions/rulesets/custom-filters/`.
Facts read from the script rather than guessed:

```python
"TargetFilename": "file.path"          # generic ECS -> works on Linux
"file_create"/"file_delete": "endpoint.events.file"
"begin with": ("included", "wildcard")
```

Three consequences: `TargetFilename` is not Windows-only despite every one of
the ~250 filters SO ships being Windows; `operating_system` is never read by
the script, so filters are grid-wide; and the script itself converts
`custom-filters-raw` into the `custom-filters/` directory.

**Delivery — the soc.json trap again.** `custom-filters-raw` is
`file.managed` from `salt://elasticfleet/files/soc/elastic-defend-custom-filters.yaml`,
so writing it directly is reverted by the next highstate. We override the
SOURCE in `local/salt/`, which precedes `default/salt` in `file_roots` — the
same technique as the GRE `iptables.jinja` override. The stock file holds only
non-functional templates (`id: 'This needs to be a UUIDv4 id'`), so replacing
it wholesale loses nothing.

**Placement.** Included above the `end_host` probe as well as below it, like
`airgap_mode.yml`: the filters live in Fleet's database, so a rebuilt manager
loses them and only a re-run restores them (PORTING_GUIDE 9.4b).

**Scope safety.** Because the helper ignores `operating_system`, a path filter
applies grid-wide. `/opt/splunk/var/lib/splunk/` exists on exactly one host, so
it cannot blind another. That property is a precondition for this approach, not
an accident — noted in the variable's comment for whoever adds the next filter.

**A bug caught by testing the render, not by reading it.** The description
contained "96% of that host's telemetry". YAML single-quoted scalars escape a
quote by DOUBLING it, so the apostrophe truncated the scalar and the document
failed to parse. The file would have been written successfully and broken
inside the helper. Every interpolated value now passes through
`replace("'", "''")`. Rendered locally with Jinja2 and parsed with
`yaml.safe_load_all` before shipping — 2 documents, all 10 required keys,
schema matching SO's shipped examples.

**Verification in the play** asserts our rule IDs appear in the GENERATED
`custom-filters/` directory — proving both that the override reached the raw
file and that the conversion consumed it — rather than trusting that the
helper command exited 0.

### FIRST RUN UPLOADED NOTHING, AND MY CHECK SAID IT WORKED

The play reported `2 Defend exclusion(s) active`. Nothing had been uploaded:

```
Error with POST request: 404 -
  {"message":"exception list id: \"endpoint_event_filters\" does not exist"}
```

**Why it lied.** The verification asserted our rule IDs appeared in the
GENERATED `custom-filters/` directory. That is a real check of a real thing —
it proves the `local/salt` override reached the raw file and the raw→directory
conversion consumed it. It says NOTHING about whether Fleet accepted them.
Directory presence is two steps upstream of the claim. I verified the proxy and
reported the claim, in the same commit whose message said the check "asserts
our rule IDs appear in the GENERATED directory... rather than trusting that the
helper command exited 0" — I correctly avoided trusting the exit code and then
trusted something equally uninformative.

It surfaced only because the report echoed the helper's stdout. Without that
line the play was green, file events would have continued, and the next hours
would have gone into Defend's Linux field mappings.

**Root cause — the list does not exist.** Read from
`so_elastic_defend_filters_helper.py`: the only URL it ever builds is
`http://localhost:5601/api/exception_lists/items`. It POSTs items; it never
creates the list. Elastic Security creates `endpoint_event_filters` lazily on
first use of the Event Filters UI, so on a grid nobody has clicked through, it
does not exist and every POST 404s.

Also learned: plain **HTTP on 5601**, not HTTPS — my earlier probe used https
and returned nothing, which I misread as "Kibana unreachable".

**And there is no defend cron at all.** `crontab -l` has no defend entry, so
`defend_filters.enable_auto_configuration` is off. This is not SO failing
nightly — the whole mechanism is disabled by default, which is why the list was
never created by SO either. **SO's own ~250 shipped Windows filters have
therefore never applied on this grid.** Separate decision, not taken here:
whether to enable that ruleset.

**Fix.**
- Create the list first with an idempotent POST to `/api/exception_lists`
  (`type: endpoint_events`, `namespace_type: agnostic`), accepting 200 or 409,
  using the same URL and `curl.config` credentials the helper uses.
- Verification now queries **Kibana** for each rule by `item_id` — the key the
  helper itself uses (`api_request` builds `?item_id={guid}`) — and requires
  HTTP 200. The filesystem check is gone.
- The report no longer says "active". It says CONFIRMED present in Kibana, and
  separately counts errors the helper reported for other rules.

### Run 2: list created, SO's own ruleset unblocked, one rule rejected on LENGTH

The list-creation POST worked. Consequences beyond our two filters: **SO's ~250
shipped Windows filters are now loading for the first time on this grid** —
`_find` returns pages of `SO - network_connection - <guid>` items. They had
never applied because nothing had ever created the list.

Of our two, `file_delete` returned 200 and `file_create` 404. Not dedup (my
guess), and the helper said so plainly:

```
400 - EndpointArtifactError: [description]: value has length [263]
      but it must have a maximum length of [256].
```

**A measurable fact fell out of that.** The source description was 204
characters and Kibana saw 263, so the helper prepends exactly **59** characters
of its own. Budget for the source is therefore 197, not 256.

**And the helper's own reporting is not trustworthy.** The same run printed:

```
Processing Summary
 - New rules: 1
Rule status Summary
 - Active rules: 2
```

"Active rules: 2" while one POST was returning 400. Anything keyed on the
helper's summary — including a human reading it — would have concluded success.
Only the per-item Kibana query caught it, which is the check that replaced the
filesystem one earlier the same day.

**Fix.** Descriptions shortened (130 and 97 chars), plus an assert in the play
that fails when a source description exceeds 190. The assert runs BEFORE the
render, so a too-long description fails immediately and names the field, rather
than surfacing several tasks later as a Kibana 404 with no indication of cause.

### Run 4: the filter was correct in every respect except the one that matters

Rate after applying: **230,836 in 30 minutes** — ~460k/hour, completely
unchanged. The stored item explains it:

```json
"entries": [
  {"type":"wildcard","field":"file.path","value":"/opt/splunk/var/lib/splunk/*"},
  {"type":"match","field":"event.dataset","value":"endpoint.events.file"}
],
"os_types": ["windows"]
```

Dataset right, field right, wildcard right — `modify_pattern` appends the `*`
correctly. **`os_types: ["windows"]` on a Linux host.** Defend never evaluates
it. Line 87 of `so-elastic-defend-manage-filters.py` hardcodes it, and
`operating_system` is read nowhere in that directory.

**This is an upstream gap worth reporting.** `TARGET_FIELD_MAPPINGS` maps
`TargetFilename` to `file.path` — the generic ECS field, chosen precisely
because Linux uses it — and then every item the tool creates is stamped
Windows-only. The mechanism is one line away from supporting Linux.

**My earlier claim was wrong and I stated it as fact.** When designing this I
wrote that "`operating_system` is NOT read by the script, so filters are
grid-wide", and built the whole approach around path-uniqueness on that basis.
I concluded it from a grep against the wrong file returning empty. An empty
grep is not evidence of absent behaviour — the same mistake I had already made
once in this thread with the HTTP layer, which also lived in the other file.

**Path scope was also too narrow.** Events showed churn under BOTH
`/opt/splunk/var/lib/` (buckets, tsidx, .merge from splunk-optimize) and
`/opt/splunk/var/run/` (dispatch artifacts, splunkd.pid from splunkd). Now
`/opt/splunk/var/*`. `bin/` and `etc/` stay monitored — app code and config are
what an attacker modifies.

**Two filters collapsed to one.** `file_create` and `file_delete` both map to
`endpoint.events.file`, so both produced byte-identical entries; that is why
the second reported "up to date" while doing nothing. One item keyed on the
dataset covers creates, deletes and renames.

### Rewritten to manage the filters directly

SO's helper cannot express what we need, so the play now calls the Kibana API
itself — same endpoint and credentials the helper uses. Safe to self-manage:
`disable_check` only deletes a GUID listed in `disabled-filters.yaml`, and
`process_rules` only iterates its own input directories. It never enumerates
the list, so it cannot touch items it did not create.

DELETE-then-POST rather than PUT: both verbs have observed behaviour on this
grid, whereas PUT's body schema differs. After this many surprises, using only
calls we have watched work is worth a moment of churn on a static filter.

The play also removes the superseded `local/salt` override and the generated
YAMLs, because they carry the SAME item_ids and would recreate Windows-scoped
copies if the helper ever ran.

**Verification now reads the item back and asserts `os_types` and the match
value** — the two fields that were wrong while the previous check reported
success. Presence was never the question.

### Run 3: both filters confirmed in Kibana

```
2 Defend exclusion(s) CONFIRMED present in Kibana's endpoint_event_filters
list. Helper reported no errors.
```

`failed=0`, and the per-item Kibana query returned 200 for both UUIDs.

**Status (run 3): VERIFIED — for PRESENCE only.** The filters exist in the list; that is
what the check proves and all it proves. Whether they actually suppress
`endpoint.events.file` from pp-splunk is a separate claim requiring a separate
measurement: `host.name: "pp-splunk" | groupby event.dataset` a few hours out,
showing file events collapsed with process/syslog/network unchanged.

Keeping those two claims apart is the entire lesson of this entry's history —
"the rule is in the generated directory" was asserted as "active", and "the
helper ran" was printed as "Active rules: 2" while a POST was 400ing. Presence
is not effect.

## 2026-08-05 (later 5) · enhancement · deploy.sh made hands-off — the blueprint runs it, nobody is at a keyboard

**Requirement.** These deploys are driven by the range BLUEPRINT: the platform
spins the images, pulls the tarball from GitHub, extracts it and runs
`deploy.sh`. Any step that previously read "now run these three commands by
hand" is a defect, not documentation.

**Two things extraction leaves wrong.**
- `/etc/ansible/retry` is root-owned, because the tarball extracts as root. The
  ansible user cannot write retry files — every failed run printed
  `Could not create retry file ... Permission denied`, and attempt 2 lost its
  retry-file scope and silently degraded to a full sweep.
- `/home/simspace/.vault_pass` is placed by the platform with its value, but
  not necessarily with ownership and mode this account can read. `0600
  root:root` is unreadable to `simspace`, and every vaulted variable resolves
  through it.

**Fix.** `deploy.sh` corrects both itself, before the vault guard. Details that
matter:

- **`sudo -n`** throughout, via an `as_root` helper that calls directly when
  already uid 0. Non-interactive is the point: a sudo password prompt would
  hang a headless deploy forever on stdin rather than failing.
- **Fix only what is actually wrong**, judged by BEHAVIOUR — can this account
  write the retry dir, can it read the password file — not by comparing
  ownership metadata. A first attempt chown'd unconditionally and emitted five
  `sudo: a password is required` warnings on every clean run. It is also the
  correct assertion: `0600 root:root` is broken, but so is any other
  combination that leaves the file unreadable.
- **Readability, not existence.** The old guard checked `[ -f ]`. A file that
  exists but cannot be read fails much later as a confusing vault decrypt
  error on the first vaulted variable. Now `head -c1` proves the deploy can
  actually read it, and an empty file is rejected too.
- **Asymmetric severity, deliberately.** An unfixable vault password ABORTS —
  nothing will work without it. An unfixable retry dir WARNS and continues —
  it only costs retry-file scoping. Treating them the same would either block
  deploys for a cosmetic problem or let a fatal one through.

**Tested against five cases** before shipping, not reasoned about:

| case | result |
|---|---|
| retry writable, vault readable (normal) | silent, exit 0 |
| vault password missing | exit 1, message points at the blueprint |
| vault password empty | exit 1 |
| vault password unreadable, unfixable | exit 1, prints `ls -l` |
| retry dir unfixable | WARN, exit 0, deploy proceeds |

All paths overridable via `ANSIBLE_OWNER`, `VAULT_PASS_FILE`, `RETRY_DIR`.

**FIRST VERSION WAS WRONG — corrected same day.** The "fix only what is
actually wrong" optimisation gated the chown on
`[ ! -w "$RETRY_DIR" ]`. A blueprint-driven `deploy.sh` runs as **root**, for
whom the directory IS writable, so the condition was false and the chown was
skipped — on precisely the run it was written for. Observed on the first real
blueprint deploy: `/etc/ansible/retry` still `root:root` while the playbook ran.

I optimised for a case that does not occur (interactive run without sudo) and
broke the one that does.

**Corrected.** chown/chmod now run UNCONDITIONALLY — they are idempotent and
cost milliseconds, so there is no reason to guess whether they are needed. The
requirement is an END STATE (owned by the ansible user), not "writable by
whoever happens to be running". The script then verifies that end state with
`stat` and warns with the ACTUAL owner if it is still wrong.

Command-level failures are silent by design: reporting "chown failed" when the
ownership was already correct is the same proxy-versus-claim mistake this log
catalogues throughout. The end-state check is the only voice.

**Status: VERIFIED** for the logic — clean path silent, wrong-owner path warns
with the real owner and continues, missing/empty/unreadable vault password all
abort. Exercised end-to-end on the next blueprint-driven deploy.

## 2026-08-05 (later 4) · bug · MY build_tarball change silently stopped packing — seven commits shipped a stale tarball

**Symptom.** After the ICMP fix, `md5 ab_pp.tgz` was byte-identical to the
previous build despite `roles/so_sensor` having changed. `git ls-tree` across
the structural pass confirmed it:

```
31c698c  7aa58abb8f83   (last real rebuild)
6410120  7aa58abb8f83   structural pass 1/5
c5ed531  7aa58abb8f83   2/5
e8bd415  7aa58abb8f83   3/5
b862183  7aa58abb8f83   4/5
9d7f525  7aa58abb8f83   5/5
bd6f9fb  7aa58abb8f83   "structural pass VERIFIED"
36d4997  7aa58abb8f83   ICMP fix
```

One blob across eight commits. The tarball had not been rebuilt since before
the structural pass began.

**Cause — mine, introduced in structural pass 1/5.** `build_tarball.sh` runs
under `set -euo pipefail` (line 21). The verify call had been
`python3 verify_vars.py "$STAGE" || true`, and I replaced it with a bare call
plus `VERIFY_RC=$?` in order to abort on scope errors. Under `errexit`, the
bare call's **exit 1 — which happens on EVERY run, since there are three
standing soft warnings — killed the script before the Pack step.**

The irony is exact: a change made to stop bad code reaching the range instead
stopped ALL code reaching the range.

**Why it went unnoticed for seven commits.** I ran `./build_tarball.sh
>/dev/null 2>&1` in the commit sequence and never checked its exit status;
where I did tail the output, the last lines were the verify warnings, which
look like a normal ending. "=== Archive built ===" was absent from every one of
those runs and I did not miss it. And `md5` was printed from a file that simply
had not changed — a value I reported to the operator as if it identified the
build.

**Fix.**

```bash
VERIFY_RC=0
python3 "$SS_PP_AB/verify_vars.py" "$STAGE" || VERIFY_RC=$?
```

`||` satisfies `errexit` while preserving the code. Verified: exit 0, "Archive
built" printed, md5 changed, and the archive now demonstrably contains the
structural-pass content (checked by extracting `so_search`/`so_sensor` from the
tarball and grepping for the new tasks).

**Lesson, and it is the same one as the check audit.** I verified the *change*
(scope errors now abort) and not the *invariant* (the build still produces an
archive). A guard added to a pipeline must be tested for what it does on the
PASSING path, not only the failing one. The passing path here ran on every
single build and was broken from the first.

**Consequence for the operator.** The deploy tested against "9d7f525" pulled
the `31c698c` archive. Whatever it exercised, it was not the structural pass —
so those five entries' VERIFIED status is withdrawn pending a real run.

**Status: VERIFIED** for the build fix (archive rebuilds, contents confirmed).
Structural pass 1/5–5/5 revert to PROPOSED.

## 2026-08-05 (later 3) · bug · Sensors were injecting ICMP unreachables into the range

**Symptom.** Phase 60's pcap check, which prints its capture, showed the
sensors' own traffic rather than only mirrored range traffic:

```
IP 172.16.9.40 > 172.16.3.5:      ICMP host 172.16.9.20 unreachable - admin prohibited
IP 172.16.9.41 > 192.168.100.101: ICMP host 172.16.9.20 unreachable - admin prohibited
IP 172.16.9.42 > 8.8.4.4:         ICMP host 172.16.2.7 unreachable - admin prohibited
```

Source addresses are the sensors' own prod IPs.

**Cause.** Mirrored packets arrive on `tun0` carrying FOREIGN destinations —
Splunk, a DC, 8.8.4.4. The kernel treats them as routable, they fall through to
SO's `-A FORWARD -j REJECT --reject-with icmp-host-prohibited`, and each sensor
emits an ICMP unreachable **to the original sender**.

**Why it matters.** A workstation mid-conversation with Splunk on 9997 receives
"host 172.16.9.20 unreachable — admin prohibited" from a machine it never
contacted. Some stacks act on that. A passive monitoring system generating
traffic into the network it monitors is the one thing it must never do.

It also feeds back on itself: those ICMPs egress the prod NIC, traverse the
routers, get mirrored, and return — which is precisely how they became visible.

**How it stayed hidden.** The mirror checks passed throughout, because packets
*were* flowing; nothing asserted anything about their content or direction. It
surfaced only because the phase 60 check PRINTS its capture. Worth noting
against the check audit (structural pass 2/5): a check can be correct, pass
correctly, and still tell you nothing about a serious defect one field away
from what it inspects.

**Fix.** `-A FORWARD -i tun0 -j DROP` injected ahead of SO's FORWARD reject,
through the same derived `iptables.jinja` override that already carries the GRE
accepts — a salt INPUT, so it survives the highstate rewrite. DROP not REJECT,
and matched on the input INTERFACE so it cannot affect anything but mirrored
traffic. Verified afterwards against the RUNNING ruleset, not the template.

**The anchor, now evidence-based.** I first guessed
`-A FORWARD -j LOGGING` by analogy with the INPUT anchor. Wrong — there is no
such line, and that guard would have failed all three sensors. The rendered
ruleset on so-sensor-corp (`/etc/iptables/rules.v4`, and live in
`iptables -S FORWARD`) ends:

```
:FORWARD DROP [0:0]
...
-A FORWARD -m conntrack --ctstate INVALID -j DROP
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
```

`so_tun_forward_anchor` is now that reject line. Mirrored traffic is new and
unrelated, so it passes both conntrack rules and lands on the reject —
inserting immediately before it is sufficient and is the smallest possible
change to the chain.

It also answers the question that would have invalidated the whole approach:
the reject IS in `rules.v4`, so it is rendered from SO's template rather than
added by Docker, and the derived-override mechanism reaches it.

**Two wrong instructions on the way here, recorded because they cost round
trips.** I asked for the template from `so-sensor-corp` and then from the
controller. `/opt/so/saltstack` exists ONLY on the manager — a fact this
role's own comments state ("the sensor has no /opt/so/saltstack at all"). I
had the answer in the code I was editing.

**Status: VERIFIED** — phase 60 on 2026-08-05, after phase 50 placed the rule.
No capture on any sensor contains an ICMP unreachable sourced from
172.16.9.40/.41/.42. What remains is legitimate mirrored range traffic:

```
corp:  IP 192.168.100.5.55086 > 172.16.2.7.53: A? M.ROOT-SERVERS.NET.
edge:  IP 200.200.200.2 > 172.16.9.30: ICMP echo reply        (the generator)
ot:    IP 192.168.95.1 > 192.168.95.2: ICMP host 192.168.90.102 unreachable
```

The OT line is worth reading closely: source `192.168.95.1` is pp-ot-router's
Gas-Turbine gateway rejecting something *inside* the range — genuine captured
traffic, not injection. Distinguishing the two is the whole point.

All three sensors still captured 100 packets, so dropping in FORWARD cost no
visibility: tcpdump sees frames at the interface before FORWARD is consulted.
Cluster green throughout, 261 shards, 2 data nodes.

## 2026-08-05 (structural pass 5/5) · enhancement · Host identities derived from inventory instead of restated

**Method.** Swept every literal IPv4 in `group_vars/` and the SO role defaults
and cross-referenced each against the `host_vars` files that declare it.

**Most hits were false alarms**, and worth recording so the next sweep does not
re-flag them:
- `so_subnet_*` values match a router interface only because a `/24` base and
  a `.0` host address look identical to a regex. They are subnet definitions,
  correctly declared once.
- `group_vars/voltgrid.yml` DNS records restate host addresses by design — it
  is zone data. Pre-existing range design, outside this pass, and risky to
  churn.
- `splunk_server_ip`, `syslog_server_ip`, `proxy_server` are pre-existing
  range variables, not SO-owned.

**Two genuine duplications of a HOST'S IDENTITY, both SO-owned:**

```yaml
so_mirror_host: "{{ hostvars[groups['ansible_controller'][0]]['ansible_host'] }}"
so_manager_ip:  "{{ hostvars[groups['so_manager'][0]]['so_prod_ip'] }}"
```

Previously `10.255.240.152` and `172.16.9.30`, restating
`host_vars/ansible.yml` and `host_vars/so-manager.yml`. A range whose
controller or manager gets a different address needed the same value changed in
two files, and missing the second breaks phases 10, 30 and 75 with a connection
error pointing at neither. Flagged as a fresh-deploy risk on 2026-08-05 before
the from-scratch run; it did not bite only because the range came from the same
blueprint.

**Validated by rendering**, not by inspection: both expressions plus the
dependent `so_mirror_url` and `so_msrv_ip` were rendered against a mocked
Ansible data model and produce byte-identical values to the literals they
replaced.

**One candidate deliberately NOT derived.** `so_web_user: "admin@voltgrid.com"`
looks like it should be `"admin@{{ domain_name }}"`. It must not be:
`domain_name` is defined in `group_vars/proxy.yml` and `group_vars/voltgrid.yml`,
both GROUP-scoped, and so-manager is in neither — it would be undefined on the
one host that renders the answer file. Left literal with a comment explaining
why, so the next person does not "fix" it.

**Limitation this exposed in the new checker.** `verify_vars.py` treats every
file under `group_vars/` as globally defined, so it would NOT have caught that
`domain_name` reference. It now handles ROLE scope (structural pass 1/5) but
not GROUP scope. Doing it properly needs group-membership analysis: resolve
which hosts each play targets, and which `group_vars/<group>.yml` files apply
to them. Worth doing, not done here.

**Status: VERIFIED** — genuinely this time, on the deployed range with a
tarball confirmed to contain the changes (`b2737cc`, grep-checked on the
controller before running). Phase 50, `failed=0` on all four nodes:
`become` preflights pass on so_base/so_search/so_sensor; the relocated firewall
invariants run on already-installed nodes with the apply correctly SKIPPED via
the `rc == 0` gate; the rewritten tunnel checks pass against real
`UNKNOWN`-state output; and every `so_base` task using the derived
`so_mirror_host` / `so_manager_ip` succeeded.

*The `ok=19/32` I could not reconcile earlier:* `so_base` runs as a META
DEPENDENCY of `so_search` and `so_sensor`, so those plays execute ~28 `so_base`
tasks before the role's own. I was counting only the role's tasks and built two
wrong theories from the difference instead of reading the task output.

## 2026-08-05 (structural pass 4/5) · enhancement · `become` audit — privilege contracts made explicit, and one unexplained inconsistency

**Method.** Mapped play-level `become` across every SO phase playbook against
task-level `become` inside every SO role.

**Two coherent patterns, both correct.**

*Roles that delegate carry task-level `become`* — `so_sensor` (14),
`so_search` (7), `vyos_mirror/tc` (4), `elastic_agent/linux` (4). These are
exactly the roles with tasks that run on a DIFFERENT host than the play
targets, where the privilege needed at each end differs. Escalating per task
is the only correct approach there.

*Windows paths carry none* — `05-time`, `70-analyst`, the sysmon plays,
`elastic_agent/windows`. WinRM connects already-elevated, so `become` is noise
at best.

**The gap: five roles with an invisible contract.** `so_apt_mirror`, `so_base`,
`so_manager`, `so_search` and `so_sensor` have zero (or partial) task-level
`become` and depend entirely on the calling play supplying it. Nothing states
that. The failure mode is a permission error partway through, in a task that
looks unrelated to privilege — and on this project every such discovery costs a
build/upload/deploy round trip through a web console.

Both `become` mistakes on 2026-08-04/05 grew from this ambiguity: a play-level
`become: true` that broke an unprivileged chmod, then removing it entirely and
breaking a privileged remote read.

**Fix.** Each of the five now opens with a two-task preflight: read `id -u`,
fail immediately with a message naming the role and the required
`become: true` if it is not 0. The contract is stated where it is depended on,
and violating it fails in the first second rather than the fortieth minute.
Placed at the very top, so it precedes the `end_host` probe per 9.4b.

**Deliberately NOT done.** Converting those five roles to task-level `become`
throughout — roughly 120 tasks. It is mechanical, touches every task in the
working set, and buys little while they are only ever invoked from
`become: true` plays. The preflight gets the safety without the churn.

**OPEN — an inconsistency I cannot explain from here.** `10-mirror.yml` runs
`hosts: ansible_controller, become: true` and works (it installs nginx, writes
under /var/www). `75-endpoint.yml`'s staging play used the identical
`hosts: ansible_controller, become: true` and failed with
`sudo: a password is required`. Same host, same user, same inventory entry.

I removed the need for privilege there rather than resolving why, which was the
right call for unblocking but leaves the question open. If a future play hits
`sudo: a password is required` on the controller, that is the thread to pull —
suspect a `become_method`/`become_pass` difference between how the two were
invoked, or something environmental in `deploy.sh` that a direct
`ansible-playbook` run does not set. The new preflight will now catch it in the
first task instead of mid-role.

**Status: VERIFIED** — genuinely this time, on the deployed range with a
tarball confirmed to contain the changes (`b2737cc`, grep-checked on the
controller before running). Phase 50, `failed=0` on all four nodes:
`become` preflights pass on so_base/so_search/so_sensor; the relocated firewall
invariants run on already-installed nodes with the apply correctly SKIPPED via
the `rc == 0` gate; the rewritten tunnel checks pass against real
`UNKNOWN`-state output; and every `so_base` task using the derived
`so_mirror_host` / `so_manager_ip` succeeded.

*The `ok=19/32` I could not reconcile earlier:* `so_base` runs as a META
DEPENDENCY of `so_search` and `so_sensor`, so those plays execute ~28 `so_base`
tasks before the role's own. I was counting only the role's tasks and built two
wrong theories from the difference instead of reading the task output.

## 2026-08-05 (structural pass 3/5) · enhancement · Lifetime-invariant vs first-install-only, classified across all four SO roles

**The recurring trap.** `meta: end_host` ends the play for an already-installed
node. Any task below it is unreachable on a re-run, so a fix placed there can
never repair an existing host — seven instances so far, each discovered by a
change that silently did nothing.

**Method.** Dumped the task order of every SO role against its `end_host`
position and classified each task: does it describe a fact that must hold for
the node's whole lifetime, or work that only makes sense once?

**Findings.**

*`so_manager` — already correct.* It includes `airgap_mode.yml` twice: once
above the probe gated on `so_installed.stat.exists`, once below for fresh
installs. Slightly awkward, but the invariant is genuinely re-asserted.

*`elastic_agent` — correct by construction.* No `end_host` at all; it gates on
the agent SERVICE STATE, which is re-evaluated every run.

*`so_sensor` — GRE firewall and tunnel already above the probe* from the
2026-08-04 fix.

*`so_search` and `so_sensor` — the manager-side firewall entry was below it.*
`so-firewall includehost <group> <ip>` plus the state apply sat in the grid-join
sequence, after `end_host`. That is MANAGER-side state, not node-side: a
rebuilt manager, a restored pillar or a hand-edited hostgroup leaves an
installed node permanently unable to reach salt on 4505/4506, and no re-run
could repair it because the play ended at the probe first. Both moved above.

**Made cheap rather than unconditional.** Re-asserting the entry on every run
is the point; paying for a possibly-20-minute queued `state.apply firewall`
when nothing changed is not. The apply is now gated on the add's EXIT CODE —
rc=0 means something was added, rc=3 is "already exists".

**A trap I set and then removed.** I first gated on `fw_add.changed`, which
couples the apply to `changed_when`'s stdout string-match
(`'Successfully added' in stdout`). A reworded so-firewall message would then
silently skip the apply on a FRESH node, leaving 4505/4506 shut — surfacing much
later as a grid join that never completes. Exit codes are contract; log strings
are not.

**The rule, for the porting guide.** A task belongs ABOVE the probe if it
asserts a fact that must remain true for the node's lifetime — firewall
entries, tunnel definitions, pillar switches, anything held on a DIFFERENT host
than the one being probed. It belongs below only if it is genuinely one-shot
work: rendering an answer file, running so-setup, the post-install reboot.

The sharpest form of the question: *if this state were destroyed on a running
range, would a re-run put it back?* If not, it is in the wrong place.

**Status: VERIFIED** — genuinely this time, on the deployed range with a
tarball confirmed to contain the changes (`b2737cc`, grep-checked on the
controller before running). Phase 50, `failed=0` on all four nodes:
`become` preflights pass on so_base/so_search/so_sensor; the relocated firewall
invariants run on already-installed nodes with the apply correctly SKIPPED via
the `rc == 0` gate; the rewritten tunnel checks pass against real
`UNKNOWN`-state output; and every `so_base` task using the derived
`so_mirror_host` / `so_manager_ip` succeeded.

*The `ok=19/32` I could not reconcile earlier:* `so_base` runs as a META
DEPENDENCY of `so_search` and `so_sensor`, so those plays execute ~28 `so_base`
tasks before the role's own. I was counting only the role's tasks and built two
wrong theories from the difference instead of reading the task output.

## 2026-08-05 (structural pass 2/5) · enhancement · Check audit — 80 checks reviewed against "can it fail?" and "does it measure its claim?"

**Method.** Extracted every task carrying `failed_when`, `until`, `assert` or
`fail` across the four SO roles, `elastic_agent`, `vyos_mirror` and the phase
playbooks: **80 checks in 272 tasks.**

**Most of it holds up.** The `until` + terminal-`fail` pattern is applied
consistently, and `failed_when: false` is used correctly throughout as "probe
now, judge later" rather than as a way to silence a task. Five failed the
audit.

### 1. `so_base` — ICMP reachability. NOT CHANGED, and worth explaining why.
Flagged initially: `ping` proves nothing about the ports the deploy needs, and
we watched pp-syslog ping the manager at 1.1ms while its TCP was rejected. I
started replacing it with a `wait_for` on salt 4505/4506 — and that would have
been a regression. `so_base` runs in phase 30, BEFORE so-setup installs
anything; there are no salt ports to test, and the manager is a bare VM.

The check was measuring prod-plane L3 reachability, which is genuinely what it
needed to measure. Fixed the *claim* instead: renamed to
"Confirm prod-plane L3 reachability to the manager (ICMP only)" with a comment
saying a pass here does NOT mean the node can talk to the manager once SO's
firewall is up. Auditing a check requires knowing when in the sequence it runs.

### 2. `vyos_mirror` — verified ONE interface and reported the mirror configured
`tc filter show dev {{ vyos_mirror_source_interfaces[0] }}` on a router that
mirrors five. The script SKIPs interfaces absent on the device (blueprint NIC
order vs `ethN`, PORTING_GUIDE 9.9), so a partial mirror is a real outcome —
and the sensor's pcap check would still pass on traffic from the one working
link. Now loops every source interface.

### 3. `75-endpoint` firewall proof — right answer, wrong chain
`iptables -S | grep <cidr> | grep -c 8220` accepts a match anywhere in the
ruleset. Fleet runs in a container, so what matters is `DOCKER-USER`; an INPUT
rule would have satisfied the check without permitting a single agent. Now
scoped to `iptables -S DOCKER-USER` with an exact `--dport 8220` match.

### 4. `so_sensor` — "Verify tunnel is up" passed on the wrong substring
`'UP' not in stdout` matches the `LOWER_UP` flag. GRE tunnels report state
`UNKNOWN`, never `UP`, so this check was passing purely on the flag list and
would also have passed on any future field containing those two letters. Now
`stdout is search('[<,]UP[,>]')` — UP as a whole token, which does not match
`LOWER_UP` — plus an explicit `LOWER_UP` carrier test. Verified against four
real `ip -brief` outputs including admin-down and up-without-carrier.

### 5. `so_manager` airgap pillar — substring where equality was available
`'True' not in stdout`, when `--out=newline_values_only` prints the bare value.
Now an exact match on trimmed stdout.

### Also: deleted dead code carrying a stale check
`roles/so_sensor/tasks/gre_tunnel.yml` was referenced by nothing and contained
a duplicate of the "Verify tunnel is up" check — the weaker version, which
would not have been fixed by #4. Dead code holding an outdated copy of a check
is worse than no code: it reads as authoritative to whoever finds it next.

**The through-line across all eight historical failures and these five.**
Every one asserted on something *correlated* with the claim instead of the
claim itself: a status banner instead of enrollment, a count instead of a host
list, a substring instead of a value, one interface instead of all of them, any
chain instead of the filtering chain. The question that catches them is not
"will this fail if something breaks" but **"what exactly would have to be true
for this to pass, and is that the thing I am claiming?"**

**Status: VERIFIED** — genuinely this time, on the deployed range with a
tarball confirmed to contain the changes (`b2737cc`, grep-checked on the
controller before running). Phase 50, `failed=0` on all four nodes:
`become` preflights pass on so_base/so_search/so_sensor; the relocated firewall
invariants run on already-installed nodes with the apply correctly SKIPPED via
the `rc == 0` gate; the rewritten tunnel checks pass against real
`UNKNOWN`-state output; and every `so_base` task using the derived
`so_mirror_host` / `so_manager_ip` succeeded.

*The `ok=19/32` I could not reconcile earlier:* `so_base` runs as a META
DEPENDENCY of `so_search` and `so_sensor`, so those plays execute ~28 `so_base`
tasks before the role's own. I was counting only the role's tasks and built two
wrong theories from the difference instead of reading the task output.

## 2026-08-05 (structural pass 1/5) · enhancement · verify_vars.py now detects role-scope errors, and build_tarball aborts on them

**The class this closes.** A play referencing a role default without including
that role resolves fine in YAML and fails at run time. It happened three
times — `so_bundled_rules_filename` (2026-07-29), `so_mirror_root` and
`so_agent_installer_*` (2026-08-04) — each costing a full
build → upload → deploy round trip to discover, which on this project means a
human hand-carrying commands through a web console.

The checker could not catch it *by construction*: it treated every
`roles/*/defaults/main.yml` key as globally defined.

**What was added.**
- `role_scoped_definitions()` — var → the role(s) whose defaults define it.
- `roles_used_in()` — roles a playbook references, via `roles:` blocks,
  `- role:`/`- name:` forms, and `import_role`/`include_role`.
- `scope_errors()` — for each playbook, any referenced var that is not
  globally defined, not locally satisfied, and IS owned by a role the playbook
  does not use.
- Exit **3** for scope errors; `build_tarball.sh` aborts. Exit 1 remains the
  advisory soft-warning path. Previously the exit code was discarded entirely
  (`|| true`), so nothing the checker found could ever stop a build.

**Granularity is per file, not per play.** A role used anywhere in a playbook
satisfies references anywhere in it. That can miss a genuine error but cannot
invent one — the right trade for a check that fails the build.

**Validated by reintroducing the bug.** Reverting `so_mirror_root` to
role-scope only produced exactly:

```
SCOPE ERROR: role-scoped variable(s) referenced by a play that
does not include the defining role.
  - so_mirror_root    in playbooks/75-endpoint.yml
      defined only in role default(s): so_apt_mirror
exit=3
```

A check is worth what its failure case proves, so it was tested by breaking
the thing it exists to catch.

**Second bug found while testing.** The `vars:` collector used
`^([ \t]*)vars:\n((?:[ \t]+\S.*\n|[ \t]*\n)+)`, whose greedy body swallows
every indented line after a play-level `vars:` — including the whole `tasks:`
section. Task-level `vars:` blocks nested inside were never matched, so their
keys were reported as undefined. That is where the `unlisted` and `missing`
"expected false positives" came from — which I had documented as acceptable
rather than investigated. Replaced with a line-based scanner that stops at
dedent and resumes scanning after each block. **A checker with known-bogus
warnings trains you to skim past the real ones.**

**Baseline correction.** Expected warnings are **3** — `billing_secret_key`,
`nat`, `pfsense_stale_gateways` — when run against the STAGE. Against the repo
root only 2 appear, because `nat` lives in `roles/vyos`, a base role copied in
from `../range-development-ansible/` at build time. I briefly documented "2"
from a repo-root run; corrected.

**Status: VERIFIED** — genuinely this time, on the deployed range with a
tarball confirmed to contain the changes (`b2737cc`, grep-checked on the
controller before running). Phase 50, `failed=0` on all four nodes:
`become` preflights pass on so_base/so_search/so_sensor; the relocated firewall
invariants run on already-installed nodes with the apply correctly SKIPPED via
the `rc == 0` gate; the rewritten tunnel checks pass against real
`UNKNOWN`-state output; and every `so_base` task using the derived
`so_mirror_host` / `so_manager_ip` succeeded.

*The `ok=19/32` I could not reconcile earlier:* `so_base` runs as a META
DEPENDENCY of `so_search` and `so_sensor`, so those plays execute ~28 `so_base`
tasks before the role's own. I was counting only the role's tasks and built two
wrong theories from the difference instead of reading the task output.

## 2026-08-05 (later 2) · bug · Agent enrollment is a single shot against a firewall that rewrites itself every 15 minutes

**Symptom.** `pp-syslog` failed to enroll:

```
Starting enrollment to URL: https://172.16.9.30:8220/
Enrollment failed: ... dial tcp 172.16.9.30:8220: connect: no route to host
```

while `pp-proxy` — same subnet (172.16.2.0/24), same gateway, same play, same
batch — enrolled without trouble.

**The manager's firewall was correct.**
`-A DOCKER-USER -s 172.16.2.0/24 -p tcp --dport 8220 -j ACCEPT` covers both
hosts, and the hostgroup pillar lists all eight subnets.

**The decisive detail is that pp-syslog PASSED the preflight.** `wait_for`
connected to 8220 successfully, and the enrollment attempt seconds later got
`EHOSTUNREACH`. The port was reachable, then it was not.

**Cause.** SO's firewall state runs `iptables_restore` as a bare `cmd.run`
with no `onchanges`, so the ruleset is rewritten on EVERY highstate (~15 min) —
this is documented in `so_sensor`'s GRE firewall comments as the reason a
manually added rule cannot survive. During that rewrite an unmatched packet
falls through to `-A FORWARD -j REJECT --reject-with icmp-host-prohibited`,
which returns ICMP admin-prohibited and surfaces as "no route to host" rather
than a timeout. The agent's own backoff (init 5s, max 10m) gave up after ~8s
and cleanly uninstalled itself.

**Fix.** The installer task now retries: `until rc == 0`, 4 retries, 45s delay,
on both the Linux and Windows paths. Safe because a failed enroll removes the
install directory and the service, so each attempt starts from a clean host.

**My diagnostic error, recorded so it is not repeated.** I asked for a test of
TCP 443 from pp-syslog and read its failure as evidence. 443 is only granted to
`172.16.9.0/24` via the `analyst` hostgroup — `172.16.2.0/24` gets 8220, 5055
and 8443. The test could only ever have failed, and it told us nothing. Check
which port a host is actually *supposed* to reach before using it as a probe.

**Status: VERIFIED** — 2026-08-05. `pp-syslog` enrolled on re-run, and the
per-host check reported `Missing: none` across all 44 agent targets. The
fresh-range deploy is now complete end to end.

*Note on the aggregate:* Fleet reports 50 hostnames against my arithmetic of
49 (44 + 5 grid nodes), so the SO grid contributes one more agent document
than assumed. That discrepancy is exactly why the count was replaced — the
authoritative signal is the per-host diff, which enumerates real inventory
targets and cannot be satisfied by an unrelated document.

## 2026-08-05 (later) · bug · Two more of my checks: a fragile reachability probe, and a Fleet count that passed while two hosts had failed

**Symptom.** On the fresh range, `pp-proxy` and `pp-syslog` failed the Fleet
preflight — while `pp-dc01`, `pp-file`, `pp-mail` and `pp-sql`, all on the SAME
subnet (172.16.2.0/24), enrolled without trouble. Then the verification play
reported:

```
Fleet has 49 agents enrolled; 49 expected (44 endpoints + 5 SO grid nodes).
```

and passed — with two endpoints demonstrably not enrolled.

### The reachability probe was not measuring reachability

```yaml
timeout 5 bash -c '</dev/tcp/{{ so_fleet_host }}/8220' 2>/dev/null && echo True || echo False
```

This reports `False` for a missing `timeout` binary, a bash built without net
redirection, or a handshake slower than 5s — none of which are "the port is
unreachable". Windows hosts on the same subnet connecting fine is not a network
story. Replaced with `ansible.builtin.wait_for`, which opens a real Python
socket on the target and reports the actual result, with a 15s timeout.

### The Fleet count could be satisfied by unrelated documents

`expected` was computed as `44 endpoints + 5 grid nodes = 49`, and
`.fleet-agents/_count` returned 49. But only 42 endpoints had enrolled, so the
SO grid contributes more agent documents than the five nodes I assumed, and the
two errors cancelled. **A count cannot tell you WHICH hosts enrolled.**

Replaced with a per-host diff: list the hostnames Fleet actually knows
(`.fleet-agents/_search`, parsed with python3 on the manager), subtract them
from the inventory's agent targets, and fail naming exactly which hosts are
missing. A separate guard fails if the query itself returns non-zero, so an
unreadable result cannot pass.

**The pattern, stated plainly.** An aggregate that *should* equal N is not
evidence that the N specific things happened. This is the seventh check I have
had to fix in two days, and they share a root: asserting on something
correlated with the claim rather than on the claim itself. The claim here is
"every target host is enrolled", so the check must enumerate target hosts.

**Status: VERIFIED** — 2026-08-05. `pp-syslog` enrolled on re-run, and the
per-host check reported `Missing: none` across all 44 agent targets. The
fresh-range deploy is now complete end to end.

*Note on the aggregate:* Fleet reports 50 hostnames against my arithmetic of
49 (44 + 5 grid nodes), so the SO grid contributes one more agent document
than assumed. That discrepancy is exactly why the count was replaced — the
authoritative signal is the per-host diff, which enumerates real inventory
targets and cannot be satisfied by an unrelated document.

## 2026-08-05 · enhancement · Restored a boot delay in deploy.sh — "the retry loop handles it" cost two full sweeps

**Symptom.** On the first from-scratch deploy of the `security-onion` branch,
attempts 1 and 2 both failed on hosts that had not finished booting; the
controller got no response from them. Attempt 3 then ran cleanly through every
phase. Three multi-hour sweeps to do the work of one.

**History.** `deploy.sh` used to `sleep 120` before the first attempt. It was
removed on 2026-07-02 in a speed pass, with the reasoning recorded in the file:
*"the retry loop already handles any host unreachable from a VM that isn't
ready. On iterative deploys the sleep is pure wasted wall clock."*

Half of that was right and half was expensive. On an ITERATIVE deploy against
an already-running range, the sleep is indeed waste. On a FRESH range it is
not, because "the retry loop handles it" means paying for an entire failed
sweep — here, two of them — to arrive at the same place a three-minute wait
would have reached directly. The cost asymmetry was never examined: 180s
against a ~5-hour deploy is 1%.

**Fix.** `BOOT_DELAY`, defaulting to 180s before attempt 1, overridable:

```bash
BOOT_DELAY=0 ./deploy.sh     # already-up range, iterative work
```

which keeps the legitimate half of the original argument.

**Generalisable.** "A retry will catch it" is only cheap when a retry is cheap.
When the retried unit is a multi-hour full-fleet sweep, a guard that prevents
the failure beats a mechanism that recovers from it. Worth applying to the
`MAX_ATTEMPTS=3` loop generally — a late-phase failure currently re-runs
everything from the range baseline.

**Status: VERIFIED** — 2026-08-05. `pp-syslog` enrolled on re-run, and the
per-host check reported `Missing: none` across all 44 agent targets. The
fresh-range deploy is now complete end to end.

*Note on the aggregate:* Fleet reports 50 hostnames against my arithmetic of
49 (44 + 5 grid nodes), so the SO grid contributes one more agent document
than assumed. That discrepancy is exactly why the count was replaced — the
authoritative signal is the per-host diff, which enumerates real inventory
targets and cannot be satisfied by an unrelated document.

## 2026-08-04 (later 12) · bug · The Fleet enrollment check counted the wrong thing entirely — `so-elastic-agent-status` reports one host, not the grid

**Symptom.** All 44 endpoints enrolled with `failed=0`, and the verification
reported:

```
Fleet reports 2 healthy agents; 49 expected (44 endpoints + 5 SO grid nodes).
```

**Cause.** `so-elastic-agent-status` reports the status of the agent on the
host it runs on. Its entire output is two lines:

```
├─ fleet          → status: (HEALTHY) Connected
└─ elastic-agent  → status: (HEALTHY) Running
```

so `grep -ci healthy` returns **2** whether the grid has 2 agents or 200. The
check was never counting enrollments — it was counting lines in a fixed-size
status banner, and would have reported "2" on an empty grid just the same.

**Fix.** Ask Elasticsearch, which is the authority: Fleet keeps enrolled agents
in `.fleet-agents`, and `so-elasticsearch-query` is the established helper in
this repo (60-verify uses it for cluster health).

```yaml
so-elasticsearch-query ".fleet-agents/_count"
```

The task now polls that count until it reaches the expected total (20×15s,
since agents take a moment to register after the installer returns), reports
actual-versus-expected, and **fails** when short — naming the likely cause and
where to look. A separate guard fails loudly if the query output contains no
`count` at all, so an unreadable result can never be mistaken for a pass.

**Sixth in the family.** Notable for being the worst kind: not a check that
could never fail, nor one that could never pass, but one measuring something
unrelated to the claim it made. A grep against human-readable CLI output that
happens to contain the search word a fixed number of times. The rule from
PORTING_GUIDE 9.15b — assert on parsed values, never `grep` against free-form
output — would have caught this too.

**Status: VERIFIED** — PowerPlant, 2026-08-04. All 44 endpoints enrolled
(`failed=0` across 40 Windows + 4 Linux), and the Fleet verification play
passed with both its guard tasks SKIPPED — which only happens when
`.fleet-agents/_count` parsed cleanly AND reached the expected 49
(44 endpoints + 5 SO grid nodes).

## 2026-08-04 (later 11) · bug · `so-firewall includehost` is not idempotent — rc=3 on an existing entry aborted the whole run

**Symptom.** Re-running `75-endpoint.yml` after the subnets were already
permitted:

```
failed: [so-manager] (item=172.16.2.0/24) => {"rc": 3,
  "stderr": "WARNING - IP 172.16.2.0/24 already exists in hostgroup elastic_agent_endpoint"}
```

All eight subnets, then `PLAY RECAP` with only so-manager and nothing else run.

**Two things went wrong.**

1. *SO's tool is not idempotent.* `so-firewall includehost` exits **rc=3** when
   the entry already exists, and says so as a `WARNING` on stderr, not an
   error. The subnet is permitted either way — this is a success for our
   purposes.

2. *The failure was fatal to the entire playbook.* so-manager was the only host
   in that play, so every host in the play failed, and Ansible aborts the run
   at that point rather than continuing to later plays. The four Linux hosts
   never got their turn even though the play they needed was unrelated.

**Fix.** Tolerate the warning, matching the pattern `so_search` already uses
for the same command during grid join:

```yaml
failed_when:
  - fw_include.rc != 0
  - "'already exists' not in fw_include.stderr"
```

**Worth remembering about single-host plays.** A play with one host has no
partial-failure mode: any failure is a total failure and stops everything
downstream. Manager-side setup plays are all like this, so a non-idempotent
command in one of them is far more expensive than the same command in a
40-host play. Second time this shape has cost a run today — the first was
`so-firewall`'s sibling behaviour in the highstate lock (later 2).

**Status: VERIFIED** — PowerPlant, 2026-08-04. All 44 endpoints enrolled
(`failed=0` across 40 Windows + 4 Linux), and the Fleet verification play
passed with both its guard tasks SKIPPED — which only happens when
`.fleet-agents/_count` parsed cleanly AND reached the expected 49
(44 endpoints + 5 SO grid nodes).

## 2026-08-04 (later 10) · bug · Linux agent install had no privilege — Windows hid the gap because WinRM already runs elevated

**Symptom.** All 40 Windows hosts enrolled cleanly; the four Linux hosts failed
identically:

```
fatal: [pp-syslog]: FAILED! => "There was an issue creating /opt/so-agent as
  requested: [Errno 13] Permission denied: b'/opt/so-agent'"
```

**Cause.** The enrollment play carries no `become` — correctly, after the
lesson in (later 9) about play-level escalation. But Windows and Linux differ:
WinRM connects as an already-elevated account, so the Windows path never needed
it, while on Linux `/opt` is root-owned, the installer writes system paths, and
`systemctl` needs root. A shared role with two OS branches hid the asymmetry:
the Windows branch passing said nothing about the Linux branch.

**Fix.** `become: true` on the four Linux tasks that genuinely need it —
staging directory, download, installer, service wait. Not on the play, and not
on the `is-active` probe or the fail/report tasks, which do not.

**Worth noting against my own prediction.** I expected the six hosts on
192.168.100.0/24 (pp-dc03, pp-dcs-ctrl, pp-ctl-wks-01..04) to fail their Fleet
preflight, on the grounds that pp-ot-firewall is default-deny with no rule
permitting OT to reach pp-security on 8220. They all passed and enrolled. The
lab-mode rules on that firewall are more permissive than its host_vars comment
("ESP boundary; default-deny, static-only") implies. No posture change was
needed, and none was made.

**Status: VERIFIED** — PowerPlant, 2026-08-04. All 44 endpoints enrolled
(`failed=0` across 40 Windows + 4 Linux), and the Fleet verification play
passed with both its guard tasks SKIPPED — which only happens when
`.fleet-agents/_count` parsed cleanly AND reached the expected 49
(44 endpoints + 5 SO grid nodes).

## 2026-08-04 (later 9) · bug · Two `become` mistakes staging the agent installers — one asked for too little privilege, one for too much

**9a — `fetch` writes its local copy as the ansible user.**

```
PermissionError: [Errno 13] Permission denied:
  b'/var/www/so-mirror/agents/so-elastic-agent_windows_amd64'
failed: [ansible -> so-manager]
```

`become: true` reads as "this task runs as root", but for `fetch` the
escalation applies to the REMOTE read (on so-manager); the local write happens
as the ansible user. The directory was `www-data`-owned, so simspace could not
write into it. The `[ansible -> so-manager]` in the failure line is the tell —
a delegated task with different privilege at each end.

**9b — and then the chmod asked for privilege it did not need.**

```
sudo: a password is required
failed: [ansible] (item=so-elastic-agent_windows_amd64)
```

Having fixed 9a by making the directory ansible-user-owned, the follow-up
`file` task still inherited the play's `become: true` — and passwordless sudo
is not available to that account in this context. It was escalating in order
to chmod files it already owned.

**Fix.** Create `{{ so_mirror_root }}/agents` in `so_apt_mirror` (phase 10),
which already runs privileged, owned by the ansible user with group www-data.
`75-endpoint.yml`'s staging play then carries **no `become` at all**: it stats,
fetches and chmods as the ansible user, and asserts the directory exists
rather than trying to create it. nginx only needs read access — 0755 on the
directory, 0644 on the files. Nothing is chowned to www-data, deliberately:
that would need root and would break the next fetch after deleting a file to
force a refresh.

**The pattern.** `become: true` at PLAY level is a blunt instrument. It applies
to tasks that cannot use it (the local half of a `fetch`) and to tasks that do
not need it (chmod on your own file), and the second kind only surfaces on a
host where passwordless sudo happens not to be configured. Escalate per task,
where the need is real.

**9c — and then removing `become` entirely broke the REMOTE read.**

On the fresh-range run of 2026-08-05:

```
failed: [ansible -> so-manager] "Failed to get information on remote file
  (/nsm/elastic-fleet/so_agent-installers/so-elastic-agent_windows_amd64):
  Permission denied"
```

The installers are root-owned on the manager, so the fetch's remote read needs
privilege — the exact thing the play-level `become` had been providing before
9b removed it. Having been wrong in one direction, I corrected past the answer
rather than to it.

**The correct configuration, arrived at the long way:** `become: true` on the
fetch task ONLY. Remote read is privileged; local write is not, and cannot be;
the chmod needs no privilege because the ansible user owns what it fetched.
That is precisely the "escalate per task" conclusion 9b already stated — and
then I applied it as "escalate nowhere".

**Status: VERIFIED** — PowerPlant, 2026-08-04. All 44 endpoints enrolled
(`failed=0` across 40 Windows + 4 Linux), and the Fleet verification play
passed with both its guard tasks SKIPPED — which only happens when
`.fleet-agents/_count` parsed cleanly AND reached the expected 49
(44 endpoints + 5 SO grid nodes).

## 2026-08-04 (later 8) · bug · Role-scoped variables referenced from a play that does not include the role — third instance

**Symptom.** `75-endpoint.yml` staging play, on the controller:

```
fatal: [ansible]: FAILED! => "'so_mirror_root' is undefined"
```

**Cause.** `so_mirror_root` lives in `roles/so_apt_mirror/defaults/main.yml`,
and `so_agent_installer_windows` / `_linux` in
`roles/elastic_agent/defaults/main.yml`. Role defaults are **role-scoped**. The
staging play includes neither role — it only copies files into the mirror
directory — so none of the three resolved.

**Third instance of this exact trap.** `so_bundled_rules_filename` was the
first (2026-07-29 fresh-range 3). The shape is always the same: a value that
"belongs" to a role conceptually, but is read by a play that does not run it.

**Fix.** All three promoted to `group_vars/all/security_onion.yml`, with
comments left in the role defaults pointing at the new home rather than
duplicate definitions, so there is one source of truth. `so_mirror_host` was
already correctly all-scoped.

**Why verify_vars.py does not catch this, and cannot as written.** It treats
any `roles/*/defaults/main.yml` entry as globally defined, so a scope error
resolves cleanly at build time and fails at run time. Its warning count is
unchanged at 3. Documented as a known limitation in CLAUDE.md — the rule to
apply by hand is that a variable read by more than one role, or by any bare
play, belongs in `group_vars/all/`.

**Unrelated bookkeeping.** The expected-warning membership changed: `nat` is no
longer referenced anywhere in the repo, and `unlisted` is now flagged — a false
positive, since it is a task-level `vars:` entry and verify_vars.py parses only
play-level `vars:`.

**Status: VERIFIED** — PowerPlant, 2026-08-04. All 44 endpoints enrolled
(`failed=0` across 40 Windows + 4 Linux), and the Fleet verification play
passed with both its guard tasks SKIPPED — which only happens when
`.fleet-agents/_count` parsed cleanly AND reached the expected 49
(44 endpoints + 5 SO grid nodes).

## 2026-08-04 (later 7) · bug · Two `win_powershell` output bugs of my own — one check that could never pass, one that could never fail

Both were written this week, in the same playbooks that carry the rule about
checks that cannot fail. Recording them because the *shapes* recur.

### 7a — `Write-Output $svc.Status` returns a DICT, so the check could never pass

**Symptom.** `75-endpoint.yml`'s Sysmon verification failed on all 40 Windows
hosts, with output that plainly showed success:

```
fatal: [pp-bp-wkstn-4]: FAILED! => {"failed_when_result": true,
  "output": [{"String": "Running", "Type": "System.ServiceProcess.ServiceControllerStatus", "Value": 4}]}
```

**Cause.** `$svc.Status` is a `ServiceControllerStatus` **enum**, not a string.
`win_powershell` serializes it as an object, so `output[0]` is a dict and
`output[0] != 'Running'` is always true.

**Fix.** `Write-Output ([string]$svc.Status)`. Applied in `75-endpoint.yml` and
both sites in `roles/elastic_agent/tasks/windows.yml`, where the identical
pattern would have failed all 44 agent installs the same way.

### 7b — `Write-Output [Math]::Abs(...)` returns a LITERAL STRING, so the check could never fail

**Cause.** PowerShell parses `Write-Output [Math]::Abs(...)` in ARGUMENT mode
and emits the literal text `[Math]::Abs(...)`. Jinja's `| float` silently
converts that to `0.0`, so `failed_when: drift > 120` was never true.

**What it cost.** Nothing yet, which is the point — it hid rather than broke.
The clock drift checks in `05-time.yml` and `70-analyst.yml` both reported
`clock 0s from range UTC` on every host **without measuring anything**. The
clocks are probably correct (`Set-Date` reported `changed` on 39 of 40 hosts),
but that was never verified.

**Fix.** `Write-Output ([Math]::Abs(...).ToString())`. Parentheses force
expression mode; `.ToString()` keeps it a scalar rather than a serialized
object, i.e. avoids 7a.

### The general rule

`win_powershell`'s `output` is a list of **serialized .NET objects**, not
strings. Anything but a string, number or bool arrives as a dict. Two
consequences, and both bit here:
- Emit an explicit `[string]` / `.ToString()` for anything compared in Jinja.
- Wrap any expression in parentheses; a bare `[Type]::Method(...)` after a
  cmdlet is a string literal, not a call.

A `| float` on unparsable text yielding `0.0` rather than erroring is what
turned 7b from a visible bug into an invisible one. Fifth instance in the
can-this-check-actually-fail family (PORTING_GUIDE 9.15, 9.15b).

**Status: VERIFIED** — PowerPlant, 2026-08-04. All 44 endpoints enrolled
(`failed=0` across 40 Windows + 4 Linux), and the Fleet verification play
passed with both its guard tasks SKIPPED — which only happens when
`.fleet-agents/_count` parsed cleanly AND reached the expected 49
(44 endpoints + 5 SO grid nodes).

## 2026-08-04 (later 6) · enhancement · Elastic Agent endpoint telemetry into SO — Sysmon + eventlogs from all 44 managed hosts

**Why.** SO had wire visibility only: Zeek and Suricata parsing mirrored
packets from the three sensors. That stops at the host boundary — you see a
workstation talk to a DC, not what ran on it. Endpoint telemetry was going to
Splunk (universal forwarder to pp-splunk) and nowhere else.

**Scope.** 44 hosts: `[windows]` + `[linux]` minus `[unmanaged]` OT devices
and minus the SO grid, which enrolls itself. 8 subnets. Additive to Splunk —
nothing is removed from the existing forwarder path.

**What the range already had, which shaped the design.**
- *Sysmon was already deployed, but only on `[aue]`.* `arbitr_pp_playbook.yaml`
  installs it in the "apply AUE settings" play, so the workstations had it and
  pp-dc01/02/03, pp-file, pp-sql, pp-mail had none — exactly where process
  ancestry matters most. The role is idempotent (`creates_service: Sysmon64`),
  so extending it to all of `[windows]` is a no-op on the AUE boxes.
- *An in-platform Nexus is already the convention.* Chrome, Firefox, Sysmon,
  the Splunk forwarder, CrowdStrike, SentinelOne and Defender all install from
  `nexus.dev.ng.simspace.lan/repository/ng_raw/installers/`. This answers the
  bundle-vs-Nexus question deferred on 2026-08-03: the range already has a
  working in-platform source and needs no bundling.

**Installers.** SO builds per-grid installers at
`/nsm/elastic-fleet/so_agent-installers/` with the Fleet URL and enrollment
token already embedded — so no token in vault, and the 1.2 GB
`elastic-agent_SO-9.0.8.tar.gz` in `/nsm/elastic-fleet/artifacts/` is the
local component source, which is what makes this work airgapped.

**Delivery — not from the manager.** SO serves the installers at
`https://<manager>/packages/` (nginx maps
`/nsm/elastic-fleet/so_agent-installers/` to `/opt/socore/html/packages`), but
that path returns **503** on this grid. Rather than debug it, the installers
are staged once onto the controller's existing `so_apt_mirror` nginx and
endpoints fetch over the mgmt plane — the same path they already use for every
other installer. This also avoids 44 hosts pulling ~8.5 GB from the manager
while it is ingesting from three sensors. Enrollment still goes to the manager
on 8220.

**Firewall.** The hostgroup is `elastic_agent_endpoint`, confirmed in
`/opt/so/saltstack/default/salt/firewall/defaults.yaml`, mapping to portgroups
`elastic_agent_control` (8220), `_data` and `_update`. Applied with
`so-firewall includehost`, which writes the firewall PILLAR — a salt input, so
it survives the highstate. Editing rendered iptables would not; same lesson as
`soc.json` and the GRE rule.

**Guards, deliberately.** Each is aimed at a failure that would otherwise
surface far from its cause:
- An assert that every agent target's in-scenario prefix appears in
  `so_agent_endpoint_subnets`. A host on an undeclared subnet would install an
  agent that can never enroll, and the symptom would be a timeout 200 lines
  into a 44-host run.
- A per-host preflight that Fleet's 8220 is reachable BEFORE installing.
- Idempotency keyed on the agent SERVICE STATE, never a marker file we wrote
  ourselves.
- Verification of the firewall against the RUNNING `iptables -S`, not the
  pillar, and of enrollment against FLEET, not the endpoints' own opinion.

**Known open item.** The six hosts on 192.168.100.0/24 (pp-dc03, pp-dcs-ctrl,
pp-ctl-wks-01..04) sit behind pp-ot-firewall, which is default-deny with no
rule permitting OT to reach pp-security on Fleet's ports. The preflight fails
those hosts individually with a message naming the needed
`host_vars/pp-ot-firewall.yml` change; the other 38 still enroll. Opening that
path changes the range's security posture and is a deliberate decision, not
something this role should make on its own.

**Status: VERIFIED** — PowerPlant, 2026-08-04. All 44 endpoints enrolled
(`failed=0` across 40 Windows + 4 Linux), and the Fleet verification play
passed with both its guard tasks SKIPPED — which only happens when
`.fleet-agents/_count` parsed cleanly AND reached the expected 49
(44 endpoints + 5 SO grid nodes).

## 2026-08-04 (later 5) · platform · SOC login loops on win-hunt-1 — the Windows clock fix was left behind when 00-setup was excluded

**Symptom.** `https://172.16.9.30` from win-hunt-1 renders
"This login form has expired. Restart the login process to continue." and
loops on every retry. No server-side error anywhere.

**Root cause.** Not new — this is so-ansible UPSTREAM_FIXES 2026-07-29
(later 14) reappearing. The platform sets each VM's RTC to UTC. Linux reads
the RTC as UTC and is correct; Windows reads it as LOCAL time and runs ahead
by the timezone offset. SOC authenticates through kratos, which mints a login
flow with an `expires_at` and compares it against the BROWSER's clock. Flows
live 60 minutes, so a client ~4h fast sees every fresh flow as ~3h expired.

**Why it came back.** The fix lived in so-ansible's `playbooks/00-setup.yml`,
which ss-pp-ab deliberately does NOT import — `arbitr_pp_playbook.yaml`
already runs `init` + `common`, and importing both would do two
NetworkManager/netplan passes with a reboot each. That decision was correct
for its own reasons, but it silently dropped an unrelated fix riding in the
same file. Nothing in the port surfaced the loss; it only appeared when a
human tried to log in.

**Not a firewall problem, which is worth recording.** so-setup seeded
`ALLOW_CIDR={{ so_subnet_security }}` (172.16.9.0/24) from the manager answer
file, so the `analyst` hostgroup already covers every host on pp-security.
`so-firewall listhostgroup analyst` shows the CIDR and win-hunt-1 reports
`TcpTestSucceeded: True` on 443. No firewall change was needed or made.

**Fix (revised same day).** Initially a `[hunt]`-scoped fix in
`playbooks/70-analyst.yml`. When the decision was taken to add Elastic Agent
endpoint telemetry, the skew stopped being a login nuisance and became a data
integrity problem — endpoint events would land in Elasticsearch hours ahead of
the sensors' Zeek/Suricata data. The fix was promoted to range-wide
`playbooks/05-time.yml`, DC-first, and 70-analyst reduced to verification
only. Two playbooks setting the same clock is a race.

The mechanics are unchanged:
- `RealTimeIsUniversal=1` — fixes the cause, effective next boot.
- An explicit `Set-Date` when drift > 60s — fixes the current session so no
  reboot is needed.
- A verification step that re-reads the clock afterwards and fails above 120s
  of residual drift, rather than trusting that the set "ran".

**Ordering is the whole design.** Kerberos tolerates 5 minutes of skew.
Correcting a domain MEMBER while the DCs are still wrong breaks auth on that
member. `05-time.yml` is therefore two plays, not one with `serial`: all three
DCs first, then `windows:!domain_controllers`, then a third play that verifies
the whole estate. Checking each host as it is corrected would miss the case
that actually matters — a member and a DC disagreeing with each other.

**Side effect worth having.** Windows event timestamps in Splunk were skewed
by the same offset and are now correct too.

**Status: PROPOSED** — verify by running phase 70 and completing a SOC login.

## 2026-08-04 (later 4) · bug · The pcap check failed because the mirror WORKED — `'0 packets captured' in stdout` is a substring test

**Symptom.** With the GRE fixes in, phase 60 still failed on all three
sensors — but the captures were full of real range traffic:

```
so-sensor-corp: IP 172.16.2.20.35015 > 8.8.8.8.53: PTR? 7.4.16.172.in-addr.arpa.
so-sensor-ot:   IP 192.168.90.101.38819 > 192.168.104.201.53: A? cloud....
so-sensor-edge: IP 172.16.2.7.60220 > 8.8.8.8.53: A? update.googleapis.com.
100 packets captured   (all three)
```

**Root cause.** The condition was

```yaml
failed_when: "'0 packets captured' in pcap_out.stdout"
```

`tcpdump -c 100` stops at 100 and prints `100 packets captured`, and the
string `"100 packets captured"` **contains** `"0 packets captured"`. The check
therefore fired exactly when the mirror was working, and would have stayed
silent at 10, 20 or 50 packets. It was an inverted check, not a loose one.

**Fix.** `failed_when: "'0 packets captured' in pcap_out.stdout_lines"` —
membership in `stdout_lines` is an equality test per line, so `100 packets
captured` no longer matches. Same one-word change in both repos.

**Second instance found while fixing it.** `verify_so.sh`'s traffic-flow smoke
test — commented in the file as "the money-shot check" — expected the pattern
`packets captured|packets received`. tcpdump prints both of those on every run
including a zero capture, so the single check that proves the whole mirror
chain could never fail. Now `[1-9][0-9]* packets captured`.

**Pattern.** That is four in this family now (PORTING_GUIDE 9.15). Worth
stating the rule directly: a check whose expected string is a *substring* of,
or a *prefix* of, the failure output is not a check. Assert on parsed values or
exact lines, never on `in` against free-form command output.

**Status: VERIFIED** — PowerPlant phase 60 green on 2026-08-04, all four
hosts `failed=0`. Each sensor captured 100 packets of genuine range traffic
off `tun0`:

```
so-sensor-corp  172.16.2.20.8080 > 172.16.6.4.54990  HTTP
so-sensor-ot    192.168.90.107.57070 > 192.168.95.2.4840   (OPC-UA)
so-sensor-edge  172.16.2.7.64604 > 8.8.4.4.53  A? www.msftconnecttest.com
```

End-to-end proof of tc mirred -> GRE encap -> route -> SO firewall -> kernel
decap -> tun0, on all three routers including the RC_NG_OT_Router image whose
tc-over-SSH path had never been exercised. Elasticsearch green, 243 active
shards at 100%, 2 data nodes.

## 2026-08-04 (later 3) · bug · Sensors captured nothing: hardcoded GRE remote in the netplan template + last-writer-wins firewall override

**Symptom.** PowerPlant phase 60, all three sensors:

```
0 packets captured / 0 packets received by filter
```

Uniform across corp, OT and edge — including corp, whose GRE path crosses no
firewall at all. That uniformity is what ruled out per-router and firewall
explanations.

**Evidence.** The mirror was never the problem. On `pp-corp-router`:

```
filter protocol all pref 3 matchall  (rule hit 2041627)
  action order 1: mirred (Egress Mirror to device tun0)
  Sent 881394835 bytes 2041627 pkt
tun0  TX: 1279445785 bytes  8561963 packets
```

and on `so-sensor-corp`, GRE was arriving with real corp traffic inside it:

```
eth1 In IP 172.16.0.42 > 172.16.9.40: GREv0, length 60: IP 172.16.5.10.53938 > 172.16.9.20.9997
```

But the sensor's tunnel read:

```
tun0: link/gre 172.16.9.40 peer 172.16.5.1     <-- packets arriving from 172.16.0.42
      RX: 0 packets
iptables: -A INPUT -s 75.21.1.2/32 -p gre -j ACCEPT   <-- that is EDGE's router
```

**Root cause 1 — hardcoded IP in a template.**
`roles/so_sensor/templates/60-so-mirror-tun.yaml.j2` contained
`remote: 172.16.5.1` as a literal. The kernel will not decapsulate a GRE
packet whose source does not match the tunnel's remote, so `tun0` stayed at
zero forever while looking perfectly healthy — UP, PROMISC, valid /30.

**Root cause 2 — one shared file, three writers.**
`so_gre_rule_block` rendered a single ACCEPT from the *current* host's
`so_gre_allowed_source`, and the derived override is written to ONE path on
the manager (`local/salt/firewall/iptables.jinja`), re-derived from the stock
template each time so it never accumulates. Three sensors each rewrote it in
turn; only the last one's rule survived, grid-wide. Edge ran last, so corp and
OT were left permitting edge's `75.21.1.2`.

**Why the dev range never caught either.** In so-ansible's range the mirroring
router WAS the sensor's gateway, so `so_prod_gateway`, the hardcoded
`172.16.5.1`, and the router's real GRE source were all the same address.
Three independent things agreed by coincidence. PowerPlant puts sensors on
`pp-security` (gw 172.16.9.1) with the mirroring routers elsewhere, and the
coincidence breaks. Only one sensor also meant last-writer-wins could never
appear.

**Fix.**
- New per-sensor variable `so_gre_remote_underlay` — the mirroring router's
  `vyos_gre_source_ip` — drives BOTH the tunnel `remote:` and the firewall
  ACCEPT. One fact, stated once.
- **No default.** Defaulting to `so_prod_gateway` would silently rebuild the
  same coincidence. A preflight task fails loudly when it is unset, placed
  before the `meta: end_host` probe so an installed sensor can still reach it.
- `so_gre_rule_block` now emits one ACCEPT per sensor, deduplicated and
  sorted, so the rendered override is byte-identical no matter which sensor
  writes it. Slightly over-permissive — every node accepts GRE from every
  mirroring router — which is the correct trade against silent breakage.
- Added `Verify the tunnel bound the CORRECT remote endpoint`, asserting on
  `ip -d link show` output. The old check tested only for "UP", which was true
  throughout this entire failure.

**Follow-on: the tunnel tasks were BELOW the `meta: end_host` probe.** Fixing
the template alone would have changed nothing on this range — all three
sensors already carry `/opt/so/state/installed`, so the play ends before ever
reaching the netplan task. Instance seven of the same trap (PORTING_GUIDE 9.4).
The whole GRE tunnel block now sits above the probe, alongside the firewall
block, because a tunnel definition is a lifetime invariant that must be
re-asserted on every run rather than only at first install.

**Status: VERIFIED** — PowerPlant phase 60 green on 2026-08-04, all four
hosts `failed=0`. Each sensor captured 100 packets of genuine range traffic
off `tun0`:

```
so-sensor-corp  172.16.2.20.8080 > 172.16.6.4.54990  HTTP
so-sensor-ot    192.168.90.107.57070 > 192.168.95.2.4840   (OPC-UA)
so-sensor-edge  172.16.2.7.64604 > 8.8.4.4.53  A? www.msftconnecttest.com
```

End-to-end proof of tc mirred -> GRE encap -> route -> SO firewall -> kernel
decap -> tun0, on all three routers including the RC_NG_OT_Router image whose
tc-over-SSH path had never been exercised. Elasticsearch green, 243 active
shards at 100%, 2 data nodes.

## 2026-08-04 (later 2) · bug · so_search / so_sensor install timeout was 20 min — ansible KILLED so-setup mid-install

**Symptom.** PowerPlant phase 50, `so-search`:

```
FAILED! => {"attempts": 41, "finished": 1, "msg": "Timeout exceeded", ...}
so-search : ok=30 changed=3 unreachable=0 failed=1
```

`salt-key -L` on the manager showed only `so-manager_manager` accepted — no
key from so-search at all, Denied or otherwise.

**Root cause.** `so_search_install_timeout` was `1200` (20 min) with
`so_search_poll_interval: 30`, giving exactly the 40 retries observed.
`so_manager_install_timeout` had already been raised to `5400` with the note
*"was 45 — real installs seen at 45+ min in dev"*, but that measurement was
never propagated: `so_sensor` carried `# 20 min (similar to search)` and
`so_search` carried no justification at all. A guess citing a guess.

`so-setup` on a search node does substantially the same work as on a manager
— docker, image pulls, elastic — so 20 minutes was never plausible.

**The damage is worse than a failed task.** Ansible's async wrapper does not
merely stop polling at `async: N`; it TERMINATES the job. so-setup was killed
partway through, leaving a half-configured node that had not yet reached salt
key submission. A too-short timeout is destructive, not just impatient.

**Fix.** `so_search_install_timeout` and `so_sensor_install_timeout` both
raised to `5400`, matching `so_manager`. Overshooting costs nothing — the
`async_status` poll returns as soon as the job finishes. Undershooting
destroys the install. Comments in both files now say so.

**Recovery on an already-killed node.** The role's skip logic is
positive-proof (marker AND `/etc/salt/minion` AND the unit), so a node killed
before salt was installed re-runs so-setup in full rather than skipping into a
broken state. Confirm no `so-setup` process is still alive before re-running —
two concurrent so-setups on one host is the one thing that makes it worse.

**Status: VERIFIED** — PowerPlant phase 60 green on 2026-08-04, all four
hosts `failed=0`. Each sensor captured 100 packets of genuine range traffic
off `tun0`:

```
so-sensor-corp  172.16.2.20.8080 > 172.16.6.4.54990  HTTP
so-sensor-ot    192.168.90.107.57070 > 192.168.95.2.4840   (OPC-UA)
so-sensor-edge  172.16.2.7.64604 > 8.8.4.4.53  A? www.msftconnecttest.com
```

End-to-end proof of tc mirred -> GRE encap -> route -> SO firewall -> kernel
decap -> tun0, on all three routers including the RC_NG_OT_Router image whose
tc-over-SSH path had never been exercised. Elasticsearch green, 243 active
shards at 100%, 2 data nodes.

## 2026-08-04 (later) · bug · Phase 40 retry loop cannot outlast a highstate — `state.apply` needs `queue=True`

**Symptom.** With the IPv6 grain fix in place, `Airgap — apply the soc state`
still failed all 20 retries, but each attempt now took 7 seconds instead of
3m11s:

```
The function "state.highstate" is running as PID 1318939
```

**Root cause.** Salt refuses a concurrent `state.apply` *instantly*, so
`retries: 20, delay: 30` is not a 10-minute wait — it is twenty instant
failures spread across ~12 minutes of sleep. This range's highstate runs
longer than that, so the loop always ran out. The retry numbers were measured
on the so-ansible dev range and do not transfer.

**Fix.** `queue=True` makes salt hold the job until the running state
finishes. Ported from so-ansible `20051e4`; applied to all four `state.apply`
call sites (so_manager airgap, so_search firewall, so_sensor firewall ×2).
The task now blocks — possibly 20+ minutes — instead of failing.

**Status: VERIFIED** — PowerPlant phase 60 green on 2026-08-04, all four
hosts `failed=0`. Each sensor captured 100 packets of genuine range traffic
off `tun0`:

```
so-sensor-corp  172.16.2.20.8080 > 172.16.6.4.54990  HTTP
so-sensor-ot    192.168.90.107.57070 > 192.168.95.2.4840   (OPC-UA)
so-sensor-edge  172.16.2.7.64604 > 8.8.4.4.53  A? www.msftconnecttest.com
```

End-to-end proof of tc mirred -> GRE encap -> route -> SO firewall -> kernel
decap -> tun0, on all three routers including the RC_NG_OT_Router image whose
tc-over-SSH path had never been exercised. Elasticsearch green, 243 active
shards at 100%, 2 data nodes.

## 2026-08-04 · platform · Salt master saturated by 10-second IPv6 DNS timeouts — phase 40 pillar compilation dies

**Symptom.** `playbooks/40-manager.yml`, task `so_manager : Airgap — apply the
soc state`, failed all 20 retries over ~70 minutes with
`Pillar timed out after 180 seconds`. The stack itself was healthy:
`so-status` 14/14 up 16 hours, load 0.45, 12 GB free.

**Root cause.** `/opt/so/log/salt/master` repeating every few seconds on every
worker PID:

```
Unable to find IPv6 record for "so-manager" causing a 0:00:10.010872 second
timeout when rendering grains. Set the dns or /etc/hosts for IPv6 to clear this.
```

Salt's `ip_fqdn()` grain calls `getaddrinfo(<own fqdn>, AF_INET6)` on every
grains render. `/etc/hosts` carried only IPv4 entries for `so-manager`, so the
lookup fell through to DNS — and **this range's resolver does not answer AAAA
at all**, so each render burned the full 10s resolver timeout. Master workers
were permanently blocked, pillar compilation exceeded 180s, and the minion
could not authenticate.

The IPv4 path never touches DNS because `/etc/hosts` answers it, which is why
nothing else in the deploy complained.

**Fix.** `roles/so_base/templates/hosts.j2` puts the node's own hostname on the
`::1` line. Only its own — peers on `::1` would resolve grid traffic to
loopback. Ported from so-ansible `b9da608`.

**Worth following up separately:** a resolver that silently drops AAAA rather
than answering NXDOMAIN is a range-DNS characteristic that may bite other
services. Not chased here because the hosts entry removes the dependency.

**Does salt own `/etc/hosts`? No — confirmed 2026-08-04.** This was the open
risk when the fix landed, by analogy with `soc.json` and `iptables.jinja`. After
phase 40 ran past several 15-minute highstate cycles, `grep "^::1" /etc/hosts`
still showed `::1 ip6-localhost ip6-loopback so-manager` and the last 200 lines
of the master log contained zero IPv6 warnings. `so_base`'s template is the sole
owner of that file; no derived override is required.

**Status: VERIFIED** — PowerPlant phase 60 green on 2026-08-04, all four
hosts `failed=0`. Each sensor captured 100 packets of genuine range traffic
off `tun0`:

```
so-sensor-corp  172.16.2.20.8080 > 172.16.6.4.54990  HTTP
so-sensor-ot    192.168.90.107.57070 > 192.168.95.2.4840   (OPC-UA)
so-sensor-edge  172.16.2.7.64604 > 8.8.4.4.53  A? www.msftconnecttest.com
```

End-to-end proof of tc mirred -> GRE encap -> route -> SO firewall -> kernel
decap -> tun0, on all three routers including the RC_NG_OT_Router image whose
tc-over-SSH path had never been exercised. Elasticsearch green, 243 active
shards at 100%, 2 data nodes.

## 2026-08-03 · enhancement · ETOPEN ruleset now bundled in the tarball; no deploy-time internet fetches

**Symptom.** Phase 10 (`so_apt_mirror`) appeared to succeed on this repo but
the ETOPEN ruleset never reached the mirror. `rules/emerging.rules.tar.gz`
existed in `so-ansible` and was never copied here, so the copy task's
`when: bundled_rules.stat.exists` gate skipped silently. Phase 40 then 404'd
staging it for airgap mode — two phases downstream of the cause.

**Fix.**
- Added `rules/emerging.rules.tar.gz` (5.5 MB) to this repo.
- `build_tarball.sh` stages `rules/` and lists it in `TAR_PATHS`.
  Confirmed inside `ab_pp.tgz` via `tar -tzf`; archive is now 5.6 MB.
- Re-copied `roles/so_apt_mirror` from so-ansible `bd87195`, which fails at
  phase 10 with a message naming the bundling requirement when the ruleset
  is absent.

**Constraint this encodes** (owner, 2026-08-03): these ranges will deploy to
platforms with **no external access, not even a proxy**. Tarballs and repos
move to an on-prem in-platform solution such as Nexus. Nothing may be fetched
from the internet at deploy time. `inet_proxy_addr` in `group_vars/all/main.yml`
is a convenience of the current range, not a design assumption.

**Not yet compliant — deferred by owner** until SO is working here and in
airfield: the SO source git-clone, the three airgap content repo clones, and
`so-setup`'s own package fetches all still require egress.

**Status: VERIFIED** for the ruleset (present in `ab_pp.tgz`); the three
above are **OPEN**.

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
