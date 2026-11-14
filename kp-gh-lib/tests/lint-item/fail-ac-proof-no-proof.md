### Goal
`spec-index.py` reports a clear error when a spec path is a directory.

### Scope
- `kp-gh-lib/scripts/spec-index.py`: reject a directory path with exit 2.

### Out of scope
- Caching changes.

### Context
code: kp-gh-lib/scripts/spec-index.py
code: kp-gh-lib/NOTES.md

### Acceptance criteria
- [ ] A directory path exits 2 with a message naming it

### Verify
- `python3 .github/scripts/validate_skills.py`
