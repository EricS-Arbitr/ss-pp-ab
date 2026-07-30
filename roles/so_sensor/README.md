# so_sensor

Renders `distributed-net-ubuntu-sensor`, brings up the GRE tunnel `tun0`
(sensor side of vyos_mirror's tunnel), runs `so-setup network`, joins
manager. `BNICS=tun0` so Suricata + Zeek bind to the decapsulated mirror
traffic.

## GRE tunnel setup

Sensor side must match router-0's tunnel:

- Local (sensor): `so_prod_ip` (172.16.5.20)
- Remote (router-0): 172.16.5.1
- Local tunnel addr: `so_gre_tunnel_local` (10.100.0.2/30)

Configured via a netplan tunnel drop-in file `/etc/netplan/60-so-mirror-tun.yaml`
so the tunnel persists across reboots. Netplan on Ubuntu 22.04 supports
GRE tunnels natively via the `tunnels:` section.

**Sequencing:** tun0 must exist BEFORE `so-setup` runs — the answer file
sets `BNICS=tun0` and so-setup validates the interface exists during
install. This role therefore configures + brings up tun0 in the same
play, before invoking so-setup.

## Suricata/Zeek + GRE decap

Because tun0 is a mode=gre kernel tunnel, packets arriving GRE-encapsulated
from router-0 get decapsulated automatically. Suricata/Zeek see the raw
mirrored L3 payload on tun0 in promiscuous mode. If we ever run into
"only see GRE headers" behavior, we'd switch to sniffing the physical
NIC + a suricata GRE-decap config; not needed with kernel decap.

## Depends on

- so_base
- vyos_mirror (router-0 GRE endpoint must be up so tun0 can complete
  the tunnel handshake and see traffic)
