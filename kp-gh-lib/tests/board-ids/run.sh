#!/usr/bin/env bash
# Drives item-id.sh, resolve-board.sh and set-status.sh, the three helpers that turn a
# board and an issue into Projects v2 ids and move a Status, against the fake gh in
# bin/. Each case sets the fake's answer, then checks the exit code, stdout, stderr and
# the calls the script made. Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="${BOARD_IDS_SCRIPTS:-$(cd "$here/../../scripts" && pwd)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" FAKE_CALLS="$work/calls.log"
checks=0
mismatches=0
out=""
err=""
status=0

# run_case [VAR=value …] -- <script> <args…> — runs one script with those fake knobs.
run_case() {
  local knobs=()
  while [ "$1" != -- ]; do knobs+=("$1"); shift; done
  shift
  : > "$FAKE_CALLS"
  out="$(env ${knobs[@]+"${knobs[@]}"} "$scripts/$1" "${@:2}" 2>"$work/stderr")"
  status=$?
  err="$(cat "$work/stderr")"
}

calls() { wc -l < "$FAKE_CALLS" | tr -d ' '; }

# same_json <actual> <expected> — true when both parse to the same JSON value.
same_json() {
  python3 -c '
import json
import sys
sys.exit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)
' "$1" "$2" 2>/dev/null
}

# expect <label> <exit> <gh calls> <stdout: JSON, or "" for none> [text stderr must contain]
expect() {
  local label=$1 problem=""
  [ "$status" -eq "$2" ] || problem="exit $status, want $2"
  [ "$(calls)" -eq "$3" ] || problem="${problem:+$problem; }$(calls) gh calls, want $3"
  if [ -z "$4" ]; then
    [ -z "$out" ] || problem="${problem:+$problem; }stdout is not empty: $out"
  else
    same_json "$out" "$4" || problem="${problem:+$problem; }stdout is $out"
  fi
  if [ -n "${5:-}" ]; then
    [[ $err == *"$5"* ]] || problem="${problem:+$problem; }stderr lacks '$5': $err"
  fi
  checks=$((checks + 1))
  if [ -z "$problem" ]; then
    echo "-> $label: ok"
  else
    echo "-> $label: MISMATCH ($problem)"
    mismatches=$((mismatches + 1))
  fi
}

# called_with <label> <text the one logged call must contain> [text it must not contain]
called_with() {
  local problem="" call
  call="$(cat "$FAKE_CALLS")"
  [[ $call == *"$2"* ]] || problem="the call lacks '$2': $call"
  if [ -n "${3:-}" ] && [[ $call == *"$3"* ]]; then
    problem="${problem:+$problem; }the call has '$3'"
  fi
  checks=$((checks + 1))
  if [ -z "$problem" ]; then
    echo "-> $1: ok"
  else
    echo "-> $1: MISMATCH ($problem)"
    mismatches=$((mismatches + 1))
  fi
}

# --- item-id.sh -----------------------------------------------------------------------

# issue_answer <projectItems nodes JSON>
issue_answer() {
  printf '{"data":{"repository":{"issue":{"id":"I_7","projectItems":{"nodes":%s}}}}}' "$1"
}

item() {
  printf '{"id":"%s","project":{"id":"%s","number":1},"fieldValueByName":%s}' "$1" "$2" "$3"
}

READY='{"name":"Ready","optionId":"opt-ready"}'

run_case "FAKE_STDOUT=$(issue_answer "[$(item PVTI_a PVT_shop "$READY")]")" -- \
  item-id.sh example-org/shop-api 7 PVT_shop
expect "1 item-id: an issue on the board" 0 1 \
  '{"itemId":"PVTI_a","status":"Ready","statusOptionId":"opt-ready","contentId":"I_7"}'
called_with "2 item-id: the query carries owner, repo and number" \
  "owner=example-org -F repo=shop-api -F num=7"

