# Fuel Farm (POL) — Build Sheet

**Subsystem:** Bulk fuel storage, truck loading rack, and aircraft delivery
**Enclave:** `fuel` (OT / RVIN) — segmented Purdue chain off `bs-modbus-gateway`: MTU `172.16.45.0/29` (gw `.45.1`) · Fuel-PLC `172.16.45.8/29` (gw `.45.9`) · Fuel-Sim `172.16.46.0/24` (gw `.46.16`) · Fuel-Data `172.16.48.0/24` (gw `.48.1`)
**Management:** all hosts dual-homed onto `10.255.240.0/20` (gw `10.255.240.1`); Ansible reaches every host over its mgmt NIC (mgmt IPs are sequential within the shared `/20` — see §1)
**Purdue placement:** field sim (L0) → OpenPLC (L1) → shared control-room HMI (L2); historian + audit DB on a dedicated **in-enclave L2 data segment** (Fuel-Data `172.16.48.0/24`); optional read-only historian replica in Engineering
**Deployment:** 100% Ansible, idempotent, resettable to known-good between exercise iterations

This sheet is self-contained: host specs, the physical model, the OpenPLC control logic and Modbus map, the HMI/historian/audit-DB design, the process simulator and 48-hour replay harness, the Ansible role layout with dual-home connection vars, firewall rules, acceptance tests, and the training/attack surface. Build order is given per host at the end.

---

## 1. Host inventory

All hosts are dual-homed: `eth0` on a production OT segment, `eth1` on management (`10.255.240.0/20`). `ansible_host` is the **mgmt** IP; the blueprint assigns mgmt IPs sequentially across all VmInstances, so fuel hosts are interleaved with the rest of the project's mgmt allocation rather than living in a dedicated `/24`. Standard hosts run `net.ipv4.ip_forward=0`; `control-room-hmi` is a designated OT **bridge** (forwards MTU↔Power-PLC, with a second production NIC on `172.16.47.9`). `bs-modbus-gateway` (VyOS, in the `net` group) is the L3 gateway for all four fuel segments and routes up to `bs-ops-fw` (pfSense) via `172.31.1.16/30`. All Linux hosts run **Ubuntu 24.04 LTS Server** (headless, `systemd-networkd` renderer — matches the netplan in §9). **Platform constraint:** the `.2` host address is reserved in every subnet — never assign `.2` to any host (lesson learned; `control-room-hmi` therefore sits at `172.16.45.3`, not `.45.2`).

| Host | Role / Purdue | `eth0` (production) | `eth1` (mgmt) | OS | vCPU / RAM / disk | Core package |
|---|---|---|---|---|---|---|
| `ff-plc-1` | OpenPLC v4 runtime (L1) | 172.16.45.10  (Fuel-PLC /29) | 10.255.240.168 | Ubuntu 24.04 LTS Server | 2 / 2 GB / 20 GB | OpenPLC v4 runtime (container) |
| `fuel-farm-sim` | Field instrument sim + replay harness (L0) | 172.16.46.17  (Fuel-Sim /24) | 10.255.240.115 | Ubuntu 24.04 LTS Server | 2 / 4 GB / 20 GB | Python 3.12 venv, pymodbus, psycopg |
| `control-room-hmi` | FUXA HMI (L2) — **shared with power**, bridge host | 172.16.45.3  (MTU /29) + 172.16.47.9 (Power-PLC) | 10.255.240.173 | Ubuntu 24.04 LTS Server | 2 / 4 GB / 20 GB | FUXA (`frangoteam/fuxa`) |
| `fuel-hist` | Historian — Telegraf + InfluxDB 2.7 + Grafana (L2, **in-enclave**) | 172.16.48.18  (Fuel-Data /24) | 10.255.240.118 | Ubuntu 24.04 LTS Server | 2 / 4 GB / 60 GB | telegraf, `influxdb:2.7`, grafana |
| `fuel-db` | Audit DB — PostgreSQL 16 + TimescaleDB (L2) | 172.16.48.19  (Fuel-Data /24) | 10.255.240.175 | Ubuntu 24.04 LTS Server | 2 / 4 GB / 60 GB | postgresql-16, timescaledb |

