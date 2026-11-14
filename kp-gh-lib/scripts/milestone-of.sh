#!/usr/bin/env bash
# Find the milestone an issue belongs to: its nearest ancestor that is a milestone epic
# (labelled type:epic, carrying `spec-ref: milestone:M<n>` outside the human-only fence).
# Walks the native sub-issue parent chain from the issue side in one 1-point GraphQL
# query — never by scanning the board. A pull request is accepted too: it has no parent,
# so it has no milestone.
#
# Usage: milestone-of.sh <owner/repo> <issue-or-pr>
#
# Prints one JSON object on stdout:
#   {"issue": "owner/repo#n", "state": "OPEN" | "CLOSED" | "MERGED",
#    "milestone": "M<n>" | null, "rank": <n> | null, "epic": "owner/repo#e" | null,
#    "root": "owner/repo#r"}
# state is the item's own: MERGED only for a pull request, whose CLOSED means closed
# unmerged. milestone is null when no ancestor is a milestone epic: the item is outside
# the milestone rules. rank is the id's number, the order milestones run in (M9 before M10).
# root is the topmost ancestor on the sub-issue parent chain, or the item itself when it
# has no parent.
#
# Exit: 0 looked up · 1 lookup failed (no such issue or PR, API error) · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: milestone-of.sh <owner/repo> <issue-or-pr>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
[[ $1 =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ $2 =~ ^[0-9]+$ ]] || usage

# Issue bodies never reach a shell: Python runs gh as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/milestone_of.py "$@" </dev/null
