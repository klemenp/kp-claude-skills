#!/usr/bin/env bash
# Decide whether a spec PR a decision resolver opened is structurally clean enough to merge
# without the review ⇄ fix loop (kp-resolve-spec-decision §4.7). Read-only, so it may be
# run on a merged PR.
#
# Usage: spec-pr-check.sh <owner/repo> <pr> --decision <owner/repo>#<n> [--from-file <dir>]
#
# Each `spec-ref:` key of the decision issue (outside the human-only fence and code
# fences) is resolved to a `<path>#<anchor>` and line extent through spec-index.py, the
# way lint-item.py resolves one: `REQ-<AREA>-<nnn>` matches a REQ section by anchor in any
# file, `<doc-slug>#<heading-slug>` a heading anchor in the file whose name slugs to
# `<doc-slug>`. Rules, one `FAIL <rule>: <detail>` line per problem, else `ok`:
#   untouched-ref  a `spec-ref:` section has no changed line inside its head-side extent,
#                  or no longer exists at the head
#   no-backref     a touched `spec-ref:` section (children included) carries no
#                  `decided in <owner/repo>#<n>` ref to this decision at the head
#   identity       a `spec-ref:` section's heading (level, number, title) differs between
#                  the base and head indexes, or the section is absent from the head index
#   outside-spec   a changed file matches none of the spec globs: the PR repo's
#                  `.claude/spec-sync.json` `specGlobs` on its default branch (never the
#                  PR head), else docs/specs/**/*.md, specs/**/*.md, SPEC*.md
#   ci             a check at the head whose bucket is not `pass` or `skipping`, pending
#                  included; no checks at all passes (spec repos have no CI)
#
# --from-file <dir> reads diff.patch, base, head (one SHA each), issue.json (`{"body"}`),
# base-index.json, head-index.json (spec-index.py output), checks.json (`gh pr checks
# --json name,bucket`) and spec-sync.json (the default branch's copy; absent = none)
# instead of calling GitHub (fixtures).
#
# Exit: 0 ok · 1 at least one FAIL · 2 bad arguments · 4 a GitHub or fetch failure.
set -euo pipefail

python3 "$(dirname "${BASH_SOURCE[0]}")"/py/spec_pr_check.py "$(dirname "$0")" "$@" </dev/null
