#!/usr/bin/env bash
# Drives item-outcome.sh over each case directory. The script runs as a copy in a temp
# directory, next to bin/sibling-stub copied under each sibling's name, with the `gh` stub
# in bin/ first on PATH; every stub answers from the case's JSON files. A case named
# issue-* looks up item #7 on project owner/4, a pr-* case PR #21; stdout must equal the
# case's expected.txt. Then checks that the `--pr` path never runs the milestone-gate or
# blocker-state stub, that the decision search gets the item's PR and its spec-ref from
# outside the human-only fence, that a failed read is exit 1 with empty stdout, and that
# bad arguments exit 2. Offline — no real `gh`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH"
export ITEM_OUTCOME_CALLS="$work/calls.log"
cp "$repo_root/kp-gh-lib/scripts/item-outcome.sh" "$work/"
mkdir "$work/py"
cp "$repo_root/kp-gh-lib/scripts/py/item_outcome.py" "$work/py/"
for sibling in find-task-pr.sh find-blocking-decision.sh blocker-state.sh milestone-gate.sh; do
  cp "$here/bin/sibling-stub" "$work/$sibling"
done
script="$work/item-outcome.sh"
mismatches=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || mismatches=$((mismatches + 1))
}

# Runs the script against one case directory: pr-* → --pr 21, anything else → --issue 7.
run_case() {
  local case_dir=$1
  : >"$ITEM_OUTCOME_CALLS"
  case "$(basename "$case_dir")" in
    pr-*) ITEM_OUTCOME_CASE="$case_dir" "$script" owner/repo --pr 21 ;;
    *) ITEM_OUTCOME_CASE="$case_dir" "$script" owner/repo --issue 7 --project owner/4 ;;
  esac
}

for case_dir in "$here"/*/; do
  name="$(basename "$case_dir")"
  [ "$name" = bin ] && continue
  echo "== $name"
  actual="$(run_case "$case_dir")"
  status=$?
  expected="$(cat "$case_dir/expected.txt")"
  if [ "$status" -eq 0 ] && [ "$actual" = "$expected" ]; then
    check "$name" ok
  else
    printf 'exit %s\nexpected: %s\nactual:   %s\n' "$status" "$expected" "$actual"
    check "$name" MISMATCH
  fi
  gated="$(grep -E '^(milestone-gate|blocker-state) ' "$ITEM_OUTCOME_CALLS")"
  if [[ $name == pr-* ]] && [ -n "$gated" ]; then
    echo "the --pr path ran: $gated"
    check "$name never runs milestone-gate or blocker-state" MISMATCH
  fi
done

echo "== decision search flags"
run_case "$here/issue-blocked-on-decision" >/dev/null 2>&1
flags="$(grep '^find-blocking-decision ' "$ITEM_OUTCOME_CALLS")"
echo "$flags"
if [ "$flags" = "find-blocking-decision owner/repo --issue 7 --pr 31 --spec-ref docs/spec.md#req-3" ]; then
  check "decision search flags" ok
else
  check "decision search flags" MISMATCH
fi

# A failed read is exit 1 with nothing on stdout: an empty case has no fixture at all, so
# the first read (find-task-pr for --issue, gh pr view for --pr) fails.
for name in issue-failure pr-failure; do
  echo "== $name"
  mkdir "$work/$name"
  actual="$(run_case "$work/$name" 2>/dev/null)"
  status=$?
  echo "exit $status, stdout '$actual'"
  if [ "$status" -eq 1 ] && [ -z "$actual" ]; then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
done

# Bad arguments are exit 2, distinct from a GitHub failure.
usage_case() {
  local label=$1
  shift
  "$script" "$@" >/dev/null 2>&1
  local status=$?
  echo "== usage: $label (exit $status)"
  if [ "$status" -eq 2 ]; then check "usage: $label" ok; else check "usage: $label" MISMATCH; fi
}
usage_case "neither --issue nor --pr" owner/repo --project owner/4
usage_case "both --issue and --pr" owner/repo --issue 7 --pr 21 --project owner/4
usage_case "--issue without --project" owner/repo --issue 7
usage_case "--pr with --project" owner/repo --pr 21 --project owner/4

echo
echo "mismatches: $mismatches"
exit $(( mismatches > 0 ? 1 : 0 ))
