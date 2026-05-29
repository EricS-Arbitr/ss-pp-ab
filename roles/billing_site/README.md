# Billing Site Role

## Description
Deploys the Voltgrid Power customer billing portal on `pp-www`. Runs Flask + gunicorn as a host-direct systemd service (`billing.service`) bound to `127.0.0.1:5000` and configures host nginx to reverse-proxy `billing.voltgrid.com` to it. WordPress (deployed by the `wordpress-pv` role) keeps serving every other Host header on `127.0.0.1:8080`. The SQLite DB at `/var/lib/billing/billing.db` is seeded once with 80 fictional customers, 6 months of bills, and daily kWh readings; the seed is idempotent and reproducible (`random.Random(42)`).

## Variable Definition Location
Variables for this role are defined in:
- **group_vars/all.yml** — proxy configuration used to pull Python packages
- **host_vars/[hostname].yml** (or a group covering pp-www) — optional secrets

## Required Variables

### In group_vars/all.yml

| Variable | Required | Description |
|----------|----------|-------------|
| inet_proxy_addr | Yes | IP address of the corporate proxy (used by pip to reach PyPI) |
| inet_proxy_port | Yes | Port number for the corporate proxy |

## Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| billing_secret_key | `voltgrid-dev-secret-change-me` | Flask `SECRET_KEY` env var passed to gunicorn. Override per-host or per-group to set a real value. |

## Prerequisites
- pp-www is Ubuntu (`apt`-managed) and a member of `[wordpress-pv]` — the `wordpress-pv` role must run before this one because nginx reverse-proxies the default vhost to the WordPress container on `127.0.0.1:8080`.
- The corporate proxy is reachable from pp-www so `pip` can install Flask, Werkzeug, and gunicorn.
- DNS records `billing.voltgrid.com` and `www.voltgrid.com` resolve to pp-www's data-plane IP (created by the `dns` role via `internal_dns_records`).

## Notes
- The Flask app source under `files/app/` is synced verbatim to `/opt/billing/app/`; the virtualenv lives at `/opt/billing/venv`.
- DB initialization runs `/opt/billing/app/init_db.py` exactly once, gated by `creates: /var/lib/billing/billing.db` — re-running the role will not reseed.
- All 80 seeded customers share the demo password `voltgrid123`; usernames are `<first>.<last>` (e.g. `joseph.johnson`), account numbers `VG-100000`..`VG-100079`.
- The stock nginx default site is removed; this role's two vhost files (`billing.voltgrid.com.conf`, `wordpress-default.conf`) replace it.
- The `billing` systemd unit and nginx are managed via the role's handlers (`restart billing`, `reload nginx`).
