#!/usr/bin/env bash
# Runs repo-roots.sh against throwaway repos. Each case gets fresh local bare repos as
# origins; every clone's remote.origin.url is a GitHub URL redirected to its bare repo
# with url.<bare>.insteadOf, HOME is the temp dir, and a `gh` stub that fails when called
# is first on PATH. Offline, so this runs in CI.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
script="$repo_root/kp-gh-lib/scripts/repo-roots.sh"
failures=0

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# fresh-checkout.sh exports under TMPDIR, so the "ref exists" case leaves nothing behind.
export HOME="$tmp" GIT_CONFIG_NOSYSTEM=1 TMPDIR="$tmp/exports"
mkdir -p "$TMPDIR"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
# Prints $GH_STUB_OUTPUT when a case sets it; any other call is a bug in the script.
if [ -n "${GH_STUB_OUTPUT:-}" ]; then
  printf '%s\n' "$GH_STUB_OUTPUT"
  exit 0
fi
echo "gh stub: unexpected call: $*" >&2
exit 99
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

check() {
  local label=$1 result=$2
  echo "-> $label: $result"
  [ "$result" = ok ] || failures=$((failures + 1))
}

# make_clone <case-dir> <name> <origin-url>: a bare repo with one commit on main, and a
# clone of it at <case-dir>/<name> whose origin URL is <origin-url>.
make_clone() {
  local dir=$1 name=$2 url=$3 bare="$1/bare/$2.git"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$dir/$name" 2>/dev/null
  echo "$name" >"$dir/$name/README.md"
  git -C "$dir/$name" add README.md
  git -C "$dir/$name" commit -q -m "Seed $name"
  git -C "$dir/$name" push -q origin main
  git -C "$dir/$name" remote set-head origin main
  git -C "$dir/$name" remote set-url origin "$url"
  git -C "$dir/$name" config "url.$bare.insteadOf" "$url"
}

# new_case <name> <config-json>: a spec repo (the run root) holding spec.md and the
# config, plus two area clones — frontend (https form) and backend (git@ form).
new_case() {
  local dir="$tmp/$1"
  mkdir -p "$dir"
  make_clone "$dir" spec https://github.com/acme/spec
  make_clone "$dir" frontend https://github.com/acme/frontend
  make_clone "$dir" backend git@github.com:ACME/backend.git
  mkdir -p "$dir/spec/.claude"
  printf '%s\n' "$2" >"$dir/spec/.claude/spec-sync.json"
  echo "# Spec" >"$dir/spec/spec.md"
  git -C "$dir/spec" add .
  git -C "$dir/spec" commit -q -m "Add config and spec"
  git -C "$dir/spec" push -q origin main
  case_dir=$dir
}

# run_script <args>…: runs repo-roots.sh from the spec root, setting out, err, status.
run_script() {
  status=0
  out=$(cd "$case_dir/spec" && "$script" "$@" 2>"$tmp/stderr") || status=$?
  err=$(cat "$tmp/stderr")
}

# A failed check: exit 1, nothing on stdout, exactly one stderr line containing $2.
expect_failure() {
  local label=$1 needle=$2
  if [ "$status" -eq 1 ] && [ -z "$out" ] && [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ] \
    && [[ $err == *"$needle"* ]]; then
    check "$label" ok
  else
    printf 'status=%s\nstdout=%s\nstderr=%s\n' "$status" "$out" "$err"
    check "$label" MISMATCH
  fi
}

# Rewrites every area's codeRoot to its physical path (macOS /private prefix).
physical_roots() {
  local json=$1 count index code_root
  count=$(jq '.areas | length' <<<"$json")
  for ((index = 0; index < count; index++)); do
    code_root=$(jq -r ".areas[$index].codeRoot" <<<"$json")
    code_root=$(cd "$code_root" && pwd -P)
    json=$(jq --arg root "$code_root" ".areas[$index].codeRoot = \$root" <<<"$json")
  done
  printf '%s' "$json"
}

expect_json() {
  local label=$1 expected=$2
  if [ "$status" -eq 0 ] \
    && diff -u <(jq -S . <<<"$expected") <(physical_roots "$out" | jq -S .); then
    check "$label" ok
  else
    printf 'status=%s\nstderr=%s\n' "$status" "$err"
    check "$label" MISMATCH
  fi
}

sha_of() {
  git -C "$1" rev-parse HEAD
}

two_areas='{"specRepo": {"value": "acme/spec"}, "requirementRepos": {
  "note": "routes areas to repos",
  "UI": {"repo": "acme/frontend", "path": "../frontend"},
  "API": {"repo": "acme/Backend", "path": "../backend"}}}'

echo "== happy path, two areas"
new_case happy "$two_areas"
run_script --spec-files spec.md
expect_json "happy path" "$(jq -n --arg spec "$(sha_of "$case_dir/spec")" \
  --arg fe "$(sha_of "$case_dir/frontend")" --arg be "$(sha_of "$case_dir/backend")" \
  --arg feRoot "$case_dir/frontend" --arg beRoot "$case_dir/backend" '
  {specRepo: "acme/spec", specBranch: "main", specSha: $spec, areas: [
    {area: "UI", repo: "acme/frontend", path: "../frontend", branch: "main", sha: $fe, codeRoot: $feRoot},
    {area: "API", repo: "acme/Backend", path: "../backend", branch: "main", sha: $be, codeRoot: $beRoot}]}')"

echo "== note string entry skipped"
if [ "$(jq -c '[.areas[].area]' <<<"$out")" = '["UI","API"]' ]; then
  check "note skipped" ok
else
  check "note skipped" MISMATCH
fi

