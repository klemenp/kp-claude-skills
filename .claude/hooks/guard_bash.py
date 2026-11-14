#!/usr/bin/env python3
"""PreToolUse guard: deny destructive commands, protected-path writes, and commits
that would skip the board -> worktree -> PR flow.

Reads the hook event JSON on stdin and emits a PreToolUse permission decision on stdout.
Silence (empty output) means "no opinion" — the normal permission flow continues.

A Bash command is judged by its words, not its text: it is split into segments at shell
operators and newlines, and each segment's command word and arguments are checked. So is
every command a segment hands to another shell (`bash -c`, `eval`, a heredoc fed to a
shell). Text that only mentions a guarded command — a quoted string, a heredoc written
to a file — is not a command and is not checked.

This is a same-session backstop only: it applies when a Claude session runs with this
repo as its project directory. The load-bearing enforcement is .githooks/, which applies
to every commit regardless of who or what makes it.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

from shell_words import (MAX_NESTING_DEPTH, command_word_index, nested_commands,
                         segments_of, strip_heredocs, tokenize)

# Paths this repo must never have rewritten by an agent.
PROTECTED = [
    (r"\.claude/settings\.local\.json", "personal machine-local config"),
    (r"(^|[\s/='\"])\.env", "environment/credential file"),
    (r"\.config/kp-msg-me/config", "Telegram credentials"),
]

PROTECTED_BRANCH = "main"
# git's global options may sit between `git` and the subcommand (`git -C <dir> commit`),
# so finding the subcommand has to step over them or the check is trivially bypassed.
GIT_GLOBAL_OPTIONS_WITH_VALUE = frozenset({"-C", "-c"})
GIT_GLOBAL_OPTIONS = re.compile(r"^(--git-dir=.*|--work-tree=.*|--no-pager|-P)$")
HOOKS_PATH_CONFIG = re.compile(r"^core\.hookspath=", re.IGNORECASE)
# Commands that would write history or the remote, and so must not run on main.
HISTORY_SUBCOMMANDS = frozenset({"commit", "push", "merge", "rebase", "cherry-pick"})
REDIRECTIONS = frozenset({">", ">>"})
PATH_WRITING_COMMANDS = frozenset({"tee", "rm", "mv"})

RECURSIVE_FORCE_DELETE = "recursive force delete"
FORCE_PUSH = "force push"
HARD_RESET = "hard reset discards uncommitted work"
GIT_CLEAN = "git clean deletes untracked files"
CHECKOUT_ALL = "checkout -- . discards all local changes"
# The escape hatch stays open in the operator's own shell, where PreToolUse hooks do not
# run -- but an agent must not decide to skip .githooks/ on its own.
NO_VERIFY = "--no-verify skips the board -> worktree -> PR hooks"

FLOW_REMINDER = (
    "Skill changes go through the board, a worktree and a PR: /kp-create-gh-item to "
    "file the item, /kp-do-gh-task <n> to build it, then git pull once the PR merges."
)


def deny(reason: str) -> None:
    json.dump({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, sys.stdout)
    sys.exit(0)


def deny_destructive(why: str) -> None:
    deny(f"Blocked by repo hook: {why}. Run it yourself if you really mean it.")


def expand_path(raw: str, base: str) -> str:
    path = os.path.expanduser(raw)
    return path if os.path.isabs(path) else os.path.join(base, path)


def current_branch(cwd: str) -> str:
    try:
        result = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                                capture_output=True, text=True, timeout=5, cwd=cwd)
    except (OSError, subprocess.SubprocessError):
        return ""  # Unresolvable target: fail open, .githooks/ is the load-bearing layer.
    return result.stdout.strip() if result.returncode == 0 else ""


def short_flags(arguments: list[str]) -> set[str]:
    """The letters of every short option or bundle (`-rf` gives r and f) before `--`."""
    letters: set[str] = set()
    for word in arguments:
        if word == "--":
            break
        if word.startswith("-") and not word.startswith("--"):
            letters.update(word[1:])
    return letters


def has_option(arguments: list[str], option: str) -> bool:
    return any(word == option or word.startswith(option + "=") for word in arguments)


def protected_reason(word: str) -> str | None:
    for pattern, why in PROTECTED:
        if re.search(pattern, word):
            return why
    return None


def split_git(arguments: list[str]) -> tuple[list[str], str | None, list[str], str | None]:
    """A git command's `-c` settings, subcommand, the words after it, and its `-C` dir."""
    settings: list[str] = []
    directory = None
    index = 0
    while index < len(arguments):
        word = arguments[index]
        if word in GIT_GLOBAL_OPTIONS_WITH_VALUE and index + 1 < len(arguments):
            if word == "-c":
                settings.append(arguments[index + 1])
            else:
                directory = arguments[index + 1]
            index += 2
        elif GIT_GLOBAL_OPTIONS.match(word):
            index += 1
        else:
            return settings, word, arguments[index + 1:], directory
    return settings, None, [], directory


