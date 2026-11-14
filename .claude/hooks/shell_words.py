"""Shell command splitting shared by the PreToolUse guards.

A command string is split into tokens, the tokens into segments (the words between shell
operators and unquoted newlines), and the commands a segment hands to another shell are
found, so a guard judges the commands a Bash call would run, not its raw text.
"""
from __future__ import annotations

import os
import re
import shlex

# shlex splits these off as their own tokens even when unspaced. A token made only of
# SEGMENT_SEPARATOR_CHARS ends a segment; redirections (`<`, `>`) stay inside theirs.
SHELL_PUNCTUATION = ";&|()<>\n"
SEGMENT_SEPARATOR_CHARS = frozenset(";&|()\n")
SHELL_NAMES = frozenset({"bash", "sh", "zsh", "dash"})
# `-c`, and bundles that end in it such as `-lc`.
SHELL_COMMAND_FLAG = re.compile(r"^-[A-Za-z]*c$")
MAX_NESTING_DEPTH = 3


def tokenize(command: str) -> list[str]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=SHELL_PUNCTUATION)
    lexer.whitespace_split = True
    lexer.whitespace = " \t\r"
    # shlex.shlex drops everything after a `#`; a comment must not hide a merge.
    lexer.commenters = ""
    try:
        return list(lexer)
    except ValueError:
        return command.split()


def segments_of(tokens: list[str]) -> list[list[str]]:
    """The runs of tokens between shell operators and unquoted newlines."""
    segments: list[list[str]] = [[]]
    for token in tokens:
        if token and set(token) <= SEGMENT_SEPARATOR_CHARS:
            segments.append([])
        else:
            segments[-1].append(token)
    return [segment for segment in segments if segment]


def nested_commands(segment: list[str]) -> list[str]:
    """Command strings a segment hands to another shell: `bash -c <string>`, `eval <args>`."""
    nested: list[str] = []
    for index, token in enumerate(segment):
        if os.path.basename(token) in SHELL_NAMES:
            for flag_index in range(index + 1, len(segment) - 1):
                if SHELL_COMMAND_FLAG.match(segment[flag_index]):
                    nested.append(segment[flag_index + 1])
                    break
        elif token == "eval":
            nested.extend(segment[index + 1:])
    return nested


WRAPPER_WORDS = frozenset({"sudo", "env", "command", "exec", "time", "nohup", "xargs"})
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
HEREDOC_START = re.compile(r"<<(?P<dash>-?)\s*(?P<quote>['\"]?)(?P<tag>[A-Za-z_][A-Za-z0-9_]*)(?P=quote)")


def command_word_index(segment: list[str]) -> int | None:
    """Position of the word a segment runs, past assignments and wrapper words."""
    after_wrapper = False
    for index, word in enumerate(segment):
        if ASSIGNMENT.match(word):
            continue
        if after_wrapper and word.startswith("-"):
            continue
        if os.path.basename(word) in WRAPPER_WORDS:
            after_wrapper = True
            continue
        return index
    return None


def is_fed_to_a_shell(line_before_heredoc: str) -> bool:
    """Whether the segment holding a `<<` runs a shell, so the body is commands."""
    segments = segments_of(tokenize(line_before_heredoc))
    if not segments:
        return False
    last = segments[-1]
    index = command_word_index(last)
    return index is not None and os.path.basename(last[index]) in SHELL_NAMES


def strip_heredocs(command: str) -> tuple[str, list[str]]:
    """The command without heredoc bodies, and the bodies that were fed to a shell.

    A body runs from the line after `<<TAG` (or `<<-TAG`, tag bare or quoted) to the line
    that is the tag alone. A body written to a file or piped to another program is text,
    not commands, so it is dropped; one fed to a shell is returned to be checked.
    """
    kept: list[str] = []
    shell_bodies: list[str] = []
    lines = command.split("\n")
    position = 0
    while position < len(lines):
        line = lines[position]
        kept.append(line)
        position += 1
        for start in HEREDOC_START.finditer(line):
            tag = start.group("tag")
            body: list[str] = []
            while position < len(lines):
                candidate = lines[position]
                position += 1
                closing = candidate.lstrip("\t") if start.group("dash") else candidate
                if closing == tag:
                    break
                body.append(candidate)
            if is_fed_to_a_shell(line[:start.start()]):
                shell_bodies.append("\n".join(body))
    return "\n".join(kept), shell_bodies
