import argparse
import json
import os
import re
import subprocess
import sys

GH_TIMEOUT_SECONDS = 30
# pr-verdict-state.sh pages through every PR comment, each page under its own 30 s limit.
STATE_TIMEOUT_SECONDS = 120
EXIT_GITHUB_FAILED = 1
EXIT_BAD_INPUT = 2
EXIT_HEAD_MOVED = 3

VERDICT_MARKER = "<!-- kp-review-gh-pr:verdict -->"
FIX_SUMMARY_MARKER = "<!-- kp-fix-pr:summary -->"
VERDICT_SHA_LINE = {"verdict: APPROVED": "approved", "verdict: REQUEST_CHANGES": "reviewed"}
FULL_SHA = "[0-9a-f]{40}"
REPO = re.compile(r"[^/\s]+/[^/\s]+")


def die(code, message):
    print(f"post-verdict-comment.sh: {message}", file=sys.stderr)
    sys.exit(code)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        die(EXIT_BAD_INPUT, message)


def parse_args():
    parser = Parser(prog="post-verdict-comment.sh")
    parser.add_argument("repo")
    parser.add_argument("pr")
    parser.add_argument("--kind", required=True, choices=["verdict", "fixSummary"])
    parser.add_argument("--body-file", required=True)
    args = parser.parse_args()
    if not REPO.fullmatch(args.repo):
        die(EXIT_BAD_INPUT, f"<owner/repo> must look like owner/name, got {args.repo!r}")
    if not args.pr.isdigit():
        die(EXIT_BAD_INPUT, f"<pr> must be a number, got {args.pr!r}")
    return args


def body_lines(path):
    try:
        with open(path, "rb") as handle:
            return handle.read().decode("utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        die(EXIT_BAD_INPUT, f"cannot read body file {path}: {error}")


def verdict_key_lines(lines):
    """The body's `verdict:` and SHA lines and its SHA; exit 2 when the header is malformed."""
    if len(lines) < 3 or lines[0] != VERDICT_MARKER:
        die(EXIT_BAD_INPUT, f"a verdict body must open with {VERDICT_MARKER}, "
                            "a verdict: line and an approved:/reviewed: line")
    verdict_line, sha_line = lines[1], lines[2]
    sha_field = VERDICT_SHA_LINE.get(verdict_line)
    if sha_field is None:
        die(EXIT_BAD_INPUT, f"line 2 must be one of {sorted(VERDICT_SHA_LINE)}, "
                            f"got {verdict_line!r}")
    match = re.fullmatch(f"{sha_field}: ({FULL_SHA})", sha_line)
    if not match:
        die(EXIT_BAD_INPUT, f"line 3 must be `{sha_field}: <40-hex sha>` after "
                            f"{verdict_line!r}, got {sha_line!r}")
    return verdict_line, sha_line, match.group(1)


def fix_summary_sha(lines):
    """The body's `pushed:` SHA; exit 2 when the header is malformed."""
    if len(lines) < 2 or lines[0] != FIX_SUMMARY_MARKER:
        die(EXIT_BAD_INPUT, f"a fix summary body must open with {FIX_SUMMARY_MARKER} "
                            "and a pushed: line")
    match = re.fullmatch(f"pushed: ({FULL_SHA})", lines[1])
    if not match:
        die(EXIT_BAD_INPUT, f"line 2 must be `pushed: <40-hex sha>`, got {lines[1]!r}")
    return match.group(1)


def read_state(repo, pr):
    script = os.path.join(os.environ["KP_GH_LIB_BIN"], "pr-verdict-state.sh")
    command = [script, repo, pr, "--history"]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=STATE_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired) as error:
        die(EXIT_GITHUB_FAILED, f"reading the verdict state of {repo}#{pr} failed: {error}")
    if result.returncode != 0:
        die(EXIT_GITHUB_FAILED, f"reading the verdict state of {repo}#{pr} failed: "
                                f"{result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        die(EXIT_GITHUB_FAILED, f"pr-verdict-state.sh returned unparseable JSON: {error}")


def verdict_rerun_id(state, verdict_line, sha_line):
    """The comment id a verdict body PATCHes, or None when it must stack a new round."""
    history = state.get("history") or []
    verdicts = [entry for entry in history if entry.get("kind") == "verdict"]
    if not verdicts:
        return None
    last = verdicts[-1]
    last_lines = (last.get("body") or "").splitlines()
    if verdict_line not in last_lines or sha_line not in last_lines:
        return None
    last_created = last.get("createdAt") or ""
    fix_newer = any(entry.get("kind") == "fixSummary"
                    and (entry.get("createdAt") or "") > last_created
                    for entry in history)
    return None if fix_newer else last.get("id")


def fix_summary_rerun_id(state, head):
    """The comment id a fix summary PATCHes, or None when it must stack a new round."""
    summary = state.get("fixSummary")
    if not summary:
        return None
    if f"pushed: {head}" not in (summary.get("body") or "").splitlines():
        return None
    return summary.get("id")


def post(repo, pr, comment_id, body_file):
    if comment_id is None:
        command = ["gh", "api", f"repos/{repo}/issues/{pr}/comments",
                   "-F", f"body=@{body_file}"]
    else:
        command = ["gh", "api", "-X", "PATCH", f"repos/{repo}/issues/comments/{comment_id}",
                   "-F", f"body=@{body_file}"]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=GH_TIMEOUT_SECONDS)
    except FileNotFoundError:
        die(EXIT_GITHUB_FAILED, "`gh` is not installed")
    except subprocess.TimeoutExpired:
        die(EXIT_GITHUB_FAILED, f"`{' '.join(command)}` timed out after {GH_TIMEOUT_SECONDS}s")
    if result.returncode != 0:
        die(EXIT_GITHUB_FAILED, f"`{' '.join(command)}` failed: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)["id"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        die(EXIT_GITHUB_FAILED, f"`{' '.join(command)}` returned no comment id: {error}")


def main():
    args = parse_args()
    lines = body_lines(args.body_file)
    if args.kind == "verdict":
        verdict_line, sha_line, body_sha = verdict_key_lines(lines)
    else:
        body_sha = fix_summary_sha(lines)

    state = read_state(args.repo, args.pr)
    head = state.get("head")
    if body_sha != head:
        die(EXIT_HEAD_MOVED, f"head moved: body {body_sha}, head {head}")

    if args.kind == "verdict":
        comment_id = verdict_rerun_id(state, verdict_line, sha_line)
    else:
        comment_id = fix_summary_rerun_id(state, head)
    posted_id = post(args.repo, args.pr, comment_id, args.body_file)
    action = "created" if comment_id is None else "patched"
    print(json.dumps({"action": action, "id": posted_id}))


main()
