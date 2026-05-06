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
    r"^\s*set_fact:\s*\n((?:[ \t]+\S.*\n)+)",
    re.MULTILINE,
)
SF_KEY_RE = re.compile(r"^[ \t]+([a-zA-Z_][a-zA-Z0-9_]*)\s*:")
# {% for X in ... %} captures X (Jinja loop var, only in scope of the for block)
JINJA_FOR_RE = re.compile(r"\{%\s*for\s+([a-zA-Z_][a-zA-Z0-9_]*)\s+in\s")
# {% set X = ... %} captures X
JINJA_SET_RE = re.compile(r"\{%\s*set\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=")
# Any reference starting with this prefix is treated as magic (runtime facts)
MAGIC_PREFIXES = ("ansible_",)


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


def collect_defined(stage):
    defined = set(MAGIC)

    # Top-level keys in dedicated var files only.
    var_files = list((stage / "group_vars").glob("*.yml"))
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


def main():
    if not STAGE.is_dir():
        print(f"verify_vars: stage dir not found: {STAGE}", file=sys.stderr)
        return 2

    refs = collect_referenced(STAGE)
    defined = collect_defined(STAGE)
    # Strip any reference that matches a magic prefix (runtime facts)
    unresolved = sorted(
        v for v in set(refs) - defined
        if not any(v.startswith(p) for p in MAGIC_PREFIXES)
    )

    if not unresolved:
        print(f"  All {len(refs)} Jinja var references resolve to a definition.")
        return 0

    print(f"  WARN: {len(unresolved)} Jinja var(s) referenced but not "
          f"defined in any group_vars/host_vars/role-defaults file.")
    print(f"  Likely missing — review each before deploying:")
    for v in unresolved:
        first_ref = refs[v][0]
        more = f" (+{len(refs[v]) - 1} more)" if len(refs[v]) > 1 else ""
        print(f"    - {v}    first seen in: {first_ref}{more}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
