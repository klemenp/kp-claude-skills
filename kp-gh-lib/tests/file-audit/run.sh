#!/usr/bin/env bash
# Drives file-audit.sh against the fakes in bin/ (gh plus the sibling scripts, found
# through KP_GH_LIB_BIN): each case sets its arguments and the FAKE_* knobs that steer the
# fakes, then checks the exit code, the calls made, in order, and the printed JSON.
# Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/file-audit.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin" FAKE_LOG="$work/calls.log" \
  FAKE_EDITED_BODY="$work/edited.md"
mismatches=0

body="$work/body.md"
printf 'audit-unit: milestone:M1\n\n## Cost\n__TOKENS__\n' > "$body"
plain_body="$work/plain.md"
printf 'audit-unit: milestone:M1\naudit-accepted: example-org/demo#7\n' > "$plain_body"
base_args=(--repo example-org/demo --title "Audit M1 2026-10-31")
tokens_args=(--tokens 2026-10-31T00:00:00.000Z "<!-- kp-audit-alignment:token-usage -->")
dedup_args=(--dedup-line "audit-unit: milestone:M1" --dedup-line "audit-accepted: example-org/demo#7")
hit_closed='[{"number": 9, "state": "CLOSED", "url": "https://github.com/example-org/demo/issues/9"}]'
hit_open='[{"number": 9, "state": "OPEN", "url": "https://github.com/example-org/demo/issues/9"}]'

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || mismatches=$((mismatches + 1))
}

# run_case <name> <expected exit> <expected calls> <expected output JSON, '' for none>
#          [VAR=value …]
# Runs the script with case_args; the output is compared after `jq -c`.
run_case() {
  local name=$1 expected_status=$2 expected_calls=$3 expected_output=$4
  shift 4
  echo "== $name"
  : > "$FAKE_LOG"
  rm -f "$FAKE_EDITED_BODY"
  local status=0 output
  output="$(env "$@" "$script" "${case_args[@]}" 2>"$work/stderr")" || status=$?
  [ -n "$output" ] && output="$(jq -c . <<<"$output" 2>/dev/null || echo "$output")"
  if [ "$status" -eq "$expected_status" ] && [ "$(cat "$FAKE_LOG")" = "$expected_calls" ] &&
    [ "$output" = "$expected_output" ]; then
    check "$name" ok
  else
    printf 'exit %s, output: %s\ncalls:\n%s\nstderr:\n%s\n' \
      "$status" "$output" "$(cat "$FAKE_LOG")" "$(cat "$work/stderr")"
    check "$name" MISMATCH
  fi
}

created='{"number":42,"url":"https://github.com/example-org/demo/issues/42","reused":false}'
reused='{"number":9,"url":"https://github.com/example-org/demo/issues/9","reused":true}'

case_args=("${base_args[@]}" --body-file "$body" "${tokens_args[@]}")
run_case "(a) no dedup, with --tokens" 0 "ensure-labels type:audit
issue-create
report-tokens 42
issue-edit-body
issue-close 42" "$created"
if grep -q 'fake-row' "$FAKE_EDITED_BODY" && ! grep -q __TOKENS__ "$FAKE_EDITED_BODY"; then
  check "(a) edited body holds the row, no __TOKENS__" ok
else
  check "(a) edited body holds the row, no __TOKENS__" MISMATCH
fi

case_args=("${base_args[@]}" --body-file "$body")
run_case "(b) no --tokens" 0 "ensure-labels type:audit
issue-create
issue-close 42" "$created"

case_args=("${base_args[@]}" --body-file "$plain_body" "${dedup_args[@]}")
dedup_calls="ensure-labels type:audit
find-marker audit-unit: milestone:M1
find-marker audit-accepted: example-org/demo#7"
run_case "(c) both dedup lines hit a closed #9" 0 "$dedup_calls" "$reused" \
  FAKE_FIND_audit_unit="$hit_closed" FAKE_FIND_audit_accepted="$hit_closed"

run_case "(d) both dedup lines hit an open #9" 0 "$dedup_calls
issue-close 9" "$reused" \
  FAKE_FIND_audit_unit="$hit_open" FAKE_FIND_audit_accepted="$hit_open"

run_case "(e) only one dedup line hits" 0 "$dedup_calls
issue-create
issue-close 42" "$created" \
  FAKE_FIND_audit_unit="$hit_closed"

case_args=("${base_args[@]}" --body-file "$body" "${tokens_args[@]}")
run_case "(f) report-tokens.sh fails" 0 "ensure-labels type:audit
issue-create
issue-close 42" "$created" FAKE_TOKENS_FAIL=1
if grep -q 'token fill skipped' "$work/stderr"; then
  check "(f) stderr says token fill skipped" ok
else
  check "(f) stderr says token fill skipped" MISMATCH
fi

run_case "(g) create fails" 1 "ensure-labels type:audit" '' FAKE_CREATE_FAIL=1

case_args=("${base_args[@]}" --body-file "$plain_body" "${tokens_args[@]}")
run_case "(h) --tokens without __TOKENS__" 2 "" ''

case_args=("${base_args[@]}" --body-file "$plain_body" --dedup-line "audit-unit milestone:M1")
run_case "(i) malformed --dedup-line" 2 "" ''

echo
echo "mismatches: $mismatches"
exit $(( mismatches > 0 ? 1 : 0 ))
