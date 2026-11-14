#!/usr/bin/env bash
# Drives comment-once.sh against the fake gh in bin/, which serves a comment list from a
# state file and logs every call: a post on an empty list, an exists on a marked comment,
# a post past a different marker, the oldest of two matches, labels on the exists path,
# four argument errors that call nothing (a body without the marker, a lone --add-label, an empty
# --add-label, a non-ASCII digit <n>), and a failed comment read. Offline — no GitHub —
# so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/comment-once.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" FAKE_STATE="$work"
failures=0
marker='<!-- kp-do-gh-task:needs-contract -->'
body="$work/body.md"
printf '%s\nThe body fails the contract.\n' "$marker" > "$body"

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

# seed <comments JSON array> — resets the comment list and the call log
seed() {
  printf '%s\n' "$1" > "$work/comments.json"
  : > "$work/calls.log"
}

calls() { grep -c -F -e "$1" "$work/calls.log"; }

# once <args…> — runs the script, leaving "<exit>:<stdout>" in $outcome
once() {
  local output status=0
  output="$("$script" "$@" 2>/dev/null)" || status=$?
  outcome="$status:$output"
}

echo "== no comments → posted"
seed '[]'
once example-org/demo 7 --marker "$marker" --body-file "$body"
expect "prints posted with the new id" "$outcome" "0:posted 1001"
expect "one POST logged" "$(calls '-X POST')" 1
expect "the posted comment carries the body" \
  "$(jq -r '.[0].body' "$work/comments.json")" "$(cat "$body")"

echo "== a comment carries the marker → exists"
seed "$(jq -n --arg m "$marker" '[{id: 41, body: "unrelated"}, {id: 42, body: ("text\n" + $m + "\nmore")}]')"
once example-org/demo 7 --marker "$marker" --body-file "$body"
expect "prints exists with its id" "$outcome" "0:exists 42"
expect "no POST logged" "$(calls '-X POST')" 0

echo "== a different marker → posted"
pins_body="$work/pins.md"
printf '%s\nPins refreshed.\n' '<!-- kp-sync-spec-tasks:pins bbb -->' > "$pins_body"
seed '[{"id": 50, "body": "<!-- kp-sync-spec-tasks:pins aaa -->\nPins refreshed."}]'
once example-org/demo 7 --marker '<!-- kp-sync-spec-tasks:pins bbb -->' --body-file "$pins_body"
expect "prints posted" "$outcome" "0:posted 51"
expect "one POST logged" "$(calls '-X POST')" 1

echo "== two matches → the older id"
seed "$(jq -n --arg m "$marker" '[{id: 60, body: $m}, {id: 61, body: $m}]')"
once example-org/demo 7 --marker "$marker" --body-file "$body"
expect "prints exists with the older id" "$outcome" "0:exists 60"

echo "== --add-label on the exists path"
seed "$(jq -n --arg m "$marker" '[{id: 70, body: $m}]')"
once example-org/demo 7 --marker "$marker" --body-file "$body" \
  --add-label needs-contract --label-color D93F0B
expect "prints exists" "$outcome" "0:exists 70"
expect "label create logged" "$(calls 'label create needs-contract -R example-org/demo --color D93F0B --force')" 1
expect "label add logged" "$(calls 'issue edit 7 -R example-org/demo --add-label needs-contract')" 1
expect "no POST logged" "$(calls '-X POST')" 0

echo "== a body file without the marker → exit 2"
seed '[]'
printf 'No marker here.\n' > "$work/plain.md"
once example-org/demo 7 --marker "$marker" --body-file "$work/plain.md"
expect "exits 2" "${outcome%%:*}" 2
expect "no gh call logged" "$(wc -l < "$work/calls.log" | tr -d ' ')" 0

echo "== --add-label without --label-color → exit 2"
seed '[]'
once example-org/demo 7 --marker "$marker" --body-file "$body" --add-label needs-contract
expect "exits 2" "${outcome%%:*}" 2
expect "no gh call logged" "$(wc -l < "$work/calls.log" | tr -d ' ')" 0

echo "== an empty --add-label → exit 2"
seed '[]'
once example-org/demo 7 --marker "$marker" --body-file "$body" --add-label '' --label-color D93F0B
expect "exits 2" "${outcome%%:*}" 2
expect "no gh call logged" "$(wc -l < "$work/calls.log" | tr -d ' ')" 0

echo "== a non-ASCII digit <n> → exit 2"
seed '[]'
once example-org/demo '²' --marker "$marker" --body-file "$body"
expect "exits 2" "${outcome%%:*}" 2
expect "no gh call logged" "$(wc -l < "$work/calls.log" | tr -d ' ')" 0

echo "== the comment read fails → exit 1"
seed '[]'
export FAKE_READ_FAIL=1
once example-org/demo 7 --marker "$marker" --body-file "$body"
unset FAKE_READ_FAIL
expect "exits 1 with empty stdout" "$outcome" "1:"
expect "no POST logged" "$(calls '-X POST')" 0

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
