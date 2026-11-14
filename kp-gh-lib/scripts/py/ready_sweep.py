import argparse
import json
import re
import subprocess
import sys

SWEEP_TIMEOUT_SECONDS = 60
CALL_TIMEOUT_SECONDS = 30
TYPE_LABELS = ("type:coding", "type:decision", "type:question", "type:conflict", "type:research")
KIND_ORDER = ("ambiguous", "item", "gated", "needs-contract")
NEEDS_CONTRACT = "needs-contract"
DEFAULT_MODEL = "opus (no model label)"
PROJECT = re.compile(r"([^/\s]+)/(\d+)")
REPO = re.compile(r"[^/\s#]+/[^/\s#]+")
ONLY_ENTRY = re.compile(r"(?:(?:([^/\s#]+)/)?([^/\s#]+))?#(\d+)|(\d+)")
USER_MISS = re.compile(r'"user":\s*null')
TITLE_PREFIX = re.compile(r"\[[^\]]*\] ")
# The fence and marker regexes of milestone-gate.sh: a loosely matched start marker up to
# its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
BLOCKED_BY = re.compile(r"^[ \t]*blocked-by:[ \t]*([\w.-]+/[\w.-]+)?#(\d+)[ \t]*$", re.M)
SWEEP_QUERY = """
query($owner:String!,$number:Int!,$endCursor:String){
  %s(login:$owner){ projectV2(number:$number){
    items(first:100, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ id
        fieldValueByName(name:"Status"){ ... on ProjectV2ItemFieldSingleSelectValue{ name } }
        content{ ... on Issue{ number state repository{ nameWithOwner }
          labels(first:10){ nodes{ name } } } } } } } } }
"""


class UsageError(Exception):
    pass


class GitHubError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_only(value):
    entries = [entry.strip() for entry in value.split(",") if entry.strip()]
    if not entries:
        raise UsageError("empty --only")
    for entry in entries:
        if not ONLY_ENTRY.fullmatch(entry):
            raise UsageError(f"not an issue reference in --only: {entry!r}")
    return entries


def parse_args(argv):
    parser = Parser(prog="ready-sweep.sh", add_help=False)
    parser.add_argument("--project", required=True)
    parser.add_argument("--repo")
    parser.add_argument("--only")
    parser.add_argument("--label")
    parser.add_argument("--status", default="Ready")
    parser.add_argument("--from-file")
    args = parser.parse_args(argv)
    project = PROJECT.fullmatch(args.project)
    if not project:
        raise UsageError(f"not an <owner>/<number> project: {args.project!r}")
    args.owner, args.number = project.group(1), project.group(2)
    if args.repo is not None and not REPO.fullmatch(args.repo):
        raise UsageError(f"not an owner/name repo: {args.repo!r}")
    args.only = parse_only(args.only) if args.only is not None else None
    return args


