---
name: kp-review-gh-pr
description: Review a GitHub PR independently against its work item's contract — the item body and the bounded context read-context.sh loads, a targeted out-of-manifest spec check and the spec's goal frame — reading CI without waiting at the start, reviewing only the fix diff on a round after a fix when the reviewed head is an ancestor of the new one, running locally only what CI does not cover and waiting for CI once at the end; check acceptance criteria, hunt bugs, check readability/conventions/code-quality/security/scope/tests/docs/goals, then either APPROVE + squash-merge (closing the issue and the loop, and moving dependents the merge fully unblocked from Blocked to Ready) or submit REQUEST_CHANGES with an agent-actionable + human-readable comment and move the board back to In progress. A blocker/major finding or red CI blocks the merge; minor/nit-only findings approve, listed as non-blocking. Manual-only.
disable-model-invocation: true
argument-hint: [pr-number] [--project <number|owner/number|id>]
allowed-tools: Read, Grep, Glob, Bash
---

# Review a GitHub PR end-to-end

Downstream companion to `kp-do-gh-task`. That skill builds a work item into a PR and
moves the board to **In review**; this skill **reviews that PR** and closes the loop:
it checks the PR against the item's contract, the spec rules the item may have missed and
the spec's goals, verifies CI, and then either **approves + squash-merges** (clean, or only minor/nit
findings) or submits a **`REQUEST_CHANGES`** review with an agent-actionable +
human-readable comment and sends the item back to **In progress** (any blocker or major
finding).

Runs **inline (no fork)** on purpose, like its sibling: §7's `report-tokens.sh` reads
the session's top-level transcript, which holds none of a forked skill's usage (see
`kp-do-gh-task`), and `kp-do-gh-pr-loop` greps this skill's log for the CLI's usage-limit
line, which a fork has not been probed to print. A review worktree isolates the
filesystem when it runs a command CI does not cover (§2.3); otherwise the review reads
the PR's refs and creates none.

This is a **fresh-context, independent pass.** The builder and the reviewer are both
Claude, so the value is *not* trusting the PR description — derive what the PR was
supposed to do from the item's contract, then check whether it did it. The contract is
the item body plus exactly the context `read-context.sh` loads for it; a whole spec doc
is never read. Because the item can miss a rule, §4.12 still searches the pinned spec for
the terms the diff touches.

**Goal (success criteria):** the PR has been judged against an independently
derived acceptance basis, the out-of-manifest spec check, the goal frame and the
project's CI; a verdict is recorded — a GitHub
review (`APPROVE` or `REQUEST_CHANGES`) plus, always, the marked verdict comment §6
defines; on approval the PR is squash-merged and the issue/board reach Done; on changes
the board returns to In progress with a comment that a human can grasp in seconds and an
agent can act on directly.

Load a section of `~/.claude/skills/kp-gh-lib/NOTES.md` this skill names only with
`~/.claude/skills/kp-gh-lib/scripts/notes-section.sh '<heading>'`; never open the file
whole. The heading is the name in the reference (`§ *Run state across compaction*` →
`'Run state across compaction'`); for `§ *A* → *B*` it is `B`.

## 0. Setup

**Record the run start time** (`date -u +%Y-%m-%dT%H:%M:%S.000Z`) — §7 sums token
usage from it to the end of the run.

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the **PR number** (required; if
   missing, stop and ask for one). `--project <number|owner/number|id>` selects the
   GitHub Project (v2).
2. **Preamble — one call.** `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --pr <n>
   [--project <…>]`, then do what `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with its
   JSON, its exit code, and any `null` board field.

   Keep `.project.id`, `.itemId`, `.itemStatus`, `.status.fieldId` and the
   **`In progress`**, **`In review`**, **`Done`**, **`Blocked`** and **`Ready`** ids
   from `.status.options` (the last two for §5's dependent unblock, skipped and noted
   if absent). A PR closing no issue leaves `.issue` and `.itemId` null — §1.2's
   spec-PR and no-link branches cover that, and the board moves are skipped.

## 1. Load the PR + work item contract (the independent acceptance basis)

1. **Read the PR.** `gh pr view <n> --json
   number,title,body,headRefName,baseRefName,author,state,isDraft,labels,files,url,mergeable,mergeStateStatus`.
   If the PR is already `MERGED` or `CLOSED`, stop and report it (idempotency — never
   re-merge). If it is a **draft**, stop and report rather than reviewing.
2. **Find the linked issue** — one call,
   `~/.claude/skills/kp-gh-lib/scripts/linked-item.sh <owner/repo> <n>`. A non-zero exit
   leaves no basis — **stop** and report the message. Its `.via` picks the bullet below;
   on `closes` or `branch`, `.issue` is the linked issue. Load it with **one call**:
   `~/.claude/skills/kp-gh-lib/scripts/read-context.sh --code-root <checkout> <owner/repo>
   <issue>`. Its stdout — the `item` block (human-only fence already removed), the
   `goal-frame` block, and the `spec:`, `code:` and `decision:` blocks the body names — is
   the whole item and spec input of the review. The `code:` blocks are the files as they
   are on this checkout's base; the PR's versions come from §3. Exit `3` (something the
   body names did not resolve) is a contract finding for §1.5; exit `1` or `2` leaves no
   basis — **stop** and report the message. Add one `gh issue view <issue> --json
   labels,state` for what the blocks do not carry.
   - **Spec PR.** On `via: "spec-pr"` the PR is a `kp-resolve-spec-decision` spec PR,
     and `.decisions` (each `<owner>/<repo>#<n>`) lists its **decision issues**: one for
     a `spec/resolve-<n>` PR, every folded decision for a batched
     `spec/resolve-<n>-batch` PR. A decision issue usually lives in the target repo, not
     the spec repo this PR is in, so read each with its own `gh issue view <n> -R
     <owner>/<repo> --json number,title,body,labels,state,comments`, one call per entry.
     They are the acceptance basis only: the resolver closes them itself, so the PR
     closes no issue, and §0.2, the §5 board moves and the §5 unblock treat the PR as
     having no linked work item.
   - **No link.** On `via: null` nothing links an issue; that is not an error: record "no linked
     issue found" for the §8 report, skip §1.3–§1.4, and review the PR anyway.
