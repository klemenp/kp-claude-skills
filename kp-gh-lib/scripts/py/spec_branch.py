import argparse
import json
import os
import re
import subprocess
import sys

CALL_TIMEOUT_SECONDS = 120
REPO = re.compile(r"[^/\s]+/[^/\s]+")
BATCH_SECTION = re.compile(r"^## [^/ ]+/[^# ]+#[0-9]+: ", re.M)


class UsageError(Exception):
    pass


class CallFailed(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def positive_int(text):
    if not re.fullmatch(r"[0-9]+", text) or int(text) == 0:
        raise argparse.ArgumentTypeError(f"--issue not a positive integer: {text!r}")
    return int(text)


def owner_repo(text):
    if not REPO.fullmatch(text):
        raise argparse.ArgumentTypeError(f"not an owner/repo: {text!r}")
    return text


def parse_args(argv):
    if not argv or argv[0] not in ("prepare", "publish"):
        raise UsageError(f"unknown or missing mode: {argv[0] if argv else ''!r}")
    mode = argv[0]
    parser = Parser(prog=f"spec-branch.sh {mode}", add_help=False)
    parser.add_argument("--spec-repo", type=owner_repo, required=True)
    parser.add_argument("--issue", type=positive_int, required=True)
    parser.add_argument("--batch", action="store_true")
    if mode == "publish":
        parser.add_argument("--target-repo", type=owner_repo)
        parser.add_argument("--title", required=True)
        parser.add_argument("--body-file", required=True)
    args = parser.parse_args(argv[1:])
    args.mode = mode
    return args


def usage_exit(message):
    print(f"spec-branch.sh: {message}", file=sys.stderr)
    sys.exit(2)


def call(command, check=True):
    """Run one git/gh call. A failure (with check) raises CallFailed carrying its stderr."""
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=CALL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise CallFailed(f"{' '.join(command)} timed out after {CALL_TIMEOUT_SECONDS}s")
    if check and result.returncode != 0:
        raise CallFailed(result.stderr.strip() or f"{' '.join(command)} exited "
                         f"{result.returncode}")
    return result


def layout(args):
    top = call(["git", "rev-parse", "--show-toplevel"]).stdout.strip()
    origin_url = call(["git", "remote", "get-url", "origin"]).stdout.strip()
    repo_name = origin_url.rstrip("/").rsplit("/", 1)[-1]
    if repo_name.endswith(".git"):
        repo_name = repo_name[:-len(".git")]
    origin_head = call(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
                       check=False)
    if origin_head.returncode == 0:
        base = origin_head.stdout.strip().removeprefix("origin/")
        start_point = f"origin/{base}"
    else:
        base = call(["git", "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()
        start_point = base
    parent = os.path.dirname(top)
    suffix = f"{args.issue}-batch" if args.batch else f"{args.issue}"
    return {
        "base": base,
        "start_point": start_point,
        "branch": f"spec/resolve-{suffix}",
        "worktree": os.path.join(parent, f"{repo_name}-spec-resolve-{suffix}"),
        "legacy": None if args.batch else os.path.join(parent, f"spec-resolve-{args.issue}"),
    }


def listed_worktrees():
    porcelain = call(["git", "worktree", "list", "--porcelain"]).stdout
    return {os.path.realpath(line[len("worktree "):])
            for line in porcelain.splitlines() if line.startswith("worktree ")}


def is_listed(path, worktrees):
    return os.path.realpath(path) in worktrees


def newest_pr_state(spec_repo, branch):
    listing = call(["gh", "pr", "list", "-R", spec_repo, "--head", branch, "--state", "all",
                    "--json", "number,state"]).stdout
    prs = json.loads(listing or "[]")
    if not prs:
        return None
    return max(prs, key=lambda pr: pr["number"])["state"]


def prepare(args, names):
    worktrees = listed_worktrees()
    for path in (names["worktree"], names["legacy"]):
        if path and is_listed(path, worktrees):
            call(["git", "worktree", "remove", "--force", path])
    branch = names["branch"]
    branch_exists = call(["git", "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"],
                         check=False).returncode == 0
    if branch_exists and newest_pr_state(args.spec_repo, branch) == "MERGED":
        # A squash merge that did not delete the branch leaves it stale: start it fresh.
        call(["git", "branch", "-D", branch])
        if call(["git", "ls-remote", "--heads", "origin", branch]).stdout.strip():
            call(["git", "push", "origin", "--delete", branch])
        branch_exists = False
    if branch_exists:
        call(["git", "worktree", "add", names["worktree"], branch])
    else:
        call(["git", "worktree", "add", names["worktree"], "-b", branch, names["start_point"]])
    return {"worktree": names["worktree"], "branch": branch, "base": names["base"],
            "reusedBranch": branch_exists}


def check_publish_preconditions(args, names):
    try:
        with open(args.body_file) as body_file:
            body = body_file.read()
    except OSError as error:
        usage_exit(f"body file unreadable: {error}")
    if args.batch:
        if args.target_repo:
            usage_exit("--target-repo is not accepted with --batch")
        if not BATCH_SECTION.search(body):
            usage_exit("batch body has no '## <owner/repo>#<n>: ' section")
    else:
        if not args.target_repo:
            usage_exit("--target-repo is required without --batch")
        reference = f"{args.target_repo}#{args.issue}"
        if not re.search(re.escape(reference) + r"(?![0-9])", body):
            usage_exit(f"body does not reference {reference}")
    if not is_listed(names["worktree"], listed_worktrees()):
        usage_exit(f"no worktree at {names['worktree']}")
    if call(["git", "-C", names["worktree"], "status", "--porcelain"]).stdout.strip():
        usage_exit(f"uncommitted changes in {names['worktree']}")


def push_and_open_pr(args, names):
    branch = names["branch"]
    call(["git", "-C", names["worktree"], "push", "-u", "origin", branch])
    listing = call(["gh", "pr", "list", "-R", args.spec_repo, "--head", branch,
                    "--json", "number,url"]).stdout
    open_prs = json.loads(listing or "[]")
    if open_prs:
        return {"pr": open_prs[0]["number"], "url": open_prs[0]["url"], "created": False}
    created = call(["gh", "pr", "create", "-R", args.spec_repo, "--base", names["base"],
                    "--head", branch, "--title", args.title, "--body-file", args.body_file])
    url = [line for line in created.stdout.splitlines() if line.strip()][-1].strip()
    return {"pr": int(url.rstrip("/").rsplit("/", 1)[-1]), "url": url, "created": True}


def publish(args, names):
    check_publish_preconditions(args, names)
    try:
        result = push_and_open_pr(args, names)
    finally:
        # Removed on failure too: the skill reports the failure and moves on. A failed
        # removal is reported without hiding the push or create failure it follows.
        removal = call(["git", "worktree", "remove", names["worktree"]], check=False)
        if removal.returncode != 0:
            print(f"spec-branch.sh: {removal.stderr.strip()}", file=sys.stderr)
    if removal.returncode != 0:
        raise CallFailed(f"git worktree remove {names['worktree']} failed")
    return result


def main():
    try:
        args = parse_args(sys.argv[1:])
    except UsageError as error:
        usage_exit(f"{error}\nusage: spec-branch.sh prepare|publish --spec-repo <owner/repo>"
                   " --issue <n> [--batch] [--target-repo <owner/repo>] [--title <t>]"
                   " [--body-file <f>]")
    if call(["git", "rev-parse", "--is-inside-work-tree"], check=False).stdout.strip() != "true":
        usage_exit(f"not inside a git work tree: {os.getcwd()}")
    try:
        names = layout(args)
        result = prepare(args, names) if args.mode == "prepare" else publish(args, names)
    except CallFailed as error:
        print(f"spec-branch.sh: {error}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(result))


main()
