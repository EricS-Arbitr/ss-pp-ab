# so_base

Cross-cutting prep for every SO Linux node (manager + search + sensor).
Runs BEFORE so_manager / so_search / so_sensor. Idempotent.

## Responsibilities

1. Install baseline packages needed for SO 2.4 network install on Ubuntu
   22.04 (curl, ca-certificates, python3-apt, etc.).
2. Configure system-wide HTTP/HTTPS proxy env vars so `so-setup network`
   (and Docker + Elastic apt repos it adds) reaches upstream via the
   mgmt-plane proxy at `so_upstream_proxy` (default: `10.255.240.1:3128`).
3. Fetch the pinned SO source tarball from the ansible-hosted mirror
   (`so_source_tarball_url`), extract to `/root/manager_setup/securityonion`
   so `so-setup` finds it via its `/root/manager_setup/securityonion/setup`
   auto-detect path (see so-setup lines 138-139).
4. Overlay the snapshotted `so-setup`, `so-functions`, `so-variables`,
   `so-whiptail` from `files/setup-automation-source/` on top of the
   extracted source — belt-and-suspenders in case the tarball's copies
   drift from our pinned snapshot.
5. Populate `/etc/hosts` with peer SO node hostnames so search + sensor
   can resolve `so-manager` for the join step (short-hostname resolution
   is what `MSRV` in the answer file needs).
6. Ensure UFW is not running (SO manages its own firewall via
   `so-firewall`) but do NOT install/enable Docker — `so-setup` installs
   its own pinned Docker version and will fail if a conflicting Docker
   is present.

## Variables

- `so_git_ref` (from group_vars/all.yml) — pinned SHA; also drives which
  tarball we pull from the mirror.
- `so_source_tarball_url` — full URL to the tarball on the mirror.
- `so_upstream_proxy` — corp proxy URL for so-setup's upstream fetches.
- `so_peer_hosts` (derived from inventory) — list of `{hostname, ip}`
  dicts used to populate /etc/hosts.
