# Fixture spec

## 2. Goals, non-goals, v1 scope

### Goals

**G-1 — Fresh prices.** Every listed product has prices at most 30 days old.

**G-2 — Merchant time.** The merchant schedules a import in two clicks.

**G-3 — Catalogue exports.** Catalogue lists reach the public site.

**G-4 — Review history.** Reviews are kept per product.

### Non-goals

- A full copy of the market.

## 5. Functional spec

**REQ-FIX-001 — Stable requirement.**
Serves: G-1
The importer refreshes a listed product's prices every 30 days.

**REQ-FIX-002 — Changing requirement.**
Serves: G-2
The dashboard lists scheduled imports.

**REQ-FIX-003 — Vanishing requirement.**
Serves: G-3, G-4
Export writes catalogue lists as CSV.
