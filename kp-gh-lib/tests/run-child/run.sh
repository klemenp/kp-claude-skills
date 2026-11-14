#!/usr/bin/env bash
# Drives run-child.sh's finished-child report over the <name>.log fixtures: each one is
# copied to a temp dir with the sentinel its <name>.expected line names, so `--wait`
# reports on it without launching anything. Then checks the still-running answer and bad
# arguments, that `--chrome` and the KP_HEADLESS_CHILD marker reach the child, and that
# the child's detached processes are swept on exit and on timeout, against the `claude`
# stub in bin/ (the timeout check waits out run-child.sh's one-minute minimum). Also checks
# the child registry: `--list` shows a running child, forgets it once it exits and prunes
# a dead entry, every child gets KP_CHILD_LOG, and nothing is written under the real
# home (the suite runs with HOME and KP_CHILDREN_DIR inside its temp dir). And checks
# `--effort` and a tier's effort suffix on `--model` reach the child as `--effort <level>`
# and KP_EFFORT, an explicit `--effort` wins, no effort adds neither, and an invalid one
# launches nothing. Offline — no
# real `claude`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/run-child.sh"
work="$(mktemp -d)"
unset KP_EFFORT
export KP_CHILDREN_DIR="$work/children"
export HOME="$work/home"
trap 'rm -rf "$work"' EXIT
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for fixture in "$here"/*.log; do
  name="$(basename "$fixture" .log)"
  expected="$(cat "$here/$name.expected")"
  code="$(sed -nE 's/^exit=([0-9]+).*/\1/p' <<<"$expected")"
  echo "== $name"
  log="$work/$name.log"
  cp "$fixture" "$log"
  echo "$code" > "$log.exit"
  actual="$("$script" --wait "$log")"
  # The log path is the temp dir's, so compare everything before it.
  if [ "${actual% log=*}" = "$expected" ]; then
    check "$name" ok
  else
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual"
    check "$name" MISMATCH
  fi
done

# No sentinel yet: the wait returns `status: running` and exit 3 so the caller re-waits.
echo "== still running"
"$script" --wait "$work/absent.log" --wait-max-sec 1 > "$work/running.out"
status=$?
running="$(cat "$work/running.out")"
echo "exit $status: $running"
if [ "$status" -eq 3 ] && [ "$running" = "status: running log=$work/absent.log" ]; then
  check "still running" ok
else
  check "still running" MISMATCH
fi

# `--chrome` reaches the child command and the child runs with KP_HEADLESS_CHILD=1: launch
# against the `claude` stub in bin/, which records both, and wait for it like any child.
echo "== chrome"
export RUN_CHILD_ARGV_FILE="$work/chrome.argv"
PATH="$here/bin:$PATH" "$script" --log "$work/chrome.log" --cwd "$work" --chrome -- "/probe" \
  >/dev/null
"$script" --wait "$work/chrome.log" --wait-max-sec 30 > "$work/chrome.out"
status=$?
echo "exit $status: $(cat "$work/chrome.out")"
missing=
for arg in --chrome -p --settings KP_HEADLESS_CHILD=1; do
  grep -qxe "$arg" "$RUN_CHILD_ARGV_FILE" 2>/dev/null || missing="$missing $arg"
done
if [ "$status" -eq 0 ] && [ -z "$missing" ]; then
  check "chrome" ok
else
  echo "missing from the child argv:${missing:- (none)}"
  check "chrome" MISMATCH
fi

# KP_CHILD_LOG names the child's own log.
echo "== child-log-env"
if grep -qxF "KP_CHILD_LOG=$work/chrome.log" "$RUN_CHILD_ARGV_FILE" 2>/dev/null; then
  check "child-log-env" ok
else
  check "child-log-env" MISMATCH
fi

# Effort: launch against the stub with the given run-child.sh options and check the
# child's argv (one argument per line, so a flag's value is the next line) and KP_EFFORT.
argv_pair() { # file flag value: the line after <flag> is <value>
  awk -v flag="$2" -v value="$3" 'prev == flag && $0 == value { found = 1 } { prev = $0 }
    END { exit !found }' "$1"
}

effort_check() { # label expected-model expected-effort run-child-options…
  local label=$1 want_model=$2 want_effort=$3 dir="$work/$1" problems=
  shift 3
  mkdir -p "$dir"
  echo "== $label"
  RUN_CHILD_ARGV_FILE="$dir/argv" PATH="$here/bin:$PATH" \
    "$script" --log "$dir/child.log" --cwd "$work" "$@" -- "/probe" >/dev/null
  "$script" --wait "$dir/child.log" --wait-max-sec 30 >/dev/null || problems="$problems wait"
  argv_pair "$dir/argv" --model "$want_model" || problems="$problems model"
  if [ -n "$want_effort" ]; then
    argv_pair "$dir/argv" --effort "$want_effort" || problems="$problems effort-flag"
  else
    grep -qxF -- --effort "$dir/argv" && problems="$problems effort-flag-present"
  fi
  grep -qxF "KP_EFFORT=$want_effort" "$dir/argv" || problems="$problems effort-env"
  if [ -z "$problems" ]; then check "$label" ok; else echo "problems:$problems"; check "$label" MISMATCH; fi
}

effort_check effort-flag opus high --model opus --effort high
effort_check effort-suffix opus xhigh --model opus-xhigh
effort_check effort-flag-wins opus high --model opus-low --effort high
effort_check effort-none opus "" --model opus

echo "== effort-invalid"
PATH="$here/bin:$PATH" "$script" --log "$work/invalid/child.log" --cwd "$work" \
  --effort bogus -- "/probe" >/dev/null 2>&1
