---
name: kp-create-gh-item
description: Turn a freeform task description into a build-ready GitHub coding item — one atomic item, or, when the work isn't atomic, an epic + atomic children. Clarifies every ambiguity with the operator first (asking, never inventing), then writes a body in the family's coding-item contract (checked by lint-item.py and a cold reader before filing), a recommended-model label (model:opus/opus-xhigh/haiku), and blocked-by markers, and adds the item(s) to the project board. Manual-only.
disable-model-invocation: true
argument-hint: [task-description] [--repo <owner/name>] [--project <number|owner/number|id>] [--dry-run]
allowed-tools: Read, Grep, Glob, Write, Agent, Bash(gh issue:*), Bash(gh project:*), Bash(gh label:*), Bash(gh api:*), Bash(gh repo:*), Bash(git rev-parse:*), Bash(git log:*), Bash(~/.claude/skills/kp-gh-lib/scripts/ensure-labels.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/repo-code.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/create-item.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/lint-item.py:*), Bash(~/.claude/skills/kp-gh-lib/scripts/read-context.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/find-marker.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/edge-check.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/preamble.sh:*)
---

# Create a GitHub work item from a description

The ad-hoc sibling to `kp-sync-spec-tasks`. Where that skill mints items from spec docs
and `kp-decompose-gh-task` splits an existing issue, this one takes a **freeform task
description** straight from the operator and turns it into a **build-ready** GitHub
item that `do_gh_task` can pick up. It resolves every ambiguity by **asking the
operator** (never inventing an interpretation), assesses whether the work is one
atomic unit or needs an epic + atomic children, and files the issue(s) with a
human-only blurb, a body in the coding-item contract, a `model:*` tier label, and
`blocked-by:` markers.

Runs **inline (no fork)** on purpose: it is interactive and judgement-bearing — the
clarity loop needs a live thread with the operator, like `kp-resolve-spec-decision` /
`do_gh_task`. It never touches the working tree; the only side effects are GitHub
issue/label creation, board adds, and re-parenting a prerequisite pulled forward into an
earlier milestone (§3.3).

**The one deliberate divergence from the family:** items created here have **no
`spec-ref:`** — there is no backing spec doc. The one exception is a milestone epic
(§1.4), which carries a single `spec-ref: milestone:<id>` marker so later runs can
recognise it. The **issue body is itself the source of
truth**, so everything resolved in the clarity loop (§1) must be captured in the body
(§6), self-contained enough for a build agent to implement without external context.

**Goal (success criteria — loop until all are true):** every ambiguity affecting
behavior / interface / scope is resolved with the operator; the work is assessed for
atomicity; each coding item carries exactly one `type:` and exactly one `model:` label,
a body in the coding-item contract (plus the cross-cutting gates that apply to it)
that passed `lint-item.py` and the cold-reader check (§5a), and correct acyclic
`blocked-by:` edges; any epic→children
links and the board adds are in place; a likely duplicate was surfaced to the operator
before creating.

## 0. Setup

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** Everything that is not a flag is the **task description**
   (it may be multi-word / multi-line; if it is empty, stop and ask the operator for
   one). `--repo <owner/name>` selects the repo the issue is filed in;
   `--project <number|owner/number|id>` selects the GitHub Project (v2); `--dry-run`
   previews without creating anything.
2. **Preamble — one call**, from the current checkout:
   `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --no-item --no-fetch [--project <…>]`,
   passing `--project` only when given (`--no-fetch` because this skill never syncs).
   Do what `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with its exit code: `5`, `2` or
   `1` → stop with its message; `6` → **ask** the operator which project, offering the
   candidates it printed on stderr, then re-run with `--project`.
3. **Resolve the target repo.** In order: `--repo` → config `.claude/spec-sync.json`
   `targetRepo` → otherwise **ask** (offer candidates with `gh repo list <owner>`).
   Never default to the spec repo. Record `<owner/name>`; every `gh issue` / `gh label`
   call below runs against it with `-R <target-repo>`.
4. **Record the Project (v2)** from §0.2's preamble: the owner login, number and node id
   are its `.project.owner`, `.project.number` and `.project.id`.

## 1. Capture + clarify the task (the gate)

The description is the raw input; the clarity loop turns it into a buildable spec.

1. **Read the description** and ground it in the codebase: use `Grep`/`Glob`/`Read` to
   find the symbols / files / endpoints / tests the work touches, the existing patterns
   it should match, and anything that informs the model tier (§3) or candidate blockers.
   This grounding also collects each item's `### Context` lines: a `code:` line per path
   the item touches or must match, and a `decision:` line per decision issue the work
   references. The repo's `CLAUDE.md` `## Verify` block, when present, supplies
   `### Verify`; otherwise take the commands the repo's `CLAUDE.md` / README document.
