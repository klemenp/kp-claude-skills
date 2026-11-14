#!/usr/bin/env bash
# A stand-in for milestone-tag.sh: prints the scenario's `tagLines` and exits with its
# `tagExit` (default 0).
set -euo pipefail
echo "milestone-tag.sh $*" >>"$FAKE_CALL_LOG"
jq -r '(.tagLines // ["tagged o/t milestone/M1 head"])[]' "$FAKE_GH_SCENARIO"
exit "$(jq -r '.tagExit // 0' "$FAKE_GH_SCENARIO")"
