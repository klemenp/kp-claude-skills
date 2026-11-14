#!/usr/bin/env bash
# Fake run-child.sh: a launch only counts and records the prompt and its --model and
# --effort (no path, so the line is the same on every machine); a wait answers at once
# with the case's wait.<launch> line, or a clean finish.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/fake-lib.sh"
if [ "$1" = --wait ]; then
  log=$2
  if [ -f "$FAKE_DIR/wait.$(launches)" ]; then
    printf '%s log=%s\n' "$(cat "$FAKE_DIR/wait.$(launches)")" "$log"
  else
    printf 'exit=0 capacity=none log=%s\n' "$log"
  fi
  exit 0
fi
model='' effort=''
while [ "$1" != -- ]; do
  case "$1" in
    --model) model=$2; shift ;;
    --effort) effort=$2; shift ;;
  esac
  shift
done
shift
prompt="$*"
echo $(($(launches) + 1)) > "$FAKE_STATE/launches"
record "launch $prompt"
record "launch-args --model $model${effort:+ --effort $effort}"
case "$prompt" in *kp-do-gh-pr-loop-escalate*) touch "$FAKE_STATE/escalated" ;; esac
echo "status: running"
exit 3
