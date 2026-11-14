import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.parse

script_dir, repo, issue, body_file, code_root = sys.argv[1:]

GH_TIMEOUT_SECONDS = 30
SPEC_INDEX_TIMEOUT_SECONDS = 300
SPEC_INDEX = pathlib.Path(script_dir) / "spec-index.py"
CONTENT_CACHE_DIR = pathlib.Path(script_dir).parent / "state" / "spec-index" / "content"
EXIT_FETCH_FAILURE = 1
EXIT_UNRESOLVED = 3
GOALS_TITLE_PREFIX = "goals"
# kp-resolve-spec-decision §4.6 opens its resolution comment with one of these.
RESOLUTION_PREFIXES = ("Resolved → ", "Closed as won't-do")

# A loosely matched start marker up to its end marker, or to the end of an unclosed body.
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
CODE_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
CONTEXT_LINE = re.compile(r"^(spec|code|decision):[ \t]*(.*?)[ \t]*$")
TRAILING_COMMENT = re.compile(r"[ \t]+#[ \t].*$")
SPEC_REF = re.compile(
    r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-fA-F]{40}):([^#\s]+)#(\S+)")
CODE_REF = re.compile(r"([^#\s]+)(?:#(\S+))?")
DECISION_REF = re.compile(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)")

problems = []


class FetchError(Exception):
    pass


def problem(message):
    problems.append(message)
    print(f"read-context.sh: {message}", file=sys.stderr)


def run(command, timeout):
    try:
        result = subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise FetchError(f"{' '.join(command)} timed out after {timeout}s") from error
    return result


def gh_api(endpoint, *extra):
    command = ["gh", "api", endpoint, *extra]
    result = run(command, GH_TIMEOUT_SECONDS)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise FetchError(f"gh api {endpoint} failed: {detail}")
    return result.stdout.decode("utf-8", "replace")


def context_lines(body):
    """(kind, value) for each context line outside code fences, in body order."""
    found = []
    fence = None
    for line in body.split("\n"):
        fence_match = CODE_FENCE.match(line)
        if fence is not None:
            if fence_match and fence_match.group(1)[0] == fence[0] \
                    and len(fence_match.group(1)) >= len(fence):
                fence = None
            continue
        if fence_match:
            fence = fence_match.group(1)
            continue
        match = CONTEXT_LINE.match(line)
        if match:
            found.append((match.group(1), TRAILING_COMMENT.sub("", match.group(2))))
    return found


def item_block():
    if body_file:
        body = pathlib.Path(body_file).read_text(encoding="utf-8")
        return f"draft {body_file}", body
    issue_json = json.loads(gh_api(f"repos/{repo}/issues/{issue}"))
    return f"{repo}#{issue}", f"{issue_json['title']}\n\n{issue_json['body'] or ''}"


def spec_content(spec_repo, sha, path):
    cache_file = CONTENT_CACHE_DIR / f"{spec_repo.replace('/', '_')}@{sha}" / path
    try:
        return cache_file.read_text(encoding="utf-8")
    except FileNotFoundError:
        pass
    content = gh_api(f"repos/{spec_repo}/contents/{urllib.parse.quote(path)}?ref={sha}",
                     "-H", "Accept: application/vnd.github.raw")
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=cache_file.parent,
                                     delete=False) as handle:
        handle.write(content)
    os.replace(handle.name, cache_file)
    return content


def spec_sections(spec_repo, sha, paths):
    """{path: [section, …]} from spec-index.py for one repo at one commit."""
    result = run([sys.executable, str(SPEC_INDEX), f"{spec_repo}@{sha}", *paths],
                 SPEC_INDEX_TIMEOUT_SECONDS)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise FetchError(f"spec-index.py {spec_repo}@{sha} failed: {detail}")
    files = json.loads(result.stdout)["files"]
    return {path: entry["sections"] for path, entry in files.items()}


def section_text(content, section):
    lines = content.split("\n")
    return "\n".join(lines[section["startLine"] - 1:section["endLine"]]) + "\n"


def decision_text(decision_repo, number):
    title = json.loads(gh_api(f"repos/{decision_repo}/issues/{number}"))["title"]
    comments = [json.loads(line) for line in gh_api(
        f"repos/{decision_repo}/issues/{number}/comments?per_page=100", "--paginate",
        "--jq", ".[] | {body}").splitlines() if line.strip()]
    resolutions = [c for c in comments if (c["body"] or "").startswith(RESOLUTION_PREFIXES)]
    if resolutions:
        return "", f"{title}\n\n{resolutions[-1]['body']}\n"
    if comments:
        return " — no resolution comment, latest comment shown", \
            f"{title}\n\n{comments[-1]['body']}\n"
    problem(f"{decision_repo}#{number} has no comments to resolve it")
    return " — no comments", f"{title}\n"


def code_text(path):
    root = pathlib.Path(code_root).resolve()
    target = (root / path).resolve()
    if pathlib.Path(path).is_absolute() or root not in (target, *target.parents):
        problem(f"code path {path} is outside the code root")
        return "missing\n"
    try:
        return target.read_bytes().decode("utf-8", "replace")
    except (FileNotFoundError, IsADirectoryError):
        problem(f"code file {path} is missing under {root}")
        return "missing\n"


def collect():
    item_ref, item_body = item_block()
    item_body = HUMAN_ONLY_FENCE.sub("", item_body.replace("\r\n", "\n"))
    blocks = [("item", item_ref, item_body)]

    specs, codes, decisions = [], [], []
    for kind, value in context_lines(item_body):
        pattern = {"spec": SPEC_REF, "code": CODE_REF, "decision": DECISION_REF}[kind]
        match = pattern.fullmatch(value)
        if not match:
            problem(f"malformed {kind}: line: {value!r}")
            continue
        {"spec": specs, "code": codes, "decision": decisions}[kind].append(match.groups())

    # The goal frame comes from the file and commit of each repo's first spec: line.
    goal_sources = {}
    paths_by_commit = {}
    for spec_repo, sha, path, _ in specs:
        goal_sources.setdefault(spec_repo, (sha.lower(), path))
        paths_by_commit.setdefault((spec_repo, sha.lower()), set()).add(path)
    sections = {}
    for (spec_repo, sha), paths in paths_by_commit.items():
        for path, entries in spec_sections(spec_repo, sha, sorted(paths)).items():
            sections[(spec_repo, sha, path)] = entries

    for spec_repo, (sha, path) in goal_sources.items():
        ref = f"{spec_repo}@{sha}:{path}"
        goals = next((s for s in sections[(spec_repo, sha, path)] if s["kind"] == "heading"
                      and s["title"].lower().startswith(GOALS_TITLE_PREFIX)), None)
        if goals is None:
            problem(f"no Goals section in {ref}")
            blocks.append(("goal-frame", ref, "goal-frame: none found\n"))
            continue
        blocks.append(("goal-frame", f"{ref}#{goals['anchor']}",
                       section_text(spec_content(spec_repo, sha, path), goals)))

    for spec_repo, sha, path, anchor in specs:
        sha = sha.lower()
        ref = f"{spec_repo}@{sha}:{path}#{anchor}"
        section = next((s for s in sections[(spec_repo, sha, path)]
                        if s["anchor"] == anchor), None)
        if section is None:
            problem(f"unknown anchor {anchor} in {spec_repo}@{sha}:{path}")
            blocks.append(("spec", ref, "unknown anchor\n"))
            continue
        blocks.append(("spec", ref, section_text(spec_content(spec_repo, sha, path), section)))

    for path, symbol in codes:
        blocks.append(("code", f"{path}#{symbol}" if symbol else path, code_text(path)))

    for decision_repo, number in decisions:
        note, text = decision_text(decision_repo, number)
        blocks.append(("decision", f"{decision_repo}#{number}{note}", text))
    return blocks


def main():
    try:
        blocks = collect()
    except (FetchError, OSError, ValueError, KeyError) as error:
        print(f"read-context.sh: {error}", file=sys.stderr)
        return EXIT_FETCH_FAILURE
    total_bytes = 0
    out = sys.stdout
    for kind, ref, text in blocks:
        if not text.endswith("\n"):
            text += "\n"
        size = len(text.encode("utf-8"))
        total_bytes += size
        out.write(f"===== {kind}: {ref} ({size} B) =====\n{text}")
    out.write(f"===== total: {total_bytes} B, {len(blocks)} blocks =====\n")
    return EXIT_UNRESOLVED if problems else 0


sys.exit(main())
