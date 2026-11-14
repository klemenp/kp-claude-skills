#!/usr/bin/env python3
"""PreToolUse gate: a PR merges only when CI is green and an approval is pinned to the
PR's current head commit.

GitHub-side enforcement (branch protection, rulesets) is deliberately not used in this
repo, so this hook is the only automated check between an agent and an unreviewed merge.
Unlike guard_bash.py it is load-bearing rather than a backstop: every uncertainty -- an
unparseable command, a failed API call, a missing PR number -- is a deny.

It raises the cost of skipping review; it cannot prevent it. There is no override token,
but on a self-authored PR the approval it reads is an ordinary issue comment that an
agent is free to write. See the limits in CLAUDE.md's Enforcement section.

Approval is read from either channel `kp-review-gh-pr` can write (GitHub rejects a
formal self-review, so on a self-authored PR the verdict lives in a marked comment):

  * a formal review whose state is APPROVED and whose commit_id is the head SHA;
  * a comment carrying VERDICT_MARKER with a `verdict: APPROVED` line and an
    `approved: <head sha>` line.

The most recent verdict across both channels wins. Pinning it to the head SHA is what
stops "review it, push two more commits, merge it".

What counts as a merge. The command is split into segments at shell operators and
unquoted newlines, and each segment is at most one merge:

  * a token whose basename is `gh`, followed (options skipped) by `pr merge` -- so a full
    path, `command gh`, `env X=1 gh`, `sudo gh` and `gh -R <repo> pr merge` all count;
  * any token ending in the REST merge path `repos/<o>/<r>/pulls/<n>/merge`, whatever
    program it is passed to (`gh api`, `curl`).

Every merge in a command is checked, each against its own segment's tokens. The string
after `-c` of bash/sh/zsh/dash and the arguments of `eval` are searched the same way.
Two forms are denied outright because they cannot be checked: a GraphQL merge mutation
(the PR is a node id) and `gh pr merge --auto` (it would merge a later head).

Erring towards a deny is deliberate: an unquoted `echo gh pr merge 6` is treated as a
merge. Not detected: a merge inside backticks or inside a quoted string other than the
nested-shell cases above (including "$(...)"), one reached through a shell variable or
alias holding the program name, and one made by a script file.
"""
from __future__ import annotations

import dataclasses
import json
import os
import re
import subprocess
import sys

from shell_words import (MAX_NESTING_DEPTH, nested_commands, segments_of,
                         tokenize)

VERDICT_MARKER = "<!-- kp-review-gh-pr:verdict -->"
APPROVED_VERDICT = re.compile(r"^verdict:\s*APPROVED\s*$", re.MULTILINE)
# Full 40-char SHAs only: the value is compared against `headRefOid`, so an
# abbreviated SHA could never match and would deny with a confusing message.
APPROVED_SHA = re.compile(r"^approved:\s*([0-9a-f]{40})\s*$", re.MULTILINE)

# `gh pr checks` bucket values that count as green. Anything else -- fail, pending,
# cancel -- or no checks at all, blocks.
GREEN_BUCKETS = {"pass", "skipping"}

GH_TIMEOUT_SECONDS = 30

# The raw REST spelling of a merge: gh api --method PUT repos/<o>/<r>/pulls/<n>/merge
API_MERGE_PATH = re.compile(r"repos/([^/\s]+/[^/\s]+)/pulls/(\d+)/merge/?$")

# Options whose *value* is a bare word and must not be mistaken for the PR number.
VALUE_FLAGS = frozenset({"-b", "--body", "-F", "--body-file", "-t", "--subject",
                         "-R", "--repo", "--match-head-commit", "--author-email"})

REPO_FLAGS = frozenset({"-R", "--repo"})
GITHUB_API_PREFIX = "https://api.github.com/"
GRAPHQL_MERGE_MUTATIONS = ("mergePullRequest", "enablePullRequestAutoMerge")
SQUASH_FLAG = "--squash"
SQUASH_API_FIELD = "merge_method=squash"
AUTO_MERGE_FLAG = "--auto"

FLOW_REMINDER = (
    "A PR merges only after /kp-review-gh-pr approves it at its current head "
    "(CI green + a verdict pinned to the head SHA). Merge from your own shell if you "
    "mean to override this."
)


def deny(reason: str) -> None:
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": f"Blocked by repo merge gate: {reason}",
    }}, sys.stdout)
    sys.exit(0)


