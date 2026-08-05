#!/usr/bin/env python3
"""
Verify Jinja {{ var }} references in a staged Ansible bundle resolve to a
definition somewhere in group_vars/, host_vars/, role defaults/vars, or
register/loop_var/set_fact in a task file.

Usage: verify_vars.py <stage_dir>

Exits 0 if everything resolves, 1 if there are unresolved references.
Designed to be informational — false positives happen (vars from
include_vars, vars files outside group_vars, dynamic facts, etc.). Treat
output as "review these," not "build is broken."
"""
import re
import textwrap
import sys
from pathlib import Path
from collections import defaultdict

STAGE = Path(sys.argv[1] if len(sys.argv) > 1 else ".")

# Magic Ansible vars + Jinja keywords that are always "defined".
MAGIC = {
    # Ansible inventory / runtime
    "inventory_hostname", "hostvars", "groups", "group_names", "play_hosts",
    "ansible_play_hosts", "ansible_managed", "ansible_check_mode",
    "ansible_diff_mode", "playbook_dir", "inventory_dir",
    # Ansible connection vars (defined in group_vars/{windows,linux,vyos}.yml
    # but referenced inside roles via shorthand — keep magic to avoid noise)
    "ansible_host", "ansible_user", "ansible_password", "ansible_port",
    "ansible_connection", "ansible_become_user", "ansible_become_method",
    "ansible_become_pass", "ansible_python_interpreter",
    "ansible_winrm_transport", "ansible_ssh_pass", "ansible_network_os",
    # Facts (gathered automatically)
    "ansible_facts", "ansible_distribution", "ansible_distribution_version",
    "ansible_os_family", "ansible_kernel", "ansible_architecture",
    "ansible_local",
    # Loop / lookup
    "ansible_loop", "ansible_loop_var", "item", "lookup", "query", "omit",
    "role_name", "role_path",
    # Jinja keywords
    "true", "false", "none", "True", "False", "None",
    "and", "or", "not", "in", "is", "if", "else", "elif",
    "for", "endfor", "endif", "endblock", "block", "set", "endset",
    "with", "endwith", "as", "import", "from",
}

REF_RE = re.compile(r"\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)")
TOP_KEY_RE = re.compile(r"^([a-zA-Z_][a-zA-Z0-9_]*)\s*:", re.MULTILINE)
REGISTER_RE = re.compile(r"^\s*register:\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*$", re.MULTILINE)
LOOP_VAR_RE = re.compile(r"^\s*loop_var:\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*$", re.MULTILINE)
SET_FACT_BLOCK_RE = re.compile(
    # Optional FQCN prefix: so-ansible's roles write ansible.builtin.set_fact,
    # which the bare-name pattern missed entirely — every computed var it
    # produced (so_prod_nic, so_prod_netmask, so_global_pillar_merged) was
    # reported as undefined. Added 2026-07-30 during the Security Onion port.
    r"^\s*(?:ansible\.builtin\.)?set_fact:\s*\n((?:[ \t]+\S.*\n)+)",
    re.MULTILINE,
)
SF_KEY_RE = re.compile(r"^[ \t]+([a-zA-Z_][a-zA-Z0-9_]*)\s*:")
# {% for X in ... %} captures X (Jinja loop var, only in scope of the for block)
JINJA_FOR_RE = re.compile(r"\{%\s*for\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+in\s")
# {% set X = ... %} captures X
JINJA_SET_RE = re.compile(r"\{%\s*set\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=")
# Any reference starting with this prefix is treated as magic (runtime facts)
# "vault_": group_vars/all/vault.yml is ansible-vault encrypted, so this
# script cannot read its keys — the file is ciphertext on disk. Everything it
# provides is prefixed vault_ by convention, so treat the prefix as defined
# rather than warning on every credential. Added 2026-07-30 with the vault.
MAGIC_PREFIXES = ("ansible_", "vault_")


def relevant_files(root):
    """Yield .yml/.yaml/.j2 files under root."""
    for f in root.rglob("*"):
        if f.is_file() and f.suffix in {".yml", ".yaml", ".j2"}:
            yield f


def read_text(f):
    try:
        return f.read_text(errors="replace")
    except Exception:
        return ""


def collect_referenced(stage):
    refs = defaultdict(list)  # var -> [files referencing it]
    for f in relevant_files(stage):
        text = read_text(f)
        seen_in_file = set()
        for v in REF_RE.findall(text):
            if v not in seen_in_file:
                refs[v].append(str(f.relative_to(stage)))
                seen_in_file.add(v)
    return refs


