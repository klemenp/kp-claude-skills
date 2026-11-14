import functools
import json
import pathlib
import re
import subprocess
import sys

(item_id_script, merged_repo, merged_number, project_id, status_field_id,
 blocked_option_id, ready_option_id) = sys.argv[1:]
set_status_script = str(pathlib.Path(item_id_script).with_name("set-status.sh"))
owner = merged_repo.split("/")[0]
merged_ref = f"{merged_repo}#{merged_number}"

DECISION_LABELS = ("type:decision", "type:question", "type:conflict")
# A loosely matched start marker up to its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
BLOCKED_BY = re.compile(r"^[ \t]*blocked-by:[ \t]*([\w.-]+/[\w.-]+)?#(\d+)[ \t]*$", re.M)
BLOCKS = re.compile(r"^[ \t]*blocks:[ \t]*(\S.*?)[ \t]*$", re.M)
SPEC_REF = re.compile(r"^[ \t]*spec-ref:[ \t]*(\S.*?)[ \t]*$", re.M)
BLOCKED_ON = re.compile(r"blocked on #(\d+)", re.I)


def fail(message):
    print(f"unblock-dependents.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{' '.join(command)} failed: {result.stderr.strip()}")
    return result.stdout


def gh_get(path, params, paginate=False):
    command = ["gh", "api", "-X", "GET", path]
    if paginate:
        command += ["--paginate", "--slurp"]
    for key, value in params.items():
        command += ["-f", f"{key}={value}"]
    return json.loads(run(command))


def gh_list(path, params):
    pages = gh_get(path, {"per_page": 100, **params}, paginate=True)
    return [entry for page in pages for entry in page]


def outside_fence(body):
    return HUMAN_ONLY_FENCE.sub("", (body or "").replace("\r\n", "\n"))


def blockers_of(issue, repo):
    return [f"{blocker_repo or repo}#{number}"
            for blocker_repo, number in BLOCKED_BY.findall(outside_fence(issue["body"]))]


def find_candidates():
    """Issues whose text matches either marker form. Search is over-broad, so a hit is
    only a candidate until blockers_of confirms its marker line."""
    queries = (f'"blocked-by: #{merged_number}" repo:{merged_repo} is:issue is:open',
               f'"blocked-by: {merged_ref}" user:{owner} is:issue is:open')
    hits = set()
    for query in queries:
        for item in gh_get("search/issues", {"q": query, "per_page": 100})["items"]:
            hits.add((item["repository_url"].split("/repos/", 1)[1], item["number"]))
    return sorted(hits)


@functools.cache
def is_done(ref):
    """An issue blocker is done once closed, a pull request only once merged: the REST
    issue object reports a PR closed unmerged as closed too."""
    repo, number = ref.split("#")
    blocker = gh_get(f"repos/{repo}/issues/{number}", {})
    if "pull_request" in blocker:
        return blocker["pull_request"]["merged_at"] is not None
    return blocker["state"] == "closed"


@functools.cache
def open_decisions(repo):
    """(number, body) of every open decision / question / conflict issue in repo."""
    return tuple((issue["number"], issue["body"])
                 for label in DECISION_LABELS
                 for issue in gh_list(f"repos/{repo}/issues", {"state": "open", "labels": label})
                 if "pull_request" not in issue)


@functools.cache
def open_pulls(repo):
    return tuple((pull["number"], pull["head"]["ref"])
                 for pull in gh_list(f"repos/{repo}/pulls", {"state": "open"}))


def blocking_decision(repo, number, issue):
    """The open decision issue that blocks this dependent, or None."""
    decisions = open_decisions(repo)
    if not decisions:
        return None
    names = {f"#{number}", f"{repo}#{number}"}
    names.update(f"{repo}#{pull}" for pull, head in open_pulls(repo)
                 if head.startswith(f"task/{number}-"))
    names.update(SPEC_REF.findall(outside_fence(issue["body"])))
    for decision, body in decisions:
        if names.intersection(BLOCKS.findall(outside_fence(body))):
            return decision
    open_numbers = {decision for decision, _ in decisions}
    for comment in gh_list(f"repos/{repo}/issues/{number}/comments", {}):
        for decision in BLOCKED_ON.findall(comment["body"] or ""):
            if int(decision) in open_numbers:
                return int(decision)
    return None


def promotion_check(repo, number, issue, blockers):
    """(item id, None) when the dependent may move to Ready, else (None, skip reason).
    Cheapest checks first: the board lookup costs a GraphQL point."""
    if issue["state"] != "open":
        return None, "closed"
    if "type:coding" not in {label["name"] for label in issue["labels"]}:
        return None, "not type:coding"
    item = json.loads(run([item_id_script, repo, str(number), project_id]))
    if item["itemId"] is None:
        return None, "not on this board"
    if item["statusOptionId"] != blocked_option_id:
        return None, f"status is not Blocked ({item['status'] or 'none'})"
    pending_blocker = next((blocker for blocker in blockers if not is_done(blocker)), None)
    if pending_blocker:
        return None, f"blocked on {pending_blocker}"
    decision = blocking_decision(repo, number, issue)
    if decision:
        return None, f"blocked on decision #{decision}"
    return item["itemId"], None


promoted, skipped = [], []
for repo, number in find_candidates():
    issue = gh_get(f"repos/{repo}/issues/{number}", {})
    blockers = blockers_of(issue, repo)
    if merged_ref not in blockers:
        continue  # the hit's marker names another issue, or sits inside the fence
    ref = f"{repo}#{number}"
    item_id, reason = promotion_check(repo, number, issue, blockers)
    if reason:
        skipped.append({"issue": ref, "reason": reason})
        continue
    run([set_status_script, project_id, item_id, status_field_id, ready_option_id])
    promoted.append(ref)

print(json.dumps({"promoted": promoted, "skipped": skipped}))
