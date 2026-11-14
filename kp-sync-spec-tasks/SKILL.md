---
name: kp-sync-spec-tasks
description: From a collection of spec docs, create GitHub epics/issues for unimplemented, untracked requirements — each coding item's body the family's coding-item contract pinned to the synced spec commit, checked by lint-item.py and a cold reader before filing — and re-pin open coding items to that commit, flagging changed sections and goal drift. Idempotent; manual-only.
disable-model-invocation: true
context: fork
argument-hint: [spec-path-or-glob] [--repo <owner/name>] [--project <number|owner/number|id>] [--dry-run]
allowed-tools: Read, Grep, Glob, Write, Agent, Bash(gh issue:*), Bash(gh project:*), Bash(gh label:*), Bash(gh repo:*), Bash(gh api:*), Bash(gh pr view:*), Bash(jq:*), Bash(cat:*), Bash(diff:*), Bash(git rev-parse:*), Bash(git log:*), Bash(git -C:*), Bash(~/.claude/skills/kp-gh-lib/scripts/resolve-board.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/item-id.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-of.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/create-item.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/lint-item.py:*), Bash(~/.claude/skills/kp-gh-lib/scripts/read-context.sh:*), Bash(~/.claude/skills/kp-sync-spec-tasks/scripts/refresh-pins.py:*), Bash(~/.claude/skills/kp-gh-lib/scripts/fresh-checkout.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/find-marker.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/comment-once.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/set-marker.sh:*), Bash(printf:*), Bash(for:*), Bash(continue:*), Bash(:*), Bash([:*), Bash(~/.claude/skills/kp-gh-lib/scripts/edge-check.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh:*)
---

# Sync spec tasks → GitHub

Read a collection of spec docs, classify each requirement against GitHub + the
codebase, and create epics/issues **only** for requirements that are
unimplemented AND not already tracked. Manual, idempotent, loopable.

**Convergence invariant:** re-running with no spec/code changes creates zero
items, moves nothing, and prints `NEW_ISSUES=0`. Issue creation, the milestone
re-sequencing of §5 and the pin refresh of §5a are the only side effects — never close or
delete existing issues, and relabel one only with §5a's `needs-contract`.
`kp-backfill-contract` (its §1) is a separate skill with its own side effects; re-running
it converts nothing already converted and raises nothing already raised.

**Never asks:** A missing input stops the run with the flag to pass; the skill never
waits for an answer.

**Contract invariant:** no `type:coding` item is created without a body that passed
`lint-item.py` and the cold-reader check (§4a), and none for a requirement without a
`Serves:` line.

Read `NOTES.md` (same dir) for the sub-issue mechanism, the `gh api` tradeoff,
and the resolution-flow rationale. Read `spec-sync.example.json` for config shape.

## 0. Setup

1. This run's arguments: `$ARGUMENTS` (empty if none). `--backfill-contract` prints
   `use /kp-backfill-contract` and stops before anything else. Otherwise parse them: a
   path/glob is the spec source; `--repo <owner/name>` selects the target repository for created issues; `--project <number|owner/number|id>`
   selects the target GitHub Project (v2); `--dry-run` sets dry-run, which drafts and
   checks every new coding item (§4a) and creates nothing.
2. **Spec source.** If a path/glob was given, use it. Else discover via, in order:
   `docs/specs/**/*.md`, `specs/**/*.md`, `SPEC*.md`. If none match, print
   `NEW_ISSUES=0` and stop with a note that no specs were found.
3. **Config.** If `.claude/spec-sync.json` exists in the working dir, read it for
   `project`, `labels`/`typeLabels`, `epicMapping`, `requirementRepos` and `specRepo`. Otherwise use defaults
   (see example file). Never hardcode repo paths or assume project context — this
   skill is global and forked.
4. **Target project (required).** Resolve the GitHub Project (v2) to attach every
   created issue to, in order: the `--project` argument → config `project` →
   otherwise stop the run; print `no project given; pass --project <owner/number>` and
   then the candidates (`gh project list --owner <repo-owner>`, `gh project list
   --owner @me`), with `NEW_ISSUES=0` as the last line. Do not invent or default a
   project. Record its **owner login and number** — the owner login is reused in §5
   to assign human-gated items.

   **Resolve the project id + `Priority` field — 1 point.**
   `~/.claude/skills/kp-gh-lib/scripts/resolve-board.sh <owner> <number>` prints the
   project node id together with the `Priority` field id and all its option ids in
   board order (`priority` is `null` when the board has no such field).

   Capture the option id for the **highest** priority (commonly `High` / `Urgent` /
   `P0`, else the top-listed option; if the naming is ambiguous,
   take the top-listed option and note the choice in the summary). If the board has no `Priority` field, skip
   prioritisation as best-effort and note it in the summary. §5's `create-item.sh` adds
   each created issue to the board (skip on dry-run).

   **GitHub API budget (family convention).** Keep this preamble ≤5 points — never
   `gh project field-list` or a board-wide `gh project item-list` — and read the
   remaining budget from `X-RateLimit-Remaining`, never `gh api rate_limit`. A
   secondary-limit `403` is a park/escalate reason, not a crash (stop issuing calls,
   report it, resume later); the rules and their rationale are in
   `~/.claude/skills/kp-gh-lib/NOTES.md`.
5. **Target repository (where the work lives).** Created issues describe
   implementation work, so they belong in the repo that work will be built in —
   the **app/service repo**, never the spec repo by default. Resolve in order:
   the `--repo` argument → config `targetRepo` → otherwise stop the run; print
   `no target repo given; pass --repo <owner/name>` and then the candidates from
   `gh repo list <spec-repo-owner>`, with `NEW_ISSUES=0` as the last line. Do not default to the spec repo. Record the resolved
   `<owner/name>` as the **target repo**.

   **The ref's repo.** Each spec-ref (§1) resolves its own repo, first match wins:
   1. config `requirementRepos[<AREA>]` `repo`, where `<AREA>` is the area of an
      explicit `REQ-<AREA>-<nnn>` id and the entry is an object (the `note` string
      is not an area) — a derived `<doc-slug>#<heading-path-slug>` key has no area
      and never matches;
   2. the `epicMapping` override `repo` for the ref's doc/section;
   3. the target repo (`--repo` / `targetRepo`).

   Call the result `<ref-repo>`; a ref is **routed** when it came from
   `requirementRepos`. It stands in for the target repo everywhere a ref is
   concerned — §2 classification and dedup, §3 detection, §4–§5 creation, labels, the
   `[<REPO-CODE>] ` prefix, the `repo:` label and the board add — so **every**
   `gh issue create` / `gh label create` / sub-issue lookup for a ref's item runs
   with `-R <ref-repo>`. A ref whose area has no entry resolves exactly as it did
   before `requirementRepos` existed. An epic is not a ref: it goes in the repo its
   doc/section resolves to (`epicMapping` override `repo` → target repo).
6. **Bootstrap when the target repo does not exist.** Probe with
   `gh repo view <owner/name>`. If it does not exist yet:
   - Create **exactly one** bootstrap issue — the *only* item this skill may ever
     create in the spec repo. Create it only once the §0.9 clone check and, under the
     `milestone` strategy, the §1 milestone table check have passed: each stops the run
     before anything is created, this issue included. Type it `type:coding`, title it
     e.g. `Create <name> repository and scaffold the project`, and give it the stable
     `spec-ref: repo-bootstrap:<owner/name>`. Dedup it like any other item
     (`~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <spec-repo> spec-ref
     repo-bootstrap:<owner/name> --state all`); never recreate it. Add it to the project board
     like any other item (§0.4) and count it toward `NEW_ISSUES`.
   - Create **no other items this run** — they have nowhere to live. Report each
     remaining candidate as **blocked-on-repo-bootstrap** in the summary.
   - On a later run, once the repo exists, resume normal creation in the target
     repo; the bootstrap issue is closed when the repo has been created.
7. **Repo guard.** `git rev-parse --is-inside-work-tree` must succeed and `gh`
   must be authenticated. If not, stop with a clear message.
8. Record the base SHA: `git rev-parse HEAD`.
9. **Validate routed clones.** Before §2 classifies anything, pick the code ref by the
   current-milestone rule with the project §0.4 resolved:
   `~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh --project <owner/number>
   --current` exiting `0` with `"milestone": "M<k>"` gives `--ref release/M<k>`;
   `"milestone": null` or a non-zero exit gives no `--ref`, and the report says why
   (`no milestones`, or the first stderr line). Then run
   `~/.claude/skills/kp-gh-lib/scripts/repo-roots.sh --spec-dir <spec-dir> --spec-files
   <spec files> [--ref release/M<k>]` from the run's repo root (`kp-gh-lib/SKILL.md`
   § *`repo-roots.sh`*). It checks every `requirementRepos` area (a work tree whose
   `origin` is the entry's `repo` and that fetches) and prints one JSON object. Record
   each area's `repo`, branch read (`branch`, a bare name: `release/M<k>` when that
   area's origin has it, else its default branch — repo-roots passes the
   `origin/release/M<k> not found` line on for each area that fell back), `sha` and
   **code root** (`codeRoot`: the milestone branch's export, or for the default branch
   the clone itself, fast-forwarded, or an export of `origin/<default branch>` when the
   clone has local edits, is on another branch or has diverged). §3 reads that commit.
   Every `--code-root` this skill passes for a routed repo (§4a *Check*;
   `kp-backfill-contract` §1, its stale-label pass included) is that code root, never
   `<path>`. Exit `1` (a failed check) **stops** the run before anything is created — on
   dry-run too — quoting its stderr line, which names the area, the path and the failed
   check.
