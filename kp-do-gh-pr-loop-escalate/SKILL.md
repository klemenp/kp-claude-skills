---
name: kp-do-gh-pr-loop-escalate
description: Raise the blocking human-decision issue for a PR whose review ⇄ fix loop stopped converging — the escalation step of kp-do-gh-pr-loop, launched by kp-gh-lib/scripts/pr-loop.sh as one headless child with the loop's evidence file. Dedups on the PR's blocks marker, types and writes the item per the human-gated body convention, climbs to the spec's goals, assigns, prioritises and places it, comments "blocked on #<d>" on the PR and its linked item, and moves the item to Blocked; filing the issue pings the operator on Telegram through create-item.sh. Never merges, fixes or reviews. Not for direct use.
disable-model-invocation: true
argument-hint: <pr-number> --project <owner/number> --evidence <file>
allowed-tools: Read, Grep, Glob, Bash
---

# Escalate a stalled PR loop

The one step of `kp-do-gh-pr-loop` that needs judgement: turning the loop's evidence into
a human-gated item the operator can act on. `~/.claude/skills/kp-gh-lib/scripts/pr-loop.sh`
runs the loop itself and launches this skill as a headless child once, when the loop
stops; it then reads the raised item back by its `blocks: <R>#<pr>` marker.

Same pattern as `kp-do-gh-task` §1.4 / `kp-sync-spec-tasks` §5, so the operator resolves
it with the same `/kp-resolve-spec-decision` flow.

Runs **inline (no fork)**: `pr-loop.sh` reads this child's log for the CLI's usage-limit
line through `run-child.sh`, and a fork has not been probed to print it.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS`. Parse them.** The first bare token is the **PR
   number**; `--project <owner/number>` and `--evidence <file>` are required. A missing
   one is a launch bug, not a question: report it and stop.
2. **Read the evidence file** (JSON, written by `pr-loop.sh`): `reason`, `cycles`,
   `stalls`, `lastFindings` (the last denial's `### Findings (for the build agent)`
   list), `mergeStateStatus`, `declined` (the finding `kp-fix-pr` did not action, and
   why), `logs` (every child log path), `issue` (the linked item, or null),
   `referenceOnly`, `specRef` and `decision` (an open human-gated issue the loop already
   found, or null). A `referenceOnly` item is handled as no linked item throughout.
3. **Preamble — one call.** `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --pr <pr>
   --project <project>`, then do what `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with
   its JSON, its exit code, and any `null` board field. `<R>` is `.repo`. Keep
   `.project.owner`, `.project.number`, `.project.id`, `.status.fieldId`, the
   **`Blocked`** and **`Ready`** ids from `.status.options`.
4. **The linked item's project item id** is `.itemId` when the preamble's `.issue` is
   the evidence's `issue`; otherwise, for a linked item that is not reference-only,
   `~/.claude/skills/kp-gh-lib/scripts/item-id.sh <R> <issue> <project-id>`
   (best-effort; used by §1.5).

## 1. Raise the blocking human-decision issue

1. **Dedup first.** Search for an existing open decision issue for this PR before
   creating anything: `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <R> blocks <R>#<pr>`
   (open issues whose body carries `blocks: <R>#<pr>` in either reference form); also treat the evidence's
   `decision` issue as an existing one. If one exists, **reuse it** — make sure it
   is still assigned, prioritised, and on the board, and repair it per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item* when it
   carries `goal-ref:` — and skip to step 5. Never raise a second decision issue for
   the same impasse on a re-run.
2. **Type it by the nature of the impasse:** `type:decision` (needs a binding call —
   stall, merge-blocked, max-cycles), `type:conflict` (reviewer and fixer disagree —
   `unactionable-finding`), or `type:question` (needs clarification). Create the label
   with `gh label create -R <R> … --force` if absent. It is human-gated, so it gets
   **no** `model:*` label. Only a technical or feature unknown is typed as an impasse
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *When an item is human-gated*): a PR held
   only by build order — an unmerged dependency or an earlier milestone — raises no item;
   report the reason and stop with the PR open.
