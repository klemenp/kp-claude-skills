#!/usr/bin/env bash
# Runs .github/scripts/validate_skills.py and the Stop gate .claude/hooks/validate_gate.py
# against temporary skills trees, one tree per case. Both scripts find the repository as
# two directories above their own file, so each tree gets its own copy of them at the
# same relative paths; the real repository is never validated here.
# Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="${VALIDATE_SKILLS_REPO:-$(cd "$here/../../.." && pwd)}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
checks=0
mismatches=0
tree=""
out=""
err=""
status=0

VALID_FRONTMATTER=$'name: kp-a\ndescription: A test skill.'

# new_tree [--no-validator] — starts an empty tree holding copies of the two scripts.
new_tree() {
  tree="$(mktemp -d "$work/tree.XXXXXX")"
  mkdir -p "$tree/.github/scripts" "$tree/.claude/hooks"
  cp "$repo_root/.claude/hooks/validate_gate.py" "$tree/.claude/hooks/"
  [ "${1:-}" = --no-validator ] || cp "$repo_root/.github/scripts/validate_skills.py" "$tree/.github/scripts/"
}

# skill <dir> <frontmatter lines> [body] — writes <tree>/<dir>/SKILL.md.
skill() {
  mkdir -p "$tree/$1"
  printf -- '---\n%s\n---\n%s\n' "$2" "${3:-Body.}" > "$tree/$1/SKILL.md"
}

validate() {
  out="$(python3 "$tree/.github/scripts/validate_skills.py" 2>"$work/stderr")"
  status=$?
  err="$(cat "$work/stderr")"
}

# gate <stdin text> — runs the Stop gate with that hook event.
gate() {
  out="$(printf '%s' "$1" | python3 "$tree/.claude/hooks/validate_gate.py" 2>"$work/stderr")"
  status=$?
  err="$(cat "$work/stderr")"
}

# expect <label> <exit code> [text stdout must contain]...
expect() {
  local label=$1 want_status=$2 problem="" text
  shift 2
  [ "$status" -eq "$want_status" ] || problem="exit $status, want $want_status"
  for text in "$@"; do
    [[ $out == *"$text"* ]] || problem="${problem:+$problem; }stdout lacks '$text'"
  done
  report "$label" "$problem"
}

# report <label> <problem, empty when the check passed>
report() {
  checks=$((checks + 1))
  if [ -z "$2" ]; then
    echo "-> $1: ok"
  else
    echo "-> $1: MISMATCH ($2)"
    mismatches=$((mismatches + 1))
  fi
}

# rejects <label> <frontmatter lines> <text the report must contain> [body]
# One skill kp-a with that frontmatter must fail with that text.
rejects() {
  new_tree
  skill kp-a "$2" "${4:-Body.}"
  validate
  expect "$1" 1 "FAIL kp-a" "$3" "1 skills checked, 1 failed"
}

# accepts <label> <frontmatter lines> [body]
accepts() {
  new_tree
  skill kp-a "$2" "${3:-Body.}"
  validate
  expect "$1" 0 "ok   kp-a" "1 skills checked, 0 failed"
}

repeat() { printf "%${1}s" "" | tr ' ' x; }

# --- validate_skills.py ---------------------------------------------------------------

accepts "1 a valid skill passes" "$VALID_FRONTMATTER"

new_tree
mkdir "$tree/kp-a"
validate
expect "2 a directory without SKILL.md fails" 1 "FAIL kp-a" "no SKILL.md"

new_tree
mkdir "$tree/kp-a"
printf 'name: kp-a\ndescription: A test skill.\n' > "$tree/kp-a/SKILL.md"
validate
expect "3 a file without frontmatter fails" 1 "FAIL kp-a" "missing YAML frontmatter"

new_tree
mkdir "$tree/kp-a"
printf -- '---\n%s\nBody.\n' "$VALID_FRONTMATTER" > "$tree/kp-a/SKILL.md"
validate
expect "4 an unclosed frontmatter fails" 1 "FAIL kp-a" "never closed"

rejects "5 a line that is not key: value fails" \
  "$VALID_FRONTMATTER"$'\n  - x' "not a flat 'key: value' pair"
rejects "6 a duplicate key fails" \
  "$VALID_FRONTMATTER"$'\nname: kp-a' "duplicate key 'name'"
rejects "7 a missing description fails" \
  "name: kp-a" "missing a non-empty 'description'"
