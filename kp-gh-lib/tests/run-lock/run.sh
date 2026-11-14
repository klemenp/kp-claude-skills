#!/usr/bin/env bash
# Drives run-lock.sh through acquire, release and status in a mktemp -d workspace: a free
# key, a live holder (a `sleep 300 &`, killed on exit), a dead holder (a `true &` that has
# been waited on), re-entry, the $CLAUDE_PID default, a malformed lock file, bad arguments
# and an unwritable lock directory. Offline — no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/run-lock.sh"
work="$(mktemp -d)"
sleep 300 &
live_pid=$!
trap 'kill "$live_pid" 2>/dev/null; chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
true &
dead_pid=$!
wait "$dead_pid"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# run <workspace> <args…>: runs the script, leaving its stdout, stderr and exit status in
# $out, $err and $status.
run() {
  local workspace=$1
  shift
  out=$("$script" "$@" --workspace "$workspace" 2>"$work/stderr")
  status=$?
  err=$(cat "$work/stderr")
  echo "   run-lock.sh $* -> exit $status: $out${err:+ | stderr: $err}"
}

# fresh <name>: a new, empty workspace for one case.
fresh() {
  ws="$work/$1"
  mkdir -p "$ws"
  lock="$ws/.kp-locks/k.lock"
}

verdict() { # label problems
  if [ -z "$2" ]; then check "$1" ok; else echo "   problems:$2"; check "$1" MISMATCH; fi
}

pid_in_lock() { sed -n 's/^pid=//p' "$lock"; }

echo "== acquire-free"
fresh acquire-free
run "$ws" acquire k --pid "$live_pid"
problems=
[ "$status" -eq 0 ] || problems="$problems exit=$status"
[ "$out" = "acquired key=k pid=$live_pid" ] || problems="$problems stdout"
[ "$(sed -n 1p "$lock")" = "pid=$live_pid" ] || problems="$problems pid-line"
sed -n 2p "$lock" | grep -qE '^started=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || problems="$problems started-line"
sed -n 3p "$lock" | grep -q '^session=' || problems="$problems session-line"
sed -n 4p "$lock" | grep -q '^log=' || problems="$problems log-line"
compgen -G "$ws/.kp-locks/*.tmp.*" >/dev/null && problems="$problems tmp-left"
verdict acquire-free "$problems"

echo "== held-live"
fresh held-live
run "$ws" acquire k --pid "$live_pid" >/dev/null
before=$(cat "$lock")
run "$ws" acquire k --pid "$dead_pid"
problems=
[ "$status" -eq 3 ] || problems="$problems exit=$status"
[[ "$out" == "held key=k pid=$live_pid started="* ]] || problems="$problems stdout"
[ "$(cat "$lock")" = "$before" ] || problems="$problems file-changed"
verdict held-live "$problems"

echo "== takeover-dead"
fresh takeover-dead
run "$ws" acquire k --pid "$dead_pid" >/dev/null
run "$ws" acquire k --pid "$live_pid"
problems=
[ "$status" -eq 0 ] || problems="$problems exit=$status"
[[ "$out" == *"takeover=$dead_pid"* ]] || problems="$problems stdout"
[[ "$err" == *"took over stale lock"* ]] || problems="$problems stderr"
[ "$(pid_in_lock)" = "$live_pid" ] || problems="$problems pid-not-new"
compgen -G "$ws/.kp-locks/*.stale.*" >/dev/null && problems="$problems stale-left"
verdict takeover-dead "$problems"

echo "== reentrant"
fresh reentrant
run "$ws" acquire k --pid "$live_pid" >/dev/null
before=$(cat "$lock")
run "$ws" acquire k --pid "$live_pid"
problems=
[ "$status" -eq 0 ] || problems="$problems exit=$status"
[ "$out" = "acquired key=k pid=$live_pid reentrant" ] || problems="$problems stdout"
[ "$(cat "$lock")" = "$before" ] || problems="$problems file-changed"
verdict reentrant "$problems"

echo "== release-not-owner"
fresh release
run "$ws" acquire k --pid "$live_pid" >/dev/null
run "$ws" release k --pid "$dead_pid"
problems=
[ "$status" -eq 3 ] || problems="$problems exit=$status"
[ "$out" = "not-owner key=k pid=$live_pid" ] || problems="$problems stdout"
[ -e "$lock" ] || problems="$problems file-removed"
verdict release-not-owner "$problems"

