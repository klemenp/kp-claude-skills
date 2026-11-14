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
ESCALATED = "<!-- kp-resolve-spec-decision-auto:escalated -->"
RESTORED = "<!-- kp-resolve-spec-decision:restored -->"
SEND = os.environ.get("KP_MSG_ME_SEND") or os.path.expanduser(
    "~/.claude/skills/kp-msg-me/scripts/send.sh")
MARKER = re.compile(r"^(spec-ref|blocks|blocked-by|resolves|slice|parent|milestone|spec-pr"
                    r"|goal-ref|goal-answered): ")
FENCE_LINE = re.compile(r"^`{3,}$")
VERBATIM_INTRO = ("Original title and body, verbatim — `/kp-resolve-spec-decision` restores "
                  "the decision from this block once the goal is recorded:")

SUBCOMMANDS = {
    "escalate": {
        "required": {"--repo", "--issue", "--goal-title", "--goal-body-file", "--goal-ref",
                     "--missing-fact"},
        "optional": {"--creator"},
        "flags": set(),
    },
    "create": {
        "required": {"--repo", "--technical-body-file", "--technical-title",
                     "--technical-type", "--goal-body-file", "--goal-title", "--goal-ref",
                     "--missing-fact", "--creator"},
        "optional": {"--label", "--project", "--priority", "--origin", "--parent"},
        "flags": {"--assign-owner"},
    },
    "restore": {
        "required": {"--repo", "--issue", "--pr-url"},
        "optional": set(),
        "flags": set(),
    },
}


def usage():
    print("usage: goal-question.sh escalate --repo <owner/repo> --issue <n> --goal-title <t> "
          "--goal-body-file <f> --goal-ref <key> --missing-fact <text> [--creator <skill>]\n"
          "       goal-question.sh create --repo <owner/repo> --technical-body-file <f> "
          "--technical-title <t> --technical-type <label> --goal-body-file <f> "
          "--goal-title <t> --goal-ref <key> --missing-fact <text> --creator <skill> "
          "[--label <l>…] [--project <owner/number>] [--priority top] [--assign-owner] "
          "[--origin <owner/repo#n>] [--parent <owner/repo#n>]\n"
          "       goal-question.sh restore --repo <owner/repo> --issue <n> --pr-url <url>",
          file=sys.stderr)
    sys.exit(2)


def parse(argv):
    if not argv or argv[0] not in SUBCOMMANDS:
        usage()
    spec = SUBCOMMANDS[argv[0]]
    valued = spec["required"] | spec["optional"]
    args = {"subcommand": argv[0], "labels": []}
    position = 1
    while position < len(argv):
        name = argv[position]
        if name in spec["flags"]:
            args[name] = True
            position += 1
            continue
        if name not in valued or position + 1 >= len(argv):
            usage()
        value = argv[position + 1]
        if name == "--label":
            args["labels"].append(value)
        else:
            args[name] = value
        position += 2

    present = set(args) | ({"--label"} if args["labels"] else set())
    checks = [
        spec["required"] <= present,
        REPO.fullmatch(args.get("--repo", "")),
        "--issue" not in args or args["--issue"].isdigit(),
        "--project" not in args or PROJECT.fullmatch(args["--project"]),
        args.get("--priority", "top") == "top",
        "--technical-type" not in args or args["--technical-type"].startswith("type:"),
    ]
    for name in ("--goal-body-file", "--technical-body-file"):
        checks.append(name not in args or os.path.isfile(args[name]))
    for ref in ("--origin", "--parent"):
        checks.append(ref not in args or ITEM_REF.fullmatch(args[ref]))
    if not all(checks):
        usage()
    return args


def run(*command):
    """(ok, stdout, first stderr line or exit description)."""
    result = subprocess.run(command, capture_output=True, text=True)
    lines = result.stderr.strip().splitlines()
    reason = lines[0] if lines else f"{os.path.basename(command[0])} exited {result.returncode}"
    return result.returncode == 0, result.stdout, reason


