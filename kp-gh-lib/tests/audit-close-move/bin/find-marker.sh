#!/usr/bin/env bash
# A stand-in for find-marker.sh: prints the scenario's `epics` hits, or exits 1 when the
# scenario sets `findMarkerFails`.
set -euo pipefail
echo "find-marker.sh $*" >>"$FAKE_CALL_LOG"
if [ "$(jq -r '.findMarkerFails // false' "$FAKE_GH_SCENARIO")" = true ]; then
  echo "gh: API rate limit exceeded (HTTP 403)" >&2
  exit 1
fi
jq -c '.epics // []' "$FAKE_GH_SCENARIO"
