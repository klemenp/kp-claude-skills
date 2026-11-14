import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys

USAGE = ("usage: review-scope.sh <owner/repo> <pr> <issue|-> <headRefName> "
         "[--state-file <json>] [--body-file <file>]")
EXIT_FAILED = 1
EXIT_USAGE = 2
GH_TIMEOUT_SECONDS = 60
GIT_TIMEOUT_SECONDS = 60
REPO_FORMAT = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
PUSHED_LINE = re.compile(r"^pushed: [0-9a-f]{7,40}$", re.MULTILINE)
BODY_SHA_LINE = re.compile(r"^body-sha256: ([0-9a-f]+)$", re.MULTILINE)
# A finding bullet that opens with a backticked `path:line` or `path:start-end`.
FLAGGED_BULLET = re.compile(r"^\s*[-*]\s+`([^`]+?):\d+(?:-\d+)?`", re.MULTILINE)
TEST_DIRS = {"test", "tests", "__tests__"}
TEST_BASENAMES = ("test_*", "*_test.*", "*.test.*", "*.spec.*")


def usage(message=None):
    if message:
        print(f"review-scope.sh: {message}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(EXIT_USAGE)


def fail(message):
    print(f"review-scope.sh: {message}", file=sys.stderr)
    sys.exit(EXIT_FAILED)


def parse_args(argv):
    positional, options = [], {}
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ("--state-file", "--body-file"):
            if index + 1 >= len(argv):
                usage(f"{arg} needs a value")
            options[arg] = argv[index + 1]
            index += 2
            continue
        if arg.startswith("--"):
            usage(f"unknown option {arg}")
        positional.append(arg)
        index += 1
    if len(positional) != 4:
        usage()
    repo, pr, issue, head = positional
    if not REPO_FORMAT.fullmatch(repo):
        usage(f"bad repo {repo!r}")
    if not pr.isdigit():
        usage(f"bad PR number {pr!r}")
    if issue != "-" and not issue.isdigit():
        usage(f"bad issue {issue!r} (a number or -)")
    if not head:
        usage("empty headRefName")
    for flag in ("--state-file", "--body-file"):
        if flag in options and not os.path.isfile(options[flag]):
            usage(f"{flag} {options[flag]!r} is not a file")
    return repo, pr, issue, head, options.get("--state-file"), options.get("--body-file")


def run(command, timeout, what):
    try:
        return subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(f"{what} timed out after {timeout}s")


def read_history(lib, repo, pr, state_file):
    if state_file:
        with open(state_file, "rb") as handle:
            raw = handle.read()
        source = f"--state-file {state_file}"
    else:
        command = [os.path.join(lib, "pr-verdict-state.sh"), repo, pr, "--history"]
        result = run(command, GH_TIMEOUT_SECONDS * 4, "pr-verdict-state.sh")
        if result.returncode != 0:
            detail = result.stderr.decode(errors="replace").strip()
            fail(f"pr-verdict-state.sh {repo} {pr} --history failed: {detail}")
        raw = result.stdout
        source = "pr-verdict-state.sh output"
    try:
        state = json.loads(raw)
    except ValueError as error:
        fail(f"{source} is not JSON: {error}")
    history = state.get("history") if isinstance(state, dict) else None
    return history or []


def body_hash(lib, repo, issue, body_file):
    if body_file:
        with open(body_file, "rb") as handle:
            body = handle.read()
    else:
        command = ["gh", "issue", "view", issue, "-R", repo, "--json", "body", "-q", ".body"]
        result = run(command, GH_TIMEOUT_SECONDS, f"gh issue view {issue}")
        if result.returncode != 0:
            detail = result.stderr.decode(errors="replace").strip()
            fail(f"gh issue view {issue} -R {repo} failed: {detail}")
        body = result.stdout
    # UTF-8 on both pipes, so the hash does not depend on the caller's locale.
    environment = {**os.environ, "PYTHONIOENCODING": "utf-8", "PYTHONUTF8": "1"}
    stripped = subprocess.run([os.path.join(lib, "body-parts.py"), "strip"], input=body,
                              capture_output=True, env=environment)
    if stripped.returncode != 0:
        detail = stripped.stderr.decode(errors="replace").strip()
        fail(f"body-parts.py strip failed: {detail}")
    return hashlib.sha256(stripped.stdout).hexdigest()


def flagged_paths(findings):
    return set(FLAGGED_BULLET.findall(findings or ""))


def is_test_file(path):
    *directories, basename = path.split("/")
    if TEST_DIRS.intersection(directories):
        return True
    return any(fnmatch.fnmatchcase(basename, pattern) for pattern in TEST_BASENAMES)


def changed_paths(reviewed, head):
    command = ["git", "diff", "--name-status", "-z", f"{reviewed}..origin/{head}"]
    result = run(command, GIT_TIMEOUT_SECONDS, "git diff")
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        fail(f"git diff --name-status {reviewed}..origin/{head} failed: {detail}")
    fields = result.stdout.decode(errors="surrogateescape").split("\0")
    paths, index = [], 0
    while index < len(fields) and fields[index]:
        status = fields[index]
        width = 2 if status[0] in "RC" else 1
        paths.extend(fields[index + 1:index + 1 + width])
        index += 1 + width
    return paths


def is_ancestor(reviewed, head):
    command = ["git", "merge-base", "--is-ancestor", reviewed, f"origin/{head}"]
    return run(command, GIT_TIMEOUT_SECONDS, "git merge-base").returncode == 0


def decide(history, issue, head, current_sha):
    """(reason or None for fix-diff, reviewed SHA or None)."""
    entries = sorted(history, key=lambda entry: entry.get("createdAt") or "")
    verdicts = [entry for entry in entries if entry.get("kind") == "verdict"]
    denial = verdicts[-1] if verdicts else None
    if not denial or denial.get("verdict") != "REQUEST_CHANGES" or not denial.get("reviewed"):
        return "no prior denial", None
    reviewed = denial["reviewed"]
    denied_at = denial.get("createdAt") or ""
    pushed = any(entry.get("kind") == "fixSummary"
                 and (entry.get("createdAt") or "") > denied_at
                 and PUSHED_LINE.search(entry.get("body") or "")
                 for entry in entries)
    if not pushed:
        return "no fix push", reviewed
    if not is_ancestor(reviewed, head):
        return "reviewed not an ancestor", reviewed
    flagged = flagged_paths(denial.get("findings"))
    if not all(path in flagged or is_test_file(path) for path in changed_paths(reviewed, head)):
        return "fix outside flagged files", reviewed
    denial_sha = BODY_SHA_LINE.search(denial.get("body") or "")
    if issue == "-" or not denial_sha:
        return "no body hash", reviewed
    if denial_sha.group(1) != current_sha:
        return "item body changed", reviewed
    return None, reviewed


def main():
    lib, argv = sys.argv[1], sys.argv[2:]
    repo, pr, issue, head, state_file, body_file = parse_args(argv)
    current_sha = None if issue == "-" else body_hash(lib, repo, issue, body_file)
    history = read_history(lib, repo, pr, state_file)
    reason, reviewed = decide(history, issue, head, current_sha)
    print("scope: fix-diff" if reason is None else f"scope: full ({reason})")
    print(f"reviewed: {reviewed or '-'}")
    print(f"bodySha: {current_sha or '-'}")


main()
