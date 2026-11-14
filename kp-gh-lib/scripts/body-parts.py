#!/usr/bin/env python3
# Split an issue body into the parts a rewrite must copy rather than retype — its
# human-only fence and its marker lines — reassemble a rewritten body and check those
# parts survived byte for byte, and strip the human-only fence from a body. The kp-* skills
# used to carry these as inline jq and python one-liners, each slightly differently.
#
# Usage: body-parts.py split <owner/repo> <n> <prefix> [--from-file <body-file>]
#        body-parts.py assemble <prefix> <sections-file>
#        body-parts.py strip < body > stripped
#
# split: reads the body with `gh issue view <n> -R <owner/repo> --json body -q .body`
#   (or, with --from-file, that file's bytes) and writes
#     <prefix>-orig.md     the body byte for byte;
#     <prefix>-fence.md    the first fence, from its start marker through the first end
#                          marker after it, plus one newline; empty when there is none;
#     <prefix>-markers.md  with that fence removed, every line matching
#                          `^[a-z][a-z0-9-]*: ` except `serves:`, `spec:`, `code:`,
#                          `decision:` and `dismissed:` lines, one per line, in body order.
#   A start marker with no end marker after it writes <prefix>-orig.md only, prints
#   `unclosed-fence` to stderr and exits 3.
#
# assemble: writes <prefix>-draft.md from the non-empty parts <prefix>-fence.md,
#   <sections-file>, <prefix>-markers.md, in that order, one blank line between them; then
#   cuts the fence and markers from the draft by the split rules and compares them with
#   <prefix>-fence.md and <prefix>-markers.md. A difference (an unclosed fence in the
#   draft is one) prints a unified diff to stderr, leaves the draft on disk and exits 1.
#
# strip: copies stdin to stdout with every human-only fence removed; an unclosed one is
#   removed to the end of the body. Text-mode stdin, like the one-liner it replaces, so
#   sha256 of the output is the `body-sha256:` every earlier review verdict recorded.
#
# Exit: 0 ok · 1 assemble check failed · 2 bad arguments · 3 unclosed fence (split) ·
#       4 the gh read failed (split).

import argparse
import difflib
import re
import subprocess
import sys
from pathlib import Path

FENCE_START = b"<!-- human-only:start"
FENCE_END = b"<!-- human-only:end -->"
MARKER_LINE = re.compile(rb"[a-z][a-z0-9-]*: ")
CONTEXT_LINE = re.compile(rb"(serves|spec|code|decision|dismissed):")
# The exact pattern kp-review-gh-pr hashed bodies with; changing it invalidates every
# recorded body-sha256.
STRIP_FENCE = re.compile(r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.DOTALL)
GH_TIMEOUT_SECONDS = 60
REPO_FORMAT = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")

EXIT_CHECK_FAILED = 1
EXIT_UNCLOSED_FENCE = 3
EXIT_GH_FAILED = 4


class UnclosedFence(Exception):
    pass


def cut(body):
    """Return (fence, markers) as split writes them; raise UnclosedFence."""
    last_start = body.rfind(FENCE_START)
    if last_start != -1 and body.find(FENCE_END, last_start) == -1:
        raise UnclosedFence
    start = body.find(FENCE_START)
    if start == -1:
        fence = b""
        rest = body
    else:
        end = body.find(FENCE_END, start) + len(FENCE_END)
        fence = body[start:end] + b"\n"
        rest = body[:start] + body[end:]
    markers = b"".join(
        line + b"\n"
        for line in rest.split(b"\n")
        if MARKER_LINE.match(line) and not CONTEXT_LINE.match(line)
    )
    return fence, markers


def read_issue_body(repo, number):
    try:
        result = subprocess.run(
            ["gh", "issue", "view", number, "-R", repo, "--json", "body", "-q", ".body"],
            capture_output=True,
            timeout=GH_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"body-parts.py: gh issue view {repo}#{number} failed: {error}", file=sys.stderr)
        sys.exit(EXIT_GH_FAILED)
    if result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        print(f"body-parts.py: gh issue view {repo}#{number} failed: {detail}", file=sys.stderr)
        sys.exit(EXIT_GH_FAILED)
    return result.stdout


def split(args):
    body = Path(args.from_file).read_bytes() if args.from_file else read_issue_body(args.repo, args.number)
    Path(f"{args.prefix}-orig.md").write_bytes(body)
    try:
        fence, markers = cut(body)
    except UnclosedFence:
        print("unclosed-fence", file=sys.stderr)
        sys.exit(EXIT_UNCLOSED_FENCE)
    Path(f"{args.prefix}-fence.md").write_bytes(fence)
    Path(f"{args.prefix}-markers.md").write_bytes(markers)


def unified_diff(expected, actual, expected_name, actual_name):
    return "".join(
        difflib.unified_diff(
            expected.decode(errors="replace").splitlines(keepends=True),
            actual.decode(errors="replace").splitlines(keepends=True),
            expected_name,
            actual_name,
        )
    )


def assemble(args):
    fence_path = Path(f"{args.prefix}-fence.md")
    markers_path = Path(f"{args.prefix}-markers.md")
    draft_path = Path(f"{args.prefix}-draft.md")
    fence = fence_path.read_bytes()
    markers = markers_path.read_bytes()
    parts = [part for part in (fence, Path(args.sections_file).read_bytes(), markers) if part]
    draft_path.write_bytes(b"\n".join(parts))

    try:
        draft_fence, draft_markers = cut(draft_path.read_bytes())
    except UnclosedFence:
        print(f"body-parts.py: {draft_path} has an unclosed human-only fence", file=sys.stderr)
        sys.exit(EXIT_CHECK_FAILED)
    report = unified_diff(fence, draft_fence, str(fence_path), f"{draft_path} (fence)")
    report += unified_diff(markers, draft_markers, str(markers_path), f"{draft_path} (markers)")
    if report:
        sys.stderr.write(report)
        sys.exit(EXIT_CHECK_FAILED)


def strip(_args):
    sys.stdout.write(STRIP_FENCE.sub("", sys.stdin.read()))


def existing_file(path):
    if not Path(path).is_file():
        raise argparse.ArgumentTypeError(f"no such file: {path}")
    return path


def repo_name(value):
    if not REPO_FORMAT.fullmatch(value):
        raise argparse.ArgumentTypeError(f"not <owner/repo>: {value}")
    return value


def issue_number(value):
    if not value.isdigit():
        raise argparse.ArgumentTypeError(f"not an issue number: {value}")
    return value


def main():
    parser = argparse.ArgumentParser(prog="body-parts.py")
    commands = parser.add_subparsers(dest="command", required=True)

    split_parser = commands.add_parser("split")
    split_parser.add_argument("repo", type=repo_name)
    split_parser.add_argument("number", type=issue_number)
    split_parser.add_argument("prefix")
    split_parser.add_argument("--from-file", type=existing_file)
    split_parser.set_defaults(run=split)

    assemble_parser = commands.add_parser("assemble")
    assemble_parser.add_argument("prefix")
    assemble_parser.add_argument("sections_file", type=existing_file)
    assemble_parser.set_defaults(run=assemble)

    strip_parser = commands.add_parser("strip")
    strip_parser.set_defaults(run=strip)

    args = parser.parse_args()
    if args.command == "assemble":
        for part in ("fence", "markers"):
            if not Path(f"{args.prefix}-{part}.md").is_file():
                parser.error(f"no {args.prefix}-{part}.md: run split first")
    args.run(args)


if __name__ == "__main__":
    main()
