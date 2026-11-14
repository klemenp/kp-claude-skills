import argparse
import json
import re
import subprocess
import sys

DECISION_LABELS = {"type:decision", "type:question", "type:conflict"}
REPO = re.compile(r"[^/\s]+/[^/\s]+")
NUMBER = re.compile(r"\d+")
USAGE = ("usage: find-blocking-decision.sh <owner/repo> [--issue <n>] [--pr <p>]"
         " [--spec-ref <s>] [--from-file <json>]")


class UsageError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    parser = Parser(prog="find-blocking-decision.sh", add_help=False)
    parser.add_argument("repo")
    parser.add_argument("--issue")
    parser.add_argument("--pr")
    parser.add_argument("--spec-ref")
    parser.add_argument("--from-file")
    args = parser.parse_args(argv)
    if not REPO.fullmatch(args.repo):
        raise UsageError(f"not an owner/repo: {args.repo!r}")
    for flag, value in (("--issue", args.issue), ("--pr", args.pr)):
        if value is not None and not NUMBER.fullmatch(value):
            raise UsageError(f"{flag} is not a number: {value!r}")
    if args.spec_ref is not None and (not args.spec_ref.strip() or "\n" in args.spec_ref):
        raise UsageError("empty or multi-line --spec-ref")
    if args.issue is None and args.pr is None and args.spec_ref is None:
        raise UsageError("one of --issue, --pr or --spec-ref is required")
    return args


def targets(args):
    found = []
    if args.issue is not None:
        found.append(f"#{args.issue}")
    if args.pr is not None:
        found.append(f"#{args.pr}")
    if args.spec_ref is not None:
        found.append(args.spec_ref)
    return found


def blocking(find_marker, args, target):
    command = [find_marker, args.repo, "blocks", target, "--state", "open"]
    if args.from_file:
        command += ["--from-file", args.from_file]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        print(f"find-blocking-decision.sh: find-marker.sh for {target!r} exited "
              f"{result.returncode}", file=sys.stderr)
        sys.exit(1)
    return {hit["number"] for hit in json.loads(result.stdout)
            if DECISION_LABELS & set(hit["labels"])}


find_marker_path, argv = sys.argv[1], sys.argv[2:]
try:
    arguments = parse_args(argv)
except UsageError as error:
    print(f"find-blocking-decision.sh: {error}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)
kept = set()
for target in targets(arguments):
    kept |= blocking(find_marker_path, arguments, target)
ordered = sorted(kept)
print(json.dumps({"decision": ordered[0] if ordered else None, "all": ordered}))
