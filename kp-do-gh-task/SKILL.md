---
name: kp-do-gh-task
description: Implement a GitHub work item end-to-end from its own coding-item contract — load exactly the context its body names with read-context.sh, move it to In progress, build it in an isolated worktree until acceptance criteria + tests pass, update the README, commit, push, open a PR, move the item to In review, and post this run's token usage as an issue comment. A body that does not meet the contract is labelled needs-contract and never built; context too ambiguous to build from raises a prioritised, assigned human-decision issue and stops instead. Manual-only.
disable-model-invocation: true
argument-hint: [item-number] [--project <number|owner/number|id>] [--base <branch>]
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

# Do a GitHub task end-to-end

Companion to `kp-sync-spec-tasks` / `kp-resolve-spec-decision`. Takes one GitHub issue
(a `type:coding` item) and **implements it**: drives its project-board status
across the work, builds the change in an isolated git worktree until the
acceptance criteria and the project's own tests/linters pass, updates the README,
commits, pushes, and opens a PR. It builds from the item's body — the coding-item
contract (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*) — and the bounded
context that body names, loaded by `read-context.sh`. Whole spec docs are never read.

Runs **inline (no fork)** on purpose. §9's `report-tokens.sh` sums the session's
top-level transcript, and a forked skill's turns are written to a subagent transcript it
never reads, so a fork would report zero tokens (probed on Claude Code 2.1.270).
`kp-do-gh-task-loop` also greps this skill's headless log for the CLI's usage-limit line,
which a fork has not been probed to print. The git worktree already isolates the
filesystem.

**Goal (success criteria — loop until all are true):** the issue is implemented;
its acceptance criteria are met and demonstrably verified; the README reflects any
new behavior/usage; the change is committed and pushed to a PR that references the
issue; the item's board status is **In review**.

Load a section of `~/.claude/skills/kp-gh-lib/NOTES.md` this skill names only with
`~/.claude/skills/kp-gh-lib/scripts/notes-section.sh '<heading>'`; never open the file
whole. The heading is the name in the reference (`§ *Run state across compaction*` →
`'Run state across compaction'`); for `§ *A* → *B*` it is `B`.

## 0. Setup

**Record the run start time** (`date -u +%Y-%m-%dT%H:%M:%S.000Z`) — §9 sums token
usage from it to the end of the run.

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the **item number** (required; if
   missing, stop and ask for one).
   `--project <number|owner/number|id>` selects the GitHub Project (v2);
   `--base <branch>` overrides the base branch.
