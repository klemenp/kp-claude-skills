<!-- human-only:start (not LLM/spec context) -->
> **For humans:** fixture for lint-item.py.
<!-- human-only:end -->

### Goal
Return the stock of expired reservations.
serves: G-2

### Scope
- The change this item makes.

### Out of scope
- Everything else.

### Context
spec: example-org/shop-spec@0123456789abcdef0123456789abcdef01234567:TECH_SPEC.md#REQ-ORDER-002

### Acceptance criteria
- [ ] The order tests pass — proof: `pytest -k order` output.

### Verify
- `pytest`

spec-ref: REQ-ORDER-002
