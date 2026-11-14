#!/usr/bin/env bash
# Fake pr-verdict-state.sh: prints the state JSON file named by $FAKE_STATE.
set -euo pipefail
[ "${FAKE_STATE_FAIL:-}" = 1 ] && { echo "HTTP 502: comments read failed" >&2; exit 1; }
cat "$FAKE_STATE"
