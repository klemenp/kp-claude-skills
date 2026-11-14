---
name: kp-decompose-gh-task
description: Decompose one coarse GitHub coding item into smaller, independently shippable children — each a complete unit whose body follows the family's coding-item contract (the governing spec rules and ADR constraints carried down, narrowed to the slice, and checked by lint-item.py and a cold reader before filing) and a recommended-model label (model:opus/opus-xhigh/haiku) — using the spec docs and ADRs as input. Converts the parent to an epic, links children as sub-issues. Idempotent; manual-only.
disable-model-invocation: true
argument-hint: [item-number] [spec-path-or-glob ...] [--project <number|owner/number|id>] [--repo <owner/name>] [--dry-run]
allowed-tools: Read, Grep, Glob, Write, Agent, Bash(gh issue:*), Bash(gh project:*), Bash(gh label:*), Bash(gh api:*), Bash(gh repo:*), Bash(git rev-parse:*), Bash(git log:*), Bash(git symbolic-ref:*), Bash(git -C:*), Bash(~/.claude/skills/kp-gh-lib/scripts/ensure-labels.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/repo-code.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/report-tokens.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-of.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/create-item.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/link-item.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/lint-item.py:*), Bash(~/.claude/skills/kp-gh-lib/scripts/read-context.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/fresh-checkout.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/find-marker.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/epic-convert.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/set-marker.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/body-parts.py:*), Bash(date:*), Bash(~/.claude/skills/kp-gh-lib/scripts/edge-check.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/preamble.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh:*)
---

# Decompose a GitHub backlog item

Sits between `kp-sync-spec-tasks` (which mints coarse, one-per-spec-heading coding
items) and `do_gh_task` (which implements one item as one PR). Takes **one** coarse
`type:coding` issue plus the spec docs and the repo's ADRs, and splits it into
several **smaller** children. Each child stays a *complete* unit of work — its own
narrowed acceptance criteria, the cross-cutting gates that apply to it, shippable as
a single `do_gh_task` PR — and is tagged with a **recommended model** so the operator
(and `do_gh_task`) knows what to run it with.

Runs **inline (no fork)** on purpose: §9's `report-tokens.sh` reads the session's
top-level transcript, which holds none of a forked skill's usage (see `kp-do-gh-task`).
Manual, idempotent, loopable. Issue creation, the parent→epic relabel, re-parenting a
prerequisite pulled forward (§6.2, §7) and rewriting the `blocked-by:` / `blocks:` marker
lines of the parent's dependents and of the children (§7) are the only side effects — it
never closes, deletes, implements, or edits the working tree.

**Goal (success criteria — loop until all are true):** the parent is split into
children that each pass the "complete + independently verifiable" bar; each coding
child carries exactly one `type:` and one `model:` label and a body in the coding-item
contract that passed `lint-item.py` and the cold-reader check (§4b); children are linked as
sub-issues of the parent and added to the board; the parent is an open `type:epic`;
re-running creates zero new items.

## The idempotency contract (read first)

`kp-sync-spec-tasks` dedups off the **exact `spec-ref:` line** and skips a requirement
when *any* issue (open or closed) **of the type it would create (`type:coding`)**
already carries that ref (its §2.2). Converting the parent to `type:epic` removes
the only `type:coding` issue carrying the parent ref, which would let a later sync
run **recreate the monolithic coding item**. To prevent that without editing
`kp-sync-spec-tasks`:

- **Children carry the parent's exact `spec-ref:`** — they are slices of the same
  spec obligation. Sync then sees `type:coding` issues carrying the ref → skips; its
  epic-reuse rule reuses the existing epic carrying the ref → no duplicate epic.
