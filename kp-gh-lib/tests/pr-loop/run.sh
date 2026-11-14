#!/usr/bin/env bash
# Drives pr-loop.sh through each cases/<name>/ fixture against the fakes in bin/: a fake
# run-child.sh that counts launches and answers every wait at once, and fake gh,
# preamble.sh and pr-verdict-state.sh that replay the case's GitHub state as it stands
# after each launch (<name>.<k>.json, the highest k not above the launch count). Each
# case runs `start`, re-waits until a terminal line, and checks that line and its exit
# code (`expected`), the final state file (`state.expected`: phase outcome cycles stalls,
# or `none`), the side effects it must have made (`calls.expected`), those it must not
# (`absent-calls.expected`), when a case has `calls.exact`, the whole call sequence line
# for line, and, when a case has `output.expected`, that each of its lines appears as a
# whole line in the final output. A case's `env` file holds KEY=VALUE lines exported for
# that case only.
# Offline — no `claude`, no GitHub — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/pr-loop.sh"
# Physical path: pr-loop.sh resolves --log-dir, and macOS temp dirs sit behind /private.
work="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" KP_GH_LIB_BIN="$here/bin"
# No real sleeping between ci-wait polls.
export KP_PR_LOOP_CI_POLL_SECONDS=0
MAX_WAITS=20
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

for case_dir in "$here"/cases/*/; do
  name="$(basename "$case_dir")"
  echo "== $name"
  export FAKE_DIR="${case_dir%/}" FAKE_STATE="$work/$name"
  log_dir="$work/$name/logs"
  mkdir -p "$log_dir"
  extra=()
  [ -f "$FAKE_DIR/args" ] && read -ra extra < "$FAKE_DIR/args"
  state_file="$log_dir/pr-loop-demo-12.state.json"
  case_env=()
  [ -f "$FAKE_DIR/env" ] && mapfile -t case_env < "$FAKE_DIR/env"
  for assignment in "${case_env[@]}"; do export "${assignment?}"; done

  "$script" start example-org/demo 12 --project example-org/4 --log-dir "$log_dir" "${extra[@]}" \
    > "$work/$name.out" 2>&1
  status=$?
  waits=0
  while [ "$status" -eq 3 ] && [ "$waits" -lt "$MAX_WAITS" ]; do
    "$script" --wait "$state_file" --wait-max-sec 5 > "$work/$name.out" 2>&1
    status=$?
    waits=$((waits + 1))
  done

  actual="$(printf '%s\nexit %s' "$(tail -1 "$work/$name.out" | sed "s#$log_dir#LOG#g")" "$status")"
  if [ "$actual" = "$(cat "$FAKE_DIR/expected")" ]; then
    check "$name terminal line" ok
  else
    printf 'expected: %s\nactual:   %s\n' "$(cat "$FAKE_DIR/expected")" "$actual"
    cat "$work/$name.out"
    check "$name terminal line" MISMATCH
  fi

  if [ -f "$state_file" ]; then
    state="$(jq -r '"\(.phase) \(.outcome) \(.cycles) \(.stalls)"' "$state_file")"
  else
    state=none
  fi
  if [ "$state" = "$(cat "$FAKE_DIR/state.expected")" ]; then
    check "$name state file" ok
  else
    printf 'expected: %s\nactual:   %s\n' "$(cat "$FAKE_DIR/state.expected")" "$state"
    check "$name state file" MISMATCH
  fi

  if [ -f "$FAKE_DIR/calls.expected" ]; then
    missing="$(sed "s#$log_dir#LOG#g" "$FAKE_STATE/calls" 2>/dev/null | grep -vxFf - "$FAKE_DIR/calls.expected")"
    if [ -z "$missing" ]; then
      check "$name calls" ok
    else
      printf 'missing calls:\n%s\n' "$missing"
      check "$name calls" MISMATCH
    fi
  fi

  if [ -f "$FAKE_DIR/calls.exact" ]; then
    if diff <(sed "s#$log_dir#LOG#g" "$FAKE_STATE/calls" 2>/dev/null) "$FAKE_DIR/calls.exact"; then
      check "$name exact calls" ok
    else
      check "$name exact calls" MISMATCH
    fi
  fi

  if [ -f "$FAKE_DIR/output.expected" ]; then
    missing="$(sed "s#$log_dir#LOG#g" "$work/$name.out" | grep -vxFf - "$FAKE_DIR/output.expected")"
    if [ -z "$missing" ]; then
      check "$name output" ok
    else
      printf 'missing output lines:\n%s\n' "$missing"
      cat "$work/$name.out"
      check "$name output" MISMATCH
    fi
  fi

  if [ -f "$FAKE_DIR/absent-calls.expected" ]; then
    present="$(sed "s#$log_dir#LOG#g" "$FAKE_STATE/calls" 2>/dev/null | grep -xFf "$FAKE_DIR/absent-calls.expected")"
    if [ -z "$present" ]; then
      check "$name absent calls" ok
    else
      printf 'unexpected calls:\n%s\n' "$present"
      check "$name absent calls" MISMATCH
    fi
  fi

  for assignment in "${case_env[@]}"; do unset "${assignment%%=*}"; done
done

# Bad arguments exit 2 without touching anything.
"$script" start example-org/demo 12 > /dev/null 2>&1
if [ $? -eq 2 ]; then check "missing --project" ok; else check "missing --project" MISMATCH; fi
"$script" --wait > /dev/null 2>&1
if [ $? -eq 2 ]; then check "--wait without a state file" ok; else check "--wait without a state file" MISMATCH; fi

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "all pr-loop checks passed"
