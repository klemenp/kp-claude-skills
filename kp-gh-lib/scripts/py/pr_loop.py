import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

LIB = Path(os.environ["KP_GH_LIB_BIN"])
GH_TIMEOUT_SECONDS = 30
PREAMBLE_TIMEOUT_SECONDS = 180
DEFAULT_WAIT_MAX_SECONDS = 480
DEFAULT_STALL_LIMIT = 2
DEFAULT_MAX_CYCLES = 6
DEFAULT_MODEL = "opus"
# A review never runs below this effort on an item whose tier names an effort.
REVIEW_EFFORT_FLOOR = "high"
EFFORTS_BELOW_REVIEW_FLOOR = ("low", "medium")
# After a stalled fix cycle, review and fix get one stronger attempt before the loop parks.
STALL_BOOST_EFFORT = "xhigh"
STALL_BOOST_EFFORT_FROM_TOP = "max"
EFFORTS_AT_TOP = ("xhigh", "max")
BOOSTED_PHASES = ("review", "fix")
DEFAULT_LOG_DIR = Path(os.environ.get("TMPDIR") or "/tmp") / "kp-pr-loop"


def env_seconds(name, default):
    """A non-negative integer from the environment (the fixtures' override), else default."""
    value = os.environ.get(name, "")
    return int(value) if re.fullmatch(r"\d+", value) else default


CI_POLL_SECONDS = env_seconds("KP_PR_LOOP_CI_POLL_SECONDS", 60)
CI_WAIT_CAP_SECONDS = env_seconds("KP_PR_LOOP_CI_WAIT_CAP_SECONDS", 3600)
CI_READ_FAILURE_LIMIT = 2

EXIT_MERGED, EXIT_FAILED, EXIT_USAGE, EXIT_RUNNING, EXIT_PARKED, EXIT_CAPACITY = range(6)
PREAMBLE_STOP_EXITS = (5, 6)

VERDICT_MARKER = "<!-- kp-review-gh-pr:verdict -->"
# A loosely matched start marker up to its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
CLOSING_REF = re.compile(r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)\b", re.I)
TASK_BRANCH = re.compile(r"^task/(\d+)-")
SPEC_REF = re.compile(r"^[ \t]*spec-ref:[ \t]*(\S.*?)[ \t]*$", re.M)
CHILD_RESULT = re.compile(
    r"^exit=(\d+) capacity=(\S+)(?: reset='(.*)')? log=(.*)$", re.M)
# kp-fix-pr §6.2 calls out each finding it deliberately did not action, with its reason.
# Its summary is prose, so this reads a "not actioned" / "declined" line whose text, or
# the bullets under it, name something other than "none".
DECLINED_LINE = re.compile(r"not\s+actioned|declined|not\s+addressed", re.I)
NONE_TEXT = re.compile(r"^\W*(none|n/?a|nothing|—|-)?\W*$", re.I)
# A line's own tail may open with "none" and carry on ("none. Verified: …"): that still
# declines nothing, whereas a bullet has to be the "none" form alone.
NONE_TAIL = re.compile(r"^\s*(none|n/?a|nothing|—|-)(?!\w)", re.I)
# "No finding declined." says nothing was declined, so the phrase is set aside before a
# line is tested; a line that names a decline beside it still counts.
NO_DECLINE = re.compile(r"\bno\s+findings?\s+(?:(?:was|were)\s+)?declined\b", re.I)

USAGE = """usage: pr-loop.sh start <owner/repo> <pr> --project <owner/number> [--model <tier>]
                  [--stall-limit <k>] [--max-cycles <k>] [--log-dir <dir>] [--dry-run]
       pr-loop.sh --wait <state-file> [--wait-max-sec <s>]"""


class Failure(Exception):
    """A lookup or launch failed; the loop state is left as it was (exit 1)."""


def usage():
    print(USAGE, file=sys.stderr)
    sys.exit(EXIT_USAGE)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd, timeout=GH_TIMEOUT_SECONDS, ok=(0,), cwd=None):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL, cwd=cwd)
    except subprocess.TimeoutExpired:
        raise Failure(f"{' '.join(cmd[:3])} timed out after {timeout}s")
    except OSError as error:
        raise Failure(f"cannot run {cmd[0]}: {error}")
    if proc.returncode not in ok:
        raise Failure(f"{' '.join(cmd[:3])} exited {proc.returncode}: "
                      f"{proc.stderr.strip() or proc.stdout.strip()}")
    return proc


