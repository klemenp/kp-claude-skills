#!/usr/bin/env bash
# Drives report-tokens.sh --render over session.jsonl: a first run, a second run with a
# later start, a re-run of the first start with an unreadable transcript, an old
# single-line comment, a 7-column table and the 100-row cap. Each rendered body is diffed
# against its hand-checked <name>.expected.md. session/subagents/ holds the subagent
# transcripts summed into the `subagents` column (agent-a1.meta.json must be ignored).
# Offline — no GitHub — so this runs in CI.
set -uo pipefail
# The expected bodies record no effort; effort-from-env sets it per call.
unset KP_EFFORT

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/report-tokens.sh"
transcript="$here/session.jsonl"
marker="<!-- kp-test:token-usage -->"
first="2026-09-10T10:00:00.000Z"
second="2026-09-10T10:05:00.000Z"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# render <name> <start> <existing-body|-> [transcript]: writes $work/<name>.md and diffs
# it against <name>.expected.md.
render() {
  local name=$1 start=$2 existing=$3 source=${4:-$transcript}
  echo "== $name"
  "$script" --render "$start" "$marker" "$source" "$existing" > "$work/$name.md"
  if diff -u "$here/$name.expected.md" "$work/$name.md"; then
    check "$name" ok
  else
    check "$name" MISMATCH
  fi
}

render first-run "$first" -
render second-run "$second" "$work/first-run.md"
# Same start as the first run, now with no readable transcript: its row is rewritten in
# place with `?` figures, the second row is untouched and the sum passes over the `?`.
render rerun-first "$first" "$work/second-run.md" "$work/absent.jsonl"
render old-format "$second" "$here/old-format.md"
# Today's 7-column table: both old rows get `?` for effort and subagents, the sum is
# recomputed over the figures, and the new run appends.
render seven-column-upgrade "$second" "$here/seven-column.md"

# subagents since the first start: agent-a1 sa-1 once (100+200+300+400) plus sa-2
# (1+2+3+4), agent-a2 sb-1 (4 x 20); the entries before the start and the .meta.json
# are excluded.
row_cell() { # row_cell <body> <start> <1-based cell>
  grep "^| $2 " "$1" | cut -d'|' -f$(($3 + 1)) | sed 's/^ *//; s/ *$//'
}
echo "== subagents-summed"
expected_subagents=$((100 + 200 + 300 + 400 + 1 + 2 + 3 + 4 + 4 * 20))
actual_subagents="$(row_cell "$work/first-run.md" "$first" 8 | tr -d ,)"
echo "subagents: $actual_subagents (expected $expected_subagents)"
if [ "$actual_subagents" = "$expected_subagents" ]; then
  check subagents-summed ok
else
  check subagents-summed MISMATCH
fi

echo "== effort-from-env"
effort_ok=ok
for case in "high:high" ":—" "bogus:—" "HIGH:—"; do
  value=${case%%:*} want=${case#*:}
  if [ -n "$value" ]; then
    KP_EFFORT=$value "$script" --render "$first" "$marker" "$transcript" - > "$work/effort.md"
  else
    "$script" --render "$first" "$marker" "$transcript" - > "$work/effort.md"
  fi
  got="$(row_cell "$work/effort.md" "$first" 3)"
  echo "KP_EFFORT='$value' -> '$got' (expected '$want')"
  [ "$got" = "$want" ] || effort_ok=MISMATCH
done
check effort-from-env "$effort_ok"

# 101 runs: the oldest row goes and the sum line counts it.
echo "== row cap"
body=-
for minute in $(seq 0 100); do
  start="2026-09-12T$(printf '%02d:%02d' $((minute / 60)) $((minute % 60))):00.000Z"
  "$script" --render "$start" "$marker" "$transcript" "$body" > "$work/cap.md"
  cp "$work/cap.md" "$work/cap-previous.md"
  body="$work/cap-previous.md"
done
rows="$(grep -c '^| 2026-09-12T' "$work/cap.md")"
sum_line="$(grep '^| \*\*Sum\*\*' "$work/cap.md")"
echo "rows: $rows; $sum_line"
if [ "$rows" -eq 100 ] && [[ $sum_line == *"100 runs; 1 oldest row dropped"* ]] \
    && ! grep -q '2026-09-12T00:00:00' "$work/cap.md"; then
  check "row cap" ok
else
  check "row cap" MISMATCH
fi

# Bad arguments are exit 2, distinct from a GitHub failure.
status=0
"$script" not-a-time "$marker" o/r 1 >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then check "bad start exits 2" ok; else check "bad start exits 2" MISMATCH; fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
