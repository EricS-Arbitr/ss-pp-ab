#!/usr/bin/env bash
#
# Build ab_pp.tgz for deployment.
#
# Auto-discovers roles referenced by arbitr_pp_playbook.yaml (and their meta
# dependencies), then bundles:
#   1. base roles from ../range-development-ansible/roles/
#   2. custom roles from ./roles/ (override base if same name)
#   3. files/ (pre-staged installers — refreshed from Nexus when reachable)
#   4. host_vars/, group_vars/, hosts, arbitr_pp_playbook.yaml, deploy.sh
#
# Before staging, Nexus is checked for any installer in NEXUS_FETCH below.
# If the remote is reachable and differs from the local copy, the local file
# is replaced. If Nexus is unreachable (e.g., running this script outside the
# customer network), the existing local file is used and a warning is printed.
#
# UPSTREAM_FIXES.md is intentionally excluded.
#
# Usage: ./build_tarball.sh
#
set -euo pipefail

SS_PP_AB="$(cd "$(dirname "$0")" && pwd)"
SRC_BASE="$(cd "$SS_PP_AB/../range-development-ansible" && pwd)"
PLAYBOOK="$SS_PP_AB/arbitr_pp_playbook.yaml"
ARCHIVE="$SS_PP_AB/ab_pp.tgz"
STAGE_PARENT="$(mktemp -d)"
STAGE="$STAGE_PARENT/abpp_build"

# Files we pull from Nexus before each build. Add more rows as needed.
# Format: "<remote-url>|<local-path-relative-to-ss-pp-ab>"
# (Empty for now — all hosts can download from Nexus directly. Re-populate
# if a host needs to bypass HTTPS for any reason.)
NEXUS_FETCH=()

trap 'rm -rf "$STAGE_PARENT"' EXIT

# --- Helpers ---------------------------------------------------------------

