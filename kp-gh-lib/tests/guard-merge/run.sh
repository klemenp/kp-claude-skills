#!/usr/bin/env bash
# Pipes PreToolUse events to .claude/hooks/guard_merge.py with the `gh` stub in bin/ first
# on PATH, and checks the gate's answer: empty stdout is "allow", a JSON deny carries its
# reason. Covers every spelling of a merge the gate detects (each allowed for an approved
# PR and denied for an unreviewed one), several merges in one command, the two forms it
# refuses outright, text that only mentions a merge, segment edges, and the gate's
# allow/deny decisions. The PRs live in a mktemp -d case directory the stub reads.
# Offline — no real `gh`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
hook="$repo_root/.claude/hooks/guard_merge.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH"
export GUARD_MERGE_CASE="$work/case"
mkdir -p "$GUARD_MERGE_CASE"
failures=0

head_sha=1111111111111111111111111111111111111111
old_sha=2222222222222222222222222222222222222222
marker='<!-- kp-review-gh-pr:verdict -->'
green='[{"name": "validate", "bucket": "pass"}]'

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# pr <n> <state> <isDraft> <checks json> <reviews json> <comments json>
pr() {
  mkdir -p "$GUARD_MERGE_CASE/pr-$1"
  printf '{"state": "%s", "isDraft": %s, "headRefOid": "%s"}\n' "$2" "$3" "$head_sha" \
    >"$GUARD_MERGE_CASE/pr-$1/view.json"
  printf '%s\n' "$4" >"$GUARD_MERGE_CASE/pr-$1/checks.json"
  printf '%s\n' "$5" >"$GUARD_MERGE_CASE/pr-$1/reviews.json"
  printf '%s\n' "$6" >"$GUARD_MERGE_CASE/pr-$1/comments.json"
}

# verdict <APPROVED|REQUEST_CHANGES> <sha> <updated_at>: one marked verdict comment.
verdict() {
  local line="approved: $2"
  [ "$1" = APPROVED ] || line="reviewed: $2"
  jq -cn --arg body "$marker"$'\n'"verdict: $1"$'\n'"$line" --arg at "$3" \
    '{body: $body, updated_at: $at}'
}

approval="$(verdict APPROVED "$head_sha" 2026-01-02T00:00:00Z)"
pr 5 OPEN false "$green" '[]' "[$approval]"
pr 6 OPEN false "$green" '[]' '[]'
pr 7 OPEN false "$green" '[]' "[$(verdict APPROVED "$old_sha" 2026-01-02T00:00:00Z)]"
pr 8 OPEN false "$green" '[]' \
  "[$approval, $(verdict REQUEST_CHANGES "$head_sha" 2026-01-03T00:00:00Z)]"
pr 9 OPEN false "$green" \
  "[{\"state\": \"APPROVED\", \"submitted_at\": \"2026-01-02T00:00:00Z\", \"commit_id\": \"$head_sha\"}]" '[]'
pr 10 OPEN false '[{"name": "validate", "bucket": "fail"}]' '[]' "[$approval]"
pr 11 OPEN true "$green" '[]' "[$approval]"
pr 12 MERGED false "$green" '[]' "[$approval]"
pr 13 OPEN false "$green" '[]' "[$approval]"
touch "$GUARD_MERGE_CASE/pr-13/view.fail"