- Because siblings share the ref, **this skill dedups children on a `slice:<slug>`
  marker**, not on `spec-ref`. (NOTES.md for the family already permits "one
  `spec-ref` may map to several issues.")

Net: re-running this skill creates 0 children, and `kp-sync-spec-tasks --dry-run` stays
`NEW_ISSUES=0`. No change to `kp-sync-spec-tasks` is required.

## 0. Setup

**First, record the run start time** as ISO-8601 UTC
(`date -u +%Y-%m-%dT%H:%M:%S.000Z`) and keep it — §9 sums token usage from this
moment to the end of the run.

1. **This run's arguments: `$ARGUMENTS` (empty if none). Parse them.** The first bare token is the **item number** (required; if
   missing, stop and ask). Any path/glob token is a **spec source**.
   `--project <number|owner/number|id>` selects the GitHub Project (v2);
   `--repo <owner/name>` selects the repo the issues live in; `--dry-run` drafts and
   checks every child (§4a–§4b) without creating or relabeling anything.
2. **Preamble — one call**, from the current checkout:
   `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --no-item [--project <…>]`, passing
   `--project` only when given (no `--no-fetch`: its sync is §0.3). Do what
   `kp-gh-lib/SKILL.md` § *`preamble.sh`* says with its exit code: `5`, `2` or `1` → stop
   with its message; `6` → **ask** the operator which project, offering the candidates
   it printed on stderr, then re-run with `--project`.
3. **Sync first.** Done by §0.2's preamble.
4. **Resolve the target repo.** In order: `--repo` → config
   `.claude/spec-sync.json` `targetRepo` → otherwise **ask** (offer candidates with
   `gh repo list <owner>`). Never default to the spec repo. Record `<owner/name>`;
   every `gh issue` / `gh label` call below runs against it with `-R <target-repo>`.
   Its **local checkout** is the current one when its `origin` is the target repo,
   otherwise **ask** for the path. Pick its code ref by the current-milestone rule with
   the project §0.2's preamble resolved:
   `~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh --project
   <.project.owner>/<.project.number> --current` exiting `0` with `"milestone": "M<k>"`
   gives `--ref release/M<k>`; `"milestone": null` or a non-zero exit gives no `--ref`,
   and §8 says why (`no milestones`, or the first stderr line). Run
   `~/.claude/skills/kp-gh-lib/scripts/fresh-checkout.sh <checkout> [--ref release/M<k>]`
   on it — the milestone branch when the repo's origin has it, else the default branch
   (its `origin/release/M<k> not found; reading origin/<default>` line says so); the
   directory it prints is `<target-checkout>`, which §4a–§4b read `code:` files from and pass to
   `lint-item.py` and `read-context.sh` — never the raw checkout. Exit `1` stops the run
   with its message.
5. **Record the Project (v2)** from §0.2's preamble: the owner login, number and node id
   are its `.project.owner`, `.project.number` and `.project.id`. The owner login is
   reused in §6 to assign any human-gated child.
6. **Resolve the spec repo and pin it.** In order: config `.claude/spec-sync.json`
   `specRepo` → the `origin` of the local checkout holding the spec docs §2.1 reads
   (`git -C <spec-dir> remote get-url origin`) → otherwise **ask**. Pin its current
   default-branch SHA once for the run:
   `gh api repos/<spec-repo> -q .default_branch`, then
   `gh api repos/<spec-repo>/commits/<branch> -q .sha`. Every child's `spec:` lines and
   Rules attributions use this `<sha>`.

## 1. Read the parent (the gate)

1. **Read the issue.** `gh issue view <n> -R <target-repo> --json
   number,title,labels,state,comments`, and the body only with its human-only fence
   stripped — the fence is a human reading aid, never spec input:
   `gh issue view <n> -R <target-repo> --json body -q .body |
   ~/.claude/skills/kp-gh-lib/scripts/body-parts.py strip`.
2. **Extract** `spec-ref:`, the `type:` label, the Scope section, and the acceptance
   criteria from the body, plus its `serves:` line and `### Context` / `### Rules`
   sections when it has them (§4a starts every child from those).
3. **Type guard.** Only a `type:coding` item decomposes. If given a `type:epic` or a
   human-gated item (`type:decision` / `type:question` / `type:conflict` /
   `type:research`), report why and **stop** — epics are already containers; gated
   items go through `kp-resolve-spec-decision`.
