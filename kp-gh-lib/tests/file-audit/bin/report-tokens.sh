#!/usr/bin/env bash
# Fake report-tokens.sh: logs the call and prints a fixed row, or fails on FAKE_TOKENS_FAIL.
set -euo pipefail
[ "${FAKE_TOKENS_FAIL:-}" = 1 ] && { echo "no transcript readable" >&2; exit 1; }
echo "report-tokens $4" >> "$FAKE_LOG"
echo "| 2026-10-31T00:00:00.000Z | fake-row |"