2. **Preamble — one call.** `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --issue <n>
   [--project <…>]`, then do what `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with its
   JSON, its exit code, and any `null` board field.

   Keep `.project.owner`, `.project.number`, `.project.id`, `.itemId`, `.itemStatus`,
   `.status.fieldId`, and the **`In progress`** and **`In review`** ids from
   `.status.options`.

## 1. Load the item's context (the gate)

1. **Milestone branch, then the context.** First resolve the branch this item builds
   against and merges into:
   `~/.claude/skills/kp-gh-lib/scripts/milestone-branch.sh <owner/repo> <n> --create`
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone branch*). It prints one JSON
   line; keep its `branch` (`release/M<k>`, or `null` for an item with no milestone)
   and creates a missing `release/M<k>` at the default-branch HEAD. Exit `3`
   (`earlier-unmerged release/M<j>` on stderr — an earlier milestone's merge has not
   happened): **stop**, build nothing, report the stderr line and ping the operator,
   since only a human can unstick it (no `--session-end`):
   `~/.claude/skills/kp-msg-me/scripts/send.sh "kp-do-gh-task <owner/repo>#<n>: stopped — <stderr line>"`.
   Exit `1` or `2`: **stop** and report the message.

   Then load the context — one call:
   `~/.claude/skills/kp-gh-lib/scripts/read-context.sh --code-root <code-root>
   <owner/repo> <n>`, where `<owner/repo>` is §0.2's repo and `<checkout>` is this
   checkout (the §3 worktree does not exist yet). `<code-root>` is `<checkout>` when
   `branch` is `null`, and otherwise the directory
   `~/.claude/skills/kp-gh-lib/scripts/fresh-checkout.sh <checkout> --ref <branch>`
   prints — also when this run was given an explicit `--base`, which affects only the
   worktree and the PR base (§3.1). Its stdout is the **only** item and
   spec input this run has: the `item` block (title and body, human-only fence already
   removed), the goal frame, the `spec:` sections, the `code:` files and the
   `decision:` resolutions the body names — never a whole spec doc, and never the
   issue's comments.
   Exit `3` (something the body names did not resolve) goes to §1.2; exit `1` or `2`
   leaves nothing to build from — **stop** and report the message.
   Then one `gh issue view <n> -R <owner/repo> --json labels,state` for what the
   context blocks do not carry: the type label, the **`needs-contract`** label (§1.2)
   and any **`model:*` label** (§1.6). Never re-read the raw body into context — the
   human-only fence is stripped only in the `read-context.sh` output.
2. **No contract, no build.** The body is the contract, so a body that does not meet it
   is never built from. It fails when any of these holds:
   - the issue carries the **`needs-contract`** label;
   - `read-context.sh` exited `3` in §1.1;
   - `lint-item.py` exits `1` on its body — the family's contract test
     (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*). Write the body
     straight to a file without printing it (`gh issue view <n> -R <owner/repo> --json
     body -q .body > /tmp/item-<n>.md`), then
     `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <owner/repo> --body-file
     /tmp/item-<n>.md --code-root <code-root>` (§1.1's). Exit `2` (bad arguments) or `4` (a
     GitHub or fetch failure) is **not** a contract verdict: **stop the run** with that
     message and label nothing — the same rule `kp-backfill-contract` §1.3 applies.

   On a failure: write the reason — the `FAIL` lines, the `read-context.sh` stderr
   problems, or the pre-existing label — under a `<!-- kp-do-gh-task:needs-contract -->`
   marker to a file, then label and comment in one call:
   `~/.claude/skills/kp-gh-lib/scripts/comment-once.sh <owner/repo> <n> --marker '<!-- kp-do-gh-task:needs-contract -->' --body-file <file> --add-label needs-contract --label-color D93F0B`.
   It adds the `needs-contract` label every time and posts the comment only when no
   comment already carries that marker, so a re-run stacks nothing. Leave the board **Status untouched**, and stop with the report line
   `needs-contract <owner/repo>#<n> | <reason>`. No build is attempted, no worktree is
   opened, no §9 token row is posted (nothing was built), and there is **no fallback to
   reading the spec**: `/kp-backfill-contract` is what converts such a
   body.
3. **Acceptance criteria.** They are the bullets of the body's `### Acceptance
   criteria`, as loaded in §1.1 — never re-derived from a spec. Each bullet's
   `— proof:` part is the verification §4 runs for it, and the body's `### Verify`
   commands are the run that proves the item as a whole. These become the verification
   checklist for §4.
