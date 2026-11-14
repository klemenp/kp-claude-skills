#!/usr/bin/env bash
# kp-compact-project's mechanical git and PR steps for one repo — the §0.4 repo guard and
# §0.5 tag (`prepare`), the §4.1 branch (`branch`), and the §4.3–§4.5 commit, push and PR
# with its rollback (`land`) — so every run checks and lands a repo the same way.
#
# Usage: compact-apply.sh prepare <repo> --tag <tag> [--no-tag]
#        compact-apply.sh branch <repo> --branch <name>
#        compact-apply.sh land <repo> --branch <name> --default <branch> --tag <tag>
#          --message-file <file> --title <title> --pr-body-file <file>
#
# prepare: a dirty work tree → `stop dirty` (no fetch); fetches origin; prints
#   `default <branch>` and `base <HEAD sha>` once HEAD is on the default branch and equals
#   `origin/<default>` (else `stop not-on-default <branch>` / `stop diverged <head> <origin>`);
#   then tags HEAD `<tag>` → `tag created`, or `tag reused` when it already points at the
#   base, or `stop tag-elsewhere <sha>` when it points elsewhere; `--no-tag` → `tag skipped`.
# branch: `refs/heads/<name>` or `refs/remotes/origin/<name>` exists →
#   `stop branch-exists <name>`, nothing changed; else switches to a new `<name>` and
#   prints `branch <name>`.
# land: on `<name>`, stages everything, commits with the message file (hooks always run),
#   pushes the branch and the tag (`pushed <ref>` after each), opens the PR and prints
#   `pr <url>`. On a failure it rolls back — `reset --hard HEAD`, switch to `<default>`,
#   delete the local branch and the local tag — and prints `failed commit nothing staged`,
#   `rejected <first stderr line of the commit>`, `failed push <ref>` or `failed pr`.
#   Remote refs are never deleted: a `pushed` line already printed stays true.
# The commit message and PR body are read only from files, never put in a shell string.
#
# Exit: 0 done · 1 a git/gh call failed (after rollback in `land`) · 2 bad arguments ·
#   3 a guard stop (`prepare`, `branch`) or a rejected commit (`land`), the `stop` or
#   `rejected` line naming why.
set -euo pipefail

NETWORK_TIMEOUT_SECONDS=120

usage() {
  echo "compact-apply.sh: $1" >&2
  exit 2
}

fail() {
  echo "compact-apply.sh: $1" >&2
  exit 1
}

# `timeout(1)` is not in base macOS, so network calls are bounded by a watchdog instead
# (the fresh-checkout.sh pattern).
run_bounded() {
  local pid killer code=0
  "$@" &
  pid=$!
  ( sleep "$NETWORK_TIMEOUT_SECONDS"; kill -TERM "$pid" ) >/dev/null 2>&1 &
  killer=$!
  wait "$pid" || code=$?
  kill -TERM "$killer" >/dev/null 2>&1 || true
  return "$code"
}

[ $# -ge 2 ] || usage "expected a subcommand and a repo"
subcommand=$1
repo=$2
shift 2
case "$subcommand" in
  prepare | branch | land) ;;
  *) usage "unknown subcommand: $subcommand" ;;
esac
if [ ! -d "$repo" ] || [ ! -e "$repo/.git" ]; then usage "not a git repo: $repo"; fi

tag="" no_tag=false branch="" default_branch="" message_file="" title="" pr_body_file=""
title_given=false
while [ $# -gt 0 ]; do
  case "$1" in
    --no-tag) no_tag=true; shift; continue ;;
    --tag | --branch | --default | --message-file | --title | --pr-body-file)
      [ $# -ge 2 ] || usage "$1 needs a value" ;;
    *) usage "unexpected argument: $1" ;;
  esac
  case "$1" in
    --tag) tag=$2 ;;
    --branch) branch=$2 ;;
    --default) default_branch=$2 ;;
    --message-file) message_file=$2 ;;
    --title) title=$2; title_given=true ;;
    --pr-body-file) pr_body_file=$2 ;;
  esac
  shift 2
done

# allow_options <subcommand> <option>… — reject any option the subcommand does not take.
allow_options() {
  local given
  for given in tag branch default_branch message_file pr_body_file; do
    [ -n "${!given}" ] || continue
    case " $* " in *" $given "*) ;; *) usage "$subcommand does not take --${given//_/-}" ;; esac
  done
  if "$no_tag" && [[ " $* " != *" no_tag "* ]]; then usage "$subcommand does not take --no-tag"; fi
  if "$title_given" && [[ " $* " != *" title "* ]]; then usage "$subcommand does not take --title"; fi
  return 0
}

