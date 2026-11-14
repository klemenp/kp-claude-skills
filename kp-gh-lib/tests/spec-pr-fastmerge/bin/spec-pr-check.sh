#!/usr/bin/env bash
# spec-pr-check.sh stub for the spec-pr-fastmerge fixtures: logs its --decision to
# check.log, then answers from the case's check-answers.tsv (no row → ok).
set -uo pipefail
decision=""
while [ $# -gt 0 ]; do
  if [ "$1" = --decision ]; then decision="$2"; fi
  shift
done
echo "$decision" >> "$SPEC_PR_FASTMERGE_OUT/check.log"

answers="$SPEC_PR_FASTMERGE_CASE/check-answers.tsv"
row=""
[ -f "$answers" ] && row="$(awk -F'\t' -v d="$decision" '$1 == d' "$answers")"
if [ -z "$row" ]; then
  echo ok
  exit 0
fi
code="$(printf '%s\n' "$row" | cut -f2)"
message="$(printf '%s\n' "$row" | cut -f3)"
if [ "$code" -eq 1 ]; then
  echo "$message"
else
  echo "$message" >&2
fi
exit "$code"
