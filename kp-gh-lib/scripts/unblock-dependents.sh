#!/usr/bin/env bash
# Move the dependents of a merged work item from Blocked to Ready on one GitHub
# Project (v2) board, once nothing else blocks them. Dependents are found with REST issue
# search — never by enumerating the board.
#
# Usage: unblock-dependents.sh <owner/repo> <issue-or-pr> <project-id> <status-field-id> \
#          <blocked-option-id> <ready-option-id>
#
# <issue-or-pr> is the merged work item: the issue a merged PR closed, or the merged PR
# itself when it closes no issue. A dependent is an issue whose body, outside the
# human-only fence, carries the line `blocked-by: #<n>` (in <owner/repo>) or
# `blocked-by: <owner/repo>#<n>` (in any repo of <owner>), <n> being that number. It moves
# to Ready only when it is open, labelled type:coding, Blocked on this board, every
# blocked-by: blocker it lists is done — an issue once closed, a pull request once merged
# (one closed unmerged still blocks) — and no open type:decision / type:question /
# type:conflict issue blocks it (the kp-do-gh-task-loop §1.3 check). Every other
# dependent is left untouched.
#
# Prints one JSON object on stdout:
#   {"promoted": ["owner/repo#n", …],
#    "skipped": [{"issue": "owner/repo#n", "reason": "…"}, …]}
#
# Exit: 0 completed (including no dependents) · 1 a lookup or write failed · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: unblock-dependents.sh <owner/repo> <issue-or-pr> <project-id> <status-field-id>" \
    "<blocked-option-id> <ready-option-id>" >&2
  exit 2
}

[ $# -eq 6 ] || usage
[[ $1 =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ $2 =~ ^[0-9]+$ ]] || usage
for board_id in "$3" "$4" "$5" "$6"; do
  [ -n "$board_id" ] || usage
done

# Issue titles, bodies and comments never reach a shell: Python runs every gh call as an
# argument vector and handles bodies only as strings.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/unblock_dependents.py "$(dirname "$0")/item-id.sh" "$@" </dev/null
