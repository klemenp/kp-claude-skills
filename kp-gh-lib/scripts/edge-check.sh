#!/usr/bin/env bash
# Decide one proposed `<dependent> blocked-by <blocker>` edge before a skill writes its
# marker, exactly as NOTES.md § *Milestone sequencing* → *Acyclicity* and *Edges stay
# inside one milestone* define it. `blocks:` is the same relation seen from the blocker, so
# a `Y blocks: X` write is checked as `X blocked-by Y`. Writes nothing.
#
# Usage: edge-check.sh --project <owner/number> <dependent> <blocker>
#          [--dependent-epic <owner/repo#e>] [--from-file <json>]
#
# <dependent> is <owner/repo#n>, or `draft:<M<k>|none>` for an item not created yet, whose
# milestone is the one its creator's milestone-place.sh call returned; --dependent-epic,
# for a draft only, names that milestone epic. <blocker> is <owner/repo#m>, an issue or a
# pull request.
#
# Cycle walk: breadth-first from the blocker over its prerequisites — the issues its own
# `blocked-by:` lines name, and every issue in the project's linked repos whose `blocks:`
# line names it (either reference form) or its `spec-ref:` — repeated from each node
# reached, open and closed alike; a pull request ends its branch. Reaching the dependent is
# a `cycle`. A self-edge, and a blocker the dependent names in a `resolves:` line, are a
# `cycle` too. Marker lines count outside the human-only fence and every <details> block.
# The `blocks:` lines come from one find-marker.sh search per repo owner, so a call costs a
# constant number of searches however large the graph is; each node costs one REST read.
#
# Milestones, only when there is no cycle: milestone-of.sh for each real end. Either end
# without one → `ok` (outside the rules); same → `ok`; the blocker's earlier →
# `drop-earlier`; later → `pull-forward`.
#
# Prints one JSON object on stdout:
#   {"verdict": "ok" | "cycle" | "drop-earlier" | "pull-forward",
#    "path": ["owner/repo#n", …], "dependentMilestone": "M<k>" | null,
#    "blockerMilestone": "M<j>" | null, "pullForwardEpic": "owner/repo#e" | null}
# path runs from the blocker to the dependent on `cycle` ([X] for a self-edge, [Y, X] for
# a `resolves:` conflict) and is [] otherwise. The milestones are null on `cycle`, which
# skips the lookup. pullForwardEpic is the dependent's milestone epic on `pull-forward`
# (null for a draft given no --dependent-epic) and null otherwise.
#
# --from-file <json>: `{"issues": {"owner/repo#n": {"type": "issue"|"pr", "state",
#   "milestone": "M2"|null, "epic": "owner/repo#e"|null, "specRef": "<ref>" (optional),
#   "blocks": [...], "blockedBy": [...], "resolves": [...]}}}` replaces every GitHub read
#   (fixtures). Marker values are `#n` (the key's repo) or `owner/repo#n`; a `blocks:`
#   value may also be a spec-ref.
#
# Exit: 0 decided (every verdict) · 1 a lookup failed · 2 bad arguments.
set -euo pipefail

# Issue bodies never reach a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/edge_check.py "$(dirname "$0")" "$@" </dev/null