3. **Strip the human-only fence before reading a decision issue body into context** —
   every decision issue in `.decisions` (`read-context.sh` already strips it from a
   coding item): read each only as
   `gh issue view <n> -R <owner/repo> --json body -q .body |
   ~/.claude/skills/kp-gh-lib/scripts/body-parts.py strip`. The fence is a human
   reading aid only — do **not** read it as spec/acceptance-criteria input or act on it.
4. **Locate the spec sections — spec PR only.** A coding item's spec comes only from
   §1.2's `read-context.sh`. For a spec PR, resolve each `spec-ref:` of every decision
   issue in `.decisions` (a conflict carries several) to one section: list the spec repo's sections at
   the PR head with `~/.claude/skills/kp-gh-lib/scripts/spec-index.py
   <owner/repo>@<head-sha>`, pick the section the `<doc-slug>` or `REQ-*` id names, and
   read only its line range (`git show <head>:<path>` piped through `sed -n
   '<start>,<end>p'`). A decision issue carrying `goal-ref:` outside the fence is a goal
   question: also locate the section its key names, the same way. Never read a whole
   spec file.
5. **Write the acceptance checklist yourself** from the body's `### Acceptance
   criteria` and `### Rules`, as §1.2 loaded them — the concrete, testable obligations
   this PR must satisfy, each with its `proof:`, plus any cross-cutting gates the item
   cites (a11y / perf / security) and any **design checklist it embeds**. This
   independently written list is the checklist for §4. **Do not** adopt the PR
   description's self-assessment as the basis, and never widen the basis by reading a
   spec doc.
   - **No contract.** A linked coding item whose body has no `### Context` section has
     no contract to review against. The verdict is **`REQUEST_CHANGES`** with the single
     finding `needs-contract` (the missing `### Context` section, fixed by
     `/kp-backfill-contract`), and **nothing else is reviewed**: skip
     §1.6–§4 — no CI read, no worktree, no pass — go straight to §5's request-changes
     branch, then §7.
   - **Unresolved context.** When §1.2's `read-context.sh` exited `3`, each problem it
     printed on stderr is a `major` finding (the item names context that does not
     resolve), and the review continues on what did load.
   - **Spec PR.** The basis is the decisions, not a ticket, built per entry of
     `.decisions`: that issue's latest decision comment (`kp-resolve-spec-decision` §3
     defines which comment that is) and its resolver's `Resolved → …` / `Closed as
     won't-do …` comment, plus every one of its `spec-ref:` requirements from §1.4. The
     PR must amend each referenced requirement to match its decision, keep its heading
     and `spec-ref` identity, and carry that decision's own
     `<!-- decided in <owner>/<repo>#<n> -->` back-reference beside the amended text.
   - **Goal-question spec PR** (`kp-resolve-spec-decision` *Goal-answered branch*). The
     basis is the operator's answer to the domain question (that same latest decision
     comment) and the resolver's `Goal recorded → PR …` comment. The PR must amend the
     section the `goal-ref:` key names to record that goal, with the
     `<!-- decided in <owner>/<repo>#<n> -->` back-reference, and must **not** amend the
     `spec-ref:` requirement: the technical decision is still open. On a won't-do answer
     the Spec PR basis above applies, and the PR also records the new non-goal in the
     goal section.
   - **No linked issue.** There is no ticket or spec, so the basis is the change the
     PR's title and body say it makes — its stated intent, never its claims of having
     verified it. §4.1 still verifies it, by the same CI-first rule.
   - **Reuse the Acceptance basis while the item body is unchanged.** Every verdict
     embeds its checklist in an `Acceptance basis` block (§6) with the item body's
     hash: the SHA-256 of the linked item's body after the §1.3 human-only fence strip,
     the same text the checklist is derived from, so an edit inside the fence alone
     keeps the hash. A spec PR and a PR with no linked issue embed the checklist with no
     hash and re-derive it every round — their basis is not an item body, so they
     never reuse. Save the stdout of `~/.claude/skills/kp-gh-lib/scripts/pr-verdict-state.sh
     <owner/repo> <n> --history` to a state file — the one `--history` call, which §1.6
     and §1.7 also read — then, from the checkout §0.2 fetched, run
     `~/.claude/skills/kp-gh-lib/scripts/review-scope.sh <owner/repo> <n> <issue|->
     <headRefName> --state-file <state-file>`, passing `-` for a spec PR or a PR with no
     linked issue. Its `bodySha:` line is the hash, computed without printing the body
     (`-` for a PR that never reuses); its `scope:` and `reviewed:` lines are §1.7's.
     Exit 1 stops the review with its message, like a failed `read-context.sh`.
     Then take the newest verdict in the saved state file's `history` whose
     `body` carries an `Acceptance basis` block. When its `body-sha256:` line equals the
     hash, adopt its checklist as this round's instead of writing one; otherwise — no
     earlier basis, no hash line, or a different hash — write the checklist as above.
     Reuse saves only the derivation: §4.1 still verifies every criterion against the
     new head. On a `scope: fix-diff` round (§1.7) the checklist, reused or rewritten,
     is still verified in full by §4.1 against the new head.
