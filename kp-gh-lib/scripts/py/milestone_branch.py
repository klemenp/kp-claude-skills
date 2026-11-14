import json
import os
import re
import subprocess
import sys

repo, issue, create = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
RELEASE_BRANCH = re.compile(r"release/M([0-9]+)")
EXIT_EARLIER_UNMERGED = 3


def fail(what, stderr):
    print(f"milestone-branch.sh: {what}: {stderr.strip() or 'no error output'}", file=sys.stderr)
    sys.exit(1)


def gh_api(what, *args):
    result = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if result.returncode != 0:
        fail(what, result.stderr)
    return result.stdout


def branch_exists(branch):
    result = subprocess.run(["gh", "api", f"repos/{repo}/branches/{branch}"],
                            capture_output=True, text=True)
    if result.returncode == 0:
        return True
    if "HTTP 404" in result.stderr:
        return False
    fail(f"branch lookup {repo} {branch} failed", result.stderr)


def earliest_unmerged(rank):
    """The lowest release/M<j> with j < rank that still exists, or None."""
    names = gh_api(f"branch listing {repo} failed", "--paginate",
                   f"repos/{repo}/branches?per_page=100", "--jq", ".[].name")
    earlier = sorted(int(match.group(1)) for match in map(RELEASE_BRANCH.fullmatch, names.split())
                     if match and int(match.group(1)) < rank)
    return f"release/M{earlier[0]}" if earlier else None


lookup = subprocess.run([os.path.join(os.environ["KP_GH_LIB_BIN"], "milestone-of.sh"), repo, issue],
                        capture_output=True, text=True)
if lookup.returncode != 0:
    fail(f"milestone-of.sh {repo} {issue} failed", lookup.stderr)
found = json.loads(lookup.stdout)
milestone, rank = found["milestone"], found["rank"]

default = gh_api(f"default-branch read {repo} failed", f"repos/{repo}", "--jq", ".default_branch").strip()
state = {"milestone": milestone, "branch": None, "exists": False, "created": False, "default": default}

if milestone is not None:
    branch = f"release/{milestone}"
    state.update(branch=branch, exists=branch_exists(branch))
    if create and not state["exists"]:
        blocker = earliest_unmerged(rank)
        if blocker:
            print(f"earlier-unmerged {blocker}", file=sys.stderr)
            sys.exit(EXIT_EARLIER_UNMERGED)
        head = gh_api(f"default-branch HEAD read {repo} {default} failed",
                      f"repos/{repo}/git/ref/heads/{default}", "--jq", ".object.sha").strip()
        gh_api(f"create {branch} in {repo} failed", "-X", "POST", f"repos/{repo}/git/refs",
               "-f", f"ref=refs/heads/{branch}", "-f", f"sha={head}")
        state.update(exists=True, created=True)

print(json.dumps(state))