4. **Resumability.** If the parent is already `type:epic` with `slice:` children,
   treat those existing slices as done; this run only adds **missing** slices and
   re-converges. Read the existing children
   (`gh issue list -R <target-repo> --state all --search "parent:#<n>"`, or the
   sub-issue list) so §6 dedup sees them.

## 2. Read the decomposition inputs

The split is driven by the spec and the project's recorded architecture — not by the
parent issue body alone (which is itself a derived summary).

1. **Spec section(s).** Use the `spec-path-or-glob` arguments if given; otherwise
   resolve from `spec-ref` (the `<doc-slug>` maps back to the spec file; for an
   explicit `REQ-*` id, grep the spec docs). Read the cited section(s) in full.
2. **ADRs.** Read **every** `docs/adr/*.md` (fall back to `**/adr/*.md` /
   `**/decisions/*.md` if that path is absent). Treat ADRs as **binding constraints**
   on how slices may be built — never as new requirements to create items for. §4a
   carries each one that applies to a slice into that child's body.
3. **Positioning.** For any UI-facing slice, read `POSITIONING_BRIEF.md` (or the
   spec's positioning doc) — it wins on visual/voice decisions.

## 3. Clarity gate

Walk the spec section against the planned slices. A slice the spec leaves genuinely
ambiguous, contradictory, or silent on (anything affecting behavior, interface, or
scope) is **not** a coding child: type it `type:decision` / `type:question` /
`type:conflict` per the family taxonomy and write its title and body per the
human-gated item body convention in `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Human-gated item body*. Its "To resolve" carries the pasteable resolution prompt
`/kp-resolve-spec-decision <n>`, where `<n>` is the **created child's own number**,
which §6.3's `create-item.sh` substitutes after create, never a metavariable. Route it to a
human. **Do not invent an interpretation** to force a coding slice. Such gated children
get no `model:*` label and are assigned to the project owner (§6). Before creating one, apply `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Before raising a human-gated item*; a goal question raised in its place keeps the
slice's `spec-ref:` / `slice:` / `parent:` / `blocked-by:` lines, so §6.1's dedup finds
it. Order is never such a gap: slice order, milestone placement and a
dependency cycle are settled in §4 and §6 and reported, never routed to a human
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *When an item is human-gated*).

## 4. Propose the split

Identify the parent's natural seams — distinct acceptance criteria, layers,
deliverables, or file groups. Define a child per seam. **Every** slice meets the bar in
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Atomicity bar*.

Order the slices and record dependencies as `blocked-by:` markers (§6); slices sit in
the parent's milestone, so an edge between siblings never crosses one. Print the
proposed split (slice slug, title, model tier, one-line "verifiable because…").
**On `--dry-run`, continue through §4a–§4b, then stop** — create and relabel nothing;
emit the summary (§8) with `NEW_ITEMS=0`.

## 4a. Write each child's contract

Each coding child's body follows `~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item
body* (§6.2). The parent's spec reading does not travel with it: a builder loads only the
child's body and what `read-context.sh` returns for it, so everything that governs the
slice goes into the body, narrowed to that slice.

1. **Start from the parent.** When the parent has a `### Context` (and `### Rules`),
   each child starts from those lines and keeps only the ones that govern its slice.
   Otherwise start from the §2 reading.
2. **`spec:` lines.** One per spec section that governs this slice — not the parent's
   whole set — as `spec: <spec-repo>@<sha>:<path>#<anchor>` with the §0.6 `<sha>`.
3. **Rules.** Quote word for word the binding sentences this slice must honour: spec
   rules and the ADR constraints (§2.2) that apply to it, each attributed to its pinned
   source. A quote longer than the contract's limit becomes a `spec:` line to that
   section (for an ADR, its file or section) instead. A constraint that governs a
   sibling only stays out.
4. **`serves:`** is the parent's `serves:` line, else the `Serves:` line of the
   requirement `spec-ref:` names — never invented.
5. **`code:` lines** for the files the slice touches or must match, found with
   `Grep` / `Glob` in the target repo's checkout. `decision:` and `dismissed:` lines
   cover the rest of the contract's cross-reference sweep.
