import argparse
import json
import pathlib
import re
import subprocess
import sys

scripts_dir, *argv = sys.argv[1:]
SPEC_INDEX = pathlib.Path(scripts_dir) / "spec-index.py"
GH_TIMEOUT_SECONDS = 30
SPEC_INDEX_TIMEOUT_SECONDS = 180
DEFAULT_SPEC_GLOBS = ["docs/specs/**/*.md", "specs/**/*.md", "SPEC*.md"]
GREEN_BUCKETS = {"pass", "skipping"}

REPO = re.compile(r"[\w.-]+/[\w.-]+")
DECISION = re.compile(r"([\w.-]+/[\w.-]+)#(\d+)")
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
CODE_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
SPEC_REF_MARKER = re.compile(r"^spec-ref:[ \t]*(\S+)")
REQ_KEY = re.compile(r"REQ-[A-Z]+-\d{3}")
DIFF_FILE = re.compile(r"^diff --git a/(.*) b/(.*)$")
HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


class UsageError(Exception):
    pass


class FetchError(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def run(command: list[str], timeout: int) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise FetchError(f"{' '.join(command[:4])} timed out after {timeout}s") from error


def gh(*args: str) -> str:
    result = run(["gh", *args], GH_TIMEOUT_SECONDS)
    if result.returncode != 0:
        raise FetchError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()}")
    return result.stdout


# ---------------------------------------------------------------- inputs

def live_inputs(repo: str, pr: str, decision_repo: str, decision_number: str) -> dict:
    view = json.loads(gh("pr", "view", pr, "-R", repo, "--json", "baseRefOid,headRefOid"))
    base, head = view["baseRefOid"], view["headRefOid"]
    sync = run(["gh", "api", f"repos/{repo}/contents/.claude/spec-sync.json",
                "-H", "Accept: application/vnd.github.raw"], GH_TIMEOUT_SECONDS)
    if sync.returncode == 0:
        spec_sync = json.loads(sync.stdout)
    elif "404" in sync.stderr or "Not Found" in sync.stderr:
        spec_sync = None
    else:
        raise FetchError(f"spec-sync.json of {repo} failed: {sync.stderr.strip()}")
    # gh pr checks exits non-zero for red, pending and "no checks reported" alike.
    checks_run = run(["gh", "pr", "checks", pr, "-R", repo, "--json", "name,bucket"],
                     GH_TIMEOUT_SECONDS)
    if checks_run.stdout.strip().startswith("["):
        checks = json.loads(checks_run.stdout)
    elif "no checks reported" in checks_run.stdout + checks_run.stderr:
        checks = []
    else:
        raise FetchError(f"gh pr checks {pr} failed: {checks_run.stderr.strip()}")
    return {
        "diff": gh("pr", "diff", pr, "-R", repo),
        "base": base,
        "head": head,
        "body": json.loads(gh("issue", "view", decision_number, "-R", decision_repo,
                              "--json", "body"))["body"],
        "base_index": spec_index(repo, base),
        "head_index": spec_index(repo, head),
        "checks": checks,
        "spec_sync": spec_sync,
    }


