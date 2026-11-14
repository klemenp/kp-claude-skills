<!-- human-only:start (not LLM/spec context) -->
> **For humans:** Refresh prices. spec: fixture/spec@__OLD__:TECH_SPEC.md#REQ-FIX-001
<!-- human-only:end -->

### Goal
serves: G-1
Prices stay fresh, which is G-1.

### Scope
- importer.py — schedule the refresh.

### Out of scope
- The dashboard.

### Context
spec: fixture/spec@__OLD__:TECH_SPEC.md#REQ-FIX-001
spec: other/repo@__OLD__:TECH_SPEC.md#REQ-FIX-001

### Rules
> The importer refreshes a listed product's prices every 30 days.
> — fixture/spec@__OLD__:TECH_SPEC.md#REQ-FIX-001

### Acceptance criteria
- [ ] A 31-day-old price is refreshed — proof: `pytest -k refresh`

### Verify
```
spec: fixture/spec@__OLD__:TECH_SPEC.md#REQ-FIX-001
```

spec-ref: REQ-FIX-001
blocked-by: #12
parent: #3
