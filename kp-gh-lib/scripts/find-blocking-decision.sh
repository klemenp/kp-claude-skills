#!/usr/bin/env bash
# Find the open human-gated issue — `type:decision`, `type:question` or `type:conflict` —
# that blocks a work item, its PR or its `spec-ref`. `pr-loop.sh`, `kp-do-gh-task-loop`
# and `kp-do-gh-pr-loop-all` all ask this; they used to restate the search, each slightly
# differently.
#
# Usage: find-blocking-decision.sh <owner/repo> [--issue <n>] [--pr <p>]
#          [--spec-ref <s>] [--from-file <json>]
#        At least one of --issue / --pr / --spec-ref is required.
#
# Search: each given target is one call to the sibling `find-marker.sh`:
#   find-marker.sh <owner/repo> blocks <target> --state open
# where the target is `#<n>` for --issue, `#<p>` for --pr (find-marker matches both `#<n>`
# and `<owner/repo>#<n>`, never `#<n>0`) and the value verbatim for --spec-ref. The
# human-only fence and <details> blocks are skipped there, not here.
#
# Confirm: a hit is kept only when its labels include `type:decision`, `type:question` or
# `type:conflict` — a coding item carrying a `blocks:` line is not a decision.
#
# Prints one JSON object:
#   {"decision": <lowest kept issue number>|null,
#    "all": [<every kept issue number, ascending, no duplicates>]}
#
# --from-file <json>: passed through unchanged to every find-marker.sh call (its
#   `{"issues": [...]}` fixture shape), so fixtures stand in for the search.
#
# Exit: 0 searched (including no hit) · 1 a find-marker.sh call failed (its stderr passed
# on) · 2 bad arguments.
set -euo pipefail

FIND_MARKER="$(dirname "$0")/find-marker.sh"

python3 "$(dirname "${BASH_SOURCE[0]}")"/py/find_blocking_decision.py "$FIND_MARKER" "$@" </dev/null
