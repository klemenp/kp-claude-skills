#!/usr/bin/env bash
# Fake set-status.sh: logs the option it was asked to move to.
echo "status $4" >> "$FAKE_LOG"
printf '{"itemId": "%s", "fieldId": "%s", "optionId": "%s"}\n' "$2" "$3" "$4"
