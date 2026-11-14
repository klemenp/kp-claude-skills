import json
import os
import re
import subprocess
import sys
import tempfile

USAGE = ("usage: file-audit.sh --repo <owner/repo> --title <t> --body-file <f> "
         "[--tokens <start-iso> <marker>] [--dedup-line '<marker>: <value>']…")
AUDIT_LABEL = "type:audit"
TOKENS_PLACEHOLDER = "__TOKENS__"
DEDUP_LINE = re.compile(r"([A-Za-z0-9_-]+): (\S.*)")
ISSUE_URL = re.compile(r"https://\S+/issues/(\d+)")
BIN = os.environ["KP_GH_LIB_BIN"]


class CallFailed(Exception):
    pass


def usage_error(message):
    print(f"file-audit: {message}\n{USAGE}", file=sys.stderr)
    sys.exit(2)


def parse_args(argv):
    args = {"repo": None, "title": None, "body_file": None, "tokens": None, "dedup": []}
    index = 0
    while index < len(argv):
        flag = argv[index]
        if flag in ("--repo", "--title", "--body-file", "--dedup-line"):
            if index + 1 >= len(argv):
                usage_error(f"{flag} needs a value")
            value = argv[index + 1]
            if flag == "--dedup-line":
                match = DEDUP_LINE.fullmatch(value)
                if not match:
                    usage_error(f"--dedup-line not shaped '<marker>: <value>': {value!r}")
                args["dedup"].append((match.group(1), match.group(2)))
            else:
                args[flag[2:].replace("-", "_")] = value
            index += 2
        elif flag == "--tokens":
            if index + 2 >= len(argv):
                usage_error("--tokens needs <start-iso> <marker>")
            args["tokens"] = (argv[index + 1], argv[index + 2])
            index += 3
        else:
            usage_error(f"unknown argument {flag!r}")
    for required in ("repo", "title", "body_file"):
        if not args[required]:
            usage_error(f"--{required.replace('_', '-')} is required")
    try:
        with open(args["body_file"], encoding="utf-8") as body:
            args["body"] = body.read()
    except OSError as error:
        usage_error(f"cannot read --body-file: {error}")
    if args["tokens"] and TOKENS_PLACEHOLDER not in args["body"]:
        usage_error(f"--tokens given but the body has no {TOKENS_PLACEHOLDER}")
    return args


def run(command, what):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr.strip() or result.stdout.strip()).splitlines()
        raise CallFailed(f"{what} failed: {detail[-1] if detail else f'exit {result.returncode}'}")
    return result.stdout


def find_reusable(repo, dedup_lines):
    """The highest-numbered issue every dedup line's search returned, or None."""
    common = None
    for marker, value in dedup_lines:
        output = run([f"{BIN}/find-marker.sh", repo, marker, value,
                      "--state", "all", "--label", AUDIT_LABEL],
                     f"find-marker.sh {marker}: {value}")
        hits = {hit["number"]: hit for hit in json.loads(output)}
        common = hits if common is None else {
            number: hit for number, hit in common.items() if number in hits}
    if not common:
        return None
    return common[max(common)]


def fill_tokens(repo, number, body, start_iso, marker):
    try:
        row = run([f"{BIN}/report-tokens.sh", start_iso, marker, repo, str(number)],
                  "report-tokens.sh").strip()
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False,
                                         encoding="utf-8") as copy:
            copy.write(body.replace(TOKENS_PLACEHOLDER, row))
        try:
            run(["gh", "issue", "edit", str(number), "-R", repo, "--body-file", copy.name],
                "gh issue edit")
        finally:
            os.unlink(copy.name)
    except CallFailed as error:
        print(f"file-audit: token fill skipped — {error}", file=sys.stderr)


def file_audit(args):
    repo = args["repo"]
    run([f"{BIN}/ensure-labels.sh", "--repo", repo, AUDIT_LABEL], "ensure-labels.sh")
    if args["dedup"]:
        reused = find_reusable(repo, args["dedup"])
        if reused:
            if reused["state"] == "OPEN":
                run(["gh", "issue", "close", str(reused["number"]), "-R", repo],
                    f"gh issue close {reused['number']}")
            return {"number": reused["number"], "url": reused["url"], "reused": True}
    created = run(["gh", "issue", "create", "-R", repo, "--title", args["title"],
                   "--label", AUDIT_LABEL, "--body-file", args["body_file"]],
                  "gh issue create")
    match = ISSUE_URL.search(created)
    if not match:
        raise CallFailed(f"gh issue create printed no issue URL: {created.strip()!r}")
    number, url = int(match.group(1)), match.group(0)
    if args["tokens"]:
        fill_tokens(repo, number, args["body"], *args["tokens"])
    run(["gh", "issue", "close", str(number), "-R", repo],
        f"gh issue close {number} (the issue exists, open)")
    return {"number": number, "url": url, "reused": False}


def main():
    args = parse_args(sys.argv[1:])
    try:
        result = file_audit(args)
    except CallFailed as error:
        print(f"file-audit: {error}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(result))


main()