2. **Resolve every ambiguity by asking the operator.** Anything left unclear,
   contradictory, or unstated that affects **behavior, interface, or scope** is a
   question for the operator — ask **one targeted question at a time** (global
   `CLAUDE.md` §1), re-evaluate after each answer, and loop until you can **restate the
   task with no gaps**. This is the inline analogue of the family's clarity gate:
   because the operator is present, you **ask** rather than raising a `type:decision`
   issue — and you **never invent an interpretation** to avoid asking. When a spec is
   readable from this checkout (config `specGlobs`, else `docs/specs/**/*.md`,
   `specs/**/*.md`, `SPEC*.md`), climb first per `~/.claude/skills/kp-gh-lib/NOTES.md`
   § *Decision layers*: if its domain layer is silent on the fact a question turns on,
   and that fact is a business or domain goal, ask the goal-level question instead of
   the technical one, and name in the §7 report the domain section that lacks it, so
   the operator can record it in the spec. Build order is
   not a question: which item comes first, which milestone it lands in and a
   dependency cycle are settled in §3 and reported
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *When an item is human-gated*).
3. **The body will be authoritative.** There is no backing spec, so capture every
   resolved decision from this loop into the §6 body — scope, constraints, file
   pointers, and acceptance criteria — so a build agent needs nothing beyond the issue.
4. **Milestone epic?** When the §2 structure includes an epic, ask the operator — as
   part of this loop, one question at a time — whether it is a **milestone epic**: a
   `type:epic` that groups one roadmap milestone. If it is, ask for the milestone id
   (e.g. `M1`). Never infer either from the description. A milestone epic carries
   `spec-ref: milestone:<id>` and is repo-neutral (§6).

## 2. Assess atomicity / structure