def vars_block_keys(text):
    """Keys from every `vars:` block, at ANY indent (play, block or task).

    Line-based on purpose. The previous regex body -- `(?:[ \t]+\S.*\n|...)+`
    -- is greedy and swallows every indented line after a play-level `vars:`,
    including the entire `tasks:` section. Task-level `vars:` blocks nested in
    that region were therefore never matched, and their keys were reported as
    undefined (`missing` and `unlisted` in playbooks/75-endpoint.yml, which we
    had written off as expected false positives). A checker with known-bogus
    warnings trains you to skim past the real ones.
    """
    keys = set()
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^([ \t]*)vars:[ \t]*$", lines[i])
        if not m:
            i += 1
            continue
        block_indent = len(m.group(1))
        key_indent = None
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if not line.strip() or line.lstrip().startswith("#"):
                j += 1
                continue
            cur = len(line) - len(line.lstrip())
            if cur <= block_indent:
                break                      # dedented out of this vars: block
            if key_indent is None:
                key_indent = cur
            if cur == key_indent:
                km = re.match(r"[ \t]*([a-zA-Z_][a-zA-Z0-9_]*)\s*:", line)
                if km:
                    keys.add(km.group(1))
            j += 1
        i = j                              # continue scanning AFTER the block
    return keys


def collect_defined(stage):
    defined = set(MAGIC)

    # Top-level keys in dedicated var files only.
    # rglob, not glob: group_vars/all/ is a DIRECTORY since the vault landed
    var_files = list((stage / "group_vars").rglob("*.yml"))
    var_files += list((stage / "host_vars").glob("*.yml"))
    for role in (stage / "roles").glob("*"):
        for sub in ("defaults", "vars"):
            f = role / sub / "main.yml"
            if f.exists():
                var_files.append(f)
            f = role / sub / "main.yaml"
            if f.exists():
                var_files.append(f)
    for f in var_files:
        defined.update(TOP_KEY_RE.findall(read_text(f)))

    # `vars:` blocks at every level -- play, block and task.
    for f in relevant_files(stage):
        defined.update(vars_block_keys(read_text(f)))

    # registered task vars + loop_var: + set_fact keys + Jinja for/set vars (anywhere)
    for f in relevant_files(stage):
        text = read_text(f)
        defined.update(REGISTER_RE.findall(text))
        defined.update(LOOP_VAR_RE.findall(text))
        defined.update(JINJA_FOR_RE.findall(text))
        defined.update(JINJA_SET_RE.findall(text))
        for block in SET_FACT_BLOCK_RE.findall(text):
            for line in block.splitlines():
                m = SF_KEY_RE.match(line)
                if m:
                    defined.add(m.group(1))

    return defined



# ---------------------------------------------------------------------------
# ROLE SCOPE
# ---------------------------------------------------------------------------
# Role defaults are ROLE-SCOPED: a play that references one without including
# that role fails at run time. This checker used to treat every role default as
# globally defined, so those references resolved cleanly here and blew up on
# the range -- three times (so_bundled_rules_filename 2026-07-29,
# so_mirror_root + so_agent_installer_* 2026-08-04). Each cost a full
# build/upload/deploy round trip to discover.
#
# Granularity is per FILE, not per play: if a playbook uses the role ANYWHERE
# in the file, a reference in it is accepted. That can miss a genuine error
# (role used in play 1, var referenced in play 2) but it cannot invent one,
# which is the right trade for a check that fails the build.

ROLES_BLOCK_RE = re.compile(r"^([ \t]*)roles:[ \t]*\n((?:[ \t]+.*\n|[ \t]*\n)+)", re.M)
ROLE_ITEM_RE = re.compile(r"^[ \t]*-[ \t]*(?:(?:role|name):[ \t]*)?([A-Za-z_][\w.-]*)[ \t]*$")
INCLUDE_ROLE_RE = re.compile(
    r"(?:import_role|include_role):[ \t]*\n(?:[ \t]+\w+:.*\n)*?[ \t]+name:[ \t]*([A-Za-z_][\w.-]*)", re.M)


def playbook_files(stage):
    """Files that are plays, not role internals."""
    out = []
    for f in list(stage.glob("*.yml")) + list(stage.glob("*.yaml")):
        out.append(f)
    pb = stage / "playbooks"
    if pb.is_dir():
        out += sorted(pb.rglob("*.yml")) + sorted(pb.rglob("*.yaml"))
    return out