def lib(name):
    return str(LIB / name)


def gh_json(*args):
    out = run(["gh", *args]).stdout.strip()
    return json.loads(out) if out else None


def strip_fence(body):
    return HUMAN_ONLY_FENCE.sub("", body or "")


def int_arg(value, minimum):
    if not re.fullmatch(r"\d+", value or "") or int(value) < minimum:
        usage()
    return int(value)


# ---------------------------------------------------------------- state file

def load_state(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise Failure(f"cannot read the loop state {path}: {error}")


def save_state(state):
    path = Path(state["stateFile"])
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=1) + "\n")
    tmp.replace(path)


# ---------------------------------------------------------------- GitHub reads

def read_pr(state, fields="state,isDraft,headRefOid,reviews,mergeStateStatus"):
    return gh_json("pr", "view", str(state["pr"]), "-R", state["repo"], "--json", fields)


def read_verdict_state(repo, pr):
    return json.loads(run([lib("pr-verdict-state.sh"), repo, str(pr)]).stdout)


def score_formal_denial(review, head):
    """Score a formal REQUEST_CHANGES body the way pr-verdict-state.sh scores a comment."""
    fixture = {"head": head, "comments": [{
        "id": 0,
        "body": f"{VERDICT_MARKER}\nverdict: REQUEST_CHANGES\n\n{review.get('body') or ''}",
        "created_at": review["submittedAt"], "updated_at": review["submittedAt"]}]}
    with tempfile.NamedTemporaryFile("w", prefix="pr-loop-formal-", suffix=".json",
                                     delete=False) as scratch:
        json.dump(fixture, scratch)
    path = Path(scratch.name)
    try:
        return json.loads(run([lib("pr-verdict-state.sh"), "--from-file", str(path)]).stdout)["denial"]
    finally:
        path.unlink(missing_ok=True)


def denial_count(denial):
    """Loop policy `count`: blockers + major + ci; the legacy joint group falls back."""
    severity = denial.get("bySeverity") or {}
    if severity.get("combined") is not None:
        return denial.get("count") or 0
    return (severity.get("blockers") or 0) + (severity.get("major") or 0) + (severity.get("ci") or 0)


def minor_nits(denial):
    severity = denial.get("bySeverity") or {}
    if severity.get("combined") is not None:
        return "—"
    return (severity.get("minor") or 0) + (severity.get("nits") or 0)


def latest_formal(reviews):
    decided = [r for r in reviews or [] if r.get("state") in ("APPROVED", "CHANGES_REQUESTED")]
    return max(decided, key=lambda r: r.get("submittedAt") or "", default=None)


def classify_review(state):
    """§2 step 2: what the review phase left on GitHub."""
    pr = read_pr(state)
    if pr["state"] == "MERGED":
        return {"kind": "merged", "pr": pr}
    if pr["state"] == "CLOSED":
        return {"kind": "pr-closed", "pr": pr}
    if pr.get("isDraft"):
        return {"kind": "pr-draft", "pr": pr}
    verdicts = read_verdict_state(state["repo"], state["pr"])
    comment = verdicts.get("verdict")
    formal = latest_formal(pr.get("reviews"))
    comment_at = (comment or {}).get("updatedAt") or ""
    formal_at = (formal or {}).get("submittedAt") or ""
    fix_at = ((verdicts.get("fixSummary") or {}).get("updatedAt")) or ""

    if formal and formal_at > comment_at:
        if formal["state"] == "APPROVED":
            return {"kind": "approved", "pr": pr}
        if formal_at > fix_at:
            return {"kind": "denied", "pr": pr,
                    "denial": score_formal_denial(formal, pr["headRefOid"])}
        return {"kind": "none", "pr": pr}
    if comment and comment.get("verdict") == "APPROVED":
        return {"kind": "approved", "pr": pr}
    # A denial counts only when no fix summary is newer than it: an older verdict was
    # already addressed, so this review left nothing new.
    if verdicts.get("denial") and verdicts.get("fixSummary") is None:
        return {"kind": "denied", "pr": pr, "denial": verdicts["denial"]}
    return {"kind": "none", "pr": pr}


