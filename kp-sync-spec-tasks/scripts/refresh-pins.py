#!/usr/bin/env python3
"""Plan the pin refresh of one coding item's body against a newer spec commit.

Usage: refresh-pins.py --spec-dir <dir> --spec-repo <owner/repo> --sha <synced sha>
                       --body-file <path> --out <path>

Reads spec text from the local clone at --spec-dir (`git show <sha>:<path>`), never from
GitHub, and splits it into sections with spec-index.py's parser. Every pin of --spec-repo
in the body — a `spec:` line or a Rules attribution `> — <repo>@<sha>:<path>#<anchor>` —
is classified against the same anchor at --sha:
  current    already pinned to --sha; left alone
  unchanged  section text identical; the SHA is bumped
  changed    section text differs; the SHA is bumped and `diff` holds the section diff
  missing    the path or anchor does not exist at one of the two commits; left alone
Only the 40 hex characters of a bumped pin change: every other byte of the body, marker
lines included, is written to --out as it was read.

When the goal frame (the first heading titled `Goals…` in the file of the item's first
pin, as read-context.sh picks it) differs between that pin's SHA and --sha, each goal on
the body's `serves:` lines is checked:
  removed    defined at the old SHA and not at --sha
  non-goal   named under a non-goals heading at --sha and not at the old SHA
  changed    its defining line's text differs (the caller judges whether the meaning did)

Prints one JSON object: {"pins": [...], "goalFrameChanged": bool, "goalDrift": [...],
"bodyChanged": bool}.
Exit: 0 ok · 2 bad arguments · 4 the clone cannot show a pinned commit or path.
"""
from __future__ import annotations

import argparse
import difflib
import importlib.util
import json
import pathlib
import re
import subprocess
import sys

SPEC_INDEX_PATH = pathlib.Path(__file__).resolve().parents[2] / "kp-gh-lib" / "scripts" / "spec-index.py"
GIT_TIMEOUT_SECONDS = 30
EXIT_BAD_ARGUMENTS = 2
EXIT_READ_FAILURE = 4

