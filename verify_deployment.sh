#!/bin/bash
#
# verify_deployment.sh — read-only health check for PowerPlant range.
# Run from the Ansible controller (/etc/ansible/).
#
# Walks every tier deployed by arbitr_pp_playbook.yaml and confirms
# externally-visible state. Uses `ansible -m win_shell` / `vyos_command` /
# `shell` and greps each command's stdout for an expected literal -- no
# JSON parsing, no value extraction.
#
# Usage:
#   cd /etc/ansible && ./verify_deployment.sh           # summary
#   cd /etc/ansible && ./verify_deployment.sh -v        # show ansible
#                                                       # output for each fail
#
# Exit 0 if every check passes, 1 if any fails.

set -u

VERBOSE=0
case "${1:-}" in
  -v|--verbose) VERBOSE=1 ;;
  -h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
esac

# --- colors --------------------------------------------------------------
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=''; R=''; Y=''; B=''; D=''; N=''
fi

PASS=0
FAIL=0
declare -a FAILURES

pass()    { printf "  ${G}✓${N} %s\n" "$1"; PASS=$((PASS+1)); }
fail() {
  printf "  ${R}✗${N} %s\n" "$1"
  FAIL=$((FAIL+1))
  FAILURES+=("$1")
  if [ "$VERBOSE" -eq 1 ] && [ -n "${2:-}" ]; then
    printf "      ${D}%s${N}\n" "$2" | head -5
  fi
}
section() { printf "\n${B}━━ %s ━━${N}\n" "$1"; }
note()    { printf "  ${D}%s${N}\n" "$1"; }

A() { ansible "$@" 2>&1; }

# Splunk admin auth for the cluster-status checks in section 7. Read from
# group_vars rather than hardcoded, so it follows a credential change.
#
# SEARCHES BOTH LAYOUTS, AND REFUSES TO RUN WITH AN EMPTY PASSWORD.
#
# This read only group_vars/all.yml. ss-pp-stacked keeps group_vars/all/ as a
# DIRECTORY -- the same conversion that broke verify_vars.py until it was
# switched to rglob -- so the grep found nothing, SPLUNK_AUTH became the string
# "admin:" with no password, and every curl-based check in section 7
# authenticated as nobody.
#
# Three of them failed, which was survivable. The fourth PASSED: the
# duplicate-license check counts occurrences of "same license" in the response
# and expects zero, and an auth error contains no such string. It scored zero
# and printed a green tick. A check that passes BECAUSE its query failed is
# worse than one that fails, because nobody goes looking.
#
# Hence the hard exit below. An empty credential can only produce noise.
SPLUNK_ADMIN_PW="$(
  { grep -hm1 '^splunk_admin_password:' group_vars/all.yml 2>/dev/null
    grep -rhm1 '^splunk_admin_password:' group_vars/all/ 2>/dev/null
  } | head -1 | cut -d'"' -f2
)"
if [ -z "$SPLUNK_ADMIN_PW" ] || case "$SPLUNK_ADMIN_PW" in *'{{'*) true;; *) false;; esac; then
  echo "ERROR: could not read splunk_admin_password from group_vars/all.yml"
  echo "       or group_vars/all/. Section 7 would authenticate as nobody and"
  echo "       report false passes, so this refuses to run."
  echo
  echo "       If the value is vaulted (a {{ ... }} reference), export the"
  echo "       password instead:  SPLUNK_ADMIN_PW=... ./verify_deployment.sh"
  [ -n "${SPLUNK_ADMIN_PW_OVERRIDE:-}" ] || exit 1
fi
SPLUNK_AUTH="admin:$SPLUNK_ADMIN_PW"

n_hosts() {
  ansible "$1" --list-hosts 2>/dev/null | tail -n +2 | sed '/^$/d' | wc -l | tr -d ' '
}

# One reachability probe per group.
probe_group() {
  local group="$1" module="$2" cmd="$3" label="$4"
  local total ok out
  total=$(n_hosts "$group")
  if [ "$total" -eq 0 ]; then
    note "$label: 0 hosts in inventory (skipping)"
    return
  fi
  if [ -n "$cmd" ]; then
    out=$(A "$group" -m "$module" -a "$cmd" --one-line)
  else
    out=$(A "$group" -m "$module" --one-line)
  fi
  ok=$(echo "$out" | grep -cE '\| (SUCCESS|CHANGED)')
  if [ "$ok" -eq "$total" ]; then
    pass "$label: $ok/$total reachable"
  else
    fail "$label: $ok/$total reachable" "$out"
  fi
}

