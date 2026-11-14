#!/usr/bin/env bash
# Move a Projects v2 item's single-select field — the board's Status — to one option,
# with the `updateProjectV2ItemFieldValue` mutation. `gh project item-edit` is the
# obvious command and the one that has silently failed to move Status across runs; this
# is the path that works, in one place instead of eight prose blocks.
#
# Usage: set-status.sh <project-id> <item-id> <field-id> <option-id>
#
# The ids are the ones `resolve-board.sh` / `preamble.sh` and `item-id.sh` already
# returned. Prints the move as JSON on stdout:
#   {"itemId": "PVTI_…", "fieldId": "PVTSSF_…", "optionId": "47fc9ee4"}
#
# One 1-point GraphQL mutation, bounded by GH_TIMEOUT_SECONDS (default 30).
# Exit: 0 moved · 1 the mutation failed (stderr carries the GraphQL errors) · 2 bad
# arguments.
set -euo pipefail

GH_TIMEOUT_SECONDS=${GH_TIMEOUT_SECONDS:-30}

usage() {
  echo "usage: set-status.sh <project-id> <item-id> <field-id> <option-id>" >&2
  exit 2
}

[ $# -eq 4 ] || usage
project_id=$1
item_id=$2
field_id=$3
option_id=$4
for argument in "$project_id" "$item_id" "$field_id" "$option_id"; do
  [ -n "$argument" ] || usage
done

# $project/$item/$field/$option below are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016
MUTATION='mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){
  updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,
    value:{singleSelectOptionId:$option}}){ projectV2Item{ id } } }'

# `-f` (raw string), never `-F`: `-F` coerces an all-digit option id such as `98236657`
# to a JSON number, which the `String!` variable rejects.
# `timeout(1)` is not in base macOS, so the call is bounded by a watchdog instead. The
# watchdog's own output goes to /dev/null: sharing the caller's pipe would hold the
# command substitution open for the full timeout even after gh returns.
run_bounded() {
  local pid killer code=0
  "$@" &
  pid=$!
  ( sleep "$GH_TIMEOUT_SECONDS"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" || code=$?
  kill -TERM "$killer" >/dev/null 2>&1 || true
  return "$code"
}

if ! response=$(run_bounded gh api graphql -f query="$MUTATION" \
  -f project="$project_id" -f item="$item_id" -f field="$field_id" \
  -f option="$option_id" 2>&1); then
  printf 'set-status.sh: cannot move %s to option %s: %s\n' \
    "$item_id" "$option_id" "${response:-timed out after ${GH_TIMEOUT_SECONDS}s}" >&2
  exit 1
fi

# A 200 can still carry `errors` alongside a null payload — that is a failed move.
if printf '%s' "$response" | grep -q '"errors"'; then
  printf 'set-status.sh: cannot move %s to option %s: %s\n' \
    "$item_id" "$option_id" "$response" >&2
  exit 1
fi

printf '{"itemId": "%s", "fieldId": "%s", "optionId": "%s"}\n' \
  "$item_id" "$field_id" "$option_id"
