import json
import re
import subprocess
import sys

scripts_dir, repo, mode, target, project = sys.argv[1:]

# A sibling walks issue trees and may make many gh calls; bound it all the same.
COMMAND_TIMEOUT_SECONDS = 600
# Copied from pr-loop.sh: a loosely matched start marker up to its end marker, or to the
# end of an unclosed body; and the item's `spec-ref:` marker line.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
SPEC_REF = re.compile(r"^[ \t]*spec-ref:[ \t]*(\S.*?)[ \t]*$", re.M)
# Output keys always print in this order, whichever ones an outcome sets.
KEY_ORDER = ("pr", "decision", "mergeStateStatus", "blocker", "milestone")


def fail(message):
    print(f"item-outcome.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run_json(command):
    shown = " ".join(command)
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        fail(f"`{shown}` timed out after {COMMAND_TIMEOUT_SECONDS}s")
    except OSError as error:
        fail(f"`{shown}` could not run: {error}")
    for line in result.stderr.splitlines():
        print(f"item-outcome.sh: {line}", file=sys.stderr)
    if result.returncode != 0:
        fail(f"`{shown}` exited {result.returncode}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        fail(f"`{shown}` printed no JSON")


def sibling(name, *args):
    return run_json([f"{scripts_dir}/{name}", *args])


def emit(outcome, **keys):
    pairs = [f"{key}={keys[key]}" for key in KEY_ORDER if keys.get(key) is not None]
    print(" ".join([f"outcome={outcome}", *pairs]))
    sys.exit(0)


def pr_outcome(number):
    pr = run_json(["gh", "pr", "view", number, "-R", repo, "--json", "state,mergeStateStatus"])
    if pr["state"] == "MERGED":
        emit("merged", pr=number)
    if pr["state"] == "CLOSED":
        emit("pr-closed", pr=number)
    if pr["state"] != "OPEN":
        fail(f"{repo}#{number} has an unknown state: {pr['state']}")
    decision = sibling("find-blocking-decision.sh", repo, "--pr", number)["decision"]
    if decision is not None:
        emit("blocked-on-decision", pr=number, decision=decision)
    emit("parked", pr=number, mergeStateStatus=pr["mergeStateStatus"] or "UNKNOWN")


def issue_outcome(number):
    found = sibling("find-task-pr.sh", repo, number)
    pr, closed = found["pr"], found["closed"]
    pr_number = pr["number"] if pr else None
    if pr and pr["state"] == "MERGED":
        emit("merged", pr=pr_number)

    item = run_json(["gh", "issue", "view", number, "-R", repo, "--json", "labels,body"])
    if "needs-contract" in {label["name"] for label in item["labels"]}:
        emit("needs-contract", pr=pr_number)

    flags = ["--issue", number]
    if pr_number is not None:
        flags += ["--pr", str(pr_number)]
    spec_ref = SPEC_REF.search(HUMAN_ONLY_FENCE.sub("", item.get("body") or ""))
    if spec_ref:
        flags += ["--spec-ref", spec_ref.group(1)]
    decision = sibling("find-blocking-decision.sh", repo, *flags)["decision"]
    if decision is not None:
        emit("blocked-on-decision", pr=pr_number, decision=decision)

    if pr is None and not closed:
        gate = sibling("milestone-gate.sh", "--project", project, repo, number)
        if gate["waitingOn"] is not None:
            emit("waiting-on-milestone", milestone=gate["waitingOn"])
        open_blockers = [entry for entry in sibling("blocker-state.sh", repo, number)
                         if not entry["done"]]
        for entry in open_blockers:
            if entry["laterMilestone"]:
                emit("stalled-cross-milestone", blocker=entry["blocker"])
        if open_blockers:
            emit("blocked-on-dependency", blocker=open_blockers[0]["blocker"])

    if pr and pr["state"] == "OPEN":
        emit("parked", pr=pr_number, mergeStateStatus=pr["mergeStateStatus"] or "UNKNOWN")
    if pr is None and closed:
        emit("pr-closed", pr=max(closed))
    emit("build-failed")


if mode == "--pr":
    pr_outcome(target)
issue_outcome(target)
