---
name: kp-backfill-contract
description: Rewrite open coding items filed before the coding-item contract into that contract (keeping their Scope, AC and marker text), folding in the answers the code, spec or Scope settle, converting an item once lint and the cold reader pass, and labelling only an item with an open gap or a non-gap failure needs-contract, with one human-gated item raised for its open gaps. Idempotent; manual-only.
disable-model-invocation: true
context: fork
argument-hint: [spec-path-or-glob] [--repo <owner/name>] [--project <…>] [--limit <n>] [--dry-run]
allowed-tools: Read, Grep, Glob, Write, Agent, Bash(gh issue:*), Bash(gh project:*), Bash(gh label:*), Bash(gh repo:*), Bash(gh api:*), Bash(gh pr view:*), Bash(jq:*), Bash(cat:*), Bash(diff:*), Bash(git rev-parse:*), Bash(git log:*), Bash(git -C:*), Bash(~/.claude/skills/kp-gh-lib/scripts/preamble.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/item-id.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/backfill-candidates.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-of.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-place.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/create-item.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/lint-item.py:*), Bash(~/.claude/skills/kp-gh-lib/scripts/read-context.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/fresh-checkout.sh:*), Bash(~/.claude/skills/kp-gh-lib/scripts/body-parts.py:*), Bash(~/.claude/skills/kp-gh-lib/scripts/comment-once.sh:*), Bash(printf:*), Bash(for:*), Bash(continue:*), Bash(:*), Bash([:*), Bash(~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh:*)
---

# Backfill the coding-item contract

Converts open `type:coding` items filed before the coding-item contract
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*) into it. Drafting and
checking follow NOTES § *Coding item body* → *Drafting from a spec section*, the rules
`kp-sync-spec-tasks` §4a uses for a new item. Manual, idempotent, loopable: a re-run
converts nothing already converted and raises nothing already raised.

Its comment markers keep the names they had when this mode lived in `kp-sync-spec-tasks`
— `<!-- kp-sync-spec-tasks:backfill -->` and
`<!-- kp-sync-spec-tasks:backfill-failed <sha> -->` — so §1.1 step 3's dedup still matches
comments posted before the split, and so does `kp-do-gh-task-loop` §1.3. Never rename them.

**Never asks:** A missing input stops the run with the flag to pass; the skill never
waits for an answer.

## 0. Setup

Numbered as in `kp-sync-spec-tasks` §0, whose steps 1, 3, 4, 5, 7, 9 and 10 these are,
so a `§0.<n>` cite in NOTES § *Drafting from a spec section* holds here too.

1. This run's arguments: `$ARGUMENTS` (empty if none). Parse them: a path/glob names the
   spec docs, whose directory is the spec dir (§1); `--repo <owner/name>` restricts the
   run to one repo; `--project <number|owner/number|id>` selects the target GitHub
   Project (v2); `--limit <n>` caps how many items it converts (§1.1); `--dry-run` sets
   dry-run, which drafts and checks every selected item and writes nothing.
3. **Config.** If the working dir is not inside a git work tree (a workspace root
   holding several checkouts), use as the run dir for every later step the one immediate
   subdirectory whose `.claude/spec-sync.json` `project` matches `--project` (or, with no
   `--project`, the one subdirectory that has the file at all). When several match, keep
   the ones whose config has `requirementRepos` (none do → those with `specGlobs`): the
   spec repo's checkout is the one this skill runs from, and a code repo's config may
   name the same project. Stop with the list only when zero match, or several still
   remain after that narrowing. If `.claude/spec-sync.json` exists in the run dir, read it for
   `project`, `labels`/`typeLabels`, `epicMapping`, `requirementRepos` and `specRepo`. Otherwise use defaults
   (see example file). Never hardcode repo paths or assume project context — this
   skill is global and forked.