6. **The rest.** `### Scope` and `### Acceptance criteria` are the slice's, each
   criterion with its `— proof:`; `### Out of scope` names the sibling slices a builder
   might reach into; `### Verify` comes from the target repo's `CLAUDE.md` `## Verify`
   block, else the commands its `CLAUDE.md` / README documents.

Write each draft, ending in its §6.2 marker lines (lint checks `serves:` against
`spec-ref:`), to `/tmp/kp-decompose-gh-task-<n>-<slug>.md` (`<slug>` = the slice slug).
A sibling blocker has no number yet: write `blocked-by: #__SLICE_<slug>__` and replace it
with the sibling's number when §6.3 files this child.

## 4b. Check each child

Runs for every coding child before any `gh issue create` — on `--dry-run` too. Both
scripts take `--code-root <target-checkout>` (§0.4), so `code:` paths resolve there.

1. **Lint.**
   `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <target-repo> --body-file <draft> --code-root <target-checkout>`.
   Exit 1: fix every `FAIL` line in the draft and run it again. Exit 4 (a fetch failure)
   or 2: **stop the run** with that message — never file a child on an unchecked draft.
   Keep the final `INFO` line for §8.
2. **Cold reader.** Run `~/.claude/skills/kp-gh-lib/NOTES.md` § *Cold-reader check* on
   the linted draft: `read-context.sh --code-root <target-checkout> --body-file <draft>
   --repo <target-repo>`, its stdout the only input to the subagent (save it to a file
   and have the subagent read that file and nothing else). Exit 3 (something unresolved)
   is a gap in the draft. Exit 1 (a fetch failure) or 2 **stops the run**. On a gap, fix the draft and run step 1 and this step again.
3. **Two rounds.** A child that still fails after two rounds is re-sliced (back to §4,
   then §4a–§4b for the new slices), or raised as a human-gated slice per §3 and
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item*. A
   question-5 conflict (scope against a non-goal or a higher-ranked quality priority)
   always takes the second path. On `--dry-run`, report what would be raised instead of
   creating it.
4. **Size.** A child that still looks large gets a split suggestion in §8 saying why;
   never trim its context to shrink it.

## 5. Labels

For each coding slice, assess its model tier per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Model-tier rubric* (a human-gated
slice gets none), and create any missing label before use per *Labels* there: one
`~/.claude/skills/kp-gh-lib/scripts/ensure-labels.sh --repo <target-repo>` call with
every label §6 will pass the slices (`type:*`, `model:*`, `repo:<name>`).

## 6. Create the children

**Place the parent chain — once per run,** before the first slice's create
(on a resumed run where every slice exists, still once), per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Every new item has a milestone*. The parent is a
`type:coding` item, or on a resumed run the `type:epic` §7 converted it to — never a
milestone epic — so it is passed as both `--parent` and `--origin`:

`~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh --project <owner>/<number> --repo <target-repo> --cache <scratchpad>/milestone-current-<owner>-<number>.json --origin <target-repo>#<n> --parent <target-repo>#<n>`

`--project` is the project §0.5 resolved. On `link: "<owner/repo#r>"`, link that chain
root as a sub-issue of `epic`:
`~/.claude/skills/kp-gh-lib/scripts/link-item.sh --parent <epic> --child <owner/repo#r>`;
a re-run finds the root already placed and gets
`link: "none"`, which links nothing. When the script exits non-zero, or `link-item.sh`
exits 1, the slices are still created, and the run's milestone line (§8) is the
NOTES line for that case: `milestone: not checked (placement failed: <first stderr
line>)` or `no milestone — sub-issue link failed`.

For each slice, in dependency order, create one issue in the **target repo**:

1. **Dedup first.** `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo> slice <slug>
   --state all` and `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo> parent '#<n>' --state all`;
   the slice exists when an issue number appears in both (the script confirms each line
   outside the human-only fence and `<details>`, so substring matches never collide).
   If it already exists, skip *creation* but **still run step 4** to ensure it is
   linked as a sub-issue and on the board — both are idempotent, so this repairs a
   child left half-wired by a prior run that died mid-block. A gated child carrying
   `goal-ref:` is also repaired per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before
   raising a human-gated item*. Do not skip the whole per-slice block.
