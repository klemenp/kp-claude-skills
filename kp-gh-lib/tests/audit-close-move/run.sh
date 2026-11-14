#!/usr/bin/env bash
# Runs audit-close-move.sh with the fake `gh` and the stub find-marker.sh, milestone-of.sh,
# file-audit.sh, milestone-merge.sh and milestone-tag.sh in bin/ (the stubs through
# KP_GH_LIB_BIN), checking
# its stdout, its exit code and the calls it made. Each scenario is written here as JSON
# for the fakes, and every fake appends its argument vector to one call log. Offline, so
# this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/audit-close-move.sh"
failures=0
scenario="$(mktemp)"
call_log="$(mktemp)"
audit_body="$(mktemp)"
trap 'rm -f "$scenario" "$call_log" "$audit_body"' EXIT

ARGS=(--repo o/t --issue 7 --milestone M1 --spec-repo o/spec)
PROJECT=(--project o/1)
DECISION_CLOSE="gh issue close 7 -R o/t --reason completed"

# A find-marker.sh hit for milestone epic o/spec#<n> carrying M<k>.
EPIC='def epic(n; m): {number: n, repo: "o/spec", state: "OPEN", labels: ["type:epic"],
  url: "https://github.com/o/spec/issues/\(n)", value: "milestone:\(m)", where: "body",
  commentId: null};'
BASE_EPICS='[epic(2; "M1"), epic(3; "M2")]'
ONE_ITEM='{"o/be#11": {state: "OPEN", milestone: "M1"}}'

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

expect_eq() {
  local label=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    check "$label" ok
  else
    check "$label" "MISMATCH (want '$want', got '$got')"
  fi
}

# Lines of the call log matching a fixed string.
logged() {
  grep -cF -- "$1" "$call_log"
}

# Line number of the first call-log line starting with a fixed string, or 0.
log_line() {
  awk -v prefix="$1" 'index($0, prefix) == 1 { print NR; found = 1; exit } END { if (!found) print 0 }' "$call_log"
}

# run <label> <audit-close-move.sh args…>, with the scenario already written: sets
# $stdout and $exit_code.
run() {
  echo "== $1"
  shift
  : >"$call_log"
  : >"$audit_body"
  stdout="$(PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_GH_SCENARIO="$scenario" \
    FAKE_CALL_LOG="$call_log" FAKE_AUDIT_BODY="$audit_body" "$script" "$@" 2>/dev/null)"
  exit_code=$?
}

field() {
  jq -c "$1" <<<"$stdout"
}