case "$subcommand" in
  prepare)
    allow_options tag no_tag
    [ -n "$tag" ] || usage "prepare needs --tag"
    ;;
  branch)
    allow_options branch
    [ -n "$branch" ] || usage "branch needs --branch"
    ;;
  land)
    allow_options branch default_branch tag message_file title pr_body_file
    [ -n "$branch" ] || usage "land needs --branch"
    [ -n "$default_branch" ] || usage "land needs --default"
    [ -n "$tag" ] || usage "land needs --tag"
    [ -n "$title" ] || usage "land needs --title"
    if [ ! -f "$message_file" ] || [ ! -r "$message_file" ]; then
      usage "land needs a readable --message-file"
    fi
    if [ ! -f "$pr_body_file" ] || [ ! -r "$pr_body_file" ]; then
      usage "land needs a readable --pr-body-file"
    fi
    ;;
esac

stop() {
  echo "stop $*"
  exit 3
}

prepare() {
  local porcelain head_ref current head origin_sha tag_sha
  porcelain=$(git -C "$repo" status --porcelain) || fail "git status failed in $repo"
  [ -z "$porcelain" ] || stop dirty
  run_bounded git -C "$repo" fetch --quiet origin || fail "git fetch origin failed in $repo"
  head_ref=$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD) ||
    fail "cannot resolve the default branch of $repo (origin/HEAD unset)"
  default_branch=${head_ref#refs/remotes/origin/}
  current=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$current" = "$default_branch" ] || stop not-on-default "$current"
  head=$(git -C "$repo" rev-parse HEAD)
  origin_sha=$(git -C "$repo" rev-parse "refs/remotes/origin/$default_branch")
  [ "$head" = "$origin_sha" ] || stop diverged "$head" "$origin_sha"
  echo "default $default_branch"
  echo "base $head"
  if "$no_tag"; then
    echo "tag skipped"
    return 0
  fi
  if ! tag_sha=$(git -C "$repo" rev-parse --quiet --verify "refs/tags/$tag^{commit}"); then
    git -C "$repo" tag "$tag"
    echo "tag created"
    return 0
  fi
  [ "$tag_sha" = "$head" ] || stop tag-elsewhere "$tag_sha"
  echo "tag reused"
}

create_branch() {
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch" ||
    git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    stop branch-exists "$branch"
  fi
  git -C "$repo" switch -q -c "$branch"
  echo "branch $branch"
}

# Every step runs even when an earlier one fails, so the repo ends as close to clean as
# git allows; a failed step is named on stderr.
rollback() {
  git -C "$repo" reset -q --hard HEAD || echo "compact-apply.sh: rollback: reset failed" >&2
  git -C "$repo" switch -q "$default_branch" ||
    echo "compact-apply.sh: rollback: switch to $default_branch failed" >&2
  git -C "$repo" branch -D "$branch" >/dev/null ||
    echo "compact-apply.sh: rollback: deleting branch $branch failed" >&2
  git -C "$repo" tag -d "$tag" >/dev/null ||
    echo "compact-apply.sh: rollback: deleting tag $tag failed" >&2
}

land() {
  local current commit_stderr reason ref pr_output pr_url
  current=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
  [ "$current" = "$branch" ] || usage "land must run on $branch, not $current"

  git -C "$repo" add -A
  if git -C "$repo" diff --cached --quiet; then
    rollback
    echo "failed commit nothing staged"
    exit 1
  fi

  if ! commit_stderr=$(git -C "$repo" commit -q -F "$message_file" 2>&1 >/dev/null); then
    printf '%s\n' "$commit_stderr" >&2
    rollback
    reason=$(printf '%s\n' "$commit_stderr" | grep -m1 -v '^[[:space:]]*$' || true)
    echo "rejected $reason"
    exit 3
  fi

  for ref in "$branch" "$tag"; do
    local push_args=(push --quiet origin "$ref")
    [ "$ref" != "$branch" ] || push_args=(push --quiet -u origin "$ref")
    if ! run_bounded git -C "$repo" "${push_args[@]}"; then
      rollback
      echo "failed push $ref"
      exit 1
    fi
    echo "pushed $ref"
  done

  if ! pr_output=$(cd "$repo" && run_bounded gh pr create --base "$default_branch" \
    --head "$branch" --title "$title" --body-file "$pr_body_file"); then
    rollback
    echo "failed pr"
    exit 1
  fi
  pr_url=$(printf '%s\n' "$pr_output" | grep -v '^[[:space:]]*$' | tail -n 1)
  echo "pr $pr_url"
}

case "$subcommand" in
  prepare) prepare ;;
  branch) create_branch ;;
  land) land ;;
esac
