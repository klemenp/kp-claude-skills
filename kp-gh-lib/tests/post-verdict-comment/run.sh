#!/usr/bin/env bash
# Drives post-verdict-comment.sh against the fakes in bin/ (gh, and pr-verdict-state.sh
# found through KP_GH_LIB_BIN): each case writes a state JSON for the fake to print, then
# checks the exit code, the action and comment id printed, the write call logged and that
# the logged body is byte-identical to the body file. Offline — no GitHub — so this runs
# in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/post-verdict-comment.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_LOG="$work/calls.log" \
  FAKE_STATE="$work/state.json"
failures=0

head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
old_sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
repo=example-org/demo
pr=7

# Bodies end without a newline and carry shell metacharacters and trailing spaces, so a
# byte-identical post proves the file was sent untouched. The `$HOME` and backticks are
# literal Markdown, not expansions.
# shellcheck disable=SC2016
write_body() {
  local file=$1 header=$2
  printf '%s\n\n## Review\n`x` $HOME "quoted"  \nlast line' "$header" > "$file"
}
approved="$work/approved.md"
denial="$work/denial.md"
fix="$work/fix.md"
stale="$work/stale.md"
no_marker="$work/no-marker.md"
write_body "$approved" "$(printf '<!-- kp-review-gh-pr:verdict -->\nverdict: APPROVED\napproved: %s' "$head_sha")"
write_body "$denial" "$(printf '<!-- kp-review-gh-pr:verdict -->\nverdict: REQUEST_CHANGES\nreviewed: %s' "$head_sha")"
write_body "$fix" "$(printf '<!-- kp-fix-pr:summary -->\npushed: %s' "$head_sha")"
write_body "$stale" "$(printf '<!-- kp-fix-pr:summary -->\npushed: %s' "$old_sha")"
write_body "$no_marker" "$(printf 'verdict: APPROVED\napproved: %s' "$head_sha")"

verdict_entry() { # <id> <createdAt> <verdict line> <sha line>
  jq -n --argjson id "$1" --arg at "$2" --arg body "$(printf '<!-- kp-review-gh-pr:verdict -->\n%s\n%s\n\nolder text' "$3" "$4")" \
    '{kind: "verdict", id: $id, createdAt: $at, updatedAt: $at, body: $body}'
}
fix_entry() { # <id> <createdAt> <sha>
  jq -n --argjson id "$1" --arg at "$2" --arg body "$(printf '<!-- kp-fix-pr:summary -->\npushed: %s\n\nfixed' "$3")" \
    '{kind: "fixSummary", id: $id, createdAt: $at, updatedAt: $at, body: $body}'
}
# set_state <fixSummary entry or null> [history entry…]
set_state() {
  local fix_summary=$1
  shift
  jq -n --arg head "$head_sha" --argjson fix "$fix_summary" \
    '{head: $head, verdict: null, denial: null, fixSummary: $fix, history: $ARGS.positional}' \
    --jsonargs "$@" > "$FAKE_STATE"
}

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# expect_post <name> <kind> <body file> <action> <id> — a posting case: exit 0, the
# action and id printed, one write call to the expected path, the body sent byte for byte.
expect_post() {
  local name=$1 kind=$2 body=$3 action=$4 id=$5
  echo "== $name"
  : > "$FAKE_LOG"
  local status=0 output expected_call
  output="$("$script" "$repo" "$pr" --kind "$kind" --body-file "$body")" || status=$?
  if [ "$action" = patched ]; then expected_call="PATCH repos/$repo/issues/comments/$id"
  else expected_call="POST repos/$repo/issues/$pr/comments"; fi
  if [ "$status" -eq 0 ] &&
    [ "$(jq -c '[.action, .id]' <<<"$output")" = "[\"$action\",$id]" ] &&
    [ "$(head -n 1 "$FAKE_LOG")" = "$expected_call" ] &&
    cmp -s <(tail -n +2 "$FAKE_LOG") "$body"; then
    check "$name" ok
  else
    printf 'exit %s, output: %s\nlog:\n%s\n' "$status" "$output" "$(cat "$FAKE_LOG")"
    check "$name" MISMATCH
  fi
}

# expect_exit <name> <kind> <body file> <exit code> [VAR=value …] — nothing may be written.
expect_exit() {
  local name=$1 kind=$2 body=$3 expected=$4
  shift 4
  echo "== $name"
  : > "$FAKE_LOG"
  local status=0
  env "$@" "$script" "$repo" "$pr" --kind "$kind" --body-file "$body" >/dev/null 2>"$work/err" ||
    status=$?
  if [ "$status" -eq "$expected" ] && [ ! -s "$FAKE_LOG" ]; then
    check "$name" ok
  else
    printf 'exit %s, stderr: %s\nlog:\n%s\n' "$status" "$(cat "$work/err")" "$(cat "$FAKE_LOG")"
    check "$name" MISMATCH
  fi
}

set_state null
expect_post "verdict with no prior verdict" verdict "$approved" created 9001

set_state null "$(verdict_entry 101 2026-10-01T10:00:00Z "verdict: APPROVED" "approved: $head_sha")"
expect_post "verdict re-run, same lines, no newer fix summary" verdict "$approved" patched 101

set_state null \
  "$(verdict_entry 101 2026-10-01T10:00:00Z "verdict: REQUEST_CHANGES" "reviewed: $head_sha")" \
  "$(fix_entry 201 2026-10-01T11:00:00Z "$head_sha")"
expect_post "verdict, same lines but a newer fix summary" verdict "$denial" created 9001

set_state null "$(verdict_entry 101 2026-10-01T10:00:00Z "verdict: REQUEST_CHANGES" "reviewed: $head_sha")"
expect_post "verdict, same head but a changed verdict line" verdict "$approved" created 9001

set_state null "$(verdict_entry 101 2026-10-01T10:00:00Z "verdict: APPROVED" "approved: $old_sha")"
expect_post "verdict, last verdict on an older head" verdict "$approved" created 9001

set_state "$(fix_entry 201 2026-10-01T11:00:00Z "$head_sha")"
expect_post "fix summary re-run on the same head" fixSummary "$fix" patched 201

set_state null
expect_post "fix summary with none newer than the denial" fixSummary "$fix" created 9001

set_state "$(fix_entry 201 2026-10-01T11:00:00Z "$old_sha")"
expect_post "fix summary on a different pushed head" fixSummary "$fix" created 9001

set_state null
expect_exit "body SHA is not the head" fixSummary "$stale" 3
if grep -qF "head moved: body $old_sha, head $head_sha" "$work/err"; then
  check "head-moved message" ok
else
  check "head-moved message" MISMATCH
fi
expect_exit "verdict body missing its marker" verdict "$no_marker" 2
expect_exit "fix summary body given as a verdict" verdict "$fix" 2
expect_exit "missing body file" verdict "$work/absent.md" 2
expect_exit "state read failure" verdict "$approved" 1 FAKE_STATE_FAIL=1

echo
if [ "$failures" -eq 0 ]; then echo "all post-verdict-comment fixtures passed"; else
  echo "$failures post-verdict-comment fixture(s) failed"; fi
[ "$failures" -eq 0 ]
