#!/usr/bin/env bash
# Drives run-verify.sh over a quiet pass, a failing command's tail (default, --tail 5 and a
# log shorter than the tail), a timeout that must leave no child behind, and the
# bad-argument cases that must exit 2 without running anything. Offline — no GitHub — so
# this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/run-verify.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# Prints the run-verify.sh output a failing command of <total> numbered lines must
# produce with tail <k>, after the result line.
expected_tail() { # total k
  local start=$(($1 - $2 + 1))
  echo "--- last $2 of $1 lines ---"
  seq -f 'line %g' "$start" "$1"
}

# pass-quiet: 500 lines, exit 0 → exactly one output line, all 500 lines in the log.
log="$work/sub/pass.log"
out=$("$script" --log "$log" -- bash -c 'seq -f "line %g" 1 500')
status=$?
echo "== pass-quiet -> exit $status: $out"
if [ "$status" -eq 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
  && [[ $out == "result=pass exit=0 seconds="*" lines=500 log=$log" ]] \
  && [ "$(cat "$log")" = "$(seq -f 'line %g' 1 500)" ]; then
  check pass-quiet ok
else
  check pass-quiet MISMATCH
fi

# A failing command of <total> numbered lines, exit 3; compares everything after the
# result line byte for byte with the expected tail.
expect_tail() { # label total k [run-verify options…]
  local label=$1 total=$2 k=$3 out status
  shift 3
  out=$("$script" --log "$work/$label.log" "$@" -- \
    bash -c "seq -f 'line %g' 1 $total; exit 3"; printf x)
  status=$?
  out=${out%x}
  echo "== $label -> exit $status: $(printf '%s' "$out" | head -1)"
  if [ "$status" -eq 0 ] \
    && [[ $(printf '%s' "$out" | head -1) == "result=fail exit=3 seconds="*" lines=$total log=$work/$label.log" ]] \
    && [ "$(printf '%s' "$out" | tail -n +2)" = "$(expected_tail "$total" "$k")" ] \
    && [ "${out: -1}" = $'\n' ]; then
    check "$label" ok
  else
    check "$label" MISMATCH
  fi
}

expect_tail fail-tail 200 80
expect_tail tail-option 200 5 --tail 5
expect_tail short-log 3 3

# timeout: the command is stopped, reported as timeout, and no sleep child survives.
out=$("$script" --log "$work/timeout.log" --timeout-sec 1 -- sleep 31.7)
status=$?
sleep 2
survivors=$(pgrep -f 'sleep 31.7' || true)
echo "== timeout -> exit $status: $out${survivors:+ | survivors: $survivors}"
if [ "$status" -eq 0 ] && [[ $out == "result=timeout exit=124 seconds="*" lines=0 log=$work/timeout.log"$'\n'"--- last 0 of 0 lines ---" ]] \
  && [ -z "$survivors" ]; then
  check timeout ok
else
  pkill -f 'sleep 31.7' 2>/dev/null
  check timeout MISMATCH
fi

# usage: bad arguments exit 2, print nothing on stdout and never run the command.
expect_usage() { # label args…
  local label=$1 out err status marker="$work/ran-$1"
  shift
  out=$("$script" "$@" touch "$marker" 2>/dev/null)
  status=$?
  err=$("$script" "$@" touch "$marker" 2>&1 >/dev/null)
  echo "== $label -> exit $status${err:+ | stderr: ${err%%$'\n'*}}"
  if [ "$status" -eq 2 ] && [ -z "$out" ] && [ ! -e "$marker" ] && [[ $err == *usage:* ]]; then
    check "$label" ok
  else
    check "$label" MISMATCH
  fi
}

expect_usage usage-no-log --
expect_usage usage-no-separator --log "$work/u.log"
expect_usage usage-unknown-option --log "$work/u.log" --bogus 1 --
expect_usage usage-non-integer --log "$work/u.log" --tail five --
expect_usage usage-timeout-541 --log "$work/u.log" --timeout-sec 541 --
expect_usage usage-tail-0 --log "$work/u.log" --tail 0 --

# No command after --: expect_usage always appends one, so this case is checked here.
out=$("$script" --log "$work/u.log" -- 2>/dev/null)
status=$?
echo "== usage-no-command -> exit $status"
if [ "$status" -eq 2 ] && [ -z "$out" ] && [ ! -e "$work/u.log" ]; then
  check usage-no-command ok
else
  check usage-no-command MISMATCH
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all run-verify checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