echo "== release-owner"
run "$ws" release k --pid "$live_pid"
problems=
[ "$status" -eq 0 ] || problems="$problems exit=$status"
[ "$out" = "released key=k" ] || problems="$problems stdout"
[ -e "$lock" ] && problems="$problems file-left"
verdict release-owner "$problems"

echo "== release-free"
run "$ws" release k --pid "$live_pid"
problems=
[ "$status" -eq 0 ] || problems="$problems exit=$status"
[ "$out" = "not-held key=k" ] || problems="$problems stdout"
verdict release-free "$problems"

echo "== default-pid"
fresh default-pid
out=$(CLAUDE_PID="$live_pid" "$script" acquire k --workspace "$ws" 2>/dev/null)
status=$?
echo "   CLAUDE_PID=$live_pid run-lock.sh acquire k -> exit $status: $out"
problems=
[ "$status" -eq 0 ] || problems="$problems exit=$status"
[ "$(pid_in_lock)" = "$live_pid" ] || problems="$problems pid=$(pid_in_lock)"
verdict default-pid "$problems"

# status must never write: the directory listing and the lock's content are compared
# before and after every call.
snapshot() { ls -la "$ws/.kp-locks"; cat "$lock" 2>/dev/null; }

echo "== status"
fresh status
mkdir -p "$ws/.kp-locks"
problems=
before=$(snapshot)
run "$ws" status k
[ "$status" -eq 0 ] && [ "$out" = "free key=k" ] || problems="$problems free"
[ "$(snapshot)" = "$before" ] || problems="$problems free-wrote"
run "$ws" acquire k --pid "$live_pid" >/dev/null
before=$(snapshot)
run "$ws" status k
[ "$status" -eq 0 ] && [[ "$out" == "held key=k pid=$live_pid started="* ]] || problems="$problems held"
[ "$(snapshot)" = "$before" ] || problems="$problems held-wrote"
printf 'pid=%s\nstarted=2026-01-01T00:00:00Z\nsession=\nlog=\n' "$dead_pid" > "$lock"
before=$(snapshot)
run "$ws" status k
[ "$status" -eq 0 ] && [ "$out" = "stale key=k pid=$dead_pid started=2026-01-01T00:00:00Z session= log=" ] \
  || problems="$problems stale"
[ "$(snapshot)" = "$before" ] || problems="$problems stale-wrote"
verdict status "$problems"

echo "== malformed"
fresh malformed
mkdir -p "$ws/.kp-locks"
echo "garbage" > "$lock"
problems=
run "$ws" status k
[ "$status" -eq 0 ] && [[ "$out" == "stale key=k pid= "* ]] || problems="$problems status"
run "$ws" acquire k --pid "$live_pid"
[ "$status" -eq 0 ] || problems="$problems exit=$status"
[[ "$out" == *"takeover= "* ]] || problems="$problems stdout"
[ "$(pid_in_lock)" = "$live_pid" ] || problems="$problems pid-not-new"
verdict malformed "$problems"

echo "== usage"
fresh usage
problems=
run "$ws" frobnicate k --pid "$live_pid"
[ "$status" -eq 2 ] || problems="$problems bad-verb=$status"
run "$ws" acquire a/b --pid "$live_pid"
[ "$status" -eq 2 ] || problems="$problems bad-key=$status"
"$script" acquire k --pid "$live_pid" >/dev/null 2>&1
status=$?
echo "   run-lock.sh acquire k (no --workspace) -> exit $status"
[ "$status" -eq 2 ] || problems="$problems no-workspace=$status"
verdict usage "$problems"

echo "== io-failure"
if [ "$(id -u)" -eq 0 ]; then
  echo "   skipped: running as root, which ignores the directory's permissions"
  check io-failure ok
else
  fresh io-failure
  mkdir -p "$ws/.kp-locks"
  chmod 500 "$ws/.kp-locks"
  run "$ws" acquire k --pid "$live_pid"
  chmod 700 "$ws/.kp-locks"
  problems=
  [ "$status" -eq 1 ] || problems="$problems exit=$status"
  [[ "$err" == run-lock.sh:* ]] || problems="$problems stderr"
  verdict io-failure "$problems"
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all run-lock checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
