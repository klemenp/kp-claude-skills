#!/usr/bin/env bash
# Turn a decomposed coding item into its epic (kp-decompose-gh-task §7): relabel it
# `type:epic`, drop `type:coding` and every `model:*` label (NOTES.md § *Model-tier
# rubric*: epics carry none), create `type:epic` when the repo lacks it, and prefix the
# title `Sub-Epic: ` once, keeping a leading `[<CODE>]` first. The skill used to describe
# these edits in prose; this is the one place they are applied.
#
# Usage: epic-convert.sh <owner/repo> <n>
#
# Reads the issue once over REST (`gh api repos/<owner/repo>/issues/<n>`; no GraphQL, no
# Projects call). A pull request, or an issue carrying neither `type:coding` nor
# `type:epic`, is refused. Otherwise each field converges on its own, so a resumed or
# half-converted run finishes the job without stacking anything:
#   labels  the current labels minus `type:coding` and every `model:*`, plus `type:epic`;
#   title   unchanged when it already contains `Sub-Epic: `; else `[<CODE>] <rest>` becomes
#           `[<CODE>] Sub-Epic: <rest>`; else `Sub-Epic: <title>`.
# Nothing to change → no further call. Otherwise `ensure-labels.sh --repo <owner/repo>
# type:epic` runs first when `type:epic` is not yet on the issue, then exactly one
# `gh issue edit` carries every `--remove-label`, the `--add-label` and the `--title`.
#
# Prints one JSON object on stdout:
#   {"changed": true|false, "title": "<final title>", "labels": [<final names, sorted>]}
#
# ensure-labels.sh is found through KP_GH_LIB_BIN, default this script's own directory.
#
# Exit: 0 converted or already converted · 1 a gh or ensure-labels.sh call failed (stderr
# names it, no JSON) · 2 bad arguments, nothing called · 3 not a coding item or epic (stderr
# names its `type:*` labels, or `pull request`), nothing written.
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

# Issue text never reaches a shell: Python runs every gh call as an argument vector.
exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/epic_convert.py "$@" </dev/null