def check_git(arguments: list[str], directory: str) -> None:
    settings, subcommand, rest, git_directory = split_git(arguments)
    if "--no-verify" in arguments or any(HOOKS_PATH_CONFIG.match(s) for s in settings) \
            or (subcommand == "commit" and "n" in short_flags(rest)):
        deny_destructive(NO_VERIFY)
    if subcommand == "push":
        forced = has_option(rest, "--force") or "f" in short_flags(rest) \
            or any(word.startswith("+") for word in rest)
        if forced:
            deny_destructive(FORCE_PUSH)
    if subcommand == "reset" and "--hard" in rest:
        deny_destructive(HARD_RESET)
    if subcommand == "clean" and ("--force" in rest or "f" in short_flags(rest)):
        deny_destructive(GIT_CLEAN)
    if subcommand == "checkout" and "--" in rest and "." in rest[rest.index("--") + 1:]:
        deny_destructive(CHECKOUT_ALL)
    if subcommand in HISTORY_SUBCOMMANDS:
        if git_directory is not None:
            directory = expand_path(git_directory, directory)
        if current_branch(directory) == PROTECTED_BRANCH:
            deny(f"Blocked by repo hook: refusing to rewrite history on "
                 f"'{PROTECTED_BRANCH}', which is the live skills directory. {FLOW_REMINDER}")


def deny_protected_writes(written: list[str]) -> None:
    for word in written:
        why = protected_reason(word)
        if why:
            deny(f"Blocked by repo hook: that command writes a protected path ({why}).")


def written_by(name: str, arguments: list[str]) -> list[str]:
    """The arguments a path-writing command may write: all of them, conservatively."""
    edits_in_place = name == "sed" and any(word.startswith("-i") for word in arguments)
    return arguments if name in PATH_WRITING_COMMANDS or edits_in_place else []


def check_command(command: str, directory: str, depth: int = 0) -> str:
    """Check every segment of a command; return the directory it leaves the shell in."""
    stripped, shell_bodies = strip_heredocs(command)
    tokens = tokenize(stripped)
    # A redirection operator is a token of its own, so its target is the token after it.
    deny_protected_writes([tokens[position + 1] for position in range(len(tokens) - 1)
                           if tokens[position] in REDIRECTIONS])
    for segment in segments_of(tokens):
        index = command_word_index(segment)
        if index is None:
            continue
        name = os.path.basename(segment[index])
        arguments = segment[index + 1:]
        if name == "cd" and arguments:
            directory = expand_path(arguments[0], directory)
        elif name == "rm":
            flags = short_flags(arguments)
            recursive = bool(flags & {"r", "R"}) or "--recursive" in arguments
            force = "f" in flags or "--force" in arguments
            if recursive and force:
                deny_destructive(RECURSIVE_FORCE_DELETE)
        elif name == "git":
            check_git(arguments, directory)
        deny_protected_writes(written_by(name, arguments))
        if depth < MAX_NESTING_DEPTH:
            for nested in nested_commands(segment):
                check_command(nested, directory, depth + 1)
    if depth < MAX_NESTING_DEPTH:
        for body in shell_bodies:
            check_command(body, directory, depth + 1)
    return directory


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return  # Never block on a malformed event.

    tool_input = event.get("tool_input") or {}
    command = tool_input.get("command") or ""
    file_path = tool_input.get("file_path") or ""

    if file_path:
        why = protected_reason(file_path)
        if why:
            deny(f"Blocked by repo hook: {file_path} is protected ({why}).")
    if command:
        check_command(command, event.get("cwd") or os.getcwd())


if __name__ == "__main__":
    main()
