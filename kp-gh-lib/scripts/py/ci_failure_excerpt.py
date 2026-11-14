import argparse
import json
import os
import re
import subprocess
import sys

DEFAULT_LINES = 60
DEFAULT_TIMEOUT_SECONDS = 60
TIMEOUT_SECONDS = int(os.environ.get("KP_CI_EXCERPT_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS))
REPO = re.compile(r"[^/\s]+/[^/\s]+")
PR_NUMBER = re.compile(r"[0-9]+")
ACTIONS_JOB = re.compile(r"^https://github\.com/[^/]+/[^/]+/actions/runs/(\d+)/job/(\d+)")
TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT\S+ ")
BYTE_ORDER_MARK = "﻿"
UNKNOWN_STEP = "unknown"
NOT_ACTIONS_JOB = "not a GitHub Actions job"
LOG_CALL_FAILED = "log call failed"
LOG_CALL_TIMED_OUT = "log call timed out"
NO_FAILED_STEP_LINES = "no failed-step lines"
USAGE = "usage: ci-failure-excerpt.sh <owner/repo> <pr> [--lines <n>]"


class UsageError(Exception):
    pass


class LogUnavailable(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    parser = Parser(prog="ci-failure-excerpt.sh", add_help=False, allow_abbrev=False)
    parser.add_argument("repo")
    parser.add_argument("pr")
    parser.add_argument("--lines", default=str(DEFAULT_LINES))
    args = parser.parse_args(argv)
    if not REPO.fullmatch(args.repo):
        raise UsageError(f"not an owner/repo: {args.repo!r}")
    if not PR_NUMBER.fullmatch(args.pr):
        raise UsageError(f"not a PR number: {args.pr!r}")
    if not re.fullmatch(r"-?[0-9]+", args.lines) or int(args.lines) < 1:
        raise UsageError(f"--lines must be an integer >= 1: {args.lines!r}")
    args.lines = int(args.lines)
    return args


def read_checks(repo, pr):
    command = ["gh", "pr", "checks", pr, "-R", repo, "--json", "name,bucket,link,workflow"]
    try:
        # A non-zero exit is not a failure by itself: 8 means pending, 1 some failed.
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        fail(f"gh pr checks {pr} -R {repo} timed out after {TIMEOUT_SECONDS}s")
    try:
        checks = json.loads(result.stdout)
    except json.JSONDecodeError:
        checks = None
    if not isinstance(checks, list):
        detail = result.stderr.strip() or f"unparseable output (exit {result.returncode})"
        fail(f"gh pr checks {pr} -R {repo} failed: {detail}")
    return checks


def fail(message):
    print(f"ci-failure-excerpt.sh: {message}", file=sys.stderr)
    sys.exit(1)


def read_failed_log(repo, link):
    match = ACTIONS_JOB.match(link or "")
    if not match:
        raise LogUnavailable(NOT_ACTIONS_JOB)
    run_id, job_id = match.groups()
    command = ["gh", "run", "view", run_id, "-R", repo, "--job", job_id, "--log-failed"]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise LogUnavailable(LOG_CALL_TIMED_OUT) from error
    if result.returncode != 0:
        raise LogUnavailable(LOG_CALL_FAILED)
    lines = result.stdout.removeprefix(BYTE_ORDER_MARK).splitlines()
    if not lines:
        raise LogUnavailable(NO_FAILED_STEP_LINES)
    return lines


def split_log_line(line):
    """(step or None, text) of one `<job>\t<step>\t<timestamp> <text>` line."""
    fields = line.split("\t", 2)
    if len(fields) < 3:
        return None, line
    return fields[1], TIMESTAMP.sub("", fields[2], count=1)


def check_block(repo, check, max_lines):
    header = [f"check: {check.get('name', '')}", f"url: {check.get('link', '')}"]
    try:
        lines = read_failed_log(repo, check.get("link"))
    except LogUnavailable as reason:
        return header + [f"log: unavailable ({reason})"]
    parsed = [split_log_line(line) for line in lines]
    steps = [step for step, _ in parsed if step is not None]
    shown = parsed[-max_lines:]
    return header + [
        f"step: {steps[-1] if steps else UNKNOWN_STEP}",
        f"--- last {len(shown)} of {len(parsed)} failed-step lines ---",
    ] + [text for _, text in shown]


try:
    arguments = parse_args(sys.argv[1:])
except UsageError as error:
    print(f"ci-failure-excerpt.sh: {error}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)

failing = [check for check in read_checks(arguments.repo, arguments.pr)
           if check.get("bucket") == "fail"]
if not failing:
    print("no failing checks")
    sys.exit(0)
blocks = ["\n".join(check_block(arguments.repo, check, arguments.lines)) for check in failing]
print("\n\n".join(blocks))
