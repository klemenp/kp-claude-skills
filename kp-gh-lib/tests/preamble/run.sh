#!/usr/bin/env bash
# Drives preamble.sh's --no-item and --pr modes against the fake gh in bin/, inside a
# throwaway git repo: --no-item comes back with every work-item field null and no item
# lookup or board add, the mode flags are exclusive and required, an unresolved project still exits 6, and
# a --pr whose closingIssuesReferences is empty takes its issue from the body's keyword.
# Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/preamble.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" FAKE_LOG="$work/calls.log"
failures=0

checkout="$work/checkout"
git init -q "$checkout"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# run_preamble <args…> — runs preamble.sh --no-fetch in the throwaway checkout and sets
# $status and $output; stderr is dropped.
run_preamble() {
  : > "$FAKE_LOG"
  status=0
  output="$(cd "$checkout" && "$script" --no-fetch "$@" 2>/dev/null)" || status=$?
}

echo "== (a) --no-item --project example-org/4"
run_preamble --no-item --project example-org/4
fields="$(jq -c '[.issue, .itemId, .itemStatus, .pr, .project.id, .priority.top]' <<<"$output" 2>/dev/null)"
if [ "$status" -eq 0 ] && [ "$fields" = '[null,null,null,null,"PVT_demo","p-0"]' ] &&
  ! grep -qE 'projectItems|addProjectV2ItemById|pr view' "$FAKE_LOG"; then
  check "(a) no work item, no item lookup or add" ok
else
  printf 'exit %s, output: %s\ncalls:\n%s\n' "$status" "$output" "$(cat "$FAKE_LOG")"
  check "(a) no work item, no item lookup or add" MISMATCH
fi

echo "== (b) --no-item --issue 5"
run_preamble --no-item --issue 5 --project example-org/4
if [ "$status" -eq 2 ]; then check "(b) --no-item with --issue exits 2" ok
else echo "exit $status"; check "(b) --no-item with --issue exits 2" MISMATCH; fi

echo "== (c) no mode flag"
run_preamble --project example-org/4
if [ "$status" -eq 2 ]; then check "(c) no mode flag exits 2" ok
else echo "exit $status"; check "(c) no mode flag exits 2" MISMATCH; fi

echo "== (d) --no-item, no --project, no .claude/spec-sync.json"
run_preamble --no-item
if [ "$status" -eq 6 ]; then check "(d) unresolved project exits 6" ok
else echo "exit $status"; check "(d) unresolved project exits 6" MISMATCH; fi

echo "== (e) --pr 9, no closingIssuesReferences, body 'Closes #42'"
run_preamble --pr 9 --project example-org/4
fields="$(jq -c '[.issue, .pr.number, .pr.base]' <<<"$output" 2>/dev/null)"
if [ "$status" -eq 0 ] && [ "$fields" = '[42,9,"release/M7"]' ]; then
  check "(e) body closing keyword is the issue" ok
else
  printf 'exit %s, output: %s\n' "$status" "$output"
  check "(e) body closing keyword is the issue" MISMATCH
fi

echo
echo "mismatches: $failures"
exit $(( failures > 0 ? 1 : 0 ))
