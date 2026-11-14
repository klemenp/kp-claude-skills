#!/usr/bin/env bash
# Drive one PR to merged: the review ⇄ fix loop `kp-do-gh-pr-loop` § *Loop policy*
# defines, run as a script so the calling session spends a handful of turns on it
# instead of one per child launch, wait and GitHub read.
#
# Usage:
#   pr-loop.sh start <owner/repo> <pr> --project <owner/number> [--model <tier>]
#              [--stall-limit <k>] [--max-cycles <k>] [--log-dir <dir>] [--dry-run]
#   pr-loop.sh --wait <state-file> [--wait-max-sec <s>]
#
# The `run-child.sh` shape. `start` runs from the PR's primary checkout: it runs the
# preamble, reads the PR and its linked item, writes the loop state to
# <log-dir>/pr-loop-<repo-name>-<pr>.state.json, launches the first review child and
# prints `status: running state=<file>`. Each `--wait` polls the running child; when it
# ends, it classifies the outcome from GitHub state (never from the child's stdout),
# updates the state file and launches the next phase — review, fix, or the one
# `/kp-do-gh-pr-loop-escalate` child that raises the human-gated item — and returns
# `status: running state=<file>` within <s> seconds (default 480), so the caller simply
# calls it again. Every path lives in the state file, so no shell variable has to
# survive between the caller's `Bash` calls.
#
# A review that ends with no verdict (its own CI wait ran out) counts a stall and a
# cycle. When checks are still pending, the next review is not launched at once: the
# loop enters the `ci-wait` phase, which launches no child and polls the PR's checks
# every 60 s for up to 60 minutes, then launches that review once nothing is pending (or
# escalates `ci-not-settling` at the cap). Waiting here costs no tokens; a new reviewer
# waiting on the same checks would redo every pass first.
#
# The tier (`--model`, else the linked item's `model:*` label value, else `opus`) is split
# once by `model-label.sh` into a model and an effort (`opus-medium` → opus, medium). Every
# child runs on that model; fix and escalate run at the tier's effort, and the review at
# `high` when that effort is `low` or `medium`. A tier with no effort passes no `--effort`.
# After the first stalled fix cycle the loop continues past, every later review and fix
# runs at the boost effort — `xhigh`, or `max` when the tier is already `xhigh` or `max` —
# for the rest of the loop; escalate is never boosted, and a no-verdict round never boosts.
#
# A finished loop prints its cycle table and one terminal line:
#   outcome=<o> [reason='<r>'] [reset='<t>'] state=<file>
# A PR merged on entry runs the close-out only and writes no state file. The close-out
# closes the linked issue itself: the `Closes #N` keyword closes it only on a
# default-branch merge, and a milestone item's PR merges into `release/M<k>`.
#
# Siblings (`preamble.sh`, `run-child.sh`, `model-label.sh`, `pr-verdict-state.sh`,
# `item-id.sh`, `set-status.sh`, `unblock-dependents.sh`) are found through
# KP_GH_LIB_BIN, default this script's directory, so offline tests can shadow them; `gh`
# comes from PATH.
#
# Exit: 0 merged (close-out done) or a --dry-run plan · 3 still running · 4 parked ·
# 5 capacity-limit · 1 a failed lookup · 2 bad arguments.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$here}"

# PR bodies, findings and fix summaries never reach a shell: Python runs every call as an
# argument vector and handles them only as strings.
exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/pr_loop.py "$@" </dev/null
