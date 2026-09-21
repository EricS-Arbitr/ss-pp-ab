#!/usr/bin/env python3
"""
verify_task_keywords.py — catch task keywords misindented into module arguments.

WHY THIS EXISTS
---------------
ss-pp-stacked 2026-09-20. A `when:` was written one level too deep:

    - name: Fail fast if this host is not on the network at all
      ansible.builtin.fail:
        msg: |
          ...
        when: "'WINRM_NOROUTE' in (winrm_reach.stdout | default(''))"

`when` belongs to the TASK. Indented to match `msg`, it becomes an ARGUMENT to
the fail module instead. The condition is never evaluated, so the task runs
unconditionally -- a `fail` that fires on every host in the play, turning a
targeted guard into a range-wide outage.

The file is valid YAML. yaml.safe_load() accepts it, there are no duplicate
keys, and every quote is balanced, so neither verify_shell_args.py nor
verify_dup_keys.py can see it. It reads correctly at a glance too: both lines
are spelled right and sit in a plausible place. Only the column is wrong.

Ansible itself often will not save you. Some modules reject unknown arguments
and some silently accept them, and a module that rejects it fails at RUN time
on the host, deep into a deploy.

WHAT IT CANNOT CHECK
--------------------
A keyword swallowed into a block scalar:

    - name: Probe something
      ansible.windows.win_shell: |
        Get-Service ADWS
        register: probe

Here `register: probe` is a line of PowerShell, not a mapping key. It is
structurally indistinguishable from any other line of the script, so nothing
short of understanding the script can flag it. The symptom is a registered
variable that is always undefined.

WHAT IT CHECKS
--------------
For every task, whether any well-known task keyword appears inside the
argument mapping of a module. Keywords that are legitimately module arguments
for a few specific modules are exempted by name.
"""
import sys
import pathlib
import yaml

# Task-level keywords that are almost never module arguments.
TASK_KEYWORDS = {
    "when", "loop", "with_items", "with_dict", "with_subelements", "loop_control",
    "register", "become", "become_user", "become_method", "delegate_to",
    "delegate_facts", "run_once", "until", "retries", "delay", "notify",
    "changed_when", "failed_when", "ignore_errors", "ignore_unreachable",
    "tags", "vars", "no_log", "check_mode", "any_errors_fatal", "throttle",
    "environment", "args", "block", "rescue", "always", "serial",
}

# (module, keyword) pairs where the keyword IS a real module argument.
EXEMPT = {
    ("ansible.builtin.set_fact", "vars"),
    ("set_fact", "vars"),
    ("ansible.builtin.debug", "vars"),
    ("debug", "vars"),
    # wait_for / win_wait_for take a genuine `delay` argument.
    ("ansible.builtin.wait_for", "delay"),
    ("wait_for", "delay"),
    ("ansible.windows.win_wait_for", "delay"),
    ("win_wait_for", "delay"),
    ("ansible.builtin.wait_for_connection", "delay"),
    ("wait_for_connection", "delay"),
    ("ansible.windows.win_reboot", "post_reboot_delay"),
    # blockinfile's `block` is the CONTENT to insert, nothing to do with
    # block/rescue/always. Caught as a false positive on roles/splunk
    # 2026-09-20 -- a checker with known-bogus warnings trains you to skim
    # past the real ones, which is the whole reason this file exists.
    ("ansible.builtin.blockinfile", "block"),
    ("blockinfile", "block"),
    ("ansible.windows.win_blockinfile", "block"),
    ("win_blockinfile", "block"),
    ("community.windows.win_blockinfile", "block"),
    ("ansible.builtin.uri", "body"),
}

# Modules whose `tags` argument is real cloud-resource tagging rather than the
# Ansible task keyword. None are used in these ranges today; listed so the
# first one added does not arrive as a mystery failure.
TAGS_ARE_REAL = ("amazon.", "azure.", "google.", "community.docker.", "openstack.")

NOT_A_MODULE = TASK_KEYWORDS | {"name", "action", "local_action", "collections"}


def walk_tasks(node):
    """Yield every task mapping, descending into block/rescue/always."""
    if isinstance(node, list):
        for item in node:
            yield from walk_tasks(item)
    elif isinstance(node, dict):
        if any(k in node for k in ("block", "rescue", "always")):
            for k in ("block", "rescue", "always"):
                if k in node:
                    yield from walk_tasks(node[k])
        # A play: descend into its task lists.
        descended = False
        for k in ("tasks", "pre_tasks", "post_tasks", "handlers"):
            if k in node:
                descended = True
                yield from walk_tasks(node[k])
        if not descended and "block" not in node:
            yield node


def check(path):
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (yaml.YAMLError, OSError, UnicodeDecodeError):
        return []
    if not data:
        return []

    problems = []
    for task in walk_tasks(data):
        if not isinstance(task, dict):
            continue
        for key, val in task.items():
            if key in NOT_A_MODULE or not isinstance(val, dict):
                continue
            # `key` is the module; `val` is its argument mapping.
            for arg in val:
                if arg == "tags" and key.startswith(TAGS_ARE_REAL):
                    continue
                if arg in TASK_KEYWORDS and (key, arg) not in EXEMPT:
                    problems.append((
                        task.get("name", "(unnamed task)"), key, arg,
                    ))
    return problems


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted(
        p for p in root.rglob("*.y*ml")
        if p.is_file() and ".git" not in p.parts and p.suffix in (".yml", ".yaml")
    )

    findings = []
    for f in files:
        for name, module, arg in check(f):
            findings.append((f, name, module, arg))

    if not findings:
        print(f"  {len(files)} YAML files checked, no misindented task keywords")
        return 0

    print(f"  {len(files)} YAML files checked, {len(findings)} MISINDENTED keyword(s):")
    print()
    for f, name, module, arg in findings:
        try:
            rel = f.relative_to(root)
        except ValueError:
            rel = f
        print(f"  FAIL {rel}")
        print(f"       task   : {name}")
        print(f"       `{arg}` is indented as an argument to `{module}`")
    print()
    print("  These are TASK keywords. One level too deep they become module")
    print("  arguments: the keyword is never applied, so a `when` never gates,")
    print("  a `loop` never loops and a `register` never registers. Outdent by")
    print("  two spaces to sit level with the module name.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