2. **Body** — the §4a draft that passed §4b. Its sections, line forms and human-only
   fence are `~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*; what this
   skill adds are the marker lines after the sections, outside the fence:

   ```
   spec-ref: <parent-ref>
   slice: <slug>
   parent: #<n>
   blocked-by: #<m>        # one line per blocker; omit when none
   ```

   `spec-ref:` is the **parent's** ref verbatim (the idempotency contract). `slice:`
   is this skill's dedup identity. Each edge to an existing blocker is checked first
   with `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh --project <owner>/<number>
   draft:<M<k>|none> <blocker> --dependent-epic <epic>`
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing*, hard invariants). A
   slice sits in the parent's milestone: `<M<k>|none>` and `<epic>` are the `milestone`
   and `epic` the placement step above printed, or, when that script failed, the
   parent's `~/.claude/skills/kp-gh-lib/scripts/milestone-of.sh <repo> <n>` result
   (`none` and no `--dependent-epic` when it has none). `ok` → write the line; `cycle` or
   `drop-earlier` → drop it and report it; `pull-forward` → re-parent the blocker to
   `pullForwardEpic`, with the
   note `milestone: M<k> (spec: M<j>) — pulled forward, required by #<slice>` added
   right after step 3 creates the slice; exit `1` or `2` → leave the line unwritten and
   report it. Sibling slices share a milestone, so edges between them are written as-is.
   None of this ever makes a human-gated slice.

   A **human-gated slice** (§3) does not use this shape. Its title and body follow the
   convention §3 names, and the convention's marker block carries the same
   `spec-ref:` / `slice:` / `parent:` / `blocked-by:` lines as above, so dedup and
   linking are unchanged.
3. **Create — one call.** `~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo
   <target-repo> --title "[<REPO-CODE>] <slice title>" --body-file <draft> --label
   type:coding --label model:<tier> --label repo:<name> --project <owner>/<number>
   --link-under <target-repo>#<n>`. It adds the child to the board (Projects v2 are
   cross-repo) and links it as a sub-issue of the parent, which the parent chain
   placement above already placed. Exit `1` means the child was not created: report
   it; note each `skipped` step in its JSON. **Children inherit the parent's repo identification:** if the parent
   title starts with `[<CODE>]`, reuse that code and the parent's `repo:<name>` label;
   otherwise, and under a repo-neutral milestone epic, resolve both per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Repo identification*.
   For a human-gated slice (§3):
   use its `type:*` label, **no** `model:*` label, and `--assign-owner` (assignees must
   be users; on an org-owned project the script skips it, and the run reports that
   auto-assignment was skipped rather than failing). A `type:decision` slice whose every
   Recommendation is `confidence: high` is creator-decided
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items*): write
   its decision comment to `<scratchpad>/decided.md` with `__ISSUE__` and add
   `--decided-body-file <scratchpad>/decided.md`; the script then files it Ready. The
   script substitutes the child's
   own number into its resolution prompt. A goal question raised in its place (§3) is
   created by that NOTES section's steps.
4. **Existing child: link and board.** For a child step 1 found, link it as a sub-issue
   of the parent and make sure it is on the board in one call:
   `~/.claude/skills/kp-gh-lib/scripts/link-item.sh --parent <target-repo>#<n> --child <target-repo>#<c> --project-id <project node id>`
   (the node id §0.5 records). Exit 1 or 3 is reported per child, never fatal.
   Skip this for an existing child whose body carries a `milestone: … pulled forward`
   note (§7): its parent link is the milestone epic it was moved to, and re-linking it to
   the parent would move it back (NOTES § *Milestone sequencing* → *Determinism*: moves
   only go earlier). Its `parent:` marker stays as it is.

## 7. Convert the parent to the epic

Once the children exist (and only then), convert the parent — one call:

```
~/.claude/skills/kp-gh-lib/scripts/epic-convert.sh <target-repo> <n>
```

