#!/usr/bin/env bash
# Pipes SessionStart events to restore-run-state.py and checks what it prints. The hook
# reads `state/` beside its own `scripts/` directory, so the suite runs a copy placed in
# a temporary directory with its own state files; the real state directory is never
# read. Offline — only local git — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
hook_source="${RESTORE_RUN_STATE_HOOK:-$here/../../scripts/restore-run-state.py}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lib/scripts" "$work/lib/state"
cp "$hook_source" "$work/lib/scripts/restore-run-state.py"
hook="$work/lib/scripts/restore-run-state.py"
checks=0
mismatches=0

HEADER="Run state restored after compaction — continue from here:"

worktree="$work/worktree"
git init -q "$worktree"
git -C "$worktree" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
head_sha="$(git -C "$worktree" rev-parse HEAD)"

# state <session id> <text> — writes that session's state file.
state() { printf '%s' "$2" > "$work/lib/state/run-$1.md"; }

# expect <label> <stdin> <expected stdout> — the hook must print exactly that and exit 0.
expect() {
  local got status problem=""
  got="$(printf '%s' "$2" | python3 "$hook" 2>"$work/stderr")"
  status=$?
  [ "$status" -eq 0 ] || problem="exit $status, want 0"
  [ "$got" = "$3" ] || problem="${problem:+$problem; }stdout is: $got"
  [ ! -s "$work/stderr" ] || problem="${problem:+$problem; }stderr: $(cat "$work/stderr")"
  checks=$((checks + 1))
  if [ -z "$problem" ]; then
    echo "-> $1: ok"
  else
    echo "-> $1: MISMATCH ($problem)"
    mismatches=$((mismatches + 1))
  fi
}

event() { printf '{"session_id": "%s", "source": "compact"}' "$1"; }

state with-worktree "item: example-org/shop-api#7"$'\n'"worktree: $worktree"$'\n'
expect "1 a state file with a live worktree prints the state and its HEAD" \
  "$(event with-worktree)" \
  "$HEADER"$'\n'"item: example-org/shop-api#7"$'\n'"worktree: $worktree"$'\n'"head: $head_sha"

state no-worktree "item: example-org/shop-api#7"$'\n\n\n'
expect "2 a state file without a worktree line prints the state only" \
  "$(event no-worktree)" "$HEADER"$'\n'"item: example-org/shop-api#7"

state gone "worktree: $work/removed"$'\n'
expect "3 a recorded worktree that no longer exists adds no head line" \
  "$(event gone)" "$HEADER"$'\n'"worktree: $work/removed"

mkdir "$work/plain"
state not-git "worktree: $work/plain"$'\n'
expect "4 a recorded worktree that is not a repository adds no head line" \
  "$(event not-git)" "$HEADER"$'\n'"worktree: $work/plain"

expect "5 a session without a state file prints nothing" "$(event unknown)" ""

# The id would resolve to an existing state file if it were used as a path.
mkdir "$work/lib/state/run-x"
expect "6 a session id that is not a plain token is refused" \
  "$(event "x/../run-with-worktree")" ""

expect "7 an event without a session id prints nothing" '{"source": "compact"}' ""
expect "8 an event that is not an object prints nothing" '["with-worktree"]' ""
expect "9 an event that is not JSON prints nothing" 'not json' ""

if [ "$mismatches" -eq 0 ]; then
  echo "all restore-run-state checks passed"
else
  echo "$mismatches of $checks restore-run-state checks failed"
  exit 1
fi
