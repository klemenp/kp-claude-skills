#!/usr/bin/env bash
# Drives linked-item.sh over each case directory against the `gh` stub in bin/, which
# answers from that directory's pr.json and issue.json, and compares the output with its
# expected.json. Every case looks up PR #5. Then checks that a failed `gh` read is exit 1
# and bad arguments exit 2. Offline — no real `gh`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/linked-item.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH"
mismatches=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || mismatches=$((mismatches + 1))
}

for case_dir in "$here"/*/; do
  name="$(basename "$case_dir")"
  [ "$name" = bin ] && continue
  echo "== $name"
  actual="$(LINKED_ITEM_CASE="$case_dir" "$script" owner/repo 5)"
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

# A failed `gh pr view` is exit 1: the stub has no pr.json in an empty case.
echo "== gh failure"
mkdir -p "$work/empty"
LINKED_ITEM_CASE="$work/empty" "$script" owner/repo 5 >/dev/null 2>&1
status=$?
echo "exit $status"
if [ "$status" -eq 1 ]; then check "gh failure" ok; else check "gh failure" MISMATCH; fi

# A non-numeric PR is exit 2, distinct from a GitHub failure.
echo "== usage"
LINKED_ITEM_CASE="$work/empty" "$script" owner/repo five >/dev/null 2>&1
status=$?
echo "exit $status"
if [ "$status" -eq 2 ]; then check "usage" ok; else check "usage" MISMATCH; fi

echo
echo "mismatches: $mismatches"
exit $(( mismatches > 0 ? 1 : 0 ))