check_ps() {
  local host="$1" ps="$2" expect="$3" label="$4"
  local out
  out=$(A "$host" -m ansible.windows.win_shell -a "$ps" --one-line)
  if echo "$out" | grep -qE "$expect"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

check_vyos() {
  local host="$1" cmd="$2" expect="$3" label="$4"
  local out
  out=$(A "$host" -m vyos.vyos.vyos_command -a "commands=\"$cmd\"" --one-line)
  if echo "$out" | grep -qE "$expect"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

check_pf_shell() {
  local host="$1" cmd="$2" expect="$3" label="$4"
  local out
  out=$(A "$host" -m ansible.builtin.shell -a "$cmd" --one-line)
  if echo "$out" | grep -qE "$expect"; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}

# Like check_pf_shell, but prints the returned token on PASS as well as FAIL.
#
# The data-quality checks embed their event counts in the token
# (DNS_SRC_OK_5920_events, not DNS_SRC_OK). A passing check that hides its
# count is precisely how PROC_CIM_OK passed on 13 of ~406,000 events and
# printed a green tick on 2026-08-18. If the number is the evidence, the
# number has to be on screen.
check_pf_shell_token() {
  local host="$1" cmd="$2" expect="$3" label="$4"
  local out tok
  out=$(A "$host" -m ansible.builtin.shell -a "$cmd" --one-line)
  # Token bodies carry lowercase words (VISIBILITY_OK_529374_raw_events), so
  # the class must admit them or the count is truncated at the first one.
  tok=$(echo "$out" | grep -oE '[A-Z][A-Za-z0-9_]{4,}' | tail -1)
  if echo "$out" | grep -qE "$expect"; then
    pass "$label [${tok:-?}]"
  else
    fail "$label [${tok:-no token}]" "$out"
  fi
}

count_ps_predicate() {
  local group="$1" ps="$2" expect="$3"
  A "$group" -m ansible.windows.win_shell -a "$ps" --one-line \
    | grep -cE "$expect"
}

# =========================================================================
# 1. Inventory reachability
# =========================================================================
section "1. Inventory reachability"

probe_group vyos             vyos.vyos.vyos_facts     ""          "VyOS routers (network_cli)"
probe_group vyos_routes_only vyos.vyos.vyos_facts     ""          "VyOS-CLI-only appliances (pp-ot-router)"
probe_group pfsense          ansible.builtin.shell    "echo ok"   "pfSense firewalls (ssh)"
probe_group linux            ansible.builtin.ping     ""          "Linux hosts (ssh)"
probe_group windows          ansible.windows.win_ping ""          "Windows hosts (winrm)"
probe_group email            ansible.builtin.shell    "echo ok"   "is-inet (email + global_dns)"

# =========================================================================
# 2. Network — routing convergence
#
# Current design (per host_vars — NOT the old iBGP-everywhere layout from
# PROJECT_LOG.md Phase 1):
#   - eBGP: pp-isp-router (AS 65002) <-> pp-external-firewall (AS 65001).
#     ONE session, at the internet edge.
#   - OSPF: pp-external-firewall <-> pp-internal-firewall. Corp routes
#     flow up via OSPF; pp-external-fw does `redistribute_ospf` into eBGP
#     so ISP-side learns the corp subnets.
#   - STATIC everywhere else: pp-corp-router / pp-internal-router /
#     site-edge-router carry `remove_vyos_bgp: true` (corp core = static).
#     pp-ot-firewall runs neither BGP nor OSPF ("ESP boundary; default-
#     deny, static-only" -- host_vars comment). pp-ot-router (routes-only
#     appliance) is static-only too.
# =========================================================================
section "2. Network — routing convergence"

# Every corp VyOS should have a default route in the FIB (via static).
for rtr in pp-internal-router site-edge-router pp-corp-router; do
  check_vyos "$rtr" \
    "show ip route 0.0.0.0/0" \
    'static|S\\*|S>' \
    "$rtr default route present in FIB (static)"
done

# eBGP edge -- pp-isp-router <-> pp-external-firewall.
#
# Asserts the STATE, not the uptime. The previous version matched
# `Establ|[0-9]+:[0-9]+:[0-9]+` against `show ip bgp summary`, which was wrong
# in both halves:
#
#   * "Establ" never appears in summary output. FRR prints the PREFIX COUNT in
#     the State/PfxRcd column when a session is up, and only prints a state
#     name (Idle / Active / Connect / OpenSent) when it is DOWN. So the literal
#     it looked for is the one string that cannot be there on success.
#   * The HH:MM:SS alternative matched the Up/Down column -- but FRR only uses
#     that format below 24 hours. At a day it switches to `1d00h25m`, at a week
#     to `2w3d04h`.
#
# Net effect: the check passed for the first 24 hours after a session came up
# and false-failed forever after. Caught 2026-08-18 at 1d00h25m uptime with
# both sessions perfectly healthy (1468/1474 messages exchanged).
#
# `show ip bgp neighbors` prints "BGP state = Established" explicitly, in every
# FRR version, with no time dependence. Both hosts have exactly one peer
# ("Total number of neighbors 1"), so matching one Established line is
# unambiguous here; add a count if a second session is ever introduced.
check_vyos pp-isp-router \
  "show ip bgp neighbors" \
  'BGP state = Established' \
  "pp-isp-router: eBGP session Established (peer pp-external-firewall)"

check_pf_shell pp-external-firewall \
  'vtysh -c "show ip bgp neighbors"' \
  'BGP state = Established' \
  "pp-external-firewall: eBGP session Established (peer pp-isp-router)"

# OSPF between the two firewalls -- feeds corp routes into eBGP via
# pp-external-fw's `redistribute_ospf: true`. If OSPF is down, ISP side
# loses everything behind pp-external-fw.
for fw in pp-external-firewall pp-internal-firewall; do
  check_pf_shell "$fw" \
    'vtysh -c "show ip ospf neighbor"' \
    'Full/' \
    "$fw OSPF: at least one Full neighbor"
done

# Static-only appliances: prove they have a default route.
check_vyos pp-ot-router \
  "show ip route static" \
  'S|static|0\.0\.0\.0|192\.168' \
  "pp-ot-router: static routes present"

# Avoid awk-through-ansible quoting problems -- grep -c returns a plain
# integer that survives --one-line's stdout joining cleanly.
# pfSense/FreeBSD prints the default route as either `default` or `0.0.0.0`
# in the Destination column depending on the netstat flavor/version. Match
# both.
check_pf_shell pp-ot-firewall \
  'c=$(netstat -rn -f inet | grep -cE "^(default|0\\.0\\.0\\.0)"); [ "$c" -ge 1 ] && echo HAS_DEFAULT || echo NO_DEFAULT' \
  'HAS_DEFAULT' \
  "pp-ot-firewall: default route in kernel FIB (static-only by design, no FRR)"

# FRR-RIB vs kernel-FIB divergence check on pp-internal-firewall -- this
# is the same failure class that hit airfield's bs-ops-fw (dhclient
# poisoning zebra). Verify the OT umbrella 192.168.100.0/24 route is in
# both FRR's view and the kernel FIB. Divergence here would break OT-side
# domain join for pp-ctl-wks-* and pp-dcs-ctrl.
check_pf_shell pp-internal-firewall \
  'frr_installed=$(vtysh -c "show ip route" 2>/dev/null | grep "192.168.100.0" | grep -c ">"); kernel_has=$(netstat -rn -f inet 2>/dev/null | grep -c "^192.168.100"); if [ "$frr_installed" -ge 1 ] && [ "$kernel_has" -ge 1 ]; then echo "OK_MATCH frr=$frr_installed kernel=$kernel_has"; elif [ "$frr_installed" -ge 1 ] && [ "$kernel_has" -eq 0 ]; then echo "DIVERGENCE frr=$frr_installed kernel=0 (dhclient poisoning? see UPSTREAM_FIXES.md 2026-06-30)"; else echo "NO_ROUTE frr=$frr_installed kernel=$kernel_has"; fi' \
  'OK_MATCH|NO_ROUTE' \
  "pp-internal-firewall FRR-RIB and kernel-FIB agree on 192.168.100.0/24"

# =========================================================================
# 3. pfSense configuration integrity
# =========================================================================
section "3. pfSense configuration integrity"

# Every firewall should have a defaultgw4 set. Each pfsense_stale_gateways
# entry represents a GW that must NOT be selected as default.
declare -A EXPECTED_GW=(
  [pp-external-firewall]="GW_ISP"
  [pp-internal-firewall]="GW_EDGE"
  [pp-ot-firewall]="GW_INTERNAL"
)

for fw in "${!EXPECTED_GW[@]}"; do
  expected="${EXPECTED_GW[$fw]}"
  check_pf_shell "$fw" \
    "xmllint --xpath 'string(//gateways/defaultgw4)' /cf/conf/config.xml 2>&1" \
    "$expected" \
    "$fw defaultgw4 pinned to $expected"
done

# Outbound NAT disabled on every corp pfSense (corp is fully-routed;
# NAT out to inet only happens at pp-isp-router edge, and even that only
# in simulation). If outbound NAT re-enabled itself, egress would source
# from the firewall's WAN interface -- silent break.
for fw in pp-external-firewall pp-internal-firewall pp-ot-firewall; do
  check_pf_shell "$fw" \
    "xmllint --xpath 'string(//nat/outbound/mode)' /cf/conf/config.xml 2>&1" \
    'disabled' \
    "$fw outbound NAT mode = disabled"
done

# USER_RULE count -- proves pfsense_rules from host_vars actually rendered
# into pfctl. Floor set below the current design counts to avoid false-
# failing on rule tidy-ups; a big drop still catches "rules didn't render".
for fw in "pp-external-firewall:4" "pp-internal-firewall:3" "pp-ot-firewall:4"; do
  host="${fw%:*}"; floor="${fw##*:}"
  check_pf_shell "$host" \
    "c=\$(pfctl -vsr 2>/dev/null | grep -c 'label \"USER_RULE'); [ \"\$c\" -ge $floor ] && echo OK_\$c || echo LOW_\$c" \
    'OK_' \
    "$host has >= $floor USER_RULE rules loaded"
done

# NAT rules on pp-external-firewall: HTTP + HTTPS reflected to pp-www.
# If either is missing, public voltgrid.com / billing.voltgrid.com break.
check_pf_shell pp-external-firewall \
  "xmllint --xpath 'count(//nat/rule)' /cf/conf/config.xml 2>&1" \
  '[2-9]|[1-9][0-9]' \
  "pp-external-firewall: >= 2 <nat><rule> entries (voltgrid.com WAN reflection)"

# =========================================================================
# 4. Active Directory — voltgrid.com
# =========================================================================
section "4. Active Directory — voltgrid.com"

# simspace in Domain Admins on the forest root.
check_ps pp-dc01 \
  'Get-ADGroupMember "Domain Admins" | Where-Object { $_.Name -eq "simspace" } | Select-Object -ExpandProperty Name' \
  '\(stdout\)[[:space:]]+simspace' \
  "voltgrid.com: simspace is in Domain Admins"

# DomainUsers population — floor at 20 to catch a partial create_users run.
check_ps pp-dc01 \
  '$c=(Get-ADGroupMember "Domain Admins" -Recursive | Where-Object {$_.objectClass -eq "user"}).Count; if ($c -ge 20) {"OK_$c"} else {"LOW_$c"}' \
  '\(stdout\)[[:space:]]+OK_' \
  "voltgrid.com: >= 20 named users in Domain Admins (create_users ran)"

# Spot-check one specific named user exists + is enabled. ahmed.ortega
# is a canonical PowerPlant-roster name (from DomainUsers in voltgrid.yml).
check_ps pp-dc01 \
  'try { (Get-ADUser ahmed.ortega -Properties Enabled).Enabled } catch { "MISSING" }' \
  '\(stdout\)[[:space:]]+True' \
  "voltgrid.com: ahmed.ortega exists and is enabled"

# Both additional DCs promoted (PartOfDomain == True). pp-dc02 is the
# corp additional DC, pp-dc03 is the OT-side additional DC (192.168.100.5).
for adc in pp-dc02 pp-dc03; do
  check_ps "$adc" \
    '(Get-WmiObject Win32_ComputerSystem).PartOfDomain' \
    '\(stdout\)[[:space:]]+True' \
    "$adc: PartOfDomain True (additional DC promoted)"
done

# Both additional DCs should be actual DCs, not just members. Get-ADDomainController
# should return the host itself. Confirms dcpromo actually finished.
# Windows echoes hostname UPPERCASE (PP-DC02), so match case-insensitively.
for adc in pp-dc02 pp-dc03; do
  UPPER=$(echo "$adc" | tr '[:lower:]' '[:upper:]')
  check_ps "$adc" \
    'try { (Get-ADDomainController -Identity $env:COMPUTERNAME).Name } catch { "NOT_A_DC" }' \
    "\\(stdout\\)[[:space:]]+($adc|$UPPER)" \
    "$adc: is a real DC in voltgrid.com (Get-ADDomainController)"
done

# Member join counts across all domain members.
total=$(n_hosts members)
joined=$(count_ps_predicate members \
  '(Get-WmiObject Win32_ComputerSystem).PartOfDomain' \
  '\(stdout\)[[:space:]]+True')
if [ "$joined" -eq "$total" ] && [ "$total" -gt 0 ]; then
  pass "members: $joined/$total hosts domain-joined"
else
  fail "members: $joined/$total hosts domain-joined"
fi

# OT-side workstations specifically -- these were the ones added to
# [members] on 2026-07-02 to fix "domain not contacted" errors. Break
# them out so a mgmt-network anomaly doesn't get hidden in the aggregate.
for ot in pp-ctl-wks-01 pp-ctl-wks-02 pp-ctl-wks-03 pp-ctl-wks-04 pp-dcs-ctrl; do
  check_ps "$ot" \
    '(Get-WmiObject Win32_ComputerSystem).Domain' \
    '\(stdout\)[[:space:]]+voltgrid\.com' \
    "$ot: joined to voltgrid.com (OT-side via pp-dc03)"
done

# DNS forwarders on pp-dc01 → is-inet aliases (8.8.8.8 / 8.8.4.4 / 1.1.1.1).
# Fixes "nslookup hbo.com times out" that the customer DNS role doesn't
# handle by default (UPSTREAM_FIXES.md 2026-05-22).
check_ps pp-dc01 \
  '(Get-DnsServerForwarder).IPAddress.IPAddressToString -join ","' \
  '8\.8\.8\.8.*1\.1\.1\.1|1\.1\.1\.1.*8\.8\.8\.8|8\.8\.4\.4' \
  "pp-dc01 DNS forwarders → is-inet aliases (8.8.8.8 / 8.8.4.4 / 1.1.1.1)"

# Mgmt-IP DDNS scrubbing — the DDNS overlay play removes 10.255.240.x
# A records for hostnames from AD DNS. Verify no A records in voltgrid.com
# zone still point into the mgmt subnet.
check_ps pp-dc01 \
  '$c=(Get-DnsServerResourceRecord -ZoneName voltgrid.com -RRType A | Where-Object {$_.RecordData.IPv4Address -match "^10\.255\.2(4[0-9]|5[0-5])\."}).Count; if ($c -eq 0) {"OK_CLEAN"} else {"LEAK_$c"}' \
  '\(stdout\)[[:space:]]+OK_CLEAN' \
  "pp-dc01: no 10.255.240.x A records in voltgrid.com zone (mgmt DDNS scrubbed)"

# The purge above is a safety net, not the mechanism. A multihomed Windows DNS
# server republishes a STATIC host record for every bound address on each
# service start, which is why the records returned a day after a successful
# deploy with RegisterThisConnectionsAddress already False on the mgmt NIC.
# PublishAddresses is what actually withholds the management address; assert it
# is set, or the purge is destined to be undone again.
for dc in pp-dc01 pp-dc02 pp-dc03; do
  check_ps "$dc" \
    '(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\DNS\Parameters" -Name PublishAddresses -EA SilentlyContinue).PublishAddresses' \
    '\(stdout\)[[:space:]]+[0-9]' \
    "$dc: DNS server PublishAddresses is set (withholds the mgmt address)"
done

# =========================================================================
# 5. File services
# =========================================================================
section "5. File services"

check_ps pp-dc01 \
  'Get-GPO -All | Where-Object { $_.DisplayName -eq "Mapped Network Drives" } | Select-Object -ExpandProperty DisplayName' \
  '\(stdout\)[[:space:]]+Mapped Network Drives' \
  "voltgrid.com: 'Mapped Network Drives' GPO exists"

check_ps pp-file \
  'Get-SmbShare -Name "Share" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name' \
  '\(stdout\)[[:space:]]+Share' \
  "voltgrid.com: \\\\pp-file.voltgrid.com\\Share is exposed"

# =========================================================================
# 6. SOC tier — syslog collector
# =========================================================================
section "6. SOC tier — syslog collector"

# pp-syslog runs rsyslog on UDP+TCP 514.
check_pf_shell pp-syslog \
  'ss -lnu | grep -qE ":514\\b" && ss -lnt | grep -qE ":514\\b" && echo LISTENERS_OK || echo LISTENERS_MISSING' \
  'LISTENERS_OK' \
  "pp-syslog listening on UDP+TCP 514"

# VyOS routers land under /var/log/remote/<hostname>/ (customer syslog_server
# role's rsyslog template resolves the syslog HOSTNAME field).
# pfSense firewalls land under /var/log/remote/<source-ip>/ because pfSense's
# built-in syslog doesn't populate a hostname the template can pick up --
# rsyslog falls back to source IP. (Filed in UPSTREAM_FIXES.md 2026-07-06;
# the range-dev syslog_server role should reverse-resolve or template on
# fromhost-ip -> hostname.) IP mapping confirmed via `ifconfig` on each fw:
#   pp-external-firewall -> 172.16.0.9
#   pp-internal-firewall -> 172.16.0.25
#   pp-ot-firewall       -> 172.16.0.50
# Fresh mtime (<10 min) proves messages still flow.
for src in pp-internal-router site-edge-router pp-corp-router \
           172.16.0.9 172.16.0.25 172.16.0.50; do
  case "$src" in
    172.16.0.9)  label="pp-external-firewall (via IP $src)" ;;
    172.16.0.25) label="pp-internal-firewall (via IP $src)" ;;
    172.16.0.50) label="pp-ot-firewall (via IP $src)" ;;
    *)           label="$src" ;;
  esac
  check_pf_shell pp-syslog \
    "test -f /var/log/remote/$src/syslog.log && age=\$((\$(date +%s) - \$(stat -c %Y /var/log/remote/$src/syslog.log))) && [ \$age -lt 600 ] && echo OK_FRESH || echo STALE_OR_MISSING" \
    'OK_FRESH' \
    "pp-syslog receiving from $label (log mtime <10min)"
