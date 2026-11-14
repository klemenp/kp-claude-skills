#!/usr/bin/env bash
# Fake kp-msg-me send script for the create-item fixtures: logs the
# message to $FAKE_LOG, or fails when FAKE_SEND_FAIL=1, so no fixture reaches Telegram.
set -euo pipefail
[ "${FAKE_SEND_FAIL:-}" = 1 ] && { echo "Error: failed to reach Telegram API." >&2; exit 4; }
echo "notify $*" >> "$FAKE_LOG"
