# kp-skills

The global Claude Code skills library. **This repository IS `~/.claude/skills`** — the
live directory Claude Code loads skills from. A merge to `main` only takes effect after
`git pull` here.

## Stack

Markdown (`SKILL.md`) plus `bash` and `python3` helper scripts; a `kp-gh-lib` wrapper's
Python lives in `kp-gh-lib/scripts/py/`. No build, no
dependencies, no package manager.

## Commands

- Validate every skill: `python3 .github/scripts/validate_skills.py`
- Shell scripts: `shellcheck **/*.sh` (CI only — not installed locally)
- Python lint: `ruff check --config .github/ruff.toml .` (CI installs a pinned ruff with `pipx`)
- Fixture suites: `.github/scripts/run_fixture_suites.sh` finds and runs every suite
  (offline; CI runs it; several minutes). One suite: `<skill>/tests/<name>/run.sh`.

## Verify

`python3 .github/scripts/validate_skills.py`. Shellcheck runs only in CI
(`.github/workflows/validate.yml`) — it isn't installed locally.

## Structure

One skill per top-level directory. Each contains a `SKILL.md` whose frontmatter `name`
equals the directory name; optional `scripts/`, `templates/`, `NOTES.md`, `state/`
(runtime, gitignored). Nothing else belongs at the top level — Claude Code treats every
top-level directory as a skill candidate, except `synced/`: the harness writes it itself
(synced Anthropic skills), it's gitignored, and `validate_skills.py` skips it by name.
Documents that are not a skill's own live under `.github/docs/` for the same reason:
`architecture.md`, `conventions.md`, `glossary.md` and `threat-model.md`.

`kp-gh-lib` is the one directory that is not a command: a helper library
(`disable-model-invocation: true`) whose `scripts/` the `kp-*` GitHub skills call by
absolute path. Each script has its own `## \`scripts/<name>\`` section in
`kp-gh-lib/SKILL.md`, and `.github/docs/architecture.md` § Helper scripts lists them by
concern. Its `headless-settings.json`, passed to every headless launch, runs
`restore-run-state.py` to put a run's state back in context after compaction.

## Conventions

- **Never edit on `main`.** Work goes board item → `kp-do-gh-task` (worktree at
  `~/.claude/kp-skills-task-<n>`) → PR → `kp-review-gh-pr` → merge. Items live on the
  "KP Skills" project board; repo + board defaults are in `.claude/spec-sync.json`.
  Every step is checked, not merely documented — see **Enforcement**.
  `~/.claude/kp-skills` is the skills' own primary checkout, auto-cloned by
  `ensure-checkout.sh` because the family names a repo's checkout `<workspace>/<repo-name>`
  and this repo is `kp-skills`, not `skills`; the task, fix and review worktrees hang off
  it. It is never hand-edited (a dirty one makes every fresh read export a worktree) and
  never symlinked to `~/.claude/skills` (`fresh-checkout.sh` fast-forwards a clean primary
  checkout, which would change the loaded skills under running children).
- Skills are prompts, not code: prefer precise, testable instructions over prose. Keep the
  frontmatter `description` a faithful trigger statement — it is the only thing the model
  sees when deciding to invoke a skill.
- Every change updates the docs it affects in the same change (`README.md`, this file);
  a new or removed `kp-gh-lib` script updates its section in `kp-gh-lib/SKILL.md` and
  the table in `.github/docs/architecture.md`.
- **GitHub API budget in the `kp-*` GitHub skills.** Projects v2 is the only expensive
  part of the GitHub API here (GraphQL: 5,000 points/hr, cost scales with nodes
  returned). Use the `kp-gh-lib/scripts/` helpers (`preamble.sh` does a skill's whole
  setup for 2–4 points; `set-status.sh` moves a Status, never `gh project item-edit`)
  and never paste their blocks back into a skill. Never reintroduce
  `gh project field-list` (102 points) or a board-wide `gh project item-list` (305
  points / 582 KB on a 254-item board). Rules: `kp-gh-lib/NOTES.md` § *GitHub API
  budget*; helper by helper: `.github/docs/conventions.md` § *GitHub API budget in the
  `kp-*` GitHub skills*.
