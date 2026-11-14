#!/usr/bin/env bash
# A stand-in for milestone-gate.sh --milestone: prints the scenario's `gate` object, or
# exits 1 when the scenario sets `gateFails`.
set -euo pipefail
[ "$3" = --milestone ] || { echo "stub milestone-gate.sh: unexpected $*" >&2; exit 2; }
if [ "$(jq -r '.gateFails // false' "$FAKE_GH_SCENARIO")" = true ]; then
  echo "milestone-gate.sh: project o/1 not found" >&2
  exit 1
fi
jq -c .gate "$FAKE_GH_SCENARIO"