FULL_SHA = re.compile(r"[0-9a-fA-F]{40}")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
PIN_PREFIX = re.compile(r"^(?:spec:[ \t]*| {0,3}>[ \t]*[—–][ \t]*)")
SPEC_REF = re.compile(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-fA-F]{40}):([^#\s]+)#(\S+)")
CODE_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
HUMAN_ONLY_START = re.compile(r"<!--\s*human-only:start")
HUMAN_ONLY_END = re.compile(r"<!--\s*human-only:end\s*-->")
SERVES_LINE = re.compile(r"^serves:[ \t]*(.*?)[ \t]*$")
VIA = re.compile(r"\bvia[ \t]+\S+#\d+$")
GOAL = re.compile(r"\bG-\d+\b")
# A goal is defined where its id opens a line, list item or table row: `**G-1 — …**`,
# `- G-2: …`, `| G-3 | … |`. A mention elsewhere ("protects G-1") is not a definition.
GOAL_DEFINITION = re.compile(r"^[ \t]*(?:[-*+][ \t]+|\d+\.[ \t]+|\|[ \t]*)?(?:\*\*)?(G-\d+)\b")
GOALS_TITLE_PREFIX = "goals"
NON_GOAL_TITLE = "non-goal"


def load_spec_index():
    loader_spec = importlib.util.spec_from_file_location("spec_index", SPEC_INDEX_PATH)
    module = importlib.util.module_from_spec(loader_spec)
    loader_spec.loader.exec_module(module)
    return module


spec_index = load_spec_index()


class ReadFailure(Exception):
    pass


class SpecClone:
    """Files and their sections at any commit of a local spec clone, memoised."""

    def __init__(self, spec_dir: str):
        self.spec_dir = spec_dir
        self.files: dict[tuple[str, str], tuple[list[str], list[dict]] | None] = {}

    def git(self, *args: str) -> subprocess.CompletedProcess:
        command = ["git", "-C", self.spec_dir, *args]
        try:
            return subprocess.run(command, capture_output=True, timeout=GIT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired as error:
            raise ReadFailure(f"{' '.join(command)} timed out after {GIT_TIMEOUT_SECONDS}s") from error

    def require_commit(self, sha: str) -> None:
        if self.git("cat-file", "-e", f"{sha}^{{commit}}").returncode != 0:
            raise ReadFailure(f"{self.spec_dir} has no commit {sha}; fetch the spec repo")

    def file(self, sha: str, path: str) -> tuple[list[str], list[dict]] | None:
        """(lines, sections), or None when the path does not exist at sha."""
        key = (sha, path)
        if key not in self.files:
            self.require_commit(sha)
            if self.git("cat-file", "-e", f"{sha}:{path}").returncode != 0:
                self.files[key] = None
            else:
                shown = self.git("show", f"{sha}:{path}")
                if shown.returncode != 0:
                    detail = shown.stderr.decode("utf-8", "replace").strip()
                    raise ReadFailure(f"git show {sha}:{path} failed: {detail}")
                content = shown.stdout.decode("utf-8", "replace")
                lines = content.split("\n")
                if lines and lines[-1] == "":
                    lines.pop()
                sections = spec_index.index_file("", path, content)["sections"]
                self.files[key] = (lines, sections)
        return self.files[key]

    def section_text(self, sha: str, path: str, anchor: str) -> str | None:
        found = self.file(sha, path)
        if found is None:
            return None
        lines, sections = found
        section = next((s for s in sections if s["anchor"] == anchor), None)
        if section is None:
            return None
        return "\n".join(lines[section["startLine"] - 1:section["endLine"]]) + "\n"

    def goal_frame(self, sha: str, path: str) -> list[tuple[str, bool]] | None:
        """(line, under a non-goals subheading) for each line of the goal frame."""
        found = self.file(sha, path)
        if found is None:
            return None
        lines, sections = found
        frame = next((s for s in sections if s["kind"] == "heading"
                      and s["title"].lower().startswith(GOALS_TITLE_PREFIX)), None)
        if frame is None:
            return None
        subheadings = {s["startLine"]: NON_GOAL_TITLE in s["title"].lower()
                       for s in sections if s["kind"] == "heading"
                       and frame["startLine"] < s["startLine"] <= frame["endLine"]}
        framed = []
        under_non_goal = False
        for number in range(frame["startLine"], frame["endLine"] + 1):
            under_non_goal = subheadings.get(number, under_non_goal)
            framed.append((lines[number - 1], under_non_goal))
        return framed


def body_pins(lines: list[str], spec_repo: str) -> list[dict]:
    """Pins of spec_repo outside the human-only fence and code fences."""
    pins = []
    in_human_only = False
    fence = None
    for index, raw in enumerate(lines):
        line = raw.rstrip("\r\n")
        if in_human_only:
            in_human_only = HUMAN_ONLY_END.search(line) is None
            continue
        if HUMAN_ONLY_START.search(line):
            in_human_only = HUMAN_ONLY_END.search(line) is None
            continue
        fence_match = CODE_FENCE.match(line)
        if fence is not None:
            if fence_match and fence_match.group(1)[0] == fence[0] and len(fence_match.group(1)) >= len(fence):
                fence = None
            continue
        if fence_match:
            fence = fence_match.group(1)
            continue
        prefix = PIN_PREFIX.match(line)
        if not prefix:
            continue
        ref = SPEC_REF.match(line, prefix.end())
        if not ref or ref.group(1).lower() != spec_repo.lower():
            continue
        pins.append({
            "line": index + 1,
            "kind": "spec" if line.startswith("spec:") else "rules",
            "path": ref.group(3), "anchor": ref.group(4), "old": ref.group(2).lower(),
            "shaSpan": ref.span(2),
        })
    return pins


def served_goals(lines: list[str]) -> list[str]:
    goals = []
    for raw in lines:
        match = SERVES_LINE.match(raw.rstrip("\r\n"))
        if match:
            text = match.group(1)
            via = VIA.search(text)
            goals += GOAL.findall(text[:via.start()] if via else text)
    return list(dict.fromkeys(goals))


def classify_pin(clone: SpecClone, pin: dict, sha: str) -> dict:
    result = {key: pin[key] for key in ("line", "kind", "path", "anchor", "old")}
    if pin["old"] == sha:
        return {**result, "status": "current"}
    old_text = clone.section_text(pin["old"], pin["path"], pin["anchor"])
    new_text = clone.section_text(sha, pin["path"], pin["anchor"])
    if old_text is None or new_text is None:
        where = pin["old"] if old_text is None else sha
        return {**result, "status": "missing", "detail": f"{pin['path']}#{pin['anchor']} not found at {where}"}
    if old_text == new_text:
        return {**result, "status": "unchanged"}
    diff = "".join(difflib.unified_diff(
        old_text.splitlines(keepends=True), new_text.splitlines(keepends=True),
        fromfile=f"{pin['path']}@{pin['old'][:7]}", tofile=f"{pin['path']}@{sha[:7]}"))
    return {**result, "status": "changed", "diff": diff}


def goal_definitions(frame: list[tuple[str, bool]]) -> tuple[dict[str, str], set[str]]:
    definitions: dict[str, str] = {}
    non_goal_mentions: set[str] = set()
    for line, under_non_goal in frame:
        if under_non_goal:
            non_goal_mentions.update(GOAL.findall(line))
            continue
        match = GOAL_DEFINITION.match(line)
        if match:
            definitions.setdefault(match.group(1), line.strip())
    return definitions, non_goal_mentions


def goal_drift(clone: SpecClone, first_pin: dict, sha: str, goals: list[str]) -> tuple[bool, list[dict]]:
    old_frame = clone.goal_frame(first_pin["old"], first_pin["path"])
    new_frame = clone.goal_frame(sha, first_pin["path"])
    if old_frame == new_frame:
        return False, []
    old_definitions, old_non_goals = goal_definitions(old_frame or [])
    new_definitions, new_non_goals = goal_definitions(new_frame or [])
    drift = []
    for goal in goals:
        old_line = old_definitions.get(goal)
        new_line = new_definitions.get(goal)
        if goal in new_non_goals and goal not in old_non_goals:
            reason = "non-goal"
        elif old_line is None:
            continue
        elif new_line is None:
            reason = "removed"
        elif old_line != new_line:
            reason = "changed"
        else:
            continue
        drift.append({"goal": goal, "reason": reason, "old": old_line, "new": new_line})
    return True, drift


def refresh(clone: SpecClone, spec_repo: str, sha: str, body: str) -> tuple[dict, str]:
    lines = body.splitlines(keepends=True)
    pins = body_pins(lines, spec_repo)
    planned = [classify_pin(clone, pin, sha) for pin in pins]
    for pin, plan in zip(pins, planned):
        if plan["status"] in ("unchanged", "changed"):
            start, end = pin["shaSpan"]
            line = lines[pin["line"] - 1]
            lines[pin["line"] - 1] = line[:start] + sha + line[end:]
    first_pin = next((pin for pin in pins if pin["kind"] == "spec"), None)
    frame_changed, drift = False, []
    if first_pin is not None and first_pin["old"] != sha:
        frame_changed, drift = goal_drift(clone, first_pin, sha, served_goals(lines))
    new_body = "".join(lines)
    report = {"pins": planned, "goalFrameChanged": frame_changed, "goalDrift": drift,
              "bodyChanged": new_body != body}
    return report, new_body


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--spec-dir", required=True)
    parser.add_argument("--spec-repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--body-file", required=True)
    parser.add_argument("--out", required=True)
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return EXIT_BAD_ARGUMENTS
    if not FULL_SHA.fullmatch(args.sha) or not REPO.fullmatch(args.spec_repo):
        print("refresh-pins: --sha must be a full 40-character SHA and --spec-repo <owner/repo>",
              file=sys.stderr)
        return EXIT_BAD_ARGUMENTS
    try:
        with open(args.body_file, encoding="utf-8", newline="") as handle:
            body = handle.read()
    except OSError as error:
        print(f"refresh-pins: cannot read {args.body_file}: {error}", file=sys.stderr)
        return EXIT_BAD_ARGUMENTS
    try:
        report, new_body = refresh(SpecClone(args.spec_dir), args.spec_repo, args.sha.lower(), body)
    except ReadFailure as error:
        print(f"refresh-pins: {error}", file=sys.stderr)
        return EXIT_READ_FAILURE
    with open(args.out, "w", encoding="utf-8", newline="") as handle:
        handle.write(new_body)
    print(json.dumps(report, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