4. **Clarity gate → raise a decision item.** Judge this against the §1.1 context and
   the `### Rules` it quotes — that is the whole of what governs this item. If they, or
   the acceptance criteria, are unclear, ambiguous, contradictory, or silent on
   something that affects behavior, interface, or scope: do **not** start implementing and do **not** invent an
   interpretation. Only such technical and feature unknowns count: build order —
   which item or requirement comes first, which milestone something belongs in, a
   dependency cycle — is never a gap and raises no item here
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *When an item is human-gated*).
   **Never put the ambiguity to the operator as a question and wait
   for an answer.** A headless run (`claude -p`) has no human attached: the question
   goes to stdout, nothing answers it, the run exits 0, and it leaves no GitHub trace
   — which `kp-do-gh-task-loop` §2, reading state rather than stdout, can only
   see as a build failure. **Filing the decision item is how this skill asks.** That
   binds in an interactive run too: even with an operator in the thread who could
   answer immediately, still raise the item and stop, so the run produces the same
   artifacts and a later pass can read the same trail. Instead — the same way
   `kp-sync-spec-tasks` §5 / `kp-resolve-spec-decision` create human-decision items —
   **create one here and stop this run:**
   - **Dedup first.** Before creating anything, search for an existing open decision
     issue for this gap: `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <owner/repo> blocks
     <spec-ref>` (open issues whose body carries `blocks: <spec-ref>`). If one already exists,
     **reuse it** (skip creation), make sure it is still assigned / prioritised / on
     the board, repair it per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising
     a human-gated item* when it carries `goal-ref:`, and jump to the stop step below —
     never raise a second decision issue for the same gap on a re-run.
   - **Type it by the nature of the gap:** `type:decision` (needs a binding design
     choice), `type:question` (needs clarification), or `type:conflict` (specs
     contradict on what to build). Create the label with `gh label create -R <repo> ... --force` if
     absent. It is human-gated, so it gets **no** `model:*` label.
   - **Title and body** follow the human-gated item body convention in
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body*. The title is
     the question in plain words; the body puts the question first, and the gap's
     evidence (REQ/AC refs, file:line) goes in `<details>`. The marker block carries
     the **same `spec-ref`** as this coding item and a `blocks: <spec-ref>` line (the
     gap blocks this item). "To resolve" carries the pasteable resolution prompt
     `/kp-resolve-spec-decision <n>`, where `<n>` is the **created issue's own
     number**, never a metavariable and never a bare command.
   - **Climb before raising.** With the item drafted, apply
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item*: it
     may quote a domain goal in the Recommendation, gate the item on an open goal
     question, or raise a goal question in its place. A goal question keeps the
     `spec-ref:` and `blocks: <spec-ref>` lines, so the dedup above and the stop below
     treat it as this gap's item.
   - **Decide it yourself when the answer is settled.** When the item is the technical
     `type:decision` itself (not a goal question raised in its place) and every
     Recommendation is `confidence: high`
     (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items*), write
     that section's decision comment to `<scratchpad>/decided.md` with `__ISSUE__` and
     add `--decided-body-file <scratchpad>/decided.md` to the call below. The stop below
     is unchanged: the next `kp-do-gh-ready-items` pass resolves the item, and once it
     closes, `kp-do-gh-task-loop` §1.3 no longer finds it.
   - **Create — one call.** Write the body to a file carrying the literal token
     `__ISSUE__` where its own number goes, create its labels, then:

     `~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo <owner/repo> --title "…" --body-file /tmp/decision.md --label <type> … --project <.project.owner>/<.project.number> --priority top --status Ready --assign-owner --origin <owner/repo>#<n> --cache <scratchpad>/milestone-current-<.project.owner>-<.project.number>.json`

     It creates the item — the decision issue, or the goal question raised in its
     place — substitutes `__ISSUE__`, assigns the project owner, adds it to the board,
     sets the top `Priority` and Status **`Ready`**, and places and links it per
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Every new item has a milestone* with this
     coding item as `--origin` (`kp-gh-lib/SKILL.md` § *`create-item.sh`*). `Ready` is
     chosen rather than inherited from the board's default: it is the most visible
     column, and `kp-do-gh-ready-items` §1.6 lists human-gated types it finds there in
     every pass's report until it is resolved; `create-item.sh` pings the operator once,
     when it files the item — never for a creator-decided item whose comment posted and
     that landed Ready. Exit `1` means nothing was created: stop and report it. Every later step
     is best-effort: note each `skipped` entry (a `substitute` one means the resolution
     line still carries the token) and never fail the run over one. A decision issue
     the dedup above reused keeps its parent and is not placed.
   - **Check the edge.** Once the decision issue exists (created or reused), run
     `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh --project
     <.project.owner>/<.project.number> <owner/repo>#<n> <owner/repo>#<decision>`. On
     `cycle` or `drop-earlier`, edit the `blocks: <spec-ref>` line out of the decision's
     body (`gh issue edit --body-file`) and report the dropped edge; on `pull-forward`,
     re-parent the decision under `pullForwardEpic` per
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Edges stay inside one milestone*. Exit `1`
     or `2` is noted, never fatal.
   - **Stop.** Comment on this coding item linking the decision issue **only if no
     prior "blocked on #<decision>" comment already exists** (check
     `gh issue view <n> --json comments`), then halt: do **not** mark it In progress,
     do **not** open a worktree, do **not** implement. Report the raised issue and that the coding item is blocked on it,
     with its report line from NOTES § *Every new item has a milestone*,
     and run §9 token reporting before exiting.
