#!/usr/bin/env bash
# Find a work item's PR: the open one, else the merged one, else none.
#
# Usage: find-task-pr.sh <owner/repo> <issue-number>
#
# Branch match first (`task/<n>-*`, via search + prefix filter, because
# `gh pr list --head` takes an exact branch name), closing-keyword references second —
# only when the branch match found no open or merged PR. A PR closed unmerged is
# history, never the item's PR, but its number is listed so a caller can still tell
# "closed" from "never opened".
#
# Prints one JSON object:
#   {"pr": {"number","state","isDraft","headRefName","mergeStateStatus"} | null,
#    "closed": [<numbers of PRs closed unmerged, ascending>]}
# Exit: 0 ok (including "pr": null) · 1 a gh call failed · 2 bad arguments.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: find-task-pr.sh <owner/repo> <issue-number>" >&2; exit 2; }
repo=$1
issue=$2
[[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] \
  || { echo "find-task-pr.sh: repo must be <owner/repo>: $repo" >&2; exit 2; }
[[ $issue =~ ^[0-9]+$ ]] || { echo "find-task-pr.sh: issue must be a number: $issue" >&2; exit 2; }

PR_FIELDS=number,state,isDraft,headRefName,mergeStateStatus
# stdin: the `gh pr list` JSON; argv: the item's branch prefix, then each
# closing-reference PR as JSON. Prints the lowest-numbered open PR, else the
# lowest-numbered merged one, else null, plus every closed-unmerged number.
PICK_PY='
import json, sys
prefix = sys.argv[1]
prs = [pr for pr in json.load(sys.stdin) if pr["headRefName"].startswith(prefix)]
prs += [json.loads(arg) for arg in sys.argv[2:]]
by_number = sorted({pr["number"]: pr for pr in prs}.values(), key=lambda pr: pr["number"])
live = [pr for state in ("OPEN", "MERGED") for pr in by_number if pr["state"] == state]
closed = [pr["number"] for pr in by_number if pr["state"] == "CLOSED"]
print(json.dumps({"pr": live[0] if live else None, "closed": closed}))
'
LINKED_PY='
import json, sys
print(*(ref["number"] for ref in json.load(sys.stdin)["closedByPullRequestsReferences"]))
'

gh_read() {
  gh "$@" || { echo "find-task-pr.sh: \`gh $*\` failed" >&2; exit 1; }
}

listed=$(gh_read pr list -R "$repo" --state all --search "head:task/$issue-" --json "$PR_FIELDS")
pick() { python3 -c "$PICK_PY" "task/$issue-" "$@" <<<"$listed"; }

by_branch=$(pick)
if [[ $by_branch != '{"pr": null,'* ]]; then
  echo "$by_branch"
  exit 0
fi

refs=$(gh_read issue view "$issue" -R "$repo" --json closedByPullRequestsReferences)
linked=$(python3 -c "$LINKED_PY" <<<"$refs")
linked_prs=()
for pr in $linked; do
  one=$(gh_read pr view "$pr" -R "$repo" --json "$PR_FIELDS")
  linked_prs+=("$one")
done
# `${a[@]+…}`: bash 3.2 (macOS) treats an empty array as unbound under `set -u`.
pick ${linked_prs[@]+"${linked_prs[@]}"}
