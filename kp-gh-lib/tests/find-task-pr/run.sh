#!/usr/bin/env bash
# Drives find-task-pr.sh over each case directory against the `gh` stub in bin/, which
# answers from that directory's pr-list.json, issue.json and pr-<n>.json, and compares
# the output with its expected.json. Every case looks up item #7. Then checks that a
# failed `gh` read is exit 1 and bad arguments exit 2. Offline — no real `gh`, no
# GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/find-task-pr.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for case_dir in "$here"/*/; do
  name="$(basename "$case_dir")"
  [ "$name" = bin ] && continue
  echo "== $name"
  actual="$(FIND_TASK_PR_CASE="$case_dir" "$script" owner/repo 7)"
  status=$?
  same="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]) == json.load(open(sys.argv[2])))' \
    "$actual" "$case_dir/expected.json" 2>/dev/null)"
  if [ "$status" -eq 0 ] && [ "$same" = True ]; then
    check "$name" ok
  else
    printf 'exit %s\nexpected: %s\nactual:   %s\n' "$status" "$(cat "$case_dir/expected.json")" "$actual"
    check "$name" MISMATCH
  fi
done

# A failed `gh` read is exit 1: the stub has no pr-list.json in an empty case.
echo "== gh failure"
mkdir -p "$work/empty"
FIND_TASK_PR_CASE="$work/empty" "$script" owner/repo 7 >/dev/null 2>&1
status=$?
echo "exit $status"
if [ "$status" -eq 1 ]; then check "gh failure" ok; else check "gh failure" MISMATCH; fi

# Bad arguments are exit 2, distinct from a GitHub failure.
echo "== usage"
"$script" owner/repo >/dev/null 2>&1
missing=$?
"$script" owner/repo seven >/dev/null 2>&1
non_numeric=$?
echo "exit $missing, $non_numeric"
if [ "$missing" -eq 2 ] && [ "$non_numeric" -eq 2 ]; then
  check "usage" ok
else
  check "usage" MISMATCH
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all find-task-pr checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
