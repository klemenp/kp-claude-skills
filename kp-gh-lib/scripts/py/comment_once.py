import json
import subprocess
import sys

USAGE = ("usage: comment-once.sh <owner/repo> <n> --marker <m> --body-file <f>"
         " [--add-label <name> --label-color <hex>]")
VALUE_OPTIONS = ("--marker", "--body-file", "--add-label", "--label-color")


class UsageError(Exception):
    pass


def parse_args(argv):
    positional, options = [], {}
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in VALUE_OPTIONS:
            if index + 1 >= len(argv):
                raise UsageError(f"{token} needs a value")
            options[token] = argv[index + 1]
            index += 2
            continue
        if token.startswith("--"):
            raise UsageError(f"unknown option {token}")
        positional.append(token)
        index += 1
    if len(positional) != 2:
        raise UsageError(f"expected <owner/repo> <n>, got {len(positional)} positional arguments")
    repo, number = positional
    if not (number.isascii() and number.isdigit()) or int(number) < 1:
        raise UsageError(f"<n> is not a positive integer: {number!r}")
    for required in ("--marker", "--body-file"):
        if required not in options:
            raise UsageError(f"missing {required}")
    marker = options["--marker"]
    if not marker:
        raise UsageError("empty marker")
    try:
        with open(options["--body-file"], encoding="utf-8") as body_file:
            body = body_file.read()
    except OSError as error:
        raise UsageError(f"cannot read body file {options['--body-file']!r}: {error.strerror}")
    if marker not in body:
        raise UsageError(f"body file {options['--body-file']!r} does not contain the marker")
    if ("--add-label" in options) != ("--label-color" in options):
        raise UsageError("--add-label and --label-color go together")
    if options.get("--add-label") == "":
        raise UsageError("empty --add-label")
    return {"repo": repo, "number": number, "marker": marker,
            "body_file": options["--body-file"], "label": options.get("--add-label"),
            "color": options.get("--label-color")}


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        print(f"comment-once.sh: {' '.join(command)} failed", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def add_label(args):
    run(["gh", "label", "create", args["label"], "-R", args["repo"],
         "--color", args["color"], "--force"])
    run(["gh", "issue", "edit", args["number"], "-R", args["repo"],
         "--add-label", args["label"]])


def comments(args):
    path = f"repos/{args['repo']}/issues/{args['number']}/comments"
    pages = json.loads(run(["gh", "api", path, "--paginate", "--slurp"]))
    return [comment for page in pages for comment in page]


def post(args):
    path = f"repos/{args['repo']}/issues/{args['number']}/comments"
    created = json.loads(run(["gh", "api", "-X", "POST", path,
                              "-F", f"body=@{args['body_file']}"]))
    return created["id"]


try:
    arguments = parse_args(sys.argv[1:])
except UsageError as error:
    print(f"comment-once.sh: {error}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)
if arguments["label"]:
    add_label(arguments)
# The endpoint lists comments oldest first, so the first match is the oldest.
existing = [comment["id"] for comment in comments(arguments)
            if arguments["marker"] in (comment.get("body") or "")]
if existing:
    print(f"exists {existing[0]}")
else:
    print(f"posted {post(arguments)}")
