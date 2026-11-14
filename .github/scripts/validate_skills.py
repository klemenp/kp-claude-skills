#!/usr/bin/env python3
"""Validate the skill contract for every skill directory in this repo.

Each top-level directory is a skill and must hold a SKILL.md whose YAML frontmatter is a
flat mapping identifying the skill. Exits 1 with a per-skill report on any violation.

Deliberately stdlib-only: the repo has no dependencies and this must run from a bare
clone, in CI, and from a Stop hook without a virtualenv.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# SKILL.md frontmatter description cap. Descriptions are loaded into every session's
# context, so an unbounded one is a real cost, not a style nit.
MAX_DESCRIPTION = 1024

# The Claude Code harness writes this top-level folder itself, holding synced Anthropic
# skills (<id>/manifest.json, <id>/<skill>/SKILL.md). This repo does not own it, so it is
# skipped by exact name only -- never treated as a skill candidate.
SYNCED_DIR = "synced"

NAME_PATTERN = re.compile(r"^kp-[a-z0-9-]+$")
FRONTMATTER_LINE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*): (.*)$")
# Narrow on purpose: only backticked *file* paths into a skill's own asset dirs. Prose
# like `scripts` and directory mentions ending in "/" never trip the check -- git cannot
# track an empty directory, so a directory reference is not a file dependency.
ASSET_REF = re.compile(r"`((?:scripts|templates)/[A-Za-z0-9_.\-/]*[A-Za-z0-9_.\-])`")
REQUIRED_KEYS = ("name", "description")
KNOWN_KEYS = {"name", "description", "allowed-tools", "argument-hint",
              "disable-model-invocation", "context", "model"}


def parse_frontmatter(text: str) -> tuple[dict[str, str], list[str]]:
    """Parse the leading --- fenced block as a flat mapping. Returns (fields, errors)."""
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}, ["missing YAML frontmatter (file must start with '---')"]
    fields: dict[str, str] = {}
    errors: list[str] = []
    for lineno, line in enumerate(lines[1:], start=2):
        if line.strip() == "---":
            return fields, errors
        match = FRONTMATTER_LINE.match(line)
        if not match:
            errors.append(f"line {lineno}: not a flat 'key: value' pair -> {line!r}")
            continue
        key, value = match.group(1), match.group(2).strip()
        if key in fields:
            errors.append(f"line {lineno}: duplicate key {key!r}")
        fields[key] = value.strip("'\"")
    errors.append("frontmatter block is never closed by '---'")
    return fields, errors


def check_allowed_tools(value: str) -> list[str]:
    """Each entry is a bare tool name or Tool(pattern) with balanced parens."""
    errors = []
    for entry in (e.strip() for e in value.split(",")):
        if not entry:
            errors.append("allowed-tools: empty entry (trailing or doubled comma)")
        elif entry.count("(") != entry.count(")"):
            errors.append(f"allowed-tools: unbalanced parentheses in {entry!r}")
        elif "(" in entry and not entry.endswith(")"):
            errors.append(f"allowed-tools: malformed pattern {entry!r}")
    return errors


def validate(skill_dir: Path) -> list[str]:
    errors: list[str] = []
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        return ["no SKILL.md (every top-level directory is loaded as a skill)"]

    text = skill_md.read_text(encoding="utf-8")
    fields, errors = parse_frontmatter(text)

    for key in REQUIRED_KEYS:
        if not fields.get(key):
            errors.append(f"frontmatter is missing a non-empty {key!r}")
    for key in fields:
        if key not in KNOWN_KEYS:
            errors.append(f"unknown frontmatter key {key!r}")

    name = fields.get("name", "")
    if name and name != skill_dir.name:
        errors.append(f"name {name!r} does not match directory {skill_dir.name!r}")
    if name and not NAME_PATTERN.match(name):
        errors.append(f"name {name!r} does not match {NAME_PATTERN.pattern}")

    description = fields.get("description", "")
    if len(description) > MAX_DESCRIPTION:
        errors.append(f"description is {len(description)} chars (max {MAX_DESCRIPTION})")

    if "allowed-tools" in fields:
        errors.extend(check_allowed_tools(fields["allowed-tools"]))

    for ref in sorted(set(ASSET_REF.findall(text))):
        if not (skill_dir / ref).is_file():
            errors.append(f"SKILL.md references {ref!r}, which is not a file on disk")

    return errors


def main() -> int:
    skills = sorted(p for p in REPO.iterdir()
                     if p.is_dir() and not p.name.startswith(".") and p.name != SYNCED_DIR)
    if not skills:
        print(f"no skill directories found under {REPO}", file=sys.stderr)
        return 1

    failed = 0
    for skill in skills:
        errors = validate(skill)
        if errors:
            failed += 1
            print(f"FAIL {skill.name}")
            for error in errors:
                print(f"       {error}")
        else:
            print(f"ok   {skill.name}")

    print(f"\n{len(skills)} skills checked, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
