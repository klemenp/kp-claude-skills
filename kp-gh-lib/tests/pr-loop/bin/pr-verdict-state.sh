#!/usr/bin/env bash
# Fake pr-verdict-state.sh: the case's verdict.<k>.json; right after a fix launch it
# carries the fix summary that kp-fix-pr would have posted. The `launch-args` line the
# fake run-child.sh records after each launch is not a call of its own.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/fake-lib.sh"
if grep -v '^launch-args ' "$FAKE_STATE/calls" 2>/dev/null | tail -1 | grep -q '^launch /kp-fix-pr'; then
  fixture_at verdict json | jq --argjson fix "$(fixture fix-summary.json)" '.fixSummary = $fix'
else
  fixture_at verdict json
fi
