# Daily, weekly and monthly source reconciliation reviews

The dashboard contains six cards: C-Trax, SwipeSimple, Authorize.net, Shopify, Bank · NAB / IRIS and Google Drive backup. The **Daily / weekly / monthly reconciliation** link opens `/money_reconciliations`. The existing inventory-reconciliation report remains available separately.

Choose a calendar date and Daily, Weekly or Monthly. Weeks start Monday. All period boundaries use America/New_York, including daylight-saving transitions. The report presents source evidence for the entire chosen period, with a CSV download and an administrator/operator action to save or refresh the review. Saved reviews have encrypted payloads, tenant-scoped access, provenance timestamps and one current record per tenant/period. Refreshing replaces that period's current review and retains immutable encrypted CSV and JSON versions in the [document vault](daily-reconciliation-retention.md); it never creates or changes source sales, payments, deposits or inventory. Unchanged source data reuses the same archived evidence.

## Automatic closes

The existing Solid Queue worker saves the previous completed period:

| Review | Eastern schedule | Saved period |
| --- | --- | --- |
| Daily | 12:20 a.m. daily | Yesterday |
| Weekly | 12:25 a.m. Monday | Previous Monday through Sunday |
| Monthly | 12:30 a.m. on the first | Previous calendar month |

These jobs produce internal reports only, with no email or message delivery. Late exports or settlement evidence can be included by refreshing a saved period. A job configuration is not proof of fresh vendor data: each review includes source freshness and evidence warnings. Existing source schedules remain unchanged: Shopify every 15 minutes, C-Trax/SwipeSimple every 30 minutes, approved IRIS API reads daily, and configured Google Drive backups every six hours.

## Accounting and evidence rules

- Shopify recorded sales use order dates and group currency separately. Recorded refunds use refund dates. Amounts are taken from stored canonical data, including recorded tax/shipping; fetch completeness is a source concern rather than an assumed guarantee.
- SwipeSimple uses the latest observation per native transaction identity, approved Sales and Refunds, and distinct merchant/currency/tender groups. Invoice snapshots are not added again to payment receipts.
- Authorize.net uses settlement dates for settled sales/refunds. Portal/API observations sharing gateway/transaction IDs are deduplicated, with the newest source observation retained (production API wins equal timestamps). Sandbox records are excluded. Decimal precision and currencies are preserved. Pending or declined transactions are not represented as settled cash.
- NAB / IRIS selects one newest covering deposit snapshot per merchant and calendar-month slice. It never adds overlapping API/CSV windows together. Adjustments remain separate. Native Daily Deposits currency and actual net ACH funding are unconfirmed; an unknown currency stays unknown. Exported rows do not establish completeness of actual bank statements.
- Monthly Health Center summaries appear only when the complete source month fits the requested period. They are not allocated into invented daily/weekly amounts or added to deposit totals.
- C-Trax native daily retail snapshots provide recorded order totals, tax, tips, cash/card receipts and source refund controls per merchant, currency and store timezone. Missing amounts remain unavailable and missing/unreviewed source days are flagged. These normalized snapshots and their corrections are versioned in the document vault. Stock freshness and Google backup health remain operational context.

The report is deliberately **Review required**, not **Reconciled**. Stable payment-to-order and payout-to-bank links, source-account mapping, fees, currency and funding evidence are not yet fully established. Orders, gateway payments and processor deposits describe different layers of the same money flow and are never added into a combined revenue number. Missing observations are flagged; missing currency, fees, coverage and bank receipt are not replaced by zeros or inferred values.

## Access and operation

Report viewing/CSV requires reports-read permission. Saving additionally requires sync-write permission. Snapshot IDs and source records are scoped to the current tenant. CSV text cells are protected against formula interpretation. Real merchant identifiers, source exports, credentials and amounts stay out of Git.

The NAB card links to the existing encrypted IRIS setup and native Daily Deposits upload. A portal import does not imply API access. The Google backup card derives status from the platform-owned connection and backup logs; it does not expose backup files, folders or credentials to store users. Only platform administrators receive its settings link. An unconnected Google account is shown as Needs connection; account consent is still required before the existing scheduled upload job can run.

Preserve consistent SQLite/configuration backups and encryption keys before applying migration `20261016040000`. Rehearse loader/assets and report generation against a cloned database first. Roll back application code independently of report data; dropping the new table would discard subsequently saved reviews.
