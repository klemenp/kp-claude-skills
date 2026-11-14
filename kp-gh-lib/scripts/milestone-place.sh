#!/usr/bin/env bash
# Decide where a newly created item goes in the milestone-epic tree (NOTES.md
# § *Milestone sequencing* → *Every new item has a milestone*). Makes no GitHub call of
# its own: it runs milestone-gate.sh --current (at most once per --cache file) and
# milestone-of.sh on the --parent and --origin items.
#
# Usage: milestone-place.sh --project <owner/number> --repo <owner/repo> --cache <file>
#                           [--origin <owner/repo#n>] [--parent <owner/repo#n>]
#
# --repo is the repo the new item is filed in; --origin the existing item whose work
# produced it; --parent the parent the creating skill links it to, never a milestone
# epic (milestone-of.sh reads only ancestors, so one would look unplaced). --cache holds the
# run's `milestone-gate.sh --current` result: read when the file exists, else looked up
# and written there on success.
#
# Prints one JSON object on stdout:
#   {"milestone": "M<k>" | null, "epic": "owner/repo#e" | null,
#    "link": "item" | "none" | "owner/repo#r"}
# milestone is null when the project uses no milestones. link "item" means link the new
# item under epic; "owner/repo#r" means link that chain root (the parent's) under epic;
# "none" means link nothing — no milestones, or the parent already has one.
#
# Exit: 0 placed · 1 a lookup failed (a looked-up script exited non-zero, its stderr
# passed through; or an unreadable --cache file) · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: milestone-place.sh --project <owner/number> --repo <owner/repo> --cache <file>" \
    "[--origin <owner/repo#n>] [--parent <owner/repo#n>]" >&2
  exit 2
}

project="" repo="" cache="" origin="" parent=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --project) project=$2 ;;
    --repo) repo=$2 ;;
    --cache) cache=$2 ;;
    --origin) origin=$2 ;;
    --parent) parent=$2 ;;
    *) usage ;;
  esac
  shift 2
done

[[ $project =~ ^[^/[:space:]]+/[0-9]+$ ]] || usage
[[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[ -n "$cache" ] || usage
item_ref='^[^/[:space:]]+/[^/[:space:]#]+#[0-9]+$'
[ -z "$origin" ] || [[ $origin =~ $item_ref ]] || usage
[ -z "$parent" ] || [[ $parent =~ $item_ref ]] || usage

scripts="$(dirname "$0")"
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/milestone_place.py "$scripts/milestone-gate.sh" "$scripts/milestone-of.sh" \
  "$project" "$repo" "$cache" "$origin" "$parent" </dev/null