def declined_findings(summary_body):
    """The fix summary's "not actioned" text, or '' when it declined nothing."""
    lines = (summary_body or "").splitlines()
    for index, line in enumerate(lines):
        if not DECLINED_LINE.search(NO_DECLINE.sub("", line)):
            continue
        tail = re.split(r":", line, maxsplit=1)[1] if ":" in line else ""
        if tail.strip() and not NONE_TEXT.match(tail) and not NONE_TAIL.match(tail):
            return line.strip()
        bullets = []
        for follow in lines[index + 1:]:
            if re.match(r"^\s*[-*] ", follow):
                bullets.append(follow.strip())
            elif follow.strip():
                break
        named = [b for b in bullets if not NONE_TEXT.match(b.lstrip("-* "))]
        if named:
            return "\n".join([line.strip(), *named])
    return ""


def blocking_decisions(state, *flags):
    """`find-blocking-decision.sh`'s answer for this PR's repo and the given targets."""
    return json.loads(run([lib("find-blocking-decision.sh"), state["repo"], *flags]).stdout)


def open_decision(state):
    """§2.5: an open decision/question/conflict issue whose `blocks:` names this PR or item."""
    flags = ["--pr", str(state["pr"])]
    if state.get("issue") and not state.get("referenceOnly"):
        flags += ["--issue", str(state["issue"])]
    if state.get("specRef"):
        flags += ["--spec-ref", state["specRef"]]
    return blocking_decisions(state, *flags)["decision"]


def raised_item(state):
    """§3.1's search: the newest open human-gated item carrying `blocks: <repo>#<pr>`."""
    raised = blocking_decisions(state, "--pr", str(state["pr"]))["all"]
    return max(raised) if raised else None


# ---------------------------------------------------------------- children

def child_log(state, label):
    name = f"pr-loop-{state['repoName']}-{state['pr']}-{state['runId']}-{label}.log"
    return str(Path(state["logDir"]) / name)


def split_tier(tier):
    """`model-label.sh`'s split of a tier such as `opus-high` into (model, effort)."""
    line = run([lib("model-label.sh"), tier]).stdout.strip()
    match = re.fullmatch(r"model=(\S+) effort=(\S*)", line)
    if not match:
        raise Failure(f"model-label.sh printed an unexpected line for {tier!r}: {line!r}")
    return match.group(1), match.group(2)


def phase_effort(state, phase):
    """The effort a phase's child runs at: the stall boost once set (review and fix only),
    else the tier's, raised to the floor for a review."""
    boost = state.get("boost")
    if boost and phase in BOOSTED_PHASES:
        return boost
    effort = state.get("effort") or ""
    if phase == "review" and effort in EFFORTS_BELOW_REVIEW_FLOOR:
        return REVIEW_EFFORT_FLOOR
    return effort


def boost_effort(state):
    """The effort a stalled loop's later review and fix children run at."""
    if (state.get("effort") or "") in EFFORTS_AT_TOP:
        return STALL_BOOST_EFFORT_FROM_TOP
    return STALL_BOOST_EFFORT


def launch(state, phase, prompt, label):
    log = child_log(state, label)
    effort = phase_effort(state, phase)
    effort_flags = ["--effort", effort] if effort else []
    run([lib("run-child.sh"), "--log", log, "--cwd", state["cwd"], "--model", state["model"],
         *effort_flags, "--", prompt], ok=(EXIT_RUNNING,))
    state.update(phase=phase, log=log, phaseStartedAt=now_iso())
    state["logs"].append(log)


def launch_review(state):
    launch(state, "review", f"/kp-review-gh-pr {state['pr']} --project {state['project']}",
           f"cycle{state['cycles'] + 1}-review")


def launch_fix(state):
    launch(state, "fix", f"/kp-fix-pr {state['pr']} --project {state['project']}",
           f"cycle{state['cycles'] + 1}-fix")


def wait_child(log, budget):
    proc = run([lib("run-child.sh"), "--wait", log, "--wait-max-sec", str(max(budget, 1))],
               ok=(0, EXIT_RUNNING), timeout=max(budget, 1) + 60)
    if proc.returncode == EXIT_RUNNING:
        return None
    match = CHILD_RESULT.search(proc.stdout)
    if not match:
        raise Failure(f"run-child.sh --wait printed no result line: {proc.stdout.strip()}")
    return {"exit": int(match.group(1)), "capacity": match.group(2),
            "reset": match.group(3) or "", "log": match.group(4)}


def limit_line(log, reset):
    try:
        lines = Path(log).read_text(errors="replace").splitlines()
    except OSError:
        return ""
    for line in lines:
        if (reset and reset in line) or (not reset and "limit" in line.lower()):
            return line.strip()
    return ""


# ---------------------------------------------------------------- outcomes