6. **Prior review state + prior rounds — read before reviewing.** List this bot's
   existing reviews and review comments (`gh pr view <n> --json reviews`; `gh api
   repos/{owner}/{repo}/pulls/<n>/reviews`). Every review and fix runs in a fresh
   session, so what earlier rounds raised, declined and accepted exists only on the PR.
   Read every round from the state file §1.5 saved when it checked the Acceptance
   basis — the stdout of `~/.claude/skills/kp-gh-lib/scripts/pr-verdict-state.sh
   <owner/repo> <n> --history`, whose `history` holds every verdict and fix-summary comment
   oldest to newest by creation time, each `body` already stripped of the human-only
   fence and of `### TL;DR (for humans)`, and each denial's `### Findings (for the build
   agent)` section isolated in its own `findings` field. Add any formal review body
   carrying the verdict marker (a different channel, so still read directly). A PR with a
   single legacy upserted comment of each is simply a one-round history. From each
   verdict read only `findings` (an approved verdict has none: read its `body`'s summary
   paragraph and non-blocking list); read each fix summary's `body` whole. Then:
   - **Do not re-raise** a finding that an earlier fix summary declined with a reason
     and that a later verdict did not re-raise or explicitly accepted, nor anything an
     earlier verdict recorded as verified clean. The only exception is **new
     evidence**: the relevant code or doc changed since that round, or the stated
     reason is demonstrably wrong.
   - **A re-raise under that exception cites the earlier round** (the comment's link)
     and states the new evidence in the finding.
7. **Review scope — the fix diff or the whole PR.** A round after a denial and a fix
   push reviews only what the fix changed. The scope is the `scope:` line
   `review-scope.sh` printed in §1.5 — **`scope: fix-diff`**, or **`scope: full`** with
   the first failed condition's reason in brackets — and `<reviewed>` is its `reviewed:`
   line. A round with no history (the `needs-contract` short-circuit skips §1.6) is
   `scope: full (no prior denial)`. The script checks, in order:
   1. the newest verdict is a denial with a `reviewed` SHA — else `no prior denial`;
   2. a fix summary newer than that denial carries a `pushed:` line — else `no fix push`;
   3. `<reviewed>` is an ancestor of `origin/<headRefName>` (an unknown commit after a
      force-push is not) — else `reviewed not an ancestor`;
   4. every path the fix diff touches is a file that denial's findings flag or a test
      file — else `fix outside flagged files`;
   5. the current body and that denial both carry a `body-sha256:` (a spec PR and a PR
      with no linked issue never do) — else `no body hash`; and the two are equal, since a
      changed Scope, Out of scope or acceptance criteria means the whole PR is reviewed
      against the new body — else `item body changed`.

   Record the chosen scope and, on `scope: full`, the first failed condition, for §6 and
   §8. On `scope: fix-diff`, **check every finding in that denial's `findings` against
   the new head** as addressed or not addressed; one not addressed is re-raised at its
   original severity, citing that round's comment link. Only the newest denial's
   findings are checked: an older denial's findings were already checked by the round
   that wrote the newest denial, which re-raised any it found not addressed. The §1.6
   do-not-re-raise rule — a finding declined with a reason and not re-raised or accepted
   later stays settled — still applies to this check unchanged.

## 2. CI — read early, wait once at the end

CI being green is a non-negotiable precondition for merge (`shop-spec` TICKETING §6:
typecheck, lint, tests, build, smoke/Lighthouse). The review does not wait for it: it
reads CI once here without waiting, runs its passes, and waits for CI once, in §4's CI
end check.

1. **Early read — never waits.** One plain `gh pr checks <n>` call, never polled or
   repeated, lists the checks at the head SHA (about 2–5 GraphQL points). Pending is
   fine here.
2. **Coverage map.** For each command the review would otherwise run locally (the
   project's tests, build, lint, typecheck — from its `CLAUDE.md` / README / package
   manifest / `.github/workflows/`), decide which check runs it. **Any check that exists
   at the head SHA, green or still pending, covers its command**: the review never runs
   that command locally. A check that finishes red is caught by the end check, not by a
   local re-run.
3. **Local runs.** What must run locally is only: the commands no check covers, plus the
   targeted test a §1.5 criterion's `proof:` names. When that list is empty the review
   needs no worktree (§3).

## 3. Diff, and a worktree only when something runs locally

Never review against the main working tree — review the PR's actual revision.

**Load the diff explicitly**, against the refs §0.2's fetch updated:
`git diff --stat origin/<baseRefName>...origin/<headRefName>` for the shape of the
change, then per file `git diff origin/<baseRefName>...origin/<headRefName> -- <path>`.
On a `scope: fix-diff` round (§1.7) the fix-diff passes (§4) load the fix commits
instead: `git diff --stat <reviewed>..origin/<headRefName>`, then per file
`git diff <reviewed>..origin/<headRefName> -- <path>`; the full-PR passes keep the
range above.
Read a full file only where the hunk context is not enough, with
`git show origin/<headRefName>:<path>` (or from the worktree when one exists).

**Reclaim first — always, worktree needed or not**, so a stale worktree from an
interrupted run never survives. From this checkout, **when §2.3 left something to run
locally**, call `~/.claude/skills/kp-gh-lib/scripts/worktree.sh review <n>
<headRefName>`: it removes `../<repo-name>-review-pr-<n>` and the legacy
`../review-pr-<n>` when this checkout has them (another repo's same-named sibling is
left alone), then adds `../<repo-name>-review-pr-<n>` detached at
`origin/<headRefName>` (§0.2's fetch already updated the ref) — a clean tree at the PR
revision for those runs, never a reused one (`kp-gh-lib/SKILL.md` §
*`worktree.sh`*). Use the printed `path` as the review worktree; it is removed in
§7. When §2.3 left nothing to run, call `worktree.sh review <n> <headRefName>
--reclaim-only` instead: it only reclaims, prints `path: null`, and the review reads
every file with `git show`. A non-zero exit: stop and report its stderr verbatim.

Then **write the run state** per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Run state
across compaction*: `issue: #<issue>` (the §1.2 linked issue; omit it when there is
none), `pr: #<n>`, `branch: <headRefName>`, the absolute review worktree path (the
`worktree:` line is left out when there is no worktree), and every §1.5 acceptance
criterion unchecked. After the passes, §5 always re-reads the head with
`gh pr view <n> --json headRefOid`, so a restored state without a `head:` line is safe.

