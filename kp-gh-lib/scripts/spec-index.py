#!/usr/bin/env python3
"""Index a spec repo's markdown at one commit: sections, their size, Serves goals and refs.

Usage: spec-index.py <owner/repo>@<sha> [<path> ...]

With no paths every *.md file tracked at <sha> is indexed. Prints one JSON object:
{"repo", "sha", "files": {<path>: {"sections": [...]}}}. A section is a heading (extent up
to the next heading of the same or higher level) or a bold `**REQ-…**` paragraph (extent
up to the next REQ line or heading). `serves` and `refs` come from the section's own text,
before its first child section; children carry their own. `req` refs resolve across the
files in this call's output.

REST only, every gh call bounded by a timeout. Parsed files are cached per commit under
kp-gh-lib/state/spec-index/ and never invalidated, since a commit SHA is immutable.
Exit codes: 0 ok, 1 fetch or parse failure (stderr), 2 bad arguments.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.parse

CACHE_DIR = pathlib.Path(__file__).resolve().parents[1] / "state" / "spec-index"
GH_TIMEOUT_SECONDS = 30
USAGE = "usage: spec-index.py <owner/repo>@<sha> [<path> ...]"

# A full SHA only: the cache is keyed by it and never invalidated, so a branch name or a
# short SHA that could later mean another commit is refused.
TARGET = re.compile(r"([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)@([0-9a-fA-F]{40})")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$")
CLOSING_HASHES = re.compile(r"(?:^|[ \t]+)#+$")
HEADING_NUMBER = re.compile(r"^(\d+(?:\.\d+)*[a-z]?)\.?[ \t]+(.*)$")
REQ_LINE = re.compile(r"^\*\*(REQ-[A-Z]+-\d{3})\b[ \t]*(?:[—–-][ \t]*)?(.*?)\*\*")
SERVES_LINE = re.compile(r"^[ \t]*Serves:(.*)$")
GOAL = re.compile(r"\bG-\d+\b")
MARKDOWN_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
HTML_TAG = re.compile(r"<!--.*?-->|<[^>]+>")
SLUG_DROP = re.compile(r"[^\w\- ]")

# A run of §-refs joined by commas/"and" ("§3.1, §5.6"): the whole run belongs to the doc
# named just before it, so "Payments spec §3.1, §5.6" points into another file.
SECTION_RUN = re.compile(r"§\s?\d+(?:\.\d+)*[a-z]?(?:\s*(?:,|and|&|/)\s*§\s?\d+(?:\.\d+)*[a-z]?)*")
SECTION_REF = re.compile(r"§\s?(\d+(?:\.\d+)*[a-z]?)")
# No leading \b: in "TECH_SPEC" the "_" is a word character. Closing code/link punctuation
# may follow the name ("`TECH_SPEC.md` §6").
FOREIGN_DOC_BEFORE = re.compile(r"(?:spec|\.md)[`\])]*\s*$", re.IGNORECASE)
REQ_REF = re.compile(r"\bREQ-[A-Z]+-\d{3}\b")
ADR_REF = re.compile(r"\bADR-\d+\b")
DECISION_REF = re.compile(r"decided in (?:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+))?#(\d+)")
FOREIGN_CONTEXT_CHARS = 40


class FetchError(Exception):
    pass


def gh_api(endpoint: str, raw: bool) -> str:
    command = ["gh", "api", endpoint]
    if raw:
        command += ["-H", "Accept: application/vnd.github.raw"]
    try:
        result = subprocess.run(command, capture_output=True, timeout=GH_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise FetchError(f"gh api {endpoint} timed out after {GH_TIMEOUT_SECONDS}s") from error
    except OSError as error:
        raise FetchError(f"cannot run gh: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise FetchError(f"gh api {endpoint} failed: {detail}")
    try:
        return result.stdout.decode("utf-8")
    except UnicodeDecodeError as error:
        raise FetchError(f"gh api {endpoint} returned non-UTF-8 content") from error


def markdown_paths(repo: str, sha: str) -> list[str]:
    endpoint = f"repos/{repo}/git/trees/{sha}?recursive=1"
    try:
        tree = json.loads(gh_api(endpoint, raw=False))
    except ValueError as error:
        raise FetchError(f"gh api {endpoint} returned invalid JSON") from error
    if tree.get("truncated"):
        raise FetchError(f"tree of {repo}@{sha} is truncated; pass the paths explicitly")
    return sorted(
        entry["path"] for entry in tree.get("tree", [])
        if entry.get("type") == "blob" and entry["path"].endswith(".md")
    )


def file_content(repo: str, sha: str, path: str) -> str:
    quoted = urllib.parse.quote(path)
    return gh_api(f"repos/{repo}/contents/{quoted}?ref={sha}", raw=True)


def github_slug(text: str, seen: dict[str, int]) -> str:
    plain = HTML_TAG.sub("", MARKDOWN_LINK.sub(r"\1", text))
    base = SLUG_DROP.sub("", plain.strip().lower()).replace(" ", "-")
    slug = base
    while slug in seen:
        seen[base] += 1
        slug = f"{base}-{seen[base]}"
    seen[slug] = 0
    return slug


def find_markers(lines: list[str]) -> list[dict]:
    """Headings and REQ lines outside code fences, in file order."""
    markers: list[dict] = []
    seen_slugs: dict[str, int] = {}
    fence: str | None = None
    heading_level = 0
    for index, line in enumerate(lines):
        if fence is not None:
            # CommonMark: a closing fence is at least as long as the opening one and has
            # no info string.
            closing = re.match(rf"^ {{0,3}}{re.escape(fence[0])}{{{len(fence)},}}[ \t]*$", line)
            if closing:
                fence = None
            continue
        fence_match = FENCE.match(line)
        if fence_match:
            fence = fence_match.group(1)
            continue
        heading = HEADING.match(line)
        if heading:
            heading_level = len(heading.group(1))
            text = CLOSING_HASHES.sub("", heading.group(2) or "").strip()
            numbered = HEADING_NUMBER.match(text)
            markers.append({
                "line": index, "kind": "heading", "level": heading_level,
                "anchor": github_slug(text, seen_slugs),
                "title": numbered.group(2) if numbered else text,
                "number": numbered.group(1) if numbered else None,
            })
            continue
        req = REQ_LINE.match(line)
        if req:
            markers.append({
                "line": index, "kind": "req", "level": heading_level + 1,
                "anchor": req.group(1),
                "title": req.group(2).strip().rstrip("."),
                "number": None,
            })
    return markers


def extent_end(markers: list[dict], position: int, line_count: int) -> int:
    """Index of the section's last line."""
    marker = markers[position]
    for later in markers[position + 1:]:
        if marker["kind"] == "req" or (later["kind"] == "heading" and later["level"] <= marker["level"]):
            return later["line"] - 1
    return line_count - 1