rejects "8 an unknown key fails" \
  "$VALID_FRONTMATTER"$'\nversion: 1' "unknown frontmatter key 'version'"
rejects "9 a name that differs from the directory fails" \
  $'name: kp-b\ndescription: A test skill.' "does not match directory"

new_tree
skill helper $'name: helper\ndescription: A test skill.'
validate
expect "10 a name without the kp- prefix fails" 1 "FAIL helper" 'does not match ^kp-[a-z0-9-]+$'

accepts "11a a 1024-character description passes" \
  "name: kp-a"$'\n'"description: $(repeat 1024)"
rejects "11b a 1025-character description fails" \
  "name: kp-a"$'\n'"description: $(repeat 1025)" "description is 1025 chars"

rejects "12a allowed-tools with an empty entry fails" \
  "$VALID_FRONTMATTER"$'\nallowed-tools: Read,, Bash' "empty entry"
rejects "12b allowed-tools with an unclosed parenthesis fails" \
  "$VALID_FRONTMATTER"$'\nallowed-tools: Bash(git:*' "unbalanced parentheses"
rejects "12c allowed-tools with text after a pattern fails" \
  "$VALID_FRONTMATTER"$'\nallowed-tools: Bash(git:*) x' "malformed pattern"
accepts "12d a well-formed allowed-tools passes" \
  "$VALID_FRONTMATTER"$'\nallowed-tools: Read, Bash(git:*)'

# The backticks below are literal Markdown, not command substitution.
# shellcheck disable=SC2016
rejects "13a a referenced script that does not exist fails" \
  "$VALID_FRONTMATTER" "which is not a file on disk" 'Run `scripts/run.sh` first.'

new_tree
# shellcheck disable=SC2016
skill kp-a "$VALID_FRONTMATTER" 'Run `scripts/run.sh` first.'
mkdir "$tree/kp-a/scripts"
: > "$tree/kp-a/scripts/run.sh"
validate
expect "13b a referenced script that exists passes" 0 "ok   kp-a"

# shellcheck disable=SC2016
accepts "13c a mention of a directory is not a reference" \
  "$VALID_FRONTMATTER" 'Helpers live in `scripts/`.'

new_tree
skill kp-a "$VALID_FRONTMATTER"
mkdir "$tree/synced" "$tree/.hidden"
validate
expect "14 synced/ and dot-directories are skipped" 0 "1 skills checked, 0 failed"

new_tree
validate
problem=""
[ "$status" -eq 1 ] || problem="exit $status, want 1"
[[ $err == *"no skill directories found"* ]] || problem="${problem:+$problem; }stderr lacks the message"
report "15 a tree without skills fails" "$problem"

new_tree
skill kp-a "$VALID_FRONTMATTER"
skill kp-b "name: kp-b"
validate
expect "16 one bad skill fails the run and the good one is still reported" 1 \
  "ok   kp-a" "FAIL kp-b" "2 skills checked, 1 failed"

# --- validate_gate.py -----------------------------------------------------------------

# silent <label> — the gate must exit 0 and print nothing.
silent() {
  local problem=""
  [ "$status" -eq 0 ] || problem="exit $status, want 0"
  [ -z "$out" ] || problem="${problem:+$problem; }stdout is not empty: $out"
  report "$1" "$problem"
}

new_tree
skill kp-a "$VALID_FRONTMATTER"
gate '{}'
silent "17 the gate allows a valid tree"

new_tree
skill kp-a "name: kp-a"
gate '{}'
problem=""
[ "$status" -eq 0 ] || problem="exit $status, want 0"
block="$(printf '%s' "$out" | python3 -c '
import json
import sys
answer = json.load(sys.stdin)
reason = answer["reason"]
print(answer["decision"], "validate_skills.py fails" in reason, "FAIL kp-a" in reason)
' 2>&1)"
[ "$block" = "block True True" ] || problem="${problem:+$problem; }answer is '$block' from: $out"
report "18 the gate blocks a tree with a failing skill" "$problem"

gate 'not json'
silent "19 the gate allows when the event is not JSON"

new_tree --no-validator
skill kp-a "name: kp-a"
gate '{}'
silent "20 the gate allows when the validator is missing"

if [ "$mismatches" -eq 0 ]; then
  echo "all validate-skills checks passed"
else
  echo "$mismatches of $checks validate-skills checks failed"
  exit 1
fi
