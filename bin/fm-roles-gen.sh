#!/usr/bin/env bash
# fm-roles-gen.sh - assemble firstmate's role-charter dist files from sources.
#
#   fm-roles-gen.sh                regenerate roles/dist/<role>.charter.md from roles/ sources
#   fm-roles-gen.sh --out <dir>    regenerate into <dir> instead of roles/dist
#   fm-roles-gen.sh --list         print the role -> dist-file mapping
#   fm-roles-gen.sh --dist-dir     print the dist directory path
#   fm-roles-gen.sh --help         print this usage
#
# Single authoring sources (roles/common-base.md, roles/<role>.md, and the
# deploy annex) are assembled into committed self-contained dist charters.
# Each dist charter reads base first, then the role overlay, then the deploy
# annex for the implementer role, matching the dispatch assembly order. The
# output is deterministic and idempotent: running it twice yields byte-identical
# dist files, so bin/fm-roles-lint.sh can verify dist sources are in sync by
# regenerating into a temp dir and diffing.
# HTML comment provenance blocks and the Karpathy delimiters are stripped when
# assembling; the byte-verbatim Karpathy block itself is preserved in the dist.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
ROLES_DIR="$ROOT/roles"
DIST_DIR="$ROLES_DIR/dist"

# Roles whose overlays and dist charters we build. The deploy annex is appended
# only to the implementer charter (it belongs to the implementer overlay by
# design; see the annex source header).
ROLES="scout architect implementer primary-reviewer second-vendor-reviewer adjudicator merge-train-sweeper"

usage() {
  sed -n '2,12{s/^# \{0,1\}//;p;}' "$SELF_DIR/fm-roles-gen.sh"
}

OUT_DIR="$DIST_DIR"
if [ "${1:-}" = "--out" ]; then
  OUT_DIR="${2:?--out needs a directory}"
  shift 2
fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "${1:-}" = "--list" ]; then
  for role in $ROLES; do
    printf '%s %s\n' "$role" "$OUT_DIR/$role.charter.md"
  done
  exit 0
fi
if [ "${1:-}" = "--dist-dir" ]; then
  printf '%s\n' "$DIST_DIR"
  exit 0
fi

# Emit a source file with HTML-comment provenance blocks removed and the
# Karpathy delimiters removed. The byte-verbatim Karpathy block between the
# delimiters is preserved verbatim.
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

mkdir -p "$OUT_DIR"

for role in $ROLES; do
  base_body="$(strip_sources "$ROLES_DIR/common-base.md")"
  overlay_body="$(strip_sources "$ROLES_DIR/$role.md")"
  annex_body=""
  if [ "$role" = "implementer" ]; then
    annex_body="$(strip_sources "$ROLES_DIR/annex-deploy-verifier.md")"
  fi
  {
    printf '%s' "$base_body"
    printf '\n\n'
    printf '%s' "$overlay_body"
    if [ -n "$annex_body" ]; then
      printf '\n\n'
      printf '%s' "$annex_body"
    fi
    printf '\n'
  } > "$OUT_DIR/$role.charter.md"
done

printf 'fm-roles-gen: wrote %d charter files in %s\n' \
  "$(printf '%s\n' "$ROLES" | wc -w | tr -d ' ')" "$OUT_DIR"
