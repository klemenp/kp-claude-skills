#!/usr/bin/env bash
# Drives ci-failure-excerpt.sh against a fake gh (bin/gh): one failed Actions job with a
# 150-line failed-step log, the --lines option, an external status check, a log call that
# fails, times out or returns nothing, no failing checks, `gh pr checks` exiting 8 while
# pending, a failed checks read and the bad-argument cases. Offline — no GitHub — so this
# runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/ci-failure-excerpt.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PATH="$here/bin:$PATH" FAKE_STATE="$work"
failures=0

job_url=https://github.com/acme/widgets/actions/runs/111/job/222
external_url=https://ci.example.com/build/7

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

checks_json() { # file, then one "<name>|<bucket>|<link>" per check
  local file=$1 entry name bucket link first=true
  shift
  {
    printf '['
    for entry in "$@"; do
      IFS='|' read -r name bucket link <<<"$entry"
      $first || printf ','
      first=false
      printf '{"name":"%s","bucket":"%s","link":"%s","workflow":"validate"}' \
        "$name" "$bucket" "$link"
    done
    printf ']\n'
  } > "$file"
}

# 150 failed-step lines behind a byte-order mark: 1–100 in step "Build", 101–150 in
# step "Run tests", each `<job>\t<step>\t<timestamp> line <i>`.
printf '\xef\xbb\xbf' > "$work/log-150.txt"
for i in $(seq 1 150); do
  step=Build
  [ "$i" -le 100 ] || step='Run tests'
  printf 'validate\t%s\t2026-11-10T12:00:00.0000000Z line %d\n' "$step" "$i" >> "$work/log-150.txt"
done
: > "$work/log-empty.txt"

checks_json "$work/one-failed.json" "lint|pass|$job_url" "validate|fail|$job_url?pr=9"
checks_json "$work/external.json" "external-ci|fail|$external_url"
checks_json "$work/all-green.json" "lint|pass|$job_url" "docs|skipping|$job_url"
checks_json "$work/pending.json" "lint|pending|$job_url" "docs|pass|$job_url"

excerpt_of() { # first last total — the expected block for validate's failed job
  echo "check: validate"
  echo "url: $job_url?pr=9"
  echo "step: Run tests"
  echo "--- last $(($2 - $1 + 1)) of $3 failed-step lines ---"
  seq -f 'line %g' "$1" "$2"
}

run_case() { # label expected-status expected-stdout args… (env set by the caller)
  local label=$1 want_status=$2 want_out=$3 out status
  shift 3
  : > "$work/calls"
  out=$("$script" "$@" 2>"$work/stderr")
  status=$?
  echo "== $label -> exit $status${out:+, first line: ${out%%$'\n'*}}"
  if [ "$status" -eq "$want_status" ] && [ "$out" = "$want_out" ]; then
    check "$label" ok
  else
    diff <(printf '%s\n' "$want_out") <(printf '%s\n' "$out") | sed 's/^/   | /'
    sed 's/^/   stderr | /' "$work/stderr"
    check "$label" MISMATCH
  fi
}

FAKE_CHECKS="$work/one-failed.json" FAKE_LOG="$work/log-150.txt" \
  run_case one-failed-job 0 "$(excerpt_of 91 150 150)" acme/widgets 9
if grep -qx 'run view 111 -R acme/widgets --job 222 --log-failed' "$work/calls"; then
  check one-failed-job/log-call ok
else
  check one-failed-job/log-call MISMATCH
fi

FAKE_CHECKS="$work/one-failed.json" FAKE_LOG="$work/log-150.txt" \
  run_case lines-option 0 "$(excerpt_of 146 150 150)" acme/widgets 9 --lines 5
FAKE_CHECKS="$work/one-failed.json" FAKE_LOG="$work/log-150.txt" \
  run_case lines-option-above-total 0 "$(excerpt_of 1 150 150)" acme/widgets 9 --lines 500

unavailable() { # url reason
  printf 'check: %s\nurl: %s\nlog: unavailable (%s)' "${3:-validate}" "$1" "$2"
}

FAKE_CHECKS="$work/external.json" \
  run_case external-check 0 "$(unavailable "$external_url" 'not a GitHub Actions job' external-ci)" \
  acme/widgets 9
if grep -q '^run view' "$work/calls"; then
  check external-check/no-log-call MISMATCH
else
  check external-check/no-log-call ok
fi

FAKE_CHECKS="$work/one-failed.json" FAKE_LOG="$work/log-150.txt" FAKE_LOG_EXIT=1 \
  run_case log-call-fails 0 "$(unavailable "$job_url?pr=9" 'log call failed')" acme/widgets 9
FAKE_CHECKS="$work/one-failed.json" FAKE_LOG_SLEEP=3 KP_CI_EXCERPT_TIMEOUT_SECONDS=1 \
  run_case log-call-times-out 0 "$(unavailable "$job_url?pr=9" 'log call timed out')" acme/widgets 9
FAKE_CHECKS="$work/one-failed.json" FAKE_LOG="$work/log-empty.txt" \
  run_case log-empty 0 "$(unavailable "$job_url?pr=9" 'no failed-step lines')" acme/widgets 9

FAKE_CHECKS="$work/all-green.json" run_case none-failing 0 'no failing checks' acme/widgets 9
FAKE_CHECKS="$work/pending.json" FAKE_CHECKS_EXIT=8 \
  run_case pending-exit-8 0 'no failing checks' acme/widgets 9

FAKE_CHECKS_EXIT=1 run_case checks-read-fails 1 '' acme/widgets 9
if grep -q '^ci-failure-excerpt.sh: gh pr checks 9 -R acme/widgets failed' "$work/stderr"; then
  check checks-read-fails/stderr ok
else
  check checks-read-fails/stderr MISMATCH
fi

for case in 'no-arguments' 'missing-pr acme/widgets' 'bad-repo acme 9' \
  'non-numeric-pr acme/widgets nine' 'unknown-option acme/widgets 9 --bogus' \
  'lines-no-value acme/widgets 9 --lines' 'lines-not-integer acme/widgets 9 --lines 1.5' \
  'lines-zero acme/widgets 9 --lines 0' 'lines-negative acme/widgets 9 --lines -3'; do
  read -r label args <<<"$case"
  # shellcheck disable=SC2086 # deliberate word splitting of the case's arguments
  run_case "usage/$label" 2 '' $args
  if grep -q '^usage:' "$work/stderr" && ! [ -s "$work/calls" ]; then
    check "usage/$label/stderr" ok
  else
    check "usage/$label/stderr" MISMATCH
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "all ci-failure-excerpt checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
