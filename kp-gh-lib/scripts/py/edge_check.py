import argparse
import collections
import functools
import json
import re
import subprocess
import sys

scripts_dir, *argv = sys.argv[1:]

ISSUE_REF = re.compile(r"([\w.-]+/[\w.-]+)#(\d+)")
SHORT_REF = re.compile(r"#(\d+)")
DRAFT = re.compile(r"draft:(M\d+|none)")
MILESTONE_ID = re.compile(r"M(\d+)")
PROJECT = re.compile(r"[^/\s]+/\d+")
# A loosely matched start marker up to its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
DETAILS_TAG = re.compile(r"<(/?)details\b[^>]*>", re.I)
HTML_COMMENT_LINE = re.compile(r"<!--(.*)-->")
# The project's linked repositories, whether its owner is a user or an organization.
PROJECT_REPOS_QUERY = """query($owner:String!,$number:Int!){ repositoryOwner(login:$owner){
  ... on ProjectV2Owner{ projectV2(number:$number){
    repositories(first:100){ nodes{ nameWithOwner } } } } } }"""


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    parser = Parser(prog="edge-check.sh", add_help=False)
    parser.add_argument("--project", required=True)
    parser.add_argument("dependent")
    parser.add_argument("blocker")
    parser.add_argument("--dependent-epic")
    parser.add_argument("--from-file")
    args = parser.parse_args(argv)
    if not PROJECT.fullmatch(args.project):
        raise UsageError(f"not an owner/number project: {args.project!r}")
    if not (ISSUE_REF.fullmatch(args.dependent) or DRAFT.fullmatch(args.dependent)):
        raise UsageError(f"dependent is neither owner/repo#n nor draft:<M<k>|none>: "
                         f"{args.dependent!r}")
    if not ISSUE_REF.fullmatch(args.blocker):
        raise UsageError(f"blocker is not owner/repo#n: {args.blocker!r}")
    if args.dependent_epic is not None:
        if not DRAFT.fullmatch(args.dependent):
            raise UsageError("--dependent-epic is for a draft dependent only")
        if not ISSUE_REF.fullmatch(args.dependent_epic):
            raise UsageError(f"--dependent-epic is not owner/repo#e: {args.dependent_epic!r}")
    return args


def fail(message):
    print(f"edge-check.sh: {message}", file=sys.stderr)
    sys.exit(1)


def run(command, what):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{what} failed: {result.stderr.strip()}")
    return result.stdout


def resolve(value, repo):
    """`owner/repo#n` for either reference form written in `repo`, else None."""
    if SHORT_REF.fullmatch(value):
        return f"{repo}{value}"
    return value if ISSUE_REF.fullmatch(value) else None


def visible_lines(body):
    """Body lines outside the human-only fence and every <details> block (nesting counted),
    each trimmed and unwrapped from a whole-line `<!-- … -->` — find-marker.sh's reading."""
    text = HUMAN_ONLY_FENCE.sub("\n", (body or "").replace("\r\n", "\n"))
    kept, depth, position = [], 0, 0
    for tag in DETAILS_TAG.finditer(text):
        if depth == 0:
            kept.append(text[position:tag.start()])
        depth = max(depth - 1, 0) if tag.group(1) else depth + 1
        position = tag.end()
        if depth == 0:
            kept.append("\n")
    if depth == 0:
        kept.append(text[position:])
    lines = []
    for line in "".join(kept).split("\n"):
        line = line.strip()
        wrapped = HTML_COMMENT_LINE.fullmatch(line)
        lines.append(wrapped.group(1).strip() if wrapped else line)
    return lines


def marker_values(lines, marker):
    prefix = f"{marker}: "
    return [line[len(prefix):].strip() for line in lines if line.startswith(prefix)]


class GitHub:
    """Live reads: one REST read per node, one blocks: search per owner, milestone-of.sh."""

    def __init__(self, project):
        self.project = project

    @functools.cached_property
    def repos(self):
        owner, number = self.project.split("/")
        what = f"project {self.project} repositories lookup"
        response = json.loads(run(["gh", "api", "graphql", "-f", f"query={PROJECT_REPOS_QUERY}",
                                   "-f", f"owner={owner}", "-F", f"number={number}"], what))
        board = ((response.get("data") or {}).get("repositoryOwner") or {}).get("projectV2")
        if board is None:
            fail(f"project {self.project} not found")
        repos = {node["nameWithOwner"] for node in board["repositories"]["nodes"]}
        if not repos:
            fail(f"project {self.project} has no linked repositories")
        return repos

    @functools.cache
    def node(self, ref):
        repo, number = ref.split("#")
        issue = json.loads(run(["gh", "api", f"repos/{repo}/issues/{number}"],
                               f"{ref} lookup"))
        lines = visible_lines(issue.get("body"))
        spec_refs = marker_values(lines, "spec-ref")
        return {"type": "pr" if issue.get("pull_request") else "issue",
                "specRef": spec_refs[0] if spec_refs else None,
                "blockedBy": marker_values(lines, "blocked-by"),
                "resolves": marker_values(lines, "resolves")}

    @functools.cached_property
    def blocks_lines(self):
        """(issue ref, value) for every `blocks:` line in the project's linked repos."""
        lines = []
        for owner in sorted({repo.split("/")[0] for repo in self.repos}):
            some_repo = min(repo for repo in self.repos if repo.startswith(f"{owner}/"))
            hits = json.loads(run([f"{scripts_dir}/find-marker.sh", some_repo, "blocks",
                                   "--any-value", "--scope", "owner", "--state", "all"],
                                  f"blocks: search for {owner}"))
            lines += [(f"{hit['repo']}#{hit['number']}", hit["value"])
                      for hit in hits if hit["repo"] in self.repos]
        return lines

    @functools.cache
    def milestone(self, ref):
        repo, number = ref.split("#")
        found = json.loads(run([f"{scripts_dir}/milestone-of.sh", repo, number],
                               f"milestone-of.sh {ref}"))
        return found["milestone"], found["epic"]