5. **Resumability.** If a branch `task/<n>-<slug>` or an open PR for this issue
   already exists, continue that work (check out the existing branch in the
   worktree) instead of starting over.
6. **Honor the model label.** If the issue carries a `model:*` label (e.g.
   `model:opus` / `model:opus-xhigh` / `model:haiku`, set by `kp-decompose-gh-task`),
   **report the recommended model prominently before touching code.** The label's
   value is a tier, `<model>` or `<model>-<effort>` with effort one of `low`, `medium`,
   `high`, `xhigh`, `max`; `~/.claude/skills/kp-gh-lib/scripts/model-label.sh <tier>`
   splits it. Report the model part and the labelled effort (or "no effort"). A
   session cannot switch its own model or effort mid-run, so this is advisory: if the
   model you are running under does not match the model part, or the tier names an
   effort and the environment variable `KP_EFFORT` (set by `run-child.sh` to the effort
   it launched this child with) is unset or different, **surface the mismatch** (so the
   operator can relaunch at the right tier) and proceed — never silently ignore it, and
   never hard-stop (headless loops must keep running). Carry the recommended tier into
   the §8 report and the §9 token comment. If there is no `model:*` label, note "no
   model label" and proceed.

## 2. Mark In progress

Set the board status to **In progress** before touching code:
`~/.claude/skills/kp-gh-lib/scripts/set-status.sh <project-id> <item-id> <status-field-id>
<in-progress-option-id>`.
Skip only if it is already In progress. Report the transition.

## 3. Worktree on a new branch

Never edit the main working tree in place.

1. **Worktree — one call.** The **base** `<base>` is one bare branch name (e.g.
   `release/M7`, `main`) used for the worktree, the run state and the PR, taken in this
   order: the explicit `--base` given to this run, else §1.1's milestone `branch`, else
   §0.2's `defaultBranch`. A resumed run recomputes it the same way
   (`milestone-branch.sh --create` is idempotent). From this checkout,
   `~/.claude/skills/kp-gh-lib/scripts/worktree.sh task <n> <slug> [--base …]`:
   - explicit `--base`: pass it to `worktree.sh` as given;
   - milestone branch (no explicit `--base`): first `git fetch origin <base>` in this
     checkout, then pass `--base origin/<base>`;
   - default branch: pass no `--base`.

   `worktree.sh` reusing an existing branch ignores `--base`, and an already-open PR
   keeps its base. `<slug>` is a short kebab summary of the title. It picks the base (`--base`, else `origin/HEAD`, else the current
   branch), then reuses `../<repo-name>-task-<n>` or the legacy `../task-<n>` when this
   checkout already has it, or else adds `../<repo-name>-task-<n>` on branch
   `task/<n>-<slug>` — new from the base, or the existing branch when resuming
   (`kp-gh-lib/SKILL.md` § *`worktree.sh`*). Use the printed `path` wherever
   `../<repo-name>-task-<n>` appears below. A non-zero exit means there is no worktree:
   stop and report its stderr verbatim.
2. **Write the run state** per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Run state
   across compaction*: `issue: #<n>`, `branch: task/<n>-<slug>`, `base: <base>`, the
   absolute worktree path and every §1.3 acceptance criterion unchecked, plus `pr: #<pr>` when §1.5 found
   an open PR.

## 4. Implement → verify (loop)

Work **surgically** inside the worktree: change only what the item requires; match
existing style; don't refactor unrelated code (operator conventions §3).

