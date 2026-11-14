#!/usr/bin/env bash
# The one setup preamble the kp-* GitHub skills share: repo guard, auth check, sync,
# project resolve, board fields, and the work item's id on that board — never
# `gh project field-list` or a board-wide `gh project item-list`.
#
# Usage: preamble.sh (--issue <n> | --pr <n> | --no-item)
#                    [--project <number|owner/number|id>] [--no-fetch]
#
# Run from inside the target checkout. Prints one JSON object on stdout:
#   {"repo": "owner/name", "defaultBranch": "main",
#    "project": {"owner": "…", "number": 4, "id": "PVT_…", "ownerType": "user"},
#    "status":   {"fieldId": "PVTSSF_…", "options": {"<name>": "<id>", …}} | null,
#    "priority": {"fieldId": "PVTSSF_…", "options": {…}, "top": "<id>"} | null,
#    "issue": <n> | null, "itemId": "PVTI_…" | null, "itemStatus": "<name>" | null,
#    "pr": {"number": …, "head": "…", "headSha": "…", "base": "…",
#           "isDraft": false, "state": "OPEN"} | null}
#
# With --pr the linked issue is the PR's first closing reference, or, when GitHub lists
# none (it lists them only for a default-branch base), the first closing keyword in its
# body (`Closes #<n>`); a PR that closes none
# leaves `issue`, `itemId` and `itemStatus` null and the caller resolves the work item
# its own way. With --no-item (a caller that needs the repo, project and board fields but
# no single work item, such as a creator) the PR read, the item lookup and the board add
# are all skipped: `issue`, `itemId`, `itemStatus` and `pr` are null and nothing is
# written to the board. An issue not yet on the board is added with the addProjectV2ItemById
# mutation, whose response carries the new item's id — a freshly added item has no
# Status, so nothing is looked up again.
#
# The board is best-effort: a Projects v2 failure warns on stderr and nulls `project.id`,
# `status`, `priority`, `itemId` and `itemStatus` rather than failing the run, so a board
# glitch never blocks the caller's real work. The repo and the PR are not — without them
# there is nothing to work on.
#
# Cost: 2 GraphQL points on --no-item, 3 on --issue and 4 on --pr, plus one each for a
# node-id --project, an issue that has to be added to the board, and an
# organization-owned board (resolve-board.sh tries user(login:) first).
#
# Exit: 0 ok · 5 guard or auth · 6 project unresolved (candidates on stderr)
#     · 1 a GitHub failure that leaves nothing to work on · 2 usage.
set -euo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  echo "usage: preamble.sh (--issue <n> | --pr <n> | --no-item) [--project <number|owner/number|id>] [--no-fetch]" >&2
  exit 2
}

die() {
  printf 'preamble.sh: %s\n' "$1" >&2
  exit "${2:-1}"
}

# A Projects v2 failure is noted, not fatal: the caller still gets the repo, the PR and
# the issue, with the board fields null, and skips its board writes as best-effort.
warn_board() {
  printf 'preamble.sh: %s — continuing without board ids\n' "$1" >&2
}

issue=
pr=
no_item=
project_arg=
fetch=yes
while [ $# -gt 0 ]; do
  case $1 in
    --issue) [ $# -ge 2 ] || usage; issue=$2; shift 2 ;;
    --pr) [ $# -ge 2 ] || usage; pr=$2; shift 2 ;;
    --no-item) no_item=yes; shift ;;
    --project) [ $# -ge 2 ] || usage; project_arg=$2; shift 2 ;;
    --no-fetch) fetch=no; shift ;;
    *) usage ;;
  esac
done
# Exactly one of --issue, --pr and --no-item.
modes=0
for mode in "$issue" "$pr" "$no_item"; do
  [ -z "$mode" ] || modes=$((modes + 1))
done
[ "$modes" -eq 1 ] || usage
[ -z "$issue" ] || [[ $issue =~ ^[0-9]+$ ]] || usage
[ -z "$pr" ] || [[ $pr =~ ^[0-9]+$ ]] || usage

# 1. Repo guard and auth check.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "not inside a git work tree — run this from the target checkout" 5
gh auth status >/dev/null 2>&1 \
  || die "gh is not authenticated — run: gh auth login" 5

repo_json=$(gh repo view --json nameWithOwner,defaultBranchRef 2>&1) \
  || die "cannot read the repo of this checkout: $repo_json"