Engineering access: programmed/administered from the Engineering Control Center (`172.31.8.0/24`) running OpenPLC Editor (Autonomy-Logic) — it reaches `ff-plc-1:8080` through `bs-ops-fw` (the L3.5 boundary) to upload the compiled program. An optional read-only historian replica lives at Engineering `172.31.8.5`. No EWS lives inside the fuel segments.

---

## 2. Two-tier Modbus topology

The fuel farm uses two Modbus TCP tiers, now spread across the segmented chain. Both tiers cross `bs-modbus-gateway`, which is the realistic routing choke point and the place to apply OT ACLs and detection.

- **Field bus (L1↔L0):** `ff-plc-1` (OpenPLC, **master**, Fuel-PLC `/29`) polls `fuel-farm-sim` (pymodbus **slave**, Fuel-Sim `/24`, the simulated transmitters/meters/limit switches) as a remote I/O device. Traffic routes `172.16.45.8/29 ↔ 172.16.46.0/24` through the gateway (`.45.9 ↔ .46.16`). The PLC reads field inputs and writes actuator commands back; the sim's physics react (pump on → fuel flows → meter increments → tank level drops).
- **SCADA bus (L2↔L1):** `ff-plc-1`'s built-in **Modbus TCP server** (port 502) exposes the consolidated process image. `control-room-hmi` (FUXA, MTU `/29`) and `fuel-hist` (Telegraf, Fuel-Data `/24`) read it across the gateway.

The register map in §4 is the **SCADA-bus** image (what HMI/historian see). The field-bus map on the sim mirrors the physical instruments one-to-one.

> Simpler fallback if remote-I/O config is troublesome on the chosen OpenPLC build: run the sim as a co-process that writes "field" values directly into OpenPLC holding registers/coils (the only Modbus-writable types) and have the ST program read those. Less realistic addressing, single Modbus tier. Prefer the two-tier design above.

---

## 3. Physical process model

**Bulk storage** — 3 JP-8 tanks, ~500,000 gal each:

| Tank | Product | Capacity (gal) | Instrumentation |
|---|---|---|---|
| T-101 | JP-8 | 500,000 | level, temp, water bottom, HH/H/L/LL switches, outlet valve |
| T-102 | JP-8 | 500,000 | same |
| T-103 | JP-8 | 500,000 | same |

**Distribution:** lead/lag issue pumps P-201 / P-202 → filter/separator → FSII additive injection → metered header → loading rack.

**Loading rack** — 2 positions (LR-1, LR-2), each with: deadman switch, grounding-clamp verification, overfill sensor, mass/volume flow meter with 32-bit totalizer, and a batch preset.

**Refueler fleet** — R-01…R-06, ~6,000 gal each (R-11-type bowsers).

**Aircraft parking** — pads PAD-A1, A2, B1, B2 (extend as needed), each carrying an assigned tail number and a fuel order.

**Operational flow (one cycle):**
1. Truck arrives → enters queue (DB row, state `QUEUED`).
2. Truck assigned a rack position + source tank (holding registers + DB).
3. Permissives met (grounding OK ∧ deadman held ∧ no overfill ∧ tank > LL ∧ ¬ESD) → issue pump starts → fuel transfers; totalizer increments; tank level drops.
4. Batch preset reached / deadman released → pump stops → **load transaction** recorded (gallons, meter start/end, tank, rack, truck, operator).
5. Truck dispatched to pad → delivers to aircraft → **delivery transaction** recorded (tail, pad, gallons, order).
6. Truck returns to queue / marked `AVAILABLE`.

---

## 4. OpenPLC control logic & Modbus map

**Runtime:** OpenPLC v4 (Autonomy-Logic). Modbus TCP server on **502**; web UI on **8080** (default creds `openplc`/`openplc` — the `fuel_plc` role **must** rotate these). Program authored in ST/LD in OpenPLC Editor, compiled, uploaded by the role.

**Interlocks implemented in the ST program:**
- Pump permissive = `GROUND_OK ∧ DEADMAN ∧ ¬OVERFILL ∧ ¬SRC_TANK_LL ∧ ¬ESD_ACTIVE`, where `SRC_TANK_LL` is the `*_LL_LVL` switch of the tank selected by `LR*_SRC_TANK`.
- Rack overfill → immediate load-valve close + pump stop for that position.
- Source-tank `*_LL_LVL` → pump protection lockout; `*_HH_LVL` → close that tank's outlet valve.
- ESD → latch all pumps off, all outlet/load valves closed; requires `ESD_RESET`.
- Lead/lag pump rotation on header pressure setpoint.

