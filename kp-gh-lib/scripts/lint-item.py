#!/usr/bin/env python3
"""Check a draft coding item against kp-gh-lib/NOTES.md § Coding item body before it is filed.

Usage: lint-item.py --repo <owner/repo> --body-file <path> [--code-root <dir>]

The body's own `spec:` lines name the spec repo and commit to check against; no config is
read. `code:` paths are checked under --code-root (default: the current directory).

Prints one `FAIL <rule>: <detail>` line per problem, then
`INFO bytes=<read-context total> acs=<n> spec-sections=<n>`. Rules:
  sections         a required section is missing or empty (Rules only when spec text is quoted)
  ac-proof         an acceptance criterion has no `— proof:` part
  context-resolve  a `spec:` SHA, path or anchor, or a `code:` path, does not exist
  rules-source     a Rules quote's `> — <source>` is not a resolvable `spec:`-form reference,
                   or its text (whitespace-normalised) is not in that section
Spec-backed items only (a `spec-ref:` marker or any `spec:` line):
  serves-present   no `serves:` line under Goal
  serves-match     a `serves:` goal (without `via`) is not served by the `spec-ref:` section
  spec-gap         the `spec-ref:` section has no `Serves:` line
  via-parent       a `serves: … via <owner/repo>#<n>` parent does not exist
  sweep            an outgoing ref of a loaded spec section (children included) is uncovered

A ref is covered when a `spec:` line loads its target, a Rules quote comes from its target,
a `decision:` line names it, or a `dismissed: <ref> — <reason>` line names it; `goal` refs
always are. A dismissal names the ref's target (`<path>#<anchor>`) or its raw text. A `§n`
that resolved into its own file is dismissed by target only, because the same raw `§n` also
names a section of another doc ("Payments spec §8"). An unresolved ref is covered only by a
dismissal, or by a `spec:` line that loads it: a REQ by anchor, an `ADR-<n>` by a section
whose anchor is or starts with `adr-<n>`, a `§n` by a same-numbered section of another loaded
file.

The `spec-ref:` section is looked up in the files the `spec:` lines load, then in the whole
spec repo at that commit. A `<doc-slug>#<heading-slug>` key matches a heading anchor only in
the file whose name slugs to `<doc-slug>` (`PAYMENTS_Interface_Spec.md` → `payments-interface-spec`).

REST only, every gh call bounded by a timeout.
Exit: 0 pass · 1 at least one FAIL · 2 bad arguments · 4 a fetch failure (network or gh),
      which is never reported as a content FAIL.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.parse

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
SPEC_INDEX = SCRIPT_DIR / "spec-index.py"
READ_CONTEXT = SCRIPT_DIR / "read-context.sh"
# Same content cache read-context.sh fills, so both scripts share one fetch per file.
CONTENT_CACHE_DIR = SCRIPT_DIR.parent / "state" / "spec-index" / "content"
GH_TIMEOUT_SECONDS = 30
SPEC_INDEX_TIMEOUT_SECONDS = 300
READ_CONTEXT_TIMEOUT_SECONDS = 600

EXIT_FAIL = 1
EXIT_BAD_ARGUMENTS = 2
EXIT_FETCH_FAILURE = 4

ALWAYS_REQUIRED = ("Goal", "Scope", "Out of scope", "Context", "Acceptance criteria", "Verify")
RULES = "Rules"

REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
HUMAN_ONLY_FENCE = re.compile(
    r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", re.S)
HTML_COMMENT = re.compile(r"<!--.*?-->", re.S)
CODE_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*?)[ \t#]*$")
CONTEXT_LINE = re.compile(r"^(spec|code|dismissed):[ \t]*(.*?)[ \t]*$")
TRAILING_COMMENT = re.compile(r"[ \t]+#[ \t].*$")
SPEC_REF_MARKER = re.compile(r"^spec-ref:[ \t]*(\S+)")
SERVES_LINE = re.compile(r"^serves:[ \t]*(.*?)[ \t]*$")
VIA = re.compile(r"\bvia[ \t]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\d+)$")
GOAL = re.compile(r"\bG-\d+\b")
SPEC_REF = re.compile(
    r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-fA-F]{40}):([^#\s]+)#(\S+)")
CODE_REF = re.compile(r"([^#\s]+)(?:#(\S+))?")
DISMISSED = re.compile(r"(.+?)[ \t]+—[ \t]*(\S.*)")
LIST_ITEM = re.compile(r"^[-*+][ \t]+")
PROOF = re.compile(r"—[ \t]*proof:")
QUOTE_LINE = re.compile(r"^ {0,3}>[ \t]?(.*)$")
ATTRIBUTION = re.compile(r"^[—–][ \t]*(.*?)[ \t]*$")
# A quote attributed to anything shaped like a pinned spec ref counts as quoting spec text.
SPEC_ATTRIBUTION = re.compile(r"^ {0,3}>[ \t]*[—–][ \t]*\S+/\S+@\S+")
REQ_KEY = re.compile(r"REQ-[A-Z]+-\d{3}")
SECTION_RAW_NUMBER = re.compile(r"§\s?(\S+)")
WHITESPACE = re.compile(r"\s+")
NOT_FOUND = re.compile(r"\(HTTP (?:404|422)\)")
READ_CONTEXT_TOTAL = re.compile(r"^===== total: (\d+) B, \d+ blocks =====$", re.M)


class FetchError(Exception):
    """GitHub could not be reached or answered with something other than not-found."""


class NotFound(Exception):
    """GitHub answered that the repo, commit or path does not exist (or is not visible)."""


def normalise(text: str) -> str:
    return WHITESPACE.sub(" ", text).strip()


def run(command: list[str], timeout: int) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(command, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise FetchError(f"{' '.join(command)} timed out after {timeout}s") from error
    except OSError as error:
        raise FetchError(f"cannot run {command[0]}: {error}") from error


def gh_api(endpoint: str, *extra: str) -> str:
    result = run(["gh", "api", endpoint, *extra], GH_TIMEOUT_SECONDS)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        if NOT_FOUND.search(detail):
            raise NotFound(detail)
        raise FetchError(f"gh api {endpoint} failed: {detail}")
    return result.stdout.decode("utf-8", "replace")


# ---------------------------------------------------------------- body parsing

def unfenced_lines(body: str) -> list[tuple[int, str]]:
    """(index, line) for each line outside code fences."""
    found = []
    fence = None
    for index, line in enumerate(body.split("\n")):
        fence_match = CODE_FENCE.match(line)
        if fence is not None:
            if fence_match and fence_match.group(1)[0] == fence[0] \
                    and len(fence_match.group(1)) >= len(fence):
                fence = None
            continue
        if fence_match:
            fence = fence_match.group(1)
            continue
        found.append((index, line))
    return found


def body_sections(body: str) -> dict[str, list[str]]:
    """Lowercased heading title -> its lines, up to the next heading of the same or higher level."""
    lines = body.split("\n")
    headings = [(index, len(match.group(1)), match.group(2).strip())
                for index, line in unfenced_lines(body)
                if (match := HEADING.match(line))]
    sections: dict[str, list[str]] = {}
    for position, (index, level, title) in enumerate(headings):
        end = next((later for later, later_level, _ in headings[position + 1:]
                    if later_level <= level), len(lines))
        sections.setdefault(title.lower(), lines[index + 1:end])
    return sections


def doc_slug_of(path: str) -> str:
    """The `<doc-slug>` a `spec-ref:` key uses for a spec file: `PAYMENTS_Interface_Spec.md` →
    `payments-interface-spec`."""
    return pathlib.PurePath(path).stem.lower().replace("_", "-")


def is_empty(lines: list[str]) -> bool:
    return not HTML_COMMENT.sub("", "\n".join(lines)).strip()


def acceptance_criteria(lines: list[str]) -> list[str]:
    """Each top-level list item with its continuation lines joined."""
    items: list[str] = []
    for line in lines:
        if LIST_ITEM.match(line):
            items.append(line)
        elif items and line.strip():
            items[-1] += " " + line.strip()
    return items


def rules_quotes(lines: list[str]) -> list[tuple[str, str | None]]:
    """(quoted text, source or None) per blockquote group; the source is its `— …` last line."""
    groups: list[list[str]] = []
    previous_was_quote = False
    for line in lines:
        match = QUOTE_LINE.match(line)
        if match:
            if not previous_was_quote:
                groups.append([])
            groups[-1].append(match.group(1))
        previous_was_quote = bool(match)
    quotes = []
    for group in groups:
        attribution = ATTRIBUTION.match(group[-1])
        if attribution:
            quotes.append((normalise(" ".join(group[:-1])), attribution.group(1)))
        else:
            quotes.append((normalise(" ".join(group)), None))
    return quotes


# ---------------------------------------------------------------- spec access

class SpecRepo:
    """Sections and content of the spec files named for one repo at one commit."""

    def __init__(self, repo: str, sha: str):
        self.repo = repo
        self.sha = sha
        self.sections: dict[str, list[dict]] = {}
        self.missing: dict[str, str] = {}

    def check_path(self, path: str) -> str | None:
        """None when the path indexes at this commit, else why it does not."""
        if path in self.sections or path in self.missing:
            return self.missing.get(path)
        result = run([sys.executable, str(SPEC_INDEX), f"{self.repo}@{self.sha}", path],
                     SPEC_INDEX_TIMEOUT_SECONDS)
        detail = result.stderr.decode("utf-8", "replace").strip()
        if result.returncode == 0:
            self.sections[path] = []
            return None
        if result.returncode == 1 and NOT_FOUND.search(detail):
            reason = (f"commit {self.sha} not found in {self.repo}" if "No commit found" in detail
                      else f"{path} not found in {self.repo}@{self.sha} (or not visible)")
            self.missing[path] = reason
            return reason
        raise FetchError(f"spec-index.py {self.repo}@{self.sha} {path} failed: {detail}")

    def index(self, extra_paths: tuple[str, ...] = ()) -> None:
        """Index every existing path together, so REQ refs resolve across them."""
        paths = sorted(set(self.sections) | set(extra_paths))
        command = [sys.executable, str(SPEC_INDEX), f"{self.repo}@{self.sha}", *paths]
        result = run(command, SPEC_INDEX_TIMEOUT_SECONDS)
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise FetchError(f"spec-index.py {self.repo}@{self.sha} failed: {detail}")
        files = json.loads(result.stdout)["files"]
        self.sections = {path: entry["sections"] for path, entry in files.items()}

    def whole_repo_sections(self) -> dict[str, list[dict]]:
        result = run([sys.executable, str(SPEC_INDEX), f"{self.repo}@{self.sha}"],
                     SPEC_INDEX_TIMEOUT_SECONDS)
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace").strip()
            raise FetchError(f"spec-index.py {self.repo}@{self.sha} failed: {detail}")
        files = json.loads(result.stdout)["files"]
        return {path: entry["sections"] for path, entry in files.items()}

    def section(self, path: str, anchor: str) -> dict | None:
        return next((s for s in self.sections.get(path, []) if s["anchor"] == anchor), None)

    def descendants(self, path: str, outer: dict) -> list[dict]:
        return [s for s in self.sections[path]
                if s["startLine"] >= outer["startLine"] and s["endLine"] <= outer["endLine"]]

    def content(self, path: str) -> str:
        cache_file = CONTENT_CACHE_DIR / f"{self.repo.replace('/', '_')}@{self.sha}" / path
        try:
            return cache_file.read_text(encoding="utf-8")
        except FileNotFoundError:
            pass
        try:
            text = gh_api(f"repos/{self.repo}/contents/{urllib.parse.quote(path)}?ref={self.sha}",
                          "-H", "Accept: application/vnd.github.raw")
        except NotFound as error:
            raise FetchError(f"{path} vanished from {self.repo}@{self.sha}: {error}") from error
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=cache_file.parent,
                                         delete=False) as handle:
            handle.write(text)
        os.replace(handle.name, cache_file)
        return text

    def section_text(self, path: str, section: dict) -> str:
        lines = self.content(path).split("\n")
        return "\n".join(lines[section["startLine"] - 1:section["endLine"]])


# ---------------------------------------------------------------- linter

class Linter:
    def __init__(self, repo: str, body: str, code_root: pathlib.Path):
        self.repo = repo
        self.body = body
        self.code_root = code_root
        self.failures: list[str] = []
        self.sections = body_sections(body)
        self.specs: list[tuple[str, str, str, str]] = []
        self.codes: list[str] = []
        self.dismissed: set[str] = set()
        self.spec_repos: dict[tuple[str, str], SpecRepo] = {}
        self.spec_ref: str | None = None
        for _, line in unfenced_lines(body):
            marker = SPEC_REF_MARKER.match(line)
            if marker and self.spec_ref is None:
                self.spec_ref = marker.group(1)

    def fail(self, rule: str, detail: str) -> None:
        self.failures.append(f"FAIL {rule}: {detail}")

    def spec_repo(self, repo: str, sha: str) -> SpecRepo:
        key = (repo, sha.lower())
        if key not in self.spec_repos:
            self.spec_repos[key] = SpecRepo(*key)
        return self.spec_repos[key]

    def section_lines(self, title: str) -> list[str] | None:
        return self.sections.get(title.lower())

    # -- sections / ac-proof

    def check_sections(self) -> None:
        for title in ALWAYS_REQUIRED:
            lines = self.section_lines(title)
            if lines is None:
                self.fail("sections", f"missing `### {title}`")
            elif is_empty(lines):
                self.fail("sections", f"`### {title}` is empty")
        quotes_spec = any(SPEC_ATTRIBUTION.match(line) for _, line in unfenced_lines(self.body))
        rules = self.section_lines(RULES)
        if quotes_spec and (rules is None or is_empty(rules)):
            self.fail("sections", f"the body quotes spec text, so `### {RULES}` is required")

    def check_ac_proof(self) -> int:
        items = acceptance_criteria(self.section_lines("Acceptance criteria") or [])
        for item in items:
            if not PROOF.search(item):
                self.fail("ac-proof", f"no `— proof:` in: {item.strip()}")
        return len(items)

    # -- context-resolve

    def parse_context(self) -> None:
        for _, line in unfenced_lines(self.body):
            match = CONTEXT_LINE.match(line)
            if not match:
                continue
            kind, value = match.group(1), TRAILING_COMMENT.sub("", match.group(2))
            if kind == "dismissed":
                dismissal = DISMISSED.fullmatch(value)
                if dismissal:
                    self.dismissed.add(dismissal.group(1).strip())
                continue
            pattern = SPEC_REF if kind == "spec" else CODE_REF
            parsed = pattern.fullmatch(value)
            if not parsed:
                self.fail("context-resolve", f"malformed `{kind}:` line: {value!r}")
            elif kind == "spec":
                spec_repo, sha, path, anchor = parsed.groups()
                self.specs.append((spec_repo, sha.lower(), path, anchor))
            else:
                self.codes.append(parsed.group(1))

    def check_context_resolve(self) -> None:
        for spec_repo, sha, path, _ in self.specs:
            self.spec_repo(spec_repo, sha).check_path(path)
        for (spec_repo, sha), spec in self.spec_repos.items():
            if spec.sections:
                spec.index()
        for spec_repo, sha, path, anchor in self.specs:
            ref = f"{spec_repo}@{sha}:{path}#{anchor}"
            spec = self.spec_repo(spec_repo, sha)
            missing = spec.missing.get(path)
            if missing:
                self.fail("context-resolve", f"`spec: {ref}`: {missing}")
            elif spec.section(path, anchor) is None:
                self.fail("context-resolve", f"`spec: {ref}`: no section with anchor `{anchor}`")
        root = self.code_root.resolve()
        for path in self.codes:
            target = (root / path).resolve()
            if pathlib.Path(path).is_absolute() or root not in (target, *target.parents):
                self.fail("context-resolve", f"`code: {path}` is outside the code root {root}")
            elif not target.is_file():
                self.fail("context-resolve", f"`code: {path}` does not exist under {root}")

    def loaded_specs(self) -> list[tuple[SpecRepo, str, dict]]:
        loaded = []
        for spec_repo, sha, path, anchor in self.specs:
            spec = self.spec_repo(spec_repo, sha)
            section = spec.section(path, anchor)
            if section is not None:
                loaded.append((spec, path, section))
        return loaded

    # -- rules-source

    def check_rules_source(self) -> list[tuple[SpecRepo, str, str]]:
        """Validate every Rules quote; return (spec, path, anchor) of each valid one."""
        valid = []
        for text, source in rules_quotes(self.section_lines(RULES) or []):
            excerpt = text[:60]
            if source is None:
                self.fail("rules-source", f"quote {excerpt!r} has no `> — <source>` line")
                continue
            parsed = SPEC_REF.fullmatch(source)
            if not parsed:
                self.fail("rules-source",
                          f"quote {excerpt!r}: source {source!r} is not "
                          "`<owner/repo>@<sha>:<path>#<anchor>`")
                continue
            spec_repo, sha, path, anchor = parsed.groups()
            spec = self.spec_repo(spec_repo, sha)
            missing = spec.check_path(path)
            if missing:
                self.fail("rules-source", f"quote {excerpt!r}: {missing}")
                continue
            if path not in spec.sections or not spec.sections[path]:
                spec.index((path,))
            section = spec.section(path, anchor)
            if section is None:
                self.fail("rules-source", f"quote {excerpt!r}: no section `{anchor}` in "
                                          f"{spec.repo}@{spec.sha}:{path}")
                continue
            if text not in normalise(spec.section_text(path, section)):
                self.fail("rules-source", f"quote {excerpt!r} does not occur in {source}")
                continue
            valid.append((spec, path, anchor))
        return valid

    # -- serves

    def serves_lines(self) -> list[str]:
        return [match.group(1) for line in self.section_lines("Goal") or []
                if (match := SERVES_LINE.match(line))]

    def resolved_spec_repos(self) -> list[SpecRepo]:
        return [spec for spec in self.spec_repos.values() if spec.sections]

    def governing_section(self) -> tuple[SpecRepo, str, dict] | None:
        key = self.spec_ref
        is_req = REQ_KEY.fullmatch(key) is not None
        doc_slug, _, heading = key.partition("#")
        for spec in self.resolved_spec_repos():
            for candidates in (spec.sections, None):
                files = candidates if candidates is not None else spec.whole_repo_sections()
                matches = [(path, section) for path, sections in files.items()
                           for section in sections
                           if (section["kind"] == "req" and section["anchor"] == key) or
                           (not is_req and section["kind"] == "heading"
                            and section["anchor"] == heading
                            and doc_slug_of(path) == doc_slug)]
                if matches:
                    path, section = matches[0]
                    return spec, path, section
        return None

    def check_serves(self) -> None:
        lines = self.serves_lines()
        if not lines:
            self.fail("serves-present", "a spec-backed item needs a `serves:` line under `### Goal`")
        own_goals = []
        for line in lines:
            via = VIA.search(line)
            goals = GOAL.findall(line[:via.start()] if via else line)
            if not goals:
                self.fail("serves-present", f"`serves: {line}` names no `G-<n>` goal")
            if via:
                self.check_via_parent(via.group(1), via.group(2))
            else:
                own_goals += goals
        if self.spec_ref is None:
            return
        if not self.resolved_spec_repos():
            self.fail("serves-match", f"`spec-ref: {self.spec_ref}` cannot be checked: "
                                      "no `spec:` line resolves to a spec repo and commit")
            return
        governing = self.governing_section()
        if governing is None:
            pinned = ", ".join(f"{s.repo}@{s.sha}" for s in self.resolved_spec_repos())
            self.fail("serves-match", f"`spec-ref: {self.spec_ref}` names no section in {pinned}")
            return
        spec, path, section = governing
        where = f"{spec.repo}@{spec.sha}:{path}#{section['anchor']}"
        if section["serves"] is None:
            self.fail("spec-gap",
                      f"{where} (`spec-ref: {self.spec_ref}`) has no `Serves:` line. The spec "
                      "must gain a `Serves:` line; fix it through the spec, not in the item")
            return
        for goal in own_goals:
            if goal not in section["serves"]:
                served = ", ".join(section["serves"]) or "no goal"
                self.fail("serves-match",
                          f"`serves: {goal}` but {where} serves {served}")

    def check_via_parent(self, parent_repo: str, number: str) -> None:
        try:
            gh_api(f"repos/{parent_repo}/issues/{number}", "--jq", ".number")
        except NotFound:
            self.fail("via-parent", f"parent {parent_repo}#{number} does not exist")

    # -- sweep

    def check_sweep(self, quoted: list[tuple[SpecRepo, str, str]]) -> None:
        loaded = self.loaded_specs()
        decisions = {value for _, line in unfenced_lines(self.body)
                     if (match := re.match(r"^decision:[ \t]*(\S+)", line))
                     for value in [match.group(1)]}
        uncovered: dict[tuple[str, str, str | None], list[str]] = {}
        for spec, path, outer in loaded:
            for section in spec.descendants(path, outer):
                for ref in section["refs"]:
                    if not self.covered(spec, path, ref, loaded, quoted, decisions):
                        key = (f"{spec.repo}@{spec.sha}", ref["raw"], ref["target"])
                        referrer = f"{path}#{section['anchor']}"
                        uncovered.setdefault(key, [])
                        if referrer not in uncovered[key]:
                            uncovered[key].append(referrer)
        for (pinned, raw, target), referrers in uncovered.items():
            by = ", ".join(referrers)
            if target is None:
                self.fail("sweep", f"{raw} (unresolved) in {pinned}, referenced by {by}: "
                                   f"load it explicitly or add `dismissed: {raw} — <reason>`")
            else:
                self.fail("sweep", f"{raw} → {target} in {pinned}, referenced by {by}, is not "
                                   "covered: load it with a `spec:` line, quote it in Rules, "
                                   f"or add `dismissed: {target} — <reason>`")

    def covered(self, spec: SpecRepo, path: str, ref: dict,
                loaded: list[tuple[SpecRepo, str, dict]],
                quoted: list[tuple[SpecRepo, str, str]], decisions: set[str]) -> bool:
        raw, kind, target = ref["raw"], ref["type"], ref["target"]
        if kind == "goal" or (target is not None and target in self.dismissed):
            return True
        if raw in self.dismissed and not (kind == "section" and target is not None):
            return True
        if kind == "decision":
            return target in decisions
        same_repo = [(p, s) for other, p, s in loaded if other is spec]
        if target is None:
            if kind == "req":
                return any(s["anchor"] == raw for _, s in same_repo)
            if kind == "adr":
                adr_slug = raw.lower()
                return any(s["anchor"].lower() == adr_slug
                           or s["anchor"].lower().startswith(f"{adr_slug}-")
                           for _, s in same_repo)
            number = SECTION_RAW_NUMBER.match(raw)
            return kind == "section" and number is not None and any(
                p != path and s["number"] == number.group(1) for p, s in same_repo)
        target_path, _, target_anchor = target.partition("#")
        if any(other is spec and p == target_path and a == target_anchor
               for other, p, a in quoted):
            return True
        target_section = spec.section(target_path, target_anchor)
        return target_section is not None and any(
            p == target_path and s["startLine"] <= target_section["startLine"]
            and target_section["endLine"] <= s["endLine"] for p, s in same_repo)

    # -- info

    def context_bytes(self, body_file: str) -> str:
        command = [str(READ_CONTEXT), "--code-root", str(self.code_root),
                   "--body-file", body_file, "--repo", self.repo]
        result = run(command, READ_CONTEXT_TIMEOUT_SECONDS)
        total = READ_CONTEXT_TOTAL.search(result.stdout.decode("utf-8", "replace"))
        if result.returncode in (0, 3) and total:
            return total.group(1)
        # read-context.sh cannot load a spec line that does not resolve; that is already a
        # content failure, so the byte count is simply unknown. Any other exit, a fetch
        # failure included, stays a fetch failure.
        if result.returncode == 3 and any(f.startswith("FAIL context-resolve")
                                          for f in self.failures):
            return "unknown"
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise FetchError(f"read-context.sh exited {result.returncode}: {detail}")

    def lint(self, body_file: str) -> list[str]:
        self.check_sections()
        acs = self.check_ac_proof()
        self.parse_context()
        self.check_context_resolve()
        quoted = self.check_rules_source()
        if self.spec_ref is not None or self.specs:
            self.check_serves()
            self.check_sweep(quoted)
        info = (f"INFO bytes={self.context_bytes(body_file)} acs={acs} "
                f"spec-sections={len(self.specs)}")
        return [*self.failures, info]


class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        print(f"lint-item.py: {message}", file=sys.stderr)
        sys.exit(EXIT_BAD_ARGUMENTS)


def main(argv: list[str]) -> int:
    parser = Parser(prog="lint-item.py", description="Check a draft coding item body.")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--body-file", required=True)
    parser.add_argument("--code-root", default=".")
    args = parser.parse_args(argv)
    if not REPO.fullmatch(args.repo):
        parser.error(f"--repo must be <owner/repo>, got {args.repo!r}")
    if not os.path.isfile(args.body_file):
        parser.error(f"no such body file: {args.body_file}")
    code_root = pathlib.Path(args.code_root)
    if not code_root.is_dir():
        parser.error(f"no such code root: {args.code_root}")

    body = pathlib.Path(args.body_file).read_text(encoding="utf-8").replace("\r\n", "\n")
    body = HUMAN_ONLY_FENCE.sub("", body)
    try:
        lines = Linter(args.repo, body, code_root).lint(args.body_file)
    except (FetchError, NotFound, json.JSONDecodeError) as error:
        print(f"lint-item.py: fetch failure, lint incomplete: {error}", file=sys.stderr)
        return EXIT_FETCH_FAILURE
    print("\n".join(lines))
    return EXIT_FAIL if len(lines) > 1 else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
