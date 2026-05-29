# Syslog Server Role

## Description
Configures a Linux host as the range's central rsyslog collector. Installs rsyslog (no-op on Ubuntu Desktop/Server, which ship with it), opens UDP **and** TCP port 514, and writes incoming messages to per-host files at `/var/log/remote/<hostname>/syslog.log`. Local rsyslog/journald messages keep their normal `/var/log/syslog` path; only remote events land under `/var/log/remote/`, so the Splunk Universal Forwarder on the same host can tail that tree with correct `host=` attribution via the `lin_inputs.conf.j2` overlay's `host_segment = 4` stanza (see `roles/splunk-forwarder/templates/lin_inputs.conf.j2`).

## Variable Definition Location
Variables for this role are defined in:
- **group_vars/all.yml** — `syslog_server_ip` (informational on the server; the role binds to all interfaces)
- **inventory** — host membership in the `[syslog]` group selects which host(s) get this role

## Required Variables

None — the role itself has no required variables. Membership in `[syslog]` is what targets the role at a host.

## Optional Variables

This role does not currently expose tunables. If you need to change the listen port, file layout, or transports, edit `templates/30-remote.conf.j2`.

## Companion Variables (used elsewhere, but related)

| Variable | Where | Description |
|----------|-------|-------------|
| syslog_server_ip | group_vars/all.yml | IP that clients forward to. The syslog client plays in `arbitr_pp_playbook.yaml` (Linux, VyOS, pfSense) reference this. The server itself binds to `*:514` so this var is informational on the server side. |

## Prerequisites
- The host runs Ubuntu (`apt`-managed). The Linux NM pre-config play and `common` role run before this one.
- Network reachability from every sender to `syslog_server_ip:514` is in place — verified end-to-end during the routing fixes (corp/DMZ/OT all reach the PP-Services subnet that pp-syslog lives on).
- The host is a member of `[splunk-forwarder]` (transitively via `[corporate_servers]` for pp-syslog) so the Splunk UF picks up the `/var/log/remote/` tree and ships events to pp-splunk.

## Notes
- Listens on **both** UDP and TCP 514. UDP matches pfSense/VyOS defaults; TCP is available for any client configured to send over TCP. Most clients in this range use UDP for simplicity.
- The rsyslog filter (`if $fromhost-ip != '127.0.0.1' then { ... stop }`) ensures remote events land **only** in `/var/log/remote/<hostname>/syslog.log` and don't also flow into `/var/log/syslog` on the collector. Local kernel/cron/etc. messages keep their normal path because they originate from `127.0.0.1`.
- Per-host directory layout is intentional: Splunk UF's `host_segment = 4` reads the directory name as the `host=` field, so events show up under the **sender** (e.g., `pp-internal-router`, `pp-ot-firewall`) rather than under pp-syslog.
- File mode is `0640` (group `adm`), directory mode `0755`, owner `syslog:adm` — matches Ubuntu's stock log layout.
- Idempotent — re-runs only restart rsyslog if `30-remote.conf` content changed (handler `restart rsyslog`).
- pp-isp-router is explicitly excluded from the VyOS client play (`hosts: vyos:vyos_routes_only:!pp-isp-router`) because it represents the upstream ISP; sending its logs into the corp SIEM would break scenario fiction.

## Related upstream gap
See `UPSTREAM_FIXES.md`, entry **2026-05-29 · gap · range-development-ansible has no central syslog collector role** — this role is the PowerPlant overlay's reference implementation and could be lifted into the shared repo verbatim.