10. **Pin the spec commit.** From the same §0.9 JSON, record the **spec repo**
    (`specRepo`: config `specRepo`, else the spec checkout's `origin`), its bare default
    branch (`specBranch`) and the **synced SHA** (`specSha`). Every coding item's `spec:`
    lines and Rules attributions pin this SHA (§4a). The script has already pulled a
    clean spec checkout on that branch up to the synced SHA and, given `--spec-files`,
    stopped with exit `1` (`spec: dirty`, naming the files) when the spec docs this run
    reads differ from that commit: a body pinned to a commit whose text it was not
    drafted from fails lint.

## 1. Parse requirements → stable keys

Split each spec into discrete requirements (one testable obligation each).

- **Prefer explicit requirement IDs** present in the docs (e.g. `REQ-AUTH-001`).
- If absent, derive `<doc-slug>#<heading-path-slug>` and **WARN** in the output:
  heading renames break continuity — recommend the user add explicit IDs.

The chosen key is the `spec-ref` and is the dedup identity for the requirement's
whole lifecycle (a decision issue and the coding issue that resolves it share it).

**Milestone table (`epicMapping.strategy: "milestone"` only).** Find it across the spec
docs in the run and place each ref by it, per `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Creating an item* → *Picking the parent epic*. If no table or several tables qualify,
**stop** before anything is created — on dry-run too — with a message naming the docs
searched or the tables found. An unplaced ref is handled by §2.5. §5 parents a new item
by this placement, and sequences its edges by the milestone of the parent it picks.

## 2. Classify each spec-ref

Run, in this order; first match wins.

1. **Tracked-as-blocked** — any *open* `type:decision` / `type:question` /
   `type:research` / `type:conflict` issue carries this ref →
   **BLOCKED**, skip, report as blocked-on-human. Do not also create a coding issue.
   An issue carrying `goal-ref:` is first repaired per
   `~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item*, with
   the technical item drafted as §5 would.
2. **Already tracked for the needed type** — any issue (open or closed) of the
   type you would create already carries this ref → **skip creation**. Before moving
   on, if that existing issue is missing from the project board or from its epic's
   sub-issue links (e.g. a prior run died after `gh issue create` but before the
   board-add / link step), re-ensure those — both are idempotent — so a
   half-provisioned item self-heals instead of staying orphaned. **A pulled-forward
   item is not orphaned.** When the epic link looks missing, first check where the item
   sits: if its parent chain (`~/.claude/skills/kp-gh-lib/scripts/milestone-of.sh
   <repo> <n>`) — or, on the task-list fallback, an earlier milestone epic's task list —
   already places it under a milestone epic **earlier** than the one the spec plans, it
   was moved there on purpose and carries the `milestone: … pulled forward` note. Count
   it as linked and skip the re-link: moves only go earlier
   (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Milestone sequencing*), and a re-link would
   fail on its existing parent, add it back to the old epic's task list, or move it back
   into the later milestone.
3. **Resolved** — a closed decision issue plus an existing downstream coding
   issue for the ref → **skip creation**. Before moving on, check the spec actually
   caught up: if either issue records a `spec-pr: <url>` marker, read that PR's state
   (`gh pr view <url> --json state,mergedAt`). If it is **not merged**, the decision
   is closed while the spec text still says the old thing — report the ref as
   **spec-drift** with the PR URL and `/kp-resolve-spec-decision <n>` for the decision
   issue: that re-run drives the PR to merged and syncs its items to the merged text,
   which merging by hand skips. Never merge it yourself, and never re-create the item. A resolved ref with no `spec-pr:` marker
   and a recorded `no spec change: <why>` is fine; one with neither is reported as
   spec-drift too (the resolution left no trace either way).
4. **Implemented** — code satisfies the requirement (§3) → **skip**; if an open
   issue still carries the ref, report it as a **close-candidate** (never auto-close).
5. **Otherwise** (untracked, unimplemented) → **create** per §4–§5. Under the
   `milestone` strategy an **unplaced** ref (§1) is the exception: report
   `unplaced <ref> (rows: <ids or none>)` and create nothing for it — no coding item
   and no human-gated item.

**Dedup is authoritative against GitHub, not any local file.** Before any create,
run `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <ref-repo> spec-ref <key> --state all`
(the bootstrap issue from §0.6 is the sole exception — dedup it against the spec
repo, where it lives). It returns only issues carrying the exact `spec-ref:` line
outside the human-only fence and `<details>`, with each one's `state` and `labels` —
what §2.1–§2.3 classify by. Create only when no issue with that exact key exists in
the relevant state.

**Every lookup in this section runs against `<ref-repo>`** (§0.5). When `<ref-repo>`
differs from the target repo, run each one against both repos and count a match in
either, so an item filed before its ref was routed is still found — including an
open human-gated issue that makes the ref **BLOCKED** (§2.1).

## 3. Implementation detection (the expensive step)

Decide whether code already satisfies each candidate ref — every ref §2.1–§2.3 left
unmatched — by mapping the requirement to the symbols/files/endpoints/tests that would
exist if it were done. §2.4 and §2.5 then read the verdicts.

**The search runs in one subagent.** Its grep and read output is large and no later step
needs it, so launch one `Explore` subagent with the Agent tool and
`run_in_background: false`, for every candidate ref the cache below does not settle; the
call blocks until the result is back. Charge it read-only — search and read only: no file
edits, no commits or pushes, no GitHub writes — and give it, per ref, the key, the
requirement text and, for a routed ref, its clone path, §0.9 `branch` and §0.9 SHA.
It searches the codebase with `Grep`/`Glob`/`Read`, except that **a routed ref (§0.5) is
detected in its own repo**, not in the checkout the run started in. It reads the
`origin/<branch>` commit §0.9 fetched (`<branch>` the area's `branch` from repo-roots'
JSON: the milestone branch, else the default branch), never the clone's working tree,
so a stale local branch cannot hide merged code:
`git -C <path> grep -n <pattern> origin/<branch>` in place of `Grep`,
`git -C <path> ls-tree -r --name-only origin/<branch>` in place of `Glob`, and
`git -C <path> show origin/<branch>:<file>` in place of `Read`.
It replies with exactly one line per ref and nothing else:

```
<key> | implemented | <file:line evidence> | <files the verdict depends on>
<key> | unimplemented | none | <files the verdict depends on>
```

A ref the reply does not cover, or whose line does not parse, is **unimplemented**: its
create is still dedup-guarded (§2), while a wrong skip would drop the requirement
silently.

Optional cache `.claude/spec-sync-cache.json`, keyed by `spec-ref`, each entry
storing the verdict + the SHA it was based on: `git rev-parse HEAD`, or for a routed
ref the SHA §0.9 recorded for the repo it read. Reuse a
verdict only if the SHA is unchanged and the files it depended on (the reply's last
field) are unchanged;
otherwise re-evaluate. The cache is **advisory/regenerable** — never a dedup
authority. On dry-run, you may read it but do not rely on it for correctness.

## 4. Item typing (exactly one `type:` label)

Assign each created item exactly one `type:` label. Taxonomy comes from config
(`typeLabels`); ship these defaults:

| label           | when                                                              |
|-----------------|-------------------------------------------------------------------|
| `type:coding`   | implementable; requirement is **unambiguous** enough to build     |
| `type:decision` | needs a binding human design decision (ambiguous/underspecified)  |
| `type:question` | needs info/clarification from a human (not a binding design choice)|
| `type:research` | needs investigation/spike before it can be specced or estimated   |
| `type:conflict` | two or more spec docs contradict each other on what to build      |
| `type:epic`     | container/parent (see §5)                                         |

Classify `type:coding` **only if unambiguous**. If unclear, classify as
decision / question / research / conflict and do **not** also create a coding
issue for the same ref. Only technical and feature unknowns are unclear: build order —
which requirement comes first, which milestone it lands in, a dependency cycle — is
settled in §5 and reported, never typed decision / question / conflict
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *When an item is human-gated*). An unclear ref
whose answer turns on a domain goal the spec never states is raised as a goal question
instead (§5, *Climb before raising*). The set is
**extensible**: if specs imply a category not listed, create a new `type:<x>` label and
report it in the summary.