def spec_index(repo: str, sha: str) -> dict:
    result = run([sys.executable, str(SPEC_INDEX), f"{repo}@{sha}"], SPEC_INDEX_TIMEOUT_SECONDS)
    if result.returncode != 0:
        raise FetchError(f"spec-index.py {repo}@{sha} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def file_inputs(directory: pathlib.Path) -> dict:
    def text(name: str) -> str:
        return (directory / name).read_text(encoding="utf-8")

    sync_file = directory / "spec-sync.json"
    return {
        "diff": text("diff.patch"),
        "base": text("base").strip(),
        "head": text("head").strip(),
        "body": json.loads(text("issue.json"))["body"],
        "base_index": json.loads(text("base-index.json")),
        "head_index": json.loads(text("head-index.json")),
        "checks": json.loads(text("checks.json")),
        "spec_sync": json.loads(sync_file.read_text(encoding="utf-8")) if sync_file.exists() else None,
    }


# ---------------------------------------------------------------- parsing

def spec_ref_keys(body: str) -> list[str]:
    keys = []
    fence = None
    for line in HUMAN_ONLY_FENCE.sub("", body).split("\n"):
        fence_match = CODE_FENCE.match(line)
        if fence is not None:
            if fence_match and fence_match.group(1)[0] == fence[0] \
                    and len(fence_match.group(1)) >= len(fence):
                fence = None
            continue
        if fence_match:
            fence = fence_match.group(1)
            continue
        if (marker := SPEC_REF_MARKER.match(line)) and marker.group(1) not in keys:
            keys.append(marker.group(1))
    return keys


def changed_lines(diff: str) -> dict[str, set[int]]:
    """Changed path -> head-side line numbers touched. A deletion counts at the head line
    that follows it, so it falls in the section it was cut from (see touches())."""
    changes: dict[str, set[int]] = {}
    path = None
    new_line = 0
    in_hunk = False
    for line in diff.split("\n"):
        if file_match := DIFF_FILE.match(line):
            old_path, path = file_match.groups()
            changes.setdefault(path, set())
            if old_path != path:
                changes.setdefault(old_path, set())
            in_hunk = False
            continue
        if line.startswith("+++ ") and line[4:].startswith("b/"):
            path = line[6:]
            changes.setdefault(path, set())
            continue
        if hunk := HUNK.match(line):
            new_line = int(hunk.group(1))
            in_hunk = True
            continue
        if not in_hunk or path is None:
            continue
        if line.startswith("+"):
            changes[path].add(new_line)
            new_line += 1
        elif line.startswith("-"):
            changes[path].add(-new_line)
        elif line.startswith(" "):
            new_line += 1
    return changes


def touches(lines: set[int], section: dict) -> bool:
    start, end = section["startLine"], section["endLine"]
    # Positive: an added line. Negative: a deletion just before head line -n, i.e. between
    # lines n-1 and n, which is inside the section when start < n <= end + 1.
    return any(start <= line <= end if line > 0 else start < -line <= end + 1 for line in lines)


def doc_slug_of(path: str) -> str:
    return pathlib.PurePath(path).stem.lower().replace("_", "-")


def find_section(index: dict, key: str) -> tuple[str, dict] | None:
    is_req = REQ_KEY.fullmatch(key) is not None
    doc_slug, _, heading = key.partition("#")
    for path in sorted(index.get("files", {})):
        for section in index["files"][path]["sections"]:
            if (section["kind"] == "req" and section["anchor"] == key) or \
                    (not is_req and section["kind"] == "heading" and section["anchor"] == heading
                     and doc_slug_of(path) == doc_slug):
                return path, section
    return None


def heading_of(section: dict) -> tuple:
    return section["kind"], section["level"], section.get("number"), section["title"]


def describe(section: dict) -> str:
    number = f"{section['number']} " if section.get("number") else ""
    return f"`{number}{section['title']}` ({section['kind']}, level {section['level']})"


def glob_regex(glob: str) -> re.Pattern:
    """A path glob where `**/` spans any number of directories and `*`, `?` stay in one."""
    pattern = ""
    position = 0
    while position < len(glob):
        if glob.startswith("**/", position):
            pattern += "(?:.*/)?"
            position += 3
        elif glob.startswith("**", position):
            pattern += ".*"
            position += 2
        elif glob[position] == "*":
            pattern += "[^/]*"
            position += 1
        elif glob[position] == "?":
            pattern += "[^/]"
            position += 1
        else:
            pattern += re.escape(glob[position])
            position += 1
    return re.compile(pattern)


# ---------------------------------------------------------------- rules

def check(inputs: dict, decision: str) -> list[str]:
    failures = []
    changes = changed_lines(inputs["diff"])
    base_index, head_index = inputs["base_index"], inputs["head_index"]

    for key in spec_ref_keys(inputs["body"]):
        at_head = find_section(head_index, key)
        at_base = find_section(base_index, key)
        if at_head is None:
            failures.append(f"untouched-ref: `{key}` no longer exists at the head "
                            f"{inputs['head']}")
            failures.append(f"identity: `{key}` is absent from the head index")
            continue
        path, section = at_head
        where = f"`{key}` ({path}#{section['anchor']}, lines {section['startLine']}-" \
                f"{section['endLine']} at the head)"
        if at_base is not None and (at_base[0] != path or heading_of(at_base[1]) != heading_of(section)):
            failures.append(f"identity: {where} heading {describe(at_base[1])} at the base "
                            f"is {describe(section)} at the head")
        if not touches(changes.get(path, set()), section):
            failures.append(f"untouched-ref: {where} has no changed line")
            continue
        within = [candidate for candidate in head_index["files"][path]["sections"]
                  if candidate["startLine"] >= section["startLine"]
                  and candidate["endLine"] <= section["endLine"]]
        targets = {ref["target"].lower() for candidate in within for ref in candidate.get("refs", [])
                   if ref.get("type") == "decision" and ref.get("target")}
        if decision.lower() not in targets:
            failures.append(f"no-backref: {where} has no `<!-- decided in {decision} -->` line")

    spec_sync = inputs["spec_sync"] or {}
    globs = spec_sync.get("specGlobs") or DEFAULT_SPEC_GLOBS
    patterns = [glob_regex(glob) for glob in globs]
    for path in sorted(changes):
        if not any(pattern.fullmatch(path) for pattern in patterns):
            failures.append(f"outside-spec: {path} matches none of {', '.join(globs)}")

    for entry in inputs["checks"]:
        if entry.get("bucket") not in GREEN_BUCKETS:
            failures.append(f"ci: {entry.get('name')} is {entry.get('bucket')} at {inputs['head']}")
    return failures


def main() -> int:
    parser = Parser(prog="spec-pr-check.sh", add_help=False)
    parser.add_argument("repo")
    parser.add_argument("pr")
    parser.add_argument("--decision", required=True)
    parser.add_argument("--from-file")
    try:
        args = parser.parse_args(argv)
        if not REPO.fullmatch(args.repo) or not args.pr.isdigit():
            raise UsageError(f"expected <owner/repo> <pr>, got {args.repo} {args.pr}")
        decision = DECISION.fullmatch(args.decision)
        if decision is None:
            raise UsageError(f"--decision must be <owner/repo>#<n>, got {args.decision}")
        if args.from_file and not pathlib.Path(args.from_file).is_dir():
            raise UsageError(f"--from-file {args.from_file} is not a directory")
    except UsageError as error:
        print(f"spec-pr-check.sh: {error}\nusage: spec-pr-check.sh <owner/repo> <pr> "
              "--decision <owner/repo>#<n> [--from-file <dir>]", file=sys.stderr)
        return 2
    try:
        inputs = (file_inputs(pathlib.Path(args.from_file)) if args.from_file
                  else live_inputs(args.repo, args.pr, *decision.groups()))
    except (FetchError, json.JSONDecodeError, KeyError, OSError) as error:
        print(f"spec-pr-check.sh: {args.repo}#{args.pr}: {error}", file=sys.stderr)
        return 4
    failures = check(inputs, args.decision)
    for failure in failures:
        print(f"FAIL {failure}")
    if failures:
        return 1
    print("ok")
    return 0


sys.exit(main())
