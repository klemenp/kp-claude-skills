#!/usr/bin/env bash
# Link an issue as a sub-issue of a parent by the NOTES.md § *Creating an item* →
# *Sub-issue linking* ladder, and optionally make sure the child is on a board — the one
# procedure for a link a skill makes outside create-item.sh.
#
# Usage: link-item.sh --parent <owner/repo#p> --child <owner/repo#c> [--project-id <id>]
#
# The child is looked up first. Already under --parent → nothing is linked again and
# `via` is "existing". Under a different parent → nothing is linked, stderr names it
# (`has parent <owner/repo#n>`) and the exit is 1: re-parenting is never this script's job.
# Otherwise the ladder runs, the first rung that succeeds wins, and each failure is one
# stderr line `<rung>: <reason>`:
#   native    — only when `gh issue edit --help` lists --add-sub-issue;
#   graphql   — the addSubIssue mutation (always available);
#   extension — only when `gh extension list` shows sub-issue; never installed here;
#   tasklist  — a `- [ ] #<c>` line (`- [ ] <owner>/<repo>#<c>` across repos) appended to
#               the parent body, unless the body already references the child.
# With --project-id the child is then put on that board (reused when item-id.sh finds it
# there, else addProjectV2ItemById), whether or not the link succeeded; a failure is one
# stderr line `board-add: <reason>`.
#
# Prints one JSON object on stdout, on every exit but 2:
#   {"linked": true|false, "via": "existing"|"native"|"graphql"|"extension"|"tasklist"|null,
#    "boardItem": "PVTI_…"|null}
# `via` is null when not linked; `boardItem` is null without --project-id or on a failure.
#
# Siblings (item-id.sh) are found through KP_GH_LIB_BIN, default this script's own
# directory.
#
# Exit: 0 linked (and, with --project-id, on the board) · 1 not linked (a lookup failed,
# the child has another parent, or every rung failed) · 2 bad arguments (no stdout, no gh
# call) · 3 linked but the board add failed.
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/link_item.py "$@" </dev/null
