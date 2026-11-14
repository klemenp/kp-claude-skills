#!/usr/bin/env bash
# The goal-question mechanics of NOTES.md § *Goal questions* and § *Before raising a
# human-gated item*: rewrite a decision in place as a goal question (escalate), raise one
# in place of a drafted technical item (create), and put the original back once the
# goal's spec PR merges (restore). The escalation comment is the restore source: it holds
# the original title and body verbatim in a backtick fence one longer than the body's
# longest backtick run, so no code block in the body can close it.
#
# Usage: goal-question.sh escalate --repo <owner/repo> --issue <n> --goal-title <t>
#                          --goal-body-file <f> --goal-ref <key> --missing-fact <text>
#                          [--creator <skill>]
#        goal-question.sh create --repo <owner/repo> --technical-body-file <f>
#                          --technical-title <t> --technical-type <label>
#                          --goal-body-file <f> --goal-title <t> --goal-ref <key>
#                          --missing-fact <text> --creator <skill> [--label <l>…]
#                          [--project <owner/number>] [--priority top] [--assign-owner]
#                          [--origin <owner/repo#n>] [--parent <owner/repo#n>]
#        goal-question.sh restore --repo <owner/repo> --issue <n> --pr-url <url>
#
# Every step checks before it acts, so a re-run finishes a partial call. Prints one JSON
# object on stdout:
#   {"issue": 12, "action": "escalated" | "already-escalated" | "created" | "restored" | null,
#    "commentId": 123 | null, "title": "…", "labels": [...], "skipped": [...]}
# with the title and labels as they are after the call; a failed step is recorded as
# {"step": "<name>", "reason": "<text>"} in `skipped`.
#
# create-item.sh is found through KP_GH_LIB_BIN, default this script's own directory.
# A fresh escalation pings the operator on Telegram through the send script at
# KP_MSG_ME_SEND (default ~/.claude/skills/kp-msg-me/scripts/send.sh); a failed send is a
# `notify` entry in `skipped`. `create` pings through create-item.sh; `restore` never does.
#
# Exit: 0 done · 1 a GitHub failure (after a change, `skipped` names the step) ·
#       2 bad arguments · 3 the escalation comment could not be posted (nothing changed,
#       or the created issue was reverted to the technical item).
set -euo pipefail

KP_GH_LIB_BIN="${KP_GH_LIB_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export KP_GH_LIB_BIN

exec python3 "$(dirname "${BASH_SOURCE[0]}")"/py/goal_question.py "$@" </dev/null