done

# =========================================================================
# 7. SOC tier — Splunk SIEM
# =========================================================================
section "7. SOC tier — Splunk SIEM"

check_pf_shell pp-splunk \
  'systemctl is-active Splunkd || systemctl is-active splunk' \
  'active' \
  "pp-splunk: Splunk service active (search head)"

# pp-splunk is a SEARCH HEAD as of the 2026-08-19 cutover. It must NOT be
# listening on 9997 -- a search head that still accepts forwarder connections
# means some forwarders are delivering to a host that stores nothing, and the
# data lands nowhere visible with no error at either end. Asserting the
# ABSENCE is the only way that shows up.
check_pf_shell pp-splunk \
  'ss -lnt | grep -qE ":9997\\b" && echo STILL_RECEIVING || echo NOT_RECEIVING' \
  'NOT_RECEIVING' \
  "pp-splunk: NOT listening on :9997 (search head stores no data)"

check_pf_shell pp-splunk \
  'ss -lnt | grep -qE ":8000\\b" && echo OK_8000 || echo MISSING_8000' \
  'OK_8000' \
  "pp-splunk listening on :8000 (Splunk Web)"

check_pf_shell pp-splunk \
  'ss -lnt | grep -qE ":8089\\b" && echo OK_8089 || echo MISSING_8089' \
  'OK_8089' \
  "pp-splunk listening on :8089 (Splunk REST/mgmt)"