The parent stays open as the umbrella, its `spec-ref` unchanged. The script relabels it
`type:epic` (dropping `type:coding` and any `model:*`), creates `type:epic` if absent,
prefixes `Sub-Epic: ` once with the repo code kept first (`[<CODE>] Sub-Epic: <rest>`),
and a non-zero exit stops the run before the dependents are re-pointed.

**Re-point the parent's dependents.** An item still `blocked-by` the parent now waits on
an epic, which no build closes, so move each such edge onto the children it needs. This
runs on a fresh run and on a resumed run whose parent is already `type:epic`, never on
`--dry-run` (§4 stops a dry run before §6). Handle dependents, and each dependent's
children, in NOTES § *Milestone sequencing* → *Determinism* order: dependent, then
blocker, each by repo then number.

1. **Find the dependents:** the **open** issues of any type whose body, outside the
   human-only fence, carries `blocked-by: #<n>` (in the target repo) or
   `blocked-by: <owner/repo>#<n>` (any repo of the owner, `<n>` being the parent).
   Find them with `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <target-repo> blocked-by
   <target-repo>#<n> --scope owner`, never a board scan — it searches both reference
   forms and confirms each hit's marker line outside the fence. Human-gated and epic dependents are re-pointed like coding ones.
2. **Pick the children each dependent needs.** Only **open `type:coding`** children are
   candidates; a closed child is already done and gets no edge. The needed children are
   those whose output the dependent consumes, judged by comparing the dependent's Scope
   and acceptance criteria with each child's Scope. When that is unclear, every open
   coding child is needed, and §8 reports `all children (unclear)` for that dependent,
   since pulling all of them forward can move a large set. A child the dependent already
   lists in a `blocked-by:` line counts as needed, and its line is not duplicated. This
   is settled by the skill and never raised as a human-gated item (NOTES § *When an item
   is human-gated*: order is not a question).
3. **Rewrite the dependent's markers.** Remove its `blocked-by:` line for the parent
   with `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <dependent-repo> <d> blocked-by --remove
   <target-repo>#<n>`. Then check each needed child, in NOTES § *Milestone sequencing* → *Determinism*
   order, with `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh --project
   <owner>/<number> <dependent> <child>`. A child whose verdict is `cycle` or
   `drop-earlier`, or whose check exits `1` or `2`, gets no line and is reported as
   dropped. A `pull-forward` child is pulled forward per § *Pulling a prerequisite
   forward*: re-parented to `pullForwardEpic`, its
   `milestone:` note written or extended in place as that section says
   (`milestone: M<k> (spec: M<j>) — pulled forward, required by <ref>`, each further
   requiring item appended), the requiring item written `#<d>` when it is in the child's
   repo and `<owner/repo>#<d>` otherwise. Write one `blocked-by:` line per remaining
   child with `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <dependent-repo> <d> blocked-by --add
   <child-ref>`, `<child-ref>` bare `#<m>` when the child is in the dependent's repo,
   else `<owner/repo>#<m>`. When every child is dropped, the dependent is left with no edge
   for the parent, and §8 says so.
4. **Inverse markers.** Remove the parent's `blocks:` line for that dependent when it
   has one (`~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <target-repo> <n> blocks --remove
   <dependent-ref>`), and add `blocks: <dependent-ref>` to each child that now carries
   the edge (`~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <child-repo> <m> blocks --add
   <dependent-ref>`), in the same bare-or-qualified form seen from the child's repo, one
   line per dependent. Marker lines change only through `set-marker.sh`; the
   pull-forward `milestone:` note in step 3 is still written as § *Pulling a prerequisite
   forward* says.
5. **Idempotent.** A re-run that finds no open item still `blocked-by` the parent
   changes nothing.

Then ensure every child is linked as a sub-issue (§6.3–§6.4), skipping a child pulled forward
— one whose body carries a `milestone: … pulled forward` note is never re-linked to the
sub-epic, since that would move it back. On `--dry-run`, do not relabel or retitle.

## 8. Report / loop control