3. **Title and body** follow the human-gated item body convention in
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body*. The title is the
   question you need answered, in plain words. The options are the calls that would
   unstick the PR, described by their effect, with no recommendation dressed as a fact
   and never at `confidence: high`: which call unsticks a PR is the operator's, so an
   escalate item is never creator-decided
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items*).
   Each part goes in its slot in the convention:
   - **marker block:** the same **`spec-ref:`** as the linked coding item (the
     evidence's `specRef`), if it has one; **`blocks: <R>#<pr>`** and, when there is a
     linked item, **`blocks: <R>#<issue>`**;
   - **"Why it matters":** which PR (and linked item) is blocked, and what stays stuck
     until the call is made;
   - **`<details>`:** the **reason** and the **evidence** from the evidence file: cycles
     run, stall count, the last denial's `### Findings (for the build agent)` list,
     `mergeStateStatus`, any finding `kp-fix-pr` declined and why, and the log paths;
   - **"To resolve":** the pasteable resolution prompt `/kp-resolve-spec-decision <n>`,
     where `<n>` is the **created issue's own number**, never a metavariable and never a
     bare command, and the pasteable resume prompt `/kp-do-gh-pr-loop <pr>` for after
     it is resolved (the PR number is known already, so substitute it inline).
   - **Climb before raising.** With the item drafted, apply
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item*. A goal
     question raised in its place keeps the `spec-ref:` and both `blocks:` lines and the
     resume prompt, so step 1's dedup and step 5's park treat it as this impasse's item.
4. **Create — one call.** Write the body to a file carrying the literal token
   `__ISSUE__` where its own number goes, create its labels, then:

   `~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo <R> --title "…" --body-file /tmp/decision.md --label <type> … --project <.project.owner>/<.project.number> --priority top --assign-owner --origin <R>#<issue> --cache <scratchpad>/milestone-current-<.project.owner>-<.project.number>.json`

   with no `--origin` when the evidence has no linked `issue`. It creates the item —
   the decision issue, or the goal question raised in its place — substitutes
   `__ISSUE__`, assigns the project owner, adds it to the board, sets the top
   `Priority`, and places and links it per `~/.claude/skills/kp-gh-lib/NOTES.md`
   § *Every new item has a milestone* (`kp-gh-lib/SKILL.md` § *`create-item.sh`*).
   Exit `1` means nothing was created: report it and stop. Every later step is
   best-effort: note each `skipped` entry (a `substitute` one means the resolution line
   still carries the token) and never fail the escalation over one. A decision issue
   step 1 reused keeps its parent and is not placed.
   Then, when there is a linked item, check its edge once the decision issue exists
   (created or reused): `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh --project
   <owner>/<number> <R>#<issue> <R>#<decision>`. On `cycle` or `drop-earlier`, edit the
   `blocks: <R>#<issue>` line out of the decision's body (`gh issue edit --body-file`)
   and report the dropped edge; on `pull-forward`, re-parent the decision under
   `pullForwardEpic` per NOTES § *Edges stay inside one milestone*; exit `1` or `2` is
   noted, never fatal. The `blocks: <R>#<pr>` line is never checked — a PR has no
   milestone.
5. **Link, park, stop.**
   - Comment on the **PR** linking the decision issue, **only if no prior
     "blocked on #<decision>" comment exists** (`gh pr view <pr> -R <R> --json
     comments`); same guarded comment on the **linked issue**, when there is one.
   - Move the linked board item **→ `Blocked`** when there is one (best-effort; if the
     board has no such option, leave it where the last child put it and note that):
     `~/.claude/skills/kp-gh-lib/scripts/set-status.sh <project-id> <item-id>
     <status-field-id> <blocked-option-id>`.
   - **Leave the PR open** and leave any child worktree the failing run left behind —
     the operator needs both to inspect.
   - **End the run.** Never merge, never force, never launch a review or fix.

## 2. Report

Print the decision issue raised or reused (`#<d>`, its URL and type) or why none was
raised, its report line from NOTES § *Every new item has a milestone* for an issue §1.3
created (with `create-item.sh`'s `notify` skip, if any — filing the issue is what pings
the operator), the comments posted or skipped, and the board move.
`pr-loop.sh` reads the outcome from GitHub, never from this output.