def finish(state, outcome, code, reason=""):
    state.update(phase="done", outcome=outcome, exitCode=code, reason=reason, log=None)
    save_state(state)
    return report(state)


def escalate(state, reason, last_findings="", merge_state="", declined=""):
    """§3: write the evidence and hand the impasse to the escalate child."""
    evidence_path = Path(state["logDir"]) / f"pr-loop-{state['repoName']}-{state['pr']}.evidence.json"
    evidence = {"reason": reason, "cycles": state["cycles"], "stalls": state["stalls"],
                "lastFindings": last_findings or state.get("lastFindings") or "",
                "mergeStateStatus": merge_state, "declined": declined,
                "logs": list(state["logs"]), "issue": state.get("issue"),
                "referenceOnly": state.get("referenceOnly", False),
                "specRef": state.get("specRef"), "decision": state.get("decision")}
    evidence_path.write_text(json.dumps(evidence, indent=1) + "\n")
    state.update(reason=reason, evidence=str(evidence_path))
    launch(state, "escalate",
           f"/kp-do-gh-pr-loop-escalate {state['pr']} --project {state['project']} "
           f"--evidence {evidence_path}", "escalate")


def outcome_of(reason):
    for outcome in ("blocked-on-decision", "merge-blocked", "unactionable-finding",
                    "ci-not-settling", "stalled", "max-cycles", "pr-closed", "pr-draft"):
        if reason.replace(" ", "-").startswith(outcome):
            return outcome
    return reason.split(" ")[0]


def close_out(state):
    """§4: close the linked item and set it Done. The `Closes #N` keyword closes it only
    on a default-branch merge, so a merge into `release/M<k>` leaves it open for this."""
    repo, pr = state["repo"], state["pr"]
    merged = gh_json("pr", "view", str(pr), "-R", repo, "--json", "state,mergeCommit")
    if merged["state"] != "MERGED":
        raise Failure(f"close-out on {repo}#{pr}, which is {merged['state']}, not MERGED")
    sha = (merged.get("mergeCommit") or {}).get("oid", "")
    result = {"issue": "no linked item; nothing to close", "board": "skipped",
              "dependents": "skipped"}
    issue = state.get("issue")
    unblock_target = pr
    if issue and state.get("referenceOnly"):
        result["issue"] = f"research item #{issue}, reference only; left as is"
    elif issue:
        current = gh_json("issue", "view", str(issue), "-R", repo, "--json", "state")["state"]
        if current == "OPEN":
            run(["gh", "issue", "close", str(issue), "-R", repo, "--reason", "completed",
                 "--comment", f"Closed by merged PR #{pr} ({sha})."])
            result["issue"] = f"#{issue} closed by the loop"
        else:
            result["issue"] = f"#{issue} already {current}"
        unblock_target = issue
        options = state.get("options") or {}
        if state.get("itemId") and state.get("projectId") and options.get("Done"):
            try:
                run([lib("set-status.sh"), state["projectId"], state["itemId"],
                     state["statusFieldId"], options["Done"]])
                result["board"] = "Done"
            except Failure as error:
                result["board"] = f"not set: {error}"
        else:
            result["board"] = "skipped: no board item or no Done option"
    options = state.get("options") or {}
    if state.get("projectId") and options.get("Blocked") and options.get("Ready"):
        try:
            result["dependents"] = json.loads(run(
                [lib("unblock-dependents.sh"), repo, str(unblock_target), state["projectId"],
                 state["statusFieldId"], options["Blocked"], options["Ready"]],
                timeout=300).stdout)
        except (Failure, ValueError) as error:
            result["dependents"] = f"failed: {error}"
    else:
        result["dependents"] = "skipped: the board has no Blocked or Ready option"
    # The merged PR's local branch, in the primary checkout the loop started in (a
    # state file written before headRefName was recorded has none). Best-effort.
    branch = state.get("headRefName")
    if not branch:
        result["branch"] = "skipped: no head branch recorded"
    else:
        try:
            stdout = run([lib("branch-cleanup.sh"), branch], cwd=state["cwd"]).stdout
            match = re.search(r"result=(.*)$", stdout.strip())
            result["branch"] = match.group(1) if match else f"unparsed: {stdout.strip()!r}"
        except Failure as error:
            result["branch"] = f"not cleaned: {error}"
    return result


