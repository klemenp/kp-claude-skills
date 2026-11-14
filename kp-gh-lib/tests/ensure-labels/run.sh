#!/usr/bin/env bash
# Drives ensure-labels.sh against the fake gh in bin/, which serves a label list from the
# FAKE_LABELS knob and logs every call: an absent label created, a matching one left
# untouched, a recolored one updated, an `=<hex>` suffix used for an unmapped label, a
# model tier label given its family's color, an unmapped label without a suffix refused
# before any call, and a failing create. Offline — no
# GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/ensure-labels.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" FAKE_LOG="$work/calls.log"
mismatches=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || mismatches=$((mismatches + 1))
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

# once <labels JSON array> <args…> — runs the script against that label list, leaving
# "<exit>:<stdout>" in $outcome and the calls in $FAKE_LOG
once() {
  local output status=0
  : > "$FAKE_LOG"
  output="$(FAKE_LABELS="$1" "$script" "${@:2}" 2>/dev/null)" || status=$?
  outcome="$status:$output"
}

logged() { wc -l < "$FAKE_LOG" | tr -d ' '; }
creates() { grep -c '^label create' "$FAKE_LOG"; }
create_line() { grep '^label create' "$FAKE_LOG"; }

echo "== absent label → created with the built-in color"
once '[]' --repo example-org/demo type:decision
expect "prints created" "$outcome" "0:created type:decision"
expect "one create with the map color" "$(create_line)" \
  "label create type:decision -R example-org/demo --color d93f0b --force "

echo "== same color, other case → untouched"
once '[{"name":"type:coding","color":"1D76DB"}]' --repo example-org/demo type:coding
expect "prints exists" "$outcome" "0:exists type:coding"
expect "no create logged" "$(creates)" 0

echo "== different color → updated"
once '[{"name":"model:opus","color":"000000"}]' --repo example-org/demo model:opus
expect "prints updated" "$outcome" "0:updated model:opus"
expect "one create with the map color" "$(create_line)" \
  "label create model:opus -R example-org/demo --color B60205 --force "

echo "== repo:* label → the shared repo color"
once '[]' --repo example-org/demo repo:demo
expect "one create with the repo color" "$(create_line)" \
  "label create repo:demo -R example-org/demo --color 6E7781 --force "

echo "== =<hex> suffix on an unmapped label"
once '[]' --repo example-org/demo spec-sync=c5def5
expect "prints created with the bare name" "$outcome" "0:created spec-sync"
expect "one create with the suffix color" "$(create_line)" \
  "label create spec-sync -R example-org/demo --color c5def5 --force "

echo "== several labels → one line each, in order, one list read"
once '[{"name":"type:coding","color":"1d76db"}]' --repo example-org/demo type:coding model:haiku
expect "prints both lines" "$outcome" "0:exists type:coding
created model:haiku"
expect "one list read" "$(grep -c '^api' "$FAKE_LOG")" 1

echo "== model tier labels → the family colors, no suffix needed"
once '[]' --repo example-org/demo model:opus-xhigh model:haiku-low
expect "prints both created" "$outcome" "0:created model:opus-xhigh
created model:haiku-low"
expect "the opus and haiku colors" "$(create_line)" \
  "label create model:opus-xhigh -R example-org/demo --color B60205 --force 
label create model:haiku-low -R example-org/demo --color 0E8A16 --force "

echo "== unknown model family tier without a suffix → exit 2, no call"
once '[]' --repo example-org/demo model:gpt-high
expect "exits 2 and prints nothing" "$outcome" "2:"
expect "no call logged" "$(logged)" 0

echo "== unmapped label without a suffix → exit 2, no call"
once '[]' --repo example-org/demo type:coding spec-sync
expect "exits 2 and prints nothing" "$outcome" "2:"
expect "no call logged" "$(logged)" 0

echo "== malformed hex → exit 2, no call"
once '[]' --repo example-org/demo 'spec-sync=#c5def5'
expect "exits 2" "$outcome" "2:"
expect "no call logged" "$(logged)" 0

echo "== missing --repo → exit 2, no call"
once '[]' type:coding
expect "exits 2" "$outcome" "2:"
expect "no call logged" "$(logged)" 0

echo "== failing create → exit 1 after the lines already printed"
: > "$FAKE_LOG"
status=0
output="$(FAKE_LABELS='[{"name":"type:coding","color":"1d76db"}]' FAKE_CREATE_FAIL=1 \
  "$script" --repo example-org/demo type:coding type:epic 2>"$work/stderr")" || status=$?
expect "exits 1 with the earlier line" "$status:$output" "1:exists type:coding"
expect "stderr names the label" "$(grep -c "'type:epic'" "$work/stderr")" 1

echo
echo "mismatches: $mismatches"
exit $(( mismatches > 0 ? 1 : 0 ))
