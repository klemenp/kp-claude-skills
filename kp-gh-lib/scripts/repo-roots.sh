#!/usr/bin/env bash
# Validate a spec repo's routed clones and pin its spec commit — the check
# `kp-sync-spec-tasks` §0.9–§0.10 and `kp-backfill-contract` §0.9–§0.10 run.
#
# Usage: repo-roots.sh [--spec-dir <dir>] [--spec-files <file>…] [--ref <branch>]
#
# Run from the run's repo root; reads `<root>/.claude/spec-sync.json` (absent → no areas,
# no `specRepo`).
#   - Every object-valued `requirementRepos` entry is an area: its `path` (relative to the
#     root) must be a git work tree whose configured `remote.origin.url` names its `repo`
#     and must fetch. Its bare default branch, that branch's SHA and the code root
#     `fresh-checkout.sh` prints are recorded.
#   - With `--ref <branch>` (a milestone branch such as `release/M<k>`), each area reads
#     the milestone branch when its origin has it after the fetch, else the default
#     branch: `branch`/`sha` report the branch actually read, `--ref` goes on to
#     `fresh-checkout.sh`, and its `origin/<branch> not found` fallback line is passed on
#     to stderr, one per area that fell back. Areas may end up on different refs. The spec
#     checkout never takes `--ref`: `specBranch`/`specSha` stay its default branch.
#   - The spec repo is config `specRepo`, else the `origin` of `--spec-dir` (default: the
#     root). Its origin is fetched and its bare default branch and SHA recorded; a spec
#     checkout on that branch with a clean work tree is `git pull --ff-only`ed first (a
#     failed pull falls through). With `--spec-files`, those files must not differ from
#     the pinned SHA.
# Prints one JSON object:
#   {"specRepo","specBranch","specSha","areas":[{"area","repo","path","branch","sha","codeRoot"}]}
#
# Exit: 0 printed · 1 a failed check, one stderr line
#   `repo-roots: <area|spec>: <check> failed: <path>` and nothing on stdout · 2 bad arguments
#   (including a `--ref` that fails `git check-ref-format --branch` or holds a character
#   outside `[A-Za-z0-9._/-]`).
set -euo pipefail

GIT_TIMEOUT_SECONDS=60
fresh_checkout="$(cd "$(dirname "$0")" && pwd)/fresh-checkout.sh"

usage() {
  echo "usage: repo-roots.sh [--spec-dir <dir>] [--spec-files <file>…] [--ref <branch>]" >&2
  exit 2
}

spec_dir=""
ref=""
spec_files=()
check_spec_files=false
while [ $# -gt 0 ]; do
  case $1 in
    --spec-dir)
      [ $# -ge 2 ] || usage
      spec_dir=$2
      shift 2
      ;;
    --ref)
      [ $# -ge 2 ] || usage
      ref=$2
      shift 2
      ;;
    --spec-files)
      shift
      check_spec_files=true
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do
        spec_files+=("$1")
        shift
      done
      ;;
    *) usage ;;
  esac