echo "== missing path"
new_case missing '{"requirementRepos": {"UI": {"repo": "acme/frontend", "path": "../absent"}}}'
run_script
expect_failure "missing path" "repo-roots: UI: work-tree failed: ../absent"

echo "== origin is another repo"
new_case wrong-origin '{"requirementRepos": {"UI": {"repo": "acme/other", "path": "../frontend"}}}'
run_script
expect_failure "wrong origin" "repo-roots: UI: origin failed: ../frontend"

echo "== fetch fails"
new_case fetch-fails '{"requirementRepos": {"UI": {"repo": "acme/frontend", "path": "../frontend"}}}'
rm -rf "$case_dir/bare/frontend.git"
run_script
expect_failure "fetch fails" "repo-roots: UI: fetch failed: ../frontend"

echo "== no requirementRepos"
new_case no-areas '{}'
run_script
expect_json "no areas" "$(jq -n --arg spec "$(sha_of "$case_dir/spec")" \
  '{specRepo: "acme/spec", specBranch: "main", specSha: $spec, areas: []}')"

echo "== default branch from gh"
new_case gh-branch '{"requirementRepos": {"UI": {"repo": "acme/frontend", "path": "../frontend"}}}'
git -C "$case_dir/frontend" remote set-head origin -d
GH_STUB_OUTPUT=main run_script
if [ "$status" -eq 0 ] && [ "$(jq -r '.areas[0].branch' <<<"$out")" = main ]; then
  check "gh default branch" ok
else
  printf 'status=%s\nstdout=%s\nstderr=%s\n' "$status" "$out" "$err"
  check "gh default branch" MISMATCH
fi

echo "== dirty spec file"
new_case dirty '{}'
echo "local edit" >>"$case_dir/spec/spec.md"
run_script --spec-files spec.md
expect_failure "dirty spec with --spec-files" "repo-roots: spec: dirty failed: . (differs from $(sha_of "$case_dir/spec"): spec.md)"
run_script
if [ "$status" -eq 0 ] && [ -n "$out" ]; then
  check "dirty spec without --spec-files" ok
else
  printf 'status=%s\nstderr=%s\n' "$status" "$err"
  check "dirty spec without --spec-files" MISMATCH
fi

echo "== spec clone behind and clean"
new_case behind '{}'
git clone -q "$case_dir/bare/spec.git" "$case_dir/spec-other" 2>/dev/null
echo "## More" >>"$case_dir/spec-other/spec.md"
git -C "$case_dir/spec-other" commit -q -am "Extend spec"
git -C "$case_dir/spec-other" push -q origin main
run_script --spec-files spec.md
pushed=$(sha_of "$case_dir/spec-other")
if [ "$status" -eq 0 ] && [ "$(jq -r .specSha <<<"$out")" = "$pushed" ] \
  && [ "$(sha_of "$case_dir/spec")" = "$pushed" ]; then
  check "behind spec pulled" ok
else
  printf 'status=%s\nstdout=%s\nstderr=%s\n' "$status" "$out" "$err"
  check "behind spec pulled" MISMATCH
fi

echo "== unknown flag"
run_script --bogus
if [ "$status" -eq 2 ] && [ -z "$out" ]; then
  check "unknown flag exits 2" ok
else
  check "unknown flag exits 2" MISMATCH
fi

one_area='{"requirementRepos": {"UI": {"repo": "acme/frontend", "path": "../frontend"}}}'

echo "== ref exists"
new_case ref-exists "$one_area"
git -C "$case_dir/frontend" checkout -q -b release/M1
echo milestone >"$case_dir/frontend/feature.txt"
git -C "$case_dir/frontend" add feature.txt
git -C "$case_dir/frontend" commit -q -m "Milestone work"
git -C "$case_dir/frontend" push -q origin release/M1
release_sha=$(sha_of "$case_dir/frontend")
git -C "$case_dir/frontend" checkout -q main
run_script --ref release/M1
code_root=$(jq -r '.areas[0].codeRoot' <<<"$out")
if [ "$status" -eq 0 ] && [ "$(jq -r '.areas[0].branch' <<<"$out")" = release/M1 ] \
  && [ "$(jq -r '.areas[0].sha' <<<"$out")" = "$release_sha" ] \
  && [ "$(git -C "$code_root" rev-parse HEAD)" = "$release_sha" ] \
  && [ "$(jq -r .specBranch <<<"$out")" = main ] \
  && [ "$(jq -r .specSha <<<"$out")" = "$(sha_of "$case_dir/spec")" ]; then
  check "ref exists" ok
else
  printf 'status=%s\nstdout=%s\nstderr=%s\n' "$status" "$out" "$err"
  check "ref exists" MISMATCH
fi

echo "== ref falls back"
new_case ref-fallback "$one_area"
run_script --ref release/M9
if [ "$status" -eq 0 ] && [ "$(jq -r '.areas[0].branch' <<<"$out")" = main ] \
  && [ "$(jq -r '.areas[0].sha' <<<"$out")" = "$(sha_of "$case_dir/frontend")" ] \
  && [ "$err" = "fresh-checkout.sh: origin/release/M9 not found; reading origin/main" ]; then
  check "ref falls back" ok
else
  printf 'status=%s\nstdout=%s\nstderr=%s\n' "$status" "$out" "$err"
  check "ref falls back" MISMATCH
fi

echo "== invalid ref"
run_script --ref 'bad..ref'
if [ "$status" -eq 2 ] && [ -z "$out" ]; then
  check "invalid ref exits 2" ok
else
  check "invalid ref exits 2" MISMATCH
fi

echo "mismatches: $failures"
[ "$failures" -eq 0 ]
