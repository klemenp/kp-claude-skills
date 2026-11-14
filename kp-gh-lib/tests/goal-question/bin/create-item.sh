#!/usr/bin/env bash
# Fake create-item.sh for the goal-question fixtures: creates issue 42 in
# $FAKE_STATE/issue.json with the title, labels and __ISSUE__-substituted body it is given.
set -euo pipefail

title="" body="" labels=()
while [ $# -gt 0 ]; do
  case "$1" in
    --title) title=$2; shift 2 ;;
    --body-file) body=$2; shift 2 ;;
    --label) labels+=("$2"); shift 2 ;;
    --assign-owner) shift ;;
    *) shift 2 ;;
  esac
done
sed 's/__ISSUE__/42/g' "$body" |
  jq -Rs --arg title "$title" '{title: $title, body: ., labels: $ARGS.positional, comments: []}' \
    --args "${labels[@]}" > "$FAKE_STATE/issue.json"
echo '{"number":42,"url":"https://github.com/example-org/demo/issues/42","skipped":[]}'
