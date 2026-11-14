#!/usr/bin/env bash
# Fake kp-msg-me send script for the goal-question fixtures: logs one line per message to
# $FAKE_STATE/sent.log, so no fixture reaches Telegram.
set -euo pipefail
echo "$*" >> "$FAKE_STATE/sent.log"
