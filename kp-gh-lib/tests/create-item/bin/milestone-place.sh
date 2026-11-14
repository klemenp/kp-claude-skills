#!/usr/bin/env bash
# Fake milestone-place.sh: places every item in M1 under example-org/demo#5.
echo "place" >> "$FAKE_LOG"
echo '{"milestone": "M1", "epic": "example-org/demo#5", "link": "item"}'
