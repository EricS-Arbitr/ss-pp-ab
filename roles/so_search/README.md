# so_search

Renders `distributed-net-ubuntu-search`, runs `so-setup network <name>`,
joins the manager. Structurally near-identical to so_manager but:

- `install_type=SEARCHNODE`
- Uses `MSRV` + `MSRVIP` + `SOREMOTEPASS1/2` to auto-join the manager
  (the salt-key remote-invoke handles grid acceptance without manual
  SOC WebUI clicks)
- No WEBUSER/WEBPASSWD (those live on manager only)
- Shorter install (~5-10 min vs 20-30 for manager)

Runs AFTER 40-manager.yml. Depends on so_base + manager being fully
up (so-status green on manager) — the join step SSHes to manager
during install.