# (a) The next epic is the lowest milestone above M<k>, numerically, ties by number.
jq -n "$EPIC {epics: [epic(1; \"M0\"), epic(2; \"M1\"), epic(4; \"M10\"), epic(7; \"M2\"),
  epic(3; \"M2\")], items: $ONE_ITEM}" >"$scenario"
run next-epic "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
expect_eq "next-epic exit" 0 "$exit_code"
expect_eq "next-epic target" '"M2"' "$(field .target)"
expect_eq "next-epic epic" '"o/spec#3"' "$(field .epic)"
expect_eq "next-epic parent node" 1 "$(logged '-f p=node-o/spec#3')"

# (b) No epic above M<k>: {"target": null}, nothing written.
jq -n "$EPIC {epics: [epic(1; \"M0\"), epic(2; \"M1\")], items: $ONE_ITEM}" >"$scenario"
run no-later-milestone "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
expect_eq "no-later-milestone exit" 0 "$exit_code"
expect_eq "no-later-milestone stdout" '{"target": null}' "$stdout"
expect_eq "no-later-milestone calls" "find-marker.sh o/spec spec-ref --any-value --scope owner --label type:epic" \
  "$(cat "$call_log")"

# (c) Open in M1 → moved, already in M2 → already, closed → skipped; one re-parent.
jq -n "$EPIC {epics: $BASE_EPICS, items: {
  \"o/be#11\": {state: \"OPEN\", milestone: \"M1\"},
  \"o/be#12\": {state: \"OPEN\", milestone: \"M2\"},
  \"o/be#13\": {state: \"CLOSED\", milestone: \"M1\"}}}" >"$scenario"
run three-items "${ARGS[@]}" --item o/be#11 --item o/be#12 --item o/be#13 "${PROJECT[@]}"
expect_eq "three-items exit" 0 "$exit_code"
expect_eq "three-items moved" '["o/be#11"]' "$(field .moved)"
expect_eq "three-items already" '["o/be#12"]' "$(field .already)"
expect_eq "three-items skipped" '[{"item":"o/be#13","reason":"closed"}]' "$(field .skipped)"
expect_eq "three-items addSubIssue calls" 1 "$(logged addSubIssue)"
expect_eq "three-items replaceParent" 1 "$(logged 'replaceParent:true')"
expect_eq "three-items child node" 1 "$(logged '-f c=node-o/be#11')"
expect_eq "three-items audit body" "M1 accepted by the operator with these findings moved to M2: o/be#11, o/be#12." \
  "$(tail -n 1 "$audit_body")"
expect_eq "three-items open audit closed" 1 "$(logged 'gh issue close 50 -R o/t')"
expect_eq "three-items resolved comment posted" 1 "$(logged 'gh api -X POST repos/o/t/issues/7/comments')"
expect_eq "three-items decision closed" 1 "$(logged "$DECISION_CLOSE")"
expect_eq "three-items output" \
  '{"target":"M2","epic":"o/spec#3","moved":["o/be#11"],"already":["o/be#12"],"skipped":[{"item":"o/be#13","reason":"closed"}],"audit":{"number":50,"url":"https://github.com/o/t/issues/50","reused":false},"decisionClosed":true,"merge":["no-branch o/t"],"mergeExit":0,"tag":["tagged o/t milestone/M1 head"],"tagExit":0}' \
  "$(field .)"

# (d) A reused, already-closed audit is not closed again.
jq -n "$EPIC {epics: $BASE_EPICS, items: $ONE_ITEM,
  audit: {number: 50, url: \"https://github.com/o/t/issues/50\", reused: true},
  issueState: {\"o/t#50\": \"closed\"}}" >"$scenario"
run reused-audit "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
expect_eq "reused-audit exit" 0 "$exit_code"
expect_eq "reused-audit reused" true "$(field .audit.reused)"
expect_eq "reused-audit no close" 0 "$(logged 'gh issue close 50 ')"

# (e) A decision already carrying a `Resolved → ` comment gets no second one, but closes.
jq -n "$EPIC {epics: $BASE_EPICS, items: $ONE_ITEM,
  comments: [\"Decision: B\", \"Resolved → no spec change: audit-close. Decision: B\"]}" >"$scenario"
run already-resolved "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
expect_eq "already-resolved exit" 0 "$exit_code"
expect_eq "already-resolved no comment" 0 "$(logged 'gh api -X POST')"
expect_eq "already-resolved decision closed" 1 "$(logged "$DECISION_CLOSE")"

# (f) No --project: no merge or tag call, merge, mergeExit, tag and tagExit all null.
jq -n "$EPIC {epics: $BASE_EPICS, items: $ONE_ITEM}" >"$scenario"
run no-project "${ARGS[@]}" --item o/be#11
expect_eq "no-project exit" 0 "$exit_code"
expect_eq "no-project merge and tag" 'null null null null' \
  "$(field .merge) $(field .mergeExit) $(field .tag) $(field .tagExit)"
expect_eq "no-project no merge call" 0 "$(logged milestone-merge.sh)"
expect_eq "no-project no tag call" 0 "$(logged milestone-tag.sh)"

# (g) A failing milestone-tag.sh is recorded, never fatal.
jq -n "$EPIC {epics: $BASE_EPICS, items: $ONE_ITEM, tagLines: [\"failed o/t: boom\"], tagExit: 1}" >"$scenario"
run tag-fails "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
expect_eq "tag-fails exit" 0 "$exit_code"
expect_eq "tag-fails tagExit" 1 "$(field .tagExit)"
expect_eq "tag-fails tag" '["failed o/t: boom"]' "$(field .tag)"

# (h) The decision closes before the milestone is tagged.
jq -n "$EPIC {epics: $BASE_EPICS, items: $ONE_ITEM}" >"$scenario"
run close-before-tag "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
close_line=$(log_line "$DECISION_CLOSE")
tag_line=$(log_line "milestone-tag.sh --project o/1 M1")
if [ "$close_line" -gt 0 ] && [ "$tag_line" -gt "$close_line" ]; then
  check "close-before-tag order" ok
else
  check "close-before-tag order" "MISMATCH (close at $close_line, tag at $tag_line)"
fi

# (h2) The merge runs after the close and before the tag, and both results are reported.
jq -n "$EPIC {epics: $BASE_EPICS, items: $ONE_ITEM, mergeLines: [\"merged o/t 9 sha-t\"]}" >"$scenario"
run merge-then-tag "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
merge_line=$(log_line "milestone-merge.sh --project o/1 M1")
tag_line=$(log_line "milestone-tag.sh --project o/1 M1")
close_line=$(log_line "$DECISION_CLOSE")
if [ "$close_line" -gt 0 ] && [ "$merge_line" -gt "$close_line" ] && [ "$tag_line" -gt "$merge_line" ]; then
  check "merge-then-tag order" ok
else
  check "merge-then-tag order" "MISMATCH (close at $close_line, merge at $merge_line, tag at $tag_line)"
fi
expect_eq "merge-then-tag exit" 0 "$exit_code"
expect_eq "merge-then-tag merge" '["merged o/t 9 sha-t"] 0' "$(field .merge) $(field .mergeExit)"
expect_eq "merge-then-tag tag" '["tagged o/t milestone/M1 head"] 0' "$(field .tag) $(field .tagExit)"

# (h3) A failing merge skips the tag: tag "skipped", tagExit null, no tag call; never fatal.
jq -n "$EPIC {epics: $BASE_EPICS, items: $ONE_ITEM,
  mergeLines: [\"conflict o/t: gh: Merge conflict (HTTP 409)\"], mergeExit: 1}" >"$scenario"
run merge-fails "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
expect_eq "merge-fails exit" 0 "$exit_code"
expect_eq "merge-fails merge" '["conflict o/t: gh: Merge conflict (HTTP 409)"] 1' \
  "$(field .merge) $(field .mergeExit)"
expect_eq "merge-fails tag" '"skipped" null' "$(field .tag) $(field .tagExit)"
expect_eq "merge-fails no tag call" 0 "$(logged milestone-tag.sh)"

# (i) A failed find-marker.sh stops the run: exit 1, no JSON.
jq -n '{findMarkerFails: true}' >"$scenario"
run find-marker-fails "${ARGS[@]}" --item o/be#11 "${PROJECT[@]}"
expect_eq "find-marker-fails exit" 1 "$exit_code"
expect_eq "find-marker-fails stdout" "" "$stdout"

# (j) No --item: exit 2 before any call.
jq -n "$EPIC {epics: $BASE_EPICS}" >"$scenario"
run no-item "${ARGS[@]}" "${PROJECT[@]}"
expect_eq "no-item exit" 2 "$exit_code"
expect_eq "no-item calls" "" "$(cat "$call_log")"

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