Create any missing label before use, per `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Creating an item* → *Labels*.

### Model tier (`type:coding` items only)

Every `type:coding` item **also** gets exactly one `model:*` label, per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Model-tier rubric*;
non-coding (human-gated/epic) items get none.

## 4a. Write and check each coding item's contract

Runs for every `type:coding` item §2.5 would create — on dry-run too — after its blockers
(§5 *Blockers*) are known and before any `gh issue create`. Tracked, blocked, resolved,
implemented and unplaced refs get no draft. Epics, the §0.6 bootstrap issue and
human-gated items keep the §5 body shapes.

Draft each body and check it per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item
body* → *Drafting from a spec section*: its *Draft* steps 1–8, the draft path, *Raising a
spec gap*, *Check* steps 1–4 and *Budget*. Its bare `§` cites are this skill's sections.

## 5. Create items

**Epics.** Pick each item's parent epic per `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Creating an item* → *Picking the parent epic*. A doc or section epic is reused when
one already carries its `spec-ref`, otherwise created. Under `epicMapping.strategy:
"milestone"`, the §2 dedup search returns the ref's sub-epic, and a missing milestone
epic is created in the repo §0.5 resolves for the milestone table's doc.

Never create a doc-level or section-level epic under the milestone strategy. The parent
chosen here is "its epic" everywhere else in this skill, §2.2's re-link included. A
re-link may create a missing milestone epic by that subsection's step 2, as a new item
does, and counts it toward `NEW_ISSUES`. A tracked ref that is unplaced (§1) has no `M<n>` and so no parent: when
its item's epic link is missing, leave it unlinked and report
`unlinked <ref> #<n> — unplaced (rows: <ids or none>)`.

