#!/usr/bin/env bash
# Runs milestone-merge.sh with the fake `gh` and `sleep` and the stub milestone-gate.sh in
# bin/ (the stub through KP_GH_LIB_BIN), checking its stdout, its exit code and the calls it made. Each
# scenario is written here as JSON for the fakes; the fake's PR and branch state persists
# across runs in one state file, so a re-run sees the first run's merges. Offline, so
# this runs in CI.
# Every `scenario '…'` filter names jq's $gate, not a shell variable.
# shellcheck disable=SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/milestone-merge.sh"
failures=0
scenario="$(mktemp)"
call_log="$(mktemp)"
body_log="$(mktemp)"
gh_state="$(mktemp)"
checks_counter="$(mktemp -u)"
trap 'rm -f "$scenario" "$call_log" "$body_log" "$gh_state" "$checks_counter"' EXIT

DONE_GATE='{"milestone": "M1", "done": true, "repos": ["o/be", "o/plan"]}'
SYNC_BE="merges o/be base=release/M1 head=main"
CREATE_BE="pr-create o/be base=main head=release/M1 title=Merge M1 into main"
CHECKS_BE="pr-checks o/be 7"
MERGE_BE="pr-merge o/be 7 -R o/be --merge --delete-branch"
SYNC_PLAN="merges o/plan base=release/M1 head=trunk"
CREATE_PLAN="pr-create o/plan base=trunk head=release/M1 title=Merge M1 into trunk"
CHECKS_PLAN="pr-checks o/plan 7"
MERGE_PLAN="pr-merge o/plan 7 -R o/plan --merge --delete-branch"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

expect_eq() {
  local label=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    check "$label" ok
  else
    check "$label" "MISMATCH (want '$want', got '$got')"
  fi
}

# scenario <jq filter over $gate>: writes the scenario for the next runs.
scenario() {
  jq -n --argjson gate "$DONE_GATE" "$1" >"$scenario"
}

# fresh: forgets every PR created and branch deleted by earlier runs.
fresh() {
  : >"$gh_state"
}

# run <label> <milestone-merge.sh args…>, with the scenario already written: sets $stdout
# and $exit_code, and leaves this run's calls in $call_log and PR bodies in $body_log.
run() {
  echo "== $1"
  shift
  : >"$call_log"
  : >"$body_log"
  rm -f "$checks_counter"
  stdout="$(PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_GH_SCENARIO="$scenario" \
    FAKE_GH_STATE="$gh_state" FAKE_CALL_LOG="$call_log" FAKE_PR_BODY_LOG="$body_log" \
    FAKE_CHECKS_COUNTER="$checks_counter" "$script" "$@" 2>/dev/null)"
  exit_code=$?
}

calls() {
  cat "$call_log"
}

lines() {
  printf '%s\n' "$@" | sed '/^$/d'
}

# not-done: nothing is looked up or touched.
fresh
jq -n '{gate: {milestone: "M1", done: false, repos: ["o/be", "o/plan"]}}' >"$scenario"
run not-done --project o/1 M1
expect_eq "not-done exit" 0 "$exit_code"
expect_eq "not-done stdout" "not-done M1" "$stdout"
expect_eq "not-done calls" "" "$(calls)"

# all-no-branch: no release/M1 anywhere — the spec-repo and kp-skills case.
fresh
scenario '{gate: $gate}'
run all-no-branch --project o/1 M1
expect_eq "all-no-branch exit" 0 "$exit_code"
expect_eq "all-no-branch stdout" "$(lines "no-branch o/be" "no-branch o/plan")" "$stdout"
expect_eq "all-no-branch calls" "" "$(calls)"

# merged: 204 sync, PR created, green CI, merge commit; o/plan has no branch.
fresh
scenario '{gate: $gate, branches: ["o/be"]}'
run merged --project o/1 M1
expect_eq "merged exit" 0 "$exit_code"
expect_eq "merged stdout" "$(lines "merged o/be 7 merge-o-be" "no-branch o/plan")" "$stdout"
expect_eq "merged calls" "$(lines "$SYNC_BE" "$CREATE_BE" "$CHECKS_BE" "$MERGE_BE")" "$(calls)"
expect_eq "merged PR body marker" 1 "$(grep -cxF 'milestone-merge: M1' "$body_log")"
expect_eq "merged PR body has no closing keyword" 0 "$(grep -ciwE '(close[sd]?|fix(e[sd])?|resolve[sd]?)' "$body_log")"
expect_eq "merged never squashes" 0 "$(grep -c -- --squash "$call_log")"

# checks-appear: the watch and the first re-poll report no checks, the second re-poll
# sees them, and the second watch is green.
fresh
scenario '{gate: $gate, branches: ["o/be"], noChecks: {"o/be": [1, 2]}}'
run checks-appear --project o/1 M1
expect_eq "checks-appear exit" 0 "$exit_code"
expect_eq "checks-appear stdout" "$(lines "merged o/be 7 merge-o-be" "no-branch o/plan")" "$stdout"
expect_eq "checks-appear calls" "$(lines "$SYNC_BE" "$CREATE_BE" "$CHECKS_BE" "sleep 30" "$CHECKS_BE" \
  "sleep 30" "$CHECKS_BE" "$CHECKS_BE" "$MERGE_BE")" "$(calls)"

