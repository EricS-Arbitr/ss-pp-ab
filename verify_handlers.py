#!/usr/bin/env python3
"""Fail the build if any `notify:` names a handler that does not exist.

WHY THIS EXISTS. Ansible resolves notify targets at RUN TIME, on the host, at the
moment the task reports changed. A typo or a missing handler is therefore not a
syntax error and --syntax-check does not see it: it is a run-time abort, hours
into a deploy, on whichever host happens to change first.

MEASURED 2026-09-26, airfield-stacked:
    TASK [splunk : Copy Splunk Installer]
    changed: [soc-splunk-cm]
    ERROR! The requested handler 'Initialize Splunk' was not found in either the
    main handlers list nor in the listening handlers list
    Attempt 1 failed after 4h 31m 00s
airfield-range had removed Splunk when it went Security-Onion-only, so its
handlers role arrived in airfield-stacked stripped, while roles/splunk and
roles/splunk-es still notified it. `Restart Splunk Service` was missing too and
would have ended the next 4.5-hour attempt identically. This check finds both in
under a second.

RUNS ON THE STAGED BUNDLE, not the repo. Most roles a playbook calls are base
roles merged in at build time and are not in the repo at all, so a repo-root scan
both misses their handlers (false MISSING) and misses their notifies (false pass).

A handler is resolvable by its `name` or by any string in its `listen`. Handlers
may live in roles/<r>/handlers/, in a play's `handlers:` block, or be reachable
because the play includes a role whose handlers file defines them -- so this
collects every handler name in the bundle and treats the union as the namespace.
That is deliberately permissive: it cannot prove a handler is reachable from the
play that notifies it, only that the name exists somewhere. It catches the
failure that actually happens, which is a name that exists nowhere.
"""
import os
import sys
import glob

try:
    import yaml
except ImportError:
    sys.stderr.write("verify_handlers: PyYAML not available; skipping\n")
    sys.exit(0)


# Ansible's own tags -- !vault above all -- are not known to SafeLoader, so a
# group_vars file holding an inline-vaulted value raises ConstructorError. Left
# unhandled that file is silently skipped, and a skipped file is a blind spot:
# any notify inside it would be invisible and the check would pass by not
# looking. Resolve every unknown tag to None so the document still parses.
class _AnsibleLoader(yaml.SafeLoader):
    pass


_AnsibleLoader.add_multi_constructor("", lambda loader, suffix, node: None)


TASK_KEYS = ("block", "rescue", "always", "tasks", "pre_tasks", "post_tasks", "handlers")


def walk(node):
    """Yield every mapping that could be a task or a play."""
    if isinstance(node, dict):
        yield node
        for key, value in node.items():
            if key in TASK_KEYS:
                yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)


def as_list(value):
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [v for v in value if isinstance(v, str)]
    return []


def main():
    stage = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(stage):
        sys.stderr.write("verify_handlers: %s is not a directory\n" % stage)
        return 2

    files = []
    for pattern in ("**/*.yml", "**/*.yaml"):
        files.extend(glob.glob(os.path.join(stage, pattern), recursive=True))
    files = sorted(set(files))

    defined = set()
    notified = {}    # handler name -> set of "file:line-ish" origins
    unparsed = []

    for path in files:
        rel = os.path.relpath(path, stage)
        # Vaulted files and inventories are not task files.
        try:
            with open(path, "r") as fh:
                head = fh.read(32)
            if head.startswith("$ANSIBLE_VAULT"):
                continue
            with open(path, "r") as fh:
                doc = yaml.load(fh, Loader=_AnsibleLoader)
        except Exception as exc:
            unparsed.append("%s (%s)" % (rel, type(exc).__name__))
            continue
        if doc is None:
            continue

        in_handlers_file = "%shandlers%s" % (os.sep, os.sep) in path

        for node in walk(doc):
            if not isinstance(node, dict):
                continue
            # Anything with a `listen` is addressable by those names.
            defined.update(as_list(node.get("listen")))
            # A named task inside a handlers/ file is a handler.
            if in_handlers_file and isinstance(node.get("name"), str):
                defined.add(node["name"])
            # A play-level handlers: block defines handlers by name.
            block = node.get("handlers")
            if isinstance(block, list):
                for handler in block:
                    if isinstance(handler, dict) and isinstance(handler.get("name"), str):
                        defined.add(handler["name"])
            for target in as_list(node.get("notify")):
                # A templated notify cannot be checked statically.
                if "{{" in target:
                    continue
                notified.setdefault(target, set()).add(rel)

    missing = {k: v for k, v in notified.items() if k not in defined}

    print("  %d YAML file(s), %d handler name(s) defined, %d notify target(s)"
          % (len(files), len(defined), len(notified)))
    if unparsed:
        # Named, not counted. A silently skipped file is a blind spot: this check
        # would pass by not looking at it.
        print("  WARN: %d file(s) could not be parsed and were NOT checked:" % len(unparsed))
        for item in unparsed:
            print("        %s" % item)

    if not missing:
        print("  all notify targets resolve")
        return 0

    print("")
    print("  FAIL: %d notify target(s) name a handler that does not exist." % len(missing))
    print("  Ansible resolves these at run time, so this aborts the deploy mid-run:")
    print("")
    for name in sorted(missing):
        print("    '%s'" % name)
        for origin in sorted(missing[name]):
            print("        notified from %s" % origin)
    print("")
    print("  Either define the handler (usually roles/handlers/handlers/main.yml,")
    print("  or the role's own handlers/main.yml), or correct the notify name.")
    print("  A handler is addressable by its `name` or by any entry in `listen`.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
