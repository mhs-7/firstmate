#!/usr/bin/env bash
# fm-precheck.sh - firstmate's pre-review claim checker (v1).
#
# Runs a cheap local model over a worker's claims-vs-diff BEFORE expensive
# review seats dispatch, so obvious gaps - a brief-required file that the diff
# never touches, a missing regression test, a claim the diff contradicts - are
# caught before a human or deep reviewer reads the branch.
#
# The checker is advisory in v1: it always exits 0 and never gates review
# dispatch mechanically. Firstmate reads the stdout gap list and owns judgment.
#
# Usage:
#   fm-precheck.sh <task-id> [--diff-range <base>...<tip>] [--brief <path>]
#
# With a task-id, the worktree and branch are resolved from state/<id>.meta the
# way bin/fm-review-diff.sh does (PR head preferred when a pr= is recorded).
# --diff-range and --brief override the resolved inputs for post-teardown or
# ad-hoc use; both are accepted without a task-id.
#
# Endpoint config: config/precheck-endpoint (LOCAL, gitignored). Line 1 is the
# OpenAI-compatible base URL (e.g. http://127.0.0.1:11434/v1); line 2, if
# present, is the path of a file holding a bearer API key. ABSENT config is a
# clean one-line skip (exit 0) - the checker must never block review dispatch
# when unconfigured, the endpoint is down, or the model output cannot be parsed.
#
# Output:
#   precheck: skipped (unparseable model output)  exactly one line when the
#       model output is empty or cannot be parsed; no gap sections are printed
#   CONCRETE GAPS section    mechanically-checkable gaps the brief/diff exposes
#   ANNOTATIONS section      uncertain observations the model flagged
# Exit status is 0 always (usage errors are the only non-zero exit).
#
# Ledger: one JSON line per invocation is appended to state/precheck-ledger.jsonl
# so rounds-saved vs false-holds is measurable over time.
#
# Environment:
#   FM_PRE_CHECK_CURL   curl executable (or mock seam). Default: curl.
#   FM_PRE_CHECK_TIMEOUT  curl hard bound in seconds. Default: 20.
#   FM_PRE_CHECK_DIFF_BYTES  byte cap on the diff sent to the model. Default: 64000.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

CURL="${FM_PRE_CHECK_CURL:-curl}"
TIMEOUT=${FM_PRE_CHECK_TIMEOUT:-20}
case "$TIMEOUT" in
  ''|*[!0-9]*|0*) TIMEOUT=20 ;;
esac
DIFF_BYTES=${FM_PRE_CHECK_DIFF_BYTES:-64000}
case "$DIFF_BYTES" in
  ''|*[!0-9]*|0*) DIFF_BYTES=64000 ;;
esac

usage() {
  echo "usage: fm-precheck.sh <task-id> [--diff-range <base>...<tip>] [--brief <path>]" >&2
  echo "       fm-precheck.sh --diff-range <base>...<tip> [--brief <path>]" >&2
  echo "       Empty or unparseable model output prints: precheck: skipped (unparseable model output)" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

# --- argument parsing --------------------------------------------------------

ID=
DIFF_RANGE=
DIFF_RANGE_SET=false
BRIEF=
BRIEF_SET=false
while [ $# -gt 0 ]; do
  case "$1" in
    --diff-range)
      [ $# -ge 2 ] || { usage; exit 1; }
      DIFF_RANGE=$2
      DIFF_RANGE_SET=true
      shift 2
      ;;
    --brief)
      [ $# -ge 2 ] || { usage; exit 1; }
      BRIEF=$2
      BRIEF_SET=true
      shift 2
      ;;
    -*) usage; exit 1 ;;
    *)
      [ -z "$ID" ] || { usage; exit 1; }
      ID=$1
      shift
      ;;
  esac
done

# Either a task-id or a --diff-range is required.
if [ -z "$ID" ] && ! "$DIFF_RANGE_SET"; then
  usage
  exit 1
fi

# --- endpoint config --------------------------------------------------------
#
# Absent config must be a clean skip: firstmate review dispatch is never blocked
# when the operator has not configured a local model endpoint.

