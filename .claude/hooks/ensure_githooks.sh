#!/usr/bin/env bash
# SessionStart: point this clone at .githooks.
#
# core.hooksPath lives in .git/config, which is per-clone and never inherited from the
# remote -- so a fresh clone of this repo starts with the board -> worktree -> PR hooks
# switched off, and the operator has to remember to enable them. .claude/settings.json
# is tracked, so any Claude session in any clone can do it instead.
set -euo pipefail

if [[ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
  exit 0
fi

if [[ "$(git config --get core.hooksPath || true)" == ".githooks" ]]; then
  exit 0
fi

git config core.hooksPath .githooks
echo "Enabled this clone's git hooks: core.hooksPath = .githooks"