def serves_of(own_lines: list[str]) -> list[str] | None:
    for line in own_lines:
        match = SERVES_LINE.match(line)
        if match:
            return GOAL.findall(match.group(1))
    return None


def refs_of(text: str, path: str, heading_by_number: dict[str, str], repo: str) -> list[tuple[int, dict]]:
    """(offset, ref) pairs; `req` targets stay None until resolve_req_refs runs."""
    found: list[tuple[int, dict]] = []
    for run in SECTION_RUN.finditer(text):
        before = text[max(0, run.start() - FOREIGN_CONTEXT_CHARS):run.start()]
        foreign = FOREIGN_DOC_BEFORE.search(before) is not None
        for ref in SECTION_REF.finditer(run.group(0)):
            anchor = None if foreign else heading_by_number.get(ref.group(1))
            found.append((run.start() + ref.start(), {
                "raw": ref.group(0), "type": "section",
                "target": f"{path}#{anchor}" if anchor else None,
            }))
    for ref in REQ_REF.finditer(text):
        found.append((ref.start(), {"raw": ref.group(0), "type": "req", "target": None}))
    for ref in ADR_REF.finditer(text):
        found.append((ref.start(), {"raw": ref.group(0), "type": "adr", "target": None}))
    for ref in DECISION_REF.finditer(text):
        target_repo = ref.group(1) or repo
        found.append((ref.start(), {
            "raw": ref.group(0), "type": "decision", "target": f"{target_repo}#{ref.group(2)}",
        }))
    for ref in GOAL.finditer(text):
        found.append((ref.start(), {"raw": ref.group(0), "type": "goal", "target": ref.group(0)}))
    return sorted(found, key=lambda pair: pair[0])