read -r repo default_branch < <(printf '%s' "$repo_json" | python3 -c '
import json, sys
repo = json.load(sys.stdin)
print(repo["nameWithOwner"], (repo["defaultBranchRef"] or {}).get("name") or "-")
')
[ -n "$repo" ] || die "cannot read the repo of this checkout"

# 2. Sync, so the base branch, PR head refs and CI status reflect the remote. The pull is
# skipped on a dirty tree: the fetch alone already updates the refs worktrees are cut from.
if [ "$fetch" = yes ]; then
  git fetch origin --prune >/dev/null 2>&1 \
    || echo "preamble.sh: warning: git fetch origin failed" >&2
  if [ -z "$(git status --porcelain)" ]; then
    git pull origin "$(git rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1 \
      || echo "preamble.sh: warning: git pull origin failed — building on the local branch" >&2
  fi
fi

# 3. Resolve the project: --project → .claude/spec-sync.json → exit 6 with candidates.
# A node id carries neither owner nor number, so it costs one extra point to expand.
# $id below is a GraphQL variable, not a shell expansion.
# shellcheck disable=SC2016
PROJECT_BY_ID='query($id:ID!){ node(id:$id){ ... on ProjectV2 { number
  owner { ... on User { login } ... on Organization { login } } } } }'

# Prints "<owner> <number>" for a PVT_… project node id.
expand_project_id() {
  local response
  response=$(gh api graphql -f query="$PROJECT_BY_ID" -F id="$1" 2>&1) \
    || die "cannot resolve project id $1: $response"
  printf '%s' "$response" | python3 -c '
import json, sys
node = json.load(sys.stdin)["data"]["node"] or {}
if not node.get("number"):
    sys.exit("no project has that node id")
print(node["owner"]["login"], node["number"])
' || die "cannot resolve project id $1"
}