**Link children to the epic** per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an
item* → *Sub-issue linking*.

**Milestone placement.** Place each item this run creates per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Every new item has a milestone*, whatever its
type — a coding item and a human-gated item (`type:decision`, `type:question`,
`type:conflict`) alike, each by its parent. A §4a spec-gap question, or a goal question
created in an item's place, takes the parent the replaced item would have had. None has
an `--origin`:

`~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh --project <owner>/<number> --repo <ref-repo> --cache <scratchpad>/milestone-current-<owner>-<number>.json [--parent <owner/repo#n>]`

`--project` is §0.4's owner login and number. Run it, with only the parts that apply, by
case:
- Under a non-milestone `epicMapping`, a doc or section epic this run creates: run with
  no `--parent`.
- Under a non-milestone `epicMapping`, an item created under a doc or section epic this
  run created: not run; it inherits its milestone through that epic.
- Under a non-milestone `epicMapping`, an item created under an existing doc or section
  epic: run with `--parent <that epic>`.
- Under `epicMapping.strategy: "milestone"`, an item §5 *Epics* parents: not run (the
  NOTES exception). Its milestone is `milestone-of.sh` on that parent — for a `REQ-*`
  sub-epic, which may be earlier than the ref's `M<n>` — or the parent's own id when the
  parent is a milestone epic. A milestone epic §5 creates is exempt.
