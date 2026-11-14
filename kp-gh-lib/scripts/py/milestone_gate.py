import collections
import functools
import itertools
import json
import re
import subprocess
import sys

milestone_of_script, project, *target = sys.argv[1:]

# A loosely matched start marker up to its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
MILESTONE_REF = re.compile(r"^[ \t]*spec-ref:[ \t]*milestone:(M(\d+))[ \t]*$", re.M)
BLOCKED_BY = re.compile(r"^[ \t]*blocked-by:[ \t]*([\w.-]+/[\w.-]+)?#(\d+)[ \t]*$", re.M)
AUDIT_UNIT = re.compile(r"^[ \t]*audit-unit:[ \t]*milestone:(M\d+)[ \t]*$", re.M)
AUDIT_FILED = re.compile(r"^[ \t]*audit-filed:[ \t]*(.*?)[ \t]*$", re.M)
AUDIT_CLOSE = re.compile(r"^[ \t]*audit-close:[ \t]*(M\d+)[ \t]*$", re.M)
# One page of an epic's children: a 1-point query.
SUB_ISSUES_QUERY = """query($id:ID!,$after:String){ node(id:$id){ ... on Issue{
  subIssues(first:50, after:$after){ pageInfo{ hasNextPage endCursor }
    nodes{ id number state closedAt body repository{ nameWithOwner }
      labels(first:20){ nodes{ name } } } } } } }"""
# The project's linked repositories, whether its owner is a user or an organization.
PROJECT_REPOS_QUERY = """query($owner:String!,$number:Int!){ repositoryOwner(login:$owner){
  ... on ProjectV2Owner{ projectV2(number:$number){
    repositories(first:100){ nodes{ nameWithOwner } } } } } }"""


def fail(message):
    print(f"milestone-gate.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run(command, what=None):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{what or ' '.join(command[:3])} failed: {result.stderr.strip()}")
    return result.stdout


def outside_fence(body):
    return HUMAN_ONLY_FENCE.sub("", (body or "").replace("\r\n", "\n"))


def labels_of(issue):
    return {label["name"] for label in issue["labels"]["nodes"]}


def milestone_marker(issue):
    """(id, rank) when this issue is a milestone epic, else None."""
    if "type:epic" not in labels_of(issue):
        return None
    match = MILESTONE_REF.search(outside_fence(issue["body"]))
    return (match.group(1), int(match.group(2))) if match else None


@functools.cache
def milestone_of(ref):
    target_repo, target_number = ref.split("#")
    return json.loads(run([milestone_of_script, target_repo, target_number]))


def search_issues(query):
    pages = json.loads(run(["gh", "api", "-X", "GET", "search/issues", "--paginate", "--slurp",
                            "-f", f"q={query}", "-f", "per_page=100"]))
    hits = [hit for page in pages for hit in page["items"]]
    for hit in hits:
        hit["labels"] = {"nodes": hit["labels"]}
    return hits


def project_repos(project):
    """The nameWithOwner of every repository linked to the project; fails when the project
    is missing or links none, since the gate would then count nothing."""
    owner, project_number = project.split("/")
    what = f"project {project} repositories lookup"
    response = json.loads(run(["gh", "api", "graphql", "-f", f"query={PROJECT_REPOS_QUERY}",
                               "-f", f"owner={owner}", "-F", f"number={project_number}"], what))
    board = ((response.get("data") or {}).get("repositoryOwner") or {}).get("projectV2")
    if board is None:
        fail(f"project {project} not found")
    repos = {node["nameWithOwner"] for node in board["repositories"]["nodes"]}
    if not repos:
        fail(f"project {project} has no linked repositories")
    return repos


def owner_qualifier(owner):
    owner_type = json.loads(run(["gh", "api", f"users/{owner}"]))["type"]
    return f"{'org' if owner_type == 'Organization' else 'user'}:{owner}"


def milestone_epics(qualifier, repos):
    """(rank, id, node id, owner/repo#number) of every milestone epic in the project's
    linked repos, by rank.
    The search runs owner-wide as a prefilter and is over-broad, so a hit counts only once
    its repo is linked and its label and marker line are confirmed."""
    epics = []
    for hit in search_issues(f'"spec-ref: milestone:" label:type:epic is:issue {qualifier}'):
        if repo_of(hit) not in repos:
            continue
        marker = milestone_marker(hit)
        if marker:
            epics.append((marker[1], marker[0], hit["node_id"], f"{repo_of(hit)}#{hit['number']}"))
    return sorted(epics)


