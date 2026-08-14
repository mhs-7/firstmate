#!/usr/bin/env bash
# Tests for bin/fm-precheck.sh: firstmate's pre-review claim checker.
#
# The checker is advisory in v1: it must NEVER block review dispatch, so every
# skip path (absent config, endpoint down, unparseable output) exits 0 and
# prints a one-line notice. When configured and healthy, it renders the model's
# concrete gaps and appends one ledger line so rounds-saved vs false-holds is
# measurable.
#
# The HTTP call goes through the FM_PRE_CHECK_CURL seam (mirroring the
# FM_SSH_BIN command-seam convention in bin/fm-on.sh), so tests stub curl
# without binding to a real server or port.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PRECHECK="$ROOT/bin/fm-precheck.sh"
TMP_ROOT=$(fm_test_tmproot fm-precheck-tests)

# --- mock curl seam ---------------------------------------------------------
#
# fake_curl writes FAKE_CURL_BODY to the -o output file, prints FAKE_CURL_CODE
# as the response status, and returns FAKE_CURL_RC (default 0). With
# FAKE_CURL_CAPTURE set it records the request payload there so tests can assert
# the brief and diff were actually sent to the model.

install_fake_curl() {
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
out=
payload=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w|-m) shift 2 ;;
    -X|-H) shift 2 ;;
    --data) payload=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "${FAKE_CURL_BODY:-}" > "$out"
if [ -n "${FAKE_CURL_CAPTURE:-}" ] && [ -f "$payload" ]; then
  cp "$payload" "$FAKE_CURL_CAPTURE"
fi
printf '%s' "${FAKE_CURL_CODE:-200}"
exit "${FAKE_CURL_RC:-0}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin/curl"
}

# --- git fixture ------------------------------------------------------------
#
# new_case <name> creates project/<name>/project on branch main with an
# fm/task-x1 worktree. It must be called WITHOUT command substitution (the
# git-worktree plumbing makes command substitution run it in a subshell, which
# would discard the ROOT_DIR/WT_DIR/CASE_DIR globals). Globals ROOT_DIR/WT_DIR
# hold the project and worktree paths; CASE_DIR holds the case dir.

ROOT_DIR=
WT_DIR=
CASE_DIR=

new_case() {
  local name=$1 root wt
  root="$TMP_ROOT/$name/project"
  wt="$TMP_ROOT/$name/wt"
  mkdir -p "$root"
  git init -q "$root"
  git -C "$root" symbolic-ref HEAD refs/heads/main
  printf 'original\n' > "$root/app.js"
  git -C "$root" add app.js
  git -C "$root" -c user.email=t@t -c user.name=t commit -qm baseline
  git -C "$root" worktree add -q -b fm/task-x1 "$wt" main
  ROOT_DIR=$root
  WT_DIR=$wt
  CASE_DIR="$TMP_ROOT/$name"
}


write_meta() {  # <state_dir>
  local state=$1
  mkdir -p "$state"
  fm_write_meta "$state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$WT_DIR" \
    "project=$ROOT_DIR"
}

# Feature worktouching diff on app.js, leaving config.required untouched.
feature_commit() {
  printf 'changed\n' > "$WT_DIR/app.js"
  git -C "$WT_DIR" add app.js
  git -C "$WT_DIR" commit -qm "feature change"
}

write_brief() {  # <data_dir>
  local data=$1
  mkdir -p "$data/task-x1"
  cat > "$data/task-x1/brief.md" <<'EOF'
Acceptance criteria:
- must add config.required to the shipped defaults
- feature change in app.js
EOF
}

write_endpoint() {  # <config_dir>
  mkdir -p "$1"
  printf '%s\n' "http://127.0.0.1:9/v1" > "$1/precheck-endpoint"
}

run_for_task() {  # <state> <home>
  local state=$1 home=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" \
  FM_STATE_OVERRIDE="$state" \
  FM_CONFIG_OVERRIDE="$state/config" \
    "$PRECHECK" task-x1
}

# --- tests ------------------------------------------------------------------