1. Implement the change to satisfy every acceptance criterion from §1.3.
2. **Context gap.** If building shows the loaded context is missing something the build
   needs, load **one more named section** — never a whole doc, and never by reading the
   spec file. Locate it with `~/.claude/skills/kp-gh-lib/scripts/spec-index.py
   <owner/repo>@<sha> [<path>]`, then load it the way everything else was loaded: append
   a `spec: <owner/repo>@<sha>:<path>#<anchor>` line to a copy of the body and re-run
   `~/.claude/skills/kp-gh-lib/scripts/read-context.sh --code-root <worktree>
   --body-file <copy> --repo <owner/repo>`. Then:
   - record it in the PR body (§6.3) as
     `context-gap: <owner/repo>@<sha>:<path>#<anchor> — <why the item's context did not
     cover it>`, one line per gap;
   - if the gap changes behavior, interface or scope, it is an ambiguity, not a
     shortfall: raise the human-gated item per §1.4 and stop.
3. **Verify.** Run the body's `### Verify` commands and each criterion's `proof:` from
   §1.3, in the worktree. Add the project's own tests, linters and build (from its
   `CLAUDE.md` / README / Makefile / package manifest) where the body's commands do not
   cover what changed.
   For a bug item, add a test that reproduces the bug first, then make it pass.
   Run each `### Verify` command, each `proof:` command and each project test, lint
   or build command through `~/.claude/skills/kp-gh-lib/scripts/run-verify.sh --log
   <scratchpad>/verify-<n>-<k>.log -- <command>`, where `<n>` is the item number and `<k>`
   counts this run's commands from 1. It keeps the output in the log: read its result
   line and the tail it prints on `fail` or `timeout`, and open the log by line range
   with `Read` only when the tail does not show the cause. A `result=timeout` means the
   command is too long for one foreground call, not that it failed: re-run it once with
   the detached pattern of `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a
   headless session*. A command the project's docs say takes longer than 9 minutes
   goes straight to that pattern. The printed tail is the verbatim failure text
   §4.5 reports.
   §6's commit, push and PR wait until each run has completed in this same turn.
4. **Update CI when verification changes.** If the change introduces a new
   verification/testing step that CI should run — a new test suite, lint/type
   check, build target, service dependency, or required env/secret — update the
   GitHub Actions workflows under `.github/workflows/` so the pipeline runs it too.
   Keep edits surgical: add the missing step/job to the existing workflow rather
   than rewriting it, mirror the commands you ran locally in §4.3, and don't touch
   unrelated CI config. If no workflow exists, note that CI was not updated rather
   than scaffolding one unasked. When nothing about verification changed, skip this.
5. **Loop** until acceptance criteria are met **and** tests/linters/build are
   green. Report any failures **verbatim**; never claim done without verification.
   Each time a criterion's verification passes, rewrite the run-state file (§3.2) with
   it ticked and how it was verified.
   If a criterion cannot be met (blocked, contradicts code reality), stop and
   report it rather than papering over it.

## 5. README

Update the README only if this change adds or alters how the project is run,
configured, or used. Keep it to what changed — no changelog, no "what I did"
prose. If nothing user-facing changed, note "no README change".

## 6. Commit, push, PR

1. **Commit** in the worktree, imperative subject ≤72 chars, body explaining *why*
   if non-obvious, referencing the issue:
   `git -C ../<repo-name>-task-<n> add -A` then commit **only if something is
   staged** (so a resumed run whose change already landed doesn't error or stack a
   duplicate commit):
   `git -C ../<repo-name>-task-<n> diff --cached --quiet ||
   git -C ../<repo-name>-task-<n> commit -m "<subject>" -m "Refs #<n>. <why>"`.
   One logical change; squash WIP before pushing.
2. **Push:** `git -C ../<repo-name>-task-<n> push -u origin task/<n>-<slug>`.
3. **PR** (use a closing keyword to link the issue). **Check for an
   existing PR first** — `gh pr list --head task/<n>-<slug> --json url,number`: if one
   exists, the §6.2 push already updated it, so capture its URL and skip creation
   (`gh pr create` errors when a PR is already open for the head branch). Otherwise
   create it:
   `gh pr create --base <base> --head task/<n>-<slug> --title "<title> (#<n>)"
   --body "Closes #<n>. <summary of change + how acceptance criteria were verified>"`.
   The body carries one `context-gap: <ref> — <why>` line per §4.2 gap, or none when
   the item's own context covered the build.
   `<base>` is §3.1's. The `Closes #<n>` (equivalently `Fixes #<n>`) keyword links the
   PR to the issue; GitHub closes it only on a default-branch merge, otherwise
   `kp-review-gh-pr` §5 or the pr-loop close-out closes it. Once the PR is created or
   found, add `pr: #<pr>` to the run-state file (§3.2).