@functools.cache
def items_under(epic_node_id):
    """Non-epic issues anywhere below an epic, open and closed, one query per page of
    children. A nested milestone epic is its own milestone, so the walk does not enter it."""
    found, pending, seen = [], [epic_node_id], set()
    while pending:
        node_id = pending.pop()
        if node_id in seen:
            continue
        seen.add(node_id)
        after = []
        while True:
            response = json.loads(run(["gh", "api", "graphql", "-f", f"query={SUB_ISSUES_QUERY}",
                                       "-F", f"id={node_id}", *after]))
            page = response["data"]["node"]["subIssues"]
            for child in page["nodes"]:
                if milestone_marker(child):
                    continue
                if "type:epic" in labels_of(child):
                    pending.append(child["id"])
                else:
                    found.append(child)
            if not page["pageInfo"]["hasNextPage"]:
                break
            after = ["-F", f"after={page['pageInfo']['endCursor']}"]
    return found


def filed_refs(line, audit_repo):
    """The refs on an `audit-filed:` line; `none` is no refs. A bare #n is the audit's repo."""
    return [f"{ref_repo or audit_repo}#{ref_number}"
            for ref_repo, ref_number in re.findall(r"(?:^|\s)([\w.-]+/[\w.-]+)?#(\d+)\b", line)]


def repo_of(hit):
    return hit["repository_url"].split("/repos/", 1)[1]


@functools.cache
def audits_by_milestone(owner_qualifier, repos):
    """Every milestone's audit issues in the project's linked repos, oldest first, keyed by
    milestone: one search, each hit confirmed by its repo, label and `audit-unit:` line.
    One search for all milestones keeps a call at 3 searches (the API allows 30 a minute).
    The search runs owner-wide as a prefilter, because a milestone epic may live in a code
    repo while its audits live in the spec repo; only linked repos' hits count."""
    audits = collections.defaultdict(list)
    for hit in search_issues(f'"audit-unit: milestone:" label:type:audit is:issue '
                             f"{owner_qualifier}"):
        body = outside_fence(hit["body"])
        unit = AUDIT_UNIT.search(body)
        if repo_of(hit) not in repos or "type:audit" not in labels_of(hit) or not unit:
            continue
        filed = AUDIT_FILED.search(body)
        audits[unit.group(1)].append({
            "created": hit["created_at"], "repo": repo_of(hit),
            "filed": filed_refs(filed.group(1), repo_of(hit)) if filed else []})
    for milestone_audits in audits.values():
        milestone_audits.sort(key=lambda audit: audit["created"])
    return audits


@functools.cache
def audit_close_states(owner_qualifier, repos):
    """Each milestone's audit-close decisions in the project's linked repos, keyed by
    milestone, as their state (`open`/`closed`) and repo: one owner-wide search as a
    prefilter, each hit confirmed by its repo, label and `audit-close:` line."""
    decisions = collections.defaultdict(list)
    for hit in search_issues(f'"audit-close:" label:type:decision is:issue {owner_qualifier}'):
        marker = AUDIT_CLOSE.search(outside_fence(hit["body"]))
        if repo_of(hit) in repos and "type:decision" in labels_of(hit) and marker:
            decisions[marker.group(1)].append({"state": hit["state"], "repo": repo_of(hit)})
    return decisions


def cross_edges(dependent_ref, dependent_milestone, dependent_rank, body):
    dependent_repo = dependent_ref.split("#")[0]
    edges = []
    for blocker_repo, blocker_number in BLOCKED_BY.findall(outside_fence(body)):
        blocker_ref = f"{blocker_repo or dependent_repo}#{blocker_number}"
        blocker = milestone_of(blocker_ref)
        if blocker["state"] == "OPEN" and blocker["rank"] is not None \
                and blocker["rank"] > dependent_rank:
            edges.append({"issue": dependent_ref, "milestone": dependent_milestone,
                          "blockedBy": blocker_ref, "blockerMilestone": blocker["milestone"]})
    return edges


MilestoneState = collections.namedtuple("MilestoneState",
                                        "done open_items audits audit_needed")


