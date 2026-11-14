#!/usr/bin/env bash
# Fake item-id.sh for the backfill-candidates fixtures: serves the Status in
# $FAKE_STATE/status-<n> (not on the board when absent), logs each call to
# $FAKE_STATE/item-id.log, and fails when FAKE_ITEM_ID_FAIL=1.
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_STATE/item-id.log"
[ "${FAKE_ITEM_ID_FAIL:-}" = 1 ] && { echo "item-id.sh: cannot look up $1#$2: HTTP 502" >&2; exit 1; }

status_file="$FAKE_STATE/status-$2"
if [ -f "$status_file" ]; then
  jq -cn --arg status "$(cat "$status_file")" \
    '{itemId: "PVTI_fake", status: $status, statusOptionId: "opt", contentId: "I_fake"}'
else
  echo '{"itemId": null, "status": null, "statusOptionId": null, "contentId": "I_fake"}'
fi
