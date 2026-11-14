#!/usr/bin/env bash
# Fake ensure-labels.sh: logs the call and reports the label as present.
set -euo pipefail
echo "ensure-labels ${*: -1}" >> "$FAKE_LOG"
echo "exists ${*: -1}"
