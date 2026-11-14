import json
import os
import re
import subprocess
import sys
import tempfile

LIB = os.environ["KP_GH_LIB_BIN"]
ITEM_REF = re.compile(r"([^/\s#]+/[^/\s#]+)#([1-9]\d*)")
VALUED = ("--parent", "--child", "--project-id")

# $owner/$name/$number/$parent/$child/$project/$content below are GraphQL variables.
LOOKUP = """query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){ issue(number:$number){
    id parent{ number repository{ nameWithOwner } } } } }"""
ADD_ITEM = """mutation($project:ID!,$content:ID!){
  addProjectV2ItemById(input:{projectId:$project,contentId:$content}){ item{ id } } }"""
ADD_SUB_ISSUE = """mutation($parent:ID!,$child:ID!){
  addSubIssue(input:{issueId:$parent, subIssueId:$child}){ clientMutationId } }"""

EXIT_LINKED, EXIT_NOT_LINKED, EXIT_USAGE, EXIT_BOARD_FAILED = 0, 1, 2, 3


def usage(problem):
    print(f"link-item.sh: {problem}", file=sys.stderr)
    print("usage: link-item.sh --parent <owner/repo#p> --child <owner/repo#c> "
          "[--project-id <project node id>]", file=sys.stderr)
    sys.exit(EXIT_USAGE)


def parse(argv):
    args = {}
    position = 0
    while position < len(argv):
        name = argv[position]
        if name not in VALUED:
            usage(f"unknown option {name}")
        if position + 1 >= len(argv):
            usage(f"{name} needs a value")
        args[name] = argv[position + 1]
        position += 2
    for name in ("--parent", "--child"):
        if not ITEM_REF.fullmatch(args.get(name, "")):
            usage(f"{name} must be <owner>/<repo>#<positive integer>")
    if args["--parent"].lower() == args["--child"].lower():
        usage("--parent and --child are the same issue")
    if "--project-id" in args and not args["--project-id"]:
        usage("--project-id is empty")
    return args


def run(*command):
    """(ok, stdout, first stderr line or exit description)."""
    result = subprocess.run(command, capture_output=True, text=True)
    lines = result.stderr.strip().splitlines()
    reason = lines[0] if lines else f"{os.path.basename(command[0])} exited {result.returncode}"
    return result.returncode == 0, result.stdout, reason


def graphql(query, **variables):
    """(data, None) or (None, reason). A 200 carrying `errors` is a failure too."""
    command = ["gh", "api", "graphql", "-f", f"query={query}"]
    for name, value in variables.items():
        command += ["-F", f"{name}={value}"]
    ok, stdout, reason = run(*command)
    if not ok:
        return None, reason
    try:
        response = json.loads(stdout)
    except ValueError:
        return None, "unreadable GraphQL response"
    errors = response.get("errors")
    if errors:
        return None, errors[0].get("message") or "GraphQL error"
    return response.get("data") or {}, None


def lookup(ref):
    """The issue's node id and its current parent ref (or None); LookupError on failure."""
    repo, number = ITEM_REF.fullmatch(ref).groups()
    owner, name = repo.split("/")
    data, error = graphql(LOOKUP, owner=owner, name=name, number=number)
    if error:
        raise LookupError(f"cannot look up {ref}: {error}")
    issue = (data.get("repository") or {}).get("issue")
    if not issue:
        raise LookupError(f"cannot look up {ref}: no such issue")
    parent = issue.get("parent")
    parent_ref = (f"{parent['repository']['nameWithOwner']}#{parent['number']}"
                  if parent else None)
    return issue["id"], parent_ref


def child_url(child):
    repo, number = ITEM_REF.fullmatch(child).groups()
    return f"https://github.com/{repo}/issues/{number}"


def rung_native(parent, child, _parent_id, _child_id):
    ok, stdout, reason = run("gh", "issue", "edit", "--help")
    if not ok or "--add-sub-issue" not in stdout:
        return "gh issue edit has no --add-sub-issue flag"
    repo, number = ITEM_REF.fullmatch(parent).groups()
    ok, _, reason = run("gh", "issue", "edit", number, "-R", repo,
                        "--add-sub-issue", child_url(child))
    return None if ok else reason


