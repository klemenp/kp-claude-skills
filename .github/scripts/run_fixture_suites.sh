#!/usr/bin/env bash
# Run every fixture suite in the repository: each `<skill>/tests/<name>/run.sh` under the
# repository root, in sorted order. CI and a local run use this same script, so a new
# suite needs no entry in the workflow or in CLAUDE.md.
#
# Usage: run_fixture_suites.sh        (no arguments; works from any directory)
#
# Every suite runs to completion even after an earlier one fails. Per suite: a start
# line, the suite's own output, then `-> <suite>: ok` or `-> <suite>: FAILED (exit <n>)`.
# Under GitHub Actions each suite's output is folded into a log group. A run.sh that is
# not executable is a failed suite. The last lines are `<n> suites run, <m> failed` and
# the failed suites, one per line.
#
# Exit: 0 every suite passed · 1 a suite failed, or no suite was found.
set -uo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root" || exit 1

shopt -s nullglob
suites=(*/tests/*/run.sh)
if [ ${#suites[@]} -eq 0 ]; then
  echo "run_fixture_suites.sh: no */tests/*/run.sh under $repo_root" >&2
  exit 1
fi

in_actions=false
[ "${GITHUB_ACTIONS:-}" = true ] && in_actions=true
failed=()

for suite in "${suites[@]}"; do
  if "$in_actions"; then echo "::group::$suite"; else echo "== $suite"; fi
  if [ -x "$suite" ]; then
    "./$suite"
    status=$?
    result="FAILED (exit $status)"
  else
    status=1
    result="FAILED (not executable)"
  fi
  "$in_actions" && echo "::endgroup::"
  if [ "$status" -eq 0 ]; then
    echo "-> $suite: ok"
  else
    echo "-> $suite: $result"
    failed+=("$suite")
  fi
done

echo
echo "${#suites[@]} suites run, ${#failed[@]} failed"
if [ ${#failed[@]} -gt 0 ]; then
  printf '%s\n' "${failed[@]}"
  exit 1
fi