## 4. Review passes → a findings list

Start the passes right after §3 — CI may still be running. Work through every pass
below at the PR revision. Each **finding** records:
`file:line` · severity (`blocker` | `major` | `minor` | `nit`) · what is wrong · why
it matters · a concrete fix · the acceptance criterion or rule it maps to. **Severity
decides the verdict** (see §5): a `blocker` or `major` finding blocks the merge; `minor`
and `nit` findings do not — they ride along on the approval as non-blocking. On the
boundary: anything that would ship wrong behavior, an unmet or unverified acceptance
criterion, a security gap, or a missing required test or doc is at least `major`, while
wording, naming, and style that mislead no one are `minor` or `nit`.

On a `scope: fix-diff` round (§1.7), passes 2 Bugs/correctness, 3 Readability, 4
Conventions, 5 Code quality, 6 Scope creep, 7 Tests added, 9 Security, 11 Commit hygiene
(the commits in `<reviewed>..origin/<headRefName>`), 12 Out-of-manifest spec check and
13 Goal pass read only the fix diff (§3), and pass 12 draws its term list from it. Passes
1 Acceptance criteria, 8 Docs/ADRs and 10 Design/cross-cutting gates keep the full PR:
each is judged against the item's obligations as a whole, like the checklist. On a
`scope: full` round every pass reads the full PR.

1. **Acceptance criteria.** Every item from §1.5 met and **demonstrably verified** —
   by its `proof:`: inspect the diff or files, run in the worktree only what §2.3 listed,
   and count a CI-covered command as verified by that check, which the CI end check
   confirms. Never run locally a test, build or lint command a CI check covers. An
   unmet or unverifiable criterion is a finding. Never assert an AC is met without
   showing the verification result. Run every local test, build and lint per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a
   headless session*; the §5 verdict waits until each run has completed in this same
   turn. Tick each criterion in the run-state file (§3) as its verification passes.