run_case "FAKE_STDOUT=$(issue_answer "[$(item PVTI_other PVT_other null),$(item PVTI_a PVT_shop "$READY")]")" -- \
  item-id.sh example-org/shop-api 7 PVT_shop
expect "3 item-id: an issue on two boards answers for the one asked" 0 1 \
  '{"itemId":"PVTI_a","status":"Ready","statusOptionId":"opt-ready","contentId":"I_7"}'

run_case "FAKE_STDOUT=$(issue_answer "[$(item PVTI_other PVT_other "$READY")]")" -- \
  item-id.sh example-org/shop-api 7 PVT_shop
expect "4 item-id: an issue not on the board" 0 1 \
  '{"itemId":null,"status":null,"statusOptionId":null,"contentId":"I_7"}'

run_case "FAKE_STDOUT=$(issue_answer "[$(item PVTI_a PVT_shop null)]")" -- \
  item-id.sh example-org/shop-api 7 PVT_shop
expect "5 item-id: an item with no Status" 0 1 \
  '{"itemId":"PVTI_a","status":null,"statusOptionId":null,"contentId":"I_7"}'

run_case FAKE_EXIT=1 'FAKE_STDOUT={"errors":[{"type":"NOT_FOUND"}]}' -- \
  item-id.sh example-org/shop-api 7 PVT_shop
expect "6 item-id: a failed lookup" 1 1 "" "item-id.sh: cannot look up example-org/shop-api#7"

run_case -- item-id.sh example-org/shop-api 7
expect "7a item-id: two arguments" 2 0 "" "usage: item-id.sh"
run_case -- item-id.sh example-org/shop-api seven PVT_shop
expect "7b item-id: an issue that is not a number" 2 0 "" "usage: item-id.sh"
run_case -- item-id.sh shop-api 7 PVT_shop
expect "7c item-id: a repo without an owner" 2 0 "" "usage: item-id.sh"

# --- resolve-board.sh -----------------------------------------------------------------

STATUS_FIELD='{"id":"PVTSSF_status","name":"Status","options":[{"id":"o1","name":"Backlog"},{"id":"o2","name":"Ready"},{"id":"o3","name":"Done"}]}'
PRIORITY_FIELD='{"id":"PVTSSF_priority","name":"Priority","options":[{"id":"p1","name":"P0"},{"id":"p2","name":"P1"}]}'
STATUS_OUT='{"fieldId":"PVTSSF_status","options":[{"id":"o1","name":"Backlog"},{"id":"o2","name":"Ready"},{"id":"o3","name":"Done"}]}'
PRIORITY_OUT='{"fieldId":"PVTSSF_priority","options":[{"id":"p1","name":"P0"},{"id":"p2","name":"P1"}]}'

# board_answer <user | organization> <field nodes JSON>
board_answer() {
  printf '{"data":{"%s":{"projectV2":{"id":"PVT_shop","fields":{"nodes":%s}}}}}' "$1" "$2"
}

USER_MISS='{"data":{"user":null},"errors":[{"type":"NOT_FOUND","path":["user"]}]}'

# The empty node is how a field that is not single-select comes back.
run_case "FAKE_STDOUT=$(board_answer user "[{},$STATUS_FIELD,$PRIORITY_FIELD]")" -- \
  resolve-board.sh example-user 4
expect "8 resolve-board: a user's board with both fields, options in board order" 0 1 \
  "{\"projectId\":\"PVT_shop\",\"ownerType\":\"user\",\"status\":$STATUS_OUT,\"priority\":$PRIORITY_OUT}"
called_with "9 resolve-board: the query carries owner and number" \
  "owner=example-user -F number=4"

run_case "FAKE_STDOUT=$(board_answer user "[$STATUS_FIELD]")" -- resolve-board.sh example-user 4
expect "10 resolve-board: a board without Priority" 0 1 \
  "{\"projectId\":\"PVT_shop\",\"ownerType\":\"user\",\"status\":$STATUS_OUT,\"priority\":null}"

