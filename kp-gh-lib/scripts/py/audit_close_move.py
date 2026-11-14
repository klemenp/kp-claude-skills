import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

repo, issue, milestone, spec_repo, project, *items = sys.argv[1:]
project = project or None
BIN = os.environ["KP_GH_LIB_BIN"]
EPIC_VALUE = re.compile(r"milestone:M([0-9]+)")
RESOLVED_PREFIX = "Resolved → "
AUDIT_LABEL = "type:audit"
AUDIT_LABEL_COLOR = "0052CC"
ADD_SUB_ISSUE = ("mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p, subIssueId:$c, "
                 "replaceParent:true}){issue{number}}}")
k = int(milestone[1:])


class StepFailed(Exception):
    pass


def first_line(text):
    return next((line for line in text.splitlines() if line.strip()), "no error output")


def call(step, argv):
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        raise StepFailed(f"{step}: {os.path.basename(argv[0])} failed: {first_line(result.stderr)}")
    return result.stdout


def sibling(name):
    return os.path.join(BIN, name)


def split_ref(ref):
    item_repo, number = ref.rsplit("#", 1)
    return item_repo, number


def issue_json(step, issue_repo, number):
    return json.loads(call(step, ["gh", "api", f"repos/{issue_repo}/issues/{number}"]))


def paginated_array(text):
    """`gh api --paginate` prints one JSON array per page, back to back."""
    decoder = json.JSONDecoder()
    values, position = [], 0
    while position < len(text):
        if text[position].isspace():
            position += 1
            continue
        page, position = decoder.raw_decode(text, position)
        values.extend(page)
    return values


def next_epic():
    hits = json.loads(call("next milestone epic", [
        sibling("find-marker.sh"), spec_repo, "spec-ref", "--any-value",
        "--scope", "owner", "--label", "type:epic"]))
    later = []
    for hit in hits:
        match = EPIC_VALUE.fullmatch(hit["value"])
        if match and int(match.group(1)) > k:
            later.append((int(match.group(1)), hit["repo"], hit["number"]))
    return min(later) if later else None


def reparent(epic_repo, epic_number, target):
    step = "re-parent"
    epic_node = None
    moved, already, skipped = [], [], []
    for ref in items:
        item_repo, number = split_ref(ref)
        where = json.loads(call(step, [sibling("milestone-of.sh"), item_repo, number]))
        if where["state"] == "OPEN" and where["milestone"] == milestone:
            if epic_node is None:
                epic_node = issue_json(step, epic_repo, epic_number)["node_id"]
            item_node = issue_json(step, item_repo, number)["node_id"]
            call(step, ["gh", "api", "graphql", "-f", f"query={ADD_SUB_ISSUE}",
                        "-f", f"p={epic_node}", "-f", f"c={item_node}"])
            moved.append(ref)
        elif where["milestone"] == target:
            already.append(ref)
        elif where["state"] != "OPEN":
            skipped.append({"item": ref, "reason": "closed"})
        else:
            skipped.append({"item": ref, "reason": f"milestone {where['milestone'] or 'none'}"})
    return moved, already, skipped


def write_temp(text):
    handle = tempfile.NamedTemporaryFile("w", suffix=".md", delete=False)
    with handle:
        handle.write(text)
    return handle.name


def file_acceptance(target, refs):
    step = "acceptance audit"
    call(step, ["gh", "label", "create", AUDIT_LABEL, "-R", repo,
                "--color", AUDIT_LABEL_COLOR, "--force"])
    body = (f"audit-unit: milestone:{milestone}\n"
            f"audit-filed: none\n"
            f"audit-accepted: {repo}#{issue}\n"
            f"\n"
            f"{milestone} accepted by the operator with these findings moved to {target}: {refs}.\n")
    body_file = write_temp(body)
    try:
        date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        audit = json.loads(call(step, [
            sibling("file-audit.sh"), "--repo", repo, "--title", f"Audit {milestone} {date}",
            "--body-file", body_file,
            "--dedup-line", f"audit-unit: milestone:{milestone}",
            "--dedup-line", f"audit-accepted: {repo}#{issue}"]))
    finally:
        os.unlink(body_file)
    if issue_json(step, repo, audit["number"])["state"] == "open":
        call(step, ["gh", "issue", "close", str(audit["number"]), "-R", repo])
    return audit


def close_decision(target, refs, audit_number):
    step = "close decision"
    comments = paginated_array(call(step, [
        "gh", "api", "--paginate", f"repos/{repo}/issues/{issue}/comments"]))
    if not any(comment["body"].lstrip().startswith(RESOLVED_PREFIX) for comment in comments):
        comment_file = write_temp(f"{RESOLVED_PREFIX}no spec change: audit-close. Decision: B — "
                                  f"moved {refs} to {target}; audit #{audit_number}\n")
        try:
            call(step, ["gh", "api", "-X", "POST", f"repos/{repo}/issues/{issue}/comments",
                        "-F", f"body=@{comment_file}"])
        finally:
            os.unlink(comment_file)
    if issue_json(step, repo, issue)["state"] == "open":
        call(step, ["gh", "issue", "close", issue, "-R", repo, "--reason", "completed"])


def run_milestone_script(name):
    """Never fails the script: the caller reports the lines and the exit code."""
    result = subprocess.run([sibling(name), "--project", project, milestone],
                            stdout=subprocess.PIPE, text=True)
    return [line for line in result.stdout.splitlines() if line.strip()], result.returncode


def merge_and_tag_milestone():
    """The tag lands on the merged default branch, so a failed merge skips it."""
    merge, merge_exit = run_milestone_script("milestone-merge.sh")
    if merge_exit != 0:
        return merge, merge_exit, "skipped", None
    tag, tag_exit = run_milestone_script("milestone-tag.sh")
    return merge, merge_exit, tag, tag_exit


try:
    epic = next_epic()
    if epic is None:
        print(json.dumps({"target": None}))
        sys.exit(0)
    target_rank, epic_repo, epic_number = epic
    target = f"M{target_rank}"
    moved, already, skipped = reparent(epic_repo, epic_number, target)
    refs = ", ".join(moved + already) or "none"
    audit = file_acceptance(target, refs)
    close_decision(target, refs, audit["number"])
except StepFailed as error:
    print(f"audit-close-move.sh: {error}", file=sys.stderr)
    sys.exit(1)

merge, merge_exit, tag, tag_exit = merge_and_tag_milestone() if project else (None,) * 4
print(json.dumps({
    "target": target,
    "epic": f"{epic_repo}#{epic_number}",
    "moved": moved,
    "already": already,
    "skipped": skipped,
    "audit": {"number": audit["number"], "url": audit["url"], "reused": audit["reused"]},
    "decisionClosed": True,
    "merge": merge,
    "mergeExit": merge_exit,
    "tag": tag,
    "tagExit": tag_exit,
}))
