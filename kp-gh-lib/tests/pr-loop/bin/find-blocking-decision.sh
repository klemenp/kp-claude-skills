#!/usr/bin/env bash
# Fake find-blocking-decision.sh: nothing blocks the PR until the escalate child has run,
# then the human-gated item it raised.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/fake-lib.sh"
if [ -f "$FAKE_STATE/escalated" ]; then
  echo '{"decision": 300, "all": [300]}'
else
  echo '{"decision": null, "all": []}'
fi
