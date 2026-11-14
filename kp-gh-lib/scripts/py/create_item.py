import json
import os
import re
import subprocess
import sys
import tempfile

LIB = os.environ["KP_GH_LIB_BIN"]
REPO = re.compile(r"[^/\s]+/[^/\s]+")
PROJECT = re.compile(r"[^/\s]+/\d+")
ITEM_REF = re.compile(r"[^/\s]+/[^/\s#]+#\d+")
TOKEN = "__ISSUE__"
HUMAN_GATED = ("type:decision", "type:question", "type:conflict")
SEND = os.environ.get("KP_MSG_ME_SEND") or os.path.expanduser(
    "~/.claude/skills/kp-msg-me/scripts/send.sh")
VALUED = {"--repo", "--title", "--body-file", "--label", "--project", "--priority",
          "--status", "--assignee", "--origin", "--parent", "--link-under", "--cache",
          "--decided-body-file"}
DECIDED_LABEL = "type:decision"
FLAGS = {"--assign-owner", "--no-place"}

# $project/$content/$parent/$child below are GraphQL variables.
ADD_ITEM = """mutation($project:ID!,$content:ID!){
  addProjectV2ItemById(input:{projectId:$project,contentId:$content}){ item{ id } } }"""
ADD_SUB_ISSUE = """mutation($parent:ID!,$child:ID!){
  addSubIssue(input:{issueId:$parent, subIssueId:$child}){ clientMutationId } }"""


def usage():
    print("usage: create-item.sh --repo <owner/repo> --title <t> --body-file <f> --label <l>… "
          "[--project <owner/number>] [--priority top] [--status <name>] "
          "[--assignee <login> | --assign-owner] [--origin <owner/repo#n>] "
          "[--parent <owner/repo#n>] [--no-place] [--link-under <owner/repo#p>] "
          "[--cache <file>] [--decided-body-file <f>]", file=sys.stderr)
    sys.exit(2)


def parse(argv):
    args = {"labels": []}
    position = 0
    while position < len(argv):
        name = argv[position]
        if name in FLAGS:
            args[name] = True
            position += 1
            continue
        if name not in VALUED or position + 1 >= len(argv):
            usage()
        value = argv[position + 1]
        if name == "--label":
            args["labels"].append(value)
        else:
            args[name] = value
        position += 2

    checks = [
        REPO.fullmatch(args.get("--repo", "")),
        args.get("--title"),
        os.path.isfile(args.get("--body-file", "")),
        args["labels"],
        "--project" not in args or PROJECT.fullmatch(args["--project"]),
        args.get("--priority", "top") == "top",
        "--link-under" not in args or "--parent" not in args,
        "--decided-body-file" not in args
        or (os.path.isfile(args["--decided-body-file"]) and DECIDED_LABEL in args["labels"]),
    ]
    for ref in ("--origin", "--parent", "--link-under"):
        checks.append(ref not in args or ITEM_REF.fullmatch(args[ref]))
    if not all(checks):
        usage()
    # A creator-decided item must land where kp-do-gh-ready-items sweeps.
    if "--decided-body-file" in args and "--status" not in args:
        args["--status"] = "Ready"
    return args


def run(*command):
    """(ok, stdout, first stderr line or exit description)."""
    result = subprocess.run(command, capture_output=True, text=True)
    lines = result.stderr.strip().splitlines()
    reason = lines[0] if lines else f"{os.path.basename(command[0])} exited {result.returncode}"
    return result.returncode == 0, result.stdout, reason


def lib(name, *arguments):
    return run(os.path.join(LIB, name), *arguments)


def graphql_errors(stdout):
    """A 200 can still carry `errors` beside a null payload — that is a failure."""
    try:
        errors = json.loads(stdout).get("errors")
    except ValueError:
        return "unreadable GraphQL response"
    return errors and (errors[0].get("message") or "GraphQL error")


