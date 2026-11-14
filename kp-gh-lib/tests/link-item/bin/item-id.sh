#!/usr/bin/env bash
# Fake item-id.sh: the child is on the board as $FAKE_BOARD_ITEM when set, else off it.
set -euo pipefail
echo "item-id $*" >> "$FAKE_LOG"
jq -n --arg item "${FAKE_BOARD_ITEM:-}" --arg content "I_$2" \
  '{itemId: (if $item == "" then null else $item end), status: null, statusOptionId: null,
    contentId: $content}'
