#!/usr/bin/env bash
# Drives model-label.sh over the five effort suffixes, a plain alias, a full model name
# with and without a suffix, the `model:` prefix, and the three bad-argument cases (an
# empty argument, two arguments, and a value whose model part is empty). Offline — no
# GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/model-label.sh"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

expect_split() { # label tier expected-line
  local out status
  out=$("$script" "$2" 2>/dev/null)
  status=$?
  echo "== $1: model-label.sh '$2' -> exit $status: $out"
  if [ "$status" -eq 0 ] && [ "$out" = "$3" ]; then check "$1" ok; else check "$1" MISMATCH; fi
}

expect_usage() { # label args…
  local label=$1 out err status
  shift
  out=$("$script" "$@" 2>/dev/null)
  status=$?
  err=$("$script" "$@" 2>&1 >/dev/null)
  echo "== $label -> exit $status${err:+ | stderr: $err}"
  if [ "$status" -eq 2 ] && [ -z "$out" ] && [[ $err == usage:* ]]; then
    check "$label" ok
  else
    check "$label" MISMATCH
  fi
}

expect_split suffix-low opus-low 'model=opus effort=low'
expect_split suffix-medium opus-medium 'model=opus effort=medium'
expect_split suffix-high opus-high 'model=opus effort=high'
expect_split suffix-xhigh opus-xhigh 'model=opus effort=xhigh'
expect_split suffix-max opus-max 'model=opus effort=max'
expect_split plain-alias sonnet 'model=sonnet effort='
expect_split full-name claude-opus-5-5 'model=claude-opus-5-5 effort='
expect_split full-name-suffix claude-opus-5-5-xhigh 'model=claude-opus-5-5 effort=xhigh'
expect_split label-prefix model:haiku-low 'model=haiku effort=low'
expect_split label-prefix-plain model:opus 'model=opus effort='

expect_usage empty-argument ''
expect_usage two-arguments opus high
expect_usage empty-model -high
expect_usage empty-model-prefixed model:-high

echo
if [ "$failures" -eq 0 ]; then
  echo "all model-label checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
