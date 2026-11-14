<!-- human-only:start (not LLM/spec context) -->
> **For humans:** fixture for lint-item.py.
<!-- human-only:end -->

### Goal
Reserve stock when a checkout starts.
serves: G-1

### Scope
- The change this item makes.

### Out of scope
- Everything else.

### Context
spec: example-org/shop-spec@0123456789abcdef0123456789abcdef01234567:TECH_SPEC.md#REQ-ORDER-001
decision: example-org/shop-api#12
dismissed: TECH_SPEC.md#5-events — outside this slice
dismissed: TECH_SPEC.md#REQ-ORDER-002 — outside this slice

### Rules
> A checkout reserves each line item's stock for 15 minutes.
> — example-org/shop-spec@0123456789abcdef0123456789abcdef01234567:TECH_SPEC.md#REQ-ORDER-001

### Acceptance criteria
- [ ] The order tests pass — proof: `pytest -k order` output.

### Verify
- `pytest`

spec-ref: REQ-ORDER-001