- **Never end the turn while a started command is still running.** A headless
  `claude -p` child exits when its turn ends, so a backgrounded build or CI wait is lost
  and no commit, PR or verdict lands. Builds, tests, CI polls and an orchestrator's idle
  wait run in the foreground — never `run_in_background` or `Monitor` — and a
  `claude -p` child is launched and waited on with `kp-gh-lib/scripts/run-child.sh`.
  Rules: `kp-gh-lib/NOTES.md` § *Waiting in a headless session*; long form:
  `.github/docs/conventions.md` § *Never end the turn while a started command is still
  running*.
- **Token usage: fork, model tier, subagents.** Each `kp-*` skill is judged on its own
  against three rules. `context: fork` only on a skill whose operator is never in the
  loop mid-run, and only after a throwaway probe skill proves what the fork could change.
  `model:` never on `kp-do-gh-task`, `kp-fix-pr` or `kp-review-gh-pr`, whose callers pick
  the model from the item's `model:*` label; elsewhere only to go cheaper, per
  `kp-gh-lib/NOTES.md` § *Creating an item* → *Model-tier rubric*. A long skill's heavy
  read-only phase runs in one foreground, read-only subagent that returns a bounded
  summary. Probe results and figures: `.github/docs/conventions.md` § *Token usage: fork,
  model tier, subagents*.
- **Pasteable prompts in a created issue body carry real values, not metavariables.**
  A human-gated item carries a resolution prompt the operator is meant to copy and run,
  so it must be runnable as it ships. Values known before creation are substituted
  inline; the issue's own number is written as a literal `__ISSUE__` token and edited
  away after creation, best-effort. Recipe: `kp-gh-lib/NOTES.md` § *Creating an item*;
  the skills that do it: `.github/docs/conventions.md` § *Pasteable prompts in a created
  issue body carry real values, not metavariables*.
- **Coding items carry their own contract.** Every `type:coding` issue follows
  `kp-gh-lib/NOTES.md` § *Coding item body*. Builders and reviewers load context only
  through `kp-gh-lib/scripts/read-context.sh`, never a whole spec doc; `lint-item.py` is
  the test, and a body it fails is `needs-contract`, which no loop builds. A new coding
  draft that fails is settled, then raised, never filed `needs-contract`
  (`kp-gh-lib/NOTES.md` § *Settling a failing draft*). Who lints, labels and backfills:
  `.github/docs/conventions.md` § *Coding items carry their own contract*.
- **Skills read checkouts only through `kp-gh-lib/scripts/fresh-checkout.sh`**: every
  `--code-root` is the directory it prints (an export of the current milestone's
  `origin/release/M<k>` when the repo has it, else the clone fast-forwarded or an export of
  `origin/<default branch>`), never a raw clone path that may be stale or edited.
- **Human-gated items are written for the operator.** Every `type:decision` /
  `type:question` / `type:conflict` issue a skill creates takes its title and body from
  one template; the creators point there and never restate a body shape. Every
  Recommendation names its confidence, and a decision whose every Recommendation is
  `confidence: high` is creator-decided. A skill climbs to the spec's goals before it
  raises or decides an item. Rules: `kp-gh-lib/NOTES.md` § *Human-gated item body* →
  *Confidence and creator-decided items*, § *Decision layers* and § *Before raising a
  human-gated item*; which skill resolves what: `.github/docs/conventions.md`
  § *Human-gated items are written for the operator*.
- **Build order is the skills' call, and milestones run strictly in order.** Only
  technical and feature unknowns, and the domain goals the spec leaves unwritten, become
  human-gated items; order, milestone and dependency cycles are settled by the skill and
  reported. Milestones run M0, M1, … numerically, no `blocked-by:` edge crosses
  milestones, and nothing launches while an earlier milestone has open work. Rules:
  `kp-gh-lib/NOTES.md` § *When an item is human-gated*, § *Milestone sequencing*,
  § *Every new item has a milestone* and § *Milestone branch*; audits, tags and release
  branches: `.github/docs/conventions.md` § *Build order is the skills' call, and
  milestones run strictly in order*.
