#!/usr/bin/env bash
# Resolve a GitHub Project (v2) board: its node id plus the Status and Priority
# single-select fields and their option ids, in one 1-point GraphQL query.
#
# Usage: resolve-board.sh <owner> <number>
#
# Prints one JSON object on stdout:
#   {"projectId": "PVT_…", "ownerType": "user" | "organization",
#    "status":   {"fieldId": "PVTSSF_…", "options": [{"id": "…", "name": "…"}, …]} | null,
#    "priority": {"fieldId": "PVTSSF_…", "options": [{"id": "…", "name": "…"}, …]} | null}
# Options keep board order. A field the board lacks is null, not an error.
#
# Exit: 0 resolved · 1 the board could not be resolved · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: resolve-board.sh <owner> <number>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
owner=$1
number=$2
[ -n "$owner" ] || usage
[[ $number =~ ^[0-9]+$ ]] || usage

# Fields are picked by name client-side: field(name:"X") exits 1 on a board lacking X.
# $owner/$number below are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016
BOARD_QUERY='query($owner:String!,$number:Int!){
  OWNER_KIND(login:$owner){ projectV2(number:$number){ id
    fields(first:50){ nodes{ ... on ProjectV2SingleSelectField{ id name options{ id name } } } } } } }'

run_query() {
  gh api graphql -f query="${BOARD_QUERY//OWNER_KIND/$1}" \
    -F owner="$owner" -F number="$number" 2>/dev/null
}

fail() {
  printf 'resolve-board.sh: cannot resolve project %s/%s: %s\n' "$owner" "$number" "$1" >&2
  exit 1
}

owner_type=user
if ! response=$(run_query user); then
  # A user-login miss answers "user":null — the org-owned signal, not a failure.
  [[ $response == *'"user":null'* ]] || fail "$response"
  owner_type=organization
  response=$(run_query organization) || fail "$response"
fi

printf '%s' "$response" | python3 -c '
import json, sys

owner_type = sys.argv[1]
project = json.load(sys.stdin)["data"][owner_type]["projectV2"]
# Fields that are not single-select come back as empty nodes.
fields = {node["name"]: node for node in project["fields"]["nodes"] if node}


def pick(name):
    field = fields.get(name)
    return {"fieldId": field["id"], "options": field["options"]} if field else None


print(json.dumps({"projectId": project["id"], "ownerType": owner_type,
                  "status": pick("Status"), "priority": pick("Priority")}))
' "$owner_type"