**SCADA-bus register map** (OpenPLC process image as read by FUXA/Telegraf). Coils FC1/5, discrete inputs FC2, input registers FC4, holding registers FC3/6/16.

**Coils — commands (`%QX` → Modbus coil):**

| Addr | Tag | Description |
|---|---|---|
| 0 | `P201_RUN_CMD` | Issue pump 1 run |
| 1 | `P202_RUN_CMD` | Issue pump 2 run |
| 2 | `T101_OUT_VLV` | Tank 101 outlet valve open |
| 3 | `T102_OUT_VLV` | Tank 102 outlet valve open |
| 4 | `T103_OUT_VLV` | Tank 103 outlet valve open |
| 5 | `LR1_LOAD_VLV` | Rack 1 load valve open |
| 6 | `LR2_LOAD_VLV` | Rack 2 load valve open |
| 7 | `FSII_INJ_CMD` | Additive injection enable |
| 8 | `ESD_RESET` | Clear latched ESD |
| 9 | `ALARM_ACK` | Acknowledge alarms |

**Discrete inputs — status (`%IX` → Modbus discrete input):**

| Addr | Tag | Description |
|---|---|---|
| 0 | `P201_RUN_STS` | Pump 1 running feedback |
| 1 | `P202_RUN_STS` | Pump 2 running feedback |
| 2 | `LR1_GROUND_OK` | Rack 1 grounding verified |
| 3 | `LR2_GROUND_OK` | Rack 2 grounding verified |
| 4 | `LR1_DEADMAN` | Rack 1 deadman held |
| 5 | `LR2_DEADMAN` | Rack 2 deadman held |
| 6 | `LR1_OVERFILL` | Rack 1 overfill tripped |
| 7 | `LR2_OVERFILL` | Rack 2 overfill tripped |
| 8 | `T101_HH_LVL` | T-101 high-high level switch |
| 9 | `T101_H_LVL` | T-101 high level switch |
| 10 | `T101_L_LVL` | T-101 low level switch |
| 11 | `T101_LL_LVL` | T-101 low-low level switch |
| 12 | `T102_HH_LVL` | T-102 high-high level switch |
| 13 | `T102_H_LVL` | T-102 high level switch |
| 14 | `T102_L_LVL` | T-102 low level switch |
| 15 | `T102_LL_LVL` | T-102 low-low level switch |
| 16 | `T103_HH_LVL` | T-103 high-high level switch |
| 17 | `T103_H_LVL` | T-103 high level switch |
| 18 | `T103_L_LVL` | T-103 low level switch |
| 19 | `T103_LL_LVL` | T-103 low-low level switch |
| 20 | `ESD_ACTIVE` | Emergency shutdown latched |

**Input registers — analog measurements (`%IW` → Modbus input register, 16-bit):**

| Addr | Tag | Units / scaling |
|---|---|---|
| 0 | `T101_LEVEL` | 0–10000 = 0.00–100.00 %; × capacity = gallons |
| 1 | `T102_LEVEL` | same |
| 2 | `T103_LEVEL` | same |
| 3 | `T101_TEMP` | 0.1 °F per count |
| 4 | `LR1_FLOW` | GPM, direct |
| 5 | `LR2_FLOW` | GPM, direct |
| 6 | `HEADER_PRESS` | 0.1 PSI per count |
| 7 | `LR1_METER_HI` | totalizer high word (gal) |
| 8 | `LR1_METER_LO` | totalizer low word (gal) |
| 9 | `LR2_METER_HI` | totalizer high word (gal) |
| 10 | `LR2_METER_LO` | totalizer low word (gal) |
| 11 | `T102_TEMP` | 0.1 °F per count |
| 12 | `T103_TEMP` | 0.1 °F per count |

**Holding registers — setpoints / assignments (`%QW` → Modbus holding register):**

