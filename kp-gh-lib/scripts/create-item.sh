#!/usr/bin/env bash
# The create chain every item-creating kp-* skill shares (NOTES.md § *Creating an item*),
# run from a finished body file after the caller's own dedup and climb: create, the
# `__ISSUE__` substitution, assignee, board add, Priority, Status, milestone placement and
# the sub-issue link. It never creates labels and never adds a title prefix — the caller
# passes the final title and creates its labels first.
#
# Usage: create-item.sh --repo <owner/repo> --title <t> --body-file <f> --label <l>…
#                       [--project <owner/number>] [--priority top] [--status <name>]
#                       [--assignee <login> | --assign-owner]
#                       [--origin <owner/repo#n>] [--parent <owner/repo#n>]
#                       [--no-place] [--link-under <owner/repo#p>] [--cache <file>]
#                       [--decided-body-file <f>]
#
# --assignee wins over --assign-owner, which assigns the project owner's login only on a
# user-owned board. --origin/--parent go to milestone-place.sh; --parent is also the
# parent the new item is linked under. --link-under <p> links the new item under a parent
# the caller's own rule chose and skips placement, like --no-place. --cache defaults to
# ${TMPDIR:-/tmp}/kp-milestone-current-<owner>-<number>.json. Without --project the board
# add, priority, status, placement and link steps are skipped with reason `no project`.
#
# A human-gated item (a type:decision, type:question or type:conflict label) pings the
# operator on Telegram right after the create, through the send script at KP_MSG_ME_SEND
# (default ~/.claude/skills/kp-msg-me/scripts/send.sh) — NOTES.md § *Operator
# notifications*.
#
# --decided-body-file <f> files a creator-decided type:decision (NOTES.md § *Human-gated
# item body* → *Confidence and creator-decided items*): right after the substitution the
# file's `__ISSUE__` is substituted too and it is posted as the issue's first comment, the
# Status defaults to Ready so kp-do-gh-ready-items sweeps it, and the operator is pinged
# only when that comment failed or Ready did not land (board or status step skipped, no
# project) — then the item is an ordinary operator-gated one. Any other label with it is
# a usage error.
#
# Every step after the create is best-effort: a failed or skipped one is recorded as
# {"step": "<name>", "reason": "<text>"} in `skipped` (steps: substitute, decided, notify,
# assignee, board-add, priority, status, place, link) and the chain carries on. Prints one JSON
# object on stdout:
#   {"number": 12, "url": "…", "itemId": "PVTI_…" | null, "milestone": "M<k>" | null,
#    "epic": "owner/repo#e" | null, "link": "item" | "owner/repo#r" | "none",
#    "skipped": [...]}
# With --no-place / --link-under the placement fields are null, null, "none".
#
# Siblings (resolve-board.sh, item-id.sh, set-status.sh, milestone-place.sh) are found
# through KP_GH_LIB_BIN, default this script's own directory.
#
# Exit: 0 created · 1 the create failed · 2 bad arguments.
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/create_item.py "$@" </dev/null
