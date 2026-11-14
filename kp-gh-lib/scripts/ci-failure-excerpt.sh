#!/usr/bin/env bash
# Print each failing CI check of a PR with its failed step and the last lines of its
# failed-step log, so `kp-fix-pr` and `kp-review-gh-pr` judge a red check without loading
# a whole log.
#
# Usage: ci-failure-excerpt.sh <owner/repo> <pr> [--lines <n>]
#
# Reads the checks once (`gh pr checks --json name,bucket,link,workflow`); a check is
# failing when its bucket is `fail`. For each failing check whose link is a GitHub Actions
# job (`https://github.com/<owner>/<repo>/actions/runs/<run-id>/job/<job-id>…`) it reads
# `gh run view <run-id> --job <job-id> --log-failed` and prints, in the order the checks
# were listed, one block per failing check, blocks separated by one empty line:
#
#   check: <name>
#   url: <link>
#   step: <step of the last log line that has one, or `unknown`>
#   --- last <k> of <total> failed-step lines ---
#   <the last k lines, each reduced to its text>
#
# where k = min(--lines, total), --lines defaulting to 60. A failing check whose link is
# not an Actions job, or whose log call fails, times out or returns no lines, prints
# `check:`, `url:` and `log: unavailable (<reason>)` instead. No failing check prints
# `no failing checks`.
#
# Each gh call is bounded to 60 s (`KP_CI_EXCERPT_TIMEOUT_SECONDS` overrides it).
#
# Exit: 0 printed (including no failing checks and unavailable logs) · 1 the checks read
# failed (empty or unparseable output — `gh pr checks` exits 8 while checks are pending
# and 1 when some failed, both with valid JSON) · 2 bad arguments.
set -euo pipefail

python3 "$(dirname "${BASH_SOURCE[0]}")"/py/ci_failure_excerpt.py "$@" </dev/null