Print:
- the parent (number, title, original `spec-ref`), the resolved target repo + project;
- the spec repo and pinned SHA, the spec section and the ADR files read;
- `code refs: <repo>=<branch>` — the branch §0.4 read (`release/M<k>`, or the default
  branch after a fallback or with §0.4's no-ref reason);
- a table of slices: **slice | title | type | model | verifiable-because**;
- per coding child: the lint `INFO` line (`bytes`, `acs`, `spec-sections`), the
  cold-reader result (`ok`, or the gaps fixed and rounds taken), and any re-slice,
  raise or size split suggestion from §4b;
- `blocked-by` edges recorded (and any dropped to avoid a dependency cycle or because
  they pointed into an earlier milestone), and every prerequisite pulled forward;
- one line per dependent §7 re-pointed,
  `retargeted <dependent> blocked-by <parent> → <child refs | none>`, with
  `all children (unclear)` appended when §7.2 could not tell which children it needs;
  its moves and drops use the move and drop lines above;
- the sub-issue mechanism used and the board adds: each `link-item.sh` call's `via` and
  `boardItem`;
- one milestone line for the run, since every slice shares it: the placement script's
  report line (NOTES § *Every new item has a milestone* → *Report lines*), plus
  `placed <owner/repo#r> under M<k> (chain had no milestone)` when a chain root was
  linked. `--dry-run` stops before §6 (§4), so it runs no placement and prints no
  milestone line;
- any human-gated slices routed to `kp-resolve-spec-decision`.

The **final line** must be exactly:

```
NEW_ITEMS=<n>
```

where `n` = children actually created (0 on dry-run or a fully-converged re-run) —
the convergence signal for a headless wrapper.

## 9. Report token consumption

As the **final action of every run** — on success *and* on any early stop once work
began — post this run's token usage as a comment on the **parent** issue. Best-effort:
never let it block or fail the deliverable.

1. **Record this run's row** on the parent, from the session's working directory:
   ```bash
   ~/.claude/skills/kp-gh-lib/scripts/report-tokens.sh "<run-start-timestamp from §0>" \
     "<!-- kp-decompose-gh-task:token-usage -->" <target-repo> <n>
   ```
   It adds or rewrites this run's row in the marked table and prints it; the table is
   described in `~/.claude/skills/kp-gh-lib/NOTES.md` § *Token-usage report*. A
   non-zero exit means nothing was written: note it and finish the run.

## Invariants

- **Never emit a slice that isn't independently shippable AND fully verifiable**
  (§4). If a seam can't carry its own acceptance criteria, it isn't a slice — merge
  it or route the ambiguity to a decision item.
- **Each coding child has exactly one `type:` and exactly one `model:` label.**
  Human-gated children carry their `type:` label and no `model:` label.
- **Idempotent:** children share the parent `spec-ref` and dedup on `slice:`; the
  parent keeps its `spec-ref` forever. Re-running creates zero duplicates and leaves
  `kp-sync-spec-tasks` converged (`NEW_ISSUES=0`). An already-existing child is
  *reconciled* (link + board re-ensured), not skipped wholesale, so a child left
  half-wired by a crashed run self-heals; the token-usage comment upserts by marker.
- **`blocked-by` / `blocks` stay acyclic.** Never write an edge that points
  (directly or transitively) back at the slice itself.
- **Edges stay inside one milestone** (§6.2, §7): an earlier-milestone blocker is
  dropped, a later-milestone one is pulled forward, and order is never a human-gated
  slice.
- **No open item is left `blocked-by` a parent this skill turned into an epic** (§7):
  each dependent is re-pointed to the open coding children it needs.
- **Children carry their own contract** (§4a–§4b): no child is filed until
  `lint-item.py` exits 0 and the cold reader answers `ok`, and its rules are the
  slice's, never a bare pointer to the parent's spec.
- **No working-tree edits.** This skill only creates/edits GitHub issues and labels
  and adds board items (its drafts go to `/tmp`) — no worktree, no spec edits, no implementation. Implementation
  is `do_gh_task`'s job; spec changes are `kp-resolve-spec-decision`'s.
- **ADRs are constraints, not requirements** — they shape how slices are built, never
  spawn their own items.