# The indexer tier is what receives now.
for idx in pp-splunk-idx01 pp-splunk-idx02; do
  check_pf_shell "$idx" \
    'systemctl is-active Splunkd || systemctl is-active splunk' \
    'active' \
    "$idx: Splunk service active"

  check_pf_shell "$idx" \
    'ss -lnt | grep -qE ":9997\\b" && echo OK_9997 || echo MISSING_9997' \
    'OK_9997' \
    "$idx: listening on :9997 (UF receiver)"

  # Without the replication listener a peer joins and then cannot replicate,
  # which presents as the replication factor never being met rather than as a
  # configuration error.
  check_pf_shell "$idx" \
    'ss -lnt | grep -qE ":9887\\b" && echo OK_9887 || echo MISSING_9887' \
    'OK_9887' \
    "$idx: listening on :9887 (bucket replication)"
done

# The cluster's own view. Peers can each be Up while nothing replicates, and
# the factors are the only place that shows.
check_pf_shell pp-splunk-cm \
  "/opt/splunk/bin/splunk show cluster-status -auth '$SPLUNK_AUTH' 2>/dev/null | grep -cE '(Replication|Search) factor met'" \
  '2' \
  "pp-splunk-cm: replication AND search factors met"

check_pf_shell pp-splunk-cm \
  "/opt/splunk/bin/splunk show cluster-status -auth '$SPLUNK_AUTH' 2>/dev/null | grep -c 'Status  *Up'" \
  '2' \
  "pp-splunk-cm: both peers Up"

# pp-syslog UF forwarding /var/log/remote/* -- catches "UF running but no
# ESTABLISHED conn to an indexer" silent break. Now checks the TIER: a UF
# auto-load-balances, so at any instant it holds a connection to one peer, not
# necessarily a specific one.
check_pf_shell pp-syslog \
  'systemctl is-active SplunkForwarder' \
  'active' \
  "pp-syslog SplunkForwarder service active"

check_pf_shell pp-syslog \
  'c=$(ss -ant | grep -E "172\\.16\\.9\\.(21|22):9997" | grep -c ESTAB); [ "$c" -ge 1 ] && echo OK_ESTAB || echo NO_ESTAB' \
  'OK_ESTAB' \
  "pp-syslog UF has ESTABLISHED connection to an indexer :9997"

# Total forwarder count, derived from the inventory rather than a constant, and
# summed ACROSS the peers -- auto-load-balancing spreads the estate over both,
# so neither peer alone carries them all.
uf_expected=$(n_hosts splunk-forwarder)
uf_floor=$(( uf_expected * 9 / 10 ))
uf_total=0
for idx in pp-splunk-idx01 pp-splunk-idx02; do
  c=$(A "$idx" -m ansible.builtin.shell -a "ss -ant | grep ':9997 ' | grep -c ESTAB" --one-line \
      | grep -oE 'stdout\) [0-9]+' | grep -oE '[0-9]+' | head -1)
  uf_total=$(( uf_total + ${c:-0} ))
done
if [ "$uf_total" -ge "$uf_floor" ]; then
  pass "indexer tier: $uf_total of $uf_expected inventoried UFs ESTABLISHED (floor $uf_floor)"
else
  fail "indexer tier: $uf_total of $uf_expected inventoried UFs ESTABLISHED (floor $uf_floor)"
fi