run_case FAKE_USER_EXIT=1 "FAKE_USER_STDOUT=$USER_MISS" \
  "FAKE_STDOUT=$(board_answer organization "[$STATUS_FIELD]")" -- resolve-board.sh example-org 4
expect "11 resolve-board: an organization's board is found on the second query" 0 2 \
  "{\"projectId\":\"PVT_shop\",\"ownerType\":\"organization\",\"status\":$STATUS_OUT,\"priority\":null}"

run_case FAKE_USER_EXIT=1 'FAKE_USER_STDOUT={"message":"Bad credentials"}' -- \
  resolve-board.sh example-org 4
expect "12 resolve-board: a failure that is not a user miss stops at once" 1 1 "" \
  "resolve-board.sh: cannot resolve project example-org/4"

run_case FAKE_USER_EXIT=1 "FAKE_USER_STDOUT=$USER_MISS" FAKE_EXIT=1 \
  'FAKE_STDOUT={"data":{"organization":null}}' -- resolve-board.sh example-org 4
expect "13 resolve-board: neither a user nor an organization" 1 2 "" \
  "resolve-board.sh: cannot resolve project example-org/4"

run_case -- resolve-board.sh example-org
expect "14a resolve-board: one argument" 2 0 "" "usage: resolve-board.sh"
run_case -- resolve-board.sh example-org four
expect "14b resolve-board: a number that is not a number" 2 0 "" "usage: resolve-board.sh"

# --- set-status.sh --------------------------------------------------------------------

MOVED='{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_a"}}}}'

run_case "FAKE_STDOUT=$MOVED" -- set-status.sh PVT_shop PVTI_a PVTSSF_status 98236657
expect "15 set-status: a move" 0 1 \
  '{"itemId":"PVTI_a","fieldId":"PVTSSF_status","optionId":"98236657"}'
# -F would send an all-digit option id as a number, which the mutation rejects.
called_with "16 set-status: every id is sent as a raw string" \
  "-f project=PVT_shop -f item=PVTI_a -f field=PVTSSF_status -f option=98236657" " -F "

run_case FAKE_EXIT=1 "FAKE_STDERR=HTTP 502" -- set-status.sh PVT_shop PVTI_a PVTSSF_status o2
expect "17 set-status: a failed call" 1 1 "" "set-status.sh: cannot move PVTI_a to option o2: HTTP 502"

run_case 'FAKE_STDOUT={"data":{"updateProjectV2ItemFieldValue":null},"errors":[{"message":"no such option"}]}' -- \
  set-status.sh PVT_shop PVTI_a PVTSSF_status o2
expect "18 set-status: errors in a successful response" 1 1 "" "no such option"

started=$SECONDS
run_case FAKE_SLEEP=20 GH_TIMEOUT_SECONDS=1 -- set-status.sh PVT_shop PVTI_a PVTSSF_status o2
expect "19 set-status: a call that hangs is cut off" 1 1 "" "set-status.sh: cannot move PVTI_a to option o2"
checks=$((checks + 1))
if [ $((SECONDS - started)) -lt 10 ]; then
  echo "-> 20 set-status: the cut-off does not wait for the hung call: ok"
else
  echo "-> 20 set-status: the cut-off does not wait for the hung call: MISMATCH ($((SECONDS - started))s)"
  mismatches=$((mismatches + 1))
fi

run_case -- set-status.sh PVT_shop PVTI_a PVTSSF_status
expect "21a set-status: three arguments" 2 0 "" "usage: set-status.sh"
run_case -- set-status.sh PVT_shop "" PVTSSF_status o2
expect "21b set-status: an empty argument" 2 0 "" "usage: set-status.sh"

if [ "$mismatches" -eq 0 ]; then
  echo "all board-ids checks passed"
else
  echo "$mismatches of $checks board-ids checks failed"
  exit 1
fi