def read_file(path):
    with open(path) as source:
        return source.read()


def write_temp(text):
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as target:
        target.write(text)
    return target.name


def same_text(left, right):
    return left.rstrip("\n") == right.rstrip("\n")


def comment_id(url):
    match = re.search(r"#issuecomment-(\d+)", url or "")
    return int(match.group(1)) if match else None


def fence_for(body):
    longest = max((len(run_) for run_ in re.findall(r"`+", body)), default=2)
    return "`" * max(longest + 1, 3)


def escalation_comment(lead, key, restore_type, title, body):
    """The restore source, in the shape kp-resolve-spec-decision-auto §4.0 has always posted."""
    fence = fence_for(body)
    header = [lead, f"goal-ref: {key}"]
    if restore_type:
        header.append(f"restore-type: {restore_type}")
    header.append(VERBATIM_INTRO)
    return ("".join(line + "\n\n" for line in header)
            + f"{fence}\n{title}\n\n{body}\n{fence}\n"
            + f"\n{ESCALATED}\n")


def split_escalation(text):
    """(header text, original title, original body) from an escalation comment."""
    lines = text.replace("\r\n", "\n").split("\n")
    opening = next((index for index, line in enumerate(lines) if FENCE_LINE.match(line)), None)
    if opening is None:
        raise ValueError("escalation comment has no verbatim block")
    fence = lines[opening]
    closing = max((index for index, line in enumerate(lines)
                   if line == fence and index > opening), default=None)
    if closing is None:
        raise ValueError("escalation comment's verbatim block is not closed")
    block = "\n".join(lines[opening + 1:closing])
    title, separator, body = block.partition("\n\n")
    if not separator:
        raise ValueError("escalation comment's verbatim block has no title line")
    return "\n".join(lines[:opening]), title, body


def with_goal_answered(body, line):
    """Insert `line` after the last marker line outside the human-only fence and <details>;
    with none, after the human-only fence, else at the top (NOTES § *Goal questions*)."""
    lines = body.split("\n")
    fenced, last_marker, fence_end = False, None, None
    for index, text in enumerate(lines):
        if re.search(r"<!-- human-only:start|^<details", text):
            fenced = True
        elif "<!-- human-only:end" in text:
            fenced = False
            if fence_end is None:
                fence_end = index
        elif text.startswith("</details>"):
            fenced = False
        elif not fenced and MARKER.match(text):
            last_marker = index
    if last_marker is not None:
        lines = lines[:last_marker + 1] + [line] + lines[last_marker + 1:]
    elif fence_end is not None:
        lines = lines[:fence_end + 1] + ["", line] + lines[fence_end + 1:]
    else:
        lines = [line, ""] + lines
    return "\n".join(lines)


