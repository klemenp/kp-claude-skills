#!/usr/bin/env bash
# Feeds every <name>.json fixture through pr-verdict-state.sh --from-file and diffs the
# result against the hand-written <name>.expected.json. Then checks --history on the
# multi-round fixture and --reviews on every fixture with a <name>.reviews.expected.json.
# Offline: the fixtures stand in for the GitHub reads, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/pr-verdict-state.sh"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for fixture in "$here"/*.json; do
  case "$fixture" in *.expected.json) continue ;; esac
  name="$(basename "$fixture" .json)"
  expected="$here/$name.expected.json"
  echo "== $name"
  if ! actual="$("$script" --from-file "$fixture" 2>&1)"; then
    printf '%s\n' "$actual"
    check "$name" MISMATCH
    continue
  fi
  if diff -u <(jq -S . "$expected") <(jq -S . <<<"$actual"); then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
done

# --reviews: a fixture with a <name>.reviews.expected.json is also diffed with the flag.
for expected in "$here"/*.reviews.expected.json; do
  [ -e "$expected" ] || continue
  name="$(basename "$expected" .reviews.expected.json)"
  echo "== $name --reviews"
  if ! actual="$("$script" --from-file "$here/$name.json" --reviews 2>&1)"; then
    printf '%s\n' "$actual"
    check "$name --reviews" MISMATCH
    continue
  fi
  if diff -u <(jq -S . "$expected") <(jq -S . <<<"$actual"); then
    check "$name --reviews" ok
  else
    check "$name --reviews" MISMATCH
  fi
done

# A fixture with no "reviews" key reads as no formal reviews: `latest` is the verdict
# comment itself.
echo "== one-approval --reviews (no reviews key)"
no_reviews="$("$script" --from-file "$here/one-approval.json" --reviews \
  | jq -c '[.latest.channel, .latest.id == .verdict.id, .latest.verdict == .verdict.verdict]')"
echo "latest: $no_reviews"
if [ "$no_reviews" = '["comment",true,true]' ]; then
  check "missing reviews key reads as comment" ok
else
  check "missing reviews key reads as comment" MISMATCH
fi

# --history: every round, oldest first, so kp-review-gh-pr can apply its
# do-not-re-raise rule without paging comments itself.
echo "== denial-fix-denial --history"
history="$("$script" --from-file "$here/denial-fix-denial.json" --history)"
order="$(jq -r '[.history[] | "\(.id):\(.kind)"] | join(",")' <<<"$history")"
echo "history: $order"
if [ "$order" = "11:verdict,12:fixSummary,13:verdict" ]; then
  check "history order" ok
else
  check "history order" MISMATCH
fi

# An approval carries no findings section; a denial in history carries its own.
echo "== one-approval --history"
approval_findings="$("$script" --from-file "$here/one-approval.json" --history \
  | jq -r '.history[0].findings')"
echo "findings: $approval_findings"
if [ "$approval_findings" = null ]; then
  check "approval has no findings" ok
else
  check "approval has no findings" MISMATCH
fi

# Bad arguments are exit 2, distinct from a GitHub failure.
status=0
"$script" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
  check "no args exits 2" ok
else
  check "no args exits 2" MISMATCH
fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