project_owner=
project_number=
if [[ $project_arg =~ ^[0-9]+$ ]]; then
  project_owner=${repo%%/*}
  project_number=$project_arg
elif [[ $project_arg =~ ^([^/[:space:]]+)/([0-9]+)$ ]]; then
  project_owner=${BASH_REMATCH[1]}
  project_number=${BASH_REMATCH[2]}
elif [ -n "$project_arg" ]; then
  expanded=$(expand_project_id "$project_arg")
  read -r project_owner project_number <<<"$expanded"
fi

config=$(git rev-parse --show-toplevel)/.claude/spec-sync.json
if [ -z "$project_number" ] && [ -f "$config" ]; then
  # "<owner> <number>" when the config names both, else the bare node id, else empty.
  configured=$(python3 -c '
import json, sys
project = json.load(open(sys.argv[1])).get("project") or {}
owner, number, node_id = project.get("owner"), project.get("number"), project.get("id")
print(f"{owner} {number}" if owner and number else (node_id or ""))
' "$config") || die "cannot read $config"
  if [[ $configured =~ ^([^/[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
    project_owner=${BASH_REMATCH[1]}
    project_number=${BASH_REMATCH[2]}
  elif [ -n "$configured" ]; then
    expanded=$(expand_project_id "$configured")
    read -r project_owner project_number <<<"$expanded"
  fi
fi

if [ -z "$project_owner" ] || [ -z "$project_number" ]; then
  {
    printf 'preamble.sh: no project given and none in .claude/spec-sync.json.\n'
    printf 'Pass --project <number|owner/number|id>. Candidates:\n'
    # Both lists, deduplicated: the repo owner is often the authenticated user.
    { gh project list --owner "${repo%%/*}" 2>&1 || true
      gh project list --owner @me 2>&1 || true; } | awk '!seen[$0]++'
  } >&2
  exit 6
fi

# 4. Board fields — 1 point (2 when the owner turns out to be an organization).
project_id=
if board_json=$("$LIB_DIR/resolve-board.sh" "$project_owner" "$project_number"); then
  project_id=$(printf '%s' "$board_json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["projectId"])')
else
  board_json=null
  warn_board "cannot resolve board $project_owner/$project_number"
fi

# 5. The work item's issue. With --pr it is the PR's first closing reference.
# GitHub fills closingIssuesReferences only for a PR into the default branch (verified on
# #347, base throwaway/341-base, 2026-11-08), so a PR into release/M<k> falls back to the
# body's first closing keyword — pr-loop.sh's CLOSING_REF pattern.
# Steps 5 and 6 do nothing on --no-item: it sets neither $pr nor $issue.
pr_json=null
if [ -n "$pr" ]; then
  pr_json=$(gh pr view "$pr" --json number,headRefName,headRefOid,baseRefName,isDraft,state,closingIssuesReferences,body 2>&1) \
    || die "cannot read PR #$pr: $pr_json"
  issue=$(printf '%s' "$pr_json" | python3 -c '
import json, re, sys
CLOSING_REF = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b", re.I)
pull = json.load(sys.stdin)
closing = pull["closingIssuesReferences"]
keyword = CLOSING_REF.search(pull.get("body") or "")
if closing:
    print(closing[0]["number"])
elif keyword:
    print(keyword.group(1))
else:
    print("")
')
fi

# 6. The item on the board — 1 point, from the issue side; add it when missing.
# The add is the 1-point mutation, not `gh project item-add`: that CLI re-resolves the
# project and the content itself and measures 4 points, where the mutation costs 1 and the
# add path stays within the ceiling. A freshly added item has no Status, so `itemStatus`
# stays null and no second lookup is needed.
# $project/$content below are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016
ADD_ITEM='mutation($project:ID!,$content:ID!){
  addProjectV2ItemById(input:{projectId:$project,contentId:$content}){ item{ id } } }'

item_json=null
if [ -n "$issue" ] && [ -n "$project_id" ]; then
  if item_json=$("$LIB_DIR/item-id.sh" "$repo" "$issue" "$project_id"); then
    content_id=$(printf '%s' "$item_json" | python3 -c '
import json, sys
item = json.load(sys.stdin)
print("" if item["itemId"] else item["contentId"])
')
  else
    item_json=null
    content_id=
    warn_board "cannot look up $repo#$issue on board $project_owner/$project_number"
  fi
  if [ -n "$content_id" ]; then
    if response=$(gh api graphql -f query="$ADD_ITEM" -F project="$project_id" \
      -F content="$content_id" 2>&1); then
      item_json=$(printf '%s' "$response" | python3 -c '
import json, sys
item = json.load(sys.stdin)["data"]["addProjectV2ItemById"]["item"]
print(json.dumps({"itemId": item["id"], "status": None, "statusOptionId": None}))
') || { item_json=null; warn_board "cannot read the item added for $repo#$issue"; }
    else
      item_json=null
      warn_board "cannot add $repo#$issue to project $project_owner/$project_number: $response"
    fi
  fi
fi

REPO=$repo DEFAULT_BRANCH=$default_branch PROJECT_OWNER=$project_owner \
PROJECT_NUMBER=$project_number ISSUE=${issue:-} \
BOARD=$board_json ITEM=$item_json PR=$pr_json python3 -c '
import json, os


def by_name(raw):
    """resolve-board.sh gives options in board order; callers want them by name."""
    if not raw:
        return None
    return {"fieldId": raw["fieldId"],
            "options": {option["name"]: option["id"] for option in raw["options"]}}


# A board this run could not reach is null here: every board-derived field goes null,
# which tells the caller to skip its board writes (see warn_board above).
board = json.loads(os.environ["BOARD"]) or {"projectId": None, "ownerType": None,
                                            "status": None, "priority": None}
item = json.loads(os.environ["ITEM"]) or {}
pull = json.loads(os.environ["PR"])
issue = os.environ["ISSUE"]

priority = by_name(board["priority"])
if priority:
    # Board order puts the highest priority first.
    options = board["priority"]["options"]
    priority["top"] = options[0]["id"] if options else None

print(json.dumps({
    "repo": os.environ["REPO"],
    "defaultBranch": os.environ["DEFAULT_BRANCH"] if os.environ["DEFAULT_BRANCH"] != "-" else None,
    "project": {"owner": os.environ["PROJECT_OWNER"],
                "number": int(os.environ["PROJECT_NUMBER"]),
                "id": board["projectId"], "ownerType": board["ownerType"]},
    "status": by_name(board["status"]),
    "priority": priority,
    "issue": int(issue) if issue else None,
    "itemId": item.get("itemId"),
    "itemStatus": item.get("status"),
    "pr": {"number": pull["number"], "head": pull["headRefName"],
           "headSha": pull["headRefOid"], "base": pull["baseRefName"],
           "isDraft": pull["isDraft"], "state": pull["state"]} if pull else None,
}))
'
