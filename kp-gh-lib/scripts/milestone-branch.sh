#!/usr/bin/env bash
# Resolves the branch an item builds against and merges into: `release/M<k>` when its
# sub-issue parent chain reaches milestone epic M<k> (milestone-of.sh), else the default
# branch (NOTES.md § *Milestone sequencing* → *Milestone branch*). With --create, a
# missing `release/M<k>` is created at the default-branch HEAD — unless an earlier
# milestone's `release/M<j>` still exists, which means its merge into the default branch
# has not happened, and milestones run strictly in order.
#
# Usage: milestone-branch.sh <owner/repo> <issue> [--create]
#
# Prints exactly one JSON line on stdout:
#   {"milestone": "M<k>" | null, "branch": "release/M<k>" | null, "exists": bool,
#    "created": bool, "default": "<default branch>"}
# No milestone: milestone and branch are null, exists and created false, nothing created.
# The earlier-unmerged guard runs only when --create would create the branch.
#
# milestone-of.sh is found through KP_GH_LIB_BIN, default this script's own directory.
# API cost: 1 GraphQL point (milestone-of.sh) and 2–5 REST calls.
#
# Exit: 0 resolved · 1 an API call or milestone-of.sh failed (stderr names it; nothing
# on stdout) · 2 bad arguments · 3 `earlier-unmerged release/M<j>` on stderr, nothing
# created.
set -euo pipefail

usage() {
  echo "usage: milestone-branch.sh <owner/repo> <issue> [--create]" >&2
  exit 2
}

create=false
positional=()
for arg in "$@"; do
  case $arg in
    --create) create=true ;;
    -*) usage ;;
    *) positional+=("$arg") ;;
  esac
done
[ ${#positional[@]} -eq 2 ] || usage
[[ ${positional[0]} =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ ${positional[1]} =~ ^[1-9][0-9]*$ ]] || usage

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/milestone_branch.py "${positional[0]}" "${positional[1]}" "$create" </dev/null
