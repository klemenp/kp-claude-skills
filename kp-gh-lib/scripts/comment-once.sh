#!/usr/bin/env bash
# Post an issue or PR comment only when no existing comment on it contains a marker, so a
# re-run of a skill never stacks a second copy. The kp-* skills' "post once" guards used
# to describe this read-then-post in prose, each slightly differently.
#
# Usage: comment-once.sh <owner/repo> <n> --marker <m> --body-file <f>
#          [--add-label <name> --label-color <hex>]
#
# Arguments are checked before any GitHub call: <n> is a positive integer, the marker is
# non-empty, the body file is readable and its text contains the marker (otherwise a later
# run could never find the comment), and --add-label and --label-color come together, the
# label non-empty.
#
# --add-label: `gh label create <name> --color <hex> --force`, then `gh issue edit <n>
# --add-label <name>`. Both run on every call, posted or not — both are idempotent.
#
# Match: every comment on <n> is read (`gh api --paginate repos/<owner/repo>/issues/<n>/
# comments`, all pages — the endpoint also returns a PR's conversation comments, so <n>
# may be a PR number). A comment matches when its body contains the marker as a plain,
# case-sensitive substring.
#
# Prints one line:
#   exists <id>   a comment already carries the marker (<id> is the oldest such comment);
#                 nothing is posted
#   posted <id>   no comment carried it; the body file was posted as comment <id>
#
# Exit: 0 posted or exists · 1 a gh call failed (nothing on stdout, its stderr passed
# through) · 2 bad arguments.
set -euo pipefail

# Comment text never reaches a shell: Python runs every gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/comment_once.py "$@" </dev/null
