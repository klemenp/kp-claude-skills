<!-- human-only:start (not LLM/spec context) -->
> **For humans:** fixture for lint-item.py.
<!-- human-only:end -->

### Goal
Hold a checkout's stock for the decided length.

### Scope
- The change this item makes.

### Out of scope
- Everything else.

### Context
code: kp-gh-lib/scripts/spec-index.py
decision: example-org/shop-api#12

### Acceptance criteria
- [ ] The order tests pass — proof: `pytest -k order` output.

### Verify
- `pytest`