test_absent_config_skips_cleanly() {
  local home state out rc
  new_case absentcfg
  home="$CASE_DIR"
  state="$home/state"
  write_meta "$state"
  # No config/precheck-endpoint exists.
  out=$(run_for_task "$state" "$home" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "absent config exits 0"
  assert_contains "$out" "precheck skipped" "absent config prints a skipped notice"
  assert_absent "$state/precheck-ledger.jsonl" "absent config does not append a ledger line"
  pass "absent config skips cleanly"
}

test_endpoint_down_skips_cleanly() {
  local home state out rc curl
  new_case enddown
  home="$CASE_DIR"
  state="$home/state"
  write_meta "$state"
  write_endpoint "$home/state/config"
  curl=$(install_fake_curl)
  # Endpoint down: curl fails (non-zero), so the checker records HTTP 000.
  out=$(FAKE_CURL_RC=7 FAKE_CURL_CODE=000 FM_PRE_CHECK_CURL="$curl" \
    run_for_task "$state" "$home" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "endpoint down exits 0"
  assert_contains "$out" "precheck skipped" "endpoint down prints a skipped notice"
  assert_absent "$state/precheck-ledger.jsonl" "endpoint down does not append a ledger line"
  pass "endpoint down skips cleanly"
}

test_untouched_file_produces_gap() {
  local home state out rc curl capture
  new_case gap
  home="$CASE_DIR"
  state="$home/state"
  write_meta "$state"
  feature_commit
  write_brief "$home/data"
  write_endpoint "$home/state/config"
  curl=$(install_fake_curl)
  capture=$(mktemp "${TMPDIR:-/tmp}/fm-precheck-capture.XXXXXX")
  # The model (played by fake curl) reports a mechanically-checkable
  # file-untouched gap grounded in the brief and diff.
  FAKE_CURL_BODY='{"gaps":[{"type":"file-untouched","claim":"must add config.required to the shipped defaults","evidence":"diff has no hunk for config.required"}],"annotations":["possible but unverified"]}'
  out=$(FM_PRE_CHECK_CURL="$curl" FAKE_CURL_BODY="$FAKE_CURL_BODY" \
    FAKE_CURL_CAPTURE="$capture" \
    run_for_task "$state" "$home" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "healthy check exits 0"
  assert_contains "$out" "CONCRETE GAPS" "render a CONCRETE GAPS section"
  assert_contains "$out" "file-untouched" "gap type is file-untouched"
  assert_contains "$out" "config.required" "gap names the untouched file"
  assert_contains "$out" "ANNOTATIONS" "render an ANNOTATIONS section"
  # The brief (naming the untouched file) and the diff must actually be sent.
  assert_grep "must add config.required" "$capture" "brief text is sent to the model"
  assert_grep "config.required" "$capture" "the untouched file is named in the sent brief"
  assert_grep '"task":"task-x1"' "$state/precheck-ledger.jsonl" "ledger records the task id"
  assert_grep '"gaps":1' "$state/precheck-ledger.jsonl" "ledger records one gap"
  rm -f "$capture"
  pass "untouched file produces a file-untouched gap grounded in brief+diff and appends the ledger"
}

test_no_gaps_appends_zero_ledger() {
  local home state out rc curl
  new_case nogap
  home="$CASE_DIR"
  state="$home/state"
  write_meta "$state"
  feature_commit
  write_endpoint "$home/state/config"
  curl=$(install_fake_curl)
  FAKE_CURL_BODY='{"gaps":[],"annotations":[]}'
  out=$(FM_PRE_CHECK_CURL="$curl" FAKE_CURL_BODY="$FAKE_CURL_BODY" \
    run_for_task "$state" "$home" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "no-gap check exits 0"
  assert_contains "$out" "no concrete gaps" "state that no concrete gaps were found"
  assert_grep '"gaps":0' "$state/precheck-ledger.jsonl" "ledger records zero gaps on a clean check"
  pass "clean check still appends a ledger line with gaps=0"
}

test_ad_hoc_diff_range_mode() {
  local root out rc curl base tip
  root="$TMP_ROOT/adhoctmp"
  mkdir -p "$root"
  git init -q "$root"
  git -C "$root" symbolic-ref HEAD refs/heads/main
  printf 'a\n' > "$root/f.txt"
  git -C "$root" add f.txt
  git -C "$root" -c user.email=t@t -c user.name=t commit -qm base
  base=$(git -C "$root" rev-parse HEAD)
  printf 'b\n' > "$root/f.txt"
  git -C "$root" add f.txt
  git -C "$root" -c user.email=t@t -c user.name=t commit -qm tip
  tip=$(git -C "$root" rev-parse HEAD)
  curl=$(install_fake_curl)
  write_endpoint "$root/config"
  FAKE_CURL_BODY='{"gaps":[],"annotations":[]}'
  out=$(cd "$root" && FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" \
    FM_PRE_CHECK_CURL="$curl" FAKE_CURL_BODY="$FAKE_CURL_BODY" \
    "$PRECHECK" --diff-range "$base...$tip" 2>/dev/null); rc=$?
  expect_code 0 "$rc" "ad-hoc --diff-range exits 0"
  assert_grep '"diff_source":"' "$root/state/precheck-ledger.jsonl" "ad-hoc check records a diff source"
  pass "ad-hoc --diff-range mode resolves and records the diff"
}

test_absent_config_skips_cleanly
test_endpoint_down_skips_cleanly
test_untouched_file_produces_gap
test_no_gaps_appends_zero_ledger
test_ad_hoc_diff_range_mode
