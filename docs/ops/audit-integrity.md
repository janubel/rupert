# Integrity fixes and local containers

The October 17 code audit has regression coverage in `web/test/integration/audit_integrity_test.rb` and the warehouse checkout suites.

## Payment and confirmation recovery

Warehouse payment attempts commit before the gateway request. They retain a nonce digest, invoice, amount, gateway fingerprint and encrypted shipping snapshot; raw payment tokens and gateway credentials are never retained. Cart changes are refused while an attempt is submitting, unknown or approved.

An approved response remains saved if local order creation fails. The same browser can finish that approved order without sending another charge or entering another card token. A lost response, held response or approval without a transaction ID remains unresolved. The customer sees the invoice reference, and the Activity log records a review item. The store operator must review that invoice in the original gateway account. Do not clear the attempt, switch its state to declined or submit a new charge merely because a local order is missing. This release does not automatically resolve an unknown outcome.

Order confirmation now requires the purchasing browser's signed, share-bound confirmation cookie. Knowing a vendor link and an order number grants no access to another customer's confirmation. Historical confirmations without the new cookie remain available to authorized staff through the ordinary order pages.

The new `warehouse_payment_attempts` table is additive. No existing orders, payments or payroll records are rewritten by deployment.

## Accounting and salary rules

Expense edits void the current posted journal entry rather than the oldest historical one. Vendor-payment form and bank-statement entry paths use the same transactional posting workflow; removal and restoration update the current posting too. Existing historical discrepancies need an attributed reconciliation rather than silent backfill during deployment.

Weekly and biweekly salaried pay use 52 and 26 annual installments, prorated over inclusive seven- and fourteen-day periods. Monthly salary uses one twelfth of annual salary per complete calendar month; partial months are prorated by their actual calendar-day counts. Final-period rounding happens once after the calculation. Previously finalized payslips are not recalculated by this release.

Sales-tax allocation separates the amount including tip from the order's collected tax. Cumulative payment allocation assigns a final split-tender rounding cent once. Ignored bank lines remain retained history and are excluded from active reconciliation totals and unresolved work.

## SQLite restoration

Live SQLite restoration through the web UI is disabled. An HTTP request cannot stop other workers or safely replace their open WAL database. Snapshot downloads remain available. PostgreSQL restoration retains its separate transaction-based path.

An instance operator restoring SQLite must first take a consistent SQLite backup using the backup API, verify a restored copy with integrity and foreign-key checks, preserve configuration and encryption keys privately, stop all web/job writers and close their connections, then restore and verify before starting services. Preserve subsequent business writes and an explicit reconciliation plan before choosing an older backup. A plain copy of the live main database file does not include uncheckpointed WAL commits.

## Local Orchard instance

`Dockerfile.local` builds a separate development instance with dummy boot configuration and no production database or merchant credentials. Build it with the full source revision:

```sh
container build -f Dockerfile.local --build-arg RUPERT_BUILD_SHA="$(git rev-parse HEAD)" -t rupert-local:current .
```

Use a dedicated persistent data volume at `/data`, prepare that local database before starting web, and publish port 3000 to a loopback-only host port. Complete first-run setup locally. The SER8 deployment and its encrypted data remain independent.
