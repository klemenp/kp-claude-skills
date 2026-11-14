import json
import os
import subprocess
import sys

project, milestone = sys.argv[1:]
branch = f"release/{milestone}"
CI_WATCH_TIMEOUT_SECONDS = 540  # matches spec-pr-fastmerge.sh's wait_for_ci
CI_WATCH_INTERVAL_SECONDS = "60"
GH_PENDING_EXIT = 8  # `gh pr checks` exit code for pending checks
NO_CHECKS_MARKER = "no checks reported"
NO_CHECKS_REPOLL_INTERVAL_SECONDS = "30"
NO_CHECKS_REPOLL_LIMIT = 10
NO_CHECKS_REPOLL_TIMEOUT_SECONDS = 60
CONFLICT_MARKER = "(HTTP 409)"
NOT_FOUND_MARKER = "HTTP 404"


class RepoOutcome(Exception):
    """A repo that goes no further; the message is its whole stdout line."""


def first_line(text):
    return next((line for line in text.splitlines() if line.strip()), "no error output")


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def gh_api(repo, *args):
    result = run(["gh", "api", *args])
    if result.returncode != 0:
        raise RepoOutcome(f"failed {repo}: {first_line(result.stderr)}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def has_branch(repo):
    result = run(["gh", "api", f"repos/{repo}/branches/{branch}"])
    if result.returncode == 0:
        return True
    if NOT_FOUND_MARKER in result.stderr:
        return False
    raise RepoOutcome(f"failed {repo}: {first_line(result.stderr)}")


def sync_default_into_branch(repo, default):
    result = run(["gh", "api", "-X", "POST", f"repos/{repo}/merges",
                  "-f", f"base={branch}", "-f", f"head={default}"])
    if result.returncode == 0:
        return
    if CONFLICT_MARKER in result.stderr:
        raise RepoOutcome(f"conflict {repo}: {first_line(result.stderr)}")
    raise RepoOutcome(f"failed {repo}: {first_line(result.stderr)}")


def find_or_create_pr(repo, default):
    owner = repo.split("/", 1)[0]
    open_prs = gh_api(repo, f"repos/{repo}/pulls?head={owner}:{branch}&base={default}&state=open")
    if open_prs:
        return str(open_prs[0]["number"])
    body = (f"milestone-merge: {milestone}\n\n"
            f"Merges the done milestone {milestone}'s integration branch `{branch}` into "
            f"`{default}`, ahead of its `milestone/{milestone}` tag.")
    result = run(["gh", "pr", "create", "-R", repo, "--base", default, "--head", branch,
                  "--title", f"Merge {milestone} into {default}", "--body", body])
    if result.returncode != 0:
        raise RepoOutcome(f"failed {repo}: {first_line(result.stderr)}")
    return result.stdout.strip().rstrip("/").rsplit("/", 1)[-1]


def watch_checks(repo, pr):
    command = ["gh", "pr", "checks", pr, "-R", repo, "--watch",
               "--interval", CI_WATCH_INTERVAL_SECONDS]
    try:
        return run(command, timeout=CI_WATCH_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise RepoOutcome(f"ci-pending {repo} {pr}")


def checks_appeared(repo, pr):
    """Sleeps one interval, then re-polls once; a re-poll that times out still has none."""
    # `sleep` as a subprocess from PATH, not time.sleep, so the fixture's fake sees it.
    subprocess.run(["sleep", NO_CHECKS_REPOLL_INTERVAL_SECONDS], check=True)
    try:
        result = run(["gh", "pr", "checks", pr, "-R", repo],
                     timeout=NO_CHECKS_REPOLL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return False
    return NO_CHECKS_MARKER not in result.stderr


def wait_for_checks_to_appear(repo, pr):
    for _ in range(NO_CHECKS_REPOLL_LIMIT):
        if checks_appeared(repo, pr):
            return True
    return False


def wait_for_ci(repo, pr):
    result = watch_checks(repo, pr)
    if NO_CHECKS_MARKER in result.stderr:
        if not wait_for_checks_to_appear(repo, pr):
            return
        result = watch_checks(repo, pr)
    if result.returncode == GH_PENDING_EXIT:
        raise RepoOutcome(f"ci-pending {repo} {pr}")
    if result.returncode != 0:
        raise RepoOutcome(f"ci-failed {repo} {pr}")


def merge_repo(repo):
    default = gh_api(repo, f"repos/{repo}")["default_branch"]
    if not has_branch(repo):
        return f"no-branch {repo}"
    sync_default_into_branch(repo, default)
    pr = find_or_create_pr(repo, default)
    wait_for_ci(repo, pr)
    result = run(["gh", "pr", "merge", pr, "-R", repo, "--merge", "--delete-branch"])
    if result.returncode != 0:
        raise RepoOutcome(f"failed {repo}: {first_line(result.stderr)}")
    head = gh_api(repo, f"repos/{repo}/commits/{default}")["sha"]
    return f"merged {repo} {pr} {head}"


gate = run([os.path.join(os.environ["KP_GH_LIB_BIN"], "milestone-gate.sh"),
            "--project", project, "--milestone", milestone])
if gate.returncode != 0:
    print(f"milestone-merge.sh: milestone-gate.sh --milestone {milestone} failed: "
          f"{first_line(gate.stderr)}", file=sys.stderr)
    sys.exit(1)
state = json.loads(gate.stdout)
if not state["done"]:
    print(f"not-done {milestone}")
    sys.exit(0)

failed = False
for repo in state["repos"]:
    try:
        print(merge_repo(repo), flush=True)
    except RepoOutcome as outcome:
        print(outcome, flush=True)
        failed = True
sys.exit(1 if failed else 0)
