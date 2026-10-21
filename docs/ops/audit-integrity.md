# Integrity fixes and local containers

The October 17 code audit has regression coverage in `web/test/integration/audit_integrity_test.rb` and the warehouse checkout suites.

## Payment and confirmation recovery

Warehouse payment attempts commit before the gateway request. They retain a nonce digest, invoice, amount, gateway fingerprint and encrypted shipping snapshot; raw payment tokens and gateway credentials are never retained. Cart changes are refused while an attempt is submitting, unknown or approved.

An approved response remains saved if local order creation fails. The same browser can finish that approved order without sending another charge or entering another card token. A lost response, held response or approval without a transaction ID remains unresolved. The customer sees the invoice reference, and the Activity log records a review item. The store operator must review that invoice in the original gateway account. Do not clear the attempt, switch its state to declined or submit a new charge merely because a local order is missing. This release does not automatically resolve an unknown outcome.

Order confirmation now requires the purchasing browser's signed, share-bound confirmation cookie. Knowing a vendor link and an order number grants no access to another customer's confirmation. Historical confirmations without the new cookie remain available to authorized staff through the ordinary order pages. If a successful checkout response is lost, returning to checkout with the original signed cart cookie recovers the paid order and issues its confirmation cookie without another gateway request. Cart editing still starts a new cart after payment.

The new `warehouse_payment_attempts` table is additive. No existing orders, payments or payroll records are rewritten by deployment.

## Warehouse checkout review and catalog boundaries

Fresh warehouse payments require a signed review of the cart, vendor link, workspace and exact line quantities/prices. The review expires after fifteen minutes. Catalog repricing, cart edits from another tab, expired reviews and modified tokens return an updated checkout for customer review before any gateway request. Previously approved payments can still finish without a fresh review or another charge.

Public catalogs, cart additions and checkout validation exclude inactive products, explicit product/variant tombstones and absent/nonpositive list prices. Legacy catalog rows without a presence stamp retain their previous compatibility until a complete source read marks presence. Availability is explicitly scoped to that workspace's Shopify mirror. Cart quantity changes check the accumulated quantity, and withdrawn lines can still be removed.

Catalog forms render per request, including with production caching enabled, so one buyer never receives another browser's CSRF form token. Checkout shipping fields and signed review tokens are excluded from request instrumentation.

Gateway submissions are limited to five per cart and thirty per vendor link over ten minutes. Counters use durable payment attempts and a workspace lock before network I/O, so changing carts or restarting a worker does not reset the link budget. Only actual new payment attempts count; blocked submissions create no new attempt and do not extend the cooldown. HTTP 429 responses include a Retry-After header. Existing approved/uncertain outcomes are handled before these limits; recovery is not a new charge. These are payment submission limits, not a general network traffic limiter.

## Local warehouse stock holds

A new additive migration creates `warehouse_stock_holds`. Each fresh payment attempt reserves its line quantities in the same workspace-serialized transaction, before any gateway request. Available warehouse quantities subtract active holds across all vendor links and carts in that workspace. Explicit declines release their holds atomically; approved, submitting and unknown payments retain them. Local order completion attaches the existing holds to the order. Failed local completion and repeated payment recovery reuse the same holds.

The migration also conservatively holds stock for existing approved/uncertain attempts and completed legacy checkout carts. It does not rewrite orders, payments or source inventory. Existing unsubmitted carts reserve no stock.

The Warehouse overview lists the oldest outstanding holds with paid-order links and uncertain-payment references. The authenticated order page lists each held line. Staff with both sales-write and inventory-write permission can release it after confirming fulfillment, confirming the source stock adjustment, entering its reference and timestamp, and refreshing the Shopify inventory mirror afterward. The release checks the snapshot timestamp for every variant, stores the confirming actor, adjustment reference (encrypted), adjustment and observed source-refresh timestamps, and records an audit event. Repeated release is a no-op. Refunds and ordinary tracking/status changes do not silently free stock; they need the same explicit stock reconciliation.

This workflow writes only local holds and fulfillment evidence. It does not create source orders or mutate Shopify/Square stock. Other source sales can still change physical stock between mirror reads; paired POS allocations and other source channels remain separate workflows.

## Accounting and salary rules

Expense edits void the current posted journal entry rather than the oldest historical one. Vendor-payment form and bank-statement entry paths use the same transactional posting workflow; removal and restoration update the current posting too. Existing historical discrepancies need an attributed reconciliation rather than silent backfill during deployment.

Weekly and biweekly salaried pay use 52 and 26 annual installments, prorated over inclusive seven- and fourteen-day periods. Monthly salary uses one twelfth of annual salary per complete calendar month; partial months are prorated by their actual calendar-day counts. Final-period rounding happens once after the calculation. Previously finalized payslips are not recalculated by this release.

Sales-tax allocation separates the amount including tip from the order's collected tax. Cumulative payment allocation assigns a final split-tender rounding cent once. Ignored bank lines remain retained history and are excluded from active reconciliation totals and unresolved work.

## Database restoration

Live database restoration through the web UI is disabled. An HTTP request cannot stop other web/job writers; even a successful replacement discards newer activity. SQLite cannot safely replace an open WAL database. Snapshot downloads remain available, use unique private filenames for overlapping requests, and retain the `.sqlite3` file extension.

An instance operator restoring a database must first take a consistent database backup using the SQLite backup API (`VACUUM INTO`), verify a restored copy with integrity and foreign-key checks, preserve configuration and encryption keys privately, stop all web/job writers and close their connections, then restore and verify before starting services. Preserve subsequent business writes and an explicit reconciliation plan before choosing an older backup. A plain copy of the live main database file does not include uncheckpointed WAL commits.

## Local Orchard instance

`Dockerfile.local` builds a separate development instance with dummy boot configuration and no production database or merchant credentials. Build it with the full source revision:

```sh
container build -f Dockerfile.local --build-arg RUPERT_BUILD_SHA="$(git rev-parse HEAD)" -t rupert-local:current .
```

Use a dedicated persistent data volume at `/data`, prepare that local database before starting web, and publish port 3000 to a loopback-only host port. Complete first-run setup locally. The SER8 deployment and its encrypted data remain independent.