def report(state):
    rows = state.get("table") or []
    if rows:
        print("| cycle | phase outcome | head before→after | count | minor+nits | findings changed | result |")
        print("|---|---|---|---|---|---|---|")
        for row in rows:
            print(f"| {row['cycle']} | {row['outcome']} | {row['headBefore'][:7]}→{row['headAfter'][:7]} "
                  f"| {row['count']} | {row['minorNits']} | {row['findingsChanged']} | {row['result']} |")
    if state.get("closeOut"):
        print("close-out: " + json.dumps(state["closeOut"]))
    if state.get("logs"):
        print("logs: " + " ".join(state["logs"]))
    if state.get("limitLine"):
        print("limit: " + state["limitLine"])
    if state.get("boost"):
        print("boost: " + state["boost"])
    line = f"outcome={state['outcome']}"
    if state.get("reason"):
        line += f" reason='{state['reason']}'"
    if state.get("reset"):
        line += f" reset='{state['reset']}'"
    print(f"{line} state={state['stateFile']}")
    return state["exitCode"]


# ---------------------------------------------------------------- phase handlers

def after_review(state):
    seen = classify_review(state)
    kind, pr = seen["kind"], seen["pr"]
    if kind == "merged":
        state["closeOut"] = close_out(state)
        return finish(state, "merged", EXIT_MERGED)
    if kind in ("pr-closed", "pr-draft"):
        return escalate(state, kind)
    decision = open_decision(state)
    if decision:
        state["decision"] = decision
        return escalate(state, f"blocked-on-decision #{decision}")
    if kind == "approved":
        return escalate(state, f"merge-blocked ({pr.get('mergeStateStatus') or 'unknown'})",
                        merge_state=pr.get("mergeStateStatus") or "")
    if kind == "none":
        state["cycles"] += 1
        state["stalls"] += 1
        state["table"].append({"cycle": state["cycles"], "outcome": "no verdict",
                               "headBefore": state["prev"]["head"],
                               "headAfter": pr["headRefOid"], "count": "—",
                               "minorNits": "—", "findingsChanged": "—", "result": "stall"})
        if state["stalls"] >= state["stallLimit"]:
            return escalate(state, "ci-not-settling", merge_state=pr.get("mergeStateStatus") or "")
        if cycle_cap_reached(state):
            return escalate(state, "max-cycles reached")
        return enter_ci_wait(state)
    denial = seen["denial"]
    state["pendingDenial"] = {"count": denial_count(denial), "minorNits": minor_nits(denial),
                              "findings": denial.get("fingerprint") or "",
                              "headBefore": state["prev"]["head"]}
    state["lastFindings"] = denial.get("findings") or ""
    state["lastMergeState"] = pr.get("mergeStateStatus") or ""
    return launch_fix(state)


def cycle_cap_reached(state):
    return state["maxCycles"] != 0 and state["cycles"] >= state["maxCycles"]


def after_fix(state):
    pr = read_pr(state, "state,isDraft,headRefOid,mergeStateStatus")
    if pr["state"] == "CLOSED":
        return escalate(state, "pr-closed")
    if pr.get("isDraft"):
        return escalate(state, "pr-draft")
    pending = state.pop("pendingDenial")
    previous = state["prev"]
    state["cycles"] += 1
    progress = previous.get("count") is None or pending["count"] < previous["count"]
    state["stalls"] = 0 if progress else state["stalls"] + 1
    state["table"].append({
        "cycle": state["cycles"], "outcome": "denied → fixed",
        "headBefore": pending["headBefore"], "headAfter": pr["headRefOid"],
        "count": pending["count"], "minorNits": pending["minorNits"],
        "findingsChanged": "yes" if pending["findings"] != previous.get("findings") else "no",
        "result": "progress" if progress else "stall"})
    state["prev"] = {"head": pr["headRefOid"], "count": pending["count"],
                     "findings": pending["findings"]}
    merge_state = pr.get("mergeStateStatus") or ""

    summary = read_verdict_state(state["repo"], state["pr"]).get("fixSummary") or {}
    declined = declined_findings(summary.get("body"))
    if declined:
        return escalate(state, "unactionable-finding", merge_state=merge_state, declined=declined)
    decision = open_decision(state)
    if decision:
        state["decision"] = decision
        return escalate(state, f"blocked-on-decision #{decision}", merge_state=merge_state)
    if state["stalls"] >= state["stallLimit"]:
        return escalate(state, f"stalled ({state['stalls']} cycles, findings not reduced)",
                        merge_state=merge_state)
    if cycle_cap_reached(state):
        return escalate(state, "max-cycles reached", merge_state=merge_state)
    if not progress:
        state["boost"] = boost_effort(state)
        state["table"][-1]["result"] = f"stall → effort {state['boost']}"
    return launch_review(state)