done
if [ "$check_spec_files" = true ] && [ ${#spec_files[@]} -eq 0 ]; then
  usage
fi
if [ -n "$ref" ]; then
  [[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || usage
  git check-ref-format --branch "$ref" >/dev/null 2>&1 || usage
fi
ref_args=()
[ -z "$ref" ] || ref_args=(--ref "$ref")

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "repo-roots.sh: not inside a git work tree" >&2
  exit 2
}
config="$root/.claude/spec-sync.json"

# One stderr line per failure, so a calling skill can quote it whole.
fail() {
  local label=$1 check=$2 path=$3 detail=${4:-}
  printf 'repo-roots: %s: %s failed: %s%s\n' "$label" "$check" "$path" "${detail:+ ($detail)}" >&2
  exit 1
}

# `timeout(1)` is not in base macOS: the fresh-checkout.sh watchdog.
run_bounded() {
  local pid killer code=0
  "$@" &
  pid=$!
  ( sleep "$GIT_TIMEOUT_SECONDS"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" || code=$?
  kill -TERM "$killer" >/dev/null 2>&1 || true
  return "$code"
}

# `https://github.com/Owner/Name.git` and `git@github.com:Owner/Name.git` → `Owner/Name`.
slug_of() {
  local url=$1
  url=${url#https://github.com/}
  url=${url#git@github.com:}
  printf '%s' "${url%.git}"
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_work_tree() {
  [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]
}

# Prints the bare default branch of the clone at $1, whose GitHub repo is $2.
default_branch_of() {
  local dir=$1 repo=$2 head_ref branch
  if head_ref=$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s' "${head_ref#refs/remotes/origin/}"
    return 0
  fi
  branch=$(run_bounded gh repo view "$repo" --json defaultBranchRef \
    -q .defaultBranchRef.name 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  printf '%s' "$branch"
}

areas_tsv=""
spec_repo=""
if [ -f "$config" ]; then
  areas_tsv=$(jq -r '(.requirementRepos // {}) | to_entries[]
    | select(.value | type == "object")
    | [.key, (.value.repo // ""), (.value.path // "")] | @tsv' "$config")
  spec_repo=$(jq -r '.specRepo | if type == "object" then .value else . end // ""' "$config")
fi

checkout_errors=$(mktemp)
trap 'rm -f "$checkout_errors"' EXIT

areas_json='[]'
while IFS=$'\t' read -r area repo path; do
  [ -n "$area" ] || continue
  case $path in
    /*) abs_path=$path ;;
    *) abs_path="$root/$path" ;;
  esac
  is_work_tree "$abs_path" || fail "$area" work-tree "$path"
  origin_url=$(git -C "$abs_path" config --get remote.origin.url || true)
  [ "$(lower "$(slug_of "$origin_url")")" = "$(lower "$repo")" ] \
    || fail "$area" origin "$path" "origin is ${origin_url:-unset}, not $repo"
  run_bounded git -C "$abs_path" fetch origin >/dev/null 2>&1 || fail "$area" fetch "$path"
  branch=$(default_branch_of "$abs_path" "$repo") || fail "$area" default-branch "$path"
  sha=$(git -C "$abs_path" rev-parse --verify -q "origin/$branch^{commit}") \
    || fail "$area" default-branch "$path" "origin/$branch does not exist"
  # The same check fresh-checkout.sh makes on the same fetched refs, so the two agree.
  if [ -n "$ref" ] && ref_sha=$(git -C "$abs_path" rev-parse --verify -q "origin/$ref^{commit}"); then
    branch=$ref
    sha=$ref_sha
  fi
  if ! code_root=$("$fresh_checkout" "$abs_path" ${ref_args[@]+"${ref_args[@]}"} 2>"$checkout_errors"); then
    fail "$area" fresh-checkout "$path" "$(tail -n 1 "$checkout_errors")"
  fi
  # fresh-checkout.sh's note on why it exported rather than pulled, or that the --ref
  # fell back, is worth passing on.
  cat "$checkout_errors" >&2
  code_root=$(cd "$code_root" && pwd)
  areas_json=$(jq -c --arg area "$area" --arg repo "$repo" --arg path "$path" \
    --arg branch "$branch" --arg sha "$sha" --arg codeRoot "$code_root" \
    '. + [{area: $area, repo: $repo, path: $path, branch: $branch, sha: $sha, codeRoot: $codeRoot}]' \
    <<<"$areas_json")
done <<<"$areas_tsv"

spec_label=${spec_dir:-.}
spec_dir=${spec_dir:-$root}
is_work_tree "$spec_dir" || fail spec work-tree "$spec_label"
if [ -z "$spec_repo" ]; then
  spec_repo=$(slug_of "$(git -C "$spec_dir" config --get remote.origin.url || true)")
  [ -n "$spec_repo" ] || fail spec origin "$spec_label" "no origin and no specRepo"
fi
run_bounded git -C "$spec_dir" fetch origin >/dev/null 2>&1 || fail spec fetch "$spec_label"
spec_branch=$(default_branch_of "$spec_dir" "$spec_repo") || fail spec default-branch "$spec_label"
spec_sha=$(git -C "$spec_dir" rev-parse --verify -q "origin/$spec_branch^{commit}") \
  || fail spec default-branch "$spec_label" "origin/$spec_branch does not exist"

if [ "$(git -C "$spec_dir" symbolic-ref --short -q HEAD || true)" = "$spec_branch" ] \
  && [ -z "$(git -C "$spec_dir" status --porcelain)" ]; then
  # A failed pull is not an error: the clean check below catches a checkout left behind.
  run_bounded git -C "$spec_dir" pull --ff-only >/dev/null 2>&1 || true
fi

if [ "$check_spec_files" = true ] \
  && ! git -C "$spec_dir" diff --quiet "$spec_sha" -- "${spec_files[@]}"; then
  changed=$(git -C "$spec_dir" diff --name-only "$spec_sha" -- "${spec_files[@]}" | tr '\n' ' ')
  fail spec dirty "$spec_label" "differs from $spec_sha: ${changed% }"
fi

jq -n --arg specRepo "$spec_repo" --arg specBranch "$spec_branch" --arg specSha "$spec_sha" \
  --argjson areas "$areas_json" \
  '{specRepo: $specRepo, specBranch: $specBranch, specSha: $specSha, areas: $areas}'
