# so_manager

Renders the `distributed-net-ubuntu-manager` answer file from the pinned
snapshot, drops it into `/root/manager_setup/securityonion/setup/automation/`,
runs `so-setup network <name>`, waits for the ~20-30 min install to
complete, reboots, verifies `so-status`.

## Flow

1. Precondition check: `so_base` ran (`/root/manager_setup/securityonion/setup/so-setup` exists) and the source tree is fresh.
2. Render `manager.conf.j2` from group_vars + host_vars, save as
   `/root/manager_setup/securityonion/setup/automation/so-ansible-manager`.
3. Idempotency guard: if `/opt/so/state/installed` exists, skip so-setup
   entirely (SO is already installed on this host).
4. Invoke: `cd /root/manager_setup/securityonion/setup && sudo ./so-setup network so-ansible-manager`.
   Streams to `/root/so-setup.log`. Uses `async` + `poll: 0` because the
   install takes 20-30 min and we don't want a blocking Ansible SSH.
5. Poll for completion (async_status) with generous timeout.
6. Reboot handling: SO's own reboot is suppressed by setting
   `SKIP_REBOOT=1` in the answer file, then this role's post-install
   task issues an Ansible-managed reboot + wait_for_connection.
7. Post-reboot verification: run `sudo so-status`, expect "STATUS: OK".

## Variables that flow into the answer file

From group_vars/all.yml + so_all.yml + vault.yml:

- `so_web_user` (WEBUSER), `so_web_password` (WEBPASSWD1/2 from vault)
- `so_remote_password` (SOREMOTEPASS1/2 from vault)
- `so_allow_subnets` (ALLOW_CIDR — comma-joined)
- `so_nids`, `so_zeek_version`, `so_rule_set`, `so_manager_adv`

From host_vars/so-manager.yml:

- `so_hostname` (HOSTNAME)
- `so_prod_ip` / `so_prod_prefix` / `so_prod_gateway` (MIP/MMASK/MGATEWAY)
- `so_prod_dns` (MDNS — comma-joined)
