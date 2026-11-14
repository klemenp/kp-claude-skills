#!/usr/bin/env bash
# Make sure a repo has the labels an item creator is about to apply, in the family's
# colors. The item-creating skills used to hand-run `gh label create … --force` blocks,
# each carrying its own copy of the colors; this script's built-in map is now the one list.
#
# Usage: ensure-labels.sh --repo <owner/repo> <label>[=<hex>]…
#
# Arguments are checked before any GitHub call: --repo and at least one label are given,
# every `=<hex>` suffix is exactly six hex digits (no `#`), and every label without a
# suffix has a built-in color. Built-in colors:
#   type:coding 1d76db · type:epic 5319e7 · type:decision d93f0b · type:question fbca04 ·
#   type:research 0e8a16 · type:conflict b60205 · type:audit 0052CC ·
#   needs-contract D93F0B · model:opus B60205 · model:sonnet FBCA04 · model:haiku 0E8A16 ·
#   any repo:* 6E7781
# A model tier label `model:<family>-<effort>` — <family> one of opus, sonnet, haiku and
# <effort> one of low, medium, high, xhigh, max, both matched case-insensitively — takes
# the color of `model:<family>`; any other unknown `model:*` label needs a suffix.
# A suffix overrides the map.
#
# Reads the repo's labels once over REST (`gh api repos/<owner/repo>/labels --paginate`;
# no GraphQL, no Projects call), then for each argument, in order — names matched
# case-insensitively, as GitHub does:
#   absent         → `gh label create <label> -R <owner/repo> --color <hex> --force`
#   other color    → the same call (colors compared case-insensitively)
#   same color     → no call
#
# Prints one line per argument, in order:
#   created <label> · updated <label> · exists <label>
#
# Exit: 0 every label ensured · 1 a gh call failed (stderr names the label; the lines for
# the labels before it are already printed) · 2 bad arguments, nothing called.
set -euo pipefail

# Label names never reach a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/ensure_labels.py "$@" </dev/null