Decide the shape by the bar in `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an
item* → *Atomicity bar*.

If the described work is a single such unit → **one `type:coding` item**. If it is not
→ **one `type:epic` parent + the smallest set of atomic `type:coding` children**, each
meeting the bar, ordered with `blocked-by:` edges where one child must precede
another. Print the
proposed structure (single item, or epic + child titles) for the operator before
creating; if it includes an epic, settle §1.4 first. **On `--dry-run`, skip §5 and stop
after §5a's checks** and emit the §7 report with nothing created.

## 3. Per coding item — model, acceptance criteria, blockers

For each `type:coding` item (the single item, or each child):

1. **Model tier.** Assess exactly one `model:*` label per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Model-tier rubric*;
   the `type:epic` parent gets none.
2. **Acceptance criteria.** Write concrete, testable obligations — the checklist
   `do_gh_task` will verify — plus the applicable cross-cutting gates (a11y / perf /
   security) that apply to this unit. Each takes the contract's form
   `- [ ] <observable outcome> — proof: <test name | command | file/field to inspect>`.
3. **Blockers.** Determine what must complete first: an existing issue the operator
   references (`#<n>`), or a prerequisite child within the same epic. Record each as a
   `blocked-by: #<n>` marker (§6). Each edge follows
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing* (hard invariants),
   checked as below. This item's milestone comes from
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Every new item has a milestone*. This skill
   never parents an item under an existing issue — the only parent is an epic this run
   creates — so each created item, this one or its epic, falls in exactly one case:
   - **a milestone epic this run creates** (§1.4): exempt, never passed to the script;
   - **a child of an epic this run creates**: the script is not run for it. Its
     milestone is that epic's id when the epic is a milestone epic (the NOTES exception),
     otherwise the epic's script result, inherited through its parent;
   - **an epic this run creates that is not a milestone epic, and a single item created
     with no epic**: run the script with no `--origin` and no `--parent`:

     `~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh --project <owner>/<number> --repo <target-repo> --cache <scratchpad>/milestone-current-<owner>-<number>.json`

     `--project` is the project §0.4 resolved. The script is read-only apart from its
     cache file, so it runs on `--dry-run` too, and §7 reports its result. When it exits
     non-zero, the item is created unplaced (NOTES *A failed placement*). On a real
     run §6.1's `create-item.sh` runs it again and does the link.

   The printed `milestone` and `epic` are the item's for the edge check. Check each
   edge onto an existing issue with `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh
   --project <owner>/<number> draft:<M<k>|none> <blocker> [--dependent-epic <epic>]`
   (`--dependent-epic` only when the item's milestone epic already exists); a
   prerequisite child within the same epic shares its milestone and is written as-is.
   `ok` → write the edge; `cycle` or `drop-earlier` → drop it and report it; exit `1` or
   `2` → leave it unwritten and report it with the first stderr line; `pull-forward` →
   the blocker is pulled forward and the edge is written: decide it here, and make the
   move in §6.2, once this item and its milestone epic exist — never on `--dry-run`.
   Settle this yourself — it is never a question for the operator (§1.2).

## 4. Soft duplicate check

Before creating each item, search the target repo for a likely duplicate:
`gh issue list -R <target-repo> --state open --search "<key title words>"`. If a
plausible match surfaces, **show it to the operator and ask** whether to proceed or
abort — do not create silently over it. There is **no machine idempotency marker**:
this is a manual one-off, and the operator is the dedup authority.

## 5. Labels

Create any missing label before use, per `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Creating an item* → *Labels*: before §5a, run
`~/.claude/skills/kp-gh-lib/scripts/ensure-labels.sh --repo <target-repo>` with every
label §6 will pass (`type:*`, `model:*`, `repo:<name>`). Exit 1 or 2 stops the run before
anything is created.

## 5a. Check the draft

Runs after the §4 duplicate check and before any `gh issue create`, for every
`type:coding` item — on `--dry-run` too, which runs both checks, reports their results in
§7 and creates nothing.

1. **Write the draft.** Compose the body per §6 and write it to
   `/tmp/kp-create-gh-item-<slug>.md`, `<slug>` a short kebab summary of the item's title.
2. **Lint.** From the target repo's checkout root, run
   `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <target-repo> --body-file <draft>`.
   Exit 1: fix every `FAIL` line in the draft and run it again until it exits 0. Exit 4
   (a fetch failure) or 2: **stop the run** with that message — never file the item on an
   unchecked draft. Keep the final `INFO` line for §7.
3. **Cold reader.** Run `~/.claude/skills/kp-gh-lib/NOTES.md` § *Cold-reader check*
   on the linted draft: `read-context.sh --body-file <draft> --repo <target-repo>` from
   the same root (a non-zero exit stops the run like lint's exit 4), its stdout the only
   input to the subagent. On a gap, fix the draft and rerun step 2 and this step. After
   two failed rounds, split the item per §2, or ask the operator — this skill's way of
   raising a human-gated item (§1.2).
4. **Size.** When the item looks large, suggest a split to the operator and say why
   (NOTES § *Coding item body* → *Rules*); never trim context to shrink it.

## 6. Create item(s)

If an epic is needed, create it first so children can link to it. **Coding item body:**
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body* — its template, line forms and
rules. What is specific to this skill:

- **No `spec-ref:` line**, except on a milestone epic (§1.4), whose body carries
  `spec-ref: milestone:<id>` outside the fence so later runs can recognise it. The body is
  authoritative and self-contained.
- **A spec readable from this checkout** (the §1.2 spec-glob rule) still lets an item
  carry `spec:` lines and a `serves:` line, per the contract.
- **Markers** after the sections, outside the fence: one `blocked-by: #<m>` per blocker,
  and `parent: #<n>` on a child.

An epic body keeps the family's human-only fence and a `### Scope` only.

**Repo identification:** the `[<REPO-CODE>] ` title prefix and the `repo:<name>` label
are the `code` and `label` that `~/.claude/skills/kp-gh-lib/scripts/repo-code.sh
<target-repo>` prints, run from the target repo's checkout root so it reads that repo's
`.claude/spec-sync.json`. A milestone epic (§1.4) is repo-neutral and takes neither, per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Repo identification*.

1. **Create — one call per issue,** epic first.
   `~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo <target-repo> --title
   "[<REPO-CODE>] <title>" --body-file <body> --label type:coding --label model:<tier>
   --label repo:<name> --project <owner>/<number> --cache
   <scratchpad>/milestone-current-<owner>-<number>.json`. For the epic parent:
   `--label type:epic` and **no** `model:*` label; a milestone epic also drops the
   `[<REPO-CODE>] ` prefix and the `repo:` label (`--title "<title>" --label type:epic`)
   and passes `--no-place`. A child of an epic this run creates passes `--link-under
   <target-repo>#<epic>`, which links it as a sub-issue of the epic instead of placing
   it; an epic that is not a milestone epic, and a single item with no epic, pass
   neither, and the script places them per §3.3. The epic body uses
   the same fence; its Scope summarises the umbrella and (optionally) lists the
   children as a task list. Before creating a milestone epic, look for one:
   `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo> spec-ref
   milestone:<id> --state all --label type:epic`. A hit is reused as the parent instead
   of creating a second epic for the same milestone. The script adds every created issue
   to the board (Projects v2 are cross-repo) and sets no status — this skill leaves it
   at the board's default. Exit `1` means nothing was created: stop and report it. A
   `skipped` `link` entry makes that item's line `no milestone — sub-issue link failed`;
   note any other `skipped` entry.
2. **Pull later-milestone blockers forward** (§3.3). Only now do this item and its
   milestone epic both exist. Re-parent each such blocker to the item's milestone epic
   per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Pulling a prerequisite forward*, and add
   `milestone: M<k> (was: M<j>) — pulled forward, required by #<item>` to the blocker's
   body outside its human-only fence — `was:`, not `spec:`, because this skill reads no spec
   (NOTES § *Pulling a prerequisite forward*).

On `--dry-run`, create, link, add, and move nothing — the §5a stop already emitted the
report.

## 7. Report

Print:
- the resolved target repo + project;
- the structure decided — single item, or epic + children — with a one-line atomicity
  rationale;
- a table: **title | type | model | milestone | blocked-by | url**. The `milestone` cell
  holds the script's report line for an item the §3.3 script ran for, the parent epic's
  cell for a child of an epic this run created, `milestone: M<k>` for an item under a
  milestone epic, and `exempt (milestone epic)` for a milestone epic. Each
  `placed <owner/repo#r> under M<k> (chain had no milestone)` line is listed under the
  table;
- per coding item: the lint `INFO` line (`bytes`, `acs`), the cold-reader result (`ok`,
  or the gaps fixed and rounds taken), and any split suggested because of size (§5a);
- the sub-issue mechanism used (if an epic was created), any `blocked-by` edge
  dropped to avoid a cycle or because its blocker sits in an earlier milestone, and
  every prerequisite pulled forward into an earlier milestone (§3.3);
- the recommended model(s), flagged when uncertain at a tier boundary;
- each goal-level question §1 asked, with the spec's domain section that lacks the goal.

No `NEW_ITEMS=` / token-usage lines — this is an interactive single-shot creator, not a
headless-loop skill.

## Invariants

- **Ambiguity is resolved by asking, never invented** (§1). The clarity loop runs until
  the task can be restated with no gaps; an interpretation is never assumed to avoid a
  question.
- **The issue body is self-contained** — no `spec-ref:` (the one exception: a milestone
  epic's `spec-ref: milestone:<id>` marker), no external backing doc. A coding item's
  body follows NOTES § *Coding item body*, and is filed only after `lint-item.py` exits 0
  and the cold-reader check answers `ok` (§5a); a build agent implements from the body
  plus what `read-context.sh` returns for it.
- **A milestone epic is repo-neutral** (§6): no `[<REPO-CODE>] ` title prefix and no
  `repo:*` label. Every other created item carries both.
- **Items are as atomic as sensible** (§2): one `type:coding` item when the work is one
  shippable+verifiable unit; otherwise an epic + the smallest set of atomic children.
- **Each coding item has exactly one `type:` and exactly one `model:` label.** The epic
  carries its `type:epic` label and no `model:` label.
- **`blocked-by` / `blocks` stay acyclic.** Never write an edge that points (directly or
  transitively) back at the item itself.
- **Edges stay inside one milestone** (§3.3): an earlier-milestone blocker is dropped, a
  later-milestone one is pulled forward, and build order is never asked.
- **No working-tree edits.** This skill only creates GitHub issues/labels, adds board
  items and re-parents a prerequisite it pulls forward — no worktree, no code, no spec
  edits. Implementation is `do_gh_task`'s job.
- **Soft dedup, no machine idempotency** (§4): a likely duplicate is surfaced to the
  operator, who decides; there is no stable body marker and re-running is not guaranteed
  to converge to zero.
