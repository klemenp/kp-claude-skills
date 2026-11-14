# Fixture spec

## 2. Goals, non-goals, v1 scope

### Goals

**G-1 — Fresh prices.** Every listed product has prices at most 30 days old.

**G-2 — Merchant time.** The merchant schedules a import in one click.

### Non-goals

- A full copy of the market.
- G-3: exporting catalogue lists; the site reads the database directly.

## 5. Functional spec

**REQ-FIX-001 — Stable requirement.**
Serves: G-1
The importer refreshes a listed product's prices every 30 days.

**REQ-FIX-002 — Changing requirement.**
Serves: G-2
The dashboard lists and filters scheduled imports.
