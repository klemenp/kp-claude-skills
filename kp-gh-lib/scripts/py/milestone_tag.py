import json
import os
import subprocess
import sys

project, milestone = sys.argv[1:]
tag = f"milestone/{milestone}"


class RepoFailure(Exception):
    pass


def first_line(text):
    return next((line for line in text.splitlines() if line.strip()), "no error output")


def gh_api(*args):
    result = subprocess.run(["gh", "api", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RepoFailure(first_line(result.stderr))
    return json.loads(result.stdout)


def existing_tag_sha(repo):
    """The SHA the tag points at, or None when the lookup is a 404 (no such tag)."""
    result = subprocess.run(["gh", "api", f"repos/{repo}/git/ref/tags/{tag}"],
                            capture_output=True, text=True)
    if result.returncode == 0:
        return json.loads(result.stdout)["object"]["sha"]
    if "HTTP 404" in result.stderr:
        return None
    raise RepoFailure(first_line(result.stderr))


def tag_repo(repo):
    branch = gh_api(f"repos/{repo}")["default_branch"]
    head = gh_api(f"repos/{repo}/commits/{branch}")["sha"]
    existing = existing_tag_sha(repo)
    if existing is not None:
        return f"exists {repo} {tag} {existing}"
    gh_api("-X", "POST", f"repos/{repo}/git/refs", "-f", f"ref=refs/tags/{tag}", "-f", f"sha={head}")
    return f"tagged {repo} {tag} {head}"


gate = subprocess.run([os.path.join(os.environ["KP_GH_LIB_BIN"], "milestone-gate.sh"),
                       "--project", project, "--milestone", milestone],
                      capture_output=True, text=True)
if gate.returncode != 0:
    print(f"milestone-tag.sh: milestone-gate.sh --milestone {milestone} failed: "
          f"{first_line(gate.stderr)}", file=sys.stderr)
    sys.exit(1)
state = json.loads(gate.stdout)
if not state["done"]:
    print(f"not-done {milestone}")
    sys.exit(0)

failed = False
for repo in state["repos"]:
    try:
        print(tag_repo(repo), flush=True)
    except RepoFailure as error:
        print(f"failed {repo}: {error}", flush=True)
        failed = True
sys.exit(1 if failed else 0)
