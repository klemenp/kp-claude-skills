#!/usr/bin/env bash
# A stand-in for file-audit.sh: copies the --body-file to $FAKE_AUDIT_BODY and prints the
# scenario's `audit` (default a new issue #50).
set -euo pipefail
echo "file-audit.sh $*" >>"$FAKE_CALL_LOG"
while [ $# -gt 0 ]; do
  [ "$1" = --body-file ] && cp "$2" "$FAKE_AUDIT_BODY"
  shift
done
jq -c '.audit // {number: 50, url: "https://github.com/o/t/issues/50", reused: false}' \
  "$FAKE_GH_SCENARIO"