| Addr | Tag | Meaning |
|---|---|---|
| 0 | `LR1_PRESET_GAL` | Rack 1 batch preset |
| 1 | `LR2_PRESET_GAL` | Rack 2 batch preset |
| 2 | `LR1_ACTIVE_TRUCK` | Truck ID at rack 1 (mirrors DB) |
| 3 | `LR2_ACTIVE_TRUCK` | Truck ID at rack 2 |
| 4 | `LR1_SRC_TANK` | Source tank (1/2/3) |
| 5 | `LR2_SRC_TANK` | Source tank (1/2/3) |
| 6 | `PUMP_LEADLAG_SEL` | Lead pump select |
| 7 | `SYS_MODE` | 0 = auto, 1 = manual |

> **Totalizers are 32-bit split across two 16-bit registers, high word first** — `*_METER_HI` at the lower address, `*_METER_LO` next (big-endian / `ABCD` word order, the Telegraf `inputs.modbus` default). This order is recorded in `group_vars/fuel.yml` so Telegraf and FUXA reassemble them identically.

> **Register encodings for DB-mirrored tags:** a 16-bit register can't hold the TEXT keys, so `LR*_ACTIVE_TRUCK` carries the truck **ordinal** (`R-03` → `3`) and `LR*_SRC_TANK` the tank **index** (`1/2/3` → `T-101/102/103`). The ordinal↔key maps live in `group_vars/fuel.yml` and are applied identically by the sim, HMI, and Grafana.

The full tag list, addresses, and scaling live in `group_vars/fuel.yml` as the single source of truth consumed by the PLC program template, the Telegraf config, and the FUXA device import.

---

## 5. HMI and operations visualization (split by purpose)

Two complementary surfaces — keep them distinct:

**A. FUXA — OT process HMI** (`control-room-hmi:1881`, Modbus to `ff-plc-1:502`). Native Modbus support; deploy via the `frangoteam/fuxa` Docker image to avoid Node build pain. Screens:
1. **Process overview** — P&ID style: 3 tank bargraphs + numeric level/temp, P-201/P-202 run state, outlet/load valves, header pressure, FSII, live rack flow.
2. **Loading rack detail** — per position: preset, live totalizer, grounding/deadman/overfill indicators, active truck, source tank, start/stop.

**B. Grafana "Fuel Operations" board** (`fuel-hist:3000`) — the logistics visualization the project requires (trucks queued, tank assignments, fuel withdrawn, aircraft/terminal assignment). Backed by **PostgreSQL** (authoritative logistics state) plus **InfluxDB** (process trends). Panels:
- Truck queue board (ordered, with state) — from `truck_queue`.
- Tank assignment matrix and current levels — from `tanks` + `tank_level_snap`.
- Fuel withdrawn (per truck / per tank / cumulative) — from `load_txn`.
- Aircraft ↔ pad ↔ delivered gallons — from `delivery_txn` + `fuel_orders`.
- Process trends (tank levels, flow, totalizers over time) — from InfluxDB.

This split keeps the PLC/HMI tier honest (only real process I/O on Modbus) while the audit DB remains the source of truth for logistics — which is exactly the boundary a blue team must learn to reason about.

---

## 6. Historian

**Stack:** Telegraf → InfluxDB 2.7 → Grafana, all on `fuel-hist`.

- **Telegraf** `inputs.modbus` polls `ff-plc-1:502` every 1–5 s, maps the §4 registers to a `fuel` measurement, writes to InfluxDB bucket `fuel`. Reassemble 32-bit totalizers per the documented word order.
- **InfluxDB 2.7 OSS** — UI/API on **8086**; org `airfield`, bucket `fuel`, operator token in vault. **Pin the image to `influxdb:2.7`.**
- **Grafana** on **3000** — provisioned InfluxDB (Flux) + PostgreSQL datasources and the dashboards from §5.

> **Critical version note:** as of 2026 the InfluxDB `latest` Docker tag points to **InfluxDB 3 Core**, a "recent-data" engine with a ~72-hour query window and incomplete InfluxQL support — wrong for a historian. Pin `influxdb:2.7` explicitly. (FUXA also has a built-in DAQ historian over SQLite/InfluxDB; fine as a lightweight secondary, not the primary.)

---

## 7. Audit database schema

**`fuel-db`:** PostgreSQL 16 + TimescaleDB. The `fuel_db` role creates the schema, makes the transaction/snapshot tables hypertables, and seeds reference data (tanks, trucks, aircraft, pads).