- Under either strategy, the §0.6 bootstrap issue: run with no `--parent`.

On a real run `create-item.sh` (§5 *Create*) does the placement and the epic link: a case
above that runs the script with `--parent <epic>` passes that flag to `create-item.sh`;
one run with no `--parent` passes neither; an item that is not run — under an epic this
run created, or a milestone-strategy parent — passes `--link-under <its epic>` instead;
and a milestone epic §5 creates passes `--no-place`. The script is read-only apart from
its cache file, so on dry-run it runs alone to report the planned placement, and nothing
is linked. §2 step 5 still creates nothing for an unplaced ref, and the
§2.2 re-link of an already-tracked unplaced item keeps the `unlinked … unplaced` line
above: it touches an item created earlier, so the script never runs for it.

**Human-only fence (every created issue).** Each body begins with a short,
plain-language description **for human readers only**, fenced so the skills skip
it on later reads, per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-only fence*.
Keep it to 1–2 lines. On a `type:coding` item the sections below
the fence are the contract (§4a), pinned to the synced spec SHA: the body is what a
builder builds from. All machine markers stay **outside** the fence, below it:

```
<!-- human-only:start (not LLM/spec context) -->
> **For humans:** <one- or two-line plain summary of what this task is / why it exists>
<!-- human-only:end -->

spec-ref: <key>
```

Apply this to **every** created item — coding, decision/question/conflict/research,
and epics alike. On a decision/question/conflict item, the blurb says what is stuck and
what needs deciding, per the convention named in "Unclear requirements" below.

**Every created issue body** contains the line `spec-ref: <key>` (outside the
`human-only` fence).

**Blockers → `blocked-by:` (every created item).** Before creating an item for
ref `R`, determine what must complete before it:
- any **open** human-gated issue (`type:decision` / `type:question` /
  `type:conflict` / `type:research`) carrying `blocks: R`, found with
  `~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <repo> blocks R` in `R`'s
  `<ref-repo>` and, when that differs, in the target repo too; and
- any **prerequisite requirement** that `R`'s spec text declares a dependency on
  (e.g. "depends on / requires / after REQ-X"). Resolve the prerequisite to its
  tracking issue via `spec-ref:` when one exists; otherwise reference it by its
  `spec-ref` key (a later run reconciles it to a number).

For each blocker, add a marker line **outside** the fence:
`blocked-by: #<issue-number>` (preferred) or `blocked-by: <spec-ref>` when not yet
tracked. When the blocker and the item are in different repos, the number is qualified:
`blocked-by: <owner>/<repo>#<issue-number>`. Omit the line entirely when there are no blockers. The blocker issue
carries the inverse `blocks:` marker, so the relation is recorded from both ends.