status=$?
echo "exit $status"
if [ "$status" -eq 2 ] && [ ! -e "$work/invalid/child.log" ]; then
  check "effort-invalid" ok
else
  check "effort-invalid" MISMATCH
fi

# The registry: a running child is listed, then forgotten once its wait has returned.
echo "== list-running"
list_dir="$work/list"
mkdir -p "$list_dir"
list_prompt="/probe list"
RUN_CHILD_ARGV_FILE="$list_dir/argv" RUN_CHILD_STUB_SLEEP=5 PATH="$here/bin:$PATH" \
  "$script" --log "$list_dir/child.log" --cwd "$work" -- "$list_prompt" >/dev/null
# The detached wrapper registers asynchronously, so wait up to 10 s for its entry.
entry=
for _ in $(seq 1 50); do
  entry=$(find "$KP_CHILDREN_DIR" -maxdepth 1 -name 'run-child-*' 2>/dev/null | head -1)
  [ -n "$entry" ] && break
  sleep 0.2
done
listed=$("$script" --list)
echo "$listed"
expected_tail="cwd=$work log=$list_dir/child.log prompt=$list_prompt"
if [ -n "$entry" ] && [ "$(wc -l <<<"$listed")" -eq 1 ] \
  && [[ $listed =~ ^pid=[0-9]+\ elapsed=[0-9:d]+\ (.*)$ ]] \
  && [ "${BASH_REMATCH[1]}" = "$expected_tail" ]; then
  check "list-running" ok
else
  check "list-running" MISMATCH
fi

echo "== list-after-exit"
"$script" --wait "$list_dir/child.log" --wait-max-sec 30 >/dev/null
listed=$("$script" --list)
echo "$listed"
if [ "$listed" = "no live children" ] && [ -n "$entry" ] && [ ! -e "$entry" ]; then
  check "list-after-exit" ok
else
  check "list-after-exit" MISMATCH
fi

# A dead wrapper pid, and an entry with no pid at all, are both pruned.
echo "== list-prunes-dead"
true &
dead_pid=$!
wait "$dead_pid"
plant_entry() { # name [pid]
  {
    [ -n "${2-}" ] && echo "pid=$2"
    printf 'child=1\nstarted=2026-01-01T00:00:00Z\nstarted_epoch=1767225600\ncwd=%s\nlog=%s\nprompt=/probe\n' \
      "$work" "$work/planted.log"
  } > "$KP_CHILDREN_DIR/$1"
}
plant_entry run-child-dead-1 "$dead_pid"
plant_entry run-child-nopid-2
listed=$("$script" --list)
echo "$listed"
if [ "$listed" = "no live children" ] && [ ! -e "$KP_CHILDREN_DIR/run-child-dead-1" ] \
  && [ ! -e "$KP_CHILDREN_DIR/run-child-nopid-2" ]; then
  check "list-prunes-dead" ok
else
  check "list-prunes-dead" MISMATCH
fi

echo "== list-usage"
"$script" --list extra >/dev/null 2>&1
status=$?
echo "exit $status"
if [ "$status" -eq 2 ]; then check "list-usage" ok; else check "list-usage" MISMATCH; fi

# The sweep: whatever the child detached is gone once the wait reports it finished, on a
# normal exit and on a timeout, except a Gradle daemon, which may serve another build.
# `alive` ignores a zombie, which a dead process stays until its reaper notices.
alive() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  [[ $state != Z* ]]
}

sweep_check() { # label timeout-min stub-sleep expected-exit
  local label=$1 dir="$work/$1" out status code
  mkdir -p "$dir"
  echo "== $label"
  RUN_CHILD_ARGV_FILE="$dir/argv" RUN_CHILD_DETACH_DIR="$dir" RUN_CHILD_STUB_SLEEP=$3 \
    PATH="$here/bin:$PATH" "$script" --log "$dir/child.log" --cwd "$work" \
    --timeout-min "$2" -- "/probe" >/dev/null
  "$script" --wait "$dir/child.log" --wait-max-sec 120 > "$dir/out"
  status=$?
  out=$(cat "$dir/out")
  code="$(sed -nE 's/^exit=([0-9]+).*/\1/p' <<<"$out")"
  echo "exit $status: $out"
  local problems=
  [ "$status" -eq 0 ] || problems="$problems wait-status=$status"
  if [ "$4" = nonzero ]; then
    [ "${code:-0}" -ne 0 ] || problems="$problems child-exit=$code"
  else
    [ "$code" = "$4" ] || problems="$problems child-exit=$code"
  fi
  grep -qE '^KP_RUN_ID=run-child-[0-9]+-[0-9]+$' "$dir/argv" || problems="$problems no-run-id"
  alive "$(cat "$dir/detached.pid")" && problems="$problems detached-survived"
  alive "$(cat "$dir/daemon.pid")" || problems="$problems daemon-killed"
  kill -KILL "$(cat "$dir/detached.pid")" "$(cat "$dir/daemon.pid")" 2>/dev/null
  if [ -z "$problems" ]; then check "$label" ok; else echo "problems:$problems"; check "$label" MISMATCH; fi
}

sweep_check "sweep on exit" 0 "" 0
# The smallest timeout is one minute; the stub outlives it, so the watchdog fires.
sweep_check "sweep on timeout" 1 120 nonzero

# Bad arguments are exit 2, distinct from a launch failure.
echo "== usage"
"$script" --log "$work/x.log" >/dev/null 2>&1
status=$?
echo "exit $status"
if [ "$status" -eq 2 ]; then check "usage" ok; else check "usage" MISMATCH; fi

echo "== no-home-registry"
if [ ! -e "$work/home/.claude/kp-children" ]; then
  check "no-home-registry" ok
else
  check "no-home-registry" MISMATCH
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all run-child checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
