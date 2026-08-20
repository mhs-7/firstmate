#!/usr/bin/env bash
# fm-roles-lint.sh - validate firstmate's role-charter tree.
#
# Usage:
#   fm-roles-lint.sh                run every charter lint check
#   fm-roles-lint.sh --soft <n>     assembled soft-cap word ceiling (warning below hard cap)
#   fm-roles-lint.sh --help         print this usage
#
# The seven checks from the role-charter spec (c.2):
#   1. The byte-verbatim Karpathy block is present and hash-pinned in the base
#      and in every dist charter; a mutated block fails.
#   2. Every overlay carries its required section headings.
#   3. Word/instruction budgets: base editable prose, each overlay, the annex,
#      and every assembled dist are under their hard ceilings; the assembled
#      soft cap prints a warning instead of failing.
#   4. No overlay duplicates project-AGENTS.md-class content (heuristic that
#      flags project paths, vendor names, and concrete commands in effective
#      charter prose, excluding provenance comments).
#   5. Role names and role-mandate deliverable contracts are pairwise distinct.
#   6. Every dist charter carries a Charter-date line.
#   7. Dist files are in sync with sources: regeneration is clean.
#
# Budget semantics: the byte-verbatim Karpathy block is a fixed, non-prunable
# fixture controlled by the hash check, so the base budget counts only the
# editable base prose and the hard assembled ceiling counts the full dist the
# worker reads (Karpathy included).
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
ROLES_DIR="$ROOT/roles"
DIST_DIR="$ROLES_DIR/dist"
BASE_FILE="$ROLES_DIR/common-base.md"
ANNEX_FILE="$ROLES_DIR/annex-deploy-verifier.md"

# The pinned sha256 of the byte-verbatim Karpathy block, captured from
# roles/karpathy-rules-verbatim.md (lines 8-72, each line newline-terminated).
KARPATHY_PIN=694a2d721e41c385f3db492838c23299826df5ba9809e3b0721aac70021e196a

# Hard word ceilings (spec D1). The assemble/overlay ceiling is 550 and the
# assembled ceiling is 1400; the base editable prose ceiling controls the
# prunable directives around the fixed Karpathy fixture.
BASE_CEILING=500
OVERLAY_CEILING=550
ANNEX_CEILING=130
ASSEMBLED_CEILING=1400
ASSEMBLED_SOFT=1300

# The seven roles with their dist file stem, H1 role title, and required ## headings.
ROLE_SPECS=$(cat <<'EOF'
scout|scout / researcher|Role|Standing skill workflow|Definition of done|Procedure|Boundaries
architect|architect|Role|Standing skill workflow|Definition of done|Procedure|Boundaries
implementer|implementer|Role|Standing skill workflow|Definition of done|Procedure|Boundaries|Output contract
primary-reviewer|primary reviewer|Role|Standing skill workflow|Definition of done|Procedure|Boundaries
second-vendor-reviewer|second-vendor reviewer|Role|Standing skill workflow|Definition of done|Independence contract|Procedure|Boundaries
adjudicator|adjudicator|Role|Input contract|Procedure|Disposition vocabulary|Boundaries
merge-train-sweeper|merge-train integration sweeper|Role|Object of review|Procedure|Boundaries
EOF
)

FAILURES=0
WARNINGS=0

fail_check() {
  printf 'fm-roles-lint: FAIL: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

warn_check() {
  printf 'fm-roles-lint: WARN: %s\n' "$1" >&2
  WARNINGS=$((WARNINGS + 1))
}

usage() {
  sed -n '2,16{s/^# \{0,1\}//;p;}' "$SELF_DIR/fm-roles-lint.sh"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "${1:-}" = "--soft" ]; then
  ASSEMBLED_SOFT="${2:?--soft needs a ceiling}"
  shift 2
fi

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    sha256sum
  fi
}

# Keep trailing newlines pinned for byte-identical hashing.
karpathy_block_from_dist() {
  awk '
    /^# CLAUDE\.md$/ { inblock = 1 }
    inblock { print }
    inblock && /rather than after mistakes\.$/ { exit }
  ' "$1"
}

karpathy_block_from_base() {
  awk '
    /^<!-- KARPATHY-BLOCK-START -->$/ { inblock = 1; next }
    /^<!-- KARPATHY-BLOCK-END -->$/ { inblock = 0; next }
    inblock { print }
  ' "$1"
}