2. **Bugs / correctness.** Logic errors, missed edge cases, error handling,
   async/await and promise handling, null/empty/boundary paths, off-by-one, incorrect
   state transitions.
3. **Readability & quick human understandability.** Intent-revealing names, obvious
   control flow, small focused units, guard clauses over deep nesting. Flag anything a
   competent reader can't follow on first read.
4. **Conventions.** Framework idioms (React 19, TypeScript strict, Tailwind 4,
   shadcn/ui), the project `CLAUDE.md`, and the operator's global engineering
   conventions. Match existing style. The Next.js App Router, Payload and Drizzle
   checks apply only when the repo uses them: read the root `package.json` at the head
   (`git show origin/<headRefName>:package.json`); each applies only when its package —
   `next`, `payload`, `drizzle-orm` — is listed in `dependencies` or `devDependencies`.
   No `package.json` → none of the three apply.
5. **Code quality.** Least code that solves the problem; no speculative abstraction,
   no dead code, no magic numbers/strings, early returns, immutability by default,
   fail-fast validation at boundaries, narrow exception handling with context.
6. **Scope creep.** Changes outside the ticket's *Out of scope*, or spanning more than
   one feature area — every changed line should trace to the ticket (surgical-change
   rule).
7. **Tests added** for new behavior, at the layer the ticket names (TICKETING §6;
   for a bug fix, a test that reproduces the bug). Behavior tested, not implementation.
8. **Docs/ADRs updated** in the same PR when behavior, usage, or configuration changed
   (project doc rule + TICKETING §6). Missing doc update for a user-facing change is a
   finding.
9. **Security.** No secrets/tokens/credentials in the diff, no secrets in logs, input
   validation and output encoding at the edges, parameterized queries only, least
   privilege (`shop-spec` guardrails + global §11).
10. **Design / cross-cutting gates (UI tickets).** Verify each checkbox the ticket
    **embeds** — canonical tokens, anti-marketplace rules, keyboard focus visible,
    prefers-reduced-motion respected. Driven by the ticket's own checklist, so this
    pass stays project-agnostic.
11. **Commit hygiene.** Imperative subject ≤72 chars, one logical change, references
    the issue (`Closes #N`). A spec PR's `Refs <owner>/<repo>#<n>` is its reference —
    the resolver closes the decision issue itself — so it draws no missing-`Closes`
    finding.
12. **Out-of-manifest spec check** (a coding item with `spec:` lines). The item can miss
    a binding rule, so search the pinned spec for what the diff touches:
    1. From the diff, list the changed domain terms: identifiers, entity and event
       names, config keys.
    2. Grep the spec at the `spec:` lines' pinned SHA for each term, and map each hit to
       its section. `~/.claude/skills/kp-gh-lib/scripts/spec-index.py <spec-repo>@<sha>`
       lists the spec files and every section's line extent. Fetch each file once into
       a scratch file, never printing it (`mkdir -p "$(dirname /tmp/spec-<n>/<path>)"`, then `gh api -H 'Accept:
       application/vnd.github.raw' 'repos/<spec-repo>/contents/<path>?ref=<sha>' >
       /tmp/spec-<n>/<path>`), then `grep -n -i -F '<term>'` it. A hit's line number
       falls inside one section's extent — that section is the hit's section.
    3. Read only the matching sections that §1.2 did not already load, by their line
       range.
    4. A binding rule there that the diff breaks, or leaves unmet, is a finding tagged
       **`context-gap`**, severity by impact, naming the section as
       `<spec-repo>@<sha>:<path>#<anchor>`. The §6 TL;DR names every context gap so the
       item's creator can learn from it.
13. **Goal pass.** Check the diff against §1.2's `goal-frame` block — the spec's goals,
    quality priorities and non-goals. Breaking a non-goal (e.g. adding a write call
    where the spec says the importer is read-only) is a **`blocker`**, and the finding
    quotes the non-goal line. Trading a higher-ranked quality priority for a lower one
    is **`major`**. A no-spec item has no `spec:` line, so `read-context.sh` printed no
    `goal-frame` block: the goal pass is skipped, the §6 TL;DR says
    `goal pass: skipped (no goal frame)`, and that is not a finding.

