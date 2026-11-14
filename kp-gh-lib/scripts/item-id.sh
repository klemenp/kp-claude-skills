#!/usr/bin/env bash
# Find an issue's item on one GitHub Project (v2) board, from the issue side, in one
# 1-point GraphQL query — never by scanning the board.
#
# Usage: item-id.sh <owner/repo> <issue> <project-id>
#
# Prints one JSON object on stdout:
#   {"itemId": "PVTI_…" | null, "status": "<Status option name>" | null,
#    "statusOptionId": "<option id>" | null, "contentId": "I_…"}
# itemId is null when the issue is not on that board; contentId is the issue's own node
# id, which a caller adding it to the board needs (one more field costs no extra point). An issue can sit on several
# boards; only the item whose project id equals <project-id> counts.
#
# Exit: 0 looked up · 1 lookup failed (no such issue, API error) · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: item-id.sh <owner/repo> <issue> <project-id>" >&2
  exit 2
}

[ $# -eq 3 ] || usage
repo_ref=$1
issue=$2
project_id=$3
[[ $repo_ref =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
[[ $issue =~ ^[0-9]+$ ]] || usage
[ -n "$project_id" ] || usage

# $owner/$repo/$num below are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016
ITEM_QUERY='query($owner:String!,$repo:String!,$num:Int!){
  repository(owner:$owner,name:$repo){ issue(number:$num){ id
    projectItems(first:5){ nodes{ id project{ id number }
      fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name optionId } } } } } } }'

if ! response=$(gh api graphql -f query="$ITEM_QUERY" -F owner="${repo_ref%%/*}" \
    -F repo="${repo_ref#*/}" -F num="$issue" 2>/dev/null); then
  printf 'item-id.sh: cannot look up %s#%s: %s\n' "$repo_ref" "$issue" "$response" >&2
  exit 1
fi

printf '%s' "$response" | python3 -c '
import json, sys

project_id = sys.argv[1]
issue = json.load(sys.stdin)["data"]["repository"]["issue"]
nodes = issue["projectItems"]["nodes"]
item = next((node for node in nodes if node["project"]["id"] == project_id), None)
status = (item or {}).get("fieldValueByName") or {}
print(json.dumps({"itemId": item["id"] if item else None,
                  "status": status.get("name"), "statusOptionId": status.get("optionId"),
                  "contentId": issue["id"]}))
' "$project_id"