- **Follow-up items look like every other item.** An issue a run files outside its
  skill's defined outputs (code a spec fold makes owed, work a review finding pushes out
  of a PR) gets the same labels, repo prefix, human-only fence, `blocked-by:` markers,
  epic link and board add as a created item. A dependency on a PR that closes no issue is
  `blocked-by: <owner>/<repo>#<pr>`, done only once that PR merges. The rule lives in
  `kp-gh-lib/NOTES.md` § *Filing a follow-up item*.
- **The audit runs bottom-up.** `kp-audit-alignment` starts from merged code, not from
  the spec: a unit's as-built description is written by a subagent that never sees the
  spec, only then compared with the REQs and goals, and a finding is filed only once a
  read-only check confirms it — as an ordinary item in the repo it concerns, deduplicated
  there. It commits nothing itself; its only writes to a code or spec repo are the
  milestone merge and the `milestone/M<k>` tag on a milestone its audit closes. Finding kinds and routing live in
  `kp-gh-lib/NOTES.md` § *Alignment audit*.
- Pushing to `origin`: `git pull --rebase origin <branch>` first, then `git push`.

## Enforcement

GitHub-side enforcement is deliberately unused (this plan has no rulesets, and `main` is
not protected). Every gate is local:

- **`.githooks/pre-commit`** — a commit on `main`, from the live directory instead of a
  worktree, or on a branch not shaped `task/<n>-<slug>`; then a staged change (added
  lines and paths) that matches the denylist, checked by `.githooks/check-denylist.sh`.
  Offline, on every commit.
- **`.githooks/commit-msg`** — a commit message that matches the denylist. The denylist
  is `~/.config/kp-skills/denylist` (or `$KP_SKILLS_DENYLIST`): one case-insensitive
  extended regex per line, kept outside the repository so the terms are never committed.
  A clone without the file checks nothing. Issue, PR and comment text is not checked.
  The same script's `tree <dir>` mode checks a whole exported tree (see **Publishing**).
- **`.githooks/pre-push`** — a direct push to `main`; and a task branch whose issue
  number does not exist in `targetRepo`. A GitHub it cannot reach warns and allows —
  being offline must not block a push.
- **`.claude/hooks/guard_merge.py`** (`PreToolUse`, `Bash`) — `gh pr merge` and the REST
  equivalent, unless the PR is open, not a draft, CI is green at the head SHA, the merge
  is `--squash`, and the latest verdict is an approval **pinned to that head SHA**. It
  fails closed (a failed API call, an unparseable command or a missing PR number all
  deny) and has no override token. This is the layer that makes review non-optional.
  A merge is found in each segment of the command (split at shell operators and
  newlines): `gh` by any path followed by `pr merge`, with options before the subcommand
  skipped, or the REST path `repos/<o>/<r>/pulls/<n>/merge` passed to any program. Every
  merge in a command is checked, including inside `bash -c "…"` and `eval`. A GraphQL
  merge mutation and `gh pr merge --auto` are denied outright. Fixtures:
  `kp-gh-lib/tests/guard-merge/run.sh`.
- **`.claude/hooks/guard_bash.py`** (`PreToolUse`) — destructive commands, protected
  paths, history rewrites on `main`, and `--no-verify` issued by an agent. It reads each
  command's words, not its text: every segment between shell operators, every command
  handed to `bash -c` or `eval`, and a heredoc fed to a shell; a quoted string or a
  heredoc written to a file is text and is not checked. A same-session backstop;
  `.githooks/` is the load-bearing layer. Both guards split commands with
  `.claude/hooks/shell_words.py`; `kp-gh-lib/tests/guard-bash/` tests this one.
- **`.claude/hooks/validate_gate.py`** (`Stop`) — runs `validate_skills.py` and blocks
  the session from finishing while it fails. An unreadable event or a missing
  validator allows. `kp-gh-lib/tests/validate-skills/` tests it and the validator.
