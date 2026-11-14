# TICKETING — from spec to GitHub Project tickets

How AI agents turn [`TECH_SPEC.md`](./TECH_SPEC.md) into a GitHub Project board: read spec → emit tickets → build agents execute → loop until the board is complete and the app meets the spec. This file is the contract for the **ticket-generation agent**; it does not build the app.

## 1. Source of truth
- **What to build:** `TECH_SPEC.md` §5 (functional + acceptance criteria), §8 (data model), cross-cutting (§10–13).
- **Order:** `TECH_SPEC.md` §19 milestones → epics, run strictly in order (M0, then M1, …).
- **Look & feel:** the brief, enforced via a design checklist on UI tickets.
- Spec wins over any ticket. If the spec is silent on behavior, **open a `question` issue — never invent scope.**

## 2. Board structure
All items go on the operator's **existing shared GitHub Project (v2)**, named in the project's own config — never create a new project; resolve the board and add every issue (`gh project item-add`; Projects v2 are cross-repo). Fields: `Status`, `Milestone` (from §19), `Type` (feature/chore/bug/question/docs), `Estimate` (S/M/L), `Area`. One milestone per §19 row; §5 clusters → issues; cross-cutting → issues + embedded acceptance items.

Because the board is shared across repos, **every issue must be repo-identifiable at a glance**, by both a **title prefix** `[<REPO-CODE>] ` (short stable uppercase code per repo, e.g. `my-org/shop-data-api` → `DATA-API`; never change a code once items carry it) and a **`repo:<repo-name>` label** (create with `gh label create ... --force` before first use). The one exception is a **milestone epic** — a `type:epic` issue grouping one §19 milestone, marked `spec-ref: milestone:<id>` (e.g. `spec-ref: milestone:M1`): it spans repos, so it gets neither the prefix nor the label, even when all its children sit in one repo. Its children still carry the prefix and label of the repo they are created in.

## 3. Granularity
One ticket = one shippable, independently reviewable PR (S/M; split L). Explicit `depends on #N`, only on a ticket in the same milestone: an earlier milestone is already done when this one starts, and a ticket this one needs from a later milestone moves into this one. Every functional ticket cites its spec section(s) and carries the requirement's stable `REQ-*` id as its `spec-ref` — the dedup key for the ticket's whole lifecycle.

## 4. Ticket template
```markdown
## [<REPO-CODE>] <imperative title>
**Milestone:** <Mx>   **Repo:** <owner/name>   **Area:** <area>   **Type:** <type>   **Estimate:** <S/M/L>
**Spec:** TECH_SPEC.md §<n> ...

### Context
<why this exists>

### Scope
- <concrete work; expected files/modules per §6>

### Out of scope
- <explicit exclusions>

### Acceptance criteria
- [ ] <testable, derived from §5 AC>
- [ ] Tests added per §17 (which layer)
- [ ] Applicable cross-cutting gates met (a11y/perf/security)

### Design checklist (UI only)
- [ ] Canonical tokens; design rules from the brief honored

### Depends on (same milestone only)
- #<n>

spec-ref: REQ-<AREA>-<NNN>
```

## 5. Generation loop
1. Parse §5/§8/§19 → milestone→issue map.
2. Emit milestones as repo-neutral milestone epics (`type:epic`, `spec-ref: milestone:<id>`, no `[<REPO-CODE>]` prefix, no `repo:*` label), then issues (template, fields, dependencies) — each issue titled with its `[<REPO-CODE>]` prefix and labeled `repo:*`; add every one to the shared board (§2).
3. Dedupe: list existing issues; update in place; close removed-scope issues.
4. Self-review: every §5 AC covered; cross-cutting gates represented; no oversized issues; dependency graph is a valid DAG; no "Depends on" crosses milestones.
5. Ambiguities about what to build → `question` issues; ticket order is never a question. After **3 iterations** without convergence, summarize open questions for the human.
6. Done when milestones populated, dependencies valid, every spec AC traces to an issue.

## 6. Build-agent expectations
Pick `Todo` issues respecting deps; implement on a branch; PR satisfies every acceptance checkbox, passes CI (§17), updates docs/ADRs, references the issue (`Closes #N`). Failing a design/cross-cutting gate = not done.

## 7. Tooling
Use `gh` CLI / GitHub API; keep operations idempotent (search before create); never force-push shared branches; one logical change per commit.
