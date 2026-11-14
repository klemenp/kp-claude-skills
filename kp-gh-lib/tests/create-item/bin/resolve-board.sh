#!/usr/bin/env bash
# Fake resolve-board.sh: a board owned by ${FAKE_OWNER_TYPE:-user}, with no Priority
# field when FAKE_NO_PRIORITY=1.
set -euo pipefail
priority='{"fieldId": "PRIO", "options": [{"id": "p0", "name": "P0"}, {"id": "p1", "name": "P1"}]}'
[ "${FAKE_NO_PRIORITY:-}" = 1 ] && priority=null
cat <<JSON
{"projectId": "PVT_demo", "ownerType": "${FAKE_OWNER_TYPE:-user}",
 "status": {"fieldId": "STATUS", "options": [{"id": "s-ready", "name": "Ready"}]},
 "priority": $priority}
JSON
