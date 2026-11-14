---
name: kp-fix-pr
description: Fix the findings of a denied (REQUEST_CHANGES) GitHub PR review end-to-end — read the reviewer's agent-actionable findings (skipping every human-only section), reproduce/fix each in an isolated worktree on the PR branch until the project's tests/linters/build pass, update the docs the fix affects, commit, push to update the same PR, move the board In progress → In review so the reviewer re-picks it, and post this run's token usage as a PR comment. Acts only on a PR whose latest verdict requests changes — delivered as a formal REQUEST_CHANGES review or, on a self-authored PR, a marked verdict comment; idempotent and resumable. Manual-only.
disable-model-invocation: true
argument-hint: [pr-number] [--project <number|owner/number|id>]
allowed-tools: Read, Grep, Glob, Edit, Write, Agent, Bash
---

# Fix a denied PR review end-to-end

Closes the loop opened by `kp-do-gh-task` (build → PR → **In review**) and
`kp-review-gh-pr` (review → `REQUEST_CHANGES` + findings comment → board back to
**In progress**). This skill takes one PR number, reads the reviewer's
**agent-actionable findings** — deliberately skipping every section the reviewer
marked for humans — **fixes** them in an isolated worktree on the PR branch until the
project's own tests/linters/build pass, pushes to update the same PR, and moves the
board **In progress → In review** so `kp-review-gh-pr` re-judges it.

Runs **inline (no fork)** on purpose, like its siblings: §8's `report-tokens.sh` reads
the session's top-level transcript, which holds none of a forked skill's usage (see
`kp-do-gh-task`), and `kp-do-gh-pr-loop` greps this skill's log for the CLI's usage-limit
line, which a fork has not been probed to print. The git worktree isolates the
filesystem.

The findings are the work list — **not** a fresh acceptance re-derivation. The
reviewer already did the independent pass; this skill's job is to make the listed
findings true and verify them, reading the issue/spec only to fix correctly.

**Goal (success criteria — loop until all are true):** every finding from the denied
review is addressed and demonstrably verified; the project's tests/linters/build are
green in the worktree; the docs the fix affects are updated; the change is committed
and pushed to the existing PR; the board status is **In review**.

Load a section of `~/.claude/skills/kp-gh-lib/NOTES.md` this skill names only with
`~/.claude/skills/kp-gh-lib/scripts/notes-section.sh '<heading>'`; never open the file
whole. The heading is the name in the reference (`§ *Run state across compaction*` →
`'Run state across compaction'`); for `§ *A* → *B*` it is `B`.

## 0. Setup

**Record the run start time** (`date -u +%Y-%m-%dT%H:%M:%S.000Z`) — §8 sums token
usage from it to the end of the run.

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the **PR number** (required; if
   missing, stop and ask for one). `--project <number|owner/number|id>` selects the
   GitHub Project (v2).
2. **Preamble — one call.** `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --pr <n>
   [--project <…>]`, then do what `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with its
   JSON, its exit code, and any `null` board field.

   Keep `.project.id`, `.itemId`, `.itemStatus`, `.status.fieldId` and the
   **`In progress`** and **`In review`** ids from `.status.options`.

## 1. Load the PR + the denied verdict (the fix basis)

1. **Read the PR.** `gh pr view <n> --json
   number,title,body,headRefName,baseRefName,author,state,isDraft,labels,files,url,mergeable,mergeStateStatus`.
   If the PR is `MERGED` or `CLOSED`, stop and report it (idempotency — never push to
   a closed PR). If it is a **draft**, stop and report.
2. **Find the latest denied verdict — a formal review *or* a marked verdict comment.**
   `kp-review-gh-pr` records a verdict as a formal review when it can, but GitHub rejects
   a formal review on a **self-authored PR**, so there it posts the same body as a marked
   issue comment instead. One call reads both channels:
   `STATE=$(~/.claude/skills/kp-gh-lib/scripts/pr-verdict-state.sh <owner/repo> <n> --reviews)`.
   Its `latest` is the newest verdict across them (`channel` `review` or `comment`, with
   `verdict`, `at` and `id`), and `fixNeeded` is true only when that verdict requests
   changes and no §6 fix summary is newer than it. A marked comment is an approval only on
   a `verdict: APPROVED` line; anything else — including the pre-2026-09 format with no
   `verdict:` line — is a denial, and a legacy PR's single upserted comment is simply the
   only entry.
   **Stop — "nothing to fix" — exactly when `.fixNeeded` is `false`** (idempotency: the
   newest verdict is an approval, there is no verdict at all, or the denial was already
   addressed and awaits re-review — a re-run after a successful fix is a no-op until a new
   denial arrives). Otherwise the work list for §1.3 is:
   - when `.latest.channel` is `comment`: `.denial.findings` — already reduced to the
     `### Findings (for the build agent)` section, so §1.3's strip has nothing left to do
     on it;
   - when it is `review`: that formal review's body,
     `gh api repos/{owner}/{repo}/pulls/<n>/reviews/<.latest.id> --jq .body`, stripped by
     §1.3.