```sql
-- Reference data
CREATE TABLE tanks (
  tank_id      TEXT PRIMARY KEY,
  product      TEXT NOT NULL,
  capacity_gal NUMERIC NOT NULL
);
CREATE TABLE trucks (
  truck_id     TEXT PRIMARY KEY,
  callsign     TEXT,
  capacity_gal NUMERIC NOT NULL,
  status       TEXT NOT NULL DEFAULT 'AVAILABLE'  -- AVAILABLE|QUEUED|LOADING|ENROUTE|DISPENSING|RETURNING
);
CREATE TABLE aircraft (
  tail_no  TEXT PRIMARY KEY,
  ac_type  TEXT
);
CREATE TABLE pads (
  pad_id TEXT PRIMARY KEY,
  ramp   TEXT
);

-- Orders & queue
CREATE TABLE fuel_orders (
  order_id      BIGSERIAL PRIMARY KEY,
  tail_no       TEXT REFERENCES aircraft(tail_no),
  pad_id        TEXT REFERENCES pads(pad_id),
  requested_gal NUMERIC NOT NULL,
  status        TEXT NOT NULL DEFAULT 'OPEN',     -- OPEN|ASSIGNED|FILLED|CANCELLED
  created_ts    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE truck_queue (
  queue_id      BIGSERIAL PRIMARY KEY,
  truck_id      TEXT REFERENCES trucks(truck_id),
  position      INT,
  state         TEXT NOT NULL,                    -- QUEUED|LOADING|ENROUTE|DISPENSING|RETURNING
  source_tank   TEXT REFERENCES tanks(tank_id),
  rack_position INT,
  enqueued_ts   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_ts    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Transactions (hypertables)
CREATE TABLE load_txn (
  load_id     BIGSERIAL,
  truck_id    TEXT REFERENCES trucks(truck_id),
  tank_id     TEXT REFERENCES tanks(tank_id),
  rack_pos    INT,
  preset_gal  NUMERIC,
  meter_start NUMERIC,
  meter_end   NUMERIC,
  gallons     NUMERIC,
  operator    TEXT,
  start_ts    TIMESTAMPTZ NOT NULL,
  end_ts      TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (load_id, start_ts)
);
CREATE TABLE delivery_txn (
  delivery_id BIGSERIAL,
  truck_id    TEXT REFERENCES trucks(truck_id),
  tail_no     TEXT REFERENCES aircraft(tail_no),
  pad_id      TEXT REFERENCES pads(pad_id),
  order_id    BIGINT REFERENCES fuel_orders(order_id),
  gallons     NUMERIC,
  start_ts    TIMESTAMPTZ NOT NULL,
  end_ts      TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (delivery_id, start_ts)
);
CREATE TABLE tank_level_snap (
  ts        TIMESTAMPTZ NOT NULL,
  tank_id   TEXT REFERENCES tanks(tank_id),
  level_gal NUMERIC,
  temp_f    NUMERIC
);
CREATE TABLE events (
  event_id BIGSERIAL,
  ts       TIMESTAMPTZ NOT NULL DEFAULT now(),
  source   TEXT,        -- plc|sim|hmi|operator
  severity TEXT,        -- info|warn|alarm
  code     TEXT,
  message  TEXT,
  PRIMARY KEY (event_id, ts)
);

SELECT create_hypertable('load_txn','start_ts');
SELECT create_hypertable('delivery_txn','start_ts');
SELECT create_hypertable('tank_level_snap','ts');
SELECT create_hypertable('events','ts');
```

> **Timestamps under replay:** the `DEFAULT now()` columns apply to genuinely live inserts, but during replay `fuelsim` writes **every** timestamp column explicitly from its wall-clock anchor (see §8) — so a run's rows carry current time while staying otherwise seed-identical across runs.

**Reconciliation** (also an acceptance test and a blue-team detection): per truck, `Σ load_txn.gallons` should balance `Σ delivery_txn.gallons` within fleet/holding tolerance; tank drawdown should match `Σ load_txn.gallons` per source tank. Diversion scenarios break these on purpose.

---

## 8. Process simulator & 48-hour replay harness

**`fuel-farm-sim`** runs `fuelsim`, a Python systemd service with three parts:

