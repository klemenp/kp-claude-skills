#!/usr/bin/env bash
# Runs spec-branch.sh prepare / publish against a throwaway spec repo per case: a local
# bare `kp-demo-spec.git` as `origin` and a clone `spec/` as the primary checkout, with the
# fake `gh` in bin/ first on PATH. Offline — real git, no network — so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/spec-branch.sh"
failures=0

SPEC_REPO=example-org/kp-demo-spec
TARGET_REPO=example-org/kp-demo-target
PR_URL_PREFIX="https://github.com/$SPEC_REPO/pull"

export PATH="$here/bin:$PATH"
# The operator's git config (hooks, signing, default branch) must not change a case.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com

cases_root="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$cases_root"' EXIT

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# assert <label> <command…> — ok when the command succeeds.
assert() {
  local label=$1
  shift
  if "$@"; then check "$label" ok; else check "$label" MISMATCH; fi
}

# Sets tmp (the case dir, also the fake gh's state dir), spec (the primary checkout) and
# wt / batch_wt (the worktree paths spec-branch.sh derives for issue 7).
new_case() {
  echo "== $1"
  tmp="$(mktemp -d "$cases_root/case.XXXXXX")"
  export FAKE_GH_STATE="$tmp"
  git init -q -b main "$tmp/seed"
  git -C "$tmp/seed" commit -q --allow-empty -m seed
  git clone -q --bare "$tmp/seed" "$tmp/kp-demo-spec.git"
  git clone -q "$tmp/kp-demo-spec.git" "$tmp/spec"
  spec="$tmp/spec"
  wt="$tmp/kp-demo-spec-spec-resolve-7"
  batch_wt="$tmp/kp-demo-spec-spec-resolve-7-batch"
}

# Runs spec-branch.sh from the primary checkout; sets out (stdout) and status.
run_script() {
  status=0
  out="$(cd "$spec" && "$script" "$@" 2>"$tmp/stderr")" || status=$?
  [ "$status" -eq 0 ] || sed 's/^/   stderr: /' "$tmp/stderr"
}

field() { jq -r ".$1" <<<"$out"; }
commit_in() {
  echo "$2" >"$1/$2.md"
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}
head_of() { git -C "$1" rev-parse HEAD; }
origin_main() { git -C "$spec" rev-parse origin/main; }
on_origin() { [ -n "$(git -C "$spec" ls-remote --heads origin "$1")" ]; }
not_on_origin() { ! on_origin "$1"; }
no_local_branch() { ! git -C "$spec" show-ref --verify --quiet "refs/heads/$1"; }
logged() { grep -qF -- "$1" "$tmp/gh.log" 2>/dev/null; }
not_logged() { ! logged "$1"; }
equals() { [ "$1" = "$2" ]; }
write_prs() { printf '%s\n' "$1" >"$tmp/prs.json"; }
pr_entry() { printf '{"number": %s, "state": "%s", "headRefName": "%s", "url": "%s/%s"}' \
  "$1" "$2" "$3" "$PR_URL_PREFIX" "$1"; }

prepare() { run_script prepare --spec-repo "$SPEC_REPO" --issue 7 "$@"; }
publish_single() {
  run_script publish --spec-repo "$SPEC_REPO" --issue 7 --target-repo "$TARGET_REPO" \
    --title "Resolve #7: x" --body-file "$tmp/body.md"
}
single_body() { printf 'Refs %s#7. x\n' "$TARGET_REPO" >"$tmp/body.md"; }

new_case "fresh prepare"
prepare
assert "exit 0" equals "$status" 0
assert "reusedBranch false" equals "$(field reusedBranch)" false
assert "base main" equals "$(field base)" main
assert "worktree path" equals "$(field worktree)" "$wt"
assert "on spec/resolve-7" equals "$(git -C "$wt" branch --show-current)" spec/resolve-7
assert "at origin/main" equals "$(head_of "$wt")" "$(origin_main)"

new_case "leftover worktree is reclaimed"
git -C "$spec" worktree add -q "$wt" -b spec/resolve-7 origin/main
touch "$wt/stray.md"
prepare
assert "exit 0" equals "$status" 0
assert "re-added" test -e "$wt/.git"
assert "stray file gone" test ! -e "$wt/stray.md"

new_case "leftover legacy worktree is removed"
git -C "$spec" worktree add -q "$tmp/spec-resolve-7" -b spec/resolve-7 origin/main
prepare
assert "exit 0" equals "$status" 0
assert "no spec-resolve-7 directory" test ! -e "$tmp/spec-resolve-7"
assert "worktree at new name" equals "$(field worktree)" "$wt"