# Windows UF service spot check on one workstation + one DC.
check_ps pp-bp-wkstn-1 \
  '(Get-Service SplunkForwarder -ErrorAction SilentlyContinue).Status' \
  '\(stdout\)[[:space:]]+Running' \
  "pp-bp-wkstn-1: SplunkForwarder service running"

check_ps pp-dc01 \
  '(Get-Service SplunkForwarder -ErrorAction SilentlyContinue).Status' \
  '\(stdout\)[[:space:]]+Running' \
  "pp-dc01: SplunkForwarder service running"

# Sysmon spot check -- proves the sysmon role landed the config +
# started Sysmon64 service. Sysmon events land in index=sysmon via UF --
# MEASURED 2026-08-18: all 454,659 of them, none in index=windows. The
# previous comment here said windows and was wrong.
check_ps pp-bp-wkstn-1 \
  '(Get-Service Sysmon64 -ErrorAction SilentlyContinue).Status' \
  '\(stdout\)[[:space:]]+Running' \
  "pp-bp-wkstn-1: Sysmon64 service running"

# -------------------------------------------------------------------------
# Licensing — exactly one license manager
# -------------------------------------------------------------------------
# Splunk Web, 2026-08-25:
#
#   "Peer pp-splunk-idx02 has the same license installed as peer
#    pp-splunk-idx01 ... Please fix this issue in 72 hours, otherwise peer
#    will be disabled."
#
# The base `splunk` role installs {{ splunk_license }} unconditionally and runs
# in all four distributed Splunk plays, so cm, both peers AND the search head
# each became an independent license manager holding the same license. Splunk
# reads that as one licensed volume claimed four times.
#
# Note what the warning did NOT say: pp-splunk holds the same duplicate and is
# never mentioned, because the cluster manager compares licenses across its
# PEERS and a search head is not one. Acting only on the hosts named in a
# vendor warning would have left a third duplicate in place. These checks are
# written against the INVARIANT -- one holder, everyone else pointed at it --
# rather than against the symptom that happened to get reported.

check_pf_shell pp-splunk-cm \
  'sudo ls /opt/splunk/etc/licenses/enterprise/ 2>/dev/null | grep -cE "\.(lic|license|xml)$" || true' \
  '\(stdout\)[[:space:]]+[1-9]' \
  "pp-splunk-cm: holds the deployment's license (license manager)"

# Asserting the ABSENCE on every other node. A license peer ignores a local
# license, so a stray one causes no immediate symptom -- it just re-arms the
# same 72-hour warning the next time someone reruns the base role and Splunk
# re-compares. "No symptom" is not the same as "correct".
for h in pp-splunk-idx01 pp-splunk-idx02 pp-splunk; do
  check_pf_shell "$h" \
    'sudo ls /opt/splunk/etc/licenses/enterprise/ 2>/dev/null | grep -cE "\.(lic|license|xml)$" || true' \
    '\(stdout\)[[:space:]]+0' \
    "$h: holds no local license (defers to pp-splunk-cm)"
done

# The outcome, from the manager's side. The three checks above prove the FILES
# are in the right places; this proves the nodes actually reached each other.
# A wrong URI, an unreachable 8089 or a pass4SymmKey mismatch all leave the
# filesystem looking perfect and the peer still licensing itself.
for h in pp-splunk-idx01 pp-splunk-idx02 pp-splunk; do
  check_pf_shell_token pp-splunk-cm \
    "curl -sS -k -u '$SPLUNK_AUTH' 'https://127.0.0.1:8089/services/licenser/slaves?output_mode=json&count=0' | grep -c '\"label\"[[:space:]]*:[[:space:]]*\"$h\"' || true" \
    '\(stdout\)[[:space:]]+[1-9]' \
    "$h: registered with the license manager"
done

# The warning itself. Splunk keeps licenser messages until the condition
# clears, so this is the check that actually answers "is the 72-hour clock
# still running?" -- the only one of these that a human would recognise as the
# original problem.
# A ZERO COUNT IS ONLY MEANINGFUL IF THE QUERY RAN.
# This used to be `grep -ci 'same license' || true` expecting 0, which an auth
# failure satisfies perfectly -- an error response contains no such string. It
# reported green for the entire time SPLUNK_AUTH was empty. Assert the response
# actually looks like the licenser API before counting anything in it.
check_pf_shell pp-splunk-cm \
  "r=\$(curl -sS -k -u '$SPLUNK_AUTH' 'https://127.0.0.1:8089/services/licenser/messages?output_mode=json&count=0' 2>&1); \
   if ! printf '%s' \"\$r\" | grep -q '\"entry\"'; then echo LICWARN_QUERY_FAILED; \
   elif printf '%s' \"\$r\" | grep -qi 'same license'; then echo LICWARN_PRESENT; \
   else echo LICWARN_NONE; fi" \
  '\(stdout\)[[:space:]]+LICWARN_NONE' \
  "no active duplicate-license warning (query proven to have run)"

# =========================================================================
# 8. Enterprise services — root certs, AUE lockdown, autologin, squid, DNS
# =========================================================================
section "8. Enterprise services"

# root_certs role installed the SimSpace lab-CA into every Windows Trusted Root store.
check_ps pp-bp-wkstn-1 \
  'if (Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object {$_.Subject -match "SimSpace|root_ca|simspace|DigiCert"}) { "PRESENT" } else { "MISSING" }' \
  '\(stdout\)[[:space:]]+PRESENT' \
  "pp-bp-wkstn-1: root CA installed in Trusted Root store"

# AUE lockdown — disable_uac role sets EnableLUA=0. Only aue hosts get this.
check_ps pp-bp-wkstn-1 \
  '(Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction SilentlyContinue).EnableLUA' \
  '\(stdout\)[[:space:]]+0' \
  "pp-bp-wkstn-1 (AUE): UAC disabled (proves disable_uac ran)"

# autologin role sets DefaultUserName from each host's logon_user.
check_ps pp-bp-wkstn-1 \
  '(Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue).DefaultUserName' \
  '\(stdout\)[[:space:]]+[a-z]+\.[a-z]+' \
  "pp-bp-wkstn-1 (AUE): autologin DefaultUserName populated"

# Chrome install spot check.
check_ps pp-bp-wkstn-1 \
  'if (Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe") { "INSTALLED" } elseif (Test-Path "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe") { "INSTALLED" } else { "MISSING" }' \
  '\(stdout\)[[:space:]]+INSTALLED' \
  "pp-bp-wkstn-1: Chrome installed (proves chrome role ran)"

# network_discovery — Public/Private network prompt suppressed on Win10/11.
check_ps pp-bp-wkstn-1 \
  '$np=Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1; if ($np.NetworkCategory -match "Domain|Private|Public") { "$($np.NetworkCategory)" } else { "MISSING" }' \
  '\(stdout\)[[:space:]]+(Domain|Private|Public)' \
  "pp-bp-wkstn-1: network profile categorized (network_discovery ran)"

# pp-proxy — squid service active + listening on :3128.
check_pf_shell pp-proxy \
  'systemctl is-active squid' \
  'active' \
  "pp-proxy: squid service active"