1. **Field Modbus slave** (pymodbus server) — exposes the physical instruments (tank level/temp transmitters, flow meters/totalizers, pump-run feedback, limit/overfill/ground/deadman). Polled by OpenPLC as remote I/O.
2. **Physics model** — integrates flow when a pump runs + load valve open: meter totalizer increments, source-tank level drops, header pressure/temps respond; enforces tank low-level behavior.
3. **Logistics state machine + replay** — drives trucks through `QUEUED→LOADING→ENROUTE→DISPENSING→RETURNING`, writes audit rows to PostgreSQL, mirrors active assignments into PLC holding registers (`LR*_ACTIVE_TRUCK`, `LR*_SRC_TANK`).

Telegraf independently polls OpenPLC, so the historian captures everything as if live — no special hook needed.

**Replay dataset.** A generator (`generate_timeline.py`, fixed `--seed` for determinism) emits `fuel_ops_timeline.jsonl` covering 48 h. Parameters: sortie rate, fleet size, tank start levels, and an ops-tempo profile with surge windows. Event schema (one JSON object per line):

```json
{"t_offset_s": 5400, "event": "order_created", "order_id": 1042, "tail_no": "AF-2231", "pad_id": "PAD-A1", "requested_gal": 4200}
{"t_offset_s": 5460, "event": "truck_arrival", "truck_id": "R-03"}
{"t_offset_s": 5520, "event": "load_start", "truck_id": "R-03", "tank_id": "T-102", "rack_pos": 1, "preset_gal": 4200}
{"t_offset_s": 5880, "event": "load_end", "truck_id": "R-03", "gallons": 4200}
{"t_offset_s": 6300, "event": "delivery_start", "truck_id": "R-03", "tail_no": "AF-2231", "pad_id": "PAD-A1", "order_id": 1042}
{"t_offset_s": 6720, "event": "delivery_end", "truck_id": "R-03", "gallons": 4200}
```

`fuelsim` replay mode reads the timeline, scales `t_offset_s` by `replay.speed` (1.0 = real-time, higher = compressed), and fires each event to the state machine + physics so PLC/HMI/historian/DB all reflect it.

**Wall-clock anchoring.** At run start `fuelsim` captures `run_anchor` = current wall-clock time and stamps every event — and **every audit row it writes** — at `run_anchor + t_offset_s/replay.speed`, *not* at the literal moment of insert. So all non-timestamp fields (ids, gallons, tails, tanks, racks, operator, event sequence) are byte-for-byte identical to every other run from the same `--seed`, while the timestamps are always current. That is the goal: real replayed traffic that does not *look* replayed.

**Loopable:** on wrap, advance `run_anchor` to the new current wall-clock time (equivalently, offset by the 48 h window) so the stream stays live indefinitely. Determinism (fixed seed) for the payload + fresh anchoring for the clock is what makes scenarios both repeatable for assessment and realistic on the wire.

---

## 9. Ansible

**Inventory group** `fuel` → these hosts (the shared `control-room-hmi` also belongs to the power chain). `ansible_host` set to each mgmt IP. `group_vars/fuel.yml` holds the four OT segment CIDRs + gateways, the mgmt block, the full §4 tag map + scaling + totalizer word order, InfluxDB org/bucket, DB name, the tanks/trucks/aircraft/pads seed lists, `replay.speed`, and vault references for all credentials (OpenPLC web, FUXA admin, InfluxDB token, Grafana admin, Postgres roles). Per-host production IP/prefix/gateway live in `host_vars`.

**Roles:**
- `common` — netplan dual-home template (below), NTP client to the range time source, base users/hardening, Wazuh agent, nftables forwarding policy (`net.ipv4.ip_forward=0` on standard hosts; default-deny FORWARD with the `eth0↔eth2`-only bridge exception on `control-room-hmi`).
- `fuel_db` — PostgreSQL 16 + TimescaleDB, apply §7 schema, seed reference data.
- `fuel_sim` — deploy `fuelsim` package + systemd unit, place `fuel_ops_timeline.jsonl`, set env/`replay.speed`.
- `fuel_plc` — install OpenPLC v4 runtime (container), upload compiled program, configure Modbus server + remote-I/O slave pointing at `fuel-farm-sim`, **rotate default web creds**.
- `fuel_hmi` — deploy FUXA (`frangoteam/fuxa`), import the project JSON (screens + Modbus device config), set admin auth.
- `fuel_historian` — Telegraf `inputs.modbus` config; InfluxDB **`influxdb:2.7`** with org/bucket/token bootstrap; Grafana with provisioned datasources + dashboards.

