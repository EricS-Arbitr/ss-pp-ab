# so_apt_mirror

Ansible-controller-hosted HTTP mirror for Security Onion install artifacts.
Serves:

- **SO source tree** at the pinned master SHA (`so_git_ref` in
  group_vars/all.yml), tarballed for one-shot fetch from SO nodes.
- **SO airgap ISO** (`so_iso_filename`), downloaded once from
  packages.securityonion.net via the mgmt-plane proxy.

Runs on `ansible_controller` (the ansible box itself, `ansible_connection=local`).
Nginx binds `http://{{ so_mirror_host }}:{{ so_mirror_port }}/`.

Paths served:

| URL | Filesystem | Purpose |
|---|---|---|
| `/so-source/securityonion-{{ so_git_ref[:12] }}.tar.gz` | `/var/www/so-mirror/so-source/` | git-cloned SO source at pinned SHA, tarred |
| `/so-iso/{{ so_iso_filename }}` | `/var/www/so-mirror/so-iso/` | SO airgap ISO |
| `/so-iso/SHA256SUMS` | same | ISO integrity checksums |

The SO nodes' `so_base` role fetches from these URLs during install. No
authentication (dev range only). If pulled into a customer range,
gate access via bs-ops-fw ACL or add nginx basic auth via a follow-up.

## Idempotency

- ISO download uses `ansible.builtin.get_url` with `checksum:` from
  `so_iso_sha256` — no re-fetch on subsequent runs.
- SO source snapshot: task checks for existing `securityonion-<sha>.tar.gz`
  and only clones+tars if missing.
- nginx config uses `notify: reload nginx` — only reloads if the config
  template renders differently.

## Variables

Defaults live in `defaults/main.yml`; overrides in group_vars/all.yml.

- `so_mirror_root: /var/www/so-mirror`
- `so_git_repo`, `so_git_ref`, `so_iso_filename`, `so_iso_url_upstream`,
  `so_iso_sha256`, `so_mirror_port`