check_pf_shell pp-proxy \
  'ss -lnt | grep -qE ":3128\\b" && echo OK_3128 || echo MISSING_3128' \
  'OK_3128' \
  "pp-proxy: listening on :3128 (squid HTTP proxy)"

# is-inet global_dns via unbound -- query is-inet directly (via 8.8.8.8
# lo alias) rather than through corp AD DNS. Uses mail.outlook.com --
# an external-simulation record defined in group_vars/all.yml
# global_dns_records that isn't covered by any Section 9 check. voltgrid.com
# records also live in the include file but they're already tested in
# Section 9. www.faa.gov (from the airfield-range aviation records) is
# NOT defined for PowerPlant.
check_pf_shell pp-syslog \
  'r=$(nslookup mail.outlook.com 8.8.8.8 2>/dev/null | awk "/^Address: / {print \$2; exit}"); [ "$r" = "52.96.223.2" ] && echo "OK_$r" || echo "GOT_$r"' \
  'OK_52\.96\.223\.2' \
  "is-inet: unbound resolves mail.outlook.com -> 52.96.223.2 (global_dns loaded)"

# =========================================================================
# 9. Public web (WordPress + billing) + email
# =========================================================================
section "9. Public web + email"

# pp-www: docker daemon healthy + wordpress + db containers up.
check_pf_shell pp-www \
  'systemctl is-active docker' \
  'active' \
  "pp-www: docker service active"

check_pf_shell pp-www \
  'c=$(docker ps --filter status=running --format "{{.Names}}" 2>/dev/null | grep -cE "wordpress|db"); [ "$c" -ge 2 ] && echo "OK_$c" || echo "LOW_$c"' \
  'OK_' \
  "pp-www: wordpress + db containers running"

# WordPress inside the container -- HTTP 200 on :8080 (localhost-bound).
check_pf_shell pp-www \
  'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/' \
  '^200$|200' \
  "pp-www: WordPress container returns HTTP 200 on 127.0.0.1:8080"

# billing_site (gunicorn on 127.0.0.1:5000) -- check the systemd unit.
check_pf_shell pp-www \
  'systemctl is-active billing' \
  'active' \
  "pp-www: billing gunicorn service active"

check_pf_shell pp-www \
  'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5000/' \
  '^200$|200|302' \
  "pp-www: billing gunicorn returns HTTP 200/302 on 127.0.0.1:5000"

# Host nginx front-ends both -- vhost billing.voltgrid.com -> :5000,
# default vhost -> :8080.
check_pf_shell pp-www \
  'systemctl is-active nginx' \
  'active' \
  "pp-www: nginx front-end service active"

check_pf_shell pp-www \
  'curl -s -o /dev/null -w "%{http_code}" -H "Host: www.voltgrid.com" http://127.0.0.1/' \
  '^200$|200' \
  "pp-www: nginx serves WordPress for Host: www.voltgrid.com"

check_pf_shell pp-www \
  'curl -s -o /dev/null -w "%{http_code}" -H "Host: billing.voltgrid.com" http://127.0.0.1/' \
  '^200$|200|302' \
  "pp-www: nginx serves billing for Host: billing.voltgrid.com"

# is-inet unbound has the apex + mail A records. Query is-inet's unbound
# DIRECTLY (via 8.8.8.8 lo alias) -- otherwise corp AD DNS answers first
# with the internal 172.16.8.5 A record (that's correct behavior for
# internal clients; the unbound records are what OUTSIDE hosts see).
check_pf_shell pp-syslog \
  'r=$(nslookup voltgrid.com 8.8.8.8 2>/dev/null | awk "/^Address: / {print \$2; exit}"); [ "$r" = "52.96.223.2" ] && echo "OK_$r" || echo "GOT_$r"' \
  'OK_52\.96\.223\.2' \
  "is-inet: unbound resolves voltgrid.com apex -> 52.96.223.2"

check_pf_shell pp-syslog \
  'r=$(nslookup www.voltgrid.com 8.8.8.8 2>/dev/null | awk "/^Address: / {print \$2; exit}"); [ "$r" = "75.21.1.1" ] && echo "OK_$r" || echo "GOT_$r"' \
  'OK_75\.21\.1\.1' \
  "is-inet: unbound resolves www.voltgrid.com -> 75.21.1.1 (pp-external-fw WAN)"

check_pf_shell pp-syslog \
  'r=$(nslookup billing.voltgrid.com 8.8.8.8 2>/dev/null | awk "/^Address: / {print \$2; exit}"); [ "$r" = "75.21.1.1" ] && echo "OK_$r" || echo "GOT_$r"' \
  'OK_75\.21\.1\.1' \
  "is-inet: unbound resolves billing.voltgrid.com -> 75.21.1.1 (pp-external-fw WAN)"

# Email container up + Dovecot listening + our bob.burke test user exists.
# Avoid Docker's `--format "{{.Status}}"` here -- Ansible tries to Jinja-
# render the braces and fails. Grep the plain `docker ps` output instead.
check_pf_shell is-inet \
  'docker ps --filter name=email 2>&1 | grep -E "\\s+Up\\s+" | head -1' \
  '\bUp\b' \
  "is-inet: email container running"

check_pf_shell is-inet \
  'docker exec email getent passwd bob.burke 2>&1 | head -1' \
  'bob.burke' \
  "is-inet: bob.burke unix user exists in email container (mailbox provisioned)"

# =========================================================================
# 10. SOC tier — Splunk data quality
# =========================================================================
# Section 7 proves splunkd is up, ports are listening and forwarders hold
# sockets. It does NOT prove events parse. Every check in section 7 passed
# for the entire period two Sysmon add-ons were nulling each other's CIM
# fields -- ES's DNS panels were blank while event counts climbed, and
# nothing here noticed. Sockets are not evidence of normalisation.
#
# These checks assert the outcome: that searches return correctly mapped
# fields. They run as svc_verify (roles/splunk-verify-user), a search-only
# account, so the verifier never holds the admin credential. The SPL lives
# on pp-splunk in the runner rather than inline here -- it is full of double
# quotes that do not survive `ansible -m shell -a "..."`.
# =========================================================================
section "10. SOC tier — Splunk data quality"

VERIFY_DATA=/opt/splunk/etc/apps/arbitr_verify/bin/verify_data.sh

if ! A pp-splunk -m ansible.builtin.shell \
     -a "test -x $VERIFY_DATA && echo RUNNER_OK" --one-line | grep -q RUNNER_OK; then
  fail "pp-splunk: data-quality runner missing at $VERIFY_DATA"
  note "Deploy predates roles/splunk-verify-user — re-run with --tags splunk-verify-user"
