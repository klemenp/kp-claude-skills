#!/usr/bin/env bash
# A stand-in for milestone-of.sh <repo> <n>: prints the scenario's `items["<repo>#<n>"]`
# (`state` and `milestone`).
set -euo pipefail
echo "milestone-of.sh $*" >>"$FAKE_CALL_LOG"
jq -c --arg ref "$1#$2" '.items[$ref] // error("stub milestone-of.sh: no item \($ref)")' \
  "$FAKE_GH_SCENARIO"
