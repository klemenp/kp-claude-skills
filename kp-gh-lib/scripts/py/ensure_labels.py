import json
import re
import subprocess
import sys

USAGE = "usage: ensure-labels.sh --repo <owner/repo> <label>[=<hex>]…"
HEX_COLOR = re.compile(r"[0-9A-Fa-f]{6}")
REPO_LABEL_PREFIX = "repo:"
REPO_LABEL_COLOR = "6E7781"
MODEL_TIER_LABEL = re.compile(r"model:(opus|sonnet|haiku)-(low|medium|high|xhigh|max)", re.I)
FAMILY_COLORS = {
    "type:coding": "1d76db",
    "type:epic": "5319e7",
    "type:decision": "d93f0b",
    "type:question": "fbca04",
    "type:research": "0e8a16",
    "type:conflict": "b60205",
    "type:audit": "0052CC",
    "needs-contract": "D93F0B",
    "model:opus": "B60205",
    "model:sonnet": "FBCA04",
    "model:haiku": "0E8A16",
}


class UsageError(Exception):
    pass


def builtin_color(name):
    if name in FAMILY_COLORS:
        return FAMILY_COLORS[name]
    if name.startswith(REPO_LABEL_PREFIX) and len(name) > len(REPO_LABEL_PREFIX):
        return REPO_LABEL_COLOR
    tier = MODEL_TIER_LABEL.fullmatch(name)
    if tier:
        return FAMILY_COLORS[f"model:{tier.group(1).lower()}"]
    return None


def parse_label(argument):
    name, has_suffix, color = argument.partition("=")
    if not name:
        raise UsageError(f"empty label name in {argument!r}")
    if has_suffix:
        if not HEX_COLOR.fullmatch(color):
            raise UsageError(f"{name}: color {color!r} is not six hex digits")
        return name, color
    color = builtin_color(name)
    if color is None:
        raise UsageError(f"{name}: no built-in color; pass {name}=<hex>")
    return name, color


def parse_args(argv):
    repo, labels = None, []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--repo":
            if index + 1 >= len(argv):
                raise UsageError("--repo needs a value")
            repo = argv[index + 1]
            index += 2
            continue
        if token.startswith("--"):
            raise UsageError(f"unknown option {token}")
        labels.append(parse_label(token))
        index += 1
    if not repo:
        raise UsageError("missing --repo")
    if not labels:
        raise UsageError("no labels given")
    return repo, labels


def run(command, failure):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        print(f"ensure-labels.sh: {failure}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def existing_colors(repo):
    pages = json.loads(run(["gh", "api", f"repos/{repo}/labels", "--paginate", "--slurp"],
                           f"reading the labels of {repo} failed"))
    return {label["name"].lower(): label["color"] for page in pages for label in page}


try:
    repo, labels = parse_args(sys.argv[1:])
except UsageError as error:
    print(f"ensure-labels.sh: {error}", file=sys.stderr)
    print(USAGE, file=sys.stderr)
    sys.exit(2)

current = existing_colors(repo)
for name, color in labels:
    present = current.get(name.lower())
    if present is not None and present.lower() == color.lower():
        print(f"exists {name}", flush=True)
        continue
    run(["gh", "label", "create", name, "-R", repo, "--color", color, "--force"],
        f"creating or recoloring label {name!r} in {repo} failed")
    current[name.lower()] = color
    print(f"{'created' if present is None else 'updated'} {name}", flush=True)
