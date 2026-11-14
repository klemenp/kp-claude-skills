#!/usr/bin/env bash
# Runs milestone-place.sh against every <name>.json scenario with milestone-gate's fake
# `gh` first on PATH, and diffs its JSON against the hand-written <name>.expected.json.
# A scenario is a fake-gh scenario plus `args` (the arguments after --project and
# --cache) and, optionally, `cache` (written to the --cache file before the run, so no
# search may be made). Each run must leave a --current result in the cache file. The
# j-* checks cover bad arguments and failed lookups. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/milestone-place.sh"
fake_bin="$repo_root/kp-gh-lib/tests/milestone-gate/bin"
failures=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
search_log="$work/searches"
cache="$work/cache.json"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

run_place() {
  PATH="$fake_bin:$PATH" FAKE_GH_SEARCH_LOG="$search_log" "$script" "$@"
}

for fixture in "$here"/*.json; do
  case "$fixture" in *.expected.json) continue ;; esac
  name="$(basename "$fixture" .json)"
  echo "== $name"
  : >"$search_log"
  rm -f "$cache"
  if jq -e 'has("cache")' "$fixture" >/dev/null; then
    jq '.cache' "$fixture" >"$cache"
  fi
  args=()
  while IFS= read -r arg; do args+=("$arg"); done < <(jq -r '.args[]' "$fixture")
  if ! actual="$(FAKE_GH_SCENARIO="$fixture" run_place --project o/1 --cache "$cache" "${args[@]}" 2>&1)"; then
    printf '%s\n' "$actual"
    check "$name" MISMATCH
    continue
  fi
  if diff -u <(jq -S . "$here/$name.expected.json") <(jq -S . <<<"$actual"); then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
  if jq -e '.epics | type == "array"' "$cache" >/dev/null 2>&1; then
    check "$name cache" ok
  else
    check "$name cache" "no --current result in the cache file"
  fi
  if jq -e 'has("cache")' "$fixture" >/dev/null; then
    searches="$(wc -l <"$search_log" | tr -d ' ')"
    if [ "$searches" -eq 0 ]; then
      check "$name searches" ok
    else
      check "$name searches" "$searches searches, want 0 with a cache file"
    fi
  fi
done

# Bad arguments and failed lookups. Their scenarios are made here, never stored as
# *.json, since the loop above treats every *.json as a success scenario.
expect_failure() {
  local label=$1 want_exit=$2 want_stderr=$3
  shift 3
  local stderr exit_code
  echo "== $label"
  stderr="$(run_place "$@" 2>&1 >/dev/null)"
  exit_code=$?
  if [ "$exit_code" -eq "$want_exit" ] && [[ $stderr == *"$want_stderr"* ]]; then
    check "$label" ok
  else
    printf '%s\n' "$stderr"
    check "$label" "exit $exit_code, want $want_exit with stderr containing '$want_stderr'"
  fi
}

export FAKE_GH_SCENARIO="$here/b-epic-in-repo.json"
rm -f "$cache"
expect_failure j-missing-project 2 usage --repo o/be --cache "$cache"
expect_failure j-missing-repo 2 usage --project o/1 --cache "$cache"
expect_failure j-missing-cache 2 usage --project o/1 --repo o/be
expect_failure j-malformed-project 2 usage --project foo --repo o/be --cache "$cache"
expect_failure j-malformed-origin 2 usage --project o/1 --repo o/be --cache "$cache" --origin o/be-40
expect_failure j-malformed-parent 2 usage --project o/1 --repo o/be --cache "$cache" --parent 42
expect_failure j-missing-value 2 usage --project o/1 --repo o/be --cache
expect_failure j-unknown-option 2 usage --project o/1 --repo o/be --cache "$cache" --epic o/be#3

# Bad arguments are rejected before the cache is touched.
if [ -e "$cache" ]; then
  check j-bad-arguments-no-cache "a bad-argument run wrote the cache file"
else
  check j-bad-arguments-no-cache ok
fi

jq '.issues = {"o/be#40": {"fail": true}}' "$here/b-epic-in-repo.json" >"$work/origin-fails.json"
FAKE_GH_SCENARIO="$work/origin-fails.json" \
  expect_failure j-origin-lookup-fails 1 "lookup of o/be#40 failed" \
  --project o/1 --repo o/be --cache "$cache" --origin o/be#40

rm -f "$cache"
jq '.projectRepos = []' "$here/b-epic-in-repo.json" >"$work/no-linked-repos.json"
FAKE_GH_SCENARIO="$work/no-linked-repos.json" \
  expect_failure j-current-lookup-fails 1 o/1 --project o/1 --repo o/be --cache "$cache"
if [ -e "$cache" ]; then
  check j-current-lookup-fails-no-cache "a failed --current lookup wrote the cache file"
else
  check j-current-lookup-fails-no-cache ok
fi

for bad_cache in empty not-current; do
  case "$bad_cache" in
    empty) : >"$cache" ;;
    not-current) echo '{"milestone": "M2"}' >"$cache" ;;
  esac
  before="$(cat "$cache")"
  expect_failure "j-cache-$bad_cache" 1 "--cache" --project o/1 --repo o/be --cache "$cache"
  if [ "$(cat "$cache")" = "$before" ]; then
    check "j-cache-$bad_cache left as is" ok
  else
    check "j-cache-$bad_cache left as is" "the cache file was rewritten"
  fi
done

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
