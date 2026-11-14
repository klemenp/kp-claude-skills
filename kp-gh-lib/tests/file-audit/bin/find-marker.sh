#!/usr/bin/env bash
# Fake find-marker.sh: logs the call and prints the JSON hits the case put in the knob
# named after the marker — FAKE_FIND_<marker, `-` as `_`> — or `[]` when unset.
set -euo pipefail
marker=$2
echo "find-marker $marker: $3" >> "$FAKE_LOG"
knob="FAKE_FIND_${marker//-/_}"
echo "${!knob:-[]}"
