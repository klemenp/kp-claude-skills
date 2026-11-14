#!/usr/bin/env bash
# The candidate list kp-backfill-contract lints: §7.1 steps 2–4 (list, skip a failed item,
# status) and the stale-label pass's enumeration and status lookup, run the same way
# every time. Selection by lint stays in the skill.
#
# Usage: backfill-candidates.sh --repo <owner/repo> --project-id <id> --sha <synced SHA>
#                               [--labelled]
#
# List: without --labelled, the open `type:coding` items
#   (`gh issue list -R <repo> --state open --label type:coding --limit 1000 --json number,title,body,labels`);
#   with --labelled, the open `needs-contract` items
#   (`gh issue list -R <repo> --label needs-contract --state open --limit 1000 --json number,title,body,labels`).
# Failed-at-SHA: an item carrying `needs-contract` has every comment read
#   (`gh api --paginate repos/<repo>/issues/<n>/comments`, REST, no GraphQL points);
#   failedAtSha is true when a comment line, trimmed, equals
#   `<!-- kp-sync-spec-tasks:backfill-failed <sha> -->` (case-sensitive, the full given
#   SHA). An item without the label is never read and is false. Without --labelled such
#   an item is `skip: "unchanged-failure"` and is not looked up; with --labelled the flag
#   is only reported.
# Status: every item not already skipped is looked up with
#   `item-id.sh <repo> <n> <project-id>` — 1 GraphQL point each, never a board-wide
#   listing. `In progress` or `In review` is `skip: "in-progress"`; any other status, and
#   an item not on the board, is `skip: null`.
#
# Prints one JSON array, sorted by number, one object per listed item:
#   [{"number": n, "title": "…", "body": "…", "labels": [names],
#     "status": "<name>" | null, "failedAtSha": true|false,
#     "skip": null | "unchanged-failure" | "in-progress"}, …]
# `status` is null for an item not on the board, with no Status, or never looked up.
#
# item-id.sh is found through KP_GH_LIB_BIN, default this script's own directory.
#
# Exit: 0 listed (including `[]`) · 1 a gh call or item-id.sh failed (nothing on stdout,
#       its stderr passed through) · 2 bad arguments.
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/backfill_candidates.py "$@" </dev/null