**CI end check — once, after every pass.** Now wait for CI, the review's only CI wait:
`gh pr checks <n> --watch --interval 60`, as one foreground call with `timeout: 600000`
per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting in a headless session* (≤60 polls
≈ 120–300 GraphQL points per review round; never `--interval 30` or lower).
**CI wait cap: 6 calls × 10 min = 60 min per review round** — the budget starts fresh on
every `kp-review-gh-pr` run. When a call ends because the `Bash` timeout stopped it (the
watch never printed a final result), issue it again (the identical call), up to 6 calls in
total. A call that returns on its own (all checks finished, red or green) ends the wait
at once.
- **A check finished red → a blocking finding.** Take the failing check names, their
  detail URLs and the failure text from one
  `~/.claude/skills/kp-gh-lib/scripts/ci-failure-excerpt.sh <owner/repo> <n>` call, for
  the §6 `**CI**` group. A red check covering a command the review skipped locally is a
  `**CI**` finding too: judge from its excerpt whether it also backs a code finding.
- **Still pending after the CI wait cap → stop without a verdict.** Report "CI not
  finished"; do **not** merge and do **not** post `REQUEST_CHANGES` (pending is not a
  defect). Run §7 and exit. This is reached only when the 6th call has been stopped by
  its timeout — the run never ends its turn while a wait is still in flight.
- **All green → §5.**

## 5. Verdict + act

Re-check the PR is still open and unmerged before acting (idempotency).

