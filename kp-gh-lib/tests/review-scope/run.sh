#!/usr/bin/env bash
# Runs review-scope.sh against a throwaway git repo and the <name>.json history fixtures
# (passed with --state-file, `__REVIEWED__` and `__BODY_SHA__` filled in per case) and the
# body-*.md bodies (passed with --body-file), asserting the full three-line stdout of each
# case. Offline: nothing calls GitHub, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/review-scope.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
UNKNOWN_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# The body hash kp-review-gh-pr/SKILL.md line 143 computed at 72034bc, verbatim: every
# earlier verdict's `body-sha256:` came from it, so review-scope.sh must agree with it.
reference_sha() {
  python3 -c 'import hashlib, re, sys; body = re.sub(r"<!--\s*human-only:start.*?(?:<!--\s*human-only:end\s*-->|\Z)", "", sys.stdin.read(), flags=re.DOTALL); print(hashlib.sha256(body.encode()).hexdigest())' < "$1"
}

# --- the throwaway repo -----------------------------------------------------------------
# main: src/app.py, src/other.py, tests/test_x.py. `reviewed` is the head a denial was made
# against; each origin/<head> ref below is one fix pushed on top of it (or beside it).
git_quiet() { git -C "$work/repo" "$@" >/dev/null 2>&1; }
commit_all() { git_quiet add -A && git_quiet commit -q -m "$1"; }

mkdir -p "$work/repo/src" "$work/repo/tests"
git_quiet init -q -b main
git_quiet config user.email fixtures@example.invalid
git_quiet config user.name fixtures
git_quiet config diff.renames true
printf 'total = 1\n' > "$work/repo/src/app.py"
printf 'other = 1\n' > "$work/repo/src/other.py"
printf 'def test_x():\n    pass\n' > "$work/repo/tests/test_x.py"
commit_all base
base="$(git -C "$work/repo" rev-parse HEAD)"

git_quiet checkout -q -b feature
printf 'total = 2\n' > "$work/repo/src/app.py"
commit_all reviewed
reviewed="$(git -C "$work/repo" rev-parse HEAD)"

# A fix confined to the flagged file and a test.
printf 'total = 3\n' > "$work/repo/src/app.py"
printf 'def test_x():\n    assert True\n' > "$work/repo/tests/test_x.py"
commit_all fix-flagged
git_quiet update-ref refs/remotes/origin/fix-flagged HEAD

# A fix that also touches a file no finding named.
git_quiet checkout -q "$reviewed"
printf 'other = 2\n' > "$work/repo/src/other.py"
commit_all fix-unflagged
git_quiet update-ref refs/remotes/origin/fix-unflagged HEAD

# A fix that renames the flagged file to a name no finding named.
git_quiet checkout -q "$reviewed"
git_quiet mv src/app.py src/renamed.py
commit_all fix-rename
git_quiet update-ref refs/remotes/origin/fix-rename HEAD

# A force-push: the new head does not descend from `reviewed`.
git_quiet checkout -q "$base"
printf 'total = 4\n' > "$work/repo/src/app.py"
commit_all side
git_quiet update-ref refs/remotes/origin/side HEAD

body_sha="$(reference_sha "$here/body.md")"

# case <label> <fixture> <issue|-> <body file> <head> <reviewed SHA for the fixture>
#      <expected scope line> <expected reviewed value> <expected bodySha value>
case_run() {
  local label=$1 fixture=$2 issue=$3 body=$4 head=$5 sha=$6
  local expected actual state="$work/$label.json"
  expected="$(printf '%s\nreviewed: %s\nbodySha: %s' "$7" "$8" "$9")"
  sed -e "s/__REVIEWED__/$sha/g" -e "s/__BODY_SHA__/$body_sha/g" "$here/$fixture" > "$state"
  actual="$(cd "$work/repo" && "$script" example-org/demo 7 "$issue" "$head" \
    --state-file "$state" --body-file "$here/$body" 2>&1)"
  if [ "$actual" = "$expected" ]; then
    check "$label" ok
  else
    diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual")
    check "$label" MISMATCH
  fi
}

case_run "fix-diff" denial-fixed.json 5 body.md fix-flagged "$reviewed" \
  "scope: fix-diff" "$reviewed" "$body_sha"
case_run "empty history" empty-history.json 5 body.md fix-flagged "$reviewed" \
  "scope: full (no prior denial)" - "$body_sha"
case_run "newest verdict an approval" approval-newest.json 5 body.md fix-flagged "$reviewed" \
  "scope: full (no prior denial)" - "$body_sha"
case_run "no newer fix summary" no-fix-push.json 5 body.md fix-flagged "$reviewed" \
  "scope: full (no fix push)" "$reviewed" "$body_sha"
case_run "reviewed on a side branch" denial-fixed.json 5 body.md side "$reviewed" \
  "scope: full (reviewed not an ancestor)" "$reviewed" "$body_sha"
case_run "reviewed unknown" denial-fixed.json 5 body.md fix-flagged "$UNKNOWN_SHA" \
  "scope: full (reviewed not an ancestor)" "$UNKNOWN_SHA" "$body_sha"
case_run "unflagged file" denial-fixed.json 5 body.md fix-unflagged "$reviewed" \
  "scope: full (fix outside flagged files)" "$reviewed" "$body_sha"
case_run "flagged file renamed" denial-fixed.json 5 body.md fix-rename "$reviewed" \
  "scope: full (fix outside flagged files)" "$reviewed" "$body_sha"
case_run "no linked issue" denial-fixed.json - body.md fix-flagged "$reviewed" \
  "scope: full (no body hash)" "$reviewed" -
case_run "denial without body hash" no-body-sha.json 5 body.md fix-flagged "$reviewed" \
  "scope: full (no body hash)" "$reviewed" "$body_sha"
case_run "item body changed" denial-fixed.json 5 body-changed.md fix-flagged "$reviewed" \
  "scope: full (item body changed)" "$reviewed" "$(reference_sha "$here/body-changed.md")"
case_run "first failing condition wins" no-fix-push.json 5 body-changed.md fix-flagged \
  "$reviewed" "scope: full (no fix push)" "$reviewed" "$(reference_sha "$here/body-changed.md")"

# The body hash agrees with the old one-liner on a fenced body and on CRLF line endings.
awk '{ printf "%s\r\n", $0 }' "$here/body-fenced.md" > "$work/body-crlf.md"
cp "$here/body-fenced.md" "$work/body-fenced.md"
for kind in fenced crlf; do
  body="$work/body-$kind.md"
  actual="$(cd "$work/repo" && "$script" example-org/demo 7 5 fix-flagged \
    --state-file "$here/empty-history.json" --body-file "$body" 2>&1 | sed -n 's/^bodySha: //p')"
  if [ -n "$actual" ] && [ "$actual" = "$(reference_sha "$body")" ]; then
    check "bodySha $kind" ok
  else
    echo "got '$actual', want '$(reference_sha "$body")'"
    check "bodySha $kind" MISMATCH
  fi
done

# Bad arguments are exit 2, distinct from a GitHub or git failure.
status=0
"$script" >/dev/null 2>&1 || status=$?
if [ "$status" -eq 2 ]; then
  check "no arguments exits 2" ok
else
  check "no arguments exits 2" MISMATCH
fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
