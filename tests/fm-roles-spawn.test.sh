#!/usr/bin/env bash
# tests/fm-roles-spawn.test.sh - spawn-path integration for the role-charter
# hash validation (T2 dispatch integration). Drives bin/fm-spawn.sh against fake
# tmux panes and real isolated git worktrees, exercising the "Role charter:"
# brief agreement: hash-match launches and records role=/charter_hash= in meta,
# hash-mismatch refuses with a re-scaffold instruction, and a brief with no role
# line (back-compat) warns once and launches without a pinned charter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-roles-spawn)

# Real current dist hash for the implementer charter, so a match-case brief pins
# the byte the spawn will recompute.
real_implementer_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$ROOT/roles/dist/implementer.charter.md" | awk '{print $1}'
  else
    sha256sum "$ROOT/roles/dist/implementer.charter.md" | awk '{print $1}'
  fi
}

# Fake tmux that answers the pane-path query and accepts session commands so a
# real spawn completes through its fake backend and writes state/<id>.meta.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <role-line>: build a home+project+worktree and write a
# brief carrying the given role line (or none when empty). Emits a | record.
make_spawn_case() {
  local name=$1 role_line=$2 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n'
    [ -z "$role_line" ] || printf '%s\n' "$role_line"
    printf '# Task\nbrief body\n'
  } > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$id"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 id=$4 proj=$5
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR CASE_ID <<EOF
$1
EOF
}

test_hash_match_launches_and_records_role_in_meta() {
  local rec out status meta hash
  hash=$(real_implementer_hash)
  rec=$(make_spawn_case role-match "Role charter: role=implementer date=2026-08-18 hash=$hash")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "hash-match spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "hash-match spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  grep -q "^role=implementer$" "$meta" || fail "hash-match spawn must record role=implementer in meta"
  grep -q "^charter_hash=$hash$" "$meta" || fail "hash-match spawn must record the pinned charter_hash in meta"
  pass "hash-match: matching Role charter line launches and records role=/charter_hash= in meta"
}

test_hash_mismatch_refuses_with_rescaffold() {
  local rec out status meta
  rec=$(make_spawn_case role-mismatch "Role charter: role=implementer date=2026-08-18 hash=deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "hash-mismatch spawn must refuse"
  assert_contains "$out" "role charter mismatch" "refusal must name the role charter mismatch"
  assert_contains "$out" "re-scaffold the brief" "refusal must instruct re-scaffolding"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  [ ! -e "$meta" ] || fail "a refused hash-mismatch spawn must not write meta"
  pass "hash-mismatch: a Role charter line whose hash disagrees with the dist is refused with a re-scaffold instruction"
}

test_no_role_line_warns_and_launches_backcompat() {
  local rec out status meta
  rec=$(make_spawn_case role-absent "")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "back-compat brief with no role line should still launch"
  assert_contains "$out" "records no role charter line" "back-compat path must warn once about the missing role line"
  assert_contains "$out" "spawned $CASE_ID" "back-compat brief should still launch"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  ! grep -q '^role=' "$meta" || fail "back-compat spawn without a role line must not claim a role in meta"
  pass "no-role-line: a pre-charter brief warns once and launches without pinning a role"
}

test_scout_hash_match_also_validates() {
  local rec out status meta hash
  hash=$(real_implementer_hash)
  rec=$(make_spawn_case scout-match "Role charter: role=scout date=2026-08-18 hash=$(if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$ROOT/roles/dist/scout.charter.md" | awk '{print $1}'; else sha256sum "$ROOT/roles/dist/scout.charter.md" | awk '{print $1}'; fi)")
  read_case_record "$rec"

  out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$CASE_ID" "$PROJ_DIR" --scout 2>&1)
  status=$?
  expect_code 0 "$status" "scout hash-match spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "scout hash-match should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  grep -q "^role=scout$" "$meta" || fail "scout spawn must record role=scout in meta"
  pass "scout: the role-charter hash agreement also governs scout spawns"
}

test_hash_match_launches_and_records_role_in_meta
test_hash_mismatch_refuses_with_rescaffold
test_no_role_line_warns_and_launches_backcompat
test_scout_hash_match_also_validates
