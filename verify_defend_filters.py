#!/usr/bin/env python3
"""
verify_defend_filters.py — validate so_defend_exclusions before a deploy.

WHY THIS EXISTS
---------------
ss-pp-stacked 2026-09-19. A Defend filter description was 485 characters
against Kibana's 256-character limit. The `so_manager` role asserts the
length, so the bad value was caught -- 1h 31m into deploy.sh attempt 3, after
six hours of wall clock, on a range that was otherwise fully built.

The assert is in the right place to protect Kibana. It is in the wrong place
to protect the deploy: `so_defend_exclusions` is static group_vars data, so
every one of these checks can run offline in under a second. There is no
reason to spend six hours discovering that a string is too long.

This does not replace the runtime assert. The role still refuses to push a
bad filter; this just means you never get that far.

WHAT IT CHECKS
--------------
  * description length -- 250, matching the role assert (Kibana rejects >256;
    the margin is deliberate)
  * every required key present and non-empty
  * id is an uppercase GUID, the form Kibana stores
  * ids are unique
  * (os_type, dataset, field, value) tuples are unique

That last one is not hypothetical. The comment block above the filter in
group_vars records it: file_create, file_delete and rename all land in
endpoint.events.file, so writing one entry per event type produced two
byte-identical filters. The second reported "up to date" while doing nothing
at all -- a silent no-op that looked exactly like success.
"""
import re
import sys
import pathlib
import yaml

MAX_DESCRIPTION = 250          # role assert; Kibana rejects over 256
REQUIRED = ("id", "name", "description", "os_type", "dataset", "field", "value")
VALID_OS = {"linux", "windows", "macos"}
GUID_RE = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")


def load_filters(root):
    """Yield (path, filters) for every vars file defining so_defend_exclusions."""
    for sub in ("group_vars", "host_vars"):
        base = root / sub
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*.y*ml")):
            try:
                text = p.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            # Vault-encrypted files are not ours to read and never hold this.
            if text.lstrip().startswith("$ANSIBLE_VAULT"):
                continue
            try:
                data = yaml.safe_load(text)
            except yaml.YAMLError:
                # Malformed YAML belongs to the other checkers and to
                # --syntax-check, which both say it better than we would.
                continue
            if isinstance(data, dict) and data.get("so_defend_exclusions"):
                yield p, data["so_defend_exclusions"]


def check(path, filters):
    problems = []
    seen_ids, seen_rules = {}, {}

    for i, f in enumerate(filters):
        if not isinstance(f, dict):
            problems.append((path, f"entry {i} is not a mapping"))
            continue
        label = f.get("name") or f.get("id") or f"entry {i}"

        for key in REQUIRED:
            if not str(f.get(key, "")).strip():
                problems.append((path, f"{label}: missing or empty `{key}`"))

        desc = str(f.get("description", "")).strip()
        if len(desc) > MAX_DESCRIPTION:
            problems.append((
                path,
                f"{label}: description is {len(desc)} chars, limit {MAX_DESCRIPTION}"
                f" (Kibana rejects over 256). Move the rationale to a YAML"
                f" comment beside the entry -- `description` is rendered in the"
                f" Kibana UI.",
            ))

        fid = str(f.get("id", "")).strip()
        if fid and not GUID_RE.match(fid):
            problems.append((path, f"{label}: id `{fid}` is not an uppercase GUID"))
        # Case-insensitively: two GUIDs differing only in case are the same
        # id, and reporting only the casing problem would hide the collision
        # until someone fixed the casing.
        if fid.upper() in seen_ids:
            problems.append((path, f"{label}: duplicate id `{fid}`, also on {seen_ids[fid.upper()]}"))
        elif fid:
            seen_ids[fid.upper()] = label

        os_type = str(f.get("os_type", "")).strip()
        if os_type and os_type not in VALID_OS:
            problems.append((
                path,
                f"{label}: os_type `{os_type}` is not one of {sorted(VALID_OS)}",
            ))

        rule = (os_type, str(f.get("dataset", "")), str(f.get("field", "")), str(f.get("value", "")))
        if all(rule) and rule in seen_rules:
            problems.append((
                path,
                f"{label}: identical rule to `{seen_rules[rule]}` -- same os_type,"
                f" dataset, field and value. The second filter is a silent no-op;"
                f" it reports up to date while doing nothing.",
            ))
        elif all(rule):
            seen_rules[rule] = label

    return problems


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    problems, total, files = [], 0, 0

    for path, filters in load_filters(root):
        files += 1
        total += len(filters)
        problems += check(path, filters)

    if not problems:
        print(f"  {total} Defend filter(s) in {files} file(s) checked, no problems")
        return 0

    print(f"  {total} Defend filter(s) in {files} file(s) checked, {len(problems)} PROBLEM(S):")
    print()
    for path, msg in problems:
        try:
            rel = path.relative_to(root)
        except ValueError:
            rel = path
        print(f"  FAIL {rel}")
        print(f"       {msg}")
    print()
    print("  so_manager asserts these at deploy time. Fixing them here costs a")
    print("  second; finding them there costs a deploy.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
