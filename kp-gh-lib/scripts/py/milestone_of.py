import json
import re
import subprocess
import sys

repo, number = sys.argv[1:]
owner, name = repo.split("/")

# GitHub nests sub-issues at most eight levels deep, so this many parents reaches the root.
MAX_SUB_ISSUE_DEPTH = 8
ISSUE_FIELDS = "number state body repository{ nameWithOwner } labels(first:20){ nodes{ name } }"
# A loosely matched start marker up to its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
MILESTONE_REF = re.compile(r"^[ \t]*spec-ref:[ \t]*milestone:(\S+)[ \t]*$", re.M)
MILESTONE_ID = re.compile(r"M(\d+)")


def fail(message):
    print(f"milestone-of.sh: {message}", file=sys.stderr)
    sys.exit(1)


def ancestors_query():
    chain = ""
    for _ in range(MAX_SUB_ISSUE_DEPTH):
        chain = f"parent{{ {ISSUE_FIELDS} {chain} }}"
    return ("query($owner:String!,$repo:String!,$num:Int!){"
            " repository(owner:$owner,name:$repo){ issueOrPullRequest(number:$num){"
            f" ... on Issue{{ state {chain} }} ... on PullRequest{{ state }} }} }} }}")


def ref_of(issue):
    return f"{issue['repository']['nameWithOwner']}#{issue['number']}"


def milestone_id(issue):
    """The M<n> id when this issue is a milestone epic, else None."""
    if "type:epic" not in {label["name"] for label in issue["labels"]["nodes"]}:
        return None
    body = HUMAN_ONLY_FENCE.sub("", (issue["body"] or "").replace("\r\n", "\n"))
    match = MILESTONE_REF.search(body)
    if not match:
        return None
    if not MILESTONE_ID.fullmatch(match.group(1)):
        print(f"milestone-of.sh: {ref_of(issue)} marks milestone {match.group(1)!r},"
              " which is not M<number>; not treated as a milestone epic", file=sys.stderr)
        return None
    return match.group(1)


result = subprocess.run(
    ["gh", "api", "graphql", "-f", f"query={ancestors_query()}",
     "-F", f"owner={owner}", "-F", f"repo={name}", "-F", f"num={number}"],
    capture_output=True, text=True)
if result.returncode != 0:
    fail(f"cannot look up {repo}#{number}: {result.stderr.strip()}")
item = json.loads(result.stdout)["data"]["repository"]["issueOrPullRequest"]

found = {"issue": f"{repo}#{number}", "state": item["state"],
         "milestone": None, "rank": None, "epic": None, "root": f"{repo}#{number}"}
ancestor = item.get("parent")
while ancestor:
    found["root"] = ref_of(ancestor)
    milestone = None if found["milestone"] else milestone_id(ancestor)
    if milestone:
        found.update(milestone=milestone, rank=int(MILESTONE_ID.fullmatch(milestone).group(1)),
                     epic=ref_of(ancestor))
    ancestor = ancestor.get("parent")

print(json.dumps(found))
