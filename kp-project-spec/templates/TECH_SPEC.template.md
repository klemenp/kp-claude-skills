# TECH_SPEC — <Project Name>

> **Status:** <draft | complete> (open unknowns: <none | list>).
> **Audience:** human reviewers and AI build agents.
> **Design/requirements authority:** [`<BRIEF>.md`](./<BRIEF>.md) overrides this file on conflicts in its domain.
> **Ticketing:** [`TICKETING.md`](./TICKETING.md).

Single source of truth for the build. Every section addressable; functional sections carry acceptance criteria written to lift into tickets.

## 1. Overview & positioning
<What this is, for whom, the core value, the one-sentence spine. Link the brief.>

### Domain language & contexts
<Glossary table: term → meaning → not to be confused with. Requirements, acceptance criteria and decisions use these terms exactly; add a term here before using it elsewhere.>
<Bounded-context table: context → what it owns → what it talks to.>

## 2. Goals, non-goals, v1 scope

### Goals
<Table in priority order, highest first: id → measurable outcome (metric + target). The order is binding: when two goals conflict, the higher one wins. Ids are `G-<n>` and permanent — never renumber or reuse one, even when goals are reordered or dropped.>

### Quality priorities
<Ranked list, highest first, of the qualities trade-offs turn on (e.g. freshness, cost, operator effort, risk), each naming the `G-<n>` it protects. A higher quality wins a trade-off against a lower one.>

### Non-goals
<Explicit: what is deliberately out — kills scope creep.>

### v1 scope
<What ships.>

## 3. Personas & primary journeys
<Table: persona → need → primary journey. Name the conversion/success event.>

## 4. Information architecture / sitemap
<Routes/screens tree with one-line purpose each. Note routing/i18n strategy.>

## 5. Functional spec (ticket-ready, with acceptance criteria)
<Per feature: short description + numbered acceptance criteria (AC) that are testable. One subsection per feature/area. Every requirement carries a stable explicit id `REQ-<AREA>-<NNN>` (e.g. `REQ-AUTH-001`) in its heading or first line — ticket sync keys on these ids, so they are permanent: never renumber or reuse an id when text or headings change. Every requirement's first line also carries `Serves: G-<n>[, G-<m>]`, naming the §2 goals it serves (e.g. `REQ-AUTH-001 · Serves: G-1, G-3`).>

## 6. Architecture
<Components, boundaries, data flow diagram (ASCII/Mermaid), rendering/runtime strategy, suggested module layout.>

## 7. Tech stack (pinned)
<Table: concern → choice → version. Mark anything fixed by existing code.>

## 8. Data & content model
<Entities/collections with fields, types, constraints; access control; persistence; i18n/localization config.>

## 9. Design system
<Tokens (canonical values + source), type, components, role discipline, hard UI rules. Defer look-and-feel to the brief.>

## 10. SEO (if web-facing)
<Metadata, structured data, sitemap/robots, canonical, i18n-readiness, content strategy.>

## 11. Performance
<Budgets as acceptance gates (e.g. CWV, Lighthouse, bundle/latency), validated where.>

## 12. Accessibility (if UI)
<Target standard (e.g. WCAG 2.2 AA), concrete requirements, how tested.>

## 13. Security
<Input validation, authn/authz, secrets, rate limiting, idempotency, headers/transport, data minimization, GDPR/cookies, dependencies.>

## 14. Observability & analytics
<Analytics, error tracking, logging levels/structure, uptime/health, key funnels.>

## 15. Code quality
<Language strictness, lint/format, conventions, error-handling rules.>

## 16. Maintainability (human + AI agents)
<Root CLAUDE.md, config-as-code, docs/ADRs, predictable structure, env.example, keeping the spec current.>

## 17. Testing & CI
<Test layers + tools + coverage; CI pipeline gates; preview deploys.>

## 18. Deployment & environments
<Host, environments, DB/storage/email, migrations, env-var inventory, seed.>

## 19. Build roadmap / epics & milestones
<Ordered milestones (M0…Mn) → outcome each. Milestones run strictly in order — nothing in M1 starts while an M0 item is open — so no item-level dependency crosses milestones: work an earlier milestone needs belongs to that earlier milestone. Maps 1:1 to tickets.>

## 20. Assumptions & resolved-decisions log
<Table: topic → layer (domain / feature / technical) → decision → rationale → serves (the `G-<n>` ids or quality priority the decision serves). A feature or technical rationale cites the `G-<n>` or quality priority that decided it. Must show no open unknowns affecting behavior/interfaces/scope. List low-risk build-time deferrals separately.>
