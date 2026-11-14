import argparse
import json
import re
import subprocess
import sys

GH_TIMEOUT_SECONDS = 30
PER_PAGE = 100
REPO = re.compile(r"[^/\s]+/[^/\s]+")
ISSUE_NUMBER = re.compile(r"[1-9][0-9]*")
RESTORED = "<!-- kp-resolve-spec-decision:restored -->"
NO_DECISION = "<!-- kp-resolve-spec-decision:no-decision -->"
SESSION = "<!-- decision-source: claude-code-session -->"
FINDINGS = "<!-- decision-source: kp-resolve-spec-research -->"
AGENT = re.compile(r"<!-- decision-source: (kp-[a-z0-9-]+) -->")
SKILL_OUTPUT_FRAGMENTS = ("<!-- kp-", "<!-- decision-source:")
RESOLVER_OUTCOME_PREFIXES = ("Resolved →", "Closed as won't-do", "Goal recorded →")


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    parser = Parser(prog="decision-state.sh", add_help=False)
    parser.add_argument("repo")
    parser.add_argument("number")
    parser.add_argument("--from-file")
    args = parser.parse_args(argv)
    if not REPO.fullmatch(args.repo):
        raise UsageError(f"not an owner/repo: {args.repo!r}")
    if not ISSUE_NUMBER.fullmatch(args.number):
        raise UsageError(f"not an issue number: {args.number!r}")
    return args


def fail(message):
    print(f"decision-state.sh: {message}", file=sys.stderr)
    sys.exit(1)


def fetch_comments(repo, number):
    command = ["gh", "api", "-X", "GET", f"repos/{repo}/issues/{number}/comments",
               "--paginate", "--slurp", "-f", f"per_page={PER_PAGE}"]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=GH_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        fail(f"{' '.join(command[:5])} timed out after {GH_TIMEOUT_SECONDS}s")
    if result.returncode != 0:
        fail(f"{' '.join(command[:5])} failed: {result.stderr.strip()}")
    try:
        pages = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        fail(f"{' '.join(command[:5])} returned unparseable JSON: {error}")
    return [comment for page in pages for comment in page]


def load_fixture(path):
    try:
        with open(path) as fixture:
            return json.load(fixture)["comments"]
    except (OSError, ValueError, KeyError) as error:
        raise UsageError(f"unreadable --from-file {path!r}: {error}") from error


def lines_of(comment):
    return [line.strip() for line in (comment.get("body") or "").replace("\r\n", "\n").split("\n")]


def order(comment):
    return (comment["created_at"], comment["id"])


def latest_with(comments, predicate):
    matching = [comment for comment in comments if predicate(comment)]
    return matching[-1] if matching else None


def carries(marker):
    return lambda comment: marker in lines_of(comment)


def agent_skill(comment):
    """The `kp-…` skill of the comment's last agent decision-source line, or None."""
    skills = [match.group(1) for match in map(AGENT.fullmatch, lines_of(comment)) if match]
    return skills[-1] if skills else None


def is_skill_output(comment):
    lines = lines_of(comment)
    if any(fragment in line for line in lines for fragment in SKILL_OUTPUT_FRAGMENTS):
        return True
    first = next((line for line in lines if line), "")
    return first.startswith(RESOLVER_OUTCOME_PREFIXES)


def is_bot(comment):
    return (comment.get("user") or {}).get("type") == "Bot"


def after(comments, anchor):
    if anchor is None:
        return comments
    return [comment for comment in comments if order(comment) > order(anchor)]


def classify(comments):
    comments = sorted(comments, key=order)
    cutoff = latest_with(comments, carries(RESTORED))
    current = after(comments, cutoff)
    agent = latest_with(current, lambda comment: agent_skill(comment) is not None)
    session = latest_with(current, carries(SESSION))
    findings = latest_with(current, carries(FINDINGS))
    no_decision = latest_with(comments, carries(NO_DECISION))

    decisions = [comment for comment in (agent, session) if comment is not None]
    newest_decision = max(decisions, key=order) if decisions else None
    latest = None
    if newest_decision is not None:
        latest = "agent" if newest_decision is agent else "session"

    anchors = [comment for comment in (cutoff, agent, session) if comment is not None]
    newest_anchor = max(anchors, key=order) if anchors else None
    candidates = [comment for comment in after(comments, newest_anchor)
                  if not is_skill_output(comment) and not is_bot(comment)]

    no_decision_entry = None
    if no_decision is not None:
        no_decision_entry = {
            "id": no_decision["id"], "url": no_decision["html_url"],
            "newerDecision": newest_decision is not None
            and order(newest_decision) > order(no_decision)}

    return {
        "cutoffId": cutoff["id"] if cutoff else None,
        "agent": {"id": agent["id"], "skill": agent_skill(agent), "url": agent["html_url"]}
        if agent else None,
        "session": {"id": session["id"], "url": session["html_url"], "body": session["body"]}
        if session else None,
        "latest": latest,
        "humanCandidates": [{"id": comment["id"], "url": comment["html_url"],
                             "body": comment["body"]} for comment in candidates],
        "noDecision": no_decision_entry,
        "findings": {"id": findings["id"], "url": findings["html_url"]} if findings else None,
    }


try:
    arguments = parse_args(sys.argv[1:])
    if arguments.from_file:
        all_comments = load_fixture(arguments.from_file)
    else:
        all_comments = None
except UsageError as error:
    print(f"decision-state.sh: {error}", file=sys.stderr)
    print("usage: decision-state.sh <owner/repo> <n> [--from-file <json>]", file=sys.stderr)
    sys.exit(2)
if all_comments is None:
    all_comments = fetch_comments(arguments.repo, arguments.number)
print(json.dumps(classify(all_comments)))
