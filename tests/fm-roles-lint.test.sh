#!/usr/bin/env bash
# Behavior tests for the role-charter generator and linter.
#
# Tests exercise bin/fm-roles-gen.sh and bin/fm-roles-lint.sh as executables
# against an isolated scratch copy of the roles tree, so they never read or
# mutate the repository's own roles/. They assert exit codes and reported
# findings, never implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GEN="$ROOT/bin/fm-roles-gen.sh"
LINT="$ROOT/bin/fm-roles-lint.sh"

# make_scratch <var>: create an isolated tree with the two scripts and a copy
# of the roles/ sources and dist, and assign its path to <var>.
make_scratch() {
  local d
  d=$(fm_test_tmproot "fm-roles-lint")
  mkdir -p "$d/bin"
  cp "$GEN" "$LINT" "$d/bin/"
  cp -R "$ROOT/roles" "$d/"
  eval "$1=$d"
}

# run_lint <scratch> [extra lint args...]: run the linter in a scratch tree and
# capture stdout+stderr.
run_lint() {
  local scratch=$1
  shift
  ( cd "$scratch" && ./bin/fm-roles-lint.sh "$@" ) 2>&1
}

# hash_dist <scratch>: sorted content hashes of the scratch dist charters.
hash_dist() {
  ( cd "$1" && {
      if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 roles/dist/*.charter.md
      else
        sha256sum roles/dist/*.charter.md
      fi
    } | awk '{print $1}' | sort )
}

test_repository_tree_lints_clean() {
  local scratch out rc
  make_scratch scratch
  set +e
  out=$(run_lint "$scratch")
  rc=$?
  set -e
  expect_code 0 "$rc" "clean scratch roles tree must lint clean"
  assert_not_contains "$out" "FAIL" "clean tree should report no FAIL lines"
  pass "repository roles tree lints clean"
}

test_generator_is_idempotent_and_in_sync() {
  local scratch
  make_scratch scratch
  # Snapshot the committed dist (the scratch copy holds it), regenerate twice,
  # and confirm both regenerations equal the committed dist.
  hash_dist "$scratch" > "$scratch/committed"
  ( cd "$scratch" && ./bin/fm-roles-gen.sh ) >/dev/null
  hash_dist "$scratch" > "$scratch/run1"
  ( cd "$scratch" && ./bin/fm-roles-gen.sh ) >/dev/null
  hash_dist "$scratch" > "$scratch/run2"
  cmp -s "$scratch/committed" "$scratch/run1" || fail "regeneration diverged from committed dist"
  cmp -s "$scratch/run1" "$scratch/run2" || fail "generator is not idempotent"
  pass "generator is idempotent and matches committed dist"
}

test_mutated_karpathy_block_fails_hash_check() {
  local scratch out rc
  make_scratch scratch
  sed -i.bak 's/Behavioral guidelines/Behavioral GUIDELINES/' "$scratch/roles/common-base.md"
  rm -f "$scratch/roles/common-base.md.bak"
  set +e
  out=$(run_lint "$scratch")
  rc=$?
  set -e
  expect_code 1 "$rc" "mutated Karpathy block must fail lint"
  assert_contains "$out" "Karpathy" "failure should name the Karpathy hash check"
  pass "mutated Karpathy block is caught by the hash check"
}

test_dist_drift_is_detected() {
  local scratch out rc
  make_scratch scratch
  printf '\n// drift\n' >> "$scratch/roles/dist/scout.charter.md"
  set +e
  out=$(run_lint "$scratch")
  rc=$?
  set -e
  expect_code 1 "$rc" "drifted dist must fail lint"
  assert_contains "$out" "out of sync" "failure should name dist being out of sync"
  pass "dist drift is detected"
}

test_budget_enforcement_flags_oversized_overlay() {
  local scratch out rc
  make_scratch scratch
  # Prepend ~200 filler words ahead of the scout overlay content to blow the
  # overlay word budget.
  python3 - "$scratch/roles/scout.md" <<'PY'
import sys
filler = "lorem ipsum dolor sit amet consectetur adipiscing elit " * 40
p = sys.argv[1]
body = open(p).read()
open(p, "w").write("# Role overlay: scout / researcher\n\n" + filler + "\n\n" + body)
PY
  set +e
  out=$(run_lint "$scratch")
  rc=$?
  set -e
  expect_code 1 "$rc" "oversized overlay must fail lint"
  assert_contains "$out" "words >" "failure should report the word budget"
  pass "budget enforcement flags an oversized overlay"
}

test_duplicate_deliverable_contract_fails_lint() {
  local scratch out rc
  make_scratch scratch
  # Give the architect overlay the scout's exact deliverable sentence, then
  # regenerate dist so only the distinctness check can fire.
  python3 - "$scratch/roles/scout.md" "$scratch/roles/architect.md" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
sentence = next(l for l in open(src) if l.startswith("Your deliverable is "))
lines = open(dst).readlines()
open(dst, "w").writelines(
    sentence if l.startswith("Your deliverable is ") else l for l in lines
)
PY
  ( cd "$scratch" && ./bin/fm-roles-gen.sh ) >/dev/null
  set +e
  out=$(run_lint "$scratch")
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate deliverable contracts must fail lint"
  assert_contains "$out" "deliverable contract" "failure should name the deliverable contract"
  pass "duplicate deliverable contracts are caught"
}

test_missing_dist_file_fails_lint() {
  local scratch out rc
  make_scratch scratch
  rm "$scratch/roles/dist/scout.charter.md"
  set +e
  out=$(run_lint "$scratch")
  rc=$?
  set -e
  expect_code 1 "$rc" "deleted committed dist charter must fail lint"
  assert_contains "$out" "missing committed dist file" "failure should name the missing dist file"
  pass "missing committed dist charter is detected"
}

test_repository_tree_lints_clean
test_generator_is_idempotent_and_in_sync
test_mutated_karpathy_block_fails_hash_check
test_dist_drift_is_detected
test_budget_enforcement_flags_oversized_overlay
test_duplicate_deliverable_contract_fails_lint
test_missing_dist_file_fails_lint
