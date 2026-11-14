import json
import os
import re
import subprocess
import sys

USAGE = "usage: epic-convert.sh <owner/repo> <n>"
REPO = re.compile(r"[^/\s]+/[^/\s]+")
NUMBER = re.compile(r"[0-9]+")
CODE_TITLE = re.compile(r"\[([A-Z0-9][A-Z0-9-]*)\] (.*)")
PREFIX = "Sub-Epic: "
CODING = "type:coding"
EPIC = "type:epic"
TYPE_PREFIX = "type:"
MODEL_PREFIX = "model:"
ENSURE_LABELS = os.path.join(os.environ["KP_GH_LIB_BIN"], "ensure-labels.sh")


def fail(code, message):
    print(f"epic-convert.sh: {message}", file=sys.stderr)
    sys.exit(code)


def run(argv, what):
    result = subprocess.run(argv, capture_output=True, text=True)
    if result.returncode != 0:
        fail(1, f"{what} failed (exit {result.returncode}): {result.stderr.strip()}")
    return result.stdout


def target_title(title):
    if PREFIX in title:
        return title
    coded = CODE_TITLE.fullmatch(title)
    if coded:
        return f"[{coded.group(1)}] {PREFIX}{coded.group(2)}"
    return PREFIX + title


def main(args):
    if len(args) != 2 or not REPO.fullmatch(args[0]) or not NUMBER.fullmatch(args[1]):
        fail(2, USAGE)
    repo, number = args

    issue = json.loads(run(["gh", "api", f"repos/{repo}/issues/{number}"],
                           f"reading {repo}#{number}"))
    if issue.get("pull_request"):
        fail(3, f"{repo}#{number} is a pull request, not a coding item or epic")
    labels = [label["name"] for label in issue.get("labels", [])]
    if CODING not in labels and EPIC not in labels:
        types = [name for name in labels if name.startswith(TYPE_PREFIX)]
        fail(3, f"{repo}#{number} is not a coding item or epic "
                f"(type labels: {', '.join(types) or 'none'})")

    removed = [name for name in labels if name == CODING or name.startswith(MODEL_PREFIX)]
    add_epic = EPIC not in labels
    title = issue["title"]
    new_title = target_title(title)
    kept = [name for name in labels if name not in removed]
    final_labels = sorted(kept + [EPIC] if add_epic else kept)

    changed = bool(removed) or add_epic or new_title != title
    if changed:
        if add_epic:
            run([ENSURE_LABELS, "--repo", repo, EPIC], f"ensure-labels.sh {EPIC} on {repo}")
        edit = ["gh", "issue", "edit", number, "-R", repo]
        for name in removed:
            edit += ["--remove-label", name]
        if add_epic:
            edit += ["--add-label", EPIC]
        if new_title != title:
            edit += ["--title", new_title]
        run(edit, f"editing {repo}#{number}")

    print(json.dumps({"changed": changed, "title": new_title, "labels": final_labels}))


main(sys.argv[1:])