class Issue:
    def __init__(self, repo, number):
        self.repo = repo
        self.number = number
        self.title = None
        self.body = None
        self.labels = []
        self.comments = []
        self.skipped = []

    def load(self):
        ok, stdout, reason = run("gh", "issue", "view", str(self.number), "-R", self.repo,
                                 "--json", "title,body,labels,comments")
        if not ok:
            fail(f"cannot read {self.repo}#{self.number}: {reason}")
        found = json.loads(stdout)
        self.title = found["title"]
        self.body = found["body"]
        self.labels = [label["name"] for label in found["labels"]]
        self.comments = found["comments"]

    def latest(self, marker):
        """(index, comment) of the newest comment carrying marker, or (-1, None)."""
        for index in range(len(self.comments) - 1, -1, -1):
            if marker in self.comments[index]["body"]:
                return index, self.comments[index]
        return -1, None

    def skip(self, step, reason):
        self.skipped.append({"step": step, "reason": reason})

    def comment(self, text):
        """The posted comment's id, or None after recording the failure."""
        path = write_temp(text)
        try:
            ok, stdout, reason = run("gh", "issue", "comment", str(self.number), "-R",
                                     self.repo, "--body-file", path)
        finally:
            os.unlink(path)
        if not ok:
            self.skip("comment", reason)
            return None
        return comment_id(stdout.strip()) or 0

    def edit(self, step, title, body):
        """Set title and body unless both already match; False on failure."""
        if title == self.title and same_text(body, self.body):
            return True
        path = write_temp(body)
        try:
            ok, _, reason = run("gh", "issue", "edit", str(self.number), "-R", self.repo,
                                "--title", title, "--body-file", path)
        finally:
            os.unlink(path)
        if not ok:
            self.skip(step, reason)
            return False
        self.title, self.body = title, body
        return True

    def swap_label(self, step, add, remove):
        """Make `add` present and `remove` absent; create `add` once if the repo lacks it."""
        removing = remove if remove != add and remove in self.labels else None
        if add in self.labels and not removing:
            return True
        command = ["gh", "issue", "edit", str(self.number), "-R", self.repo, "--add-label", add]
        if removing:
            command += ["--remove-label", removing]
        ok, _, reason = run(*command)
        if not ok:
            run("gh", "label", "create", add, "-R", self.repo, "--force")
            ok, _, reason = run(*command)
        if not ok:
            self.skip(step, reason)
            return False
        self.labels = [label for label in self.labels if label != removing]
        if add not in self.labels:
            self.labels.append(add)
        return True

    def output(self, action, posted_id, code=0):
        print(json.dumps({"issue": self.number, "action": action, "commentId": posted_id,
                          "title": self.title, "labels": self.labels,
                          "skipped": self.skipped}))
        sys.exit(code)


def fail(message):
    print(f"goal-question.sh: {message}", file=sys.stderr)
    sys.exit(1)


def escalate(args):
    issue = Issue(args["--repo"], int(args["--issue"]))
    issue.load()
    key = args["--goal-ref"]
    escalated_at, escalated = issue.latest(ESCALATED)
    restored_at, _ = issue.latest(RESTORED)
    already = (escalated is not None and escalated_at > restored_at
               and re.search(rf"(?m)^goal-ref: {re.escape(key)}$",
                             split_escalation(escalated["body"])[0]))
    if already:
        action, posted_id = "already-escalated", comment_id(escalated.get("url"))
    else:
        creator = args.get("--creator", "kp-resolve-spec-decision-auto")
        lead = (f"**Escalated to a goal question (agent, via /{creator}).** No option is "
                f"clearly best on the requirement, and the spec does not say "
                f"{args['--missing-fact']}.")
        posted_id = issue.comment(escalation_comment(lead, key, "type:decision",
                                                     issue.title, issue.body))
        if posted_id is None:
            issue.output(None, None, 3)
        action = "escalated"
    goal_body = read_file(args["--goal-body-file"])
    if not issue.edit("edit", args["--goal-title"], goal_body):
        issue.output(action, posted_id, 1)
    if not issue.swap_label("label", "type:question", "type:decision"):
        issue.output(action, posted_id, 1)
    if action == "escalated":
        notify(issue)
    issue.output(action, posted_id)


def notify(issue):
    """Ping the operator: the escalation puts a new question in front of them."""
    message = (f"{issue.repo}#{issue.number} question: {issue.title} — needs your call "
               f"https://github.com/{issue.repo}/issues/{issue.number}")
    ok, _, reason = run(SEND, message)
    if not ok:
        issue.skip("notify", reason)