class Fixture:
    """--from-file reads: the same answers from a JSON file, no GitHub call."""

    def __init__(self, path):
        with open(path) as fixture:
            self.issues = json.load(fixture)["issues"]

    def node(self, ref):
        if ref not in self.issues:
            fail(f"{ref} lookup failed: not in fixture")
        return self.issues[ref]

    @functools.cached_property
    def blocks_lines(self):
        return [(ref, value) for ref, issue in sorted(self.issues.items())
                for value in issue.get("blocks", [])]

    def milestone(self, ref):
        issue = self.node(ref)
        return issue["milestone"], issue["epic"]


def prerequisites(source, ref):
    """What must complete before `ref`: its own blocked-by targets, then every issue whose
    blocks: line names it or its spec-ref, each once, in the order found."""
    node = source.node(ref)
    if node["type"] == "pr":
        return []
    repo = ref.split("#")[0]
    found = [resolve(value, repo) for value in node.get("blockedBy", [])]
    for blocker_of_ref, value in source.blocks_lines:
        target = resolve(value, blocker_of_ref.split("#")[0])
        if target == ref or (target is None and value == node.get("specRef")):
            found.append(blocker_of_ref)
    return list(dict.fromkeys(found_ref for found_ref in found if found_ref))


def cycle_path(source, dependent, blocker):
    """The nodes from the blocker to the dependent when the edge closes a loop, else []."""
    if dependent == blocker:
        return [blocker]
    dependent_repo = dependent.split("#")[0]
    if blocker in {resolve(value, dependent_repo)
                   for value in source.node(dependent).get("resolves", [])}:
        return [blocker, dependent]
    came_from = {blocker: None}
    queue = collections.deque([blocker])
    while queue:
        current = queue.popleft()
        for prerequisite in prerequisites(source, current):
            if prerequisite in came_from:
                continue
            came_from[prerequisite] = current
            if prerequisite == dependent:
                path = [dependent]
                while came_from[path[-1]]:
                    path.append(came_from[path[-1]])
                return path[::-1]
            queue.append(prerequisite)
    return []


def rank(milestone):
    return int(MILESTONE_ID.fullmatch(milestone).group(1))


def decide(args, source):
    result = {"verdict": "ok", "path": [], "dependentMilestone": None,
              "blockerMilestone": None, "pullForwardEpic": None}
    draft = DRAFT.fullmatch(args.dependent)
    if not draft:
        path = cycle_path(source, args.dependent, args.blocker)
        if path:
            return {**result, "verdict": "cycle", "path": path}
    if draft:
        dependent_milestone = None if draft.group(1) == "none" else draft.group(1)
        dependent_epic = args.dependent_epic
    else:
        dependent_milestone, dependent_epic = source.milestone(args.dependent)
    blocker_milestone, _ = source.milestone(args.blocker)
    result.update(dependentMilestone=dependent_milestone, blockerMilestone=blocker_milestone)
    if dependent_milestone is None or blocker_milestone is None:
        return result
    if rank(blocker_milestone) < rank(dependent_milestone):
        return {**result, "verdict": "drop-earlier"}
    if rank(blocker_milestone) > rank(dependent_milestone):
        return {**result, "verdict": "pull-forward", "pullForwardEpic": dependent_epic}
    return result


try:
    arguments = parse_args(argv)
except UsageError as error:
    print(f"edge-check.sh: {error}", file=sys.stderr)
    print("usage: edge-check.sh --project <owner/number> <dependent> <blocker>"
          " [--dependent-epic <owner/repo#e>] [--from-file <json>]", file=sys.stderr)
    sys.exit(2)
source = Fixture(arguments.from_file) if arguments.from_file else GitHub(arguments.project)
print(json.dumps(decide(arguments, source)))
