#!/usr/bin/env bash
# Tags a done milestone: a lightweight `milestone/M<k>` tag on `origin`'s default-branch
# HEAD in every repo that holds one of its epics, items, audits or audit-close decisions
# (NOTES.md § *Milestone sequencing* → *Audit gate*, *Milestone tag*). Done and the repo
# set both come from `milestone-gate.sh --milestone`, so the tag can never disagree with
# the gate.
#
# Usage: milestone-tag.sh --project <owner/number> M<k>
#
# Prints one line per outcome on stdout:
#   not-done M<k>                          the milestone is not done; nothing is created
#   tagged <owner/repo> milestone/M<k> <sha>  the tag was created at that HEAD
#   exists <owner/repo> milestone/M<k> <sha>  the tag was already there; it is never moved
#   failed <owner/repo>: <first stderr line>  a lookup or the create failed for that repo
# A failed repo never stops the others, and a re-run tags any repo an earlier run missed.
#
# milestone-gate.sh is found through KP_GH_LIB_BIN, default this script's own directory.
#
# Exit: 0 every repo tagged or existing, or not-done · 1 the gate lookup or a repo
# failed · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: milestone-tag.sh --project <owner/number> M<k>" >&2
  exit 2
}

[ $# -eq 3 ] || usage
[ "$1" = --project ] || usage
[[ $2 =~ ^[^/[:space:]]+/[0-9]+$ ]] || usage
[[ $3 =~ ^M[0-9]+$ ]] || usage

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/milestone_tag.py "$2" "$3" </dev/null