If push or PR creation fails (no remote, no write access), report it, leave the
worktree in place for inspection, and **do not** move the item to In review.

## 7. Mark In review

On a successful push + PR, set the board status to **In review**:
`~/.claude/skills/kp-gh-lib/scripts/set-status.sh <project-id> <item-id> <status-field-id>
<in-review-option-id>`.

## 8. Clean up + report

On success, remove the worktree (`git worktree remove ../<repo-name>-task-<n>`) — the
PR is the deliverable. On any failure or unmet criterion, **leave the worktree** so the
operator can inspect, and say so.

Report: the item, the resolved project, the recommended model (from the `model:*`
label) and whether the running model matched it, the context loaded (`read-context.sh`
blocks and total bytes) and any `context-gap:` line, acceptance criteria
and how each was verified (with the test/lint command output summary), the README
change or "none", the branch and its base (§3.1), the commit subject, the PR URL, the final board
status, and the token-usage totals posted in §9.

## 9. Report token consumption

As the **final action of every run** — on success, on any failure or early stop once
implementation has begun, *and* on a clarity-gate stop that raised a decision item
(§1.4) — post this skill run's token usage as a comment on the issue. This report is **best-effort**: never let it block or fail the deliverable.

1. **Record this run's row**, from the session's working directory:
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/report-tokens.sh "<run-start-timestamp from §0>" \
     "<!-- kp-do-gh-task:token-usage -->" <owner/repo> <n>
   ```
   It adds or rewrites this run's row in the marked table and prints it; the table is
   described in `~/.claude/skills/kp-gh-lib/NOTES.md` § *Token-usage report*. A
   non-zero exit means nothing was written: note it and finish the run.
2. **Delete the run-state file** (§3.2) on every run end, success or stop:
   `rm -f ~/.claude/skills/kp-gh-lib/state/run-"$CLAUDE_CODE_SESSION_ID".md`.

## Invariants

- **The body is the contract; whole spec docs are never read.** §1.1 loads the item and
  its named spec sections, code files and decisions only through `read-context.sh`; a
  gap found while building is one more named section (§4.2), recorded as `context-gap:`
  in the PR body.
- **No contract, no build** (§1.2): a body carrying `needs-contract`, failing
  `lint-item.py`, or whose context does not resolve is labelled `needs-contract` and
  commented on — Status untouched, no worktree, no build, no fallback to the spec.
- **Don't start with unresolved ambiguity** (§1.4): raise a prioritised, assigned
  human-decision item (`type:decision`/`question`/`conflict`) carrying this coding
  item's `spec-ref` and a `blocks:` marker, then stop — never invent an
  interpretation or implement past the gap.
- **Honor the `model:*` label** (§1.6): report the recommended model at start; a
  mismatch with the running model is surfaced, never silently ignored.
- **In progress → In review** are the only board transitions this skill makes; it
  never closes the issue directly. The PR carries a `Closes #<n>` keyword: GitHub
  closes the issue only on a default-branch merge; otherwise `kp-review-gh-pr` §5 or
  the pr-loop close-out closes it and marks the board item done.
- Never edit the main working tree — all code changes go through the worktree
  branch and a PR.
- Idempotent/resumable: re-running for the same item reuses the existing
  worktree/branch and PR (check-before-create), commits only when something changed,
  raises at most one decision issue per gap, and upserts the token-usage comment —
  never duplicating work.
- Never claim acceptance criteria are met without running the verification and
  showing the result.
- **Never end the turn with a started command still running** — builds, tests and lints
  wait in the foreground per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a
  headless session*; never `run_in_background` or `Monitor`.
