#!/usr/bin/env python3
"""Stop gate: refuse to finish while the skill contract is broken."""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR = REPO / ".github" / "scripts" / "validate_skills.py"


def main() -> None:
    try:
        json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return

    if not VALIDATOR.is_file():
        return

    result = subprocess.run(
        [sys.executable, str(VALIDATOR)],
        capture_output=True, text=True, cwd=REPO, timeout=60,
    )
    if result.returncode != 0:
        json.dump({
            "decision": "block",
            "reason": "validate_skills.py fails — fix the skill contract before "
                      f"finishing:\n\n{result.stdout.strip()}\n{result.stderr.strip()}",
        }, sys.stdout)


if __name__ == "__main__":
    main()