precheck_endpoint_line() {  # <n> - nth non-empty, non-comment line
  local n=$1 idx=0 line
  [ -f "$CONFIG/precheck-endpoint" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    idx=$((idx + 1))
    if [ "$idx" = "$n" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$CONFIG/precheck-endpoint"
  return 1
}

if [ ! -f "$CONFIG/precheck-endpoint" ]; then
  echo "precheck skipped: no config/precheck-endpoint (checker is advisory and unconfigured)"
  exit 0
fi

BASE_URL=$(precheck_endpoint_line 1 || true)
if [ -z "$BASE_URL" ]; then
  echo "precheck skipped: config/precheck-endpoint has no non-comment base URL line"
  exit 0
fi
KEY_FILE=$(precheck_endpoint_line 2 || true)

# --- resolve brief and diff -------------------------------------------------

BRIEF_PATH=
if "$BRIEF_SET"; then
  BRIEF_PATH=$BRIEF
elif [ -n "$ID" ]; then
  BRIEF_PATH="$FM_HOME/data/$ID/brief.md"
fi


DIFF_SOURCE=
if "$DIFF_RANGE_SET"; then
  # Validate the range is base...tip with both sides resolvable by git. For
  # ad-hoc use run from the caller's current repo.
  case "$DIFF_RANGE" in
    *'...'*)
      base=${DIFF_RANGE%%...*}
      tip=${DIFF_RANGE##*...}
      ;;
    *)
      echo "precheck error: --diff-range must be <base>...<tip>" >&2
      exit 1
      ;;
  esac
  [ -n "$base" ] && [ -n "$tip" ] || { echo "precheck error: --diff-range must be <base>...<tip>" >&2; exit 1; }
  WT=$(pwd -P)
  git -C "$WT" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
    || { echo "precheck error: base $base does not resolve in $WT" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "$tip^{commit}" >/dev/null 2>&1 \
    || { echo "precheck error: tip $tip does not resolve in $WT" >&2; exit 1; }
  DIFF_TEXT=$(git -C "$WT" diff "$base...$tip" -- 2>/dev/null || true)
  DIFF_SOURCE="$base...$tip"
else
  # Resolve worktree/project/branch from meta the way fm-review-diff.sh does.
  META="$STATE/$ID.meta"
  [ -f "$META" ] || { echo "precheck error: no meta for task $ID at $META" >&2; exit 1; }
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PROJ=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$WT" ] && [ -d "$WT" ] \
    || { echo "precheck error: meta for task $ID has no usable worktree" >&2; exit 1; }
  [ -n "$PROJ" ] && [ -d "$PROJ" ] \
    || { echo "precheck error: meta for task $ID has no usable project" >&2; exit 1; }

  default_branch() {
    local ref b
    ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -n "$ref" ]; then
      printf '%s\n' "${ref#origin/}"
      return 0
    fi
    for b in main master; do
      if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$b"; then
        printf '%s\n' "$b"
        return 0
      fi
    done
    return 1
  }
  DEFAULT=$(default_branch) \
    || { echo "precheck error: cannot determine default branch for $PROJ" >&2; exit 1; }

  BRANCH="fm/$ID"
  if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
    BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -n "$BRANCH" ] \
      || { echo "precheck error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  fi

  PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
  COMPARE_REF=$BRANCH
  if [ -n "$PR_URL" ]; then
    case "$PR_URL" in
      *"/pull/"*)
        pr_n=${PR_URL##*/pull/}
        pr_n=${pr_n%%[!0-9]*}
        ;;
      [0-9]*)
        pr_n=${PR_URL%%[!0-9]*}
        ;;
      *) pr_n= ;;
    esac
    if [ -n "$pr_n" ] && git -C "$WT" fetch --quiet origin "+refs/pull/$pr_n/head:refs/fm-precheck/pull/$pr_n/head" >/dev/null 2>&1; then
      COMPARE_REF=$(git -C "$WT" rev-parse --verify "refs/fm-precheck/pull/$pr_n/head^{commit}" 2>/dev/null || true)
      [ -n "$COMPARE_REF" ] || COMPARE_REF=$BRANCH
    elif [ -n "$PR_HEAD_RECORDED" ] && git -C "$WT" cat-file -e "$PR_HEAD_RECORDED^{commit}" 2>/dev/null; then
      COMPARE_REF=$PR_HEAD_RECORDED
    fi
  fi

  if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
    git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet 2>/dev/null || true
    BASE="origin/$DEFAULT"
  else
    BASE="$DEFAULT"
  fi

  git -C "$WT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1 \
    || { echo "precheck error: base $BASE does not exist in $WT" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null 2>&1 \
    || { echo "precheck error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

  DIFF_TEXT=$(git -C "$WT" diff "$BASE...$COMPARE_REF" -- 2>/dev/null || true)
  DIFF_SOURCE="$BASE...$COMPARE_REF"
fi

