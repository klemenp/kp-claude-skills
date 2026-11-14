#!/usr/bin/env bash
# Drives audit-prev.sh against the fake gh in bin/, which answers `gh issue list` from a
# fixture array in the state dir: a first round, units that only look alike, the later of
# two rounds, the prev-refuted.md order, the prev spec SHA, the gh argument vector, a
# failing gh that leaves an earlier prev.json alone, and argument errors that call no gh.
# Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/audit-prev.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" FAKE_STATE="$work"
run_dir="$work/run"
failures=0

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

# reset — an empty run dir, no gh log, no failure flag, and no issues.
reset() {
  rm -rf "$run_dir" "$work/gh.log" "$work/fail"
  mkdir -p "$run_dir"
  echo '[]' > "$work/issues.json"
}

# issue <number> <closedAt> <body> — one issue object for the fixture array.
issue() {
  jq -n --argjson number "$1" --arg closedAt "$2" --arg body "$3" \
    '{number: $number, closedAt: $closedAt, body: $body}'
}

# seed <issue object>… — the fixture array gh issue list answers with.
seed() { printf '%s\n' "$@" | jq -s . > "$work/issues.json"; }

prev() { jq -c "$1" "$run_dir/prev.json"; }

echo "== no issues: a first round"
reset
output="$("$script" example-org/spec area:EXPORT "$run_dir")"
expect "exits 0 and prints {}" "$?:$output" "0:{}"
expect "prev.json is {}" "$(prev .)" "{}"
expect "prev-refuted.md exists and is empty" \
  "$([ -f "$run_dir/prev-refuted.md" ] && wc -c < "$run_dir/prev-refuted.md" | tr -d ' ')" "0"

echo "== only other units"
reset
seed "$(issue 3 2026-01-01T00:00:00Z $'audit-unit: area:EXPORTS\naudit-shas: example-org/spec@aaa')" \
  "$(issue 4 2026-02-01T00:00:00Z $'Report for audit-unit: area:EXPORT here\naudit-shas: example-org/spec@bbb')"
output="$("$script" example-org/spec area:EXPORT "$run_dir")"
expect "a look-alike unit is a first round" "$?:$output" "0:{}"

echo "== two rounds for the unit"
reset
later_body=$'# Audit\naudit-unit: area:EXPORT\nrefuted: REQ-EXPORT-002 — stale\naudit-shas: Example-Org/Spec@abc123 example-org/be@def456\naudit-filed: example-org/be#9\nprose that is dropped\nunfiled: none\n## Findings\n| kind | ref |\n| gap | REQ-EXPORT-001 |\nrefuted: REQ-EXPORT-003 — fixed'
seed "$(issue 10 2026-01-05T00:00:00Z $'audit-unit: area:EXPORT\naudit-shas: example-org/spec@old111\nrefuted: REQ-EXPORT-009 — old')" \
  "$(issue 12 2026-03-05T00:00:00Z "$later_body")" \
  "$(issue 11 2026-02-05T00:00:00Z $'audit-unit: area:EXPORT\naudit-shas: example-org/spec@mid222')"
output="$("$script" example-org/spec area:EXPORT "$run_dir")"
expect "the later round, its spec SHA matched case-insensitively" "$?:$output" \
  '0:{"number": 12, "prevSpecSha": "abc123"}'
expect "prev.json carries the later round's number and closedAt" \
  "$(prev '[.number, .closedAt]')" '[12,"2026-03-05T00:00:00Z"]'
expect "prev.json lines are only the kept lines, in body order" "$(prev .lines)" \
  '["refuted: REQ-EXPORT-002 — stale","audit-shas: Example-Org/Spec@abc123 example-org/be@def456","audit-filed: example-org/be#9","unfiled: none","| kind | ref |","| gap | REQ-EXPORT-001 |","refuted: REQ-EXPORT-003 — fixed"]'
expect "prev-refuted.md is audit-shas: then the refuted: lines" "$(cat "$run_dir/prev-refuted.md")" \
  $'audit-shas: Example-Org/Spec@abc123 example-org/be@def456\nrefuted: REQ-EXPORT-002 — stale\nrefuted: REQ-EXPORT-003 — fixed'
expect "gh is asked for closed type:audit issues, 200 at most" \
  "$(grep -c -- '--label type:audit --state closed --limit 200' "$work/gh.log")" "1"

echo "== a round with no audit-shas: line"
reset
seed "$(issue 20 2026-04-01T00:00:00Z $'audit-unit: area:EXPORT\nrefuted: REQ-EXPORT-001 — fine')"
output="$("$script" example-org/spec area:EXPORT "$run_dir")"
expect "prevSpecSha is null" "$?:$output" '0:{"number": 20, "prevSpecSha": null}'

echo "== gh fails"
reset
seed "$(issue 30 2026-04-01T00:00:00Z $'audit-unit: area:EXPORT')"
echo '{"number": 1}' > "$run_dir/prev.json"
touch "$work/fail"
output="$("$script" example-org/spec area:EXPORT "$run_dir" 2>"$work/stderr")"
expect "exits 1 with empty stdout" "$?:$output" "1:"
expect "gh's stderr is passed through" "$(cat "$work/stderr")" "HTTP 502: issue list failed"
expect "the earlier prev.json is unchanged" "$(prev .)" '{"number":1}'
expect "no prev-refuted.md is created" "$([ -e "$run_dir/prev-refuted.md" ] && echo yes || echo no)" "no"

echo "== bad arguments"
reset
"$script" example-org/spec area:EXPORT 2>/dev/null
expect "two positionals exit 2" "$?" "2"
"$script" example-org/spec area:EXPORT "$work/missing" 2>/dev/null
expect "a missing run dir exits 2" "$?" "2"
"$script" not-a-repo area:EXPORT "$run_dir" 2>/dev/null
expect "a malformed spec repo exits 2" "$?" "2"
"$script" example-org/spec "" "$run_dir" 2>/dev/null
expect "an empty unit exits 2" "$?" "2"
expect "no gh call is made on bad arguments" "$([ -e "$work/gh.log" ] && echo called || echo none)" "none"

if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi
echo "all audit-prev checks passed"
