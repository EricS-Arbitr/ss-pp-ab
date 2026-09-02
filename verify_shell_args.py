#!/usr/bin/env python3
"""
verify_shell_args.py — catch unbalanced quotes in free-form shell arguments.

WHY THIS EXISTS
---------------
ss-pp-stacked 2026-09-02. A PowerShell comment inside a win_shell block read

    # reports on THIS host's own DNS service and says nothing about whether

and the deploy died at play-load time with

    ERROR! failed at splitting arguments, either an unbalanced jinja2 block
    or quotes

shell / command / raw / script / win_shell / win_command take FREE-FORM
arguments. Ansible therefore runs split_args() over the entire string to pull
out things like chdir= and creates=, and split_args counts quotes. It has no
idea PowerShell (or sh) has comments, so one possessive apostrophe is an
unterminated string and the whole play fails to load. Nothing on the host is
touched and the error names the task, not the character.

WHY YAML VALIDATION DID NOT CATCH IT
------------------------------------
It is valid YAML. yaml.safe_load() parsed the file happily, which is exactly
the trap: the file was checked with a parser weaker than the one that would
reject it. Ansible's argument splitter is a SECOND parser layered on top of
YAML, and this check exists to model that second one.

Exit 1 on any finding. This is not a style warning -- an affected play cannot
load at all.
"""
import pathlib
import shlex
import sys

import yaml

# Modules whose value, when given as a plain string, is parsed by split_args().
# A dict value (cmd:/chdir:/...) is NOT free-form and is deliberately skipped.
FREEFORM = {
    "shell", "command", "raw", "script",
    "ansible.builtin.shell", "ansible.builtin.command",
    "ansible.builtin.raw", "ansible.builtin.script",
    "win_shell", "win_command",
    "ansible.windows.win_shell", "ansible.windows.win_command",
}


def walk(node, path, findings):
    """Recurse through arbitrary YAML looking for free-form shell args.

    A key only counts as a MODULE if the dict holding it also has a `name`,
    i.e. it is a task. Without that rule this check produced nine false
    positives on its first run, every one of them the `script:` PARAMETER of
    ansible.windows.win_powershell -- which is a normal module argument and is
    never passed through split_args. Those playbooks load and deploy fine, so
    a check that flagged them was measuring the wrong thing.

    The task dict has a `name`; a module argument dict nested inside it does
    not. That distinction is what separates the two cases.
    """
    if isinstance(node, list):
        for item in node:
            walk(item, path, findings)
        return
    if not isinstance(node, dict):
        return

    name = node.get("name")
    is_task = name is not None
    for key, value in node.items():
        if is_task and key in FREEFORM and isinstance(value, str):
            try:
                shlex.split(value)
            except ValueError as exc:
                culprits = [
                    (i, line)
                    for i, line in enumerate(value.splitlines(), 1)
                    if line.count("'") % 2 or line.count('"') % 2
                ]
                findings.append((path, name, key, str(exc), culprits))
        walk(value, path, findings)


def main(root):
    findings = []
    checked = 0
    for path in sorted(pathlib.Path(root).rglob("*")):
        if path.suffix not in (".yml", ".yaml") or not path.is_file():
            continue
        try:
            doc = yaml.safe_load(path.read_text())
        except Exception:
            continue  # YAML validity is verified elsewhere
        checked += 1
        walk(doc, path, findings)

    if not findings:
        print(f"  {checked} YAML files checked, no unbalanced free-form shell args")
        return 0

    print(f"  {checked} YAML files checked, {len(findings)} BROKEN task(s):")
    for path, name, key, err, culprits in findings:
        print(f"\n  FAIL {path}")
        print(f"       task  : {name}")
        print(f"       module: {key}")
        print(f"       error : {err}")
        for lineno, line in culprits:
            print(f"       odd quote count at line {lineno} of the script:")
            print(f"         {line.strip()}")
    print(
        "\n  These plays cannot LOAD. Ansible runs split_args() over free-form\n"
        "  module arguments and counts quotes; it does not know the script has\n"
        "  comments. Reword to avoid the apostrophe -- do not try to escape it."
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
