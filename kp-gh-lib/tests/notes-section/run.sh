#!/usr/bin/env bash
# Drives notes-section.sh over fixtures/sample.md: a `##` section with its subsections, a
# `###` section stopping at the next heading, the ` (suffix)` match, headings inside
# backtick and tilde fences, an ambiguous and a missing heading, the bad-argument cases,
# and one lookup against the real kp-gh-lib/NOTES.md. Offline — no GitHub — so this runs
# in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/notes-section.sh"
sample="$here/fixtures/sample.md"
failures=0

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

expect_section() { # label heading expected-output
  local out status
  out=$("$script" --file "$sample" "$2" 2>/dev/null)
  status=$?
  echo "== $1: '$2' -> exit $status"
  if [ "$status" -eq 0 ] && [ "$out" = "$3" ]; then
    check "$1" ok
  else
    printf '%s\n' "$out" | sed 's/^/   | /'
    check "$1" MISMATCH
  fi
}

expect_exit() { # label expected-status stderr-pattern args…
  local label=$1 want=$2 pattern=$3 out err status
  shift 3
  out=$("$script" "$@" 2>/dev/null)
  status=$?
  err=$("$script" "$@" 2>&1 >/dev/null)
  echo "== $label -> exit $status${err:+ | stderr: ${err//$'\n'/ / }}"
  if [ "$status" -eq "$want" ] && [ -z "$out" ] && [[ $err =~ $pattern ]]; then
    check "$label" ok
  else
    check "$label" MISMATCH
  fi
}

expect_section h2-with-subsections Alpha "## Alpha

Alpha intro.

### Rules

Alpha rules.

#### Deep detail

Still inside Alpha rules.

### Beta sub

Beta sub text."

expect_section h3-stops-at-next-h3 'Beta sub' "### Beta sub

Beta sub text."

expect_section suffix-match 'Waiting in a headless session' "## Waiting in a headless session (family convention)

Waiting text."

expect_section heading-inside-code-fence-ignored 'Coding item body' "## Coding item body

Template:

\`\`\`markdown
### Goal
<one paragraph>

## Not a heading either
\`\`\`

~~~text
\`\`\`
### Also not a heading
~~~

After the fences.

### Rules

Coding rules."

expect_exit ambiguous 1 '^notes-section.sh: 2 headings match: Rules.*7: ### Rules.*41: ### Rules' --file "$sample" Rules
expect_exit missing 1 'no heading matches: Gamma' --file "$sample" Gamma
expect_exit missing-fenced-heading 1 'no heading matches: Goal' --file "$sample" Goal

for case in 'no-heading' 'two-headings Alpha Beta' 'unknown-option --bogus Alpha' 'missing-file-value --file'; do
  read -r label args <<<"$case"
  # shellcheck disable=SC2086 # deliberate word splitting of the case's arguments
  expect_exit "usage/$label" 2 '^usage:' $args
done
expect_exit usage/unreadable-file 2 'cannot read file' --file "$here/fixtures/does-not-exist.md" Alpha

real_out=$("$script" 'Run state across compaction' 2>/dev/null)
real_status=$?
echo "== real-file: 'Run state across compaction' -> exit $real_status, first line: ${real_out%%$'\n'*}"
if [ "$real_status" -eq 0 ] && [ "${real_out%%$'\n'*}" = '## Run state across compaction (family convention)' ]; then
  check real-file ok
else
  check real-file MISMATCH
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "all notes-section checks passed"
else
  echo "$failures check(s) failed"
fi
exit $(( failures > 0 ? 1 : 0 ))