def create_goal_issue(args, goal_body_path):
    """(number, skipped) — through create-item.sh when the library has it."""
    labels = ["type:question"] + [label for label in args["labels"] if label != "type:question"]
    chain = os.path.join(LIB, "create-item.sh")
    if os.path.exists(chain):
        command = [chain, "--repo", args["--repo"], "--title", args["--goal-title"],
                   "--body-file", goal_body_path]
        for label in labels:
            command += ["--label", label]
        for name in ("--project", "--priority", "--origin", "--parent"):
            if name in args:
                command += [name, args[name]]
        if "--assign-owner" in args:
            command.append("--assign-owner")
        ok, stdout, reason = run(*command)
        if not ok:
            fail(f"cannot create the goal question in {args['--repo']}: {reason}")
        created = json.loads(stdout)
        return created["number"], created["skipped"]

    skipped = [{"step": "create-item", "reason": "create-item.sh absent"}]
    command = ["gh", "issue", "create", "-R", args["--repo"], "--title", args["--goal-title"],
               "--body-file", goal_body_path]
    for label in labels:
        command += ["--label", label]
    ok, stdout, reason = run(*command)
    number = stdout.strip().rsplit("/", 1)[-1] if stdout.strip() else ""
    if not ok or not number.isdigit():
        fail(f"cannot create the goal question in {args['--repo']}: {reason}")
    goal_body = read_file(goal_body_path)
    if TOKEN in goal_body:
        path = write_temp(goal_body.replace(TOKEN, number))
        try:
            ok, _, reason = run("gh", "issue", "edit", number, "-R", args["--repo"],
                                "--body-file", path)
        finally:
            os.unlink(path)
        if not ok:
            skipped.append({"step": "substitute", "reason": f"body still carries {TOKEN}: {reason}"})
    return int(number), skipped


def create(args):
    repo = args["--repo"]
    # create-item.sh creates no labels; an already-present label makes this a no-op failure.
    run("gh", "label", "create", "type:question", "-R", repo)
    number, skipped = create_goal_issue(args, args["--goal-body-file"])
    issue = Issue(repo, number)
    issue.load()
    issue.skipped = list(skipped)

    technical_type = args["--technical-type"]
    technical_body = read_file(args["--technical-body-file"]).replace(TOKEN, str(number))
    lead = (f"**Raised as a goal question (agent, via /{args['--creator']}).** The spec does "
            f"not say {args['--missing-fact']}.")
    posted_id = issue.comment(escalation_comment(lead, args["--goal-ref"], technical_type,
                                                 args["--technical-title"],
                                                 technical_body.rstrip("\n")))
    if posted_id is not None:
        issue.output("created", posted_id)

    # A goal question never exists without its restore source: put the technical item back.
    reverted = (issue.edit("revert", args["--technical-title"], technical_body)
                and issue.swap_label("revert", technical_type, "type:question"))
    issue.output(None, None, 3 if reverted else 1)


def restore(args):
    issue = Issue(args["--repo"], int(args["--issue"]))
    issue.load()
    escalated_at, escalated = issue.latest(ESCALATED)
    if escalated is None:
        fail(f"{issue.repo}#{issue.number} has no escalation comment to restore from")
    try:
        header, title, body = split_escalation(escalated["body"])
    except ValueError as error:
        fail(f"{issue.repo}#{issue.number}: {error}")
    key = re.search(r"(?m)^goal-ref: (\S+)$", header)
    if not key:
        fail(f"{issue.repo}#{issue.number}: escalation comment carries no goal-ref: line")
    restore_type = re.search(r"(?m)^restore-type: (type:[a-z]+)$", header)
    restore_type = restore_type.group(1) if restore_type else "type:decision"

    answered = f"goal-answered: {key.group(1)} via {args['--pr-url']}"
    if not issue.edit("edit", title, with_goal_answered(body, answered)):
        issue.output("restored", None, 1)
    if not issue.swap_label("label", restore_type, "type:question"):
        issue.output("restored", None, 1)

    restored_at, restored = issue.latest(RESTORED)
    if restored is not None and restored_at > escalated_at:
        issue.output("restored", comment_id(restored.get("url")))
    posted_id = issue.comment(f"Goal answered → PR {args['--pr-url']}; decision restored for "
                              f"the next /kp-resolve-spec-decision run.\n\n{RESTORED}\n")
    if posted_id is None:
        issue.output("restored", None, 1)
    issue.output("restored", posted_id)


ARGS = parse(sys.argv[1:])
{"escalate": escalate, "create": create, "restore": restore}[ARGS["subcommand"]](ARGS)
