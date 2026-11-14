#!/usr/bin/env bash
# Find the work item a PR belongs to.
#
# Usage: linked-item.sh <owner/repo> <pr-number>
#
# One `gh pr view` read. The human-only fence is dropped from the PR body first, then
# the first rule that matches wins:
#   1. closes  — a GitHub closing keyword on a same-repo `#<n>` in the body, first in
#                body order (a cross-repo `owner/repo#<n>` does not match);
#   2. branch  — a `task/<n>-*` head branch;
#   3. spec-pr — a `spec/resolve-<n>` head branch whose body carries
#                `Refs <owner>/<repo>#<n>` with the same <n>: a kp-resolve-spec-decision
#                spec PR, linked to that decision issue rather than to a work item;
#   4. spec-pr — a `spec/resolve-<n>-batch` head branch: a batched spec PR, linked to
#                every decision whose `## <owner>/<repo>#<n>:` heading is in the body, in
#                body order, each once. The branch's <n> need not be among them; no
#                heading is no link.
# When an issue is found, one `gh issue view` sets `referenceOnly`: true exactly when it
# is CLOSED and labelled `type:research` (kp-do-gh-pr-loop §1).
#
# Prints one JSON object:
#   {"issue": <n>|null, "via": "closes"|"branch"|"spec-pr"|null,
#    "decision": "<owner>/<repo>#<n>"|null, "decisions": ["<owner>/<repo>#<n>", …],
#    "referenceOnly": true|false}
# `decision` is the first entry of `decisions` (null when it is empty).
# Exit: 0 answered (including no link) · 1 a gh call failed · 2 bad arguments.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: linked-item.sh <owner/repo> <pr-number>" >&2; exit 2; }
repo=$1
pr=$2
[[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] \
  || { echo "linked-item.sh: repo must be <owner/repo>: $repo" >&2; exit 2; }
[[ $pr =~ ^[0-9]+$ ]] || { echo "linked-item.sh: pr must be a number: $pr" >&2; exit 2; }

# stdin: the `gh pr view` JSON. Prints {"issue","via","decision","decisions"}. The fence and
# closing-keyword patterns are pr-loop.sh's HUMAN_ONLY_FENCE and CLOSING_REF.
LINK_PY='
import json, re, sys
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
CLOSING_REF = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b", re.I)
TASK_BRANCH = re.compile(r"^task/(\d+)-")
SPEC_BRANCH = re.compile(r"^spec/resolve-(\d+)$")
SPEC_REFS = re.compile(r"\bRefs\s+([^\s/#]+/[^\s/#]+)#(\d+)\b")
SPEC_BATCH_BRANCH = re.compile(r"^spec/resolve-(\d+)-batch$")
# Exactly two "#" then a space or tab, so a "###" heading never matches.
BATCH_SECTION = re.compile(r"^##[ \t]+([^\s/#]+/[^\s/#]+)#(\d+):", re.M)

pr = json.load(sys.stdin)
body = HUMAN_ONLY_FENCE.sub("", pr.get("body") or "")
branch = pr.get("headRefName") or ""
link = {"issue": None, "via": None, "decision": None, "decisions": []}

closing = CLOSING_REF.search(body)
task = TASK_BRANCH.match(branch)
spec = SPEC_BRANCH.match(branch)
batch = SPEC_BATCH_BRANCH.match(branch)
if closing:
    link.update(issue=int(closing.group(1)), via="closes")
elif task:
    link.update(issue=int(task.group(1)), via="branch")
elif spec:
    for match in SPEC_REFS.finditer(body):
        if int(match.group(2)) == int(spec.group(1)):
            decision = f"{match.group(1)}#{match.group(2)}"
            link.update(via="spec-pr", decision=decision, decisions=[decision])
            break
elif batch:
    decisions = []
    for match in BATCH_SECTION.finditer(body):
        decision = f"{match.group(1)}#{int(match.group(2))}"
        if decision not in decisions:
            decisions.append(decision)
    if decisions:
        link.update(via="spec-pr", decision=decisions[0], decisions=decisions)
print(json.dumps(link))
'
# stdin: the `gh issue view` JSON. Prints true or false.
REFERENCE_ONLY_PY='
import json, sys
issue = json.load(sys.stdin)
labels = {label["name"] for label in issue.get("labels") or []}
print(json.dumps(issue.get("state") == "CLOSED" and "type:research" in labels))
'
# argv: the link JSON, then referenceOnly. Prints the final object.
MERGE_PY='
import json, sys
link = json.loads(sys.argv[1])
link["referenceOnly"] = json.loads(sys.argv[2])
print(json.dumps(link))
'

gh_read() {
  gh "$@" || { echo "linked-item.sh: \`gh $*\` failed" >&2; exit 1; }
}

view=$(gh_read pr view "$pr" -R "$repo" --json body,headRefName)
link=$(python3 -c "$LINK_PY" <<<"$view")
issue=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["issue"] or "")' "$link")

reference_only=false
if [ -n "$issue" ]; then
  state=$(gh_read issue view "$issue" -R "$repo" --json state,labels)
  reference_only=$(python3 -c "$REFERENCE_ONLY_PY" <<<"$state")
fi
python3 -c "$MERGE_PY" "$link" "$reference_only"
