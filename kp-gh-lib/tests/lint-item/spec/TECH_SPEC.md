# Shop — technical specification

Fixture spec for the lint-item suite. The shop is invented.

## 1. Goals and non-goals

**G-1 — Orders are never oversold.** A paid order can always be filled from stock.

**G-2 — Checkout stays fast.** A customer reaches the payment step in under two seconds.

Non-goals: marketplace sellers, multi-currency pricing.

## 2. Catalogue

**REQ-CAT-001 — List products with live stock**

Serves: G-2

The product list shows each product's sellable stock, read from the stock ledger.

## 3. Orders

### 3.1 Reservations

**REQ-ORDER-001 — Reserve stock at checkout**

Serves: G-1

A checkout reserves each line item's stock for 15 minutes. A reservation that expires
emits the event described in §5, and REQ-ORDER-002 returns its stock. Payment capture
follows Payments spec §8. The reservation length was decided in example-org/shop-api#12.

**REQ-ORDER-002 — Release expired reservations**

Serves: G-1

A sweeper returns the stock of every expired reservation to the ledger within one minute.

**REQ-ORDER-003 — Export orders**

A merchant downloads the orders of one day as a CSV file.

## 4. Metrics

**REQ-METRIC-001 — Expose order metrics**

Serves: G-2

Counters for placed, paid and expired orders are exposed in Prometheus format.

## 5. Events

Every order state change appends one `OrderEvent` row with the order id, the old state,
the new state and a timestamp.
