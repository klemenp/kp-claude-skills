#!/usr/bin/env bash
# shellcheck source=/dev/null
. "$(dirname "$0")/fake-lib.sh"
record "branch-cleanup $*"
echo "branch=$1 result=deleted"
