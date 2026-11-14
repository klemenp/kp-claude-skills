#!/usr/bin/env bash
# Sweep a project board for the items `kp-do-gh-ready-items` §1 selects and print one line
# per item, so the skill reads a handful of lines instead of the board JSON and every body.
#
# Usage: ready-sweep.sh --project <owner>/<number> [--repo <owner/name>]
#          [--only <#,#,…>] [--label <name>] [--status <name>] [--from-file <json>]
#
# Reads:
#   1. The board, with one narrow paginated GraphQL query (Status, issue number, repo,
#      state, first 10 labels; ~3 points on a 254-item board). A user-login miss
#      (`NOT_FOUND` beside `"user":null`) re-runs once as `organization(login:)`.
#   2. Nothing more for a node that is not an OPEN issue in Status `--status` (default
#      Ready) carrying `type:coding`, `type:decision`, `type:question`, `type:conflict` or
#      `type:research`, or that `--repo` / `--only` filter out. `--only` takes `#n`, `n`,
#      `name#n` or `owner/name#n`; a bare entry matching items in two repos is ambiguous.
#   3. `gh issue view` (1 point) per survivor; `--label` then filters on its full labels.
#   4. The sibling `decision-state.sh` (REST only) per `type:decision` / `type:question`.
#
# Prints, sorted by kind (in this order), then repo, then number:
#   ambiguous <entry> | <repo>, <repo>…
#   item <owner/name>#<n> | <title> | <model alias or `opus (no model label)`>
#        | <blocked-by markers outside the human-only fence, or none> | <mismatch or none>
#   gated <owner/name>#<n> | <title> | <type label> | answered-agent | answered-person
#        | unanswered | check:<one of those three> | - (conflict / research)
#   needs-contract <owner/name>#<n> | <title>
# `check:<fallback>` means human comments follow the latest decision; whether one picks an
# outcome is the caller's judgment, and `<fallback>` is the state if none does.
#
# --from-file <json>: `{"nodes": [<sweep item nodes>], "issues": {"<owner/name>#<n>":
#   <issue view JSON>}, "decisionStates": {"<owner/name>#<n>": <decision-state.sh JSON>}}`
#   stands in for every GitHub read.
#
# Exit: 0 swept (including no lines) · 1 a GitHub call or decision-state.sh failed (stdout
# empty, one stderr line) · 2 bad arguments.
set -euo pipefail

# Issue bodies never reach a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/ready_sweep.py "$(dirname "$0")/decision-state.sh" "$@" </dev/null