**Acyclicity and milestones (hard invariants)** per `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Milestone sequencing*: every edge stays acyclic and inside one milestone, and
milestones run in order. Before writing each `blocked-by:` line or its inverse `blocks:`
line, check the edge with `~/.claude/skills/kp-gh-lib/scripts/edge-check.sh --project
<owner>/<number> <dependent> <blocker>`; for a dependent this run has not created yet,
pass `draft:<M<k>|none>` — the milestone the spec's milestone table plans for it (under
the `milestone` strategy, the milestone of the parent §5 *Epics* picks, per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* → *Picking the parent
epic*) — with `--dependent-epic` naming that milestone's epic. Act on its `verdict`:
`ok` → write the edge; `cycle` → drop the line and report the pair as a cycle;
`drop-earlier` → drop it and report
`dropped X blocked-by Y (M<j> runs before M<k>)`; `pull-forward` → pull the blocker
forward to `pullForwardEpic` first — created under it when this run files it,
re-parented to it when it exists — with the note
`milestone: M<k> (spec: M<j>) — pulled forward, required by #<n>`, then write the edge.
A blocker not yet tracked (`blocked-by: <spec-ref>`) has no issue to check and is written
as-is. Exit `1` or `2` checks nothing: leave that edge unwritten and report it with the
first stderr line. Ordering never creates a human-gated item.

**Re-sequencing tracked items (every run).** The same rules repair a board filed before
them. List the open tracked items carrying a `blocked-by:` line
(`~/.claude/skills/kp-gh-lib/scripts/find-marker.sh <repo> blocked-by --any-value` for the target repo
and every `requirementRepos` repo — one entry per confirmed `blocked-by:` line, its
`value` the blocker) and check each, in the order the NOTES fix, with `edge-check.sh`:
remove a line whose verdict is `drop-earlier` with `~/.claude/skills/kp-gh-lib/scripts/set-marker.sh <its-repo> <m>
blocked-by --remove <value>` (`<value>` from the `find-marker.sh` entry), and pull a `pull-forward` blocker forward
to its `pullForwardEpic`. Change only the marker lines, the `milestone:` note and the parent link. Moves only
go earlier, so the next run on an unchanged spec changes nothing and prints
`NEW_ISSUES=0`. On dry-run, report what would change and change nothing.

**Unclear requirements → resolution items.** A decision/question/conflict item's
title and body follow the **human-gated item body convention** in
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body*. After the
`[<REPO-CODE>] ` prefix, the title is the question in plain words; REQ/AC refs and spec
excerpts go in `<details>`. Within that shape, the body MUST contain:
1. The sections the convention prescribes, in its order and within its writing rules.
2. `spec-ref: <key>` and `blocks: <key>` (plus any `blocked-by:` from above), in the
   convention's marker block.
3. In "To resolve", a pasteable resolution prompt of the form `/kp-resolve-spec-decision <n>`,
   carrying the **created issue's own number** in place of `<n>`, substituted after
   create per `~/.claude/skills/kp-gh-lib/NOTES.md` § *Creating an item* →
   *Pasteable-prompt `__ISSUE__` substitution* — `create-item.sh` does it. (The companion skill executes the
   resolution; this skill never resolves.)

**Climb before raising.** Draft the item as above, then apply
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Before raising a human-gated item* before
creating it. A goal question raised in its place keeps `spec-ref: <key>`,
`blocks: <key>` and any `blocked-by:`, so the next run classifies the ref as
tracked-as-blocked (§2.1) and creates nothing; its assignee, priority, repo
identification and epic link are the technical item's.