def allow() -> None:
    """Silence is 'no opinion' -- the normal permission flow continues."""
    sys.exit(0)


def gh(args: list[str], cwd: str | None) -> tuple[int, str]:
    """Run a gh command. Returns (exit code, stdout); a failure to launch is (-1, "")."""
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True,
                                cwd=cwd or None, timeout=GH_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError):
        return -1, ""
    return result.returncode, result.stdout


def gh_json(args: list[str], cwd: str | None, what: str):
    """Run a gh command that must produce JSON. Denies rather than returning on failure."""
    code, out = gh(args, cwd)
    if code != 0:
        detail = "gh could not be run" if code < 0 else f"gh exited {code}"
        deny(f"could not read {what} ({detail}). The gate fails closed.")
    try:
        return json.loads(out)
    except (json.JSONDecodeError, ValueError):
        deny(f"could not parse {what} from gh output. The gate fails closed.")


@dataclasses.dataclass(frozen=True)
class MergeTarget:
    """One merge invocation: the segment it was found in and what that segment names."""
    tokens: tuple[str, ...]
    repo: str | None
    pr: str | None
    # Set when this form of merge is refused whatever its review state.
    refusal: str | None = None


def is_gh(token: str) -> bool:
    return os.path.basename(token) == "gh"


def gh_subcommand(after_gh: list[str]) -> list[str]:
    """The tokens from gh's subcommand on, with the options before it skipped."""
    index = 0
    while index < len(after_gh) and after_gh[index].startswith("-"):
        index += 2 if after_gh[index] in REPO_FLAGS else 1
    return after_gh[index:]


def merge_in_segment(segment: list[str]) -> MergeTarget | None:
    tokens = tuple(segment)
    runs_gh = any(is_gh(token) for token in segment)
    if runs_gh and "graphql" in segment and any(
            mutation in token for token in segment for mutation in GRAPHQL_MERGE_MUTATIONS):
        return MergeTarget(tokens, None, None, refusal=(
            "a GraphQL merge names the PR by node id, so its review state cannot be "
            "checked. Use `gh pr merge <n> --squash`."))
    for index, token in enumerate(segment):
        if not is_gh(token):
            continue
        subcommand = gh_subcommand(segment[index + 1:])
        if subcommand[:2] != ["pr", "merge"]:
            continue
        if AUTO_MERGE_FLAG in segment:
            return MergeTarget(tokens, None, None, refusal=(
                "auto-merge would merge a later head than the one reviewed. Merge "
                "without --auto once the PR is approved at its head."))
        return MergeTarget(tokens, explicit_repo(segment), pr_number_argument(subcommand[2:]))
    for token in segment:
        match = API_MERGE_PATH.search(token.removeprefix(GITHUB_API_PREFIX))
        if match:
            return MergeTarget(tokens, match.group(1), match.group(2))
    return None


def find_merge_targets(tokens: list[str], depth: int = 0) -> list[MergeTarget]:
    """Every merge invocation in the command, in order, nested shell commands included."""
    targets: list[MergeTarget] = []
    for segment in segments_of(tokens):
        target = merge_in_segment(segment)
        if target is not None:
            targets.append(target)
        if depth < MAX_NESTING_DEPTH:
            for nested in nested_commands(segment):
                targets.extend(find_merge_targets(tokenize(nested), depth + 1))
    return targets


def explicit_repo(tokens: list[str]) -> str | None:
    for index, token in enumerate(tokens):
        if token in ("-R", "--repo") and index + 1 < len(tokens):
            return tokens[index + 1]
        if token.startswith("--repo="):
            return token.split("=", 1)[1]
    return None


def pr_number_argument(tokens: list[str]) -> str | None:
    """First bare integer after `gh pr merge`, skipping option values."""
    skip_next = False
    for token in tokens:
        if skip_next:
            skip_next = False
            continue
        if token in VALUE_FLAGS:
            skip_next = True
            continue
        if token.startswith("-"):
            continue
        return token if token.isdigit() else None
    return None


def resolve_repo(cwd: str | None) -> str:
    code, out = gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], cwd)
    if code != 0 or not out.strip():
        deny("could not resolve the repository. Pass -R <owner>/<name> explicitly.")
    return out.strip()


def is_squash(target: MergeTarget) -> bool:
    return SQUASH_FLAG in target.tokens or any(
        SQUASH_API_FIELD in token for token in target.tokens)


