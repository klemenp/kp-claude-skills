import json
import os
import re
import subprocess
import sys

USAGE = "usage: repo-code.sh <owner/repo> [--config <path>]"
DEFAULT_CONFIG = os.path.join(".claude", "spec-sync.json")
REPO = re.compile(r"[^/\s]+/[^/\s]+")
TITLE_CODE = re.compile(r"^\[([A-Z0-9][A-Z0-9-]*)\] ")
# A name with this many hyphen-separated segments carries an org-wide prefix to drop.
MIN_SEGMENTS_WITH_ORG_PREFIX = 3


class UsageError(Exception):
    pass


def parse_args(argv):
    positional, config = [], DEFAULT_CONFIG
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--config":
            if index + 1 >= len(argv):
                raise UsageError("--config needs a value")
            config = argv[index + 1]
            index += 2
            continue
        if token.startswith("--"):
            raise UsageError(f"unknown option {token}")
        positional.append(token)
        index += 1
    if len(positional) != 1:
        raise UsageError(f"expected <owner/repo>, got {len(positional)} positional arguments")
    repo = positional[0]
    if not REPO.fullmatch(repo):
        raise UsageError(f"<owner/repo> is not owner/name: {repo!r}")
    return repo, config


def configured_code(repo, config_path):
    try:
        with open(config_path, encoding="utf-8") as config_file:
            config = json.load(config_file)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise UsageError(f"cannot parse config {config_path!r}: {error}")
    codes = config.get("repoCodes", {}) if isinstance(config, dict) else None
    if not isinstance(codes, dict):
        raise UsageError(f"config {config_path!r}: repoCodes is not an object")
    code = codes.get(repo)
    return code if isinstance(code, str) and code else None


def code_in_use(repo, label):
    path = f"repos/{repo}/issues?state=all&labels={label}&per_page=100"
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        print(f"repo-code.sh: reading the {label} issues of {repo} failed", file=sys.stderr)
        sys.exit(1)
    counts, highest = {}, {}
    for issue in json.loads(result.stdout):
        if "pull_request" in issue:
            continue
        match = TITLE_CODE.match(issue.get("title") or "")
        if not match:
            continue
        code = match.group(1)
        counts[code] = counts.get(code, 0) + 1
        highest[code] = max(highest.get(code, 0), issue["number"])
    if not counts:
        return None
    return max(counts, key=lambda code: (counts[code], highest[code]))


def derived_code(name):
    segments = name.split("-")
    if len(segments) >= MIN_SEGMENTS_WITH_ORG_PREFIX:
        segments = segments[1:]
    return "-".join(segments).upper()


try:
    repo, config_path = parse_args(sys.argv[1:])
    name = repo.split("/", 1)[1]
    label = f"repo:{name}"
    code = configured_code(repo, config_path)
except UsageError as error:
    print(f"repo-code.sh: {error}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)
if code is None:
    code = code_in_use(repo, label) or derived_code(name)
print(json.dumps({"code": code, "label": label}))