**Dual-home netplan (in `common`, templated per host):**

```yaml
network:
  version: 2
  ethernets:
    eth0:                      # production OT segment (/29 for MTU & PLC, /24 for Sim)
      addresses: [ "{{ prod_ip }}/{{ prod_prefix }}" ]
      routes:
        - to: default
          via: "{{ prod_gw }}"     # .45.1 MTU · .45.9 Fuel-PLC · .46.16 Fuel-Sim · .48.1 Fuel-Data (all = bs-modbus-gateway)
    eth1:                      # management — directly connected; on-link to the mgmt supernet only, no default route
      addresses: [ "{{ mgmt_ip }}/20" ]
```

Plus a sysctl drop-in setting `net.ipv4.ip_forward=0` on standard hosts. `control-room-hmi` is the exception — a designated bridge (`eth0` = MTU `172.16.45.3`, `eth1` = mgmt, `eth2` = Power-PLC `172.16.47.9`) with `ip_forward=1`. Because `ip_forward` is global rather than per-interface, the `common` role pins the actual path with an nftables default-deny FORWARD policy so traffic can only cross `eth0↔eth2` and **never** reaches mgmt (`eth1`):

```nft
# /etc/nftables.d/bridge-forward.nft — applied only when `bridge: true` (control-room-hmi)
table inet bridge_fw {
  chain forward {
    type filter hook forward priority filter; policy drop;   # default-deny forwarding
    ct state established,related accept
    iifname "eth0" oifname "eth2" accept                      # MTU 172.16.45.3 -> Power-PLC 172.16.47.9
    iifname "eth2" oifname "eth0" accept                      # Power-PLC -> MTU
    # eth1 (mgmt) is named on neither side, so every OT<->mgmt forward is dropped
  }
}
```

`ansible_host = {{ mgmt_ip }}`. On Ubuntu cloud images the `common` role must neutralize cloud-init networking (`/etc/netplan/50-cloud-init.yaml`) so it doesn't override this dual-home config; netplan itself is native on Ubuntu, so no extra package is needed.

**Intra-enclave deploy order** (this enclave runs after the network + foundation tiers in the top-level `site.yml`):
`fuel_db` → `fuel_sim` → `fuel_plc` → `fuel_historian` → `fuel_hmi` → Grafana dashboard provisioning.
Rationale: DB schema before anything writes to it; the field slave (`fuel_sim`) up before the PLC starts polling it; the PLC's Modbus server up before Telegraf/FUXA connect.

---

## 10. Firewall & segment ACLs

Two enforcement points: `bs-ops-fw` (pfSense) for IT↔OT at the L3.5 boundary, and `bs-modbus-gateway` (VyOS) for intra-OT segment ACLs. Default-deny; allow only:

| Source | Destination | Port/proto | Enforced at | Purpose |
|---|---|---|---|---|
| Engineering WS (`172.31.8.0/24`) | `ff-plc-1` | 8080/tcp, 502/tcp | ops-fw + gw | Program upload, Modbus test |
| Engineering WS (`172.31.8.0/24`) | `control-room-hmi` | 1881/tcp | ops-fw + gw | FUXA admin |
| Engineering WS (`172.31.8.0/24`) | `fuel-hist` | 3000/tcp, 8086/tcp | ops-fw + gw | Grafana / InfluxDB |
| Engineering WS (`172.31.8.0/24`) | `fuel-db` | 5432/tcp | ops-fw + gw | DB admin |
| `fuel-hist` | RO historian replica (`172.31.8.5`) | 8086/tcp | ops-fw | Optional replication up |
| Fuel-PLC `172.16.45.8/29` | Fuel-Sim `172.16.46.0/24` | 502/tcp | gw | Field bus (PLC→sim remote I/O) |
| MTU `172.16.45.0/29`, Fuel-Data `172.16.48.0/24` | `ff-plc-1` :502 | 502/tcp | gw | SCADA reads (HMI/historian→PLC) |
| Fuel-Sim `172.16.46.0/24` | `fuel-db` :5432 | 5432/tcp | gw | Sim writes audit/logistics rows to DB |
| — | enterprise / flight ops | any | ops-fw | **Denied** (no flat path into OT) |
| — | other OT subsystems | any | gw | **Denied** except the defined power-chain bridge |