3. **Strip every human-only section before reading findings into context.** Two
   conventions, both skipped:
   - The **`<!-- human-only:start (not LLM/spec context) -->` … `<!-- human-only:end
     -->`** fence: everything between the markers is a human reading aid only — do
     **not** read it into context or act on it. The start marker may carry trailing
     annotation text; match it loosely. If a start marker has no matching end marker,
     drop everything from the marker to the end of the body.
   - The **`### TL;DR (for humans)`** section of the denied-verdict body (the prose
     summary `kp-review-gh-pr` §6 emits, in a formal review or a verdict comment): skip
     from that heading up to the next `---` or same-level heading.
   Read only the **`### Findings (for the build agent)`** section as the work list.
4. **Gather the rest of the work list.**
   - **Inline review comments:** `gh api repos/{owner}/{repo}/pulls/<n>/comments`
     (each carries `path`, `line`, `body`). Treat unresolved ones as findings; apply
     the same human-only strip to each body.
   - **Failing CI checks:** any the findings cite, plus those
     `~/.claude/skills/kp-gh-lib/scripts/ci-failure-excerpt.sh <owner/repo> <n>` prints —
     run it once and treat each printed block (check, URL, failed step, the failed-step
     log's last lines) as a finding to reproduce and fix. Open a full log only when a
     block says `log: unavailable` or its excerpt does not show the cause.
5. **Context, not re-derivation.** Find the linked issue with
   `~/.claude/skills/kp-gh-lib/scripts/linked-item.sh <owner/repo> <n>`: it is `.issue`
   when non-null, else every `.decisions` entry (each read with `gh issue view <number>
   -R <owner/repo>`) when the list is non-empty, else there is no background issue. Read it for background
   (`gh issue view <n> --json number,title,body,labels,state`), applying the
   same human-only strip from §1.3. Read the spec it references only as needed to fix
   correctly. **Do not** re-derive acceptance criteria from scratch; the §1.3–1.4
   findings are the authoritative list.

## 2. Worktree on the PR branch

Never edit the main working tree — fix on the PR's own branch so the push updates the
PR.

**One call**, from this checkout:
`~/.claude/skills/kp-gh-lib/scripts/worktree.sh fix <n> <headRefName>`. A new worktree
is a **real branch checkout** of `<headRefName>` (not `--detach`), tracking
`origin/<headRefName>` (§0.2's fetch updated the ref), so commits push back to the PR.
**Resumable:** it reuses `../<repo-name>-fix-pr-<n>` or the legacy `../fix-pr-<n>` when
this checkout already has it, fetches, and fast-forwards to the PR head only when the
local branch is not ahead of it (`kp-gh-lib/SKILL.md` § *`worktree.sh`*). On
`ffSkipped: true` the worktree holds unpushed fix commits from a prior run — proceed to
§5, which pushes them. Use the printed `path` wherever `../<repo-name>-fix-pr-<n>`
appears below. A non-zero exit means there is no worktree: stop and report its stderr
verbatim.

Once the worktree is ready, **write the run state** per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Run state across compaction*: `issue: #<issue>`
(the §1.5 linked issue; omit it when there is none), `pr: #<n>`, `branch: <headRefName>`,
the absolute worktree path, and one unchecked line per §1.3–1.4 finding and per
acceptance criterion the linked issue lists.

## 3. Fix → verify (loop)

Work **surgically** inside the worktree: change only what a finding requires; match
existing style; don't refactor unrelated code (operator conventions §3).

1. Address **every** finding from §1.3–1.4. Each maps to a `file:line` and a concrete
   fix the reviewer already named.
2. **For a correctness/bug finding, add a reproducing test first, then fix it** — make
   the test fail, then pass (operator conventions §4).
3. **Verify.** Discover and run the project's tests, linters, and build (commands from
   its `CLAUDE.md` / README / Makefile / package manifest) in the worktree. If a
   finding was a **failing CI check**, reproduce that check locally where possible and
   make it pass. Run each test, lint or build command through
   `~/.claude/skills/kp-gh-lib/scripts/run-verify.sh --log
   <scratchpad>/verify-pr-<n>-<k>.log -- <command>`, where `<n>` is the PR number and
   `<k>` counts this run's commands from 1. It keeps the output in the log: read its result
   line and the tail it prints on `fail` or `timeout`, and open the log by line range
   with `Read` only when the tail does not show the cause. A `result=timeout` means the
   command is too long for one foreground call, not that it failed: re-run it once with
   the detached pattern of `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a
   headless session*. A command the project's docs say takes longer than 9 minutes
   goes straight to that pattern. The printed tail is the verbatim failure text
   §3.4 reports.
   The §5 push and the §6.2 summary comment wait until each run has completed in this
   same turn.
4. **Loop** until every finding is addressed **and** tests/linters/build are green.
   Report any failures **verbatim**; never claim a finding fixed without showing the
   verification result. Tick each line of the run-state file (§2) as its verification
   passes.
5. **A finding you cannot action** (it contradicts the code reality, or is itself
   wrong) — do **not** paper over it. Note it for the §7 report and plan to reply to
   that finding in §6 explaining why, rather than silently skipping it.
6. **A finding whose fix is owed work outside this PR** is filed per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Filing a follow-up item*, not improvised —
   created through `~/.claude/skills/kp-gh-lib/scripts/create-item.sh` as that section
   says. When it was raised as a human-gated item instead of filed, the §6.2 summary comment
   names the raised item; when it is unfiled, that comment quotes its
   `unfiled: check could not run — <title> (exit <code>)` line, so the PR thread is the
   durable record.

## 4. README / docs

Update the docs the fix affects in the same change (project doc rule) — `README.md`
and any relevant files under `docs/` when behavior, usage, or configuration changed.
Keep it to what changed; no changelog or "what I did" prose. If nothing user-facing
changed, note "no doc change".

## 5. Commit, push (updates the PR)

Re-check the PR is still open before pushing (idempotency).

1. **Commit** in the worktree, imperative subject ≤72 chars, body referencing the
   issue and explaining *why*: `git -C ../<repo-name>-fix-pr-<n> add -A` then commit
   **only if something is staged** (so a resumed run whose fix already landed doesn't
   error or stack an empty/duplicate commit):
   `git -C ../<repo-name>-fix-pr-<n> diff --cached --quiet ||
   git -C ../<repo-name>-fix-pr-<n> commit -m "<subject>" -m "Refs #<n>. <why>"`. One
   logical change; if a prior run already committed the fix, prefer
   `git -C ../<repo-name>-fix-pr-<n> commit --amend` over a second commit, and squash
   WIP before pushing.
2. **Push to the PR head:**
   `git -C ../<repo-name>-fix-pr-<n> push origin HEAD:<headRefName>`.
   This updates the **existing** PR — never open a new one.

If push fails (no write access, protected branch, non-fast-forward), report it
verbatim, leave the worktree in place, and **do not** move the board.

## 6. Re-queue + signal re-review

1. **Move the board item In progress → In review** (best-effort) so the build/review
   loop re-picks it, with the §0.2 item id:
   `~/.claude/skills/kp-gh-lib/scripts/set-status.sh <project-id> <item-id> <status-field-id>
   <in-review-option-id>`.
2. **Post a brief PR comment — one per fix run** — summarizing which findings were
   addressed, and calling out any finding deliberately **not** actioned with the reason
   (§3.5), so the reviewer's next pass has context. Earlier summaries stay on the PR:
   `kp-review-gh-pr` §1.6 reads them all, so a decline it accepted is not re-raised
   without new evidence. The body opens with the stable marker and the head the §5 push
   left (a no-new-commit round repeats the previous head):
   ```markdown
   <!-- kp-fix-pr:summary -->
   pushed: <head SHA after the §5 push>

   <findings addressed; findings not actioned, each with its reason>
   ```
   Write the summary — the marker, then `pushed: <head SHA after the §5 push>` read with
   `gh pr view <n> --json headRefOid -q .headRefOid` — to a file, and post it with
   `~/.claude/skills/kp-gh-lib/scripts/post-verdict-comment.sh <owner/repo> <n> --kind
   fixSummary --body-file <file>`. It `PATCH`es the latest summary only on a **true
   re-run** — its `pushed:` equals the head **and** it is newer than the §1.2 denial —
   and otherwise creates a new comment; given §1.2's stop, summaries in practice always
   stack.
   Best-effort — never block the fix on it.

## 7. Clean up + report

On success, remove the worktree (`git worktree remove ../<repo-name>-fix-pr-<n>`) — the
updated PR is the deliverable. On any failure or unactioned finding, **leave the worktree** so
the operator can inspect, and say so.

Report: the PR and its linked issue, the denied review acted on, the findings list and
how each was fixed and verified (with the test/lint/build output summary), any finding
not actioned and why, the docs change or "none", the commit subject, the push result,
the resulting board status, and the token totals posted in §8.

## 8. Token-usage report

As the **final action of every run** — on success, on any failure or early stop once
fixing has begun, and on a "nothing to fix" stop — post this run's token usage as a PR
comment. **Best-effort:** never let it block or fail the deliverable.

1. **Record this run's row** on the PR, from the session's working directory:
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/report-tokens.sh "<run-start-timestamp from §0>" \
     "<!-- kp-fix-pr:token-usage -->" <owner/repo> <n>
   ```
   It adds or rewrites this run's row in the marked table and prints it; the table is
   described in `~/.claude/skills/kp-gh-lib/NOTES.md` § *Token-usage report*. A
   non-zero exit means nothing was written: note it and finish the run.
2. **Delete the run-state file** (§2) on every run end, success or stop:
   `rm -f ~/.claude/skills/kp-gh-lib/state/run-"$CLAUDE_CODE_SESSION_ID".md`.

## Invariants

- **Acts only on a denied PR** — the latest verdict must request changes, whether
  delivered as a formal `REQUEST_CHANGES` review or, on a self-authored PR, a marked
  verdict comment — as `pr-verdict-state.sh --reviews` reports in `fixNeeded` (§1.2). An `APPROVED` / no-denial /
  already-addressed / `MERGED` / `CLOSED` PR stops the run (idempotent — re-runs never
  re-fix).
- **Never reads human-only content into context** — the `<!-- human-only -->` fence
  and the `### TL;DR (for humans)` review section are skipped; only the
  `### Findings (for the build agent)` section, unresolved inline comments, and cited
  failing CI checks drive the work.
- **The findings are the work list** — not a fresh acceptance re-derivation; the
  issue/spec are read only to fix correctly.
- **Always works in a worktree on the PR branch** — never edits the main working tree;
  the push updates the existing PR and never opens a new one.
- **In progress → In review** is the only board transition, best-effort, never
  blocking the fix push.
- **Never claims a finding fixed without running the verification and showing the
  result.**
- **Never ends the turn with a started command still running** — builds, tests and lints
  wait in the foreground per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a
  headless session*; never `run_in_background` or `Monitor`.
- **Resumable** — re-running for the same PR continues the existing worktree/branch
  rather than starting over: the fast-forward is skipped when local holds unpushed
  commits (§2), the commit is guarded against empty/duplicate commits (§5.1), the
  summary comment is `PATCH`ed only on a true re-run (§6.2), and the token-usage comment
  upserts by marker rather than stacking (§8.1).
