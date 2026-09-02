#!/usr/bin/env python3
"""
verify_so_inventory.py — Security Onion hosts must inherit a way in.

WHY THIS EXISTS
---------------
ss-pp-stacked 2026-09-02. The five SO hosts were in [so_manager], [so_search],
[so_sensor] and [so_all], had correct host_vars, and had playbooks written
against them -- but were never added to [ubuntu22]. ansible_connection,
ansible_user and ansible_ssh_pass live in group_vars/linux.yml, keyed on
[linux] <- [ubuntu22], so every SO play reported ok=0 unreachable=1. That is
indistinguishable from a VM the range never built, and it cost three deploy
attempts and about four hours.

Membership in a group that gives a host WORK is not membership in a group that
gives it a WAY IN. The inventory makes the first obvious and the second
invisible.

WHY THIS CHECK IS NARROW
------------------------
The first attempt was general: "every host must resolve a connection from
somewhere". Two things killed it.

  1. It listed ansible_host among the keys that count as a connection, and so
     PASSED on the exact tree it was written to catch -- the SO hosts each had
     an ansible_host. An address says where to knock, not how to get in.
  2. Once that was fixed it flagged six hosts in all three repos that deploy
     perfectly well, because the vyos routers take their credentials from
     [vyos:vars] blocks inside the inventory, which the parser skipped.

A gate that fires on known-good trees trains people to ignore it, so the
general version is not shipped. This asserts one thing that is unambiguously
true of this topology and has no exceptions: every [so_all] member is a
[linux] member. It no-ops in a repo with no [so_all].

Exit 1 on any finding.
"""
import collections
import pathlib
import re
import sys


def parse_inventory(path):
    hosts, children = collections.defaultdict(list), collections.defaultdict(list)
    cur = kind = None
    for line in path.read_text().splitlines():
        s = line.split("#")[0].strip()
        if not s:
            continue
        m = re.match(r"^\[([^\]]+)\]$", s)
        if m:
            n = m.group(1)
            if n.endswith(":children"):
                cur, kind = n[:-9], "children"
            elif n.endswith(":vars"):
                cur, kind = n[:-5], "vars"
            else:
                cur, kind = n, "hosts"
            hosts.setdefault(cur, [])
            continue
        if kind == "hosts":
            hosts[cur].append(s.split()[0])
        elif kind == "children":
            children[cur].append(s)
    return hosts, children


def expand(group, hosts, children, seen=None):
    seen = seen or set()
    if group in seen:
        return set()
    seen.add(group)
    out = set(hosts.get(group, []))
    for c in children.get(group, []):
        out |= expand(c, hosts, children, seen)
    return out


def main(root):
    inv = pathlib.Path(root) / "hosts"
    if not inv.is_file():
        print("  no inventory at ./hosts, skipping")
        return 0
    hosts, children = parse_inventory(inv)
    if "so_all" not in set(hosts) | set(children):
        print("  no [so_all] in this inventory, nothing to check")
        return 0

    so = expand("so_all", hosts, children)
    linux = expand("linux", hosts, children)
    missing = sorted(so - linux)

    if not missing:
        print(f"  {len(so)} [so_all] host(s), all inherit [linux] credentials")
        return 0

    print(f"  {len(missing)} Security Onion host(s) with no credentials:")
    for h in missing:
        print(f"    FAIL {h}  -- in [so_all] but not in [linux]")
    print(
        "\n  These will report ok=0 unreachable=1 on every SO play, which\n"
        "  looks exactly like a VM that was never built. Add them to\n"
        "  [ubuntu22], which feeds [linux] and therefore group_vars/linux.yml."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
