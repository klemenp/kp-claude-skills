#!/usr/bin/env bash
# The whole-milestone gate for one issue: may it launch, or is an earlier milestone not
# done yet? Finds the issue's milestone with milestone-of.sh, then walks the earlier
# milestone epics' sub-issue trees in ascending milestone order and stops at the first
# milestone that is not done. Never scans the board.
#
# A milestone is done when every non-epic item under it is closed, no audit-close
# decision for it is open, and either a `type:audit` issue carrying
# `audit-unit: milestone:M<k>` was created after the last of those items closed, or a
# closed `type:decision` carrying `audit-close: M<k>` exists (NOTES.md § *Milestone
# sequencing* → *Audit gate*).
#
# Usage: milestone-gate.sh --project <owner/number> <owner/repo> <issue>
#        milestone-gate.sh --project <owner/number> --current
#        milestone-gate.sh --project <owner/number> --milestone M<k>
#
# Only the project's linked repositories count: epics, audits and audit-close decisions
# in any other repo are ignored, so two boards with their own M0…Mn never gate each other.
#
# The gate form prints one JSON object on stdout:
#   {"issue": "owner/repo#n", "milestone": "M<n>" | null, "epic": "owner/repo#e" | null,
#    "waitingOn": "M<k>" | null, "openEarlier": ["owner/repo#m", …],
#    "auditNeeded": "M<k>" | null, "auditRound": <n>,
#    "lastAuditFiled": ["owner/repo#m", …] | null,
#    "crossEdges": [{"issue": "owner/repo#m", "milestone": "M<k>",
#                    "blockedBy": "owner/repo#b", "blockerMilestone": "M<j>"}, …]}
# waitingOn is null when the gate is open: the issue has no milestone, or every earlier
# milestone is done. openEarlier lists the open non-epic items of the waitingOn
# milestone. auditNeeded is the waitingOn milestone when all its items are closed but it
# has no current audit and no audit-close decision. auditRound counts the waitingOn
# milestone's audit issues, and lastAuditFiled is the newest one's `audit-filed:` list
# ([] for `none`, null with no audit issue); 0 and null when the gate is open.
# crossEdges lists each `blocked-by:` edge, from the issue or an openEarlier item, onto
# an open issue of a later milestone than the dependent's own — an edge that stalls both
# milestones under the gate. A pull-request blocker has no milestone, so it is never a
# cross edge.
#
# The --current form looks up the project's current milestone instead, and prints:
#   {"project": "<owner/number>", "milestone": "M<k>" | null, "epics": ["owner/repo#e", …]}
# milestone is the earliest milestone that is not done, by the same test the gate applies,
# or the latest one when every milestone is done; null, with epics [], when the project's
# linked repos hold no milestone epic (the project does not use milestones). epics lists
# every milestone epic carrying that id, by owner/repo then number.
#
# The --milestone form decides one named milestone, and prints:
#   {"milestone": "M<k>", "done": true | false, "repos": ["owner/repo", …]}
# done is the same test the gate applies. repos, sorted, is every linked repo holding one
# of the milestone's epics, an item under them, one of its audits or an audit-close
# decision for it — where milestone-tag.sh tags a done milestone. An M<k> no epic carries
# prints done false with repos [].
#
# Exit: 0 decided · 1 a lookup failed · 2 bad arguments.
set -euo pipefail

usage() {
  echo "usage: milestone-gate.sh --project <owner/number> <owner/repo> <issue>" >&2
  echo "       milestone-gate.sh --project <owner/number> --current" >&2
  echo "       milestone-gate.sh --project <owner/number> --milestone M<k>" >&2
  exit 2
}

[ $# -eq 3 ] || [ $# -eq 4 ] || usage
[ "$1" = --project ] || usage
[[ $2 =~ ^[^/[:space:]]+/[0-9]+$ ]] || usage
project=$2
shift 2
# The --milestone form and the gate form both leave two arguments, so the flag decides.
if [ "$1" = --milestone ]; then
  [ $# -eq 2 ] || usage
  [[ $2 =~ ^M[0-9]+$ ]] || usage
elif [ $# -eq 1 ]; then
  [ "$1" = --current ] || usage
else
  [[ $1 =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage
  [[ $2 =~ ^[0-9]+$ ]] || usage
fi

# Issue bodies never reach a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/milestone_gate.py "$(dirname "$0")/milestone-of.sh" "$project" "$@" </dev/null