def milestone_state(milestone, epics, qualifier, repos):
    """Whether one milestone, spread over the given epics, is done (NOTES.md § *Milestone
    sequencing* → *Audit gate*), with its open non-epic items and its audits oldest first.
    audit_needed is set when every item is closed but no audit or audit-close decision
    counts yet. Both call forms decide done here, so they can never disagree."""
    items = [child for epic in epics for child in items_under(epic[2])]
    open_items = [child for child in items if child["state"] == "OPEN"]
    audits = audits_by_milestone(qualifier, repos)[milestone]
    if open_items:
        return MilestoneState(False, open_items, audits, False)
    close_states = {decision["state"] for decision in audit_close_states(qualifier, repos)[milestone]}
    last_closed = max((child["closedAt"] or "" for child in items), default="")
    audited = any(audit["created"] > last_closed for audit in audits)
    close_pending = "open" in close_states
    done = not close_pending and (audited or "closed" in close_states)
    return MilestoneState(done, open_items, audits, not close_pending and not done)


def current_milestone(repos):
    """The --current form's output: the earliest milestone that is not done, else the
    latest, with every epic carrying it."""
    qualifier = owner_qualifier(project.split("/")[0])
    by_milestone = [list(epics) for _, epics in
                    itertools.groupby(milestone_epics(qualifier, repos), key=lambda epic: epic[0])]
    current = next((epics for epics in by_milestone
                    if not milestone_state(epics[0][1], epics, qualifier, repos).done),
                   by_milestone[-1] if by_milestone else [])
    return {"project": project, "milestone": current[0][1] if current else None,
            "epics": sorted((epic[3] for epic in current),
                            key=lambda ref: (ref.split("#")[0], int(ref.split("#")[1])))}


def named_milestone(milestone, repos):
    """The --milestone form's output: whether the milestone is done, and every linked repo
    holding its epics, their items, its audits or its audit-close decisions."""
    qualifier = owner_qualifier(project.split("/")[0])
    epics = [epic for epic in milestone_epics(qualifier, repos) if epic[1] == milestone]
    if not epics:
        return {"milestone": milestone, "done": False, "repos": []}
    holders = {epic[3].split("#")[0] for epic in epics}
    holders |= {child["repository"]["nameWithOwner"]
                for epic in epics for child in items_under(epic[2])}
    holders |= {audit["repo"] for audit in audits_by_milestone(qualifier, repos)[milestone]}
    holders |= {decision["repo"] for decision in audit_close_states(qualifier, repos)[milestone]}
    return {"milestone": milestone,
            "done": milestone_state(milestone, epics, qualifier, repos).done,
            "repos": sorted(holders & repos)}


linked_repos = frozenset(project_repos(project))
if target == ["--current"]:
    print(json.dumps(current_milestone(linked_repos)))
    sys.exit(0)
if target[0] == "--milestone":
    print(json.dumps(named_milestone(target[1], linked_repos)))
    sys.exit(0)

repo, number = target
item_ref = f"{repo}#{number}"
item = milestone_of(item_ref)
gate = {"issue": item_ref, "milestone": item["milestone"], "epic": item["epic"],
        "waitingOn": None, "openEarlier": [], "auditNeeded": None, "auditRound": 0,
        "lastAuditFiled": None, "crossEdges": []}
if item["milestone"] is None:
    print(json.dumps(gate))
    sys.exit(0)

item_body = json.loads(run(["gh", "api", f"repos/{repo}/issues/{number}"]))["body"]
dependents = [(item_ref, item["milestone"], item["rank"], item_body)]

qualifier = owner_qualifier(item["epic"].split("/")[0])
earlier = [epic for epic in milestone_epics(qualifier, linked_repos) if epic[0] < item["rank"]]
for rank, epics in itertools.groupby(earlier, key=lambda epic: epic[0]):
    epics = list(epics)
    milestone = epics[0][1]
    state = milestone_state(milestone, epics, qualifier, linked_repos)
    if state.done:
        continue
    if state.audit_needed:
        gate["auditNeeded"] = milestone
    gate["waitingOn"] = milestone
    gate["openEarlier"] = sorted({f"{child['repository']['nameWithOwner']}#{child['number']}"
                                  for child in state.open_items})
    gate["auditRound"] = len(state.audits)
    gate["lastAuditFiled"] = state.audits[-1]["filed"] if state.audits else None
    dependents += [(f"{child['repository']['nameWithOwner']}#{child['number']}",
                    milestone, rank, child["body"]) for child in state.open_items]
    break

gate["crossEdges"] = [edge for dependent in dependents for edge in cross_edges(*dependent)]
print(json.dumps(gate))