The mgmt plane (`eth1` / `10.255.240.0/20`) is reachable only from the Ansible control node, enforced on the platform management network, never exposed to a scenario.

---

## 11. Acceptance tests

- **PLC live:** `modpoll`/pymodbus read of `T101_LEVEL` tracks the sim; toggling a pump command changes flow and totalizer.
- **Interlock:** drop `LR1_GROUND_OK` → pump will not start; assert `LR1_LOAD_VLV` stays closed.
- **ESD:** trip `ESD_ACTIVE` → all pumps off, valves closed, latched until `ESD_RESET`.
- **Historian:** InfluxDB `fuel` bucket receiving points; Grafana process trend live; totalizers reassemble correctly (no 16-bit rollover artifacts).
- **Audit DB:** during replay, `load_txn` and `delivery_txn` accumulate; tank drawdown ≈ `Σ load_txn.gallons` per source tank.
- **HMI:** FUXA overview reflects live tank/pump/valve state within poll interval.
- **Replay:** 48 h timeline completes; loop wraps cleanly; two fixed-seed runs produce audit rows identical in every field **except** timestamps, which advance to each run's wall-clock anchor (§8) — confirm rows are fresh (max `ts` within a poll interval of now) yet payload-identical across runs.
- **Reconciliation:** per-truck loaded vs delivered balances within tolerance (the baseline a diversion scenario will later break).

---

## 12. Training value & attack surface

Why this subsystem is a strong range target, and where to point detection:

- **Unauthenticated Modbus (502) on both tiers.** Coil writes force pumps/valves; register writes spoof presets or fake tank levels. Authentic ICS attack; Zeek/Malcolm Modbus parsers in the SOC enclave should flag anomalous function codes and writes.
- **OpenPLC web (8080)** default `openplc/openplc` — rotated by the role, but a scenario can deliberately leave weak creds.
- **FUXA (1881) / Grafana (3000) web auth** — credential attacks, exposed operational dashboards.
- **PostgreSQL (5432)** — audit tampering: alter/delete `load_txn` to hide fuel theft. Strong blue-team exercise because **three independent records exist** (sim ground truth, historian time-series, audit DB) — tampering one creates a detectable divergence.
- **Historian poisoning** — false points written to InfluxDB to mask a process anomaly.
- **Consequence scenarios:** defeat overfill interlock; pump deadhead; **fuel diversion** (truck loads more than it delivers → §7 reconciliation breaks); tank-level spoofing to mask a low-fuel condition during a surge.

---

## 13. Build-time version checklist

Verify these against current releases before/while building with Claude Code — this ecosystem moves:

- **OS baseline:** Ubuntu 24.04 LTS Server — PostgreSQL 16 is native (no PGDG repo needed); point the InfluxData, Grafana, and TimescaleDB apt repos and Docker at the `noble` codename. The `common` role must neutralize cloud-init networking (override/remove `/etc/netplan/50-cloud-init.yaml`) so the dual-home config doesn't collide; netplan itself is native on Ubuntu.
- **OpenPLC:** v4 (Autonomy-Logic) is current and ships a containerized runtime plus OPC-UA/S7comm; v3 is more battle-tested specifically for Modbus remote-slave (master) I/O config. Confirm the remote-I/O workflow in whichever you pick; pin the version.
- **InfluxDB:** pin `influxdb:2.7`. Do **not** use `:latest` (now InfluxDB 3 Core — recent-data engine, ~72 h query window, partial InfluxQL). Only move to v3 if you validate that window against your retention/replay needs.
- **FUXA:** deploy the `frangoteam/fuxa` Docker image (port 1881) to dodge Node-version build friction; confirm the Modbus driver config import format for the release you pull.
- **TimescaleDB:** confirm the build's PostgreSQL 16 compatibility.
- **pfSense automation:** the L3.5 rules above assume the pfSense automation path settled earlier (community collection vs templated `config.xml`) — confirm coverage before relying on it for these rules.
