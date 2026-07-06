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
check_vyos pp-isp-router \
  "show ip bgp summary" \
  'Establ|[0-9]+:[0-9]+:[0-9]+' \
  "pp-isp-router: eBGP session Established (peer pp-external-firewall)"

check_pf_shell pp-external-firewall \
  'vtysh -c "show ip bgp summary"' \
  'Establ|[0-9]+:[0-9]+:[0-9]+' \
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
check_pf_shell pp-ot-firewall \
  'c=$(netstat -rn -f inet | grep -c "^default"); [ "$c" -ge 1 ] && echo HAS_DEFAULT || echo NO_DEFAULT' \
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
  '$c=(Get-DnsServerResourceRecord -ZoneName voltgrid.com -RRType A | Where-Object {$_.RecordData.IPv4Address -match "^10\.255\.24"}).Count; if ($c -eq 0) {"OK_CLEAN"} else {"LEAK_$c"}' \
  '\(stdout\)[[:space:]]+OK_CLEAN' \
  "pp-dc01: no 10.255.240.x A records in voltgrid.com zone (mgmt DDNS scrubbed)"

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
  "pp-splunk indexer service active"

check_pf_shell pp-splunk \
  'ss -lnt | grep -qE ":9997\\b" && echo OK_9997 || echo MISSING_9997' \
  'OK_9997' \
  "pp-splunk listening on :9997 (UF receiver)"

check_pf_shell pp-splunk \
  'ss -lnt | grep -qE ":8000\\b" && echo OK_8000 || echo MISSING_8000' \
  'OK_8000' \
  "pp-splunk listening on :8000 (Splunk Web)"

check_pf_shell pp-splunk \
  'ss -lnt | grep -qE ":8089\\b" && echo OK_8089 || echo MISSING_8089' \
  'OK_8089' \
  "pp-splunk listening on :8089 (Splunk REST/mgmt)"

# pp-syslog UF forwarding /var/log/remote/* -- catches "UF running but no
# ESTABLISHED conn to indexer" silent break.
check_pf_shell pp-syslog \
  'systemctl is-active SplunkForwarder' \
  'active' \
  "pp-syslog SplunkForwarder service active"

check_pf_shell pp-syslog \
  'c=$(ss -ant | grep "172.16.9.20:9997" | grep -c ESTAB); [ "$c" -ge 1 ] && echo OK_ESTAB || echo NO_ESTAB' \
  'OK_ESTAB' \
  "pp-syslog UF has ESTABLISHED connection to indexer :9997"

# Total forwarder count -- Linux UFs (~5) + Windows UFs (~40+) once
# the rollout is done. Floor 30 confirms the Windows batch landed.
check_pf_shell pp-splunk \
  'c=$(ss -ant | grep ":9997 " | grep -c ESTAB); [ "$c" -ge 30 ] && echo "OK_UFS_$c" || echo "LOW_UFS_$c"' \
  'OK_UFS_' \
  "pp-splunk: >= 30 UFs ESTABLISHED on :9997 (Linux + Windows rollout done)"

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
# started Sysmon64 service. Sysmon events land in index=windows via UF.
check_ps pp-bp-wkstn-1 \
  '(Get-Service Sysmon64 -ErrorAction SilentlyContinue).Status' \
  '\(stdout\)[[:space:]]+Running' \
  "pp-bp-wkstn-1: Sysmon64 service running"

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
# lo alias) rather than through corp AD DNS. AD DNS is authoritative for
# voltgrid.com locally and answers with internal IPs; the unbound records
# are the *external-facing* view meant for hosts outside the range.
# 8.8.8.8 is a lo alias on is-inet so this hits unbound directly.
check_pf_shell pp-syslog \
  'r=$(nslookup www.faa.gov 8.8.8.8 2>/dev/null | awk "/^Address: / {print \$2; exit}"); [ "$r" = "70.39.65.10" ] && echo "OK_$r" || echo "GOT_$r"' \
  'OK_70\.39\.65\.10' \
  "is-inet: unbound resolves www.faa.gov -> 70.39.65.10 (global_dns loaded)"

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