def after_escalate(state):
    raised = raised_item(state) or state.get("decision")
    reason = state["reason"]
    reason += f"; decision #{raised}" if raised else "; no human-gated item raised"
    return finish(state, outcome_of(state["reason"]), EXIT_PARKED, reason)


HANDLERS = {"review": after_review, "fix": after_fix, "escalate": after_escalate}


# ---------------------------------------------------------------- ci-wait

def read_checks(state):
    """The PR's checks as a list of `{bucket}`, or None when the read failed. `gh pr checks`
    exits 8 while checks are pending and 1 when some failed, both with valid JSON, so
    only empty or unparseable stdout counts as a failed read."""
    try:
        proc = subprocess.run(["gh", "pr", "checks", str(state["pr"]), "-R", state["repo"],
                               "--json", "bucket"],
                              capture_output=True, text=True, timeout=GH_TIMEOUT_SECONDS,
                              stdin=subprocess.DEVNULL)
    except (subprocess.TimeoutExpired, OSError):
        return None
    try:
        checks = json.loads(proc.stdout)
    except ValueError:
        return None
    return checks if isinstance(checks, list) else None


def any_pending(checks):
    return any(check.get("bucket") == "pending" for check in checks)


def enter_ci_wait(state):
    """After a no-verdict review: launch the next review now, unless checks are pending —
    then wait for them in the script (no child) instead of in a fresh reviewer."""
    checks = read_checks(state)
    if checks is None or not any_pending(checks):
        return launch_review(state)
    state.update(phase="ci-wait", log=None, ciWaitStartedAt=now_iso(), ciReadFailures=0)


def ci_wait_elapsed_seconds(state):
    started = datetime.strptime(state["ciWaitStartedAt"], "%Y-%m-%dT%H:%M:%SZ")
    return (datetime.now(timezone.utc) - started.replace(tzinfo=timezone.utc)).total_seconds()


def poll_ci_wait(state):
    """One `ci-wait` poll: the PR's state, then its checks, then the cap. Leaves the phase
    `ci-wait` while checks are still pending; otherwise moves the loop on."""
    pr = read_pr(state, "state,isDraft,headRefOid,mergeStateStatus")
    if pr["state"] == "MERGED":
        state["closeOut"] = close_out(state)
        return finish(state, "merged", EXIT_MERGED)
    if pr["state"] == "CLOSED":
        return escalate(state, "pr-closed")
    if pr.get("isDraft"):
        return escalate(state, "pr-draft")
    checks = read_checks(state)
    if checks is None:
        state["ciReadFailures"] = state.get("ciReadFailures", 0) + 1
        if state["ciReadFailures"] >= CI_READ_FAILURE_LIMIT:
            return launch_review(state)
    else:
        state["ciReadFailures"] = 0
        if not any_pending(checks):
            return launch_review(state)
    if ci_wait_elapsed_seconds(state) >= CI_WAIT_CAP_SECONDS:
        return escalate(state, "ci-not-settling", merge_state=pr.get("mergeStateStatus") or "")
    return None


def wait(state_file, wait_max):
    deadline = time.monotonic() + wait_max
    while True:
        state = load_state(state_file)
        if state["phase"] == "done":
            return report(state)
        budget = int(deadline - time.monotonic())
        if budget <= 0:
            print(f"status: running state={state_file}")
            return EXIT_RUNNING
        # ci-wait has no child, so neither a child wait nor a capacity read applies.
        if state["phase"] == "ci-wait":
            returned = poll_ci_wait(state)
        else:
            result = wait_child(state["log"], budget)
            if result is None:
                print(f"status: running state={state_file}")
                return EXIT_RUNNING
            # Capacity check before any GitHub read: a quota-killed child exits without
            # touching GitHub, so it is neither a missing verdict nor a stalled fix.
            if result["capacity"] != "none":
                state.update(capacity=result["capacity"], reset=result["reset"],
                             limitLine=limit_line(result["log"], result["reset"]))
                state.pop("pendingDenial", None)
                return finish(state, "capacity-limit", EXIT_CAPACITY,
                              f"{result['capacity']} in the {state['phase']} phase")
            returned = HANDLERS[state["phase"]](state)
        if returned is not None:
            return returned
        save_state(state)
        if state["phase"] == "ci-wait":
            time.sleep(max(0.0, min(CI_POLL_SECONDS, deadline - time.monotonic())))


