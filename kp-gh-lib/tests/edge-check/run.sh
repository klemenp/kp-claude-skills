#!/usr/bin/env bash
# Runs edge-check.sh against every <name>.json scenario with --from-file, so no GitHub call
# is made, and checks each key of the scenario's "expected" object against the script's
# JSON. "args" holds the dependent, the blocker and any further flags; "issues" is the
# --from-file graph. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/edge-check.sh"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for fixture in "$here"/*.json; do
  name="$(basename "$fixture" .json)"
  echo "== $name"
  args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(jq -r '.args[]' "$fixture")
  if ! actual="$("$script" --project o/1 "${args[@]}" --from-file "$fixture" 2>&1)"; then
    printf '%s\n' "$actual"
    check "$name" FAILED
    continue
  fi
  # The expected keys only, so a case asserts what it names and nothing else.
  if diff -u <(jq -S .expected "$fixture") \
      <(jq -S --argjson want "$(jq .expected "$fixture")" \
        'with_entries(select(.key as $k | $want | has($k)))' <<<"$actual"); then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
done

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
