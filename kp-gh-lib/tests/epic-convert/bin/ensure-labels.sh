#!/usr/bin/env bash
# Fake ensure-labels.sh: logs its arguments; FAKE_ENSURE_FAIL=1 makes it fail.
echo "ensure-labels.sh $*" >> "$FAKE_LOG"
[ "${FAKE_ENSURE_FAIL:-}" = 1 ] && { echo "HTTP 403: label create refused" >&2; exit 1; }
echo "created type:epic"
