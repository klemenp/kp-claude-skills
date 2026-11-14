#!/usr/bin/env bash
# Drives blocker-state.sh over each case directory against the `gh` stub in bin/, which
# answers from that directory's body.md and items.json — for blocker-state.sh and for
# the real milestone-of.sh and find-task-pr.sh it calls — and compares the output with
# its expected.json. Every case looks up item owner/repo#7. Then checks that a failed
# milestone lookup is exit 1 with empty stdout and bad arguments exit 2. Offline — no
# real `gh`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/blocker-state.sh"
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
  actual="$(BLOCKER_STATE_CASE="$case_dir" "$script" owner/repo 7)"
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

# A failed milestone-of.sh lookup is exit 1 with nothing on stdout: the blocker has no
# fixture, so the stub fails its GraphQL query.
echo "== milestone lookup failure"
mkdir -p "$work/lookup-fails"
printf 'blocked-by: #10\n' > "$work/lookup-fails/body.md"
echo '{"owner/repo#7": {}}' > "$work/lookup-fails/items.json"
stdout="$(BLOCKER_STATE_CASE="$work/lookup-fails" "$script" owner/repo 7 2>"$work/stderr")"
status=$?
echo "exit $status, stderr: $(cat "$work/stderr")"
if [ "$status" -eq 1 ] && [ -z "$stdout" ] && grep -q '^blocker-state.sh: milestone-of.sh' "$work/stderr"; then
  check "milestone lookup failure" ok
else
  check "milestone lookup failure" MISMATCH
fi

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
echo "mismatches: $mismatches"
exit $(( mismatches > 0 ? 1 : 0 ))