new_case "existing branch with an open PR is reused"
git -C "$spec" checkout -q -b spec/resolve-7
commit_in "$spec" earlier-fold
branch_head="$(head_of "$spec")"
git -C "$spec" checkout -q main
write_prs "[$(pr_entry 3 OPEN spec/resolve-7)]"
prepare
assert "exit 0" equals "$status" 0
assert "reusedBranch true" equals "$(field reusedBranch)" true
assert "branch commit is HEAD" equals "$(head_of "$wt")" "$branch_head"

new_case "newest PR merged: branch recreated"
git -C "$spec" checkout -q -b spec/resolve-7
commit_in "$spec" merged-fold
git -C "$spec" push -q origin spec/resolve-7
git -C "$spec" checkout -q main
write_prs "[$(pr_entry 5 MERGED spec/resolve-7), $(pr_entry 3 OPEN spec/resolve-7)]"
prepare
assert "exit 0" equals "$status" 0
assert "reusedBranch false" equals "$(field reusedBranch)" false
assert "recreated at origin/main" equals "$(head_of "$wt")" "$(origin_main)"
assert "deleted on origin" not_on_origin spec/resolve-7

new_case "publish creates a PR"
prepare
commit_in "$wt" decision
single_body
publish_single
assert "exit 0" equals "$status" 0
assert "created true" equals "$(field created)" true
assert "pr 1" equals "$(field pr)" 1
assert "pr create logged" logged "pr create -R $SPEC_REPO --base main --head spec/resolve-7"
assert "branch on origin" on_origin spec/resolve-7
assert "worktree gone" test ! -e "$wt"

new_case "publish reuses an open PR"
prepare
commit_in "$wt" decision
write_prs "[$(pr_entry 4 OPEN spec/resolve-7)]"
single_body
publish_single
assert "exit 0" equals "$status" 0
assert "created false" equals "$(field created)" false
assert "its url" equals "$(field url)" "$PR_URL_PREFIX/4"
assert "no pr create" not_logged "pr create"

new_case "publish refuses uncommitted edits"
prepare
touch "$wt/draft.md"
single_body
publish_single
assert "exit 2" equals "$status" 2
assert "worktree kept" test -d "$wt"
assert "nothing pushed" not_on_origin spec/resolve-7

new_case "publish refuses a body without the qualified reference"
prepare
commit_in "$wt" decision
printf 'Refs #7. x\n' >"$tmp/body.md"
publish_single
assert "exit 2" equals "$status" 2
assert "nothing pushed" not_on_origin spec/resolve-7

new_case "publish with a failing pr create"
prepare
commit_in "$wt" decision
single_body
touch "$tmp/fail-pr-create"
publish_single
assert "exit 1" equals "$status" 1
assert "empty stdout" equals "$out" ""
assert "worktree gone" test ! -e "$wt"

new_case "prepare without --issue"
run_script prepare --spec-repo "$SPEC_REPO"
assert "exit 2" equals "$status" 2
assert "no gh call" test ! -s "$tmp/gh.log"

new_case "batch prepare and publish"
prepare --batch
assert "prepare exit 0" equals "$status" 0
assert "batch worktree path" equals "$(field worktree)" "$batch_wt"
assert "batch branch" equals "$(field branch)" spec/resolve-7-batch
assert "reusedBranch false" equals "$(field reusedBranch)" false
commit_in "$batch_wt" decisions
printf '## %s#7: x\nRefs %s#7. x\n\n## %s#9: y\nRefs %s#9. y\n' \
  "$TARGET_REPO" "$TARGET_REPO" "$TARGET_REPO" "$TARGET_REPO" >"$tmp/body.md"
run_script publish --spec-repo "$SPEC_REPO" --issue 7 --batch \
  --title "Resolve 7, 9: 2 decisions" --body-file "$tmp/body.md"
assert "publish exit 0" equals "$status" 0
assert "created true" equals "$(field created)" true
assert "pr create on batch head" logged "--head spec/resolve-7-batch"
assert "batch branch on origin" on_origin spec/resolve-7-batch
assert "batch worktree gone" test ! -e "$batch_wt"
assert "no spec/resolve-7 locally" no_local_branch spec/resolve-7
assert "no spec/resolve-7 on origin" not_on_origin spec/resolve-7

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