# ---------------------------------------------------------------- start

def run_preamble(pr, project):
    try:
        proc = subprocess.run([lib("preamble.sh"), "--pr", str(pr), "--project", project],
                              capture_output=True, text=True, timeout=PREAMBLE_TIMEOUT_SECONDS,
                              stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Failure(f"preamble.sh timed out after {PREAMBLE_TIMEOUT_SECONDS}s")
    sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        raise Failure(f"preamble.sh exited {proc.returncode}"
                      + (" (guard/auth or project unresolved)" if proc.returncode in PREAMBLE_STOP_EXITS else ""))
    return json.loads(proc.stdout)


def find_linked(preamble, pr_view, repo):
    """§1.2: the work item the PR closes, or the one its task branch names."""
    issue = preamble.get("issue")
    if issue is None:
        match = CLOSING_REF.search(pr_view.get("body") or "") or TASK_BRANCH.match(pr_view.get("headRefName") or "")
        issue = int(match.group(1)) if match else None
    if issue is None:
        return {"issue": None, "referenceOnly": False, "itemId": None, "modelLabel": None, "specRef": None}
    item = gh_json("issue", "view", str(issue), "-R", repo, "--json", "number,state,labels,body")
    labels = [label["name"] for label in item.get("labels") or []]
    reference_only = item["state"] == "CLOSED" and "type:research" in labels
    model_label = next((name.split(":", 1)[1] for name in labels if name.startswith("model:")), None)
    spec_ref = SPEC_REF.search(strip_fence(item.get("body")))
    item_id = preamble.get("itemId") if preamble.get("issue") == issue else None
    project_id = (preamble.get("project") or {}).get("id")
    if item_id is None and not reference_only and project_id:
        try:
            item_id = json.loads(run([lib("item-id.sh"), repo, str(issue), project_id]).stdout).get("itemId")
        except (Failure, ValueError) as error:
            print(f"pr-loop.sh: no board item for #{issue}: {error}", file=sys.stderr)
    return {"issue": issue, "referenceOnly": reference_only, "itemId": None if reference_only else item_id,
            "modelLabel": model_label, "specRef": spec_ref.group(1) if spec_ref else None}


def parse_start(argv):
    if len(argv) < 2:
        usage()
    repo, pr = argv[0], argv[1]
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", repo) or not re.fullmatch(r"\d+", pr):
        usage()
    options = {"repo": repo, "pr": int(pr), "project": None, "model": None,
               "stallLimit": DEFAULT_STALL_LIMIT, "maxCycles": DEFAULT_MAX_CYCLES,
               "logDir": str(DEFAULT_LOG_DIR), "dryRun": False}
    rest = argv[2:]
    while rest:
        flag = rest.pop(0)
        if flag == "--dry-run":
            options["dryRun"] = True
            continue
        if not rest:
            usage()
        value = rest.pop(0)
        if flag == "--project" and re.fullmatch(r"[^/\s]+/\d+", value):
            options["project"] = value
        elif flag == "--model" and value:
            options["model"] = value
        elif flag == "--stall-limit":
            options["stallLimit"] = int_arg(value, 1)
        elif flag == "--max-cycles":
            options["maxCycles"] = int_arg(value, 0)
        elif flag == "--log-dir" and value:
            options["logDir"] = str(Path(value).resolve())
        else:
            usage()
    if not options["project"]:
        usage()
    return options


def describe_verdicts(verdicts):
    denial, verdict = verdicts.get("denial"), verdicts.get("verdict")
    if not verdict:
        return "none"
    text = f"latest={verdict.get('verdict')} reviewed={(verdict.get('reviewed') or '')[:7]} atHead={verdict.get('atHead')}"
    if denial:
        text += f" | denial count={denial_count(denial)} minor+nits={minor_nits(denial)}"
        text += " (addressed by a newer fix summary)" if verdicts.get("fixSummary") else " (open)"
    return text


def start(argv):
    options = parse_start(argv)
    repo, pr = options["repo"], options["pr"]
    preamble = run_preamble(pr, options["project"])
    if preamble.get("repo") != repo:
        raise Failure(f"this checkout is {preamble.get('repo')}, not {repo} — run from the PR's primary checkout")
    pr_view = gh_json("pr", "view", str(pr), "-R", repo, "--json",
                      "number,title,body,headRefName,headRefOid,state,isDraft,url,mergeStateStatus")
    linked = find_linked(preamble, pr_view, repo)
    tier = options["model"] or linked["modelLabel"] or DEFAULT_MODEL
    model, effort = split_tier(tier)
    project = preamble.get("project") or {}
    status = preamble.get("status") or {}
    state_file = Path(options["logDir"]) / f"pr-loop-{repo.split('/')[1]}-{pr}.state.json"
    state = {
        "stateFile": str(state_file), "repo": repo, "repoName": repo.split("/")[1], "pr": pr,
        "project": options["project"], "projectId": project.get("id"),
        "statusFieldId": status.get("fieldId"), "options": status.get("options") or {},
        "priorityTop": (preamble.get("priority") or {}).get("top"),
        "headRefName": pr_view["headRefName"],
        "issue": linked["issue"], "referenceOnly": linked["referenceOnly"],
        "itemId": linked["itemId"], "specRef": linked["specRef"], "model": model,
        "effort": effort,
        "cwd": os.getcwd(), "logDir": options["logDir"],
        "runId": datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S"),
        "stallLimit": options["stallLimit"], "maxCycles": options["maxCycles"],
        "cycles": 0, "stalls": 0, "prev": {"head": pr_view["headRefOid"], "count": None, "findings": ""},
        "phase": None, "log": None, "logs": [], "table": [], "startedAt": now_iso()}

    if pr_view["state"] == "MERGED":
        first = "close-out (already merged)"
    elif pr_view["state"] == "CLOSED" or pr_view.get("isDraft"):
        first = "none (closed or draft: stop and report)"
    else:
        first = f"review (/kp-review-gh-pr {pr} --project {options['project']})"

    if options["dryRun"]:
        verdicts = read_verdict_state(repo, pr) if pr_view["state"] == "OPEN" else {}
        if linked["issue"] is None:
            item = "none"
        elif linked["referenceOnly"]:
            item = f"research item #{linked['issue']}, reference only"
        else:
            item = f"#{linked['issue']} (item {linked['itemId'] or 'not on the board'}, spec-ref {linked['specRef'] or 'none'})"
        print(f"pr: {repo}#{pr} '{pr_view['title']}' state={pr_view['state']} draft={pr_view.get('isDraft')} "
              f"head={pr_view['headRefOid'][:7]} mergeState={pr_view.get('mergeStateStatus')}")
        print(f"linked issue: {item}")
        print(f"model: {model} ({'--model' if options['model'] else 'model:' + linked['modelLabel'] if linked['modelLabel'] else 'default'})"
              f" · effort: {effort or 'default'}")
        print(f"project: {options['project']} ({project.get('id') or 'board unavailable'})")
        print(f"verdict state: {describe_verdicts(verdicts)}")
        print(f"first phase: {first}")
        print(f"limits: stall-limit={options['stallLimit']} max-cycles={options['maxCycles']}")
        print(f"state file: {state_file} (not written on --dry-run)")
        return EXIT_MERGED

    Path(options["logDir"]).mkdir(parents=True, exist_ok=True)
    if pr_view["state"] == "MERGED":
        close = close_out(state)
        print("close-out: " + json.dumps(close))
        print("outcome=merged reason='merged before the loop started'")
        return EXIT_MERGED
    if pr_view["state"] == "CLOSED":
        return finish(state, "pr-closed", EXIT_PARKED, "closed before the loop started")
    if pr_view.get("isDraft"):
        return finish(state, "pr-draft", EXIT_PARKED, "draft before the loop started")

    verdicts = read_verdict_state(repo, pr)
    if verdicts.get("denial") and verdicts.get("fixSummary") is None:
        state["prev"].update(count=denial_count(verdicts["denial"]),
                             findings=verdicts["denial"].get("fingerprint") or "")
    launch_review(state)
    save_state(state)
    print(f"status: running state={state_file}")
    return EXIT_RUNNING


def main(argv):
    if not argv:
        usage()
    if argv[0] == "start":
        return start(argv[1:])
    if argv[0] == "--wait":
        if len(argv) not in (2, 4):
            usage()
        wait_max = DEFAULT_WAIT_MAX_SECONDS
        if len(argv) == 4:
            if argv[2] != "--wait-max-sec":
                usage()
            wait_max = int_arg(argv[3], 1)
        return wait(argv[1], wait_max)
    usage()


try:
    sys.exit(main(sys.argv[1:]))
except Failure as error:
    print(f"pr-loop.sh: {error}", file=sys.stderr)
    sys.exit(EXIT_FAILED)
