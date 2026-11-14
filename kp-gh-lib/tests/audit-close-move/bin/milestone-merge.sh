#!/usr/bin/env bash
# A stand-in for milestone-merge.sh: prints the scenario's `mergeLines` and exits with
# its `mergeExit` (default 0).
set -euo pipefail
echo "milestone-merge.sh $*" >>"$FAKE_CALL_LOG"
jq -r '(.mergeLines // ["no-branch o/t"])[]' "$FAKE_GH_SCENARIO"
exit "$(jq -r '.mergeExit // 0' "$FAKE_GH_SCENARIO")"
