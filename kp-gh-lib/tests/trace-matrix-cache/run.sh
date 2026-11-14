#!/usr/bin/env bash
# Runs trace-matrix.sh against the `gh` stub in bin/, which answers from a temp copy of
# case/, and checks its merged-PR files cache: a warm run prints what a cold run printed
# without a `pulls/<n>/files` call, a newly merged PR is fetched and cached, and a corrupt
# cache file is ignored and rewritten. Then, each from a fresh copy of case/ and an empty
# cache, the milestone-branch read: `--ref` and `--milestone` pick the branch whose SHA
# and tree are read, a missing branch falls back to the default one, and a merged
# `release/*`-headed PR is skipped. The scripts run from a temp copy of
# kp-gh-lib/scripts/, so both their caches land in the temp directory, never in this
# repo's kp-gh-lib/state/. Offline — no real `gh`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH"
export TRACE_MATRIX_CASE="$work/case"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

mkdir -p "$work/kp-gh-lib"
cp -R "$repo_root/kp-gh-lib/scripts" "$work/kp-gh-lib/scripts"
cp -R "$here/case" "$TRACE_MATRIX_CASE"
script="$work/kp-gh-lib/scripts/trace-matrix.sh"
cache="$work/kp-gh-lib/state/trace-cache/fx/code.json"
pulls_list="$TRACE_MATRIX_CASE/repos_fx_code_pulls_state_closed_per_page_100"

spec="$work/spec"
mkdir -p "$spec/.claude"
git -C "$spec" init -q
git -C "$spec" remote add origin https://github.com/fx/spec.git
echo '{"targetRepo": "fx/code"}' >"$spec/.claude/spec-sync.json"
printf '# Spec\n\n**REQ-CORE-001 — Store a widget**\n\nServes: G-1\n' >"$spec/spec.md"

# run <n> [args…]: one trace from the spec checkout, its calls in calls-<n>, stdout in
# out-<n>.
run() {
  local n=$1
  shift
  : >"$TRACE_MATRIX_CASE/calls.log"
  (cd "$spec" && "$script" fx/spec "$@" >"$work/out-$n" 2>"$work/err-$n")
  local status=$?
  cp "$TRACE_MATRIX_CASE/calls.log" "$work/calls-$n"
  echo "== run $n: exit $status"
  [ "$status" -eq 0 ] || { cat "$work/err-$n"; return 1; }
}

# fresh_case: a new copy of case/ and no trace cache, so a case sees no earlier run.
fresh_case() {
  rm -rf "$TRACE_MATRIX_CASE" "$work/kp-gh-lib/state"
  cp -R "$here/case" "$TRACE_MATRIX_CASE"
}

# out_is <n> <jq-expression>: run <n>'s stdout makes the expression true.
out_is() {
  jq -e "$2" "$work/out-$1" >/dev/null || { echo "not true of out-$1: $2"; return 1; }
}

# called <n> <endpoint>: run <n> requested exactly that endpoint.
called() {
  grep -qxF "$2" "$work/calls-$1" || { echo "not called in run $1: $2"; return 1; }
}

files_calls() {
  grep -cE 'pulls/[0-9]+/files' "$work/calls-$1"
}

# cache_has <pr> <filename>: the cache file is a valid version-1 cache listing it.
cache_has() {
  python3 - "$cache" "$1" "$2" <<'PY'
import json, sys
cache = json.load(open(sys.argv[1]))
sys.exit(0 if cache.get("version") == 1 and sys.argv[3] in cache["prs"].get(sys.argv[2], [])
         else 1)
PY
}

if run 1 && run 2 && cmp -s "$work/out-1" "$work/out-2"; then
  check same-output ok
else
  check same-output MISMATCH
fi

if [ -s "$work/calls-2" ] && [ "$(files_calls 1)" -gt 0 ] && [ "$(files_calls 2)" -eq 0 ]; then
  check no-files-refetch ok
else
  echo "run 1 files calls: $(files_calls 1); run 2 files calls: $(files_calls 2)"
  check no-files-refetch MISMATCH
fi

