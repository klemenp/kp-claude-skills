#!/usr/bin/env bash
# Collect a research item's open PRs and add each to the board — the research PRs
# `kp-resolve-spec-research` §6.1.1 drives through a pr-loop.
#
# Usage: research-prs.sh <owner/repo> <n> --project-id <ID>
#
# Collect: one `gh pr list --state open --limit 100` in <owner/repo>. A PR is kept when its
# head branch starts with `research/<n>-` or its body references `#<n>` not followed by a
# digit, and dropped when its body carries a closing keyword (close/closes/closed,
# fix/fixes/fixed, resolve/resolves/resolved — any case — then whitespace, then `#<m>`)
# naming an <m> other than <n>: that PR belongs to the item it closes.
#
# Board add: for each kept PR, in ascending number, the 1-point `addProjectV2ItemById`
# mutation, which returns the existing item when the PR is already on the board. No
# board-wide read and no field list. A failed add is best-effort: that PR's `boardItem`
# is null, one stderr line names it, and the exit stays 0.
#
# Prints a JSON array, ascending by number, `[]` when nothing matches:
#   [{"number": n, "url": "…", "boardItem": "<project item id>" | null}, …]
# Exit: 0 listed (including `[]`) · 1 the `gh pr list` call failed · 2 bad arguments.
#
# PR bodies never reach a shell: Python runs every gh call as an argument vector.
set -euo pipefail

usage() {
  echo "usage: research-prs.sh <owner/repo> <n> --project-id <ID>" >&2
  exit 2
}

positional=()
project_id=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project-id)
      [ $# -ge 2 ] || usage
      project_id=$2
      shift 2
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
[ ${#positional[@]} -eq 2 ] || usage
[ -n "$project_id" ] || usage
repo=${positional[0]}
issue=${positional[1]}
[[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] \
  || { echo "research-prs.sh: repo must be <owner/repo>: $repo" >&2; usage; }
[[ $issue =~ ^[1-9][0-9]*$ ]] \
  || { echo "research-prs.sh: <n> must be a positive integer: $issue" >&2; usage; }

python3 "$(dirname "${BASH_SOURCE[0]}")"/py/research_prs.py "$repo" "$issue" "$project_id" </dev/null