def checks_are_green(pr: str, repo: str, cwd: str | None) -> tuple[bool, str]:
    """gh pr checks exits non-zero for red *and* pending runs, so read its JSON, not
    its exit code -- but an unparseable body still means 'unknown', which blocks."""
    _code, out = gh(["pr", "checks", pr, "-R", repo, "--json", "bucket,name"], cwd)
    if not out.strip():
        return False, "no checks reported for the head commit"
    try:
        checks = json.loads(out)
    except (json.JSONDecodeError, ValueError):
        return False, "could not parse the check results"
    if not checks:
        return False, "no checks reported for the head commit"
    blocking = [f"{check.get('name')} ({check.get('bucket')})" for check in checks
                if check.get("bucket") not in GREEN_BUCKETS]
    if blocking:
        return False, "CI is not green: " + ", ".join(blocking)
    return True, ""


def latest_verdict(pr: str, repo: str, cwd: str | None) -> tuple[str, bool, str | None]:
    """The most recent verdict across both channels, as (timestamp, approved, sha).

    An empty timestamp means no verdict was found at all.
    """
    verdicts: list[tuple[str, bool, str | None]] = []

    reviews = gh_json(["api", f"repos/{repo}/pulls/{pr}/reviews", "--paginate"],
                      cwd, "the PR's reviews")
    for review in reviews:
        state = review.get("state")
        if state not in ("APPROVED", "CHANGES_REQUESTED"):
            continue  # COMMENTED / PENDING reviews carry no verdict.
        verdicts.append((review.get("submitted_at") or "",
                         state == "APPROVED",
                         review.get("commit_id")))

    comments = gh_json(["api", f"repos/{repo}/issues/{pr}/comments", "--paginate"],
                       cwd, "the PR's comments")
    for comment in comments:
        body = comment.get("body") or ""
        if VERDICT_MARKER not in body:
            continue
        sha = APPROVED_SHA.search(body)
        # A marked comment without an explicit APPROVED verdict is a denial -- that is
        # both the old format's meaning and the safe default.
        verdicts.append((comment.get("updated_at") or "",
                         bool(APPROVED_VERDICT.search(body)),
                         sha.group(1) if sha else None))

    if not verdicts:
        return "", False, None
    return max(verdicts, key=lambda verdict: verdict[0])


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return  # A malformed event is not a merge; never block on it.

    command = (event.get("tool_input") or {}).get("command") or ""
    if not command:
        return
    cwd = event.get("cwd")

    targets = find_merge_targets(tokenize(command))
    if not targets:
        return
    for target in targets:
        check_merge(target, cwd)
    allow()


def check_merge(target: MergeTarget, cwd: str | None) -> None:
    """Deny unless this merge is a squash of an open PR, green and approved at its head."""
    if target.refusal:
        deny(target.refusal)
    pr = target.pr
    if not pr:
        deny("name the PR number explicitly (e.g. `gh pr merge 12 --squash`) so the "
             "gate can check its review state.")
    if not is_squash(target):
        deny("merges are squash merges; pass --squash.")

    repo = target.repo or resolve_repo(cwd)

    state = gh_json(["pr", "view", pr, "-R", repo, "--json", "state,isDraft,headRefOid"],
                    cwd, f"PR #{pr}")
    if state.get("state") != "OPEN":
        deny(f"PR #{pr} is {str(state.get('state')).lower()}, not open.")
    if state.get("isDraft"):
        deny(f"PR #{pr} is a draft.")
    head = state.get("headRefOid") or ""
    if not head:
        deny(f"could not read the head commit of PR #{pr}.")

    green, why = checks_are_green(pr, repo, cwd)
    if not green:
        deny(f"{why}. {FLOW_REMINDER}")

    timestamp, approved, sha = latest_verdict(pr, repo, cwd)
    if not timestamp:
        deny(f"PR #{pr} has no review verdict. {FLOW_REMINDER}")
    if not approved:
        deny(f"the latest review verdict on PR #{pr} requests changes. "
             f"Run /kp-fix-pr {pr}, then have it re-reviewed.")
    if not sha:
        deny(f"the approval on PR #{pr} does not name a full 40-character commit SHA, "
             f"so it cannot be pinned to the head ({head[:12]}). Re-review the current "
             f"revision.")
    if sha != head:
        deny(f"the approval on PR #{pr} names {sha[:12]}, but the head is {head[:12]}. "
             f"Re-review the current revision.")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 -- an unexpected fault must not open the gate.
        deny(f"the gate itself failed ({type(error).__name__}: {error}).")