# Extract role names from a playbook's `roles:` blocks.
# Handles both "  - rolename" and "  - role: rolename" forms.
extract_playbook_roles() {
  awk '
    /^  roles:/ { inroles=1; next }
    inroles && /^  [a-z]/ { inroles=0 }
    inroles && /^    - / {
      sub(/^    - role:[[:space:]]+/, "")
      sub(/^    - /, "")
      sub(/[ \t#].*$/, "")
      if (length($0) > 0) print
    }
  ' "$1"
}

# Extract role-dependency names from a meta/main.yml.
extract_meta_deps() {
  [ -f "$1" ] || return 0
  awk '
    /^dependencies:/ { indeps=1; next }
    indeps && /^[a-z]/ { indeps=0 }
    indeps && /^[[:space:]]+-[[:space:]]+role:/ {
      sub(/^[[:space:]]+-[[:space:]]+role:[[:space:]]+/, "")
      sub(/[ \t#].*$/, "")
      print
    }
  ' "$1"
}

# Resolve a role to its source path (custom overrides base).
resolve_role_path() {
  local r="$1"
  if   [ -d "$SS_PP_AB/roles/$r" ]; then echo "$SS_PP_AB/roles/$r"
  elif [ -d "$SRC_BASE/roles/$r" ]; then echo "$SRC_BASE/roles/$r"
  else return 1
  fi
}

# Membership check on a bash array.
in_array() {
  local needle="$1"; shift
  for x in "$@"; do
    [ "$x" = "$needle" ] && return 0
  done
  return 1
}

# Refresh a single file from Nexus if reachable. Falls back to existing local
# copy on any network error. Errors only if neither remote nor local exists.
update_from_nexus() {
  local url="$1"
  local dest="$2"
  local label
  label="$(basename "$dest")"
  local tmp="${dest}.tmp"

  mkdir -p "$(dirname "$dest")"

  if curl -sSfL --insecure --connect-timeout 10 --max-time 120 \
          -o "$tmp" "$url" 2>/dev/null; then
    if [ -s "$tmp" ]; then
      if [ ! -f "$dest" ] || ! cmp -s "$dest" "$tmp"; then
        mv "$tmp" "$dest"
        echo "  refreshed from Nexus: $label"
      else
        rm -f "$tmp"
        echo "  up-to-date (matches Nexus): $label"
      fi
    else
      rm -f "$tmp"
      echo "  WARN: Nexus returned empty body for $label; keeping local copy"
    fi
  else
    rm -f "$tmp"
    if [ -f "$dest" ]; then
      echo "  Nexus unreachable; using existing local copy: $label"
    else
      echo "  ERROR: Nexus unreachable AND no local copy at $dest" >&2
      return 1
    fi
  fi
}

# --- Refresh installers from Nexus ----------------------------------------

if [ ${#NEXUS_FETCH[@]} -gt 0 ]; then
  echo "=== Refreshing installer files from Nexus ==="
  for entry in "${NEXUS_FETCH[@]}"; do
    url="${entry%%|*}"
    rel="${entry##*|}"
    update_from_nexus "$url" "$SS_PP_AB/$rel"
  done
  echo ""
fi

# --- Discovery -------------------------------------------------------------

[ -f "$PLAYBOOK" ] || { echo "ERROR: playbook not found at $PLAYBOOK" >&2; exit 1; }
[ -d "$SRC_BASE/roles" ] || { echo "ERROR: base roles dir not found at $SRC_BASE/roles" >&2; exit 1; }

seen=()
queue=()
while IFS= read -r r; do queue+=("$r"); done < <(extract_playbook_roles "$PLAYBOOK")

missing=()
while [ ${#queue[@]} -gt 0 ]; do
  r="${queue[0]}"
  queue=("${queue[@]:1}")
  in_array "$r" "${seen[@]:-}" && continue
  seen+=("$r")

  if rolepath="$(resolve_role_path "$r")"; then
    while IFS= read -r dep; do
      [ -n "$dep" ] && queue+=("$dep")
    done < <(extract_meta_deps "$rolepath/meta/main.yml")
  else
    missing+=("$r")
  fi
done

# --- Stage -----------------------------------------------------------------

mkdir -p "$STAGE/roles"

echo "=== Base roles (from $SRC_BASE/roles) ==="
base_count=0
for r in "${seen[@]}"; do
  if [ -d "$SRC_BASE/roles/$r" ]; then
    cp -R "$SRC_BASE/roles/$r" "$STAGE/roles/"
    echo "  base: $r"
    base_count=$((base_count+1))
  fi
done

echo ""
echo "=== Custom overlays (from $SS_PP_AB/roles) ==="
custom_count=0
for r in "${seen[@]}"; do
  if [ -d "$SS_PP_AB/roles/$r" ]; then
    rm -rf "$STAGE/roles/$r"
    cp -R "$SS_PP_AB/roles/$r" "$STAGE/roles/"
    echo "  custom: $r"
    custom_count=$((custom_count+1))
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo ""
  echo "WARN: roles referenced by playbook but not found in either source:"
  for r in "${missing[@]}"; do echo "  - $r"; done
fi

# Other deployment files
cp -R "$SS_PP_AB/host_vars"               "$STAGE/"
cp -R "$SS_PP_AB/group_vars"              "$STAGE/"
cp    "$SS_PP_AB/hosts"                   "$STAGE/"
cp    "$SS_PP_AB/arbitr_pp_playbook.yaml" "$STAGE/"
cp    "$SS_PP_AB/deploy.sh"               "$STAGE/"
chmod +x "$STAGE/deploy.sh"
# Read-only post-deploy verification script (optional but very useful).
if [ -f "$SS_PP_AB/verify_deployment.sh" ]; then
  cp "$SS_PP_AB/verify_deployment.sh" "$STAGE/"
  chmod +x "$STAGE/verify_deployment.sh"
fi
# Ansible Galaxy collection requirements (pfsensible.core etc.)
if [ -f "$SS_PP_AB/requirements.yml" ]; then
  cp "$SS_PP_AB/requirements.yml" "$STAGE/"
fi

# Pre-staged installers (referenced via win_copy with bare filename)
if [ -d "$SS_PP_AB/files" ]; then
  cp -R "$SS_PP_AB/files" "$STAGE/"
  # Strip macOS .DS_Store noise so it doesn't ride along to /etc/ansible
  find "$STAGE/files" -name '.DS_Store' -delete 2>/dev/null || true
fi

# --- Verify ----------------------------------------------------------------

# HARD GATE, not a warning. A free-form shell argument with unbalanced quotes
# makes the PLAY FAIL TO LOAD -- not one task, the whole run, before any host
# is touched. ss-pp-stacked 2026-09-02 shipped a tarball whose additional_dc
# role contained the PowerShell comment "THIS host's own DNS service"; the
# apostrophe is an unterminated string to Ansible's split_args(), which is run
# over free-form module arguments and does not know PowerShell has comments.
#
# The file was valid YAML and yaml.safe_load() accepted it, which is exactly
# why this check is separate: the tree had been validated with a parser weaker
# than the one that would reject it.
if [ -x "$SS_PP_AB/verify_shell_args.py" ] && command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Verifying free-form shell arguments ==="
  if ! python3 "$SS_PP_AB/verify_shell_args.py" "$STAGE"; then
    echo ""
    echo "ERROR: refusing to build a tarball whose plays cannot load."
    exit 1
  fi
fi

if [ -x "$SS_PP_AB/verify_vars.py" ] && command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "=== Verifying Jinja var references ==="
  python3 "$SS_PP_AB/verify_vars.py" "$STAGE" || true
fi

# --- Pack ------------------------------------------------------------------

cd "$STAGE"
TAR_PATHS=(roles host_vars group_vars hosts arbitr_pp_playbook.yaml deploy.sh)
[ -f "verify_deployment.sh" ] && TAR_PATHS+=(verify_deployment.sh)
[ -f "requirements.yml" ] && TAR_PATHS+=(requirements.yml)
[ -d "files" ] && TAR_PATHS+=(files)
# THIS SCRIPT HAS TWO ALLOWLISTS. The staging section above decides what is
# copied into $STAGE; TAR_PATHS decides what is actually packed. Adding to one
# and not the other produces an archive that builds clean, reports the right
# role count, and is missing the files. Assert they agree.
for entry in *; do
  packed=0
  for p in "${TAR_PATHS[@]}"; do [ "$p" = "$entry" ] && packed=1 && break; done
  if [ "$packed" -eq 0 ]; then
    echo "ERROR: '$entry' was staged but is not in TAR_PATHS -- it would be" >&2
    echo "       silently missing from the archive. Add it to TAR_PATHS." >&2
    exit 1
  fi
done

# macOS junk, stripped from the whole stage before packing.
find "$STAGE" \( -name '.DS_Store' -o -name '._*' \) -delete 2>/dev/null || true

# COPYFILE_DISABLE=1 is the load-bearing setting, NOT --no-xattrs.
#
# Apple's tar emits an AppleDouble "._name" companion for every file carrying
# an extended attribute, and com.apple.provenance is set on anything
# downloaded -- i.e. most of a checked-out repo. `--no-xattrs` does NOT
# suppress them despite reading as though it should. Measured on this repo
# 2026-08-17: 724 members of which 362 were junk, exactly one companion per
# real file. Extraction is ADDITIVE, so every one of them persisted in
# /etc/ansible on every deploy.
#
# Apple's `tar -tzf` HIDES AppleDouble members when listing, so macOS tar
# cannot verify this. Check with python3 tarfile.
COPYFILE_DISABLE=1 tar --no-xattrs \
  --exclude='.DS_Store' --exclude='._*' \
  -czf "$ARCHIVE" "${TAR_PATHS[@]}"

echo ""
echo "=== Archive built ==="
ls -lh "$ARCHIVE"
echo "Roles bundled: $(( base_count + 0 )) base + $custom_count custom = ${#seen[@]} total"
