---
name: kp-project-spec
description: Author a complete, unknowns-resolved build specification (TECH_SPEC.md + supporting markdown) for a software project from an initial brief, so AI agents can turn it into tickets and build it. Use when the user wants to "spec out", "write a specification for", "plan the build of", or create a spec repo for a new app/project, especially when a positioning/requirements brief exists.
---

# Project specification authoring

Produce a complete specification — markdown files — for building a software project. The spec is consumed by humans for review and by AI agents to generate tickets and implement the build. It must be human-readable yet compact, and complete enough that no behavioral ambiguity remains.

## Operating principles

- **Resolve every unknown before writing the spec.** A spec with open behavioral questions is a bug waiting to happen.
- **Ask one targeted question at a time.** When multiple valid options exist, present them with concrete pros/cons and a recommendation; let the user decide. Never silently pick on anything affecting behavior, interfaces, or scope. (If the user prefers conversational Q&A over the structured question tool, follow their lead.)
- **Reuse what exists.** Inventory any existing code/briefs/stack first; treat committed stack choices as fixed unless told otherwise.
- **Bias to simplicity.** Recommend the least complex option that meets the goal; push back on speculative scope.
- **Compact for agents.** Tables, bullets, and acceptance criteria over prose. Every section addressable.

## Workflow

### 1. Ingest & inventory
- Read all provided inputs (brief, existing repos, READMEs, package manifests, design files). Identify the committed stack, the design authority, and what already exists vs. what's greenfield.
- Restate the goal back in one sentence and confirm scope boundaries.

### 2. Resolve unknowns (loop, one question at a time)
Drive out decisions until none affecting behavior/interfaces/scope remain. Resolve the **domain axes first** — later choices are settled from them:
- Goals: each a measurable outcome with a `G-<n>` id, then their priority order (binding when goals conflict).
- Quality priorities: rank the qualities trade-offs will turn on (e.g. freshness vs. cost vs. operator effort vs. risk), each tied to the goal it protects.
- Personas and their primary journeys.
- Non-goals.
- Domain terms: the glossary and bounded contexts, so later questions and requirements share one vocabulary.

Only then the **technical axes**:
- Repo strategy (spec-only vs. monorepo; greenfield vs. evolve existing).
- Architecture & backend location (single deployable vs. separate services).
- Data/content layer (DB + custom admin, headless CMS, git-based files) — weigh AI-agent maintainability *and* human-editor ergonomics.
- Integrations (email, payments, auth, third-party services) — prefer self-hosted/in-app when it matches the product ethos.
- i18n / locales for v1.
- Hosting/infra defaults.
Each unresolved choice → one question with options, pros/cons, recommendation; a technical recommendation cites the `G-<n>` goal or quality priority behind it. Record every answer in a decisions log, with its layer and the goals it serves.

### 3. Write the spec
Create the spec files (see `templates/`):
- **`TECH_SPEC.md`** — the master spec, using the section template in `templates/TECH_SPEC.template.md`. Fill every section; give every functional feature **acceptance criteria** written to lift directly into tickets, and a **stable explicit requirement id** (`REQ-<AREA>-<NNN>`) — downstream sync (`/kp-sync-spec-tasks`) uses the id as the requirement's permanent dedup key, so heading renames never break tracking. Ids are never renumbered or reused. Goals carry permanent `G-<n>` ids in priority order, every requirement's first line carries `Serves: G-<n>[, G-<m>]`, and requirements use the §1 glossary's terms.
- **`TICKETING.md`** — how agents convert the spec into a GitHub Project board (epics/milestones, issue template, generation loop). Base on `templates/TICKETING.template.md`.
- **`README.md`** — what the repo is, file map, how to read it, the loop diagram, decisions summary.
- Copy any provided brief in as the design/requirements authority and reference it from `TECH_SPEC.md`.
Adapt the section set to the project; drop sections that genuinely don't apply, but don't drop cross-cutting concerns (security, testing, observability, maintainability) without reason.

### 4. Review loop (max 3 iterations, then ask)
After drafting, review for: completeness (every requirement covered), internal contradictions, unresolved unknowns, broken cross-references between files, untestable acceptance criteria, and goal traceability: every `REQ-*` serves at least one `G-<n>`, every goal is served by at least one `REQ-*` or is explicitly out of v1, and glossary terms are used consistently across requirements. Fix inline. Surface to the user only a genuinely new fork. After **3 review iterations** without convergence, ask the user whether to keep iterating. Exit the loop when the spec is internally consistent and unknowns-free.

### 5. Repo setup (if requested)
Guard every step so a re-run or a resume after a partial setup converges instead of erroring:
- `git init` (a harmless re-init on an existing repo), stage, then commit **only if something is staged**: `git diff --cached --quiet || git commit -m "<imperative message>"` — a clean tree skips rather than erroring on "nothing to commit".
- **Create or reuse the remote** (confirm public/private and name first). If `gh repo view <name>` shows the repo already exists, don't re-create it: ensure `origin` points at it (`git remote get-url origin || git remote add origin <url>`) and `git push -u origin HEAD`. Otherwise `gh repo create <name> --private --source . --remote origin --push`.
- Verify with `gh repo view` and a clean `git status`.

## Quality bar (self-check before finishing)
- Decisions log shows **no open unknowns** that affect behavior/interfaces/scope.
- Every functional feature has testable acceptance criteria and a stable `REQ-*` id (unique, never renumbered).
- Every `REQ-*` serves at least one `G-<n>`, and every goal is served by at least one `REQ-*` or is explicitly out of v1.
- Glossary terms are used consistently across requirements — one term per concept, as §1 defines it.
- Cross-cutting requirements present and concrete (perf budgets, security gates, a11y target, testing layers, CI).
- A maintainability section addresses **both** human and AI-agent maintainers.
- Cross-references between files resolve; stack versions are consistent with any existing code.
- The spec is something a senior engineer would call complete and not overcomplicated.

## Supporting files
- `templates/TECH_SPEC.template.md` — section skeleton for the master spec.
- `templates/TICKETING.template.md` — spec-to-tickets contract skeleton.