else

  # MUST come first. On 2026-08-18 svc_verify could see 74 of ~406,000 Sysmon
  # events and all four checks below still returned clean OK tokens -- one of
  # them passed on 13 events. A restricted account emits well-formed tokens, so
  # nothing downstream is trustworthy until this passes.
  #
  # COMPARED AGAINST ADMIN, not against a bare floor. On 2026-08-20 the
  # floor-only version failed a fresh deploy three times reporting
  # VISIBILITY_FAIL_0_raw_events, where zero was simply correct -- the range was
  # minutes old and nothing had sent an event yet. "There is no data" and "this
  # account cannot see the data" are the two states this check exists to
  # separate, and a floor cannot separate them. Asking admin the same question
  # through the same interface can.
  admin_events=$(A pp-splunk -m ansible.builtin.shell -a \
    "printf 'user = \"$SPLUNK_AUTH\"\n' | curl -sS -k -K - --url https://127.0.0.1:8089/services/search/jobs/export --data-urlencode 'search=search index=* source=\"WinEventLog:Microsoft-Windows-Sysmon/Operational\" | stats count AS e | fields e' --data-urlencode earliest_time=-7d --data-urlencode latest_time=now --data-urlencode output_mode=csv 2>/dev/null | tail -1 | tr -dc '0-9'" \
    --one-line | grep -oE 'stdout\) *[0-9]+' | grep -oE '[0-9]+' | head -1)
  admin_events=${admin_events:-0}

  if [ "$admin_events" -eq 0 ]; then
    note "verifier visibility: skipped — admin sees 0 events too, so there is nothing to be blind to (young range?)"
  else
    check_pf_shell_token pp-splunk \
      "$VERIFY_DATA visibility" \
      'VISIBILITY_OK' \
      "pp-splunk: verifier account can see the data admin can ($admin_events events)"
  fi

  check_pf_shell_token pp-splunk \
    "$VERIFY_DATA apps" \
    'SYSMON_ADDONS_OK' \
    "pp-splunk: exactly one Sysmon add-on installed (two collide and null CIM fields)"

  # DNS_NO_EVENTS also fails this, deliberately: a SIEM with no DNS telemetry
  # over 7 days is a finding, not a pass. Read the token to tell them apart.
  check_pf_shell_token pp-splunk \
    "$VERIFY_DATA dns_src" \
    'DNS_SRC_OK' \
    "pp-splunk: every Sysmon DnsQuery event has src mapped (ES DNS panels group by it)"

  check_pf_shell_token pp-splunk \
    "$VERIFY_DATA proc_cim" \
    'PROC_CIM_OK' \
    "pp-splunk: ProcessCreate carries process + parent_process_* (the collided fields)"

  # Server-side DNS. Sysmon records the querying process but never which server
  # answered, so Network_Resolution fed by Sysmon alone is 100% message_type
  # "unknown" -- which blanks every ES DNS panel that filters on it while the
  # key indicators still populate. The DC debug logs supply the other half.
  check_pf_shell_token pp-splunk \
    "$VERIFY_DATA dns_server" \
    'DNSSRV_OK' \
    "pp-splunk: DC DNS logs reach Network_Resolution with Query AND Response"

  # Can fail while dns_src passes: search-time config does not retroactively
  # repair summaries built while the mapping was broken. That means rebuild
  # the acceleration, not that the add-ons are wrong.
  check_pf_shell_token pp-splunk \
    "$VERIFY_DATA dm_src" \
    'DM_SRC_OK' \
    "pp-splunk: Network_Resolution acceleration contains src (else rebuild acceleration)"

fi

# =========================================================================
# 11. SOC hunt workstations
# =========================================================================
# win-hunt-1..6. Added to [members], [voltgrid] and [splunk-forwarder] on
# 2026-08-17; nothing verified them until now. An analyst box that is not
# domain-joined, or not forwarding, degrades the SOC silently -- the range
# still looks healthy because every other tier is fine.
# =========================================================================
section "11. SOC hunt workstations"

hunt_total=$(n_hosts hunt)
if [ "$hunt_total" -eq 0 ]; then
  note "hunt: 0 hosts in inventory (skipping)"
else
  hunt_joined=$(count_ps_predicate hunt \
    '(Get-WmiObject Win32_ComputerSystem).PartOfDomain' \
    '\(stdout\)[[:space:]]+True')
  if [ "$hunt_joined" -eq "$hunt_total" ]; then
    pass "hunt: $hunt_joined/$hunt_total domain-joined to voltgrid.com"
  else
    fail "hunt: $hunt_joined/$hunt_total domain-joined to voltgrid.com"
  fi

  hunt_uf=$(count_ps_predicate hunt \
    '(Get-Service SplunkForwarder -ErrorAction SilentlyContinue).Status' \
    '\(stdout\)[[:space:]]+Running')
  if [ "$hunt_uf" -eq "$hunt_total" ]; then
    pass "hunt: $hunt_uf/$hunt_total running SplunkForwarder"
  else
    fail "hunt: $hunt_uf/$hunt_total running SplunkForwarder"
  fi


  # PowerShell single quotes: the outer bash string must be double-quoted to
  # carry the registry path's spaces, so the inner quoting cannot also be
  # double or `ansible -a "..."` would break on it.
  hunt_autologon=$(count_ps_predicate hunt \
    "(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').AutoAdminLogon" \
    '\(stdout\)[[:space:]]+1')
  if [ "$hunt_autologon" -eq "$hunt_total" ]; then
    pass "hunt: $hunt_autologon/$hunt_total configured for autologin"
  else
    fail "hunt: $hunt_autologon/$hunt_total configured for autologin"
  fi

  # ANALYSTS DO NOT GET EMULATED USERS.
  #
  # [hunt] is deliberately excluded from [aue] and [ae], so the aue_agent role
  # never targets these hosts -- and for months that was taken as sufficient.
  # It is not. On 2026-08-24, enabling user emulation in the SimSpace platform
  # installed the AUE agent on all six hunt workstations anyway: MSI install
  # records dated that day, a scheduled task named AUEAgent in Running state,
  # and a live aue-agent process on every one. The agent is NOT baked into
  # global/RDP_Windows_10:1.0.6 -- the platform pushed it.
  #
  # So the Ansible-side exclusion is not the control it appears to be. The
  # control is the platform's emulation host set, which lives outside this
  # repo entirely and which nothing here can enforce. What this repo CAN do is
  # notice, which is what this check is for: it converts a silent platform
  # config drift into a failed check.
  #
  # Why it matters beyond tidiness: emulated users on an analyst workstation
  # inject synthetic process, browser and file activity into exactly the host
  # a hunter is using to investigate, so their own tooling shows up as
  # adversary-shaped noise in their own telemetry.
  hunt_aue=$(count_ps_predicate hunt \
    '$t=Get-ScheduledTask -TaskName AUEAgent -ErrorAction SilentlyContinue; $p=Get-Process aue-agent -ErrorAction SilentlyContinue; if ($t -or $p) { Write-Output AUE_PRESENT } else { Write-Output AUE_ABSENT }' \
    '\(stdout\)[[:space:]]+AUE_ABSENT')
  if [ "$hunt_aue" -eq "$hunt_total" ]; then
    pass "hunt: $hunt_aue/$hunt_total free of the AUE agent (analysts get no emulated users)"
  else
    fail "hunt: $hunt_aue/$hunt_total free of the AUE agent — $((hunt_total - hunt_aue)) still running emulation; the platform's emulation host set still includes hunt workstations"
  fi
fi