# gate <command>: runs the hook on one Bash event. Leaves its stdout in $out, the deny
# reason (empty on an allow) in $reason and the stub's calls in $calls.
gate() {
  : >"$GUARD_MERGE_CASE/calls.log"
  out=$(jq -cn --arg command "$1" --arg cwd "$work" '{tool_input: {command: $command}, cwd: $cwd}' |
    python3 "$hook")
  reason=$(jq -r 'select(.hookSpecificOutput.permissionDecision == "deny")
    | .hookSpecificOutput.permissionDecisionReason' <<<"${out:-null}")
  calls=$(cat "$GUARD_MERGE_CASE/calls.log")
}

# allowed <label> <command>: no opinion from the gate, after it read the PR named <read>.
allowed() {
  gate "$2"
  if [ -z "$out" ] && grep -q "^pr view $3 " <<<"$calls"; then
    check "$1" ok
  else
    echo "   stdout: $out"
    check "$1" MISMATCH
  fi
}

# denied <label> <command> <text the reason must contain>
denied() {
  gate "$2"
  if [ -n "$reason" ] && grep -qF -- "$3" <<<"$reason"; then
    check "$1" ok
  else
    echo "   stdout: $out"
    check "$1" MISMATCH
  fi
}

# ignored <label> <command>: not a merge, so no output and no gh call at all.
ignored() {
  gate "$2"
  if [ -z "$out" ] && [ -z "$calls" ]; then
    check "$1" ok
  else
    echo "   stdout: $out | calls: $calls"
    check "$1" MISMATCH
  fi
}

# spelling <label> <command with N for the PR number>
spelling() {
  allowed "$1, approved PR" "${2//N/5}" 5
  denied "$1, unreviewed PR" "${2//N/6}" "PR #6 has no review verdict"
}

spelling "gh pr merge" 'gh pr merge N --squash -R fx/code'
spelling "gh by full path" '/opt/homebrew/bin/gh pr merge N --squash -R fx/code'
spelling "option before the subcommand" 'gh -R fx/code pr merge N --squash'
spelling "command gh" 'command gh pr merge N --squash -R fx/code'
spelling "bash -c" 'bash -c "gh pr merge N --squash -R fx/code"'
spelling "bash -lc" 'bash -lc "gh pr merge N --squash -R fx/code"'
spelling "eval" 'eval "gh pr merge N --squash -R fx/code"'
spelling "gh api REST path" 'gh api --method PUT repos/fx/code/pulls/N/merge -f merge_method=squash'
spelling "curl REST path" \
  'curl -X PUT https://api.github.com/repos/fx/code/pulls/N/merge -d merge_method=squash'

denied "two merges, second unreviewed" \
  'gh pr merge 5 --squash -R fx/code && gh pr merge 6 --squash -R fx/code' "PR #6"
allowed "two merges, both approved" \
  'gh pr merge 5 --squash -R fx/code && gh pr merge 5 --squash -R fx/code' 5
denied "two merges, unspaced semicolon" \
  'gh pr merge 5 --squash -R fx/code;gh pr merge 6 --squash -R fx/code' "PR #6"
denied "squash of a later merge does not count" \
  'gh pr merge 5 -R fx/code && gh pr merge 5 --squash -R fx/code' "pass --squash"

denied "GraphQL merge mutation" \
  "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"PR_x\"}) { clientMutationId } }'" \
  "GraphQL merge"
denied "auto-merge" 'gh pr merge 5 --squash --auto -R fx/code' "auto-merge"

ignored "gh pr view" 'gh pr view 6 -R fx/code'
ignored "merge named in a commit message" 'git commit -m "then run gh pr merge 6 --squash"'
ignored "merge named in a comment body" \
  'gh pr comment 6 -R fx/code --body "gh pr merge 6 --squash"'
ignored "unrelated command" 'echo done'

denied "newline ends a segment" $'gh pr merge 5 -R fx/code\necho --squash' "pass --squash"
denied "unquoted mention is treated as a merge" \
  'echo gh pr merge 6 --squash -R fx/code' "PR #6 has no review verdict"
denied "subshell" '(gh pr merge 6 --squash -R fx/code)' "PR #6 has no review verdict"
denied "comment character does not hide a merge" \
  'true a#b; gh pr merge 6 --squash -R fx/code' "PR #6 has no review verdict"

denied "approval pinned to an older head" 'gh pr merge 7 --squash -R fx/code' "but the head is"
denied "newer denial after the approval" 'gh pr merge 8 --squash -R fx/code' "requests changes"
allowed "formal review at the head" 'gh pr merge 9 --squash -R fx/code' 9
denied "red check" 'gh pr merge 10 --squash -R fx/code' "CI is not green"
denied "draft PR" 'gh pr merge 11 --squash -R fx/code' "is a draft"
denied "merged PR" 'gh pr merge 12 --squash -R fx/code' "not open"
denied "no --squash" 'gh pr merge 5 -R fx/code' "pass --squash"
denied "no PR number" 'gh pr merge --squash -R fx/code' "name the PR number"
denied "gh fails, gate fails closed" 'gh pr merge 13 --squash -R fx/code' "fails closed"

echo
if [ "$failures" -eq 0 ]; then
  echo "all guard-merge checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
