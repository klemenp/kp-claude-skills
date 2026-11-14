# Architecture

How the skills, the helper scripts and GitHub fit together. The rules each skill follows
live in `kp-gh-lib/NOTES.md`; this page is the map.

## Skills by role

A skill is a prompt (`SKILL.md`) that one Claude Code session follows. Control passes
between skills through GitHub, never through shared memory.

- **Spec skills** turn intent into items. `kp-project-spec` writes the spec,
  `kp-sync-spec-tasks` files a coding item per unimplemented requirement, and the
  `kp-resolve-spec-*` skills fold a human's or an agent's decision back into the spec.
- **Intake skills** file or reshape single items: `kp-create-gh-item`, `kp-check`,
  `kp-decompose-gh-task`, `kp-backfill-contract`.
- **Build and review skills** do the work on one item: `kp-do-gh-task` builds it and
  opens a PR, `kp-review-gh-pr` reviews and merges or denies, `kp-fix-pr` fixes a denial.
- **Orchestrators** hold no judgement of their own. `kp-do-gh-pr-loop`,
  `kp-do-gh-task-loop`, `kp-do-gh-pr-loop-all` and `kp-do-gh-ready-items` launch the
  skills above as headless children, wait, read the outcome from GitHub, and decide what
  to launch next.
- **Audit**: `kp-audit-alignment` describes merged code without seeing the spec, then
  compares the two and files confirmed differences as ordinary items.

A builder never reviews its own PR in the same session, and a reviewer never reads the
builder's reasoning: each sees only the item, the diff and the bounded context the item
names.

## State model

Everything a later run needs is on GitHub, so any run can be interrupted and resumed.

- **Issue body.** A coding item's body is its contract: Goal, Scope, Out of scope,
  Context, Acceptance criteria, Verify. It opens with a human-only fence that agents
  strip before reading. `lint-item.py` checks the contract before an item is filed.
- **Marker lines.** Lines such as `blocked-by: #12`, `parent: #3` and `spec-ref: REQ-…`
  outside the fence carry the dependency graph and the link back to the spec.
- **Marked comments.** A review verdict, a fix summary and a decision are comments that
  begin with an HTML-comment marker and a fixed first line (`verdict: APPROVED`). Scripts
  read state from these, never from free prose.
- **Board Status.** Backlog, Ready, Blocked, In progress, In review and Done on a
  Projects v2 board say where an item stands and what an orchestrator may pick up.
- **Branches.** A task builds on `task/<n>-<slug>`; a milestone's items merge into
  `release/M<k>`, which reaches the default branch only after the milestone's audit
  files nothing.

## Helper scripts

`kp-gh-lib/scripts/` holds what would otherwise be repeated prose in every skill. Each
script documents its usage, output and exit codes in its header and in
`kp-gh-lib/SKILL.md`.

| Concern | Scripts |
|---|---|
| Setup and board | `preamble.sh`, `resolve-board.sh`, `item-id.sh`, `set-status.sh`, `ready-sweep.sh`, `repo-code.sh`, `ensure-labels.sh` |
| Items and markers | `create-item.sh`, `link-item.sh`, `epic-convert.sh`, `find-marker.sh`, `set-marker.sh`, `body-parts.py`, `comment-once.sh`, `lint-item.py`, `read-context.sh`, `backfill-candidates.sh` |
| Dependencies and decisions | `edge-check.sh`, `blocker-state.sh`, `unblock-dependents.sh`, `find-blocking-decision.sh`, `decision-state.sh`, `goal-question.sh` |
| Milestones | `milestone-of.sh`, `milestone-gate.sh`, `milestone-place.sh`, `milestone-branch.sh`, `milestone-merge.sh`, `milestone-tag.sh`, `audit-close-move.sh` |
| PR loop and verdicts | `pr-loop.sh`, `pr-verdict-state.sh`, `review-scope.sh`, `post-verdict-comment.sh`, `find-task-pr.sh`, `linked-item.sh`, `item-outcome.sh`, `research-prs.sh`, `ci-failure-excerpt.sh`, `branch-cleanup.sh` |
| Spec and audit | `spec-index.py`, `spec-branch.sh`, `spec-pr-check.sh`, `spec-pr-fastmerge.sh`, `trace-matrix.sh`, `audit-prev.sh`, `file-audit.sh` |
| Checkouts and worktrees | `ensure-checkout.sh`, `fresh-checkout.sh`, `repo-roots.sh`, `worktree.sh` |
| Headless runtime | `run-child.sh`, `run-lock.sh`, `run-verify.sh`, `model-label.sh`, `report-tokens.sh`, `restore-run-state.py`, `notes-section.sh` |

The scripts are written against a budget. GitHub's GraphQL API allows 5,000 points an
hour and Projects v2 queries are the expensive part, so a skill's setup is one
`preamble.sh` call of a few points, and a whole-board listing is never used
(`kp-gh-lib/NOTES.md` § GitHub API budget).

## Headless children

An orchestrator launches each step as its own `claude -p` process through
`run-child.sh`, which adds the family's flags, detaches the child, registers it, and
waits for it in the foreground by polling a sentinel. A child exits when its turn ends,
so nothing a child starts may be left running in the background.

The orchestrator does not parse what a child says. It reads the result from GitHub: is
there a PR, what is the latest verdict, is the issue closed. A child that hits a usage
limit is recognised from its log, and the run is reported as stopped, not failed.

Long runs survive context compaction because a skill writes its run state (issue,
branch, worktree, criteria ticked so far) to a file, and a `SessionStart` hook passed to
every child puts that file back into context after a compaction.

## Enforcement

GitHub-side branch protection is not used. Every gate is local, and described with its
limits in `CLAUDE.md` § Enforcement:

- `.githooks/pre-commit`, `commit-msg` and `pre-push` keep work on task branches in
  worktrees, tie each branch to a real issue, and reject content on a private denylist.
- `.claude/hooks/guard_merge.py` denies a merge unless CI is green and an approval is
  pinned to the PR's head commit.
- `.claude/hooks/guard_bash.py` is a backstop against destructive commands.

## Tradeoffs

- **State lives in markdown.** Verdicts, decisions and dependencies are parsed out of
  comments and issue bodies. That keeps everything visible and resumable with no
  database, but a format is a contract spread over several readers.
- **One format, several files.** The verdict comment's shape is known to the merge gate,
  the reviewer, the fixer, the PR loop and two scripts. `CLAUDE.md` lists them, and they
  have to change together.
- **Shell wrappers around Python.** Most scripts are a shell wrapper that parses nothing
  itself and runs a Python program from `kp-gh-lib/scripts/py/`. The programs are linted
  in CI and tested end to end by the fixture suites; type checking and unit tests for
  them are still to come.
- **Prompts are long.** The skills and their shared notes run to thousands of lines,
  because each rule exists to stop a failure that was seen. They are precise, and they
  are not quick to read.
- **Trust is by position, not by author.** The scripts act on any comment or marker in
  the repositories they run on. See the [threat model](threat-model.md).