class Chain:
    def __init__(self, args):
        self.args = args
        self.repo = args["--repo"]
        self.skipped = []
        self.number = None
        self.url = None
        self.content_id = None
        self.item_id = None
        self.board = None
        self.decided = False
        self.status_set = False

    def skip(self, step, reason):
        self.skipped.append({"step": step, "reason": reason})

    def create(self):
        command = ["gh", "issue", "create", "-R", self.repo, "--title", self.args["--title"],
                   "--body-file", self.args["--body-file"]]
        for label in self.args["labels"]:
            command += ["--label", label]
        ok, stdout, reason = run(*command)
        url = stdout.strip().splitlines()[-1] if stdout.strip() else ""
        number = url.rsplit("/", 1)[-1]
        if not ok or not number.isdigit():
            print(f"create-item.sh: cannot create the issue in {self.repo}: {reason}",
                  file=sys.stderr)
            sys.exit(1)
        self.url, self.number = url, int(number)

    def substitute(self):
        with open(self.args["--body-file"]) as body_file:
            body = body_file.read()
        if TOKEN not in body:
            return
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as final:
            final.write(body.replace(TOKEN, str(self.number)))
        try:
            ok, _, reason = run("gh", "issue", "edit", str(self.number), "-R", self.repo,
                                "--body-file", final.name)
        finally:
            os.unlink(final.name)
        if not ok:
            self.skip("substitute", f"body still carries {TOKEN}: {reason}")

    def decide(self):
        """Post the creator's decision comment, with the item's own number substituted."""
        if "--decided-body-file" not in self.args:
            return
        with open(self.args["--decided-body-file"]) as decided_file:
            comment = decided_file.read().replace(TOKEN, str(self.number))
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as final:
            final.write(comment)
        try:
            ok, _, reason = run("gh", "issue", "comment", str(self.number), "-R", self.repo,
                                "--body-file", final.name)
        finally:
            os.unlink(final.name)
        if ok:
            self.decided = True
        else:
            self.skip("decided", reason)

    def notify(self):
        gate = next((label for label in self.args["labels"] if label in HUMAN_GATED), None)
        if not gate:
            return
        # A decided item that landed Ready with its comment needs nobody; the sweep
        # resolves it and pings only if that fails (NOTES § *Operator notifications*).
        if self.decided and self.status_set:
            return
        message = (f"{self.repo}#{self.number} {gate.split(':')[1]}: {self.args['--title']}"
                   f" — needs your call {self.url}")
        ok, _, reason = run(SEND, message)
        if not ok:
            self.skip("notify", reason)

    def resolve_board(self):
        owner, number = self.args["--project"].split("/")
        ok, stdout, reason = lib("resolve-board.sh", owner, number)
        if ok:
            self.board = json.loads(stdout)
        return reason

    def assign(self, board_reason):
        login = self.args.get("--assignee")
        if not login and "--assign-owner" in self.args:
            if "--project" not in self.args:
                return self.skip("assignee", "no project")
            if not self.board:
                return self.skip("assignee", f"board unresolved: {board_reason}")
            if self.board["ownerType"] != "user":
                return self.skip("assignee", "organization-owned project")
            login = self.args["--project"].split("/")[0]
        if not login:
            return
        ok, _, reason = run("gh", "issue", "edit", str(self.number), "-R", self.repo,
                            "--add-assignee", login)
        if not ok:
            self.skip("assignee", reason)

    def board_add(self, board_reason):
        if not self.board:
            return self.skip("board-add", f"board unresolved: {board_reason}")
        project_id = self.board["projectId"]
        ok, stdout, reason = lib("item-id.sh", self.repo, str(self.number), project_id)
        if not ok:
            return self.skip("board-add", reason)
        found = json.loads(stdout)
        self.content_id = found["contentId"]
        if found["itemId"]:
            self.item_id = found["itemId"]
            return
        ok, stdout, reason = run("gh", "api", "graphql", "-f", f"query={ADD_ITEM}",
                                 "-F", f"project={project_id}", "-F", f"content={self.content_id}")
        error = reason if not ok else graphql_errors(stdout)
        if error:
            return self.skip("board-add", error)
        self.item_id = json.loads(stdout)["data"]["addProjectV2ItemById"]["item"]["id"]

    def set_priority(self):
        if not self.item_id:
            return self.skip("priority", "not on the board")
        field = self.board["priority"]
        if not field or not field["options"]:
            return self.skip("priority", "board has no Priority field")
        ok, _, reason = run("gh", "project", "item-edit", "--id", self.item_id,
                            "--project-id", self.board["projectId"], "--field-id",
                            field["fieldId"], "--single-select-option-id",
                            field["options"][0]["id"])
        if not ok:
            self.skip("priority", reason)

    def set_status(self):
        name = self.args["--status"]
        if not self.item_id:
            return self.skip("status", "not on the board")
        field = self.board["status"]
        if not field:
            return self.skip("status", "board has no Status field")
        option = next((option for option in field["options"] if option["name"] == name), None)
        if not option:
            return self.skip("status", f"board has no Status option {name}")
        ok, _, reason = lib("set-status.sh", self.board["projectId"], self.item_id,
                            field["fieldId"], option["id"])
        if not ok:
            return self.skip("status", reason)
        self.status_set = True

    def place(self):
        owner, number = self.args["--project"].split("/")
        cache = self.args.get("--cache") or os.path.join(
            os.environ.get("TMPDIR") or "/tmp", f"kp-milestone-current-{owner}-{number}.json")
        command = ["milestone-place.sh", "--project", self.args["--project"],
                   "--repo", self.repo, "--cache", cache]
        for name in ("--origin", "--parent"):
            if name in self.args:
                command += [name, self.args[name]]
        ok, stdout, reason = lib(*command)
        if not ok:
            self.skip("place", reason)
            return None
        return json.loads(stdout)

    def node_id(self, ref):
        if ref == f"{self.repo}#{self.number}" and self.content_id:
            return self.content_id
        repo, number = ref.split("#")
        ok, stdout, reason = run("gh", "issue", "view", number, "-R", repo, "--json", "id",
                                 "-q", ".id")
        if not ok or not stdout.strip():
            raise LookupError(f"cannot resolve {ref}: {reason}")
        return stdout.strip()

    def link(self, parent, child):
        """Link child under parent with GraphQL addSubIssue (NOTES § *Sub-issue linking*)."""
        try:
            parent_id, child_id = self.node_id(parent), self.node_id(child)
        except LookupError as error:
            return self.skip("link", str(error))
        ok, stdout, reason = run("gh", "api", "graphql", "-f", f"query={ADD_SUB_ISSUE}",
                                 "-F", f"parent={parent_id}", "-F", f"child={child_id}")
        error = reason if not ok else graphql_errors(stdout)
        if error:
            self.skip("link", f"{child} under {parent}: {error}")

    def execute(self):
        self.create()
        self.substitute()
        self.decide()
        # A decided item's ping waits for the status step, which decides whether one is due.
        deciding = "--decided-body-file" in self.args
        if not deciding:
            self.notify()
        has_project = "--project" in self.args
        board_reason = self.resolve_board() if has_project else "no project"
        self.assign(board_reason)
        placement = {"milestone": None, "epic": None, "link": "none"}
        if not has_project:
            for step in ("board-add", "priority", "status", "place", "link"):
                if step == "board-add" or self.wanted(step):
                    self.skip(step, "no project")
            if deciding:
                self.notify()
            return self.output(placement)

        self.board_add(board_reason)
        if "--priority" in self.args:
            self.set_priority()
        if "--status" in self.args:
            self.set_status()
        if deciding:
            self.notify()
        itself = f"{self.repo}#{self.number}"
        if "--link-under" in self.args:
            self.link(self.args["--link-under"], itself)
            return self.output(placement)
        if "--parent" in self.args:
            self.link(self.args["--parent"], itself)
        if "--no-place" in self.args:
            return self.output(placement)
        placed = self.place()
        if placed:
            placement = placed
            if placed["link"] == "item":
                self.link(placed["epic"], itself)
            elif placed["link"] != "none":
                self.link(placed["epic"], placed["link"])
        return self.output(placement)

    def wanted(self, step):
        if step == "priority":
            return "--priority" in self.args
        if step == "status":
            return "--status" in self.args
        if step == "place":
            return "--no-place" not in self.args and "--link-under" not in self.args
        return "--link-under" in self.args or "--parent" in self.args or self.wanted("place")

    def output(self, placement):
        return {"number": self.number, "url": self.url, "itemId": self.item_id,
                "milestone": placement["milestone"], "epic": placement["epic"],
                "link": placement["link"], "skipped": self.skipped}


print(json.dumps(Chain(parse(sys.argv[1:])).execute()))
