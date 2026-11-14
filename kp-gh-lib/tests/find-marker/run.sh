#!/usr/bin/env bash
# Feeds every <name>.json fixture through find-marker.sh --from-file, with the arguments
# in its "args" array, and diffs the result against the hand-written
# <name>.expected.json. Offline: the fixtures stand in for the search and reads, so this
# runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/find-marker.sh"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for fixture in "$here"/*.json; do
  case "$fixture" in *.expected.json) continue ;; esac
  name="$(basename "$fixture" .json)"
  echo "== $name"
  args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(jq -r '.args[]' "$fixture")
  if ! actual="$("$script" "${args[@]}" --from-file "$fixture" 2>&1)"; then
    printf '%s\n' "$actual"
    check "$name" MISMATCH
    continue
  fi
  if diff -u <(jq -S . "$here/$name.expected.json") <(jq -S . <<<"$actual"); then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
done

# Bad arguments are exit 2, distinct from a GitHub failure.
status=0
"$script" example-org/demo spec-ref >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
  check "missing value exits 2" ok
else
  check "missing value exits 2" MISMATCH
fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