# =========================================================================
# 12. Endpoint telemetry coverage
# =========================================================================
# Checks the WHOLE [sysmon] group, not one sample host. Section 7 asserted
# Sysmon on pp-bp-wkstn-1 and passed for months while pp-file, pp-sql, pp-mail
# and all six hunt workstations had no Sysmon service at all -- a single
# in-group sample cannot detect a coverage gap, only a total outage.
# =========================================================================
section "12. Endpoint telemetry coverage"

sysmon_total=$(n_hosts sysmon)
if [ "$sysmon_total" -eq 0 ]; then
  fail "sysmon: 0 hosts in inventory — the [sysmon] group is missing or empty"
else
  sysmon_running=$(count_ps_predicate sysmon \
    '(Get-Service Sysmon64 -ErrorAction SilentlyContinue).Status' \
    '\(stdout\)[[:space:]]+Running')
  if [ "$sysmon_running" -eq "$sysmon_total" ]; then
    pass "sysmon: $sysmon_running/$sysmon_total hosts running Sysmon64"
  else
    fail "sysmon: $sysmon_running/$sysmon_total hosts running Sysmon64"
  fi
fi

# pp-dcs-ctrl is OT process equipment and excluded by decision (Eric,
# 2026-08-18). Assert the exclusion holds, so a future :children edit that
# quietly sweeps it in gets caught here rather than in a scenario review.
if ansible sysmon --list-hosts 2>/dev/null | grep -qw pp-dcs-ctrl; then
  fail "sysmon: pp-dcs-ctrl is in the [sysmon] group — it is excluded by decision"
else
  pass "sysmon: pp-dcs-ctrl correctly excluded (OT process equipment)"
fi

# =========================================================================
section "13. Forwarder coverage — no host is dark by accident"

# WHY THIS SECTION EXISTS.
#
# Section 7 counts running forwarders AGAINST [splunk-forwarder]. That answers
# "of the hosts we expect to forward, how many do?" -- which can never notice a
# host that SHOULD be expected and is not in the group at all. It reports a
# clean 47/47 while a 48th host sits dark.
#
# That is not hypothetical. pp-dcs-ctrl had no universal forwarder, no Sysmon
# and no events of any kind, and section 7 passed every run. It surfaced only
# because a manual search returned 44 Windows hosts against an inventory of 45,
# and it got there structurally rather than by decision: [ot_servers] was never
# made a child of [splunk-forwarder], so nobody ever chose to exclude it.
#
# These checks invert the question -- "of the hosts that exist, which produce no
# telemetry?" -- so a silent host is either an explicit entry in
# [splunk_forwarder_exempt] or a failure here.
#
# THE BASIS IS [windows], NOT [members], and that distinction is the whole
# check. [members] is domain membership: it holds 40 hosts and excludes
# pp-dc01, pp-dc02, pp-dc03, pp-dmz-dns and pp-dmz-smtp -- the domain
# controllers and both DMZ hosts, which are the highest-value log sources here.
# Anchoring coverage on it would have produced a check that structurally could
# not report a dark DC: the same class of blind spot one level up from the one
# it was written to close. [windows] is all 45 Windows hosts, which is the
# population that should be producing Windows telemetry.

fwd_list=$(ansible splunk-forwarder --list-hosts 2>/dev/null | tail -n +2 | tr -d ' \r' | sed '/^$/d' | sort -u)
win_list=$(ansible windows --list-hosts 2>/dev/null | tail -n +2 | tr -d ' \r' | sed '/^$/d' | sort -u)
# An empty or absent group makes ansible warn on stderr and print "hosts (0):"
# on stdout, so this correctly yields an empty list rather than an error.
exempt_list=$(ansible splunk_forwarder_exempt --list-hosts 2>/dev/null | tail -n +2 | tr -d ' \r' | sed '/^$/d' | sort -u)

n_win=$(printf '%s' "$win_list" | grep -c . || true)
n_exempt=$(printf '%s' "$exempt_list" | grep -c . || true)

# comm(1) rather than a shell loop over an unquoted list. The loop version
# depended on word-splitting an unquoted "$list", which bash does and zsh does
# not -- and when it does not split, the whole multi-line string is handed to
# `grep -xF` as ONE pattern, where grep treats each embedded newline as a
# SEPARATE pattern and matches any line at all. So the loop silently matched
# everything and `uncovered` could never be non-empty. A check that cannot fail
# is not a check; comm compares two sorted sets with no shell semantics in the
# middle and cannot degrade that way.
uncovered=$(comm -23 <(printf '%s\n' "$win_list") <(printf '%s\n' "$fwd_list" "$exempt_list" | sed '/^$/d' | sort -u) | tr '\n' ' ' | sed 's/ *$//')

if [ "$n_win" -eq 0 ]; then
  fail "coverage: [windows] resolved to 0 hosts — inventory did not parse"
elif [ -n "$uncovered" ]; then
  fail "coverage: Windows hosts with no forwarder and no exemption: $uncovered"
else
  pass "coverage: all $n_win Windows hosts forward to Splunk or are explicitly exempt"
fi

# A host in both groups means two people recorded opposite decisions and
# [splunk-forwarder] silently won. Cheap to check, and it keeps the exemption
# list meaningful rather than decorative.
contradict=$(comm -12 <(printf '%s\n' "$exempt_list" | sed '/^$/d') <(printf '%s\n' "$fwd_list") | tr '\n' ' ' | sed 's/ *$//')
if [ -n "$contradict" ]; then
  fail "coverage: exempt but also in [splunk-forwarder]: $contradict"
else
  pass "coverage: exemption list consistent with [splunk-forwarder] ($n_exempt exempt)"
fi

# The two halves of the pp-dcs-ctrl decision, asserted separately, because they
# point in OPPOSITE directions and a future :children edit could flip either.
#
# The line is INSTRUMENT vs OBSERVE. Sysmon instruments the OS with a kernel
# driver and process-level hooks and stays off process-critical OT equipment
# (asserted in section 12). A universal forwarder only reads event logs Windows
# already writes, which is ordinary practice on an HMI or engineering station
# even where an EDR agent would never be allowed -- and pp-dcs-ctrl is in [ae],
# a host attacks are actively run against, so its compromise has to leave
# evidence somewhere.
if printf '%s\n' "$fwd_list" | grep -qxF pp-dcs-ctrl; then
  pass "coverage: pp-dcs-ctrl forwards Windows event logs (OT station, no Sysmon)"
else
  fail "coverage: pp-dcs-ctrl is not in [splunk-forwarder] — it would produce no telemetry"
fi

# =========================================================================
# Summary
# =========================================================================
section "Summary"

total=$((PASS+FAIL))
printf "  Total checks : %d\n" "$total"
printf "  ${G}Pass${N}         : %d\n" "$PASS"
printf "  ${R}Fail${N}         : %d\n" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "${R}Failed checks:${N}"
  for f in "${FAILURES[@]}"; do echo "  • $f"; done
  if [ "$VERBOSE" -eq 0 ]; then
    echo
    echo "${D}Re-run with -v to see ansible's output for each failure.${N}"
  fi
  exit 1
fi

echo
printf "${G}All checks passed.${N}\n"
exit 0
