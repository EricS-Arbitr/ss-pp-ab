#!/usr/bin/env python3
"""
verify_dup_keys.py — catch duplicate mapping keys in task YAML.

WHY THIS EXISTS
---------------
airfield-range 2026-09-18. roles/dcpromo/tasks/main.yml carried a task with
TWO `when:` keys:

    - name: Fail if AD services did not come up on the new child DC
      ansible.builtin.fail: ...
      when: (child_dc_services.output[0] | default('9') | int) != 0
      when:
        - parent_domain_name is defined
        - dcpromo_child is defined
        - dcpromo_child is changed

YAML keeps the LAST key and drops the first without complaint. The service
condition -- the entire reason the task exists -- was never evaluated, and the
`child_dc_services` probe above it fed nothing but a message string. A gate
that had been in the repo for months had never once run.

Ansible does warn:

    [WARNING] While constructing a mapping from .../main.yml, line 290,
    column 3, found a duplicate dict key (when). Using last defined value only.

...at RUN time, on stderr, in the middle of a 26,000-line deploy log. It is
one line among hundreds and nobody reads it. Worse, `yaml.safe_load()` accepts
duplicates silently, so neither verify_shell_args.py nor verify_vars.py -- both
of which parse every one of these files -- could see it either.

This check exists because a silent-by-default failure needs a loud gate. It is
a HARD GATE: a duplicate key means a line of logic you wrote is not running,
and you cannot tell which from the file alone.

WHAT IT DOES NOT DO
-------------------
It flags duplicates at any depth in any mapping, not just task-level keywords.
That is deliberate -- a doubled key in group_vars or in a module argument block
is the same class of silent loss.
"""
import sys
import pathlib
import yaml


class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that records duplicate mapping keys instead of swallowing them."""


def _construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            loader.duplicates.append(
                (key, key_node.start_mark.line + 1, key_node.start_mark.column + 1)
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


DupKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def scan(path):
    """Return [(key, line, col)] for every duplicate mapping key in `path`."""
    loader = DupKeyLoader(path.read_text(encoding="utf-8"))
    loader.duplicates = []
    try:
        while loader.check_data():
            loader.get_data()
    except yaml.YAMLError:
        # Malformed YAML is not this checker's job -- verify_shell_args.py and
        # the ansible-playbook --syntax-check both surface it with a better
        # message. Report what was collected before the parse gave up.
        pass
    finally:
        loader.dispose()
    return loader.duplicates


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    files = sorted(
        p
        for p in root.rglob("*.y*ml")
        if p.is_file() and ".git" not in p.parts and p.suffix in (".yml", ".yaml")
    )

    findings = []
    for f in files:
        for key, line, col in scan(f):
            findings.append((f, key, line, col))

    if not findings:
        print(f"  {len(files)} YAML files checked, no duplicate mapping keys")
        return 0

    print(f"  {len(files)} YAML files checked, {len(findings)} DUPLICATE key(s):")
    print()
    for f, key, line, col in findings:
        rel = f.relative_to(root) if root in f.parents or f.parent == root else f
        print(f"  FAIL {rel}")
        print(f"       duplicate key `{key}` at line {line}, column {col}")
    print()
    print("  YAML keeps the LAST value and discards the earlier one silently.")
    print("  Whatever the first key said is NOT running. Merge them into one")
    print("  key -- for `when`, combine the conditions into a single list.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
