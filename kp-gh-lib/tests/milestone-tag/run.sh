#!/usr/bin/env bash
# Runs milestone-tag.sh with the fake `gh` and stub milestone-gate.sh in bin/ (the stub
# through KP_GH_LIB_BIN), checking its stdout, its exit code and the git/refs POSTs it
# made. Each scenario is written here as JSON for the fakes. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/milestone-tag.sh"
failures=0
scenario="$(mktemp)"
post_log="$(mktemp)"
trap 'rm -f "$scenario" "$post_log"' EXIT

DONE_GATE='{"milestone": "M1", "done": true, "repos": ["o/be", "o/plan", "o/spec"]}'

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# expect <label> <want-exit> <want-stdout> <want-posts> <milestone-tag.sh args…>, with the
# scenario already written to $scenario.
expect() {
  local label=$1 want_exit=$2 want_stdout=$3 want_posts=$4
  shift 4
  local stdout exit_code
  echo "== $label"
  : >"$post_log"
  stdout="$(PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_GH_SCENARIO="$scenario" \
    FAKE_GH_POST_LOG="$post_log" "$script" "$@" 2>/dev/null)"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ]; then
    check "$label exit" ok
  else
    check "$label exit" "exit $exit_code, want $want_exit"
  fi
  # Command substitution drops stdout's trailing newline, so drop the expected one too.
  if diff -u <(printf '%s' "${want_stdout%$'\n'}") <(printf '%s' "$stdout"); then
    check "$label stdout" ok
  else
    check "$label stdout" MISMATCH
  fi
  if diff -u <(printf '%s' "$want_posts") "$post_log"; then
    check "$label posts" ok
  else
    check "$label posts" MISMATCH
  fi
}

jq -n '{gate: {milestone: "M1", done: false, repos: ["o/be", "o/plan"]}}' >"$scenario"
expect not-done 0 "not-done M1
" "" --project o/1 M1

jq -n --argjson gate "$DONE_GATE" '{gate: $gate, defaultBranch: {"o/spec": "trunk"}}' >"$scenario"
expect done-untagged 0 "tagged o/be milestone/M1 head-o-be
tagged o/plan milestone/M1 head-o-plan
tagged o/spec milestone/M1 head-o-spec
" "o/be refs/tags/milestone/M1 head-o-be
o/plan refs/tags/milestone/M1 head-o-plan
o/spec refs/tags/milestone/M1 head-o-spec
" --project o/1 M1

jq -n --argjson gate "$DONE_GATE" '{gate: $gate, tags: {"o/plan": "old-plan-sha"}}' >"$scenario"
expect tag-exists 0 "tagged o/be milestone/M1 head-o-be
exists o/plan milestone/M1 old-plan-sha
tagged o/spec milestone/M1 head-o-spec
" "o/be refs/tags/milestone/M1 head-o-be
o/spec refs/tags/milestone/M1 head-o-spec
" --project o/1 M1

jq -n --argjson gate "$DONE_GATE" '{gate: $gate, failCreate: ["o/be"]}' >"$scenario"
expect create-fails 1 "failed o/be: gh: Reference update failed (HTTP 422)
tagged o/plan milestone/M1 head-o-plan
tagged o/spec milestone/M1 head-o-spec
" "o/plan refs/tags/milestone/M1 head-o-plan
o/spec refs/tags/milestone/M1 head-o-spec
" --project o/1 M1

jq -n --argjson gate "$DONE_GATE" '{gate: $gate, gateFails: true}' >"$scenario"
expect gate-fails 1 "" "" --project o/1 M1

expect missing-project 2 "" "" M1
expect malformed-milestone 2 "" "" --project o/1 1
expect extra-argument 2 "" "" --project o/1 M1 o/be

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