def index_file(repo: str, path: str, content: str) -> dict:
    lines = content.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    markers = find_markers(lines)
    heading_by_number: dict[str, str] = {}
    for marker in markers:
        if marker["number"] is not None:
            heading_by_number.setdefault(marker["number"], marker["anchor"])

    sections = []
    for position, marker in enumerate(markers):
        start = marker["line"]
        end = extent_end(markers, position, len(lines))
        own_end = markers[position + 1]["line"] - 1 if position + 1 < len(markers) else len(lines) - 1
        own_lines = lines[start:min(end, own_end) + 1]
        self_target = f"{path}#{marker['anchor']}"
        refs = []
        seen = set()
        for _, ref in refs_of("\n".join(own_lines), path, heading_by_number, repo):
            key = (ref["raw"], ref["type"], ref["target"])
            is_self = ref["target"] == self_target or (
                marker["kind"] == "req" and ref["type"] == "req" and ref["raw"] == marker["anchor"]
            )
            if is_self or key in seen:
                continue
            seen.add(key)
            refs.append(ref)
        sections.append({
            "anchor": marker["anchor"], "kind": marker["kind"], "level": marker["level"],
            "title": marker["title"], "number": marker["number"],
            "startLine": start + 1, "endLine": end + 1,
            "bytes": len(("\n".join(lines[start:end + 1]) + "\n").encode("utf-8")),
            "serves": serves_of(own_lines),
            "refs": refs,
        })
    return {"sections": sections}


def resolve_req_refs(files: dict[str, dict]) -> None:
    """Point each req ref at its section, preferring the referring file."""
    req_paths: dict[str, list[str]] = {}
    for path, entry in files.items():
        for section in entry["sections"]:
            if section["kind"] == "req":
                req_paths.setdefault(section["anchor"], []).append(path)
    for path, entry in files.items():
        for section in entry["sections"]:
            for ref in section["refs"]:
                if ref["type"] != "req":
                    continue
                paths = req_paths.get(ref["raw"], [])
                if not paths:
                    continue
                owner = path if path in paths else paths[0]
                ref["target"] = f"{owner}#{ref['raw']}"
            # Resolving can reveal a self-reference or a duplicate hidden while unresolved.
            unique = []
            for ref in section["refs"]:
                if ref["target"] == f"{path}#{section['anchor']}" or ref in unique:
                    continue
                unique.append(ref)
            section["refs"] = unique


def load_cache(cache_file: pathlib.Path) -> dict:
    try:
        return json.loads(cache_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"complete": False, "files": {}}
    except (OSError, ValueError) as error:
        raise FetchError(f"unreadable cache {cache_file}: {error}") from error


def save_cache(cache_file: pathlib.Path, cache: dict) -> None:
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=cache_file.parent, delete=False) as handle:
        json.dump(cache, handle, ensure_ascii=False)
    os.replace(handle.name, cache_file)


def build_index(owner: str, name: str, sha: str, requested: list[str]) -> dict:
    repo = f"{owner}/{name}"
    cache_file = CACHE_DIR / f"{owner}_{name}@{sha}.json"
    cache = load_cache(cache_file)
    cached_files = cache["files"]

    if requested:
        paths = requested
    elif cache["complete"]:
        paths = sorted(cached_files)
    else:
        paths = markdown_paths(repo, sha)

    missing = [path for path in paths if path not in cached_files]
    for path in missing:
        cached_files[path] = index_file(repo, path, file_content(repo, sha, path))
    if not requested:
        cache["complete"] = True
    if missing or not requested:
        save_cache(cache_file, cache)

    # The cache holds req targets unresolved: which file a REQ lives in depends on the
    # set of files this call outputs.
    files = json.loads(json.dumps({path: cached_files[path] for path in paths}))
    resolve_req_refs(files)
    return {"repo": repo, "sha": sha, "files": files}


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE, file=sys.stderr)
        return 2
    target = TARGET.fullmatch(argv[0])
    paths = argv[1:]
    if not target or any(not path or path.startswith("/") or ".." in path.split("/") for path in paths):
        print(f"{USAGE}\n<sha> must be a full 40-character commit SHA; paths are repo-relative",
              file=sys.stderr)
        return 2
    owner, name, sha = target.group(1), target.group(2), target.group(3).lower()
    try:
        index = build_index(owner, name, sha, list(dict.fromkeys(paths)))
    except FetchError as error:
        print(f"spec-index: {error}", file=sys.stderr)
        return 1
    print(json.dumps(index, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
