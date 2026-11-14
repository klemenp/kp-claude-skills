#!/usr/bin/env bash
# Trace a spec's requirements to the merged work that built them, bottom-up: merged PRs in
# the code repos routed to the spec → the issues each PR closes → the `spec-ref:` and
# `serves:` lines of those issues → the spec's REQs and their `Serves:` lines at the spec's
# default-branch SHA (spec-index.py). kp-audit-alignment's step 1.
#
# Usage: trace-matrix.sh <spec-repo> [--repo <target-repo>]
#                        [--milestone M<n> | --area <REQ-AREA> | --all] [--ref <branch>]
#
# Run from a checkout of <spec-repo>. The routed repos are the target repo (--repo, else
# `targetRepo` in the checkout's .claude/spec-sync.json) plus every `requirementRepos`
# repo, each counted once. A REQ area's owning repo is `requirementRepos[<AREA>].repo`,
# else the target repo. With no scope flag the scope is --all. A --milestone scope takes
# its items from the milestone epic's sub-issue tree, walked as milestone-gate.sh walks it.
#
# Code is read at the milestone branch when the unit has one and it exists, else the
# default branch: with `--ref <branch>` (any scope; a `--milestone M<k>` run with no
# `--ref` uses `release/M<k>`, and an explicit `--ref` wins), each routed code repo's
# `shas` entry and tree are `<branch>`'s commit when `repos/<repo>/branches/<branch>`
# exists, else its default branch's on a 404. The spec repo always stays on its default
# branch. `refs` names the branch read per routed code repo, on every run. A merged PR
# whose head branch starts with `release/` (a milestone merge PR, closing nothing and
# repeating its task PRs' files) is skipped in every scope: its files are never fetched,
# cached, or counted in `untraced`.
#
# Prints one JSON object on stdout:
#   {"spec": {"repo", "sha"},
#    "scope": {"kind": "all"|"area"|"milestone", "value", "epics": ["owner/repo#e", …]},
#    "covered": {"<REQ>": {"repo": <owning repo>, "serves": [G-…],
#                          "items": [{"item", "title", "prs", "serves", "files", "code"}]}},
#    "uncovered": ["<REQ>", …],
#    "noServes": ["owner/repo#n", …],
#    "noSpecRef": ["owner/repo#n", …],          # --milestone only: items with no REQ spec-ref
#    "untraced": {"owner/repo": ["path", …]},
#    "areas": {"<AREA>": <owning repo>},       # every area with an in-scope REQ
#    "shas": {"owner/repo": "<sha>"},
#    "refs": {"owner/repo": "<branch read>"}}  # every routed code repo
# A closing keyword whose issue is missing or inaccessible (404) closes nothing.
# `files` are the paths an item's merged PRs changed that exist at the repo's `shas`
# commit; `code` are its `code:` lines. `untraced` holds, per scope repo, the paths merged
# PRs changed that no merged PR closing an item traced to a spec REQ touched — path-level,
# and blind to commits pushed without a PR.
#
# REST and search only, every gh call bounded by a timeout. Never enumerates a board and
# needs no code checkout.
#
# A merged PR's changed files never change, so the filenames each `pulls/<n>/files` call
# returns (before the tree intersection) are cached per routed repo in
# kp-gh-lib/state/trace-cache/<owner>/<repo>.json, owner and repo lowercased, shaped
# {"version": 1, "prs": {"<PR number>": ["<filename>", …]}}. An entry is never pruned or
# refreshed; deleting the file is the only invalidation. A missing or malformed file is
# read as empty and rewritten. Closing refs are not cached: a PR body can be edited.
#
# Exit: 0 traced · 1 a lookup failed · 2 bad arguments or config (including a `--ref` that
# fails `git check-ref-format --branch` or holds a character outside `[A-Za-z0-9._/-]`).
set -euo pipefail

usage() {
  echo "usage: trace-matrix.sh <spec-repo> [--repo <target-repo>] [--milestone M<n> | --area <REQ-AREA> | --all] [--ref <branch>]" >&2
  exit 2
}

spec_repo=
target_repo=
scope_kind=all
scope_value=
scope_flags=0
ref=
while [ $# -gt 0 ]; do
  case $1 in
    --repo) [ $# -ge 2 ] || usage; target_repo=$2; shift 2 ;;
    --milestone) [ $# -ge 2 ] || usage; scope_kind=milestone; scope_value=$2; scope_flags=$((scope_flags + 1)); shift 2 ;;
    --area) [ $# -ge 2 ] || usage; scope_kind=area; scope_value=$2; scope_flags=$((scope_flags + 1)); shift 2 ;;
    --all) scope_kind=all; scope_flags=$((scope_flags + 1)); shift ;;
    --ref) [ $# -ge 2 ] || usage; ref=$2; shift 2 ;;
    -*) usage ;;
    *) [ -z "$spec_repo" ] || usage; spec_repo=$1; shift ;;
  esac
done

[ -n "$spec_repo" ] || usage
[ "$scope_flags" -le 1 ] || usage
[[ $spec_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[ -z "$target_repo" ] || [[ $target_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[ "$scope_kind" != milestone ] || [[ $scope_value =~ ^M[0-9]+$ ]] || usage
[ "$scope_kind" != area ] || [[ $scope_value =~ ^[A-Z]+$ ]] || usage
if [ -n "$ref" ]; then
  [[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || usage
  git check-ref-format --branch "$ref" >/dev/null 2>&1 || usage
elif [ "$scope_kind" = milestone ]; then
  ref="release/$scope_value"
fi

checkout=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "trace-matrix.sh: run it from a checkout of $spec_repo" >&2
  exit 2
}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Issue bodies never reach a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/trace_matrix.py "$script_dir/spec-index.py" "$checkout" "$spec_repo" "$target_repo" \
  "$scope_kind" "$scope_value" "$ref" </dev/null
