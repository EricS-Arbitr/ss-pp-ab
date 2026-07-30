# vyos_mirror

Router-0 (VyOS) side of the ERSPAN-lite traffic-capture path to
so-sensor-1.

## Two mechanisms combined

**1. Declarative: GRE tunnel `tun0`.** Configured via `vyos.vyos.vyos_config`
from the group_vars values:

```
set interfaces tunnel tun0 encapsulation gre
set interfaces tunnel tun0 source-address {{ vyos_gre_source_ip }}
set interfaces tunnel tun0 remote          {{ vyos_gre_remote_ip }}
set interfaces tunnel tun0 address         {{ vyos_gre_local_addr }}/{{ vyos_gre_tunnel_prefix }}
```

**2. Imperative: tc mirred rules per source interface.** VyOS 1.4/1.5's
declarative CLI doesn't natively support "mirror source interface into a
GRE tunnel destination" — the `set interfaces ethernet ethX mirror
ingress <iface>` syntax only accepts local physical interfaces, not
tunnel interfaces. So we drop to raw `tc` via a startup script installed
at `/config/scripts/vyatta-postconfig-bootup.script` (VyOS's blessed
hook for post-config-load imperative shell). Idempotency via a marker
file + tc filter compare.

```
tc qdisc add dev {{ item }} handle ffff: ingress
tc filter add dev {{ item }} parent ffff: matchall action mirred egress mirror dev tun0
tc qdisc replace dev {{ item }} handle 1: root prio
tc filter add dev {{ item }} parent 1: matchall action mirred egress mirror dev tun0
```

(Two filter rules per interface — one on ingress qdisc, one on root — to
catch both directions of traffic.)

## Idempotency

- tunnel: `vyos_config` diffs actual config to intent, no-op if match.
- tc: script re-runs on boot; `tc filter show` output compared to
  desired state, deltas applied.

## Variables

From host_vars/router-0.yml:

- `vyos_mirror_source_interfaces` — list of physical NICs to mirror
- `vyos_gre_source_ip` / `vyos_gre_remote_ip` — tunnel endpoints
- `vyos_gre_local_addr` / `vyos_gre_remote_addr` / `vyos_gre_tunnel_prefix`
