#!/usr/bin/env bash
# Runs ready-sweep.sh against every <name>.json case with the fake `gh` in bin/ first on
# PATH, and diffs its stdout against the hand-written <name>.expected. A case's optional
# `args` are passed after `--project o/1`. The fake logs every call, which checks the
# budget: one `api graphql` call for a user board and two for an org board, and one
# `issue view` per survivor of the sweep's own filters (the case's `views`), never for a
# dropped node. Then bad arguments exit 2 and a failed `issue view` exits 1 with empty
# stdout. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/ready-sweep.sh"
failures=0
call_log="$(mktemp)"
trap 'rm -f "$call_log"' EXIT
export PATH="$here/bin:$PATH" READY_SWEEP_LOG="$call_log"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

calls() {
  grep -c "^$1 " "$call_log"
}

for case_file in "$here"/*.json; do
  name="$(basename "$case_file" .json)"
  echo "== $name"
  extra=()
  while IFS= read -r arg; do
    extra+=("$arg")
  done < <(jq -r '.args // [] | .[]' "$case_file")
  : >"$call_log"
  actual="$(READY_SWEEP_CASE="$case_file" "$script" --project o/1 "${extra[@]}")"
  exit_code=$?
  # $(…) strips the final newline that every non-empty expected file ends with.
  [ -n "$actual" ] && actual+=$'\n'
  if [ "$exit_code" -eq 0 ] && diff -u "$here/$name.expected" <(printf '%s' "$actual"); then
    check "$name" ok
  else
    check "$name" "exit $exit_code or output mismatch"
  fi

  want_graphql=1
  [ "$(jq -r '.owner // "user"' "$case_file")" = organization ] && want_graphql=2
  got_graphql="$(calls graphql)"
  if [ "$got_graphql" -eq "$want_graphql" ]; then
    check "$name graphql calls" ok
  else
    check "$name graphql calls" "$got_graphql, want $want_graphql"
  fi

  want_views="$(jq -r .views "$case_file")"
  got_views="$(calls issue-view)"
  distinct_views="$(grep '^issue-view ' "$call_log" | sort -u | wc -l | tr -d ' ')"
  if [ "$got_views" -eq "$want_views" ] && [ "$distinct_views" -eq "$got_views" ]; then
    check "$name issue views" ok
  else
    check "$name issue views" "$got_views ($distinct_views distinct), want $want_views"
  fi
done

expect_failure() {
  local label=$1 want_exit=$2
  shift 2
  local stdout exit_code
  echo "== $label"
  stdout="$("$script" "$@" 2>/dev/null)"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ] && [ -z "$stdout" ]; then
    check "$label" ok
  else
    check "$label" "exit $exit_code with stdout '$stdout', want exit $want_exit and empty stdout"
  fi
}

export READY_SWEEP_CASE="$here/filters.json"
expect_failure missing-project 2
expect_failure malformed-project 2 --project foo
expect_failure malformed-repo 2 --project o/1 --repo nope
expect_failure malformed-only 2 --project o/1 --only 'a/b/c#1'
READY_SWEEP_FAIL_VIEW=1 expect_failure issue-view-failure 1 --project o/1

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
