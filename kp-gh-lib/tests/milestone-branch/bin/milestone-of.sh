#!/usr/bin/env bash
# A stand-in for milestone-of.sh <repo> <n>: the scenario's `milestone` (M<k> or null),
# or a failure when `fail` holds `milestone-of`.
set -euo pipefail
if jq -e '(.fail // []) | index("milestone-of")' "$FAKE_GH_SCENARIO" >/dev/null; then
  echo "milestone-of.sh: cannot look up $1#$2: HTTP 502" >&2
  exit 1
fi
jq -c --arg issue "$1#$2" --arg root "$1" '
  .milestone as $milestone
  | {issue: $issue, state: "OPEN", milestone: $milestone,
     rank: (if $milestone then ($milestone[1:] | tonumber) else null end),
     epic: null, root: $root}' "$FAKE_GH_SCENARIO"
