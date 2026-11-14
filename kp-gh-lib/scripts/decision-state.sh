#!/usr/bin/env bash
# Classify a human-gated item's comments: which agent, session and human comments can carry
# its decision, and the restored / no-decision / research-findings markers around them.
# `kp-resolve-spec-decision`, `kp-resolve-spec-decision-auto` and `kp-resolve-spec-research`
# used to restate these marker rules in prose, each slightly differently.
#
# Usage: decision-state.sh <owner/repo> <n> [--from-file <json>]
#
# Reads the issue's comments with one paginated REST call (no GraphQL) and prints:
#   {"cutoffId": id|null,
#    "agent": {"id", "skill", "url"}|null,
#    "session": {"id", "url", "body"}|null,
#    "latest": "agent"|"session"|null,
#    "humanCandidates": [{"id", "url", "body"}],
#    "noDecision": {"id", "url", "newerDecision": bool}|null,
#    "findings": {"id", "url"}|null}
#
# A marker counts only as a whole trimmed line. Order ("latest", "after", "newer") is by
# `created_at`, ties broken by comment id.
#   cutoffId        the latest `<!-- kp-resolve-spec-decision:restored -->` comment; every
#                   field but noDecision considers only comments after it.
#   agent           the latest `<!-- decision-source: kp-<skill> -->` comment.
#   session         the latest `<!-- decision-source: claude-code-session -->` comment.
#   latest          which of agent / session was posted later.
#   humanCandidates the comments after the newest of cutoff, agent and session that are not
#                   skill output and not by a `Bot` user, oldest first. Skill output has a
#                   line containing `<!-- kp-` or `<!-- decision-source:`, or a first
#                   non-blank line starting `Resolved →`, `Closed as won't-do` or
#                   `Goal recorded →`. Whether one picks an outcome is the caller's call.
#   noDecision      the latest `<!-- kp-resolve-spec-decision:no-decision -->` comment over
#                   all comments; newerDecision when agent or session was posted after it.
#   findings        the latest `<!-- decision-source: kp-resolve-spec-research -->` comment.
#
# --from-file <json>: `{"args": [...], "comments": [<REST comment objects: id, html_url,
#   created_at, user {login, type}, body>]}` stands in for the GitHub read (fixtures).
#
# Exit: 0 read (including no comments) · 1 a GitHub call failed · 2 bad arguments.
set -euo pipefail

# Comment bodies never reach a shell: Python runs the gh call as an argument vector.
python3 "$(dirname "${BASH_SOURCE[0]}")"/py/decision_state.py "$@" </dev/null