- **Approve — CI green AND no `blocker` / `major` finding** (zero findings, or only
  `minor` / `nit`):
  1. **Record the approval — before merging.** A repo may gate the merge on an approval
     pinned to the PR's current head (kp-skills does: `.claude/hooks/guard_merge.py`),
     so the verdict has to exist *first*. Try a **formal review** — `gh pr review <n>
     --approve --body "<one-paragraph summary: what was verified and how, plus the §6
     non-blocking section if any>"`; on a
     **self-authored PR** GitHub rejects it (an author cannot review their own PR — see
     the operator's self-author note). **Either way**, post the §6 *approved* verdict
     comment, which carries the reviewed head SHA, by the **posting rule** — one verdict
     comment per round. Read `HEAD_SHA` with `gh pr view <n> --json headRefOid -q
     .headRefOid` after the review passes, write the §6 body carrying it to a file, and
     run `~/.claude/skills/kp-gh-lib/scripts/post-verdict-comment.sh <owner/repo> <n>
     --kind verdict --body-file <file>`. It `PATCH`es the latest verdict comment only on a
     **true re-run** — the same `verdict:` and SHA lines, and no
     `<!-- kp-fix-pr:summary -->` comment newer than it — and otherwise creates a new one,
     so a new head, a changed verdict, and a same-head round after a decline-only fix each
     stack. Exit `3` (head moved) means **do not merge**: report it and re-review. Any
     other non-zero exit means **do not merge**; report it verbatim.
     Read `headRefOid` *after* the review passes, and never hand-copy it — the SHA is
     what makes the approval verifiable. Anything pushed after this invalidates it, by
     design: re-review instead of re-stamping.
  2. **Merge:** `gh pr merge <n> --squash --delete-branch`. GitHub closes the linked
     issue through the `Closes #N` keyword only on a default-branch merge, and a
     milestone item's PR merges into `release/M<k>`
     (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone branch*), so close it
     explicitly: when §1.2 found a linked issue, read its state (`gh issue view <issue>
     -R <owner/repo> --json state`); when it is still `OPEN`, run `gh issue close <issue>
     -R <owner/repo> --reason completed --comment "Closed by merged PR #<n> (<sha>)."`,
     `<sha>` the squash merge commit (`gh pr view <n> --json mergeCommit -q
     .mergeCommit.oid`), as `pr-loop.sh` close_out does. Then set Status→Done with
     `~/.claude/skills/kp-gh-lib/scripts/set-status.sh <project-id> <item-id> <status-field-id>
     <done-option-id>` (best-effort).
  3. **Unblock dependents** (best-effort), only after the merge in step 2 landed, for the
     merged work item. When the PR closes the issue §1.2 found, step 2 has closed it, so
     pass `<issue>` — unless that close failed and it is still open: then skip this step
     and say so. When the PR closes no issue, pass the PR number `<n>`
     — the step 2 merge is what makes it done. Then, reusing the §0.2 ids:
     ```bash
     ~/.claude/skills/kp-gh-lib/scripts/unblock-dependents.sh <owner/repo> <issue-or-pr> \
       <project-id> <status-field-id> <blocked-option-id> <ready-option-id>
     ```
     It moves each dependent whose `blocked-by:` blockers are now all done — an issue
     closed, a pull request merged — and that no open decision blocks, from `Blocked` to
     `Ready`, and prints the `promoted` /
     `skipped` lists for the §8 report. A non-zero exit (an API error, or a
     secondary-limit `403`, which it never retries) is noted in the report and never
     fails the merge or the verdict.
  4. If merge is blocked (conflicts, branch protection, a merge gate, not mergeable), do
     **not** force it and **never** work around the gate — report
     `mergeable`/`mergeStateStatus` or the gate's reason, and leave the approval in
     place.

- **Request changes — any `blocker` or `major` finding (or CI red):**
  1. **Request changes.** Record the §6 verdict body (it begins with the
     `<!-- kp-review-gh-pr:verdict -->` marker, a `verdict: REQUEST_CHANGES` line and a
     `reviewed: <head SHA>` line, the SHA read as in the approval step).
     Try a **formal review first** —
     `gh pr review <n> --request-changes --body "<the §6 comment>"` — which supersedes
     any prior bot verdict (no duplicate stacking). **On a self-authored PR GitHub
     rejects a formal self-review** (see the operator's self-author note); when the
     command fails, **fall back to posting the same §6 body** by running
     `post-verdict-comment.sh … --kind verdict --body-file <file>` (the approval's
     **posting rule** above): a true re-run on an unchanged head `PATCH`es its own
     comment, and every other round stacks a new one.
     Either channel is enough for `kp-fix-pr` to pick up the denial (it reads both).
  2. **Move the board item In review → In progress** so the build loop repicks it
     (best-effort), with the §0.2 item id:
     `~/.claude/skills/kp-gh-lib/scripts/set-status.sh <project-id> <item-id> <status-field-id>
     <in-progress-option-id>`.
  3. **Do not merge.**

## 6. Verdict comment format

Both bodies open with the stable marker and an explicit **`verdict:` line**. That line
is what every reader keys on — `kp-fix-pr`, `kp-do-gh-pr-loop`, and a merge gate that
has to tell an approval from a denial. Never omit it, and never write `verdict:` prose
in the summary text where it could be mistaken for the real line.

Directly under it sits the **head SHA line** — `approved:` on an approval, `reviewed:` on
a denial — naming the head the review actually ran against; §5's posting rule keys on it
to tell a true re-run from a new round. Both SHA lines are additive: a marked comment
without one stays valid, and one without a `verdict: APPROVED` line is still a denial.

Under the SHA line sits the **`Acceptance basis`** block — §1.5's checklist, one
`- [x]` / `- [ ]` line per criterion, and, for a linked coding item only, the
`body-sha256:` line with §1.5's hash, which a later round compares to decide whether to
reuse the checklist. A spec PR or a PR with no linked issue omits that line. The block
stays above `## Review:`, outside the Findings section, so its checklist lines are never
counted as findings. A `needs-contract` denial wrote no checklist and omits the block.

**Approved** — short, and the `approved:` SHA must be the head the review actually ran
against. The non-blocking section appears only when the review found `minor` / `nit`
findings; omit it otherwise:

```markdown
<!-- kp-review-gh-pr:verdict -->
verdict: APPROVED
approved: <head SHA>

<details><summary>Acceptance basis</summary>

- [x] <criterion> — proof: <proof>
body-sha256: <§1.5 hash; omitted for a spec PR or a PR with no linked issue>

</details>

## Review: approved

<one paragraph: what was verified and how — the same summary passed to `gh pr review
--approve`.>

### Non-blocking (minor / nit)
- `path/to/file.ts:42` — <what's wrong>. Why: <why it matters>. Fix: <concrete fix>.
  (AC/rule: <which acceptance criterion or convention this maps to>)
```

**Changes requested** — two clearly separated sections, in this order:

```markdown
<!-- kp-review-gh-pr:verdict -->
verdict: REQUEST_CHANGES
reviewed: <head SHA>

<details><summary>Acceptance basis</summary>

- [x] <criterion> — proof: <proof>
body-sha256: <§1.5 hash; omitted for a spec PR or a PR with no linked issue>

</details>

## Review: changes requested

### TL;DR (for humans)
<2–4 sentences of plain prose, scannable in ~15 seconds: the verdict, the 1–3
things that matter most, and *why*. No jargon, no file paths here.>

---

### Findings (for the build agent)
**Blockers**
- `path/to/file.ts:42` — <what's wrong>. Why: <why it matters>. Fix: <concrete fix>.
  (AC/rule: <which acceptance criterion or convention this maps to>)

**Major**
- `path/to/file.tsx:88` — …

**Minor**
- `path/to/file.tsx:120` — …

**Nits**
- `path/to/file.tsx:140` — …

**CI**
- <failing check name> — <detail URL>   (omit this block if CI was green)

---
Re-run after fixing: `/kp-do-gh-task <issue-#> <spec-path>` · Issue: #<issue-#>
```

Keep the TL;DR free of `file:line` noise; keep the Findings precise and pasteable.
Group findings by severity so a human reads top-down and an agent works the list; leave
out a group with no findings. The TL;DR (on approval, the summary paragraph) names every
§4.12 `context-gap` finding by its spec section, and says `goal pass: skipped (no goal
frame)` when §4.13 was skipped. A `context-gap` finding carries the tag in its line:
`- [context-gap] <spec-repo>@<sha>:<path>#<anchor> — …`. The TL;DR (on approval, the
summary paragraph) also carries one line with §1.7's review scope — `scope: fix-diff` or
`scope: full` — and, on a `scope: full` round after a denial, the failed condition (e.g.
`scope: full (reviewed not an ancestor)`). The marker, `verdict:`, `approved:` /
`reviewed:` lines and the `Acceptance basis` block of both templates are unchanged.

## 7. Token-usage report + cleanup

1. **Remove the review worktree:** `git worktree remove ../<repo-name>-review-pr-<n>`
   (use `--force` if it refuses due to the detached state). Leave it only if you need the
   operator to inspect something, and say so. A review that skipped `git worktree add`
   in §3 skips this remove: there is nothing to remove.
2. **Record this run's token usage on the PR** — best-effort, never let it block or
   fail the verdict. Run from the session's working directory:
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/report-tokens.sh "<run-start-timestamp from §0>" \
     "<!-- kp-review-gh-pr:token-usage -->" <owner/repo> <n>
   ```
   It adds or rewrites this run's row in the marked table and prints it; the table is
   described in `~/.claude/skills/kp-gh-lib/NOTES.md` § *Token-usage report*. A
   non-zero exit means nothing was written: note it and continue.
3. **Delete the run-state file** (§3) on every run end, success or stop:
   `rm -f ~/.claude/skills/kp-gh-lib/state/run-"$CLAUDE_CODE_SESSION_ID".md`.

## 8. Report

Report: the PR and its linked issue (a spec PR's decision issues, or "no linked issue
found"), the resolved project, the §1.7 review scope (`scope: fix-diff` or
`scope: full`, and on `scope: full` the reason), the context loaded (`read-context.sh` blocks and bytes,
and each §4.12 section read), the acceptance checklist and how each was verified (CI
check, or local test/lint/build output summary), whether a worktree was created, the CI
status, the findings list (context gaps and the goal pass called out) (or "none"), the verdict
(`APPROVE`+merged / `REQUEST_CHANGES`), the resulting board status, the dependents §5
promoted and skipped (or why that step was skipped or failed), and the token totals
posted in §7.

## Invariants

- **Independent acceptance basis** — the acceptance checklist is written from the item's
  contract as `read-context.sh` loads it — for a spec PR, the decision and its
  `spec-ref:` requirements, or for a goal question the goal answer and its `goal-ref:`
  section (§1.5) — never trusted from the PR description. A coding item without
  `### Context` is denied with the single finding `needs-contract`.
- **No whole spec doc is read** — the basis is `read-context.sh` plus §4.12's
  out-of-manifest sections, each read by its line range.
- **Prior rounds bind** — a finding an earlier fix declined with a reason, which a later
  verdict did not re-raise or explicitly accepted, stays settled, as does anything a
  verdict recorded as verified clean; re-raising it takes new evidence and a citation of
  the earlier round (§1.6).
- **A fix-diff round is not a lighter review** — it still verifies every acceptance
  criterion and waits for CI exactly as a full round does, and it is taken only on an
  unbroken `reviewed` → head ancestry (§1.7).
- **CI green is a non-negotiable merge precondition** — failing CI blocks; CI still
  pending after the CI wait cap pauses the run *without* a verdict (pending ≠ defect).
- **No duplicate CI** — CI is read once without waiting (§2) and waited on once, after
  the passes (§4); a command a CI check covers is never run locally.
- **Never end the turn with a started command still running** — CI polls, tests, builds
  and lints wait in the foreground per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Waiting
  in a headless session*; never `run_in_background` or `Monitor`.
- **Severity decides the verdict — a `blocker` or `major` finding blocks the merge.**
  Any such finding, or red CI, yields `REQUEST_CHANGES`; a findings set of only `minor`
  / `nit` approves, each listed in §6's non-blocking section.
- **Verdict is recorded even when a formal review is impossible** — on a self-authored
  PR the formal `--approve` / `--request-changes` is rejected, so *both* verdicts are
  also written as the marker-tagged comment of §6, one per round (§5): the approval
  (carrying the reviewed head SHA) before the merge, the denial so `kp-fix-pr` can act
  on it. The formal review is best-effort; the comment is not.
- **Only In review→In progress (on changes) and →Done (on merge)** board transitions on
  the PR's item, plus Blocked→Ready for dependents the merge fully unblocked (§5), all
  best-effort and never blocking the verdict.
- **Idempotent** — a true re-run on an unchanged head `PATCH`es its own verdict comment
  instead of stacking one (§5), never re-merges
  (re-check PR state first; a `MERGED`/`CLOSED` PR stops the run), reclaims a stale
  review worktree before adding (§3), and upserts the single token-usage comment
  rather than stacking duplicates (§7).
- **Never claim an acceptance criterion is met without running the verification and
  showing the result.**
- **Never edit repo code** — this is a read-only review; every mutation is via `gh`
  (review, merge, comment) or the project board, plus its own run-state file (§3).
  (§4.12's scratch copies of spec files are not repo edits.)