def rung_graphql(_parent, _child, parent_id, child_id):
    _, error = graphql(ADD_SUB_ISSUE, parent=parent_id, child=child_id)
    return error


def rung_extension(parent, child, _parent_id, _child_id):
    ok, stdout, reason = run("gh", "extension", "list")
    if not ok:
        return reason
    if "sub-issue" not in stdout:
        return "gh-sub-issue extension not installed"
    repo, number = ITEM_REF.fullmatch(parent).groups()
    ok, _, reason = run("gh", "sub-issue", "add", number, child_url(child), "-R", repo)
    return None if ok else reason


def references(body, parent_repo, child):
    """Whether the parent body already names the child (NOTES § *Sub-issue linking* (4))."""
    child_repo, number = ITEM_REF.fullmatch(child).groups()
    full = re.compile(re.escape(child_repo) + "#" + number + r"(?!\d)", re.IGNORECASE)
    if full.search(body):
        return True
    same_repo = child_repo.lower() == parent_repo.lower()
    return same_repo and re.search(r"(?<!/)#" + number + r"(?!\d)", body) is not None


def rung_tasklist(parent, child, _parent_id, _child_id):
    parent_repo, number = ITEM_REF.fullmatch(parent).groups()
    child_repo, child_number = ITEM_REF.fullmatch(child).groups()
    ok, stdout, reason = run("gh", "issue", "view", number, "-R", parent_repo,
                             "--json", "body")
    if not ok:
        return reason
    try:
        body = json.loads(stdout)["body"] or ""
    except (ValueError, KeyError):
        return "unreadable parent body"
    if references(body, parent_repo, child):
        return None
    target = (f"#{child_number}" if child_repo.lower() == parent_repo.lower()
              else f"{child_repo}#{child_number}")
    separator = "" if not body or body.endswith("\n") else "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
        handle.write(f"{body}{separator}- [ ] {target}\n")
        path = handle.name
    try:
        ok, _, reason = run("gh", "issue", "edit", number, "-R", parent_repo,
                            "--body-file", path)
    finally:
        os.unlink(path)
    return None if ok else reason


LADDER = (("native", rung_native), ("graphql", rung_graphql),
          ("extension", rung_extension), ("tasklist", rung_tasklist))


def link(parent, child, child_id):
    """The rung that linked, or None. Each failed rung is one stderr line."""
    try:
        parent_id, _ = lookup(parent)
    except LookupError as error:
        print(f"parent: {error}", file=sys.stderr)
        return None
    for name, rung in LADDER:
        reason = rung(parent, child, parent_id, child_id)
        if reason is None:
            return name
        print(f"{name}: {reason}", file=sys.stderr)
    return None


def board_add(child, child_id, project_id):
    """The child's board item id, or None after one stderr line."""
    repo, number = ITEM_REF.fullmatch(child).groups()
    ok, stdout, reason = run(os.path.join(LIB, "item-id.sh"), repo, number, project_id)
    if not ok:
        print(f"board-add: {reason}", file=sys.stderr)
        return None
    item_id = json.loads(stdout).get("itemId")
    if item_id:
        return item_id
    data, error = graphql(ADD_ITEM, project=project_id, content=child_id)
    if error:
        print(f"board-add: {error}", file=sys.stderr)
        return None
    return data["addProjectV2ItemById"]["item"]["id"]


def finish(via, board_item, board_failed):
    print(json.dumps({"linked": via is not None, "via": via, "boardItem": board_item}))
    if via is None:
        sys.exit(EXIT_NOT_LINKED)
    sys.exit(EXIT_BOARD_FAILED if board_failed else EXIT_LINKED)


def main():
    args = parse(sys.argv[1:])
    parent, child = args["--parent"], args["--child"]
    try:
        child_id, current_parent = lookup(child)
    except LookupError as error:
        print(f"child: {error}", file=sys.stderr)
        finish(None, None, False)

    if current_parent is None:
        via = link(parent, child, child_id)
    elif current_parent.lower() == parent.lower():
        via = "existing"
    else:
        print(f"{child} has parent {current_parent}", file=sys.stderr)
        via = None

    board_item = None
    project_id = args.get("--project-id")
    if project_id:
        board_item = board_add(child, child_id, project_id)
    finish(via, board_item, project_id is not None and board_item is None)


main()