cp "$TRACE_MATRIX_CASE/pulls-with-pr-11.json" "$pulls_list"
if run 3 && grep -q 'pulls/11/files' "$work/calls-3" && cache_has 11 src/b.py; then
  check new-pr-cached ok
else
  check new-pr-cached MISMATCH
fi

echo 'not json' >"$cache"
if run 4 && cmp -s "$work/out-3" "$work/out-4" && cache_has 11 src/b.py; then
  check corrupt-cache-rewritten ok
else
  check corrupt-cache-rewritten MISMATCH
fi

release_sha=dddddddddddddddddddddddddddddddddddddddd
main_sha=cccccccccccccccccccccccccccccccccccccccc
spec_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

fresh_case
if run ref-sha --all --ref release/M1 \
  && out_is ref-sha ".shas[\"fx/code\"] == \"$release_sha\" and .spec.sha == \"$spec_sha\"
    and .refs == {\"fx/code\": \"release/M1\"}" \
  && called ref-sha "repos/fx/code/git/trees/$release_sha?recursive=1"; then
  check "ref branch sha" ok
else
  check "ref branch sha" MISMATCH
fi

fresh_case
mv "$TRACE_MATRIX_CASE/repos_fx_code_branches_release_M1" \
  "$TRACE_MATRIX_CASE/repos_fx_code_branches_release_M1.404"
if run ref-missing --all --ref release/M1 \
  && called ref-missing "repos/fx/code/branches/release/M1" \
  && out_is ref-missing ".shas[\"fx/code\"] == \"$main_sha\" and .refs == {\"fx/code\": \"main\"}"; then
  check "ref branch missing" ok
else
  check "ref branch missing" MISMATCH
fi

fresh_case
: >"$TRACE_MATRIX_CASE/calls.log"
(cd "$spec" && "$script" fx/spec --ref 'bad..ref' >/dev/null 2>&1)
status=$?
if [ "$status" -eq 2 ] && [ ! -s "$TRACE_MATRIX_CASE/calls.log" ]; then
  check "invalid ref" ok
else
  echo "exit $status"
  check "invalid ref" MISMATCH
fi

fresh_case
if run explicit-ref --milestone M1 --ref release/M2 \
  && called explicit-ref "repos/fx/code/branches/release/M2" \
  && ! grep -q 'branches/release/M1' "$work/calls-explicit-ref"; then
  check "explicit ref wins" ok
else
  check "explicit ref wins" MISMATCH
fi

fresh_case
if run milestone-ref --milestone M1 \
  && called milestone-ref "repos/fx/code/branches/release/M1" \
  && out_is milestone-ref ".refs == {\"fx/code\": \"release/M1\"}"; then
  check "milestone implies ref" ok
else
  check "milestone implies ref" MISMATCH
fi

fresh_case
cp "$TRACE_MATRIX_CASE/pulls-with-release-pr.json" "$pulls_list"
if run release-pr \
  && ! grep -q 'pulls/12/files' "$work/calls-release-pr" \
  && ! cache_has 12 src/b.py \
  && out_is release-pr '[.covered[].items[].prs[]] == ["fx/code#10"] and .untraced["fx/code"] == []'; then
  check "release-headed PR skipped" ok
else
  check "release-headed PR skipped" MISMATCH
fi

# Two routed repos: fx/code's merged PR closes an issue before fx/other's branch is read.
other_sha=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
fresh_case
echo '{"targetRepo": "fx/code", "requirementRepos": {"OTHER": {"repo": "fx/other"}}}' \
  >"$spec/.claude/spec-sync.json"
if run ref-all --all --ref release/M1 \
  && out_is ref-all ".refs == {\"fx/code\": \"release/M1\", \"fx/other\": \"release/M1\"}
    and .shas[\"fx/other\"] == \"$other_sha\"" \
  && called ref-all "repos/fx/other/branches/release/M1" \
  && ! grep -q '#' "$work/calls-ref-all"; then
  check "ref read in every routed repo" ok
else
  check "ref read in every routed repo" MISMATCH
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all trace-matrix-cache checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
