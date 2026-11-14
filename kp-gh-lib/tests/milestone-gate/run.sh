#!/usr/bin/env bash
# Runs milestone-gate.sh against every <name>.json scenario with the fake `gh` in bin/
# first on PATH, and diffs the gate's JSON against the hand-written <name>.expected.json.
# Each scenario is an item in M2 behind an earlier M1, in the audit-gate states of
# NOTES.md § *Milestone sequencing* → *Audit gate*. Each call must also stay within
# MAX_SEARCHES search requests however many earlier milestones there are, since the
# search API allows 30 a minute. The current/<name>.json scenarios run the --current
# form the same way, and name no item; the milestone/<name>.json scenarios run the
# --milestone form for M1. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/milestone-gate.sh"
milestone_of="$repo_root/kp-gh-lib/scripts/milestone-of.sh"
failures=0
# One search for the milestone epics, one for all audits, one for all audit-close decisions.
MAX_SEARCHES=3
search_log="$(mktemp)"
no_linked_repos="$(mktemp)"
trap 'rm -f "$search_log" "$no_linked_repos"' EXIT

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# Runs one scenario with the given milestone-gate.sh arguments and checks its output and
# its search count.
run_scenario() {
  local name=$1 fixture=$2
  shift 2
  local actual searches
  echo "== $name"
  : >"$search_log"
  if ! actual="$(PATH="$here/bin:$PATH" FAKE_GH_SCENARIO="$fixture" FAKE_GH_SEARCH_LOG="$search_log" \
      "$script" "$@" 2>&1)"; then
    printf '%s\n' "$actual"
    check "$name" MISMATCH
    return
  fi
  if diff -u <(jq -S . "$here/$name.expected.json") <(jq -S . <<<"$actual"); then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
  searches="$(wc -l <"$search_log" | tr -d ' ')"
  if [ "$searches" -le "$MAX_SEARCHES" ]; then
    check "$name searches" ok
  else
    check "$name searches" "$searches > $MAX_SEARCHES"
  fi
}

for fixture in "$here"/*.json; do
  case "$fixture" in *.expected.json) continue ;; esac
  run_scenario "$(basename "$fixture" .json)" "$fixture" --project o/1 o/be 5
done

for fixture in "$here"/current/*.json; do
  case "$fixture" in *.expected.json) continue ;; esac
  run_scenario "current/$(basename "$fixture" .json)" "$fixture" --project o/1 --current
done

for fixture in "$here"/milestone/*.json; do
  case "$fixture" in *.expected.json) continue ;; esac
  run_scenario "milestone/$(basename "$fixture" .json)" "$fixture" --project o/1 --milestone M1
done

# Argument and project-lookup failures. Their scenarios are made here, never stored as
# *.json, since the loop above treats every *.json as a success scenario.
expect_failure() {
  local label=$1 want_exit=$2 want_stderr=$3
  shift 3
  local stderr exit_code
  echo "== $label"
  stderr="$(PATH="$here/bin:$PATH" FAKE_GH_SEARCH_LOG="$search_log" "$script" "$@" 2>&1 >/dev/null)"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ] && [[ $stderr == *"$want_stderr"* ]]; then
    check "$label" ok
  else
    printf '%s\n' "$stderr"
    check "$label" "exit $exit_code, want $want_exit with stderr containing '$want_stderr'"
  fi
}

export FAKE_GH_SCENARIO="$here/audit-current.json"
expect_failure missing-project 2 usage o/be 5
expect_failure malformed-project 2 usage --project foo o/be 5
expect_failure current-with-issue 2 usage --project o/1 --current o/be 5
expect_failure milestone-without-id 2 usage --project o/1 --milestone
expect_failure malformed-milestone 2 usage --project o/1 --milestone 1
expect_failure milestone-with-extra 2 usage --project o/1 --milestone M1 o/be
jq '.projectRepos = []' "$here/audit-current.json" >"$no_linked_repos"
FAKE_GH_SCENARIO="$no_linked_repos" expect_failure no-linked-repos 1 o/1 --project o/1 o/be 5

# The item's parent is its M2 epic, which has no parent, so the epic is the chain root.
echo "== milestone-of-root"
root="$(PATH="$here/bin:$PATH" "$milestone_of" o/be 5 | jq -r .root)"
if [ "$root" = "o/spec#20" ]; then
  check milestone-of-root ok
else
  check milestone-of-root "root $root, want o/spec#20"
fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
