# Reviewed sales imports and daily register reports

Reviewed 2026-10-15. [Open Rupert Sync](https://rupert.stoverparc.org/syncs#swipesimple) or [open daily register reports](https://rupert.stoverparc.org/reports/register_summary). Sign in with the relevant store permissions.

## Supported CSV contract

Rupert accepts a prepared line-item sales CSV, rather than assuming every native SwipeSimple report has the same columns. SwipeSimple's transaction exports may lack item details. Verify and convert the source report into this contract before importing; do not infer item prices or payment completion from a transaction total alone. [Download the fictional sample](https://techmore.github.io/rupert/data/swipesimple-sales-template.csv).

Required columns are Order, Date, Item, Qty, Unit Price, Payment, Status and Currency. SKU, Total and Order Total are optional. Recognized aliases remain supported. Date must be a real ISO timestamp with seconds and an explicit offset, such as `2026-07-01T14:30:00-04:00`. Missing dates and date-only rows are rejected. Use a stable source order/transaction identifier, positive whole item quantities and supported two-decimal prices. All rows in an order must agree on its timestamp, currency, status and tender; supplied line/order totals must reconcile with item quantities and prices.

Each order supports one known cash, card, gift-card, check or other tender. Paid, completed or approved status must be explicit. Declines, voids, refunds, authorizations and ambiguous split-tender rows are rejected. One currency is allowed per file; supported two-decimal currencies are USD, CAD, EUR, GBP, AUD and NZD. Customer names are ignored instead of creating customer identities from names alone. Tax, tips, discounts, fees and location allocation are unavailable; unsupported financial details must be reconciled separately. This contract must not be used to relabel those amounts as merchandise.

The file limit is 2 MiB and 5,000 data rows. Error messages identify row positions and fixed validation reasons, without returning customer/export contents.

## Preview, review and import

Choose a CSV file or paste its text under Sync, then select **Preview sales**. Previewing validates the entire file and displays aggregate order, item, tender and item-sales totals with limitations. It creates no sales, customer records, sync runs or cache changes. Review the source totals before selecting **Import reviewed sales**.

The preview is tied to the exact export, signed-in user, store and contract version. It expires after 15 minutes. Editing or replacing the export requires another preview; totals posted by the browser cannot authorize an import. With JavaScript, the selected file remains available for the second step. Without JavaScript, attach or paste the same export again after reviewing the preview.

The import is a bounded, atomic local operation. If any order is invalid or conflicts with an existing record, the file's business changes roll back. Identical existing orders remain intact, including their child records. Changed or refunded orders require explicit reconciliation rather than an automatic overwrite. New order and ledger identities are scoped to the store. Existing legacy records are not automatically rewritten.

Only users with sync-write permission may preview or import. Imports share the existing per-store sync lock; a running source sync must finish first. A successful import records a source-specific sync receipt and refreshes local aggregates. Cache failure does not turn committed sales into a failed import. No payment provider is contacted, platform stock changed, scheduled sync triggered or message sent by this workflow.

## Daily register report

Select a business day, source and optional location. Day boundaries use Rupert's configured Eastern time zone. Sales, payments and refunds use their separate stored event dates, so a refund today can refer to an older sale. Currency, source and location remain separate.

The report shows recorded tender, recorded refund and net amounts for each tender method, with CSV export. Payment coverage identifies orders with missing, incomplete, excess or unknown imported payments. This compares all currently imported payments against the selected day's orders; it is not a historical register-close balance. Missing tax/amounts stay unavailable. Undated-event counts cannot recover a source timestamp replaced by a legacy importer.

Source freshness separates a successful source import's completion time from its latest stored order, payment and refund dates. Importing an old CSV today does not prove today's sales coverage. Skipped or failed sources do not refresh success; bounded full-sync history reports uncertainty when older evidence was not inspected.

Shopify tenders are inferred from gateway names and order totals, and their timestamps may be order creation rather than collection. Completed payments on unsettled orders are excluded. These records do not verify actual collection, split tenders or bank deposits. C-Trax data, terminal settlement, discounts, collected tips and merchant fees remain incomplete. Compare the report with actual source register, processor and bank records before closing.

## Remaining POS work

Actual checkout, tax/discount calculation, customer-facing terminal tipping, failed/retried payment handling, refunds and source-to-bank reconciliation remain the primary POS acceptance gate. Account connection checks do not establish those capabilities. See the [connection guide](https://techmore.github.io/rupert/payment-integrations.html) and [POS parity acceptance](https://techmore.github.io/rupert/pos-parity.html).

The Shopify bulk-material workflow now stores exact source line and variant identities, versioned gram recipes and reviewed one-time lot deductions with shortage checks. Reused SKUs never identify the recipe. Prepared SwipeSimple CSV rows are not eligible for this Shopify-only deduction workflow. Automatic consumption/refunds and an owner-selected Google Sheets destination remain planned. See the [inventory workflow guide](inventory-workflows.html).

## Vendor references

[SwipeSimple daily and batch reporting](https://support.swipesimple.com/hc/en-us/articles/360011707534-Batch-Reports-Daily-Transaction-Reports), [SwipeSimple public API statement](https://support.swipesimple.com/hc/en-us/articles/27117544574487-Does-SwipeSimple-have-a-public-API-for-integrations). Rupert's prepared CSV contract is narrower than all vendor transaction/report formats.
