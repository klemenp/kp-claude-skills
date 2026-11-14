#!/usr/bin/env bash
# Runs milestone-branch.sh with the fake `gh` and stub milestone-of.sh in bin/ (the stub
# through KP_GH_LIB_BIN), checking its stdout, its exit code, its stderr where it matters
# and the git/refs POSTs it made. Each scenario is written here as JSON for the fakes.
# Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/milestone-branch.sh"
failures=0
scenario="$(mktemp)"
post_log="$(mktemp)"
trap 'rm -f "$scenario" "$post_log"' EXIT

NULL_LINE='{"milestone": null, "branch": null, "exists": false, "created": false, "default": "main"}'
CREATE_M3_POST='o/r refs/heads/release/M3 head-main
'

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# expect <label> <want-exit> <want-stdout> <want-posts> <want-stderr> <milestone-branch.sh
# args…>, with the scenario already written to $scenario. An empty <want-stderr> is not
# checked; any other must equal stderr exactly.
expect() {
  local label=$1 want_exit=$2 want_stdout=$3 want_posts=$4 want_stderr=$5
  shift 5
  local stdout stderr_file exit_code
  echo "== $label"
  : >"$post_log"
  stderr_file="$(mktemp)"
  stdout="$(PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_GH_SCENARIO="$scenario" \
    FAKE_GH_POST_LOG="$post_log" "$script" "$@" 2>"$stderr_file")"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ]; then
    check "$label exit" ok
  else
    check "$label exit" "exit $exit_code, want $want_exit"
  fi
  if diff -u <(printf '%s' "$want_stdout") <(printf '%s' "$stdout"); then
    check "$label stdout" ok
  else
    check "$label stdout" MISMATCH
  fi
  if diff -u <(printf '%s' "$want_posts") "$post_log"; then
    check "$label posts" ok
  else
    check "$label posts" MISMATCH
  fi
  if [ -n "$want_stderr" ]; then
    if diff -u <(printf '%s\n' "$want_stderr") "$stderr_file"; then
      check "$label stderr" ok
    else
      check "$label stderr" MISMATCH
    fi
  fi
  rm -f "$stderr_file"
}

jq -n '{milestone: null, branches: ["main"]}' >"$scenario"
expect no-milestone 0 "$NULL_LINE" "" "" o/r 7
expect create-no-milestone 0 "$NULL_LINE" "" "" o/r 7 --create

jq -n '{milestone: "M2", branches: ["main", "release/M2"]}' >"$scenario"
expect exists 0 '{"milestone": "M2", "branch": "release/M2", "exists": true, "created": false, "default": "main"}' \
  "" "" o/r 7 --create

jq -n '{milestone: "M3", branches: ["main"]}' >"$scenario"
expect missing-no-create 0 '{"milestone": "M3", "branch": "release/M3", "exists": false, "created": false, "default": "main"}' \
  "" "" o/r 7
expect create 0 '{"milestone": "M3", "branch": "release/M3", "exists": true, "created": true, "default": "main"}' \
  "$CREATE_M3_POST" "" --create o/r 7

jq -n '{milestone: "M3", branches: ["main", "release/M2", "release/M1"]}' >"$scenario"
expect earlier-unmerged 3 "" "" "earlier-unmerged release/M1" o/r 7 --create

# The guard compares numerically: release/M10 is later than M3, so it never blocks.
jq -n '{milestone: "M3", branches: ["main", "release/M1a", "release/Mx", "release/M10", "xrelease/M1"]}' >"$scenario"
expect non-numeric-ignored 0 '{"milestone": "M3", "branch": "release/M3", "exists": true, "created": true, "default": "main"}' \
  "$CREATE_M3_POST" "" o/r 7 --create

echo "== bad-args"
for args in "" "o/r" "o/r 7 8" "o/r 7 --force" "kp-skills 7" "o/r 0" "o/r abc"; do
  # shellcheck disable=SC2086  # each case is a whitespace-separated argument list
  expect "bad-args [$args]" 2 "" "" "" $args
done

echo "== api-failure"
for failing in lookup listing head post milestone-of; do
  jq -n --arg failing "$failing" '{milestone: "M3", branches: ["main"], fail: [$failing]}' >"$scenario"
  expect "api-failure [$failing]" 1 "" "" "" o/r 7 --create
done

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