**Assign human-gated items to the project owner.** Every item that awaits a human
— `type:decision`, `type:question`, `type:conflict`, `type:research` — must be
assigned to the resolved project's owner login (from §0) at creation: `create-item.sh
--assign-owner`. Coding and epic items are not auto-assigned. Note: GitHub assignees
must be **users**; on an org-owned project the script skips the assignee, and the run
reports that the item could not be auto-assigned instead of failing.

**Prioritise human-gated items on the board.** Those same items — `type:decision`,
`type:question`, `type:conflict`, `type:research` — block downstream work and must
surface for the human, so set them to highest priority: `create-item.sh --priority top`
sets the board's `Priority` field to its top option.

Coding and epic items are not auto-prioritised. This is
best-effort: if §0.4 found no `Priority` field, skip and note it. Prioritise
nothing on dry-run.

**Repo identification** — the `[<REPO-CODE>] ` title prefix and `repo:<name>` label on
every created item, epics and the bootstrap issue included, and a milestone epic
repo-neutral even when §5 reuses one — per `~/.claude/skills/kp-gh-lib/NOTES.md`
§ *Creating an item* → *Repo identification*. A ref's item takes the code of `<ref-repo>`.

**Create** with one call per item —
`~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo <ref-repo> --title
"[<REPO-CODE>] ..." --body-file <draft> --label type:<x> --label repo:<name> --project
<owner>/<number> --cache <scratchpad>/milestone-current-<owner>-<number>.json` plus the
*Milestone placement* flags above. A `type:coding` item's `<draft>` is the draft §4a
checked, never a body written after the check (+ `--label model:<tier>` for
`type:coding` items per §4, + epic label if
configured, + `--assign-owner --priority top` for human-gated items, +
`--decided-body-file <scratchpad>/decided.md` for a creator-decided `type:decision` — the
technical item itself, every Recommendation `confidence: high`, its comment written per
`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items* — which the
script then files Ready; a milestone epic drops the
`[<REPO-CODE>] ` prefix and the `repo:` label) — all
items, epics included (a milestone epic unprefixed and unlabelled), go in the repo
§0.5 resolves for them (a ref's item in `<ref-repo>`, an epic in its doc/section's
repo); the only exception is
the §0.6 bootstrap issue, which is created in the spec repo (prefixed with the
**target** repo's code, since that is the repo it is about). The script adds the issue
to the resolved project board (§0) — Projects (v2) are cross-repo, so that works
regardless of the issue's repo. Exit `1` (the create failed) is reported for that ref;
each `skipped` step in its JSON is noted in the summary. On
dry-run, create nothing and assign nothing.

## 5a. Refresh pins

Runs on every sync after §2 has matched the items, and on dry-run too, where it only
plans. It keeps open coding items pinned to the §0.10 synced SHA, so nothing is built
against outdated spec text. It changes nothing when an item is already pinned there, so a
re-run on an unchanged spec edits nothing.

1. **List the items.** For the target repo and every `requirementRepos` repo:
   `gh issue list -R <repo> --state open --label type:coding --search '"spec:" in:body'
   --limit 1000 --json number,body,labels`. Keep each item with at least one `spec:` line
   outside the human-only fence whose repo is the spec repo.
2. **Plan each item.** Save its body byte for byte
   (`gh issue view <n> -R <repo> --json body -q .body > /tmp/kp-pins-<n>.md`), then run
   ```bash
   ~/.claude/skills/kp-sync-spec-tasks/scripts/refresh-pins.py --spec-dir <spec-dir> \
     --spec-repo <spec-repo> --sha <synced SHA> \
     --body-file /tmp/kp-pins-<n>.md --out /tmp/kp-pins-<n>-new.md
   ```
   It compares each pin — every `spec:` line and every Rules attribution of the spec repo
   — with the same anchor at the synced SHA, by the section text `spec-index.py`'s parser
   gives, reading both commits from the §0.10 clone. It prints one JSON plan and writes the
   refreshed body. Pin statuses:
   - `current` — already at the synced SHA. Nothing to do.
   - `unchanged` — identical section text. The refreshed body bumps only that pin's
     `@<sha>`.
   - `changed` — the section text differs. The pin is bumped, and `diff` holds the
     section diff.
   - `missing` — the anchor or its file is gone. The pin keeps its old SHA.

   `goalDrift` lists each `serves:` goal of an item whose goal frame changed between its
   first pin's SHA and the synced SHA: `removed`, `non-goal` (now named under non-goals),
   or `changed` (its defining line was reworded). Judge a `changed` entry: it is drift only
   when the id now names a different outcome. A reworded target for the same outcome is
   not drift; drop it from the report. Exit 4 means the clone lacks a pinned commit: report
   `pins-unreadable #<n> — <stderr>` and leave the item untouched. Exit 2 stops the run.
3. **Check a changed item.** When any pin is `changed`, run §4a *Check* steps 1–2
   (`lint-item.py`, then the cold reader) on the refreshed body, with the item's repo and
   `--code-root`. There is no fix round. A `FAIL`, a cold-reader gap, or a check that
   could not run (lint exit 2 or 4, `read-context.sh` exit 1 or 2) is a failed check.
4. **Act.** How an item is handled depends on its board Status
   (`~/.claude/skills/kp-gh-lib/scripts/item-id.sh <repo> <n> <project-id>`). Only look it
   up for an item that has something to act on.
   - **Ready, Backlog, Blocked, or not on the board.** When `bodyChanged` is true, write
     the refreshed body with `gh issue edit <n> -R <repo> --body-file
     /tmp/kp-pins-<n>-new.md`. That file differs from the saved body only in the bumped
     SHAs, so every other line, markers included, stays byte-identical. Never write a
     body you edited by hand. Add `needs-contract` (created with `gh label create
     needs-contract -R <repo> --color D93F0B --force`) when a check failed, a pin is
     `missing`, or a goal drifted.
   - **In progress or In review.** The body and labels are never edited. The item gets
     the comment below only, and it is listed in the report as `in-flight #<n>`.
   - **Comment** on any item with a `changed` or `missing` pin, a failed check, or goal
     drift. The first line is `<!-- kp-sync-spec-tasks:pins <synced SHA> -->`. Write the
     comment to a file and post it with
     `~/.claude/skills/kp-gh-lib/scripts/comment-once.sh <repo> <n> --marker '<!-- kp-sync-spec-tasks:pins <synced SHA> -->' --body-file <file>`,
     which posts nothing when a comment already carries that line. The comment says:
     - for each `changed` pin, `section changed: <path>#<anchor> <old>..<new>`, with its
       `diff` inside `<details>`;
     - for each `missing` pin, `anchor missing: <path>#<anchor> at <new>`;
     - each failed check's `FAIL` lines or gaps;
     - for each drifted goal, `goal changed: <old line> → <new line or removed>`.
   - **Dry-run** writes, labels and comments nothing. It prints each item's plan instead:
     the pins it would bump with their statuses, the labels it would add, and the
     comment it would post.
5. **Count** for §6: `pins bumped` (items whose body was, or on dry-run would be,
   rewritten), `sections changed` (items with a `changed` pin), `needs-contract` (items
   labelled, or that would be; in-flight items are listed there too but never labelled),
   and `goal-drift` (items with a drifted goal).

The pin plan is testable offline: `kp-sync-spec-tasks/tests/refresh-pins/run.sh` runs the
script on crafted bodies against a throwaway two-commit spec repo.

## 6. Output / loop control

Print a summary table with columns:
**spec-ref | repo | type | model | milestone | state | action** (state ∈ untracked / tracked-unimplemented / blocked /
blocked-on-repo-bootstrap / implemented / resolved / spec-drift / unplaced; action ∈ create /
skip / close-candidate / merge-spec-pr / blocked). The **repo** column is the repo each item went to
(or would go to) — `<ref-repo>` per §0.5 — making the spec-repo bootstrap exception visible; the **model**
column is the `model:*` tier for `type:coding` items (blank for others). The
**milestone** column, for a created item, holds the § *Every new item has a milestone*
report line for the §5 placement script's output, the parent epic's cell for an item
that inherits, or `milestone: M<k>` for an item under an epic §5 *Epics* chose, `M<k>`
being that item's milestone as §5 *Milestone placement* states; it is blank for any
other row.

Emit warnings for derived (non-explicit) keys, any new `type:`/`model:` labels
created, any `blocked-by` edge dropped because it would have closed a dependency
cycle, every milestone move and every cross-milestone edge dropped (§5, one line each,
tracked items re-sequenced this run included), any human-gated item left un-prioritised
because the board has no
`Priority` field, and every **spec-drift** ref (§2.3) — a resolved decision whose
spec PR is still unmerged, listed with its PR URL and `/kp-resolve-spec-decision <n>`,
every **unplaced** ref (§2.5) as `unplaced <ref> (rows: <ids or none>)`, and every
tracked unplaced item left unlinked (§5) as
`unlinked <ref> #<n> — unplaced (rows: <ids or none>)`, and every
`placed <owner/repo#r> under M<k> (chain had no milestone)` line from §5 *Milestone
placement*.

For each new coding item (§4a), print its lint `INFO` line and its cold-reader result
(passed, or the questions that failed and what was raised), plus any split suggestion;
on dry-run also print each checked draft body. Print every `spec-gap <ref> — no Serves:
line` with the question raised (or, on dry-run, that would be raised), every
`no-verify-block <ref-repo>`, and one count line:
`contract-checks: lint=<runs> cold-reader=<runs>`. Print one
`code refs: <area>=<branch> …` line from §0.9's repo-roots JSON, followed by §0.9's
no-ref reason when it passed no `--ref`.

Then print the §5a report as four sections, each headed with its count and listing
`<repo>#<n>` per item plus what changed: `pins bumped (n)`, `sections changed (n)`,
`needs-contract (n)` (each with its reason: failed check, missing anchor, goal drift, or
`in-flight` for an item commented on but not labelled), and `goal-drift (n)` (each with
its `goal changed:` lines). Also print every `pins-unreadable` item.

The **final line** must be exactly:

```
NEW_ISSUES=<n>
```

where `n` = items actually created (0 on dry-run). This is the convergence
signal for a headless `while` wrapper, e.g.:

```bash
while :; do
  out=$(claude -p "/kp-sync-spec-tasks docs/specs/" --autocompact 150k \
    --settings ~/.claude/skills/kp-gh-lib/scripts/headless-settings.json) ; echo "$out"
  [ "$(printf '%s\n' "$out" | tail -1)" = "NEW_ISSUES=0" ] && break
done
```