# The tip for the ledger: prefer an explicit tip, else the resolved compare ref/HEAD.
TIPPED=
if "$DIFF_RANGE_SET"; then
  TIPPED=${DIFF_RANGE##*...}
else
  TIPPED=$(git -C "$WT" rev-parse "$COMPARE_REF" 2>/dev/null || true)
fi

append_unparseable_ledger() {
  mkdir -p "$STATE"
  printf '{"task":%s,"tip":%s,"outcome":"skipped_unparseable","timestamp":%s,"diff_source":%s}\n' \
    "$(printf '%s' "${ID:-ad-hoc}" | jq -R .)" \
    "$(printf '%s' "${TIPPED:-unknown}" | jq -R .)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ | jq -R .)" \
    "$(printf '%s' "$DIFF_SOURCE" | jq -R .)" \
    >> "$STATE/precheck-ledger.jsonl" 2>/dev/null || true
}

# --- build the prompt -------------------------------------------------------
#
# The model must emit ONLY concrete, mechanically-checkable gaps, plus a
# separate annotations array. Opinions, style notes, and severity judgments are
# forbidden: a gap is only valid when a reader could verify it from the brief
# and diff alone.

BRIEF_TEXT=
[ -n "$BRIEF_PATH" ] && [ -f "$BRIEF_PATH" ] && BRIEF_TEXT=$(cat "$BRIEF_PATH" 2>/dev/null || true)

SHORT_BRIEF=
if [ -n "$BRIEF_TEXT" ]; then
  SHORT_BRIEF="BRIEF (task instructions, acceptance criteria, findings):
$BRIEF_TEXT"
fi
if [ -n "$BRIEF_PATH" ] && [ ! -f "$BRIEF_PATH" ]; then
  SHORT_BRIEF="NOTE: brief at $BRIEF_PATH was requested but does not exist - judge claims against the diff only."
fi

# Byte cap with a truncation notice (the model runs 32K tokens per slot).
DIFF_CHUNK=$DIFF_TEXT
TRUNCATED=false
if [ "${#DIFF_CHUNK}" -gt "$DIFF_BYTES" ]; then
  DIFF_CHUNK=${DIFF_TEXT:0:$DIFF_BYTES}
  TRUNCATED=true
fi

PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-precheck-prompt.XXXXXX") || exit 1
RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-precheck-resp.XXXXXX") || exit 1
PAYLOAD_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-precheck-payload.XXXXXX") || exit 1
precheck_cleanup() {
  rm -f "$PROMPT_FILE" "$RESP_FILE" "$PAYLOAD_FILE"
}
trap precheck_cleanup EXIT

{
  printf 'You are a meticulous code reviewer. Given a task brief and a branch diff, find ONLY concrete, mechanically-checkable gaps a worker must fix before review.\n'
  printf '\n'
  printf 'Emissions rules - STRICT:\n'
  printf '  - Emit ONLY gaps a reader can verify mechanically from the brief and diff alone.\n'
  printf '  - A gap MUST be one of exactly three types:\n'
  printf '      file-untouched        a brief-required file is never changed by the diff (acceptance criterion / finding names it and the diff has no hunk for it)\n'
  printf '      missing-regression    a code change needs a regression test but the diff adds none for it\n'
  printf '      claim-contradiction   an explicit claim in the brief contradicts what the diff actually does\n'
  printf '  - FORBIDDEN: opinions, style notes, refactors, naming, severity judgments, praise, or any gap that needs taste to decide.\n'
  printf '  - If you are not sure a gap is real and mechanically checkable, put it in annotations, never in gaps.\n'
  printf '\n'
  printf 'Reply with EXACTLY ONE JSON object:\n'
  printf '  {"gaps":[{"type":"file-untouched|missing-regression|claim-contradiction","claim":"<verbatim quote from brief>","evidence":"<concrete observation from the diff>"}],"annotations":["<uncertain observation>", "..."]}\n'
  printf '  gaps and annotations may both be empty arrays when nothing applies.\n'
  printf '\n'
  printf 'DIFF TRUNCATION NOTICE: the diff below was truncated at %s bytes (model slot is 32K tokens). Only judge what you can see.\n' "$DIFF_BYTES"
  printf '===BEGIN BRIEF===\n'
  printf '%s\n' "$SHORT_BRIEF"
  printf '===END BRIEF===\n'
  printf '===BEGIN DIFF (source: %s, truncated: %s)===\n' "$DIFF_SOURCE" "$TRUNCATED"
  printf '%s\n' "$DIFF_CHUNK"
  printf '===END DIFF===\n'
} > "$PROMPT_FILE"

# --- call the OpenAI-compatible endpoint -------------------------------------

{
  printf '{"model":"precheck","messages":[{"role":"user","content":'
  # Embed the prompt as a JSON string (escape backslash and double-quote only;
  # newlines and tabs are legal inside a JSON string).
  p=$(cat "$PROMPT_FILE")
  printf '"%s"' "$(printf '%s' "$p" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '}]}'
} > "$PAYLOAD_FILE"

ENDPOINT=$BASE_URL
ENDPOINT=${ENDPOINT%/}
case "$ENDPOINT" in
  */chat/completions) : ;;
  *) ENDPOINT="$ENDPOINT/chat/completions" ;;