# checks-appear-failed: checks that appear on a re-poll are classified by the second watch.
fresh
scenario '{gate: $gate, branches: ["o/be"], noChecks: {"o/be": [1]}, checks: {"o/be": "fail"}}'
run checks-appear-failed --project o/1 M1
expect_eq "checks-appear-failed exit" 1 "$exit_code"
expect_eq "checks-appear-failed stdout" "$(lines "ci-failed o/be 7" "no-branch o/plan")" "$stdout"
expect_eq "checks-appear-failed no merge" 0 "$(grep -c '^pr-merge' "$call_log")"

# no-checks-bound: checks never appear; after the 10th re-poll the repo passes.
fresh
scenario '{gate: $gate, branches: ["o/be"], noChecks: {"o/be": "all"}}'
run no-checks-bound --project o/1 M1
expect_eq "no-checks-bound exit" 0 "$exit_code"
expect_eq "no-checks-bound stdout" "$(lines "merged o/be 7 merge-o-be" "no-branch o/plan")" "$stdout"
expect_eq "no-checks-bound sleeps" 10 "$(grep -cx 'sleep 30' "$call_log")"
expect_eq "no-checks-bound checks calls" 11 "$(grep -cxF "$CHECKS_BE" "$call_log")"
expect_eq "no-checks-bound merges" 1 "$(grep -cxF "$MERGE_BE" "$call_log")"

# conflict: o/be's sync is a 409; o/plan (default branch trunk) still merges.
fresh
scenario '{gate: $gate, branches: ["o/be", "o/plan"], syncConflict: ["o/be"],
  defaultBranch: {"o/plan": "trunk"}}'
run conflict --project o/1 M1
expect_eq "conflict exit" 1 "$exit_code"
expect_eq "conflict stdout" \
  "$(lines "conflict o/be: gh: Merge conflict (HTTP 409)" "merged o/plan 7 merge-o-plan")" "$stdout"
expect_eq "conflict calls" "$(lines "$SYNC_BE" "$SYNC_PLAN" "$CREATE_PLAN" "$CHECKS_PLAN" "$MERGE_PLAN")" \
  "$(calls)"

# ci-failed: a red check stops the repo before any merge.
fresh
scenario '{gate: $gate, branches: ["o/be"], checks: {"o/be": "fail"}}'
run ci-failed --project o/1 M1
expect_eq "ci-failed exit" 1 "$exit_code"
expect_eq "ci-failed stdout" "$(lines "ci-failed o/be 7" "no-branch o/plan")" "$stdout"
expect_eq "ci-failed no merge" 0 "$(grep -c '^pr-merge' "$call_log")"

# rerun-open-pr: after the ci-failed run, o/be's checks go green; its open PR is found,
# not created again.
scenario '{gate: $gate, branches: ["o/be"]}'
run rerun-open-pr --project o/1 M1
expect_eq "rerun-open-pr exit" 0 "$exit_code"
expect_eq "rerun-open-pr stdout" "$(lines "merged o/be 7 merge-o-be" "no-branch o/plan")" "$stdout"
expect_eq "rerun-open-pr calls" "$(lines "$SYNC_BE" "$CHECKS_BE" "$MERGE_BE")" "$(calls)"

# rerun: after a conflict, the merged repo now reports no-branch, only o/be is retried.
fresh
scenario '{gate: $gate, branches: ["o/be", "o/plan"], syncConflict: ["o/be"],
  defaultBranch: {"o/plan": "trunk"}}'
run rerun-first --project o/1 M1
expect_eq "rerun-first exit" 1 "$exit_code"
scenario '{gate: $gate, branches: ["o/be", "o/plan"], defaultBranch: {"o/plan": "trunk"}}'
run rerun-second --project o/1 M1
expect_eq "rerun-second exit" 0 "$exit_code"
expect_eq "rerun-second stdout" "$(lines "merged o/be 7 merge-o-be" "no-branch o/plan")" "$stdout"
expect_eq "rerun-second calls" "$(lines "$SYNC_BE" "$CREATE_BE" "$CHECKS_BE" "$MERGE_BE")" "$(calls)"

# ci-pending: `gh pr checks` exit 8 stops the repo before any merge.
fresh
scenario '{gate: $gate, branches: ["o/be"], checks: {"o/be": "pending"}}'
run ci-pending --project o/1 M1
expect_eq "ci-pending exit" 1 "$exit_code"
expect_eq "ci-pending stdout" "$(lines "ci-pending o/be 7" "no-branch o/plan")" "$stdout"
expect_eq "ci-pending no merge" 0 "$(grep -c '^pr-merge' "$call_log")"

# lookup-failed: o/be's repo lookup fails; o/plan is still processed.
fresh
scenario '{gate: $gate, branches: ["o/plan"], failRepo: ["o/be"]}'
run lookup-failed --project o/1 M1
expect_eq "lookup-failed exit" 1 "$exit_code"
expect_eq "lookup-failed stdout" \
  "$(lines "failed o/be: gh: Server Error (HTTP 502)" "merged o/plan 7 merge-o-plan")" "$stdout"

# gate-fails: exit 1, nothing printed.
fresh
scenario '{gate: $gate, gateFails: true}'
run gate-fails --project o/1 M1
expect_eq "gate-fails exit" 1 "$exit_code"
expect_eq "gate-fails stdout" "" "$stdout"

run missing-project M1
expect_eq "missing-project exit" 2 "$exit_code"
run malformed-milestone --project o/1 1
expect_eq "malformed-milestone exit" 2 "$exit_code"
run extra-argument --project o/1 M1 o/be
expect_eq "extra-argument exit" 2 "$exit_code"

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