- **`.claude/hooks/ensure_githooks.sh`** (`SessionStart`) — sets `core.hooksPath` to
  `.githooks`, which a fresh clone leaves unset.

The approval `guard_merge.py` reads is the newest verdict comment `kp-review-gh-pr` §6
posts — one per round, so a PR carries several — (or a formal `APPROVED` review whose
`commit_id` is the head SHA):

```
<!-- kp-review-gh-pr:verdict -->
verdict: APPROVED
approved: <head SHA>
```

`kp-resolve-spec-decision` §4.7 posts the same approval on a spec PR it opened through
`kp-gh-lib/scripts/spec-pr-fastmerge.sh`, once one sonnet read finds the change covers
the decision and `kp-gh-lib/scripts/spec-pr-check.sh` prints `ok`, then merges in its own
call; `guard_merge.py` gates that merge unchanged.

A denial carries `verdict: REQUEST_CHANGES` and `reviewed: <head SHA>` instead, and each
`kp-fix-pr` summary (`<!-- kp-fix-pr:summary -->`) carries `pushed: <head SHA>`. Those two
lines only decide whether the writer, `kp-gh-lib/scripts/post-verdict-comment.sh`,
`PATCH`es a true re-run or stacks a new round; the gate reads neither.

Change that format in one place and the gate stops recognising it: `guard_merge.py`,
`kp-review-gh-pr` §5–§6, `kp-fix-pr` §1.2 and §6.2 and `kp-do-gh-pr-loop` §2 with
`kp-gh-lib/scripts/pr-loop.sh`, `kp-gh-lib/scripts/post-verdict-comment.sh` and
`kp-gh-lib/scripts/spec-pr-fastmerge.sh` move together
(`kp-do-gh-ready-items` delegates to `kp-do-gh-task-loop`, which runs `pr-loop.sh`;
neither reads a verdict itself). The
`verdict:` line is what separates an approval from a denial — every reader checks it,
and a marked comment without one is a denial.

The limits, stated honestly:

- None of this binds the operator's own shell, a deliberate `--no-verify`, or a Claude
  session rooted outside this repo.
- **The merge gate reads command text, not what runs.** It does not see a merge inside
  backticks or inside a quoted string other than `bash -c` / `eval` (including
  `"$(…)"`), one reached through a shell variable or alias holding the program name, or
  one made by a script file. It errs the other way too: an unquoted `echo gh pr merge 6`
  is treated as a merge.
- **The Bash guard reads command words, not what runs.** It does not see a command
  built by variable or backtick expansion, a heredoc piped into a shell
  (`cat <<EOF | bash`), an alias or script that wraps a guarded command, or other
  deleting tools (`find -delete`, `git rm`).
- **The approval artifact is agent-writable.** GitHub rejects a formal self-review, so
  on a self-authored PR the approval is an ordinary issue comment — and nothing gates
  writing one. A `gh pr comment` carrying the marker, a `verdict: APPROVED` line and an
  `approved: <head SHA>` line opens the gate immediately. Closing that would mean
  giving up self-authored review entirely, so it stays open by design.

The goal is that skipping the flow takes intent, not that it is impossible.

## Publishing

This repository is private and stays the working repository. The public copy is a
separate, read-only mirror that receives snapshot commits:
`.github/scripts/export-mirror.sh <mirror-clone>` exports `origin/main`, drops the paths
in `.github/mirror-exclude`, refuses on any denylist match (or with no denylist) and
commits one snapshot in a local clone of the mirror. It never pushes. Pushing a snapshot
and any change to a repository's or board's visibility are the operator's own manual
steps; no skill or agent performs them.

## Non-obvious

- `kp-msg-me` reads Telegram credentials from the environment or
  `~/.config/kp-msg-me/config` — never commit a token here. The `kp-*` skills ping only
  when a human-gated item is filed (a creator-decided decision excepted: it pings only
  when its resolve falls back to the operator), another stop needs the operator, or a top-level
  orchestrator session ends (`send.sh --session-end`, a no-op in a headless child) —
  never for a merge (`kp-gh-lib/NOTES.md` § *Operator notifications*).
