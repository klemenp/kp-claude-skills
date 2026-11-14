#!/usr/bin/env bash
# Drives create-item.sh against the fakes in bin/ (gh plus the sibling scripts, found
# through KP_GH_LIB_BIN): each case sets the FAKE_* knobs that make one step fail or be
# skipped, then checks the exit code and the `skipped` step names; the full chain also
# checks the calls it made, in order. Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/create-item.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_LOG="$work/calls.log" \
  KP_MSG_ME_SEND="$here/bin/send.sh"
failures=0

body="$work/body.md"
# The backticks are literal Markdown in the issue body, not a command substitution.
# shellcheck disable=SC2016
printf 'Run `/kp-resolve-spec-decision __ISSUE__`.\n' > "$body"
args=(--repo example-org/demo --title "Which store?" --body-file "$body" --label type:decision
  --project example-org/4 --priority top --status Ready --assign-owner
  --origin example-org/demo#7 --cache "$work/cache.json")
case_args=("${args[@]}")

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# run_case <name> <expected skipped steps, JSON array> [VAR=value …]
# Runs the script with case_args. Every case expects exit 0: only the create itself is fatal.
run_case() {
  local name=$1 expected_steps=$2
  shift 2
  echo "== $name"
  : > "$FAKE_LOG"
  local status=0 steps
  output="$(env "$@" "$script" "${case_args[@]}")" || status=$?
  steps="$(jq -c '[.skipped[].step]' <<<"$output" 2>/dev/null)"
  if [ "$status" -eq 0 ] && [ "$steps" = "$expected_steps" ]; then
    check "$name" ok
  else
    printf 'exit %s, output: %s\n' "$status" "$output"
    check "$name" MISMATCH
  fi
}

run_case "full chain" '[]'
expected_calls="issue-create
issue-edit-body
notify example-org/demo#42 decision: Which store? — needs your call https://github.com/example-org/demo/issues/42
issue-edit-assignee example-org
board-add
priority
status s-ready
place
link I_node_5 I_new"
if [ "$(cat "$FAKE_LOG")" = "$expected_calls" ] &&
  [ "$(jq -c '[.number, .itemId, .milestone, .epic, .link]' <<<"$output")" = \
    '[42,"PVTI_new","M1","example-org/demo#5","item"]' ]; then
  check "full chain calls and output" ok
else
  printf 'calls:\n%s\noutput: %s\n' "$(cat "$FAKE_LOG")" "$output"
  check "full chain calls and output" MISMATCH
fi

run_case "organization owner" '["assignee"]' FAKE_OWNER_TYPE=organization
run_case "board without Priority" '["priority"]' FAKE_NO_PRIORITY=1
run_case "failed __ISSUE__ edit" '["substitute"]' FAKE_EDIT_FAIL=1
run_case "failed sub-issue link" '["link"]' FAKE_LINK_FAIL=1
run_case "failed notify" '["notify"]' FAKE_SEND_FAIL=1

# Only a human-gated label pings the operator.
echo "== coding item"
: > "$FAKE_LOG"
"$script" "${args[@]/type:decision/type:coding}" >/dev/null
if grep -q '^notify' "$FAKE_LOG"; then check "coding item sends no notify" MISMATCH
else check "coding item sends no notify" ok; fi

# A creator-decided item (NOTES § *Human-gated item body* → *Confidence and creator-decided
# items*): the comment is posted with the number substituted, Status defaults to Ready, and
# the operator is pinged only when the comment failed or Ready did not land.
decided="$work/decided.md"
# shellcheck disable=SC2016
printf '**Decision (agent, via /kp-do-gh-task, at filing):** B\n\nOverride: `/kp-resolve-spec-decision __ISSUE__`.\n\n<!-- decision-source: kp-do-gh-task -->\n' > "$decided"
case_args=(--repo example-org/demo --title "Which store?" --body-file "$body" --label type:decision
  --project example-org/4 --priority top --assign-owner --origin example-org/demo#7
  --cache "$work/cache.json" --decided-body-file "$decided")

run_case "decided item" '[]'
expected_calls="issue-create
issue-edit-body
issue-comment
issue-edit-assignee example-org
board-add
priority
status s-ready
place
link I_node_5 I_new"
if [ "$(cat "$FAKE_LOG")" = "$expected_calls" ]; then
  check "decided item calls: comment posted, Ready by default, no notify" ok
else
  printf 'calls:\n%s\n' "$(cat "$FAKE_LOG")"
  check "decided item calls: comment posted, Ready by default, no notify" MISMATCH
fi

run_case "decided item with failed comment" '["decided"]' FAKE_COMMENT_FAIL=1
if grep -q '^notify' "$FAKE_LOG"; then check "failed comment still pings" ok
else check "failed comment still pings" MISMATCH; fi

echo "== decided item without project"
: > "$FAKE_LOG"
status=0
"$script" --repo example-org/demo --title "Which store?" --body-file "$body" --label type:decision \
  --decided-body-file "$decided" >/dev/null || status=$?
if [ "$status" -eq 0 ] && grep -q '^issue-comment' "$FAKE_LOG" && grep -q '^notify' "$FAKE_LOG"; then
  check "decided item without project" ok
else
  printf 'exit %s, calls:\n%s\n' "$status" "$(cat "$FAKE_LOG")"
  check "decided item without project" MISMATCH
fi

echo "== decided item with wrong type"
status=0
"$script" "${case_args[@]/type:decision/type:question}" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then check "decided item with wrong type" ok
else echo "exit $status"; check "decided item with wrong type" MISMATCH; fi

# A failed create is the one fatal step; bad arguments are exit 2.
echo "== failed create"
status=0
FAKE_CREATE_FAIL=1 "$script" "${args[@]}" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 1 ]; then check "failed create exits 1" ok; else check "failed create exits 1" MISMATCH; fi
echo "== usage"
status=0
"$script" --repo example-org/demo --title t >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then check "usage exits 2" ok; else check "usage exits 2" MISMATCH; fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all create-item checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
