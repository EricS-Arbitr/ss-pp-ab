#!/usr/bin/env bash
#
# Build ab_pp.tgz for deployment.
#
# Auto-discovers roles referenced by arbitr_pp_playbook.yaml (and their meta
# dependencies), then bundles:
#   1. base roles from ../range-development-ansible/roles/
#   2. custom roles from ./roles/ (override base if same name)
#   3. host_vars/, group_vars/, hosts, arbitr_pp_playbook.yaml, deploy.sh
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

# --- Pack ------------------------------------------------------------------

cd "$STAGE"
tar --no-xattrs -czf "$ARCHIVE" \
    roles host_vars group_vars hosts arbitr_pp_playbook.yaml deploy.sh

echo ""
echo "=== Archive built ==="
ls -lh "$ARCHIVE"
echo "Roles bundled: $(( base_count + 0 )) base + $custom_count custom = ${#seen[@]} total"
