#!/usr/bin/env bash
# Report the state of every `blocked-by:` blocker of an item — done, later-milestone,
# in flight — so the loops read those facts instead of restating the lookups in prose.
#
# Usage: blocker-state.sh <owner/repo> <issue>
#
# Prints one JSON array, one object per blocker in first-appearance order:
#   [{"blocker": "owner/repo#m", "kind": "issue" | "pr", "state": "OPEN" | "CLOSED" | "MERGED",
#     "done": bool, "milestone": "M<k>" | null, "laterMilestone": bool, "inFlight": bool}, …]
# done: an issue once CLOSED, a pull request only once MERGED. laterMilestone: an open
# issue blocker whose milestone ranks after the item's (M10 after M9), both ends having
# one. inFlight: not done, and an open PR — or an open issue with an open task PR
# (find-task-pr.sh). An item with no blocker prints [] after one GitHub call.
#
# Exit: 0 reported · 1 a lookup failed (stdout empty) · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: blocker-state.sh <owner/repo> <issue>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
[[ $1 =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ $2 =~ ^[0-9]+$ ]] || usage

# Issue bodies never reach a shell: Python runs every command as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/blocker_state.py "$(dirname "$0")" "$@" </dev/null
