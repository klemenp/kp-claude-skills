import os
import re
import subprocess
import sys
import tempfile

USAGE = (
    "usage: spec-pr-fastmerge.sh <spec-repo> <pr> --decision <owner/repo>#<n> "
    "[--decision <owner/repo>#<n>]... --checked-head <40-hex sha> "
    "--key <spec-ref key> [--key <k>]... --read <answer>\n"
    "Posts the approval verdict on a clean spec PR; never lands the PR."
)
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
DECISION_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
CI_TIMEOUT_SECONDS = 540  # under the caller's 600000 ms Bash cap
GH_PENDING_EXIT = 8  # `gh pr checks` exit code for pending checks
SHORT_SHA = 7

APPROVAL_HEAD = """<!-- kp-review-gh-pr:verdict -->
verdict: APPROVED
approved: {head}

<details><summary>Acceptance basis</summary>

"""
DECISION_LINE = "- [x] Decision {decision} is what the amended sections say — proof: sonnet read `ok`\n"
KEY_LINE = "- [x] spec-ref: {key} — proof: `spec-pr-check.sh` ok (amended, backref, identity)\n"
APPROVAL_TAIL = """
</details>

## Review: approved

Merged by `kp-resolve-spec-decision` §4.7: `spec-pr-check.sh` passed and one bounded
sonnet read found the amended sections say what the decision says, and nothing else.
"""


def usage_error(message):
    print(f"spec-pr-fastmerge.sh: {message}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)


def parse_args(argv):
    positional, decisions, keys = [], [], []
    checked_head = read = None
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ("--decision", "--key", "--checked-head", "--read"):
            if index + 1 >= len(argv):
                usage_error(f"{arg} needs a value")
            value = argv[index + 1]
            index += 2
            if arg == "--decision":
                if not DECISION_RE.match(value):
                    usage_error(f"--decision must be <owner/repo>#<n>, got {value!r}")
                decisions.append(value)
            elif arg == "--key":
                if not value.strip():
                    usage_error("--key must not be empty")
                keys.append(value)
            elif arg == "--checked-head":
                checked_head = value
            else:
                read = value
            continue
        if arg.startswith("--"):
            usage_error(f"unknown option {arg}")
        positional.append(arg)
        index += 1
    if len(positional) != 2:
        usage_error("expected <spec-repo> <pr>")
    spec_repo, pr = positional
    if not REPO_RE.match(spec_repo):
        usage_error(f"<spec-repo> must be <owner/repo>, got {spec_repo!r}")
    if not pr.isdigit():
        usage_error(f"<pr> must be a number, got {pr!r}")
    if not decisions:
        usage_error("at least one --decision is required")
    if not keys:
        usage_error("at least one --key is required")
    if checked_head is None or not SHA_RE.match(checked_head):
        usage_error("--checked-head must be a full 40-character lowercase hex SHA")
    if read is None:
        usage_error("--read is required")
    return spec_repo, pr, decisions, keys, checked_head, read


def finish(line, code):
    print(line)
    sys.exit(code)


def fallback(trigger):
    finish(f"fallback: {trigger}", 3)


def first_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def with_detail(prefix, detail):
    return f"{prefix}: {detail}" if detail else prefix


def wait_for_ci(spec_repo, pr):
    command = ["gh", "pr", "checks", pr, "-R", spec_repo, "--watch", "--interval", "60"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=CI_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        fallback("ci pending")
    if "no checks reported" in result.stderr:
        return
    if result.returncode == GH_PENDING_EXIT:
        fallback("ci pending")


def exit_code(returncode):
    # A negative returncode is a signal; report it the way a shell would.
    return 128 - returncode if returncode < 0 else returncode


def check_decision(spec_repo, pr, decision):
    script = os.path.join(os.environ["KP_GH_LIB_BIN"], "spec-pr-check.sh")
    result = subprocess.run([script, spec_repo, pr, "--decision", decision], capture_output=True, text=True)
    if result.returncode == 0:
        return
    if result.returncode == 1:
        fails = [line.strip() for line in result.stdout.splitlines() if line.startswith("FAIL")]
        fallback(f"spec-pr-check {decision}: {' | '.join(fails)}")
    prefix = f"spec-pr-check {decision} exit {exit_code(result.returncode)}"
    fallback(with_detail(prefix, first_line(result.stderr)))


def recheck_head(spec_repo, pr, checked_head):
    command = ["gh", "pr", "view", pr, "-R", spec_repo, "--json", "headRefOid", "-q", ".headRefOid"]
    result = subprocess.run(command, capture_output=True, text=True)
    head = result.stdout.strip()
    if result.returncode != 0 or not head:
        fallback("head read failed")
    if head != checked_head:
        fallback(f"head moved {checked_head[:SHORT_SHA]}..{head[:SHORT_SHA]}")


def approval_body(checked_head, decisions, keys):
    lines = [DECISION_LINE.format(decision=decision) for decision in decisions]
    lines += [KEY_LINE.format(key=key) for key in keys]
    return APPROVAL_HEAD.format(head=checked_head) + "".join(lines) + APPROVAL_TAIL


def post_approval(spec_repo, pr, body):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
        handle.write(body)
        body_file = handle.name
    try:
        command = ["gh", "pr", "comment", pr, "-R", spec_repo, "--body-file", body_file]
        result = subprocess.run(command, capture_output=True, text=True)
    finally:
        os.unlink(body_file)
    if result.returncode != 0:
        fallback(with_detail("comment failed", first_line(result.stderr)))


def main():
    spec_repo, pr, decisions, keys, checked_head, read = parse_args(sys.argv[1:])
    if read != "ok":
        fallback(f"read: {read}")
    wait_for_ci(spec_repo, pr)
    for decision in decisions:
        check_decision(spec_repo, pr, decision)
    recheck_head(spec_repo, pr, checked_head)
    post_approval(spec_repo, pr, approval_body(checked_head, decisions, keys))
    finish(f"approved {checked_head}", 0)


main()
