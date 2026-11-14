#!/usr/bin/env bash
# Classify what a child run left behind — a work item's or a PR's outcome — from GitHub
# state, never from the child's log. The loops used to restate this first-match ladder
# in prose, five times. The capacity check is the caller's, and runs before this.
#
# Usage: item-outcome.sh <owner/repo> --issue <n> --project <owner/number>
#        item-outcome.sh <owner/repo> --pr <p>
#
# Prints one line: `outcome=<o>` then only the keys that outcome sets, from
# pr=<number> decision=<number> mergeStateStatus=<value> blocker=<owner/repo>#<m>
# milestone=M<k>. --issue outcomes: merged, needs-contract, blocked-on-decision,
# waiting-on-milestone, stalled-cross-milestone, blocked-on-dependency, parked, pr-closed,
# build-failed. --pr outcomes: merged, blocked-on-decision, parked, pr-closed.
#
# Exit: 0 an outcome was printed · 1 a gh call or a sibling script failed (stdout empty)
# · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: item-outcome.sh <owner/repo> --issue <n> --project <owner/number>" \
    "| item-outcome.sh <owner/repo> --pr <p>" >&2
  exit 2
}

[ $# -ge 1 ] || usage
repo=$1
shift
[[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
issue=""
pr=""
project=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case $1 in
    --issue) issue=$2 ;;
    --pr) pr=$2 ;;
    --project) project=$2 ;;
    *) usage ;;
  esac
  shift 2
done
if [ -n "$issue" ]; then
  [ -z "$pr" ] || usage
  [[ $issue =~ ^[0-9]+$ ]] || usage
  [[ $project =~ ^[^/[:space:]]+/[0-9]+$ ]] || usage
  mode=--issue
  target=$issue
else
  [[ $pr =~ ^[0-9]+$ ]] || usage
  [ -z "$project" ] || usage
  mode=--pr
  target=$pr
fi

# Issue bodies never reach a shell: Python runs every command as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/item_outcome.py "$(dirname "$0")" "$repo" "$mode" "$target" "$project" </dev/null
