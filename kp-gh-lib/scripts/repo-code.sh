#!/usr/bin/env bash
# Resolve the `[<REPO-CODE>] ` title prefix and the `repo:<name>` label an item creator
# puts on an issue it files in <owner/repo>. Implements `kp-gh-lib/NOTES.md`
# § *Repo identification*; the creators used to follow that lookup order in prose.
#
# Usage: repo-code.sh <owner/repo> [--config <path>]
#
# The code is resolved in this order, first hit wins:
#   1. config — `repoCodes["<owner/repo>"]` in --config (default `.claude/spec-sync.json`
#      under the current directory). A missing file skips this step; an unparseable one,
#      or a `repoCodes` that is not an object, is exit 2.
#   2. in use — one REST call,
#      `gh api 'repos/<owner/repo>/issues?state=all&labels=repo:<name>&per_page=100'`;
#      pull requests are dropped, and the code is taken from each title matching
#      `^\[([A-Z0-9][A-Z0-9-]*)\] `. The most frequent code wins; a tie goes to the code
#      whose own highest issue number is largest. Never a GraphQL or Projects call:
#      the board is not read.
#   3. derived — the repo name, its first hyphen-separated segment dropped when it has
#      three or more segments, upper-cased (`my-org/shop-data-api` → `DATA-API`,
#      `example-org/shop-tools` → `SHOP-TOOLS`).
#
# Prints one JSON object:
#   {"code": "<CODE>", "label": "repo:<name>"}
# <name> is the repo name without its owner.
#
# Exit: 0 printed · 1 a gh call failed (its stderr passed through) · 2 bad arguments.
set -euo pipefail

# Issue titles never reach a shell: Python runs the gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/repo_code.py "$@" </dev/null