# Effective prose for budget and heuristic checks: provenance + delimiters removed.
strip_sources() {
  awk '
    /^<!--/ && /provenance/ { inprov = 1; next }
    inprov && /^-->/ { inprov = 0; next }
    inprov { next }
    /^<!-- KARPATHY-BLOCK-START -->$/ { next }
    /^<!-- KARPATHY-BLOCK-END -->$/ { next }
    { print }
  ' "$1"
}

# Editable base prose: strip provenance, delimiters, and the Karpathy fixture.
strip_base_editable() {
  awk '
    /^<!--/ && /provenance/ { inprov = 1; next }
    inprov && /^-->/ { inprov = 0; next }
    inprov { next }
    /^<!-- KARPATHY-BLOCK-START -->$/ { next }
    /^<!-- KARPATHY-BLOCK-END -->$/ { next }
    /^# CLAUDE\.md$/ { inblock = 1 }
    inblock && /rather than after mistakes\.$/ { inblock = 0; next }
    inblock { next }
    { print }
  ' "$1"
}

word_count() {
  if [ $# -ge 1 ]; then
    tr -s '[:space:]' ' ' < "$1" | wc -w | tr -d ' '
  else
    tr -s '[:space:]' ' ' | wc -w | tr -d ' '
  fi
}

check_file_exists() {
  [ -e "$1" ] || fail_check "missing expected file: $1"
}

# --- check 1: Karpathy hash identity ---------------------------------------
check_karpathy() {
  check_file_exists "$BASE_FILE"
  [ -e "$BASE_FILE" ] || return
  local base_hash
  base_hash=$(karpathy_block_from_base "$BASE_FILE" | sha256_stdin | awk '{print $1}')
  if [ "$base_hash" != "$KARPATHY_PIN" ]; then
    fail_check "base Karpathy block hash $base_hash != pinned $KARPATHY_PIN"
  fi
  if [ ! -d "$DIST_DIR" ]; then
    fail_check "missing dist directory: $DIST_DIR"
    return
  fi
  local dist dist_hash
  for dist in "$DIST_DIR"/*.charter.md; do
    [ -e "$dist" ] || continue
    dist_hash=$(karpathy_block_from_dist "$dist" | sha256_stdin | awk '{print $1}')
    if [ "$dist_hash" != "$KARPATHY_PIN" ]; then
      fail_check "Karpathy block in $(basename "$dist") hash $dist_hash != pinned $KARPATHY_PIN"
    fi
  done
}

# --- check 2: required headings --------------------------------------------
check_headings() {
  local stem title h1 h2 h3 h4 h5 h6 file want
  while IFS='|' read -r stem title h1 h2 h3 h4 h5 h6; do
    file="$ROLES_DIR/$stem.md"
    if [ ! -e "$file" ]; then
      fail_check "missing overlay: $file"
      continue
    fi
    for want in "$h1" "$h2" "$h3" "$h4" "$h5" "$h6"; do
      [ -n "$want" ] || continue
      grep -q "^## $want" "$file" || fail_check "$stem overlay missing ## $want"
    done
  done <<EOF
$ROLE_SPECS
EOF
}

# --- check 3: word budgets --------------------------------------------------
check_budgets() {
  local base_editable overlay_editable annex_editable assembled stem
  base_editable=$(strip_base_editable "$BASE_FILE" | word_count)
  if [ "$base_editable" -gt "$BASE_CEILING" ]; then
    fail_check "base editable prose $base_editable words > $BASE_CEILING"
  fi
  annex_editable=$(strip_sources "$ANNEX_FILE" | word_count)
  if [ "$annex_editable" -gt "$ANNEX_CEILING" ]; then
    fail_check "deploy annex $annex_editable words > $ANNEX_CEILING"
  fi
  while IFS='|' read -r stem title rest; do
    overlay_editable=$(strip_sources "$ROLES_DIR/$stem.md" | word_count)
    if [ "$overlay_editable" -gt "$OVERLAY_CEILING" ]; then
      fail_check "$stem overlay $overlay_editable words > $OVERLAY_CEILING"
    fi
    assembled=$(word_count "$DIST_DIR/$stem.charter.md")
    if [ "$assembled" -gt "$ASSEMBLED_CEILING" ]; then
      fail_check "$stem assembled $assembled words > $ASSEMBLED_CEILING"
    elif [ "$assembled" -gt "$ASSEMBLED_SOFT" ]; then
      warn_check "$stem assembled $assembled words exceeds soft cap $ASSEMBLED_SOFT"
    fi
  done <<EOF
$ROLE_SPECS
EOF
}

# --- check 4: no project-specific content -----------------------------------
scan_project_content() {
  local file=$1 hits bad
  [ -e "$file" ] || return 0
  hits=$(strip_sources "$file" | awk '
    tolower($0) ~ /(^|[^a-z])cfb([^a-z]|$)/ ||
    tolower($0) ~ /(^|[^a-z])kalshi([^a-z]|$)/ ||
    tolower($0) ~ /(^|[^a-z])polymarket([^a-z]|$)/ ||
    tolower($0) ~ /(^|[^a-z])uv([^a-z]|$)/ ||
    tolower($0) ~ /(^|[^a-z])pytest([^a-z]|$)/
  ')
  if [ -n "$hits" ]; then
    bad=$(printf '%s\n' "$hits" | head -1 | tr -s '[:space:]' ' ')
    fail_check "project-specific content in $(basename "$file"): $bad"
  fi
}

check_no_project_content() {
  local stem title rest
  scan_project_content "$BASE_FILE"
  scan_project_content "$ANNEX_FILE"
  while IFS='|' read -r stem title rest; do
    scan_project_content "$ROLES_DIR/$stem.md"
  done <<EOF
$ROLE_SPECS
EOF
}

# --- check 5: pairwise-distinct roles/deliverables --------------------------
check_distinct() {
  local file stem title rest role deliverable seen
  seen=""
  while IFS='|' read -r stem title rest; do
    file="$ROLES_DIR/$stem.md"
    if [ ! -e "$file" ]; then
      continue
    fi
    role=$(sed -n 's/^# Role overlay: //p' "$file" | head -1)
    if [ "$role" != "$title" ]; then
      fail_check "$stem overlay H1 '$role' != expected '$title'"
    fi
    deliverable=$(sed -n 's/^Your deliverable is //p' "$file" | head -1 | tr -s '[:space:]' ' ')
    if [ -z "$deliverable" ]; then
      fail_check "$stem overlay has no 'Your deliverable is' contract sentence"
      continue
    fi
    if printf '%s\n' "$seen" | grep -Fqx "$deliverable"; then
      fail_check "$stem overlay duplicates another overlay's deliverable contract: '$deliverable'"
    fi
    seen="$seen
$deliverable"
  done <<EOF
$ROLE_SPECS
EOF
}

# --- check 6: Charter-date present ------------------------------------------
check_charter_date() {
  local dist
  for dist in "$DIST_DIR"/*.charter.md; do
    [ -e "$dist" ] || continue
    grep -q '^Charter-date:' "$dist" || fail_check "$(basename "$dist") missing Charter-date line"
  done
}

# --- check 7: dist in sync --------------------------------------------------
check_dist_sync() {
  local tmp gen dist stem
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-roles-lint.XXXXXX")
  trap 'rm -rf "$tmp"' RETURN
  # Regenerate with the single generator authority and diff against committed.
  if ! bash "$SELF_DIR/fm-roles-gen.sh" --out "$tmp" >/dev/null 2>&1; then
    fail_check "generator failed during dist-sync check"
    return
  fi
  for gen in "$tmp"/*.charter.md; do
    [ -e "$gen" ] || continue
    stem=$(basename "$gen" .charter.md)
    dist="$DIST_DIR/$stem.charter.md"
    if [ ! -e "$dist" ]; then
      fail_check "missing committed dist file: $stem.charter.md (run bin/fm-roles-gen.sh)"
    elif ! cmp -s "$dist" "$gen"; then
      fail_check "dist out of sync with sources: $stem.charter.md (run bin/fm-roles-gen.sh)"
    fi
  done
  for dist in "$DIST_DIR"/*.charter.md; do
    [ -e "$dist" ] || continue
    stem=$(basename "$dist" .charter.md)
    if [ ! -e "$tmp/$stem.charter.md" ]; then
      fail_check "unexpected dist file with no source: $stem.charter.md"
    fi
  done
}

check_file_exists "$BASE_FILE"
check_file_exists "$ANNEX_FILE"

check_karpathy
check_headings
check_budgets
check_no_project_content
check_distinct
check_charter_date
check_dist_sync

if [ "$FAILURES" -gt 0 ]; then
  printf 'fm-roles-lint: %d check(s) failed (%d warning(s))\n' "$FAILURES" "$WARNINGS" >&2
  exit 1
fi
printf 'fm-roles-lint: ok (%d warning(s))\n' "$WARNINGS"
