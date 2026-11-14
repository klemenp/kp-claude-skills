#!/usr/bin/env bash
# Runs spec-pr-check.sh --from-file against every fixture directory and diffs its stdout
# with the directory's `expected`; `clean` must exit 0 and every other one 1. Offline: the
# fixture files stand in for the GitHub reads, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/spec-pr-check.sh"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for fixture in "$here"/*/; do
  name="$(basename "$fixture")"
  echo "== $name"
  status=0
  actual="$("$script" o/spec 1 --decision o/be#7 --from-file "$fixture" 2>&1)" || status=$?
  want_status=1
  [ "$name" = clean ] && want_status=0
  if [ "$status" -ne "$want_status" ]; then
    printf '%s\n' "$actual"
    check "$name exit $status, want $want_status" MISMATCH
  elif diff -u "$fixture/expected" <(printf '%s\n' "$actual"); then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
done

# Bad arguments are exit 2, distinct from a FAIL and from a GitHub failure.
status=0
"$script" o/spec 1 --decision not-a-ref >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then check "bad --decision exits 2" ok; else check "bad --decision exits 2 (got $status)" MISMATCH; fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
