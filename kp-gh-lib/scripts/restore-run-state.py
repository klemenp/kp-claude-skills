#!/usr/bin/env python3
"""SessionStart(compact) hook: re-inject a headless run's key facts after compaction.

Prints kp-gh-lib/state/run-<session_id>.md and the recorded worktree's live HEAD so a
compacted run keeps its place. Always exits 0; with nothing to restore it prints nothing.
No network calls.
"""
from __future__ import annotations

import json
import pathlib
import re
import subprocess
import sys

STATE_DIR = pathlib.Path(__file__).resolve().parents[1] / "state"
HEADER = "Run state restored after compaction — continue from here:"
GIT_TIMEOUT_SECONDS = 10
# The session id becomes part of a path, so anything but a UUID-shaped token is refused.
SESSION_ID = re.compile(r"[A-Za-z0-9-]+")


def recorded_worktree(state: str) -> str | None:
    for line in state.splitlines():
        if line.startswith("worktree:"):
            return line[len("worktree:"):].strip() or None
    return None


def live_head(worktree: str) -> str | None:
    if not pathlib.Path(worktree).is_dir():
        return None
    try:
        result = subprocess.run(
            ["git", "-C", worktree, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=GIT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    if not isinstance(session_id, str) or not SESSION_ID.fullmatch(session_id):
        return

    try:
        state = (STATE_DIR / f"run-{session_id}.md").read_text(encoding="utf-8")
    except (OSError, ValueError):
        return

    print(HEADER)
    print(state.rstrip("\n"))
    worktree = recorded_worktree(state)
    head = live_head(worktree) if worktree else None
    if head:
        print(f"head: {head}")


if __name__ == "__main__":
    main()