esac

AUTH_ARGS=()
if [ -n "$KEY_FILE" ]; then
  if [ -f "$KEY_FILE" ] && [ -r "$KEY_FILE" ]; then
    KEY=$(tr -d '[:space:]' < "$KEY_FILE" || true)
    [ -n "$KEY" ] && AUTH_ARGS=(-H "Authorization: Bearer $KEY")
  fi
fi

code=$("$CURL" -m "$TIMEOUT" -s -o "$RESP_FILE" -w '%{http_code}' \
  -X POST \
  -H 'Content-Type: application/json' \
  "${AUTH_ARGS[@]}" \
  --data @"$PAYLOAD_FILE" \
  "$ENDPOINT" 2>/dev/null) || code=000

if [ "$code" != "200" ]; then
  echo "precheck skipped: endpoint returned HTTP $code (checker is advisory and never blocks review dispatch)"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "precheck skipped: jq is required to parse model output and is not available"
  exit 0
fi

# OpenAI-compatible endpoints return the model's output as a JSON string inside
# choices[0].message.content. Some proxies return the {gaps,annotations} object
# directly. Handle either shape: parse the envelope content when present, else
# parse the response body itself.
ENV_CONTENT=$(jq -r '.choices[0].message.content // empty' "$RESP_FILE" 2>/dev/null || true)
if [ -n "$ENV_CONTENT" ]; then
  GAPS_JSON=$(printf '%s' "$ENV_CONTENT" | jq -c '.gaps // []' 2>/dev/null) || GAPS_JSON=
  ANNOT_JSON=$(printf '%s' "$ENV_CONTENT" | jq -c '.annotations // []' 2>/dev/null) || ANNOT_JSON=
else
  GAPS_JSON=$(jq -c '.gaps // []' "$RESP_FILE" 2>/dev/null) || GAPS_JSON=
  ANNOT_JSON=$(jq -c '.annotations // []' "$RESP_FILE" 2>/dev/null) || ANNOT_JSON=
fi

GAP_COUNT=$(printf '%s' "$GAPS_JSON" | jq 'length' 2>/dev/null || true)
ANNOT_COUNT=$(printf '%s' "$ANNOT_JSON" | jq 'length' 2>/dev/null || true)

case "$GAP_COUNT" in
  ''|*[!0-9]*)
    append_unparseable_ledger
    echo "precheck: skipped (unparseable model output)"
    exit 0
    ;;
esac
case "$ANNOT_COUNT" in
  ''|*[!0-9]*)
    append_unparseable_ledger
    echo "precheck: skipped (unparseable model output)"
    exit 0
    ;;
esac

# --- human-readable output --------------------------------------------------

echo "precheck: $( [ "$GAP_COUNT" -gt 0 ] && echo "found $GAP_COUNT concrete gap(s)" || echo "no concrete gaps" ) (diff: $DIFF_SOURCE)"
echo
echo "CONCRETE GAPS"
echo "-------------"
if [ "$GAP_COUNT" -gt 0 ]; then
  printf '%s' "$GAPS_JSON" | jq -r '.[] | "- type: \(.type)\n  claim: \(.claim)\n  evidence: \(.evidence)\n"' 2>/dev/null || echo "  (unparseable gaps)"
else
  echo "  (none)"
fi
echo
echo "ANNOTATIONS"
echo "-----------"
if [ "$ANNOT_COUNT" -gt 0 ]; then
  printf '%s' "$ANNOT_JSON" | jq -r '.[] | "- \(.)"' 2>/dev/null || echo "  (unparseable annotations)"
else
  echo "  (none)"
fi

# --- ledger -----------------------------------------------------------------

mkdir -p "$STATE"
printf '{"task":%s,"tip":%s,"gaps":%s,"annotations":%s,"timestamp":%s,"diff_source":%s}\n' \
  "$(printf '%s' "${ID:-ad-hoc}" | jq -R .)" \
  "$(printf '%s' "${TIPPED:-unknown}" | jq -R .)" \
  "$GAP_COUNT" \
  "$ANNOT_COUNT" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ | jq -R .)" \
  "$(printf '%s' "$DIFF_SOURCE" | jq -R .)" \
  >> "$STATE/precheck-ledger.jsonl" 2>/dev/null || true

precheck_cleanup

# v1 is advisory: always exit 0. Firstmate reads the gap list and owns judgment.
exit 0