def roles_used_in(text):
    used = set()
    for indent, blk in ROLES_BLOCK_RE.findall(text):
        for line in blk.splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if len(line) - len(line.lstrip()) <= len(indent):
                break
            m = ROLE_ITEM_RE.match(line)
            if m:
                used.add(m.group(1))
    used.update(INCLUDE_ROLE_RE.findall(text))
    return used


def role_scoped_definitions(stage):
    """var -> set(roles that define it in defaults/ or vars/)."""
    owned = defaultdict(set)
    roles_dir = stage / "roles"
    if not roles_dir.is_dir():
        return owned
    for role in sorted(roles_dir.glob("*")):
        if not role.is_dir():
            continue
        for sub in ("defaults", "vars"):
            for name in ("main.yml", "main.yaml"):
                f = role / sub / name
                if f.exists():
                    for k in TOP_KEY_RE.findall(read_text(f)):
                        owned[k].add(role.name)
    return owned


def globally_defined(stage):
    """Definitions visible to any play: group_vars, host_vars, magic."""
    out = set(MAGIC)
    for f in list((stage / "group_vars").rglob("*.yml")) + list((stage / "host_vars").glob("*.yml")):
        out.update(TOP_KEY_RE.findall(read_text(f)))
    return out


def scope_errors(stage):
    """[(file, var, defining_roles)] for role-scoped vars used without the role."""
    owned = role_scoped_definitions(stage)
    global_defs = globally_defined(stage)
    problems = []
    for f in playbook_files(stage):
        text = read_text(f)
        used = roles_used_in(text)
        # locally satisfied: play vars, registers, set_fact, loop_var, jinja
        local = set(REGISTER_RE.findall(text)) | set(LOOP_VAR_RE.findall(text))
        local |= set(JINJA_FOR_RE.findall(text)) | set(JINJA_SET_RE.findall(text))
        for block in SET_FACT_BLOCK_RE.findall(text):
            for line in block.splitlines():
                m = SF_KEY_RE.match(line)
                if m:
                    local.add(m.group(1))
        local |= vars_block_keys(text)
        for var in sorted(set(REF_RE.findall(text))):
            if var in global_defs or var in local:
                continue
            if any(var.startswith(pfx) for pfx in MAGIC_PREFIXES):
                continue
            if var in owned and not (owned[var] & used):
                problems.append((f, var, sorted(owned[var])))
    return problems



def main():
    if not STAGE.is_dir():
        print(f"verify_vars: stage dir not found: {STAGE}", file=sys.stderr)
        return 2

    refs = collect_referenced(STAGE)
    defined = collect_defined(STAGE)

    # --- Role scope: a hard error, not a warning ---------------------------
    scope = scope_errors(STAGE)
    if scope:
        print("")
        print("  SCOPE ERROR: role-scoped variable(s) referenced by a play that")
        print("  does not include the defining role. These resolve fine here and")
        print("  FAIL AT RUN TIME on the range.")
        for f, var, roles in scope:
            try:
                rel = f.relative_to(STAGE)
            except ValueError:
                rel = f
            print(f"    - {var}    in {rel}")
            print(f"        defined only in role default(s): {', '.join(roles)}")
        print("")
        print("  Fix: move the variable to group_vars/all/, leaving a pointer")
        print("  comment in the role's defaults so there is one source of truth.")
    # Strip any reference that matches a magic prefix (runtime facts)
    unresolved = sorted(
        v for v in set(refs) - defined
        if not any(v.startswith(p) for p in MAGIC_PREFIXES)
    )

    if not unresolved:
        print(f"  All {len(refs)} Jinja var references resolve to a definition.")
        # Exit 3 signals a SCOPE error specifically. build_tarball.sh aborts on
        # 3 and tolerates 1 (soft warnings), because a scope error is a
        # guaranteed run-time failure while the warnings are usually
        # `| default(...)` references that are fine.
        return 3 if scope else 0

    print(f"  WARN: {len(unresolved)} Jinja var(s) referenced but not "
          f"defined in any group_vars/host_vars/role-defaults file.")
    print(f"  Likely missing — review each before deploying:")
    for v in unresolved:
        first_ref = refs[v][0]
        more = f" (+{len(refs[v]) - 1} more)" if len(refs[v]) > 1 else ""
        print(f"    - {v}    first seen in: {first_ref}{more}")
    return 3 if scope else 1


if __name__ == "__main__":
    sys.exit(main())