def run(command, timeout):
    """The command's stdout; GitHubError on a non-zero exit or a timeout."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise GitHubError(f"{' '.join(command[:4])} timed out after {timeout}s") from error
    if result.returncode != 0:
        raise GitHubError(f"{' '.join(command[:4])} failed: "
                          f"{(result.stderr.strip() or result.stdout.strip())}")
    return result.stdout


def sweep_as(owner_kind, args):
    command = ["gh", "api", "graphql", "--paginate", "--slurp",
               "-f", f"query={SWEEP_QUERY % owner_kind}",
               "-F", f"owner={args.owner}", "-F", f"number={args.number}"]
    try:
        result = subprocess.run(command, capture_output=True, text=True,
                                timeout=SWEEP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise GitHubError(f"board sweep timed out after {SWEEP_TIMEOUT_SECONDS}s") from error
    return result


def sweep(args):
    result = sweep_as("user", args)
    owner_kind = "user"
    output = result.stdout + result.stderr
    if result.returncode != 0 and "NOT_FOUND" in output and USER_MISS.search(output):
        owner_kind = "organization"
        result = sweep_as(owner_kind, args)
    if result.returncode != 0:
        raise GitHubError(f"board sweep ({owner_kind}) failed: "
                          f"{(result.stderr.strip() or result.stdout.strip())}")
    try:
        pages = json.loads(result.stdout)
        return [node for page in pages
                for node in page["data"][owner_kind]["projectV2"]["items"]["nodes"]]
    except (ValueError, KeyError, TypeError) as error:
        raise GitHubError(f"board sweep ({owner_kind}) returned unexpected JSON: {error}") from error


def survivor_ref(node, args):
    """`owner/name#n` for a node step 2 keeps, else None."""
    content = node.get("content") or {}
    if "number" not in content:
        return None
    status = (node.get("fieldValueByName") or {}).get("name")
    labels = {label["name"] for label in content["labels"]["nodes"]}
    if status != args.status or content["state"] != "OPEN" or not labels & set(TYPE_LABELS):
        return None
    repo = content["repository"]["nameWithOwner"]
    if args.repo is not None and repo != args.repo:
        return None
    return (repo, content["number"])


def only_matches(entry, survivors):
    match = ONLY_ENTRY.fullmatch(entry)
    owner, name, number = match.group(1), match.group(2), match.group(3) or match.group(4)
    number = int(number)
    found = []
    for repo, survivor_number in survivors:
        if survivor_number != number:
            continue
        repo_owner, repo_name = repo.split("/", 1)
        if name is not None and repo_name != name:
            continue
        if owner is not None and repo_owner != owner:
            continue
        found.append((repo, survivor_number))
    return found, name is None


def apply_only(entries, survivors):
    """The survivors `--only` selects, and the `ambiguous` lines of bare entries."""
    selected, ambiguous = set(), []
    for entry in entries:
        found, bare = only_matches(entry, survivors)
        repos = sorted({repo for repo, _ in found})
        if bare and len(repos) > 1:
            ambiguous.append(("ambiguous", "", 0, f"ambiguous {entry} | {', '.join(repos)}"))
            continue
        selected.update(found)
    return [ref for ref in survivors if ref in selected], ambiguous


def read_issue(repo, number, fixture):
    if fixture is not None:
        return fixture["issues"][f"{repo}#{number}"]
    return json.loads(run(["gh", "issue", "view", str(number), "-R", repo, "--json",
                           "number,title,body,labels,state,assignees"], CALL_TIMEOUT_SECONDS))


def read_decision_state(script, repo, number, fixture):
    if fixture is not None:
        return fixture["decisionStates"][f"{repo}#{number}"]
    return json.loads(run([script, repo, str(number)], CALL_TIMEOUT_SECONDS))


def blocked_by(body):
    visible = HUMAN_ONLY_FENCE.sub("", (body or "").replace("\r\n", "\n"))
    markers = [f"{match.group(1) or ''}#{match.group(2)}" for match in BLOCKED_BY.finditer(visible)]
    return ", ".join(markers) if markers else "none"


def model_alias(labels):
    aliases = [label.split(":", 1)[1] for label in labels if label.startswith("model:")]
    return aliases[0] if aliases else DEFAULT_MODEL


def mismatch(repo, title, labels):
    repo_name = repo.split("/", 1)[1]
    repo_labels = [label.split(":", 1)[1] for label in labels if label.startswith("repo:")]
    problems = [f"label repo:{code}" for code in repo_labels if code != repo_name]
    if not repo_labels:
        problems.append("no repo label")
    if not TITLE_PREFIX.match(title):
        problems.append("no title prefix")
    return "; ".join(problems) if problems else "none"


def gated_state(state):
    fallback = {"agent": "answered-agent", "session": "answered-person"}.get(
        state["latest"], "unanswered")
    return f"check:{fallback}" if state["humanCandidates"] else fallback


def classify(issue, repo, args, script, fixture):
    """One (kind, repo, number, line) for the issue, or None when --label drops it."""
    labels = [label["name"] for label in issue["labels"]]
    if args.label is not None and args.label not in labels:
        return None
    type_label = next((label for label in TYPE_LABELS if label in labels), None)
    if type_label is None:
        return None
    number, title = issue["number"], issue["title"]
    ref = f"{repo}#{number}"
    if type_label == "type:coding" and NEEDS_CONTRACT in labels:
        return ("needs-contract", repo, number, f"needs-contract {ref} | {title}")
    if type_label == "type:coding":
        fields = [title, model_alias(labels), blocked_by(issue["body"]),
                  mismatch(repo, title, labels)]
        return ("item", repo, number, f"item {ref} | {' | '.join(fields)}")
    if type_label in ("type:conflict", "type:research"):
        return ("gated", repo, number, f"gated {ref} | {title} | {type_label} | -")
    state = gated_state(read_decision_state(script, repo, number, fixture))
    return ("gated", repo, number, f"gated {ref} | {title} | {type_label} | {state}")


def ready_sweep(args, script):
    fixture = None
    if args.from_file:
        with open(args.from_file) as handle:
            fixture = json.load(handle)
    nodes = fixture["nodes"] if fixture is not None else sweep(args)
    survivors = [ref for ref in (survivor_ref(node, args) for node in nodes) if ref]
    lines = []
    if args.only is not None:
        survivors, lines = apply_only(args.only, survivors)
    for repo, number in survivors:
        issue = read_issue(repo, number, fixture)
        line = classify(issue, repo, args, script, fixture)
        if line is not None:
            lines.append(line)
    lines.sort(key=lambda line: (KIND_ORDER.index(line[0]), line[1], line[2]))
    return [line[3] for line in lines]


decision_state_script, *argv = sys.argv[1:]
try:
    arguments = parse_args(argv)
except UsageError as error:
    print(f"ready-sweep.sh: {error}", file=sys.stderr)
    print("usage: ready-sweep.sh --project <owner>/<number> [--repo <owner/name>]"
          " [--only <#,#,…>] [--label <name>] [--status <name>] [--from-file <json>]",
          file=sys.stderr)
    sys.exit(2)
try:
    output = ready_sweep(arguments, decision_state_script)
except GitHubError as error:
    print(f"ready-sweep.sh: {error}", file=sys.stderr)
    sys.exit(1)
for output_line in output:
    print(output_line)
