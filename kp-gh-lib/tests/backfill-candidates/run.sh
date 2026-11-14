#!/usr/bin/env bash
# Drives backfill-candidates.sh against the fakes in bin/ (gh, and item-id.sh found through
# KP_GH_LIB_BIN), which serve the issue listing, comments and board statuses from a state
# dir and log every call: the skip rules, the failed-at-SHA match, --labelled, sorting, an
# empty listing, bad arguments and a failing lookup. Offline — no GitHub — so this runs
# in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/backfill-candidates.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_STATE="$work"
failures=0
sha=abc1234def
other_sha=0123456
args=(--repo example-org/demo --project-id PVT_demo --sha "$sha")

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# expect <label> <actual> <expected>
expect() {
  if [ "$2" = "$3" ]; then
    check "$1" ok
  else
    printf 'expected: %s\nactual:   %s\n' "$3" "$2"
    check "$1" MISMATCH
  fi
}

reset_state() {
  rm -f "$work"/*
  : > "$work/gh.log"
  : > "$work/item-id.log"
}

# issue <number> <label>… — one listed issue
issue() {
  local number=$1
  shift
  jq -cn --argjson number "$number" --args \
    '{number: $number, title: "Item \($number)", body: "Body \($number)",
      labels: [$ARGS.positional[] | {name: .}]}' "$@"
}

# seed <issue json>… — the listing, in the order given
seed() { printf '%s\n' "$@" | jq -s . > "$work/issues.json"; }

# failed_comment <number> <sha> — a comment holding the backfill-failed line for <sha>
failed_comment() {
  jq -cn --arg body "  <!-- kp-sync-spec-tasks:backfill-failed $2 -->
Settled answers and open gaps." '[{id: 1, body: "An unrelated comment."}, {id: 2, body: $body}]' \
    > "$work/comments-$1.json"
}

entry() { jq -c --argjson number "$1" "map(select(.number == \$number))[0] | $2" <<<"$output"; }
looked_up() { grep -c "^example-org/demo $1 PVT_demo$" "$work/item-id.log"; }
comments_read() { grep -c "issues/$1/comments" "$work/gh.log"; }

echo "== statuses and the failed-at-SHA skip"
reset_state
seed "$(issue 8 type:coding needs-contract)" "$(issue 5 type:coding)" "$(issue 3 type:coding)" \
  "$(issue 7 type:coding needs-contract)" "$(issue 2 type:coding)" "$(issue 4 type:coding)"
echo Ready > "$work/status-5"
echo "In progress" > "$work/status-3"
echo "In review" > "$work/status-4"
echo Ready > "$work/status-8"
echo Ready > "$work/status-7"
failed_comment 7 "$sha"
failed_comment 8 "$other_sha"
output="$("$script" "${args[@]}")"
expect "exits 0" "$?" 0
expect "sorted by number" "$(jq -c 'map(.number)' <<<"$output")" '[2,3,4,5,7,8]'
expect "a Ready item is a candidate" "$(entry 5 '[.status, .skip, .failedAtSha]')" '["Ready",null,false]'
expect "an In progress item is skipped" "$(entry 3 '[.status, .skip]')" '["In progress","in-progress"]'
expect "an In review item is skipped" "$(entry 4 '[.status, .skip]')" '["In review","in-progress"]'
expect "an item not on the board is a candidate" "$(entry 2 '[.status, .skip]')" '[null,null]'
expect "a failure at this SHA is unchanged-failure" "$(entry 7 '[.status, .failedAtSha, .skip]')" \
  '[null,true,"unchanged-failure"]'
expect "an unchanged-failure item is never looked up" "$(looked_up 7)" 0
expect "a failure at another SHA is looked up" "$(entry 8 '[.status, .failedAtSha, .skip]')" \
  '["Ready",false,null]'
expect "the other-SHA item had one lookup" "$(looked_up 8)" 1
expect "no comments read for an unlabelled item" "$(comments_read 5)" 0
expect "the output carries title, body and label names" \
  "$(entry 8 '[.title, .body, .labels]')" '["Item 8","Body 8",["type:coding","needs-contract"]]'
expect "the type:coding listing query" "$(grep -c -- '^issue list -R example-org/demo --state open --label type:coding --limit 1000 --json number,title,body,labels$' "$work/gh.log")" 1

echo "== --labelled"
reset_state
seed "$(issue 7 type:coding needs-contract)"
echo Ready > "$work/status-7"
failed_comment 7 "$sha"
output="$("$script" "${args[@]}" --labelled)"
expect "exits 0" "$?" 0
expect "failedAtSha is reported but sets no skip" "$(entry 7 '[.status, .failedAtSha, .skip]')" \
  '["Ready",true,null]'
expect "the matching-SHA item is looked up" "$(looked_up 7)" 1
listing="$(grep '^issue list' "$work/gh.log")"
expect "the listing narrows to needs-contract" \
  "$(grep -c -- '--label needs-contract' <<<"$listing"):$(grep -c -- '--label type:coding' <<<"$listing")" "1:0"

echo "== an empty listing"
reset_state
seed
output="$("$script" "${args[@]}")"
expect "prints [] and exits 0" "$?:$output" "0:[]"

echo "== missing --sha"
reset_state
"$script" --repo example-org/demo --project-id PVT_demo > /dev/null 2>&1
expect "exits 2" "$?" 2
expect "no gh call made" "$(wc -l < "$work/gh.log" | tr -d ' ')" 0

echo "== a failing item-id.sh"
reset_state
seed "$(issue 5 type:coding)"
output="$(FAKE_ITEM_ID_FAIL=1 "$script" "${args[@]}" 2>/dev/null)"
expect "exits 1 with nothing on stdout" "$?:$output" "1:"

if [ "$failures" -eq 0 ]; then
  echo "all backfill-candidates checks passed"
else
  echo "$failures backfill-candidates check(s) failed"
  exit 1
fi