4. **Target project (required) — one call**, from the §0.3 run dir:
   `~/.claude/skills/kp-gh-lib/scripts/preamble.sh --no-item --no-fetch [--project <…>]`,
   passing `--project` only when given (`--no-fetch` because §0.9 and §0.10 do this
   skill's syncing). It resolves the GitHub Project (v2) to attach every created issue
   to from the `--project` argument → config `project`. Exit `6` stops the run: print
   `no project given; pass --project <owner/number>` and then the candidates the
   preamble printed on stderr, with `NEW_ISSUES=0` as the last line. Do not invent or
   default a project. Record its **owner login and number** from `.project` — the owner
   login is reused in §1.4 to assign human-gated items.

   The project node id is `.project.id`, the `Priority` field is `.priority`, and the
   option id for the **highest** priority is `.priority.top` (the top-listed option). A
   null `.priority` (the board has no `Priority` field) means skip prioritisation as
   best-effort and note it in the summary; a null `.project.id` (the board could not be
   reached) means skip this run's board writes and note it. §1's `create-item.sh` adds
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
   the `--repo` argument → config `targetRepo` → otherwise there is no target repo and
   §1.1 sweeps the `requirementRepos` repos alone. Stop only when neither exists; print
   `no target repo given; pass --repo <owner/name>` and then the candidates from
   `gh repo list <spec-repo-owner>`, with `NEW_ISSUES=0` as the last line. Do not default to the spec repo. Record the resolved
   `<owner/name>`, if any, as the **target repo**.
   A repo is **routed** when a `requirementRepos` area names it; §0.9 gives its code root.
7. **Repo guard.** Done by §0.4's preamble (exit `5` stops the run with its message).
9. **Validate routed clones.** Before §1 selects anything, pick the code ref by the
   current-milestone rule with the project §0.4's preamble resolved:
   `~/.claude/skills/kp-gh-lib/scripts/milestone-gate.sh --project <owner/number>
   --current` exiting `0` with `"milestone": "M<k>"` gives `--ref release/M<k>`;
   `"milestone": null` or a non-zero exit gives no `--ref`, and §7.5 says why
   (`no milestones`, or the first stderr line). Then run
   `~/.claude/skills/kp-gh-lib/scripts/repo-roots.sh --spec-dir <spec-dir>
   [--ref release/M<k>]` from the run's repo root (`kp-gh-lib/SKILL.md`
   § *`repo-roots.sh`*) — **without** `--spec-files`. It checks every `requirementRepos`
   area (a work tree whose `origin` is the entry's `repo` and that fetches) and prints one
   JSON object. Record each area's `repo`, branch read (`branch`, a bare name:
   `release/M<k>` when that area's origin has it, else its default branch), `sha` and
   **code root** (`codeRoot`: the milestone branch's export, or for the default branch
   the clone itself, fast-forwarded, or an export of `origin/<default branch>` when the
   clone has local edits, is on another branch or has diverged). Every `--code-root`
   this skill passes for a routed repo (§1.1, §1.3, §1.4 and the stale-label pass) is
   that code root, never `<path>`. Exit `1` (a failed check) **stops** the run before
   anything is created — on dry-run too — quoting its stderr line, which names the area,
   the path and the failed check.
10. **Pin the spec commit.** From the same §0.9 JSON, record the **spec repo**
    (`specRepo`: config `specRepo`, else the spec checkout's `origin`), its bare default
    branch (`specBranch`) and the **synced SHA** (`specSha`). Every coding item's `spec:`
    lines and Rules attributions pin this SHA (NOTES § *Drafting from a spec section*).
    The script has already pulled a clean spec checkout on that branch up to the synced
    SHA; called without `--spec-files`, it runs no clean check.

**Assign human-gated items to the project owner.** Every item that awaits a human
— `type:decision`, `type:question`, `type:conflict`, `type:research` — must be
assigned to the resolved project's owner login (§0.4) at creation: `create-item.sh
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

## 1. Backfill

`/kp-backfill-contract [--dry-run] [--repo <owner/name>] [--limit <n>]`
rewrites open coding items filed before the contract existed into a contract body
(`~/.claude/skills/kp-gh-lib/NOTES.md` § *Coding item body*). It runs §0 steps 1, 3, 4,
5 (the target repo), 7, 9 and 10, then this section. The spec dir is the spec path
argument's directory, else the run's repo root; `kp-sync-spec-tasks` §0.2's discovery and
its no-specs stop do not apply. §0.9 calls `repo-roots.sh`
without `--spec-files`, so the clean check and its whole-run stop do not run: no file
list was discovered to check. Every
read here is at the synced SHA, so uncommitted text never reaches a draft; what a
changed doc means is that the operator is still editing it and its pins will soon be
stale. §1.2 checks each doc an item reads, when its path becomes known, and a doc that
differs fails only that item (`dirty-spec <path>`). Run it from the spec repo's
checkout, or from a repo whose `requirementRepos` name the item repos.

### 7.1 Select

The contract check is the selector: an item needs backfill exactly when its body fails
`lint-item.py`. A proxy test on the body — a missing `### Context` heading, say — makes an
item that carries the heading but fails the contract invisible to the mode that exists to
fix it. These five steps run in this order, and the lint is last of them.

1. **Repos.** `--repo` alone when given, else the target repo (if §0.5 resolved one)
   and every `requirementRepos` repo, deduplicated.
2. **Items.** Per repo, one call:
   `~/.claude/skills/kp-gh-lib/scripts/backfill-candidates.sh --repo <repo> --project-id
   <project-id> --sha <synced SHA>` (`kp-gh-lib/SKILL.md` § *`backfill-candidates.sh`*).
   Its JSON array, every open `type:coding` item, is the candidate list; there is no body
   test here. Exit `1` or `2` stops the run with its message.
3. **Skip a failed item.** An item labelled `needs-contract` whose comments already hold
   a `<!-- kp-sync-spec-tasks:backfill-failed <synced SHA> -->` line is skipped as
   `unchanged-failure`, before any lint is run. When the operator removes the label, or
   the synced SHA moves, the item is eligible again. The script reports such an item as
   `skip: "unchanged-failure"`, before any status lookup.
4. **Status.** An item **In progress** or **In review** is never linted, read further,
   edited, labelled or commented on: count it as `skipped in progress`. Every other
   status, and an item not on the board, stays a candidate. The script looks up each
   remaining candidate with `item-id.sh` and reports an In progress / In review item as
   `skip: "in-progress"`. This is 1 point per candidate, and 1 more in §1.4 — never a
   board-wide `gh project item-list`.
5. **Lint, in order, up to the cap.** Sort the remaining candidates by repo, then issue
   number, and lint in that order: write the item's `body` from the script's output to `<b>-orig.md` (`<b>` as §1.2
   defines it) and run `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <repo>
   --body-file <b>-orig.md` with, for a routed repo, `--code-root <code-root>` from §0.9 — the
   same arguments §1.3 passes during the check phase, so a pre-existing `code:` line
   resolves the same way at selection as it does at check time. §1.2 step 1 writes that
   same file from the same source, so selection and draft see one body. Keep an item
   whose lint **exits 1**; an item that exits 0 already meets the contract and is not
   selected. `--limit <n>` bounds this loop: stop linting once `n` items have been kept.
   It does not bound §1.4's label-clearing pass.

**Lint exit 2 or 4 stops the run.** A bad-arguments (2) or fetch-failure (4) exit is not
a verdict on the body, so it is never counted as "needs backfill" and never selects the
item. Selection stops there and nothing is written, exactly as §1.3 already does for the
check phase.

**Accepted cost.** Selection is one `lint-item.py` run per candidate — network calls,
not a free local string test. Measured on a private backend repo on 2026-09-21: 59 open
`type:coding` items, about 4m45s wall clock on a cold cache, with 55 of the 59 paying a
lint run only to be found passing. Steps 3 and 4 keep already-failed and in-flight items
out of the *selection* sweep and `--limit` bounds it, but an unbounded run over a whole
repo pays that, and §1.4's label pass lints each labelled item once more. There is no
lint-verdict cache.

### 7.2 Draft

Per item, with `<b>` = `/tmp/kp-backfill-<repo-name>-<n>` (on dry-run, the session
scratchpad instead of `/tmp`):

1. **Save the body and cut the parts that are copied, never retyped — one call.**
   `~/.claude/skills/kp-gh-lib/scripts/body-parts.py split <repo> <n> <b>` writes the
   body byte for byte to `<b>-orig.md`, its fence to `<b>-fence.md` and its marker lines
   to `<b>-markers.md`. An empty `<b>-fence.md` means the item had no fence; the new body
   has none either. Exit 3 means the body holds a `human-only:start` marker with no
   matching end, which is a failure with reason `unclosed-fence`, so §1.4 leaves the body
   untouched rather than dropping text the operator can read today. Exit 4 is a failed
   GitHub read and stops the run.
2. The marker lines (`spec-ref:`, `slice:`, `parent:`, `blocked-by:`, `resolves:`, …) are
   copied, not written again.
3. **Find the requirement.** The `spec-ref:` marker, else the `**Spec:**` / `Ref:`
   pointer in the prose. Neither names its doc, so find the doc by grepping the spec dir
   at the synced SHA (`git -C <spec-dir> grep -n '<ref>' <synced SHA>`) — several docs
   live there and §0.2's discovery did not run. Before reading it, check that one path
   against the synced SHA (`git -C <spec-dir> diff --quiet <synced SHA> -- <path>`): a
   non-zero exit makes this item a failure with reason `dirty-spec <path>`, and the run
   goes on to the next item. Otherwise read that requirement at the synced SHA
   (`git -C <spec-dir> show <synced SHA>:<path>`). An item with neither is a **no-spec**
   item: it lints without a `serves:` line (`lint-item.py` runs its `serves:` checks
   only for a spec-backed item), and its Context and Rules come from the existing prose
   alone.
4. **Write the sections** to `<b>-sections.md` with Write, following NOTES § *Drafting from a spec section* *Draft*
   steps 2–7 with these differences. Throughout the step, before the text of any further doc a
   `spec:` line or Rules attribution names is read, check that doc as step 3 does; one
   that differs makes this item a failure with reason `dirty-spec <path>`, and the run
   goes on to the next item.
   - **Goal.** `serves:` from the requirement's `Serves:` line. A requirement without one
     is a failure with reason `spec-gap <ref>`; raise nothing, as NOTES § *Drafting from a spec section* would, since the
     item already exists.
   - **Scope / Out of scope.** Keep every sentence and bullet of the existing Scope and
     Out of scope text word for word, and add to it. Any other prose the old body carried
     (background, a `**Milestone:**` line, notes) goes under Scope unchanged. Drop only the
     `**Spec:**` / `Ref:` pointer, which becomes the `spec:` line.
   - **Context.** As NOTES § *Drafting from a spec section* *Draft* step 4. `decision:` lines also come from the item's `resolves:`
     markers and its `decided in #<n>` notes. `code:` lines only when the item's repo is
     routed (§0.9 gives its checkout).
   - **Acceptance criteria.** Every existing AC, reworded only into the
     `- [ ] <observable outcome> — proof: <…>` form. Its meaning, numbers and names stay;
     none is dropped, merged away or weakened. A proof may be added; an obligation may not.
   - **Verify.** From the item repo's `CLAUDE.md`, as NOTES § *Drafting from a spec section* *Draft* step 7.
5. **Assemble and check — one call.**
   `~/.claude/skills/kp-gh-lib/scripts/body-parts.py assemble <b> <b>-sections.md`
   writes `<b>-draft.md` from the non-empty fence, sections and markers, one blank line
   between them, then checks that the fence and marker lines cut from the draft equal
   `<b>-fence.md` and `<b>-markers.md` byte for byte.
6. A non-zero exit from step 5 means the draft is wrong: rebuild `<b>-sections.md` and
   rerun step 5.

### 7.3 Check

Run NOTES § *Drafting from a spec section* *Check* steps 1–2 on `<b>-draft.md` with `--repo <repo>` and, for a routed repo,
`--code-root <code-root>` (§0.9). Fix and rerun at most once, so there are two rounds per item, as in
the NOTES § *Cold-reader check*. A fix may add to the sections but must keep step 4's
rules and re-pass step 5's `assemble` check. `FAIL spec-gap`, `FAIL serves-present`, `unclosed-fence` and
`dirty-spec` cannot be fixed in the draft. Lint exit 2 or 4, or `read-context.sh` exit 1 or 2, **stops the run** before
the next item. Items already written stay written.

### 7.4 Act

Just before any write, re-run `item-id.sh`. If the item has moved to In progress or In
review, count it as `skipped in progress` and write nothing.

- **Pass.** `gh issue edit <n> -R <repo> --body-file <b>-draft.md`. Then comment once
  for audit. The first line is `<!-- kp-sync-spec-tasks:backfill -->`, followed by
  `<details><summary>Previous body</summary>`, `<b>-orig.md` inside a code fence longer
  than any backtick run in it, and `</details>`. If the item carried `needs-contract`,
  remove it (`gh issue edit <n> -R <repo> --remove-label needs-contract`).
- **Fail.** The body stays as it was unless the **Fold** below converts it; nothing
  else on this path edits it. Sort the gaps, fold them when every one is settled, and
  otherwise label, raise for the open ones, and comment.
  1. **Sort each remaining cold-reader gap** — from §1.3's two rounds, or
     `read-context.sh` exit 3 — as settled or open per
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Settling a failing draft* step 1, reading
     the item repo's code at its `--code-root` (§0.9) and the spec at the synced SHA,
     each doc checked as §1.2 step 3 does. A settled gap's answer and source go in the
     comment and nothing is raised for it; only open gaps become questions. A
     question-5 gap (scope against a non-goal or a higher-ranked quality priority) is
     always open, as NOTES § *Cold-reader check* routes it to § *Before raising a
     human-gated item*.

     Failures that are not cold-reader gaps — `unclosed-fence`, `spec-gap <ref>`,
     `dirty-spec <path>` and lint-only `FAIL` lines — are not sorted and raise nothing.

     **Fold.** Before anything is labelled, the settled answers are written into the
     body when all of these hold: lint on `<b>-draft.md` after §1.3 (in the stale-label
     pass, on `<b>-orig.md`) exits 0; no failure is a non-gap one (`unclosed-fence`,
     `spec-gap <ref>`, `dirty-spec <path>`); and every cold-reader gap is settled. In
     every other case the fold does not run, and steps 2–3 below run as they stand.
     - **Re-check citations.** Before writing, find the symbol or text each `path:line`
       citation of an answer names in the code root's current files (§0.9) and update
       the line number to where it is now; check a spec citation at the synced SHA. If
       the cited code or spec text no longer exists, that gap is open and the fold does
       not run.
     - **Write the answers.** Copy `<b>-draft.md` (in the stale-label pass,
       `<b>-orig.md`) to `<b>-fold.md` and write each settled answer into it. Behaviour
       or plumbing goes into Scope, under the bullet the gap is about. A wrong figure or
       proof command is corrected in the AC that holds it. A missing criterion becomes a
       new `- [ ] <outcome> — proof: <…>` AC. A source pointer becomes a `code:` line in
       Context. Rules stays for attributed spec quotes only, so nothing code-settled is
       written there. §1.2 step 4's rules hold: no existing Scope or Out of scope
       sentence is removed, and no AC loses an obligation. The one exception to its rule
       that an AC's numbers and names stay: an AC may be corrected only when the code
       settles the figure and the spec at the synced SHA does not state it — a page count
       that disagrees with `PAGE_SIZE`, say, or a `git grep` proof that also matches test
       files the item itself requires. If the spec states the figure, or the code and
       spec disagree, the gap is open and the fold does not run.
     - **Re-check once.** Run NOTES § *Drafting from a spec section* *Check* steps 1–2 on `<b>-fold.md` once. This round
       does not count toward §1.3's two rounds, but its cold-reader run counts in §1.5's
       `cold-reader runs`. Lint exit 2 or 4, or `read-context.sh` exit 1 or 2, stops the
       run, as in §1.3.
     - **Pass:** take the *Pass* path above with `<b>-fold.md` as the new body: edit the
       body, and post the audit comment with `<b>-orig.md` as *Previous body*, followed by
       a `Folded answers` list naming each answer written in, where it went, and its
       source — an AC correction marked as one. The list covers both folds when the
       **Second fold** ran. Then remove `needs-contract` if the item has it. Report the
       item as `converted`, with `folded <k>` in its reasons, where `<k>` counts the
       answers of both folds.
     - **Second fold.** When the re-check does not pass, fold once more if all of these
       hold: its lint exits 0; no failure is a non-gap one; and every gap it found is
       settled, sorted as step 1 says (a question-5 gap is always open) and with each
       answer's citations passing *Re-check citations*. Write those answers into
       `<b>-fold.md` by the *Write the answers* rules, §1.2 step 4's limits included,
       then re-run `lint-item.py` on it with the same arguments — lint only. The cold
       reader does not run again: each settled answer comes from the code or spec, and
       each further cold-reader round tends to raise new minor points rather than
       converge. Lint exit 0 takes the *Pass* path above; lint exit 1 discards
       `<b>-fold.md` and goes on to *Still failing* with the re-check's gaps; exit 2 or 4
       stops the run, as in §1.3. When any condition fails, the second fold does not run
       and *Still failing* follows.
     - **Still failing:** discard `<b>-fold.md`; the body stays as it was. Run steps 1–3
       on the gaps of this last round, the re-check, not the earlier ones: an open one
       among them raises the human-gated item as step 2 says, and the re-check's lint
       `FAIL` lines go into the comment unsorted, as step 3 lists them. The second fold
       is the last one: there is never a third fold, and the cold reader never runs after
       the second fold.

     When the fold does not run or falls through to *Still failing*, create the label
     (`gh label create needs-contract -R <repo> --color D93F0B --force`) and add it,
     then go on with steps 2–3.
  2. **Raise one item for the open gaps.** When at least one gap is open, raise a
     human-gated item per NOTES § *Human-gated item body*, § *Before raising a
     human-gated item*, §0 *Assign human-gated items to the project owner* and §0
     *Prioritise human-gated items on the board*, with NOTES § *Creating an item* →
     *Repo identification*, placed per
     `~/.claude/skills/kp-gh-lib/NOTES.md` § *Every new item has a milestone*. Create it
     in the coding item's repo with one call —
     `~/.claude/skills/kp-gh-lib/scripts/create-item.sh --repo <repo> --title "…"
     --body-file <draft> --label type:<x> --label repo:<name> --project <owner>/<number>
     --priority top --assign-owner --origin <repo>#<n> --cache
     <scratchpad>/milestone-current-<owner>-<number>.json`, which does the board add, the
     placement and the link; note each `skipped` step in its JSON; its marker block carries
     `blocks: #<n>` naming the coding item, plus `spec-ref: <key>` when the coding item
     has one — the form `kp-do-gh-task-loop` §1.3 matches. Its questions are the open
     gaps only, at most what NOTES § *Human-gated item body* → *Several questions in one
     impasse* allows, each with a recommended option, never at `confidence: high` — an
     open gap is one no source settles, so this item is never creator-decided
     (`~/.claude/skills/kp-gh-lib/NOTES.md` § *Human-gated item body* → *Confidence and creator-decided items*); the settled gaps and their answers
     go in its `<details>` evidence. When every gap is settled, raise nothing: the
     comment with the proposed answers is the whole result.

     **Dedup first.** Raise nothing when an open `type:decision` / `type:question` /
     `type:conflict` in that repo already carries, outside its human-only fence, a
     `blocks:` marker naming the item (`#<n>`, `<repo>#<n>` or its `spec-ref:` value).
     Find it with `kp-do-gh-task-loop` §1.3's single search,
     `gh issue list -R <repo> --state open --limit 100 --json number,labels,body --search '"#<n>" OR "<spec-ref>" in:body'`,
     dropping the `<spec-ref>` term when the item has none; that existing item takes the
     raised item's place in the comment.
  3. **Comment.** The first line is
     `<!-- kp-sync-spec-tasks:backfill-failed <synced SHA> -->`, followed by the item's
     failure reason from §1.2 (`unclosed-fence`, `spec-gap <ref>`, `dirty-spec <path>`),
     if any, then the remaining `FAIL` lines, then each settled gap with its answer and
     source, worded so the operator can paste it into Scope or, for a missing criterion,
     as `- [ ] <outcome> — proof: <…>` under Acceptance criteria, then each open gap
     naming the raised item. Then a `**What you do now**` block of three numbered steps:
     (1) when an item was raised, resolve it with `/kp-resolve-spec-decision <d>` (its
     real number), then paste its answer and the proposed answers into the issue body;
     when none was, paste the proposed answers into the issue body (Scope or Acceptance
     criteria) — either way, or close the issue if it is no longer wanted; (2) remove the
     `needs-contract` label; (3) run `/kp-backfill-contract` again,
     which converts the item if it now passes or labels it again with a new comment.
     Write the comment to a file and post it with
     `~/.claude/skills/kp-gh-lib/scripts/comment-once.sh <repo> <n> --marker '<!-- kp-sync-spec-tasks:backfill-failed <synced SHA> -->' --body-file <file>`,
     which posts nothing when a comment with that first line already exists.
- **Dry-run.** Writes, labels, comments and raises nothing. `<b>-draft.md` stays in the
  scratchpad as the proposed body, and §1.5 reports the gaps it would settle and the
  item it would raise. The fold and both its checks still run in the scratchpad, where
  `<b>-fold.md` stays as the proposed body of an item §1.5 reports as
  `would convert (folded <k>)`.

**Clear a stale `needs-contract` label.** An item can be hand-fixed to passing while
still carrying the label, and §1.1 no longer selects it — it exits 0. Once the selected
items are done, enumerate the labelled items, each looked up **before** linting, with one
call:
`~/.claude/skills/kp-gh-lib/scripts/backfill-candidates.sh --repo <repo> --project-id <project-id> --sha <synced SHA> --labelled`
— so the pass has the body it lints without a
second fetch, and a run that labelled more than one page of items still sees every one of
them. An item with `skip: "in-progress"` keeps the label, counts as `skipped in progress`
and is never linted, exactly as §1.1.4 has it.
Lint the rest with the call §1.1.5 makes: write that listing's body to `<b>-orig.md` and
run `~/.claude/skills/kp-gh-lib/scripts/lint-item.py --repo <repo> --body-file
<b>-orig.md` with, for a routed repo, `--code-root <code-root>` from §0.9. A hand-fixed item
in a routed repo carries `code:` lines (§1.2 step 4) and the mode runs from the spec
repo's checkout, so without `--code-root` every one of them fails to resolve and the item
this pass exists to free stays labelled. Lint is only one of the two checks that set the
label, so an item that **exits 0** then gets NOTES § *Drafting from a spec section* *Check* step 2, the cold reader, on
`<b>-orig.md`: `~/.claude/skills/kp-gh-lib/scripts/read-context.sh --body-file
<b>-orig.md --repo <repo>` with the same `--code-root`, its stdout saved to a file, and one
`Explore` subagent, `model: sonnet`, reading only that file. One round, with no §1.3 repair; the
only body edit this pass makes is the fold below. An item whose cold reader answers `ok`
to all six questions has the label
removed (`gh issue edit <n> -R <repo> --remove-label needs-contract`) and **nothing
else**: its body, its comments and its board status are left untouched, and it is neither
selected nor redrafted. A gap, or `read-context.sh` exit 3, gets §1.4 *Fail* step 1's
settled/open sort. When every gap meets the **Fold** condition, the item gets that fold,
starting from `<b>-orig.md`, and the **Second fold** when its re-check meets that step's
condition, unless its comments already hold a
`<!-- kp-sync-spec-tasks:backfill-failed <synced SHA> -->` line (the script's
`failedAtSha: true`) — that item keeps the
handling below, which matches §1.1 step 3's `unchanged-failure`. A fold that passes
takes the same *Pass* steps (body edit, audit comment with its `Folded answers`, label
removal) and is reported as `converted`, not `label cleared`. An item with any open gap,
an item the fold skipped and one whose fold falls through keep the label and go
through §1.4 *Fail* steps 2–3: only an open gap
raises the item, with the same dedup, and the comment — first line
`<!-- kp-sync-spec-tasks:backfill-failed <synced SHA> -->`, then the settled answers and
open gaps, then the three-step `**What you do now**` block — is posted with the same
`comment-once.sh <repo> <n> --marker '<!-- kp-sync-spec-tasks:backfill-failed <synced SHA> -->' --body-file <file>`
call, which posts nothing when a comment with that first line already exists, so §1.1 step 3 skips the item as
`unchanged-failure` until the operator acts. `read-context.sh` exit 1 or 2 stops the run,
as NOTES § *Drafting from a spec section* *Check* step 2 says. The label removal, the raise and the comment are writes, and the
status check above is the one lookup this pass makes, so it governs all three. An item that exits 1 keeps
the label and is left alone here — §1.1 reaches it on its own terms. Lint exit 2 or 4
stops the run, as everywhere else.

This pass is **separate from and unbounded by `--limit`**. `--limit` bounds the conversion
sweep over all open `type:coding` items; this pass enumerates only the items that already
carry the label — one query, however many they are — so a run that converts nothing must
still clear a label that no longer applies. Report a cleared item as
`label cleared`, a folded one as `converted`, and one kept for a cold-reader gap as
`needs-contract` with its gaps. On dry-run, run both checks and any fold in the
scratchpad, report the result, and edit, remove, label, comment and raise nothing.

### 7.5 Report

Before the table, print a `Next steps` section. It lists only items that still need the
operator — never a converted or folded one: one line per `needs-contract` item —
one §1.4 *Fail* labelled, or one the stale-label pass kept for a cold-reader gap —
naming the item, its open gaps in short and the item raised for them with its
`/kp-resolve-spec-decision <d>` prompt, followed by the three-step
`**What you do now**` block §1.4 *Fail* writes, printed once with both forms of its
step 1. When no item is `needs-contract`, the section says `none`.

Print a table with columns **repo | item | title | status | result | reasons**, where
result is `converted`, `needs-contract`, `label cleared`, `skipped in progress` or
`unchanged-failure` (`would convert` / `would convert (folded <k>)` / `would label` /
`would clear label` on dry-run),
with `raised #<d>` appended when §1.4 *Fail* raised an item for it (`blocked on #<d>` when
its dedup found one, `would raise` on dry-run), and reasons ending in `settled <k>`, the
number of its gaps settled. For an item the §1.4 **Fold** converted, `folded <k>` — the
number of answers written into its body — replaces `settled <k>`.
On dry-run, also print each draft's path.
Then print these sections, each headed with its count:

- `converted (n)`;
- `needs-contract (n)`, each item with its reasons and its settled-gap count;
- `raised (n)`, each raised item `<repo>#<d>` with the coding item it blocks and its
  milestone report line;
- `label cleared (n)`;
- `skipped in progress (n)`;
- `code refs: <area>=<branch> …` from §0.9's repo-roots JSON, with §0.9's no-ref reason
  when it passed no `--ref`;
- `cold-reader runs: <n>`, counting §1.3's runs and the stale-label pass's, with the lint
  `INFO` line of each converted item.

The final line is `NEW_ISSUES=<n>`, where `n` is the `raised` count (0 on dry-run): the
human-gated items are the only issues the mode creates, and the dedup keeps a re-run from
raising one twice.
