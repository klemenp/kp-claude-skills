import json
import re
import subprocess
import sys

scripts_dir, repo, number = sys.argv[1:]

# Copied from milestone-gate.sh: a loosely matched start marker up to its end marker, or
# to the end of an unclosed body; and a `blocked-by:` marker line.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
BLOCKED_BY = re.compile(r"^[ \t]*blocked-by:[ \t]*([\w.-]+/[\w.-]+)?#(\d+)[ \t]*$", re.M)


def fail(message):
    print(f"blocker-state.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run_json(command, what):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{what} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def milestone_of(blocker_repo, blocker_number):
    return run_json([f"{scripts_dir}/milestone-of.sh", blocker_repo, blocker_number],
                    f"milestone-of.sh {blocker_repo} {blocker_number}")


def blockers_of(body):
    visible = HUMAN_ONLY_FENCE.sub("", (body or "").replace("\r\n", "\n"))
    refs = [(match.group(1) or repo, match.group(2)) for match in BLOCKED_BY.finditer(visible)]
    return list(dict.fromkeys(refs))


def has_open_task_pr(blocker_repo, blocker_number):
    found = run_json([f"{scripts_dir}/find-task-pr.sh", blocker_repo, blocker_number],
                     f"find-task-pr.sh {blocker_repo} {blocker_number}")
    return found["pr"] is not None and found["pr"]["state"] == "OPEN"


def state_of(blocker_repo, blocker_number, item_rank):
    looked_up = milestone_of(blocker_repo, blocker_number)
    url = run_json(["gh", "issue", "view", blocker_number, "-R", blocker_repo, "--json", "url"],
                   f"reading the URL of {blocker_repo}#{blocker_number}")["url"]
    kind = "pr" if "/pull/" in url else "issue"
    state = looked_up["state"]
    done = state == ("MERGED" if kind == "pr" else "CLOSED")
    later = (kind == "issue" and state == "OPEN" and item_rank is not None
             and looked_up["rank"] is not None and looked_up["rank"] > item_rank)
    if done or state != "OPEN":
        in_flight = False
    elif kind == "pr":
        in_flight = True
    else:
        in_flight = has_open_task_pr(blocker_repo, blocker_number)
    return {"blocker": f"{blocker_repo}#{blocker_number}", "kind": kind, "state": state,
            "done": done, "milestone": looked_up["milestone"], "laterMilestone": later,
            "inFlight": in_flight}


item = run_json(["gh", "issue", "view", number, "-R", repo, "--json", "body"],
                f"reading the body of {repo}#{number}")
blockers = blockers_of(item["body"])
if not blockers:
    print("[]")
    sys.exit(0)

item_rank = milestone_of(repo, number)["rank"]
print(json.dumps([state_of(blocker_repo, blocker_number, item_rank)
                  for blocker_repo, blocker_number in blockers]))
